# 🛡️ NFTBAN: Next-Gen Nftables Firewall

**Enterprise-Grade | Atomic Updates | Polkit-Secured | AI-Ready**

[![Version](https://img.shields.io/badge/version-1.11.0-blue)](https://github.com/itcmsgr/nftban)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL%202.0-brightgreen.svg)](https://opensource.org/licenses/MPL-2.0)
[![Code: 58% Shell 42% Go](https://img.shields.io/badge/Code-58%25%20Shell%20%7C%2042%25%20Go-4EAA25.svg)]()
[![Performance: Go Binaries](https://img.shields.io/badge/Performance-Go%20Binaries-00ADD8.svg)](https://go.dev/)
[![Security: Polkit](https://img.shields.io/badge/Security-Polkit-orange.svg)]()
[![FHS: Compliant](https://img.shields.io/badge/FHS-Compliant-success)]()
[![Status](https://img.shields.io/badge/status-BETA-yellow)]()

**NFTBAN (NFTables BAN actions)** is a high-performance firewall management system designed for modern Linux environments. Moving beyond legacy iptables-based scripts, NFTBAN provides a resilient, self-healing network defense layer by combining the raw power of **nftables** with advanced privilege separation and real-time threat intelligence.

### Why NFTBAN?

- **⚡ Atomic Performance** — Leverages native nftables for near-instant rule updates without flushing connections
- **🔐 Security First** — Uses Polkit for granular privilege separation; management without needing full root access
- **🤖 Intelligent Defense** — Integrated AI-assisted threat intelligence for proactive and self-healing network protection
- **🌐 Hosting Ready** — Built-in support for DirectAdmin, cPanel, CWP, CyberPanel, and custom panels

> **BETA TESTING** | We are actively finding and fixing bugs. **NOT production-ready yet.** Tested on 5 lab servers. Community feedback needed from diverse environments. [Report issues here](https://github.com/itcmsgr/nftban/issues).

---

## Quick Install

### Tier 0 — Primary Platforms (Recommended)

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

> **Note:** Fedora is the upstream development platform for RHEL. The `el9` package (based on Fedora 34) and `el10` package (based on Fedora 40) cover enterprise use cases. Fedora users can use the corresponding EL package.

### DEB Packages (Ubuntu + Debian)

| Tier | Distribution | Version | Package |
|------|--------------|---------|---------|
| 0 | Ubuntu | 24.04 (Noble) | [nftban-ubuntu24.04-amd64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-ubuntu24.04-amd64.deb) |
| 0 | Debian | 12 (Bookworm) | [nftban-debian12-amd64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-debian12-amd64.deb) |
| 1 | Debian | 13 (Trixie) | [nftban-debian13-amd64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-debian13-amd64.deb) |
| 2 | Ubuntu | 22.04 (Jammy) | [nftban-ubuntu22.04-amd64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-ubuntu22.04-amd64.deb) |

> Packages are distro-specific and FHS compliant. Use the package matching your exact distribution version. See [Supported Platforms](https://github.com/itcmsgr/nftban/wiki/Supported-Platforms) for the full platform contract. Old versions archived in [Releases](https://github.com/itcmsgr/nftban/releases).

---

## Highlights

- **54 CLI Commands** — Complete firewall management from command line
- **Unified Go Backend** — High-performance feeds, GeoIP, and sync operations
- **Suricata Integration** — Intelligent rule management with 50-70% rule reduction
- **RBL Monitoring** — Real-time blackhole list checking and IP reputation tracking
- **Web Interface** — Modern dashboard for visual management
- **Dual-Table Architecture** — Clean IPv4/IPv6 separation with `ip nftban` and `ip6 nftban`
- **FHS Compliant** — Follows Filesystem Hierarchy Standard
- **Security Hardened** — Systemd sandboxing, capability-based permissions

---

## Core Features

| Feature | Description |
|---------|-------------|
| **Threat Intelligence Feeds** | Automatic blocking from Spamhaus, AbuseIPDB, Firehol, etc. |
| **Geographic Blocking (GeoBan)** | Block/allow traffic by country code |
| **Login Monitoring** | Detects SSH brute-force and suspicious patterns |
| **Port Scan Detection** | Automatic detection and blocking of reconnaissance |
| **DDoS Protection** | Rate limiting, SYN flood protection, connection limits |
| **Suricata IDS** | Optional deep packet inspection integration |
| **Prometheus Metrics** | Full observability for monitoring stacks |
| **Connectors** | Export to Elasticsearch, Kafka, syslog, webhook |
| **Cloudflare Integration** | Auto-whitelist Cloudflare proxy IPs |

---

## Quick Start

```bash
# Verify installation
nftban version
nftban health summary

# Enable protection
nftban login enable      # SSH login monitoring
nftban feeds enable      # Threat intelligence feeds
nftban portscan enable   # Port scan detection

# Optional: Advanced IDS integration
nftban suricata install  # Install Suricata IDS (automated)
nftban suricata enable   # Enable with weekly rule updates

# Common tasks
nftban ban 1.2.3.4       # Block IP
nftban unban 1.2.3.4     # Remove ban
nftban search 1.2.3.4    # Search across all sets
nftban firewall reload   # Atomic reload (no downtime)

# Check status
nftban status
```

---

## CLI Overview

### System & Health
```bash
nftban status          # Quick system overview
nftban health          # System diagnostics with auto-heal
nftban validate        # Firewall structure validation
nftban services        # Systemd services status
nftban configtest      # Validate config against schema
nftban configaudit     # Audit config for drift and changes
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

### Testing
```bash
nftban smoke run       # Standard smoke test
nftban smoke all       # Comprehensive test (54 commands)
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
| `nftban` | Bash CLI | Main command-line interface (54 commands) |
| `nftban-core` | Go Binary | Unified backend (feeds, geoip, sync) |
| `nftban-ui` | Go Binary | Web interface server |

---

## Requirements

- **Linux**: Rocky/Alma/RHEL 9-10, CentOS Stream 9-10, Ubuntu 22.04+, Debian 12+
- **nftables**: 1.0+ (native backend)
- **Bash**: 4.4+
- **systemd**: 252+ (sysusers.d, tmpfiles.d support)
- **jq**: JSON processor (auto-installed)
- **yq**: YAML processor (auto-installed via pip3)
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

**NFTBan is correct if it builds and passes receipt-based audit on these platforms.**

### Tier 1 — Future (Planned)

- Rocky Linux 10.x / AlmaLinux 10.x / RHEL 10
- Debian 13 (Trixie)
- Ubuntu 26.04 LTS

### Tier 2 — Legacy (Best-Effort)

- Rocky/RHEL 8.x, Ubuntu 22.04, Debian 11

---

## AI-Assisted Development

NFTBan is developed through **ethical AI collaboration** combining human expertise with AI capabilities:

| Partner | Role |
|---------|------|
| **ChatGPT (OpenAI)** | Architecture & Design Planning |
| **Claude Code (Anthropic)** | Implementation & Testing |
| **Claude AI (Anthropic)** | Review & Optimization |

All AI-generated code is human-reviewed, version-controlled, and transparently attributed.

---

## License

Mozilla Public License 2.0 (MPL-2.0)

Copyright (c) 2024-2026 NFTBan Project / Antonios Voulvoulis

---

## Documentation

### Getting Started
- **[Wiki Home](https://github.com/itcmsgr/nftban/wiki)** - Complete documentation
- **[CLI Commands Reference](https://github.com/itcmsgr/nftban/wiki/CLI-Commands-Reference)** - All 54 commands
- **[Installation Guide](https://github.com/itcmsgr/nftban/wiki/Installation-Guide)** - Prerequisites, install, post-config

### Advanced Integration
- **[Suricata IDS Integration](https://github.com/itcmsgr/nftban/wiki/Suricata-IDS-Integration)** - Complete guide for Suricata IDS/IPS setup (2-command install, auto-detected profiles, DDoS/portscan integration)

### Security
- **[Security Policy](SECURITY.md)** - Vulnerability reporting
- **[Security Architecture](https://github.com/itcmsgr/nftban/wiki/Security-Architecture)** - FHS Auto-Heal, Polkit integration
- **[Security Operations Guide](https://github.com/itcmsgr/nftban/wiki/Security-Operations-Guide)** - Hardening, monitoring, emergency procedures
- **[Security Architecture](https://github.com/itcmsgr/nftban/wiki/Security-Architecture#access-control-model)** - Access control, groups and permissions

### Community
- **Website**: https://nftban.com
- **[Report Bug](https://github.com/itcmsgr/nftban/issues)** - Issue tracker
- **[Discussions](https://github.com/itcmsgr/nftban/discussions)** - Community forum

---

<p align="center">
  <b>NFTBan - Linux Firewall Management via nftables</b><br>
  <a href="https://nftban.com">nftban.com</a> |
  <a href="https://github.com/itcmsgr/nftban/issues">Report Issue</a> |
  <a href="https://github.com/itcmsgr/nftban/discussions">Discussions</a>
</p>

