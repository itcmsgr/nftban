# NFTBan — Integrity & Build Status

> **Policy:** Main branch is always green. Failed CI blocks merge.
> No manual overrides for truth-critical checks. Evidence over claims.

**Version (this commit):** v1.112.2 — sourced from [`/VERSION`](VERSION); static per commit, not auto-updated. For the current released tag see [GitHub releases](https://github.com/itcmsgr/nftban/releases) or the README badge.
**Release lane:** v1.112.2 (2026-05-13) — V112.2 single-PR hotfix on top of v1.112.1. Closes a long-latent DEB-postinst ordering defect exposed under V112.2 fresh-install validation across the 9-VM lab fleet (`hyperv-itcms`) + lab2 snapshot rebuild. `packaging/deb/postinst` invoked the Go installer (which triggers service activation) BEFORE creating the runtime tree shipped via `/usr/lib/tmpfiles.d/nftban.conf`. With `nftband.service` declaring `ReadWritePaths=/var/cache/nftban` for systemd mount-namespace isolation, systemd refuses the unit at namespace setup with `status=226/NAMESPACE` (`"Failed to set up mount namespacing: /var/cache/nftban: No such file or directory"`). `nftban-unified-exporter.service` inherits the same failure path and surfaces as `exit-code 2/INVALIDARGUMENT` — the SAME visible symptom that motivated v1.112.1 PR #606, but rooted in packaging ordering rather than shell arithmetic. **Zero impact on v1.112.x release content** (Go daemon, all exporter scripts, systemd unit files, FHS spec, schema all UNCHANGED). **Schema 1.83.0 remains frozen.** **No new metric names. No new schema entries. No new label cardinality. No systemd unit change. No Go daemon change. No RPM packaging change.** **PR (single):** **#608** (sq `3ec53e24`) — `fix(packaging): run systemd-tmpfiles --create before service activation in DEB postinst (v1.112.2 hotfix)`. Insert `systemd-tmpfiles --create /usr/lib/tmpfiles.d/nftban.conf 2>/dev/null || true` between `systemctl daemon-reload` and the Go-installer invocation block. Idempotent (`[ -f ]` guard + `|| true` fallback). 1 file (+16/-0): `packaging/deb/postinst`. **No struct/interface churn:** Go source / schema / unit files / FHS spec / RPM packaging all UNCHANGED. **Reproduction matrix (11 hosts; evidence at `AUDIT_190_LIFECYCLE/V112_HOST_VITALS_EVIDENCE/v112_2_vm_fleet/`):** 5/5 RPM hosts NO reproduction (lab4 AlmaLinux 9, tgt-a9, tgt-r9, tgt-cs9, tgt-a8 cross-major el9) — RPM `%post` scriptlet ordering already creates runtime dirs before service activation; **4/4 fresh DEB VMs REPRODUCED the exit=2 self-repair pattern** — tgt-d12 Debian 12 (r1-r3 exit=2, 7/10 pass), tgt-d13 Debian 13 (r1-r4+ exit=2 then SUCCESS), tgt-u2204 Ubuntu 22.04 (r1-r3 exit=2, 7/10 pass), tgt-u2404 Ubuntu 24.04 (r1-r4 exit=2 then SUCCESS); lab2 Ubuntu 24.04 fresh install preinst-blocked first → after manual `systemd-tmpfiles --create` + `systemctl restart nftband.service` → 10/10 SUCCESS confirming tmpfiles-create is sufficient remediation. Defect localized to DEB postinst ordering exclusively. **Why v1.112.1 fix was insufficient:** PR #606 line-805 Shape A arithmetic fix is a real defensive improvement but targets a different surface (extended-mode `live extended` code path in `nftban_unified_exporter_collect.sh`). The actual broader v1.112-class regression was the DEB-postinst ordering gap — visible from minute one in the journal as `nftband.service: Failed to set up mount namespacing` (status=226/NAMESPACE) one layer earlier than the unified-exporter exit=2 that V112.1 chased. PR #606 remains correctly merged at v1.112.1 and is unrelated to this hotfix. **Verification:** `bash -n` syntax PASS on `packaging/deb/postinst`; shellcheck shows only one pre-existing SC2043 at line 157 (unchanged from baseline; not introduced by this PR); pre-commit hooks PASSED (header validations + shell-files check); CI 45 critical checks PASS including all 4 DEB install workflows (debian12/13 + ubuntu22.04/24.04) + all 4 RPM install workflows (alma9 + centos-stream9/10 + rocky9) + Runtime Truth (almalinux-9 + ubuntu-24.04) + package effective parity + systemd ExecStart payload resolution. **Audit-discipline note:** 9-VM parallel acceptance reproduced the defect with leave-no-trace cleanup per VM; one-VM-per-gate discipline waived for parallel coverage per operator direction with the caveat that per-VM before/after evidence is preserved. **Investigation lesson captured:** when a systemd unit fails, ALWAYS read one journal layer earlier — decisive errors often sit in a dependent unit (`nftband.service` 226/NAMESPACE was visible from minute one but V112.1 chased exporter exit=2 across two release cycles). Status codes 200–255 indicate pre-script-exec setup failure (namespace / capabilities / user / cgroup), not script-body bugs. Prevention CI guard recorded as future debt: assert "remove /var/cache/nftban → install DEB → service must start without 226/NAMESPACE". **Explicit non-goals carried forward to v1.113+ as separately-gated future debt:** V112 plan §5 host rollout resumes with v1.112.2 (`EXECUTE_V112_2_VALIDATE_DEB_FAMILY = GO` cross-distro DEB re-validation acceptance: fresh install + `nftband.service` starts cleanly without 226/NAMESPACE without manual tmpfiles step; then `EXECUTE_V112_VALIDATE_SRV3/SRV2/SRV1 = GO`); `OPEN_V112_DNS2_UPDATE_SAFETY_PREFLIGHT = GO_READ_ONLY`; `OPEN_V113_PORTAL_REENTRY_READINESS_SCOPE = GO_READ_ONLY`; `OPEN_V112_2_CI_FRESH_INSTALL_GUARD_PR = GO_IMPLEMENTATION_ONLY` (CI prevention truth case for tmpfiles-before-service-start); `OPEN_V112_2_RPM_POST_DEFENSIVE_HOTFIX_PR = GO_IMPLEMENTATION_ONLY` (defense-in-depth RPM %post tmpfiles call); `OPEN_V112_2_EXPORTER_INVOCATION_INVESTIGATION_RESUME = GO_READ_ONLY` (companion bash-wrapped-vs-bare-path question; low priority now that root cause is identified); all v1.112.0/v1.112.1 deferred items remain deferred (PR-M2b-w2..w7 per-module emission waves; PR-M2c new nft named counters; PR-M2d kernel set element annotation cookies; PR-M3 cache + PR-M1 CLI; §F4 metrics beyond 6 targets; D-LMA-1 W1; R-11; D-DNS-1 DESIGN-FIX; D-FHS-1..5; D-SHA-1; D-POL-1; D-DEG-1; D-SEC-1; D-TRP-1; D-EGM-1; D-PNL-1; D-OSH-1; D-GHC-1; D-BKT-1). v1.112.3 hotfix slot **not authorized** (latent reservation only — opened only if a v1.112.2 defect surfaces).
**Prior release lane:** v1.112.1 (2026-05-12) — V112.1 single-PR hotfix on top of v1.112.0. Closes a v1.112.0-released regression in the `nftban-unified-exporter.service` shell exporter that surfaced under post-release host-vitals validation (lab2/lab4 EL9+Ubuntu hosts failed `live extended` mode invocation with `exit-code 2/INVALIDARGUMENT`; srv4 EL10 unaffected — newer toolchain timing). **Zero impact on v1.112.0 host-vitals release content** (Go daemon `/metrics` continues to emit all 6 `nftban_host_*` metrics correctly on every validated host; this hotfix touches the shell-exporter side only). **Schema 1.83.0 remains frozen.** **No new metric names. No new schema entries. No new label cardinality. No systemd unit change. No Go daemon change.** **PR (single):** **#606** (sq `5d4e9613`) — `fix(exporter): nftban_nft_sets_total arithmetic syntax error (v1.112.1 hotfix)`. Root cause was `cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh:805` compound arithmetic `sets_count=$(( $(nft list sets "$ipv4_family" 2>/dev/null | grep -c "set " || echo 0) + ... ))` — when `nft list sets` returns no matches, `grep -c "set "` outputs `"0"` AND exits 1 (no matches per GNU grep semantics); the `|| echo 0` fallback then outputs ANOTHER `"0"`; the captured stdout `"0\n0"` is invalid inside `$(( ))` arithmetic context and produces a bash syntax error, which under `set -Eeuo pipefail` exits the script with code 2 — systemd reports as `INVALIDARGUMENT` and the entire `nftban-unified-exporter.service` invocation fails. Manifests reliably under `groups: live extended` in restricted systemd context (User=nftban + ProtectSystem=strict + CAP_NET_ADMIN + RestrictAddressFamilies + LockPersonality); intermittent under `groups: live` only. Manual root invocation succeeds (different env state). EL10 hosts (srv4) unaffected because the timer fires when nft tables are populated and the `grep -c` matches at least one set, avoiding the dual-zero output. **Fix (Shape A defensive wrapping per `V112_1_HOTFIX_PR_B_SCOPE.md` §3):** split the compound arithmetic into separate command-substitutions with `|| _v4_sets=0` assignment-level fallback + `[[ =~ ^[0-9]+$ ]]` numeric-validation guard + safe two-operand arithmetic. The dual-output pattern cannot occur. 1 file (+14/-1): `cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh` lines 803-820 modified. **No struct/interface churn:** systemd unit + timer + all other exporter scripts (`nftban_unified_exporter.sh` loader + `_helpers.sh` + `_export.sh`) UNCHANGED. **No Go daemon change.** **Note (v1.112.2 post-mortem):** PR #606's shell hardening is unrelated to the V112-class broader regression which v1.112.2 root-causes as a DEB-postinst tmpfiles ordering defect. PR #606 remains correctly merged at v1.112.1 as a defensive improvement, but was not the actual cause of the original lab2/lab4 failures. The decisive error (`nftband.service 226/NAMESPACE`) was sitting one journal layer earlier and was first surfaced by V112.2 fresh-install testing on the lab VM fleet (4/4 DEB VMs reproduced the underlying exit=2 pattern). v1.112.1 host upgrades remain safe (existing /var/cache/nftban dirs from prior installs mask the postinst gap); only fresh DEB installs hit it before v1.112.2 shipped.
**Prior release lane:** v1.112.0 (2026-05-12) — V112 PR-B schema-fulfill lane on top of v1.111.0. Closes PR-M2b-w1 host-vitals emission gap by implementing 6 metric names already declared in schema doc 17 §F4 + already accepted in the receiver-v2 181-entry allow-list since v1.111.0 publish. **Schema 1.83.0 frozen invariant remains intact** per operator contract-fulfill interpretation locked at `V112_CONTRACT_FULFILL_ATTESTATION.md` — implementing already-declared schema names is fulfillment, not schema mutation. **Behavior change limited to: 6 host-vitals Prometheus metrics now emit in production where they previously did not exist on the daemon `/metrics` surface** (the receiver-v2 has been ready since 2026-05-02 M-T9 cutover). **No new metric names beyond what schema doc 17 §F4 already declared.** **No new label cardinality dimensions.** No portal, install API, panel-adapter, FHS-ATG, Self-Healing, POLKIT-AUTHORITY, dns2-migration, eventbus, packaging, or systemd implementation changes. **PR (single):** **#604** (sq `1d0a6221`) — `fix(watchdog): emit nftban_host_* vitals per schema doc 17 §F4 (PR-M2b-w1)`. Emits: `nftban_host_load_average{window}` (windows: `1m`/`5m`/`15m`), `nftban_host_memory_total_bytes`, `nftban_host_memory_available_bytes`, `nftban_host_memory_used_bytes` (derived = MemTotal − MemAvailable), `nftban_host_disk_usage_ratio{mount,device,fstype}` (per `NFTBAN_HOST_DISK_MOUNT_ALLOWLIST` env or default `[/, /var, /var/log, /var/lib/nftban]` mount policy), `nftban_host_oom_events_total` (Counter; per-tick delta from `/proc/vmstat oom_kill`). **Architecture decision (locked at PR-B scope):** EXTENDED existing `SystemCollector` — NOT a new `collector_host.go`. The `SystemCollector` already reads `/proc/loadavg`, `/proc/meminfo`, `/proc/stat`, `syscall.Statfs()`; `SystemMetrics` already exposes `LoadAvg1/5/15`, `MemTotal/MemFree/MemAvail`, etc. PR-M2b-w1 adds two new collector functions (`collectOOMEvents` reads `/proc/vmstat`; `collectMultiMountDisks` per mount-policy allowlist + `readMountInfo` parses `/proc/self/mountinfo` for device + fstype) and 6 new `promauto.New*` blocks in `metrics.go`. 5 files (+592/-2): `internal/watchdog/collector_system.go` (+147 — 2 new collectors + helpers wired into `Collect()`), `internal/watchdog/collector_system_test.go` (NEW, +239 — 11 tests covering mount-policy default/env/whitespace + multi-mount root-always/nonexistent-skipped/cardinality-bound + OOM events + Collect() integration + mountinfo parser), `internal/watchdog/metrics.go` (+65 — 6 `promauto.New*` blocks + `lastOOMEvents` counter-delta field + Update() pump section with memory-underflow guard), `internal/watchdog/metrics_test.go` (+125 — 5 tests covering host-vitals emission + OOM counter delta + OOM monotonic-down guard + multi-mount loop + memory underflow guard), `internal/watchdog/types.go` (+18/-2 — `SystemMetrics` extended with `Disks []DiskUsageEntry` + `OOMEvents uint64` both `omitempty` for byte-identical zero-value JSON output; NEW `DiskUsageEntry` struct). **No struct/interface churn:** `Watchdog` struct + `internal/watchdog/config.go` + `internal/watchdog/collector_base.go` UNCHANGED. **Behavior changes (narrow, explicit):** 6 `nftban_host_*` Prometheus metrics now emit values in production when the watchdog ticks (default cadence 5s per `WatchdogSystemInterval`); cardinality bound ~11 series/host under default mount policy; OOM counter uses per-tick delta semantics (Counter Add-only) with regression resync guard. **No other behavior change in `nftban-core` / `nftband` daemons.** Schema frozen at `1.83.0`. PR-A scope artifact pre-locked the fix shape; PR-B prerequisite check verified all 7 axes (R-10 module-isolation lint SAFE — watchdog still not a Module; R-12 typed `Status().Extra` SAFE — same reason; SystemMetrics JSON wire-format SAFE via `omitempty`; SystemCollector mutex pattern preserved; config-loader untouched — `SystemInterval` reused; no `internal/contracts/` enforcement; no CI workflow updates). **Explicit non-goals carried forward to v1.113+ as separately-gated future debt:** **PR-M2b-w2..w7** per-module emission waves (LoginMon / DDoS / BotGuard / Feed / Geoban / Suricata) — per-wave gating recommended; **PR-M2c** new nft named counters (`ddos_drop`, `whitelist_hit`, `feed_hit`, `geoban_hit`) — true schema-UNFREEZE; **PR-M2d** kernel set element annotation cookies — schema-UNFREEZE + migration plan; **PR-M3** cache v2 producer + **PR-M1** CLI formatter — depend on PR-M2/PR-M3 sequence; **§F4 metrics beyond the 6 PR-M2b-w1 targets** (CPU details, swap, inodes, IO wait, SMART, RAID, service health) — future PR-M2b sub-items; **D-LMA-1** legacy `/opt/nftban-pro:3000` decommission (sibling W1 governance lane; observation window OPEN since 2026-05-02 M-T9 cutover); **R-11** Watchdog → BotGuard `EventSafetyPressure` contract; **D-DNS-1** dns2 host migration (DESIGN-FIX side OPEN); **D-FHS-1..5**; **D-SHA-1**; **D-POL-1**; **D-DEG-1**; **D-SEC-1**; **D-TRP-1**; **D-EGM-1**; **D-PNL-1**; **D-OSH-1**; **D-GHC-1**; **D-BKT-1**. v1.112.x hotfix slot **not authorized** (latent reservation only — opened only if a v1.112.0 defect surfaces).
**Prior release lane:** v1.111.0 (2026-05-12) — V111 PR-A conservative lane on top of v1.110.0. Closes D-METR-2 watchdog emission gap via single PR-M2 fix. **Behavior change limited to: `nftban_watchdog_action_total` and `nftban_watchdog_last_action_timestamp_seconds` counters now actually advance in production when watchdog actions fire (previously registered but never incremented because `MetricsExporter.RecordAction(action)` was orphaned).** **No new metric names.** **No new metric registrations.** Schema frozen at `1.83.0`. No new metric names / labels / health JSON schema entries / nft kernel set or counter entities / portal / install API / panel-adapter / FHS-ATG / Self-Healing / POLKIT-AUTHORITY / dns2-migration / eventbus / packaging / systemd implementation changes. **PR (single):** **#602** (sq `7334e63e`) — `fix(watchdog): wire MetricsExporter.RecordAction via SetOnAction callback (D-METR-2)`. Fix mirrors the existing `onMetrics`/`SetOnMetrics` callback pattern with `onAction`/`SetOnAction` and wires it in `cmd/nftband/daemon_init.go` after the `SetOnMetrics` block: `wd.SetOnAction(func(action watchdog.Action) { d.wdMetrics.RecordAction(action) })`. Root cause was an orphaned-method gap: `MetricsExporter.RecordAction` existed at `internal/watchdog/metrics.go:366-369` but was never called from production code — `Watchdog.handleAction()` at `internal/watchdog/watchdog.go:317-325` dispatched only to the in-memory flight recorder (`Recorder.RecordAction` at `flight_recorder.go:98`), never to the Prometheus exporter. 4 files (+267/-0): `cmd/nftband/daemon_init.go` (+7), `internal/watchdog/watchdog.go` (+17 = `onAction func(Action)` field + `SetOnAction(cb)` setter + `handleAction` reads cb under RLock + dispatches after releasing the lock), `internal/watchdog/metrics_test.go` (NEW, +194 = `TestSetOnAction_{NilSafe,Fires,Replace,ConcurrentSetAndDispatch}` + `TestMetricsExporter_RecordAction_Smoke`), `internal/watchdog/executor_test.go` (+49 = `TestActionExecutor_FiresWatchdogOnAction` end-to-end chain regression). **Behavior changes (narrow, explicit):** `nftban_watchdog_action_total{action=...}` and `nftban_watchdog_last_action_timestamp_seconds{action=...}` now emit non-zero values in production when watchdog actions fire (`throttle`, `disable_optional`, `profile_cpu`, `profile_heap`, `profile_goroutine`, `free_os_memory`, `degrade_mode`). **No other behavior change in `nftban-core` / `nftband` daemons.** Schema frozen at `1.83.0`. PR-A scope artifact pre-locked the fix shape; PR-A prerequisite check verified all 7 axes (R-10 module-isolation lint SAFE — watchdog is not a Module; R-12 typed `Status().Extra` SAFE — same reason; existing `onMetrics`/`SetOnMetrics` callback pattern directly mirrorable; no config-loader changes; no `internal/contracts/` metric-inventory enforcement; no CI workflow updates; master worklog has no blocker). **PR-M4 receiver-v2 enforcement** was already DONE + LIVE in production (per `nftbanpro_cms/apps/receiver-v2/` inspection 2026-05-12 + `CURRENT_STATE.md` 2026-05-03 post-M-T9 cutover); removed from v1.111 scope. **Explicit non-goals carried forward to v1.112+ as separately-gated future debt:** **PR-M2b-w1 host vitals emission** — DEFERRED to v1.112 schema-fulfill gate (6 new `promauto.New*` registrations for `nftban_host_load_average`, `nftban_host_memory_{total,used,available}_bytes`, `nftban_host_disk_usage_ratio`, `nftban_host_oom_events_total`; names already in schema doc 17 §F4 + receiver-v2 181-entry allow-list, but adding `promauto.New*` requires explicit operator contract-fulfill judgment; proposed gate `OPEN-V112-SCHEMA-FULFILL-HOST-VITALS-SCOPE`); **PR-M2c new nft named counters** (`ddos_drop`, `whitelist_hit`, `feed_hit`, `geoban_hit`) — CROSSES FREEZE; needs schema-unfreeze gate; **PR-M2d kernel set element annotation cookies** — CROSSES FREEZE; needs schema-unfreeze gate + migration plan; **PR-M2b-w2..w7** 6-module emission waves — defer per-wave; **PR-M3** cache v2 producer + **PR-M1** CLI formatter — depend on PR-M2/PR-M3; **D-LMA-1** legacy `/opt/nftban-pro:3000` decommission decision (sibling W1 governance lane; observation window OPEN since 2026-05-02 M-T9 cutover); **R-11** Watchdog → BotGuard `EventSafetyPressure` contract; **D-DNS-1** dns2 host migration (DESIGN-FIX side OPEN); **D-FHS-1..5** FHS Authority Graph; **D-SHA-1** SELF-HEALING-AUTHORITY-REDESIGN; **D-POL-1** POLKIT-AUTHORITY impl decisions; **D-DEG-1** V108 Item 4 DEGRADED-runtime-pattern investigation; **D-SEC-1** SEC-FW-BYPASS-ALERT-GAP-001; **D-TRP-1** TRANSPORT-001; **D-EGM-1** EgressMon; **D-PNL-1** Panel architecture consolidation; **D-OSH-1** OS hardening blueprint; **D-GHC-1** optional GHCR `sha-*` retention policy; **D-BKT-1** Bucket C 14 v0.x tag historical-review (remote untouched). v1.111.x hotfix slot **not authorized** (latent reservation only — opened only if a v1.111.0 defect surfaces).
**Prior release lane:** v1.110.0 (2026-05-12) — V110 module-isolation moderate-cut lane on top of v1.109.0. Closes R-10 (module-isolation CI invariant lint) and R-12 (typed `Status().Extra` per module) from `AUDIT_190_MODULE_ISOLATION/REMEDIATION_PLAN.md` via the V110 narrow lane. **No daemon behavior change.** **No code change in `nftban-core` / `nftband` daemons.** Schema frozen at `1.83.0`. No metrics, portal, install API, panel-adapter, FHS-ATG, Self-Healing, POLKIT-AUTHORITY, dns2-migration, eventbus, packaging, or systemd implementation changes. **PRs (in merge order):** **#599** (sq `c8050d9e`) — R-10 module-isolation static-analysis CI lint enforcing three invariants: A1 distinct `ModuleName` across registered `Module` implementers (auto-discovered via `func (m *Module) Name() string`), A2 every `eventbus.NewEvent(eventbus.EventBan, ...)` publish uses the calling module's own `ModuleName` const (rejects cross-attribution + string-literal sources), A3 `Status().Extra` cross-module check (locks baseline allowlist `mode` / `suricata_available` / `tracked_ips` at v1.109.0 HEAD and blocks NEW cross-module key introductions). 2 files (`scripts/lint-module-isolation.sh` NEW shellcheck-clean + `.github/workflows/ci-architecture.yml` new step inserted after V108 Item 3 heredoc-safety using `bash scripts/...` invocation matching the V108 step style). **#600** (sq `9e26d2d6`) — R-12 typed `Status().Extra` per module: `DDoSStatusExtra` (2 fields), `PortscanStatusExtra` (3), `LoginMonStatusExtra` (18 incl. `string` + `map[string]int64` value types), `BotGuardStatusExtra` (16); each struct has a `ToExtraInfo() module.ExtraInfo` method that builds the map manually (no reflection); `Module.Status()` API, `Status.Extra` field type, and `ExtraInfo` alias are all UNCHANGED; JSON wire keys preserved byte-for-byte via struct tags. 8 files (4 production refactors + 3 new `_test.go` + 1 extended `_test.go`). After R-12, R-10's A3 lint becomes vacuous (0 direct `Extra[KEY] =` writes in any module dir; passes by construction); A1+A2 remain active. **Behavior changes:** **none.** Pure CI-invariant + module-internal type-safety refactor; all external consumers reading the JSON-marshaled `Status` see byte-identical output. **W1 MASTER_TODO refresh** remains workspace-only and is **not** bundled (may be filed in parallel as workspace doc; not a repo release payload). **Explicit non-goals carried forward to v1.111+ as separately-gated future debt:** R-11 Watchdog→BotGuard `EventSafetyPressure` contract (deferred per moderate-cut authorization; eventbus infrastructure present from PR-26 era; ~200-300 LOC estimated; needs separate `OPEN-V1XX-WATCHDOG-BOTGUARD-EVENTBUS-CONTRACT-SCOPE`); D-MET-1 Metrics + Portal Contract Enforcement Lane (18 active M-T TODOs; producer of v1.112+ portal/pro.nftban.com design evidence); D-METR-2 watchdog `nftban_watchdog_action_total` emission gap (sub-item of D-MET-1); D-DNS-1 dns2 host migration (PARTIALLY FIXED — BUG side closed in v1.108.0 PR #592; DESIGN-FIX side OPEN); D-FHS-1..5 FHS Authority Graph single-source authority (5 verified gaps); D-SHA-1 SELF-HEALING-AUTHORITY-REDESIGN (post-v1.108.0 reservation MET); D-POL-1 POLKIT-AUTHORITY impl decisions; D-DEG-1 V108 Item 4 DEGRADED-runtime-pattern investigation; D-SEC-1 SEC-FW-BYPASS-ALERT-GAP-001 security backlog; D-TRP-1 TRANSPORT-001 outbound transport adapter; D-EGM-1 V1.1XX EgressMon module (CONDITIONAL GO post-CVE-2026-41940); D-PNL-1 Panel architecture consolidation (4 deferred adapters); D-OSH-1 OS hardening blueprint SELinux/AppArmor; D-GHC-1 optional org-level GHCR `sha-*` retention policy; D-BKT-1 Bucket C 14 v0.x tag historical-review (remote untouched). v1.110.x hotfix slot **not authorized** (latent reservation only — opened only if a v1.110.0 defect surfaces).
**Prior release lane:** v1.109.0 (2026-05-12) — V109 narrow-governance lane on top of v1.108.0. Closes the 6-item narrow cleanup scope: stale docs/comment residue + dead-code deletion + README package-matrix restoration + Dependabot dependency refresh. **No daemon behavior change.** **No code change in `nftban-core` / `nftband` daemons.** Schema frozen at `1.83.0`. No metrics, portal, install API, panel-adapter, FHS-ATG, Self-Healing, POLKIT-AUTHORITY, dns2-migration, or module-isolation implementation changes. **PRs (in merge order):** **#596** (sq `46847717`) — `nftban-api-server` / `nftban-api.service` documentation-side decommissioning (4 files: `CONTRIBUTING.md` tree connector fix + `.github/workflows/release.yml` comment-only edit + `docs/systemd/TIMERS.md` HISTORICAL_KEEP strikethrough + `docs/ARCHITECTURE.md` Optional Services removal; packaging deprecated-cleanup snippets at `install/packaging/{deb,rpm}/*.inc` intentionally preserved as upgrade-time cleanup mechanism). **#597** (sq `787558f7`) — unused `internal/config/config.go` deletion (1 file, -247 lines; zero-importer pre-verified across `*.go`, `*_test.go`, build-tag files; legacy JWT-secret bootstrap from the `nftban-api-server` era; distinct from `internal/configloader/`). **#586** (sq `a3293ff1`) — README tier 0/1/2 package matrix restoration (post PR #399 regression); adds explicit per-distro install blocks for Ubuntu 24.04 LTS, Debian 12, Rocky/Alma/RHEL 9 (Tier 0); Debian 13, Rocky/Alma/RHEL 10 (Tier 1); Ubuntu 22.04 LTS (Tier 2); plus the full `## Available Packages` matrix. Fixes a latent README defect where the combined `Ubuntu 24.04 / Debian 12` heading instructed Debian 12 users to install the Ubuntu 24.04 `.deb` package. **#497** (sq `57ba0f4f`) — `aquasecurity/trivy-action` SHA-pin bump (`e368e328` → `ed142fd0`); single-workflow change to `.github/workflows/secure-go.yml`. **#578** (sq `29353171`) — `actions/dependency-review-action` v4.9.0 → v5.0.0 (major); single-workflow change to `.github/workflows/dependency-review.yml`; Dependency Review check verified SUCCESS under v5. **#495** (sq `232e2dc4`) — `actions/setup-node` v4.4.0 → v6.4.0 (two major versions); single-workflow change to `.github/workflows/project-health.yml`. **#577** (sq `bd4727ec`) — `github/codeql-action` v3.32.3 → v4.35.4 (major); five workflows updated as SARIF-uploader (`codeql.yml`, `osv-scanner.yml`, `scorecard.yml`, `secure-go.yml`, `semgrep.yml`); CodeQL Analysis (Go) verified SUCCESS under v4. **#535** (sq `267b02b8`) — Go modules bump: `github.com/fsnotify/fsnotify v1.9.0 → v1.10.1` (semver-minor; used in nftband for inotify watching) + `golang.org/x/sys v0.42.0 → v0.44.0` (patch-level); 2 files (`go.mod` + `go.sum`); full build matrix verified (Build & Test, all 6 distro RPM/DEB builds, all 8 install tests, CodeQL Go, gosec, govulncheck, osv-scanner, Go Security Analysis, Dependency Review, Validate package effective parity, Validate systemd ExecStart payload resolution). **Behavior changes:** **none.** Pure docs / dead-code removal / dependency refresh. No daemon, packaging-payload, runtime, schema, metrics, portal, install API, panel-adapter, FHS, sysusers, polkit, dns2, or DEGRADED-runtime work in this release. **W1 MASTER_TODO refresh** is workspace-only (`V1.80_ROADMAP/MASTER_TODO.md` workspace doc; **not** a repo release payload). **Explicit non-goals carried forward to v1.110+ as separately-gated future debt:** dns2 host migration execution (**D-DNS-1 PARTIALLY FIXED** — BUG side closed in v1.108.0 PR #592, but DESIGN-FIX side OPEN; dns2 host still source-installed at v1.98.2; reports `Install type: unknown`; needs P1-P8 operator attestations per `DNS2_SOURCE_INSTALL_TO_RPM_MIGRATION_SCOPE.md`); FHS-ATG single-source authority lane (D-FHS-1..5; 5 gaps verified at HEAD `1d83df9e` per `V107_FHS_AUTHORITY_GRAPH_DESIGN_CODE_GAP_CLOSURE.md`); SELF-HEALING-AUTHORITY-REDESIGN (D-SHA-1; post-v1.108.0 reservation now MET); POLKIT-AUTHORITY impl-level decisions (D-POL-1); V108 Item 4 DEGRADED-runtime-pattern investigation (D-DEG-1; lab repro across 3 host classes required); SEC-FW-BYPASS-ALERT-GAP-001 security backlog (D-SEC-1; parked, scope-ready); TRANSPORT-001 outbound transport adapter (D-TRP-1; sub-items 001A/B/C ordered); Module Isolation V1.101-FOLLOWUP (D-MOD-1; 5 R-* findings); Metrics + Portal Contract Enforcement Lane (D-MET-1; 18 active M-T TODOs); EgressMon module (D-EGM-1; CONDITIONAL GO post-CVE-2026-41940); Panel architecture consolidation (D-PNL-1; 4 deferred adapters: CyberPanel/CWP/InterWorx/Vesta); OS hardening blueprint SELinux/AppArmor (D-OSH-1; precondition now MET); optional org-level GHCR `sha-*` retention policy (D-GHC-1); Bucket C 14 v0.x tag historical-review (D-BKT-1; remote untouched). v1.109.x hotfix slot **not authorized** (latent reservation only — opened only if a v1.109.0 defect surfaces).
**Schema status:** schema remains frozen at `1.83.0` in v1.112.2. **No new metric names. No new label cardinality. No schema doc edits. No allow-list mutation. No host-vitals release content change.** v1.112.2 hotfix scope is strictly limited to one DEB packaging file: 16 lines added to `packaging/deb/postinst` inserting a `systemd-tmpfiles --create /usr/lib/tmpfiles.d/nftban.conf` call between `daemon-reload` and the Go-installer invocation; the Go daemon, all exporter scripts (including the v1.112.1 `nftban_unified_exporter_collect.sh:805` Shape A fix which remains in place), the systemd unit files, the FHS spec, and the RPM packaging are all UNCHANGED. The three v1.100.4 H4 disclosure items (ban attribution under `source=manual`, `EffectiveIdle` for Portscan/LoginMon, shared `input_syn_rate_exceeded` counter) are unchanged. PR-M2b-w1 host-vitals release content from v1.112.0 (6 `nftban_host_*` Prometheus metrics) continues to emit correctly via the unaltered Go daemon path. PR-M2c new nft named counters and PR-M2d kernel set element annotation cookies remain explicit schema-unfreeze items deferred to v1.113+ (need separate `OPEN-V1XX-SCHEMA-UNFREEZE-*` gates). **No portal, install API, panel-adapter, FHS, sysusers, polkit, dns2-migration-execution, DEGRADED-runtime, eventbus, RPM packaging, or systemd unit changes in v1.112.2.** v1.112.2 is a focused single-PR packaging hotfix restoring fresh-install operation on DEB hosts where the long-latent postinst ordering gap prevented `nftband.service` from passing systemd namespace setup.
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
