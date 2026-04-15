# NFTBan Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **History reset.** Pre-v1.79.2 releases are recorded as git tags and on
> the GitHub Releases page (`gh release list`). From v1.79.2 forward, every
> tagged release MUST have a CHANGELOG entry written before tagging.

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

### Refs

- V1.80_ROADMAP/MASTER_TODO.md (v3.1, GO 2026-04-13)

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
