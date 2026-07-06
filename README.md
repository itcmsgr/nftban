# NFTBan

**Linux Intrusion Prevention System & nftables Firewall Manager**

[![Version](https://img.shields.io/github/v/tag/itcmsgr/nftban?label=version&sort=semver&color=blue)](https://github.com/itcmsgr/nftban/releases)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL%202.0-brightgreen.svg)](https://opensource.org/licenses/MPL-2.0)
[![Go](https://img.shields.io/badge/Go-1.25-00ADD8.svg)](https://go.dev/)
[![FHS Compliant](https://img.shields.io/badge/FHS-Compliant-success)]()

### CI/CD Status

[![Shell Quality](https://github.com/itcmsgr/nftban/actions/workflows/ci-bash.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-bash.yml)
[![Go Quality](https://github.com/itcmsgr/nftban/actions/workflows/ci-go.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-go.yml)
[![Architecture](https://github.com/itcmsgr/nftban/actions/workflows/ci-architecture.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-architecture.yml)
[![Build Packages](https://github.com/itcmsgr/nftban/actions/workflows/build-packages.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/build-packages.yml)
[![Release](https://github.com/itcmsgr/nftban/actions/workflows/release.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/release.yml)

### Security & Supply Chain

[![SLSA 3](https://slsa.dev/images/gh-badge-level3.svg)](https://slsa.dev)
[![OpenSSF Scorecard](https://img.shields.io/ossf-scorecard/github.com/itcmsgr/nftban?label=OpenSSF%20Scorecard)](https://securityscorecards.dev/viewer/?uri=github.com/itcmsgr/nftban)
[![OpenSSF Best Practices](https://www.bestpractices.dev/projects/11959/badge)](https://www.bestpractices.dev/projects/11959)
[![CodeQL](https://github.com/itcmsgr/nftban/actions/workflows/codeql.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/codeql.yml)
[![OSV-Scanner](https://github.com/itcmsgr/nftban/actions/workflows/osv-scanner.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/osv-scanner.yml)
[![gitleaks](https://github.com/itcmsgr/nftban/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/gitleaks.yml)

---

NFTBan is an open-source Linux Intrusion Prevention System (IPS) and firewall
manager built on nftables, designed to integrate cleanly with modern Linux
security stacks.

All packet decisions (accept, drop, bypass) are enforced in the nftables kernel.
The Go daemon writes to kernel sets. The Go validator derives health from kernel
state. The CLI presents kernel-derived truth.

### What NFTBan Provides

- nftables-native enforcement with kernel-managed timeouts
- Threat feed ingestion with CIDR aggregation
- Country blocking via GeoIP (DB-IP Lite default)
- Login brute-force detection across SSH, mail, FTP, panel services
- Port scan detection (classic + Suricata modes)
- L3/L4 rate limiting and connection limits
- Set-driven SSH brute-force connection-rate-limit (`tcp dport @ssh_ports ct count`) — follows every detected sshd listener port across IPv4/IPv6
- HTTP bot classification with 6 dedicated kernel sets
- Optional Suricata DPI integration (EVE JSON)
- 4-axis health model with kernel-derived truth validator
- Atomic nftables schema rebuild (validate before load)
- 5-phase installer with emergency SSH table

---

## Truth Authority

| Priority | Component | Role |
|---|---|---|
| 1 | **Kernel** (`nft list ruleset`) | What is actually enforcing |
| 2 | **Validator** (`nftban-validate`) | Derives health from kernel evidence |
| 3 | **CLI** (`nftban`) | Presents validator output to operator |
| 4 | **Config** (`/etc/nftban/`) | Operator intent (not runtime truth) |

When sources disagree, kernel wins.

---

## Evidence Model

NFTBan derives protection state from kernel-observable evidence:

| Evidence | Meaning | Strength |
|---|---|---|
| Counter > 0 | Packet processing observed | Strong |
| Set membership > 0 | State present in kernel | Strong |
| Structure exists | Rules/chains present | Weak (presence only) |
| Journal event | External event (daemon/logs) | Context-dependent |

Interpretation rules:

- Counter > 0 = positive evidence of enforcement
- Counter = 0 = neutral (not a failure)
- Structure alone does not imply enforcement
- Absence of evidence is not evidence of absence

---

## Protection Modules

| Module | Layer | Evidence | Daemon |
|---|---|---|---|
| **DDoS Protection** | L3/L4 | 5 dedicated kernel counters | NO |
| **BotGuard** | L7 HTTP | 6 dedicated kernel sets | YES |
| **Portscan Detection** | L3/L4 | Structure only (no counter) | NO |
| **Login Monitoring** | L2 Auth | Journal + shared sets | YES |
| **Blacklist & Feeds** | L1 IP | Shared sets + counters | Partial |
| **Suricata IDS** | L7 DPI | EVE JSON (external) | YES |
| **DNS Tunnel** | Advisory | DNS analysis (non-blocking) | YES |

---

## Quick Install

> All tiers below are built, released, and install-tested in CI every release. Tiers reflect **recommendation/age**, not support level: **Tier 0** = primary/recommended · **Tier 1** = newer releases · **Tier 2** = older LTS still supported.

### Tier 0 — Primary Platforms

#### Ubuntu 24.04 LTS (Noble)
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-ubuntu24.04-amd64.deb
sudo apt install -y ./nftban-ubuntu24.04-amd64.deb
```

#### Ubuntu 26.04 LTS (Resolute Raccoon)
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-ubuntu26.04-amd64.deb
sudo apt install -y ./nftban-ubuntu26.04-amd64.deb
```

#### Debian 12 (Bookworm)
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-debian12-amd64.deb
sudo apt install -y ./nftban-debian12-amd64.deb
```

#### Rocky / AlmaLinux / RHEL 9
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-el9-x86_64.rpm
sudo dnf install -y ./nftban-el9-x86_64.rpm
```

### Tier 1 — Newer Platforms

#### Debian 13 (Trixie)
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-debian13-amd64.deb
sudo apt install -y ./nftban-debian13-amd64.deb
```

#### Rocky / AlmaLinux / RHEL 10
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-el10-x86_64.rpm
sudo dnf install -y ./nftban-el10-x86_64.rpm
```

### Tier 2 — Legacy Platforms

#### Ubuntu 22.04 LTS (Jammy)
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-ubuntu22.04-amd64.deb
sudo apt install -y ./nftban-ubuntu22.04-amd64.deb
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
| 0 | Ubuntu | 26.04 (Resolute Raccoon) | [nftban-ubuntu26.04-amd64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-ubuntu26.04-amd64.deb) |
| 0 | Debian | 12 (Bookworm) | [nftban-debian12-amd64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-debian12-amd64.deb) |
| 1 | Debian | 13 (Trixie) | [nftban-debian13-amd64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-debian13-amd64.deb) |
| 2 | Ubuntu | 22.04 (Jammy) | [nftban-ubuntu22.04-amd64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-ubuntu22.04-amd64.deb) |

> Packages are distro-specific and FHS compliant. Use the package matching your exact distribution version. See [Supported Platforms](https://github.com/itcmsgr/nftban/wiki/Supported-Platforms) for the full platform contract.

---

## Quick Start

```bash
# Check system health (kernel-derived truth)
nftban health

# Check validator output directly
nftban-validate --json

# SAFETY FIRST — whitelist your management/SSH IP before enabling enforcement,
# so a detection rule can never lock you out of your own host:
nftban whitelist add YOUR.MANAGEMENT.IP        # your admin/SSH source IP
nftban check YOUR.MANAGEMENT.IP                # confirm it is whitelisted, not banned

# Enable modules (only after your admin IP is whitelisted)
nftban ddos enable
nftban portscan enable
nftban botguard enable
nftban login enable
nftban geoban enable

# Common operations
nftban ban 1.2.3.4                       # permanent ban
nftban ban 1.2.3.4 --timeout 3600        # 1-hour ban (positive integer seconds)
nftban unban 1.2.3.4
nftban status
```

`--timeout` requires a positive integer (seconds) — non-integer / negative /
zero / fractional / signed / hex / leading-zero values are rejected at parse
time with a clear ERROR (since v1.141.0). Omit `--timeout` for a permanent ban.

---

## Health States

| State | Meaning | Exit |
|---|---|---|
| **PROTECTED** | All axes pass, system capable of enforcement | 0 |
| **IDLE** | All axes pass, no relevant traffic | 0 |
| **DEGRADED** | One or more axes fail | 1 |
| **DOWN** | Critical failure | 2 |

```bash
nftban health           # 4-axis truth table
nftban-validate --json  # full validator output
```

---

## Validator Scope

The validator is kernel-first and derives truth from observable evidence.
Kernel-resident evidence (counters, sets, chains) is authoritative for
enforcement state. Some module-specific runtime evidence may come from
bounded daemon or journal observations where defined by the module contract.

Current scope boundaries:

- Portscan: no dedicated kernel counter — enforcement cannot be proven
- LoginMon: journal-based evidence — may enforce while validator reports IDLE
- Blacklist: shared counters — per-source attribution not possible from kernel

The validator reports observable truth, not complete system behavior.

---

## Architecture

```
Kernel (nftables)     ← packet decisions enforced here
  ↑ reads
Go validator          ← derives health state
  ↑ reads
CLI (nftban)          ← presents to operator
  ↑ reads
Config (/etc/nftban/) ← operator intent
```

| Component | Type | Purpose |
|---|---|---|
| `nftban` | Shell CLI | Operator interface, schema generation |
| `nftband` | Go daemon | Ban execution, loginmon, BotGuard scoring |
| `nftban-validate` | Go binary | Read-only kernel truth validator (~1ms) |

---

## Core Invariants

The following rules define NFTBan behavior:

1. Kernel is the only enforcement authority
2. Validator derives truth from kernel state
3. CLI presents validator output only
4. Configuration expresses intent, not runtime state
5. Shared evidence cannot be used for attribution

These invariants are enforced by validation logic and CI gates.

---

## Metrics and Observability

The daemon exposes runtime metrics on `http://127.0.0.1:9580/metrics`
(localhost only, Prometheus text exposition format). This is the canonical
runtime metrics surface. As of v1.89, the evidence layer reads all kernel
data from the validator — no duplicate nft queries.

The watchdog subsystem provides adaptive resource control. It monitors
process, Go runtime, and kernel metrics, and adjusts operating mode
(NORMAL → DEGRADED → SURVIVAL) based on memory and CPU pressure.
Server profile detection (Small/Medium/Large) automatically tunes memory
budgets and CIDR limits based on available RAM.

---

## Go Module Notice

NFTBan is a **system-level firewall product**, not a general-purpose Go library.

### Supported Public Packages

| Package | Purpose |
|---|---|
| [`pkg/ipc`](https://pkg.go.dev/github.com/itcmsgr/nftban/pkg/ipc) | IPC client for daemon communication |
| [`pkg/version`](https://pkg.go.dev/github.com/itcmsgr/nftban/pkg/version) | Version information |

All packages under `internal/` are implementation details.

---

## Requirements

- **Linux**: Rocky / Alma / RHEL 9–10, Ubuntu 22.04 / 24.04 / **26.04 LTS (Resolute Raccoon)**, Debian 12 / 13
- **nftables**: 1.0+
- **Bash**: 4.4+
- **systemd**: 252+
- **jq**: JSON processor
- **Go 1.24+**: For building from source (optional)

Ubuntu 26.04 LTS is **Tier-0 (fully supported)** since v1.140.0 — see the
[Quick Install — Tier 0](#tier-0--primary-platforms) section and the
[DEB Packages](#deb-packages-ubuntu--debian) table for the install snippet
and `.deb` URL.

---

## Security

SLSA Level 3 provenance, 9 automated security tools (CodeQL, OSV-Scanner,
gitleaks, Trivy, gosec, ShellCheck, Semgrep, Fuzz, Dependency Review),
SBOM with every release, all GitHub Actions SHA-pinned.

See [SECURITY.md](SECURITY.md) for vulnerability reporting and full pipeline details.

---

## Documentation

| Section | Link |
|---|---|
| **Wiki Home** | [Complete documentation](https://github.com/itcmsgr/nftban/wiki) |
| **Architecture** | [System design + truth model](https://github.com/itcmsgr/nftban/wiki/Architecture-Overview) |
| **Health Model** | [4-axis derivation](https://github.com/itcmsgr/nftban/wiki/Health-Model) |
| **CLI Reference** | [All commands + trust levels](https://github.com/itcmsgr/nftban/wiki/CLI-Commands-Reference) |
| **Glossary** | [Canonical terminology](https://github.com/itcmsgr/nftban/wiki/Glossary-and-Vocabulary) |
| **Known Limitations** | [Validator scope per module](https://github.com/itcmsgr/nftban/wiki/Known-Limitations-and-Validation-Scope) |
| **Installation** | [Install guide](https://github.com/itcmsgr/nftban/wiki/Installation-Guide) |

---

## License

NFTBan Core is licensed under the **Mozilla Public License 2.0 (MPL-2.0)**.

Copyright (c) 2024-2026 NFTBan Project / Antonios Voulvoulis

MPL-2.0 is file-level copyleft: you may use, modify, and distribute freely.
Modified MPL files must remain open. Your own separate code is unaffected.

| Layer | License |
|---|---|
| Core engine | MPL-2.0 |
| Pro portal | Commercial |
| Brand assets | All rights reserved |

See [LICENSE](LICENSE) for full text. "NFTBan" is a trademark — forks must use
a different name. See [TRADEMARK.md](TRADEMARK.md).

---

<p align="center">
  <b>NFTBan — Linux IPS & nftables Firewall Manager</b><br>
  <a href="https://nftban.com">nftban.com</a> |
  <a href="https://github.com/itcmsgr/nftban/issues">Report Issue</a> |
  <a href="https://github.com/itcmsgr/nftban/discussions">Discussions</a>
</p>
