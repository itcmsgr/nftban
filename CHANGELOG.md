# NFTBan Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **History reset.** Pre-v1.79.2 releases are recorded as git tags and on
> the GitHub Releases page (`gh release list`). From v1.79.2 forward, every
> tagged release MUST have a CHANGELOG entry written before tagging.

---

## [1.79.4] - 2026-04-11

**BOTGUARD-REBUILD-UX hotfix.** Fixes a gating bug in `nftban firewall
rebuild`, `reload`, and `reset` that caused BotGuard-enabled hosts to
unnecessarily trigger the post-rebuild rollback path. Stable-line hotfix
off v1.79.3; contains no v1.80 feature work.

### Fixed

- **BOTGUARD-REBUILD-UX** — three module-restore sites in
  `cli/lib/nftban/cli/cmd_firewall.sh` (`firewall_reload`,
  `firewall_rebuild` Step 10, `firewall_reset` Step 8) read the wrong
  config key `BOTGUARD_ENABLED` instead of the canonical
  `HTTP_BOTGUARD_ENABLED` used everywhere else in the codebase
  (cmd_botguard.sh, cmd_status.sh, health checks, exporter, doctor,
  data/config-schema.json). The grep returned empty, the local fell
  through to `"false"`, the existing `nftban botguard enable` re-init
  path silently no-op'd, post-rebuild validation saw transient missing
  helper chains, and the existing PROTECTED→degraded rollback fired
  unnecessarily. srv1 was the only fleet host with
  `HTTP_BOTGUARD_ENABLED=true` in production, so it was the only host
  that surfaced the bug in the wild.

### Added

- `cli/lib/nftban/cli/cmd_firewall.sh` — new private helper
  `_firewall_botguard_is_enabled` that centralises the canonical-key
  read. The three duplicated inline grep blocks now route through this
  helper, making future drift impossible.
- `cli/lib/nftban/tests/test_botguard_rebuild_sequencing.sh` — 10 hermetic
  unit assertions covering positive gating, negative gating, fall-through
  semantics, legacy-key-ignored regression guard, and Step 10 ordering
  invariant.
- `cli/lib/nftban/tests/merge_gate_botguard_rebuild_log.sh` — runnable
  merge-gate parser that reads a captured `nftban firewall rebuild` log
  and asserts Step 10 fired, gating decision matches host config, final
  status PROTECTED, no rollback. Two modes: default (BotGuard enabled)
  and `--disabled` (no-regression).

### Not changed

- No sequencing change. Step 10 of `firewall_rebuild` was already
  correctly placed before POST-rebuild validation.
- No parser code.
- No scoring logic.
- No pipeline code (no Phase A–E content in this release).
- No base firewall enforcement.
- No BotGuard architecture change.
- No new CLI surface.
- No new config knob.
- No config-resolution semantics change — existing `.local` fall-through
  behaviour pinned by regression test.
- Existing rollback safety net unchanged.

### Verification

Lab-host merge-gate runs (2026-04-11):

| Host | Mode | Gate result |
|---|---|---|
| lab4 | `--disabled` | `MERGE GATE: PASS (disabled mode)` 5/5 |
| lab2 | `--disabled` | `MERGE GATE: PASS (disabled mode)` 5/5 |
| monitor | enabled (natural) | `MERGE GATE: PASS (enabled mode)` 6/6 |
| srv1 | enabled (original failure host) | `MERGE GATE: PASS (enabled mode)` 6/6 |

srv1 post-rebuild: chain count 18 → 18 (no drop), all 12 BotGuard sets
present, jump rules active on both v4 and v6 input chains, validator
returns `protected`. Unit test 10/10 green. CI on `3f4b626c` (main):
46/46 checks SUCCESS.

### Affected hosts

srv1 (CentOS Stream 10 + DirectAdmin + OpenLiteSpeed + real-traffic
BotGuard) is the only fleet host that surfaced the bug. This RPM gives
srv1 a clean package upgrade path without pulling in v1.80 Phase A–E
pipeline work, preserving srv1's CONTROL role in the pipeline
decommission soak (ends 2026-04-23).

### Refs

- PR itcmsgr/nftban#368 (main branch commit 3f4b626c)
- V1.80_ROADMAP/MASTER_TODO.md item `BOTGUARD-REBUILD-UX` (RESOLVED 2026-04-11)
- V1.80_ROADMAP/PARSER_DECOMMISSION_GATES.md §5 (RESOLVED 2026-04-11)

### Soak impact

v1.79.1 soak and pipeline soak are both untouched. v1.79.4 is a
stable-line hotfix deploy target for srv1 only.

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
