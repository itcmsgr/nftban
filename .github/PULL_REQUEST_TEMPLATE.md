## Pull Request

### Description

<!-- Provide a clear and concise description of what this PR does -->

### Type of Change

<!-- Mark with 'x' all that apply -->

- [ ] 🐛 Bug fix (non-breaking change which fixes an issue)
- [ ] ✨ New feature (non-breaking change which adds functionality)
- [ ] 💥 Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] 📝 Documentation update
- [ ] 🎨 Code style/formatting update (no functional changes)
- [ ] ♻️ Refactoring (no functional changes)
- [ ] ⚡ Performance improvement
- [ ] ✅ Test update
- [ ] 🔧 Build/CI update

### Related Issues

<!-- Link to related issues. Use "Fixes #123" to auto-close issues when merged -->

- Fixes #
- Related to #

### Motivation and Context

<!-- Why is this change required? What problem does it solve? -->

### Testing

<!-- Describe the tests you ran to verify your changes -->

**Test Environment:**
- Distribution: <!-- e.g., Rocky Linux 9.3 -->
- Kernel: <!-- uname -r -->
- nftables version: <!-- nft --version -->
- NFTBan version: <!-- nftban --version -->

**Test Commands:**
```bash
# List the commands you used to test this PR
```

**Test Results:**
- [ ] All existing tests pass
- [ ] New tests added and pass
- [ ] Manual testing completed
- [ ] Tested on multiple distributions (if applicable)

### Checklist

<!-- Mark with 'x' all that you have completed -->

- [ ] My code follows the project's [coding standards](../CONTRIBUTING.md)
- [ ] I have performed a self-review of my own code
- [ ] I have commented my code, particularly in hard-to-understand areas
- [ ] I have made corresponding changes to the documentation
- [ ] My changes generate no new warnings
- [ ] I have added tests that prove my fix is effective or that my feature works
- [ ] New and existing unit tests pass locally with my changes
- [ ] Any dependent changes have been merged and published
- [ ] I have signed off my commits (DCO) with `git commit -s`
- [ ] I have updated CHANGELOG.md (if applicable)

### Security Considerations

<!-- If this PR has security implications, describe them here -->

- [ ] This PR has no security implications
- [ ] I have reviewed this PR for security vulnerabilities
- [ ] Security considerations documented in SECURITY.md (if applicable)

### Screenshots (if applicable)

<!-- Add screenshots to help explain your changes -->

### Additional Notes

<!-- Any additional information that reviewers should know -->

---

### Runtime Mode Authority — MANDATORY for module/mode changes

<!--
REQUIRED if this PR touches: modules, modes (auto/classic/suricata/hybrid), Suricata,
detection, banning, health, or status.  Delete this whole section only if none apply.

Authority: docs/RUNTIME_MODE_AUTHORITY_CONTRACT.md  ·  ADR-0001
AN UNANSWERED FIELD BLOCKS MERGE. "N/A" is an answer; blank is not.

A feature is not merely code that exists. A feature is a complete production path that is
REACHABLE, OBSERVABLE, ENFORCEABLE, TESTABLE and RECOVERABLE.

  DEFINED        != REACHABLE
  CONFIGURED     != EFFECTIVE
  ENABLED        != DETECTING
  RUNNING        != RECEIVING INPUT
  DETECTED       != ENFORCED
  SET MEMBERSHIP != FIREWALL BLOCK
  PASS           != INJECTION PROVEN
-->

- **MODULE:**
- **CONFIGURED MODES:**
- **EFFECTIVE MODE RESOLUTION:** <!-- resolver + where the result is recorded -->
- **PRODUCTION ENTRYPOINT:** <!-- service/timer/scheduler/dispatcher, not a private helper -->
- **DETECTION AUTHORITY:** <!-- kernel nftables | shell detector | EVE consumer | Go publisher -->
- **BAN AUTHORITY:**
- **ENFORCEMENT AUTHORITY:** <!-- set -> referencing rule -> HOOKED chain -> drop/reject -->
- **HEALTH AUTHORITY:** <!-- proves the SELECTED mode is active -->
- **LOG SOURCE:**
- **CONSUMER IDENTITY:** <!-- the uid/gid actually reading that source -->
- **ZERO-INPUT BEHAVIOR:** <!-- ACTIVE_ZERO_INPUT vs SOURCE_MISSING vs reported healthy -->
- **FALLBACK BEHAVIOR:** <!-- and whether it is silent -->
- **HYBRID DEDUP:** <!-- canonical event identity + single ban authority, or N/A -->
- **STATIC TEST:**
- **MUTATION TEST:** <!-- the guard was SEEN to fail when the behaviour was removed -->
- **CROSS-VM TEST:** <!-- real traffic from a separate host, or explicitly not yet -->
- **UNPROVEN ITEMS:** <!-- state them; do not leave blank to imply completeness -->
- **MODE LEDGER UPDATED:** <!-- docs/MODE_ADMISSION_LEDGER.md row + new status -->

---

**By submitting this pull request, I confirm that:**
1. My contribution is made under the MPL-2.0 license
2. I have signed off my commits with the DCO (Developer Certificate of Origin)
3. I have read and agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md)
4. I understand this may be reviewed, modified, or rejected

**Thank you for contributing to NFTBan! 🎉**
