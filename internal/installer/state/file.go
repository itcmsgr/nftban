// =============================================================================
// NFTBan v1.73 - Installer State File I/O
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
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
//	REBUILD_EXIT_CODE   — rebuild process exit code (int)
//	REBUILD_DURATION_MS — rebuild wall-clock duration in milliseconds
//	SERVICES_ENABLED    — comma-separated list of enabled service units
//	SERVICES_FAILED     — comma-separated list of failed service units
type StateFile struct {
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
func (sf *StateFile) Transition(newState InstallState, phase Phase, reason string) error {
	sf.State = newState
	sf.PhaseReached = string(phase)
	if newState.IsFailed() {
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
	}
	sf.Timestamp = time.Now().UTC()
	if !sf.DryRun {
		if err := sf.WriteAtomic(); err != nil {
			return err
		}
	}
	// Failure states must return an error so the phase runner stops execution.
	if newState.IsFailed() {
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
	fmt.Fprintf(w, "INSTALL_TIMESTAMP=%s\n", sf.Timestamp.Format(time.RFC3339))
	fmt.Fprintf(w, "SSH_PORT=%d\n", sf.SSHPort)
	fmt.Fprintf(w, "AUTHORITY=%s\n", sf.Authority)
	fmt.Fprintf(w, "PANEL=%s\n", sf.Panel)
	fmt.Fprintf(w, "CONFLICTS=%s\n", sf.Conflicts)
	fmt.Fprintf(w, "SCHEMA_VERSION=%s\n", sf.SchemaVersion)
	fmt.Fprintf(w, "PHASE_REACHED=%s\n", sf.PhaseReached)
	fmt.Fprintf(w, "FAILURE_REASON=%s\n", sf.FailureReason)
	fmt.Fprintf(w, "PREFLIGHT_PASSED=%s\n", fmtBool(sf.PreflightPassed))
	fmt.Fprintf(w, "REBUILD_EXIT_CODE=%d\n", sf.RebuildExitCode)
	fmt.Fprintf(w, "REBUILD_DURATION_MS=%d\n", sf.RebuildDurationMs)
	fmt.Fprintf(w, "SERVICES_ENABLED=%s\n", sf.ServicesEnabled)
	fmt.Fprintf(w, "SERVICES_FAILED=%s\n", sf.ServicesFailed)

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
		case "REBUILD_EXIT_CODE":
			sf.RebuildExitCode, _ = strconv.Atoi(val)
		case "REBUILD_DURATION_MS":
			sf.RebuildDurationMs, _ = strconv.ParseInt(val, 10, 64)
		case "SERVICES_ENABLED":
			sf.ServicesEnabled = val
		case "SERVICES_FAILED":
			sf.ServicesFailed = val
		}
	}
	return scanner.Err()
}

func fmtBool(b bool) string {
	if b {
		return "1"
	}
	return "0"
}
