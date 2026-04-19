# PR-20 — Update Logging Contract (G3-U15 / U16 / U17)

**Status:** Draft
**Scope:** G3-U15 runtime-state preserved, G3-U16 reinstall/update idempotency visibility, G3-U17 log/evidence adequacy
**Base:** PR-19 merged at `9f882508`

---

## Pinned sentence

> PR-20 is observability only: it may refine logging detail, phase markers,
> and idempotency visibility, but may not introduce any new
> state-mutation, recovery, authority, or validation behavior.

---

## Scope

### G3-U15 — Runtime state preserved in evidence

Currently `runUpdateApply` logs phase markers + a one-line summary at the
end. PR-20 adds:

- **From → to version line** at the start of apply, so the operator sees
  the intended transition BEFORE mutation begins. Lines up with the
  plan output from `--dry-run` (PR-16).
- **Post-mortem summary trailer** at the end: one line with `mode`,
  `from`, `to`, `phases_passed`, `phases_failed`, `duration_ms`, `final_state`.
  Machine-parseable — single line, `key=value` pairs.

### G3-U16 — Idempotency visibility

When `current_version == target_version`, apply must log a clear
"already up-to-date" marker so operator reruns are visible as no-ops.

**Behaviour is NOT changed** — rebuild is already idempotent (v1.96
safe-switch atomically validates → flushes+loads; identical input =
identical output). PR-20 only surfaces the observation.

The apply path still invokes rebuild in the idempotent case (no
short-circuit), so rebuild itself remains the single authority for
"is this a no-op." Apply just reports what's visible from plan.

### G3-U17 — Log/evidence adequacy

Existing phase boundaries are sufficient but lack timing. PR-20 adds:

- Wall-clock duration per phase at `PhaseEnd` (Preflight / Rebuild /
  Validate).
- The trailer above gives an end-to-end duration.

---

## Explicit non-goals (strict)

- ❌ No new `exec.Run` calls (observability must not introduce new
  commands). Any log line that requires reading host state uses the
  existing read-only probes already whitelisted in PR-18's contract.
- ❌ No new mutation path
- ❌ No new recovery / rollback behavior
- ❌ No new authority-taking logic
- ❌ No idempotency short-circuit (rebuild stays the single authority
  for "is this a no-op"; apply only observes)
- ❌ No new validation logic — timing is measurement, not judgement
- ❌ No change to exit-code contract or state-transition rules
- ❌ No change to `ApplyWhitelist`

If any of these emerges as "needed" → STOP and split into a separate PR.

---

## Mandatory merge evidence

- [ ] `runUpdateApply` emits a single "update apply: from vX.Y.Z → vA.B.C"
      log line after preflight + version detection
- [ ] When `current == target`, log contains a distinct "already
      up-to-date" marker
- [ ] Each phase's `PhaseEnd` log line includes a duration marker
- [ ] End-of-run trailer contains `mode`, `from`, `to`, `phases_passed`,
      `phases_failed`, `duration_ms`, `final_state` as key=value pairs
- [ ] Call-path purity tests still pass — no new commands in
      `AuditRecordedCommands` trace
- [ ] Structural CI check: no new `exec.Run` in `update_apply.go` diff

---

## Post-merge gate (blocks PR-21 — not this PR)

After PR-20 merges and before PR-21 opens, a parity-checkpoint review
must happen to confirm the shell update path can be deleted safely.
That gate is G3-U-REBUILD-PARITY per the v1.99 plan. PR-20 does not
ship that proof — it only lays the observability that makes the proof
readable.
