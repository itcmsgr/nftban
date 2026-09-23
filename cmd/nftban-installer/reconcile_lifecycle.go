// =============================================================================
// NFTBan v1.233.x Lane B — OPERATOR SURFACE FOR LIFECYCLE RECONCILIATION
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-reconcile-lifecycle-cmd"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-23"
// meta:description="--reconcile-lifecycle: derive a REBUILD_REFUSED_BUSY host's lifecycle record from proven live reality without mutating that reality. Reports every assertion, and on refusal names the assertion that refused."
// meta:inventory.files="cmd/nftban-installer/reconcile_lifecycle.go"
// meta:inventory.binaries="nftban-installer"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/var/lib/nftban/state/install_state,/var/lib/nftban/state/lifecycle-reconcile.jsonl"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package main

import (
	"context"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/reconcile"
	"github.com/itcmsgr/nftban/internal/installer/state"
)

// runReconcileLifecycle is the operator entry point for RECONCILE.
//
// ⛔ WHY IT IS NOT AN EXTENSION OF --revalidate. runRevalidate acts on exactly one
// state (DEGRADED) and recomputes a HEALTH verdict; it holds no convergence authority,
// reads no generation, and derives no structure identity. Teaching it a second state
// with three new obligations would change DEGRADED recovery behaviour fleet-wide under
// cover of a different fix — the pattern the transaction-truth invariant in
// state/file.go explicitly refuses. RECONCILE is ONE guarded transition, kept separate
// and kept narrow.
func runReconcileLifecycle(ctx context.Context, exec executor.Executor, cfg *config, log *logging.Logger) int {
	if err := ctx.Err(); err != nil {
		log.Error("reconcile-lifecycle: context cancelled before start: %v", err)
		return state.ExitFatal
	}

	mode := "RECONCILE"
	if cfg.dryRun {
		mode = "RECONCILE (dry run — proves everything, persists nothing)"
	}
	log.Info("reconcile-lifecycle: %s", mode)
	log.Info("reconcile-lifecycle: this path NEVER rebuilds, reinstalls, reloads or writes to the kernel — " +
		"it derives the record from live reality, and refuses if live reality does not support it")

	out, err := reconcile.Run(reconcile.Inputs{
		Exec:     exec,
		StateDir: cfg.stateDir,
		RunID:    log.RunID(),
		DryRun:   cfg.dryRun,
	})
	if err != nil {
		log.Error("reconcile-lifecycle: could not be carried out: %v", err)
		return state.ExitFatal
	}

	for _, a := range out.Event.Assertions {
		if a.Passed {
			log.Info("  PASS  %-28s %s", a.Name, a.Detail)
			continue
		}
		log.Error("  REFUSE %-27s %s", a.Name, a.Refusal)
	}

	switch {
	case out.Reconciled:
		log.Info("reconcile-lifecycle: %s -> COMMITTED (CONVERGENCE_VERIFIED=VERIFIED)",
			out.Event.PreviousState)
		log.Info("reconcile-lifecycle: structure %s %s", out.Event.StructureSchema, out.Event.StructureFingerprint)
		log.Info("reconcile-lifecycle: runtime_mutated=false — the firewall was not touched")
		log.Info("reconcile-lifecycle: the original failure is preserved in %s", reconcile.ForensicRecordPath)
		return state.ExitCommitted

	case cfg.dryRun && out.Refusal == "":
		log.Info("reconcile-lifecycle: every assertion PASSED — a real run would reconcile this host")
		log.Info("reconcile-lifecycle: nothing was written. Re-run without --dry-run to persist")
		return state.ExitCommitted

	default:
		log.Error("reconcile-lifecycle: REFUSED — %s", out.Refusal)
		log.Info("reconcile-lifecycle: the lifecycle record was NOT changed and the firewall was NOT touched")
		return state.ExitRefused
	}
}
