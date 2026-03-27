#!/usr/bin/env bash

# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true

# Load JSON helper for --json support
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"

# Load NFT schema (single source of truth for table/set names)
# shellcheck source=/usr/lib/nftban/lib/nft_schema.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" || return 1
fi
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER" || return 1
fi

# Load IPC library for single-writer architecture
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" 2>/dev/null || true

# NFTBan v1.0.0 - Port CLI Handler
# =============================================================================

# SPDX-License-Identifier: MPL-2.0
# Purpose: Handle port-related CLI commands
#
# meta:name="cmd_port"
# meta:type="cli"
# meta:header="Port CLI Command"
# meta:version="1.45.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI interface for port status reporting"
# meta:inventory.files=""
# meta:inventory.binaries="ss,nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2025-11-24"
# =============================================================================


# Strict mode
IFS=$'\n\t'
umask 027

# Load dependencies
SCRIPT_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
LIB_DIR="$(dirname "$SCRIPT_DIR")"

# Load port report core module if not already loaded
if [[ ! $(type -t nftban_port_report_status) == "function" ]]; then
    if [[ -f "${LIB_DIR}/core/nftban_report_port.sh" ]]; then
        # shellcheck source=/dev/null
        source "${LIB_DIR}/core/nftban_report_port.sh" || return 1
    else
        echo "ERROR: nftban_report_port.sh not found at ${LIB_DIR}/core" >&2
        return 1
    fi
fi

# Load mail module for mail-report functionality
if [[ ! $(type -t nftban_mail_send) == "function" ]]; then
    if [[ -f "${LIB_DIR}/core/nftban_mail.sh" ]]; then
        # shellcheck source=/dev/null
        source "${LIB_DIR}/core/nftban_mail.sh" || return 1
    fi
fi

# =============================================================================
# HELP
# =============================================================================

nftban_cmd_port_help() {
    # Load output module for standard banner
    source "${LIB_DIR}/core/nftban_output.sh" || return 1
    nftban_banner
    echo ""
    echo "USAGE:"
    echo "  nftban port <subcommand> [options]"
    echo ""
    echo "SUBCOMMANDS:"
    echo "  allow <action> [args]             Per-IP port access (v1.41.0)"
    echo "    allow add <port> from <ip>      Grant IP access to port"
    echo "      --proto tcp|udp              Protocol (default: tcp)"
    echo "      --timeout 1h                 Access duration (default: permanent)"
    echo "      --comment \"text\"              Reason for access"
    echo "    allow remove <port> from <ip>   Revoke IP access to port"
    echo "      --proto tcp|udp              Protocol (default: tcp)"
    echo "    allow list [--json]             List all per-IP port rules"
    echo "    allow flush                     Remove all per-IP port rules"
    echo "  status [options] [ports]          Show port status (3-section view)"
    echo "    Options:"
    echo "      --listening                   Show only listening services"
    echo "      --inbound                     Show only inbound firewall policy"
    echo "      --outbound                    Show only outbound firewall policy"
    echo "      --active                      Hide ports without active services"
    echo "      --json                        Output as JSON"
    echo "  detailed [ports]                  Show detailed status with BIND and PROCESS"
    echo "  add <port> <protocol> <direction> Add port to whitelist (ALL args required)"
    echo "  remove <port>                     Remove port from whitelist"
    echo "  block <port>                      Block port (remove from whitelist)"
    echo "  unblock <port>                    Unblock port (TCP+UDP, INPUT+OUTPUT)"
    echo "  egress <cmd>                      Outbound port policy (stats/audit/recommend/enforce)"
    echo "  html-report                       Generate HTML report"
    echo "  mail-report [path] [recipient]    Mail report"
    echo "  allow-panel <panel>               Allow control panel ports"
    echo "  help                              Show this help"
    echo ""
    echo "ADD ARGUMENTS (ALL REQUIRED):"
    echo "  port:      1-65535"
    echo "  protocol:  tcp | udp | both"
    echo "  direction: in (INPUT) | out (OUTPUT) | inout (INPUT+OUTPUT)"
    echo ""
    echo "ARCHITECTURE:"
    echo "  All port operations apply to BOTH IPv4 and IPv6 tables automatically."
    echo "  Ports are stored in 4 nftables sets per IP family:"
    echo "    - tcp_ports_in   TCP ports allowed for INPUT (incoming connections)"
    echo "    - tcp_ports_out  TCP ports allowed for OUTPUT (outgoing connections)"
    echo "    - udp_ports_in   UDP ports allowed for INPUT (incoming packets)"
    echo "    - udp_ports_out  UDP ports allowed for OUTPUT (outgoing packets)"
    echo ""
    echo "EXAMPLES:"
    echo "  nftban port status               # Show all 3 sections (listeners, inbound, outbound)"
    echo "  nftban port status --listening   # Show only listening services"
    echo "  nftban port status --inbound     # Show only inbound firewall policy"
    echo "  nftban port status --outbound    # Show only outbound firewall policy"
    echo "  nftban port status 22,80,443     # Filter to specific ports"
    echo "  nftban port detailed             # Show detailed info with bind addresses"
    echo ""
    echo "  # Web server (inbound only)"
    echo "  nftban port add 80 tcp in"
    echo "  nftban port add 443 both inout   # HTTPS + HTTP/3 QUIC (bidirectional)"
    echo ""
    echo "  # SMTP outbound relay"
    echo "  nftban port add 25 tcp out"
    echo ""
    echo "  # DNS server (TCP+UDP, bidirectional)"
    echo "  nftban port add 53 both inout"
    echo ""
    echo "  # Zabbix agent (server polls us)"
    echo "  nftban port add 10050 tcp in"
    echo ""
    echo "  # MySQL client (outbound connections only)"
    echo "  nftban port add 3306 tcp out"
    echo ""
    echo "  nftban port remove 8080          # Remove port 8080 from whitelist"
    echo "  nftban port block 3389           # Block RDP port"
    echo "  nftban port unblock 3389         # Unblock RDP port (TCP+UDP, both directions)"
    echo ""
    echo "  nftban port mail-report ${NFTBAN_DATA_DIR}/reports/port_report.html admin@example.com"
    echo "  nftban port allow-panel directadmin  # Allow DirectAdmin panel ports"
    echo ""
    echo "  # Egress (outbound) policy management"
    echo "  nftban port egress stats             # View outbound counters"
    echo "  nftban port egress audit 24          # Find unknown outbound ports (last 24h)"
    echo "  nftban port egress recommend         # Suggest ports to add"
    echo "  nftban port egress enforce           # Enable restrictive outbound policy"
    echo ""
    echo "  # Test outbound before enforcing"
    echo "  nftban emulate --out 8.8.8.8:443    # Test if HTTPS outbound allowed"
    echo ""
    echo "Note: For full panel management, use: nftban panel directadmin <action>"
    echo "      Actions: enable, disable, status, report, repair, test"
    echo ""
    echo "THREE-SECTION OUTPUT (v1.19.24):"
    echo ""
    echo "  Section 1: LISTENING SERVICES"
    echo "    Shows what processes are actually listening on this host"
    echo "    Columns: PORT, PROTO, SERVICE, PROCESS, BIND, SCOPE"
    echo ""
    echo "  Section 2: INBOUND FIREWALL POLICY"
    echo "    Shows what inbound ports are allowed, regardless of listeners"
    echo "    Columns: PORT, PROTO, SERVICE, IPv4, IPv6, LISTENING?, ACCESS"
    echo "    Access labels: Public, Local-only, Open (no listener)"
    echo ""
    echo "  Section 3: OUTBOUND FIREWALL POLICY"
    echo "    Shows what egress ports are allowed (dependencies like Zabbix, DNS)"
    echo "    Columns: PORT, PROTO, SERVICE, IPv4, IPv6, ACCESS"
    echo "    Access labels: Egress allowed, Egress (IPv4/IPv6 only)"
    echo ""
    echo "SERVICE LABEL RESOLUTION:"
    echo "  1. Built-in mapping (SSH, HTTP, DNS, etc.)"
    echo "  2. Runtime process correlation (if listening)"
    echo "  3. Config-defined alias (custom labels)"
    echo "  4. Fallback: 'Unknown' (port still shown!)"
    echo ""
    echo "IMPORTANT: Unknown service name != hidden port"
    echo "  If nft allows it, it appears. If something listens, it appears."
    echo ""
    echo "FIREWALL SYMBOLS:"
    echo "  ✔ Allowed  - Port explicitly allowed in nftables"
    echo "  ✖ Blocked  - Port explicitly blocked (drop/reject)"
    echo "  − No-rule  - No explicit rule (default policy applies)"
    echo ""
    echo "NOTES:"
    echo "  - Requires root privileges (sudo)"
    echo "  - Uses ss/lsof to detect listening services"
    echo "  - Parses nftables rules to determine firewall status"
    echo "  - 'generic' rules lack meta nfproto (affect both IPv4/IPv6)"
    echo "  - PUBLIC = binds to 0.0.0.0 or ::"
    echo "  - LOCAL-ONLY = binds to 127.0.0.1 or ::1"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "QUICK START"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  # Allow a web server"
    echo "  nftban port add 80 tcp in"
    echo "  nftban port add 443 both inout"
    echo ""
    echo "  # Allow a database (internal only)"
    echo "  nftban port add 3306 tcp in"
    echo ""
    echo "  # Check current ports"
    echo "  nftban port status"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "HOW IT WORKS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Port rules are stored in ${NFTBAN_CONFIG_DIR:-/etc/nftban}/ports.d/*.conf"
    echo "  The daemon (nftband) loads ports into nftables via IPC."
    echo "  All operations apply to both IPv4 and IPv6 automatically."
    echo ""
    echo "  Config file priority (loaded in order):"
    echo "    00-system.conf   - Protected system ports (SSH, etc.)"
    echo "    50-services.conf - Common service ports"
    echo "    90-custom.conf   - User-added ports (via 'nftban port add')"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "TROUBLESHOOTING"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  If ports are not applied, check:"
    echo ""
    echo "  1. Is the daemon running?"
    echo "     systemctl status nftband"
    echo ""
    echo "  2. Check the config files:"
    echo "     cat ${NFTBAN_CONFIG_DIR:-/etc/nftban}/ports.d/90-custom.conf"
    echo ""
    echo "  3. Force reload all ports:"
    echo "     nftban reload"
    echo ""
    echo "  4. Verify firewall is initialized:"
    echo "     nftban firewall status"
    echo ""
    echo "  5. Check for errors in logs:"
    echo "     journalctl -u nftband -n 50"
    echo ""
}

# =============================================================================

# PORT COMMAND HANDLER
# =============================================================================

nftban_cmd_port() {
    # Handle port subcommands
    # Args: $@ = port subcommand and arguments

    local subcmd="${1:-status}"
    shift || true

    # Check root for port scanning
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Port scanning requires root privileges" >&2
        echo "Please run: sudo nftban port $subcmd" >&2
        return 1
    fi

    case "$subcmd" in
        allow)
            # v1.41.0: Per-IP port access management
            nftban_port_allow_dispatch "$@"
            return $?
            ;;

        status|list)
            # Show port status (terminal output)
            # Optional: port filter as argument
            # NOTE: 'list' is deprecated, use 'status' instead
            # Flags: --json, --active, --listening, --inbound, --outbound

            local filter_ports="" show_active_only=0 section="all"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --json)
                        export NFTBAN_PORT_OUTPUT_FORMAT="json"
                        shift
                        ;;
                    --active)
                        show_active_only=1
                        shift
                        ;;
                    --listening)
                        section="listening"
                        shift
                        ;;
                    --inbound)
                        section="inbound"
                        shift
                        ;;
                    --outbound)
                        section="outbound"
                        shift
                        ;;
                    *)
                        filter_ports="$1"
                        shift
                        ;;
                esac
            done

            export NFTBAN_PORT_FILTER_PORTS="$filter_ports"
            export NFTBAN_PORT_DETAILED=0
            export NFTBAN_PORT_ACTIVE_ONLY="$show_active_only"
            export NFTBAN_PORT_SECTION="$section"

            if [[ "$NFTBAN_PORT_OUTPUT_FORMAT" != "json" ]]; then
                nftban_banner
                export NFTBAN_PORT_OUTPUT_FORMAT="table"
            fi

            nftban_port_report_status
            return $?
            ;;

        detailed)
            # Show detailed port status with BIND and PROCESS columns

            # Show standard banner
            nftban_banner

            export NFTBAN_PORT_FILTER_PORTS="${1:-}"
            export NFTBAN_PORT_DETAILED=1
            export NFTBAN_PORT_OUTPUT_FORMAT="table"
            nftban_port_report_status
            return $?
            ;;

        html-report)
            # Generate HTML report
            echo "Generating HTML port report..."
            local report_file
            report_file=$(nftban_port_generate_html_report)
            if [[ $? -eq 0 && -f "$report_file" ]]; then
                echo "✓ HTML report generated successfully:"
                echo "  $report_file"
                echo
                echo "View with: firefox '$report_file' (or your preferred browser)"
                return 0
            else
                echo "ERROR: Failed to generate HTML report" >&2
                return 1
            fi
            ;;

        mail-report)
            # Mail port report
            # Args: [path] [recipient]
            local report_path="${1:-}"
            # Per-module override: NFTBAN_MAIL_REPORT_RECIPIENT, fallback: NFTBAN_MAIL_RECIPIENT
            local recipient="${2:-${NFTBAN_MAIL_REPORT_RECIPIENT:-${NFTBAN_MAIL_RECIPIENT:-}}}"

            if [[ -z "$recipient" ]]; then
                echo "ERROR: No recipient specified" >&2
                echo "Set NFTBAN_MAIL_RECIPIENT (global) or NFTBAN_MAIL_REPORT_RECIPIENT (override)" >&2
                echo "Quick setup: nftban mail setup your@email.com" >&2
                echo "Usage: nftban port mail-report [path] [recipient]" >&2
                return 1
            fi

            # Check if mail module is available
            if [[ ! $(type -t nftban_mail_send) == "function" ]]; then
                echo "ERROR: Mail module not available" >&2
                echo "Please ensure nftban_mail.sh is installed" >&2
                return 1
            fi

            # If path provided, mail that file
            if [[ -n "$report_path" ]]; then
                if [[ ! -f "$report_path" ]]; then
                    echo "ERROR: Report file not found: $report_path" >&2
                    return 1
                fi
                echo "Sending port report to $recipient..."
                nftban_mail_send "$report_path" "$recipient"
                return $?
            else
                # Generate report and mail it
                echo "Generating HTML report and sending to $recipient..."
                local report_file
                report_file=$(nftban_port_generate_html_report)
                if [[ $? -eq 0 && -f "$report_file" ]]; then
                    echo "✓ Report generated: $report_file"
                    echo "Sending via email..."
                    nftban_mail_send "$report_file" "$recipient"
                    return $?
                else
                    echo "ERROR: Failed to generate HTML report" >&2
                    return 1
                fi
            fi
            ;;

        add)
            # Add port to whitelist
            # Args: <port> <protocol> <direction>  (ALL REQUIRED)
            local port="${1:-}"
            local proto="${2:-}"
            local direction="${3:-}"

            # Show usage if missing arguments
            if [[ -z "$port" ]] || [[ -z "$proto" ]] || [[ -z "$direction" ]]; then
                echo "ERROR: All arguments required" >&2
                echo "" >&2
                echo "Usage: nftban port add <port> <protocol> <direction>" >&2
                echo "" >&2
                echo "  port:      1-65535" >&2
                echo "  protocol:  tcp | udp | both" >&2
                echo "  direction: in (INPUT) | out (OUTPUT) | inout (INPUT+OUTPUT)" >&2
                echo "" >&2
                echo "NOTE: All port operations apply to both IPv4 and IPv6 tables automatically." >&2
                echo "" >&2
                echo "Examples:" >&2
                echo "  nftban port add 80 tcp in        # Web server (inbound only)" >&2
                echo "  nftban port add 443 both inout   # HTTPS + HTTP/3 QUIC (bidirectional)" >&2
                echo "  nftban port add 25 tcp out       # SMTP outbound relay" >&2
                echo "  nftban port add 53 both inout    # DNS server (TCP+UDP, bidirectional)" >&2
                echo "  nftban port add 10050 tcp in     # Zabbix agent (polled by server)" >&2
                return 1
            fi

            # Validate port number
            if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
                echo "ERROR: Invalid port number: $port" >&2
                echo "Port must be between 1-65535" >&2
                return 1
            fi

            # Normalize and validate protocol
            local proto_code proto_name
            case "${proto,,}" in
                tcp|t)
                    proto_code="T"
                    proto_name="TCP"
                    ;;
                udp|u)
                    proto_code="U"
                    proto_name="UDP"
                    ;;
                both|b)
                    proto_code="B"
                    proto_name="TCP+UDP"
                    ;;
                *)
                    echo "ERROR: Invalid protocol: $proto" >&2
                    echo "Valid protocols: tcp, udp, both" >&2
                    return 1
                    ;;
            esac

            # Normalize and validate direction
            local dir_code dir_name
            case "${direction,,}" in
                in|i|input)
                    dir_code="I"
                    dir_name="INPUT"
                    ;;
                out|o|output)
                    dir_code="O"
                    dir_name="OUTPUT"
                    ;;
                inout|io|both)
                    dir_code="IO"
                    dir_name="INPUT+OUTPUT"
                    ;;
                *)
                    echo "ERROR: Invalid direction: $direction" >&2
                    echo "Valid directions: in, out, inout" >&2
                    return 1
                    ;;
            esac

            # Create ports.d directory if missing
            mkdir -p ${NFTBAN_CONFIG_DIR}/ports.d || return 1
            chmod 750 ${NFTBAN_CONFIG_DIR}/ports.d
            chown root:nftban ${NFTBAN_CONFIG_DIR}/ports.d 2>/dev/null || true

            # Use 90-custom.conf for user-added ports
            local config_file="${NFTBAN_CONFIG_DIR}/ports.d/90-custom.conf"

            # Build config entry: PORT/PROTOCOL/DIRECTION
            local config_entry="${port}/${proto_code}/${dir_code}"

            # Check if exact entry already exists
            if [[ -f "$config_file" ]] && grep -qE "^${config_entry}$" "$config_file" 2>/dev/null; then
                echo "⚠ Port already configured: $config_entry" >&2
                return 0
            fi

            # Add port to config (format: PORT/PROTOCOL/DIRECTION)
            echo "# Added by: nftban port add $port $proto_name $dir_name ($(date '+%Y-%m-%d %H:%M:%S'))" >> "$config_file"
            echo "$config_entry" >> "$config_file"
            chmod 640 "$config_file"
            chown root:nftban "$config_file" 2>/dev/null || true

            echo "✓ Port $port ($proto_name $dir_name) added to whitelist"
            echo "  Config: $config_file"
            echo "  Entry:  $config_entry"
            echo ""

            # Atomically add to nftables via IPC (if firewall is active)
            if nft list table "${NFTBAN_TABLE_IPV4}" >/dev/null 2>&1; then
                echo "⚡ Applying to firewall via IPC..."

                local add_success=false

                # Check if daemon is running and add port atomically
                if nft_ipc_is_daemon_running 2>/dev/null; then
                    # Use atomic add_port IPC - much faster than full reload
                    if nft_ipc_add_port "$port" "$proto" "$direction" 2>/dev/null; then
                        echo "  ✓ Port $port applied to firewall (IPv4 + IPv6)"
                        add_success=true
                    else
                        echo "  ⚠ Could not add port via daemon" >&2
                    fi
                else
                    echo "  ℹ Daemon not running"
                fi

                # Final status
                if [[ "$add_success" == "true" ]]; then
                    echo ""
                    echo "✅ Port $port is now active in firewall"
                else
                    echo ""
                    echo "⚠ Port saved to config but daemon not running"
                    echo ""
                    echo "To activate the port, start the daemon:"
                    echo "  systemctl start nftband"
                    echo ""
                    echo "Or reload ports manually after starting daemon:"
                    echo "  nftban port reload"
                fi
            else
                echo "⚠ Firewall not initialized - port saved but not active yet"
                echo "Run: nftban firewall rebuild"
            fi

            echo ""
            echo "To remove this port later, use:"
            echo "  nftban port remove $port"

            return 0
            ;;

        remove)
            # Remove port from whitelist
            # Args: <port>
            local port="${1:-}"

            if [[ -z "$port" ]]; then
                echo "ERROR: Port number required" >&2
                echo "Usage: nftban port remove <port>" >&2
                echo "" >&2
                echo "Examples:" >&2
                echo "  nftban port remove 8080" >&2
                echo "  nftban port remove 53" >&2
                return 1
            fi

            # Validate port number
            if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 ]] || [[ "$port" -gt 65535 ]]; then
                echo "ERROR: Invalid port number: $port" >&2
                echo "Port must be between 1-65535" >&2
                return 1
            fi

            # CRITICAL: Protect current SSH port from being removed
            local current_ssh_port="${SSH_CLIENT:+${SSH_CLIENT##* }}"
            if [[ "$port" == "$current_ssh_port" ]]; then
                echo "❌ ERROR: Cannot remove port $port - this is your ACTIVE SSH port!" >&2
                echo "" >&2
                echo "⚠️  DANGER: Removing this port will lock you out of the server!" >&2
                echo "   Your SSH connection is using port $port right now." >&2
                echo "" >&2
                echo "If you really need to remove this port:" >&2
                echo "  1. Connect via console or alternate SSH port" >&2
                echo "  2. Then run: nftban port remove $port" >&2
                return 1
            fi

            # Find all config files containing this port
            local found_files=()
            local protected_files=()

            if [[ -d ${NFTBAN_CONFIG_DIR}/ports.d ]]; then
                while IFS= read -r file; do
                    # Check if file contains the port
                    if grep -qE "^${port}/" "$file" 2>/dev/null; then
                        # Check if it's a protected file (00-*.conf)
                        if [[ "$(basename "$file")" =~ ^00- ]]; then
                            protected_files+=("$file")
                        else
                            found_files+=("$file")
                        fi
                    fi
                done < <(find ${NFTBAN_CONFIG_DIR}/ports.d -type f -name "*.conf" 2>/dev/null)
            fi

            # Show protected files (don't remove)
            if [[ ${#protected_files[@]} -gt 0 ]]; then
                echo "⚠ WARNING: Port $port found in protected system files:" >&2
                for file in "${protected_files[@]}"; do
                    echo "  - $file (PROTECTED - will not remove)" >&2
                    grep -E "^${port}/" "$file" 2>/dev/null | sed 's/^/    /' >&2
                done
                echo "" >&2

                # If ONLY in protected files, abort
                if [[ ${#found_files[@]} -eq 0 ]]; then
                    echo "ERROR: Cannot remove port $port - only exists in protected files" >&2
                    echo "Protected files (00-*.conf) contain critical system ports." >&2
                    echo "To remove, edit manually: ${protected_files[0]}" >&2
                    return 1
                fi
            fi

            # Remove from non-protected files
            if [[ ${#found_files[@]} -eq 0 ]]; then
                echo "ERROR: Port $port not found in whitelist" >&2
                echo "Checked: ${NFTBAN_CONFIG_DIR}/ports.d/*.conf" >&2
                return 1
            fi

            local removed_count=0

            for file in "${found_files[@]}"; do
                echo "Removing port $port from: $file"

                # Show what we're removing and capture protocol/direction
                local port_line removed_proto removed_dir
                port_line=$(grep -E "^${port}/" "$file" 2>/dev/null)
                removed_proto=$(echo "$port_line" | cut -d'/' -f2)
                removed_dir=$(echo "$port_line" | cut -d'/' -f3)
                echo "  - $port_line (proto=$removed_proto, dir=$removed_dir)"

                # Create backup
                cp "$file" "${file}.backup.$(date +%Y%m%d-%H%M%S)"

                # Remove port and its comment line (if immediately before)
                sed -i "/^# Added by: nftban port add ${port} /d; /^${port}\//d" "$file"

                removed_count=$((removed_count + 1))
            done

            echo ""
            echo "✓ Port $port removed from $removed_count file(s)"
            echo ""

            # Apply removal to nftables via IPC (if firewall is active)
            # Delete from ALL protocol/direction combinations since config removal is global
            if nft list table "${NFTBAN_TABLE_IPV4}" >/dev/null 2>&1; then
                echo "⚡ Applying removal to firewall via IPC..."

                if nft_ipc_is_daemon_running 2>/dev/null; then
                    # Use atomic delete_port IPC - remove from all sets (both protocols, both directions)
                    if nft_ipc_delete_port "$port" "both" "both" 2>/dev/null; then
                        echo "  ✓ Port $port removed from firewall (IPv4 + IPv6)"
                        echo ""
                        echo "✅ Port $port is now blocked in firewall"
                    else
                        echo "  ⚠ Could not remove port via daemon" >&2
                        echo "  Run manually: nftban reload" >&2
                    fi
                else
                    echo "  ℹ Daemon not running - port removed from config only"
                    echo "  Start daemon and reload: systemctl start nftband && nftban reload"
                fi
            else
                echo "⚠ Firewall not initialized - port removed from config only"
            fi

            return 0
            ;;

        block)
            # Block port (remove from whitelist)
            # Default: blocks TCP+UDP on both IPv4+IPv6
            # Args: <port>
            local port="${1:-}"

            if [[ -z "$port" ]]; then
                echo "ERROR: Port number required" >&2
                echo "Usage: nftban port block <port>" >&2
                echo "" >&2
                echo "Examples:" >&2
                echo "  nftban port block 8080    # Block TCP+UDP port 8080 (safest)" >&2
                echo "" >&2
                echo "Note: This removes the port from the firewall whitelist." >&2
                echo "      The port will be blocked by the default DROP policy." >&2
                return 1
            fi

            # CRITICAL: Protect current SSH port from being blocked
            local current_ssh_port="${SSH_CLIENT:+${SSH_CLIENT##* }}"
            if [[ "$port" == "$current_ssh_port" ]]; then
                echo "❌ ERROR: Cannot block port $port - this is your ACTIVE SSH port!" >&2
                echo "" >&2
                echo "⚠️  DANGER: Blocking this port will lock you out of the server!" >&2
                echo "   Your SSH connection is using port $port right now." >&2
                echo "" >&2
                echo "If you really need to block this port:" >&2
                echo "  1. Connect via console or alternate SSH port" >&2
                echo "  2. Then run: nftban port block $port" >&2
                return 1
            fi

            echo "🛡️  Blocking port $port (TCP+UDP on IPv4+IPv6)..."
            echo ""

            # Call remove to take it out of whitelist
            nftban_cmd_port remove "$port"
            local result=$?

            if [[ $result -eq 0 ]]; then
                echo ""
                echo "✅ Port $port is now BLOCKED by firewall"
                echo ""
                echo "To unblock this port later, use:"
                echo "  nftban port unblock $port"
            fi

            return $result
            ;;

        unblock)
            # Unblock port (add to whitelist)
            # Default: unblocks TCP+UDP on both INPUT+OUTPUT
            # Args: <port>
            local port="${1:-}"

            if [[ -z "$port" ]]; then
                echo "ERROR: Port number required" >&2
                echo "Usage: nftban port unblock <port>" >&2
                echo "" >&2
                echo "Examples:" >&2
                echo "  nftban port unblock 8080    # Allow TCP+UDP port 8080 (inout)" >&2
                echo "" >&2
                echo "Note: This adds the port to the firewall whitelist (both protocols, both directions)." >&2
                return 1
            fi

            echo "✅ Unblocking port $port (TCP+UDP, INPUT+OUTPUT)..."
            echo ""

            # Call add with 'both' protocol and 'inout' direction
            nftban_cmd_port add "$port" "both" "inout"
            local result=$?

            if [[ $result -eq 0 ]]; then
                echo ""
                echo "To block this port again, use:"
                echo "  nftban port block $port"
            fi

            return $result
            ;;

        allow-panel)
            # Allow control panel ports in firewall
            # Args: <panel_name>
            local panel="${1:-}"

            if [[ -z "$panel" ]]; then
                echo "ERROR: Panel name required" >&2
                echo "Usage: nftban port allow-panel <panel_name>" >&2
                echo "Available panels: directadmin" >&2
                return 1
            fi

            case "$panel" in
                directadmin|da)
                    nftban_port_allow_directadmin
                    return $?
                    ;;
                *)
                    echo "ERROR: Unknown panel: $panel" >&2
                    echo "Available panels: directadmin" >&2
                    return 1
                    ;;
            esac
            ;;

        help|--help|-h)
            nftban_cmd_port_help
            return 0
            ;;

        egress)
            # Egress subcommand - outbound port policy management
            # Load egress functions from cmd_egress.sh
            local egress_file="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/cli/cmd_egress.sh"
            if [[ -f "$egress_file" ]]; then
                # shellcheck source=/dev/null
                source "$egress_file" || return 1
                # Call the egress handler with remaining args
                nftban_cmd_egress "$@"
            else
                echo "ERROR: Egress module not found: $egress_file" >&2
                return 1
            fi
            ;;

        *)
            echo "ERROR: Unknown port command: $subcmd" >&2
            echo "Run 'nftban port help' for available commands" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# PER-IP PORT ACCESS (v1.41.0)
# =============================================================================

# Persistence file for port allow rules
readonly NFTBAN_PORT_ALLOW_CONFIG="${NFTBAN_CONFIG_DIR:-/etc/nftban}/access.d/port_allow.conf"

nftban_port_allow_dispatch() {
    # Dispatch port allow subcommands
    local action="${1:-help}"
    shift || true

    case "$action" in
        add)    nftban_port_allow_add "$@" ;;
        remove) nftban_port_allow_remove "$@" ;;
        list)   nftban_port_allow_list "$@" ;;
        flush)  nftban_port_allow_flush "$@" ;;
        help|--help|-h) nftban_port_allow_help ;;
        *)
            echo "ERROR: Unknown allow action: $action" >&2
            echo "Run 'nftban port allow help' for usage" >&2
            return 1
            ;;
    esac
}

nftban_port_allow_add() {
    # Add per-IP port access
    # Usage: nftban port allow add <port> from <ip> [--proto tcp|udp] [--timeout 1h] [--comment "text"]

    local port="" ip="" proto="tcp" timeout_val="" comment_text=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            from) shift; ip="${1:-}"; shift || true ;;
            --proto) shift; proto="${1:-tcp}"; shift || true ;;
            --timeout) shift; timeout_val="${1:-}"; shift || true ;;
            --comment) shift; comment_text="${1:-}"; shift || true ;;
            *)
                if [[ -z "$port" ]]; then
                    port="$1"
                elif [[ -z "$ip" ]]; then
                    ip="$1"
                fi
                shift
                ;;
        esac
    done

    # Validate required args
    if [[ -z "$port" || -z "$ip" ]]; then
        echo "ERROR: Port and IP required" >&2
        echo "Usage: nftban port allow add <port> from <ip> [--proto tcp|udp] [--timeout 1h]" >&2
        return 1
    fi

    # Validate port
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]]; then
        echo "ERROR: Invalid port: $port (must be 1-65535)" >&2
        return 1
    fi

    # Validate protocol
    proto="${proto,,}"
    if [[ "$proto" != "tcp" && "$proto" != "udp" ]]; then
        echo "ERROR: Invalid protocol: $proto (must be tcp or udp)" >&2
        return 1
    fi

    # Validate IP (basic check — daemon does full validation)
    if [[ "$ip" != *"."* && "$ip" != *":"* ]]; then
        echo "ERROR: Invalid IP address: $ip" >&2
        return 1
    fi

    # Convert timeout to seconds for IPC
    local timeout_seconds=0
    if [[ -n "$timeout_val" ]]; then
        # Parse duration: 30s, 5m, 1h, 1d
        case "$timeout_val" in
            *s) timeout_seconds="${timeout_val%s}" ;;
            *m) timeout_seconds=$(( ${timeout_val%m} * 60 )) ;;
            *h) timeout_seconds=$(( ${timeout_val%h} * 3600 )) ;;
            *d) timeout_seconds=$(( ${timeout_val%d} * 86400 )) ;;
            *)
                if [[ "$timeout_val" =~ ^[0-9]+$ ]]; then
                    timeout_seconds="$timeout_val"
                else
                    echo "ERROR: Invalid timeout: $timeout_val (use 30s, 5m, 1h, 1d)" >&2
                    return 1
                fi
                ;;
        esac
    fi

    # Persist to config
    mkdir -p "$(dirname "$NFTBAN_PORT_ALLOW_CONFIG")"
    chmod 750 "$(dirname "$NFTBAN_PORT_ALLOW_CONFIG")"
    local iso_date
    iso_date=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    echo "${port}|${ip}|${proto}|${timeout_seconds}|${comment_text}|${iso_date}" >> "$NFTBAN_PORT_ALLOW_CONFIG"
    chmod 640 "$NFTBAN_PORT_ALLOW_CONFIG"

    # Apply via IPC
    if nft_ipc_is_daemon_running 2>/dev/null; then
        local params
        params=$(jq -nc \
            --arg ip "$ip" \
            --argjson port "$port" \
            --arg protocol "$proto" \
            --argjson timeout "$timeout_seconds" \
            '{ip: $ip, port: $port, protocol: $protocol, timeout: $timeout}')
        local response
        response=$(nft_ipc_request "access_allow" "$params")
        if nft_ipc_success "$response"; then
            echo "✅ Port $port ($proto) access granted to $ip"
            [[ $timeout_seconds -gt 0 ]] && echo "   Expires in: $timeout_val"
            [[ -n "$comment_text" ]] && echo "   Comment: $comment_text"
        else
            echo "⚠ Saved to config but IPC failed: $(nft_ipc_error "$response")" >&2
            echo "  Port will be applied on daemon restart" >&2
        fi
    else
        echo "✅ Port $port ($proto) access saved for $ip"
        echo "   ℹ Daemon not running — will apply on start"
    fi

    return 0
}

nftban_port_allow_remove() {
    # Remove per-IP port access
    # Usage: nftban port allow remove <port> from <ip> [--proto tcp|udp]

    local port="" ip="" proto="tcp"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            from) shift; ip="${1:-}"; shift || true ;;
            --proto) shift; proto="${1:-tcp}"; shift || true ;;
            *)
                if [[ -z "$port" ]]; then
                    port="$1"
                elif [[ -z "$ip" ]]; then
                    ip="$1"
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$port" || -z "$ip" ]]; then
        echo "ERROR: Port and IP required" >&2
        echo "Usage: nftban port allow remove <port> from <ip> [--proto tcp|udp]" >&2
        return 1
    fi

    proto="${proto,,}"

    # Remove from config file
    if [[ -f "$NFTBAN_PORT_ALLOW_CONFIG" ]]; then
        local pattern="^${port}|${ip}|${proto}|"
        if grep -q "$pattern" "$NFTBAN_PORT_ALLOW_CONFIG" 2>/dev/null; then
            sed -i "/${port}|${ip}|${proto}|/d" "$NFTBAN_PORT_ALLOW_CONFIG"
            echo "✓ Removed from config"
        else
            echo "⚠ Entry not found in config" >&2
        fi
    fi

    # Revoke via IPC
    if nft_ipc_is_daemon_running 2>/dev/null; then
        local params
        params=$(jq -nc \
            --arg ip "$ip" \
            --argjson port "$port" \
            --arg protocol "$proto" \
            '{ip: $ip, port: $port, protocol: $protocol}')
        local response
        response=$(nft_ipc_request "access_revoke" "$params")
        if nft_ipc_success "$response"; then
            echo "✅ Port $port ($proto) access revoked from $ip"
        else
            echo "⚠ IPC revoke failed: $(nft_ipc_error "$response")" >&2
        fi
    else
        echo "✅ Port $port ($proto) access removed from config"
        echo "   ℹ Daemon not running — change takes effect on start"
    fi

    return 0
}

nftban_port_allow_list() {
    # List all per-IP port access rules
    # Usage: nftban port allow list [--json]

    local json_output=false
    [[ "${1:-}" == "--json" ]] && json_output=true

    if [[ ! -f "$NFTBAN_PORT_ALLOW_CONFIG" ]] || [[ ! -s "$NFTBAN_PORT_ALLOW_CONFIG" ]]; then
        if [[ "$json_output" == "true" ]]; then
            echo '{"rules":[]}'
        else
            echo "No per-IP port access rules configured"
        fi
        return 0
    fi

    if [[ "$json_output" == "true" ]]; then
        # JSON output
        echo '{"rules":['
        local first=true
        while IFS='|' read -r port ip proto timeout comment date; do
            [[ -z "$port" || "$port" == "#"* ]] && continue
            if [[ "$first" == "true" ]]; then
                first=false
            else
                echo ","
            fi
            printf '{"port":%s,"ip":"%s","protocol":"%s","timeout":%s,"comment":"%s","added":"%s"}' \
                "$port" "$ip" "$proto" "$timeout" "$comment" "$date"
        done < "$NFTBAN_PORT_ALLOW_CONFIG"
        echo ']}'
    else
        # Table output
        printf "%-7s %-8s %-40s %-12s %s\n" "PORT" "PROTO" "IP" "EXPIRES" "COMMENT"
        printf "%-7s %-8s %-40s %-12s %s\n" "-------" "--------" "----------------------------------------" "------------" "-------"
        while IFS='|' read -r port ip proto timeout comment date; do
            [[ -z "$port" || "$port" == "#"* ]] && continue
            local expires="permanent"
            if [[ "$timeout" -gt 0 ]]; then
                expires="${timeout}s"
            fi
            printf "%-7s %-8s %-40s %-12s %s\n" "$port" "$proto" "$ip" "$expires" "$comment"
        done < "$NFTBAN_PORT_ALLOW_CONFIG"
    fi

    return 0
}

nftban_port_allow_flush() {
    # Flush all per-IP port access rules

    echo "Flushing all per-IP port access rules..."

    # Clear config
    if [[ -f "$NFTBAN_PORT_ALLOW_CONFIG" ]]; then
        : > "$NFTBAN_PORT_ALLOW_CONFIG"
        echo "✓ Config cleared"
    fi

    # Flush nft sets via IPC
    if nft_ipc_is_daemon_running 2>/dev/null; then
        local families=("ip" "ip6")
        local sets=("port_allow_tcp" "port_allow_udp")
        for fam in "${families[@]}"; do
            local suffix="_ipv4"
            [[ "$fam" == "ip6" ]] && suffix="_ipv6"
            for set_base in "${sets[@]}"; do
                if ! nft_ipc_flush_set "${fam} nftban" "${set_base}${suffix}" 2>/dev/null; then
                    echo "  ⚠ Failed to flush ${set_base}${suffix} via IPC" >&2
                fi
            done
        done
        echo "✅ All per-IP port access rules flushed"
    else
        echo "✅ Config cleared (daemon not running — sets empty on start)"
    fi

    return 0
}

nftban_port_allow_help() {
    echo "PER-IP PORT ACCESS (v1.41.0)"
    echo ""
    echo "Grant specific IPs access to specific ports without opening the port globally."
    echo "Banned IPs are ALWAYS blocked (blacklist rules have higher priority)."
    echo ""
    echo "USAGE:"
    echo "  nftban port allow add <port> from <ip> [options]"
    echo "  nftban port allow remove <port> from <ip> [--proto tcp|udp]"
    echo "  nftban port allow list [--json]"
    echo "  nftban port allow flush"
    echo ""
    echo "OPTIONS:"
    echo "  --proto tcp|udp       Protocol (default: tcp)"
    echo "  --timeout <duration>  Access duration (30s, 5m, 1h, 1d; default: permanent)"
    echo "  --comment \"text\"      Reason for access grant"
    echo ""
    echo "EXAMPLES:"
    echo "  # Allow admin MySQL access for 1 hour"
    echo "  nftban port allow add 3306 from 10.0.0.5 --timeout 1h --comment 'DB admin'"
    echo ""
    echo "  # Allow permanent SSH access for office IP"
    echo "  nftban port allow add 22 from 203.0.113.10 --comment 'Office IP'"
    echo ""
    echo "  # Allow UDP DNS from monitoring server"
    echo "  nftban port allow add 53 from 10.0.0.100 --proto udp"
    echo ""
    echo "  # List all rules"
    echo "  nftban port allow list"
    echo ""
    echo "  # Revoke access"
    echo "  nftban port allow remove 3306 from 10.0.0.5"
    echo ""
    echo "PRECEDENCE:"
    echo "  Blacklist (ban) > Port Allow > Global port rules"
    echo "  A banned IP CANNOT access ports via 'port allow'."
    echo ""
}

export -f nftban_port_allow_dispatch
export -f nftban_port_allow_add
export -f nftban_port_allow_remove
export -f nftban_port_allow_list
export -f nftban_port_allow_flush
export -f nftban_port_allow_help

# =============================================================================

# DIRECTADMIN PANEL SUPPORT
# =============================================================================


nftban_port_allow_directadmin() {
    # Allow DirectAdmin control panel ports in firewall
    # Opens all required ports for DirectAdmin installation

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "DirectAdmin Control Panel - Firewall Configuration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Load DirectAdmin configuration
    local config_file="${NFTBAN_CONFIG_DIR}/conf.d/panels/directadmin/main.conf"
    if [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file" || true
        echo "✓ Loaded configuration from: $config_file"
    else
        echo "⚠ Config file not found: $config_file"
        echo "  Using default port configuration..."
    fi
    echo ""

    # IMPORTANT WARNING: CloudFlare requirement
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║ ⚠️  IMPORTANT: CloudFlare Whitelist Required                      ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "DirectAdmin licensing servers are behind CloudFlare CDN."
    echo "You MUST whitelist CloudFlare IP ranges for licensing to work!"
    echo ""
    echo "CloudFlare IPs will be automatically whitelisted if you enable it."
    echo ""

    # Ensure strict mode is still active after sourcing config
    set -Eeuo pipefail

    # Handle CloudFlare whitelist based on configuration
    local cf_mode="${NFTBAN_DIRECTADMIN_AUTO_CLOUDFLARE:-ASK}"
    local _cf_update="${NFTBAN_DIRECTADMIN_UPDATE_CLOUDFLARE:-YES}"  # Reserved for future use
    local enable_cloudflare="no"

    case "$cf_mode" in
        YES|yes|Y|y)
            enable_cloudflare="yes"
            echo "→ CloudFlare whitelist: AUTO-ENABLE (configured)"
            ;;
        NO|no|N|n)
            enable_cloudflare="no"
            echo "→ CloudFlare whitelist: DISABLED (configured)"
            echo "  ⚠️  WARNING: You must manually whitelist CloudFlare IPs!"
            echo "     Run: nftban cloudflare enable"
            ;;
        ASK|ask|A|a|*)
            echo "Do you want to enable CloudFlare IP whitelist? (REQUIRED for licensing)"
            echo -n "Enable CloudFlare whitelist? [Y/n]: "
            read -r response
            case "$response" in
                n|N|no|NO)
                    enable_cloudflare="no"
                    echo "  ⚠️  WARNING: CloudFlare whitelist NOT enabled!"
                    echo "     DirectAdmin licensing may fail!"
                    echo "     Enable later with: nftban cloudflare enable"
                    ;;
                *)
                    enable_cloudflare="yes"
                    echo "  ✓ CloudFlare whitelist will be enabled"
                    ;;
            esac
            ;;
    esac
    echo ""

    # Check if DirectAdmin is installed
    local da_path="${NFTBAN_DIRECTADMIN_PATH:-/usr/local/directadmin}"
    if [[ -d "$da_path" ]]; then
        echo "✓ DirectAdmin detected at: $da_path"
        if [[ -f "$da_path/directadmin" ]]; then
            local da_version
            da_version=$("$da_path/directadmin" v 2>/dev/null | head -1 || echo "Unknown")
            echo "  Version: $da_version"
        fi
    else
        echo "⚠ DirectAdmin not found at: $da_path"
        echo "  Continuing with port configuration anyway..."
    fi
    echo ""

    # Parse port configurations from config or use defaults (from DirectAdmin CSF policy)
    # Note: DirectAdmin uses same ports for IPv4 and IPv6
    local tcp_in="${NFTBAN_DIRECTADMIN_TCP_IN:-20,21,22,25,53,853,80,110,143,443,465,587,993,995,2222,35000-35999}"
    local tcp_out="${NFTBAN_DIRECTADMIN_TCP_OUT:-20,21,22,25,53,853,80,110,113,143,443,465,587,993,995,2222}"
    local udp_in="${NFTBAN_DIRECTADMIN_UDP_IN:-20,21,53,853,80,443}"
    local udp_out="${NFTBAN_DIRECTADMIN_UDP_OUT:-20,21,53,853,113,123,443}"

    # Add custom ports if defined
    [[ -n "${NFTBAN_DIRECTADMIN_CUSTOM_TCP_IN:-}" ]] && tcp_in="${tcp_in},${NFTBAN_DIRECTADMIN_CUSTOM_TCP_IN}"
    [[ -n "${NFTBAN_DIRECTADMIN_CUSTOM_TCP_OUT:-}" ]] && tcp_out="${tcp_out},${NFTBAN_DIRECTADMIN_CUSTOM_TCP_OUT}"
    [[ -n "${NFTBAN_DIRECTADMIN_CUSTOM_UDP_IN:-}" ]] && udp_in="${udp_in},${NFTBAN_DIRECTADMIN_CUSTOM_UDP_IN}"
    [[ -n "${NFTBAN_DIRECTADMIN_CUSTOM_UDP_OUT:-}" ]] && udp_out="${udp_out},${NFTBAN_DIRECTADMIN_CUSTOM_UDP_OUT}"

    echo "Port Configuration (applies to both IPv4 and IPv6):"
    echo "  TCP IN:  $tcp_in"
    echo "  TCP OUT: $tcp_out"
    echo "  UDP IN:  $udp_in"
    echo "  UDP OUT: $udp_out"
    echo ""

    # Convert to arrays
    IFS=',' read -ra tcp_in_ports <<< "$tcp_in"
    IFS=',' read -ra tcp_out_ports <<< "$tcp_out"
    IFS=',' read -ra udp_in_ports <<< "$udp_in"
    IFS=',' read -ra udp_out_ports <<< "$udp_out"

    echo "Opening DirectAdmin ports in nftables..."
    echo ""

    # Check if nftables is running
    # PERFORMANCE FIX: Use 'nft -t list tables' (terse mode) to avoid dumping all IP sets
    if ! nft -t list tables >/dev/null 2>&1; then
        echo "ERROR: nftables is not running or not accessible" >&2
        echo "Please ensure nftables is installed and running" >&2
        return 1
    fi

    # Detect NFTBan table and chains
    # Try multiple table name variations
    local nftban_table_inet=""
    local nftban_table_ip=""
    local nftban_table_ip6=""
    local input_chain="input"
    local output_chain="output"

    # Check which tables exist (try different naming conventions)
    local has_inet=false
    local has_ip=false
    local has_ip6=false

    # Try inet family with different names
    for table_name in nftban nftban_runtime nftban_filter filter; do
        if nft list table inet "$table_name" >/dev/null 2>&1; then
            nftban_table_inet="$table_name"
            has_inet=true
            echo "✓ Found inet table: $table_name"
            break
        fi
    done

    # Try ip family
    for table_name in nftban nftban_filter filter; do
        if nft list table ip "$table_name" >/dev/null 2>&1; then
            nftban_table_ip="$table_name"
            has_ip=true
            echo "✓ Found ip table: $table_name"
            break
        fi
    done

    # Try ip6 family
    for table_name in nftban nftban_filter filter; do
        if nft list table ip6 "$table_name" >/dev/null 2>&1; then
            nftban_table_ip6="$table_name"
            has_ip6=true
            echo "✓ Found ip6 table: $table_name"
            break
        fi
    done

    echo ""

    if [[ "$has_inet" == "false" && "$has_ip" == "false" && "$has_ip6" == "false" ]]; then
        echo "ERROR: No compatible nftables table found" >&2
        echo ""
        echo "Available tables:" >&2
        # PERFORMANCE FIX: Use 'nft -t list tables' (terse mode) for error display
        nft -t list tables 2>&1 | head -10 >&2
        echo "" >&2
        echo "This command requires a firewall table with input/output chains." >&2
        echo "Tried looking for: nftban, nftban_runtime, nftban_filter, filter" >&2
        echo "" >&2
        echo "Please ensure NFTBan firewall is initialized or create manually:" >&2
        echo "  nft add table ${NFTBAN_TABLE_IPV4}" >&2
        echo "  nft add chain ${NFTBAN_TABLE_IPV4} input { type filter hook input priority 0\\; }" >&2
        echo "  nft add chain ${NFTBAN_TABLE_IPV4} output { type filter hook output priority 0\\; }" >&2
        return 1
    fi

    # Detect chain names (could be input/output or input_filter/output_filter, etc.)
    local -A chain_map=()

    # For inet table
    if [[ "$has_inet" == "true" ]]; then
        for chain_try in input input_filter filter_input; do
            if nft list chain inet "$nftban_table_inet" "$chain_try" >/dev/null 2>&1; then
                chain_map["inet_input"]="$chain_try"
                break
            fi
        done
        for chain_try in output output_filter filter_output; do
            if nft list chain inet "$nftban_table_inet" "$chain_try" >/dev/null 2>&1; then
                chain_map["inet_output"]="$chain_try"
                break
            fi
        done

        # If no chains found, create them via IPC
        if [[ -z "${chain_map[inet_input]:-}" ]]; then
            echo "Creating input chain in inet $nftban_table_inet..."
            local chain_fragment="/etc/nftban/rules.d/port-audit-chain-input.nft"
            echo "add chain inet $nftban_table_inet input { type filter hook input priority 0; }" > "$chain_fragment"
            if nft_ipc_apply_ruleset "$chain_fragment" 2>/dev/null; then
                chain_map["inet_input"]="input"
                echo "✓ Created chain: input"
            else
                echo "⚠ Failed to create input chain" >&2
            fi
            rm -f "$chain_fragment" 2>/dev/null
        fi

        if [[ -z "${chain_map[inet_output]:-}" ]]; then
            echo "Creating output chain in inet $nftban_table_inet..."
            local chain_fragment="/etc/nftban/rules.d/port-audit-chain-output.nft"
            echo "add chain inet $nftban_table_inet output { type filter hook output priority 0; }" > "$chain_fragment"
            if nft_ipc_apply_ruleset "$chain_fragment" 2>/dev/null; then
                chain_map["inet_output"]="output"
                echo "✓ Created chain: output"
            else
                echo "⚠ Failed to create output chain" >&2
            fi
            rm -f "$chain_fragment" 2>/dev/null
        fi
    fi

    echo ""

    # Function to add rule if it doesn't exist (via IPC)
    add_port_rule() {
        local family="$1"
        local table="$2"
        local chain="$3"
        local proto="$4"
        local port="$5"
        local direction="$6"  # "dport" or "sport"

        # Check if rule already exists
        if nft list chain "$family" "$table" "$chain" 2>/dev/null | grep -q "$proto $direction $port accept"; then
            return 0  # Rule already exists
        fi

        # Add the rule via IPC
        local rule_fragment="/etc/nftban/rules.d/port-audit-rule-$$.nft"
        echo "add rule $family $table $chain $proto $direction $port counter accept" > "$rule_fragment"
        local result=0
        nft_ipc_apply_ruleset "$rule_fragment" 2>/dev/null || result=1
        rm -f "$rule_fragment" 2>/dev/null
        return $result
    }

    # Bulk add ports (60x faster for large port lists) via IPC
    add_ports_bulk() {
        local family="$1"
        local table="$2"
        local chain="$3"
        local proto="$4"
        local ports="$5"      # Comma-separated list: "20,21,22"
        local direction="$6"   # "dport" or "sport"

        # Convert comma list to nftables set syntax: { 20, 21, 22 }
        local port_set="{ ${ports//,/, } }"

        # Add bulk rule via IPC
        local rule_fragment="/etc/nftban/rules.d/port-audit-bulk-$$.nft"
        echo "add rule $family $table $chain $proto $direction $port_set counter accept" > "$rule_fragment"
        local result=0
        nft_ipc_apply_ruleset "$rule_fragment" 2>/dev/null || result=1
        rm -f "$rule_fragment" 2>/dev/null
        return $result
    }

    local rules_added=0
    local rules_skipped=0
    local rules_failed=0

    # Add TCP INPUT rules
    # Use bulk operation (60x faster for large port lists like DirectAdmin)
    echo "Adding TCP INPUT rules..."

    # If we have many ports (>5), use bulk operation
    if [[ ${#tcp_in_ports[@]} -gt 5 ]]; then
        echo "  Using bulk operation for ${#tcp_in_ports[@]} ports..."

        if [[ "$has_inet" == "true" && -n "${chain_map[inet_input]:-}" ]]; then
            if add_ports_bulk "inet" "$nftban_table_inet" "${chain_map[inet_input]}" "tcp" "$tcp_in" "dport"; then
                echo "  ✓ TCP ports ${tcp_in:0:40}... (inet/${chain_map[inet_input]}) - ${#tcp_in_ports[@]} ports"
                rules_added=$((rules_added + ${#tcp_in_ports[@]}))
            else
                echo "  ⚠ Bulk operation failed, falling back to individual rules..."
                # Fallback to individual rules if bulk fails
                for port in "${tcp_in_ports[@]}"; do
                    [[ -z "$port" ]] && continue
                    if add_port_rule "inet" "$nftban_table_inet" "${chain_map[inet_input]}" "tcp" "$port" "dport"; then
                        rules_added=$((rules_added + 1))
                    else
                        rules_failed=$((rules_failed + 1))
                    fi
                done
            fi
        else
            if [[ "$has_ip" == "true" ]]; then
                if add_ports_bulk "ip" "$nftban_table_ip" "$input_chain" "tcp" "$tcp_in" "dport"; then
                    echo "  ✓ TCP ports ${tcp_in:0:40}... (IPv4/$input_chain) - ${#tcp_in_ports[@]} ports"
                    rules_added=$((rules_added + ${#tcp_in_ports[@]}))
                else
                    rules_failed=$((rules_failed + 1))
                fi
            fi
            if [[ "$has_ip6" == "true" ]]; then
                if add_ports_bulk "ip6" "$nftban_table_ip6" "$input_chain" "tcp" "$tcp_in" "dport"; then
                    echo "  ✓ TCP ports ${tcp_in:0:40}... (IPv6/$input_chain) - ${#tcp_in_ports[@]} ports"
                    rules_added=$((rules_added + ${#tcp_in_ports[@]}))
                else
                    rules_failed=$((rules_failed + 1))
                fi
            fi
        fi
    else
        # Use individual rules for small port lists
        for port in "${tcp_in_ports[@]}"; do
            [[ -z "$port" ]] && continue
            local added_any=false

            if [[ "$has_inet" == "true" && -n "${chain_map[inet_input]:-}" ]]; then
                if add_port_rule "inet" "$nftban_table_inet" "${chain_map[inet_input]}" "tcp" "$port" "dport"; then
                    echo "  ✓ TCP $port (inet/${chain_map[inet_input]})"
                    rules_added=$((rules_added + 1))
                    added_any=true
                else
                    rules_failed=$((rules_failed + 1))
                fi
            else
                if [[ "$has_ip" == "true" ]]; then
                    if add_port_rule "ip" "$nftban_table_ip" "$input_chain" "tcp" "$port" "dport"; then
                        echo "  ✓ TCP $port (IPv4/$input_chain)"
                        rules_added=$((rules_added + 1))
                        added_any=true
                    else
                        rules_failed=$((rules_failed + 1))
                    fi
                fi
                if [[ "$has_ip6" == "true" ]]; then
                    if add_port_rule "ip6" "$nftban_table_ip6" "$input_chain" "tcp" "$port" "dport"; then
                        echo "  ✓ TCP $port (IPv6/$input_chain)"
                        rules_added=$((rules_added + 1))
                        added_any=true
                    else
                        rules_failed=$((rules_failed + 1))
                    fi
                fi
            fi

            [[ "$added_any" == "false" ]] && rules_skipped=$((rules_skipped + 1))
        done
    fi

    # Add TCP OUTPUT rules
    echo ""
    echo "Adding TCP OUTPUT rules..."

    # Use bulk operation for large port lists
    if [[ ${#tcp_out_ports[@]} -gt 5 ]]; then
        echo "  Using bulk operation for ${#tcp_out_ports[@]} ports..."

        if [[ "$has_inet" == "true" && -n "${chain_map[inet_output]:-}" ]]; then
            if add_ports_bulk "inet" "$nftban_table_inet" "${chain_map[inet_output]}" "tcp" "$tcp_out" "dport"; then
                echo "  ✓ TCP ports ${tcp_out:0:40}... (inet/${chain_map[inet_output]}) - ${#tcp_out_ports[@]} ports"
                rules_added=$((rules_added + ${#tcp_out_ports[@]}))
            else
                echo "  ⚠ Bulk operation failed, falling back to individual rules..."
                for port in "${tcp_out_ports[@]}"; do
                    [[ -z "$port" ]] && continue
                    if add_port_rule "inet" "$nftban_table_inet" "${chain_map[inet_output]}" "tcp" "$port" "dport"; then
                        rules_added=$((rules_added + 1))
                    else
                        rules_failed=$((rules_failed + 1))
                    fi
                done
            fi
        else
            if [[ "$has_ip" == "true" ]]; then
                if add_ports_bulk "ip" "$nftban_table_ip" "$output_chain" "tcp" "$tcp_out" "dport"; then
                    echo "  ✓ TCP ports ${tcp_out:0:40}... (IPv4/$output_chain) - ${#tcp_out_ports[@]} ports"
                    rules_added=$((rules_added + ${#tcp_out_ports[@]}))
                else
                    rules_failed=$((rules_failed + 1))
                fi
            fi
            if [[ "$has_ip6" == "true" ]]; then
                if add_ports_bulk "ip6" "$nftban_table_ip6" "$output_chain" "tcp" "$tcp_out" "dport"; then
                    echo "  ✓ TCP ports ${tcp_out:0:40}... (IPv6/$output_chain) - ${#tcp_out_ports[@]} ports"
                    rules_added=$((rules_added + ${#tcp_out_ports[@]}))
                else
                    rules_failed=$((rules_failed + 1))
                fi
            fi
        fi
    else
        # Individual rules for small port lists
        for port in "${tcp_out_ports[@]}"; do
            [[ -z "$port" ]] && continue
            local added_any=false

            if [[ "$has_inet" == "true" && -n "${chain_map[inet_output]:-}" ]]; then
                if add_port_rule "inet" "$nftban_table_inet" "${chain_map[inet_output]}" "tcp" "$port" "dport"; then
                    echo "  ✓ TCP $port (inet/${chain_map[inet_output]})"
                    rules_added=$((rules_added + 1))
                    added_any=true
                else
                    rules_failed=$((rules_failed + 1))
                fi
            else
                if [[ "$has_ip" == "true" ]]; then
                    if add_port_rule "ip" "$nftban_table_ip" "$output_chain" "tcp" "$port" "dport"; then
                        echo "  ✓ TCP $port (IPv4/$output_chain)"
                        rules_added=$((rules_added + 1))
                        added_any=true
                    else
                        rules_failed=$((rules_failed + 1))
                    fi
                fi
                if [[ "$has_ip6" == "true" ]]; then
                    if add_port_rule "ip6" "$nftban_table_ip6" "$output_chain" "tcp" "$port" "dport"; then
                        echo "  ✓ TCP $port (IPv6/$output_chain)"
                        rules_added=$((rules_added + 1))
                        added_any=true
                    else
                        rules_failed=$((rules_failed + 1))
                    fi
                fi
            fi

            [[ "$added_any" == "false" ]] && rules_skipped=$((rules_skipped + 1))
        done
    fi

    # Add UDP rules (DNS)
    echo ""
    echo "Adding UDP rules (DNS)..."
    for port in "${udp_in_ports[@]}"; do
        [[ -z "$port" ]] && continue  # Skip empty ports
        if [[ "$has_inet" == "true" && -n "${chain_map[inet_input]:-}" ]]; then
            if add_port_rule "inet" "$nftban_table_inet" "${chain_map[inet_input]}" "udp" "$port" "dport"; then
                echo "  ✓ UDP $port (inet/${chain_map[inet_input]})"
                rules_added=$((rules_added + 1))
            else
                rules_failed=$((rules_failed + 1))
            fi
        else
            if [[ "$has_ip" == "true" ]]; then
                if add_port_rule "ip" "$nftban_table_ip" "$input_chain" "udp" "$port" "dport"; then
                    echo "  ✓ UDP $port (IPv4/$input_chain)"
                    rules_added=$((rules_added + 1))
                else
                    rules_failed=$((rules_failed + 1))
                fi
            fi
            if [[ "$has_ip6" == "true" ]]; then
                if add_port_rule "ip6" "$nftban_table_ip6" "$input_chain" "udp" "$port" "dport"; then
                    echo "  ✓ UDP $port (IPv6/$input_chain)"
                    rules_added=$((rules_added + 1))
                else
                    rules_failed=$((rules_failed + 1))
                fi
            fi
        fi
    done

    for port in "${udp_out_ports[@]}"; do
        [[ -z "$port" ]] && continue  # Skip empty ports
        if [[ "$has_inet" == "true" && -n "${chain_map[inet_output]:-}" ]]; then
            if add_port_rule "inet" "$nftban_table_inet" "${chain_map[inet_output]}" "udp" "$port" "dport"; then
                echo "  ✓ UDP $port (inet/${chain_map[inet_output]})"
                rules_added=$((rules_added + 1))
            else
                rules_failed=$((rules_failed + 1))
            fi
        else
            if [[ "$has_ip" == "true" ]]; then
                if add_port_rule "ip" "$nftban_table_ip" "$output_chain" "udp" "$port" "dport"; then
                    echo "  ✓ UDP $port (IPv4/$output_chain)"
                    rules_added=$((rules_added + 1))
                else
                    rules_failed=$((rules_failed + 1))
                fi
            fi
            if [[ "$has_ip6" == "true" ]]; then
                if add_port_rule "ip6" "$nftban_table_ip6" "$output_chain" "udp" "$port" "dport"; then
                    echo "  ✓ UDP $port (IPv6/$output_chain)"
                    rules_added=$((rules_added + 1))
                else
                    rules_failed=$((rules_failed + 1))
                fi
            fi
        fi
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Summary:"
    echo "  Rules added:   $rules_added"
    echo "  Rules skipped: $rules_skipped (already exist)"
    echo "  Rules failed:  $rules_failed"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [[ $rules_failed -gt 0 ]]; then
        echo "⚠ Some rules failed to add. Check nftables configuration."
        return 1
    fi

    echo "✅ DirectAdmin ports configured successfully"
    echo ""
    echo "Key ports opened (IPv4 and IPv6):"
    echo "  • 2222 (TCP)       - DirectAdmin Web Panel"
    echo "  • 22 (TCP)         - SSH"
    echo "  • 80/443           - HTTP/HTTPS (TCP + UDP for QUIC/HTTP3)"
    echo "  • 25/587/465       - SMTP/Submission"
    echo "  • 20/21            - FTP (TCP + UDP)"
    echo "  • 35000-35999 (TCP) - Passive FTP range"
    echo "  • 53               - DNS (TCP + UDP)"
    echo "  • 853              - DNS over TLS"
    echo "  • 993/995          - IMAPS/POP3S"
    echo "  • 110/143          - POP3/IMAP"
    echo "  • 123 (UDP OUT)    - NTP"
    echo ""

    # Handle CloudFlare whitelist
    if [[ "$enable_cloudflare" == "yes" ]]; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Enabling CloudFlare IP Whitelist"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""

        # Enable CloudFlare whitelist via trust command (uses native Go HTTP)
        echo "Enabling CloudFlare whitelist..."
        if nftban trust enable CLOUDFLARE 2>/dev/null && nftban trust update 2>/dev/null; then
            echo "✓ CloudFlare whitelist enabled"
            echo ""
            echo "CloudFlare IP ranges are now whitelisted for DirectAdmin licensing."
        else
            echo "⚠️  Failed to enable CloudFlare whitelist"
            echo "   Please enable manually: nftban trust enable CLOUDFLARE && nftban trust update"
        fi
        echo ""
    else
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "⚠️  CloudFlare Whitelist NOT Enabled"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "DirectAdmin licensing REQUIRES CloudFlare IP whitelist!"
        echo ""
        echo "To enable CloudFlare whitelist:"
        echo "  nftban trust enable CLOUDFLARE"
        echo "  nftban trust update"
        echo ""
        echo "Or run this command again and select 'Yes' when prompted."
        echo ""
    fi

    echo "To verify port status, run:"
    echo "  nftban port status"
    echo ""

    # Run autoheal to fix any permission issues
    if command -v nftban >/dev/null 2>&1; then
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Running autoheal to fix permissions..."
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        nftban permissions fix 2>/dev/null || true
        echo ""
    fi

    # Note: fail2ban integration removed in v1.0 (replaced by Suricata IDS and built-in login monitoring)

    # Exit marker for testing validation
    command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "port"
    return 0
}

# Export function for auto-loading
export -f nftban_cmd_port
export -f nftban_port_allow_directadmin
