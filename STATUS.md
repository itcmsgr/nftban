# NFTBan — Integrity & Build Status

> **Policy:** Main branch is always green. Failed CI blocks merge.
> No manual overrides for truth-critical checks. Evidence over claims.

**Version (this commit):** v1.110.0 — sourced from [`/VERSION`](VERSION); static per commit, not auto-updated. For the current released tag see [GitHub releases](https://github.com/itcmsgr/nftban/releases) or the README badge.
**Release lane:** v1.110.0 (2026-05-12) — V110 module-isolation moderate-cut lane on top of v1.109.0. Closes R-10 (module-isolation CI invariant lint) and R-12 (typed `Status().Extra` per module) from `AUDIT_190_MODULE_ISOLATION/REMEDIATION_PLAN.md` via the V110 narrow lane. **No daemon behavior change.** **No code change in `nftban-core` / `nftband` daemons.** Schema frozen at `1.83.0`. No metrics, portal, install API, panel-adapter, FHS-ATG, Self-Healing, POLKIT-AUTHORITY, dns2-migration, eventbus, packaging, or systemd implementation changes. **PRs (in merge order):** **#599** (sq `c8050d9e`) — R-10 module-isolation static-analysis CI lint enforcing three invariants: A1 distinct `ModuleName` across registered `Module` implementers (auto-discovered via `func (m *Module) Name() string`), A2 every `eventbus.NewEvent(eventbus.EventBan, ...)` publish uses the calling module's own `ModuleName` const (rejects cross-attribution + string-literal sources), A3 `Status().Extra` cross-module check (locks baseline allowlist `mode` / `suricata_available` / `tracked_ips` at v1.109.0 HEAD and blocks NEW cross-module key introductions). 2 files (`scripts/lint-module-isolation.sh` NEW shellcheck-clean + `.github/workflows/ci-architecture.yml` new step inserted after V108 Item 3 heredoc-safety using `bash scripts/...` invocation matching the V108 step style). **#600** (sq `9e26d2d6`) — R-12 typed `Status().Extra` per module: `DDoSStatusExtra` (2 fields), `PortscanStatusExtra` (3), `LoginMonStatusExtra` (18 incl. `string` + `map[string]int64` value types), `BotGuardStatusExtra` (16); each struct has a `ToExtraInfo() module.ExtraInfo` method that builds the map manually (no reflection); `Module.Status()` API, `Status.Extra` field type, and `ExtraInfo` alias are all UNCHANGED; JSON wire keys preserved byte-for-byte via struct tags. 8 files (4 production refactors + 3 new `_test.go` + 1 extended `_test.go`). After R-12, R-10's A3 lint becomes vacuous (0 direct `Extra[KEY] =` writes in any module dir; passes by construction); A1+A2 remain active. **Behavior changes:** **none.** Pure CI-invariant + module-internal type-safety refactor; all external consumers reading the JSON-marshaled `Status` see byte-identical output. **W1 MASTER_TODO refresh** remains workspace-only and is **not** bundled (may be filed in parallel as workspace doc; not a repo release payload). **Explicit non-goals carried forward to v1.111+ as separately-gated future debt:** R-11 Watchdog→BotGuard `EventSafetyPressure` contract (deferred per moderate-cut authorization; eventbus infrastructure present from PR-26 era; ~200-300 LOC estimated; needs separate `OPEN-V1XX-WATCHDOG-BOTGUARD-EVENTBUS-CONTRACT-SCOPE`); D-MET-1 Metrics + Portal Contract Enforcement Lane (18 active M-T TODOs; producer of v1.112+ portal/pro.nftban.com design evidence); D-METR-2 watchdog `nftban_watchdog_action_total` emission gap (sub-item of D-MET-1); D-DNS-1 dns2 host migration (PARTIALLY FIXED — BUG side closed in v1.108.0 PR #592; DESIGN-FIX side OPEN); D-FHS-1..5 FHS Authority Graph single-source authority (5 verified gaps); D-SHA-1 SELF-HEALING-AUTHORITY-REDESIGN (post-v1.108.0 reservation MET); D-POL-1 POLKIT-AUTHORITY impl decisions; D-DEG-1 V108 Item 4 DEGRADED-runtime-pattern investigation; D-SEC-1 SEC-FW-BYPASS-ALERT-GAP-001 security backlog; D-TRP-1 TRANSPORT-001 outbound transport adapter; D-EGM-1 V1.1XX EgressMon module (CONDITIONAL GO post-CVE-2026-41940); D-PNL-1 Panel architecture consolidation (4 deferred adapters); D-OSH-1 OS hardening blueprint SELinux/AppArmor; D-GHC-1 optional org-level GHCR `sha-*` retention policy; D-BKT-1 Bucket C 14 v0.x tag historical-review (remote untouched). v1.110.x hotfix slot **not authorized** (latent reservation only — opened only if a v1.110.0 defect surfaces).
**Prior release lane:** v1.109.0 (2026-05-12) — V109 narrow-governance lane on top of v1.108.0. Closes the 6-item narrow cleanup scope: stale docs/comment residue + dead-code deletion + README package-matrix restoration + Dependabot dependency refresh. **No daemon behavior change.** **No code change in `nftban-core` / `nftband` daemons.** Schema frozen at `1.83.0`. No metrics, portal, install API, panel-adapter, FHS-ATG, Self-Healing, POLKIT-AUTHORITY, dns2-migration, or module-isolation implementation changes. **PRs (in merge order):** **#596** (sq `46847717`) — `nftban-api-server` / `nftban-api.service` documentation-side decommissioning (4 files: `CONTRIBUTING.md` tree connector fix + `.github/workflows/release.yml` comment-only edit + `docs/systemd/TIMERS.md` HISTORICAL_KEEP strikethrough + `docs/ARCHITECTURE.md` Optional Services removal; packaging deprecated-cleanup snippets at `install/packaging/{deb,rpm}/*.inc` intentionally preserved as upgrade-time cleanup mechanism). **#597** (sq `787558f7`) — unused `internal/config/config.go` deletion (1 file, -247 lines; zero-importer pre-verified across `*.go`, `*_test.go`, build-tag files; legacy JWT-secret bootstrap from the `nftban-api-server` era; distinct from `internal/configloader/`). **#586** (sq `a3293ff1`) — README tier 0/1/2 package matrix restoration (post PR #399 regression); adds explicit per-distro install blocks for Ubuntu 24.04 LTS, Debian 12, Rocky/Alma/RHEL 9 (Tier 0); Debian 13, Rocky/Alma/RHEL 10 (Tier 1); Ubuntu 22.04 LTS (Tier 2); plus the full `## Available Packages` matrix. Fixes a latent README defect where the combined `Ubuntu 24.04 / Debian 12` heading instructed Debian 12 users to install the Ubuntu 24.04 `.deb` package. **#497** (sq `57ba0f4f`) — `aquasecurity/trivy-action` SHA-pin bump (`e368e328` → `ed142fd0`); single-workflow change to `.github/workflows/secure-go.yml`. **#578** (sq `29353171`) — `actions/dependency-review-action` v4.9.0 → v5.0.0 (major); single-workflow change to `.github/workflows/dependency-review.yml`; Dependency Review check verified SUCCESS under v5. **#495** (sq `232e2dc4`) — `actions/setup-node` v4.4.0 → v6.4.0 (two major versions); single-workflow change to `.github/workflows/project-health.yml`. **#577** (sq `bd4727ec`) — `github/codeql-action` v3.32.3 → v4.35.4 (major); five workflows updated as SARIF-uploader (`codeql.yml`, `osv-scanner.yml`, `scorecard.yml`, `secure-go.yml`, `semgrep.yml`); CodeQL Analysis (Go) verified SUCCESS under v4. **#535** (sq `267b02b8`) — Go modules bump: `github.com/fsnotify/fsnotify v1.9.0 → v1.10.1` (semver-minor; used in nftband for inotify watching) + `golang.org/x/sys v0.42.0 → v0.44.0` (patch-level); 2 files (`go.mod` + `go.sum`); full build matrix verified (Build & Test, all 6 distro RPM/DEB builds, all 8 install tests, CodeQL Go, gosec, govulncheck, osv-scanner, Go Security Analysis, Dependency Review, Validate package effective parity, Validate systemd ExecStart payload resolution). **Behavior changes:** **none.** Pure docs / dead-code removal / dependency refresh. No daemon, packaging-payload, runtime, schema, metrics, portal, install API, panel-adapter, FHS, sysusers, polkit, dns2, or DEGRADED-runtime work in this release. **W1 MASTER_TODO refresh** is workspace-only (`V1.80_ROADMAP/MASTER_TODO.md` workspace doc; **not** a repo release payload). **Explicit non-goals carried forward to v1.110+ as separately-gated future debt:** dns2 host migration execution (**D-DNS-1 PARTIALLY FIXED** — BUG side closed in v1.108.0 PR #592, but DESIGN-FIX side OPEN; dns2 host still source-installed at v1.98.2; reports `Install type: unknown`; needs P1-P8 operator attestations per `DNS2_SOURCE_INSTALL_TO_RPM_MIGRATION_SCOPE.md`); FHS-ATG single-source authority lane (D-FHS-1..5; 5 gaps verified at HEAD `1d83df9e` per `V107_FHS_AUTHORITY_GRAPH_DESIGN_CODE_GAP_CLOSURE.md`); SELF-HEALING-AUTHORITY-REDESIGN (D-SHA-1; post-v1.108.0 reservation now MET); POLKIT-AUTHORITY impl-level decisions (D-POL-1); V108 Item 4 DEGRADED-runtime-pattern investigation (D-DEG-1; lab repro across 3 host classes required); SEC-FW-BYPASS-ALERT-GAP-001 security backlog (D-SEC-1; parked, scope-ready); TRANSPORT-001 outbound transport adapter (D-TRP-1; sub-items 001A/B/C ordered); Module Isolation V1.101-FOLLOWUP (D-MOD-1; 5 R-* findings); Metrics + Portal Contract Enforcement Lane (D-MET-1; 18 active M-T TODOs); EgressMon module (D-EGM-1; CONDITIONAL GO post-CVE-2026-41940); Panel architecture consolidation (D-PNL-1; 4 deferred adapters: CyberPanel/CWP/InterWorx/Vesta); OS hardening blueprint SELinux/AppArmor (D-OSH-1; precondition now MET); optional org-level GHCR `sha-*` retention policy (D-GHC-1); Bucket C 14 v0.x tag historical-review (D-BKT-1; remote untouched). v1.109.x hotfix slot **not authorized** (latent reservation only — opened only if a v1.109.0 defect surfaces).
**Prior release lane:** v1.108.0 (2026-05-12) — V108 primary hardening bundle on top of v1.107.2. Closes 6 of 7 primary items from the `V108_LIFECYCLE_AUTHORITY_AND_CI_BLIND_SPOT_HARDENING` workspace scope (Item 4 DEGRADED-runtime-pattern investigation remains separately gated and is **not** bundled here). The bundle is CI-hardening + GOTH/`nftban-ui` decommission completion + two narrow behavior fixes (CLI install-method classifier and installer state-writer terminal hygiene); **no daemon behavior change**. **PRs (in merge order):** #587 (sq `7c5bccd5`) Item 7C — transitional RPM `%pre` / DEB preinst cleanup of deprecated `nftban-ui*` units; lab4 cross-validation closes the srv1 stale-deprecated-unit residue class. #588 (sq `3a8351e2`) Item 7B — residual GOTH source/config residue cleanup (9 files; 837-byte `ui-access.list` deleted). #589 (sq `4a31a58a`) Item 7A — GOTH active-docs cleanup (5 doc files; CHANGELOG.md + `docs/systemd/UNITS.md` strikethrough preserved as historical record). #590 (sq `86690661`) Item 1 — systemd ExecStart payload-resolution CI gate verifies every active unit's `Exec*` path resolves to a shipped package payload; closes the v1.107.1-class "helper missing from package" defect class. #591 (sq `8f9318fb`) Item 3 — heredoc command-substitution safety CI gate detects unescaped backticks / `$(...)` / `$((...))` in unquoted heredocs; closes the v1.107.1-class "backtick in spec heredoc corrupts generated content" class. #592 (sq `721b2a5c`) Item 6 — source-install package-manager mismatch detection; `_detect_install_type` now reads `update-history.json` first-entry type and emits a 5-class taxonomy (`rpm`/`deb`/`source`/`mixed`/`unknown`); new `_classify_for_pkg_mgr_update` returns gate-framework verdicts via distinct exit codes (0/10/11/12/13); closes the dns2-class source-install misclassification. #593 (sq `ccf37e1f`) Item 5 — install_state carry-over hygiene; `internal/installer/state/file.go::Transition()` now clears stale `FailureReason`/`Conflicts`/`PreflightPassed=0` on `COMMITTED`/`DEGRADED` terminals; closes the lab2/srv1/srv3/srv4 cross-host contradictory-field issue observed across the v1.107.2 fleet. #594 (sq `73394dac`) Item 2 — chattr `+i` lifecycle matrix CI gate; new canonical `build/+i-lifecycle-matrix.yaml` source of truth verifies four surfaces (Go `SetImmutableFlags` + RPM `%pretrans`/`%preun` + DEB `preinst`/`postinst`/`prerm` + the matrix yaml itself) stay in lockstep; closes the v1.107.2-class "Go +i list silently out of sync with scriptlets" defect class. **Behavior changes (narrow, explicit):** (a) CLI `nftban update` now distinguishes `source`/`mixed`/`unknown` install methods explicitly and emits distinct exit codes for upstream gates; (b) installer state-writer terminal hygiene clears stale carry-over fields on success / soft-success transitions; (c) deprecated `nftban-ui*` units auto-clean on package upgrade for hosts upgrading from pre-v1.100.1b.A packages. **No behavior change in `nftban-core` / `nftband` daemons.** Schema frozen at `1.83.0`. No metrics, portal, install API, panel-adapter, FHS-ATG, Self-Healing, or POLKIT-AUTHORITY implementation changes. **Explicit non-goals carried forward to v1.109+ as separately-gated future debt:** Item 4 DEGRADED-runtime-pattern investigation; Items 8–16 from the V108 parent inventory (dns2 migration, FHS-ATG, POLKIT-AUTHORITY follow-on, optional GHCR retention, row 17 SELF-HEALING-AUTHORITY-REDESIGN, etc.); `SEC-FW-BYPASS-ALERT-GAP-001` security backlog (parked, scope-ready); README rewrite PR #586 (separate docs review track); open Dependabot PRs (#495, #497, #535, #577, #578); v1.107.3 hotfix (**not authorized**).
**Prior release lane:** v1.107.2 (2026-05-10) — packaging hotfix on top of v1.107.1. Closes a long-standing pre-cpio `+i` asymmetry: `internal/installer/validate/authority.go SetImmutableFlags` sets `chattr +i` on **two** files (`/etc/nftban/nftban.conf` + `/usr/lib/nftban/lib/nft_schema.sh`), but the upgrade-pre-cpio scriptlets (RPM `%pretrans` Lua + DEB preinst) only stripped `+i` from `nft_schema.sh`. Direct `dnf upgrade ./nftban-core-*.rpm` and `apt install ./nftban-core-*.deb` therefore failed at cpio extraction on hosts where `/etc/nftban/nftban.conf` carried the `+i` flag, with the misleading `cpio: utime failed - Directory not empty` error. The canonical CLI path `nftban update` already worked because `cli/lib/nftban/cli/cmd_update_helpers.sh:120 _remove_immutable_flags` walks `/etc/nftban` recursively before invoking the package manager. v1.107.2 aligns RPM `%pretrans` and DEB preinst with that same lifecycle invariant — adds a 9-line Lua block + 3-line shell `if` that strip `+i` from `/etc/nftban/nftban.conf` before extraction. The `+i` setter, the unit file, the validator assertion, the CLI helper, and `%preun`/prerm are all unchanged. Schema frozen at `1.83.0`. No portal, schema, metrics, install API, or panel-adapter changes. No behavior change in `nftban-core` / `nftband` daemons. Carries forward all v1.107.0 + v1.107.1 non-goals (row 17 SELF-HEALING-AUTHORITY-REDESIGN, FHS Authority Graph / ATG, optional GHCR retention).
**Prior release lane:** v1.107.1 (2026-05-10) — packaging hotfix on top of v1.107.0. Closes a packaging-vs-source-install asymmetry surfaced by lab4 takeover (Issue #525 follow-on rollout): `nftban-firewall-init.service` references `/usr/lib/nftban/helpers/firewall-init-with-delay.sh` but RPM/DEB packagers did not ship the helper, leaving `INSTALL_STATE=DEGRADED` after every successful takeover. Fix is two `install` lines in `packaging/build_nftban.sh` (RPM `%install` + DEB `build_deb()`), staging the helper from `install/helpers/` (the same source location that `internal/installer/payload/payload.go:411` uses for the source-install path under PR26.5). Helper source unchanged. Unit file unchanged. Validator assertion unchanged. Schema frozen at `1.83.0`. No metrics, portal, install API, or panel-adapter changes. Behavior change limited to: `nftban-firewall-init.service` `ExecStart=` target now resolves on package install; `systemd_execstart_paths_ok` validator assertion now passes; takeover terminal state advances from `DEGRADED` to `OK`/`HEALTHY`. Carries forward all v1.107.0 non-goals (row 17 SELF-HEALING-AUTHORITY-REDESIGN, FHS Authority Graph / ATG, optional GHCR retention).
**Prior release lane:** v1.107.0 (2026-05-10) — post-MFST closure release on top of v1.106.0. Five code PRs and one accepted-retention closure land the v1.107 worklog targets. **PR #576 (squash `15bb9f44`)** — Slot 5a PKG-EFFECTIVE-PARITY: DEB postinst ownership convergence (Option α + Option A `dpkg-statoverride`) + new CI parity gate covering all six layers (yaml SoT → generator → archive metadata → installed-fs → reinstall preservation → verify tool). **PR #579 (squash `0daeb38e`)** — Slot 5b G8-AUDITOR-DIR-UBUNTU: Runtime Truth G8 verifier sudo-wrapped so the runner-user can traverse `0750 root:nftban` parents on Ubuntu 24.04; CI test-harness fix only (Bucket F), no product change. The SYSUSERS-GECOS-G-LINES dormant defect surfaced as a side-effect of this gate's reverted Stage-2 attempt and was closed separately by PR #582. **PR #580 (squash `1d2c4b63`)** — Slot 6 POLKIT-AUTHORITY: documentation-only amendment. Two `note:` fields added to `build/fhs-spec.yaml` (D-NEW-11 keep-decision + auditor-dir AUTHORITY EXCEPTION); header `// CONSUMERS` block added to `30-nftban-panel.rules` with 9-surface live-consumer manifest + decommission-rejected rationale. `polkit.addRule(...)` body BYTE-IDENTICAL to base. The three-tier polkit model (operator/auditor/panel) is confirmed load-bearing. **PR #581 (squash `1d83df9e`)** — Slot 7 LANE-G / Issue #525: `nftban-core-geoip.service` `TasksMax=10`→`64` (mirrored on `nftban-health.service`) closes a Go 1.25 runtime fatal-trace class triggered by `clone(2) EAGAIN` under cgroup pids exhaustion. New Runtime Truth G9 step asserts no Go runtime fatal trace appears at geoip startup on both ubuntu-24.04 (real-systemd path A) and almalinux-9 (prlimit path B) matrix legs. Issue #525 left OPEN by the merge gate (operational hygiene; operator may close separately). **PR #582 (squash `3af86877`)** — proposed worklog row 16 SYSUSERS-GECOS-G-LINES one-shot: generator emitter `g \(.name) - "\(.comment)"` → `g \(.name) -` (per `sysusers.d(5)`, g-lines do not take a GECOS field); regenerated `install/systemd/sysusers.d/nftban.conf`; new Runtime Truth G10 step asserts `systemd-sysusers --dry-run` exits 0 on systemd 252 + 255 matrix legs. Identities byte-equivalent. **Row 13 / F-6 REGISTRY-HYGIENE** closed via accepted-retention path (b): `ghcr.io/itcmsgr/nftban:sha-4de527d` re-classified as normal `docker/metadata-action@v5.9.0` `type=sha` output (one of 284 `sha-*` tags), not stale; zero registry mutation, zero code change, zero PR. **No runtime behavior change in `nftban-core` / `nftband` daemons; behavior changes confined to (a) raised cgroup `TasksMax` on `nftban-core-geoip.service` + `nftban-health.service` and (b) corrected `sysusers.d` g-line syntax (dormant in production; postinst uses `groupadd -r` directly, never `systemd-sysusers`).** Schema frozen at `1.83.0`. No metrics, portal, install API, or panel-adapter changes. **Explicit non-goals carried forward to v1.108+ as separately-gated future debt:** (i) row 17 SELF-HEALING-AUTHORITY-REDESIGN (lifecycle / authority-model debt; SCOPE-FIRST treatment; not displaced by v1.107.0); (ii) FHS Authority Graph / ATG (intentionally deferred — not a v1.107.0 blocker; will not open before release; after v1.108.0 the operator may introduce it as a separate debt lane with its own scope gate); (iii) optional org-level GHCR `sha-*` retention policy (forward-looking hygiene, post-v1.107).
**Schema status:** schema remains frozen at `1.83.0` in v1.110.0. No metric names, labels, or health JSON schema changed across the v1.110 module-isolation lane (R-10 CI lint + R-12 typed `Status().Extra` refactor are both schema-neutral; JSON wire keys preserved byte-for-byte). The three v1.100.4 H4 disclosure items (ban attribution under `source=manual`, `EffectiveIdle` for Portscan/LoginMon, shared `input_syn_rate_exceeded` counter) are unchanged. The schema / metrics lane (Lane S) remains held; deeper attribution / effective-state work is routed to a future release (see D-MET-1 / D-METR-2 carried forward). **No metrics, portal, install API, panel-adapter, FHS, sysusers, polkit, dns2-migration-execution, DEGRADED-runtime, eventbus, packaging, or systemd changes in v1.110.0.** v1.110.0 is a pure CI-invariant + module-internal type-safety refactor; zero external-consumer behavior change.
**Truth model:** Kernel → Validator → CLI
**Enforcement:** [Design Principles](docs/DESIGN_PRINCIPLES.md)

---

## 0. What This Page Represents

This is not a badge collection.

This page is a **live, machine-verifiable audit surface** showing how NFTBan
enforces system integrity through automated CI/CD pipelines.

**Authority model:**
Kernel (nftables) is the only source of truth. All validation, metrics, and
CLI output derive from kernel state via the Go validator. The daemon `/metrics`
endpoint is the canonical runtime observability surface.

**Evidence model:**
Protection state is derived from kernel-observable evidence (counters, sets,
meters). Structural presence alone does not imply enforcement.

Every check listed here is:

- **Automated** — runs without human intervention on every PR and push
- **Reproducible** — identical inputs produce identical results
- **Verifiable** — badge links go directly to workflow run logs

No check relies on manual verification.

If any check fails, the corresponding code **cannot be merged or released**.

This model allows operators and auditors to independently verify system
integrity without trusting documentation or claims.

This page covers four verification axes:

1. Build correctness and runtime safety
2. Architecture and contract enforcement
3. Security and supply chain integrity
4. Compliance and provenance attestation

---

## 1. Build & Runtime Verification

These workflows verify that NFTBan compiles, installs, and executes correctly
across all supported platforms.

| Workflow | What it verifies | Frequency | Status |
|---|---|---|---|
| [Go Build & Test](https://github.com/itcmsgr/nftban/actions/workflows/ci-go.yml) | Compilation, unit tests, race detection, module completeness (G8-1/2/3), schema codegen lock | Every PR + push | [![Go](https://github.com/itcmsgr/nftban/actions/workflows/ci-go.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-go.yml) |
| [Bash Validation](https://github.com/itcmsgr/nftban/actions/workflows/ci-bash.yml) | Shell correctness under `set -Eeuo pipefail`, execution safety | Every PR + push | [![Bash](https://github.com/itcmsgr/nftban/actions/workflows/ci-bash.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-bash.yml) |
| [ShellCheck](https://github.com/itcmsgr/nftban/actions/workflows/shellcheck.yml) | Static shell analysis (SC2 rules) | Every PR + push | [![ShellCheck](https://github.com/itcmsgr/nftban/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/shellcheck.yml) |
| [Build Packages](https://github.com/itcmsgr/nftban/actions/workflows/build-packages.yml) | RPM + DEB build and install test across 7 platform targets | Every PR + push | [![Build](https://github.com/itcmsgr/nftban/actions/workflows/build-packages.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/build-packages.yml) |
| [Docker](https://github.com/itcmsgr/nftban/actions/workflows/docker.yml) | Container build reproducibility | Every PR + push | [![Docker](https://github.com/itcmsgr/nftban/actions/workflows/docker.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/docker.yml) |
| [Smoke Test](https://github.com/itcmsgr/nftban/actions/workflows/ci-smoke.yml) | CLI runtime execution, JSON output validity, runtime anomaly detection | Every PR + push | [![Smoke](https://github.com/itcmsgr/nftban/actions/workflows/ci-smoke.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-smoke.yml) |
| [Release](https://github.com/itcmsgr/nftban/actions/workflows/release.yml) | Signed release pipeline with provenance attestation | Release only | [![Release](https://github.com/itcmsgr/nftban/actions/workflows/release.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/release.yml) |

---

## 2. Architecture & Contract Enforcement

These workflows enforce structural invariants that prevent regression of the
kernel-first truth model.

**Structural invariant:** No rule may shadow another. Detection logic must
remain reachable in the nftables chain. Shadowed logic (e.g., accept rules
before detection jumps) is treated as DEGRADED state.

| Workflow | What it verifies | Frequency | Status |
|---|---|---|---|
| [Architecture Policy](https://github.com/itcmsgr/nftban/actions/workflows/ci-architecture.yml) | Schema integrity, vocabulary discipline (G1-1), module consistency (G8-4), codegen drift detection, nft direct-write protection | Every PR + push | [![Architecture](https://github.com/itcmsgr/nftban/actions/workflows/ci-architecture.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-architecture.yml) |
| [Documentation](https://github.com/itcmsgr/nftban/actions/workflows/ci-docs.yml) | Markdown lint, link validity, doc completeness | Every PR + push | [![Docs](https://github.com/itcmsgr/nftban/actions/workflows/ci-docs.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-docs.yml) |
| [Project Health](https://github.com/itcmsgr/nftban/actions/workflows/project-health.yml) | Repository hygiene, stale issues, PR quality | Scheduled | [![Health](https://github.com/itcmsgr/nftban/actions/workflows/project-health.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/project-health.yml) |

The Architecture Policy workflow is the primary anti-regression guard. It
prevents changes that would break the kernel → validator → CLI truth pipeline
or introduce vocabulary drift in operator-facing output.

---

## 3. Security & Supply Chain (Zero-Trust)

These workflows implement defense-in-depth security scanning. No single tool
covers all attack surfaces — the combination provides layered coverage.

| Workflow | What it verifies | Frequency | Status |
|---|---|---|---|
| [CodeQL](https://github.com/itcmsgr/nftban/actions/workflows/codeql.yml) | Semantic SAST for Go (data flow, taint tracking) | Every PR + push | [![CodeQL](https://github.com/itcmsgr/nftban/actions/workflows/codeql.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/codeql.yml) |
| [Semgrep](https://github.com/itcmsgr/nftban/actions/workflows/semgrep.yml) | Pattern-based security rules (Go + Shell) | Every PR + push | [![Semgrep](https://github.com/itcmsgr/nftban/actions/workflows/semgrep.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/semgrep.yml) |
| [Secure Go](https://github.com/itcmsgr/nftban/actions/workflows/secure-go.yml) | gosec, govulncheck, staticcheck, Trivy container scan | Every PR + push | [![SecureGo](https://github.com/itcmsgr/nftban/actions/workflows/secure-go.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/secure-go.yml) |
| [OSV-Scanner](https://github.com/itcmsgr/nftban/actions/workflows/osv-scanner.yml) | Dependency CVE detection via Google OSV database | Every PR + weekly | [![OSV](https://github.com/itcmsgr/nftban/actions/workflows/osv-scanner.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/osv-scanner.yml) |
| [Gitleaks](https://github.com/itcmsgr/nftban/actions/workflows/gitleaks.yml) | Secret and credential leakage detection | Every PR + push | [![Gitleaks](https://github.com/itcmsgr/nftban/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/gitleaks.yml) |
| [Fuzz Tests](https://github.com/itcmsgr/nftban/actions/workflows/fuzz.yml) | Parser robustness via automated fuzzing | Nightly | [![Fuzz](https://github.com/itcmsgr/nftban/actions/workflows/fuzz.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/fuzz.yml) |
| [Dependency Review](https://github.com/itcmsgr/nftban/actions/workflows/dependency-review.yml) | Dependency diff risk analysis on PRs | Every PR | [![DepReview](https://github.com/itcmsgr/nftban/actions/workflows/dependency-review.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/dependency-review.yml) |
| [Socket Supply Chain](https://github.com/itcmsgr/nftban/actions/workflows/socket-supplychain.yml) | Typosquatting, malicious package, and behavioral detection | Every PR + push | [![Socket](https://github.com/itcmsgr/nftban/actions/workflows/socket-supplychain.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/socket-supplychain.yml) |
| [Security Summary](https://github.com/itcmsgr/nftban/actions/workflows/security-summary.yml) | Consolidated security posture dashboard | Scheduled | [![SecSummary](https://github.com/itcmsgr/nftban/actions/workflows/security-summary.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/security-summary.yml) |

---

## 4. Compliance & Provenance

These workflows provide verifiable evidence of license compliance and build
provenance for enterprise and audit requirements.

| Workflow | What it verifies | Frequency | Status |
|---|---|---|---|
| [OSSRA Remediation](https://github.com/itcmsgr/nftban/actions/workflows/ossra-remediation.yml) | License compliance (go-licenses), SPDX header validation, dependency freshness (libyear), URL integrity (Lychee) | Every PR + push | [![OSSRA](https://github.com/itcmsgr/nftban/actions/workflows/ossra-remediation.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ossra-remediation.yml) |
| [OpenSSF Scorecard](https://github.com/itcmsgr/nftban/actions/workflows/scorecard.yml) | OpenSSF security posture scoring | Scheduled | [![Scorecard](https://github.com/itcmsgr/nftban/actions/workflows/scorecard.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/scorecard.yml) |
| [SLSA Provenance](https://github.com/itcmsgr/nftban/actions/workflows/slsa-go-releaser.yml) | Cryptographic build attestation (SLSA Level 3) | Release only | [![SLSA 3](https://slsa.dev/images/gh-badge-level3.svg)](https://slsa.dev) |

Every release includes:

- SLSA Level 3 provenance (non-forgeable build attestation)
- SBOM in SPDX-JSON format
- GPG-signed tags and artifacts
- All GitHub Actions pinned to commit SHAs

---

## 5. Contract Gates

These are **blocking gates** enforced by CI workflows. A failure in any gate
prevents merge to main. They enforce [Design Principles](docs/DESIGN_PRINCIPLES.md)
directly in code — not by policy document, but by automated test.

| Gate | Design Principle | What it prevents |
|---|---|---|
| **G1-1** | Vocabulary discipline | Banned terms in CLI output ("healthy", "OK", "working", etc.) |
| **G2-3** | Schema consistency | CLI expected schema ≠ validator schema version |
| **G8-1** | Module completeness | CORE module missing from evaluator or JSON output |
| **G8-2** | Config classification | Module config directory without classification |
| **G8-3** | IPv6 parity | IPv4 structural check without matching IPv6 check |
| **G8-4** | Cross-surface truth | Validator module list ≠ CLI module list |
| **INV-M-001** | Single kernel read | Evidence layer calls nft directly (must go through validator) |
| **INV-M-003** | Metric ownership | Duplicate metric collection across components |
| **INV-M-005** | No shell duplication | Shell exporter duplicates daemon kernel collection |

These gates are tested as part of `ci-go.yml` (Go unit tests) and
`ci-architecture.yml` (structural policy checks).

---

## 6. Pipeline Statistics (Automation Proof)

These values represent enforced automation, not documentation claims.

| Metric | Value |
|---|---|
| CI/CD workflows | 24 |
| Security scanning tools | 10 |
| Contract gates (blocking) | 9 |
| Package build targets | 7 (el9, el10, ubuntu22/24, debian12/13, + validation) |
| Install test environments | 5 (rocky9, alma9, centos-stream9/10, debian12) |
| Canonical daemon metrics | ~110 (post v1.90 name freeze) |
| Provenance level | SLSA Level 3 |
| SBOM format | SPDX-JSON |

---

## 7. Runtime Truth Verification

Post-deploy verification commands that prove kernel enforcement on live hosts:

```bash
# 1. Kernel-derived health state (authoritative)
nftban-validate --json | jq '.status'
# Expected: "protected", "idle", or "degraded"

# 2. CLI truth (must match validator — INV-CONS-001)
nftban health --json | jq '.status'
# Must match validator output exactly

# 3. Evidence metrics (observable enforcement data)
nftban metrics evidence
nftban metrics evidence-json

# 4. Kernel structure verification
nft list tables
nft list chain ip nftban input | grep ANCHOR
# Must show 7 anchors: HYGIENE → TRUSTED → BAN → ESTABLISHED → DETECT → SERVICE → FINAL
```

**System invariant:** Kernel == Validator == CLI

If any of these commands disagree, the system state is invalid and must be
treated as DEGRADED regardless of what individual surfaces report.

---

## 8. Health Policy

- Main branch is always green
- Failed CI blocks merge — no exceptions
- No manual overrides for truth-critical checks
- Every release is CI-gated before tag
- Evidence over claims — if it cannot be measured, it cannot be stated
- Unknown state → DEGRADED (never PROTECTED)

---

## 9. Interpretation Guide

| Badge status | Meaning |
|---|---|
| **Green** | Workflow passed — invariant verified |
| **Red** | Workflow failed — code cannot merge or release until resolved |
| **Skipped** | Workflow not triggered for this event type (expected for some PR-only checks) |
| **Neutral** | Advisory result (e.g., gosec code annotations) — does not block |
| **No badge** | Workflow runs on a different trigger (release-only, scheduled) |

---

## 10. Integrity Statement

NFTBan does not claim protection. It **proves** protection through:

- **Kernel evidence** — nftables counters, sets, and chain structure
- **Automated validation** — Go validator reads kernel state (~1ms)
- **Reproducible CI** — 24 workflows, 10 security tools, 9 contract gates
- **Cryptographic provenance** — SLSA Level 3 attestation on every release

If any invariant breaks, the system reports **DEGRADED**, not PROTECTED.

This is not a design claim. It is enforced by CI and validator logic.

---

> [SECURITY.md](SECURITY.md) — Vulnerability reporting and supported versions
> [Design Principles](docs/DESIGN_PRINCIPLES.md) — Engineering contract for all components
> [Wiki](https://github.com/itcmsgr/nftban/wiki) — Full system specification
