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
- [ ] Every added, renamed or retired configuration key (v1.238+) changes, in the same change: its consumer
      (the code that applies it), `cli/lib/nftban/data/config-schema.json` (so `nftban config validate`
      agrees with the consumer), the shipped defaults and help/docs, and the behaviour for an existing
      operator `.local` (kept and still effective, or reported by `nftban config validate` with the key,
      file, consequence and supported replacement). Operator `.local` lines are never rewritten.

---

## C. Filesystem & Permissions

- [ ] `/etc/nftban` is root-owned
- [ ] `/var/lib/nftban` is root:nftban
- [ ] Daemon-writable dirs are nftban:nftban
- [ ] `/run/nftban` created via tmpfiles
- [ ] Executables have +x

---

## D. Networking

- [ ] nftables rules use the family-split tables `ip nftban` and `ip6 nftban` (no `inet` table)
- [ ] No iptables legacy dependencies
- [ ] `nft` binary resolved via distro config

### D.1 IPv4 / IPv6 coverage (required for every networking fix, v1.238+)

For each fix that touches addresses, CIDRs, sets or rules, the PR and the release list state
**separately for IPv4 and IPv6** one of: `supported` · `verified` (runtime evidence linked) ·
`unsupported` (documented limitation) · `not tested`. Cover each stage that applies:

| Stage | IPv4 | IPv6 |
|---|---|---|
| Input (CLI argument, config file, feed/country data source) | | |
| Address / CIDR parsing and normalisation | | |
| Authority decision (which module/source owns the entry) | | |
| Whitelist precedence (whitelist, exceptions, overlapping ban reasons) | | |
| Kernel application (`ip nftban` / `ip6 nftban` set or rule present) | | |
| Status / `--json` reporting (no unsupported family shown as working, no unknown shown as 0) | | |
| Mixed-family input (both families in one file/command), where applicable | | |

- [ ] Every networking fix in this release has the table above, filled from existing evidence
- [ ] An `unsupported` family is shown as unsupported in help, status and documentation
- [ ] Ban/feed test fixtures are globally routable (reserved ranges are filtered by design)

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

- [ ] **Repository authority confirmed** (`./tools/repo-authority-guard.sh`) — the clone is the
      canonical repository on the post-rewrite history epoch, with no borrowed object store and
      full tag parity. Releasing from a wrong-epoch clone would ship pre-rewrite sources.
- [ ] VERSION file updated
- [ ] CHANGELOG.md updated with release notes
- [ ] All generated files regenerated (`./build/generate-fhs-outputs.sh`)
- [ ] Pre-commit hooks pass
- [ ] Health check passes (`.github/ci/health_check.sh`)
- [ ] Git tag created with version

---

## Embargoed Security Release

For a coordinated-disclosure fix (see [`docs/security/COORDINATED_DISCLOSURE.md`](docs/security/COORDINATED_DISCLOSURE.md)
and [`SECURITY.md`](SECURITY.md)):

- [ ] Report received privately (GitHub Security Advisory or security@nftban.com); handled TLP:RED
- [ ] Fix developed on a private/embargo branch (or GHSA private fork)
- [ ] Validation: full CI + relevant install/runtime-truth/canonization gates + a regression test for the vulnerability class
- [ ] Packages built via the normal pipeline (signing applies once package signing exists — see roadmap Lane 2; not yet available)
- [ ] Advisory drafted: CVSS vector, CWE, affected/fixed versions, VEX if dependency-related
- [ ] **Coordinated release timing** — publish the fixed version and the GitHub Security Advisory together at the agreed time
- [ ] Backport the fix to the "security-fixes-only" prior minor per the supported-versions policy
- [ ] Operator notice via GitHub Security Advisory + release notes (a security-announcement list is planned, not yet available)
- [ ] Post-release: public disclosure + reporter credit; short postmortem + regression guard
- [ ] Rollback: if the hotfix regresses, use the documented rollback/commit-confirm path and re-issue under the same embargo discipline

---

*This checklist is frozen for 2026.*
