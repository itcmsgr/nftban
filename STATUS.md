# NFTBan Development Project Health Status

**Status:** ⚠️ Warning
**Last Updated:** 2026-07-28 UTC
**Current Development Version:** v1.228.4 — `RELEASE_PREP`, **NOT PUBLISHED**
**Latest Published Release:** v1.228.0 (tag `v1.228.0` → `0c2a0d9a`, published 2026-07-27, 15 assets)
**Release State:** `RELEASE_PREP`

> **Development version ≠ published version.** `VERSION` in this tree is the version being
> *prepared*; it becomes the published release only when a tag exists and assets are published.
> A single `Version:` field could not express that distinction and previously implied the
> development version was live. Publication closure updates *Latest Published Release*, never
> release-prep. See `docs/RUNTIME_MODE_AUTHORITY_CONTRACT.md` for the governing
> `DEFINED ≠ REACHABLE` / `CONFIGURED ≠ EFFECTIVE` family of inequalities.

---

## Active Release Train

**v1.228.4 — a failed read is no longer proof of absence — `RELEASE_PREP`, NOT PUBLISHED** — *Three PRs merged to `main` (#1178 `3d1be747` nft consumer authority inventory + guard · #1179 `30900f04` AF_NETLINK correction across six units · #1180 `18eafc40` typed nft probe with fail-closed absence and a monotonic degraded latch). `TAG = NOT_CREATED` · `PUBLICATION = NOT_STARTED` · `FLEET = NOT_STARTED` · `GO_RELEASE = NO`. Governing invariant: a failed read is not evidence of absence, and only a VERIFIED absence may authorise a mutation. Six units sandboxed away `AF_NETLINK`, so every `nft` call inside them failed `EAFNOSUPPORT` and the "firewall table absent" message ran ~927 times per host while both tables existed; `nftban-queue` and `nftban-botscan` deliberately still WITHHOLD `AF_NETLINK`. The probe now yields `PRESENT | ABSENT | CANNOT_READ`, establishes readability POSITIVELY, and latches degradation monotonically so a later success cannot erase an earlier blindness. `PRODUCT_CODE_CHANGE = shell + systemd units + CI` · `DAEMON_CHANGE = NO` · `SCHEMA_CHANGE = NO`. **Package-native upgrade validation v1.228.2 → v1.228.4 on lab2 (DEB) and lab4 (EL9/RPM) is the required gate before publication** — the two-lab 29/29 negative-control proof used a file overlay, not installed packages. SELinux Enforcing remains UNTESTED (both labs Permissive/SELinux-less); the EL9 Enforcing clean-install blocker is the v1.228.5 lane.*

**v1.228.2 — CLI truth: a command that cannot do its work no longer reports success — `RELEASE_PREP`, NOT PUBLISHED** — *Four PRs merged to `main` (#1170 `081ffb71` Suricata retirement · #1171 `d0289184` router exit truth · #1172 `f2042f9d` command-count authority + advertising parity · #1173 `3be2ed09` snapshot dispatch truth). `TAG = NOT_CREATED` · `PUBLICATION = NOT_STARTED` · `FLEET = NOT_STARTED` · `GO_RELEASE = NO`. **`v1.228.1` was never published** — the lane originally numbered `.1` is deferred, because publishing it after `.2` would present as a downgrade to dpkg/rpm version comparison. Governing invariant: a component that failed to perform its required work must not report success. The router returned `0` when it had nothing to run (8 library files dispatchable, exiting 0 silently); `nftban snapshot` created snapshots when asked to list, restore or help, including hourly in production via `nftban-snapshot.service`. Suricata is retired to a dormant placeholder — 3 units removed from both package families, public surface reduced to `status`+`help`, registry narrowed 42→2 subcommands, 26 wrong or dead completion tokens removed. Four guards that measured the wrong thing were corrected: a count guard pinning a literal that punished correctness, an allowlist matching comment prose, a phantom-subcommand blind spot across all five existing guards, and a systemd-token gap. `PRODUCT_CODE_CHANGE = shell + CI only` · `DAEMON_CHANGE = NO` · `SCHEMA_CHANGE = NO` (nft 1.84.0 / config 1.1.0) · no exit-code values renumbered. **Required gate before publication: upgrade from v1.228.0 on lab2 (DEB) and lab4 (EL9/RPM) with legacy NFTBan Suricata units ENABLED** — proving the units are stopped, disabled and removed with no restart loop and upstream Suricata untouched. Final `main` tree verified byte-identical to the validated cumulative tree.*

**v1.228.0 — Post-install outcome truth: the package boundary reports whether the install actually succeeded — `RELEASE_PREP`, NOT PUBLISHED** — *Implementation MERGED to `main` (PR #1166, squash `4676480f`). `TAG = NOT_CREATED` · `PUBLICATION = NOT_STARTED` · `FLEET = NOT_STARTED` · `GO_RELEASE = NO`. DEB `postinst` and RPM `%post` now run a read-only verifier after every installer outcome and emit machine-readable tokens, so a package manager printing `Complete!` over a failed install is distinguishable from a verified one. Ledger: `PACKAGE_POSTINSTALL_OUTCOME_TRUTH = MUTATION_PROVEN` (T8 44/44 on both DEB and RPM against the real verifier and the installed binary, outcome parity PASS). Explicitly **NOT** promoted: `PACKAGE_PRETRANSITION_T9_BOUNDARY = NOT_YET_VERIFIED` (no shipped injection hook; the lifecycle L5 case remains an analogue, not a proof) and `LAB4_SELINUX_ENFORCING = NOT_VALIDATED` (lab4 SELinux is Disabled; the v1.226 waiver stands — the separate stock-Enforcing tgt-a9 result is different host coverage and must not be restated as a lab4 Enforcing PASS). Post-merge CI attempt 1 recorded 2 non-required failures (`Fuzz Tests` = flaky 30s fuzz-deadline with no reproducer, first seen 18 days earlier on a metadata-only commit; `Build Docker Image` = ghcr.io login transport timeout); both classified with evidence and PASSED on an exact-SHA rerun with no source mutation — the failed attempts are retained as permanent history, not erased. Remaining confirmed runtime-mode defects are recorded in `docs/MODE_ADMISSION_LEDGER.md` and are **not** corrected in this release.*

**v1.227.0 — RELEASED (2026-07-24)** — *tag `v1.227.0` → `f1602764`, 15 assets. Scope detail is held in the roadmap register rather than restated here.*

**v1.226.0 — RELEASED (2026-07-23)** — *tag `v1.226.0` → `28c17fc5`, 15 assets. Scope detail is held in the roadmap register rather than restated here.*

**v1.225.0 — Update-render truth, completion parity & uninstall firewall-ownership message — RELEASED, FLEET-LIVE 11/11 (2026-07-22)** — *`RELEASE_CLASS = SHELL_PACKAGING_TESTINFRA_MAINTENANCE`. `PUBLISHED` (tag `v1.225.0`→`c84ad25a`, 13 assets, Release+Docker+SLSA GREEN), `FLEET_LIVE = 11/11` (production 9/9 + labs 2/2), `ENTRY_SOAK = PASS`, `FULL_MULTI_DAY_SOAK = NOT_CLAIMED`. Shell/packaging/test-infra only on RELEASE_COMMIT `c84ad25a` (PR #1134 update-render truth, #1135 health-resources completion, #1119 uninstall ownership message — all MERGED; installed-RBL-launcher forensically VERIFIED_FIXED in v1.220.1, no v1.225.0 code). `PRODUCT_CODE_CHANGE = 0`, `GO_FILES_CHANGED = 0` — `nftband`/`nftban-core`/`nftban-installer` expected byte-identical to v1.224.0 (identical build metadata). `SCHEMA_CHANGE = NO` (nft 1.84.0 / config 1.1.0). Four hermetic regression guards now execute in blocking Policy Gates (targeted Phase-A correction; NOT full test-suite governance — `OPEN_TEST_SUITE_SINGLE_AUTHORITY` remains open). Gates PASSED: package-native lab2 DEB + lab4 RPM (real DEB remove/purge + RPM final-erase message validated) → published → dns2 canary → serial fleet 11/11 (labs on official published package). PUBLISHED_EQUALS_RC = PASS_BY_SEMANTIC_AND_BINARY_EQUIVALENCE (payload byte-identical, same VCS revision; raw package SHA differs — release rebuild, NOT_EXPECTED to match). Release notes carry the standing GitHub `refs/pull/*` history residual-risk note (residual OPEN with GitHub Support; current tree/packages/docs clean).*

**v1.224.0 — Health-resource parser & classifier truth hardening — RELEASED, FLEET-LIVE 11/11 (2026-07-22)** — *tag `v1.224.0` → `263d8fbf`; production 9/9 + labs 2/2 = 11/11; `ENTRY_SOAK = PASS`, `FULL_MULTI_DAY_SOAK = NOT_CLAIMED`. `RELEASE_CLASS = MAINTENANCE_TRUTH_HARDENING`. Standalone R2 / Lane B release built on implementation commit `dc00c639` (impl PR #1129→#1132; `LATEST_RELEASE = v1.224.0`). Hardens the health-resource parser/classifier/predicate: rejects empty/whitespace/negative systemd memory values, stops invalid live values becoming a fabricated zero-sized verdict, surfaces external/admin drop-in authority before ordinary numeric-match, self-defends the classifier against infinity, and fails closed on unknown/empty tier — while preserving known small advisory + medium/large required behavior. `PRODUCT_FILES = internal/healthresource/{systemd,generate,verdict}.go` + `cmd/nftban-core/cmd_resources.go` (nftban-core + installer only). `DAEMON_CHANGE = NO` (nftband byte-identical to v1.223.0 — reproducible-build proven; does not link the changed package). `SCHEMA_CHANGE = NO` (nft 1.84.0 / config 1.1.0). `FLEET_BEHAVIOR_FLIP_CURRENTLY_EXPECTED = NO`. Package-native PASS lab2 DEB + lab4 RPM (install COMMITTED, validate rc0, human/JSON parity, NFTBan-only=ACTIVE_MATCH, reversible external-drop-in→EXTERNAL_OVERRIDE_CONFLICT→restored). Read-only fleet evidence (point-in-time, does NOT eliminate the dns2 canary): 9/9 production hosts = known tier · NFTBan-only health drop-in · ACTIVE_MATCH · no external sibling drop-in. Lane D arithmetic hardening excluded (daemon-linked, separate rollback domain, remains OPEN).*

**v1.223.0 — Verdict-truth stabilization: authoritative health-resource verdict across all validation paths — RELEASED (superseded by v1.224.0)** — *verdict-truth fix on `main` (#1129, squash `13d06f29`); supersedes the halted v1.222.1 fleet rollout and preserves its verified health-OOM correction + structured failed-unit truth. One `ResolveHealthResourceVerdict` resolves an authoritative verdict in every validation entry point (install/upgrade/repair/resume/revalidate/update-force/validation-retry), re-resolved per pass — fixes false-DEGRADED on `--repair` (`BUG-REPAIR-HEALTH-VERDICT-EMPTY`) and false-COMMITTED on `--revalidate` (`BUG-REVALIDATE-MASKS-HEALTH-DEGRADE`); live truth wins over stale persisted state; UNAVAILABLE fail-closed for required tiers; CLI==installer predicate (`BUG-RESOURCES-VERDICT-TIER-BLIND`); resource-policy DEGRADED no longer claims a failed unit. Bundles approved mail recipient/subject/help UX (no delivery-authority change; no direct module send). No daemon/firewall behavior change; no nft schema change (1.84.0); no config-schema change. Deferred: v1.224.0 debt (cgroup-tier-desync, classify-external-override, infinity self-defense, parse cleanup, `PERF-VALIDATOR-NFT-JSON-OVERFETCH`).*

**v1.222.1 — HEALTH-OOM hotfix: health-service memory + structured failed-unit truth — PUBLISHED (fleet rollout halted; superseded by v1.223.0)** — *patch hotfix on `main` (#1126, squash `cf772724`; tag `v1.222.1`); fixes 4 confirmed v1.222.0 defects — health-service cgroup-OOM (profile-derived MemoryHigh/MemoryMax drop-in via one canonical resource-tier authority) + structured failed-unit `SERVICES_FAILED` propagation with per-unit attribution (hardcoded botscan removed) + read-only `nftban health resources` diagnostics. Primary OOM fix + structured failed-unit work VERIFIED on the dns2 medium canary; the fleet rollout was halted by a health-verdict-propagation defect (repair/revalidate false verdicts) fixed in v1.223.0. No daemon/firewall behavior change; no nft schema change (1.84.0); no config-schema change.*

**v1.222.0 — Lifecycle forensic-log correctness & bounded log-retention/rotation safety — RELEASED (superseded by v1.222.1)** — *one combined release, two serial gates (Gate A + Gate B), both merged to `main`; VERSION-only release-prep; shell + Go (`internal/logretention`, `internal/safety`, consumed only by `nftban-core`); `nftband` daemon binary source unchanged (daemon byte-identical); no nft schema change (1.84.0); no config-schema change (1.1.0 / schema_version 1).*

| Field | State |
|-------|-------|
| Scope | **Gate A** — per-run update forensic record correctness (human.log written; installer-child slice; aligned structured+human evidence). **Gate B** — profile/capacity-derived **bounded** retention-policy generation; read-only `nftban logs retention status [--json]`; operator config preserved across DEB/RPM upgrades; generated logrotate = derived state (`%ghost`/not-in-DEB-payload); single `Readiness()` authority (generated + bounded fallback); installer `COMMITTED` gated on a valid active policy; whole-set incl. Suricata; crash-consistent durable multi-file activation + recovery; numeric rollout-acceptance evidence |
| Files | Gate A: `cli/lib/nftban/cli/cmd_update_helpers.sh` + support bundle (shell). Gate B: `internal/logretention/*`, `internal/safety/{file,durable}.go`, `cmd/nftban-core/cmd_logretention.go`, `cli/lib/nftban/cli/cmd_logs.sh`, packaging (`build_nftban.sh`, `deb/postinst`), `conf.d/logs.conf`, config-schema keys, guards + tests |
| Product PRs | Gate A **MERGED** #1122 → `main` `526b83f3`; Gate B **MERGED** #1123 → `main` `42af7fea` (squash; both CI-green) |
| Validation | `go test ./internal/... ./cmd/...` 84/0 on lab2 (DEB/Ubuntu 24.04) + lab4 (RPM/Alma 9.8/el9); Gate B shell guards green; package-native DEB + RPM builds SHA-chain verified; independent transaction-safety audits (F1/F2/F3 + T1-A/B/C) closed, 0 open findings |
| Daemon change class | **NONE** (`nftband` daemon binary source identical; only `nftban-core` gains the log-retention surface) |
| Explicit non-goals | no active disk-pressure auto-deletion (watchdog alert-only); no mutating retention CLI; no time-first redesign; no single-policy-file simplification; no event-driven regen redesign; **no fleet deployment yet; no canary result yet** |
| Tag / Publication | **NOT_CREATED / NOT_STARTED** (release-prep only; TAG/PUBLISH + package-native lab validation + canary + FLEET on HOLD pending explicit GOs) |

**v1.221.4 — BotScan HTTP log-source validity & health truth (R22A) — RELEASED (Latest; tag `v1.221.4`)** — *shell-only; daemon binary source identical to v1.221.3; no nft schema change (1.84.0); no config-schema change; no enforcement-policy change. Superseded as the active release-prep candidate by v1.222.0 above.*

| Field | State |
|-------|-------|
| Scope | cPanel/Plesk/generic HTTP-log **source validity**: class-exclude FTP/offset/bandwidth/state/mail/non-HTTP files (in discovery **and** the privileged collector) + content-signature validation; truthful source-health states (`SOURCE_ACTIVE`/`SOURCE_VALID_QUIET`/`NEVER_OBSERVED`/`INVALID_SOURCE`); DirectAdmin behavior preserved |
| Files | `cli/lib/nftban/lib/nftban_http_logs.sh` + `cli/sbin/nftban-botscan-collector` (shell) + BotScan status renderers + tests |
| Product PR | **MERGED** #1120 → `main` `d713c3b7` (CI green) |
| Validation | package-native DEB lab2/Plesk + RPM lab4/cPanel (false-healthy eliminated at the collector source); **production canary srv2 (DirectAdmin, 186 domains) PASS** — no over-exclusion (`collected=12 skipped=0`), verdict OK, no `WARN_NO_LOGS` regression, validate rc0, schema 1.84.0, connectivity preserved |
| Daemon change class | **NONE** (shell-only; daemon byte-source identical) |
| Tag / Publication | **CREATED / PUBLISHED** — tag `v1.221.4` (GitHub release, Latest, 2026-07-18) |
| Canary/labs note | srv2 + lab2 + lab4 temporarily run R22A code labeled `1.221.3`; the official `1.221.4` package normalizes package identity during the later fleet rollout |

**v1.221.3 — P1 UNINSTALL FIREWALL-SAFETY HOTFIX — RELEASED, fleet-live 11/11** — *packaging-only; no daemon/nft-schema change. Supersedes v1.221.2 for deployment.*

| Field | State |
|-------|-------|
| Defect | **CONFIRMED_V1_221_2_PACKAGE_NATIVE_UNINSTALL_CONNECTIVITY_DEFECT** — DEB `remove)` flushed `ip/ip6 nftban` but kept the `policy drop` input chain (0 accept rules) → dropped all inbound (SSH/ping) until reboot; iface/IP/route/sshd stayed healthy. Runtime + serial-console proven on published v1.221.2. Old (v1.38.0-era) path; not an RBL/release-workflow regression. |
| Fix | `packaging/deb/postrm` `remove)` now **deletes** `ip/ip6 nftban` tables (matches safe purge/RPM-erase); config retained; no reboot needed |
| Guard | NEW `scripts/ci/check-uninstall-firewall-safety.sh` (wired into ci-architecture.yml) — rejects flush-without-delete + negative self-test |
| Status | PR in prep (this hotfix) |
| v1.221.2 | PUBLISHED but **DEPLOYMENT_BLOCKED** by this defect (preserved, not rewritten) |
| Rollout | lab2 DEB + lab4 RPM full uninstall-lifecycle re-validation → canary → fleet, all PENDING |

**v1.221.2 — PUBLISHED · ARTIFACTS_VERIFIED · DEPLOYMENT_BLOCKED (uninstall defect) · superseded by v1.221.3 for deployment** — *release-automation repair only; same product code as v1.221.0/v1.221.1 (no daemon/nft-schema change).*

| Field | State |
|-------|-------|
| Product implementation | MERGED (#1106 privacy, #1107 opqueue, #1108 build-provenance, #1109 lifecycle) |
| Workflow Mode-3 + jq prerequisite | MERGED (#1111 f4fbb859, #1114 1f274b7b) |
| Publication-path fix (shared assembly verifier + CI guard) | MERGED (#1115 d47416b2) |
| Relative `--dist-dir` verifier fix | MERGED (#1116 → `main` 536db592) |
| **Tag v1.221.2** | **CREATED** — object `1188d650` → target `536db592919d7d5dc3c77d6526678fbcd948a0b9` |
| **Release** | **PUBLISHED** (non-draft, non-prerelease) · Release Packages 29618953508 ✅ · Docker 29618953526 ✅ · SLSA 29619105199 ✅ |
| **Assets** | **15/15, 0 duplicates** (5 DEB + 2 RPM + nftband + nftban-core + .intoto.jsonl + sbom + SHA256SUMS + SHA256SUMS.build + MANIFEST + VERIFY) |
| **Checksums** | SHA256SUMS ✅ == SHA256SUMS.build ✅ (8 entries: packages+nftband; nftban-core via SLSA intoto) · DEB↔RPM parity ✅ (nftban-core, nftband) · embedded commit `536db592` |
| **SLSA provenance** | VERIFIED — intoto subject sha256 matches `nftban-core-linux-amd64` (slsa.dev/provenance/v0.2) |
| **Docker tags** | `v1.221.2` · `1.221.2` · `1.221` · `sha-536db592` |
| Local KVM qualification | PENDING (Phase-4 matrix on official assets) |
| Remote lab / canary / fleet | PENDING |

**Superseded, incomplete publications (both preserved, never rewritten):**
- **v1.221.0** — tag `→ a9ab66b2` · Docker PUBLISHED · GitHub release ABSENT (release.yml called bare `build_nftban.sh`; no `jq`).
- **v1.221.1** — tag `→ 1f274b7b` · Docker PUBLISHED · GitHub release ABSENT (assembly-verify step's trailing bare conditional failed the push path). Both Docker image sets + failure evidence retained.

Register state: publication defects `OPEN_RELEASE_YML_MODE3_PREBUILT_GAP`, `OPEN_RELEASE_YML_MODE3_JQ_PREREQUISITE_GAP`, `OPEN_RELEASE_YML_PUSH_PATH_ASSEMBLY_VERIFY_FOOTGUN` are `SHIPPED_IN=v1.221.2` (the repaired release workflow is now published + asset-verified). NOT closed as a train: local KVM qualification, remote-lab, canary, and fleet rollout remain; validation-dependent findings (`SUSPECTED_NFTBAN_UNINSTALL_TRANSIENT_CONNECTIVITY_DROP`, `OPEN_SLSA_STANDALONE_BINARY_VERSION_LDFLAGS`) stay OPEN. The v1.221.2 release train is NOT closed.

**Current published / fleet baseline: v1.220.10** — managed fleet 11/11 (production 9/9, labs 2/2), daemon `bc9650be`, nft schema 1, validator/status schema 1.84.0. v1.221.2 is PUBLISHED but not yet the fleet baseline (rollout pending qualification).

---

## Summary

| Metric | Value |
|--------|-------|
| Total Checks | 29 |
| Passed | ✅ 29 |
| Failed | ❌ 0 |
| Warnings | ⚠️ 6 |

---

## Check Results

### ✅ Passed Checks
- **Shell Quality**: shellcheck, shfmt
- **Go Quality**: go vet, gofmt, go test
- **Documentation**: markdownlint
- **Configuration**: yamllint
- **Structure**: all critical files present
- **Security**: no obvious issues detected
- **Permissions**: appropriate file permissions
- **NFT Schema**: v1.221.1 alignment verified


### ⚠️ Warnings (Non-Critical)
- shfmt (528 files)
- markdownlint
- gofmt (171 files)
- No Go tests
- Security (1 potential issues)
- NFT Schema alignment (1 potential issues)

---

## Health Categories

### Shell Script Quality
- **shellcheck**: Static analysis for bash scripts
- **shfmt**: Shell script formatting
- **Status**: ✅ Passing

### Go Code Quality
- **go vet**: Go code static analysis
- **gofmt**: Go code formatting
- **go test**: Unit test execution
- **go.mod**: Dependency management
- **Status**: ✅ Passing

### Documentation
- **markdownlint**: Markdown style checking
- **Status**: ✅ Passing

### Project Structure
- **Critical Files**: README, LICENSE, go.mod, build.sh
- **Core Directories**: cli/, cmd/, internal/, pkg/, install/, packaging/
- **Status**: ✅ All present

### Security
- **Secret Scanning**: Basic grep-based detection
- **File Permissions**: World-writable checks
- **Status**: ⚠️ Review recommended

### NFT Schema v1.221.1 Alignment
- **Variable Usage**: Check for hardcoded table names in shell
- **Constants Usage**: Check for hardcoded table names in Go
- **Status**: ✅ Aligned

---

## CI/CD Status

This status report is automatically generated by `.ci/health_check.sh`.

- **Workflow**: Project Health
- **Trigger**: On push to v0.7 branch, weekly schedule
- **Full Logs**: [GitHub Actions](https://github.com/itcmsgr/nftban/actions/workflows/health.yml)

---

## Development Notes

This is the **development branch** for NFTBan v1.221.1. Health checks include:

1. **Code Quality**: Both shell and Go code are validated
2. **Architecture Alignment**: NFT Schema v1.221.1 dual-table architecture
3. **Package Building**: Automated RPM/DEB package generation
4. **Testing**: Unit tests and integration checks

**Note**: This is an automated health check. Manual review may be required for warnings.
