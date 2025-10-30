# NFTBan v0.10.0 - OS Path Compatibility Guide

This document tracks command paths across different operating systems to ensure NFTBan works universally.

## Critical Commands and Their Paths

### nftables (`nft` command)

| Operating System | Path | Verified |
|-----------------|------|----------|
| CentOS Stream 9 | `/usr/sbin/nft` | ✅ |
| CentOS/RHEL 8-9 | `/usr/sbin/nft` | Expected |
| Ubuntu 24.04 LTS | `/usr/sbin/nft` (after install) | ⏳ Installing |
| Ubuntu 20.04/22.04 | `/usr/sbin/nft` | Expected |
| Debian 11/12 | `/usr/sbin/nft` | Expected |

**Symlinks:** On RHEL-based systems, `/sbin/nft` → `/usr/sbin/nft`

**Package Names:**
- RHEL/CentOS: `nftables`
- Debian/Ubuntu: `nftables`

---

### fail2ban (`fail2ban-client` command)

| Operating System | Path | Verified |
|-----------------|------|----------|
| CentOS Stream 9 | `/usr/bin/fail2ban-client` | ⏳ Installing |
| CentOS/RHEL 8-9 | `/usr/bin/fail2ban-client` | Expected |
| Ubuntu 24.04 LTS | `/usr/bin/fail2ban-client` | ⏳ Installing |
| Ubuntu 20.04/22.04 | `/usr/bin/fail2ban-client` | Expected |
| Debian 11/12 | `/usr/bin/fail2ban-client` | Expected |

**Package Names:**
- RHEL/CentOS: `fail2ban` (from EPEL repository)
- Debian/Ubuntu: `fail2ban`

**IMPORTANT:** On RHEL/CentOS, fail2ban requires EPEL repository:
```bash
dnf install -y epel-release
dnf install -y fail2ban
```

---

### bash

| Operating System | Path | Notes |
|-----------------|------|-------|
| All Linux | `/bin/bash` | Standard location |
| All Linux | `/usr/bin/bash` | Also works (symlink) |

---

### systemd commands

| Command | Path | Notes |
|---------|------|-------|
| systemctl | `/usr/bin/systemctl` | Universal |
| journalctl | `/usr/bin/journalctl` | Universal |

---

## Systemd Service PATH Configuration

To ensure commands are found regardless of OS, our systemd services set:

```ini
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
```

This covers:
- `/usr/local/sbin`, `/usr/local/bin` - User-installed binaries
- `/usr/sbin`, `/usr/bin` - System binaries (RHEL/Debian)
- `/sbin`, `/bin` - Legacy locations (symlinked on modern systems)

---

## Dynamic Path Detection

For maximum portability, we use `command -v` to detect paths at runtime:

### In Systemd Services:

```ini
ExecStartPre=-/bin/sh -c 'command -v nft >/dev/null 2>&1 && nft -f /path/to/file || true'
```

This approach:
- ✅ Works on RHEL, Debian, Ubuntu
- ✅ Fails gracefully if command not found (`|| true`)
- ✅ Uses systemd PATH environment
- ✅ No hardcoded paths

### In Bash Scripts:

```bash
if command -v nft >/dev/null 2>&1; then
    NFT_CMD=$(command -v nft)
    echo "Found nft at: $NFT_CMD"
else
    echo "ERROR: nft command not found"
    exit 1
fi
```

---

## Installation Requirements

### Minimum Required Packages:

| Package | RHEL/CentOS | Debian/Ubuntu | Purpose |
|---------|-------------|---------------|---------|
| bash | `bash` | `bash` | Shell scripts |
| nftables | `nftables` | `nftables` | Firewall |
| systemd | `systemd` | `systemd` | Service management |
| curl | `curl` | `curl` | IP detection |
| iproute | `iproute` | `iproute2` | Network tools (ss) |
| gawk | `gawk` | `gawk` | Text processing |

### Optional Packages:

| Package | RHEL/CentOS | Debian/Ubuntu | Purpose |
|---------|-------------|---------------|---------|
| fail2ban | `fail2ban` (EPEL) | `fail2ban` | Temporary bans |
| mailx | `mailx` | `mailutils` | Email alerts |
| jq | `jq` | `jq` | JSON processing |
| golang | `golang` | `golang-go` | Build only (NOT runtime) |

---

## Package Manager Detection

Our installation scripts detect the package manager:

```bash
if command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
    OS_TYPE="rhel"
elif command -v apt-get >/dev/null 2>&1; then
    PKG_MGR="apt-get"
    OS_TYPE="debian"
elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
    OS_TYPE="rhel"
else
    echo "ERROR: Unknown package manager"
    exit 1
fi
```

---

## Testing Checklist

Before releasing, test on:

- [ ] CentOS Stream 9
- [ ] RHEL 9
- [ ] RHEL 8
- [ ] Ubuntu 24.04 LTS
- [ ] Ubuntu 22.04 LTS
- [ ] Ubuntu 20.04 LTS
- [ ] Debian 12
- [ ] Debian 11

### Test Commands:

```bash
# Verify nft path
which nft
nft --version

# Verify fail2ban path
which fail2ban-client
fail2ban-client version

# Test systemd service
systemctl daemon-reload
systemctl start nftban-firewall-init.service
systemctl status nftban-firewall-init.service

# Check logs
journalctl -u nftban-firewall-init.service -n 50
```

---

## Future Improvements

1. **Auto-detect nft path in nftban CLI**
   - Store detected path in `/etc/nftban/nftban.conf`
   - Use `command -v nft` at installation time

2. **Create distribution-specific packages**
   - RPM for RHEL/CentOS (with EPEL dependency)
   - DEB for Debian/Ubuntu
   - Each package can set correct paths in post-install

3. **Add path verification to health check**
   - `nftban firewall check` should verify all required commands exist
   - Report missing dependencies with installation instructions

---

**Document Version:** 1.0
**Last Updated:** 2025-10-29
**Status:** ✅ TESTED on CentOS Stream 9, Ubuntu 24.04 installation in progress
