# NFT Schema Validation (v2.1)

NFTBan uses a canonical nftables schema with strict validation to ensure firewall integrity and security.

## 1. Architectural Strategy

### Strict IP Family Separation

NFTBan uses **separate tables**, not inet dual-stack.

| Table | Family | Purpose |
|-------|--------|---------|
| `ip nftban` | IPv4 | Primary IPv4 enforcement |
| `ip6 nftban` | IPv6 | Primary IPv6 enforcement |

**We explicitly DO NOT use:** `table inet nftban`

**Why?**
- No `_v4/_v6` suffix pollution
- No mixed-family evaluation
- Deterministic rule resolution
- Cleaner validation logic
- Lower cognitive complexity

## 2. v2.1 Minimal Set Architecture

### Design Principles

- **Minimal sets**: Only whitelist + blacklist for IP addresses
- **CIDR aggregation**: Lower memory, no IP duplicates
- **Single blacklist**: All ban sources (feeds, geoban, auto, manual) go to ONE set
- **Timeout support**: Temp bans auto-expire via nftables timeout flag
- **Source tracking**: Done in daemon database, not separate nft sets

### IPv4 Sets (`ip nftban`)

| Set | Type | Flags | Purpose |
|-----|------|-------|---------|
| `whitelist_ipv4` | `ipv4_addr` | `interval` | Trusted IPs (admin, internal) |
| `blacklist_ipv4` | `ipv4_addr` | `interval,timeout` | **ALL bans** (feeds+geoban+auto+manual) |
| `tcp_ports_in` | `inet_service` | - | Inbound TCP ports |
| `tcp_ports_out` | `inet_service` | - | Outbound TCP ports |
| `udp_ports_in` | `inet_service` | - | Inbound UDP ports |
| `udp_ports_out` | `inet_service` | - | Outbound UDP ports |

### IPv6 Sets (`ip6 nftban`)

Same structure with `ipv6_addr` types:
- `whitelist_ipv6`, `blacklist_ipv6`
- `tcp_ports_in`, `tcp_ports_out`, `udp_ports_in`, `udp_ports_out`

### Ban Pipeline

All ban sources converge into the single blacklist set:

```
┌──────────────┐
│   Manual     │──┐
├──────────────┤  │
│   Feeds      │──┼──► blacklist_ipv4/ipv6
├──────────────┤  │
│   GeoIP      │──┤
├──────────────┤  │
│ Auto-detect  │──┘   (temp bans use timeout flag)
└──────────────┘
```

## 3. Module System

### Modules are DISABLED by Default

When a module is disabled, it is **NOT loaded** (zero overhead).

| Module | Enable Command | Config File |
|--------|----------------|-------------|
| DDoS Protection | `nftban ddos enable` | `/etc/nftban/conf.d/ddos/classic.conf` |
| Portscan Detection | `nftban portscan enable` | `/etc/nftban/conf.d/portscan/portscan.conf` |
| Threat Feeds | `nftban feeds enable` | `/etc/nftban/conf.d/feeds/feeds.conf` |
| GeoIP Blocking | `nftban geoban enable` | `/etc/nftban/conf.d/geoban/geoban.conf` |
| Login Monitor | `nftban login enable` | `/etc/nftban/conf.d/login/login.conf` |

### Config Hierarchy

1. **Defaults**: `/etc/nftban/conf.d/<module>/<module>.conf`
2. **User Override**: `/etc/nftban/conf.d/<module>/<module>.conf.local` (survives upgrades)

### Example Override

```bash
# /etc/nftban/conf.d/ddos/classic.conf.local
DDOS_CLASSIC_HTTP_CONN_LIMIT="200"
DDOS_CLASSIC_SYN_RATE="50/second"
```

## 4. Directional Service Model

You no longer "open a port." You define:
- **Protocol**: TCP / UDP
- **Direction**: IN / OUT / INOUT
- **State**: NEW only
- **IP Family**: IPv4 / IPv6 (both applied automatically)

### Directional Semantics

| Direction | Chains Affected |
|-----------|-----------------|
| `in` | INPUT chain only |
| `out` | OUTPUT chain only |
| `inout` | Both INPUT and OUTPUT |

Example:
```bash
nftban port add 8080 tcp in      # Inbound only
nftban port add 53 udp inout     # Both directions
```

## 5. Security-Critical Rule Order

The order of rules in the input chain is **non-negotiable**.

### Correct Order (CVE-2025-NFTBAN-001 Prevention)

```
Priority | Rule                            | Purpose
---------|----------------------------------|---------------------------
1        | ct state invalid drop           | Malformed packets
2        | iif lo accept                   | Loopback always allowed
3        | whitelist accept                | Trusted IPs bypass checks
4        | blacklist drop                  | ⚠️ BEFORE established!
5        | ct state established accept     | ✅ NOW safe (after bans)
6        | ICMPv4/ICMPv6 accept            | Control plane
7        | CT limits (DDoS)                | Connection/rate limits
8        | Services (ports) accept         | Public services
9        | default deny                    | Drop everything else
```

### Why This Matters

If blacklist appears AFTER `ct state established`, a banned attacker can keep active sessions alive. This is a **security vulnerability**.

## 6. Connection Limits (CT Limits)

### Defaults (configurable via ddos.conf)

| Service | Limit | Config Variable |
|---------|-------|-----------------|
| SSH | 10 concurrent/IP | `DDOS_CLASSIC_SSH_CONN_LIMIT` |
| HTTP | 100 concurrent/IP | `DDOS_CLASSIC_HTTP_CONN_LIMIT` |
| HTTPS | 100 concurrent/IP | `DDOS_CLASSIC_HTTPS_CONN_LIMIT` |
| SYN Rate | 25/second | `DDOS_CLASSIC_SYN_RATE` |

### Whitelisted IPs Bypass All Limits

IPs in `whitelist_ipv4/ipv6` are accepted BEFORE any limits are evaluated.

## 7. ICMPv6 Requirements

Blocking all ICMPv6 breaks IPv6 completely. These types are **essential**:

```nft
icmpv6 type {
    echo-request, echo-reply,
    destination-unreachable,
    packet-too-big,
    time-exceeded,
    parameter-problem,
    nd-router-solicit,      # Router discovery
    nd-router-advert,       # Router advertisement
    nd-neighbor-solicit,    # Neighbor discovery
    nd-neighbor-advert,     # Neighbor advertisement
    nd-redirect             # Redirect
}
```

**Without these:**
- PMTU blackholes
- Neighbor Discovery failure
- Silent IPv6 routing collapse

## 8. Chain Priorities

### v2.1: Priority 0 (Standard Filter)

```nft
chain input {
    type filter hook input priority 0; policy drop;
}
chain forward {
    type filter hook forward priority 0; policy drop;
}
chain output {
    type filter hook output priority 0; policy accept;
}
```

## 9. IPC-Only Writes

All nftables write operations go through the Go daemon via IPC:

| Operation | IPC Function |
|-----------|--------------|
| Ban IP | `nft_ipc_ban()` |
| Unban IP | `nft_ipc_unban()` |
| Add element | `nft_ipc_add_element()` |
| Delete element | `nft_ipc_delete_element()` |
| Flush set | `nft_ipc_flush_set()` |
| Apply ruleset | `nft_ipc_apply_ruleset()` |

Direct `nft add/delete` commands are **only** used for:
1. **Viewing** (list, get)
2. **Validation** (verify IPC operation succeeded)
3. **Schema checking** (validate structure exists)

## 10. Validation Functions

| Function | Purpose |
|----------|---------|
| `nftban_nft_validate_tables()` | Check required tables exist |
| `nftban_nft_validate_sets()` | Check required sets exist |
| `nftban_nft_validate_set_flags()` | Verify set types and flags |
| `nftban_nft_validate_chains()` | Verify chains with correct policies |
| `nftban_nft_validate_rule_order()` | Security-critical rule order |
| `nftban_nft_validate_full()` | Run all validations |

### Running Validation

```bash
# Full validation
nftban firewall validate --json

# Check status
nftban status
```

## 11. CVE-2025-NFTBAN-001 Protection

If a legacy table exists with permissive policy:

```nft
table inet filter {
    chain input {
        type filter hook input priority 0; policy accept;
    }
}
```

**All bans are bypassed!**

NFTBan automatically detects and warns about this condition during validation.

## 12. Deprecated Tables

These tables should NOT exist in v2.1:

| Table | Reason |
|-------|--------|
| `inet nftban` | v0.6.0-beta single inet table |
| `inet nftban_main` | v0.6.x dual-table approach |
| `inet nftban_runtime` | v0.6.x runtime table |

The validator will report these as warnings for migration.

## 13. Quick Reference

### v2.1 Schema Summary

```
Tables:     ip nftban, ip6 nftban
IP Sets:    whitelist_ipv4/ipv6, blacklist_ipv4/ipv6
Port Sets:  tcp_ports_in/out, udp_ports_in/out
Policy:     input/forward=drop, output=accept
Priority:   0 (standard filter)
```

### Commands

```bash
# Validation
nftban firewall validate

# Module management
nftban ddos status
nftban ddos enable
nftban ddos disable

# Ban/unban (goes to blacklist)
nftban ban 1.2.3.4 --reason "spam"
nftban ban 1.2.3.4 --timeout 3600   # temp ban (1 hour)
nftban unban 1.2.3.4

# Ports
nftban port add 8080 tcp in
nftban port list
```

## 14. Final Maturity Assessment

NFTBan v2.1 is:
- ✅ Stateful
- ✅ Directional
- ✅ Protocol-explicit
- ✅ Dual-stack deterministic
- ✅ Schema-validated
- ✅ CVE-protected
- ✅ IPC-only writes
- ✅ CIDR aggregated (low memory)
- ✅ Module-based (disabled = not loaded)

It is a **structured nftables governance framework**.
