# NFTBan

**Linux Intrusion Prevention System & nftables Firewall Manager**

[![Version](https://img.shields.io/badge/version-1.53.0-blue)](https://github.com/itcmsgr/nftban/releases)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL%202.0-brightgreen.svg)](https://opensource.org/licenses/MPL-2.0)
[![Go](https://img.shields.io/badge/Go-1.24-00ADD8.svg)](https://go.dev/)
[![Status](https://img.shields.io/badge/status-BETA-yellow)]()
[![FHS Compliant](https://img.shields.io/badge/FHS-Compliant-success)]()

### CI/CD Status

[![Shell Quality](https://github.com/itcmsgr/nftban/actions/workflows/ci-bash.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-bash.yml)
[![Go Quality](https://github.com/itcmsgr/nftban/actions/workflows/ci-go.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-go.yml)
[![Architecture](https://github.com/itcmsgr/nftban/actions/workflows/ci-architecture.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-architecture.yml)
[![Build Packages](https://github.com/itcmsgr/nftban/actions/workflows/build-packages.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/build-packages.yml)
[![Docker](https://github.com/itcmsgr/nftban/actions/workflows/docker.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/docker.yml)
[![ShellCheck](https://github.com/itcmsgr/nftban/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/shellcheck.yml)

### Security & Supply Chain

[![SLSA 3](https://slsa.dev/images/gh-badge-level3.svg)](https://slsa.dev)
[![SBOM](https://img.shields.io/badge/SBOM-SPDX--JSON-blue)](https://github.com/itcmsgr/nftban/releases)
[![OpenSSF Scorecard](https://img.shields.io/ossf-scorecard/github.com/itcmsgr/nftban?label=OpenSSF%20Scorecard)](https://securityscorecards.dev/viewer/?uri=github.com/itcmsgr/nftban)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/11959/badge)](https://www.bestpractices.dev/projects/11959)
[![CodeQL](https://github.com/itcmsgr/nftban/actions/workflows/codeql.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/codeql.yml)
[![Semgrep](https://github.com/itcmsgr/nftban/actions/workflows/semgrep.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/semgrep.yml)
[![OSV-Scanner](https://github.com/itcmsgr/nftban/actions/workflows/osv-scanner.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/osv-scanner.yml)
[![Trivy](https://github.com/itcmsgr/nftban/actions/workflows/secure-go.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/secure-go.yml)
[![gitleaks](https://github.com/itcmsgr/nftban/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/gitleaks.yml)
[![Fuzz Testing](https://github.com/itcmsgr/nftban/actions/workflows/fuzz.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/fuzz.yml)

### 2026 OSSRA Compliance

[![OSSRA Remediation](https://github.com/itcmsgr/nftban/actions/workflows/ossra-remediation.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ossra-remediation.yml)
[![License Compliance](https://img.shields.io/badge/Licenses-Compliant-success)](https://github.com/itcmsgr/nftban/actions/workflows/ossra-remediation.yml)
[![Dependency Health](https://img.shields.io/badge/Libyear-Tracked-blue)](https://github.com/itcmsgr/nftban/actions/workflows/ossra-remediation.yml)

---

## Security Hardening (2026 OSSRA Compliant)

This project implements a **Zero-Trust CI/CD pipeline** designed for the modern threat landscape:

| Control | Protection |
|---------|------------|
| **SLSA Level 3** | Cryptographic provenance - every binary proves its source |
| **License Enforcement** | Blocks GPL/copyleft via `go-licenses` - prevents AI hallucinations |
| **Dependency Freshness** | Libyear metrics flag "zombie" components >2 years old |
| **URL Validation** | Lychee catches hallucinated/hijacked documentation links |
| **Secret Scanning** | Gitleaks + GitGuardian prevent credential leaks |
| **Supply Chain** | All GitHub Actions SHA-pinned to prevent hijacking |
| **Behavioral Analysis** | Socket.dev detects typosquatting and malicious packages |

> See [SECURITY.md](SECURITY.md) for vulnerability reporting and supported versions.

---

NFTBan is an open-source Linux Intrusion Prevention System (IPS) and firewall manager built on nftables, designed to integrate cleanly with modern Linux security stacks.

It provides automated threat detection and response using native nftables for kernel-level enforcement, with Polkit-based privilege separation for secure operation without full root access.

## Go Module Notice

NFTBan is a **system-level firewall product**, not a general-purpose Go library.

While this repository is a Go module and appears on [pkg.go.dev](https://pkg.go.dev/github.com/itcmsgr/nftban), it is **not designed or supported for use as an embeddable SDK**. The Go packages exist to implement the NFTBan daemon, CLI, and internal tooling.

### Supported Public Packages

| Package | Purpose |
|---------|---------|
| [`pkg/ipc`](https://pkg.go.dev/github.com/itcmsgr/nftban/pkg/ipc) | IPC client for communicating with the NFTBan daemon |
| [`pkg/version`](https://pkg.go.dev/github.com/itcmsgr/nftban/pkg/version) | Version information |

### For Integration with NFTBan

- **CLI:** `nftban ban`, `nftban unban`, `nftban status`
- **Go IPC client:** `pkg/ipc` — the supported public Go package
- **HTTP API:** `http://127.0.0.1:8080/api/` (when daemon is running)

All packages under `internal/` are implementation details and may change without notice between releases.

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
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-el9-x86_64.rpm
sudo dnf install -y ./nftban-el9-x86_64.rpm && sudo nftban enable
```

### Tier 1 — Future Platforms

#### Debian 13 (Trixie)
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-debian13-amd64.deb
sudo apt update && sudo apt install -y ./nftban-debian13-amd64.deb && sudo nftban enable
```

#### Rocky / AlmaLinux / RHEL 10
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-el10-x86_64.rpm
sudo dnf install -y ./nftban-el10-x86_64.rpm && sudo nftban enable
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
| **HTTP Bot Guard** | Intelligent crawler detection with kernel-native suspect marking |
| **DNS Tunnel Suspicion** | Advisory-only DNS tunnel detection with 5 signals (v1.30.0) |
| **Suricata IDS Integration** | Optional deep packet inspection |
| **Prometheus Metrics** | Observability for monitoring stacks |
| **Zabbix Integration** | Native trapper protocol export to Zabbix server |
| **Portal (pro.nftban.com)** | Centralized metrics aggregation and fleet management |
| **Connectors** | Export to Elasticsearch, Kafka, syslog, webhook |
| **Whitelist Safety Tests** | Protected whitelists with automated safety validation |

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
nftban botguard status # HTTP bot guard (v1.20.0)
nftban tunnel status   # DNS tunnel suspicion (v1.30.0)
```

### DNS Tunnel Suspicion (v1.30.0)
```bash
nftban tunnel enable       # Enable monitoring (disabled by default)
nftban tunnel status       # Show status and summary
nftban tunnel scan         # Run scan now
nftban tunnel top          # Show top suspects by score
nftban tunnel explain IP   # Signal breakdown for an IP
nftban tunnel config       # Show configuration
```

> **Advisory-only** — the tunnel module scores DNS traffic for tunnel indicators but never bans or blocks. Enforcement is planned for a future release.

See [CLI Commands Reference](https://github.com/itcmsgr/nftban/wiki/CLI-Commands-Reference) for complete documentation.

---

## Architecture

```
ip nftban {                  # IPv4 rules
    set whitelist_ipv4 {...}   # Protected IPs (never blocked)
    set blacklist_ipv4 {...}   # Unified blocklist (all sources)
    set tcp_ports_in {...}     # Inbound TCP ports
    set udp_ports_in {...}     # Inbound UDP ports
    chain input {...}
    chain forward {...}
}

ip6 nftban {                 # IPv6 rules
    set whitelist_ipv6 {...}   # Protected IPs (never blocked)
    set blacklist_ipv6 {...}   # Unified blocklist (all sources)
    chain input {...}
    chain forward {...}
}
```

> **v1.18 Unified Blacklist**: All ban sources (feeds, geoban, login, ddos, portscan, manual) route to single `blacklist_ipv4/ipv6` set. Source tracking maintained in daemon database.

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

NFTBan follows **defense-in-depth** security practices with **12 automated security tools** across our CI/CD pipeline.

### Security Certifications & Compliance

| Certification | Status | Badge |
|--------------|--------|-------|
| **OpenSSF Scorecard** | 7+ / 10 | [![OpenSSF Scorecard](https://img.shields.io/ossf-scorecard/github.com/itcmsgr/nftban)](https://securityscorecards.dev/viewer/?uri=github.com/itcmsgr/nftban) |
| **OpenSSF Best Practices** | Passing | [![CII Best Practices](https://www.bestpractices.dev/projects/11959/badge)](https://www.bestpractices.dev/projects/11959) |
| **SLSA Level 3** | Provenance | [![SLSA 3](https://slsa.dev/images/gh-badge-level3.svg)](https://slsa.dev) |
| **SBOM** | Every Release | SPDX-JSON format |

### Automated Security Pipeline

<table>
<tr><th>Category</th><th>Tool</th><th>Purpose</th><th>Frequency</th></tr>
<tr><td rowspan="4"><b>SAST</b></td><td>CodeQL</td><td>Semantic code analysis for Go</td><td>Every PR + Push</td></tr>
<tr><td>Semgrep</td><td>Pattern-based security rules (Go + Shell)</td><td>Every PR + Push</td></tr>
<tr><td>gosec</td><td>Go-specific security linting</td><td>Every PR + Push</td></tr>
<tr><td>ShellCheck</td><td>Shell script security analysis</td><td>Every PR + Push</td></tr>
<tr><td rowspan="3"><b>SCA</b></td><td>govulncheck</td><td>Go module vulnerability scanning</td><td>Every PR + Push</td></tr>
<tr><td>OSV-Scanner</td><td>Google OSV database scanning</td><td>Every PR + Weekly</td></tr>
<tr><td>Trivy</td><td>Container & dependency CVE scanning</td><td>Every PR + Push</td></tr>
<tr><td rowspan="2"><b>Secrets</b></td><td>gitleaks</td><td>Secret detection in commits</td><td>Every PR + Push</td></tr>
<tr><td>GitHub Secret Scanning</td><td>Known secret pattern detection</td><td>Continuous</td></tr>
<tr><td rowspan="2"><b>Supply Chain</b></td><td>SLSA Provenance</td><td>Cryptographic build attestation</td><td>Every Release</td></tr>
<tr><td>Dependency Review</td><td>PR-level dependency diff analysis</td><td>Every PR</td></tr>
<tr><td><b>Fuzzing</b></td><td>go-fuzz</td><td>Automated fuzz testing</td><td>Nightly</td></tr>
</table>

### Supply Chain Security

```
Source → Build → Attest → Release → Verify
   ↓       ↓        ↓         ↓        ↓
  Git   Hermetic  SLSA L3   SBOM    sigstore
```

- **SLSA Level 3**: Hermetic builds with non-forgeable provenance
- **SBOM**: Full Software Bill of Materials (SPDX-JSON) for every release
- **Signed Releases**: GPG-signed tags and artifacts
- **Pinned Dependencies**: All GitHub Actions pinned to SHAs

### Security Dashboards

| Dashboard | Description |
|-----------|-------------|
| [Security Overview](https://github.com/itcmsgr/nftban/security) | All security features |
| [Code Scanning](https://github.com/itcmsgr/nftban/security/code-scanning) | SAST results (CodeQL, Semgrep, gosec, ShellCheck) |
| [Dependabot](https://github.com/itcmsgr/nftban/security/dependabot) | Dependency CVE alerts |
| [Secret Scanning](https://github.com/itcmsgr/nftban/security/secret-scanning) | Exposed credential detection |
| [OpenSSF Scorecard](https://securityscorecards.dev/viewer/?uri=github.com/itcmsgr/nftban) | Security health score (7+/10) |
| [Workflow Status](https://github.com/itcmsgr/nftban/actions) | CI/CD pipeline status |

### Vulnerability Disclosure

We follow **coordinated disclosure** with a 90-day fix window. Report vulnerabilities to:
- **Email**: security@nftban.com
- **GitHub Security Advisories**: [Report a vulnerability](https://github.com/itcmsgr/nftban/security/advisories/new)

See [SECURITY.md](SECURITY.md) for complete security policy, threat model, and architecture.

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
