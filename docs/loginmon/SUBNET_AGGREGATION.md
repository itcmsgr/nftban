# LoginMon Subnet Aggregation (v1.113)

> Closes **`D-LOGINMON-EXIM-SUBNET-ROTATION-GAP`** from the srv1 production incident on 2026-05-13: a distributed `81.30.98.0/24` SMTP brute force where each individual IP made only 1-2 attempts and never crossed the per-IP ban threshold.

## What it does

The LoginMon `Scorer` now tracks aggregate event counts per `/24` (IPv4) or `/64` (IPv6) subnet in addition to per-IP scores. When a configurable number of distinct IPs from the same subnet generate enough `EXIM_AUTH_FAIL` events within a rolling window, the feature can either emit an observe-only pressure event or ban the entire CIDR.

The per-IP scoring path is unchanged. Subnet aggregation runs in parallel and triggers only when the per-IP path would miss the attack (because each IP's score stays below threshold).

## Opt-in, observe-first

The feature is **disabled by default**. To enable, set in `/etc/nftban/conf.d/login/scorer.conf` (or any included config file):

```sh
LOGINMON_EXIM_SUBNET_AGG_ENABLED=true
LOGINMON_EXIM_SUBNET_AGG_MODE=observe       # observe | enforce
```

Operators are encouraged to begin in `observe` mode for at least one full attack cycle. Pressure-event counts are visible via `nftban status` → `subnet_pressure_count` and via the JSON status surface. Once the operator is confident the false-positive rate is acceptable, switch to `enforce`.

## Configuration reference

| Env key | Type | Default | Description |
|---|---|---|---|
| `LOGINMON_EXIM_SUBNET_AGG_ENABLED` | bool | `false` | Master toggle. Must be explicitly set to `true`. |
| `LOGINMON_EXIM_SUBNET_AGG_MODE` | string | `observe` | `observe` (count + log) or `enforce` (ban CIDR). |
| `LOGINMON_EXIM_SUBNET_WINDOW` | duration | `5m` | Rolling-window duration. Events older than this expire and re-arm the trigger. |
| `LOGINMON_EXIM_SUBNET_UNIQUE_IPS` | int | `5` | Minimum number of distinct IPs in window required to trigger. |
| `LOGINMON_EXIM_SUBNET_MIN_TOTAL_EVENTS` | int | `10` | Minimum total events in window required to trigger. Both this AND unique-IPs threshold must be met. |
| `LOGINMON_EXIM_SUBNET_IPV4_PREFIX` | int | `24` | Aggregation prefix bits for IPv4. `/24` covers a typical hosting-provider rotation block. |
| `LOGINMON_EXIM_SUBNET_IPV6_PREFIX` | int | `64` | Aggregation prefix bits for IPv6. `/64` is a single end-user allocation. |
| `LOGINMON_EXIM_SUBNET_ACTION` | string | `ban_cidr` | Action on trigger. Only `ban_cidr` ships in v1.113. `pressure_score` and `dynamic_threshold` labels are reserved for v1.114+. |
| `LOGINMON_EXIM_SUBNET_CIDR_BAN_DURATION` | duration | `24h` | Duration for subnet bans. `0` = permanent. |

## False-positive guards

Six guards must ALL pass before a trigger fires:

1. **Reason filter** — only `EXIM_AUTH_FAIL` events count toward subnet aggregation. Other LoginMon reasons (SSH, FTP, panel logins) are not aggregated by subnet in v1.113.
2. **Dual threshold** — both the unique-IP count AND the total-event count must cross their respective thresholds.
3. **Rolling window** — events older than `SubnetWindow` are excluded from the count. When the window expires for a subnet, the state resets.
4. **Trusted-provider allowlist** — subnets contained in the operator-curated trusted list are exempt. Use this to whitelist Google, Microsoft, Apple, and other large mail-relay networks.
5. **Private/internal ranges blocked** — RFC 1918, RFC 4193, link-local, and loopback ranges are never aggregated.
6. **Audit logging** — every trigger writes a structured journal entry attributing the subnet, unique-IP count, total event count, sample IPs, and the action taken.

## What gets banned

When `MODE=enforce` and all guards pass, LoginMon publishes a `EventBan` event with `WithIP(<prefix>)` set to the CIDR (e.g., `81.30.98.0/24`). The downstream ban executor accepts CIDR strings via the same path as the canonical `nftban ban <CIDR>` CLI. The ban is recorded in `/etc/nftban/blacklist.d/99-manual.conf` with reason `exim_auth_fail_subnet`.

The triggering IP (the IP whose event tripped the threshold) is preserved in the event data field `trigger_ip` for audit attribution.

## Observability

Three new fields appear in the JSON output of `nftban status --json` under `extra`:

```json
{
  "extra": {
    ...
    "subnet_pressure_count": 7,
    "subnet_bans_total": 1,
    "subnet_watch_active": 3
  }
}
```

When the feature is disabled or no subnet events have been observed, these fields are omitted (zero values are not emitted) to keep the wire format byte-identical to v1.112.x.

## What it does NOT do (yet)

- **No Prometheus emission in v1.113.** Schema 1.83.0 is frozen; Prometheus metric names for subnet aggregation are deferred to v1.114 with an explicit schema-unfreeze gate if needed.
- **No `pressure_score` action.** This reserved label would boost the per-IP score for all IPs in the offending subnet instead of banning the CIDR. Implementation reserved for v1.114+.
- **No `dynamic_threshold` action.** This reserved label would temporarily lower the per-IP ban threshold for the offending subnet. Implementation reserved for v1.114+.
- **No cross-module integration with BotGuard or DDoS modules.** Subnet aggregation is currently LoginMon-only.
- **No persistent state.** The subnet map is in-memory only; restarts reset state. The 5-minute window granularity makes persistence unnecessary.

## Performance characteristics

- Subnet map sits alongside the per-IP map under the same `Scorer.mu` write-lock. Hot-path overhead per `RecordVerdict` call is a few map ops (one for `getOrCreateSubnetState`, one to record the event into `UniqueIPs`, one for the cap check).
- `MaxTracked` caps the subnet map at 10,000 prefixes by default. New prefixes are declined when the cap is reached (no LRU eviction in v1.113; reserved for v1.114 if pressure justifies it).
- Memory bound per tracked subnet: one `SubnetState` (~80 bytes fixed) plus `UniqueIPs` map (~16 bytes per IP). At the default `MIN_TOTAL_EVENTS=10` threshold, a fully-loaded subnet entry holds at most a few dozen IPs typically; worst case ~1 KB per subnet × 10,000 cap = ~10 MB.

## Verification / acceptance

After enabling on a host with active attack traffic, expect:

1. `nftban status --json | jq '.extra.subnet_pressure_count'` increases on each subnet-trigger event (observe mode) or each subnet-ban-fire event (enforce mode).
2. `journalctl -u nftband.service | grep subnet_prefix` shows the trigger events.
3. In enforce mode, `nft list set ip nftban blacklist_manual_ipv4` shows the CIDR entry.
4. `/etc/nftban/blacklist.d/99-manual.conf` lists the CIDR with reason `exim_auth_fail_subnet`.
5. Existing per-IP bans coexist; subnet bans add to (don't replace) per-IP ban state.

## Related artifacts

- Production incident write-up: `feedback_loginmon_smtp_subnet_rotation_gap.md` (operator memory)
- Workspace scope: `AUDIT_190_LIFECYCLE/V113_LOGINMON_SMTP_SUBNET_AGGREGATION_SCOPE.md`
- Source: `internal/loginmon/detector/scorer.go` (subnet-aggregation section) and `internal/loginmon/module.go` (config + status integration)
- Tests: `internal/loginmon/detector/scorer_test.go` (`TestSubnetAgg_*` cluster)
