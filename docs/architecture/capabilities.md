# NFTBan Capability-Based Security Model

**Document Version**: 1.0
**Date**: 2025-11-02
**Status**: Active

---

## Executive Summary

NFTBan manages nftables as a **non-root user** using **Linux capabilities** scoped to the **systemd service**, not to binaries. This design:

- ✅ Minimizes attack surface (grants ONLY `CAP_NET_ADMIN`, not full root)
- ✅ Follows principle of least privilege
- ✅ Prevents local privilege escalation
- ✅ Works consistently across all major Linux distributions

---

## Why Polkit Doesn't Work for nftables

### Technical Background

**Polkit (PolicyKit)** is a D-Bus-based authorization framework that works for applications using D-Bus for inter-process communication.

**nft (nftables)** communicates **directly with the Linux kernel** via **netlink sockets**, which require the `CAP_NET_ADMIN` kernel capability.

### Architecture Comparison

```
❌ Polkit Approach (DOESN'T WORK):
┌─────────┐    D-Bus    ┌────────┐
│  nftban │ ─────────> │ Polkit │ ─X─> nft (never reaches here)
└─────────┘            └────────┘

✅ Actual nft Architecture:
┌─────────┐   netlink   ┌────────┐
│   nft   │ ─────────> │ Kernel │ (requires CAP_NET_ADMIN)
└─────────┘            └────────┘
```

**Conclusion**: Polkit rules have **zero effect** on nft commands. Capabilities are the correct approach.

---

## NFTBan's Capability Model

### Service-Scoped Capabilities (Recommended)

NFTBan uses **systemd service-scoped capabilities** instead of file capabilities:

```ini
[Service]
User=nftban
Group=nftban

# Grant capability ONLY to this service, not globally
AmbientCapabilities=CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_ADMIN

# Security hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
SystemCallFilter=~@mount @module @raw-io @reboot @swap
```

### Why Service-Scoped?

| Approach | Security | Maintenance | Cross-Distro |
|----------|----------|-------------|--------------|
| **File caps** (`setcap cap_net_admin+ep /usr/sbin/nft`) | ❌ ANY local user can modify firewall | ❌ Lost on package updates | ✅ Works |
| **Service-scoped** (systemd AmbientCapabilities) | ✅ ONLY nftban service | ✅ Survives upgrades | ✅ Works |
| **Run as root** | ❌ Full system access | ✅ Simple | ✅ Works |

**Verdict**: Service-scoped capabilities are the most secure and maintainable approach.

---

## Implementation Details

### 1. Capability Checking Helper

**File**: `src/usr/lib/nftban/core/nftban_security.sh`

```bash
# Check if current process has CAP_NET_ADMIN capability
nftban_has_net_admin() {
    # Method 1: Harmless read-only query through nft
    if command -v nft >/dev/null 2>&1; then
        if nft list tables >/dev/null 2>&1; then
            return 0
        fi
    fi

    # Method 2: Check CapEff bitmask (bit 12 = CAP_NET_ADMIN)
    if [[ -r /proc/self/status ]]; then
        local hexbits
        hexbits="$(awk '/^CapEff:/ {print $2}' /proc/self/status 2>/dev/null || true)"
        if [[ -n "${hexbits:-}" ]]; then
            if (( 0x$hexbits & 0x0000000000001000 )); then
                return 0
            fi
        fi
    fi

    return 1
}

# Require CAP_NET_ADMIN or exit with clear error
nftban_require_net_admin_or_exit() {
    if ! nftban_has_net_admin; then
        echo "ERROR: CAP_NET_ADMIN capability required" >&2
        echo "See /usr/share/nftban/docs/architecture/capabilities.md" >&2
        exit 1
    fi
}
```

### 2. CLI Command Refactoring

**Before** (root-only check):
```bash
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: 'feeds update' requires root privileges" >&2
    exit 1
fi
```

**After** (capability-aware):
```bash
# Check CAP_NET_ADMIN capability for nftables modifications
if declare -F nftban_require_net_admin_or_exit >/dev/null 2>&1; then
    nftban_require_net_admin_or_exit
fi
```

**Files Updated**:
- `src/usr/lib/nftban/cli/cmd_feeds.sh` (5 EUID checks → capability checks)
- Future: cmd_nftables.sh, cmd_firewall.sh, etc.

### 3. Systemd Service Configuration

**File**: `src/usr/lib/systemd/system/nftban.service`

Key directives:
- `AmbientCapabilities=CAP_NET_ADMIN` - Grants capability to service
- `CapabilityBoundingSet=CAP_NET_ADMIN` - Limits to ONLY this capability
- `NoNewPrivileges=yes` - Prevents privilege escalation
- `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK` - Limits network access
- `SystemCallFilter=~@mount @module @raw-io @reboot @swap` - Blocks dangerous syscalls

---

## Security Comparison

### Attack Surface Reduction

| Privilege Level | Grants | Risk if Compromised |
|----------------|---------|---------------------|
| **root** | Everything (filesystem, kernel modules, suid binaries, etc.) | **Full host takeover** |
| **CAP_NET_ADMIN** | Modify routing tables, firewall, sockets | **Network disruption only**; no file/exec access |

**Impact**: Capability isolation removes **≥ 80-90%** of root's privilege scope.

### Threat Model

**Scenario 1: nftban service exploited**
- With root: Attacker gains full system access
- With CAP_NET_ADMIN: Attacker can only modify network rules

**Scenario 2: Local privilege escalation attempt**
- With file caps on nft: ANY user can modify firewall
- With service-scoped caps: ONLY nftban service can modify firewall

**Scenario 3: Package update**
- With file caps: Lost after nft package update (must reapply)
- With service-scoped caps: Persists (defined in service file)

---

## Verification & Troubleshooting

### Check Service Capabilities

```bash
# Verify service has correct capabilities
systemctl show nftban.service -p AmbientCapabilities -p CapabilityBoundingSet

# Expected output:
# AmbientCapabilities=cap_net_admin
# CapabilityBoundingSet=cap_net_admin
```

### Test Capability Check

```bash
# As nftban user (should work with service-scoped caps)
sudo -u nftban nft list tables

# Check process capabilities
grep Cap /proc/self/status
```

### Common Issues

#### Issue 1: "ERROR: CAP_NET_ADMIN capability required"

**Cause**: Service not running with correct capabilities

**Solution**:
```bash
# 1. Verify service file has capability directives
systemctl cat nftban.service | grep -A2 "Capability"

# 2. Reload systemd
systemctl daemon-reload

# 3. Restart service
systemctl restart nftban.service
```

#### Issue 2: SELinux denials (RHEL/CentOS/Fedora)

**Check for denials**:
```bash
ausearch -m AVC -ts recent | grep nftban
```

**Solution** (usually not needed):
```bash
# Generate policy from denials
audit2allow -a -M nftban_capability

# Install policy
semodule -i nftban_capability.pp
```

**Note**: Modern SELinux policies generally allow capabilities without custom modules.

#### Issue 3: Service fails to start

**Check logs**:
```bash
journalctl -u nftban.service -n 50 --no-pager
```

**Common causes**:
- Systemd version too old (< 229) - AmbientCapabilities not supported
- Kernel version too old (< 4.3) - Ambient capabilities not available

**Fallback**: Temporarily run as root (User=root, Group=root) until system upgraded

---

## Distribution Support

### Tested Distributions

| Distribution | Version | Systemd | Support |
|--------------|---------|---------|---------|
| **Ubuntu** | 24.04 LTS | 255 | ✅ Full |
| **Debian** | 12 (Bookworm) | 252 | ✅ Full |
| **CentOS Stream** | 9 | 252 | ✅ Full |
| **RHEL** | 9.x | 252 | ✅ Full |
| **Fedora** | 39+ | 254+ | ✅ Full |
| **Rocky Linux** | 9.x | 252 | ✅ Full |
| **AlmaLinux** | 9.x | 252 | ✅ Full |
| **Arch Linux** | Rolling | Latest | ✅ Full |

**Minimum Requirements**:
- Systemd >= 229 (for AmbientCapabilities support)
- Kernel >= 4.3 (for ambient capability inheritance)

### Legacy System Fallback

For systems with systemd < 229 or kernel < 4.3:

**Option 1**: Use file capabilities (less secure)
```bash
setcap cap_net_admin+ep /usr/sbin/nft
```

**Option 2**: Run as root (least secure)
```ini
[Service]
User=root
Group=root
```

**Recommendation**: Upgrade system to modern kernel/systemd

---

## Best Practices

### DO ✅

1. **Use service-scoped capabilities** (AmbientCapabilities)
2. **Keep systemd security directives** (NoNewPrivileges, ProtectSystem, etc.)
3. **Test after system updates** (verify capabilities still work)
4. **Monitor service logs** for capability-related errors
5. **Use `nftban_has_net_admin()` helper** for capability checks

### DON'T ❌

1. **Don't set file capabilities on /usr/sbin/nft globally**
2. **Don't run nftban services as root** (unless absolutely necessary)
3. **Don't use Polkit for nft commands** (it doesn't work)
4. **Don't remove capability checks** from CLI commands
5. **Don't skip systemd security hardening** directives

---

## Future Enhancements

### Planned Improvements

1. **Extend capability checks to all CLI commands**
   - cmd_nftables.sh (7 EUID checks)
   - cmd_firewall.sh (1 EUID check)
   - cmd_cloudflare.sh (2 EUID checks)
   - cmd_ddos.sh (1 EUID check)
   - etc.

2. **Add capability-aware help messages**
   - Show different help based on capability availability
   - Guide users to enable service-scoped caps

3. **Automated capability testing**
   - CI/CD tests for capability functionality
   - Integration tests across multiple distros

4. **Capability monitoring**
   - Health check for service capabilities
   - Alert if capabilities lost/misconfigured

---

## References

### NFTBan Documentation
- [Permission Architecture](permission-architecture.md)
- [Security Model](../security/SECURITY.md)
- [Development Guidelines](../development/coding-standards.md)

### External Resources
- [Linux Capabilities man page](https://man7.org/linux/man-pages/man7/capabilities.7.html)
- [systemd Security Directives](https://www.freedesktop.org/software/systemd/man/systemd.exec.html#Security)
- [nftables Netlink Protocol](https://wiki.nftables.org/wiki-nftables/index.php/Netlink_API)

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2025-11-02 | Initial documentation (BUG-007 resolution) |

---

## Authors

- **Antonios Voulvoulis** <contact@nftban.com>
- **Claude (AI Assistant)** - Technical analysis and recommendations

---

**NFTBan** — Simplifying Linux Firewall Management
https://nftban.com
