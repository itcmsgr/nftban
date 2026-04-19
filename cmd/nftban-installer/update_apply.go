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
	"time"

	"github.com/itcmsgr/nftban/internal/constants"
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
	//
	// Absolute path via constants.ValidatorBinPath — /usr/lib/nftban/bin
	// is NOT in default $PATH on Ubuntu or AlmaLinux, so a bare name
	// ("nftban-validate") fails to resolve. Found by the post-PR-20
	// parity gate FC-1 on 2026-04-19. constants.ValidatorBinPath is the
	// single authority for this path (four pre-existing consumers in
	// internal/metrics + internal/smoke); this PR aligns the two
	// previously bare-name Go call sites (here + cmd_lifecycle.go) with
	// that single authority rather than introducing a second one.
	validatorArg1 = "--json"
)

var (
	// validatorCmd is a var, not const, because it references the
	// constants package. Kept parallel to rebuildCmd (still a const
	// string because nftban IS on $PATH at /usr/sbin/nftban).
	validatorCmd = constants.ValidatorBinPath
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
func runUpdateApply(_ context.Context, exec executor.Executor, sf *state.StateFile, cfg *config, log *logging.Logger) (rc int) {
	// PR-20 G3-U15/U17: track run metadata for the end-of-run trailer.
	meta := newRunMeta("upgrade")
	defer meta.emitTrailer(log, &rc, sf)

	log.Info("update apply starting (mode=upgrade, dry-run=false)")

	// 1. Preflight — read-only, identical to dry-run surface.
	origin := detectInstallOrigin(cfg)
	if origin == "" {
		origin = update.DetectInstallOrigin(exec, log)
	}

	// PR-20 G3-U15: emit the intended transition BEFORE any mutation so
	// operators see from→to in the log even if a later phase fails.
	// DetectVersions uses only whitelisted probes (VERSION file + rpm/dpkg
	// query) — no new contract surface.
	current, target, _ := update.DetectVersions(exec, cfg.sourceDir, origin, log)
	meta.from = current
	meta.to = target
	log.Info("update apply: %s → %s (origin=%s)",
		displayVer(current), displayVer(target), displayOrigin(origin))

	// PR-20 G3-U16: observability-only idempotency marker. Apply still
	// invokes rebuild in the no-op case — rebuild owns the authoritative
	// "is this a no-op" decision (v1.96 atomic switch produces identical
	// kernel state for identical input).
	if current != "" && target != "" && current == target {
		log.Info("update apply: already up-to-date (current == target == %s) — rebuild will no-op", current)
	}

	meta.beginPhase("Preflight")
	log.Phase("Preflight")
	pre := update.Preflight(exec, log, origin)
	log.PhaseEnd("Preflight")
	meta.endPhase(log, "Preflight", pre.Passed)

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
	meta.beginPhase("Rebuild")
	log.Phase("Rebuild")
	rebuildRes := exec.Run(rebuildCmd, rebuildArg1, rebuildArg2)
	log.PhaseEnd("Rebuild")
	meta.endPhase(log, "Rebuild", rebuildRes.ExitCode == 0)

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
	meta.beginPhase("Validate")
	log.Phase("Validate")
	valRes := exec.Run(validatorCmd, validatorArg1)
	log.PhaseEnd("Validate")
	meta.endPhase(log, "Validate", valRes.ExitCode == 0)

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

// runMeta carries observability state for a single runUpdateApply call.
// Populated as phases progress; emitted as a one-line trailer at function
// return via defer. Pure observability — never inspected to make control
// decisions (PR-20 contract).
type runMeta struct {
	mode          string
	from          string
	to            string
	start         time.Time
	currentPhase  string
	phaseStart    time.Time
	phasesPassed  int
	phasesFailed  int
}

func newRunMeta(mode string) *runMeta {
	return &runMeta{mode: mode, start: time.Now()}
}

func (m *runMeta) beginPhase(name string) {
	m.currentPhase = name
	m.phaseStart = time.Now()
}

func (m *runMeta) endPhase(log *logging.Logger, name string, passed bool) {
	d := time.Since(m.phaseStart)
	log.Info("  phase %s duration_ms=%d result=%s",
		name, d.Milliseconds(), passedStr(passed))
	if passed {
		m.phasesPassed++
	} else {
		m.phasesFailed++
	}
	m.currentPhase = ""
}

// emitTrailer writes a single machine-parseable key=value summary line
// at function return. Safe to call regardless of early exit — every
// field has a defined zero value.
func (m *runMeta) emitTrailer(log *logging.Logger, rc *int, sf *state.StateFile) {
	d := time.Since(m.start)
	finalState := "UNSET"
	if sf != nil {
		finalState = string(sf.State)
	}
	exitCode := 0
	if rc != nil {
		exitCode = *rc
	}
	log.Info("update apply trailer: mode=%s from=%s to=%s phases_passed=%d phases_failed=%d duration_ms=%d exit=%d final_state=%s",
		m.mode,
		displayVer(m.from),
		displayVer(m.to),
		m.phasesPassed,
		m.phasesFailed,
		d.Milliseconds(),
		exitCode,
		finalState,
	)
}

// displayVer returns a placeholder for empty version strings so log lines
// never contain blank fields.
func displayVer(v string) string {
	if v == "" {
		return "unknown"
	}
	return v
}

// displayOrigin returns a placeholder for empty origin strings.
func displayOrigin(o string) string {
	if o == "" {
		return "unknown"
	}
	return o
}

func passedStr(p bool) string {
	if p {
		return "pass"
	}
	return "fail"
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
