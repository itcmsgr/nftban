// =============================================================================
// NFTBan v1.99 PR-16 — Update Dry-Run Orchestrator
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-update-dryrun"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="--mode=upgrade --dry-run: preflight + plan, no mutation"
// meta:inventory.files="cmd/nftban-installer/update_dryrun.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// PR-16 closes G3-U1 (lifecycle entry), G3-U2 (current→target versions),
// G3-U3 (--dry-run correctness), G3-U4 (preflight enforcement).
//
// This entry point is intentionally narrow. It does NOT run phasePrepare /
// phaseSwitch / phaseConfigure / phaseValidate — those remain the property
// of install mode in PR-16. Update apply (PR-18) will wire update mode
// back into the same phase pipeline (INV-U-001: update = rebuild with
// controlled input delta, not a separate engine).
//
// =============================================================================

package main

import (
	"context"
	"fmt"
	"os"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/update"
)

// runUpdateDryRun runs the update-trigger dry-run path:
//
//  1. phaseDetect (reused from install — same detection surface)
//  2. update.Preflight (P-1..P-5)
//  3. update.DetectVersions
//  4. update.BuildPlan + render
//
// No mutation; no phasePrepare / phaseSwitch / phaseConfigure / phaseValidate.
//
// Exit code contract:
//
//	0 — preflight passed, plan rendered cleanly
//	1 — preflight failed (critical check), plan rendered with failures
//	2 — phaseDetect failed (cannot even reason about the host)
//	4 — fatal (I/O error, etc.)
func runUpdateDryRun(ctx context.Context, exec executor.Executor, sf *state.StateFile, cfg *config, log *logging.Logger) int {
	log.Info("update dry-run starting (mode=upgrade, dry-run=true)")

	// 1. Reuse phaseDetect so the update trigger sees the same detection
	// surface that a real install/upgrade would. This is the first step
	// in routing update through the shared pipeline.
	log.Phase("Detect")
	if err := phaseDetect(ctx, exec, sf, log); err != nil {
		log.Error("update dry-run: phaseDetect failed: %v", err)
		log.PhaseEnd("Detect")
		return state.ExitFailed
	}
	log.PhaseEnd("Detect")

	// 2. Update-specific preflight (P-1 through P-5).
	log.Phase("Preflight")
	pre := update.Preflight(exec, log)
	log.PhaseEnd("Preflight")

	// 3. Version detection. sourceDir is empty in the package-install case;
	// the update package treats that as non-fatal for PR-16 (package-install
	// target detection lands in PR-17).
	current, target, err := update.DetectVersions(exec, cfg.sourceDir, log)
	if err != nil {
		log.Error("update dry-run: version detection failed: %v", err)
		return state.ExitFailed
	}

	// 4. Install origin — drives which apply path PR-18 will use.
	origin := detectInstallOrigin(cfg)

	// 5. Assemble + render plan.
	plan := update.BuildPlan(pre, current, target, origin)
	plan.Render(os.Stdout)

	// 6. Write a copy of the plan JSON to the state dir for audit/history
	// traceability. Not a hard requirement for PR-16 but closes G3-U12
	// (update history integrity) early.
	dst := cfg.stateDir + "/update_plan.json"
	if werr := plan.WriteJSONToFile(dst); werr != nil {
		log.Warn("update dry-run: could not persist plan to %s: %v", dst, werr)
	} else {
		log.Info("update dry-run: plan written to %s", dst)
	}

	// 7. Exit contract.
	if !pre.Passed {
		fmt.Fprintln(os.Stderr, "update dry-run: preflight FAILED — apply would abort (see plan)")
		return state.ExitDegraded
	}
	log.Info("update dry-run complete — no mutation, plan valid")
	return state.ExitCommitted
}

// detectInstallOrigin produces the install origin label for the plan.
// PR-16 reads it from the cfg flags the operator passed; heuristic detection
// against package databases is a PR-17 enhancement.
func detectInstallOrigin(cfg *config) string {
	switch {
	case cfg.source:
		return "source"
	case cfg.rpm:
		return "rpm"
	case cfg.deb:
		return "deb"
	default:
		// PR-17 will detect origin by inspecting rpm -q / dpkg -s when no
		// flag is provided. For now, report it as unknown so operators can
		// see the detection gap.
		return ""
	}
}
