# NFTBan Anchor Contract

> As of v1.62.0 | This document defines the firewall rule structure contract.

## Overview

NFTBan's input chain has a fixed 7-phase structure. Each phase boundary is marked by a named counter rule with a `NFTBAN_ANCHOR:` comment. Modules insert their `jump` rules before specific anchors. The order cannot be changed at runtime.

## Canonical Phase Order

```
Phase  Anchor                   Purpose
─────  ───────────────────────  ─────────────────────────────────
  0    ANCHOR_HYGIENE           loopback accept, then ct state invalid drop (v1.217.0: iif lo BEFORE invalid-drop)
  1    ANCHOR_TRUSTED           whitelist accept
  2    ANCHOR_BAN               blacklist drop, per-IP port access
  3    ANCHOR_ESTABLISHED       ct state established,related accept
  4    ANCHOR_DETECT            CT limits, SYN meter, portscan
  5    ANCHOR_SERVICE           tcp_ports_in accept, udp_ports_in accept
  6    ANCHOR_FINAL             log + policy drop
```

## Anchor Marker Format

```nft
counter name anchor_<phase> comment "NFTBAN_ANCHOR:ANCHOR_<PHASE>"
```

Present in both `ip nftban` and `ip6 nftban` input chains (14 markers total).

## Module Insertion Map

| Module | Subchain | Anchor | Phase |
|--------|----------|--------|-------|
| ddos_sanity | ddos_sanity | ANCHOR_TRUSTED | 1 |
| ddos_ban_enforce | ddos_ban_enforce | ANCHOR_BAN | 2 |
| ddos_penalty | ddos_penalty | ANCHOR_ESTABLISHED | 3 |
| ddos_synproxy | ddos_synproxy | ANCHOR_ESTABLISHED | 3 |
| portscan_detection | portscan_detection | ANCHOR_DETECT | 4 |
| ddos_protection | ddos_protection | ANCHOR_SERVICE | 5 |
| ddos_prefix | ddos_prefix | ANCHOR_SERVICE | 5 |
| http_bot_guard | http_bot_guard | ANCHOR_SERVICE | 5 |

A module's jump rule MUST have a lower nftables handle than its anchor.

## Non-Negotiable Rules

1. **Bans before established.** Phase 2 before phase 3. Banned IPs' existing connections are killed immediately.
2. **Whitelist before blacklist.** Within phase 1-2 ordering. A whitelisted IP cannot be banned.
3. **Anchors are always present.** They are part of the template and survive rebuilds. Modules do not create or remove anchors.
4. **14 markers exactly.** 7 per address family, no duplicates.

## Invariant Summary

- **INV-O-003 (CRITICAL):** ANCHOR_BAN before ANCHOR_ESTABLISHED
- **INV-F-001 (CRITICAL):** Whitelist accept before blacklist drop
- **INV-S-003 (ERROR):** All 7 anchors exist exactly once per family
- **INV-O-007 (ERROR):** Each module jump handle < its anchor handle

Full invariant registry: [wiki/Firewall-Anchor-Architecture](../../../nftban.wiki/Firewall-Anchor-Architecture.md)

## Verification

```bash
# Count anchors (expect 7 per family)
nft -a list chain ip nftban input | grep -c NFTBAN_ANCHOR

# Validate module placement
scripts/validate-chain-order.sh

# Health check
nftban health
```

## Files

| File | Role |
|------|------|
| `install/nftables/nftables.conf.tpl` | Template with anchor markers |
| `install/nftables/nftables.conf` | Compiled template (default values) |
| `scripts/validate-chain-order.sh` | CI gate for module placement |
| `cli/lib/nftban/core/nftban_health_checks_security.sh` | Runtime health check |
| `cli/lib/nftban/lib/nft_fragment.sh` | Module jump renderers |
