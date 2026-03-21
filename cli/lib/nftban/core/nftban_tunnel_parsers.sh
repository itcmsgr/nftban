#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.30.0 - Tunnel Suspicion DNS Log Parsers
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Parse DNS query logs from BIND, Unbound, dnsmasq, systemd-resolved
#
# meta:name="nftban_tunnel_parsers"
# meta:type="lib"
# meta:header="Tunnel DNS Log Parsers"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="DNS log parsers for tunnel suspicion module"
# meta:depends="nftban_tunnel.sh"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/tunnel/main.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2026-03-21"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_TUNNEL_PARSERS_LOADED:-}" ]] && return 0
_NFTBAN_TUNNEL_PARSERS_LOADED=1

# =============================================================================
# DNS SOURCE AUTO-DETECTION
# =============================================================================

nftban_tunnel_detect_dns_source() {
    # Auto-detect which DNS resolver is running and where its logs are.
    # Sets global: TUNNEL_DNS_TYPE, TUNNEL_DNS_LOG_PATH
    # Returns: 0=found, 1=not found

    TUNNEL_DNS_TYPE=""
    TUNNEL_DNS_LOG_PATH=""

    # Check user override first
    local source="${NFTBAN_TUNNEL_DNS_SOURCE:-auto}"
    if [[ "$source" != "auto" ]]; then
        TUNNEL_DNS_TYPE="$source"
        case "$source" in
            bind)
                TUNNEL_DNS_LOG_PATH="${NFTBAN_TUNNEL_BIND_LOG:-}"
                [[ -z "$TUNNEL_DNS_LOG_PATH" ]] && TUNNEL_DNS_LOG_PATH=$(_tunnel_find_bind_log)
                ;;
            unbound)
                TUNNEL_DNS_LOG_PATH="${NFTBAN_TUNNEL_UNBOUND_LOG:-}"
                [[ -z "$TUNNEL_DNS_LOG_PATH" ]] && TUNNEL_DNS_LOG_PATH=$(_tunnel_find_unbound_log)
                ;;
            dnsmasq)
                TUNNEL_DNS_LOG_PATH="${NFTBAN_TUNNEL_DNSMASQ_LOG:-}"
                [[ -z "$TUNNEL_DNS_LOG_PATH" ]] && TUNNEL_DNS_LOG_PATH=$(_tunnel_find_dnsmasq_log)
                ;;
            resolved)
                TUNNEL_DNS_LOG_PATH="journalctl"
                ;;
        esac
        [[ -n "$TUNNEL_DNS_LOG_PATH" ]] && return 0
        return 1
    fi

    # Auto-detect: try each resolver in order
    # 1. BIND (named)
    if command -v named &>/dev/null || systemctl is-active named.service &>/dev/null 2>&1 || systemctl is-active bind9.service &>/dev/null 2>&1; then
        TUNNEL_DNS_TYPE="bind"
        TUNNEL_DNS_LOG_PATH="${NFTBAN_TUNNEL_BIND_LOG:-}"
        [[ -z "$TUNNEL_DNS_LOG_PATH" ]] && TUNNEL_DNS_LOG_PATH=$(_tunnel_find_bind_log)
        [[ -n "$TUNNEL_DNS_LOG_PATH" ]] && return 0
    fi

    # 2. Unbound
    if command -v unbound &>/dev/null || systemctl is-active unbound.service &>/dev/null 2>&1; then
        TUNNEL_DNS_TYPE="unbound"
        TUNNEL_DNS_LOG_PATH="${NFTBAN_TUNNEL_UNBOUND_LOG:-}"
        [[ -z "$TUNNEL_DNS_LOG_PATH" ]] && TUNNEL_DNS_LOG_PATH=$(_tunnel_find_unbound_log)
        [[ -n "$TUNNEL_DNS_LOG_PATH" ]] && return 0
    fi

    # 3. dnsmasq
    if command -v dnsmasq &>/dev/null || systemctl is-active dnsmasq.service &>/dev/null 2>&1; then
        TUNNEL_DNS_TYPE="dnsmasq"
        TUNNEL_DNS_LOG_PATH="${NFTBAN_TUNNEL_DNSMASQ_LOG:-}"
        [[ -z "$TUNNEL_DNS_LOG_PATH" ]] && TUNNEL_DNS_LOG_PATH=$(_tunnel_find_dnsmasq_log)
        [[ -n "$TUNNEL_DNS_LOG_PATH" ]] && return 0
    fi

    # 4. systemd-resolved
    if systemctl is-active systemd-resolved.service &>/dev/null 2>&1; then
        TUNNEL_DNS_TYPE="resolved"
        TUNNEL_DNS_LOG_PATH="journalctl"
        return 0
    fi

    return 1
}

_tunnel_find_bind_log() {
    # Find BIND query log file
    local candidates=(
        "/var/log/named/queries.log"
        "/var/log/named/query.log"
        "/var/log/bind/query.log"
        "/var/log/queries.log"
        "/var/named/data/queries.log"
    )
    for f in "${candidates[@]}"; do
        if [[ -f "$f" && -r "$f" ]]; then
            echo "$f"
            return 0
        fi
    done
    # Try to extract from named.conf
    local named_conf=""
    for cfg in /etc/named.conf /etc/bind/named.conf /etc/named/named.conf; do
        [[ -f "$cfg" ]] && named_conf="$cfg" && break
    done
    if [[ -n "$named_conf" ]]; then
        local log_file
        log_file=$(grep -A5 'channel.*queries' "$named_conf" 2>/dev/null | grep 'file' | head -1 | sed 's/.*file[[:space:]]*"\([^"]*\)".*/\1/' || true)
        if [[ -n "$log_file" && -f "$log_file" && -r "$log_file" ]]; then
            echo "$log_file"
            return 0
        fi
    fi
    echo ""
}

_tunnel_find_unbound_log() {
    # Find Unbound log file
    local candidates=(
        "/var/log/unbound/unbound.log"
        "/var/log/unbound.log"
    )
    for f in "${candidates[@]}"; do
        if [[ -f "$f" && -r "$f" ]]; then
            echo "$f"
            return 0
        fi
    done
    # Try to extract from unbound.conf
    local unbound_conf="/etc/unbound/unbound.conf"
    if [[ -f "$unbound_conf" ]]; then
        local log_file
        log_file=$(grep 'logfile:' "$unbound_conf" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"' || true)
        if [[ -n "$log_file" && -f "$log_file" && -r "$log_file" ]]; then
            echo "$log_file"
            return 0
        fi
    fi
    echo ""
}

_tunnel_find_dnsmasq_log() {
    # Find dnsmasq log — usually syslog
    local candidates=(
        "/var/log/dnsmasq.log"
        "/var/log/syslog"
        "/var/log/messages"
    )
    for f in "${candidates[@]}"; do
        if [[ -f "$f" && -r "$f" ]]; then
            echo "$f"
            return 0
        fi
    done
    echo ""
}

# =============================================================================
# LOG PARSERS
# =============================================================================
# Each parser outputs normalized records to stdout, one per line:
#   SOURCE_IP|QNAME|QTYPE|RCODE
#
# Where:
#   SOURCE_IP = client IP that made the query
#   QNAME    = fully qualified domain name queried
#   QTYPE    = query type (A, AAAA, TXT, MX, etc.)
#   RCODE    = response code (NOERROR, NXDOMAIN, SERVFAIL, etc.)

nftban_tunnel_parse_bind() {
    # Parse BIND 9 query log (querylog format)
    # Format: DD-Mon-YYYY HH:MM:SS.mmm queries: info: client @0xPTR IP#PORT (QNAME): query: QNAME CLASS QTYPE FLAGS (IP)
    # Newer: DD-Mon-YYYY HH:MM:SS.mmm client @0xPTR IP#PORT (QNAME): query: QNAME CLASS QTYPE +FLAGS (IP)
    local log_file="$1"
    local since_ts="${2:-0}"

    if [[ ! -f "$log_file" || ! -r "$log_file" ]]; then
        return 1
    fi

    # Parse recent queries (last scan interval)
    # Extract: client IP, qname, qtype
    # BIND query log is complex; use awk for reliable parsing
    awk -v since="$since_ts" '
    /query:/ {
        # Extract client IP (before #port)
        client_ip = ""
        qname = ""
        qtype = ""

        for (i = 1; i <= NF; i++) {
            if ($i == "client" || ($i ~ /@/ && $(i+1) ~ /#/)) {
                # Next field with # is IP#PORT
                for (j = i+1; j <= NF; j++) {
                    if ($j ~ /#[0-9]+/) {
                        split($j, parts, "#")
                        client_ip = parts[1]
                        # Remove @prefix if present
                        sub(/^@/, "", client_ip)
                        break
                    }
                }
            }
            if ($i == "query:") {
                qname = $(i+1)
                # Skip CLASS (IN)
                qtype = $(i+3)
                break
            }
        }

        if (client_ip != "" && qname != "") {
            # BIND query log does not include RCODE in the query line
            print client_ip "|" qname "|" qtype "|NOERROR"
        }
    }
    ' "$log_file"
}

nftban_tunnel_parse_unbound() {
    # Parse Unbound log
    # Format: [TIMESTAMP] unbound[PID:TID] info: IP QNAME QTYPE QCLASS
    # With verbosity 2+: also shows replies with RCODE
    local log_file="$1"
    local since_ts="${2:-0}"

    if [[ ! -f "$log_file" || ! -r "$log_file" ]]; then
        return 1
    fi

    awk '
    /info:/ && / [A-Z]+ IN$/ {
        # Query line: info: CLIENT_IP QNAME QTYPE CLASS
        for (i = 1; i <= NF; i++) {
            if ($i == "info:") {
                client_ip = $(i+1)
                qname = $(i+2)
                qtype = $(i+3)
                print client_ip "|" qname "|" qtype "|NOERROR"
                break
            }
        }
    }
    ' "$log_file"
}

nftban_tunnel_parse_dnsmasq() {
    # Parse dnsmasq log (syslog format)
    # Format: Mon DD HH:MM:SS hostname dnsmasq[PID]: query[QTYPE] QNAME from IP
    # Reply:  Mon DD HH:MM:SS hostname dnsmasq[PID]: reply QNAME is <CNAME|IP|NXDOMAIN>
    local log_file="$1"
    local since_ts="${2:-0}"

    if [[ ! -f "$log_file" || ! -r "$log_file" ]]; then
        return 1
    fi

    awk '
    /dnsmasq\[.*\]: query\[/ {
        # Extract: query[TYPE] QNAME from IP
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^query\[/) {
                qtype = $i
                sub(/^query\[/, "", qtype)
                sub(/\]$/, "", qtype)
                qname = $(i+1)
                # "from" should be $(i+2)
                if ($(i+2) == "from") {
                    client_ip = $(i+3)
                    print client_ip "|" qname "|" qtype "|NOERROR"
                }
                break
            }
        }
    }
    ' "$log_file"
}

nftban_tunnel_parse_resolved() {
    # Parse systemd-resolved logs from journalctl
    # Format varies; typically: "Received DNS query for QNAME QTYPE from IP"
    local since_ts="${1:-0}"
    local since_date

    if [[ "$since_ts" -gt 0 ]]; then
        since_date=$(date -d "@${since_ts}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "5 minutes ago")
    else
        since_date="5 minutes ago"
    fi

    journalctl -u systemd-resolved --since "$since_date" --no-pager -o cat 2>/dev/null | \
    awk '
    /[Qq]uery/ {
        # Best-effort parsing of resolved log entries
        # Format is not standardized — extract what we can
        for (i = 1; i <= NF; i++) {
            if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
                client_ip = $i
            }
        }
        # This parser is best-effort; resolved logging is limited
    }
    '
}

# =============================================================================
# UNIFIED PARSER INTERFACE
# =============================================================================

nftban_tunnel_parse_dns_logs() {
    # Parse DNS logs from the detected source.
    # Outputs normalized records to stdout.
    # Args: $1 = dns_type, $2 = log_path, $3 = since_timestamp
    local dns_type="$1"
    local log_path="$2"
    local since_ts="${3:-0}"

    case "$dns_type" in
        bind)
            nftban_tunnel_parse_bind "$log_path" "$since_ts"
            ;;
        unbound)
            nftban_tunnel_parse_unbound "$log_path" "$since_ts"
            ;;
        dnsmasq)
            nftban_tunnel_parse_dnsmasq "$log_path" "$since_ts"
            ;;
        resolved)
            nftban_tunnel_parse_resolved "$since_ts"
            ;;
        *)
            echo "ERROR: Unknown DNS source type: $dns_type" >&2
            return 1
            ;;
    esac
}

# Export functions
export -f nftban_tunnel_detect_dns_source
export -f nftban_tunnel_parse_dns_logs
export -f nftban_tunnel_parse_bind
export -f nftban_tunnel_parse_unbound
export -f nftban_tunnel_parse_dnsmasq
export -f nftban_tunnel_parse_resolved
