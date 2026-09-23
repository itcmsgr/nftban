// =============================================================================
// NFTBan v1.73 - Installer State File I/O
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-state-file"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="State file struct, atomic write, read, transition persistence"
// meta:inventory.files="internal/installer/state/file.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/var/lib/nftban/state/install_state"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package state

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// DefaultStateDir is the standard location for install state.
const DefaultStateDir = "/var/lib/nftban/state"

// StateFileName is the install state file name.
const StateFileName = "install_state"

// LockFileName is the V125 R-2 installer concurrent-run lock file name.
// Lives alongside install_state so it shares the same state-dir lifecycle.
// Consumed by internal/installer/lock via LockFilePath().
const LockFileName = "installer.lock"

// LockFilePath returns the full path to the installer concurrent-run lock
// file given a state-dir. If stateDir is empty, DefaultStateDir is used —
// matches NewStateFile's empty-stateDir fallback so the two file paths
// always share a parent directory.
func LockFilePath(stateDir string) string {
	if stateDir == "" {
		stateDir = DefaultStateDir
	}
	return filepath.Join(stateDir, LockFileName)
}

// StateFile holds all install state and handles persistence.
//
// Schema contract (frozen):
//
//	INSTALL_STATE       — current InstallState enum value
//	INSTALL_MODE        — "install" or "upgrade"
//	INSTALL_VERSION     — version string (e.g. "1.73.0")
//	INSTALL_TIMESTAMP   — RFC3339 UTC timestamp
//	SSH_PORT            — detected SSH port (int)
//	AUTHORITY           — "UPDATE", "TAKEOVER", "FRESH", or ""
//	PANEL               — detected panel type or ""
//	CONFLICTS           — comma-separated conflict names or ""
//	SCHEMA_VERSION      — nftables schema version (e.g. "0.7.3")
//	PHASE_REACHED       — last phase name reached
//	FAILURE_REASON      — human-readable failure description or ""
//	PREFLIGHT_PASSED    — "1" or "0"
//	CONVERGENCE_VERIFIED — post-update convergence verdict (v1.230.0 Gate 6R)
//	REBUILD_EXIT_CODE   — rebuild process exit code (int)
//	REBUILD_DURATION_MS — rebuild wall-clock duration in milliseconds
//	SERVICES_ENABLED    — comma-separated list of enabled service units
//	SERVICES_FAILED     — comma-separated list of failed service units
type StateFile struct {
	// stateFieldSeen records whether an INSTALL_STATE= line was actually parsed
	// from disk. NewStateFile seeds State with a constructor default, so a
	// non-empty State does NOT prove the value was persisted. A reader that
	// evaluates the default as persisted evidence would report a fabricated
	// state for a file that never carried one. Set only by Read().
	stateFieldSeen bool

	// rebuildEvidenceRejected records that the record READ FROM DISK contradicts
	// itself about the rebuild (see RebuildEvidenceContradiction). It is IN-MEMORY
	// ONLY and is never written: the on-disk artifact is forensic material and must
	// survive verbatim, while no consumer in this process may go on treating
	// REBUILD_EXIT_CODE / REBUILD_DURATION_MS as measurements. Same discipline as
	// stateFieldSeen above — a value that exists is not automatically a value that
	// was observed.
	rebuildEvidenceRejected string

	State             InstallState
	Mode              string
	Version           string
	Timestamp         time.Time
	SSHPort           int
	Authority         string
	Panel             string
	Conflicts         string
	SchemaVersion     string
	PhaseReached      string
	FailureReason     string
	PreflightPassed   bool
	RebuildExitCode   int
	RebuildDurationMs int64
	ServicesEnabled   string
	ServicesFailed    string
	// v1.222.1 Lane 4: structured failed-unit attribution companions to
	// SERVICES_FAILED (canonical, comma-separated nftban unit names). Backward-
	// compatible — absent in old state files → empty.
	ServicesFailedPreexisting string
	ServicesFailedInWindow    string

	// v1.222.1 HEALTH-OOM hotfix (Lane 2): profile-derived health-service
	// resource reconciliation result. All optional/backward-compatible — an old
	// state file without these keys parses to zero values. No volatile timestamp.
	// v1.228.5 BUG-REBUILD-DISCARDS-FAILED-WHITELIST-RECONCILE: durable whitelist.d
	// convergence verdict from services.SyncWhitelist, the SOLE installer convergence
	// authority (switchop.Rebuild runs pre-daemon with --install-context and DEFERS
	// the projection). CONVERGED | FAILED | "" (not evaluated). A FAILED value means
	// configured management IPs are not projected into the running set.
	WhitelistConvergence string

	// ConvergenceVerified — v1.230.0 Gate 6R. The POST-UPDATE CONVERGENCE verdict
	// (switchop.VerifyPostUpdateConvergence), persisted as CONVERGENCE_VERIFIED.
	//
	// ⛔ PACKAGE UPDATED != PROJECTION GENERATED != PROJECTION VALIDATED
	//    != KERNEL RULESET APPLIED != RUNTIME CONVERGED.
	// The installer used to collapse those, so an update could be reported successful
	// with convergence never proven. This carries the phase verdict to the assertion
	// that gates COMMITTED, exactly as WHITELIST_CONVERGENCE above does.
	//
	// "" means NOT EVALUATED (a pre-v1.230.0 record, or a path that does not evaluate
	// it). ⛔ It is never read as VERIFIED.
	ConvergenceVerified string

	// ─────────────────────────────────────────────────────────────────────────
	// v1.233.x Lane B — DURABLE STRUCTURE ATTRIBUTION
	// ─────────────────────────────────────────────────────────────────────────
	// WHICH static enforcement structure this record certifies. Written together
	// with CONVERGENCE_VERIFIED, never instead of it.
	//
	// ⛔ THE SCHEMA TOKEN IS NOT OPTIONAL METADATA. A digest is comparable only to
	// another digest produced by the SAME canonicalisation. Storing the bare hash
	// would make every historical record uninterpretable the moment normalisation
	// changes — a reader could not distinguish "the structure changed" from "the
	// ruler changed". Both fields move together or neither is meaningful.
	//
	// ⛔ AND IT IS ATTRIBUTION, NOT VALIDATION. A matching fingerprint identifies
	// the structure that was proven correct; it is never evidence that it IS
	// correct, and must never short-circuit the semantic assertions.
	//
	// "" on both means NOT ATTRIBUTED (every pre-v1.233.x record, and every path
	// that does not derive a structure identity). It is never read as agreement.
	ConvergenceStructureSchema      string
	ConvergenceStructureFingerprint string

	HealthResourceState         string // effective state: ACTIVE_MATCH/FALLBACK_MATCH/FALLBACK_UNDERSIZED/EXTERNAL_OVERRIDE_CONFLICT/…
	HealthResourceProfile       string // resource tier: small/medium/large
	HealthResourceAuthority     string // always internal/safety
	HealthResourceReason        string // tier-selection reason
	HealthResourceProtection    bool   // true iff profile-derived OOM protection is effectively active
	HealthMemHighCalculated     int64
	HealthMemMaxCalculated      int64
	HealthMemHighEffective      int64
	HealthMemMaxEffective       int64
	HealthTasksMaxEffective     int64
	HealthResourceDropin        string // canonical generated drop-in path
	HealthResourceDropinLoaded  bool
	HealthResourceLoadedDropins string // space-separated ALL loaded DropInPaths (conflict evidence)
	HealthResourceSourceVer     string
	HealthResourceGenerated     string // file-level generated state
	HealthResourceError         string // last reconciliation error (cleared on success)

	// DryRun, when true, makes Transition update in-memory fields only
	// and skip the atomic file write. PR-22B introduced this so that
	// dry-run paths sharing phase functions with real install/upgrade
	// (e.g. phaseDetect reused by runUpdateDryRun) do not persist
	// install_state during observational runs.
	//
	// Callers that need to force a real persistence during a dry-run
	// (none exist today, but reserved for future audit artifacts) can
	// set this to false temporarily and call Transition, but that is
	// discouraged — the expected contract is DryRun=cfg.dryRun at the
	// start of the run and never toggled.
	DryRun bool

	stateDir string
}

// NewStateFile creates a new StateFile with the given state directory.
// If stateDir is empty, DefaultStateDir is used.
func NewStateFile(stateDir string) *StateFile {
	if stateDir == "" {
		stateDir = DefaultStateDir
	}
	return &StateFile{
		State:    StateFilesInstalled,
		stateDir: stateDir,
	}
}

// Path returns the full path to the state file.
func (sf *StateFile) Path() string {
	return filepath.Join(sf.stateDir, StateFileName)
}

// Transition validates and applies a state transition.
// It updates the state, phase, and optional failure reason, then persists atomically.
// For failure states, it always returns an error (the reason) so phase runners halt.
//
// When sf.DryRun is true, the in-memory fields are updated but the
// filesystem is NOT written. This allows dry-run orchestrators to reuse
// phase functions that call Transition without tripping the
// observational-path Stop Condition (PR-22B boundary repair).
// degradedReasonFallback is used when a DEGRADED transition is handed an empty
// reason, so FAILURE_REASON is never blank for a completed-with-issues install
// (v1.135 scope §5: every DEGRADED has a non-empty machine-readable reason).
const degradedReasonFallback = "degraded: post-install assertions failed (reason unavailable)"

// commitEligibleConvergenceVerdicts is the ALLOWLIST of CONVERGENCE_VERIFIED values
// from which COMMITTED may be reached. Each member names a state in which the
// post-update convergence contract ACTUALLY RAN; the values it excludes — "" and
// NOT_EVALUATED — name states in which it did not, and NOT_CONVERGED names one in
// which it ran and failed.
//
// ⛔ MIRRORS, IT DOES NOT OWN. switchop.ConvergenceVerdict is the authority; these are
// duplicated here only because internal/installer/state must not import switchop
// (switchop already depends on state). internal/installer/switchop/convergence.go
// carries a matching note.
var commitEligibleConvergenceVerdicts = []string{
	ConvergenceVerifiedValue,
	"DEFERRED",
	"UNVERIFIED",
}

// ConvergenceVerdictPermitsCommit is the EXPORTED predicate. Any caller that needs
// to know "could this record reach COMMITTED?" BEFORE attempting the transition must
// ask this function rather than comparing to a literal.
//
// ⛔ ADDED BECAUSE A SECOND AUTHORITY DISAGREED WITH THE FIRST. runRevalidate's
// carry-forward gate was written as `!= ConvergenceVerifiedValue`, which refuses
// DEFERRED and UNVERIFIED — verdicts the boundary invariant PERMITS. Result: a host
// whose install legitimately deferred could never clear a DEGRADED record through
// --revalidate, while the same verdict committed fine through the install chain.
// Caught only by the package-native matrix; the unit test used "" , which both
// spellings refuse, so it passed.
//
//	ONE PREDICATE, ONE AUTHORITY. A pre-check that reimplements the invariant it
//	is pre-checking will drift away from it.
func ConvergenceVerdictPermitsCommit(v string) bool { return convergenceVerdictPermitsCommit(v) }

func convergenceVerdictPermitsCommit(v string) bool {
	for _, ok := range commitEligibleConvergenceVerdicts {
		if v == ok {
			return true
		}
	}
	return false
}

func (sf *StateFile) Transition(newState InstallState, phase Phase, reason string) error {
	// ⛔ TRANSACTION-TRUTH INVARIANT (v1.232.2). COMMITTED may only be reached from a
	// state in which a convergence verdict was ACTUALLY ESTABLISHED. Enforced HERE, at
	// the state-machine boundary, so it holds for EVERY caller — including future ones
	// — rather than depending on each path remembering the rule.
	//
	// ⛔ THIS IS AN ALLOWLIST, AND IT IS DELIBERATELY NOT `== VERIFIED`.
	//
	// The first version of this guard required VERIFIED. That is a stronger claim than
	// the defect warrants and it BREAKS PRODUCTION: assertPostUpdateConvergence has
	// long treated DEFERRED and UNVERIFIED as permitted intermediate dispositions
	// (see its contract block — "setting r.Passed = false on this arm re-introduces
	// P12-A01 for every upgrade"), and phaseSwitch writes exactly those verdicts on
	// ordinary hosts. Requiring VERIFIED here would have left every deferring upgrade
	// stuck at SERVICES_COMPLETE. Whether DEFERRED and UNVERIFIED *should* be
	// commit-eligible is a real, separate question with its own documented history;
	// re-deciding it inside a bug fix would change fleet-wide upgrade behaviour under
	// cover of something else. Tracked as its own handle.
	//
	// WHAT THE DEFECT ACTUALLY IS: COMMITTED reached when NO VERDICT WAS EVER
	// ESTABLISHED. That is what production srv3 held — COMMITTED beside an EMPTY
	// CONVERGENCE_VERIFIED — and what update_apply produced.
	//
	//	VERIFIED        permitted   the contract ran and every leg passed
	//	DEFERRED        permitted   ran; debt recorded, gated by other assertions
	//	UNVERIFIED      permitted   ran; a leg was unobservable, gated likewise
	//	""              REFUSED     no verdict exists — the srv3 shape
	//	NOT_EVALUATED   REFUSED     the path declines to evaluate convergence
	//	NOT_CONVERGED   REFUSED     it ran and the answer was NO
	//	anything else   REFUSED     fail closed; an unknown verdict is not a proof
	//
	// An allowlist rather than a denylist so a future verdict value cannot inherit
	// permission by being unrecognised.
	//
	// ⛔ THE STATE IS NOT MUTATED ON REFUSAL. Every caller writes
	// `_ = sf.Transition(...)`, so an error return alone would be ignored and
	// COMMITTED would still land. Refusing to ASSIGN is what makes the false-green
	// structurally impossible; the state stays at its prior, truthful value.
	if newState == StateCommitted && !convergenceVerdictPermitsCommit(sf.ConvergenceVerified) {
		return fmt.Errorf(
			"refusing COMMITTED: CONVERGENCE_VERIFIED=%q is not a verdict that was established by "+
				"any run — COMMITTED requires one of %v. A completed mutation and a healthy daemon "+
				"are not evidence that THIS transaction converged",
			sf.ConvergenceVerified, commitEligibleConvergenceVerdicts)
	}
	sf.State = newState
	sf.PhaseReached = string(phase)
	if newState.IsFailed() || newState.IsDeferredRebuild() {
		// v1.230.0 Gate 6R: a DEFERRED terminal is not a failure, but it still owes the
		// operator a machine-readable cause. FailureReason is the existing diagnostic
		// carrier in this file; leaving it empty would produce a terminal state file
		// that says the install stopped and refuses to say why.
		sf.FailureReason = reason
	} else if newState == StateCommitted || newState == StateDegraded {
		// V108 Item 5: clear stale pre-failure carry-over fields when reaching
		// success/soft-success terminals. Without this, a host that experienced
		// FAILED_AUTHORITY_ABORT earlier and then advanced to COMMITTED/DEGRADED
		// would carry CONFLICTS=… / FAILURE_REASON="takeover not approved…" /
		// PREFLIGHT_PASSED=0 verbatim into the terminal state file — visible on
		// 4 of 6 v1.107.2 rollout hosts (lab2/srv1/srv3/srv4) and confusing for
		// operator diagnosis. See V108_ITEM5_INSTALL_STATE_HYGIENE_SCOPE.md.
		sf.applyTerminalHygiene()
		// v1.131.4 (D-INSTALL-STATE-BLANK-REASON): unlike COMMITTED, DEGRADED is
		// a completed-WITH-issues terminal whose reason (the still-failing
		// assertion names) is CURRENT, not stale carry-over. applyTerminalHygiene
		// cleared FailureReason for the clean COMMITTED path; re-attach the
		// current reason for DEGRADED so FAILURE_REASON= is populated in the
		// state file and report() can render the "Issues:" line for the operator.
		if newState == StateDegraded {
			// v1.135 (scope §5): a DEGRADED terminal must NEVER carry an empty
			// FAILURE_REASON. phaseValidate always supplies a non-empty reason,
			// but guard against any future caller passing "" so the operator
			// always sees a machine-readable cause.
			if reason == "" {
				reason = degradedReasonFallback
			}
			sf.FailureReason = reason
		}
	}
	sf.Timestamp = time.Now().UTC()
	if !sf.DryRun {
		if err := sf.WriteAtomic(); err != nil {
			return err
		}
	}
	// Failure states must return an error so the phase runner stops execution.
	//
	// v1.230.0 Gate 6R: a DEFERRED rebuild terminal must stop the runner too. Without
	// this it returns nil, phaseSwitch returns nil, and the run walks on to Configure
	// and Validate — which is how an install with NO CONVERGENCE could still reach a
	// COMMITTED verdict because enforcement happened to still be in force.
	//     PROTECTED != TRANSACTION COMPLETE.
	// The sentinel is a STOP signal, not a claim of failure: the state itself carries
	// the truthful classification and IsFailed() stays false for it.
	if newState.IsFailed() || newState.IsDeferredRebuild() {
		return fmt.Errorf("%s: %s", newState, reason)
	}
	return nil
}

// applyTerminalHygiene clears stale pre-failure carry-over fields when
// transitioning to COMMITTED or DEGRADED. Per V108 Item 5 scope §4:
//
//   - FailureReason: cleared (no current failure on success/soft-success
//     terminal — the prior reason is no longer current)
//   - Conflicts: cleared iff Authority == "UPDATE" (takeover approved, so
//     the prior conflict descriptors no longer reflect current state)
//   - PreflightPassed: set true (a successful terminal implies preflight
//     passed; the prior 0 from an aborted phase is stale)
//
// All three writes are idempotent on a clean (never-failed) host.
//
// Failure terminals (StateFailedAbort etc.) MUST preserve all fields —
// operator needs the diagnostic — and intermediate states preserve as-is
// (legitimate carry-over for diagnosis).
func (sf *StateFile) applyTerminalHygiene() {
	sf.FailureReason = ""
	if sf.Authority == "UPDATE" {
		sf.Conflicts = ""
	}
	sf.PreflightPassed = true
}

// WriteAtomic writes the state file atomically (write to tmp, then rename).
func (sf *StateFile) WriteAtomic() error {
	if err := os.MkdirAll(sf.stateDir, 0750); err != nil {
		return fmt.Errorf("create state dir %s: %w", sf.stateDir, err)
	}

	tmpPath := sf.Path() + ".tmp"
	f, err := os.OpenFile(tmpPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0640)
	if err != nil {
		return fmt.Errorf("create state temp file: %w", err)
	}

	w := bufio.NewWriter(f)
	fmt.Fprintln(w, "# NFTBan Install State — machine-written, do not edit")
	fmt.Fprintf(w, "INSTALL_STATE=%s\n", sf.State)
	fmt.Fprintf(w, "INSTALL_MODE=%s\n", sf.Mode)
	fmt.Fprintf(w, "INSTALL_VERSION=%s\n", sf.Version)
	// RFC3339Nano, not RFC3339. v1.228.0 Item 2 made this field verdict-bearing:
	// the post-install gate compares it against a --not-before stamp that carries
	// nanoseconds (date %N). Whole-second precision floors the write time, so a
	// transaction that commits inside the same second it began reads as older than
	// its own start and is reported STALE_STATE. It fails closed, so it produces a
	// false alarm rather than a false success — but it is still a wrong verdict.
	// The reader parses with the RFC3339 layout, which accepts the fractional part.
	fmt.Fprintf(w, "INSTALL_TIMESTAMP=%s\n", sf.Timestamp.UTC().Format(time.RFC3339Nano))
	fmt.Fprintf(w, "SSH_PORT=%d\n", sf.SSHPort)
	fmt.Fprintf(w, "AUTHORITY=%s\n", sf.Authority)
	fmt.Fprintf(w, "PANEL=%s\n", sf.Panel)
	fmt.Fprintf(w, "CONFLICTS=%s\n", sf.Conflicts)
	fmt.Fprintf(w, "SCHEMA_VERSION=%s\n", sf.SchemaVersion)
	fmt.Fprintf(w, "PHASE_REACHED=%s\n", sf.PhaseReached)
	fmt.Fprintf(w, "FAILURE_REASON=%s\n", sf.FailureReason)
	fmt.Fprintf(w, "PREFLIGHT_PASSED=%s\n", fmtBool(sf.PreflightPassed))
	fmt.Fprintf(w, "CONVERGENCE_VERIFIED=%s\n", sf.ConvergenceVerified)
	fmt.Fprintf(w, "CONVERGENCE_STRUCTURE_SCHEMA=%s\n", sf.ConvergenceStructureSchema)
	fmt.Fprintf(w, "CONVERGENCE_STRUCTURE_FINGERPRINT=%s\n", sf.ConvergenceStructureFingerprint)
	fmt.Fprintf(w, "REBUILD_EXIT_CODE=%d\n", sf.RebuildExitCode)
	fmt.Fprintf(w, "REBUILD_DURATION_MS=%d\n", sf.RebuildDurationMs)
	fmt.Fprintf(w, "SERVICES_ENABLED=%s\n", sf.ServicesEnabled)
	fmt.Fprintf(w, "SERVICES_FAILED=%s\n", sf.ServicesFailed)
	fmt.Fprintf(w, "SERVICES_FAILED_PREEXISTING=%s\n", sf.ServicesFailedPreexisting)
	fmt.Fprintf(w, "SERVICES_FAILED_IN_WINDOW=%s\n", sf.ServicesFailedInWindow)
	fmt.Fprintf(w, "WHITELIST_CONVERGENCE=%s\n", sf.WhitelistConvergence)
	fmt.Fprintf(w, "HEALTH_RESOURCE_STATE=%s\n", sf.HealthResourceState)
	fmt.Fprintf(w, "HEALTH_RESOURCE_PROFILE=%s\n", sf.HealthResourceProfile)
	fmt.Fprintf(w, "HEALTH_RESOURCE_AUTHORITY=%s\n", sf.HealthResourceAuthority)
	fmt.Fprintf(w, "HEALTH_RESOURCE_REASON=%s\n", sf.HealthResourceReason)
	fmt.Fprintf(w, "HEALTH_RESOURCE_PROTECTION_ACTIVE=%s\n", fmtBool(sf.HealthResourceProtection))
	fmt.Fprintf(w, "HEALTH_MEMORY_HIGH_CALCULATED=%d\n", sf.HealthMemHighCalculated)
	fmt.Fprintf(w, "HEALTH_MEMORY_MAX_CALCULATED=%d\n", sf.HealthMemMaxCalculated)
	fmt.Fprintf(w, "HEALTH_MEMORY_HIGH_EFFECTIVE=%d\n", sf.HealthMemHighEffective)
	fmt.Fprintf(w, "HEALTH_MEMORY_MAX_EFFECTIVE=%d\n", sf.HealthMemMaxEffective)
	fmt.Fprintf(w, "HEALTH_TASKS_MAX_EFFECTIVE=%d\n", sf.HealthTasksMaxEffective)
	fmt.Fprintf(w, "HEALTH_RESOURCE_DROPIN=%s\n", sf.HealthResourceDropin)
	fmt.Fprintf(w, "HEALTH_RESOURCE_DROPIN_LOADED=%s\n", fmtBool(sf.HealthResourceDropinLoaded))
	fmt.Fprintf(w, "HEALTH_RESOURCE_LOADED_DROPINS=%s\n", sf.HealthResourceLoadedDropins)
	fmt.Fprintf(w, "HEALTH_RESOURCE_SOURCE_VERSION=%s\n", sf.HealthResourceSourceVer)
	fmt.Fprintf(w, "HEALTH_RESOURCE_GENERATED=%s\n", sf.HealthResourceGenerated)
	fmt.Fprintf(w, "HEALTH_RESOURCE_ERROR=%s\n", sf.HealthResourceError)

	if err := w.Flush(); err != nil {
		f.Close()
		os.Remove(tmpPath)
		return fmt.Errorf("flush state file: %w", err)
	}
	if err := f.Close(); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("close state file: %w", err)
	}

	return os.Rename(tmpPath, sf.Path())
}

// Read reads an existing state file. Returns os.ErrNotExist if file is missing
// (which is normal for a fresh install).
func (sf *StateFile) Read() error {
	f, err := os.Open(sf.Path())
	if err != nil {
		return err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		idx := strings.IndexByte(line, '=')
		if idx < 0 {
			continue
		}
		key, val := line[:idx], line[idx+1:]
		switch key {
		case "INSTALL_STATE":
			sf.State = InstallState(val)
			sf.stateFieldSeen = true
		case "INSTALL_MODE":
			sf.Mode = val
		case "INSTALL_VERSION":
			sf.Version = val
		case "INSTALL_TIMESTAMP":
			sf.Timestamp, _ = time.Parse(time.RFC3339, val)
		case "SSH_PORT":
			sf.SSHPort, _ = strconv.Atoi(val)
		case "AUTHORITY":
			sf.Authority = val
		case "PANEL":
			sf.Panel = val
		case "CONFLICTS":
			sf.Conflicts = val
		case "SCHEMA_VERSION":
			sf.SchemaVersion = val
		case "PHASE_REACHED":
			sf.PhaseReached = val
		case "FAILURE_REASON":
			sf.FailureReason = val
		case "PREFLIGHT_PASSED":
			sf.PreflightPassed = (val == "1" || val == "true")
		case "CONVERGENCE_VERIFIED":
			sf.ConvergenceVerified = val
		case "CONVERGENCE_STRUCTURE_SCHEMA":
			sf.ConvergenceStructureSchema = val
		case "CONVERGENCE_STRUCTURE_FINGERPRINT":
			sf.ConvergenceStructureFingerprint = val
		case "REBUILD_EXIT_CODE":
			sf.RebuildExitCode, _ = strconv.Atoi(val)
		case "REBUILD_DURATION_MS":
			sf.RebuildDurationMs, _ = strconv.ParseInt(val, 10, 64)
		case "SERVICES_ENABLED":
			sf.ServicesEnabled = val
		case "SERVICES_FAILED":
			sf.ServicesFailed = val
		case "SERVICES_FAILED_PREEXISTING":
			sf.ServicesFailedPreexisting = val
		case "SERVICES_FAILED_IN_WINDOW":
			sf.ServicesFailedInWindow = val
		case "WHITELIST_CONVERGENCE":
			sf.WhitelistConvergence = val
		case "HEALTH_RESOURCE_STATE":
			sf.HealthResourceState = val
		case "HEALTH_RESOURCE_PROFILE":
			sf.HealthResourceProfile = val
		case "HEALTH_RESOURCE_AUTHORITY":
			sf.HealthResourceAuthority = val
		case "HEALTH_RESOURCE_REASON":
			sf.HealthResourceReason = val
		case "HEALTH_RESOURCE_PROTECTION_ACTIVE":
			sf.HealthResourceProtection = (val == "1" || val == "true")
		case "HEALTH_MEMORY_HIGH_CALCULATED":
			sf.HealthMemHighCalculated, _ = strconv.ParseInt(val, 10, 64)
		case "HEALTH_MEMORY_MAX_CALCULATED":
			sf.HealthMemMaxCalculated, _ = strconv.ParseInt(val, 10, 64)
		case "HEALTH_MEMORY_HIGH_EFFECTIVE":
			sf.HealthMemHighEffective, _ = strconv.ParseInt(val, 10, 64)
		case "HEALTH_MEMORY_MAX_EFFECTIVE":
			sf.HealthMemMaxEffective, _ = strconv.ParseInt(val, 10, 64)
		case "HEALTH_TASKS_MAX_EFFECTIVE":
			sf.HealthTasksMaxEffective, _ = strconv.ParseInt(val, 10, 64)
		case "HEALTH_RESOURCE_DROPIN":
			sf.HealthResourceDropin = val
		case "HEALTH_RESOURCE_DROPIN_LOADED":
			sf.HealthResourceDropinLoaded = (val == "1" || val == "true")
		case "HEALTH_RESOURCE_LOADED_DROPINS":
			sf.HealthResourceLoadedDropins = val
		case "HEALTH_RESOURCE_SOURCE_VERSION":
			sf.HealthResourceSourceVer = val
		case "HEALTH_RESOURCE_GENERATED":
			sf.HealthResourceGenerated = val
		case "HEALTH_RESOURCE_ERROR":
			sf.HealthResourceError = val
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	// ⛔ REJECT AT THE READ BOUNDARY, LIKE ReadRebuildResult DOES — and DO NOT fail the
	// read. A contradictory record still carries the state, phase and resume point that
	// `--repair` needs, and refusing to parse it would strand exactly the hosts that
	// have the defect. What is withheld is the discredited MEASUREMENT PAIR, nothing else.
	sf.rebuildEvidenceRejected = sf.RebuildEvidenceContradiction()
	return nil
}

// nonZeroExitInProse matches an exit code an installer-authored FAILURE_REASON
// asserts, in the two forms this tree emits: "(exit N)" and "exit=N".
//
// ⛔ IT IS A CONSISTENCY AUDIT OF OUR OWN RECORD, NOT AN INTERFACE.
// The Gate 6R rule against reading message text bans deriving a VERDICT from a
// subprocess's stderr. This is the opposite direction: it reads a field WE wrote, and
// its only permitted output is REJECTION. ⛔ Nothing may use it to POPULATE a field —
// that would make prose the source of a structured value, which is the very inversion
// this limb exists to remove.
var nonZeroExitInProse = regexp.MustCompile(`(?:\(exit |exit=)([0-9]+)\)?`)

// RebuildEvidenceContradiction returns a description when this record contradicts
// itself about the rebuild, or "" when it does not.
//
// ⛔ THE DEFECT IT REJECTS (dns1, one file, one run):
//
//	FAILURE_REASON=... produced no usable result contract (exit 1): ...
//	REBUILD_EXIT_CODE=0
//	REBUILD_DURATION_MS=0
//
// while installer.log recorded `(exit=1)` and `elapsed=31.22s`. The prose was right and
// the machine-readable pair was wrong — and automation reads the machine-readable pair.
//
// This is the install_state counterpart of the rejection ReadRebuildResult already
// applies to the rebuild RESULT contract (a REFUSED record that also claims a mutation
// is refused rather than believed). ONE VALIDATOR PER CONTRACT: this is the only place
// install_state is checked against itself, exactly as that is the only place the result
// record is.
//
// ⛔ IT REJECTS, IT NEVER REPAIRS. Adopting the prose's number would make an
// unstructured field the authority for a structured one.
func (sf *StateFile) RebuildEvidenceContradiction() string {
	if sf.FailureReason == "" {
		return ""
	}
	m := nonZeroExitInProse.FindStringSubmatch(sf.FailureReason)
	if m == nil {
		return ""
	}
	claimed, err := strconv.Atoi(m[1])
	if err != nil || claimed == 0 {
		return ""
	}
	if sf.RebuildExitCode == 0 {
		return fmt.Sprintf("FAILURE_REASON asserts a non-zero rebuild exit (%d) while REBUILD_EXIT_CODE=0"+
			" (REBUILD_DURATION_MS=%d) — the structured evidence was never populated and must not be read as a measurement",
			claimed, sf.RebuildDurationMs)
	}
	return ""
}

// RebuildEvidenceUsable reports whether REBUILD_EXIT_CODE / REBUILD_DURATION_MS from
// THIS record may be consumed as measurements.
//
// ⛔ CONSULT THIS BEFORE READING EITHER FIELD. A rejected pair is not "probably fine";
// it is a pair we have positively shown to disagree with the rest of its own record.
func (sf *StateFile) RebuildEvidenceUsable() bool { return sf.rebuildEvidenceRejected == "" }

// RebuildEvidenceRejection returns why the rebuild evidence was rejected, or "".
func (sf *StateFile) RebuildEvidenceRejection() string { return sf.rebuildEvidenceRejected }

func fmtBool(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

// StateFieldPresent reports whether Read() actually parsed an INSTALL_STATE=
// line from the file on disk.
//
// This exists because NewStateFile seeds State with a constructor default
// (StateFilesInstalled). Without this signal a caller cannot distinguish
// "the file records this state" from "the file recorded nothing and you are
// looking at the constructor". Verification paths MUST consult it before
// treating State as persisted evidence.
func (sf *StateFile) StateFieldPresent() bool { return sf.stateFieldSeen }
