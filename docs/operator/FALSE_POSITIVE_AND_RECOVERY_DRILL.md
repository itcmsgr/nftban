# BotScan False-Positive & Recovery Drill

*Operator runbook — as of v1.219.0. (End-to-end automated drill test is deferred to v1.222.0; this is the manual procedure + the standing gate.)*

BotScan (HTTP Exploit Scanner) can ban a legitimate visitor if a pattern is too broad (e.g. the v1.218.10 EXP_REVSLIDER and v1.218.13 EXP_RFI false positives, where a bare product/URL token matched normal requests). This runbook is the standing recovery path. It applies the maturity principle: **operator truth is security** — a ban you cannot explain and recover from is itself a hazard.

## 0. Confirm it is really a BotScan ban (not admin/feed/geo)

```
nftban search <ip>
```
- Top-level `BANNED` is **kernel-authoritative** (nft-set membership). A `CACHE ONLY — not currently enforced` line is NOT a ban.
- A BotScan-origin ban lands in `blacklist_manual_*` with `source=botscan` (see `source_index.jsonl`). *(Full per-ban reason + matched URL attribution arrives with v1.219.0 PR-B durable evidence.)*

## 1. Truth: what did BotScan do, and is it still enforcing?

```
nftban status                 # HTTP Exploit Scan row: enabled? DEGRADED? action mode?
nftban botscan status         # enabled / timer / action / patterns
nftban health                 # HTTP Exploit Scanner (BotScan) block
```
`ENABLED but DEGRADED … NOT currently enforcing` means the scanner is blind — a ban you see is from a prior cycle, and new bans are not being written.

## 2. Count / list truth

```
nftban blacklist list | grep <ip>      # confirm kernel membership
nftban stats                            # BotScan bans_emitted / signals
```

## 3. Recover the specific IP (targeted, evidence-based — NOT a bulk flush)

```
nftban whitelist add <ip>     # durable protection so it cannot be re-banned
nftban unban <ip>             # remove the current ban
```
Prefer per-IP recovery with evidence. **Do not** bulk-flush `blacklist_manual_*` to clear one false positive — that drops real bans too.

## 4. Fix the pattern (root cause), not just the symptom

If a pattern is systematically false-positive, narrow it (mirror the EXP_REVSLIDER / EXP_RFI fixes): anchor to exploit-specific tokens, add an **asset-negative fixture** (a real legit URL that must NOT match) and an **exploit-positive fixture** (a probe that must match). Ship it as a pattern-data hotfix. Generalized pattern-quality CI lint + `nftban botscan test-url <url>` land in v1.222.0.

## 5. RPM config-drift caveat

If you ever hand-edit `patterns.d/botscan/*` on an RPM host, `%config(noreplace)` will make future **packaged** pattern security fixes silently skip that host. Verify with `rpm -V nftban-core`; reconcile from the packaged file. (Tracked: `OPEN_RPM_PATTERN_CONFIG_DRIFT_RECONCILE_GUARD`.)

## Standing gate: FALSE_POSITIVE_AND_RECOVERY_DRILL

Every BotScan-touching release must be able to demonstrate: **false-positive → search truth → list/count truth → targeted whitelist+unban → not re-banned**, and that a broken/blind scanner or a cache-only hit never presents as enforced/protected.
