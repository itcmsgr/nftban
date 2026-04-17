// =============================================================================
// NFTBan v1.76.0 - nftban-installer - Phase Implementations
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-phases"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Phase implementations wiring detect/render/switchop/services/validate"
// meta:inventory.files="cmd/nftban-installer/phases.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package main

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/authority"
	"github.com/itcmsgr/nftban/internal/installer/deps"
	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/render"
	"github.com/itcmsgr/nftban/internal/installer/services"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/switchop"
	"github.com/itcmsgr/nftban/internal/installer/validate"
)

// phaseData holds state accumulated across phases (detect→prepare→switch etc.)
// Stored on the config struct or passed via state file fields.
type phaseData struct {
	sshPort    int
	panel      detect.PanelType
	conflicts  []detect.Conflict
	decision   authority.Decision
	distro     *detect.DistroInfo
	ctLimits   detect.CTLimits
}

// globalPhaseData is set by phaseDetect and consumed by later phases.
// This is intentionally package-level since phases run sequentially in a single process.
var globalPhaseData phaseData

// phaseDetect discovers SSH port, panel, conflicts, distro, authority decision.
func phaseDetect(_ context.Context, exec executor.Executor, sf *state.StateFile, log *logging.Logger) error {
	pd := &globalPhaseData

	// 1. Detect SSH port
	sshPort, err := detect.SSHPort(exec, log)
	if err != nil {
		log.Error("SSH port detection failed: %v", err)
		return sf.Transition(state.StateFailedSSH, state.PhaseDetect, err.Error())
	}
	pd.sshPort = sshPort
	sf.SSHPort = sshPort
	log.Detect("ssh", "port", fmt.Sprintf("%d", sshPort))

	// 2. Detect panel
	pd.panel = detect.DetectPanel(exec, log)
	sf.Panel = string(pd.panel)
	if pd.panel != detect.PanelNone {
		log.Detect("panel", "type", string(pd.panel))
	}

	// 3. Detect distro
	distro, err := detect.DetectDistro(exec, log)
	if err != nil {
		log.Warn("distro detection failed: %v — using defaults", err)
		pd.distro = &detect.DistroInfo{NftConfPath: "/etc/nftables.conf"}
	} else {
		pd.distro = distro
		log.Detect("distro", "id", distro.ID)
		log.Detect("distro", "nft_conf", distro.NftConfPath)
	}

	// 4. Detect conflicts
	pd.conflicts = detect.DetectConflicts(exec, log)
	if len(pd.conflicts) > 0 {
		names := detect.ConflictNames(pd.conflicts)
		sf.Conflicts = strings.Join(names, ",")
		log.Detect("conflicts", "services", sf.Conflicts)
	}

	// 5. Detect CT limits (for nftables rendering)
	pd.ctLimits = detect.ReadCTLimits(exec, log)
	log.Detect("ct_limits", "ssh", fmt.Sprintf("%d", pd.ctLimits.SSH))
	log.Detect("ct_limits", "http", fmt.Sprintf("%d", pd.ctLimits.HTTP))
	log.Detect("ct_limits", "mail", fmt.Sprintf("%d", pd.ctLimits.Mail))

	// 6. Authority classification
	// Read takeover flag from environment or config
	forceApprove := exec.Getenv("NFTBAN_TAKEOVER") == "1"
	pd.decision = authority.Classify(exec, pd.conflicts, pd.panel, forceApprove, log)
	sf.Authority = string(pd.decision)
	log.Detect("authority", "decision", string(pd.decision))
	log.StateChange(string(sf.State), string(state.StateDetectComplete), "authority="+string(pd.decision))

	if pd.decision == authority.Abort {
		return sf.Transition(state.StateFailedAbort, state.PhaseDetect,
			"conflicts detected, takeover not approved: "+sf.Conflicts)
	}

	log.PhaseEnd("Detect")
	return sf.Transition(state.StateDetectComplete, state.PhaseDetect, "")
}

// phasePrepare runs dep install, stale cleanup, FHS setup, template rendering, config persistence.
func phasePrepare(_ context.Context, exec executor.Executor, sf *state.StateFile, log *logging.Logger) error {
	pd := &globalPhaseData

	// 0. Install missing dependencies (dpkg/rpm lock is released by now)
	if pd.distro != nil {
		if err := deps.InstallMissing(exec, pd.distro, log); err != nil {
			log.Error("dependency install failed: %v", err)
			return sf.Transition(state.StateFailedRender, state.PhasePrepare,
				"missing critical dependencies: "+err.Error())
		}
	}

	// 1. Clean stale files from prior versions
	services.CleanStaleFiles(exec, log)

	// 2. Ensure FHS directories exist
	fhs.EnsureDirectories(exec, log)

	// 3. Set FHS permissions
	fhs.SetPermissions(exec, log)

	// 4. Apply systemd-tmpfiles (creates /run/nftban with correct ownership)
	services.ApplyTmpfiles(exec, log)

	// 5. Set binary capabilities
	fhs.SetCapabilities(exec, log)

	// 6. Render nftables.conf (substitute SSH port + CT limits)
	if err := render.RenderNftablesConf(exec, pd.sshPort, pd.ctLimits, log); err != nil {
		log.Error("nftables.conf render failed: %v", err)
		return sf.Transition(state.StateFailedRender, state.PhasePrepare, err.Error())
	}

	// 7. Integrate NFTBan include into system nftables.conf
	if pd.distro != nil && pd.distro.NftConfPath != "" {
		if err := render.IntegrateSystemConf(exec, pd.distro.NftConfPath, log); err != nil {
			log.Warn("system conf integration: %v", err)
			// Non-fatal — system conf might not exist
		}
	}

	// 8. Persist SSH port to conf.local and state file
	render.PersistSSHPort(exec, pd.sshPort, log)

	log.PhaseEnd("Prepare")
	return sf.Transition(state.StatePrepareComplete, state.PhasePrepare, "")
}

// phaseSwitch disables conflicts, enables nftables, runs rebuild.
//
// SSH Safety Invariant: At every point during this function, at least one of:
//   - The pre-existing firewall is still running and accepting SSH, OR
//   - The inet nftban_install_emergency table exists accepting SSH, OR
//   - The nftban ruleset is loaded with SSH port in tcp_ports_in
func phaseSwitch(_ context.Context, exec executor.Executor, sf *state.StateFile, log *logging.Logger) error {
	pd := &globalPhaseData
	emergencyInjected := false

	// 1. TAKEOVER / FRESH: inject emergency SSH table BEFORE any destructive action.
	// On UPDATE, nftban tables already exist with SSH in sets — no emergency needed.
	if pd.decision == authority.Takeover || pd.decision == authority.Fresh {
		if err := switchop.InjectEmergencySSH(exec, pd.sshPort, log); err != nil {
			log.Error("cannot inject emergency SSH table: %v", err)
			return sf.Transition(state.StateFailedNoFirewall, state.PhaseSwitch,
				"emergency SSH inject failed: "+err.Error())
		}
		emergencyInjected = true
	}

	// 2. TAKEOVER: disable conflicting firewalls (emergency table protects SSH)
	if pd.decision == authority.Takeover {
		if err := switchop.DisableConflicts(exec, pd.conflicts, pd.panel, log); err != nil {
			// Emergency table LEFT IN PLACE — SSH still safe
			return sf.Transition(state.StateFailedTakeover, state.PhaseSwitch, err.Error())
		}
		log.StateChange(string(sf.State), "takeover_complete", "conflicts disabled")
	}

	// 3. Clean ghost tables (all paths). Emergency table is NOT cleaned here —
	// its lifecycle is managed explicitly below.
	switchop.CleanGhostTables(exec, log)

	// 4. Enable nftables service
	if err := switchop.EnableNftables(exec, pd.distro, log); err != nil {
		// Emergency table LEFT IN PLACE — SSH still safe
		return sf.Transition(state.StateFailedNoFirewall, state.PhaseSwitch, err.Error())
	}

	// 5. Assert SSH port is in live nft sets (NOW nftban tables exist)
	switchop.AssertSSHInLiveSet(exec, pd.sshPort, log)

	// 6. daemon-reload (pick up any new unit files)
	if err := exec.DaemonReload(); err != nil {
		log.Warn("daemon-reload: %v", err)
	}

	// 7. REBUILD — FATAL on failure (v1.70.0 invariant)
	if err := switchop.Rebuild(exec, log); err != nil {
		// Emergency table LEFT IN PLACE — SSH still safe
		return sf.Transition(state.StateFailedRebuild, state.PhaseSwitch, err.Error())
	}

	// 8. Post-rebuild: re-assert SSH in live sets (belt-and-suspenders)
	switchop.AssertSSHInLiveSet(exec, pd.sshPort, log)

	// 9. Remove emergency SSH table — nftban rules proven in kernel
	if emergencyInjected {
		switchop.RemoveEmergencySSH(exec, log)
	}

	log.PhaseEnd("Switch")
	return sf.Transition(state.StateSwitchComplete, state.PhaseSwitch, "")
}

// phaseConfigure starts daemon, timers, panel, login, whitelist sync.
func phaseConfigure(_ context.Context, exec executor.Executor, sf *state.StateFile, log *logging.Logger) error {
	pd := &globalPhaseData

	// 1. Start daemon (socket + service)
	services.StartDaemon(exec, log)

	// 2. Reconcile timers
	services.ReconcileTimers(exec, log)

	// 3. Enable panel integration
	services.EnablePanel(exec, pd.panel, log)

	// 4. Enable login monitoring
	services.EnableLogin(exec, log)

	// 5. Whitelist sync (loads whitelists and feeds)
	services.SyncWhitelist(exec, log)

	// 6. Restart polkit (picks up new/removed polkit rules)
	services.RestartPolkit(exec, log)

	log.PhaseEnd("Configure")
	return sf.Transition(state.StateServicesComplete, state.PhaseConfigure, "")
}

// phaseValidate runs post-install assertions, writes authority files, sets immutable flags.
//
// v1.98 flow (INV-I-010 through INV-I-013):
//   1. Write authority files
//   2. Run permissions enforce (safe auto-fix for FHS drift)
//   3. Run assertions (VALIDATE_1)
//   4. If assertions fail → try health fix once (safe auto-fix)
//   5. Re-run assertions (VALIDATE_2) — only post-fix result counts
//   6. Set immutable flags
//   7. Final result from VALIDATE_2 (or VALIDATE_1 if no fix needed)
func phaseValidate(_ context.Context, exec executor.Executor, sf *state.StateFile, log *logging.Logger) error {
	pd := &globalPhaseData

	// 1. Write authority files
	validate.WriteAuthorityFiles(exec, pd.decision, log)

	// 2. Run permissions enforce (G10 — full FHS permissions fix)
	validate.RunPermissionsEnforce(exec, log)

	// 3. Run assertions (VALIDATE_1)
	results := validate.RunAssertions(exec, pd.sshPort, log)

	// 4. Set immutable flags on security-critical files (G8)
	validate.SetImmutableFlags(exec, log)

	if validate.AllPassed(results) {
		log.Info("all post-install assertions passed — COMMITTED")
		_ = exec.Remove(fhs.InstallFailedMarker)
		return sf.Transition(state.StateCommitted, state.PhaseValidate, "")
	}

	// v1.98 INV-I-010: Some assertions failed → try safe auto-fix ONCE
	failed := validate.FailedNames(results)
	log.Warn("VALIDATE_1: %d assertions failed: %s", len(failed), strings.Join(failed, ", "))
	log.Info("attempting bounded safe auto-fix (permissions enforce only, INV-I-011/012)...")

	// Run ONLY permissions enforce — bounded, safe, idempotent (INV-I-011).
	// This fixes ownership/mode on NFTBan-managed paths only.
	// Does NOT run 'health fix all' which would cross authority boundaries
	// (disabling UFW/firewalld/fail2ban, triggering rebuild, GeoIP download, etc.)
	fixRes := exec.RunTimeout(30*time.Second, fhs.NftbanCLI, "permissions", "enforce")
	if fixRes.ExitCode == 0 {
		log.Info("permissions enforce completed — re-validating (INV-I-013)")
	} else {
		log.Warn("permissions enforce returned exit %d — re-validating anyway", fixRes.ExitCode)
	}

	// v1.98 INV-I-013: Re-run assertions (VALIDATE_2) — only this result counts
	results2 := validate.RunAssertions(exec, pd.sshPort, log)

	if validate.AllPassed(results2) {
		log.Info("VALIDATE_2: all assertions passed after safe auto-fix — COMMITTED")
		_ = exec.Remove(fhs.InstallFailedMarker)
		return sf.Transition(state.StateCommitted, state.PhaseValidate, "")
	}

	// Still failing after auto-fix → DEGRADED (INV-I-008)
	failed2 := validate.FailedNames(results2)
	reason := "failed assertions after safe auto-fix: " + strings.Join(failed2, ", ")
	log.Warn("VALIDATE_2: %d assertions still failed — DEGRADED: %s", len(failed2), reason)
	return sf.Transition(state.StateDegraded, state.PhaseValidate, reason)
}
