// =============================================================================
// NFTBan v1.100 PR-23 — Uninstall Apply Dispatcher
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-uninstall-apply"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-20"
// meta:description="--mode=uninstall --confirm-mutation dispatcher: preflight + Apply + state transition"
// meta:inventory.files="cmd/nftban-installer/uninstall_apply.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftband.service"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// This dispatcher is the ONLY entry into uninstall mutation. Reached
// only when:
//
//   cfg.mode             == "uninstall"  AND
//   cfg.confirmMutation  == true         AND
//   cfg.dryRun           == false
//
// (flags.go rejects any other combination at parse time.)
//
// Responsibilities:
//
//   1. Detect SSH port (reused from install-side detect package).
//   2. Classify current authority (via uninstall.Classify).
//   3. Preflight refusal for non-recoverable states; proceed for
//      AuthorityNFTBan or recoverable AuthorityAmbiguous+OrphanNFTBan.
//   4. Invoke uninstall.Apply for the mutation sequence.
//   5. Transition the state file to the Apply result's terminal state.
//
// Emergency SSH: Apply handles the entire inject/validate/remove cycle
// internally. The dispatcher never touches the kernel directly.
//
// History: intentionally NOT written for uninstall mode. main.go's
// writeHistory guard excludes cfg.mode=="uninstall" (Option A locked
// 2026-04-20). Uninstall events are forensically visible only in the
// installer log until a dedicated uninstall-history schema lands in a
// later PR.
//
// =============================================================================
package main

import (
	"context"
	"fmt"
	"os"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// runUninstallApply orchestrates the PR-23 authority release path.
// Returns the process exit code derived from the final state.
func runUninstallApply(_ context.Context, exec executor.Executor, sf *state.StateFile, cfg *config, log *logging.Logger) int {
	log.Info("uninstall apply starting (mode=uninstall, confirm-mutation=true)")

	// 1. SSH port — needed for the emergency SSH safety table.
	sshPort, sshErr := detect.SSHPort(exec, log)
	if sshErr != nil {
		log.Error("uninstall apply: SSH port detection failed: %v", sshErr)
		_ = sf.Transition(state.StateFailedSSH, state.PhaseDetect,
			"SSH port detection failed: "+sshErr.Error())
		return sf.State.ExitCode()
	}
	log.Detect("ssh", "port", fmt.Sprintf("%d", sshPort))
	sf.SSHPort = sshPort

	// 2. Classify authority.
	auth := uninstall.Classify(exec, log)
	log.Info("uninstall apply: authority=%s ambiguity=%s external=%s",
		auth.State, auth.Ambiguity, auth.External)

	// 3. Preflight decision table.
	proceed := false
	var refuseReason string
	switch {
	case auth.State == uninstall.AuthorityNFTBan:
		proceed = true
	case auth.State == uninstall.AuthorityAmbiguous && auth.Ambiguity == uninstall.AmbiguityOrphanNFTBan:
		// PR-23 correction 1 (locked 2026-04-20): recoverable ambiguity.
		// Orphan nftban kernel/service artifacts with no external
		// authority observable — Apply proceeds via the emergency-SSH-
		// injected cleanup path.
		log.Info("uninstall apply: recoverable ambiguity (orphan_nftban) — proceeding with cleanup")
		proceed = true
	case auth.State == uninstall.AuthorityAmbiguous && auth.Ambiguity == uninstall.AmbiguityConflictExternal:
		refuseReason = "authority is ambiguous (external firewall conflict); operator must resolve before uninstall mutation can proceed"
	case auth.State == uninstall.AuthorityExternal:
		refuseReason = "nftban is not authoritative (" + auth.External + " appears to own the firewall); nothing to release"
	case auth.State == uninstall.AuthorityNone:
		refuseReason = "no firewall authority detected; nothing to release"
	default:
		refuseReason = "unknown authority state: " + string(auth.State)
	}

	if !proceed {
		log.Error("uninstall apply: preflight REFUSED — %s", refuseReason)
		fmt.Fprintln(os.Stderr, "uninstall apply: preflight refused — "+refuseReason)
		_ = sf.Transition(state.StateFailedAbort, state.PhaseDetect, refuseReason)
		return sf.State.ExitCode()
	}

	// 4. Apply the mutation sequence.
	//
	// Mode comes from the operator's --purge / --force-delete-operator-config
	// flags via modeFromFlags (defined in uninstall_dryrun.go). v1.100.4
	// (UPSTREAM-UNINSTALL-INCOMPLETE-001) wires this through ApplyConfig
	// so artifact removal can honour the §4.4 mode contract.
	//
	// Distro is detected for the polkit-destination branch in
	// payload.Destinations. Third-audit item B: detection failure must NOT
	// silently default to the RHEL polkit dir — that would skip Debian
	// polkit residue. On error: log WARN and pass nil; artifacts.go's
	// polkit-fallback enumerates BOTH /etc/polkit-1/rules.d and
	// /usr/share/polkit-1/rules.d so neither family's residue survives.
	distroInfo, distroErr := detect.DetectDistro(exec, log)
	if distroErr != nil {
		log.Warn("uninstall apply: distro detection failed: %v — polkit cleanup will enumerate both Debian and RHEL destinations as a fallback", distroErr)
		distroInfo = nil
	}
	result := uninstall.Apply(exec, &uninstall.ApplyConfig{
		SSHPort: sshPort,
		Mode:    modeFromFlags(cfg),
		Distro:  distroInfo,
	}, log)

	// 5. Persist terminal state. sf.Transition returns a non-nil error
	// for failure states (so phase runners halt); here we ignore that
	// signal because the dispatcher IS the halt point.
	_ = sf.Transition(result.State, state.PhaseSwitch, result.Reason)

	// Step-by-step evidence log for operator forensics + CI real-host
	// evidence capture. Every step is logged regardless of outcome.
	log.Info("uninstall apply: %d steps executed:", len(result.Steps))
	for i, s := range result.Steps {
		verdict := "ok"
		if !s.Success {
			verdict = "FAIL"
		}
		log.Info("  step %d %-28s %s  %s", i+1, s.Name, verdict, s.Detail)
	}

	if result.State == state.StateUninstallReleased {
		log.Result("[NFTBan] uninstall: authority released; nftban is no longer authoritative on this host")
	} else {
		log.Result("[NFTBan] uninstall: %s — %s", result.State, result.Reason)
	}

	return sf.State.ExitCode()
}
