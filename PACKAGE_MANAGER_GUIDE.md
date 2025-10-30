# NFTBan v0.10.0 - Package Manager Integration Guide

Complete instructions for creating RPM (RHEL/CentOS) and DEB (Debian/Ubuntu) packages with proper path detection and validation.

---

## Package Manager Responsibilities

Package managers MUST handle these critical tasks in the correct order:

### 1. Pre-Installation (`%pre` / `preinst`)
- ✅ Create `nftban` system user (UID 995)
- ✅ Create `nftban-cli` group
- ✅ Verify system dependencies exist (bail out if missing)

### 2. Installation
- ✅ Install all files to correct locations
- ✅ Preserve existing config files (don't overwrite user configs)

### 3. Post-Installation (`%post` / `postinst`)
- ✅ Create FHS directory hierarchy
- ✅ Set correct ownership and permissions
- ✅ **RUN PATH VALIDATOR** to detect nft/fail2ban paths
- ✅ Save detected paths to `/etc/nftban/nftban.conf`
- ✅ Reload systemd daemon
- ✅ Display post-install message

### 4. Pre-Uninstall (`%preun` / `prerm`)
- ✅ Stop and disable systemd services
- ✅ Backup critical config files

### 5. Post-Uninstall (`%postun` / `postrm`)
- ✅ Clean up runtime directories
- ✅ Optionally remove nftban user (on purge only)

---

## RPM Spec File Template

```spec
# NFTBan v0.10.0 RPM Spec File

Name:           nftban
Version:        0.10.0
Release:        1%{?dist}
Summary:        Intelligent firewall management with fail2ban integration
License:        GPL-3.0-or-later
URL:            https://github.com/yourusername/nftban
Source0:        %{name}-%{version}.tar.gz

# REQUIRED Runtime Dependencies
Requires:       nftables >= 0.9.3
Requires:       bash >= 4.4
Requires:       systemd >= 239
Requires:       curl
Requires:       iproute
Requires:       gawk
Requires:       coreutils

# OPTIONAL Runtime Dependencies
Recommends:     fail2ban >= 0.11
Recommends:     mailx
Recommends:     jq

# Build Dependencies (NOT needed at runtime)
BuildRequires:  systemd-rpm-macros

%description
NFTBan is an intelligent firewall management system using nftables with:
- Two-table architecture (runtime + main)
- Fail2ban integration for temporary bans
- Persistent offender detection
- Auto-whitelist of SSH IPs to prevent lockout
- 5-minute startup delay for safe boot
- Comprehensive logging and statistics

%prep
%setup -q

%build
# No compilation needed - pure Bash

%install
# Install binaries
install -D -m 0755 src/usr/sbin/nftban %{buildroot}/usr/sbin/nftban
install -D -m 0755 src/usr/sbin/nftban-complete %{buildroot}/usr/sbin/nftban-complete

# Install libraries
mkdir -p %{buildroot}/usr/lib/nftban/{core,cli,integrations}
cp -r src/usr/lib/nftban/* %{buildroot}/usr/lib/nftban/

# Install configs (noreplace - don't overwrite user configs)
install -D -m 0644 src/etc/nftban/nftban.conf %{buildroot}/etc/nftban/nftban.conf
install -D -m 0644 src/etc/nftban/logging.conf %{buildroot}/etc/nftban/logging.conf

# Install systemd units
install -D -m 0644 src/packaging/systemd/nftban-firewall-init.service \
    %{buildroot}%{_unitdir}/nftban-firewall-init.service
install -D -m 0644 src/packaging/systemd/nftban-snapshot.service \
    %{buildroot}%{_unitdir}/nftban-snapshot.service
install -D -m 0644 src/packaging/systemd/nftban-snapshot.timer \
    %{buildroot}%{_unitdir}/nftban-snapshot.timer

# Install sysusers.d and tmpfiles.d
install -D -m 0644 src/packaging/sysusers.d/nftban.conf \
    %{buildroot}%{_sysusersdir}/nftban.conf
install -D -m 0644 src/packaging/tmpfiles.d/nftban.conf \
    %{buildroot}%{_tmpfilesdir}/nftban.conf

# Install shared resources
mkdir -p %{buildroot}/usr/share/nftban
cp -r src/usr/share/nftban/* %{buildroot}/usr/share/nftban/

# Install documentation
mkdir -p %{buildroot}/usr/share/doc/nftban
cp README.md CHANGELOG.md LICENSE %{buildroot}/usr/share/doc/nftban/

%pre
# Create nftban user and nftban-cli group
getent group nftban >/dev/null || groupadd -r nftban
getent group nftban-cli >/dev/null || groupadd -r nftban-cli
getent passwd nftban >/dev/null || \
    useradd -r -g nftban -d /var/lib/nftban -s /sbin/nologin \
    -c "NFTBan firewall management" -u 995 nftban 2>/dev/null || :

# Verify critical dependencies
if ! command -v nft >/dev/null 2>&1; then
    echo "ERROR: nftables (nft command) is required but not found!"
    echo "Install with: dnf install nftables"
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "ERROR: systemd is required but not found!"
    exit 1
fi

%post
# Create FHS directory hierarchy using systemd-tmpfiles
systemd-tmpfiles --create /usr/lib/tmpfiles.d/nftban.conf 2>/dev/null || :

# Set correct permissions on binaries
chmod 755 /usr/sbin/nftban /usr/sbin/nftban-complete

# Set correct permissions on libraries
find /usr/lib/nftban -type f -name "*.sh" -exec chmod 755 {} \;

# Set ownership: configs owned by nftban user
chown -R nftban:nftban /etc/nftban
chown -R nftban:nftban /var/lib/nftban 2>/dev/null || :
chown -R nftban:nftban /var/cache/nftban 2>/dev/null || :
chown -R nftban:adm /var/log/nftban 2>/dev/null || :

# CRITICAL: Run path validator to detect command locations
echo "Detecting command paths..."
if [ -x /usr/lib/nftban/core/path_validator.sh ]; then
    # Source path validator and save paths to config
    source /usr/lib/nftban/core/path_validator.sh
    if validate_all_paths; then
        save_paths_to_config /etc/nftban/nftban.conf
        echo "✓ Command paths detected and saved to /etc/nftban/nftban.conf"
    else
        echo "⚠ WARNING: Some required commands not found!"
        echo "  NFTBan may not function correctly."
    fi
fi

# Reload systemd daemon
%systemd_post nftban-firewall-init.service nftban-snapshot.timer

# Display post-install message
cat << 'EOF'

════════════════════════════════════════════════════════════
NFTBan v0.10.0 installed successfully!
════════════════════════════════════════════════════════════

Next steps:

1. Review configuration:
   vi /etc/nftban/nftban.conf

2. Initialize firewall (first time):
   nftban firewall init

3. Enable services for boot:
   systemctl enable nftban-firewall-init.service
   systemctl enable nftban-snapshot.timer

4. Check health:
   nftban firewall check

Documentation: /usr/share/doc/nftban/

IMPORTANT: The firewall has a 5-minute startup delay on boot
to prevent lockout. Configure via NFTBAN_STARTUP_DELAY in
/etc/nftban/nftban.conf

════════════════════════════════════════════════════════════
EOF

%preun
# Stop and disable services before uninstall
%systemd_preun nftban-firewall-init.service nftban-snapshot.timer

# Backup configs if this is a full uninstall (not upgrade)
if [ $1 -eq 0 ]; then
    echo "Backing up configs to /var/lib/nftban/backup..."
    mkdir -p /var/lib/nftban/backup
    tar -czf /var/lib/nftban/backup/nftban-config-$(date +%Y%m%d-%H%M%S).tar.gz \
        /etc/nftban 2>/dev/null || :
fi

%postun
# Clean up after uninstall
%systemd_postun_with_restart nftban-firewall-init.service nftban-snapshot.timer

# Full uninstall only (not upgrade)
if [ $1 -eq 0 ]; then
    # Remove runtime directories
    rm -rf /run/nftban 2>/dev/null || :

    # Optionally remove user (commented out by default - user may own files)
    # userdel nftban 2>/dev/null || :
    # groupdel nftban 2>/dev/null || :
    # groupdel nftban-cli 2>/dev/null || :

    echo "NFTBan has been uninstalled."
    echo "Config backup saved in /var/lib/nftban/backup/"
fi

%files
# Binaries
/usr/sbin/nftban
/usr/sbin/nftban-complete

# Libraries
/usr/lib/nftban/

# Configs (noreplace)
%config(noreplace) /etc/nftban/nftban.conf
%config(noreplace) /etc/nftban/logging.conf
%dir /etc/nftban/conf.d
%dir /etc/nftban/whitelist.d
%dir /etc/nftban/blacklist.d
%dir /etc/nftban/ports.d
%dir /etc/nftban/feeds.d
%dir /etc/nftban/rules.d
%dir /etc/nftban/secrets.d

# Systemd units
%{_unitdir}/nftban-firewall-init.service
%{_unitdir}/nftban-snapshot.service
%{_unitdir}/nftban-snapshot.timer

# Sysusers and tmpfiles
%{_sysusersdir}/nftban.conf
%{_tmpfilesdir}/nftban.conf

# Shared resources
/usr/share/nftban/

# Documentation
%doc /usr/share/doc/nftban/

# State directories (created by tmpfiles.d)
%dir %attr(0750,nftban,nftban) /var/lib/nftban
%dir %attr(0750,nftban,nftban) /var/cache/nftban
%dir %attr(0750,nftban,adm) /var/log/nftban

%changelog
* Tue Oct 29 2025 NFTBan Contributors <nftban@example.com> - 0.10.0-1
- Initial v0.10.0 release
- Added path validator for cross-OS compatibility
- Added 5-minute startup delay
- Added snapshot mechanism
- Fixed arithmetic bugs in firewall init
- Added policy accept for safe default
- Added auto-whitelist of SSH IPs
```

---

## DEB Control File Template

### `debian/control`

```
Source: nftban
Section: admin
Priority: optional
Maintainer: NFTBan Contributors <nftban@example.com>
Build-Depends: debhelper-compat (= 13)
Standards-Version: 4.6.0
Homepage: https://github.com/yourusername/nftban

Package: nftban
Architecture: all
Depends: nftables (>= 0.9.3),
         bash (>= 4.4),
         systemd (>= 239),
         curl,
         iproute2,
         gawk,
         coreutils
Recommends: fail2ban (>= 0.11),
            mailutils,
            jq
Description: Intelligent firewall management with fail2ban integration
 NFTBan is an intelligent firewall management system using nftables with:
  - Two-table architecture (runtime + main)
  - Fail2ban integration for temporary bans
  - Persistent offender detection
  - Auto-whitelist of SSH IPs to prevent lockout
  - 5-minute startup delay for safe boot
  - Comprehensive logging and statistics
```

### `debian/preinst`

```bash
#!/bin/bash
set -e

# Create nftban user and groups
if ! getent group nftban >/dev/null; then
    addgroup --system nftban
fi

if ! getent group nftban-cli >/dev/null; then
    addgroup --system nftban-cli
fi

if ! getent passwd nftban >/dev/null; then
    adduser --system --home /var/lib/nftban --no-create-home \
            --ingroup nftban --disabled-password --disabled-login \
            --uid 995 --gecos "NFTBan firewall management" nftban 2>/dev/null || true
fi

# Verify critical dependencies
if ! command -v nft >/dev/null 2>&1; then
    echo "ERROR: nftables (nft command) is required but not found!" >&2
    echo "Install with: apt install nftables" >&2
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "ERROR: systemd is required but not found!" >&2
    exit 1
fi

#DEBHELPER#

exit 0
```

### `debian/postinst`

```bash
#!/bin/bash
set -e

case "$1" in
    configure)
        # Create FHS directory hierarchy
        systemd-tmpfiles --create /usr/lib/tmpfiles.d/nftban.conf 2>/dev/null || true

        # Set correct permissions
        chmod 755 /usr/sbin/nftban /usr/sbin/nftban-complete
        find /usr/lib/nftban -type f -name "*.sh" -exec chmod 755 {} \;

        # Set ownership
        chown -R nftban:nftban /etc/nftban
        chown -R nftban:nftban /var/lib/nftban 2>/dev/null || true
        chown -R nftban:nftban /var/cache/nftban 2>/dev/null || true
        chown -R nftban:adm /var/log/nftban 2>/dev/null || true

        # CRITICAL: Run path validator
        echo "Detecting command paths..."
        if [ -x /usr/lib/nftban/core/path_validator.sh ]; then
            # Source and run validator
            source /usr/lib/nftban/core/path_validator.sh
            if validate_all_paths; then
                save_paths_to_config /etc/nftban/nftban.conf
                echo "✓ Command paths detected and saved"
            else
                echo "⚠ WARNING: Some required commands not found!" >&2
            fi
        fi

        # Display post-install message
        cat << 'EOF'

════════════════════════════════════════════════════════════
NFTBan v0.10.0 installed successfully!
════════════════════════════════════════════════════════════

Next steps:

1. Review configuration:
   vi /etc/nftban/nftban.conf

2. Initialize firewall (first time):
   nftban firewall init

3. Enable services for boot:
   systemctl enable nftban-firewall-init.service
   systemctl enable nftban-snapshot.timer

4. Check health:
   nftban firewall check

Documentation: /usr/share/doc/nftban/

IMPORTANT: The firewall has a 5-minute startup delay on boot
to prevent lockout. Configure via NFTBAN_STARTUP_DELAY in
/etc/nftban/nftban.conf

════════════════════════════════════════════════════════════
EOF
        ;;
esac

#DEBHELPER#

exit 0
```

### `debian/prerm`

```bash
#!/bin/bash
set -e

case "$1" in
    remove|deconfigure)
        # Stop and disable services
        deb-systemd-invoke stop nftban-firewall-init.service nftban-snapshot.timer 2>/dev/null || true

        # Backup configs
        if [ "$1" = "remove" ]; then
            echo "Backing up configs..."
            mkdir -p /var/lib/nftban/backup
            tar -czf /var/lib/nftban/backup/nftban-config-$(date +%Y%m%d-%H%M%S).tar.gz \
                /etc/nftban 2>/dev/null || true
        fi
        ;;
esac

#DEBHELPER#

exit 0
```

### `debian/postrm`

```bash
#!/bin/bash
set -e

case "$1" in
    purge)
        # Remove runtime directories
        rm -rf /run/nftban 2>/dev/null || true

        # Remove user and groups on purge
        if getent passwd nftban >/dev/null; then
            deluser --system nftban 2>/dev/null || true
        fi

        if getent group nftban >/dev/null; then
            delgroup --system nftban 2>/dev/null || true
        fi

        if getent group nftban-cli >/dev/null; then
            delgroup --system nftban-cli 2>/dev/null || true
        fi

        echo "NFTBan has been purged."
        ;;

    remove)
        echo "NFTBan has been removed."
        echo "Config backup saved in /var/lib/nftban/backup/"
        ;;
esac

#DEBHELPER#

exit 0
```

---

## Testing Package Installation

### RPM Testing:

```bash
# Build RPM
rpmbuild -ba nftban.spec

# Install
dnf install ./RPMS/noarch/nftban-0.10.0-1.*.noarch.rpm

# Verify paths were detected
grep "NFTBAN_NFT_PATH" /etc/nftban/nftban.conf
grep "NFTBAN_FAIL2BAN_CLIENT_PATH" /etc/nftban/nftban.conf

# Test firewall init
nftban firewall init

# Check services
systemctl status nftban-firewall-init.service
```

### DEB Testing:

```bash
# Build DEB
dpkg-buildpackage -us -uc

# Install
apt install ./nftban_0.10.0-1_all.deb

# Verify paths were detected
grep "NFTBAN_NFT_PATH" /etc/nftban/nftban.conf

# Test firewall init
nftban firewall init

# Check services
systemctl status nftban-firewall-init.service
```

---

## Path Validator Integration

The path_validator.sh module provides these functions for package scripts:

```bash
# Source the module
source /usr/lib/nftban/core/path_validator.sh

# Validate all paths
if validate_all_paths; then
    echo "✓ All required commands found"

    # Save detected paths to config
    save_paths_to_config /etc/nftban/nftban.conf

    # Export to environment
    export_paths_to_env

    # Print what was found
    print_detected_paths
else
    echo "✗ Some required commands missing"
    exit 1
fi
```

---

## Key Points for Package Maintainers

1. **ALWAYS run path validator in postinst** - This ensures nft and fail2ban paths are detected correctly regardless of OS

2. **Mark configs as noreplace** - User configs should never be overwritten on upgrade

3. **Create backup on uninstall** - Save user configs before removing

4. **Verify dependencies in preinst** - Bail out early if nftables not installed

5. **Use systemd-tmpfiles** - Let systemd create directories with correct permissions

6. **Don't remove user on package removal** - Only on purge (DEB) or never (RPM)

7. **Test on multiple OS versions** - RHEL 8/9, Ubuntu 20.04/22.04/24.04, Debian 11/12

---

**Document Version:** 1.0
**Last Updated:** 2025-10-29
**Status:** ✅ READY FOR PACKAGE CREATION
