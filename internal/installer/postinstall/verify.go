// =============================================================================
// NFTBan - postinstall verify (v1.228.0)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="postinstall_verify"
// meta:type="package"
// meta:version="1.228.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Post-install outcome gate: decides whether the persisted install_state belongs to the CURRENT package transaction. State presence is not state freshness — a prior COMMITTED must never be reported as this transaction's result."
// meta:inventory.files="/var/lib/nftban/state/install_state"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package postinstall answers one question a package manager cannot: did THIS
// transaction actually commit?
//
// # WHY THIS EXISTS
//
// `dnf install` and `apt-get install` report success when the package payload
// is unpacked. They do not report the installer's outcome. On a stock enforcing
// EL9 host the bundled installer aborts with FAILED_NO_FIREWALL, the firewall
// never loads, and the package manager still prints "Complete!". Automation that
// gates on the package manager's exit code reads a firewall-less host as a
// successful install.
//
// The installer already records the truth — StateFile.Transition persists a
// terminal state with a UTC timestamp. The gap is on the READING side.
//
// # STATE PRESENCE IS NOT STATE FRESHNESS
//
// Three termination classes run BEFORE the StateFile exists (main.go:125):
// flag/usage errors, --version, and lock contention (os.Exit(75)); a panic is a
// fourth. Those paths are CORRECT not to write state — nothing was installed.
// But they leave the previous install_state untouched, so a reader asking only
// "is it COMMITTED?" gets a yes from an unrelated, earlier transaction.
//
// Version equality does not close this. A retry after lock contention is BY
// DEFINITION a same-version reinstall, so State==COMMITTED and Version==expected
// both hold while nothing was installed. Freshness must be correlated with the
// transaction itself:
//
//	StateFile.Timestamp >= the moment this transaction invoked the installer
//
// Both operands are UTC (Transition sets time.Now().UTC()), so no timezone
// conversion can affect the comparison.
//
// FAIL CLOSED. Missing, unreadable or ambiguous state is never a pass.
package postinstall

import (
	"fmt"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/state"
)

// Verdict is the outcome of a post-install verification.
type Verdict string

// unknownField is emitted instead of a blank so every token line is always
// present and parseable, on every path including failures.
const unknownField = "UNKNOWN"

const (
	// CurrentCommitted is the ONLY verdict that means "this transaction committed".
	CurrentCommitted Verdict = "CURRENT_COMMITTED"
	// StaleState means the persisted state predates this transaction. The most
	// important verdict in this package: it is what lock contention, a panic and
	// any other pre-StateFile termination must produce.
	StaleState Verdict = "STALE_STATE"
	// VersionMismatch means the state belongs to a different package version.
	VersionMismatch Verdict = "VERSION_MISMATCH"
	// InstallFailed means the installer reached a terminal failure state.
	InstallFailed Verdict = "INSTALL_FAILED"
	// InstallDegraded means the installer completed with issues.
	InstallDegraded Verdict = "INSTALL_DEGRADED"
	// MissingState means no state file exists.
	MissingState Verdict = "MISSING_STATE"
	// InvalidState means the state file exists but cannot be read or understood.
	InvalidState Verdict = "INVALID_STATE"
	// DryRunNotApplied means the caller asked about a dry run, which by contract
	// never mutates authoritative state.
	DryRunNotApplied Verdict = "DRY_RUN_NOT_APPLIED"
)

// Verified reports whether the verdict permits claiming the install committed.
// Exactly one verdict does.
func (v Verdict) Verified() bool { return v == CurrentCommitted }

// Result carries the verdict plus the persisted facts behind it, so the caller
// can print the historical state and the current-attempt verdict as SEPARATE
// machine-readable fields. A historically valid COMMITTED must never be
// presentable as this transaction's outcome.
type Result struct {
	Verdict Verdict
	// PersistedState is what the state file said, verbatim — may be empty.
	PersistedState string
	// PersistedVersion is the version the state file recorded — may be empty.
	PersistedVersion string
	// PersistedTimestamp is the state file's UTC timestamp — may be zero.
	PersistedTimestamp time.Time
	// Detail is a short operator-safe explanation.
	Detail string
}

// Options are the inputs a package script must supply.
type Options struct {
	// StateDir is the installer state directory.
	StateDir string
	// ExpectedVersion is the version the package manager just installed.
	ExpectedVersion string
	// NotBefore is captured IMMEDIATELY before invoking the installer — not at
	// the start of the whole package script. Anything earlier widens the window
	// in which a previous transaction's state would look fresh.
	NotBefore time.Time
	// DryRun marks a dry-run verification; authoritative state is not expected
	// to change and must not be reported as a current commit.
	DryRun bool
}

// Verify decides whether the persisted install_state belongs to this transaction.
//
// No tolerance window is applied. Both timestamps originate from time.Now().UTC()
// on the same host at nanosecond precision, and a tolerance is precisely what
// would let an old state look fresh.
func Verify(opt Options) Result {
	if opt.NotBefore.IsZero() {
		return Result{
			Verdict:          InvalidState,
			PersistedState:   unknownField,
			PersistedVersion: unknownField,
			Detail:           "no transaction start timestamp supplied — freshness cannot be established",
		}
	}

	sf := state.NewStateFile(opt.StateDir)
	if err := sf.Read(); err != nil {
		// Distinguish "never installed" from "cannot be trusted". Both fail, but
		// an operator needs to know which.
		return Result{
			Verdict:          MissingState,
			PersistedState:   unknownField,
			PersistedVersion: unknownField,
			Detail:           fmt.Sprintf("cannot read install state at %s: %v", sf.Path(), err),
		}
	}

	// PROVENANCE FIRST. NewStateFile seeds State with a constructor default, so a
	// non-empty sf.State does NOT prove the value came from disk. Reading the
	// default as persisted evidence would report a fabricated state for a file
	// that never carried one — checking sf.State == "" alone cannot detect it.
	if !sf.StateFieldPresent() {
		return Result{
			Verdict:          InvalidState,
			PersistedState:   unknownField,
			PersistedVersion: unknownField,
			Detail:           fmt.Sprintf("install state file %s carries no INSTALL_STATE field", sf.Path()),
		}
	}

	res := Result{
		PersistedState:     string(sf.State),
		PersistedVersion:   sf.Version,
		PersistedTimestamp: sf.Timestamp.UTC(),
	}

	if sf.State == "" {
		res.Verdict = InvalidState
		res.PersistedState = unknownField
		res.Detail = "install state file carries an empty INSTALL_STATE value"
		return res
	}

	if opt.DryRun {
		res.Verdict = DryRunNotApplied
		res.Detail = "dry run: authoritative install state was intentionally not modified"
		return res
	}

	// FRESHNESS FIRST. A stale state must be reported as stale even when it says
	// COMMITTED and the version matches — that is the whole defect. Checking the
	// state value first would let a same-version prior COMMITTED answer for a
	// transaction that never ran.
	if res.PersistedTimestamp.Before(opt.NotBefore.UTC()) {
		res.Verdict = StaleState
		res.Detail = fmt.Sprintf(
			"persisted state %s (%s) predates this transaction: state written %s, transaction began %s — "+
				"the installer did not reach a terminal state in this run",
			sf.State, sf.Version,
			res.PersistedTimestamp.Format(time.RFC3339Nano),
			opt.NotBefore.UTC().Format(time.RFC3339Nano))
		return res
	}

	switch {
	case sf.State == state.StateCommitted:
		if opt.ExpectedVersion != "" && sf.Version != opt.ExpectedVersion {
			res.Verdict = VersionMismatch
			res.Detail = fmt.Sprintf("state records version %q but %q was installed",
				sf.Version, opt.ExpectedVersion)
			return res
		}
		res.Verdict = CurrentCommitted
		res.Detail = fmt.Sprintf("installation committed in this transaction at %s",
			res.PersistedTimestamp.Format(time.RFC3339Nano))
	case sf.State == state.StateDegraded:
		res.Verdict = InstallDegraded
		res.Detail = "installation completed with issues (DEGRADED) — see the installer log"
	case sf.State.IsFailed():
		res.Verdict = InstallFailed
		res.Detail = fmt.Sprintf("installer reached terminal failure state %s", sf.State)
	default:
		// A non-terminal state written within this transaction means the
		// installer stopped mid-flight. Never optimistic.
		res.Verdict = InvalidState
		res.Detail = fmt.Sprintf("install state %s is not a terminal outcome", sf.State)
	}
	return res
}

// ExitCode maps a verdict to the process exit code.
//
//	0  this transaction committed
//	1  anything else that is a real, determined negative
//	2  usage / undeterminable input (handled by the caller before Verify)
func (v Verdict) ExitCode() int {
	if v == CurrentCommitted {
		return 0
	}
	return 1
}

// Tokens renders the stable machine-readable fields.
//
// PERSISTED state and the CURRENT-ATTEMPT verdict are deliberately separate
// fields. Printing a bare NFTBAN_INSTALL_STATE=COMMITTED on a path where the
// state predates the attempt is exactly the misrepresentation this package
// exists to prevent.
func (r Result) Tokens(opt Options, installerExit int) []string {
	ts := unknownField
	if !r.PersistedTimestamp.IsZero() {
		ts = r.PersistedTimestamp.Format(time.RFC3339Nano)
	}
	ps, pv := r.PersistedState, r.PersistedVersion
	if ps == "" {
		ps = unknownField
	}
	if pv == "" {
		pv = unknownField
	}
	nb := unknownField
	if !opt.NotBefore.IsZero() {
		nb = opt.NotBefore.UTC().Format(time.RFC3339Nano)
	}
	ev := opt.ExpectedVersion
	if ev == "" {
		ev = unknownField
	}
	return []string{
		"NFTBAN_PERSISTED_INSTALL_STATE=" + ps,
		"NFTBAN_PERSISTED_STATE_VERSION=" + pv,
		"NFTBAN_PERSISTED_STATE_TIMESTAMP=" + ts,
		"NFTBAN_EXPECTED_VERSION=" + ev,
		"NFTBAN_NOT_BEFORE=" + nb,
		"NFTBAN_INSTALL_ATTEMPT_VERDICT=" + string(r.Verdict),
		"NFTBAN_INSTALL_VERIFIED=" + boolWord(r.Verdict.Verified()),
		fmt.Sprintf("NFTBAN_INSTALLER_EXIT=%d", installerExit),
	}
}

func boolWord(b bool) string {
	if b {
		return "YES"
	}
	return "NO"
}
