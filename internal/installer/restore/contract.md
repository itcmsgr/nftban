# PR-24 — Authority Restoration Policy Engine Contract (Seed v1)

**Status:** Seed (approved 2026-04-20, pre-implementation)
**Authorization basis:** lattice v2 + locked amendments (NoRecord + --restore, legacy ActiveAtInstall, 365-day staleness fixed)
**Scope:** Authority restoration **policy engine** — decision only. No execution.

---

## Pinned sentence

> PR-24 decides whether restoration is allowed — not how to do it. It
> is a pure decision engine over four input axes producing exactly one
> of three outputs: PROCEED, REFUSE, REQUIRE_EXPLICIT_INTENT. It spawns
> no external process, mutates no kernel, service, or filesystem state,
> and writes no history entry. Refusal is a valid and expected outcome.

---

## 1. Purpose

PR-24 introduces a pure decision engine that resolves whether the installer is allowed to attempt authority restoration after PR-23 has released authority. It produces one of three outcomes and performs no mutation. Execution of any allowed outcome is the responsibility of a later PR (PR-25+).

## 2. Scope (locked)

### Allowed in PR-24

- Decision engine — pure function over the four input axes
- CLI surface for `--restore` and `--panel-auto-takeover`
- Refusal and intent-required message surfaces
- Structured logging of the decision path (axes read, rule matched, output)
- New state-machine terminals (`StateRestoreRefused`, `StateRestoreIntentRequired`)
- Non-terminal policy-handoff marker (`StateRestoreDecided`) — see §7 prohibitions
- New exit codes (`ExitRefused`, `ExitIntentRequired`)
- Preflight-error surface for classifier reduction failures

### Forbidden (hard, CI-enforced)

- Kernel mutation (`nft`, `iptables`, `ip`, etc.) — zero process spawns
- Service mutation (`systemctl`, service file writes) — zero process spawns
- Filesystem mutation of any config, state, or log file
- History-schema changes (`update-history.json` untouched)
- Any "best effort" / "fallback" / "silent takeover" path
- Any fourth output
- Any path that auto-upgrades `REQUIRE_EXPLICIT_INTENT` to `PROCEED`
- Any restoration-execution code (belongs to PR-25+)

## 3. Inputs — four axes

### A. Classifier state

From `uninstall/authority.Classify`, reused. No parallel detection path.

- `AuthorityNone`
- `AuthorityNFTBan`
- `AuthorityExternal`
- `AuthorityAmbiguous` + sub-kind:
  - `AmbiguityOrphanNFTBan`
  - `AmbiguityConflictExternal`

### B. Prior-authority record

From `internal/installer/prior` (PR-P2-1 hardened schema).

- `NoRecord` — no prior-authority record on disk
- `Complete` — record present, all required fields parseable, **including** `ActiveAtInstall` ∈ {true, false}
- `Incomplete` — record present but one or more required fields missing
  - **Legacy records missing `ActiveAtInstall` are classified as `Incomplete`.** No defaulting to true, no defaulting to false, no inference.
- `Stale` — record present and complete but exceeds freshness window.
  - **Freshness window is fixed at 365 days in PR-24. Configurability is deferred to a later PR.** The implementer has no latitude to choose a different value.

### C. Operator intent (flags)

- `none` (neither flag)
- `--restore`
- `--panel-auto-takeover`

### D. Panel context

From existing panel detection.

- `None`
- `DirectAdmin`
- `cPanel`
- `Plesk`

## 4. Outputs — three only (locked)

- `PROCEED` — policy permits restoration; PR-25+ may execute
- `REFUSE` — policy forbids restoration; no PR-25+ execution permitted
- `REQUIRE_EXPLICIT_INTENT` — policy cannot decide; operator must supply additional intent

No fourth state. No "soft proceed." No default.

## 5. Precedence rule (locked, load-bearing)

Lattice is evaluated top-down in exactly this order:

1. Classifier hard-stops
2. Input / flag validity
3. Prior-record integrity gates
4. Panel context gates
5. Proceed decisions

**Invariant:** no later rule may override an earlier refusal. Earlier-rule output is final.

## 6. Decision lattice (normative)

### Group 1 — Classifier hard-stops

| Classifier | Prior | Flags | Panel | Output |
|---|---|---|---|---|
| `AuthorityNFTBan` | * | * | * | **REFUSE** |
| `AuthorityExternal` | * | * | * | **REFUSE** |
| `AmbiguityConflictExternal` | * | * | * | **REFUSE** |

Absolute. No flag, no panel may override.

### Group 2 — Input / flag validity

| Condition | Output |
|---|---|
| `--panel-auto-takeover` with `Panel=None` | **REFUSE** |
| `--restore` AND `--panel-auto-takeover` both set | **REFUSE** |

Operator input errors, not policy ambiguity.

### Group 3 — `AuthorityNone`

#### 3.1 Strong prior (`Complete` + `ActiveAtInstall=true`)

| Flags | Panel | Output |
|---|---|---|
| none | any | REQUIRE_EXPLICIT_INTENT |
| `--restore` | any | **PROCEED** |
| `--panel-auto-takeover` | panel present | **PROCEED** |

#### 3.2 Complete-but-inactive (`Complete` + `ActiveAtInstall=false`)

| Flags | Panel | Output |
|---|---|---|
| any | any | REQUIRE_EXPLICIT_INTENT |

Rationale: restoring a firewall the operator had deliberately disabled is an implicit re-enablement. Operator must specify target explicitly.

#### 3.3 Weak / absent prior

| Prior | Flags | Panel | Output |
|---|---|---|---|
| `NoRecord` | none | any | REQUIRE_EXPLICIT_INTENT |
| `NoRecord` | `--restore` | any | **REQUIRE_EXPLICIT_INTENT** |
| `NoRecord` | `--panel-auto-takeover` | panel present | **PROCEED** |
| `Incomplete` | any | any | REQUIRE_EXPLICIT_INTENT |
| `Stale` | any | any | REQUIRE_EXPLICIT_INTENT |

Rationale for `NoRecord + --restore`: `--restore` carries an implicit target (the recorded prior firewall). With `NoRecord`, that target does not exist. Panel-auto-takeover is the only flag whose target is independent of the record.

### Group 4 — `AmbiguityOrphanNFTBan`

Group 4 sub-rules are evaluated top-down: 4.1 and 4.2 match on prior state for flags {`none`, `--restore`}; 4.3 matches `--panel-auto-takeover` regardless of prior.

#### 4.1 Strong prior (`Complete` + `ActiveAtInstall=true`)

| Flags | Output |
|---|---|
| none | REQUIRE_EXPLICIT_INTENT |
| `--restore` | **PROCEED** |

#### 4.2 Weak / inactive / absent prior

| Prior | Flags | Output |
|---|---|---|
| `Complete` + `ActiveAtInstall=false` | any | REQUIRE_EXPLICIT_INTENT |
| `NoRecord` | none | REQUIRE_EXPLICIT_INTENT |
| `NoRecord` | `--restore` | **REQUIRE_EXPLICIT_INTENT** |
| `Incomplete` | any | REQUIRE_EXPLICIT_INTENT |
| `Stale` | any | REQUIRE_EXPLICIT_INTENT |

#### 4.3 Orphan + panel-auto

| Flags | Output |
|---|---|
| `--panel-auto-takeover` | **REFUSE** |

Panel-auto must never fire over nftban residue, regardless of recoverability.

### Group 5 — Panel context

Panel context is **inert by default**. Panel-auto-takeover is handled inline in Groups 3 and 4 — as a specialized proceed case under `AuthorityNone`, and as an absolute refusal under `AmbiguityOrphanNFTBan`. It is not a standalone override.

## 7. State-machine integration

Two new `InstallState` terminals (added to `internal/installer/state/machine.go`):

- **`StateRestoreRefused`** — policy-determined refusal.
  - `IsTerminal()` returns true
  - `IsFailed()` returns false (refusal is not failure)
  - Excluded from `IsApplyTerminal()` (no mutation was attempted)
  - Excluded from `update-history.json` (Option A discipline continues)

- **`StateRestoreIntentRequired`** — policy-determined intent-required.
  - `IsTerminal()` returns true
  - `IsFailed()` returns false
  - Excluded from `IsApplyTerminal()`
  - Excluded from `update-history.json`

One non-terminal marker:

- **`StateRestoreDecided`** — marks that PR-24's decision was `PROCEED`.

  **`StateRestoreDecided` is constrained as follows (all enforced by this contract):**

  1. **Policy-only.** It records that the decision engine said `PROCEED`; nothing more.
  2. **Non-terminal for apply semantics.** `IsApplyTerminal()` returns false. `IsTerminal()` returns false.
  3. **Excluded from `update-history.json`.** No history row, no schema change. Option A discipline continues.
  4. **Not evidence that restoration happened.** No kernel, service, or filesystem change is implied. PR-25+ execution would change state further; in PR-24, `PROCEED` is a handoff outcome only.

  *(Name is a placeholder pending bikeshed at implementation time. The semantic role above is locked regardless of final name.)*

## 8. Exit-code contract (extends PR-23 table)

| State | Exit code | Constant |
|---|---|---|
| `StateRestoreDecided` (PROCEED handoff) | 0 | `ExitCommitted` |
| `StateRestoreRefused` | 5 | `ExitRefused` *(new)* |
| `StateRestoreIntentRequired` | 6 | `ExitIntentRequired` *(new)* |

Rationale: distinct codes enable scriptability. Operators and automation must distinguish "engine said no" (5) from "engine said you need to clarify" (6) from "engine failed" (2, unchanged).

## 9. Preflight error boundary (pre-policy)

Any condition that prevents the classifier from producing one of the five supported classifier states is a **preflight error**, not a lattice output. Examples:

- classifier probe command failed
- prior-record file malformed beyond `Incomplete` reduction (e.g., JSON parse failure)
- internal invariant violation (`Ambiguous` without a sub-kind)

Handling: exits with `ExitFatal` (4) and a distinct log marker. Does **not** emit `PROCEED` / `REFUSE` / `REQUIRE_EXPLICIT_INTENT`. This keeps the lattice output space closed and testable.

## 10. Forbidden surfaces — enforcement mechanisms

| Forbidden | Enforcement mechanism |
|---|---|
| Kernel mutation | Exec-trace CI gate — zero `nft` / `iptables` / `ip` process spawns in restore code paths |
| Service mutation | Exec-trace CI gate — zero `systemctl` process spawns in restore code paths |
| Filesystem mutation | Static source scan for write APIs (`os.Create`, `os.WriteFile`, `os.Rename`, `os.Remove*`, `io.Copy` to file targets, template rendering) in the restore package — must be empty. Exec-trace separately proves zero external-process mutation paths. **No syscall-level enforcement is claimed by this seed.** |
| History schema change | Diff check on `update-history.json` schema version + file unchanged across a PR-24 invocation |
| Fourth output | Type system: output is a closed Go enum of three values |
| Auto-upgrade from `REQUIRE_EXPLICIT_INTENT` to `PROCEED` | Source-grep for illegal state transitions in decision engine |

## 11. Proof model

PR-24 correctness is proven on two tiers:

### Tier 1 — Fixture tests (primary proof)

Exhaustive matrix over the 5 × 4 × 3 × 4 input space (= 240 cells), collapsed by the lattice into ~30 distinct rule paths. One test fixture per rule path, asserting exact output. Fixture tests own the dangerous branches (`AuthorityExternal`, `AmbiguityConflictExternal`, `AmbiguityOrphanNFTBan`, weak-record, panel-auto) — these are not real-host branches.

### Tier 2 — Real-host decision tests (secondary proof)

Run the engine on `lab2` and `lab4`, both in clean `AuthorityNone` post-PR-23. Assert:

- bare invocation → `REQUIRE_EXPLICIT_INTENT` (NoRecord + none flags)
- `--restore` → `REQUIRE_EXPLICIT_INTENT` (NoRecord + `--restore`; per locked amendment)
- Zero kernel / service interaction observed in either run (exec-trace)

Real-host proof is deliberately minimal. Simulating dangerous branches at kernel level would violate the no-mutation gate via the test harness itself, which is not acceptable.

## 12. CI gate requirements

Four new gates in the `G4-RESTORE-*` namespace:

| Gate | Assertion |
|---|---|
| `G4-RESTORE-DECISION-CORRECTNESS` | Fixture matrix: input → exact output, one assertion per rule path. Fails if any rule path is untested. |
| `G4-RESTORE-REFUSAL-INTEGRITY` | When output = `REFUSE` or `REQUIRE_EXPLICIT_INTENT`, assert zero execution branches reached in the same invocation. Proven via exec-trace + call-count assertions. |
| `G4-RESTORE-NO-IMPLICIT-EXEC` | Static: grep-based scan of `internal/installer/restore/` for any `exec.`, `nft`, `systemctl`, `os.Create`, `os.WriteFile`, `os.Rename`, `os.Remove*` references. Must be empty. |
| `G4-RESTORE-DETERMINISM` | Same fixture inputs on two back-to-back runs produce identical outputs. No env-variable, time-of-day, or random-seed dependency. |

**Carry-forward from PR-23:** none of `G3-UN-SHIM-LOCK`, `G3-UN-NO-MUTATION`, `G3-EXEC-TRACE`, `G3-KS-SNAPSHOT` are weakened. They continue to apply to uninstall scope unchanged.

## 13. Reviewer checklist (merge-blocking)

### Policy correctness

- [ ] Every classifier state handled (no default branch, no fallthrough)
- [ ] Every prior-record state handled
- [ ] Group 1 hard-stops dominate all flag/panel inputs
- [ ] Panel context never causes proceed without `--panel-auto-takeover`
- [ ] `NoRecord + --restore` returns `REQUIRE_EXPLICIT_INTENT`
- [ ] Legacy records missing `ActiveAtInstall` classify as `Incomplete`
- [ ] Staleness window is fixed at 365 days (not configurable in PR-24)

### Safety

- [ ] `AuthorityExternal` never overridden
- [ ] `AmbiguityConflictExternal` never overridden
- [ ] Orphan + `--panel-auto-takeover` → `REFUSE`
- [ ] No auto-upgrade path from `REQUIRE_EXPLICIT_INTENT` to `PROCEED`

### Purity

- [ ] Zero kernel interaction
- [ ] Zero service interaction
- [ ] Zero filesystem writes in the restore package (static scan green)
- [ ] `update-history.json` schema unchanged
- [ ] Exec-trace gate shows zero external-process spawns in refusal paths

### Output discipline

- [ ] Output type is a closed enum of three (`PROCEED` / `REFUSE` / `REQUIRE_EXPLICIT_INTENT`)
- [ ] State-machine terminals added for refuse / intent-required
- [ ] `StateRestoreDecided` excluded from `IsApplyTerminal` and from history
- [ ] Exit codes distinct: `ExitRefused=5`, `ExitIntentRequired=6`

## 14. Merge-blocking real-host matrix

| Host | OS / family | Required evidence |
|---|---|---|
| `lab2` | Ubuntu 24.04 / DEB | `AuthorityNone + NoRecord`: bare → `REQUIRE_EXPLICIT_INTENT`; `--restore` → `REQUIRE_EXPLICIT_INTENT`; exec-trace clean |
| `lab4` | AlmaLinux 9 / RPM | same as lab2 |

**Not merge-blocking** (optional extended evidence): `monitor`, `srv1`.

**Not real-host** (fixture-only): `AuthorityExternal`, `AmbiguityConflictExternal`, `AmbiguityOrphanNFTBan`, panel-driven proceed, all weak-record branches.

## 15. Follow-up items (tracked, not blocking)

1. `ActiveAtInstall` capture in new prior-record writes. If not already landed in PR-P2-1, new records written after PR-24 should populate the field. Legacy records without it continue to flow through `Incomplete` → `REQUIRE_EXPLICIT_INTENT`; this is intentional and truthful.
2. Staleness window configurability. PR-24 locks the window at 365 days fixed. A configurability knob is deferred to a later PR.
3. Uninstall-history schema decision (carry-forward from PR-23 follow-up).
4. Panel-auto prior-firewall-identity consistency: when `--panel-auto-takeover` is used and prior record exists but names a non-panel-native firewall, this seed has no opinion — panel-auto target is panel-native regardless of record. Worth revisiting in PR-25.

---

## Amendment history

- **2026-04-20 v1 (seed)** — first committed seed. Lattice v2 + three locked corrections:
  1. `§10` filesystem purity enforcement clarified: static source scan for write APIs + exec-trace for external processes. No syscall-level enforcement claim.
  2. `§7` / `§8` `StateRestoreDecided` explicitly constrained as policy-only / non-terminal-for-apply / excluded-from-history / not-evidence-of-restoration.
  3. `§3` / `§15` staleness window locked at 365 days fixed; configurability deferred.
- **2026-04-20 v1 (auditor wording)** — two non-semantic wording clarifications before merge, per auditor review of PR #493:
  1. `§6` Group 5 wording updated: panel-auto handling spans Groups 3 and 4 (proceed under `AuthorityNone`; refuse under `AmbiguityOrphanNFTBan`), not only Group 3.
  2. `§6` Group 4 precedence clarifier added: 4.1 / 4.2 match on prior state for flags {`none`, `--restore`}; 4.3 matches `--panel-auto-takeover` regardless of prior.

  Neither edit changes lattice behavior (§5 precedence already produces the correct outcome).
