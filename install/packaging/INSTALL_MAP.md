# NFTBan v1.0 - Installation File Mapping

**Version:** 1.0.0
**Updated:** 2025-12-17
**Package:** nftban (main package)

This document defines the **exact file mapping** from development repo to installed system.

**NO symlinks, NO patches** - files are copied directly to their destinations.

---

## Path Configuration

All paths are defined in `/etc/nftban/nftban.conf` via config variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_CONFIG_DIR` | `/etc/nftban` | Configuration files |
| `NFTBAN_LIB_DIR` | `/usr/lib/nftban` | Library modules |
| `NFTBAN_DATA_DIR` | `/var/lib/nftban` | Runtime state data |
| `NFTBAN_LOG_DIR` | `/var/log/nftban` | Log files |
| `NFTBAN_CACHE_DIR` | `/var/cache/nftban` | Cache files |
| `NFTBAN_RUN_DIR` | `/run/nftban` | Runtime (PIDs, sockets) |
| `NFTBAN_SHARE_DIR` | `/usr/share/nftban` | Static data |

**Scripts must use these variables** - not hardcoded paths.

---

## Installation Method

All files are **direct copies** (not symlinks):

```
SOURCE (repo)                          → DESTINATION (installed system)
/home/.../nftban-v1.0-dev/cli/...      → /usr/lib/nftban/...
/home/.../nftban-v1.0-dev/install/...  → various system locations
```

---

## Directory Structure on Installed System

```
/etc/nftban/                          # Configuration (user-editable)
/etc/nftban/conf.d/                   # Modular config (watchdog.conf, etc.)
/usr/lib/nftban/                      # Library modules (immutable)
/usr/bin/nftban                       # Main CLI binary
/usr/sbin/nftban                      # Symlink → /usr/bin/nftban (for backward compat ONLY)
/usr/share/nftban/                    # Static data (templates, profiles)
/var/lib/nftban/                      # Runtime state (mutable)
/var/log/nftban/                      # Logs
/usr/lib/systemd/system/              # Systemd services
```

---

## File Mapping: CLI Library

### Source: `cli/lib/nftban/` → Destination: `/usr/lib/nftban/`

| Source Directory | Destination | Description |
|-----------------|-------------|-------------|
| `cli/lib/nftban/core/*.sh` | `/usr/lib/nftban/core/` | Core modules (nftban_*.sh) |
| `cli/lib/nftban/cli/*.sh` | `/usr/lib/nftban/cli/` | CLI commands (cmd_*.sh) |
| `cli/lib/nftban/modules/*.sh` | `/usr/lib/nftban/modules/` | Feature modules |
| `cli/lib/nftban/helpers/*.sh` | `/usr/lib/nftban/helpers/` | Helper functions |
| `cli/lib/nftban/lib/*.sh` | `/usr/lib/nftban/lib/` | Shared libraries |
| `cli/lib/nftban/exporters/*.sh` | `/usr/lib/nftban/exporters/` | Prometheus exporters |
| `cli/lib/nftban/setup/*.sh` | `/usr/lib/nftban/setup/` | Setup scripts |
| `cli/lib/nftban/tools/*.sh` | `/usr/lib/nftban/tools/` | Utility tools |
| `cli/lib/nftban/cron/*.sh` | `/usr/lib/nftban/cron/` | Cron job scripts |
| `cli/lib/nftban/bin/` | `/usr/lib/nftban/bin/` | Go binaries |

### Watchdog Module (NEW)

| Source | Destination | Mode | Owner |
|--------|-------------|------|-------|
| `cli/lib/nftban/core/nftban_watchdog.sh` | `/usr/lib/nftban/core/nftban_watchdog.sh` | 0644 | root:root |
| `cli/lib/nftban/cli/cmd_watchdog.sh` | `/usr/lib/nftban/cli/cmd_watchdog.sh` | 0644 | root:root |

---

## File Mapping: Main CLI Binary

| Source | Destination | Mode | Owner |
|--------|-------------|------|-------|
| `cli/sbin/nftban` | `/usr/bin/nftban` | 0755 | root:nftban |

**Note:** `/usr/sbin/nftban` should be a **symlink** to `/usr/bin/nftban` for backward compatibility only:
```bash
ln -sf /usr/bin/nftban /usr/sbin/nftban
```

---

## File Mapping: Configuration

### Source: `install/config/` → Destination: `/etc/nftban/`

| Source | Destination | Mode | Owner |
|--------|-------------|------|-------|
| `install/config/nftban.conf` | `/etc/nftban/nftban.conf` | 0640 | root:nftban |
| `install/config/feeds.conf` | `/etc/nftban/feeds.conf` | 0640 | root:nftban |
| `install/config/nftban.logrotate` | `/etc/logrotate.d/nftban` | 0644 | root:root |
| `install/config/ui-access.list` | `/etc/nftban/ui-access.list` | 0640 | root:nftban |
| `install/config/allowed-gui-groups` | `/etc/nftban/allowed-gui-groups` | 0640 | root:nftban |

### Modular Config: `install/config/conf.d/` → `/etc/nftban/conf.d/`

| Source | Destination | Mode | Owner |
|--------|-------------|------|-------|
| `install/config/conf.d/watchdog.conf` | `/etc/nftban/conf.d/watchdog.conf` | 0640 | root:nftban |

---

## File Mapping: Systemd Services

### Source: `install/systemd/` → Destination: `/usr/lib/systemd/system/`

| Source | Destination | Mode |
|--------|-------------|------|
| `nftban-health.service` | `/usr/lib/systemd/system/nftban-health.service` | 0644 |
| `nftban-health.timer` | `/usr/lib/systemd/system/nftban-health.timer` | 0644 |
| `nftban-health-fix.service` | `/usr/lib/systemd/system/nftban-health-fix.service` | 0644 |
| `nftban-maintenance.service` | `/usr/lib/systemd/system/nftban-maintenance.service` | 0644 |
| `nftban-maintenance.timer` | `/usr/lib/systemd/system/nftban-maintenance.timer` | 0644 |
| `nftban-login-monitor.service` | `/usr/lib/systemd/system/nftban-login-monitor.service` | 0644 |
| `nftban-snapshot.service` | `/usr/lib/systemd/system/nftban-snapshot.service` | 0644 |
| `nftban-snapshot.timer` | `/usr/lib/systemd/system/nftban-snapshot.timer` | 0644 |
| `nftban-rollback.service` | `/usr/lib/systemd/system/nftban-rollback.service` | 0644 |
| `nftban-rollback.timer` | `/usr/lib/systemd/system/nftban-rollback.timer` | 0644 |
| `nftban-metrics-exporter.service` | `/usr/lib/systemd/system/nftban-metrics-exporter.service` | 0644 |
| `nftban-metrics-exporter.timer` | `/usr/lib/systemd/system/nftban-metrics-exporter.timer` | 0644 |
| `nftban-suricata.service` | `/usr/lib/systemd/system/nftban-suricata.service` | 0644 |
| `nftban-suricata-update.service` | `/usr/lib/systemd/system/nftban-suricata-update.service` | 0644 |
| `nftban-suricata-update.timer` | `/usr/lib/systemd/system/nftban-suricata-update.timer` | 0644 |
| `nftban-ui.service` | `/usr/lib/systemd/system/nftban-ui.service` | 0644 |
| `nftban-ui-auth.service` | `/usr/lib/systemd/system/nftban-ui-auth.service` | 0644 |
| `nftban-ui-auth.socket` | `/usr/lib/systemd/system/nftban-ui-auth.socket` | 0644 |
| **`nftban-watchdog.service`** | `/usr/lib/systemd/system/nftban-watchdog.service` | 0644 |
| **`nftban-watchdog.timer`** | `/usr/lib/systemd/system/nftban-watchdog.timer` | 0644 |

---

## File Mapping: Static Data

### Source: `cli/share/nftban/` → Destination: `/usr/share/nftban/`

| Source Directory | Destination | Description |
|-----------------|-------------|-------------|
| `cli/share/nftban/templates/` | `/usr/share/nftban/templates/` | Email templates, report templates |
| `cli/share/nftban/profiles/` | `/usr/share/nftban/profiles/` | Protection profiles |
| `cli/share/nftban/specs/` | `/usr/share/nftban/specs/` | Specification files |

---

## Runtime Directories (Created at Install)

These directories are **created** during installation per FHS spec (`nftban_fhs_spec.sh`):

| Directory | Mode | Owner | Purpose |
|-----------|------|-------|---------|
| `/etc/nftban/` | 0750 | root:nftban | Configuration files |
| `/etc/nftban/conf.d/` | 0750 | root:nftban | Module configurations |
| `/var/lib/nftban/` | 0750 | nftban:nftban | Application state data |
| `/var/lib/nftban/reports/` | 0750 | nftban:nftban | Generated reports |
| `/var/lib/nftban/reports/baseline/` | 0750 | nftban:nftban | Baseline reports |
| `/var/lib/nftban/reports/watchdog/` | 0750 | nftban:nftban | Watchdog system reports |
| `/var/lib/nftban/reports/auditors/` | 0770 | root:nftban-auditors | Auditor reports |
| `/var/lib/nftban/metrics/` | 0750 | nftban:nftban | Statistics metrics |
| `/var/lib/nftban/snapshots/` | 0750 | nftban:nftban | Stats snapshots |
| `/var/lib/nftban/exports/` | 0750 | nftban:nftban | User data exports |
| `/var/lib/nftban/geoip/` | 0750 | nftban:nftban | GeoIP databases |
| `/var/log/nftban/` | 0750 | nftban:nftban | Log files |
| `/var/cache/nftban/` | 0755 | nftban:nftban | Cache files |
| `/var/cache/nftban/health/` | 0750 | nftban:nftban | Health cache |
| `/run/nftban/` | 0755 | nftban:nftban | Runtime (PIDs, sockets) |

**Note:** Compiled IP lists (whitelist, blacklist, feeds) are generated at runtime in `/var/lib/nftban/compiled/` by the nftables module.

---

## Go Binaries

### Source: `cli/lib/nftban/bin/` → Destination: `/usr/lib/nftban/bin/`

| Binary | Purpose |
|--------|---------|
| `nftban-geoip-lookup` | GeoIP lookup |
| `nftban-nft-controller` | nftables controller |
| `nftban-json-parser` | JSON parsing |
| `nftban-ip-validator` | IP validation |
| `nftban-cidr-merge` | CIDR aggregation |
| `nftban-ui` | Web UI server (requires nftban-cli group) |
| `nftban-auth` | Authentication service |
| `nftban-email` | Email sender |
| `nftban-feed-fetcher` | Threat feed fetcher |

---

## Installation Commands

### Install Library Files
```bash
# Create directories
install -d -m 0755 /usr/lib/nftban/{core,cli,modules,helpers,lib,exporters,setup,tools,cron,bin}

# Copy library files (preserving structure)
cp -r cli/lib/nftban/* /usr/lib/nftban/

# Set permissions
find /usr/lib/nftban -type d -exec chmod 0755 {} \;
find /usr/lib/nftban -type f -name "*.sh" -exec chmod 0644 {} \;
find /usr/lib/nftban/bin -type f -exec chmod 0755 {} \;
```

### Install Configuration
```bash
install -d -m 0750 /etc/nftban/conf.d
install -m 0640 -o root -g nftban install/config/nftban.conf /etc/nftban/
install -m 0640 -o root -g nftban install/config/feeds.conf /etc/nftban/
install -m 0640 -o root -g nftban install/config/conf.d/watchdog.conf /etc/nftban/conf.d/
```

### Install Systemd Services
```bash
install -m 0644 install/systemd/*.service /usr/lib/systemd/system/
install -m 0644 install/systemd/*.timer /usr/lib/systemd/system/
install -m 0644 install/systemd/*.socket /usr/lib/systemd/system/
systemctl daemon-reload
```

### Install Main Binary
```bash
install -m 0755 -o root -g nftban cli/sbin/nftban /usr/bin/nftban
ln -sf /usr/bin/nftban /usr/sbin/nftban  # backward compat only
```

---

## Watchdog Files Summary

| Type | Source Path | Destination Path |
|------|-------------|------------------|
| Core Module | `cli/lib/nftban/core/nftban_watchdog.sh` | `/usr/lib/nftban/core/nftban_watchdog.sh` |
| CLI Command | `cli/lib/nftban/cli/cmd_watchdog.sh` | `/usr/lib/nftban/cli/cmd_watchdog.sh` |
| Config | `install/config/conf.d/watchdog.conf` | `/etc/nftban/conf.d/watchdog.conf` |
| Systemd Service | `install/systemd/nftban-watchdog.service` | `/usr/lib/systemd/system/nftban-watchdog.service` |
| Systemd Timer | `install/systemd/nftban-watchdog.timer` | `/usr/lib/systemd/system/nftban-watchdog.timer` |
| Runtime Dir | (created) | `/var/lib/nftban/reports/watchdog/` |
| Metrics File | (generated) | `/var/lib/nftban/metrics/watchdog.prom` |

---

## Verification

After installation, verify:

```bash
# Check all watchdog files exist
ls -la /usr/lib/nftban/core/nftban_watchdog.sh
ls -la /usr/lib/nftban/cli/cmd_watchdog.sh
ls -la /etc/nftban/conf.d/watchdog.conf
ls -la /usr/lib/systemd/system/nftban-watchdog.service
ls -la /usr/lib/systemd/system/nftban-watchdog.timer
ls -la /var/lib/nftban/reports/watchdog/

# Test watchdog command
nftban watchdog status
```

---

## NO Symlinks Policy

**All files are direct copies**, except:

1. `/usr/sbin/nftban` → symlink to `/usr/bin/nftban` (backward compatibility)

Everything else is a **direct file copy** with proper ownership and permissions.
