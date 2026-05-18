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
			log.Error("phase %s failed: %v", p.name, err)
			log.PhaseEnd(p.name)

			if lb != nil {
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
			log.Error("repair phase %s failed: %v", p.name, err)
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

// report prints the final status and returns the process exit code.
func report(sf *state.StateFile, log *logging.Logger) int {
	log.Info("")

	switch sf.State {
	case state.StateCommitted:
		log.Result("[NFTBan] Install/upgrade completed successfully.")
		log.Result("[NFTBan] State: COMMITTED")
	case state.StateDegraded:
		log.Result("[NFTBan] Install/upgrade completed with warnings.")
		log.Result("[NFTBan] State: DEGRADED")
		if sf.FailureReason != "" {
			log.Result("[NFTBan] Issues: %s", sf.FailureReason)
		}
		log.Result("")
		log.Result("[NFTBan] Run:")
		log.Result("[NFTBan]   nftban support")
		log.Result("[NFTBan] to generate a diagnostic bundle and optionally submit it for review.")
		log.Result("")
		log.Result("[NFTBan] To fix: nftban-installer --repair")
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
