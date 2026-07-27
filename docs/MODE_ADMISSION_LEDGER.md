# NFTBan Mode Admission Ledger

Authority: [`RUNTIME_MODE_AUTHORITY_CONTRACT.md`](RUNTIME_MODE_AUTHORITY_CONTRACT.md).

One row per module × configured mode. A mode may appear in user-facing help only with an explicit
status. **`DECLARED` alone never justifies advertising a mode as available.**

Statuses: `DECLARED` → `STATICALLY_REACHABLE` → `FIXTURE_PROVEN` → `TRAFFIC_PROVEN` → `SUSTAINED`,
plus `BROKEN` and `DEMOTED`.

## Current state — v1.228.0

Evidence basis: direct source trace 2026-07-26, plus a live ruleset capture on a v1.228.0 target.
Every row cites what was actually checked. Rows without traffic evidence are **not** promoted.

| Module | Mode | Status | Evidence / blocker |
|---|---|---|---|
| DDoS | classic | `STATICALLY_REACHABLE` (partial traffic) | Enforcement is in-kernel: `syn_meter_v4` rate-limit observed live in the hooked `input` chain. No bounded-traffic fixture yet. |
| DDoS | suricata | **`BROKEN`** | `nftban_ddos_suricata_process` has **zero external callers** (definition + one internal call + `export -f`). No mode dispatcher exists for DDoS at all. The mode name resolves to nothing. |
| DDoS | hybrid | `DECLARED` | No dispatcher exists; dedup authority undefined. |
| DDoS | auto | `DECLARED` | Resolver `internal/ddos/module.go` not yet traced end to end. |
| PortScan | classic | `STATICALLY_REACHABLE` | `nftban_portscan_run` → `nftban_portscan_classic_run` (`nftban_portscan_classic.sh`). Gated on `PORTSCAN_ENABLED`. No traffic fixture yet. |
| PortScan | suricata | `STATICALLY_REACHABLE` | `nftban_portscan_run` → `nftban_portscan_suricata_run` (`nftban_portscan_suricata.sh`). Source readiness unproven. |
| PortScan | hybrid | `DECLARED` | Both branches invoked; **dedup authority unproven** — cannot be promoted (Lesson F). |
| PortScan | auto | `DECLARED` | Resolver not traced end to end. |
| LoginMon | classic | `STATICALLY_REACHABLE` | `Start()` → `runJournalWatcher`. |
| LoginMon | suricata | **`BROKEN` when source missing** | Selected on presence (score ≥ 2 = binary + service, **no EVE required**); `Start()` then runs **only** the EVE watcher. `runEVEWatcher` exits on open failure while status stays `RUNNING` (Lessons A + B). |
| LoginMon | hybrid | `DECLARED` | Both watchers started; dedup authority unproven. |
| LoginMon | auto | **`BROKEN` readiness resolution** | `auto` + Suricata present ⇒ `ModeSuricata` on presence alone, silently darkening journal sources. Fail-safe direction is correct (configured `suricata` + unavailable ⇒ falls back to `classic`). |

### Not in this table

BotScan, BotGuard, GeoBan, RBL and Watchdog have not been mode-resolved. Absence from this ledger
means **unassessed**, not healthy.

## Promotion requirements

A row moves to `TRAFFIC_PROVEN` only with **all** of:

1. static reachability traced (resolver → dispatcher → entrypoint)
2. committed positive fixture
3. committed negative fixture (proves the check can fail)
4. real cross-VM traffic from a dedicated attacker host
5. enforcement proven: set → referencing rule → **hooked** chain → observed block
6. clean recovery (expiry/unban restores access)

The traffic test must enter through the shipped production lifecycle. **A synthetic direct call to
a private helper does not promote a row** — it proves the function runs, not that the product
reaches it.

## Standing rule for `BROKEN`

A `BROKEN` mode **must be rejected at configuration validation or explicitly marked
`unavailable`**. It must not be selectable as an operational mode. Hiding it from help alone is
insufficient — an existing configuration file would keep selecting it silently.

## OPEN runtime-lane defect — validation is not module × mode aware

**Status: confirmed, not fixed in v1.228.0.** Flagged by the static guard.

`cli/lib/nftban/helpers/nftban_mode.sh:32` declares a single global vocabulary:

```
NFTBAN_VALID_MODES="auto classic suricata hybrid"
```

This is the configuration-validation accept-list. It accepts modes this ledger marks `BROKEN`, so
the validator still admits a mode that must not be operationally selectable.

**This is a runtime-lane product defect, not a documentation defect.** The interim behaviour must
be chosen explicitly:

| Option | Behaviour |
|---|---|
| **A** | reject specifically `BROKEN` module × mode combinations |
| **B** | accept syntax, fail semantic validation as unavailable |
| **C** | preserve parsing compatibility, refuse activation, and report `CONFIGURED_MODE=<value>` / `EFFECTIVE_MODE=unavailable` / `MODE_REASON=<stable reason>` |

**Constraint:** do **not** remove `suricata` or `hybrid` globally from the shared vocabulary.
PortScan and LoginMon do not share an admission state with DDoS — PortScan/suricata is
`STATICALLY_REACHABLE` while DDoS/suricata is `BROKEN`. Validation must be **module × mode aware**,
not a global four-word allowlist.

Until this is resolved, the guard reports these rows as `MUST_FIX` / `BLOCKED_FROM_ADMISSION`.
