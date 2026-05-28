# NFTBan Release Gate (2026)

Every release must pass this checklist.

---

## A. Platform Validation

### Tier 0 (required)

- [ ] Build succeeds on Ubuntu 24.04
- [ ] Build succeeds on Ubuntu 26.04
- [ ] Build succeeds on Debian 12
- [ ] Build succeeds on Rocky Linux 9

### Tier 1 (informational)

- [ ] Rocky Linux 10 (warn-only)
- [ ] Debian 13 (warn-only)

---

## B. Packaging & Install

- [ ] DEB package installs cleanly
- [ ] RPM package installs cleanly
- [ ] No postinst script creates directories manually
- [ ] sysusers.d and tmpfiles.d executed successfully
- [ ] No recursive chmod/chown present

---

## C. Filesystem & Permissions

- [ ] `/etc/nftban` is root-owned
- [ ] `/var/lib/nftban` is root:nftban
- [ ] Daemon-writable dirs are nftban:nftban
- [ ] `/run/nftban` created via tmpfiles
- [ ] Executables have +x

---

## D. Networking

- [ ] nftables rules use `inet` family
- [ ] No iptables legacy dependencies
- [ ] `nft` binary resolved via distro config

---

## E. Polkit

- [ ] Correct `polkit_rules_dir` per distro
- [ ] Rules installed from generated paths
- [ ] No wildcards or unsafe actions

---

## F. Receipt & Audit

- [ ] Receipt generated on install
- [ ] Receipt records distro resolution
- [ ] `nftban audit receipt --strict` passes on Tier 0
- [ ] Audit differences are zero

---

## G. Documentation Freeze

- [ ] README platform table unchanged or intentionally updated
- [ ] CONTRIBUTING.md unchanged or intentionally updated
- [ ] Any contract change documented and approved

---

## Final Release Rule

**If any Tier 0 check fails, the release is blocked.**

---

## Version Bump Checklist

Before tagging a release:

- [ ] VERSION file updated
- [ ] CHANGELOG.md updated with release notes
- [ ] All generated files regenerated (`./build/generate-fhs-outputs.sh`)
- [ ] Pre-commit hooks pass
- [ ] Health check passes (`.github/ci/health_check.sh`)
- [ ] Git tag created with version

---

*This checklist is frozen for 2026.*
