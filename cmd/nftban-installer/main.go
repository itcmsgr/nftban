// =============================================================================
// NFTBan v1.73 - nftban-installer - RPM/DEB install finalizer
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Go-based RPM install finalizer replacing shell %post"
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
	"flag"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
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

	log.Info("nftban-installer %s starting (mode=%s, repair=%v)", version.Version, cfg.mode, cfg.repair)

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

	// Try to read existing state (ok if missing — fresh install)
	if err := sf.Read(); err != nil && !os.IsNotExist(err) {
		log.Warn("could not read state file: %v", err)
	}

	// Set metadata
	sf.Mode = cfg.mode
	sf.Version = version.Version

	exitCode := run(ctx, exec, sf, cfg, log)
	os.Exit(exitCode)
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
			return report(sf, log)
		}

		log.Phase(p.name)
		if err := p.fn(ctx, exec, sf, log); err != nil {
			log.Error("phase %s failed: %v", p.name, err)
			// State file already updated by the phase function
			return report(sf, log)
		}
	}

	return report(sf, log)
}

// runRepair reads the state file and resumes from the last failed phase.
func runRepair(ctx context.Context, exec executor.Executor, sf *state.StateFile, log *logging.Logger) int {
	log.Info("repair mode: current state is %s", sf.State)

	if sf.State == state.StateCommitted {
		log.Info("system already COMMITTED, nothing to repair")
		return report(sf, log)
	}

	startPhase := sf.State.ResumePhase()
	log.Info("resuming from phase %s", startPhase)

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

	started := false
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
			return report(sf, log)
		}
	}

	return report(sf, log)
}

// Phase stubs — these will be implemented in Batch 2.
// Each phase function updates the state file on success or failure.

func phaseDetect(_ context.Context, _ executor.Executor, sf *state.StateFile, log *logging.Logger) error {
	// TODO(batch2): implement detect phase (SSH, panel, conflicts, authority)
	log.Info("detect phase: not yet implemented (stub)")
	return sf.Transition(state.StateDetectComplete, state.PhaseDetect, "")
}

func phasePrepare(_ context.Context, _ executor.Executor, sf *state.StateFile, log *logging.Logger) error {
	// TODO(batch2): implement prepare phase (stale cleanup, FHS, render, config persist)
	log.Info("prepare phase: not yet implemented (stub)")
	return sf.Transition(state.StatePrepareComplete, state.PhasePrepare, "")
}

func phaseSwitch(_ context.Context, _ executor.Executor, sf *state.StateFile, log *logging.Logger) error {
	// TODO(batch2): implement switch phase (takeover, enable, rebuild, verify)
	log.Info("switch phase: not yet implemented (stub)")
	return sf.Transition(state.StateSwitchComplete, state.PhaseSwitch, "")
}

func phaseConfigure(_ context.Context, _ executor.Executor, sf *state.StateFile, log *logging.Logger) error {
	// TODO(batch2): implement configure phase (daemon, timers, panel, login, whitelist)
	log.Info("configure phase: not yet implemented (stub)")
	return sf.Transition(state.StateServicesComplete, state.PhaseConfigure, "")
}

func phaseValidate(_ context.Context, _ executor.Executor, sf *state.StateFile, log *logging.Logger) error {
	// TODO(batch2): implement validate phase (kernel assertions, authority file)
	log.Info("validate phase: not yet implemented (stub)")
	return sf.Transition(state.StateCommitted, state.PhaseValidate, "")
}

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
	log.Info("log file: %s", logging.DefaultLogPath)

	return sf.State.ExitCode()
}
