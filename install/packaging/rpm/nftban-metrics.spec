# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2025 NFTBan Development Team

# Version is passed via rpmbuild --define "pkg_version X.Y.Z"
%{!?pkg_version: %define pkg_version 0.0.0}

Name:           nftban-metrics
Version:        %{pkg_version}
Release:        1%{?dist}
Summary:        NFTBAN Metrics - Prometheus/Grafana observability for nftables firewall

License:        MPL-2.0
URL:            https://github.com/nftban/nftban
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch
Requires:       systemd >= 232
Requires:       nftban >= 1.0.0
Recommends:     node_exporter
Recommends:     prometheus
Recommends:     grafana
Suggests:       mailx

%description
Prometheus metrics collection and Grafana dashboards for NFTBAN firewall
monitoring. Provides real-time observability into nftables-based firewall
operations, ban statistics, and threat detection events.

Features:
 - Prometheus metrics exporter for NFTBan statistics
 - Node Exporter integration via textfile collector
 - 4 pre-built Grafana dashboards (Overview, Health, Geographic, Performance)
 - Automated installation scripts for Node Exporter and Prometheus
 - 15+ alert rules for proactive monitoring
 - Security-hardened systemd services
 - Multi-distro support (RHEL, Fedora, Debian, Ubuntu)

The metrics exporter collects NFTBan firewall statistics and exports them
in Prometheus format via Node Exporter's textfile collector. Dashboards
provide visualization for block statistics, system health, geographic
distribution, and performance metrics.

%prep
%setup -q

%build
# No build required - shell scripts and configuration files

%install
rm -rf %{buildroot}

# Create directory structure
install -d %{buildroot}%{_prefix}/lib/nftban/exporters
install -d %{buildroot}%{_prefix}/lib/nftban/setup
install -d %{buildroot}%{_unitdir}/node_exporter.service.d
install -d %{buildroot}%{_datadir}/nftban/prometheus/alerts
install -d %{buildroot}%{_datadir}/nftban/grafana/dashboards
install -d %{buildroot}%{_docdir}/nftban/metrics

# Install Track 1: Core Metrics Exporter
install -m 0755 work/track1/nftban_prometheus_exporter.sh \
    %{buildroot}%{_prefix}/lib/nftban/exporters/nftban_prometheus_exporter.sh
install -m 0644 work/track1/nftban-unified-exporter.service \
    %{buildroot}%{_unitdir}/nftban-unified-exporter.service
install -m 0644 work/track1/nftban-unified-exporter.timer \
    %{buildroot}%{_unitdir}/nftban-unified-exporter.timer

# Install Track 2: Node Exporter Setup
install -m 0755 cli/lib/nftban/setup/install_node_exporter.sh \
    %{buildroot}%{_prefix}/lib/nftban/setup/install_node_exporter.sh
install -m 0755 cli/lib/nftban/setup/validate_node_exporter.sh \
    %{buildroot}%{_prefix}/lib/nftban/setup/validate_node_exporter.sh
install -m 0644 install/systemd/node_exporter.service.d/textfile-collector.conf \
    %{buildroot}%{_unitdir}/node_exporter.service.d/textfile-collector.conf
install -m 0644 install/systemd/node_exporter.service.d/hardening.conf \
    %{buildroot}%{_unitdir}/node_exporter.service.d/hardening.conf
install -m 0644 docs/metrics/NODE_EXPORTER_SETUP.md \
    %{buildroot}%{_docdir}/nftban/metrics/NODE_EXPORTER_SETUP.md

# Install Track 3: Grafana Dashboards
install -m 0644 install/grafana/dashboards/nftban_overview.json \
    %{buildroot}%{_datadir}/nftban/grafana/dashboards/nftban_overview.json
install -m 0644 install/grafana/dashboards/nftban_health.json \
    %{buildroot}%{_datadir}/nftban/grafana/dashboards/nftban_health.json
install -m 0644 install/grafana/dashboards/nftban_geographic.json \
    %{buildroot}%{_datadir}/nftban/grafana/dashboards/nftban_geographic.json
install -m 0644 install/grafana/dashboards/nftban_performance.json \
    %{buildroot}%{_datadir}/nftban/grafana/dashboards/nftban_performance.json

# Install Track 4: Prometheus Configuration
install -m 0755 cli/lib/nftban/setup/install_prometheus.sh \
    %{buildroot}%{_prefix}/lib/nftban/setup/install_prometheus.sh
install -m 0755 cli/lib/nftban/setup/validate_prometheus.sh \
    %{buildroot}%{_prefix}/lib/nftban/setup/validate_prometheus.sh
install -m 0644 install/prometheus/prometheus.yml.example \
    %{buildroot}%{_datadir}/nftban/prometheus/prometheus.yml.example
install -m 0644 install/prometheus/prometheus-remote.yml.example \
    %{buildroot}%{_datadir}/nftban/prometheus/prometheus-remote.yml.example
install -m 0644 install/prometheus/web.yml.example \
    %{buildroot}%{_datadir}/nftban/prometheus/web.yml.example
install -m 0644 install/prometheus/alerts/nftban-metrics.yml \
    %{buildroot}%{_datadir}/nftban/prometheus/alerts/nftban-metrics.yml
install -m 0644 docs/metrics/PROMETHEUS_SETUP.md \
    %{buildroot}%{_docdir}/nftban/metrics/PROMETHEUS_SETUP.md

# Install Track 10: Security
install -m 0755 install/firewall/metrics-firewall-rules.sh \
    %{buildroot}%{_prefix}/lib/nftban/setup/metrics-firewall-rules.sh
install -m 0644 docs/metrics/SECURITY.md \
    %{buildroot}%{_docdir}/nftban/metrics/SECURITY.md

%files
%license LICENSE
%doc README.md

# Track 1: Core Metrics Exporter
%{_prefix}/lib/nftban/exporters/nftban_prometheus_exporter.sh
%{_unitdir}/nftban-unified-exporter.service
%{_unitdir}/nftban-unified-exporter.timer

# Track 2: Node Exporter Setup
%{_prefix}/lib/nftban/setup/install_node_exporter.sh
%{_prefix}/lib/nftban/setup/validate_node_exporter.sh
%{_unitdir}/node_exporter.service.d/textfile-collector.conf
%{_unitdir}/node_exporter.service.d/hardening.conf
%{_docdir}/nftban/metrics/NODE_EXPORTER_SETUP.md

# Track 3: Grafana Dashboards
%{_datadir}/nftban/grafana/dashboards/nftban_overview.json
%{_datadir}/nftban/grafana/dashboards/nftban_health.json
%{_datadir}/nftban/grafana/dashboards/nftban_geographic.json
%{_datadir}/nftban/grafana/dashboards/nftban_performance.json

# Track 4: Prometheus Configuration
%{_prefix}/lib/nftban/setup/install_prometheus.sh
%{_prefix}/lib/nftban/setup/validate_prometheus.sh
%{_datadir}/nftban/prometheus/prometheus.yml.example
%{_datadir}/nftban/prometheus/prometheus-remote.yml.example
%{_datadir}/nftban/prometheus/web.yml.example
%{_datadir}/nftban/prometheus/alerts/nftban-metrics.yml
%{_docdir}/nftban/metrics/PROMETHEUS_SETUP.md

# Track 10: Security
%{_prefix}/lib/nftban/setup/metrics-firewall-rules.sh
%{_docdir}/nftban/metrics/SECURITY.md

%pre
# Create nftban user if it doesn't exist (usually handled by main nftban package)
if ! id -u nftban >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/nftban --shell /usr/sbin/nologin nftban
fi

%post
# Create textfile collector directory
if [ ! -d "/var/lib/node_exporter/textfile_collector" ]; then
    mkdir -p /var/lib/node_exporter/textfile_collector
    chown nftban:nftban /var/lib/node_exporter/textfile_collector
    chmod 750 /var/lib/node_exporter/textfile_collector
fi

# Reload systemd daemon
%systemd_post nftban-unified-exporter.service nftban-unified-exporter.timer

# Print installation message
cat <<'EOF'

═══════════════════════════════════════════════════════════
NFTBan Metrics installed successfully!
═══════════════════════════════════════════════════════════

Next steps:

1. Install Node Exporter (if not already installed):
   sudo /usr/lib/nftban/setup/install_node_exporter.sh

2. Install Prometheus (if not already installed):
   sudo /usr/lib/nftban/setup/install_prometheus.sh

3. Enable and start metrics collection:
   sudo systemctl enable --now nftban-unified-exporter.timer

4. Verify metrics are being collected:
   sudo systemctl status nftban-unified-exporter.timer
   cat /var/lib/node_exporter/textfile_collector/nftban.prom

5. Import Grafana dashboards (optional):
   Dashboards are in: /usr/share/nftban/grafana/dashboards/

Documentation:
  - Node Exporter: /usr/share/doc/nftban/metrics/NODE_EXPORTER_SETUP.md
  - Prometheus: /usr/share/doc/nftban/metrics/PROMETHEUS_SETUP.md
  - Security: /usr/share/doc/nftban/metrics/SECURITY.md

═══════════════════════════════════════════════════════════
EOF

%preun
%systemd_preun nftban-unified-exporter.timer nftban-unified-exporter.service

%postun
%systemd_postun_with_restart nftban-unified-exporter.timer nftban-unified-exporter.service

# Remove metrics file on package removal (but not upgrade)
if [ $1 -eq 0 ]; then
    rm -f /var/lib/node_exporter/textfile_collector/nftban.prom 2>/dev/null || true
    rm -f /var/lib/node_exporter/textfile_collector/nftban.prom.tmp 2>/dev/null || true
fi

%changelog
* Wed Dec 11 2024 NFTBan Development Team <noreply@nftban.org> - 1.0.0-1
- NFTBan v1.0.0 release - Unified Security Platform
- Updated to work with NFTBan 1.0.0 core
- All metrics aligned with v1.0 schema
- Enhanced Prometheus exporter with additional metrics
- Updated Grafana dashboards for v1.0.0

* Sun Nov 17 2024 NFTBan Development Team <noreply@nftban.org> - 0.6.0-1
- Initial release of NFTBan Prometheus/Grafana integration
- Add Prometheus metrics exporter for NFTBan statistics
- Add systemd timer for automated metrics collection (60s interval)
- Add Node Exporter installation and validation scripts
- Add Prometheus installation and validation scripts
- Add 4 Grafana dashboards (Overview, Health, Geographic, Performance)
- Add 15+ Prometheus alert rules for proactive monitoring
- Add security-hardened systemd service configurations
- Add comprehensive documentation and setup guides
- Support for standalone Prometheus and Grafana Cloud deployments
- Multi-distro support: RHEL 8/9, Fedora 38+, Debian 11/12, Ubuntu 20.04+
