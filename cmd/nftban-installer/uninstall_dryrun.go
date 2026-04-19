// =============================================================================
// NFTBan v1.100 PR-22 — Uninstall Dry-Run Orchestrator (Detect + Plan Only)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-uninstall-dryrun"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="--mode=uninstall --dry-run: authority classify + prior probe + plan"
// meta:inventory.files="cmd/nftban-installer/uninstall_dryrun.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// Pinned PR-22 scope lock:
//
//   "PR-22 is detect + dry-run plan only. It must not flush any chain,
//    remove any table, disable any service, delete any file, touch any
//    .conf.local, or re-enable any external firewall."
//
// This orchestrator mirrors runUpdateDryRun's shape intentionally: it
// proves the scope-boundary invariant by construction — it has no
// mutation code paths and no branches that could be expanded into
// mutation without a visible diff.
//
// Authorization: V1100_LIFECYCLE_COMPLETION_CONTRACT.md §13 frozen
// 2026-04-19.
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
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// PR-22A boundary repair (audit finding A):
//
//   The original PR-22 orchestrator persisted two artifacts under
//   /var/lib/nftban/ during a dry-run that the CLI banner described as
//   "no mutation":
//
//     1. os.WriteFile(<stateDir>/uninstall_plan.json, …)
//     2. sf.Transition(StateUninstallPlanning, …) — writes install_state
//
//   Both tripped the PR-22 contract Stop Condition: "writing to anywhere
//   under /etc/nftban/ or /var/lib/nftban/ → STOP PR-22."
//
//   PR-22A removes both. The plan is rendered to stdout (human) and,
//   optionally, JSON to stderr below the render (machine). No filesystem
//   persistence occurs during the dry-run. Operators who need a
//   machine-consumable plan can capture stdout; the dry-run remains
//   strictly observational, as PR-22 originally promised.
//
//   Install-state persistence during dry-run is deliberately removed
//   (Option B in the repair contract). A read-only planning run has no
//   reason to mutate the installer state file.

// runUninstallDryRun orchestrates the PR-22 detect + plan-render flow.
//
// Exit codes:
//
//	0 — plan computed and rendered; no mutation; operator has a contract
//	    preview to review
//	1 — plan could not be computed due to detection failure (never due
//	    to authority state — "AuthorityNone" is a valid plan)
//	3 — illegal flag combination (e.g. --mode=uninstall without the
//	    installer being built for v1.100+)
//
// No other exit code paths exist in PR-22 because no mutation code
// exists in PR-22.
func runUninstallDryRun(_ context.Context, exec executor.Executor, sf *state.StateFile, cfg *config, log *logging.Logger) int {
	log.Info("uninstall dry-run starting (mode=uninstall, dry-run=true)")

	// 1. Authority classification — 4-state read-only.
	log.Phase("Detect")
	auth := uninstall.Classify(exec, log)
	log.Info("uninstall: current authority = %s", auth.State)
	for _, note := range auth.Notes {
		log.Debug("uninstall/authority: %s", note)
	}

	// 2. Prior-authority record probe — 3-state read-only.
	prior := uninstall.Probe(exec, log)
	log.Info("uninstall: prior-authority record state = %s", prior.State)
	for _, note := range prior.Notes {
		log.Debug("uninstall/prior: %s", note)
	}
	log.PhaseEnd("Detect")

	// 3. Mode selection from flags — ordered by precedence.
	mode := modeFromFlags(cfg)
	restoreRequested := cfg.restorePriorAuthority

	// 4. Build the release plan (pure function).
	log.Phase("Plan")
	plan := uninstall.BuildPlan(mode, auth, prior, restoreRequested)
	log.PhaseEnd("Plan")

	// 5. Render to stdout (operator-visible). No filesystem persistence —
	// the dry-run is strictly observational per PR-22 contract Stop
	// Condition. Machine consumers can capture stdout; see also Note A
	// above for the PR-22A audit rationale.
	plan.Render(os.Stdout)

	// 6. Emit the literal scope-boundary log marker per PR-22 contract.
	// The state file is NOT transitioned here: a read-only plan computes
	// no state change, and persisting StateUninstallPlanning during a
	// dry-run would trip the same Stop Condition the orchestrator
	// exists to respect. sf is retained in the signature for symmetry
	// with install/update orchestrators and for PR-23 takeover.
	_ = sf
	log.Info("uninstall dry-run complete — PR-22 scope boundary: NO mutation phase exists in this release")
	fmt.Fprintln(os.Stderr, "uninstall dry-run: plan rendered; no mutation (PR-22 scope)")
	return state.ExitCommitted
}

// modeFromFlags maps the operator's --purge / --force-delete-operator-config
// flags to the three §4.4 modes. Priority:
//
//	--purge --force-delete-operator-config → ModePurgeForceDOC
//	--purge                                 → ModePurge
//	(default)                               → ModeRemove
//
// Flags that have no effect on mode (e.g. --restore-prior-authority)
// are handled separately by BuildPlan.
func modeFromFlags(cfg *config) uninstall.Mode {
	switch {
	case cfg.purge && cfg.forceDeleteOperatorConfig:
		return uninstall.ModePurgeForceDOC
	case cfg.purge:
		return uninstall.ModePurge
	default:
		return uninstall.ModeRemove
	}
}
