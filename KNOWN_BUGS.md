# NFTBan v0.10.0 - Known Bugs

**Last Updated**: 2025-11-02

## 🐛 Active Bugs

### BUG-006: nftban.service uses non-existent command
**Severity**: High  
**Status**: Identified  
**Component**: systemd service  

**Description**:
The `nftban.service` unit file references `nftban run` which does not exist.

**Error**:
```
ERROR: Unknown command 'run'
Run 'nftban help' for available commands
```

**Files Affected**:
- `src/usr/lib/systemd/system/nftban.service` (line 10)
- `src/packaging/systemd/nftban.service` (line 10)

**Current Code**:
```ini
ExecStart=/usr/sbin/nftban run
User=nftban
Group=nftban
```

**Root Cause**:
The `run` command was never implemented. The service is triggered by `nftban.timer` (hourly) and should update threat feeds.

**Proposed Fix**:
```ini
ExecStart=/usr/sbin/nftban feeds update
User=nftban
Group=nftban
```

**Issue**: The `nftban` user needs Polkit authorization to run `nft` commands (for feeds update).

**Related**: BUG-007

---

### BUG-007: Missing Polkit rule for nftables commands
**Severity**: High  
**Status**: Identified  
**Component**: Polkit authorization  

**Description**:
The `nftban` system user cannot execute `nft` commands because there's no Polkit rule authorizing it.

**Error**:
```
ERROR: 'feeds update' requires root privileges
```

**Current Polkit Rules**:
- ✅ `60-nftban-cli.rules` - Allows `nftban-cli` group to manage services
- ❌ Missing rule for `nftban` user to run nftables commands

**Required Polkit Rule** (similar to fail2ban approach):
```javascript
// Allow nftban system user to run nftables commands
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.policykit.exec") &&
        (subject.user == "nftban")) {
        return polkit.Result.YES;
    }
});
```

**Alternative Approach**:
Create a specific Polkit action for nftables commands and authorize the `nftban` user.

**Files to Create/Modify**:
- `/usr/share/polkit-1/rules.d/61-nftban-system.rules`

**Related**: BUG-006

---

## ✅ Fixed Bugs

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
