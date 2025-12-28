# Security Policy

## Reporting Security Vulnerabilities

We take the security of NFTBan seriously. If you discover a security vulnerability, please report it responsibly.

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
| 1.0.x   | ✅ Full support    |
| 0.32.x  | ⚠️ Security fixes only |
| < 0.32  | ❌ Not supported   |

**Recommendation:** Always use the latest stable release (v1.0.x) for best security.

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
