# Security Policy

## About NFTBAN

NFTBan is an open-source Linux Intrusion Prevention System (IPS) and firewall manager built on nftables, designed to integrate cleanly with modern Linux security stacks. Security is foundational to the architecture, featuring Polkit-based privilege separation, systemd sandboxing, and strict input validation at all layers.

## Reporting Security Vulnerabilities

We take security seriously and follow responsible disclosure practices. If you discover a security vulnerability in NFTBAN, please report it responsibly.

### How to Report

**Please DO NOT report security vulnerabilities through public GitHub issues.**

Instead, please report security vulnerabilities by:

1. **Email:** Send details to security@itcms.gr
2. **Subject:** Include "NFTBan Security:" prefix
3. **Details:** Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if available)
   - Your contact information

### What to Expect

- **Acknowledgment:** Within 48 hours
- **Initial Assessment:** Within 7 days
- **Status Updates:** Every 7-14 days until resolution
- **Credit:** Public acknowledgment in release notes (if desired)

### Security Update Process

1. **Verification:** We confirm the vulnerability
2. **Fix Development:** Create and test patch
3. **Private Disclosure:** Notify affected users before public release
4. **Public Release:** Publish fix with security advisory
5. **CVE Assignment:** Request CVE if applicable

### Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.0.x   | Full support    |
| 0.32.x  | Security fixes only |
| < 0.32  | Not supported   |

**Recommendation:** Always use the latest stable release (v1.0.x) for best security.

### Supported Platforms by Tier

NFTBan supports platforms by tier. Security fixes are prioritized for Tier 0 first.

**Tier 0 — Focus (fully supported)**
- Ubuntu 24.04 LTS
- Debian 12
- Rocky Linux 9.x

**Tier 1 — Future targets (planned)**
- Rocky Linux 10.x
- Debian 13
- Ubuntu 26.04 LTS

**Tier 2 — Legacy (best-effort)**
- Rocky/RHEL 8.x
- Ubuntu 22.04 LTS
- Debian 11

### Security Model

#### Privilege Boundaries
- NFTBan uses a dedicated system user: `nftban`
- Root privileges are constrained to specific operations (e.g., applying nftables changes)
- Privileged operations use polkit or tightly sandboxed root-run services

#### Receipt-Driven Installation
- Installations produce `/var/lib/nftban/install-receipt.json`
- The receipt defines the expected system state and is used for validation
- Drift (extra units, leftover scripts, unexpected permissions) is treated as a security risk

#### Distro-Specific Policy Resolution
- Distro differences (polkit rules location, binary paths) resolve via `/etc/nftban/distros/*.conf`
- No hardcoded distro paths are allowed in installers or validators
- Resolved values are recorded in the receipt

#### Scheduling and Autoheal
- Scheduling is systemd timers only. **Cron is forbidden.**
- Maintenance and health timers are security features (e.g., SSH lockout prevention)
- Disabling them can increase risk

## Hardening Requirements

### systemd Service Hardening

Services should use conservative hardening where compatible:

```ini
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
MemoryDenyWriteExecute=true  # See trade-off section below
ReadWritePaths=/var/lib/nftban /var/log/nftban /var/cache/nftban /run/nftban
```

### Filesystem Permissions

- `/etc/nftban` is root-owned and not writable by the `nftban` user
- `/var/lib/nftban` is root:nftban (top-level boundary) with daemon-writable subdirectories
- Scripts invoked by systemd must be executable (0755) and installed deterministically by packaging

### Polkit Rules

- Polkit rules must be least-privilege and profile-gated
- Rule installation path is distro-dependent and resolved via distro config + receipt:
  - Debian/Ubuntu: `/usr/share/polkit-1/rules.d`
  - RHEL/Rocky: `/etc/polkit-1/rules.d`

### Security Features

NFTBan includes comprehensive security features:

- **FHS Auto-Heal** - Self-correcting file system permissions
- **Polkit Integration** - Least-privilege service management
- **Suricata IDS** - Real-time intrusion detection
- **Threat Feeds** - Automated malicious IP blocking
- **Geo-Blocking** - Country-based access control
- **DDoS Protection** - Multi-layer attack mitigation

For complete security documentation, see:

- **[Security Architecture](https://github.com/itcmsgr/nftban/wiki/Security-Architecture)** - NFTBan's security model
- **[Security Operations Guide](https://github.com/itcmsgr/nftban/wiki/Security-Operations-Guide)** - Hardening and operations
- **[Groups and Permissions](https://github.com/itcmsgr/nftban/wiki/Groups-and-Permissions)** - Access control

### Systemd Hardening Trade-offs

NFTBan's systemd service files implement comprehensive security hardening, but one directive is intentionally disabled for Go-based services:

#### MemoryDenyWriteExecute Trade-off

**Status:** ⚠️ Intentionally DISABLED for Go services

**Affected Services:**
- `nftban-core.service`
- `nftban-core-feeds.service`
- `nftban-core-geoip.service`
- `nftban-ui.service`
- `nftban-ui-auth.service`

**Reason:**

The `MemoryDenyWriteExecute=true` systemd directive prevents memory pages from being both writable and executable, which is a strong defense against memory corruption exploits (buffer overflows, ROP attacks, etc.). However, this directive breaks Go runtime on:

- Ubuntu 24.04+ (AppArmor + Landlock LSM interaction)
- Potentially other SELinux-enforcing distributions
- Certain kernel configurations with strict memory protection

**Risk Assessment:**

Without `MemoryDenyWriteExecute=true`, memory pages can be both writable and executable, which increases the attack surface for memory corruption vulnerabilities.

**Risk Level:** LOW to MEDIUM

- Go's memory-safe runtime significantly reduces memory corruption risk
- Other systemd hardening compensates for this trade-off
- Attack requires both memory corruption vulnerability AND bypass of other protections

**Mitigation Strategies:**

NFTBan employs defense-in-depth to compensate for this trade-off:

1. **Systemd Sandboxing:**
   - `ProtectSystem=strict` - Read-only filesystem
   - `ProtectKernelModules=true` - Cannot load kernel modules
   - `ProtectKernelTunables=true` - Cannot modify kernel parameters
   - `NoNewPrivileges=true` - Cannot gain additional privileges
   - `SystemCallFilter=@system-service` - Strict syscall allowlist
   - `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6` - Limited network access

2. **Language-Level Protection:**
   - Go's garbage collector and bounds checking prevent many memory corruption bugs
   - Go's type safety reduces attack surface compared to C/C++

3. **System-Level Protection:**
   - ASLR (Address Space Layout Randomization) enabled system-wide
   - Stack canaries and other compiler protections
   - SELinux/AppArmor policies (distribution-dependent)

4. **Input Validation:**
   - Strict username validation (allowlist-based)
   - Safe shell script practices (no command injection)
   - Validated environment variables

**Alternatives Investigated:**

The following alternatives were evaluated but rejected:

- **Custom AppArmor profiles:** Complex, distribution-specific, maintenance burden
- **Seccomp-bpf filters:** Insufficient for this specific LSM interaction issue
- **Landlock sandboxing:** Conflicts with Go runtime memory management

**Future Resolution:**

This trade-off will be re-evaluated on:
- Go 1.23+ releases (improved LSM compatibility)
- Ubuntu 26.04 LTS (updated AppArmor + Landlock)
- Future kernel versions with refined memory protection

**Recommendation:**

Accept this trade-off. The defense-in-depth approach provides strong security despite the missing directive. The combination of systemd sandboxing, Go's memory safety, and strict input validation makes exploitation extremely difficult.

**References:**
- Service files: `install/systemd/*.service` (central location)
- Each affected service file contains detailed inline documentation
- See systemd.exec(5) man page for directive details

### Known High-Risk Areas (Review Hotspots)

Changes touching any of the following require extra security review:

- systemd unit files, timers, sockets
- polkit rules or helpers
- nftables rule generation
- installer scripts and maintainer scripts (deb/rpm)
- receipt schema or validation logic
- any code paths that modify `/etc/nftban` or firewall state

### Known Security Advisories

#### CVE-2024-NFTBAN-001 - Rule Order Bypass (FIXED)

**Severity:** HIGH
**Affected:** v0.32.5 and earlier
**Fixed in:** v0.32.6 (2025-11-05)
**Status:** ✅ Patched in v1.0+

**Issue:** Blacklist checks ran after port allow rules, allowing blacklisted IPs to bypass firewall.

**Action Required:**
- Upgrade to v1.0.x (recommended)
- Or upgrade to v0.32.6+ minimum
- Verify fix: `nftban firewall check`

**Details:** See [Security Operations Guide](https://github.com/itcmsgr/nftban/wiki/Security-Operations-Guide#security-advisories)

### Security Best Practices

1. **Keep Updated** - Run latest stable version
2. **Monitor Logs** - Review security events daily
3. **Enable Health Checks** - Automated system validation
4. **Use Threat Feeds** - Block known malicious IPs
5. **Harden SSH** - Disable passwords, use keys only
6. **Backup Regularly** - Automated daily backups
7. **Test Restores** - Verify backup integrity quarterly

See the **[Security Operations Guide](https://github.com/itcmsgr/nftban/wiki/Security-Operations-Guide)** for complete hardening procedures.

### Scope

This security policy applies to:

- NFTBan core system
- NFTBan CLI tools
- NFTBan Go binaries
- Official installation packages (RPM, DEB)
- Official documentation and scripts

### Out of Scope

The following are **not** covered by this security policy:

- Third-party dependencies (report to upstream)
- User misconfigurations
- Physical server security
- Social engineering attacks
- Theoretical vulnerabilities without proof of concept

### Hall of Fame

We recognize security researchers who responsibly disclose vulnerabilities:

*No vulnerabilities reported yet for v1.0+*

### Contact

- **Security Email:** security@itcms.gr
- **GitHub Issues:** https://github.com/itcmsgr/nftban/issues (non-security only)
- **Discussions:** https://github.com/itcmsgr/nftban/discussions

---

**Thank you for helping keep NFTBan secure!**
