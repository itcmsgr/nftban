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
	"path/filepath"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/authority"
	"github.com/itcmsgr/nftban/internal/installer/deps"
	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/panelfw"
	"github.com/itcmsgr/nftban/internal/installer/payload"
	"github.com/itcmsgr/nftban/internal/installer/preflight"
	"github.com/itcmsgr/nftban/internal/installer/render"
	"github.com/itcmsgr/nftban/internal/installer/safety"
	"github.com/itcmsgr/nftban/internal/installer/services"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/switchop"
	"github.com/itcmsgr/nftban/internal/installer/users"
	"github.com/itcmsgr/nftban/internal/installer/validate"
)

// phaseData holds state accumulated across phases (detect→prepare→switch etc.)
// Stored on the config struct or passed via state file fields.
type phaseData struct {
	sshPort   int   // primary SSH port (back-compat scalar; used by InjectEmergencySSH, AssertSSHInLiveSet, assertions, lifecycle bridge)
	sshPorts  []int // v1.125 R-1: ALL detected sshd listener ports (primary first). len(sshPorts) >= 1 once phaseDetect completes; len > 1 on multi-port hosts (e.g., sshd on :22 + :55000). Passed to RenderNftablesConfMultiPort so the firewall allow-set covers every detected port (closes dns2-class lockout vector).
	panel     detect.PanelType
	conflicts []detect.Conflict
	decision  authority.Decision
	distro    *detect.DistroInfo
	ctLimits  detect.CTLimits
	// v1.98.x PR-14-pre: source-install fields. Populated from cfg in main()
	// before phases run. When source is true, Prepare and Configure take
	// additional branches for user/group creation, payload staging from
	// sourceDir, and safety-whitelist seeding. Package installs leave these
	// as zero-value and never reach the gated code.
	source    bool
	sourceDir string
	// v1.100 PR-22B: panel auto-takeover opt-in. Propagated from
	// cfg.panelAutoTakeover in main() before phases run. Default false —
	// panel detection alone no longer auto-approves takeover.
	panelAutoApprove bool
	// v1.100 PR26.2: PANEL-SURVIVAL-001 opt-out. Propagated from
	// cfg.noPanel in main(). When true, the panel-survival assertion
	// returns Fatal=false even on adapter failure (operator has
	// explicitly accepted the risk).
	noPanel bool
	// v1.120 (D-UPDATE-OPERATOR-SELF-BAN-GAP-001): operator-session
	// whitelist TTL. Propagated from cfg.sessionWhitelistTTL in main().
	// Default 30m (safety.DefaultSessionWhitelistTTL). Used by
	// phaseConfigure's AddSessionWhitelist call to bound the auto-seeded
	// operator SSH peer entry.
	sessionWhitelistTTL time.Duration
}

// globalPhaseData is set by phaseDetect and consumed by later phases.
// This is intentionally package-level since phases run sequentially in a single process.
var globalPhaseData phaseData

// phaseDetect discovers SSH port, panel, conflicts, distro, authority decision.
//
// V125 R-3: honors ctx cancellation at the phase entry and before the final
// authority classification. Detection itself is fast (sub-second on healthy
// hosts) but interior checks let `--timeout` reclaim wall-clock if a single
// detector hangs on a slow kernel/distro probe.
func phaseDetect(ctx context.Context, exec executor.Executor, sf *state.StateFile, log *logging.Logger) error {
	pd := &globalPhaseData

	// V125 R-3: context cancellation guard at phase entry. Returns before
	// any executor call if the global timeout already fired or the operator
	// sent SIGINT/SIGTERM during the inter-phase gap. The between-phase
	// check in main.go is the primary timeout enforcer; this is a defensive
	// belt that closes the small window where the previous phase returned
	// just as the timer expired.
	if err := ctx.Err(); err != nil {
		log.Error("phaseDetect: context cancelled before start: %v", err)
		return sf.Transition(state.StateFailedRebuild, state.PhaseDetect, "context cancelled: "+err.Error())
	}

	// 1. Detect SSH port(s). v1.125 R-1: multi-port-aware — captures the
	// full list of sshd listener ports (e.g. dns2-class hosts on :22 + :55000)
	// and the primary port (SSH_CLIENT-aware: prefers the port the operator's
	// session is connected on, else first detected). Phase data carries
	// both: pd.sshPort = primary (back-compat scalar consumed by all single-
	// port callers; install_state SSH_PORT field stays single-int), pd.sshPorts
	// = full list (consumed by phasePrepare → render.RenderNftablesConfMultiPort
	// so the rendered nftables.conf allow-set covers every detected port).
	// v1.145 PR-B2: render the FULL detected union (ss + sshd_config Port +
	// ListenAddress + state + conf.local), primary-first — not just the
	// ss-listener subset DetectSSHPorts returns — so every SSH listener port
	// is seeded into tcp_ports_in + ssh_ports at install time (no missing port
	// → no external DROP → no multi-port lockout).
	sshPorts, sshPort, err := detect.DetectSSHPortsForRender(exec, log)
	if err != nil {
		log.Error("SSH port detection failed: %v", err)
		return sf.Transition(state.StateFailedSSH, state.PhaseDetect, err.Error())
	}
	pd.sshPort = sshPort
	pd.sshPorts = sshPorts
	sf.SSHPort = sshPort // install_state keeps single-int primary (backward compatible)
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

	// V125 R-3: ctx check before authority classification. Classification
	// itself is a pure function over detected state, but reaching this point
	// means all detectors completed. If a detector hung close to the
	// global timeout, we'd rather refuse here than commit a half-detected
	// classification.
	if err := ctx.Err(); err != nil {
		log.Error("phaseDetect: context cancelled before authority classification: %v", err)
		return sf.Transition(state.StateFailedRebuild, state.PhaseDetect, "context cancelled: "+err.Error())
	}

	// 6. Authority classification
	// Read takeover flag from environment or config
	forceApprove := exec.Getenv("NFTBAN_TAKEOVER") == "1"
	pd.decision = authority.Classify(exec, pd.conflicts, pd.panel, forceApprove, pd.panelAutoApprove, log)
	sf.Authority = string(pd.decision)
	log.Detect("authority", "decision", string(pd.decision))
	log.StateChange(string(sf.State), string(state.StateDetectComplete), "authority="+string(pd.decision))

	if pd.decision == authority.Abort {
		return sf.Transition(state.StateFailedAbort, state.PhaseDetect,
			"conflicts detected, takeover not approved: "+sf.Conflicts)
	}

	// V125 R-5: disk-space preflight at the END of phaseDetect, before any
	// mutation in phasePrepare (dnf/apt install) or phaseSwitch (nft writes,
	// systemctl operations). Refuses with StateFailedPreflightDiskSpace if
	// the state-dir's filesystem has insufficient free space (default 500 MB;
	// operator-tunable via NFTBAN_MIN_DISK_FREE_MB). Closes the ENOSPC-mid-
	// install class identified in V125_INSTALL_ROBUSTNESS_SCOPE.md §3.1 R-5.
	//
	// Path target: the state-dir's filesystem. install_state, the lock file,
	// and update-history.json all land under /var/lib/nftban; that's also
	// where phasePrepare's dnf/apt caches will write. Using sf.Path() ensures
	// the check reflects the actual filesystem the installer will write into,
	// even when --state-dir overrides the default.
	stateDir := filepath.Dir(sf.Path())
	if err := preflight.EnsureMinDiskFree(stateDir, preflight.MinDiskFreeBytes()); err != nil {
		log.Error("preflight: %v", err)
		return sf.Transition(state.StateFailedPreflightDiskSpace, state.PhaseDetect, err.Error())
	}

	log.PhaseEnd("Detect")
	return sf.Transition(state.StateDetectComplete, state.PhaseDetect, "")
}

// phasePrepare runs dep install, stale cleanup, FHS setup, template rendering, config persistence.
//
// V125 R-3: honors ctx cancellation before the three heaviest operations:
// deps install (dnf/apt — minutes on cold cache), source payload staging
// (file copies), and nftables.conf render. The fast operations (mkdir,
// chmod, tmpfiles) are interior to fhs/services packages and reach their
// own kernel boundaries quickly; we don't add ctx checks for those.
func phasePrepare(ctx context.Context, exec executor.Executor, sf *state.StateFile, log *logging.Logger) error {
	pd := &globalPhaseData

	// V125 R-3: context cancellation guard at phase entry.
	if err := ctx.Err(); err != nil {
		log.Error("phasePrepare: context cancelled before start: %v", err)
		return sf.Transition(state.StateFailedRender, state.PhasePrepare, "context cancelled: "+err.Error())
	}

	// v1.98.x PR-14-pre (G-14-A): Source-install user/group creation.
	//
	// Runs first because everything downstream (fhs.EnsureDirectories,
	// fhs.SetPermissions, payload staging, chown to nftban:nftban) depends
	// on the nftban user and group existing.
	//
	// Package installs (RPM/DEB) create users/groups in %pre / postinst
	// before this phase runs, so pd.source=false here and this block is
	// skipped entirely.
	if pd.source {
		if err := users.Ensure(exec, pd.distro, log); err != nil {
			log.Error("user/group creation failed: %v", err)
			return sf.Transition(state.StateFailedRender, state.PhasePrepare,
				"user/group creation failed: "+err.Error())
		}
	}

	// V125 R-3: ctx check before deps install — the longest-running
	// operation in the installer (dnf/apt update + multi-package install
	// can take minutes on a cold-cache host). The deps package itself
	// uses exec.RunTimeout with its own per-command timeouts; this check
	// closes the gap between user/group creation and the first dnf invoke.
	if err := ctx.Err(); err != nil {
		log.Error("phasePrepare: context cancelled before deps install: %v", err)
		return sf.Transition(state.StateFailedRender, state.PhasePrepare, "context cancelled: "+err.Error())
	}

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

	// V125 R-3: ctx check before payload staging (source-install path).
	// StageAll copies the entire source tree into /usr/lib/nftban — I/O
	// bound on slow disks and can stall on full filesystems. Operators
	// running with --timeout should be able to interrupt here.
	if err := ctx.Err(); err != nil {
		log.Error("phasePrepare: context cancelled before payload staging: %v", err)
		return sf.Transition(state.StateFailedRender, state.PhasePrepare, "context cancelled: "+err.Error())
	}

	// v1.98.x PR-14-pre (G-14-B..G): Source-install payload staging.
	//
	// Must run AFTER fhs.EnsureDirectories (destination parent dirs like
	// /usr/lib/nftban/*, /etc/nftban/* must exist before WriteFileAtomic
	// can land files there). Must run BEFORE fhs.SetPermissions (so
	// enforcement has files to chown/chmod).
	//
	// Idempotent: copyIfChanged skips unchanged files, %config(noreplace)
	// entries preserve operator-edited configs, .conf.local never touched.
	if pd.source {
		if err := payload.StageAll(exec, pd.sourceDir, pd.distro, log); err != nil {
			log.Error("source payload staging failed: %v", err)
			return sf.Transition(state.StateFailedRender, state.PhasePrepare,
				"source payload staging failed: "+err.Error())
		}
	}

	// 3. Set FHS permissions
	fhs.SetPermissions(exec, log)

	// 4. Apply systemd-tmpfiles (creates /run/nftban with correct ownership)
	services.ApplyTmpfiles(exec, log)

	// 5. Set binary capabilities
	fhs.SetCapabilities(exec, log)

	// 6. Render nftables.conf (substitute SSH port + CT limits). v1.125 R-1:
	// pass the full multi-port list so the rendered tcp_ports_in allow-set
	// covers every detected sshd listener port (closes dns2-class lockout
	// vector). For single-port hosts (the common case) pd.sshPorts is a
	// single-element slice and the render output is byte-identical to the
	// v1.124 single-port code path.
	if err := render.RenderNftablesConfMultiPort(exec, pd.sshPorts, pd.ctLimits, log); err != nil {
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
//
// V125 R-3 placement constraints (carefully chosen to NOT break the invariant):
//   - Entry-guard ctx check: safe — no kernel mutation has happened yet.
//   - After step 2 (DisableConflicts) ctx check: safe — the emergency
//     table is in place and protects SSH; aborting here leaves the host
//     with emergency SSH only (degraded but reachable). A subsequent
//     repair or install run cleans up.
//   - NO ctx check between step 7 (Rebuild) and step 9 (RemoveEmergencySSH)
//     — those three steps form the atomic chain that hands SSH protection
//     from the emergency table to the nftban ruleset. Cancelling mid-chain
//     could leave the host with neither protector.
func phaseSwitch(ctx context.Context, exec executor.Executor, sf *state.StateFile, log *logging.Logger) error {
	pd := &globalPhaseData
	emergencyInjected := false

	// V125 R-3: context cancellation guard at phase entry. Safe — no
	// kernel/service mutation has happened yet.
	if err := ctx.Err(); err != nil {
		log.Error("phaseSwitch: context cancelled before start: %v", err)
		return sf.Transition(state.StateFailedRebuild, state.PhaseSwitch, "context cancelled: "+err.Error())
	}

	// 1. TAKEOVER / FRESH / AMBIGUOUS: inject emergency SSH table BEFORE any destructive action.
	// On UPDATE, nftban tables already exist with SSH in sets — no emergency needed.
	//
	// PR-22B audit fix: AMBIGUOUS (orphan table, daemon-down, etc.) is
	// added to this branch. A host in ambiguous state cannot be trusted
	// to already carry a SSH-safe nftban load, so the emergency-SSH
	// injection must run before rebuild. Omitting Ambiguous here would
	// silently continue with whatever stale kernel state the prior run
	// left — the exact regression class the audit flagged.
	if pd.decision == authority.Takeover || pd.decision == authority.Fresh || pd.decision == authority.Ambiguous {
		if err := switchop.InjectEmergencySSH(exec, pd.sshPort, log); err != nil {
			log.Error("cannot inject emergency SSH table: %v", err)
			return sf.Transition(state.StateFailedNoFirewall, state.PhaseSwitch,
				"emergency SSH inject failed: "+err.Error())
		}
		emergencyInjected = true
	}

	// 2. TAKEOVER: disable conflicting firewalls (emergency table protects SSH).
	// Ambiguous intentionally does NOT disable conflicts — the audit logic says
	// we can't prove who owns the firewall, so a conflict-disable could
	// strip the host of its actual active authority.
	if pd.decision == authority.Takeover {
		if err := switchop.DisableConflicts(exec, pd.conflicts, pd.panel, log); err != nil {
			// Emergency table LEFT IN PLACE — SSH still safe
			return sf.Transition(state.StateFailedTakeover, state.PhaseSwitch, err.Error())
		}
		log.StateChange(string(sf.State), "takeover_complete", "conflicts disabled")
	}

	// V125 R-3: ctx check after DisableConflicts and BEFORE the
	// CleanGhostTables → EnableNftables → Rebuild atomic chain begins.
	// Safe boundary: if emergency injection succeeded earlier, the
	// emergency table is protecting SSH right now. Aborting here leaves
	// the host with emergency SSH only — degraded but operator-reachable,
	// and the next install/repair will remove the emergency table cleanly.
	// Beyond this point, ctx checks are intentionally absent so the
	// Rebuild → AssertSSHInLiveSet → RemoveEmergencySSH chain remains
	// atomic and preserves the SSH safety invariant.
	if err := ctx.Err(); err != nil {
		log.Error("phaseSwitch: context cancelled before ghost-table cleanup: %v", err)
		return sf.Transition(state.StateFailedRebuild, state.PhaseSwitch, "context cancelled: "+err.Error())
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
//
// V125 R-3: honors ctx cancellation at phase entry. Interior service
// operations are short-running systemctl calls; the entry guard plus the
// existing between-phase check in main.go covers the realistic
// cancellation surface without splitting service-start ordering.
func phaseConfigure(ctx context.Context, exec executor.Executor, sf *state.StateFile, log *logging.Logger) error {
	pd := &globalPhaseData

	// V125 R-3: context cancellation guard at phase entry.
	// StateFailedRebuild is used here (consistent with the between-phase
	// check pattern in main.go and the other phase ctx guards) because
	// phaseConfigure has no dedicated FAILED_CONFIGURE state in the
	// install_state machine — services are runtime concerns and a
	// cancelled configure leaves the host in a degraded but recoverable
	// state that `--repair` will resume.
	if err := ctx.Err(); err != nil {
		log.Error("phaseConfigure: context cancelled before start: %v", err)
		return sf.Transition(state.StateFailedRebuild, state.PhaseConfigure, "context cancelled: "+err.Error())
	}

	// 1. Start daemon (socket + service)
	services.StartDaemon(exec, log)

	// 2. Reconcile timers
	services.ReconcileTimers(exec, log)

	// 3. Enable panel integration
	services.EnablePanel(exec, pd.panel, log)

	// 4. Enable login monitoring
	services.EnableLogin(exec, log)

	// v1.98.x PR-14-pre (G-14-H): Safety whitelist seed for source install.
	// Must run BEFORE SyncWhitelist so the file exists before the sync reads
	// it. Package installs skip this block (pd.source=false) because their
	// 99-manual.conf comes through the package payload (%config(noreplace)).
	// Non-fatal: SSH safety backstop (switchop.InjectEmergencySSH) runs in
	// phaseSwitch independently.
	if pd.source {
		if err := safety.SeedManualWhitelist(exec, log); err != nil {
			log.Warn("safety whitelist seed failed (non-fatal): %v", err)
		}
	}

	// v1.120 (D-UPDATE-OPERATOR-SELF-BAN-GAP-001): operator-session whitelist
	// auto-seed. UNGATED (runs for both --source AND package installs/upgrades)
	// to close the gap proven by the 2026-05-18 lab2 self-ban incident. If
	// SSH_CLIENT is empty (non-SSH invocation: cron, systemd timer, RPM/DEB
	// scriptlet without inherited env), CaptureSSHPeerIP returns "" and we
	// skip without seeding. TTL is bounded so stale entries auto-expire even
	// if cleanup never runs. Non-fatal: failure to seed does NOT block the
	// install/upgrade — the operator can still recover via the V119 runbook
	// (manual whitelist edit + reload via OOB console).
	if peerIP := safety.CaptureSSHPeerIP(); peerIP != "" {
		entry := safety.SessionWhitelistEntry{
			IP:        peerIP,
			ExpiresAt: time.Now().UTC().Add(pd.sessionWhitelistTTL),
			Reason:    "v120-update-session",
			AddedBy:   "nftban-installer",
		}
		if err := safety.AddSessionWhitelist(exec, log, entry); err != nil {
			log.Warn("session whitelist seed failed (non-fatal): %v", err)
		}
	} else {
		log.Debug("session whitelist seed skipped: SSH_CLIENT empty (non-SSH invocation)")
	}

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
//
// V125 R-3: honors ctx cancellation at phase entry and before the
// auto-fix retry path (VALIDATE_2). The retry path is the only place
// inside phaseValidate where a meaningful wall-clock budget is at risk
// — assertions themselves are quick.
func phaseValidate(ctx context.Context, exec executor.Executor, sf *state.StateFile, log *logging.Logger) error {
	pd := &globalPhaseData

	// V125 R-3: context cancellation guard at phase entry.
	if err := ctx.Err(); err != nil {
		log.Error("phaseValidate: context cancelled before start: %v", err)
		return sf.Transition(state.StateFailedRebuild, state.PhaseValidate, "context cancelled: "+err.Error())
	}

	// 1. Write authority files
	validate.WriteAuthorityFiles(exec, pd.decision, log)

	// 2. Run permissions enforce (G10 — full FHS permissions fix)
	validate.RunPermissionsEnforce(exec, log)

	// 3. Run assertions (VALIDATE_1)
	// PR26.2: derive panel-survival policy from operator flags. The
	// adapter registry is consulted by panelfw (empty in PR26.2 —
	// effectively a no-op until PR26.3 lands the first adapter).
	policy := panelfw.DefaultPolicy()
	policy.OperatorDisabled = pd.noPanel
	opts := validate.AssertionOpts{}.WithPanelPolicy(policy)
	results := validate.RunAssertionsWithOpts(exec, pd.sshPort, log, opts)

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

	// V125 R-3: ctx check before the auto-fix retry. VALIDATE_1 has
	// already run; if the context expired between then and now, prefer
	// recording the cancellation over launching a 30-second permissions
	// enforce that the caller no longer wants to wait for.
	if err := ctx.Err(); err != nil {
		log.Error("phaseValidate: context cancelled before auto-fix retry: %v", err)
		return sf.Transition(state.StateFailedRebuild, state.PhaseValidate, "context cancelled: "+err.Error())
	}

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
	results2 := validate.RunAssertionsWithOpts(exec, pd.sshPort, log, opts)

	if validate.AllPassed(results2) {
		log.Info("VALIDATE_2: all assertions passed after safe auto-fix — COMMITTED")
		_ = exec.Remove(fhs.InstallFailedMarker)
		return sf.Transition(state.StateCommitted, state.PhaseValidate, "")
	}

	// Still failing after auto-fix → DEGRADED (INV-I-008)
	failed2 := validate.FailedNames(results2)
	// v1.135: include each failing assertion's Detail (when present) so the
	// specific cause — e.g. the timer named by core_timers_active_or_scheduled_ok
	// — reaches FAILURE_REASON, not just the bare assertion name.
	var reasonParts []string
	for _, r := range results2 {
		if r.Passed {
			continue
		}
		if r.Detail != "" {
			reasonParts = append(reasonParts, r.Name+" ("+r.Detail+")")
		} else {
			reasonParts = append(reasonParts, r.Name)
		}
	}
	reason := "failed assertions after safe auto-fix: " + strings.Join(reasonParts, "; ")
	log.Warn("VALIDATE_2: %d assertions still failed — DEGRADED: %s", len(failed2), reason)
	return sf.Transition(state.StateDegraded, state.PhaseValidate, reason)
}
