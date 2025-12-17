# NFTBan v1.0 Metrics - Package File Manifest

**Version:** 1.0.0
**Date:** 2025-12-11
**Component:** Prometheus/Grafana Integration

This manifest lists all files to be included in DEB/RPM packages for NFTBan v1.0 metrics functionality.

---

## Track 1: Core Metrics Exporter

### Exporter Script
```
Source: work/track1/nftban_prometheus_exporter.sh
Dest:   /usr/lib/nftban/exporters/nftban_prometheus_exporter.sh
Mode:   0755
Owner:  root:root
```

### Systemd Service Files
```
Source: work/track1/nftban-metrics-exporter.service
Dest:   /usr/lib/systemd/system/nftban-metrics-exporter.service
Mode:   0644
Owner:  root:root

Source: work/track1/nftban-metrics-exporter.timer
Dest:   /usr/lib/systemd/system/nftban-metrics-exporter.timer
Mode:   0644
Owner:  root:root
```

---

## Track 2: Node Exporter Setup

### Installation Scripts
```
Source: cli/lib/nftban/setup/install_node_exporter.sh
Dest:   /usr/lib/nftban/setup/install_node_exporter.sh
Mode:   0755
Owner:  root:root

Source: cli/lib/nftban/setup/validate_node_exporter.sh
Dest:   /usr/lib/nftban/setup/validate_node_exporter.sh
Mode:   0755
Owner:  root:root
```

### Systemd Configuration
```
Source: install/systemd/node_exporter.service.d/textfile-collector.conf
Dest:   /usr/lib/systemd/system/node_exporter.service.d/textfile-collector.conf
Mode:   0644
Owner:  root:root

Source: install/systemd/node_exporter.service.d/hardening.conf
Dest:   /usr/lib/systemd/system/node_exporter.service.d/hardening.conf
Mode:   0644
Owner:  root:root
```

### Documentation
```
Source: docs/metrics/NODE_EXPORTER_SETUP.md
Dest:   /usr/share/doc/nftban/metrics/NODE_EXPORTER_SETUP.md
Mode:   0644
Owner:  root:root
```

---

## Track 3: Grafana Dashboards

### Dashboard JSON Files
```
Source: install/grafana/dashboards/nftban_overview.json
Dest:   /usr/share/nftban/grafana/dashboards/nftban_overview.json
Mode:   0644
Owner:  root:root

Source: install/grafana/dashboards/nftban_health.json
Dest:   /usr/share/nftban/grafana/dashboards/nftban_health.json
Mode:   0644
Owner:  root:root

Source: install/grafana/dashboards/nftban_geographic.json
Dest:   /usr/share/nftban/grafana/dashboards/nftban_geographic.json
Mode:   0644
Owner:  root:root

Source: install/grafana/dashboards/nftban_performance.json
Dest:   /usr/share/nftban/grafana/dashboards/nftban_performance.json
Mode:   0644
Owner:  root:root
```

---

## Track 4: Prometheus Configuration

### Installation Scripts
```
Source: cli/lib/nftban/setup/install_prometheus.sh
Dest:   /usr/lib/nftban/setup/install_prometheus.sh
Mode:   0755
Owner:  root:root

Source: cli/lib/nftban/setup/validate_prometheus.sh
Dest:   /usr/lib/nftban/setup/validate_prometheus.sh
Mode:   0755
Owner:  root:root
```

### Configuration Examples
```
Source: install/prometheus/prometheus.yml.example
Dest:   /usr/share/nftban/prometheus/prometheus.yml.example
Mode:   0644
Owner:  root:root

Source: install/prometheus/prometheus-remote.yml.example
Dest:   /usr/share/nftban/prometheus/prometheus-remote.yml.example
Mode:   0644
Owner:  root:root

Source: install/prometheus/web.yml.example
Dest:   /usr/share/nftban/prometheus/web.yml.example
Mode:   0644
Owner:  root:root
```

### Alert Rules
```
Source: install/prometheus/alerts/nftban-metrics.yml
Dest:   /usr/share/nftban/prometheus/alerts/nftban-metrics.yml
Mode:   0644
Owner:  root:root
```

### Documentation
```
Source: docs/metrics/PROMETHEUS_SETUP.md
Dest:   /usr/share/doc/nftban/metrics/PROMETHEUS_SETUP.md
Mode:   0644
Owner:  root:root
```

---

## Track 10: Security

### Firewall Rules Script
```
Source: install/firewall/metrics-firewall-rules.sh
Dest:   /usr/lib/nftban/setup/metrics-firewall-rules.sh
Mode:   0755
Owner:  root:root
```

### Documentation
```
Source: docs/metrics/SECURITY.md
Dest:   /usr/share/doc/nftban/metrics/SECURITY.md
Mode:   0644
Owner:  root:root
```

---

## Directory Structure Created by Package

### Runtime Directories
```
/var/lib/node_exporter/textfile_collector/
Mode:   0750
Owner:  nftban:nftban
Purpose: Metrics output directory for Node Exporter textfile collector
```

### Installation Directories
```
/usr/lib/nftban/exporters/
Mode:   0755
Owner:  root:root
Purpose: NFTBan Prometheus exporter scripts

/usr/lib/nftban/setup/
Mode:   0755
Owner:  root:root
Purpose: Installation and validation scripts

/usr/share/nftban/prometheus/
Mode:   0755
Owner:  root:root
Purpose: Prometheus configuration examples

/usr/share/nftban/prometheus/alerts/
Mode:   0755
Owner:  root:root
Purpose: Prometheus alert rules

/usr/share/nftban/grafana/dashboards/
Mode:   0755
Owner:  root:root
Purpose: Grafana dashboard JSON files

/usr/share/doc/nftban/metrics/
Mode:   0755
Owner:  root:root
Purpose: Metrics documentation
```

---

## File Count Summary

| Track | Files | Scripts | Configs | Docs | Total |
|-------|-------|---------|---------|------|-------|
| Track 1 | 3 | 1 | 2 | 0 | 3 |
| Track 2 | 5 | 2 | 2 | 1 | 5 |
| Track 3 | 4 | 0 | 4 | 0 | 4 |
| Track 4 | 8 | 2 | 4 | 1 | 7 |
| Track 10 | 2 | 1 | 0 | 1 | 2 |
| **Total** | **22** | **6** | **12** | **3** | **21** |

---

## Package Dependencies

### DEB Package (Debian/Ubuntu)
```
Depends: systemd (>= 232)
Recommends: prometheus-node-exporter, prometheus, grafana
Suggests: mailx
```

### RPM Package (RHEL/Fedora)
```
Requires: systemd >= 232
Recommends: node_exporter, prometheus, grafana
Suggests: mailx
```

---

## Post-Installation Actions

### DEB postinst Script
```bash
#!/bin/bash
set -e

# Create textfile collector directory
if [ ! -d "/var/lib/node_exporter/textfile_collector" ]; then
    mkdir -p /var/lib/node_exporter/textfile_collector
    chown nftban:nftban /var/lib/node_exporter/textfile_collector
    chmod 750 /var/lib/node_exporter/textfile_collector
fi

# Create nftban user if needed (handled by main nftban package)
if ! id -u nftban >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/nftban --shell /usr/sbin/nologin nftban
fi

# Reload systemd
systemctl daemon-reload

# Print information
echo "NFTBan v0.6 Metrics installed successfully!"
echo ""
echo "Next steps:"
echo "1. Install Node Exporter: /usr/lib/nftban/setup/install_node_exporter.sh"
echo "2. Install Prometheus: /usr/lib/nftban/setup/install_prometheus.sh"
echo "3. Enable metrics collection: systemctl enable --now nftban-metrics-exporter.timer"
echo ""
echo "Documentation: /usr/share/doc/nftban/metrics/"
```

### RPM %post Script
```bash
# Create textfile collector directory
if [ ! -d "/var/lib/node_exporter/textfile_collector" ]; then
    mkdir -p /var/lib/node_exporter/textfile_collector
    chown nftban:nftban /var/lib/node_exporter/textfile_collector
    chmod 750 /var/lib/node_exporter/textfile_collector
fi

# Reload systemd
systemctl daemon-reload

# Print information
echo "NFTBan v0.6 Metrics installed successfully!"
echo ""
echo "Next steps:"
echo "1. Install Node Exporter: /usr/lib/nftban/setup/install_node_exporter.sh"
echo "2. Install Prometheus: /usr/lib/nftban/setup/install_prometheus.sh"
echo "3. Enable metrics collection: systemctl enable --now nftban-metrics-exporter.timer"
echo ""
echo "Documentation: /usr/share/doc/nftban/metrics/"
```

---

## Pre-Removal Actions

### DEB prerm Script
```bash
#!/bin/bash
set -e

# Stop and disable timer if running
if systemctl is-active --quiet nftban-metrics-exporter.timer; then
    systemctl stop nftban-metrics-exporter.timer
fi

if systemctl is-enabled --quiet nftban-metrics-exporter.timer; then
    systemctl disable nftban-metrics-exporter.timer
fi
```

### RPM %preun Script
```bash
if [ $1 -eq 0 ]; then
    # Package removal (not upgrade)
    systemctl stop nftban-metrics-exporter.timer 2>/dev/null || true
    systemctl disable nftban-metrics-exporter.timer 2>/dev/null || true
fi
```

---

## Post-Removal Actions

### DEB postrm Script
```bash
#!/bin/bash
set -e

if [ "$1" = "purge" ]; then
    # Remove textfile collector directory on purge
    rm -rf /var/lib/node_exporter/textfile_collector/nftban.prom 2>/dev/null || true
fi

# Reload systemd
systemctl daemon-reload
```

### RPM %postun Script
```bash
if [ $1 -eq 0 ]; then
    # Package removal (not upgrade)
    rm -rf /var/lib/node_exporter/textfile_collector/nftban.prom 2>/dev/null || true
    systemctl daemon-reload
fi
```

---

## Package Metadata

### Package Name
- DEB: `nftban-metrics` or `nftban-prometheus`
- RPM: `nftban-metrics` or `nftban-prometheus`

### Version
- `0.6.0`

### Description
```
NFTBan Prometheus/Grafana Integration

This package provides Prometheus metrics collection for NFTBan firewall,
including exporters, Grafana dashboards, and automated installation scripts.

Features:
 - Prometheus metrics exporter for NFTBan statistics
 - Node Exporter integration via textfile collector
 - 4 pre-built Grafana dashboards (Overview, Health, Geographic, Performance)
 - Automated installation scripts for Node Exporter and Prometheus
 - 15+ alert rules for proactive monitoring
 - Security-hardened systemd services
 - Multi-distro support (RHEL, Fedora, Debian, Ubuntu)
```

### Maintainer
- Name: NFTBan Development Team
- Email: [To be determined]

### Homepage
- URL: [To be determined]

### License
- MPL-2.0 (Mozilla Public License 2.0)

---

## Build Instructions

### DEB Package
```bash
cd /home/commonfolder/Prometheus_Grafana_v06_Parallel

# Create build directory
mkdir -p build/deb/nftban-metrics-0.6.0/DEBIAN
mkdir -p build/deb/nftban-metrics-0.6.0/usr/lib/nftban/{exporters,setup}
mkdir -p build/deb/nftban-metrics-0.6.0/usr/lib/systemd/system/node_exporter.service.d
mkdir -p build/deb/nftban-metrics-0.6.0/usr/share/nftban/{prometheus/alerts,grafana/dashboards}
mkdir -p build/deb/nftban-metrics-0.6.0/usr/share/doc/nftban/metrics

# Copy files (according to manifest)
# ... [copy commands]

# Build package
dpkg-deb --build build/deb/nftban-metrics-0.6.0
```

### RPM Package
```bash
cd /home/commonfolder/Prometheus_Grafana_v06_Parallel

# Create rpmbuild structure
mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

# Create tarball
tar czf ~/rpmbuild/SOURCES/nftban-metrics-0.6.0.tar.gz \
    --transform 's,^,nftban-metrics-0.6.0/,' \
    work/track1/* cli/lib/nftban/setup/* install/* docs/metrics/*

# Build RPM
rpmbuild -ba install/packaging/nftban-metrics.spec
```

---

## Testing Checklist

- [ ] Package installs without errors on RHEL 9
- [ ] Package installs without errors on Fedora 40
- [ ] Package installs without errors on Debian 12
- [ ] Package installs without errors on Ubuntu 24.04
- [ ] All files installed to correct locations
- [ ] Correct permissions on all files
- [ ] Systemd services load without errors
- [ ] Post-install script runs successfully
- [ ] Timer can be enabled and started
- [ ] Metrics exporter runs and creates output file
- [ ] Package removes cleanly
- [ ] Purge removes all files (DEB only)

---

**Status:** Ready for package creation

**Next Steps:**
1. Create DEB control files
2. Create RPM spec file
3. Build and test packages
