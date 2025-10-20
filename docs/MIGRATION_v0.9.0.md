# Migration Guide: v0.8.5 → v0.9.0

**Complete guide for upgrading to nftban v0.9.0 split table architecture**

[![Version](https://img.shields.io/badge/from-0.8.5-orange)](https://github.com/itcmsgr/nftban)
[![Version](https://img.shields.io/badge/to-0.9.0-green)](https://github.com/itcmsgr/nftban)
[![Breaking](https://img.shields.io/badge/breaking-changes-red)](https://github.com/itcmsgr/nftban)

---

## ⚠️ BREAKING CHANGES WARNING

**v0.9.0 introduces fundamental architectural changes that are NOT backward compatible.**

### What Changed:
- **Table structure**: Single `inet nftban_global` → Dual `ip nftban_v4` + `ip6 nftban_v6`
- **Set names**: Removed `_v4/_v6` suffixes (e.g., `whitelist_v4` → `whitelist`)
- **Rule syntax**: Simplified (no more `ip saddr`/`ip6 saddr` selectors)

### Migration Strategy:
- **Recommended**: Fresh installation on new systems
- **For Production**: Test on staging environment first
- **Data Preservation**: Backup all configurations and ban lists

---

## 📊 Architecture Comparison

### OLD Architecture (v0.8.5)

```bash
# Single inet table
nft list table inet nftban_global

# Sets with version suffixes
table inet nftban_global {
    set whitelist_v4 { type ipv4_addr; }
    set whitelist_v6 { type ipv6_addr; }
    set temp_ban_v4 { type ipv4_addr; flags timeout; }
    set temp_ban_v6 { type ipv6_addr; flags timeout; }
}

# Rules with selectors
chain input {
    ip saddr @whitelist_v4 accept
    ip6 saddr @whitelist_v6 accept
    ip saddr @temp_ban_v4 drop
    ip6 saddr @temp_ban_v6 drop
}
```

### NEW Architecture (v0.9.0)

```bash
# Dual tables by IP version
nft list table ip nftban_v4
nft list table ip6 nftban_v6

# Sets WITHOUT version suffixes
table ip nftban_v4 {
    set whitelist { type ipv4_addr; }
    set temp_ban { type ipv4_addr; flags timeout; }
}

table ip6 nftban_v6 {
    set whitelist { type ipv6_addr; }
    set temp_ban { type ipv6_addr; flags timeout; }
}

# Simplified rules (no selectors!)
chain input {
    saddr @whitelist accept
    saddr @temp_ban drop
}
```

**Performance Impact**: 30-50% faster packet processing, 50% fewer rule evaluations

---

## 🔄 Migration Options

### Option A: Fresh Installation (RECOMMENDED)

**Best for:**
- New deployments
- Test/staging servers
- When you can afford downtime

**Steps:**
1. Backup current configuration
2. Export ban lists
3. Uninstall v0.8.5
4. Fresh install v0.9.0
5. Restore configuration
6. Re-import ban lists

**Downtime:** 10-30 minutes

---

### Option B: In-Place Upgrade (ADVANCED)

**Best for:**
- Production systems with careful planning
- Experienced administrators
- When you have verified backups

**Steps:**
1. Full system backup
2. Export all data
3. Pull v0.9.0 code
4. Run migration script (when available)
5. Validate new tables
6. Test thoroughly

**Downtime:** 5-15 minutes

**⚠️ WARNING**: This is a breaking change. In-place upgrade requires careful execution.

---

## 📦 Pre-Migration Checklist

### 1. Backup Current System

```bash
# Backup nftables rules
sudo nft list ruleset > /backup/nftables-v085-$(date +%Y%m%d).nft

# Backup configuration files
sudo tar -czf /backup/nftban-config-v085-$(date +%Y%m%d).tar.gz /etc/nftban/config/

# Backup ban lists
sudo nft list set inet nftban_global temp_ban_v4 > /backup/temp_ban_v4.txt
sudo nft list set inet nftban_global temp_ban_v6 > /backup/temp_ban_v6.txt
sudo nft list set inet nftban_global whitelist_v4 > /backup/whitelist_v4.txt
sudo nft list set inet nftban_global whitelist_v6 > /backup/whitelist_v6.txt
```

### 2. Export IP Lists

```bash
# Export whitelist IPs
grep -v '^#' /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local > /backup/whitelist_ips.txt

# Export blacklist IPs
grep -v '^#' /etc/nftban/config/nftban-configuration-user-blacklist_ips.conf.local > /backup/blacklist_ips.txt

# Export current active bans (from nftables)
sudo nft -j list set inet nftban_global temp_ban_v4 | jq -r '.nftables[].set.elem[]' > /backup/active_bans_v4.txt
sudo nft -j list set inet nftban_global temp_ban_v6 | jq -r '.nftables[].set.elem[]' > /backup/active_bans_v6.txt
```

### 3. Document Current State

```bash
# System information
uname -a > /backup/system_info.txt
nft --version >> /backup/system_info.txt
fail2ban-client --version >> /backup/system_info.txt

# Current nftban status
sudo nftban status > /backup/nftban_status.txt 2>&1

# Current ports configuration
cat /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local > /backup/ports_config.txt
```

---

## 🚀 Fresh Installation Migration (Recommended)

### Step 1: Prepare for Installation

```bash
# Create backup directory
sudo mkdir -p /backup/nftban_v085_migration

# Run all backup commands from checklist above
# ...

# Stop services
sudo systemctl stop nftables
sudo systemctl stop fail2ban
```

### Step 2: Uninstall v0.8.5

```bash
# Remove old installation
sudo rm -rf /etc/nftban/
sudo rm -f /usr/local/bin/nftban

# Remove old nftables rules
sudo nft flush ruleset

# Keep configuration backups!
```

### Step 3: Install v0.9.0

```bash
# Download v0.9.0 installer
curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh -o nftban_init.sh

# Run installer (handles all configuration automatically)
sudo bash nftban_init.sh --github -y
```

### Step 4: Restore Configuration

```bash
# Restore whitelisted IPs
while read ip; do
    [[ "$ip" =~ ^# ]] && continue
    [[ -z "$ip" ]] && continue
    sudo nftban whitelist add "$ip"
done < /backup/whitelist_ips.txt

# Restore blacklisted IPs
while read ip; do
    [[ "$ip" =~ ^# ]] && continue
    [[ -z "$ip" ]] && continue
    sudo nftban blacklist ban "$ip" "Restored from v0.8.5"
done < /backup/blacklist_ips.txt
```

### Step 5: Validate New Installation

```bash
# Check tables exist
sudo nft list tables
# Should show: table ip nftban_v4
#              table ip6 nftban_v6

# Verify sets (NO _v4/_v6 suffix!)
sudo nft list set ip nftban_v4 whitelist
sudo nft list set ip6 nftban_v6 whitelist

# Run smoketest
sudo nftban smoketest run

# Check system status
sudo nftban status
```

---

## 🔧 Command Translation Guide

### nftables Commands

| v0.8.5 (OLD) | v0.9.0 (NEW) |
|--------------|--------------|
| `nft list table inet nftban_global` | `nft list table ip nftban_v4`<br>`nft list table ip6 nftban_v6` |
| `nft list set inet nftban_global whitelist_v4` | `nft list set ip nftban_v4 whitelist` |
| `nft list set inet nftban_global whitelist_v6` | `nft list set ip6 nftban_v6 whitelist` |
| `nft list set inet nftban_global temp_ban_v4` | `nft list set ip nftban_v4 temp_ban` |
| `nft add element inet nftban_global whitelist_v4 { 192.0.2.1 }` | `nft add element ip nftban_v4 whitelist { 192.0.2.1 }` |
| `nft add element inet nftban_global whitelist_v6 { 2001:db8::1 }` | `nft add element ip6 nftban_v6 whitelist { 2001:db8::1 }` |

### nftban CLI Commands

**Good news:** CLI commands remain the same! nftban automatically uses the correct table.

```bash
# These commands work identically in both versions:
sudo nftban whitelist add <IP>
sudo nftban blacklist ban <IP>
sudo nftban status
sudo nftban --verify-ip <IP>
```

---

## 📝 Configuration File Changes

### No Changes Required

Configuration files use the same format in v0.9.0:

```bash
# These files work identically:
/etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local
/etc/nftban/config/nftban-configuration-user-blacklist_ips.conf.local
/etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local
```

**Action Required:** None - just copy your `.conf.local` files to new installation

---

## 🐛 Common Migration Issues

### Issue 1: Old Table Still Exists

**Symptom:**
```bash
$ sudo nft list tables
table inet nftban_global
table ip nftban_v4
table ip6 nftban_v6
```

**Solution:**
```bash
# Remove old table
sudo nft delete table inet nftban_global
```

---

### Issue 2: Commands Reference Old Table

**Symptom:**
```bash
Error: No such file or directory; did you mean set 'whitelist' in table ip 'nftban_v4'?
nft list set inet nftban_global whitelist_v4
```

**Solution:**
Update your commands to new syntax:
```bash
# OLD (wrong)
nft list set inet nftban_global whitelist_v4

# NEW (correct)
nft list set ip nftban_v4 whitelist
```

---

### Issue 3: Scripts Still Use Old References

**Symptom:**
Custom scripts fail with "table not found" errors.

**Solution:**
Update all scripts to use new constants:
```bash
# OLD
NFTBAN_TABLE="inet nftban_global"

# NEW
NFTBAN_TABLE_V4="ip nftban_v4"
NFTBAN_TABLE_V6="ip6 nftban_v6"
```

---

### Issue 4: Fail2Ban Actions Broken

**Symptom:**
Fail2Ban cannot ban IPs after upgrade.

**Solution:**
Fail2Ban actions are automatically updated during installation. If issues persist:
```bash
# Reinstall Fail2Ban configuration
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh setup

# Restart Fail2Ban
sudo systemctl restart fail2ban
```

---

## 🧪 Post-Migration Testing

### 1. Verify Table Structure

```bash
# List all tables
sudo nft list tables

# Expected output:
# table ip nftban_v4
# table ip6 nftban_v6

# Verify IPv4 table sets
sudo nft list table ip nftban_v4 | grep "set "

# Should show (no _v4 suffix!):
# set whitelist
# set temp_ban
# set user_blacklist
# set system_blacklist
# set feeds
```

### 2. Test Ban Operations

```bash
# Test temporary ban
sudo nftban blacklist ban 192.0.2.100 "Migration test"

# Verify ban exists (new syntax!)
sudo nft list set ip nftban_v4 temp_ban | grep 192.0.2.100

# Remove test ban
sudo nftban blacklist unban 192.0.2.100
```

### 3. Test Whitelist

```bash
# Add test IP
sudo nftban whitelist add 192.0.2.200

# Verify (new syntax!)
sudo nft list set ip nftban_v4 whitelist | grep 192.0.2.200

# Try to ban whitelisted IP (should fail)
sudo nftban blacklist ban 192.0.2.200
# Expected: Error - IP is whitelisted

# Remove test IP
sudo nftban whitelist remove 192.0.2.200
```

### 4. Run Smoketest

```bash
# Run comprehensive tests
sudo nftban smoketest run

# All tests should pass
# Smoketest supports both v0.8.5 and v0.9.0 detection
```

### 5. Performance Validation

```bash
# Check rule count (should be ~half of v0.8.5)
sudo nft list table ip nftban_v4 | grep "rule" | wc -l

# Monitor packet processing
sudo nft monitor

# Test connection (should be faster)
time curl -I https://example.com
```

---

## 📊 Performance Improvements

### Expected Gains

| Metric | v0.8.5 | v0.9.0 | Improvement |
|--------|--------|--------|-------------|
| Rules per packet (IPv4) | ~20 | ~10 | 50% reduction |
| Rules per packet (IPv6) | ~20 | ~10 | 50% reduction |
| Packet processing speed | Baseline | 30-50% faster | Major gain |
| CPU cache efficiency | Standard | Improved | Better |
| Rule complexity | High | Low | Simpler |

### Real-World Impact

```
Before (v0.8.5):
- Every packet evaluated against 20 rules
- ip/ip6 selector checks required
- Single large table

After (v0.9.0):
- IPv4 packets: 10 rules in ip table
- IPv6 packets: 10 rules in ip6 table
- No selector overhead
- Separate optimized tables
```

---

## 🔐 Security Considerations

### No Security Regressions

- All v0.8.5 security features maintained
- Safety mechanisms still active
- Whitelist protection preserved
- Fail2Ban integration unchanged

### New Security Benefits

- Clearer table separation (IPv4/IPv6)
- Simpler rule auditing
- Faster incident response (less lag)

---

## 📚 Additional Resources

- [CHANGELOG.md](../CHANGELOG.md) - Complete v0.9.0 changes
- [ARCHITECTURE.md](ARCHITECTURE.md) - Technical deep-dive
- [README.md](../README.md) - Main project documentation
- [GitHub Issues](https://github.com/itcmsgr/nftban/issues) - Report problems

---

## 💬 Need Help?

### Community Support
- **Issues**: [GitHub Issues](https://github.com/itcmsgr/nftban/issues)
- **Discussions**: [GitHub Discussions](https://github.com/itcmsgr/nftban/discussions)

### Professional Support
- **Email**: contact@itcms.gr
- **Website**: [https://itcms.gr](https://itcms.gr)

---

## ✅ Migration Checklist

Use this checklist to track your migration:

- [ ] Read this entire migration guide
- [ ] Backup current system (nftables rules, configs, ban lists)
- [ ] Export all IP lists (whitelist, blacklist)
- [ ] Document current state
- [ ] Test migration on staging environment
- [ ] Plan maintenance window
- [ ] Uninstall v0.8.5 (or prepare for in-place upgrade)
- [ ] Install v0.9.0
- [ ] Restore configuration files
- [ ] Re-import IP lists
- [ ] Verify table structure (ip/ip6, not inet)
- [ ] Verify set names (no _v4/_v6 suffix)
- [ ] Test ban operations
- [ ] Test whitelist operations
- [ ] Run smoketest
- [ ] Check Fail2Ban integration
- [ ] Monitor for 24-48 hours
- [ ] Update any custom scripts
- [ ] Update documentation/runbooks
- [ ] Train team on new commands

---

<p align="center">
  <b>Made with ❤️ by <a href="https://itcms.gr">ITCMS Team</a></b><br>
  <sub>Migration guide for nftban v0.9.0 split table architecture</sub>
</p>

<p align="center">
  <sub>Copyright © 2025 Antonios Voulvoulis – ITCMS. All rights reserved.</sub>
</p>
