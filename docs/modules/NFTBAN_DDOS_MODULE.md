# NFTBan DDoS Protection Module

**Module:** `nftban_ddos_module.sh` | **Version:** 0.9.3-dev | **Location:** `/usr/local/lib/nftban/`

## Overview

Implements 4 types of DDoS protection: SYN flood, connection limiting, port flooding, and ICMP rate limiting using nftables.

### Key Features

- **SYN Flood Protection**: Rate limits TCP SYN packets (100/second default, burst 150)
- **Connection Limits**: Per-IP concurrent connection limits per port (SSH: 5, HTTP: 20, HTTPS: 20)
- **Port Flood Protection**: New connection rate limiting (SSH: 5/300s, HTTP: 20/5s)
- **ICMP Protection**: Rate limit ping (1/second), block timestamp/addressmask requests
- **Config-Based**: `.conf` + `.conf.local` override system
- **Logging**: Dedicated DDoS log with rate-limited kernel logging

---

## API Reference

### SYN Flood Protection

**`nftban_ddos_synflood_enable()`** - Enable SYN flood protection
```bash
nftban_ddos_synflood_enable
# ✓ SYN flood protection enabled (rate: 100/second, burst: 150)
```

**`nftban_ddos_synflood_disable()`** - Disable SYN flood protection
**`nftban_ddos_synflood_status()`** - Show status

**Config:**
- `SYNFLOOD_RATE`: "100/second" (default)
- `SYNFLOOD_BURST`: "150" packets
- `SYNFLOOD_LOG`: "1" (enable logging)

---

### Connection Limit Protection

**`nftban_ddos_connlimit_enable()`** - Enable connection limits for standard ports
```bash
nftban_ddos_connlimit_enable
# ✓ Connection limit protection enabled: 9 port(s) configured
```

**`nftban_ddos_connlimit_add_port(port, limit, [action])`** - Add per-port limit
```bash
nftban_ddos_connlimit_add_port 22 5 reject
# ✓ Connection limit added for port 22: max 5 connections per IP
```

**`nftban_ddos_connlimit_disable()`** - Disable all connection limits
**`nftban_ddos_connlimit_status()`** - Show status

**Config:**
- `CONNLIMIT_SSH`: "5" concurrent connections
- `CONNLIMIT_HTTP`: "20"
- `CONNLIMIT_HTTPS`: "20"
- `CONNLIMIT_FTP`: "3"
- `CONNLIMIT_SMTP`: "5"
- `CONNLIMIT_POP3`: "5"
- `CONNLIMIT_IMAP`: "5"
- `CONNLIMIT_MYSQL`: "10"
- `CONNLIMIT_POSTGRESQL`: "10"
- `CONNLIMIT_CUSTOM`: "port1;limit1,port2;limit2"
- `CONNLIMIT_ACTION`: "reject" or "drop"

---

### Port Flood Protection

**`nftban_ddos_portflood_enable()`** - Enable port flood protection
```bash
nftban_ddos_portflood_enable
# ✓ Port flood protection enabled: 5 port(s) configured
```

**`nftban_ddos_portflood_add_port(port, rate_config)`** - Add rate limit
```bash
nftban_ddos_portflood_add_port 22 "5/300"
# ✓ Port flood protection added for port 22: max 5 connections per 300 seconds
```

**`nftban_ddos_portflood_disable()`** - Disable port flood protection
**`nftban_ddos_portflood_status()`** - Show status

**Config:**
- `PORTFLOOD_SSH`: "5/300" (5 connections per 300 seconds)
- `PORTFLOOD_HTTP`: "20/5"
- `PORTFLOOD_HTTPS`: "20/5"
- `PORTFLOOD_FTP`: "10/60"
- `PORTFLOOD_SMTP`: "5/300"
- `PORTFLOOD_CUSTOM`: "port1;rate1,port2;rate2"

---

### ICMP Protection

**`nftban_ddos_icmp_enable()`** - Enable ICMP rate limiting
```bash
nftban_ddos_icmp_enable
# ✓ ICMP echo request rate limiting enabled: 1/second
# ✓ ICMP timestamp requests blocked (PCI compliance)
# ✓ ICMP address mask requests blocked
```

**`nftban_ddos_icmp_disable()`** - Disable ICMP protection
**`nftban_ddos_icmp_status()`** - Show status

**Config:**
- `ICMP_IN_RATE`: "1/second" (ping rate limit)
- `ICMP_TIMESTAMP_DROP`: "0" (PCI compliance)
- `ICMP_ADDRESSMASK_DROP`: "1" (security)

---

### Master Control

**`nftban_ddos_enable_all()`** - Enable all configured protections
**`nftban_ddos_disable_all()`** - Disable all protections
**`nftban_ddos_status()`** - Comprehensive status report

---

## Configuration

**Files:**
- `/etc/nftban/ddos_protection.conf` - Main configuration
- `/etc/nftban/ddos_protection.conf.local` - User overrides
- `/var/log/nftban/ddos-protection.log` - DDoS log

**Global Settings:**
- `DDOS_PROTECTION_ENABLED`: "1" (master switch)
- `DDOS_LOGGING_ENABLED`: "1"
- `DDOS_EMAIL_ALERTS`: "1"

---

## CLI Integration

```bash
# Enable all DDoS protections
nftban ddos enable

# Disable all
nftban ddos disable

# Show status
nftban ddos status

# Enable specific protection
nftban ddos synflood enable
nftban ddos connlimit enable
nftban ddos portflood enable
nftban ddos icmp enable
```

---

## nftables Implementation

**SYN Flood Chain:**
```nft
chain synflood_protection {
    tcp flags syn tcp dport != 0 ct state new \
        limit rate 100/second burst 150 packets counter accept
    tcp flags syn limit rate 30/minute burst 5 packets \
        log prefix "nftban: SYNFLOOD: " counter
    tcp flags syn counter drop
}
```

**Connection Limit Rules:**
```nft
# SSH connection limit (5 per IP)
tcp dport 22 tcp flags syn ct state new ct count over 5 counter reject
```

**Port Flood Rules:**
```nft
# SSH rate limit (5 connections per 300 seconds)
tcp dport 22 ct state new limit rate over 5/300 second counter drop
```

**ICMP Rules:**
```nft
# Ping rate limit
ip protocol icmp icmp type echo-request limit rate 1/second counter accept
ip protocol icmp icmp type echo-request counter drop

# Block timestamp requests
ip protocol icmp icmp type timestamp-request counter drop
```

---

## Testing

```bash
# Test SYN flood protection
hping3 -S -p 80 --flood target

# Test connection limit (SSH)
for i in {1..10}; do ssh user@target & done

# Test port flood (SSH)
for i in {1..10}; do nc target 22 & done

# Test ICMP rate limit
ping -f target
```

---

## Performance

- **SYN Flood**: Minimal overhead (< 1% CPU at 10k pps)
- **Connection Limits**: O(1) per connection (ct count)
- **Port Flood**: Minimal overhead (stateful tracking)
- **ICMP**: Negligible impact

---

## License

**NFTBAN Custom License v3.0** | SPDX-License-Identifier: NFTBAN-Custom-License
© 2025 Antonios Voulvoulis – ITCMS. All rights reserved.

**Summary:**
- ✅ Free to use for any purpose (personal, commercial, production)
- ✅ Free to modify privately
- ✅ Free to deploy unlimited instances
- ❌ NO redistribution, republication, or resale
- ❌ NO public GitHub forks or package uploads

Full license: https://github.com/itcmsgr/nftban/blob/main/LICENSE.md

**Made by ITCMS** | https://itcms.gr
