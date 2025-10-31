# Rocky Linux CRB Repository - Quick Inquiry

**Purpose:** Validate CRB usage for fail2ban installation
**Target:** Rocky Linux developers
**Status:** Draft

---

## Short Email Template

**Subject:** Clarification: CRB Repository Requirement for fail2ban Installation

**To:** ~devel@lists.rockylinux.org
**Forum:** https://forums.rockylinux.org/ (Development category)

---

Hi Rocky Linux Team,

Quick question about repository best practices for **Rocky Linux 9 and 10**.

**Background:**
I'm documenting installation requirements for NFTBan (nftables firewall tool) which depends on fail2ban.

**Current Documentation:**
```bash
# Rocky Linux 9/10
dnf install -y epel-release
crb enable  # ← Is this correct?
dnf install -y fail2ban-server
```

**Questions:**

1. **Is `crb enable` the official recommended method?**
   - Or should we use: `dnf config-manager --set-enabled crb`?
   - Are there any downsides to enabling CRB permanently?

2. **Why is CRB required for fail2ban?**
   - fail2ban is in EPEL, but installation fails without CRB
   - Which specific dependencies require CRB?

3. **Will CRB remain available long-term?**
   - Is CRB stable across Rocky 9/10 lifecycle?
   - Any plans to change CRB in future releases?

4. **fail2ban vs fail2ban-server:**
   - We recommend `fail2ban-server` to avoid firewalld conflict
   - Is this the right approach for Rocky Linux?

**Why This Matters:**
- Writing user-facing documentation for sysadmins
- Want to recommend the "Rocky Linux Way"
- Ensuring our instructions remain valid long-term

**Current Status:**
- Tested successfully on Rocky 9.5 and Rocky 10.0
- Works perfectly, just want to confirm best practices

Thanks for maintaining Rocky Linux!

**Project:** https://github.com/itcmsgr/nftban
**Docs:** docs/guides/REPOSITORY-SETUP.md

---

Best regards,
Antonios Voulvoulis

---

## Alternative: Forum Post Format

**Title:** [Question] CRB Repository - Best Practice for fail2ban Installation?

**Category:** Development / Packaging

**Body:**

Hi Rocky community,

I'm documenting fail2ban installation for [NFTBan](https://github.com/itcmsgr/nftban) and want to ensure I'm recommending the correct approach.

**Current instructions:**
```bash
sudo dnf install -y epel-release
sudo crb enable
sudo dnf install -y fail2ban-server
```

**Questions:**
1. Is `crb enable` the official way, or should I document `dnf config-manager --set-enabled crb`?
2. Why does fail2ban require CRB? (understanding for documentation)
3. Is CRB stable long-term, or might it be deprecated/renamed?

**Context:**
- Rocky 9.5 and 10.0 tested successfully
- Just want to document the "Rocky Linux Way" properly

Thanks in advance! 🙏

---

## Rocky Linux Mailing List

**Subscribe:** https://lists.resf.org/mailman3/lists/devel.lists.rockylinux.org/

**Send to:** devel@lists.rockylinux.org

---

## Expected Answers (Likely)

Based on Rocky Linux documentation, the expected answers are:

1. **`crb enable` is correct** ✅
   - Simplified command introduced in Rocky 9
   - Equivalent to: `dnf config-manager --set-enabled crb`
   - Official Rocky docs use this method

2. **CRB contains development libraries**
   - EPEL packages may depend on -devel packages
   - These are in CRB (formerly PowerTools)
   - fail2ban dependencies likely include some -devel libs

3. **CRB is stable** ✅
   - Part of RHEL ecosystem (CodeReady Builder)
   - Will remain throughout Rocky 9/10 lifecycle
   - Name inherited from RHEL 9+

4. **fail2ban-server recommendation** ✅
   - Correct to avoid firewalld conflict
   - fail2ban package pulls in firewalld as dependency
   - fail2ban-server is the minimal install

---

## Action Items

**If confirmed by Rocky team:**
- [x] Keep current documentation as-is
- [ ] Add note: "Officially recommended by Rocky Linux"
- [ ] Reference Rocky docs in our documentation

**If corrections needed:**
- [ ] Update REPOSITORY-SETUP.md
- [ ] Update installation.md
- [ ] Update RPM spec recommendations

---

## References

- Rocky Linux Docs: https://docs.rockylinux.org/
- EPEL Documentation: https://docs.fedoraproject.org/en-US/epel/
- CRB Information: https://wiki.almalinux.org/repos/AlmaLinux.html#crb

