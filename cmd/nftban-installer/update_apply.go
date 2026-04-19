// =============================================================================
// NFTBan v1.99 PR-18 — Update Apply Orchestrator (G3-U5..U10)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-update-apply"
// meta:type="cmd"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Update apply orchestration — thin sequencer over rebuild + validator"
// meta:inventory.files="cmd/nftban-installer/update_apply.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// Pinned contract (apply_contract.md + PR #475 body):
//
//   PR-18 is orchestration-only: update apply may invoke the existing
//   rebuild/lifecycle authority, but may not implement any independent
//   apply, mutation, recovery, validation, or authority-taking behavior.
//
// runUpdateApply is a THIN SEQUENCER, not a policy engine.
//
//   1. Re-run preflight (read-only, PR-16/PR-17)
//   2. Invoke the canonical rebuild entrypoint: `nftban firewall rebuild`
//   3. Invoke the validator gate: `nftban-validate --json`
//   4. Inspect post-state read-only (informational only)
//   5. Return rebuild/validator outcome DIRECTLY — no reinterpretation
//
// No custom retry. No custom rollback. No custom recovery. No config
// mutation. No authority decisions beyond what rebuild already owns.
// No success coercion or error downgrading.
//
// Critical semantic: if rebuild passes but validator fails, update apply
// MUST fail. Validator is the truth gate, not advisory output.
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

// Canonical entry points PR-18 orchestrates. String constants so the
// contract audit (apply_contract_test.go::applyWhitelist) and the
// runtime path agree by inspection.
const (
	// Rebuild entrypoint. Invokes cli/lib/nftban/cli/cmd_firewall.sh ::
	// firewall_rebuild via the nftban CLI. This is the ONLY mutation
	// path — PR-18 adds no other.
	rebuildCmd  = "nftban"
	rebuildArg1 = "firewall"
	rebuildArg2 = "rebuild"

	// Validator gate. Read-only; governs apply's exit contract per
	// G3-U8 ("validator result GOVERNS lifecycle outcome").
	validatorCmd  = "nftban-validate"
	validatorArg1 = "--json"
)

// runUpdateApply is the update-mode apply orchestrator. Invoked when
// cfg.mode == "upgrade" and dry-run is NOT set.
//
// Sequence (each phase short-circuits on failure; later phases only run
// when earlier ones pass):
//
//	1. update.Preflight            (read-only)
//	2. nftban firewall rebuild     (canonical mutation path)
//	3. nftban-validate --json      (truth gate)
//	4. postStateInspection         (read-only, success-path only)
//
// Post-state inspection runs only on the success path because the earlier
// failure branches already returned with a precise failure state; emitting
// "post-state" evidence in a failure context would dilute the failure
// signal and is not required by G3-U9 (which judges convergence on
// successful apply).
//
// Exit-code contract (explicit, no merging):
//
//	state.ExitCommitted (0) — preflight + rebuild + validator all passed
//	state.ExitDegraded  (1) — preflight failed before apply could start
//	rebuild's own RC    (*) — rebuild failed; its recovery already ran
//	                          and propagated through its own exit code
//	validator's own RC  (*) — rebuild succeeded but validator rejected
//	                          the post-state (validator is truth gate)
//
// If rebuild passes but validator fails, runUpdateApply returns the
// validator's non-zero code. No coercion. No masking. The two phase
// failures are ALWAYS distinguishable by exit code + log phase marker.
func runUpdateApply(_ context.Context, exec executor.Executor, sf *state.StateFile, cfg *config, log *logging.Logger) int {
	log.Info("update apply starting (mode=upgrade, dry-run=false)")

	// 1. Preflight — read-only, identical to dry-run surface.
	origin := detectInstallOrigin(cfg)
	if origin == "" {
		origin = update.DetectInstallOrigin(exec, log)
	}

	log.Phase("Preflight")
	pre := update.Preflight(exec, log, origin)
	log.PhaseEnd("Preflight")

	if !pre.Passed {
		log.Error("update apply: preflight FAILED — apply blocked before rebuild invocation")
		for _, c := range pre.Checks {
			if !c.Passed && c.Severity == "critical" {
				log.Error("  preflight %s: %s", c.Name, c.Detail)
			}
		}
		fmt.Fprintln(os.Stderr, "update apply: preflight failed — see log for details")
		// PR-19 G3-U11: state↔exit agreement. Persist the state derived
		// from preflight severity and return the SAME state's ExitCode().
		// Previously this branch transitioned to StateFailedAbort (which
		// maps to ExitAborted=3) but returned hard-coded ExitDegraded=1
		// — a silent truth split of the same class PR-18 fixed for the
		// validator-fail branch.
		st := stateForPreflightFailure(pre)
		_ = sf.Transition(st, state.PhasePrepare,
			"update preflight failed before rebuild")
		return st.ExitCode()
	}

	// 2. Canonical rebuild entrypoint — the ONLY mutation path.
	// Recovery, rollback, authority enforcement, config rendering: all
	// owned by firewall_rebuild (v1.96 pipeline). PR-18 owns NONE of them.
	log.Phase("Rebuild")
	rebuildRes := exec.Run(rebuildCmd, rebuildArg1, rebuildArg2)
	log.PhaseEnd("Rebuild")

	if rebuildRes.ExitCode != 0 {
		// Rebuild failed. Its own recovery/rollback path already ran
		// (nftban_rebuild_recovery.sh). We propagate the exit code WITHOUT
		// reinterpretation — no retry, no "helpful" fallback, no error
		// downgrading. The installer state machine transitions to a
		// rebuild-failure state so the outer audit trail is honest.
		log.Error("update apply: rebuild FAILED (exit=%d) — rebuild recovery already ran", rebuildRes.ExitCode)
		if rebuildRes.Stderr != "" {
			log.Error("  rebuild stderr: %s", truncate(rebuildRes.Stderr, 500))
		}
		_ = sf.Transition(state.StateFailedRebuild, state.PhaseSwitch,
			"rebuild failed during update apply")
		fmt.Fprintf(os.Stderr, "update apply: rebuild failed (exit %d)\n", rebuildRes.ExitCode)
		return rebuildRes.ExitCode
	}

	// 3. Validator gate — truth gate per G3-U8.
	// A rebuild that succeeds but produces a kernel state the validator
	// rejects is a FAILED apply. No success coercion — validator wins.
	log.Phase("Validate")
	valRes := exec.Run(validatorCmd, validatorArg1)
	log.PhaseEnd("Validate")

	if valRes.ExitCode != 0 {
		// Rebuild SUCCEEDED but validator rejected the post-state. This
		// is NOT a warning — per user directive, validator is the truth
		// gate. Apply must fail cleanly so monitoring can distinguish
		// "rebuild worked and post-state is sane" from "rebuild worked
		// but kernel ended up in a bad state".
		//
		// Blocker #1 fix (code review): persisted lifecycle state is
		// derived from validator's exit code, not hard-coded. This
		// keeps State.ExitCode() and the returned process exit aligned
		// and preserves the truth-gate discipline: a stronger validator
		// failure is NOT collapsed into a weaker persisted state.
		log.Error("update apply: validator REJECTED post-update state (exit=%d) — apply failed despite rebuild success", valRes.ExitCode)
		if valRes.Stderr != "" {
			log.Error("  validator stderr: %s", truncate(valRes.Stderr, 500))
		}
		_ = sf.Transition(stateForValidatorExit(valRes.ExitCode), state.PhaseValidate,
			"post-update validator rejected state")
		fmt.Fprintf(os.Stderr, "update apply: validator rejected post-update state (exit %d)\n", valRes.ExitCode)
		return valRes.ExitCode
	}

	// 4. Read-only post-state inspection. Informational only — these
	// lines emit what kernel and service state look like so operators
	// have evidence without pulling logs. NO mutation, NO retry, NO fix.
	postStateInspection(exec, log)

	// Success — preflight passed, rebuild passed, validator passed.
	log.Info("update apply complete — preflight + rebuild + validator all passed")
	_ = sf.Transition(state.StateCommitted, state.PhaseValidate, "update apply committed")
	return state.ExitCommitted
}

// postStateInspection emits read-only evidence lines. Every call here MUST
// be in the apply_contract.md whitelist. No side effects.
func postStateInspection(exec executor.Executor, log *logging.Logger) {
	// Kernel authority — ip nftban table present?
	if exec.NftTableExists("ip", "nftban") {
		log.Info("post-state: kernel ip nftban table present")
	} else {
		log.Warn("post-state: kernel ip nftban table ABSENT (unexpected — validator passed)")
	}

	// Service convergence — nftband active?
	if exec.ServiceActive("nftband.service") {
		log.Info("post-state: nftband.service active")
	} else {
		log.Info("post-state: nftband.service NOT active (may be expected on this host)")
	}
}

// stateForPreflightFailure maps a failing preflight result to the
// InstallState this apply run should persist. Keeps state↔exit aligned
// by construction — the returned state's ExitCode() equals the process
// exit runUpdateApply returns on this branch.
//
// Today: any critical preflight failure maps to StateFailedNoFirewall
// (ExitCode == ExitFailed == 2). This is honest: preflight exists to
// gate apply on "nftban is functionally present and authoritative" —
// a critical preflight failure means at least one of those conditions
// is not met. PR-19 intentionally avoids building a mini policy engine
// that varies the state per check; the signature accepts the full
// preflight result so a future PR can deepen mapping without changing
// callers.
func stateForPreflightFailure(_ *update.PreflightResult) state.InstallState {
	return state.StateFailedNoFirewall
}

// stateForValidatorExit maps the validator binary's process exit code to
// the InstallState this apply run should persist. Local and narrow by
// design (PR-18 review blocker #1):
//
//	rc == 0       — validator passed; caller uses StateCommitted directly
//	rc == 1       — DEGRADED (post-state valid enough to classify as degraded)
//	rc >= 2       — FAILED_REBUILD (apply produced a post-update state
//	                that cannot be accepted as protected and cannot be
//	                trusted as merely degraded)
//
// Depends only on the validator PROCESS EXIT CODE. Does NOT parse the
// validator's JSON body — that would be the exact success-coercion
// regression the truth-gate discipline forbids.
//
// This helper intentionally does not introduce a new InstallState enum
// value. Any future expansion of the state taxonomy is out of PR-18 scope.
func stateForValidatorExit(rc int) state.InstallState {
	if rc == 1 {
		return state.StateDegraded
	}
	return state.StateFailedRebuild
}

// truncate returns s clipped to n runes with an ellipsis appended. Used
// for bounded stderr snippets in error logs — must not be verbose enough
// to dump validator secrets or environment. Operates on runes (not bytes)
// so multi-byte UTF-8 characters don't get cut in half.
func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}
