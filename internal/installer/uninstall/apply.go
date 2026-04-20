// =============================================================================
// NFTBan v1.100 PR-23 — Uninstall Mutation Phase 1 (Authority Release Core)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-uninstall-apply"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-20"
// meta:description="Authority release core — PR-23 uninstall mutation orchestrator"
// meta:inventory.files="internal/installer/uninstall/apply.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftband.service"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// PR-23 authorized scope (frozen 2026-04-20):
//
//   Allowed mutation:
//     - releasing nftban kernel authority (flush + delete ip/ip6 nftban tables)
//     - controlled teardown of nftban-owned service (stop + disable + mask)
//     - emergency SSH safety injection before mutation, removal after success
//
//   NOT allowed (non-goals):
//     - external firewall restoration (PR-24)
//     - filesystem artifact deletion / purge semantics (PR-25)
//     - .conf.local touch — read or write
//     - cross-system cleanup (logrotate, timers beyond mask, user/group)
//     - any package-manager transactions
//
// This file is the ONLY mutation path in the uninstall package. Every
// other file in internal/installer/uninstall/ (authority.go, prior.go,
// plan.go) remains strictly read-only — the G3-UN-NO-MUTATION CI gate
// scopes its structural audit to exclude this file explicitly.
//
// Caller contract:
//   - Operator passed --confirm-mutation on the CLI (flags.go validates)
//   - Caller classified authority via Classify() and verified one of:
//       * Classify().State == AuthorityNFTBan
//       * Classify().State == AuthorityAmbiguous AND
//         Classify().Ambiguity == AmbiguityOrphanNFTBan
//     Any other pre-state must refuse BEFORE calling Apply.
//
// =============================================================================
package uninstall

import (
	"fmt"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/switchop"
)

// ApplyConfig is the input to Apply. Intentionally minimal — Apply is
// authority release core and should not grow consumer-specific knobs.
type ApplyConfig struct {
	// SSHPort is the port the emergency SSH safety table accepts on.
	// Must be > 0 and a valid TCP port.
	SSHPort int
}

// ApplyResult is the output of Apply. Consumed by the dispatcher
// (cmd/nftban-installer/uninstall_apply.go) to transition the state
// file and set the process exit code.
type ApplyResult struct {
	// State is the terminal installer state the dispatcher should
	// persist via sf.Transition. Exactly one of:
	//   StateUninstallReleased     — full success
	//   StateUninstallFailedRelease — kernel mutation started but
	//                                 did not complete / validate
	//   StateDegraded              — kernel released but service
	//                                 teardown incomplete (authority
	//                                 released, state persists)
	//   StateFailedNoFirewall      — emergency SSH inject failed;
	//                                 no mutation was attempted
	State state.InstallState
	// Reason is the human-readable rationale for State. Placed in the
	// state file's FailureReason on failure, logged on success.
	Reason string
	// EmergencyInjected reports whether the emergency SSH table was
	// inserted during this run. True means the table was put in place;
	// for StateUninstallReleased it has been cleanly removed, for
	// failure states it MAY still be present as a safety net (leaving
	// it up is the deliberate failure-mode behaviour — an
	// over-permissive SSH rule is safer than a potential lockout).
	EmergencyInjected bool
	// Steps is an ordered audit trail of each mutation step attempted.
	// Used by the dispatcher for real-host evidence output + test
	// assertions.
	Steps []StepResult
}

// StepResult records the outcome of one Apply step.
type StepResult struct {
	Name    string
	Success bool
	Detail  string
}

// Apply runs the PR-23 authority release mutation sequence.
//
// The sequence is 10 explicit steps, executed in order:
//
//	 1. Inject emergency SSH safety table (inet nftban_install_emergency)
//	 2. Stop nftband.service (prevent it from fighting kernel mutation)
//	 3. Flush ip nftban table
//	 4. Flush ip6 nftban table (if present)
//	 5. Delete ip nftban table
//	 6. Delete ip6 nftban table (if present)
//	 7. Disable nftband.service
//	 8. Mask nftband.service (prevent any re-enable path)
//	 9. Validate end-state:
//	      - no ip nftban / ip6 nftban tables
//	      - nftband.service not active
//	      - emergency SSH table STILL PRESENT (step 10 removes it)
//	10. Remove emergency SSH table (warn-only on failure — leaving an
//	    over-permissive SSH rule in place is safer than lockout)
//
// Failure mapping:
//
//	Step 1 fails   → StateFailedNoFirewall (no kernel mutation; safe to retry)
//	Step 2 fail    → log warn, continue (stop-of-already-stopped is OK)
//	Steps 3-6 fail → StateUninstallFailedRelease (kernel partial; emergency up)
//	Steps 7-8 fail → StateDegraded (kernel released; service lingers)
//	Step 9 fail    → StateUninstallFailedRelease (end-state mismatch)
//	Step 10 fail   → log warn; State stays StateUninstallReleased (over-permissive safer than lockout)
//	All pass       → StateUninstallReleased
func Apply(exec executor.Executor, cfg *ApplyConfig, log *logging.Logger) *ApplyResult {
	r := &ApplyResult{}

	// Step 1 — emergency SSH safety net MUST land before any mutation.
	log.Info("uninstall apply: step 1/10 — injecting emergency SSH safety net (port %d)", cfg.SSHPort)
	if err := switchop.InjectEmergencySSH(exec, cfg.SSHPort, log); err != nil {
		r.Steps = append(r.Steps, StepResult{Name: "inject_emergency_ssh", Success: false, Detail: err.Error()})
		r.State = state.StateFailedNoFirewall
		r.Reason = fmt.Sprintf("inject emergency SSH failed: %v — no kernel mutation performed", err)
		log.Error("uninstall apply: step 1 FAILED; aborting before any mutation")
		return r
	}
	r.EmergencyInjected = true
	r.Steps = append(r.Steps, StepResult{Name: "inject_emergency_ssh", Success: true, Detail: "emergency SSH table injected (priority -1, policy accept)"})

	// Step 2 — stop the daemon so it can't fight the kernel mutation.
	// Stop-of-already-stopped returns success on most systemctl
	// implementations; a hard failure here is tolerated (logged) and
	// we push through because the subsequent flush+delete IS the
	// authority release, and the daemon without its kernel tables has
	// no firewall job to do.
	log.Info("uninstall apply: step 2/10 — stopping nftband.service")
	if err := exec.ServiceStop("nftband.service"); err != nil {
		log.Warn("stop nftband.service: %v (continuing; daemon may already be stopped)", err)
		r.Steps = append(r.Steps, StepResult{Name: "stop_nftband", Success: false, Detail: err.Error()})
	} else {
		r.Steps = append(r.Steps, StepResult{Name: "stop_nftband", Success: true})
	}

	// Step 3 — flush ip nftban.
	log.Info("uninstall apply: step 3/10 — flushing ip nftban table")
	if res := exec.Run("nft", "flush", "table", "ip", "nftban"); res.ExitCode != 0 {
		r.Steps = append(r.Steps, StepResult{Name: "flush_ip_nftban", Success: false, Detail: res.Stderr})
		r.State = state.StateUninstallFailedRelease
		r.Reason = "flush ip nftban table failed: " + res.Stderr
		log.Error("uninstall apply: step 3 FAILED; emergency SSH still in place, operator must resolve")
		return r
	}
	r.Steps = append(r.Steps, StepResult{Name: "flush_ip_nftban", Success: true})

	// Step 4 — flush ip6 nftban (may legitimately not exist).
	log.Info("uninstall apply: step 4/10 — flushing ip6 nftban table (if present)")
	if exec.NftTableExists("ip6", "nftban") {
		if res := exec.Run("nft", "flush", "table", "ip6", "nftban"); res.ExitCode != 0 {
			r.Steps = append(r.Steps, StepResult{Name: "flush_ip6_nftban", Success: false, Detail: res.Stderr})
			r.State = state.StateUninstallFailedRelease
			r.Reason = "flush ip6 nftban table failed: " + res.Stderr
			return r
		}
		r.Steps = append(r.Steps, StepResult{Name: "flush_ip6_nftban", Success: true})
	} else {
		r.Steps = append(r.Steps, StepResult{Name: "flush_ip6_nftban", Success: true, Detail: "skipped — no ip6 nftban table"})
	}

	// Step 5 — delete ip nftban.
	log.Info("uninstall apply: step 5/10 — deleting ip nftban table")
	if err := exec.NftDeleteTable("ip", "nftban"); err != nil {
		r.Steps = append(r.Steps, StepResult{Name: "delete_ip_nftban", Success: false, Detail: err.Error()})
		r.State = state.StateUninstallFailedRelease
		r.Reason = "delete ip nftban table failed: " + err.Error()
		return r
	}
	r.Steps = append(r.Steps, StepResult{Name: "delete_ip_nftban", Success: true})

	// Step 6 — delete ip6 nftban (may legitimately not exist).
	log.Info("uninstall apply: step 6/10 — deleting ip6 nftban table (if present)")
	if exec.NftTableExists("ip6", "nftban") {
		if err := exec.NftDeleteTable("ip6", "nftban"); err != nil {
			r.Steps = append(r.Steps, StepResult{Name: "delete_ip6_nftban", Success: false, Detail: err.Error()})
			r.State = state.StateUninstallFailedRelease
			r.Reason = "delete ip6 nftban table failed: " + err.Error()
			return r
		}
		r.Steps = append(r.Steps, StepResult{Name: "delete_ip6_nftban", Success: true})
	} else {
		r.Steps = append(r.Steps, StepResult{Name: "delete_ip6_nftban", Success: true, Detail: "skipped — no ip6 nftban table"})
	}

	// Step 7 — disable nftband.service.
	log.Info("uninstall apply: step 7/10 — disabling nftband.service")
	if err := exec.ServiceDisable("nftband.service"); err != nil {
		r.Steps = append(r.Steps, StepResult{Name: "disable_nftband", Success: false, Detail: err.Error()})
		// Kernel is released (steps 3-6 succeeded). Service teardown
		// incomplete → partial success → Degraded.
		r.State = state.StateDegraded
		r.Reason = "authority released but nftband.service disable failed: " + err.Error()
		return r
	}
	r.Steps = append(r.Steps, StepResult{Name: "disable_nftband", Success: true})

	// Step 8 — mask nftband.service (prevents accidental restart).
	log.Info("uninstall apply: step 8/10 — masking nftband.service")
	if err := exec.ServiceMask("nftband.service"); err != nil {
		r.Steps = append(r.Steps, StepResult{Name: "mask_nftband", Success: false, Detail: err.Error()})
		r.State = state.StateDegraded
		r.Reason = "authority released but nftband.service mask failed: " + err.Error()
		return r
	}
	r.Steps = append(r.Steps, StepResult{Name: "mask_nftband", Success: true})

	// Step 9 — end-state validation. Proves the release claim directly
	// rather than trusting step return codes. Emergency SSH table must
	// STILL be present; step 10 removes it.
	log.Info("uninstall apply: step 9/10 — validating end-state")
	if exec.NftTableExists("ip", "nftban") {
		r.Steps = append(r.Steps, StepResult{Name: "validate_end_state", Success: false, Detail: "ip nftban table still present after delete"})
		r.State = state.StateUninstallFailedRelease
		r.Reason = "post-mutation validation failed: ip nftban table still exists"
		return r
	}
	if exec.NftTableExists("ip6", "nftban") {
		r.Steps = append(r.Steps, StepResult{Name: "validate_end_state", Success: false, Detail: "ip6 nftban table still present after delete"})
		r.State = state.StateUninstallFailedRelease
		r.Reason = "post-mutation validation failed: ip6 nftban table still exists"
		return r
	}
	if exec.ServiceActive("nftband.service") {
		r.Steps = append(r.Steps, StepResult{Name: "validate_end_state", Success: false, Detail: "nftband.service still active after stop+disable+mask"})
		r.State = state.StateUninstallFailedRelease
		r.Reason = "post-mutation validation failed: nftband.service still active"
		return r
	}
	// Correction 2 locked 2026-04-20: validation MUST assert emergency
	// SSH is STILL PRESENT here. Step 10 is what removes it.
	if !exec.NftTableExists("inet", "nftban_install_emergency") {
		r.Steps = append(r.Steps, StepResult{Name: "validate_end_state", Success: false, Detail: "emergency SSH table unexpectedly missing at step 9"})
		r.State = state.StateUninstallFailedRelease
		r.Reason = "post-mutation validation failed: emergency SSH table disappeared unexpectedly before step 10"
		return r
	}
	r.Steps = append(r.Steps, StepResult{Name: "validate_end_state", Success: true, Detail: "nftban kernel + service released; emergency SSH still intact pending step 10"})

	// Step 10 — remove emergency SSH. Failure is warn-only: leaving an
	// over-permissive SSH rule in place is safer than risking lockout.
	// RemoveEmergencySSH logs its own warning internally if it fails.
	log.Info("uninstall apply: step 10/10 — removing emergency SSH safety net")
	switchop.RemoveEmergencySSH(exec, log)
	r.Steps = append(r.Steps, StepResult{Name: "remove_emergency_ssh", Success: true, Detail: "warn-only on failure per PR-23 safety policy"})

	// All 10 steps green — authority released.
	r.State = state.StateUninstallReleased
	r.Reason = "nftban authority released: kernel tables deleted, nftband.service stopped+disabled+masked, emergency SSH cleaned up"
	log.Result("[NFTBan] uninstall complete — nftban authority released")
	return r
}
