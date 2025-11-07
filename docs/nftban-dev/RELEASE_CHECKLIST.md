# NFTBan Release Checklist

Complete checklist for creating a new NFTBan release. This document records all files that must be updated and the exact process to follow.

**Target audience**: NFTBan developers creating new releases

## Version Variables

For this guide, let's say we're releasing version `X.Y.Z`:
- `OLD_VERSION`: The previous version (e.g., `0.31.0`)
- `NEW_VERSION`: The new version (e.g., `0.32.0`)

## Pre-Release Checklist

### 1. Update All Version References

Run this comprehensive search to find ALL version references:

```bash
# Find all version strings in source files
grep -r "0\.31" src/ packaging/ docs/ go-feeds/ README.md CHANGELOG.md

# Find meta:version tags
grep -r "meta:version=" src/

# Find Version: headers in configs
grep -r "Version:" src/etc/
```

### 2. Critical Files That MUST Be Updated

#### 2.1 Main Configuration (MOST IMPORTANT!)

**File**: `src/etc/nftban/nftban.conf`
- Line 4: `# Version: X.Y.Z`
- **Line 12**: `NFTBAN_VERSION="X.Y.Z"` ← **THIS CONTROLS THE BANNER! NEVER FORGET!**

**Why critical**: This variable is the source of truth for the CLI banner display. If you forget this, users will see the wrong version in `nftban` output.

**Example**:
```bash
# Version
NFTBAN_VERSION="0.32.0"  # ← MUST match package version!
```

#### 2.2 Main CLI Binary

**File**: `src/usr/sbin/nftban`
- Line 3: `# NFTBan vX.Y.Z - CLI Interface`
- Line 10: `# meta:version=X.Y.Z`
- Line 54: `export NFTBAN_VERSION="X.Y.Z"`

#### 2.3 Go Configuration

**File**: `src/etc/nftban/conf.d/nftban-go.conf`
- Line 2: `# NFTBan vX.Y.Z - Go Binary Common Configuration`
- Line 62: `GO_USER_AGENT="NFTBan/X.Y.Z (+https://nftban.com)"`

#### 2.4 Package Manager Files

**File**: `packaging/rpm/nftban.spec`
- Line 1: `Version:        X.Y.Z`
- Line 7-12: Add changelog entry

**File**: `packaging/deb/changelog`
- Line 1: `nftban (X.Y.Z-1) stable; urgency=medium`
- Lines 3-5: Add bullet points describing changes

#### 2.5 Documentation

**File**: `docs/nftban.1` (man page)
- Line 1: `.TH NFTBAN 1 "2025" "NFTBan vX.Y.Z" "User Commands"`

**File**: `CHANGELOG.md`
- Add new `## [vX.Y.Z] - YYYY-MM-DD` section at the top
- List all changes under appropriate categories (Added, Changed, Fixed, etc.)

**File**: `README.md`
- Line 13: Update version badge: `[![Version](https://img.shields.io/badge/version-X.Y.Z-blue.svg)]`

#### 2.6 Go Binaries

**File**: `go-feeds/cmd/nftban-feeds/main.go`
- Line 56: Update usage version string: `NFTBan Feeds Manager vX.Y.Z`

**File**: `go-feeds/cmd/nftban-geoip/main.go`
- Update version string if present

### 3. Mass Update Config Files

Update ALL config files in `src/etc/nftban/conf.d/`:

```bash
# Update meta:version headers
find src/etc/nftban/conf.d/ -name "*.conf" -exec sed -i 's/meta:version=0\.31/meta:version=0.32/g' {} +

# Update Version: headers
find src/etc/nftban/conf.d/ -name "*.conf" -exec sed -i 's/Version: 0\.31/Version: 0.32/g' {} +
```

**Files to update** (approximately 30 files):
- `banner.conf`
- `cloudflare.conf`
- `feeds.conf`
- `nftban-go.conf`
- `ports.conf`
- `system.conf`
- And all others in `conf.d/`

### 4. Mass Update Fail2ban Templates

Update ALL fail2ban templates in `src/etc/fail2ban/`:

```bash
# Update version references
find src/etc/fail2ban/ -type f -exec sed -i 's/v0\.31/v0.32/g' {} +
```

**Files to update** (approximately 19 files):
- `action.d/nftban.conf`
- `filter.d/*.conf`
- `jail.d/*.conf`

### 5. Mass Update Module Headers

Update ALL bash modules:

```bash
# Update meta:version in all modules
find src/usr/lib/nftban/ -name "*.sh" -exec sed -i 's/meta:version=0\.31/meta:version=0.32/g' {} +
```

**Directories**:
- `src/usr/lib/nftban/core/` (~15 modules)
- `src/usr/lib/nftban/cli/` (~20 commands)
- `src/usr/lib/nftban/utils/` (~10 utilities)
- `src/usr/lib/nftban/helpers/` (~5 helpers)

## Release Process

### Step 1: Verify All Changes

```bash
# Check that no old version references remain
grep -r "0\.31" src/ packaging/ docs/ go-feeds/ README.md

# If you find any, update them!
```

### Step 2: Run Quality Checks

```bash
# Shellcheck all bash scripts
find src/usr/lib/nftban/ -name "*.sh" -exec shellcheck {} \;
shellcheck src/usr/sbin/nftban

# Build Go binaries locally
cd go-feeds
go build ./cmd/nftban-feeds
go build ./cmd/nftban-geoip
cd ..
```

### Step 3: Commit Changes

```bash
git add .
git commit -m "chore: Bump version to X.Y.Z

- Updated all version references across codebase
- Updated package manager files (RPM spec, DEB changelog)
- Updated documentation (README, man page, CHANGELOG)
- Updated config files and module headers

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

### Step 4: Create Git Tag

```bash
# Create and push tag
git tag vX.Y.Z
git push
git push origin vX.Y.Z
```

### Step 5: Monitor Build

GitHub Actions will automatically:
1. Build Go binaries (x86_64 and aarch64)
2. Build RPM packages (Rocky Linux 9)
3. Build DEB packages (Ubuntu/Debian)
4. Create GitHub Release
5. Upload all artifacts

**Monitor at**: https://github.com/itcmsgr/nftban/actions

**Expected artifacts** (8 files):
- `nftban-X.Y.Z-1.el9.x86_64.rpm` (versioned RPM x86_64)
- `nftban-X.Y.Z-1.el9.aarch64.rpm` (versioned RPM ARM64)
- `nftban_X.Y.Z-1_amd64.deb` (versioned DEB amd64)
- `nftban_X.Y.Z-1_arm64.deb` (versioned DEB ARM64)
- `nftban-x86_64.rpm` (simplified name)
- `nftban-aarch64.rpm` (simplified name)
- `nftban-amd64.deb` (simplified name)
- `nftban-arm64.deb` (simplified name)
- `SHA256SUMS` (checksums)
- `MANIFEST.txt` (file list)
- `VERIFY.txt` (installation guide)

Build takes approximately **10-15 minutes**.

### Step 6: Verify Build Success

```bash
# Check release exists
curl -s https://api.github.com/repos/itcmsgr/nftban/releases/tags/vX.Y.Z | jq -r '.tag_name, .published_at, .assets | length'

# Should output:
# vX.Y.Z
# 2025-XX-XXTXX:XX:XXZ
# 11
```

## Post-Release Testing

### Test on Lab Servers

**Lab2** (Fresh install):
```bash
ssh root@lab2.example.test
dnf remove -y nftban
cd /tmp
wget https://github.com/itcmsgr/nftban/releases/download/vX.Y.Z/nftban-X.Y.Z-1.el9.x86_64.rpm
dnf install -y nftban-X.Y.Z-1.el9.x86_64.rpm
nftban health check --auto-heal
```

**Lab3 & Lab4** (Update):
```bash
ssh root@lab3.example.test
cd /tmp
wget https://github.com/itcmsgr/nftban/releases/download/vX.Y.Z/nftban-X.Y.Z-1.el9.x86_64.rpm
dnf update -y nftban-X.Y.Z-1.el9.x86_64.rpm
```

### Comprehensive CLI Test Suite

Run on all servers:

```bash
# ============================================================================
# PART 1: VERSION VERIFICATION
# ============================================================================

echo "=== Package Version ==="
rpm -qi nftban | grep Version

echo ""
echo "=== CLI Version (should match package) ==="
head -5 /usr/sbin/nftban | grep "NFTBan v"
grep "NFTBAN_VERSION=" /usr/sbin/nftban

echo ""
echo "=== Banner Version (CRITICAL!) ==="
grep "NFTBAN_VERSION=" /etc/nftban/nftban.conf

echo ""
echo "=== Module Versions (sample) ==="
grep "meta:version" /usr/lib/nftban/cli/*.sh | head -3
grep "meta:version" /usr/lib/nftban/core/*.sh | head -3

echo ""
echo "=== Config Versions (sample) ==="
grep "Version:" /etc/nftban/conf.d/*.conf | head -3

# ============================================================================
# PART 2: BASIC CLI COMMANDS
# ============================================================================

echo ""
echo "=== Help Command ==="
nftban help | head -20

echo ""
echo "=== Status Command ==="
nftban status

echo ""
echo "=== Health Check ==="
nftban health check

echo ""
echo "=== List Commands ==="
nftban list tables
nftban list chains

# ============================================================================
# PART 3: BAN/UNBAN OPERATIONS
# ============================================================================

echo ""
echo "=== Ban IPv4 Test ==="
nftban ban 198.51.100.99 "test ban"
nftban list bans | grep "198.51.100.99"

echo ""
echo "=== Ban IPv6 Test ==="
nftban ban 2001:db8::bad:actor "test ban IPv6"
nftban list bans | grep "2001:db8"

echo ""
echo "=== Unban IPv4 Test ==="
nftban unban 198.51.100.99
nftban list bans | grep -c "198.51.100.99" || echo "✓ Unbanned successfully"

echo ""
echo "=== Unban IPv6 Test ==="
nftban unban 2001:db8::bad:actor
nftban list bans | grep -c "2001:db8" || echo "✓ Unbanned successfully"

# ============================================================================
# PART 4: PORT MANAGEMENT
# ============================================================================

echo ""
echo "=== Port Search (SSH) ==="
nftban port search 22

echo ""
echo "=== Port Protect ==="
nftban port protect 8080 "Test port protection"
nftban port list | grep 8080

echo ""
echo "=== Port Remove ==="
nftban port remove 8080
nftban port list | grep -c 8080 || echo "✓ Port removed successfully"

# ============================================================================
# PART 5: FEEDS SYSTEM (Single Source of Truth Test)
# ============================================================================

echo ""
echo "=== Feeds Configuration Check ==="
echo "Checking feed URLs are ONLY in conf.d/feeds.conf:"
grep -r "blocklist.greensnow" /etc/nftban/
# Should ONLY show feeds.conf, not Go binary!

echo ""
echo "=== Feeds List ==="
nftban feeds list

echo ""
echo "=== Feeds Status ==="
nftban feeds status

echo ""
echo "=== Enable Test Feed (if category exists) ==="
nftban feeds enable-cat anonymity 2>/dev/null || echo "Category command may not exist yet"

# ============================================================================
# PART 6: WHITELIST/BLACKLIST
# ============================================================================

echo ""
echo "=== Whitelist Commands ==="
nftban whitelist list | head -10

echo ""
echo "=== Add to Whitelist ==="
nftban whitelist add 192.0.2.50 "test whitelist"
nftban whitelist list | grep "192.0.2.50"

echo ""
echo "=== Remove from Whitelist ==="
nftban whitelist remove 192.0.2.50
nftban whitelist list | grep -c "192.0.2.50" || echo "✓ Removed successfully"

# ============================================================================
# PART 7: CLOUDFLARE (if configured)
# ============================================================================

echo ""
echo "=== Cloudflare Status ==="
nftban cloudflare status 2>/dev/null || echo "Cloudflare not configured (optional)"

# ============================================================================
# PART 8: PORTSCAN DETECTION
# ============================================================================

echo ""
echo "=== Portscan Status ==="
nftban portscan status 2>/dev/null || echo "Portscan feature may not be available"

# ============================================================================
# PART 9: FHS STRUCTURE & PERMISSIONS
# ============================================================================

echo ""
echo "=== FHS Directory Structure ==="
ls -la /etc/nftban/
ls -la /var/lib/nftban/
ls -la /var/log/nftban/
ls -la /var/cache/nftban/
ls -la /run/nftban/

echo ""
echo "=== Auto-Heal Test ==="
nftban health check --auto-heal

# ============================================================================
# PART 10: SERVICE STATUS
# ============================================================================

echo ""
echo "=== Systemd Services ==="
systemctl status nftban-maintenance.timer --no-pager
systemctl status fail2ban.service --no-pager || echo "fail2ban not running (optional)"

echo ""
echo "=== NFTables Rules ==="
nft list ruleset | grep -A5 "table inet nftban"
```

## Common Issues & Solutions

### Issue 1: Banner Shows Wrong Version

**Symptom**: `nftban` command shows "NFTBan v0.32.6" but package is v0.32.6

**Cause**: `NFTBAN_VERSION` variable in `/etc/nftban/nftban.conf` not updated

**Solution**:
```bash
# Fix in source
vi src/etc/nftban/nftban.conf
# Change line 12: NFTBAN_VERSION="0.32.0"

# Rebuild package
git add src/etc/nftban/nftban.conf
git commit -m "fix: Update NFTBAN_VERSION to 0.32.0"
git tag -d vX.Y.Z
git push origin :refs/tags/vX.Y.Z
git tag vX.Y.Z
git push && git push origin vX.Y.Z
```

### Issue 2: Go Binary Has Hardcoded URLs

**Symptom**: Feed URLs found in Go binary, not respecting config file

**Cause**: Go code downloads feeds instead of reading from disk

**Solution**: Ensure Go feeds binary uses disk-based approach:
```go
// WRONG:
allFeeds := map[string]string{
    "greensnow": "https://blocklist.greensnow.co/greensnow.txt",
}

// CORRECT:
feedDir := "/var/lib/nftban/feeds"
feedFile := filepath.Join(feedDir, name+".txt")
content, err := os.ReadFile(feedFile)
```

### Issue 3: Rocky Linux Build Failure (glibc mismatch)

**Symptom**: `nothing provides glibc = 2.34-168.el9_6.24`

**Cause**: Rocky Linux Docker base image has older glibc than glibc-devel package

**Solution**: Already fixed in `.github/workflows/release.yml` line 95:
```yaml
# CRITICAL: Update glibc FIRST
dnf update -y glibc
# Then install glibc-devel
dnf install -y --allowerasing glibc-devel ...
```

### Issue 4: Shellcheck Failures

**Symptom**: `((counter++))` patterns causing errors

**Cause**: NFTBan uses `set -e` which causes arithmetic exit when counter=0

**Solution**: Use safe pattern:
```bash
# WRONG:
command && ((counter++))

# CORRECT:
if command; then
    counter=$((counter + 1))
fi
```

## Version Update Template

Quick commands for updating to a new version (replace X.Y.Z):

```bash
# Set version variables
OLD="0.31"
NEW="0.32"

# Update all files
sed -i "s/Version: $OLD/Version: $NEW/g" src/etc/nftban/nftban.conf
sed -i "s/NFTBAN_VERSION=\"$OLD\.0\"/NFTBAN_VERSION=\"$NEW.0\"/g" src/etc/nftban/nftban.conf
sed -i "s/NFTBan v$OLD/NFTBan v$NEW/g" src/usr/sbin/nftban
sed -i "s/meta:version=$OLD/meta:version=$NEW/g" src/usr/sbin/nftban
sed -i "s/GO_USER_AGENT=\"NFTBan\/$OLD/GO_USER_AGENT=\"NFTBan\/$NEW/g" src/etc/nftban/conf.d/nftban-go.conf

# Mass update
find src/etc/nftban/conf.d/ -name "*.conf" -exec sed -i "s/meta:version=$OLD/meta:version=$NEW/g" {} +
find src/etc/nftban/conf.d/ -name "*.conf" -exec sed -i "s/Version: $OLD/Version: $NEW/g" {} +
find src/etc/fail2ban/ -type f -exec sed -i "s/v$OLD/v$NEW/g" {} +
find src/usr/lib/nftban/ -name "*.sh" -exec sed -i "s/meta:version=$OLD/meta:version=$NEW/g" {} +

# Update package files
vi packaging/rpm/nftban.spec  # Update Version: and %changelog
vi packaging/deb/changelog    # Add new entry
vi CHANGELOG.md               # Add release notes
vi README.md                  # Update version badge
vi docs/nftban.1              # Update .TH line
vi go-feeds/cmd/nftban-feeds/main.go  # Update usage string
```

## Checklist Summary

Before tagging a release, verify:

- [ ] `src/etc/nftban/nftban.conf` line 12: `NFTBAN_VERSION="X.Y.Z"`
- [ ] `src/etc/nftban/conf.d/nftban-go.conf` line 62: `GO_USER_AGENT="NFTBan/X.Y.Z"`
- [ ] `src/usr/sbin/nftban` header and meta:version
- [ ] `packaging/rpm/nftban.spec` Version and changelog
- [ ] `packaging/deb/changelog` new entry
- [ ] `CHANGELOG.md` new section
- [ ] `README.md` version badge
- [ ] `docs/nftban.1` .TH line
- [ ] All `conf.d/*.conf` files meta:version
- [ ] All fail2ban templates version references
- [ ] All bash modules meta:version
- [ ] Go binaries usage strings
- [ ] No grep results for old version: `grep -r "0\.31" src/`
- [ ] Shellcheck passes on all scripts
- [ ] Go builds successfully

---

**Created**: 2025-11-06
**Last Updated**: 2025-11-06
**Version**: 1.0
**Maintainer**: NFTBan Development Team
