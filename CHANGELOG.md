# NFTBan Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **History reset.** Pre-v1.79.2 releases are recorded as git tags and on
> the GitHub Releases page (`gh release list`). From v1.79.2 forward, every
> tagged release MUST have a CHANGELOG entry written before tagging.

---

## [1.79.3] - 2026-04-09

**BUG-19 hotfix.** DirectAdmin path keys are now universal across all distro
families. The v1.79.2 schema incorrectly assumed DA only runs on RHEL and
marked DA keys as `n/a` on Debian/Ubuntu. srv3 (Ubuntu 22 + DA) proved that
wrong: pre-v1.79.2 srv3 emitted `directadmin_login_fail` events, post-v1.79.2
the parser was disabled by the n/a literal.

### Fixed

- **BUG-19** — debian-11/12/13/14, ubuntu-22, ubuntu-24 confs now declare
  `directadmin_login_log = /var/log/directadmin/login.log` and
  `directadmin_security_log = /var/log/directadmin/security.log` (real paths,
  not `n/a`).
- `validate_distro_configs.sh` updated: DA path keys are required on every
  family with a real path; the `n/a` literal is no longer accepted for DA keys.
- `TestAllDistros_HaveAllRequiredKeys` updated to require real DA paths on
  every distro conf, not just RHEL.

### Affected hosts

srv3 (Ubuntu 22 + DA) regains DirectAdmin parser binding after upgrade. Other
hosts unchanged. lab2 (Plesk on Ubuntu, no DA) is unaffected because the
parser only starts when the DA service is detected.

### Verification

`bash cli/lib/nftban/tests/validate_distro_configs.sh etc/nftban/distros` PASS.
`go test ./internal/loginmon/distroconf/` PASS on lab4.

### Refs

- BUG-19 (lab4 + srv3 deploy regression of v1.79.2)
- v1.79.2 (parent release)

---

## [1.79.2] - 2026-04-08

**Truth + coverage foundation.** Parser log paths resolve through a layered
contract rooted in central distro config. Soak v1.79.1 untouched.

### Added
- Go distroconf reader package (BUG-15)
- 18 distro confs populated with mail/MTA/DA/FTP path keys (BUG-14) + CI gate
- `tools/refresh-osv-suppressions.sh` + weekly OSV refresh workflow
- v1.79.2 truth foundation plan, gap matrix, Go pipeline design, decommission roadmap

### Fixed
- BUG-2 — DA parser reads `login.log` + `security.log`
- BUG-4 — cPanel exim path via `exim -bP` fall-through
- BUG-5 — CLI banner = pure projection of validator JSON (INV-CONS-001)
- BUG-12 — postfix path via `postconf -h maillog_file`
- OSV CI gate — 6 newer stdlib CVEs suppressed under build-target policy
- gosec G204/G304 false positives annotated

### Changed
- `loginmon/module.go startFileWatchers` — 4-layer resolver (distroconf → tool → fallback → MISSING)
- CHANGELOG process — entry required before every tag

### Verification
Lab4 gates: `go build`, `go test`, `go vet`, `validate_distro_configs.sh` all pass.
Main CI on `41f64fd7`: 36/36 success.

### Refs
PR #350. v1.80 backlog: BUG-1, BUG-3, BUG-6, BUG-10, BUG-13 schema.
