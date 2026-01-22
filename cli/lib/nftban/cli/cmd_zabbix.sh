#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Zabbix Integration CLI
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI commands for Zabbix metrics integration
#
# meta:name="cmd_zabbix"
# meta:type="cli"
# meta:header="Zabbix Integration"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description & Purpose**
# meta:description="Manage Zabbix trapper metrics integration"
# meta:input="Subcommands (setup, status, test, push, template, discover, targets, config)"
# meta:output="Zabbix integration status and configuration"
#
# **Inventory & Requirements**
# meta:depends="systemd,zabbix-sender(optional)"
# meta:inventory.files=""
# meta:inventory.binaries="zabbix_sender(optional)"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="nftban-zabbix-exporter.timer"
# meta:inventory.network="10051/tcp"
# meta:inventory.privileges="root"
#
# meta:created_date="2026-01-22"
# meta:updated_date="2026-01-22"
# =============================================================================

set -Eeuo pipefail

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"
readonly NFTBAN_CONFIG_DIR="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
readonly NFTBAN_SHARE_DIR="${NFTBAN_SHARE_DIR:-/usr/share/nftban}"

# Load main config
if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_CONFIG_DIR}/nftban.conf"
fi

# Load output module for banner and styling
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
fi

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

_zabbix_config_get() {
    # Get a Zabbix config value from nftban.conf
    local key="$1"
    local default="${2:-}"
    local value=""

    if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
        value=$(grep -E "^${key}=" "${NFTBAN_CONFIG_DIR}/nftban.conf" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
    fi

    echo "${value:-$default}"
}

_zabbix_config_set() {
    # Set a Zabbix config value in nftban.conf
    local key="$1"
    local value="$2"
    local conf_file="${NFTBAN_CONFIG_DIR}/nftban.conf"

    if [[ ! -f "$conf_file" ]]; then
        echo "ERROR: Config file not found: $conf_file" >&2
        return 1
    fi

    # If key exists, update it; otherwise append
    if grep -qE "^${key}=" "$conf_file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$conf_file"
    else
        echo "${key}=\"${value}\"" >> "$conf_file"
    fi
}

_zabbix_print_header() {
    local title="$1"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $title"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

_zabbix_print_success() {
    echo "✅ $1"
}

_zabbix_print_error() {
    echo "❌ $1" >&2
}

_zabbix_print_warning() {
    echo "⚠️  $1"
}

_zabbix_print_info() {
    echo "ℹ️  $1"
}

# Firewall helper: Allow outbound traffic to Zabbix server
_zabbix_firewall_allow() {
    local server="$1"
    local port="$2"

    # Resolve hostname to IP if needed
    local server_ip
    if [[ "$server" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        server_ip="$server"
    else
        server_ip=$(getent hosts "$server" 2>/dev/null | awk '{print $1}' | head -1)
        [[ -z "$server_ip" ]] && server_ip=$(host "$server" 2>/dev/null | awk '/has address/ {print $4}' | head -1)
    fi

    [[ -z "$server_ip" ]] && return 1

    # Check if rule already exists
    if nft list chain inet nftban output 2>/dev/null | grep -q "daddr $server_ip.*dport $port"; then
        return 0  # Already exists
    fi

    # Add outbound rule to nftban output chain
    # Use handle-based insertion for proper priority
    if nft add rule inet nftban output ip daddr "$server_ip" tcp dport "$port" accept comment \"zabbix-export\" 2>/dev/null; then
        return 0
    fi

    # Fallback: Try ip family if inet doesn't exist
    if nft add rule ip nftban output ip daddr "$server_ip" tcp dport "$port" accept comment \"zabbix-export\" 2>/dev/null; then
        return 0
    fi

    return 1
}

# Firewall helper: Remove Zabbix outbound rule
_zabbix_firewall_remove() {
    local server="$1"
    local port="$2"

    # Resolve hostname to IP
    local server_ip
    if [[ "$server" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        server_ip="$server"
    else
        server_ip=$(getent hosts "$server" 2>/dev/null | awk '{print $1}' | head -1)
    fi

    [[ -z "$server_ip" ]] && return 1

    # Find and delete rule with zabbix-export comment
    local handle
    handle=$(nft -a list chain inet nftban output 2>/dev/null | grep "zabbix-export" | grep -oP 'handle \K\d+')

    if [[ -n "$handle" ]]; then
        nft delete rule inet nftban output handle "$handle" 2>/dev/null && return 0
    fi

    # Try ip family
    handle=$(nft -a list chain ip nftban output 2>/dev/null | grep "zabbix-export" | grep -oP 'handle \K\d+')
    if [[ -n "$handle" ]]; then
        nft delete rule ip nftban output handle "$handle" 2>/dev/null && return 0
    fi

    return 1
}

# =============================================================================
# Command: nftban zabbix setup
# =============================================================================
_cmd_zabbix_setup() {
    local server=""
    local port="10051"
    local hostname="auto"
    local tls="false"
    local psk="false"
    local interactive="true"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server)   server="$2"; shift 2 ;;
            --server=*) server="${1#*=}"; shift ;;
            --port)     port="$2"; shift 2 ;;
            --port=*)   port="${1#*=}"; shift ;;
            --hostname) hostname="$2"; shift 2 ;;
            --hostname=*) hostname="${1#*=}"; shift ;;
            --tls)      tls="true"; shift ;;
            --psk)      psk="true"; shift ;;
            --non-interactive) interactive="false"; shift ;;
            *)          shift ;;
        esac
    done

    if [[ "$interactive" == "true" && -z "$server" ]]; then
        _zabbix_print_header "NFTBan Zabbix Setup Wizard"

        echo "This wizard will configure NFTBan to push metrics to your Zabbix server."
        echo ""

        read -rp "Zabbix Server address: " server
        read -rp "Zabbix Server port [10051]: " port_input
        port="${port_input:-10051}"
        read -rp "Hostname to report [auto]: " hostname_input
        hostname="${hostname_input:-auto}"

        read -rp "Enable TLS encryption? [y/N]: " tls_answer
        [[ "$tls_answer" =~ ^[Yy] ]] && tls="true"

        if [[ "$tls" != "true" ]]; then
            read -rp "Enable PSK authentication? [y/N]: " psk_answer
            [[ "$psk_answer" =~ ^[Yy] ]] && psk="true"
        fi
    fi

    # Validate
    if [[ -z "$server" ]]; then
        _zabbix_print_error "Zabbix server address required"
        return 1
    fi

    # Auto-detect hostname if needed
    if [[ "$hostname" == "auto" ]]; then
        hostname=$(hostname -f 2>/dev/null || hostname)
    fi

    # Write config
    _zabbix_print_info "Saving configuration..."
    _zabbix_config_set "NFTBAN_ZABBIX_ENABLED" "true"
    _zabbix_config_set "NFTBAN_ZABBIX_SERVER" "$server"
    _zabbix_config_set "NFTBAN_ZABBIX_PORT" "$port"
    _zabbix_config_set "NFTBAN_ZABBIX_HOSTNAME" "$hostname"
    _zabbix_config_set "NFTBAN_ZABBIX_TLS_ENABLED" "$tls"
    _zabbix_config_set "NFTBAN_ZABBIX_PSK_ENABLED" "$psk"

    # Configure firewall for outbound Zabbix traffic
    local firewall_auto
    firewall_auto=$(_zabbix_config_get "NFTBAN_ZABBIX_FIREWALL_AUTO" "true")
    if [[ "$firewall_auto" == "true" ]]; then
        _zabbix_print_info "Configuring firewall for outbound traffic to $server:$port..."
        if _zabbix_firewall_allow "$server" "$port"; then
            _zabbix_print_success "Firewall rule added"
        else
            _zabbix_print_warning "Could not add firewall rule (manual setup may be required)"
        fi
    fi

    # Enable unified exporter timer
    _zabbix_print_info "Enabling unified exporter timer..."
    if systemctl enable --now nftban-unified-exporter.timer 2>/dev/null; then
        _zabbix_print_success "Timer enabled"
    else
        _zabbix_print_warning "Could not enable timer (run: systemctl enable --now nftban-unified-exporter.timer)"
    fi

    # Test connection
    echo ""
    _zabbix_print_info "Testing connection..."
    if _cmd_zabbix_test --quiet; then
        _zabbix_print_success "Zabbix integration configured successfully"
        echo ""
        echo "Configuration saved to: ${NFTBAN_CONFIG_DIR}/nftban.conf"
        echo ""
        echo "Next steps:"
        echo "  1. Import template: nftban zabbix template --version 6.0 --output /tmp/nftban.yaml"
        echo "  2. Link template to host in Zabbix UI"
        echo "  3. Verify: nftban zabbix status"
    else
        _zabbix_print_warning "Configuration saved but connection test failed"
        echo ""
        echo "Troubleshooting:"
        echo "  - Check server address and port"
        echo "  - Verify firewall allows port $port"
        echo "  - Ensure Zabbix server is running"
        echo "  - Run: nftban zabbix test --verbose"
    fi
}

# =============================================================================
# Command: nftban zabbix status
# =============================================================================
_cmd_zabbix_status() {
    local json="false"
    local verbose="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)    json="true"; shift ;;
            --verbose) verbose="true"; shift ;;
            *)         shift ;;
        esac
    done

    # Load config values
    local enabled server port hostname interval tls psk
    enabled=$(_zabbix_config_get "NFTBAN_ZABBIX_ENABLED" "false")
    server=$(_zabbix_config_get "NFTBAN_ZABBIX_SERVER" "")
    port=$(_zabbix_config_get "NFTBAN_ZABBIX_PORT" "10051")
    hostname=$(_zabbix_config_get "NFTBAN_ZABBIX_HOSTNAME" "auto")
    interval=$(_zabbix_config_get "NFTBAN_ZABBIX_INTERVAL" "60")
    tls=$(_zabbix_config_get "NFTBAN_ZABBIX_TLS_ENABLED" "false")
    psk=$(_zabbix_config_get "NFTBAN_ZABBIX_PSK_ENABLED" "false")

    # Get actual hostname if auto
    local actual_hostname="$hostname"
    if [[ "$hostname" == "auto" ]]; then
        actual_hostname=$(hostname -f 2>/dev/null || hostname)
    fi

    if [[ "$json" == "true" ]]; then
        cat <<EOF
{
  "enabled": $enabled,
  "server": "$server",
  "port": $port,
  "hostname": "$actual_hostname",
  "interval": $interval,
  "tls_enabled": $tls,
  "psk_enabled": $psk
}
EOF
        return 0
    fi

    _zabbix_print_header "NFTBan Zabbix Integration Status"

    echo "Configuration:"
    if [[ "$enabled" == "true" ]]; then
        echo "  Enabled:    ✅ true"
    else
        echo "  Enabled:    ❌ false"
    fi
    echo "  Server:     ${server:-not configured}:$port"
    echo "  Hostname:   $actual_hostname"
    echo "  Interval:   ${interval}s"
    echo "  TLS:        $tls"
    echo "  PSK:        $psk"
    echo ""

    # Check exporter timer status
    echo "Exporter Service:"
    if systemctl is-active nftban-zabbix-exporter.timer &>/dev/null; then
        echo "  Timer:      ✅ Active"
        local last_run
        last_run=$(systemctl show nftban-zabbix-exporter.timer -p LastTriggerUSec --value 2>/dev/null || echo "n/a")
        if [[ -n "$last_run" ]] && [[ "$last_run" != "n/a" ]]; then
            echo "  Last run:   $(date -d "$last_run" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$last_run")"
        fi
    elif systemctl list-unit-files nftban-zabbix-exporter.timer &>/dev/null 2>&1; then
        echo "  Timer:      ⚠️  Installed but not active"
        echo "              Enable with: systemctl enable --now nftban-zabbix-exporter.timer"
    else
        echo "  Timer:      ℹ️  Not installed (using bash fallback)"
    fi
    echo ""

    # Check zabbix_sender availability
    echo "Dependencies:"
    if command -v zabbix_sender &>/dev/null; then
        local sender_version
        sender_version=$(zabbix_sender -V 2>&1 | head -1 || echo "unknown")
        echo "  zabbix_sender: ✅ $sender_version"
    else
        echo "  zabbix_sender: ⚠️  Not installed (using native protocol)"
        echo "                 Install: apt install zabbix-sender  # or yum/dnf"
    fi
    echo ""
}

# =============================================================================
# Command: nftban zabbix test
# =============================================================================
_cmd_zabbix_test() {
    local verbose="false"
    local dry_run="false"
    local quiet="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose) verbose="true"; shift ;;
            --dry-run) dry_run="true"; shift ;;
            --quiet)   quiet="true"; shift ;;
            *)         shift ;;
        esac
    done

    local server port hostname
    server=$(_zabbix_config_get "NFTBAN_ZABBIX_SERVER" "")
    port=$(_zabbix_config_get "NFTBAN_ZABBIX_PORT" "10051")
    hostname=$(_zabbix_config_get "NFTBAN_ZABBIX_HOSTNAME" "auto")

    if [[ -z "$server" ]]; then
        [[ "$quiet" != "true" ]] && _zabbix_print_error "Zabbix server not configured"
        [[ "$quiet" != "true" ]] && echo "Run: nftban zabbix setup"
        return 1
    fi

    [[ "$quiet" != "true" ]] && _zabbix_print_info "Testing Zabbix connection to $server:$port..."

    # Step 1: DNS resolution
    [[ "$verbose" == "true" ]] && echo "[1/4] Resolving $server..."
    if ! host "$server" &>/dev/null && ! getent hosts "$server" &>/dev/null; then
        [[ "$quiet" != "true" ]] && _zabbix_print_error "Cannot resolve $server"
        return 1
    fi
    [[ "$verbose" == "true" ]] && echo "      ✅ OK"

    # Step 2: TCP connection
    [[ "$verbose" == "true" ]] && echo "[2/4] Connecting to $server:$port..."
    if ! timeout 5 bash -c "echo >/dev/tcp/$server/$port" 2>/dev/null; then
        [[ "$quiet" != "true" ]] && _zabbix_print_error "Cannot connect to $server:$port"
        [[ "$quiet" != "true" ]] && echo "Check: firewall, Zabbix server status, port configuration"
        return 1
    fi
    [[ "$verbose" == "true" ]] && echo "      ✅ OK"

    # Step 3: Send test metric
    if [[ "$dry_run" != "true" ]]; then
        [[ "$verbose" == "true" ]] && echo "[3/4] Sending test metric..."

        # Resolve hostname if auto
        if [[ "$hostname" == "auto" ]]; then
            hostname=$(hostname -f 2>/dev/null || hostname)
        fi

        if command -v zabbix_sender &>/dev/null; then
            local result
            result=$(zabbix_sender -z "$server" -p "$port" -s "$hostname" \
                -k "nftban.test" -o "1" 2>&1) || true

            if echo "$result" | grep -q "processed: 1"; then
                [[ "$verbose" == "true" ]] && echo "      ✅ OK (metric accepted)"
            elif echo "$result" | grep -q "failed: 0"; then
                [[ "$verbose" == "true" ]] && echo "      ⚠️  Sent (item may not exist in Zabbix)"
            else
                [[ "$quiet" != "true" ]] && _zabbix_print_warning "Test metric sent but may not be processed"
                [[ "$verbose" == "true" ]] && echo "      Response: $result"
            fi
        else
            [[ "$verbose" == "true" ]] && echo "      ⚠️  Skipped (zabbix_sender not installed)"
        fi
    else
        [[ "$verbose" == "true" ]] && echo "[3/4] Dry run - skipping metric send"
    fi

    [[ "$verbose" == "true" ]] && echo "[4/4] Test complete"

    [[ "$quiet" != "true" ]] && _zabbix_print_success "Zabbix connection test passed"
    return 0
}

# =============================================================================
# Command: nftban zabbix push
# =============================================================================
_cmd_zabbix_push() {
    local dry_run="false"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry_run="true"; shift ;;
            *)         shift ;;
        esac
    done

    _zabbix_print_info "Forcing metric push to Zabbix..."

    # Check if configured
    local server hostname
    server=$(_zabbix_config_get "NFTBAN_ZABBIX_SERVER" "")
    hostname=$(_zabbix_config_get "NFTBAN_ZABBIX_HOSTNAME" "auto")

    if [[ -z "$server" ]]; then
        _zabbix_print_error "Zabbix not configured"
        echo "Run: nftban zabbix setup"
        return 1
    fi

    # Resolve hostname if auto
    if [[ "$hostname" == "auto" ]]; then
        hostname=$(hostname -f 2>/dev/null || hostname)
    fi

    # Use bash exporter
    local exporter="${NFTBAN_LIB_DIR}/exporters/nftban_zabbix_exporter.sh"

    if [[ -x "$exporter" ]]; then
        if [[ "$dry_run" == "true" ]]; then
            echo ""
            echo "Dry run - would execute: $exporter"
            "$exporter" --dry-run 2>/dev/null || "$exporter"
        else
            "$exporter"
            local exit_code=$?
            if [[ $exit_code -eq 0 ]]; then
                _zabbix_print_success "Metrics pushed successfully"
            else
                _zabbix_print_error "Push failed (exit code: $exit_code)"
                return $exit_code
            fi
        fi
    else
        _zabbix_print_warning "Exporter not found: $exporter"
        echo "Creating basic metric push..."

        # Fallback: push basic metrics directly
        if command -v zabbix_sender &>/dev/null; then
            local port
            port=$(_zabbix_config_get "NFTBAN_ZABBIX_PORT" "10051")

            # Collect basic metrics
            local version bans_total
            version=$(cat /etc/nftban/VERSION 2>/dev/null || echo "unknown")
            bans_total=$(nft list set inet nftban blacklist_ipv4 2>/dev/null | grep -c "elements" || echo "0")

            echo "Sending basic metrics..."
            zabbix_sender -z "$server" -p "$port" -s "$hostname" \
                -k "nftban.version" -o "$version" \
                -k "nftban.active.count" -o "$bans_total"

            _zabbix_print_success "Basic metrics pushed"
        else
            _zabbix_print_error "zabbix_sender not installed and exporter not found"
            return 1
        fi
    fi
}

# =============================================================================
# Command: nftban zabbix template
# =============================================================================
_cmd_zabbix_template() {
    local format="xml"
    local version="5.0"
    local output=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format)  format="$2"; shift 2 ;;
            --format=*) format="${1#*=}"; shift ;;
            --version) version="$2"; shift 2 ;;
            --version=*) version="${1#*=}"; shift ;;
            --output)  output="$2"; shift 2 ;;
            --output=*) output="${1#*=}"; shift ;;
            *)         shift ;;
        esac
    done

    local template_dir="${NFTBAN_SHARE_DIR}/templates/zabbix"
    local template_file=""

    # Determine template file based on version
    case "$version" in
        5.0|5.2|5.4)
            template_file="$template_dir/nftban_template_5x.xml"
            format="xml"  # Force XML for 5.x
            ;;
        6.0|6.2|6.4|7.0)
            if [[ "$format" == "yaml" ]]; then
                template_file="$template_dir/nftban_template_6x.yaml"
            else
                template_file="$template_dir/nftban_template_6x.xml"
            fi
            ;;
        *)
            _zabbix_print_error "Unknown Zabbix version: $version"
            echo "Supported versions: 5.0, 5.2, 5.4, 6.0, 6.2, 6.4, 7.0"
            return 1
            ;;
    esac

    if [[ ! -f "$template_file" ]]; then
        _zabbix_print_warning "Template not found: $template_file"
        echo ""
        echo "Templates will be available after HELPER-1 completes template creation."
        echo "Expected locations:"
        echo "  - $template_dir/nftban_template_5x.xml"
        echo "  - $template_dir/nftban_template_6x.yaml"
        echo ""
        echo "For now, you can:"
        echo "  1. Wait for template files to be created"
        echo "  2. Download from: https://nftban.com/downloads/zabbix/"
        return 1
    fi

    if [[ -n "$output" ]]; then
        cp "$template_file" "$output"
        _zabbix_print_success "Template exported to: $output"
        echo ""
        echo "Import this file in Zabbix UI:"
        echo "  Configuration → Templates → Import"
    else
        cat "$template_file"
    fi
}

# =============================================================================
# Command: nftban zabbix discover
# =============================================================================
_cmd_zabbix_discover() {
    local type="${1:-all}"

    case "$type" in
        modules)
            echo '{"data":['
            local first=true
            for module in login portscan ddos feeds geoban suricata; do
                local enabled="0"
                if [[ -f "${NFTBAN_CONFIG_DIR}/modules/${module}.conf" ]]; then
                    enabled="1"
                fi
                [[ "$first" != "true" ]] && echo ","
                echo "{\"{\#MODULE}\":\"$module\",\"{\#ENABLED}\":\"$enabled\"}"
                first=false
            done
            echo ']}'
            ;;
        interfaces)
            echo '{"data":['
            local first=true
            for iface in $(ip -o link show | awk -F': ' '{print $2}' | grep -v "^lo$"); do
                [[ "$first" != "true" ]] && echo ","
                echo "{\"{\#IFACE}\":\"$iface\"}"
                first=false
            done
            echo ']}'
            ;;
        countries)
            echo '{"data":['
            # Get blocked countries from geoban config
            if [[ -f "${NFTBAN_CONFIG_DIR}/modules/geoban.conf" ]]; then
                source "${NFTBAN_CONFIG_DIR}/modules/geoban.conf"
                local first=true
                for country in ${NFTBAN_GEOBAN_COUNTRIES:-}; do
                    [[ "$first" != "true" ]] && echo ","
                    echo "{\"{\#COUNTRY}\":\"$country\",\"{\#BLOCKED}\":\"1\"}"
                    first=false
                done
            fi
            echo ']}'
            ;;
        feeds)
            echo '{"data":['
            local first=true
            if [[ -d "${NFTBAN_CONFIG_DIR}/feeds" ]]; then
                for feed_file in "${NFTBAN_CONFIG_DIR}/feeds"/*.conf; do
                    [[ -f "$feed_file" ]] || continue
                    local feed_name
                    feed_name=$(basename "$feed_file" .conf)
                    [[ "$first" != "true" ]] && echo ","
                    echo "{\"{\#FEED}\":\"$feed_name\",\"{\#ENABLED}\":\"1\"}"
                    first=false
                done
            fi
            echo ']}'
            ;;
        timers)
            echo '{"data":['
            local first=true
            for timer in 1h 6h 24h 7d 30d permanent; do
                [[ "$first" != "true" ]] && echo ","
                echo "{\"{\#TIMER}\":\"$timer\"}"
                first=false
            done
            echo ']}'
            ;;
        --all|all)
            echo "Available discovery types:"
            echo ""
            for t in modules interfaces countries feeds timers; do
                echo "=== $t ==="
                _cmd_zabbix_discover "$t"
                echo ""
            done
            ;;
        *)
            _zabbix_print_error "Unknown discovery type: $type"
            echo "Valid types: modules, interfaces, countries, feeds, timers, --all"
            return 1
            ;;
    esac
}

# =============================================================================
# Command: nftban zabbix targets
# =============================================================================
_cmd_zabbix_targets() {
    local action="${1:-list}"
    shift || true

    case "$action" in
        list)
            _zabbix_print_header "Zabbix Targets"
            printf "%-15s %-30s %-10s %-15s\n" "Name" "Server" "Status" "Filter"
            echo "─────────────────────────────────────────────────────────────────────"

            # Primary target
            local server port enabled
            server=$(_zabbix_config_get "NFTBAN_ZABBIX_SERVER" "")
            port=$(_zabbix_config_get "NFTBAN_ZABBIX_PORT" "10051")
            enabled=$(_zabbix_config_get "NFTBAN_ZABBIX_ENABLED" "false")

            if [[ -n "$server" ]]; then
                local status="disabled"
                [[ "$enabled" == "true" ]] && status="enabled"
                printf "%-15s %-30s %-10s %-15s\n" "primary" "${server}:${port}" "$status" "all"
            fi

            # Additional targets (multi-target support)
            local i=1
            while true; do
                local name target_server target_port target_enabled target_filter
                name=$(_zabbix_config_get "NFTBAN_ZABBIX_TARGET_${i}_NAME" "")
                [[ -z "$name" ]] && break

                target_server=$(_zabbix_config_get "NFTBAN_ZABBIX_TARGET_${i}_SERVER" "")
                target_port=$(_zabbix_config_get "NFTBAN_ZABBIX_TARGET_${i}_PORT" "10051")
                target_enabled=$(_zabbix_config_get "NFTBAN_ZABBIX_TARGET_${i}_ENABLED" "false")
                target_filter=$(_zabbix_config_get "NFTBAN_ZABBIX_TARGET_${i}_FILTER" "all")

                local status="disabled"
                [[ "$target_enabled" == "true" ]] && status="enabled"
                printf "%-15s %-30s %-10s %-15s\n" "$name" "${target_server}:${target_port}" "$status" "$target_filter"
                ((i++))
            done

            if [[ -z "$server" ]] && [[ $i -eq 1 ]]; then
                echo "No targets configured."
                echo ""
                echo "Setup primary target: nftban zabbix setup"
                echo "Add additional:       nftban zabbix targets add NAME --server HOST"
            fi
            echo ""
            ;;
        add)
            local name="$1"
            shift || { _zabbix_print_error "Target name required"; return 1; }

            # Find next available slot
            local i=1
            while [[ -n "$(_zabbix_config_get "NFTBAN_ZABBIX_TARGET_${i}_NAME" "")" ]]; do
                ((i++))
            done

            # Parse options
            local server="" port="10051" filter="all"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --server) server="$2"; shift 2 ;;
                    --server=*) server="${1#*=}"; shift ;;
                    --port)   port="$2"; shift 2 ;;
                    --port=*) port="${1#*=}"; shift ;;
                    --filter) filter="$2"; shift 2 ;;
                    --filter=*) filter="${1#*=}"; shift ;;
                    *)        shift ;;
                esac
            done

            [[ -z "$server" ]] && { _zabbix_print_error "--server required"; return 1; }

            _zabbix_config_set "NFTBAN_ZABBIX_TARGET_${i}_NAME" "$name"
            _zabbix_config_set "NFTBAN_ZABBIX_TARGET_${i}_SERVER" "$server"
            _zabbix_config_set "NFTBAN_ZABBIX_TARGET_${i}_PORT" "$port"
            _zabbix_config_set "NFTBAN_ZABBIX_TARGET_${i}_ENABLED" "true"
            _zabbix_config_set "NFTBAN_ZABBIX_TARGET_${i}_FILTER" "$filter"

            _zabbix_print_success "Added target: $name ($server:$port)"
            ;;
        enable|disable)
            local name="$1"
            [[ -z "$name" ]] && { _zabbix_print_error "Target name required"; return 1; }

            # Handle primary target
            if [[ "$name" == "primary" ]]; then
                local value="true"
                [[ "$action" == "disable" ]] && value="false"
                _zabbix_config_set "NFTBAN_ZABBIX_ENABLED" "$value"
                _zabbix_print_success "Primary target ${action}d"
                return 0
            fi

            # Handle additional targets
            local i=1
            while true; do
                local tname
                tname=$(_zabbix_config_get "NFTBAN_ZABBIX_TARGET_${i}_NAME" "")
                [[ -z "$tname" ]] && { _zabbix_print_error "Target not found: $name"; return 1; }

                if [[ "$tname" == "$name" ]]; then
                    local value="true"
                    [[ "$action" == "disable" ]] && value="false"
                    _zabbix_config_set "NFTBAN_ZABBIX_TARGET_${i}_ENABLED" "$value"
                    _zabbix_print_success "Target $name ${action}d"
                    return 0
                fi
                ((i++))
            done
            ;;
        remove)
            local name="$1"
            [[ -z "$name" ]] && { _zabbix_print_error "Target name required"; return 1; }

            _zabbix_print_warning "Target removal not yet implemented"
            echo "For now, disable the target: nftban zabbix targets disable $name"
            ;;
        *)
            _zabbix_print_error "Unknown action: $action"
            echo "Valid actions: list, add, enable, disable, remove"
            return 1
            ;;
    esac
}

# =============================================================================
# Command: nftban zabbix config
# =============================================================================
_cmd_zabbix_config() {
    local action="${1:-show}"
    shift || true

    case "$action" in
        show)
            _zabbix_print_header "Zabbix Configuration"
            grep -E "^NFTBAN_ZABBIX_" "${NFTBAN_CONFIG_DIR}/nftban.conf" 2>/dev/null || echo "No Zabbix configuration found"
            echo ""
            ;;
        set)
            local key="$1"
            local value="$2"
            [[ -z "$key" || -z "$value" ]] && { _zabbix_print_error "Usage: nftban zabbix config set KEY VALUE"; return 1; }

            # Prefix with NFTBAN_ZABBIX_ if not already
            [[ "$key" != NFTBAN_ZABBIX_* ]] && key="NFTBAN_ZABBIX_$key"

            _zabbix_config_set "$key" "$value"
            _zabbix_print_success "Set $key = $value"
            ;;
        enable)
            _zabbix_config_set "NFTBAN_ZABBIX_ENABLED" "true"
            _zabbix_print_success "Zabbix integration enabled"
            ;;
        disable)
            # Remove firewall rule if it was auto-configured
            local server port firewall_auto
            server=$(_zabbix_config_get "NFTBAN_ZABBIX_SERVER" "")
            port=$(_zabbix_config_get "NFTBAN_ZABBIX_PORT" "10051")
            firewall_auto=$(_zabbix_config_get "NFTBAN_ZABBIX_FIREWALL_AUTO" "true")

            if [[ "$firewall_auto" == "true" ]] && [[ -n "$server" ]]; then
                _zabbix_print_info "Removing firewall rule..."
                _zabbix_firewall_remove "$server" "$port" && _zabbix_print_success "Firewall rule removed"
            fi

            _zabbix_config_set "NFTBAN_ZABBIX_ENABLED" "false"
            _zabbix_print_success "Zabbix integration disabled"
            ;;
        *)
            _zabbix_print_error "Unknown action: $action"
            echo "Valid actions: show, set, enable, disable"
            return 1
            ;;
    esac
}

# =============================================================================
# Command: nftban zabbix help
# =============================================================================
_cmd_zabbix_help() {
    cat <<'EOF'
NFTBan Zabbix Integration

USAGE:
    nftban zabbix <command> [options]

COMMANDS:
    setup               Interactive setup wizard
    status              Show integration status
    test                Test Zabbix connectivity
    push                Force immediate metric push
    template            Export Zabbix template
    discover            Run LLD discovery
    targets             Manage multiple Zabbix targets
    config              Show/modify configuration
    help                Show this help

SETUP OPTIONS:
    --server HOST       Zabbix server address
    --port PORT         Zabbix server port (default: 10051)
    --hostname NAME     Hostname to report (default: auto)
    --tls               Enable TLS encryption
    --psk               Enable PSK authentication
    --non-interactive   Non-interactive mode (require --server)

STATUS OPTIONS:
    --json              Output in JSON format
    --verbose           Show detailed information

TEST OPTIONS:
    --verbose           Show step-by-step progress
    --dry-run           Don't send test metric
    --quiet             Suppress output (exit code only)

PUSH OPTIONS:
    --all               Push all metrics (including discovery)
    --dry-run           Show what would be sent

TEMPLATE OPTIONS:
    --format xml|yaml   Output format (default: xml)
    --version VER       Zabbix version (5.0, 6.0, 7.0, etc.)
    --output FILE       Save to file instead of stdout

DISCOVER TYPES:
    modules             Discover enabled modules
    interfaces          Discover network interfaces
    countries           Discover geo-blocked countries
    feeds               Discover threat feeds
    timers              Discover ban timer durations
    --all               Discover all types

TARGETS OPTIONS:
    list                List configured targets
    add NAME            Add new target (requires --server)
    enable NAME         Enable target
    disable NAME        Disable target
    remove NAME         Remove target

CONFIG OPTIONS:
    show                Show current Zabbix configuration
    set KEY VALUE       Set configuration value
    enable              Enable Zabbix integration
    disable             Disable Zabbix integration

EXAMPLES:
    # Interactive setup
    nftban zabbix setup

    # Non-interactive setup
    nftban zabbix setup --server zabbix.example.com --hostname myserver

    # Check status
    nftban zabbix status
    nftban zabbix status --json

    # Test connection
    nftban zabbix test --verbose

    # Export template for Zabbix 6.x
    nftban zabbix template --version 6.0 --format yaml --output /tmp/nftban.yaml

    # Run LLD discovery
    nftban zabbix discover modules
    nftban zabbix discover --all

    # Multi-target setup (DR/backup)
    nftban zabbix targets add backup --server zabbix-dr.example.com
    nftban zabbix targets list

    # Force metric push
    nftban zabbix push

METRICS OVERVIEW:
    NFTBan exports 85+ metrics to Zabbix including:
    - Daemon status, version, uptime
    - Ban statistics (total, 24h, rate)
    - Memory usage, goroutines, GC stats
    - Module status per enabled module
    - Watchdog pressure scores
    - Feed status and IP counts
    - GeoIP statistics

    See: /home/commonfolder/implementation/metrics-contract.yaml

EOF
}

# =============================================================================
# Main Command Handler
# =============================================================================
nftban_cmd_zabbix() {
    local subcommand="${1:-help}"
    shift || true

    # Show banner for non-quiet commands
    if [[ "$subcommand" != "test" || ! "$*" =~ "--quiet" ]]; then
        if [[ $(type -t nftban_banner) == "function" ]]; then
            nftban_banner "zabbix"
        fi
    fi

    case "$subcommand" in
        setup)    _cmd_zabbix_setup "$@" ;;
        status)   _cmd_zabbix_status "$@" ;;
        test)     _cmd_zabbix_test "$@" ;;
        push)     _cmd_zabbix_push "$@" ;;
        template) _cmd_zabbix_template "$@" ;;
        discover) _cmd_zabbix_discover "$@" ;;
        targets)  _cmd_zabbix_targets "$@" ;;
        config)   _cmd_zabbix_config "$@" ;;
        help|--help|-h) _cmd_zabbix_help ;;
        *)
            _zabbix_print_error "Unknown command: $subcommand"
            _cmd_zabbix_help
            return 1
            ;;
    esac
}

# Export main handler
export -f nftban_cmd_zabbix
