# Security Policy

## Integrity & Build Verification

NFTBan enforces security through a kernel-first validation model and automated
CI/CD pipelines.

→ **Full audit surface:** [Integrity & Build Status (STATUS.md)](STATUS.md)

This includes:
- CI pipeline results (build, security, compliance)
- Contract gate enforcement
- Supply chain verification (SLSA Level 3)
- Runtime verification commands

This page describes vulnerability reporting and security policy.
STATUS.md provides machine-verifiable system integrity.

---

## About NFTBan

NFTBan is an open-source Linux Intrusion Prevention System (IPS) and firewall manager built on nftables. Security is foundational to the architecture, featuring capability-based privilege separation, systemd sandboxing, Unix socket IPC, and strict input validation at all layers.

---

## Supported Versions

| Version | Support Status |
|---------|----------------|
| 1.61.x  | **Current** - Full support (security fixes, bug fixes, features) |
| 1.60.x  | Security fixes only |
| < 1.59  | **Not supported** - upgrade immediately |

**Recommendation:** Always run the latest stable release (currently v1.61.0) for optimal security and performance.

### Supported Platforms by Tier

Security fixes are prioritized for Tier 0 platforms first.

| Tier | Platforms | Support Level |
|------|-----------|---------------|
| **Tier 0** | Ubuntu 24.04 LTS, Debian 12, Rocky Linux 9.x | Fully supported |
| **Tier 1** | Rocky Linux 10.x, Debian 13, Ubuntu 26.04 LTS | Planned |
| **Tier 2** | Rocky/RHEL 8.x, Ubuntu 22.04 LTS, Debian 11 | Best-effort (legacy) |

---

## Reporting Security Vulnerabilities

We take security seriously and follow responsible disclosure practices. If you discover a security vulnerability in NFTBan, please report it responsibly.

### How to Report

**DO NOT report security vulnerabilities through public GitHub issues.**

Report security vulnerabilities via:

1. **Email:** [security@nftban.com](mailto:security@nftban.com)
2. **Subject Line:** Include `[SECURITY]` prefix
3. **Required Information:**
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact assessment
   - Affected versions
   - Suggested fix (if available)
   - Your contact information for follow-up

### Response Timeline

| Phase | Timeline |
|-------|----------|
| **Acknowledgment** | Within 48 hours |
| **Initial Assessment** | Within 7 days |
| **Status Updates** | Every 7-14 days until resolution |
| **Patch Development** | Based on severity (Critical: 7 days, High: 14 days, Medium: 30 days) |

### Coordinated Disclosure Policy

NFTBan follows a **90-day coordinated disclosure policy**:

1. **Day 0:** Vulnerability reported
2. **Day 1-7:** Initial assessment and severity classification
3. **Day 7-60:** Patch development and testing
4. **Day 60-75:** Private disclosure to affected users (for critical infrastructure)
5. **Day 75-90:** Public release preparation
6. **Day 90:** Public disclosure with security advisory

**Exceptions:**
- Actively exploited vulnerabilities may be disclosed sooner
- Complex issues may require timeline extension (with reporter agreement)
- Reporters will be kept informed throughout the process

### Credit to Security Researchers

We publicly acknowledge security researchers who responsibly disclose vulnerabilities:

- Credit in release notes and security advisories
- Listed in our Security Hall of Fame (with permission)
- CVE acknowledgment where applicable

**To opt out of public credit:** Indicate your preference when reporting.

### Security Update Process

1. **Verification:** We confirm and reproduce the vulnerability
2. **Severity Assessment:** CVSS scoring and impact analysis
3. **Patch Development:** Create, review, and test fix
4. **Private Disclosure:** Notify enterprise users before public release
5. **Public Release:** Publish patched version with security advisory
6. **CVE Assignment:** Request CVE identifier if applicable
7. **Post-Incident Review:** Document lessons learned

---

## Security Architecture

### Privilege Model

NFTBan implements a **capability-based privilege model** following the principle of least privilege:

| Component | User | Capabilities | Purpose |
|-----------|------|--------------|---------|
| `nftband` (daemon) | `root` | `CAP_NET_ADMIN`, `CAP_DAC_OVERRIDE` | nftables rule management, stats writing |
| `nftban-health` | `nftban` | `CAP_NET_ADMIN` | Health monitoring |
| `nftban-unified-exporter` | `nftban` | `CAP_NET_ADMIN` | Metrics collection |

**Key Points:**
- **Root required for nftables:** `CAP_NET_ADMIN` capability is essential for firewall rule management
- **Dedicated system user:** Services run as `nftban` user where possible
- **No privilege escalation:** `NoNewPrivileges=true` enforced for all services
- **Ambient capabilities:** Used instead of setuid/setgid for cleaner security boundaries

### Inter-Process Communication (IPC)

The `nftband` daemon uses **Unix socket IPC** for CLI communication:

| Property | Value |
|----------|-------|
| Socket Path | `/run/nftban/nftband.sock` |
| Permissions | `0660` (owner + group read/write) |
| Ownership | `root:nftban` |
| Authentication | `SO_PEERCRED` credential verification |

**Security Properties:**
- **No network listeners:** The daemon does not bind to any network interface
- **Local-only access:** Communication restricted to local Unix socket
- **Group-based ACL:** Only `nftban` group members can communicate with daemon
- **Credential verification:** Client UID/GID verified via socket peer credentials

### Crash Behavior and Recovery

NFTBan is designed for **fail-secure** operation:

| Scenario | Behavior |
|----------|----------|
| Daemon crash | nftables rules persist in kernel; firewall remains active |
| Daemon restart | systemd automatically restarts daemon (`Restart=on-failure`) |
| Config error | Daemon refuses to start; existing rules remain in place |
| Socket failure | CLI operations fail gracefully; firewall unaffected |

**Key Guarantees:**
- **Rules persist:** nftables rules are loaded into kernel memory and survive daemon restarts
- **Atomic restarts:** systemd manages service lifecycle with proper dependency ordering
- **No rule gaps:** Firewall protection never drops during daemon restart

### Rule Modification Atomicity

All nftables rule changes are **atomic via nftables transactions**:

```
# Conceptual transaction flow
1. Build complete ruleset in memory
2. Validate ruleset syntax
3. Submit to nftables as single transaction
4. Kernel applies atomically (all-or-nothing)
```

**Guarantees:**
- **No partial updates:** Rules are never half-applied
- **Automatic rollback:** Failed transactions leave previous rules intact
- **Consistent state:** System always has a valid, complete ruleset
- **Performance:** Bulk operations are batched into single kernel transaction

---

## systemd Service Hardening

All NFTBan services implement comprehensive systemd sandboxing:

```ini
# Applied to all services
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictNamespaces=true
LockPersonality=true
RestrictSUIDSGID=true
RestrictRealtime=true
SystemCallFilter=@system-service
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=/var/lib/nftban /var/log/nftban /var/cache/nftban /run/nftban
```

### MemoryDenyWriteExecute Trade-off

**Status:** Intentionally DISABLED for Go-based services

**Affected Services:** current Go-based services (`nftband`, `nftban-core`)

**Reason:** Go runtime requires writable-executable memory for JIT compilation, which conflicts with `MemoryDenyWriteExecute=true` on Ubuntu 24.04+ (AppArmor + Landlock LSM interaction).

**Risk Level:** LOW

**Mitigations:**
- Go's memory-safe runtime prevents most memory corruption vulnerabilities
- Defense-in-depth via other systemd sandboxing directives
- ASLR, stack canaries, and compiler protections remain active

---

## Filesystem Security

### Permission Model

| Path | Ownership | Permissions | Purpose |
|------|-----------|-------------|---------|
| `/etc/nftban` | `root:root` | `0755` | Configuration (read-only by daemon) |
| `/var/lib/nftban` | `root:nftban` | `0750` | State data (security boundary) |
| `/var/lib/nftban/*` | `nftban:nftban` | Varies | Daemon-writable subdirectories |
| `/var/log/nftban` | `nftban:nftban` | `0750` | Log files |
| `/run/nftban` | `root:nftban` | `0750` | Runtime data, sockets |

### Receipt-Driven Installation

NFTBan installations produce `/var/lib/nftban/install-receipt.json`:

- Defines expected system state (files, permissions, units)
- Used for drift detection and security validation
- Drift (unexpected files, wrong permissions) treated as security risk

---

## Polkit Integration

Polkit rules provide least-privilege service management:

| Distro Family | Rules Path |
|---------------|------------|
| Debian/Ubuntu | `/usr/share/polkit-1/rules.d` |
| RHEL/Rocky | `/etc/polkit-1/rules.d` |

Rules are:
- Least-privilege and profile-gated
- Installed via distro-specific paths resolved at install time
- Recorded in installation receipt

---

## Input Validation

All input is validated before processing:

- **IP addresses:** Validated against RFC-compliant regex, normalized
- **Usernames:** Allowlist-based validation (alphanumeric + limited special chars)
- **Configuration:** Schema-validated at load time
- **Shell commands:** Parameterized; no string interpolation in commands
- **JSON IPC:** Strict schema validation; unknown fields rejected

---

## Known Security Advisories

### NFTBan-SA-2024-001 - Rule Order Bypass

| Field | Value |
|-------|-------|
| **Advisory ID** | NFTBan-SA-2024-001 |
| **Severity** | HIGH |
| **Affected** | v0.32.5 and earlier |
| **Fixed in** | v0.32.6 (2024-11-05) |
| **Status** | Patched in v1.0+ |
| **CVE** | Not assigned (internal advisory) |

**Issue:** Blacklist checks ran after port allow rules, allowing blacklisted IPs to bypass firewall.

**Action Required:**
1. Upgrade to v1.61.x (recommended)
2. Verify fix: `nftban firewall check`

---

## Security Best Practices

1. **Keep Updated** - Run the latest stable version
2. **Monitor Logs** - Review `/var/log/nftban/` security events daily
3. **Enable Health Checks** - Automated system validation catches issues early
4. **Use Threat Feeds** - Automated malicious IP blocking
5. **Harden SSH** - Disable password authentication, use key-based only
6. **Backup Regularly** - Use `nftban backup` for automated daily backups
7. **Test Restores** - Verify backup integrity quarterly
8. **Review Permissions** - Run `nftban health --check permissions` periodically

---

## Security Review Hotspots

Changes to these areas require extra security review:

- systemd unit files, timers, sockets
- Polkit rules and helpers
- nftables rule generation logic
- Installer and maintainer scripts (deb/rpm)
- Receipt schema and validation logic
- Code paths modifying `/etc/nftban` or firewall state
- Unix socket authentication and authorization

---

## Scope

### In Scope

- NFTBan core system and daemon
- NFTBan CLI tools
- NFTBan Go binaries
- Official installation packages (RPM, DEB)
- Official documentation and scripts
- Unix socket IPC protocol

### Out of Scope

- Third-party dependencies (report to upstream maintainers)
- User misconfigurations
- Physical server security
- Social engineering attacks
- Theoretical vulnerabilities without proof of concept
- Issues in EOL versions (< 1.14)

---

## Security Hall of Fame

We recognize security researchers who responsibly disclose vulnerabilities:

| Researcher | Vulnerability | Date |
|------------|---------------|------|
| *Your name here* | Be the first to report a v1.15+ vulnerability | - |

---

## Contact

| Channel | Address | Use For |
|---------|---------|---------|
| **Security Email** | [security@nftban.com](mailto:security@nftban.com) | Vulnerability reports |
| **GitHub Issues** | [github.com/nftban/nftban/issues](https://github.com/nftban/nftban/issues) | Non-security bugs only |
| **Discussions** | [github.com/nftban/nftban/discussions](https://github.com/nftban/nftban/discussions) | General questions |

---

## Automated Security Pipeline (CI/CD)

NFTBan employs **16 GitHub Actions workflows** with **12 dedicated security tools** running on every commit and PR.

### Security Certifications

| Certification | Level | Verification |
|--------------|-------|--------------|
| **OpenSSF Scorecard** | 7+ / 10 | [View Score](https://securityscorecards.dev/viewer/?uri=github.com/itcmsgr/nftban) |
| **OpenSSF Best Practices** | Passing | [View Badge](https://www.bestpractices.dev/projects/11959) |
| **SLSA Provenance** | Level 3 | Hermetic builds, non-forgeable provenance |
| **SBOM** | SPDX-JSON | Attached to every release |

### Security Tools by Category

#### Static Application Security Testing (SAST)

| Tool | Workflow | Purpose |
|------|----------|---------|
| **CodeQL** | `codeql.yml` | Semantic code analysis for Go |
| **Semgrep** | `semgrep.yml` | Pattern-based security rules (Go + Shell) |
| **gosec** | `secure-go.yml` | Go-specific security linting |
| **ShellCheck** | `shellcheck.yml` | Shell script security analysis |

#### Software Composition Analysis (SCA)

| Tool | Workflow | Purpose |
|------|----------|---------|
| **govulncheck** | `secure-go.yml` | Go module vulnerability scanning |
| **OSV-Scanner** | `osv-scanner.yml` | Google OSV database scanning |
| **Trivy** | `secure-go.yml` | Container & dependency CVE scanning |
| **Dependency Review** | `dependency-review.yml` | PR-level dependency diff analysis |

#### Secret Detection

| Tool | Workflow | Purpose |
|------|----------|---------|
| **gitleaks** | `gitleaks.yml` | Secret detection in commits |
| **GitHub Secret Scanning** | Native | Known secret pattern detection |

#### Supply Chain Security

| Tool | Workflow | Purpose |
|------|----------|---------|
| **SLSA Provenance** | `slsa-go-releaser.yml` | Cryptographic build attestation |
| **OpenSSF Scorecard** | `scorecard.yml` | Security health assessment |
| **Syft SBOM** | `release.yml` | Software Bill of Materials generation |
| **Socket.dev** | GitHub App | Typosquatting and malware detection |

#### 2026 OSSRA Compliance

| Tool | Workflow | Purpose |
|------|----------|---------|
| **go-licenses** | `ossra-remediation.yml` | License compliance (blocks copyleft) |
| **SPDX Validation** | `ossra-remediation.yml` | License header enforcement |
| **Libyear** | `ossra-remediation.yml` | Dependency freshness metrics |
| **Lychee** | `ossra-remediation.yml` | URL validation (anti-hallucination) |

#### Quality & Fuzzing

| Tool | Workflow | Purpose |
|------|----------|---------|
| **go-fuzz** | `fuzz.yml` | Automated fuzz testing |
| **Go Test** | `ci.yml` | Unit and integration tests |

### SARIF Integration

All security tools upload findings to GitHub Security tab in SARIF format for unified vulnerability tracking and remediation workflow.

### Vulnerability Response SLA

| Severity | Detection → Fix SLA |
|----------|---------------------|
| **Critical** | 24-48 hours |
| **High** | 7 days |
| **Medium** | 30 days |
| **Low** | Next release |

---

## Additional Resources

- [Security Architecture](https://github.com/itcmsgr/nftban/wiki/Security-Architecture) - Detailed security model
- [Security Operations Guide](https://github.com/itcmsgr/nftban/wiki/Security-Operations-Guide) - Hardening procedures
- [Groups and Permissions](https://github.com/itcmsgr/nftban/wiki/Groups-and-Permissions) - Access control details
- [OpenSSF Scorecard](https://securityscorecards.dev/viewer/?uri=github.com/itcmsgr/nftban) - Live security score

---

**Thank you for helping keep NFTBan secure.**
