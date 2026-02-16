# NFTBan

**Linux Intrusion Prevention System & nftables Firewall Manager**

[![Version](https://img.shields.io/badge/version-1.15.1-blue)](https://github.com/itcmsgr/nftban/releases)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL%202.0-brightgreen.svg)](https://opensource.org/licenses/MPL-2.0)
[![Go](https://img.shields.io/badge/Go-1.23-00ADD8.svg)](https://go.dev/)
[![SLSA 3](https://slsa.dev/images/gh-badge-level3.svg)](https://slsa.dev)
[![OpenSSF Scorecard](https://img.shields.io/ossf-scorecard/github.com/itcmsgr/nftban?label=openssf%20scorecard)](https://securityscorecards.dev/viewer/?uri=github.com/itcmsgr/nftban)
[![Semgrep](https://img.shields.io/badge/Semgrep-enabled-blue?logo=semgrep)](https://semgrep.dev/)
[![FHS Compliant](https://img.shields.io/badge/FHS-Compliant-success)]()
[![Status](https://img.shields.io/badge/status-BETA-yellow)]()

NFTBan is an open-source Linux Intrusion Prevention System (IPS) and firewall manager built on nftables, designed to integrate cleanly with modern Linux security stacks.

It provides automated threat detection and response using native nftables for kernel-level enforcement, with Polkit-based privilege separation for secure operation without full root access.

> **BETA** | Tested on 5 lab servers. Community feedback needed from diverse environments. [Report issues here](https://github.com/itcmsgr/nftban/issues).

---

## Quick Install

### Tier 0 — Primary Platforms

#### Ubuntu 24.04 LTS (Noble)
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-ubuntu24.04-amd64.deb
sudo apt update && sudo apt install -y ./nftban-ubuntu24.04-amd64.deb && sudo nftban enable
```

#### Debian 12 (Bookworm)
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-debian12-amd64.deb
sudo apt update && sudo apt install -y ./nftban-debian12-amd64.deb && sudo nftban enable
```

#### Rocky / AlmaLinux / RHEL 9
```bash
sudo dnf install -y epel-release && sudo dnf config-manager --set-enabled crb
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-el9-x86_64.rpm
sudo dnf install -y nftban-el9-x86_64.rpm && sudo nftban enable
```

### Tier 1 — Future Platforms

#### Debian 13 (Trixie)
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-debian13-amd64.deb
sudo apt update && sudo apt install -y ./nftban-debian13-amd64.deb && sudo nftban enable
```

#### Rocky / AlmaLinux / RHEL 10
```bash
sudo dnf install -y epel-release && sudo dnf config-manager --set-enabled crb
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-el10-x86_64.rpm
sudo dnf install -y nftban-el10-x86_64.rpm && sudo nftban enable
```

### Tier 2 — Legacy Platforms

#### Ubuntu 22.04 LTS (Jammy)
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-ubuntu22.04-amd64.deb
sudo apt update && sudo apt install -y ./nftban-ubuntu22.04-amd64.deb && sudo nftban enable
```

### From Source
```bash
git clone https://github.com/itcmsgr/nftban.git && cd nftban
sudo ./install.sh cli    # CLI-only (~50MB RAM)
# or
sudo ./install.sh gui    # Full with Web GUI (~200MB RAM)
```

---

## Available Packages

### RPM Packages (EL Family)

| Tier | Distribution | Version | Package |
|------|--------------|---------|---------|
| 0 | Rocky / Alma / RHEL / CentOS Stream | 9 | [nftban-el9-x86_64.rpm](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-el9-x86_64.rpm) |
| 1 | Rocky / Alma / RHEL / CentOS Stream | 10 | [nftban-el10-x86_64.rpm](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-el10-x86_64.rpm) |

### DEB Packages (Ubuntu + Debian)

| Tier | Distribution | Version | Package |
|------|--------------|---------|---------|
| 0 | Ubuntu | 24.04 (Noble) | [nftban-ubuntu24.04-amd64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-ubuntu24.04-amd64.deb) |
| 0 | Debian | 12 (Bookworm) | [nftban-debian12-amd64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-debian12-amd64.deb) |
| 1 | Debian | 13 (Trixie) | [nftban-debian13-amd64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-debian13-amd64.deb) |
| 2 | Ubuntu | 22.04 (Jammy) | [nftban-ubuntu22.04-amd64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-ubuntu22.04-amd64.deb) |

> Packages are distro-specific and FHS compliant. Use the package matching your exact distribution version. See [Supported Platforms](https://github.com/itcmsgr/nftban/wiki/Supported-Platforms) for the full platform contract.

---

## Features

| Feature | Description |
|---------|-------------|
| **Threat Intelligence Feeds** | Automatic blocking from Spamhaus, AbuseIPDB, Firehol |
| **Geographic Blocking** | Block or allow traffic by country code |
| **Login Monitoring** | Detects SSH brute-force and suspicious authentication patterns |
| **Port Scan Detection** | Automatic detection and blocking of reconnaissance |
| **DDoS Protection** | Rate limiting, SYN flood protection, connection limits |
| **Suricata IDS Integration** | Optional deep packet inspection |
| **Prometheus Metrics** | Observability for monitoring stacks |
| **Zabbix Integration** | Native trapper protocol export to Zabbix server |
| **Portal (pro.nftban.com)** | Centralized metrics aggregation and fleet management |
| **Connectors** | Export to Elasticsearch, Kafka, syslog, webhook |

---

## Quick Start

```bash
# Verify installation
nftban version
nftban health summary

# Enable protection modules
nftban login enable      # SSH login monitoring
nftban feeds enable      # Threat intelligence feeds
nftban portscan enable   # Port scan detection

# Optional: Suricata IDS integration
nftban suricata install  # Install Suricata IDS
nftban suricata enable   # Enable with weekly rule updates

# Common operations
nftban ban 1.2.3.4       # Block IP
nftban unban 1.2.3.4     # Remove ban
nftban search 1.2.3.4    # Search across all sets
nftban firewall reload   # Atomic reload

# Check status
nftban status
```

---

## CLI Overview

### System & Health
```bash
nftban status          # System overview
nftban health          # Diagnostics with auto-heal
nftban validate        # Firewall structure validation
nftban services        # Systemd services status
nftban configtest      # Validate config against schema
```

### IP Management
```bash
nftban ban <IP>        # Ban IP (with optional timeout)
nftban unban <IP>      # Remove ban
nftban search <IP>     # Search across all sets
nftban whitelist add   # Add to whitelist
```

### Protection Modules
```bash
nftban login status    # SSH login monitoring
nftban feeds list      # Threat feed status
nftban geoban list     # Geographic blocking
nftban portscan status # Port scan detection
nftban ddos status     # DDoS protection
```

See [CLI Commands Reference](https://github.com/itcmsgr/nftban/wiki/CLI-Commands-Reference) for complete documentation.

---

## Architecture

```
ip nftban {                  # IPv4 rules
    set whitelist_ipv4 {...}
    set blacklist_ipv4 {...}
    set feeds_ipv4 {...}
    set geoban_ipv4 {...}
    chain input {...}
}

ip6 nftban {                 # IPv6 rules
    set whitelist_ipv6 {...}
    set blacklist_ipv6 {...}
    chain input {...}
}
```

### Components

| Component | Type | Description |
|-----------|------|-------------|
| `nftban` | Bash CLI | Main command-line interface (76 commands) |
| `nftban-core` | Go Binary | Backend for feeds, geoip, sync |
| `nftban-ui` | Go Binary | Web interface server |

---

## Requirements

- **Linux**: Rocky/Alma/RHEL 9-10, CentOS Stream 9-10, Ubuntu 22.04+, Debian 12+
- **nftables**: 1.0+ (native backend)
- **Bash**: 4.4+
- **systemd**: 252+ (sysusers.d, tmpfiles.d support)
- **jq**: JSON processor (auto-installed)
- **yq**: YAML processor (auto-installed)
- **Go 1.21+**: For building from source (optional)

---

## Supported Platforms

NFTBan uses a tiered support model. See the [full platform contract](https://github.com/itcmsgr/nftban/wiki/Supported-Platforms) for details.

### Tier 0 — Primary (CI-Required)

| Family | Platform | Kernel | nftables |
|--------|----------|--------|----------|
| DEB | Ubuntu 24.04 LTS | 6.8 | 1.0 |
| DEB | Debian 12 | 6.1 | 1.0 |
| RPM | Rocky Linux 9.x | 5.14 | 1.0 |

### Tier 1 — Future (Planned)

- Rocky Linux 10.x / AlmaLinux 10.x / RHEL 10
- Debian 13 (Trixie)
- Ubuntu 26.04 LTS

### Tier 2 — Legacy (Best-Effort)

- Rocky/RHEL 8.x, Ubuntu 22.04, Debian 11

---

## Development

NFTBan development uses AI tools for code generation and review. All code is human-reviewed and version-controlled.

| Tool | Use |
|------|-----|
| ChatGPT (OpenAI) | Architecture planning |
| Claude (Anthropic) | Implementation, testing, review |

---

## License

Mozilla Public License 2.0 (MPL-2.0)

Copyright (c) 2024-2026 NFTBan Project / Antonios Voulvoulis

---

## Security & Supply Chain

| Control | Status |
|---------|--------|
| **SLSA Level 3** | Provenance attestation for Go binaries |
| **SBOM** | SPDX-JSON attached to every release |
| **Vulnerability Scanning** | govulncheck, Trivy, gosec, CodeQL |
| **Semgrep** | Static analysis for security patterns in Go and shell code |
| **Dependency Review** | PR-level dependency vulnerability scanning |
| **Secret Scanning** | gitleaks with SARIF upload |
| **OpenSSF Scorecard** | Automated security posture assessment |

See [SECURITY.md](SECURITY.md) for vulnerability disclosure policy and security architecture.

---

## Documentation

### Getting Started
- [Wiki Home](https://github.com/itcmsgr/nftban/wiki) — Complete documentation
- [CLI Commands Reference](https://github.com/itcmsgr/nftban/wiki/CLI-Commands-Reference) — All commands
- [Installation Guide](https://github.com/itcmsgr/nftban/wiki/Installation-Guide) — Prerequisites, install, post-config

### Architecture & Security
- [Architecture](docs/ARCHITECTURE.md) — System design and data flow
- [Threat Model](docs/THREAT_MODEL.md) — Assets, adversaries, attack surfaces
- [Security Policy](SECURITY.md) — Vulnerability reporting, privilege model
- [Reproducible Builds](docs/REPRODUCIBLE_BUILDS.md) — Build verification

### Integration
- [Suricata IDS](https://github.com/itcmsgr/nftban/wiki/Suricata-IDS-Integration) — IDS/IPS setup
- [Control Panels](https://github.com/itcmsgr/nftban/wiki/Panel-Integration) — cPanel, DirectAdmin, Plesk

### Community
- Website: https://nftban.com
- [Report Bug](https://github.com/itcmsgr/nftban/issues)
- [Discussions](https://github.com/itcmsgr/nftban/discussions)

---

<p align="center">
  <b>NFTBan — Linux IPS & nftables Firewall Manager</b><br>
  <a href="https://nftban.com">nftban.com</a> |
  <a href="https://github.com/itcmsgr/nftban/issues">Report Issue</a> |
  <a href="https://github.com/itcmsgr/nftban/discussions">Discussions</a>
</p>
