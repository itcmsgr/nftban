// =============================================================================
// NFTBan v1.0 - nftband Daemon - Startup lifecycle state machine and readiness
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Canonical daemon startup lifecycle: phase state machine, readiness gate, startup-pending diagnostic, and structured phase logging"
//
// meta:inventory.files="/usr/lib/nftban/bin/nftband"
// meta:inventory.binaries="nftband"
// meta:inventory.env_vars="NFTBAN_STARTUP_PENDING_SEC"
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units="nftband.service, nftband.socket"
// meta:inventory.network="/run/nftban/nftband.sock (Unix)"
// meta:inventory.privileges="root"
// =============================================================================
//
// This file owns the ONE canonical, concurrency-safe startup lifecycle state for
// the daemon. Readiness is made explicit here rather than inferred from startup
// ordering: a socket may already be bound and accepting before modules finish and
// before READY=1 is sent, so the state distinguishes ipc_bound from ipc_accepting
// and gates the systemd READY=1 notification on a set of mandatory prerequisites.
//
// The lifecycle instrumentation does NOT change the underlying startup ORDER — it
// records phase transitions around the existing sequence and exposes the result
// through the journal (structured `event=startup_phase` lines), sd_notify STATUS=,
// and the status IPC. All surfaces render this one snapshot; there is no second
// authority.
// =============================================================================

package main

import (
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// LifecyclePhase identifies a discrete daemon startup/shutdown phase. Phases map
// to real code boundaries in daemon_init.go / daemon_socket.go / daemon_lifecycle.go.
type LifecyclePhase string

const (
	PhaseProcessStart           LifecyclePhase = "PROCESS_START"
	PhaseRuntimePathsInit       LifecyclePhase = "RUNTIME_PATHS_INIT"
	PhaseNFTManagerInit         LifecyclePhase = "NFT_MANAGER_INIT"
	PhaseOpQueueInit            LifecyclePhase = "OPQUEUE_INIT"
	PhaseConfigLoad             LifecyclePhase = "CONFIG_LOAD"
	PhaseModulesInit            LifecyclePhase = "MODULES_INIT"
	PhaseIPCSocketInit          LifecyclePhase = "IPC_SOCKET_INIT"
	PhaseHTTPInit               LifecyclePhase = "HTTP_INIT"
	PhaseWorkersStart           LifecyclePhase = "WORKERS_START"
	PhaseReadinessPrerequisites LifecyclePhase = "READINESS_PRECONDITIONS"
	PhaseSystemdNotifyReady     LifecyclePhase = "SYSTEMD_NOTIFY_READY"
	PhaseRunning                LifecyclePhase = "RUNNING"
	PhaseShutdownBegin          LifecyclePhase = "SHUTDOWN_BEGIN"
	PhaseShutdownComplete       LifecyclePhase = "SHUTDOWN_COMPLETE"
)

// phaseState is the transition state recorded for the current phase.
const (
	stateBegin    = "begin"
	stateComplete = "complete"
	stateFailed   = "failed"
	stateDegraded = "degraded"
)

// phaseOrder gives a monotonic ordinal per phase so backwards transitions can be
// detected and rejected. Only used for validation; it never reorders execution.
var phaseOrder = map[LifecyclePhase]int{
	PhaseProcessStart:           0,
	PhaseRuntimePathsInit:       1,
	PhaseNFTManagerInit:         2,
	PhaseOpQueueInit:            3,
	PhaseConfigLoad:             4,
	PhaseModulesInit:            5,
	PhaseIPCSocketInit:          6,
	PhaseHTTPInit:               7,
	PhaseWorkersStart:           8,
	PhaseReadinessPrerequisites: 9,
	PhaseSystemdNotifyReady:     10,
	PhaseRunning:                11,
	PhaseShutdownBegin:          12,
	PhaseShutdownComplete:       13,
}

// systemd nftband.service has no explicit TimeoutStartSec, so systemd applies its
// default (DefaultTimeoutStartSec, 90s on typical distros). The startup-pending
// diagnostic must fire BEFORE that deadline so the blocked phase is captured in the
// journal while the unit is still "activating" — 2/3 of the default gives headroom.
const systemdDefaultStartTimeout = 90 * time.Second

var defaultStartupPendingDelay = systemdDefaultStartTimeout * 2 / 3 // 60s

// notifyFunc matches coreos/go-systemd daemon.SdNotify(false, state) — (sent, err).
// A nil notifier means "not wired" (unit tests / non-systemd) and is a no-op.
type notifyFunc func(state string) (bool, error)

// LifecycleSnapshot is an immutable copy of the lifecycle state for rendering by
// operator surfaces (status IPC, health). Field names are stable additive contract.
type LifecycleSnapshot struct {
	Phase                  LifecyclePhase `json:"phase"`
	LastCompletedPhase     LifecyclePhase `json:"last_completed_phase"`
	State                  string         `json:"state"`
	Ready                  bool           `json:"ready"`
	ReadyAttempted         bool           `json:"ready_attempted"`
	ReadySent              bool           `json:"ready_sent"`
	NotifyExpected         bool           `json:"notify_expected"`
	ShutdownStarted        bool           `json:"shutdown_started"`
	RuntimePathsReady      bool           `json:"runtime_paths_ready"`
	NFTReady               bool           `json:"nft_ready"`
	OpQueueReady           bool           `json:"opqueue_ready"`
	ModulesInitialized     bool           `json:"modules_initialized"`
	IPCBound               bool           `json:"ipc_bound"`
	IPCAccepting           bool           `json:"ipc_accepting"`
	HTTPReady              bool           `json:"http_ready"`
	HTTPDisabledByDesign   bool           `json:"http_disabled_by_design"`
	RequiredModulesStarted bool           `json:"required_modules_started"`
	WatchdogReady          bool           `json:"watchdog_ready"`
	DegradedComponents     []string       `json:"degraded_components"`
	MainPID                int            `json:"main_pid"`
	PhaseElapsedMs         int64          `json:"phase_elapsed_ms"`
	TotalElapsedMs         int64          `json:"total_elapsed_ms"`
}

// startupLifecycle is the single canonical, mutex-protected lifecycle state.
type startupLifecycle struct {
	mu sync.Mutex

	currentPhase       LifecyclePhase
	lastCompletedPhase LifecyclePhase
	phaseState         string
	phaseError         string

	startupStartedAt time.Time
	phaseStartedAt   time.Time
	mainPID          int

	// Readiness signals (see evaluateReadinessLocked for mandatory vs degradable).
	runtimePathsReady      bool
	nftReady               bool
	opqueueReady           bool
	modulesInitialized     bool
	ipcBound               bool
	ipcAccepting           bool
	httpReady              bool
	httpDisabledByDesign   bool // v1.229.2 TRACK A — HTTP optional-by-design (EADDRINUSE)
	requiredModulesStarted bool
	watchdogReady          bool

	// Separate ATTEMPT from RESULT — ready_sent must reflect the actual notify
	// outcome and must not be set true before SdNotifyReady reports success.
	readyAttempted  bool
	readySent       bool
	shutdownStarted bool

	// notifyExpected records whether NOTIFY_SOCKET was present for the MAIN process
	// at startup (captured before any child sanitization). It decides whether a
	// failed/undelivered READY=1 is fatal (Type=notify service) or benign (a direct
	// terminal run with no service manager). See SendReady.
	notifyExpected bool

	degradedComponents []string
	degradedSeen       map[string]bool

	// Injectable seams for tests.
	now      func() time.Time
	notifier notifyFunc

	// READY=1 exactly-once guard.
	readyOnce sync.Once

	// startup-pending diagnostic: emitted at most once, cancellable.
	pendingOnce    sync.Once
	pendingResolve chan struct{}
	pendingResolvd sync.Once
}

// newStartupLifecycle creates the canonical lifecycle with the real clock. The
// caller wires a notifier (SdNotify) via setNotifier once systemd context exists.
func newStartupLifecycle(mainPID int) *startupLifecycle {
	now := time.Now()
	return &startupLifecycle{
		currentPhase:     PhaseProcessStart,
		phaseState:       stateBegin,
		phaseError:       "",
		startupStartedAt: now,
		phaseStartedAt:   now,
		mainPID:          mainPID,
		// Snapshot NOTIFY_SOCKET presence for the MAIN process now, before any
		// child process is launched/sanitized, so the readiness gate can tell a
		// systemd Type=notify run from a direct terminal run.
		notifyExpected: os.Getenv("NOTIFY_SOCKET") != "",
		degradedSeen:   map[string]bool{},
		pendingResolve: make(chan struct{}),
		now:            time.Now,
	}
}

func (s *startupLifecycle) setNotifier(fn notifyFunc) {
	s.mu.Lock()
	s.notifier = fn
	s.mu.Unlock()
}

// -----------------------------------------------------------------------------
// Phase API — BeginPhase / CompletePhase / FailPhase / DegradePhase
// -----------------------------------------------------------------------------

// BeginPhase records entry into a phase. The canonical state is updated BEFORE the
// caller enters the (possibly blocking) synchronous work, so the startup-pending
// diagnostic can report the phase that is actually stuck. Backwards transitions are
// logged and rejected (they indicate a programming error, not real progress).
func (s *startupLifecycle) BeginPhase(phase LifecyclePhase, component string) {
	s.mu.Lock()
	if !s.validTransitionLocked(phase) {
		cur := s.currentPhase
		s.mu.Unlock()
		log.Printf("event=startup_phase phase=%s state=invalid_transition pid=%d component=%s error=%s",
			phase, s.mainPID, component, sanitizeLogValue(fmt.Sprintf("rejected transition from %s", cur)))
		return
	}
	s.currentPhase = phase
	s.phaseState = stateBegin
	s.phaseError = ""
	s.phaseStartedAt = s.now()
	total := s.now().Sub(s.startupStartedAt).Milliseconds()
	notifier := s.notifier
	pid := s.mainPID
	s.mu.Unlock()

	emitPhase(phase, stateBegin, pid, component, 0, total, "")
	// Only STARTUP phases push a "NFTBan startup: <phase>" systemd STATUS=. RUNNING
	// and the shutdown phases have their own steady-state statuses ("NFTBan ready"
	// from SendReady, "NFTBan shutting down" from beginShutdown); auto-sending here
	// would clobber them (RUNNING runs right after READY).
	if phase != PhaseRunning && phase != PhaseShutdownBegin && phase != PhaseShutdownComplete {
		sendStatus(notifier, fmt.Sprintf("NFTBan startup: %s", phase))
	}

	// Test-only bounded startup blocker. Empty/unset in production (verified: no
	// unit/package sets it). If this phase matches NFTBAN_DEBUG_BLOCK_PHASE, sleep
	// up to NFTBAN_DEBUG_BLOCK_MS (hard-capped) so the startup-pending diagnostic
	// can be exercised deterministically without an uncontrolled hang. The mutex is
	// NOT held during the sleep, so Snapshot()/status IPC/pending diag stay live.
	debugBlockPhase(phase)
}

// debugBlockCapMs hard-caps the test-only phase block so it can never hang a real
// unit past its start timeout.
const debugBlockCapMs = 30000

func debugBlockPhase(phase LifecyclePhase) {
	if os.Getenv("NFTBAN_DEBUG_BLOCK_PHASE") != string(phase) {
		return
	}
	ms, err := strconv.Atoi(os.Getenv("NFTBAN_DEBUG_BLOCK_MS"))
	if err != nil || ms <= 0 {
		return
	}
	if ms > debugBlockCapMs {
		ms = debugBlockCapMs
	}
	log.Printf("event=startup_debug_block phase=%s block_ms=%d (test-only NFTBAN_DEBUG_BLOCK_PHASE)", phase, ms)
	time.Sleep(time.Duration(ms) * time.Millisecond)
}

// CompletePhase records successful completion of a phase.
func (s *startupLifecycle) CompletePhase(phase LifecyclePhase) {
	s.finishPhase(phase, stateComplete, "", "")
}

// FailPhase records a fatal failure of a phase (the daemon will not become ready).
func (s *startupLifecycle) FailPhase(phase LifecyclePhase, err error) {
	s.finishPhase(phase, stateFailed, "", sanitizeErr(err))
}

// DegradePhase records that a phase completed but a DEGRADABLE component is
// unavailable. The daemon may still reach readiness, but the degraded component is
// recorded, surfaced through status IPC, and must never be reported as healthy.
func (s *startupLifecycle) DegradePhase(phase LifecyclePhase, component string, err error) {
	s.finishPhase(phase, stateDegraded, component, sanitizeErr(err))
}

func (s *startupLifecycle) finishPhase(phase LifecyclePhase, state, component, errStr string) {
	s.mu.Lock()
	// Record completion timing relative to when this phase began.
	elapsed := s.now().Sub(s.phaseStartedAt).Milliseconds()
	total := s.now().Sub(s.startupStartedAt).Milliseconds()
	s.phaseState = state
	s.phaseError = errStr
	if state == stateComplete || state == stateDegraded {
		s.lastCompletedPhase = phase
	}
	if state == stateDegraded && component != "" && !s.degradedSeen[component] {
		s.degradedSeen[component] = true
		s.degradedComponents = append(s.degradedComponents, component)
	}
	notifier := s.notifier
	pid := s.mainPID
	s.mu.Unlock()

	logComponent := component
	if logComponent == "" {
		logComponent = string(phase)
	}
	emitPhase(phase, state, pid, logComponent, elapsed, total, errStr)

	switch state {
	case stateDegraded:
		sendStatus(notifier, fmt.Sprintf("NFTBan startup degraded: %s", phase))
	case stateFailed:
		// A failed phase resolves the pending diagnostic — startup is not going to
		// reach READY on this path.
		s.resolvePending()
	}
}

// validTransitionLocked rejects strictly-backwards phase transitions. Re-entering
// the SAME phase is allowed (idempotent begin); forward moves are allowed.
func (s *startupLifecycle) validTransitionLocked(next LifecyclePhase) bool {
	no, ok := phaseOrder[next]
	if !ok {
		return false
	}
	co := phaseOrder[s.currentPhase]
	return no >= co
}

// -----------------------------------------------------------------------------
// Readiness signal setters (each is a single canonical write).
// -----------------------------------------------------------------------------

func (s *startupLifecycle) setRuntimePathsReady(v bool)      { s.setFlag(&s.runtimePathsReady, v) }
func (s *startupLifecycle) setNFTReady(v bool)               { s.setFlag(&s.nftReady, v) }
func (s *startupLifecycle) setOpQueueReady(v bool)           { s.setFlag(&s.opqueueReady, v) }
func (s *startupLifecycle) setModulesInitialized(v bool)     { s.setFlag(&s.modulesInitialized, v) }
func (s *startupLifecycle) setIPCBound(v bool)               { s.setFlag(&s.ipcBound, v) }
func (s *startupLifecycle) setIPCAccepting(v bool)           { s.setFlag(&s.ipcAccepting, v) }
func (s *startupLifecycle) setHTTPReady(v bool)              { s.setFlag(&s.httpReady, v) }
func (s *startupLifecycle) setHTTPDisabledByDesign(v bool)   { s.setFlag(&s.httpDisabledByDesign, v) }
func (s *startupLifecycle) setRequiredModulesStarted(v bool) { s.setFlag(&s.requiredModulesStarted, v) }
func (s *startupLifecycle) setWatchdogReady(v bool)          { s.setFlag(&s.watchdogReady, v) }

func (s *startupLifecycle) setFlag(field *bool, v bool) {
	s.mu.Lock()
	*field = v
	s.mu.Unlock()
}

// -----------------------------------------------------------------------------
// Readiness gate + READY=1 notification
// -----------------------------------------------------------------------------

// evaluateReadinessLocked returns the list of unmet MANDATORY prerequisites and the
// list of unavailable DEGRADABLE components. Mandatory prerequisites must all hold
// before READY=1 is sent; degradable components may be absent (the daemon reports
// ready-but-degraded rather than blocking).
func (s *startupLifecycle) evaluateReadinessLocked() (missing, degraded []string) {
	if !s.runtimePathsReady {
		missing = append(missing, "runtime_paths_ready")
	}
	if !s.modulesInitialized {
		missing = append(missing, "modules_initialized")
	}
	if !s.ipcBound {
		missing = append(missing, "ipc_bound")
	}
	if !s.ipcAccepting {
		missing = append(missing, "ipc_accepting")
	}
	// v1.229.2 TRACK A — HTTP READINESS TIER.
	//
	// The HTTP API is optional by design: when another service owns the port the
	// daemon runs IPC-only and MUST still be allowed to reach READY. Previously
	// http_ready sat unconditionally in the MANDATORY tier, and startup papered
	// over that by asserting setHTTPReady(true) even when no server existed —
	// systemd was told a mandatory prerequisite was met by a component that was
	// never created.
	//
	// Simply reporting httpReady=false when disabled would have been the opposite
	// error: it would place http_ready in `missing`, making an intentional
	// port collision a FATAL startup failure.
	//
	// So disabled-by-design joins the DEGRADED tier, where nft, opqueue and
	// watchdog already live: honest state, READY=1 still permitted. A genuine bind
	// failure never reaches here at all — startHTTP returns an error and startup
	// fails at the producer.
	if s.httpDisabledByDesign {
		degraded = append(degraded, "http")
	} else if !s.httpReady {
		missing = append(missing, "http_ready")
	}
	if !s.requiredModulesStarted {
		missing = append(missing, "required_modules_started")
	}
	if !s.nftReady {
		degraded = append(degraded, "nft")
	}
	if !s.opqueueReady {
		degraded = append(degraded, "opqueue")
	}
	if !s.watchdogReady {
		degraded = append(degraded, "watchdog")
	}
	return missing, degraded
}

// SendReady evaluates the readiness contract and, if the mandatory prerequisites
// hold, sends systemd READY=1 exactly once. It returns a fatal error when a
// mandatory prerequisite is unmet — the caller must then fail startup WITHOUT
// sending READY=1. A failure of the SdNotify call itself is material but non-fatal
// (retains prior semantics): it is logged and recorded, ready_sent reflects the
// actual result, and the SYSTEMD_NOTIFY_READY phase is only marked complete on a
// clean call.
func (s *startupLifecycle) SendReady() error {
	// Idempotent: once a ready attempt has been made, further calls are no-ops.
	s.mu.Lock()
	alreadyAttempted := s.readyAttempted
	s.mu.Unlock()
	if alreadyAttempted {
		return nil
	}

	s.BeginPhase(PhaseReadinessPrerequisites, "readiness")

	s.mu.Lock()
	missing, degraded := s.evaluateReadinessLocked()
	notifier := s.notifier
	s.mu.Unlock()

	if len(missing) > 0 {
		err := fmt.Errorf("readiness prerequisites unmet: %s", strings.Join(missing, ","))
		s.FailPhase(PhaseReadinessPrerequisites, err)
		return err
	}

	if len(degraded) > 0 {
		s.DegradePhase(PhaseReadinessPrerequisites, strings.Join(degraded, ","), nil)
	} else {
		s.CompletePhase(PhaseReadinessPrerequisites)
	}

	// The systemd READY=1 notification and its result handling run EXACTLY ONCE.
	// ready_attempted is recorded here (inside the guard); ready_sent reflects a
	// CONFIRMED send only. The outcome is classified by whether systemd
	// notification was expected (NOTIFY_SOCKET present for the main process):
	//
	//   NOTIFY_EXPECTED=NO  + sent=false + err=nil        → direct run, non-fatal
	//   NOTIFY_EXPECTED=YES + sent=true  + err=nil        → ready
	//   NOTIFY_EXPECTED=YES + (err!=nil OR not delivered) → FATAL startup failure
	//
	// The fatal cases are the whole point of this gate: under a Type=notify unit,
	// a daemon that keeps running without delivering READY=1 leaves systemd in
	// "activating" until TimeoutStartSec — the exact ambiguity this lane removes.
	var fatal error
	s.readyOnce.Do(func() {
		s.BeginPhase(PhaseSystemdNotifyReady, "systemd")

		s.mu.Lock()
		s.readyAttempted = true
		expected := s.notifyExpected
		s.mu.Unlock()

		var sent bool
		var notifyErr error
		if notifier != nil {
			sent, notifyErr = notifier("READY=1")
		}

		s.mu.Lock()
		s.readySent = sent && notifyErr == nil
		s.mu.Unlock()

		switch {
		case !expected:
			// Direct terminal run: no service manager to be ready to. sent=false/
			// err=nil is the normal terminal case and is NOT a failure.
			if notifyErr != nil {
				log.Printf("sd_notify READY returned an error with no NOTIFY_SOCKET (direct run), ignoring: %v", sanitizeErr(notifyErr))
			}
			s.CompletePhase(PhaseSystemdNotifyReady)
		case notifyErr != nil:
			// Type=notify unit, READY delivery errored → FATAL.
			log.Printf("sd_notify READY failed under systemd (NOTIFY_SOCKET present): %v", sanitizeErr(notifyErr))
			s.FailPhase(PhaseSystemdNotifyReady, notifyErr)
			fatal = fmt.Errorf("sd_notify READY failed under systemd: %w", notifyErr)
		case !sent:
			// Type=notify unit, but READY was not delivered → FATAL.
			e := fmt.Errorf("sd_notify READY not delivered though NOTIFY_SOCKET is present")
			log.Printf("%v", e)
			s.FailPhase(PhaseSystemdNotifyReady, e)
			fatal = e
		default:
			log.Println("sd_notify READY sent")
			sendStatus(notifier, "NFTBan ready")
			s.CompletePhase(PhaseSystemdNotifyReady)
		}

		// Resolve the pending diagnostic on every terminal outcome (success →
		// ready; fatal → fail fast). FailPhase already resolves it; idempotent.
		s.resolvePending()
	})
	return fatal
}

// enterRunning marks the daemon as running (post-ready steady state).
func (s *startupLifecycle) enterRunning() {
	s.BeginPhase(PhaseRunning, "daemon")
	s.CompletePhase(PhaseRunning)
}

// beginShutdown / completeShutdown record the shutdown phases in order.
func (s *startupLifecycle) beginShutdown() {
	s.mu.Lock()
	s.shutdownStarted = true
	notifier := s.notifier
	s.mu.Unlock()
	s.resolvePending()
	s.BeginPhase(PhaseShutdownBegin, "daemon")
	sendStatus(notifier, "NFTBan shutting down")
	s.CompletePhase(PhaseShutdownBegin)
}

func (s *startupLifecycle) completeShutdown() {
	s.BeginPhase(PhaseShutdownComplete, "daemon")
	s.CompletePhase(PhaseShutdownComplete)
}

// -----------------------------------------------------------------------------
// Startup-pending diagnostic
// -----------------------------------------------------------------------------

// startPendingWatch launches a single bounded timer that, if READY has not been
// sent (and startup has not failed or begun shutdown) by the deadline, emits ONE
// `event=startup_pending` line naming the current/last-completed phase so the
// blocked phase is captured in the journal before systemd's start timeout. The
// timer never mutates readiness state.
func (s *startupLifecycle) startPendingWatch(delay time.Duration) {
	go func() {
		timer := time.NewTimer(delay)
		defer timer.Stop()
		select {
		case <-s.pendingResolve:
			return
		case <-timer.C:
			s.emitPending()
		}
	}()
}

func (s *startupLifecycle) resolvePending() {
	s.pendingResolvd.Do(func() {
		close(s.pendingResolve)
	})
}

func (s *startupLifecycle) emitPending() {
	s.pendingOnce.Do(func() {
		s.mu.Lock()
		if s.readySent || s.shutdownStarted || s.phaseState == stateFailed {
			s.mu.Unlock()
			return
		}
		snap := s.snapshotLocked()
		s.mu.Unlock()

		log.Printf("event=startup_pending last_completed_phase=%s current_phase=%s "+
			"phase_elapsed_ms=%d total_elapsed_ms=%d main_pid=%d ipc_bound=%t ipc_accepting=%t "+
			"nft_ready=%t opqueue_ready=%t required_modules_started=%t ready_attempted=%t ready_sent=%t",
			snap.LastCompletedPhase, snap.Phase, snap.PhaseElapsedMs, snap.TotalElapsedMs, snap.MainPID,
			snap.IPCBound, snap.IPCAccepting, snap.NFTReady, snap.OpQueueReady,
			snap.RequiredModulesStarted, snap.ReadyAttempted, snap.ReadySent)
	})
}

// -----------------------------------------------------------------------------
// Snapshot
// -----------------------------------------------------------------------------

// Snapshot returns an immutable copy of the canonical state for rendering.
func (s *startupLifecycle) Snapshot() LifecycleSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.snapshotLocked()
}

func (s *startupLifecycle) snapshotLocked() LifecycleSnapshot {
	ready := s.readySent
	// make() returns a non-nil (possibly empty) slice, so this always marshals to
	// a JSON array rather than null.
	degraded := make([]string, len(s.degradedComponents))
	copy(degraded, s.degradedComponents)
	return LifecycleSnapshot{
		Phase:                  s.currentPhase,
		LastCompletedPhase:     s.lastCompletedPhase,
		State:                  s.phaseState,
		Ready:                  ready,
		ReadyAttempted:         s.readyAttempted,
		ReadySent:              s.readySent,
		NotifyExpected:         s.notifyExpected,
		ShutdownStarted:        s.shutdownStarted,
		RuntimePathsReady:      s.runtimePathsReady,
		NFTReady:               s.nftReady,
		OpQueueReady:           s.opqueueReady,
		ModulesInitialized:     s.modulesInitialized,
		IPCBound:               s.ipcBound,
		IPCAccepting:           s.ipcAccepting,
		HTTPReady:              s.httpReady,
		HTTPDisabledByDesign:   s.httpDisabledByDesign,
		RequiredModulesStarted: s.requiredModulesStarted,
		WatchdogReady:          s.watchdogReady,
		DegradedComponents:     degraded,
		MainPID:                s.mainPID,
		PhaseElapsedMs:         s.now().Sub(s.phaseStartedAt).Milliseconds(),
		TotalElapsedMs:         s.now().Sub(s.startupStartedAt).Milliseconds(),
	}
}

// -----------------------------------------------------------------------------
// Emit + sanitize helpers
// -----------------------------------------------------------------------------

// emitPhase writes the single structured phase event to the journal (primary event
// stream). Other surfaces render the canonical snapshot; they do not re-emit this.
func emitPhase(phase LifecyclePhase, state string, pid int, component string, elapsedMs, totalMs int64, errStr string) {
	if errStr == "" {
		errStr = "-"
	}
	log.Printf("event=startup_phase phase=%s state=%s pid=%d component=%s elapsed_ms=%d total_elapsed_ms=%d error=%s",
		phase, state, pid, component, elapsedMs, totalMs, errStr)
}

// sendStatus pushes a bounded sd_notify STATUS= line. Best-effort and degradable:
// failures are ignored (STATUS= is a convenience surface, not the ready contract).
// The text is a fixed phrase plus a phase name — never a raw error, config value,
// or path.
func sendStatus(notifier notifyFunc, text string) {
	if notifier == nil {
		return
	}
	if len(text) > 120 {
		text = text[:120]
	}
	_, _ = notifier("STATUS=" + text)
}

// sanitizeErr converts an error into a bounded, single-line, safe log value.
func sanitizeErr(err error) string {
	if err == nil {
		return ""
	}
	return sanitizeLogValue(err.Error())
}

// sanitizeLogValue strips newlines/tabs and bounds length so a phase error cannot
// inject extra log lines or dump large/sensitive payloads. It intentionally keeps
// only a short, bounded fragment.
func sanitizeLogValue(v string) string {
	v = strings.ReplaceAll(v, "\n", " ")
	v = strings.ReplaceAll(v, "\r", " ")
	v = strings.ReplaceAll(v, "\t", " ")
	v = strings.TrimSpace(v)
	const maxLen = 200
	if len(v) > maxLen {
		v = v[:maxLen] + "…(truncated)"
	}
	if v == "" {
		return "-"
	}
	return v
}

// resolveStartupPendingDelay derives the pending-diagnostic delay. Default is 2/3
// of the systemd default start timeout; NFTBAN_STARTUP_PENDING_SEC overrides it
// (used for tuning and by tests to avoid real 60s/90s sleeps).
func resolveStartupPendingDelay() time.Duration {
	if v := os.Getenv("NFTBAN_STARTUP_PENDING_SEC"); v != "" {
		if secs, err := strconv.Atoi(v); err == nil && secs > 0 {
			return time.Duration(secs) * time.Second
		}
	}
	return defaultStartupPendingDelay
}
