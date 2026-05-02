# MIGRATION_COVERAGE.md — Shell → Go migration coverage

**Status:** H3.1 deliverable for v1.100.4 — doc-only.
**Authority:** OPERATOR DECISION 2026-05-02.
**Branch HEAD reference:** `6455232f` (PR #541, MERGEABLE).
**Hard constraints:** doc-only; no code changes; no shell deletion; no panel adapter / restore / H4 changes; no lifecycle replay; no v1.100.4 tag.

---

## §1. Executive decision

The v1.100.x release stream introduced a Go-owned install-time `panelfw` framework for **install-time panel survival validation** (Detect / RequiredPorts / ValidateReachability). It does **NOT** replace the operator-facing panel CLI. Both surfaces continue to coexist for v1.100.4 and the foreseeable v1.100.x stream.

This document is the single source of truth for which surfaces are Go-owned, which remain shell-owned, and which are bridges. CI gate H3.2 enforces it. Shell-delete guard H3.3 prevents premature deletion.

---

## §2. Scope and non-scope

### In scope (this document)

- Inventory of shell-owned vs Go-owned surfaces
- Authoritative classification of each surface's migration status
- Release-impact tagging per surface for v1.100.4
- Guard requirements feeding H3.2 (CI) and H3.3 (shell-delete guard)

### Explicitly out of scope (do NOT extend this document)

- Code changes to shell or Go (H3.1 is doc-only)
- Shell deletion (covered by H3.3 guard, NOT executed in this lane)
- Panel adapter behavior changes (panelfw lane closed at PR26.7.1 + PR26.8 + PR26.6.1)
- Restore lane changes (separate lane, PR-24 + PR26 evidence; out of H3.x)
- Schema / metrics changes (H4 — HELD pending operator briefing)
- Lifecycle install/uninstall/reinstall changes (CLOSED 2026-05-02 — see `project_v1_100_4_lifecycle_lane_closed.md`)
- Source-build oldest-glibc behavior (CLOSED 2026-05-02)
- Shell-side runtime residue cleanup (UPSTREAM-UNINSTALL-SHELL-RESIDUE-002 — v1.101 follow-up)
- Source-install update stale payload (UPSTREAM-UPDATE-STALE-PAYLOAD-001 — v1.101 follow-up)

---

## §3. Authoritative wording (binding for docs / release notes / changelog)

> **Install-time panel survival validation migrated to Go for DirectAdmin, Plesk, and cPanel. Operator-facing panel CLI remains shell-owned until a future explicit migration/decommission lane.**

This wording must appear verbatim in:
- v1.100.4 release notes / CHANGELOG.md
- STATUS.md panel section
- Any wiki page describing panel adapter behavior
- Any post-merge announcement / docs PR for v1.100.4

What this wording does NOT say:
- ❌ "panel shell logic migrated to Go" — false; only install-time validation migrated
- ❌ "panel shell decommissioned" — false; it remains operator-facing
- ❌ "panelfw replaces shell panel module" — false; they coexist

What this wording DOES say:
- ✅ Install-time `Detect` / `RequiredPorts` / `ValidateReachability` for the 3 named adapters is Go-owned
- ✅ Operator-facing panel CLI (`nftban panel ...` shell-side commands) remains shell-owned
- ✅ Migration of the operator-facing surface is a future explicit lane (NOT in v1.100.4)

---

## §4. Migration coverage matrix

| # | Surface / command / file family | Current owner | Migration status | Release impact | Evidence source | Guard needed |
|---|---|---|---|---|---|---|
| 1 | Install-time panel survival: Detect (DA / Plesk / cPanel) | **Go** | migrated (PR26.3 / PR26.7 / PR26.8) | v1.100.4 non-blocker (CLOSED) | `internal/installer/panelfw/adapters/{directadmin,plesk,cpanel}/` | H3.2: prevent regression to shell-side detect |
| 2 | Install-time panel survival: RequiredPorts (DA / Plesk / cPanel) | **Go** | migrated (PR26.4 / PR26.7 / PR26.8) | v1.100.4 non-blocker (CLOSED) | `internal/installer/panelfw/adapters/*/` + `etc/nftban/conf.d/panels/*/main.conf` | H3.2: enforce conf.d-as-source-of-truth |
| 3 | Install-time panel survival: ValidateReachability (DA / Plesk / cPanel) | **Go** | migrated (PR26.4 / PR26.7 / PR26.8) | v1.100.4 non-blocker (CLOSED) | `internal/installer/panelfw/adapters/*/` (port any-of lists) | H3.2: prevent unbounded port-list growth |
| 4 | Install-time panel survival: CyberPanel / CWP / InterWorx / Vesta / generic | **conf.d only** (no Go adapter yet) | pending — evidence-gated | v1.100.4 non-blocker (deferred to v1.101+) | `etc/nftban/conf.d/panels/{cyberpanel,cwp,interworx,vesta,generic}/main.conf` | none in H3.2 |
| 5 | DirectAdmin runtime watchdog coherence (services.status flip) | **Go** | migrated (PR26.6.1) | v1.100.4 non-blocker (CLOSED) | `internal/installer/panelfw/adapters/directadmin/` | H3.2: prevent regression |
| 6 | nft table classifier (NFTBAN_OWNED / EXTERNAL_AUTHORITY_GHOST / KERNEL_DEFAULT / OPERATOR_SAFETY) | **Go + shared shell lib** | mixed (PR26.6) | v1.100.4 non-blocker (CLOSED) | `cli/lib/nftban/lib/nftban_table_classify.sh` + Go callers | H3.2: shell lib must remain in sync with Go classifier |
| 7 | Source-install payload staging (binaries / shell / configs / panels / systemd / polkit / logrotate / docs) | **Go** | migrated (PR26.5) | v1.100.4 non-blocker (CLOSED) | `internal/installer/payload/payload.go` `buildEntries()` + `Destinations()` | H3.2: payload destinations registry must be sole source for install AND uninstall |
| 8 | Uninstall artifact removal (PR-25-equivalent) | **Go** | migrated (PR #541, this release) | v1.100.4 non-blocker (CLOSED) | `internal/installer/uninstall/artifacts.go` | H3.2: G3-UN-NO-MUTATION whitelist locked |
| 9 | Authority release / safe-switch / emergency SSH | **Go** | migrated (PR-23, pre-v1.100.4) | v1.100.4 non-blocker (CLOSED) | `internal/installer/uninstall/apply.go` + `internal/installer/switchop/` | H3.2: G3-UN-SHIM-LOCK + G3-EXEC-TRACE remain green |
| 10 | Restore-prior-authority (CSF / external firewall) | **Go** | migrated (PR-24 + PR26 series) | v1.100.4 non-blocker (CLOSED) | `internal/installer/restore/` + `cmd/nftban-installer/restore_*.go` | H3.2: NOT in this lane (separate restore-canon gate exists) |
| 11 | Detect / preflight (DistroInfo / SSH port / kernel modules) | **Go** | migrated | v1.100.4 non-blocker (CLOSED) | `internal/installer/detect/` | H3.2: existing detect-canon gate already covers |
| 12 | nftban-installer state file lifecycle | **Go** | migrated | v1.100.4 non-blocker (CLOSED) | `internal/installer/state/` | none new |
| 13 | Operator-facing `nftban ban` / `unban` / `whitelist` / `blacklist` | **shell** | **intentionally shell-owned** | v1.100.4 non-blocker | `cli/lib/nftban/cli/cmd_ban.sh`, `cmd_unban.sh`, `cmd_whitelist.sh`, `cmd_blacklist.sh` | H3.3: shell-delete guard MUST refuse deletion |
| 14 | Operator-facing `nftban status` / `health` / `feeds` / `stats` | **shell** | **intentionally shell-owned** | v1.100.4 non-blocker | `cli/lib/nftban/cli/cmd_{status,health*,feeds,stats}.sh` | H3.3: shell-delete guard MUST refuse deletion |
| 15 | Operator-facing `nftban panel` (enable / disable / status / report / repair / test) | **shell** | **intentionally shell-owned** | v1.100.4 non-blocker | `cli/lib/nftban/cli/cmd_panel.sh` (+ `cmd_report.sh`, `cmd_status.sh`, `cmd_test.sh`) | H3.3: shell-delete guard MUST refuse deletion |
| 16 | Operator-facing Cloudflare integration | **shell** | intentionally shell-owned | v1.100.4 non-blocker (panel-only feature) | `cli/lib/nftban/cli/cmd_cloudflare.sh` (if present) | H3.3: shell-delete guard MUST refuse deletion |
| 17 | Operator-facing cPHulk integration | **shell** | intentionally shell-owned | v1.100.4 non-blocker | shell module under cPanel-specific paths | H3.3: shell-delete guard MUST refuse deletion |
| 18 | Operator-facing `nftban ddos` / `botguard` / `suricata` / `botscan` | **shell** | intentionally shell-owned | v1.100.4 non-blocker | `cli/lib/nftban/cli/cmd_{ddos,botguard,suricata,botscan}.sh` | H3.3: shell-delete guard MUST refuse deletion |
| 19 | Operator-facing `nftban login` (loginmon CLI) | **shell** with Go daemon backing | mixed (Go daemon owns runtime, shell owns CLI) | v1.100.4 non-blocker | `cli/lib/nftban/cli/cmd_login.sh` + `internal/loginmon/` Go daemon | H3.2: shell CLI must call into Go daemon, NOT reimplement |
| 20 | Login-monitor runtime | **Go** | migrated (v1.80 series) | v1.100.4 non-blocker | `internal/loginmon/` | none new |
| 21 | Firewall rebuild (validate-then-flush-load) | **shell + Go validator** | mixed (shell driver, Go validator authority) | v1.100.4 non-blocker | `cli/lib/nftban/cli/cmd_firewall.sh` + `cmd/nftban-validate/` | H3.2: validator authority pinned (per v1.83) |
| 22 | Health model (5-state) | **Go validator + shell exposure** | mixed | v1.100.4 non-blocker | `cmd/nftban-validate/` + `cli/lib/nftban/cli/cmd_health*.sh` | none new |
| 23 | Metrics + sampler | **Go + shell** (legacy) | mixed (deprecated sampler still exists) | v1.100.4 non-blocker (H4 HELD) | `internal/metrics/` + legacy `cli/lib/nftban/exporters/` | H4 lane will resolve |
| 24 | nftban-ui / nftban-ui-auth | **deprecated** (PR26.5 removed staging; binary not built) | deprecated | v1.100.4 non-blocker (already removed) | NOT in payload.Destinations | H3.3: shell-delete guard MUST refuse re-adding ui.service |
| 25 | nftban-suricata logrotate template | **Go staged** | migrated (PR26.5) | v1.100.4 non-blocker (CLOSED) | `payload.buildEntries` logrotate category | none new |
| 26 | bash completion + man page | **Go staged** | migrated | v1.100.4 non-blocker | `payload.buildEntries` docs category | none new |
| 27 | systemd units (nftban-*.service / .timer / .socket) | **Go staged + shell consumers** | mixed | v1.100.4 non-blocker | `install/systemd/*` staged via Go | H3.2: payload.Destinations is sole truth for unit set |
| 28 | Distro-aware path registry | **Go staged from etc/nftban/distros/*.conf** | mixed | v1.100.4 non-blocker | `etc/nftban/distros/*.conf` (data) + `internal/installer/detect/` (consumer) | none new |
| 29 | tmpfiles.d / runtime state dirs (rules.d/*.nft etc.) | **shell** (runtime-created) | intentionally shell-owned | v1.100.4 non-blocker; UPSTREAM-UNINSTALL-SHELL-RESIDUE-002 = v1.101 follow-up | shell daemon code | H3.3: shell-delete guard MUST refuse deletion |
| 30 | Update path / source-install update | **Go** | migrated (with known asymmetry) | v1.100.4 non-blocker; UPSTREAM-UPDATE-STALE-PAYLOAD-001 = v1.101 follow-up | `internal/installer/update/` | none new this release |

**Row totals:** 30 surfaces.
**Go-owned (migrated):** rows 1–12, 20, 25–28, 30 = 18 surfaces.
**Intentionally shell-owned:** rows 13–18, 29 = 7 surfaces.
**Mixed bridge:** rows 6, 19, 21, 22, 23, 28 = 6 surfaces (some overlap with Go).
**Deprecated / do-not-touch:** row 24 = 1 surface.
**Pending evidence-gated:** row 4 = 1 surface (v1.101+ panel adapters).

---

## §5. Go-owned install-time surfaces (CLOSED for v1.100.4)

Surfaces fully migrated to Go and verified by VANILLA_MATRIX Round 1 + PR-26 evidence:

- panelfw adapter contract (Detect / RequiredPorts / ValidateReachability) for DirectAdmin (PR26.3 + PR26.4), Plesk (PR26.7 + PR26.7.1), cPanel (PR26.8)
- DirectAdmin runtime watchdog coherence (PR26.6.1)
- 4-class nft table classifier (PR26.6)
- Source-install payload staging (PR26.5) — binaries, cli-bin, shell, data, configs, panels, templates, version, systemd, polkit, logrotate, docs
- Uninstall artifact removal (PR #541) — closes UPSTREAM-UNINSTALL-INCOMPLETE-001
- Authority release core (PR-23) + emergency SSH safety (PR23 step 1+11)
- Restore-prior-authority core + CSF restore + evidence record (PR-24, PR26.4-doc, PR26-code-A through code-E)
- Detect framework (DistroInfo / SSH port / kernel modules)
- nftban-installer state file lifecycle
- Login-monitor daemon (`internal/loginmon/`) — runtime owned by Go since v1.80

These surfaces have CI canonization gates: install-canon, restore-canon, runtime-truth, uninstall-canon, update-canon (all green on PR #541).

---

## §6. Shell-owned operator-facing surfaces (intentionally NOT migrated)

These surfaces are operator CLI / runtime ergonomics. They remain shell-owned for v1.100.4 and the foreseeable v1.100.x stream. **No deletion or migration is authorized in v1.100.4.** A future explicit decommission/migration lane would be required.

- `nftban ban` / `unban` / `whitelist` / `blacklist`
- `nftban status` / `health` / `feeds` / `stats`
- `nftban panel {enable,disable,status,report,repair,test}` and Cloudflare / cPHulk integrations
- `nftban ddos` / `botguard` / `suricata` / `botscan`
- `nftban login` CLI (delegates to Go daemon)
- `nftban firewall rebuild` (driver script; Go validator is authority)
- `nftban config doctor` / runtime diagnostic surfaces

Shell-side runtime artifacts created by these surfaces (e.g. `/etc/nftban/rules.d/*.nft`, `/var/lib/nftban/state/*`, recorder snapshots) are correctly classified as **out of `payload.StageAll` scope** by UPSTREAM_UNINSTALL_001_REPLAY_DIRECTIVE.md §3.3.

---

## §7. Mixed or bridge surfaces

These surfaces have BOTH Go and shell components by design. Each side has a defined role.

- **nft table classifier** — Go logic in PR26.6 + shared shell library `cli/lib/nftban/lib/nftban_table_classify.sh`. Shell consumers call the shared lib, Go consumers call native code. Both must produce identical 4-class output.
- **Login-monitor** — Go daemon owns runtime; shell `cmd_login.sh` is the operator CLI front-end. Shell must NOT reimplement detection logic.
- **Firewall rebuild** — shell `cmd_firewall.sh` is the driver; `nftban-validate` (Go) is the authority. Shell must defer to validator's verdict.
- **Health model** — Go validator computes the 5-state health; shell `cmd_health*.sh` exposes it to operator.
- **Distro-aware path registry** — `etc/nftban/distros/*.conf` is data; consumers are Go (preferred) and shell (legacy).
- **Metrics + sampler** — Go-side metrics under `internal/metrics/`; legacy shell `exporters/` deprecated but retained until H4 resolves.

---

## §8. Deprecated / do-not-touch surfaces

- **`nftban-ui` / `nftban-ui-auth`** — deprecated since PR26.5 (no longer in `payload.Destinations`, binary not built). Shell-delete guard H3.3 must REFUSE re-adding `nftban-ui.service` to systemd payload destinations.

---

## §9. Guard requirements for H3.2 (CI migration-coverage gate)

H3.2 implements a CI gate that enforces this document's classifications structurally. Required checks:

1. **PANELFW-ADAPTER-COVERAGE** — every adapter in `internal/installer/panelfw/adapters/<name>/` must have a corresponding row in §4 with status=`migrated` AND a matching `etc/nftban/conf.d/panels/<name>/main.conf`. New adapters require a §4 row addition.
2. **PAYLOAD-DESTINATIONS-SOLE-TRUTH** — `payload.Destinations()` must be the ONLY source consulted by `internal/installer/uninstall/artifacts.go` for installer-owned paths (no parallel hardcoded list grown in artifacts.go beyond the bounded `uninstallOwnedRuntimePaths` enumerated in PR #541).
3. **NFTBAN-TABLE-CLASSIFIER-PARITY** — `cli/lib/nftban/lib/nftban_table_classify.sh` and the Go classifier in `internal/installer/uninstall/` must classify the same fixture set identically (table-driven test).
4. **G3-UN-NO-MUTATION whitelist locked** — only `apply.go` and `artifacts.go` excluded from the structural no-mutation grep; any new uninstall .go file added to the whitelist requires a documented entry in §4 + §5.
5. **G3-UN-SHIM-LOCK + G3-EXEC-TRACE** — existing PR-22/PR-23 gates must remain green (already in `.github/workflows/ci-uninstall-canonization.yml`).
6. **DEPRECATED-UI-UNIT-REFUSAL** — CI must FAIL if `nftban-ui.service` reappears in any payload-destination glob.
7. **PORT-LIST-BOUNDS** — panelfw adapters' `RequiredPorts()` and `ValidateReachability()` port lists must remain bounded (no unbounded growth via shell-side conf.d edits without an explicit adapter test update).
8. **VALIDATOR-AUTHORITY-PIN** — shell `cmd_firewall.sh` rebuild paths must defer to `nftban-validate` exit code (existing v1.83 invariant; H3.2 just locks it).

H3.2 is a separate PR. This document is the spec; H3.2 implements the CI workflow.

---

## §10. Shell-delete guard requirements for H3.3

H3.3 implements a CI gate that REFUSES deletion of any shell file in §6 (intentionally shell-owned) or §7 (mixed bridge surfaces) without an explicit migration-lane authorization marker.

Required checks:

1. **NO-DROP-OPERATOR-FACING-SHELL** — deletion of any file in `cli/lib/nftban/cli/cmd_{ban,unban,whitelist,blacklist,status,health*,feeds,stats,panel,report,test,ddos,botguard,suricata,botscan,login,firewall,config}.sh` MUST be refused unless the PR title contains `[MIGRATION-LANE-AUTHORIZED]` AND `MIGRATION_COVERAGE.md` has been updated to flip the row to `migrated` or `deprecated`.

2. **NO-DROP-SHARED-SHELL-LIBS** — deletion of `cli/lib/nftban/lib/nftban_table_classify.sh` (and other shared libs) MUST be refused unless §7 row is flipped.

3. **NO-DROP-RUNTIME-DIRS-CODE** — code that creates `/etc/nftban/rules.d/`, `/var/lib/nftban/state/`, `/var/lib/nftban/recorder/`, `/var/lib/nftban/backup/` is shell-runtime — H3.3 refuses deletion of those creator paths until UPSTREAM-UNINSTALL-SHELL-RESIDUE-002 lands.

4. **NO-DROP-DEPRECATED-MARKERS** — files marked deprecated in §8 may be deleted, but the deletion PR must include a `[DEPRECATED-REMOVAL]` marker AND keep the §8 entry as historical record (do not strip the row).

5. **REQUIRE-MIGRATION-COVERAGE-UPDATE** — any PR that touches shell files in `cli/lib/nftban/cli/` MUST also update `MIGRATION_COVERAGE.md` if the change crosses an ownership boundary (Go ↔ shell).

H3.3 is a separate PR. This document is the spec; H3.3 implements the CI workflow.

---

## §11. Release impact table

| Lane | v1.100.4 release impact |
|---|---|
| Go-owned install-time surfaces (§5) | **NON-BLOCKER** — all migrated and CI-canonized |
| Shell-owned operator-facing surfaces (§6) | **NON-BLOCKER** — intentionally shell-owned; no deletion authorized |
| Mixed bridge surfaces (§7) | **NON-BLOCKER** — both sides coexist by design |
| Deprecated nftban-ui (§8) | **NON-BLOCKER** — already removed from payload (PR26.5) |
| Pending evidence-gated panel adapters (row 4) | **NON-BLOCKER** — deferred to v1.101+ |
| H3.2 CI gate | follows H3.1; doc-only here |
| H3.3 shell-delete guard | follows H3.2; doc-only here |
| H4 (schema/metrics) | HELD — operator briefing pending |
| H5 (module isolation / config / logrotate / maintenance) | follows H3.x |
| **v1.100.4 final tag** | gated by H3.2 + H3.3 + H5 + H4 (briefing) + post-merge CIs green |

---

## §12. Follow-up lanes (NOT v1.100.4 blockers)

| Lane | Disposition | Tracker |
|---|---|---|
| UPSTREAM-UNINSTALL-SHELL-RESIDUE-002 | v1.101 / v1.100.5 follow-up — shell-side runtime cleanup symmetry | `RELEASE_CORRELATION_GAP_AUDIT_v1.100.4.md` §10.4 |
| UPSTREAM-UPDATE-STALE-PAYLOAD-001 | v1.101 follow-up — source-install update path-removal asymmetry | same doc |
| INSTALLER-PREFLIGHT-NFT-PRESENCE-001 | v1.101 follow-up — product preflight for `nft` binary | same doc |
| EL8 SELinux Enforcing verification | v1.101 (Tier-2 advisory) | same doc |
| Future panel adapter migrations (CyberPanel / CWP / InterWorx / Vesta) | v1.101+ evidence-gated | row 4 |
| Operator-facing panel CLI migration to Go | future explicit lane (NOT v1.100.x) | this doc §3 wording |
| H4 schema + metrics | post-briefing | task #77 |

---

## §13. H3.1 outcome

- **Path:** `/home/commonfolder/LLMAI4NFTBAN/V1.90_AUDIT_WIKI_CODE/MIGRATION_COVERAGE.md`
- **Section count:** 13 (this section + 12 above)
- **Migration-matrix row count:** 30
- **Discovered ambiguities requiring H3.2 / H3.3 attention:**
  - Row 19 (login CLI shell + Go daemon) — H3.2 must enforce shell-CLI-defers-to-Go-daemon pattern; not yet a structural CI check
  - Row 21 (firewall rebuild) — validator-authority-pin is documented (v1.83) but not yet a structural CI gate; H3.2 should add explicit grep
  - Row 23 (metrics + legacy sampler) — H4-shaped; deferred until H4 briefing
  - Row 6 (nft table classifier shared shell lib) — needs parity test in H3.2 to prevent shell-lib drift from Go classifier
  - Row 4 (CyberPanel / CWP / InterWorx / Vesta / generic) — has `etc/nftban/conf.d/panels/<name>/main.conf` but NO Go adapter; H3.2's `PANELFW-ADAPTER-COVERAGE` check must NOT flag this as a missing adapter (this row's status=`pending` is the authoritative state)

**H3.1 verdict: doc-only GO. Next: H3.2 CI migration-coverage gate.**

---

## §14. Cross-references

- Replay directive: `VANILLA_DISTRO_INSTALL_MATRIX/UPSTREAM_UNINSTALL_001_REPLAY_DIRECTIVE.md`
- Final dossier: `VANILLA_DISTRO_INSTALL_MATRIX/replay_logs/UPSTREAM-UNINSTALL-INCOMPLETE-001/AUDIT_DOSSIER_FINAL.md`
- Correlation audit: `VANILLA_DISTRO_INSTALL_MATRIX/RELEASE_CORRELATION_GAP_AUDIT_v1.100.4.md`
- Source-build directive: `VANILLA_DISTRO_INSTALL_MATRIX/SOURCE_BUILD_OLDEST_GLIBC_001.md`
- Lifecycle lane closure: `~/.claude/projects/-home-gituser-github-nftban/memory/project_v1_100_4_lifecycle_lane_closed.md`
- v1.100.4 release lane: `~/.claude/projects/-home-gituser-github-nftban/memory/project_v1_100_4_release_lane.md`
- Preflight known issues: `VANILLA_DISTRO_INSTALL_MATRIX/KNOWN_ISSUES_PREFLIGHT.md`
- Panel-shell-migration-coverage directive (the directive THIS doc fulfills): `~/.claude/projects/-home-gituser-github-nftban/memory/feedback_panel_shell_migration_coverage_directive.md`
