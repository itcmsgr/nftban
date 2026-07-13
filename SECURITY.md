# Security Policy

## Integrity & Build Verification

NFTBan enforces security through a kernel-first validation model and automated
CI/CD pipelines.

→ **Full audit surface:** [Integrity & Build Status (STATUS.md)](STATUS.md)

This includes:
- CI pipeline results (build, security, compliance)
- Contract gate enforcement
- Supply chain verification (SLSA provenance for the standalone nftban-core binary)
- Runtime verification commands

This page describes vulnerability reporting and security policy.
STATUS.md provides machine-verifiable system integrity.

---

## About NFTBan

NFTBan is an open-source Linux Intrusion Prevention System (IPS) and firewall manager built on nftables. Security is foundational to the architecture, featuring least-privilege service separation, systemd sandboxing, Unix socket IPC, and strict input validation at all layers.

---

## Supported Versions

NFTBan follows a rolling support policy tied to the latest release. The authoritative
current version is the [`VERSION`](VERSION) file; see [GitHub Releases](https://github.com/itcmsgr/nftban/releases).

| Release | Support Status |
|---------|----------------|
| Latest stable release (current `VERSION`) | **Current** — full support (security + bug fixes) |
| Immediately preceding stable release | **Security fixes may be provided at maintainer discretion** |
| Older | **Not supported** — upgrade to the latest release |

> NFTBan ships patch trains (e.g. v1.220.0 → v1.220.1); "release" here means a stable
> tagged release, not an OSI minor version. Backports to a previous release are not
> guaranteed.

**Recommendation:** Always run the latest stable release for security and correctness fixes.

### Supported Platforms by Tier

Security fixes are prioritized for Tier 0 platforms first.

| Tier | Platforms | Support Level |
|------|-----------|---------------|
| **Tier 0** | Ubuntu 24.04 LTS, Debian 12, EL9 (Rocky / AlmaLinux / RHEL 9) | Primary — fully supported |
| **Tier 1** | Ubuntu 26.04 LTS, Debian 13, EL10 (Rocky / AlmaLinux / RHEL 10) | Newer supported — released and packaged |
| **Tier 2** | Ubuntu 22.04 LTS | Older supported / best-effort (released package) |

EL8 (Rocky / AlmaLinux / RHEL 8) and Debian 11 are **historical** — not current release-package targets.

---

## Reporting Security Vulnerabilities

We take security seriously and follow responsible disclosure practices. If you discover a security vulnerability in NFTBan, please report it responsibly.

### How to Report

**DO NOT report security vulnerabilities through public GitHub issues, discussions, or pull requests.**

Report privately, in order of preference:

1. **GitHub private Security Advisory (preferred):** open a report via
   **Security → Advisories → Report a vulnerability** on the
   [nftban repository](https://github.com/itcmsgr/nftban/security/advisories/new).
   This channel is private and encrypted in transit.
2. **Email (fallback):** [security@nftban.com](mailto:security@nftban.com) with a `[SECURITY]` subject prefix.

**Encrypted contact:** a PGP key for encrypted email reports is **pending publication**;
until then, prefer the GitHub private Security Advisory path.

**Confidentiality:** reports are treated as confidential and shared only with the people
needed for triage and remediation. A TLP classification may be agreed with the reporter
where useful; it is not assigned automatically.

**Please include:**
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact assessment
   - Affected versions
   - Suggested fix (if available)
   - Your contact information for follow-up

**Coordination expected:** please do **not** publish exploit code, proof-of-concept, or
reproduction details before a fix is released and the coordinated-disclosure window (below)
has elapsed. We commit to the timeline below and to crediting reporters who follow this process.

### Response Timeline

| Phase | Timeline |
|-------|----------|
| **Acknowledgment** | Within 48 hours |
| **Initial Assessment** | Within 7 days |
| **Status Updates** | Every 7-14 days until resolution |
| **Patch Development** | Target remediation windows (begin after validation + severity classification): Critical — as rapidly as practicable; High — target 14 days; Medium — target 30 days; Low — next suitable release |

> These are **targets, not guarantees**. Complexity, coordination requirements, platform
> impact, and reporter agreement may change the timeline.

### Coordinated Disclosure Policy

NFTBan follows a **flexible coordinated disclosure** model. The target disclosure window
is **up to 90 days**, but exact timing is agreed case by case based on severity,
active exploitation, patch readiness, downstream coordination, and reporter needs.

A typical flow (indicative, not fixed):

1. Vulnerability reported → acknowledgment.
2. Initial assessment and severity classification.
3. Patch development and testing.
4. Public release with a security advisory once a fix is ready.

Critical or actively-exploited issues may be released and disclosed in well under 90 days;
low-risk or disputed findings may follow a different timeline. NFTBan does not operate a
private customer-notification channel, so per-user pre-disclosure is not guaranteed.

**Exceptions:**
- Actively exploited vulnerabilities may be disclosed sooner
- Complex issues may require timeline extension (with reporter agreement)
- Reporters will be kept informed throughout the process

### Security-response model

NFTBan follows a **coordinated vulnerability disclosure** model and is designed to be
compatible with industry security-response practices — **CVE, CVSS, CWE, TLP, and VEX** —
and confidential remediation workflows. See:

- [`docs/security/COORDINATED_DISCLOSURE.md`](docs/security/COORDINATED_DISCLOSURE.md) — intake → triage → fix → embargo → advisory
- [`docs/security/SECURITY_ADVISORY_PROCESS.md`](docs/security/SECURITY_ADVISORY_PROCESS.md) — GHSA/CVE/CVSS/CWE/VEX publication flow
- [`docs/security/VULNERABILITY_CLASSES.md`](docs/security/VULNERABILITY_CLASSES.md) — NFTBan-specific (firewall/IPS) vulnerability classes
- [`docs/security/CVE_CVSS_CWE_GUIDE.md`](docs/security/CVE_CVSS_CWE_GUIDE.md) — severity-scoring rubric
- [`docs/security/VEX_POLICY.md`](docs/security/VEX_POLICY.md) — dependency-CVE exploitability statements

> **No external affiliation.** NFTBan is not affiliated with, certified by, endorsed by, or
> protected by Akrites or any other external security body. NFTBan maintains its own coordinated
> vulnerability disclosure process and is designed to be compatible with modern security-response
> practices such as confidential intake, coordinated disclosure, CVE, CVSS, CWE, TLP, and VEX.

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
4. **Coordinated Disclosure:** Notify affected parties via the published GitHub Security Advisory and release notes at public release (a dedicated security-announcement channel is planned, not yet available)
5. **Public Release:** Publish patched version with security advisory
6. **CVE Assignment:** Request CVE identifier if applicable
7. **Post-Incident Review:** Document lessons learned

---

## Security Architecture

### Privilege Model

NFTBan applies **least privilege (PoLP)** through service separation, group authorization,
systemd sandboxing, Linux capabilities where applicable, and narrowly scoped root-owned
operations. (Note: the `nftband` daemon runs as `root` with a bounded capability set — this
is not the same as an unprivileged capability-only daemon.) The table below is validated
against the shipped `install/systemd/*` units; keep it in sync with a documentation guard.

| Component | User | Capabilities | Purpose |
|-----------|------|--------------|---------|
| `nftband` (daemon) | `root` | `CAP_NET_ADMIN`, `CAP_DAC_OVERRIDE` | nftables rule management, stats writing |
| `nftban-health` | `nftban` | `CAP_NET_ADMIN` | Health monitoring |
| `nftban-unified-exporter` | `nftban` | `CAP_NET_ADMIN` | Metrics collection |

**Key Points:**
- **Root required for nftables:** `CAP_NET_ADMIN` capability is essential for firewall rule management
- **Dedicated system user:** Services run as `nftban` user where possible
- **No privilege escalation, where compatible:** `NoNewPrivileges=true` is set on the units where it is compatible (the majority of shipped units), not universally — a few require elevated transitions (e.g. SELinux domain transition, install/update helpers). Verify per unit against `install/systemd/*`.
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
- **IPC is local-only:** The daemon's control/IPC path is a local Unix socket (`SO_PEERCRED`, `root:nftban` `0660`) — it does not accept IPC from any network interface.
- **HTTP surface (`:9580`) is network-reachable — hardening tracked:** The daemon also serves an HTTP metrics/health/status surface that, by default, **binds `:9580` on all interfaces** (not loopback-only). The `/metrics` endpoint enforces a loopback source check (localhost only), but **`/health`, `/api/v1/status`, and `/api/v1/modules` are unauthenticated and reachable from remote networks** (information disclosure). Binding this surface to loopback and/or adding authentication is a planned hardening item; **until it ships, operators should firewall `:9580` to trusted sources** (e.g. allow only the local monitoring host).
- **Local-only access:** IPC restricted to the local Unix socket
- **Authorized access:** the socket is accessible to `root` and authorized members of the `nftban` group (`0660 root:nftban`). Group membership grants socket access; it does not by itself authorize every operation.
- **Credential + command verification:** the daemon validates client UID/GID via `SO_PEERCRED` and applies per-command authorization (not all callers may perform all actions).

### Crash Behavior and Recovery

NFTBan is designed to **preserve the last successfully loaded nftables policy across daemon
failures**. Individual update, synchronization, and recovery paths are validated separately
for fail-open and lockout risks — "fail-secure" is a design goal for the loaded ruleset, not
an unconditional whole-system guarantee.

| Scenario | Behavior |
|----------|----------|
| Daemon crash | already-loaded nftables rules persist in kernel; firewall remains active |
| Daemon restart | systemd automatically restarts daemon (`Restart=on-failure`) |
| Config error | Daemon refuses to start; existing rules remain in place |
| Socket failure | CLI operations fail gracefully; loaded firewall rules unaffected |

**Key behaviors:**
- **Rules persist:** nftables rules are loaded into kernel memory and survive daemon restarts
- **Managed lifecycle:** systemd manages service lifecycle with proper dependency ordering
- **Continuity:** daemon restart does not normally remove the already-loaded nftables ruleset; ruleset rebuild and synchronization paths use transactional and validation controls to minimize enforcement gaps.

### Rule Modification Atomicity

**Full-ruleset replacement** (schema load / firewall rebuild) uses nftables transactional
loading — all-or-nothing:

```
# Full-ruleset transaction flow (nft -f)
1. Build complete ruleset in memory
2. Validate ruleset syntax
3. Submit to nftables as a single transaction
4. Kernel applies atomically (all-or-nothing)
```

**Incremental set-element updates** (ban/unban, add/delete) and set
synchronization/reconciliation follow their **own separate atomicity and reconciliation
contracts** — they are not a single whole-ruleset transaction. Do not read "atomic rebuild"
as "every nftables mutation is one atomic transaction."

**Guarantees (full-ruleset load):**
- **No partial updates:** the ruleset is never half-applied
- **Automatic rollback:** a failed transaction leaves previous rules intact
- **Consistent state:** the load produces a valid, complete ruleset

---

## systemd Service Hardening

NFTBan services apply a baseline of systemd sandboxing, with additional syscall
filtering on selected services:

```ini
# Baseline directives applied broadly across NFTBan units
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
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
ReadWritePaths=/var/lib/nftban /var/log/nftban /var/cache/nftban /run/nftban

# SystemCallFilter is applied to a subset of units (currently the shorter-lived
# helper services: nftban-core-feeds, nftban-core-geoip, nftban-firewall-init,
# nftban-firewall-validate). It is NOT currently set on the long-running nftband
# daemon unit; see the MemoryDenyWriteExecute trade-off note below for why some
# hardening directives are applied selectively rather than uniformly.
SystemCallFilter=@system-service   # (selected services only, not nftband.service)
```

### MemoryDenyWriteExecute Trade-off

**Status:** Currently NOT enabled for the Go-based services

**Affected Services:** current Go-based services (`nftband`, `nftban-core`)

**Reason:** `MemoryDenyWriteExecute=true` is **not enabled for the Go services because
compatibility has not been fully validated across supported distributions.** This is a
documented hardening gap under review. (Standard Go binaries do not use a JIT compiler; the
incompatibility, where it occurs, is not "Go JIT" — likely candidates are cgo, runtime
memory mappings, embedded libraries, or platform/LSM-specific behavior, and must be
reproduced before a definitive cause is stated.)

**Risk Level:** LOW

**Mitigations:**
- Go reduces many classes of memory-safety defects, though cgo, `unsafe` usage, logic bugs, and dependency code remain relevant.
- Defense-in-depth via other systemd sandboxing directives
- ASLR, stack canaries, and compiler protections remain active

---

## Filesystem Security

### Permission Model

Ownership and modes **vary by path, file class, and producer** (some artifacts are
root-owned security/forensic files even under a `nftban`-owned parent). The **generated FHS
specification (`build/fhs-spec.yaml`) is authoritative** — the table below is an
illustrative summary, not the source of truth.

| Path | Ownership (typical) | Permissions | Purpose |
|------|---------------------|-------------|---------|
| `/etc/nftban` | `root:root` | `0755` | Configuration (read-only by daemon) |
| `/var/lib/nftban` | `root:nftban` | `0750` | State data (security boundary) |
| `/var/lib/nftban/*` | varies by subdir/producer | Varies | Daemon-writable + root-owned artifacts |
| `/var/log/nftban` | `nftban:nftban` | `0750` | Log files |
| `/run/nftban` | `root:nftban` | `0750` | Runtime data, sockets |

### Receipt-Driven Installation

NFTBan installations produce `/var/lib/nftban/install-receipt.json`:

- Defines expected system state (files, permissions, units)
- Used for drift detection and security validation
- Drift (unexpected files, wrong permissions) treated as security risk

---

## Polkit Integration

Polkit mediates **approved service-management actions** for authorized group members. The
authorization model is: `root` is fully privileged; `nftban` group members may run
command-specific service actions via Polkit; `nftban-auditor` members are read-only and
cannot mutate state; some operations remain root-only. **sudo does not automatically bypass
NFTBan's internal command authorization** — the boundary is authorization policy plus
filesystem/socket DAC, not an absolute block.

| Distro Family | Rules Path |
|---------------|------------|
| Debian/Ubuntu | `/usr/share/polkit-1/rules.d` |
| RHEL/Rocky | `/etc/polkit-1/rules.d` |

Rules are:
- Scoped to specific units/actions (not blanket service control)
- Installed via distro-specific paths resolved at install time
- Recorded in installation receipt

---

## Input Validation

Security-sensitive inputs are validated and normalized at their trust boundaries. Validation
coverage is enforced through shared parsers, typed Go APIs, ShellCheck/Semgrep rules, and
targeted tests — not an unqualified "everything, everywhere" guarantee.

- **IP addresses:** validated and normalized using **proper parsers** (Go `net.ParseIP` /
  `netip`) as the authority — not regex. Shell entry points apply a defensive charset gate
  before constructing `nft` commands.
- **Usernames:** allowlist-based validation (alphanumeric + limited special chars)
- **Configuration:** schema-validated at load time
- **Shell commands:** the daemon-write path uses parameterized IPC + a validation gate; a
  Semgrep/ShellCheck CI ratchet guards against unsafe string interpolation in new code.
- **JSON IPC:** strict schema validation; unknown fields rejected

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
1. Upgrade to the latest stable release
2. Verify fix: `nftban firewall check`

> This is a historical **internal** advisory (no CVE assigned); it is retained as a record.
> It affected v0.32.5 and was fixed in v0.32.6 — well before the current 1.x line.

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

### Scope notes

- **Dependency vulnerabilities are in scope** when they materially affect NFTBan's shipped
  binaries, packages, containers, or supported runtime paths (report those to us; purely
  upstream issues with no NFTBan impact go to the upstream maintainers).
- Reports **do not require working exploit code** — clear technical reasoning and
  reproducible evidence are sufficient.
- **Unsupported versions** are not eligible for fixes, but a report may still be relevant if
  the issue also affects the current release.

Generally out of scope: user misconfigurations, physical server security, and social
engineering attacks.

---

## Security Hall of Fame

We recognize security researchers who responsibly disclose vulnerabilities:

| Researcher | Vulnerability | Date |
|------------|---------------|------|
| — | No public acknowledgments yet | — |

---

## Contact

| Channel | Address | Use For |
|---------|---------|---------|
| **Security (vulnerabilities)** | GitHub private Security Advisory (preferred) · [security@nftban.com](mailto:security@nftban.com) (fallback) | Confidential vulnerability reports |
| **Support** | [support@nftban.com](mailto:support@nftban.com) | Install/config help, troubleshooting, false positives (no secrets/PoC) |
| **General / business** | [contact@nftban.com](mailto:contact@nftban.com) | Project, partnership, non-security contact |
| **Legal** | [legal@nftban.com](mailto:legal@nftban.com) | Licensing, copyright, trademark, formal notices |
| **GitHub Issues** | [github.com/itcmsgr/nftban/issues](https://github.com/itcmsgr/nftban/issues) | Non-security bugs only |
| **Discussions** | [github.com/itcmsgr/nftban/discussions](https://github.com/itcmsgr/nftban/discussions) | General questions |

---

## Automated Security Pipeline (CI/CD)

NFTBan uses layered CI security and supply-chain checks, listed below. Individual workflows
run according to their own triggers — across pull requests, branch updates, scheduled scans,
and release workflows — not uniformly "on every commit."

### Security posture

| Item | Status | Verification |
|--------------|-------|--------------|
| **OpenSSF Scorecard** | current score from the linked report | [View Score](https://securityscorecards.dev/viewer/?uri=github.com/itcmsgr/nftban) |
| **OpenSSF Best Practices** | Passing | [View Badge](https://www.bestpractices.dev/projects/11959) |
| **SLSA build provenance** | for the standalone `nftban-core` release binary, via GitHub's trusted SLSA release workflow (other assets are checksum-verified) | `.intoto.jsonl` asset |
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
| **go-licenses** | `ossra-remediation.yml` | Dependency-license compatibility against the project's approved policy |
| **SPDX Validation** | `ossra-remediation.yml` | License header enforcement |
| **Libyear** | `ossra-remediation.yml` | Dependency freshness metrics |
| **Lychee** | `ossra-remediation.yml` | Detects broken and unreachable documentation links |

#### Quality & Fuzzing

| Tool | Workflow | Purpose |
|------|----------|---------|
| **go-fuzz** | `fuzz.yml` | Automated fuzz testing |
| **Go Test** | `ci.yml` | Unit and integration tests |

### SARIF Integration

Supported analysis tools upload SARIF findings to GitHub code scanning; other tools report through their native workflow outputs and artifacts.

### Vulnerability Response SLA

The project publishes **target remediation windows** (not a contractual SLA), defined under
[Response Timeline](#response-timeline) above: acknowledgment within 48 hours; fix targets
Critical as rapidly as practicable, High target 14 days, Medium target 30 days, Low next suitable release. (Internally-detected issues
follow the same fix targets.)

---

## Additional Resources

- [Security Architecture](https://github.com/itcmsgr/nftban/wiki/Security-Architecture) - Detailed security model
- [Security Operations Guide](https://github.com/itcmsgr/nftban/wiki/Security-Operations-Guide) - Hardening procedures
- [Groups and Permissions](https://github.com/itcmsgr/nftban/wiki/Groups-and-Permissions) - Access control details
- [OpenSSF Scorecard](https://securityscorecards.dev/viewer/?uri=github.com/itcmsgr/nftban) - Live security score

---

**Thank you for helping keep NFTBan secure.**
