# 🛡️ NFTBan — Adaptive Firewall for the Modern Linux Stack

> **Secure by Design  |  Zero Trust Ready  |  AI‑Assisted Defense**

[![Version](https://img.shields.io/badge/version-0.32.3-brightgreen)](https://github.com/itcmsgr/nftban)
[![License: MPL 2.0](https://img.shields.io/badge/License-MPL%202.0-blue.svg)](https://opensource.org/licenses/MPL-2.0)
[![Code: 80%+ Shell](https://img.shields.io/badge/Code-80%25%20Shell-brightgreen)]()
[![Performance: Go Binaries](https://img.shields.io/badge/Performance-Go%20Binaries-00ADD8)]()
[![Security: Polkit](https://img.shields.io/badge/Security-Polkit%20Integrated-red)]()
[![FHS: Compliant](https://img.shields.io/badge/FHS-21%2F21%20Compliant-success)]()
[![Status](https://img.shields.io/badge/status-BETA%20TESTING-orange)]()

NFTBan is an **enterprise‑grade firewall management system** built on Linux *nftables* — combining
**atomic rule updates, privilege separation through Polkit**, and **AI‑assisted threat intelligence**
for a resilient, self‑healing network defense layer.

> ⚠️ **BETA TESTING** | We are actively finding and fixing bugs. NOT production-ready yet.
> Tested on 5 lab servers. **Community feedback needed** from diverse environments. [Report issues here](https://github.com/itcmsgr/nftban/issues).

---

## 👤 About the Project

**NFTBan** is founded and architected by **Antonios Voulvoulis**, open‑source contributor and cybersecurity architect, through an **AI‑assisted but human‑supervised development workflow**.

The project embraces an **ethical AI collaboration philosophy** — merging **human creativity, accountability, and system‑design expertise** with **AI precision and scalability** to accelerate open‑source cybersecurity innovation.

> All AI‑generated content is human‑reviewed, version‑controlled, and transparently attributed in Git history.
> NFTBan aligns with open standards encouraged by **OpenSSF** and the **Linux Foundation**.

---

## 🚀 Quick Install

**Rocky / AlmaLinux 9+** (requires EPEL + CRB)
```bash
# Enable repositories first
sudo dnf install -y epel-release
sudo dnf config-manager --set-enabled crb

# Install NFTBan
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-x86_64.rpm
sudo dnf install -y nftban-x86_64.rpm
sudo nftban setup
```

**Fedora** (all repos included)
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-x86_64.rpm
sudo dnf install -y nftban-x86_64.rpm
sudo nftban setup
```

**Ubuntu / Debian**
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-amd64.deb
sudo dpkg -i nftban-amd64.deb && sudo nftban setup
```

---

## 📦 Available Architectures

| Platform | Architecture | Package |
|-----------|--------------|----------|
| 🐧 RHEL / Rocky / Alma / Fedora | x86_64 | [nftban-x86_64.rpm](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-x86_64.rpm) |
| 🐧 RHEL / Rocky / Alma / Fedora | aarch64 (ARM64) | [nftban-aarch64.rpm](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-aarch64.rpm) |
| 🐧 Ubuntu 24.04+ / Debian 12+ | amd64 | [nftban-amd64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-amd64.deb) |
| 🐧 Ubuntu 24.04+ / Debian 12+ | arm64 | [nftban-arm64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-arm64.deb) |

> **Note:** Packages are self-contained and verified for FHS compliance. Old versions are archived in [Releases](https://github.com/itcmsgr/nftban/releases).

---

## 🌐 Overview

NFTBan simplifies Linux firewall management without sacrificing depth or safety.
It empowers teams to deploy **Zero‑Trust‑aligned**, **FHS‑compliant**, and **auditable** firewall
infrastructures in minutes.

**Key Design Pillars**
- 🔐 Secure by Design — Least privilege, no sudo needed
- ⚙️ Atomic Operations — Zero packet loss on rule reloads
- 🧠 AI Assistance — Adaptive threat feeds and automated healing
- 🧩 Modular Architecture — Two‑table nftables design for runtime stability
- 🧾 Compliance Built‑In — 21/21 FHS validation and continuous self‑audit

---

## 🔒 Core Capabilities

| Domain | Capability | Description |
|--------|-------------|-------------|
| **Security** | Polkit integration | True privilege separation for CLI and system tasks |
| **Protection** | Whitelist‑first logic | Prevents self‑lockouts and enforces safety layering |
| **Performance** | Go binaries | 10–60× faster feed and GeoIP processing |
| **Reliability** | Auto‑heal system | Periodic integrity checks and file‑system repair |
| **Visibility** | Audit logging | Every action attributed, verifiable, and reversible |

> NFTBan's design philosophy: *Security is a process — automation should reinforce, not replace, human judgment.*

---

## 🧠 Architecture at a Glance

```
┌───────────────────────────────┐
│  inet nftban_runtime          │  ← Temporary bans / Fail2ban integration
│  • Persistent across reloads  │
└───────────────────────────────┘
            ↓
┌───────────────────────────────┐
│  inet nftban_main             │  ← Permanent rules, atomic updates
│  • Whitelist + Blacklist sets │
│  • Port policy definitions    │
└───────────────────────────────┘
```

**Highlights**
- Runtime bans survive reloads (no service restarts)
- Atomic commits prevent partial rule failure
- Blacklist evaluated before port allow‑lists
- Full drop‑by‑default policy with explicit trust exceptions

---

## ⚡ Quick Start

```bash
sudo nftban setup          # Interactive guided configuration
sudo nftban status         # View system status
sudo nftban health check   # Run diagnostics and auto‑heal
```

Common tasks:
```bash
nftban ban 1.2.3.4          # Block IP (safe ban)
nftban unban 1.2.3.4        # Remove ban
nftban firewall reload      # Atomic reload (no downtime)
```

---

## 🧩 Why NFTBan Matters

Traditional firewalls either **favor convenience over safety** or require expert‑level
configuration. NFTBan aims to merge both worlds — a platform where **any administrator can operate safely**
and **engineers retain fine‑grained control**.

**Current Features (Beta):**
- 🔧 Zero Trust Privilege Model with Polkit (testing in progress)
- 🔧 Automatic self‑healing for critical paths (under development)
- 🔧 AI‑curated threat feeds and GeoIP filtering (bugs being fixed)
- ✅ Compliant with Linux Foundation FHS standards
- 🔧 Optimized for automation, monitoring, and CI/CD pipelines (in progress)

> **We're finding and fixing bugs daily.** Your testing and feedback are critical for production readiness.

---

## 🤖 AI-Assisted Development

NFTBan is developed through **ethical AI collaboration** that unites human creativity and machine precision under transparent governance.

**Development Partners**
| Partner | Role |
|----------|------|
| 🤝 **ChatGPT (OpenAI)** | Architecture & Design Planning |
| ⚙️ **Claude Code (Anthropic)** | Implementation & Testing |
| 🧠 **Claude AI (Anthropic)** | Review & Optimization |

> All AI-generated code and text are **human-reviewed, version-controlled**, and fully attributed in Git history.
> This project aligns with ethical collaboration standards promoted by **OpenSSF** and **Linux Foundation** initiatives.

---

## 📜 License & Trademark

**License:** [Mozilla Public License 2.0 (MPL‑2.0)](LICENSE)
**Copyright © 2024–2026 NFTBan Project / Antonios Voulvoulis**
**Trademark:** "NFTBAN" and logo are registered marks of Antonios Voulvoulis.
Free for personal & commercial use under MPL‑2.0 terms.

---

## 🤝 Contributing

We welcome thoughtful contributions from both human and AI‑assisted developers.

```bash
git clone https://github.com/itcmsgr/nftban.git
git checkout -b feature/<name>
# build, test, and commit with signed‑off‑by lines
```

Read [CONTRIBUTING.md](CONTRIBUTING.md) for details.

---

<p align="center">
  <b>Empowering system administrators with simple, auditable, intelligent security.</b><br>
  <a href="https://nftban.com">🌐 nftban.com</a> • <a href="https://github.com/itcmsgr/nftban/issues">🐛 Report Issue</a>
</p>
