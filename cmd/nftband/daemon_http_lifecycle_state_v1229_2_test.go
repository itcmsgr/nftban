// SPDX-License-Identifier: MPL-2.0
//
// v1.229.2 TRACK A — optional-HTTP lifecycle consistency.
//
// ONE root condition, TWO wrong consumers. startHTTP may legitimately produce no
// server (the configured port is owned by Apache/DA/cPanel/nginx). Before this
// change:
//
//	A1  gracefulShutdown called d.httpSrv.Shutdown() unguarded -> nil-receiver panic
//	    on the handleSignals goroutine. The only recover() is deferred in the PARENT
//	    goroutine and cannot catch it, so the process died and everything after that
//	    line was skipped: module StopAll, OpQueue drain, the SourceIndex save, bus
//	    close, final cache flush, completeShutdown, PID removal — all after STOPPING=1
//	    had been sent. Proven on lab4: systemd Result=exit-code, unit FAILED,
//	    OnFailure= dependencies triggered, PID file left stale.
//
//	A2  startup asserted setHTTPReady(true) unconditionally while http_ready sat in
//	    the MANDATORY readiness tier — systemd was told a mandatory prerequisite was
//	    satisfied by a component that did not exist.
//
//	A2b EVERY net.Listen error took the "API disabled" path, so a genuine fault
//	    (EADDRNOTAVAIL from a bad bind address, EACCES on a privileged port) was
//	    reported as a healthy daemon.
//
// The contract these arms lock:
//
//	RUNNING             listener established         -> http_ready mandatory, satisfied
//	DISABLED_BY_DESIGN  errors.Is(err, EADDRINUSE)   -> DEGRADED tier, READY=1 allowed
//	FAILED              any other error              -> startHTTP errors, startup fails
//
// Note the asymmetry that makes A2 subtle: reporting httpReady=false when disabled
// would be the OPPOSITE bug — http_ready would land in `missing` and an intentional
// port collision would become a FATAL startup failure. ARM 2 therefore asserts the
// global readiness outcome, not merely the flag.
package main

import (
	"context"
	"errors"
	"net"
	"net/http"
	"os"
	"strings"
	"syscall"
	"testing"
)

// ---------------------------------------------------------------------------
// ARM 3 support: the classifier itself, exercised against REAL kernel errnos
// rather than fabricated error values, so the arm cannot pass on a mock that
// does not resemble what net.Listen actually returns.
// ---------------------------------------------------------------------------

func listenErr(t *testing.T, addr string) error {
	t.Helper()
	ln, err := net.Listen("tcp", addr)
	if err == nil {
		ln.Close()
		return nil
	}
	return err
}

// TestHTTPBindClassification_ErrnoNotText proves the disabled-by-design predicate
// is errno-based and, critically, that non-EADDRINUSE faults are NOT tolerated.
func TestHTTPBindClassification_ErrnoNotText(t *testing.T) {
	// EXPECTED COLLISION — hold a port, then collide with it.
	held, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Skipf("cannot bind a loopback port in this environment: %v", err)
	}
	defer held.Close()
	collision := listenErr(t, held.Addr().String())
	if collision == nil {
		t.Fatal("control failed: second bind on a held port succeeded — the arm would be vacuous")
	}
	if !errors.Is(collision, syscall.EADDRINUSE) {
		t.Fatalf("port collision did not classify as EADDRINUSE: %v", collision)
	}

	// GENUINE FAILURE — an address that cannot exist on this host.
	notAvail := listenErr(t, "203.0.113.77:9999") // RFC 5737 documentation range
	if notAvail == nil {
		t.Skip("host unexpectedly owns a documentation-range address; cannot exercise the genuine-failure arm")
	}
	if errors.Is(notAvail, syscall.EADDRINUSE) {
		t.Fatalf("genuine bind failure misclassified as EADDRINUSE: %v", notAvail)
	}
	// The failure must be recognisable as a real error, not silently tolerated.
	if notAvail.Error() == "" {
		t.Fatal("genuine failure produced an empty error")
	}
}

// ---------------------------------------------------------------------------
// ARM 1/2/3: readiness tiering. These drive the REAL evaluateReadinessLocked via
// the real setters, so a change to the tier assignment is caught here.
// ---------------------------------------------------------------------------

// readyLifecycle returns a lifecycle with every MANDATORY prerequisite except HTTP
// already satisfied, so each arm below varies exactly one thing.
func readyLifecycle() *startupLifecycle {
	// Use the REAL constructor: a bare &startupLifecycle{} leaves internal maps and
	// channels nil, so Snapshot() panics and the arms would be testing a shape the
	// daemon never builds.
	s := newStartupLifecycle(os.Getpid())
	s.setRuntimePathsReady(true)
	s.setModulesInitialized(true)
	s.setIPCBound(true)
	s.setIPCAccepting(true)
	s.setRequiredModulesStarted(true)
	return s
}

func evaluate(s *startupLifecycle) (missing, degraded []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.evaluateReadinessLocked()
}

func contains(xs []string, want string) bool {
	for _, x := range xs {
		if x == want || strings.Contains(x, want) {
			return true
		}
	}
	return false
}

// ARM 1 — HTTP RUNNING: http_ready is mandatory and satisfied.
func TestReadinessArm1_HTTPRunning(t *testing.T) {
	s := readyLifecycle()
	s.setHTTPReady(true)

	missing, degraded := evaluate(s)
	if len(missing) != 0 {
		t.Fatalf("ARM1: running HTTP must leave no mandatory prerequisite unmet, got missing=%v", missing)
	}
	if contains(degraded, "http") {
		t.Fatalf("ARM1: a running HTTP server must not be reported degraded, got degraded=%v", degraded)
	}
}

// ARM 2 — DISABLED BY DESIGN: degraded tier, and READY must remain reachable.
//
// This asserts the GLOBAL outcome deliberately. Asserting only httpReady==false
// would also pass for the startup-fatal regression this fix exists to avoid.
func TestReadinessArm2_HTTPDisabledByDesign(t *testing.T) {
	s := readyLifecycle()
	s.setHTTPDisabledByDesign(true)
	// httpReady deliberately left false: there is no server to be ready.

	missing, degraded := evaluate(s)

	if contains(missing, "http_ready") {
		t.Fatalf("ARM2 REGRESSION: disabled-by-design HTTP became a MANDATORY unmet prerequisite "+
			"(missing=%v) — an intentional port collision would fail startup", missing)
	}
	if len(missing) != 0 {
		t.Fatalf("ARM2: unexpected mandatory prerequisites unmet: %v", missing)
	}
	if !contains(degraded, "http") {
		t.Fatalf("ARM2: disabled-by-design HTTP must be reported in the DEGRADED tier, got degraded=%v", degraded)
	}
}

// ARM 2b — the state must be honest: disabled must never read as ready.
func TestReadinessArm2_DisabledIsNotReportedReady(t *testing.T) {
	s := readyLifecycle()
	s.setHTTPDisabledByDesign(true)
	snap := s.Snapshot()
	if snap.HTTPReady {
		t.Fatal("ARM2b: HTTPReady must be false when no server exists — this was the readiness lie")
	}
	if !snap.HTTPDisabledByDesign {
		t.Fatal("ARM2b: disabled-by-design must be observable in the snapshot, not merely implied by !HTTPReady")
	}
}

// ARM 3 — GENUINE FAILURE must not be expressible as degraded.
//
// The producer returns an error for non-EADDRINUSE faults, so a failed HTTP never
// reaches readiness evaluation at all. This arm proves the state machine cannot be
// coaxed into representing a failure as a tolerated degradation.
func TestReadinessArm3_GenuineFailureIsNotDegraded(t *testing.T) {
	s := readyLifecycle()
	// A genuine failure sets NEITHER flag — nothing marks it tolerable.
	missing, degraded := evaluate(s)

	if contains(degraded, "http") {
		t.Fatalf("ARM3: an unclassified/failed HTTP must NOT appear in the degraded tier, got degraded=%v", degraded)
	}
	if !contains(missing, "http_ready") {
		t.Fatalf("ARM3: an unclassified/failed HTTP must leave http_ready in the MANDATORY unmet set, got missing=%v", missing)
	}
}

// ---------------------------------------------------------------------------
// State authority: zero value must not be mistaken for a valid degraded state.
// ---------------------------------------------------------------------------

func TestHTTPLifecycleState_ZeroValueIsUnknown(t *testing.T) {
	var d Daemon
	if d.httpState != httpStateUnknown {
		t.Fatalf("zero value must be httpStateUnknown, got %v", d.httpState)
	}
	if httpStateUnknown == httpStateDisabledByDesign || httpStateUnknown == httpStateRunning {
		t.Fatal("UNKNOWN must be distinct from DISABLED and RUNNING")
	}
	for _, c := range []struct {
		s    httpLifecycleState
		want string
	}{
		{httpStateUnknown, "unknown"},
		{httpStateRunning, "running"},
		{httpStateDisabledByDesign, "disabled-by-design"},
		{httpStateFailed, "failed"},
	} {
		if got := c.s.String(); got != c.want {
			t.Errorf("String(): got %q want %q", got, c.want)
		}
	}
}

// ---------------------------------------------------------------------------
// A1: the shutdown terminator must tolerate an absent optional component.
// ---------------------------------------------------------------------------

// A1 has two halves, deliberately.
//
// The behavioural half proves WHY the guard is required: an unguarded Shutdown on a
// nil *http.Server panics. The structural half proves the PRODUCTION shutdown path
// actually carries the guard — asserting a copy of the guard inside the test would
// pass even if production lost it, which is exactly the vacuity this project keeps
// catching. gracefulShutdown needs a fully wired Daemon (bus, registry, lifecycle,
// contexts) so it cannot be driven from a unit test; the structural assertion is the
// honest substitute, and the lab witness covers the wired path.
func TestA1_UnguardedShutdownOnNilServerPanics(t *testing.T) {
	var srv *http.Server
	panicked := false
	func() {
		defer func() {
			if r := recover(); r != nil {
				panicked = true
			}
		}()
		_ = srv.Shutdown(context.Background())
	}()
	if !panicked {
		t.Fatal("control failed: Shutdown on a nil *http.Server did not panic — " +
			"the structural guard below would be guarding nothing")
	}
}

func TestA1_ShutdownPathGuardsOptionalHTTPServer(t *testing.T) {
	src, err := os.ReadFile("daemon_lifecycle.go")
	if err != nil {
		t.Fatalf("read daemon_lifecycle.go: %v", err)
	}
	text := string(src)

	idx := strings.Index(text, "d.httpSrv.Shutdown(")
	if idx == -1 {
		// SUBJECT_NOT_FOUND is a test failure, never a silent pass.
		t.Fatal("subject not found: no d.httpSrv.Shutdown( call in daemon_lifecycle.go — " +
			"the shutdown path changed shape and this guard no longer proves anything")
	}

	// The guard must appear between the start of gracefulShutdown and the call.
	fnIdx := strings.Index(text, "func (d *Daemon) gracefulShutdown()")
	if fnIdx == -1 || fnIdx > idx {
		t.Fatal("subject not found: gracefulShutdown does not precede the Shutdown call")
	}
	between := text[fnIdx:idx]
	if !strings.Contains(between, "if d.httpSrv != nil") {
		t.Fatal("A1 REGRESSION: gracefulShutdown calls d.httpSrv.Shutdown() without a preceding " +
			"nil guard — on a host whose HTTP port is owned by another service, SIGTERM panics and " +
			"module StopAll, OpQueue drain, SourceIndex save, bus close, final cache flush, " +
			"completeShutdown and PID removal are all skipped")
	}
}

// A2 structural: readiness must never be asserted unconditionally again.
func TestA2_HTTPReadyIsNotAssertedUnconditionally(t *testing.T) {
	src, err := os.ReadFile("daemon_init.go")
	if err != nil {
		t.Fatalf("read daemon_init.go: %v", err)
	}
	text := string(src)
	if !strings.Contains(text, "setHTTPReady(true)") {
		t.Fatal("subject not found: no setHTTPReady(true) call in daemon_init.go")
	}
	// It must be reached through a state decision, not on the straight-line path.
	idx := strings.Index(text, "setHTTPReady(true)")
	window := text[max(0, idx-400):idx]
	if !strings.Contains(window, "httpStateRunning") {
		t.Fatal("A2 REGRESSION: setHTTPReady(true) is not gated on httpStateRunning — " +
			"the daemon can again assert a mandatory readiness prerequisite while no server exists")
	}
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// The classifier is the A2b decision point. Driven with REAL kernel errnos, and
// asserting the FAILED arms explicitly — a classifier that tolerated every error
// would satisfy only the disabled arm, so the failing cases are what give this teeth.
func TestClassifyBindError_OnlyEADDRINUSEIsDisabledByDesign(t *testing.T) {
	if got := classifyBindError(nil); got != httpStateRunning {
		t.Errorf("nil error must classify as running, got %v", got)
	}

	held, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Skipf("cannot bind loopback in this environment: %v", err)
	}
	defer held.Close()
	collision := listenErr(t, held.Addr().String())
	if collision == nil {
		t.Fatal("control failed: colliding bind succeeded — arm would be vacuous")
	}
	if got := classifyBindError(collision); got != httpStateDisabledByDesign {
		t.Errorf("EADDRINUSE must classify as disabled-by-design, got %v", got)
	}

	// GENUINE FAILURES — these are the arms an over-tolerant classifier breaks.
	if got := classifyBindError(syscall.EACCES); got != httpStateFailed {
		t.Errorf("EACCES must classify as FAILED (fail loud), got %v", got)
	}
	if got := classifyBindError(syscall.EADDRNOTAVAIL); got != httpStateFailed {
		t.Errorf("EADDRNOTAVAIL must classify as FAILED (fail loud), got %v", got)
	}
	if got := classifyBindError(errors.New("some future errno we do not know yet")); got != httpStateFailed {
		t.Errorf("unknown errors must default to FAILED, never tolerated, got %v", got)
	}
}
