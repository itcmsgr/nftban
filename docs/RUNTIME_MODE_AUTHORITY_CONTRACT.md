# NFTBan Runtime Mode Authority and Evidence Standard (v1.228)

A standing contributor and auditor contract. This is not a forensic report and does not
expire with a release.

## What a feature is

A feature is not merely code that exists. **A feature is a complete production path that is
reachable, observable, enforceable, testable and recoverable.**

For NFTBan that means all five, not a subset:

| Property | Requirement |
|---|---|
| **REACHABLE** | the shipped runtime actually calls it |
| **OBSERVABLE** | logs, health and status expose its real state |
| **ENFORCEABLE** | detection reaches the authoritative ban/firewall path |
| **TESTABLE** | positive, negative **and mutation** fixtures prove it |
| **RECOVERABLE** | disable, unban, restart, rebuild and reboot behave correctly |

Code that satisfies four of the five is not an **admitted** feature. Without these gates, it risks
being reported as working despite an incomplete production path.

## The invariant

```
NO CONFIGURED MODE MAY BE REPORTED ACTIVE
UNLESS ITS EFFECTIVE RUNTIME CHAIN IS PROVEN:

configuration → resolution → dispatcher → detector
              → decision → enforcement → health → recovery
```

## The compact standing rule

This is the canonical short form. Quote it verbatim; do not paraphrase it.

```
DEFINED         ≠  REACHABLE
CONFIGURED      ≠  EFFECTIVE
ENABLED         ≠  DETECTING
RUNNING         ≠  RECEIVING INPUT
DETECTED        ≠  ENFORCED
SET MEMBERSHIP  ≠  FIREWALL BLOCK
PASS            ≠  INJECTION PROVEN
```

**Every one of these has been observed in this product.** They are not hypothetical:
a defined-but-uncalled Suricata processor; `auto` resolving to a mode whose source is absent;
a module RUNNING with its only watcher exited; a ban present in a set that no hooked chain
referenced; and harness cases that printed PASS while asserting nothing.

## Scope

This governs **DDoS, PortScan, LoginMon, Suricata, BotScan, ban/unban, package lifecycle, health,
reporting — and every future module.** It is not limited to the modules that happened to surface
the defects.

## Position in architecture

| Layer | Role | Authority |
|-------|------|-----------|
| Configuration | Operator intent | Declares, never proves |
| Resolver | Intent → effective mode | Must record both, and the reason |
| Dispatcher | Effective mode → entrypoint | Missing entrypoint is a FAILURE, never a no-op |
| Detector | Event production | Requires a readable, producing source |
| Ban authority | Decision | Exactly one per event |
| Kernel (nftables) | Enforcement | Source of truth |
| Health | Interpretation of the **selected** path | Must be able to report failure |

---

## Lessons

These are stated as rules because each was learned from a real defect.

### Lesson A — Presence is not readiness

**Wrong:** `binary exists + service active = available`.

**Required readiness**, all of:

- binary exists
- service active
- required source exists
- source readable **by the actual consumer identity**
- source producing the **required event class**
- cursor/watcher advancing
- parser accepts current schema

> Observed: `checkSuricataAvailable()` scores binary(+1), `systemctl is-active`(+1), fresh EVE(+1)
> and returns `score >= 2`. Binary plus service therefore selects Suricata **with no EVE file at
> all**. Presence scored as readiness.

### Lesson B — Started is not running

**Wrong:** goroutine launched → module `RUNNING`.

**Required:** worker started **and** still alive **and** source attached **and** input authority
proven **and** progress/heartbeat observed. A worker that exits immediately must not leave module
status at `RUNNING`.

> Observed: `runEVEWatcher` fails to open EVE, calls `RecordError`, and `return`s — the goroutine
> exits with no retry and no fallback, while `MarkRunning()` had already been set. The module
> reported running with zero detection.

### Lesson C — Function existence is not runtime reachability

**Wrong:** function defined and `export -f`'d → feature implemented.

**Required:** production caller → selected dispatcher branch → invocation → observable output.

> Observed: `nftban_ddos_suricata_process` exists, is exported, and has **zero external callers**.
> `DDOS_MODE=suricata` names a mode whose processor never runs.

### Lesson D — Configured mode and effective mode are different authorities

Always record **both**, plus the reason:

```
CONFIGURED_MODE=auto
EFFECTIVE_MODE=classic
MODE_REASON=suricata_source_not_ready
```

Never overwrite operator intent with the resolved value without preserving both. A status surface
that shows only one of them cannot be audited.

### Lesson E — Health must test the *selected* path

Health may not merely assert process active / service active / config says enabled. It must test
the path the effective mode selected:

| Effective mode | Health must prove |
|---|---|
| `classic` | native/kernel detector path alive |
| `suricata` | EVE source readable **and consumer progressing** |
| `hybrid` | both paths progressing **and** deduplicating |
| `auto` | resolver result recorded **and** selected path healthy |

Health states must distinguish:
`ACTIVE_AND_RECEIVING` · `ACTIVE_ZERO_INPUT` · `SOURCE_MISSING` · `SOURCE_UNREADABLE` ·
`PARSER_REJECTING` · `CURSOR_STALLED`.

### Lesson F — Hybrid is a separate architecture

Hybrid is not "classic plus Suricata" behind a checkbox. It requires a canonical event identity,
one deduplication authority, one ban authority, one expiry decision, one notification, and
independent health for each input.

Without proven deduplication, two valid detectors produce duplicate events, duplicate bans,
competing expiry values, conflicting severity, double notifications and inconsistent counters.
**Until dedup is proven, hybrid is unsupported or experimental — never "supported".**

### Lesson G — Silent no-op is failure

This pattern is prohibited as a success path:

```bash
type -t some_function >/dev/null && some_function     # missing fn ⇒ rc0, nothing ran
```

**Required:** selected-mode entrypoint missing ⇒ `DEGRADED` or `FAILED`, with an explicit
machine-readable reason and a non-success operation result.

```
SELECTED MODE + MISSING ENTRYPOINT = FAILED/DEGRADED     never rc0/no-op
```

### Lesson H — Tests must prove their injection

A test does not count because its assertions passed. Every critical test must establish:

```
PRECONDITION → INJECTION_APPLIED → EXPECTED_PATH_EXECUTED
             → OBSERVATION → NEGATIVE_CONTROL_FAILED → CLEANUP_COMPLETE
```

If the injection did not take, the case is `NOT_YET_VERIFIED` — never `PASS`, and never
`FAIL_PRODUCT` (which would misattribute a harness gap to the product). This applies equally to
product code and to lifecycle/attack harnesses.

---

## Required resolution — the ten fields

Before any claim or mutation involving DDoS, PortScan, LoginMon, BotScan, Suricata,
enable/disable, detection, banning, health or status, resolve all ten:

| # | Field | Must name |
|---|-------|-----------|
| 1 | MODULE | ddos · portscan · loginmon · other |
| 2 | CONFIGURED MODE | auto · classic · suricata · hybrid |
| 3 | EFFECTIVE MODE | the mode actually selected after dependency/config resolution |
| 4 | RUNTIME ENTRYPOINT | exact service/timer/Go scheduler/shell dispatcher/kernel rule |
| 5 | DETECTION AUTHORITY | kernel nftables · shell detector · EVE consumer · Go publisher |
| 6 | BAN AUTHORITY | exact function/process that requests or performs the ban |
| 7 | ENFORCEMENT AUTHORITY | set → referencing rule → **reachable hooked chain** → drop/reject |
| 8 | HEALTH AUTHORITY | the consumer proving the **selected** mode is active |
| 9 | LOG AUTHORITY | source log/event stream **and the runtime identity consuming it** |
| 10 | TEST EVIDENCE | static reachability + committed fixture + real cross-VM traffic |

**Never infer that a configured mode is operational because:** status prints its name · a function
exists · a function is exported · a Go module starts · enable returns rc0 · a source file is
installed · Suricata is installed · a detector prints a message.

---

## Mode admission ledger

Each module × mode carries exactly one status. A mode may appear in user-facing help only with an
explicit status of `supported`, `experimental`, `unavailable` or `broken`.

| Status | Meaning |
|---|---|
| `DECLARED` | The mode name exists in config/help |
| `STATICALLY_REACHABLE` | Resolver → dispatcher → entrypoint traced in code |
| `FIXTURE_PROVEN` | Committed positive **and** negative fixture pass |
| `TRAFFIC_PROVEN` | Real cross-VM traffic, enforcement proven, clean recovery |
| `SUSTAINED` | Traffic-proven across restart/rebuild/reboot/upgrade |
| `BROKEN` | Named but not reachable, or reachable but not truthful |
| `DEMOTED` | Previously admitted, now failing — must be hidden or marked unavailable |

Promotion requires **all** of: static reachability, a committed positive fixture, a committed
negative fixture, real cross-VM traffic, enforcement proof, and clean recovery. The traffic test
must enter through the **shipped production lifecycle** — never by calling a private helper
directly. A synthetic direct call proves the function works; it proves nothing about the product.

Current ledger: see [`MODE_ADMISSION_LEDGER.md`](MODE_ADMISSION_LEDGER.md).

---

## Machine-readable mode declaration

Supported modes must be **inventoried, not inferred from scattered code**. Each module declares:

```yaml
module: loginmon
configured_modes: [auto, classic, suricata, hybrid]
modes:
  classic:
    dispatcher: internal/loginmon.Module.Start
    detector: journal_watcher
    required_sources: [systemd-journal]
    health: [watcher_alive, source_attached, progress_observed]
  suricata:
    dispatcher: internal/loginmon.Module.Start
    detector: eve_watcher
    required_sources: [suricata-service, eve-json, required-event-classes]
    fallback: classic
    health: [watcher_alive, eve_readable, cursor_advancing]
  hybrid:
    detectors: [journal_watcher, eve_watcher]
    dedup_authority: REQUIRED
```

Format may be YAML, Go metadata or a registry. The principle is fixed:

> The machine-readable declaration is the canonical **mode inventory and specification authority**.
> It is **not runtime truth**. Runtime enforcement authority remains the **kernel**, and runtime
> health interpretation remains the **validator**. CI checks implementation and documentation
> against the declaration.

This preserves the established hierarchy — kernel enforces, validator interprets, CLI renders,
config records intent — and deliberately does not create a second runtime truth source or compete
with `ModuleHealthMap`.

---

## CI guards

Static guards cannot prove runtime operation. They exist to stop architectural drift:

- every documented mode has a resolver branch
- every resolver output has a dispatcher branch
- every dispatcher branch references an existing entrypoint
- a missing selected entrypoint cannot return success
- every `MarkRunning()` has a worker-liveness/error transition
- every Suricata mode declares source-readiness checks
- every hybrid mode declares a deduplication authority
- help/status cannot advertise a mode marked `BROKEN`

## Mutation fixtures

Guards are only trustworthy if they have been seen to fail. Each of these must flip its guard red:

| Mutation | Guard that must fail |
|---|---|
| remove the DDoS Suricata caller | reachability test |
| remove a PortScan mode function | selected-mode test returns FAILED, not rc0 |
| make the EVE path absent | LoginMon must not report healthy Suricata |
| stop the EVE watcher after startup | status must leave RUNNING |
| send duplicate journal + EVE events | hybrid must produce exactly one decision |
| change auto readiness to presence-only | readiness fixture |

---

## Threshold retuning

Retuning is **prohibited** until reachability and ownership are proven for the mode being tuned.

Thresholds are not numerically comparable across modes, because the observation models differ:

- kernel meter observes packets/connections directly
- Suricata observes classified events after capture, decode, rule evaluation and EVE output
- shell polling adds interval and batching behaviour

```
same config number  ≠  same effective sensitivity
```

Retuning must therefore produce per-mode defaults or an explicit normalization model — never one
number reused across modes.

---

## STOP-ON-MODE-AMBIGUITY

Stop and report **before mutation** when any of these is unknown:

configured mode · effective mode · runtime dispatcher · selected function exists but caller
unproven · selected mode silently no-ops · classic/Suricata ownership overlap · hybrid dedup
unproven · auto resolution not reproducible · health disagrees with observed traffic behaviour ·
Suricata presence changes another module's inputs · a test enters through a private helper rather
than the shipped entrypoint.

**Do not repair, retune, or declare support until the ambiguity is resolved.**

---

## Related

- [`EVIDENCE_CONTRACT.md`](EVIDENCE_CONTRACT.md) — evidence has no authority over status
- [`CONTRACT_RULES.md`](CONTRACT_RULES.md)
- [`adr/ADR-0001-runtime-mode-authority.md`](adr/ADR-0001-runtime-mode-authority.md)
- [`MODE_ADMISSION_LEDGER.md`](MODE_ADMISSION_LEDGER.md)
