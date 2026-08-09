# NFTBan

**Linux Intrusion Prevention System & nftables Firewall Manager**

[![Version](https://img.shields.io/github/v/tag/itcmsgr/nftban?label=version&sort=semver&color=blue)](https://github.com/itcmsgr/nftban/releases)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL%202.0-brightgreen.svg)](https://opensource.org/licenses/MPL-2.0)
[![Build: Go 1.25](https://img.shields.io/badge/Build-Go%201.25-00ADD8.svg)](https://go.dev/)
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

All firewall packet decisions — accept, drop, and policy bypass — are enforced
by nftables in the kernel. NFTBan's controlled daemon and synchronization paths
update the kernel sets they own, while kernel-native rules and meters enforce
traffic policy directly. Observe-only and advisory modules produce findings
without modifying packet enforcement. Health and enforcement-status surfaces
derive their authoritative verdict from kernel and validator evidence.

### What NFTBan Provides

- nftables-native enforcement with kernel-managed timeouts
- Threat feed ingestion with CIDR aggregation
- Country blocking via GeoIP (DB-IP Lite default)
- Login brute-force detection across SSH, mail, FTP, panel services
- Port scan detection (classic + Suricata modes)
- Network and transport-layer rate limiting and connection limits
- Set-driven SSH brute-force connection-rate-limit (`tcp dport @ssh_ports ct count`) — follows every detected sshd listener port across IPv4/IPv6
- HTTP bot classification (BotGuard) using dedicated nftables HTTP signal sets
- Malicious-HTTP / exploit-probe scanning (BotScan) with durable ban-evidence handoff to the daemon
- Server public IPv4/IPv6 reputation monitoring via DNSBL/RBL checks, with explicit degraded-coverage reporting — observe-only and non-enforcing
- Optional Suricata DPI integration (EVE JSON)
- 4-axis health model with kernel-derived truth validator
- Atomic nftables schema rebuild (validate before load)
- Structured transactional installer with emergency SSH protection and per-run forensic logging

---

## Truth Authority

| Priority | Component | Role |
|---|---|---|
| 1 | **Kernel** (`nft list ruleset`) | What is actually enforcing |
| 2 | **Validator** (`nftban validate`) | Derives health from kernel evidence |
| 3 | **CLI** (`nftban`) | Health/enforcement-status surfaces present validator-derived truth; other commands manage operator intent and invoke controlled operations |
| 4 | **Config** (`/etc/nftban/`) | Operator intent (not runtime truth) |

When sources disagree on enforcement truth, kernel wins.

---

## Evidence Model

NFTBan derives protection state from kernel-observable evidence. What each
evidence type actually proves:

| Evidence | What it proves |
|---|---|
| Referenced set membership | Enforcement state exists for a rule-linked set |
| Dedicated rule counter increment | Traffic reached that specific enforcement path |
| Shared counter increment | Enforcement occurred, but producer attribution may be unavailable |
| Structure only | Capability is installed, not necessarily active |
| Journal / daemon evidence | Module activity per that module's bounded evidence contract |

Interpretation rules:

- A counter > 0 proves rule traversal; a **shared** counter cannot prove which module caused it.
- Counter = 0 = neutral (not a failure).
- Set membership proves state exists, not that the set is rule-linked, correctly ordered, reachable, or attributable to a specific module.
- Absence of evidence is not evidence of absence.

---

## Protection and Security-Monitoring Modules

| Module | Protects or Monitors | Signal Source | Operation |
|---|---|---|---|
| **DDoS Protection** | Network and transport-layer floods | nftables meters and counters | Kernel-enforced; daemon provides runtime management/telemetry where applicable |
| **BotGuard** (HTTP Guard) | HTTP abuse and connection attacks | nftables HTTP signals | Go daemon with centralized enforcement |
| **BotScan** (HTTP Exploit Scanner) | Malicious HTTP requests and exploit probes | Web access logs | Scheduled scanner + daemon consumer (centralized enforcement) |
| **Portscan Detection** | Reconnaissance and connection scanning | Connection-pattern analysis | Go daemon module + centralized enforcement |
| **Login Monitoring** | Brute-force and authentication abuse | Journald, service logs, panel logs, web-auth logs, Suricata | Go daemon detection + centralized enforcement (legacy shell path in-tree, not deployed) |
| **Blacklist & Threat Feeds** | Known hostile addresses | Manual entries and external intelligence feeds | Centrally synchronized enforcement |
| **Suricata Integration** | IDS-detected network threats | Suricata EVE JSON (external IDS) | External IDS producer + NFTBan processing |
| **RBL Monitoring** | Server-IP reputation and mail-delivery blocklisting risk | Public IPv4/IPv6 DNSBL checks | Scheduled and on-demand; observe-only; alerts and reports (no bans, no nftables writes) |
| **DNS Tunnel Detection** | Suspicious DNS behavior | DNS-query analysis | Advisory and non-blocking |

See the [Architecture Overview](https://github.com/itcmsgr/nftban/wiki/Architecture-Overview)
for the full protection-domain / evidence / runtime taxonomy.

---

## Quick Install

> Packages for all listed targets are built and released through CI. Package-native
> installation is validated on representative DEB and RPM platforms before fleet
> rollout. Tiers reflect **recommendation/age**, not support level: **Tier 0** =
> primary/recommended · **Tier 1** = newer releases · **Tier 2** = older supported LTS.

### Tier 0 — Primary Platforms

#### Ubuntu 24.04 LTS (Noble)
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-ubuntu24.04-amd64.deb
sudo apt install -y ./nftban-ubuntu24.04-amd64.deb
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

#### Ubuntu 26.04 LTS (Resolute Raccoon)
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-ubuntu26.04-amd64.deb
sudo apt install -y ./nftban-ubuntu26.04-amd64.deb
```

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

### Tier 2 — Older Supported LTS Platforms

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
| 0 | Debian | 12 (Bookworm) | [nftban-debian12-amd64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-debian12-amd64.deb) |
| 1 | Ubuntu | 26.04 (Resolute Raccoon) | [nftban-ubuntu26.04-amd64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-ubuntu26.04-amd64.deb) |
| 1 | Debian | 13 (Trixie) | [nftban-debian13-amd64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-debian13-amd64.deb) |
| 2 | Ubuntu | 22.04 (Jammy) | [nftban-ubuntu22.04-amd64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-ubuntu22.04-amd64.deb) |

> Packages are distro-specific and FHS compliant. Use the package matching your exact distribution version. See [Supported Platforms](https://github.com/itcmsgr/nftban/wiki/Supported-Platforms) for the full platform contract.

---

## Quick Start

```bash
# 1. Review readiness and current configuration first
nftban health                                  # 4-axis kernel-derived truth
nftban validate                                # validator verdict

# 2. SAFETY FIRST — whitelist your management/SSH IP before enabling enforcement,
#    so a detection rule can never lock you out of your own host:
nftban whitelist add YOUR.MANAGEMENT.IP        # your admin/SSH source IP
nftban check YOUR.MANAGEMENT.IP                # confirm it is whitelisted, not banned

# 3. Enable only the modules appropriate for this host
nftban ddos enable
nftban portscan enable
nftban login enable

# 4. Optional, policy-dependent modules (review before enabling)
nftban botguard enable                         # HTTP abuse protection
nftban geoban enable                           # country blocking — operator policy decision

# Observe-only server-IP reputation check; does NOT modify nftables and issues no bans
nftban rbl server check

# Common operations
nftban ban 1.2.3.4                             # permanent ban
nftban ban 1.2.3.4 --timeout 3600             # 1-hour ban (positive integer seconds)
nftban unban 1.2.3.4
nftban status
```

`--timeout` requires a positive integer (seconds) — non-integer / negative /
zero / fractional / signed / hex / leading-zero values are rejected at parse
time with a clear ERROR (since v1.141.0). Omit `--timeout` for a permanent ban.
Whitelist both IPv4 and IPv6 management addresses where applicable.

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
nftban validate --json  # full validator output
```

---

## Validator Scope

The validator is kernel-first and derives truth from observable evidence.
Kernel-resident evidence (counters, sets, chains) is authoritative for
enforcement state. Some module-specific runtime evidence may come from
bounded daemon or journal observations where defined by the module contract.

Current scope boundaries:

- **Portscan:** detection runs as a Go daemon module; kernel-attributable enforcement evidence is limited, so validator visibility is bounded by the module contract.
- **Login Monitoring:** combines kernel, daemon, source-visibility, and bounded journal evidence. Quiet traffic and unavailable input sources are distinguished according to the current health contract.
- **Blacklist:** shared counters — per-source attribution is not possible from the kernel alone.

The validator reports observable truth, not complete system behavior.

---

## Architecture

```
Kernel (nftables)     ← packet decisions enforced here
  ↑ reads
Go validator          ← derives health state
  ↑ reads
CLI (nftban)          ← health surfaces present validator truth; also drives operations
  ↑ reads
Config (/etc/nftban/) ← operator intent
```

| Component | Type | Purpose |
|---|---|---|
| `nftban` | Shell CLI | Operator interface, configuration management, diagnostics, scheduled workflows, and controlled lifecycle operations |
| `nftband` | Go daemon | Centralized ban execution, detector event processing, evidence consumption (incl. BotScan signals), set synchronization/reconciliation, and runtime module services |
| `nftban validate` | Go binary (impl: `/usr/lib/nftban/bin/nftban-validate`) | Read-only kernel truth validator (~1ms) |

---

## Core Invariants

The following rules define NFTBan behavior:

1. Kernel is the only enforcement authority
2. Validator derives truth from kernel state
3. Health and enforcement-status surfaces derive their authoritative verdict from kernel and validator evidence; other CLI commands manage operator intent and invoke controlled operations
4. Configuration expresses intent, not runtime state
5. Shared evidence cannot be used for attribution

These invariants are enforced by validation logic and CI gates.

---

## Metrics and Observability

The daemon serves runtime metrics at `http://127.0.0.1:9580/metrics`
(the `/metrics` endpoint is loopback-restricted; Prometheus text exposition
format). This is the canonical runtime metrics surface. Note that the daemon's
`:9580` listener binds all interfaces and its `/health` and `/api/v1/*`
endpoints are not loopback-restricted — firewall `:9580` to trusted sources.
Validator-backed health surfaces use the validator as their canonical
kernel-evidence source, reducing duplicate nftables inspection.

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

- **Linux**: Rocky / Alma / RHEL 9–10, Ubuntu 22.04 / 24.04 / 26.04 LTS (Resolute Raccoon), Debian 12 / 13
- **nftables**: 1.0+
- **Bash**: 4.4+
- **systemd**: 252+
- **jq**: JSON processor
- **Go 1.25+**: For building from source (optional; matches the `go.mod` toolchain)

Ubuntu 26.04 LTS (Resolute Raccoon) is a **Tier 1** target — released, packaged,
and installable — see the [Quick Install — Tier 1](#tier-1--newer-platforms)
section and the [DEB Packages](#deb-packages-ubuntu--debian) table for the
install snippet and `.deb` URL. Tier 0 remains the primary/recommended baseline
(Ubuntu 24.04, Debian 12, EL9).

---

## Security

**SLSA Level 3 provenance for the standalone `nftban-core` release binary** (other
release assets — `nftband` and the complete DEB/RPM packages — are checksum-verified
via `SHA256SUMS`, not covered by that provenance). Plus automated security checks —
CodeQL, OSV-Scanner, gitleaks, Trivy, gosec, ShellCheck, Semgrep, fuzzing, and
Dependency Review — with an SBOM on every release and all GitHub Actions SHA-pinned.

**Reporting is split by process (shared `security@nftban.com` mailbox):** security
**vulnerabilities** → the private process in [SECURITY.md](SECURITY.md) (GitHub private
Security Advisory preferred; email fallback `security@nftban.com` with a `[SECURITY]`
subject prefix — **never a public issue**). Community/**conduct** reports →
`security@nftban.com` per the [Code of Conduct](.github/CODE_OF_CONDUCT.md).

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

Copyright (c) 2024-2026 Antonios Voulvoulis

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
