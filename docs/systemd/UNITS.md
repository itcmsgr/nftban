# NFTBan Systemd Units - Canonical List

**SINGLE SOURCE OF TRUTH** - Any unit not listed here is ILLEGAL to reference.

## Timers (15)

| Timer | Schedule | Purpose |
|-------|----------|---------|
| `nftban-maintenance.timer` | Every 15min | Housekeeping, log rotation |
| `nftban-unified-exporter.timer` | 45s boot | Metrics export startup |
| `nftban-watchdog.timer` | 2min boot | Daemon health monitoring |
| `nftban-queue.timer` | 3min boot | Ban queue processing |
| `nftban-snapshot.timer` | Hourly | State snapshots |
| `nftban-health.timer` | Daily 3:00 | System health check |
| `nftban-core-feeds.timer` | Daily 3:20 | Threat feed updates |
| `nftban-rbl-check.timer` | Daily 2:00 | RBL verification |
| `nftban-pro-inventory.timer` | Daily 4:00 | Pro license inventory |
| `nftban-pro-license.timer` | Every 6h | License validation |
| `nftban-core-geoip.timer` | Weekly Sun 2:30 | GeoIP database update |
| `nftban-suricata-update.timer` | Weekly Sun 3:40 | Suricata rules update |
| `nftban-update-check.timer` | Daily 3:30 | Update availability check |
| `nftban-update-apply.timer` | Weekly Sun 4:00 | Auto-update apply (gated) |
| `nftban-rollback.timer` | Manual-trigger (`OnActiveSec=5min`) | Emergency rollback — started by `nftban-apply`, stopped by `nftban-confirm` |

## Services (25)

| Service | Type | Purpose |
|---------|------|---------|
| `nftband.service` | daemon | Main IPC daemon |
| `nftband.socket` | socket | Socket activation |
| `nftban-firewall-init.service` | oneshot | Firewall initialization |
| `nftban-login-monitor.service` | daemon | Login attempt monitoring |
| `nftban-maintenance.service` | oneshot | Maintenance tasks |
| `nftban-health.service` | oneshot | Health check |
| `nftban-health-fix.service` | oneshot | Health auto-fix |
| `nftban-queue.service` | oneshot | Queue processing |
| `nftban-snapshot.service` | oneshot | State snapshot |
| `nftban-rollback.service` | oneshot | Emergency rollback |
| `nftban-unified-exporter.service` | oneshot | Metrics export |
| `nftban-watchdog.service` | oneshot | Watchdog check |
| `nftban-core-feeds.service` | oneshot | Feed updates |
| `nftban-core-geoip.service` | oneshot | GeoIP updates |
| `nftban-rbl-check.service` | oneshot | RBL check |
| `nftban-update-check.service` | oneshot | Update check (unprivileged) |
| `nftban-update-apply.service` | oneshot | Auto-update apply (gated) |
| `nftban-suricata.service` | daemon | Suricata integration |
| `nftban-suricata-stats.service` | daemon | Suricata stats |
| `nftban-suricata-update.service` | oneshot | Suricata rule updates |
| `nftban-pro-inventory.service` | oneshot | Pro inventory |
| `nftban-pro-license.service` | oneshot | Pro license check |
| `nftban-api.service` | daemon | REST API server |
| `nftban-ui.service` | daemon | Web UI |
| `nftban-ui-auth.service` | daemon | UI auth service |
| `nftban-ui-auth.socket` | socket | UI auth socket |
| `nftban-alert@.service` | template | Alert notifications |

## DEPRECATED / PHANTOM (DO NOT USE)

These names are INVALID - do not reference them anywhere:

- ~~`nftban.timer`~~ - legacy, never existed
- ~~`nftban-feeds.timer`~~ - use `nftban-core-feeds.timer`
- ~~`nftban-geoip-update.timer`~~ - use `nftban-core-geoip.timer`
- ~~`nftban-suricata.timer`~~ - use `nftban-suricata-update.timer`
- ~~`nftban-ddos.timer`~~ - never existed
- ~~`nftban-login.timer`~~ - never existed
- ~~`nftban-portscan.timer`~~ - never existed
- ~~`nftban-bandwidth-exporter.timer`~~ - never existed
- ~~`nftban-sync.timer`~~ - never existed
- ~~`nftban-login-monitor.timer`~~ - service only, no timer
- ~~`nftban-core.service`~~ - renamed to `nftband.service`
- ~~`nftban-update.timer`~~ - split into `nftban-update-check.timer` + `nftban-update-apply.timer` (v1.71.0)
- ~~`nftban-update.service`~~ - split into `nftban-update-check.service` + `nftban-update-apply.service` (v1.71.0)

---
*Last updated: 2026-04-04 | Version: 1.71.0*
