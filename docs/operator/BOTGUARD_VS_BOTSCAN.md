# HTTP Guard (BotGuard) vs HTTP Exploit Scanner (BotScan)

*Versioned contract — as of v1.219.0.*

NFTBan has **two independent HTTP protection subsystems.** They are not the same component, and one does not control the other.

| | **HTTP Guard = BotGuard** | **HTTP Exploit Scanner = BotScan** |
|---|---|---|
| What it is | Live, request-time HTTP bot guard | Periodic access-log exploit scanner |
| Trigger | Real-time request evaluation | `nftban-botscan.timer` (default every 10 min) |
| Config flag | `HTTP_BOTGUARD_ENABLED` | `BOTSCAN_ENABLED` |
| Patterns | crawler allow/deny lists | `patterns.d/botscan/*.patterns` |
| Enforces via | `http_bot_ban` / `http_bot_suspect` sets | `blacklist_manual_ipv4` / `blacklist_manual_ipv6` |
| Fleet default | **disabled** | **enabled** (`action=both`) |

## The one rule to remember

> **BotGuard disabled does NOT mean BotScan disabled.** They are independent.

BotScan can — and by default does — enforce bans through `blacklist_manual_*` even when BotGuard is off. Its ban path (the daemon batch-signal consumer) was ungated from `HTTP_BOTGUARD_ENABLED` in v1.209. So an operator who sees `Bot Guard: DISABLED` in `nftban status` must **not** conclude that HTTP exploit banning is off — check the **HTTP Exploit Scan (BotScan)** row too.

## Action modes (BotScan)

- `alert` — **detect-only**, does not ban.
- `ban` / `both` — **enforce** (write bans to `blacklist_manual_*`). In the current code `ban` and `both` are equivalent enforcement.

## Where to look

- `nftban status` — shows **HTTP Guard** and **HTTP Exploit Scan** rows independently, with last-scan/health for BotScan.
- `nftban botscan status` — heads *"HTTP Exploit Scanner (BotScan) Status"* with enabled/timer/action/patterns.
- `nftban health` — has a dedicated *HTTP Exploit Scanner (BotScan)* block (cheap-read; it never scans access-log content synchronously).
- `nftban search <ip>` — top-level `BANNED` is **kernel-authoritative** (reads nft sets). A BotGuard decision-cache hit renders as *"CACHE ONLY — not currently enforced"* and never flips the top-level verdict.

## Suricata is optional, not required

BotScan is NFTBan's **native, lightweight web-exploit detector** for the URL/path/query class (e.g. `/.env`, `/.git/config`, `revslider_show_image`, RFI probes). **Suricata is an optional deep IDS** (payload/TLS/protocol) — it is not required for ordinary HTTP exploit-path scanning, and its absence does not degrade BotScan.

## If BotScan false-bans a legitimate visitor

See [`FALSE_POSITIVE_AND_RECOVERY_DRILL.md`](FALSE_POSITIVE_AND_RECOVERY_DRILL.md).
