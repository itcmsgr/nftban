// =============================================================================
// NFTBan v1.198.1 - nftban-installer - --revalidate (restart-free recommit)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-revalidate"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-22"
// meta:description="v1.198.1 PR-B (D-V198-STICKY-DEGRADED-NO-RECOMMIT-PATH): restart-free recompute of a stale DEGRADED install_state from the live post-install assertion suite only — no install, no daemon restart. DEGRADED→COMMITTED only when every live assertion passes; never masks a real failure."
// meta:inventory.files="cmd/nftban-installer/revalidate.go"
// meta:inventory.binaries="nftban-installer"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package main

import (
	"context"
	"strings"

	"github.com/itcmsgr/nftban/internal/healthresource"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/panelfw"
	"github.com/itcmsgr/nftban/internal/installer/services"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/validate"
	"github.com/itcmsgr/nftban/pkg/version"
)

// runRevalidate implements `nftban-installer --revalidate` — the v1.198.1 PR-B
// official, non-manual, restart-free recompute of a stale DEGRADED install_state
// (D-V198-STICKY-DEGRADED-NO-RECOMMIT-PATH).
//
// It does NOT install packages, render the firewall, or restart the daemon. It
// re-runs ONLY the live post-install assertion suite (validate.RunAssertionsWithOpts,
// the same suite the VALIDATE phase uses — which performs the v1.174/v1.185.1
// stale-latched-oneshot recovery, now incl. the nftban-alert@ template via PR-B's
// staleClearableOneshotStems entry) and rewrites install_state via the official
// StateFile.Transition writer.
//
// Safety contract (MUST NOT mask a real failure):
//   - Acts only on a DEGRADED state. COMMITTED → no-op. Any other / FAILED_* state
//     → refuse (use --repair or re-run the upgrade).
//   - Refuses when the recorded install version != the running binary version.
//   - Transitions to COMMITTED ONLY when validate.AllPassed over the LIVE suite is
//     true; otherwise re-writes DEGRADED with the current live failure reason. A
//     genuinely-still-failed unit, a non-zero validator, a missing table, an
//     inactive daemon, etc. all keep it DEGRADED (the assertions fail closed).
func runRevalidate(ctx context.Context, exec executor.Executor, sf *state.StateFile, cfg *config, log *logging.Logger) int {
	// Read the on-disk record authoritatively: main() already overwrote
	// sf.Version with the running binary version, so re-read for the recorded
	// version/ssh-port/mode/state.
	cur := state.NewStateFile(cfg.stateDir)
	if err := cur.Read(); err != nil {
		log.Error("revalidate: cannot read install_state at %s: %v", cur.Path(), err)
		log.Info("revalidate recomputes an EXISTING install_state; none is present — nothing to do")
		return state.ExitRefused
	}

	if err := ctx.Err(); err != nil {
		log.Error("revalidate: context cancelled before start: %v", err)
		return state.ExitFatal
	}

	switch cur.State {
	case state.StateCommitted:
		log.Info("revalidate: install_state already COMMITTED — nothing to recommit")
		return state.ExitCommitted
	case state.StateDegraded:
		// the one recoverable terminal — proceed
	default:
		log.Error("revalidate: install_state=%s is not DEGRADED — recommit only recomputes a DEGRADED record", cur.State)
		log.Info("revalidate: for a failed install use 'nftban update repair' or re-run the upgrade; revalidate will not touch %s", cur.State)
		return state.ExitRefused
	}

	// Version guard: the DEGRADED record must belong to the currently installed
	// version. A mismatch means the marker is from a different install; stamping
	// COMMITTED onto it would be dishonest.
	if cur.Version != "" && cur.Version != version.Version {
		log.Error("revalidate: install_state version %q != running nftban-installer version %q — refusing to recommit a mismatched record", cur.Version, version.Version)
		log.Info("revalidate: re-run the upgrade to %s, then recommit if needed", version.Version)
		return state.ExitRefused
	}

	sshPort := cur.SSHPort
	if sshPort <= 0 {
		sshPort = 22
		log.Warn("revalidate: install_state carries no SSH_PORT; assuming %d for the SSH-in-set assertion", sshPort)
	}

	log.Info("revalidate: recomputing install_state from LIVE post-install assertions (version=%s ssh_port=%d) — no install, no daemon restart", version.Version, sshPort)

	policy := panelfw.DefaultPolicy()
	policy.OperatorDisabled = cfg.noPanel
	opts := validate.AssertionOpts{}.WithPanelPolicy(policy)
	// v1.223.0 verdict-truth: systemd-payload assertion inputs from real host
	// (nil) or the DATA test-injection carrier (nil-safe).
	opts.SystemdPayloadInputs = cfg.inject.payload()
	// v1.223.0 verdict-truth (BUG-REVALIDATE-MASKS-HEALTH-DEGRADE): revalidate never
	// runs phaseConfigure, so without this it left opts.HealthResource nil → the
	// health_resource_policy_active assertion SKIPped and a genuinely OOM-unprotected
	// medium/large host was silently recommitted to COMMITTED. Resolve the LIVE
	// verdict read-only (no zero verdict) so a real FALLBACK_UNDERSIZED keeps the
	// host DEGRADED and an ACTIVE_MATCH truthfully recommits. The optional injected
	// profile forces a deterministic tier for execution-path tests (nil → /proc).
	resolvedHealth := services.ResolveHealthResourceVerdict(exec, sf, log, healthresource.Verdict{}, version.Version, cfg.inject.profile())
	opts.HealthResource = &resolvedHealth
	results := validate.RunAssertionsWithOpts(exec, sshPort, log, opts)

	// Preserve recorded identity the Transition writer re-emits. main() blanked
	// sf.Mode to the (empty) --mode for a revalidate run; restore it so the
	// rewritten record stays faithful. sf already carries the file's
	// Authority/Panel/SchemaVersion/SSHPort from main()'s earlier Read().
	if sf.Mode == "" {
		sf.Mode = cur.Mode
	}
	if sf.SSHPort == 0 {
		sf.SSHPort = cur.SSHPort
	}

	if validate.AllPassed(results) {
		log.Info("revalidate: all live post-install assertions passed — recommitting install_state COMMITTED")
		_ = exec.Remove(fhs.InstallFailedMarker)
		if err := sf.Transition(state.StateCommitted, state.PhaseValidate, ""); err != nil {
			log.Error("revalidate: failed to persist COMMITTED state: %v", err)
			return state.ExitFatal
		}
		return state.ExitCommitted
	}

	failed := validate.FailedNames(results)
	reason := "revalidate: live post-install assertions still failing: " + strings.Join(failed, ", ")
	log.Warn("revalidate: %d assertion(s) still failing (%s) — leaving install_state DEGRADED (no masking)", len(failed), strings.Join(failed, ", "))
	if err := sf.Transition(state.StateDegraded, state.PhaseValidate, reason); err != nil {
		log.Error("revalidate: failed to persist DEGRADED state: %v", err)
		return state.ExitFatal
	}
	return state.ExitDegraded
}
