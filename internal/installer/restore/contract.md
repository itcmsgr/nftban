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

# PART II — PR-25 execution contract

> **Boundary rule (locked):** PR-24 decides. PR-25 executes. PR-25 may never reinterpret PR-24.
>
> Sections §16–§29 below are normative for PR-25 only. They do not modify §1–§15.

## 16. Purpose (PR-25)

PR-25 is the **execution** counterpart of PR-24's decision engine.

| Phase | Owner |
|---|---|
| Decision (PROCEED / REFUSE / REQUIRE_EXPLICIT_INTENT) | PR-24 (§§1–15 above; merged, soak-validated) |
| Execution (mutate kernel + service run-state to fulfil the authorized decision) | **PR-25 (§§16–29 below)** |
| Post-restore verification gate | PR-26 (separate scope) |

## 17. Scope — Option A: restore execution only (locked, Q1)

PR-25 is **restore execution only**. Bundled purge / remove / artifact-cleanup semantics are EXPLICITLY excluded.

### 17.1 Permitted (PR-25 may do)

- Kernel `nft` mutations within the authorized target's surface
- Service **run-state** changes: `start` / `stop` of `nftband.service` and the target-native firewall service (`ufw` / `firewalld` / `iptables` / `csf` per §20)
- Emergency-SSH safety net: insertion before mutation, removal after inline verification (§21)
- New execution-outcome state terminals + exit codes (§22)

### 17.2 Forbidden (PR-25 may NOT do)

| Forbidden surface | Why excluded |
|---|---|
| `enable` / `disable` policy mutation | INV-PR25-STATIC-SERVICE-LIFECYCLE |
| `mask` / `unmask` | Same |
| Unit-file mutation | Same |
| Cross-target service orchestration | Authority-isolation invariant |
| Filesystem artifact cleanup | Q1 forbidden — deferred to a future purge contract |
| `.conf.local` policy mutation | Operator-content surface; not lifecycle |
| History-schema changes | Stability of decision-record layer |
| `--purge` flag semantics | Q1 forbidden |
| Post-restore verification gate | Q5-B → PR-26 |
| Panel-auto target-identity *resolution* | Q4 — execution-time mapping only |
| Shell wrapper code | Implementation surface choice |

### 17.3 Scope-bounding invariants (named, locked)

- **INV-PR25-AUTHORITY-IMMUTABILITY**: `TargetAuthority` resolved by PR-24 PROCEED is unchanged across the entire PR-25 execution window. No mid-flight re-resolution.
- **INV-PR25-STATIC-SERVICE-LIFECYCLE**: PR-25 makes no change to systemd unit policy, enable/disable state beyond run-state, or unit files.

## 18. TargetAuthority concretization (locked, Q2)

`TargetAuthority` is a struct with **unexported fields** and read-only accessors. Construction is constrained to one of three paths.

### 18.1 Type definition (canonical)

```go
type TargetAuthorityKind string

const (
    TargetAuthorityKindNone          TargetAuthorityKind = ""              // zero value
    TargetAuthorityKindRecordedPrior TargetAuthorityKind = "recorded_prior"
    TargetAuthorityKindPanelNative   TargetAuthorityKind = "panel_native"
)

type TargetAuthority struct {
    kind         TargetAuthorityKind   // unexported
    firewallType string                // unexported
    panel        detect.PanelType      // unexported
}

// Read-only accessors
func (t TargetAuthority) Kind() TargetAuthorityKind
func (t TargetAuthority) FirewallType() string
func (t TargetAuthority) Panel() detect.PanelType

// Per-Kind constructors
func TargetNone() TargetAuthority
func TargetRecordedPrior(firewallType string) (TargetAuthority, error)
func TargetPanelNative(panel detect.PanelType) (TargetAuthority, error)
```

### 18.2 Construction paths

| Kind | Reachable via | Validation |
|---|---|---|
| `None` | `TargetNone()` OR zero value `TargetAuthority{}` (equivalent and intentional) | n/a |
| `RecordedPrior` | ONLY `TargetRecordedPrior(firewallType)` | `firewallType ∈ knownFirewallType` set defined at `internal/installer/uninstall/prior.go:278-284`: `{ufw, firewalld, iptables, csf}` |
| `PanelNative` | ONLY `TargetPanelNative(panel)` | `panel ≠ detect.PanelNone` |

### 18.3 Payload invariants (per Kind)

| Kind | Required fields shape |
|---|---|
| `None` | `firewallType=""`, `panel=PanelNone` |
| `RecordedPrior` | `firewallType ∈ known set`, `panel=PanelNone` |
| `PanelNative` | `firewallType=""`, `panel ≠ PanelNone` |

### 18.4 Closed-enum discipline

- `Kind` enum is closed at the type level. Adding a variant requires §12-style review.
- Default branch in any `Kind` switch MUST `panic` at runtime.
- No exported mutators. Post-construction immutability is by type design — not enforced by CI/linter (acknowledged limit).

## 19. StateRestoreDecided downstream meaning (locked, Q3)

### 19.1 Semantic rule

> *"Exit code 0 from `--mode=restore` with `StateRestoreDecided` is a policy-handoff outcome only. It is NOT evidence that any restoration mutation has been executed."*

### 19.2 Four enforcement layers

| Layer | What | Where |
|---|---|---|
| 1 — Type-level distinctness (narrow) | `StateRestoreDecided` is a distinct constant; PR-25 execution-terminals are **separate** constants. Prevents equality-based confusion only. | `internal/installer/state/machine.go` |
| 2 — API-level disambiguation (PR-25, optional) | `IsRestoreExecuted(s State) bool` helper. Returns true ONLY for execution-terminals. Never true for `StateRestoreDecided`. | new helper alongside `IsApplyTerminal` |
| 3 — Contract-level documentation | Consumer-facing rule added to `state/machine.go` comment + this document. Covers the exit-code-misread class. | (this section) |
| 4 — Defensive gate (already landed) | `cfg.mode == "restore"` excluded from history-write at `cmd/nftban-installer/main.go:132`. | (existing) |

### 19.3 Consumer rule

Consumers MUST NOT use `sf.State == StateRestoreDecided` to infer that restoration execution has occurred.

### 19.4 Exit code discipline

PR-25 execution terminals MUST carry distinct exit codes, **separate from** the existing constants at `internal/installer/state/machine.go:149-155`:

- `ExitCommitted = 0`
- `ExitFatal = 4`
- `ExitRefused = 5`
- `ExitIntentRequired = 6`

New PR-25 exit codes are allocated from the next available integers.

## 20. Panel-auto target consistency (locked, Q4)

When `TargetAuthority.Kind == PanelNative`, PR-25 execution resolves the firewall via a **static explicit mapping**:

```
target_firewall = mapping[TargetAuthority.Panel()]
```

### 20.1 Mapping properties

- **Static, compile-time.** Shipped with PR-25 code as a const map or exhaustive switch.
- **Key type:** `detect.PanelType`.
- **Output validation rule:** mapped value MUST be a member of `knownFirewallType` (the same set used in §18.2).
- **Not required to be exhaustive** over all `detect.PanelType` values.

### 20.2 Ambiguity resolution

| Case | PR-25 behavior |
|---|---|
| Panel ∈ mapping | Execute the mapped firewall |
| Panel ∉ mapping | **REFUSE before any mutation.** Transition to PR-25 execution-failure terminal (see §22). |

### 20.3 Forbidden fallbacks

- **No fallback** to a default firewall on unmapped panel.
- **No fallback** to recorded-prior `FirewallType` (structurally empty by §18.3 invariant when Kind=PanelNative; AND contractually forbidden to consult).
- **No heuristic**, **no runtime discovery**, **no config-driven mapping**.

### 20.4 Boundary with PR-24

§20 is **execution-time** resolution. PR-24 decision-time behavior is NOT modified.

## 21. Post-restore verification — split (locked, Q5)

### 21.1 PR-25 — INLINE VERIFICATION = safety interlock, NOT a gate

- **Purpose:** Prove enough about the mutation outcome to *truthfully set the execution-terminal state* AND *safely remove the safety net*.
- **Scope rule:** Minimum-sufficient checks for terminal-state + safety-net removal decisions.
- **Coverage:** seed skeleton §11's first three assertions only:
  - Target firewall is active
  - nftban authority class is correct (post-mutation)
  - Safety-net removal is safe to proceed with
- **Timing:** Runs WHILE the safety net is still present.
- **Classification:** **safety interlock**, not a verification gate.

### 21.2 PR-26 — POST-RESTORE VERIFICATION GATE (scope-expanded, NOT in this contract)

PR-26 contract content is defined by PR-26's own contract seed work, NOT by §21.

What §21 records about PR-26:
- PR-26 is **scope-expanded** from V1100 contract §8's "post-uninstall verification" / G3-UN-VERIFY to also cover post-restore outcomes.
- PR-26 has its own verification-outcome terminals and exit codes.
- PR-26 has its own operator-invokable CLI surface (PR-26 scope, NOT §21).
- PR-26 is **scope-expanded, not replaced, renumbered, or split**.

### 21.3 Hard invariant

PR-25 MUST NOT remove the safety net until inline verification (§21.1) passes. (V1100 contract §8 step 5.)

### 21.4 PR-25 must NOT implement the gate

PR-25 implements only §21.1. The full gate is PR-26's contract scope.

## 22. State terminals + exit codes (PR-25 introduces)

Concrete names are open in the lock — confirmed candidate set, finalized in code phase:

| Candidate name | Meaning | Exit code |
|---|---|---|
| `StateRestoreExecuted` | Full mutation completed AND inline verification passed AND safety net removed | next available |
| `StateRestoreFailedExecution` | Mutation failed mid-flight; safety net still present; system rolled to known-safe state | next |
| `StateRestoreDegraded` | Mutation completed but inline verification flagged a soft-fail condition; safety net removed under explicit policy | next |
| `StateRestoreFailedVerification` | Mutation completed but inline verification hard-failed; safety net retained; explicit operator action required | next |

Constraints:
- All four MUST be NEW constants distinct from `StateRestoreDecided` (§19.2 layer 1).
- Exit codes MUST be distinct from `ExitCommitted=0` / `ExitFatal=4` / `ExitRefused=5` / `ExitIntentRequired=6`.
- `IsRestoreExecuted(s)` (§19.2 layer 2) returns true for `StateRestoreExecuted` and `StateRestoreDegraded`; false for the other two AND for `StateRestoreDecided`.

Final names + final integers chosen during the code phase.

## 23. Execution shape (V1100 §8, ordered)

PR-25 execution proceeds in this exact ordered sequence:

1. **Preflight target validation** — confirm authority resolution still satisfies invariants (§18.3 payload invariants); confirm `knownFirewallType` membership (RecordedPrior); confirm panel mapping resolves (PanelNative). Refuse here is non-mutating.
2. **Safety net insertion** — emergency-SSH allow rule before any other mutation.
3. **Minimal target-specific execution** — kernel nft mutations + service run-state changes for the authorized target only. No cross-target traffic.
4. **Verification while safety net still present** — inline checks per §21.1.
5. **Safety net removal only after verification passes** — hard gate, no exceptions.
6. **Terminal state set truthfully** — pick the execution-success or execution-failure terminal that matches step-4 outcome; emit the corresponding exit code.

## 24. Inputs PR-25 may consume

- **PR-24 output** — decision MUST be `PROCEED`. `REFUSE` / `REQUIRE_EXPLICIT_INTENT` → PR-25 does not run.
- **Resolved target identity** — `TargetAuthority` of `Kind=RecordedPrior` (with `firewallType`) OR `Kind=PanelNative` (with `panel`). `Kind=None` → PR-25 does not run.
- **Current classifier state** — must still be compatible at runtime (preflight at §23 step 1).
- **Prior record** — only as already reduced/approved by the PR-24 path. PR-25 does not re-reduce.

PR-25 may **NOT** consume:
- Any signal that re-derives `TargetAuthority` (locked by INV-PR25-AUTHORITY-IMMUTABILITY).
- Operator config beyond what was already authorized by PR-24.

## 25. Forbidden behaviors (consolidated)

- No execution if PR-24 ≠ `PROCEED`.
- No target inference beyond what PR-24 authorized.
- No reinterpretation of `StateRestoreDecided` as success.
- No silent fallback between targets.
- No "try restore, then rebuild nftban if fails" pattern.
- No hidden purge/remove unless explicitly in scope (it isn't).
- No history-schema redesign unless separately approved.
- No mutation outside the declared target surface.
- No mid-flight `TargetAuthority` re-resolution.
- No verification beyond §21.1 inline checks (gate is PR-26).
- No safety-net removal before inline verification passes.

## 26. Cross-lock consistency

- **§17 narrow scope × §21 split** → PR-25 stays execution-only; gate-level verification stays in PR-26 → scope integrity preserved.
- **§18 type safety × §20 panel resolution** → `FirewallType` structurally empty for `PanelNative` (§18.3 invariant) AND forbidden to consult (§20.3 contract) → no accidental cross-variant authority leak.
- **§17 authority-resolution immutability × §19 decision-vs-execution boundary** → `TargetAuthority` set once by PR-24, read-only by PR-25 → no reinterpretation across the boundary.
- **§19 rollback coupling × §21 inline safety interlock** → inline verification gates safety-net removal → prevents "remove before prove" rollback failure that would corrupt §19's decision-execution distinction.

## 27. What this contract does NOT contain (intentional, not omission)

- Final state-terminal names + final integer exit codes (§22 candidates only)
- Test fixture matrix (parallels PR-24's exhaustive matrix; produced during code phase)
- Real-host evidence plan (§28 below names hosts; the matrix itself is code-phase work)
- CI gate expansion plan (minimal beyond what's already in `ci-restore-canonization.yml`; specifics emerge in code phase)
- Concrete `IsRestoreExecuted` signature (helper is locked as §19.2 layer 2 optional API)
- The PanelType → firewall mapping itself (locked as static; concrete map content is code-phase work)

These are intentionally absent. **Expansion would violate the locked rule "no expansion beyond Q1–Q5".**

## 28. Merge-blocking real-host matrix (PR-25 code-phase)

| Host | OS / family | Required evidence |
|---|---|---|
| `lab2` | Ubuntu 24.04 / DEB | DEB execution path: at least one `RecordedPrior` case |
| `lab4` | AlmaLinux 9 / RPM | RPM execution path: at least one `RecordedPrior` case |
| (TBD) | panel host (cPanel / DA / Plesk) | At least one `PanelNative` case if in scope at code phase |

Evidence plan is code-phase work; this section names the hosts only.

## 29. Reviewer checklist (merge-blocking, PR-25 code-phase only)

- [ ] §18.1 type definition matches verbatim; no exported mutators.
- [ ] §18.2 construction paths exhaustive; no fourth path exists.
- [ ] §18.3 payload invariants enforced in constructors.
- [ ] §18.4 default-branch panic present in every `Kind` switch.
- [ ] §19.2 layer 1 — execution terminals are NEW constants, not aliases.
- [ ] §19.2 layer 4 — `main.go:132` writeHistory gate untouched.
- [ ] §19.4 — new exit codes distinct from existing 0/4/5/6.
- [ ] §20.1 mapping is static (not config-driven, not runtime-discovered).
- [ ] §20.3 — no fallback paths exist anywhere in execution code.
- [ ] §21.1 inline verification covers exactly the three assertions; nothing more.
- [ ] §21.3 hard invariant — no code path removes safety net before §21.1 returns success.
- [ ] §23 execution sequence respected exactly; no reordering.
- [ ] §25 forbidden behaviors all absent from code.
- [ ] §28 real-host evidence captured for at least lab2 + lab4.
- [ ] CI gate updated minimally (no scope expansion beyond restore-execution surface).

---

# PART III — AMENDMENT 1: CSF restore mutation authorization

> **Authority gap discovered 2026-04-28.** The original §§16–29 PR-25 contract assumed "restore target firewall" was a small run-state mutation (start the target's service). Inspection during PR-25 commit 4B-3 revealed that install-time `switchop.DisableConflicts` (`internal/installer/switchop/takeover.go:32`) performs **persistent, file-level mutations** when nftban takes over from CSF on a DirectAdmin host:
>
> 1. `ServiceStop("csf.service")` + `ServiceDisable` + `ServiceMask`
> 2. Flush `iptables`/`ip6tables` filter/nat/mangle (legacy firewall reset)
> 3. Remove `/etc/cron.d/lfd-cron`, `/etc/cron.d/csf-cron`
> 4. Rename `/usr/sbin/csf` → `/usr/sbin/csf.disabled`
> 5. DirectAdmin custombuild: `build set csf no` (write `csf=no` to options.conf)
>
> A real CSF restore must reverse the operations nftban actually performed. §§16–29 forbid every operation needed for that reversal (no enable/disable, no unit-file edits, no file writes, no broad cleanup). Without an explicit authority extension, PR-25 csf restore is impossible — any partial implementation would leave the host in a broken state (csf service started but binary renamed = ExecStart failure).
>
> **This amendment is CSF-only.** It does NOT authorize inverse-of-install for ufw/firewalld/iptables. Those remain typed-unsupported until separately amended.

## 30. Amendment scope and applicability

### 30.1 In scope

This amendment authorizes a constrained set of inverse-of-install mutations on the **CSF restore path only**. The amendment activates when, and ONLY when, all four conditions hold:

1. PR-24 returned `OutputProceed`.
2. The PR-25 planner resolved `TargetAuthority` such that `Kind == TargetAuthorityKindRecordedPrior` AND `FirewallType() == "csf"`,
   **OR** `Kind == TargetAuthorityKindPanelNative` AND `Panel() == detect.PanelDirectAdmin` (which §20 maps to `"csf"`).
3. The PR-25 dispatcher has actually constructed an `ExecuteDeps` and entered `Execute`.
4. The mutation step (§23.3 / §32 below) is the active phase.

### 30.2 Out of scope

Explicitly **NOT** authorized by this amendment:

- Any non-CSF firewall (`ufw` / `firewalld` / `iptables` / others). They remain typed-unsupported until separately amended.
- Any panel other than `PanelDirectAdmin` (per §20.1, `PanelDirectAdmin` is the only panel mapped in commit 3A; the amendment cannot operate on unmapped panels).
- Any restoration path that does NOT pass through PR-24 PROCEED (the contract entry point is unchanged).
- Operations beyond §31's enumerated list. **No "while we're at it" cleanup.**

### 30.3 Locked invariants that this amendment does NOT modify

The following original §§17–29 invariants apply unchanged:

- **INV-PR25-AUTHORITY-IMMUTABILITY** (§17.3): TargetAuthority resolved by the planner is read-only across execution.
- **§19.2 layer 4**: `main.go:132` writeHistory gate excludes `cfg.mode == "restore"` — the amendment does NOT relax this.
- **§19.4** exit codes for the four §22 terminals are unchanged.
- **§20.3** no-fallback rule remains in force; the amendment introduces NO new fallback.
- **§21.3** safety-net retention on verify-fail is unchanged.
- **§23 ordering** is extended (see §32) but not reordered.

## 31. Authorized inverse-of-install mutations (CSF-only)

Each authorized mutation MUST be gated on its specific evidence precondition. Mutation runs ONLY if its precondition holds. No precondition → no mutation; the higher-level `MutateToTarget` returns a typed sentinel error.

### 31.1 Mutation table

| ID | Mutation | Evidence required (must ALL hold) | Action if precondition fails |
|---|---|---|---|
| **A.1** | `ServiceUnmask("csf.service")` | (a) prior record present AND `FirewallType == "csf"`; OR (b) `csf.service` is currently in `masked` state AND a CSF binary exists at `/usr/sbin/csf` OR `/usr/sbin/csf.disabled`. | Skip A.1 (csf not masked → nothing to unmask). |
| **A.2** | `ServiceEnable("csf.service")` | Same as A.1, plus: A.1 was either skipped (already unmasked) or returned nil. | Skip A.2 (skipping is safe; later ServiceStart still works on a one-shot basis). |
| **A.3** | Restore CSF binary: rename `/usr/sbin/csf.disabled` → `/usr/sbin/csf` (atomic) | (a) `FileExists("/usr/sbin/csf.disabled") == true`; AND (b) `FileExists("/usr/sbin/csf") == false` (target slot empty); AND (c) prior record present with `FirewallType == "csf"` OR PanelDirectAdmin path active. | Skip A.3 if .disabled is absent. **Refuse the entire restore** if both /usr/sbin/csf and /usr/sbin/csf.disabled are present (ambiguous state — operator must resolve). |
| **A.4** | Restore CSF cron files: re-create `/etc/cron.d/csf-cron` AND `/etc/cron.d/lfd-cron` from a manifest backup. | (a) `FileExists("<backup-path>/csf-cron") == true` AND same for lfd-cron; AND (b) target paths in `/etc/cron.d/` are absent; AND (c) prior record evidence as in A.1. | Skip A.4 — log warning that cron files are not restored automatically. Operator must restore manually. (Failing soft on cron is acceptable because csf can run without cron; LFD just won't auto-restart.) |
| **A.5** | `ServiceStart("csf.service")` | A.1, A.2, A.3, A.4 each either skipped (precondition false) OR returned nil. | Mutation fails. Caller (`Execute`) lands at `StateRestoreFailedExecution`, safety-net retained. |
| **A.6** | `ServiceStop("nftband.service")` | A.5 returned nil (csf is now started). | Skip A.6 if nftband is already inactive (idempotent). Mutation fails if nftband is active and stop fails — `StateRestoreFailedExecution`, safety-net retained. |
| **A.7** | Release nftban kernel authority: `NftDeleteTable("ip", "nftban")` AND `NftDeleteTable("ip6", "nftban")`. | (a) A.5 returned nil; AND (b) `ServiceActive("csf.service") == true` (verified at execution time, not just A.5's return); AND (c) the SSH protection check (§32 step 7) confirms SSH still reachable outside the emergency rule. | **Refuse to release nftban tables**. Mutation fails with `ErrCSFRestoreNftReleaseUnsafe`. Safety-net retained. The host is left with both csf and nftban tables present — non-success but non-destructive. Operator must decide. |

### 31.2 Mutation NOT authorized by this amendment

- DirectAdmin custombuild restore (`build set csf yes`) — DirectAdmin's own update path can re-arm csf. Reversing nftban's `build set csf no` is DirectAdmin operator territory, not nftban restore territory. Out of scope.
- Re-arming `/usr/sbin/lfd` if it was disabled (lfd is csf's companion daemon; if csf install-time disable renamed lfd, we don't have explicit evidence here). **If 4B-3-csf inspection finds DisableConflicts also renamed lfd, this amendment must be re-extended before adding A.4-bis.** Until that inspection: lfd restore is NOT authorized.
- Restoring iptables/ip6tables rules that DisableConflicts flushed. Those rules came from CSF's runtime (csf rebuilds them via `csf -r` / `csf -ra` on start). After A.5 starts csf, csf will repopulate iptables. nftban does NOT manually restore the flushed rules.
- Any operation on services other than `csf.service`, `lfd.service` (read-only check), `nftband.service`.
- Any nftban table operation other than the precise `NftDeleteTable("ip", "nftban")` + `NftDeleteTable("ip6", "nftban")` pair in step A.7. No flush, no element edit, no rule add.

## 32. Required ordering — extends §23

The §23 six-step sequence is extended for the CSF path as follows. Each step is numbered to make the inverse-of-install nature explicit. Ordering is normative — no reordering.

1. **Preflight** (§23.1, §31.1 evidence collection). The mutation dep collects evidence for A.1–A.7 BEFORE any mutation. If A.3 finds the ambiguous-binary state, refuse here (non-mutating).
2. **Safety-net insertion** (§23.2; emergency-SSH allow rule per 4B-2).
3. **CSF prerequisite restoration** (§31.1 A.1–A.4 in order, gated by their preconditions). Skip-on-precondition-false is normal; refusal on hard failure of A.3-ambiguous is fatal.
4. **CSF service start** (§31.1 A.5).
5. **CSF post-start verification (cheap)**: `ServiceActive("csf.service")` returns true. If false → mutation fails, no further action.
6. **nftband stop** (§31.1 A.6).
7. **SSH-still-protected check**: ensure SSH connectivity is observable on the post-mutation ruleset OUTSIDE the emergency rule (i.e., csf has loaded its own SSH-allow rule). This is a precondition for step 8 AND for §21.1's third assertion (safety-net removal safe).
8. **nftban kernel release** (§31.1 A.7) — only if step 7 passed.
9. **Inline verification** (§23.4 / §21.1) — three assertions evaluated against the post-mutation state. Must include verification that csf is the current authority class.
10. **Safety-net removal** (§23.5 / §21.3) — only if step 9's verification confirms safe.
11. **Terminal state selection** (§23.6 / §22).

### 32.1 Failure-mode safety-net retention

| Step that fails | Terminal state | Safety net |
|---|---|---|
| Step 1 ambiguous-binary | `StateRestoreFailedExecution` | NOT inserted (refusal pre-§23.2) |
| Step 1 evidence-incomplete | `StateRestoreFailedExecution` | NOT inserted |
| Step 3 (any A.1-A.4) | `StateRestoreFailedExecution` | RETAINED (already inserted at step 2) |
| Step 4 / A.5 | `StateRestoreFailedExecution` | RETAINED |
| Step 5 | `StateRestoreFailedExecution` | RETAINED |
| Step 6 / A.6 | `StateRestoreFailedExecution` | RETAINED |
| Step 7 | `StateRestoreFailedExecution` | RETAINED — host is csf-active but SSH unverified; operator must inspect |
| Step 8 / A.7 | `StateRestoreFailedExecution` (with `ErrCSFRestoreNftReleaseUnsafe`) | RETAINED |
| Step 9 | `StateRestoreFailedVerification` (per §22) | RETAINED per §21.3 |
| Step 10 | `StateRestoreFailedVerification` per §22 candidate path | RETAINED (post-removal verify caught a silent failure) |
| Step 11 happy path | `StateRestoreExecuted` | REMOVED |

## 33. Required evidence preconditions — consolidated

These are the gating conditions per §31.1, restated as a single discoverable list for the implementation.

| Evidence id | What it proves | How the implementation reads it |
|---|---|---|
| **E.1 prior-record FirewallType** | nftban took over from a previously-installed csf | `priorRec != nil && priorRec.FirewallType == "csf"`. priorRec is the same `*uninstall.PriorRecord` the planner consumed; the dispatcher passes it forward to the mutation dep. |
| **E.2 prior-record ActiveAtInstall** | csf was active when nftban installed (so install-time `DisableConflicts` actually ran) | `priorRec.ActiveAtInstall != nil && *priorRec.ActiveAtInstall == true`. If nil, fail closed (treat as "evidence absent"). |
| **E.3 csf binary state** | One of: original-active, install-time-disabled, ambiguous | Inspect `/usr/sbin/csf` and `/usr/sbin/csf.disabled` via `FileExists`. Three states: only-csf (ok), only-csf.disabled (proven disabled), both-present (ambiguous → refuse), neither (csf uninstalled → refuse — restore impossible). |
| **E.4 csf service state** | One of: original-loaded, install-time-masked, absent | Use existing executor surface to read service status. If `csf.service` not listable → refuse (csf uninstalled). |
| **E.5 cron backup manifest** | nftban's install-time removal kept a backup copy | `FileExists` against the backup-path the installer's `disarmCSFArtifacts` is required to produce. **PREREQUISITE NOTE:** if the installer does not currently write a cron backup, A.4 is unimplementable until the install-time path is amended to produce it. The amendment notes this dependency; 4B-3-csf must verify it exists before relying on E.5. |
| **E.6 SSH reachability outside emergency rule** | post-mutation csf rules permit SSH | Inline-verify dep's third assertion (§21.1.3). Cannot skip — A.7 (nftban release) is gated on this. |
| **E.7 panel evidence (PanelNative path)** | DirectAdmin is the live panel | The same `panel detect.PanelType` value the planner used to resolve via §20. Re-validation forbidden — INV-PR25-AUTHORITY-IMMUTABILITY. |

## 34. Forbidden behaviors (CSF-specific) — extends §25

In addition to the §25 consolidated list, the following are forbidden on the CSF restore path:

- **No guessed restore.** A.1–A.7 each refuse when their precondition fails; never proceed on incomplete evidence.
- **No broad cron restoration** — only `/etc/cron.d/csf-cron` and `/etc/cron.d/lfd-cron`, only from manifest backup. No other cron files touched. No other `/etc/cron.d/*`.
- **No DirectAdmin custombuild rewrite.** `build set csf yes` is NOT authorized — DirectAdmin operator territory.
- **No iptables rule re-population.** csf manages its own iptables. nftban does not restore the flushed iptables ruleset.
- **No fallback** — A.3 ambiguous binary state must refuse, not pick one. A.5 csf service start failure must refuse, not retry-with-different-args.
- **No service operations beyond the three named units** (`csf.service`, `lfd.service` read-only, `nftband.service`). No daemon-reload after individual changes (only at the end of step 3 if necessary, and only once).
- **No nftban table flush.** A.7 uses `NftDeleteTable` (the entire authoritative table at once) — no per-rule flush, no per-set element changes.
- **No retry loops.** Each authorized mutation runs at most once per Execute call. Idempotency comes from preconditions, not from retry.
- **No log of secrets.** The amendment introduces no new log-output requirements; existing PR-25 logging applies.

## 35. New tests and §28 evidence requirements

### 35.1 Unit tests required for 4B-3-csf implementation

Each authorized mutation A.1–A.7 must have at minimum:

1. **Happy-path test** — precondition holds, mutation succeeds, mock state reflects the change.
2. **Precondition-false test** — mutation skipped or refused per §31.1's "Action if precondition fails" column.
3. **Ambiguous-state test (A.3 specifically)** — both binary paths present → refuse the entire restore at preflight (step 1).
4. **Idempotency test** — mutation re-run with the post-success state produces no further mutation (or refuses cleanly).
5. **No out-of-target test** — mock executor traces show ZERO calls outside the §31 authorized set + §32 ordering.

### 35.2 Integration tests required

1. **Full Execute with all-evidence-present, all-mutations-needed**: walks steps 1→11; verifies exact ordering; verifies `StateRestoreExecuted` reached.
2. **Full Execute with partial evidence (e.g., csf already unmasked, .disabled absent)**: walks the steps that still apply; skips A.1/A.3; succeeds.
3. **Full Execute with ambiguous binary**: refuses at step 1.
4. **Full Execute with SSH unreachable post-mutation**: A.7 refuses with `ErrCSFRestoreNftReleaseUnsafe`.
5. **Full Execute with verify-fail at step 9**: `StateRestoreFailedVerification`, safety-net retained.

### 35.3 §28 real-host evidence

After 4B-3-csf code lands and unit/integration tests pass, real-host §28 evidence is captured on lab2 (DEB / Ubuntu 24.04 / DirectAdmin) AND lab4 (RPM / AlmaLinux 9 / cPanel).

Required evidence per host:

1. **Pre-condition setup**: install nftban (run install-time `DisableConflicts`, recording exact mutations to disk).
2. **Restore invocation**: `nftban-installer --mode=restore --panel-auto-takeover` (reaches PROCEED via G3.3 or G3.1+PanelAuto or G4.3).
3. **Exec-trace capture**: full strace / audit-log of the dispatcher's child processes during Execute. Evidence MUST show ONLY commands within the §31 authorized set + §32 ordering.
4. **Final-state verification**:
   - `csf.service` is `active`.
   - `nftban` ip + ip6 tables are absent.
   - `nftban_install_emergency` table is absent (safety-net cleaned up).
   - SSH connectivity verified by an out-of-band check (separate session not relying on the safety-net rule).
   - `update-history.json` does NOT contain a new success entry for this restore (per §19.2 layer 4 + main.go:132 mode-gate).

### 35.4 §28 evidence is merge-blocking

Per §28 of the original PR-25 contract, real-host evidence is merge-blocking. This amendment inherits that gate. PR-25 cannot ship without 35.3 evidence captured AND audited.

## 36. Reviewer checklist for 4B-3-csf code phase

When 4B-3-csf opens for review, the reviewer must confirm each of the following:

- [ ] §30 applicability gate: code path is reachable ONLY for the four §30.1 conditions (PROCEED + RecordedPrior+csf OR PanelDirectAdmin+csf + Execute step 3+).
- [ ] §31 mutation set: code performs ONLY A.1–A.7. File-scan + behavior tests confirm zero out-of-set operations.
- [ ] §31.1 evidence gates: each of A.1–A.7 reads its precondition before acting; precondition-false → skip or typed-refuse; never proceed on incomplete evidence.
- [ ] A.3 ambiguous binary: refuses the entire restore at preflight; never picks one binary over the other.
- [ ] §32 ordering: 11-step sequence implemented in exact order; tests pin the order.
- [ ] §32.1 safety-net retention: failure-mode table is reflected in code; retains safety net at every relevant failure step.
- [ ] §33 evidence preconditions: implementation reads each E.1–E.7 from the correct source; never re-derives, never refreshes after the planner.
- [ ] §33 E.5 dependency: if the installer doesn't yet write a cron-backup manifest, A.4 is documented as unimplementable; A.4 returns "skip with operator-warning" until the installer-side prerequisite lands.
- [ ] §34 forbidden behaviors: no guessed restore, no broad cron restoration, no DirectAdmin custombuild rewrite, no iptables re-population, no fallback, no service ops beyond the three named units, no nftban flush.
- [ ] §35.1 unit tests: every A.1–A.7 has happy / precondition-false / idempotency / no-out-of-target coverage.
- [ ] §35.2 integration tests: 5 scenarios (all-evidence, partial-evidence, ambiguous-binary, SSH-unreachable, verify-fail).
- [ ] §35.3 §28 evidence: lab2 + lab4 runs captured, exec-trace audited, final-state verified.
- [ ] §35.4 evidence is in-tree (commit message or evidence file) before merge.
- [ ] No expansion to non-CSF firewalls. ufw/firewalld/iptables remain typed-unsupported.
- [ ] No expansion to non-DirectAdmin panels.
- [ ] §19.2 layer 4 verified: `main.go:132` writeHistory gate untouched.

---

# PART IV — PR-26 restore verification / evidence hardening contract (Seed v1)

> **Status:** Seed (drafted 2026-04-28, pre-implementation, post-PR-25 merge `6a0ab67a`)
> **Scope:** PR-26 is the **verification** counterpart of PR-25's execution engine. It proves on real systems that the PR-25 restore outcome is correct.
>
> Part IV is normative for PR-26 only and does not modify §§1–36.

## 37. Pinned sentence

> PR-25 answered: "can restore execute safely?". PR-26 answers: "can we prove the restore outcome is correct after execution?". The two are intentionally distinct lanes; PR-26 may NOT relax PR-25 invariants and may NOT widen restore lifecycle scope. PR-26 produces evidence and a small set of correctness-tightening changes — nothing more.

## 38. Scope (locked)

### 38.1 Permitted (PR-26 may do)

- Tighten the safety-net-safe predicate to be **target-specific** (Q3, §41).
- Add typed executor methods `ServiceUnmask(unit)` and `Rename(old, new)` and migrate `restore_deps_csf.go` off the raw `Run(...)` indirections (Q5, §43).
- Amend install-time `switchop.disarmCSFArtifacts` to write a cron-backup manifest, then implement A.4 cron-restore against that manifest (Q4, §42).
- Capture **destructive real-host CSF restore evidence** on a staged DirectAdmin host (Q2, §40).
- Tighten the existing `G4-RESTORE-EXEC-NO-OUT-OF-TARGET` CI gate to enforce the new typed-method surface (Q5, §43.4).
- Extend §22 / §32 ordering ONLY where the verification path requires (e.g., a post-restore evidence-collection step that runs AFTER §32 step 11). No change to A.1–A.7 mutation set.

### 38.2 Forbidden (PR-26 may NOT do)

| Forbidden surface | Why excluded |
|---|---|
| Any new mutation primitive beyond Amendment 1 §31 A.1–A.7 | Amendment 1 scope-fence remains in force |
| Authorize ufw / firewalld / iptables restore | Amendment 1 §30.2 explicitly defers to a separate amendment |
| Authorize panels other than DirectAdmin | §20.1 mapping is intentionally sparse |
| Modify the §22 four-terminal set or §19.4 exit codes | Stable consumer contract |
| Modify the `main.go:132` writeHistory gate | INV-PR25-HISTORY-GATE (§38.3) |
| Add a "validator full sweep" step | PR-26 verification is restore-specific, not full-system health |
| Repo hygiene / UX / GOTH / metrics / module cleanup | Out of lane (operator instruction 2026-04-28) |
| Change `TargetAuthority`, `Decide`, planner, or PR-24 lattice | Frozen by §17.3 / §6 |
| Allow the cron-backup manifest to be operator-readable secret | Manifest is metadata only — the cron files themselves are public-config |

### 38.3 Scope-bounding invariants (named, locked)

- **INV-PR26-VERIFICATION-IS-PROOF-NOT-DECISION**: PR-26 verification produces evidence and may set a §22 terminal; it does NOT re-decide the PR-24 output, re-resolve `TargetAuthority`, or modify the §32 mutation order.
- **INV-PR26-NEW-MUTATION-SURFACES-BOUNDED**: PR-26 introduces exactly three new mutation surfaces:
   1. typed `executor.ServiceUnmask`
   2. typed `executor.Rename`
   3. install-time CSF/LFD cron-backup manifest write under `/var/lib/nftban/state/csf-cron-backup/`

   These are bounded extensions of PR-25 Amendment 1 and are the only new mutation surfaces allowed in PR-26. No fourth mutation surface is permitted without a new contract amendment. (Surfaces 1 + 2 replace the raw `Run("systemctl","unmask",…)` and `Run("mv",…)` indirections that Amendment 1 §31 already authorized; surface 3 makes the §31 A.4 cron path implementable by preserving the cron files Amendment 1 implicitly assumed but never required to be backed up.)
- **INV-PR25-HISTORY-GATE**: `main.go:132` mode-gate (§19.2 layer 4) is unchanged. PR-26 verification MAY emit a PR-26-specific evidence-record file (separate from `update-history.json`) but that file is NEVER `update-history.json` itself.
- **INV-PR26-EVIDENCE-PRIVATE-BY-DEFAULT**: Real-host evidence captures stay PRIVATE per the PR-25 precedent. `evidence/` and `pr25-evidence/` remain in `.gitignore`; PR-26 evidence lands at the operator's internal handoff path (likely `/home/commonfolder/LLMAI4NFTBAN/V1.90_AUDIT_WIKI_CODE/PR26_EVIDENCE/`).

## 39. Q1 — Verification authority (proposed lock)

What evidence proves the restore outcome is correct? Each candidate is classified BLOCKING (must hold for `StateRestoreExecuted`) or ADVISORY (logged but not load-bearing).

### 39.1 Decision table

| # | Evidence | Classification | Source | Notes |
|---|---|---|---|---|
| 1 | Target firewall service active (`csf.service` for csf restore) | **BLOCKING** | `exec.ServiceActive(unit)` | Already enforced by §21.1 assertion 1 |
| 2 | nftband.service stopped | **BLOCKING** | `exec.ServiceActive("nftband.service") == false` | §32 step 6 already performs the stop; verification confirms the post-state |
| 3 | nftban kernel tables released (`ip:nftban` + `ip6:nftban` absent) | **BLOCKING** | `exec.NftTableExists("ip","nftban") == false` AND same for `ip6` | §32 step 8 / A.7 performs the release; verification confirms |
| 4 | Emergency safety-net table absent post-removal | **BLOCKING** | `exec.NftTableExists("inet","nftban_install_emergency") == false` | §32 step 10 performs the removal; verification confirms |
| 5 | Final authority class equals expected | **BLOCKING** | `uninstall.Classify().State == AuthorityExternal` for csf restore | Already §21.1 assertion 2; PR-26 elevates to BLOCKING for the post-restore evidence-record file |
| 6 | Target firewall protects SSH outside the emergency rule (target-specific) | **BLOCKING** | Target-specific kernel evidence — see Q3 / §41 | Replaces PR-25's any-external-FW heuristic |
| 7 | External SSH continuity from out-of-band session | **ADVISORY** | Operator-driven; cannot be observed by the dispatcher itself | Captured manually in §28 evidence; not a programmatic gate |
| 8 | `update-history.json` unchanged for restore mode | **BLOCKING** | sha256 pre/post diff | Already enforced by `main.go:132`; PR-26 evidence-record file MUST include the diff |
| 9 | Final state-machine terminal == `StateRestoreExecuted` (or `StateRestoreDegraded` per §22 candidate set) | **BLOCKING** | Persisted state file | If terminal != one of the success terminals, verification did not pass |
| 10 | Validator full sweep | **NOT REQUIRED** | n/a | Out of PR-26 scope — restore is a narrow lane |
| 11 | CLI ruleset parsing (`nft list ruleset` parsed for ownership) | **NOT REQUIRED** | n/a | CLI ruleset parsing is not required and must not be used as truth. Kernel/service truth must come from typed executor methods, such as `NftTableExists`, `ServiceActive`, and any additional typed introspection method explicitly authorized by Q5 / §48.1. |

### 39.2 Decision (proposed lock)

- **Kernel evidence (1, 3, 4)**: BLOCKING.
- **Systemd evidence (1, 2)**: BLOCKING.
- **External SSH continuity (7)**: ADVISORY only. PR-26 evidence pack documents the manual check; not programmatic.
- **Authority class (5)**: BLOCKING.
- **Target-specific safety predicate (6)**: BLOCKING — see Q3 §41.
- **History gate (8)**: BLOCKING.
- **Terminal state (9)**: BLOCKING.
- **Validator sweep (10) and CLI parsing (11)**: NOT REQUIRED — out of scope.

### 39.3 What PR-26 produces from this

A new file `restore_evidence.go` (or similar) in `cmd/nftban-installer/` that, on every `StateRestoreExecuted` terminal, writes a structured JSON evidence-record file at a documented path under `/var/lib/nftban/state/restore-evidence/<timestamp>.json`. The file carries: kernel-table presence, systemd-active states, authority class, sha256 of `update-history.json` pre/post, terminal name, exit code, target firewall, panel context, and the safety-net-safe predicate's result. **OPEN**: exact path + schema version are §48 open questions.

## 40. Q2 — Real-host destructive soak scope (proposed lock)

### 40.1 Decision table

| # | Question | Proposed lock | Rationale |
|---|---|---|---|
| Q2.1 | lab2 / lab4 only, or staged DirectAdmin required? | **Staged DirectAdmin required for PR-26 merge.** lab2 / lab4 fixture-style runs (PR-25 §28 shape) are sufficient for PR-26 commits 1-3 (predicate, executor, cron). The destructive soak is the merge-blocker for PR-26 final. | Without a real DirectAdmin host, A.7 nftban table release post-CSF-active is never observed in production. |
| Q2.2 | Destructive restore required before PR-26 merge? | **Yes.** At least ONE clean A.1→A.7 destructive cycle on a staged DirectAdmin host with a captured exec-trace. | Otherwise PR-26 reduces to fixture-only and does not prove the outcome. |
| Q2.3 | Production srv3? | **No, unless operator-approved per-run.** srv3 is a real production DirectAdmin host; running destructive restore against it requires explicit approval each time. The default is a staged VM. | Operator policy: srv3 is supplemental, not required, evidence (per PR-25 close-out). |
| Q2.4 | What evidence paths are private vs committed? | **Private by default.** Per PR-25 precedent: `evidence/`, `pr25-evidence/`, `pr26-evidence/` all in `.gitignore`. Real evidence lives at the operator's internal handoff path. Public-facing references in commit messages / README cite the private path; do not embed file contents. | Operator policy: hostnames + infra detail must not be published. |
| Q2.5 | Redaction rules if any evidence is summarized publicly | **Hostnames, IPs, panel-customer data, certificate fingerprints redacted.** Distro / kernel version / nftban version permitted. Per-host classification keys (lab2/lab4/staged-da/srv3) replaced with role labels (DEB-NoCSF/RPM-NoCSF/STAGED-DA-CSF/PROD-DA-CSF). | Defense in depth even when sharing summaries. |

### 40.2 What PR-26 produces from this

- A reproducible setup script (private, lives at the operator handoff path) that stages a DirectAdmin VM with prior CSF state suitable for A.1–A.7.
- An evidence pack: pre/post nft list ruleset, csf+nftband service states, emergency-table lifecycle, exec-trace capture, update-history.json diff, final installer state, out-of-band SSH continuity log.
- All of the above in the private evidence tree only.

## 41. Q3 — Safety-net-safe predicate tightening (proposed lock)

### 41.1 Current PR-25 behavior

`productionInlineVerifyDep.IsSafetyNetRemovalSafe` returns true iff:
1. `detect.SSHPort` resolves AND
2. ANY service in `inlineVerifyExternalFirewallServices` (csf / ufw / firewalld / iptables / netfilter-persistent) is active.

This loosely accepts a host where, e.g., `firewalld` happens to be active even when CSF (the restore target) failed to start.

### 41.2 Proposed lock

For Amendment-1 csf-restore path, the predicate MUST narrow to the **resolved target's specific unit**:

1. `detect.SSHPort` resolves on the running listener (Source 1 `ss -tlnp`, NOT a fallback to sshd_config or state file). **PROPOSED LOCK** — sshd_config or state file evidence is too weak to confirm post-mutation reachability.
2. `exec.ServiceActive(targetUnit) == true` where `targetUnit` is the unit derived from the resolved `firewallType` (csf → `csf.service`).
3. **Target firewall has loaded an SSH-allow rule.** Mechanism: kernel-level evidence ONLY. **OPEN** §48.1 — exact mechanism (csf manages iptables-legacy, not nftables; we may need `iptables-legacy -L INPUT -n -v --line-numbers` parsed for the SSH port allow OR an `nft list table ip filter` query for the `csf` table). The mechanism MUST stay inside `executor.Executor` (no raw `os/exec`) and MUST be deterministic.

### 41.3 Where the tightened predicate lives

The predicate stays in `productionInlineVerifyDep.IsSafetyNetRemovalSafe`. PR-26 does NOT add a new mutation pre-release check or a separate package — it tightens the existing assertion with target awareness.

To make the predicate target-aware, the dep gains a read-only `firewallType` field (or a `targetUnit` field) populated by the production factory at construction time, mirroring the priorRec/panel plumbing landed by 4B-3-pre. **OPEN** §48.2 — whether to plumb `firewallType` or a pre-computed `targetUnit`; the answer depends on whether ufw / firewalld / iptables ever become supported (Amendment 1 §30.2 says no, but the predicate should be ready).

### 41.4 Authorization scope

ufw / firewalld / iptables remain typed-unsupported per Amendment 1 §30.2. The tightened predicate refuses with the existing `ErrInlineVerifyOnlyCSFAuthorized` for non-csf targets — no behavior change there.

## 42. Q4 — Cron backup / A.4 restore contract (proposed lock)

### 42.1 Current state

`internal/installer/switchop/takeover.go::disarmCSFArtifacts` (lines 81–107) runs `rm -f /etc/cron.d/lfd-cron /etc/cron.d/csf-cron` without preserving copies. PR-25 A.4 logs an operator warning and continues; **no cron files are recreated**.

### 42.2 Proposed lock

**A. Install-time backup:**

`disarmCSFArtifacts` MUST, before removing each cron file, copy it (with its mode and ownership) to a backup location AND emit a manifest entry. Proposed paths:

- Backup files: `/var/lib/nftban/state/csf-cron-backup/csf-cron`, `/var/lib/nftban/state/csf-cron-backup/lfd-cron`. **OPEN** §48.3 — exact directory name (alternative: `/var/lib/nftban/csf-restore/cron/`). Pick the one consistent with existing `/var/lib/nftban/state/` layout.
- Manifest: `/var/lib/nftban/state/csf-cron-backup/manifest.json`. Schema:
  ```json
  {
    "schema_version": "1.0.0",
    "captured_at": "2026-04-28T07:00:00Z",
    "files": [
      {"src": "/etc/cron.d/csf-cron", "backup": "csf-cron", "sha256": "…", "mode": "0644", "uid": 0, "gid": 0},
      {"src": "/etc/cron.d/lfd-cron", "backup": "lfd-cron", "sha256": "…", "mode": "0644", "uid": 0, "gid": 0}
    ]
  }
  ```
  **OPEN** §48.4 — schema version, fields, whether to include the original mtime.

**B. A.4 restore preconditions:**

A.4 runs iff **all** of the following hold:

1. Manifest exists at the documented path AND parses cleanly (schema_version match).
2. Each backup file in the manifest exists AND its sha256 matches the manifest entry (integrity check).
3. The corresponding `/etc/cron.d/<name>` target path is absent (don't overwrite operator-modified state).
4. Standard E.1 / E.7 evidence holds (same as PR-25).

If any precondition fails: A.4 stays soft-skip with an operator-warning log line that is more specific than PR-25's generic warning (states which precondition failed).

**C. Migration behavior:**

Existing installs without a manifest (i.e., installs from before the PR-26 amendment lands) get the same soft-skip behavior PR-25 ships today. No retro-active manifest creation; no fabrication of cron contents.

**D. Refusal behavior on integrity failure:**

If the manifest exists but a backup file's sha256 does not match the manifest entry, A.4 refuses with `ErrCSFRestoreCronManifestCorrupt` (new typed sentinel) and stays soft-skip. **The mutation does NOT abort** — A.5 still runs. Cron is non-critical for csf to function (csf runs without cron; LFD just won't auto-restart) per Amendment 1 §31 A.4 rationale. A failed cron restore is a P1 logged warning, not a P0 mutation failure.

### 42.3 What PR-26 produces from this

- An installer-side amendment to `internal/installer/switchop/takeover.go::disarmCSFArtifacts` (yes, this is one place where PR-26 touches install-time code — bounded to writing the backup manifest before cron removal). The file lives in `internal/installer/switchop/`, which is NOT in PR-25's do-not-touch list.
- New restore-side logic in `cmd/nftban-installer/restore_deps_csf.go::mutateToCSFTarget` step 3 that flips A.4 from soft-skip to manifest-restore when E.5 holds.
- New typed sentinels for the cron-restore failure modes.
- Tests for manifest creation, manifest read, integrity check, refusal modes.

## 43. Q5 — Executor hardening (proposed lock)

### 43.1 Current state

`restore_deps_csf.go` uses `exec.Run("systemctl","unmask","csf.service")` at A.1 and `exec.Run("mv", csfBinaryDisabled, csfBinary)` at A.3 because `executor.Executor` lacks typed `ServiceUnmask` and `Rename` methods. The `G4-RESTORE-EXEC-NO-OUT-OF-TARGET` CI gate's per-call argument enforcement was dropped in PR-25 commit-5-fix because shell regex couldn't reliably parse identifier arguments.

### 43.2 Proposed lock

**A. Add typed methods to `executor.Executor`:**

```go
// ServiceUnmask unmasks a systemd unit (inverse of ServiceMask).
ServiceUnmask(unit string) error

// Rename atomically renames oldpath to newpath. Same-filesystem semantics
// equivalent to syscall.Rename. Implementations route through whatever
// primitive their host abstraction provides (RealExecutor uses os.Rename;
// MockExecutor records and updates its in-memory file map).
Rename(oldpath, newpath string) error
```

**B. Implementation:**

- `RealExecutor.ServiceUnmask` runs `systemctl unmask <unit>` via `RunTimeout` and returns the typed error path consistent with `ServiceMask`.
- `RealExecutor.Rename` calls `os.Rename(oldpath, newpath)` (NOT `os/exec`-shelled `mv`) — this is the single point where `os.Rename` is permitted in the executor package, matching the existing `WriteFileAtomic` precedent.
- `MockExecutor.ServiceUnmask` records the systemctl-style command and returns nil.
- `MockExecutor.Rename` records the call AND updates `Files` to reflect the rename.

**C. Migration:**

`restore_deps_csf.go::unmaskCSFService` becomes `m.exec.ServiceUnmask(csfServiceUnit)`. `restore_deps_csf.go::renameAtomicViaExec` becomes `m.exec.Rename(oldpath, newpath)`. The two helper functions can be inlined or kept as thin wrappers (operator preference; **OPEN** §48.5).

**D. Tighten G4-RESTORE-EXEC-NO-OUT-OF-TARGET:**

- Forbid `Run("systemctl"...)` for unit-mutating verbs (start / stop / enable / disable / mask / unmask / restart / reload). Only `Run("systemctl","is-enabled",…)` and `Run("systemctl","is-active",…)` remain — read-only probes.
  - Pattern: forbid `exec\.Run\("systemctl",\s*"(start|stop|enable|disable|mask|unmask|restart|reload)"`.
- Forbid `Run("mv",...)` entirely. The typed `Rename` is the only authorized path for atomic file moves.
  - Pattern: forbid `exec\.Run\("mv"\b`.
- Re-introduce the per-call-unit-allow-list pin for `ServiceUnmask`, `ServiceEnable`, `ServiceStart`, `ServiceStop` — but as Go-AST-style structural greps over the typed method calls (not the raw Run strings). This is feasible because typed-method args ARE constants in source and parse as Go identifiers; we can forbid every typed-service call whose argument is not in the allow-list `{csf.service, nftband.service}` for `restore_deps_csf.go`.

### 43.3 Raw `Run` policy in restore deps

After PR-26:
- `Run` is permitted in `restore_deps.go` ONLY for read-only probes (currently: `detect.SSHPort` indirectly via `Run("ss","-tlnp")`).
- `Run` is permitted in `restore_deps_csf.go` ONLY for read-only `Run("systemctl","is-enabled",...)` (and similar). Every mutating system call must go through a typed method.
- The CI gate enforces this with the strengthened patterns above.

### 43.4 What PR-26 produces from this

- Two interface additions in `internal/installer/executor/executor.go`.
- Implementations in `internal/installer/executor/real.go` and `internal/installer/executor/mock.go`.
- Migration of `restore_deps_csf.go` to the typed methods.
- Strengthened CI gate patterns.
- New tests for the typed methods (parity with existing `ServiceMask` / `WriteFileAtomic` tests).

## 44. Proposed invariants (locked-in summary)

| Name | Statement |
|---|---|
| **INV-PR26-VERIFICATION-IS-PROOF-NOT-DECISION** | PR-26 verification produces evidence; it does NOT re-decide PR-24, re-resolve TargetAuthority, or modify §32 ordering. |
| **INV-PR26-NEW-MUTATION-SURFACES-BOUNDED** | PR-26 introduces exactly three new mutation surfaces: (1) typed `executor.ServiceUnmask`, (2) typed `executor.Rename`, (3) install-time CSF/LFD cron-backup manifest write under `/var/lib/nftban/state/csf-cron-backup/`. No fourth mutation surface is permitted without a new contract amendment. |
| **INV-PR25-HISTORY-GATE** | `main.go:132` writeHistory mode-gate unchanged; PR-26 evidence-record file is a SEPARATE artefact from `update-history.json`. |
| **INV-PR26-EVIDENCE-PRIVATE-BY-DEFAULT** | Real-host evidence captures stay PRIVATE per PR-25 precedent; `evidence/`, `pr25-evidence/`, `pr26-evidence/` all gitignored. |
| **INV-PR26-TARGET-SPECIFIC-PREDICATE** | `IsSafetyNetRemovalSafe` proves the resolved target's unit is providing SSH protection, not "any external firewall". |
| **INV-PR26-RAW-RUN-FORBIDDEN-FOR-MUTATION** | After PR-26, raw `exec.Run` is permitted in restore deps ONLY for read-only probes. Mutation goes through typed methods exclusively. |

## 45. Merge-blocking evidence requirements

| Evidence | Source | Merge-blocking? |
|---|---|---|
| Fixture tests for typed `ServiceUnmask` + `Rename` (parity with existing `ServiceMask` + `WriteFileAtomic`) | `internal/installer/executor/{real,mock}_test.go` | YES |
| Migration tests proving `restore_deps_csf.go` uses typed methods only (no raw `Run("systemctl",mutating)`, no raw `Run("mv",…)`) | `restore_deps_csf_test.go` | YES |
| Target-specific predicate tests proving safe-to-remove gates on csf.service AND target SSH-rule kernel evidence | `restore_deps_inlineverify_test.go` | YES |
| Cron-backup manifest tests: write at install, read at restore, integrity check, missing-manifest soft-skip, corrupt-manifest typed refusal | new test file or extension to existing `switchop_test.go` + `restore_deps_csf_test.go` | YES |
| Strengthened CI gate replays clean against modified `restore_deps_csf.go` | local + CI run | YES |
| Real-host destructive CSF restore on a staged DirectAdmin VM: full A.1–A.7 cycle, exec-trace clean of out-of-target processes, post-state verifies all §39.1 BLOCKING signals, evidence pack at the private path | private evidence tree | YES |
| Fixture-only lab2 (DEB) + lab4 (RPM) coverage of the same code paths | `go test` on lab2 + lab4 | YES |
| Out-of-band SSH continuity confirmation during the destructive run | operator log entry | YES (advisory but recorded) |

## 46. CI gate requirements

### 46.1 Locked discipline for text-grep gates

All text-grep gates in PR-26 MUST follow these rules to avoid the false-positive class that broke `Architecture Policy / Suppression comment audit` on PR #511:

- **Production-code gates exclude `*_test.go` files.** Tests legitimately reference forbidden symbols in negation comments, fixture strings, and behavior assertions. Production-side scope only.
- **Grep gates ignore line-leading comments.** Pipe through `grep -vE '^[[:space:]]*//'` (or equivalent line-skipping) before checking forbidden patterns. A literal forbidden token inside a `//` comment is documentation, not a violation.
- **Future complex write-path gates use Go AST or structural runtime tests, not raw grep.** When a gate needs to assert "every call to API X targets resource Y", that requires AST-aware analysis. Don't bolt regex onto problems that aren't regex problems.

### 46.2 Gate table

| Gate | Change | Rationale |
|---|---|---|
| `G4-RESTORE-EXEC-NO-OUT-OF-TARGET` | Add forbidden patterns for `exec\.Run\("systemctl",\s*"(start\|stop\|enable\|disable\|mask\|unmask\|restart\|reload)"` and `exec\.Run\("mv"\b`. Apply §46.1 line-skipping discipline (production-code-only; ignore line-leading comments). | Forces typed-method use for mutating systemctl + atomic rename |
| `G4-RESTORE-EXEC-NO-OUT-OF-TARGET` | Add per-call unit allow-list for typed `ServiceUnmask` / `ServiceEnable` / `ServiceStart` / `ServiceStop` over `restore_deps_csf.go` only — args MUST be in `{"csf.service", "nftband.service"}`. Implementation MUST use Go-AST parsing (preferred) OR a structural Go-source matcher; raw regex over identifier args is forbidden by §46.1. | Replaces PR-25's silently-no-op systemctl/mv pins with structurally reliable Go-source matching |
| `G4-RESTORE-EVIDENCE-RECORD` (new) | **Structural requirement, not vague static scan.** All evidence-record file writes MUST route through a single helper (e.g., `writeRestoreEvidence(record)`) that uses a named constant `evidenceRecordDir` for the destination path. Tests in `restore_evidence_test.go` MUST assert every `WriteFileAtomic(...)` call in `restore_evidence.go` flows from that helper / constant. CI may grep for forbidden direct `WriteFileAtomic\(` calls outside the helper definition (production-code-only, §46.1 discipline). | Enforces the §39.3 / §44 separation between PR-26 evidence and PR-23/PR-24 history without relying on fragile path-string parsing |
| `G4-RESTORE-CRON-MANIFEST-INTEGRITY` (new) | Structural requirement: the manifest writer in `switchop/takeover.go` MUST compute and persist a `sha256` per cron file before removal; the manifest reader in `restore_deps_csf.go` MUST verify each `sha256` before A.4 acts. Behavior tests assert the integrity-check refuses on mismatched sha256. CI may add a structural grep over both files (production-code-only, §46.1 discipline) confirming the sha256 helper symbols are present in both writer + reader. | Catches a silent-corruption regression where A.4 would restore a stale or tampered backup |
| `G4-RESTORE-NO-IMPLICIT-EXEC` (existing) | No change | Already forbids mutation in `internal/installer/restore/`; PR-26 inherits |
| `G4-RESTORE-DECISION-CORRECTNESS` (existing) | No change | PR-24 lattice unchanged |

## 47. Reviewer checklist (PR-26 code-phase merge-blocking)

### Scope
- [ ] No file in PR-25's do-not-touch list is modified outside the PR-26-permitted set (`switchop/takeover.go` for cron-backup; `executor/{executor,real,mock}.go` for typed methods; `restore_deps.go` / `restore_deps_csf.go` / their test files for migration; `restore_evidence.go` new; CI workflow for gate updates).
- [ ] §22 four-terminal set unchanged.
- [ ] §19.4 exit codes unchanged.
- [ ] `main.go:132` writeHistory gate untouched.
- [ ] No new mutation primitive beyond §43.2 (`ServiceUnmask`, `Rename`).

### Verification correctness
- [ ] `IsSafetyNetRemovalSafe` is target-specific (resolved unit, not any-external-FW).
- [ ] Target firewall SSH-rule kernel evidence is actually queried (not skipped).
- [ ] Cron-backup manifest schema_version is checked at read time.
- [ ] Cron sha256 integrity checked before A.4 acts.
- [ ] A.4 corrupt-manifest path returns `ErrCSFRestoreCronManifestCorrupt` and stays soft-skip; A.5 still runs.

### Executor hardening
- [ ] `executor.Executor` interface adds ONLY `ServiceUnmask` and `Rename`.
- [ ] `RealExecutor.Rename` uses `os.Rename` directly (not `os/exec`-shelled `mv`).
- [ ] `restore_deps_csf.go` contains zero `Run("systemctl",mutating-verb,…)` and zero `Run("mv",…)` after migration.
- [ ] Strengthened CI gate replays clean.

### Evidence
- [ ] PR-26 evidence-record file lands at the documented path; schema_version matches.
- [ ] Real-host destructive cycle on a staged DirectAdmin VM captured with full evidence pack at the private path.
- [ ] No public commit of evidence files; `.gitignore` updated if a new pattern is needed.

### CI
- [ ] All existing G4-RESTORE-* gates still green.
- [ ] New `G4-RESTORE-EVIDENCE-RECORD` and `G4-RESTORE-CRON-MANIFEST-INTEGRITY` gates added and green.

## 48. Open questions (explicitly marked)

These are the questions Part IV does NOT lock; the auditor + operator decide them at Q1-Q5 lock time before code phase opens.

- **§48.1 (Q3) — HARD BLOCKER for PR-26-code-A.** Exact mechanism for the target firewall SSH-rule kernel evidence in `IsSafetyNetRemovalSafe`. CSF manages iptables-legacy, not nftables; the existing `executor.NftTableExists` is nft-only and cannot probe iptables rules. PR-26-code-A IS the target-specific safety predicate; without this mechanism locked, code-A cannot be implemented. CLI parsing is forbidden (§39.1 row 11). Operator/auditor must choose:

  - **Option A — Add iptables typed introspection.** Add a third typed executor method, e.g. `IptablesRuleExists(table, chain, port int) bool`, and keep §39.1 row 6 ("target firewall protects SSH outside the emergency rule") **BLOCKING**. Q5's bounded-3-method invariant (`INV-PR26-NEW-MUTATION-SURFACES-BOUNDED`) does NOT cover this addition because that invariant applies to mutation surfaces only; an introspection method is read-only and authorized as the §48.1 resolution. The Q5 §43.2 method list expands from 2 to 3 (read-only) typed methods; the mutation count remains at 2.

  - **Option B — Downgrade target SSH-rule kernel evidence to ADVISORY.** Do NOT add iptables introspection. §39.1 row 6 becomes ADVISORY rather than BLOCKING; row 6 is logged in the evidence-record file but does not gate `StateRestoreExecuted`. BLOCKING evidence then consists of: service-active (rows 1, 2), kernel-table presence/absence (rows 3, 4), authority class (row 5), update-history unchanged (row 8), terminal correct (row 9), AND `detect.SSHPort` listener-source success. External SSH continuity (row 7) remains ADVISORY.

  **No PR-26-code-A may start until operator/auditor chooses Option A or Option B.** This decision is captured in the operator's lock signal for PR-26; until then, code-A is structurally unimplementable.
- **§48.2 (Q3)** — Whether to plumb `firewallType string` or pre-computed `targetUnit string` into `productionInlineVerifyDep`. Lock candidate: `firewallType` (consistent with the existing `priorRec` / `panel` plumbing pattern from 4B-3-pre).
- **§48.3 (Q4)** — Cron-backup directory: `/var/lib/nftban/state/csf-cron-backup/` vs `/var/lib/nftban/csf-restore/cron/` vs other. Lock candidate: `/var/lib/nftban/state/csf-cron-backup/` (consistent with existing `/var/lib/nftban/state/` layout).
- **§48.4 (Q4)** — Cron-backup manifest schema. Proposed shape in §42.2 is a strawman. Lock candidate: `schema_version` + `captured_at` + per-file `{src, backup, sha256, mode, uid, gid}`. Mtime preservation is OPEN; default to NOT preserving mtime (matches `WriteFileAtomic` behaviour).
- **§48.5 (Q5)** — Whether to keep the `unmaskCSFService` / `renameAtomicViaExec` thin-wrapper helpers or inline them. Lock candidate: inline them — typed methods make the wrappers redundant.
- **§48.6 (Q1 / §39.3)** — Exact path + schema for the post-restore evidence-record file. Candidate path: `/var/lib/nftban/state/restore-evidence/<unix-timestamp>.json`. Schema TBD; include all §39.1 BLOCKING signals + their observed values.
- **§48.7 (Q2)** — Where to source the staged DirectAdmin VM. Local KVM image, dedicated staging server, fresh cloud VM per run? Lock candidate: dedicated staging VM with a snapshot-restore script so each destructive run starts from a known clean state.

## 49. Non-goals (explicit)

These are intentionally OUTSIDE PR-26 scope, lest scope creep nullify the lane.

- Authorize ufw / firewalld / iptables restore. Stays as Amendment 1 §30.2 deferral.
- Authorize panels other than DirectAdmin. Stays as §20.1 sparse mapping.
- Modify the four §22 terminals or §19.4 exit codes. Stays.
- Add a "validator full sweep" or module-health probe. Out of lane (§38.2).
- Repo hygiene / UX / GOTH / metrics / module cleanup. Out of lane (operator instruction 2026-04-28).
- Change PR-24 lattice rules. Stays.
- Change `TargetAuthority` types or planner. Stays.
- Promote read-only systemctl probes (`is-enabled`, `is-active`) to typed methods. Out of PR-26 scope; tracked as a follow-up item.
- Ship a generic "verify the host is healthy" command. Restore-specific verification only.

## 50. Sequencing recommendation

Per the operator's PR-25 cadence:

| Slice | Scope | Files (expected) |
|---|---|---|
| **PR-26-doc** (this) | Contract seed (§§37–48) | `internal/installer/restore/contract.md` |
| **PR-26-code-A** | Target-specific safety predicate (Q3) | `restore_deps.go`, `restore_deps_inlineverify_test.go` |
| **PR-26-code-B** | Typed executor methods (Q5) + migration | `executor/{executor,real,mock}.go`, `restore_deps_csf.go`, related tests, CI gate |
| **PR-26-code-C** | Cron backup manifest at install + A.4 manifest-restore | `switchop/takeover.go`, `restore_deps_csf.go`, related tests. **Internal ordering:** install-time manifest creation in `switchop/takeover.go` MUST land in the same commit as — and BEFORE — the A.4 restore-from-manifest enablement in `restore_deps_csf.go`. A.4 must remain skip/refuse-only on hosts where the manifest is absent (existing pre-PR-26 installs). The two changes are co-required: enabling A.4 restore without the manifest writer would break on the first run; writing the manifest without consuming it would leave dead state on disk. |
| **PR-26-code-D** | Post-restore evidence-record file (§39.3) + new CI gates | `cmd/nftban-installer/restore_evidence.go` (new), CI workflow |
| **PR-26-code-E** | Destructive staged DirectAdmin soak — evidence-only commit pointing at the private path | (no source change beyond a CHANGELOG / commit-message pointer) |
| **PR-26-final** | CHANGELOG + release prep | `CHANGELOG.md` |

Auditor passes between every major slice, mirroring the 4B-1 / 4B-2 / 4B-3-pre / 4B-3-csf / 4B-4 / 5 cadence.

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

- **2026-04-27 v2 (PR-25 contract append)** — appends Part II (§§16–29: PR-25 execution contract). Faithful normalization of the locked Q1–Q5 design decisions (recorded 2026-04-20 during PR-24 freeze Day 0) following the locked "no expansion beyond Q1–Q5" rule. Sections §1–§15 are untouched. Verified live-code anchors at `internal/installer/uninstall/prior.go:278-284` (knownFirewallType set), `cmd/nftban-installer/main.go:132` (writeHistory gate), `internal/installer/state/machine.go:149-155` (existing exit-code constants). Doc-only commit; no code changes in this PR. Code phase opens in a separate PR after this one merges.

- **2026-04-28 v3 (Amendment 1: CSF restore mutation authorization)** — appends Part III (§§30–36). Authority gap discovered during PR-25 commit 4B-3 inspection: install-time `switchop.DisableConflicts` performs persistent, file-level mutations (service mask, binary rename, cron removal) that cannot be reversed under the §§17–29 forbidden-behaviors list. This amendment authorizes a narrow set of CSF-specific inverse-of-install mutations (A.1–A.7) gated on prior-record / on-disk evidence, with extended §23 ordering (11 steps), evidence-precondition table, failure-mode safety-net retention table, CSF-specific forbidden behaviors, unit + integration test requirements, and §28 real-host evidence requirements (lab2 DEB / lab4 RPM, exec-trace clean of out-of-target processes). Amendment is **CSF-only**; ufw / firewalld / iptables remain typed-unsupported until separately amended. Sections §§16–29 are untouched. `main.go:132` writeHistory gate (§19.2 layer 4) untouched. Doc-only commit; no production code changes — 4B-3-csf code phase opens after this amendment is reviewed and merged.

- **2026-04-28 v4 (PR-26 contract seed: restore verification / evidence hardening)** — appends Part IV (§§37–48). PR-25 (#511, merged `6a0ab67a`) shipped restore execution under Amendment 1 with three known correctness gaps: (1) the safety-net-safe predicate accepts ANY active external firewall as evidence of SSH protection, not the resolved target's specific unit; (2) A.4 cron restore is soft-skip because `switchop.disarmCSFArtifacts` does not preserve `/etc/cron.d/csf-cron` and `/etc/cron.d/lfd-cron` before removal; (3) restore mutation routes through `Run("systemctl","unmask",…)` and `Run("mv",…)` because the `executor.Executor` interface lacks typed `ServiceUnmask` and `Rename` methods, weakening the per-call CI trace. PR-26 closes those gaps and adds post-restore evidence hardening — a structured proof that the restore outcome is correct on real systems. Part IV is normative for PR-26 only and does NOT modify §§1–36. **Doc-only commit; no production code changes.** Code phase opens in segmented commits after this seed is reviewed and merged.
