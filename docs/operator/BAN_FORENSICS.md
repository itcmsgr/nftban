# Ban forensics

**Last verified: v1.218.5.**

This page explains how to answer, after the fact, the questions an operator asks about a ban: *is this
IP actually banned right now, which module banned it, when, why, and in which nftables set?* It covers
the on-disk log, the query commands, and the kernel-verification commands that prove enforcement.

## Prerequisites

- Root or `nftban` group membership (to read `/var/log/nftban/` and run `nft list set`).
- NFTBan installed from an official package (FHS layout).

## 1. The ban log

Ban and unban events are written to **`/var/log/nftban/bans.log`**.

The daemon writes pipe-delimited records with up to ten fields:

```
DATE|TIME|SOURCE|IP|COUNTRY|STATUS|REASON|BAN_ID|TIMEOUT|CLASS
```

| Field | Meaning |
|-------|---------|
| `SOURCE` | which subsystem banned the IP: `manual`, `login`, `portscan`, `ddos`, `feeds`, `suricata` |
| `STATUS` | `BANNED`, `UNBANNED`, or `RESYNC` (RESYNC = an idempotent re-push of an existing ban, not a new event) |
| `REASON` | free text; `|` and newlines are sanitized out |
| `BAN_ID` | links a `BANNED` record to its later `UNBANNED` record (present since v1.41.0; empty before) |
| `TIMEOUT` | kernel timeout for the ban |
| `CLASS` | `temp` (kernel TTL, default 15m), `escalated`, `permanent`, `manual`, or `resync` |

Unban events are recorded in the same file with `STATUS=UNBANNED`. There is no separate `unbans.log`
— a path by that name is referenced in the code but has no writer, so do not look for it.

Example queries:

```bash
grep '|login|'   /var/log/nftban/bans.log        # everything the login module banned
grep '203.0.113.5' /var/log/nftban/bans.log      # full history for one IP (BAN + UNBAN share a BAN_ID)
awk -F'|' '$6=="BANNED"{print $3}' /var/log/nftban/bans.log | sort | uniq -c   # bans per source
```

## 2. Ask the CLI which set an IP is in

```bash
nftban search <ip>            # or a port; --json for machine output, --no-interactive to skip prompts
```

`search` reads the kernel sets in order — `whitelist_<family>`, `blacklist_manual_<family>`,
`blacklist_<family>` — does CIDR-containment matching, and reports which set the address falls in
(it relabels `blacklist_manual` as "blacklist (manual)"). It is read-only and never changes state.

```bash
nftban list banned            # enumerate banned IPs (manual + feed/geoban sets); also: whitelist | all
nftban list banned --json
nftban blacklist list         # both feed/geoban and manual entries; blacklist show for detail
nftban status                 # "Banned IPs" = kernel blacklist_ipv4 + blacklist_manual_ipv4 (+ v6)
```

## 3. Which set means which origin

The nftables set an IP sits in already tells you how it was banned:

| Set | Holds | Structure |
|-----|-------|-----------|
| `whitelist_ipv4` / `whitelist_ipv6` | trusted IPs; bypass all checks | — |
| `blacklist_manual_ipv4` / `blacklist_manual_ipv6` | manual bans **and** auto-detect bans (login, portscan, ddos) | hash (single IP) |
| `blacklist_ipv4` / `blacklist_ipv6` | feed and geoban bans | interval / CIDR-aggregated |

So the set distinguishes *manual/auto* (`blacklist_manual_*`) from *feed/geoban* (`blacklist_*`). To
pin down the **exact module** behind a manual/auto ban, read the `SOURCE` field in `bans.log`
(`login` / `portscan` / `ddos` / `manual` / `feeds` / `suricata`). Emergency direct bans (see
[Emergency recovery](EMERGENCY_RECOVERY_AND_ROLLBACK.md)) land in the unified `blacklist_ipv4` /
`blacklist_ipv6` set.

## 4. Daemon events

For the runtime story of a ban/unban (decision, IPC, errors), read the daemon journal:

```bash
journalctl -u nftband --since "1 hour ago"
```

## 5. Kernel truth — prove the ban is enforced

The CLI summaries above are a report layer. The firewall state that actually drops traffic lives in
the kernel. Confirm it directly:

```bash
nft list set ip  nftban blacklist_ipv4
nft list set ip  nftban blacklist_manual_ipv4
nft list set ip6 nftban blacklist_ipv6
nft list set ip6 nftban blacklist_manual_ipv6
nft list tables                              # the nftban tables must be present
```

If an IP appears in `bans.log` and in `nftban status` but is **not** in the corresponding kernel set,
the ban is not being enforced — investigate the daemon (`journalctl -u nftband`) and reconcile with
`nftban blacklist reconcile`.

## 6. Ban counts (metrics)

Aggregate ban counts are cached in the unified stats file at
`/var/cache/nftban/metrics/stats.json`; the running total is at `.activity.total_bans`:

```bash
jq .activity.total_bans /var/cache/nftban/metrics/stats.json
```

See [Metrics truth](METRICS_TRUTH.md) for what the metrics layer does and does not guarantee.

## Failure modes and caveats

- **The log is history; the kernel is state.** An entry in `bans.log` records that an event happened,
  not that the IP is still banned now. Use `nft list set` for the current state.
- **RESYNC is not a new ban.** Filter it out when counting distinct ban events.
- **`RBL` never appears as a ban `SOURCE`.** RBL is DNSBL advisory monitoring (disabled by default);
  it reports reputation and can send alerts, but it does not write nftables sets or ban anything.

## References

- Ban log writer and format: `internal/banlog/banlog.go`; shell mirror `core/nftban_login_alert.sh`
- Query commands: `cli/lib/nftban/cli/cmd_search.sh`, `cmd_list.sh`, `cmd_blacklist.sh`, `cmd_status.sh`
- Set definitions: `install/nftables/nftables.conf.tpl`
- Stats cache: `cli/lib/nftban/core/nftban_stats.sh`, `nftban_stats_collect.sh`
- Related: [Emergency recovery](EMERGENCY_RECOVERY_AND_ROLLBACK.md), [Metrics truth](METRICS_TRUTH.md)
