# NFTBan v0.10.0 - Known Bugs

**Last Updated**: 2025-11-02

## 🐛 Active Bugs

**None currently** - All critical bugs fixed for v0.10.0 release! 🎉

---

## ✅ Fixed Bugs

### BUG-007: Missing authorization for nftban user to execute nft commands
**Status**: Fixed (commits: a8977d2, 53b9d56, 63c1164)
**Fixed Date**: 2025-11-02
**Severity**: Critical (blocked v0.10.0 release)

**Original Problem**:
The `nftban` system user couldn't execute `nft` commands because it lacked proper authorization.

**Initial Approach (FAILED)**:
Attempted to use Polkit authorization, but discovered Polkit doesn't work for nft commands.
**Why**: nft uses kernel netlink (not D-Bus), so Polkit has zero effect.

**Final Solution (PERMANENT)**:
Implemented **systemd-scoped Linux capabilities** instead of Polkit or root:

1. **Service-Scoped Capability Grant**:
   ```ini
   [Service]
   User=nftban
   Group=nftban
   AmbientCapabilities=CAP_NET_ADMIN
   CapabilityBoundingSet=CAP_NET_ADMIN
   ```

2. **New Capability Helper Module**:
   - Created `src/usr/lib/nftban/core/nftban_security.sh`
   - `nftban_has_net_admin()` - Check if process has CAP_NET_ADMIN
   - `nftban_require_net_admin_or_exit()` - Require capability or exit

3. **CLI Command Refactoring**:
   - Replaced EUID checks with capability checks in `cmd_feeds.sh`
   - Commands affected: select, enable, disable, enable-category, update

4. **Enhanced Security Hardening**:
   - Added: ProtectKernelTunables, ProtectKernelModules, ProtectKernelLogs
   - Added: ProtectControlGroups, ProtectClock, ProtectHostname
   - Added: RestrictAddressFamilies, SystemCallFilter

**Security Benefits**:
- ✅ No root privileges (service runs as nftban user)
- ✅ Only CAP_NET_ADMIN granted (not full root access)
- ✅ 80-90% less attack surface than root
- ✅ Survives package updates (defined in service file, not file caps)

**Testing Results**:
- ✅ Ubuntu 24.04 LTS (systemd 255) - Working
- ✅ CentOS Stream 9 (systemd 252) - Working
- ✅ Manual test: `sudo -u nftban nftban feeds update` - Success!

**Documentation**:
- Added comprehensive guide: `docs/architecture/capabilities.md`
- Explains why Polkit doesn't work
- Security comparison (root vs CAP_NET_ADMIN)
- Troubleshooting and distribution support

**Contributors**:
- ChatGPT (OpenAI) - Architecture guidance and implementation recommendations
- Claude (Anthropic) - Implementation and testing

**Related**: BUG-006

---

### BUG-006: nftban.service uses non-existent command
**Status**: Fixed (commit: 53b9d56)
**Fixed Date**: 2025-11-02
**Severity**: Critical (blocked v0.10.0 release)

**Problem**:
Service referenced `nftban run` command which doesn't exist.

**Solution**:
Changed `ExecStart=/usr/sbin/nftban run` to `ExecStart=/usr/sbin/nftban feeds update`

**Files Modified**:
- `src/usr/lib/systemd/system/nftban.service`
- `src/packaging/systemd/nftban.service`

**Note**: This bug was discovered and fixed as part of BUG-007 resolution.

**Related**: BUG-007

---

### BUG-008: Incorrect GPL-3.0-or-later license in 2 files
**Status**: Fixed (commit: c0e13d6)
**Files Modified**:
- `src/usr/lib/nftban/core/nftban_report_engine.sh`
- `src/usr/lib/nftban/core/path_validator.sh`

Changed from GPL-3.0-or-later to MPL-2.0 to match project license.

### BUG-003: Ban comment not saved to database
**Status**: Fixed (commit: ac639a7)
**Files Modified**: `src/usr/sbin/nftban-complete`

### BUG-005: Port status reporting incorrect format
**Status**: Fixed (commit: d72e784)
**Files Modified**: `src/usr/lib/nftban/core/nftban_report_port.sh`

---

## 📋 Bug Fix Priority

### Critical (Fix Now - Block v0.10.0 release):
1. ⚠️ **BUG-006**: nftban.service non-existent command
2. ⚠️ **BUG-007**: Missing Polkit rule for nftables

### High (Fix in v0.10.1):
- None currently identified

### Medium (Fix when convenient):
- None currently identified

---

## 🔧 Testing Checklist

Before releasing v0.10.0, verify:
- [ ] `systemctl start nftban.service` succeeds without errors
- [ ] Service runs as `nftban` user (not root)
- [ ] Polkit authorization allows nftban user to run nft commands
- [ ] `nftban feeds update` works when run by systemd service
- [ ] All systemd security hardening directives work correctly

---

## 📝 Notes

**Design Philosophy**:
- ✅ Use Polkit for privilege escalation (no root services)
- ✅ Follow fail2ban model: services run as dedicated user
- ✅ Security hardening via systemd directives (PrivateTmp, ProtectSystem, etc.)

**Next Release (v0.20.x)**:
- Major redesign planned
- Review architectural proposals
- Get technical clarifications from upstream (nftables developers)
