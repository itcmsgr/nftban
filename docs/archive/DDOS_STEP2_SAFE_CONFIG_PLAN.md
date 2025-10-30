# DDOS Step 2: Safe Config Implementation - Detailed Plan
**Date:** 2025-10-30
**Status:** Planning Phase
**Goal:** Make DDOS protection safe by default with user-controlled enable

---

## 🎯 OBJECTIVES

1. **Comment ALL aggressive limits** in default config
2. **Preserve all settings** but make them opt-in (remove #)
3. **Maintain backward compatibility** (existing users keep their config)
4. **Clear instructions** on how to enable
5. **Reload mechanism** that works correctly

---

## 📋 STEP 2 BREAKDOWN

### 2.1 Update Default Config File

**File:** `/etc/nftban/conf.d/ddos.conf`

**Current State Analysis:**
```bash
# Currently has these ACTIVE (enabled):
DDOS_PROTECTION_ENABLED="true"        # Master switch - OK to keep
DDOS_CONNLIMIT_SSH="5"               # ❌ TOO LOW - needs comment
DDOS_CONNLIMIT_HTTP="20"             # ❌ TOO LOW - needs comment
DDOS_CONNLIMIT_HTTPS="20"            # ❌ TOO LOW - needs comment
DDOS_CONNLIMIT_SMTP="5"              # ❌ TOO LOW - needs comment
DDOS_PORTFLOOD_SSH="5/300"           # ❌ TOO AGGRESSIVE - needs comment
DDOS_PORTFLOOD_HTTP="20/5"           # ❌ TOO AGGRESSIVE - needs comment
```

**Target State:**
```bash
# Master switch - keep enabled but protections are off
DDOS_PROTECTION_ENABLED="true"

# All limits COMMENTED with recommended values
#DDOS_CONNLIMIT_SSH="10"              # Remove # to enable (Recommended: 10-20)
#DDOS_CONNLIMIT_HTTP="150"            # Remove # to enable (Recommended: 150-300)
#DDOS_CONNLIMIT_HTTPS="150"           # Remove # to enable (Recommended: 150-300)
#DDOS_CONNLIMIT_SMTP="25"             # Remove # to enable (Recommended: 25-100)
#DDOS_CONNLIMIT_IMAP="60"             # Remove # to enable (Recommended: 60-200)
#DDOS_CONNLIMIT_POP3="30"             # Remove # to enable (Recommended: 30-100)
```

**Strategy:**
- ✅ Keep `DDOS_PROTECTION_ENABLED="true"` (master switch for module load)
- ✅ Comment all specific limits (no actual blocking)
- ✅ Update values to SAFE defaults when user enables
- ✅ Add inline comments with recommended ranges

---

### 2.2 Config File Structure

**New structure:**
```bash
# ═══════════════════════════════════════════════════════════════
# PART 1: MASTER SWITCH (Keep enabled)
# ═══════════════════════════════════════════════════════════════
DDOS_PROTECTION_ENABLED="true"       # Module loaded but no limits active

# ═══════════════════════════════════════════════════════════════
# PART 2: WHITELIST (Critical - Configure FIRST!)
# ═══════════════════════════════════════════════════════════════
#
# ⚠️  ALWAYS configure whitelist BEFORE enabling any limits!
#
# Add: localhost, private networks, office IP, CDN IPs
#DDOS_WHITELIST="127.0.0.1,::1,10.0.0.0/8,192.168.0.0/16"
#DDOS_OFFICE_IPS=""
#DDOS_CDN_IPS=""

# ═══════════════════════════════════════════════════════════════
# PART 3: CONNECTION LIMITS (All DISABLED by default)
# ═══════════════════════════════════════════════════════════════
#
# Remove # from lines below to enable specific limits
# After changes: nftban ddos reload
#
# Recommended values by server type:
#   Multi-site hosting: HTTP=300, SSH=20, SMTP=40, IMAP=120
#   Single business:    HTTP=150, SSH=10, SMTP=25, IMAP=60
#   API/proxy:          HTTP=100, SSH=8,  SMTP=15, IMAP=30
#

# ─────────────────────────────────────────────────────────────
# SSH (Port 22)
# ─────────────────────────────────────────────────────────────
# Recommended: 10 (small team), 15 (medium team), 20 (large team)
#DDOS_CONNLIMIT_SSH="10"

# ─────────────────────────────────────────────────────────────
# HTTP/HTTPS (Ports 80, 443)
# ─────────────────────────────────────────────────────────────
# Recommended: 150 (single site), 250 (multi-site), 300 (hosting)
#DDOS_CONNLIMIT_HTTP="150"
#DDOS_CONNLIMIT_HTTPS="150"

# ─────────────────────────────────────────────────────────────
# SMTP (Port 25 - Outgoing Mail)
# ─────────────────────────────────────────────────────────────
# Recommended: 25 (small office), 40 (medium office), 100 (large)
#DDOS_CONNLIMIT_SMTP="25"

# ─────────────────────────────────────────────────────────────
# IMAP (Port 143, 993 - Incoming Mail)
# ─────────────────────────────────────────────────────────────
# Recommended: 60 (standard), 100 (multi-account), 200 (office)
#DDOS_CONNLIMIT_IMAP="60"

# ─────────────────────────────────────────────────────────────
# POP3 (Port 110, 995)
# ─────────────────────────────────────────────────────────────
# Recommended: 30 (standard), 60 (multi-account), 100 (office)
#DDOS_CONNLIMIT_POP3="30"

# ═══════════════════════════════════════════════════════════════
# PART 4: RATE LIMITS (Advanced - Usually not needed)
# ═══════════════════════════════════════════════════════════════
#
# Port flood protection - rate limit new connections
# Format: connections/seconds
# Only enable if under active attack!
#

#DDOS_PORTFLOOD_SSH="10/60"          # 10 new SSH conns per 60 sec
#DDOS_PORTFLOOD_HTTP="100/5"         # 100 new HTTP conns per 5 sec
#DDOS_PORTFLOOD_HTTPS="100/5"        # 100 new HTTPS conns per 5 sec
#DDOS_PORTFLOOD_SMTP="20/60"         # 20 new SMTP conns per 60 sec

# ═══════════════════════════════════════════════════════════════
# QUICK START GUIDE
# ═══════════════════════════════════════════════════════════════
#
# 1. Configure whitelist (REQUIRED!)
#    Uncomment and set:
#    DDOS_WHITELIST="127.0.0.1,::1,YOUR_OFFICE_IP"
#
# 2. Enable limits by removing #
#    Example for single business site:
#    DDOS_CONNLIMIT_HTTP="150"
#    DDOS_CONNLIMIT_SSH="10"
#    DDOS_CONNLIMIT_SMTP="25"
#
# 3. Reload configuration
#    nftban ddos reload
#
# 4. Monitor for blocks
#    nftban ddos stats
#    tail -f /var/log/nftban/ddos-blocks.log
#
# 5. Adjust as needed based on monitoring
#
# For auto-detection: nftban ddos autotune
# See full guide: /usr/share/doc/nftban/DDOS_COMPLETE_GUIDE.md
#
# ═══════════════════════════════════════════════════════════════
```

---

### 2.3 Module Behavior When Limits Are Commented

**Current Module:** `/usr/lib/nftban/core/nftban_ddos.sh`

**Need to handle:**
```bash
# When variable is unset or empty, skip that rule
if [[ -n "${DDOS_CONNLIMIT_SSH:-}" && "${DDOS_CONNLIMIT_SSH}" != "0" ]]; then
    # Apply SSH connection limit
    nft add rule inet nftban input tcp dport 22 ct count over ${DDOS_CONNLIMIT_SSH} drop
fi
```

**Logic:**
1. Check if variable exists and is not empty: `${DDOS_CONNLIMIT_SSH:-}`
2. Check if not explicitly disabled (0): `!= "0"`
3. Only then apply the limit

**This means:**
- Commented line → variable unset → no rule created ✅
- `DDOS_CONNLIMIT_SSH="10"` → rule created with limit 10 ✅
- `DDOS_CONNLIMIT_SSH="0"` → explicitly disabled, no rule ✅

---

### 2.4 Reload Mechanism

**Command:** `nftban ddos reload`

**What it does:**
```bash
nftban_ddos_reload() {
    echo "Reloading DDOS configuration..."

    # 1. Source the config file
    source /etc/nftban/conf.d/ddos.conf

    # 2. Show what changed
    echo ""
    echo "Configuration status:"

    # Check each limit
    if [[ -n "${DDOS_CONNLIMIT_SSH:-}" ]]; then
        echo "  ✅ SSH limit enabled: ${DDOS_CONNLIMIT_SSH} connections per IP"
    else
        echo "  ⚪ SSH limit disabled (commented or not set)"
    fi

    if [[ -n "${DDOS_CONNLIMIT_HTTP:-}" ]]; then
        echo "  ✅ HTTP limit enabled: ${DDOS_CONNLIMIT_HTTP} connections per IP"
    else
        echo "  ⚪ HTTP limit disabled (commented or not set)"
    fi

    # ... check other limits

    # 3. Flush old DDOS rules
    echo ""
    echo "Removing old DDOS rules..."
    nft flush chain inet nftban ddos_limits 2>/dev/null || true

    # 4. Apply new rules (only for enabled limits)
    echo "Applying new rules..."
    nftban_ddos_apply_rules

    # 5. Verify
    echo ""
    echo "✅ Reload complete!"
    echo ""
    echo "Monitor blocks: nftban ddos stats"
    echo "View logs: tail -f /var/log/nftban/ddos-blocks.log"
}
```

**Output example:**
```bash
$ nftban ddos reload

Reloading DDOS configuration...

Configuration status:
  ✅ SSH limit enabled: 10 connections per IP
  ✅ HTTP limit enabled: 150 connections per IP
  ⚪ HTTPS limit disabled (commented or not set)
  ✅ SMTP limit enabled: 25 connections per IP
  ⚪ IMAP limit disabled (commented or not set)

Removing old DDOS rules...
Applying new rules...
  ✅ SSH rule added
  ✅ HTTP rule added
  ✅ SMTP rule added

✅ Reload complete!

Monitor blocks: nftban ddos stats
View logs: tail -f /var/log/nftban/ddos-blocks.log
```

---

### 2.5 Backward Compatibility

**Problem:** Existing users have active configs

**Solution:**
```bash
# On package update, check if config has been modified
if [[ -f /etc/nftban/conf.d/ddos.conf ]]; then
    # Calculate checksum of current config
    current_md5=$(md5sum /etc/nftban/conf.d/ddos.conf | cut -d' ' -f1)

    # Compare with default package checksum
    if [[ "$current_md5" != "$default_md5" ]]; then
        # User has custom config - preserve it
        echo "⚠️  Custom DDOS config detected - preserving your settings"
        echo ""
        echo "IMPORTANT: Review your current limits:"
        echo "  nftban ddos show"
        echo ""
        echo "Consider running auto-tune for optimized values:"
        echo "  nftban ddos autotune"
        echo ""
        echo "See guide: /usr/share/doc/nftban/DDOS_COMPLETE_GUIDE.md"

        # Create backup
        cp /etc/nftban/conf.d/ddos.conf /etc/nftban/conf.d/ddos.conf.backup-$(date +%Y%m%d)
    else
        # Using default config - safe to update
        echo "Updating DDOS config to new safe defaults..."
        # Install new commented config
    fi
fi
```

---

### 2.6 Testing Plan

**Test 1: Fresh Install**
```bash
# Expected: All limits commented, no blocking
1. Install NFTBan
2. Check config: grep -v '^#' /etc/nftban/conf.d/ddos.conf
3. Expected: Only DDOS_PROTECTION_ENABLED="true"
4. Test: curl localhost (should work unlimited)
5. Test: Multiple SSH connections (should work unlimited)
```

**Test 2: Enable Single Limit**
```bash
1. Edit config: vi /etc/nftban/conf.d/ddos.conf
2. Uncomment: DDOS_CONNLIMIT_SSH="10"
3. Reload: nftban ddos reload
4. Test: Open 11 SSH connections
5. Expected: 11th connection blocked
6. Check: nftban ddos stats (should show 1 block)
```

**Test 3: Reload Changes Existing Connections**
```bash
1. Enable SSH limit: DDOS_CONNLIMIT_SSH="5"
2. Open 3 SSH connections
3. Change limit: DDOS_CONNLIMIT_SSH="10"
4. Reload: nftban ddos reload
5. Expected: Existing 3 connections remain open
6. Expected: Can open 7 more (total 10)
```

**Test 4: Whitelist Works**
```bash
1. Enable HTTP limit: DDOS_CONNLIMIT_HTTP="10"
2. Set whitelist: DDOS_WHITELIST="127.0.0.1,::1"
3. Reload: nftban ddos reload
4. Test from localhost: Open 20 HTTP connections
5. Expected: All 20 allowed (whitelisted)
6. Test from remote IP: Open 11 connections
7. Expected: 11th blocked
```

---

### 2.7 Migration Script for Existing Users

**File:** `/usr/lib/nftban/scripts/migrate-ddos-config.sh`

```bash
#!/bin/bash
# Migrate existing DDOS config to new safe defaults

echo "NFTBan DDOS Configuration Migration"
echo ""

# Check if config has aggressive defaults
if grep -q 'DDOS_CONNLIMIT_SSH="5"' /etc/nftban/conf.d/ddos.conf; then
    echo "⚠️  Detected old aggressive defaults!"
    echo ""
    echo "Current limits are TOO LOW and may block legitimate users:"
    echo "  SSH: 5 (should be 10-20)"
    echo "  HTTP: 20 (should be 150-300)"
    echo "  SMTP: 5 (should be 25-100)"
    echo ""
    echo "Recommended action:"
    echo "  1. Run auto-tune: nftban ddos autotune"
    echo "  2. Review suggestions"
    echo "  3. Apply recommended profile"
    echo ""
    echo "Or manually update /etc/nftban/conf.d/ddos.conf"
    echo ""

    # Ask if user wants auto-migration
    read -p "Run auto-tune now? (y/n): " answer
    if [[ "$answer" == "y" ]]; then
        nftban ddos autotune
    fi
else
    echo "✅ Configuration looks OK"
fi
```

---

## 📝 IMPLEMENTATION CHECKLIST

### Files to Modify:

- [ ] `/etc/nftban/conf.d/ddos.conf` - Comment all limits, update values
- [ ] `/usr/lib/nftban/core/nftban_ddos.sh` - Add checks for unset variables
- [ ] `/usr/lib/nftban/cli/cmd_ddos.sh` - Improve reload command output
- [ ] `/usr/lib/nftban/scripts/migrate-ddos-config.sh` - New migration script

### Commands to Test:

- [ ] `nftban ddos reload` - Reload with changes shown
- [ ] `nftban ddos show` - Show current active limits
- [ ] `nftban ddos status` - Status of protection
- [ ] `nftban ddos test` - Dry-run config validation

### Documentation to Update:

- [ ] `/usr/share/doc/nftban/DDOS_COMPLETE_GUIDE.md` - Already created ✅
- [ ] `README.md` - Add DDOS section
- [ ] `man nftban-ddos` - Man page

---

## 🎯 EXPECTED OUTCOMES

**After Step 2 Complete:**

1. ✅ Fresh installs have NO limits active (all commented)
2. ✅ Users must explicitly enable limits (remove #)
3. ✅ Reload shows clear status of what's enabled/disabled
4. ✅ Existing users warned about aggressive defaults
5. ✅ Backward compatible (keeps custom configs)
6. ✅ Clear instructions in config file
7. ✅ Safe defaults when enabled (150/10/25 not 20/5/5)

---

## ⏱️ ESTIMATED TIME

- Config file update: 30 min
- Module logic update: 1 hour
- Reload command improvements: 1 hour
- Testing: 2 hours
- Documentation: 1 hour

**Total: ~5-6 hours**

---

**Ready to implement? Y/N**

**EOF**
