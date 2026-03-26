#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Packet Emulation CLI Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_emulate"
# meta:type="cli"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-10-26"
# meta:description="Simulate packet evaluation to show what nftban would do"
# meta:input="IP address, optional protocol/port/direction"
# meta:output="Emulation result (JSON or text)"
# meta:depends="nftban_emulate.sh"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Usage:
#   nftban emulate <ip>
#   nftban emulate <ip> tcp 22
#   nftban emulate <ip> tcp 111 in
#   nftban emulate <ip> --proto tcp --port 22 --direction in
#   nftban emulate <ip> --json
# =============================================================================

set -Eeuo pipefail

# Source core emulation module
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/core/nftban_emulate.sh" || return 1

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_emulate() {
    local ip=""
    local proto=""
    local port=""
    local direction="in"
    local json_output=false
    local help=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help|help)
                help=true
                shift
                ;;
            -j|--json)
                json_output=true
                shift
                ;;
            -p|--proto|--protocol)
                proto="$2"
                shift 2
                ;;
            --port)
                port="$2"
                shift 2
                ;;
            -d|--direction|--dir)
                direction="$2"
                shift 2
                ;;
            -*)
                nftban_banner 2>/dev/null || true
                echo "ERROR: Unknown option: $1" >&2
                echo "Use 'nftban emulate --help' for usage" >&2
                return 1
                ;;
            *)
                if [[ -z "$ip" ]]; then
                    # Detect old syntax: nftban emulate ban <ip> (removed in v1.24.0)
                    if [[ "$1" =~ ^(ban|unban|test|check)$ ]]; then
                        echo "NOTICE: 'nftban emulate $1 <ip>' syntax was removed in v1.24.0" >&2
                        echo "Use: nftban emulate <ip> [proto] [port]" >&2
                        echo "" >&2
                        # Skip the old subcommand and continue parsing
                        shift
                        continue
                    fi
                    ip="$1"
                elif [[ -z "$proto" && "$1" =~ ^(tcp|udp|icmp|icmpv6)$ ]]; then
                    # Positional protocol (e.g., nftban emulate 8.8.8.8 tcp 111 in)
                    proto="$1"
                elif [[ -z "$port" && -n "$proto" && "$1" =~ ^[0-9]+$ ]]; then
                    # Positional port (must follow protocol)
                    port="$1"
                elif [[ "$1" =~ ^(in|input|out|output|fwd|forward)$ ]]; then
                    # Positional direction
                    direction="$1"
                else
                    nftban_banner 2>/dev/null || true
                    echo "ERROR: Unexpected argument: $1" >&2
                    echo "Use 'nftban emulate --help' for usage" >&2
                    return 1
                fi
                shift
                ;;
        esac
    done

    # Show help
    if [[ "$help" == "true" ]]; then
        _emulate_help
        return 0
    fi

    # Validate IP
    if [[ -z "$ip" ]]; then
        nftban_banner 2>/dev/null || true
        echo "ERROR: IP address required" >&2
        echo "Usage: nftban emulate <ip> [options]" >&2
        return 1
    fi

    # Validate IP format
    if ! _validate_ip "$ip"; then
        nftban_banner 2>/dev/null || true
        echo "ERROR: Invalid IP address: $ip" >&2
        return 1
    fi

    # Validate protocol if specified
    if [[ -n "$proto" ]]; then
        case "$proto" in
            tcp|udp|icmp|icmpv6) ;;
            *)
                nftban_banner 2>/dev/null || true
                echo "ERROR: Invalid protocol: $proto (use tcp, udp, icmp)" >&2
                return 1
                ;;
        esac
    fi

    # Validate port if specified
    if [[ -n "$port" ]]; then
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
            nftban_banner 2>/dev/null || true
            echo "ERROR: Invalid port: $port (must be 1-65535)" >&2
            return 1
        fi
    fi

    # Validate direction
    case "$direction" in
        in|input|out|output|fwd|forward) ;;
        *)
            nftban_banner 2>/dev/null || true
            echo "ERROR: Invalid direction: $direction (use in, out, fwd)" >&2
            return 1
            ;;
    esac

    # Run emulation
    local result
    result=$(nftban_emulate_packet "$ip" "$proto" "$port" "$direction")

    if [[ "$json_output" == "true" ]]; then
        echo "$result"
    else
        nftban_emulate_format_text "$result"
    fi

    # Return exit code based on decision
    local decision
    decision=$(echo "$result" | grep -o '"decision": *"[^"]*"' | cut -d'"' -f4)
    [[ "$decision" == "block" ]] && return 2
    return 0
}

# Validate IP address format
_validate_ip() {
    local ip="$1"

    # IPv4 validation
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        local IFS='.'
        read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            [[ "$octet" -gt 255 ]] && return 1
        done
        return 0
    fi

    # IPv6 validation (basic)
    if [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
        return 0
    fi

    return 1
}

# Show help
_emulate_help() {
    cat <<'EOF'
NFTBan Emulate - Simulate packet decision

USAGE:
    nftban emulate <ip> [proto] [port] [direction]
    nftban emulate <ip> [options]

DESCRIPTION:
    Simulates what nftban would do with a packet from the specified IP.
    Shows whether the packet would be ALLOWED or BLOCKED, and explains
    which rule/set/module would make the decision.

    Without --proto/--port, only checks whitelist/blacklist membership.
    With --proto and --port, also checks port-level filtering (allowed
    ports sets: tcp_ports_in, udp_ports_in, etc.).

ARGUMENTS:
    <ip>                IP address to test (IPv4 or IPv6)
    [proto]             Protocol: tcp, udp (positional, optional)
    [port]              Port number: 1-65535 (positional, optional)
    [direction]         Direction: in, out, fwd (positional, default: in)

OPTIONS:
    -p, --proto <proto> Protocol: tcp, udp, icmp (optional)
    --port <port>       Port number: 1-65535 (optional)
    -d, --direction     Direction: in, out, fwd (default: in)
    -j, --json          Output as JSON
    -h, --help          Show this help

EXAMPLES:
    # Basic IP check (whitelist/blacklist only)
    nftban emulate 8.8.8.8

    # Check if port is allowed (positional args)
    nftban emulate 8.8.8.8 tcp 22
    nftban emulate 8.8.8.8 tcp 111

    # Check with flags
    nftban emulate 8.8.8.8 --proto tcp --port 22

    # Check outbound traffic
    nftban emulate 1.2.3.4 --direction out

    # JSON output for scripts/API
    nftban emulate 8.8.8.8 --json

    # Check if internal IP is whitelisted
    nftban emulate 10.0.0.1

EXIT CODES:
    0    Packet would be ALLOWED
    1    Error (invalid input, etc.)
    2    Packet would be BLOCKED

EVALUATION ORDER:
    1. Whitelist check (if match → ALLOW)
    2. Blacklist check (if match → BLOCK)
    3. GeoBan check (if match → BLOCK)
    4. Port filter (if port not allowed → BLOCK)
    5. Default policy (usually → ALLOW established, DROP new)

OUTPUT FIELDS:
    Module          Which nftban module made the decision
    Source          Specific source (feed name, config file, etc.)
    List type       Which nft set was matched
    Matching entry  The actual CIDR or IP that matched
    Table/Chain     NFTables table and chain
    Rule handle     NFTables rule handle number

SEE ALSO:
    nftban list          Show current bans
    nftban whitelist     Manage whitelist
    nftban search        Search for IP in sets
EOF
}

# Subcommand aliases (note: nftban_cmd_test removed - conflicts with cmd_test.sh)
nftban_cmd_simulate() {
    nftban_cmd_emulate "$@"
}

nftban_cmd_explain() {
    nftban_cmd_emulate "$@"
}

# Export functions
export -f nftban_cmd_emulate
export -f nftban_cmd_simulate
export -f nftban_cmd_explain
