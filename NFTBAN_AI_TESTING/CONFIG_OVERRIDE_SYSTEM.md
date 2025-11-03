# NFTBan Configuration Override System

**Status:** ✅ Fully implemented and documented
**Version:** v0.30.0

---

## Overview

NFTBan uses a **hierarchical configuration system** with `.local` file overrides that are **preserved during upgrades**.

---

## Configuration Loading Order

```
1. /etc/nftban/nftban.conf              (Main config)
2. /etc/nftban/conf.d/health.conf       (Health module defaults)
3. /etc/nftban/conf.d/health.conf.local (Health module overrides) ← Safe to edit!
4. /etc/nftban/conf.d/mail.conf         (Mail module defaults)
5. /etc/nftban/conf.d/mail.conf.local   (Mail module overrides)   ← Safe to edit!
6. ... (all other conf.d/*.conf files)
7. /etc/nftban/nftban.conf.local        (Global overrides)        ← Highest priority!
```

**Priority:** Later files override earlier files

---

## The Rules

### ❌ **DO NOT EDIT:**
- `/etc/nftban/nftban.conf` (replaced during upgrades)
- `/etc/nftban/conf.d/*.conf` (replaced during upgrades)

### ✅ **SAFE TO EDIT:**
- `/etc/nftban/conf.d/*.conf.local` (preserved during upgrades)
- `/etc/nftban/nftban.conf.local` (preserved during upgrades)

---

## Quick Examples

### Example 1: Override Health Check Thresholds

```bash
# Create health.conf.local
cat > /etc/nftban/conf.d/health.conf.local <<'EOF'
# Production - conservative thresholds
NFTBAN_DISK_WARN_THRESHOLD=80
NFTBAN_DISK_CRIT_THRESHOLD=90
NFTBAN_ALERT_THROTTLE_SECONDS=7200  # 2 hours
EOF

# Test
nftban health check
```

### Example 2: Override Mail Settings

```bash
# Create mail.conf.local
cat > /etc/nftban/conf.d/mail.conf.local <<'EOF'
# Production mail settings
NFTBAN_MAIL_TO="ops-team@example.com"
NFTBAN_MAIL_FROM="nftban@prod.example.com"
NFTBAN_MAIL_ENABLED=1
EOF

# Test
source /usr/lib/nftban/core/nftban_mail_v030.sh
nftban_v030_mail_info
```

### Example 3: Global Override (Highest Priority)

```bash
# Create nftban.conf.local
cat > /etc/nftban/nftban.conf.local <<'EOF'
# Override ANY setting across all modules
NFTBAN_ALERT_THROTTLE_SECONDS=3600
NFTBAN_DISK_WARN_THRESHOLD=85
NFTBAN_MAIL_TO="admin@example.com"
EOF
```

---

## How Overrides Work

### Scenario: Customize Disk Warning Threshold

**Default** (`health.conf`):
```bash
NFTBAN_DISK_WARN_THRESHOLD=85
```

**Override** (`health.conf.local`):
```bash
NFTBAN_DISK_WARN_THRESHOLD=80  # More conservative
```

**Result:** Disk warnings trigger at 80% instead of 85%

---

## Configuration Priority

### Example with Multiple Files

```bash
# health.conf (default)
NFTBAN_DISK_WARN_THRESHOLD=85
NFTBAN_ALERT_THROTTLE_SECONDS=3600

# health.conf.local (override)
NFTBAN_DISK_WARN_THRESHOLD=80

# nftban.conf.local (global override)
NFTBAN_ALERT_THROTTLE_SECONDS=7200

# RESULT:
NFTBAN_DISK_WARN_THRESHOLD=80    # From health.conf.local
NFTBAN_ALERT_THROTTLE_SECONDS=7200  # From nftban.conf.local (highest priority)
```

---

## Templates & Examples

### Health Check Template

See: `/usr/share/doc/nftban/architecture/examples/health.conf.local.example`

```bash
# Copy template
cp /usr/share/doc/nftban/architecture/examples/health.conf.local.example \
   /etc/nftban/conf.d/health.conf.local

# Edit to your needs
vim /etc/nftban/conf.d/health.conf.local
```

### Common Overrides

#### Conservative Production
```bash
cat > /etc/nftban/conf.d/health.conf.local <<'EOF'
NFTBAN_DISK_WARN_THRESHOLD=80
NFTBAN_DISK_CRIT_THRESHOLD=90
NFTBAN_RAM_WARN_THRESHOLD=85
NFTBAN_CPU_WARN_THRESHOLD=75
NFTBAN_ALERT_THROTTLE_SECONDS=7200  # Alert max every 2 hours
EOF
```

#### Relaxed Development
```bash
cat > /etc/nftban/conf.d/health.conf.local <<'EOF'
NFTBAN_DISK_WARN_THRESHOLD=90
NFTBAN_RAM_WARN_THRESHOLD=93
NFTBAN_CPU_WARN_THRESHOLD=85
NFTBAN_ALERT_THROTTLE_SECONDS=1800  # Alert max every 30 min
EOF
```

#### Reduce Alert Frequency
```bash
cat > /etc/nftban/conf.d/health.conf.local <<'EOF'
NFTBAN_ALERT_THROTTLE_SECONDS=10800  # 3 hours
NFTBAN_ALERT_MAX_PER_DAY=8
EOF
```

---

## RPM Packaging

### Config File Handling

```spec
# Default config files (replaced on upgrade)
%attr(0640,root,nftban) /etc/nftban/conf.d/health.conf

# User config preserved on upgrade
%config(noreplace) %attr(0640,root,nftban) /etc/nftban/nftban.conf
```

**Note:** `.local` files are **never** installed by RPM - they are user-created and automatically preserved.

---

## Best Practices

### 1. **Use Per-Module .local Files**
```bash
# Good - specific override
/etc/nftban/conf.d/health.conf.local

# Also good - global override
/etc/nftban/nftban.conf.local
```

### 2. **Document Your Changes**
```bash
cat > /etc/nftban/conf.d/health.conf.local <<'EOF'
# Production server: web01.example.com
# Lowered thresholds due to high I/O workload
# Updated: 2025-11-03 by ops-team

NFTBAN_DISK_WARN_THRESHOLD=75
NFTBAN_DISK_CRIT_THRESHOLD=85
EOF
```

### 3. **Test Before Deploying**
```bash
# Test configuration
nftban health check

# View effective settings
source /etc/nftban/conf.d/health.conf
source /etc/nftban/conf.d/health.conf.local 2>/dev/null
echo "Disk warn: $NFTBAN_DISK_WARN_THRESHOLD"
```

### 4. **Version Control Your .local Files**
```bash
# Keep .local files in git
cd /etc/nftban/conf.d
git init
git add *.local
git commit -m "Production overrides for web01"
```

---

## Troubleshooting

### Problem: Changes Not Applied

```bash
# Check if .local file exists
ls -la /etc/nftban/conf.d/*.local

# Check file permissions
stat /etc/nftban/conf.d/health.conf.local

# Check syntax
bash -n /etc/nftban/conf.d/health.conf.local

# Test loading order
bash -x /usr/sbin/nftban health check 2>&1 | grep "source.*health"
```

### Problem: Don't Know What to Override

```bash
# View defaults
cat /etc/nftban/conf.d/health.conf

# View current effective values
source /etc/nftban/conf.d/health.conf
env | grep NFTBAN_
```

### Problem: Accidental Edit of Default Config

```bash
# Restore from RPM
dnf reinstall nftban

# Or extract from package
rpm2cpio nftban-0.30.0-1.rpm | cpio -idmv ./etc/nftban/conf.d/health.conf
```

---

## Migration from Old System

If you have existing modifications:

```bash
# Old way (BAD - will be overwritten)
vim /etc/nftban/conf.d/health.conf

# New way (GOOD - preserved)
vim /etc/nftban/conf.d/health.conf.local
```

### Migration Script

```bash
#!/bin/bash
# migrate_to_local.sh - Extract your modifications

cd /etc/nftban/conf.d

for conf in *.conf; do
    if git diff "$conf" &>/dev/null; then
        # Extract modified lines
        git diff "$conf" | grep '^+' | sed 's/^+//' > "${conf}.local"
        echo "Created ${conf}.local with your changes"
    fi
done
```

---

## Technical Implementation

### Code Location

**File:** `/usr/sbin/nftban`

```bash
# Load module configs (conf.d/*.conf) in alphabetical order
# After each .conf file, load corresponding .local override if exists
if [[ -d "${NFTBAN_CONFIG_DIR}/conf.d" ]]; then
    for conf_file in "${NFTBAN_CONFIG_DIR}"/conf.d/*.conf; do
        if [[ -f "$conf_file" ]]; then
            # Load main config file
            source "$conf_file"

            # Load .local override for this specific config (if exists)
            local_override="${conf_file}.local"
            if [[ -f "$local_override" ]]; then
                source "$local_override"
            fi
        fi
    done
fi

# Load user overrides (highest priority) if exists
if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf.local" ]]; then
    source "${NFTBAN_CONFIG_DIR}/nftban.conf.local"
fi
```

---

## Benefits

✅ **Upgrade Safe** - Your .local files are never touched by RPM
✅ **Per-Module** - Override only what you need
✅ **Hierarchical** - Clear priority system
✅ **Documented** - Examples and templates provided
✅ **Flexible** - Global or per-module overrides
✅ **Standard** - Follows systemd .local pattern

---

## Summary

| File | Purpose | Modified By | Preserved? |
|------|---------|-------------|------------|
| `nftban.conf` | Main defaults | NFTBan package | ❌ No (replaced) |
| `nftban.conf.local` | Global overrides | Administrator | ✅ Yes |
| `conf.d/*.conf` | Module defaults | NFTBan package | ❌ No (replaced) |
| `conf.d/*.conf.local` | Module overrides | Administrator | ✅ Yes |

**Golden Rule:** If you edit it, put it in a `.local` file!

---

*NFTBan v0.30.0 - Upgrade-Safe Configuration System* 🔒
