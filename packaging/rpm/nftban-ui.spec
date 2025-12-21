Name:           nftban-ui
Version:        1.0.0
Release:        1%{?dist}
Summary:        NFTBan Web GUI - Secure web interface for NFTBan firewall management

License:        MPL-2.0
URL:            https://github.com/itcmsgr/nftban-dev
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  golang >= 1.21
BuildRequires:  pam-devel
BuildRequires:  systemd-rpm-macros
BuildRequires:  git

Requires:       systemd
Requires:       pam
Requires:       nftables
Requires(pre):  shadow-utils

%description
NFTBan Web GUI is a secure, modern web interface for managing the NFTBan
adaptive firewall system. It features socket-based PAM authentication, JWT
session management, and an 8-layer security architecture.

Features:
- Socket-based PAM authentication (no setuid binaries)
- 8-layer security architecture
- 15+ RESTful API endpoints
- Modern dark theme UI
- Systemd socket activation
- Resource limits and cgroup awareness

%prep
%autosetup -n %{name}-%{version}

%build
# Build main GUI server
cd cmd/nftban-ui
CGO_ENABLED=1 go build -buildmode=pie -mod=readonly -modcacherw \
    -ldflags="-linkmode=external -s -w -X main.version=%{version}" \
    -o ../../bin/nftban-ui .

cd ../..

# Build authentication service
CGO_ENABLED=1 go build -buildmode=pie -mod=readonly -modcacherw \
    -ldflags="-linkmode=external -s -w -X main.version=%{version}" \
    -o bin/nftban-ui-auth ./cmd/nftban-ui-auth

%install
# Create directory structure
install -d %{buildroot}%{_sbindir}
install -d %{buildroot}%{_libexecdir}
install -d %{buildroot}%{_unitdir}
install -d %{buildroot}%{_sysconfdir}/nftban
install -d %{buildroot}%{_sysconfdir}/pam.d
install -d %{buildroot}%{_localstatedir}/log/nftban
install -d %{buildroot}%{_datadir}/nftban-ui/web

# Install binaries
install -m 0755 bin/nftban-ui %{buildroot}%{_sbindir}/nftban-ui
install -m 0755 bin/nftban-ui-auth %{buildroot}%{_libexecdir}/nftban-ui-auth

# Install systemd units
install -m 0644 install/systemd/nftban-ui.service %{buildroot}%{_unitdir}/nftban-ui.service
install -m 0644 install/systemd/nftban-ui-auth.service %{buildroot}%{_unitdir}/nftban-ui-auth.service
install -m 0644 install/systemd/nftban-ui-auth.socket %{buildroot}%{_unitdir}/nftban-ui-auth.socket

# Install PAM configuration
install -m 0644 install/pam/nftban-ui %{buildroot}%{_sysconfdir}/pam.d/nftban-ui

# Install config files
install -m 0644 install/config/allowed-gui-groups %{buildroot}%{_sysconfdir}/nftban/allowed-gui-groups

# Install distro config parser module
install -d %{buildroot}%{_prefix}/lib/nftban/lib
install -m 0755 cli/lib/nftban/lib/nftban_distro_config.sh %{buildroot}%{_prefix}/lib/nftban/lib/nftban_distro_config.sh

# Install distro config files
install -d %{buildroot}%{_sysconfdir}/nftban/distros
install -d %{buildroot}%{_sysconfdir}/nftban/conf.d
install -m 0644 etc/nftban/distros/*.conf %{buildroot}%{_sysconfdir}/nftban/distros/

# Install web files
cp -r cmd/nftban-ui/web/* %{buildroot}%{_datadir}/nftban-ui/web/

%pre
# Create nftban system user and groups if they don't exist
# NFTBan v1.0 uses 2-group model:
#   nftban: All operators (CLI + Web GUI)
#   nftban-auditors: Read-only audit access
getent group nftban >/dev/null || groupadd -r nftban
getent group nftban-auditors >/dev/null || groupadd -r nftban-auditors
getent passwd nftban >/dev/null || \
    useradd -r -g nftban -d /var/lib/nftban -s /sbin/nologin \
    -c "NFTBan system user" nftban
exit 0

%post
# Check for legacy inet filter table (CVE-2025-NFTBAN-001)
if command -v nft >/dev/null 2>&1; then
    if nft list table inet filter >/dev/null 2>&1; then
        echo "ERROR: Conflicting 'inet filter' table detected!" >&2
        echo "ERROR: This table will bypass nftban blocking (CVE-2025-NFTBAN-001)." >&2
        echo "ERROR: Please run: nft delete table inet filter" >&2
        echo "ERROR: Then re-install the package." >&2
        exit 1
    fi
fi

# Enable and start socket (will auto-start service on-demand)
%systemd_post nftban-ui-auth.socket
%systemd_post nftban-ui.service

# Only enable socket if this is initial install
if [ $1 -eq 1 ]; then
    systemctl enable nftban-ui-auth.socket >/dev/null 2>&1 || :
    systemctl start nftban-ui-auth.socket >/dev/null 2>&1 || :
fi

# If upgrading and service is already running, restart it
if [ $1 -eq 2 ]; then
    # Restart auth socket (will reload service on next connection)
    systemctl try-restart nftban-ui-auth.socket >/dev/null 2>&1 || :
    # Restart GUI service if it's running
    systemctl try-restart nftban-ui.service >/dev/null 2>&1 || :
fi

%preun
%systemd_preun nftban-ui.service
%systemd_preun nftban-ui-auth.socket
%systemd_preun nftban-ui-auth.service

%postun
%systemd_postun_with_restart nftban-ui.service
%systemd_postun_with_restart nftban-ui-auth.socket

# Inform user about leftover files on complete removal
if [ $1 -eq 0 ]; then
    echo "nftban-ui: Configuration files in /etc/nftban/ (/ui.conf, ui-whitelist.conf, ssl/) have been preserved."
    echo "nftban-ui: Log files in /var/log/nftban/ui-*.log have been preserved."
    echo "nftban-ui: User accounts and groups have NOT been removed."
    echo "nftban-ui: To manually remove: userdel nftban; groupdel nftban nftban-auditors"
fi

%files
%license LICENSE
%doc README.md README_GUI.md

# Binaries
%{_sbindir}/nftban-ui
%{_libexecdir}/nftban-ui-auth

# Systemd units
%{_unitdir}/nftban-ui.service
%{_unitdir}/nftban-ui-auth.service
%{_unitdir}/nftban-ui-auth.socket

# Configuration
%config(noreplace) %{_sysconfdir}/pam.d/nftban-ui
%config(noreplace) %{_sysconfdir}/nftban/allowed-gui-groups

# Distro config parser module
%{_prefix}/lib/nftban/lib/nftban_distro_config.sh

# Distro config files
%dir %{_sysconfdir}/nftban/distros
%dir %{_sysconfdir}/nftban/conf.d
%config(noreplace) %{_sysconfdir}/nftban/distros/*.conf

# Web files
%{_datadir}/nftban-ui/

# Log directory
%dir %attr(0750,nftban,nftban) %{_localstatedir}/log/nftban

%changelog
* Wed Dec 11 2024 Antonios Voulvoulis <contact@nftban.com> - 1.0.0-1
- NFTBan v1.0.0 release
- Unified security platform
- 2-group security model (nftban, nftban-auditors)
- Enhanced PAM socket authentication
- Modern dashboard with real-time metrics
- FHS compliant directory structure

* Sat Nov 16 2024 Antonios Voulvoulis <itcmsgr@example.com> - 0.5.1-1
- CRITICAL SECURITY FIX: CVE-2025-NFTBAN-001 detection added
- Installer now refuses installation if inet filter table exists
- Added nftables security check to health system
- Added GUI port access control documentation
- Security hardening improvements

* Thu Nov 14 2024 Antonios Voulvoulis <itcmsgr@example.com> - 0.5.0-1
- Initial RPM packaging for v0.5.0
- Socket-based PAM authentication (no setuid binaries)
- Systemd socket activation
- 8-layer security architecture
- Modern web UI with JWT sessions
- Complete systemd hardening
