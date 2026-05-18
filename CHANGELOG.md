# NFTBan Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **History reset.** Pre-v1.79.2 releases are recorded as git tags and on
> the GitHub Releases page (`gh release list`). From v1.79.2 forward, every
> tagged release MUST have a CHANGELOG entry written before tagging.

---

## [v1.119.0] - 2026-05-18 — V119 dedicated narrow-feature: Manual CIDR DESIGN-FIX Option D

V119 dedicated narrow-feature release on top of v1.118.0, closing
`D-MANUAL-CIDR-LOAD-GAP` with **Cand 3 Manual CIDR DESIGN-FIX Option D**.
Mirrors the v1.113 LoginMon subnet aggregation single-feature precedent —
one design-locked Go + shell + test PR with fleet-validation gates
reserved post-publication.

**Schema 1.83.0 remains frozen.** No new metric names, no new metric
registrations, no Status JSON wire format additions, no allow-list
mutation. Per `V119_MANUAL_CIDR_SCHEMA_IMPACT_DECISION.md` verdict
`SCHEMA_STAYS_FROZEN` (5-row decision matrix Q1-Q5 verified). In-PR
regression test `TestSchemaVersionUnchangedByManualCIDRFix` enforces
`SchemaVersionCurrent == "1.83.0"`.

**Daemon binary NOT byte-identical to v1.118.0:** real Go change in
`internal/blacklist/loader.go` + `internal/whitelist/loader.go` (typed
`BlacklistEntry`/`WhitelistEntry{Value,IsCIDR}` structs + `LoadAll*Typed`
+ `IsIPIn*File` CIDR-containment helpers via `netip.Prefix.Contains`)
plus 4 callsite swaps from exact-key `map[ip]` lookups to the new
helpers. Closes D1 (loader IsCIDR drop) and the daemon-side whitelist
CIDR safety predicate.

### Added (typed CIDR-aware loader API)

- `internal/blacklist/loader.go` — new `BlacklistEntry{Value,IsCIDR}`
  struct, new `LoadAllBlacklistsTyped(configDir)` returning
  `map[string]BlacklistEntry`, new `IsIPInBlacklistFile(ip, entries)`
  helper using `netip.Prefix.Contains` for CIDR containment with
  fast-path exact-key match preserved. Legacy `LoadAllBlacklists`
  kept as thin wrapper around `LoadAllBlacklistsTyped` per dual-API
  pattern from `V119_MANUAL_CIDR_PREFLIGHT_PROFILE_SYNC_AUDIT.md` §5
  (`profile_sync.go` callers preserved on legacy API byte-unchanged).
  +107/−36. (PR #633)

- `internal/whitelist/loader.go` — parallel implementation: new
  `WhitelistEntry{Value,IsCIDR}` + `LoadAllWhitelistsTyped` +
  `IsIPInWhitelistFile` + legacy wrapper preserved. Orphan
  `loadWhitelistFile` helper deleted in remediation commit
  `15e48816` (staticcheck U1000) per
  `V119_A1_WHITELIST_BLACKLIST_CORRECTNESS_AND_ORPHAN_AUDIT.md`
  verdict `V119_A1_CORRECTNESS_CONFIRMED_REMEDIATION_IS_SINGLE_ORPHAN_DELETE`.
  Blacklist counterpart `loadBlacklistFile` retained — still used by
  pre-existing `GetBlacklistByCategory()`; whitelist has no symmetric
  `GetWhitelistByCategory` (pre-V119 asymmetry).
  +108/−37, then -25 in remediation. (PR #633)

### Fixed (D1 + D2 + D3 + whitelist CIDR safety predicate)

- `cmd/nftban-core/cmd_check.go` — whitelist + blacklist membership
  check swap from exact-key `map[ip]` to CIDR-aware helpers. +8/−8.
  (PR #633)

- `cmd/nftban-core/cmd_ban.go` — pre-ban whitelist guard and
  already-banned detection swap to CIDR-aware helpers. +8/−8. (PR #633)

- `cmd/nftban-core/cmd_unban.go` — file-membership check swap to
  CIDR-aware helper. Per V116 §7 Test 6 design: file is treated as
  authoritative for what the operator wrote; single-IP-inside-CIDR
  removal does NOT auto-rewrite the file; kernel-side removal
  proceeds via existing `backend.Unban` IPC path. +8/−3. (PR #633)

- `cmd/nftban-core/cmd_status.go` — D3 label disambiguation: upper-pane
  stats labels gain `(configured file entries)` suffix to disambiguate
  file-loaded counts from kernel-enforced counts in lower "Shared
  State" pane. Text-only change; `runtime.Counters.TotalBlacklistIPv*`
  field name byte-unchanged per V116 §3 (preserves watchdog/metrics
  surface). +9/−4. (PR #633)

- `cmd/nftband/daemon_handlers_ban.go` — **safety-invariant fix**:
  `isWhitelisted()` IPC pre-ban guard now uses
  `whitelist.IsIPInWhitelistFile` so an IP inside a whitelisted CIDR
  (e.g. `1.2.3.5` against stored `1.2.3.0/27`) is now correctly
  protected from being banned. Pre-V119 the guard silently failed
  to detect IP-in-CIDR membership, allowing bans to proceed against
  IPs inside whitelisted CIDR ranges. Pure internal-Go predicate
  change — no JSON, no IPC method, no Prometheus metric, no Status
  JSON wire format change, no CLI whitelist output change. +8/−3.
  (PR #633)

- `cli/lib/nftban/cli/cmd_blacklist.sh` — D2 closure: text-mode
  `nftban_blacklist_list` now queries BOTH `blacklist_ipv4`
  (interval, CIDRs from feeds/geoban) AND `blacklist_manual_ipv4`
  (hash, single-IP manual bans), merges via `sort -u`
  (deduplicated), mirroring canonical `cmd_list.sh:165-200`
  pattern. Pre-V119 this command queried only `blacklist_ipv4` and
  silently missed all `blacklist_manual_ipv4` entries. JSON path
  byte-unchanged (already delegates to `nftban list banned --json`
  which queries both sets). +38/−24. (PR #633)

### Tests (V116 §7 acceptance bar — 10 cases covered)

- `internal/blacklist/loader_test.go` — extended +169 (6 new test
  funcs): `TestLoadAllBlacklistsTyped_PreservesIsCIDR`,
  `TestIsIPInBlacklistFile_SingleIPv4ExactMatch`,
  `TestIsIPInBlacklistFile_IPv4CIDRContainment`,
  `TestIsIPInBlacklistFile_SingleIPv6ExactMatch`,
  `TestIsIPInBlacklistFile_IPv6CIDRContainment`,
  `TestIsIPInBlacklistFile_InvalidIPInput`,
  `TestLoadAllBlacklists_DualAPIParity`. Covers V116 §7 Tests 1-4 +
  dual-API parity guard.

- `internal/whitelist/loader_test.go` — extended +130 (6 new test
  funcs): symmetric matrix to blacklist.

- `internal/blacklist/schema_freeze_test.go` (NEW, +56):
  `TestSchemaVersionUnchangedByManualCIDRFix` asserts
  `validator.SchemaVersionCurrent == "1.83.0"` per V116 §7 Test 10
  regression guard. Fails closed if any future V119-class change
  accidentally introduces a schema-impacting field.

- `cmd/nftband/daemon_handlers_ban_test.go` (NEW, +102, 5 test
  funcs): `TestIsWhitelisted_IPv4CIDRContainment` (the V119 fix),
  `TestIsWhitelisted_IPv4ExactMatch` (regression guard for
  single-IP), `TestIsWhitelisted_IPv6CIDRContainment`,
  `TestIsWhitelisted_NoConfigDir`, `TestIsWhitelisted_EmptyWhitelist`.
  Covers V116 §7 Test 5.

- `cli/lib/nftban/tests/cmd_blacklist_list_test.sh` (NEW, +199, 5
  fixtures × 7 assertions, all PASS locally): mocks `nft list set`
  via PATH stub in `mktemp -d` sandbox; F1 both sets populated → both
  visible; F2 only hash set → entries visible; F3 same IP in both
  sets → deduplicated; F4 both empty → `(empty)` marker; F5 neither
  set exists → `(not available)` marker. Covers V116 §7 Test 9.

### Closes

- `D-MANUAL-CIDR-LOAD-GAP` — D1 (loader) + D2 (shell list) + D3
  (status label) + daemon-side whitelist CIDR safety predicate — by PR #633

### Mechanism unchanged (V116 §5 forbidden surfaces preserved)

- `internal/nftbackend/backend.go` byte-unchanged (CIDR routing to
  `blacklist_ipv4` interval set + single-IP routing to
  `blacklist_manual_ipv4` hash set already correct pre-V119)
- `internal/opqueue/types.go` byte-unchanged (set-name mapping)
- `internal/setsync/*` byte-unchanged
- `internal/metrics/*` byte-unchanged
- `internal/loginmon/*` byte-unchanged (v1.113 LoginMon path independent)
- `internal/validator/types.go` byte-unchanged (schema 1.83.0 const +
  in-PR `TestSchemaVersionUnchangedByManualCIDRFix` enforces)
- `install/nftables/*` byte-unchanged (no new kernel set — both
  `blacklist_ipv4` interval + `blacklist_manual_ipv4` hash already
  existed pre-V119; the bug was at the shell-query and Go-helper
  layers only)
- `cli/lib/nftban/lib/nft_schema.sh` byte-unchanged (schema mirror)
- `internal/installer/*` + `cmd/nftban-installer/*` byte-unchanged
- `packaging/*` + `install/packaging/*` byte-unchanged
- `cli/lib/nftban/cli/cmd_list.sh` byte-unchanged (already correct
  per V116 §3 NOT-defects)
- `cli/lib/nftban/cli/cmd_whitelist.sh` byte-unchanged (out of V116
  scope per §5)
- `cmd/nftban-core/profile_sync.go` byte-unchanged (hidden caller
  honored via dual-API per V119 preflight audit)
- `internal/runtime/state.go` byte-unchanged (lowest-churn variant
  per V116 §4 file 3 — V119 callsites bypass runtime state and use
  typed loader + helper directly)

### Continuous protection preserved

v1.112.2 `status=226/NAMESPACE` regression class continues to be
guarded by the workflow_run-triggered Fresh-Install Namespace Guard
built across V114 PRs #612-#620 + V115 PR #624's `/bin/kill` polish.
**32/32 A1-A4 assertions expected PASS on the v1.119.0 baseline**
post-tag, continuing the streak from v1.118.0 / v1.117.0 / v1.116.0 /
v1.115.0 / v1.114.0 release-prep verification.

### Files touched (the entire envelope)

V119 candidate envelope (already on `main` before this release-prep):

- `internal/blacklist/loader.go` (+107/−36) — PR #633
- `internal/whitelist/loader.go` (+108/−37, then −25 remediation) — PR #633
- `internal/blacklist/loader_test.go` (+169) — PR #633
- `internal/whitelist/loader_test.go` (+130) — PR #633
- `internal/blacklist/schema_freeze_test.go` (NEW, +56) — PR #633
- `cmd/nftban-core/cmd_check.go` (+8/−8) — PR #633
- `cmd/nftban-core/cmd_ban.go` (+8/−8) — PR #633
- `cmd/nftban-core/cmd_unban.go` (+8/−3) — PR #633
- `cmd/nftban-core/cmd_status.go` (+9/−4) — PR #633
- `cmd/nftband/daemon_handlers_ban.go` (+8/−3) — PR #633
- `cmd/nftband/daemon_handlers_ban_test.go` (NEW, +102) — PR #633
- `cli/lib/nftban/cli/cmd_blacklist.sh` (+38/−24) — PR #633
- `cli/lib/nftban/tests/cmd_blacklist_list_test.sh` (NEW, +199) — PR #633

Cumulative PR #633: +936/−134 across 13 files.

Plus the v1.119.0 release-prep 4-file envelope (this PR):

- `VERSION` (1.118.0 → 1.119.0)
- `STATUS.md` (v1.119.0 release-lane paragraph + v1.118.0 demoted)
- `CHANGELOG.md` (this entry)
- `cli/lib/nftban/core/nftban_fhs_spec.sh` (auto-regen via
  `build/generate-fhs-outputs.sh`; banner version only; FHS
  path-table body byte-unchanged because V119 did not touch
  `build/fhs-spec.yaml`)

**No daemon binary byte-equivalence claim** (this release ships real
Go change in blacklist/whitelist loader + 4 callsite swaps + daemon
guard). **No schema change. No `internal/validator` change. No
metric change. No nftables kernel set change. No RPM/DEB packaging
change. No systemd unit change. No `go.mod`/`go.sum` change.**

### Workspace artifacts (no PR, no code)

V119 design-lock + decision chain filed at `AUDIT_190_LIFECYCLE/`:

- `V119_SCOPE_TRIAGE.md` (408 lines, recommended Option A dedicated
  A1 lane; verdict `V119_SCOPE_TRIAGE_LOCKED_PLAN_READY`)
- `V119_MANUAL_CIDR_SCHEMA_IMPACT_DECISION.md` (252 lines, 5-row
  decision matrix Q1-Q5; verdict `SCHEMA_STAYS_FROZEN`)
- `V119_MANUAL_CIDR_PREFLIGHT_PROFILE_SYNC_AUDIT.md` (247 lines,
  dual-API non-blocking pattern; verdict
  `SCOPE_CONSTRAINT_CONFIRMED_NON_BLOCKING_WITH_DUAL_API`)
- `V119_A1_WHITELIST_BLACKLIST_CORRECTNESS_AND_ORPHAN_AUDIT.md` (352
  lines, Part A correctness 6/6 + Part B orphan scan 4/4 + remediation
  envelope; verdict
  `V119_A1_CORRECTNESS_CONFIRMED_REMEDIATION_IS_SINGLE_ORPHAN_DELETE`)

All four artifacts read-only / zero code mutation / zero host contact
during preflight + verification cycles.

### Non-goals carried forward to v1.120+

Explicit deferred debt — each separately gated:

- **FHS Phase D-1 Authority Territory Graph filing** — design-only
  deliverable per `V118_FHS_SINGLE_AUTHORITY_DESIGN_SCOPE.md` §6 Option
  D phasing; deferred since v1.118 Track A; recommended next
  workspace-only gate.
- **B2** EVE overlap review (LoginMon + Suricata double-action) —
  separate gate, architectural decision pending.
- **B3** Legacy parser decommission (4 stale shell files) — separate
  gate, needs 7-day soak period.
- **B4** Plesk/cPanel distroconf keys (BUG-14 schema closure) —
  separate gate, blocked on schema-unfreeze decision.
- **B7** WordPress login-failure detector — separate gate, not scoped.
- **B8** stale CLI residue cleanup (nftban-api-server, nftban-ui
  residue from V108 closure) — separate gate, not scoped.
- All **schema-UNFREEZE** items (PR-M2b-w2..w7, PR-M2c new nft named
  counters, PR-M2d kernel set element annotation cookies, PR-M3 + PR-M1,
  §F4 metrics beyond 6 PR-M2b-w1 targets, LoginMon subnet
  Prometheus emission)
- All **pre-V113 D-* large lanes** (D-MET-1, D-MOD-1, D-DNS-1,
  D-FHS-1..5 implementation, D-SHA-1, D-POL-1, D-SEC-1, D-TRP-1,
  D-EGM-1, D-PNL-1, D-OSH-1, D-GHC-1, D-WIK-2, D-MIG-1, D-BKT-1
  Bucket-C 14 v0.x tags **NEVER delete remote**, D-LMA-1, R-11,
  #525 geoip Go panic Lane G, D-RECV-INSTALL-RESULT-JSON-PARSE-001
  nftbanpro_cms scope)
- **dns2 migration** — D-DNS-1 separately gated
- **nftbanpro_cms / portal changes** — separate-track / pro lanes
- **Packaging/systemd/installer payload changes** — none; future
  packaging cleanup lanes separate
- **Host rollout** (srv1–4, lab2, monitor) — post-publication
  fleet validation gates `EXECUTE_V119_VALIDATE_{LAB2,LAB4,SRV1-4,MONITOR}`,
  operator-conditional (mirrors v1.113 LoginMon HIGH-risk lane
  precedent for the dedicated narrow-feature release pattern)
- **Bucket-C v0.x tag changes** — FORBIDDEN INDEFINITELY
- **MASTER_TODO edits** — workspace control rule locked 2026-05-13

### Behavior changes (narrow, explicit)

- **ZERO behavior change for single-IP entries** in blacklist or
  whitelist files (loader output byte-equivalent for the common path;
  helpers' fast-path exact-key match preserves prior semantics).
- **NEW correct behavior for CIDR entries** in blacklist.d /
  whitelist.d configuration files:
  - `nftban check <ip>` against blacklist `1.2.3.0/27` containing
    `1.2.3.5` now correctly reports BLACKLISTED.
  - `nftban ban <ip>` against whitelist `1.2.3.0/27` containing
    `1.2.3.5` now correctly refuses with "IP is whitelisted, cannot ban".
  - `nftban unban <ip>` against blacklist file `1.2.3.0/27`
    containing `1.2.3.5` now correctly detects in-file membership
    (per V116 §7 Test 6 design the blacklist file is treated as
    authoritative for what operator wrote and is NOT auto-rewritten —
    kernel-side removal proceeds via existing `backend.Unban` IPC
    path).
  - Daemon `isWhitelisted(<ip>)` IPC pre-ban guard now correctly
    returns true for IPs inside whitelisted CIDR ranges
    (**silent safety-invariant violation now fixed**).
- **`nftban blacklist list`** text-mode now shows entries from both
  `blacklist_ipv4` and `blacklist_manual_ipv4` kernel sets,
  deduplicated. `--json` byte-unchanged.
- **`nftban status`** upper-pane stats labels gain `(configured file
  entries)` suffix; `runtime.Counters.TotalBlacklistIPv*` field name
  byte-unchanged.
- **New IPC traffic:** NONE. **New Prometheus metric:** NONE. **New
  Status JSON key:** NONE. **New file system surface:** NONE.
  **New external dependency:** NONE.
- **Docker/GHCR tag pattern after publication:** `v1.119.0`,
  `1.119.0`, `1.119`, `latest`, AND `sha-<8>` all resolve.

v1.119.x hotfix slot **not authorized** (latent reservation only —
opened only if a v1.119.0 defect surfaces).

---

## [v1.118.0] - 2026-05-16 — V118 narrow-cleanup: CSF #4 active-conflict CLI guidance + FHS single-authority design-scope

V118 narrow-cleanup release on top of v1.117.0. Bundles one shell-only
CLI surface (V118 B1) with **zero daemon binary change** — the v1.118.0
`/usr/lib/nftban/bin/nftband` is byte-identical to v1.117.0 (and to
v1.116.0, v1.115.0) because no `internal/` or `cmd/` Go code changes
ship in this release.

**Schema 1.83.0 remains frozen.** No new metric names, no new metric
registrations, no schema doc edits, no allow-list mutation. No new
behavior on the daemon `/metrics` surface, Status JSON wire format,
ban behavior, or per-IP/per-subnet scoring path.

### Added (CLI authority discoverability)

- `cli/lib/nftban/cli/cmd_status.sh` — adds `_status_section_authority()`
  section function reading
  `${NFTBAN_STATE_DIR:-/var/lib/nftban/state}/install_state` via
  `grep '^AUTHORITY='` and `grep '^CONFLICTS='` plus `cut -d= -f2-`.
  Section is emitted from `output_terminal()` between
  `_status_section_firewall` and `_status_section_services`. Silent
  when the state file is missing (fresh installs pre-classification)
  or `AUTHORITY=""` (FRESH installs pre-classification). When
  `AUTHORITY=AMBIGUOUS` AND `CONFLICTS` is non-empty (e.g. CSF/lfd/
  firewalld still active after a failed takeover attempt) the section
  emits a `WARNING: <conflicts> still active — nftban is not sole
  authority.` line followed by `ACTION:  Run 'nftban update
  --panel-auto-takeover' to disarm conflicts.`, closing the gap where
  operators on srv4-class hosts had to read
  `/var/lib/nftban/state/install_state` manually to discover the
  resolution command. Silent on `AUTHORITY=UPDATE` because V108 Item 5
  hygiene (`internal/installer/state/file.go:applyTerminalHygiene`)
  clears CONFLICTS on COMMITTED transition when Authority==UPDATE so
  UPDATE+CONFLICTS is transient and not the B1 actionable case.
  Also adds an `authority` JSON object to `output_json()` between the
  firewall close and master_enabled with fields `state` (string),
  `conflicts` (string), `ambiguous_with_conflicts` (bool); object is
  always emitted (empty strings + `false` when install_state is
  missing) so the JSON wire format is byte-stable for downstream
  parsers. 1 file (+47/-0). (PR #633)

- `cli/lib/nftban/tests/cmd_status_authority_test.sh` — NEW. 12
  sub-assertions across 5 fixtures: F1 AMBIGUOUS+CONFLICTS positive
  (header, fields, WARNING, ACTION); F2 UPDATE no-warning; F3
  missing install_state silent; F4 empty AUTHORITY silent; F5
  AMBIGUOUS without CONFLICTS no-warning. Sandbox isolation via
  `mktemp -d` + `NFTBAN_STATE_DIR` env override + `trap rm -rf`
  cleanup; no live `/var/lib/nftban` dependency. Test extracts the
  `_status_section_authority()` function definition from
  `cmd_status.sh` via `awk` and runs it in a subshell so the test
  does not need to source the full nftban runtime. 1 file (+182/0).
  (PR #633)

### Closes

- V118 B1 CSF #4 active-conflict CLI guidance gap recorded as
  `V117_BACKLOG_INVENTORY.md §C-1` — by PR #633

### Mechanism unchanged

- `internal/installer/state/file.go` — **byte-identical** to v1.117.0
  (B1 is a read-only consumer of fields owned by this file)
- `internal/installer/authority/types.go` — byte-identical (AUTHORITY
  enum `UPDATE/FRESH/TAKEOVER/ABORT/AMBIGUOUS` already canonical)
- All `cmd/nftban-installer/**`, `internal/installer/**`, `internal/`,
  `cmd/` — no Go change
- Daemon `nftband` binary — byte-identical to v1.117.0, v1.116.0, v1.115.0

### Continuous protection preserved

v1.112.2 `status=226/NAMESPACE` regression class continues to be
guarded by the workflow_run-triggered Fresh-Install Namespace Guard
built across V114 PRs #612-#620 + V115 PR #624's `/bin/kill` polish.
**32/32 A1-A4 assertions expected PASS on the v1.118.0 baseline**
post-tag, continuing the streak from v1.117.0 / v1.116.0 / v1.115.0 /
v1.114.0 release-prep verification.

### Files touched (the entire envelope)

V118 candidate envelope already on `main` before this release-prep:

- `cli/lib/nftban/cli/cmd_status.sh` (+47/-0) — PR #633 B1 authority section
- `cli/lib/nftban/tests/cmd_status_authority_test.sh` (NEW, +182) — PR #633

Plus the v1.118.0 release-prep 4-file envelope (this PR):

- `VERSION` (1.117.0 → 1.118.0)
- `STATUS.md` (v1.118.0 release-lane paragraph + v1.117.0 demoted)
- `CHANGELOG.md` (this entry)
- `cli/lib/nftban/core/nftban_fhs_spec.sh` (auto-regen via
  `build/generate-fhs-outputs.sh`; header version-banner only; no
  FHS path-table change because B1 did not touch
  `build/fhs-spec.yaml`)

**No daemon binary change.** No `internal/` Go change. No `cmd/`
Go change. No schema change. No FHS spec body change. No RPM
packaging change. No DEB packaging change. No systemd unit change.
No metric / label / cardinality change. No `go.mod`/`go.sum` change.

### Workspace artifacts (no PR, no code)

v1.118 Track A FHS Single-Authority Design design-scope filed at:

- `AUDIT_190_LIFECYCLE/V118_DUAL_TRACK_SCOPE.md` (314 lines, recommends
  Option D Hybrid staged authority preserving MFST + adding executive
  authority layer for `nftban_health_fix_permissions` + RPM/DEB
  scriptlets + Go installer `applyPermissions`; D-FHS-1..5 decomposed
  into 5 separately gated phases D-1 Authority Territory Graph
  filing through D-6 polkit live-consumer audit across multiple
  release cycles)
- `AUDIT_190_LIFECYCLE/V118_FHS_SINGLE_AUTHORITY_DESIGN_SCOPE.md`
  (314 lines, 19-surface authority territory matrix + 5 drift classes
  + 4-option comparison rejecting Options B/C and choosing Option D)
- `AUDIT_190_LIFECYCLE/V118_SCOPE_FILING_CLOSURE.md` (closure record)

Phase D-1 Authority Territory Graph filing **deferred** to separately
gated session; no v1.118 implementation.

### Non-goals carried forward to v1.119+

Explicit deferred debt — each separately gated:

- **Cand 3** Manual CIDR design fix Option D (DESIGN-LOCKED in
  `V116_CAND3_MANUAL_CIDR_DESIGN_FIX_SCOPE.md`; cross-10-file Go +
  shell + counter-UX change; HIGH-risk; recommended for its own
  narrow-feature **v1.119** dedicated lane with fleet validation
  acceptance gates `EXECUTE_V119_VALIDATE_SRV*`, mirroring the
  v1.113 LoginMon subnet aggregation release pattern;
  D-MANUAL-CIDR-LOAD-GAP)
- **D-FHS-1..5 Phase D-1..D-6 implementation** — design-only filed
  in v1.118 Track A; each phase separately gated across multiple
  release cycles
- **B2** EVE overlap review (LoginMon + Suricata double-action) —
  separate gate, architectural decision pending
- **B3** Legacy parser decommission (4 stale shell files) — separate
  gate, needs 7-day soak
- **B4** Plesk/cPanel distroconf keys (BUG-14 schema closure) —
  separate gate, blocked on schema-unfreeze decision
- **B7** WordPress login-failure detector — separate gate, not scoped
- **B8** stale CLI residue cleanup (nftban-api-server, nftban-ui
  residue from V108 closure) — separate gate, not scoped
- All **schema-UNFREEZE** items (PR-M2b-w2..w7, PR-M2c new nft named
  counters, PR-M2d kernel set element annotation cookies, PR-M3 + PR-M1,
  §F4 metrics beyond 6 PR-M2b-w1 targets, LoginMon subnet
  Prometheus emission)
- All **pre-V113 D-* large lanes** (D-MET-1, D-MOD-1, D-DNS-1,
  D-FHS-1..5 implementation, D-SHA-1, D-POL-1, D-SEC-1, D-TRP-1,
  D-EGM-1, D-PNL-1, D-OSH-1, D-GHC-1, D-WIK-2, D-MIG-1, D-BKT-1
  Bucket-C 14 v0.x tags **NEVER delete remote**, D-LMA-1, R-11,
  #525 geoip Go panic Lane G, D-RECV-INSTALL-RESULT-JSON-PARSE-001
  nftbanpro_cms scope)
- **dns2 migration** — D-DNS-1 separately gated
- **nftbanpro_cms changes** — separate-track / pro lanes
- **Packaging/systemd/installer payload changes** — none; future
  packaging cleanup lanes separate
- **Host rollout** (srv1–4, lab2, monitor) — post-publication
  validation gate, operator-conditional
- **Bucket-C v0.x tag changes** — FORBIDDEN INDEFINITELY
- **MASTER_TODO edits** — workspace control rule locked 2026-05-13

### Behavior changes (narrow, explicit)

- **None on daemon.** `nftban-core` / `nftband` byte-identical to
  v1.115.0, v1.116.0, and v1.117.0.
- **`nftban status` text output** gains an optional new AUTHORITY
  section between FIREWALL and SERVICES. Section is silent when
  install_state is missing or AUTHORITY=""; emits 1-line WARNING +
  1-line ACTION when AUTHORITY=AMBIGUOUS + CONFLICTS non-empty;
  emits header + fields only on other AUTHORITY values
  (UPDATE/FRESH/TAKEOVER/ABORT).
- **`nftban status --json`** adds a new `authority` object between
  the firewall and master_enabled top-level keys. Fields: `state`
  (string), `conflicts` (string), `ambiguous_with_conflicts` (bool).
  Object is always emitted (empty strings + `false` when install_state
  is missing) so JSON wire format is byte-stable.
- **New file read at status time:**
  `${NFTBAN_STATE_DIR:-/var/lib/nftban/state}/install_state` — bounded
  by `[[ -f $state_file ]]` existence check; idempotent; no write; no
  daemon contact; no IPC; no network.
- **Docker/GHCR tag pattern after publication:** `v1.118.0`,
  `1.118.0`, `1.118`, `latest`, AND `sha-<8>` all resolve (the
  `sha-<8>` 8-char short-SHA tag continues to use the v1.117.0
  raw-template escape hatch from PR #631).

v1.118.x hotfix slot **not authorized** (latent reservation only —
opened only if a v1.118.0 defect surfaces).

---

## [v1.117.0] - 2026-05-16 — V117 narrow-cleanup: firewall takeover discoverability + Docker SHA-length fix

V117 narrow-cleanup release on top of v1.116.0. Bundles two non-Go
fixes with **zero daemon binary change** — the v1.117.0
`/usr/lib/nftban/bin/nftband` is byte-identical to v1.116.0 (and to
v1.115.0) because no `internal/` or `cmd/` Go code changes ship in
this release.

**Schema 1.83.0 remains frozen.** No new metric names, no new metric
registrations, no schema doc edits, no allow-list mutation. No new
behavior on the daemon `/metrics` surface, Status JSON wire format,
ban behavior, or per-IP/per-subnet scoring path.

### Added (CLI discoverability)

- `commands.registry.yml` — registers `firewall.subcommands.takeover`
  (`requires_root: true`, options `--panel-auto-takeover` + `--dry-run`,
  examples, reversibility notes, env-mirror reference) and
  `update.options.--panel-auto-takeover`. The existing central
  pipeline (`scripts/generate-help.sh` +
  `scripts/generate-wiki-operator.sh` +
  `scripts/generate-wiki-auditor.sh` + bash completion +
  `scripts/lint-registry-parity.sh` G15) picks both surfaces up
  automatically. The 72-entry registry was the central CLI/help
  source-of-truth; the takeover mechanism (well-engineered since
  PR-22B 2026-02) was invisible to operators through normal
  discovery channels until this release. (PR #630)

- `cli/lib/nftban/cli/cmd_firewall.sh` — adds `takeover` dispatch case
  + `firewall_takeover()` handler with `--help` (Usage block citing
  reversibility, env-mirror, and reverse path), root + `--dry-run`
  gating, and `exec` of
  `/usr/lib/nftban/bin/nftban-installer --mode=upgrade
  [--panel-auto-takeover] [--dry-run]`. Refuses with operator-actionable
  error when invoked without `--panel-auto-takeover` or `--dry-run`.
  Refuses with privilege error when invoked non-root without
  `--dry-run`. 1 file (+87/-0). (PR #630)

- `cli/lib/nftban/cli/cmd_update.sh` — parses + strips
  `--panel-auto-takeover` from argv in the `nftban_cmd_update`
  preamble and exports `NFTBAN_PANEL_AUTO_TAKEOVER=1`. The
  install.sh chain (install.sh:67 `exec` of installer) inherits env,
  so the existing env-mirror handler at
  `cmd/nftban-installer/flags.go:141` picks it up across every
  update path (github / git / local / package). Stripping the flag
  before the existing case dispatcher avoids polluting version /
  branch / path subcommand parsers. 1 file (+19/-0). (PR #630)

- `cli/lib/nftban/tests/cmd_firewall_takeover_test.sh` — NEW. 21
  sub-assertions across help output, no-flags refusal, dry-run argv,
  panel-auto-takeover argv forwarding, unknown-arg refusal, root
  gate, update env-mirror set/unset, registry YAML structural
  validity, and a regression guard asserting
  `cmd/nftban-installer/flags.go` byte-unchanged vs main
  (scope-violation guard). 1 file (+332/0). (PR #630)

### Fixed (Docker tag scheme polish)

- `.github/workflows/docker.yml` — closes
  `D-DOCKER-SHA-LENGTH-OBSERVATION` from
  `V1_116_0_RELEASE_CLOSURE.md` §6. `docker/metadata-action@v5`
  silently ignores `length=N` on `type=sha` (the action hard-codes
  `context.sha.substr(0, 7)` for `format=short`). v1.116.0 evidence:
  workflow declared `type=sha,format=short,length=8` yet the
  published Docker tag was `sha-3ea0488` (7-char) instead of the
  intended `sha-3ea0488b` (8-char). The fix adds a pre-step that
  computes `${GITHUB_SHA:0:8}` via `cut -c1-8`, exports as
  `SHA_SHORT` via `$GITHUB_ENV`, and replaces the broken sha rule
  with `type=raw,value=sha-${{ env.SHA_SHORT }},enable=true,priority=100`
  — the canonical metadata-action escape hatch. v-prefix + non-v +
  major.minor semver tags from v1.116.0 PR #626 remain unchanged.
  1 file (+20/-3). (PR #631)

### Closes

- V117 firewall-takeover-discoverability-gap — by PR #630
- D-DOCKER-SHA-LENGTH-OBSERVATION (v1.116.0 closure §6) — by PR #631

### Mechanism unchanged

- `cmd/nftban-installer/flags.go` — **byte-identical** to v1.116.0
  (regression-guarded by test T9.1 in PR #630)
- `internal/installer/switchop/takeover.go` — byte-identical
- `internal/installer/restore/contract.md` — byte-identical
- `internal/installer/uninstall/contract.md` — byte-identical
- All `cmd/nftban-installer/**`, `internal/installer/**` — no Go change
- Takeover mechanism preserved from PR-22B (2026-02)

### Continuous protection preserved

v1.112.2 `status=226/NAMESPACE` regression class continues to be
guarded by the workflow_run-triggered Fresh-Install Namespace Guard
built across V114 PRs #612-#620 + V115 PR #624's `/bin/kill` polish.
**32/32 A1-A4 assertions expected PASS on the v1.117.0 baseline**
post-tag, continuing the streak from v1.116.0 / v1.115.0 / v1.114.0
release-prep verification.

### Files touched (the entire envelope)

V117 candidate envelope already on `main` before this release-prep:

- `commands.registry.yml` (+25/-0) — PR #630 takeover discoverability
- `cli/lib/nftban/cli/cmd_firewall.sh` (+87/-0) — PR #630
- `cli/lib/nftban/cli/cmd_update.sh` (+19/-0) — PR #630
- `cli/lib/nftban/tests/cmd_firewall_takeover_test.sh` (+332/0) — PR #630
- `.github/workflows/docker.yml` (+20/-3) — PR #631 SHA-length fix

Plus the v1.117.0 release-prep 4-file envelope (this PR):

- `VERSION` (1.116.0 → 1.117.0)
- `STATUS.md` (v1.117.0 release-lane paragraph)
- `CHANGELOG.md` (this entry)
- `cli/lib/nftban/core/nftban_fhs_spec.sh` (auto-regen via
  `build/generate-fhs-outputs.sh`; header version-banner only; no
  FHS path-table change)

**No daemon binary change.** No `internal/` Go change. No `cmd/`
Go change. No schema change. No FHS spec body change. No RPM
packaging change. No DEB packaging change. No systemd unit change.
No metric / label / cardinality change. No `go.mod`/`go.sum` change.

### Non-goals carried forward to v1.118+

Explicit deferred debt — each separately gated:

- **Cand 3** Manual CIDR design fix Option D (DESIGN-LOCKED in
  `V116_CAND3_MANUAL_CIDR_DESIGN_FIX_SCOPE.md`; cross-10-file Go +
  shell + counter-UX change; HIGH-risk; recommended for its own
  narrow-feature **v1.118** release with fleet validation
  acceptance gates `EXECUTE_V118_VALIDATE_SRV*`, mirroring the
  v1.113 LoginMon subnet aggregation release pattern;
  D-MANUAL-CIDR-LOAD-GAP)
- **B7** WordPress login-failure detector — separate gate, not scoped
- **B8** stale CLI residue cleanup (nftban-api-server, nftban-ui
  residue from V108 closure) — separate gate, not scoped
- All **schema-UNFREEZE** items (PR-M2b-w2..w7, PR-M2c new nft named
  counters, PR-M2d kernel set element annotation cookies, PR-M3 + PR-M1,
  §F4 metrics beyond 6 PR-M2b-w1 targets, LoginMon subnet
  Prometheus emission)
- All **pre-V113 D-* large lanes** (D-MET-1, D-MOD-1, D-DNS-1,
  D-FHS-1..5, D-SHA-1, D-POL-1, D-SEC-1, D-TRP-1, D-EGM-1, D-PNL-1,
  D-OSH-1, D-GHC-1, D-WIK-2, D-MIG-1, D-BKT-1 Bucket-C 14 v0.x tags
  **NEVER delete remote**, D-LMA-1, R-11, #525 geoip Go panic Lane G,
  D-RECV-INSTALL-RESULT-JSON-PARSE-001 nftbanpro_cms scope)
- **dns2 migration** — D-DNS-1 separately gated
- **nftbanpro_cms changes** — separate-track / pro lanes
- **Packaging/systemd/installer payload changes** — none; future
  packaging cleanup lanes separate
- **Host rollout** (srv1–4, lab2, monitor) — post-publication
  validation gate, operator-conditional
- **Bucket-C v0.x tag changes** — FORBIDDEN INDEFINITELY
- **MASTER_TODO edits** — workspace control rule locked 2026-05-13

### Behavior changes (narrow, explicit)

- **None on daemon.** `nftban-core` / `nftband` byte-identical to
  v1.115.0 and v1.116.0.
- **`nftban firewall takeover`** new CLI surface — wraps the
  existing installer; mechanism unchanged.
- **`nftban update --panel-auto-takeover`** exports
  `NFTBAN_PANEL_AUTO_TAKEOVER=1` env mirror for the duration of the
  update; existing handler at `cmd/nftban-installer/flags.go:141`
  is unchanged.
- **Docker/GHCR tag pattern after publication:** `v1.117.0`,
  `1.117.0`, `1.117`, `latest` all resolve (PR #626 logic
  preserved); `sha-<8>` 8-character short-SHA tag is **restored**
  via PR #631 (was: only 7-char `sha-<7>` resolved in v1.116.0).

v1.117.x hotfix slot **not authorized** (latent reservation only —
opened only if a v1.117.0 defect surfaces).

---

## [v1.116.0] - 2026-05-16 — V116 narrow-cleanup: Docker tag scheme restore + LoginMon CLI source-state visibility

V116 narrow-cleanup release on top of v1.115.0. Bundles two non-Go fixes
with **zero daemon binary change** — the v1.116.0
`/usr/lib/nftban/bin/nftband` is byte-identical to v1.115.0 because no
`internal/` or `cmd/` Go code changes ship in this release.

**Schema 1.83.0 remains frozen.** No new metric names, no new metric
registrations, no schema doc edits, no allow-list mutation. No new
behavior on the daemon `/metrics` surface, Status JSON wire format, ban
behavior, or per-IP/per-subnet scoring path.

### Fixed (Docker tag scheme)

- `.github/workflows/docker.yml` — restored pre-v1.108.0-era convenience
  tag pattern to the `docker/metadata-action@v5` configuration. Added
  `type=semver,pattern=v{{version}}` alongside the existing non-v
  `{{version}}` and `{{major}}.{{minor}}` rules so both
  `ghcr.io/itcmsgr/nftban:v1.116.0` and `ghcr.io/itcmsgr/nftban:1.116.0`
  resolve post-publication. Added explicit
  `type=sha,format=short,length=8` to restore 8-character short-SHA tags
  (default `type=sha` is 7-char; explicit length matches git short-form).
  Workflow-only — no nftban product code change. Closes the V114 PR #620
  Docker tag scheme drift observation. 1 file (+8/-1). (PR #626)

### Added (LoginMon CLI source-state visibility)

- `cli/lib/nftban/cli/cmd_login.sh` — `nftban login stats` now consumes
  the daemon's existing `modules` IPC method and renders the typed
  `LoginMonStatusExtra` fields when available. New helpers
  `_loginmon_ipc_call` (Unix-socket call via `socat - UNIX-CONNECT:`,
  mirroring the proven `cmd_watchdog.sh:_watchdog_ipc_call` pattern) +
  `_loginmon_extract_extra` (extracts `.data[] | select(.name=="loginmon") | .extra`
  via `jq`). Text mode renders: module status header (mode,
  suricata_available, tracked_ips), totals with IPv4/v6 split, top
  services by detections, top reasons by bans, and the v1.113 subnet
  aggregation section (zero-omittable — shown only when any of
  `subnet_pressure_count` / `subnet_bans_total` / `subnet_watch_active`
  is non-zero). The pre-v1.116 file-log section is preserved verbatim
  as "Today's logged events". When daemon socket / `socat` / `jq`
  unavailable, the formatter degrades to file-log-only with a
  `(daemon unreachable — file-log fallback only)` notice and exits 0.
  JSON mode adds a `.module` key when daemon data is available and
  omits the key entirely when unavailable; `.events` and `.service`
  keys remain byte-stable for existing JSON consumers. **No new IPC
  method. No new HTTP route. No new Go struct. No `internal/loginmon/`
  touch. No daemon code touch.** 1 file (+177/-27). (PR #628)

- `cli/lib/nftban/tests/cmd_login_stats_test.sh` — NEW. Bats-free test
  fixture with 27 sub-assertions across 6 scenarios (daemon-up text,
  daemon-up JSON, daemon-down text fallback, daemon-down JSON omit,
  subnet-zero omission, subnet-non-zero presence). Executes entirely
  in a `mktemp -d` sandbox with a PATH-based `socat` wrapper, stubbed
  `systemctl`, and a passthrough `json_output`. Verifies that existing
  `TestLoginMonStatusExtra_*` Go regression guards in
  `internal/loginmon/module_test.go` remain byte-unchanged. 1 file
  (+323/0). (PR #628)

### Closes

- D-DOCKER-TAG-SCHEME-DRIFT (V114 PR #620 observation) — by PR #626
- LoginMon CLI source-state visibility gap (V117_BACKLOG_INVENTORY §B-1) — by PR #628

### Continuous protection preserved

v1.112.2 `status=226/NAMESPACE` regression class continues to be guarded
by the workflow_run-triggered Fresh-Install Namespace Guard built
across V114 PRs #612-#620 + V115 PR #624's `/bin/kill` polish.
**32/32 A1-A4 assertions expected PASS on the v1.116.0 baseline**
post-tag, continuing the streak from v1.115.0 / v1.114.0 release-prep
verification.

### Files touched (the entire envelope)

V116 candidate envelope already on `main` before this release-prep:

- `.github/workflows/docker.yml` (+8/-1) — P2 Docker tag scheme restore (PR #626)
- `cli/lib/nftban/cli/cmd_login.sh` (+177/-27) — V116 Cand 1 LoginMon CLI (PR #628)
- `cli/lib/nftban/tests/cmd_login_stats_test.sh` (+323) — V116 Cand 1 test fixture (PR #628)

Plus the v1.116.0 release-prep 4-file envelope (this PR):

- `VERSION` (1.115.0 → 1.116.0)
- `STATUS.md` (v1.116.0 release-lane paragraph + schema unchanged statement)
- `CHANGELOG.md` (this entry)
- `cli/lib/nftban/core/nftban_fhs_spec.sh` (auto-regen via
  `build/generate-fhs-outputs.sh`; header version-banner only; no
  FHS path-table change)

**No daemon binary change.** No `internal/` Go change. No `cmd/`
Go change. No schema change. No FHS spec body change. No RPM
packaging change. No DEB packaging change. No systemd unit change.
No metric / label / cardinality change. No `go.mod`/`go.sum` change.

### Non-goals carried forward to v1.117+

Explicit deferred debt — each separately gated:

- **Cand 3** Manual CIDR design fix Option D (DESIGN-LOCKED in
  `V116_CAND3_MANUAL_CIDR_DESIGN_FIX_SCOPE.md`; cross-5-file Go +
  shell + counter-UX change; HIGH-risk; v1.117 candidate via
  `OPEN_V117_MANUAL_CIDR_FIX_PR`; D-MANUAL-CIDR-LOAD-GAP)
- **B7** WordPress login-failure detector — separate gate, not scoped
- **B8** stale CLI residue cleanup (nftban-api-server, nftban-ui
  residue from V108 closure) — separate gate, not scoped
- All **schema-UNFREEZE** items (PR-M2b-w2..w7, PR-M2c new nft named
  counters, PR-M2d kernel set element annotation cookies, PR-M3 + PR-M1,
  §F4 metrics beyond the 6 PR-M2b-w1 targets, LoginMon subnet
  Prometheus emission `nftban_loginmon_subnet_pressure_total` +
  `nftban_loginmon_subnet_bans_total`)
- All **pre-V113 D-* large lanes** (D-MET-1, D-MOD-1, D-DNS-1,
  D-FHS-1..5, D-SHA-1, D-POL-1, D-SEC-1 SEC-FW-BYPASS-ALERT-GAP-001,
  D-TRP-1 TRANSPORT-001, D-EGM-1, D-PNL-1, D-OSH-1, D-GHC-1, D-WIK-2,
  D-MIG-1, D-BKT-1 Bucket-C 14 v0.x tags **NEVER delete remote** per
  long-standing policy, D-RECV-INSTALL-RESULT-JSON-PARSE-001
  nftbanpro_cms scope, D-LMA-1, R-11, #525 geoip Go panic Lane G)
- **dns2 migration** — D-DNS-1 separately gated
- **nftbanpro_cms changes** — separate-track / pro lanes
- **Packaging/systemd/installer payload changes** — none; future
  packaging cleanup lanes separate
- **Host rollout** (srv1–4, lab2, monitor) — post-publication
  validation gate, operator-conditional
- **Bucket-C v0.x tag changes** — FORBIDDEN INDEFINITELY per
  long-standing operator policy
- **MASTER_TODO edits** — FORBIDDEN per workspace control rule locked
  2026-05-13
- **README PR #586** — open PR, separate merge

### Behavior changes (narrow, explicit)

- **None on daemon.** The `nftban-core` / `nftband` binaries are
  byte-identical to v1.115.0.
- **`nftban login stats` text mode** adds a daemon-derived module
  status section when daemon data is reachable; on daemon-down the
  formatter is byte-equivalent to pre-v1.116 behavior.
- **`nftban login stats --json`** adds a `.module` key when daemon
  data is reachable; omits the key entirely otherwise (absence, not
  null). `.events` and `.service` keys remain byte-stable.
- **Docker/GHCR tag pattern after publication**: both `v1.116.0` and
  `1.116.0` resolve; `sha-<8>` resolves (was: `sha-<7>` only).
- New IPC traffic from CLI to daemon: one read-only `modules` IPC
  call per `nftban login stats` invocation; idempotent; bounded by
  `timeout 5` seconds; no daemon-side handler change required because
  the `modules` method has existed since prior releases.

v1.116.x hotfix slot **not authorized** (latent reservation only —
opened only if a v1.116.0 defect surfaces).

---

## [v1.115.0] - 2026-05-15 — V115 narrow-cleanup: DEB config-perm + D-DEG-1 fixes + CI guard polish

V115 operational hygiene / packaging and CI guard stabilization release on
top of v1.114.0. Bundles three workflow-only and packaging-only fixes with
**zero daemon binary change** — the v1.115.0 `/usr/lib/nftban/bin/nftband`
is byte-identical to v1.114.0 because no `internal/` or `cmd/` Go code
changes ship in this release.

**Schema 1.83.0 remains frozen.** No new metric names, no new metric
registrations, no schema doc edits, no allow-list mutation. No new
behavior on the daemon `/metrics` surface, Status JSON wire format, ban
behavior, or per-IP/per-subnet scoring path.

### Fixed (DEB packaging)

- `packaging/deb/postinst` — `/etc/nftban/nftban.conf` +
  `/etc/nftban/nftables.conf` + `/etc/nftban/conf.d/**/*.conf` +
  `/etc/nftban/conf.d/**/*.conf.default` now converge to **mode 0640
  owner `root:nftban`** after package install, matching RPM
  `%attr(640,root,nftban) %config(noreplace)` parity. The existing
  dir-only convergence loop intentionally skipped files; the new
  file-level loop closes the gap. Idempotent. `dpkg-statoverride`
  remove/add pattern for top-level conf files keeps `dpkg --verify`
  clean across reinstalls. Operator-edited file contents preserved —
  only ownership/mode changes. **Side-effect: closes D-DEG-1 sub-class
  B** (`Permission denied on /etc/nftban/nftban.conf` at
  `cli/lib/nftban/sbin/nftban-service-alert:47` when `nftban-alert@`
  template runs as user `nftban`). 1 file (+39/-0). (PR #622)

### Fixed (D-DEG-1 sub-class A)

- `install/systemd/nftban-queue.service` — `[Service]` section gains
  3 literal `Environment=` directives after `Type=oneshot`:
  ```
  Environment=NFTBAN_DATA_DIR=/var/lib/nftban
  Environment=NFTBAN_RUN_DIR=/run/nftban
  Environment=NFTBAN_LOG_DIR=/var/log/nftban
  ```
  The queue helper at `cli/lib/nftban/helpers/nftban_task_queue.sh`
  runs under `set -u` and references these vars without per-var
  fallbacks in fallback-substitution chains
  (`${NFTBAN_QUEUE_PENDING_DIR:-${NFTBAN_DATA_DIR}/queue/pending}`).
  systemd does not inherit shell environment by default; pre-v1.115
  the queue service hit `NFTBAN_DATA_DIR: unbound variable` on hosts
  where the system environment did not pre-set these vars (lab2
  reproduction confirmed in V113 fleet rollout). All three vars set
  defensively (defense-in-depth Option 1b) so any future helper that
  references RUN_DIR/LOG_DIR through the same fallback pattern is
  also protected. Literal `Environment=` chosen (Option 2a) over
  `EnvironmentFile=-` to avoid introducing an external packaging
  surface. 1 file (+12/-0). (PR #623)

### Fixed (CI Fresh-Install Namespace Guard)

- `.github/workflows/ci-fresh-install-namespace-guard.yml` — appended
  `procps` to each of 4 DEB matrix `systemd_install` entries
  (debian12 / debian13 / ubuntu22.04 / ubuntu24.04). `procps` provides
  `/usr/bin/kill`, which merged-usr `/bin → /usr/bin` symlink
  resolves to satisfy `nftband.service:75 ExecReload=/bin/kill -HUP
  $MAINPID` in minimal Debian/Ubuntu CI containers. Closes
  `D-V114-CI-GUARD-DEB-BINKILL-VERIFY-001` (the DEGRADED VERIFY-stage
  observation surfaced in V114 PR #620's decisive run, carried to
  v1.115 as deferred non-blocking polish). DEB installer now reports
  `outcome=SUCCESS, stage=FINAL, health=PROTECTED` (was `FAILED,
  VERIFY, DEGRADED`). Workflow-only — no nftban product code change.
  Same mechanical pattern as V114 PR #618 (curl restore) and PR #620
  (netbase add). 1 file (+4/-4). (PR #624)

### Closes

- `D-DEG-1` sub-class A (nftban-queue.service NFTBAN_DATA_DIR unbound) — by PR #623
- `D-DEG-1` sub-class B (alert@ EACCES on nftban.conf) — by PR #622 side-effect
- `D-V114-CI-GUARD-DEB-BINKILL-VERIFY-001` (DEB VERIFY-stage DEGRADED on /bin/kill) — by PR #624

### Continuous protection preserved

v1.112.2 `status=226/NAMESPACE` regression class continues to be
guarded by the workflow_run-triggered Fresh-Install Namespace Guard
built across V114 PRs #612-#620 + v1.115's `/bin/kill` polish.
**32/32 A1-A4 assertions PASS on the v1.115.0 baseline** (run
`25927046952` on commit `f5c8c242`), continuing the streak from
v1.114.0 release-prep verification.

### Files touched (the entire envelope)

3 PR envelope for v1.115 candidates (already on `main` before this
release-prep):

- `packaging/deb/postinst` (+39/-0) — Cand 6 (PR #622)
- `install/systemd/nftban-queue.service` (+12/-0) — Cand 2 sub-A (PR #623)
- `.github/workflows/ci-fresh-install-namespace-guard.yml` (+4/-4)
  — `/bin/kill` VERIFY polish (PR #624)

Plus the v1.115.0 release-prep 4-file envelope (this PR):

- `VERSION` (1.114.0 → 1.115.0)
- `STATUS.md` (v1.115.0 release-lane row + schema unchanged statement)
- `CHANGELOG.md` (this entry)
- `cli/lib/nftban/core/nftban_fhs_spec.sh` (auto-regen via
  `build/generate-fhs-outputs.sh`; header version-banner only; no
  FHS path-table change)

**No daemon binary change.** No `internal/` Go change. No `cmd/`
Go change. No schema change. No FHS spec body change. No RPM
packaging change. No metric / label / cardinality change. No
`go.mod`/`go.sum` change.

### Non-goals carried forward to v1.116+

Explicit deferred debt — each separately gated:

- **Cand 1** — LoginMon Source State API (CLI formatter for typed
  `LoginMonStatusExtra`); scope-plan first to confirm CLI-only
  contract surface
- **Cand 3** — Manual CIDR design fix Option D (typed `IsCIDR`
  loader + CIDR-containment in membership + counter-label
  clarification; HIGH-risk cross-5-file Go + shell + counter-UX
  change); design-only gate first; D-MANUAL-CIDR-LOAD-GAP
- Optional Docker tag scheme cleanup (V114 PR #620 surfaced drift:
  no v-prefix on Docker tag, 7-char short SHA instead of 8-char)
- V113 LoginMon scope/source audit B1-B8 follow-up gates (B1 legacy
  parser decommission, B2 subnet aggregation expansion, B4 FTP
  file watcher, B5 Plesk/cPanel distroconf keys, B6 EVE overlap
  review, B7 WP detector decision, B8 stale CLI residue cleanup)
- All Schema-UNFREEZE items (PR-M2b-w2..w7, PR-M2c, PR-M2d,
  LoginMon subnet Prometheus emission)
- All large lanes from V109 debt inventory (D-MET-1, D-MOD-1,
  D-DNS-1, D-FHS-1..5, D-SHA-1, D-POL-1, D-SEC-1, D-TRP-1, D-EGM-1,
  D-PNL-1, D-OSH-1, D-GHC-1, D-WIK-2, D-MIG-1, D-BKT-1 — **NEVER
  delete remote** per long-standing policy)
- V1.80 backlog reconciliation (historical input only — most items
  already shipped under different names)

### Behavior changes (narrow, explicit)

- **None on daemon.** The `nftban-core` / `nftband` binaries are
  byte-identical to v1.114.0.
- **DEB `packaging/deb/postinst`** runs an additional file-perm
  convergence loop at package-install time. Idempotent.
  Operator-edited file contents preserved.
- **`nftban-queue.service`** receives 3 literal `Environment=`
  directives. systemd-launched queue runs deterministic across
  distros without depending on inherited shell environment.
- **CI Fresh-Install Namespace Guard** uses richer DEB base images
  for the test scaffold (one additional package `procps`). No
  production-host impact.

v1.115.x hotfix slot **not authorized** (latent reservation only —
opened only if a v1.115.0 defect surfaces).

---

## [v1.114.0] - 2026-05-15 — V114 narrow-cleanup: RPM tmpfiles defensive mirror + CI fresh-install 226/NAMESPACE guard

V114 narrow-cleanup release on top of v1.113.0. Bundles three operational
hygiene improvements with **zero impact** on `nftban-core` / `nftband`
daemon behavior, packaging payloads, systemd units, or runtime semantics.
The v1.114.0 daemon binary is byte-identical to v1.113.0 because no
`internal/` or `cmd/` Go code changes ship in this release.

**Schema 1.83.0 remains frozen.** No new metric names, no new metric
registrations, no schema doc edits, no allow-list mutation. No new
behavior on the daemon `/metrics` surface, Status JSON wire format, ban
behavior, or per-IP/per-subnet scoring path.

### Added

- **CI: Fresh-Install Namespace Guard** workflow — workflow_run-triggered
  systemd-in-container assertion grid across 8 distros (alma9, rocky9,
  centos-stream9, centos-stream10, debian12, debian13, ubuntu22.04,
  ubuntu24.04). Runs after every `Build NFTBan Packages` success and
  validates four assertions per distro:
    - **A1** `nftband.service` active post-install
    - **A2** no `status=226/NAMESPACE` or `Failed to set up mount
      namespacing` entries in the unit journal
    - **A3** `/var/cache/nftban` exists post-install
    - **A4** no failed `nftban-*` dependent units
  32/32 assertions PASS on the v1.114.0 baseline. Continuous protection
  against the v1.112.2 226/NAMESPACE regression class on every PR-merge
  that touches packaging or installer paths. Architecture: inline
  per-distro Dockerfile builds a systemd-ready image (FROM matrix image
  → install systemd + iproute + nftables + jq + tar + family-specific
  prereqs → seed `/etc/ssh/sshd_config` with `Port 22` → STOPSIGNAL
  SIGRTMIN+3 → ENTRYPOINT `/sbin/init`), `docker run -d --privileged
  --tmpfs /run` starts systemd as PID 1, then `docker exec -i $CID bash
  -s <<'SCRIPT'` runs the install + A1-A4 grid. Cleanup trap captures
  last 200 in-container journal lines + last 100 docker stdout lines on
  any exit. Job-level `timeout-minutes: 5`. Workflow-only — **no nftban
  product code change**. (PRs #612, #613, #614, #615, #616, #617, #618,
  #620 over a single iteration arc; final SHA `3cbf1376`.)

### Fixed (defense-in-depth)

- `packaging/build_nftban.sh` STEP 0.5: idempotent
  `systemd-tmpfiles --create /usr/lib/tmpfiles.d/nftban.conf 2>/dev/null
  || true` call inserted between the RPM scriptlet's STEP 0 (yq link)
  and STEP 1 (Go installer). Mirror of the v1.112.2 DEB-postinst fix at
  `packaging/deb/postinst:196-203`. Protects against any future
  regression that removes `/var/cache/nftban` from the RPM payload. The
  V112.2 status=226/NAMESPACE failure was reproduced 0/5 on RPM during
  v1.112.2 validation; this call is strict defense-in-depth. (PR #612)

### Operational

- Closed stale GitHub Issue #212 (security-summary issue closed
  2026-05-14; operational hygiene; no code change).

### Files touched (the entire envelope)

The Cand 4 fix is **1 file**:

- `packaging/build_nftban.sh` (STEP 0.5 block at lines 933, 942, 945
  preserved across PRs #613-#620)

The Cand 5 CI guard is **1 file** (single new workflow):

- `.github/workflows/ci-fresh-install-namespace-guard.yml` — created in
  PR #612 and re-architected across 7 follow-up PRs; final shape: ~300
  LOC; systemd-as-PID-1 via inline Dockerfile + `docker run -d` +
  `docker exec` heredoc + cleanup trap + 30s readiness poll + 8-distro
  matrix.

The v1.114.0 release-prep envelope is **4 files**:

- `VERSION` (1.113.0 → 1.114.0)
- `STATUS.md` (v1.114.0 release-lane row + schema unchanged statement)
- `CHANGELOG.md` (this entry)
- `cli/lib/nftban/core/nftban_fhs_spec.sh` (auto-regen via
  `build/generate-fhs-outputs.sh` — header version-banner only;
  produces no FHS path-table changes)

No daemon binary change. No Go source change. No schema change. No
systemd unit changes. No FHS spec body change. No RPM/DEB packaging
payload change. No `go.mod`/`go.sum` change.

### Non-goals carried forward to v1.115+

Explicit deferred debt — each separately gated:

- **Cand 1** LoginMon Source State API — not yet scoped; product code
  change pending operator authorization.
- **Cand 2** D-DEG-1 investigation resume — investigation-only gate;
  requires 3-host lab reproduction queued from v1.108 lineage; two
  named sub-classes: A `NFTBAN_DATA_DIR: unbound variable` at
  `helpers/nftban_task_queue.sh:64` (env-var-export gap in queue unit);
  B `Permission denied on /etc/nftban/nftban.conf` at
  `sbin/nftban-service-alert:47` (alert-helper conf permission).
- **Cand 3** Manual-CIDR design fix — D-MANUAL-CIDR-LOAD-GAP; design
  decision pending; product code change.
- **Cand 6** DEB config-permission hardening — not yet scoped.
- **Optional** `D-V114-CI-GUARD-DEB-BINKILL-VERIFY-001` — non-blocking
  observation surfaced by the PR #620 decisive run. The
  nftban-installer VERIFY phase reports DEGRADED on DEB CI containers
  because `install/systemd/nftband.service:75 ExecReload=/bin/kill -HUP
  $MAINPID` does not resolve in minimal Debian containers without
  `bsdutils`/`procps`. A1-A4 all still PASS because the service IS
  active, the journal is clean, the cache dir exists, and no units are
  in `failed` state. Does not affect any real-host behavior (real
  Debian/Ubuntu hosts ship `/bin/kill` via `bsdutils` essential-priority
  or merged-usr `/bin → /usr/bin` symlink). Recommend defer to v1.115+
  if pursued at all.

All v1.113.0 deferred items remain deferred (PR-M2b-w2..w7 per-module
emission waves; PR-M2c new nft named counters; PR-M2d kernel set
element annotation cookies; PR-M3 cache v2 + PR-M1 CLI formatter; §F4
metrics beyond 6 PR-M2b-w1 targets; D-LMA-1; R-11; D-DNS-1 DESIGN-FIX;
D-FHS-1..5; D-SHA-1; D-POL-1; D-SEC-1 SEC-FW-BYPASS-ALERT-GAP-001;
D-TRP-1 TRANSPORT-001; D-EGM-1; D-PNL-1; D-OSH-1; D-GHC-1; D-BKT-1).

### Behavior changes (narrow, explicit)

- **None on daemon.** The `nftban-core` / `nftband` binaries are
  byte-identical to v1.113.0.
- **RPM `%post` STEP 0.5** fires `systemd-tmpfiles --create` once at
  install time on RPM hosts. Idempotent; no observable runtime change
  on hosts where `/var/cache/nftban` already exists.
- **CI Fresh-Install Namespace Guard** runs in GitHub Actions only; no
  production-host impact.

v1.114.x hotfix slot **not authorized** (latent reservation only —
opened only if a v1.114.0 defect surfaces).

---

## [v1.113.0] - 2026-05-13 — V113 LoginMon SMTP subnet aggregation: opt-in detection primitive for distributed /24 brute force

V113 single-PR feature release on top of v1.112.2. Closes
`D-LOGINMON-EXIM-SUBNET-ROTATION-GAP` from the srv1 production incident on
2026-05-13: a distributed `81.30.98.0/24` SMTP brute force where each
individual IP made only 1-2 attempts (15-30 points each) and never crossed
the per-IP LoginMon 45-point temp-ban threshold. Per-IP scoring could not
defeat the /24 rotation; this release adds a per-prefix tracking primitive
that runs in parallel to the existing per-IP map.

**The feature is disabled by default.** On hosts that do not enable it the
daemon `/metrics` surface, Status JSON wire format, ban behavior, and
per-IP scoring path are byte-identical to v1.112.2. **Schema 1.83.0
remains frozen.** **No Prometheus emission added.**

### Closes

- `D-LOGINMON-EXIM-SUBNET-ROTATION-GAP` (srv1 production incident
  2026-05-13: distributed `81.30.98.0/24` exim brute force; ~5 manual /27
  bans deployed as temporary mitigation before this release).

### Files touched (the entire envelope)

6 files / +1039 / -51 = **988 net new LOC**:

- `internal/loginmon/detector/scorer.go` (+393) — `SubnetState` type,
  `Scorer.subnets` per-prefix map, `BanAction.Prefix`/`IsSubnet` fields,
  `ScorerConfig` +13 new fields, `Stats` +3 atomic counters,
  `StatsSnapshot` +3 fields, `RecordVerdict` extension, new
  `checkSubnetAggregation` path + 5 private helpers
  (`subnetPrefixForIP`, `getOrCreateSubnetState`, `emitSubnetBan`,
  `isPrivateOrInternalPrefix`, `isInTrustedAllowlist`). gosec G115
  int→int32 bounded clamp on the unique-IP count at line 748 with
  explicit `#nosec` annotation.
- `internal/loginmon/detector/scorer_test.go` (+345) — 14 new
  `TestSubnetAgg_*` cases (disabled-noop, observe-mode pressure,
  enforce-mode CIDR ban, dual-threshold guards in both directions,
  private-range blocked, trusted allowlist, reason filter, IPv6 /64,
  window expiry, repeated-trigger suppression, max-tracked cap, prefix
  helpers × 10 subcases, allowlist helper × 4 subcases, per-IP path
  regression coverage).
- `internal/loginmon/module.go` (+139 / -13) — env-var parsing for 9
  `LOGINMON_EXIM_SUBNET_*` knobs, `buildScorerConfig` extended,
  `LoginMonStatusExtra` grows 18→21 fields with `omitempty` JSON tags,
  `ToExtraInfo` emits the 3 new fields non-zero-only, `Status()`
  populates them, `triggerBan` branches for CIDR target when
  `action.IsSubnet`. gosec errcheck `_, _ =` discard on 4×
  `fmt.Sscanf` returns.
- `internal/loginmon/module_test.go` (+85) — 2 new
  `TestLoginMonStatusExtra_SubnetFields_{ZeroOmitted,NonZeroEmitted}`
  cases that lock the wire-format invariant (disabled-feature hosts
  produce byte-identical Status.Extra payloads vs v1.112.2).
- `internal/loginmon/types.go` (+29) — `Config` +9 new fields with
  defaults (`SubnetAggEnabled=false`, `SubnetMode=observe`,
  `SubnetWindow=5m`, `SubnetUniqueIPsMin=5`, `SubnetMinTotalEvents=10`,
  `SubnetIPv4Prefix=24`, `SubnetIPv6Prefix=64`, `SubnetAction=ban_cidr`,
  `SubnetCIDRBanDuration=24h`).
- `docs/loginmon/SUBNET_AGGREGATION.md` (NEW, +99) — user-facing docs
  covering opt-in/observe-first, configuration reference, the 6
  false-positive guards, observability fields, performance
  characteristics, what-it-does-not-do (yet), and verification steps.

No daemon binary change beyond the LoginMon module. No schema change.
No systemd unit changes. No FHS spec body change. No RPM/DEB packaging
change. No `go.mod`/`go.sum` change. No CI workflow change.

### Design (locked)

8 user-visible config knobs (the 9th env-var binding covers the action
label completeness):

| Env key | Default | Purpose |
|---|---|---|
| `LOGINMON_EXIM_SUBNET_AGG_ENABLED` | `false` | Master toggle (opt-in) |
| `LOGINMON_EXIM_SUBNET_AGG_MODE` | `observe` | `observe` (count + log) or `enforce` (ban CIDR) |
| `LOGINMON_EXIM_SUBNET_WINDOW` | `5m` | Rolling-window duration |
| `LOGINMON_EXIM_SUBNET_UNIQUE_IPS` | `5` | Distinct-IP threshold |
| `LOGINMON_EXIM_SUBNET_MIN_TOTAL_EVENTS` | `10` | Total-event threshold (AND with unique-IPs) |
| `LOGINMON_EXIM_SUBNET_IPV4_PREFIX` | `24` | IPv4 aggregation prefix bits |
| `LOGINMON_EXIM_SUBNET_IPV6_PREFIX` | `64` | IPv6 aggregation prefix bits |
| `LOGINMON_EXIM_SUBNET_ACTION` | `ban_cidr` | Only `ban_cidr` ships in v1.113; `pressure_score` and `dynamic_threshold` reserved for v1.114+ |
| `LOGINMON_EXIM_SUBNET_CIDR_BAN_DURATION` | `24h` | CIDR ban duration (`0` = permanent) |

### False-positive guards

Six guards must ALL pass before a trigger fires:

1. **Reason filter** — only `EXIM_AUTH_FAIL` events count toward
   subnet aggregation in v1.113. Other LoginMon reasons (SSH/FTP/panel)
   are not subnet-aggregated.
2. **Dual threshold** — both the unique-IP count AND the total-event
   count must cross their respective thresholds.
3. **Rolling window** — events older than `SubnetWindow` expire;
   when the window resets, subnet state resets.
4. **Trusted-provider allowlist** — operator-curated subnets are
   exempt (Google, Microsoft, Apple, large mail-relay networks).
5. **Private/internal ranges blocked** — RFC 1918, RFC 4193,
   link-local, and loopback never aggregate.
6. **Audit logging** — every trigger writes a structured journal
   entry with subnet, unique-IP count, total event count, sample IPs,
   action taken, and the trigger IP for attribution.

### Behavior changes

- **Disabled by default.** On hosts that do not set
  `LOGINMON_EXIM_SUBNET_AGG_ENABLED=true`, the daemon `/metrics`
  surface, Status JSON wire format, ban behavior, and per-IP scoring
  path are byte-identical to v1.112.2 (`omitempty` JSON tags on the
  three new `LoginMonStatusExtra` fields suppress them when zero).
- **Observe mode.** Surfaces 3 new non-zero fields under Status.Extra
  (`subnet_pressure_count`, `subnet_bans_total`, `subnet_watch_active`)
  via `nftban status --json`. No bans issued.
- **Enforce mode.** Issues CIDR bans via the existing
  `nftban ban <CIDR>` path with reason `exim_auth_fail_subnet`,
  recorded in `/etc/nftban/blacklist.d/99-manual.conf`. The triggering
  IP is preserved in the event data `trigger_ip` field for attribution.

No other behavior change in `nftban-core` / `nftband` daemons.

### Invariants preserved

- **R-10 module-isolation** — A1 distinct `LoginMonName` const
  unchanged; A2 subnet-triggered `EventBan` publishes with the
  `LoginMonName` source; A3 stays vacuous per R-12 typed-struct.
- **R-12 typed Status.Extra** — additive growth 18→21 fields with
  `omitempty` JSON tags preserves byte-identical wire format on
  disabled-feature hosts (locked by
  `TestLoginMonStatusExtra_SubnetFields_ZeroOmitted`).
- **Module-interface** — no change to `Module.*` contracts.
- **Cross-distro** — pure `internal/loginmon/` Go change; no
  packaging, systemd, or FHS asymmetry.

### Schema status

Schema remains frozen at `1.83.0`. **No new metric names. No new label
cardinality. No schema doc edits. No allow-list mutation.** No
Prometheus emission added in v1.113.0; subnet counters surface via
`LoginMonStatusExtra` typed-struct fields only. The two candidate
Prometheus metric names `nftban_loginmon_subnet_pressure_total` +
`nftban_loginmon_subnet_bans_total` are reserved for v1.114 with an
explicit schema-unfreeze gate if/when telemetry need arises. PR-M2b-w1
host-vitals release content from v1.112.0 (6 `nftban_host_*` metrics)
continues to emit correctly via the unaltered Go daemon path.

### Verification

- Pre-merge PR #610 HEAD `ec1e7732` CI: 50 PASS / 3 fail (baseline-
  advisory triplet OSV-Scanner + 2× health) / 1 skip (Typosquat/Socket
  expected fork-skip). gosec PASS after the G115 int32 bounded-clamp
  + errcheck `fmt.Sscanf` fix commit.
- Post-merge main `35c4eb25` CI: 21 PASS / 2 fail (baseline-advisory
  doublet OSV-Scanner + Project Health = 13th consecutive ack matching
  v1.102→v1.112.2 precedent).
- All gating checks pass: Go Build & Test, all 4 RPM install distros
  (alma9 / centos-stream9 / centos-stream10 / rocky9), all 4 DEB
  install distros (debian12 / debian13 / ubuntu22.04 / ubuntu24.04),
  both Runtime Truth distros (almalinux-9 / ubuntu-24.04), CodeQL,
  Secure Go, Semgrep, ShellCheck, Bash Validation, Architecture
  Policy, all 5 Canonization Gates (Install / Update / Restore /
  Uninstall + Migration Coverage), Shell-Delete Guard, Smoke Test,
  Documentation Validation, Docker, Gitleaks, OpenSSF Scorecard, Fuzz
  Tests.

### Non-goals carried forward to v1.114+

Each item separately gated:

- **LoginMon subnet Prometheus emission**
  (`nftban_loginmon_subnet_pressure_total` +
  `nftban_loginmon_subnet_bans_total`) — reserved for v1.114
  schema-unfreeze gate if/when telemetry need arises.
- **`pressure_score` + `dynamic_threshold` action types** — reserved
  for v1.114+ (boost per-IP score for offending subnet IPs / lower
  per-IP threshold temporarily).
- **Cross-module subnet aggregation** (BotGuard / DDoS hooks) — not
  in v1.113.
- **Subnet state persistence across restart** — 5-minute window
  granularity makes persistence unnecessary in v1.113; reserved for
  v1.114 if pressure justifies.
- **LRU eviction at `MaxTracked=10000` cap** — v1.113 declines new
  prefixes when full; reserved for v1.114 if pressure justifies.
- **PR-M2b-w2..w7** per-module host-vitals emission waves (LoginMon /
  DDoS / BotGuard / Feed / Geoban / Suricata).
- **PR-M2c** new nft named counters (`ddos_drop`, `whitelist_hit`,
  `feed_hit`, `geoban_hit`) — schema-UNFREEZE.
- **PR-M2d** kernel set element annotation cookies — schema-UNFREEZE
  + migration plan.
- **PR-M3** cache v2 producer + **PR-M1** CLI formatter.
- **§F4** metrics beyond the 6 PR-M2b-w1 targets (CPU details, swap,
  inodes, IO wait, SMART, RAID, service health).
- **D-LMA-1** legacy `/opt/nftban-pro:3000` decommission decision.
- **R-11** Watchdog → BotGuard `EventSafetyPressure` contract.
- **D-DNS-1** dns2 host migration (DESIGN-FIX side OPEN).
- **D-FHS-1..5**, **D-SHA-1**, **D-POL-1**, **D-DEG-1**, **D-SEC-1**,
  **D-TRP-1**, **D-EGM-1**, **D-PNL-1**, **D-OSH-1**, **D-GHC-1**,
  **D-BKT-1** — all unchanged from v1.112.2 forward-list.

### Acceptance plan (separately gated)

`EXECUTE_V113_VALIDATE_SRV1 = GO` — enable observe mode on srv1
(which still has the 81.30.98.x attack pattern that motivated this
feature) → verify `subnet_pressure_count` increments under live
traffic → switch to enforce mode → verify CIDR ban fires for
`81.30.98.0/24` → confirm coexistence with the 5 existing manual /27
bans on srv1.

v1.113.x hotfix slot **not authorized** (latent reservation only —
opened only if a v1.113.0 defect surfaces).

---

## [v1.112.2] - 2026-05-13 — V112.2 hotfix: DEB postinst tmpfiles ordering before service activation

V112.2 single-PR packaging hotfix on top of v1.112.1. Closes a long-latent
DEB-postinst ordering defect exposed under V112.2 fresh-install validation
across the 9-VM lab fleet (`hyperv-itcms`) plus lab2 snapshot rebuild.
**Zero impact on v1.112.x release content** — the Go daemon, all exporter
scripts (including the v1.112.1 line-805 Shape A fix which stays in place),
the systemd unit files, and the FHS spec are all UNCHANGED. **Schema
1.83.0 remains frozen.** **No RPM packaging change.**

### Defect

`packaging/deb/postinst` invokes the Go installer (which triggers service
activation) BEFORE creating the runtime tree shipped via
`/usr/lib/tmpfiles.d/nftban.conf`. With `nftband.service` declaring
`ReadWritePaths=/var/cache/nftban` for systemd mount-namespace isolation,
systemd refuses the unit at namespace setup with:

```
nftband.service: Failed to set up mount namespacing:
/var/cache/nftban: No such file or directory
status=226/NAMESPACE
```

`nftban-unified-exporter.service` inherits the same failure path and
surfaces as `exit-code 2/INVALIDARGUMENT` — the SAME visible symptom that
motivated v1.112.1 PR #606, but rooted in packaging ordering rather than
shell arithmetic.

### Why v1.112.1 fix was insufficient

PR #606 line-805 Shape A arithmetic fix is a real defensive improvement
but targets a different surface (the extended-mode `live extended` code
path in `nftban_unified_exporter_collect.sh`). The actual broader
V112-class regression was this DEB-postinst ordering gap — visible from
minute one in the journal as `nftband.service 226/NAMESPACE` one layer
earlier than the unified-exporter exit=2 that V112.1 chased. PR #606
remains correctly merged at v1.112.1 as a defensive improvement and is
unrelated to this hotfix.

### Fix

Insert a tmpfiles-create call between `systemctl daemon-reload` and the
Go-installer invocation block:

```sh
if [ -f /usr/lib/tmpfiles.d/nftban.conf ]; then
    systemd-tmpfiles --create /usr/lib/tmpfiles.d/nftban.conf 2>/dev/null || true
fi
```

Idempotent (`[ -f ]` guard + redirect + `|| true` fallback). The package-
shipped tmpfiles config creates `/var/cache/nftban`, `/run/nftban`,
`/var/log/nftban`, and the rest of the runtime tree before any unit with
`ReadWritePaths=` references those paths.

### Reproduction matrix (11 hosts)

Evidence preserved at
`AUDIT_190_LIFECYCLE/V112_HOST_VITALS_EVIDENCE/v112_2_vm_fleet/`.

| Host | OS / Pkg | Reproduced exit=2? |
|---|---|---|
| lab4 | AlmaLinux 9 RPM | ❌ |
| lab2 (post snapshot rebuild) | Ubuntu 24.04 DEB | ✅ (preinst-blocked first; after manual tmpfiles + restart → 10/10 SUCCESS) |
| tgt-a9 | AlmaLinux 9 RPM | ❌ |
| tgt-r9 | Rocky 9 RPM | ❌ |
| tgt-cs9 | CentOS Stream 9 RPM | ❌ |
| tgt-a8 | AlmaLinux 8 (cross-major el9 RPM) | ❌ |
| **tgt-d11** | **Debian 11 DEB** | **✅** |
| **tgt-d12** | **Debian 12 DEB** | **✅ (r1-r3 exit=2, then 7/10 pass)** |
| **tgt-d13** | **Debian 13 DEB** | **✅ (r1-r4+ exit=2 then SUCCESS)** |
| **tgt-u2204** | **Ubuntu 22.04 DEB** | **✅ (r1-r3 exit=2, then 7/10 pass)** |
| **tgt-u2404** | **Ubuntu 24.04 DEB** | **✅ (r1-r4 exit=2 then SUCCESS)** |

5/5 RPM hosts: clean. 4/4 fresh DEB VMs: reproduced. Defect localized
to DEB postinst ordering exclusively.

### Files touched (the entire envelope)

- `packaging/deb/postinst` (+16 / -0)

No Go source changes, no schema changes, no unit files, no FHS spec,
no RPM packaging, no other generated files, no go.mod/go.sum.

### Behavior changes

- Fresh DEB installs (Debian 11/12/13 + Ubuntu 22.04/24.04) now bring
  `nftband.service` and `nftban-unified-exporter.service` up successfully
  on first activation; the manual
  `systemd-tmpfiles --create /usr/lib/tmpfiles.d/nftban.conf` workaround
  is no longer required.
- All other behavior unchanged.

**No change in Go daemon `/metrics` output. No change in receiver-v2
ingest contract. No change in schema, metric names, label cardinality,
or systemd unit hardening.**

### Why this is safe (pre-merge attestation)

Pre-merge investigation gate (`V112_2_HOTFIX_SCOPE_LOCKED.md`) reproduced
the defect on 4/4 fresh DEB VMs with per-VM before/after evidence
preserved. RPM hosts (5/5) never reproduced because RPM `%post`
scriptlet ordering already creates the runtime tree before service
activation. Manual workaround (`systemd-tmpfiles --create` +
`systemctl restart nftband.service`) demonstrated 10/10 SUCCESS on lab2
post-install, confirming tmpfiles-create is the precise remediation.
PR #608 verification gate confirmed 1-file 16-line envelope strict;
all 4 RPM install workflows (alma9 / centos-stream9 / centos-stream10 /
rocky9) and 4 DEB install workflows (debian12 / debian13 / ubuntu22.04 /
ubuntu24.04) CI checks PASS plus Runtime Truth (almalinux-9 +
ubuntu-24.04) plus package effective parity plus systemd ExecStart
payload resolution.

### Investigation lesson captured

When a systemd unit fails, ALWAYS read one journal layer earlier — the
decisive error often sits in a dependent unit. Here, `nftband.service`
`226/NAMESPACE` was visible from minute one but V112.1 chased the
downstream exporter `exit=2`. Status codes 200–255 indicate
pre-script-exec setup failure (namespace / capabilities / user / cgroup),
not script-body bugs. Documented at
`/home/gituser/.claude/projects/-home-gituser-github-nftban/memory/feedback_investigation_follow_layer_one_journal.md`.

Prevention CI guard recorded as separately-gated future debt:
`OPEN_V112_2_CI_FRESH_INSTALL_GUARD_PR` would add a CI truth case
asserting "remove `/var/cache/nftban` → install DEB → service must
start without `226/NAMESPACE`".

### Explicit non-goals carried forward to v1.113+ as separately-gated future debt

All v1.112.0 and v1.112.1 deferred items remain deferred:

- **PR-M2b-w2..w7** per-module emission waves (LoginMon, DDoS, BotGuard,
  Feed, Geoban, Suricata)
- **PR-M2c** new nft named counters — schema-unfreeze required
- **PR-M2d** kernel set element annotation cookies — schema-unfreeze +
  migration plan
- **PR-M3** cache v2 producer + **PR-M1** CLI formatter
- **§F4 metrics beyond the 6 PR-M2b-w1 targets** (CPU details, swap,
  inodes, IO wait, SMART, RAID, service health)
- **D-LMA-1** legacy `/opt/nftban-pro:3000` decommission — sibling W1
  governance lane
- **R-11** Watchdog → BotGuard `EventSafetyPressure` contract
- **D-DNS-1** dns2 host migration (DESIGN-FIX side OPEN)
- **D-FHS-1..5**, **D-SHA-1**, **D-POL-1**, **D-DEG-1**, **D-SEC-1**,
  **D-TRP-1**, **D-EGM-1**, **D-PNL-1**, **D-OSH-1**, **D-GHC-1**,
  **D-BKT-1**
- **OPEN_V112_2_CI_FRESH_INSTALL_GUARD_PR** — CI prevention guard
- **OPEN_V112_2_RPM_POST_DEFENSIVE_HOTFIX_PR** — RPM defense-in-depth
- **OPEN_V112_2_EXPORTER_INVOCATION_INVESTIGATION_RESUME** — companion
  bash-wrapped vs bare-path question

v1.112.3 hotfix slot **not authorized** (latent reservation only).

---

## [v1.112.1] - 2026-05-12 — V112.1 hotfix: unified-exporter arithmetic syntax error on EL9 + Ubuntu

V112.1 single-PR hotfix on top of v1.112.0. Closes a v1.112.0-released
regression in the `nftban-unified-exporter.service` shell exporter that
surfaced under post-release host-vitals validation. **Zero impact on
v1.112.0 host-vitals release content** — the Go daemon `/metrics`
continues to emit all 6 `nftban_host_*` metrics correctly on every
validated host; the hotfix touches the shell-exporter side only.
**Schema 1.83.0 remains frozen.**

### Defect

`cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh:805`:

```bash
sets_count=$(( $(nft list sets "$ipv4_family" 2>/dev/null \
                  | grep -c "set " || echo 0) + ... ))
```

When `nft list sets` returns no `"set "` matches:

1. `grep -c "set "` outputs `"0"` AND exits **1** (no matches per GNU
   grep semantics)
2. `|| echo 0` fallback then outputs **another** `"0"`
3. Combined captured stdout is `"0\n0"`
4. `$(( "0\n0" + ... ))` is a bash arithmetic syntax error
5. Under `set -Eeuo pipefail` bash exits with code 2; systemd reports
   `INVALIDARGUMENT` and the entire exporter run fails

Manifests reliably under `groups: live extended` invocation in
restricted systemd context (`User=nftban` + `ProtectSystem=strict` +
`CAP_NET_ADMIN` + `RestrictAddressFamilies` + `LockPersonality`).
Intermittent under `groups: live` only. Manual root invocation
succeeds (different env state). EL10 hosts (srv4) were unaffected
because the timer fires when nft tables are already populated and the
`grep -c` matches at least one set, avoiding the dual-zero output.

Cross-distro defect matrix (from V112 validation gates):

- lab2 (Ubuntu 24.04, DEB): extended-fail
- lab4 (AlmaLinux 9, RPM): extended-fail (root-cause line identified
  via `bash -x` trace under systemd; leave-no-trace cleanup verified)
- srv4 (AlmaLinux 10.1, RPM): all runs succeed including
  `live extended` (newer toolchain timing)

### Fix (Shape A defensive wrapping)

Split the compound arithmetic into separate command-substitutions
with `|| _var=0` assignment-level fallback plus `[[ =~ ^[0-9]+$ ]]`
numeric-validation guard plus safe two-operand arithmetic. The
dual-output pattern cannot occur:

```bash
local _v4_sets _v6_sets
_v4_sets=$(nft list sets "$ipv4_family" 2>/dev/null \
            | grep -c "set " 2>/dev/null) || _v4_sets=0
_v6_sets=$(nft list sets "$ipv6_family" 2>/dev/null \
            | grep -c "set " 2>/dev/null) || _v6_sets=0
[[ "$_v4_sets" =~ ^[0-9]+$ ]] || _v4_sets=0
[[ "$_v6_sets" =~ ^[0-9]+$ ]] || _v6_sets=0
sets_count=$((_v4_sets + _v6_sets))
```

### Files touched

- `cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh`
  (+14 / -1)

That is the entire envelope. The Go daemon, all other exporter
scripts (`nftban_unified_exporter.sh` loader + `_helpers.sh` +
`_export.sh`), the systemd unit file, the timer file, and the FHS
spec are all UNCHANGED.

### Primary Item

**PR #606 — `fix(exporter): nftban_nft_sets_total arithmetic syntax
error (v1.112.1 hotfix)`** (squash `5d4e9613`). 1 file (+14/-1).

### Behavior changes

- `nftban-unified-exporter.service` no longer fails with
  `exit-code 2/INVALIDARGUMENT` under `live extended` invocation on
  EL9 + Ubuntu hosts when nft sets are empty.
- All other exporter behavior unchanged.

**No change in Go daemon `/metrics` output.** **No change in receiver-v2
ingest contract.** **No change in schema, metric names, label
cardinality, or systemd unit hardening.**

### Why this is safe

Pre-merge investigation gate (`V112_1_HOTFIX_PR_B_SCOPE.md`)
identified the exact failing line via `bash -x` trace under systemd
on lab4 with leave-no-trace cleanup (drop-in removed; unit restored
to packaged baseline; run #166 post-cleanup SUCCESS confirms healthy
state). Shape A fix locked at scope §3. PR #606 verification gate
(8-criterion) confirmed 1-file 14-line envelope strict; all RPM
install (alma9 / rocky9 / centos-stream9 / centos-stream10) and DEB
install (debian12 / debian13 / ubuntu22.04 / ubuntu24.04) CI checks
PASS. Local bash reproduction confirmed both the bug (arithmetic
syntax error on `"0\n0"`) and the fix (correct sum for empty +
matched inputs). End-to-end re-validation on lab4 reproducible host
deferred to `EXECUTE_V112_1_VALIDATE_LAB4` post-release gate.

### Explicit non-goals carried forward to v1.113+ as separately-gated future debt

All v1.112.0 deferred items remain deferred:

- **PR-M2b-w2..w7** per-module emission waves (LoginMon, DDoS,
  BotGuard, Feed, Geoban, Suricata)
- **PR-M2c new nft named counters** — schema-unfreeze required
- **PR-M2d kernel set element annotation cookies** — schema-unfreeze
  + migration plan
- **PR-M3** cache v2 producer + **PR-M1** CLI formatter
- **§F4 metrics beyond the 6 PR-M2b-w1 targets** (CPU details, swap,
  inodes, IO wait, SMART, RAID, service health)
- **D-LMA-1** legacy `/opt/nftban-pro:3000` decommission — sibling
  W1 governance lane
- **R-11** Watchdog → BotGuard `EventSafetyPressure` contract
- **D-DNS-1** dns2 host migration (DESIGN-FIX side OPEN)
- **D-FHS-1..5**, **D-SHA-1**, **D-POL-1**, **D-DEG-1**, **D-SEC-1**,
  **D-TRP-1**, **D-EGM-1**, **D-PNL-1**, **D-OSH-1**, **D-GHC-1**,
  **D-BKT-1**

v1.112.2 hotfix slot **not authorized** (latent reservation only —
opened only if a v1.112.1 defect surfaces).

---

## [v1.112.0] - 2026-05-12 — V112 PR-B schema-fulfill: PR-M2b-w1 host-vitals emission

V112 PR-B schema-fulfill lane on top of v1.111.0. Single-PR release closing
the PR-M2b-w1 host-vitals emission gap by implementing 6 metric names
already declared in schema doc 17 §F4 + already accepted in the
receiver-v2 181-entry allow-list since v1.111.0 publish. **Schema 1.83.0
frozen invariant remains intact** per operator contract-fulfill
interpretation locked at `V112_CONTRACT_FULFILL_ATTESTATION.md` —
implementing already-declared schema names is fulfillment, not schema
mutation.

### Goals

Close the highest-value schema-fulfillment sub-item from the D-MET-1
portal-evidence checklist, deferred from v1.111 per PR-A scope §4
friction point 1:

- **PR-M2b-w1** — emit 6 `nftban_host_*` Prometheus metrics that have
  been part of the frozen schema contract since v1.90 + accepted by the
  consumer-side allow-list since v1.111.0, but which the daemon was not
  previously producing.

Conservative scope: only the 6 PR-M2b-w1 targets emit. Other §F4 metrics
(CPU details, swap, inodes, IO wait, SMART, RAID, service health) remain
deferred to future per-section PR-M2b sub-items.

### Primary Item

**PR #604 — `fix(watchdog): emit nftban_host_* vitals per schema doc 17
§F4 (PR-M2b-w1)`** (squash `1d0a6221`). 5 files (+592/-2).

### Metrics emitted

| Metric | Type | Labels | Source |
|---|---|---|---|
| `nftban_host_load_average` | GaugeVec | `window` (1m/5m/15m) | `/proc/loadavg` |
| `nftban_host_memory_total_bytes` | Gauge | — | `/proc/meminfo` MemTotal |
| `nftban_host_memory_available_bytes` | Gauge | — | `/proc/meminfo` MemAvailable |
| `nftban_host_memory_used_bytes` | Gauge | — | derived (MemTotal − MemAvailable) |
| `nftban_host_disk_usage_ratio` | GaugeVec | `mount`, `device`, `fstype` | `syscall.Statfs()` + `/proc/self/mountinfo` |
| `nftban_host_oom_events_total` | Counter | — | `/proc/vmstat oom_kill` (per-tick delta) |

**Cardinality bound:** ~11 series per host under the default mount
policy (3 load_average windows + 3 plain memory gauges + ~4 disk mounts
+ 1 OOM counter).

### Architecture decision (locked at PR-B scope)

This release is an **EXTENSION of the existing `SystemCollector`** in
`internal/watchdog/collector_system.go` — not a new `collector_host.go`.
The PR-B daemon-source audit found that `SystemCollector` already reads
`/proc/loadavg`, `/proc/meminfo`, `/proc/stat`, and uses
`syscall.Statfs()`; `SystemMetrics` already exposes `LoadAvg1/5/15`,
`MemTotal`, `MemAvail`, etc. PR-M2b-w1 adds two new collector functions
(`collectOOMEvents` reads `/proc/vmstat`; `collectMultiMountDisks` per
mount-policy allowlist plus `readMountInfo` parses
`/proc/self/mountinfo` for device + fstype) and 6 new `promauto.New*`
blocks in `metrics.go`.

**`Watchdog` struct, `internal/watchdog/config.go`, and
`internal/watchdog/collector_base.go` remain UNCHANGED** — no
struct/interface churn.

### Files touched (strict envelope, locked at PR-B scope gate)

- `internal/watchdog/types.go` (+18/-2): `SystemMetrics` extended with
  `Disks []DiskUsageEntry` + `OOMEvents uint64` (both `omitempty` for
  byte-identical zero-value JSON output); NEW `DiskUsageEntry{Mount,
  Device, FSType string; Ratio float64}`
- `internal/watchdog/collector_system.go` (+147): NEW
  `collectOOMEvents()`, `collectMultiMountDisks()`,
  `hostDiskMountAllowlist()` env helper, `readMountInfo()` parser,
  `defaultHostDiskMounts` var; wired into existing `Collect()` body
- `internal/watchdog/metrics.go` (+65): 6 new `promauto.New*` blocks;
  new `lastOOMEvents uint64` field on `MetricsExporter` for
  counter-delta semantics; new emission section in `Update()` pump with
  memory-underflow guard
- `internal/watchdog/collector_system_test.go` (NEW, +239): 11 tests
  covering mount-policy default/env/whitespace + multi-mount
  root-always/nonexistent-skipped/cardinality-bound + OOM events +
  `Collect()` integration + mountinfo parser
- `internal/watchdog/metrics_test.go` (+125): 5 tests covering
  host-vitals emission + OOM counter delta + OOM monotonic-down
  regression guard + multi-mount loop + memory underflow guard

### Behavior changes (narrow, explicit)

- 6 `nftban_host_*` Prometheus metrics now emit values in production
  when the watchdog ticks (default cadence 5 seconds per
  `WatchdogSystemInterval`). The receiver-v2 has been ready to accept
  these names since the M-T9 cutover on 2026-05-02; this release
  fulfills the daemon side.
- Cardinality is bounded ~11 series per host under default mount policy.
- OOM counter uses per-tick delta semantics (Prometheus Counter is
  Add-only). Counter regression (kernel reset or host change) is
  handled by resyncing baseline without crashing.

**No other behavior change in `nftban-core` / `nftband` daemons.** No
new metric names beyond schema doc 17 §F4. No new label cardinality
dimensions. No schema/contract changes. No portal, install API,
panel-adapter, FHS-ATG, Self-Healing, POLKIT-AUTHORITY, dns2-migration,
eventbus, packaging, or systemd changes.

### Mount policy

Per schema doc 17 §F4.3.1:

- Default 4 mounts: `/`, `/var`, `/var/log`, `/var/lib/nftban` (3 from
  doc + nftban-FHS-specific addition)
- Operator override:
  `NFTBAN_HOST_DISK_MOUNT_ALLOWLIST=/data,/mnt/storage`
  (comma-separated)
- Mounts that fail `statfs` are skipped silently (unmounted / permission
  denied)
- Device + FSType resolved from `/proc/self/mountinfo`; fallback to
  `"unknown"` if not resolvable

### Kernel compatibility

All supported distros (EL9/10, Debian 12/13, Ubuntu 22.04/24.04) ship
kernel ≥5.14, well above the 4.7 `oom_kill` threshold and 3.14
`MemAvailable` threshold. Fallbacks are documented in PR-B scope but
unlikely to trigger.

### Why this is safe (7-axis prerequisite check)

1. **R-10 module-isolation lint SAFE** — watchdog is not a Module
2. **R-12 typed `Status().Extra` SAFE** — same reason
3. **JSON wire-format SAFE** — new `SystemMetrics` fields use
   `omitempty`; zero-value output is byte-identical
4. **`SystemCollector` mutex pattern READY** — new helpers inherit
   `c.mu` from `Collect()` body
5. **Config-loader NO change** — reuses `SystemInterval` (5s default)
6. **No `internal/contracts/` directory exists** — no metric-inventory
   CI gate to update
7. **`ci-architecture.yml` SAFE** — runs R-10 lint only; does not lint
   metric registrations

### Explicit non-goals carried forward to v1.113+ as separately-gated future debt

- **PR-M2b-w2..w7** per-module emission waves (LoginMon, DDoS,
  BotGuard, Feed, Geoban, Suricata) — per-wave gating recommended
- **PR-M2c new nft named counters** (`ddos_drop`, `whitelist_hit`,
  `feed_hit`, `geoban_hit`) — true schema-UNFREEZE; requires
  `OPEN-V1XX-SCHEMA-UNFREEZE-NFT-NAMED-COUNTERS-SCOPE`
- **PR-M2d kernel set element annotation cookies** — schema-UNFREEZE +
  migration plan; requires
  `OPEN-V1XX-SCHEMA-UNFREEZE-SET-ELEMENT-FORMAT-SCOPE`
- **PR-M3** cache v2 producer + **PR-M1** CLI formatter — depend on
  PR-M2/PR-M3 sequence
- **§F4 metrics beyond the 6 PR-M2b-w1 targets** (CPU details, swap,
  inodes, IO wait, SMART, RAID, service health) — future PR-M2b
  sub-items
- **D-LMA-1** legacy `/opt/nftban-pro:3000` decommission — sibling W1
  governance lane; observation window OPEN since 2026-05-02 M-T9
  cutover
- **R-11** Watchdog → BotGuard `EventSafetyPressure` contract
- **D-DNS-1** dns2 host migration (DESIGN-FIX side OPEN)
- **D-FHS-1..5**, **D-SHA-1**, **D-POL-1**, **D-DEG-1**, **D-SEC-1**,
  **D-TRP-1**, **D-EGM-1**, **D-PNL-1**, **D-OSH-1**, **D-GHC-1**,
  **D-BKT-1** — all long-deferred carry-forward debt

v1.112.x hotfix slot **not authorized** (latent reservation only —
opened only if a v1.112.0 defect surfaces).

---

## [v1.111.0] - 2026-05-12 — V111 PR-A conservative: D-METR-2 watchdog emission gap fix

V111 PR-A conservative lane on top of v1.110.0. Closes D-METR-2 (watchdog
`nftban_watchdog_action_total` emission gap) via a single focused PR.
**Schema remains frozen at `1.83.0`.** **No new metric names, no new metric
registrations, no schema or contract changes.** Behavior change confined to
two already-registered watchdog Prometheus counters now actually advancing
in production when watchdog actions fire (previously registered via
`promauto` at package init but never incremented because the production
action-fire path did not invoke the Prometheus emission method).

### Goals

Close the single highest-value frozen-safe sub-item from the D-MET-1 portal-
evidence checklist surfaced in `V111_METRICS_PORTAL_SCOPE_PREFLIGHT.md`:

- **D-METR-2** — fix the orphaned `MetricsExporter.RecordAction` so that
  `nftban_watchdog_action_total{action=...}` and
  `nftban_watchdog_last_action_timestamp_seconds{action=...}` actually
  increment in production.

Conservative path deliberately chosen per PR-A scope artifact §4 friction
analysis: PR-M2b-w1 host-vitals registration was deferred to v1.112 to
avoid the "new metric registration" interpretation ambiguity (the 6
host-vitals metric names are pre-declared in schema doc 17 §F4 and
pre-accepted in the receiver-v2 181-entry allow-list, but implementing
them requires new `promauto.New*` calls that need an explicit operator
contract-fulfill judgment on a future schema-fulfill gate
`OPEN-V112-SCHEMA-FULFILL-HOST-VITALS-SCOPE`).

### Primary Item

**PR #602 — `fix(watchdog): wire MetricsExporter.RecordAction via SetOnAction
callback` (D-METR-2)** (squash `7334e63e`). 4 files (+267/-0).

Fix mirrors the existing `onMetrics`/`SetOnMetrics` callback pattern (used
for per-tick metrics pump) with a parallel `onAction`/`SetOnAction` hook
(for action-fire events), then wires the daemon side in
`cmd/nftband/daemon_init.go` immediately after the existing `SetOnMetrics`
block:

```go
wd.SetOnAction(func(action watchdog.Action) {
    d.wdMetrics.RecordAction(action)
})
```

Root cause was a clean orphaned-method gap discovered during the PR-A
daemon-source audit: `MetricsExporter.RecordAction(action)` at
`internal/watchdog/metrics.go:366-369` had been defined since the watchdog
metrics package was created, but no production caller ever invoked it.
`Watchdog.handleAction()` at `internal/watchdog/watchdog.go:317-325`
dispatched only to the in-memory flight recorder (`Recorder.RecordAction`
at `internal/watchdog/flight_recorder.go:98`), never to the Prometheus
exporter — so both counter metrics appeared in `/metrics` output at zero
value forever, even when the watchdog was actively taking actions.

**Files touched (strict envelope, locked at PR-A scope gate):**

- `internal/watchdog/watchdog.go` (+17): `onAction func(Action)` field
  added to `Watchdog` struct alongside `onMetrics`; new `SetOnAction(cb)`
  setter mirrors `SetOnMetrics` exactly (same `mu.Lock`/`defer Unlock`
  pattern); `handleAction()` now captures `cb := w.onAction` under
  `RLock`, releases, then calls `cb(action)` if non-nil (race-safe
  release-before-call pattern).
- `cmd/nftband/daemon_init.go` (+7): `wd.SetOnAction(...)` block inserted
  after the `SetOnMetrics` closure at line 415, with a 3-line comment
  citing D-METR-2.
- `internal/watchdog/metrics_test.go` (NEW, +194): 5 tests covering the
  full contract — `TestSetOnAction_NilSafe`, `TestSetOnAction_Fires`,
  `TestSetOnAction_Replace`, `TestSetOnAction_ConcurrentSetAndDispatch`
  (race coverage of the `mu.Lock` pattern under `-race`), and
  `TestMetricsExporter_RecordAction_Smoke` (verifies the previously
  orphaned `RecordAction` is callable for all 7 documented `ActionType`
  values: `throttle`, `disable_optional`, `profile_cpu`, `profile_heap`,
  `profile_goroutine`, `free_os_memory`, `degrade_mode`).
- `internal/watchdog/executor_test.go` (+49): `TestActionExecutor_FiresWatchdogOnAction`
  end-to-end chain regression — constructs a full `Watchdog`, sets a
  test `onAction` callback via `SetOnAction`, then invokes
  `w.executor.recordAction(action)` to verify the full production chain
  (executor → `handleAction` via `SetOnAction(w.handleAction)` at
  `watchdog.go:105` → `w.onAction`) fires exactly once with the correct
  `Action` payload.

### Behavior changes (narrow, explicit)

- **`nftban_watchdog_action_total{action=...}`** now emits non-zero counter
  values in production when the watchdog executes actions. Previously
  registered but always zero.
- **`nftban_watchdog_last_action_timestamp_seconds{action=...}`** now emits
  Unix timestamps when actions fire. Previously registered but always
  zero.

Both metric names were already in the schema 1.83.0 frozen contract set
at v1.110.0; this release only makes their emission paths reach the
Prometheus default registry in production.

**No other behavior change in `nftban-core` / `nftband` daemons.** No new
metric names. No new metric registrations. No schema or contract changes.
No portal, install API, panel-adapter, FHS-ATG, Self-Healing,
POLKIT-AUTHORITY, dns2-migration, eventbus, packaging, or systemd
changes.

### Why this is safe

Pre-merge **PR-A daemon-source scope audit**
(`V111_METRICS_PORTAL_PR_A_SCOPE.md`) answered 10 locked questions with
file:line evidence. Pre-merge **PR-A prerequisite check**
(`V111_PR_A_PREREQUISITE_CHECK.md`) verified 7 invariant axes:

1. **R-10 module-isolation lint SAFE** — `scripts/lint-module-isolation.sh`
   autodiscovers Module implementers via `func (m *Module) Name() string`;
   watchdog has zero hits (it is a subsystem coordinator, not the
   `module.Module` interface). A1/A2/A3 invariants do not apply.
2. **R-12 typed `Status().Extra` SAFE** — only applies to the 4 Module
   implementers (`ddos`, `portscan`, `loginmon`, `botguard` per v1.110.0
   PR #600); watchdog has no `Status() module.Status` method.
3. **Watchdog struct READY** — existing `onMetrics`/`SetOnMetrics`
   callback pattern (per-tick pump, daemon wires via
   `cmd/nftband/daemon_init.go:387-388`) is directly mirrorable.
4. **ActionExecutor already wired** — `executor.go:43-59` defines
   `onAction func(Action)` + `SetOnAction(cb)`; `watchdog.go:105` calls
   `w.executor.SetOnAction(w.handleAction)`. The bug was one missing
   hop: `handleAction` never bridged to `d.wdMetrics.RecordAction`.
5. **Config-loader NO change** — watchdog config (`config.go:77-79`) has
   only `ProcessInterval`/`SystemInterval`/`KernelInterval`; no action
   or host-vitals keys touched.
6. **No `internal/contracts/` directory exists**; no nftban-core
   metric-inventory CI gate to update.
7. **`ci-architecture.yml`** runs the R-10 lint only; does not lint
   metric registrations.

Master worklog cross-check confirmed no blocker: receiver-v2 PR-M4
enforcement was already DONE + LIVE in production since the M-T9 cutover
2026-05-02 (per `nftbanpro_cms/docs/CURRENT_STATE.md` 2026-05-03 update +
direct receiver-v2 source inspection); v1.111 PR-A was the only
outstanding nftban-core deliverable required to close the watchdog
emission half of D-METR-2.

### Explicit non-goals carried forward to v1.112+ as separately-gated future debt

- **PR-M2b-w1 host vitals emission** — DEFERRED to v1.112 schema-fulfill
  gate. Requires 6 new `promauto.New*` registrations for
  `nftban_host_load_average`, `nftban_host_memory_{total,used,available}_bytes`,
  `nftban_host_disk_usage_ratio`, `nftban_host_oom_events_total`. Names
  already in schema doc 17 §F4 + receiver-v2 181-entry allow-list, but
  the "new metric registration" interpretation ambiguity requires
  explicit operator authorization. Proposed gate
  `OPEN-V112-SCHEMA-FULFILL-HOST-VITALS-SCOPE`. Estimated envelope
  ~200-300 LOC including new `internal/watchdog/collector_host.go`.
- **PR-M2c new nft named counters** (`ddos_drop`, `whitelist_hit`,
  `feed_hit`, `geoban_hit`) — CROSSES freeze; requires schema-unfreeze
  gate.
- **PR-M2d kernel set element annotation cookies** — CROSSES freeze;
  requires schema-unfreeze gate plus migration plan for existing set
  elements.
- **PR-M2b-w2..w7** — 6 module-emission waves (LoginMon, DDoS, BotGuard,
  Feed, Geoban, Suricata); per-wave gating recommended once
  PR-M2b-w1 lands cleanly.
- **PR-M3** cache v2 producer (depends on PR-M2 cache reorganization);
  **PR-M1** CLI formatter (depends on PR-M3). Both deferred to v1.112+.
- **D-LMA-1** legacy `/opt/nftban-pro:3000` decommission decision —
  sibling W1 governance lane; observation window OPEN since 2026-05-02
  M-T9 cutover (~10+ days mature). Separable from v1.111.0 release
  timing.
- **R-11** Watchdog → BotGuard `EventSafetyPressure` contract — explicitly
  deferred from V110 moderate cut.
- **D-DNS-1** dns2 host migration execution — PARTIALLY FIXED (BUG side
  closed in v1.108.0 PR #592; DESIGN-FIX side still OPEN).
- **D-FHS-1..5** FHS Authority Graph; **D-SHA-1**
  SELF-HEALING-AUTHORITY-REDESIGN; **D-POL-1** POLKIT-AUTHORITY impl
  decisions; **D-DEG-1** V108 Item 4 DEGRADED-runtime-pattern
  investigation; **D-SEC-1** SEC-FW-BYPASS-ALERT-GAP-001; **D-TRP-1**
  TRANSPORT-001; **D-EGM-1** EgressMon (CONDITIONAL GO
  post-CVE-2026-41940); **D-PNL-1** Panel architecture consolidation;
  **D-OSH-1** OS hardening blueprint; **D-GHC-1** optional GHCR `sha-*`
  retention policy; **D-BKT-1** Bucket C 14 v0.x tag historical-review
  (remote untouched).

v1.111.x hotfix slot **not authorized** (latent reservation only —
opened only if a v1.111.0 defect surfaces).

---

## [v1.110.0] - 2026-05-12 — V110 module-isolation moderate-cut lane

V110 module-isolation lane on top of v1.109.0. Closes R-10 and R-12
from `AUDIT_190_MODULE_ISOLATION/REMEDIATION_PLAN.md` per the V110
moderate cut (R-11 explicitly deferred to a future gate).

**No daemon behavior change. No code change in `nftban-core` /
`nftband` daemons.** Schema remains frozen at `1.83.0`. No metrics,
portal, install API, panel-adapter, FHS-ATG, Self-Healing,
POLKIT-AUTHORITY, dns2-migration, eventbus, packaging, or systemd
implementation changes.

### Goals

Close two long-standing module-isolation findings via the narrow lane
discipline that V108/V109 proved out:

1. **R-10** — formalize the module-isolation invariants as a CI gate.
   Three rules: distinct `ModuleName` across registered Module
   implementers, module-owned `source` label on every `EventBan`
   publish, and `Status().Extra` cross-module key isolation
   (baseline-allowlist current shared concepts; block NEW collisions).
2. **R-12** — replace ad-hoc `map[string]any` writes to `Status().Extra`
   with a typed `<Module>StatusExtra` struct per module. Preserve the
   `Module.Status() Status` interface byte-for-byte. Preserve all JSON
   wire keys byte-for-byte. Type-system supersedes runtime lint for
   within-module key validity.

### Primary Items

**PR #599 — R-10 module-isolation invariant lint** (squash `c8050d9e`).
2 files (+280/-0): new `scripts/lint-module-isolation.sh` (236 LOC,
shellcheck-clean, executable) plus a `V110 R-10: module isolation
lint` step inserted into `.github/workflows/ci-architecture.yml`
after the V108 Item 3 heredoc-safety step. Three invariants:

- **A1** Distinct `ModuleName` — auto-discovers Module implementers
  via `func (m *Module) Name() string`; verifies each declares a
  unique package-level `ModuleName` const. At v1.109.0 base HEAD:
  4 distinct (`ddos`, `portscan`, `loginmon`, `botguard`).
- **A2** EventBan source label — every `eventbus.NewEvent(eventbus.
  EventBan, <arg>)` publish in module code must pass the module's own
  `ModuleName` const. Rejects cross-attribution and string-literal
  sources.
- **A3** `Status().Extra` cross-module key isolation — locks the
  current baseline (`mode`, `suricata_available`, `tracked_ips` —
  confirmed intentional shared concepts at v1.109.0 HEAD) and blocks
  NEW cross-module key introductions. Future shared keys require
  deliberate `BASELINE_ALLOWLIST` update.

The PR landed via a brief history rewrite to clean a Gitleaks regex
false-positive on the literal phrase `key isolation ===` in an A3
section header (renamed to `cross-module check`); the squash-merge
commit contains only the final clean text.

**PR #600 — R-12 typed `Status().Extra` per module** (squash
`9e26d2d6`). 8 files (+433/-41): 4 production refactors (`ddos`,
`portscan`, `loginmon`, `botguard`) plus 4 test files (3 new + 1
extended). Each module gains a `<Module>StatusExtra` struct and a
`ToExtraInfo() module.ExtraInfo` method that builds the map manually
(no reflection, no JSON-marshal roundtrip). Field counts:
`DDoSStatusExtra` 2, `PortscanStatusExtra` 3, `LoginMonStatusExtra`
18 (including `string` + `map[string]int64` value types),
`BotGuardStatusExtra` 16.

A minimal post-CI fix corrected two preflight-inferred type
mismatches in `LoginMonStatusExtra`: `Services []string` →
`Services string` (matches the actual return type of
`m.getServiceList()` which is comma-joined; this also preserves the
existing JSON wire format `"services": "..."` byte-for-byte), and
`TrackedIPs int64` → `TrackedIPs int` (matches `m.scorer.TrackedIPs()`
return type). The fix landed as the second commit on the PR; both
commits squashed cleanly into `9e26d2d6` at merge time.

### Behavior changes

**None.** R-10 is a CI-only invariant gate. R-12 is a module-internal
refactor with no external API change. The `Module.Status()` interface
contract is preserved byte-identical: `Status.Extra` is still
`ExtraInfo`, `ExtraInfo` is still `map[string]any`, and JSON wire keys
(snake_case via struct tags) are unchanged.

After R-12, R-10's A3 lint becomes vacuous (0 direct `Extra[KEY] =`
writes remain in any module dir; the type system supersedes the
runtime grep for within-module key validity). R-10 A1 and A2 remain
active and continue to enforce their invariants.

### Workspace-only (not repo payload)

- **W1 MASTER_TODO refresh** — `V1.80_ROADMAP/MASTER_TODO.md`
  (workspace doc) MAY be refreshed in parallel to bring it current
  through v1.110.0 in-progress state. Not bundled here; not a repo
  release artifact.

### Out of scope (explicit non-goals carried forward to v1.111+)

- **R-11** Watchdog → BotGuard `EventSafetyPressure` contract —
  deferred per the moderate-cut authorization. Eventbus infrastructure
  is already present from PR-26 era; the SafetyPressure topic + producer
  + consumer wiring estimated at ~200-300 LOC. Available via separate
  `OPEN-V1XX-WATCHDOG-BOTGUARD-EVENTBUS-CONTRACT-SCOPE` gate.
- **D-MET-1** Metrics + Portal Contract Enforcement Lane — 18 active
  M-T TODOs; producer of v1.112+ portal/pro.nftban.com design evidence.
- **D-METR-2** Watchdog `nftban_watchdog_action_total` emission gap
  (sub-item of D-MET-1; concrete BUG).
- **D-DNS-1** dns2 host migration execution — PARTIALLY FIXED. BUG
  side closed in v1.108.0 PR #592; DESIGN-FIX side OPEN. dns2 host
  still source-installed at v1.98.2 and reports `Install type: unknown`.
  Migration scope ready (Option C: manual uninstall + RPM install);
  requires P1-P8 operator attestations.
- **D-FHS-1..5** FHS Authority Graph (5 verified gaps).
- **D-SHA-1** SELF-HEALING-AUTHORITY-REDESIGN (post-v1.108.0
  reservation MET).
- **D-POL-1** POLKIT-AUTHORITY impl-level decisions.
- **D-DEG-1** V108 Item 4 DEGRADED-runtime-pattern investigation.
- **D-SEC-1** SEC-FW-BYPASS-ALERT-GAP-001 security backlog.
- **D-TRP-1** TRANSPORT-001 outbound transport adapter.
- **D-EGM-1** V1.1XX EgressMon module (CONDITIONAL GO post-CVE-
  2026-41940).
- **D-PNL-1** Panel architecture consolidation (4 deferred adapters).
- **D-OSH-1** OS hardening blueprint SELinux/AppArmor.
- **D-GHC-1** Optional org-level GHCR `sha-*` retention policy.
- **D-BKT-1** Bucket C 14 v0.x tag historical-review (remote
  untouched).
- v1.110.x hotfix slot **not authorized** (latent reservation only).

### Scope

10 files changed since v1.109.0 (excluding this release-prep), plus
4 files in this release-prep: `VERSION` (1.109.0 → 1.110.0),
`STATUS.md` (v1.110.0 release lane added; v1.109.0 demoted to first
Prior; schema-status line updated), `CHANGELOG.md` (this block
prepended), and auto-regenerated
`cli/lib/nftban/core/nftban_fhs_spec.sh` (version banner refresh).

---

## [v1.109.0] - 2026-05-12 — V109 narrow-governance lane

V109 narrow-governance lane on top of v1.108.0. Closes the 6-item
narrow cleanup scope: stale docs/comment residue + dead-code deletion +
README package-matrix restoration + Dependabot dependency refresh.

**No daemon behavior change. No code change in `nftban-core` /
`nftband` daemons.** Schema remains frozen at `1.83.0`. No metrics,
portal, install API, panel-adapter, FHS-ATG, Self-Healing,
POLKIT-AUTHORITY, dns2-migration, or module-isolation implementation
changes.

### Goals

Clear V109 narrow-governance debt items that accumulated through the
v1.107.x / v1.108.0 cycle and were intentionally deferred until after
v1.108.0 publication:

1. **CF-13 + CF-14** — finish documentation-side decommissioning of the
   legacy `nftban-api-server` / `nftban-api.service` surface that was
   already removed from the codebase but left residual references in
   four docs/workflow files.
2. **CF-12** — remove the orphaned `internal/config` package (legacy
   JWT-secret bootstrap from the `nftban-api-server` era) with zero
   importers in the codebase.
3. **CF-04** — restore the README tier 0/1/2 package matrix that was
   inadvertently removed in PR #399 (2026-04-15), and fix a latent
   defect where Debian 12 users were instructed to install the Ubuntu
   24.04 package.
4. **CF-05** — refresh five parked Dependabot PRs (one Go-module bump
   + four GitHub Actions version bumps including three major version
   advances).

### Primary Items

**PR #596 — `nftban-api-server` / `nftban-api.service` documentation
decommissioning** (squash `46847717`). 4 files modified
(+3/−7): `CONTRIBUTING.md` directory-tree connector fix;
`.github/workflows/release.yml` comment-only edit dropping
`nftban-api-server` from the Go-binary build list;
`docs/systemd/TIMERS.md` HISTORICAL_KEEP strikethrough on the
`nftban-api.service` row with annotation pointing to
`docs/systemd/UNITS.md`; `docs/ARCHITECTURE.md` removal of the
deprecated "Optional Services" block from the ASCII art (strikethrough
does not render inside fenced code blocks; canonical history record
preserved at `docs/systemd/UNITS.md:103`). The four packaging
deprecated-service cleanup snippets in `install/packaging/{deb,rpm}/`
that reference `nftban-api.service` are **intentionally preserved** —
they remain the upgrade-time mechanism that removes stale
`nftban-api.service` from older installations.

**PR #597 — Unused `internal/config` package deletion** (squash
`787558f7`). 1 file deleted (−247 lines): `internal/config/config.go`
(legacy JWT-secret bootstrap code from the `nftban-api-server` era).
Zero-importer pre-verified across `*.go`, `*_test.go`, and
build-tag-gated files. `internal/configloader/` is a distinct package
and is **not** touched. Local Go validation not run on this host per
build policy; CI build-packages matrix validated Go compilation across
all 6 distros (RPM EL9/EL10, DEB Debian 12/13, Ubuntu 22.04/24.04).

**PR #586 — README tier 0/1/2 package matrix restoration** (squash
`a3293ff1`). 1 file modified (+51/−3): `README.md`. Adds explicit
per-distro install blocks for **Tier 0** (Ubuntu 24.04 LTS, Debian 12,
Rocky/Alma/RHEL 9), **Tier 1** (Debian 13, Rocky/Alma/RHEL 10), and
**Tier 2** (Ubuntu 22.04 LTS). Adds the full `## Available Packages`
matrix covering all 6 published RPM/DEB packages. Restores coverage
removed in PR #399 (2026-04-15). Fixes a latent defect in the previous
combined "Ubuntu 24.04 / Debian 12" heading that directed Debian 12
users to install the Ubuntu 24.04 `.deb` package.

**PR #497 — `aquasecurity/trivy-action` SHA-pin bump** (squash
`57ba0f4f`). 1 file modified (+1/−1): `.github/workflows/secure-go.yml`.
SHA pin updated `e368e328` → `ed142fd0` per supply-chain best-practice
SHA-pinning pattern.

**PR #578 — `actions/dependency-review-action` v4.9.0 → v5.0.0**
(squash `29353171`). 1 file modified (+1/−1):
`.github/workflows/dependency-review.yml`. Major version bump.
Dependency Review check verified SUCCESS under v5 in the PR's own CI
before merge.

**PR #495 — `actions/setup-node` v4.4.0 → v6.4.0** (squash
`232e2dc4`). 1 file modified (+1/−1):
`.github/workflows/project-health.yml`. Two-major-version bump.
`project-health.yml` is a scheduled non-gating advisory workflow.

**PR #577 — `github/codeql-action` v3.32.3 → v4.35.4** (squash
`bd4727ec`). 5 workflows updated (+8/−8): `codeql.yml`,
`osv-scanner.yml`, `scorecard.yml`, `secure-go.yml`, `semgrep.yml`.
`github/codeql-action` is the SARIF uploader used across five security
workflows. Major version bump. CodeQL Analysis (Go) verified SUCCESS
under v4 in the PR's own CI before merge.

**PR #535 — Go modules bump** (squash `267b02b8`). 2 files modified
(+6/−6): `go.mod` + `go.sum`. Two modules bumped:
`github.com/fsnotify/fsnotify v1.9.0 → v1.10.1` (semver-minor; used in
`nftband` for inotify watching) and `golang.org/x/sys v0.42.0 → v0.44.0`
(patch-level within v0). Full build matrix verified in CI: Build &
Test, all 6 distro RPM/DEB builds, all 8 install tests, CodeQL
Analysis (Go), gosec, govulncheck, osv-scanner, Go Security Analysis,
Dependency Review, Validate package effective parity, Validate systemd
ExecStart payload resolution.

### Behavior changes

**None.** Pure docs / dead-code-removal / dependency-refresh. No
daemon, packaging-payload, runtime, schema, metrics, portal, install
API, panel-adapter, FHS, sysusers, polkit, dns2, or DEGRADED-runtime
work in this release.

### Workspace-only (not repo payload)

- **W1 MASTER_TODO refresh** — `V1.80_ROADMAP/MASTER_TODO.md` (workspace
  doc) refreshed from v1.95.0 cutoff through v1.108.0 released + v1.109
  in progress. Workspace-only; not a repo release artifact.

### Out of scope (explicit non-goals carried forward to v1.110+)

- **dns2 host migration execution** — D-DNS-1 PARTIALLY FIXED. BUG side
  closed in v1.108.0 PR #592; DESIGN-FIX side still OPEN. dns2 host is
  source-installed at v1.98.2 and reports `Install type: unknown` until
  manually migrated. Migration scope ready (Option C: manual uninstall
  + RPM install) per `DNS2_SOURCE_INSTALL_TO_RPM_MIGRATION_SCOPE.md`;
  requires P1-P8 operator attestations. **Not a v1.109.0 blocker.**
- **FHS Authority Graph (D-FHS-1..5)** — 5 verified gaps; lane gated by
  separate scope artifact.
- **SELF-HEALING-AUTHORITY-REDESIGN (D-SHA-1)** — post-v1.108.0
  reservation now MET; lane available for separate gate.
- **POLKIT-AUTHORITY impl-level decisions (D-POL-1)**.
- **V108 Item 4 DEGRADED-runtime-pattern investigation (D-DEG-1)** —
  lab repro across 3 host classes required.
- **SEC-FW-BYPASS-ALERT-GAP-001 (D-SEC-1)** — security backlog; parked,
  scope-ready.
- **TRANSPORT-001 (D-TRP-1)** — outbound transport adapter; sub-items
  001A/B/C ordered.
- **Module Isolation V1.101-FOLLOWUP (D-MOD-1)** — 5 R-* findings.
- **Metrics + Portal Contract Enforcement Lane (D-MET-1)** — 18 active
  M-T TODOs.
- **EgressMon module (D-EGM-1)** — CONDITIONAL GO post-CVE-2026-41940.
- **Panel architecture consolidation (D-PNL-1)** — 4 deferred adapters.
- **OS hardening blueprint SELinux/AppArmor (D-OSH-1)** — precondition
  now MET.
- **GHCR `sha-*` retention policy (D-GHC-1)** — org-level governance,
  optional follow-on to V108 Item 12 closure.
- **Bucket C 14 v0.x tag historical-review (D-BKT-1)** — remote
  untouched; deferred per `TAG_HYGIENE_LOCAL_ADOPTION_CLOSURE.md`.
- **v1.109.x hotfix slot** — latent; not authorized.

### Scope

15 files changed since v1.108.0 (excluding this release-prep), plus 2
files in this release-prep: `VERSION` (1.108.0 → 1.109.0), `STATUS.md`
(v1.109.0 release lane added; v1.108.0 demoted to first Prior),
`CHANGELOG.md` (this block prepended), and auto-regenerated
`cli/lib/nftban/core/nftban_fhs_spec.sh` (version banner refresh).

---

## [v1.108.0] - 2026-05-12 — V108 primary hardening bundle

V108 primary hardening lane on top of v1.107.2. Closes 6 of 7 primary
items from the `V108_LIFECYCLE_AUTHORITY_AND_CI_BLIND_SPOT_HARDENING`
workspace scope. Item 4 (DEGRADED-runtime-pattern investigation) is
**not** bundled and remains separately gated for a future release.

The bundle is CI hardening + GOTH/`nftban-ui` decommission completion +
two narrow behavior fixes (CLI install-method classifier and installer
state-writer terminal hygiene). Schema remains frozen at `1.83.0`. No
daemon behavior change. No metrics, portal, install API, or
panel-adapter changes.

### Goals

Lock four operational regression classes that emerged across the
v1.107.x lab2 / lab4 / srv1 / srv3 / srv4 / dns2 rollout into permanent
CI invariants, so they can never recur silently:

1. **v1.107.1-class** — a unit's `ExecStart=` references a helper path
   that the RPM/DEB packagers never staged, leaving
   `INSTALL_STATE=DEGRADED` after every successful takeover.
2. **v1.107.1-class** — an unescaped backtick / `$(...)` inside a
   build-time heredoc silently corrupts the generated RPM `.spec` /
   shell artifact.
3. **v1.107.2-class** — Go `SetImmutableFlags` extends its protected
   files list, but RPM `%pretrans` Lua / DEB preinst / postinst / prerm
   strip-lists fall out of sync, breaking direct package-manager
   upgrade on `+i`-protected hosts (`cpio: rename failed - No data
   available`).
4. **dns2-class** — source-tree installs and `rpm`+`deb` mixed-method
   hosts misclassified as `unknown` by the CLI install-method probe,
   causing upstream gates to refuse safe updates.

In parallel, complete the `nftban-ui` (Go template hot-reload, "GOTH")
decommission started in v1.100.1b.A by cleaning the four remaining
residue surfaces (transitional scriptlets, source/config residue,
active-docs strikethrough policy, and packaging cleanup) and fix the
install_state carry-over hygiene defect observed across all v1.107.2
host snapshots.

### Primary Items

**Item 7C — Transitional `nftban-ui*` scriptlet cleanup** (PR #587,
squash `7c5bccd5`). RPM `%pre` (`packaging/build_nftban.sh`) and DEB
preinst (`packaging/deb/preinst`) gain a small transitional block that
stops, disables, and `systemctl reset-failed` deprecated `nftban-ui*`
units on package upgrade if they survive from pre-v1.100.1b.A
installations. Cross-validated on lab4 (the canonical srv1-class host)
where pre-existing `nftban-ui*` residue was confirmed cleaned by a
single `dnf reinstall`. The scriptlets are idempotent and no-op on
clean hosts.

**Item 7B — Residual source/config residue cleanup** (PR #588, squash
`3a8351e2`). Removes 9 residual GOTH source/config files including the
837-byte `cli/lib/nftban/cli/ui-access.list`. Pure tree cleanup — no
runtime, packaging, or scriptlet behavior touched. Confirmed orphan
status via path-corpus grep across all live consumers prior to
deletion.

**Item 7A — Active-docs cleanup** (PR #589, squash `4a31a58a`). Five
active doc files trimmed of GOTH/`nftban-ui` references.
`docs/systemd/UNITS.md` and `CHANGELOG.md` (this file) retain
**strikethrough** entries for the deprecated units as a deliberate
historical record (not removal). Confirmed via wiki-repo audit that
the external `../wiki` mirror is already aligned with this policy and
needs no separate commit.

**Item 1 — systemd ExecStart payload-resolution CI gate** (PR #590,
squash `86690661`). New gate `scripts/ci/test-systemd-execstart-payload-resolution.sh`
(~470 lines) walks every active unit in `install/systemd/` and asserts
that every `Exec*` path resolves to a payload that RPM or DEB will
ship. Five failure modes (`INVALID_MISSING_PATH`,
`INVALID_NOT_IN_PAYLOAD`, etc.). Wired in as a Policy Gates step in
`.github/workflows/ci-architecture.yml`. Locks the v1.107.1 defect
class permanently (re-running the gate against the v1.107.0 spec
proves it would have caught PR #569 / `nftban-firewall-init.service`
before merge).

**Item 3 — heredoc command-substitution safety CI gate** (PR #591,
squash `8f9318fb`). New gate `scripts/ci/test-heredoc-safety.sh` (~486
lines) parses every shell script in the repo and reports unescaped
backticks / `$(...)` / `$((...))` inside unquoted heredocs. Six
failure modes including `UNESCAPED_BACKTICK_IN_UNQUOTED_HEREDOC` and
`UNCLOSED_HEREDOC`. Fixture extension `.shfix` (instead of `.sh`) so
ShellCheck CI does not pre-parse intentionally malformed fixtures.
Wired into the same Policy Gates job.

**Item 6 — Source-install / mixed package-manager detection** (PR
#592, squash `721b2a5c`). Behavior change in
`cli/lib/nftban/cli/cmd_update_detection.sh`:

- `_detect_install_type()` now reads
  `/var/lib/nftban/state/update-history.json` first-entry type and
  uses three override-aware probes (`_probe_rpm_owns_nftban`,
  `_probe_dpkg_owns_nftban`, `_probe_git_repo_present`) to emit a
  5-class taxonomy: `rpm` / `deb` / `source` / `mixed` / `unknown`.
- New `_classify_for_pkg_mgr_update <target_family>` returns
  gate-framework verdicts via distinct exit codes:
  - `0`  — match (rpm host, rpm target; deb host, deb target)
  - `10` — mismatch (rpm host, deb target — refuse)
  - `11` — source-install (manual upgrade required)
  - `12` — mixed (manual reconciliation required)
  - `13` — unknown (host probe inconclusive)

Closes the dns2-class misclassification where a source-installed host
was reported as `unknown` and silently refused safe updates.

**Item 5 — install_state carry-over hygiene** (PR #593, squash
`ccf37e1f`). Behavior change in
`internal/installer/state/file.go::Transition()`:

- On `COMMITTED` or `DEGRADED` terminals, the new private method
  `applyTerminalHygiene()` clears stale `FailureReason`, clears
  `Conflicts` when `Authority=UPDATE`, and forces
  `PreflightPassed=true`.
- Seven new unit tests in
  `internal/installer/state/file_test.go` cover all transition
  matrices.

Closes the cross-host (lab2 / srv1 / srv3 / srv4) v1.107.2
contradictory-field issue where successful upgrades carried forward
`FailureReason` strings from earlier failed transitions, confusing
downstream gate logic.

**Item 2 — chattr `+i` lifecycle matrix CI gate** (PR #594, squash
`73394dac`). New canonical SoT `build/+i-lifecycle-matrix.yaml`
declares every immutable-protected file and which of four surfaces
must strip the bit at each lifecycle step:

1. Go: `internal/installer/validate/authority.go::SetImmutableFlags`
   (canonical apply list).
2. RPM `%pretrans` Lua + `%preun` (`packaging/build_nftban.sh`).
3. DEB `preinst` + `postinst` + `prerm` (`packaging/deb/`).
4. CLI sweep helper `cli/lib/nftban/cli/cmd_update_helpers.sh::_remove_immutable_flags`
   (covered_by_sweep / covered_by_dir_recursion).

New gate `scripts/ci/test-immutable-lifecycle-matrix.sh` (~280 lines)
validates 7 failure modes (`YAML_FILE_NOT_IN_GO`,
`GO_FILE_NOT_IN_YAML`, `MISSING_RPM_PRETRANS_STRIP`, etc.) and
includes 8 fixtures under `scripts/ci/fixtures/immutable-lifecycle-matrix/`.
Wired in as a Policy Gates step. Mid-PR re-audit confirmed the v1.107.2
DEB `preinst` already strips both files (the original scope §3.3 was
operator-corrected on this point); the gate locks the symmetric strip
requirement permanently across all four surfaces.

Re-running the gate against the v1.107.1 spec proves it would have
caught the v1.107.2 defect class before merge: any future addition to
the Go `SetImmutableFlags` list now requires matching strip-block
additions in every scriptlet OR an explicit `not_required` /
`covered_by_sweep` annotation in the yaml.

### Behavior changes (narrow, explicit)

1. **CLI `nftban update`** now distinguishes `source` / `mixed` /
   `unknown` install methods explicitly and emits distinct exit codes
   for upstream gates (Item 6).
2. **Installer state-writer terminal hygiene** clears stale
   `FailureReason` / `Conflicts` / `PreflightPassed` fields on
   `COMMITTED` / `DEGRADED` transitions (Item 5).
3. **Deprecated `nftban-ui*` units auto-clean** on package upgrade for
   hosts upgrading from pre-v1.100.1b.A packages (Item 7C).

**No behavior change in `nftban-core` / `nftband` daemons.** Schema
frozen at `1.83.0`. No metrics, portal, install API, panel-adapter,
FHS-ATG, Self-Healing, or POLKIT-AUTHORITY implementation changes.

### Defense in place after v1.108.0

| Regression class | Blocked by |
|------------------|------------|
| v1.107.1-class — helper missing from package payload | Item 1 (PR #590) |
| v1.107.1-class — heredoc backtick corruption in generated spec | Item 3 (PR #591) |
| v1.107.2-class — Go `+i` list silently out of sync with scriptlets | Item 2 (PR #594) |
| srv1-class — stale deprecated unit residue across upgrades | Item 7C (PR #587) + Item 1 detector |
| dns2-class — source-install misclassified as `unknown` | Item 6 (PR #592) |
| v1.107.2 cross-host install_state contradictions | Item 5 (PR #593) |

### Non-goals — explicitly carried forward to v1.109+ as separately-gated future debt

- Item 4 DEGRADED-runtime-pattern investigation (separate scope; may
  produce its own hotfix).
- Items 8–16 from the V108 parent inventory (dns2 migration, FHS
  Authority Graph / ATG, POLKIT-AUTHORITY follow-on, optional org-level
  GHCR retention, row 17 SELF-HEALING-AUTHORITY-REDESIGN, etc.).
- `SEC-FW-BYPASS-ALERT-GAP-001` — security backlog, parked,
  scope-ready, not auto-bundled.
- README rewrite PR #586 — routed to a separate docs review track.
- Open Dependabot PRs (#495, #497, #535, #577, #578).
- v1.107.3 hotfix — **not authorized**.

### Reverts / removed

None.

### File counts (merge-bundle scope)

- Item 7C: PR #587 — `packaging/build_nftban.sh` + `packaging/deb/preinst` (transitional blocks).
- Item 7B: PR #588 — 9 files removed (837-byte `ui-access.list` deleted; 8 other GOTH residue).
- Item 7A: PR #589 — 5 active docs trimmed (CHANGELOG.md + `docs/systemd/UNITS.md` strikethrough preserved).
- Item 1: PR #590 — new `scripts/ci/test-systemd-execstart-payload-resolution.sh` + 5 fixtures + workflow EDIT.
- Item 3: PR #591 — new `scripts/ci/test-heredoc-safety.sh` + 6 fixtures (`.shfix`) + workflow EDIT.
- Item 6: PR #592 — `cli/lib/nftban/cli/cmd_update_detection.sh` extended + 9 fixtures (`.vars`).
- Item 5: PR #593 — `internal/installer/state/file.go` + new `file_test.go` (7 tests).
- Item 2: PR #594 — new canonical `build/+i-lifecycle-matrix.yaml` + new `scripts/ci/test-immutable-lifecycle-matrix.sh` + 8 fixtures + workflow EDIT.

This release-prep commit bumps `VERSION` `1.107.2`→`1.108.0`, updates
`STATUS.md` Release lane block, prepends this `CHANGELOG.md` entry, and
regenerates `cli/lib/nftban/core/nftban_fhs_spec.sh` (version-string-only diff).

---

## [v1.107.2] - 2026-05-10 — packaging hotfix (immutable-bit pre-cpio asymmetry)

Single-defect packaging hotfix on top of v1.107.1. Closes a pre-existing
pre-cpio `+i` (immutable bit) asymmetry surfaced operationally during the
v1.107.1 lab4 convergence test (2026-05-10). Schema remains frozen at
`1.83.0`. No metrics changes. No portal coordination. No install API or
panel-adapter changes. No behavior change in `nftban-core` / `nftband`
daemons. The `+i` setter, the unit file, the validator assertion, the
CLI helper `_remove_immutable_flags`, and the comprehensive `%preun` /
prerm are all unchanged — the fix lives exclusively in the
upgrade-pre-cpio path of `packaging/build_nftban.sh`.

### Defect

`internal/installer/validate/authority.go SetImmutableFlags` sets
`chattr +i` on **two** files post-install/repair:

- `/etc/nftban/nftban.conf`
- `/usr/lib/nftban/lib/nft_schema.sh`

The CLI canonical update path `nftban update` (which most operators use)
runs `cli/lib/nftban/cli/cmd_update_helpers.sh:120 _remove_immutable_flags`
before invoking the package manager. That helper walks `/usr/lib/nftban`,
`/usr/sbin/nftban`, and `/etc/nftban` recursively, so both `+i`-protected
files are stripped before extraction.

The **direct package-manager upgrade path** is asymmetric:

- RPM `%pretrans` Lua (`packaging/build_nftban.sh:552-564`) stripped `+i`
  only from `nft_schema.sh` (and a recursive `chattr -i -R /usr/lib/nftban`).
- DEB preinst (`packaging/build_nftban.sh:1346-1361`) stripped `+i` only
  from `nft_schema.sh`.
- `%preun` and DEB prerm DO cover both files, but they run **after** cpio
  extraction in the RPM upgrade transaction (`%preun` of OLD package fires
  at step 5; cpio extract at step 3) — too late to help.

Effect: on any host that completed install/repair under v1.76.0 through
v1.107.1, `/etc/nftban/nftban.conf` carries `+i`. A direct
`dnf upgrade ./nftban-core-*.rpm` or `apt install ./nftban-core-*.deb`
fails at cpio extraction with the misleading message:

    cpio: utime failed - Directory not empty
    error: nftban-core-1.107.1-1.el9.x86_64: install failed
    error: nftban-core-1.107.0-1.el9.x86_64: erase skipped

(`erase skipped` is the proof that `%preun` never ran.) The cpio error
text is `errno=ENOTEMPTY` mistranslation by cpio for the actual
immutable-write block on a regular file.

The defect has existed since v1.76.0 (when the Go installer started
setting `+i` on `nftban.conf`) but was never operationally surfaced
until the v1.107.1 lab4 convergence test deliberately attempted a
direct `dnf upgrade`.

### Fix

`packaging/build_nftban.sh` — two surgical insertions mirroring the
existing `nft_schema.sh` handling:

- **RPM `%pretrans` Lua** — add a 9-line block after the existing
  `if/end` at line 564 that opens `/etc/nftban/nftban.conf`, closes it,
  and runs `chattr -i` via three PATH variants.
- **DEB preinst** — add a 3-line shell `if` before the trailing
  `fi` at line 1361 that runs `chattr -i /etc/nftban/nftban.conf`.

Both blocks are idempotent and silent on absence (file may not exist
on a fresh install). Both mirror the existing pattern.

### Out of scope (explicit non-goals)

- **`internal/installer/validate/authority.go SetImmutableFlags`** —
  unchanged. The `+i` setter is correct as-is; protection is the
  intended security posture.
- **`cli/lib/nftban/cli/cmd_update_helpers.sh _remove_immutable_flags`** —
  unchanged. The CLI workaround already covers the missing path; the
  fix in this release brings the package-manager direct-upgrade path
  to parity, not the other way round.
- **`%preun` / prerm** — unchanged. Already comprehensive; runs in the
  correct ordering for uninstall but is too late on upgrade-pre-cpio.
- **CI hardening** to verify `+i`-managed paths are stripped by both
  upgrade-pre-cpio scriptlets — recommended as separate follow-on; not
  in this hotfix to keep scope minimal.
- **Row 17 SELF-HEALING-AUTHORITY-REDESIGN** — proposed / non-counted /
  SCOPE-FIRST. Remains deferred. Not displaced by v1.107.2.
- **FHS Authority Graph / ATG** — intentionally deferred post-v1.108.
  Not a v1.107.x blocker.
- **Optional org-level GHCR `sha-*` retention policy** — forward-
  looking hygiene; post-v1.107.x.
- **Issue #525 GitHub-level close** — operator-decided.
- **CI hardening to trace systemd `ExecStart=` paths back to package
  payload** (the v1.107.1 architectural blind spot) — recommended
  follow-on; not in this hotfix.

### Standing rules

Schema frozen at `1.83.0`.
No metrics, portal, schema, install API, lifecycle, or panel-adapter
changes in v1.107.2.
`nftban-core` / `nftband` daemons unchanged.
Cross-distro `+i` lifecycle invariant preserved across all four
mechanisms (Go setter / RPM scriptlets / DEB scriptlets / Go uninstall
artifacts) and now also at upgrade-pre-cpio.

### Migration

No operator action required. Hosts already on v1.107.1 will pick up
v1.107.2 cleanly via either canonical `nftban update` (which already
worked) **or** direct `dnf upgrade` / `apt install` (which now also
works on hosts where `/etc/nftban/nftban.conf` carries `+i`). No
takeover state change.

### Release-prep

`packaging/build_nftban.sh` (the fix) +
`VERSION` (`1.107.1` → `1.107.2`) +
`STATUS.md` (release-lane block) +
`CHANGELOG.md` (this block) +
`cli/lib/nftban/core/nftban_fhs_spec.sh` (regen with new VERSION).
Total: 5 files.

---

## [v1.107.1] - 2026-05-10 — packaging hotfix (firewall-init helper)

Single-defect packaging hotfix on top of v1.107.0. Closes a
packaging-vs-source-install asymmetry surfaced operationally by the
v1.107.0 lab4 takeover (Issue #525 follow-on rollout, 2026-05-10).
Schema remains frozen at `1.83.0`. No metrics changes. No portal
coordination. No install API or panel-adapter changes. No behavior
change in `nftban-core` / `nftband` daemons. The helper script,
unit file, and Go validator are all unchanged — the fix lives
exclusively in `packaging/build_nftban.sh`.

### Defect

`install/systemd/nftban-firewall-init.service:55` references
`/usr/lib/nftban/helpers/firewall-init-with-delay.sh`. The
source-install path in `internal/installer/payload/payload.go:411`
correctly stages the helper from `install/helpers/` (per PR26.5,
"source-install payload completeness — close the gaps surfaced
by the dns2 evidence run, 2026-04-30"). The package-build path
in `packaging/build_nftban.sh` was not updated in symmetry, so
RPM and DEB payloads ship 8 helpers (from `cli/lib/nftban/helpers/`)
but not this 9th helper from `install/helpers/`. Effect: every
successful `nftban-installer --repair` takeover ended in
`INSTALL_STATE=DEGRADED` because the Go-side
`systemd_execstart_paths_ok` assertion failed at install time
on real hosts. The directory-glob-level Effective Parity Gate
(PR #576) did not catch this — its scope is package-payload-vs-yaml
SoT at directory granularity, not per-unit ExecStart-path resolution.

### Fix (one PR — packaging only)

- **`packaging/build_nftban.sh`** — two `install` lines:
  - RPM `%install` step (after the systemd-units `while` loop):
    `install -D -m 0755 install/helpers/firewall-init-with-delay.sh %{buildroot}/usr/lib/nftban/helpers/firewall-init-with-delay.sh`
  - DEB `build_deb()` step (after the systemd-units `while` loop):
    `install -m 0755 "${PROJECT_ROOT}/install/helpers/firewall-init-with-delay.sh" "${deb_root}/usr/lib/nftban/helpers/firewall-init-with-delay.sh"`

Helper source (`install/helpers/firewall-init-with-delay.sh`,
3,841 B, mode `rwx--x--x`, present since `d55e38a9`) is unchanged.
Both target directories already exist via the prior
`cp -r cli/lib/nftban/*` step; the new lines are purely additive.

### Out of scope (explicit non-goals)

- **`install/systemd/nftban-firewall-init.service`** — unchanged.
  The `ExecStart=` reference is correct; the missing payload was
  the bug.
- **`install/helpers/firewall-init-with-delay.sh`** — unchanged.
  The helper itself is correct; only its packaging shipment was
  broken.
- **`internal/installer/validate/assertions.go`** — unchanged.
  The `systemd_execstart_paths_ok` assertion correctly surfaced
  the defect; weakening it would mask the same bug class going
  forward.
- **`internal/installer/payload/payload.go`** — unchanged.
  Already correct under PR26.5.
- **CI assertion that traces every unit-file `ExecStart=` path
  back to the package payload** — recommended as a follow-on to
  permanently close the architectural blind spot (extend
  `scripts/test-package-effective-parity.sh`); not landed in
  this hotfix to keep PR scope minimal.
- **Row 17 SELF-HEALING-AUTHORITY-REDESIGN** — proposed /
  non-counted / SCOPE-FIRST per the v1.107.0 doctrine. Not
  displaced by v1.107.1.
- **FHS Authority Graph / ATG** — intentionally deferred
  post-v1.108. Not a v1.107.x blocker.
- **Optional org-level GHCR `sha-*` retention policy** — forward-
  looking hygiene; post-v1.107.x.
- **Issue #525 GitHub-level close** — operator-decided after
  rollout reaches `OK` terminal state on at least one host. The
  v1.107.0 worklog row 12 closure remains authoritative.

### Standing rules

Schema frozen at `1.83.0`.
No metrics, portal, schema, install API, lifecycle, or panel-adapter
changes in v1.107.1.
`nftban-core` / `nftband` daemons unchanged.

### Migration

No operator action required for the daemon. Hosts already on
v1.107.0 in `FAILED_AUTHORITY_ABORT` state (lab2, srv4) will
ship the helper on next `apt-get install` / `dnf install` of
v1.107.1, and a subsequent `NFTBAN_TAKEOVER=1 nftban-installer
--repair` will reach `INSTALL_STATE=OK`. Hosts already in
`DEGRADED` state (lab4) can either upgrade in place (next
`dnf upgrade` ships the helper; subsequent `nftban-installer
--repair` resolves the assertion) or roll back via the
`xt-backup` file written during initial takeover and reinstall
fresh from v1.107.1.

### Release-prep

`packaging/build_nftban.sh` (the fix) +
`VERSION` (`1.107.0` → `1.107.1`) +
`STATUS.md` (release-lane block) +
`CHANGELOG.md` (this block) +
`cli/lib/nftban/core/nftban_fhs_spec.sh` (regen with new VERSION).
Total: 5 files.

---

## [v1.107.0] - 2026-05-10 — post-MFST closure release

Five code PRs and one accepted-retention closure land the v1.107 worklog
targets on top of v1.106.0. Schema remains frozen at `1.83.0`. No metrics
changes. No portal coordination. No install API or panel-adapter changes.

Behavior changes are confined to (a) raised cgroup `TasksMax` on the
`nftban-core-geoip.service` + `nftban-health.service` units (10 → 64) and
(b) corrected `sysusers.d` g-line syntax (dormant in production — DEB
postinst uses `groupadd -r` directly, never `systemd-sysusers`). The
`nftban-core` and `nftband` daemons themselves are unchanged.

Counted-findings progress in v1.106 post-MFST worklog: 12 CLOSED / 3 OPEN
at v1.106.0 → **13 CLOSED / 2 OPEN** at v1.107.0 release-prep, with
remaining rows 6 (F-4) + 7 (F-5) closed in this release-prep PR per
Option α.

### Closure-set PRs

- **PR #576 (squash `15bb9f44`)** — Slot 5a PKG-EFFECTIVE-PARITY. DEB
  postinst ownership convergence using Option α + Option A
  `dpkg-statoverride` semantics. New CI parity gate
  (`Validate package effective parity (RPM vs DEB)`) covers all six
  authority layers: yaml SoT (`build/fhs-spec.yaml`) → generator output
  → archive metadata → installed-fs → reinstall preservation → verify
  tool. RPM continues to use `%attr()` name-based directives; DEB
  reaches the same effective on-disk state through postinst chown +
  `dpkg-statoverride --update --add`.

- **PR #579 (squash `0daeb38e`)** — Slot 5b G8-AUDITOR-DIR-UBUNTU.
  Runtime Truth `G8` verifier wraps its `[ -d ]` / `[ -e ]` / `stat -c`
  checks in `sudo` so the runner user can traverse the intentionally-
  restrictive `0750 root:nftban` parent directory on Ubuntu 24.04.
  Bucket F (CI verifier privilege) classification confirmed by
  `SYSTEMD_LOG_LEVEL=debug` capture; `systemd-tmpfiles` always created
  the auditor directory correctly on both AlmaLinux 9 / systemd 252 and
  Ubuntu 24.04 / systemd 255 — the bug was entirely in the test harness.
  No product code, packaging, or sysusers/tmpfiles change.

- **PR #580 (squash `1d2c4b63`)** — Slot 6 POLKIT-AUTHORITY documentation
  amendment (2 files / +73 / −0). Two `note:` fields added to
  `build/fhs-spec.yaml` (one on the `nftban-panel` group entry recording
  the D-NEW-11 keep-decision + 9-surface live-consumer manifest, one on
  `/var/lib/nftban/reports/auditors` flagging it as an AUTHORITY
  EXCEPTION). Header `// CONSUMERS (verified live as of v1.107)` block
  added to `packaging/polkit-1/rules.d/30-nftban-panel.rules` with the
  decommission-rejected rationale. `polkit.addRule(...)` body
  **BYTE-IDENTICAL** to base — verified by `diff` on extracted rule
  bodies. Generator `--check` confirms the new `note:` field is not
  consumed by yq queries (zero generated-artifact drift). The three-tier
  polkit model (operator / auditor / panel) is confirmed load-bearing
  and intentional.

- **PR #581 (squash `1d83df9e`)** — Slot 7 LANE-G / Issue #525.
  `install/systemd/nftban-core-geoip.service`: `TasksMax=10`→`64` with a
  mechanism comment citing Go 1.25 runtime + maxminddb finalizer-
  goroutine OS-thread requirements (peer Go services in
  `install/systemd/` ran 20–50; geoip was the outlier). Mirror fix on
  `install/systemd/nftban-health.service` because health checks shell
  out to `nftban-core` subcommands and exercise the same Go runtime
  surface. New Runtime Truth `G9` step asserts no Go runtime fatal-trace
  patterns (`runtime.fatalpanic`, `runtime.gopanic`,
  `runtime.(*cleanupQueue)`, `fatal error:`, `^panic:`,
  `goroutine 1 [running]:`) appear in geoip startup output on both
  matrix legs (real-systemd path A on ubuntu-24.04; `prlimit --nproc=64`
  path B on almalinux-9 container). Closes Issue #525 root cause:
  `clone(2) EAGAIN` under cgroup pids-exhaustion. **No `cmd_geoip.go`
  or `internal/geoip/lookup.go` change. No `maxminddb-golang` version
  bump.** Issue #525 left OPEN by the merge gate (operational hygiene;
  operator may close separately).

- **PR #582 (squash `3af86877`)** — proposed worklog row 16 SYSUSERS-
  GECOS-G-LINES one-shot. `build/generate-fhs-outputs.sh:217` g-line
  emitter switched from `g \(.name) - "\(.comment)"` to `g \(.name) -`,
  per `sysusers.d(5)`'s rule that g-lines take only `name [id]` (GECOS
  is reserved for u-lines). Regenerated `install/systemd/sysusers.d/
  nftban.conf` so the 3 g-lines now match `g <name> -`. New Runtime
  Truth `G10` step asserts `systemd-sysusers --dry-run` exits `0` on
  both ubuntu-24.04 (systemd 255) and almalinux-9 (systemd 252) matrix
  legs + belt-and-braces grep on the diagnostic message. Identities
  byte-equivalent (3 groups + 1 user + 1 membership preserved); u-line
  GECOS preserved (allowed on u-lines per `sysusers.d(5)`); comment
  metadata preserved in `build/fhs-spec.yaml` under
  `.sysusers.groups[].comment` (just no longer emitted to sysusers.d
  g-lines). Was dormant in production: postinst uses `groupadd -r`
  directly, never `systemd-sysusers`.

### Accepted-retention closure (no PR)

- **Row 13 / F-6 REGISTRY-HYGIENE** — closed via accepted-retention
  path (b) per `OPEN-REGISTRY-HYGIENE-SCOPE` (verdict
  `GO_CLOSE_AS_ACCEPTED_RETENTION`). Read-only GHCR HEAD/GET probes
  confirmed `ghcr.io/itcmsgr/nftban:sha-4de527d` exists (manifest digest
  `sha256:e1f0fc37…`) and is one of 284 `sha-*` tags emitted by the
  standard `docker/metadata-action@v5.9.0` `type=sha` rule in
  `.github/workflows/docker.yml`. The tag corresponds to git commit
  `4de527dc` (the v1.106.0 release squash). Original "first/failed
  publish" framing was a misclassification — the tag is a normal CI
  artifact, not stale. **Zero registry mutation; zero code change; zero
  PR.** Closure recorded in worklog `§6.9` and this CHANGELOG entry.

### CI hardening (Runtime Truth Gate)

The `Runtime Truth Gate` workflow grew from 8 G-steps at v1.106.0 to
**10 G-steps** at v1.107.0:

- `G9` (added by PR #581): no Go runtime fatal trace at geoip startup;
  matrix-aware (real systemd path A on ubuntu-24.04; `prlimit --nproc=64`
  path B on almalinux-9).
- `G10` (added by PR #582): `systemd-sysusers --dry-run` exits 0 on
  systemd 252 + 255; belt-and-braces grep on the diagnostic message
  catches future regressions.

Both new gates lock the regression class: any future PR that
re-introduces the geoip fatal-trace path or the sysusers GECOS-on-g-line
defect fails CI.

### Documentation closures (rows 6 + 7 / F-4 + F-5, this PR)

- **Row 6 / F-4** — v1.106.0 hotfix-arc disclosure consolidation. The
  v1.106.0 release shipped seven Lane MFST PRs (#563–#569). The v1.107.0
  closure narrative above documents the post-v1.106 work that completes
  the arc: PRs #576/#579 close the PKG-EFFECTIVE-PARITY layer (Slot 5);
  PR #580 closes the POLKIT-AUTHORITY documentation gaps surfaced
  during Slot 5; PR #581 closes the long-deferred Lane G #525; PR #582
  closes the SYSUSERS-GECOS-G-LINES dormant defect surfaced by Slot 5b's
  reverted Stage-2 attempt; row 13 closes via accepted-retention. F-4
  disclosure complete.

- **Row 7 / F-5** — release/status rolling-context note. STATUS.md and
  this CHANGELOG together carry the rolling closure context for the
  v1.106 → v1.107 arc, including: explicit non-goals (row 17
  SELF-HEALING-AUTHORITY-REDESIGN; FHS Authority Graph / ATG; org-level
  GHCR retention); preserved scope discipline (no schema/metrics/portal
  changes); preserved authority discipline (no postinst migration to
  systemd-sysusers; row 17 not displaced by v1.107). F-5 disclosure
  complete.

### Explicit non-goals (carried forward as future debt)

- **Row 17 SELF-HEALING-AUTHORITY-REDESIGN** — lifecycle / authority-
  model debt (proposed/non-counted); treatment SCOPE-FIRST per the
  2026-05-09 doctrine. After Slot 5 + Slot 6 closed, NFTBan's authority
  model spans `build/fhs-spec.yaml` (SoT) + `systemd-tmpfiles` +
  `systemd-sysusers` + postinst/postrm + `dpkg-statoverride` + RPM
  `%attr()` / dpkg verification + Runtime Truth + PKG-EFFECTIVE-PARITY
  gates. Self-Healing must be audited and (if needed) redesigned to
  route every repair through the correct authority mechanism rather
  than independent `mkdir`/`chown`/`chmod`/identity-create. Awaits
  separately-authorized `OPEN-SELF-HEALING-AUTHORITY-REDESIGN-SCOPE`
  gate. **Not displaced by v1.107.0.**

- **FHS Authority Graph / ATG** — intentionally deferred. **Not a
  v1.107.0 blocker; will not open before release.** After v1.108.0 the
  operator may introduce it as a separate debt lane with its own scope
  gate. v1.107.0 release scope is limited to the closure-set PRs above
  + row 13 accepted-retention + rows 6/7 release-prep doc-amend.

- **Optional org-level GHCR `sha-*` retention policy** — forward-
  looking hygiene; post-v1.107. Would auto-prune `sha-*` tags older
  than N days while preserving `latest`/`main`/semver tags. Out of
  scope for v1.107.0; not a row-13 dependency.

- **`maxminddb-golang` version bump** — explicitly excluded from PR
  #581 / Slot 7. The conservative TasksMax fix proved sufficient; the
  dependency bump is available as a separate PR if a future regression
  ever requires it. Not a v1.107.0 task.

### Migration

No operator action required. The two TasksMax changes apply on the
next service restart (or immediately on fresh install). The sysusers
change is dormant in production for current postinst paths and only
matters if a future packaging change moves identity creation to
`systemd-sysusers`.

---

## [v1.106.0] - 2026-05-06 — Lane MFST (Manifest Authority) partial release

Seven code PRs land manifest-pipeline drift closures on top of v1.104.0
(v1.105.0 was reserved but never tagged; the lane is codenamed v1.106
Manifest Authority and the release name follows the lane). Schema remains
frozen at `1.83.0`. No metrics changes. No portal coordination. No install
API or panel-adapter changes. The only documented runtime-visible change
is **8 net-new systemd unit files now ship passively** (file-presence
only; the Go installer at `internal/installer/services/daemon.go`
continues to own enablement per the PR-22B safety contract).

C6 (AM-4 + E6 structural CI hardening) is deferred to v1.107+ per
operator queue narrowing. AUTH-HARDENING (D-NEW-8 / D-NEW-9 / D-NEW-12)
and POLKIT-AUTHORITY (D-NEW-10 / D-NEW-11) remain separately gated.
Issue #525 (geoip startup Go runtime panic, P1) remains deferred to
Lane G / v1.107+.

### Lane MFST — Manifest Authority partial closure

- **C0a** RPM Layer-0 wire-in. Spec heredoc consumes the generator
  output `install/packaging/rpm/nftban-files.inc` via `%include
  %{_sourcedir}/nftban-files.inc`; staged into `${BUILD_DIR}/SOURCES/`
  by `build_rpm()`. 11 new directory entries added to
  `build/fhs-spec.yaml` (8 panel sub-dirs + `botguard/profiles` +
  `conf.d/suricata` + `/etc/nftban/templates`). `/etc/nftban/distros`
  yaml mode/owner corrected (0755 root:root → 0750 root:nftban) to
  preserve current package behavior. Tmpfiles-managed `/var/*` and
  `/run/*` removed from `%files` (Option 4a — created by tmpfiles at
  boot). Closes drift D-NEW-1 RPM-side.
  (`8f5b35a8`, PR [#563](https://github.com/itcmsgr/nftban/pull/563))
- **C0b** DEB Layer-0 wire-in. `build_deb()` consumes
  `install/packaging/deb/nftban.dirs` via a while-read loop; 26-entry
  brace expansion + 17 inline mkdirs replaced. 10 tmpfiles-managed
  runtime dirs removed from build_deb (Option 4a parity). Closes drift
  D-NEW-1 DEB-side.
  (`be0c9bc3`, PR [#564](https://github.com/itcmsgr/nftban/pull/564))
- **C1** Layer-1 systemd install-list generator. New
  `build/generate-systemd-install-list.sh` reads
  `install/systemd/*.{service,timer,socket}` and emits a shared
  `install/packaging/systemd/nftban-systemd-install.list` (49 unit
  basenames). Both `build_rpm()` (via spec heredoc + `Source2:`) and
  `build_deb()` (while-read loop) consume the same list. CI gains a
  parallel `--check` step. Closes drift D1 (the prior 41-of-49 gap).
  The 8 net-new units are file-presence only — no auto-enable, no
  `%systemd_post`/`%systemd_preset` macros, no preset files; the Go
  installer continues to own enablement.
  (`a07f4c2c`, PR [#565](https://github.com/itcmsgr/nftban/pull/565))
- **C2** `docs/systemd/UNITS.md` regenerated from filesystem truth.
  Header counts fixed (15 → 21 timers, 25 → 27 services), Sockets
  promoted to its own section (1), 6 missing timer rows + 6 missing
  service rows added with Schedule and Purpose pulled from each
  unit's `OnCalendar=` / `OnBootSec=` / `Description=`, 5 stale
  entries (`nftban-login-monitor.service`, `nftban-api.service`,
  `nftban-ui.service`, `nftban-ui-auth.service`,
  `nftban-ui-auth.socket`) moved to DEPRECATED with removal-version
  notes. Senior audit fix-up commit corrected the
  `nftban-rbl-check.timer` schedule from "Daily 2:00" to "Twice daily
  02:00/14:00 + boot+10m", fixed the `nftban-pro-inventory.timer`
  purpose ("inventory collection", not "license"), added
  `+ boot+Nm` annotations to 8 timer rows, replaced the misleading
  "SINGLE SOURCE OF TRUTH" header with a curated-projection
  description, and renamed Type to Category to disambiguate from the
  literal systemd `Type=` directive. CI gains a count-parity step.
  Closes drift D3.
  (`b331d5c3`, PR [#566](https://github.com/itcmsgr/nftban/pull/566))
- **C3** `build/deprecated-units.yaml` (5 entries: `login-monitor` and
  `api` as `stop_only`; `ui`, `ui-auth.service`, `ui-auth.socket` as
  `stop_disable_mask_remove`) + `build/generate-systemd-maintainer-scripts.sh`
  (~490 LOC) emit per-packager cleanup snippets (`.inc`) consumed by
  RPM `%preun` (heredoc interpolation) and DEB `prerm` (sentinel
  region). The new `mask_if_exists()` helper guards all mask / remove
  operations behind a `readlink "/etc/systemd/system/$unit" ==
  "/dev/null"` check, so clean hosts no longer accumulate
  `/etc/systemd/system/nftban-ui*` mask residue (Lane L10 F7_LOW class
  structurally closed) and operator-created custom symlinks
  (target ≠ `/dev/null`) are preserved. Active stop list now sources
  from C1 (49 units minus 1 `*@.service` template skip = 48). CI
  gains structural assertions (mask_if_exists + readlink
  /dev/null + no unconditional `systemctl mask nftban-ui*`). Closes
  drift D6.
  (`ed632e34`, PR [#567](https://github.com/itcmsgr/nftban/pull/567))
- **C4** `internal/installer/fhs/paths_yaml_parity_test.go`. The Go
  test reads the C0a-generated mirror
  `cli/lib/nftban/data/fhs_directories.json` (no yq / YAML-library
  dep), iterates `RequiredDirs`, asserts every path is either
  declared in yaml or explicitly exempted with rationale. One inline
  exemption: `/var/lib/node_exporter/textfile_collector`
  (runtime-only metrics-deposit subdir of externally-owned
  `/var/lib/node_exporter`). Mode/owner alignment is intentionally
  out of scope; that work is routed to AUTH-HARDENING. Closes
  drift D4.
  (`63fab761`, PR [#568](https://github.com/itcmsgr/nftban/pull/568))
- **C5** `internal/loginmon/distroconf/distroconf_loader_parity_test.go`.
  Iterates all 18 committed distro fixtures in
  `etc/nftban/distros/*.conf` and asserts each parses cleanly via
  `distroconf.LoadFromFile()` and contains the 7 shell-recognized
  sections (`distro`, `package_manager`, `packages`, `services`,
  `paths`, `repository`, `features`). Three documented design
  asymmetries inline (NOT enforced): shell drops `[tier]`; shell
  collapses absent / empty / `n/a` to `""` while Go has 4-state
  `Resolve()`; `centos.conf` and `fedora.conf` are shell-only
  generic fallbacks. Extends Go-side fixture coverage from 2 of 18
  to all 18, symmetric to the existing shell-side coverage in
  `cli/lib/nftban/tests/validate_distro_configs.sh`. Closes
  drift D5.
  (`4222f707`, PR [#569](https://github.com/itcmsgr/nftban/pull/569))

### v1.106 lane closure surfaces

- **D-NEW-1 RPM** (`nftban-files.inc` orphan) — closed by C0a.
- **D-NEW-1 DEB** (`nftban.dirs` orphan) — closed by C0b.
- **D1** (RPM/DEB systemd install-list drift, 41 vs 49) — closed by C1.
- **D3** (`docs/systemd/UNITS.md` count + content drift) — closed by C2.
- **D4** (paths.go ↔ fhs-spec.yaml parity) — closed by C4.
- **D5** (shell ↔ Go distro-loader fixture coverage) — closed by C5.
- **D6** (RPM `%preun` / DEB `prerm` hand-rolled lists + unconditional
  `nftban-ui*` mask) — closed by C3.
- **Lane L10 F7_LOW class** (`/etc/systemd/system` mask-residue on
  clean hosts during uninstall) — structurally closed by C3.

### Out-of-scope items deferred to later releases

- C6 (AM-4 + E6 structural CI hardening) — v1.107+.
- AUTH-HARDENING lane (D-NEW-8 paths.go ↔ tmpfiles owner drift,
  D-NEW-9 `/run/nftban` + `/var/cache/nftban` mode tightening,
  D-NEW-12 DEB postinst missing chown for `/etc/nftban/*`) — separate
  lane, not started.
- POLKIT-AUTHORITY lane (D-NEW-10 auditor reports `0770 root:nftban-auditor`
  doc gap, D-NEW-11 `nftban-panel` group decommission) — separate
  lane, not started.
- Issue #525 (geoip startup Go runtime panic, P1) — Lane G, deferred.
- F14 manifest-parity gate, Shape A wrapper — deferred per MFST-A2
  AM-5 / AM-6.

---

## [v1.104.0] - 2026-05-05 — Lane M test-guard release (Decision B)

One test-guard PR on top of v1.103.0. Schema remains frozen at `1.83.0`. No
metrics changes. No portal coordination. No lifecycle, install, packaging,
or panel-adapter changes. **No runtime behavior change.** Lane S remains held.

### Lane M — Login config-namespace ownership formalized (Decision B)

- **PR-M-C** Rename the temporary v1.103 boundary-guard test
  `TestLoadFromFile_LoginNotAliasedInC3C` into a permanent regression guard
  `TestLoadFromFile_LoginKeysAreDistinctFacts`, and add a symmetric
  `TestOverlayFromFile_LoginKeysAreDistinctFacts` covering the `.conf.local`
  overlay path (`67e7492f`, PR
  [#561](https://github.com/itcmsgr/nftban/pull/561)). The comment block now
  cites Lane M Decision B as the authority. Single file:
  `internal/nftbanconf/loader_alias_test.go` (+27 / −7).
- **Lane M Decision B (locked):** `LOGIN_ENABLED` (Go loginmon module
  per-module self-enable; owned by `internal/loginmon`; declared in
  `etc/nftban/conf.d/login/main.conf:26`) and `NFTBAN_LOGIN_MONITOR_ENABLED`
  (central nftban infra observability/monitor gate; owned by
  `internal/nftbanconf`; declared in `install/config/nftban.conf:207`) are
  **distinct configuration facts**, not duplicates. They control different
  subsystems and **must never be aliased**. Drift row **C0A-D-07** closed by
  formalizing the split. **No alias was introduced**: the central loader
  (`internal/nftbanconf/loader.go`), the loginmon module
  (`internal/loginmon/module.go`), and the alias helper
  (`cli/lib/nftban/lib/nftban_config_alias.sh`) all remain unchanged.

### Out of scope (explicit non-goals)

- **Issue [#525](https://github.com/itcmsgr/nftban/issues/525)** —
  `nftban-core-geoip.service crashes at startup (Go runtime panic,
  status=2/INVALIDARGUMENT)` — remains OPEN and is deferred to **Lane G /
  v1.105** investigation. Not introduced by v1.104; carries over from
  v1.101 / v1.102 / v1.103 deferrals.
- BotGuard (C0A-D-08) skipped — production clean; legacy `BOTGUARD_ENABLED`
  regression-guard fixture intentionally retained.
- GeoBan tracked separately as `GEO-CLEANUP-001` (optional micro-cleanup;
  not started).
- Bucket C residual old tags (`v0.8.0`, `v0.9.2-final`, `v0.9.3`, `v0.9.4`,
  `v0.9.5`, `v0.9.5-final`, `v0.10.0`, `v0.30.0`, `v0.30.6`, `v0.30.7`,
  `v0.30.8`, `v0.31.1`, `v0.32.5`, `v0.32.22`) remain deferred to a future
  historical-review lane (separate from any release).

### Standing rules

- Schema frozen at `1.83.0`.
- No metrics, portal, lifecycle, install, packaging, or panel-adapter
  changes in v1.104.0.

### Release-prep

- **Release-prep PR** VERSION + STATUS + CHANGELOG + FHS regen.

---

## [v1.103.0] - 2026-05-05 — config canonical-alias reads (Lane C / C3-C)

One code PR on top of v1.102.0. Schema remains frozen at `1.83.0`. No
metrics changes. No portal coordination. No lifecycle, install,
packaging, or panel-adapter changes. Lane S remains held.

### Lane C — config canonical-alias (Strategy C)

- **PR-C3-C** Add read-side `*_ENABLED` key aliases for DDoS and
  Portscan (`f6163af6`, PR [#559](https://github.com/itcmsgr/nftban/pull/559)).
  Strategy C: read both keys, canonical wins on conflict, warn on
  conflict. Write paths already canonical in v1.102.0 — no write-side
  change. Six files: shared shell helper
  `cli/lib/nftban/lib/nftban_config_alias.sh` (new); shell consumers
  `cli/lib/nftban/core/nftban_config_doctor.sh` and
  `cli/lib/nftban/helpers/suricata_effective_config.sh`; 23-case shell
  test `cli/lib/nftban/tests/test_config_alias_ddos_portscan.sh` (new);
  Go central loader `internal/nftbanconf/loader.go` adds `DDoSEnabled`
  and `PortscanEnabled` fields with alias switch cases; Go alias test
  `internal/nftbanconf/loader_alias_test.go` (new) including
  `TestLoadFromFile_LoginNotAliasedInC3C` boundary guard.
- **Operator-visible behavior change:** operators who had only set
  `NFTBAN_DDOS_ENABLED` or `NFTBAN_PORTSCAN_ENABLED` in
  `nftban.conf.local` will now see those values honored by
  `config-doctor` and the central Go loader. If both the canonical and
  the prefixed key are set with different values, the canonical wins
  and a warning is emitted.
- **Drift register effect:** C0A-D-05 (DDoS) and C0A-D-06 (Portscan)
  CLOSED.

### Out of scope (explicit non-goals)

- **Login (C0A-D-07)** remains deferred to v1.104 Lane M.
- **BotGuard (C0A-D-08)** skipped — production clean; the legacy
  `BOTGUARD_ENABLED` regression-guard fixture is intentionally
  retained.
- **GeoBan** tracked separately as `GEO-CLEANUP-001` (optional
  micro-cleanup; not started).
- **Issue [#525](https://github.com/itcmsgr/nftban/issues/525)** —
  `nftban-core-geoip.service crashes at startup (Go runtime panic,
  status=2/INVALIDARGUMENT)` — remains OPEN and is deferred to v1.104
  investigation. Not introduced by v1.103; carries over from v1.101 /
  v1.102 deferrals.

### Standing rules

- Schema frozen at `1.83.0`.
- No metrics, portal, lifecycle, install, packaging, or panel-adapter
  changes in v1.103.0.
- v1.103 hygiene Batch 1 closed internal-only (workspace audit-pack
  cross-references); zero `nftban-core` repo touches in that lane.

### Release-prep

- **Release-prep PR** VERSION + STATUS + CHANGELOG + FHS regen.

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
