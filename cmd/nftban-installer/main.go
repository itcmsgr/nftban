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
)

// globalTimeout is the maximum wall-clock time for the entire installer run.
const globalTimeout = 300 * time.Second

func main() {
	cfg := parseFlags()

	if cfg.showVersion {
		fmt.Printf("nftban-installer %s\n", version.Version)
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

	exitCode := run(ctx, exec, sf, cfg, log)

	// Write JSON update history (compatible with nftban update history --json)
	writeHistory(sf, cfg, previousVersion, hostname, log)

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
	return runInstall(ctx, exec, sf, cfg, log)
}

// runInstall runs all phases in order for a fresh install or upgrade.
func runInstall(ctx context.Context, exec executor.Executor, sf *state.StateFile, cfg *config, log *logging.Logger) int {
	// v1.98: Initialize lifecycle bridge (observational only — INV-I-004)
	lb := newLifecycleBridge(cfg.mode, log)

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
			lb.observeResult(sf) // v1.98: record failure
			return report(sf, log)
		}

		log.Phase(p.name)
		if err := p.fn(ctx, exec, sf, log); err != nil {
			log.Error("phase %s failed: %v", p.name, err)
			log.PhaseEnd(p.name)

			// v1.98: Emit lifecycle observations for the phase that completed before failure
			if p.phase == state.PhaseDetect {
				lb.observeDetect(&globalPhaseData, sf)
				lb.observePlan(&globalPhaseData)
			}
			lb.observeResult(sf) // record failure outcome
			return report(sf, log)
		}

		// v1.98: Lifecycle observations at phase boundaries
		switch p.phase {
		case state.PhaseDetect:
			lb.observeDetect(&globalPhaseData, sf)
			lb.observePlan(&globalPhaseData)
		}
	}

	// v1.98: Record final lifecycle result
	lb.observeResult(sf)

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
func writeHistory(sf *state.StateFile, cfg *config, previousVersion, hostname string, log *logging.Logger) {
	// Map state to history status
	var status string
	switch {
	case sf.State == state.StateCommitted:
		status = history.StatusSuccess
	case sf.State == state.StateDegraded:
		status = history.StatusVerifyFail
	default:
		status = history.StatusInstallFail
	}

	// Determine install type
	installType := "rpm"
	if cfg.deb {
		installType = "deb"
	}

	// Duration from state file timestamp
	durationSecs := sf.RebuildDurationMs / 1000
	if durationSecs == 0 {
		// Fallback: use wall clock from run start (captured in logger)
		durationSecs = 1
	}

	if previousVersion == "" {
		previousVersion = "none"
	}

	entry := history.NewEntry(previousVersion, sf.Version, status, installType, durationSecs, hostname)
	if err := history.WriteEntry("", entry); err != nil {
		log.Warn("failed to write update history: %v", err)
	} else {
		log.Debug("wrote history entry: %s -> %s status=%s", previousVersion, sf.Version, status)
	}
}
