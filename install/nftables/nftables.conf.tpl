#!/usr/sbin/nft -f
# =============================================================================
# NFTBan v2.1 - Directional Stateful Architecture
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftables_config"
# meta:type="config"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-10-26"
# meta:description="Production nftables schema with CIDR aggregation"
# meta:input="None"
# meta:output="nftables ruleset with IPv4/IPv6 tables"
# meta:depends=""
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
#
# NFTBan v2.1 SCHEMA OVERVIEW
# ===========================
#
# ARCHITECTURE:
#   - Separate ip/ip6 tables (NOT inet dual-stack)
#   - Minimal sets: whitelist + blacklist only (CIDR aggregated)
#   - Directional ports: tcp_ports_in/out, udp_ports_in/out
#   - All bans go to blacklist (feeds, geoban, auto, manual)
#   - Temp bans use timeout flag (auto-expire)
#   - Source tracking in daemon database
#
# SETS (per table):
#   whitelist_ipv4/ipv6        - Trusted IPs/networks (bypass all checks)
#   blacklist_manual_ipv4/ipv6 - Manual/auto-detect bans (hash O(1), v1.33.0)
#   blacklist_ipv4/ipv6        - Feed/geoban bans (interval, CIDR aggregated)
#   tcp_ports_in/out           - Directional TCP service ports
#   udp_ports_in/out           - Directional UDP service ports
#   http_bot_*                 - Bot Guard sets (6 per family, always present, empty when disabled)
#
# RULE ORDER (security-critical):
#   1. ct state invalid drop
#   2. loopback accept
#   3. whitelist accept    <- trusted IPs skip everything
#   4. blacklist drop      <- BEFORE established (CVE protection)
#   5. ct state established,related accept
#   6. ICMP/ICMPv6 essentials
#   7. CT limits (DDoS protection)
#   8. Service ports
#   9. Default deny (policy drop)
#
# MODULE SYSTEM:
#   Modules are DISABLED by default. Enable via:
#     nftban ddos enable      # DDoS protection
#     nftban portscan enable  # Portscan detection
#     nftban feeds enable     # Threat intelligence feeds
#     nftban geoban enable    # Country blocking
#     nftban login enable     # Login brute-force protection
#
#   When disabled, modules are NOT loaded (no overhead).
#   When enabled, modules read config from:
#     /etc/nftban/conf.d/<module>/<module>.conf        (defaults)
#     /etc/nftban/conf.d/<module>/<module>.conf.local  (user overrides)
#
# CT LIMITS (base schema placeholders, substituted at rebuild):
#   __CT_LIMIT_SSH__   default: 15 (or DDoS SSH limit when DDoS active)
#   __CT_LIMIT_HTTP__  default: 150 (or DDoS HTTP limit when DDoS active)
#   __CT_LIMIT_MAIL__  default: 150 (or DDoS SMTP limit when DDoS active)
#
#   v1.49.0 FIX-F: Base limits were dead when DDoS module active because
#   DDoS helper chain had stricter limits (SSH:10 vs base:15). Now both
#   use the same configurable values. Override via:
#     /etc/nftban/conf.d/ddos/classic.conf.local:
#       DDOS_CLASSIC_SSH_CONN_LIMIT="20"
#
# =============================================================================

# Clean slate - delete existing NFTBan tables
table ip nftban { }
table ip6 nftban { }
delete table ip nftban
delete table ip6 nftban

# =============================================================================
# IPv4 TABLE: ip nftban
# =============================================================================

table ip nftban {

    # =========================================================================
    # SETS - Minimal architecture (CIDR aggregated, no duplicates)
    # =========================================================================

    # Whitelist - trusted IPs/networks (CIDR interval for aggregation)
    # v1.39.0: BEHAVIOR CHANGE — Removed RFC1918 private ranges (10.0.0.0/8,
    # 172.16.0.0/12, 192.168.0.0/16) from default whitelist. Private networks
    # should never reach a public-facing firewall; whitelisting them by default
    # could mask spoofed-source attacks. Add back explicitly if needed:
    #   nftban whitelist add 10.0.0.0/8
    set whitelist_ipv4 {
        type ipv4_addr
        flags interval
        auto-merge
        comment "Trusted IPs and networks"
        elements = {
            127.0.0.1
        }
    }

    # Blacklist - Feed/geoban IPs (CIDR aggregated, interval set for range support)
    # Temp bans use timeout parameter (auto-expire)
    set blacklist_ipv4 {
        type ipv4_addr
        flags interval, timeout
        auto-merge
        comment "Feed and geoban bans (CIDR aggregated, interval O(n))"
    }

    # Blacklist Manual - Manual/auto-detect bans (hash set for O(1) performance)
    # Sources: manual CLI, loginmon, portscan, ddos, botguard, suricata
    set blacklist_manual_ipv4 {
        type ipv4_addr
        flags timeout
        comment "Manual and auto-detect bans (hash O(1))"
    }

    # Directional TCP ports (v2.1 model)
    set tcp_ports_in {
        type inet_service
        comment "Allowed inbound TCP ports"
        elements = { __SSH_PORT__, 80, 443 }
    }

    set tcp_ports_out {
        type inet_service
        comment "Allowed outbound TCP ports"
        # Baseline required egress: DNS, HTTP, HTTPS
        elements = { 53, 80, 443 }
    }

    # Directional UDP ports (v2.1 model)
    set udp_ports_in {
        type inet_service
        comment "Allowed inbound UDP ports"
    }

    set udp_ports_out {
        type inet_service
        comment "Allowed outbound UDP ports"
        # Baseline required egress: DNS, NTP
        elements = { 53, 123 }
    }

    # =========================================================================
    # HTTP BOT GUARD SETS (v1.21.4)
    # Always present in schema — cost nothing when empty.
    # Populated by nftband when botguard is enabled.
    # =========================================================================

    # Kernel-populated: nft meter marks IPs exceeding request rate
    set http_bot_suspect {
        type ipv4_addr
        flags timeout
        comment "Kernel-populated HTTP bot suspects"
    }

    # Go-populated: awaiting classification (light throttle)
    set http_bot_pending {
        type ipv4_addr
        flags timeout
        comment "Awaiting bot classification"
    }

    # Go-populated: verified allowed crawlers (bypass throttle)
    set http_bot_allow {
        type ipv4_addr
        flags timeout
        comment "Verified allowed crawlers"
    }

    # Go-populated: suspicious bots (heavy throttle)
    set http_bot_grey {
        type ipv4_addr
        flags timeout
        comment "Suspicious bots, throttled"
    }

    # Go-populated: denied/malicious bots (full drop)
    set http_bot_ban {
        type ipv4_addr
        flags timeout
        comment "Denied/malicious bots"
    }

    # Go-populated: emergency pressure blocks (immediate drop)
    set http_bot_emergency {
        type ipv4_addr
        flags timeout
        comment "Emergency pressure blocks"
    }

    # =========================================================================
    # PER-IP PORT ACCESS SETS (v1.41.0 — concat IP+port for granular access)
    # =========================================================================

    set port_allow_tcp_ipv4 {
        type ipv4_addr . inet_service
        flags timeout
        comment "Per-IP TCP port access"
    }

    set port_allow_udp_ipv4 {
        type ipv4_addr . inet_service
        flags timeout
        comment "Per-IP UDP port access"
    }

    # =========================================================================
    # NAMED COUNTERS (v1.41.0 — replace anonymous for Prometheus export)
    # =========================================================================

    counter input_invalid_drop {
        comment "Invalid state packets dropped"
    }

    counter input_whitelist_accept {
        comment "Whitelisted IPs accepted"
    }

    counter input_blacklist_manual_drop {
        comment "Manual blacklist drops"
    }

    counter input_blacklist_drop {
        comment "Feed/geoban blacklist drops"
    }

    counter input_port_allow_tcp_accept {
        comment "Per-IP TCP access accepted"
    }

    counter input_port_allow_udp_accept {
        comment "Per-IP UDP access accepted"
    }

    counter input_ct_ssh_drop {
        comment "SSH conn limit drops"
    }

    counter input_ct_http_drop {
        comment "HTTP conn limit drops"
    }

    counter input_ct_mail_drop {
        comment "Mail conn limit drops"
    }

    # v1.46.0: New input counters (FIX-B, FIX-D, partial FIX-E)
    counter input_loopback_accept {
        comment "Loopback input accepted"
    }

    counter input_established_accept {
        comment "Established/related connection accepted"
    }

    counter input_icmp_accept {
        comment "ICMP/ICMPv6 essential accepted"
    }

    counter input_syn_rate_exceeded {
        comment "SYN rate exceeded per-IP (portscan detection)"
    }

    counter input_service_tcp_accept {
        comment "Inbound TCP service port accepted"
    }

    counter input_service_udp_accept {
        comment "Inbound UDP service port accepted"
    }

    counter output_loopback_accept {
        comment "Loopback output accepted"
    }

    counter output_established_accept {
        comment "Established output accepted"
    }

    counter output_icmp_accept {
        comment "ICMPv4 output accepted"
    }

    counter output_tcp_accept {
        comment "Outbound TCP accepted"
    }

    counter output_udp_accept {
        comment "Outbound UDP accepted"
    }

    counter output_egress_audit {
        comment "Unknown egress audit events"
    }

    # v1.42.0: Global aggregate counters (SOC-grade observability)
    counter total_input_accept {
        comment "Total packets accepted on input chain"
    }

    counter total_input_drop {
        comment "Total packets dropped on input chain (policy + explicit)"
    }

    # v1.62.0: Anchor counters — phase boundary markers for structure validation
    counter anchor_hygiene {
        comment "NFTBAN_ANCHOR:ANCHOR_HYGIENE phase boundary"
    }

    counter anchor_trusted {
        comment "NFTBAN_ANCHOR:ANCHOR_TRUSTED phase boundary"
    }

    counter anchor_ban {
        comment "NFTBAN_ANCHOR:ANCHOR_BAN phase boundary"
    }

    counter anchor_established {
        comment "NFTBAN_ANCHOR:ANCHOR_ESTABLISHED phase boundary"
    }

    counter anchor_detect {
        comment "NFTBAN_ANCHOR:ANCHOR_DETECT phase boundary"
    }

    counter anchor_service {
        comment "NFTBAN_ANCHOR:ANCHOR_SERVICE phase boundary"
    }

    counter anchor_final {
        comment "NFTBAN_ANCHOR:ANCHOR_FINAL phase boundary"
    }

    # =========================================================================
    # INPUT CHAIN - Security-critical rule order with full protections
    # =========================================================================

    chain input {
        type filter hook input priority 0; policy drop;

        # ── Phase 0: HYGIENE ──────────────────────────────────────
        counter name anchor_hygiene comment "NFTBAN_ANCHOR:ANCHOR_HYGIENE"

        # 1. Drop invalid packets early
        ct state invalid counter name input_invalid_drop counter name total_input_drop drop comment "invalid state"

        # ── Phase 1: TRUSTED ──────────────────────────────────────
        counter name anchor_trusted comment "NFTBAN_ANCHOR:ANCHOR_TRUSTED"

        # 2. Loopback - always allowed
        iif "lo" counter name input_loopback_accept counter name total_input_accept accept

        # 3. Trust / Block (CRITICAL: blacklist BEFORE established)
        ip saddr @whitelist_ipv4 counter name input_whitelist_accept counter name total_input_accept accept

        # ── Phase 2: BAN ──────────────────────────────────────────
        counter name anchor_ban comment "NFTBAN_ANCHOR:ANCHOR_BAN"

        ip saddr @blacklist_manual_ipv4 counter name input_blacklist_manual_drop counter name total_input_drop drop
        ip saddr @blacklist_ipv4 counter name input_blacklist_drop counter name total_input_drop drop

        # 3b. Per-IP port access (AFTER blacklist — bans always win)
        ip saddr . tcp dport @port_allow_tcp_ipv4 counter name input_port_allow_tcp_accept counter name total_input_accept accept comment "per-IP TCP access"
        ip saddr . udp dport @port_allow_udp_ipv4 counter name input_port_allow_udp_accept counter name total_input_accept accept comment "per-IP UDP access"

        # ── Phase 3: ESTABLISHED ──────────────────────────────────
        counter name anchor_established comment "NFTBAN_ANCHOR:ANCHOR_ESTABLISHED"

        # 4. Stateful (after blacklist - CVE-2025-NFTBAN-001 protection)
        ct state established,related counter name input_established_accept counter name total_input_accept accept

        # 5. ICMPv4 Essentials
        ip protocol icmp icmp type {
            echo-request,
            echo-reply,
            destination-unreachable,
            time-exceeded,
            parameter-problem
        } counter name input_icmp_accept counter name total_input_accept accept

        # ── Phase 4: DETECT ───────────────────────────────────────
        counter name anchor_detect comment "NFTBAN_ANCHOR:ANCHOR_DETECT"

        # 6. CT LIMITS - DDoS protection (per source IP limits)
        ct state new tcp dport __SSH_PORT__ ct count over __CT_LIMIT_SSH__ counter name input_ct_ssh_drop counter name total_input_drop drop comment "SSH: max __CT_LIMIT_SSH__ concurrent per IP"
        ct state new tcp dport { 80, 443 } ct count over __CT_LIMIT_HTTP__ counter name input_ct_http_drop counter name total_input_drop drop comment "HTTP(S): max __CT_LIMIT_HTTP__ concurrent per IP"
        ct state new tcp dport { 25, 465, 587 } ct count over __CT_LIMIT_MAIL__ counter name input_ct_mail_drop counter name total_input_drop drop comment "MAIL: max __CT_LIMIT_MAIL__ concurrent per IP"

        # 7. SYN RATE LIMIT - Portscan detection (per source IP)
        # v1.46.0 FIX-B: Two-rule pattern — accept within limit, log+drop exceeded
        # Old rule logged WITHIN limit (normal traffic) due to nftables semantics.
        # Now: meter accepts OK traffic, follow-up rule catches rate-exceeded SYNs.
        tcp flags syn ct state new meter syn_meter_v4 { ip saddr limit rate 25/second burst 50 packets } counter name total_input_accept accept comment "SYN rate OK"
        tcp flags syn ct state new counter name input_syn_rate_exceeded counter name total_input_drop log prefix "NFTBAN_PORTSCAN: " drop comment "SYN rate exceeded"

        # ── Phase 5: SERVICE ──────────────────────────────────────
        counter name anchor_service comment "NFTBAN_ANCHOR:ANCHOR_SERVICE"

        # 8. Directional Services (Inbound only)
        tcp dport @tcp_ports_in ct state new counter name input_service_tcp_accept counter name total_input_accept accept
        udp dport @udp_ports_in ct state new counter name input_service_udp_accept counter name total_input_accept accept

        # ── Phase 6: FINAL ────────────────────────────────────────
        counter name anchor_final comment "NFTBAN_ANCHOR:ANCHOR_FINAL"

        # 9. Log drops (rate limited) — unmatched traffic hits policy drop
        counter name total_input_drop log prefix "nftban: drop: " limit rate 10/minute
    }

    # =========================================================================
    # FORWARD CHAIN
    # =========================================================================

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    # =========================================================================
    # OUTPUT CHAIN
    # =========================================================================

    chain output {
        type filter hook output priority 0; policy accept;

        # 1. Loopback - always allowed
        oif "lo" counter name output_loopback_accept accept

        # 2. Stateful - allow responses to established connections
        ct state established,related counter name output_established_accept accept

        # 3. ICMPv4 Essentials (for path MTU discovery, ping, etc.)
        ip protocol icmp counter name output_icmp_accept accept

        # 4. Outbound Services (from sets - enforcement ready)
        # NOTE: policy is 'accept' so these are informational until Phase 3
        meta l4proto tcp tcp dport @tcp_ports_out ct state new counter name output_tcp_accept accept comment "allowed outbound TCP"
        meta l4proto udp udp dport @udp_ports_out ct state new counter name output_udp_accept accept comment "allowed outbound UDP"

        # 5. Audit: Log unknown outbound ports (not in sets above)
        # Rate-limited to prevent log flooding on busy servers
        meta l4proto { tcp, udp } ct state new limit rate 5/second counter name output_egress_audit log prefix "NFTBAN_EGRESS_AUDIT: " comment "audit unknown egress"
    }
}

# =============================================================================
# IPv6 TABLE: ip6 nftban
# =============================================================================

table ip6 nftban {

    # =========================================================================
    # SETS - Same minimal architecture as IPv4
    # =========================================================================

    set whitelist_ipv6 {
        type ipv6_addr
        flags interval
        auto-merge
        comment "Trusted IPv6 addresses and networks"
        elements = { ::1 }
    }

    set blacklist_ipv6 {
        type ipv6_addr
        flags interval, timeout
        auto-merge
        comment "Feed and geoban bans (CIDR aggregated, interval O(n))"
    }

    # Blacklist Manual - Manual/auto-detect bans (hash set for O(1) performance)
    set blacklist_manual_ipv6 {
        type ipv6_addr
        flags timeout
        comment "Manual and auto-detect bans (hash O(1))"
    }

    set tcp_ports_in {
        type inet_service
        comment "Allowed inbound TCP ports"
        elements = { __SSH_PORT__, 80, 443 }
    }

    set tcp_ports_out {
        type inet_service
        comment "Allowed outbound TCP ports"
        # Baseline required egress: DNS, HTTP, HTTPS
        elements = { 53, 80, 443 }
    }

    set udp_ports_in {
        type inet_service
        comment "Allowed inbound UDP ports"
    }

    set udp_ports_out {
        type inet_service
        comment "Allowed outbound UDP ports"
        # Baseline required egress: DNS, NTP
        elements = { 53, 123 }
    }

    # =========================================================================
    # HTTP BOT GUARD SETS - IPv6 (v1.21.4)
    # =========================================================================

    set http_bot_suspect6 {
        type ipv6_addr
        flags timeout
        comment "Kernel-populated HTTP bot suspects"
    }

    set http_bot_pending6 {
        type ipv6_addr
        flags timeout
        comment "Awaiting bot classification"
    }

    set http_bot_allow6 {
        type ipv6_addr
        flags timeout
        comment "Verified allowed crawlers"
    }

    set http_bot_grey6 {
        type ipv6_addr
        flags timeout
        comment "Suspicious bots, throttled"
    }

    set http_bot_ban6 {
        type ipv6_addr
        flags timeout
        comment "Denied/malicious bots"
    }

    set http_bot_emergency6 {
        type ipv6_addr
        flags timeout
        comment "Emergency pressure blocks"
    }

    # =========================================================================
    # PER-IP PORT ACCESS SETS (v1.41.0 — concat IP+port for granular access)
    # =========================================================================

    set port_allow_tcp_ipv6 {
        type ipv6_addr . inet_service
        flags timeout
        comment "Per-IP TCP port access"
    }

    set port_allow_udp_ipv6 {
        type ipv6_addr . inet_service
        flags timeout
        comment "Per-IP UDP port access"
    }

    # =========================================================================
    # NAMED COUNTERS (v1.41.0 — replace anonymous for Prometheus export)
    # =========================================================================

    counter input_invalid_drop {
        comment "Invalid state packets dropped"
    }

    counter input_whitelist_accept {
        comment "Whitelisted IPs accepted"
    }

    counter input_blacklist_manual_drop {
        comment "Manual blacklist drops"
    }

    counter input_blacklist_drop {
        comment "Feed/geoban blacklist drops"
    }

    counter input_port_allow_tcp_accept {
        comment "Per-IP TCP access accepted"
    }

    counter input_port_allow_udp_accept {
        comment "Per-IP UDP access accepted"
    }

    counter input_ct_ssh_drop {
        comment "SSH conn limit drops"
    }

    counter input_ct_http_drop {
        comment "HTTP conn limit drops"
    }

    counter input_ct_mail_drop {
        comment "Mail conn limit drops"
    }

    # v1.46.0: New input counters (FIX-B, FIX-D, partial FIX-E)
    counter input_loopback_accept {
        comment "Loopback input accepted"
    }

    counter input_established_accept {
        comment "Established/related connection accepted"
    }

    counter input_icmp_accept {
        comment "ICMP/ICMPv6 essential accepted"
    }

    counter input_syn_rate_exceeded {
        comment "SYN rate exceeded per-IP (portscan detection)"
    }

    counter input_service_tcp_accept {
        comment "Inbound TCP service port accepted"
    }

    counter input_service_udp_accept {
        comment "Inbound UDP service port accepted"
    }

    counter output_loopback_accept {
        comment "Loopback output accepted"
    }

    counter output_established_accept {
        comment "Established output accepted"
    }

    counter output_icmpv6_accept {
        comment "ICMPv6 output accepted"
    }

    counter output_tcp_accept {
        comment "Outbound TCP accepted"
    }

    counter output_udp_accept {
        comment "Outbound UDP accepted"
    }

    counter output_egress_audit {
        comment "Unknown egress audit events"
    }

    # v1.42.0: Global aggregate counters (SOC-grade observability)
    counter total_input_accept {
        comment "Total packets accepted on input chain"
    }

    counter total_input_drop {
        comment "Total packets dropped on input chain (policy + explicit)"
    }

    # v1.62.0: Anchor counters — phase boundary markers for structure validation
    counter anchor_hygiene {
        comment "NFTBAN_ANCHOR:ANCHOR_HYGIENE phase boundary"
    }

    counter anchor_trusted {
        comment "NFTBAN_ANCHOR:ANCHOR_TRUSTED phase boundary"
    }

    counter anchor_ban {
        comment "NFTBAN_ANCHOR:ANCHOR_BAN phase boundary"
    }

    counter anchor_established {
        comment "NFTBAN_ANCHOR:ANCHOR_ESTABLISHED phase boundary"
    }

    counter anchor_detect {
        comment "NFTBAN_ANCHOR:ANCHOR_DETECT phase boundary"
    }

    counter anchor_service {
        comment "NFTBAN_ANCHOR:ANCHOR_SERVICE phase boundary"
    }

    counter anchor_final {
        comment "NFTBAN_ANCHOR:ANCHOR_FINAL phase boundary"
    }

    # =========================================================================
    # INPUT CHAIN - Full protections (same as IPv4)
    # =========================================================================

    chain input {
        type filter hook input priority 0; policy drop;

        # ── Phase 0: HYGIENE ──────────────────────────────────────
        counter name anchor_hygiene comment "NFTBAN_ANCHOR:ANCHOR_HYGIENE"

        # 1. Drop invalid packets
        ct state invalid counter name input_invalid_drop counter name total_input_drop drop comment "invalid state"

        # ── Phase 1: TRUSTED ──────────────────────────────────────
        counter name anchor_trusted comment "NFTBAN_ANCHOR:ANCHOR_TRUSTED"

        # 2. Loopback
        iif "lo" counter name input_loopback_accept counter name total_input_accept accept

        # 3. Trust / Block
        ip6 saddr @whitelist_ipv6 counter name input_whitelist_accept counter name total_input_accept accept

        # ── Phase 2: BAN ──────────────────────────────────────────
        counter name anchor_ban comment "NFTBAN_ANCHOR:ANCHOR_BAN"

        ip6 saddr @blacklist_manual_ipv6 counter name input_blacklist_manual_drop counter name total_input_drop drop
        ip6 saddr @blacklist_ipv6 counter name input_blacklist_drop counter name total_input_drop drop

        # 3b. Per-IP port access (AFTER blacklist — bans always win)
        ip6 saddr . tcp dport @port_allow_tcp_ipv6 counter name input_port_allow_tcp_accept counter name total_input_accept accept comment "per-IP TCP access"
        ip6 saddr . udp dport @port_allow_udp_ipv6 counter name input_port_allow_udp_accept counter name total_input_accept accept comment "per-IP UDP access"

        # ── Phase 3: ESTABLISHED ──────────────────────────────────
        counter name anchor_established comment "NFTBAN_ANCHOR:ANCHOR_ESTABLISHED"

        # 4. Stateful
        ct state established,related counter name input_established_accept counter name total_input_accept accept

        # 5. ICMPv6 - Essential for IPv6 operation (DO NOT BLOCK)
        meta l4proto ipv6-icmp icmpv6 type {
            echo-request,
            echo-reply,
            destination-unreachable,
            packet-too-big,
            time-exceeded,
            parameter-problem,
            nd-router-solicit,
            nd-router-advert,
            nd-neighbor-solicit,
            nd-neighbor-advert,
            nd-redirect
        } counter name input_icmp_accept counter name total_input_accept accept

        # ── Phase 4: DETECT ───────────────────────────────────────
        counter name anchor_detect comment "NFTBAN_ANCHOR:ANCHOR_DETECT"

        # 6. CT LIMITS - DDoS protection (per source IP limits)
        ct state new tcp dport __SSH_PORT__ ct count over __CT_LIMIT_SSH__ counter name input_ct_ssh_drop counter name total_input_drop drop comment "SSH: max __CT_LIMIT_SSH__ concurrent per IP"
        ct state new tcp dport { 80, 443 } ct count over __CT_LIMIT_HTTP__ counter name input_ct_http_drop counter name total_input_drop drop comment "HTTP(S): max __CT_LIMIT_HTTP__ concurrent per IP"
        ct state new tcp dport { 25, 465, 587 } ct count over __CT_LIMIT_MAIL__ counter name input_ct_mail_drop counter name total_input_drop drop comment "MAIL: max __CT_LIMIT_MAIL__ concurrent per IP"

        # 7. SYN RATE LIMIT - Portscan detection (per source IP)
        # v1.46.0 FIX-B: Two-rule pattern (same as IPv4)
        tcp flags syn ct state new meter syn_meter_v6 { ip6 saddr limit rate 25/second burst 50 packets } counter name total_input_accept accept comment "SYN rate OK"
        tcp flags syn ct state new counter name input_syn_rate_exceeded counter name total_input_drop log prefix "NFTBAN_PORTSCAN: " drop comment "SYN rate exceeded"

        # ── Phase 5: SERVICE ──────────────────────────────────────
        counter name anchor_service comment "NFTBAN_ANCHOR:ANCHOR_SERVICE"

        # 8. Directional Services
        tcp dport @tcp_ports_in ct state new counter name input_service_tcp_accept counter name total_input_accept accept
        udp dport @udp_ports_in ct state new counter name input_service_udp_accept counter name total_input_accept accept

        # ── Phase 6: FINAL ────────────────────────────────────────
        counter name anchor_final comment "NFTBAN_ANCHOR:ANCHOR_FINAL"

        # 9. Log drops (rate limited) — unmatched traffic hits policy drop
        counter name total_input_drop log prefix "nftban: drop: " limit rate 10/minute
    }

    # =========================================================================
    # FORWARD CHAIN
    # =========================================================================

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    # =========================================================================
    # OUTPUT CHAIN
    # =========================================================================

    chain output {
        type filter hook output priority 0; policy accept;

        # 1. Loopback - always allowed
        oif "lo" counter name output_loopback_accept accept

        # 2. Stateful - allow responses to established connections
        ct state established,related counter name output_established_accept accept

        # 3. ICMPv6 Essentials (REQUIRED for IPv6 operation - neighbor/router discovery)
        meta l4proto ipv6-icmp counter name output_icmpv6_accept accept

        # 4. Outbound Services (from sets - enforcement ready)
        # NOTE: policy is 'accept' so these are informational until Phase 3
        meta l4proto tcp tcp dport @tcp_ports_out ct state new counter name output_tcp_accept accept comment "allowed outbound TCP"
        meta l4proto udp udp dport @udp_ports_out ct state new counter name output_udp_accept accept comment "allowed outbound UDP"

        # 5. Audit: Log unknown outbound ports (not in sets above)
        # Rate-limited to prevent log flooding on busy servers
        meta l4proto { tcp, udp } ct state new limit rate 5/second counter name output_egress_audit log prefix "NFTBAN_EGRESS_AUDIT6: " comment "audit unknown egress"
    }
}
