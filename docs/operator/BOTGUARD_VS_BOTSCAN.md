# HTTP Guard (BotGuard) vs HTTP Exploit Scanner (BotScan)

*Versioned contract — as of v1.219.0.*

NFTBan has **two independent HTTP protection subsystems.** They are not the same component, and one does not control the other.

| | **HTTP Guard = BotGuard** | **HTTP Exploit Scanner = BotScan** |
|---|---|---|
| What it is | Live, request-time HTTP bot guard | Periodic access-log exploit scanner |
| Trigger | Real-time request evaluation | `nftban-botscan.timer` (default every 10 min) |
| Config flag | `HTTP_BOTGUARD_ENABLED` | `BOTSCAN_ENABLED` |
| Patterns | crawler allow/deny lists | shipped: `/usr/lib/nftban/data/botscan_*.patterns`; yours: `/etc/nftban/patterns.d/botscan/` (`override.local`, own `*.patterns`) — as of v1.234.0 |
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

## BotScan behind a CDN or reverse proxy (as of v1.234.0)

BotScan reads the client address from the first field of each access-log line. Behind a
CDN (for example Cloudflare), that field holds the **CDN edge** unless the web server
restores the visitor address (nginx `real_ip_header` / `set_real_ip_from`, Apache
`mod_remoteip`, LiteSpeed "use client IP in header" with trusted proxies).

- **An edge address is never banned by BotScan.** Every BotScan ban (pattern rules, 404
  flood, endpoint flood) is checked against the published CDN edge ranges that ship with
  the package (`/usr/lib/nftban/data/botscan_shared_edges.tsv`; Cloudflare as of
  v1.234.0, including the Workers egress ranges), plus a newer copy fetched by
  `nftban trust` when one is cached. A skipped ban is logged in `botscan.log` as
  `SKIPPED_SHARED_EDGE` with the reason, the cycle prints one `BOTSCAN_SHARED_EDGE` line,
  and `nftban botscan status` shows the count. This is not a firewall whitelist: nothing
  is accepted on any port, and other detectors are unaffected.
- **Detection is not a block behind a CDN.** When BotScan sees an edge address, the real
  scanner is behind it and NFTBan cannot ban it at the firewall. When the web server does
  restore the visitor address, a ban of that address still does not stop requests that
  arrive through the CDN, because those connections come from the edge. A BotScan ban
  blocks only direct-to-origin traffic from that address.
- **The fix is in the web server:** restore the real client IP (trusting the header only
  from the CDN's published ranges), and optionally restrict the origin to the CDN's ranges.
- The edge ranges are refreshed with each NFTBan release. A range a CDN adds between
  releases is covered only once `nftban trust` has fetched a newer list, or after the next
  release.

## If BotScan false-bans a legitimate visitor

See [`FALSE_POSITIVE_AND_RECOVERY_DRILL.md`](FALSE_POSITIVE_AND_RECOVERY_DRILL.md).
