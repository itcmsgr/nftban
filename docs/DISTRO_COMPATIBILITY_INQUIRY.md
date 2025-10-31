# NFTBan Distribution Compatibility Inquiry Template

**Purpose:** Template for engaging with Linux distribution maintainers
**Target:** AlmaLinux, Rocky Linux, CentOS Stream developers
**Goal:** Validate architecture compatibility and best practices

---

## Email Template: AlmaLinux Developers

**Subject:** NFTBan Firewall Tool - Architecture Review Request for AlmaLinux Compatibility

**To:** devel@lists.almalinux.org
**CC:** security@lists.almalinux.org (if discussing security architecture)

---

Dear AlmaLinux Development Team,

I am developing **NFTBan**, an open-source nftables-based firewall management tool designed for enterprise Linux distributions, with a focus on RHEL-derived systems like AlmaLinux.

**Project Overview:**
- **Name:** NFTBan v0.10.0
- **Purpose:** Simplified nftables firewall management with fail2ban integration
- **License:** MPL-2.0 (Open Source)
- **Repository:** https://github.com/itcmsgr/nftban
- **Target:** System administrators managing AlmaLinux/Rocky/RHEL servers

**Request for Guidance:**

I would appreciate your team's input on the following architecture decisions to ensure optimal compatibility with AlmaLinux:

### 1. Repository Dependencies

**Current Approach:**
```bash
# Installation requires:
dnf install -y epel-release
crb enable  # CodeReady Builder
dnf install -y fail2ban-server nftables
```

**Questions:**
- Is `crb enable` the recommended approach for AlmaLinux 9/10?
- Are there any AlmaLinux-specific considerations for CRB usage?
- Should we recommend `fail2ban` or `fail2ban-server` package?
  - We currently recommend `fail2ban-server` to avoid firewalld conflicts

### 2. nftables Integration

**Current Architecture:**
```
NFTBan manages 3 nftables tables:
- inet nftban_runtime (temporary bans with timeout)
- ip nftban_v4 (permanent IPv4 rules)
- ip6 nftban_v6 (permanent IPv6 rules)
```

**Questions:**
- Does this multi-table approach align with AlmaLinux best practices?
- Are there any known conflicts with AlmaLinux's default firewall configuration?
- Should we detect and warn about firewalld presence?

### 3. System Integration

**Current Implementation:**
```
- FHS-compliant paths (/etc/nftban, /var/lib/nftban, /usr/lib/nftban)
- systemd timers for automated tasks
- sysusers.d for user/group creation
- tmpfiles.d for runtime directory creation
```

**Questions:**
- Does our FHS compliance meet AlmaLinux packaging guidelines?
- Are there AlmaLinux-specific requirements we should consider?
- Should we integrate with any AlmaLinux-specific tools or services?

### 4. fail2ban Integration

**Current Setup:**
```
- Custom fail2ban action: /etc/fail2ban/action.d/nftban.conf
- NFTBan-specific jails: /etc/fail2ban/jail.d/nftban-*.conf
- All jails use nftban- prefix to prevent conflicts
```

**Questions:**
- Does this approach align with AlmaLinux's fail2ban packaging?
- Are there any known issues with fail2ban + nftables on AlmaLinux 9/10?
- Should we provide different configurations for AlmaLinux vs Rocky?

### 5. SELinux Compatibility

**Current Status:**
- Not yet tested with SELinux enforcing mode
- Planning SELinux policy module for v0.11.0

**Questions:**
- Are there AlmaLinux-specific SELinux considerations?
- Can your team recommend SELinux policy best practices?
- Would AlmaLinux be interested in helping test SELinux integration?

### 6. Package Distribution

**Current Status:**
- Providing RPM packages for EL9/EL10
- Following Fedora packaging guidelines
- Considering EPEL submission in future

**Questions:**
- Would NFTBan be suitable for AlmaLinux's official repositories?
- What are the requirements for inclusion consideration?
- Are there AlmaLinux-specific packaging policies we should follow?

---

## Additional Information

**Testing Environment:**
- Currently tested on Rocky Linux 9, Rocky Linux 10, and AlmaLinux 9
- All tests passing with current architecture
- No known issues, but seeking validation from distribution experts

**Documentation:**
- Installation Guide: docs/guides/installation.md
- Architecture Overview: docs/architecture/NFTABLES_V10_ARCHITECTURE_FINAL.md
- Repository Setup: docs/guides/REPOSITORY-SETUP.md

**Community:**
- Open to feedback and contributions
- Willing to adapt architecture to align with AlmaLinux best practices
- Committed to maintaining compatibility with RHEL ecosystem

---

## Specific Clarifications Needed

1. **CRB Repository:**
   - Is `crb enable` the official recommended method?
   - Are there alternatives we should document?
   - Will CRB remain available in future AlmaLinux versions?

2. **fail2ban-server vs fail2ban:**
   - We recommend `fail2ban-server` to avoid firewalld dependency
   - Is this the correct approach for AlmaLinux?
   - Are there plans to split fail2ban packages differently?

3. **nftables + firewalld Coexistence:**
   - Should NFTBan detect and warn about firewalld?
   - Can nftables and firewalld coexist safely?
   - What's AlmaLinux's official position on nftables vs firewalld?

---

## How You Can Help

- **Architecture Review:** Validate our approach aligns with AlmaLinux philosophy
- **Best Practices:** Point out any AlmaLinux-specific considerations
- **Testing:** We'd welcome AlmaLinux team testing and feedback
- **Documentation:** Suggest improvements to our AlmaLinux-specific docs
- **Future Collaboration:** Explore potential inclusion in AlmaLinux ecosystem

---

## Contact Information

**Project Lead:** Antonios Voulvoulis (ITCMS)
**Email:** contact@nftban.com
**GitHub:** https://github.com/itcmsgr/nftban
**Website:** https://nftban.com

Thank you for your time and for maintaining AlmaLinux. We greatly appreciate your work in the enterprise Linux community and want to ensure NFTBan integrates seamlessly with your distribution.

Best regards,
Antonios Voulvoulis
NFTBan Project Lead

---

## Attachment: Quick Start Guide

For your convenience, here's a quick installation test on AlmaLinux 9:

```bash
# 1. Enable repositories
dnf install -y epel-release
crb enable

# 2. Install dependencies
dnf install -y nftables fail2ban-server

# 3. Install NFTBan (from source for testing)
git clone https://github.com/itcmsgr/nftban.git
cd nftban
sudo ./scripts/install.sh  # Or use RPM package

# 4. Initialize
sudo nftban firewall init

# 5. Verify
sudo nftban fhs
sudo nftban firewall check
```

---

**Note:** This communication template can be adapted for:
- Rocky Linux: devel@lists.rockylinux.org
- CentOS Stream: centos-devel@redhat.com
- Fedora: devel@lists.fedoraproject.org
