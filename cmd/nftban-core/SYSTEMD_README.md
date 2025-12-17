# NFTBan Core v1.0.0 - Systemd Integration

This document describes the systemd service integration and PolicyKit configuration for NFTBan Core v1.0.0.

## Overview

NFTBan Core v1.0.0 introduces systemd service management with PolicyKit integration, allowing:
- Automatic startup on boot
- Periodic feed updates via systemd timers
- Non-root user management through PolicyKit
- Proper security hardening via systemd directives

## Components

### 1. nftban-core.service
Main service that syncs NFTBan configuration to nftables on startup.

**Type**: `oneshot` with `RemainAfterExit=yes`
**Runs**: `/usr/local/bin/nftban-core sync`
**Security**: Hardened with ProtectSystem, PrivateTmp, resource limits

### 2. nftban-core-feeds.service
One-shot service that updates threat intelligence feeds.

**Type**: `oneshot`
**Runs**: `/usr/local/bin/nftban-core feeds load`
**Timeout**: 15 minutes
**Resources**: Up to 512MB RAM, 80% CPU quota

### 3. nftban-core-feeds.timer
Systemd timer for automatic daily feed updates.

**Schedule**:
- Daily at 3:00 AM
- 15 minutes after boot
- Random delay: 0-30 minutes (prevents thundering herd)
- Persistent: Runs missed executions

## Installation

### Quick Install
```bash
cd cmd/nftban-core
sudo ./install.sh
```

The installer will:
1. Install nftban-core binary to `/usr/local/bin/`
2. Create `nftban` group for privileged access
3. Create required directories (`/etc/nftban`, `/var/lib/nftban/feeds`)
4. Install systemd service files
5. Install PolicyKit rules (if available)
6. Optionally enable services

### Manual Installation

1. **Build the binary:**
   ```bash
   cd cmd/nftban-core
   go build -o nftban-core
   ```

2. **Install binary:**
   ```bash
   sudo install -m 0755 nftban-core /usr/local/bin/
   ```

3. **Create group and directories:**
   ```bash
   sudo groupadd -r nftban
   sudo mkdir -p /etc/nftban/{whitelist.d,blacklist.d,ports.d}
   sudo mkdir -p /var/lib/nftban/feeds
   sudo chown -R root:nftban /etc/nftban /var/lib/nftban
   sudo chmod -R 775 /etc/nftban /var/lib/nftban
   ```

4. **Install systemd files:**
   ```bash
   sudo cp systemd/*.service /etc/systemd/system/
   sudo cp systemd/*.timer /etc/systemd/system/
   sudo systemctl daemon-reload
   ```

5. **Install PolicyKit rules:**
   ```bash
   sudo cp polkit/10-nftban-core.rules /etc/polkit-1/rules.d/
   ```

6. **Add users to nftban group:**
   ```bash
   sudo usermod -aG nftban <username>
   ```
   *(Users need to log out and back in for group changes to take effect)*

## Usage

### Enable and Start Services

```bash
# Enable main service on boot
sudo systemctl enable nftban-core.service

# Start main service now
sudo systemctl start nftban-core.service

# Enable automatic feed updates
sudo systemctl enable nftban-core-feeds.timer
sudo systemctl start nftban-core-feeds.timer
```

### Check Status

```bash
# Check main service status
systemctl status nftban-core.service

# Check feed update timer
systemctl status nftban-core-feeds.timer

# View next scheduled feed update
systemctl list-timers nftban-core-feeds.timer

# View service logs
journalctl -u nftban-core.service
journalctl -u nftban-core-feeds.service
```

### Manual Operations

```bash
# Manually trigger feed update
sudo systemctl start nftban-core-feeds.service

# Reload NFTBan configuration
sudo systemctl reload nftban-core.service

# Restart service
sudo systemctl restart nftban-core.service
```

## PolicyKit Integration

Users in the `nftban` group can manage nftban-core services without `sudo`:

```bash
# Start/stop/restart services
systemctl start nftban-core.service
systemctl stop nftban-core.service
systemctl restart nftban-core.service

# Check status (always allowed)
systemctl status nftban-core.service

# Trigger feed update
systemctl start nftban-core-feeds.service
```

**Note**: PolicyKit requires the user to be in the `nftban` group and may prompt for password depending on system configuration.

## Security Features

### Systemd Hardening

Both services include comprehensive security hardening:

- **NoNewPrivileges**: Prevents privilege escalation
- **PrivateTmp**: Isolated `/tmp` directory
- **ProtectSystem=strict**: Read-only root filesystem (except specific paths)
- **ProtectHome**: No access to user home directories
- **ReadWritePaths**: Only `/etc/nftban` and `/var/lib/nftban` writable
- **ProtectKernelTunables**: Prevents kernel parameter modification
- **ProtectKernelModules**: Prevents kernel module loading
- **RestrictNamespaces**: Limits namespace creation
- **RestrictRealtime**: No realtime scheduling
- **MemoryDenyWriteExecute**: W^X protection
- **SystemCallFilter**: Restricted to safe syscalls

### Resource Limits

**nftban-core.service**:
- CPU: 50% quota
- Memory: 256MB max
- Tasks: 10 max

**nftban-core-feeds.service**:
- CPU: 80% quota
- Memory: 512MB max
- Tasks: 20 max
- Timeout: 15 minutes

## Directory Structure

```
/etc/nftban/
├── whitelist.d/          # Whitelist files
├── blacklist.d/          # Blacklist files
└── ports.d/              # Port configuration

/var/lib/nftban/
└── feeds/                # Threat intelligence feeds

/usr/local/bin/
└── nftban-core           # Main binary

/etc/systemd/system/
├── nftban-core.service
├── nftban-core-feeds.service
└── nftban-core-feeds.timer

/etc/polkit-1/rules.d/
└── 10-nftban-core.rules
```

## Troubleshooting

### Service won't start
```bash
# Check service status
systemctl status nftban-core.service

# View detailed logs
journalctl -xeu nftban-core.service

# Check binary permissions
ls -l /usr/local/bin/nftban-core

# Check directory permissions
ls -ld /etc/nftban /var/lib/nftban
```

### PolicyKit not working
```bash
# Check if user is in nftban group
groups

# Verify PolicyKit rules are installed
ls -l /etc/polkit-1/rules.d/10-nftban-core.rules

# Test PolicyKit authorization
pkcheck --action-id org.freedesktop.systemd1.manage-units \
  --process $$ --list-temp

# Reload PolicyKit
sudo systemctl restart polkit
```

### Feed updates not running
```bash
# Check timer status
systemctl status nftban-core-feeds.timer

# List all timers
systemctl list-timers --all

# View timer logs
journalctl -u nftban-core-feeds.timer

# Manually trigger update
sudo systemctl start nftban-core-feeds.service
```

## Upgrading

When upgrading to a new version:

1. Build new binary
2. Stop services:
   ```bash
   sudo systemctl stop nftban-core-feeds.timer
   sudo systemctl stop nftban-core.service
   ```
3. Install new binary:
   ```bash
   sudo install -m 0755 nftban-core /usr/local/bin/
   ```
4. Update systemd files if changed:
   ```bash
   sudo cp systemd/*.{service,timer} /etc/systemd/system/
   sudo systemctl daemon-reload
   ```
5. Restart services:
   ```bash
   sudo systemctl start nftban-core.service
   sudo systemctl start nftban-core-feeds.timer
   ```

## Uninstallation

```bash
# Stop and disable services
sudo systemctl stop nftban-core-feeds.timer nftban-core.service
sudo systemctl disable nftban-core-feeds.timer nftban-core.service

# Remove systemd files
sudo rm /etc/systemd/system/nftban-core{,-feeds}.{service,timer}
sudo systemctl daemon-reload

# Remove PolicyKit rules
sudo rm /etc/polkit-1/rules.d/10-nftban-core.rules

# Remove binary
sudo rm /usr/local/bin/nftban-core

# Optionally remove data (WARNING: Deletes all configuration)
# sudo rm -rf /etc/nftban /var/lib/nftban
```

## See Also

- Main documentation: `README.md`
- CIDR technical details: `docs/CIDR_INTERVAL_SETS.md`
- Project repository: https://github.com/itcmsgr/nftban-dev

---

**Version**: 0.7.2
**Date**: 2025-11-26
**Author**: NFTBan Development Team
