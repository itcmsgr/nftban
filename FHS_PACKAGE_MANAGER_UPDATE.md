# NFTBan v0.10.0 - FHS & Package Manager Updates

**Date:** 2025-10-29
**Version:** 0.10.0
**Component:** FHS Compliance & Package Management

---

## 📦 PACKAGE MANAGER INTEGRATION

### New Directories to Package

The following directories must be created by the package manager during installation:

#### Application State Data (`/var/lib/nftban/`)

```bash
# Directory structure for package manager
/var/lib/nftban/
├── reports/           # 750, nftban:nftban - Generated reports (HTML, JSON, CSV)
├── metrics/           # 750, nftban:nftban - Statistics metrics database
│   └── cache/         # 750, nftban:nftban - Metrics cache (5min TTL)
├── snapshots/         # 750, nftban:nftban - Hourly statistics snapshots
├── exports/           # 750, nftban:nftban - User data exports
└── geoip/             # 750, root:nftban   - GeoIP database (group readable)
```

#### Log Files (`/var/log/nftban/`)

```bash
# Directory structure for package manager
/var/log/nftban/
├── stats.log          # 640, nftban:nftban - Statistics log
├── cron.log           # 640, nftban:nftban - Cron job log
├── security-audit.log # 640, nftban:nftban - Security audit log
└── reports/           # 750, nftban:nftban - Log-style reports
```

#### Cache (`/var/cache/nftban/`)

```bash
# Directory structure for package manager
/var/cache/nftban/
└── stats/             # 755, nftban:nftban - Statistics cache
```

---

## 🗂️ UPDATED FHS DEFINITIONS

### File: `/usr/lib/nftban/core/nftban_report_fhs.sh`

**Changes Made:**

```bash
# OLD (before v0.10.0):
NFTBAN_FHS_DIRECTORIES["/var/lib/nftban"]="755|nftban|nftban|Application state data"
NFTBAN_FHS_DIRECTORIES["/var/log/nftban"]="750|nftban|nftban|Log files"

# NEW (v0.10.0):
# Variable data
NFTBAN_FHS_DIRECTORIES["/var/lib/nftban"]="755|nftban|nftban|Application state data"
NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/reports"]="750|nftban|nftban|Generated reports (application state)"
NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/metrics"]="750|nftban|nftban|Statistics metrics database"
NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/snapshots"]="750|nftban|nftban|Hourly stats snapshots"
NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/exports"]="750|nftban|nftban|User data exports (JSON, CSV)"
NFTBAN_FHS_DIRECTORIES["/var/lib/nftban/geoip"]="750|root|nftban|GeoIP database (group readable)"

# Logs
NFTBAN_FHS_DIRECTORIES["/var/log/nftban"]="750|nftban|nftban|Log files (daemon writes, group reads)"
NFTBAN_FHS_DIRECTORIES["/var/log/nftban/reports"]="750|nftban|nftban|Report files (log-style, daemon writes)"

# Cache
NFTBAN_FHS_DIRECTORIES["/var/cache/nftban"]="755|nftban|nftban|Cache files"
```

---

## 📋 PACKAGE MANAGER INSTRUCTIONS

### For RPM-based Systems (Fedora, RHEL, CentOS)

#### Spec File Addition

Add to `nftban.spec`:

```spec
%pre
# Create nftban user/group if not exists
getent group nftban >/dev/null || groupadd -r nftban
getent passwd nftban >/dev/null || \
    useradd -r -g nftban -d /var/lib/nftban -s /sbin/nologin \
    -c "NFTBan Service User" nftban

%install
# ... existing install commands ...

# Create directory structure
mkdir -p %{buildroot}/var/lib/nftban/{reports,metrics/cache,snapshots,exports,geoip}
mkdir -p %{buildroot}/var/log/nftban/reports
mkdir -p %{buildroot}/var/cache/nftban/stats

%files
# ... existing files ...

# Directories (owned by package)
%dir %attr(750,nftban,nftban) /var/lib/nftban/reports
%dir %attr(750,nftban,nftban) /var/lib/nftban/metrics
%dir %attr(750,nftban,nftban) /var/lib/nftban/metrics/cache
%dir %attr(750,nftban,nftban) /var/lib/nftban/snapshots
%dir %attr(750,nftban,nftban) /var/lib/nftban/exports
%dir %attr(750,root,nftban) /var/lib/nftban/geoip

%dir %attr(750,nftban,nftban) /var/log/nftban/reports
%dir %attr(755,nftban,nftban) /var/cache/nftban/stats

# Log files (ghost - created at runtime)
%ghost %attr(640,nftban,nftban) /var/log/nftban/stats.log
%ghost %attr(640,nftban,nftban) /var/log/nftban/cron.log
%ghost %attr(640,nftban,nftban) /var/log/nftban/security-audit.log

%post
# Create log files if they don't exist
touch /var/log/nftban/stats.log
touch /var/log/nftban/cron.log
touch /var/log/nftban/security-audit.log

# Set proper ownership and permissions
chown nftban:nftban /var/log/nftban/stats.log
chown nftban:nftban /var/log/nftban/cron.log
chown nftban:nftban /var/log/nftban/security-audit.log

chmod 640 /var/log/nftban/stats.log
chmod 640 /var/log/nftban/cron.log
chmod 640 /var/log/nftban/security-audit.log

# Install cron job for stats
cat > /etc/cron.d/nftban-stats << 'EOCRON'
# NFTBan Statistics Reports - Automated Scheduling
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Daily report at 23:59
59 23 * * * root /usr/sbin/nftban report run daily >> /var/log/nftban/cron.log 2>&1

# Hourly snapshot
0 * * * * root /usr/sbin/nftban stats snapshot >> /var/log/nftban/cron.log 2>&1

# Daily cleanup (03:00 AM)
0 3 * * * root /usr/sbin/nftban stats cleanup >> /var/log/nftban/cron.log 2>&1
EOCRON

chmod 644 /etc/cron.d/nftban-stats

%preun
# Remove cron job on uninstall (not on upgrade)
if [ $1 -eq 0 ]; then
    rm -f /etc/cron.d/nftban-stats
fi

%postun
# Cleanup on full uninstall (not on upgrade)
if [ $1 -eq 0 ]; then
    # Remove cache (but keep logs/reports for audit)
    rm -rf /var/cache/nftban/stats
fi
```

---

### For DEB-based Systems (Debian, Ubuntu)

#### Debian Package Files

**File: `debian/nftban.dirs`**

Add:

```
var/lib/nftban/reports
var/lib/nftban/metrics
var/lib/nftban/metrics/cache
var/lib/nftban/snapshots
var/lib/nftban/exports
var/lib/nftban/geoip
var/log/nftban/reports
var/cache/nftban/stats
```

**File: `debian/nftban.postinst`**

```bash
#!/bin/bash
set -e

case "$1" in
    configure)
        # Create nftban user/group if not exists
        if ! getent group nftban >/dev/null; then
            addgroup --system nftban
        fi

        if ! getent passwd nftban >/dev/null; then
            adduser --system --ingroup nftban --home /var/lib/nftban \
                --no-create-home --disabled-login \
                --gecos "NFTBan Service User" nftban
        fi

        # Create directory structure with proper permissions
        for dir in /var/lib/nftban/{reports,metrics/cache,snapshots,exports} \
                   /var/log/nftban/reports; do
            mkdir -p "$dir"
            chown nftban:nftban "$dir"
            chmod 750 "$dir"
        done

        # GeoIP directory (root owned, nftban group readable)
        mkdir -p /var/lib/nftban/geoip
        chown root:nftban /var/lib/nftban/geoip
        chmod 750 /var/lib/nftban/geoip

        # Cache directory (world readable for performance)
        mkdir -p /var/cache/nftban/stats
        chown nftban:nftban /var/cache/nftban/stats
        chmod 755 /var/cache/nftban/stats

        # Create log files
        for log in stats cron security-audit; do
            touch "/var/log/nftban/${log}.log"
            chown nftban:nftban "/var/log/nftban/${log}.log"
            chmod 640 "/var/log/nftban/${log}.log"
        done

        # Install cron job
        cat > /etc/cron.d/nftban-stats << 'EOCRON'
# NFTBan Statistics Reports - Automated Scheduling
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Daily report at 23:59
59 23 * * * root /usr/sbin/nftban report run daily >> /var/log/nftban/cron.log 2>&1

# Hourly snapshot
0 * * * * root /usr/sbin/nftban stats snapshot >> /var/log/nftban/cron.log 2>&1

# Daily cleanup (03:00 AM)
0 3 * * * root /usr/sbin/nftban stats cleanup >> /var/log/nftban/cron.log 2>&1
EOCRON

        chmod 644 /etc/cron.d/nftban-stats
        ;;
esac

#DEBHELPER#

exit 0
```

**File: `debian/nftban.postrm`**

```bash
#!/bin/bash
set -e

case "$1" in
    purge)
        # Remove cron job
        rm -f /etc/cron.d/nftban-stats

        # Remove cache (but keep logs/reports for audit)
        rm -rf /var/cache/nftban/stats

        # Ask if user wants to remove data
        if [ -x /usr/bin/debconf-get ]; then
            . /usr/share/debconf/confmodule
            db_input high nftban/purge-data || true
            db_go
            db_get nftban/purge-data
            if [ "$RET" = "true" ]; then
                # Remove all data
                rm -rf /var/lib/nftban
                rm -rf /var/log/nftban
            fi
        fi
        ;;

    remove|upgrade|failed-upgrade|abort-install|abort-upgrade|disappear)
        # Keep data on remove/upgrade
        ;;
esac

#DEBHELPER#

exit 0
```

---

### For Arch Linux (PKGBUILD)

```bash
pkgname=nftban
pkgver=0.10.0
pkgrel=1
# ... other metadata ...

install=nftban.install

package() {
    # ... existing package commands ...

    # Create directory structure
    install -dm750 "$pkgdir/var/lib/nftban"/{reports,metrics/cache,snapshots,exports}
    install -dm750 "$pkgdir/var/lib/nftban/geoip"
    install -dm750 "$pkgdir/var/log/nftban/reports"
    install -dm755 "$pkgdir/var/cache/nftban/stats"

    # Install cron job
    install -Dm644 nftban-stats.cron "$pkgdir/etc/cron.d/nftban-stats"
}
```

**File: `nftban.install`**

```bash
post_install() {
    # Create nftban user/group
    getent group nftban &>/dev/null || groupadd -r nftban
    getent passwd nftban &>/dev/null || \
        useradd -r -g nftban -d /var/lib/nftban -s /usr/bin/nologin nftban

    # Set ownership
    chown -R nftban:nftban /var/lib/nftban/{reports,metrics,snapshots,exports}
    chown -R root:nftban /var/lib/nftban/geoip
    chown -R nftban:nftban /var/log/nftban
    chown -R nftban:nftban /var/cache/nftban

    # Create log files
    for log in stats cron security-audit; do
        touch "/var/log/nftban/${log}.log"
        chown nftban:nftban "/var/log/nftban/${log}.log"
        chmod 640 "/var/log/nftban/${log}.log"
    done

    echo "==> NFTBan v0.10.0 installed successfully"
    echo "==> Daily stats reports configured (see /etc/cron.d/nftban-stats)"
}

post_upgrade() {
    post_install
}

pre_remove() {
    # Remove cron job
    rm -f /etc/cron.d/nftban-stats
}
```

---

## 🔧 MANUAL INSTALLATION SCRIPT

For systems without package manager or manual deployment:

**File: `install-fhs-directories.sh`**

```bash
#!/usr/bin/env bash
# NFTBan v0.10.0 - FHS Directory Installation Script

set -Eeuo pipefail

echo "=== NFTBan v0.10.0 - FHS Directory Setup ==="
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root"
   exit 1
fi

# Create nftban user/group if not exists
if ! getent group nftban >/dev/null; then
    echo "[+] Creating nftban group..."
    groupadd -r nftban
fi

if ! getent passwd nftban >/dev/null; then
    echo "[+] Creating nftban user..."
    useradd -r -g nftban -d /var/lib/nftban -s /sbin/nologin \
        -c "NFTBan Service User" nftban
fi

# Create /var/lib/nftban directories
echo "[+] Creating /var/lib/nftban directories..."
for dir in reports metrics/cache snapshots exports geoip; do
    mkdir -p "/var/lib/nftban/$dir"
    if [[ "$dir" == "geoip" ]]; then
        chown root:nftban "/var/lib/nftban/$dir"
    else
        chown nftban:nftban "/var/lib/nftban/$dir"
    fi
    chmod 750 "/var/lib/nftban/$dir"
    echo "  ✓ /var/lib/nftban/$dir"
done

# Create /var/log/nftban directories
echo "[+] Creating /var/log/nftban directories..."
mkdir -p /var/log/nftban/reports
chown -R nftban:nftban /var/log/nftban
chmod 750 /var/log/nftban
chmod 750 /var/log/nftban/reports
echo "  ✓ /var/log/nftban/reports"

# Create log files
echo "[+] Creating log files..."
for log in stats cron security-audit; do
    touch "/var/log/nftban/${log}.log"
    chown nftban:nftban "/var/log/nftban/${log}.log"
    chmod 640 "/var/log/nftban/${log}.log"
    echo "  ✓ /var/log/nftban/${log}.log"
done

# Create /var/cache/nftban directories
echo "[+] Creating /var/cache/nftban directories..."
mkdir -p /var/cache/nftban/stats
chown nftban:nftban /var/cache/nftban/stats
chmod 755 /var/cache/nftban/stats
echo "  ✓ /var/cache/nftban/stats"

# Install cron job
echo "[+] Installing cron job..."
cat > /etc/cron.d/nftban-stats << 'EOCRON'
# NFTBan Statistics Reports - Automated Scheduling
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Daily report at 23:59
59 23 * * * root /usr/sbin/nftban report run daily >> /var/log/nftban/cron.log 2>&1

# Hourly snapshot
0 * * * * root /usr/sbin/nftban stats snapshot >> /var/log/nftban/cron.log 2>&1

# Daily cleanup (03:00 AM)
0 3 * * * root /usr/sbin/nftban stats cleanup >> /var/log/nftban/cron.log 2>&1
EOCRON

chmod 644 /etc/cron.d/nftban-stats
echo "  ✓ /etc/cron.d/nftban-stats"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ NFTBan FHS directories installed successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Directory Structure:"
echo "  /var/lib/nftban/reports/      - Generated reports"
echo "  /var/lib/nftban/metrics/      - Statistics database"
echo "  /var/lib/nftban/snapshots/    - Hourly snapshots"
echo "  /var/lib/nftban/exports/      - Data exports"
echo "  /var/log/nftban/              - Log files"
echo "  /var/cache/nftban/stats/      - Cache"
echo ""
echo "Cron Jobs:"
echo "  Daily report:   23:59 (to contact@nftban.com)"
echo "  Hourly snapshot: :00"
echo "  Daily cleanup:   03:00"
echo ""
echo "Run 'nftban fhs report' to verify all directories"
echo ""
```

---

## ✅ VERIFICATION COMMANDS

After package installation, verify FHS compliance:

```bash
# Run FHS report
nftban fhs report

# Check directory permissions
nftban fhs check

# Manually verify
ls -ld /var/lib/nftban/{reports,metrics,snapshots,exports,geoip}
ls -ld /var/log/nftban/reports
ls -ld /var/cache/nftban/stats

# Check log files
ls -l /var/log/nftban/{stats,cron,security-audit}.log

# Check cron job
cat /etc/cron.d/nftban-stats
```

Expected output:
```
drwxr-x--- 2 nftban nftban 4096 Oct 29 14:00 /var/lib/nftban/reports
drwxr-x--- 2 nftban nftban 4096 Oct 29 14:00 /var/lib/nftban/metrics
drwxr-x--- 2 nftban nftban 4096 Oct 29 14:00 /var/lib/nftban/snapshots
drwxr-x--- 2 nftban nftban 4096 Oct 29 14:00 /var/lib/nftban/exports
drwxr-x--- 2 root   nftban 4096 Oct 29 14:00 /var/lib/nftban/geoip
drwxr-x--- 2 nftban nftban 4096 Oct 29 14:00 /var/log/nftban/reports
drwxr-xr-x 2 nftban nftban 4096 Oct 29 14:00 /var/cache/nftban/stats
```

---

## 📦 PACKAGING CHECKLIST

### Pre-Release:

- [ ] Update version in spec/control files
- [ ] Update FHS definitions in `nftban_report_fhs.sh`
- [ ] Test package build on target OS
- [ ] Verify directory creation on install
- [ ] Verify permissions after install
- [ ] Test cron job installation
- [ ] Test upgrade path (preserve data)
- [ ] Test removal (keep logs, remove cache)
- [ ] Test purge (optionally remove all data)

### Post-Install Verification:

- [ ] Run `nftban fhs report` - all checks pass
- [ ] Run `nftban stats` - works without errors
- [ ] Run `nftban report generate` - creates report
- [ ] Check `/var/log/nftban/stats.log` - log created
- [ ] Check `/etc/cron.d/nftban-stats` - cron installed
- [ ] Verify security audit log works

---

## 🔄 UPGRADE PATH

### Upgrading from v0.9.x to v0.10.0:

Package manager should:

1. **Preserve existing data:**
   - Keep `/var/lib/nftban/` contents
   - Keep `/var/log/nftban/` logs
   - Keep `/etc/nftban/` configuration

2. **Create new directories:**
   - `/var/lib/nftban/reports/` (if not exists)
   - `/var/lib/nftban/metrics/`
   - `/var/lib/nftban/snapshots/`
   - `/var/lib/nftban/exports/`
   - `/var/log/nftban/reports/`
   - `/var/cache/nftban/stats/`

3. **Install new files:**
   - `nftban_stats.sh`
   - `nftban_path_security.sh`
   - `nftban_secure_mode.sh`
   - `cmd_stats.sh`
   - `cmd_report.sh`
   - `stats.conf`
   - Templates

4. **Update cron:**
   - Install `/etc/cron.d/nftban-stats`

---

## 📞 SUPPORT

**Questions about package management?**
- Email: contact@nftban.com
- Website: https://nftban.com

**Related Documentation:**
- `DEPLOYMENT_COMPLETE.md` - Full deployment guide
- `STATS_DEPLOYMENT_GUIDE.md` - Stats system usage
- `SECURITY_PATH_VALIDATION.md` - Security features

---

**Package Maintainers:** Please update your packaging scripts according to this guide to ensure proper FHS compliance and functionality of NFTBan v0.10.0 statistics and security features.
