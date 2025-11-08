# =============================================================================
# NFTBan v0.32.20 - RPM Spec File
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: RPM package specification for Red Hat-based distributions
# Supported: Rocky Linux 9+, AlmaLinux 9+, Fedora 38+
# =============================================================================

# Disable debuginfo package generation (shell scripts don't need debug symbols)
%global debug_package %{nil}

Name:           nftban
Version:        0.32.20
Release:        1%{?dist}
Summary:        Modern nftables firewall with self-healing inventory monitoring

License:        MPL-2.0
URL:            https://nftban.com
Source0:        %{name}-%{version}.tar.gz

# Build requirements
BuildArch:      x86_64 aarch64
BuildRequires:  systemd-rpm-macros
BuildRequires:  golang >= 1.21

# Runtime requirements - Core dependencies
Requires:       nftables >= 1.0.0
Requires:       systemd >= 250
Requires:       bash >= 5.0
Requires:       bash-completion
Requires:       jq >= 1.6
Requires:       curl
Requires:       python3
Requires:       shadow-utils
Requires:       coreutils
Requires:       gzip
Requires:       tar
Requires:       grep
Requires:       sed
Requires:       gawk
Requires:       findutils
Requires:       util-linux
Requires:       iproute
Requires:       ipset
Requires:       git
Requires:       polkit
Requires:       fail2ban-server >= 0.11
Requires:       newt
Recommends:     logrotate

# Conflicts
Conflicts:      firewalld
Conflicts:      iptables-services
Conflicts:      iptables

%description
NFTBan is a modern, high-performance firewall management system for Linux
servers using nftables with advanced self-healing and inventory monitoring.

Features include:
- Commit-confirm recovery (prevents lockout)
- Go binaries for 10-60x faster feed processing
- 8 security layers (DDoS, port scan, geo-blocking, threat feeds)
- FHS-compliant with auto-healing health system
- Integration with Fail2Ban for automatic banning
- Stats & metrics with HTML/JSON/CSV reporting
- Advanced inventory system (processes, packages, firewall state)
- Baseline management with drift detection
- Cryptographic verification and signing
- Smart mail adapter (auto-detects best transport)

NOTE: For fail2ban installation on Rocky/AlmaLinux:
1. Enable EPEL: dnf install -y epel-release
2. Enable CRB: crb enable
3. Install: dnf install -y fail2ban-server

fail2ban-server is recommended (not fail2ban) to avoid firewalld conflict.

%prep
%setup -q

%build
# Build Go binaries for current architecture during package build
# This ensures transparency - source code is built on user's system

# Detect architecture for Go build
%ifarch x86_64
GO_ARCH=amd64
%endif
%ifarch aarch64
GO_ARCH=arm64
%endif

# Create output directory
mkdir -p dist/%{_arch}

# Build nftban-geoip
echo "Building nftban-geoip for ${GO_ARCH}..."
cd go-geoip
go mod download
go mod tidy
CGO_ENABLED=0 GOOS=linux GOARCH=${GO_ARCH} \
  go build -buildvcs=false \
  -ldflags "-s -w -X main.VERSION=%{version}" \
  -o ../dist/%{_arch}/nftban-geoip \
  ./cmd/nftban-geoip
cd ..

# Build nftban-feeds
echo "Building nftban-feeds for ${GO_ARCH}..."
cd go-feeds
go mod download
go mod tidy
CGO_ENABLED=0 GOOS=linux GOARCH=${GO_ARCH} \
  go build -buildvcs=false \
  -ldflags "-s -w -X main.VERSION=%{version}" \
  -o ../dist/%{_arch}/nftban-feeds \
  ./cmd/nftban-feeds
cd ..

echo "Verifying built binaries..."
ls -lh dist/%{_arch}/

%install
# Install binaries
install -d -m 0755 %{buildroot}/usr/sbin
install -m 0755 src/usr/sbin/nftban %{buildroot}/usr/sbin/
install -m 0755 src/usr/sbin/nftban-complete %{buildroot}/usr/sbin/
install -m 0755 src/usr/sbin/nftban-apply %{buildroot}/usr/sbin/
install -m 0755 src/usr/sbin/nftban-confirm %{buildroot}/usr/sbin/
install -m 0755 src/usr/sbin/nftban-rollback %{buildroot}/usr/sbin/

# Install Go binaries (wrappers + architecture-specific real binaries)
install -d -m 0755 %{buildroot}/usr/lib/nftban/bin
install -d -m 0755 %{buildroot}/usr/lib/nftban/bin/.real

# Install wrapper scripts (if they exist)
if [ -f src/usr/lib/nftban/bin/nftban-feeds ]; then
    install -m 0755 src/usr/lib/nftban/bin/nftban-feeds %{buildroot}/usr/lib/nftban/bin/
else
    # Create simple wrapper if not exists
    cat > %{buildroot}/usr/lib/nftban/bin/nftban-feeds << 'EOF'
#!/bin/bash
exec /usr/lib/nftban/bin/.real/nftban-feeds-$(uname -m) "$@"
EOF
    chmod 0755 %{buildroot}/usr/lib/nftban/bin/nftban-feeds
fi

if [ -f src/usr/lib/nftban/bin/nftban-geoip ]; then
    install -m 0755 src/usr/lib/nftban/bin/nftban-geoip %{buildroot}/usr/lib/nftban/bin/
else
    cat > %{buildroot}/usr/lib/nftban/bin/nftban-geoip << 'EOF'
#!/bin/bash
exec /usr/lib/nftban/bin/.real/nftban-geoip-$(uname -m) "$@"
EOF
    chmod 0755 %{buildroot}/usr/lib/nftban/bin/nftban-geoip
fi

# Install compiled Go binaries with architecture suffix
install -m 0755 dist/%{_arch}/nftban-feeds %{buildroot}/usr/lib/nftban/bin/.real/nftban-feeds-%{_arch}
install -m 0755 dist/%{_arch}/nftban-geoip %{buildroot}/usr/lib/nftban/bin/.real/nftban-geoip-%{_arch}

# Install core and CLI modules
install -d -m 0755 %{buildroot}/usr/lib/nftban/core
install -m 0644 src/usr/lib/nftban/core/*.sh %{buildroot}/usr/lib/nftban/core/

install -d -m 0755 %{buildroot}/usr/lib/nftban/cli
install -m 0644 src/usr/lib/nftban/cli/cmd_*.sh %{buildroot}/usr/lib/nftban/cli/

# Install help system
install -m 0644 src/usr/lib/nftban/nftban_help.sh %{buildroot}/usr/lib/nftban/

# Install cron scripts (run.sh, maintenance.sh)
install -d -m 0755 %{buildroot}/usr/lib/nftban/cron
install -m 0755 src/usr/lib/nftban/cron/*.sh %{buildroot}/usr/lib/nftban/cron/

# Install helpers (autoheal, etc.)
install -d -m 0755 %{buildroot}/usr/lib/nftban/helpers
install -m 0755 src/usr/lib/nftban/helpers/*.sh %{buildroot}/usr/lib/nftban/helpers/

# Install nft runtime
install -m 0644 src/usr/lib/nftban/nft-runtime.nft %{buildroot}/usr/lib/nftban/

# Install shared data
install -d -m 0755 %{buildroot}/usr/share/nftban
cp -a src/usr/share/nftban/* %{buildroot}/usr/share/nftban/

# Install configuration files
install -d -m 0750 %{buildroot}/etc/nftban
install -d -m 0750 %{buildroot}/etc/nftban/conf.d
install -d -m 0750 %{buildroot}/etc/nftban/feeds.d
install -d -m 0750 %{buildroot}/etc/nftban/rules.d
install -d -m 0700 %{buildroot}/etc/nftban/secrets.d

install -m 0640 src/etc/nftban/nftban.conf %{buildroot}/etc/nftban/
install -m 0640 src/etc/nftban/baseline.nft %{buildroot}/etc/nftban/
install -m 0640 src/etc/nftban/conf.d/*.conf %{buildroot}/etc/nftban/conf.d/
install -m 0640 src/etc/nftban/conf.d/health.conf %{buildroot}/etc/nftban/conf.d/
install -m 0640 src/etc/nftban/feeds.d/.gitkeep %{buildroot}/etc/nftban/feeds.d/
install -m 0640 src/etc/nftban/rules.d/.gitkeep %{buildroot}/etc/nftban/rules.d/
install -m 0644 src/etc/nftban/secrets.d/.gitkeep %{buildroot}/etc/nftban/secrets.d/

# Install fail2ban integration files
install -d -m 0755 %{buildroot}/etc/fail2ban/action.d
install -d -m 0755 %{buildroot}/etc/fail2ban/filter.d
install -d -m 0755 %{buildroot}/etc/fail2ban/jail.d

install -m 0644 src/etc/fail2ban/action.d/nftban.conf %{buildroot}/etc/fail2ban/action.d/
install -m 0644 src/etc/fail2ban/filter.d/nftban-*.conf %{buildroot}/etc/fail2ban/filter.d/
install -m 0644 src/etc/fail2ban/jail.d/nftban-*.conf %{buildroot}/etc/fail2ban/jail.d/

# Create FHS directories
install -d -m 0755 %{buildroot}/var/lib/nftban/{state,snapshots,feeds,keyring,backup,reports,metrics,config,geoip}
install -d -m 0755 %{buildroot}/var/lib/nftban/geoban/tracking
install -d -m 0755 %{buildroot}/var/cache/nftban/{geoip,geoban,feeds,tmp}
install -d -m 0750 %{buildroot}/var/log/nftban
install -d -m 0755 %{buildroot}/run/nftban

# Create GeoBan configuration directory
install -d -m 0750 %{buildroot}/etc/nftban/geoban.d

# Install systemd units
install -d -m 0755 %{buildroot}%{_unitdir}
install -m 0644 src/usr/lib/systemd/system/*.service %{buildroot}%{_unitdir}/
install -m 0644 src/usr/lib/systemd/system/*.timer %{buildroot}%{_unitdir}/

# Install sysusers.d
install -d -m 0755 %{buildroot}%{_sysusersdir}
install -m 0644 packaging/sysusers.d/nftban.conf %{buildroot}%{_sysusersdir}/nftban.conf

# Install tmpfiles.d
install -d -m 0755 %{buildroot}%{_tmpfilesdir}
install -m 0644 packaging/tmpfiles.d/nftban.conf %{buildroot}%{_tmpfilesdir}/nftban.conf

# Install logrotate
install -d -m 0755 %{buildroot}%{_sysconfdir}/logrotate.d
install -m 0644 src/etc/logrotate.d/nftban %{buildroot}%{_sysconfdir}/logrotate.d/nftban

# Install bash completion
install -d -m 0755 %{buildroot}%{_datadir}/bash-completion/completions
install -m 0644 src/usr/share/nftban/completions/nftban.bash \
    %{buildroot}%{_datadir}/bash-completion/completions/nftban

# Install man page
install -d -m 0755 %{buildroot}%{_mandir}/man1
install -m 0644 docs/nftban.1 %{buildroot}%{_mandir}/man1/nftban.1

# Install Polkit rules
install -d -m 0755 %{buildroot}%{_datadir}/polkit-1/rules.d
install -m 0644 packaging/polkit-1/rules.d/60-nftban-cli.rules \
    %{buildroot}%{_datadir}/polkit-1/rules.d/60-nftban-cli.rules

# ============================================================================
# Inventory & Health Monitoring System
# ============================================================================
# NOTE: NFTBAN_AI_TESTING directory removed (was development-only directory)
#       All inventory/health/mail features are integrated in main src/ tree

# Install Polkit rules for nftban-auditors group
install -m 0644 packaging/polkit-1/rules.d/50-nftban-v030.rules \
    %{buildroot}%{_datadir}/polkit-1/rules.d/50-nftban-v030.rules

# Create inventory directories
install -d -m 0755 %{buildroot}/var/lib/nftban/reports/baseline
install -d -m 0770 %{buildroot}/var/lib/nftban/reports/auditors
install -d -m 0700 %{buildroot}/etc/nftban/keys

# Install license files
install -d -m 0755 %{buildroot}/usr/share/licenses/nftban
install -m 0644 licenses/MPL-2.0.txt %{buildroot}/usr/share/licenses/nftban/
install -m 0644 licenses/NFTBAN-Pro-Commercial.md %{buildroot}/usr/share/licenses/nftban/
install -m 0644 licenses/NFTBAN-Docs.txt %{buildroot}/usr/share/licenses/nftban/

# Install project documentation to /usr/share/nftban/docs/
mkdir -p %{buildroot}/usr/share/nftban/docs
install -m 0644 NOTICE.md %{buildroot}/usr/share/nftban/docs/
install -m 0644 TRADEMARK.md %{buildroot}/usr/share/nftban/docs/
install -m 0644 CONTRIBUTING.md %{buildroot}/usr/share/nftban/docs/
install -m 0644 docs/CODING_STANDARDS.md %{buildroot}/usr/share/nftban/docs/

%pre
# =============================================================================
# NFTBan Pre-Installation Checks for Rocky/AlmaLinux/CentOS
# =============================================================================
# Philosophy: We check what WE NEED. If YOUR repos have conflicts, fix them.
# We don't manage vendor repositories - that's the user's responsibility.
#
# What NFTBan requires:
#   - nftables, systemd, bash, fail2ban-server, golang (for building Go binaries)
#   - On Rocky/Alma: EPEL + CRB/PowerTools repos (for fail2ban and dependencies)
#
# Common problems we detect:
#   - Missing EPEL or CRB/PowerTools repos
#   - Conflicting testing repos (epel-testing, epel-modular, epel-next)
#   - Conflicting golang installs (/usr/local/go vs distro golang)
#   - Package version mismatches (fixed with: dnf distro-sync)
# =============================================================================

# Only run on fresh install (not upgrade)
if [ $1 -eq 1 ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan Pre-Installation: System Requirements Check"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Detect OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION_ID="${VERSION_ID%%.*}"  # Get major version only
    else
        OS_ID="unknown"
        OS_VERSION_ID="0"
    fi

    echo "Detected OS: ${OS_ID} ${OS_VERSION_ID}"
    echo ""

    # Check repos based on OS
    case "${OS_ID}" in
        almalinux|rocky|centos)
            # Rocky/AlmaLinux/CentOS require EPEL + CRB/PowerTools
            echo "Checking required repositories..."
            echo ""

            PROBLEMS_FOUND=false
            FIX_COMMANDS=""

            # Check EPEL
            if ! dnf repolist enabled 2>/dev/null | grep -q 'epel[^-]'; then
                echo "❌ EPEL repository: NOT enabled"
                PROBLEMS_FOUND=true
                FIX_COMMANDS="${FIX_COMMANDS}sudo dnf install -y epel-release\n"
            else
                echo "✓ EPEL repository: enabled"
            fi

            # Check CRB/PowerTools
            if [ "$OS_VERSION_ID" -ge 9 ]; then
                CRB_NAME="crb"
            else
                CRB_NAME="powertools"
            fi

            if ! dnf repolist enabled 2>/dev/null | grep -qE "${CRB_NAME}"; then
                echo "❌ ${CRB_NAME} repository: NOT enabled"
                PROBLEMS_FOUND=true
                FIX_COMMANDS="${FIX_COMMANDS}sudo dnf config-manager --set-enabled ${CRB_NAME}\n"
            else
                echo "✓ ${CRB_NAME} repository: enabled"
            fi

            # Check for risky/conflicting repos
            RISKY_REPOS=""
            for repo in epel-testing epel-modular epel-next epel-next-testing; do
                if dnf repolist enabled 2>/dev/null | grep -q "$repo"; then
                    RISKY_REPOS="${RISKY_REPOS}${repo} "
                fi
            done

            if [ -n "$RISKY_REPOS" ]; then
                echo "⚠️  WARNING: Conflicting repos enabled: ${RISKY_REPOS}"
                echo "   These repos can cause package conflicts with EPEL"
                PROBLEMS_FOUND=true
                FIX_COMMANDS="${FIX_COMMANDS}sudo dnf config-manager --set-disabled ${RISKY_REPOS}\n"
            fi

            # Check for conflicting golang installations
            if [ -d /usr/local/go ]; then
                echo "⚠️  WARNING: Manual Go installation detected at /usr/local/go"
                echo "   This conflicts with distro golang package (required for building)"
                echo "   Recommendation: Remove /usr/local/go and use distro golang"
                PROBLEMS_FOUND=true
                FIX_COMMANDS="${FIX_COMMANDS}sudo rm -rf /usr/local/go\n"
            fi

            echo ""

            # If problems found, show fix commands and exit
            if [ "$PROBLEMS_FOUND" = true ]; then
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "❌ System Not Ready for NFTBan Installation"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo "NFTBan requires:"
                echo "  • EPEL repository (for fail2ban)"
                echo "  • CRB/PowerTools repository (for fail2ban dependencies)"
                echo "  • No conflicting testing repos"
                echo "  • No conflicting golang installations"
                echo ""
                echo "These are YOUR repository requirements, not ours."
                echo "Repository management is your responsibility."
                echo ""
                echo "Run these commands to fix your system:"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "sudo dnf clean all"
                echo -e "${FIX_COMMANDS}"
                echo "sudo dnf distro-sync -y"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo "After running these commands, retry:"
                echo "  sudo dnf install -y nftban-x86_64.rpm"
                echo ""
                echo "For more help, see: https://github.com/itcmsgr/nftban/docs"
                echo ""
                exit 1
            fi

            echo "✓ All required repositories configured correctly"
            echo "✓ Proceeding with installation..."
            ;;

        fedora)
            # Fedora - fail2ban in standard repos, no check needed
            echo "✓ Fedora detected - all repos available by default"
            ;;

        *)
            echo "⚠️  WARNING: Unsupported OS (${OS_ID})"
            echo "   Installation may fail if fail2ban is not available in repos"
            echo "   Continuing anyway..."
            ;;
    esac

    echo ""
fi

# Create nftban user and nftban-cli group (via sysusers.d)
%sysusers_create_compat packaging/sysusers.d/nftban.conf

%post
# =============================================================================
# UPGRADE vs FRESH INSTALL Detection
# =============================================================================
# $1 = 1 means FRESH INSTALL
# $1 = 2 means UPGRADE

# Update NFTBAN_VERSION in config file (handles upgrades with noreplace)
# This ensures the banner shows the correct version even on upgrades
if [ -f /etc/nftban/nftban.conf ]; then
    sed -i 's/^NFTBAN_VERSION=.*/NFTBAN_VERSION="0.32.20"/' /etc/nftban/nftban.conf
fi

# Generate system.conf with UID/GID
NFTBAN_UID=$(id -u nftban)
NFTBAN_GID=$(id -g nftban)
NFTBAN_CLI_GID=$(getent group nftban-cli | cut -d: -f3)
NFTBAN_AUDITORS_GID=$(getent group nftban-auditors | cut -d: -f3)

mkdir -p /var/lib/nftban/config
cat > /var/lib/nftban/config/system.conf <<EOF
# =============================================================================
# NFTBan System Configuration (AUTO-GENERATED - DO NOT EDIT)
# =============================================================================
# Generated: $(date -u +"%Y-%m-%d %H:%M:%%S UTC")
# Hostname: $(hostname)
#
# ⚠️  WARNING: DO NOT EDIT THIS FILE MANUALLY
# This file MUST stay aligned with actual system UID/GID values.
# =============================================================================

NFTBAN_USER="nftban"
NFTBAN_UID=${NFTBAN_UID}
NFTBAN_GROUP="nftban"
NFTBAN_GID=${NFTBAN_GID}
NFTBAN_CLI_GROUP="nftban-cli"
NFTBAN_CLI_GID=${NFTBAN_CLI_GID}
NFTBAN_AUDITORS_GROUP="nftban-auditors"
NFTBAN_AUDITORS_GID=${NFTBAN_AUDITORS_GID}
EOF

chmod 0644 /var/lib/nftban/config/system.conf

# Create log directory (NOT owned by package - preserved on uninstall)
mkdir -p /var/log/nftban
chown nftban:nftban /var/log/nftban
chmod 0750 /var/log/nftban

# Create nftban-auditors group for inventory helpers (if doesn't exist)
groupadd -f nftban-auditors 2>/dev/null || true

# Remove old bash completion file (was in /etc, now in /usr/share)
rm -f /etc/bash_completion.d/nftban 2>/dev/null || true

# Run autoheal to ensure everything is configured correctly
/usr/lib/nftban/helpers/autoheal.sh

# Dedicated directory for nftban-auditors group (explicit ownership)
if [ -d /var/lib/nftban/reports/auditors ]; then
    chown root:nftban-auditors /var/lib/nftban/reports/auditors
    chmod 0770 /var/lib/nftban/reports/auditors
fi

# =============================================================================
# UPGRADE FLOW - Check component versions and restart services
# =============================================================================
if [ $1 -eq 2 ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📦 NFTBan Upgrade - Checking Components"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check if services were running before upgrade (captured in /tmp by %preun)
    NFTBAN_WAS_RUNNING=false
    FAIL2BAN_WAS_RUNNING=false

    if [ -f /tmp/nftban-upgrade-state.txt ]; then
        . /tmp/nftban-upgrade-state.txt
        rm -f /tmp/nftban-upgrade-state.txt
    fi

    # Check component version changes
    COMPONENT_UPDATES=""

    # Check fail2ban version
    if command -v fail2ban-server >/dev/null 2>&1; then
        FAIL2BAN_VER=$(fail2ban-server --version 2>/dev/null | head -1 || echo "unknown")
        if [ -f /var/lib/nftban/config/fail2ban.version ]; then
            OLD_FAIL2BAN_VER=$(cat /var/lib/nftban/config/fail2ban.version 2>/dev/null || echo "unknown")
            if [ "$FAIL2BAN_VER" != "$OLD_FAIL2BAN_VER" ]; then
                COMPONENT_UPDATES="${COMPONENT_UPDATES}  • fail2ban: ${OLD_FAIL2BAN_VER} → ${FAIL2BAN_VER}\n"
            fi
        fi
        echo "$FAIL2BAN_VER" > /var/lib/nftban/config/fail2ban.version
    fi

    # Check nftables version
    if command -v nft >/dev/null 2>&1; then
        NFT_VER=$(nft --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        if [ -f /var/lib/nftban/config/nftables.version ]; then
            OLD_NFT_VER=$(cat /var/lib/nftban/config/nftables.version 2>/dev/null || echo "unknown")
            if [ "$NFT_VER" != "$OLD_NFT_VER" ]; then
                COMPONENT_UPDATES="${COMPONENT_UPDATES}  • nftables: ${OLD_NFT_VER} → ${NFT_VER}\n"
            fi
        fi
        echo "$NFT_VER" > /var/lib/nftban/config/nftables.version
    fi

    # Display component updates if any
    if [ -n "$COMPONENT_UPDATES" ]; then
        echo "Component updates detected:"
        echo -e "$COMPONENT_UPDATES"
    else
        echo "✓ Components unchanged (nftables, fail2ban)"
    fi
    echo ""

    # Check if firewall exists (means user had NFTBan configured)
    FIREWALL_EXISTS=false
    if /usr/sbin/nft list table inet nftban_main &>/dev/null; then
        FIREWALL_EXISTS=true
    fi

    # Reload firewall rules if firewall exists
    if [ "$FIREWALL_EXISTS" = "true" ]; then
        echo "Applying updated firewall rules..."
        if /usr/sbin/nftban firewall reload 2>&1 | grep -E '(✓|✅|━)'; then
            # Verify both tables exist after reload
            if /usr/sbin/nft list table inet nftban_main &>/dev/null && \
               /usr/sbin/nft list table inet nftban_runtime &>/dev/null; then
                echo "  ✓ Both tables verified (nftban_main + nftban_runtime)"
            else
                echo "  ⚠️  WARNING: One or more tables missing after reload"
            fi
        else
            echo "  ✗ Firewall reload failed - manual check needed"
        fi
        echo ""
    fi

    # Ensure maintenance timer always running (safety checks)
    echo "Ensuring maintenance timer active..."
    if ! systemctl is-active --quiet nftban-maintenance.timer 2>/dev/null; then
        systemctl enable nftban-maintenance.timer 2>/dev/null || true
        systemctl start nftban-maintenance.timer 2>/dev/null || true
    fi
    echo "  ✓ nftban-maintenance.timer active"
    echo ""

    # Restart services if they were running before upgrade
    SERVICES_RESTARTED=false
    NFTBAN_RUNNING_NOW=false
    FAIL2BAN_RUNNING_NOW=false
    SERVICE_FAILURES=""

    if [ "$NFTBAN_WAS_RUNNING" = "true" ]; then
        echo "Restarting nftban.timer..."
        if systemctl start nftban.timer 2>/dev/null && systemctl is-active --quiet nftban.timer 2>/dev/null; then
            echo "  ✓ nftban.timer restarted"
            SERVICES_RESTARTED=true
            NFTBAN_RUNNING_NOW=true
        else
            echo "  ✗ Failed to restart nftban.timer"
            SERVICE_FAILURES="${SERVICE_FAILURES}nftban.timer "
        fi
    fi

    if [ "$FAIL2BAN_WAS_RUNNING" = "true" ]; then
        echo "Restarting fail2ban.service..."
        if systemctl start fail2ban.service 2>/dev/null && systemctl is-active --quiet fail2ban.service 2>/dev/null; then
            echo "  ✓ fail2ban.service restarted"
            SERVICES_RESTARTED=true
            FAIL2BAN_RUNNING_NOW=true
        else
            echo "  ✗ Failed to restart fail2ban.service"
            SERVICE_FAILURES="${SERVICE_FAILURES}fail2ban.service "
        fi
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ NFTBan v0.32.7 - Upgrade Complete"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "📊 UPGRADE SUMMARY"
    echo ""

    # Show component updates
    if [ -n "$COMPONENT_UPDATES" ]; then
        echo "Component Updates:"
        echo -e "$COMPONENT_UPDATES"
    else
        echo "Components: No version changes"
    fi

    # Show what was done
    echo ""
    echo "Actions Performed:"
    if [ "$FIREWALL_EXISTS" = "true" ]; then
        echo "  ✓ Firewall rules reloaded (zero downtime)"
    fi
    if [ "$NFTBAN_RUNNING_NOW" = "true" ]; then
        echo "  ✓ nftban.timer - Running (automatic updates)"
    fi
    if [ "$FAIL2BAN_RUNNING_NOW" = "true" ]; then
        echo "  ✓ fail2ban.service - Running (intrusion prevention)"
    fi

    # Current protection status
    echo ""
    echo "Current Status:"
    if [ "$FIREWALL_EXISTS" = "true" ]; then
        if [ "$NFTBAN_RUNNING_NOW" = "true" ] && [ "$FAIL2BAN_RUNNING_NOW" = "true" ]; then
            echo "  🛡️  PROTECTED - All systems operational"
        elif [ "$NFTBAN_RUNNING_NOW" = "true" ] || [ "$FAIL2BAN_RUNNING_NOW" = "true" ]; then
            echo "  🟡 PARTIAL PROTECTION - Some services not running"
        else
            echo "  ⚠️  Firewall active, but services disabled"
        fi
    else
        echo "  ⚠️  Not initialized - Run 'nftban enable' to start protection"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Show next steps if needed
    if [ "$FIREWALL_EXISTS" = "true" ] && [ "$SERVICES_RESTARTED" = "false" ]; then
        echo "⚠️  Services not running - To enable protection:"
        echo "  → sudo nftban enable"
        echo ""
    fi

    echo "Check detailed status:"
    echo "  → nftban status"
    echo ""

    # Show troubleshooting if services failed to restart
    if [ -n "$SERVICE_FAILURES" ]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "⚠️  TROUBLESHOOTING - Service Restart Failed"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Failed services: $SERVICE_FAILURES"
        echo ""
        echo "Quick Diagnostics:"
        echo ""
        echo "1. Check service status:"
        for svc in $SERVICE_FAILURES; do
            echo "   → systemctl status $svc"
        done
        echo ""
        echo "2. Check configuration:"
        echo "   → nftban health check"
        echo "   → fail2ban-client -t  # Test fail2ban config"
        echo ""
        echo "3. Check firewall rules:"
        echo "   → nft list table inet nftban_main"
        echo "   → nft list table inet nftban_runtime"
        echo ""
        echo "4. View recent logs:"
        echo "   → journalctl -u nftban.timer -n 50"
        echo "   → journalctl -u fail2ban.service -n 50"
        echo ""
        echo "5. Try manual start:"
        for svc in $SERVICE_FAILURES; do
            echo "   → systemctl start $svc"
        done
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
    fi
fi

# Auto-detect and whitelist SSH port (LOCKOUT PREVENTION)
SSH_PORT=22
if [ -f "/etc/ssh/sshd_config" ]; then
    DETECTED_PORT=$(grep -E '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    if [ -n "$DETECTED_PORT" ] && [ "$DETECTED_PORT" -eq "$DETECTED_PORT" ] 2>/dev/null; then
        SSH_PORT=$DETECTED_PORT
    fi
fi

mkdir -p /etc/nftban/ports.d
cat > /etc/nftban/ports.d/00-ssh.conf <<SSHEOF
# SSH port auto-added during installation ($(date '+%%Y-%%m-%%d %%H:%%M:%%S'))
# DO NOT DELETE - LOCKOUT RISK!
# Port format: PORT|PROTO where PROTO = T(tcp), U(udp), B(both)
$SSH_PORT|T
SSHEOF
chmod 644 /etc/nftban/ports.d/00-ssh.conf

# Auto-detect and whitelist system IPs (LOCKOUT PREVENTION)
mkdir -p /etc/nftban/whitelist.d
{
    echo "# System IPs auto-added during installation ($(date '+%%Y-%%m-%%d %%H:%%M:%%S'))"
    echo "# DO NOT DELETE - LOCKOUT RISK!"
    echo "# Format: One IP per line (IPv4 or IPv6)"

    # Detect SSH client IP
    if [ -n "${SSH_CLIENT:-}" ]; then
        SSH_IP="${SSH_CLIENT%% *}"
        echo "$SSH_IP"
    fi

    # Detect public IPv4
    if command -v curl >/dev/null 2>&1; then
        IPV4=$(curl -s -4 --max-time 5 ifconfig.me 2>/dev/null || echo "")
        [ -n "$IPV4" ] && echo "$IPV4"
    fi

    # Detect public IPv6
    if command -v curl >/dev/null 2>&1; then
        IPV6=$(curl -s -6 --max-time 5 ifconfig.me 2>/dev/null || echo "")
        [ -n "$IPV6" ] && echo "$IPV6"
    fi
} > /etc/nftban/whitelist.d/00-system.conf
chmod 644 /etc/nftban/whitelist.d/00-system.conf

# Run health check to validate installation
if command -v nftban >/dev/null 2>&1; then
    nftban health check --quiet 2>/dev/null || true
fi

# Reload systemd and enable maintenance timer (ALWAYS enabled)
%systemd_post nftban.timer nftban-maintenance.timer

# Enable and start maintenance timer (runs even if NFTBan disabled)
systemctl enable nftban-maintenance.timer 2>/dev/null || true
systemctl start nftban-maintenance.timer 2>/dev/null || true

# Print installation message ONLY on fresh install (not upgrade)
# $1 = 1 means fresh install, $1 = 2 means upgrade
if [ $1 -eq 1 ]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                                                            ║"
    echo "║  ✅ NFTBan Installed Successfully!                         ║"
    echo "║                                                            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    # Check for previous backup
    LATEST_BACKUP=$(ls -t /var/lib/nftban/config-backup-* 2>/dev/null | head -1)

    if [ -n "$LATEST_BACKUP" ] && [ -d "$LATEST_BACKUP" ]; then
        BACKUP_DATE=$(grep "Backup Date:" "$LATEST_BACKUP/metadata.txt" 2>/dev/null | cut -d: -f2- || echo "unknown")

        echo ""
        echo "╔════════════════════════════════════════════════════════════╗"
        echo "║  Previous NFTBan Configuration Found                       ║"
        echo "╚════════════════════════════════════════════════════════════╝"
        echo ""
        echo "Backup from:$BACKUP_DATE"
        echo "Location: $LATEST_BACKUP"
        echo ""
        echo "Do you want to restore your previous settings?"
        echo "  1) RESTORE  - Use previous configuration"
        echo "  2) FRESH    - Start with defaults (keep backup)"
        echo "  3) DELETE   - Remove backup, use defaults"
        echo ""

        # In non-interactive mode, default to RESTORE
        if [ -t 0 ]; then
            read -p "Choice (1/2/3) [1]: " RESTORE_CHOICE
            RESTORE_CHOICE=${RESTORE_CHOICE:-1}
        else
            RESTORE_CHOICE="1"
            echo "Non-interactive mode: Restoring previous configuration"
        fi

        case "$RESTORE_CHOICE" in
            1)
                echo "Restoring configuration..."
                if [ -d "$LATEST_BACKUP/nftban/conf.d" ]; then
                    cp -a "$LATEST_BACKUP/nftban/conf.d"/* /etc/nftban/conf.d/ 2>/dev/null || true
                fi
                if [ -d "$LATEST_BACKUP/fail2ban" ]; then
                    cp -a "$LATEST_BACKUP/fail2ban"/* /etc/fail2ban/jail.d/ 2>/dev/null || true
                fi

                # Restore enabled state
                if [ -f "$LATEST_BACKUP/nftban.timer.state" ]; then
                    if grep -q "enabled" "$LATEST_BACKUP/nftban.timer.state"; then
                        systemctl enable nftban.timer 2>/dev/null || true
                    fi
                fi

                echo "✓ Configuration restored"
                echo ""
                ;;
            2)
                echo "⊘ Using fresh defaults (backup kept at $LATEST_BACKUP)"
                echo ""
                ;;
            3)
                rm -rf "$LATEST_BACKUP"
                echo "✓ Backup deleted, using fresh defaults"
                echo ""
                ;;
        esac
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  ⚠️  Your server is NOT protected yet!"
    echo ""
    echo "  To start protecting your server from hackers, run:"
    echo ""
    echo "     sudo nftban enable"
    echo ""
    echo "  This will automatically:"
    echo "    • Initialize the firewall"
    echo "    • Enable fail2ban SSH protection"
    echo "    • Start blocking bad guys"
    echo ""
    echo "  Takes 30 seconds. No questions asked. Just works."
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "What you'll get:"
    echo ""
    echo "  🛡️  Protection from SSH brute force attacks"
    echo "  🛡️  Protection from port scanning"
    echo "  🛡️  Automatic blocking of bad IPs"
    echo "  🛡️  Your SSH port $SSH_PORT already whitelisted (safe from lockout)"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "To disable later: sudo nftban disable"
    echo "Need help? Type: nftban help"
    echo ""
fi

%preun
# =============================================================================
# NFTBan - RPM Pre-Uninstall Script
# =============================================================================
# $1 = 0 means UNINSTALL
# $1 = 1 means UPGRADE

# =============================================================================
# UPGRADE FLOW - Capture service states and stop (not disable) services
# =============================================================================
if [ $1 -eq 1 ]; then
    # This is an UPGRADE - capture service states and stop temporarily
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📦 NFTBan Upgrade - Preparing System"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Capture component versions BEFORE upgrade
    mkdir -p /var/lib/nftban/config

    if command -v fail2ban-server >/dev/null 2>&1; then
        fail2ban-server --version 2>/dev/null | head -1 > /var/lib/nftban/config/fail2ban.version || echo "unknown" > /var/lib/nftban/config/fail2ban.version
    fi

    if command -v nft >/dev/null 2>&1; then
        nft --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 > /var/lib/nftban/config/nftables.version || echo "unknown" > /var/lib/nftban/config/nftables.version
    fi

    # Capture service states
    NFTBAN_WAS_RUNNING=false
    FAIL2BAN_WAS_RUNNING=false

    if systemctl is-active --quiet nftban.timer 2>/dev/null; then
        NFTBAN_WAS_RUNNING=true
        echo "Stopping nftban.timer temporarily..."
        systemctl stop nftban.timer 2>/dev/null || true
    fi

    if systemctl is-active --quiet fail2ban.service 2>/dev/null; then
        FAIL2BAN_WAS_RUNNING=true
        echo "Stopping fail2ban.service temporarily..."
        systemctl stop fail2ban.service 2>/dev/null || true
    fi

    # Save state to temp file for %post to restore
    cat > /tmp/nftban-upgrade-state.txt <<UPGRADEEOF
NFTBAN_WAS_RUNNING=$NFTBAN_WAS_RUNNING
FAIL2BAN_WAS_RUNNING=$FAIL2BAN_WAS_RUNNING
UPGRADEEOF

    echo "✓ Services stopped temporarily (will restart after upgrade)"
    echo ""

# =============================================================================
# UNINSTALL FLOW - Ask user to disable services
# =============================================================================
elif [ $1 -eq 0 ]; then
    # This is an UNINSTALL
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  NFTBan Uninstallation                                     ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    # Ask user if they want to backup configuration
    echo "Do you want to backup your configuration for future reinstalls?"
    echo "  • yes - Backup to /var/lib/nftban/config-backup/"
    echo "  • no  - Delete everything"
    echo ""

    # In non-interactive mode, default to yes (backup)
    if [ -t 0 ]; then
        read -p "Backup configuration? (yes/no) [yes]: " BACKUP_CONFIG
        BACKUP_CONFIG=${BACKUP_CONFIG:-yes}
    else
        BACKUP_CONFIG="yes"
        echo "Non-interactive mode: Backing up configuration automatically"
    fi

    if [ "$BACKUP_CONFIG" = "yes" ]; then
        BACKUP_DIR="/var/lib/nftban/config-backup-$(date +%%Y%%m%%d-%%H%%M%%S)"
        mkdir -p "$BACKUP_DIR"/{nftban,fail2ban}

        # Backup nftban configs
        if [ -d /etc/nftban/conf.d ]; then
            cp -a /etc/nftban/conf.d "$BACKUP_DIR/nftban/" 2>/dev/null || true
        fi

        # Backup fail2ban jails
        if [ -d /etc/fail2ban/jail.d ]; then
            cp /etc/fail2ban/jail.d/nftban-*.conf "$BACKUP_DIR/fail2ban/" 2>/dev/null || true
        fi

        # Save enabled/disabled states
        if systemctl is-enabled nftban.timer >/dev/null 2>&1; then
            echo "enabled" > "$BACKUP_DIR/nftban.timer.state"
        else
            echo "disabled" > "$BACKUP_DIR/nftban.timer.state"
        fi

        # Create metadata
        cat > "$BACKUP_DIR/metadata.txt" <<BACKUPEOF
Backup Date: $(date)
NFTBan Version: $(cat /var/lib/nftban/config/nftban.version 2>/dev/null || echo "unknown")
Hostname: $(hostname)
Reason: Uninstall
BACKUPEOF

        echo ""
        echo "✓ Configuration backed up to: $BACKUP_DIR"
        echo ""
    fi

    # Ask user if they want to disable NFTBan before removal
    echo "⚠️  NFTBan is being removed from your system."
    echo ""
    echo "Do you want to disable NFTBan services before removal?"
    echo "  • yes - Stop and disable nftban.timer and fail2ban.service"
    echo "  • no  - Keep services running (if you're upgrading)"
    echo ""

    # In non-interactive mode (like automated installs), default to yes
    if [ -t 0 ]; then
        read -p "Disable NFTBan services? (yes/no) [yes]: " DISABLE_SERVICES
        DISABLE_SERVICES=${DISABLE_SERVICES:-yes}
    else
        DISABLE_SERVICES="yes"
        echo "Non-interactive mode: Disabling services automatically"
    fi

    if [ "$DISABLE_SERVICES" = "yes" ]; then
        echo ""
        echo "Disabling NFTBan services..."

        # Stop and disable nftban.timer
        if systemctl is-active --quiet nftban.timer 2>/dev/null; then
            systemctl stop nftban.timer || true
            echo "  ✓ Stopped: nftban.timer"
        fi

        if systemctl is-enabled --quiet nftban.timer 2>/dev/null; then
            systemctl disable nftban.timer || true
            echo "  ✓ Disabled: nftban.timer"
        fi

        # Stop and disable nftban-health.timer (legacy)
        if systemctl is-active --quiet nftban-health.timer 2>/dev/null; then
            systemctl stop nftban-health.timer || true
            echo "  ✓ Stopped: nftban-health.timer (legacy)"
        fi

        # Stop and disable nftban-maintenance.timer
        if systemctl is-active --quiet nftban-maintenance.timer 2>/dev/null; then
            systemctl stop nftban-maintenance.timer || true
            echo "  ✓ Stopped: nftban-maintenance.timer"
        fi

        if systemctl is-enabled --quiet nftban-maintenance.timer 2>/dev/null; then
            systemctl disable nftban-maintenance.timer || true
            echo "  ✓ Disabled: nftban-maintenance.timer"
        fi

        # Stop and disable fail2ban if it was enabled by NFTBan
        if systemctl is-active --quiet fail2ban.service 2>/dev/null; then
            echo ""
            echo "⚠️  fail2ban.service is running."
            echo ""
            if [ -t 0 ]; then
                read -p "Stop fail2ban.service? (yes/no) [no]: " STOP_FAIL2BAN
                STOP_FAIL2BAN=${STOP_FAIL2BAN:-no}
            else
                STOP_FAIL2BAN="no"
                echo "Non-interactive mode: Leaving fail2ban.service running"
            fi

            if [ "$STOP_FAIL2BAN" = "yes" ]; then
                systemctl stop fail2ban.service || true
                systemctl disable fail2ban.service || true
                echo "  ✓ Stopped and disabled: fail2ban.service"
            else
                echo "  ⊘ Leaving fail2ban.service running"
            fi
        fi

        echo ""
        echo "✅ NFTBan services disabled"
    else
        echo ""
        echo "⊘ Keeping services enabled (upgrade mode)"

        # Still stop the timers to prevent them running during package removal
        systemctl stop nftban.timer || true
        systemctl stop nftban-health.timer || true
        systemctl stop nftban-maintenance.timer || true
    fi

    # Ask about firewall cleanup
    echo ""
    echo "⚠️  Firewall rules and runtime bans still active."
    echo ""
    if [ -t 0 ]; then
        read -p "Remove firewall rules and runtime bans? (yes/no) [no]: " REMOVE_FIREWALL
        REMOVE_FIREWALL=${REMOVE_FIREWALL:-no}
    else
        REMOVE_FIREWALL="no"
        echo "Non-interactive mode: Leaving firewall active"
    fi

    if [ "$REMOVE_FIREWALL" = "yes" ]; then
        echo ""
        echo "Removing firewall tables..."
        if nft list table inet nftban_main >/dev/null 2>&1; then
            nft delete table inet nftban_main 2>/dev/null && echo "  ✓ Removed: nftban_main (permanent rules)"
        fi
        if nft list table inet nftban_runtime >/dev/null 2>&1; then
            nft delete table inet nftban_runtime 2>/dev/null && echo "  ✓ Removed: nftban_runtime (temporary bans)"
        fi
        echo "  ✓ All firewall rules removed"
    else
        echo ""
        echo "  ⊘ Leaving firewall rules active"
        echo ""
        echo "  To remove later:"
        echo "    → nft delete table inet nftban_main"
        echo "    → nft delete table inet nftban_runtime"
    fi

    echo ""
    echo "⚠️  NOTE: Configuration files preserved in /etc/nftban/"
    echo "   Logs preserved in /var/log/nftban/"
    echo ""
fi

%postun
%systemd_postun_with_restart nftban.timer

# Only perform cleanup if package is being completely removed (not upgraded)
# $1 = 0 means uninstall, $1 = 1 means upgrade
if [ $1 -eq 0 ]; then
    # Note: Firewall tables already handled in %preun if user chose to remove them
    # We don't force-remove here to respect user choice

    # Remove runtime directories
    rm -rf /run/nftban

    # Remove cache (not needed after uninstall)
    rm -rf /var/cache/nftban

    # PRESERVE logs and config (standard RPM practice)
    # - Logs: /var/log/nftban/ - kept for audit/forensics
    # - Config: /etc/nftban/ - kept as .rpmsave files automatically
    # - State: /var/lib/nftban/ - kept for potential reinstall

    # Change ownership to root to avoid unknown UID/GID after user removal
    if [ -d /var/log/nftban ]; then
        chown -R root:root /var/log/nftban
    fi
    if [ -d /var/lib/nftban ]; then
        chown -R root:root /var/lib/nftban
    fi

    # Leave informational note in logs directory
    cat > /var/log/nftban/README.uninstalled <<'EOF'
NFTBan has been uninstalled, but logs have been preserved for audit purposes.

To completely remove all NFTBan data including logs:
  sudo rm -rf /var/log/nftban
  sudo rm -rf /var/lib/nftban
  sudo rm -rf /etc/nftban

Configuration files were saved as /etc/nftban/*.rpmsave
EOF
fi

%files
# Binaries
/usr/sbin/nftban
/usr/sbin/nftban-complete
/usr/sbin/nftban-apply
/usr/sbin/nftban-confirm
/usr/sbin/nftban-rollback
/usr/lib/nftban/bin/nftban-feeds
/usr/lib/nftban/bin/nftban-geoip
/usr/lib/nftban/bin/.real/nftban-feeds-%{_arch}
/usr/lib/nftban/bin/.real/nftban-geoip-%{_arch}

# Libraries and modules
/usr/lib/nftban/core/*.sh
/usr/lib/nftban/cli/*.sh
/usr/lib/nftban/cron/*.sh
/usr/lib/nftban/helpers/*.sh
/usr/lib/nftban/nft-runtime.nft
/usr/lib/nftban/nftban_help.sh

# Shared data and documentation
/usr/share/nftban/

# License files (FHS: /usr/share/licenses/<package>/)
%license /usr/share/licenses/nftban/MPL-2.0.txt
%license /usr/share/licenses/nftban/NFTBAN-Pro-Commercial.md
%license /usr/share/licenses/nftban/NFTBAN-Docs.txt

# Man page
%{_mandir}/man1/nftban.1*

# Configuration
%dir %attr(0750,root,nftban) /etc/nftban
%dir %attr(0750,root,nftban) /etc/nftban/conf.d
%config(noreplace) %attr(0640,root,nftban) /etc/nftban/nftban.conf
%attr(0640,root,nftban) /etc/nftban/baseline.nft
%config(noreplace) %attr(0640,root,nftban) /etc/nftban/conf.d/banner.conf
%config(noreplace) %attr(0640,root,nftban) /etc/nftban/conf.d/cloudflare.conf
%config(noreplace) %attr(0640,root,nftban) /etc/nftban/conf.d/ddos.conf
%config(noreplace) %attr(0640,root,nftban) /etc/nftban/conf.d/directadmin.conf
%config(noreplace) %attr(0640,root,nftban) /etc/nftban/conf.d/fail2ban.conf
%config(noreplace) %attr(0640,root,nftban) /etc/nftban/conf.d/feeds.conf
%config(noreplace) %attr(0640,root,nftban) /etc/nftban/conf.d/geoip.conf
%config(noreplace) %attr(0640,root,nftban) /etc/nftban/conf.d/health.conf
%config(noreplace) %attr(0640,root,nftban) /etc/nftban/conf.d/log.conf
%config(noreplace) %attr(0640,root,nftban) /etc/nftban/conf.d/login_alert.conf
%config(noreplace) %attr(0640,root,nftban) /etc/nftban/conf.d/mail.conf
%config(noreplace) %attr(0640,root,nftban) /etc/nftban/conf.d/nftban-go.conf
%config(noreplace) %attr(0640,root,nftban) /etc/nftban/conf.d/portscan.conf
%config(noreplace) %attr(0640,root,nftban) /etc/nftban/conf.d/recovery.conf
%config(noreplace) %attr(0640,root,nftban) /etc/nftban/conf.d/stats.conf
%dir %attr(0750,root,nftban) /etc/nftban/feeds.d
%attr(0640,root,nftban) /etc/nftban/feeds.d/.gitkeep
%dir %attr(0750,root,nftban) /etc/nftban/rules.d
%attr(0640,root,nftban) /etc/nftban/rules.d/.gitkeep
%dir %attr(0700,root,root) /etc/nftban/secrets.d
/etc/nftban/secrets.d/.gitkeep

# Fail2ban Integration
%config(noreplace) /etc/fail2ban/action.d/nftban.conf

# Fail2ban Filters (all with nftban- prefix)
%config(noreplace) /etc/fail2ban/filter.d/nftban-apache-scan.conf
%config(noreplace) /etc/fail2ban/filter.d/nftban-apache-wp-login.conf
%config(noreplace) /etc/fail2ban/filter.d/nftban-apache-xmlrpc.conf
%config(noreplace) /etc/fail2ban/filter.d/nftban-dovecot-custom.conf
%config(noreplace) /etc/fail2ban/filter.d/nftban-modsecurity.conf
%config(noreplace) /etc/fail2ban/filter.d/nftban-persistent-offenders.conf

# Fail2ban Jails (all with nftban- prefix)
%config(noreplace) /etc/fail2ban/jail.d/nftban-sshd.conf
%config(noreplace) /etc/fail2ban/jail.d/nftban-exim.conf
%config(noreplace) /etc/fail2ban/jail.d/nftban-exim-spam.conf
%config(noreplace) /etc/fail2ban/jail.d/nftban-directadmin.conf
%config(noreplace) /etc/fail2ban/jail.d/nftban-pure-ftpd.conf
%config(noreplace) /etc/fail2ban/jail.d/nftban-roundcube.conf
%config(noreplace) /etc/fail2ban/jail.d/nftban-dovecot.conf
%config(noreplace) /etc/fail2ban/jail.d/nftban-modsecurity.conf
%config(noreplace) /etc/fail2ban/jail.d/nftban-apache-xmlrpc.conf
%config(noreplace) /etc/fail2ban/jail.d/nftban-apache-wp-login.conf
%config(noreplace) /etc/fail2ban/jail.d/nftban-apache-scan.conf
%config(noreplace) /etc/fail2ban/jail.d/nftban-persistent-offenders.conf

# Systemd units
%{_unitdir}/*.service
%{_unitdir}/*.timer

# Sysusers and tmpfiles
%{_sysusersdir}/nftban.conf
%{_tmpfilesdir}/nftban.conf

# GeoBan directories
%dir %attr(0750,root,nftban) /etc/nftban/geoban.d
%dir %attr(0750,nftban,nftban) /var/lib/nftban/geoban
%dir %attr(0750,nftban,nftban) /var/lib/nftban/geoban/tracking
%dir %attr(0755,nftban,nftban) /var/cache/nftban/geoban
%dir %attr(0755,nftban,nftban) /var/cache/nftban/feeds

# Logrotate
/etc/logrotate.d/nftban

# Bash completion
/usr/share/bash-completion/completions/nftban

# Polkit rules
/usr/share/polkit-1/rules.d/60-nftban-cli.rules
/usr/share/polkit-1/rules.d/50-nftban-v030.rules

# Runtime directories (created by tmpfiles.d)
%dir %attr(0755,nftban,nftban) /var/lib/nftban
%dir %attr(0755,nftban,nftban) /var/cache/nftban
# Log directory NOT owned by package - preserved on uninstall
# Created in %post, managed by systemd-tmpfiles

# Inventory directories (inventory/health features integrated in main src/ tree)
%dir %attr(0755,nftban,nftban) /var/lib/nftban/reports/baseline
%dir %attr(0770,root,nftban-auditors) /var/lib/nftban/reports/auditors
%dir %attr(0700,root,root) /etc/nftban/keys

# Documentation
%doc README.md CHANGELOG.md

%changelog
* Fri Nov 08 2025 Antonios Voulvoulis <contact@nftban.com> - 0.32.14-1
- Fixed 18 SC2155 shellcheck issues (report_port, cmd_stats, health, geoip_download)

* Fri Nov 08 2025 Antonios Voulvoulis <contact@nftban.com> - 0.32.13-1
- Fixed 17 SC2155 shellcheck issues (cmd_report, cmd_profile, fail2ban)
- Fixed Go module build in release-binaries.yml workflow

* Fri Nov 08 2025 Antonios Voulvoulis <contact@nftban.com> - 0.32.12-1
- Fixed 32 SC2155 shellcheck issues across 3 files

* Fri Nov 08 2025 Antonios Voulvoulis <contact@nftban.com> - 0.32.11-1
- Fixed shellcheck issues in nftban_geoban.sh

* Fri Nov 08 2025 Antonios Voulvoulis <contact@nftban.com> - 0.32.10-1
- FIX: Added GeoIP as MANDATORY dependency (was incorrectly optional)
- REQUIREMENT: GeoIP package now required for RHEL/Rocky installations
- REQUIREMENT: geoip-bin and geoip-database now required for Debian/Ubuntu
- DOCS: Corrected package description - GeoIP is mandatory, not optional

* Fri Nov 08 2025 Antonios Voulvoulis <contact@nftban.com> - 0.32.9-1
- FIX: Corrected version display in nftban CLI (was showing outdated version)
- FIX: Added RHEL/Rocky Apache log patterns (*access_log without .log extension)
- FIX: Comprehensive logpath validation to prevent fail2ban crashes
- ENHANCEMENT: Multiline logpath parsing with glob pattern validation
- ENHANCEMENT: Fail2ban jail enable now validates log files exist before enabling

* Fri Nov 08 2025 Antonios Voulvoulis <contact@nftban.com> - 0.32.8-1
- NEW: Fail2ban auto-discovery command for automatic jail detection
- ENHANCEMENT: Auto-discovery scans system for compatible services
- ENHANCEMENT: Auto-discovery --enable flag to enable all discovered jails
- DOCS: Updated man page with auto-discovery command
- ENHANCEMENT: Bash completion for auto-discovery command

* Fri Nov 08 2025 Antonios Voulvoulis <contact@nftban.com> - 0.32.7-1
- FIX: DirectAdmin passive FTP port range syntax (35000-35999 not 35000:35999)
- FIX: Auto-enable DirectAdmin fail2ban jail on panel setup
- FIX: Show all fail2ban jails (enabled and disabled) in CLI display
- FIX: SIGPIPE issues with pipefail in fail2ban and panel functions
- FIX: Panel status display with pipefail-safe helper functions
- DOCS: Build dependency checks and installation guidance
- DOCS: Updated man pages for fail2ban jails command
- ENHANCEMENT: Bash completion for geoban command

* Wed Nov 06 2025 Antonios Voulvoulis <contact@nftban.com> - 0.32.3-1
- FIX: Auto-heal now correctly preserves auditors directory permissions
- FIX: fail2ban shown as REQUIRED (not optional) in enable command
- FIX: GitHub Actions Rocky/Alma build process (distro-sync for glibc alignment)

* Wed Nov 06 2025 Antonios Voulvoulis <contact@nftban.com> - 0.32.0-1
- CRITICAL FIX: Single source of truth for feeds (removed hardcoded Go URLs)
- BREAKING: Go binary no longer downloads feeds (loads from disk)
- NEW ARCHITECTURE: Bash downloads, Go loads (fast, atomic, maintainable)
- FIX: Feed name case mismatch (FIREHOL_ANONYMOUS vs firehol_anonymous)
- FIX: Missing nftban_feeds_list_enabled() function
- FIX: Go binary wrappers architecture detection (-x86_64 suffix)
- FIX: Port scan auto-ban integration (calls nftban ban command)
- FIX: Port scan status display (check portscan_detection chain)
- FIX: GitHub Actions glibc version mismatch in RPM builds
- DOCS: Updated README with BETA WARNING (not production-ready)
- ENHANCEMENT: Feeds now auto-discovered from config (no hardcoding)
- ENHANCEMENT: All version references aligned to v0.32.6

* Sun Nov 03 2025 Antonios Voulvoulis <contact@nftban.com> - 0.30.0-1
- Major release: NFTBan v0.30 with self-healing inventory monitoring
- Add advanced inventory system (processes, packages, firewall state)
- Add baseline management with drift detection and cryptographic signing
- Add smart mail adapter (auto-detects v0.10 module, sendmail, msmtp, curl)
- Add 4 inventory helpers (procnet, pkgs, verify, firewall)
- Add 3 health commands (nftban-health, baseline-save, verify-signature)
- Add Polkit rules for nftban-auditors group (non-root execution)
- Add comprehensive documentation (MODULAR_ARCHITECTURE, INTEGRATION_SUMMARY)
- Integrate v0.30 health checks into existing nftban_health.sh
- Smart adaptation: uses existing systems, graceful fallbacks
- Maintain full backward compatibility with v0.10
- All features from v0.10.0 included and enhanced

* Wed Oct 30 2025 Antonios Voulvoulis <contact@nftban.com> - 0.10.0-1
- Complete rewrite for v0.10.0
- Add commit-confirm recovery system
- Add Go binaries for 10-60x faster processing
- Add FHS-compliant structure with auto-healing
- Add stats & metrics system
- Add dynamic UID/GID tracking
- Add Polkit integration for group-based service management
- Add permission hardening system with audit logging
- Improve security with 8 protection layers
