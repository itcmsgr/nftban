# NFTBan — Adaptive Firewall for the Modern Linux Stack

**Secure by Design | Zero Trust Ready | AI-Assisted Defense**

[![Version](https://img.shields.io/badge/version-1.0.0--beta-blue)](https://github.com/itcmsgr/nftban)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL%202.0-brightgreen.svg)](https://opensource.org/licenses/MPL-2.0)
[![Code: 80%+ Shell](https://img.shields.io/badge/Code-80%25%2B%20Shell-4EAA25.svg)]()
[![Performance: Go Binaries](https://img.shields.io/badge/Performance-Go%20Binaries-00ADD8.svg)](https://go.dev/)
[![Security: Polkit](https://img.shields.io/badge/Security-Polkit-orange.svg)]()
[![FHS: Compliant](https://img.shields.io/badge/FHS-Compliant-success)]()
[![Status](https://img.shields.io/badge/status-BETA-yellow)]()

NFTBan is an enterprise-grade firewall management system built on Linux nftables — combining atomic rule updates, privilege separation through Polkit, and AI-assisted threat intelligence for a resilient, self-healing network defense layer.

> **BETA TESTING** | We are actively finding and fixing bugs. **NOT production-ready yet.** Tested on 5 lab servers. Community feedback needed from diverse environments. [Report issues here](https://github.com/itcmsgr/nftban/issues).

---

## Quick Install

### Rocky / AlmaLinux 8/9/10 (requires EPEL + CRB)
```bash
sudo dnf install -y epel-release && sudo dnf config-manager --set-enabled crb
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-x86_64.rpm
sudo dnf install -y nftban-x86_64.rpm && sudo nftban enable
```

### Fedora
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-x86_64.rpm
sudo dnf install -y nftban-x86_64.rpm && sudo nftban enable
```

### Ubuntu / Debian
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-amd64.deb
sudo dpkg -i nftban-amd64.deb && sudo apt-get install -f -y && sudo nftban enable
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

| Platform | Architecture | Package |
|----------|--------------|---------|
| RHEL / Rocky / Alma / Fedora | x86_64 | [nftban-x86_64.rpm](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-x86_64.rpm) |
| RHEL / Rocky / Alma / Fedora | aarch64 (ARM64) | [nftban-aarch64.rpm](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-aarch64.rpm) |
| Ubuntu 24.04+ / Debian 12+ | amd64 | [nftban-amd64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-amd64.deb) |
| Ubuntu 24.04+ / Debian 12+ | arm64 | [nftban-arm64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-arm64.deb) |

> Packages are self-contained and FHS compliant. Old versions archived in [Releases](https://github.com/itcmsgr/nftban/releases).

---

## Highlights

- **44 CLI Commands** — Complete firewall management from command line
- **Unified Go Backend** — High-performance feeds, GeoIP, and sync operations
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
nftban smoke all       # Comprehensive test (44 commands)
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
| `nftban` | Bash CLI | Main command-line interface (44 commands) |
| `nftban-core` | Go Binary | Unified backend (feeds, geoip, sync) |
| `nftban-ui` | Go Binary | Web interface server |

---

## Requirements

- **Linux**: Rocky/Alma 8+, Ubuntu 20.04+, Debian 11+, Fedora 38+
- **nftables**: 0.9.3+
- **Bash**: 4.4+
- **systemd**: Required
- **Go 1.22+**: For building from source (optional)

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

## Links

- **Website**: https://nftban.com
- **Wiki**: [GitHub Wiki](https://github.com/itcmsgr/nftban/wiki)
- **Issues**: [Report Bug](https://github.com/itcmsgr/nftban/issues)
- **Discussions**: [Community](https://github.com/itcmsgr/nftban/discussions)

---

<p align="center">
  <b>NFTBan - Simplifying Linux Firewall Management</b><br>
  <a href="https://nftban.com">nftban.com</a> |
  <a href="https://github.com/itcmsgr/nftban/issues">Report Issue</a> |
  <a href="https://github.com/itcmsgr/nftban/discussions">Discussions</a>
</p>
