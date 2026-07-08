# Production baseline

**Last verified: v1.218.5.**

This page describes what a healthy NFTBan production host looks like on v1.218.5 and the commands an
operator uses to confirm it. Use it after an install, an update, or an incident to establish that the
host is back to a known-good state.

## Prerequisites

- Root or `nftban` group membership.
- NFTBan installed from an official package (FHS layout).

## 1. Version

`VERSION` is the single source of truth. On a baseline v1.218.5 host:

```bash
nftban version            # Version: 1.218.5  (CLI and Core components report the same version)
nftband --version         # daemon binary; version is injected at build time
```

A version mismatch between the CLI and the daemon binary, or against the `/usr/lib/nftban/VERSION`
file, means the install is inconsistent — see [Emergency recovery](EMERGENCY_RECOVERY_AND_ROLLBACK.md).

## 2. Health

```bash
nftban health
```

`nftban health` reports each component with one of: **OK, WARNING, ERROR, CRITICAL, NOT INSTALLED,
DISABLED**. The overall verdict is derived from the counts: no errors and no warnings → **OK**; no
errors but some warnings → **WARNING**; any error → **ERROR**.

Two components matter for baseline truth on v1.218.5:

- **Communication (central-comms)** — shown under *optional features*. On a host with no alert
  producer needing email, it reads **INFO / NOT CONFIGURED** (a healthy state, exit code 0). It warns
  only when an enabled producer cannot deliver (missing recipient, spool backlog, or an unresolved
  last-failure). A Communication warning **never** fails firewall posture — the health output states
  that warnings are about optional features and the firewall protection is unaffected. See
  [Notifications setup](NOTIFICATIONS_SETUP.md).
- **RBL** — DNSBL advisory reputation monitoring, **disabled by default**. On a baseline host it reads
  **OK** with the advisory note *"RBL monitoring disabled (optional; advisory reputation monitoring,
  not blocking)."* It does not block traffic or write nftables sets.

### Four-axis truth (`nftban health check`)

```bash
nftban health check
```

This view is driven by the Go validator (`nftban-validate --json`); the CLI only presents its output.
It reports **Config, Structure, Runtime, Effective** axes for the `botguard`, `ddos`, `portscan`, and
`loginmon` modules, plus a `Blacklist` composite. It expects the validator `schema_version` to be
**1.84.0** and warns on a mismatch. (This `schema_version` is the validator's JSON contract version —
it is not the `nft(8)` binary version.)

## 3. Status and validate

```bash
nftban status
```

`status` renders `SYSTEM`, `FIREWALL`, `AUTHORITY`, `SERVICES`, `PROTECTION MODULES`, and `HEALTH`
sections, with a one-line summary of the form `<state> | v1.218.5 | N banned | N whitelisted |
<health>`. The banned/whitelisted counts are read from the kernel sets, not from a cache.

```bash
nftban validate
```

`validate` checks the nftables structure and owns the exit code. The contract is: **rc 0 = PROTECTED
or IDLE** (all structure checks passed; warnings are allowed), rc 1 = DEGRADED, rc 2 = DOWN, rc 3 =
validator crashed or unreachable. It also prints a *Communication (central-comms)* dry-run block, but
that block does **not** change the nftables-structure exit code. The structure checks require the
`ip nftban` and `ip6 nftban` tables, forbid `inet filter` / `ip filter`, require the base sets
(`whitelist_ipv4`, `blacklist_ipv4`, `tcp_ports_in`, …), and expect chain policies input=drop,
output=accept.

## 4. Kernel baseline

A baseline host has **two** nftban tables (separate IPv4 and IPv6 families — not `inet`):

```bash
nft list tables
# expected: table ip nftban   and   table ip6 nftban
```

Each table has base chains `input` (policy **drop**), `forward` (drop), and `output` (accept). The
base sets include `whitelist_ipv4`, `blacklist_ipv4`, `blacklist_manual_ipv4`, the `tcp_ports_*` /
`udp_ports_*` / `ssh_ports` port sets, and the six `http_bot_*` BotGuard sets (always present, empty
when BotGuard is disabled), with the IPv6 mirror in `ip6 nftban`. Rule ordering is security-critical:
loopback accept → conntrack-invalid drop → blacklist drop (before established) → the rest.

## 5. Services and timers

```bash
nftban services          # unit status (alias: nftban service)
nftban timers            # timer status
systemctl is-active nftband
```

The runtime daemon is `nftband.service` (with `nftband.socket`); it exposes an HTTP endpoint on
`127.0.0.1:9580` and a Unix socket at `/run/nftban/nftband.sock` (see [Metrics truth](METRICS_TRUTH.md)
for the endpoint's bind rules). The install ships a set of timers (health, maintenance, watchdog,
feeds, geoip, the unified metrics exporter, the RBL check, and others). The **RBL check timer is
present but the RBL module is disabled by default**, so its presence in `nftban timers` is expected
and does not mean RBL is active.

## 6. Defaults that define the baseline

| Setting | Default | Baseline meaning |
|---------|---------|------------------|
| BotGuard (`HTTP_BOTGUARD_ENABLED`) | `false` | disabled; the `http_bot_*` sets exist but are empty |
| RBL (`NFTBAN_RBL_ENABLED`) | `NO` | observe-only monitoring is off; RBL never blocks or writes nft |
| GeoBan (`GEOBAN_ENABLED`) | `true` | module enabled, but **blocks nothing by default** |

GeoBan is enabled by default but its default policy is `allow` and the country lists in
`/etc/nftban/geoban.d/` are empty out of the box, so **GeoBan blocks no countries until you add a
`blocked.list`.** Do not read "GeoBan enabled" as "countries are being blocked."

## Failure modes and caveats

- **CLI output is a report.** `nftban status` / `health` summarize state; the enforcement truth is the
  kernel (`nft list set`, `nft list tables`). Confirm there, not from the summary alone.
- **The daemon's HTTP `/health` is not a posture signal.** It returns a fixed `ok`; use
  `nftban validate` and `nft list tables` to judge protection state (see
  [Metrics truth](METRICS_TRUTH.md)).
- **Optional-feature warnings are not firewall failures.** A Communication or RBL advisory does not
  degrade the firewall.

## References

- Version: `cli/lib/nftban/lib/version.sh`, `cmd_version.sh`; daemon `cmd/nftband/main.go`
- Health: `cli/lib/nftban/core/nftban_health.sh`, `nftban_health_render.sh`, `nftban_health_checks_modules.sh`, `cmd_health.sh`
- Status / validate: `cli/lib/nftban/cli/cmd_status.sh`, `cmd_validate.sh`
- Schema / sets / chains: `cli/lib/nftban/lib/nft_schema.sh`; daemon allowlist `cmd/nftband/daemon_types.go`
- Defaults: `etc/nftban/conf.d/botguard/main.conf`, `conf.d/rbl/main.conf`, `conf.d/geoban/main.conf`
- Related: [Metrics truth](METRICS_TRUTH.md), [Emergency recovery](EMERGENCY_RECOVERY_AND_ROLLBACK.md)
