Name:           nftban-api
Version:        2.0.0
Release:        1%{?dist}
Summary:        NFTBan Web API - Modern web interface for NFTBan firewall

License:        MIT
URL:            https://github.com/nftban/nftban
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  golang >= 1.21
BuildRequires:  systemd-rpm-macros
Requires:       nftban >= 1.0.0
Requires:       systemd
Requires(post): systemd
Requires(preun): systemd
Requires(postun): systemd

%description
NFTBan Web API v2.0 - Modern REST API and web interface for NFTBan firewall.
Features:
- Memory-only session management
- PAM authentication with RBAC
- Mobile-responsive web interface
- Real-time metrics integration
- HTTPS on port 3940

%prep
%setup -q

%build
# Build nftban-api binary
cd cmd/nftban-api
go mod tidy
CGO_ENABLED=1 go build -o nftban-api -ldflags="-s -w" .

%install
# Binary
install -D -m 755 cmd/nftban-api/nftban-api %{buildroot}%{_sbindir}/nftban-api

# Web files
install -d %{buildroot}%{_datadir}/nftban/web
cp -r web/* %{buildroot}%{_datadir}/nftban/web/

# Systemd service
install -D -m 644 install/systemd/nftban-api.service %{buildroot}%{_unitdir}/nftban-api.service

# PAM config
install -D -m 644 install/pam.d/nftban-api %{buildroot}%{_sysconfdir}/pam.d/nftban-api

# TLS directory
install -d %{buildroot}%{_sysconfdir}/nftban/tls

# Create system user
%pre
getent group nftban-web >/dev/null || groupadd -r nftban-web
getent passwd nftban-www >/dev/null || \
    useradd -r -g nftban-web -d /var/lib/nftban-www -s /sbin/nologin \
    -c "NFTBan Web API" nftban-www
exit 0

%post
# Generate self-signed TLS certificate if not exists
if [[ ! -f %{_sysconfdir}/nftban/tls/cert.pem ]]; then
    openssl req -x509 -newkey rsa:4096 -nodes \
        -keyout %{_sysconfdir}/nftban/tls/key.pem \
        -out %{_sysconfdir}/nftban/tls/cert.pem \
        -days 365 -subj "/CN=$(hostname)" &>/dev/null
    chown nftban-www:nftban-web %{_sysconfdir}/nftban/tls/*.pem
    chmod 600 %{_sysconfdir}/nftban/tls/key.pem
    chmod 644 %{_sysconfdir}/nftban/tls/cert.pem
fi

# Systemd
%systemd_post nftban-api.service

%preun
%systemd_preun nftban-api.service

%postun
%systemd_postun_with_restart nftban-api.service

%files
%license LICENSE
%doc README.md
%{_sbindir}/nftban-api
%{_datadir}/nftban/web/
%{_unitdir}/nftban-api.service
%config(noreplace) %{_sysconfdir}/pam.d/nftban-api
%dir %{_sysconfdir}/nftban/tls
%attr(0750,nftban-www,nftban-web) %dir %{_sysconfdir}/nftban/tls

%changelog
* Fri Jan 02 2026 NFTBan Team <noreply@nftban.com> - 2.0.0-1
- Initial release of Web API v2.0
- Memory-only session management
- PAM authentication with RBAC
- Mobile-responsive web interface (4 pages)
- Gemini AI accessibility fixes applied
- WCAG 2.1 AA compliant
