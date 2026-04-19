# PR-19 — Update Validation Phase Contract (G3-U11 / U12 / U13)

**Status:** Draft
**Scope:** G3-U11 exit-code truth, G3-U12 update history integrity, G3-U13 source/package path coherence
**Base:** PR-18 merged at `22f8fb41`

---

## Pinned sentence

> PR-19 is truth-enforcement only: it may refine validation outcome mapping,
> update metadata correctness, and history coherence, but may not introduce
> any new state-mutation, recovery, or authority-taking behavior.

---

## Scope

### G3-U11 — Exit-code truth (continuation of PR-18 blocker #1)

PR-18 fixed the **validator-fail** state↔exit split via
`stateForValidatorExit(rc)`. PR-19 extends the same discipline to every
state-transitioning branch in `runUpdateApply`:

- **Preflight-fail** currently transitions to `state.StateFailedAbort`
  (which maps to `ExitAborted = 3`) but returns hard-coded
  `state.ExitDegraded` (= 1). Same truth split the reviewer flagged
  in PR-18, on a different branch.

- **Rebuild-fail** transitions to `state.StateFailedRebuild` (= exit 2)
  and returns `rebuildRes.ExitCode` (the rebuild's own RC). This is
  already aligned when rebuild exits with `≥ 2`, but rebuild exit 1
  would persist as `StateFailedRebuild` (= exit 2). Needs the same
  severity-map discipline.

PR-19 locks every state transition with a regression test that asserts
`sf.State.ExitCode() == <returned process exit>`.

### G3-U12 — Update history integrity

The existing `writeHistory` in `main.go:335` writes a history entry
after every installer run. Issues this PR addresses:

1. **Run without reaching a terminal state** — a timeout / signal mid-apply
   leaves `sf.State` on an intermediate state (e.g. `DETECT_COMPLETE`).
   The writer's default case reports `status = install_fail`, but
   `from/to` fields are written regardless. For an operator auditing
   history this is misleading (the install might not have actually failed).
2. **`installType` always defaults to "rpm"** — source installs get
   labeled `"rpm"` in the history JSON, which is factually wrong and
   will obscure later postmortems. Already classified under G3-U13 below.
3. **`from` is the installer binary's *prior* self-version, not the
   operator-intended current version** — for a source install where
   the operator explicitly provides a `--source-dir`, the history
   should reflect that, not the in-memory version constant.

PR-19 refines `writeHistory` to:
- emit `status = install_fail` (not `success`) whenever `sf.State !=
  StateCommitted` — no coercion
- record an accurate `installType` with a `source` case
- capture the operator-intended `from`/`to` from the update plan when
  available

### G3-U13 — Source/package path coherence

Builds on PR-17's preflight check `install_origin_coherent` (declared vs
detected origin). PR-19 extends coherence enforcement to the metadata
surface:

- `writeHistory` must never label a `source` install as `rpm`/`deb`
- if declared origin disagrees with detected origin, the history entry
  records the declared origin but adds an `origin_mismatch` warning in
  the coherence field (new optional field)
- no mixed-mode success reporting: if preflight P-7
  (`install_origin_coherent`) failed, status must not be `success`

---

## Explicit non-goals (strict)

- ❌ No new mutation path
- ❌ No new recovery / rollback behavior
- ❌ No new authority-taking logic
- ❌ No change to `runUpdateApply`'s call graph (preflight → rebuild →
  validator remains)
- ❌ No new `InstallState` enum value
- ❌ No reinterpretation of validator JSON body
- ❌ No new service convergence logic
- ❌ No change to `ApplyWhitelist` (unless new read-only command is
  legitimately required for validation and is justified inline)

If any of these emerges as "needed" → STOP and split into a separate PR.

---

## Mandatory merge evidence

- [ ] Every state-transitioning branch in `runUpdateApply` has a test
      asserting `sf.State.ExitCode() == <returned rc>`
- [ ] Preflight-fail branch now returns an exit code that matches its
      persisted state (no more 1-vs-3 split)
- [ ] `writeHistory` emits `install_fail` on any non-terminal / non-committed
      state
- [ ] Source installs record `installType = "source"` in the history
      JSON
- [ ] Origin-mismatch detected by P-7 is reflected in the history entry
- [ ] New CI gate steps G3-U11 / G3-U12 / G3-U13 in
      `ci-update-canonization.yml`

---

## Post-merge watch item carried forward from PR-18

> In PR-19 and later, keep the same discipline around validator severity
> and persisted lifecycle state. Do not reintroduce any state↔exit split
> through a new validation-focused path.

PR-19's primary job is to eliminate the *existing* remaining splits and
put a test in the way so they cannot silently re-emerge.
