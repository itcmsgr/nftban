# NFTBan Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **History reset.** Pre-v1.79.2 releases are recorded as git tags and on
> the GitHub Releases page (`gh release list`). From v1.79.2 forward, every
> tagged release MUST have a CHANGELOG entry written before tagging.

---

## [v1.214.0] - 2026-07-02 — BotScan pattern-delimiter fix: restore 3 regex-alternation patterns (shell-only; daemon byte-identical)

**Codename:** `OPEN_BOTSCAN_PATTERN_DELIMITER_FIX` · **Impl PR:** [#988](https://github.com/itcmsgr/nftban/pull/988) (→ `08b371f4`) · **Docs:** `OPEN_BOTSCAN_PATTERN_DELIMITER_FIX_V214_{SCOPE,SCOPE_CHALLENGE,IMPL_REPORT,PR_REPORT}.md`

> **SHELL-ONLY** (`cli/lib/nftban/core/nftban_botscan.sh` + tests). **Daemon re-baseline: NO** — `nftband` + `nftban-botscan-matcher` binaries **byte-identical** (0 Go change, sha256-verified). **nft schema 1.84.0 unchanged. BotGuard default unchanged (disabled).** Fixes BotScan pattern-delimiter parsing; restores 3 shipped enabled patterns.

- **Restored patterns (dead since v1.209.1):** `EXP_CGIBIN` (`/cgi-bin/.*\.(sh|pl|cgi)`), `EXP_SQLBACKUP` (`\.(sql|sql\.gz|sql\.zip)$`), `SCAN_BACKUP_SQL` (`\.(sql|sql\.gz)$`).
- **Old behavior:** BotScan `.patterns` records are `NAME|PATTERN|MATCH_TYPE|THRESHOLD|WINDOW|BAN|ENABLED|DESCRIPTION`; the pattern field can legally contain regex alternation `|`, but the naive `IFS='|' read` split field 2 on those `|` → corrupted the record; and the internal `_BOTSCAN_PATTERNS` re-`|`-joined representation **re-corrupted** the value downstream (hot path, threshold analyze, and the prefilter build feeding the Go matcher) → RE2 skipped 3 patterns.
- **New behavior:** an **anchored file-record parser** (peel name from the front + the 6 constrained trailing fields from the back; pattern = middle, keeps its `|`); `_BOTSCAN_PATTERNS` now uses a **`\x1f`-safe internal representation** (ASCII Unit Separator) so the pattern's `|` survives every downstream re-split; a **validation guard** emits a visible `[WARN]` + skips malformed records (bad match_type/threshold/window/ban/enabled/empty-pattern) instead of silently corrupting.
- **Active/skipped:** **137 active / 3 skipped → 140 active / 0 skipped** (matcher `--check` = `3 usable, 0 skipped`; full shipped prefilter `142 usable, 0 skipped`).
- **No shipped `.patterns` format change. No Go/daemon/matcher change.** Never-ban invariants (loopback/admin/exempt/WP-admin) preserved.
- **Validation:** hermetic BotScan suite 18/18 (incl. the load→store→hot-path→prefilter downstream-re-split gate + validation-guard WARN+skip + parity + negatives); shellcheck `-x -S warning` clean; **package-native lab2 DEB + lab4 RPM PASS** (matcher 3→0 skipped, parity MATCH, negatives NO MATCH, admin never banned, resource bounds intact, daemon+matcher byte-identical).
- **Canary:** **srv4 mandatory after publish** — re-enabling the 3 patterns changes active detection (cgi-bin + SQL-backup probes on 404 become bannable), even though the daemon binary is byte-identical.

## [v1.213.0] - 2026-07-02 — SET_APPLY_SINGLE_WRITER: route sync-owned writers through FULL sync (shell-side; daemon byte-identical)

**Codename:** `SET_APPLY_SINGLE_WRITER` · **Impl PR:** [#985](https://github.com/itcmsgr/nftban/pull/985) (→ `03d6af59`) · **Docs:** `OPEN_SET_APPLY_SINGLE_WRITER_V213_{SCOPE,IMPL_SCOPE,FEED_PIPELINE_SPIKE,WRITER_SURFACE_CLASSIFICATION,IMPL_REPORT}.md`

> **Daemon re-baseline: NO** — the only `cmd/nftband` change is a comment (0 logic lines); the `nftband` binary is functionally **byte-identical**. The behavior change is **shell-side** and rides the EXISTING daemon `sync` verb. **nft schema 1.84.0 unchanged. BotGuard default unchanged (disabled).** Closes the SET_APPLY_SINGLE_WRITER P0 (sync-owned set lost-update/clobber).

- **The clobber class:** the daemon `sync` flush-replaces the sync-owned interval sets from durable sources — `blacklist_ipv4/_ipv6` (feeds `/var/lib/nftban/feeds/*.txt`, geoban `/etc/nftban/geoban.d/50-ban-*.conf`) and `whitelist_ipv4/_ipv6` (trust `/etc/nftban/whitelist.d/30-trust-*.conf`) — under `syncMutex`, while the shell modules ALSO pushed additive `add/delete element` via IPC `apply_ruleset` under `backend.mu`. Two daemon-executed writers under different mutexes → a flush-replace to a stale snapshot could **drop a just-applied element** (lost-update; not a fail-open empty-set window).
- **Affected normal-path modules:** **feeds, geoban, trust** (the writer-surface classification proved all three are the same class — SAME_SOURCE writers to sync-owned interval sets; `cmd_flush`/operator-unban = documented WATCH; `ddos_suricata`/`cmd_port`/emergency = exempt, non-sync-owned).
- **New invariant:** the daemon full `sync` is the **authoritative writer** for sync-owned interval sets. Each module writes its durable source first, then triggers a **FULL** sync. **Quick sync is never used** (it skips feeds/geoban/whitelist reconcile). Shared shell helpers: `nft_ipc_sync` (`{"quick":false}`, debounced + retry/backoff) and `nft_ipc_sync_or_apply` (on sync-IPC failure → legacy additive apply + visible `[WARN] … fell back to legacy additive apply`).
- **Legacy additive apply remains ONLY as an IPC-failure compatibility fallback.** The **daemon reject-guard is DEFERRED** to a later phased hardening after fleet convergence — the daemon still accepts legacy additive `apply_ruleset`, so old-shell↔new-daemon and new-shell↔old-daemon are both safe during rollout.
- **Validation:** PR #985 merged; CI green after an in-scope SC2120 fix; hermetic shell **12/12** + grep-guard **18/18**; shellcheck `-S warning` clean; `go build`/`go vet` rc0; **package-native lab2 DEB + lab4 RPM PASS** — **trust set-level no-clobber proof** (whitelist element survives a 2nd full sync + a daemon restart, removed on source removal), feeds/geoban full-sync reconcile counter-stable, IPC-fail fallback WARN live; admin IP never banned; validate rc0; no empty-set window.
- **Canary:** **srv4 mandatory after publish** — the live ban/allow application path changed (even though the daemon binary is byte-identical).

## [v1.212.0] - 2026-07-01 — BotScan lost-ban-signal fix (flock-guarded rename-then-consume; daemon re-baseline)

**Codename:** `BOTSCAN_LOST_BAN_SIGNAL` · **Impl PR:** [#983](https://github.com/itcmsgr/nftban/pull/983) (→ `fe75ec03`) · **Scope:** `OPEN_BOTSCAN_LOST_BAN_SIGNAL_SCOPE.md`

> **Daemon RE-BASELINED** (Go change in `internal/botguard`). **nft schema 1.84.0 unchanged. BotGuard default unchanged (disabled).** Closes the BotScan lost-ban-signal P0 (enforcement loss).

- **The race:** the producer appended ban signals to `batch_signals.jsonl` with a bare `>>` (no lock), and the daemon consumer did `os.Open` → read → `os.WriteFile(signalFile, nil)` **truncate of the LIVE file** — a signal appended in the open→truncate window was silently destroyed, with no counter (live fleet-wide via the BotGuard-disabled standalone consumer).
- **Producer fix** (`cli/lib/nftban/core/nftban_botscan.sh`): `nftban_botscan_write_signal()` appends under a shared `flock` on `${signal_file}.lock`; safe degrade if `flock` absent (still line-atomic; daemon rename is the primary guard); a real write failure is visible / returns nonzero — never a silent drop.
- **Consumer fix** (`internal/botguard/guard.go`): no truncate of the live file; under the SAME flock (held only around the O(1) op) it atomically renames `batch_signals.jsonl` → `.consuming`, releases the lock, then processes `.consuming` OUTSIDE the lock (bounded-tail / max-age / max-lines quarantine + malformed + expired + idempotent apply unchanged) and removes it on success. A prior-crash `.consuming` is recovered first each cycle. Zero loss: an append is either in the renamed file (processed) or the fresh next-cycle file — the flock forbids append-during-rename.
- **Health visibility** (`internal/botguard/types.go` + `guard.go`): new counters `BatchHandoffErrors` + `BatchStaleConsumingRecovered` (omitempty in status Extra); a broken handoff is WARN/DEGRADE-visible instead of a false PROTECTED.
- **Validation:** Go hermetic 8/8 PASS (forced-interleave zero-loss, stale-consuming recovery, handoff-error, idempotent, bounded-tail, no-live-truncate regression guard) + `go test -race` clean; shell hermetic (concurrent-writer no-corruption, safe-degrade, visible-failure) + shellcheck clean; **package-native lab2 DEB + lab4 RPM PASS** — daemon carries the fix, schema 1.84.0, validate rc0, failed units 0, BotGuard disabled; **functional signal injection + concurrent-append no-loss proven on both distros**.

## [v1.211.1] - 2026-06-30 — Trust-Feeds status label truth (shell-only; daemon byte-identical)

**Codename:** `STATUS_LABEL_TRUTH` · **PR:** [#980](https://github.com/itcmsgr/nftban/pull/980) (→ `3e29f913`) · **Scope:** `OPEN_TRUSTFEEDS_LABEL_SHELL_FIX_SCOPE.md`

> **Shell-only** (`cli/lib/nftban/cli/cmd_status.sh` + one hermetic test). **`nftband` daemon BYTE-IDENTICAL** (source-proven — 0 `.go` change). **No daemon re-baseline. nft schema 1.84.0 unchanged. BotGuard default unchanged (disabled).**

### Fixed
- **`nftban status` no longer renders Trust-Feeds as a false `NOT INSTALLED`** when `nftban-core` is installed. The block used a bare `command -v nftban-core`, which fails because the binary ships in `/usr/lib/nftban/bin` (off `$PATH`) → the whole block was skipped → default `NOT INSTALLED`. Now resolves `${NFTBAN_LIB_DIR}/bin/nftban-core` → `/usr/lib/nftban/bin/nftban-core` → `command -v nftban-core`; genuinely absent → `NOT INSTALLED`.
- **Enabled-count truth:** replaced `grep -c "enabled"` on the human text (which false-matched the help line "…apply all enabled" and never matched the `[✓]/[✗]` markers) with `trust list --json` counting `"enabled": true` — **0 enabled → `DISABLED`**, **N enabled → `ENABLED (N feeds)`**, **malformed/empty/unreadable JSON → `UNKNOWN`** (not a false `DISABLED`).

### Validation
- Hermetic test (`cli_trustfeeds_label_truth_v211_1_test.sh`) extracts the REAL shipped block and drives it (2→`ENABLED (2 feeds)`, 0→`DISABLED`, absent→`NOT INSTALLED`, malformed→`UNKNOWN`, no false positive from literal "enabled" text). **Package-native lab2 DEB + lab4 RPM PASS** — both now render `Trust Feeds......... DISABLED` (json enabled-count 0, agrees), `nftban validate` rc0, schema 1.84.0, BotGuard disabled, daemon carries no change.

### Notes
- Producer `cmd/nftban-core/cmd_trust.go` unchanged (`--json` already present).
- **Explicitly out of scope** (separate lanes): BotScan lost-ban-signal, `SET_APPLY_SINGLE_WRITER`, pattern-delimiter, whitelist-drift, opqueue, SCDV/security-hardening, RBL/Suricata, Aho-Corasick, MalwareGuard.

## [v1.211.0] - 2026-06-30 — Health-truth core: LoginMon watcher respawn + nft-read unknown contract (daemon re-baseline)

**Codename:** `HEALTH_TRUTH_CORE` · **PR:** [#978](https://github.com/itcmsgr/nftban/pull/978) (→ `edb3ed87`) · **Scope:** `OPEN_STABILITY_HOTFIX_GO_HEALTHTRUTH_IMPL_SCOPE.md`

> **Daemon RE-BASELINED** (Go change in `internal/loginmon` + `internal/validator` — `nftband` NOT byte-identical with v1.210.0; declared openly). **No nft schema change (1.84.0). No nft topology change. BotGuard default unchanged (disabled).** Closes the two P0 "health-truth / lies green" defects.

### Fixed
- **LoginMon journal watcher no longer dies silently** (`BUG-LOGINMON-JOURNAL-WATCHER-NO-RESPAWN`): `runJournalWatcher` is now a **bounded-backoff supervisor** (mirrors the file-watcher pattern; reuses `watcherBackoffMin/Max`/`watcherHealthyReset`, ctx-aware). When `journalctl -f` exits (journald restart, EOF, OOM), the watcher respawns — the **daemon does NOT restart**, only the watcher. Login detection no longer goes dark while status reads protected.
- **Runtime input-source state is no longer a stale boot snapshot**: the journal source surfaces `OK` / `WATCHER_DEGRADED` (transient restart) / `WATCHER_DOWN` (≥3 consecutive short fails) / recovered, via `Status().Extra.InputSources`.
- **Health validator no longer collapses nft set-read errors into a semantic zero** (`HEALTH_FALSE_SAFE_FIX`): a validator-local 3-valued reader `(count, exists, unknown)` (mirrors `internal/metrics/evidence_sets.go` without importing it — no package cycle) backs the BotGuard verdict and the enforcement-critical `blacklist_manual` sub-health. A failed read now surfaces **`unknown` → WARN/DEGRADED** (via a `SeverityWarn`/`CodeModuleDegraded` Finding; `Effective` unset / `State:"unknown"`) instead of a false `idle`/clean.
- **Empty and disabled/not-installed modules remain neutral** — the `zero = NEUTRAL` rule is preserved (only a *failed read* degrades, never a genuinely-empty set).
- Minimal health/status visibility wiring (Findings + InputSources); the full status/health truth-matrix (TODO-30/31) is NOT in this lane.

### Validation
- Go build / vet / test / `-race` GREEN (lab2). **Package-native lab2 DEB + lab4 RPM PASS** — install COMMITTED 16/16; `nftban validate` rc0; `nftban health` no false-WARN on clean hosts (blacklist_manual reads enforcing/primed, not false-unknown); `nftban status` renders; NFTBan failed units 0; nft schema 1.84.0; VERSION 1.210.0 (pre-bump); BotGuard disabled; installed daemon carries the fix.
- **Journal-watcher kill/respawn simulation: PASS both labs** (daemon NRestarts 0, watcher respawned `WATCHER_DEGRADED → DOWN/respawn → RESPAWNED`, detection recovered). Set-read unknown behavior hermetically/`-race` proven.

### Notes
- **Explicitly out of scope** (separate lanes): Trust-Feeds label, BotScan lost-ban-signal, `SET_APPLY_SINGLE_WRITER`, pattern-delimiter, whitelist-drift, opqueue atomicity, SCDV/security-hardening, RBL/auditor/central-comms/Suricata, Aho-Corasick, MalwareGuard, docs/site/wiki.
- PR #978 merged CI-green (53 pass / 0 fail; all 10 required contexts SUCCESS); one in-PR gosec G104 (unhandled `Kill()` at shutdown) fixed minimally.

## [v1.210.0] - 2026-06-29 — BotScan admin/management never-ban exemption guard (F2; daemon re-baseline)

**Codename:** `BOTSCAN_ADMIN_IP_EXEMPTION` · **PR:** [#974](https://github.com/itcmsgr/nftban/pull/974) (→ `30781ca9`) · **Scope:** `BOTSCAN_ADMIN_IP_EXEMPTION_SCOPE.md`

> **Daemon RE-BASELINED (Go change — `nftband` is NOT byte-identical with v1.209.3; declared openly). No nft schema change (1.84.0). No MemoryMax change, no BotGuard default flip.** Establishes a new central admin/management/live-session **never-ban invariant** at the durable ban-apply boundary.

### Added / Fixed
- **New central never-ban invariant:** `Backend.Ban()` — the single choke point every ban path funnels through (BotScan batch-signal consumer, EventBus module bans, persistent escalation, manual CLI, BotGuard enforcer) — now **refuses exempt IPs before writing to the drop-enforced `blacklist_manual_{v4,v6}` sets**. Previously, admin/session safety was firewall **rule-ordering only**, not a never-ban invariant: the durable Go apply boundary had no whitelist/management guard, so BotScan/automated paths could write the admin IP into `blacklist_manual` (F2, from the post-v1.209.2 health check; observed on srv1+srv2).
- **Exemption resolver** (`internal/nftbackend/exemption.go`): range-aware (CIDR), **v4/v6 parity**. Sources = `whitelist.d` (operator / live-session `00-session` / system `00-system`, CIDR-aware) + `safety.DetectSystemIPs` (server/gateway/dns/loopback/current-SSH) + **live established inbound SSH peers** (`/proc/net/tcp{,6}`) + optional `NFTBAN_MANAGEMENT_IPS`. TTL-cached; non-blocking initial load.
- **Exemption does NOT widen accept/whitelist traffic** — it only prevents a DROP of the operator's own IPs; it adds no allow rule. Firewall rule order is kept as defense-in-depth (a third layer), not the primary guarantee.
- **Scanner-side exemption list is defense-in-depth, NOT the authority:** the daemon publishes the resolved exempt list to a scanner-readable file; the unprivileged BotScan scanner consults it (exact match, no nft read) to suppress signals early. The daemon `Backend.Ban()` guard is the authoritative never-ban enforcement.

### Notes
- **Fail-safe:** a resolver failure NEVER blocks a legitimate ban (it falls back to no-exemption + rule order). Non-exempt IPs ban exactly as before; v4 and v6.
- **Validation:** Go tests (`internal/nftbackend/exemption_test.go`) + shell (`botscan_admin_ip_exemption_test.sh`); **lab2 (DEB) + lab4 (RPM) package-native PASS** — negative control (non-exempt bot reaches `blacklist_manual` v4 and v6), positive controls (whitelisted/CIDR/management/live-session/system IPs never enter `blacklist_manual`, v4+v6), fail-safe and anti-regression (BotScan consumer alive, manual ban of non-exempt works, daemon never crashed). `nftban validate` rc0, failed units 0, BotGuard unchanged (disabled), nft schema 1.84.0.
- **PR #974 merged cleanly** (CI green; scope = 7 files, no VERSION/schema/MemoryMax in the impl PR). Not addressed here: pattern-delimiter (remains blocked until this ships and live canary/fleet prove the invariant), spool/memory, whitelist-drift.

## [v1.209.3] - 2026-06-28 — BotScan collector spool-OOM: off-tmpfs disk-backed spool + bounded lifecycle (shell/packaging-only)

**Codename:** `BOTSCAN_COLLECTOR_SPOOL_OOM` · **PR:** [#972](https://github.com/itcmsgr/nftban/pull/972) (→ `d21ca763`) · **Scope:** `V209_3_BOTSCAN_COLLECTOR_SPOOL_OOM_SCOPE.md`

> **Shell/packaging-only; `nftband` daemon unchanged (byte-identical, source-proven — no `.go` change). No schema change (nft 1.84.0). `MemoryMax=256M` unchanged. Preserves v1.209.0 ban-path, v1.209.1 restored detection / bounded scan, and v1.209.2 gather streaming.**

### Fixed
- **Fixes the REMAINING BotScan collector OOM after v1.209.2.** v1.209.2 removed the bash command-substitution slurp (per-source memory), but the surviving failure was an **unbounded RAM-backed spool** under `/run/nftban/botscan`: the only cap was per spool FILE (10 MB) with **no total-directory bound**, the scanner never reaped consumed files, and `/run` is **tmpfs** — whose pages are unevictable and charged to the collector's 256 MB cgroup. On heavy hosts the summed spool crossed the cap and oom-killed the collector every cadence (srv3: 634 MB / 138 files / **121 OOM-kills in a day** on official v1.209.2).
- **Spool moved off tmpfs to disk-backed `/var/lib/nftban/botscan/spool`** (collector + scanner). Disk pages are reclaimable page-cache the kernel drops before OOM — this removes the OOM mechanism. The legacy `/run/nftban/botscan` is cleaned up once on startup (guarded to the exact legacy path).
- **Added a total spool-directory cap + backpressure** (`BOTSCAN_SPOOL_TOTAL_MAX_BYTES`, default 1 GiB): over-cap → the collector skips appends for the cycle **without advancing source offsets** (nothing dropped; resumes next cycle), surfaced visibly — not a silent drop.
- **Added cursor-aware reaping** — the scanner reaps each spool file once fully consumed (offset ≥ size), gated to files under the spool dir only (never a real access log), race-free via a shared processor lock taken by both the collector and the scanner.
- **Removed the blind per-file `tail -c` trim** that shortened a file the scanner cursor was mid-read on (cursor desync). Bounding is now total-cap + reaping — neither moves bytes under a live cursor.
- **`nftban health botscan` now exposes spool pressure** (a `Spool:` line) and reports DEGRADED under backpressure.

### Notes
- **No daemon change** (`nftband` byte-identical, source-proven — no `.go` changed). **No schema change** (nft 1.84.0). **`MemoryMax=256M` unchanged** — the fix is off-tmpfs + bounded lifecycle, not a memory increase.
- **Validation:** hermetic `botscan_spool_oom_v2093_test.sh` **14/14** (off-tmpfs default, total-cap backpressure, legacy cleanup, reaping with both safety gates, cursor preservation, unit/tmpfiles wiring); `botscan_read_authority_v178_test.sh` **13/13**; **lab2 (DEB) + lab4 (RPM) package-native PASS** (real collector unit `result=success` writing the disk-backed spool, `nftban health botscan` shows the `Spool:` line, validate rc0, failed units 0, schema 1.84.0). A measurement fix landed in-PR: spool footprint is summed from file content (`find -type f`) rather than `du` (which counted directory metadata and tripped a small cap on XFS).
- **srv3 live canary runs after publish, not in release-prep.** The three `|`-delimiter-broken alternation patterns (`OPEN_BOTSCAN_PATTERN_DELIMITER_FIX`) and the admin-IP ban exemption (`OPEN_BOTSCAN_ADMIN_IP_EXEMPTION_SCOPE`) remain **separate parked lanes — NOT addressed here.**

## [v1.209.2] - 2026-06-28 — BotScan collector gather-OOM streaming fix (shell-only)

**Codename:** `BOTSCAN_COLLECTOR_GATHER_OOM` · **PR:** [#970](https://github.com/itcmsgr/nftban/pull/970) (→ `faeac35c`) · **Scope:** `BOTSCAN_COLLECTOR_GATHER_OOM_SCOPE.md`

> **Shell-only; `nftband` daemon unchanged (byte-identical, source-proven). No schema change (nft 1.84.0). Preserves v1.209.0 BotScan ban-path restoration and v1.209.1 restored detection / bounded scan.** The Track-A closure layer.

### Fixed
- **Fixes BotScan collector gather OOM on heavy hosts by streaming incremental reads directly to the spool instead of storing per-source chunks in bash variables.** The gather captured each source's incremental read into a shell variable (`new="$(nftban_http_read_incremental "$canon")"`), holding up to `BOTSCAN_COLLECTOR_MAX_BYTES` per source; across many DirectAdmin sources the cumulative bash memory crossed the collector's 256 MB cgroup cap → intermittent OOM. The read now streams straight to the spool file.
- **Preserves `nftban_http_read_incremental` cursor semantics** — the inode/offset state is persisted inside that function (statefile via tmp+mv) independent of where its stdout goes, so streaming changes memory only, not cursor/rotation/crash behavior.

### Notes
- **srv3 validation: collector peak reduced from 183–213 MB / intermittent OOM to 112 MB max across 6 successful cycles under unchanged MemoryMax=256M** (no swap added); backlog progressing; fresh BotScan ban path still applies with `source_index=botscan`; admin not banned; failed units 0.
- **No schema change; daemon unchanged.** No MemoryMax change; no `BOTSCAN_COLLECTOR_MAX_BYTES` change; no matcher / source_index / threshold / firewall change.
- **Validation:** hermetic `botscan_collector_gather_stream_v2092_test.sh` 15/15 (cursor advance, no-dup, no-loss across cycles, rotation, empty-safe, large-source bounded to MAX_BYTES); **lab2 (DEB) + lab4 (RPM) package-native PASS** (collector streams, gather `result=success`, helper `--check` 152 usable/3 skipped intact, validate rc0, schema 1.84.0).

## [v1.209.1] - 2026-06-27 — BotScan prefilter correctness + bounded Go matcher (helper-first)

**Codename:** `BOTSCAN_GO_MATCHER` · **PR:** [#968](https://github.com/itcmsgr/nftban/pull/968) (→ `8205e23a`) · **Scope:** `BOTSCAN_GO_AHOCORASICK_MATCHER_SCOPE.md`

> **Helper-first; `nftband` daemon byte-identical (source-proven — `cmd/nftband` does not import the matcher).** nft schema 1.84.0 unchanged; no validator-JSON change. BotGuard remains disabled unless explicitly enabled. **Daemon ban-path behavior is unchanged from v1.209.0.**

### Fixed
- **Fixes BotScan prefilter failure caused by invalid pattern-file parsing.** The pattern file uses `|` as its field delimiter, but 3 patterns contain `|` alternation; the shell `IFS='|' read` mis-split them into invalid regex, so `grep -E -f` exited rc=2 and the prefilter (under `2>/dev/null || true`) silently returned empty — suppressing pattern-based BotScan detection where the prefilter is active.
- **Replaces the fragile shell regex prefilter with a bounded Go hybrid matcher helper** (`nftban-botscan-matcher`: Aho-Corasick literal prefilter + RE2 confirm). Bounded memory fits the BotScan collector's `MemoryMax=256M` cgroup cap — fixes the srv3 collector OOM blocker.
- **Restores pattern-based BotScan detection for the 152 valid patterns.** **This may increase BotScan bans because previously suppressed detections are now active.**
- The shell falls through to **unfiltered pass-through** on any helper problem (detection preserved) — it never silently empties.

### Notes
- **Three delimiter-broken alternation patterns remain skipped visibly and are tracked under `OPEN_BOTSCAN_PATTERN_DELIMITER_FIX`** (155 corpus → 152 active; the 3 are not activated here).
- **No schema change; BotGuard remains disabled unless explicitly enabled.** No source_index / firewall / ban-path / threshold / action change.
- **Validation:** `go test ./internal/botscanmatch` green (parity vs grep-equivalent on the real 152-pattern corpus, anchor extraction, RE2 fallback, skip-count, malformed handling); **lab2 (DEB) + lab4 (RPM) package-native PASS** — helper installed, `--check` reports "152 usable, 3 skipped", restoration proof (old grep rc=2/empty vs helper produces candidates), helper == grep(valid) byte-identical, validate rc0, failed units 0, schema 1.84.0, BotGuard disabled.

## [v1.209.0] - 2026-06-27 — BotScan signal-consumer un-gate + enforced/provenanced ban path (daemon-Go)

**Codename:** `BOTSCAN_SIGNAL_CONSUMER_GATING` · **PR:** [#966](https://github.com/itcmsgr/nftban/pull/966) (→ `dc2c37fc`) · **Scope:** `BOTSCAN_SIGNAL_CONSUMER_GATING_SCOPE.md`

> **Daemon-Go (re-baselined).** Fixes BotScan batch-signal consumption when BotGuard is disabled, without enabling BotGuard. **nft schema 1.84.0 unchanged; no validator-JSON change. BotGuard remains disabled unless explicitly enabled. No enforcement-topology / RBL / portscan / CLI-parity / updater change.**

### Fixed
- **Fixes BotScan batch-signal consumption when BotGuard is disabled.** BotScan (Clock-3 shell) produces batch ban signals, but the only consumer lived inside BotGuard's classifier tick — which never ran when BotGuard was disabled, so BotScan bans were inert. A standalone, bounded batch-signal consumer now runs even with BotGuard classification off (no suspect-read / FCrDNS / classifier loop started).
- **Adds stale backlog quarantine / bounded drain to prevent applying old queued BotScan signals.** A mandatory max-age cutoff + bounded tail-drain: stale signals are expired/quarantined, never flood-applied; the daemon never slurps the whole queue file.
- **Routes fresh BotScan bans to enforced `blacklist_manual_{ipv4,ipv6}` sets with `source_index` provenance** (`source=botscan`) — rather than `http_bot_ban`, which is not drop-enforced when BotGuard is disabled. The enabled path is unchanged.
- **OpQueue source propagation fixed at the apply boundary** — `EnqueueBan`'s source now reaches `source_index` after a successful add (for persisted blacklist sets), instead of being lost and tagged `unknown` by reconcile. Fixes provenance for every producer, not just BotScan; no module-init timing dependency.

### Notes
- **Daemon re-baselined** (Go: `internal/opqueue`, `internal/botguard`, `cmd/nftband/daemon_init.go`). No shell logic. **No schema change; BotGuard remains disabled unless explicitly enabled.**
- **Validation:** `go test ./internal/opqueue ./internal/botguard` green (apply-boundary records `source=botscan`; route v4/v6; stale-quarantine; suppression; enabled-path regression preserved) + CI 53/53; **lab2 (DEB) + lab4 (RPM) package-native PASS** — fresh → `blacklist_manual` + kernel drop + `source_index source=botscan`, stale → quarantined, integrity (schema 1.84.0, BotGuard disabled, validate rc0).
- **No fleet rollout in this release.** Canary srv4 first (stale backlog must expire/quarantine; only fresh signals apply), then expansion.

## [v1.208.0] - 2026-06-26 — BotScan trend-history / reporting-truth (shell-only)

**Codename:** `BOTSCAN_TREND_HISTORY` · **PR:** [#963](https://github.com/itcmsgr/nftban/pull/963) (→ `a9b5956c`) · **Scope:** `V208_BOTSCAN_PRESSURE_TREND_SCOPE.md`

> **Shell-only.** Adds durable BotScan pressure/mode history without changing detection, firewall, daemon, or schema. **`nftband` NOT re-baselined (byte-identical with v1.207.0); nft schema 1.84.0 unchanged. No enforcement/topology/ban/RBL/portscan/BotGuard/CLI-parity/updater/central-comms change.** Reuses the watchdog host-vitals trend — no duplicate CPU/RAM store.

### Added
- **Durable trend** — `/var/lib/nftban/botscan/trend.jsonl`: one JSON record per meaningful run (gated by recording-discipline), bounded retention (`BOTSCAN_TREND_RETENTION`, default 500) + flock + atomic trim. Reuses the watchdog trend for host load/mem/iowait; carries only BotScan's decision + a cheap `load_ratio`.
- **`nftban health botscan --history`** — summarizes scan-mode / health-state frequency, budget-hit hosts, backlog-GROWING hosts, last OK / last DEGRADED scan; tolerates corrupt/partial trend lines.
- **`NO_INPUT_DISCOVERED`** health state at the "No access log found" path (fixes non-web hosts' perpetual `NO_RUN_YET`). **Zero-progress dedupe** — consecutive identical no-progress states (NO_INPUT_DISCOVERED or empty-log DEGRADED_INPUT_BLIND) collapse to one trend record (no per-cycle spam).

### Notes
- State classification: `NO_INPUT_DISCOVERED` = no log source discovered; `DEGRADED_INPUT_BLIND` = log source exists but the scan makes zero useful progress. Both are **not clean**; neither is a crash; repeated zero-progress states dedupe.
- **Validation:** hermetic 21/0 (incl. an integration test driving `process_logs` with zero discovery → NO_INPUT_DISCOVERED + dedupe) + v207 adaptive regression 29/0 + existing BotScan regressions (nofork-parity, deadline-rotation, request-class incl IPv4/IPv6) PASS; **lab2 (DEB) + lab4 (RPM) package-native PASS** (build 28262735223) — lab2 trend accrual + `--history`; lab4 no-web → not-clean, not-crash, no spam.
- **No fleet rollout in this release.** Unified Track-A target → `v1.207.0 → v1.208.0`.

## [v1.207.0] - 2026-06-26 — BotScan smart-adaptive (pressure/backlog/mode/health, shell-only)

**Codename:** `BOTSCAN_SMART_ADAPTIVE` · **PR:** [#961](https://github.com/itcmsgr/nftban/pull/961) (→ `94b61b1b`) · **Scope:** `V207_BOTSCAN_SMART_ADAPTIVE_SCOPE.md` · **Report:** `V207_BOTSCAN_SMART_ADAPTIVE_IMPL_REPORT.md`

> **Shell-only.** Makes BotScan load-aware, backlog-aware, and operator-visible without rebuilding existing machinery. **`nftband` NOT re-baselined (no `.go`/`cmd/`/`internal/` change — byte-identical with v1.206.2); nft schema 1.84.0 unchanged. No enforcement/topology/ban/RBL/portscan/BotGuard/CLI-parity/updater-timer/central-comms change.** Reuses the existing watchdog pressure trend, `/proc/loadavg`, the BotScan forward-cursor backlog, the v1.187 candidate prefilter, and the soft budget — no new collectors, no duplicate host-vitals store.

### Added
- **Smart-adaptive control loop** (`nftban_botscan_adaptive.sh`): a deterministic pressure score (load÷nproc + watchdog `load_5m/mem/iowait` + last runtime÷budget + last-run budget-hit) → `pressure_state` (NORMAL/ELEVATED/HIGH/CRITICAL); cursor-lag → `backlog_state` (DRAINING/STABLE/GROWING/STARVED); → `scan_mode` (FULL/PREFILTERED/FAIR_SHARE/SURVIVAL) that modulates the existing per-file cap (FAIR_SHARE halves, SURVIVAL quarters). FULL/PREFILTERED preserve shipped detections; only SURVIVAL reduces coverage — explicitly declared, never reported clean.
- **Health model** (`nftban health botscan`): `OK_SCANNED_NO_BOTS`/`OK_SCANNED_BOTS_FOUND`/`WARN_PARTIAL_PROGRESS`/`DEGRADED_BUDGET_HIT`/`DEGRADED_BACKLOG_GROWING`/`DEGRADED_INPUT_BLIND`/`DEGRADED_PRESSURE_THROTTLED`/`DISABLED_BY_CONFIG`/`ERROR_RUNTIME_FAILURE`. **Invariant: 0 scanned lines is NEVER "clean"** — disabled, blind, and pressure-throttled states are all visible, not silent.
- **Recording-discipline:** a disabled+never-run module writes NO run-state/counters (no noise); a disabled module with a prior run records `DISABLED_BY_CONFIG` (not clean); counters accumulate as `*_total` in an additive `botscan/runstate.json`. Operator advisory (incl. "primary pressure may be the web/db stack").

### Notes
- 4 additive `declare -F`-guarded seams in `nftban_botscan.sh` (no-op if the module is absent); `nftban health botscan` dispatch. IPv4/IPv6 parity preserved. Honest residuals: `lines_seen≈lines_scanned` (post-prefilter, documented); per-line already-banned-skip is a future refinement (the bounded cap already throttles the bash matcher).
- **Validation:** hermetic 29/0 + existing BotScan regressions (nofork-parity, deadline/rotation, request-class incl. IPv4/IPv6) PASS; **lab2 (DEB) + lab4 (RPM) package-native PASS** (build 28252680518) — installed controller matrix 15/15, cap modulation, recording-discipline, `nftban health botscan` live, 100k-line flood benchmark (FULL/PREFILTERED detection-equivalence). dns4 read-only busy-host confirm only (web+db 143% primary load; BotScan bounded).
- **No fleet rollout in this release.** Production fleet remains **v1.203.0**; unified Track-A retargeted to `v1.203.0 → v1.207.0` (absorbs the held v1.206.2 hop; dns4 rolled last/deferred if still under flood).

## [v1.206.2] - 2026-06-26 — Stats count-reconcile + freshness + label hotfix (reporting-only)

**Codename:** `STATS_COUNT_RECONCILE` · **PR:** [#959](https://github.com/itcmsgr/nftban/pull/959) (→ `5b1a1fe9`) · **Report:** `V206_2_STATS_COUNT_RECONCILE_IMPL_REPORT.md`

> **Reporting/stats-only.** Completes the stats-dashboard clarity work after v1.206.1's provenance fix. **No firewall/ban/topology/daemon change (`nftband` byte-identical with v1.206.1); nft schema 1.84.0 unchanged.** An audit-suspected IPv6 producer omission was **retracted** — `nftban stats` counts IPv6 manual bans correctly after a valid collect; the "IPv6=0 right after a ban" was **cache staleness** (snapshot timing), now made explicit.

### Fixed (reporting)
- **Freshness:** the cache-hit `Data source` stays `UNIFIED CACHE` with a new **Snapshot** line (`collected Ns ago`) + an explicit note that a ban added since the last collect (either family) may not appear until the next collection.
- **Count reconciliation:** the by-source breakdown now reconciles to `New ban events` via an **`Other/Unclass`** bucket (= total − Σ by-source); if by-source exceeds the total, a different-basis note is shown. No more unexplained `17 vs 9`.
- **Label disambiguation:** ambiguous bare `Manual` → `Operator/CLI` (By source) and `MANUAL` → `OPERATOR/CLI` (BANS BY MODULE) — the manual/CLI ban *source*, not the manual-hash *set*; operator-manual vs persistent/loginmon vs adopted stays in the PROTECTION BREAKDOWN provenance line.
- **Active-bans sample:** prints `showing X of N`, lists all when N≤10, and reads BOTH families (interval + manual hash, IPv4 + IPv6) so IPv6 active bans appear.

### Notes
- Shell/stats-only (`cli/lib/nftban/core/nftban_stats_format.sh` + new test). No `source_index` rewrite; no enforcement/topology/LoginMon/RBL/portscan/CLI-parity/updater-timer/central-comms change. IPv4/IPv6 enforcement remains kernel-proven (v1.206.1 audit).
- **Validation:** hermetic 17/0 + v1.206.1 provenance regression 16/0; **lab2 (DEB) + lab4 (RPM) package-native PASS** (build 28199925166) — controlled v4+v6 ban → fresh/live path → IPv6 manual-set `0`→`1` visible.
- **No fleet rollout in this release.** Production fleet remains **v1.203.0**; unified Track-A retargeted to `v1.203.0 → v1.206.2`.

---

## [v1.206.1] - 2026-06-25 — Stats manual-attribution + count-clarity hotfix (reporting-only)

**Codename:** `STATS_MANUAL_ATTRIBUTION` · **PR:** [#957](https://github.com/itcmsgr/nftban/pull/957) (→ `f3d6b95b`) · **Evidence:** `V206_FLEET_STATS_MANUAL_ATTRIBUTION_FINDINGS.md`

> **Reporting/stats-only.** `nftban stats` displayed LoginMon persistent-offender durable bans as operator **"Manual"** (since v1.203.0 routed single-IP `blacklist.d` entries into the `blacklist_manual_*` hash set). This hotfix corrects the *attribution and labels only* — **no firewall/ban/topology behavior change, no daemon change (`nftband` byte-identical with v1.206.0), nft schema 1.84.0 unchanged, no `source_index.jsonl` rewrite.**

### Fixed — manual-ban attribution
- LoginMon persistent-offender durable bans **no longer display as operator "Manual."** The `blacklist_manual_*` set name is **not** treated as provenance by itself.
- Provenance split (PROTECTION BREAKDOWN → "Manual-set by:"): **operator-manual** = `99-manual.conf` · **persistent/loginmon** = `30-persistent-offenders.conf` · **adopted/unknown** = remainder. Precedence: 99-manual wins; no double-count; adopted clamps ≥0.

### Clarified — count semantics
- `New bans (period)` → **`New ban events`** with a note that events include re-bans and are **not** the live-set size (distinguishes event count vs unique-IP count vs live-set count).
- `Modules:` → **`By source (ban events, this period)`**; BANS-BY-MODULE note points to the provenance line.
- **CURRENT ACTIVE BANS** sample now reads the **manual hash set** as well as the interval set (so a host whose only live bans are persistent-offenders no longer shows an empty sample); explicit "sample unavailable" reason otherwise.

### Notes
- Shell/stats-only (`cli/lib/nftban/core/nftban_stats_format.sh` + new test) — no `.go`/daemon change; schema 1.84.0; no firewall/ban/topology change; no `source_index` rewrite; no RBL/portscan/CLI-parity change; the updater inhibited-timer warning is parked separately (not in this release).
- **Validation:** hermetic 16/0; **lab2 (DEB) + lab4 (RPM) package-native PASS** (build 28194777988) — live smoke: lab2 `operator-manual: 0 · persistent/loginmon: 386 · adopted: 20`, lab4 `0 · 133 · 0`.
- **No fleet rollout in this release.** Production fleet remains **v1.203.0**; unified Track-A retargeted to `v1.203.0 → v1.206.1`.

---

## [v1.206.0] - 2026-06-25 — RBL state + visibility hardening (resolver/provider false-negative fix)

**Codename:** `RBL_STATE_AND_VISIBILITY` · **PR:** [#955](https://github.com/itcmsgr/nftban/pull/955) (→ `fffc9712`) · **Scope:** `V206_RBL_STATE_AND_VISIBILITY_SCOPE.md`

> **What:** fixes a P0 RBL false-negative where resolver/provider failures were folded into CLEAN, and makes degraded/blind RBL state visible to operators. **Shell-only — the `nftband` daemon is NOT re-baselined; nft `SchemaVersionCurrent` unchanged (1.84.0).**
>
> **No fleet rollout in this release.** Production fleet remains **v1.203.0**; v1.204 portscan + v1.205 CLI parity + v1.206 RBL are on main but **not fleet-live** until a separate unified Track-A rollout (`v1.203.0 → v1.206.0`).

### Fixed — RBL 7-state resolver/provider model
- `LISTED · CLEAN · ERROR · RESOLVER_BLOCKED · TIMEOUT · SKIPPED_IPV4_ONLY_ZONE · UNSUPPORTED_IPV6_ZONE`. **CLEAN now means a successful negative lookup ONLY** — non-CLEAN states never increment the clean count and never project as fully protected (closes the false-negative).
- **Spamhaus block-codes `127.255.255.252/.253/.254` → `RESOLVER_BLOCKED`** (carved out before the blanket 127/8 listed check — not listed, not clean).
- Resolver/provider classification: `REFUSED → RESOLVER_BLOCKED`, `SERVFAIL → ERROR`, `timeout → TIMEOUT`, authoritative `NXDOMAIN → CLEAN`, authority-failed/no-resolver → `ERROR` (never clean).
- **IPv6 honesty:** un-reversible IPv6 → `UNSUPPORTED_IPV6_ZONE`; operator-declared IPv4-only zones (`NFTBAN_RBL_IPV4_ONLY_ZONES`) → `SKIPPED_IPV4_ONLY_ZONE` — distinct states, never counted clean.

### Visibility
- `nftban rbl check --json` exposes per-state counts + a `degraded` total (state, not just a clean/listed boolean); human output never says "clean" for a degraded result.
- `nftban health rbl` reads the **authoritative** `/var/cache/nftban/rbl` state store (fixes a key/state-path drift to a stale `/var/log` reader) and surfaces **DEGRADED** / "not fully protected" when RBL is blind.
- `rbl check` persists a 3-way state (listed/degraded/clean) — a degraded check is no longer recorded clean.

### Notes
- Shell-only (`cli/lib/nftban/core/nftban_rbl.sh`, `cli/cmd_rbl.sh`, `cli/cmd_health_analysis.sh` + new test) — no `.go`/daemon change; nft schema 1.84.0 unchanged. No portscan/CLI-parity/BotGuard change; no email/webhook/auditor/central-comms work; no RBL-timer default-enable flip.
- **Validation:** hermetic suite 19/0 + v1.150 regression 17/0; **lab2 (DEB) + lab4 (RPM) package-native PASS** (build 28185397692).

---

## [v1.205.0] - 2026-06-25 — CLI surface parity fix (registry/completion alignment + parity guard)

**Codename:** `CLI_SURFACE_PARITY_FIX` · **PR:** [#953](https://github.com/itcmsgr/nftban/pull/953) (→ `3a457c62`) · **Source audit:** `FULL_CLI_SURFACE_PARITY_AUDIT.md`

> **What:** aligns the CLI command-surface metadata (registry + bash-completion) with the runtime shell dispatch (the source of truth) and adds a CI guard to keep them in sync. **Metadata/completion/CI-only — no product behavior change; the `nftband` daemon is NOT re-baselined; nft `SchemaVersionCurrent` unchanged (1.84.0).**

### Fixed (command-surface truth)
- **`commands.registry.yml` aligned with shell dispatch:** added the real `firewall` subcommands that were missing — `status`, `rebuild`, `reset`, `conflicts`, `restore` (target enum csf/fail2ban/firewalld/ufw), `record`; added top-level `export` (real dispatch arm, alias of `stats export`).
- **Aliases/deprecated commands marked:** `trust` ← `cloudflare` (legacy top-level alias); `geoban update` ← `refresh` (same handler); `fhs check` deprecated → `status`; `port list` deprecated → `status`.
- **bash-completion:** removed the **retired `gui`** command (retired v1.100.1b) — it was still advertised in tab-completion.

### Added
- **CI parity guard** `scripts/ci/check-cli-surface-parity.sh` (wired into `ci-architecture.yml`): validates registry ↔ bash-completion ↔ dispatch and classifies drift (MISSING_FROM_REGISTRY / STALE_IN_REGISTRY / MISSING_FROM_COMPLETION / RETIRED_IN_COMPLETION / ALIAS_NOT_MARKED / DEPRECATED_NOT_MARKED / INTERNAL_OR_TARGET_ONLY_ALLOWLISTED / PASS) + retired-command + duplicate-handler scan.

### Notes
- **No daemon change** (no `.go`/`cmd/`/`internal/` edits) → `nftband` byte-identical with v1.204.0. **nft schema 1.84.0 unchanged. No docs/website changes** (already clean). **No portscan/BotGuard/whitelist/blacklist change.**
- **No fleet rollout** in this release. **Latest published remains v1.204.0 until v1.205.0 is tagged/published.** Production fleet remains **v1.203.0**; v1.204 Track-A rollout remains HOLD.

---

## [v1.204.0] - 2026-06-25 — Portscan Go-classifier migration (known-open service-port false-positive fix)

**Codename:** `PORTSCAN_GO_CLASSIFIER_MIGRATION` · **PR:** [#951](https://github.com/itcmsgr/nftban/pull/951) (→ `7db54bf5`) · **Ownership:** `LOG_SOURCE_OWNERSHIP_DECLARATION_PORTSCAN.md` (ACCEPTED)

> **What:** fixes a portscan false-positive where a legitimate multi-service client (panel+mail+web+SSH) was temp-banned for touching several known-open services quickly. **Minor bump (1.204.0) because the `nftband` daemon is intentionally RE-BASELINED** (`cmd/nftband/daemon_init.go` links the new `internal/portscan` package). NFT `SchemaVersionCurrent` unchanged (1.84.0).
>
> **⚠️ Fleet rollout is intentionally DEFERRED. Production remains v1.203.0; the portscan FP fix is NOT live fleet-wide until a separate Track-A gate (`OPEN_V204_TRACK_A_FLEET_ROLLOUT_11_HOSTS`).** v1.204.0 published ≠ fleet protected by the new classifier.

### Fixed
- **Portscan classic classifier migrated to a typed Go decision function** (`internal/portscan`). Previously the shell classifier scored ALL distinct destination ports an IP touched (including configured open services) as scan diversity → a legitimate multi-service/browser/panel client could be classified strobe/vertical and temp-banned (proven: admin `62.38.150.122`, 6 open ports).
  - **Known-open service ports from `tcp_ports_in` no longer score as scan evidence** — they are allowed context.
  - **Unexpected/closed-port diversity remains ban-capable** (block/vertical/horizontal/strobe scoring is on the unexpected-port count); mixed traffic scores only the unexpected ports.
  - **IPv4/IPv6 parity validated.**

### Notes
- New `nftban-core portscan-classify` subcommand (pure decision function — does not read logs or write nft sets). Shell mode gate `PORTSCAN_CLASSIC_CLASSIFIER`: **shadow** (default — logs old-vs-new, **legacy enforcement preserved**), **go** (enforces the fixed classifier), **shell** (legacy). Single ban authority unchanged (shell → daemon IPC → `blacklist_manual_*`).
- **`nftband` daemon RE-BASELINED** (intentional); nft schema **1.84.0** unchanged; **no whitelist/blacklist topology change; no BotGuard change**; no counters/metrics; no new nft set.
- **Validation:** `internal/portscan` 12 table-driven tests; **lab2 (DEB) + lab4 (RPM) package-native PASS** — real `detect_scan_type` integration: go-mode known-open burst → allow (v4+v6), unexpected diversity → ban, mixed → unexpected-only, shadow preserves legacy, classifier makes no direct nft write, no whitelist/blacklist regression, no ban residue.

---

## [v1.203.0] - 2026-06-25 — Blacklist topology cleanup (file-backed ban feed-reload fail-open)

**Codename:** `BLACKLIST_TOPOLOGY_CLEANUP` · **PR:** [#949](https://github.com/itcmsgr/nftban/pull/949) (→ `43535fae`) · **Audit:** `BLACKLIST_TOPOLOGY_CLEANUP_INDEPENDENT_AUDIT.md` (PASS)

> **What:** fixes a fail-open where file-backed `blacklist.d` bans stopped being enforced once threat feeds loaded. **Minor bump (1.203.0) because the `nftband` daemon is intentionally RE-BASELINED** (`cmd/nftband/daemon_handlers_sync.go`). NFT `SchemaVersionCurrent` unchanged (1.84.0).

### Fixed (ban-path enforcement)
- **`BUG-BLACKLIST-FILE-ENTRY-FAIL-OPEN-ON-FEED-RELOAD`** — `blacklist_ipv4/_ipv6` are feed/geoban-owned `interval,auto-merge` sets written by a flush-first replace; the sync also string-diffed `blacklist.d` into them, so the feed/geoban replace then **wiped** those file-backed bans (operator hand-edits / persist-only entries silently un-enforced once feeds loaded).
  - **File-backed single-IP** blacklist.d entries now survive feed reload — routed to the manual hash sets `blacklist_manual_ipv4/_ipv6` (which the feed replace never touches).
  - **File-backed CIDR** blacklist.d entries now survive feed reload — folded into the **unified** feed/geoban canonical replace input.
- **Feed-vs-geoban sequential-replace clobber** — feeds and geoban each did a separate full replace of the shared interval set (second source wiped the first); now **unified into one canonical replace** per family (single interval writer). `FullSync` no longer string-diffs the interval blacklist sets.

### Notes
- **`nftband` daemon RE-BASELINED** — not byte-identical with v1.202.0; intentional (daemon-only change, single file). nft `SchemaVersionCurrent` stays **1.84.0** (no set-shape/schema change; no new set). **CLI/IPC `nftban ban` unchanged; `unban` clears all live copies. IPv4/IPv6 parity maintained.**
- **No portscan change** (the portscan Go-classifier migration is NOT part of v1.203.0; still parked). **No BotGuard change.**
- **Whitelist topology remains validated** (`WHITELIST_TOPOLOGY_STILL_VALIDATED = PASS`) — no lane reopen; the live whitelist path has no feed/geoban flush-replace writer (trust apply is additive). A latent `load_cidrs(set_type="whitelist")` flush-replace twin is parked as a future watch-item, **not** a release blocker.
- **Validation:** independent audit PASS (W2 comment fixed); **package-native lab2 (DEB) + lab4 (RPM) PASS** on installed packages (CI build 28161680101) — single-IP + CIDR survive feed reload, coexist with real feeds, no clobber, no malformed intervals, v4+v6; labs restored clean to v1.202.0.

---

## [v1.202.0] - 2026-06-25 — Whitelist durable-apply reconcile + range-aware verify (trusted-must-be-live)

**Codename:** `WHITELIST_DURABLE_APPLY_RECONCILE` · **PR:** [#947](https://github.com/itcmsgr/nftban/pull/947) (→ `e4827ab3`) · **Audit:** `WHITELIST_DURABLE_APPLY_RECONCILE_INDEPENDENT_AUDIT.md` (PASS)

> **What:** enforces the "trusted-must-be-live" invariant — a durable `whitelist.d` entry must be present in the live kernel whitelist set. **Minor bump (1.202.0) because the `nftband` daemon is RE-BASELINED** (the fix is in `internal/setsync`, which links into the daemon). NFT `SchemaVersionCurrent` unchanged (1.84.0).

### Fixed (P1/P2 — whitelist trust reliability)
- **Root cause:** the whitelist set is an `interval, auto-merge` set; the kernel coalesces adjacent CIDRs (`104.16.0.0/13 + 104.24.0.0/14 → 104.16.0.0-104.27.255.255`). The daemon's `setsync` used a **string** diff against the coalesced interval → spurious add/remove churn every sync that could drop genuinely-new durable entries (e.g. an operator/management IP written by `whitelist add --static` but not actually live). The same mismatch made `whitelist verify` report phantom Cloudflare drift.
- **Fix (range coverage, not strings):** a range-aware coverage oracle (`internal/netutil`) now drives (a) `nftban whitelist verify` — phantom CIDR↔interval anomalies eliminated; (b) `nftban whitelist add --static` — **live read-back / loud-fail** (exits non-zero, no false "applied live"); (c) the daemon whitelist sync — a range-preserving set reader (`GetSetElementsRanges`) + range-aware diff (**0 churn** on stable CIDR sets) + **post-apply durable-coverage verification** that fails loud if any permanent durable entry is not live.

### Notes
- **`nftband` daemon RE-BASELINED** (not byte-identical with v1.201.4) — intentional; `internal/setsync`/`internal/netutil` changed. nft `SchemaVersionCurrent` stays 1.84.0 (no set-shape/schema change). No detector/firewall/portscan/BotGuard change.
- **Validation:** netutil + setsync unit tests (incl. the nftables interval-element model pinned by `TestReconstructIntervalRanges_ObservedStructure`); go vet; **package-native lab2 (DEB) 19/0 + lab4 (RPM) 19/0** — 0-churn, clean intervals, new `--static` IP lands live, loud-fail, manual/trust/system tier reconcile, session preserved, labs restored clean.
- **Follow-on (separate lanes):** verify-CIDR-interval-normalization is shipped here as the oracle; the standalone `WHITELIST_VERIFY_CIDR_INTERVAL_NORMALIZATION` register entry is satisfied. srv3 host reconcile + portscan Go-classifier migration remain parked (own gates).

---

## [v1.201.4] - 2026-06-24 — `config local` read-only override diagnostics (CONFIG_LOCAL_RECOVERY IMPL-2)

**Codename:** `CONFIG_LOCAL_RECOVERY IMPL-2` · **PR:** [#944](https://github.com/itcmsgr/nftban/pull/944) (`334dd4fa`) · **Scope:** `CONFIG_LOCAL_RECOVERY_IMPL2_SCOPE.md`

> **What:** adds read-only diagnostics for operator `*.conf.local` overrides, built on the v1.201.2 `_source_local` mechanism. **Strictly read-only — no writes, no quarantine, no mutation.** Shell-only; `nftband` daemon byte-identical (source-proven: zero `.go`); NFT `SchemaVersionCurrent` unchanged (1.84.0).

### Added
- **`nftban config local list [--json]`** — enumerate every `*.conf.local` with path · base `.conf` it overrides · sha256 · size · mtime · `bash -n` syntax status.
- **`nftban config local validate [--json]`** — `bash -n` syntax-check each `.local` (never sources/executes); exit nonzero if any `SYNTAX_ERROR`.
- **`nftban config local doctor [--json]`** — syntax + a schema-derived `KEY=VALUE` lint against `config-schema.json`: `OK` / `UNKNOWN_KEY` / `DEPRECATED_KEY` (flags the v1.201.3-deprecated recovery keys) / `BAD_VALUE`. Read-only by design (no mutating mode).

### Notes
- **Strictly read-only:** no file writes, no quarantine, no `disable`/`reset`/`restore`, no `config-quarantine` directory, no change to `_source_local` loading. The lint is schema-derived (single source of truth) — no second hardcoded key list.
- Wired through the CLI contract: `commands.registry.yml` (`config.subcommands.local`, `mutates:false`, `config_view`), `config` usage, and `config local [--help]` + per-verb `--help`.
- **`nftband` daemon byte-identical (source-proven); nft schema 1.84.0**; no daemon IPC; `recovery.conf`/`config-schema.json` not modified (read-only consumers).
- **Validation:** hermetic 20/20 (incl. read-only + `-e`-safety proofs); **package-native both families lab2(DEB) 29/0 + lab4(RPM) 29/0** via the installed CLI — list/validate/doctor behavior, sha-compared zero mutation, no quarantine dir, registry/help green, labs restored clean.
- **Deferred (separate lanes):** IMPL-3 (quarantine/disable/restore verbs) · IMPL-4 (parse-not-execute migration).

---

## [v1.201.3] - 2026-06-24 — Recovery-config truth: trim+ship+wire recovery.conf, deprecate 11 phantom keys

**Codename:** `RECOVERY_LEGACY_RECONCILE` · **PR:** [#942](https://github.com/itcmsgr/nftban/pull/942) (`d6e13dbd`) · **Findings:** `RECOVERY_LEGACY_RECONCILE_FINDINGS.md`

> **What:** `recovery.conf` was a phantom config surface — unshipped + unsourced, yet `config-schema.json` documented 14 keys as living there (11 unread; 3 read by `nftban-apply` only from env / unshipped `/etc/default/nftban`). This makes the recovery config truthful: the 3 live commit-confirm knobs get a real shipped+sourced home; the 11 dead keys are deprecated. **Shell/packaging + config-schema metadata only; `nftband` runtime daemon byte-identical (source-proven: zero `.go`); NFT `SchemaVersionCurrent` UNCHANGED (1.84.0).**

### Fixed (P2 operator-truth)
- **Ship** a trimmed `/etc/nftban/conf.d/recovery.conf` with only the 3 live commit-confirm knobs (`NFTBAN_REBOOT_GRACE_PERIOD`, `NFTBAN_SSH_TEST_BEFORE_APPLY`, `NFTBAN_SSH_TEST_PORT`); the unshipped 14-key copy is removed.
- **Wire** `nftban-apply` to source the shipped `recovery.conf` + `recovery.conf.local` (via the central `_source_local` helper, `bash -n`-gated) with explicit precedence (low→high): hardcoded < recovery.conf < `/etc/default/nftban` (legacy compat, retained) < recovery.conf.local < environment. Commit-confirm rollback behavior unchanged.
- **Deprecate** the 11 unread keys in both `config-schema.json` copies (no longer advertised as live `conf.d/recovery.conf` config). Previously they over-promised backup-rotation / rollback-alerts / reset-on-boot that do not exist in code.

### Notes
- **`nftband` daemon byte-identical (source-proven); nft schema 1.84.0** (the `config-schema.json` change is config metadata, not the nft schema). `rebuild_recovery.json` rebuild-retry marker contract untouched (separate mechanism). No detector/firewall/ban-path/BotGuard change; no new CLI command.
- **Validation:** hermetic 17/17; **package-native both families lab2(DEB) 25/0 + lab4(RPM) 25/0** via `nftban-apply`'s real config-resolution path — each live key in recovery.conf reflected in the effective config; `.local` overrides via `_source_local`; env > `.local`; full precedence chain deterministic; 11 dead keys deprecated; rebuild marker untouched; labs restored clean.
- This also closes the last R1a-5 `UNCLEAR_NO_GO` (recovery.conf).
- **Deferred (separate lanes):** config-local IMPL-2/3/4 · `OPEN_DRHG1_SYSTEMD_SPLIT_SCOPE`.

---

## [v1.201.2] - 2026-06-24 — `.conf.local` recovery (IMPL-1): central `_source_local` — broken overrides no longer partial-apply

**Codename:** `CONFIG_LOCAL_RECOVERY_IMPL1` · **PRs:** [#938](https://github.com/itcmsgr/nftban/pull/938) (helper + literal migration) + [#939](https://github.com/itcmsgr/nftban/pull/939) (variable-indirected completion) + [#940](https://github.com/itcmsgr/nftban/pull/940) (sbin entry-script + guard scope) → main `cd18bbf8` · **Scope:** `CONFIG_LOCAL_RECOVERY_DESIGN.md`

> **What:** a syntactically-broken operator `*.conf.local` override no longer silently **partial-applies** (the old `source … || true` left variables set before the error applied, then aborted). All `.conf.local` sourcing now routes through a single helper that `bash -n`-gates the file: clean → sourced (semantics preserved); broken → **skipped whole** with one actionable WARN, non-fatal. **Shell-only; `nftband` runtime daemon byte-identical (source-proven: zero `.go`); NFT schema UNCHANGED (1.84.0).**

### Fixed
- **Central `_source_local` helper** (`lib/env.sh`): `NFTBAN_IGNORE_LOCAL_CONFIG=1` bypass (break-glass) · missing/unreadable → silent · `bash -n` clean → source · `bash -n` fail → not sourced, **no partial-apply**, warn-once, non-fatal.
- **All `.conf.local` source sites routed through the helper** — literal paths, variable-indirected (`source "$VAR"` incl. `${base}.local` forms), and the **dispatcher entry script** `cli/sbin/nftban` (loop-`$local_override` + literal). Repo-wide bare-`.local`-source count = 0. Base-config sources unchanged.
- **CI guard** (`config_local_source_helper_impl1_test.sh`): Guard A (literal) + Guard B (variable-indirect) scanning the whole `cli/` tree (entry scripts included) — prevents recurrence; + regression for the partial-apply class.

### Notes
- **Schema 1.84.0 unchanged; `nftband` daemon byte-identical (source-proven).** No detector/firewall/nftables/ban-path/LoginMon-behavior/BotGuard/schema/counter change. No new CLI command (registry/help untouched).
- **Config model preserved:** base `.conf` = defaults; operator prefs = `*.conf.local` (survive upgrade).
- **Validation:** hermetic 13/13; **package-native both families lab2(DEB) 20/0 + lab4(RPM) 20/0 via the `/usr/sbin/nftban` dispatcher path** — broken `services.conf.local` (line-1 `NFTBAN_ENABLED=false` + syntax error) skipped whole (no partial-apply → status stays ENABLED), WARN emitted, `NFTBAN_IGNORE_LOCAL_CONFIG=1` bypass, `.local` survives upgrade; labs restored clean.
- **Deferred (separate lanes):** IMPL-2 (`config local list|validate|doctor`) · IMPL-3 (quarantine verbs) · IMPL-4 (parse-not-execute). `OPEN_RECOVERY_LEGACY_RECONCILE` / `OPEN_DRHG1_SYSTEMD_SPLIT_SCOPE` remain plan-only.

---

## [v1.201.1] - 2026-06-24 — Structural hygiene: ship login_alert.conf + services.conf at their live read paths

**Codename:** `STRUCTURAL_HYGIENE_PRA` · **PR:** [#936](https://github.com/itcmsgr/nftban/pull/936) (`ae687ef2`) · **Scope:** `STRUCTURAL_HYGIENE_SCOPE.md` + `STRUCTURAL_HYGIENE_INVESTIGATION_FINDINGS.md`

> **What:** closes two config **shipping gaps** — operator configs read live but never packaged, so the runtime silently fell back to defaults. **Shell/packaging + test only; `nftband` runtime daemon byte-identical (source-proven: zero `cmd/nftband`/daemon-source change); NFT schema UNCHANGED (1.84.0).**

### Fixed
- **`login_alert.conf`** — read live by `cmd_login.sh` (`conf.d/login_alert.conf`) but absent from the shipped tree → now shipped at `etc/nftban/conf.d/login_alert.conf` (auto-ships via the `/etc/nftban/conf.d/*.conf` packaging path).
- **`services.conf`** — `cmd_status.sh` sources `conf.d/services.conf` to honor the master switch `NFTBAN_ENABLED` (v1.150 MOD-09), but only the modular `conf.d/login/services.conf` shipped → the base master-switch never loaded (defaulted true). Now shipped at `etc/nftban/conf.d/services.conf` (distinct from the login-monitor `login/services.conf`).
- Guard `nftban_file_cleanup_r1a5_test.sh` updated to track the ownership decision (shipped-at-root + no cli/etc shadow for the two; recovery.conf still kept).

### Config model (validated)
Base `.conf` files ship **defaults**; operator preferences live in `*.conf.local` (never shipped → survive upgrade). RPM marks base confs `%config(noreplace)`; on DEB the curated conffiles list intentionally treats most base confs as defaults (operator prefs via `.local`). Both families validated package-native: `NFTBAN_ENABLED=false` honored by `nftban status`, `.local` precedence, `.local` survives upgrade.

### Deferred (separate lanes, not in this release)
- `recovery.conf` — legacy 14-key config surface → `OPEN_RECOVERY_LEGACY_RECONCILE` (audit/deprecate before any removal). recovery.conf + `config-schema.json` UNTOUCHED here.
- D-RHG-1 structural systemd-split → `OPEN_DRHG1_SYSTEMD_SPLIT_SCOPE` (definition-first; undefined).
- `.conf.local` recovery/quarantine tooling → `OPEN_CONFIG_LOCAL_RECOVERY_SCOPE`.

### Notes
- **Schema 1.84.0 unchanged; `nftband` daemon byte-identical (source-proven).** No detector/firewall/nftables/ban-path/LoginMon-behavior/BotGuard/schema/counter change.
- **Validation:** package-native both families from build `ae687ef2` — lab2 (DEB) 20/0 + lab4 (RPM) 20/0; labs restored to published fleet daemon.
- **Build-reproducibility note:** package builds here are non-reproducible (per-build daemon/wrapper sha differs); daemon byte-identity is **source-proven** (no daemon-source change), not binary-sha compared.

---

## [v1.201.0] - 2026-06-23 — Stale-oneshot / SOAK / A2 assertion-tolerance reliability

**Codename:** `V201_STALE_ONESHOT_SOAK_A2` · **PR:** [#932](https://github.com/itcmsgr/nftban/pull/932) (`c81c5db2`) · **Scope:** `V1_201_STALE_ONESHOT_SOAK_A2_SCOPE.md`

> **What:** a transient, re-verifiable nftban oneshot latch no longer marks `install_state=DEGRADED` — while a **persistent** failure still does (strict no-mask). Closes the deferred A2 from v1.198.3 and the broader stale-oneshot/SOAK class. **Installer-validation Go only (`internal/installer/validate` → `nftban-installer`, NOT `cmd/nftband`) → `nftband` runtime daemon byte-identical. NFT schema UNCHANGED (1.84.0).**

### Fixed
- **A2 assertion-tolerance** — an owned-update-window cadence-oneshot `EXEC-203`/equivalent latch (the v1.198.3 watchdog/update-swap class) is tolerated as non-fatal **only** after a live re-verify proves it transient.
- **Cadence-oneshot gated stale-clear** — extends the gated recovery to `nftban-watchdog` / `nftban-soak` / `nftban-maintenance` (a new `cadenceReverifiableOneshotStems` set), recovered **only** via `reset-failed` + a fresh clean `systemctl start` (host-side re-verify), in-window OR pre-window. Distinct from the existing unconditional pre-window botscan/alert@ clear (unchanged).
- **SOAK stale-failed recovery** — a stale failed `nftban-soak` from a prior unclean cycle is reset + re-verified; a genuinely-failing soak stays visible and DEGRADES.

### Strict no-mask invariant
A cadence oneshot is reclassified `WARN_TRANSIENT_RECOVERED` (non-fatal) **only** when the re-verify was done AND the re-run was clean. A re-run that still fails, a non-cadence unit, or a unit with no re-verify stays in `FailedUnits` → **DEGRADED**. No `systemctl mask`, no unconditional allowlist, no hand-edited install_state.

### Notes
- **Schema 1.84.0 unchanged; `nftband` daemon byte-identical** (only `nftban-installer` validation moved). No LoginMon/R2 change · no BotGuard · no firewall/nftables/detector/ban-path change · no schema/counter/metrics work.
- **v1.199 forensic integration:** the tolerate/DEGRADE decision is recorded via `installer.log` (run_id-correlated) + the `update-runs/<run_id>/` post-verify snapshot's `install_state`.
- **Surfaces:** `systemd_payload.go` (`cadenceReverifiableOneshotStems` + `FailedUnitsTransientRecovered` bucket + gated classifier branch), `systemd_payload_gather.go` (`reverifyCadenceOneshot` host-side re-verify), `assertions.go` (`WARN_TRANSIENT_RECOVERED` surfacing). Test `cadence_oneshot_reverify_v1201_test.go` (transient→tolerated · persistent→DEGRADED · no-mask · non-cadence-DEGRADED · botscan regression intact).
- **Release gate:** NOT release-ready on merge alone — fleet/publish stay blocked until **package-native validation** on lab2 (DEB) + lab4 (RPM) proves BOTH sides: a recoverable transient cadence-oneshot failure → clean re-run → COMMITTED, AND a persistent failure → DEGRADED; with the v1.199 `update-runs/<run_id>/` capturing the decision.

---

## [v1.200.0] - 2026-06-23 — LoginMon source-visibility (R2): actionable + ack-able starved-source advisories

**Codename:** `V200_LOGINMON_SOURCE_VISIBILITY` · **PR:** [#930](https://github.com/itcmsgr/nftban/pull/930) (`994998be`) · **Scope:** `V1_200_LOGINMON_SOURCE_VISIBILITY_SCOPE.md`

> **What:** turns the fleet-wide `PASS_WITH_ACTIONABLE_WARN` LoginMon noise (`VAL-LOGINMON-002`) into something **actionable** (the WARN names the exact fix) and **quiet-able** (an operator can acknowledge a starved-by-design stack so it reads INFO — still visible). **Validator + config only; NFT schema UNCHANGED (1.84.0); no new JSON axis. The only `.go` change is in `internal/validator` (builds `nftban-validate`, NOT `cmd/nftband`) → the `nftband` runtime daemon is byte-identical.**

### Fixed (`VAL-LOGINMON-002` / R2)
- **Actionable remediation:** a starved source ("present but produced no readable logs") now carries the exact fix — **Roundcube** → enable `$config['log_logins'] = true;` in the Roundcube config; **webauth/ftpauth** → confirm the expected auth-log path is present + readable; default → points at the ack knob.
- **Operator acknowledge / suppress:** new **`LOGINMON_SOURCE_ACK`** in `conf.d/login/main.conf` (`.local` override first). A starved-by-design stack listed there is reported as **INFO** instead of WARN — but **stays VISIBLE** (the finding says *operator-acked*; the code is still emitted, never silently hidden). An **unacknowledged** starved source **remains WARN**; an **absent** source stays INFO; ack matching is case-insensitive.

### Notes
- **Schema 1.84.0 unchanged**; no new JSON axis (the input axis stays internal, awaiting SCHEMA-UNFREEZE). config(noreplace) → existing hosts unchanged unless they set the knob.
- **No `internal/loginmon` / detector / firewall / nftables / ban-path behavior change. No BotGuard. No stale-oneshot/A2/SOAK reliability logic (that is v1.201). No auto-editing of third-party (Roundcube/panel/FTP) configs.** `nftband` daemon byte-identical (only `nftban-validate` + config moved).
- **Surfaces:** `internal/validator/module_health.go` (`loginMonSourceAcked` + `loginMonRemediation`), `etc/nftban/conf.d/login/main.conf` (the `LOGINMON_SOURCE_ACK` knob). Test `loginmon_source_ack_v1200_test.go` (unacked=WARN+remediation · acked=INFO+visible · other/empty/malformed ack does not hide · case-insensitive · per-source text).
- **Release gate:** NOT release-ready on merge alone — fleet/publish stay blocked until **package-native validation** on DEB/RPM + at least one real starved-source host (Roundcube `log_logins` off) proves the advisory carries the fix, `LOGINMON_SOURCE_ACK` quiets to INFO visibly, and un-acking restores WARN.

---

## [v1.199.0] - 2026-06-23 — Lifecycle forensics: per-run records + run-id + JSONL + support all-logs

**Codename:** `V199_LIFECYCLE_FORENSICS` · **PR:** [#927](https://github.com/itcmsgr/nftban/pull/927) (`ec144cbd`) · **Scope:** `V1_199_LIFECYCLE_FORENSICS_SCOPE.md`

> **What:** an observability/forensics lane so install/update lifecycle bugs are diagnosable from the host's own record + a `nftban support` bundle (no more live `journalctl`/`stat` archaeology, as the v1.198.x rollout needed). **NFT schema UNCHANGED (1.84.0). The only Go change is in `internal/installer/logging` — imported by `nftban-installer`, NOT `cmd/nftband`, so the `nftband` runtime daemon is expected byte-identical (proven at package-native Stage B).** Forensics ONLY — no reliability self-heal.

### Added
- **Per-run forensic records** (`BUG-INSTALLER-PER-RUN-FORENSIC-LOG-MISSING`) — each `nftban update` mints a **run_id** and writes `/var/log/nftban/update-runs/<run_id>/{run.jsonl,human.log}`. `cmd_update.sh` snapshots the lifecycle at **pre-swap / post-swap / post-verify** plus inhibit/restore events and a run-end (including on the install-fail path). **Bounded retention** (newest N, default 20 via `NFTBAN_FORENSIC_RETAIN`); pruning **logs what it drops** (no silent cap). New FHS dir `/var/log/nftban/update-runs` (0750 nftban:nftban, tmpfiles `z`-reconcile).
- **Structured JSONL event stream + run-id correlation** (`BUG-INSTALLER-LOG-FORMAT-MIXED-JSON`) — `run.jsonl` is one parseable JSON event per line, every line carrying `run_id`; `installer.log`'s RUN header is stamped with the same run_id (`NFTBAN_RUN_ID` shared with the shell path, else `<UTC compact>-<pid>`) so installer/update logs correlate.
- **Forensic snapshot (strict allowlist)** — binary mode/mtime/xattr (`/usr/sbin/nftban`), cadence-timer due-time + active state (`nftban-watchdog.timer`/`nftban-maintenance.timer`), failed-unit name/`Result`/`ExecMainStatus`/`ExecMainExitTimestamp`/`InactiveEnterTimestamp`, install_state. **No env, no secrets, no config dump.**
- **`nftban support` all-logs** — collects the newest N `update-runs/<run_id>/` (`SUPPORT_UPDATE_RUNS_MAX`, default 10), redacted, size-bounded; warns when older runs are omitted.

### Notes
- **Redaction:** jq-free; values pass a secret-pattern safety-net AND a secret-named-key redaction; the snapshot is allowlisted.
- **Schema 1.84.0 unchanged.** No stale-oneshot/A2/SOAK reliability logic (→ v1.201). No R2/LoginMon source-visibility. No schema/counter/metrics work. No BotGuard work. No firewall/nftables/detector behavior change.
- **Surfaces:** `cmd_update.sh`/`cmd_update_helpers.sh`/`cmd_support.sh` (shell), `internal/installer/logging/logger.go` (run-id, installer-side only), `build/fhs-spec.yaml` + regenerated outputs. Tests: `lifecycle_forensics_v1199_test.sh` (18/0) + `logger_runid_test.go` + `tmpfiles_zz_v139` (11/0) + `watchdog_update_swap_race_v1983` (20/0).
- **Release gate:** NOT release-ready on merge alone — fleet/publish stay blocked until **package-native Stage B** validates v1.199.0 as built DEB/RPM through the official upgrade path on lab2 + lab4 (the lab-first proof, since the run-id needs the built `nftban-installer` binary).

---

## [v1.198.3] - 2026-06-23 — Hotfix: cadence-timer inhibit during update binary-swap (`BUG-WATCHDOG-TIMER-UPDATE-SWAP-EXEC203-RACE`)

**Codename:** `V198_3_WATCHDOG_UPDATE_SWAP_RACE` · **PR:** [#925](https://github.com/itcmsgr/nftban/pull/925) (`7d7588d5`) · **Scope:** `V1_198_3_SCOPE_WATCHDOG_UPDATE_RACE.md`

> **What:** a surgical, **shell-only** lifecycle/update-window reliability hotfix. **Daemon byte-identical to v1.198.2** (zero `.go`; only git-stamp/package-metadata differs). **NFT schema UNCHANGED (1.84.0).** No systemd-unit, no firewall/nftables behavior, no BotGuard, no counters/metrics, no A2 assertion-tolerance, no v1.199 forensic-log work.

### Fixed
- **`BUG-WATCHDOG-TIMER-UPDATE-SWAP-EXEC203-RACE`** — `nftban-watchdog.timer` (`OnUnitActiveSec=120s`, `ExecStart=/usr/sbin/nftban watchdog run`) could fire while `nftban update` was replacing / permission-/attribute-toggling `/usr/sbin/nftban`, hitting a transient `EXEC 203 Permission denied`. That latched `nftban-watchdog.service` failed and the post-install `failed_units_postinstall_ok` assertion marked `install_state=DEGRADED` on an otherwise-healthy upgrade. **Class:** lifecycle/update-race. **Severity:** MED (reliability/lifecycle-truth) — **not** a firewall/ban/protection failure.

### dns2 incident (reproduced in production)
During the v1.198.2 fleet rollout, **dns2** finished `DEGRADED` + `failed=1` = `nftban-watchdog.service` `Failed at step EXEC spawning /usr/sbin/nftban: Permission denied` at **2026-06-22 20:23:24Z — inside the update window**, while live state was healthy (v1.198.2, validate rc0, daemon active, floor_breach=0; `/usr/sbin/nftban` `0750 root:nftban`; watchdog re-runs clean). **dns2 recovered to COMMITTED via the official `nftban update recommit`** (v1.198.1 path) — no manual edit, no `firewall reset --force`, bans intact. monitor + dns1 had passed clean; the race is timing-dependent (~120s cadence vs the ~30-45s swap), so the remaining hosts were held for this fix.

### v1.198.3 A1 fix
`cmd_update.sh` wraps the `[2/6] Install` (binary-swap) phase: `_update_inhibit_cadence_timers` transiently **stops** the active racing timers (`nftban-watchdog.timer` + defensive `nftban-maintenance.timer`); `_update_restore_cadence_timers` restores **exactly** the ones it stopped (idempotent; **never enables a disabled timer; never masks**) — explicit restore after the install case (success + handled-failure) plus a **scoped `INT/TERM` trap** (interrupt). **No `EXIT` trap** (the update-lock cleanup is return-based and must not be clobbered; the trap is cleared right after restore). `_update_verify_watchdog` runs the watchdog once post-swap and **fails only if the restored watchdog still fails** (a clean re-run clears any stale latch; never masks a genuine failure).

### Notes
- Shell-only: `cmd_update.sh` + `cmd_update_helpers.sh`. Daemon byte-identical to v1.198.2; NFT schema 1.84.0.
- Tests: `watchdog_update_swap_race_v1983_test.sh` **20/0** (stops-only-active · restores-exactly · idempotent · failure-path · never mask/enable · watchdog-verify pos/neg · static install-phase-wiring + no-EXIT-trap guard). **Stage-1 (source/staged) lab2 (DEB) + lab4 (RPM) PASS** (real `nftban update` → COMMITTED, 0 failed, both timers restored, watchdog verification passed; ban deltas were feed-resync lag, not loss). **Pre-existing test debt** `cmd_update_lock_cleanup_v135_test.sh::static_s3` is red on clean main and this candidate identically (`PRE_EXISTING_TEST_DEBT_STATIC_S3_LOCK_CLEANUP_NOT_INTRODUCED_BY_V1_198_3`).
- **Release gate:** this build is **NOT release-ready on Stage-1 alone** — fleet resume / publish stay blocked until **package-native Stage B** validates v1.198.3 as built DEB/RPM through the official upgrade path on lab2 + lab4.
- Deferred (NOT in v1.198.3): A2 assertion-tolerance + broader stale-oneshot/SOAK → v1.201; installer per-run forensic logs + `nftban support` all-logs → v1.199.

---

## [v1.198.2] - 2026-06-22 — Hotfix: firewall-transition health truth (clear path + verdict aggregation)

**Codename:** `V198_2_FW_TRANSITION_HEALTH_TRUTH` · **PR:** [#923](https://github.com/itcmsgr/nftban/pull/923) (`7f763ca8`) · **Scope:** `V1_198_2_SCOPE_FW_TRANSITION_HEALTH_TRUTH.md`

> **What:** a surgical, **shell-only** hotfix for the firewall-transition health surface. **NFT schema UNCHANGED (1.84.0). Daemon byte-identical to v1.198.1** (zero `.go`). **No firewall/ban enforcement, detector, or BotGuard behavior change.** Surfaced during the v1.198.1 fleet rollout when lab2 showed a sticky `floor_breach=1` CRITICAL while live protection was healthy.

### Added
- **Official transition-health clear path** (`BUG-FW-TRANSITION-HEALTH-COUNTER-STICKY-NO-RESET`) — new `nftban firewall transition-health status` (report the current verdict) and `nftban firewall transition-health ack` (clear a **resolved** alarm). The ack zeroes the cumulative harm counters **only after a live probe verifies the management floor is intact** (refuses otherwise — it cannot mask a current breach), preserves the prior anomaly timestamp as audit history, and touches **only the state JSON** — no `nft`/ban-set mutation. A clean `nftban firewall rebuild` also clears a resolved alarm via the same gated logic. Registered in the CLI help, command registry, and bash-completion.

### Fixed
- **Health/status verdict aggregation** (`BUG-HEALTH-VERDICT-IGNORES-FW-TRANSITION-CRITICAL`) — a CRITICAL firewall-transition alarm now flags the operator verdict: `nftban health` reads `Upgrade readiness: PASS_WITH_WARN` / `Action needed: WARN` with an alarm note (no longer `PASS`/`NONE`), and `nftban status` qualifies the Health roll-up. **No more green/`PASS`/`NONE` headline beside a `Firewall Transition: CRITICAL` line.** Runtime protection may still read PROTECTED — the operator-truth surface now reflects the unresolved alarm.
- **Finding double-render** (`D-V198-HEALTH-FINDINGS-DOUBLE-RENDER`) — the operator-readiness block is now verdict-only; finding detail renders **once** in the canonical "Findings" section.

### Operator example (real lab2 case — canonical)
- **Symptom:** `nftban status` shows `FW Transition....... 🔴 CRITICAL (floor=1 table=0 blacklist=0)` while the firewall is otherwise healthy (daemon active, tables present, bans enforcing). This is a *resolved* historical transition transient whose cumulative counter never cleared.
- **Inspect, then clear:**
  ```
  nftban firewall transition-health status      # CRITICAL — floor_breach=1
  nftban firewall transition-health ack          # clears ONLY after live-floor verification
  ```
- **Expected result:** `floor_breach` clears to 0 **only after** the live floor is verified intact; **bans are preserved** (lab2: 343 → 343, no loss); `nftban health`/`status` become consistent; the prior anomaly timestamp is retained for audit.
- **Do NOT** use `nftban firewall reset --force` merely to clear a resolved transition alarm — that flushes all sets and **drops every ban**. The `ack` path is the proportionate, ban-preserving way. `ack` **refuses if a current breach still exists** (restore the floor with `nftban firewall rebuild` first).

### Notes
- Shell-only: `nftban_firewall_transition_health.sh` (gated `fth_reset_transition_health`), `nftban_output.sh` (readiness), `cmd_health.sh`/`cmd_status.sh` (verdict surfaces), `cmd_firewall.sh` (verb + rebuild clear). NFT schema 1.84.0; daemon byte-identical to v1.198.1. Tests: `fw_transition_health_truth_v1982_test.sh` (16/16: reset positive/negative no-mask, no-ban-loss, verdict aggregation) + updated `nftban_operator_readiness_r1b2_test.sh` (23/0) + `firewall_transition_health_v1921_test.sh` (34/0). **Lab-first:** lab2 (DEB/Plesk) stuck-host proof PASS (real `floor_breach=1` cleared via `ack`, bans preserved) + lab4 (RPM/cPanel) clean regression PASS. **Deferred (NOT in v1.198.2):** `BUG-INSTALLER-PER-RUN-FORENSIC-LOG-MISSING` → a v1.199 lifecycle-forensics lane (per-run forensic logs + `nftban support` all-logs collection).

---

## [v1.198.1] - 2026-06-22 — Hotfix: alert-handler /dev/log robustness + install_state recommit path

**Codename:** `V198_1_ALERT_HANDLER_AND_RECOMMIT` · **PR:** [#921](https://github.com/itcmsgr/nftban/pull/921) (`260d0ad9`) · **Scope:** `V1_198_1_HOTFIX_SCOPE_ALERT_HANDLER_AND_RECOMMIT.md`

> **What:** a surgical hotfix for two coupled defects surfaced during the v1.198.0 Track-A rollout (a host upgraded functionally but stuck `install_state=DEGRADED`). **NFT schema UNCHANGED (1.84.0). No firewall/ban/detector/BotGuard/counter/metrics change.** Lab-first validated (lab2 DEB 24/24 + lab4 RPM 24/24).

### Fixed
- **`D-NFTBAN-ALERT-LOGGER-DEVLOG-PERMISSION`** — the OnFailure service-failure alert oneshot (`nftban-alert@.service`, `PrivateDevices=yes` + `User=nftban`) failed with `logger: socket /dev/log: Permission denied`; because the unguarded `logger` was the last command in `log_alert()`, its non-zero exit latched the unit `failed`, which tripped the post-install failed-unit assertion (→ `install_state=DEGRADED`) and meant real service failures went unalerted. `cli/sbin/nftban-service-alert` `log_alert()` now delivers to the journal via stderr (the unit's `StandardError=journal` + `SyslogIdentifier=nftban-alert` reach the journal without `/dev/log`), keeps the file log, treats `logger` as best-effort (`2>/dev/null || true`), and returns 0. The systemd sandbox is **unchanged** (not relaxed); email **delivery** keeps its own rc contract (real delivery failures still fail the unit) — no masking.

### Added
- **`D-V198-STICKY-DEGRADED-NO-RECOMMIT-PATH`** — once `install_state` was DEGRADED, no official command recomputed it to COMMITTED on the same version after the cause was resolved (`--force`/`--repair` re-echo the stale record; `reset-failed` is defeated by the alert re-firing on the update restart), forcing manual edits of the machine-written state file. New **`nftban-installer --revalidate`** (shell verb **`nftban update recommit`**): a restart-free recompute that re-runs **only** the live post-install assertion suite and rewrites `install_state` via the official writer — no package install, no daemon restart. Transitions DEGRADED → COMMITTED **only** when every live assertion passes (version match, validator clean, 0 failed nftban units, ip/ip6 tables present, daemon active); refuses on a non-DEGRADED state / version mismatch / missing state file; otherwise leaves DEGRADED with the current live reason. Never marks COMMITTED while a real failure remains.
- The `nftban-alert@` **template** is now a stale-clearable oneshot (`staleClearableOneshotStems`, template-aware match): a pre-existing alert latch (failure strictly before the install window) recovers without the live-health gate — the same circular-block fix v1.185.1 applied to `nftban-botscan`. In-window alert failures still DEGRADE.

### Notes
- **No product behavior change to firewall/ban/detector/BotGuard.** Go change is confined to `nftban-installer` (the `--revalidate` mode + the alert-template stale-clear classification); the `nftband` runtime daemon is otherwise unchanged. Tests: `systemd_payload_v1981_test.go`, `revalidate_test.go`, `alert_logger_devlog_sandbox_v1981_test.sh`. **Validation:** PR #921 CI green (69 pass / 0 fail) + post-merge main CI green (25 success / 0 fail); lab-first lab2 DEB + lab4 RPM 24/24 each, both restored clean.

---

## [v1.198.0] - 2026-06-22 — R1 LOW-risk hygiene + operator-UX sweep

**Codename:** `V198_R1_SWEEP` · **PRs:** [#912](https://github.com/itcmsgr/nftban/pull/912) (`606453b6`) + [#913](https://github.com/itcmsgr/nftban/pull/913) (`8ed90112`) + [#914](https://github.com/itcmsgr/nftban/pull/914) (`fcd9c8e7`) + [#915](https://github.com/itcmsgr/nftban/pull/915) (`837bc53c`) + [#916](https://github.com/itcmsgr/nftban/pull/916) (`b0f49fef`) + [#917](https://github.com/itcmsgr/nftban/pull/917) (`871c92a9`) + [#918](https://github.com/itcmsgr/nftban/pull/918) (`eceaa859`) + [#919](https://github.com/itcmsgr/nftban/pull/919) (`8f309cd6`) · **Scope:** `V198_R1_SCOPE.md` · **Forward plan:** `V198_PLUS_FORENSIC_BURNDOWN_SEQUENCE.md`

> **What:** the R1 low-risk hygiene + operator-UX sweep — ten small same-domain lanes, all shell/test/config/docs/file-cleanup. **No Go change — `nftban`/`nftban-core` daemon byte-identical to v1.197.0** (hashes move only via the embedded git-commit stamp). **NFT schema UNCHANGED (1.84.0).** No BotGuard re-enable (stays disabled fleet-wide), no counters/schema bump, no CSF, no installer parity. **Deferred (NOT in R1):** config-path drift / 3 `UNCLEAR_NO_GO` conf files · packaging-vs-install systemd-split (D-RHG, structural) · cmd_firewall renderer-dedup · RBL 11.4 / TODO-36/23.

### Added
- Operator-readiness verdict in `nftban health` (`Operational` / `Upgrade readiness` PASS·PASS_WITH_WARN·FAIL / `Action needed` + IDLE explained), computed shell-side from already-emitted validator output — no new validator field, no schema change ([#913](https://github.com/itcmsgr/nftban/pull/913)).
- `nftban update` fixed-phase `[n/6]` progress markers + readiness verdict folded into the existing install_state verdict block (no contradictory second verdict) ([#914](https://github.com/itcmsgr/nftban/pull/914)).
- Shared `nftban_render_findings` helper (hide-INFO default / `--verbose` all / `--json` unfiltered) extracted from `cmd_health.sh` ([#912](https://github.com/itcmsgr/nftban/pull/912)).
- Wiki: DDoS enforcement-pipeline Mermaid diagram (published to the live wiki, corrected to code-truth — per-IP service-port SYN `25/s burst 50` vs `ddos_prefix` `100/s burst 200`).

### Fixed
- GeoIP/GeoBan help advertised the obsolete country-IP path `/var/cache/nftban/geoban/`; corrected to the real runtime path `/var/lib/nftban/geoip/` ([#915](https://github.com/itcmsgr/nftban/pull/915)).
- DirectAdmin `panel directadmin disable` confirmation hardcoded SSH port `22`; now resolves the configured safety port (`${NFTBAN_SSH_TEST_PORT:-${SSH_PORT:-22}}`) ([#916](https://github.com/itcmsgr/nftban/pull/916)).
- CONFIG/RHG cosmetic comments: dropped the stale `NFTBan v1.0.0` header banner from `conf.d/{services,login_alert}.conf` and the `/home/commonfolder` dev-machine path from four `scripts/ci/*.sh` comment blocks (comment-only) ([#918](https://github.com/itcmsgr/nftban/pull/918)).

### Removed
- Two proven-unshipped repo artifacts: the byte-identical shadow `cli/etc/nftban/conf.d/trust.conf` (the shipped copy `etc/nftban/conf.d/trust.conf` is untouched) and the orphan `install/pam.d/nftban-api` (PAM config for the deprecated `nftban-api.service`). No package payload change ([#919](https://github.com/itcmsgr/nftban/pull/919)).

### Notes (audit-close / regression-lock — no product change)
- `rbl check --json` TXT escaping (`"`/`\`/newline): production fix already shipped in v1.150; this lane only adds the missing regression test ([#917](https://github.com/itcmsgr/nftban/pull/917)).
- Shell installer `[PHASE]` markers: already emitted by the Go installer (`nftban-installer`) since v1.156 — audit-close, no code.
- LoginMon shell `UX-MSG-AUDIT`: no misleading/contradictory shell messages found — audit-close, no code.

---

## [v1.197.0] - 2026-06-21 — MED validator/observability + legal/package-metadata hygiene

**Codename:** `V197_MED_TRAIN` · **PRs:** [#905](https://github.com/itcmsgr/nftban/pull/905) (`482329b7`) + [#906](https://github.com/itcmsgr/nftban/pull/906) (`8736f1d5`) + [#907](https://github.com/itcmsgr/nftban/pull/907) (`a0a7eaf2`) + [#908](https://github.com/itcmsgr/nftban/pull/908) (`9864e5f0`) + [#909](https://github.com/itcmsgr/nftban/pull/909) (`f70ffa1c`) + [#910](https://github.com/itcmsgr/nftban/pull/910) (`9aa1f1ef`) · **Plan:** `V196_197_DEBT_BURN_AND_SINGLE_ROLLOUT_PLAN.md` · **Scope:** `V197_MED_SCOPE.md`

> **What:** the final debt-burn train before the single waved fleet rollout — six independent single-domain lanes. **NFT schema UNCHANGED (1.84.0).** One lane (PR-A) is daemon-Go (validator): the packaged `nftban`/`nftban-core` daemon hash **moves off the v1.192.2 baseline** (re-baseline future shell/data-only lanes). No BotGuard re-enable, no counters/schema bump, no CSF, no installer parity, no 8E (cPanel/Plesk), no 8G (dead-knob deletion). The single waved Track-A rollout `v1.192.2 → v1.197.0` follows publish.

### Fixed
- **PR-A — VAL-LOGINMON-002-UX** (validator-Go, `internal/validator/module_health.go`): LoginMon health collapsed "source absent" and "source present but starved" into one WARN, so every non-web/non-FTP host read as a warning. Now classified **per-source** — a structurally-absent source (`NO_LOGS reason=no_<stack>`) reports **INFO / no action needed**; a present-but-starved source (`WARN_NO_LOGS reason=<stack>_present_…`) stays **WARN / actionable** — with the source + reason preserved (roundcube added to checked sources). Overall `PROTECTED/DEGRADED` rollup unchanged. **Rider:** geoban health resolves the GeoIP DB at `${NFTBAN_DATA_DIR}/geoip/dbip-country-lite.mmdb` (honoring the configured data dir, `/var/lib/nftban` fallback) instead of a hardcoded path. Lab-first lab2 (DEB) + lab4 (RPM) PASS, both restored clean.
- **PR-LICENSE — Core package license metadata**: the generated Core RPM spec declared `License: GPL-3.0-or-later` for an MPL-2.0 project — corrected to `License: MPL-2.0`, with `%license LICENSE` now shipped and a CI guard (`scripts/ci/check-license-metadata.sh`, wired into `ci-architecture.yml`) preventing regression. Adds DEP-5 `packaging/deb/copyright`, `AI_ASSISTED_DEVELOPMENT.md`, and repairs broken `NOTICE.md` references. Copyright holder kept as the repo canon `NFTBan Project / Antonios Voulvoulis`.

### Added
- **PR-B — SUPPORT-DIAG** (shell, read-only): `nftban support` diagnostics widened to diagnose install/health DEGRADED — dynamic `nftban*`/`nftband*` unit enumeration, `systemctl --failed`, per-unit Result/OOM properties, `install_state`, journald disk-usage, and OOM-kill evidence.
- **PR-C — dual-family test coverage**: IPv6 cases added to the four v1.196 IPv4-only fixtures (portscan, pattern-ban, wpadmin, fcrdns); the `# PARITY-GUARD-EXEMPT` markers were removed so the IPv4/IPv6 parity guard now reports 6 dual-family / 0 exempt. **No runtime family gap** — the change is test coverage only.

### Changed
- **PR-D — recovery.conf**: stale fail2ban comments removed (NFTBan has no fail2ban integration) and the required `meta:inventory` header added — config-comment/header only, no key/value/default change.

### Removed
- **GOTH orphan cleanup**: removed the tracked-but-unconsumed `install/config/allowed-gui-groups` (GUI/nftban-ui retirement). `ENABLE_GUI=0` external-compat pin kept.

### Notes
- No schema change (1.84.0). Daemon hash moves (PR-A validator-Go) off the v1.192.2 baseline; no ban/nftables/detector-ownership/installer/packaging behavior change. Fleet rollout = one waved hop `v1.192.2 → v1.197.0` (Track A), separate per-host gate after publish.

---

## [v1.196.0] - 2026-06-19 — LOW-risk debt sweep (test / docs / CI only)

**Codename:** `V196_LOW_RISK_DEBT_SWEEP` · **PRs:** [#900](https://github.com/itcmsgr/nftban/pull/900) (`d233939f`) + [#901](https://github.com/itcmsgr/nftban/pull/901) (`f4956e7a`) + [#902](https://github.com/itcmsgr/nftban/pull/902) (`69ee41fc`) · **Plan:** `V196_197_DEBT_BURN_AND_SINGLE_ROLLOUT_PLAN.md` · **Scope:** `V196_LOW_RISK_SWEEP_SCOPE.md`

> **What:** a small, low-risk cleanup release — three independent test/docs/CI-only PRs. **No product behavior change. NFT schema UNCHANGED (1.84.0). No Go/runtime source change — Go/product runtime byte-identical to v1.195.0** (packaged `nftban-core`/`nftband` hashes move only via the embedded git-commit stamp). No BotGuard re-enable, no counters, no CSF, no installer parity, no 8E (cPanel/Plesk), no 8G (dead-knob deletion), no v1.197 MED work; PR-E fuzz seeds skipped. Fleet rollout remains deferred to the final train target v1.197.0.

### Fixed
- **PR-A — FCrDNS broken-pipe test flake** (`cli/lib/nftban/tests/botscan_fcrdns_v189_test.sh`): a `sed … | grep -q` pipeline let `grep -q` close the pipe on first match, delivering SIGPIPE to `sed` (`couldn't flush stdout: Broken pipe`); under `pipefail` that intermittently flipped the `analyze() must call verify_crawler` assertion and red-flagged the 8C harness. Replaced with here-string capture (`grep -q … <<<"$(…)"`) — no pipe, no SIGPIPE; assertions unchanged.

### Changed
- **PR-B — stale docs/version/architecture references refreshed** (docs/text only): `SECURITY.md` supported-versions (`1.190.x`/`v1.190.1` → `1.195.x`/`v1.195.0`); `docs/ARCHITECTURE.md` IPC ban-flow diagram (`inet nftban`/`blacklist_v4` → `ip nftban`/`blacklist_ipv4`); `docs/systemd/TIMERS.md` stale `Removal Target v1.23.0` row retired; `.claude/CLAUDE.md` current-version stamp (`v1.56.0` → `v1.195.0`).

### Added
- **PR-F — IPv4/IPv6 parity static CI guard** (`scripts/ci/check-ipv4-ipv6-parity.sh`, wired into `ci-architecture.yml`): asserts both `table ip nftban` and `table ip6 nftban` are present, every `*_ipv4` set has a matching `*_ipv6` sibling (and vice-versa), and the canonical set inventories of the two table blocks match. **No runtime IPv4/IPv6 parity gap was found** — the nft data model is already fully dual-family; four IPv4-only fixtures are recorded as explicit `# PARITY-GUARD-EXEMPT` test-coverage exemptions (runtime is family-agnostic), with dual-family test coverage tracked for v1.197.

### Notes
- No schema change (1.84.0). No runtime/IPv4-IPv6 behavior change. Fleet rollout deferred to one waved hop `v1.192.2 → v1.197.0`.

---

## [v1.195.0] - 2026-06-19 — wp-login Go-path validation (8D, data-only matrix flip)

**Codename:** `V195_WPLOGIN_GO_PATH_PROOF` · **PR:** [#898](https://github.com/itcmsgr/nftban/pull/898) (squash-merged `e013b6fc`) · **Scope:** `V195_WPLOGIN_GO_PATH_PROOF_SCOPE.md` · **Evidence:** `V195_WPLOGIN_GOPATH_READONLY_PROOF_RECORD.md`

> **What:** data-only Protection-Claim Matrix update (8D). A **read-only** fleet proof validated the `WPLOGIN-AUTHFAIL` claim **live**, so the release records the result rather than changing any product code. **No LoginMon fix required. No product behavior change. NFT schema UNCHANGED (1.84.0). No Go source change — Go/product runtime byte-identical to v1.194.0** (packaged `nftban-core`/`nftband` hashes move only via the embedded git-commit stamp). No cPanel/Plesk proof (8E), no dead-knob deletion (8G), no BotGuard re-enable, no counters, no CSF, no installer parity. Fleet rollout remains separate (Track A, after publish).

The wp-login.php failed-credential ban path (Go LoginMon WebAuth detector) was proven live read-only on **srv1 / srv2 / srv3 / srv4** (all v1.192.2, DirectAdmin): failed `POST /wp-login.php` (HTTP `200`) → reason `wordpress_wp_login` → temp ban (900s), **IPv4 and IPv6**; `302` success-control observed and correctly **not** a ban driver. No host mutation, no synthetic traffic.

### Changed
- Protection-Claim Matrix row **`WPLOGIN-AUTHFAIL`**:
  - `classification`: **unproven → validated**
  - `fixture`: **read-only-fleet-G3 → `internal/loginmon/detector/webauth_test.go`** (the existing hermetic Go test — unchanged — which already asserts `POST /wp-login.php` + `200` → `ReasonWordPressWPLogin` for IPv4 and IPv6, `302` success → no verdict, and `xmlrpc`/`GET` → not owned).
  - owner (LoginMon), event class (`auth_failure`), and ban authority (IPC → blacklist) unchanged.

### Notes
- Repo diff is one data-only line in `cli/lib/nftban/tests/protection_claim_matrix_v194.tsv`. No schema change (1.84.0). The matrix now reports 14 validated claims.

---

## [v1.194.0] - 2026-06-19 — Protection-Claim Matrix harness (8C)

**Codename:** `V194_PROTECTION_CLAIM_MATRIX` · **PR:** [#896](https://github.com/itcmsgr/nftban/pull/896) (squash-merged `1b961cba`) · **Scope:** `V194_PROTECTION_CLAIM_MATRIX_SCOPE.md`

> **What:** test/CI-only validation-harness release (PR-A, 8C). **No detector/parser/daemon/CLI behavior change. NFT schema UNCHANGED (1.84.0). No Go source change — Go/product runtime byte-identical to v1.193.0** (packaged `nftban-core`/`nftband` hashes move only via the embedded git-commit stamp). No BotGuard re-enable, no counters population, no CSF, no installer parity. 8D/8E/8G are deferred follow-ons, NOT in this release.

Turns the one-time read-only protection-claim audit into a repeatable, CI-runnable harness so an advertised protection cannot silently regress to "no runtime owner" and a known dead config knob cannot be represented as a live enforcer.

### Added
- **21-row machine-checkable Protection-Claim Matrix** (`cli/lib/nftban/tests/protection_claim_matrix_v194.tsv`) — each advertised protection claim → runtime owner, source, consumer identity, ban authority, mode, zero-input behaviour, fixture, expected result, classification. Classifications surfaced: `validated` / `unproven` / `deferred` / `unowned` / `legacy-only` / `suppress` / `observe-only` / `dead-knob`.
- **CI guard** (`scripts/ci/check-protection-claim-matrix.sh`) — fails the build on wrong row count, missing/empty fields, invalid OWNER/MODE/CLASSIFICATION enum, a claimed-`enforce` row orphaned to `OWNER=NONE` (not `unowned`/`deferred`), or a dead knob (`WordPressXMLRPC`/`WordPressWPLogin`) represented as a live OWNER/BAN_AUTHORITY. Wired into `ci-architecture.yml` so advertised protection claims are now gated on every PR and on `main`.
- **Harness** (`cli/lib/nftban/tests/protection_claim_matrix_v194_test.sh`) — runs the CI guard plus the existing hermetic owner fixtures referenced in the matrix (BotScan scanner/exploit, 404-flood, endpoint-flood, authenticated WP-admin suppress, FCrDNS, portscan) as the owner-actually-bans proof.

### Changed
- Installed-tree (RPM) harness behaviour: in the **source tree** it runs the strict CI guard and requires every referenced fixture to pass; in the **installed package tree** (where the CI-only `scripts/ci` guard is not shipped) it validates the shipped matrix **inline** (same invariants — still fails on matrix corruption) and **skips source-tree-only fixtures** rather than hard-failing.

### Notes
- No schema change (1.84.0). No detector behavior change. `WordPressXMLRPC`/`WordPressWPLogin` remain parsed-but-unused and are documented as dead in the matrix; their deletion (8G) is a separate gated follow-on after 8D/8E.

---

## [v1.193.0] - 2026-06-17 — Post-v1.192 firewall / ops hygiene

**Codename:** `V193_POST_192_FIREWALL_OPS_HYGIENE` · **PR:** [#887](https://github.com/itcmsgr/nftban/pull/887) (squash-merged `192ff5db`) · **Scope:** `V193_POST_192_FIREWALL_OPS_HYGIENE_SCOPE.md`

> **What:** small, single-domain shell/observability release. **NFT schema UNCHANGED (1.84.0). No Go source change — Go runtime byte-identical to v1.192.2** (packaged `nftban-core`/`nftband` hashes move only via the embedded git-commit stamp). No BotGuard, no counters/schema, no CSF, no installer parity, no fleet rollout in this release.

Removes two operational foot-guns surfaced during the v1.192 train.

### Fixed
- **PR-A — `BUG-REBUILD-DROPS-MANUAL-WHITELIST`** (`cli/lib/nftban/cli/cmd_firewall.sh`): an explicit `nftban firewall rebuild` dropped manual `/etc/nftban/whitelist.d/*.conf` entries (operator `--static` admin IPs) from the live whitelist set, while `firewall reload`, daemon restart, reboot, and the maintenance timer preserved them. Rebuild now reconciles durable manual `whitelist.d`/`blacklist.d` via the **same core `sync --quick` path `firewall_reload` uses** (new Step 6b, after the system whitelist sync) — so **a manual `--static` whitelist now survives `firewall rebuild`** as well as reload/restart/reboot. System + trust-provider whitelist behaviour and blacklist/feed/geoban sets are unchanged.

### Changed
- **PR-B — table-absent maintenance-log noise** (`cli/lib/nftban/cron/maintenance.sh`): the maintenance run logged ~60/day `WARN "nftban firewall table absent"` — a **sampling artifact** when it sampled the nftban table mid firewall transition (rebuild/reload re-applying the schema). A new bounded **confirmation re-sample** (`_maint_table_absent_confirmed`) now re-probes the live table over a short grace before the WARN: a **transient** transition window (table reappears) is reduced to a quiet `INFO`, while a **genuine table-absent while `install_state` COMMITTED still reports** the `WARN`. The FW-transition harm counter `table_absent_while_committed_count` is untouched and remains the authoritative signal; firewall load/rebuild semantics and `install_state` are unchanged.

### Audited (no code)
- **PR-C — monitor MED re-audit:** `OPEN_MONITOR_SOAK_TIMEOUT_ROOTCAUSE` and `BUG-UPDATE-VERDICT-DEGRADED-ON-VALIDATOR-IDLE` were re-confirmed **read-only on v1.192.2 and closed with evidence — no code**: `nftban-soak.service` now succeeds (a single earlier timeout was a one-off under fleet-rollout load), and recent updates with the validator reporting `idle` complete `SUCCESS`/`COMMITTED` (the old idle→DEGRADED mapping no longer reproduces).

### Tests
- `cli/lib/nftban/tests/whitelist_rebuild_remerge_v1930_test.sh` (5/5) — static guard that rebuild invokes the `sync --quick` reconcile after the system whitelist sync, in parity with reload; discriminates the pre-fix tree.
- `cli/lib/nftban/tests/maint_table_absent_noise_v1930_test.sh` (6/6) — transient→suppress, genuine→WARN, both WARN sites gated, no harm-counter mutation.

### Validation
- Lab-first lab2 (DEB) + lab4 (RPM): PR-A manual whitelist **survives `firewall rebuild`**; PR-B transient table-absence suppressed / genuine kept (helper vs real nft); FW Transition 🟢 with harm counters 0; labs restored clean.
- **DEB/RPM package-native validation PASS** (`V193_PR_AB_PACKAGE_NATIVE_PASS_READY_FOR_PR`): packages ship both shell files + both tests; RPM≡DEB parity; schema 1.84.0. Post-merge main CI green.

---

## [v1.192.2] - 2026-06-17 — BotScan authenticated WordPress admin/editor false-positive hotfix

**Codename:** `BOTSCAN_WP_AUTHENTICATED_ADMIN_FALSE_POSITIVE` · **PR:** [#885](https://github.com/itcmsgr/nftban/pull/885) (squash-merged `2fff7af4`) · **Scope:** `BOTSCAN_WP_AUTHENTICATED_ADMIN_FALSE_POSITIVE_SCOPE.md`

> **What:** shell-only BotScan change. **Go source byte-identical to v1.192.1** (packaged `nftban-core`/`nftband` hashes move only via the embedded git-commit stamp, not a code change). **NFT schema UNCHANGED (1.84.0).** No BotGuard change, no fleet rollout, no manual-whitelist-rebuild change.

A legitimately logged-in WordPress administrator using the Gutenberg block editor / Elementor was classified `request_class=scanner` and auto-banned: the editor fetches `/wp-json/wp/v2/users` (matches `EXP_WPREST`) and editor calls match `WS_WPADMIN`, reaching score 80 → ban → escalation into the permanent blacklist (confirmed on srv4 for `nafpliotisbros.gr`).

### Added
- **BotScan authenticated WP-admin/editor context gate** (`cli/lib/nftban/core/nftban_botscan.sh`). A successful login — `POST <login_path> → 302` (uses the already-parsed HTTP **status**; a failed/probing login returns 200, so brute-force is never treated as "admin") — marks the IP authenticated for that scan cycle. In `analyze`, an authenticated IP has **only** the configured WP admin/REST scanner pattern hits (`BOTSCAN_WPADMIN_CONTEXT_PATTERNS`, default `EXP_WPREST WS_WPADMIN`) removed from its matched set and its hit-count recomputed **before** the threshold check.
- Operator knobs (default-on): `BOTSCAN_WPADMIN_CONTEXT_GATE`, `BOTSCAN_WPADMIN_CONTEXT_PATTERNS`, `BOTSCAN_WPADMIN_LOGIN_PATH`.

### Preserved (scanner detection unchanged)
- **Authenticated WP-admin/editor false-positives are reduced**, but this is a **per-IP context gate, not a global pattern weakening**: `EXP_WPREST`/`WS_WPADMIN` definitions, thresholds and weights are unchanged.
- **Unauthenticated `/wp-json/wp/v2/users` REST enumeration still bans** (no successful login → not gated). Exploit/webshell/CVE patterns, the 404-flood and endpoint-flood paths, and a **non-authenticated `WS_WPADMIN`** hit all still ban. **Empty/rotating-UA scanners still ban.** A **mixed exploit** request (some admin-looking traffic + an exploit pattern) still bans. v1.189 verified-crawler semantics are unchanged.
- LOG_SOURCE_OWNERSHIP_DECLARATION = **ACCEPTED** (same access-log event class BotScan already owns; uses the already-parsed status field — no new source/consumer/identity; zero-input behaviour unchanged).

### Tests
- New hermetic `cli/lib/nftban/tests/botscan_wpadmin_context_gate_v1922_test.sh` (8/8): authenticated admin not banned; unauthenticated enumeration / mixed exploit / no-auth `WS_WPADMIN` / empty-UA scanner all still ban; normal `admin-ajax` no ban; gate-disabled discriminator reproduces the pre-fix ban (so a suppressed FP cannot be promoted to the permanent blacklist).

### Validation
- Lab-first DEB (lab2) + RPM (lab4) full `process_logs` replay against the real `patterns.d`; **DEB/RPM package-native validation PASS** (`V192_2_PACKAGE_NATIVE_PASS_READY_FOR_PR`; `nftban_botscan.sh` + the new test shipped, RPM≡DEB parity, schema 1.84.0); existing BotScan suite green; post-merge main CI green.

### Not in this release (separate lanes)
- v1.192.1 fleet rollout · `BUG-REBUILD-DROPS-MANUAL-WHITELIST` (manual `whitelist.d` dropped by `firewall rebuild`) · BotGuard re-enable. None are addressed here.

---

## [v1.192.1] - 2026-06-17 — Firewall service-port transition atomicity (residual fix) + transition health

**Codename:** `V192_1_FUNCTIONAL_HOTFIX` · **Branch:** `fix/v1.192.1-service-port-set-atomicity` · **Scope:** `V1_192_1_FUNCTIONAL_HOTFIX_SCOPE.md`

> **What:** shell render + `nftban-core` effective-port authority + PR-B health. **NFT schema UNCHANGED (1.84.0). `nftban-core` rebuilt; daemon hash MOVED (the branch adds `internal/ports/effective.go`, linked into `nftband`) — nftband runtime behavior unchanged (sync still uses the unchanged `ports.LoadAllPorts`; no daemon path calls the new render functions).** Not "byte-identical".

**v1.192.0 was PARTIAL MITIGATION.** It closed the rebuild floor-collapse (F-RB) and the blacklist refresh fail-open (F-FEED/F-GEO), but the durable nftables config still rendered **skeletal** service-port sets (`tcp_ports_in/out`, `udp_ports_in/out` = `{__SSH_PORT__,80,443}`-class) and relied on a post-load daemon sync to fill them — so a configured service port (e.g. `993`) could be momentarily **absent** from the live sets immediately after a rebuild/reload (~1.85s drop window; lab-proven cross-family, inbound). v1.192.1 closes that residual gap.

### Fixed
- **`D-V192-RESIDUAL-REBUILD-DROP`** — the firewall render now completes the service-port sets **declaratively inside the nft set blocks** (`elements = {…}`, ip + ip6) for `tcp_ports_in`, `tcp_ports_out`, `udp_ports_in`, `udp_ports_out`, computed from the **same authority the daemon uses** (`ports.LoadAllPorts` via a new `nftban-core ports render-effective`). The atomic `nft -f` therefore installs the **complete** sets in one transaction **before** any daemon sync — the configured ports never disappear. The render is declarative in-block (a post-table imperative `flush set`/`add element` fragment segfaults `nft -c` on nftables 1.0.x — caught lab-first).
- Rebuild and reload **fail-closed** on effective-port render failure (missing `nftban-core`, render error, or no SSH-port authority) — they abort before `nft -f` and keep the existing ruleset; a skeletal service-port set is **never** applied (lockout-safe).

### Added (observability — PR-B)
- **Harm-keyed firewall transition health** in `/var/lib/nftban/state/firewall_transition_health.json` (**NOT the NFT schema**): `service_port_breach_count`, `floor_breach_count`, `table_absent_while_committed_count`, `blacklist_empty_during_refresh_count`, `non_atomic_rebuild_count` + metadata (`last_rebuild_atomic`, `last_trigger`, `last_duration_ms`, `last_transition_anomaly_at/_reason`).
- Surfaces: a `nftban health` finding (**anomalous-only** — healthy transitions and rebuild **cadence never alarm**), a `nftban status` "FW Transition" line, and a `firewall_transition` object in `nftban status --json`. Semantics: floor / table-absent / blacklist-empty → CRITICAL; service-port / non-atomic → DEGRADED.

### Added (guards & tests)
- Static CI guard **V-NFT-SERVICE-PORTS-RENDERED-COMPLETE** in `scripts/ci/check-nft-atomicity.sh` (every production substitute-render must complete the service-port sets; FAILs on a skeletal regression).
- Hermetic tests: `v1921_effective_port_render_failclosed_test.sh`, `firewall_transition_health_v1921_test.sh`, `firewall_transition_health_cli_v1921_test.sh`, plus `internal/ports` render-completeness/declarative tests.

### Validation
- **Functional rebuild + reload lab proof** — lab2 (DEB, Ubuntu 24.04) + lab4 (RPM, AlmaLinux 9.8): rebuild/reload rc=0; nft sampler shows the configured port (`993`) **never** leaves `tcp_ports_in` (ip + ip6) across thousands of samples; cross-host v4/v6 probes **0 excess drops**; durable config **complete before daemon sync**; daemon sync idempotent (no repair needed).
- **PR-B health lab proof** — healthy transitions keep all harm counters **zero**; controlled missing-port injection reports the exact **set/family/port**; `health`/`status` surfaces validated; labs restored clean.
- **DEB/RPM package-native validation PASS** (`V192_1_PACKAGE_NATIVE_PASS_READY_FOR_RELEASE_PREP`) — the real packages install the new `nftban-core` + shell helpers + health files + tests on lab2/lab4 and reproduce the runtime behavior; `nftban-core` byte-identical across RPM and DEB.

### Notes
- **NFT schema remains 1.84.0** — the transition-health counters are a state JSON, not NFT counters; no schema bump, no NFT counter population.
- **Daemon hash moved; nftband runtime behavior unchanged** (do not describe as "byte-identical").

---

## [v1.192.0] - 2026-06-17 — Firewall transition atomicity (F-RB + F-FEED + F-GEO)

**Codename:** `FIREWALL_TRANSITION_ATOMICITY` · **PR:** [#881](https://github.com/itcmsgr/nftban/pull/881) (squash-merged `c926f22e`) · **Scope:** `V1_192_FIREWALL_CONTINUITY_SCOPE.md` + audit `V1_192_AUDIT_NFTBAN_TRANSITION_CONTINUITY_BY_MODULE_AND_TIMER.md`

> **What:** daemon-Go + shell fix. **Daemon hash MOVED (Go set-writer change in `internal/setsync`, linked into `nftband`). NFT schema UNCHANGED (1.84.0). `MergeStats` / IPC contracts unchanged. No counter population.**

Closes the nftables **transition-atomicity class** — all three blockers reduce to one root cause: *flush + repopulate in separate transactions instead of one `nft -f`*. Every production live-object transition is now a single atomic transaction, so packets never observe an empty/partial state.

### Fixed
- **F-RB** (`D-NFTBAN-REBUILD-FLUSH-WINDOW`, fail-**CLOSED**) — `_firewall_rebuild_core` flushed the live `nftban` table (`nft flush table ip/ip6 nftban`) in a standalone step *before* a separate `nft -f`, collapsing the input chain to policy-drop with no accepts (lab repro: **19→1 rules** during rebuild, DEB + RPM). Removed the external flush; the rendered config already self-resets in one transaction (`table{}` create → `delete table` → full recreate), so `nft -f` alone is the atomic replace.
- **F-FEED** (`D-NFTBAN-FEED-REFRESH-FAILOPEN`) + **F-GEO** (`D-NFTBAN-GEOBAN-REFRESH-FAILOPEN`), fail-**OPEN** — the daily feed / weekly geoban refresh flushed the shared `blacklist_ipv4`/`blacklist_ipv6` set then repopulated in a separate transaction, momentarily emptying it (banned IPs admitted during the window). New `replaceSetElementsViaFile` / `renderSetReplaceScript` emit `flush set` as the first statement of the *same* `nft -f` script (flush+add commit atomically; on failure the transaction rolls back and prior blocked contents are retained — fail-CLOSED). The two same-class interval split/refresh paths route through the same helper; standalone `nftFlushSet` removed.

### Added (guards & tests)
- Static CI guards `scripts/ci/check-nft-atomicity.sh` — **V-NFT-REBUILD-ATOMICITY** + **V-NFT-SET-REFRESH-ATOMICITY** (function-scoped/structural, wired into `ci-architecture.yml`; verified to FAIL on the pre-fix tree and PASS on the fix).
- Hermetic Go unit test `internal/setsync/nft_set_refresh_atomicity_v192_test.go` (flush is the single first statement, precedes every add; no root/nft).
- Lab-first runtime tests `rebuild_no_syn_drop_v192_test.sh` + `blacklist_refresh_no_failopen_v192_test.sh` (self-skip without root/nft).

### Validation
- **lab2 (DEB, Ubuntu 24.04) + lab4 (RPM, AlmaLinux 9.8)** reversible source+daemon deploy, restored clean. Post-fix F-RB: management floor (loopback **AND** established **AND** SSH/service accept) present in **every** sample during rebuild — breach **0/600** (lab2), **0/500** (lab4); collapse-to-1 eliminated. F-FEED/F-GEO: atomic replace never empty (min=5); discriminator confirms the pre-fix pattern hits 0. PR #881 CI green (57 pass / 1 skip / 0 fail).

### Deferred / non-goals
- **PR-B** harm-keyed health observability (`non_atomic_*` / `table_absent_while_committed` / blacklist-empty counters) → **v1.192.1** (separate).
- F-OPQ (build-then-swap), F-DDOS (operator chain rebuild), F-LOCK (rebuild lock), `nftban_base` defense-in-depth — deferred.
- Recovery/reset/rollback/restore/stop paths intentionally exempt (operator/by-design).
- Residual to exercise at rollout: a **live populated** feed/geoban refresh (labs had empty `blacklist_ipv4`; daemon path proven via hermetic test + guard + kernel test).

---

## [v1.191.0] - 2026-06-16 — 8B BotGuard request-class-aware tuning + bounded decision cache

**Codename:** `BOTGUARD_REQUEST_CLASS_TUNING` · **PR:** [#879](https://github.com/itcmsgr/nftban/pull/879) (squash-merged `d526da6f`) · **Scope:** `V1_19X_8B_BOTGUARD_TUNING_DESIGN.md` (+ lab2/lab4/package-native/PR records)

> **What:** daemon-Go + shell feature. **Daemon hash MOVED off the prior `351d35df` byte-identical baseline (8B is daemon-Go). NFT schema UNCHANGED (1.84.0). NO counter population (counters-populate lane → v1.192.0+). BotGuard default remains DISABLED fleet-wide — re-enable is a separate canary-gated decision.**

Fixes the L4/request-blind browser / e-shop / gallery / WooCommerce-admin **false-positive** class (confirmed fleet-broad) without weakening abuse protection.

### Added
- Keep + **raise** the browser-safe L4 meter (suspect `100/second burst 200`; grey `25/50`; pending `50/100`).
- Structured `family` / `request_class` fields in `batch_signals.jsonl` (additive, old-reader-safe).
- BotScan `request_class` classifier (8-class taxonomy).
- Temporary daemon-Go **decision cache** — 6 temporary states only, monotonic TTL, hard caps + bounded eviction, IPv6 /64 candidate accounting (no durable trust/block, no persisted writer, no shell cache).
- Cadence-gap gate: the request-blind meter escalation only proceeds with dynamic class evidence (mid-band residual = `ACCEPT_WITH_VISIBLE_LAG`; a fast per-endpoint dynamic meter is an optional separate lane).
- Read-only `explain_ip` IPC + `search` / `emulate` / `debug botguard` / `support` / `health` bounded observability (temporary cache shown separate from durable nft truth).
- Bounded restart **warm-up** (tail-replay of `batch_signals.jsonl`, cache-only).
- Operator config knobs: `HTTP_BOT_CACHE_{MAX_ENTRIES,MAX_CANDIDATES,V6_PREFIX_BITS,MAX_PER_FAMILY,MAX_PER_HOST}`, `HTTP_BOT_WARMUP_{MAX_LINES,MAX_BYTES,MAX_AGE_SECONDS,MAX_DURATION_MS,MAX_ACCEPTED,MAX_LINE_SIZE}`, `HTTP_BOT_CADENCE_STALE_AFTER_SECONDS` (invalid → safe default, no unbounded mode).
- BotScan cadence-lag visibility (fresh / stale / unknown, text-only).

### Changed
- Browser-like batch signals (`static`/`static404`/`eshop_fanout`/`admin_ajax`) are **suppressed** (never ban/grey from class/rate alone); `dynamic_abuse`/`login_api`/`scanner` enforcement is **preserved**.

### Fixed
- BotGuard **disable orphan-chain** cleanup — `nftban botguard disable` no longer leaves an orphaned `http_bot_guard` chain or requires a manual `firewall rebuild` (validated live on lab2 + lab4).

### Validation
- inc1–8A hermetic Go/shell tests PASS (consolidated regression + synthetic scale envelope; `-race` clean).
- lab2 DEB + lab4 RPM behavioral source-deploy `PASS_RESTORE_CLEAN`.
- CI package-native build/install `PASS_WITH_WARNINGS_READY_FOR_PR` (RPM el9/el10 + DEB ×5 build + native install + parity; namespace-guard 9-distro matrix).
- PR #879 CI green; post-merge main CI green.

### Explicit non-goals (this release)
- No production re-enable · no shipped-default flip · no counter population (`nftban_counters_population_phase` stays 0) · no schema bump beyond the existing 1.84.0 baseline · no FCrDNS cache-size-cap refactor · no project-wide scale-envelope work. The **counters-populate** lane (formerly tracked loosely as "v1.191 counters") moves to **v1.192.0+**.

---

## [v1.190.3] - 2026-06-16 — BotScan direct-ban flag fix (BUG-BOTSCAN-DIRECT-BAN-FLAG)

**Codename:** `BOTSCAN_DIRECT_BAN_FLAG` · **PR:** [#877](https://github.com/itcmsgr/nftban/pull/877) (merged `482ab32b`) · **Scope:** `V1_190_3_BOTSCAN_DIRECT_BAN_FLAG_SCOPE.md`

> **What:** shell-only correctness fix. **Daemon byte-identical `351d35df`; schema unchanged (1.84.0); no nft/detector/ownership change.**

### Fixed
- **`nftban_botscan_ban_ip` direct/legacy branch** (`nftban_botscan.sh:1063`) called `nftban ban … --duration`, but the CLI accepts **`--timeout`**, not `--duration` — and `2>/dev/null` hid the error, so on that path the IP was logged BANNED but never inserted into nft. Fixed `--duration` → `--timeout`. **Production was unaffected** (the processor forces `BOTSCAN_BATCH_SIGNAL_MODE=true` → batch-signal → daemon path); this corrects standalone/legacy/direct invocations.

### Added
- Hermetic guard `botscan_direct_ban_flag_v1903_test.sh` — stubs `NFTBAN_BIN`, forces direct mode, asserts the emitted args use `--timeout` and never `--duration`.

---

## [v1.190.2] - 2026-06-16 — Low-risk shell/UX hygiene: version-literal cleanup, banner box fix, doc refresh

**Codename:** `LOW_RISK_SHELL_SWEEP` · **PRs:** [#873](https://github.com/itcmsgr/nftban/pull/873) (hygiene) + [#874](https://github.com/itcmsgr/nftban/pull/874) (banner) · **Scope:** `V1_190_2_LOW_RISK_SHELL_SWEEP_SCOPE.md`

> **What:** cosmetic + UX hygiene only. **Daemon byte-identical `351d35df`; NFT ruleset/schema UNCHANGED (1.84.0); no detector/ban behavior change; no counters.** A code re-challenge confirmed most of the originally-planned sweep (set-u cluster 16, H4/U3/empty-env CI guards, RBL per-run cap) was **already shipped** (largely v1.150) — those rows were debunked, not re-done.

### Fixed
- **Banner full-box overflow** — on `version`/`status` the v1.187.2 tagline was crammed onto line 1 (icons + posture + version), overflowing the fixed 60–70 col box border (multi-byte emoji + ANSI also defeat byte-based padding). The tagline now renders on its own plain-ASCII line, aligned to the border. Tagline preserved; banner guards (`cli_no_banner_v141`, `b1b_banner_compact_v1873`, `b1_text_ux_v1872`) all pass. (#874)

### Changed
- **Stale `NFTBan v1.0.x` version literals** — 113 shell-file header comments normalized to version-neutral `# NFTBan - …` (can't go stale again); `cmd_services.sh` help fallback now uses dynamic `${NFTBAN_VERSION}`. Factual since-version notes left intact. (#873)
- **FHS generator** (`build/generate-fhs-outputs.sh`) — generated config-file headers (tmpfiles.d, sysusers.d, FHS permissions) emit version-neutral banners instead of a hardcoded `v1.0.0`; the FHS spec header still carries the project version. Removes the stale-version source; `--check` parity holds.
- **`SECURITY.md`** — supported-versions table refreshed (1.149.x → 1.190.x; current → v1.190.2).
- **`.claude/CLAUDE.md`** — added the real `sync` verb to the valid-CLI list (DOC-SYNC-VERB).

### Notes
- Deferred (registered, not in this release): `INSTALL-UPDATE-PROGRESS-UX` (step/total progress contract); B1b-2 shared findings renderer (needs surface-scoping); the emoji-line right-border being a few columns short (terminal emoji width can't be byte-counted in shell); orphan-module deletion (guard-coupled).

---

## [v1.190.1] - 2026-06-15 — BotScan endpoint-flood: close advertised xmlrpc/wp-login protection gap

**Codename:** `BOTSCAN_ENDPOINT_FLOOD` · **PR:** [#871](https://github.com/itcmsgr/nftban/pull/871) (merged `1f958523`) · **Lane:** PROTECTION-CLAIM-MATRIX (HIGH)

> **What:** security/coverage fix — advertised WordPress/XML-RPC protection had **no runtime owner** for `POST /xmlrpc.php` (and `/wp-login.php`) **200-volume floods**, so they went unbanned fleet-wide. Adds a BotScan endpoint-flood detector. **Shell-only; daemon byte-identical `351d35df`; NFT ruleset/schema UNCHANGED; no counters (→ v1.191).**

### Fixed (security/coverage)
- **Unowned xmlrpc/wp-login 200 floods** — BotScan had only 404/URL-pattern detection (misses 200s); LoginMon owns credential-failure and cannot see the 200-body auth result; BotGuard is L3/L4 (content-blind). Confirmed unbanned on srv1–4/dns1/dns2 (10k–19k counts). Now owned by BotScan.

### Added
- **BotScan endpoint-flood detector** (`BOTSCAN_ENDPOINT_FLOOD`) — per source-IP × endpoint × window POST volume, **status-independent** (200 counts), volume-thresholded (never a single-hit URL ban → no false-ban of legit Jetpack/pingback/app xmlrpc). Initial endpoints `xmlrpc.php`, `wp-login.php`; defaults 30/60s/3600s, configurable via `main.conf(.local)`. Hooks the proven `count_404_tail` re-read (fork-free per-line); emits via the **batch-signal path only** (never the direct `ban_ip --duration` branch). Enforcement reuses the existing `anchor_ban` phase + `blacklist_manual`/`http_bot_ban` sets — **no nft schema change**.

### Behavior
- A flooding IP is banned via the existing daemon batch-signal → nft set path (IPv4 and IPv6). 404-flood and URL-pattern detection are unchanged (non-interference verified).

### Fixed (internal)
- IFS strict-mode parse of the endpoint list (`IFS=' ' read -ra`; v1.186.1 class).
- Claim correction `cmd_login.sh:1267` — states real owners (BotScan endpoint-flood = xmlrpc/wp-login POST volume; LoginMon = credential-failure; BotGuard = L3/L4 burst only).

### Validation
- Hermetic `botscan_endpoint_flood_test.sh` 10/10 (xmlrpc/wp-login positive, status-independent 200/403/500, below-threshold negative, non-POST negative, 404 non-interference, batch-signal-not-direct, unconfigured-endpoint negative, per-endpoint independence, **IPv6**). Regressions (404-tail/nofork/fcrdns/pattern-ifs/deadline) pass; shellcheck clean.
- **Lab-first PASS** lab2 (DEB) + lab4 (RPM): hermetic + live batch-signal integration, reversible, 0 failed units, daemon active. Pre-impl lab proved the existing batch-signal path reaches nft (srv2 `botscan-404` IPs in nft) and reproduced the gap.

### Notes
- `BUG-BOTSCAN-DIRECT-BAN-FLAG` (direct-mode `--duration` vs CLI `--timeout`) recorded separately (LOW; production unaffected — uses batch path). Counters for this detector deferred to v1.191.

---

## [v1.190.0] - 2026-06-15 — SCHEMA-UNFREEZE: counters contract/scaffolding + IP-family (1.83.0→1.84.0)

**Codename:** `SCHEMA_UNFREEZE_COUNTERS` · **PR:** [#868](https://github.com/itcmsgr/nftban/pull/868) (merged `bdaba785`) · **Design:** `SCHEMA_UNFREEZE_COUNTERS_DESIGN.md` · **Report:** `V1_190_0_REPORT_HUMAN.md`

> **What:** the **contract / scaffolding** half of the counters schema-unfreeze. Bumps the public health/observability schema **1.83.0 → 1.84.0** and defines the counter shape in the type system + Prometheus surface. **Daemon-Go (ends the `c63d8822` byte-identical train; daemon `351d35df…`); NO live counter population; no detector/ban behavior change.** Counters are deliberately **absent** (not zero), gated by `nftban_counters_population_phase = 0` and `counters_phase = "contract"` — *absent ≠ zero*. **v1.191.0 reserved for population** (phase 0→1).

### Added (schema 1.84.0, additive — old consumers ignore new fields)
- `counters_phase` (always present; `"contract"` in v1.190.0) — the anti-false-zero gate.
- `counters` (omitempty/absent until v1.191.0): BotScan/BotGuard/Whitelist with IP-family split (`FamilyCounts{ipv4,ipv6,inet,unknown}`; per-IP counters use ipv4/ipv6, `unknown` signals a classification defect).
- `nft.anchors[]` (omitempty/absent until v1.191.0): interpreted JSON VIEW over the existing `nftban_nft_named_counter_*{family,counter}` — **no** new `nftban_nft_anchor_*` metric (SOS-2 reuse, no double-count). Anchors are phase-boundary/pipeline-continuity counters, never accept/drop verdicts.
- Prometheus `nftban_counters_population_phase` gauge = 0; `nftban_firewall_rules_total` documented as a DEPRECATED alias of canonical `nftban_nft_rules_total` (2-minor window); `nftban_suricata_rules_total` kept distinct.

### Decisions (SOS-1..4)
- **SOS-1:** only the validator output/health schema moves to 1.84.0; `nftban stats` (int 2), lifecycle, installer schemas untouched.
- **SOS-2:** anchors reuse the named-counter Prometheus source; JSON view only.
- **SOS-3:** JSON normalizes nft family `ip→ipv4`, `ip6→ipv6` (one JSON vocabulary); Prometheus label stays raw `ip/ip6` for compat (documented bridge).
- **SOS-4:** the emitted `/metrics` text is validated as a consumer parses it.

### Validators added (now guarding this contract)
- **JSON schema** — `internal/validator/counters_contract_v190_test.go`.
- **Prometheus/OpenMetrics** — `internal/metricscontract/openmetrics_v190_test.go` (Gather→expfmt encode→reparse; phase=0; no anchor metric; family ip/ip6; no new series; naming rule; JSON↔Prometheus mutual consistency).
- **nft counting-model** — `cli/lib/nftban/tests/nft_counting_model_guard_v190_test.sh` (single rule-count owner; alias DEPRECATED; suricata distinct; stats schema int 2; T13 health-`--json` projection includes counters_phase).
- **Exporter/lab scrape** — `scripts/lab/openmetrics_scrape_validate_v190.sh`.

### Found & fixed before merge (five cross-surface drift bugs)
1. Go schema 1.84.0 vs shell CLI still 1.83.0 → bumped `cmd_health.sh` + `cmd_status.sh` (CI G2-3).
2. `go.mod`/`go.sum` drift from new parser deps → `go mod tidy` (CI tidy gate).
3. Dead `countNFTablesRules` after the single-owner metric fix → removed (staticcheck U1000).
4. `nftban health --json` advertised 1.84.0 but stripped `counters_phase`/`counters`/`nft` → fixed the jq projection + guard T13 (lab-first consumer-parse).
5. Semgrep IFS-tampering in the lab script (redundant global IFS) → behavior-neutral removal (code-scanning + required conversation resolution correctly blocked the merge).

### Validation
- PR #868 CI green 69/69; post-merge main CI green. **Lab-first PASS** on lab2 (DEB) + lab4 (RPM) + monitor (DEB): `health --json` schema 1.84.0, `counters_phase=contract`, counters/nft absent, phase gauge 0, `nft_rules_total` present, no anchor metric, family ip/ip6 (no relabel), no new counter series, 0 failed units, NRestarts=0, nft authority intact, 0 TEST-NET; reversible binary-swap restored byte-identical on every host.

### Open / baselined (future gates)
- `METRIC-NAMING-TOTAL-GAUGE-DEBT` (legacy `_total` gauges) · `METRIC-FIREWALL-ALIAS-UNEXPOSED` (alias on private registry, not HTTP) · `SCHEMA-BUMP-ALL-SURFACES-CHECKLIST` · `CONTRACT-VALIDATOR-FRAMEWORK` (`CONTRACT_VALIDATOR_FRAMEWORK.md`).

---

## [v1.189.0] - 2026-06-15 — BotScan FCrDNS: verified-crawler whitelist (forward-confirmed rDNS)

**Codename:** `BOTSCAN_FCRDNS` · **PR:** [#866](https://github.com/itcmsgr/nftban/pull/866) · **Scope:** `BOTSCAN_VERIFIED_CRAWLER_WHITELIST_SCOPE.md`

> **What:** security/evasion fix — verify claimed search-crawler UAs by forward-confirmed reverse DNS at analyze-time. **Shell-only; daemon `cmd/nftband` byte-identical `c63d8822`; schema 1.83.0 frozen; NO counters** (deferred to SCHEMA-UNFREEZE).

### Fixed (security)
- **Spoofable crawler whitelist** — `is_whitelisted` matched search crawlers by UA substring only, so `User-Agent: Googlebot` from any IP was blanket-whitelisted and evaded BotScan (404-flood + pattern bans). Now verified by forward-confirmed rDNS.

### Added
- `nftban_botscan_verify_crawler(ip,family)` — PTR must match a provider-documented family suffix (Google/Bing/Yandex/DuckDuckGo/Yahoo-slurp/Apple/Baidu), then forward-resolve to the original IP. **Fail-closed** on no-PTR/suffix-mismatch/forward-mismatch/timeout/NXDOMAIN. Runs at **analyze-time, per unique candidate IP — never per log line** (preserves the v1.187.1 fork-free hot path). Cache by `src_ip+family` (24h/6h/30m), atomic in-flight guard, hard 2s per-lookup timeouts, self-contained resolver (host→dig→nslookup). `BOTSCAN_VERIFY_CRAWLERS` toggle (default on).

### Behavior
- A **verified** crawler is exempt from the **404-flood ban ONLY** (real crawlers legitimately hit 404s). A spoofer (unverified) is banned with a `fake_bot_ua` reason. **Exploit/webshell/scanner URL-pattern bans are NEVER exempted** by crawler-verify — not a blanket IP whitelist. Unverifiable families (facebot) keep the legacy whitelist.

### Validation
- Hermetic `botscan_fcrdns_v189_test` (stubbed resolver) PASS — verify matrix, fail-closed, cache/family-separation, toggle, no-per-line-DNS, exempt-verified/ban-spoofer, structural guard. Regressions pass; shellcheck clean; daemon `c63d8822`.
- **Lab-first real-DNS PASS** (lab2): real Googlebot `66.249.66.1` verified OK + cached; `8.8.8.8` claiming Googlebot fail-closed. Caught + fixed a resolver-dependency bug (the hermetic test had stubbed it).

---

## [v1.188.0] - 2026-06-15 — BotScan-train B2: badbot/aibot easy UX + aibots category

**Codename:** `BOTSCAN_B2_BADBOT_AIBOT` · **PR:** [#864](https://github.com/itcmsgr/nftban/pull/864) · **Ownership:** `B2_BOTSCAN_BADBOT_EASY_UX_OWNERSHIP_DECLARATION.md` · **Lab-first:** `B2_LAB_FIRST_VALIDATION_RECORD.md`

> **What:** easy bot-policy CLI + a new `aibots` pattern category. **Shell + pattern-content + packaging-aware; daemon `cmd/nftband` byte-identical `c63d8822`; schema 1.83.0 frozen; NO counters/daemon-Go/cmd/internal/adaptive/VAL-LOGINMON/FCrDNS.** BotScan counters remain SCHEMA-UNFREEZE.

### Added
- **`aibots` category** (`etc/nftban/patterns.d/botscan/aibots.patterns`) — AI/LLM scraper UA detection, primary-doc-verified tokens.
- **CLI** (`nftban botscan …`): `bots [category] [--enabled|--disabled]` (override-aware listing), `blockbot <name>` (enable), `allowbot <name>` (disable). Friendly token resolver; help text + `commands.registry.yml` updated.
- **Never-ban guard** — `blockbot` refuses Google-Extended/Applebot-Extended/Googlebot/Bingbot/Applebot/facebookexternalhit/ChatGPT-User/Perplexity-User/Claude-User with an explanation (no override written).
- **3-tier no-clobber** — loader reads `override.local` (`NAME|true|false`) which wins over the shipped `ENABLED` column without editing the config(noreplace) `*.patterns`; override.local is operator-owned (not packaged) → survives DEB/RPM upgrades.

### Changed (Option A — migrate-and-preserve, zero live behavior change)
- AI scraper tokens MOVED `badbots.patterns → aibots.patterns` with **ENABLED state preserved exactly** (GPTBot/CCBot/Bytespider stay hard-ban; ClaudeBot stays observe). One owner per token.
- New **PerplexityBot** ships observe/disabled. **AppleBot-Extended removed** from patterns (robots.txt-only → never-ban guard only).

### Packaging
- A new `*.patterns` file is auto-packaged by the existing `%config(noreplace) /etc/nftban/patterns.d/botscan/*.patterns` glob + auto-loaded — no spec/FHS/%files change.

### Validation
- Hermetic `b2_badbot_aibot_v188_test` PASS 1-8; help↔code↔registry guards (v128/130/133/134) pass; shellcheck `-S warning` clean; daemon byte-identical `c63d8822`.
- **Lab-first DEB (lab2) + RPM (lab4) PASS** — migration-preserves-state, override.local no-clobber (not package-owned), never-ban guard (message + no override), daemon NRestarts=0; caught + fixed a dispatch core-sourcing bug.

---

## [v1.187.3] - 2026-06-15 — BotScan-train B1b: banner convergence (one compact posture line)

**Codename:** `BOTSCAN_B1B_BANNER` · **PR:** [#862](https://github.com/itcmsgr/nftban/pull/862)

> **What:** closes BUG-BANNER-INCONSISTENT. Presentation-only; daemon `cmd/nftband` byte-identical `c63d8822`; schema 1.83.0 frozen; no validator-Go/cmd/internal/packaging. Does NOT include the findings helper (B1b-2), B2 bad-bot UX, or counters (SCHEMA-UNFREEZE).

### Changed
- **BUG-BANNER-INCONSISTENT** — one banner path, two intentional render modes. `version`/`status`/`health` keep the **full box** (live-validator posture); every other command renders **one compact one-liner** (`nftban_render_banner_compact`) with a posture glyph + optional cached notice, replacing the old motto 2-liner (`🐧🛡️ NFTBan vX / ban · unban · protect`). `nftban_render_banner_simple` → back-compat shim.
- Compact posture = **cheap-fresh** `systemctl is-active nftband.service` (perm-safe, no `jq`, no validator fork) → 🟢/🟠/🔴/⚪. Full box keeps the live validator. (A daily cache could paint a false 🟢 — rejected.)
- Dynamic notice = **cache-only** `↑ vX available — nftban update` (never network).
- Suppression unchanged (`_v141_banner_suppressed`); notices on the compact line, never inside the box.

### Validation
- New hermetic `b1b_banner_compact_v1873_test.sh` PASS A-E — incl. proof compact **ignores a bogus validator cache** (no hot-path validator fork), failed→🔴, cache-only notice, JSON/none suppression, full-box gate intact. shellcheck `-S warning` clean; v1.187.2 regression passes; daemon `c63d8822`; FHS `--check` rc=0.

### Deferred (tracked)
- **B1b-2** — shared `nftban_render_findings` helper + UX-VERBOSE-FINDINGS adoption (surface-scoping first).
- **VAL-LOGINMON-002-UX** — validator-Go (separate lane).

---

## [v1.187.2] - 2026-06-15 — BotScan-train B1: CLI/text-UX (banner tagline + update-lock friendliness)

**Codename:** `BOTSCAN_B1_TEXT_UX` · **PR:** [#860](https://github.com/itcmsgr/nftban/pull/860)

> **What:** presentation-only CLI/text UX (two operator-requested items). **Shell/data only; daemon `cmd/nftband` byte-identical `c63d8822`; schema 1.83.0 frozen; no packaging/detection-content change.** Does NOT include B2 bad-bot/aibot UX (HOLD), banner unification (B1b, design decision), or BotScan/BotGuard counters (SCHEMA-UNFREEZE major).

### Changed
- **UX-BANNER-TEXT** — Firewall-first tagline: unified banner `Open-source Linux IPS & nftables FW` → `Open-source Linux Firewall & IPS for nftables` (`nftban_output.sh`); `NFTBAN_VERSION_NAME` `Linux IPS & nftables Firewall` → `Linux Firewall & IPS for nftables` (`version.sh`, shown in `nftban version` JSON).
- **UX-UPDATE-LOCK** — friendlier lock-contention message (`cmd_update.sh`): best-effort names the in-progress updater (PID + start time, only when alive), points to `tail -f /var/log/nftban/update.log`, and clarifies `nftban update force` clears only a STALE lock. The flock mechanism is unchanged.

### Deferred (tracked, not in this release)
- **BUG-BANNER-INCONSISTENT** (B1b) — two banner renderers (`nftban_banner_unified` box vs `nftban_render_banner_simple` 2-line motto); needs a design decision on the single banner path.
- **UX-VERBOSE-FINDINGS** (B1b) — which surfaces hide INFO behind `--verbose`.
- **VAL-LOGINMON-002-UX** — validator-Go (moves daemon hash), separate Go train.

### Validation
- New hermetic `b1_text_ux_v1872_test.sh` (behavioral banner render asserts the Firewall-first tagline + `NFTBAN_VERSION_NAME` + update-lock content guards) PASS; shellcheck `-S warning` clean; daemon byte-identical `c63d8822`; FHS `--check` rc=0.

---

## [v1.187.1] - 2026-06-14 — Hotfix: BotScan cycle-timeout regression (main-loop per-line fork removal)

**Codename:** `BOTSCAN_CYCLE_TIMEOUT_FORK_REMOVAL` · **Diagnosis:** `NFTBAN_ROADMAP/V1_187_1_TIMEOUT_ROOT_CAUSE_DIAGNOSIS.md` · **Validation:** `V1_187_1_SRV2_VALIDATION_RECORD.md`
**PR:** [#858](https://github.com/itcmsgr/nftban/pull/858)

> **What:** v1.187.1 fixes the BotScan processor cycle-timeout regression on high-log-count hosts by removing the main-scan per-line subshell-fork overhead, preserving the A4 404-tail bound, and lowering the per-file cap. It does NOT change Lane B, aibots, BotGuard counters, schema, daemon Go, or UX.

### Fixed
- **CORE-BOTSCAN-PROCESSOR-TIMEOUT (v1.187.0 fleet NO-GO on srv2):** the BotScan cycle SIGTERM'd at the 300s `TimeoutStartSec` on srv2 (AlmaLinux 9.8, DirectAdmin, 126 access logs/921 MB). Timing markers pinned the cost to the **main scan loop**, not A4/analyze — one 4.2 MB DA log took **123s / 5497 lines ≈ 22 ms/line**, dominated by **three per-line command-substitution forks**: `parsed=$(parse_line)`, `matched=$(match_url)` (in `process_entry`), and `now=$(nftban_timestamp_unix||date)`. The soft budget (`BOTSCAN_SCAN_BUDGET_SECS=180`) is checked between files only, so a single slow file straddling the boundary overran toward 300s; v1.187 Lane A's forward cursor (≤1 MiB ≈ 5k lines/file vs the old `tail -1000`) exposed the latent fork cost. (A4 `count_404_tail` measured 0s — its bound fires; `analyze` ~1s.)

### Changed
- `nftban_botscan_parse_line` → no-fork `nftban_botscan_parse_line_g` (fields via `_BS_IP/_BS_URL/_BS_METHOD/_BS_STATUS/_BS_UA` globals); the echo-API `parse_line` is retained as a thin wrapper delegating to `_g` (no drift for `cmd_botscan` + existing tests). Hot loops call `_g` directly.
- `nftban_botscan_match_url` → no-fork `nftban_botscan_match_url_g` (`_BS_MATCHED` global); echo wrapper retained.
- `process_entry` per-line timestamp → fork-free `printf -v now '%(%s)T' -1` (bash 4.2+; old fork fallback).
- `BOTSCAN_SCAN_MAX_BYTES_PER_FILE` default 1 MiB → 256 KiB (cheap time backstop; rotation cursor still covers every file across cycles).
- Retains the A4 404-tail budget bound (per-file soft-deadline + total-bytes backstop + `404-rotate` cursor) from this release train.

### Preserved
- Parse semantics, URL/UA match semantics (all match types), 404-flood detection, the v1.186.1 IFS pattern-ban fix, signal format, thresholds/windows/durations.
- **Daemon `cmd/nftband` BYTE-IDENTICAL to v1.186 `c63d8822`** (shell/data only); schema 1.83.0 frozen; NO packaging/FHS change (header `meta:version` only).

### Validation
- New hermetic `botscan_nofork_parity_v1871_test.sh` (parse_line_g == echo across IPv4/IPv6/bracketed/no-UA/malformed; match_url_g == echo across every match type + no-match) + `botscan_404_tail_bound_v1871_test.sh` + v187 throughput + v185 deadline/rotation + v1.186.1 IFS + http_log_discovery_v177 regressions PASS; shellcheck `-S warning` clean.
- **srv2 production proof 3/3** (reversible single-file swap): cycles 209s/185s/183s all `Result=success` status 0, none near 300s; throughput ~2× (13.4k → 25.6k entries/cycle); daemon active NRestarts=0, 0 nftban failed units, nft authority intact, 0 TEST-NET leak, 0 bans (no false-positive storm).

---

## [v1.187.0] - 2026-06-14 — BotScan throughput (Lane A): BOTSCAN-SCAN-THROUGHPUT

**Codename:** `BOTSCAN_SCAN_THROUGHPUT` · **Plan:** `NFTBAN_ROADMAP/V1_187_IMPL_PLAN_CODE_CHALLENGE.md` + `V1_187_DECISION_ADDENDUM.md` · **Validation:** `V1_187_LANE_A_VALIDATION_RECORD.md`
**PR:** [#855](https://github.com/itcmsgr/nftban/pull/855)

> **What:** closes the flood-host BotScan throughput class that v1.185's per-file cap left as a documented KNOWN LIMITATION (tail-biased → dropped the majority of bytes on busy hosts). **Shell/data only.** Does NOT include bot-policy UX (Lane B, next), adaptive promotion (HOLD), FCrDNS (v1.188), or BotGuard counters (separate schema-unfreeze lane).

### Changed — BotScan scan path (`nftban_botscan.sh` + `nftban_http_logs.sh`)
- **A1 — Forward-mode per-file cursor.** `nftban_http_read_incremental` gains opt-in `NFTBAN_HTTP_LOG_READ_FORWARD`: emits the oldest unread window `[start, start+MAX)` and advances the offset by exactly what it emits → a backlog larger than the per-cycle cap drains **forward across cycles with no skipped bytes**, on a dedicated `/var/lib/nftban/botscan/proc-offsets` dir (distinct from the collector, which stays byte-identical). Per-file cap default 64 KiB → 1 MiB.
- **A2 — Candidate prefilter.** One C-speed `grep -E -f` pass (a *sound ERE superset* of the bash matcher; GNU grep DFA → linear, cannot ReDoS-stall) drops the measured 49–90% droppable fraction before the ~55-eps per-line bash loop. srv2 (fleet high-water: 128 MB / 696,883 lines) → **77% dropped** (159,124 candidates).
- **A3 — Regex hygiene.** Literal/regex split feeds the prefilter; no combined bash alternation.
- **A4 — 404-window Option 1.** An independent fixed-tail re-read, **independent of the forward cursor** (never reads/rewinds its offset), preserves 404-burst detection.
- Per-cycle wall-time stays bounded by the processor's soft deadline (`BOTSCAN_SCAN_BUDGET_SECS=180` < `TimeoutStartSec=300`) → never SIGTERM'd (v1.185 liveness preserved).

### Envelope
- Daemon `cmd/nftband` **BYTE-IDENTICAL to v1.186 (`c63d8822`)** (shell/data only); schema 1.83.0 frozen; no packaging/FHS change.

### Tests / validation
- New hermetic `botscan_throughput_v187_test.sh` **PASS 3/3** (forward cursor no-skip across cycles; prefilter soundness / no ban regression; 404 fixed-tail independence). v185 deadline/rotation regression + v1.186.1 IFS test pass; shellcheck clean. Real-host srv2 prefilter 77% drop; bounded-by-design; cross-distro/uutils via the v1.186.1 rollout.
- **CI determinism fix (unrelated to BotScan): help/code doctest guard** (`v130_subcommand_flag_help_code_test.sh`) — eliminated a SIGPIPE/`pipefail` flake (`printf | grep -qwF` → here-string) that intermittently mis-flagged a *matched* token as undocumented, and allowlisted the deprecated `firewall init` alias (v1.38.0 BUG-002 → rebuild) in `v134_help_code_alias_allowlist.tsv`. Now deterministic 67/0. CI-test + allowlist only; no product/daemon change.

---

## [v1.186.1] - 2026-06-14 — Hotfix: BotScan URL/UA pattern-ban correctness (IFS word-split)

**Codename:** `BOTSCAN_PATTERN_BAN_IFS_HOTFIX` · **Finding:** `NFTBAN_ROADMAP/V1_187_FINDING_BOTSCAN_PATTERN_BAN_IFS.md` · **Lab record:** `V1_186_1_LAB_VALIDATION_RECORD.md`
**PR:** [#853](https://github.com/itcmsgr/nftban/pull/853)

> **v1.186.1 fixes BotScan URL/UA pattern ban correctness under the production runtime IFS and restores catalog/custom pattern ban behavior.** It does NOT fix BotScan throughput (`BOTSCAN-SCAN-THROUGHPUT` remains open for v1.187) or bot-policy UX (`BOTSCAN-BOT-POLICY-UX` remains open for v1.187).

### Fixed — pattern-ban IFS word-split (`nftban_botscan_analyze`)
- The lib sets a global `IFS=$'\n\t'` (no space) at source time; the processor (`cli/sbin/nftban-botscan-processor`) inherits it. `analyze` iterated the per-IP matched-pattern list with an unquoted `for pattern_name in $patterns` over a space-joined value (`" NAME"`) → the leading space was kept → the pattern key lookup missed → the per-pattern **threshold/window/ban-duration were never applied** (defaults 5/60/1800 used instead).
- **Effect (measured, no overclaim):** `threshold=1/2` scanner/exploit/webshell patterns (sqlmap, nikto, masscan, Log4Shell/CVE_*, webshells WS_*) failed to ban on the first/second matching hit; high-volume crawler matches still emitted a weaker default **grey** signal; the **404-flood path was unaffected**.
- **Fix:** IFS-independent split — `IFS=$' \t\n' read -ra` — the same idiom already used for the http-log override split (`nftban_http_logs.sh`). 8 lines, no behavior change beyond applying the configured pattern tuning.

### Tests
- New hermetic `cli/lib/nftban/tests/botscan_pattern_ban_ifs_v1861_test.sh`: useragent + url-404 pattern bans fire on the first matching hit under the lib's REAL runtime IFS (404-flood disabled so the ban can only come from the pattern path). Fails pre-fix, passes post-fix. v185 regression + shellcheck clean.

### Envelope
- Shell-only → **daemon `cmd/nftband` BYTE-IDENTICAL to v1.186 (`c63d8822`)**; schema 1.83.0 frozen; no packaging/FHS change (header `meta:version` only).

### Validation
- A/B lab-first across all 9 fleet hosts (Ubuntu 22.04/24.04/26.04, CentOS Stream 10, AlmaLinux 9.8/10.1; GNU + uutils coreutils): installed=NO_BAN → fixed=BAN(pattern), 0 nftban failed units, nft authority intact. Zero install mutation, signal-only, reserved IP. (Separate follow-up: `TAIL_OBSOLETE_SYNTAX_UUTILS` — Ubuntu 26.04 uutils rejects `tail -1000` in the pinned/interactive path; production incremental reader unaffected.)

---

## [v1.186.0] - 2026-06-14 — Roundcube webmail auth source (LoginMon) — DirectAdmin central /var/log/roundcube layout

**Codename:** `ROUNDCUBE_WEBMAIL_AUTH_SOURCE_DA_ONLY` · **Decision:** `NFTBAN_ROADMAP/V1_186_ROUNDCUBE_DA_ONLY_DECISION.md` · **Ownership:** `ROUNDCUBE_WEBMAIL_AUTH_SOURCE_OWNERSHIP_DECLARATION.md` · **Gate-0:** `ROUNDCUBE_GATE0_CAPTURE_RECORD.md` · **Lab-first:** `V1_186_ROUNDCUBE_LABFIRST_VALIDATION_RECORD.md`
**PR:** [#851](https://github.com/itcmsgr/nftban/pull/851) (squash `23600beb`)

> **What:** LoginMon gains a Roundcube webmail source that owns ONLY the webmail interactive **auth_failure** event class from the central `/var/log/roundcube/userlogins.log`. **Coverage is narrow: DirectAdmin hosts using the central `/var/log/roundcube` layout.** NOT claimed: all DirectAdmin installs, cPanel, Plesk, app-local `log_dir` installs, or all webmail brute-force coverage.

### Added — Roundcube webmail auth_failure source (DirectAdmin central-log)
- `internal/loginmon/detector/roundcube.go` — parses `Failed login for <user> from <IP> in session <sid>` → `Verdict{Reason: ReasonRoundcubeAuthFail=5003, Service: "roundcube"}`. `Successful login` never verdicts (prefilter + explicit guard + test).
- **Mandatory public-IP-only guard** (`isPublicLoginIP`): rejects loopback/RFC1918/link-local/ULA/multicast/unspecified/malformed BEFORE any score/ban — fleet-safe no-op on hosts logging 127.0.0.1; auto-neutralizes the dovecot `rip=localhost` webmail mirror.
- `internal/loginmon/roundcubediscovery.go` — DA-only discovery of the central `/var/log/roundcube/userlogins.log` (nil unless DirectAdmin; no cPanel per-user / no Plesk glob). `WARN_NO_LOGS`/`NO_LOGS` when absent — never HEALTHY.
- `internal/loginmon/module.go` — `[LOGINMON] roundcube: state=...` input-state wiring; root `nftband.service` (CAP_DAC_OVERRIDE) reads the `drwx--x---` webapps log directly (Option A).
- Disjoint from BotScan (web_abuse), WebAuth (HTTP 401/wp-login), and dovecot/mail (IMAP/POP3) — distinct source `roundcube` + reason `5003`; independent ownership audit PASS.

### Not claimed (deferred to v1.186.x)
- cPanel (per-user `$HOME/logs/roundcube/` discovery), Plesk (central log, pending captured line), and app-local `log_dir` installs (config-driven `log_dir` resolution). srv4 (DA + RC 1.6.15, unset `log_dir`) is the proven app-local caveat — a safe no-op until the refinement ships.

### Envelope
- Daemon `cmd/nftband` hash **MOVES** (expected; daemon-Go) `dc4e1a33`→`c63d8822` (first daemon-Go since v1.185; canonical `CGO_ENABLED=0 go build -trimpath -buildvcs=false ./cmd/nftband` reproduces it). Schema 1.83.0 frozen. NO packaging/FHS/cmd change (release-prep header `meta:version` only).

### Validation
- Hermetic detector + discovery suites green; independent source-ownership audit PASS (`READY_FOR_MERGE=YES`).
- Lab-first reversible daemon-swap across 9 hosts, **0 live bans**: dns1 (Ubuntu 24.04, DA 1.7.1) WARN_NO_LOGS→OK→2 public detections (IPv4+IPv6), localhost+RFC1918 rejected, `Successful login` ignored; dns2/srv1/srv2/srv3/srv4 WARN_NO_LOGS; lab2 (Plesk) + lab4 (cPanel) + monitor NO_LOGS no-op. Cross-distro: Ubuntu 22.04/24.04/26.04, CentOS Stream 9/10, AlmaLinux 9.8/10.1.

---

## [v1.185.1] - 2026-06-14 — Hotfix: botscan state-dir + stale-oneshot recovery + reset-failed guidance

**Codename:** `BOTSCAN_STATE_DIR_AND_STALE_ONESHOT_RECOVERY` · **Scope:** `NFTBAN_ROADMAP/V1_185_1_HOTFIX_SCOPE.md` · **User guide:** `USER_GUIDE_DEGRADED_BOTSCAN_AFTER_UPGRADE.md`
**PR:** [#849](https://github.com/itcmsgr/nftban/pull/849)

> **Why:** upgrading to v1.185 produced a false **DEGRADED** that `--repair` could not clear. Proven on monitor: the v1.185 botscan processor completes in ~6s rc=0, but a STALE v1.184 300s-timeout `failed` state latched *before* the upgrade flipped install validation to DEGRADED. Also a real persistence bug: the scanner's rotation cursor could never be written.

### Fixed — H1: botscan state directory (rotation cursor persistence)
- Added `/var/lib/nftban/botscan` (nftban:nftban 0750) to `build/fhs-spec.yaml`; regenerated `tmpfiles.d/nftban.conf`, `fhs_directories.json`, `nftban_fhs_spec.sh`. The `nftban-botscan` processor runs as `User=nftban` and could not create a subdir under `/var/lib/nftban` (root:nftban 0750) — the in-script `mkdir` failed silently and `scan-rotate` never persisted (rotation never advanced on multi-file hosts; `scan-rotate.tmp: No such file` in the journal). The dir is now created by tmpfiles/package.

### Fixed — H2: stale-oneshot recovery on upgrade
- `internal/installer/validate/systemd_payload.go`: the v1.174 stale failed-unit classification now recovers a **stale-clearable oneshot** (`nftban-botscan.service`) whose failure is strictly BEFORE the install window **without** the live-health gate — a oneshot's own `failed` latch can make the live-health probe read unclean (circular), which previously kept it from ever recovering. Real in-window failures still DEGRADE (in-window guard retained). 5 unit tests (monitor scenario, in-window-degrades, unknown-time fail-safe, non-oneshot-not-broadened, membership).

### Fixed — H3: remediation guidance includes reset-failed
- `cli/lib/nftban/cli/cmd_update.sh` + `cmd/nftban-installer/main.go` DEGRADED remediation now surfaces `systemctl reset-failed nftban-botscan.service` + a run ahead of `--repair`, noting that `--repair` alone does not clear a stale oneshot latch. (Also fixed a pre-existing stale v127 test assertion: the `sudo` form was removed in v1.131.4.)

### Envelope
- **Daemon `cmd/nftband` BYTE-IDENTICAL to v1.185 `dc4e1a33`** — installer-Go + shell + FHS-generated only. Schema 1.83.0 frozen. FHS body adds one dir (`--check` rc=0).
- **Validation:** lab2 (DEB) + lab4 (RPM/EL9) reversible swap — H1/H1-functional/H2/H3/reboot all PASS; monitor (v1.185.0) direct — dir-present run writes scan-rotate, prior `No such file` error eliminated. srv2 rotation-advance inconclusive (host on v1.184 times out — a v1.187 throughput boundary, not a v1.185.1 failure). PR #849 CI green (69 pass / 0 fail).

---

## [v1.185.0] - 2026-06-14 — Installer restart-debt (Lane A) + BotScan processor timeout-at-scale (Lane B)

**Codename:** `INSTALLER_CORRECTNESS_PARITY_AND_BOTSCAN_TIMEOUT_AT_SCALE` · **Scope:** `NFTBAN_ROADMAP/V1_185_INSTALLER_CORRECTNESS_PARITY_SCOPE.md`
**PR:** [#847](https://github.com/itcmsgr/nftban/pull/847) · **Records:** `V1_185_LANE_A_INSTALLER_RESTART_VALIDATION_RECORD.md`, `V1_185_LANE_B_BOTSCAN_FLEET_VALIDATION_RECORD.md`, `CORE_BOTSCAN_PROCESSOR_TIMEOUT_AT_SCALE_FINDING.md`

> **Why:** (A) on an upgrade over a live daemon the installer's `systemctl start` is a no-op, so the OLD binary kept running with the new files on disk (found on dns2 during the v1.184 fleet rollout). (B) the BotScan processor did a whole-spool single pass per cycle and on high-volume hosts could not finish within `TimeoutStartSec=300` → SIGTERM → never banned + alert every cycle.

### Fixed — Lane A: INSTALL-UPGRADE-NO-DAEMON-RESTART (installer; DEB + RPM + source parity)
- `StartDaemon` (`internal/installer/services/daemon.go`) captures `wasActive := ServiceActive("nftband.service")` before touching the unit and, **only** on the upgrade-over-live-daemon path, issues `ServiceTryRestart` (`systemctl try-restart` — cycles iff active, no-op if deliberately stopped) at the end to load the upgraded binary. Fresh installs (inactive) skip it (already a clean first-start).
- New executor method `ServiceTryRestart` on the interface + real (`RunTimeout(90s, "systemctl", "try-restart", unit)`) + mock executors. One shared `phaseConfigure` path → identical behavior for `--deb`/`--rpm`/`--source`.
- Tests: `TestStartDaemon_UpgradeOverLiveDaemon_TryRestarts` (pre-active → try-restart) + `TestStartDaemon_FreshInstall_NoTryRestart` (inactive → none).

### Fixed — Lane B: CORE-BOTSCAN-PROCESSOR-TIMEOUT-AT-SCALE (shell; BotScan liveness/completion)
- `nftban_botscan.sh` `nftban_botscan_process_logs` + `cli/sbin/nftban-botscan-processor`: per-file byte cap (`BOTSCAN_SCAN_MAX_BYTES_PER_FILE`, default 64 KiB, tail-biased via the shared incremental reader) + a soft deadline checked **between files** (`BOTSCAN_SCAN_BUDGET_SECS`, default 180s) that checkpoints a rotation cursor (`/var/lib/nftban/botscan/scan-rotate`) and exits rc=0 to resume next cycle → never SIGTERM'd. `analyze()` always runs.
- CI test: `cli/lib/nftban/tests/botscan_deadline_rotation_v185_test.sh`.
- **Scope discipline (no overclaim):** this fixes the **liveness/completion** class (never-completes / SIGTERM / alert-per-cycle), NOT full-spool per-cycle coverage / fleet-health / high-throughput ban yield. It scans the newest ~64 KiB/file/cycle. **`BOTSCAN-SCAN-THROUGHPUT` remains OPEN** (v1.187 follow-up; the bash per-line matcher needs a C-speed prefilter for full-spool coverage).

### Envelope
- **Daemon `cmd/nftband` is BYTE-IDENTICAL to v1.184 `dc4e1a33`** — Lane A is in `cmd/nftban-installer` (not the daemon import graph); Lane B is shell-only. **Schema 1.83.0 frozen. No packaging/FHS/cmd change.**
- **Validation:** Lane A lab-first — lab2 (DEB) + lab4 (RPM) + lab2 (source) all cycle the daemon on upgrade via try-restart; lab2 reboot clean; SSH + firewall preserved; no package-family divergence. Lane B real-host reversible-shell-swap across all 9 hosts — srv2/srv4/dns2/srv3 cured (SIGTERM/never-completes → rc=0/success); lab2/lab4/monitor/srv1/dns1 no regression. PR #847 CI green.

---

## [v1.184.0] - 2026-06-13 — Suricata EVE rotation fix + Train-1 detection-tail closure

**Codename:** `SURICATA_EVE_ROTATION_FIX_AND_TRAIN1_DETECTION_TAIL_CLOSURE` · **Classification:** `NFTBAN_ROADMAP/TRAIN1_INPUT_AUTHORITY_DETECTION_TAIL_CLASSIFICATION.md`
**PR:** [#845](https://github.com/itcmsgr/nftban/pull/845) (sq `d0daee92`)

> **Why:** the Suricata EVE reader opened `eve.json` once and `Seek(SeekEnd)`, with no rotation handling — after logrotate it held a stale offset/fd and silently read 0 new alerts. This closes the input-authority program's detection tail. **No new ban surface, no new source.**

### Fixed — SURICATA-EVE-ROTATION-MISS (correctness-when-enabled; suricata module dormant in daemon)
- `internal/suricata/reader.go` `reopenIfRotated()` is called at the top of `drainEvents` (both inotify + polling paths funnel through it). It handles **copytruncate** (the open fd shrank below our read offset → `size < offset` → `Seek(0)` + reader reset) and **rename/create** (`os.SameFile` false → reopen the path + read the rotated-in file from the start). Best-effort: stat/open errors keep the current fd and the next tick retries.
- Tests: copytruncate, rename+create, and a no-rotation normal-tailing guard (no spurious re-read). `go test ./internal/suricata/...` + `go build ./...` green.

### Train-1 (input-authority) detection-tail closure — register-only
- **DET-WEBAUTH** — already closed by **v1.179** (`webauth.go` parses generic apache/nginx 401; LiteSpeed shares the combined access-log format). Register-close only; no code in this release.
- **Roundcube** — **DEFERRED** as a future new-source lane `ROUNDCUBE_WEBMAIL_AUTH_SOURCE` (NOT folded here; needs logging prereqs + parser + watcher + dedup + `LOG_SOURCE_OWNERSHIP_DECLARATION`). Direct IMAP/POP3 brute-force stays covered by dovecot. **Roundcube webmail-auth coverage is NOT claimed in this release.**

### Envelope
- **Daemon `cmd/nftband` is BYTE-IDENTICAL to v1.183 `dc4e1a33`** — the suricata EVE reader is not in the daemon import graph (suricata module dormant); the fix lands in the suricata processor path (correctness-when-enabled). **Schema 1.83.0 frozen. No packaging/FHS/cmd change.**
- **Validation:** suricata rotation units + `go build ./...` green; PR #845 CI green (0 fail; 0 GHAS-check fail — the gosec `Close()`-unhandled advisory matches the established pre-existing baseline pattern at `reader.go:99/191`, the gosec check itself is green).

---

## [v1.183.0] - 2026-06-13 — LoginMon input-readability finding (HEALTH-NO-INPUT-AXIS increment 2)

**Codename:** `LOGINMON_INPUT_READABILITY_FINDING` · **Scope/design:** `NFTBAN_ROADMAP/V1_182_GLOBAL_HEALTH_INPUT_AXIS_SCOPE.md`
**PR:** [#843](https://github.com/itcmsgr/nftban/pull/843)

> **Why:** the `DETECTION_INPUT_AUTHORITY` audit flagged that an enabled module reading *nothing* reads healthy. Increment 1 (v1.182) made LoginMon per-source input-state observable over daemon IPC; increment 2 surfaces it through `nftban health` — **without unfreezing the M81-6 health-output schema.**

### Changed — LoginMon input-readability surfaced as a warning finding (no new ban surface)
- The validator already queries the journal (`queryJournal`). `evaluateLoginMon` (`internal/validator/module_health.go`) now reads the daemon's own `[LOGINMON] <src>: state=...` startup lines (v1.179 webauth + v1.180 ftpauth), derives an internal input-readability state (`loginMonInputState`/`parseLoginMonState`/`worseInputState`, worst-of precedence `no_logs > warn_no_logs > ok > unknown`), and emits the new `VAL-LOGINMON-002` warning finding (`CodeLoginMonNoInput`) when an enabled module's source reports no input. The daemon is the authority on its own watchers — no IPC client, no state file.
- `types.go`: `InputState` (`ok`/`warn_no_logs`/`no_logs`/`unknown`) + `ModuleHealth.Input` as an **INTERNAL** field (`json:"-"`, drives the finding, NOT serialized; `ToJSONLegacy`/rebuild parsers + the frozen `ModuleJSON` untouched).

### Schema intentionally NOT extended
The frozen M81-6 health-output schema was deliberately left unchanged — `health_output.go`/`health_mapper.go` explicitly not extended (comments record why). A first-class JSON **Input axis** remains **deferred to the SCHEMA-UNFREEZE major.**

### Envelope
- Daemon `cmd/nftband` source moves (validator compiled in): `6fdfd975`→`dc4e1a33`. **Schema 1.83.0 frozen** (`ModuleJSON` unchanged; `health_mapper_test` schema_version assertion still 1.83.0). **No packaging/FHS/cmd change.**
- **Validation:** parse/precedence units + starved→finding + ok→no-finding (mock journal reader); `go test ./internal/validator/...` + `go build ./...` green; CI #843 green / 0 GHAS.

---

## [v1.182.0] - 2026-06-13 — LoginMon input-state observability (HEALTH-NO-INPUT-AXIS, increment 1)

**Codename:** `LOGINMON_INPUT_STATE_OBSERVABILITY` · **Scope/design:** `NFTBAN_ROADMAP/V1_182_GLOBAL_HEALTH_INPUT_AXIS_SCOPE.md`
**PR:** [#841](https://github.com/itcmsgr/nftban/pull/841) (sq `b25ce51e`)

> **Why:** the `DETECTION_INPUT_AUTHORITY` audit flagged that an enabled module reading *nothing* shows healthy. The validator's `module_health.go` derives health from the kernel ruleset + service state and never queries daemon IPC, so it cannot see watcher starvation; the daemon (root `nftband.service`) is the authority on its own watchers.

### Added — LoginMon input-state observability (no new ban surface)
- `Module.inputSources` (mu-guarded) + `recordInputState`/`inputStateSnapshot`; captured at watcher startup for **webauth** (v1.179) and **ftpauth** (v1.180) with the shared `OK`/`WARN_NO_LOGS`/`NO_LOGS` vocabulary (aligned with BotScan v1.177).
- Surfaced via `LoginMonStatusExtra.InputSources` (json `input_sources`, `omitempty`) + `ToExtraInfo` over the existing daemon module-status IPC — **byte-equivalent wire format for existing readers when nothing captured**. An enabled-but-starved source is now observable.

### Not in this release (next lane)
Increment 2 — fold this daemon-known input-state into the validator's `ModuleHealth` as a first-class **Input axis** surfaced by `nftban health` (needs a CLI→daemon health bridge) + extend to BotGuard/other modules.

### Envelope
- Daemon `cmd/nftband` source moves **loginmon-only** (`b9a462a4`→`6fdfd975`; additive). **Schema 1.83.0 frozen. No packaging/FHS/cmd change.**
- **Validation:** unit tests (snapshot round-trip + defensive copy, Status surfacing, omitted-when-empty); `go test -race ./...` + `go build ./...` green; CI #841 green / 0 GHAS.

---

## [v1.181.0] - 2026-06-13 — auth-source dead-key cleanup + duplicate-source guard

**Codename:** `AUTH_SOURCE_DEAD_KEY_AND_DUPLICATE_GUARD` (hygiene/guardrail — **no new ban surface**) · **Scope:** `NFTBAN_ROADMAP/V1_181_AUTH_SOURCE_DEAD_KEY_AND_DUPLICATE_GUARD_SCOPE.md`
**PR:** [#839](https://github.com/itcmsgr/nftban/pull/839) (sq `88280fb5`)

> **Why:** two distro-config keys (`pureftpd_log`, `exim_reject_log`) had **zero readers** — only `directadmin_login_log` / `exim_log` / `dovecot_log` are consumed via `DistroKey`; pure-ftpd has been journal facility-11 since v1.180 and exim uses `mainlog`. Real-prod sampling (v1.180) also disproved adding cphulkd/exim-reject as auth sources (duplicate/false-positive). This lane removes the dead keys and adds a CI guard so those rejected sources cannot be silently re-wired.

### Added — duplicate-source guard
- New `internal/loginmon/source_ownership_guard_test.go` fails CI if a future change wires a known duplicate/non-auth source into the LoginMon ban path without a fresh `LOG_SOURCE_OWNERSHIP_DECLARATION` + non-duplicate proof:
  - **cphulkd `login_log` NOT in `panelLogPaths`** (duplicates cPanel access_log-401, PanelDetector-owned).
  - **exim `rejectlog` NOT in `mailLogPaths`** (auth subset duplicates `mainlog`; unique lines are spam/RBL/HELO = `web_abuse`, not auth).
  - **FTP file globs exclude pure-ftpd** (journal-routed) and any `rejectlog`.
  - **journal facilities pinned to `{auth 4, authpriv 10, ftp 11}`** — extracted to `journalAuthFacilities` so the set is testable.

### Removed — proven-dead config keys (zero readers)
- `pureftpd_log` + `exim_reject_log` (and the orphaned FTP section comment) from all **21 `etc/nftban/distros/*.conf`**.
- The same two keys from the validator `REQUIRED_FIELDS` (`cli/lib/nftban/tests/validate_distro_configs.sh`) and from `internal/loginmon/distroconf/distroconf_test.go`.

### Envelope
- Daemon `cmd/nftband` source moves **loginmon-only** (`cce992a1`→`b9a462a4`; journal-watcher arg refactor, no behavior change). **Schema 1.83.0 frozen. No packaging/FHS/cmd change.**
- **Validation:** `go test -race ./...` + `go build ./...` green; PR #839 CI green (56 pass / 1 skip / 0 fail; 0 GHAS). `validate_distro_configs.sh` has a pre-existing rc=1 on the `NFTBAN_LOGIN_*` line-format check unrelated to this lane (diff vs main empty).

---

## [v1.180.0] - 2026-06-13 — LoginMon FTP auth-input (pure-ftpd facility-11 + vsftpd/proftpd source correctness)

**Codename:** `LOGINMON_FTP_AUTH_INPUT` (FTP-only) · **Record:** `NFTBAN_ROADMAP/V1_180_LOGINMON_FTP_IMPL_RECORD.md`
**PR:** [#837](https://github.com/itcmsgr/nftban/pull/837) (sq `999c9428`)

> **Why:** the Go `FTPDetector` existed but was unfed — no FTP source reached it. Worse, production pure-ftpd (deployed fleet-wide) logs auth failures to **syslog facility ftp (11)**, which the LoginMon journal watcher did not consume (auth/authpriv only) → FTP brute-force was invisible to the daemon.

### Added — LoginMon FTP auth-input (auth_failure only)
- **pure-ftpd → journal `SYSLOG_FACILITY=11`** added to `runJournalWatcher` (the FTPDetector consumes via `processLine`). `/var/log/pureftpd.log` is stats-only/empty and is intentionally NOT treated as an auth source.
- **vsftpd / proftpd → file watchers** (`internal/loginmon/ftpdiscovery.go`); pure-ftpd dropped from file globs to avoid double-counting.
- Root daemon (`CAP_DAC_OVERRIDE`) reads directly — no collector/spool. Zero-input health-visible (`[LOGINMON] ftpauth: state=…`).

### Event ownership (LOG_SOURCE_OWNERSHIP — one event class, one ban owner)
- FTP authentication failures → **LoginMon `auth_failure`** (`ReasonFTPAuthFail`). No BotScan/BotGuard ownership of FTP auth.

### Fixed (real-production-traffic sampling of srv1-4)
- **vsftpd file-format gate:** `Detect()` required the `"vsftpd"` substring absent from `/var/log/vsftpd.log` (only `FAIL LOGIN: Client "<ip>"`). Real vsftpd brute from the file is now detected.
- **pure-ftpd IP extraction:** read a trailing `[<ip>]` bracket real pure-ftpd never emits; the real format is `(?@<ip>) … Authentication failed for user [<username>]`. Added `extractParenAtIP`.
- **IPv4/IPv6 family parity** for every detector path (16/16 cases).

### Health behavior
- pure-ftpd present → journal coverage OK even with `files=0`; vsftpd/proftpd present with missing files → `WARN_NO_LOGS`; no FTP daemon → `NO_LOGS`.

### Explicitly NOT in scope (real-prod sampling disproved them)
- **No cphulkd reader** (login_log duplicates cPanel access_log-401 ownership) · **no exim-rejectlog reader** (auth subset duplicates exim mainlog; unique lines are spam/RBL/HELO, not auth) · no Roundcube · no global `module_health` input-axis · no fleet rollout. Tracked as v1.181 (plan-only dead-key/duplicate-source guard).

### Envelope
- Daemon `cmd/nftband` source moves **loginmon-only** (`36978621`→`cce992a1`). **Schema 1.83.0 frozen. No packaging/FHS/cmd change.**
- **Validation:** detector matrix (real pure-ftpd format, IPv4+IPv6, journal-vs-file routing, success-login control) + `go test -race` + `go build ./...` green; PR #837 CI green / 0 GHAS; **lab2 binary-swap PASS** — IPv4→v4 set + IPv6→v6 set kernel-banned (`nft list ruleset`), success-login not banned, SSH preserved, test IPs scrubbed.

---

## [v1.179.0] - 2026-06-13 — LoginMon web-auth runtime (HTTP basic-auth 401 + WordPress wp-login failed-credential)

**Codename:** `LOGINMON_WEB_AUTH_RUNTIME` (v1.178-B/v1.179) · **Records:** `NFTBAN_ROADMAP/V1_179_LOGINMON_WEB_AUTH_IMPL_RECORD.md`, `LOG_SOURCE_OWNERSHIP_AND_MODULE_BOUNDARY_AUDIT.md`
**PR:** [#835](https://github.com/itcmsgr/nftban/pull/835) (sq `405a8c79`)

> **Why:** Go LoginMon detected WordPress but had no web access-log watcher; apache/nginx HTTP-auth was advertised with no consumer → web/WordPress auth attacks invisible to the daemon.

### Added — LoginMon web-auth runtime (auth_failure only)
- `internal/loginmon/detector/webauth.go` + `webdiscovery.go` + a supervised (v1.176-respawn) web access-log watcher. Owns ONLY the **`auth_failure`** event class: HTTP **status 401** (generic apache/nginx → `http-auth`) + WordPress `POST /wp-login.php` status-200 failed-credential (→ `wordpress`). Panel-aware discovery (DA/cPanel/Plesk/generic), realpath-canonicalize (cPanel `domlogs` symlink chain), exclude error/compressed/rotated, bounded.
- Root daemon (`CAP_DAC_OVERRIDE`) reads logs **directly** — no BotScan collector/spool. Zero-input health-visible (`[LOGINMON] webauth: state=…`).

### Event ownership (per the LOG_SOURCE_OWNERSHIP contract — one event class, one ban owner)
- **NOT matched** (web_abuse → BotScan→BotGuard): `/xmlrpc.php`, wp-login high-rate floods, **403 Forbidden** (authz deny/scanner/WAF), scanner/probe 404s, bad-bot UAs. cPanel `/login/` 401 stays PanelDetector-owned.

### Fixed (caught by real-production-traffic sampling)
- **status-vs-size false-ban:** loose substring matched the bytes-sent SIZE field as the status. Now **structural** (`parseRequestAndStatus`): the status is parsed as a field and method/path are matched in the request line only (kills the referer/UA false-match too).
- **DA httpd/nginx mirror double-count:** every request logged to both dirs → counted twice. Prefer `httpd/domains`; skip the nginx mirror when httpd has logs.

### Scoring — REST_401_SCORING_DECISION = CONSERVATIVE_DEFAULT
wp-login failed-credential score **20**; generic/REST HTTP-401 score **8**; scorer TempBan threshold **45** unchanged → incidental logged-out browser/plugin REST-401s don't ban quickly; sustained probing accumulates.

### Envelope
- Daemon `cmd/nftband` source moves **loginmon-only** (`48b82663`→`36978621`). **Schema 1.83.0 frozen. No packaging/FHS/cmd change.**
- **Validation:** unit tests incl. **real sanitized production traffic** (srv1-4/dns1-2) + size-collision + referer + DA-dedup guards; full `go test ./...` green, `-race` clean; CI green / 0 GHAS; real-prod read-only sampling + **final lab binary-swap PASS lab2 (generic) + lab4 (cPanel domlogs canonicalize)**.

### New governance
- **`LOG_SOURCE_OWNERSHIP_DECLARATION`** is now a mandatory release gate for any detector/log-source/watcher/parser/ban-path change (`LOG_SOURCE_OWNERSHIP_DECLARATION_TEMPLATE.md`).

---

## [v1.178.0] - 2026-06-13 — BotScan read-authority (cap-scoped collector → nftban-readable spool)

**Codename:** `BOTSCAN_READ_AUTHORITY` (v1.178-A) · **Records:** `NFTBAN_ROADMAP/BOTSCAN_READ_AUTHORITY_SCOPE.md`, `BOTSCAN_READ_AUTHORITY_IMPL_RECORD.md`, `V178A_PACKAGED_INSTALL_LAB_VALIDATION.md`, `V1_177_DIAGNOSTIC_FLEET_VALIDATION.md`
**PR:** [#833](https://github.com/itcmsgr/nftban/pull/833) (sq `e0ed237e`)

> **Why:** v1.177 proved the unprivileged `nftban-botscan.service` (`User=nftban`) cannot read panel access logs — fleet-validated **8/9 hosts DEGRADED**, two blocker shapes: DirectAdmin `/var/log/httpd/domains` `drwx--x--- apache:root` (parent traversal) and generic/Plesk `/var/log/{apache2,nginx}` `0640 root:adm` (file read). No single group/ACL covers both.

### Added — separate cap-scoped read-collector → spool (B1)
- **`cli/sbin/nftban-botscan-collector`** + **`nftban-botscan-collector.{service,timer}`** — runs `User=nftban` with **`AmbientCapabilities=CAP_DAC_READ_SEARCH` only** (read+traverse), on its OWN hardened unit (`ProtectSystem=strict`, `RestrictAddressFamilies=AF_UNIX`, `NoNewPrivileges=true`, `RestrictSUIDSGID=true`, `ReadWritePaths` limited to the spool + offset state). Reads **allowlisted** access-log roots: realpath-canonicalize → revalidate inside an allowlisted root → **reject symlink escape** → regular-files only → bounded max files/bytes → **per-read audit**. Writes an **`nftban:nftban 0640`** spool under `/run/nftban/botscan`.
- The scanner is now **spool-first** and reports **"OK (served via collector spool)"** when direct source readability is DEGRADED/UNKNOWN but the spool is feeding.

### Unchanged (security boundary preserved)
- **`nftban-botscan.service` scanner stays `User=nftban`, capless, `NoNewPrivileges=true`, `RestrictSUIDSGID=true`** — the capability lives only on the separate collector unit.

### Packaging / FHS / systemd (first-class)
- New spool + offset dirs (`/run/nftban/botscan`, `/var/lib/nftban/botscan-collector`) via `build/fhs-spec.yaml` → regenerated tmpfiles/`fhs_directories.json`/`nftban_fhs_spec.sh`; collector installed by DEB + RPM; systemd install list + `docs/systemd/UNITS.md` + restore-staging manifests updated.

### Validation
- **Package-family lab validation PASS:** lab2 (ubuntu24.04 **DEB**) + lab4 (almalinux9 **RPM**) — files/units/tmpfiles land; Shape B recovered on lab2, Shape A recovered on lab4 (real cPanel `domlogs` symlink-chain canonicalized) through the real packaged collector unit; no failed nftban units; SSH/firewall preserved.
- Hermetic tests `botscan_read_authority_v178_test.sh` **13/0**, CI-wired. CI #833 green (60 pass / 3 skip / 0 fail / 0 GHAS).

### Envelope
- **Daemon `cmd/nftband` SOURCE byte-identical to v1.177.0 (`48b82663`)** — local `-trimpath -buildvcs=false` reproduction identical; `cmd/nftband` has 0 `internal/installer` deps. **Packaged daemon binary hashes may differ because CI embeds VCS metadata (`buildvcs=auto`) — this is build-metadata, NOT a code change; packaged binary byte-identity is NOT claimed.** **Schema 1.83.0 frozen.**

### Not included (later lanes)
- Go LoginMon WordPress/web runtime authority (v1.178-B); FTP/cphulkd/exim-reject/HTTP-auth watchers; global Go health input-axis; v1.178-A fleet rollout; fleet-wide xmlrpc mitigation.

---

## [v1.177.0] - 2026-06-12 — BotScan panel access-log discovery + diagnostic/readability truth

**Codename:** `HTTP_LOG_DISCOVERY_AND_BOTSCAN_PANEL_PATHS` · **Records:** `NFTBAN_ROADMAP/V1_177_HTTP_LOG_DISCOVERY_AND_BOTSCAN_PANEL_PATHS_SCOPE.md`, `DETECTION_INPUT_AUTHORITY_AUDIT.md`, `SENIOR_ARCHITECT_ROADMAP_INPUT_AUTHORITY.md`
**PR:** [#831](https://github.com/itcmsgr/nftban/pull/831) (sq `e2453ddd`)

> **Why:** BotScan used a hardcoded single-file `[[ -f ]]` access-log lookup → "No access log found" on panel hosts (DirectAdmin/cPanel/Plesk), so web/xmlrpc attacks went undetected fleet-wide. This release fixes **discovery** and adds **honest diagnostics**; it does **not** grant read authority.

### Fixed — BotScan panel access-log discovery
- Panel-aware **multi-glob discovery** (DirectAdmin `/var/log/httpd/domains/*.log` + nginx domains, cPanel `/usr/local/apache/domlogs/*`, Plesk `/var/www/vhosts/system/*/logs/access_log`, generic Apache/nginx/LiteSpeed) replacing the single-file lookup, plus a **bounded incremental/offset reader** (rotation + copytruncate aware), **IPv4/IPv6**, and a `BOTSCAN_LOG_PATHS` override (`cli/lib/nftban/lib/nftban_http_logs.sh`).

### Added — diagnostic / readability truth (no enforcement change)
- `nftban botscan logs --detect` and `nftban botscan status` report a **five-state verdict — OK / DEGRADED / WARN_NO_LOGS / NO_LOGS / UNKNOWN** — evaluated **as the service account (`User=nftban`) via `runuser`, never the caller** (root-blindness guard). Unreadable and UNKNOWN states are surfaced instead of a bare "No access log found".

### Corrected — false coverage claims
- LoginMon/Roundcube/apache-auth runtime-coverage claims corrected to reflect what actually has a runtime watcher.

### Does NOT (explicit limitations)
- Does **not** grant BotScan read authority — `BOTSCAN_READ_AUTHORITY` remains **OPEN** (on DA/cPanel where panel logs are unreadable to `User=nftban`, BotScan reports DEGRADED but enforcement stays blocked until a later read-authority lane).
- Does **not** restore BotScan enforcement fleet-wide; does **not** mitigate xmlrpc on DA/cPanel.
- Go LoginMon WordPress/web runtime authority remains **deferred**; FTP/cphulkd/exim-reject/http-auth remain **separate input-authority lanes**.

### Envelope
- **Shell/data/test only — daemon `cmd/nftband` BYTE-IDENTICAL `48b82663…`** (no Go/systemd/packaging/ACL/Polkit change). **Schema 1.83.0 frozen.**
- **Validation:** `http_log_discovery_v177_test.sh` 30/0 (panel matrix, exclusion, dedup, bounded scan, incremental/rotation/copytruncate, IPv4/IPv6 parse, service-account readability T13–T19 incl. root-blindness guard), CI-wired; `bash -n` + shellcheck `-S warning` clean; GHAS Semgrep `ifs-tampering` cleared via command-scoped IFS (`6f9bf9f1`); CI #831 green (52 pass / 2 skip / 0 fail); post-merge main `e2453ddd`.

---

## [v1.176.0] - 2026-06-12 — daemon reliability (loginmon watcher respawn + fsync-residual state writes)

**Codename:** `DAEMON_RELIABILITY` · **Records:** `NFTBAN_ROADMAP/V1_176_DAEMON_RELIABILITY_SCOPE.md`, `V1_176_LAB_VALIDATION_RECORD.md`
**PR:** [#829](https://github.com/itcmsgr/nftban/pull/829) (sq `b3c8c82b`)

> **Why:** two daemon-graph reliability defects — a killed `tail -F` log-watcher child was never respawned (a detection source silently went dark until daemon restart), and two state writers did temp+rename without `fsync` (torn-on-crash).

### Fixed — LOGINMON-WATCHER-NO-RESPAWN (detection availability)
- The loginmon `tail -F` file-watcher is now **supervised**: if the child dies while the context is alive it **respawns with bounded exponential backoff** (1s→60s, reset after a 30s-healthy run). A killed watcher child no longer leaves that log source dark until daemon restart.
- **Shutdown via context cancel stays clean** — no respawn, no leaked `*exec.Cmd` (the watcher registry tracks only currently-live children).

### Fixed — FSYNC-RESIDUAL F-1/F-2 (crash-consistency)
- `internal/stats/set_counters.go` (set_counts.json) and `internal/rebuild/marker.go` (recovery marker) now write via `safety.SafeWriteFile` (temp + **fsync** + atomic rename), replacing `os.WriteFile(tmp)+os.Rename` with no Sync. Perms 0640 preserved.
- A new **CI guard** (`cli/lib/nftban/tests/fsync_residual_guard_v176_test.sh`) blocks any **new** unapproved hand-rolled temp+rename Go state writer outside `internal/safety`.
- The **13 pre-existing hand-rolled temp+rename writers are explicitly baselined as separate tech debt — NOT claimed fixed** by this release.

### Envelope
- **Daemon `cmd/nftband` hash MOVES (expected):** code-only `65ac698d…` → `48b82663…`, attributable to `internal/loginmon` + `internal/stats`; the rebuild change lands in `nftban-core`/`nftban-installer`. **Schema 1.83.0 frozen**; no FHS/packaging/schema change.
- **Lab-first PASS** lab2 (DEB/Plesk) + lab4 (RPM/cPanel): kill→respawn with unchanged daemon MainPID + no leak + clean shutdown; `set_counts.json` durable 0640 with no temp residue across restart; `validate`/`fhs` rc=0, no failed nftban units. CI #829 green (56 pass / 1 skip / 0 fail).

---

## [v1.175.0] - 2026-06-12 — FHS lane (auditors / sid-stats / alert-throttle FHS; firewall-validate accepted security exception)

**Codename:** `FHS_LANE` · **Records:** `NFTBAN_ROADMAP/V1_175_FHS_LANE_SCOPE.md`
**PR:** [#827](https://github.com/itcmsgr/nftban/pull/827) (sq `94069c08`; D-1 correction `2e910850`)

> **Why:** three FHS-authority defects in the generated tmpfiles / file layout, plus a lab-corrected design decision (D-1) on the one path that cannot be relocated.

### Fixed — BUG-TMPFILES-AUDITORS (unsafe path transition closed)
- `/var/lib/nftban/reports/auditors` moved `created_by tmpfiles → package` (RPM `%dir %attr(0770,root,nftban-auditor)`; DEB `nftban.dirs` + postinst converge to `root:nftban-auditor 0770`). Removed from the generated tmpfiles → systemd-tmpfiles no longer attempts the non-root-parent→root-child transition → **auditors exit-73 eliminated** on both families.

### Fixed — FHS-SMELL-SIDSTATS (mutable cache out of /etc)
- suricata sid-stats snapshot moved `/etc/nftban/suricata/cache/sid-stats.json` → `/var/lib/nftban/suricata/cache/sid-stats.json` (`cfg.DataDir`) + `migrateLegacySnapshot` (relocates an old `/etc` copy on first start). `internal/suricata/stats` is in no `cmd/` binary → **daemon byte-identical**.

### Fixed — ALERT-THROTTLE-FHS (throttle/diagnostics ownership)
- `nftban-alert@` throttle + diagnostics relocated under the nftban-owned `/var/lib/nftban/alerts` (`0750 nftban:nftban`, new tmpfiles entry) + `cli/sbin/nftban-service-alert` repointed → throttling now **persists** on `User=nftban` hosts (the root-cause fix deferred from v1.174 Item 3).

### Retained — BUG-TMPFILES-FIREWALL-VALIDATE (accepted non-fatal security exception — NOT closed)
- `/run/nftban/firewall-validate` (`2750 root:nftban`) **intentionally stays** in tmpfiles. The dir is root-owned because only the audited root service writes `last.json` (the nftban group reads it `0640`) — owning it `nftban:nftban` would let a compromised daemon forge the independent validation result. `/run` is tmpfs, so it must be tmpfiles-created at boot. The "drop tmpfiles, unit `+ExecStartPre` sole creator" alternative (D-1) was **rejected — lab-proven reboot-latent `226/NAMESPACE`** on systemd 252 + 255 (ReadWritePaths binds at mount-namespace setup, before ExecStartPre runs). Structurally guarded by `fhs_lane_v175_test` T1 (allowlists exactly this path; fails for any other root-under-non-root).

### Envelope
- **FHS-generator + shell + `internal/suricata/stats` (not in any `cmd/` binary) — daemon `cmd/nftband` BYTE-IDENTICAL** · schema **1.83.0 frozen**. CI green; lab2 (systemd 255) + lab4 (systemd 252) Option-I proof PASS.
- **NOT a full BUG-TMPFILES closure (audit truth):** the auditors unsafe transition is closed; firewall-validate's exit-73 is retained as an accepted non-fatal security exception, so `systemd-tmpfiles --create` may still exit 73 because of that one path.
- **Still open:** SUPPORT-DIAG-FAILED-UNIT-COVERAGE, UX-MSG-AUDIT, FSYNC-RESIDUAL, SEC / VX (v1.176), firewall-validate `RuntimeDirectory=` (deferred, security-reviewed).

---

## [v1.174.0] - 2026-06-12 — install/health reliability (stale failed-unit classification + health OOM + alert bookkeeping)

**Codename:** `INSTALL_HEALTH_RELIABILITY` · **Records:** `NFTBAN_ROADMAP/V1_174_INSTALL_HEALTH_RELIABILITY_SCOPE.md`, `V1_173_INSTALL_WARNINGS_CLASSIFICATION.md`
**PR:** [#825](https://github.com/itcmsgr/nftban/pull/825) (sq `cb7fb5b8`)

> **Why:** the installer's `failed_units_postinstall_ok` flagged DEGRADED on a **pre-existing** failed nftban unit (one that failed *before* the upgrade) — observed on dns2 (`nftban-health.service` OOM) and monitor (`nftban-alert@nftband.service.service`, a stale alert latch) — even though live health passed. It had no install-window timestamp comparison.

### Fixed — pre-existing failed-unit no longer falsely DEGRADES
- **Classification** (`internal/installer/validate`): a failed nftban unit is compared to an install-window start (recorded at installer startup). **Pre-existing** (failed strictly before the window) **+ clean live `nftban health`** → `WARN_PRE_EXISTING_RECOVERED` (non-fatal; `--repair` reaches COMMITTED). **In-window / unknown timestamp / unknown-or-unhealthy live health** → stays DEGRADED. A newly-failed unit is **never** classified as recovered (fail-safe). Covers templated `nftban-alert@*.service`.
- **Live-health parser** accepts the real four-axis vocabulary — `Overall: OK|IDLE|PROTECTED` + `Findings: none` / `none (N INFO hidden)` — so the downgrade fires on a normally-protecting host.
- **Bounded `reset-failed`** clears the stale systemd failed-state for ONLY the recovered units (exact names; never in-window/unknown/non-nftban; a reset-failed error is non-fatal).

### Fixed — health OOM
- `nftban-health.service` `MemoryMax` 128M → **256M** (validator + concurrent children RSS on hosts with large journals; the validator's journalctl read is already bounded).

### Fixed — alert unit no longer latches on bookkeeping
- `cli/sbin/nftban-service-alert`: the non-delivery bookkeeping writes (throttle, failure-metric, diagnostics) are **best-effort** — a permission error logs WARN and continues instead of failing the unit (it runs `User=nftban` and those paths were root-owned). **`send_email_alert` (delivery) keeps its rc contract.**

### Changed — update messaging
- `nftban update` summary now surfaces an **auto-recovered pre-existing unit** (transparency; this-run-scoped; quiet when none), and the DEGRADED block no longer says "often a known transient on the exporter" — it now states the failure may be current **or** a stale pre-existing latch and points to `nftban health` + `--repair`.

### Envelope
- **Installer-Go + shell — daemon `cmd/nftband` BYTE-IDENTICAL to v1.173.0** (daemon does not import `internal/installer/validate`) · schema **1.83.0 frozen** · FHS body unchanged. Lab-first PASS lab2 + lab4 (recovered-path fires on real PROTECTED hosts; in-window stays DEGRADED).
- **Explicitly NOT fixed here (open lanes):** ALERT-THROTTLE-FHS (relocate throttle to an nftban-owned dir so it persists — v1.175 FHS), SUPPORT-DIAG-FAILED-UNIT-COVERAGE (support-bundle gaps — diagnostics release), UX-MSG-AUDIT (broad scan for similar misleading messages).

---

## [v1.173.0] - 2026-06-11 — §4.1 session-whitelist cross-language flock + executor fsync

**Codename:** `SESSION_FLOCK` · **Controlling record:** `NFTBAN_ROADMAP/V173_SESSION_FLOCK_SCOPE.md`
**PR:** [#822](https://github.com/itcmsgr/nftban/pull/822) (sq `0a85527c`)

> **Why:** `/etc/nftban/whitelist.d/00-session.conf` was written by SIX read-modify-write writers across two languages with no shared lock, so a concurrent `nftban update` (Go) and `nftban firewall whitelist-session add/remove/cleanup` (shell) could lose an update (atomic rename prevents torn reads, not lost updates).

### Fixed — §4.1 cross-process / cross-language lost-update
- One shared advisory lock `/run/nftban/session_whitelist.lock`, taken for the FULL read→modify→write. Go `syscall.Flock(LOCK_EX)` (`internal/installer/safety/session_whitelist.go` Add/Cleanup/Remove) and shell `flock(1)` (`cli/lib/nftban/cli/cmd_firewall.sh` add/remove/cleanup) both use flock(2), so they genuinely interlock. Separate lock file (the data-file inode changes on atomic rename — `blacklistd.go` rationale).
- Durability: `RealExecutor.WriteFileAtomic` now `tmp.Sync()` before rename (pure-win for all installer atomic writes; directory fsync intentionally omitted per the F-3 decision note). FakeExecutor unchanged.

### Envelope
- **Installer-Go + shell only. Daemon `cmd/nftband` BYTE-IDENTICAL to v1.172.0** (reader-only; does not import `internal/installer/{executor,safety}` — verified SHA256 unchanged, 0 `cmd/nftband` files). Schema **1.83.0 frozen**; FHS body byte-unchanged (volatile on-demand `/run` lock); no dependency change.

### Tests
- `internal/installer/safety/session_whitelist_flock_v173_test.go` (24 concurrent adds → no lost update; cross-language: Go holds LOCK_EX → shell `flock -n` fails, then succeeds — passes under `-race`) + `cli/lib/nftban/tests/session_whitelist_flock_v173_test.sh` (lock-structure + flock(1) mechanism); CI-wired. Lab-first PASS (lab2 DEB + lab4 RPM) before tag.

---

## [v1.172.0] - 2026-06-11 — CLI-PIPEFAIL-ARITH full-class sweep

**Codename:** `CLI_PIPEFAIL_SWEEP` · **Controlling record:** `NFTBAN_ROADMAP/V172_CLI_PIPEFAIL_SWEEP_SCOPE.md`
**PR:** [#820](https://github.com/itcmsgr/nftban/pull/820) (sq `26a53867`)

> **Why:** under `set -Eeuo pipefail` a `producer | <emit-on-empty> … || <fallback>` inside `$()` double-emits when an early pipe stage fails (zero-match `grep` rc=1, head-closes-pipe SIGPIPE rc=141, or a `jq` parse error) while a later stage already printed a default → `"0\n0"`; the consumer's `[[ $X -eq/-gt ]]` / `jq tonumber` then crashes. Already closed for `stats ip` in v1.170 — this applies the proven idioms to every remaining sibling. Merges the former v1.172 (HIGH) + v1.173 (MED/LOW) into one **shell-only** release.

### Fixed — pipefail-arith crash class (16 sites)
- **HIGH:** `core/nftban_report_email.sh` blacklist/whitelist empty-set counts (aborted the daily report on a fresh install); `cli/cmd_watchdog.sh` history count on the daemon-just-started path (`.data.history // []` + sanitize).
- **MED:** `lib/nftban_report_data.sh` unique-IP count; `cli/cmd_ddos.sh` blocked_24h/total + packets/bytes; `cli/cmd_stats.sh` repeat-offenders / ip-history total / total_countries; `cli/cmd_cleanup.sh` ip_count; `cli/cmd_login.sh` + `cli/cmd_update.sh` digest/history counts (`jq -s 'add // [] | length'` for single + appended arrays).
- **MED (siblings found via full-class scan, beyond the original audit list):** `core/nftban_login_alert.sh` digest count; `core/nftban_health_checks_services.sh` fd_count; `lib/service_control.sh` timers_active (directly `[[ -eq 0 ]]`-consumed).
- **LOW:** `cli/cmd_wizard.sh` re-`readonly` guard (no "readonly variable" stderr on re-source); `core/nftban_stats_format.sh` removed a dead, buggy `grep -c | grep -cE` pair (+ its now-unused locals).

Dropped `|| echo X` fallbacks were replaced with `|| true` (rc-safe under `set -e`, no second emit) — empirically confirmed bare assignments abort (exit 5) otherwise.

### Tests
- `cli/lib/nftban/tests/cli_pipefail_arith_sweep_v172_test.sh` (20/0): behavioral single-emit + static lint that the broken forms are gone; CI-wired in `ci-architecture.yml`.

### Envelope
- **Shell-only — `0 cmd/nftband` + `internal` (daemon byte-identical to v1.171.0)** · schema **1.83.0 frozen** · FHS body byte-unchanged · no packaging/dependency change · hermetic (no lab gate). `bash -n` 13/13, shellcheck `-S warning` 0 new; CI #820 green; post-merge main `26a53867` green (non-blocking Dependabot bot aside).

---

## [v1.171.0] - 2026-06-11 — daemon state-write atomicity (§4.2–§4.3) + §3.6 ssh_ports counter

**Codename:** `STATE_WRITE_ATOMICITY` · **Controlling records:** `NFTBAN_ROADMAP/V171_STATE_WRITE_ATOMICITY_SCOPE.md` · `NFTBAN_ROADMAP/V171_LAB_VALIDATION_RECORD.md`
**PR:** [#818](https://github.com/itcmsgr/nftban/pull/818) (sq `d05509b3`)

> **Why:** several daemon state files were written with a plain `os.WriteFile`/`os.Create` (torn-on-crash / torn-on-concurrent-read), and the startup set-counter reconcile omitted `ssh_ports`. **Daemon-Go lane** — the daemon `cmd/nftband` hash **moves intentionally** (the v1.147→v1.167 byte-identical chain already ended at v1.168). **Schema 1.83.0 frozen** — only the write *mechanism* changes; on-disk payloads are byte-identical. **Does NOT close §4.1** (cross-process flock on `00-session.conf`) — that remains a separate future lane.

### Fixed — atomic state writes (§4.2/§4.3)
- Routed the offending writers through the in-tree gold helper `safety.SafeWriteFile` (temp → `Sync` → rename, random temp): **§4.2** suricata sid-stats snapshot (`internal/suricata/stats/cache.go`); **§4.3a–c** `internal/safety/limits.go` ProtectionState/FilterState/PermanentBans; **§4.3d** `internal/ports/panel_loader.go` (streamed `os.Create` → buffer + `SafeWriteFile`, byte-identical content). A crash mid-write or a concurrent read can no longer observe a truncated/torn file.

### Fixed — §3.6 ssh_ports startup counter
- `cmd/nftband/daemon_init.go` reconcile `setNames` now includes `ssh_ports`, so its in-memory counter is seeded from the kernel on startup (was silently omitted; count-only, set was always enforced).

### Tests
- `internal/safety/atomic_write_v171_test.go` (concurrent-read atomicity + no stray temp on success) + `cli/lib/nftban/tests/state_write_atomicity_v171_test.sh` (8/0 call-site lock), CI-wired in `ci-architecture.yml`.

### Envelope
- **Daemon-Go — daemon `cmd/nftband` NOT byte-identical** (hash moves by design). Schema **1.83.0 frozen** (payloads unchanged). Installer/runtime behavior otherwise unchanged.

### Validation
- Local: `go build/test/vet ./...` + staticcheck + gofmt + shellcheck green.
- **Lab-first (mandatory for daemon-Go) PASS 3/3** — lab2 (DEB), lab4 (RPM/EL9), monitor (real host): daemon SHA256 moved to the single v1.171 build then restored to each baseline; `ssh_ports` counter seeded (`Reconciled ssh_ports: count=1`); state JSON valid across a restart-survival cycle, no torn-JSON; SSH preserved. dns1/dns2/srv1 held for the post-release fleet gate. Record `NFTBAN_ROADMAP/V171_LAB_VALIDATION_RECORD.md`.
- PR #818 CI green; post-merge main `d05509b3` green (non-blocking Dependabot bot aside).

## [v1.170.0] - 2026-06-10 — stats ip history: pipefail fix + rotated/compressed logs

**Codename:** `STATS_IP_HISTORY_FIX` · **Controlling record:** `NFTBAN_ROADMAP/V170_STATS_IP_HISTORY_FIX_SCOPE.md`
**PR:** [#816](https://github.com/itcmsgr/nftban/pull/816) (sq `5e6ddc94`)

> **Why:** `nftban stats ip <IP>` crashed with a bash arithmetic error and garbled output for any IP with **zero** ban records (the common case). **Shell-only** — daemon `cmd/nftband` byte-identical; schema **1.83.0 frozen**; no packaging-dependency change (gzip already declared — CI assertion only).

### Fixed — BUG-STATS-IP-HISTORY-PIPEFAIL
- `nftban_stats_ip_history()` (`core/nftban_stats_collect.sh`) was `grep | awk '…[]…' || echo "[]"`. Under `set -Eeuo pipefail`, a zero-match grep made the pipeline exit non-zero → the `|| echo "[]"` fired **in addition** to awk's `[]` → `"[]\n[]"` → caller `jq '. | length'` → `"0\n0"` → `cmd_stats.sh:924 [[ $total -eq 0 ]]` arithmetic crash. Now **single-emit** (capture matcher into a var; awk emits a valid `[]` on empty input). `cmd_stats.sh` also defensively sanitizes the jq total to one integer.

### Changed — complete history across rotated/compressed logs
- The reader greps the live `bans.log` **and** its rotated archives (`bans.log.1`, `bans.log.*.gz`) via `zgrep` (sorted by timestamp), so per-IP history is no longer silently truncated to the current uncompressed window (logrotate keeps `rotate 12` compressed). **Graceful-degrade:** if `zgrep`/`gzip` is absent (source/minimal installs), falls back to the live log + a WARN — never hard-errors. `gzip` is already a declared dependency (DEB `Depends` + RPM `Requires`); CI now asserts it stays declared.

### Tests
- New guard `stats_ip_history_v170_test.sh` (7/0), CI-wired in `ci-architecture.yml`: zero-match→single `[]` (no arith crash) · live-log IP · compressed-only `.gz` IP · merged+sorted live+gz · caller total sanitized · gzip dep declared.

### Envelope
- **Shell-only — daemon `cmd/nftband` byte-identical**; schema **1.83.0 frozen**; no dependency mutation.

## [v1.169.0] - 2026-06-09 — hygiene/UX residuals (CLI-BUG-3 · CI-TEST-GAP · docs)

**Codename:** `V169_HYGIENE_UX` · **Controlling record:** `NFTBAN_ROADMAP/V169_HYGIENE_UX_SCOPE.md`
**PR:** [#814](https://github.com/itcmsgr/nftban/pull/814) (sq `5a8f05b8`)

> **Why:** a low-risk hygiene/UX bundle following the daemon-Go v1.168. **Shell + CI-workflow + docs only** — daemon `cmd/nftband` byte-identical to v1.168.0; schema **1.83.0 frozen**; no FHS body/generator or packaging-authority change.

### Fixed — `whitelist list` labels timed/session entries (CLI-BUG-3)
- Since v1.168 a timed kernel element renders as `1.2.3.4 timeout 30m expires 29m55s`; the list printed that raw text appended to the IP, unlabeled. `cmd_whitelist.sh` now formats each element via `nftban_whitelist_fmt_element` (**TIMED (expires in …)** vs **DURABLE**) and emits a bare IP in `--json` via `nftban_whitelist_bare_ip` (keeps JSON values valid). Read-only display; no nft writes. Guard `whitelist_list_timed_label_v169_test.sh`.

### Changed — CI-TEST-GAP: wire previously-unwired guards
- Wired 6 substantive guards that shipped with v1.158–v1.163 but were never in any workflow (`mac_posture_v158`, `geoban_refresh_execcondition_v159`, `firewall_pkg_wording_v160`, `permissions_optional_module_skip_v160`, `whitelist_verify_v163`, `immutable_health_verify_v163`) plus the new v169 CLI-BUG-3 guard into `ci-architecture.yml`.

### Changed — docs/hygiene (REPO-DOC-HYGIENE)
- README: `Tier 1 — Future Platforms` → `Tier 1 — Newer Platforms` + a clarifier that all tiers are built/released/CI-tested every release (tiers reflect recommendation/age, not support level; verified against artifacts).
- Removed the stale `# NFTBan v1.0.0` banner from `packaging/systemd/nftban-firewall-init.service` (comment-only; the `install/systemd/` copy was already clean since #552).

### Envelope
- **Daemon `cmd/nftband` byte-identical to v1.168.0** (0 Go/internal change) · schema **1.83.0 frozen** · FHS body byte-unchanged (release-prep header-only; `generate-fhs-outputs.sh --check` rc=0).

### Validation
- Local: `bash -n` + shellcheck `-S warning` (0 new) on touched shell; new test + all 6 wired guards pass; `ci-architecture.yml` YAML valid. PR #814 CI green; post-merge main `5a8f05b8` green (non-blocking Dependabot bot run + a superseded namespace-guard leg aside; neither is a required check). **Not shipped here:** DDoS wiki drift (separate `nftban.wiki` repo).

---

## [v1.168.0] - 2026-06-09 — CLI-BUG-2: whitelist TTLs expire in-kernel

**Codename:** `V168_CLI_BUG_2_WHITELIST_TTL`
**Controlling records:** `NFTBAN_ROADMAP/CLI_BUG_2_WHITELIST_TIMEOUT_SCOPE.md` · `NFTBAN_ROADMAP/V168_CLI_BUG_2_VALIDATION_RECORD.md`
**PR:** [#812](https://github.com/itcmsgr/nftban/pull/812) (sq `dd794d1a`)

> **Why:** `nftban firewall whitelist-session add <ip> --ttl <dur>` (and `whitelist add --ttl`) reported an expiry, but the entry never expired in the kernel. The daemon's `FullSync` repopulated the whitelist sets from an IP-only snapshot (`EXPIRES_AT` was load-time skip-only), so any kernel timeout was dropped on the next sync/rebuild and a "temporary" whitelist became permanent — exempt from all protection indefinitely. This is the first daemon-Go change since v1.147: the daemon `cmd/nftband` byte-identical chain (v1.147→v1.167; tree `85a2de3e…`) **ends intentionally here**. Schema **1.83.0 frozen** — no schema change.

### Fixed — whitelist TTLs expire in-kernel and survive sync (CLI-BUG-2)
- **Loader** (`internal/whitelist/loader.go`): `WhitelistEntry` now carries the absolute `ExpiresAt` from the inline `EXPIRES_AT` marker (`parseExpiresAt`) instead of only skipping expired lines. Past/malformed markers are still dropped; entries with no marker stay permanent. `shouldSkipDueToExpiresAt` retained as a compatible wrapper.
- **Runtime state** (`internal/runtime/state.go`): `LoadWhitelists` populates `IPEntry.ExpireAt`; new `GetWhitelistSnapshotWithExpiry()` exposes `ip → absolute expiry` for timed entries only (permanent entries are absent from the map).
- **Sync** (`internal/setsync/diff.go`): new pure `remainingTimeout()` + timeout-aware `SyncWhitelistSetToNFT`; `FullSync` gains a `whitelistExpiry` argument and applies `AddIPWithTimeout(remaining)` to timed entries. The timeout is anchored to the **absolute** expiry and recomputed every sync, so a re-sync/rebuild **refreshes** the remaining TTL rather than clobbering it to permanent. Blacklist sync unchanged.
- **Daemon** (`cmd/nftband/daemon_handlers_sync.go`): passes the expiry snapshot into `FullSync`.

### Changed — whitelist sets are timeout-capable (render prerequisite)
- `whitelist_ipv4`/`whitelist_ipv6` now declare `flags interval, timeout` in both the static boot-baseline `install/nftables/nftables.conf` and the rebuild template `install/nftables/nftables.conf.tpl` (the blacklist sets already had it). Without the `timeout` flag the kernel set cannot hold a per-element timeout.

### Changed — upgrade activation (normal rebuild; backstop is defense-in-depth)
- On upgrade the installer's existing `switchop.Rebuild` runs `nftban firewall rebuild`, which re-renders the v1.168 template and recreates the whitelist sets with `flags interval, timeout`. Validation confirmed this **normal upgrade rebuild activates the flag** on lab2 (DEB), lab4 (RPM/EL9) and monitor (real host) **without any manual rebuild**.
- A conditional, SSH-guarded **backstop** was added to the DEB postinst + RPM `%post` (modeled on the v1.145 PR-A.1 migration): if a live whitelist set still shows bare `flags interval` (installer rebuild skipped/DEGRADED), it recreates the set via an explicit `nftban firewall rebuild`; idempotent, non-fatal. The backstop is **defense-in-depth and was dormant during validation** — it did not fire on any host.

### Tests
- `internal/setsync` `TestRemainingTimeout_TTLSurvivesFullSync` (primary acceptance: TTL survives FullSync, anchored/refreshed, never clobbered) + loader `ExpiresAt`-carry + runtime expiry-snapshot tests.
- Shell guards CI-wired in `ci-architecture.yml`: `whitelist_set_timeout_flag_v168_test.sh` (the 4 whitelist decls carry `timeout`) + `whitelist_timeout_upgrade_activation_v168_test.sh` (deb+rpm backstop). Schema-freeze guard green (1.83.0).

### Envelope
- **Daemon `cmd/nftband` changes** — the v1.147→v1.167 byte-identical chain (`85a2de3e…`) ends here by design.
- Schema **1.83.0 frozen**. FHS body byte-unchanged (release-prep header-only; `generate-fhs-outputs.sh --check` rc=0).

### Validation
- Local: `go build/test ./...`, `go vet`, `staticcheck`, `gofmt`, schema-freeze, shell guards, shellcheck — all green.
- Kernel-level (binary-swap **and** real package upgrade) on lab2 (DEB), lab4 (RPM/EL9), monitor (real host, v1.159→v1.168 jump): a timed `--ttl` entry kept a shrinking kernel timeout across an extra FullSync; durable/trust entries stayed permanent; SSH preserved; all hosts restored to baseline. dns1/dns2 untouched. Record: `NFTBAN_ROADMAP/V168_CLI_BUG_2_VALIDATION_RECORD.md`.
- PR #812 CI green; post-merge main `dd794d1a` green (sole failure = the non-blocking Dependabot Updates bot run, not in `required_status_checks`).

---

## [v1.167.0] - 2026-06-08 — UX residual (CLI output-truth + hygiene)

**Codename:** `V167_UX_RESIDUAL`
**Controlling record:** `NFTBAN_ROADMAP/V167_UX_RESIDUAL_SCOPE.md`
**PRs:** [#806](https://github.com/itcmsgr/nftban/pull/806) (PR-1, sq `c7bd820d`) · [#807](https://github.com/itcmsgr/nftban/pull/807) (PR-2, sq `251b29a0`) · [#808](https://github.com/itcmsgr/nftban/pull/808) (PR-3, sq `0c3f157f`)

> **Why:** close the open UX-residual debts. A v1.166 code-challenge found over half the original list (UX-C2/C3/C4/C6, RC-CONTRACT, several §10/§13/§15 items) was already fixed in v1.141–v1.153 and verified-closed; this lane ships the genuinely-open remainder. **Shell/CLI only** — daemon `cmd/nftband` byte-identical (chain v1.147→v1.167; tree `85a2de3e…`); schema 1.83.0 frozen; FHS body byte-unchanged; no `internal/validator` Go touched.

### Fixed — feed-counter drift (BUG-CtCount-feeds) [PR-1]
- New shared helpers `cli/lib/nftban/lib/nftban_feed_counters.sh`: `nftban_feed_ips_total()` (enabled-feed IP sum) + `nftban_feed_file_count()` (enabled-feed file count). The three previously-independent total computations — `cmd_status.sh` (was `find … *.txt | wc -l` over **all** files incl. disabled/orphans), `core/nftban_stats_collect.sh` (cat-all), `cmd_feeds.sh` aggregates — now route through the helpers, ending the drift. The v1.141 labelled surfaces ("Feed file count" / "Feed IP total") are preserved; per-single-feed displays untouched. Test `feed_counters_unify_v167_test.sh` 4/0.

### Changed — CLI output-truth + flag-parity [PR-2]
- **JSON safety:** the no-jq fallback paths in `cmd_botscan.sh` (`action_mode`) and `cmd_debug.sh` (`trace_log`/`log_level`) now escape via the existing `helpers/json_output.sh json_escape()` — no more invalid JSON on quotes/backslash/newline. jq-primary paths unchanged.
- **`nftban update --dry-run`** now emits an explicit hint (`ERROR: --dry-run is not supported for 'nftban update'` / use `nftban update check`, rc=1) instead of the generic "Unknown command".
- **`nftban-validate` INFO filtering** is now **shell-side** in `cmd_firewall.sh firewall_validate()` — INFO-severity findings are dropped by default (matching `nftban health`), with `--verbose` / `NFTBAN_VALIDATE_VERBOSE=1` to show them. `--json` output is unaffected and **no `internal/validator` Go was modified** (UX-INFO stays a shell post-filter in this lane).
- **Stats label-casing** aligned (`unified cache` → `UNIFIED CACHE`). The lone `DERIVED` token is a logic-backed cache-miss data-source label (pinned by `v127_ux3` test), not spec residue → retained. Test `cli_output_truth_v167_test.sh` 16/0.

### Removed — orphan shell modules [PR-3]
- Deleted 10 confirmed-orphan modules (zero inbound real references; staged by RPM `cp -r` but never sourced → dead bytes): `lib/{colors,nft_lock,exporter_utils,nftban_metrics_modes,nftban_vm_enterprise}.sh`, `exporters/nftban_metrics_wrapper.sh`, `core/{nftban_config_safe,nftban_report_engine,nftban_secure_mode,path_validator}.sh`. Anti-orphan guard `no_reintroduced_orphan_modules_v167_test.sh` 11/0. No packaging-spec/FHS edit needed (the recursive `cp -r` drops them).

### Not shipped (separate lanes)
- **WIKI_ALIGN_V166** — wiki is its own repo; plain-text alignment (4 drift files: stale version, Webmin ×2, a Redis example), **no release number**, done separately.
- v1.168 state-write atomicity §4.1–4.3 (daemon-Go) · daemon-Go · schema · FHS/packaging · BUG-Explain / `nftban why`.

### Notes
- **Envelope:** shell/CLI only — `0 cmd/nftband` (daemon byte-identical, tree `85a2de3e…`) · `0` schema (1.83.0 frozen) · `0` FHS body/generator · no packaging/switchop/runtime/firewall change. Three file-disjoint PRs.
- **Validation:** the 3 v167 tests + 5 existing UX regression guards green; shellcheck + `bash -n` clean; `check-nft-writes` PASS; `generate-fhs-outputs.sh --check` rc=0. CI #806/#807/#808 green (one Docker-Hub `ubuntu:24.04` pull-timeout infra flake rerun-cleared); post-merge main `0c3f157f` green (25 success / 1 skip / 0 fail). The release-prep commit changes only `VERSION`/`STATUS.md`/`CHANGELOG.md`/`nftban_fhs_spec.sh` header — the FHS body (incl. the v1.166 `email`/`partials` ownership) is byte-unchanged.

## [v1.166.0] - 2026-06-08 — RPM templates %files dedup via FHS-generator correction

**Codename:** `V166_RPM_TEMPLATES_FHS_DEDUP`
**Controlling record:** `NFTBAN_ROADMAP/V166_RPM_TEMPLATES_FHS_DEDUP_SCOPE.md`
**PR:** [#804](https://github.com/itcmsgr/nftban/pull/804) (sq `29dd622b`)

> **Why:** complete the RPM `%files` cleanup — the templates half of `BUG-RPM-FILES-LISTED-TWICE` (lib-dir half shipped in v1.165 PR-B). This is a deliberate **FHS-authority edit**: the bare `/usr/share/nftban/templates` line both double-listed the generator `%dir`-owned dirs *and* solely owned the `email/`+`partials/` staged `.html` (which had no inc `%dir`), so it could not be dropped without orphaning them (the v1.161 trap). Build-time only; daemon `cmd/nftband` byte-identical (chain v1.147→v1.166; tree `85a2de3e…`); schema 1.83.0 frozen.

### Changed — templates `%files` dedup + FHS-generator ownership
- **`build/fhs-spec.yaml`** now `%dir`-owns `/usr/share/nftban/templates/email` + `/usr/share/nftban/templates/partials`; `templates/zabbix` kept as an **empty owned `%dir`** for compatibility. All FHS outputs regenerated (`nftban-files.inc`, `nftban_fhs_spec.sh`, `fhs_directories.json`, `deb/nftban.dirs`).
- **`packaging/build_nftban.sh` `%files`:** the bare `/usr/share/nftban/templates` line is replaced with explicit subdir contents — `mail/*`, `reports/*`, `email/*`, `partials/*` — so `%include nftban-files.inc` keeps sole `%dir` ownership (removes the remaining "File listed twice" warning). `zabbix` gets no `/*` line (no content). A `%install` templates dotfile strip (`find %{buildroot}/usr/share/nftban/templates -name '.*' -type f -delete`) keeps the `<dir>/*` glob complete.
- New hermetic guard `cli/lib/nftban/tests/rpm_files_templates_dedup_v166_test.sh`, CI-wired (the PR-A comment-macro guard stays the first tripwire).

### Closed
- **`BUG-RPM-FILES-LISTED-TWICE` — fully closed in code:** lib-dir half (v1.165 PR-B) + templates half (this lane PR-C).

### Not shipped (separate lanes)
- v1.167 = UX residual (mostly shell) · v1.168 = state-write atomicity §4.1–4.3 (daemon-Go, breaks zero-Go) · schema unfreeze · daemon-Go · runtime/firewall behavior.

### Notes
- **Envelope:** FHS-generator + regenerated outputs + packaging-build-script + test + CI — `0 cmd/nftband` (daemon byte-identical, tree `85a2de3e…`) · `0` schema (1.83.0 frozen) · no CSF. The shipped DEB/RPM packages change intentionally (deduped templates `%files`).
- **FHS body DELIBERATELY CHANGED** (this is an FHS-authority lane, not a body-frozen one): `nftban-files.inc` → `08e0163f3baefee0e6d43c9e709e4b98098a1f258eb714d6c8ff7da991cb1ccd`; `nftban_fhs_spec.sh` body → `3a389e9a94fa9c96b25f2aa51bbd32a99c098115c3a48b24a7cd5979488bc411`. **The release-prep commit changes only the FHS header/`meta:version` on top of this PR-C body — it does not touch the FHS body.**
- **Validation:** v166 guard 13/0 · PR-A 5/0 · PR-B 15/0 · v157 6/0 (hermetic). `generate-fhs-outputs.sh --check` rc=0 (generator parity). A hermetic mini-rpmbuild (templates `%dir` + `/*` + strip + staged `email`/`partials` + planted `.gitkeep`) proved no "File listed twice" and no unpackaged `.gitkeep` — rpm-version-independent, so it holds for EL9/EL10. CI #804: FHS generated-files check ✅, Build RPM el9/el10 ✅, full DEB matrix ✅, Policy Gates / Semgrep / ShellCheck ✅. Post-merge main `29dd622b` green.

## [v1.165.0] - 2026-06-08 — RPM packaging correctness + hidden spec-parser hardening

**Codename:** `V165_RPM_FILES_DEDUP_LINT_FIRST`
**Controlling record:** `NFTBAN_ROADMAP/V165_RPM_FILES_DEDUP_LINT_FIRST_SCOPE.md`
**PRs:** [#801](https://github.com/itcmsgr/nftban/pull/801) (PR-A, sq `888dc67c`) · [#802](https://github.com/itcmsgr/nftban/pull/802) (PR-B, sq `848ac6b1`)

> **Why:** two build-time-only RPM packaging fixes — a hidden rpm-4.16 spec-comment parser hazard and the long-standing `/usr/lib/nftban` "File listed twice" warning. No runtime, no firewall, no daemon, no schema change. Daemon `cmd/nftband` byte-identical (chain v1.147→v1.165; tree `85a2de3e…`); schema 1.83.0 frozen; FHS body byte-unchanged (no FHS-generator change).

### Added — generated-spec comment-macro guard (PR-A)
- New hermetic CI guard `cli/lib/nftban/tests/rpm_spec_no_section_macro_in_comment_v165_test.sh`, wired into Policy Gates **before** any rpmbuild. rpm **4.16** (EL9/EL10) parses a bare unescaped `%install` token inside a generated-spec **comment** as a *second* `%install` section (`error: second %install`) and fails Build RPM el9/el10 deterministically; rpm 4.18 (lab2) / 6.x are lenient and miss it — so this bit twice (v1.157 `FIX_V157_PR_A`, v1.164 PR-C revert). The guard asserts exactly one `%install` section header, no stray `%install` token, and no bare RPM section macro in any spec comment, with a live self-test. Ground-truth verified on **srv2 (rpm 4.16.1.3)**: only `%install` is fatal-in-comment, but the full section-macro family is forbidden defensively. Seven existing benign comments reworded to drop literal `%post`/`%files` tokens. (`packaging/build_nftban.sh`, `.github/workflows/ci-architecture.yml`)

### Changed — lib-dir RPM `%files` dedup (PR-B)
- The 12 generator-owned `/usr/lib/nftban` payload dirs (`bin sbin cli core lib cron helpers setup exporters tests data health`) are listed as `<dir>/*` instead of bare paths, so `%include nftban-files.inc` keeps **sole** `%dir` ownership — removing the benign `warning: File listed twice` on strict rpm 4.16. (`packaging/build_nftban.sh`)
- A `%install` dotfile strip — `find %{buildroot}/usr/lib/nftban -name '.*' -type f -delete` — prevents the rpm `<dir>/*` glob (which skips dotfiles) from orphaning `tests/.gitkeep` (the exact v1.161 `/*` "Installed (but unpackaged)" failure). `VERSION`, `BUILD_TARGET`, `*.sh`, `%doc README.md` stay explicit.
- New hermetic guard `cli/lib/nftban/tests/rpm_files_no_double_dir_listing_v165_test.sh` (dedup shape + strip + no bare-line∩inc-`%dir`), CI-wired.

### Not shipped (separate lanes)
- **PR-C templates/FHS correction** — the `templates/email` + `templates/partials` subdirs have staged content but no inc `%dir`, so deduping the bare `/usr/share/nftban/templates` line requires an FHS-generator change that **changes the FHS body** (different validation profile, abortable). Deferred to **v1.166** (`OPEN_RPM_FILES_DEDUP_PR_C_SCOPE`).
- schema changes · daemon-Go · runtime/firewall behavior.

### Notes
- **Envelope:** packaging-build-script + tests + CI only — `0 cmd/nftband` (daemon byte-identical, tree `85a2de3e…`) · `0` schema (1.83.0 frozen) · no CSF · no FHS-generator change · FHS body byte-unchanged. The shipped DEB/RPM packages change intentionally (cleaner `%files`).
- **Validation:** PR-A guard 5/0 · PR-B guard 15/0 · v157 guard 6/0 (all hermetic). A **hermetic mini-rpmbuild** (mirroring inc `%dir` + `/*` + the strip, with a planted `tests/.gitkeep`) proved no "File listed twice" and no unpackaged `.gitkeep` — a rpm-version-independent check, so it holds for EL9/EL10. CI #801 + #802: Build RPM el9/el10 ✅, Policy Gates / Semgrep / ShellCheck ✅. Both post-merge mains green (Docker-Hub `registry-1.docker.io` pull-timeout infra flakes on el10/DEB26/Buildx were rerun-cleared; el9 — the strict rpm-4.16 `%files` judge — passed throughout).

## [v1.164.0] - 2026-06-08 — switchop classify-content safety

**Codename:** `V164_SWITCHOP_CLASSIFY_EMPTY`
**Controlling record:** `NFTBAN_ROADMAP/V164_SWITCHOP_CLASSIFY_EMPTY_SCOPE.md`
**PR:** [#799](https://github.com/itcmsgr/nftban/pull/799) (sq `42183f78`)

> **Why:** close the v1.161 reopened installer-correctness debts — §2.2 raw-ghost cleanup and refuse-on-populated `inet filter` enforcement. The `internal/installer/switchop` cleanup deleted known table names on sight; it now **classifies table content before deleting**. Installer-Go only; daemon `cmd/nftband` byte-identical (chain v1.147→v1.164; tree `85a2de3e…`); schema 1.83.0 frozen; no packaging/`build_nftban.sh` change; FHS body byte-unchanged.

### Changed — switchop ghost-table cleanup now classifies content (§2.2 + refuse-on-populated)
- New shared **`TableIsEmpty(exec, family, table)`** helper (`internal/installer/switchop/classify.go`) — generalizes the `detect/cve_inet_filter` rule-count classifier; returns true only when a `nft list table` shows zero rules (conservative false on not-exist/error).
- **`CleanGhostTables`** (`internal/installer/switchop/ghost.go`) reworked into three classes:
  - **Class 1 — unconditional compat-shim skeletons** (`ip/ip6 filter`, `nat`, `mangle`, `security`, `inet firewalld`): deleted on sight, unchanged.
  - **Class 2 — `ip raw` / `ip6 raw`, classify-empty:** an **empty** raw table is an iptables-nft skeleton → **removed**; a **populated** raw table (operator/kernel NOTRACK / conntrack-exemption rules) → **preserved + WARN**, never deleted on sight.
  - **Class 3 — `inet filter`, classify-empty + override:** an **empty/default** skeleton → **removed** (CVE-2025-NFTBAN-001 guard — it would shadow nftban blocking); a **populated operator-owned** table → **preserved + WARN/refuse**, unless `NFTBAN_ALLOW_REMOVE_INET_FILTER=1` authorises a deliberate, logged **high-risk** removal. This aligns the Go cleanup path with the DEB/RPM scriptlets and the detect-phase verdict, so cleanup can no longer destroy what detect preserved.

### Changed — PR26.6 invariant refined (intentional, not a regression)
- `TestPR26_6_GhostCleanup_DoesNotDeleteOperatorTable` now asserts **empty `ip raw` → removed** (an empty raw table is an iptables-nft skeleton, not a kernel default in pure nftables, where tables are created on demand) while **populated raw** and the operator/nftban/ssh_safety tables stay **preserved**. (`internal/installer/switchop/takeover_pr26_6_test.go`)

### Not shipped — reverted/descoped (remain open in the register)
- **RPM `%files` double-listing cleanup (PR-C) — REVERTED.** It failed strict rpm 4.16 EL9/EL10 a **second** time, this round on a bare `%install` token inside a generated-spec comment (`error: line 1295: second %install`, the v1.157 packaging-comment class) — before the `%files` dedup was even evaluated. PR-C was reverted; v1.164 ships the switchop classify-content work only. RPM %files dedup is now a **dedicated micro-lane** whose next attempt **must** add a strict **generated-spec lint forbidding bare RPM section macros (`%install`/`%files`/…) in spec comments before `rpmbuild`** (lab rpm 4.18 is lenient and cannot pre-catch this; the strict gate is CI `Build RPM (el9)`/(el10) only).
- daemon-Go lanes (§3.6 ssh_ports counter + v1.150 Lane-C) · SEC-AUDITLOG · SEC-DAEMON-PRIV · schema unfreeze · CSF restore.

### Notes
- **Envelope:** installer-Go (switchop) + tests only — `0 cmd/nftband` (daemon byte-identical, tree `85a2de3e…`) · `0 cmd/nftban-core` · `0` schema (1.83.0 frozen) · no CSF · **no packaging/`build_nftban.sh` change** · **no FHS-body change**. The installer binary (`cmd/nftban-installer`/`internal/installer/switchop`) changes intentionally.
- **Validation:** lab2 `go build` + `go test ./internal/installer/switchop/...` green (hermetic `MockExecutor.RunResults` empty-vs-populated cases + flipped PR26.6 invariant), gofmt clean, `cmd/nftband` tree `85a2de3e…` unchanged. CI #799 — Build RPM el9/el10 ✅ (after the PR-C revert), `Build & Test` ✅, Semgrep/ShellCheck/Policy Gates ✅. Post-merge main `42183f78` green (70/0 check-runs, full DEB+RPM matrix ✅, daemon tree unchanged).

## [v1.163.0] - 2026-06-08 — whitelist verify + immutable health checks

**Codename:** `V163_SEC_WL_VERIFY_IMMUT`
**Controlling record:** `NFTBAN_ROADMAP/V163_SEC_WL_VERIFY_IMMUT_SCOPE.md`
**PR:** [#797](https://github.com/itcmsgr/nftban/pull/797) (sq `9e61faa1`)

> **Why:** two security-visibility gaps (SEC-WL-VERIFY, SEC-IMMUT). Both shell-only, read-only, daemon `cmd/nftband` byte-identical (chain v1.147→v1.163; tree `85a2de3e…`); schema 1.83.0 frozen; no nft writes, no chattr application.

### Added — `nftban whitelist verify` (SEC-WL-VERIFY)
- New **read-only** `verify` subcommand: reads the live kernel whitelist sets (`@whitelist_ipv4` / `@whitelist_ipv6`, via `nft list set` only) and compares them against the durable `whitelist.d/` baseline (no-`EXPIRES_AT` entries). Reports `IN-KERNEL-NOT-IN-BASELINE` (potential injection) and `IN-BASELINE-NOT-IN-KERNEL` (drift / not-applied). Session/TTL entries (`00-session.conf`, unexpired) are **informational, not anomalies** — a live admin session isn't flagged as injected. Symmetric IPv4 + IPv6; rc=0 clean / rc=1 anomalies; remediation hint only (no `--fix`, no nft writes). (`cli/lib/nftban/cli/cmd_whitelist.sh`)

### Added — immutable-flag health verification (SEC-IMMUT)
- New **advisory** health check `nftban_health_check_immutable_flags`: `lsattr` (read-only) confirms `chattr +i` is still present on the security-critical files, **pinned by comment to `internal/installer/validate/authority.go:62`** (`/etc/nftban/nftban.conf` + `/usr/lib/nftban/lib/nft_schema.sh`). WARN-only (appends to `NFTBAN_HEALTH_WARNINGS`, never escalates the health exit code); graceful skip when `lsattr`/`chattr` is unavailable or non-root; never applies the flag (the installer's `SetImmutableFlags` already re-applies it on every install/update). (`cli/lib/nftban/core/nftban_health_checks_security.sh`, registered in `nftban_health.sh`)

### Not in scope (remain open in the register)
- whitelist `--fix` · `permissions --reapply-immutable` · daemon least-privilege · audit-log uid/gid/pid · §2.2/%files/switchop follow-up · §3.6 daemon ssh_ports counter · schema unfreeze · CSF restore.

### Notes
- **Envelope:** shell + tests only — `0 cmd/nftband` (daemon byte-identical) · `0` schema (1.83.0 frozen) · no CSF · no nft writes · no chattr writes.
- **Validation:** lab2 `shellcheck -x -S warning` clean, `bash -n` clean, `whitelist_verify_v163` 23/0, `immutable_health_verify_v163` 16/0 (no nft/chattr writes — mock-verified). CI #797 52/0/2-skip (after a test-file shellcheck-directive fix + a Semgrep IFS-tampering source cleanup — the persistent `IFS=` was rewritten to a scoped `IFS=… read -r -a`, clearing the review threads under the new `required_conversation_resolution` branch protection). Post-merge main `9e61faa1` green (Semgrep ✅, ShellCheck ✅, Project Health ✅, Build RPM el9/el10 ✅, full DEB matrix ✅, Runtime Truth ✅, daemon tree unchanged).

## [v1.162.0] - 2026-06-08 — SSH durable multi-port lock + static fallback

**Codename:** `V162_SSH_DURABLE_MULTI_PORT`
**Controlling record:** `NFTBAN_ROADMAP/V162_SSH_DURABLE_MULTI_PORT_SCOPE.md`
**PR:** [#795](https://github.com/itcmsgr/nftban/pull/795) (sq `b06eed7f`)

> **Why:** DELTA §3.1 was code-challenged and found **largely stale** — both durable-render paths (shell `cmd_firewall.sh` + Go `RenderNftablesConfMultiPort`/`ensureSSHPortsInSet`) already seed the **full** SSH-port union into the durable `ssh_ports` set (v1.125 R-1 + v1.145 PR-A lineage). The genuine residue was test coverage (§3.1) and the static boot-baseline fallback (§3.5). Daemon `cmd/nftband` byte-identical (chain v1.147→v1.162; tree `85a2de3e…`); schema 1.83.0 frozen.

### Ships
- **PR-A (§3.1) — hermetic multi-port durable-render + reboot-sim regression coverage.** New Go test `internal/installer/render/nftables_multiport_reboot_v162_test.go` (mock-executor; `{22,2222,55000}`) and shell test `cli/lib/nftban/tests/ssh_durable_multiport_render_v162.sh` (renders the real `nftables.conf.tpl` via `_firewall_substitute_placeholders` with a mocked multi-port detector). Both assert the durable `set ssh_ports` carries the **full union** (not primary-only) in BOTH ip and ip6 tables, the SSH ct-count rule reads `tcp dport @ssh_ports`, and the durable file alone survives a reboot (no kernel reconcile). Single-port byte-compat retained. Locks the render fix against regression.
- **PR-B (§3.5) — static fallback `install/nftables/nftables.conf` is now set-driven.** Added `set ssh_ports { type inet_service; elements = { 22 } }` to both `table ip nftban` and `table ip6 nftban` (defined-before-use) and migrated both SSH ct-count rules from the literal `tcp dport 22` to `tcp dport @ssh_ports` (the static fallback bakes the default `22` and ct-limit `15`). Brings the boot-baseline in line with the `.tpl` set-driven form. New guard `cli/lib/nftban/tests/static_nftables_ssh_set_driven_v162.sh`; both guards CI-wired.

### Explicitly NOT in scope (remain open in the register)
- **§3.6** daemon `ssh_ports` counter seeding (`cmd/nftband/daemon_init.go` `setNames`) — cosmetic, **DAEMON-Go** (would break the byte-identical chain) → deferred.
- Socket-activated SSH mismatch warning · SSH-port lifecycle validator · SSH-port operator docs · any production-host second-port testing.

### Notes
- **Envelope:** installer-render-test + static-config + CI — `0 cmd/nftband` (daemon byte-identical) · `0` schema (1.83.0 frozen) · no CSF.
- **Validation:** lab2 `go build`/`go test ./internal/installer/render/...` ok, gofmt clean, shell render+reboot-sim + static-set-driven guards pass, v145 set-driven guard still 18/0, **`nft -c -f install/nftables/nftables.conf` rc=0** (boot-baseline parses, `@ssh_ports` resolves, set defined-before-use). CI #795 59/0/3-skip (after one comment-placeholder Policy-Gates fix); post-merge main `b06eed7f` green (Build RPM el9/el10 ✅, full DEB matrix ✅, placeholder guard ✅, daemon tree unchanged).

## [v1.161.0] - 2026-06-08 — installer remainder + hygiene

**Codename:** `V161_INSTALLER_REMAINDER_HYGIENE`
**Controlling record:** `NFTBAN_ROADMAP/NFTBAN_PENDINGS_AND_BUGS_CURRENT.md` (DELTA installer clusters + PACKAGING-HYGIENE)
**PR:** [#793](https://github.com/itcmsgr/nftban/pull/793) (sq `0e08f3d3`)

> **Why:** bounded installer-remainder + hygiene lane after the v1.150.1→v1.159.0 fleet rollout. Daemon `cmd/nftband` byte-identical (chain v1.147→v1.161; tree `85a2de3e…`); schema 1.83.0 frozen; installer/core binaries change intentionally.

### Ships
- **cPanel TCP 4190 (managesieve) parity** — `etc/nftban/conf.d/panels/cpanel/main.conf` gains `4190` in `TCP_IN`+`TCP6_IN` (dovecot managesieve, RFC 5804), matching the Plesk profile.
- **INST-CVE-PARITY — detect-phase parity** — the Go installer `phaseDetect` now classifies the CVE-2025-NFTBAN-001 `inet filter` skeleton (`internal/installer/detect/cve_inet_filter.go`), mirroring the proven DEB/RPM scriptlet guards so the source-install path gets detect/classify/message parity. (Full refuse-on-populated *enforcement* via switchop remains a follow-up — see Not shipped.)
- **OSV scanner curl retry** — `.github/workflows/osv-scanner.yml` install uses `--retry 5 --retry-all-errors …` (transient github.com 504s no longer hard-fail the scan; mirrors the v1.157 fetch-hardening policy).
- **v147a MAC-profile test drift refresh** — `cli/lib/nftban/tests/cli_mac_profiles_v147a_test.sh` S1/S4/A1 updated to the shipped assets: SELinux `policy_module 1.2.0`, capability-set assertion loosened (`net_admin`+`net_raw` within the set), AppArmor `flags=(complain attach_disconnected)`.
- **default-enabled timer first-run CI guard** — `cli/lib/nftban/tests/default_enabled_timer_first_run_guard_v161.sh` (+ CI wiring) asserts every default-enabled timer's service either ships its ExecStart deps or has an ExecCondition that *skips* (not fails) on an absent optional dep — locks the geoban lesson (`TEST_LESSON_GEOBAN_REFRESH_V159`).

### Not shipped (reopened/refined — remain open in the register)
- **§2.2 raw-ghost cleanup** — attempted then reverted: adding `ip/ip6 raw` to the static `ghostTables` violated the PR26.6 preserve-`ip raw` invariant. Refined shape = classify-empty-raw-only (preserve populated/safety raw; remove only proven-empty iptables-nft skeleton).
- **RPM `%files` double-listing cleanup** — attempted then reverted: the `/*` conversion broke the strict rpm 4.16 EL9/EL10 build (`Installed (but unpackaged) file(s) found`) and `templates/{mail,reports,zabbix}` stayed double-listed. Benign LOW warning; correct fix needs `%dir` for the templates subdirs in the FHS generator first, then EL9 iteration.
- **full refuse-on-populated switchop enforcement** — follow-up bundled with the §2.2 classify-empty lane (`CleanGhostTables` still deletes `inet filter` unconditionally; v1.161 ships detect parity, not enforcement parity).

### Notes
- **Envelope:** installer-Go + config + CI + tests — `0 cmd/nftband` (daemon byte-identical) · `0` schema (1.83.0 frozen) · no CSF · no firewall behaviour change.
- **Validation:** lab2 `go build`+`go test` (detect/switchop/installer) ok, gofmt clean, v147a 17/0, timer-guard pass; CI #793 69/0/1-skip; post-merge main `0e08f3d3` green (Build RPM el9/el10 ✅, OSV ✅, daemon tree unchanged). Strict rpm 4.16 `%files` validation is a CI `Build RPM (el9)` concern — the lab hosts can't build the EL RPM (lab4 no Go; lab2 no EL build-deps).

## [v1.160.0] - 2026-06-08 — update-log operator-output truth

**Codename:** `V160_UPDATE_LOG_TRUTH_FIXES`
**Controlling record:** `NFTBAN_ROADMAP/V159_UPDATE_LOG_TRUTH_CROSSFAMILY_TRIAGE.md`
**PR:** [#791](https://github.com/itcmsgr/nftban/pull/791) (sq `02fbab23`)

> **Why:** the v1.150.1→v1.159.0 fleet rollout surfaced cross-family (RPM + DEB) operator-output truth defects on otherwise-successful (`COMMITTED`) updates — warnings that vanished from the final summary, raw lifecycle JSON in the human console, self-contradicting firewall-conflict wording, and a spurious permissions-enforce error on hosts without optional modules. Triage `V159_UPDATE_LOG_TRUTH_CROSSFAMILY_TRIAGE.md` (read-only, srv1 RPM + dns1 DEB).

### Fixed — installer warning accounting (PR-A)
- The installer `Logger` now tallies non-fatal warnings (`WarnCount`/`Warnings`, mutex-guarded); the final COMMITTED summary prints `"COMMITTED, no warnings"` only when the count is 0, else `"COMMITTED, with N warning(s) — non-fatal; see <log>"`. Previously a `[NFTBan WARN]` line (e.g. `systemd-tmpfiles exit 73`, `permissions enforce exit 1`) could print while the summary still claimed "no warnings". (`internal/installer/logging/logger.go`, `cmd/nftban-installer/main.go`)

### Fixed — lifecycle JSON routing (PR-B)
- Lifecycle `detect`/`plan`/`result` JSON events now route to the structured installer log by default instead of the operator console; opt-in console echo via `NFTBAN_LIFECYCLE_JSON=1` or `NFTBAN_DEBUG=1`. Observation semantics unchanged. (`cmd/nftban-installer/lifecycle_bridge.go`, `internal/installer/logging/logger.go`)

### Fixed — firewall package-vs-service conflict wording (PR-C)
- Prerequisite checks (RPM `build_nftban.sh` + DEB `preinst`) are now state-aware for firewalld/ufw: installed+active → conflict warning; installed+enabled-but-inactive → startup-risk; installed+disabled/inactive → advisory; installed+masked → informational; absent → clean. The active-service gate (CHECK-4) is unchanged, so the two stages no longer contradict. No iptables line-count detection; all non-fatal. (`packaging/build_nftban.sh`, `packaging/deb/preinst`)

### Fixed — permissions-enforce skips absent optional-module paths (PR-D)
- `nftban permissions enforce` now SKIPs (does not error) when an optional-module target directory or owner user is absent (e.g. `/var/log/nftban/suricata` / the `suricata` user on a host without Suricata) → returns rc=0 there; real `chown`/`chmod` failures on required paths still error as before. Fixes the srv4 `permissions enforce failed (exit 1)` + the matching `nftban fhs` "Missing 1". (`cli/lib/nftban/core/nftban_permissions.sh`)

### Notes
- **Envelope:** installer-Go + packaging-shell + tests only — **`0 cmd/nftband` (daemon byte-identical to v1.159.0; chain v1.147→v1.159.0 holds)** · `0 cmd/nftban-core` · `0` schema (1.83.0 frozen) · no CSF · no firewall behaviour change. The installer/core binaries change intentionally; the daemon does not.
- **Tests:** `logger_warncount` / `committed_summary` / `lifecycle_routing` (Go); `firewall_pkg_wording_v160` 8/0 + `permissions_optional_module_skip_v160` 5/0 (shell). lab2: `go build`+`go test` ok, gofmt clean, `build/generate-fhs-outputs.sh --check` rc=0, `cmd/nftband` tree `85a2de3e…` unchanged. CI on PR #791: 69 pass / 0 fail / 3 skip; post-merge main green.

## [v1.159.0] - 2026-06-07 — hotfix: geoban-refresh skips when geoip helper absent

**Codename:** `V159_GEOBAN_REFRESH_DEGRADE_FIX`
**Controlling record:** `NFTBAN_ROADMAP/V158_FLEET_ROLLOUT_RECORD.md`
**PR:** [#789](https://github.com/itcmsgr/nftban/pull/789) (sq `dab45096`)

> **Why:** **`BUG-GEOBAN-REFRESH-UNSHIPPED-GEOIP-DEGRADES-INSTALL`** (HIGH, fleet-rollout blocker, found on lab2 during the v1.158 rollout). v1.156 added `nftban-geoban-refresh.timer` to the installer core-timer set; its service runs `nftban geoip refresh`, which needs the `nftban-geoip` helper (`core/nftban_geoban.sh`: `bin/.real/nftban-geoip-$(uname -m)` or `bin/nftban-geoip` fallback) — **not shipped** in the base package. The service's only `ExecCondition` checked the geoban config (package-owned, ships `GEOBAN_ENABLED="true"`), so on upgrade it ran and **hard-failed** → installer `failed_units_postinstall_ok` → `INSTALL_STATE=DEGRADED` (every host). Latent pre-v1.156 (timer shipped-disabled).

### Fixed — `nftban-geoban-refresh.service` skips (not fails) when the geoip helper is absent
- Added a 2nd `ExecCondition` gating on the geoip helper binary (mirrors the resolver in `core/nftban_geoban.sh`). A failed `ExecCondition` marks the unit **skipped (condition-not-met), NOT failed** → no longer trips the install assertion. **`ExecStart` unchanged** — if the helper is installed later, the service runs normally.
- Regression lock `cli/lib/nftban/tests/geoban_refresh_execcondition_v159_test.sh` (7/0): config+geoip ExecConditions present, ExecStart intact, missing→skip, `.real`→run, fallback→run, non-exec→skip. `systemd-analyze verify` rc=0 (lab2).

> **Envelope:** systemd-unit + test only — `0 cmd/nftband` (daemon byte-identical to v1.158.0; chain v1.147→v1.158.0 holds) · `0 cmd/nftban-core` · `0` Go · `0` schema (1.83.0 frozen) · no CSF · no firewall behaviour change. CI on PR #789: 53 pass / 0 fail / 4 skip. Release-prep touches only `VERSION`, `STATUS.md`, `CHANGELOG.md`, `cli/lib/nftban/core/nftban_fhs_spec.sh` (header `meta:version` regen; FHS body byte-unchanged — SHA256 `5cc865943fe21c31499739216e25582142e155fecbd20a8adba0cb62c6906971`). **Process lesson recorded** (`TEST_LESSON_GEOBAN_REFRESH_V159`): default-enabled timer/service lanes must test the real first-run host outcome, not just enablement. lab2 (already v1.158-DEGRADED) recovers via a one-time `systemctl reset-failed` after the v1.159 upgrade; the other 8 hosts upgrade v1.150.1→v1.159.0 directly and skip cleanly. Then fleet rollout resumes. Hygiene bundle = v1.160.

---

## [v1.158.0] - 2026-06-07 — security-posture MAC visibility

**Codename:** `V158_SECURITY_POSTURE_MAC`
**Controlling record:** `NFTBAN_SECURITY_POSTURE_GAP_ANALYSIS.md`
**PR:** [#787](https://github.com/itcmsgr/nftban/pull/787) (sq `411a98d9`)

> **Why:** surface Mandatory Access Control (AppArmor/SELinux) protection state in the existing posture output — a narrow visibility add, **advisory-only**, no posture rewrite. The existing `nftban health posture` / `_collect_posture_info` / `sshd -T` effective-config / broad-only NOPASSWD logic are **extended, not rebuilt**. `0 cmd/nftband` (daemon byte-identical to v1.157.0) · `0 cmd/nftban-core` · `0 internal` · `0` schema (1.83.0 frozen) · no CSF.

### Added — MAC posture summary (AppArmor + SELinux)
- `cli/lib/nftban/lib/nftban_report_data.sh` `_collect_posture_info` + `cli/lib/nftban/cli/cmd_health_analysis.sh` (detailed) + `cmd_status.sh` (compact) now report MAC protection state. **AppArmor:** `aa-status`/securityfs; nftband profile; PASS loaded+enforcing / WARN missing-or-complain / INFO absent. **SELinux:** `getenforce` + `semodule -l`; nftban module; PASS Enforcing+module / WARN mismatch-or-missing / INFO absent. **Distro-aware** (no AppArmor WARN on SELinux-primary hosts; no SELinux WARN on Debian/Ubuntu). **Advisory-only** — MAC WARN increments `warnings`, never `issues`; health/install exit-code semantics unchanged; non-root-safe.

### Added — posture surface-map doc + JSON-behavior note (PR-A)
- `docs/security/MAC_PROFILES_SELINUX_APPARMOR.md` §12/§13: compact `nftban status` vs detailed `nftban health posture`/`health check`; the advisory model; the `--json` finding (`health posture` is text-only — machine-readable posture is via the status-JSON `POSTURE_*` fields); intentionally-excluded rp_filter / panel-port / iptables-line-count + deferred sysctl. New test `mac_posture_v158_test.sh` (13/0, all 8 required cases).

### Changed — CI: canonical RPM install matrix only
- `.github/workflows/build-packages.yml` Test-RPM-install matrix trimmed to the canonical release targets: **EL9 = Rocky 9, EL10 = AlmaLinux 10** (removed centos-stream9, centos-stream10, alma9 install legs). Build RPM matrix already canonical (rockylinux:9 / almalinux:10) — unchanged. README download links unaffected (assets are `nftban-el9/el10-x86_64.rpm`, distro-agnostic). CI-only.

### Deferred / unchanged
- **sysctl posture deferred** (PR-C — `tcp_syncookies`/`accept_redirects`/`log_martians`/`rp_filter` advisory-only/opt-in; not in this release).
- No daemon/schema/runtime change (verified: 0 `cmd/nftband`, 0 Go, 0 schema; daemon byte-identical to v1.157.0; chain v1.147→v1.157.0 holds).

> **Envelope:** shell + tests + docs + CI-matrix only. **Tests:** `mac_posture_v158` 13/0; `stats_status_truth_v150` regression PASS; shellcheck + `bash -n` clean. CI on PR #787: 52 pass / 0 fail / 2 skip (RPM install legs = rocky9 + alma10 only). Release-prep touches only `VERSION`, `STATUS.md`, `CHANGELOG.md`, `cli/lib/nftban/core/nftban_fhs_spec.sh` (header `meta:version` regen; FHS body byte-unchanged — SHA256 `5cc865943fe21c31499739216e25582142e155fecbd20a8adba0cb62c6906971`). Next: srv1 SSHPORT proof, then fleet rollout.

---

## [v1.157.0] - 2026-06-07 — CI / release fetch hardening

**Codename:** `V157_CI_FETCH_HARDENING`
**Controlling record:** `NFTBAN_ROADMAP/V157_CI_FETCH_HARDENING_SCOPE.md`
**PR:** [#785](https://github.com/itcmsgr/nftban/pull/785) (sq `29eb4c12`)

> **Why:** the release pipeline kept hard-failing on transient external downloads (yq partial download → SHA mismatch, syft HTTP 504, Docker base-image pull timeouts, Go toolchain TLS timeout) — correct-to-fail but too brittle. Make every build-time fetch resilient. **CI / workflow / build-script only — 0 runtime/daemon/schema/CSF change; daemon byte-identical to v1.156.0.**

### Changed — resilient build-time fetches
- **PR-A** — new shared `packaging/lib/fetch_verified.sh` (`curl --fail --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 10 --max-time 120 -sS` → SHA256 verify → atomic `mv`; fails closed; cleans temp). All 3 yq fetch sites use it (RPM `%install` heredoc inlines the identical hardened curl). YQ pins unchanged. Hermetic test (`fetch_verified_v157_test.sh`) 7/0.
- **PR-B** — 3-attempt `docker pull` backoff (3/9/27s) before every `docker run` (Build RPM/DEB + Test RPM/DEB) → kills the `registry-1.docker.io` exit-125 class.
- **PR-C** — pinned all 18 `setup-go` sites `1.25` → `1.25.11` (matches go.mod toolchain; patch can't move) + `GOTOOLCHAIN=local` on build-our-module jobs (reasons inline for the ones deliberately excluded).
- **PR-D** — syft/SBOM: cache syft via `download-syft` pre-step + pin `syft-version: v1.42.3` so the SBOM step reuses the cache (the HTTP-504 source). SBOM output unchanged.
- **Fix** (`FIX_V157_PR_A_DUPLICATE_RPM_INSTALL`) — PR-A's first cut put the literal token `%install` in a comment inside the spec `%install` body; **rpm 4.16 (EL9) + EL10 parse that as a second `%install` section** (`error: line 116: second %install`), failing Build RPM el9/el10. (rpm 4.18 on lab2 is lenient — didn't reproduce.) Reworded the comment (no token); added guard test `rpm_spec_single_install_v157_test.sh` (asserts exactly one `^%install$`). Proven on real EL9 rpm 4.16.1.3: pre-fix errored, post-fix clean.

> **Envelope:** CI/workflow/build-script only — `0 cmd/nftband` (daemon byte-identical to v1.156.0; chain v1.147→v1.156.0 daemon-frozen holds) · `0 cmd/nftban-core` · `0 internal` · `0 cli` runtime · `0` schema (1.83.0 frozen) · no CSF. PR-E (auto-rerun) deferred. **Validation:** lab2 shellcheck + `bash -n` clean; `fetch_verified_v157` 7/0; `rpm_spec_single_install_v157` 6/0; 18/18 workflows valid YAML; EL9 rpm-4.16 spec-parse proof. CI on PR #785: 67 pass / 0 fail / 4 skip (el9 + el10 RPM pass). Release-prep touches only `VERSION`, `STATUS.md`, `CHANGELOG.md`, `cli/lib/nftban/core/nftban_fhs_spec.sh` (header `meta:version` regen; FHS body byte-unchanged — SHA256 `5cc865943fe21c31499739216e25582142e155fecbd20a8adba0cb62c6906971`). Next: v1.158 = security-posture MAC, then srv1 SSHPORT proof, then fleet rollout.

---

## [v1.156.0] - 2026-06-07 — installer/CI rollout-safety cleanup

**Codename:** `V156_INSTALLER_CI_ROLLOUT_SAFETY`
**Controlling record:** `NFTBAN_ROADMAP/V156_INSTALLER_CI_ROLLOUT_SAFETY_SCOPE.md`
**PR:** [#783](https://github.com/itcmsgr/nftban/pull/783) (sq `eb143701`)

> **Why:** small, bounded, rollout-relevant items that make fleet deployment safer — no broad parity rewrite, no daemon/schema decisions. `0 cmd/nftband` (daemon byte-identical to v1.155.0) · `0 cmd/nftban-core` · `0` schema (1.83.0 frozen) · no CSF · no Lane-C daemon-Go. The installer binary (`cmd/nftban-installer` / `internal/installer`) changes intentionally.

### Changed — geoban-refresh.timer enabled as a best-effort core timer (PR-A)
- `internal/installer/services/timers.go` adds `nftban-geoban-refresh.timer` to `coreTimers` (best-effort `enableAndStart`; **not** `criticalCoreTimers`). Closes the v1.150 "geoban timer installed-but-disabled" caveat. Hermetic enablement tests added.

### Added — empty-env smoke CI guard (PR-B, H4)
- `.github/workflows/ci-empty-env-smoke.yml`: runs the CLI (`version`/`help`/`status --help`) and the installer (`--version`/`-h`) under `env -i` to catch `set -u`/unbound-variable crashes — read-only, no mutation. Hermetic test `cli_empty_env_smoke_v156_test.sh`.

### Added — installer.log `[PHASE]` boundary markers (PR-C)
- `cmd/nftban-installer/phases.go` emits `[PHASE] <name> start` / `[PHASE] <name> end` across all five phases (logging-string only; no flow change) — greppable phase boundaries for rollout triage. Parity test (`phase_markers_test.go`) fails CI if a future phase lacks markers.

### Fixed — strict-IFS `read -ra` on portscan timestamp splitters (PR-D)
- `cli/lib/nftban/core/nftban_portscan_classic.sh`: the two space-joined timestamp splitters now use `IFS=$' \t\n' read -ra` (a bare `read -ra` inherits the CLI's strict `IFS=$'\n\t'` and collapses them — same family as the v1.152 feeds-select fix). Test `read_ra_ifs_v156_test.sh`. The `cmd_emulate`/`nftban_tunnel` candidates already set `IFS` inline (safe) → left as recorded triage.

> **Envelope:** installer-Go + CI + shell + tests — `0 cmd/nftband` (daemon byte-identical to v1.155.0; chain v1.147→v1.155.0 daemon-frozen holds) · `0 cmd/nftban-core` · `0` schema (1.83.0 frozen) · no CSF · no Lane-C daemon-Go. Installer binary intentionally changes. **Validation (lab2 go1.25.11):** `go vet ./...` clean · `go build ./...` rc=0 · `go test -race` PASS (internal/installer/services + cmd/nftban-installer) · `go mod tidy` clean; `shellcheck -S warning` clean; empty-env 4/0 · read-ra 6/0. CI on PR #783: 71 pass / 0 fail / 1 skip. Release-prep touches only `VERSION`, `STATUS.md`, `CHANGELOG.md`, `cli/lib/nftban/core/nftban_fhs_spec.sh` (header `meta:version` regen; FHS body byte-unchanged — SHA256 `5cc865943fe21c31499739216e25582142e155fecbd20a8adba0cb62c6906971`). **No fleet rollout in this lane.**

---

## [v1.155.0] - 2026-06-07 — SSH-port lifecycle / srv1 unblocker

**Codename:** `V155_SSH_PORT_LIFECYCLE`
**Controlling record:** `NFTBAN_ROADMAP/V155_SSH_PORT_LIFECYCLE_SCOPE.md`
**PR:** [#781](https://github.com/itcmsgr/nftban/pull/781) (sq `5681dd72`)

> **Why:** remove the srv1 / external-`:55000` ambiguity blocking the fleet rollout by adding the two missing SSH lifecycle pieces + a reproducible proof procedure. **Read-only; shell + tests + docs only.** `0` Go · `0 cmd/nftband` (daemon byte-identical to v1.154.0) · `0` schema (1.83.0 frozen) · no direct nft writes · no CSF. nftban is an ingress IPS, not a NAT manager; the external `:55000→:22` redirect stays host-managed; `:22` is never at risk; `ssh_ports` = the real sshd listeners only.

### Added — socket-activated SSH port-mismatch warning (PR-1, item 3.2)
- `cli/lib/nftban/lib/ssh_admin_port_guard.sh` gains `nftban_ssh_socket_port_mismatch_audit` (surfaced via `nftban firewall ssh-audit`): on a **socket-activated** sshd, when the configured Port (`sshd -T`) ≠ the actual listeners (the `ssh.socket` unit was not restarted after a config change), emit ONE calm warning naming the class + the verbatim remediation `systemctl daemon-reload && systemctl restart ssh.socket`. Read-only — never restarts; warns to stderr only when configured≠listening AND socket-activated AND both sides readable (otherwise silent).

### Added — SSH-port-change lifecycle validator (PR-2, item 3.3)
- `tools/validation/ssh_port_change_lifecycle_validate.sh` (read-only) asserts: every sshd listener ∈ `tcp_ports_in` ∧ ∈ `ssh_ports`; the brute-force ct-count rule references `@ssh_ports`; and there is no literal `tcp dport <sshport>` for ssh (must use the set). Env-injectable (`NFTBAN_VALIDATE_RULESET_FILE` / `NFTBAN_VALIDATE_LISTENERS`) for hermetic testing; on a host it auto-collects via `nft list ruleset` + the guard lib (read-only). Wired into CI (`ci-architecture.yml`).

### Added — SSH-PORT-LIFECYCLE docs / OBS-SSHPORT decision matrix (PR-3, docs only)
- `docs/SSH-PORT-LIFECYCLE.md` — the socket-activation pitfall + lifecycle invariants, the **read-only** srv1/dns2 external-`:55000` reproduction/observation procedure, and a decision matrix for the two srv1 gates. The on-host srv1 proof is recorded as a **separate post-release read-only gate** (full lifecycle proof). Cross-linked from `docs/SSH-EXTERNAL-ADMIN-PORT.md`.

> **Envelope:** shell + tests + docs only — `0` Go · `0 cmd/nftband` (daemon byte-identical to v1.154.0; chain v1.147→v1.154.0 daemon-frozen holds) · `0 cmd/nftban-core` · `0` schema (1.83.0 frozen) · no direct nft · no CSF · no host mutation. **Tests:** `ssh_socket_port_mismatch_v155` 15/0 · `ssh_port_change_lifecycle_v155` 17/0; regression `ssh_admin_port_guard_v150` 36/0; shellcheck 0.9.0 + `bash -n` clean. CI on PR #781: 52 pass / 0 fail / 2 skip (Socket + Go-Security, both expected; 0 Go) after one `Build Go binaries` setup-go/toolchain TLS-timeout flake rerun. Release-prep touches only `VERSION`, `STATUS.md`, `CHANGELOG.md`, `cli/lib/nftban/core/nftban_fhs_spec.sh` (header `meta:version` regen; FHS body byte-unchanged — SHA256 `5cc865943fe21c31499739216e25582142e155fecbd20a8adba0cb62c6906971`). **No fleet rollout in this lane; srv1 proof = separate post-release read-only gate.**

---

## [v1.154.0] - 2026-06-06 — install timer-reload hardening

**Codename:** `V154_INSTALL_TIMER_RELOAD`
**Controlling record:** `NFTBAN_ROADMAP/OPEN_INSTALL_UPDATE_TIMER_RELOAD_HARDENING_PLAN.md`
**PR:** [#779](https://github.com/itcmsgr/nftban/pull/779) (sq `11ded868`)

> **Why:** self-heal the post-install systemd timer-wedge class (D-INSTALL-TIMER-RELOAD). On the v1.142.0 fleet rollout one host (dns2) finished install with `nftban-unified-exporter.timer` stuck `active (elapsed)` + `Trigger: n/a` + 0 runs/24h; the manual fix was `systemctl daemon-reload && systemctl restart <timer>`. The installer now performs that recovery automatically — **only for wedged timers**. **installer-Go only.**

### Fixed — post-install timer wedge / elapsed-timer recovery (D-INSTALL-TIMER-RELOAD)
- New `internal/installer/services/timers_post_install.go` — `RestartWedgedTimers`: at the end of installer `phaseValidate` (after `SetImmutableFlags`, before the `StateCommitted` transition), issue `daemon-reload`, then restart **only** timers showing the wedge signature (`ActiveState=active` with no next-elapse). **Warn-only / non-fatal**; probe errors are treated as healthy (zero false positives — never restarts a healthy or inactive timer).
- `internal/installer/services/timers.go` — 22-timer single-source-of-truth superset + `KnownTimers()` accessor (no duplicate const in `cmd/nftban-installer`).
- `cmd/nftban-installer/phases.go` — single call site, placed to cover all three `phaseValidate` terminal paths (including the VALIDATE_1-pass path where the dns2 wedge actually occurred).
- Tests: `timers_post_install_test.go` (mock wedge-recovery — exactly the wedged timers restarted, errors non-fatal, none-wedged is a no-op) + `timers_post_install_parity_test.go` (drift-parity: `KnownTimers()` ≡ `install/systemd/*.timer`, fails CI if a `.timer` is added without updating coverage).

> **Envelope:** installer-Go only — **`cmd/nftband` daemon byte-identical to v1.153.0** (chain v1.147→v1.153.0 holds) · `0 cmd/nftban-core` · `0` schema (1.83.0 frozen) · no CSF · no UX/shell spillover. The installer binary (`cmd/nftban-installer` / `internal/installer`) **does** change — intentional; installer byte-identity is not frozen. **Validation (lab2 go1.25.11, rebased on v1.153.0 main `f1a92d3a`):** `go vet ./...` rc=0 · `go build ./...` rc=0 · `go test -race` PASS (internal/installer/services + cmd/nftban-installer) · `go mod tidy` clean. CI on PR #779: 68 pass / 0 fail / 1 skip (Socket, expected); post-merge main CI 14/0. Release-prep touches only `VERSION`, `STATUS.md`, `CHANGELOG.md`, `cli/lib/nftban/core/nftban_fhs_spec.sh` (header `meta:version` regen; FHS body byte-unchanged — SHA256 `5cc865943fe21c31499739216e25582142e155fecbd20a8adba0cb62c6906971`). Cleanup train: v1.151 → v1.152 → v1.153 → **v1.154** (this).

---

## [v1.153.0] - 2026-06-06 — UX consistency / output-truth polish

**Codename:** `V153_UX_CONSISTENCY`
**Controlling record:** `NFTBAN_ROADMAP/V153_UX_CONSISTENCY_SCOPE.md`
**PR:** [#777](https://github.com/itcmsgr/nftban/pull/777) (sq `82572f91`)

> **Why:** make CLI output consistent and honest — mechanisms not adjectives; never claim *validated/completed/protected* unless kernel-proven. **Broad-output-only UX lane (6 commits A–F).** `0 cmd/nftband` (daemon byte-identical to v1.152.0) · `0 cmd/nftban-core` · `0` schema (1.83.0 frozen) · no direct nft · no CSF; installer-Go limited to **message wording only** (`panelfw.go` port-range display + `main.go` completion message).

### Changed — status output-truth + cross-command consistency (PR-A, UX-A1/A2/A5/A6 + CMD-CONSIST)
- `cmd_status.sh` authority block reworded so neutralized legacy firewalls no longer read as active conflicts (`Firewall authority.. 🔒 EXCLUSIVE` / `Legacy firewalls.... 🛡️ NEUTRALIZED:`); timers line reads `Core N/N active · Optional M disabled · Failed 0` (was a misleading `8 / 16`); modules mark `(optional add-on)` with one term per service; the authoritative posture is stated once (the health roll-up is relabelled "Health" diagnostics, not a competing verdict). New shared `nftban_kv` label helper for consistent dot-leader columns.

### Changed — banner discipline + universal suppression (PR-B, UX-A3/UX-C4/13.11)
- One banner path; `Cmd:` shows the real subcommand (was `cli`); the full box is restricted to `version`/`status`/first-run, subcommands print a one-line header. `--no-banner`/`--plain`/`--quiet` (and `NFTBAN_NO_BANNER`) honored universally via a single gate in the renderer (`--json` unaffected).

### Changed — error-text normalization (PR-C, UX-C2 + UX-C6)
- Error paths print a 3-line form (`ERROR: <fault>` / `Hint: <one-line>` / `Run 'nftban <cmd> --help' for more`) instead of reprinting the full ~30-line usage block; EUID≠0 failures emit an inline sudo / root-shell hint.

### Changed — list table format (PR-D, UX-A4)
- The human `nftban list all` IPv6 column is width-clamped/CIDR-shortened so Type/Version stay aligned; the full range remains in `--json`.

### Changed — installer-output wording (PR-E, UX-T1..T4 — wording only)
- Named WARN classes (`WARN_PERMISSIONS_ENFORCE_NONFATAL`, `WARN_TMPFILES_73`) emitted in the editable `nftban_health_fixes.sh` (**not** the gate-frozen generated `nftban_fhs_spec.sh`); installer-Go `panelfw.go` port-range display compresses contiguous ranges; `main.go` says "completed with warnings (non-fatal)" on the DEGRADED path. No installer behavior/flow change.

### Changed — help / output-truth sweep (PR-F, UX-A7)
- Short `nftban help` gains the ⚡/⚠️ markers on state-changing verbs; remaining unproven `validated`/`completed`/`protected`/`success` claims downgraded to mechanism-accurate wording.

> **Envelope:** shell + tests + installer-Go wording only — `0 cmd/nftband` (daemon byte-identical to v1.152.0) · `0 cmd/nftban-core` · `0` schema (1.83.0 frozen) · `0` VERSION-drift · no direct nft · no CSF; VERSION/STATUS.md/CHANGELOG.md/`nftban_fhs_spec.sh`-body untouched by the feature PR. **Tests:** 6 new hermetic suites — `status_consistency_v153` 15/0 · `banner_nobanner_v153` 16/0 · `error_text_3line_v153` 12/0 · `list_ipv6_clamp_v153` 10/0 · `installer_wording_v153` 13/0 · `help_verb_icons_v153` 22/0; 10 regression guards green; shellcheck 0.9.0 rc=0; Go (lab2 go1.25.11) mod-tidy/vet/build/race PASS; `check-nft-writes` 0. Release-prep touches only `VERSION`, `STATUS.md`, `CHANGELOG.md`, `cli/lib/nftban/core/nftban_fhs_spec.sh` (header `meta:version` regen; FHS body byte-unchanged — SHA256 `5cc865943fe21c31499739216e25582142e155fecbd20a8adba0cb62c6906971`). Cleanup train: v1.151 → v1.152 → **v1.153** (this) → v1.154 (install-timer-reload).

---

## [v1.152.0] - 2026-06-06 — feeds + stats truth cleanup

**Codename:** `V152_FEEDS_STATS_TRUTH`
**Controlling record:** `NFTBAN_ROADMAP/V152_FEEDS_STATS_TRUTH_SCOPE.md`
**PR:** [#775](https://github.com/itcmsgr/nftban/pull/775) (sq `496168bf`)

> **Why:** fix user-visible CLI/data-truth defects. **Shell + tests only — daemon byte-identical to v1.151.0** (`0 cmd/nftband`, `0 cmd/nftban-core`, `0 internal` Go); **schema 1.83.0 frozen**; **no CSF**.

### Fixed — `nftban feeds select` non-functional under strict IFS (BUG-FEEDS-SELECT-NONFUNCTIONAL)
- `strict.sh` sets `IFS=$'\n\t'` (no space) for the whole CLI, so `cmd_feeds.sh:231` `read -ra parts <<< "${selection//,/ }"` collapsed multi-number / comma input into ONE un-parseable token → "No valid feeds selected" for every multi/comma selection (a single number survived). Fixed: `IFS=$' \t\n' read -ra parts <<< …` so space/tab/newline split correctly regardless of the inherited strict-mode IFS. Root-caused via a live trace on lab4; the prior CI stub ran without strict-mode IFS, so it stayed green while the feature was broken.

### Fixed — stats producer/consumer total ≠ perm+temp+manual (13.10)
- The unified-exporter legacy branch read the always-absent `.permanent`/`.temporary` cache keys → `perm=0, temp=0` while total (active) = blacklist+manual, so `nftban stats` showed an unreconciled `IPv4 5 (perm: 0, temp: 0, manual: 2)`. The producer now reports all-as-permanent (like the daemon-cache branch) so **total = perm + temp** on every path (daemon-cache, legacy, nft-fallback), IPv4 + IPv6; `manual` is a labelled **subset** (`incl. manual`), not additive. A real perm/temp split is a daemon-side concern (deferred).

### Fixed — `nftban status` DOWN exit-code contract (BUG-S1a/S1b)
- The two ERROR+DOWN paths in `_nftban_protection_state_validator` (validator-missing, validator-empty) did `echo DOWN; return` (bare) → rc=0, violating the v1.139.2 rc-contract. Now `return 1`, with the three plain `var=$(_nftban_protection_state)` captures guarded with `|| true` so the DOWN sentinel is still used and the top-level exit stays mapped from `base_state` (DOWN → 2). Behavior-preserving at the top level.

### Tests
- `feeds_select_strict_e2e_v152_test.sh` (13/0) — parse under `IFS=$'\n\t'`, single/multi/comma/mixed/range/category/empty.
- `stats_producer_reconcile_v152_test.sh` (10/0) — all 3 producer branches reconcile (total=perm+temp; manual⊆total), IPv4+IPv6 + consumer label.
- `status_rc_contract_v152_test.sh` (7/0) — DOWN paths return rc≥1, captures guarded, DOWN→exit 2 preserved.

### Deferred (recorded, not in this release)
- `BUG-CtCount-feeds` (feed-counter unification) — became a broader helper-refactor.
- 6 other `read -ra … <<<` sites without an `IFS=` prefix (`cmd_emulate.sh:186`, `nftban_tunnel.sh:116/360/383`, `nftban_portscan_classic.sh:640/732`) — separate read-only triage.

---

## [v1.151.0] - 2026-06-06 — small cleanup / trust-output hotfix

**Codename:** `V151_TRUST_OUTPUT`
**Controlling record:** `NFTBAN_ROADMAP/V151_CLEANUP_SCOPE.md`
**PR:** [#773](https://github.com/itcmsgr/nftban/pull/773) (sq `a6d57e89`)

> **Why:** clean up confusing/false install/update/runtime output without touching the daemon, schema, or CSF. **Daemon byte-identical to v1.150.1** (`0 cmd/nftband`, `0 cmd/nftban-core`); **schema 1.83.0 frozen**; **no CSF**. Installer-Go limited to panelfw + rebuild-log (output/decision wording only).

### Fixed — panelfw weak DirectAdmin false-positive
- On a no-panel host whose alt-SSH listens on `:2222`, a single weak signal previously printed `detected panel id=directadmin confidence=weak` and validated/printed the full DirectAdmin port set (`35000-35999`) as if confirmed. `internal/installer/panelfw/panelfw.go` now gates validation/printing on `Confidence != "weak"` — a weak detection logs "weak signal ignored; no confirmed panel" and is treated as no-panel. It was never applied to the kernel (a validation/host-env false positive, not policy application). Strong (≥3-signal) detections are unaffected.

### Fixed — exporter `rc=143` false-error class-killer (D-EXPORTER-EXIT2-PHASE-4)
- The unified-exporter ERR trap (`cli/lib/nftban/exporters/nftban_unified_exporter.sh:48`) logged a SIGTERM/SIGINT (`rc>=128`) as `ERROR: aborted` at whatever command the signal interrupted — noisy false errors on every timer-killed collection. It is now **signal-aware**: `rc>=128` → one graceful `INFO` line (`interrupted by signal; next scheduled run will collect`), no `ERROR:`; `rc<128` (a real failure) keeps the loud diagnosable line. Ends the v1.143.1 per-site whack-a-mole. The exporter is auxiliary (metrics-only).

### Fixed — `nftban version` Build Date truth
- `cli/lib/nftban/lib/version.sh` computed `Build Date` as `$(date)` at runtime, so `nftban version` always showed the current clock (useless for support / CVE-patch tracking). It now resolves a real build stamp: build-stamp file → `rpm` BUILDTIME → `"unknown"` — **never the current clock**.

### Fixed — degraded-rebuild log truth (installer)
- `internal/installer/switchop/rebuild.go` logged `firewall rebuild DEGRADED (exit 1): ` (blank reason) followed by the self-contradictory `completed (exit 1)`, which reads as a failed takeover and tempts a Ctrl+C/rollback at the worst moment. It now logs a real reason (stderr → last stdout line → static "base schema loaded; module chains deferred to daemon start") and a non-contradictory `finished DEGRADED (exit 1) — recovery expected`; exit 0 logs a plain `completed`.

### Validation
- **Go (lab2, go1.25):** `gofmt`/`go vet ./...`/`go build ./...` clean; `panelfw_test.go` (+2: weak-skip, strong-finalizes) and `rebuild_test.go` (+3: degraded-reason-from-stdout, static-fallback, plain-completed) PASS.
- **Shell (local):** `exporter_sigterm_graceful_v151_test.sh` 11/0, `version_build_date_v151_test.sh` 8/0; shellcheck clean; `check-nft-writes.sh` 0 WRITE violations.
- First of the cleanup train: v1.151 → v1.152 (feeds+stats truth) → v1.153 (UX-consistency).

---

## [v1.150.1] - 2026-06-05 — external admin SSH-port guard (warn-only + lockout-net)

**Codename:** `OBS_SSHPORT_55000`
**Controlling records:** `NFTBAN_ROADMAP/SSHPORT_55000_EXTERNAL_REDIRECT_SURVIVES_REBUILD_SCOPE.md` · `V150_FLEET_ROLLOUT_RECORD.md` (srv1 triage)
**PR:** [#769](https://github.com/itcmsgr/nftban/pull/769) (sq `dbf7d8f3`)

> **Why:** a small, lockout-adjacent hotfix on top of v1.150.0 for the `OBS-SSHPORT-55000-FAMILY` host-config class (srv1, dns2). On hosts where admin SSH arrives on an **external** redirect/NAT port (e.g. `:55000 → :22` via firewalld / iptables-nft / provider / panel), a `nftban firewall rebuild`/`takeover` — which disarms competing firewall layers — can transiently drop that external port. `sshd` listens only on `:22`, so nftban correctly renders `ssh_ports = { 22 }` and has no source that can see `:55000` (no conntrack); `:22` is never at risk. **Pre-existing host-config debt, NOT a v1.150 regression** (behaves identically v1.142↔v1.150). **Daemon byte-identical to v1.150.0; schema 1.83.0 frozen.**

### Added — `nftban firewall ssh-audit`
- A read-only report comparing **sshd listeners** vs nftban **`ssh_ports`** vs operator-declared external admin ports (`NFTBAN_EXTERNAL_ADMIN_SSH_PORTS`), flagging an external `:55000 → :22` redirect that nftban does not own. (Alias: `ssh-port-audit`.)

### Added — pre-rebuild lockout-net (warn-only + IPC whitelist)
- Before `firewall rebuild`/`reload`/`takeover`, nftban now **warns** when an external admin SSH port is declared/mismatched and **session-whitelists the active admin source IP** through the existing IPC `whitelist-session` path, so SSH survives **by IP** regardless of the external port. Recursion-guarded; opt-out `NFTBAN_NO_PREREBUILD_LOCKOUT=1`; TTL `NFTBAN_PREREBUILD_LOCKOUT_TTL` (default `1h`).
- **No direct nft write** — the lockout-net uses the sanctioned single-writer IPC path only (`check-nft-writes.sh` stays at 0 WRITE violations).

### Rejected by design
- **Importing `:55000` into `ssh_ports`** — `ssh_ports` drives the brute-force rate-limit on the real sshd *listener*; sshd is not on `:55000`, so importing it would be wrong and unsafe (and would not restore the external redirect).
- **Recreating/preserving the external NAT/redirect** — nftban is an ingress IPS, not a NAT manager; the `:55000 → :22` redirect stays host-managed (firewalld/iptables-nft/panel/provider).

### Scope / Validation
- **Shell + CI + docs only** — `0 cmd/nftband`, `0 cmd/nftban-core`, `0 internal` Go, `0` schema. New 36/36 hermetic test (`ssh_admin_port_guard_v150_test.sh`) wired as a CI step; new operator doc `docs/SSH-EXTERNAL-ADMIN-PORT.md` (plain-English root cause + verbatim CLI text, asserted by the test); `docs/ARCHITECTURE-NFT-POLICY.md` notes the lockout-net is not a new nft-write exception.
- Merged CI-green: Policy Gates, Shell Quality, ShellCheck, Runtime Truth almalinux-9 + ubuntu-24.04, all DEB (debian12/13, ubuntu22/24/26) + RPM (el9/el10, alma9, centos-stream9/10, rocky9) build & install, CodeQL, Semgrep, OSV, docs.
- **Deploy target:** srv1 + dns2 first, then resume the remaining fleet rollout on v1.150.1.

---

## [v1.150.0] - 2026-06-05 — CLI-health truth & cleanup + nft-writer single-authority tightening + stats fixes

**Codename:** `V150_CLI_HEALTH`
**Controlling records:** `NFTBAN_ROADMAP/V150_FULL_CLI_HEALTH_AUDIT_RECORD.md` · `V150_SCOPE.md` · `V150_LANE_A_LAB_VALIDATION_RECORD.md` · `V150_BAN_UNBAN_SINGLE_AUTHORITY_AUDIT.md` · `V150_NFT_WRITER_AUTHORITY_TIGHTENING_SCOPE.md`
**PRs:** [#764](https://github.com/itcmsgr/nftban/pull/764) (Lane A, sq `bd2d35e5`) · [#765](https://github.com/itcmsgr/nftban/pull/765) (AUTH, sq `c3ee98d7`) · [#766](https://github.com/itcmsgr/nftban/pull/766) (F2, sq `255bb757`) · [#767](https://github.com/itcmsgr/nftban/pull/767) (F3, sq `3c792944`)

> **Why:** a truth-focused release — make the CLI report what the firewall is actually doing, tighten the single-writer nftables authority, and fix the broken `stats --json`. **Daemon byte-identical to v1.149.0** (zero `cmd/nftband`/`cmd/nftban-core` change across all four lanes; the only Go touched is `internal/nftbanconf/logs.go`, dead-code-eliminated from the daemon). **Schema 1.83.0 frozen.**

### Fixed — CLI-health truth (Lane A)
- **Stats/status ban counts.** `nftban stats`/`status` no longer report `0` for manual + auto-detect bans — they now read the `blacklist_manual` set (the producer key) instead of a non-existent `.temporary` key. GeoBan state in `status` is read from `/etc/nftban/geoban.d/50-ban-*.conf` instead of a phantom `grep "BLOCKED"` that never matched (status no longer shows DISABLED while countries are banned).
- **RBL false-CLEAN.** The RBL monitor no longer reports `CLEAN` on a resolver timeout/error or on `host`-only hosts: real exit-code capture (rc 124 → TIMEOUT, non-zero → ERROR — never CLEAN), a dig/nslookup fallback, a cache-dir fix, a real per-run query cap, and `jq`-built JSON.
- **Health truth.** `nftban health verify` now checks `systemctl is-failed` first, so a *failed* required service/timer is reported as broken instead of passing as “INSTALLATION COMPLETE”; the timer check also flags a failed backing service. `health`/auto-heal target `/usr/lib/systemd/system`.
- **Timer truth.** `nftban_enable_all` no longer auto-enables `nftban-rollback.timer` (the unit explicitly says “do not auto-enable”); `nftban timers` lists the six previously-omitted shipped timers; the watchdog trend hint is gated on real timer state and the orphaned trend collector is wired so adaptive thresholds populate.
- **`set -u` unbound-var class.** Initialized conditionally-assigned locals across `nftban update`-adjacent paths and made the dispatcher case-insensitive; fixes crashes on empty-env / fresh hosts.
- **Stale text / UX.** Removed Fail2Ban mislabels, fixed wrong help/flag hints, hoisted `port --help` above the root gate, dropped a banner on the geoip error path.

### Fixed — log durability / path truth (Lane A)
- **Unbounded logs.** `security-audit.log` and `portscan-events.log` (real writers, previously rotated by no stanza) gain logrotate stanzas + `logs.go` inventory entries (drift-test guarded); `permissions_audit.log` rotated.
- **Stats log path.** `nftban stats` reads `bans.log` (the real writer) instead of the singular `ban.log`; phantom `escalations.log`/`unbans.log` metric reads dropped; reports-registry path/fields/rotation corrected; SSH posture reads `sshd_config.d/` drop-ins.

### Added — systemd geoban-refresh timer (Lane A)
- Ships `nftban-geoban-refresh.{timer,service}` (weekly country-CIDR refresh, distinct from the mmdb `nftban-core-geoip.timer`) in **both** DEB and RPM, with full parity: the canonical systemd install-list, `docs/systemd/UNITS.md` counts, and the generated `%preun`/`prerm` cleanup snippets all updated (auto-enable deferred to a later installer lane; the unit is manageable via `nftban timers`).

### Changed — nft-writer single-authority tightening (AUTH)
- The DDoS-classic penalty-escalation timer write now routes through the daemon IPC (`nft_ipc_add_element`) instead of a direct `nft add element`, so it goes through the single nftables write authority — with the same per-tier expiry preserved and a direct-write fallback gated behind `NFTBAN_EMERGENCY_MODE` (default **off**).
- The `scripts/ci/check-nft-writes.sh` guard scan is widened to `scripts/`, the extensionless `cli/sbin/*` tools, and `internal/` Go (former blind spots); the allowlist is annotated per-entry and the stale `nftban_geoban.sh` entry (0 direct writes) is pruned; positive ban/unban-IPC-route and emergency-default-off assertions added. New in-tree doc `docs/ARCHITECTURE-NFT-POLICY.md`.

### Fixed — stats JSON & manual-count cache truth (F2, F3)
- **F2 — `nftban stats --json` is valid JSON again.** `nftban_stats_top_sources` no longer emits a trailing comma when some source counts are 0 (the awk now emits the separator only between actual objects), which previously broke `stats --json` with `jq: invalid JSON text passed to --argjson`.
- **F3 — manual blacklist counts visible on the cache path, IPv4/IPv6 symmetric.** The unified-stats-cache exporter now emits a `blacklist_manual{ipv4,ipv6,total}` block and the cache-hit dashboard reads + surfaces it (`manual: N` on the Direct Bans line), so manual bans are visible on both cache-hit and cache-miss paths. Existing `.blacklist` cache fields and perm/temp are preserved; the daemon `watchdog.go` half is deferred to a future daemon lane.

### Validation
- **Lane A lab-validated** on lab2 (Ubuntu 24.04, DEB) + lab4 (AlmaLinux 9.8, EL9 RPM): both packages build; the v150 hermetic test suite passes on both OSes; `logrotate -d` + the `logs.go` inventory drift-test are green; live systemd checks confirm geoban-refresh installs-but-stays-disabled, `nftban-rollback.timer` stays `static` after `enable-all`, the watchdog trend populates, and `status` GeoBan goes DISABLED→ACTIVE.
- **AUTH / F2 / F3** are hermetic-tested (nft-writer route + emergency-off; valid-JSON across zero/mixed/all source counts; manual cache-hit/miss + zero-manual + perm/temp-unchanged, all IPv4+IPv6).
- All four PRs merged CI-green (Policy Gates incl. the widened nft-writer guard, Build & Test, Runtime Truth almalinux-9 + ubuntu-24.04, ShellCheck). Ban/stats truth was validated from code + hermetic tests — **no live direct ban/unban and no direct-nft confirmation** (single-writer / IPC discipline).

### Scope / Deferred
- Boundaries held: shell/CI/docs only (the single Go file is the DCE'd log inventory), **daemon byte-identical, schema 1.83.0 frozen**. Deferred to later lanes: the daemon-Go half of the manual-count fix (`watchdog.go`), the installer-Go parity lane (Lane B: `feeds.conf`/`cli/etc` staging, suricata-perms, EL MAC), and the remaining register backlog in `NFTBAN_PENDINGS_AND_BUGS_CURRENT.md`.

---

## [v1.149.0] - 2026-06-05 — operational hardening (whitelist --static + portscan corroboration + urgent bug fixes)

**Codename:** `V149_OPERATIONAL_HARDENING`
**Controlling records:** `NFTBAN_ROADMAP/V1_149_0_OPERATIONAL_HARDENING_SCOPE.md` · `V149_URGENT_BUGS_FOUND.md`
**PRs:** [#762](https://github.com/itcmsgr/nftban/pull/762) (sq `2064d19d`, four specific lanes)

> **Why:** close the 49.x EL10-prep admin auto-ban incident end-to-end, and fix two HIGH bugs found during the work. **Daemon byte-identical to v1.148.0** (zero `cmd/nftband`/`cmd/nftban-core` change). **Schema 1.83.0 frozen.** Shell-only.

### Added
- **Whitelist `--static` (permanent tier).** `nftban whitelist add --static <ip>` writes durable `whitelist.d/99-manual.conf` (no `EXPIRES_AT`) and applies it live via `nftban sync`. `add --ttl <dur>` routes to the existing session writer (`00-session.conf`). `remove --static` clears the durable line + live entry. Help rewritten to document the three tiers (runtime / timed / permanent).
- **Portscan generic-scan corroboration (classic mode only).** New config `PORTSCAN_CLASSIC_GENERIC_CORROBORATE` (+ `_PORTS`). An uncorroborated `generic` detection (non-rapid, single-target, `MIN_PORTS..vertical-1` distinct ports — the bursty/NAT/admin profile) is downgraded to `generic-observe` (log/alert, never banned). Corroborated `generic` (>= the vertical floor) still bans.

### Fixed / Changed
- **Default `whitelist add`** now prints an honest runtime-only warning (no more false "permanent"); it is unchanged behaviorally (live nft set only).
- **BUG-1 — `nftban update` crash on fresh hosts.** `cmd_update.sh` declared `local _curv _latv _cache_file` uninitialized; under `set -u`, a host with no update cache (or no jq) left `_latv` unbound → `nftban update` aborted. Initialized the declaration. Regression test added.
- **BUG-2 — `firewall reload` dropped durable `whitelist.d` entries.** A reload flushed the whitelist/blacklist sets and only re-applied auto-detected system IPs, transiently dropping durable `--static`/manual entries (admin-lockout window). `firewall_reload` now reconciles durable whitelist.d/blacklist.d via `nftban-core sync --quick` (chosen over `nftban sync`, which would recurse into reload). `--static` now survives `firewall reload`.
- **Portscan:** the `10/sec` SYN log-rate was deliberately **not** raised — code review confirmed it is an anti-flood **log** limiter, not a ban threshold (raising it would feed more events → more false bans).

### Not changed (code-verified safe)
- **Suricata** portscan (bans on accumulated IDS-alert score) and **DDoS** classic (12-strike escalation ladder + 2h strike prune + whitelist-skip) are already corroborated — left untouched.

### Validation
- lab2 (Ubuntu 24.04 DEB, candidate built + installed) + lab4 (AlmaLinux 9.8 EL9 RPM): WL-STATIC 28/28, portscan 9/9, BUG-1 4/4; shellcheck `-S warning` clean.
- Full 7-step `--static` lifecycle proven **live** on lab2: add→LIVE; firewall reload→still LIVE; reload x2→LIVE; daemon restart→LIVE; remove→gone + not live; reload→not resurrected.

### Scope / Deferred
- Boundaries held: shell-only, schema 1.83.0 frozen, daemon byte-identical, no MAC/least-priv/audit/SEC-RULEFP/RBL/stats work. The broader backlog (RBL defects, live-host geoip/geoban/stats/timer bugs, V1.90 re-sweep residuals, the full `set -u` unbound-var class) is recorded in `NFTBAN_PENDINGS_AND_BUGS_CURRENT.md` for the v1.150 CLI-health lane.

---

## [v1.148.0] - 2026-06-04 — installer config parity + preservation + reboot-surviving restore disarm

**Codename:** `V148_INSTALL_PARITY_RESTORE_DISARM`
**Controlling records:** `NFTBAN_ROADMAP/V148_INSTALL_PARITY_RESTORE_DISARM_SCOPE.md`
**PRs:** [#760](https://github.com/itcmsgr/nftban/pull/760) installer config parity + restore disarm (sq `6fa1b2ac`)

> **Why:** close the source-vs-package config drift, make operator config durable across updates (never lose local `/etc/nftban/conf.d`), and make CSF-restore actually survive a reboot. **Daemon byte-identical to v1.147.0** — zero `cmd/nftband` / `cmd/nftban-core` change. **Schema 1.83.0 frozen.**

### Added
- **Config preservation (3-way "rpm-conffile" algorithm)** in the Go installer (`internal/installer/payload/idempotency.go::preserveOrStageConfig` + a recursive config walker in `payload.go`): fresh files are seeded, files unmodified from the prior packaged default are updated, and **operator-edited base `.conf` files are preserved** — the new default is delivered as a `.nftban-new` sidecar with a `WARN_CONFIG_LOCAL_PRESERVED` log. Honors `V148_CONFIG_PRESERVATION_CONTRACT` (never lose local config).
- **Restore disarm steps A.6b + A.6c** (`cmd/nftban-installer/restore_deps_csf.go`): CSF-restore now **masks** exactly four NFTBan-owned units (`nftband.service`, `nftband.socket`, `nftban-maintenance.timer`, `nftban-rebuild-recovery.timer`) and **strips the Shape-B include** from the distro `nftables.conf` (`render.DisarmSystemConf`), so the daemon/socket/timer/exporter/boot-include cannot reactivate after restore.
- **Restore contract Amendment 4** (`internal/installer/restore/contract.md` Part VII, §§70-71): authorizes the bounded four-unit restore mask + include-strip; the `G4-RESTORE-EXEC-NO-OUT-OF-TARGET` gate is relaxed from a blanket `ServiceMask` forbid to a structural four-unit allow-list pin (unbounded mask still fails).

### Fixed / Changed
- **Source/RPM/DEB config parity:** the canonical `conf.d` defaults tree now lives under `etc/nftban/conf.d/` and is staged identically by the source-installer and the RPM/DEB packages (`packaging/build_nftban.sh`); `*.conf.local` overrides are never shipped, never written, and never overwritten (operator override layer protected — missing keys fall back to the base default, stale keys ignored, override wins).
- **Restore survives reboot:** `disable`/`stop` of `nftband.service` alone was re-defeated by four reactivation vectors (socket trigger, exporter `RequiredBy`, always-active `nftban-maintenance.timer` self-heal, the Shape-B boot include); `mask` + include-strip close all four. `/etc/nftban/nftables.conf` is never deleted. Restore-disarm is restore-specific only — normal install/update/reinstall keep Shape-B, socket-activation, and the always-active timer design and `unmask` + re-enable normally.

### Validation
- **Restore-then-reboot** proven on lab VM: the four-vector disarm holds — no `ip/ip6 nftban` tables recreated past the socket-activation window.
- Hermetic unit tests: `internal/installer/payload/preserve_v148_test.go` (3-way preserve + `.conf.local` guard), `internal/installer/render/disarm_v148_test.go` (include strip / idempotent / absent-file / preserve-non-nftban / backup), `cmd/nftban-installer/restore_disarm_v148_test.go` (exact four-unit mask bound). PR #760 CI fully green (68 pass / 0 fail).

### Scope / Deferred
- No daemon code change, no schema bump, no MAC expansion, no whitelist-`--static`, no daemon least-privilege, no audit-log.
- Deferred: whitelist `--static` (durable temp/perm semantics); portscan SYN rate-alignment; v1.147-B daemon least-privilege; v1.147-C audit/integrity.

---

## [v1.147.0] - 2026-06-04 — MAC profiles (SELinux + AppArmor)

**Codename:** `V147_MAC_PROFILES`
**Controlling records:** `NFTBAN_ROADMAP/V147_B_PLUS_MAC_IMPL_VALIDATION_RECORD.md` · `V147_EL10_VALIDATION_RECORD.md` · `V147_A_MAC_DOCS_AND_WIKI_VALIDATION.md`
**PRs:** [#758](https://github.com/itcmsgr/nftban/pull/758) MAC profiles + daemon/unit hardening (sq `ca42153c`) · [#757](https://github.com/itcmsgr/nftban/pull/757) superseded

> **Why:** confine the privileged `nftband` daemon as defense-in-depth, and fix the EL SELinux-Enforcing failure where the daemon could not program nftables (`cannot list tables: socket: permission denied`). **Daemon NOT byte-identical to v1.146.0** (two defensive nil-guards). **Schema 1.83.0 frozen; no nftables table/set semantic change.**

### Added
- **SELinux policy module (`nftban`)** for EL: completes the `nftband_t` domain — labels the daemon `nftband_exec_t`, transitions `init_t → nftband_t` (`type_transition` + entrypoint) while keeping `NoNewPrivileges=true` via `process2:nnp_transition` (NNP not relaxed on any host). Ships `.te`/`.if`/`.fc` + a build-compiled `.pp` (refpolicy devel Makefile); `%post` `semodule -i`, `%postun` `semodule -r` (both `selinuxenabled`-guarded).
- **AppArmor profile** for Debian/Ubuntu at `/etc/apparmor.d/usr.lib.nftban.bin.nftband`, shipped in **complain** mode with `flags=(complain attach_disconnected)`. Loaded by DEB `postinst` (`apparmor_parser -r`), removed by `postrm`.
- Operator docs: `docs/security/MAC_PROFILES_SELINUX_APPARMOR.md` + wiki page “MAC Profiles: SELinux and AppArmor”.

### Fixed / Changed
- **EL SELinux Enforcing:** `nftband` now runs confined in `nftband_t` and manages its nftables objects — fixes `cannot list tables: socket: permission denied`.
- **AppArmor `attach_disconnected`:** required because the unit’s private mount namespace (`ProtectSystem=strict` + `ReadWritePaths` + `ProtectHome`) otherwise makes `/run/systemd/notify` a “disconnected path”, breaking `sd_notify` and crash-looping the `Type=notify` unit.
- **Daemon nil-guards** (`daemon_init.go`, `daemon_socket.go`): degrade gracefully (no nil-panic) when a systemd-passed socket fd is mediated to nil under confinement.
- **CI:** RPM-build containers (`build-packages.yml`) and the release build (`release.yml`) now install `selinux-policy-devel` so the `.pp` compiles.

### Validation
- **AppArmor (complain):** Ubuntu 22.04 / 24.04 / 26.04 + Debian 12 / 13 (lab) and real Ubuntu 26.04 — active, confined, `sd_notify READY`, 0 panics, 0 disconnected-path, ban verified.
- **SELinux Enforcing:** EL9 (AlmaLinux 9.7, CentOS Stream 9, Rocky 9.7) and EL10 (CentOS Stream 10, AlmaLinux 10.1, Rocky 10.1) — `nftband_t`, NNP kept, non-permissive, **0 AVC**, ban verified in `blacklist_manual_ipv4`.

### Scope / Deferred
- **EL8 SELinux Enforcing out of scope** (older refpolicy lacks required types).
- Deferred: **v1.147-B** daemon least-privilege; **v1.147-C** audit-log uid/gid/pid + whitelist/immutable verification; `D-V147-REDUCE-NFTBAND-SHELLOUTS-AND-TIGHTEN-MAC-DOMAIN`; whitelist `--static`; portscan rate-alignment.

---

## [v1.146.0] - 2026-06-03 — install / boot / package-lifecycle authority

**Codename:** `V146_INSTALL_BOOT_LIFECYCLE`
**Controlling records:** `NFTBAN_ROADMAP/V146_INSTALL_LIFECYCLE_DECISION_AND_IMPL_PLAN.md` · `V146_BOOT_SUFFICIENCY_GATE2_REBOOT_PROOF_RECORD.md` · `V146_SHAPE_B_IMPL_VALIDATION_RECORD.md` · `V146_PHASE_D_LAB_VALIDATION_RECORD.md`
**PRs:** [#754](https://github.com/itcmsgr/nftban/pull/754) Phase D (sq `31ca2081`) · [#755](https://github.com/itcmsgr/nftban/pull/755) Shape B (sq `b9855cd6`)

> **Why:** the v1.145 SSH-port work exposed an install/boot-lifecycle contradiction in how nftban integrates with the distro `/etc/nftables.conf`. v1.146 fixes the lifecycle authority. **Daemon byte-identical to v1.145.0** (installer/render + packaging only; zero `cmd/nftband`/`cmd/nftban-core` change). **Schema 1.83.0 frozen.**

### Added
- **`NFTBAN_ALLOW_REMOVE_INET_FILTER=1`** — explicit, deterministic, audit-logged opt-in to remove a populated/operator-owned `inet filter` table during install (no interactive prompt; automation-safe).

### Fixed / Changed
- **Phase D — fenced include idempotency:** the nftban include in the distro nftables config is now a fenced begin/end block. `IntegrateSystemConf` self-heals files polluted by the pre-v1.146 accumulation bug (collapses duplicate legacy comments to one block; no write when already canonical). The loose case-sensitive `sed '/nftban/d'` remover is replaced by a fenced+legacy-aware strip in DEB `postrm` (purge **and** the previously-missing `remove` branch) and RPM `%postun`.
- **Phase D — CVE-2025-NFTBAN-001 inet-filter classify-then-act:** empty/default distro skeleton is auto-removed; a populated/operator-owned `inet filter` is **never silently deleted** — DEB fresh install **refuses** (`exit 1` + runbook), RPM fresh install **skips activation** (`exit 0` + verbatim runbook, since rpm `%post` cannot cleanly abort); upgrades warn and continue. RPM `%post` gains the inet-filter guard it previously lacked (DEB/RPM symmetry).
- **Shape B — distro skeleton neutralization (reboot-proven required):** nftban **keeps** the fenced include (the daemon recreates set *structure* via netlink but does **not** load the rendered `ssh_ports`/`@ssh_ports` rate-limit ruleset — only `nft -f` via the include does), and additionally comments the bare `flush ruleset` (so `systemctl reload nftables.service` can no longer wipe daemon-managed `ip/ip6 nftban` runtime tables) and removes the empty default `table inet filter` skeleton. Reboot-proven on Debian 12 + Ubuntu 24.04 + CentOS Stream 9 (SELinux Enforcing): `ssh_ports` + the rate-limit rule are restored on every reboot; reload-safe; operator content preserved. (Shape A — removing the include — was tested and **rejected**: it silently dropped v1.145 SSH protection every reboot, and on EL Enforcing left no nftban tables at all.)

### Deferred
- **v1.147 security hardening** (147-A MAC: AppArmor + SELinux `.te`/`.if`/`.fc` incl. the EL daemon-netlink policy → 147-C audit/integrity → 147-B daemon least-privilege) — scoped `SCOPE_READY` (`NFTBAN_ROADMAP/V147_SECURITY_HARDENING_SCOPE.md`); implementation starts only after v1.146 ships. **No SELinux policy work in v1.146.**

---

## [v1.145.0] - 2026-06-03 — SSH-port lifecycle / multi-port lockout fix

**Codename:** `V145_SSH_PORT_LIFECYCLE`
**Controlling records:** `NFTBAN_ROADMAP/V145_B2_G_MULTI_DISTRO_MATRIX_VALIDATION.md` · `V145_SHELL_RENDER_PORTSD_UNION_FIX_VALIDATION.md` · `V145_PR750_OSV_EXACT_ID_TRIAGE.md`
**PRs:** [#745](https://github.com/itcmsgr/nftban/pull/745) PR-A (sq `75d8ea48`) · [#746](https://github.com/itcmsgr/nftban/pull/746) PR-B (sq `1b8305e8`) · [#747](https://github.com/itcmsgr/nftban/pull/747) PR-C2 (sq `1d65c6ae`) · [#749](https://github.com/itcmsgr/nftban/pull/749) PR-B2 (sq `65a608d1`) · [#751](https://github.com/itcmsgr/nftban/pull/751) PR-G (sq `b0ba2387`) · [#752](https://github.com/itcmsgr/nftban/pull/752) OSV maint (sq `a42822f5`) · [#750](https://github.com/itcmsgr/nftban/pull/750) RPM changelog (sq `2d91677e`)

> **Why:** completes the set-driven SSH brute-force rate-limit (`tcp dport @ssh_ports ct count`) so multi-port / ListenAddress hosts can never lose firewall coverage on a secondary SSH port. **Daemon is NOT byte-identical** — this release touches `.go` (nftbackend port-set routing, installer detect/render, daemon writable-set) and `go.mod` (x/net + toolchain 1.25.11), ending the six-release zero-Go chain `v1.140.0 → v1.144.0` by design. **Schema 1.83.0 frozen** — `ssh_ports` is one required internal set inside the existing `ip`/`ip6` tables (not a new table; no external JSON schema bump). Validated **10/10** across the DEB+RPM distro matrix.

### Fixed

- **Multi-port SSH brute-force lockout (SECURITY, PR-B2 [#749]).** On multi-port / ListenAddress hosts the firewall could drop a live SSH listener on a secondary port. Root causes, all closed: (1) the daemon IPC rejected `ssh_ports` (`knownNFTBanSets` now includes it); (2) `Backend.AddElement`/`DeleteElement` treated port-set values as IPs (`invalid IP or CIDR: <port>`) — now routed via `isPortSet()` to `AddPortElements`/`DeletePortElements`; (3) the installer rendered only the primary SSH port — now renders the full detected union (`DetectSSHPortsForRender`); (4) the shell `_firewall_substitute_placeholders` collapsed `firewall reload`/`rebuild` to primary-only (proven kernel regression `tcp_ports_in [22,80,443,55000] → [22,80,443]`) — now substitutes the live union into `__SSH_PORT__`; (5) `ports.d/00-ssh.conf` held only the primary — `PersistSSHPortsUnion` now persists the union.
- **`report_port` misclassification (PR-G [#751]).** The set-rule scanner reported the set-driven `@ssh_ports ct count … drop` rule as `BLOCKED/MISCONFIG`; it now skips `ct count over` / `limit rate` like the direct-rule scanner.

### Added

- **Set-driven SSH brute-force rate-limit** (PR-A [#745]) — `ssh_ports` set + `tcp dport @ssh_ports ct count` rule, replacing the rendered `__SSH_PORT__` literal.
- **Runtime SSH-port union detection + parity** (PR-B [#746]) — ss listeners + sshd_config Port + ListenAddress + state + conf.local; `tcp_ports_in`/`ssh_ports` kept in parity.
- **Apply-path hardening** (PR-C2 [#747]) — live nft-table re-probe + verified state commits.
- **Systemic alignment + tests** (PR-G [#751]) — `nftban port` help (4→5 managed port sets + ssh_ports semantics: internal, TCP-only, SSH-management-plane; Pure-FTPd/FTP/FTPS use `tcp_ports_in` only); four pre-existing v1.145 shell guards wired into CI + new invariant/negative tests; README/wiki ssh_ports documentation.

### Security

- **OSV gate repaired** (Maintenance [#752]) — advisories published mid-release: `golang.org/x/net 0.52.0 → 0.55.0` (GO-2026-5025…5030) and go directive `1.25.0 → 1.25.11` (GO-2026-5037/5038/5039, stdlib). `go mod tidy` pulled `golang.org/x/sys 0.44.0 → 0.45.0`. `osv-scanner v2.3.3` exits 0. go.mod/go.sum-only; kept separate and auditable (not bundled into any feature PR).

### Changed

- **RPM `%changelog` weekday fix** (Packaging [#750]) — `Mon Mar 24 2026` (a Tuesday) → `Tue`; stricter `rpm` rejected the bogus date.

### Validation

- 10/10 multi-distro lab matrix: DEB Ubuntu 22.04/24.04/26.04 + Debian 11/12/13, RPM AlmaLinux 8/9 + CentOS Stream 9 + Rocky 9 — each with sshd on 22+2222+55000: detector union, all three ports in ip/ip6 `tcp_ports_in` + `ssh_ports`, `firewall reload` preserves all SSH ports, no UDP contamination, SSH reachable. Read-only fleet check: production EL hosts run SELinux Disabled (unaffected) and already run multi-port SSH (srv2 2222+55000, dns2 22+2222).

### Deferred to v1.146 (scoped, not started)

- nftables.service / `/etc/nftables.conf` integration contradiction, postrm idempotency, boot authority, fresh-install inet-filter policy, DEB zstd/dependency runbook, per-EL-major RPM build (`V146_NFTABLES_SERVICE_INSTALL_LIFECYCLE_RECHECK_SCOPE.md`).
- EL SELinux Enforcing daemon-netlink **policy module** — not polkit (`V146_EL_SELINUX_DAEMON_NETLINK_POLICY_SCOPE.md`).
- Installer SSH_CLIENT-aware primary selection in the postinst context.

## [v1.144.0] - 2026-06-01 — Doc/UX drift cleanup

**Codename:** `V1_144_0_DOC_UX_DRIFT`
**Controlling plan:** `NFTBAN_ROADMAP/V1_144_0_DOC_UX_DRIFT_PLAN.md` (amended turn 2 to fold in D-UXV-13/14/15)
**PRs:** [#740](https://github.com/itcmsgr/nftban/pull/740) PR-A (sq `36c1c1b0`) · [#741](https://github.com/itcmsgr/nftban/pull/741) PR-B (sq `83e7340a`) · [#742](https://github.com/itcmsgr/nftban/pull/742) PR-C (sq `43a79026`) · [#743](https://github.com/itcmsgr/nftban/pull/743) PR-D (sq `e76cb49b`)

> **Why:** v1.144.0 is a cleanup release on top of v1.143.1 closing seven converging doc/UX drift defects in four coupled PRs. **Daemon byte-identical to v1.143.1** — zero `.go` touched. **The six-release zero-Go chain `v1.140.0 → v1.141.0 → v1.142.0 → v1.143.0 → v1.143.1 → v1.144.0` holds.** Schema 1.83.0 frozen.

### Closed in this release

- **D-NFTBAN-GUI-DOC-DRIFT** (PR-A) — `nftban gui` was advertised by `nftban help --all` despite no `cmd_gui.sh` ever existing post-v1.139.2 retirement. Source-side fix in `commands.registry.yml` drops the `gui:` entry + `- gui` from `missing_json:` + adjusts counters; `nftban gui` now returns "Unknown command" rc=1 via the dispatcher catch-all (cleanly, via the standard typo-suggestion path).
- **FHS-SPEC-GUI-MENTION** (PR-A) — `build/fhs-spec.yaml:425` "TLS certificates for GUI/API" → "TLS certificates for API"; `:1000-1015` removed dormant `gui:` feature directory block (`condition: gui_enabled` was never set by any installer). Regenerated `cli/lib/nftban/core/nftban_fhs_spec.sh` — body SHA256 changes from `4e618bd7…1d1f242` to `5cc86594…6906971` per operator `SELECT_V1_144_FHS_BODY_CHAIN_BREAK = accept` (intentional 5-release chain break; the identity was a side-effect, not a contract).
- **UX-C2** (PR-B) — wall-of-text validation errors. New `_v144_error_with_hint(err, hint, runhelp, rc=1)` helper in `lib/cmd_common.sh` emits ≤3 stderr lines. Migrated 6 cmd_*.sh catch-all parse-error paths to use it: `cmd_config.sh`, `cmd_status.sh`, `cmd_test.sh`, `cmd_whitelist_system.sh`, `cmd_update.sh`, `cmd_feeds.sh`. The full `show_usage` rendering still fires on explicit `--help` paths — only error paths migrated. Top-six target was code-truth-reconciled: cmd_test + cmd_whitelist_system replaced cmd_ban + cmd_firewall (which did not have the show_usage-after-ERROR antipattern).
- **UX-C5** (PR-B) — `--dry-run` parity. Operator chose the `document` shape: `cmd_update.sh` help block now states `--dry-run is NOT supported on nftban update` (asymmetric vs `nftban ban --dry-run` which IS supported; update mutations span package-manager transactions where dry-run cannot be safely simulated end-to-end) and points to `nftban update check`/`list`/`status` as preview alternatives.
- **D-UXV-14** (PR-C) — `cmd_connector.sh:234` "Use: nftban connector edit $name" hint dropped. Connector dispatch has no `edit` arm; old hint hit "Unknown command: edit" rc=1. Replaced with canonical idempotent `nftban connector show $name` (inspect) + `nftban connector remove $name && nftban connector add $name [...]` (recreate).
- **D-UXV-15** (PR-C) — `cmd_port.sh` four broken reload-hint sites (`:260`, `:558`, `:689`, `:693`) all corrected to `nftban firewall reload`. Pre-PR-C: `:260/:689/:693` emitted `nftban reload` (NOT a real command — no `cmd_reload.sh`, no `reload` alias case, absent from `_nftban_canonical_commands()`) and `:558` emitted `nftban port reload` (port dispatch has no `reload` arm). Canonical is `nftban firewall reload` (`cmd_firewall.sh:1490 firewall_reload()` — atomic ruleset rebuild + NFTBan schema re-apply + whitelist sync). **The original 2026-06-01 audit's proposed migration to `nftban reload` was challenge-verified to also be broken; this PR ships the corrected spec.**
- **D-UXV-13** (PR-D) — new runtime-hint reachability CI guard (class-killer). Reverse-direction guard for the v130 doctest pair: every echo/printf `"nftban X [Y]"` literal in source must resolve to a reachable command. Includes `cli_runtime_hint_reachability_v144_test.sh` (10/10), `cli_help_block_reachability_v144_test.sh` (8/8), `v144_runtime_hint_allowlist.tsv` (4 entries; every row requires explicit `reason` field), and 2 new CI steps in `.github/workflows/ci-architecture.yml`. HARD pass criteria include T3-3/4/5: WOULD-HAVE-CAUGHT all three historical broken hints + the audit's wrong replacement. Legacy parser-heuristic drift (12 sites) is REPORTED but not CI-blocking — tracked as v1.145.x sweep candidates.

### Coupling constraint enforced

PR-C and PR-D landed together per operator `SELECT_V1_144_PR_C_PR_D_COUPLING = both-must-land`. The audit-was-wrong episode is direct evidence that the class-killer guard is required to keep this defect class from recurring.

### Daemon byte-identity preserved

- Zero `.go` files touched across all four implementation PRs (PR-A YAML+regen, PR-B shell+helper+tests, PR-C shell+tests, PR-D test+CI-step).
- `cmd/nftban-core` + `cmd/nftband` expected SHA256-identical to v1.143.1 build.
- Six-release zero-Go chain: `v1.140.0 → v1.141.0 → v1.142.0 → v1.143.0 → v1.143.1 → v1.144.0`.
- **FHS body SHA256 chain BREAKS at v1.144.0** by design: `4e618bd7…1d1f242` (v1.140.0..v1.143.1) → `5cc86594…6906971` (v1.144.0).

### Cumulative test evidence

**306 PASS / 0 FAIL** across 23 hermetic suites at PR-D merge time.

### CI evidence

- PR #740: 52 SUCCESS / 4 SKIPPED / 0 FAIL
- PR #741: 55/2/0 (after 1× Docker Hub image-pull flake rerun — 4th class occurrence, same as v1.139.1 + v1.143.1; zero code change)
- PR #742: 52/2/0
- PR #743: 52/2/0
- Post-merge main CI on `e76cb49b`: **25 SUCCESS / 1 SKIPPED / 1 FAIL** — the 1 failure is the documented `Dependabot Updates` infrastructure workflow (event=`dynamic`, auto-bumping `github/codeql-action`); same noise pattern as v1.141.0 + v1.143.0 publish windows; NOT a release-CI failure.

### Operator gates honored

```
OPEN_V1_144_0_DOC_UX_DRIFT_PLAN = GO_PLAN_ONLY
AMEND_V1_144_0_DOC_UX_DRIFT_PLAN_WITH_D_UXV_13_14_15 = GO_PLAN_ONLY
SELECT_V1_144_GUI_DRIFT_SHAPE = drop
SELECT_V1_144_UX_C2_BATCH = top-six-files-only
SELECT_V1_144_UX_C5_SHAPE = document
SELECT_V1_144_FHS_BODY_CHAIN_BREAK = accept
SELECT_V1_144_PR_C_PR_D_COUPLING = both-must-land
SELECT_V1_144_D_UXV_14_15_VEHICLE = include-in-v1.144.0-doc-UX-drift-train
SELECT_V1_144_D_UXV_13_GUARD = include-as-4th-sub-PR-in-v1.144.0-doc-UX-drift-train
OPEN_V1_144_0_DOC_UX_DRIFT_IMPL = GO_IMPLEMENTATION_ONLY
MERGE_PR_740_WHEN_CI_GREEN = GO
MERGE_PR_741_WHEN_CI_GREEN = GO
MERGE_PR_742_AND_743_WHEN_CI_GREEN = GO
VERIFY_V1_144_0_MAIN_CI_AFTER_PR_A_B_C_D = GO_READ_ONLY  (PASS)
OPEN_V1_144_0_RELEASE_PREP = GO_RELEASE_PREP
```

### Post-publish READ-ONLY verification (run after tag publishes)

```bash
# 1. Verify SHA256 of every asset
sha256sum -c SHA256SUMS

# 2. Verify FHS spec body SHA256 (NEW value for v1.144.0)
tail -n +31 /usr/lib/nftban/core/nftban_fhs_spec.sh | sha256sum
# Expected: 5cc865943fe21c31499739216e25582142e155fecbd20a8adba0cb62c6906971

# 3. Confirm `nftban gui` returns Unknown command (D-NFTBAN-GUI-DOC-DRIFT)
nftban gui; echo "rc=$?"
# Expected: rc=1 with "ERROR: Unknown command 'gui'" + typo suggestion

# 4. Confirm `nftban connector add X` shows the canonical recreate hint when X exists
# (D-UXV-14 — only after at least one connector is configured)

# 5. Confirm `nftban firewall reload` works (D-UXV-15 canonical target)
nftban firewall reload --help; echo "rc=$?"   # Expected: rc=0 with usage

# 6. Confirm `nftban reload` returns Unknown command (proves the broken hint is dead)
nftban reload; echo "rc=$?"   # Expected: rc=1 "Unknown command 'reload'"

# 7. Daemon byte-identity check vs v1.143.1
sha256sum /usr/sbin/nftband   # Expected: same as v1.143.1
```

---

## [v1.143.1] - 2026-06-01 — RC-AUDIT-2 Phase 3 — exporter SIGTERM race fixes

**Codename:** `V1_143_1_EXPORTER_EXIT2_PHASE_3`
**Controlling scope:** `NFTBAN_ROADMAP/V1_143_EXPORTER_EXIT2_PHASE_3_SCOPE.md`
**PR:** [#738](https://github.com/itcmsgr/nftban/pull/738) (sq `5d72a9af`)

> **Why:** v1.143.1 is a focused patch release on top of v1.143.0. It closes **two new ERR-trap-pinpointed exporter SIGTERM (rc=143) race sites** surfaced during the v1.142.0 fleet rollout — both pinpointed by the v1.136 ERR trap (which is doing exactly what it was designed for: every Phase-3 pinpoint is a victory for the trap). **Daemon byte-identical to v1.143.0** (zero `.go` touched). **Schema 1.83.0 frozen.** Both fixes mirror the v1.136 Phase 2 surgical pattern at `collect.sh:642` (`set_counts.json`).

### Site A — botguard legacy-kernel jq pipeline (srv1 CentOS Stream 10)

Pre-v1.143.1 `cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh:244` ran six back-to-back `echo "$counts_json" | jq -r '…'` pipelines for `bg_{suspect,pending,allow,grey,ban,emergency}` in the legacy-kernel `else`-branch. Each pipeline opened a bash subshell that could die mid-pipeline if systemd timer fired SIGTERM. The existing post-loop numeric-validity gate caught jq returning empty / non-numeric but did NOT catch SIGTERM killing the bash subshell.

- **Fix:** validity gate `if echo "$counts_json" | jq -e '.botguard'` ONCE before reading the six counters; each per-call jq adds `2>/dev/null) || bg_X=0` belt-and-suspenders. The locals initialized to 0 at line 234 stay safe if the validity gate fails OR any individual jq is SIGTERM-killed.

### Site B — systemctl-show ActiveEnterTimestamp (ub2604 Ubuntu 26.04 LTS)

Pre-v1.143.1 `collect.sh:89` was `start_time=$(systemctl show nftband.service -p ActiveEnterTimestamp --value 2>/dev/null || echo "")`. The `|| echo ""` fallback only triggers on non-zero exit; SIGTERM mid-`systemctl show` kills the bash subshell BEFORE `||` can be evaluated — the failure is process-termination, not non-zero exit. systemd dbus latency can take 200-500 ms on a busy host.

- **Fix:** wrap with `timeout 2s` (~40× p99 healthy systemd-show latency). If `systemctl` exceeds the bound, `timeout` returns 124, `||` fires, `start_time` stays empty via the safe-default initialization.

### Tests — `cli_exporter_exit2_phase_3_test.sh` (37 PASS / 0 FAIL)

Stubbed-callable mirror pattern (same shape as v1.142 PR-FS + v1.143 PR-A/B tests). Site A driven by `NF_COUNTS_JSON` env; Site B driven by a **PATH-shadow `systemctl` stub** — NOT a bash function override, because `timeout` spawns via `execvp()` and would not see a function override.

T2-B3 proves the 2s bound actually fires: a 4-second `systemctl`-sleep stub is killed at ~2 s. Observed elapsed = **2011ms** (asserted < 3500ms) — confirming the bound is real (vs the false-positive 15ms I caught while iterating the test, before switching from bash-function to PATH-shadow stub).

T-DRIFT asserts: both `v1.143.1 EXPORTER-PHASE-3 (Site A/B)` markers present in the live exporter; Site A `.botguard` validity gate present; Site A `|| bg_suspect=0` belt-suspenders present; Site B `timeout 2s systemctl show` bound present; **v1.136 Phase 2 `:642` marker still present (regression guard — the prior fix was NOT disturbed)**.

### Five-release zero-Go chain preserved

```
v1.140.0 (Ubuntu 26 Tier-0) → v1.141.0 (CLI/status/data-truth)
                          → v1.142.0 (FS parser + UX-C6)
                          → v1.143.0 (RC-AUDIT-2 Phase 2)
                          → v1.143.1 (RC-AUDIT-2 Phase 3 — exporter SIGTERM)
```

`cmd/nftban-core` + `cmd/nftband` daemon binaries SHA256-identical to v1.140.0 ship across all five releases. `cli/lib/nftban/core/nftban_fhs_spec.sh` body SHA256 `4e618bd7d4ea379496f6052d3215ce7602e9001ea66f6948c1952c8111d1f242` unchanged across the same chain.

### Cumulative test evidence at PR-Phase-3 merge time

**253 PASS / 0 FAIL** across 18 hermetic suites:

| Suite | Result |
|---|---|
| **NEW: `cli_exporter_exit2_phase_3_test.sh`** | **37 PASS / 0 FAIL** |
| v1.143 PR-A `cli_fs3_mutation_v143_test` | 28/0 |
| v1.143 PR-B `cli_fs3_da_v143_test` | 21/0 |
| v1.142 PR-FS `cli_feeds_select_input_contract` | 23/0 |
| v1.142 PR-UX-C6 `cli_sudo_hint_v142` | 19/0 |
| v1.141 PR-A regressions (4 suites) | 76/0/4-SKIP |
| v1.141 PR-B regressions (4 suites) | 18/0 |
| v1.141 PR-C regressions (4 suites) | 21/0 |
| v1.139.2 `rollback_help_guard_v1_139_2_test` | 10/0 |

### Operator authorities honored

- `OPEN_V1_143_EXPORTER_PHASE_3_IMPL = GO_IMPLEMENTATION_ONLY` (2026-06-01)
- `SELECT_V1_143_EXPORTER_PHASE_3_VEHICLE = v1.143.1`
- `SELECT_V1_143_EXPORTER_PHASE_3_SITE_A = single-validity-gate-plus-belt-and-suspenders`
- `SELECT_V1_143_EXPORTER_PHASE_3_SITE_B = bounded-timeout`
- `SELECT_V1_143_EXPORTER_PHASE_3_TIMEOUT_SECONDS = 2`

### Non-goals locked v1.143.1-wide

- **0 `.go` files**. Daemon byte-identical to v1.143.0.
- **0 `internal/`, `cmd/`, `build/`, `packaging/`, `install/`, `systemd/`, `schema/`, `docker/`, `.github/`, `fhs-spec.yaml` (body)** changes.
- **Schema 1.83.0 frozen.** Zero metrics labels. Zero portal API change.
- **0 ERR-trap removal** — the trap is doing what it was designed for.
- **0 blanket `2>/dev/null` broadening** — only the specific per-jq / per-systemctl pipes get the belt-and-suspenders.
- **0 `set -Eeuo pipefail` weakening.**
- **0 exporter auxiliary-classification change.**
- **0 v1.136 Phase 2 `:642` refactor** — T-DRIFT regression guard.
- **0 CSF / takeover / uninstall-restore / INST-CVE-PARITY work.**
- **0 broad install/update lifecycle refactor.**
- **0 RBL batch / 0 heuristic batch / 0 fleet rollout debt** (D-NFTBAN-GUI-DOC-DRIFT / D-INSTALL-TIMER-RELOAD all targeted at v1.144+).

### Post-publish verification path (separately gated, READ-ONLY)

Once v1.143.1 publishes, operator may run on srv1 + ub2604:

```bash
journalctl -u nftban-unified-exporter -n 200 --no-pager | grep -cE 'aborted rc=143'
```

Expect 0 in the next 24-48h window if the fix landed correctly. If a NEW ERR-trap pinpoint surfaces at a different file:line, that's `D-EXPORTER-EXIT2-PHASE-4` territory — a separate future lane, NOT a v1.143.1 patch.

### Release-prep envelope (this commit)

Standard 4 files only: `VERSION` (1.143.0 → 1.143.1), `STATUS.md` (banner + lane summary), `CHANGELOG.md` (this entry), `cli/lib/nftban/core/nftban_fhs_spec.sh` (header `meta:version` 1.143.0 → 1.143.1 ONLY; FHS body byte-identical, line 31..end SHA256 `4e618bd7d4ea379496f6052d3215ce7602e9001ea66f6948c1952c8111d1f242` unchanged from v1.141.0 + v1.142.0 + v1.143.0). No host contact during release-prep construction. No tag in this PR; tag follows on the release-prep squash after merge per `TAG_AND_PUBLISH_V1_143_1`.

---

## [v1.143.0] - 2026-05-29 — RC-AUDIT-2 Phase 2 cleanup

**Codename:** `V1_143_0_RC_AUDIT_2_PHASE2_CLEANUP`
**Controlling plan:** `NFTBAN_ROADMAP/V1_143_0_PLAN.md`
**PRs:** [#735](https://github.com/itcmsgr/nftban/pull/735) (PR-A FS3-MUTATION, sq `b8887e30`) + [#736](https://github.com/itcmsgr/nftban/pull/736) (PR-B FS3-DA, sq `cc587c24`)
**Audit linkage:** `NFTBAN_ROADMAP/V1_142_RC_AUDIT_2_PUNCHLIST.md` (Phase 1 audit-only filed in v1.142.0) + `NFTBAN_ROADMAP/V1_142_LAB4_UPDATE_LOG_SAFETY_AUDIT.md` R-PERM-1 (closed by PR-B)

> **Why:** v1.143.0 implements the FS3-class loop+success / swallowed-rc cleanup recommended by the v1.142.0 RC-AUDIT-2 Phase 1 punchlist §4-§5. Two batches ship: **FS3-MUTATION** (5 functions on kernel/firewall mutation paths) and **FS3-DA** (2 functions on DirectAdmin + permissions paths, the latter closing the lab4 v1.142 update-log audit's R-PERM-1 finding). **CSF excluded** in any form per operator hard exclusion. **Install/update boundary locked to permission-enforce-only** — this release includes the shell-side producer rc-truth fix for `nftban_permissions_cmd_enforce` but does NOT touch the installer-side consumer (`cmd/nftban-installer/phases.go:571-575`), packaging scriptlets, systemd-tmpfiles policy, session-whitelist sequencing, or `install_state` schema. **Daemon byte-identical to v1.142.0** (zero `.go` touched across both PRs). **Schema 1.83.0 frozen.**

### PR-A — FS3-MUTATION rc-swallow paths ([#735](https://github.com/itcmsgr/nftban/pull/735), sq `b8887e30`)

Five FS3-class fixes — same fix shape as v1.142 PR-FS `nftban_feeds_select`. Per-iteration rc capture into a `failed=()` accumulator, `⚠️` stderr message when non-empty, success marker only on full success, `return $rc` instead of unconditional `return 0`.

- `cmd_feeds.sh::nftban_cmd_feeds` (`feeds enable <category>` arm) — `✅ Enabled N feed(s)` success symbol on partial failure replaced with `⚠️ Enabled N feed(s); M failed: <list>` to STDERR + explicit `return 1`. ✅ Successfully only on full success.
- `cmd_port.sh::nftban_port_allow_add` — IPC `access_allow` failure path captures `_v143_rc=1`; final `return $_v143_rc` replaces `return 0`. Config-side write already succeeded; rc now signals the kernel-side mismatch.
- `cmd_port.sh::nftban_port_allow_remove` — Same fix shape on the IPC `access_revoke` failure path.
- `cmd_port.sh::nftban_port_allow_flush` — Per-set IPC loop with `_v143_failed=()` accumulator; on non-empty: `⚠ Config cleared but N kernel set(s) failed to flush: …` to STDERR + `return $_v143_rc`. ✅ All flushed only on full success.
- `cmd_metrics.sh::nftban_metrics_enable` — `_set_metrics_backend` rc captured via `if ! _set_metrics_backend …; then return 1; fi`. Prometheus Metrics Enabled Successfully marker only when config-write succeeded.

New test: `cli_fs3_mutation_v143_test.sh` (28 PASS / 0 FAIL). T-DRIFT row asserts five `v1.143 PR-A (FS3-MUTATION)` markers exist in the live `cmd_*.sh` files.

### PR-B — FS3-DA rc-swallow paths ([#736](https://github.com/itcmsgr/nftban/pull/736), sq `cc587c24`)

Two FS3-class fixes — DirectAdmin licensing-critical path + permissions wrapper rc-truth contract lock.

- `cmd_port.sh::nftban_port_allow_directadmin` (CloudFlare arm + final return) — `nftban trust enable CLOUDFLARE && nftban trust update` rc captured into `_v143_da_rc`. Failure printed to STDERR with `⚠️ Failed to enable CloudFlare whitelist / DirectAdmin licensing REQUIRES this — operator action required / Re-run manually: …` Final `return $_v143_da_rc` replaces unconditional `return 0` (licensing-critical failure was previously silent to rc).
- `cmd_permissions.sh::nftban_permissions_cmd_enforce` (wrapper rc-truth lock) — The wrapper already returned `$result` truthfully (that's what produced the lab4 v1.142 installer's `permissions enforce failed (exit 1) — non-fatal` line at `cmd/nftban-installer/phases.go:573`), but the `❌` failure block went to STDOUT with no actionable advice. Now the failure block (❌ + log location + re-check + re-run advice) goes to STDERR per the v1.141 PR-B E1 contract. rc propagation unchanged (already correct). Contract LOCKED by the new test so a future refactor cannot regress it. **Installer-side consumer at `phases.go:571-575` intentionally UNCHANGED** per operator's `SELECT_V1_143_INSTALL_UPDATE_SCOPE = permission-enforce-only`.

New test: `cli_fs3_da_v143_test.sh` (21 PASS / 0 FAIL). T-DRIFT row asserts three `v1.143 PR-B (FS3-DA)` markers exist in the live `cmd_*.sh` files (cmd_port=2, cmd_permissions=1).

### lab4 update-log audit closure (R-PERM-1)

The 2026-05-29 lab4 v1.139.1 → v1.142.0 update-log safety audit (`V1_142_LAB4_UPDATE_LOG_SAFETY_AUDIT.md`) classified `permissions enforce failed (exit 1) — non-fatal` as **WARN / BUG-CANDIDATE** aligned with the RC-AUDIT-2 FS3-DA batch. PR-B (a) locks the shell-side wrapper rc-truth contract by test, and (b) improves the failure UX so an operator reading the swallowed `non-fatal` line gets the actionable advice the installer log already had. The lab4 update path itself was classified PASS (COMMITTED, 16/16 assertions, 19 s); R-DOC-1 (operator-facing `UPDATE_SAFETY_MODEL.md` note) deliberately deferred from this release.

### Test evidence — cumulative at PR-B merge time

**216 PASS / 0 FAIL** across 17 hermetic suites:

| Suite | Result |
|---|---|
| PR-A: `cli_fs3_mutation_v143_test.sh` | 28 PASS / 0 FAIL |
| PR-B: `cli_fs3_da_v143_test.sh` | 21 PASS / 0 FAIL |
| v1.142 PR-FS `cli_feeds_select_input_contract` | 23 PASS / 0 FAIL |
| v1.142 PR-UX-C6 `cli_sudo_hint_v142` | 19 PASS / 0 FAIL |
| v1.141 PR-A regressions (4 suites) | 76 PASS / 0 FAIL / 4 SKIP |
| v1.141 PR-B regressions (4 suites) | 18 PASS / 0 FAIL |
| v1.141 PR-C regressions (4 suites) | 21 PASS / 0 FAIL |
| v1.139.2 `rollback_help_guard_v1_139_2_test` | 10 PASS / 0 FAIL |

### Four-release zero-Go chain

v1.143.0 continues the **four consecutive releases without `.go` touched** chain:

```
v1.140.0 (Ubuntu 26 Tier-0) → v1.141.0 (CLI/status/data-truth)
                          → v1.142.0 (FS parser + UX-C6)
                          → v1.143.0 (RC-AUDIT-2 Phase 2)
```

`cmd/nftban-core` + `cmd/nftband` daemon binaries SHA256-identical to v1.140.0 ship across all four releases. `cli/lib/nftban/core/nftban_fhs_spec.sh` body SHA256 `4e618bd7d4ea379496f6052d3215ce7602e9001ea66f6948c1952c8111d1f242` unchanged across the same chain.

### Non-goals locked v1.143-wide

- **0 `.go` files** across PR-A + PR-B. Daemon byte-identical to v1.142.0.
- **0 `internal/`, `cmd/`, `build/`, `packaging/`, `install/`, `systemd/`, `schema/`, `docker/`, `.github/`, `fhs-spec.yaml` (body)** changes.
- **Schema 1.83.0 frozen.** Zero metrics labels. Zero portal API change. Zero Go-installer change.
- **0 CSF / takeover / uninstall-restore / INST-CVE-PARITY work** — operator hard exclusion.
- **0 broad install/update lifecycle refactor** — only `nftban_permissions_cmd_enforce` shell-side producer rc-truth lock + actionable stderr UX. Installer Go consumer at `phases.go:571-575` unchanged. Package-manager / RPM-DEB-scriptlet / systemd-tmpfiles policy / unsafe-path-transition / session-whitelist-sequencing / `install_state`-schema all untouched.
- **0 RBL batch** — deferred to v1.144+.
- **0 HEURISTIC batch** — audit-doc-only; rolled into v1.144 planning instead of inline v1.143.
- **0 v1.144 work** (module-attribution, detection-coverage, SCHEMA-UNFREEZE fork, metrics expansion).

### Release-prep envelope (this commit)

Standard 4 files only: `VERSION` (1.142.0 → 1.143.0), `STATUS.md` (banner + lane summary), `CHANGELOG.md` (this entry), `cli/lib/nftban/core/nftban_fhs_spec.sh` (header `meta:version` 1.142.0 → 1.143.0 ONLY; FHS body byte-identical, line 31..end SHA256 `4e618bd7d4ea379496f6052d3215ce7602e9001ea66f6948c1952c8111d1f242` unchanged from v1.141.0 + v1.142.0). No host contact during release-prep construction. No tag in this PR; tag follows on the release-prep squash after merge per `TAG_AND_PUBLISH_V1_143_0`.

---

## [v1.142.0] - 2026-05-29 — Cleanup release

**Codename:** `V1_142_0_CLEANUP`
**Controlling plan:** `NFTBAN_ROADMAP/V1_142_0_CLEANUP_PLAN.md`
**PRs:** [#731](https://github.com/itcmsgr/nftban/pull/731) (PR-FS, sq `9d406a0f`) + [#732](https://github.com/itcmsgr/nftban/pull/732) (PR-UX-C6, sq `7fc48f4b`)
**Audit deliverable:** `NFTBAN_ROADMAP/V1_142_RC_AUDIT_2_PUNCHLIST.md` (Phase 1, audit-only, no implementation in v1.142)

> **Why:** v1.142.0 is the disciplined cleanup release on top of v1.141.0. It closes the highest-signal `nftban feeds select` parser cluster (BUG-FS1..FS5, live-reproduced on a v1.140.0 Ubuntu 26 host), adds inline sudo / root-shell guidance to the existing privilege-check helpers, and files the RC-AUDIT-2 Phase 1 punchlist (audit-only — Phase 2 implementation deferred to v1.143.0 per the punchlist's own recommendation). **Daemon byte-identical to v1.141.0** (zero `.go` touched across both PRs; shell + test only). **Schema 1.83.0 frozen.** Zero new metric names, zero portal API change, zero `build/fhs-spec.yaml` body change.

### PR-FS — `nftban feeds select` parser BUG-FS1..FS5 ([#731](https://github.com/itcmsgr/nftban/pull/731), sq `9d406a0f`)

Live-reproduced on `ubuntu-4gb-fsn1-1` v1.140.0 (operator session 2026-05-28): operator input `3 6 11 14 5 3` produced `ERROR + ✅ Done + rc=0`. Four converging defects + a test contract.

- **BUG-FS1 — comma OR space separators**: `cmd_feeds.sh:212` pre-v1.142 `IFS=',' read -ra parts <<< "$selection"` only split on commas. The menu help advertised `1 3 6` AND `1,3,ssh`. Fix: `read -ra parts <<< "${selection//,/ }"` substitutes commas with spaces and lets `read` perform default word-splitting.
- **BUG-FS2 — empty-array → 1 phantom element**: `mapfile -t unique_feeds < <(printf '%s\n' "${empty[@]}" | sort -u)` on an empty input reads ONE empty string element; the `${#unique_feeds[@]} == 0` guard at the OLD post-mapfile site was bypassed. Fix: guard `${#feeds_to_enable[@]} == 0` BEFORE the mapfile AND return rc=1 (not rc=0) with a usage hint to stderr.
- **BUG-FS3 — silent `✅ Done` on ERROR**: the rc of `nftban_feeds_enable` was discarded; `echo "✅ Done!"` fired unconditionally even when every enable failed. Same class as BUG-A7 silent-permaban (v1.141 PR-A) and violates the v1.139.2 cli_error_rc contract. Fix: per-feed rc capture into a `failed=()` accumulator; `⚠️ N feed(s) failed: …` to stderr when non-empty; rc propagated; `✅ Done` only on full success.
- **BUG-FS4 — category regex missing `anonymity`**: pre-v1.142 `^(protection|ssh|web|email)$` omitted the menu's 5th category. Fix: `^(anonymity|email|protection|ssh|web)$`. The new FS4-DRIFT CI test asserts every category that `nftban_feeds_get_by_category()` produces is matched by the regex — adding a new category in the menu without updating the regex fails CI.
- **BUG-FS5 — test contract**: new hermetic test `cli_feeds_select_input_contract_test.sh` covers all five fixes + mixed-form (`1-3, 5, ssh` → 6 unique feeds; `all` → 14; comma/space/mixed separators all yield same result). 23 PASS / 0 FAIL.

### PR-UX-C6 — inline sudo / root-shell guidance ([#732](https://github.com/itcmsgr/nftban/pull/732), sq `7fc48f4b`)

Closes UX-C6 from the v1.139.2 UX-review residuals. UX-C4 banner restraint was already closed in-train by v1.141 PR-B E-NO-BANNER; this PR ships UX-C6 alone per operator's `SELECT_V1_142_UX_RESIDUAL_SET = C6` decision.

- **New helper `_v142_sudo_hint`** in `lib/cmd_common.sh` — stderr-only, JSON-mode aware. Prints both re-run forms (`sudo VAR=value /usr/lib/nftban/bin/nftban <command>` # sudo user, `VAR=value /usr/lib/nftban/bin/nftban <command>` # root shell) plus explicit anti-pattern warning against `export VAR=value; sudo nftban X` (the export is dropped at the sudo boundary).
- **Wired into the three central privilege-check helpers**: `cmd_require_root` (direct call after `cmd_error`), `nftban_require_root` in `lib/strict.sh` (defensive `declare -f` guard with inline fallback), `nftban_require_root_or_exit` in `core/nftban_security.sh` (same defensive pattern).
- **Intentionally NOT in scope**: the 56 inline `EUID -ne 0` check sites scattered across `cli/lib/nftban/cli/*.sh`. Patching them individually would be the broad framework rewrite operator-scope explicitly forbids; the three central helpers are the chokepoint.

### RC-AUDIT-2 Phase 1 — audit-only deliverable (no PR)

Per `SELECT_V1_142_RC_AUDIT_2_PHASE = Phase 1 only`. Punchlist filed at `NFTBAN_ROADMAP/V1_142_RC_AUDIT_2_PUNCHLIST.md` (200 lines, 14 KB). Methodology: classifier walks every `(echo|printf).*ERROR` / `cmd_error` / `cmd_die` site across 77 `cmd_*.sh` + dispatcher, inspects next 3 lines for explicit return/exit gate, classifies as SAFE-wrapper / SAFE-explicit-return / RISKY / DANGER.

**Headline findings:**

| Class | Count | % |
|---|---|---|
| SAFE-wrapper (`cmd_error` / `cmd_die`) | 19 | 4.7% |
| SAFE-explicit-return (≤3 lines after printer) | 345 | 84.6% |
| RISKY-no-explicit-return (heuristic; all 10 manually inspected = false positives) | 43 | 10.5% |
| **DANGER-return-0-after-error** | **0** | **0%** |
| **Total classified sites** | **407** | |

The v1.139.2 RC-contract test was structurally sufficient. The Phase 2 real risk surface is **20 candidate functions with the FS3-class shape** (loop + unconditional success marker), of which ~10 touch mutation paths. The punchlist recommends Phase 2 implementation for **v1.143.0**, not inline v1.142.

### Test evidence — cumulative at PR-UX-C6 merge time

**167 PASS / 0 FAIL** across 15 hermetic suites:

| Test | Result |
|---|---|
| `cli_feeds_select_input_contract_test.sh` (v1.142 PR-FS) | 23 PASS / 0 FAIL |
| `cli_sudo_hint_v142_test.sh` (v1.142 PR-UX-C6) | 19 PASS / 0 FAIL |
| v1.141 PR-A regressions (4 suites) | 76 PASS / 0 FAIL / 4 SKIP |
| v1.141 PR-B regressions (4 suites) | 18 PASS / 0 FAIL |
| v1.141 PR-C regressions (4 suites) | 21 PASS / 0 FAIL |
| v1.139.2 `rollback_help_guard_v1_139_2_test.sh` | 10 PASS / 0 FAIL |

### Non-goals locked v1.142-wide

- **0 `.go` files** across both PRs. Daemon byte-identical to v1.141.0.
- **0 `internal/`, `cmd/`, `build/`, `packaging/`, `install/`, `systemd/`, `schema/`, `docker/`, `.github/`, `fhs-spec.yaml` (body)** changes.
- **Schema 1.83.0 frozen.** Zero new metric names. Zero portal API change. Zero Go-installer change.
- **0 RC-AUDIT-2 Phase 2 implementation** — deferred to v1.143.0 per the punchlist.
- **0 log-durability / firewall-integrity / FHS-authority / security work** — those were v1.137 / v1.138 / v1.139.
- **0 v1.143 work** (module-attribution / detection coverage / SCHEMA-UNFREEZE fork).

### Release-prep envelope (this commit)

Standard 4 files only: `VERSION` (1.141.0 → 1.142.0), `STATUS.md` (banner + lane summary), `CHANGELOG.md` (this entry), `cli/lib/nftban/core/nftban_fhs_spec.sh` (header `meta:version` 1.141.0 → 1.142.0 ONLY; FHS body byte-identical, line 31..end SHA256 `4e618bd7d4ea379496f6052d3215ce7602e9001ea66f6948c1952c8111d1f242` unchanged from v1.141.0). No host contact during release-prep construction. No tag in this PR; tag follows on the release-prep squash after merge per `TAG_AND_PUBLISH_V1_142_0`.

---

## [v1.141.0] - 2026-05-29 — Consolidated CLI / status / data-truth correctness

**Codename:** `V1_141_0_CONSOLIDATED_CLI_STATUS_TRUTH`
**Controlling scope:** `NFTBAN_ROADMAP/V1_141_0_CONSOLIDATED_CLI_STATUS_TRUTH_SCOPE.md`
**PRs:** [#727](https://github.com/itcmsgr/nftban/pull/727) (PR-A, sq `fcdd00bd`) + [#728](https://github.com/itcmsgr/nftban/pull/728) (PR-B, sq `b4d9a028`) + [#729](https://github.com/itcmsgr/nftban/pull/729) (PR-C, sq `d3ff778a`)

> **Why:** v1.141.0 is a consolidated correctness release after the Ubuntu 26.04 Tier-1 introduction in v1.140.0. It closes the CLI / status / data-truth train across three PRs: parser validation and help inertness, JSON / stderr / no-banner discipline, and kernel-authoritative status / count / feed reporting. **Daemon byte-identical to v1.140.0** (zero Go touched across all three PRs — shell + test + docs only). **Schema 1.83.0 frozen.** No new metrics, no portal API change, no packaging or systemd unit change, no `build/fhs-spec.yaml` body change.

### PR-A — CLI parser validation + help inertness ([#727](https://github.com/itcmsgr/nftban/pull/727), sq `fcdd00bd`)

Closes **A7 / A8 / B5 / B6 / B7 / B8 / B11 / B12** + four sweep extras + three phantom-subcommand surfaces.

- **A7 / A8 parser** — `cmd_ban.sh` `--timeout` now rejects every non-positive-integer VALUE at parse time with rc=1 (regex `^[1-9][0-9]*$`), **before** any IPC to `nftban-core` / `/etc/nftban/blacklist.d/` write / nft mutation. Pre-v1.141: `abc` / `-5` / `0` / `1.5` / `+10` / `1e3` / `0x10` / `01` silently propagated to `nftban-core`, which defaulted to a **permanent ban**.
- **B5 / B6 / B7 / B8 / B11 / B12 help inertness** — per-arm bypass in `cmd_firewall.sh::firewall_reload`, `cmd_trust.sh::enable|disable|update` (EUID gate restructured), `cmd_config.sh::get|set|defaults|overrides|reset|reset-all` via `_v141_config_subarg_is_help()`. Plus a **top-level dispatcher guard** at `cli/sbin/nftban` covering `search`, `feeds`, `export`, `suricata`, `geoban` and the phantom subcommands `install` / `uninstall` / `rebuild`. The worst defect closed: `nftban export --help` previously **created an output JSON file on disk** before the user got help text.
- **Drops** (operator `SELECT_V1_141_0_B9_B10_B13_B14_DROP_OR_ALIAS = drop`): `feeds add` / `feeds remove` / `update apply` / `update channel` — universal sweep test SKIPs with the operator-named drop reason; no alias added.

### PR-B — JSON cleanliness + stderr + no-banner discipline ([#728](https://github.com/itcmsgr/nftban/pull/728), sq `b4d9a028`)

Closes **J-FEED / J-DDOS / J-PORT / E1 / E-NO-BANNER / F-FEEDS-JSON**.

- **J-DDOS / J-PORT JSON-mode** — `cmd_ddos.sh:386` + `cmd_portscan.sh:442` now pass `$json_mode` through to `nftban_ddos_status` / `nftban_portscan_status`; the core functions short-circuit ALL decorative chrome (banner + `━━━` heading bars + text body) when `json_mode="true"` and emit valid JSON via `jq -n`. Pre-v1.141: `nftban ddos status --json` and `nftban portscan status --json` got banner + heading + text body, not JSON (cruel-judge §3 E_J6 / E_J7).
- **F-FEEDS-JSON jq construction** — `cmd_feeds.sh` `nftban_feeds_list --json` and `nftban_feeds_status_json` now build per-feed objects via `jq -n` and fold them into an array via `jq -s '.'`. Pre-v1.141 used hand-built JSON with partial backslash + double-quote escape; broke on descriptions carrying unicode, control chars, or backslashes.
- **E1 unknown-command stderr** — dispatcher's Unknown-command path (banner + ERROR text + suggestion) is now redirected to `>&2`, leaving STDOUT clean for `nftban X 2>/dev/null`-style script consumers.
- **E-NO-BANNER universal gate** — `_v141_banner_suppressed()` at the top of `nftban_render_banner` and `nftban_banner` in `core/nftban_output.sh`. Honors `NFTBAN_NO_BANNER=1`, `NFTBAN_QUIET=1`, `NFTBAN_BANNER_MODE=none`. Dispatcher arg-parser at `cli/sbin/nftban main()` now exports `NFTBAN_NO_BANNER=1` on `--no-banner` AND on any `--json` presence so JSON output never gets decorative chrome prefix. `cmd_version.sh` + `lib/version.sh` decorative `━━━` chrome gated, data lines preserved.

### PR-C — status / count / feed truth (kernel authority) ([#729](https://github.com/itcmsgr/nftban/pull/729), sq `d3ff778a`)

Closes **D-headline / D-cache-wording / D-verify-hint / D-json-fork / D-feed-count**. Operator authority: `SELECT_CACHE_KERNEL_AUTHORITY = kernel`, `SELECT_V1_141_0_PR_C_GO_TOUCH_ALLOWED = no-unless-proven-impossible` — **shell-only landed cleanly. No Go.**

- **D-headline + D-cache-wording** — `cmd_status.sh` `_status_section_firewall`: `Banned IPs` headline reports the kernel total (sum of `blacklist_ipv4` + `blacklist_manual_ipv4` + `blacklist_ipv6` + `blacklist_manual_ipv6`). Four-line Automatic / Manual / Total-kernel split shown underneath. Pre-v1.141 `(kernel: N, cache may lag)` footnote is **gone**; cache disagreement now reports `Source-index: <count> (reconciled <N>s ago)` using cache file mtime.
- **D-verify-hint** — new `Verify kernel (authoritative):` block lists the four copy-pasteable `nft list set` commands so operators can independently confirm enforcement per CLAUDE.md project rule. Gated on `quiet_mode==0 AND ban_count>0`.
- **D-json-fork** — `cmd_status.sh` `output_json`: `banned_ips` now ALWAYS uses kernel total — matches text headline. New `counts.{authority, kernel_total, kernel_automatic, kernel_manual, kernel_elements, cache_count, source_index_count}`. `authority="kernel"` tells JSON consumers which field is the answer. Pre-v1.141 `banned_ips` preferred cache, producing JSON ↔ text contradiction.
- **D-feed-count** — `cmd_feeds.sh` `nftban_feeds_status` text mode: three distinct labels (`Feed file count`, `Feed IP total`, `Cached aggregate`) replace the pre-v1.141 single conflated line.

### Cumulative test evidence (all hermetic; jq required for JSON tests)

| Test | Result |
|---|---|
| PR-A: `cli_ban_timeout_validation_test.sh` | 12 PASS / 0 FAIL |
| PR-A: `cli_ban_timeout_no_mutation_test.sh` | 5 PASS / 0 FAIL |
| PR-A: `cli_help_inertness_v141_test.sh` | 13 PASS / 0 FAIL |
| PR-A: `cli_help_inertness_universal_test.sh` | 46 PASS / 0 FAIL / 4 SKIP |
| PR-B: `cli_no_banner_v141_test.sh` | 6 PASS / 0 FAIL |
| PR-B: `cli_stderr_contract_v141_test.sh` | 4 PASS / 0 FAIL |
| PR-B: `cli_json_clean_output_test.sh` | 3 PASS / 0 FAIL |
| PR-B: `cli_feeds_json_jq_construction_test.sh` | 5 PASS / 0 FAIL |
| PR-C: `cli_status_count_truth_test.sh` | 6 PASS / 0 FAIL |
| PR-C: `cli_status_kernel_verify_hint_test.sh` | 7 PASS / 0 FAIL |
| PR-C: `cli_status_json_no_contradict_test.sh` | 4 PASS / 0 FAIL |
| PR-C: `cli_feeds_count_truth_test.sh` | 4 PASS / 0 FAIL |
| v1.139.2 regression: `rollback_help_guard_v1_139_2_test.sh` | 10 PASS / 0 FAIL |
| v1.139.2 regression: `cli_error_rc_contract_v1_139_2_test.sh` | green via CI gate |
| **Total at PR-C merge time** | **125 PASS / 0 FAIL** |

### Non-goals — forbidden-path negative control (locked v1.141-wide)

- **0 `.go` files** across PR-A + PR-B + PR-C. Daemon `cmd/nftban-core` + `cmd/nftband` **byte-identical to v1.140.0** in `.text/.data/.rodata` expected.
- 0 `internal/`, `cmd/`, `build/`, `packaging/`, `install/`, `systemd/`, `schema/`, `docker/`, `.github/`, `fhs-spec.yaml` (body) changes.
- **Schema 1.83.0 frozen.** Zero metric names added or renamed. Zero portal API change. Zero Go-installer change. Zero logrotate or security or FHS body work. Zero v1.142 FS-cluster (feeds-select parser) work.

### Release-prep envelope (this commit)

Standard 4 files only: `VERSION` (1.140.0 → 1.141.0), `STATUS.md` (banner + lane summary), `CHANGELOG.md` (this entry), `cli/lib/nftban/core/nftban_fhs_spec.sh` (header `meta:version` regen only; FHS body byte-unchanged). No host contact during release-prep construction. No tag in this PR; tag follows on the release-prep squash after merge per `TAG_AND_PUBLISH_V1_141_0`.

---

## [v1.140.0] - 2026-05-28 — Ubuntu 26.04 LTS Tier-1 introduction

**Codename:** `V1_140_0_UBUNTU26_TIER1_INTRO`
**Controlling spec:** `NFTBAN_ROADMAP/V1_140_0_UBUNTU26_PHASE1_TIGHT_SPEC.md`
**Lab validation record:** `NFTBAN_ROADMAP/V140_172_LAB_VALIDATION_RECORD.md` (verdict `V140_172_LAB_VALIDATION_PARTIAL_PASS_B`)
**Closure:** `NFTBAN_ROADMAP/V1_140_0_RELEASE_CLOSURE.md`

> **Why:** Promotes **Ubuntu 26.04 LTS ("Resolute Raccoon")** from documented Tier-1 stub to operational Tier-0 (fully supported) per `SECURITY.md` taxonomy. CI matrix expansion + 3 new distro confs + 1 hint string + 3 tier-doc reshuffles. **Daemon byte-identical to v1.139.2** (zero Go touched; SHA256-identical confirmed in lab validation). Schema 1.83.0 frozen. Zero packaging dep change.

### CI matrix + release expansion ([#724](https://github.com/itcmsgr/nftban/pull/724), sq `1c0986fb`)

- `.github/workflows/build-packages.yml` — `ubuntu26.04 / ubuntu:26.04 / Tier 0` added to `build-deb` matrix; `tier: 0` added to `test-deb-install` matrix.
- `.github/workflows/release.yml` — `ubuntu26.04` added to `build-deb` matrix; `nftban-ubuntu26.04-amd64.deb` added to all 5 asset enumerations (replace list, MANIFEST.txt, latest URLs, RELEASE_NOTES tier table, verification list + per-asset check).
- `.github/workflows/ci-fresh-install-namespace-guard.yml` — `ubuntu26.04` matrix row added + coverage comment updated.

### Distro confs (3 new)

- `etc/nftban/distros/ubuntu-26.conf` — explicit precision: `version = 26.04`, `version_codename = resolute`, `[tier] level = 0`.
- `etc/nftban/distros/ubuntu.conf` — **generic Ubuntu fallback** (`version = latest`, `version_codename = generic`). **Mandatory:** the shell distro-config loader at `cli/lib/nftban/lib/nftban_distro_config.sh:78-112` has NO forward-fit (only the Go loginmon loader at `internal/loginmon/distroconf/distroconf.go:148-167` does). Without this, every future Ubuntu major requires a release. Closes the v1.139.1 install verify Finding #1 structurally.
- `etc/nftban/distros/debian.conf` — generic Debian fallback for symmetry + Debian 14+ forward-fit. Same shape as `centos.conf` / `fedora.conf` terminal-fallback pattern.

### CLI hint + tier docs

- `cli/lib/nftban/cli/cmd_update.sh:216` — `ubuntu20.04, ubuntu22.04, ubuntu24.04` → `..., ubuntu26.04`.
- `SECURITY.md` — Ubuntu 26.04 moved from Tier 1 (Planned) → Tier 0 (Fully supported).
- `CONTRIBUTING.md` — same tier reshuffle in §1 Supported Platforms.
- `RELEASE-CHECKLIST.md` — Ubuntu 26.04 flipped from `[ ] warn-only, when available` → `[ ] Build succeeds on Ubuntu 26.04` (required-pass).

### Operator decisions locked (2026-05-28)

- `SELECT_UBUNTU26_TIER1_VERSION = v1.140.0`
- OQ-1 = (a) promote Ubuntu 26 to repo Tier-0 / fully supported
- OQ-5 = container build (`runs-on: ubuntu-latest` + Docker `ubuntu:26.04`, matching existing 22/24/debian12/13 pattern; zero dependency on `ubuntu-26.04` runner GA)
- OQ-6 = AppArmor flip → phase2 (preserves Phase-1 daemon byte-identical; TODO comments at `nftban-core-{geoip,feeds}.service` left as-is)
- OQ-3 = keep Ubuntu 22.04 Tier-2 (LTS until April 2027)
- OQ-4 = defer Debian 13 co-promotion (Ubuntu 26 ships alone)
- Generic `debian.conf` = ship (Debian 14+ forward-fit symmetry)

### Lab validation evidence (`NFTBAN_ROADMAP/V140_172_LAB_VALIDATION_RECORD.md`)

Verdict `V140_172_LAB_VALIDATION_PARTIAL_PASS_B`. **Set B `49.12.220.155` Ubuntu 26.04 LTS — FULL PASS** on every §5.1–§5.7 step:
- Candidate DEB built natively (sha256 `5981afc5ebfd34ef19f97f8d1a97da68ec27a56af341753003c5d2dddaa89251`, 13.6 MB).
- Install reached `INSTALL_STATE=COMMITTED` via standard `apt-get install` + `NFTBAN_TAKEOVER=1 nftban-installer --repair`.
- 16/16 install assertions PASS.
- `nftban version`: no "No configuration file found" (proves the Phase-1 conf-fix).
- All 3 new confs (`ubuntu-26.conf` explicit, `ubuntu.conf` generic, `debian.conf` generic) resolve correctly via loader.
- **Daemon SHA256-identical** between baseline `main @ 3ba23da9` (v1.139.1) and candidate (`nftban-core` sha256 `cd605ca7…`, `nftband` sha256 `b48362cf…`).
- All negative-control gates PASS (fhs-spec.yaml MD5, deb/control MD5, nftban_fhs_spec.sh MD5, cmd/+internal git diff = empty).

Set A (172.x lab) deferred per operator's `PARTIAL_PASS_B` acceptance: `.3`/`.39` powered off; `.20` is the Ubuntu 24 hypervisor; the Ubuntu 26 guest `tgt-u2604` at `10.88.88.112` didn't authorize the deputy's SSH keys. Operator gate "continue to 140 and lets release the UBUNTU 26" accepted given the SHA256-identical daemon proof.

### Out of scope (deferred to Phase-2 / later lanes; filed in `NFTBAN_PENDINGS_AND_BUGS_CURRENT.md`)

- Canonization workflows (`ci-{install,uninstall,update,restore}-canonization.yml`, `ci-runtime-truth.yml`) — Phase-2.
- AppArmor + Landlock + Go-1.25 enablement re-test on `nftban-core-{geoip,feeds}.service` — Phase-2 (OQ-6).
- `nftban uninstall` CLI wrapper — separate lane.
- Ubuntu `inet filter` postinst handling under CVE-2025-NFTBAN-001 guard — Phase-2 behavioral.
- systemd 259 path-transition warnings — non-fatal; FHS-spec adjacent.
- `mailutils` via Recommends — release-notes only.
- SLSA per-distro provenance — single hermetic Go binary attests for all.
- All UX-C2 through UX-C6 + RC-CONTRACT-AUDIT + FHS-SPEC-GUI-MENTION deferred from v1.139.2.

### Release-prep envelope (this commit)

Only allowed files touched in this release-prep PR: `VERSION`, `STATUS.md`, `CHANGELOG.md`, `cli/lib/nftban/core/nftban_fhs_spec.sh` (header-version regen only; FHS body byte-unchanged). No host contact during release-prep construction.

---

## [v1.139.2] - 2026-05-28 — CLI safety + truth-telling hotfix

**Codename:** `V1_139_2_CLI_SAFETY_AND_TRUTH`
**Records:** `NFTBAN_ROADMAP/139_1_ROLLOUT/UX_HONEST_CRUEL_JUDGE_REVIEW_V1_139_1.md`
**Closure:** `NFTBAN_ROADMAP/V1_139_2_RELEASE_CLOSURE.md`

> **Why:** Three production CLI defects of the same class — the binary lies to automation — surfaced during the v1.139.1 fleet rollout and an independent UX review. None is a daemon issue; all are CLI text / dispatcher gaps. Daemon byte-identical to v1.139.1.

### Rollback `--help` guard (SHIP-BLOCKER) — PR [#722](https://github.com/itcmsgr/nftban/pull/722)
- Prior to v1.139.2, `nftban rollback --help` invoked a real rollback because the dispatcher called `_do_rollback` without parsing `--help`. A CLI-audit invocation tripped the bug during the v1.139.1 rollout and downgraded a canary host (lab2 v1.139.1 → v1.133.0).
- Defense-in-depth fix at `_do_rollback`'s entry in `cli/lib/nftban/cli/cmd_update_backup.sh:82` so every current AND future caller is safe. The 4 dispatch sites in `cli/lib/nftban/cli/cmd_update.sh` (top-level rollback alias + github/git/local sub-modes) now pass `"$@"` so the guard sees the args. New `_rollback_help()` helper renders proper usage text.
- New hermetic test `cli/lib/nftban/tests/rollback_help_guard_v1_139_2_test.sh` — 10/10 PASS (3 structural + 7 runtime / control).

### CLI exit-code contract test + CI gate (C1 from UX review)
- The UX review reported four error paths returning rc=0 while printing ERROR text. Code-truth verification against `main @ 3ba23da9` shows all four paths already return rc=1; the review's evidence likely reflects an older installed binary or a `/usr/sbin/nftban` wrapper. Rather than apply theater "fixes" to already-correct code, this release adds a hermetic regression test that locks the current correct behavior as the contract.
- Locked tier-0 matrix:
  - `nftban bogus-subcommand` → rc≥1.
  - `nftban ban` (no arg) → rc≥1.
  - `nftban ban 999.0.0.1` (invalid IP) → rc≥1.
  - `nftban update --dry-run` (unimplemented flag) → rc≥1.
  - Controls: `nftban version`, `nftban help`, `nftban rollback --help` → rc=0.
- New hermetic test `cli/lib/nftban/tests/cli_error_rc_contract_v1_139_2_test.sh` — 10/10 PASS. CI step "CLI exit-code contract (v1.139.2)" added to `ci-architecture.yml` so any future PR that regresses these paths fails CI.

### GUI retirement (cosmetic)
- The Web GUI (`cmd_gui.sh`) was structurally retired in v1.100.1b ([PR #502](https://github.com/itcmsgr/nftban/pull/502) "GOTH cross-cutting prune") but 29 stale "Web GUI" / "for GUI" / "for API/GUI" references survived across 19 files. All rewritten to "scripts/API" or "metrics" or removed, including `cmd_wizard.sh` user-facing prompts + status banners (the GUI question is gone; only the Prometheus metrics exporter remains).
- `ENABLE_GUI=0` pinned for backward-compat with downstream `/etc/nftban/nftban.conf.local` consumers, with v1.139.2 retirement-marker comments citing PR #502. Dead `WANT_GUI` variable removed (shellcheck SC2034).
- `nftban_fhs_spec.sh:99` "TLS certificates for GUI/API" deliberately NOT touched — it's a generated file; deferred to a separate fhs-spec source-side cleanup lane.

### Validation
- PR #722 CI: green.
- Local proofs: bash -n 22/22; rollback test 10/10; rc-contract test 10/10; GUI grep-zero on modified files (2 intentional retention markers only); zero `.go` in diff (daemon byte-identical to v1.139.1); YAML parse clean on touched workflows; envelope = 23 files (cap 30).
- Post-merge main CI on the squash watchpoint: confirmed before release-prep PR opened.
- Release-prep main CI on the release-prep squash: confirmed before tag.

### Out of scope (deferred to v1.140.x per UX review's P1/P2/P3 ranking)
- C2 wall-of-text validation errors — UX redesign across 60+ command modules.
- C3 cache/kernel drift remediation in `nftban status` — needs design.
- C4 banner chrome restraint.
- C5 `--dry-run` flag parity (advertised on `nftban ban`, unimplemented on `nftban update`).
- C6 inline-sudo guidance on privilege failure.
- Broader audit of the other 405 `ERROR:` printer sites — separate lane.
- `nftban_fhs_spec.sh` source-side GUI cleanup — separate fhs-spec lane.
- Ubuntu 26 / v1.140 Tier-1 introduction — separate lane (lab-first; HARD_HOLD on tag pending 172.x lab validation).

### Release-prep envelope (this commit)
Only allowed files touched in this release-prep PR: `VERSION`, `STATUS.md`, `CHANGELOG.md`, `cli/lib/nftban/core/nftban_fhs_spec.sh` (header-version regen only; FHS body byte-unchanged). No host contact during release-prep construction.

---

## [v1.139.1] - 2026-05-28 — Hostname-fallback hotfix (PRE-EXISTING distro-compat)

**Codename:** `V1_139_1_HOSTNAME_FALLBACK_HOTFIX`
**Records:** `NFTBAN_ROADMAP/V1_139_1_{HOSTNAME_FALLBACK_HOTFIX_RECORD,UBUNTU26_INSTALL_VERIFY_RECORD}.md`
**Rollout kit:** `NFTBAN_ROADMAP/139_1_ROLLOUT/` (9-host bot-runnable kit; operator-locked scope: lab2, lab4, monitor, dns1, dns2, srv1, srv2, srv3, srv4)

> **Why:** the `nftban-unified-exporter`'s hostname fallback at line 1474 read `hostname=$(hostname -f 2>/dev/null || hostname)` — both branches call the SAME `hostname` binary. On hosts that ship no `hostname` binary in PATH (notably the minimal `centos-stream10` Docker base image used in CI's Fresh-install Namespace Guard), both branches failed `command not found` (rc=127) and the exporter aborted. Pre-existing since git-blame `97b2c9297` (2026-02-04) — shipped unchanged in v1.137.0, v1.138.0, v1.139.0. **NOT a v1.139 regression.** Exporter is classified auxiliary at install_state (`IsAuxiliaryUnit`, v1.135), so installs reached COMMITTED on EL10 even when the exporter aborted. **Real-fleet production EL10 hosts (`srv1`, `srv4`) both have `hostname` present — in-production blast radius = zero.** This is defensive hardening.

### Hotfix — single PR ([#720](https://github.com/itcmsgr/nftban/pull/720), sq `b050f7ab`)
- Extends the fallback chain at `cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh:1474` to 6 links: `hostname -f || hostname || hostnamectl --static || uname -n || cat /etc/hostname || echo unknown`.
  - `hostnamectl --static` covers EL10 minimal (kept systemd; dropped `hostname` binary).
  - `uname -n` is POSIX-always.
  - `/etc/hostname` is the kernel-set nodename source.
  - `echo unknown` is the bulletproof terminator — the line never exits 127 regardless of host shape.
- Behavior preserved on Debian/Ubuntu/EL9 — first link still wins where `hostname` is present.
- New hermetic test `cli/lib/nftban/tests/hostname_fallback_v1_139_1_test.sh` (10 assertions): T1–T6 source-link asserts, T7–T9 PATH-shadow runtime simulations (T7 hostname-shadowed → `hostnamectl` returns real value; T8 hostname+hostnamectl shadowed → `uname -n` returns real value; T9 all 4 fallbacks shadowed → literal `unknown`, rc=0 never 127), T10 regression guard against the original two-call-of-same-binary pattern.
- **Daemon byte-identical to v1.139.0** (no Go touched). Schema 1.83.0 frozen. 2 files changed (146 insertions, 1 deletion).

### Validation
- Verified `V1_139_1_HOTFIX_VERIFY_PASS_DEB_AND_RPM` on **lab2** (Ubuntu 24.04 DEB / Go 1.25 / shellcheck 0.9 / mikefarah yq v4.44.1) + **lab4** (AlmaLinux 9.8 EL9 RPM / Go 1.25 / shellcheck 0.10): `bash -n` + `shellcheck` clean; 10/10 test PASS; `generate-fhs-outputs.sh --check` rc=0 (v1.139 FHS gates intact); `go vet`/`go build`/`go test ./internal/nftbanconf/...` PASS (PR-B parity test intact); `staticcheck@v0.7.0 ./...` clean; `gosec -nosec ./...` 0 new findings; DEB + EL9 RPM still-build (12 MB each); PATH-shadow runtime proofs all 3 patterns confirmed.
- Verified `V1_139_1_HOTFIX_UBUNTU26_VERIFY_PASS` on **Ubuntu 26.04 LTS "resolute"** (`49.12.220.155`, Hetzner FSN1 fresh VPS, systemd 259, nftables 1.1.6) via the CI-built `nftban-ubuntu24.04-amd64.deb` (md5 `1df7e45deb75ea793f829f1977d3c129`): standard `apt-get install` + `NFTBAN_TAKEOVER=1 nftban-installer --repair` reached `INSTALL_STATE=COMMITTED` / `AUTHORITY=TAKEOVER` with 16/16 install assertions PASS; hotfix test 10/10 PASS on the host; exporter ran twice clean (rc=0); `/var/cache/nftban/metrics/stats.json.hostname = "ubuntu-4gb-fsn1-1"` correctly populated via T1; idempotency cycle (apt purge → reinstall) reached COMMITTED again. 5 Ubuntu-26-specific findings recorded as inputs to the v1.140.0 lane (missing `ubuntu-26.conf`/`ubuntu.conf` generic, `nftban uninstall` CLI wrapper absent, Ubuntu's default `inet filter` table blocks reinstall idempotency, systemd 259 path-transition warnings non-fatal, `mailutils` pulled via Recommends).
- PR #720 CI: **50 / 2-skip / 0-fail** after one infrastructure-flake rerun on `Build NFTBan Packages` (artifact-upload intermediary 403 on `Build DEB (ubuntu22.04)` — same class as the documented container-runtime-125 flake; single `gh run rerun --failed` cleared; matches prior v1.137/v1.139 rerun precedents). All downstream test-install jobs PASS (debian12/13, ubuntu22.04/24.04, alma9, rocky9, centos-stream9, centos-stream10).

### Out of scope (deferred)
- Ubuntu 26.04 LTS as Tier-1 release target — `v1.140.0` lane (scope at `NFTBAN_ROADMAP/V1_140_0_UBUNTU26_PHASE1_TIGHT_SPEC.md`; controlling Phase-1 spec; operator-locked envelope; HOLD until v1.139.1 publishes).
- `nftban uninstall` CLI wrapper subcommand — separate lane.
- Ubuntu `inet filter` postinst handling (CVE-2025-NFTBAN-001 bypass-prevention guard friction) — Phase-2 behavioral.
- `systemd-tmpfiles --create` exit 73 path-transition warnings — already classified non-fatal; FHS-spec adjacent.
- All parked lanes (CSF-RESTORE, daemon least-privilege, Registry-2 unification, schema unfreeze, fleet least-privilege) — unchanged.

### Release-prep envelope (this commit)
Only allowed files touched in this release-prep PR: `VERSION`, `STATUS.md`, `CHANGELOG.md`, `cli/lib/nftban/core/nftban_fhs_spec.sh` (header-version regen only; FHS body byte-unchanged). No host contact during release-prep construction.

---

## [v1.139.0] - 2026-05-28 — FHS authority hardening (FHS-TMPFILES-ZZ + FHS-UNGEN-LOGROTATE-CREATE + ATG formalization)

**Codename:** `V1_139_0_FHS_AUTHORITY_HARDENING`
**Records:** `NFTBAN_ROADMAP/V1_139_{FHS_AUTHORITY_HARDENING_SCOPE,FHS_AUTHORITY_RECHALLENGE_RECORD,PR_A_TMPFILES_ZZ_VERIFY_RECORD,PR_B_LOGROTATE_CREATE_PARITY_VERIFY_RECORD,PR_C_ATG_FORMALIZATION_RECORD,FHS_AUTHORITY_GRAPH}.md`

> **Why:** the FHS spec is the single declarative source of truth for nftban directories/perms/owners, but the *effective* installed state is produced by a graph of derivative authority surfaces (tmpfiles, sysusers, RPM `%attr`, DEB `dpkg-statoverride`, logrotate, Go fallback perms…). The v1.139 re-challenge identified two real high-drift residuals and one workspace-doc formalization. Schema 1.83.0 frozen; no metrics/portal change; **daemon byte-identical to v1.138.0** (no production Go touched across the three slices). Two surfaces classified as already CI-parity-bounded were deliberately deferred; GAP 3 sysusers recipe-vs-execution remains open but not in this release.

### FHS-TMPFILES-ZZ — tmpfiles reconcile policy (PR [#716](https://github.com/itcmsgr/nftban/pull/716), sq `61558cfa`)
- The packaged `install/systemd/tmpfiles.d/nftban.conf` carried **47 `d` create-if-missing directives and zero `z`/`Z` reconcile directives**; the gap was at the **generator level** (the script hardcoded `d` prefix in all three yq projections for the data/logs/runtime groups). On systemd < 252, a pre-existing nftban-owned dir with wrong mode/owner silently stayed wrong under `systemd-tmpfiles --create`. On systemd ≥ 252 (Ubuntu 24.04, EL9), `d` itself reconciles — so `z` is belt-and-suspenders + explicit-intent + backward-compat.
- **HYBRID policy (operator-decided):** every `created_by: tmpfiles` nftban-owned-lifecycle entry gets a sibling **non-recursive `z`** reconcile line via a new `tmpfiles_reconcile` field. Zero recursive `Z` — recursive would clobber file modes inside log/data dirs whose contents have varied modes. Operator-administered surfaces (`created_by: package` / `feature_enable`) are protected via path exclusion. The `/var/lib/nftban/reports/auditors` authority exception (0770 root:nftban-auditor, operator-writable) uses `z` (non-recursive) — does not touch auditor-written report files.
- **Generator extension:** `build/generate-fhs-outputs.sh generate_tmpfiles()` now emits each group's `d` block followed by a second yq pass for the `z`/`Z` block. Uses only `select(...)` projection — no jq-style `if/then/else/end` (which mikefarah yq v4 rejects). Compatible with both yq variants. The original one-pass extension was caught by lab2 on mikefarah v4.44.1 (the build/CI standard) and re-verified on the production toolchain after the two-pass fix.
- **Tests:** new `cli/lib/nftban/tests/tmpfiles_zz_v139_test.sh` (10 assertions: per-entry annotation, no-package-leak, count parity, paired d+z, d/z tail match, auditor non-recursive guard, no recursive Z in this PR, generator `--check` PASS).
- 4 files changed; no production Go. Lab2/lab4 perm-reconcile scratch proof recorded.

### FHS-UNGEN-LOGROTATE-CREATE — logrotate create-mode parity (PR [#717](https://github.com/itcmsgr/nftban/pull/717), sq `7daacb04`)
- `install/config/nftban.logrotate` + `install/config/nftban-suricata.logrotate` carried hand-authored `create MODE OWNER GROUP` directives with **no generator emitting them from fhs-spec and no parity test asserting they match**. A future fhs-spec mode/owner change (e.g. daemon-least-priv rename of the service user) would silently leave the logrotate `create` lines pointing at the stale identity.
- **Closure:** new `logrotate_create: true` flag on the two `file_permissions` entries (`/var/log/nftban` and `/var/log/nftban/suricata`); modes/owners/groups unchanged. New Go parity test `internal/nftbanconf/logs_logrotate_create_parity_test.go` (3 functions: `TestLogrotateCreateMatchesFhsSpecAuthorities` main parity, `TestLogrotateCreateAuthorityIsReached` no-dead-authority, `TestLogrotateCreateNftbanLogsOnly` scope guard) asserts every `create` line in both packaged logrotate files matches the matching authority via longest-prefix lookup honoring `exclude`. Uses `gopkg.in/yaml.v3` (already in `go.mod`).
- 2 files changed; **no logrotate template change** (current modes already matched). **Daemon byte-identical.**

### ATG formalization (PR [#718](https://github.com/itcmsgr/nftban/pull/718), sq `6a7cc9c1`)
- Workspace promotion: `AUDIT_190_LIFECYCLE/V107_FHS_AUTHORITY_GRAPH_DESIGN_CODE_GAP_CLOSURE.md` (workspace investigation) → `NFTBAN_ROADMAP/V1_139_FHS_AUTHORITY_GRAPH.md` (canonical), with a formalization preamble + GAP-closure status table mapping V107 gaps to v1.139 closures (GAP 2 = CLOSED_BY_PR_716, GAP 4 = CLOSED_BY_PR_717, GAP 5 = closed by v1.137 panel retirement, GAP 1 + GAP 3 deferred). V107 replaced with an 11-line pointer stub matching the existing AUDIT_190_LIFECYCLE→stub pattern.
- Repo-facing slice: 1 line added to `.claude/CLAUDE.md` under `## Additional Resources` anchoring at the canonical doc.

### Compositional authority-lock now complete on logrotate (v1.137 + v1.139)
| Axis | Authority | CI gate |
|---|---|---|
| WHICH logs exist + HOW OFTEN rotated + HOW MANY retained | `LogInventory()` in `internal/nftbanconf/logs.go` (v1.137 B-12) | `TestLogInventoryCoveredByTemplates` |
| logrotate `create` MODE OWNER GROUP | `file_permissions` entries with `logrotate_create: true` in `build/fhs-spec.yaml` (v1.139 PR-B) | `TestLogrotateCreateMatchesFhsSpecAuthorities` |
| tmpfiles `z`/`Z` reconcile of nftban-owned dirs | `tmpfiles_reconcile` annotated entries in `build/fhs-spec.yaml` (v1.139 PR-A) | `cli/lib/nftban/tests/tmpfiles_zz_v139_test.sh` + generator `--check` (ci-architecture.yml) |

A future change to any axis requires reciprocal change in the others, with CI proving it.

### Unchanged / invariants
- **Schema 1.83.0 frozen.** No metrics/portal/Status-JSON wire/installer-payload schema change.
- **Daemon byte-identical to v1.138.0.** No production Go touched in PR-A, PR-B, or PR-C (only metadata YAML, generator script, regenerated tmpfiles config, two new test files, and one CLAUDE.md line).
- `nftban_fhs_spec.sh` change in this release-prep is header-version regen only (FHS body byte-unchanged — the v1.139 generator-script change does not affect this generated output's body content).
- **FHS-UNGEN (a) Go fallback perms** + **(b) RPM file-level `%attr`** = DEFERRED (re-challenge confirmed both are already CI-parity-bounded). **GAP 3 sysusers recipe-vs-execution** = OPEN, not in v1.139. **CSF-RESTORE / daemon least-privilege / Registry-2** = operator-PARKED.

### Validation (release-prep, this commit)
- Each lane challenged against real code before coding (re-challenge inside `V1_139_FHS_AUTHORITY_RECHALLENGE_RECORD.md`).
- PR #716 CI green (51 / 4-skip / 0-fail) → squash `61558cfa` → post-merge main 24/1-skip/0-fail.
- PR #717 CI green (53 / 3-skip / 0-fail) → squash `7daacb04` → post-merge main 24/1-skip/0-fail.
- PR #718 CI green (45 / 2-skip / 0-fail) → squash `6a7cc9c1` → post-merge main 24/1-skip/0-fail (after a one-shot `gh run rerun --failed` clearing the known `FuzzParseLogLine` `context deadline exceeded` infrastructure flake; same remediation pattern as v1.137 release-prep, zero code change).
- Lab verify recorded for both code PRs on DEB + RPM using production mikefarah yq v4.44.1. **No fleet rollout yet — separately gated.**



**Codename:** `V1_138_0_FIREWALL_INTEGRITY_AND_BYPASS_ALERT`
**Records:** `NFTBAN_ROADMAP/V1_138_{FIREWALL_INTEGRITY_SCOPE,PR_A_RULESET_FINGERPRINT_VERIFY_RECORD,PR_B_BYPASS_ALERT_RECORD,PR_B_DUPLICATE_ALERT_LOGS_THIRD_AUDIT}.md`

> **Why:** two operator-flagged undetected-bypass gaps from the v1.136.1 fleet recon, shipped contiguously. (1) No canonical ruleset fingerprint → an injected `nft add rule ... accept` or a chain-policy flip (`drop → accept`) went undetected by the validator's structure-only checks. (2) The 9-detector firewall-conflict library populated WARNING/CRITICAL state on every health-timer run, but that signal was trapped in in-memory arrays — operators had no canonical, grep-testable log line. Schema 1.83.0 frozen; no metrics/portal change; no Registry-2 refactor (PR-C orthogonal, intentionally not opened); CSF-RESTORE + daemon least-privilege remain operator-PARKED.

### SEC-RULEFP — ruleset fingerprint baseline + `verify-rules` (PR [#712](https://github.com/itcmsgr/nftban/pull/712), sq `df281c08`)
- New `internal/rulefp` package: `Normalize(rulesetText)` strips volatile noise (counter `packets N bytes M`, handles `# handle N`, `last used`, `expires`, dynamic-set `elements = { … }` blocks including multi-line) preserving structural text only; `Digest()` = sha256(Normalize). `CaptureBaseline()` writes the digest atomically (temp + rename, mode `0600` — daemon-owned, no group-read consumer); `Verify()` is **read-only** and never refreshes the baseline (the SEC-RULEFP invariant; tested by `TestVerify_DoesNotRefreshBaseline`).
- `nftban-core verify-rules` (new CLI subcommand): `--capture` to re-baseline, bare verify to compare. Exit codes: **OK / BASELINE_MISSING = 0, MISMATCH = 2, NFT_UNAVAILABLE = 3**.
- Daemon (`cmd/nftband`): captures the baseline only after a successful (`!check`) apply in `handleApplyRulesetRequest`; a **record-only** `checkRulesetFingerprint()` runs during periodic reconciliation — logs MISMATCH for operator action, never mutates rules, never auto-heals the baseline.
- CLI (`cmd_firewall.sh`): `firewall rebuild` captures the baseline only in the exit-0 success branch.
- Health (`nftban_health_checks_security.sh`): new `nftban_health_check_ruleset_fingerprint()` — MISMATCH → WARNING; BASELINE_MISSING → advisory.
- Tests: 7 `internal/rulefp` unit tests (deterministic digest, churn immunity incl. multi-line elements, detect injected accept + chain-policy flip, no-auto-refresh) + 19-assert shell wiring/invariant guard.
- Verified `V1_138_PR_A_RULESET_FINGERPRINT_VERIFY_PASS_DEB_AND_RPM` on lab2 (Ubuntu 24 / Go 1.25) + lab4 (AlmaLinux 9.7 / EL9 / Go 1.25): `gofmt` / `go vet` / `go build` / `go test ./internal/rulefp/` / 19-assert shell guard / **staticcheck ./... CLEAN** / **`gosec -nosec ./...` zero new findings** (the v1.137 `e7a789ee` precedent — inline `#nosec` is stripped by `gosec -nosec`, findings must be code-eliminated) / DEB + EL9 RPM still-build / a controlled live inject (`nft add rule ip nftban input ip saddr 203.0.113.222 drop`) + new-chain structural flip → MISMATCH exit 2 → restore → OK exit 0 / counter/timer/populated-set churn → no false MISMATCH / hosts fully restored (baseline file removed, ruleset diff clean, installed package `nftban-core-1.135.0-1.el9` unchanged).
- **PR #712 CI green (55 / 1-skip / 0-fail)** including a confined 3-commit CI-fix sequence on the same branch: `08db3947` SC2034 shellcheck (the lab couldn't run shellcheck) + `f66d82da` SA4000 staticcheck (test refactor for tautology pattern) + `21236c6b` gosec G306+G204 (0600 + unrolled exec literals). The lab gate was corrected mid-lane to require `staticcheck ./...` and `gosec -nosec ./...` going forward.

### SEC-BYPASS-ALERT — firewall-conflict alerts to `service-alerts.log` (PR [#713](https://github.com/itcmsgr/nftban/pull/713), sq `12399c23`)
- New emitter `nftban_emit_firewall_conflict_alerts()` in `cli/lib/nftban/core/nftban_firewall_conflicts.sh` — reads the existing `NFTBAN_FIREWALL_CONFLICTS[]` + `NFTBAN_FIREWALL_SEVERITY` globals (no new detector logic, no kernel reads). Emits only at severity ≥ WARNING (NONE/INFO suppressed; INFO covers the deliberate cPHulk-coexists state).
- Line shape (deterministic, grep-testable, non-metric): `[YYYY-MM-DD HH:MM:SS] [SEVERITY] [FW-CONFLICT] service=<name> detail=<short>`. The `[FW-CONFLICT]` tag cleanly partitions these rows from the existing OnFailure worker's diagnostic blocks in the same log.
- **Single wire call** from `nftban_health_check_conflicting_firewalls()` after `NFTBAN_HEALTH_RESULTS["conflicting_firewalls"]` is set; guarded with `declare -F` + `|| true` so an emitter failure cannot break the health check.
- Per-service throttle in `${NFTBAN_DATA_DIR}/alert_throttle_firewall_<svc>` (default 3600s; env override `NFTBAN_ALERT_THROTTLE_SECONDS`). Distinct namespace from the existing OnFailure worker's `alert_throttle_<unit>`.
- **Audit residuals R1–R7 closed in-slice** (third audit `V1_138_PR_B_DUPLICATE_ALERT_LOGS_THIRD_AUDIT.md`, operator policy "no debt to a later release"): **R1** per-service `flock -n 9` over `${throttle_file}.lock` (no parallel race between health timer + manual `nftban health`); **R2** non-numeric throttle file → treat as stale; **R3** severity-aware re-emit via sibling `.sev` file — WARNING→CRITICAL escalation inside the throttle window is no longer silently suppressed; **R4** clamp future-dated `last_alert` (clock skew) → 0; **R5** intra-run TAG dedup tested; **R6** non-writable log dir best-effort tested via `/proc/sys/...`; **R7** sanitizer comment rewritten to state the actual firewall-namespace rule and the deliberate divergence from the OnFailure worker (the throttle prefix `alert_throttle_firewall_` already disambiguates).
- `internal/nftbanconf/logs.go LogInventory()` adds `service-alerts.log` (weekly/4, TemplateMain) — closes the v1.137 B-12 silent inventory-authority gap (the path was already in `install/config/nftban.logrotate` but absent from the Go authority; the drift-test is one-directional, so the extra stanza was silently tolerated).
- Tests: `service_alerts_v138_test.sh` **27 assertions** (T1–T9a original 16: severity gating, exact line shape, multi-service emission, indented-sub-entry filtering, throttle dedup, throttle expiry, env override, empty-array guard, hyphenated-tag preservation; T10–T15a residual-closure 11: parallel ×5 race → 1 line via flock, corrupt-ts replacement, WARNING→CRITICAL escalation + `.sev` metadata, future-clamp, intra-run TAG dedup, non-writable log dir best-effort).
- Verified `V1_138_PR_B_BYPASS_ALERT_VERIFY_PASS_DEB_AND_RPM_AFTER_RESIDUAL_CLOSE` on lab2 + lab4: same Go + shell battery as PR-A (including `staticcheck ./...` CLEAN, `gosec -nosec ./...` zero new findings in `internal/nftbanconf/`); `service_alerts_v138_test.sh` 27/0 on both labs; DEB + EL9 RPM still-build; live `/var/log/nftban/service-alerts.log` (absent on labs) untouched (test uses scratch `NFTBAN_LOG_DIR`).
- **PR #713 CI green (54 / 1-skip / 0-fail)** including the residual-closure commit `6f5ce54f` on top of initial PR-B commit `cbdadcaa`.

### Unchanged / invariants
- **Schema 1.83.0 frozen.** No metrics-label / portal / Status-JSON wire / installer payload schema change.
- **PR-C Registry-2 unification** = intentionally NOT opened (orthogonal banner cosmetics; emission did not need panel×distro context).
- **CSF-RESTORE-on-uninstall** + **daemon least-privilege (`User=root → nftban`)** = operator-PARKED, not cancelled.
- `nftban_fhs_spec.sh` change in this release-prep is header-version regen only (FHS body byte-unchanged).

### Validation (release-prep, this commit)
- Each blocker challenged against real code before coding (re-challenge records inside the scope docs).
- PR #712 CI green (55/1-skip/0-fail) → squash `df281c08` → post-merge `main` 24/1-skip/0-fail.
- PR #713 CI green (54/1-skip/0-fail) → squash `12399c23` → post-merge `main` 24/1-skip/0-fail.
- Lab verify recorded for both PRs on DEB + RPM. **No fleet rollout yet — separately gated.**



**Codename:** `V1_137_0_LOG_DURABILITY_PLUS_BLOCKERS`
**Records:** `NFTBAN_ROADMAP/V1_137_{LOG_DURABILITY_VERIFY_RECORD,BLOCKER_DUXV16_DUXV17_RECORD,BLOCKER_PANEL_GROUP_RETIREMENT_RECORD,PR710_FINAL_TRAIN_REVIEW}.md`

> **Why:** one coupled train closing the operator-flagged log disk-fill plus two correctness blockers the V127/V132 shared-resource audits surfaced. The blockers are coupled (fixing the `bans.log` reader re-activates the persistent-offenders writer race), so they ship together. Shell + packaging + installer-Go; daemon NOT byte-identical (escalation/persistence/nftbanconf/installer changed; the log-durability portion alone was code-identical). Schema 1.83.0 frozen.

### Log durability (PR #710)
- **B-04** Suricata logrotate policy installed to `/etc/logrotate.d/nftban-suricata` at provisioning (was template-only → `suricata/eve-*.json` unrotated → disk-fill).
- **B-05** `copytruncate` on the main `nftban.log` stanza; **B-09** `installer.log` + `update.log` covered; **B-01** divergent health-fix fallback removed (single canonical template wins).
- `logrotate` is now a hard **DEB `Depends` + RPM `Requires`**.
- **B-12** `internal/nftbanconf/logs.go` rebuilt as the canonical `LogInventory()` authority; a new Go drift-test asserts the templates cover every inventory log with matching frequency/retain. GEO-CLEANUP-001 (`GEOBAN_ENABLED`).

### Escalation reader/writer integrity (PR #710)
- **D-UXV-16** `escalation.parseBanEntry`/`CountRecentBans` now parse the canonical BLC-1 pipe `bans.log` (was the dead space-delimited format → returned 0 for every IP → repeat-offender→permanent escalation silently never fired); counts only `BANNED` rows.
- **D-UXV-17** `30-persistent-offenders.conf` converged on a single canonical writer (`persistence.PersistBan`) hardened with a stable sibling-lockfile `flock` across read-modify-rename — eliminates the unlocked-append-vs-rename clobber and normalizes the entry format.

### nftban-panel group retirement (PR #710)
- Removed the dormant `nftban-panel` package-created authorization identity across `fhs-spec.yaml`/`sysusers.d`, polkit (`30-nftban-panel.rules` + the `nftban-panelctl` wrapper), RPM/DEB packaging, installer payload + assertions, health WARN+self-heal, `cmd_polkit.sh`/`polkit_validator.sh`, and CI runtime-truth. Supersedes the D-NEW-11 KEEP note (its `nftban-panelctl` consumer was uninvoked; the GOTH GUI redesign retired panel integration).
- **Preserved:** user `nftban`, groups `nftban`/`nftban-auditor`, the auditor read-only tier (`20-nftban-auditor.rules`), and the SEPARATE hosting-panel firewall-takeover subsystem (`--panel-auto-takeover` / `--no-panel` / `cmd_panel.sh`) — conflation trap.

### Unchanged / invariants
- No schema / metrics-label / portal change. **Schema 1.83.0 frozen.** `nftban_fhs_spec.sh` change in release-prep is header-version regen only (FHS body byte-unchanged). Daemon binary changes are confined to the escalation reader, persistence writer, and the panel-identity removal.

### Validation
- Each blocker independently challenged against real code (audits confirmed). Verified read-only on **lab2 (DEB) + lab4 (EL9 RPM)**: `go test ./...` green, `-race` clean (`ConcurrentNoClobber`/`SameIPDedup`), generator→`sysusers` byte-identical, DEB+RPM builds with panel files absent + `logrotate` Requires intact, log-durability shell suite 35/35.
- **PR #710 CI green (58 pass / 3 skip / 0 fail)** incl. gosec + health (after a confined CI-fix: shellcheck single-element loop + gosec G302/G304 on the new lock opens → `0600` + `filepath.Clean`). Post-merge `main` green. Merged squash `b9fc3da4`.

### Post-publish
- Tag/publish after this release-prep merges + `main` CI green. Fleet rollout of the published baseline is separately gated.

---

## [v1.136.1] - 2026-05-27 — exporter exit-2 Phase 2 (surgical scale-cache guard)

**Codename:** `V1_136_1_EXPORTER_EXIT2_PHASE2`
**Scope file:** `AUDIT_190_LIFECYCLE/V1_136_EXPORTER_EXIT2_PHASE2_SCOPE.md`

> **Why:** the v1.136.0 ERR trap did its job — deployed to monitor (official, checksum-verified asset), it pinned the exact intermittent `status=2/INVALIDARGUMENT` on its first occurrence (run #73565). Root cause: `nftban_unified_exporter_collect.sh:642` `_global_scale=$(jq -r '.scale_mode // "NORMAL"' "$_scale_cache" 2>/dev/null)` reading the daemon-written `/run/nftban/set_counts.json` — a mid-write/truncated cache makes `jq` exit non-zero (the in-`jq` default never applies; parse failed first), the unguarded `$(…)` fails, and `set -Eeuo pipefail` aborts the whole run. Hotfix; shell-only; daemon byte-identical to v1.136.0.

### Phase 2 (PR #708, sq `e5cb7395`)
- **Surgical guard** in the `set_counts.json` scale block: a one-time `if jq -e . "$_scale_cache" >/dev/null 2>&1` validity gate now wraps **both** pinned reads (per-set line 638 + global line 642). On a transient invalid/truncated cache the exporter emits the safe default (global scale = `NORMAL`) and skips the per-set rows that cycle instead of aborting; a belt-and-suspenders `|| _global_scale="NORMAL"` covers the rewrite-after-validate race.
- **Strict mode (`set -Eeuo pipefail`) and the v1.136.0 ERR trap are preserved.** Scoped to only this block — no broad sweep.

### Unchanged / invariants
- **No code change beyond the exporter scale block above.** `cmd/nftband` + `cmd/nftban-core` byte-identical to v1.136.0. No installer/`install_state`, schema/metrics-label, portal, or service/timer-unit change. **Schema 1.83.0 frozen.** `nftban_fhs_spec.sh` change is header-version regen only.

### Validation
- PR #708 CI green (50 / 2-skip / 0-fail); post-merge `main` green at `e5cb7395`.
- New `exporter_exit2_phase2_scale_guard_v1361_test.sh` (13/0): truncated/empty/missing-field `set_counts.json` → `NORMAL` with **no non-zero exit** under strict mode; valid cache still yields correct scale. Phase-1 `exporter_exit2_resilience_v136_test.sh` 15/0 intact. shellcheck clean.

### Post-publish
- Deploy v1.136.1 to monitor + bounded watch confirming `nftban-unified-exporter` no longer exits 2 (no abort on a truncated `set_counts.json`) — closes the exporter exit-2 loop.

---

## [v1.136.0] - 2026-05-27 — exporter exit-2 resilience + diagnosability (Phase 1)

**Codename:** `V1_136_EXPORTER_EXIT2_RESILIENCE`
**Scope file:** `AUDIT_190_LIFECYCLE/V1_136_EXPORTER_EXIT2_RESILIENCE_SCOPE.md`

> **Why:** the `nftban-unified-exporter` exits `status=2/INVALIDARGUMENT` intermittently under systemd — a volatile-read command returning 2 under `set -Eeuo pipefail`, completely silent in the journal (no `ERR` trap + pervasive `2>/dev/null`). Pre-existing observability defect (`meta:version=1.39.0`, predates v1.135; v1.135 already classified it auxiliary/non-fatal at the install_state layer so it never DEGRADED installs). This lane is **resilience + observability, not emergency remediation** — the `v1.135.x` hotfix slot stayed HOLD/UNAUTHORIZED. Shell-only; daemon byte-identical to v1.135.0.

### Phase 1 (PR #706, sq `7d0a7998`)
- **`nftban_unified_exporter.sh` — permanent `ERR` trap** placed *after* `set -Eeuo pipefail` (**strict mode preserved**): converts a silent strict-mode abort into a journal line (`rc` + `file:line` + function + failing `$BASH_COMMAND`), then **re-raises the rc** (does not swallow). `errtrace` (`-E`) propagates it into the sourced collect/export functions, so the next intermittent exit-2 **self-pins the exact failing command** for the Phase-2 surgical guard.
- **`nftban_exporter_json_compat.sh` — `_read_stats_json_retry`**: bounded retry that accepts only fully-valid JSON, so a daemon mid-write truncation of `stats.json` is retried instead of dropping the legacy-JSON cycle. Errexit-clean; never `exit 2`.
- **No blind broad guard sweep** (per scope) — the unknown failing read waits for the ERR trap to self-pin in production.

### Unchanged / invariants
- **No code change beyond the exporter scripts above.** `cmd/nftband` + `cmd/nftban-core` byte-identical to v1.135.0. No installer/`install_state`, schema/metrics-label, portal, or service/timer-unit change. **Schema 1.83.0 frozen.** `nftban_fhs_spec.sh` change is header-version regen only.

### Validation
- PR #706 CI green (50 / 2-skip / 0-fail); post-merge `main` green at `7d0a7998`.
- New `exporter_exit2_resilience_v136_test.sh` (15/0): ERR-trap attribution + rc preserved under strict mode; `stats.json` retry valid/missing/truncated/recovers. shellcheck clean.

### Parked / follow-up
- **Phase 2 (post-release dependency):** v1.136.0 release → monitor upgraded → ERR trap live → next exporter exit-2 logs the exact command/line → `OPEN_V1_136_EXPORTER_EXIT2_PHASE2` surgical guard if still needed.
- **Deferred (design-only, later release):** `NFTBAN_EXPORTER_DEBUG` config variable — opt-in *verbose* xtrace (strict mode always kept), self-limiting via a lock/timer watchdog that auto-returns to normal so it can't be left on in production.

---

## [v1.135.0] - 2026-05-27 — install/update-lifecycle correctness (timers + install_state + update-lock + mixed-drift + exporter-settle)

**Codename:** `V135_INSTALL_UPDATE_LIFECYCLE`
**Scope file:** `AUDIT_190_LIFECYCLE/V135_INSTALL_UPDATE_LIFECYCLE_SCOPE.md`

> **Why:** make install/update lifecycle state *truthful* — a critical timer that silently fails to enable must not report COMMITTED; an auxiliary metrics blip must not be reported as a protection failure; and the update path must not leave stale locks or wrongly refuse a cleanly-migrated host. First release since the v1.130/v1.131 arc to change installer Go (`internal/installer/…`) — the daemon/installer binary is **not** byte-identical to v1.134.0.

### Phase 1 — critical-timer assertion + install_state finalization (PR #703, sq `196dd03b`)
- **D-MAINTENANCE-TIMER-SILENT-ENABLE:** a CRITICAL core timer (`nftban-maintenance.timer`) that fails to enable/start now drives `install_state` **DEGRADED** via the new assertion `core_timers_active_or_scheduled_ok`, with the specific timer named in `FAILURE_REASON` — instead of latching COMMITTED on a silent `enableAndStart` warning. `NFTBAN_RECONCILE_CORE_TIMERS=false` is honored as an intentional opt-out (assertion Skips, stays COMMITTED).
- **install_state/FAILURE_REASON finalization:** `state.Transition` gains an empty-reason backstop (no DEGRADED is ever reason-less); `phaseValidate` folds each failing assertion's detail into `FAILURE_REASON`.
- New surface: `Executor.ServiceEnabled()`, `services.CriticalCoreTimers()` + exported `ShouldReconcile`, `validate.ValidateCriticalTimers`/`GatherTimerInputs`. `--repair` resumes at Validate; the assertion accepts enabled-or-active so a manual `systemctl enable --now` satisfies it.

### Phase 2 — update-lifecycle lanes (PR #704, sq `442cd580`)
- **2.1 D-UPDATE-LOCK-LEFT-BEHIND:** `_cmd_update_main` split into a lock wrapper + `_cmd_update_main_locked`; `/run/nftban/update.lock` is released on **every** terminal update path (success / DEGRADED / handled failure) — previously the flock was released on exit but the empty file was left behind (a 2-day stale lock on dns2). `UPDATE_LOCK_FILE` derives from `NFTBAN_RUN_DIR`. Test `cmd_update_lock_cleanup_v135_test.sh` (9/0).
- **2.2 D-UPDATE-MIXED-DRIFT:** `_probe_rpm_owns_all_binaries` / `_probe_dpkg_owns_all_binaries` (a clean-&-complete on-disk ownership signal — the package db owns *every* core binary) added as a third migration-clean unblock in `_detect_install_type`, so a genuinely migrated EL/DEB host with stale source-era history updates through instead of aborting `mixed`. A genuine source-over-package mix (a binary unowned) still stays `mixed` — **no unsafe bypass**. Test `cmd_update_detection_v135_clean_ownership_test.sh` (10/0; v126 detector regression 20/0).
- **2.3 D-EXPORTER-SETTLE-WINDOW:** failed **auxiliary** units (the unified exporter) are classified non-fatal — `IsAuxiliaryUnit` routes them to a new `FailedAuxiliaryUnits` bucket and `failed_units_postinstall_ok` only counts protection units — so a transient `nftban-unified-exporter` exit-2 no longer DEGRADES the install (surfaced as a non-fatal warning), with a bounded settle re-poll in the gatherer. `nftband`/`nftban-core`/tables/validator failures stay **hard**. Tests in `validate/systemd_payload_settle_test.go`.

### Real-host package validation (all PASS, recorded under `AUDIT_190_LIFECYCLE/`)
- **lab2** DEB closing gate on a live **Plesk** host: upgrade → COMMITTED (cleared a real stale exporter-DEGRADED); `mask nftban-maintenance.timer` → DEGRADED naming it → recover → COMMITTED; forced exporter → auxiliary non-fatal. (`V135_PACKAGE_INSTALL_CLOSING_GATE_LAB2_PASS`)
- **monitor** real DEB **upgrade** `v1.131.4 → v1.135.0`: a genuinely-failing exporter at validate-time classified auxiliary/non-fatal in the wild; A/B lock proof (identical `nftban update local` left a stale lock under v1.131.4, **none** under v1.135.0); `install_type=deb` not `mixed`. (`V135_VALIDATE_MONITOR_UPGRADE_PASS`)
- **lab4** AlmaLinux 9.7 / **RPM** / **cPanel**: both the EL **upgrade** AND a genuine **clean reinstall** (`INSTALL_MODE=install`) reached COMMITTED with cPanel panel-survival validated, timer-mask→DEGRADED→recover→COMMITTED, exporter→auxiliary, no stale lock, SSH preserved across the uninstall window. (`V135_VALIDATE_LAB4_CLEAN_RPM_INSTALL_PASS`)
- Coverage spans **DEB + RPM × upgrade + clean-install × Plesk + cPanel + no-panel**.

### Unchanged / invariants
- **Schema 1.83.0 frozen** — no new validator field / metric / Prometheus label / Status-JSON or `install_state` wire key / config key; install payload unchanged beyond the rebuilt binaries.
- Installer/daemon Go **did** change (`internal/installer/…`) → binary not byte-identical to v1.134.0; package-install validation on DEB **and** RPM was the closing gate (done, above).

### Parked / follow-up
- **Non-blocking (NOT a v1.135 regression — exporter script byte-unchanged):** `nftban-unified-exporter` exits 2 intermittently under systemd but exit-0 manually on monitor = pre-existing transient exporter flakiness; v1.135 correctly tolerates it as auxiliary. Parked as a separate investigation lane.

---

## [v1.134.0] - 2026-05-27 — CLI help/code-debt closure (PR-D P3 allowlist + doctest guard + PR-E docs verified)

**Codename:** `V134_0_PR_D_P3_DOCTEST_AND_PR_E_DOCS`
**Scope file:** `AUDIT_190_LIFECYCLE/V134_SCOPE_PR_D_P3_DOCTEST_AND_PR_E_DOCS.md`

> **Why:** closes the original 61-item V129→V131 text/code debt ledger — the P3 alias allowlist, the CI-enforced help/code doctest guard, and a final docs/wiki alignment pass. Doc/UX/test/CI-truth only; no functional/Go/schema change.

### PR-D P3 alias allowlist — Lane 1 (PR #700, sq `5648887a`)
- **D-26 (document):** `health rbl` + `health fhs` are real delegating subcommands → added to `cmd_health.sh` help.
- **D-28 (fix):** `cmd_metrics.sh` error-usage now lists `evidence`/`evidence-json` (matched the main `--help`).
- **Allowlist manifest** `cli/lib/nftban/tests/v134_help_code_alias_allowlist.tsv`: classifies dispatched-but-intentionally-undocumented tokens (D-12..D-30 + guard-surfaced extras) as alias / internal / universal-flag / deprecated / undocumented-subcmd. New `v134_pr_d_p3_alias_allowlist_test.sh` (11/0) — manifest well-formed + every allowlisted token actually dispatched (no phantoms).

### Help/code doctest guard — Lane 2 (PR #701, sq `9fc3dfe1`)
- Rebuilt `v130_subcommand_flag_help_code_test.sh` as a robust single-direction guard: every primary-dispatch token a command accepts must be documented in help, allowlisted, or structural. Unparseable families are SKIPPED (reported, not failed) — no prose-extraction false positives. **67 families PASS, 0 fail, 2 skip** (`health_core` helper, `smoke` passthrough).
- Allowlist extended +10 (`blacklist rm/del/delete/unban`→remove; `health detailed`→diagnostics; `sync full/status/validate`; `portscan restart`→reload/`sync`).
- **CI-enforced** via two new steps in `.github/workflows/ci-architecture.yml` — future help/code drift now fails the build (the structural lock that would have caught D-05..D-11).

### PR-E docs/wiki/README alignment — Lane 3 (verified, no changes)
- `docs/` + `README.md` + the `nftban.wiki` repo carry **no** stale CLI references (`stats top jails`, `emulate --out`, `nftban gui`, `profile select`, sudo/root privilege framing); `nftban gui` removal is already correctly documented (`Deprecations-v190.md`). The v1.132–v1.134 CLI changes were removals + added `--help` coverage the docs never documented in stale form. **Verified-aligned — no doc PR needed.**

### Unchanged / invariants
- **No Go change.** `cmd/nftband` + `cmd/nftban-core` byte-identical to v1.133.0. No install-payload / systemd-unit / polkit-rule / `build/fhs-spec.yaml` change. **Schema 1.83.0 frozen.** `nftban_fhs_spec.sh` change is header-version regen only.

### Parked / carried forward
- **DOC-CANDIDATEs** (allowlisted real subcommands the operator may later document): pro `community`, suricata `stats`/`test`, sync `validate`/`status`, portscan `sync`.
- **v1.135.0** (separate install/update-lifecycle lane, NOT here): D-MAINTENANCE-TIMER-SILENT-ENABLE, D-UPDATE-LOCK-LEFT-BEHIND, D-UPDATE-MIXED-DRIFT, D-EXPORTER-SETTLE-WINDOW, install_state/FAILURE_REASON/remediation finalization (`V135_INSTALL_UPDATE_LIFECYCLE_SCOPE.md`).

### Validation
- PR #700 CI green (50/2-skip/0-fail); PR #701 CI green (50/2-skip/0-fail); post-merge `main` CI green at `5648887a` + `9fc3dfe1`. Local: doctest guard 67/0/2-skip, Lane-1 allowlist guard 11/0, adjacent suites green; `bash -n` clean.

---

## [v1.133.0] - 2026-05-26 — CLI UX/text truth-alignment (PR-B wording + PR-D P2 help/code drift)

**Codename:** `V133_0_PR_B_WORDING_AND_PR_D_P2_HELP_DRIFT`
**Scope file:** `AUDIT_190_LIFECYCLE/V133_SCOPE_PR_B_AND_PR_D_P2.md`

> **Why:** continues the deferred V129 Layer-B / V130 long-tail — operator-facing privilege wording (PR-B) and command-help vs dispatcher drift (PR-D P2). Two separate PRs; UX/doc-truth only, no functional/Go/schema change.

### PR-B — polkit/sudo/raw-permission wording sweep A1–A15 (PR #697, sq `5e7b9b1e`)
- **A1–A11**: replaced "Must be root to <X> services" / "Root privileges required to change mode" / "sudo systemctl …" hints with the canonical `PolicyKit/polkit authorization failed or insufficient privileges (<action>)` across service management, mode change, and daemon-start hints (`nftban_service_control.sh`, `service_control.sh`, `cmd_system.sh`, `nftban_mode.sh`, `cmd_common.sh`). `nftban_mode.sh` JSON sibling left unchanged (already correct).
- **A12–A14**: `nftban_pro` / `cmd_snapshot` / `nftban_report_module` now emit the canonical polkit refusal (rc=1) when non-root **and** the target dir is not writable, instead of leaking a raw `Permission denied` from the redirect.
- **A15**: `get_live_ruleset` strips `(you must be root)` and reframes the `nft` permission error to the polkit/CAP_NET_ADMIN contract (mirrors `internal/validator/validator.go`), preserving the `{"error":…}` JSON shape.
- Tests: new `v133_pr_b_write_guard_refusal_test.sh` (7/0 — deterministic A15 reframe + real non-root behavioral refusal for A12/A13); `v128_polkit_aware_wording_sweep_test.sh` A8/A9 made case-insensitive + new A10 `Must be root` lock (genuine-root `setup/deploy_metrics.sh` requirement allowlisted).

### PR-D P2 — help/code drift D-01, D-03..D-11 (PR #698, sq `45fc005c`)
- **D-01 (remove)**: dropped the dead `nftban gui enable` from the wizard (no `gui` command; web GUI retired) — removed the dead invocation + advertised reference.
- **D-03 (fix example)**: `nftban emulate --out <ip>:<port>` → real `nftban emulate <ip> --port N --direction out` (no `--out` flag exists) in `cmd_port.sh` + `cmd_egress.sh`.
- **D-04 (re-steer)**: examples/menu pointing at the deprecated `nftban profile select` now use `nftban wizard` (the live path) in `cmd_ddos.sh`, `cmd_portscan.sh`, `cmd_menu.sh`.
- **D-05..D-11 (document)**: added the dispatched-but-undocumented subcommands to help — `status pending/queue`; `rbl config/stats/test`; `feeds config/stats/test`; `botscan stats/config` (+ error fallback); `geoban stats/test`; `login config/install`; `module duplicates`.
- **D-02** was already resolved in v1.132.0 PR-C (`fail2ban`→`login` in `cmd_test.sh`).
- Tests: new `v133_pr_d_p2_help_code_drift_test.sh` (31/0 — each subcommand documented + stale refs `nftban gui` / `emulate --out` / `nftban profile select` gone tree-wide).

### Unchanged / invariants
- **Shell-only — no Go change.** `cmd/nftband` and `cmd/nftban-core` byte-identical to v1.132.0. No install-payload, systemd-unit, polkit-rule, or `build/fhs-spec.yaml` change. **Schema 1.83.0 frozen.** `nftban_fhs_spec.sh` change is header-version regen only (FHS body byte-unchanged).

### Validation
- PR #697 CI green (50/2-skip/0-fail); PR #698 CI green (50/2-skip/0-fail); post-merge `main` CI green at `5e7b9b1e` then `45fc005c`. Local: PR-B guard 7/0, PR-D-P2 guard 31/0, v128 wording, v132 PR-C 29/0, shim 17/0; `bash -n` + FHS `--check` clean.

### Carried to v1.134.0 (not in this release)
- PR-D **P3** alias allowlist (D-12..D-30) + the full subcommand/flag **doctest guard** (untracked `v130_subcommand_flag_help_code_test.sh`); then **PR-E** docs/wiki/README alignment (last).

---

## [v1.132.0] - 2026-05-26 — CLI behavior-truth alignment (PR-C; C1/C2/C3/C5/C7/C8)

**Codename:** `V132_0_PR_C_BEHAVIOR_TRUTH`
**Scope file:** `AUDIT_190_LIFECYCLE/V129_TILL_V131_TEXT_CODE_DEBT_LEDGER_AND_PLAN.md`

> **Why:** the deferred V129 Layer-B / V130 PR-C long-tail — places where the displayed CLI text or an exit code disagreed with what the code actually does. Truth-alignment only; no feature added.

### Fixed (PR #695, sq `486bc12b`)
- **C1 `version --json`**: replaced the unconditional `# NFTBAN_CMD_EXIT: version` sentinel echo with the debug-gated `nftban_cmd_exit` helper, so `nftban version --json` emits valid JSON (was JSON followed by a trailing non-JSON sentinel line).
- **C2 `flush --json`**: removed the advertised-but-unimplemented `--json` flag, its dead parse branch, and the unused `json_mode` variable — help now matches behavior.
- **C3 `flush` exit codes**: return `rc=2` for an invalid target/option (matches the documented "2 = unsupported target / invalid argument"); removed the documented-but-nonexistent `rc=3` PolicyKit line (flush has no polkit-denial branch).
- **C5 `stats top jails` → `filters`**: the fail2ban-era `jails` top-type called an undefined function (`nftban_stats_top_jails`) and the dashboard JSON fed both `top_jails` and `top_filters` the same always-empty value. Replaced with a working `filters` top-type backed by the real `nftban_stats_top_sources`; removed the dead double-feed. **This reverses the earlier deliberate "keep top_jails names" decision** (recorded in a prior CHANGELOG entry) — the names are corrected because the backing function never existed. Also removed adjacent stale fail2ban references: the bogus `nftban migrate fail2ban` remediation (no such command), the "Protected with fail2ban" setup claim, the false "fail2ban removed in v2.1" note, the removed fail2ban test-module entry, and the `stats recent` "Jail:" output label (→ "Source:").
- **C7 `firewall validate --strict`**: documented the reachable exit codes `1` (structural validation failed) and `40` (validator binary missing / environment error), previously undocumented.
- **C8 `validate` exit-code contract**: the shared `validate_structure` shim returned `2` for a missing/empty/unexpected validator, colliding with the documented "2 = DOWN". It now returns `3` ("validator binary crashed or was unreachable") for those cases and clamps any unexpected validator exit to `3`, so `rc=2` means DOWN only — matching the documented 0/1/2/3 contract. `nftban validate` is the shim's sole runtime caller (`cmd_firewall.sh` no longer uses it) → zero cross-command impact.

### Unchanged / invariants
- **Shell-only — no Go change.** `cmd/nftband` and `cmd/nftban-core` are byte-identical to v1.131.4. No install-payload, systemd-unit, polkit-rule, or `build/fhs-spec.yaml` change. **Schema 1.83.0 frozen.** `nftban_fhs_spec.sh` change is header-version regen only (FHS body byte-unchanged).
- **Docs/wiki verified clean** — no `stats top jails` references and no stale fail2ban claims existed in `docs/`, `README.md`, or the wiki; the staleness was code-only.

### Tests
- New `cli/lib/nftban/tests/v132_pr_c_behavior_truth_test.sh` (29/0) — static behavior-truth guard covering all six items + the stale-fail2ban sweep.
- `test_validate_structure_is_shim.sh` N9 assertion flipped to `return 3` (17/0).

### Validation
- PR #695 CI green (51 success / 2 skip / 0 fail — DEB×4 + RPM×4 build+install, Runtime Truth DEB+EL9, ShellCheck, Shell Quality, parity, payload resolution). Post-merge `main` CI green at `486bc12b`. Local: new guard 29/0, shim 17/0, v129 PR-C / v130 polkit / v131 PR-A / PR-A.2 all green; `bash -n` clean.
- Shell-only release (no payload/polkit/systemd change; daemon byte-identical) → no new install-surface risk; standard package-install smoke applies (no D13-style gate).

---

## [v1.131.4] - 2026-05-26 — installer DEGRADED-state correctness hotfix (supersedes v1.131.3)

**Codename:** `V131_4_D13_PAYLOAD_INVENTORY_AND_DEGRADED_REMEDIATION_FIX`
**Scope file:** `AUDIT_190_LIFECYCLE/V131_3_DEGRADED_ROOT_CAUSE_CORRECTION.md`

> **Why:** live fleet validation of v1.131.3 found **every install latches `install_state=DEGRADED`** even though firewall protection and D13 itself work. Root cause (confirmed on lab4 with a healthy exporter, still DEGRADED): the D13 unit `nftban-firewall-validate.service` (`ExecStart=/usr/lib/nftban/helpers/firewall_validate_run.sh`, added in #687/#689) referenced a path that was never added to the installer's payload-inventory allow-list, so `systemd_payload_inventory_ok` flagged it "unknown". The `nftban-unified-exporter` exit-2 blip is coincidental/self-healing and is **not** the latch.

### Fixed
- **D-D13-PAYLOAD-INVENTORY-MISS** (PR #693, sq `7d3eec96`): added `/usr/lib/nftban/helpers/firewall_validate_run.sh` to `defaultInventoryPaths()` in `internal/installer/validate/assertions.go` so `systemd_payload_inventory_ok` passes and installs carrying the D13 unit land **COMMITTED**, not DEGRADED.
- **D-INSTALL-STATE-BLANK-REASON**: `state.Transition()` now preserves the current failing-assertion reason on a DEGRADED transition (it was cleared by `applyTerminalHygiene`, which is correct only for the clean COMMITTED terminal) — so `FAILURE_REASON=` is populated in `install_state` and `report()` renders the `Issues:` line.
- **D-DEGRADED-REMEDIATION-CMD-BROKEN**: the DEGRADED remediation no longer prints the bare `nftban-installer --repair` (the binary lives under `/usr/lib/nftban/bin` and is not on the operator's `$PATH` → `command not found`) and **never** prepends `sudo` (operator-facing text follows the nftban-group + PolicyKit/polkit wording policy). It now prints the bare full path `/usr/lib/nftban/bin/nftban-installer --repair` across the Go installer `report()`, the RPM `%post`, the DEB `postinst`, and the `nftban update` CLI.

### Unchanged / invariants
- **No functional firewall/daemon change**; no `build/fhs-spec.yaml` / systemd-unit / polkit-rule change; **no `CAP_CHOWN`**; `ProtectSystem=strict` + `CapabilityBoundingSet=CAP_NET_ADMIN` preserved; D13 setgid `2750` handoff unchanged. **Schema 1.83.0 frozen.** `nftban_fhs_spec.sh` change is header-version regen only (FHS body byte-unchanged).

### Tests
- `internal/installer/validate/systemd_payload_test.go`: `TestSystemdPayload_D13ValidateUnit_InDefaultInventory` — locks the allow-list entry + a behavioral `PAYLOAD-INVENTORY-001` pass for the real validate-unit shape.
- `internal/installer/state/file_test.go`: `TestTransitionToDegradedPreservesReason` — DEGRADED keeps `FailureReason`; the existing COMMITTED-clears-reason test still passes.

### Validation
- PR #693 CI green (61 success / 3 skip / 0 fail) — incl. `Build & Test`, `CodeQL Analysis (Go)`, `Validate systemd ExecStart payload resolution`, `Validate binary consistency (RPM vs DEB)`. Pre-merge lab2 (Go 1.25.0): `go build`/`go vet`/`go test -race` green, no regression.
- **Package-install validation PENDING (the gate that closes this):** `EXECUTE_V1_131_4_PACKAGE_INSTALL_VALIDATION` must upgrade a v1.131.3 host stuck `DEGRADED` to **`COMMITTED`** (payload-inventory passes; no unknown ExecStart path; D13 still rc=0 + `^Validator Status:` + `last.json root:nftban 0640` + handoff `2750`; nftband active; ip/ip6 nftban tables present; update lock not left active). **Fleet rollout paused at 4/7 until v1.131.4 validates.**

---

## [v1.131.3] - 2026-05-26 — D13 setgid group-ownership repair (supersedes v1.131.2)

**Codename:** `V131_3_D13_SETGID_GROUP_OWNERSHIP_FIX`
**Scope file:** `AUDIT_190_LIFECYCLE/V131_0_PACKAGE_INSTALL_VALIDATION_REPORT.md`

> **Third and (intended) final D13 layer.** v1.131.1 moved the validator output from journalctl to a `/run` file (blocked by sandbox). v1.131.2 fixed the sandbox *write* (file now created) but the file landed `root:root 0640` — unreadable by the nftban group — so the operator still saw banner-only. v1.131.3 fixes the *group ownership*. **Fleet: skip v1.131.0/.1/.2; install v1.131.3 only after both-family validation.**

### Fixed
- **D13** (group-ownership layer; PR #691, sq `84460198`): the handoff dir `/run/nftban/firewall-validate` is now **setgid** (`2750 root nftban`) — in both the tmpfiles entry (regenerated from `build/fhs-spec.yaml`) and the `+ExecStartPre=/usr/bin/install -d -o root -g nftban -m 2750 …`. The setgid bit makes the wrapper-written `last.json` inherit group `nftban` automatically, so it becomes **`root:nftban 0640`** and nftban-group operators can read it → `^Validator Status:` renders. **No `CAP_CHOWN` added** (the unit's `chgrp` fails under `CapabilityBoundingSet=CAP_NET_ADMIN`, which is exactly why setgid — not a capability grant — is the fix).

### Unchanged / invariants
- `CapabilityBoundingSet=CAP_NET_ADMIN` only (no CAP_CHOWN); `ProtectSystem=strict`; narrow `ReadWritePaths=/run/nftban/firewall-validate` (no broad form); wrapper logic untouched (rc preserved, stale cleanup, `chmod 0640`, file-first CLI read); no pkexec; no systemd-journal/adm; **no polkit rule or path change. Schema 1.83.0 frozen.**

### Tests
- New `v131_3_d13_setgid_group_ownership_test.sh`: asserts the `2750` setgid dir (tmpfiles + ExecStartPre) and a **capability-faithful** behavioral check — runs the wrapper under `systemd-run --property=CapabilityBoundingSet=CAP_NET_ADMIN` and proves `last.json` inherits group `nftban` (mode 0640) **without** chgrp (SKIPs as non-root in CI — the real proof is lab validation). Operator-visibility uses exact `^Validator Status:`; loose `IDLE|PROTECTED` banned. Local suites green; shellcheck + FHS `--check` clean.

### Validation
- **PENDING (the gate that closes D13):** `EXECUTE_V1_131_3_PACKAGE_INSTALL_VALIDATION` — lab2 DEB + lab4 RPM. **Pass = non-root nftban-group user gets rc=0 + stdout `^Validator Status:`, `last.json` is `root:nftban 0640`, `/run/nftban` stays `nftban:nftban`, root path renders — on BOTH families.** D13 is NOT closed until this passes.

### Release-prep note
- Only release-prep files touched: `VERSION` (1.131.2 → 1.131.3), `STATUS.md`, `CHANGELOG.md`, `cli/lib/nftban/core/nftban_fhs_spec.sh` (header-version regen only).

---

## [v1.131.2] - 2026-05-26 — D13 sandbox-write repair (supersedes v1.131.1's ineffective fix)

**Codename:** `V131_2_D13_SANDBOX_WRITE_REPAIR`
**Scope file:** `AUDIT_190_LIFECYCLE/V131_2_D13_SANDBOX_WRITE_REPAIR_SCOPE.md`

> **v1.131.1's D13 fix did not work under the real systemd unit.** Live package validation proved the `firewall_validate_run.sh` wrapper — correct standalone — failed under `nftban-firewall-validate.service` because `ProtectSystem=strict` (with no write allowance) makes `/run` read-only: the write failed (`ExecMainStatus=1`), `last.json` was never created, and the nftban-group operator still saw banner-only output. (The v1.131.1 PASS was a false positive: a loose `IDLE|PROTECTED` grep matched a banner word, and the behavioral test ran with `NFTBAN_RUN_DIR=/tmp` outside the sandbox.) **Fleet: skip v1.131.0 AND v1.131.1; install v1.131.2 only after both-family validation.**

### Fixed
- **D13** (`D13_OPTION_C_JOURNAL_READ_PERMISSION_GAP` → sandbox-write follow-on; PR #689, sq `6ff6f605`): the Option C handoff file now actually gets written under the hardened unit. Changes:
  - tmpfiles entry (regenerated from `build/fhs-spec.yaml`): `d /run/nftban/firewall-validate 0750 root nftban -` creates the handoff dir with group-readable perms.
  - `nftban-firewall-validate.service`: **narrow** `ReadWritePaths=/run/nftban/firewall-validate` added while **keeping `ProtectSystem=strict`** (not the broad `/run/nftban`, which would expose the daemon socket; not `RuntimeDirectory=nftban/...`, which would re-chown `/run/nftban` off `nftban:nftban` and break the daemon).
  - `+`-prefixed `ExecStartPre=+/usr/bin/install -d -o root -g nftban -m 0750 /run/nftban/firewall-validate` runs un-sandboxed to guarantee the subdir exists per-start (since `ReadWritePaths=<subdir>` requires the path to pre-exist).
  - `firewall_validate_run.sh`: `mkdir` made best-effort (`|| true`); rc preservation, `root:nftban 0640` output, stale cleanup, and stdout journal copy all unchanged.

### Tests
- New `v131_2_d13_sandbox_write_repair_test.sh`: **sandbox-aware** behavioral assertion runs the wrapper under an actual `systemd-run --property=ProtectSystem=strict` with/without `ReadWritePaths`, proving the handoff file is/is-not created (the assertion class that would have caught the v1.131.1 miss; SKIPs as non-root in CI — the real proof is lab package validation). Operator-visibility checks use exact `^Validator Status:` matching; loose `IDLE|PROTECTED` grep is banned. `v131_1_d13_…` test updated to require the unit's write allowance. Local suites green; shellcheck + FHS `--check` clean.

### Unchanged / invariants
- **No pkexec; nftban group NOT added to systemd-journal/adm; no polkit rule or path change. `ProtectSystem=strict` preserved. Schema 1.83.0 frozen.**

### Validation
- **PENDING (the gate that matters):** `EXECUTE_V1_131_2_PACKAGE_INSTALL_VALIDATION` — lab2 DEB + lab4 RPM. **Pass = non-root nftban-group user gets rc=0 + stdout `^Validator Status:`, `/run/nftban/firewall-validate/last.json` is `root:nftban 0640`, `/run/nftban` stays `nftban:nftban`, root path still renders — on BOTH families.** D13 is NOT closed until this passes.

### Release-prep note
- Only release-prep files touched: `VERSION` (1.131.1 → 1.131.2), `STATUS.md`, `CHANGELOG.md`, `cli/lib/nftban/core/nftban_fhs_spec.sh` (header-version regen only).

---

## [v1.131.1] - 2026-05-26 — D13 hotfix: Option C validator output for nftban-group operators

**Codename:** `V131_1_D13_OPTION_C_OUTPUT_CAPTURE_FIX`
**Scope file:** `AUDIT_190_LIFECYCLE/V131_0_PACKAGE_INSTALL_VALIDATION_REPORT.md`

> **Hotfix on v1.131.0.** v1.131.0 shipped the Option C validate service but its operator-facing output path was incomplete after real package install. The **fleet should skip v1.131.0 and move directly to v1.131.1** after validation. No production host had v1.131.0 installed, so D13 had zero production exposure.

### Fixed
- **D13** (`D13_OPTION_C_JOURNAL_READ_PERMISSION_GAP`, confirmed cross-family DEB+RPM): `nftban firewall validate` for a non-root `nftban`-group operator returned rc=0 and the `nftban-firewall-validate.service` ran correctly, but the CLI read the validator JSON from `journalctl`, which the operator cannot read (not a `systemd-journal`/`adm` member) → **banner-only output** for the exact audience Option C targets. (Distinct from the D10 timing race, which was real-for-root and already fixed.) Fix (PR #687, sq `76b181a7`):
  - New `cli/lib/nftban/helpers/firewall_validate_run.sh` wrapper (the unit `ExecStart` target) runs `nftban-validate --json` as root+`CAP_NET_ADMIN`, then writes the JSON to **`/run/nftban/firewall-validate/last.json`** (owner `root:nftban`, mode `0640`, pre-run stale cleanup, validator exit code preserved, JSON also echoed to stdout for the root/audit journal copy).
  - `cli/lib/nftban/cli/cmd_firewall.sh` now reads that file as the **primary** source; the `journalctl` read is demoted to a last-resort root fallback only.
  - **No pkexec; nftban group NOT added to systemd-journal/adm; no polkit rule or path change.** Family-specific polkit install paths preserved (DEB `/usr/share/polkit-1/rules.d/`, RPM `/etc/polkit-1/rules.d/`) — see `D13_FHS_PARITY_NOTE` (DEB/RPM FHS layout is identical; D13 was a design gap, not path drift).

### Unchanged / invariants
- **Schema 1.83.0 frozen** — no new validator field, metric, Prometheus label, Status JSON key, `install_state` field, nftables set/chain/table, or config key. The wrapper is package-owned (auto-staged via the existing `cli/lib/nftban/helpers` glob + RPM/DEB `cp -r`); no payload/spec edit.

### Validation
- Local suites green: D13 test 16/16; `v130_polkit_validate_service_test.sh` re-pointed to the new file-handoff contract 28/28; V131-sweep 6/6; V131-PR-A 15/15; V129 17/17. `bash -n` + shellcheck clean.
- **PENDING (required before fully-shipped):** `EXECUTE_V1_131_1_PACKAGE_INSTALL_VALIDATION` — lab2 DEB → lab4 RPM. **Pass condition: a non-root `nftban`-group user sees `Validator Status` on both families.**

### Release-prep note
- Only release-prep files touched: `VERSION` (1.131.0 → 1.131.1), `STATUS.md`, `CHANGELOG.md`, `cli/lib/nftban/core/nftban_fhs_spec.sh` (header-version regen only; FHS body byte-unchanged). No functional code change in release-prep.

---

## [v1.131.0] - 2026-05-25 — post-v1.129 defect-fix bundle (V130 + V131 lanes; v1.130 never tagged)

**Codename:** `V131_POST_V129_DEFECT_FIX_BUNDLE`
**Scope files:** `AUDIT_190_LIFECYCLE/V130_*`, `AUDIT_190_LIFECYCLE/V131_*`

> **Why v1.131.0 and not v1.130.0:** `main` accumulated both "V130"-labeled work (`#682`, `#683`) and "V131"-labeled work (`#684`, `#685`) after the `v1.129.0` tag with no release cut in between. **v1.130.0 was never tagged.** Rather than retroactively tag a confusing v1.130.0, all four PRs are folded into this single `v1.131.0` release. There is no separate v1.130.0 GitHub release or git tag.

### Added
- **`nftban-firewall-validate.service`** — a new oneshot systemd unit performing read-only nftables validation while holding `CAP_NET_ADMIN`, so `nftban`-group operators can run `nftban firewall validate` without root (PR #682, D6.A polkit Option C). Adds a corresponding `allowedUnits[]` entry to `packaging/polkit-1/rules.d/10-nftban-systemd.rules`. **This release changes the install payload + polkit surface** (new systemd unit + polkit rule entry) — unlike v1.127/v1.128/v1.129 it is NOT a no-op packaging release.

### Fixed
- **D6.A** PolicyKit architecture gap for read-only firewall validation — closed via the polkit-authorized validate service above; `internal/validator/validator.go` remediation text now references the real unit (PR #682, sq `090d73b3`).
- **D10** `nftban firewall validate` showed empty output despite rc=0 — `cmd_firewall.sh` journalctl read now uses a bounded retry loop to survive the journald async-write race (PR #683, sq `c543fc3a`).
- **D11** `nftban-firewall-validate.service` rate-limit keys were silently ignored — `StartLimitIntervalSec`/`StartLimitBurst` moved from `[Service]` to `[Unit]` (systemd 240+ requirement) (PR #683).
- **CB-1** `cmd_blacklist.sh` arithmetic crash on zero-match count; **CB-2** `nftban_report_fhs.sh` undeclared associative array caused `/etc/nftban`-as-arithmetic syntax error; **CB-3** `cmd_selftest.sh` printf/count fallback (two occurrences); **CB-4** `tests/selftest.sh` trace-path `Permission denied` leak for non-root operators, now falls back to a per-user path (PR #684, sq `18637c45`).
- **Double-zero count-fallback bug class** — `VAR=$(... grep -c ... || echo "0")` (and the unquoted `|| echo 0`) produced `0\n0` on no-match, crashing `$((...))` arithmetic and `printf %d`. Swept ~22 files to the safe idiom `|| true` + `${var:-0}`, hoisted one arithmetic-inline `grep -c`, and removed a duplicate fallback line. Both quoted and unquoted variants, including quoted sites whose grep pattern itself contains a pipe (PR #685, sq `488058ad`). A new regression guard (`cli/lib/nftban/tests/v131_pr_a_2_double_zero_sweep_test.sh`) detects all four variants and forbids `grep -c` command-substitution directly inside `$((...))`.

### Unchanged / invariants
- **Schema 1.83.0 frozen** — no new validator field, metric, Prometheus label, Status JSON key, `install_state` JSON field, nftables set/chain/table, or config key. (The freeze covers wire-format/metrics/config keys; v1.131.0 does add a systemd unit + polkit rule entry, which the freeze does not cover.)

### Validation
- Per-PR CI green on #682/#683/#684/#685; post-merge `main` CI green at `488058ad`; local suites green (sweep guard 6/6, V131 PR-A 15/15, V130 28/28, V129 17/17, V128 PR-A 23/23, V127 UX-2 40/40); `bash -n` and shellcheck clean across changed files.
- **PENDING (required before declaring fully shipped):** `EXECUTE_V1_131_0_PACKAGE_INSTALL_VALIDATION` — package-install validation on lab2 (DEB) then one RPM lab, confirming the new `nftban-firewall-validate.service` installs, the polkit `allowedUnits[]` entry is present, maintainer-script cleanup covers the new unit, validate works as an `nftban`-group user, D10/D11 behave, and the double-zero guard passes from the installed tree.

### Release-prep note
- Only release-prep files touched in the release-prep PR: `VERSION` (1.129.0 → 1.131.0), `STATUS.md`, `CHANGELOG.md`, and `cli/lib/nftban/core/nftban_fhs_spec.sh` (header-version regen only; FHS path-table body byte-unchanged). No functional code change in release-prep.

---

## [v1.129.0] - 2026-05-24 — V129 deep CLI execution/text/log correlation for the §9 representative command battery

**Codename:** `V129_DEEP_CLI_EXECUTION_TEXT_LOG_CORRELATION`
**Scope file:** `AUDIT_190_LIFECYCLE/V129_DEEP_CLI_EXECUTION_TEXT_LOG_CORRELATION_SCOPE.md`
**Closure record:** `AUDIT_190_LIFECYCLE/V129_FINAL_CROSSCHECK_SUMMARY.md`

### What v1.129 set out to do

A 3-layer (execution + text + log/state) cross-family validation of the CLI on real DEB + RPM hosts, scoped to the representative §9 command battery. The intent: surface behavioral defects that static audit alone cannot catch, fix the cross-family ones, and reverify on real packages.

### Lanes shipped (PR-A → PR-B → PR-C → PR-D, in strict order)

- **PR-A — static extractor + base-state (workspace-only, no repo PR).** Produced 8 matrices/reports under `AUDIT_190_LIFECYCLE/V129_*`: `BASE_STATE.md`, `COMMAND_EXECUTION_MATRIX.tsv` (39 rows, §9 battery), `CLI_REGISTRY_CROSSCHECK.md`, `REGISTRY_TO_CODE_MATRIX.tsv`, `REGISTRY_TO_HELP_MATRIX.tsv`, `HELP_TO_WIKI_MATRIX.tsv`, `EXIT_CODE_TRUTH_MATRIX.tsv`, `OPERATOR_CORRECTION_REGRESSION_SEEDS_REPORT.md` (10 seeds, all static-PASS).
- **PR-B — lab executor harness (evidence-only).** Ran the 32-case §9 representative battery on **lab2 (DEB, Ubuntu 24.04 + plesk)**, **dns2 (RPM-el9, CentOS Stream 9 + DirectAdmin)**, and **srv1 (RPM-el10, CentOS Stream 10 + DirectAdmin)** as the `nftban-test` user (member of the `nftban` group). Result: 31/32 exit-code parity across families (the single divergence is `firewall validate --strict` which is host-state-dependent: lab2 has UFW active → rc=20 conflict path; RPM hosts have no UFW). 7 defects classified cross-family. **3 of 10 operator-correction regression seeds failed at runtime despite static PASS**: C-1 (config rc), C-3 (well-known dry-run guard), C-8 (polkit-aware wording). Evidence root: `V129_CLI_EXECUTION_TEXT_LOG_EVIDENCE/{lab2-deb,dns2-rpm,srv1-rpm}/`.
- **PR-C — fix lane (PR [#680](https://github.com/itcmsgr/nftban/pull/680) sq `21ba927d`).** Closed 6 cross-family defects in 8 files (+350/-31):
  - **D1 (P1)** — `nftban version --json` emitted no JSON + `NFTBAN_GUI_VERSION: unbound variable`. V127 UX-1 1.3 removed the GUI/API rows from `lib/version.sh` but the JSON heredoc at `cli/lib/nftban/cli/cmd_version.sh:213-218` still referenced them. Dropped the `gui`/`api` keys to match the post-V127-UX-1 component set.
  - **D4 (P1)** — `nftban health --verbose` returned rc=1 with `Unknown health command: --verbose` because the dispatcher consumed `--verbose` as subcommand. Added a case-block in `cli/lib/nftban/cli/cmd_health.sh` so `--verbose` / `-v` / `--json` as first arg route to the default `check` subcommand and remain visible to the existing flag loop.
  - **D5 — DOCUMENTED.** Static-audit verification confirmed V127 UX-1 1.9 changed only the stderr discipline, **NOT** the exit code — `nftban_config.sh:209` explicitly comments `Returns 1 (unchanged) for nonzero rc`. The PR-A matrix prediction of rc=2 was wrong. PR-C added an `EXIT CODES` block to `cli/lib/nftban/cli/cmd_config.sh` `show_usage` so operators see the rc=1 contract via `nftban config help`.
  - **D6.B shell wording (P1)** — the validator's wrapper at `internal/validator/validator.go::ValidateKernel` concatenated nft's upstream stderr verbatim, leaking `(you must be root)` and violating the V128 PR-A.1 polkit-aware wording policy. On permission-denied errors (`Operation not permitted` / `permission denied`), the patch strips the `(you must be root)` substring and substitutes a polkit/capability-aware `Remediation` that mentions `CAP_NET_ADMIN` and is honest about the fact that polkit does not currently authorize direct nft access for the nftban group. **Note:** shell-side wording is fixed in this release; **Go-side end-to-end runtime verification activates when `nftban-validate` is rebuilt by the v1.129.0 package-build cycle**.
  - **D7 (P0 CRITICAL) — `nftban ban 8.8.8.8 --dry-run` well-known guard bypass.** Root cause: the V127 UX-2 guard condition at `cli/lib/nftban/cli/cmd_ban.sh` was `[[ "$auto_confirm" != "true" && "$dry_run" != "true" ]]` — dry-run silently bypassed the refusal branch, so `nftban ban 8.8.8.8 --dry-run` returned rc=0 with `[DRY-RUN] Would ban IP: 8.8.8.8 ...` — mis-confirming what the live command would do. The corrected condition is `auto_confirm`-only: dry-run is **also** refused unless `--yes` is explicitly set. The `--yes` override still produces a dry-run preview (with explicit override acknowledgement on stderr).
  - **D8 (P2, RPM-revealed)** — `nftban firewall validate --strict` could print `STRICT PREFLIGHT: PASSED / NFTBan is sole firewall authority - enforce mode OK` while returning rc=1 (the structural validator failed but strict-mode's own conflict checks all passed). Added a `structural_ok` 2nd-arg to `_firewall_validate_strict` in `cli/lib/nftban/cli/cmd_firewall.sh` and emit `STRICT PREFLIGHT: NOT VERIFIED (see Validator Status above) / Conflict checks passed, but the structural validator could not confirm ruleset truth.` when the structural validator did not pass — operator-visible text now agrees with the exit code.
  - **Tests:** new `cli/lib/nftban/tests/v129_pr_c_runtime_defect_fixes_test.sh` — 17 deterministic assertions covering all 6 defects (17/17 PASS). Updated `cli/lib/nftban/tests/v127_ux2_well_known_test.sh` assertion 1.7 (previously encoded the D7 bug as a feature; now reflects the V129 PR-C corrected `auto_confirm`-only condition). Adjacent V128 PR-A polkit wording sweep + V128 PR-D doc clarity audit + V127 UX-2 well-known guard all green.
- **PR-D — runtime re-verify + crosscheck closure (workspace-only, no repo PR).** Ran the 13-case post-merge battery on lab2 + dns2 + srv1 via lib-dir overlay (`NFTBAN_LIB_DIR=/tmp/v129-prd-lib` containing a copy of `/usr/lib/nftban` overlaid with the 5 patched `cmd_*.sh` files; production `/usr/lib/nftban` untouched; temp cleaned post-run). Result: **D1, D4, D7, D8 → RUNTIME-VERIFIED cross-family ✓; D5 → DOCUMENTED ✓; D6.B shell-side → VERIFIED ✓ + Go-side → PENDING-PACKAGE-BUILD; D6.A → out of PR-C scope, deferred to v1.130+; D7 P0 → CLOSED cross-family** with the `--yes` override path also verified.

### Binary impact

- **`cmd/nftban-core` differs from v1.128.0** in one localized addition at `internal/validator/validator.go::ValidateKernel`: a permission-denied branch that scrubs the upstream `(you must be root)` substring and substitutes a `CAP_NET_ADMIN`-aware `Remediation`. Function signature unchanged; capability check logic unchanged; non-permission code paths unchanged.
- **`cmd/nftband` byte-identical to v1.128.0.**
- The five `cli/lib/nftban/cli/cmd_*.sh` shell files (`cmd_ban.sh`, `cmd_config.sh`, `cmd_firewall.sh`, `cmd_health.sh`, `cmd_version.sh`) are CLI dispatcher artifacts installed under `/usr/lib/nftban/cli/` — packaged, not compiled.

### Schema / wire-format

**Schema 1.83.0 remains frozen** UNCONDITIONALLY. No new validator field, no new metric, no new Prometheus label, no Status JSON wire-format key, no new `install_state` JSON field, no new nftables kernel set / chain / table name, no new config key, no new systemd unit, no packaging behavior change.

### Limitations — honest scope of v1.129

This release validates the **representative §9 command battery only** (32 cases × 3 hosts). The following were **NOT** in the authorized v1.129 scope and are explicitly NOT claimed as covered by this release:

- **All 77 `cmd_*.sh` files were NOT runtime-verified.** The long-tail (~45 additional commands beyond the §9 set) has zero runtime evidence in this release.
- **Full subcommand + flag-level help/code correlation is NOT complete.** v1.128 PR-B covered top-level command correlation; v1.129 did not extend to subcommand/flag-level doctest.
- **Wiki + docs/ + README runtime alignment is NOT complete.** v1.128 PR-C handled wiki statically; no v1.129 runtime audit of wiki/docs/README CLI examples.
- **D6.A polkit architecture expansion is NOT addressed.** Whether to extend the polkit rules to cover direct `nft` access (e.g., via `pkexec`) vs. document the gap honestly is a design decision deferred to v1.130+.
- **Live mutating D7 confirmation NOT performed.** The bypass class is closed via the corrected dry-run behavior + the deterministic regression test; the `CONFIRM_D7_WITH_LIVE_TEST` gate (live `nftban ban 8.8.8.8` with cleanup) was never opened.
- **D7 log/state-write footprint NOT probed.** The `VERIFY_D7_LOG_STATE_WRITE_FOOTPRINT` gate (read-only check of banlog / blacklist / nft set state) was never opened.
- **Operator-correction regression seeds C-2 (live well-known ban) and C-9 (mutating preflight) were NOT run** — mutating-live, deferred.

### Out of scope (for v1.129.0)

- No package/systemd/polkit-rule behavior changes (the polkit authority architecture is preserved; only operator-facing wording about it changes; the D6.B Remediation now correctly states the polkit-vs-CAP_NET_ADMIN reality for direct nft access)
- No metrics/portal/schema drift
- No new commands or aliases
- No dispatcher routing / completion / typo handler infrastructure changes (V128 PR-B's canonical-list correction stands; v1.129 did not add or remove entries)
- No `commands.registry.yml` or `scripts/generate-help.sh` change
- No host contact during release-prep construction (only allowed files touched: `VERSION`, `STATUS.md`, `CHANGELOG.md`, `cli/lib/nftban/core/nftban_fhs_spec.sh` — the last is header-version regen only; FHS path-table body byte-unchanged because `build/fhs-spec.yaml` is byte-equal across V129 arc)
- No v1.128.1 hotfix opened (PR-C closes all P0/P1 from PR-B; v1.128.1 slot remains latent)

### Carry-forward to v1.130 (filed as backlog; each separately authorized)

- D6.A polkit architecture design (extend polkit rules to cover direct nft access via pkexec, OR document the gap honestly)
- D2 status help exit-code discoverability (P3 optional polish; surface `0/1/2 = PROTECTED/DEGRADED/DOWN` contract in `nftban status help`)
- D6.B Go-side end-to-end runtime verification on lab2 + dns2 + srv1 (activates automatically with this release's `nftban-validate` rebuild; PR-D shell-side verification is locked, Go-side will be observable on package install)
- Optional long-tail 77-command runtime battery (extend §9 coverage to the ~45 non-representative commands)
- Optional subcommand/flag-level help/code doctest correlation (the deeper class deferred from v1.128 PR-B)
- Optional wiki/docs/README runtime CLI text alignment audit (runtime equivalent of v1.128 PR-C's static sweep)
- Optional D7 live mutating confirmation + log/state-write footprint probe

### Hotfix slot

v1.129.x hotfix slot **not authorized** (latent reservation only — opens only if a v1.129.0 defect surfaces).

---

## [v1.128.0] - 2026-05-24 — V128 CLI text authority alignment release

**Codename:** `V128_CLI_TEXT_AUTHORITY_ALIGNMENT`
**Scope file:** `AUDIT_190_LIFECYCLE/V128_CLI_TEXT_AUTHORITY_ALIGNMENT_SCOPE.md`

### What's new — canonical authority statement now enforced

```
Members of the nftban group can run supported NFTBan privileged operations
through PolicyKit/polkit authorization rules.
```

This is the operator model. Code-audited against `packaging/polkit-1/rules.d/10-nftban-systemd.rules` (`isInGroup("nftban")`) and `install/systemd/sysusers.d/nftban.conf` (`g nftban -`). The nftban group + polkit IS the authorization path. Root remains a technical fallback for bootstrap/installer scripts only.

### Shipped lanes (PR-A.1 → PR-A.2 → PR-B → PR-C → PR-D, merged in strict order)

- **PR-A.1 (PR [#675](https://github.com/itcmsgr/nftban/pull/675) sq `b3b28121`) — canonical authority wording sweep**: 23 CLI shell files + 1 Go file rewritten to the canonical statement above. Forbidden patterns eliminated: `Run with sudo`, `requires root [privileges]`, `must run as root` / `Run as root`, `(sudo)` parenthetical, `Permission denied (not root)`. The 3 V127 UX-6 PR-F REQUIRES blocks that shipped in v1.127.0 with the wrong `Otherwise run as root or use the site-approved privilege method` wording were corrected here. Test asserts 20 invariants.
- **PR-A.2 (PR [#676](https://github.com/itcmsgr/nftban/pull/676) sq `53ec9b61`) — sudo nftban example sweep**: 68 main-CLI `sudo nftban X` example lines across 23 CLI shell files rewritten to `nftban X` (zero sudo-first main CLI examples on main). 14 residual `root privileges` / `NEEDS ROOT` / `needs root` operator-facing strings rewritten to canonical. `sudo nftban-installer` and `sudo nftban-core` preserved per installer/bootstrap allowlist. Test hardened to 23 invariants.
- **PR-B (PR [#677](https://github.com/itcmsgr/nftban/pull/677) sq `44420367`) — top-level CLI command correlation guards**: new deterministic CI gate asserting that canonical commands, cmd_*.sh implementation files, and dispatcher routing remain mutually consistent. Caught real drift: 11 cmd_*.sh files (`benchmark`, `cleanup`, `egress`, `flush`, `preflight`, `pro`, `protect`, `scale`, `snapshot`, `tunnel`, `unprotect`) were missing from the canonical command list since V127 UX-5 — typo suggestions were broken for those names. Canonical list grew 69 → 80. 8 inline-handled commands explicitly allowlisted. **IMPORTANT — see "Limitations" below: this PR covers TOP-LEVEL command correlation only. The deeper subcommand/flag/example doctest correlation is deferred to v1.129.**
- **PR-C (wiki commit `312fdb3` on `nftban.wiki:master`) — wiki CLI text alignment**: 22 `sudo nftban X` example lines across 6 wiki .md files rewritten to drop sudo; 6 `sudo nftban-core geoip update` rewritten to the canonical polkit-authorized CLI path `nftban geoip update`; 3 residual privilege wording strings in `FHS-Compliance.md` rewritten to canonical. `sudo nftban-installer --repair` preserved in `Installation-Guide.md` per installer/bootstrap allowlist. In-repo `docs/**/*.md` (16 files) and `README.md` were baseline-clean so no Stage 2 main-repo PR was needed.
- **PR-D (PR [#678](https://github.com/itcmsgr/nftban/pull/678) sq `855c0f49`) — doc clarity lockable lint**: recon found ZERO actionable clarity issues in README + docs/ (the V128 arc PR-A.1 + PR-A.2 + PR-B + PR-C work already brought operator-facing markdown to the canonical state). PR-D ships as the lockable test only — 5 invariants locked against future regression (TODO/XXX/FIXME placeholders, vague qualifier phrases, double negatives, residual sudo/root drift, scope sanity).

### Limitations — honest scope of v1.128 PR-B

**v1.128 PR-B added top-level CLI command correlation guards** to ensure canonical commands and cmd_*.sh implementation files remain aligned. The deeper class — verifying that every `nftban X foo --bar` in help text resolves to a parser branch in `cmd_X.sh` that accepts both `foo` as subcommand AND `--bar` as flag — was **intentionally deferred** to `v1.129 DEEP_CLI_HELP_CODE_DOCTEST_CORRELATION`.

Reason: when prototyped during PR-B development, the naive global-regex extractor produced ~26 "drift" hits with high false-positive rate from helper sub-modules (`cmd_X_<verb>.sh` own their own dispatch), wildcard cases (`*)`), and narrative help text (`"firewall-logs is an alias for ..."` generated a false `is` subcommand). v1.129 will use per-command-family extractors with proper false-positive controls and will additionally verify wiki + docs + README CLI text against actual parser/dispatcher behavior (per operator directive 2026-05-24).

**v1.128 does NOT claim full help/code correlation coverage.** See `V129_DEEP_CLI_HELP_CODE_DOCTEST_CORRELATION_SCOPE.md` for the full v1.129 plan.

### Binary impact

```
cmd/nftband:       BYTE-IDENTICAL to v1.127.0
cmd/nftban-core:   differs from v1.127.0 ONLY in the error-string constant at
                   privilege.go:91 (capability check logic UNCHANGED;
                   CAP_NET_ADMIN technical guidance preserved verbatim;
                   function signatures UNCHANGED). No behavior change.
```

### Schema / wire-format

**Schema 1.83.0 remains frozen** UNCONDITIONALLY. No new validator field, no new metric, no new Prometheus label, no Status JSON wire-format key, no new `install_state` JSON field, no new nftables kernel set / chain / table name, no new config key, no new systemd unit, no packaging behavior change.

### Out of scope (for v1.128.0)

- No package/systemd/polkit-rule behavior changes (the polkit authority architecture is preserved; only operator-facing wording about it changes)
- No metrics/portal/schema drift
- No host contact across any V128 lane (PR-C wiki push is a git-remote operation, not host contact)
- No new commands or aliases
- No dispatcher routing / completion / typo handler infrastructure changes (the canonical list grew by 11 entries to fix v1.128 PR-B's discovered drift, but that's an additive correction to the typo suggester's source list, not new commands)
- No `commands.registry.yml` or `scripts/generate-help.sh` change

### Deferred to v1.129 — `V129_DEEP_CLI_HELP_CODE_DOCTEST_CORRELATION`

Scope filed plan-only in `AUDIT_190_LIFECYCLE/V129_DEEP_CLI_HELP_CODE_DOCTEST_CORRELATION_SCOPE.md`:

- Per-command-family extractors (not one global regex) for subcommand + flag + alias + SEE ALSO + USAGE-shape correlation
- Across cli/lib/nftban/cli + cli/sbin/nftban + wiki + docs/ + README
- Each verified against actual parser/dispatcher behavior
- Estimated PR split: PR-A harness + audit, PR-B.x per-family text fixes, PR-C.x per-bug code fixes (separately gated), PR-D wiki+docs+README after CLI stabilizes, PR-E CI-lock

### Hotfix slot

v1.128.x hotfix slot **not authorized** (latent reservation only — opens only if a v1.128.0 defect surfaces).

---

## [v1.127.0] - 2026-05-24 — V127 six-lane CLI UX correction release

**Codename:** `V127_FULL_UX_CORRECTION`
**Scope file:** `AUDIT_190_LIFECYCLE/V127_FULL_UX_CORRECTION_UMBRELLA_SCOPE.md`

### What's new

Six narrow CLI UX lanes (UX-1 through UX-6) merged in strict order PR-A → PR-B → PR-C → PR-D → PR-E → PR-F, each separately-shippable and CI-clean-on-PR before this release-prep PR was opened.

- **UX-1 P0 core trust (PR #668 sq `5d14ba6e`)** — no-args dashboard truth-source unification with `nftban health`; `nftban health` INFO-finding filter; `nftban version` GUI/API removal + Installed/Latest/Last-checked rows; `nftban update` same-version no-op + verdict consolidation; selftest self-containment; config stderr error discipline. 23 deterministic tests.

- **UX-2 well-known infrastructure ban/search guard (PR #669 sq `107c0a32`)** — items 1.7 + 3.2 with a new shared helper library covering 16 well-known DNS IPs across 4 providers (Cloudflare/Google/Quad9/OpenDNS). 40 deterministic tests.

- **UX-3 stats + banlog correctness — Option A full Go fix (PR #670 sq `65e1eee7`)** — A1 facade convergence in `internal/escalation/tracker.go::LogTempBan` (delegates to canonical `banlog.LogBanFull` BLC-1 pipe format; eliminates the pre-V127 interleaved mixed-format rows that broke `nftban stats recent`); new `banlog.StatusResync` / `ClassResync` / `LogResync` emitted by `cmd/nftban-core/cmd_ban.go` on the already-banned re-sync path so operators can distinguish RESYNC events from real new bans; labeled `Source: / Set: / Event type: / Total bans:` ban footer; stats label disambiguation `Blocked IPs (live)..` + `BANS BY MODULE (cumulative)`; `Data source: DERIVED` fallback on cache-miss path. **30 deterministic shell tests + 1 Go static guard + 1 Go behavioral runtime test (using `nftbanconf.DefaultConfigFile` as the test seam — no production-code seam added).**

- **UX-4 Suricata display-only de-surfacing — Option A full de-surface (PR #671 sq `29c48bee`)** — no-args dashboard Suricata row removed (Login Mon now pairs with Watchdog); `nftban modes` Suricata-status line removed and reason strings replaced with neutral "Auto-resolved (advanced)" / "Auto-resolved (classic)"; `nftban help` / `--all` filter the suricata row. Production `cmd_suricata.sh` / `cmd_suricata_setup.sh` / `nftban_{login,portscan,ddos}_suricata.sh` / dispatcher routing / completion lists / typo handler all preserved — `nftban suricata <subcmd>` remains reachable. `--json` output preserved (`suricata.running` + `eve.*` keys intact for machine consumers). 31 deterministic tests.

- **UX-5 typo handler + alias/version discoverability (PR #672 sq `729784a9`)** — pure-bash Damerau-Levenshtein edit-distance command suggestion replacing the ~70-line static typo case table (canonical 69-command source list; length-aware thresholds); minimal multi-word fallback preserved (`configtest`/`configaudit`). ALIAS section annotation in `cmd_firewall_logs.sh::_fwlog_help`. SEE ALSO cross-references between `nftban update` and `nftban version`. 43 deterministic tests.

- **UX-6 help-system cleanup with polkit-aware wording (PR #673 sq `614dd4d0`)** — banner suppression in `nftban help` paths; fake `Profile: $profile` footer removed; `cmd_ban.sh` `--async`/`--wait` clarity + EXIT CODES gold-standard upgrade; CTRL+C + REQUIRES (polkit-aware) + EXIT CODES sections on `cmd_flush.sh` / `cmd_update.sh` / `cmd_firewall.sh`. **Mid-review polkit-aware correction** applied: initial D-6 draft used "Run with sudo" framing; operator flagged that NFTBan uses PolicyKit/polkit not sudo as the canonical privilege path; all three destructive REQUIRES blocks rewritten to the "Elevated privileges ... PolicyKit/polkit may authorize ... otherwise run as root or use the site-approved privilege method" template; exit-code-2 wording rewritten to "Authorization failed or insufficient privileges". F5/F6 test assertions added to lock the invariant against regression in PR-F's three touched files. 33 deterministic tests.

### Binary impact

**The identical-daemon-binary streak (v1.114.0 → v1.126.2, then extended to 18 releases by shell-only UX-1 + UX-2) intentionally ENDED at UX-3 by design.** Option A acceptance explicitly authorized the daemon-binary delta as the cost of single-writer canonical BLC-1 format convergence (touches: `internal/banlog/banlog.go` adds `StatusResync` / `ClassResync` / `LogResync`; `internal/escalation/tracker.go::LogTempBan` body rewritten to delegate; `cmd/nftban-core/cmd_ban.go` adds the resync emission + new ban footer).

UX-4, UX-5, and UX-6 are all shell-only and add no further daemon delta — v1.127.0's `cmd/nftband` + `cmd/nftban-core` binaries are byte-identical to PR-C UX-3 output.

### Validation

- **Per-lane lab validation: WAIVED** under `AUDIT_190_LIFECYCLE/V127_UX_VALIDATION_POLICY_AMENDED.md` — per-PR CI + deterministic tests + scope reviews substituted for lab runs across all six UX lanes.
- **Final consolidated lab validation: SKIPPED** under `SKIP_V127_FINAL_CONSOLIDATED_LAB_VALIDATION = GO` per operator directive `V127_FINAL_LAB_VALIDATION_SKIPPED_OPERATOR_WILL_VALIDATE_MANUALLY`. Operator performs manual runtime/package validation outside this automation lane on their preferred timeline. Documented in `AUDIT_190_LIFECYCLE/V127_FINAL_LAB_VALIDATION_SKIPPED.md`.
- **Validation evidence in the closure record** therefore consists of per-PR CI results + deterministic-test counts, NOT lab-host runtime evidence.

### Schema / wire-format

**Schema 1.83.0 remains frozen** UNCONDITIONALLY. No new validator field, no new metric, no new Prometheus label, no Status JSON wire-format key, no new `install_state` JSON field, no new nftables kernel set / chain / table name, no new config key, no new systemd unit, no packaging behavior change. The new `banlog.StatusResync = "RESYNC"` + `ClassResync = "resync"` are additive enum values within the existing 10-field BLC-1 pipe format (`DATE|TIME|SOURCE|IP|COUNTRY|STATUS|REASON|BAN_ID|TIMEOUT|CLASS`); downstream `cut -d'|' -fN` consumers continue to work unchanged.

### Deferred to v1.128 — `V128_CLI_TEXT_AUTHORITY_ALIGNMENT`

Three follow-up lanes filed plan-only in `AUDIT_190_LIFECYCLE/V128_CLI_TEXT_AUTHORITY_ALIGNMENT_SCOPE.md`, to run in strict order:

1. **POLKIT_AWARE_WORDING_SWEEP** — replace remaining "sudo nftban" / root-first wording across the rest of the CLI surface (scan baseline at v1.127.0 cut: ~79 `sudo nftban` occurrences across ~24 `cli/lib/nftban/**/*.sh` files + ~12 root-first error strings + 1 Go-side wording candidate at `cmd/nftban-core/privilege.go:91`).
2. **HELP_CODE_CORRELATION_AUDIT** — doctest-style verification that every CLI help example / flag / subcommand / alias / SEE ALSO reference maps to an actual dispatcher/parser path. Must run AFTER #1 so the doctest does not lock in pre-sweep `sudo nftban ...` examples.
3. **WIKI_CLI_TEXT_ALIGNMENT** — align wiki/docs CLI examples to the final CLI text after lanes 1 and 2.

### Out of scope

- No new commands or aliases.
- No dispatcher routing / completion / typo-handler infrastructure change.
- No `commands.registry.yml` change (the cosmetic `Profile: operator` footer line was removed in UX-6 D-7 but the registry schema is untouched).
- No `scripts/generate-help.sh` schema change (only the footer label removed).
- No detector/planner/takeover changes.
- No schema/metrics/portal/polkit-rules/systemd/packaging behavior change.
- No host contact during any V127 lane or this release-prep.

### Hotfix slot

v1.127.x hotfix slot **not authorized** (latent reservation only — opens only if a v1.127.0 defect surfaces).

---

## [v1.126.2] - 2026-05-23 — V126.2 install-abort UX hotfix (single-PR hotfix on top of v1.126.1)

V126.2 message-only **P2-correctness + P3-UX hotfix release** on top of
v1.126.1, closing `D-INSTALL-AUTHORITY-ABORT-MESSAGE-WRONG-COMMAND` (P2)
and `D-INSTALL-AUTHORITY-ABORT-MESSAGE-TOO-TECHNICAL` (P3). Surfaced by
dns1 live-host install 2026-05-23T13:35:53Z when the DEB postinst's
recovery instruction `NFTBAN_TAKEOVER=1 dpkg --configure nftban-core`
returned "package nftban-core is already installed and configured" —
dpkg refuses to re-run postinst once the prior postinst returned (with
exit 3) because the package is considered configured. Documented in
`AUDIT_190_LIFECYCLE/V126_2_INSTALL_ABORT_UX_HOTFIX_SCOPE.md` (REV 4).

**Schema 1.83.0 remains frozen** UNCONDITIONALLY. No new validator field,
no new metric, no new Prometheus label, no Status JSON wire-format key,
no new `install_state` JSON field, no nftables kernel set / chain /
table name change, no new config key, no new systemd unit, no packaging
behavior change beyond the de-duplicated postinst messages.

**Daemon binary byte-identical to v1.126.1** (and v1.126.0, v1.125.0,
v1.124.1, v1.124.0, ... v1.114.0). The hotfix is confined to installer
Go output formatting + new logger primitive + postinst de-duplication
+ new test file. `cmd/nftband/` and `cmd/nftban-core/` are byte-unchanged.
**16-release identical-daemon-binary streak** preserved (v1.114.0 →
v1.126.2).

**No metrics changes. No new schema or config keys. No new systemd
units. No detector/planner/takeover/firewall logic change.** No host
contact during release-prep construction.

### Fixed — operator-friendly FAILED_AUTHORITY_ABORT message

**Single PR #666 (sq `7f651153`).** Closes
`D-INSTALL-AUTHORITY-ABORT-MESSAGE-WRONG-COMMAND` and
`D-INSTALL-AUTHORITY-ABORT-MESSAGE-TOO-TECHNICAL`.

#### Root cause (audit-confirmed + live-proven on dns1)

When the installer aborts during postinst because conflicting firewalls
are detected and the operator has not pre-approved takeover (via
`NFTBAN_TAKEOVER=1`), three confusing/contradictory message blocks
were emitted in a single failed install:

1. **Go installer Detect-phase ERROR + JSON event dumps**: cryptic
   `[NFTBan ERROR] phase Detect failed: FAILED_AUTHORITY_ABORT: ...`
   plus three `{"timestamp":..."event":"detect|plan|result"...}`
   lines from the lifecycle bridge to stderr.

2. **Go installer generic FAILED summary block** at
   `cmd/nftban-installer/main.go:498-525`: `[NFTBan] Install/upgrade
   FAILED.` with `[NFTBan] To retry: /usr/lib/nftban/bin/nftban-
   installer --repair` and `[NFTBan] Or: nftban firewall rebuild`
   retry hints — **both wrong for the ABORT case** (those apply to
   FAILED_RENDER / FAILED_REBUILD recovery).

3. **DEB postinst ABORTED block** at `packaging/deb/postinst:280-281`:
   `Conflicting firewalls detected, takeover not approved.` and
   `To takeover: NFTBAN_TAKEOVER=1 dpkg --configure nftban-core` —
   the only block that surfaced a takeover command, but the command
   itself was **broken** (dns1 evidence: 3 consecutive attempts all
   returned "package nftban-core is already installed and configured").

Operator manually discovered `/usr/lib/nftban/bin/nftban-installer
--repair` as the working recovery path via process of elimination.
The `--repair` flag is the canonical state-machine recovery for
FAILED_AUTHORITY_ABORT (resumes from phase DETECT) and works
identically on both DEB and RPM hosts.

Two-AI scope review (Gemini + ChatGPT) additionally caught:

- **Sudo `env_reset` trap**: the REV 3 two-line `export VAR=...;
  sudo command` form is silently stripped by `sudoers env_reset`
  defaults. The inline `sudo VAR=value command` form survives
  env_reset.

- **Kernel-verification gap**: `systemctl is-active nftband` alone
  doesn't prove nft rules were actually loaded. Added `nft list
  tables` + `nft list ruleset | grep -i nftban`.

- **Package-state OBSERVE-ONLY commands** (refining Gemini's
  `apt-get install -f` suggestion): added `dpkg -s nftban-core`
  + `apt-get check` for DEB, `rpm -q nftban-core` + `dnf check`
  for RPM. These are reassurance commands, **not** auto-fix
  instructions (dns1 evidence shows dpkg state is fine).

- **Ctrl-C interruption hazard**: operator dns1 follow-up evidence
  showed a second `--repair` attempt interrupted by Ctrl-C left
  the install in a partial state. Added explicit warning.

#### What changed

5 files / +480 / −13. Scope: message-only across the FAILED_AUTHORITY_
ABORT path; no logic change to detector, planner, takeover, firewall,
schema, daemon, or non-ABORT failure handling.

  cmd/nftban-installer/main.go                       +156 / −3
  cmd/nftban-installer/report_failed_abort_test.go   NEW (294 lines,
                                                          3 test cases)
  internal/installer/logging/logger.go               +13 / −0
  packaging/build_nftban.sh                          +8 / −6
  packaging/deb/postinst                             +10 / −6

Primary fix (`cmd/nftban-installer/main.go::report()`):
- New `case state.StateFailedAbort:` in the result-switch, placed
  BEFORE the existing `default:`. Non-ABORT failures continue to
  use the default case with existing retry hints — unchanged.
- Emits a calm structured block: bulleted conflict list from
  `sf.Conflicts` (with detector-Option-A-gap fallback), both
  sudo-safe and root-shell command variants, Ctrl-C warning,
  do-not-re-run-dpkg-configure warning, control-panel awareness
  note, OPTION 2 "Stop Here" exit path, verification block
  (NFTBan health + kernel-state + optional package-state).

New `Logger.ErrorLogOnly()` primitive
(`internal/installer/logging/logger.go`):
- Writes ERROR-level message to log file but NOT stdout.
- Used by `main.go` phase-failure handlers (both normal and repair
  modes) when `sf.State == state.StateFailedAbort`. Suppresses the
  `[NFTBan ERROR] phase Detect failed:` stdout line; log file
  unchanged.
- Non-ABORT failures still emit `log.Error(...)` to both — existing
  behavior preserved.

Lifecycle bridge JSON event dump suppression:
- When `sf.State == state.StateFailedAbort`, the phase-failure
  handler skips `lb.observeDetect/Plan/Result` calls so the
  `{"timestamp":..."event":"detect|plan|result"...}` JSON dumps
  do NOT emit to stderr for the ABORT path.
- `install_state` and internal log capture the same outcome data.
- Lifecycle observers for non-ABORT states are unchanged.

Postinst de-duplication:
- `packaging/build_nftban.sh:991-996` (RPM) and
  `packaging/deb/postinst:276-281` (DEB) `INSTALLER_EXIT=3`
  branches are now no-op shims with a comment pointing to the Go
  installer as single source of truth. No duplicate ABORTED block,
  no broken `dpkg --configure` retry advice.

#### Tests (3 new in `report_failed_abort_test.go`)

- `TestReportFailedAbortV126_2HotfixMessage`: snapshot test of
  `report()` output for `StateFailedAbort` with full REV 4
  INCLUDE/EXCLUDE assertions; captures both stdout and stderr;
  asserts JSON event dumps (`{"timestamp":`) absent from stderr.

- `TestReportFailedAbortV126_2_EmptyConflicts`: empty-CONFLICTS
  fallback case (detector-Option-A-gap).

- `TestErrorLogOnly_DoesNotEmitToStdout`: unit test for the new
  primitive — stdout silent, log file preserved with `[ERROR]`
  level marker.

#### Operator-visible behavior changes

1. FAILED_AUTHORITY_ABORT install output is now a single calm
   structured block instead of three contradictory blocks.

2. Recovery command is sudo-safe and unified across DEB+RPM
   (same single-line invocation on every supported distribution).

3. Verification block includes kernel-state checks plus optional
   package-state observe-only commands.

4. Non-ABORT failure paths (FAILED_RENDER / FAILED_REBUILD /
   FAILED_SWITCH / FAILED_SSH_UNKNOWN / FAILED_TAKEOVER) are
   unchanged.

5. Audit trail unchanged: `/var/log/nftban/installer.log`
   contains the same ERROR line as v1.126.1; only the stdout
   emission for FAILED_AUTHORITY_ABORT is calmed. `nftban
   support` diagnostic bundles are byte-identical to v1.126.1.

#### External tooling — breaking string-parse compatibility

String-match consumers of the old DEB/RPM message lines must
migrate to canonical machine-readable surfaces:

- `install_state.INSTALL_STATE=FAILED_AUTHORITY_ABORT`
- Installer process exit code `3`
- `install_state.CONFLICTS=` field
- `install_state.FAILURE_REASON=` (unchanged from v1.126.1)
- Internal log file content (still contains ERROR line via
  `ErrorLogOnly`'s file write)

#### Companion design lanes filed (workspace-only; deferred to v1.127)

- `D_TAKEOVER_PATH_RETROACTIVE_DISARM_GAP_SCOPE.md`: planner cannot
  retro-disarm CSF artifacts when nftban already owns authority
  (live-proven on srv2).
- `D_DETECTOR_OPTION_A_CSF_CONF_GAP_SCOPE.md`: `install_state.
  CONFLICTS=` can be empty even when `detect.conflicting_firewall=
  true` JSON event fires.
- `D_CLI_FIREWALL_CONFLICTS_UNBOUND_VAR_REENTRY_SCOPE.md`:
  `CONFLICT_NONE: unbound variable` re-entrance bug when `nftban
  firewall conflicts` is invoked in a shell that already sourced
  the conflicts lib.

#### Stretch lanes carried forward (each separately gated)

- `OPEN_INSTALLER_LOG_SUPPRESS_DEBUG_JSON_SCOPE`: broader JSON dump
  suppression for non-ABORT paths (V126.2 only suppresses for ABORT).
- `OPEN_POSTINST_ALL_STATES_UX_REVIEW_SCOPE`: similar UX pass on
  DEGRADED + FAILED (non-ABORT) + COMMITTED postinst output.
- `OPEN_V126_2_DNS1_SPOT_CHECK`: operator runs v1.126.2 install on
  dns1 in same conflicting-firewall state to verify operator-visible
  output matches the snapshot.
- i18n / localization lane (current and proposed messages English-only).

### Compliance / non-goals

v1.126.x hotfix slot now **CONSUMED** by v1.126.1 + v1.126.2 (two-
revision hotfix lineage; v1.126.3+ NOT authorized). No detector,
planner, takeover, firewall, schema, or daemon changes. No metrics
changes. No new schema or config keys. No new systemd units. No
packaging behavior change beyond de-duplicated postinst messages.
No polkit changes. No host contact during release-prep construction.

### Release-prep file pattern (matches every prior release since v1.79.2)

  VERSION                                       1.126.1 → 1.126.2
  STATUS.md                                     banner + Release lane update;
                                                v1.126.1 demoted to Prior lane
  CHANGELOG.md                                  new ## [v1.126.2] entry above
                                                v1.126.1
  cli/lib/nftban/core/nftban_fhs_spec.sh        header v1.126.1 → v1.126.2
                                                (path-table body byte-unchanged;
                                                build/fhs-spec.yaml unchanged)

---

## [v1.126.1] - 2026-05-23 — V126.1 trust-load strict-warning hotfix (single-PR hotfix on top of v1.126.0)

V126.1 hotfix release on top of v1.126.0, closing
`D-NFTBAN-TRUST-LOAD-SILENT-NOOP-WHEN-PROVIDER-ENABLED-VIA-LOCAL-OVERRIDE`
(P2; surfaced by V126 srv3 Lane C live-host active test 2026-05-23T08:43Z;
documented in `AUDIT_190_LIFECYCLE/V126_VALIDATE_SRV3_LANE_C_FAIL_CLOSURE.md`
and root-caused by code audit in `AUDIT_190_LIFECYCLE/V126_1_LANE_C_HOTFIX_SCOPE.md`
after correcting the initial detection-logic-divergence hypothesis).

**Schema 1.83.0 remains frozen** UNCONDITIONALLY. No new validator field,
no new metric, no new Prometheus label, no Status JSON wire-format key,
no new `install_state` JSON field, no nftables kernel set / chain / table
name change, no new config key, no new systemd unit, no packaging change.

**Daemon binary byte-identical to v1.126.0** (and v1.125.0, v1.124.1,
v1.124.0, v1.123.0, ... v1.114.0). The hotfix is confined to two CLI
shell files plus one new test — `cmd/nftban-installer/` and `cmd/nftband/`
and `cmd/nftban-core/` are byte-unchanged across the V126 + V126.1 arc.
**15-release identical-daemon-binary streak** preserved (v1.114.0 →
v1.126.1).

**No metrics changes. No new schema or config keys. No new systemd
units. No packaging changes.** No host contact during release-prep
construction.

### Fixed — trust-load strict warning + non-zero rc

**Single PR #664 (sq `24872bc7`).** Closes
`D-NFTBAN-TRUST-LOAD-SILENT-NOOP-WHEN-PROVIDER-ENABLED-VIA-LOCAL-OVERRIDE`.

#### Root cause (audit-confirmed)

`nftban_trust_load()` at `cli/lib/nftban/core/nftban_trust.sh:836` iterates
the 7 supported trust providers. For each enabled provider, it checks for
the generated whitelist file at
`/etc/nftban/whitelist.d/30-trust-<provider>.conf`. **If the file is missing,
the inner block is SILENTLY SKIPPED** (no log, no warning, no exit-code
change). The function then emits a misleading message "No providers loaded
— check enabled status" (implies config-state problem; actual cause is
file-state problem) and returns rc=0.

V126 Lane C's Step 4d in `firewall_reload` (PR #660) invokes
`nftban trust load >/dev/null 2>&1 || { warning }`. Because trust load
returns rc=0 despite doing nothing, the warning branch never fires.
Lane C silently no-ops on every v1.126.0 host where the operator manually
edited `TRUST_*_ENABLED` in `nftban.conf.local` without running the
canonical `nftban trust enable <PROVIDER>` mutator, OR where the generated
whitelist file was removed post-enable by some cleanup or config-reset
path (srv3's exact state since pre-V125).

**Correction note:** the v1.126.1 hotfix scope's INITIAL hypothesis
("`nftban trust load` reads config differently than `nftban trust
status`") was incorrect. Direct code audit on local repo HEAD `fb295bec`
confirmed both commands use the SAME `_trust_is_enabled` helper, sourced
through the same `cli/sbin/nftban:127-130` wrapper which sources
`nftban.conf.local`. Both DO see `TRUST_CLOUDFLARE_ENABLED="true"`. The
actual divergence is in the downstream inner check for the generated
whitelist file path. The scope's §2 was rewritten by amendment 3
(`AMEND_V126_1_HOTFIX_SCOPE_ROOT_CAUSE_CORRECTION`, 2026-05-23) to reflect
the audit-confirmed mechanism.

#### Fix

**`cli/lib/nftban/core/nftban_trust.sh::nftban_trust_load`** (+28 / −2):
- Added separate `enabled_but_unloadable` counter (tracks
  "configured-enabled but whitelist file missing" providers, distinct
  from the `loaded` success counter).
- Added explicit `else` branch on the inner `[[ -f "$whitelist_file" ]]`
  check that emits stderr `[ERROR]` naming the missing file path AND the
  canonical repair command (`Run: nftban trust enable <PROVIDER>`), logs
  via `_trust_log "ERROR"` to `/var/log/nftban/trust.log`, and increments
  the new counter.
- Returns exit code 2 when `enabled_but_unloadable > 0` (distinct from
  rc=0 success and from other rc!=0 `_trust_apply_to_nft` failures).
- Preserves rc=0 behavior when no providers are configured at all (with
  a new "[!] No providers configured — use 'nftban trust enable
  <PROVIDER>'" message; no false-positive failures).
- **NO auto-heal logic added** (per V126.1 scope §4.6.4): the fix is
  strictly diagnostic + exit-code propagation. Canonical operator repair
  stays explicit `nftban trust enable <PROVIDER>` (not auto-recreate
  inside the reload path, which would mask broken trust state and add a
  network dependency to every `firewall_reload`).

**`cli/lib/nftban/cli/cmd_firewall.sh::firewall_reload` Step 4d**
(+13 / −2):
- Removed `2>&1` from the `nftban trust load >/dev/null` invocation (so
  per-provider stderr errors reach the operator).
- Updated the warning message from "Run: nftban trust load" (a no-op
  given the underlying bug) to "Run: nftban trust enable <PROVIDER> (see
  'nftban trust load' output for which providers)" — the canonical
  lifecycle repair.

**New test:**
`cli/lib/nftban/tests/trust_load_missing_whitelist_test.sh` (NEW, 366
lines, **44 assertions in 5 sections**):
- **8 static guards (S1-S8)** verify v1.126.1 fix markers are present in
  modified files; verify NO auto-heal calls (`_trust_download_provider`,
  `_trust_write_whitelist`) added inside `nftban_trust_load`.
- **15 behavioral assertions (B1-B15)** in 4 scenarios: CLOUDFLARE alone
  enabled+missing-file (rc=2 + stderr + canonical-repair-message); no
  providers configured (rc=0); CLOUDFLARE enabled+whitelist-file-present
  healthy (rc=0); mixed-state CF healthy + AWS broken (rc=2).
- **21 per-provider sweep assertions (B16-B36)** added via
  `AMEND_PR_664_ADD_7_PROVIDER_SWEEP`: loops over ALL 7 supported
  providers (`CLOUDFLARE` / `QUICCLOUD` / `AWS` / `GOOGLE` / `AZURE` /
  `DIGITALOCEAN` / `FASTLY`), enables each one in isolation, asserts
  rc=2 + stderr-names-provider + "Run: nftban trust enable <PROVIDER>"
  for each. Proves the fix is **provider-agnostic, NOT
  CLOUDFLARE-special**.

Self-contained sandbox; no root required; no nftables required (stubs
`_trust_apply_to_nft`); no host contact. **Verified both directions
pre-merge**: 44/44 PASS on the hotfix source; 8/44 PASS + 36/44 FAIL on
v1.126.0 source (production code reverted, test kept) — proves the test
actively reproduces the bug class for ALL providers, not just passively
validates the fix.

### Operator-visible behavior changes

- **`nftban trust load`** on a host with `TRUST_<PROVIDER>_ENABLED="true"`
  but `/etc/nftban/whitelist.d/30-trust-<provider>.conf` missing now:
  - exits **2** (was **0** silent)
  - emits stderr `[ERROR]` per affected provider naming the missing file
    path
  - directs operator to run `nftban trust enable <PROVIDER>` (the
    canonical lifecycle repair)

- **`nftban firewall reload`** (and internal callers:
  `whitelist-session add/remove`, takeover re-runs) now surfaces a clear
  warning when any enabled provider has a missing whitelist file.
  Previously silent in v1.126.0 because Step 4d's `2>&1 || { warning }`
  swallowed both the error and the non-zero rc.

- **Healthy-state behavior unchanged**: providers correctly enabled via
  `nftban trust enable <PROVIDER>` continue to load identically to
  v1.126.0.

### Operator-action required post-upgrade on V126 Lane C-affected hosts

The hotfix does **NOT** auto-recover srv3's (or any other affected host's)
existing broken state. Per scope §4.6.4 (no-auto-heal policy), after the
v1.126.1 RPM/DEB upgrade lands on srv3 / dns2, the operator **MUST** run
`nftban trust enable CLOUDFLARE` **ONCE per host** to recreate the
missing whitelist file.

Without this, the strict-warning behavior persists at every
`firewall_reload`: the operator is told exactly what to do, and the
warning continues until they do it. After the operator repair runs, the
active Lane C test from `V126_VALIDATE_SRV3_LANE_C_FAIL_CLOSURE.md` §3
should PASS (Cloudflare CIDRs survive `firewall_reload`).

### CI baseline

PR #664 final tally: **51 SUCCESS / 2 SKIPPED / 0 FAILURE** across 53
checks — including Go Build & Test, Build NFTBan Packages, all 5
Canonization Gates (Install / Restore / Update / Uninstall / Runtime
Truth), CodeQL, Semgrep, OSV-Scanner, ShellCheck, Bash Validation,
Documentation Validation, Architecture Policy, Migration Coverage Gate,
Shell-Delete Guard, Secret Scanning (Gitleaks), Docker, Smoke Test.

### Non-goals (carried forward as separately-gated future debt)

- **7-provider full CLI lifecycle test sweep in CI** (V126.1 scope
  §5.5.2 — enable → cache/whitelist creation → load → reload → disable
  → reload). Requires kernel-test harness not currently in CI. Partial
  coverage achieved via the §2.5 missing-file sweep in this PR (21
  assertions × 7 providers).
- **DirectAdmin trust-policy decision lane**
  (`OPEN_DIRECTADMIN_TRUST_POLICY_DECISION_LANE`) — whether
  DirectAdmin installs should default to auto-enabling Cloudflare;
  separate operator-policy decision; NOT mixed into this
  state-consistency hotfix.
- **`D-WHITELIST-SYNC-PARTIAL-MISS-AFTER-FIREWALL-RELOAD`** investigation
  — V126 Lane C closure §6.1 noted transient operator-IP drop from
  kernel after `firewall_reload`; non-blocking; separate lane.
- **`D-TRUST-STATUS-DISPLAY-COUNT-STUCK-AT-ZERO`** cosmetic — across
  lab2 + dns2 + srv3 `nftban trust status` reports `Total IP ranges: 0`
  despite kernel populated; cosmetic-only, not functional; separate
  lane.
- **Single-canonical-resolver refactor** for `_trust_is_enabled` (V126.1
  §4.1) — downgraded to code-hygiene-secondary after audit confirmed
  detection logic was already consistent across all callers; defensive
  future-proofing only; can be deferred indefinitely.

### Hotfix slot

**v1.126.x hotfix slot now CONSUMED by v1.126.1** (latent reservation
activated for the trust-load strict-warning lane). **v1.126.2+ NOT
authorized.**

### Workspace artifacts (no PR, no code)

V126.1 design + audit + decision chain filed at `AUDIT_190_LIFECYCLE/`:

- `V126_1_LANE_C_HOTFIX_SCOPE.md` — 3 amendments (root-cause correction,
  enable/disable contract, provider-matrix); §4.6 primary fix; §5.5
  7-provider sweep design; §8 acceptance criteria.
- `V126_VALIDATE_SRV3_LANE_C_FAIL_CLOSURE.md` — V126 srv3 active test
  failure record that motivated this hotfix.

---

## [v1.126.0] - 2026-05-23 — V126 install-correctness fix-bundle: 3-lane defect closure (C → B → A)

V126 install-correctness fix-bundle release on top of v1.125.0, bundling
three narrow defect-closure lanes filed in
`AUDIT_190_LIFECYCLE/V126_IMPLEMENTATION_ORDER_PLAN.md` and merged in the
locked C → B → A order. Each defect was reproduced empirically on a real
fleet host before scope; each lane was implemented as a separately-
shippable narrow PR, audited, and CI-clean-on-PR before merge; this
release-prep PR follows the same 4-file pattern (VERSION + STATUS +
CHANGELOG + FHS regen) used in every prior release since v1.79.2.

**Schema 1.83.0 remains frozen** UNCONDITIONALLY. No new validator
field, no new metric, no new Prometheus label, no Status JSON
wire-format key, no new `install_state` JSON field, no new nftables
kernel set / chain / table name change, no new config key, no new
systemd unit, no packaging change. `internal/validator/types.go`
continues to declare `const SchemaVersionCurrent = "1.83.0"`.

**Daemon binary byte-identical to v1.125.0** (and v1.124.1, v1.124.0,
v1.123.0, ... v1.114.0). Lanes B + C are shell-only; Lane A modifies
`cmd/nftban-installer/` only. `cmd/nftband/` and `cmd/nftban-core/`
are byte-unchanged across the V126 arc. **14-release identical-
daemon-binary streak** preserved (v1.114.0 → v1.126.0).

**No metrics changes. No new schema or config keys. No new systemd
units. No packaging changes** (`--rpm` / `--deb` postinst paths
unchanged; Lane A's R-4 gate extension fires identically on
package-triggered runs as on operator-initiated runs). **No polkit
changes. No host contact** during release-prep construction.

### Fixed — three install-correctness defect-closure lanes

**Lane C — re-apply trust providers in `firewall_reload` — PR #660 (sq `af904f43`).**
Closes `D-FIREWALL-RELOAD-DOES-NOT-REMERGE-TRUST-PROVIDERS` (P2,
fleet-wide latent). Empirical reproduction on srv3 (v1.121.0, 2026-05-22):
a single `nftban firewall whitelist-session add 62.38.150.122 --ttl 30m`
invocation called `firewall_reload` internally, which re-applied
DDoS / portscan / botguard / feeds / geoban — but missed trust
providers — silently dropping 14 Cloudflare CIDR ranges from kernel
`whitelist_ipv4` (17 elements → 3 elements). The trust providers had
been applied by a past `nftban trust enable CLOUDFLARE` invocation,
persisted across daemon restarts, and were not auto-re-applied. Fix
adds Step 4d to `cli/lib/nftban/cli/cmd_firewall.sh::firewall_reload`
between botguard (4c) and feeds (5), invoking `nftban trust load` as
a sibling CLI subprocess (same pattern as the other re-apply steps),
gated on `grep TRUST_*_ENABLED="true"` across
`/etc/nftban/conf.d/trust.conf` + `/etc/nftban/nftban.conf.local`
(no subprocess fork when no trust providers enabled). New shell
test `cli/lib/nftban/tests/cmd_firewall_trust_remerge_test.sh` with
15 assertions (6 regression guards, 1 sequencing assertion, 8 gating
fixture cases including srv3 shape).

**Lane B — unblock cleanly-migrated hosts in `_detect_install_type` — PR #661 (sq `2f8d9487`).**
Closes `D-DNS2-MIXED-HISTORY-AUTODETECT-FALSE-BLOCK` (P2). Empirical
reproduction on dns2 (v1.123.0, post-source-to-RPM migration 2026-05-20):
`nftban update` refused with exit 13 / `Install Type: mixed` because
`cli/lib/nftban/cli/cmd_update_detection.sh::_detect_install_type`
reads the OLDEST history entry via `jq '.[-1].type'` and dns2's oldest
entry was the 2026-04-30 source install — 23 days old and superseded
by 3 clean RPM successes on 2026-05-20. The v1.108 author landed the
oldest-history protection (catches packaging-family migrations
source → RPM / DEB) without the corresponding unblock-after-clean-
migration story. Fix extends the rpm-db and dpkg-db drift-check
predicates with a migration-clean unblock path requiring ALL THREE
positive signals: (a) package-db ownership, (b) most-recent
SUCCESSFUL history entry matches current family, (c) `install_state`
shows `INSTALL_STATE=COMMITTED + AUTHORITY=UPDATE`. All existing
v1.125 refusals preserved when any positive signal is missing
(genuinely-broken-source-mixed-with-RPM-files still refuses;
FAILED_REBUILD with RPM oldest still refuses; TAKEOVER authority
still refuses). New helpers: `_read_history_last_successful_type`
(jq + python3 + bash-awk fallback chain) and
`_probe_install_state_committed_update_authority` (with
`NFTBAN_TEST_INSTALL_STATE_FILE` env override matching the existing
`NFTBAN_TEST_HISTORY_FILE` convention). New shell test
`cli/lib/nftban/tests/cmd_update_detection_v126_test.sh` with 20
assertions covering the 8-case decision matrix plus 9 direct helper
tests.

**Lane A — extend R-4 `--force` gate to DEGRADED state — PR #662 (sq `00adedc7`).**
Closes `D-V125-R4-GAP-DEGRADED-STATE-NOT-GATED` (P2, design-gap).
Surfaced by lab2 V125 validation 2026-05-22T15:16:09Z: lab2's
`nftban update` completed as `StateDegraded` (chronic D-DEG-1
cascade triggered the `failed_units_postinstall_ok` non-fatal
assertion) instead of `StateCommitted`. The V125 R-4 active test
(`--force` on COMMITTED → ExitRefused) could not be safely executed
on lab2 because `--force` on `StateDegraded` did NOT fire the gate
— it would have re-run all 5 phases on a real host. This revealed
that chronic-DEGRADED hosts had **no** V125 R-4 protection against
accidental `--force` re-runs, precisely the protection scenario
R-4 was designed for. Fix extends
`cmd/nftban-installer/main.go::shouldRefuseForceRecommit` predicate's
gate-fire set from `{StateCommitted}` to
`{StateCommitted, StateDegraded}`. Rationale: `StateDegraded` is a
non-`StateCommitted` state but does NOT represent failure-recovery
— it means the install completed all 5 phases (Detect → Plan →
Prepare → Switch → Configure → Validate) but ended with non-fatal
assertion failures. Failure-recovery states (`StateFailedSwitch` /
`StateFailedRebuild` / `StateFailedRender` / `StateFailedNoFirewall`
/ `StateFailedTakeover`) remain unguarded by R-4 — `--force` is
the supported retry path there. Error messages now print the actual
state name via `Fprintf %s` (`error: --force on a DEGRADED install
requires --allow-recommit confirmation.`) and explicitly name the
`--repair` escape hatch for genuine failure recovery. `--allow-
recommit` flag help text updated to name both `COMMITTED` and
`DEGRADED`. Truth-table test in
`cmd/nftban-installer/force_recommit_gate_test.go` extended from 10
cases to 14 cases (test file `meta:version` bumped 1.0.0 → 1.1.0),
adding: DEGRADED + force + no-recommit → REFUSE (changed from
ALLOW), DEGRADED + force + allow-recommit → ALLOW (new explicit-
intent path), no-force on DEGRADED → ALLOW (gate requires force;
mirrors COMMITTED parity), and explicit StateFailedTakeover
boundary re-assertion (failure-recovery remains unguarded;
asymmetric with COMMITTED/DEGRADED).

### Operator-visible behavior changes

- `nftban firewall reload` (and every internal-caller path like
  `whitelist-session add/remove`, takeover re-runs, etc.) now re-applies
  trust providers when any `TRUST_*_ENABLED="true"` is set — fixes
  silent kernel-set drift after reload on hosts with trust providers
  configured.
- `nftban update` (and `nftban update github`) on hosts with a
  source → RPM or source → DEB migration in their history now proceeds
  via the standard auto-detect path when the migration is clean
  (`INSTALL_STATE=COMMITTED + AUTHORITY=UPDATE` + last-successful-history
  matches current package-db family). Previously refused with exit 13
  `Install Type: mixed`. Genuinely-mixed installs continue to refuse.
- `nftban-installer --mode=install --takeover --force` on a host with
  `INSTALL_STATE=DEGRADED` now refuses with `ExitRefused` (5) unless
  `--allow-recommit` is also passed — closes the protection-gap on
  chronic-DEGRADED hosts (e.g. lab2's D-DEG-1 cascade class).
  Failure-recovery states (`StateFailed*`) continue to allow `--force`
  alone as the supported retry path.

### CI baseline

Post-merge main CI at HEAD `00adedc7` (Lane A merge SHA): **24 SUCCESS
/ 1 SKIPPED / 0 FAILURE across 25 workflows** — including Go Build &
Test (canonical signal for Lane A's predicate + new test cases) plus
all 5 Canonization Gates (Install / Restore / Update / Uninstall /
Runtime Truth), CodeQL, Semgrep, ShellCheck, Bash Validation, OSV-Scanner,
Docker, Smoke Test, Documentation Validation, Architecture Policy,
Migration Coverage Gate, Shell-Delete Guard, Secret Scanning
(Gitleaks), Fuzz Tests, Project Health, Secure Go, Build NFTBan
Packages, OpenSSF Scorecard.

### Non-goals (carried forward as separately-gated future debt)

- **D-FHS Phase D-1 Authority Territory Graph filing** — design-only
  deliverable, deferred since v1.118 Track A.
- **dns2 fleet validation gates beyond v1.125 Lane B verification** —
  `EXECUTE_V126_VALIDATE_DNS2` operator-conditional gate.
- **V117 backlog items B2 / B3 / B4 / B7 / B8** — separate narrow
  lanes, not in V126 scope.
- **Schema-UNFREEZE items** — all deferred (PR-M2b-w2..w7 per-module
  emission waves, PR-M2c new nft named counters, PR-M2d kernel set
  element annotation cookies, PR-M3 cache v2 + PR-M1 CLI, §F4 metrics
  beyond 6 PR-M2b-w1 targets, LoginMon subnet Prometheus emission).
- **Pre-V113 D-* large lanes** — all deferred (D-MET-1, D-MOD-1,
  D-DNS-1, D-FHS-1..5 implementation, D-SHA-1, D-POL-1, D-SEC-1
  SEC-FW-BYPASS-ALERT-GAP-001, D-TRP-1 TRANSPORT-001, D-EGM-1,
  D-PNL-1, D-OSH-1, D-GHC-1, D-WIK-2, D-MIG-1, D-BKT-1 Bucket-C
  14 v0.x tags **NEVER delete remote** per long-standing policy,
  D-RECV-INSTALL-RESULT-JSON-PARSE-001 nftbanpro_cms scope, D-LMA-1,
  R-11, #525 geoip Go panic Lane G).
- **V125 stretch lanes** — R-6 deps retry, R-7 V120 TTY fallback,
  R-8 iptables backup, R-12 nft snapshot-restore, R-14 state atomic
  write remain in the V125 scope file for future cuts.
- **Bucket-C v0.x tag changes** — FORBIDDEN INDEFINITELY per
  long-standing operator policy.
- **MASTER_TODO edits** — FORBIDDEN per workspace control rule
  locked 2026-05-13.

### Hotfix slot

**v1.126.x hotfix slot not authorized** (latent reservation only —
opens only if a v1.126.0 defect surfaces in the fleet rollout).

### Workspace artifacts (no PR, no code)

V126 design + decision chain filed at `AUDIT_190_LIFECYCLE/`:

- `V126_IMPLEMENTATION_ORDER_PLAN.md` (304 lines) — order lock:
  C → B → A; per-lane independence verification; PR strategy;
  release-bundle policy (Option 1 single bundled v1.126.0); §7
  acceptance criteria carried forward into this CHANGELOG entry.
- `V126_TRUST_WHITELIST_RELOAD_MERGE_SCOPE.md` — Lane C scope spec
  + srv3 empirical reproduction.
- `V126_UPDATE_HISTORY_MIXED_INSTALL_DETECTOR_SCOPE.md` — Lane B
  scope spec + dns2 reproduction + 8-case decision matrix.
- `V126_R4_DEGRADED_GATE_EXTENSION_SCOPE.md` — Lane A scope spec +
  lab2 V125 validation reproduction.
- `V125_VALIDATE_LAB2_CLOSURE.md` — lab2 chronic DEGRADED
  reproduction that surfaced Lane A's defect.
- `V125_VALIDATE_SRV3_DEFERRED_WHITELIST_KERNEL_SYNC_ANOMALY.md` —
  srv3 reproduction that surfaced Lane C's defect.

---

## [v1.125.0] - 2026-05-22 — V125 install-robustness: 5-lane minimum cut (dns2-derived backlog)

V125 install-robustness release on top of v1.124.1, bundling the five
narrow Go-only installer-robustness lanes filed in
`AUDIT_190_LIFECYCLE/V125_INSTALL_ROBUSTNESS_SCOPE.md` §3.1 (the
"minimum cut"). Each lane was implemented, audited, monitor-verified
(`go vet`/`go build`/scope-specific `go test`), and merged as a
separately-shippable narrow PR before this release-prep PR was opened.

**Schema 1.83.0 remains frozen** UNCONDITIONALLY. No new validator
field, no new metric, no new Prometheus label, no Status JSON
wire-format key, no `install_state` JSON field added (the new
`StateFailedPreflightDiskSpace` is an enum value within the existing
`STATE` field, not a new key). `internal/validator/types.go` continues
to declare `const SchemaVersionCurrent = "1.83.0"`.

**Daemon binary byte-identical to v1.124.1** (and v1.124.0, v1.123.0,
... v1.114.0). `cmd/nftband/` and `cmd/nftban-core/` are byte-unchanged
across the V125 R-1..R-5 arc — every lane is confined to the installer
+ state-machine + new preflight-package surface. **13-release
identical-daemon-binary streak** preserved (v1.114.0 → v1.125.0).

**No metrics changes. No new schema or config keys. No new systemd
units. No packaging changes** (--rpm / --deb postinst paths unchanged;
the R-4 `--force` gate and R-5 preflight fire identically on
package-triggered runs as on operator-initiated runs, providing the
same operator-friendly improvement). **No polkit changes. No host
contact** during construction.

### Added — five installer-robustness lanes

**R-1 SSH multi-port detection + render — PR #653 (sq `95c1f119`).**
Closes the dns2-class operator-lockout vector. The pre-V125 installer's
`internal/installer/detect/ssh.go::sshFromListener` returned the FIRST
sshd listener; on multi-port hosts (e.g., dns2 with sshd on `:22 + :55000`),
the installer picked `:22` and the rendered nftables allow-set covered
only that port — a fresh install on a host where the operator uses the
high port would lock them out post-install. R-1 makes `DetectSSHPorts`
return the full listener list, picks `$SSH_CLIENT`-aware primary,
extends `RenderNftablesConfMultiPort` to emit all detected ports in
`tcp_ports_in`, and preserves single-port hosts as byte-identical
output (the common case is unaffected).

**R-2 installer concurrent-run lock via flock — PR #654 (sq `3911ecf5`).**
New `internal/installer/lock/` package using `syscall.Flock` with
`LOCK_EX|LOCK_NB`. Acquired at the top of `cmd/nftban-installer/main.go::main`
(after flag-parse, before any state mutation; **skipped during
`--dry-run`** per PR-22B contract). The recorded PID in the lock file
is informational only — the kernel's flock auto-release on process exit
is the authoritative lock source (no `/proc/<pid>/comm` over-validation
per `feedback-trust-kernel-contract`). Closes the state-file race
corruption class (concurrent operator manual + cron-scheduled repair +
RPM `%post` triggered).

**R-3 phase context cancellation honor — PR #656 (sq `3898d8cc`).**
All five phase functions in `cmd/nftban-installer/phases.go`
(phaseDetect / phasePrepare / phaseSwitch / phaseConfigure /
phaseValidate) previously discarded their `context.Context` parameter
(`_ context.Context`), so `--timeout` and SIGINT/SIGTERM could only
reclaim wall-clock at between-phase boundaries — never from inside a
long-running phase. R-3 wires `ctx` into each signature and adds 9
`ctx.Err()` checks at safe interior boundaries (entry guard for every
phase; before deps.InstallMissing, payload.StageAll, authority.Classify,
phaseValidate auto-fix retry, etc.). **phaseSwitch SSH Safety Invariant
preserved**: only ONE interior check in phaseSwitch, placed AFTER
DisableConflicts but BEFORE the atomic
`CleanGhostTables → EnableNftables → AssertSSH → Rebuild → AssertSSH →
RemoveEmergencySSH` chain. Cancelling there leaves emergency-SSH
protection intact; cancelling anywhere inside the chain would risk
breaking the invariant.

**R-4 `--force` / `--allow-recommit` safety gate — PR #657 (sq `c6e71909`).**
The previous `--force` flag re-ran ALL phases on a healthy COMMITTED
host without any confirmation, re-triggering Switch (re-flushing
iptables, re-masking CSF if the operator unmasked manually,
re-rendering config). R-4 adds the `--allow-recommit` companion flag
and refuses `--force` on `state.StateCommitted` unless `--allow-recommit`
is also set. Refusal uses `state.ExitRefused` (=5), not the generic
`ExitFatal`. **Recovery paths unaffected**: `--force` on
`StateFailedRebuild` / `StateFailedRender` / `StateFailedNoFirewall` /
`StateFailedTakeover` / `StateDegraded` continues to work without
`--allow-recommit`. **Package-manager postinst paths unaffected**:
`packaging/deb/postinst` and the RPM `%post` invoke
`nftban-installer --rpm` or `--deb` WITHOUT `--force`, so routine
package upgrades on COMMITTED hosts are unchanged. 11-case truth-table
test in `cmd/nftban-installer/force_recommit_gate_test.go` locks the
predicate.

**R-5 disk-space preflight at end of phaseDetect — PR #658 (sq `d0b2e916`).**
New `internal/installer/preflight/` package with
`EnsureMinDiskFree(path, minBytes)` using `syscall.Statfs`
(`Bavail * Bsize` for non-root-available bytes; converted via the
project's `safeconv.Int64ToUint64OrZero` helper for gosec G115 safety).
Default threshold 500 MB; `NFTBAN_MIN_DISK_FREE_MB` operator-tunable
(invalid env values fall back to default per "safety gate, not parser"
discipline). Called at the END of `phaseDetect`, before any mutation in
phasePrepare/Switch — closes the ENOSPC-mid-install class. New typed
terminal `StateFailedPreflightDiskSpace` added to the state machine
(IsApplyTerminal=true so update-history records the refusal;
IsFailed=true so ExitCode maps to ExitFailed=2). 16-sub-case test
matrix locks both `EnsureMinDiskFree` (pass/fail/bad-path) and
`MinDiskFreeBytes` (default + 4-case valid env + 8-case invalid env).

### Changed — none beyond the additive R-1..R-5 surface above

### Removed — none

### Fixed — operator-facing improvements via R-1, R-4, R-5

Three operator-classifiable defect classes that pre-V125 installer
behavior allowed:
- **Dns2-class operator lockout post-install** (R-1).
- **Accidental destructive recommit on healthy hosts via `--force`** (R-4).
- **ENOSPC mid-install corruption** (R-5).

### Process / lesson-learned this lane

V125 introduced two installer-entrypoint discipline mechanisms — both
filed as workspace docs + Claude memory entries — that paid off across
the R-3/R-4/R-5 PRs:

- `AUDIT_190_LIFECYCLE/V125_INSTALLER_ENTRYPOINT_PRECHECK.md`
  (operator-readable canonical) + `feedback_installer_entrypoint_precheck.md`
  (operative Claude memory): 7-question precheck applied BEFORE the first
  line of code on any PR touching `cmd/nftban-installer/{main,flags,phases}.go`
  or `internal/installer/{state,lock,executor}/` or any new package
  called from `main.go` before phase dispatch.

- Workflow-first sub-rule (Q4 addendum): the `.github/workflows/secure-go.yml`
  workflow runs `gosec` with the `-nosec` flag, which disables inline
  `#nosec` comment suppression. For G304 (and other suppressible
  classes), use code-truth sanitization (`filepath.Clean(path)` per
  the established project convention in `internal/botguard/*`,
  `internal/loginmon/*`, etc.). For G115 (integer overflow conversion),
  use `internal/safeconv/*` helpers (per the established convention in
  `internal/watchdog/collector_system.go`).

Cycle-cost retrospective: R-1 / R-3 / R-4 each landed in **1 CI cycle**;
R-2 took **5 cycles** (the cautionary tale that triggered the precheck
filing); R-5 took **2 cycles** (gosec G115 caught on first run; fixed
via `safeconv.Int64ToUint64OrZero` next push, mirroring the precedent
in `internal/watchdog/collector_system.go:202-203,266`).

### Forbidden surfaces — zero-touched across the V125 arc

- daemon (`cmd/nftband/`, `cmd/nftban-core/`) — byte-unchanged
- schema (`internal/validator/`) — 1.83.0 frozen
- metrics (`internal/metrics/`) — byte-unchanged
- packaging (`packaging/`) — byte-unchanged
- `install/systemd/` — byte-unchanged
- `install/polkit/` — byte-unchanged
- README PR #586, Dependabot PRs, MASTER_TODO, Bucket-C v0.x tags —
  all untouched per V125 §0 lane discipline

### Stretch lanes NOT included in v1.125.0

Per operator decision at the gate ("My recommendation: release after R-5
unless there is a specific urgent stretch-lane reason"), the V125
scope-spec stretch lanes are explicitly DEFERRED:
- R-6 deps retry/backoff (~40 LOC)
- R-7 V120 SSH peer-IP TTY fallback (~30 LOC)
- R-8 iptables backup before disarm (~100 LOC; MED risk)
- R-12 nft snapshot-restore on rebuild failure (~50 LOC)
- R-14 install_state atomic write + schema version (~50 LOC)

These remain in the scope file for v1.125.1 / v1.126 / future cuts.

### v1.125.x hotfix slot

**Not authorized** (latent reservation only — opens only if a v1.125.0
defect surfaces).

---

## [v1.124.1] - 2026-05-21 — V124 hotfix: clear Project Health workflow shellcheck baseline

V124 hotfix release on top of v1.124.0, clearing the **`Project Health`
workflow baseline shellcheck failure** that had persisted on `main` since
at least 2026-05-19, plus two related shellcheck issues flagged locally
but not by the older CI shellcheck version.

**Zero daemon binary change.** **Zero production CLI behavior change.**
`/usr/lib/nftban/bin/nftband` is byte-identical to v1.124.0 (and v1.123.0,
v1.122.0, ... v1.114.0). **12-release identical-daemon-binary streak**
preserved (v1.114.0 → v1.124.1).

**Schema 1.83.0 remains frozen** UNCONDITIONALLY. No new validator field,
no new metric, no new Prometheus label, no Status JSON wire-format key,
no `install_state` field, no nftables kernel set / chain / table name
change. `internal/validator/types.go` continues to declare
`const SchemaVersionCurrent = "1.83.0"`.

**Background:** PR #650 (v1.124.0) and the V123 release lane (#646–#649)
all merged with the `Project Health` workflow advisory-failing for
7/306 files. The failure was pre-existing and unrelated to either V123
or V124 narrow PR diffs, but it was noisy enough that the operator
classified it for cleanup before any further release work proceeded.
This v1.124.1 hotfix targets exactly those 7 baseline shellcheck
findings plus two additional findings flagged locally on
`cli/lib/nftban/cli/cmd_firewall.sh` by a newer shellcheck version (the
older CI shellcheck did not catch them; both are dead-code-by-design
markers added in V120 PR #637 and documented as such).

### Fixed — Project Health workflow shellcheck baseline (8 sites)

**1. `scripts/ci/test-install-method-detection.sh:107` (SC1090 warning)**
   The pre-existing `# shellcheck disable=SC1090` directive was attached
   to the `local` declaration two lines above the actual `source
   "$fixture_env"` call, so the directive applied to the wrong command
   and the warning still fired on the source line. Fix: move the
   directive to be immediately above the `source` line and switch to the
   more precise `# shellcheck source=/dev/null` form (declares "this
   source target is dynamic and shellcheck need not follow it"). Comment
   block added explaining the move so a future reader does not "fix" it
   back into the broken position.

**2. `scripts/ci/test-systemd-execstart-payload-resolution.sh:417`
   (SC2034 warning)** — `local deb_unit_file="$deb_sysd/$unit"` is
   declared but not consumed in the current code path (the assertion is
   RPM-side authoritative; DEB-side parity is verified earlier via the
   `comm -12` set-intersection check). The variable was kept by the
   author for symmetry with `rpm_unit_file` and as a future-checks
   anchor. Fix: explicit `# shellcheck disable=SC2034` directive with a
   1-line comment explaining the intentional retention; behavior
   unchanged.

**3. `scripts/test-package-effective-parity.sh:305` (SC2034 warning)** —
   `local row path type expected_type` declared 4 locals; `expected_type`
   was assigned via `cut -d'|' -f2` on line 305 but never read in the
   function (the aggregator validates type/owner/group via stat-derived
   tags below; `expected_type` from the EXPECTED_TABLE was not consulted
   in this fresh-stat code path). Fix: remove `expected_type` from the
   local declaration AND remove the now-unused `cut` assignment.
   1-line comment added explaining the removal + how to reintroduce if
   a future check needs it.

**4-7. `scripts/ci/fixtures/execstart-resolution/{fail-parity-unit,pass-clean}/{rpm,deb}/usr/sbin/nftban`
   (4 files; SC2148 error)** — Each fixture file was 0 bytes (empty
   stub). The `health_check.sh` workflow sweep finds these via
   `find ... -name "nftban"` because they are named without an extension,
   and shellcheck flags them with SC2148 ("Tips depend on target shell
   and yours is unknown. Add a shebang or a 'shell' directive."). The
   fixtures are consumed by `scripts/ci/test-systemd-execstart-payload-resolution.sh`
   which checks file presence and path-resolution semantics, NOT file
   content. Fix: add a `# shellcheck shell=bash` directive line + brief
   purpose comment to each fixture (file goes from 0 bytes → ~430 bytes
   of comment + directive; zero executable code; test semantics
   unchanged because the test does not read content).

**8. `cli/lib/nftban/cli/cmd_firewall.sh:651` (SC2327 warning) +
   `:662` (SC2328 error)** — The `removed=$(awk -v ip="$ip" ' ...
   ' "$file" 2> >(tail -1) > "$tmp")` block uses an intentionally-
   dead-code outer command-substitution: awk's stdout is redirected to
   `$tmp`, awk's stderr is piped through `tail -1` via process
   substitution, and the outer `$()` captures nothing. The real
   "removed" count comes from the IP-presence re-check below (see
   "Re-count removed by diffing against the original" block). The
   pattern was added in V120 PR #637 (squash `38cc86f6`) operator
   session-whitelist guard and was working-as-designed at the time;
   newer shellcheck (>= 0.10) catches the dead capture. Fix: extend
   the existing `# shellcheck disable=SC2016` directive (originally
   silencing the single-quoted awk script warning) to also cover
   `SC2327,SC2328`, with an inline comment explaining the intentional
   dead-code pattern and noting that a cleaner refactor (drop the
   capture entirely, drop awk's END block + count++) is deferred to
   V125+. Behavior is byte-equivalent to v1.124.0; this is purely a
   linter-directive update.

### Verification

- Whole-tree shellcheck sweep (replicating `health_check.sh::check_shellcheck`
  exactly: `find . -type f \( -name "*.sh" -o -name "nftban" \)
  ! -path "*/.git/*" ! -path "*/build/*" ! -path "*/node_modules/*"` then
  `shellcheck -x -S warning <file>` per match): **0/306 files failed**
  on the v1.124.1 commit (was 7/306 pre-hotfix).
- `Project Health` workflow expected to PASS on this commit — closing the
  only remaining baseline advisory CI failure across v1.120 → v1.124
  release lanes.
- All 10 required branch-protection checks unaffected (Build & Test,
  CodeQL Go, Docs Quality, Policy Gates, Scan for secrets, Semgrep,
  Shell Quality, ShellCheck, etc. all already passed for the cmd_firewall.sh
  edit because the shellcheck-disable directive update is a 1-line
  comment-style change in a file the existing tests already cover).
- Shell test suites unaffected (no shell-test changes in this hotfix);
  pre-hotfix tests still PASS: `cmd_status_authority_test.sh` 15/15,
  `cmd_firewall_takeover_test.sh` 39/39, `cmd_firewall_whitelist_session_test.sh`
  33/33, `test_update_version_normalization.sh` 21/21,
  `test_update_ssh_port_durability.sh` 8/8.

### Scope boundaries held

- **ZERO daemon binary change** — `cmd/nftband/`, `cmd/nftban-core/`,
  `cmd/nftban-installer/`, `internal/installer/`, `internal/whitelist/`,
  `internal/blacklist/`, `internal/loginmon/`, `internal/safety/`,
  `internal/runtime/`, `internal/profile/`, `internal/validator/`,
  `internal/health/`, `internal/lifecycle/`, `internal/portal/`,
  `internal/dns2/`, `internal/panel/`, `internal/nftbackend/`,
  `internal/opqueue/`, `internal/setsync/`, `internal/metrics/`,
  `internal/loginmon/pipeline/` — all byte-unchanged.
- **ZERO** schema / metrics / lifecycle / packaging / systemd / polkit /
  install / build / release-process changes.
- **ZERO** new V124 features (single-purpose hotfix; no new behavior;
  no new CLI surface; no new flag; no new test fixture beyond the
  4 nftban-stub directive updates).
- **No `NFTBAN_MASTER_PLAN_AND_PENDINGS.md` edit.**
- **No `MEMORY.md` edit.**
- **No host contact during release-prep.**
- **No tag/release/PR activity beyond the v1.124.1 release-prep PR itself.**

### Files touched

8 source files (shellcheck-directive updates / fixture comments) +
4 release-prep files:

- `scripts/ci/test-install-method-detection.sh` (+6/-1)
- `scripts/ci/test-systemd-execstart-payload-resolution.sh` (+5/-0)
- `scripts/test-package-effective-parity.sh` (+5/-2)
- `scripts/ci/fixtures/execstart-resolution/fail-parity-unit/rpm/usr/sbin/nftban` (+7/-0; from 0 bytes)
- `scripts/ci/fixtures/execstart-resolution/fail-parity-unit/deb/usr/sbin/nftban` (+7/-0; from 0 bytes)
- `scripts/ci/fixtures/execstart-resolution/pass-clean/rpm/usr/sbin/nftban` (+7/-0; from 0 bytes)
- `scripts/ci/fixtures/execstart-resolution/pass-clean/deb/usr/sbin/nftban` (+7/-0; from 0 bytes)
- `cli/lib/nftban/cli/cmd_firewall.sh` (+8/-1; directive extension only)
- `VERSION` (1.124.0 → 1.124.1)
- `STATUS.md` (v1.124.1 release-lane added; v1.124.0 demoted to Prior)
- `CHANGELOG.md` (this entry prepended)
- `cli/lib/nftban/core/nftban_fhs_spec.sh` (header version-banner only; FHS path-table body byte-unchanged)

### Release-prep envelope (this PR)

Single squash PR opens the hotfix as a bundle. Tag `v1.124.1` is created
against the merge SHA. SLSA workflow auto-publishes the GitHub release
with 14 assets. Docker tags `v1.124.1` / `1.124.1` / `1.124` (advanced
from `1.124` pointing at v1.124.0) / `latest` / `sha-<8>` all expected
HTTP 200 post-publication.

### Forbidden surfaces

- `cmd/nftband/` byte-unchanged
- `cmd/nftban-core/` byte-unchanged
- `cmd/nftban-installer/` byte-unchanged
- `internal/installer/` byte-unchanged
- Schema 1.83.0 frozen
- No new V124 candidates beyond the shellcheck baseline cleanup
- No V125 install-robustness lanes (those open separately after
  v1.124.1 ships and `Project Health` is verified-green on `main`)

---

## [v1.124.0] - 2026-05-20 — V124 urgent CLI fix: takeover guidance + wrapper dispatch + help clarity

V124 urgent bugfix release on top of v1.123.0, addressing four user-facing
text/wrapper-dispatch bugs surfaced during the **dns2 source-install →
v1.123.0 RPM migration (2026-05-20)**. The v1.123.0 installer/takeover
engine itself proved correct (15/15 post-install assertions PASS, V107.2
invariant `5e3f7498f2cc...` `/usr/sbin/csf.disabled` byte-equal preserved,
V120 operator session-whitelist auto-seed worked, panel-survival validated,
DirectAdmin integration intact through migration). What needed fixing was
the **CLI surface above the Go layer**.

**Zero daemon binary change** — `/usr/lib/nftban/bin/nftband` byte-identical
to v1.123.0 because no `cmd/nftban-installer/`, `cmd/nftband/`,
`cmd/nftban-core/`, or `internal/installer/` Go code is touched in this
release (T9.1 in-test guard asserts `flags.go` byte-equal vs main).
**11-release identical-daemon-binary streak** preserved (v1.114.0 →
v1.124.0).

**Schema 1.83.0 remains frozen** UNCONDITIONALLY. No new validator field,
no new metric, no new Prometheus label, no Status JSON wire-format key,
no `install_state` field, no nftables kernel set / chain / table name
change. `internal/validator/types.go` continues to declare
`const SchemaVersionCurrent = "1.83.0"`.

**No release-process changes.** **No metrics changes.** **No new schema or
config keys.** **No new systemd units.** **No packaging changes.** **No
portal / nftbanpro_cms changes.** **No Bucket-C v0.x tag changes**
(D-BKT-1 FORBIDDEN INDEFINITELY). **No MASTER_TODO mutation.** **No
host contact during release-prep** (workspace dev host only; dns2
migration that surfaced these bugs is closed and untouched by this PR).

### Fixed — V124 takeover CLI guidance + wrapper dispatch + help clarity (PR #650 sq `a0755fe1`)

Four bugs classified by user-facing surface, each pinpointed at exact
file:line, each verified against the dns2 migration evidence pack.

- **BUG-A — `cli/lib/nftban/cli/cmd_status.sh:619` ACTION text recommended
  the unwired entrypoint.** When `install_state AUTHORITY=AMBIGUOUS` and
  `CONFLICTS` is non-empty, `nftban status` emitted: `ACTION: Run 'nftban
  update --panel-auto-takeover' to disarm conflicts.` On dns2 this returned
  `ERROR: Unknown command: --panel-auto-takeover`. Fixed: emits the wired
  `nftban firewall takeover --panel-auto-takeover` recommendation plus a
  multi-line explanation block clarifying disarm purpose and that
  `--panel-auto-takeover` is a **permission** flag (not the takeover
  authorizer).

- **BUG-B — `cli/lib/nftban/cli/cmd_update.sh::nftban_cmd_update` parse
  order.** The V117 env-mirror filter (lines pre-v1.124 around 2173-2183)
  that strips `--panel-auto-takeover` from argv and exports
  `NFTBAN_PANEL_AUTO_TAKEOVER=1` ran AFTER `cmd="${1:-}"` extraction. For
  the bare form `nftban update --panel-auto-takeover` (no subcommand
  between `update` and the flag), `$cmd` captured the flag and fell
  through to the `case "$cmd" in` default → "Unknown command" error.
  Fixed: filter loop moved ABOVE `cmd="${1:-}"` extraction so the flag is
  stripped from argv first, then `$cmd` captures the (possibly-empty)
  next positional cleanly. Existing subcommand forms
  (`nftban update check --panel-auto-takeover`,
  `nftban update github --panel-auto-takeover [VERSION]`, etc.) remain
  byte-stable. Test guard `T7.4` asserts the filter loop precedes the
  cmd extraction by line number.

- **BUG-C — `cli/lib/nftban/cli/cmd_firewall.sh::firewall_takeover`
  wrapper missing `--takeover` flag pass-through.** Pre-v1.124 the
  wrapper unconditionally built `args=(--mode=upgrade)` and only
  appended `--panel-auto-takeover` (line ~820). The wrapper exit-0
  "succeeded" without authorizing the takeover branch because
  `--panel-auto-takeover` is a permission flag
  (`cmd/nftban-installer/flags.go:127-128`) — the **authorizer** is
  `--takeover`, which sets `NFTBAN_TAKEOVER=1`
  (`cmd/nftban-installer/main.go:104-106`) and reaches
  `switchop.DisableConflicts` via the authority classifier's takeover
  branch (`cmd/nftban-installer/phases.go:259`). On dns2 the wrapper
  invocation showed `Invoking installer: ... --mode=upgrade
  --panel-auto-takeover`, the upgrade lifecycle rebuilt rules cleanly,
  but `install_state AUTHORITY` stayed `AMBIGUOUS` with `CONFLICTS=CSF`
  persisting. The direct installer call
  `/usr/lib/nftban/bin/nftban-installer --mode=install --takeover
  --panel-auto-takeover --force --verbose` was the path that actually
  succeeded (15/15 assertions PASS, AUTHORITY=UPDATE,
  CONFLICTS=(empty)). Fixed: wrapper now branches:
  - non-dry-run: `args=(--mode=install --takeover --force)`
  - dry-run: `args=(--mode=upgrade --dry-run)` (because the installer
    explicitly rejects `--mode=install --dry-run` with "an honest
    install dry-run orchestrator is out of scope for v1.100 PR-22B")

  `--force` is needed because hosts arriving at this wrapper typically
  have `install_state INSTALL_STATE=COMMITTED` (terminal). Both code
  paths append `--panel-auto-takeover` when the operator passed it.
  Test guards: `T10.1-T10.3` static source guard (assert correct args
  construction, assert pre-v1.124 broken `args=(--mode=upgrade)`
  unconditional line not present); `T11.1-T11.6` runtime guard via
  `unshare -r` (fake-root non-dry-run invocation captures stub argv +
  asserts `--mode=install --takeover --force` present, `--mode=upgrade`
  absent).

- **BUG-D — `docs/operator/CSF_REMOVAL_AND_TAKEOVER.md` documented the
  wrong installer invocation.** The doc stated that the wrapper invokes
  `nftban-installer --mode=upgrade --panel-auto-takeover` — empirically
  proven incorrect by dns2 (that combination ran the upgrade lifecycle
  but did NOT disarm conflicts). Updated to the correct
  `nftban-installer --mode=install --takeover --force
  [--panel-auto-takeover]` with a clear permission-vs-authorizer
  paragraph. Also added an explicit **DirectAdmin CustomBuild command
  comparison table** to prevent future reviewer drift:
  - nftban **uses** `da build set csf no` (conservative; writes `csf=no`
    to `/usr/local/directadmin/custombuild/options.conf`; reversible by
    `da build set csf yes`; files preserved). Invocation site:
    `internal/installer/switchop/takeover.go:172` via
    `exec.Run(buildCmd, "set", "csf", "no")`.
  - nftban **intentionally does NOT use** `da build remove_csf`
    (destructive; would delete `/etc/csf/` + `/usr/sbin/csf` +
    `/usr/sbin/lfd` + `/usr/local/directadmin/plugins/csf` +
    `/etc/cron.d/csf-cron` + `/etc/cron.d/lfd-cron`) because that
    would destroy the cron-backup manifest and `/etc/csf/`
    configuration that the `nftban firewall restore csf` path
    (Amendment 1/2/3 of `internal/installer/restore/contract.md`)
    depends on. Operators who want CSF permanently gone can run
    `da build remove_csf` themselves AFTER nftban takeover lands —
    operator territory, not nftban's responsibility.

### Added — Help / auto-text clarity (V124 gate amendment in PR #650)

Operators must clearly understand the takeover model. PR #650 expanded
user-facing text on every CLI surface that mentions takeover:

- `cmd_status.sh` ACTION block: now explains disarm purpose + flag
  semantics (PERMISSION vs AUTHORIZER) in a multi-line block, not a
  single-sentence directive.

- `cmd_firewall.sh --help` block reorganized:
  - PERMISSION flag (`--panel-auto-takeover`) clearly disambiguated
    from AUTHORIZER (`--takeover`).
  - `--dry-run` preview semantics explicit: dry-run uses upgrade-mode
    preview because install-mode dry-run is not implemented; dry-run is
    NOT an exact simulation of install-mode takeover and does NOT
    perform conflict disarm or authority transition.
  - Underlying real-mode and dry-run installer invocations documented
    inline so operators can verify what the wrapper actually runs.

- `docs/operator/CSF_REMOVAL_AND_TAKEOVER.md` "The codified command"
  section rewritten: explicit "supported takeover" wording on the
  non-dry-run form; explicit do-not-use note on bare `nftban update
  --panel-auto-takeover` as primary recovery action; explicit dry-run
  semantics paragraph (preview-only, not exact install-mode simulation).

### Test coverage extended

- `cli/lib/nftban/tests/cmd_status_authority_test.sh` — F1 extended:
  - pre-v1.124 dead-end-text regression guard (asserts `nftban update
    --panel-auto-takeover` text NOT emitted)
  - clarity assertions (disarm purpose + permission-flag clarification
    present)
  - 15/15 PASS (was 13)

- `cli/lib/nftban/tests/cmd_firewall_takeover_test.sh` — extended with
  15 new assertions:
  - **T1.6-T1.12** (help-text clarity): PERMISSION flag mentioned,
    "does NOT itself authorize takeover" present, "supported takeover"
    phrasing for non-dry-run, dry-run "does NOT perform conflict
    disarm" present, dry-run "NOT an exact" simulation present,
    underlying `--mode=install --takeover --force` invocation
    documented, underlying `--mode=upgrade --dry-run` invocation
    documented.
  - **T7.3-T7.4** (BUG-B fix verification): bare-form env-mirror set;
    static-source guard asserts filter loop precedes cmd extraction by
    line number.
  - **T10.1-T10.3** (BUG-C static source guard): non-dry-run path uses
    `--mode=install --takeover --force`; dry-run path uses
    `--mode=upgrade --dry-run`; pre-v1.124 unconditional
    `args=(--mode=upgrade)` line absent.
  - **T11.1-T11.6** (BUG-C runtime guard via `unshare -r`): non-dry-run
    forwards `--mode=install`, `--takeover`, `--force`,
    `--panel-auto-takeover`; does NOT forward `--mode=upgrade` or
    `--dry-run`.
  - 39/39 PASS (was 24).

- **T9.1** in-test scope-regression guard (`cmd/nftban-installer/flags.go`
  byte-unchanged vs main) — PASS, confirming zero Go change.

### Sibling-test no-regression confirmation

Run locally on Fedora 44 dev host pre-merge of PR #650 (all PASS, no
regression introduced by the V124 edits):

- `cmd_firewall_whitelist_session_test.sh`: 33/33 PASS
- `test_update_version_normalization.sh`: 21/21 PASS
- `test_update_ssh_port_durability.sh`: 8/8 PASS

### CI tally (PR #650 head `a4509405`)

- **Required checks: 10/10 PASS** — Build & Test, Build/Test/Scan (Go),
  CodeQL Analysis (Go), Docs Quality, Policy Gates, Scan for secrets,
  Semgrep Scan, Shell Quality, ShellCheck (Find bash errors), Validate
  binary consistency (RPM vs DEB).
- **Non-required PASS: 41** — RPM/DEB build matrix (8), RPM/DEB install
  matrix (8), Runtime Truth (3), Update Canonization (3), Build Go
  binaries, Build Docker Image, CLI Smoke Test, GitGuardian, Migration
  Coverage Gate H3.2, OSV Vulnerability Scan, P0/P1 license + SPDX +
  Lychee + libyear, Semgrep OSS, osv-scanner inline, Validate bundled
  deps + ExecStart + RPM/DEB parity, Dependency Review, Shell-Delete
  Guard, Detailed ShellCheck.
- **Skipped (non-required, expected):** 2 — Go Security Analysis
  (correctly skipped because Detect-Go-changes found zero diff),
  Typosquat/Malware (Socket) behavioral scan (only runs on dep changes).
- **Failed (non-required, advisory):** 2 — `Project Health` ×2.
  Pre-existing baseline failure on main since at least 2026-05-19
  (`scripts/ci/test-install-method-detection.sh:107` SC1090 +
  `scripts/ci/fixtures/execstart-resolution/fail-parity-unit/rpm/usr/sbin/nftban`).
  Neither file is in PR #650's diff. Same advisory failure pattern on
  v1.123.0 release commit (`42314b46`) + PRs #646/#647/#648/#649.
  Classified as "ci ok finished" per project precedent.

### Scope boundaries held (per V124 gate)

- **ZERO Go change** (`cmd/nftban-installer/` + `internal/installer/`
  + `cmd/nftband/` + `cmd/nftban-core/` byte-unchanged; T9.1 asserts).
- **ZERO daemon binary impact.**
- **ZERO** metrics / lifecycle / packaging / systemd / polkit / install /
  build / release-process changes.
- **ZERO** host contact during PR construction.
- **No new V124 candidates beyond #650.** The other V124 backlog items
  in `NFTBAN_MASTER_PLAN_AND_PENDINGS.md` §3 Part A (`V124-B-2`
  whitelist-session JSON envelope, `V124-B-3` emergency-table
  classification docs, `V124-HK-1` issue #619 close, `V124-OSV-WF`
  workflow permission toggle, `V124-OSV-POLISH` GO-2026-4918 rationale
  polish) explicitly deferred per operator instruction "in .124 and
  .125 we dont touch old worklog we fix taht we have 124 solve from
  backlog DNS2".

### dns2 host status post-migration

dns2 is now: `INSTALL_STATE=COMMITTED`, `INSTALL_VERSION=1.124.0`-eligible
(currently at v1.123.0; will pick up v1.124.0 on next regular update),
`AUTHORITY=UPDATE`, `CONFLICTS=(empty)`, `PANEL=directadmin`, all 9
timers active, DA :2222 reachable, named active, SSH :55000 preserved.
Fleet parity achieved across lab2 / monitor / srv1-4 / lab4 / dns1 /
dns2 on the v1.123.0 baseline plus the v1.124.0 CLI-clarity overlay.

### Deferred to v1.125+ (workspace-only scope filed)

Per operator instruction, v1.125 is the **install-robustness lane**
(separate from v1.124's text/help fixes). Plan-only scope filed at
`AUDIT_190_LIFECYCLE/V125_INSTALL_ROBUSTNESS_SCOPE.md` (17 lanes
identified, file:line-cited against HEAD `a0755fe1`):

- **v1.125.0 minimum cut (5 quick wins, ~340 LOC):** SSH multi-port
  detection + render, installer flock concurrent-run lock,
  phase-context honor, `--force` + `--allow-recommit` companion gate,
  disk-space preflight.
- **v1.125.0 stretch (4 lanes, ~170 LOC):** dependency-install retry,
  V120 SSH peer-IP TTY fallback, iptables-pre-disarm snapshot,
  `install_state` atomic write + schema version.
- **v1.126+ defer (8 lanes):** source-install mutating uninstall
  (PR-23/25/26), install-mode dry-run orchestrator, cPanel/Plesk
  takeover-disarm parity, nft ruleset snapshot-restore on rebuild fail
  (if not in v1.125.0), Configure-phase rollback, clock/fs-writable/DNS
  preflights, SELinux/AppArmor preflight, install metrics emission.

### Release-prep envelope (this PR)

- `VERSION` (1.123.0 → 1.124.0)
- `STATUS.md` (v1.124.0 release-lane added; v1.123.0 demoted to "Prior
  release lane")
- `CHANGELOG.md` (this entry prepended)
- `cli/lib/nftban/core/nftban_fhs_spec.sh` (header version-banner only;
  FHS path-table body byte-unchanged — PR #650 did not touch
  `build/fhs-spec.yaml`)

---

## [v1.123.0] - 2026-05-19 — V123 small-cleanup: man-page decommission completion + OSV suppression refresh

V123 small-cleanup release on top of v1.122.0. Bundles three merged
narrow-cleanup PRs that complete the man-page decommission lane (begun
in v1.95.0's registry-canonical pivot) and refresh the CI OSV-Scanner
suppression list. **Zero daemon binary change** — `/usr/lib/nftban/bin/nftband`
is byte-identical to v1.122.0 because no exported runtime API was touched.
Source-side changes are confined to docs deletions, an orphan helper
script deletion, comment rephrases, uninstall test allowed-prefix
removal (Go test-only, no behavior change), and a CI suppression-list
data refresh. **10-release identical-daemon-binary streak** preserved
(v1.114.0 → v1.123.0).

**Schema 1.83.0 remains frozen** UNCONDITIONALLY. No validator field,
no new metric, no new Prometheus label, no Status JSON wire-format
key, no `install_state` field, no nftables kernel set / chain / table
name change. `internal/validator/types.go` continues to declare
`const SchemaVersionCurrent = "1.83.0"`.

**No dns2 migration in v1.123.0.** The dns2 source-install → RPM
migration design is separately gated and deferred. **No metrics
changes.** **No new schema or config keys.** **No new systemd
units.** **No portal / nftbanpro_cms changes.** **No Bucket-C
v0.x tag changes** (D-BKT-1 FORBIDDEN INDEFINITELY). **No
MASTER_TODO mutation.** **No host contact during the V123 lane.**

### Removed — V123 B-1 stale man-page sources (PR #646 sq `c08c64c0`)

- `install/man/man8/nftban.8` (DELETED, –646 LOC) — header `.TH NFTBAN 8 "April 2026" "NFTBan 1.77.0"`; 44 minor versions stale relative to v1.122.0; last meaningful update at commit `eb7d99bb` (v1.77.0). Never packaged by RPM (`packaging/build_nftban.sh:1734` explicitly excluded it: "Man page intentionally not shipped — CLI docs are registry-driven"). Never installed by source-install either due to a pre-existing path typo at `internal/installer/payload/payload.go:490` (`srcRel: "install/man/nftban.8"` missing the `man8/` segment; `optional: true policyAlways` silently skipped). Net production impact: zero hosts had `/usr/share/man/man8/nftban.8` deployed; the source file's only effect was to confuse future readers.

- `install/man/man8/nftban-suricata.8` (DELETED, –189 LOC) — pre-v1.77 stale companion to `nftban.8`.

- `commands.registry.yml` header (–1 LOC) — removed the vestigial `"- Man page generation"` line from the channel list. Surviving channels (`CLI help output`, `Wiki documentation`, `Bash completion`, `RBAC enforcement`) remain accurate.

### Changed — V123 B-1 residual man-page reference hygiene (PR #647 sq `a65d56d5`)

Completes the man-page decommission across the 11 surrounding surfaces left behind by PR #646, per `V123_B1_RESIDUAL_REFS_HYGIENE_SCOPE.md` + `V123_B1_RESIDUAL_REFS_HYGIENE_SCOPE_AMENDMENT.md` (challenge-and-counter-sweep audit):

- `internal/installer/payload/payload.go` — deleted the orphaned man-page payload entry at line 490; rephrased section-header comment at line 487 from `// Other shipped artifacts: bash completion, man page (optional)` to `// Other shipped artifacts: bash completion (optional)`.
- `internal/installer/uninstall/artifacts.go` — preserved `/usr/share/man/man8` in `isSharedDestDir` as defense-in-depth against future regressions (no current payload destination targets it after Surface 1 removal); added 5-line explanatory comment block citing PR #646 + this PR.
- `internal/installer/uninstall/artifacts_test.go` — deleted `/usr/share/man/man8/nftban` from the `allowedPrefixes` test list (no man8 dst remains after Surface 1); preserved the forbidden-parent `/usr/share/man/man8` entry in `forbiddenParents`.
- `packaging/build_nftban.sh` — deleted `${deb_root}/usr/share/man/man8` mkdir from the DEB Bucket-2 system-dirs block; rephrased the build_deb() decommission comment (lines 1732–1742) to past tense citing PR #646 + this PR; rephrased the parallel RPM `%install` comment (lines 527–529) to past tense, symmetric with the build_deb() rephrase.
- `scripts/update_man_page.sh` (DELETED, –170 LOC) — orphan helper script whose `MAN_SOURCE` target was deleted in PR #646.
- `scripts/lint-registry-parity.sh` — deleted the G15-B man-page parity block + the `MANPAGE=` variable; rephrased meta:description to drop `"man page,"`. G15-A completion parity check preserved. After this change, the lint emits zero G15-B WARN lines (was 70 between PR #646 and PR #647) while continuing to exit 0.
- `.github/workflows/ci-architecture.yml` — rephrased the G15 step's leading comment to drop `"+ man page match registry"`; replaced with a 4-line explanatory comment citing PR #646 + this PR.
- `CHANGELOG.md:4538-4539` — **PRESERVED** as historical append-only entry (Keep-a-Changelog convention).
- `packaging/deb/changelog:207` — **PRESERVED** as historical append-only entry (Debian Policy Manual §4.4 / `dch(1)` convention).

Net diff for PR #647: 7 files / -220 / +32.

### Changed — V123 B-OSV CI suppression refresh (PR #648 sq `e9747135`)

- `osv-scanner.toml` (+35 / 0) — appended 8 new `[[IgnoredVulns]]` entries for Go stdlib CVE IDs published since the last successful weekly auto-refresh on 2026-05-04. Auto-generated by `tools/refresh-osv-suppressions.sh --apply` against `api.osv.dev/v1/query` with `OSV_TARGET_GO_VERSION=1.25.8` — the canonical entries the broken auto-refresh workflow would have produced. New GO-IDs covered: `GO-2026-4918` (HTTP/2 transport infinite loop on bad `SETTINGS_MAX_FRAME_SIZE` — patched in `golang.org/x/net v0.53.0` embedded by our Go 1.25.8 toolchain; same GO-ID covers both stdlib and `golang.org/x/net@0.52.0` reporting surfaces, no dep bump required), `GO-2026-4971` / `4976` / `4977` / `4980` / `4981` / `4982` / `4986` (stdlib `net` / `net/http` / `net/mail` / `html/template` issues — patched in Go 1.25.10+, "out of scope for current build profile (1.25.8 builders)" class symmetric with pre-existing `GO-2026-4864` .. `GO-2026-4947` entries). `IgnoredVulns` count 26 → 34.

- **Operator-only advisory (NOT addressed in v1.123.0):** the weekly `.github/workflows/osv-suppress-refresh.yml` auto-refresh workflow remains BROKEN pending a repository-admin setting toggle — enable "Allow GitHub Actions to create and approve pull requests" in Settings → Actions → General → Workflow permissions. Until enabled, OSV suppression updates must continue as manual PRs of PR #648's shape.

### CI baseline-advisory pattern delta

Before V123 B-OSV (PR #648): every NFTBan PR + main commit fired a 3-failure **baseline-advisory triplet** that was acknowledged across V120 / V121 / V122 release cycles:

- `OSV Vulnerability Scan`: FAILURE — stale suppression-list drift, not runtime exposure
- `Project Health`: FAILURE (×2)

After PR #648, the triplet reduces to a **doublet**:

- `OSV Vulnerability Scan`: **SUCCESS** ✅
- `Project Health`: FAILURE (×2) — baseline advisory, non-blocking, unchanged

The v1.123.0 release-prep / verify / tag / closure cycle and all subsequent V124+ work will see the doublet pattern rather than the triplet.

### Closes

- **V123 B-1**: stale man-page source decommission (PR #646)
- **V123 B-1 residual**: man-page reference hygiene completion (PR #647)
- **V123 B-OSV**: OSV suppression-list drift since 2026-05-04 (PR #648)
- **OSV Vulnerability Scan baseline-advisory class** — root cause was stale suppression list (NOT runtime exposure); reduced from triplet to doublet for all future NFTBan PRs + main commits

### Mechanism unchanged

- `internal/validator/types.go` (schema 1.83.0 frozen) — byte-identical to v1.122.0
- `cmd/nftband/**`, `cmd/nftban-core/**` — no Go change; **daemon binary byte-identical to v1.122.0**
- `internal/metrics/**` — no change
- `install/systemd/*` — byte-identical (only V122 PR #642 touched `nftban-unified-exporter.service`; V123 leaves all units untouched)
- `build/fhs-spec.yaml` — byte-identical (no install path moved this cycle)
- `commands.registry.yml` — byte-identical to v1.122.0 (PR #646 was the only header edit, already in v1.122.0)
- `go.mod` / `go.sum` — byte-identical to v1.122.0 (no dependency bumps in V123; OSV refresh is data-only suppression list, not a dep change)
- `tools/refresh-osv-suppressions.sh` — byte-identical (only its output changed, not the tool itself)
- Polkit / panel detection / nftables templates — byte-identical
- `MASTER_TODO*` — byte-identical
- Bucket-C v0.x tag paths — byte-identical (D-BKT-1 FORBIDDEN INDEFINITELY)

### Continuous protection preserved

v1.112.2 `status=226/NAMESPACE` regression class continues to be guarded by the workflow_run-triggered Fresh-Install Namespace Guard built across V114 PRs #612–#620 + V115 PR #624's `/bin/kill` polish. **32/32 A1–A4 assertions expected PASS on the v1.123.0 baseline** post-tag, continuing the streak from v1.122.0 / v1.121.0 / v1.120.0 / v1.119.0 / v1.118.0 / v1.117.0 release-prep verification.

### Files touched (the entire envelope)

V123 candidate envelope already on `main` before this release-prep:

- `install/man/man8/nftban.8` (DELETED) — PR #646
- `install/man/man8/nftban-suricata.8` (DELETED) — PR #646
- `commands.registry.yml` (–1 LOC header) — PR #646
- `internal/installer/payload/payload.go` (–3 / +2) — PR #647 Surfaces 1 + 11
- `internal/installer/uninstall/artifacts.go` (+6 LOC explanatory comment) — PR #647 Surface 2
- `internal/installer/uninstall/artifacts_test.go` (–1 LOC) — PR #647 Surface 3
- `packaging/build_nftban.sh` (–20 / +10) — PR #647 Surfaces 4 + 5 + 9
- `scripts/update_man_page.sh` (DELETED, –170 LOC) — PR #647 Surface 6
- `scripts/lint-registry-parity.sh` (–37 LOC + comment) — PR #647 Surfaces 7 + 10
- `.github/workflows/ci-architecture.yml` (–1 / +4) — PR #647 Surface 8
- `osv-scanner.toml` (+35 LOC) — PR #648 B-OSV

Plus the v1.123.0 release-prep 4-file envelope (this PR):

- `VERSION` (1.122.0 → 1.123.0)
- `STATUS.md` (v1.123.0 release-lane paragraph; v1.122.0 demoted)
- `CHANGELOG.md` (this entry)
- `cli/lib/nftban/core/nftban_fhs_spec.sh` (auto-regen via `build/generate-fhs-outputs.sh`; header version-banner only; FHS path-table body byte-unchanged because V123 did not touch `build/fhs-spec.yaml`)

**No daemon binary change.** **No `cmd/` Go change.** **No schema change.** **No FHS spec body change.** **No metrics changes.** **No dns2 migration in v1.123.0** (separately gated). **No host contact.**

## [v1.122.0] - 2026-05-19 — V122 small backlog-burn: docs hygiene + exporter transient + whitelist API cleanup + config sidecar quarantine

V122 small backlog-burn release on top of v1.121.0. Bundles four merged
narrow-cleanup PRs and records two scope items as ALREADY-CLOSED. **Zero
daemon binary change** — the v1.122.0 `/usr/lib/nftban/bin/nftband` is
byte-identical to v1.121.0 because the only Go change ships in
`internal/whitelist/loader.go` and the removed `AddIP` / `RemoveIP` /
`removeIPFromFile` symbols were not called from `cmd/nftband/*` or
`cmd/nftban-core/*`. The surviving public surface of the `whitelist`
package (`LoadAllWhitelists`, `LoadAllWhitelistsTyped`,
`IsIPInWhitelistFile`, `WhitelistEntry{Value,IsCIDR}`, plus V120
EXPIRES_AT parser) is byte-equivalent across consumers.

**Schema 1.83.0 remains frozen** UNCONDITIONALLY. No validator field
added, no new metric name, no new Prometheus label, no Status JSON
wire-format key, no install_state field, no nftables kernel set /
chain / table name change. `internal/validator/types.go` continues to
declare `const SchemaVersionCurrent = "1.83.0"`.

**No dns2 migration in v1.122.0.** The dns2 source-install → RPM
migration design is deferred to a v1.123 dedicated planning lane per
`DNS2_SOURCE_INSTALL_TO_RPM_MIGRATION_SCOPE.md`; it is explicitly not
a v1.122 release-blocker. **No metrics changes.** **No new schema or
config keys.** **No new systemd units** (only the existing
`nftban-unified-exporter.service` dependency line tightened, see B-4).

### Added — V122 B-1 / B-2 / B-3 operator + internals docs (PR #641 sq `a66449d8`)

- `docs/operator/CSF_REMOVAL_AND_TAKEOVER.md` (NEW, +185 lines) —
  codified takeover process rule. Documents `nftban firewall takeover
  --panel-auto-takeover` as the canonical operator procedure for
  disarming CSF / lfd on DirectAdmin hosts, with full code-trace into
  `internal/installer/switchop/takeover.go` + `ghost.go` +
  `cron_manifest.go`. Lists the 4 PR-tagged refinements the codified
  path integrates (PR-22B opt-in, PR-26-code-C structured cron
  manifest, PR26.6.1 `disarmDAWatchdog`, PR-P1 `ServiceResetFailed`)
  and the anti-patterns (manual `systemctl` sequences, `csf -x`
  alone, over-removal via `da build remove_csf`). Closes the
  process-debt finding from V121 srv4 lane
  (`V121_SRV4_CSF_REMOVE_CODE_DISCOVERY.md`).

- `docs/operator/UPGRADING_FROM_V1_120_AND_EARLIER.md` (NEW, +131
  lines) — documents the bare-version upgrade syntax shift introduced
  by V121 PR #639 Part B (leading-letter normalization in
  `cli/lib/nftban/cli/cmd_update_methods.sh::_get_package_url`). Both
  `nftban update github 1.122.0` and `nftban update github v1.122.0`
  now accepted; pre-V121 hosts that hit `Invalid version format` on
  the leading-`v` form get a documented operator-only fallback. Also
  carries the B-10b CSF config preservation companion section
  (lines 92–116): `da build remove_csf` deletes `/etc/csf/csf.allow`
  + `/etc/csf/csf.deny`; recommends `cp -p` backup to
  `/var/lib/nftban/state/operator-csf-backup-<ts>/` before running
  the DirectAdmin command; states the codified takeover path
  preserves `/etc/csf/` byte-equivalent.

- `docs/internals/V119_MANUAL_CIDR_DUAL_API.md` (NEW) — operator-
  facing documentation of the V119 dual-API pattern (legacy
  `LoadAllWhitelists` map[string]bool API preserved for pre-V119
  callers like `cmd/nftban-core/profile_sync.go` that iterate keys
  for pprof diff profiling; new `LoadAllWhitelistsTyped` +
  `IsIPInWhitelistFile` typed API for CIDR-aware membership checks).
  Closes the architectural-knowledge gap identified during V119
  Manual CIDR DESIGN-FIX scope filing.

### Changed — V122 B-4 exporter transient hardening (PR #642 sq `3f751035`)

- `install/systemd/nftban-unified-exporter.service` —
  `Wants=nftband.service` → `Requires=nftband.service`. With
  `nftband.service` `Type=notify`, systemd considers `nftband`
  "active" only after the daemon signals `READY=1`. The `Requires=`
  upgrade refuses to start the exporter when `nftband` is not in
  the active state, preventing the timer-fire-during-restart race.
  Combined with the existing `After=` ordering, this guarantees
  the exporter runs only against a ready daemon. The recurrent
  post-upgrade `exit-code-2` transient observed on lab2 / monitor /
  srv3 / srv4 during the `nftband` restart window is closed.
  Telemetry-only failure mode — **no impact on bans / enforcement**.
  Single-file edit: +9 LOC for the dependency line + a 9-line
  comment block citing the V120 / V121 reproduction set.

### Removed — V122 B-5 unused exported whitelist APIs (PR #643 sq `9d4b76ba`)

- `internal/whitelist/loader.go` — removes the unused exported
  `AddIP()` (140 LOC removed), `RemoveIP()` (–140 LOC removed),
  and unexported `removeIPFromFile()` helper. These functions
  pre-dated the V119 manual CIDR dual-API and the V120 EXPIRES_AT
  parser and were never called from `cmd/nftband/*`,
  `cmd/nftban-core/*`, or any CLI shell path. Surviving callers
  use `LoadAllWhitelists` / `LoadAllWhitelistsTyped` /
  `IsIPInWhitelistFile` for membership semantics. The orphan
  imports (`net`, `internal/netutil`, `internal/setsync`) are
  also dropped.

- `internal/whitelist/loader_test.go` — removes 19 test functions
  for the removed APIs (–288 LOC) plus an orphan `"strings"` import
  cleaned up in PR #643's remediation commit `6cbd244b`. The
  surviving 27 tests cover the V119 typed API + V120 EXPIRES_AT
  behavior unchanged.

- Net change: **–428 / +0** across the two files.

### Added — V122 B-10a config sidecar quarantine (PR #644 sq `540373d2`)

- `packaging/build_nftban.sh` — `create_rpm_spec_nftban_core()` `%post`
  generator now emits a `_nftban_rpmnew_quarantine() ( ... )` subshell
  helper between the cache-ownership fix and the install-result
  telemetry block. The helper scans `/etc/nftban` for `*.rpmnew`
  artifacts (written by RPM when an operator-edited
  `%config(noreplace)` file is shipped with a newer default during an
  upgrade) and moves each one into
  `/var/lib/nftban/state/rpmnew-archive/<UTC-timestamp>/` preserving
  the relative path under `/etc/nftban/`. Idempotent (no-op when
  nothing matches); non-fatal (failures emit `WARN` and continue;
  outer `|| true` guards the function call). Active operator config
  is never touched. +35 LOC inside the generated `%post` heredoc;
  all `\$VAR` / `\$(...)` correctly resolve to runtime `$VAR` /
  `$(...)` in the emitted spec.

- `packaging/deb/postinst` — `configure)` arm now emits a
  `_nftban_dpkg_quarantine() ( ... )` subshell helper at the end of
  the case body (after the cache-ownership find loop). Same archive
  root for symmetry: `/var/lib/nftban/state/rpmnew-archive/`
  `<UTC-timestamp>/`. Handles `*.dpkg-dist` and `*.dpkg-new` sidecars
  via `while IFS= read -r ... < <(find ...)` for whitespace safety;
  outer `|| true` prevents `set -Eeuo pipefail` from killing the
  postinst on a quarantine failure. +37 LOC.

- The two helpers share an archive layout so RPM and DEB operator
  review paths are identical (`diff -u /etc/nftban/<path>
  /var/lib/nftban/state/rpmnew-archive/<UTC-ts>/<path>`).

### Closes

- **B-1 codified takeover process rule docs** — by PR #641
- **B-2 bare-version upgrade syntax docs** — by PR #641
- **B-3 V119 manual CIDR dual-API operational doc** — by PR #641
- **B-4 exporter transient post-upgrade exit-code-2 class** — by PR #642
- **B-5 unused exported whitelist API surface** — by PR #643
- **B-10a config sidecar accumulation class** — by PR #644
- **B-9 stale CLI residue cleanup** — ALREADY-CLOSED disposition;
  no remaining deletable surface (`nftban-api-server` references
  confined to CHANGELOG / STATUS history; `nftban-ui` references
  confined to active cleanup logic, historical docs, or CI guards).
  Recorded in PR #644 body and in this entry.
- **B-10b operator-curated CSF config preservation docs** —
  ALREADY-CLOSED by PR #641 content. All three acceptance criteria
  met by:
  `docs/operator/CSF_REMOVAL_AND_TAKEOVER.md:139–144` (over-removal
  anti-pattern + cross-reference);
  `docs/operator/UPGRADING_FROM_V1_120_AND_EARLIER.md:97–100`
  (explicit deletion warning);
  `docs/operator/UPGRADING_FROM_V1_120_AND_EARLIER.md:101–108`
  (`cp -p` backup block + non-recreation note); and
  `docs/operator/UPGRADING_FROM_V1_120_AND_EARLIER.md:114–116`
  (codified takeover preserves `/etc/csf/` byte-equivalent).
  Recorded in PR #644 body and in this entry.

### Mechanism unchanged

- `internal/validator/types.go` — **byte-identical** to v1.121.0
  (`const SchemaVersionCurrent = "1.83.0"` unchanged).
- `cmd/nftband/**`, `cmd/nftban-core/**` — no Go change. **Daemon
  binary byte-identical to v1.121.0.**
- `internal/metrics/**` — no change. No new metric name, no new
  Prometheus label.
- `internal/installer/**` — no Go change (only the packaging-
  scriptlet layer was touched in PR #644).
- `install/systemd/*` — only `nftban-unified-exporter.service`
  changed (PR #642); all other units byte-identical.
- `build/fhs-spec.yaml` — byte-identical to v1.121.0 (no install
  path moved this cycle, so the FHS spec body is unchanged; only
  the `nftban_fhs_spec.sh` generated banner shifts to v1.122.0).
- `commands.registry.yml` — byte-identical to v1.121.0.

### Continuous protection preserved

v1.112.2 `status=226/NAMESPACE` regression class continues to be
guarded by the workflow_run-triggered Fresh-Install Namespace Guard
built across V114 PRs #612–#620 + V115 PR #624's `/bin/kill` polish.
**32/32 A1–A4 assertions expected PASS on the v1.122.0 baseline**
post-tag, continuing the streak from v1.121.0 / v1.120.0 / v1.119.0
/ v1.118.0 / v1.117.0 release-prep verification.

### Files touched (the entire envelope)

V122 candidate envelope already on `main` before this release-prep:

- `docs/operator/CSF_REMOVAL_AND_TAKEOVER.md` (NEW) — PR #641 B-1
- `docs/operator/UPGRADING_FROM_V1_120_AND_EARLIER.md` (NEW) — PR #641 B-2 + B-10b
- `docs/internals/V119_MANUAL_CIDR_DUAL_API.md` (NEW) — PR #641 B-3
- `install/systemd/nftban-unified-exporter.service` — PR #642 B-4
- `internal/whitelist/loader.go` (–140) — PR #643 B-5
- `internal/whitelist/loader_test.go` (–288) — PR #643 B-5
- `packaging/build_nftban.sh` (+35) — PR #644 B-10a
- `packaging/deb/postinst` (+37) — PR #644 B-10a

Plus the v1.122.0 release-prep 4-file envelope (this PR):

- `VERSION` (1.121.0 → 1.122.0)
- `STATUS.md` (v1.122.0 release-lane paragraph; v1.121.0 demoted)
- `CHANGELOG.md` (this entry)
- `cli/lib/nftban/core/nftban_fhs_spec.sh` (auto-regen via
  `build/generate-fhs-outputs.sh`; header version-banner only; no
  FHS path-table body change because V122 did not touch
  `build/fhs-spec.yaml`)

**No daemon binary change.** No `cmd/` Go change. **No schema
change.** No FHS spec body change. **No metrics changes.** **No
dns2 migration in v1.122.0** (deferred to v1.123 lane).

## [v1.121.0] - 2026-05-19 — V121 operator-safety hardening: SSH-port durable-config injection + update github [VERSION] ergonomics

V121 operator-safety hardening release on top of v1.120.0, bundling two
narrow-feature surfaces in a single PR (#639 squash `a175bb4f`):

- **Part A** closes `D-NONDEFAULT-SSH-PORT-CONFIG-DRIFT-001` (P1 silent
  self-lockout class for hosts using non-default SSH ports) with two
  complementary code paths: render-path SSH-port injection guarantees
  the port reaches the rendered `nftables.conf` durably, and the update
  CLI verifier widens to a dual-surface check that accepts BOTH durable
  mechanisms (operator-canonical `TCP_PORTS_IN=…,<port>` AND
  `SSH_PORT=<port>` driving render injection).
- **Part B** closes the `update github [VERSION]` ergonomics gap surfaced
  at lab2 V120 validation by stripping optional leading `v`/`V` before
  the strict regex check (`v1.120.0` now accepted alongside `1.120.0`)
  and adding the formal `arguments: VERSION` block to the registry for
  auto-rendered operator wiki coverage.

**Schema 1.83.0 remains frozen** UNCONDITIONALLY per
`V121_OPERATOR_SAFETY_HARDENING_SCHEMA_IMPACT_DECISION.md` verdict
`SCHEMA_STAYS_FROZEN`. No new metric, no new Prometheus label, no
Status JSON wire-format key, no validator field, no install_state field,
no nftables kernel set/chain/table name change. In-PR regression guard
`TestSchemaVersionUnchangedByV121OperatorSafetyHardening` enforces and
PASSED in CI.

**Daemon binary byte-identical to v1.120.0** — V121 changes are confined
to the installer Go layer (`internal/installer/render/nftables.go`), the
update CLI shell layer (`cli/lib/nftban/cli/cmd_update.sh` +
`cmd_update_methods.sh`), and operator-facing metadata
(`commands.registry.yml`). `cmd/nftband/*` and `cmd/nftban-core/*` are
byte-unchanged.

### Added — V121 render-path SSH-port injection (Part A)

- `internal/installer/render/nftables.go` — new
  `ensureSSHPortInTcpPortsIn(content, sshPort, log)` helper. Injects the
  detected SSH port into every `set tcp_ports_in { … elements = { … } …
  }` block in the rendered nftables.conf if the port is missing after
  `__SSH_PORT__` placeholder substitution. Fast-path no-op when the port
  is already present (handles both Mechanism A and Mechanism B). Multi-
  set support (both `ip nftban` and `ip6 nftban` blocks injected in a
  single ReplaceAllStringFunc pass). Idempotent across repeated calls.
  +91 LOC; closes `D-NONDEFAULT-SSH-PORT-CONFIG-DRIFT-001` at the source.

- `internal/installer/render/nftables_test.go` (NEW, +204) — 7 Go test
  cases covering Mechanism A (port already in template), Mechanism B
  (placeholder substituted), Mechanism C (port missing → inject),
  multi-set injection (ip + ip6), idempotency, empty-elements edge case,
  no-tcp_ports_in-set degenerate case, multi-line elements. All 7 PASS
  in CI.

- `internal/installer/render/schema_freeze_test.go` (NEW, +67) —
  `TestSchemaVersionUnchangedByV121OperatorSafetyHardening` regression
  guard. Co-located in the V121 primary-affected package per
  `V121_OPERATOR_SAFETY_HARDENING_SCHEMA_IMPACT_DECISION.md` §5 mandate.
  PASSES in CI.

### Added — V121 verifier dual-surface check (Part A)

- `cli/lib/nftban/cli/cmd_update.sh` — V2 (post-update verify), PF5
  (preflight), VF2 (post-update verify) all widened from kernel-only to
  DUAL-SURFACE check: kernel state AND durable config. Durable check
  accepts BOTH:
  - **Mechanism A** — `TCP_PORTS_IN=…,<port>` in
    `/etc/nftban/nftban.conf.local` (monitor pattern)
  - **Mechanism B** — `SSH_PORT=<port>` in operator canonical AND
    rendered `nftables.conf` carries the port (srv2/lab2/lab4 pattern)
  Reports: PASS (kernel + durable both YES), WARN (kernel YES + durable
  NO; operator-actionable lockout-risk-on-next-reload warning), or FAIL
  (kernel NO; lockout-risk-now). +88 LOC across 3 sites.

- `cli/lib/nftban/tests/test_update_ssh_port_durability.sh` (NEW, +306)
  — 8 shell test cases covering Mechanism A PASS-BOTH, Mechanism B
  PASS-BOTH, kernel-only-via-failed-Mechanism-B WARN, kernel-only-no-conf-
  local WARN, kernel-missing FAIL, default-port-22-no-override WARN,
  empty-empty FAIL, word-boundary safety (5500 vs 55000). All 8 PASS
  locally; CI shell-test framework confirms parse + lint cleanliness.

### Added — V121 update github [VERSION] ergonomics (Part B)

- `cli/lib/nftban/cli/cmd_update_methods.sh` — `_get_package_url` now
  strips optional leading `v` or `V` before the existing strict N.N.N
  regex check. Both `1.120.0` AND `v1.120.0` accepted. Strict regex
  preserved post-strip:
  `^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9._-]+)?$`. Error message updated
  to reflect both accepted forms. Downstream URL construction unchanged
  (still uses canonical `v${version}` prefix when building the GitHub
  release URL — V121 normalization is purely an input convenience).
  +20 LOC.

- `commands.registry.yml` — `arguments: VERSION` block added under
  `update.subcommands.github:` with formal type/optional/description
  fields, 5 examples covering the latest-stable / version-pin / rollback
  / v-prefix / pre-release cases, and 4 notes documenting V121
  normalization, the strict regex, channel-eligibility bypass behavior,
  and the downstream URL form. Auto-renders into operator wiki at next
  wiki build via `scripts/generate-wiki-operator.sh`. +16 LOC. **NOTE:**
  The registry's own `schema_version: "1.2"` self-description (file-
  format version) is UNTOUCHED — distinct from M81-6 schema 1.83.0.

- `cli/lib/nftban/tests/test_update_version_normalization.sh` (NEW, +116)
  — 21 shell test cases: 4 canonical N.N.N acceptances, 3 v/V-strip
  acceptances (`v1.120.0`, `V1.120.0`, `v1.119.0-rc1`), 3 pre-release
  suffix acceptances (`-rc1`, `-beta.2`, `-alpha_3`), 6 malformed
  rejections (`1.120`, `1.120.0.0`, `latest`, empty, non-numeric,
  command-injection), 3 embedded-v rejections (only LEADING v/V
  stripped), 2 whitespace rejections. All 21 PASS locally.

### Fixed

- `D-NONDEFAULT-SSH-PORT-CONFIG-DRIFT-001` — P1 silent self-lockout
  class. Hosts using non-default SSH ports (monitor + srv2 on port
  55000) could end up with the SSH port in the LIVE kernel tcp_ports_in
  set but NOT in the DURABLE rendered config, risking SSH lockout on the
  next `nftban firewall reload`, `systemctl restart nftband`, server
  reboot, or `nftban update`. The misleading Prepare-phase warning
  `SSH port N not found in rendered nftables.conf — may need manual
  tcp_ports_in entry` was technically correct at the moment of the
  check but failed to acknowledge that downstream conf.d/ports.d merges
  would resolve the gap on most paths — operators had no way to
  distinguish a real durability gap from a transient pipeline-staging
  state. V121 fixes this at the source via render-path injection (Part A
  code path 1) AND surfaces the gap loudly at update time via the
  dual-surface verifier (Part A code path 2). Closes the misleading-
  signal class entirely.

- Lab2 V120 validation root cause (`update github v1.120.0` input
  rejection) — V121 Part B normalization accepts both forms.

### Mechanism unchanged (V121 forbidden surfaces preserved byte-unchanged)

- `internal/runtime/state.go`, `internal/profile/profile_sync.go` —
  byte-unchanged
- `internal/validator/*` (schema 1.83.0 frozen) — byte-unchanged
- `install/systemd/*` — byte-unchanged
- `install/nftables/*` — byte-unchanged (no new kernel set, no new
  chain, no new table)
- `internal/metrics/*`, `internal/health/*`, `internal/lifecycle/*`,
  `internal/portal/*`, `internal/dns2/*`, `internal/panel/*` — all
  byte-unchanged
- `packaging/*` — byte-unchanged
- `cmd/nftband/*` (daemon) — byte-unchanged (8-release identical-binary
  streak preserved)
- `cmd/nftban-core/*` (CLI binary) — byte-unchanged
- `build/fhs-spec.yaml` — byte-unchanged
- `MASTER_TODO*` — byte-unchanged (workspace-control rule locked
  2026-05-13)
- Bucket-C v0.x tag paths — byte-unchanged
- Pre-existing orphans `whitelist.AddIP` / `whitelist.RemoveIP` —
  untouched (deferred to separate cleanup lane per V120 audit §5
  boundary)

### Lifecycle

- `f9f34fc4` — single implementation commit (8 files / +881/-27 / no
  force-push / no amend); CI clean (17 SUCCESS / 3 FAILURE baseline-
  advisory / 1 SKIPPED); verified merge-ready per
  `V121_OPERATOR_SAFETY_HARDENING_PR_639_CI_AND_DIFF_VERIFICATION.md`
  verdict `PR_639_VERIFIED_MERGE_READY`; squash-merged as `a175bb4f`.

V121 had no remediation cycles (unlike V120's 4-commit B-1/B-2/T-1/T-2/
T-2-followon arc) — the scope was simpler and the local test coverage
was thorough enough to catch issues before push.

### CI final tally (pre-merge on head `f9f34fc4`)

17 SUCCESS / 3 FAILURE / 1 SKIPPED — only baseline-advisory failures
(`OSV-Scanner` 26 Go stdlib CVEs all filtered per current 1.25.8
builder profile + `Project Health` ×2 same 7/305 shellcheck warnings
as main `e96938aa`). All product gates green including **Go Build &
Test** (all 9 V121 tests PASS), **Secure Go**, Build NFTBan Packages,
Update Canonization Gate, Runtime Truth Gate, CodeQL, Semgrep,
ShellCheck, Bash Validation, Docker, Smoke Test, Documentation
Validation, Architecture Policy, Shell-Delete Guard, Secret Scanning
(Gitleaks), Dependency Review, 2026 OSSRA Remediation.

### Behavior changes (narrow, explicit)

- **NEW** render-path SSH-port injection: every `nftban firewall
  rebuild` / `nftban-installer` Configure phase now guarantees the
  detected SSH port reaches the rendered `/etc/nftban/nftables.conf`
  tcp_ports_in set (was: warned-but-didn't-fix if template lacked the
  port).
- **NEW** dual-surface verifier output: V2 / PF5 / VF2 all report
  PASS (kernel + durable) / WARN (kernel-YES + durable-NO; operator-
  actionable lockout-risk warning) / FAIL (kernel-NO; lockout-risk-now)
  instead of the prior kernel-only PASS/FAIL binary.
- **NEW** version-format input normalization: `nftban update github
  1.120.0` AND `nftban update github v1.120.0` AND `V1.120.0` all
  accepted; downstream URL still uses canonical `v${version}` prefix.
- **NEW** registry `arguments: VERSION` block: auto-renders into
  operator wiki — operators discoverable via wiki/help that VERSION is
  optional and both formats accepted.
- **No new IPC traffic, no new Prometheus metric, no new Status JSON
  key, no new file system surface, no new external dependency.**

### Docker / GHCR tag pattern (post-publication)

`v1.121.0`, `1.121.0`, `1.121`, `latest`, AND `sha-<8>` all resolve.
The `sha-<8>` 8-char short-SHA tag continues to use the v1.117.0
raw-template escape hatch from PR #631 (5th consecutive cycle).

v1.121.x hotfix slot **not authorized** (latent reservation only —
opened only if a v1.121.0 defect surfaces).

### Workspace artifacts (no PR, no code; filed at `AUDIT_190_LIFECYCLE/`)

- `V121_UPDATE_GITHUB_VERSION_ARG_DOC_SCOPE.md` — Part B scope
- `V121_SSH_PORT_TEMPLATE_GAP_SCOPE.md` — Part A scope
- `V121_OPERATOR_SAFETY_HARDENING_SCHEMA_IMPACT_DECISION.md` — schema-
  impact decision (verdict `SCHEMA_STAYS_FROZEN` unconditional)
- `V121_OPERATOR_SAFETY_HARDENING_PR_639_CI_AND_DIFF_VERIFICATION.md`
  — PR #639 verification (verdict `PR_639_VERIFIED_MERGE_READY`)
- `MONITOR_SSH_PORT_DURABILITY_DIAG_AND_FIX.md` — Mechanism A evidence
  on monitor
- `SRV2_V120_PREFLIGHT_CLOSURE.md` — Mechanism B evidence on srv2
- `SRV2_OOB_ACCESS_AND_WHITELIST_PREP_SCOPE.md` — production OOB-prep
  discipline scope
- `V119_VALIDATE_LAB4_CLOSURE.md` — lab4 V120 validation closure
- `V119_VALIDATE_MONITOR_LOG_DERIVED_CLOSURE.md` — monitor V120
  validation closure (with v1 + v2 amendments)

All artifacts read-only / zero code mutation / zero host contact during
preflight + verification cycles.

---

## [v1.120.0] - 2026-05-18 — V120 dedicated narrow-feature: operator-session whitelist guard

V120 dedicated narrow-feature release on top of v1.119.0, closing
`D-UPDATE-OPERATOR-SELF-BAN-GAP-001` with the **operator-session
whitelist guard** (single PR #637 squash `38cc86f6`). Resolves the
operator self-ban gap surfaced during v1.119 fleet validation: when
the operator's SSH peer IP was not in the permanent whitelist, the
LoginMon brute-force scorer could ban that IP during a `nftban update`
or `firewall takeover` and lock the operator out for the full timeout
(typ. 900s).

**Schema 1.83.0 remains frozen.** No new metric names, no new metric
registrations, no Status JSON wire format additions, no allow-list
mutation, no nftables kernel set change. Per
`V120_OPERATOR_TEMP_WHITELIST_SCHEMA_IMPACT_DECISION.md` verdict
`SCHEMA_STAYS_FROZEN` (conditional on `--json` deferral). In-PR
regression test `TestSchemaVersionUnchangedByV120OperatorSessionWhitelist`
enforces `SchemaVersionCurrent == "1.83.0"`.

**Daemon binary byte-identical to v1.119.0:** the V120 implementation
runs entirely inside the installer + CLI shell layer + whitelist
loader. `cmd/nftband/` and `cmd/nftban-core/` are byte-unchanged.
`internal/profile/profile_sync.go` and `internal/runtime/state.go`
are byte-unchanged. `install/nftables/`, `install/systemd/`, and
`internal/validator/` are byte-unchanged. No new IPC traffic, no new
nft set, no new systemd timer.

### Added (file-based session whitelist mechanism, Shape E.0)

- `internal/installer/safety/session_whitelist.go` (NEW, +431) —
  core mechanism. Manages `/etc/nftban/whitelist.d/00-session.conf`
  with inline `# EXPIRES_AT=<RFC3339>  REASON=<text>  ADDED_BY=<source>`
  markers. Public API: `AddSessionWhitelist`,
  `CleanupExpiredSessionWhitelist`, `ReadSessionWhitelist`,
  `RemoveSessionWhitelist`, `CaptureSSHPeerIP`. Constant
  `DefaultSessionWhitelistTTL = 30 * time.Minute`. `CaptureSSHPeerIP`
  prefers explicit `NFTBAN_OPERATOR_SESSION_IP` env-mirror over
  `$SSH_CLIENT` so the value survives sudo and package-scriptlet
  hops that scrub the SSH session env. (PR #637)

- `internal/whitelist/loader.go` (+48) — `shouldSkipDueToExpiresAt`
  helper called from `loadWhitelistFileTyped`. Entries with
  `EXPIRES_AT` in the past are silently skipped at load time;
  malformed `EXPIRES_AT` markers are conservatively skipped;
  entries with no marker continue to load permanently (backward
  compatible with pre-v1.120 99-manual.conf semantics). (PR #637)

- `cmd/nftban-installer/phases.go` (+29) — `phaseConfigure` auto-seeds
  the operator's SSH peer IP into `00-session.conf` on every install
  mode (NOT gated to `--source` like v1.98.x `SeedManualWhitelist`).
  Runs before the rebuild phase; failure is non-fatal (logged WARN
  only) so a missing peer IP never blocks the upgrade. (PR #637)

- `cmd/nftban-installer/flags.go` (+25), `main.go` (+4),
  `flags_test.go` (NEW, +96) — new flag
  `--session-whitelist-ttl <duration>` defaulting to
  `safety.DefaultSessionWhitelistTTL` (30m). Set 0 to disable
  auto-seed for the current run. Two regression-guard tests
  (`TestParseFlags_SessionWhitelistTTL{Default,Explicit}`) pin both
  the default-value path and the explicit-override path; the
  default-test exists specifically to prevent the silent-zero-TTL
  regression class surfaced by V120 audit B-2. (PR #637)

- `cli/lib/nftban/cli/cmd_update.sh` (+13) — captures `$SSH_CLIENT`
  pre-installer-invoke and exports `NFTBAN_OPERATOR_SESSION_IP` so
  the env-mirror survives sudo and package-scriptlet env scrubs.
  Best-effort; silently skipped for non-SSH invocations (cron,
  systemd timer, local console). (PR #637)

- `cli/lib/nftban/cli/cmd_firewall.sh` (+465) — new
  `nftban firewall whitelist-session {add,list,remove,cleanup}`
  subcommand. Explicit operator override for multi-hop SSH / sudo
  chains where auto-seed cannot detect the right IP. Text-mode
  only; `--json` and `-j` are REJECTED at the dispatcher with an
  operator-actionable error message and exit code 2 (deferred to
  v1.121 per schema-impact decision). Helper functions
  `_whitelist_session_{add,list,remove,cleanup}` plus
  `countDataLinesForIP`-style helpers; atomic write via `mktemp` +
  `mv`; `nftban firewall reload` triggered after every add/remove.
  (PR #637)

- `commands.registry.yml` (+40) — registry entry for
  `firewall.subcommands.whitelist-session` with sub-subcommand
  options. Notes text-mode-only and the v1.121 `--json` deferral.
  (PR #637)

- `cli/lib/nftban/tests/cmd_firewall_whitelist_session_test.sh`
  (NEW, +276) — shell test suite: 33/33 assertions PASS in
  `mktemp -d` sandbox with `_NFTBAN_SESSION_WHITELIST_PATH`
  override and patched-out `$EUID` root guards. Covers help,
  `--json`/`-j` rejection at the dispatcher (3 forms), add creates
  file with header, refresh-by-IP dedup, invalid IP rejection,
  missing `--ttl` rejection, list with TTL-remaining display,
  remove, cleanup expired-only, unknown action. (PR #637)

- `internal/installer/safety/session_whitelist_test.go` (NEW, +375)
  — 11 Go unit tests covering Add (create-with-header / refresh
  dedup), Cleanup, Read, Remove, `CaptureSSHPeerIP` (env-mirror
  precedence / SSH_CLIENT fallback / both-empty / non-routable
  rejection), `lineIsExpired` parse matrix, `extractIPField`. Uses
  `newSessionTestLogger` helper (renamed during B-1 remediation
  to avoid collision with pre-existing `newTestLogger` in
  `whitelist_test.go`). (PR #637)

- `internal/whitelist/loader_test.go` (+95) — 5 EXPIRES_AT matrix
  cases: future entry loaded; past entry skipped; malformed
  EXPIRES_AT conservatively skipped; entry without marker loaded
  (backward compat); mixed file (header + future + past +
  no-marker). (PR #637)

- `internal/whitelist/schema_freeze_test.go` (NEW, +61) —
  `TestSchemaVersionUnchangedByV120OperatorSessionWhitelist`
  asserts `validator.SchemaVersionCurrent == "1.83.0"`. Mirrors
  v1.119's `internal/blacklist/schema_freeze_test.go` regression
  guard. (PR #637)

### Fixed

- `D-UPDATE-OPERATOR-SELF-BAN-GAP-001` — closed by PR #637. When the
  operator runs `nftban update` or `firewall takeover` from an SSH
  session whose peer IP is not in the permanent whitelist, the
  LoginMon brute-force scorer can ban that IP during the brief
  reload window and lock the operator out for the full timeout
  (typ. 900s). V120 closes the gap by auto-seeding the SSH peer IP
  into `/etc/nftban/whitelist.d/00-session.conf` with a bounded TTL
  (default 30m) before the rebuild phase runs, on every install
  mode. The explicit
  `nftban firewall whitelist-session add <ip> --ttl <duration>`
  subcommand covers the multi-hop SSH / sudo chain case where
  auto-seed cannot detect the right IP.

### Mechanism (V120 forbidden surfaces preserved byte-unchanged)

`internal/runtime/state.go`, `internal/profile/profile_sync.go`,
`internal/validator/*` (schema 1.83.0), `install/systemd/*`,
`install/nftables/*` (no new kernel set, no new chain),
`internal/metrics/*`, `internal/health/*`, `internal/lifecycle/*`,
`internal/portal/*`, `internal/dns2/*`, `internal/panel/*`,
`packaging/*`, `cmd/nftband/*` (daemon byte-identical), and
`cmd/nftban-core/*` (CLI binary byte-identical) are all untouched.
Pre-existing orphans `whitelist.AddIP` / `whitelist.RemoveIP` are
exported public APIs flagged by V120 audit as currently
unused-by-production; explicitly deferred to a separate cleanup
lane per audit §5 boundary (NOT touched in PR #637).

### Lifecycle (4 commits squashed as `38cc86f6`)

- `752e89dc` — initial implementation: 12 files + ~1,800 lines of
  Go, shell, registry, tests. PR opened.
- `4ecd3905` — B-1 + B-2 remediation per
  `V120_PR_637_ORPHAN_AND_DEAD_CODE_AUDIT.md`. B-1: rename
  `newTestLogger(t)` → `newSessionTestLogger(t)` to resolve
  package-level collision with pre-existing helper in
  `whitelist_test.go`. B-2: register the missing
  `flag.DurationVar(&cfg.sessionWhitelistTTL, "session-whitelist-ttl",
  safety.DefaultSessionWhitelistTTL, …)` in `parseFlags()` — without
  this line every auto-seeded entry was born expired (silent
  zero-TTL regression class). Added `flags_test.go` regression
  guard.
- `627130d2` — T-1 + T-2 remediation per
  `V120_PR_637_CI_AND_DIFF_VERIFICATION.md`. T-1: line-anchored,
  comment-skipping `countDataLinesForIP` helper replaces
  `strings.Count` to avoid double-counting the IP that appears
  inside the file header example. T-2: relative
  `time.Now().UTC().Add(time.Hour)` fixture replaces absolute
  `time.Date(2026, 5, 18, …)` so the entry is never born expired.
- `5d1e3681` — T-2 follow-on remediation per
  `V120_PR_637_CI_AND_DIFF_VERIFICATION_RERUN.md`. Append
  `.Truncate(time.Second)` to relative timestamps so the
  in-memory `t1.Equal(parsedT1)` assertion holds across the
  RFC3339 round-trip (RFC3339 drops sub-second digits).

Each remediation was a single additive commit; no force-push, no
amend across the whole lifecycle; production code
(`internal/installer/safety/session_whitelist.go`) byte-unchanged
across all three test-fixture remediations.

### CI final tally (pre-merge on head `5d1e3681`)

21 SUCCESS / 3 FAILURE / 1 SKIPPED — only baseline-advisory failures
(`OSV-Scanner` 26 Go stdlib CVEs all filtered + `Project Health` ×2
same 7/305 shellcheck warnings as main @ `2082d23e`). All product
gates green including **Go Build & Test**, **Secure Go**, Build
NFTBan Packages, all 5 Canonization gates (Install / Restore /
Update / Uninstall / Runtime Truth), CodeQL, Semgrep, ShellCheck,
Bash Validation, Docker, Smoke Test, Documentation Validation,
Architecture Policy, Migration Coverage, Shell-Delete Guard,
Secret Scanning (Gitleaks), Dependency Review, 2026 OSSRA
Remediation.

### Behavior changes (narrow, explicit)

- NEW CLI subcommand
  `nftban firewall whitelist-session add <ip> --ttl <duration> [--reason <text>]`
  writes a TTL'd entry to `/etc/nftban/whitelist.d/00-session.conf`
  and reloads the firewall. `list` shows non-expired entries with
  TTL-remaining. `remove <ip>` drops a single entry and reloads.
  `cleanup` drops all expired entries.
- NEW installer flag `--session-whitelist-ttl <duration>`
  (default 30m; 0 disables auto-seed for this run).
- NEW env-mirror `NFTBAN_OPERATOR_SESSION_IP` propagated by
  `nftban update`.
- NEW behavior on every `nftban update` or `firewall takeover` from
  an SSH session: the operator's SSH peer IP is auto-seeded into
  `00-session.conf` with the configured TTL before the rebuild
  phase. This is the load-bearing behavior change closing
  `D-UPDATE-OPERATOR-SELF-BAN-GAP-001`.
- Loader: entries past `EXPIRES_AT` are silently skipped at load
  time; entries with no marker continue to load permanently
  (backward compatible).
- `--json` on the new `whitelist-session` subcommand is REJECTED
  with operator-actionable error and exit code 2; deferred to
  v1.121.
- New IPC traffic: NONE. New Prometheus metric: NONE. New Status
  JSON key: NONE. New file system surface:
  `/etc/nftban/whitelist.d/00-session.conf` (managed by the
  installer / CLI; persistent across reboots; cleanup at load
  time). New external dependency: NONE.

### Docker / GHCR tag pattern (post-publication)

`v1.120.0`, `1.120.0`, `1.120`, `latest`, AND `sha-<8>` all
resolve. The `sha-<8>` 8-char short-SHA tag continues to use the
v1.117.0 raw-template escape hatch from PR #631.

v1.120.x hotfix slot **not authorized** (latent reservation only —
opened only if a v1.120.0 defect surfaces).

### Workspace artifacts (no PR, no code; filed at `AUDIT_190_LIFECYCLE/`)

- `V119_OPERATOR_SELF_BAN_INCIDENT_AUDIT.md` (338 lines) — incident
  audit, verdict `OPERATOR_SELF_BAN_GAP_CONFIRMED_CODE_FIX_REQUIRED`.
- `V119_VALIDATE_RUNBOOK_SELF_BAN_GUARD_AMENDMENT.md` (272 lines)
  — 6 binding rules for fleet validation.
- `V120_OPERATOR_TEMP_WHITELIST_GUARD_SCOPE.md` (490 lines) —
  Shape E.0 design scope.
- `V120_OPERATOR_TEMP_WHITELIST_SCHEMA_IMPACT_DECISION.md`
  (297 lines) — verdict `SCHEMA_STAYS_FROZEN` conditional on
  `--json` deferral.
- `V120_PR_637_ORPHAN_AND_DEAD_CODE_AUDIT.md` (437 lines) — B-1
  + B-2 surfaced.
- `V120_PR_637_ORPHAN_AND_DEAD_CODE_AUDIT_RERUN.md` (344 lines) —
  verdict `V120_PR_637_ORPHAN_AUDIT_CLEAN`.
- `V120_PR_637_CI_AND_DIFF_VERIFICATION.md` — NOT CLEAN, T-1 + T-2
  surfaced.
- `V120_PR_637_CI_AND_DIFF_VERIFICATION_RERUN.md` — NOT CLEAN,
  T-2 follow-on surfaced.
- `V120_PR_637_CI_AND_DIFF_VERIFICATION_CLEAN.md` (302 lines) —
  final verdict `V120_PR_637_VERIFICATION_CLEAN`.

All artifacts read-only / zero code mutation / zero host contact
during preflight + verification cycles.

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
