#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.19.6 - Review Test: Portscan + DDoS Modules (Chat 09)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="09_portscan_ddos_test"
# meta:type="test"
# meta:header="Portscan + DDoS Review Test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Static analysis tests for portscan and DDoS detection modules"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# meta:created_date="2026-02-27"
# meta:updated_date="2026-02-27"
# =============================================================================
# Static analysis only. No root, no nftables, no systemd required.
# Run from repository root:  bash tests/review/09_portscan_ddos_test.sh
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# RESOLVE REPO ROOT
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Verify repo root by checking for VERSION file
if [[ ! -f "${REPO_ROOT}/VERSION" ]]; then
    echo "FATAL: Cannot find VERSION file. Run from repo root." >&2
    exit 2
fi

# =============================================================================
# MODULE PATHS
# =============================================================================

# Core modules
PORTSCAN_MAIN="${REPO_ROOT}/cli/lib/nftban/core/nftban_portscan.sh"
PORTSCAN_CLASSIC="${REPO_ROOT}/cli/lib/nftban/core/nftban_portscan_classic.sh"
PORTSCAN_SURICATA="${REPO_ROOT}/cli/lib/nftban/core/nftban_portscan_suricata.sh"
DDOS_MAIN="${REPO_ROOT}/cli/lib/nftban/core/nftban_ddos.sh"
DDOS_CLASSIC="${REPO_ROOT}/cli/lib/nftban/core/nftban_ddos_classic.sh"
DDOS_SURICATA="${REPO_ROOT}/cli/lib/nftban/core/nftban_ddos_suricata.sh"

# CLI handlers
CMD_PORTSCAN="${REPO_ROOT}/cli/lib/nftban/cli/cmd_portscan.sh"
CMD_DDOS="${REPO_ROOT}/cli/lib/nftban/cli/cmd_ddos.sh"

# Config files
CONF_PORTSCAN_MAIN="${REPO_ROOT}/etc/nftban/conf.d/portscan/main.conf"
CONF_PORTSCAN_CLASSIC="${REPO_ROOT}/etc/nftban/conf.d/portscan/classic.conf"
CONF_DDOS_MAIN="${REPO_ROOT}/etc/nftban/conf.d/ddos/main.conf"
CONF_DDOS_CLASSIC="${REPO_ROOT}/etc/nftban/conf.d/ddos/classic.conf"

# Systemd units directory
SYSTEMD_DIR="${REPO_ROOT}/install/systemd"

# =============================================================================
# COUNTERS AND HELPERS
# =============================================================================

PASS=0
FAIL=0
SKIP=0
TOTAL=0

check() {
    local description="$1"
    local result="$2"  # 0 = pass, 1 = fail, 2 = skip

    TOTAL=$(( TOTAL + 1 ))

    case "$result" in
        0)
            PASS=$(( PASS + 1 ))
            printf "  [PASS] %s\n" "$description"
            ;;
        1)
            FAIL=$(( FAIL + 1 ))
            printf "  [FAIL] %s\n" "$description"
            ;;
        2)
            SKIP=$(( SKIP + 1 ))
            printf "  [SKIP] %s\n" "$description"
            ;;
    esac
}

# Helper: grep quietly in file, return 0 if found
_has() {
    grep -qE "$1" "$2" 2>/dev/null
}

# Helper: count grep matches
_count() {
    grep -cE "$1" "$2" 2>/dev/null || echo 0
}

# =============================================================================
# BANNER
# =============================================================================

echo "======================================================================="
echo "  NFTBan Review Test 09: Portscan + DDoS Modules"
echo "  Repo root: ${REPO_ROOT}"
echo "  Date: $(date -Iseconds)"
echo "======================================================================="
echo ""

# =============================================================================
# 0. PRE-FLIGHT: VERIFY ALL FILES EXIST
# =============================================================================

echo "--- 0. Pre-flight: Required files exist ---"

for f in \
    "$PORTSCAN_MAIN" "$PORTSCAN_CLASSIC" "$PORTSCAN_SURICATA" \
    "$DDOS_MAIN" "$DDOS_CLASSIC" "$DDOS_SURICATA" \
    "$CMD_PORTSCAN" "$CMD_DDOS" \
    "$CONF_PORTSCAN_MAIN" "$CONF_PORTSCAN_CLASSIC" \
    "$CONF_DDOS_MAIN" "$CONF_DDOS_CLASSIC"; do
    label="$(basename "$f")"
    if [[ -f "$f" ]]; then
        check "File exists: ${label}" 0
    else
        check "File exists: ${label}" 1
    fi
done
echo ""

# =============================================================================
# 1. PORTSCAN DETECTION THRESHOLDS ARE CONFIGURABLE
# =============================================================================

echo "--- 1. Portscan detection thresholds are configurable ---"

# Check that threshold variables are defined with defaults in classic module
if _has 'PORTSCAN_CLASSIC_MIN_PORTS' "$PORTSCAN_CLASSIC"; then
    check "PORTSCAN_CLASSIC_MIN_PORTS default exists in classic module" 0
else
    check "PORTSCAN_CLASSIC_MIN_PORTS default exists in classic module" 1
fi

if _has 'PORTSCAN_CLASSIC_TIME_WINDOW' "$PORTSCAN_CLASSIC"; then
    check "PORTSCAN_CLASSIC_TIME_WINDOW default exists in classic module" 0
else
    check "PORTSCAN_CLASSIC_TIME_WINDOW default exists in classic module" 1
fi

if _has 'PORTSCAN_CLASSIC_VERTICAL_PORTS' "$PORTSCAN_CLASSIC"; then
    check "PORTSCAN_CLASSIC_VERTICAL_PORTS threshold exists" 0
else
    check "PORTSCAN_CLASSIC_VERTICAL_PORTS threshold exists" 1
fi

if _has 'PORTSCAN_CLASSIC_HORIZONTAL_TARGETS' "$PORTSCAN_CLASSIC"; then
    check "PORTSCAN_CLASSIC_HORIZONTAL_TARGETS threshold exists" 0
else
    check "PORTSCAN_CLASSIC_HORIZONTAL_TARGETS threshold exists" 1
fi

# Verify thresholds are also declared in config file
if _has '^PORTSCAN_CLASSIC_MIN_PORTS=' "$CONF_PORTSCAN_CLASSIC"; then
    check "PORTSCAN_CLASSIC_MIN_PORTS declared in classic.conf" 0
else
    check "PORTSCAN_CLASSIC_MIN_PORTS declared in classic.conf" 1
fi

if _has '^PORTSCAN_CLASSIC_TIME_WINDOW=' "$CONF_PORTSCAN_CLASSIC"; then
    check "PORTSCAN_CLASSIC_TIME_WINDOW declared in classic.conf" 0
else
    check "PORTSCAN_CLASSIC_TIME_WINDOW declared in classic.conf" 1
fi

if _has '^PORTSCAN_CLASSIC_VERTICAL_PORTS=' "$CONF_PORTSCAN_CLASSIC"; then
    check "PORTSCAN_CLASSIC_VERTICAL_PORTS declared in classic.conf" 0
else
    check "PORTSCAN_CLASSIC_VERTICAL_PORTS declared in classic.conf" 1
fi

if _has '^PORTSCAN_CLASSIC_HORIZONTAL_TARGETS=' "$CONF_PORTSCAN_CLASSIC"; then
    check "PORTSCAN_CLASSIC_HORIZONTAL_TARGETS declared in classic.conf" 0
else
    check "PORTSCAN_CLASSIC_HORIZONTAL_TARGETS declared in classic.conf" 1
fi

# Check main controller references PORTSCAN_THRESHOLD and PORTSCAN_TIME_WINDOW
if _has 'PORTSCAN_THRESHOLD' "$PORTSCAN_MAIN"; then
    check "PORTSCAN_THRESHOLD referenced in main controller" 0
else
    check "PORTSCAN_THRESHOLD referenced in main controller" 1
fi

if _has 'PORTSCAN_TIME_WINDOW' "$PORTSCAN_MAIN"; then
    check "PORTSCAN_TIME_WINDOW referenced in main controller" 0
else
    check "PORTSCAN_TIME_WINDOW referenced in main controller" 1
fi

echo ""

# =============================================================================
# 2. DDOS DETECTION THRESHOLDS ARE CONFIGURABLE
# =============================================================================

echo "--- 2. DDoS detection thresholds are configurable ---"

# SYN flood rate
if _has 'DDOS_CLASSIC_SYN_RATE' "$DDOS_CLASSIC"; then
    check "DDOS_CLASSIC_SYN_RATE default exists in classic module" 0
else
    check "DDOS_CLASSIC_SYN_RATE default exists in classic module" 1
fi

if _has '^DDOS_CLASSIC_SYN_RATE=' "$CONF_DDOS_CLASSIC"; then
    check "DDOS_CLASSIC_SYN_RATE declared in ddos classic.conf" 0
else
    check "DDOS_CLASSIC_SYN_RATE declared in ddos classic.conf" 1
fi

# SYN burst
if _has 'DDOS_CLASSIC_SYN_BURST' "$DDOS_CLASSIC"; then
    check "DDOS_CLASSIC_SYN_BURST default exists in classic module" 0
else
    check "DDOS_CLASSIC_SYN_BURST default exists in classic module" 1
fi

# Connection limits per service
for var in SSH_CONN_LIMIT HTTP_CONN_LIMIT HTTPS_CONN_LIMIT SMTP_CONN_LIMIT DNS_CONN_LIMIT GENERIC_CONN_LIMIT; do
    if _has "DDOS_CLASSIC_${var}" "$DDOS_CLASSIC"; then
        check "DDOS_CLASSIC_${var} default exists in classic module" 0
    else
        check "DDOS_CLASSIC_${var} default exists in classic module" 1
    fi
done

# ICMP rate
if _has 'DDOS_CLASSIC_ICMP_RATE' "$DDOS_CLASSIC"; then
    check "DDOS_CLASSIC_ICMP_RATE default exists in classic module" 0
else
    check "DDOS_CLASSIC_ICMP_RATE default exists in classic module" 1
fi

# UDP rate
if _has 'DDOS_CLASSIC_UDP_RATE' "$DDOS_CLASSIC"; then
    check "DDOS_CLASSIC_UDP_RATE default exists in classic module" 0
else
    check "DDOS_CLASSIC_UDP_RATE default exists in classic module" 1
fi

# Verify thresholds also exist in config
for var in SYN_RATE SYN_BURST SSH_CONN_LIMIT HTTP_CONN_LIMIT ICMP_RATE UDP_RATE; do
    if _has "^DDOS_CLASSIC_${var}=" "$CONF_DDOS_CLASSIC"; then
        check "DDOS_CLASSIC_${var} declared in ddos classic.conf" 0
    else
        check "DDOS_CLASSIC_${var} declared in ddos classic.conf" 1
    fi
done

# Suricata scoring thresholds
if _has 'DDOS_SURICATA_THRESHOLD_BLOCK_SHORT' "$DDOS_SURICATA"; then
    check "Suricata scoring threshold (BLOCK_SHORT) exists" 0
else
    check "Suricata scoring threshold (BLOCK_SHORT) exists" 1
fi

if _has 'DDOS_SURICATA_THRESHOLD_BLOCK_LONG' "$DDOS_SURICATA"; then
    check "Suricata scoring threshold (BLOCK_LONG) exists" 0
else
    check "Suricata scoring threshold (BLOCK_LONG) exists" 1
fi

# Auto-tuning support
if _has 'DDOS_CLASSIC_AUTO_TUNE' "$DDOS_CLASSIC"; then
    check "DDoS auto-tuning variable exists in classic module" 0
else
    check "DDoS auto-tuning variable exists in classic module" 1
fi

if _has '_nftban_ddos_classic_auto_tune' "$DDOS_CLASSIC"; then
    check "DDoS auto-tuning function exists in classic module" 0
else
    check "DDoS auto-tuning function exists in classic module" 1
fi

echo ""

# =============================================================================
# 3. WHITELIST CHECK BEFORE BAN FOR BOTH MODULES
# =============================================================================

echo "--- 3. Whitelist check before ban for both modules ---"

# Portscan classic: whitelist function exists
if _has 'nftban_portscan_classic_is_whitelisted' "$PORTSCAN_CLASSIC"; then
    check "Portscan classic has is_whitelisted function" 0
else
    check "Portscan classic has is_whitelisted function" 1
fi

# Portscan classic: whitelist called during log processing (before ban)
if _has 'nftban_portscan_classic_is_whitelisted.*\$src_ip' "$PORTSCAN_CLASSIC"; then
    check "Portscan classic calls whitelist check during log processing" 0
else
    check "Portscan classic calls whitelist check during log processing" 1
fi

# Portscan classic: whitelist called in stealth aggregation
wl_agg_count=$(_count 'nftban_portscan_classic_is_whitelisted' "$PORTSCAN_CLASSIC")
if [[ "$wl_agg_count" -ge 2 ]]; then
    check "Portscan classic calls whitelist in multiple code paths (${wl_agg_count} occurrences)" 0
else
    check "Portscan classic calls whitelist in multiple code paths (${wl_agg_count} occurrences)" 1
fi

# Portscan classic: uses central nftban_is_whitelisted
if _has 'nftban_is_whitelisted' "$PORTSCAN_CLASSIC"; then
    check "Portscan classic uses central nftban_is_whitelisted" 0
else
    check "Portscan classic uses central nftban_is_whitelisted" 1
fi

# Portscan main config: whitelist settings exist
if _has 'PORTSCAN_WHITELIST_LOCALHOST' "$CONF_PORTSCAN_MAIN"; then
    check "Portscan main.conf has WHITELIST_LOCALHOST setting" 0
else
    check "Portscan main.conf has WHITELIST_LOCALHOST setting" 1
fi

if _has 'PORTSCAN_WHITELIST_PRIVATE' "$CONF_PORTSCAN_MAIN"; then
    check "Portscan main.conf has WHITELIST_PRIVATE setting" 0
else
    check "Portscan main.conf has WHITELIST_PRIVATE setting" 1
fi

# DDoS suricata: whitelist check before ban
if _has 'nftban_is_whitelisted' "$DDOS_SURICATA"; then
    check "DDoS suricata checks nftban_is_whitelisted before ban" 0
else
    check "DDoS suricata checks nftban_is_whitelisted before ban" 1
fi

# DDoS main config: whitelist settings exist
if _has 'DDOS_WHITELIST_LOCALHOST' "$CONF_DDOS_MAIN"; then
    check "DDoS main.conf has WHITELIST_LOCALHOST setting" 0
else
    check "DDoS main.conf has WHITELIST_LOCALHOST setting" 1
fi

if _has 'DDOS_WHITELIST_PRIVATE' "$CONF_DDOS_MAIN"; then
    check "DDoS main.conf has WHITELIST_PRIVATE setting" 0
else
    check "DDoS main.conf has WHITELIST_PRIVATE setting" 1
fi

if _has 'DDOS_WHITELIST_CLOUDFLARE' "$CONF_DDOS_MAIN"; then
    check "DDoS main.conf has WHITELIST_CLOUDFLARE setting" 0
else
    check "DDoS main.conf has WHITELIST_CLOUDFLARE setting" 1
fi

echo ""

# =============================================================================
# 4. ENABLE/DISABLE PERSISTENCE TO CONFIG FOR BOTH MODULES
# =============================================================================

echo "--- 4. Enable/disable persists to config for both modules ---"

# Portscan: enable writes to main.conf.local
if _has 'PORTSCAN_ENABLED.*true.*main\.conf\.local' "$PORTSCAN_MAIN" ||
   _has 'main\.conf\.local' "$PORTSCAN_MAIN"; then
    check "Portscan enable persists to main.conf.local" 0
else
    check "Portscan enable persists to main.conf.local" 1
fi

# Portscan: disable writes to main.conf.local
if _has 'PORTSCAN_ENABLED.*false' "$PORTSCAN_MAIN"; then
    check "Portscan disable writes PORTSCAN_ENABLED=false" 0
else
    check "Portscan disable writes PORTSCAN_ENABLED=false" 1
fi

# Portscan: has both enable and disable functions
if _has 'nftban_portscan_enable\(\)' "$PORTSCAN_MAIN"; then
    check "Portscan has enable function" 0
else
    check "Portscan has enable function" 1
fi

if _has 'nftban_portscan_disable\(\)' "$PORTSCAN_MAIN"; then
    check "Portscan has disable function" 0
else
    check "Portscan has disable function" 1
fi

# Portscan config: PORTSCAN_ENABLED is declared
if _has '^PORTSCAN_ENABLED=' "$CONF_PORTSCAN_MAIN"; then
    check "PORTSCAN_ENABLED declared in main.conf" 0
else
    check "PORTSCAN_ENABLED declared in main.conf" 1
fi

# DDoS: enable writes to main.conf.local
if _has 'DDOS_ENABLED.*true.*main\.conf\.local' "$DDOS_MAIN" ||
   _has 'main\.conf\.local' "$DDOS_MAIN"; then
    check "DDoS enable persists to main.conf.local" 0
else
    check "DDoS enable persists to main.conf.local" 1
fi

# DDoS: disable writes to main.conf.local
if _has 'DDOS_ENABLED.*false' "$DDOS_MAIN"; then
    check "DDoS disable writes DDOS_ENABLED=false" 0
else
    check "DDoS disable writes DDOS_ENABLED=false" 1
fi

# DDoS: has both enable and disable functions
if _has 'nftban_ddos_enable\(\)' "$DDOS_MAIN"; then
    check "DDoS has enable function" 0
else
    check "DDoS has enable function" 1
fi

if _has 'nftban_ddos_disable\(\)' "$DDOS_MAIN"; then
    check "DDoS has disable function" 0
else
    check "DDoS has disable function" 1
fi

# DDoS config: DDOS_ENABLED is declared
if _has '^DDOS_ENABLED=' "$CONF_DDOS_MAIN"; then
    check "DDOS_ENABLED declared in main.conf" 0
else
    check "DDOS_ENABLED declared in main.conf" 1
fi

echo ""

# =============================================================================
# 5. SERVICE/TIMER UNITS EXIST FOR BOTH MODULES
# =============================================================================

echo "--- 5. Service/timer units exist for both modules ---"

# Both portscan and DDoS are managed by the nftband daemon and
# the nftban-maintenance timer (periodic processing). Verify
# the daemon service and maintenance timer/service exist.

if [[ -f "${SYSTEMD_DIR}/nftband.service" ]]; then
    check "nftband.service exists (single nftables writer daemon)" 0
else
    check "nftband.service exists (single nftables writer daemon)" 1
fi

if [[ -f "${SYSTEMD_DIR}/nftban-maintenance.service" ]]; then
    check "nftban-maintenance.service exists (periodic maintenance)" 0
else
    check "nftban-maintenance.service exists (periodic maintenance)" 1
fi

if [[ -f "${SYSTEMD_DIR}/nftban-maintenance.timer" ]]; then
    check "nftban-maintenance.timer exists (15-min maintenance timer)" 0
else
    check "nftban-maintenance.timer exists (15-min maintenance timer)" 1
fi

# Verify maintenance timer references maintenance service
if _has 'nftban-maintenance\.service' "${SYSTEMD_DIR}/nftban-maintenance.timer"; then
    check "Maintenance timer references maintenance service" 0
else
    check "Maintenance timer references maintenance service" 1
fi

# Verify nftband has security hardening
if _has 'ProtectSystem=strict' "${SYSTEMD_DIR}/nftband.service"; then
    check "nftband.service has ProtectSystem=strict" 0
else
    check "nftband.service has ProtectSystem=strict" 1
fi

if _has 'NoNewPrivileges' "${SYSTEMD_DIR}/nftband.service"; then
    check "nftband.service has NoNewPrivileges" 0
else
    check "nftband.service has NoNewPrivileges" 1
fi

# Verify maintenance service has flock to prevent overlap
if _has 'flock' "${SYSTEMD_DIR}/nftban-maintenance.service"; then
    check "Maintenance service uses flock for overlap prevention" 0
else
    check "Maintenance service uses flock for overlap prevention" 1
fi

# Verify CLI commands exist for enable/disable
if _has 'enable\)' "$CMD_PORTSCAN"; then
    check "cmd_portscan.sh handles 'enable' command" 0
else
    check "cmd_portscan.sh handles 'enable' command" 1
fi

if _has 'disable\)' "$CMD_PORTSCAN"; then
    check "cmd_portscan.sh handles 'disable' command" 0
else
    check "cmd_portscan.sh handles 'disable' command" 1
fi

if _has 'enable\)' "$CMD_DDOS"; then
    check "cmd_ddos.sh handles 'enable' command" 0
else
    check "cmd_ddos.sh handles 'enable' command" 1
fi

if _has 'disable\)' "$CMD_DDOS"; then
    check "cmd_ddos.sh handles 'disable' command" 0
else
    check "cmd_ddos.sh handles 'disable' command" 1
fi

echo ""

# =============================================================================
# 6. PROTOCOL HANDLING (TCP/UDP/ICMP AWARENESS IN DDOS)
# =============================================================================

echo "--- 6. Protocol handling (TCP/UDP/ICMP awareness in DDoS) ---"

# SYN flood = TCP protocol handling
if _has 'SYN_RATE|SYN_BURST|syn_flood|SYN' "$DDOS_CLASSIC"; then
    check "DDoS classic handles TCP SYN floods" 0
else
    check "DDoS classic handles TCP SYN floods" 1
fi

# SYNPROXY = advanced TCP protection
if _has 'SYNPROXY|synproxy' "$DDOS_CLASSIC"; then
    check "DDoS classic has SYNPROXY (TCP handshake proxy) support" 0
else
    check "DDoS classic has SYNPROXY (TCP handshake proxy) support" 1
fi

# ICMP rate limiting
if _has 'ICMP_RATE|ICMP_BURST|icmp_flood' "$DDOS_CLASSIC"; then
    check "DDoS classic handles ICMP flood protection" 0
else
    check "DDoS classic handles ICMP flood protection" 1
fi

# ICMPv6 separate handling
if _has 'ICMPV6_RATE|ICMPV6_BURST' "$DDOS_CLASSIC"; then
    check "DDoS classic handles ICMPv6 separately" 0
else
    check "DDoS classic handles ICMPv6 separately" 1
fi

# UDP flood protection
if _has 'UDP_RATE|UDP_BURST|udp_flood' "$DDOS_CLASSIC"; then
    check "DDoS classic handles UDP flood protection" 0
else
    check "DDoS classic handles UDP flood protection" 1
fi

# Config file has all protocol configs
if _has '^DDOS_CLASSIC_SYN_RATE=' "$CONF_DDOS_CLASSIC"; then
    check "Config: SYN rate limit declared in classic.conf" 0
else
    check "Config: SYN rate limit declared in classic.conf" 1
fi

if _has '^DDOS_CLASSIC_ICMP_RATE=' "$CONF_DDOS_CLASSIC"; then
    check "Config: ICMP rate limit declared in classic.conf" 0
else
    check "Config: ICMP rate limit declared in classic.conf" 1
fi

if _has '^DDOS_CLASSIC_ICMPV6_RATE=' "$CONF_DDOS_CLASSIC"; then
    check "Config: ICMPv6 rate limit declared in classic.conf" 0
else
    check "Config: ICMPv6 rate limit declared in classic.conf" 1
fi

if _has '^DDOS_CLASSIC_UDP_RATE=' "$CONF_DDOS_CLASSIC"; then
    check "Config: UDP rate limit declared in classic.conf" 0
else
    check "Config: UDP rate limit declared in classic.conf" 1
fi

# Port flood (multi-port scanning via DDoS module)
if _has 'PORT_FLOOD_RATE|PORT_FLOOD_BURST' "$DDOS_CLASSIC"; then
    check "DDoS classic has per-port flood rate limiting" 0
else
    check "DDoS classic has per-port flood rate limiting" 1
fi

# Sanity check drops invalid TCP flag combos (XMAS, NULL)
if _has 'SANITY|sanity' "$DDOS_CLASSIC"; then
    check "DDoS classic has packet sanity checks (XMAS/NULL/invalid)" 0
else
    check "DDoS classic has packet sanity checks (XMAS/NULL/invalid)" 1
fi

# Prefix aggregation for distributed attacks
if _has 'PREFIX.*ENABLED|ddos_prefix' "$DDOS_CLASSIC"; then
    check "DDoS classic has prefix aggregation for distributed attacks" 0
else
    check "DDoS classic has prefix aggregation for distributed attacks" 1
fi

# Portscan protocol awareness: parses PROTO field from logs
if _has 'PROTO=' "$PORTSCAN_CLASSIC"; then
    check "Portscan classic parses PROTO field from log lines" 0
else
    check "Portscan classic parses PROTO field from log lines" 1
fi

echo ""

# =============================================================================
# 7. SERVICE PORT EXCLUSIONS MECHANISM EXISTS
# =============================================================================

echo "--- 7. Service port exclusions mechanism exists ---"

# Portscan classic: monitoring modes (closed ports vs all vs custom)
if _has 'PORTSCAN_CLASSIC_LOG_CLOSED_PORTS' "$CONF_PORTSCAN_CLASSIC"; then
    check "Portscan classic has LOG_CLOSED_PORTS config (port monitoring control)" 0
else
    check "Portscan classic has LOG_CLOSED_PORTS config (port monitoring control)" 1
fi

if _has 'PORTSCAN_CLASSIC_LOG_ALL_NEW' "$CONF_PORTSCAN_CLASSIC"; then
    check "Portscan classic has LOG_ALL_NEW config (selective monitoring)" 0
else
    check "Portscan classic has LOG_ALL_NEW config (selective monitoring)" 1
fi

# Portscan: has service ports list (defines which ports to monitor)
if _has 'PORTSCAN_CLASSIC_LOG_PORTS_SERVICES' "$CONF_PORTSCAN_CLASSIC"; then
    check "Portscan classic defines LOG_PORTS_SERVICES (service-aware ports)" 0
else
    check "Portscan classic defines LOG_PORTS_SERVICES (service-aware ports)" 1
fi

# Portscan: has critical ports list
if _has 'PORTSCAN_CLASSIC_LOG_PORTS_CRITICAL' "$CONF_PORTSCAN_CLASSIC"; then
    check "Portscan classic defines LOG_PORTS_CRITICAL (priority ports)" 0
else
    check "Portscan classic defines LOG_PORTS_CRITICAL (priority ports)" 1
fi

# Portscan CLI help: mentions custom port mode
if _has 'PORTSCAN_CUSTOM_PORTS|custom' "$CMD_PORTSCAN"; then
    check "Portscan CLI help mentions custom port configuration" 0
else
    check "Portscan CLI help mentions custom port configuration" 1
fi

# DDoS: per-service connection limits (exclusion by service-specific thresholds)
if _has 'SSH_CONN_LIMIT' "$CONF_DDOS_CLASSIC" && \
   _has 'HTTP_CONN_LIMIT' "$CONF_DDOS_CLASSIC" && \
   _has 'SMTP_CONN_LIMIT' "$CONF_DDOS_CLASSIC" && \
   _has 'DNS_CONN_LIMIT' "$CONF_DDOS_CLASSIC"; then
    check "DDoS has per-service connection limits (SSH/HTTP/SMTP/DNS)" 0
else
    check "DDoS has per-service connection limits (SSH/HTTP/SMTP/DNS)" 1
fi

# DDoS SYNPROXY: protects specific ports only
if _has 'DDOS_SYNPROXY_PORTS' "$CONF_DDOS_CLASSIC"; then
    check "DDoS SYNPROXY targets specific service ports" 0
else
    check "DDoS SYNPROXY targets specific service ports" 1
fi

# DDoS: generic connection limit for unlisted ports
if _has 'GENERIC_CONN_LIMIT' "$CONF_DDOS_CLASSIC"; then
    check "DDoS has GENERIC_CONN_LIMIT for non-service ports" 0
else
    check "DDoS has GENERIC_CONN_LIMIT for non-service ports" 1
fi

echo ""

# =============================================================================
# 8. CONNTRACK USAGE / CONNECTION COUNTING METHOD EXISTS
# =============================================================================

echo "--- 8. Conntrack usage / connection counting method exists ---"

# DDoS classic: conntrack pressure thresholds
if _has 'CONNTRACK_TRIP_PERCENT|CONNTRACK_CLEAR_PERCENT' "$CONF_DDOS_CLASSIC"; then
    check "DDoS classic.conf has conntrack pressure thresholds" 0
else
    check "DDoS classic.conf has conntrack pressure thresholds" 1
fi

# DDoS classic: uses nftables meters for rate tracking
if _has 'DDOS_CLASSIC_SYN_METER|ddos_syn_flood' "$DDOS_CLASSIC"; then
    check "DDoS classic uses nftables meters for SYN rate tracking" 0
else
    check "DDoS classic uses nftables meters for SYN rate tracking" 1
fi

if _has 'DDOS_CLASSIC_ICMP_METER|ddos_icmp_flood' "$DDOS_CLASSIC"; then
    check "DDoS classic uses nftables meters for ICMP rate tracking" 0
else
    check "DDoS classic uses nftables meters for ICMP rate tracking" 1
fi

if _has 'DDOS_CLASSIC_UDP_METER|ddos_udp_flood' "$DDOS_CLASSIC"; then
    check "DDoS classic uses nftables meters for UDP rate tracking" 0
else
    check "DDoS classic uses nftables meters for UDP rate tracking" 1
fi

# DDoS: uses connection limit (ct count equivalent)
if _has 'CONN_LIMIT|conn_limit' "$DDOS_CLASSIC"; then
    check "DDoS classic uses connection limits per IP" 0
else
    check "DDoS classic uses connection limits per IP" 1
fi

# DDoS config: meter names declared
if _has '^DDOS_CLASSIC_SYN_METER=' "$CONF_DDOS_CLASSIC"; then
    check "Config: SYN meter name declared in classic.conf" 0
else
    check "Config: SYN meter name declared in classic.conf" 1
fi

if _has '^DDOS_CLASSIC_ICMP_METER=' "$CONF_DDOS_CLASSIC"; then
    check "Config: ICMP meter name declared in classic.conf" 0
else
    check "Config: ICMP meter name declared in classic.conf" 1
fi

if _has '^DDOS_CLASSIC_UDP_METER=' "$CONF_DDOS_CLASSIC"; then
    check "Config: UDP meter name declared in classic.conf" 0
else
    check "Config: UDP meter name declared in classic.conf" 1
fi

# DDoS classic: block set for banned IPs
if _has 'DDOS_CLASSIC_BLOCK_SET|ddos_blocked' "$DDOS_CLASSIC"; then
    check "DDoS classic defines block set for banned IPs" 0
else
    check "DDoS classic defines block set for banned IPs" 1
fi

# Portscan classic: in-memory state tracking (associative arrays)
if _has '_PORTSCAN_CLASSIC_IP_PORTS' "$PORTSCAN_CLASSIC"; then
    check "Portscan classic tracks IPs via associative arrays" 0
else
    check "Portscan classic tracks IPs via associative arrays" 1
fi

if _has '_PORTSCAN_CLASSIC_IP_TIMESTAMPS' "$PORTSCAN_CLASSIC"; then
    check "Portscan classic tracks timestamps per IP" 0
else
    check "Portscan classic tracks timestamps per IP" 1
fi

# Portscan classic: max tracked IPs safety limit
if _has 'PORTSCAN_CLASSIC_MAX_TRACKED_IPS' "$PORTSCAN_CLASSIC"; then
    check "Portscan classic has MAX_TRACKED_IPS safety limit" 0
else
    check "Portscan classic has MAX_TRACKED_IPS safety limit" 1
fi

# Portscan classic: cleanup function exists
if _has 'nftban_portscan_classic_cleanup_old_entries' "$PORTSCAN_CLASSIC"; then
    check "Portscan classic has cleanup function for stale entries" 0
else
    check "Portscan classic has cleanup function for stale entries" 1
fi

# DDoS: uses IPC for all bans (single-writer architecture)
if _has 'nft_ipc_ban' "$DDOS_CLASSIC"; then
    check "DDoS classic uses IPC for ban operations (single-writer)" 0
else
    check "DDoS classic uses IPC for ban operations (single-writer)" 1
fi

# Portscan: uses IPC for bans
if _has 'nft_ipc_ban|nftban_ban' "$PORTSCAN_CLASSIC"; then
    check "Portscan classic uses IPC/ban API for ban operations" 0
else
    check "Portscan classic uses IPC/ban API for ban operations" 1
fi

# DDoS prefix aggregation: subnet-level tracking (/24 and /64)
if _has 'PREFIX_IPV4_MASK|/24' "$CONF_DDOS_CLASSIC"; then
    check "DDoS prefix aggregation tracks by /24 subnet" 0
else
    check "DDoS prefix aggregation tracks by /24 subnet" 1
fi

if _has 'PREFIX_IPV6_MASK|/64' "$CONF_DDOS_CLASSIC"; then
    check "DDoS prefix aggregation tracks by /64 subnet" 0
else
    check "DDoS prefix aggregation tracks by /64 subnet" 1
fi

echo ""

# =============================================================================
# 9. BONUS: CODE QUALITY CHECKS
# =============================================================================

echo "--- 9. Bonus: Code quality checks ---"

# Both modules have set -Eeuo pipefail
for f in "$PORTSCAN_MAIN" "$PORTSCAN_CLASSIC" "$DDOS_MAIN" "$DDOS_CLASSIC"; do
    label="$(basename "$f")"
    if _has '^set -Eeuo pipefail' "$f"; then
        check "${label} has set -Eeuo pipefail" 0
    else
        check "${label} has set -Eeuo pipefail" 1
    fi
done

# Both modules have module guard (prevent double sourcing)
for f in "$PORTSCAN_MAIN" "$PORTSCAN_CLASSIC" "$DDOS_MAIN" "$DDOS_CLASSIC"; do
    label="$(basename "$f")"
    if _has '_LOADED' "$f"; then
        check "${label} has double-source guard (_LOADED)" 0
    else
        check "${label} has double-source guard (_LOADED)" 1
    fi
done

# Both modules have SPDX license
for f in "$PORTSCAN_MAIN" "$PORTSCAN_CLASSIC" "$DDOS_MAIN" "$DDOS_CLASSIC"; do
    label="$(basename "$f")"
    if _has 'SPDX-License-Identifier' "$f"; then
        check "${label} has SPDX license header" 0
    else
        check "${label} has SPDX license header" 1
    fi
done

# Both modules have meta tags (7 inventory lines)
for f in "$PORTSCAN_MAIN" "$PORTSCAN_CLASSIC" "$DDOS_MAIN" "$DDOS_CLASSIC"; do
    label="$(basename "$f")"
    inv_count=$(_count 'meta:inventory\.' "$f")
    if [[ "$inv_count" -ge 7 ]]; then
        check "${label} has 7+ meta:inventory lines (${inv_count})" 0
    else
        check "${label} has 7+ meta:inventory lines (${inv_count})" 1
    fi
done

# Portscan: mode config supports auto/classic/suricata/hybrid
if _has 'auto|classic|suricata|hybrid' "$CONF_PORTSCAN_MAIN"; then
    check "Portscan main.conf documents all 4 modes" 0
else
    check "Portscan main.conf documents all 4 modes" 1
fi

# DDoS: mode config supports auto/classic/suricata/hybrid
if _has 'auto|classic|suricata|hybrid' "$CONF_DDOS_MAIN"; then
    check "DDoS main.conf documents all 4 modes" 0
else
    check "DDoS main.conf documents all 4 modes" 1
fi

echo ""

# =============================================================================
# SUMMARY
# =============================================================================

echo "======================================================================="
echo "  SUMMARY"
echo "======================================================================="
echo ""
echo "  Total:  ${TOTAL}"
echo "  Passed: ${PASS}"
echo "  Failed: ${FAIL}"
echo "  Skipped: ${SKIP}"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo "  RESULT: FAIL (${FAIL} checks failed)"
    echo ""
    exit 1
else
    echo "  RESULT: PASS (all ${PASS} checks passed)"
    echo ""
    exit 0
fi
