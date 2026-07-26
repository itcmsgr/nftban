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

A `BROKEN` mode must be hidden from help, rejected at config validation, or explicitly marked
`unavailable` in status. It must never be silently selectable.
