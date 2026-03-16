# NFTBan Timer Classification Guide

**Version:** 1.21.3
**Last Updated:** 2026-03-16

## Timer Tiers

All systemd timers are classified into tiers that determine packaging, default
state, and upgrade reconciliation behavior.

| Tier | Meaning | Default State | Reconciled on Upgrade |
|------|---------|---------------|----------------------|
| **CORE** | Required for correct operation | enabled | Yes (if `RECONCILE_CORE_TIMERS=true`) |
| **CONDITIONAL** | Module-specific, enabled when module is active | disabled (enabled by module) | No |
| **OPTIONAL** | Opt-in features, not required | disabled | No |
| **PRO** | NFTBan Pro subscription only | not installed (free edition) | N/A |
| **ON-DEMAND** | Static units, activated by events | static | No |
| **DEPRECATED** | Scheduled for removal | see notes | No |

## Timer Inventory

### CORE Timers (always enabled)

These timers are essential. The package postinst enables them on install and
upgrade (unless `NFTBAN_RECONCILE_CORE_TIMERS="false"` in nftban.conf).

| Timer | Schedule | Purpose | Missed Run Impact |
|-------|----------|---------|-------------------|
| `nftban-maintenance.timer` | Every 15min | Log rotation, housekeeping, drift guard | Medium/High |
| `nftban-queue.timer` | Every 3min | Ban queue processing (retry/DLQ) | High |
| `nftban-watchdog.timer` | Every 2min | Daemon health monitoring, self-healing | Medium |
| `nftban-health.timer` | Daily 03:00 | System health diagnostics | Low/Medium |
| `nftban-core-feeds.timer` | Daily 03:20 | Threat intelligence feed updates | Medium |
| `nftban-core-geoip.timer` | Weekly Sun 02:30 | GeoIP database updates | Low/Medium |
| `nftban-unified-exporter.timer` | Every 60s | Prometheus/JSON metrics export | Medium |

### CONDITIONAL Timers (module-specific)

These timers are enabled/disabled by their parent module. They should NOT be
included in core reconciliation.

| Timer | Schedule | Module | Purpose |
|-------|----------|--------|---------|
| `nftban-botscan.timer` | Every 10min | botguard | Clock 3: access log pattern matching |
| `nftban-suricata-update.timer` | Weekly Sun 03:40 | suricata | Suricata rule updates |

### OPTIONAL Timers (opt-in)

These are installed but disabled by default. Enable manually if needed.

| Timer | Schedule | Purpose | Notes |
|-------|----------|---------|-------|
| `nftban-snapshot.timer` | Hourly | State snapshots for rollback/forensics | Low overhead, useful for supportability |
| `nftban-rbl-check.timer` | Every 12h | RBL/DNSBL reputation verification | Makes external DNS lookups |
| `nftban-update.timer` | Weekly Sun 04:00 | Automatic package self-update | Requires `update.conf` configuration |

### PRO Timers (subscription only)

Not installed in the free edition. Available with NFTBan Pro.

| Timer | Schedule | Purpose |
|-------|----------|---------|
| `nftban-pro-inventory.timer` | Daily 04:00 | Server inventory collection |
| `nftban-pro-license.timer` | Every 6h | License validation |

### ON-DEMAND Units (static)

Activated by events, not by schedule.

| Unit | Trigger | Purpose |
|------|---------|---------|
| `nftban-rollback.timer` | Manual/auto-update failure | Emergency rollback countdown |
| `nftban-alert@.service` | `OnFailure=` in other units | Service failure alerting |

## Services

### CORE Services

| Service | Type | Purpose |
|---------|------|---------|
| `nftband.service` | daemon | Main IPC daemon (single nftables writer) |
| `nftband.socket` | socket | Socket activation for daemon |

### CONDITIONAL Services

| Service | Module | Purpose |
|---------|--------|---------|
| `nftban-suricata.service` | suricata | Suricata IDS integration daemon |
| `nftban-suricata-stats.service` | suricata | Suricata statistics collection |

### DEPRECATED Services

| Service | Replaced By | Removal Target |
|---------|-------------|----------------|
| `nftban-login-monitor.service` | `nftband` loginmon module (`pkg/loginmon`) | v1.23.0 |

The shell-based login monitor is superseded by the Go daemon's built-in
loginmon module. Running both simultaneously causes duplicate ban attempts
and "Failed to ban" errors.

**Migration:** No action required. The daemon's loginmon activates automatically.
The package postinst (v1.21.3+) detects and disables the legacy service when
the daemon is active.

### PRO / EXPERIMENTAL Services

| Service | Tier | Purpose |
|---------|------|---------|
| `nftban-api.service` | PRO | REST API server |
| `nftban-ui.service` | PRO | Web UI |
| `nftban-ui-auth.service` | PRO | UI authentication |
| `nftban-ui-auth.socket` | PRO | UI auth socket activation |
| `nftban-firewall-init.service` | EXPERIMENTAL | Boot delay initialization |

## Configuration

### Timer Reconciliation

The `NFTBAN_RECONCILE_CORE_TIMERS` option in `/etc/nftban/nftban.conf` controls
whether package upgrades re-enable core timers.

```bash
# Default: true — core timers are always ensured enabled on upgrade
NFTBAN_RECONCILE_CORE_TIMERS="true"

# Set to false if you intentionally disable core timers
NFTBAN_RECONCILE_CORE_TIMERS="false"
```

Override with `/etc/nftban/nftban.conf.local` for local customization.

### Legacy Timer References

The following timer names are **invalid** and never existed:

- ~~`nftban.timer`~~ — never existed
- ~~`nftban-login.timer`~~ — never existed (service only, no timer)
- ~~`nftban-ddos.timer`~~ — never existed
- ~~`nftban-portscan.timer`~~ — never existed
- ~~`nftban-feeds.timer`~~ — renamed to `nftban-core-feeds.timer`
- ~~`nftban-geoip-update.timer`~~ — renamed to `nftban-core-geoip.timer`
- ~~`nftban-metrics-exporter.timer`~~ — replaced by `nftban-unified-exporter.timer`
- ~~`nftban-connector-exporter.timer`~~ — replaced by `nftban-unified-exporter.timer`

The unified exporter timer has `Conflicts=` directives against the legacy
exporter timers to prevent accidental co-existence.

## Expected Timer State (Typical Server)

```
$ systemctl list-timers 'nftban*'

nftban-maintenance.timer        ← CORE (15min)
nftban-queue.timer              ← CORE (3min)
nftban-watchdog.timer           ← CORE (2min)
nftban-health.timer             ← CORE (daily)
nftban-core-feeds.timer         ← CORE (daily)
nftban-core-geoip.timer         ← CORE (weekly)
nftban-unified-exporter.timer   ← CORE (60s)
```

With botguard enabled, also:
```
nftban-botscan.timer            ← CONDITIONAL (10min)
```

With suricata enabled, also:
```
nftban-suricata-update.timer    ← CONDITIONAL (weekly)
```
