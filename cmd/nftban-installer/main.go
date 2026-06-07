// =============================================================================
// NFTBan v1.75 - nftban-installer - RPM/DEB install finalizer
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Go-based RPM/DEB install finalizer replacing shell postinst"
// meta:inventory.files="/usr/lib/nftban/bin/nftban-installer"
// meta:inventory.binaries="nftban-installer"
// meta:inventory.env_vars="NFTBAN_TAKEOVER, NFTBAN_INSTALLER_LOG"
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/history"
	"github.com/itcmsgr/nftban/internal/installer/lock"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/pkg/version"

	// PR26.3: panel adapter registration via blank import. The package
	// init() calls panelfw.Register so the adapter is in the registry
	// before phaseValidate runs. Future panel adapters land alongside
	// this import.
	_ "github.com/itcmsgr/nftban/internal/installer/panelfw/adapters/directadmin"
	// PR26.7: Plesk adapter — same registration shape as DirectAdmin.
	_ "github.com/itcmsgr/nftban/internal/installer/panelfw/adapters/plesk"
	// PR26.8: cPanel/WHM adapter — same registration shape.
	_ "github.com/itcmsgr/nftban/internal/installer/panelfw/adapters/cpanel"
)

// globalTimeout is the maximum wall-clock time for the entire installer run.
const globalTimeout = 300 * time.Second

func main() {
	cfg := parseFlags()

	if cfg.showVersion {
		fmt.Println(version.Line("nftban-installer"))
		os.Exit(0)
	}

	log := logging.New(cfg.logPath, cfg.verbose)
	defer log.Close()

	// Write run header to log file for post-mortem analysis
	hostname, osInfo := systemIdentity()
	log.RunHeader(version.Version, cfg.mode, hostname, osInfo)

	log.Info("nftban-installer %s starting (mode=%s, repair=%v)", version.Version, cfg.mode, cfg.repair)
	log.Debug("flags: rpm=%v takeover=%v force=%v dry-run=%v verbose=%v", cfg.rpm, cfg.takeover, cfg.force, cfg.dryRun, cfg.verbose)
	log.Debug("state-dir=%s log=%s", cfg.stateDir, cfg.logPath)

	// V125 R-2: Acquire exclusive non-blocking flock BEFORE any state
	// mutation. Prevents concurrent installer/update/takeover runs from
	// racing install_state writes (the operator-running-nftban-installer
	// + cron-scheduled-repair collision class). Lock file lives alongside
	// install_state so it shares the same state-dir lifecycle.
	//
	// Skipped during --dry-run per PR-22B contract: dry-run modes MUST
	// NOT mutate the filesystem. Creating the lock file (even to record
	// our PID) would violate the contract enforced by the Update and
	// Uninstall Canonization Gates (G3-U3 / G3-KS-SNAPSHOT). Dry-run is
	// inherently safe to run in parallel because no writes happen, so
	// the race the lock prevents cannot occur during dry-run.
	//
	// Lock is released explicitly before os.Exit at the end of main
	// (Go skips defers on os.Exit, so an explicit Release call is
	// required to avoid leaving the lock file's flock held until the
	// kernel reclaims it on process exit — defensive cleanup).
	var installerLock *lock.Lock
	if !cfg.dryRun {
		lockPath := state.LockFilePath(cfg.stateDir)
		var lockErr error
		installerLock, lockErr = lock.Acquire(lockPath)
		if lockErr != nil {
			log.Error("%v", lockErr)
			fmt.Fprintf(os.Stderr, "ERROR: %v\n", lockErr)
			os.Exit(75) // EX_TEMPFAIL — operator should retry after the holder exits
		}
		log.Debug("acquired installer lock: %s (pid %d)", lockPath, os.Getpid())
	} else {
		log.Debug("V125 R-2: installer lock skipped (--dry-run; PR-22B no-filesystem-mutation contract)")
	}

	// Global timeout context
	ctx, cancel := context.WithTimeout(context.Background(), globalTimeout)
	defer cancel()

	// Handle signals
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		sig := <-sigCh
		log.Warn("received signal %s, shutting down", sig)
		cancel()
	}()

	exec := &executor.RealExecutor{}
	sf := state.NewStateFile(cfg.stateDir)
	// PR-22B: wire the dry-run flag into the state-file layer so that
	// Transition() is in-memory-only for every dry-run path, regardless
	// of which orchestrator invoked it. This closes the audit finding
	// that shared phase functions (phaseDetect in particular) persisted
	// install_state during update dry-run.
	sf.DryRun = cfg.dryRun

	// Read previous version before overwriting (for history tracking)
	previousVersion := ""
	if err := sf.Read(); err != nil && !os.IsNotExist(err) {
		log.Warn("could not read state file: %v", err)
	} else if err == nil {
		previousVersion = sf.Version
		log.Debug("previous state: %s (phase=%s, mode=%s, version=%s)", sf.State, sf.PhaseReached, sf.Mode, sf.Version)
	}

	// Set metadata
	sf.Mode = cfg.mode
	sf.Version = version.Version

	// Propagate --takeover flag to env so authority.Classify picks it up
	if cfg.takeover {
		os.Setenv("NFTBAN_TAKEOVER", "1")
	}

	// v1.98.x PR-14-pre: propagate source-install mode to phase data so
	// Prepare/Configure can branch into the source-install path when gated.
	// Package installs (cfg.source == false) leave these as zero-value and
	// never reach the gated code in phasePrepare/phaseConfigure.
	globalPhaseData.source = cfg.source
	globalPhaseData.sourceDir = cfg.sourceDir
	// PR-22B: propagate panel-auto-takeover to phase data so phaseDetect's
	// authority classifier honours the operator's explicit opt-in. Default
	// false — panel presence alone no longer implicitly approves takeover.
	globalPhaseData.panelAutoApprove = cfg.panelAutoTakeover
	// PR26.2: propagate --no-panel so the panel-survival assertion's
	// policy can opt out when the operator explicitly disables it.
	globalPhaseData.noPanel = cfg.noPanel
	// v1.120 (D-UPDATE-OPERATOR-SELF-BAN-GAP-001): propagate the operator-
	// session whitelist TTL. Default safety.DefaultSessionWhitelistTTL (30m)
	// already applied in parseFlags when --session-whitelist-ttl is unset.
	globalPhaseData.sessionWhitelistTTL = cfg.sessionWhitelistTTL

	exitCode := run(ctx, exec, sf, cfg, log)

	// Write JSON update history (compatible with nftban update history --json).
	//
	// PR-22B boundary repair: history writes are gated on an explicit
	// allowlist of apply-terminal states AND the absence of --dry-run.
	//
	// PR-23 extension (Option A locked 2026-04-20): uninstall mode is
	// ALSO excluded. update-history.json has an install-centric status
	// vocabulary (success / install_fail / verify_fail) that cannot
	// truthfully represent uninstall success without misrepresenting
	// it as an install-success. A dedicated uninstall-history schema
	// is an explicit pre-PR-24 (or parallel) follow-up item; until
	// that lands, uninstall events are forensically visible only in
	// the installer log, and update-history.json stays clean of them.
	//
	// PR-24 extension: --mode=restore is ALSO excluded. The three
	// restore states (RESTORE_DECIDED / RESTORE_REFUSED /
	// RESTORE_INTENT_REQUIRED) all return IsApplyTerminal=false per
	// contract seed §7, so the existing allowlist gate already blocks
	// history writes for this mode. The explicit mode check here is
	// belt-and-braces defense in case a future edit inadvertently
	// marks a restore state apply-terminal.
	if !cfg.dryRun && cfg.mode != "uninstall" && cfg.mode != "restore" && state.IsApplyTerminal(sf.State) {
		writeHistory(sf, cfg, previousVersion, hostname, log)
	}

	// Write run footer with final state for post-mortem
	log.RunFooter(string(sf.State), exitCode)

	// V125 R-2: Release the installer flock BEFORE os.Exit (Go skips
	// deferred calls on os.Exit, so explicit release is required to
	// guarantee the kernel sees the unlock before the process is gone).
	// Best-effort: any release error is logged but does NOT change the
	// installer exit code, since the lock will be released anyway when
	// the kernel reclaims the OFD on process exit.
	if relErr := installerLock.Release(); relErr != nil {
		log.Warn("installer-lock release: %v", relErr)
	}

	os.Exit(exitCode)
}

// systemIdentity returns hostname and OS identification for log headers.
func systemIdentity() (hostname, osInfo string) {
	hostname, _ = os.Hostname()
	if hostname == "" {
		hostname = "unknown"
	}

	// Read /etc/os-release for OS identification
	data, err := os.ReadFile("/etc/os-release")
	if err != nil {
		return hostname, "unknown"
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "PRETTY_NAME=") {
			osInfo = strings.Trim(strings.TrimPrefix(line, "PRETTY_NAME="), "\"")
			return hostname, osInfo
		}
	}
	return hostname, "unknown"
}

// run is the top-level orchestrator. Returns a process exit code.
func run(ctx context.Context, exec executor.Executor, sf *state.StateFile, cfg *config, log *logging.Logger) int {
	if cfg.repair {
		return runRepair(ctx, exec, sf, log)
	}
	// v1.100 PR-22 / PR-23 uninstall dispatch.
	//
	// flags.go validation (PR-23) guarantees exactly ONE of dryRun
	// or confirmMutation is true for --mode=uninstall, so this two-
	// branch routing is exhaustive:
	//
	//   --mode=uninstall --dry-run          → observational plan
	//   --mode=uninstall --confirm-mutation → authority release (PR-23)
	if cfg.mode == "uninstall" {
		if cfg.confirmMutation {
			return runUninstallApply(ctx, exec, sf, cfg, log)
		}
		return runUninstallDryRun(ctx, exec, sf, cfg, log)
	}
	// v1.100 PR-24 restore-policy-engine dispatch. Pure decision only;
	// performs NO kernel / service / filesystem mutation. flags.go
	// validates that --mode=restore is not combined with mutation flags.
	if cfg.mode == "restore" {
		return runRestoreDecide(ctx, exec, sf, cfg, log)
	}
	// v1.99 PR-16 (G3-U1/U2/U3/U4): update-mode dry-run short-circuits to
	// preflight + version-detect + plan render. No mutation — all apply
	// logic is deferred to PR-18 and reuses the rebuild pipeline per
	// INV-U-001. Install-mode dry-run falls through to the existing path
	// (behaviour preserved).
	if cfg.mode == "upgrade" && cfg.dryRun {
		return runUpdateDryRun(ctx, exec, sf, cfg, log)
	}
	// V125 R-4: --force safety gate on a COMMITTED state. The dispatch
	// paths below (runUpdateApply, runInstall) re-run all phases without
	// consulting install_state. On a healthy COMMITTED host, an accidental
	// `nftban-installer --mode=install --takeover --force` would re-trigger
	// Switch — re-flushing iptables, re-masking CSF if the operator
	// unmasked manually, re-rendering config — without operator intent
	// for that destruction.
	//
	// Gate placement is intentional:
	//   - AFTER repair (repair has its own COMMITTED no-op at line 344).
	//   - AFTER uninstall (operator IS intending to remove a COMMITTED install).
	//   - AFTER restore (decision-only, no mutation; flags.go also rejects
	//     --force with --mode=restore at line 237).
	//   - AFTER upgrade --dry-run (no mutation by design).
	//   - BEFORE runUpdateApply / runInstall, which ARE the mutating paths.
	//
	// Package-manager postinst paths (--rpm / --deb) do NOT pass --force
	// (verified: packaging/deb/postinst and packaging/build_nftban.sh RPM
	// spec invoke nftban-installer without --force), so legitimate package
	// upgrades on COMMITTED hosts are unaffected by this gate.
	//
	// --force alone still works for non-completed states (the typical
	// recovery path from StateFailedRebuild / StateFailedRender / etc.):
	// the helper shouldRefuseForceRecommit only refuses when ALL THREE
	// conditions hold (force=true AND state IN {COMMITTED, DEGRADED} AND
	// allowRecommit=false). V126 Lane A extends the gate-fire state set to
	// also include DEGRADED — chronic-DEGRADED hosts (e.g., lab2 with
	// D-DEG-1) are "completed-with-warnings" installs and need the same
	// destructive-re-run protection as COMMITTED hosts. Genuine failed
	// installs (StateFailedSwitch/Rebuild/Render/etc.) remain unguarded by
	// R-4 by design — --force is the legitimate recovery path there.
	if shouldRefuseForceRecommit(sf.State, cfg.force, cfg.allowRecommit) {
		fmt.Fprintf(os.Stderr, "error: --force on a %s install requires --allow-recommit confirmation.\n", sf.State)
		fmt.Fprintln(os.Stderr, "       this gate exists to prevent accidental destructive re-runs of a completed install.")
		fmt.Fprintln(os.Stderr, "       DEGRADED state means the install completed with non-fatal assertion failures —")
		fmt.Fprintln(os.Stderr, "       it is NOT a failed-install recovery scenario (use --repair for that).")
		fmt.Fprintf(os.Stderr, "       if you really want to re-run all phases on this %s host, add --allow-recommit.\n", sf.State)
		fmt.Fprintln(os.Stderr, "       if you intended to resume a failed install, use --repair instead of --force.")
		log.Error("V126 R-4: --force refused on %s state without --allow-recommit (use --repair to resume failed installs, or add --allow-recommit to confirm destructive re-run)", sf.State)
		return state.ExitRefused
	}

	// v1.99 PR-18 (G3-U5..U10): update apply orchestration. Thin sequencer
	// over rebuild + validator (see apply_contract.md). INV-U-001/002/003
	// enforced; no custom apply/recovery/authority logic introduced.
	//
	// Narrow gate: only operator-initiated `nftban update` routes here.
	// Package-manager post-upgrade hooks always pass --rpm or --deb
	// (see packaging/deb/postinst + packaging/build_nftban.sh RPM spec)
	// and continue through runInstall as today. PR-21 will unify the
	// paths once the shell rebuild is migrated.
	if cfg.mode == "upgrade" && !cfg.rpm && !cfg.deb {
		return runUpdateApply(ctx, exec, sf, cfg, log)
	}
	return runInstall(ctx, exec, sf, cfg, log)
}

// shouldRefuseForceRecommit is the V125 R-4 gate predicate, extended in V126
// Lane A. Returns true if the installer should refuse this run with
// ExitRefused because the operator passed --force on a completed-install
// state ({COMMITTED, DEGRADED}) without the --allow-recommit companion.
//
// Pure function over the three inputs; no I/O, no side effects. Extracted so
// the gate is testable without constructing a full run() context (executor,
// state file, logger, etc.).
//
// Refusal rule (all three must be true):
//  1. --force was passed
//  2. install_state is one of {COMMITTED, DEGRADED} (the "completed install"
//     states — install reached Validate phase; COMMITTED = clean,
//     DEGRADED = completed-with-non-fatal-assertion-failures)
//  3. --allow-recommit was NOT passed
//
// All other combinations return false (no refusal):
//   - --force alone on StateFailedSwitch / StateFailedRebuild / StateFailedRender /
//     StateFailedNoFirewall / StateFailedTakeover: allowed (legitimate recovery
//     path — the install never reached completion and re-running phases is the
//     supported way to recover)
//   - No --force on COMMITTED or DEGRADED: allowed (e.g., package-manager
//     postinst with --rpm/--deb passes no --force; routine package upgrades
//     unaffected)
//   - --force + --allow-recommit on COMMITTED or DEGRADED: allowed (explicit
//     operator intent)
//
// V126 Lane A change: extended the gate-fire set from {COMMITTED} to
// {COMMITTED, DEGRADED}. Rationale: a DEGRADED install completed all phases
// (Detect → Plan → Prepare → Switch → Configure → Validate) but ended with
// non-fatal assertion failures (e.g., chronic D-DEG-1 cascade on lab2). It
// is semantically closer to COMMITTED than to StateFailedRebuild. Operators
// running --force on a DEGRADED host without --allow-recommit are not on a
// legitimate failure-recovery path — they need the same explicit-authorization
// safety as COMMITTED hosts get. Failure-recovery flows (StateFailed*) are
// explicitly preserved unguarded; --force is the supported way to retry them.
//
// Scope: AUDIT_190_LIFECYCLE/V126_R4_DEGRADED_GATE_EXTENSION_SCOPE.md
// Reproduction: AUDIT_190_LIFECYCLE/V125_VALIDATE_LAB2_CLOSURE.md (lab2 chronic
// DEGRADED hit the gap during V125 validation; R-4 active test was
// inapplicable on DEGRADED state)
func shouldRefuseForceRecommit(currentState state.InstallState, force, allowRecommit bool) bool {
	return force &&
		(currentState == state.StateCommitted || currentState == state.StateDegraded) &&
		!allowRecommit
}

// runInstall runs all phases in order for a fresh install or upgrade.
func runInstall(ctx context.Context, exec executor.Executor, sf *state.StateFile, cfg *config, log *logging.Logger) int {
	// v1.98 Phase 2: Feature flag controls lifecycle bridge activation
	var lb *lifecycleBridge
	if cfg.lifecycle {
		log.Info("lifecycle_mode=canonized (NFTBAN_LIFECYCLE=on)")
		lb = newLifecycleBridge(cfg.mode, cfg.dryRun, log)
	} else {
		log.Info("lifecycle_mode=legacy (NFTBAN_LIFECYCLE=0)")
	}

	phases := []struct {
		phase state.Phase
		name  string
		fn    func(context.Context, executor.Executor, *state.StateFile, *logging.Logger) error
	}{
		{state.PhaseDetect, "Detect", phaseDetect},
		{state.PhasePrepare, "Prepare", phasePrepare},
		{state.PhaseSwitch, "Switch", phaseSwitch},
		{state.PhaseConfigure, "Configure", phaseConfigure},
		{state.PhaseValidate, "Validate", phaseValidate},
	}

	for _, p := range phases {
		// Check context cancellation
		if ctx.Err() != nil {
			log.Error("installer timed out or cancelled during phase %s", p.name)
			sf.Transition(state.StateFailedRebuild, p.phase, "timeout")
			if lb != nil {
				lb.observeResult(sf)
			}
			return report(sf, log)
		}

		log.Phase(p.name)
		if err := p.fn(ctx, exec, sf, log); err != nil {
			// V126.2 UX hotfix: for FAILED_AUTHORITY_ABORT only, suppress the cryptic
			// "[NFTBan ERROR] phase X failed: ..." stdout line because report() emits
			// the operator-friendly block. The internal log file still gets the error
			// via ErrorLogOnly so audit trail and diagnostic bundles are unchanged.
			// Non-ABORT failures preserve existing behavior (ERROR to stdout+log).
			// Scope: AUDIT_190_LIFECYCLE/V126_2_INSTALL_ABORT_UX_HOTFIX_SCOPE.md (REV 4).
			if sf.State == state.StateFailedAbort {
				log.ErrorLogOnly("phase %s failed: %v", p.name, err)
			} else {
				log.Error("phase %s failed: %v", p.name, err)
			}
			log.PhaseEnd(p.name)

			// V126.2: for FAILED_AUTHORITY_ABORT, skip the lifecycle bridge JSON
			// event emission to stderr (operator-noise). install_state and the
			// internal log file still capture the same outcome data, and the
			// friendly block in report() communicates the action path to the
			// operator. Lifecycle observers for non-ABORT failures are unchanged
			// so downstream consumers (CI dashboards, monitoring) continue to
			// receive their structured events.
			if lb != nil && sf.State != state.StateFailedAbort {
				if p.phase == state.PhaseDetect {
					lb.observeDetect(&globalPhaseData, sf)
					lb.observePlan(&globalPhaseData)
				}
				lb.observeResult(sf)
			}
			return report(sf, log)
		}

		// Lifecycle observations at phase boundaries (only when flag is on)
		if lb != nil {
			switch p.phase {
			case state.PhaseDetect:
				lb.observeDetect(&globalPhaseData, sf)
				lb.observePlan(&globalPhaseData)
			}
		}
	}

	// Record final lifecycle result (only when flag is on)
	if lb != nil {
		lb.observeResult(sf)
	}

	log.PhaseEnd("Validate")
	return report(sf, log)
}

// runRepair reads the state file and resumes from the last failed phase.
func runRepair(ctx context.Context, exec executor.Executor, sf *state.StateFile, log *logging.Logger) int {
	log.Info("repair mode: current state is %s", sf.State)
	log.Debug("previous failure: %s (phase=%s)", sf.FailureReason, sf.PhaseReached)

	if sf.State == state.StateCommitted {
		log.Info("system already COMMITTED, nothing to repair")
		return report(sf, log)
	}

	startPhase := sf.State.ResumePhase()
	log.Info("resuming from phase %s", startPhase)
	log.StateChange(string(sf.State), "repair", fmt.Sprintf("resume_from=%s", startPhase))

	phases := []struct {
		phase state.Phase
		name  string
		fn    func(context.Context, executor.Executor, *state.StateFile, *logging.Logger) error
	}{
		{state.PhaseDetect, "Detect", phaseDetect},
		{state.PhasePrepare, "Prepare", phasePrepare},
		{state.PhaseSwitch, "Switch", phaseSwitch},
		{state.PhaseConfigure, "Configure", phaseConfigure},
		{state.PhaseValidate, "Validate", phaseValidate},
	}

	// Always run Detect first — later phases depend on distro/panel/conflict
	// detection results (e.g. Switch needs pd.distro for xt-compat cleanup).
	// Without this, repair from SWITCH/CONFIGURE/VALIDATE would crash on nil
	// distro because Detect was skipped.
	if startPhase != state.PhaseDetect {
		log.Phase("Detect")
		if err := phaseDetect(ctx, exec, sf, log); err != nil {
			log.Warn("detect during repair: %v (continuing)", err)
		}
	}

	started := false
	lastName := ""
	for _, p := range phases {
		if p.phase == startPhase {
			started = true
		}
		if !started {
			continue
		}

		if ctx.Err() != nil {
			log.Error("installer timed out during repair phase %s", p.name)
			return report(sf, log)
		}

		log.Phase(p.name)
		if err := p.fn(ctx, exec, sf, log); err != nil {
			// V126.2 UX hotfix: same FAILED_AUTHORITY_ABORT stdout suppression as
			// the normal-mode handler above. Repair mode CAN also produce
			// StateFailedAbort if conflicts reappear before takeover is approved
			// (the second --repair run on an unchanged-state host). Internal log
			// file unchanged via ErrorLogOnly.
			// Scope: AUDIT_190_LIFECYCLE/V126_2_INSTALL_ABORT_UX_HOTFIX_SCOPE.md (REV 4).
			if sf.State == state.StateFailedAbort {
				log.ErrorLogOnly("repair phase %s failed: %v", p.name, err)
			} else {
				log.Error("repair phase %s failed: %v", p.name, err)
			}
			log.PhaseEnd(p.name)
			return report(sf, log)
		}
		lastName = p.name
	}

	if lastName != "" {
		log.PhaseEnd(lastName)
	}
	return report(sf, log)
}

// Phase implementations are in phases.go, wiring detect/render/switchop/services/validate.

// committedSummaryLine builds the operator-facing COMMITTED summary line.
//
// v1.160 PR-A (warning truth-accounting): COMMITTED means every phase committed
// and the validate assertions passed — it does NOT mean zero non-fatal warnings
// occurred. When warnings were tallied, the line says so (with the count and the
// log path to inspect) instead of the previous unconditional "no warnings".
// Pure function (no Logger dependency) so the wording is unit-testable.
func committedSummaryLine(warnCount int, logPath string) string {
	if warnCount == 0 {
		return "[NFTBan] Install/upgrade completed (state: COMMITTED, no warnings)."
	}
	noun := "warning"
	if warnCount != 1 {
		noun = "warnings"
	}
	return fmt.Sprintf(
		"[NFTBan] Install/upgrade completed (state: COMMITTED, with %d %s — non-fatal; see %s).",
		warnCount, noun, logPath,
	)
}

// report prints the final status and returns the process exit code.
func report(sf *state.StateFile, log *logging.Logger) int {
	log.Info("")

	switch sf.State {
	case state.StateCommitted:
		// v1.160 PR-A (warning truth-accounting): the v1.153 "no warnings"
		// wording was aspirational — COMMITTED is decided by validate
		// assertions, never by whether non-fatal warnings occurred, so the
		// summary used to claim "no warnings" even when WARN lines printed
		// (dns1 emitted two and still said "no warnings"). committedSummaryLine
		// now branches on log.WarnCount() so the clause matches reality, while
		// the COMMITTED/DEGRADED state selection itself is unchanged.
		log.Result("%s", committedSummaryLine(log.WarnCount(), log.LogPath()))
		log.Result("[NFTBan] State: COMMITTED")
	case state.StateDegraded:
		// v1.153 UX-T4 (message wording only): DEGRADED is the
		// committed-with-non-fatal-warnings outcome — say "with warnings"
		// explicitly so the operator-facing line is selected by the warning
		// outcome, not the bare success wording. (Flow unchanged: the state
		// machine still decides COMMITTED vs DEGRADED.)
		log.Result("[NFTBan] Install/upgrade completed with warnings (non-fatal).")
		log.Result("[NFTBan] State: DEGRADED")
		if sf.FailureReason != "" {
			log.Result("[NFTBan] Issues: %s", sf.FailureReason)
		}
		log.Result("")
		log.Result("[NFTBan] Run:")
		log.Result("[NFTBan]   nftban support")
		log.Result("[NFTBan] to generate a diagnostic bundle and optionally submit it for review.")
		log.Result("")
		// v1.131.4 (D-DEGRADED-REMEDIATION-CMD-BROKEN): use the full path —
		// `nftban-installer` is not on the operator's PATH (it lives under
		// /usr/lib/nftban/bin), so the bare form printed `command not found`.
		// Matches the full-path form already used by the FAILED-case siblings.
		log.Result("[NFTBan] To fix: /usr/lib/nftban/bin/nftban-installer --repair")
	case state.StateFailedAbort:
		// V126.2 UX hotfix: FAILED_AUTHORITY_ABORT gets a dedicated operator-friendly
		// block. Replaces the generic FAILED block (default case) which offered
		// `--repair` and `nftban firewall rebuild` as retry hints — both wrong for the
		// ABORT case (those apply to FAILED_RENDER / FAILED_REBUILD recovery).
		//
		// Also replaces the duplicate ABORTED block previously emitted by RPM/DEB
		// postinst scripts; the Go installer is now the single source of truth for
		// this message (postinst scripts shall not duplicate it).
		//
		// Critical correctness fixes from dns1 evidence + Gemini/ChatGPT review:
		//   - PRIOR DEB message instructed `NFTBAN_TAKEOVER=1 dpkg --configure nftban-core`
		//     which fails with "package already installed and configured" because dpkg
		//     considers the package configured after postinst returned (even with exit 3).
		//     The verified-working recovery path is `nftban-installer --repair`, which
		//     handles the FAILED_AUTHORITY_ABORT state-machine resume.
		//   - PRIOR two-line `export NFTBAN_TAKEOVER=1 / sudo command` form was silently
		//     stripped by `sudoers env_reset` defaults. The inline `sudo VAR=value command`
		//     form survives env_reset.
		//
		// Scope: AUDIT_190_LIFECYCLE/V126_2_INSTALL_ABORT_UX_HOTFIX_SCOPE.md (REV 4)
		log.Result("")
		log.Result("════════════════════════════════════════════════════════════════════════════════")
		log.Result("[!] NFTBan Installation Paused: Existing Firewalls Detected")
		log.Result("════════════════════════════════════════════════════════════════════════════════")
		log.Result("")
		log.Result("NFTBan found other firewall management software on this server:")
		log.Result("")
		if sf.Conflicts != "" {
			for _, c := range strings.Split(sf.Conflicts, ",") {
				c = strings.TrimSpace(c)
				if c != "" {
					log.Result("  • %s", c)
				}
			}
		} else {
			log.Result("  (detected conflicts could not be enumerated — check /var/log/nftban/installer.log)")
		}
		log.Result("")
		log.Result("For safety, NFTBan did not activate automatically.")
		log.Result("")
		log.Result("Running multiple firewall managers at the same time can cause rules to")
		log.Result("conflict or overwrite each other. In some cases, this can lock you out of")
		log.Result("the server.")
		log.Result("")
		log.Result("NFTBan is installed, but its firewall is NOT active yet.")
		log.Result("")
		log.Result("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		log.Result("OPTION 1: Let NFTBan Take Control")
		log.Result("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		log.Result("")
		log.Result("Use this option only if you want NFTBan to become the main firewall manager")
		log.Result("for this server.")
		log.Result("")
		log.Result("Run ONE of these single-line commands as root:")
		log.Result("")
		log.Result("   If you normally use sudo (most operators):")
		log.Result("       sudo NFTBAN_TAKEOVER=1 /usr/lib/nftban/bin/nftban-installer --repair")
		log.Result("")
		log.Result("   If you are already logged in as root (a # prompt):")
		log.Result("       NFTBAN_TAKEOVER=1 /usr/lib/nftban/bin/nftban-installer --repair")
		log.Result("")
		log.Result("This tells NFTBan:")
		log.Result("    \"I approve firewall takeover. Continue from where the install stopped.\"")
		log.Result("")
		log.Result("NFTBan will then disable or clean up the conflicting firewall setup and")
		log.Result("activate its own nftables firewall.")
		log.Result("")
		log.Result("The same command works on Debian/Ubuntu AND on RHEL/CentOS/AlmaLinux/Rocky —")
		log.Result("the installer binary is the same on every supported distribution.")
		log.Result("")
		log.Result("IMPORTANT — do not press Ctrl+C while it is running.")
		log.Result("    The takeover happens in phases (Detect → Prepare → Switch → Configure →")
		log.Result("    Validate). Interrupting it can leave the install in an intermediate state")
		log.Result("    requiring another --repair run.")
		log.Result("")
		log.Result("IMPORTANT — do not run dpkg --configure or rpm --reinstall again.")
		log.Result("    If a package-manager command says \"package nftban-core is already installed")
		log.Result("    and configured\", that is normal. The package manager has nothing left to do.")
		log.Result("    Use the --repair command above instead.")
		log.Result("")
		log.Result("If this server is managed by a control panel such as DirectAdmin, cPanel,")
		log.Result("Plesk, or Webmin, make sure you understand which firewall currently protects")
		log.Result("the server before continuing.")
		log.Result("")
		log.Result("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		log.Result("OPTION 2: Stop Here")
		log.Result("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		log.Result("")
		log.Result("If you are not sure, stop here.")
		log.Result("")
		log.Result("No firewall takeover has been performed.")
		log.Result("Your existing firewall setup remains in control.")
		log.Result("NFTBan will remain installed but inactive until you approve takeover.")
		log.Result("")
		log.Result("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		log.Result("After Running Option 1: Verify Status")
		log.Result("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		log.Result("")
		log.Result("NFTBan health (works on any Linux):")
		log.Result("    nftban version")
		log.Result("    systemctl is-active nftband")
		log.Result("    cat /var/lib/nftban/state/install_state")
		log.Result("")
		log.Result("Kernel-firewall actually applied (trust-but-verify):")
		log.Result("    nft list tables")
		log.Result("    nft list ruleset | grep -i nftban")
		log.Result("")
		log.Result("Optional package-state sanity (if you want extra reassurance):")
		log.Result("    Debian/Ubuntu:")
		log.Result("        dpkg -s nftban-core | grep -E \"Status|Version\"")
		log.Result("        apt-get check")
		log.Result("    RHEL/CentOS/AlmaLinux/Rocky:")
		log.Result("        rpm -q nftban-core")
		log.Result("        dnf check 2>&1 | head -5")
		log.Result("")
		log.Result("A healthy install should show:")
		log.Result("    nftband is active")
		log.Result("    INSTALL_STATE=COMMITTED")
		log.Result("    nft tables include: ip nftban, ip6 nftban")
		log.Result("    nft ruleset includes \"nftban\" rules")
		log.Result("")
		log.Result("════════════════════════════════════════════════════════════════════════════════")
	default:
		log.Result("[NFTBan] Install/upgrade FAILED.")
		log.Result("[NFTBan] State: %s", sf.State)
		if sf.FailureReason != "" {
			log.Result("[NFTBan] Reason: %s", sf.FailureReason)
		}
		log.Result("[NFTBan] To retry: /usr/lib/nftban/bin/nftban-installer --repair")
		log.Result("[NFTBan] Or: nftban firewall rebuild")
	}

	log.Info("state file: %s", sf.Path())
	log.Info("log file: %s", log.LogPath())
	log.Info("history: %s", history.DefaultHistoryPath)

	return sf.State.ExitCode()
}

// writeHistory writes a JSON entry to /var/lib/nftban/update-history.json
// compatible with `nftban update history --json`.
//
// PR-19 G3-U12 (history integrity): only StateCommitted is reported as
// success. Any other state — including non-terminal intermediate states
// from a timeout / signal mid-apply — maps to install_fail or
// verify_fail, never success. No coercion.
//
// PR-19 G3-U13 (source/package coherence): installType now has a
// "source" case. Source installs are no longer silently mislabeled as
// "rpm". Detection order: explicit --deb flag → "deb", explicit --source
// flag → "source", otherwise "rpm" (matches the RPM post-install hook
// default).
func writeHistory(sf *state.StateFile, cfg *config, previousVersion, hostname string, log *logging.Logger) {
	// Map state to history status — no success coercion for non-terminal
	// or non-committed states.
	status := historyStatusForState(sf.State)

	// Determine install type — source installs must not be silently
	// mislabeled as rpm/deb (G3-U13).
	installType := historyInstallType(cfg)

	// Duration from state file timestamp.
	durationSecs := sf.RebuildDurationMs / 1000
	if durationSecs == 0 {
		// Fallback: use wall clock from run start (captured in logger).
		durationSecs = 1
	}

	if previousVersion == "" {
		previousVersion = "none"
	}

	entry := history.NewEntry(previousVersion, sf.Version, status, installType, durationSecs, hostname)
	if err := history.WriteEntry("", entry); err != nil {
		log.Warn("failed to write update history: %v", err)
	} else {
		log.Debug("wrote history entry: %s -> %s status=%s type=%s", previousVersion, sf.Version, status, installType)
	}
}

// historyStatusForState maps an InstallState to the history status string
// without coercing non-committed states into success. Extracted from
// writeHistory so the mapping is unit-testable in isolation.
//
//	StateCommitted        → "success"
//	StateDegraded         → "verify_fail"
//	everything else       → "install_fail"  (including non-terminal
//	                                          intermediate states, which
//	                                          indicate the run was
//	                                          interrupted and never
//	                                          reached a terminal state)
func historyStatusForState(s state.InstallState) string {
	switch s {
	case state.StateCommitted:
		return history.StatusSuccess
	case state.StateDegraded:
		return history.StatusVerifyFail
	default:
		return history.StatusInstallFail
	}
}

// historyInstallType returns the install origin label for the history
// record. Priority: explicit --source > explicit --deb > explicit --rpm
// > default "rpm" (historical default for the RPM post-install hook).
//
// PR-19 G3-U13 fix: source installs were previously mislabeled as "rpm"
// because the switch only considered --deb and fell through to the
// hard-coded default.
func historyInstallType(cfg *config) string {
	switch {
	case cfg.source:
		return "source"
	case cfg.deb:
		return "deb"
	case cfg.rpm:
		return "rpm"
	default:
		// No package-manager flag passed — caller is either the RPM
		// post-install hook without the --rpm flag (legacy) or an
		// operator-initiated apply. Default to "rpm" preserves the
		// historical legacy behaviour; the history consumer can treat
		// this as "origin unknown" if stricter attribution is needed.
		return "rpm"
	}
}
