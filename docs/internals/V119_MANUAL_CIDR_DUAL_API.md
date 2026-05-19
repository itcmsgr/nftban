# V119 Manual CIDR Dual-API — Operational Semantics

## Purpose

V119 (released 2026-05-18 as v1.119.0) changed how CIDR entries in
`/etc/nftban/blacklist.d/99-manual.conf` and
`/etc/nftban/whitelist.d/99-manual.conf` are loaded and enforced. The
change is operationally significant when upgrading from v1.118.0 or
earlier: CIDR entries that were silently inert pre-V119 become
effective post-V119, **without any file mutation**.

This document explains the mechanism so operators understand why some
bans "started working" after upgrade.

## Pre-V119 behavior (silent inert)

Versions through v1.118.0 used an untyped flat-list loader for
manual files. The loader read each non-comment line as a string and
attempted to insert into the kernel nft set:

- For `blacklist_manual_ipv4` the kernel set type is `ipv4_addr` with
  `flags timeout`. The `timeout` flag is incompatible with `interval`
  in nft kernel-set semantics — meaning the set can only hold single
  IPs, not CIDR prefixes.
- A `/27` line like `81.30.98.32/27` would attempt insertion, fail
  silently (or get treated as the bare address `81.30.98.32`, losing
  the prefix), and **the /27 range as a whole was not enforced**.

The result: operator entries like `81.30.98.32/27` (a 32-address
exim-bruteforce block) were durably present in the file but
operationally inert. Connections from the other 31 addresses in the
/27 were not blocked by the manual-blacklist code path.

## Post-V119 behavior (file-based CIDR containment)

V119 (PR #633, commit `2632141b`) introduced a **typed loader**:

- `BlacklistEntry{Value string, IsCIDR bool}` and corresponding
  `WhitelistEntry{Value string, IsCIDR bool}` carry per-entry type
  information through the loader.
- `LoadAllBlacklistTyped()` and `LoadAllWhitelistTyped()` parse the
  file once and classify each line as either a bare IP or a CIDR
  prefix (`netip.Prefix`).
- A new containment-check helper, `IsIPInBlacklistFile()` (and
  whitelist equivalent), uses `netip.Prefix.Contains(addr)` to decide
  membership at decision time. CIDRs do not need to be expanded into
  kernel sets.

The dual-API split: kernel sets still hold runtime-banned IPs
(loginmon emissions, threat-feed entries, etc. — `flags timeout`
elements that came in through the daemon's runtime path). File-based
CIDRs are checked at userspace inside the Go daemon when a packet
hits a decision point that needs to consult the manual file. This is
why the kernel `blacklist_manual_ipv4` set still has `flags timeout`
only on V119+ hosts that have CIDR entries in `99-manual.conf` — the
CIDRs are not expanded into the kernel, they are file-based.

## Behavior delta on upgrade

When a host upgrades from pre-V119 to V119+ (a v1.113.0 → v1.121.0
jump, for example), the operator observes:

| Surface | Pre-upgrade | Post-upgrade |
|---------|-------------|--------------|
| `/etc/nftban/blacklist.d/99-manual.conf` content | unchanged | byte-identical (same md5) |
| Kernel `blacklist_manual_ipv4` set | 0 elements (CIDRs silently rejected) | 0 elements (CIDRs not expanded) |
| Kernel `blacklist_manual_ipv4` set flags | `timeout` only | `timeout` only |
| Userspace daemon containment check | not present | active via `IsIPInBlacklistFile()` |
| Connection from inside a /27 range in the file | not blocked by manual-blacklist | **blocked** by manual-blacklist (via file-based containment) |

In words: the operator file is byte-identical pre vs post. The kernel
set looks identical pre vs post. The behavior change is at the Go
daemon's decision-point layer — and it is in the operator's favor (the
intent of the /27 ban is now realized).

Empirical observation from V121 fleet rollout: srv1 had 5 `/27`
CIDR entries in `99-manual.conf` (exim-bruteforce blocks). Pre-V121
the kernel `blacklist_manual_ipv4` set had 0 elements; post-V121 the
set still has 0 elements and the same `flags timeout`, but the daemon
now correctly classifies all 160 addresses across the five /27 ranges
as "in manual blacklist file" via the typed loader.

## `nftban firewall check` does NOT surface this

The `nftban firewall check <ip>` CLI inspects the kernel nft ruleset
directly. It does not exercise the Go daemon's `IsIPInBlacklistFile()`
helper. Consequently:

```
$ nftban firewall check 81.30.98.35
...
Status: ❌ BLOCKED
Matched Rule:
  Rule:     default policy
  Verdict:  drop
```

The reason given is `default policy: drop` (not "matched manual
blacklist file"). This is **NOT** a contradiction — the kernel
default-input policy is `drop`, and the IP isn't in any kernel
accept-set, so it gets dropped. The fact that it's ALSO in the
manual-blacklist-file CIDR is irrelevant to the kernel check.

Operators looking for evidence that a manual CIDR is active should
look at the Go daemon logs and runtime decisions (loginmon /
portscan / botguard hits that reference the file), not at
`nftban firewall check` output.

## Why this design (dual-API, not kernel expansion)

Three considerations led to V119's dual-API choice:

1. **Kernel-set semantics.** `flags timeout` and `flags interval` are
   mutually exclusive in nft. Manual blacklist needs `timeout` to
   support automatic-ban entries that age out. Splitting into two
   sets (one timeout-flagged, one interval-flagged) would have
   doubled the surface and required dual-set lookups for every
   decision.

2. **Efficiency.** A /16 CIDR contains 65,536 addresses. Expanding it
   into kernel-set elements is wasteful and slow. File-based
   containment via `netip.Prefix.Contains` is O(1) per CIDR check
   regardless of prefix length.

3. **Operator transparency.** The file remains the source of truth.
   Operators reading `99-manual.conf` see exactly what they wrote.
   No kernel-side expansion that could drift from the file.

The trade-off: CIDR entries are not enforced by the kernel's
fast-path `set lookup` — they are enforced by the daemon's
decision-point logic. Net effect on operations: CIDRs work; they just
don't show up in `nft list set ip nftban blacklist_manual_ipv4`.

## What did NOT change in V119

- Kernel set type and flags
- File format (existing `99-manual.conf` entries remain valid)
- Bare-IP behavior (single IPs still go through the kernel-set path
  when added at runtime by the daemon)
- `nftban whitelist add` / `nftban blacklist add` CLI commands
- Schema (M81-6 remains frozen at 1.83.0)

## Related cycle artifacts

- `AUDIT_190_LIFECYCLE/V119_MANUAL_CIDR_SCHEMA_IMPACT_DECISION.md`
  (verdict: `SCHEMA_STAYS_FROZEN`)
- `AUDIT_190_LIFECYCLE/V119_MANUAL_CIDR_PREFLIGHT_PROFILE_SYNC_AUDIT.md`
  (verdict: `SCOPE_CONSTRAINT_CONFIRMED_NON_BLOCKING_WITH_DUAL_API`)
- `AUDIT_190_LIFECYCLE/V119_A1_WHITELIST_BLACKLIST_CORRECTNESS_AND_ORPHAN_AUDIT.md`
- v1.119.0 CHANGELOG entry (PR #633 squash `2632141b`)

## Code references

| Component | File | Line / function |
|-----------|------|-----------------|
| Typed `BlacklistEntry` struct | `internal/blacklist/` | `BlacklistEntry{Value, IsCIDR}` |
| Typed `WhitelistEntry` struct | `internal/whitelist/` | `WhitelistEntry{Value, IsCIDR}` |
| `LoadAllBlacklistTyped()` | `internal/blacklist/` | typed loader |
| `LoadAllWhitelistTyped()` | `internal/whitelist/` | typed loader |
| `IsIPInBlacklistFile()` | `internal/blacklist/` | `netip.Prefix.Contains` containment check |
| `IsIPInWhitelistFile()` | `internal/whitelist/` | mirror of the above |
| Daemon-side CIDR safety predicate | `cmd/nftband/` (D3 daemon guard) | runtime decision-point integration |
| In-PR schema-freeze guard | `internal/blacklist/` test file | `TestSchemaVersionUnchangedByManualCIDRFix` |

(Exact line numbers may drift as the codebase evolves; use `grep
'BlacklistEntry\|WhitelistEntry\|IsCIDR\|IsIPInBlacklistFile' internal/`
to locate current definitions.)
