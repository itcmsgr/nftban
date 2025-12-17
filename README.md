# NFTBan — Adaptive Firewall for the Modern Linux Stack

**Secure by Design | Zero Trust Ready | AI‑Assisted Defense**

[![Version](https://img.shields.io/badge/version-1.0.0--beta-blue)](https://github.com/itcmsgr/nftban)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL%202.0-brightgreen.svg)](https://opensource.org/licenses/MPL-2.0)
[![Code: 80%+ Shell](https://img.shields.io/badge/Code-80%25%2B%20Shell-4EAA25.svg)]()
[![Performance: Go Binaries](https://img.shields.io/badge/Performance-Go%20Binaries-00ADD8.svg)](https://go.dev/)
[![Security: Polkit](https://img.shields.io/badge/Security-Polkit-orange.svg)]()
[![FHS: Compliant](https://img.shields.io/badge/FHS-Compliant-success)](docs/wiki/FHS-Compliance.md)
[![Status](https://img.shields.io/badge/status-BETA-yellow)]()

NFTBan is an enterprise‑grade firewall management system built on Linux nftables — combining atomic rule updates, privilege separation through Polkit, and AI‑assisted threat intelligence for a resilient, self‑healing network defense layer.

> ⚠️ **BETA TESTING** | We are actively finding and fixing bugs. **NOT production-ready yet.** Tested on 5 lab servers. Community feedback needed from diverse environments. [Report issues here](https://github.com/itcmsgr/nftban/issues).

---

## Highlights

- **43 CLI Commands** - Complete firewall management from command line
- **Unified Go Backend** - High-performance feeds, GeoIP, and sync operations
- **Web Interface** - Modern dashboard for visual management (Mode 2)
- **Dual-Table Architecture** - Clean IPv4/IPv6 separation with `ip nftban` and `ip6 nftban`
- **FHS Compliant** - Follows Filesystem Hierarchy Standard
- **Security Hardened** - Systemd sandboxing, capability-based permissions

---

## Features

### Core Protection
| Feature | Description |
|---------|-------------|
| **Threat Intelligence Feeds** | Automatic blocking from Spamhaus, AbuseIPDB, Firehol, etc. |
| **Geographic Blocking (GeoBan)** | Block/allow traffic by country code |
| **Login Monitoring** | Detects SSH brute-force and suspicious patterns |
| **Port Scan Detection** | Automatic detection and blocking of reconnaissance |
| **DDoS Protection** | Rate limiting, SYN flood protection, connection limits |
| **IP Whitelisting** | Protected IPs that can never be banned |

### Management
| Feature | Description |
|---------|-------------|
| **Unified CLI** | 43 commands for complete firewall control |
| **Web GUI** | Dashboard, IP management, log viewer (Mode 2) |
| **REST API** | Full API for automation and integration |
| **Health Monitoring** | System diagnostics with auto-heal capability |
| **Smoke Testing** | Built-in CLI health checks |
| **Module System** | Inventory, validation, and dependency tracking |

### Advanced
| Feature | Description |
|---------|-------------|
| **Suricata IDS** | Optional deep packet inspection integration |
| **Prometheus Metrics** | Full observability for monitoring stacks |
| **Cloudflare Integration** | Sync bans to Cloudflare firewall rules |
| **Security Profiles** | Pre-configured security levels (basic/standard/advanced) |

---

## Installation Modes

### Mode 1: CLI-Only (Lightweight)

For VPS, small servers, minimal resource usage (~50MB RAM)

```bash
sudo ./install.sh cli
```

Includes:
- Complete CLI (43 commands)
- NFTables firewall with nftban table
- All protection modules (login, feeds, portscan, ddos, geoban)
- Bash-based feed processing
- Systemd timers for automation

### Mode 2: GUI + Prometheus (Full)

For production servers, monitoring infrastructure (~200MB RAM)

```bash
sudo ./install.sh gui
```

Includes everything from Mode 1, plus:
- Web GUI (port 3940)
- Go backend binaries (nftban-core, nftban-ui)
- REST API server
- Prometheus metrics exporter
- Suricata IDS integration support

---

## Quick Start

```bash
# Clone repository
git clone https://github.com/itcmsgr/nftban.git
cd nftban

# Install (choose mode)
sudo ./install.sh cli    # or: sudo ./install.sh gui

# Verify installation
nftban version
nftban health summary

# Enable protection
nftban login enable      # SSH login monitoring
nftban feeds enable      # Threat intelligence feeds
nftban portscan enable   # Port scan detection

# Check status
nftban status
```

---

## CLI Commands (43 total)

### System & Health
```bash
nftban status              # Quick system overview
nftban health              # System diagnostics with auto-heal
nftban health summary      # One-line health status
nftban validate            # Firewall structure validation
nftban version             # Show version info
nftban services            # Systemd services status
nftban timers              # Timer status
nftban fhs                 # FHS compliance check
```

### IP Management
```bash
nftban ban <IP>            # Ban IP (with optional timeout)
nftban ban <IP> 24h        # Ban for 24 hours
nftban unban <IP>          # Remove ban
nftban search <IP>         # Search across all sets
nftban whitelist add <IP>  # Add to whitelist
nftban whitelist list      # List whitelisted IPs
```

### Protection Modules
```bash
nftban login status        # SSH login monitoring
nftban login enable        # Enable login protection
nftban feeds list          # Threat feed status
nftban feeds update        # Update all feeds
nftban portscan status     # Port scan detection
nftban ddos status         # DDoS protection status
nftban geoban list         # Geographic blocking status
nftban geoban block CN     # Block country by ISO code
```

### Firewall Control
```bash
nftban firewall status     # Firewall status
nftban firewall reload     # Atomic reload (no downtime)
nftban nftables list       # List nftables rules
nftban port list           # Port configuration
nftban port open 443/tcp   # Open port
nftban sync                # Sync configuration to nftables
```

### Reporting & Stats
```bash
nftban stats summary       # Statistics summary
nftban stats dashboard     # Dashboard view
nftban report daily        # Daily security report
nftban module              # Module inventory
nftban module validate     # Validate module metadata
```

### Testing & Debug
```bash
nftban smoke run           # Standard smoke test (~20 commands)
nftban smoke quick         # Quick test (3 commands)
nftban smoke all           # Comprehensive test (43 commands)
nftban debug enable        # Enable debug trace
nftban emulate <scenario>  # Test scenarios safely
```

### Configuration
```bash
nftban config show         # Show configuration
nftban profile list        # List security profiles
nftban profile apply basic # Apply security profile
nftban setup               # Interactive setup wizard
nftban wizard              # Guided configuration
```

See [CLI Commands Reference](docs/wiki/CLI-Commands-Reference.md) for complete documentation.

---

## Architecture

### Components

| Component | Type | Description |
|-----------|------|-------------|
| `nftban` | Bash CLI | Main command-line interface (43 commands) |
| `nftban-core` | Go Binary | Unified backend (feeds, geoip, sync) |
| `nftban-ui` | Go Binary | Web interface server |
| `nftban-api-server` | Go Binary | REST API server |

### NFTables Structure

```
ip nftban {                  # IPv4 rules
    set whitelist_ipv4 {...}
    set blacklist_ipv4 {...}
    set feeds_ipv4 {...}
    set geoban_ipv4 {...}
    set tcp_ports {...}
    set udp_ports {...}
    chain input {...}
    chain output {...}
}

ip6 nftban {                 # IPv6 rules
    set whitelist_ipv6 {...}
    set blacklist_ipv6 {...}
    chain input {...}
    chain output {...}
}
```

### Directory Structure (FHS Compliant)

```
/usr/bin/nftban                 # Main CLI symlink
/usr/sbin/nftban-*              # Go binaries
/usr/lib/nftban/                # Libraries and modules
    cli/                        # CLI command handlers (43 files)
    core/                       # Core modules
    helpers/                    # Utility functions
    lib/                        # Shared libraries
/etc/nftban/                    # Configuration
    nftban.conf                 # Main config
    conf.d/                     # Drop-in configs
/var/lib/nftban/                # Runtime data
/var/log/nftban/                # Logs
/var/cache/nftban/              # Cache (feeds, geoip)
```

---

## Configuration

Main configuration: `/etc/nftban/nftban.conf`

```bash
# Version
NFTBAN_VERSION="1.0.0"

# Logging
NFTBAN_LOG_LEVEL="INFO"
NFTBAN_LOG_FILE="/var/log/nftban/nftban.log"

# Protection modules (enable individually)
NFTBAN_LOGIN_MONITOR_ENABLED="false"
NFTBAN_FEEDS_ENABLED="false"
NFTBAN_GEOIP_ENABLED="false"
NFTBAN_DDOS_ENABLED="false"
NFTBAN_PORTSCAN_ENABLED="false"

# Feeds configuration
FEEDS_AUTO_UPDATE="true"
FEEDS_UPDATE_INTERVAL="6h"

# Banner customization
NFTBAN_BANNER_UPDATE_CHECK="true"  # Show update notifications
```

See [Configuration Reference](docs/wiki/Configuration-Reference.md) for all options.

---

## Requirements

### System
- Linux (Rocky/Alma 8+, Ubuntu 20.04+, Debian 11+, Fedora 38+)
- nftables 0.9.3+
- Bash 4.4+
- systemd

### Go Components (Mode 2 only)
- Go 1.22+ (for building from source)

### Optional
- MaxMind GeoLite2 database (for GeoIP features)
- Suricata (for IDS integration)

---

## Security

NFTBan is designed with security as a priority:

- **Capability-based permissions** - Uses CAP_NET_ADMIN instead of root
- **Systemd hardening** - NoNewPrivileges, ProtectSystem, sandboxing
- **Input validation** - All CLI inputs validated
- **No setuid binaries** - Socket-based privilege escalation
- **Audit logging** - All actions logged and attributable

See [Security Architecture](docs/wiki/Security-Architecture.md) for details.

---

## Documentation

### Wiki
- [Home](docs/wiki/Home.md) - Getting started
- [CLI Commands Reference](docs/wiki/CLI-Commands-Reference.md) - All 43 commands
- [Configuration Reference](docs/wiki/Configuration-Reference.md) - All options
- [Security Architecture](docs/wiki/Security-Architecture.md) - Security design
- [FHS Compliance](docs/wiki/FHS-Compliance.md) - Directory structure
- [Groups and Permissions](docs/wiki/Groups-and-Permissions.md) - User/group model

### Guides
- [Mode 1: CLI-Only Installation](docs/wiki/Mode-1-CLI-Only-Installation.md)
- [Mode 2: GUI + Prometheus](docs/wiki/Mode-2-GUI-Prometheus-Installation.md)
- [Go Build Requirements](docs/wiki/Go-Build-Requirements.md)
- [Troubleshooting](docs/guides/DEBUG_AND_TROUBLESHOOTING.md)

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

```bash
# Development setup
git clone https://github.com/itcmsgr/nftban.git
cd nftban

# Build Go binaries
./build.sh

# Run smoke tests
nftban smoke all

# Validate CLI help
./scripts/validate_cli_help.sh
```

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

- Website: https://nftban.com
- Documentation: [docs/](docs/)
- Issues: [GitHub Issues](https://github.com/itcmsgr/nftban/issues)
- Discussions: [GitHub Discussions](https://github.com/itcmsgr/nftban/discussions)

---

<p align="center">
  <b>NFTBan - Simplifying Linux Firewall Management</b><br>
  <a href="https://nftban.com">nftban.com</a> |
  <a href="https://github.com/itcmsgr/nftban/issues">Report Issue</a> |
  <a href="https://github.com/itcmsgr/nftban/discussions">Discussions</a>
</p>
