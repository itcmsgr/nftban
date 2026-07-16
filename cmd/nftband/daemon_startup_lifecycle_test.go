// =============================================================================
// NFTBan v1.0 - nftband Daemon - Startup lifecycle tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Deterministic behavioural tests for the daemon startup lifecycle: phase ordering/timing, readiness gate, exactly-once READY, startup-pending diagnostic, error sanitization, and log-secrecy"
//
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_STARTUP_PENDING_SEC"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package main

import (
	"bytes"
	"errors"
	"log"
	"strings"
	"sync"
	"testing"
	"time"
)

// -----------------------------------------------------------------------------
// Test doubles: injectable clock + recording notifier
// -----------------------------------------------------------------------------

type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func (f *fakeClock) now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.t
}

func (f *fakeClock) advance(d time.Duration) {
	f.mu.Lock()
	f.t = f.t.Add(d)
	f.mu.Unlock()
}

type recNotifier struct {
	mu         sync.Mutex
	states     []string
	readyCount int
	sent       bool
	err        error
}

func (r *recNotifier) fn(state string) (bool, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.states = append(r.states, state)
	if state == "READY=1" {
		r.readyCount++
		return r.sent, r.err
	}
	return true, nil
}

func (r *recNotifier) readyCalls() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.readyCount
}

func (r *recNotifier) statusStates() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]string, len(r.states))
	copy(out, r.states)
	return out
}

// newTestLifecycle builds a lifecycle with a fake clock and, optionally, a notifier.
func newTestLifecycle(fc *fakeClock, n notifyFunc) *startupLifecycle {
	s := newStartupLifecycle(4242)
	s.now = fc.now
	// Rebaseline the startup/phase clocks to the fake clock (production uses a
	// single real clock for both, so this alignment is a test-only concern).
	s.startupStartedAt = fc.now()
	s.phaseStartedAt = fc.now()
	s.notifier = n
	return s
}

// markAllMandatoryReady sets every mandatory readiness prerequisite true.
func markAllMandatoryReady(s *startupLifecycle) {
	s.setRuntimePathsReady(true)
	s.setModulesInitialized(true)
	s.setIPCBound(true)
	s.setIPCAccepting(true)
	s.setHTTPReady(true)
	s.setRequiredModulesStarted(true)
}

// syncBuffer is a mutex-guarded buffer so a background goroutine (the pending
// diagnostic) that logs concurrently with the test reading the output does not
// race. Production logs to the stdlib logger's own synchronized writer; this is a
// test-only concern.
type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

// captureLog redirects the stdlib logger to a synchronized buffer for the duration
// of fn.
func captureLog(t *testing.T, fn func()) string {
	t.Helper()
	buf := &syncBuffer{}
	orig := log.Writer()
	flags := log.Flags()
	log.SetOutput(buf)
	log.SetFlags(0)
	defer func() {
		log.SetOutput(orig)
		log.SetFlags(flags)
	}()
	fn()
	return buf.String()
}

// -----------------------------------------------------------------------------
// PHASE_ORDERING
// -----------------------------------------------------------------------------

func TestLifecycle_PhaseOrdering(t *testing.T) {
	fc := &fakeClock{t: time.Unix(1000, 0)}
	s := newTestLifecycle(fc, nil)

	out := captureLog(t, func() {
		s.CompletePhase(PhaseProcessStart)
		s.BeginPhase(PhaseRuntimePathsInit, "paths")
		s.CompletePhase(PhaseRuntimePathsInit)
		s.BeginPhase(PhaseModulesInit, "registry")
		s.CompletePhase(PhaseModulesInit)
		// Backwards transition must be rejected (RUNTIME_PATHS < MODULES).
		s.BeginPhase(PhaseRuntimePathsInit, "paths")
	})

	if !strings.Contains(out, "state=invalid_transition") {
		t.Fatalf("expected invalid_transition rejection in log, got:\n%s", out)
	}
	snap := s.Snapshot()
	if snap.Phase != PhaseModulesInit {
		t.Fatalf("backwards transition mutated phase: got %s want %s", snap.Phase, PhaseModulesInit)
	}
	if snap.LastCompletedPhase != PhaseModulesInit {
		t.Fatalf("last_completed_phase = %s, want %s", snap.LastCompletedPhase, PhaseModulesInit)
	}
}

// -----------------------------------------------------------------------------
// BEGIN_COMPLETE_TIMINGS
// -----------------------------------------------------------------------------

func TestLifecycle_BeginCompleteTimings(t *testing.T) {
	fc := &fakeClock{t: time.Unix(2000, 0)}
	s := newTestLifecycle(fc, nil)

	out := captureLog(t, func() {
		s.BeginPhase(PhaseModulesInit, "registry")
		fc.advance(250 * time.Millisecond)
		s.CompletePhase(PhaseModulesInit)
	})

	// begin logs elapsed_ms=0; complete logs elapsed_ms=250, total advancing.
	if !strings.Contains(out, "phase=MODULES_INIT state=begin") {
		t.Fatalf("missing begin event:\n%s", out)
	}
	if !strings.Contains(out, "state=complete") || !strings.Contains(out, "elapsed_ms=250") {
		t.Fatalf("expected complete with elapsed_ms=250, got:\n%s", out)
	}
}

// -----------------------------------------------------------------------------
// FAILED_PHASE_STATE
// -----------------------------------------------------------------------------

func TestLifecycle_FailedPhaseState(t *testing.T) {
	fc := &fakeClock{t: time.Unix(3000, 0)}
	s := newTestLifecycle(fc, nil)

	out := captureLog(t, func() {
		s.BeginPhase(PhaseIPCSocketInit, "ipc")
		s.FailPhase(PhaseIPCSocketInit, errors.New("bind refused"))
	})
	if !strings.Contains(out, "phase=IPC_SOCKET_INIT state=failed") {
		t.Fatalf("expected failed phase event, got:\n%s", out)
	}
	if !strings.Contains(out, "error=bind refused") {
		t.Fatalf("expected sanitized error in log, got:\n%s", out)
	}
	snap := s.Snapshot()
	if snap.State != stateFailed {
		t.Fatalf("state = %s, want failed", snap.State)
	}
	// A failed phase is not a completion.
	if snap.LastCompletedPhase == PhaseIPCSocketInit {
		t.Fatalf("failed phase must not be recorded as last_completed")
	}
}

// -----------------------------------------------------------------------------
// DEGRADED_PHASE_STATE
// -----------------------------------------------------------------------------

func TestLifecycle_DegradedPhaseState(t *testing.T) {
	fc := &fakeClock{t: time.Unix(4000, 0)}
	s := newTestLifecycle(fc, nil)

	out := captureLog(t, func() {
		s.BeginPhase(PhaseOpQueueInit, "opqueue")
		s.DegradePhase(PhaseOpQueueInit, "opqueue", errors.New("nftbackend has no NFTManager"))
	})
	if !strings.Contains(out, "state=degraded") {
		t.Fatalf("expected degraded event, got:\n%s", out)
	}
	snap := s.Snapshot()
	if len(snap.DegradedComponents) != 1 || snap.DegradedComponents[0] != "opqueue" {
		t.Fatalf("degraded_components = %v, want [opqueue]", snap.DegradedComponents)
	}
	// A degraded phase still counts as completed (daemon may proceed).
	if snap.LastCompletedPhase != PhaseOpQueueInit {
		t.Fatalf("degraded phase should record last_completed, got %s", snap.LastCompletedPhase)
	}
}

// -----------------------------------------------------------------------------
// READY_AFTER_MANDATORY_PREREQUISITES  (+ degradable allowed)
// -----------------------------------------------------------------------------

func TestLifecycle_ReadyAfterMandatoryPrerequisites(t *testing.T) {
	fc := &fakeClock{t: time.Unix(5000, 0)}
	n := &recNotifier{sent: true}
	s := newTestLifecycle(fc, n.fn)
	s.notifyExpected = true // systemd Type=notify run

	markAllMandatoryReady(s)
	// Leave nft/opqueue/watchdog false → degradable, must NOT block readiness.

	err := s.SendReady()
	if err != nil {
		t.Fatalf("SendReady returned error with all mandatory prereqs met: %v", err)
	}
	if n.readyCalls() != 1 {
		t.Fatalf("READY=1 sent %d times, want 1", n.readyCalls())
	}
	snap := s.Snapshot()
	if !snap.ReadySent {
		t.Fatalf("ready_sent = false after successful notify")
	}
	// Degraded components surfaced, not hidden.
	if len(snap.DegradedComponents) == 0 {
		t.Fatalf("expected degraded components (nft/opqueue/watchdog) to be surfaced")
	}
}

// -----------------------------------------------------------------------------
// READY_BLOCKED_WHEN_IPC_NOT_ACCEPTING
// -----------------------------------------------------------------------------

func TestLifecycle_ReadyBlockedWhenIPCNotAccepting(t *testing.T) {
	fc := &fakeClock{t: time.Unix(6000, 0)}
	n := &recNotifier{sent: true}
	s := newTestLifecycle(fc, n.fn)

	// Everything mandatory EXCEPT ipc_accepting (socket bound but not serving).
	s.setRuntimePathsReady(true)
	s.setModulesInitialized(true)
	s.setIPCBound(true)
	s.setIPCAccepting(false)
	s.setHTTPReady(true)
	s.setRequiredModulesStarted(true)

	err := s.SendReady()
	if err == nil {
		t.Fatalf("expected fatal readiness error when ipc_accepting is false")
	}
	if !strings.Contains(err.Error(), "ipc_accepting") {
		t.Fatalf("error should name ipc_accepting, got: %v", err)
	}
	if n.readyCalls() != 0 {
		t.Fatalf("READY=1 must NOT be sent when a mandatory prereq is unmet (sent %d)", n.readyCalls())
	}
	snap := s.Snapshot()
	if snap.ReadySent {
		t.Fatalf("ready_sent must be false when readiness gate fails")
	}
}

// -----------------------------------------------------------------------------
// IPC_BOUND_DISTINCT_FROM_ACCEPTING
// -----------------------------------------------------------------------------

func TestLifecycle_IPCBoundDistinctFromAccepting(t *testing.T) {
	fc := &fakeClock{t: time.Unix(6500, 0)}
	s := newTestLifecycle(fc, nil)

	s.setIPCBound(true)
	snap := s.Snapshot()
	if !snap.IPCBound {
		t.Fatalf("ipc_bound not set")
	}
	if snap.IPCAccepting {
		t.Fatalf("ipc_accepting must remain false until the accept loop is serving")
	}
	s.setIPCAccepting(true)
	if !s.Snapshot().IPCAccepting {
		t.Fatalf("ipc_accepting should be true once serving")
	}
}

// -----------------------------------------------------------------------------
// READY_SENT_EXACTLY_ONCE
// -----------------------------------------------------------------------------

func TestLifecycle_ReadySentExactlyOnce(t *testing.T) {
	fc := &fakeClock{t: time.Unix(7000, 0)}
	n := &recNotifier{sent: true}
	s := newTestLifecycle(fc, n.fn)
	s.notifyExpected = true
	markAllMandatoryReady(s)

	if err := s.SendReady(); err != nil {
		t.Fatalf("first SendReady failed: %v", err)
	}
	// Repeated calls must not re-notify.
	_ = s.SendReady()
	_ = s.SendReady()

	if n.readyCalls() != 1 {
		t.Fatalf("READY=1 sent %d times, want exactly 1", n.readyCalls())
	}
}

// -----------------------------------------------------------------------------
// Test-only phase blocker: off by default, capped, matches only the named phase
// -----------------------------------------------------------------------------

func TestDebugBlockPhase(t *testing.T) {
	// Unset → no block (near-instant).
	t.Setenv("NFTBAN_DEBUG_BLOCK_PHASE", "")
	start := time.Now()
	debugBlockPhase(PhaseModulesInit)
	if time.Since(start) > 50*time.Millisecond {
		t.Fatalf("unset blocker should not sleep")
	}

	// Set but different phase → no block.
	t.Setenv("NFTBAN_DEBUG_BLOCK_PHASE", "IPC_SOCKET_INIT")
	t.Setenv("NFTBAN_DEBUG_BLOCK_MS", "5000")
	start = time.Now()
	debugBlockPhase(PhaseModulesInit)
	if time.Since(start) > 50*time.Millisecond {
		t.Fatalf("non-matching phase should not sleep")
	}

	// Matching phase, small ms → blocks ~that long.
	t.Setenv("NFTBAN_DEBUG_BLOCK_PHASE", "MODULES_INIT")
	t.Setenv("NFTBAN_DEBUG_BLOCK_MS", "60")
	start = time.Now()
	debugBlockPhase(PhaseModulesInit)
	if d := time.Since(start); d < 50*time.Millisecond {
		t.Fatalf("matching phase should block ~60ms, blocked %s", d)
	}

	// Invalid/zero ms → no block.
	for _, bad := range []string{"abc", "0", "-1", ""} {
		t.Setenv("NFTBAN_DEBUG_BLOCK_MS", bad)
		start = time.Now()
		debugBlockPhase(PhaseModulesInit)
		if time.Since(start) > 50*time.Millisecond {
			t.Fatalf("invalid ms %q should not sleep", bad)
		}
	}
}

// -----------------------------------------------------------------------------
// Startup-pending timeout override safety
//   PENDING_TIMEOUT_DEFAULT=60s / PENDING_TIMEOUT_INVALID_INPUT=SAFE
// -----------------------------------------------------------------------------

func TestResolveStartupPendingDelay(t *testing.T) {
	// Default (unset) = 2/3 of the 90s systemd default = 60s.
	t.Setenv("NFTBAN_STARTUP_PENDING_SEC", "")
	if got := resolveStartupPendingDelay(); got != 60*time.Second {
		t.Fatalf("default pending delay = %s, want 60s", got)
	}

	// Invalid / zero / negative must all SAFELY fall back to the default — they
	// must never disable the diagnostic.
	for _, bad := range []string{"abc", "0", "-5", "  ", "12x", "9999999999999999999999"} {
		t.Setenv("NFTBAN_STARTUP_PENDING_SEC", bad)
		if got := resolveStartupPendingDelay(); got != 60*time.Second {
			t.Fatalf("invalid input %q → %s, want safe default 60s", bad, got)
		}
	}

	// A valid positive override is honored (test-only tuning surface).
	t.Setenv("NFTBAN_STARTUP_PENDING_SEC", "3")
	if got := resolveStartupPendingDelay(); got != 3*time.Second {
		t.Fatalf("override 3 → %s, want 3s", got)
	}
}

// -----------------------------------------------------------------------------
// systemd-vs-direct-run readiness-notify semantics
//   DIRECT_RUN_WITHOUT_NOTIFY_SOCKET / SYSTEMD_MODE_READY_SUCCESS /
//   SYSTEMD_MODE_NOTIFY_ERROR_FATAL / SYSTEMD_MODE_NOT_SENT_FATAL /
//   READY_SENT_STATE_ONLY_AFTER_CONFIRMED_SEND
// -----------------------------------------------------------------------------

// DIRECT_RUN_WITHOUT_NOTIFY_SOCKET: NOTIFY_EXPECTED=NO, sent=false, err=nil is the
// normal terminal case and MUST NOT be fatal (daemon runs from a terminal).
func TestLifecycle_DirectRunWithoutNotifySocket(t *testing.T) {
	fc := &fakeClock{t: time.Unix(8000, 0)}
	n := &recNotifier{sent: false, err: nil}
	s := newTestLifecycle(fc, n.fn)
	s.notifyExpected = false // no NOTIFY_SOCKET
	markAllMandatoryReady(s)

	if err := s.SendReady(); err != nil {
		t.Fatalf("direct run (no NOTIFY_SOCKET) must not be fatal, got: %v", err)
	}
	snap := s.Snapshot()
	if snap.NotifyExpected {
		t.Fatalf("notify_expected should be false in direct run")
	}
	if !snap.ReadyAttempted {
		t.Fatalf("ready_attempted should be true")
	}
	if snap.ReadySent {
		t.Fatalf("ready_sent must be false when there is no socket to send to")
	}
}

// SYSTEMD_MODE_READY_SUCCESS: NOTIFY_EXPECTED=YES + sent=true + err=nil → ready.
// Also proves READY_SENT_STATE_ONLY_AFTER_CONFIRMED_SEND (sent true ⇒ ready_sent).
func TestLifecycle_SystemdModeReadySuccess(t *testing.T) {
	fc := &fakeClock{t: time.Unix(8100, 0)}
	n := &recNotifier{sent: true, err: nil}
	s := newTestLifecycle(fc, n.fn)
	s.notifyExpected = true
	markAllMandatoryReady(s)

	out := captureLog(t, func() {
		if err := s.SendReady(); err != nil {
			t.Fatalf("systemd-mode success must not error: %v", err)
		}
	})
	snap := s.Snapshot()
	if !snap.ReadySent {
		t.Fatalf("ready_sent must be true after a confirmed send")
	}
	if !strings.Contains(out, "phase=SYSTEMD_NOTIFY_READY state=complete") {
		t.Fatalf("expected SYSTEMD_NOTIFY_READY completion:\n%s", out)
	}
}

// SYSTEMD_MODE_NOTIFY_ERROR_FATAL: NOTIFY_EXPECTED=YES + err!=nil → FATAL.
func TestLifecycle_SystemdModeNotifyErrorFatal(t *testing.T) {
	fc := &fakeClock{t: time.Unix(8200, 0)}
	n := &recNotifier{sent: false, err: errors.New("write /run/systemd/notify: connection refused")}
	s := newTestLifecycle(fc, n.fn)
	s.notifyExpected = true
	markAllMandatoryReady(s)

	out := captureLog(t, func() {
		if err := s.SendReady(); err == nil {
			t.Fatalf("systemd-mode notify error MUST be fatal")
		}
	})
	snap := s.Snapshot()
	if snap.ReadySent {
		t.Fatalf("ready_sent must be false on notify error")
	}
	if strings.Contains(out, "phase=SYSTEMD_NOTIFY_READY state=complete") {
		t.Fatalf("SYSTEMD_NOTIFY_READY must NOT complete on notify error:\n%s", out)
	}
	if !strings.Contains(out, "state=failed") {
		t.Fatalf("expected failed phase on notify error:\n%s", out)
	}
}

// SYSTEMD_MODE_NOT_SENT_FATAL: NOTIFY_EXPECTED=YES + sent=false + err=nil → FATAL
// (READY undelivered though NOTIFY_SOCKET present).
func TestLifecycle_SystemdModeNotSentFatal(t *testing.T) {
	fc := &fakeClock{t: time.Unix(8300, 0)}
	n := &recNotifier{sent: false, err: nil}
	s := newTestLifecycle(fc, n.fn)
	s.notifyExpected = true
	markAllMandatoryReady(s)

	if err := s.SendReady(); err == nil {
		t.Fatalf("systemd-mode not-sent MUST be fatal")
	}
	if s.Snapshot().ReadySent {
		t.Fatalf("ready_sent must be false when READY was not delivered")
	}
}

// READY_SENT_STATE_ONLY_AFTER_CONFIRMED_SEND: ready_sent is true iff sent && !err,
// across the matrix.
func TestLifecycle_ReadySentOnlyAfterConfirmedSend(t *testing.T) {
	cases := []struct {
		name     string
		expected bool
		sent     bool
		err      error
		want     bool
	}{
		{"direct-nosocket", false, false, nil, false},
		{"systemd-ok", true, true, nil, true},
		{"systemd-err", true, false, errors.New("boom"), false},
		{"systemd-notsent", true, false, nil, false},
	}
	for i, c := range cases {
		fc := &fakeClock{t: time.Unix(int64(8400+i), 0)}
		n := &recNotifier{sent: c.sent, err: c.err}
		s := newTestLifecycle(fc, n.fn)
		s.notifyExpected = c.expected
		markAllMandatoryReady(s)
		_ = s.SendReady()
		if got := s.Snapshot().ReadySent; got != c.want {
			t.Fatalf("%s: ready_sent=%t want %t", c.name, got, c.want)
		}
	}
}

// -----------------------------------------------------------------------------
// STARTUP_PENDING_IDENTIFIES_BLOCKED_PHASE
// -----------------------------------------------------------------------------

func TestLifecycle_StartupPendingIdentifiesBlockedPhase(t *testing.T) {
	fc := &fakeClock{t: time.Unix(9000, 0)}
	s := newTestLifecycle(fc, nil)

	// Simulate a startup that reaches MODULES_INIT and then blocks.
	s.CompletePhase(PhaseProcessStart)
	s.BeginPhase(PhaseRuntimePathsInit, "paths")
	s.setRuntimePathsReady(true)
	s.CompletePhase(PhaseRuntimePathsInit)
	s.BeginPhase(PhaseModulesInit, "registry")

	var out string
	captured := captureLog(t, func() {
		s.startPendingWatch(20 * time.Millisecond)
		time.Sleep(80 * time.Millisecond)
	})
	out = captured
	if !strings.Contains(out, "event=startup_pending") {
		t.Fatalf("expected startup_pending emission, got:\n%s", out)
	}
	if !strings.Contains(out, "current_phase=MODULES_INIT") {
		t.Fatalf("startup_pending must name the blocked phase, got:\n%s", out)
	}
	if !strings.Contains(out, "last_completed_phase=RUNTIME_PATHS_INIT") {
		t.Fatalf("startup_pending must name last completed phase, got:\n%s", out)
	}
	if !strings.Contains(out, "ready_sent=false") {
		t.Fatalf("startup_pending should show ready_sent=false, got:\n%s", out)
	}
}

// -----------------------------------------------------------------------------
// STARTUP_PENDING_CANCELLED_AFTER_READY
// -----------------------------------------------------------------------------

func TestLifecycle_StartupPendingCancelledAfterReady(t *testing.T) {
	fc := &fakeClock{t: time.Unix(10000, 0)}
	n := &recNotifier{sent: true}
	s := newTestLifecycle(fc, n.fn)
	s.notifyExpected = true
	markAllMandatoryReady(s)

	out := captureLog(t, func() {
		s.startPendingWatch(50 * time.Millisecond)
		if err := s.SendReady(); err != nil { // resolves pending
			t.Fatalf("SendReady failed: %v", err)
		}
		time.Sleep(120 * time.Millisecond)
	})
	if strings.Contains(out, "event=startup_pending") {
		t.Fatalf("startup_pending must be cancelled after READY, got:\n%s", out)
	}
}

// -----------------------------------------------------------------------------
// STARTUP_PENDING_CANCELLED_ON_FAILURE
// -----------------------------------------------------------------------------

func TestLifecycle_StartupPendingCancelledOnFailure(t *testing.T) {
	fc := &fakeClock{t: time.Unix(11000, 0)}
	s := newTestLifecycle(fc, nil)

	out := captureLog(t, func() {
		s.startPendingWatch(50 * time.Millisecond)
		s.BeginPhase(PhaseIPCSocketInit, "ipc")
		s.FailPhase(PhaseIPCSocketInit, errors.New("bind failed")) // resolves pending
		time.Sleep(120 * time.Millisecond)
	})
	if strings.Contains(out, "event=startup_pending") {
		t.Fatalf("startup_pending must be cancelled on phase failure, got:\n%s", out)
	}
}

// -----------------------------------------------------------------------------
// SHUTDOWN_PHASE_ORDERING
// -----------------------------------------------------------------------------

func TestLifecycle_ShutdownPhaseOrdering(t *testing.T) {
	fc := &fakeClock{t: time.Unix(12000, 0)}
	n := &recNotifier{sent: true}
	s := newTestLifecycle(fc, n.fn)

	out := captureLog(t, func() {
		s.beginShutdown()
		s.completeShutdown()
	})
	beginIdx := strings.Index(out, "phase=SHUTDOWN_BEGIN")
	completeIdx := strings.Index(out, "phase=SHUTDOWN_COMPLETE")
	if beginIdx < 0 || completeIdx < 0 {
		t.Fatalf("missing shutdown phase events:\n%s", out)
	}
	if beginIdx > completeIdx {
		t.Fatalf("SHUTDOWN_BEGIN must precede SHUTDOWN_COMPLETE:\n%s", out)
	}
	snap := s.Snapshot()
	if !snap.ShutdownStarted {
		t.Fatalf("shutdown_started should be true")
	}
	// STATUS= "shutting down" pushed to systemd.
	found := false
	for _, st := range n.statusStates() {
		if strings.Contains(st, "shutting down") {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected STATUS= shutting down, got %v", n.statusStates())
	}
}

// -----------------------------------------------------------------------------
// ERROR_SANITIZATION
// -----------------------------------------------------------------------------

func TestLifecycle_ErrorSanitization(t *testing.T) {
	// Multi-line + overlong error must become a single bounded line.
	long := strings.Repeat("A", 500)
	err := errors.New("line1\nline2\r\ttabbed " + long)
	got := sanitizeErr(err)
	if strings.ContainsAny(got, "\n\r\t") {
		t.Fatalf("sanitized error still contains control chars: %q", got)
	}
	if len(got) > 230 { // 200 + truncation marker
		t.Fatalf("sanitized error too long (%d): %q", len(got), got)
	}
	if !strings.Contains(got, "truncated") {
		t.Fatalf("expected truncation marker, got: %q", got)
	}
	// A nil error sanitizes to the empty string (no error); the log layer renders
	// empty as "-".
	if sanitizeErr(nil) != "" {
		t.Fatalf("nil error should sanitize to empty, got %q", sanitizeErr(nil))
	}
}

// -----------------------------------------------------------------------------
// NO_SECRET_VALUES_IN_LIFECYCLE_LOGS
// -----------------------------------------------------------------------------

func TestLifecycle_NoSecretValuesInLogs(t *testing.T) {
	fc := &fakeClock{t: time.Unix(13000, 0)}
	n := &recNotifier{sent: true}
	s := newTestLifecycle(fc, n.fn)
	markAllMandatoryReady(s)

	// Plant a "secret" in the environment and confirm no phase event echoes it.
	const secret = "SUPER_SECRET_TOKEN_deadbeef"
	t.Setenv("NFTBAN_FAKE_SECRET", secret)

	out := captureLog(t, func() {
		s.BeginPhase(PhaseModulesInit, "registry")
		s.CompletePhase(PhaseModulesInit)
		_ = s.SendReady()
		s.enterRunning()
	})
	if strings.Contains(out, secret) {
		t.Fatalf("lifecycle log leaked an environment secret:\n%s", out)
	}
	// Structured lines carry only phase/state/component/timing/sanitized-error.
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if strings.HasPrefix(line, "event=startup_phase") && !strings.Contains(line, "component=") {
			t.Fatalf("phase line missing component field (unexpected shape): %q", line)
		}
	}
}

// -----------------------------------------------------------------------------
// STATUS= phase updates surfaced through the notifier
// -----------------------------------------------------------------------------

func TestLifecycle_StatusNotifyPhaseUpdates(t *testing.T) {
	fc := &fakeClock{t: time.Unix(14000, 0)}
	n := &recNotifier{sent: true}
	s := newTestLifecycle(fc, n.fn)
	s.notifyExpected = true

	s.BeginPhase(PhaseModulesInit, "registry")
	markAllMandatoryReady(s)
	_ = s.SendReady()
	s.enterRunning() // must NOT clobber the ready status

	var sawPhase, sawReady bool
	for _, st := range n.statusStates() {
		if strings.Contains(st, "STATUS=NFTBan startup: MODULES_INIT") {
			sawPhase = true
		}
		if strings.Contains(st, "STATUS=NFTBan ready") {
			sawReady = true
		}
	}
	if !sawPhase {
		t.Fatalf("expected STATUS= phase update, got %v", n.statusStates())
	}
	if !sawReady {
		t.Fatalf("expected STATUS=NFTBan ready, got %v", n.statusStates())
	}
	// The steady-state STATUS after entering RUNNING must remain "NFTBan ready" —
	// RUNNING/shutdown-begin phases must not emit a "startup: <phase>" status.
	states := n.statusStates()
	last := states[len(states)-1]
	if !strings.Contains(last, "NFTBan ready") {
		t.Fatalf("final STATUS should stay 'NFTBan ready', got %q", last)
	}
	for _, st := range states {
		if strings.Contains(st, "startup: RUNNING") {
			t.Fatalf("RUNNING must not emit a startup: status: %q", st)
		}
	}
}
