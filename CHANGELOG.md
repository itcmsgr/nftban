# NFTBan Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **History reset.** Pre-v1.79.2 releases are recorded as git tags and on
> the GitHub Releases page (`gh release list`). From v1.79.2 forward, every
> tagged release MUST have a CHANGELOG entry written before tagging.

---

## [v1.102.0] - 2026-05-04 — focused Lane P corrective release

One code PR on top of v1.101.0. Schema remains frozen at `1.83.0`. No
metrics changes. No portal coordination. No transport-adapter work.
Lane S remains held.

### Lane P — production hygiene

- **PR-P1** typed `executor.ServiceResetFailed` + takeover clears
  stale systemd `failed (Result: signal)` markers after successful
  `ServiceMask` (`c2697dd9`, PR #557). All-conflicts behavior (csf,
  lfd, future ufw / firewalld), not lfd-only. Defensive guard:
  `reset-failed` runs only if the mask succeeded. `reset-failed`
  errors are cosmetic-only / non-fatal. Restore path explicitly does
  **not** call `ServiceResetFailed` (Amendment 1 §31; pinned by
  `internal/installer/restore/engine_pr_p1_test.go` static-grep
  invariant). **Closes [#524](https://github.com/itcmsgr/nftban/issues/524).**

### Issue verification (no v1.102 code change)

- **[#526](https://github.com/itcmsgr/nftban/issues/526)**
  unified-exporter missing payload — verified fixed on a fresh
  AlmaLinux 9.7 VM with the v1.101.0 RPM. Closure attributed to
  upstream PR26.5 (`1510e361`, merged 2026-04-30). Issue closed
  2026-05-03. DEB cross-family verification is optional release-QA,
  not required for closure.

### Out of scope (deferred)

TRANSPORT-001 outbound-transport adapter layer; Lane S
(schema/metrics contract); portal lane; PR-C3
(`*_ENABLED` duplicate-pair coalescing); PR-C0B (full 1614-key
config audit); PR-T2 (timer cluster spread);
[#525](https://github.com/itcmsgr/nftban/issues/525) GeoIP runtime
panic (no host-debug lane in v1.102); PR-B2 / PR-B3 service header
notes; `docs/systemd/UNITS.md` line 5 timer-count drift; POLKIT
audit inventory; panel adapter Round 2 (CyberPanel / CWP /
InterWorx / Vesta / Generic); EgressMon (separate v1.1XX lane);
EL10 / EL8 distro-matrix expansion.

---

## [v1.101.0] - 2026-05-03 — cleanup / truth-boundary release

Operator-locked cleanup slice on top of v1.100.4. Seven PRs across four lanes
(H / T / C / P). No new features. No schema or metrics changes. No panel
adapters added. No portal coordination. Schema remains frozen at `1.83.0`.

### Lane H — repository hygiene

- **PR-H1** dev/internal path residue removed (`b38fd216`, PR #549) — 4 systemd
  `Documentation=` URLs + 4 script/CI references converted from `nftban-dev`
  to canonical `nftban`.
- **PR-H2** STATUS.md + CHANGELOG.md release-state cleanup (`58b6b231`,
  PR #550) — `v1.100.4-dev` → `v1.100.4`; `(in flight)` → `(released)`;
  v1.100.4 entry promoted from `[Unreleased]` to released.
- **PR-H3** Final live `HEADER_SPEC.md` reference removed from `Makefile`
  (`aa77db7d`, PR #551) — closes audit finding H-10 across the Lane H arc
  (`CONTRIBUTING.md` + `tools/validate-headers.sh` were closed in
  v1.100.3a).
- **PR-H4** Per-file version tokens stripped from systemd unit / timer /
  socket banners (`57305c76`, PR #552) — 48 files; pure comment cleanup;
  zero behavior change. Inline historical-fix comments preserved.

### Lane T — timers / maintenance

- **Internal timer-inventory correction** (workspace H5 doc-fix, no repo PR):
  21 systemd timers, not 3. Three ownership classes documented: 3 daemon-tier
  (watchdog / maintenance / queue), 1 manual-trigger (rollback), 17
  subsystem-coupled.
- **PR-T1** `nftban-rollback.timer` documented as manual-trigger safety net
  (`535c60ef`, PR #553) — `OnActiveSec=5min`; started by `nftban-apply`,
  stopped by `nftban-confirm`; `WantedBy=timers.target` intentionally
  commented out so fresh installs (no `backup.rules`) do not trigger
  spurious rollback countdowns.

### Lane C — config authority

- **Confirmation: legacy GUI base-write surface is gone.** PR-C0A
  (workspace audit, no repo PR) found zero production code paths writing
  to base `.conf` files at HEAD; the v1.80 finding referred to
  `cmd_gui.sh` which has been removed entirely.
- **PR-C2** Report-data layer now reads merged config (base + sibling
  `.conf.local`) for DDoS-enabled, Portscan-enabled, GeoBan-enabled, and
  GeoBan countries (`28e114b6`, PR #554). New private `_read_conf_key`
  helper; `.conf.local` wins on assignment-exists semantics, including
  empty-value override. Pure shell; no `jq`; no sourcing of `.conf` or
  `.conf.local`. Closes 4 P1 drift rows (C0A-D-01..04). Same-function
  count-bug in `_get_geoban_countries` fixed inline. 17-case test added.
- **Deferred:** PR-C3 (`*_ENABLED` duplicate-key coalescing across DDoS /
  Portscan / Login / BotGuard) — needs canonical-name decisions; routed
  to a future release.

### Lane P — production hygiene

- **PR-P4** `apt-get update` preflight added before `apt-get install` in
  `internal/installer/deps/deps.go::installDEB` (`57600518`, PR #555).
  60s timeout; fail-fast on update failure with a clear preflight error
  containing exit code + stderr. RPM/DNF/yum path unchanged. **Closes
  [#467](https://github.com/itcmsgr/nftban/issues/467).**

### Issues

- **Closed:** [#467](https://github.com/itcmsgr/nftban/issues/467) (apt-get
  update preflight).
- **Open / classified, no fix in v1.101.0:**
  - [#524](https://github.com/itcmsgr/nftban/issues/524) (lfd reset-failed)
    — STILL_REPRODUCES; PR-P1 deferred.
  - [#525](https://github.com/itcmsgr/nftban/issues/525) (geoip Go panic)
    — NEEDS_HOST; deferred to v1.102 unless a host-debug lane opens.
  - [#526](https://github.com/itcmsgr/nftban/issues/526) (unified-exporter
    missing payload) — ALREADY_FIXED at code level by PR26.5; awaits one
    fresh-install verification before issue closure.

### Out of scope (deferred)

- Portal lane (M-T9 cutover, allow-list, CMS, `nftbanpro`) — external; no
  v1.101 work.
- Schema / metrics changes (Lane S held).
- Module-isolation public-safe summary (Lane M held; internal H5 docs
  remain unpublished).
- Full 1614-key config audit (PR-C0B) — large audit batch; future release.
- Panel adapter Round 2 (CyberPanel / CWP / InterWorx / Vesta / Generic)
  — evidence-host gated.
- v2.0 UX sprint and GOTH / `nftban-ui` decommission (PR-D4) — separate
  v2.0 track.
- EgressMon — separate v1.1XX lane.
- EL10 / EL8 distro-matrix expansion — evidence-host gated.

### Standing rules

- Schema remains frozen at `1.83.0`.
- `policyConfigNoReplace` + `*.conf.default` lifecycle model from v1.100.4
  is design-correct for v1.101 (operator decision recorded against
  `CONFIG_DRIFT.md` row C0A-D-09).
- Sub-config files `classic.conf` / `suricata.conf` / `scorer.conf` /
  `services.conf` are mode-specific sub-surfaces, not duplicates of
  `main.conf`.

---

## [v1.100.4] - 2026-05-02 — release hygiene + panel-framework completion

Rollup of the v1.100 panel-framework completion lane and the v1.100.4
release-hygiene track. Released as v1.100.4 on 2026-05-02 (tag at
`9a6373bb`).

### Scope of the panel-framework lane

> **Install-time panel survival validation migrated to Go for DirectAdmin,
> Plesk, and cPanel. Operator-facing panel CLI (`nftban panel <name>
> enable/disable/status/report/repair/test` + Cloudflare checks +
> cPHulk reporting + full panel UX) remains shell-owned until a future
> explicit migration/decommission lane.**

The `panelfw` adapters added in this lane replace **only** the
install-time `PanelAdapter` contract:

- `Detect()` — filesystem + service + listener evidence
- `RequiredPorts()` — conf.d-driven port surface declaration
- `ValidateReachability()` — control-plane LISTEN check

They do **not** thin or replace the shell panel libraries. Shell
decommission is gated on per-function `MIGRATION_COVERAGE.md` (H3.1+).

### Panel-adapter coverage under `panelfw` (install-time validation only)

| Panel | Status | Evidence |
|---|---|---|
| **DirectAdmin** | adapter merged + live destructive evidence | dns2 PR26.4+26.5+26.6 retry SUCCESS + PR26.6.1 watchdog hotfix verified live |
| **Plesk** | adapter merged + live read-only reality audit | 178.105.74.229 (Ubuntu 24.04 + Obsidian 18.0.76); lab2 H2 supplementary baseline (Ubuntu 24.04 + Plesk) |
| **cPanel** | adapter merged + live read-only reality audit | lab4 (AlmaLinux 9.7 + cPanel 11.132.0.19); lab4 H2 supplementary baseline |
| CyberPanel / CWP / InterWorx / Vesta / Generic | DEFERRED | gated on licensed clean evidence hosts |

### Merged PRs (panel-framework lane)

- **PR26.1** install validation hardening (`cdf8f770`) — generic systemd-payload validation; 5 invariants block StateCommitted on missing exporter / orphan timer / unknown ExecStart / failed unit / payload inventory mismatch
- **PR26.2** panel-survival framework (`fdbebe8c`) — generic `panelfw` framework + `FakePanelAdapter` test fixture; `PANEL-SURVIVAL-001` invariant; `--no-panel` opt-out
- **PR26.3** DirectAdmin adapter (`5366caf5`) — first adapter, control-plane reachability only (Path A scope-limit)
- **PR26.4** DirectAdmin adapter consumes conf.d (`bfe6eac9`) — adapter reads `etc/nftban/conf.d/panels/directadmin/main.conf` via `internal/ports/panel_loader.LoadPanelConfig`; closes DirectAdmin four-truth drift
- **PR26.5** source-install payload completeness (`1510e361`) — `etc/nftban/conf.d/panels/*` staged; 4 shell-payload categories (exporters, cron, scripts, helpers); dead UI/API unit removal; validator strictly extended
- **PR26.6** takeover preserves non-nftban authority (`1e48b795`) — `TAKEOVER-PRESERVES-NON-NFTBAN-AUTHORITY-001` invariant; 4-class nft table classifier; CSF rename-to-`.disabled` (reversible-disarm); cron-backup manifest before rm; **dns2 retry SUCCESS** (INSTALL_RC=0 / StateCommitted / PROTECTED / inet ssh_safety preserved live)
- **PR26.7** Plesk adapter (`867f047a`) — second adapter under `panelfw`; control-plane TCP 8443 only; 8447 explicitly NOT control-plane
- **PR26.7.1** Plesk reality calibration (`93078da1`) — Detect E3 any-of `{sw-cp-server.service, psa.service, plesk.service}` (Ubuntu Plesk has no `plesk.service`); conf.d adds TCP 4190 (managesieve, RFC 5804)
- **PR26.6.1** DirectAdmin watchdog coherence (`2d8bbc7c`) — `PANEL-WATCHDOG-COHERENCE-001` invariant; `disarmDAWatchdog` flips `^lfd=ON` → `lfd=OFF` in DA `services.status` atomically + idempotently; closes dns2 dataskq lfd-mask noise loop (14+ hours of journal noise eliminated)
- **PR26.8** cPanel adapter (`6442d2f6`) — third adapter; Detect E3 = `cpanel.service` (orchestrator; NOT `cpsrvd.service`); ValidateReachability any-of `{2087 WHM, 2083 cPanel}`; **CPANEL-RPCBIND-111-DIRECTIVE** honored (no port 111 anywhere in adapter or conf.d)

### Release-hygiene PRs

- **H1.1** version truth + build metadata (`c8ede6d7`) — `/VERSION` 1.98.2 → 1.100.4-dev; `pkg/version` centralizes `GitCommit` + `BuildDate` ldflag-injectable vars + `Line(component)` helper; all 4 binaries (`nftband`, `nftban-core`, `nftban-installer`, `nftban-validate`) print canonical line via `--version`; `nftban-validate --version` is zero-side-effect; sentinel `dev`/`unknown` defaults flag uninjected builds; FHS spec regenerated and Policy Gates clean
- **H2** docs/wiki/status sync — STATUS.md + CHANGELOG.md + V1.90 staging refreshed against current main
- **H3.1** migration coverage doc (CLOSED INTERNAL) — classification rules inlined into CI gates; spec lives in private audit/wiki workspace, not shipped in repo (PR #546)
- **H3.2** migration-coverage CI gate (`50ab2532`) — 8-check gate enforcing panelfw adapter coverage, payload-destinations sole truth, nftban-table classifier parity, G3-UN-NO-MUTATION whitelist, deprecated UI unit refusal, port-list bounds, validator-authority pin
- **H3.3** shell-delete CI gate (`09325e87`) — 5-check gate refusing protected shell deletions without `[MIGRATION-LANE-AUTHORIZED]` or `[DEPRECATED-REMOVAL]` PR markers; 7/7 self-test scenarios green
- **H4** schema + metrics — closed as **GO-NO-CODE** for v1.100.4. No metric names, labels, or health JSON schema changed. Schema remains frozen at `1.83.0`. Deeper attribution / effective-state work routed to v1.101+ (R-01-impl source label split, R-02-impl `EffectiveUnverifiable`, R-12-impl typed `Status().Extra`, MET-01..05). See "H4 schema/metrics disclosures" below.

### H4 schema/metrics disclosures (read carefully)

These are **disclosure only.** No metric, label, or schema changed in v1.100.4. They describe behaviors operators should be aware of when interpreting v1.100.4 output. The deeper work that resolves each item is deferred to v1.101+.

1. **Ban attribution disclosure.** Current per-source ban metrics may aggregate some module-originated bans under `source=manual`. Forensic correlation remains available through evidence/source-index data (`evidence_correlate.go` + `source_index.jsonl`). Per-source label expansion is deferred to v1.101.

2. **Effective-state disclosure.** Portscan and LoginMon currently report `EffectiveIdle` when no kernel-observable per-module enforcement signal exists. This should be read as *"not independently kernel-verifiable,"* not proof that the modules are inactive. `EffectiveUnverifiable` / per-module counters are deferred to v1.101.

3. **Shared counter disclosure.** `input_syn_rate_exceeded` is a shared DDoS / Portscan signal in v1.100.4. Per-module counter split is deferred to v1.101.

### Invariants codified during the lane

- `TAKEOVER-PRESERVES-NON-NFTBAN-AUTHORITY-001` (PR26.6) — takeover may disable external authority via reversible lifecycle ops; must not destructively delete operator-retained tables/binaries/configs/recovery paths
- `PANEL-SURVIVAL-001` (PR26.2) — adapter detection + control-plane reachability gate StateCommitted unless `--no-panel`
- `PANEL-WATCHDOG-COHERENCE-001` (PR26.6.1) — when takeover masks an external service the panel watches, panel runtime watchdog config must be updated to stop monitoring it
- `CPANEL-RPCBIND-111-DIRECTIVE` (PR26.8 era) — TCP/UDP 111 is operator/service-specific RPC surface, NOT panel-survival; never auto-add to panel adapter/conf.d
- `SEC-HARDEN-RPCBIND-001` (PR26.8 era) — host-level rpcbind on 0.0.0.0 with no NFS evidence is `UNEXPECTED_EXPOSED`; warn/report only, never auto-mutate

### Out of scope (deferred)

- CHANGELOG entries for individual H1.x sub-PRs
- Restore-symmetric DA watchdog re-arm (`lfd=OFF` → `lfd=ON` on §32 CSF restore)
- chkservd CSF-watchdog clearing (PR26.6.1 generalization for cPanel-with-CSF hosts; needs evidence host with CSF + WHM CSF plugin)
- WHM CSF plugin presence detection (informational warn)
- Generic ufw/firewalld/fail2ban disarm in takeover (`GENERIC-EXTERNAL-AUTHORITY-DISARM-001` proposed; lab2 has the ufw=active specimen ready)
- conf.d additions for cPanel TCP 4190 (managesieve) + 2091 (cpdavd auxiliary, pending stability)
- meta:inventory header backfill for DA + cPanel sister conf.d files (Plesk got it in PR26.7.1)
- PR26.8-hygiene: explicit-name regression-guard tests (bare-control-port no-strong-detect, webmail-only-fails, rpcbind+cpanel presence-side guard)
- CyberPanel / CWP / InterWorx / Vesta / Generic adapters

### Standing rules

- Panel adapters beyond DirectAdmin + Plesk + cPanel are evidence-gated; no adapter built from assumptions.
- No restore authorized.
- No new destructive panel-host runs without operator authorization + Tier 1 rebuild.

---

## [Unreleased] - v1.100 PR-25 contract sheet (doc only)

Appends the PR-25 execution contract to `internal/installer/restore/contract.md` as a new "PART II — PR-25 execution contract" section (§§16–29). This is the doc-only first PR of the PR-25 two-PR split (mirrors the PR-24 PR #493 → PR #494 pattern). The implementation PR opens in a separate branch after this one merges.

### Origin

The contract is a faithful normalization of the **locked Q1–Q5 design decisions** recorded 2026-04-20 during PR-24 freeze Day 0 via the §12 protocol (Stage 1 scope classification + Stage 2 five-field answer + LOCK/REVISE/REJECT review). The v0 staging sheet (`memory/project_pr25_contract_sheet_v0.md`) was reviewed and locked 2026-04-27 prior to opening this PR.

### Locked rule applied

> *"Normalize, do not expand."*

Every clause in §§16–29 traces back to a Q1–Q5 lock or to V1100 contract §8. No design decisions were made in this PR. Items intentionally absent (final state-terminal names, final exit-code integers, test fixture matrix, real-host evidence plan, CI gate expansion plan, concrete `IsRestoreExecuted` signature, the PanelType→firewall mapping body) are documented in §27 as code-phase work.

### What changed

- `internal/installer/restore/contract.md` — appended §§16–29 (PR-25 execution contract) after §15 and before "Amendment history"; §1–§15 (PR-24 decision contract) untouched. New "PART II" header marks the boundary. Amendment history gains a 2026-04-27 v2 entry documenting the append + verified code anchors.

### Verified code anchors (2026-04-27)

| Lock reference | Verified at |
|---|---|
| `knownFirewallType` set `{ufw, firewalld, iptables, csf}` | `internal/installer/uninstall/prior.go:278-284` |
| writeHistory gate excluding `cfg.mode == "restore"` | `cmd/nftban-installer/main.go:132` |
| Exit-code constants `ExitCommitted=0`, `ExitFatal=4`, `ExitRefused=5`, `ExitIntentRequired=6` | `internal/installer/state/machine.go:149-155` |

All three live in surfaces that were fenced under the PR-24 freeze and remained untouched throughout the GOTH removal + SF-1 + repo hygiene stabilization train.

### Out of scope (locked)

- **No code in this PR.** PR-25 implementation (Go types, execution engine, inline safety interlock, state terminals, tests, CI gate update) is the *next* PR (`feat/v1.100-pr25-restore-execution`) and opens only after this contract PR merges.
- **No expansion** of Q1–Q5 lock content.
- PR-26 contract content stays out of scope (defined by PR-26's own seed work).

Lifecycle completion lane (PR-25..PR-30) remains explicitly **OPEN** but is now mid-re-entry: contract is the first deliberate step.

---

## [Unreleased] - v1.100.3e Repo hygiene Phase A slice 1e (H-07 + H-08)

Closes audit findings **H-07** (STATUS.md version drift) and **H-08** (README.md badge version drift). Both displayed visible-version strings that no longer matched `/VERSION` (1.98.2). STATUS.md claimed v1.89.0 (-9 minor versions); README badge pinned 1.95.0 (-3 patches).

### Changed

- `README.md:5` — replace static shield.io `version-1.95.0-blue` badge with auto-updating GitHub-tag form `https://img.shields.io/github/v/tag/itcmsgr/nftban?label=version&sort=semver&color=blue`. The badge now resolves to the latest semver tag at render time; future releases self-correct without a manual edit.
- `STATUS.md:6` — replace `**Current version:** v1.89.0` with `**Version (this commit):** v1.98.2 — sourced from [\`/VERSION\`](VERSION); static per commit, not auto-updated. For the current released tag see [GitHub releases] or the README badge.` This makes the source-of-truth explicit and clarifies the static-per-commit nature so future drift is harder.

### Out of scope (locked)

- No version bump. No tag decision.
- No CI gate / `bump-version.sh` automation. The badge is now self-updating; STATUS.md remains a manual touch-up at release time.
- No broader README cleanup.
- H-09 / H-16 / H-19 — separate slices (or deferred entirely).

Lifecycle completion lane (PR-25..PR-30) remains explicitly **OPEN**.

---

## [Unreleased] - v1.100.3d Repo hygiene Phase A slice 1d (H-05)

Closes audit finding **H-05**: 3 internal-roadmap references in tracked code/docs that are not resolvable by a public reader.

### Changed

- `CHANGELOG.md` (v1.80.0 release block) — drop the trailing "Refs:" subsection that pointed at the internal `V1.80_ROADMAP/MASTER_TODO.md` file. The release block content above (PR list with #371/#372/#373) remains the canonical record.
- `cli/lib/nftban/core/nftban_ip_and_stats.sh:73` — remove sentence pointing at `V1.80_ROADMAP/MASTER_TODO.md B80-1 discussion dated 2026-04-11`. Replace with `(B80-1)` so the planning tag survives without the unresolvable file path.
- `internal/loginmon/pipeline/doc.go:75` — remove `(see DEC-1..9 in MASTER_TODO.md)` parenthetical from package doc. Surrounding sentence preserved.

All 3 sites verified live in current tree before edit (per locked rule "first verify, then fix only confirmed live ones").

### Verification

`git grep -nE "V1\.80_ROADMAP|MASTER_TODO\b" -- ':(exclude).claude/*'` → **empty output** after this PR.

### Out of scope (deferred)

- H-07 / H-08 — version-sync (README badge, STATUS.md). No version-sync work in this slice (locked).
- H-09 / H-16 / H-19 — separate Phase A slices.
- Larger Phase A items (H-06 / H-11..H-19) — separate planning.

Lifecycle completion lane (PR-25..PR-30) remains explicitly **OPEN**.

---

## [Unreleased] - v1.100.3c Repo hygiene Phase A slice 1c (H-04)

Closes audit finding **H-04**: 3 internal-path comments referencing files under `/home/commonfolder/...` that are not part of the public repo. Particularly notable: the polkit rules file ships to every install, so the reference was visible on every operator host.

### Changed

- `cli/lib/nftban/lib/nftban_distro_config.sh:296` — drop `# See: /home/commonfolder/POLKIT-PATH-AUDIT-REPORT.md`. Reword the surrounding comment to merge the description into one sentence.
- `packaging/polkit-1/rules.d/30-nftban-panel.rules:243` — drop `// - /home/commonfolder/NFTBAN_PANEL_INTEGRATION_PLAN.md`. Adjacent "Panel Integration Phase 1" reference preserved.
- `tests/review/05_feeds_test.sh:28` — replace path with neutral phrasing "internal code-review checklist (05_FEEDS)".

All 3 sites verified live in current tree before edit (per locked rule "first verify the 3 H-04 sites still apply, then fix only confirmed live ones").

### Out of scope (deferred)

- H-05 / H-07 / H-08 / H-09 / H-16 / H-19 — separate Phase A slices.
- Larger Phase A items (H-06 / H-11..H-19) — separate planning.

Lifecycle completion lane (PR-25..PR-30) remains explicitly **OPEN**.

---

## [Unreleased] - v1.100.3b Repo hygiene Phase A slice 1b (H-01 / H-02 / H-03)

Mechanical dev-machine path cleanup across 6 files. Closes audit findings **H-01**, **H-02**, and **H-03**: hardcoded `/home/gituser/github/...nftban-v1.0-dev` and `/home/gituser/github/nftban-dev` defaults that leak the maintainer's filesystem layout and break non-author runs.

### Changed

- `scripts/export_cli_inventory.sh:35` (H-01) — replace hardcoded `/home/gituser/...` dev fallback with repo-relative resolution via `readlink -f "$0"` + `../cli/lib/nftban/cli`.
- `scripts/validate_cli_help.sh:32` (H-01) — same pattern.
- `cli/lib/nftban/tests/selftest.sh:1875` (H-01) — same pattern, using `BASH_SOURCE[0]`.
- `cli/lib/nftban/core/nftban_health_checks_config.sh:386` (H-02) — drop `/home/gituser/github/nftban-dev` from the auto-heal completion-source search list. Use `/usr/share/nftban/src` (canonical install-time source location) and add `${NFTBAN_DEV_SRC_DIR:-}` as opt-in env var for maintainers running out of a repo clone.
- `cli/lib/nftban/core/nftban_health_checks_services.sh:520` (H-02) — same pattern for the timer auto-install path.
- `tools/expand-config-schema.sh:22-23` (H-03) — make `INPUT_SKELETON` (positional `$1`) required via `:?` syntax (no public default for the internal skeleton path); resolve `OUTPUT_SCHEMA` (positional `$2`) repo-relative from the script's own location.

### Verification

Locked gate `git grep -nE "/home/gituser|/home/commonfolder|nftban-v1.0-dev" -- ':(exclude).claude/*'` produces only intentionally-deferred hits:

- 3 × H-04 sites (locked to slice 1c): `cli/lib/nftban/lib/nftban_distro_config.sh:296`, `packaging/polkit-1/rules.d/30-nftban-panel.rules:243`, `tests/review/05_feeds_test.sh:28`.
- 1 × `scripts/test_server_cleanup.sh:121` (`/root/nftban-v1.0-dev` in a one-shot dev cleanup script, not in the audit's H-list — handled separately).

> **Follow-up (2026-05-02, v1.101 PR #549, merge `b38fd216`):** line 121 was folded into the canonical `/root/nftban` cleanup on line 120; the `/tmp/nftban*` glob on the next line catches stragglers. Entry preserved above as historical record of the v1.100.3b release state.

### Out of scope (deferred)

- H-04 / H-05 / H-07 / H-08 / H-09 / H-16 / H-19 — separate Phase A slices.
- Larger Phase A items (H-06 / H-11 / H-12 / H-13 / H-14 / H-15 / H-17 / H-18) — separate planning.

Lifecycle completion lane (PR-25..PR-30) remains explicitly **OPEN**.

---

## [Unreleased] - v1.100.3a Repo hygiene Phase A slice 1a (H-10)

Smallest possible doc-only fix from the repo hygiene audit. Closes audit finding **H-10**: broken `[HEADER_SPEC.md]` link in `CONTRIBUTING.md:242` (file does not exist at repo root) and matching dangling reference in `tools/validate-headers.sh`.

### Changed

- `CONTRIBUTING.md`: section heading retitled from "HEADER_SPEC.md (File Headers)" to "File Headers". Removed the broken `[HEADER_SPEC.md](HEADER_SPEC.md)` link. Added a sentence noting that the inline section is itself the authoritative spec and that CI enforces it via `tools/validate-headers.sh`.
- `tools/validate-headers.sh`: error message no longer references the non-existent `HEADER_SPEC.md`. Pointer text now says "CONTRIBUTING.md, section 'File Headers' (authoritative spec)". Header comment updated to match.

### Out of scope (deferred to slice 1b)

- H-01 / H-02 / H-03 — dev-path cleanup. Separate micro-PR.

Lifecycle completion lane (PR-25..PR-30) remains explicitly **OPEN**.

---

## [Unreleased] - v1.100.2 SF-1 health CLI fix (released-host case)

Post-soak correctness fix derived directly from the PR-24 7-day passive soak. Side finding **SF-1** was logged on Day 6 (2026-04-26) on the released/no-tables host (lab4): `nftban health` printed a spurious `ERROR: Script failed` block on top of its own DOWN-status output.

### Root cause

The `nftban_health_cmd_truth` function correctly returns exit code 2 when the Go validator can't verify the kernel state on a released host (no nftban tables present). It also renders a clean DOWN status table before returning. However, three separate call sites under `set -Eeuo pipefail` did not protect the bare invocation from the ERR trap:

- `cli/lib/nftban/cli/cmd_health.sh:140` — case branch in `nftban_cmd_health` calling `nftban_health_cmd_truth "$json_mode"`
- `cli/lib/nftban/cli/cmd_health.sh:189` — second case branch (`json|--json` subcommand)
- `cli/sbin/nftban:917` — main() dispatch invoking `"nftban_cmd_${func_cmd}" "$@"` followed by a `return $?` that never reached because the trap had already fired
- `cli/sbin/nftban:1261` — top-level `main "$@"` where the script's set -e fires when main returns non-zero

When the validator exited 2, each unprotected level fired the ERR trap (defined in `lib/strict.sh`) which printed `ERROR: Script failed` to stderr on top of the legitimate DOWN table — confusing operators and contradicting the in-table message.

### Fix

Added the `cmd || return $?` (or `|| exit $?` at top level) idiom at all 4 sites. The pattern was already documented inside `nftban_health_cmd_truth` itself (lines 413-421) for the same reason on the inner validator call. The exit code semantics are preserved: a released host now exits 2 cleanly, matching the rendered `DOWN` status, with no spurious trap output.

### Verification

Local bash simulation reproduces the broken behaviour with the old pattern (TRAP-FIRED printed) and confirms the new pattern propagates exit 2 with no trap output.

### Out of scope for 1.100.2 (per locked instruction)

- Lifecycle execution surfaces remain untouched (`internal/installer/restore/*`, `internal/installer/state/file.go`, `cmd/nftban-installer/uninstall_apply.go`, etc.)
- SF-2 (stale `FAILURE_REASON` retained in state file after `COMMITTED`) — separate cleanup
- Repo hygiene Phase A — separate (1.100.3+)
- Lifecycle completion lane (PR-25..PR-30) — explicitly **OPEN**

---

## [Unreleased] - v1.100.1b.D GOTH docs/repo cleanup (closes the removal track)

Final phase of the GOTH/UI removal sequence (A → B → C1 → C2 → **D**). Cleans up the runtime-touching code paths and JSON registries that referenced the retired Web GUI surface, plus obsolete CI workflow steps that no longer have any consumer.

Wiki narrative cleanup was published separately to `nftban.wiki` (commit `39ab975`).

### Removed (operator-impacting)

- **`nftban health gui` health check**: deprecated function `nftban_health_check_gui()` removed entirely from `cli/lib/nftban/core/nftban_health_checks_integrations.sh` along with its dispatcher call site in `nftban_health.sh`. The health check inspected the retired `nftban-ui` binary, service, auth socket, and socket-directory permissions — all of which are gone.
- **`nftban-ui.service` health snapshot row**: dropped from `nftban_health.sh` `optional_services[]` and `optional_bins[]` arrays. `nftban health` no longer reports a stale "Web GUI not installed" row.

### Removed (files)

- `cli/lib/nftban/exporters/nftban_exporter_gui_cache.sh` — generated UI-only cache files (`traffic_history.json`, `dropped_by_country.json`, `dropped_by_port.json`) that the retired Web GUI consumed. The single sourcing site in `nftban_unified_exporter_collect.sh` is also removed.

### Removed (JSON registries)

- `cli/lib/nftban/data/fhs_directories.json`: dropped `/run/nftban-ui` directory entry.
- `cli/lib/nftban/data/config-schema.json`: dropped `NFTBAN_UI_BIN`, `NFTBAN_AUTH_BIN`, `NFTBAN_SERVICE_UI` schema entries.
- `cli/lib/nftban/data/reports-registry.json`: dropped `api` channel entry (depended on `nftban-ui.service`).

### Removed (FHS spec + security check)

- `cli/lib/nftban/core/nftban_fhs_spec.sh`: dropped `/run/nftban-ui` `NFTBAN_FHS_DIRECTORIES` entry.
- `cli/lib/nftban/core/nftban_health_checks_security.sh`: dropped `nftban-ui.service` from systemd-analyze key-services list.

### Removed (CI workflows — obsolete templ + libpam steps)

After C1+C2 removed all `.templ` files, `_templ.go` generated files, `msteinert/pam/v2` imports, and PAM-using packages, the templ-install and `libpam0g-dev` apt-install steps in CI workflows are pure dead steps (verified: zero `.templ` / `_templ.go` / `"C"` / `msteinert/pam` references remain in tree).

Removed steps from:
- `.github/workflows/ci-go.yml` — templ install/generate/verify + libpam0g-dev install
- `.github/workflows/build-packages.yml` — templ install + libpam0g-dev install
- `.github/workflows/ci-smoke.yml` — templ install/generate + libpam0g-dev (kept nftables, jq)
- `.github/workflows/codeql.yml` — templ install/generate + libpam0g-dev install
- `.github/workflows/secure-go.yml` — templ install/generate + libpam0g-dev install
- `.github/workflows/osv-scanner.yml` — libpam0g-dev install
- `.github/workflows/project-health.yml` — templ install/generate + libpam0g-dev (kept shellcheck, shfmt, yamllint, jq, devscripts, nftables)
- `.github/workflows/release.yml` — libpam0g-dev install
- Decommission comments in `release.yml`, `slsa-go-releaser.yml`, `ci-runtime-truth.yml`

CGO build flags are preserved (still required for nftban-core/nftband transitively).

### Notes

This release closes the GOTH/UI removal track. From this point forward, no shipped binary, no built artifact, no health check, no JSON registry entry, no CI build step, and no wiki page references the retired Web GUI surface in active form. Historical references survive only in the dedicated `archive/` wiki pages and the CHANGELOG entries for stages A → D.

Out of scope (lifecycle completion lane — explicitly **OPEN**):
- PR-25 restore execution
- PR-26 verification gate
- PR-27 logrotate unified config
- PR-28 missing log rotation
- PR-29 GeoIP validator freshness
- PR-30 timer alignment

---

## [Unreleased] - v1.100.1b.C2 GOTH cross-cutting prune

### Removed (operator-impacting)

- **`nftban gui` subcommand**: retired entirely. The web GUI was decommissioned in 1.100.1b.A; the CLI command that managed it (build/install/enable/disable/restart/status/port) is now removed. `nftban menu` (curses TUI) is unaffected.
- **`nftban health gui` subcommand**: retired entirely. Validated the GOTH ui-registry.json which was deleted in 1.100.1b.B.
- **`nftban-ui.service` references** in `nftban status` SERVICES section + JSON output: removed.
- **Web GUI line** in main `nftban` status overview: removed.

### Removed (files)

- `cli/lib/nftban/cli/cmd_gui.sh` — managed the retired nftban-ui binary
- `cli/lib/nftban/health/check_gui.sh` — validated the retired GOTH ui-registry.json
- `cli/cmd_ui.sh` — dead since GOTH (never wired into dispatcher)
- `packaging/rpm/nftban-ui.spec` — RPM spec for the retired nftban-ui package
- `packaging/deb/rules` — debhelper rules file for the retired nftban-ui Debian package

### Removed (Go surface)

- `internal/nftbanconf`: `UIService`, `UIAuthService`, `UIBin`, `AuthBin`, `UIAuth` (sockets), `UI`/`UIAuth` (PIDFiles) and their accessors/defaults/parsers
- `internal/installer/services/daemon.go`: nftban-ui-auth.socket enable+start block
- `internal/installer/fhs/paths.go`: `RunUIDir` constant + matching FHSDirectory entry
- `internal/installer/payload`: 2 UI staging entries + `uiRemoveInV2` struct field/handler/test

### Removed (dependencies)

- RPM: `Requires: pam` (was only needed by nftban-ui-auth)
- DEB: `Depends: libpam0g` (same)

### Notes

C2 is the cross-cutting cleanup pass after 1.100.1b.B (source delete) and 1.100.1b.C1 (orphan-package delete). Files that existed solely for the retired GOTH/UI surface were deleted; mixed-responsibility files were carved surgically.

Out of scope for C2 (deferred to **1.100.1b.D**):
- Documentation narrative cleanup (CHANGELOG history, ARCHITECTURE.md, REPRODUCIBLE_BUILDS.md, docs/systemd/UNITS.md/TIMERS.md)
- Workflow comment cleanup (.github/workflows/*.yml — comments only document v1.100.1b.A's removal)
- Broader cli/lib/ cleanup beyond the locked cmd_*.sh + health-check scope (e.g., `core/nftban_health.sh`, `core/nftban_health_checks_integrations.sh`, `core/nftban_fhs_spec.sh`, `data/fhs_directories.json`, `data/config-schema.json`, `data/reports-registry.json`, `helpers/autoheal.sh`, `exporters/nftban_exporter_gui_cache.sh`)

Lifecycle completion lane (PR-25 restore execution, PR-26 verification gate, PR-27-30 maintenance) remains explicitly **OPEN** and is not affected by this release.

---

## [Unreleased] - v1.100.1b.C1 GOTH orphan-package delete

### Removed

- **`internal/api/`** (35 files, ~9,435 LOC): GOTH HTTP handlers — orphaned after 1.100.1b.B deleted `cmd/nftban-ui` (the only consumer of these handlers).
- **`internal/middleware/`** (3 files, ~932 LOC): GOTH HTTP middleware (auth, rate limiter) — orphaned after `internal/api` lost its consumer.
- **`internal/auth/`** (2 files, ~457 LOC): PAM authentication wrapper — orphaned after `internal/api` and `internal/middleware` lost their consumers.
- **`internal/session/`** (1 file, ~219 LOC): in-memory session store — orphaned after the same cascade.
- **`internal/authproto/`** (1 file, ~53 LOC): PAM protocol types — orphaned after `internal/auth` lost its consumer.

### Notes

These 5 packages formed a closed dependency subgraph after 1.100.1b.B: every cross-edge was internal to the set, and zero non-self packages imported any of them. The single outside reference in `cmd/nftband/daemon_http.go:82` was a TODO comment, not an import.

Out of scope for C1 (deferred to **C2**):
- `internal/nftbanconf/` UIService/UIAuthService field removals
- `cli/lib/cmd_*.sh` nftban-ui carveouts + dead `cli/cmd_ui.sh` delete
- `internal/installer/` UI socket-enable + payload + paths carveouts
- `packaging/` (`rpm/nftban-ui.spec`, `deb/rules`, `build_nftban.sh`) carveouts

Workflow comment cleanup, doc cleanup, and changelog narrative cleanup remain deferred to **1.100.1b.D**.

Lifecycle completion lane (PR-25 restore execution, PR-26 verification gate, PR-27-30 maintenance) remains explicitly **OPEN** and is not affected by this release.

---

## [Unreleased] - v1.100.1b.B GOTH PR-D4 stage 2 (source-tree delete)

### Removed

- **`cmd/nftban-ui/`** (entire directory): the GOTH-stack web server source tree. 9 files, ~6,947 LOC. Includes `main.go`, the 5 handler files, and the dev-mode shell scripts.
- **`cmd/nftban-ui-auth/`** (entire directory): the PAM-backed authentication daemon source tree. 1 file, 249 LOC.
- **`internal/ui/`** (entire package): the templ-rendered UI surface — layout, types, ui-registry.json, plus the `pages/` and `components/` subtrees. 34 files, ~23,894 LOC.

### Notes

This is a **narrow source delete** (3 directories with zero non-self Go consumers). The orphaned-but-still-compiling packages — `internal/api`, `internal/middleware`, `internal/auth`, `internal/session`, `internal/authproto` — are intentionally **not** removed in this release. They will be deleted in v1.100.1b.C alongside the cross-cutting reference cleanup in `cli/lib/`, `internal/installer/`, and `internal/nftbanconf/`.

Build still passes (`go build ./...`) after this delete because the orphaned packages still compile internally; the static dependency graph between them is intact even though they have zero callers.

Lifecycle completion work (PR-25 restore execution, PR-26 verification gate, PR-27-30 maintenance) remains explicitly **open** and is not affected by this release.

---

## [Unreleased] - v1.100.1b.A GOTH PR-D4 stage 1 (stop shipping nftban-ui + nftban-ui-auth)

### Changed (operator-impacting)

- **`nftban-ui` (Web GUI server) and `nftban-ui-auth` (PAM auth daemon) are no longer shipped.** New releases under v1.100.1b.A and later do not include these binaries, their systemd units, or their SLSA provenance artifacts.
- **Existing installs receive automatic cleanup on upgrade.** Transitional postinst/prerm hooks (DEB) and `%pre` scriptlet (RPM) stop, disable, mask, and remove any prior `nftban-ui.service`, `nftban-ui-auth.service`, `nftban-ui-auth.socket` units, plus the `/usr/sbin/nftban-ui` and `/usr/libexec/nftban-ui-auth` binaries and `/run/nftban-ui` runtime directory.
- **PAM development headers are no longer a build requirement** for the standard `nftban` package (only `nftban-ui-auth` consumed PAM, and it is no longer built).

### Removed from build / packaging / release pipeline

- `.github/workflows/ci-go.yml`: nftban-ui + nftban-ui-auth build/verify entries removed.
- `.github/workflows/build-packages.yml`: nftban-ui + nftban-ui-auth removed from binary inventory loops.
- `.github/workflows/slsa-go-releaser.yml`: `build-nftban-ui` job removed; assemble-release no longer downloads nftban-ui artifacts.
- `.github/slsa/nftban-ui.yml` and `.github/slsa/nftban-ui-auth.yml`: deleted.
- `.github/workflows/release.yml`: nftban-ui + nftban-ui-auth removed from binary copy step, asset-replacement list, expected-package list, expected-asset list, SHA256SUMS.build binary list, draft-release upload list, and SLSA download retry loop.
- `build.sh`: `build_gui`, `build_ui_auth`, `generate_templ` functions removed; `gui` and `ui-auth` subcommands now error with explanation; PAM headers prerequisite check removed; `nftban-ui` and `nftban-ui-auth` removed from `go mod tidy` loop.
- `packaging/build_nftban.sh`: RPM `%install` no longer installs the binaries or systemd unit files; RPM `%files` no longer references them; DEB build helper drops the equivalent installs. RPM `%pre` and DEB prerm now also disable + mask + remove orphaned unit files transitionally.
- `packaging/deb/postinst`: `/usr/sbin/nftban-ui` removed from chown/chmod loop.
- `packaging/deb/prerm`: extended transitional cleanup (disable + mask + remove unit files + delete orphaned binaries).
- `install/download-binaries.sh`: nftban-ui + nftban-ui-auth removed from fetch, install, verify, and SLSA-provenance check loops.
- `install/verify_installation.sh`: optional checks for `/usr/sbin/nftban-ui`, `nftban-ui.service`, `nftban-ui-auth.socket` removed.

### Notes

- Source trees under `cmd/nftban-ui/`, `cmd/nftban-ui-auth/`, `internal/ui/`, `internal/auth/`, `internal/session/`, `internal/authproto/` are **intentionally retained** in the repo at this stage. They will be removed in a separate later release (v1.100.1b.B). They still compile via `go build ./...` and their unit tests still run, but the binaries are no longer published.
- Cross-cutting shell + Go references to the UI surface (87 in `cli/lib/`, 13 in `internal/installer/`, 14 in `internal/nftbanconf/`, 6 in `internal/api/`) are **also intentionally retained** at this stage. They will be cleaned up in v1.100.1b.C.
- Documentation references (`docs/ARCHITECTURE.md`, `CONTRIBUTING.md`, `docs/REPRODUCIBLE_BUILDS.md`, `SECURITY.md`, `docs/systemd/UNITS.md`, `docs/systemd/TIMERS.md`) are not edited in this release; deferred to v1.100.1b.D.
- Lifecycle completion work (PR-25 restore execution, PR-26 verification gate, PR-27-30 maintenance) remains explicitly **open** and is not affected by this release.

### Why a transitional approach

A hard removal would orphan running services on prior-version hosts (operators with active `nftban-ui.service` would get it left behind after upgrade). The transitional approach disables, masks, and removes the unit files via the package's own upgrade hooks, so the post-upgrade state is clean even though the new package no longer carries those artifacts.

---

## [Unreleased] - v1.100.1a CLI jail surgical rename

### Changed

- **`nftban stats --json` dual-key alias**: output now emits both
  `top_jails` and `top_filters` keys with the same value. `top_jails`
  is **deprecated** and will be removed in a later release; downstream
  consumers should migrate to `top_filters`. One-cycle deprecation per
  the locked surgical-rename scope (`top_jails` is the only operator-
  parseable surface affected; internal variable + function names
  unchanged in this release).
- **`cli/lib/nftban/cli/cmd_search.sh`** purpose comment: replaced
  "jails" → "filters". Comment-only change, no behavior impact.
- **`etc/nftban/conf.d/login/services.conf`** comment narration at
  9 sites: `[nftban-XXXX] jail` → `[nftban-XXXX] filter`. Comment-
  only edit; env var convention (`LOGIN_SERVICE_<SERVICE>_<SETTING>`)
  unchanged.

### Notes

- Internal struct/type renames (`escalation.BanEntry.Jail` field,
  `nftban_stats_top_jails` function name, etc.) are intentionally
  **out of scope** of this surgical rename. They will be addressed
  in a separate later PR if needed.
- Lifecycle completion work (PR-25 restore execution, PR-26 verification
  gate, PR-27-30 maintenance) remains explicitly **open** and is not
  affected by this rename.

---

## [Unreleased] - v1.100 PR-22A + PR-22B repair cycle

### Changed

- **v1.100 lifecycle truth repair** (PRs #480, #481, #482). Observational
  paths (install refused, update and uninstall dry-run) are now
  structurally honest. `StateFile.DryRun` suppresses state-file writes;
  `writeHistory` gated on `!cfg.dryRun && state.IsApplyTerminal(sf.State)`;
  `authority.IsNftbanAuthoritative` is the canonical predicate used by
  both `authority.Classify` and `update.Preflight`. New `Ambiguous`
  authority decision for orphan-table / daemon-down hosts routes through
  the emergency-SSH injection path. `--panel-auto-takeover` flag
  (default off) replaces the previous implicit panel auto-approve.
  Flag validation now rejects `--mode=install --dry-run`,
  `--repair --dry-run`, `--takeover --dry-run`, `--rpm --deb`, and
  `--force-delete-operator-config` without `--purge`.

### Data-integrity note

- **Lifecycle-bridge authority mapping (v1.98 — v1.99)** — the
  `observePlan` and `mapAuthority` switches in
  `cmd/nftban-installer/lifecycle_bridge.go` compared uppercase
  `authority.Decision` values (e.g. `"TAKEOVER"`) against lowercase
  string literals. The switches silently hit their `default` arms on
  every real run, so lifecycle consumers saw `ActionPreserveAuthority`
  and `AuthorityNone` regardless of the installer's actual decision.
  Fixed in PR-22B (#482) — switches now pin to `authority.Decision`
  constants; `Ambiguous` maps to a new `lifecycle.AuthorityUnknown`
  owner.

  **Impact on historical records**: any lifecycle telemetry,
  dashboards, or audit-trail consumers that ingested
  `lifecycle.RunResult` JSON between v1.98 and the merge of PR-22B
  will show `PreserveAuthority` / `AuthorityNone` on every install and
  update run regardless of what actually happened on the host. This
  does NOT affect install_state, update-history.json, or kernel
  behavior — only the lifecycle bridge's external reporting surface.
  Forensic interpretation of pre-PR-22B lifecycle output should treat
  the authority decision as "unknown" rather than "preserve."

## [1.98.2] - 2026-04-19

**Runtime correctness patch — exit-code truth, health resilience, installer payload truth.**

Narrow patch release closing the three correctness follow-ups surfaced by
the v1.98.1 operational audit. No new modules, no lifecycle or API surface
changes. Positioned as runtime correctness + monitoring/scriptability fix
+ installer truth hardening.

### Fixed

- **R-1 — `nftban validate` exit code** (issue #469). The CLI shim derived
  exit only from the jq-mapped error-severity finding count; a Go
  `status: down` that lacked critical-severity findings silently yielded
  exit 0 — the exact "misleading success" class the project warns against.
  Exit is now the max of three signals: error-count, validator binary rc,
  and `.status ∈ {down, degraded}`. Contract:
  - `protected` / `idle` → 0
  - `degraded` → 1
  - `down` → 2
  - validator binary crashed / unreachable → 3
- **R-2 — `nftban health check` bash trap crash** (issue #470).
  `nftban_health_cmd_truth()` captured validator output via
  `output=$("$validator_bin" --json …)` under `set -Eeuo pipefail`; a
  non-zero validator exit propagated to the ERR trap and killed the CLI
  at the exact moment operators reach for it. Now wrapped in an
  if/assignment with explicit rc capture, stderr excerpt, and a bounded
  DOWN diagnostic (non-zero exit, scriptable, no trap).
- **R-3 — installer payload truth** (issue #463). Payload staging now
  tallies per category (binaries, shell, configs, systemd, polkit,
  logrotate, docs, version) and emits an INFO-level category summary in
  the installer log. Required-artifact failures are surfaced at WARN
  with a pointer to the downstream assertion.

### Added

- **`payload_inventory_ok` assertion** (R-3): material completeness
  check in `validate.RunAssertions`. Verifies canonical destinations
  exist post-install — `/usr/sbin/nftban`, `/usr/lib/nftban/VERSION`,
  `/etc/nftban/nftables.conf`, `/etc/logrotate.d/nftban`, plus the
  non-empty shell payload roots under `/usr/lib/nftban/`. Failure
  blocks `COMMITTED` via the existing VALIDATE_1 → FIX → VALIDATE_2
  flow. This is the assertion that would have caught the missing
  VERSION file before v1.98.1 tag.
- **G-CI-1 Runtime Truth Gate** (`.github/workflows/ci-runtime-truth.yml`).
  Matrix: Ubuntu 24.04 + AlmaLinux 9. Seven sub-gates:
  G1 validate exit truth | G2 health failure handling |
  G3 payload inventory truth | G4 payload summary logging |
  G5 source-install parity | G6 idempotency |
  G7 package non-regression (delegated to `build-packages.yml`).
  Blocking on merge.

### Changed

- `nftban validate --help` exit-status section now documents the
  four-code contract (0/1/2/3) instead of the previous two-code stub.

### Risks surfaced in patch notes

- Exit-code semantics: scripts that relied on buggy `validate` exit 0
  under failure will now see non-zero. This is a correctness fix,
  called out explicitly.
- Inventory assertion scope: only *required* artifacts checked —
  optional / distro-conditional entries (man pages, polkit on distros
  without it, UI binaries marked `uiRemoveInV2`) are exempt to avoid
  breaking legitimate installs.

### PRs

| PR | Title |
|---|---|
| TBD | release: v1.98.2 — runtime correctness patch |

---

## [1.98.1] - 2026-04-19

**Install canonization closure — 7-distro G2 parity + runtime detection validation.**

Closes the v1.98.x install canonization track. `install.sh` is now a 13-line
bootstrap; all payload staging, user/group creation, and manual-whitelist
seeding live in the Go installer under an explicit `--source` gate. Source
install produces the same end-state as package install across 7 distros.
Detection pipeline proven end-to-end (SSH abuse → kernel-side ban) on both
DEB and RPM lab victims.

### Added

- **Go source-install support** (G-14-A..I, PR #462):
  - `internal/installer/users/Ensure()` — creates `nftban`, `nftban-auditor`,
    `nftban-panel`, `suricata` groups + `nftban` user with distro-family
    dispatch (`adduser`/`addgroup` on Debian, `useradd`/`groupadd` on RHEL).
    Idempotent — safe on re-run.
  - `internal/installer/payload/StageAll()` — data-driven payload stager
    (30 entries) honouring `policyAlways` vs `policyConfigNoReplace`
    (RPM `%config(noreplace)` / DEB conffile semantics). `.conf.local`
    files are never overwritten (invariant #9).
  - `internal/installer/payload/copyIfChanged()` — defensive
    `MkdirAll(filepath.Dir(dst), 0755)` for subdirs outside the FHS
    registry (fixes payload failures on `/usr/lib/nftban/cli`, `/core`).
  - `internal/installer/safety/SeedManualWhitelist()` — seeds operator IPs
    into `/etc/nftban/whitelist.d/manual.local` with IP autodetection.
  - `--source` + `--source-dir` flags on `nftban-installer` with mutex
    validation against `--rpm` / `--deb`.
- **soak observation tooling** (PR #461):
  - `scripts/nftban-soak-check.sh` with `retry_on_127` helper and
    bounded JSON output.
  - `nftban-soak.service` + `.timer` (`OnCalendar=0/2:17`,
    `RandomizedDelaySec=300`) — replaces cron-storm-prone HH:00 cron entry.
    Sandbox: `ProtectSystem=strict`, `RestrictAddressFamilies=AF_UNIX
    AF_INET AF_INET6 AF_NETLINK`, `CPUQuota=50%`, `MemoryMax=128M`.
  - logrotate entry for `/var/log/nftban/soak/cron.log`.
  - tmpfiles.d entry for `/var/log/nftban/soak` (source: `build/fhs-spec.yaml`).

### Changed

- **`install.sh` reduced to 13-line bootstrap** (PR #464, −388 lines):
  verifies root + Linux, locates `nftban-installer` (staged or
  `/usr/lib/nftban/bin/`), exports `NFTBAN_SOURCE_DIR`, `exec`s the Go
  installer with `--source --mode=install`. Zero business logic in shell.
- **NB-5 packaging perm fix**: `/usr/sbin/nftban*` binaries installed at
  `root:nftban 0750`. DEB `postinst` convergence block runs after the
  `nftban` group is created; RPM spec uses `install -D -m 0750` +
  `%attr(0750,root,nftban)`.

### Fixed

- **version.sh unbound-var crash** (PR #468, P0): `_nftban_read_version()`
  declared `local version_file` without initialization; under
  `set -Eeuo pipefail` the `[[ -f "$version_file" ]]` probe crashed when
  no lookup path matched. Since `version.sh` is sourced first by every
  CLI entry point, every subcommand crashed on source installs where
  `/usr/lib/nftban/VERSION` was missing. Fix: initialize `local
  version_file=""` and add `-n` guard before `cat`.
- **VERSION staging gap** (PR #468): `VERSION` file was not in the
  payload entry table — source installs produced a working daemon but
  broken CLI. Added `{srcRel: "VERSION", dstGlob: "/usr/lib/nftban/VERSION",
  mode: 0644, policy: policyAlways}` entry.
- **`install.sh` +x bit regression** (PR #466): PR #464 shipped at mode
  0644 (Write tool default). Restored with `git update-index --chmod=+x`.

### Removed

- **3 legacy install scripts deleted** (PR #465, −1,592 LOC):
  `install_binaries.sh` (398), `install_configs.sh` (537),
  `install_services.sh` (657). All functionality moved into Go.

### Tracked follow-ups (non-blocking for v1.98.1)

| # | Item | Severity | Tracking |
|---|------|----------|----------|
| FU-1 | `payload.StageAll` should escalate non-zero `failed` to phase error + `payload_inventory_ok` assertion | Medium | Issue #463 |
| FU-2 | `deps.InstallMissing` should `apt-get update` before `apt-get install` | Low | Issue #467 |
| FU-3 | `/usr/sbin/nftban-ui` ownership drift (`root:root 750` vs spec `root:nftban 0750`) | Cosmetic | v2.0.0 PR-D4 UI decommission |
| FU-4 | Lab `/tmp` noexec — affects manual `./install.sh` from `/tmp` | Environmental | documented |

### Operational audit evidence

- **7-distro G2 parity**: Ubuntu 22.04/24.04, Debian 12/13, AlmaLinux 9,
  Rocky 9.7, CentOS Stream 10 — 6 clean COMMITTED (287/3/0
  wrote/skip/fail, 8/8 assertions), 1 authority-safety invariant PASS
  (UFW abort on Ubuntu 22.04, invariant #6 working as designed).
- **CLI shell surface**: 34/34 commands × `help` across DEB + RPM,
  0 crashes, 0 version.sh regressions.
- **Detection pipeline**: SSH abuse → `[BAN] Successfully banned
  46.225.157.122 (timeout=900s, source=loginmon)` in <4 seconds on both
  Ubuntu24-DEB and AlmaLinux9-RPM. Kernel blacklist set populated.
- Evidence bundle: `/tmp/v1.98.1-audit/` (installation/, runtime/,
  binaries/, session-logs/).

### Closure chain

| Commit | PR | Title |
|--------|-----|-------|
| fe07942c | #468 | fix: stage VERSION + version.sh unbound-var hardening |
| 43722b21 | #466 | fix: restore install.sh +x bit (PR #464 regression) |
| ec0abe40 | #465 | feat: delete legacy install scripts (−1,592 LOC) |
| 58d671d9 | #464 | feat: install.sh bootstrap (401→13 body lines) |
| 2f1a994c | #462 | feat: Go-side source-install support (G-14-A..I) |
| (earlier) | #461 | tooling: soak + NB-5 packaging |

---

## [1.89.0] - 2026-04-16

**Metrics reduction — duplicate queries eliminated, naming corrected, safety metrics wired.**

### Changed

- **Evidence layer refactored** (INV-M-002): evidence snapshot now calls
  `validator.ValidateKernel()` directly instead of making 19 redundant
  nft CLI calls. Counters, chains, and set element counts extracted from
  the validator's parsed kernel data. Evidence layer makes ZERO direct
  nft calls.
- **Watchdog metric renames** (INV-M-007): 6 `nftban_go_*` metrics renamed
  to `nftban_runtime_*` to avoid collision with Go's standard collector.
  Old names registered as deprecated aliases (removed in v1.90).
- **Gauge naming fix** (INV-M-007): 3 gauges incorrectly using `_total`
  suffix renamed (`softnet_drops_total` → `softnet_drops`, etc.).
  Old names registered as deprecated aliases (removed in v1.90).
- **Safety metrics wired** (INV-M-008): `SetMemoryPressureLevel()`,
  `SetProtectionActive()`, `SetProtectionFeedsSkipped()`,
  `SetProtectionGeobanSkipped()`, `SetMemoryBudgetBytes()`,
  `SetMemoryUsedPercent()` now called from exactly 2 call sites
  (sync handler + watchdog callback). Previously defined but never called.
- Sampler (`sampler.go`) marked DEPRECATED (INV-M-006). No new code may
  import `GetSampler()`. Existing callers grandfathered until v1.90.
- `nftban_exporter_gui_cache.sh` and `nftban_exporter_json_compat.sh`
  marked TRANSITIONAL with removal timeline.

### Removed

- **3 legacy shell exporters** deleted: `nftban_firewall_exporter.sh`,
  `nftban_geoban_exporter.sh`, `nftban_portscan_exporter.sh`. All metrics
  covered by unified exporter and Go daemon.

### Deprecated metric aliases (remove in v1.90)

| Old Name | New Name |
|----------|----------|
| `nftban_go_goroutines` | `nftban_runtime_goroutines` |
| `nftban_go_gc_cpu_fraction` | `nftban_runtime_gc_cpu_fraction` |
| `nftban_go_gc_pause_seconds` | `nftban_runtime_gc_pause_seconds` |
| `nftban_go_heap_alloc_bytes` | `nftban_runtime_heap_alloc_bytes` |
| `nftban_go_heap_inuse_bytes` | `nftban_runtime_heap_inuse_bytes` |
| `nftban_go_heap_released_bytes` | `nftban_runtime_heap_released_bytes` |
| `nftban_softnet_drops_total` | `nftban_softnet_drops` |
| `nftban_softnet_time_squeeze_total` | `nftban_softnet_time_squeeze` |
| `nftban_nic_rx_dropped_total` | `nftban_nic_rx_dropped` |

### Global invariants enforced

| # | Invariant | Status |
|---|-----------|--------|
| INV-M-001 | Kernel read once via validator | Enforced |
| INV-M-002 | Evidence layer ZERO nft calls | Enforced |
| INV-M-003 | Each metric has ONE owner | Enforced |
| INV-M-004 | /metrics stable and available | Unchanged |
| INV-M-005 | Shell exporters don't dup daemon | Unchanged |
| INV-M-006 | Sampler deprecated | Enforced |
| INV-M-007 | Renames include compat aliases | 9 aliases registered |
| INV-M-008 | Watchdog = sole pressure writer | 2 call sites only |

---

## [1.88.0] - 2026-04-16

**Metrics Phase 2 — journal evidence, data freshness, observability docs.**

### Added

- **Total processed packets** (M88-1): sum of all nftables counters
  (accepts + drops + flow markers). Labeled explicitly to prevent
  misinterpretation.
- **Journal evidence for LoginMon** (M88-2): bounded 15m/500-line
  journal query for ban and login_failed events. LoginMon promoted
  from `expected_limitation` to evidence-backed correlation.
- **Feed data freshness** (M88-3): checks newest file in
  `/var/lib/nftban/feeds/`, fresh if < 7 days.
- **GeoIP DB freshness** (M88-4): checks mmdb mtime, fresh if < 45 days.
- **Anchor flow counters** (M88-6): 7 pipeline stage counters displayed
  as "pipeline stage transitions, not enforcement."
- **Evidence contract doc** (M88-9): `docs/EVIDENCE_CONTRACT.md` — defines
  evidence states, counter/set/chain/journal semantics, correlation
  rules, and nft compatibility reference.
- **Build status page** (M88-10): `docs/BUILD_STATUS.md` — 26 CI workflows,
  contract gates (G1-G8 + B86 + M84 + M87/M88), host runtime gate,
  health policy.

### Changed

- **LoginMon correlation**: promoted from `expected_limitation` to
  evidence-backed. Bans + validator agrees = match. Bans + idle = warning.
  Events only = warning. No journal = unknown.
- **Evidence schema**: bumped to 1.88.0. Added `external` (journal) and
  `freshness` (data pipeline) planes.
- All evidence file metadata updated to v1.88.

### PRs

| PR | Title |
|---|---|
| #429 | feat(metrics): v1.88 Metrics Phase 2 |

---

## [1.87.2] - 2026-04-16

**nft command compatibility hotfix.**

### Fixed

- **3 broken nft command patterns** across 8 locations (Go + shell).
  The `list <plural> <family> <table>` syntax is NOT supported on fleet
  nftables versions (v1.0.2 through v1.1.1):
  - `nft list counters <family> <table>` → use global `nft -j list counters`
  - `nft list chains <family> <table>` → use `nft list table <family> <table>`
  - `nft list sets <family> <table>` → use `nft list table <family> <table>`
- **Counter evidence now working** on all fleet hosts. Previously showed
  "counter evidence unavailable" on every host due to broken command.
- **cmd_stats.sh dropped count**: now sums only `_drop` and `_exceeded`
  counters (was incorrectly summing all counters including accepts).

### PRs

| PR | Title |
|---|---|
| #427 | fix(nft): command compatibility hotfix — 3 broken patterns |

---

## [1.87.1] - 2026-04-15

**CLI runtime bug fixes + host-side smoke gate.**

### Fixed

- **`nftban status` bash error**: `_unit_is_active()` crashed with "bad
  array subscript" when called with empty unit name. Dynamic variables
  like `$prometheus_service` expanded to empty on hosts without that
  component. Fix: return inactive for empty input, no bash error.
- **Smoke test FINAL anchor**: was checking `.families[].anchors.final_present`
  in validator JSON, but `HealthOutput` schema does not include families.
  Fix: check kernel directly via `nft list chain` + grep `ANCHOR_FINAL`.

### Added

- **`test_cli_runtime.sh`**: host-side CLI runtime smoke gate. Runs 27
  primary CLI commands and catches bash runtime errors (bad array subscript,
  unbound variable, syntax error). Does not check exit code semantics.
  Verified: 27/27 pass on AlmaLinux 9 + Ubuntu.

### PRs

| PR | Title |
|---|---|
| #423 | fix(cli): runtime bug fixes + CLI smoke gate |

---

## [1.87.0] - 2026-04-15

**Metrics Phase 1 — kernel evidence & correlation foundation.**

First production-safe metrics evidence layer. Collect once → render many.
Evidence reports what the kernel is doing; validator interprets what it means.

### Added

- **Named counter collector** (M87-2): structured evidence from all nftables
  named counters. Context-bound, Prometheus preserved as side-effect.
- **Set element collector** (M87-3): per-set element counts with three-state
  semantics (present/absent/unknown). JSON parsing, not text parsing.
- **Chain presence collector** (M87-4): chain presence per family with
  family-level failure → all chains unknown.
- **Validator snapshot bridge** (M87-5): read-only bridge to nftban-validate
  JSON. Status required, missing → unknown.
- **Correlation engine** (M87-6): pure function comparing kernel evidence
  against validator interpretation. Conservative: unknown inputs → unknown
  output. 5 result values: match/mismatch/warning/expected_limitation/unknown.
- **EvidenceSnapshot model** (M87-7): canonical Phase 1 structure with
  separated Kernel/Validator/Correlation planes.
- **Human renderer** (M87-8): operator-first text output distinguishing
  unavailable vs zero evidence.
- **`nftban metrics evidence`** / **`evidence-json`** CLI (M87-9).
- **Schema validation tests + golden fixture** (M87-10): 13 schema tests
  locking JSON contract, nil vs empty counters, omitempty, enum safety.
- **Evidence contract doc** (M87-11): 12-section specification defining
  evidence semantics, collector contracts, correlation rules.

### Fixed

- **MG-9** (M87-1): Firewall exporter queried `inet filter` instead of
  `ip nftban`. Fixed to correct table.

### Evidence Contract

- Evidence is NOT a truth object — validator remains sole authority
- Three states: present / absent / unknown (never guessed)
- Correlation is diagnostic only — cannot affect exit codes or status
- Zero counters are neutral, not failure
- Shared counters are family-level only; no source attribution

### PRs

| PR | Title |
|---|---|
| #418 | fix(exporter): query ip nftban not inet filter (MG-9) |
| #421 | feat(metrics): v1.87 complete evidence layer (M87-2 through M87-10) |

---

## [1.86.0] - 2026-04-15

**Contract finalization — single truth model, no ambiguity.**

### Removed

- **ModuleTruth completely deleted** (B86-1): ModuleStatus type,
  ModuleInfo type, deriveModuleTruth(), boolToStatus(), enabledStr(),
  module_truth JSON field. Zero legacy references remain. ModuleHealthMap
  is the only canonical module inventory. -130 lines.
- **Deprecated `.state` JSON key** (B86-3): Only `.status` remains in
  `nftban status --json`. Was scheduled for removal since v1.82.

### Changed

- **Classification clarity** (B86-2): Split CORE into CORE_MODULE
  (protection modules with dedicated evaluators) and CORE_INFRA
  (internal support served by parent evaluators). 5 CORE_MODULE +
  3 CORE_INFRA. Eliminates ambiguity about what needs an evaluator.
- **PrintSummary()** (B86-1): Now renders 4-axis module health from
  ModuleHealthMap instead of the deleted ModuleTruth.
- **"OK (info notices)"** → **"PROTECTED (info notices)"** (B86-3).

### Added

- **CI legacy regression blockers** (B86-4): grep-based CI checks
  prevent reintroduction of ModuleTruth or legacy fallback constructs.
  Any match = CI failure.
- **docs/CONTRACT_RULES.md** (B86-5): 20 numbered contract rules
  defining truth authority, module inventory, classification taxonomy,
  evidence rules, CLI output rules, and forbidden constructs. Single-page
  contributor reference for the 1.x contract.

### PRs

| PR | Title |
|---|---|
| #410 | fix(validator): correct GeoIP database path |
| #412 | feat(validator): B86-1 — remove ModuleTruth completely |
| #413 | refactor(validator): B86-2 — classification clarity |
| #414 | refactor(cli): B86-3 — CLI/JSON alignment |
| #415 | feat(ci): B86-4 — CI contract consolidation |
| #416 | docs: B86-5 — contract rules freeze |

---

## [1.85.1] - 2026-04-15

**GeoIP database path fix.**

### Fixed

- **GeoIP database path mismatch**: Validator checked
  `/var/cache/nftban/geoban/dbip-country-lite.mmdb` but the canonical
  path is `/var/lib/nftban/geoip/dbip-country-lite.mmdb`. Caused
  `VAL-GEOBAN-001` on all hosts even though the DB existed, the timer
  was active, and GEOBAN_ENABLED=true. Geoban now correctly reports
  `"loaded"` across all hosts and distros.

### PRs

| PR | Title |
|---|---|
| #410 | fix(validator): correct GeoIP database path — /var/lib not /var/cache |

---

## [1.85.0] - 2026-04-15

**Module completeness & integration safety.**

Makes it impossible to add a module partially — completeness is now enforced
by CI, not assumed by convention.

### Added

- **Module classification system**: every config-present module classified as
  CORE / ADVISORY / MONITORING / EXTERNAL. No unclassified modules allowed.
  Botscan classified as BotGuard sub-function (L7 batch). Tunnel = ADVISORY,
  RBL = MONITORING, Suricata = EXTERNAL (deferred).
- **CI gate G8-1**: Module completeness — every CORE module must have
  evaluator + ModuleHealthMap field + JSON field. Blocking.
- **CI gate G8-2**: Module classification — every config directory must be
  classified. No untracked modules. Blocking.
- **CI gate G8-3**: IPv6 parity — detects IPv4-only evaluator checks.
  Tests for DDoS, Portscan, BotGuard asymmetry. Blocking.
- **CI gate G8-4**: Cross-surface smoke — compares validator JSON module
  list with health JSON module list. Wired into ci-architecture.yml.
- **TestPortscanEnabledMissing**: structural missing degraded scenario.

### Changed

- **Blacklist evaluator**: now counts both IPv4 and IPv6 manual elements
  and counters (GAP-185-9). Previously IPv4-only.
- **ModuleHealthMap**: confirmed as single canonical module inventory.

### Deprecated

- **ModuleTruth** (`ModuleStatus` type + `deriveModuleTruth()`): marked
  deprecated. Removal planned for v1.86. Not used in status derivation.
  Still emitted for legacy compatibility in text-mode validator output.

### Not included

- Suricata validator integration (EXTERNAL, deferred to v1.87+)
- New module registry (completeness enforced via cross-check of existing
  authorities, not a new subsystem)
- ModuleTruth removal (v1.86)

### PRs

| PR | Title |
|---|---|
| #407 | feat(validator): M85-1/2/3 — module classification + IPv6 parity + completeness gates |
| #408 | feat(ci): G8-4 smoke test + CI wiring + per-module coverage |

---

## [1.84.0] - 2026-04-15

**Unified truth architecture — Go validator is sole authority.**

First release where all user-facing truth paths resolve through a single
authority (Go validator), shell-era validation is fully retired, and
system invariants are enforced in CI.

### Added

- **Bounded journal evidence reader** (A1-1): safe, bounded journal
  queries for daemon-dependent modules. 2s timeout, 15m window, 200
  line cap, newest-first, pattern matching in Go.
- **BotGuard runtime evidence** (A1-2): journal check for module
  registration (`module_start: botguard`, `[botguard] loaded`).
  Emits `VAL-BOTGUARD-001` (info) when no recent evidence found.
- **LoginMon source-binding evidence** (A1-3): journal check for
  module registration AND source binding (`resolved_by=`). Both must
  be present (AND semantics). Emits `VAL-LOGINMON-001` (info).
- **CI gate G1-1**: Banned phrase test now blocking — prevents
  vocabulary regression permanently.
- **CI gate G2-1**: Truth consistency test — verifies validator status
  matches health status (INV-CONS-001).
- **CI gate G2-3**: Schema version guard — Go source schema must match
  CLI expected schema on every PR.
- **CI gate G7-3**: Exit code consistency — verifies 0=PROTECTED/IDLE,
  1=DEGRADED, 2=DOWN contract.

### Changed

- **Shell authority retired** (M84-2): `_nftban_protection_state_legacy()`
  deleted. Missing Go validator binary now means DOWN (no fallback).
  `NFTBAN_FORCE_LEGACY_STATE` override removed.
- **`nftban firewall validate`**: now Go-only. Shell `validate_structure`
  removed from authority path. Single structural truth source.
- **Post-update validation** (V6): uses Go validator. Structural
  degradation blocks update; non-structural degradation warns only.
- **Health anchor integrity**: uses Go validator findings instead of
  shell invariant checker with 19 INV-* checks.
- **README**: complete rewrite with truth hierarchy, evidence model,
  validator scope, core invariants.

### Removed

- `nftban_invariant_validator.sh` (607 lines) — shell invariant
  validator with 19 INV-S/INV-O/INV-F checks. All covered by Go.
- `_nftban_protection_state_legacy()` (97 lines) — shell fallback.
- `NFTBAN_FORCE_LEGACY_STATE` environment override.
- Banned terms: "HEALTHY", "healthy", "Healthy" from all user-visible
  CLI output. "OK=healthy" → "OK=protected" in watchdog legend.
- Stale "legacy fallback" comments across 4 files.
- "[LEGACY]" tag → "[COMPAT]" in template warning.

### Performance

| Metric | Before | After |
|---|---|---|
| Shell truth-derivation paths | 6 call sites | **0** |
| Shell invariant validator lines | 607 | **0** |
| Legacy fallback paths | 4 | **0** |

### PRs

| PR | Title |
|---|---|
| #399 | docs: rewrite README — truth model, evidence model, validator scope |
| #400 | feat(validator): add bounded journal evidence reader (A1-1) |
| #401 | feat(validator): BotGuard + LoginMon journal evidence (A1-2/A1-3) |
| #402 | fix(validator): LoginMon AND semantics + comment drift |
| #403 | feat(cli): shell authority retirement — Go validator sole truth path (M84-2) |
| #404 | refactor(cli): M84-3 presentation cleanup — vocabulary alignment |
| #405 | feat(ci): M84-4 contract freeze — 4 CI gates for system invariants |

---

## [1.83.1] - 2026-04-15

**Validator evidence fidelity hotfix.**

Go validator only. No CLI contract, schema, or architecture changes.

### Fixed

- **GAP-BL1** (HIGH): Manual blacklist effective state now derived from
  `input_blacklist_manual_drop` kernel counter. ENFORCING when elements > 0
  AND drops > 0. Previously always PRIMED regardless of enforcement activity.
- **GAP-D1**: DDoS structural evaluation now checks IPv6 chains when `ip6
  nftban` table exists. All 4 DDoS chains must be present in both families.
- **GAP-P1**: Portscan structural evaluation now checks IPv6 chain when
  `ip6 nftban` table exists.
- **GAP-BL3**: GeoIP database freshness check. Files older than 45 days
  report `"stale"` with finding instead of `"loaded"`.
- **GAP-BL5**: Feed data freshness check. No recent data files (> 7 days)
  reports `"stale"` instead of `"loaded"`.

### Not included (v1.84)

- GAP-B4/L2: BotGuard/LoginMon journal runtime checks (requires new exec
  pattern)
- Legacy fallback removal
- CI gates

### PRs

| PR | Title |
|---|---|
| #397 | fix(validator): close 5 module contract gaps (GAP-BL1/D1/P1/BL3/BL5) |

---

## [1.83.0] - 2026-04-14

**Truth authority consolidation and operator-path performance.**

v1.83 enforces the Go validator as the sole truth authority for protection
state. The shell CLI layer no longer independently derives health, module
state, or config-kernel consistency. All primary operator commands now
consume validator JSON instead of recomputing facts from config files and
kernel queries.

### Added

- **VAL-TIMER-001 / VAL-TIMER-002**: Timer liveness check in Go validator.
  Zero active `nftban-*` timers → DEGRADED. Query failure → warn (not
  DEGRADED). Eliminates shell `D-NOTIMERS` override.
- **`nftban health diagnostics`** subcommand: legacy shell environment
  checks (51 checks) moved under explicit diagnostics path.
- **Schema version guard**: CLI warns when validator binary schema version
  doesn't match expected `1.83.0`. Prevents silent breakage after partial
  upgrades.
- **Legacy fallback warning**: stderr WARNING when Go validator binary is
  missing. Deprecated path, scheduled for removal in v1.84.
- **Systemctl batch prefetch**: single `systemctl is-active` call for all
  known units at status startup. Results cached in associative array.

### Changed

- **`nftban health` default** is now Go validator truth (four-axis table).
  Was: 51-check shell scan (5.4s, 1500 subprocesses).
  Now: Go validator read (0.2s, single binary call).
- **`nftban health --json`** now outputs Go validator frozen schema JSON
  (schema 1.83.0). Legacy shell diagnostics JSON via `nftban health
  diagnostics --json`.
- **Shell truth override removed**: `_nftban_protection_state_validator()`
  no longer re-checks daemon/timer state after validator says "protected".
  Validator findings (VAL-SERVICE-001, VAL-TIMER-001) control DEGRADED
  through the normal path.
- **Module display sections** (DDoS, Portscan) in `nftban status` now
  read `.modules.*.config` and `.modules.*.structural` from cached
  validator JSON instead of sourcing config files and running `nft list`.
- **Config divergence** detection reads VAL-CONS-001 findings from
  validator instead of independently parsing config and querying kernel.
- **JSON schema version** bumped to `1.83.0` (`service_state.timer_count`
  field added).

### Fixed

- **Argument leak** (F1-F3): `--json` flag no longer leaks to downstream
  functions in health and login dispatchers. `nftban health --auto-heal
  --json` no longer errors.
- **Portscan aggregate timeout** (PR #387): `tail -10000` cap on
  `journalctl` query in `nftban_portscan_aggregate()`. Prevents
  maintenance timeout on high-volume hosts (1.4M+ journal entries).

### Removed

- `nftban_health_cmd_report()` — orphaned since v1.39.0 (DEAD-1).
- Duplicate `nftband` entry and 5 unused conflict units from systemctl
  prefetch array (DEAD-4).
- Shell config-file parsing and `nft list chain` calls in DDoS/Portscan
  status display sections (DUP-2/DUP-3).
- 71 lines of authority-violating shell logic.

### Performance

| Command | v1.82 | v1.83 | Change |
|---|---|---|---|
| `nftban health` | 5.4s | 0.2s | 27x faster |
| `nftban status` | 3.6s | 0.8s | 4.5x faster |
| Subprocesses (status) | 367 | ~160 | 56% fewer |
| systemctl calls (status) | 88 | ~25 | 72% fewer |

### PRs

| PR | Title |
|---|---|
| #387 | fix(portscan): cap aggregate journal query to prevent maintenance timeout |
| #388 | feat(validator): add timer liveness check VAL-TIMER-001 |
| #389 | fix(status): remove shell truth override — validator is sole authority |
| #390 | feat(health): split into truth vs diagnostics |
| #391 | feat(cli): legacy fallback warning + schema version guard |
| #392 | fix(cli): close argument leak in health and login dispatchers (F1-F3) |
| #393 | perf(status): cache validator JSON — eliminate redundant binary calls |
| #394 | perf(status): batch systemctl queries — 1 call replaces ~35 |
| #395 | refactor(cli): Day 4+5 cleanup — validator authority + dead code |

---

## [1.82.0] - 2026-04-14

**Truth-path consolidation, evidence fidelity, and operator health surface.**

### Added

- **`nftban health truth`** subcommand: four-axis health table backed by
  Go validator's frozen schema. Text + JSON modes. CLI is presentation only.
- **Consistency axis** real implementation: config vs kernel cross-source
  verification. Emits `VAL-CONS-001` when enabled module has missing kernel
  objects. Respects Rule 8 (disabled + present = valid residual).
- **Per-set element queries** (CF-4): `countSetElements()` now runs real
  `nft -j list set` queries. Unlocks BotGuard ENFORCING/OBSERVING and
  blacklist PRIMED states with actual kernel evidence.
- **PKG-STATE-INCONSISTENT** auto-recovery in update manager + autoheal.
  DEB install failures auto-repair via dpkg configure + dependency fix.

### Fixed

- **nftban_validator.sh deleted** (structural cleanup). Functions relocated
  to `nftban_ip_and_stats.sh`. Go `ValidatorScript()` removed. `load_spec`
  and `get_live_ruleset` deleted (0 callers).
- **Portscan aggregation performance**: `tail -5000` caps input before grep.
  High-volume hosts (396K+ lines) now complete in ~14s instead of timeout.
- **CLI vocabulary enforcement**: "OK" → "PROTECTED" in 18 health/posture
  sites. DNS status uses "AVAILABLE" (non-health context). Posture source
  aligned with consumer. Banned phrase count: 24 → 6 (all false positives).
- **`.state` → `.status`** key rename in `nftban status --json`. Both keys
  emitted during transition. Old key removed in v1.83.

### Known limitations

- Set-element counting adds ~6 nft exec calls per validation cycle
- LoginMon effective evidence still journal-deferred
- Portscan effective evidence still structural-only/idle
- Consistency axis checks config↔kernel only (not cache/CLI yet)

### PRs

| PR | Title |
|---|---|
| #384 | PKG-STATE-INCONSISTENT auto-recovery |
| #385 | v1.82 steps 1-6 (structural + CF-4 + consistency + health + portscan perf + CLI) |

---

## [1.81.1] - 2026-04-14

**Hotfix.** Fixes two bugs in portscan classic that crash the maintenance
timer every 6 minutes on any host with portscan enabled.

### Fixed

- **SIGPIPE (exit 141):** `tail -1000` in pipeline under `set -o pipefail`
  in `nftban_portscan_classic_process_logs()`. When the while-read loop
  closes, tail gets SIGPIPE. Fix: `{ tail -1000 || true; }` on both
  journalctl and file-grep paths.
- **Unbound variable:** 5 tracking arrays (`_PORTSCAN_CLASSIC_IP_PORTS` etc.)
  declared with `declare -gA` but not initialized with `=()`. Under
  `set -u`, `${#array[@]}` on a declared-but-unassigned array is fatal.
  Fix: initialize all arrays at declaration.

### Impact

Without this fix, maintenance (SSH protection, whitelist sync, auto-heal)
stops running on any host with portscan enabled. Both bugs are pre-existing
— became visible after portscan classic detection was fixed in v1.81.0.

### Verification

Verified on monitor + lab2 + lab4. Maintenance completes step 7 (portscan
stealth aggregation) without crash.

### Refs

- PR #382

---

## [1.81.0] - 2026-04-14

**Metrics alignment and health semantics implementation.** Module-aware
health output with frozen JSON schema, vocabulary-aligned states, and
CLI/JSON truth discipline. Portscan classic detection bug fixed and
verified live.

### Added

- **M81-4** Per-module health evaluation in Go validator. Each module
  evaluated on 4 axes: config, structural, runtime, effective. Truth
  tables from `HEALTH_METRIC_DERIVATION_v1.81.md` implemented in code.
  Modules: BotGuard, DDoS, Portscan, LoginMon, Blacklist (unified:
  manual + feeds + geoban). (PR #381)
- **M81-6** Frozen JSON schema via mapper layer. `MapToHealthOutput()`
  is the single projection point — internal state never serialized
  directly. Schema version `1.81.0`. No nulls. Vocabulary-approved
  values only. (PR #381)
- DDoS effective axis reads real kernel named counters (`input_ct_ssh_drop`,
  `input_ct_http_drop`, `input_ct_mail_drop`, `input_syn_rate_exceeded`,
  `input_syn_prefix_drop`). Any > 0 = ENFORCING. (PR #381)
- `StatusIdle` enum: overall status distinguishes PROTECTED (at least one
  module active) from IDLE (all modules valid but no enforcement). Both
  exit 0. (PR #381)
- BotGuard dual-family structural evaluation per Rule 9 (per-family
  aggregation). IPv6 checked only if ip6 nftban table exists. (PR #381)
- Consistency block stub in JSON output (`kernel_vs_validator: "ok"`).
  Full consistency checking is v1.82 scope. (PR #381)
- `VAL-GEOBAN-001` finding emitted when geoip database missing/empty
  and geoban is enabled. (PR #381)
- `test_banned_phrases.sh`: M81-5 regression scanner detecting 7 banned
  phrase patterns across CLI files. Informational for v1.81. (PR #381)

### Fixed

- **Portscan classic log-path collision** (CRITICAL). `PORTSCAN_CLASSIC_LOG_FILE`
  was defined twice in `classic.conf` — line 32 (kernel input source) and
  line 172 (module output log). The detector was grepping its own output
  log and finding nothing. Renamed output variable to
  `PORTSCAN_CLASSIC_MODULE_LOG`. Detection now verified live: lab2=160/4,
  lab4=349/6, monitor=59/1 IPs tracked/blocked. Both background timer and
  manual `nftban portscan check` fixed. (PR #377)
- **CF-1** `service_state.nftband` now emits uppercase (`RUNNING`|`STOPPED`|
  `ERROR`) matching JSON schema spec. Module runtime fields remain
  lowercase. (PR #381)
- **CF-2** Geoban DB missing emits `"stale"` (in allowed enum) instead of
  `"degraded"` (not in enum). Emits `VAL-GEOBAN-001` finding. (PR #381)
- **M81-5** CLI banned phrases: `"healthy"` replaced with `"protected"` in
  health word mappings. `"threats_blocked_24h"` renamed to
  `"enforcement_events_24h"` in status JSON. (PR #381)

### Changed

- `ToJSON()` now uses `MapToHealthOutput()` (frozen schema). Legacy
  consumers use `ToJSONLegacy()` for backward compat. (PR #381)
- `ExitCode()` returns 0 for both PROTECTED and IDLE. (PR #381)

### Schema

```json
{
  "schema_version": "1.81.0",
  "status": "protected|idle|degraded|down",
  "service_state": { "nftband": "RUNNING|STOPPED|ERROR" },
  "modules": {
    "botguard":  { "config", "structural", "runtime", "effective" },
    "ddos":      { "config", "structural", "effective" },
    "portscan":  { "config", "structural", "effective" },
    "loginmon":  { "config", "structural", "runtime", "effective" },
    "blacklist": { "manual", "feeds", "geoban" }
  },
  "consistency": { "kernel_vs_validator": "ok|mismatch" },
  "findings": [...],
  "chain_counts": {...},
  "summary": {...}
}
```

### Specs produced (M81-1 through M81-8)

| Spec | Document |
|---|---|
| M81-1 Vocabulary | `NFTBAN_VOCABULARY_REFERENCE_v1.81.md` (v1.1) |
| M81-2 Counter inventory | `METRICS_CATALOG_v1.81.md` |
| M81-3 Module contracts | 5 module evidence contracts |
| M81-4 Health derivation | `HEALTH_METRIC_DERIVATION_v1.81.md` |
| M81-5 CLI output | `CLI_OUTPUT_SPEC_v1.81.md` |
| M81-6 JSON schema | `JSON_SCHEMA_SPEC_v1.81.md` |
| M81-7 Shadowing detection | `SHADOWING_DETECTION_SPEC_v1.81.md` |
| M81-8 Glossary | `METRICS_GLOSSARY_AND_TROUBLESHOOTING_v1.81.md` |

### Known limitations

- **Set-element counting not implemented.** `countSetElements()` returns 0.
  BotGuard ENFORCING/OBSERVING and blacklist PRIMED states are unreachable
  from the validator. Fix target: v1.82 per-set queries.
- **Portscan effective evidence is structural-only/idle.** No dedicated
  kernel counter. Real enforcement evidence requires kernel log parsing.
- **LoginMon effective evidence not yet integrated.** Journal query outside
  validator's point-in-time snapshot model. Reports idle by default.
- **Consistency axis is a stub** (`"ok"` always). Full cross-source
  checking is v1.82 scope.
- **Legacy shell CLI contains 24 banned-phrase instances** in health
  subsystem files. Full CLI vocabulary enforcement is v1.82 scope.

### PRs

| PR | Title |
|---|---|
| #377 | Portscan classic log-path collision fix |
| #381 | M81-4/5/6 health derivation + JSON schema + CLI cleanup + CF fixes |

---

## [1.80.1] - 2026-04-13

**Hotfix.** Fixes validator semantic issue from v1.80.0: module-scoped helper
chains were treated as universally required for base PROTECTED. Disabled
modules (BotGuard, Portscan, DDoS) caused false DEGRADED on hosts where
those modules are intentionally off.

### Fixed

- Helper chains split into `GeneratedRequiredHelperChains` (empty) and
  `GeneratedAllHelperChains` (6 module-scoped). No helper chain is
  base-required for PROTECTED.
- B80-3 empty-chain detection preserved: scans known helpers that EXIST in
  kernel. Missing = module disabled (neutral). Existing with 0 rules =
  broken module (DEGRADED).

### Semantic contract

- `base PROTECTED = tables + base chains + required sets + anchors + runtime`
- `missing helper chain = module disabled (neutral)`
- `existing empty helper chain = broken module (DEGRADED)`

### Refs

- PR #375

---

## [1.80.0] - 2026-04-13

**Structural truth-surface hardening.** Protection state now fails correctly
for broken kernel structure, empty required chains, dead required runtime,
schema drift, and duplicate schema authority. v1.80.0 does not change the
effective detection/scoring model; effectiveness tuning remains future work.

### Added

- **B80-1** Single validator authority: `validate_structure()` in the shell
  validator is now a thin shim over the Go `nftban-validate` binary. No
  independent shell validation logic remains. Fail-closed with exit code 2
  if the Go binary is missing. jq-missing fallback for broken environments.
  (PR #369)
- **B80-3** Empty-chain detection (`VAL-CHAIN-004`): a helper chain that
  exists but has zero rules is a no-op jump target. The validator now
  reports DEGRADED for this condition, not PROTECTED. (PR #371)
- **B80-4** Service-state truth (`VAL-SERVICE-001`): the validator checks
  whether `nftband` is running via `systemctl is-active`. Three-state
  model: RUNNING / STOPPED / ERROR. Dead daemon with correct kernel
  structure now reports DEGRADED, not PROTECTED. Transition states
  (activating, deactivating, reloading) correctly map to STOPPED. (PR #372)
- **B80-5** Schema codegen: `scripts/generate-go-schema.sh` reads the
  canonical shell schema (`cli/lib/nftban/lib/nft_schema.sh`) and generates
  `internal/validator/schema_generated.go` with sorted, deterministic Go
  slices for base chains, helper chains (6 total: 3 shell-declared +
  3 DDoS fragment sub-chains), required sets, and all known sets. (PR #372)
- **B80-8** CI drift gate: the Go Build & Test workflow re-runs the schema
  generator and fails if the committed `schema_generated.go` differs from
  the canonical shell source. Schema drift is now unmergeable. (PR #373)
- **INV-CONS-001** smoke assertion in `smoke_test.sh`: compares
  `nftban status --json` state against `nftban-validate --json` status.
  Divergence is a CI failure. (PR #369, fixed in PR #370)
- **BotGuard rebuild gating fix** (`BOTGUARD-REBUILD-UX`): three
  module-restore sites in `cmd_firewall.sh` read the wrong config key
  `BOTGUARD_ENABLED` instead of the canonical `HTTP_BOTGUARD_ENABLED`.
  Centralised into `_firewall_botguard_is_enabled` helper. (PR #368)

### Changed

- **B80-6** Validator structural lists (`RequiredBaseChains`,
  `RequiredHelperChains`, `RequiredSetsIPv4`, `RequiredSetsIPv6`) are now
  aliases to the generated schema vars. No parallel hardcoded string lists
  remain in `types.go`. Anchors stay manually maintained (strict order
  requirement, validator-only concept). (PR #372)
- **B80-7** Watchdog `schema_validator.go` now imports
  `internal/validator.Generated*` for all set and chain expectations.
  No independent schema authority remains in the watchdog. (PR #373)

### Closed

- **B80-2** was already satisfied: `cmd_status.sh` already used the Go
  validator binary exclusively at line 131.
- **BUG-6** (srv1 NAT/proxy source attribution): CLOSED NOT-A-BUG.
  Dovecot replay confirms `rip=` exposes real attacker IPs correctly.
  `lip=10.1.0.5` is the local listener address, not a source-collapsing
  proxy. Scoring effectiveness (34 failures / 0 bans from one IP) is
  BUG-1 scope (Effective-axis), not BUG-6.

### Not changed

- No parser code changes
- No scoring logic changes
- No pipeline code changes
- No detection-model changes
- No BotGuard architecture changes
- No DDoS changes
- Anchor ordering stays manually maintained in `types.go`

### Truth guarantee (v1.80.0)

| Condition | Result |
|---|---|
| Kernel broken | not PROTECTED |
| Required chain empty | not PROTECTED (VAL-CHAIN-004) |
| Required runtime dead | not PROTECTED (VAL-SERVICE-001) |
| Schema drift | CI blocks merge |
| Validator authority | Go only (shell = shim) |
| Watchdog authority | unified (imports Generated*) |

### PRs (in merge order)

| PR | Title |
|---|---|
| #368 | BotGuard rebuild gating fix |
| #369 | B80-1 validator shim |
| #370 | INV-CONS-001 smoke fix |
| #371 | B80-3 empty-chain detection |
| #372 | B80-4/5/6 service-state + schema codegen + wiring |
| #373 | B80-7/8 watchdog unification + CI drift gate |

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
