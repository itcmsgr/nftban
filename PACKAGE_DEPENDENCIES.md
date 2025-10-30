# NFTBan v0.10.0 - Complete Package Dependencies
**CRITICAL: Package Manager MUST Install These BEFORE NFTBan**

═══════════════════════════════════════════════════════════════════

## 📦 REQUIRED DEPENDENCIES (MUST BE INSTALLED)

### System Requirements
```
Operating System: Linux (kernel 5.8+)
Architecture: x86_64, aarch64
Init System: systemd
```

### Core Dependencies (REQUIRED)

#### 1. nftables (CRITICAL - Firewall Backend)
```rpm
Requires: nftables >= 0.9.3
```
```deb
Depends: nftables (>= 0.9.3)
```

**Purpose:** Core firewall engine that NFTBan controls

---

#### 2. Bash (CRITICAL - Shell Interpreter)
```rpm
Requires: bash >= 4.4
```
```deb
Depends: bash (>= 4.4)
```

**Purpose:** NFTBan is written in Bash

---

#### 3. Go (CRITICAL - For nftban-complete binary)
```rpm
BuildRequires: golang >= 1.18
# Runtime not needed if statically compiled
```
```deb
Build-Depends: golang-go (>= 2:1.18)
# Runtime not needed if statically compiled
```

**Purpose:** Build nftban-complete (main engine)
**Note:** If binary is statically compiled, NOT needed at runtime

---

#### 4. coreutils (REQUIRED)
```rpm
Requires: coreutils
```
```deb
Depends: coreutils
```

**Purpose:** Basic utilities (cat, grep, awk, etc.)

---

#### 5. curl or wget (REQUIRED - For IP detection)
```rpm
Requires: curl
```
```deb
Depends: curl
```

**Purpose:** Detect public IP during init (ifconfig.me)

---

#### 6. systemd (REQUIRED)
```rpm
Requires: systemd >= 239
```
```deb
Depends: systemd (>= 239)
```

**Purpose:** Service management, tmpfiles, sysusers

---

#### 7. iproute2 (REQUIRED)
```rpm
Requires: iproute
```
```deb
Depends: iproute2
```

**Purpose:** ss command for SSH client IP detection

---

### Optional Dependencies (RECOMMENDED)

#### 8. fail2ban (OPTIONAL - For fail2ban integration)
```rpm
Suggests: fail2ban >= 0.11
```
```deb
Suggests: fail2ban (>= 0.11)
```

**Purpose:** Automatic ban integration with fail2ban
**When Needed:** Only if using `nftban fail2ban` module

---

#### 9. GeoIP Database (OPTIONAL)
```rpm
Suggests: geoipupdate
```
```deb
Suggests: geoipupdate
```

**Purpose:** GeoIP-based blocking
**When Needed:** Only if using GeoIP features

---

#### 10. mailx/s-nail (OPTIONAL - For email alerts)
```rpm
Suggests: mailx
```
```deb
Suggests: bsd-mailx | mailutils
```

**Purpose:** Send email alerts
**When Needed:** Only if using email notifications

---

#### 11. jq (OPTIONAL - For JSON processing)
```rpm
Suggests: jq
```
```deb
Suggests: jq
```

**Purpose:** JSON processing for stats/reports
**When Needed:** Only if using stats/reporting features

---

## 📋 COMPLETE INSTALLATION ORDER

### For RPM (Fedora/RHEL/CentOS/AlmaLinux)

```spec
# NFTBan RPM Spec File
Name:           nftban
Version:        0.10.0
Release:        1%{?dist}
Summary:        Advanced nftables-based firewall management system

License:        Apache-2.0
URL:            https://github.com/yourusername/nftban
Source0:        %{name}-%{version}.tar.gz

# Build requirements
BuildRequires:  golang >= 1.18
BuildRequires:  systemd-rpm-macros
BuildRequires:  bash >= 4.4

# Runtime requirements (CRITICAL - MUST BE INSTALLED FIRST)
Requires:       nftables >= 0.9.3
Requires:       bash >= 4.4
Requires:       coreutils
Requires:       curl
Requires:       systemd >= 239
Requires:       iproute
Requires(pre):  shadow-utils
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd

# Optional but recommended
Suggests:       fail2ban >= 0.11
Suggests:       geoipupdate
Suggests:       mailx
Suggests:       jq

%description
NFTBan is an advanced firewall management system built on nftables.
It provides automated IP banning, whitelist/blacklist management,
port management, and integration with fail2ban.

%prep
%setup -q

%build
# Build nftban-complete from Go source
cd src/usr/sbin
/usr/local/go/bin/go build -o nftban-complete \
    -ldflags "-X main.Version=%{version}" \
    nftban-complete.go

%install
rm -rf %{buildroot}

# Install binaries
install -D -m 0755 src/usr/sbin/nftban %{buildroot}%{_sbindir}/nftban
install -D -m 0755 src/usr/sbin/nftban-complete %{buildroot}%{_sbindir}/nftban-complete
install -D -m 0755 src/usr/sbin/nftban-runtime %{buildroot}%{_sbindir}/nftban-runtime

# Install libraries
mkdir -p %{buildroot}%{_prefix}/lib/nftban
cp -r src/usr/lib/nftban/* %{buildroot}%{_prefix}/lib/nftban/

# Install shared data
mkdir -p %{buildroot}%{_datadir}/nftban
cp -r src/usr/share/nftban/* %{buildroot}%{_datadir}/nftban/

# Install configs
mkdir -p %{buildroot}%{_sysconfdir}/nftban
cp -r src/etc/nftban/* %{buildroot}%{_sysconfdir}/nftban/

# Install systemd units
install -D -m 0644 src/packaging/systemd/nftban.service %{buildroot}%{_unitdir}/nftban.service
install -D -m 0644 src/packaging/systemd/nftban.timer %{buildroot}%{_unitdir}/nftban.timer
install -D -m 0644 src/packaging/systemd/nftban-apply.service %{buildroot}%{_unitdir}/nftban-apply.service
install -D -m 0644 src/packaging/systemd/nftban-rollback.service %{buildroot}%{_unitdir}/nftban-rollback.service
install -D -m 0644 src/packaging/systemd/nftban-rollback.timer %{buildroot}%{_unitdir}/nftban-rollback.timer

# Install sysusers and tmpfiles
install -D -m 0644 src/packaging/sysusers.d/nftban.conf %{buildroot}%{_sysusersdir}/nftban.conf
install -D -m 0644 src/packaging/tmpfiles.d/nftban.conf %{buildroot}%{_tmpfilesdir}/nftban.conf

# Install bash completion
install -D -m 0644 src/etc/bash_completion.d/nftban %{buildroot}%{_sysconfdir}/bash_completion.d/nftban

# Install cron
install -D -m 0644 src/etc/cron.d/nftban %{buildroot}%{_sysconfdir}/cron.d/nftban

# Install logrotate
install -D -m 0644 src/etc/logrotate.d/nftban %{buildroot}%{_sysconfdir}/logrotate.d/nftban

%pre
# Create nftban user and groups BEFORE installing files
getent group nftban >/dev/null || groupadd -r nftban
getent group nftban-cli >/dev/null || groupadd -r nftban-cli
getent passwd nftban >/dev/null || \
    useradd -r -g nftban -d /var/lib/nftban -s /sbin/nologin \
    -c "nftban service user" nftban
exit 0

%post
# Create runtime directories
%tmpfiles_create nftban.conf

# Set ownership and permissions
chown -R nftban:nftban %{_sysconfdir}/nftban
chown -R nftban:nftban %{_sharedstatedir}/nftban
chown -R nftban:nftban %{_localstatedir}/cache/nftban
chown -R nftban:adm %{_localstatedir}/log/nftban
chmod 750 %{_sysconfdir}/nftban/secrets.d

# Enable systemd services
%systemd_post nftban.timer nftban-rollback.timer

# Post-install message
cat <<'EOMSG'
════════════════════════════════════════════════════════════
NFTBan v0.10.0 Installed Successfully
════════════════════════════════════════════════════════════

Dependencies installed:
  ✓ nftables   - Firewall backend
  ✓ bash       - Shell interpreter
  ✓ systemd    - Service management
  ✓ curl       - IP detection
  ✓ iproute    - Network tools

IMPORTANT: Firewall NOT auto-activated for safety!

Next Steps:
1. Initialize firewall:
   nftban firewall init

2. Enable timers:
   systemctl start nftban.timer
   systemctl start nftban-rollback.timer

3. Check status:
   nftban status

Documentation: /usr/share/nftban/docs/
════════════════════════════════════════════════════════════
EOMSG

%preun
%systemd_preun nftban.timer nftban-rollback.timer

%postun
%systemd_postun_with_restart nftban.timer nftban-rollback.timer

%files
# Binaries
%{_sbindir}/nftban
%{_sbindir}/nftban-complete
%{_sbindir}/nftban-runtime

# Libraries
%{_prefix}/lib/nftban/

# Shared data
%{_datadir}/nftban/

# Configs (preserved on upgrade)
%config(noreplace) %{_sysconfdir}/nftban/nftban.conf
%config(noreplace) %{_sysconfdir}/nftban/conf.d/*.conf
%config(noreplace) %{_sysconfdir}/nftban/baseline.nft
%dir %{_sysconfdir}/nftban/
%dir %{_sysconfdir}/nftban/conf.d/
%dir %{_sysconfdir}/nftban/whitelist.d/
%dir %{_sysconfdir}/nftban/blacklist.d/
%dir %{_sysconfdir}/nftban/ports.d/
%dir %{_sysconfdir}/nftban/feeds.d/
%dir %{_sysconfdir}/nftban/rules.d/
%dir %attr(0750,nftban,nftban) %{_sysconfdir}/nftban/secrets.d/

# Systemd units
%{_unitdir}/nftban.service
%{_unitdir}/nftban.timer
%{_unitdir}/nftban-apply.service
%{_unitdir}/nftban-rollback.service
%{_unitdir}/nftban-rollback.timer

# System integration
%{_sysusersdir}/nftban.conf
%{_tmpfilesdir}/nftban.conf
%{_sysconfdir}/bash_completion.d/nftban
%{_sysconfdir}/cron.d/nftban
%{_sysconfdir}/logrotate.d/nftban

# State directories (created by tmpfiles.d)
%dir %attr(0750,nftban,nftban) %{_sharedstatedir}/nftban/
%dir %attr(0750,nftban,nftban) %{_localstatedir}/cache/nftban/
%dir %attr(0750,nftban,adm) %{_localstatedir}/log/nftban/

%changelog
* Tue Oct 29 2025 Your Name <email@example.com> - 0.10.0-1
- Initial v0.10.0 release
- Complete FHS compliance
- Auto SSH port detection from sshd_config
- Auto IP whitelisting on init
- Startup delay configuration
- Two-table architecture (runtime + main)
```

---

### For DEB (Debian/Ubuntu)

```debian/control
Source: nftban
Section: admin
Priority: optional
Maintainer: Your Name <email@example.com>
Build-Depends: debhelper-compat (= 13),
               golang-go (>= 2:1.18),
               bash (>= 4.4),
               systemd
Standards-Version: 4.6.0
Homepage: https://github.com/yourusername/nftban

Package: nftban
Architecture: amd64 arm64
Depends: ${shlibs:Depends},
         ${misc:Depends},
         nftables (>= 0.9.3),
         bash (>= 4.4),
         coreutils,
         curl,
         systemd (>= 239),
         iproute2
Suggests: fail2ban (>= 0.11),
          geoipupdate,
          bsd-mailx | mailutils,
          jq
Description: Advanced nftables-based firewall management system
 NFTBan is an advanced firewall management system built on nftables.
 It provides automated IP banning, whitelist/blacklist management,
 port management, and integration with fail2ban.
 .
 Features:
  - Two-table architecture (runtime + main)
  - Auto SSH port detection from sshd_config
  - Auto IP whitelisting on firewall init
  - Fail2ban integration
  - GeoIP-based blocking
  - Email alerts
  - Comprehensive health checks
```

```debian/install
# Binaries
src/usr/sbin/nftban usr/sbin/
src/usr/sbin/nftban-complete usr/sbin/
src/usr/sbin/nftban-runtime usr/sbin/

# Libraries
src/usr/lib/nftban/* usr/lib/nftban/

# Shared data
src/usr/share/nftban/* usr/share/nftban/

# Configs
src/etc/nftban/* etc/nftban/

# Systemd
src/packaging/systemd/*.service usr/lib/systemd/system/
src/packaging/systemd/*.timer usr/lib/systemd/system/

# System integration
src/packaging/sysusers.d/nftban.conf usr/lib/sysusers.d/
src/packaging/tmpfiles.d/nftban.conf usr/lib/tmpfiles.d/
src/etc/bash_completion.d/nftban etc/bash_completion.d/
src/etc/cron.d/nftban etc/cron.d/
src/etc/logrotate.d/nftban etc/logrotate.d/
```

---

## 🔍 DEPENDENCY VALIDATION

### Pre-Flight Check Script (for package manager)

```bash
#!/bin/bash
# check_dependencies.sh - Run BEFORE NFTBan installation

check_dependency() {
    local name=$1
    local command=$2
    local required=$3

    if command -v $command &>/dev/null; then
        echo "✓ $name: $(command -v $command)"
        return 0
    else
        if [[ "$required" == "REQUIRED" ]]; then
            echo "✗ $name: MISSING (REQUIRED)"
            return 1
        else
            echo "⚠ $name: missing (optional)"
            return 0
        fi
    fi
}

echo "Checking NFTBan dependencies..."
echo ""

MISSING=0

# REQUIRED
check_dependency "nftables" "nft" "REQUIRED" || ((MISSING++))
check_dependency "bash" "bash" "REQUIRED" || ((MISSING++))
check_dependency "systemd" "systemctl" "REQUIRED" || ((MISSING++))
check_dependency "curl" "curl" "REQUIRED" || ((MISSING++))
check_dependency "ss (iproute)" "ss" "REQUIRED" || ((MISSING++))
check_dependency "awk" "awk" "REQUIRED" || ((MISSING++))
check_dependency "grep" "grep" "REQUIRED" || ((MISSING++))

# OPTIONAL
check_dependency "fail2ban" "fail2ban-client" "OPTIONAL"
check_dependency "jq" "jq" "OPTIONAL"
check_dependency "mailx" "mail" "OPTIONAL"

echo ""
if [[ $MISSING -gt 0 ]]; then
    echo "❌ FAILED: $MISSING required dependencies missing"
    echo ""
    echo "Install missing dependencies:"
    echo "  RHEL/Fedora: dnf install nftables bash systemd curl iproute"
    echo "  Debian/Ubuntu: apt install nftables bash systemd curl iproute2"
    exit 1
else
    echo "✅ All required dependencies satisfied"
    exit 0
fi
```

---

## 📝 INSTALLATION CHECKLIST

Package manager MUST do these in order:

1. ✅ **Check dependencies** (nftables, bash, systemd, curl, iproute)
2. ✅ **Create nftban user** (via sysusers.d)
3. ✅ **Create nftban-cli group**
4. ✅ **Install files** (binaries, libraries, configs)
5. ✅ **Create directories** (via tmpfiles.d)
6. ✅ **Set permissions** (nftban:nftban, root:root)
7. ✅ **Reload systemd daemon**
8. ✅ **Enable timers** (but DON'T start firewall)
9. ✅ **Show post-install message**

**User MUST manually run:** `nftban firewall init`

---

**Document Version:** 1.0
**Created:** 2025-10-29
**Status:** ✅ COMPLETE - READY FOR PACKAGE CREATION

═══════════════════════════════════════════════════════════════════
