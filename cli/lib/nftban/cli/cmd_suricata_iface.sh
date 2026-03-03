#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.12.0 - Suricata IDS CLI Command - Interface Detection Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Intelligent interface detection for Suricata af-packet configuration
#
# meta:name="cmd_suricata_iface"
# meta:type="cli"
# meta:header="Suricata Interface Module"
# meta:version="1.12.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Interface detection and configuration for Suricata af-packet"
# meta:inventory.files="/etc/nftban/conf.d/suricata/interfaces.conf"
# meta:inventory.binaries="ip"
# meta:inventory.env_vars="SURICATA_IFACE_MODE,SURICATA_IFACES,SURICATA_ALLOW_MULTI"
# meta:inventory.config_files="/etc/nftban/conf.d/suricata/interfaces.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="conditional"
#
# Loaded by: cmd_suricata.sh (inherits strict mode)
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_CMD_SURICATA_IFACE_LOADED:-}" ]] && return 0
_CMD_SURICATA_IFACE_LOADED="true"

# =============================================================================
# CONFIGURATION
# =============================================================================

# Virtual interface patterns (excluded by default)
# shellcheck disable=SC2034
readonly SURICATA_VIRTUAL_PATTERNS="^(lo|docker[0-9]*|cni[0-9]*|flannel|virbr[0-9]*|veth|br-|zt|tailscale[0-9]*|wg[0-9]*|tun[0-9]*|tap[0-9]*|podman[0-9]*|cali[a-z0-9]*|lxc[a-z0-9]*)"

# Private IP ranges (RFC1918 + link-local)
readonly _PRIVATE_IPV4_PATTERNS="^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|127\.|169\.254\.)"
readonly _PRIVATE_IPV6_PATTERNS="^(fe80:|fc[0-9a-f]{2}:|fd[0-9a-f]{2}:|::1$)"

# Config file path (uses DISTRO_PATHS if available)
_suricata_iface_get_config_path() {
    if [[ -n "${DISTRO_PATHS[suricata_iface_config]:-}" ]]; then
        echo "${DISTRO_PATHS[suricata_iface_config]}"
    else
        echo "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/suricata/interfaces.conf"
    fi
}

# =============================================================================
# INTERFACE TYPE DETECTION
# =============================================================================

_suricata_iface_get_type() {
    # Returns: phy|bridge|bond|vlan|virtual
    local iface="$1"

    # Check if interface exists
    if [[ ! -d "/sys/class/net/$iface" ]]; then
        echo "unknown"
        return 1
    fi

    # Check for bridge
    if [[ -d "/sys/class/net/$iface/bridge" ]]; then
        echo "bridge"
        return 0
    fi

    # Check for bond
    if [[ -d "/sys/class/net/$iface/bonding" ]]; then
        echo "bond"
        return 0
    fi

    # Check for VLAN (contains '.' in name, e.g., eth0.100)
    if [[ "$iface" == *.* ]]; then
        echo "vlan"
        return 0
    fi

    # Check for virtual interface patterns
    if _suricata_iface_is_virtual "$iface"; then
        echo "virtual"
        return 0
    fi

    # Check if it's a physical device (has /device symlink)
    if [[ -L "/sys/class/net/$iface/device" ]]; then
        echo "phy"
        return 0
    fi

    # Fallback: check driver for common virtual types
    local driver=""
    driver=$(readlink -f "/sys/class/net/$iface/device/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "")

    case "$driver" in
        virtio*|vmxnet*|hv_netvsc|xen*)
            echo "phy"  # VM NICs are treated as physical for our purposes
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

_suricata_iface_is_virtual() {
    # Returns 0 if interface matches virtual patterns
    local iface="$1"

    if [[ "$iface" =~ $SURICATA_VIRTUAL_PATTERNS ]]; then
        return 0
    fi
    return 1
}

_suricata_iface_is_private_ip() {
    # Returns 0 if IP is private/non-routable
    local ip="$1"

    # IPv4 check
    if [[ "$ip" =~ $_PRIVATE_IPV4_PATTERNS ]]; then
        return 0
    fi

    # IPv6 check
    if [[ "$ip" =~ $_PRIVATE_IPV6_PATTERNS ]]; then
        return 0
    fi

    return 1
}

_suricata_iface_get_state() {
    # Returns: UP|DOWN|UNKNOWN
    local iface="$1"

    if [[ ! -f "/sys/class/net/$iface/operstate" ]]; then
        echo "UNKNOWN"
        return 1
    fi

    local state
    state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")

    case "$state" in
        up)
            echo "UP"
            ;;
        down)
            echo "DOWN"
            ;;
        *)
            echo "UNKNOWN"
            ;;
    esac
}

# =============================================================================
# MASTER RELATIONSHIP DETECTION (CRITICAL)
# =============================================================================

_suricata_iface_get_master() {
    # Returns master interface if this is a slave, empty otherwise
    local iface="$1"

    # Method 1: Check /sys/class/net/IFACE/master symlink
    if [[ -L "/sys/class/net/$iface/master" ]]; then
        basename "$(readlink -f "/sys/class/net/$iface/master")"
        return 0
    fi

    # Method 2: Parse ip link output
    local master
    master=$(ip -o link show dev "$iface" 2>/dev/null | grep -oP 'master \K\S+' || echo "")
    if [[ -n "$master" ]]; then
        echo "$master"
        return 0
    fi

    echo ""
}

_suricata_iface_resolve_effective() {
    # Resolves slave interfaces to their master for capture
    # Input: comma-separated interface list
    # Output: resolved effective capture interfaces (newline-separated, unique)
    local interfaces="$1"
    local -A seen
    local resolved=""

    # Split by comma
    IFS=',' read -ra iface_array <<< "$interfaces"

    for iface in "${iface_array[@]}"; do
        iface=$(echo "$iface" | xargs)  # trim whitespace
        [[ -z "$iface" ]] && continue

        local master
        master=$(_suricata_iface_get_master "$iface")

        if [[ -n "$master" ]]; then
            # This is a slave, use the master instead
            if [[ -z "${seen[$master]:-}" ]]; then
                seen[$master]=1
                resolved+="$master"$'\n'
            fi
        else
            # Not a slave, use as-is
            if [[ -z "${seen[$iface]:-}" ]]; then
                seen[$iface]=1
                resolved+="$iface"$'\n'
            fi
        fi
    done

    echo -n "$resolved" | grep -v '^$'
}

# =============================================================================
# IP AND ROUTE DETECTION
# =============================================================================

_suricata_iface_get_default_route_ifaces() {
    # Returns interfaces with default route (newline-separated)
    ip route show default 2>/dev/null | awk '/^default/ {print $5}' | sort -u
}

_suricata_iface_get_ips() {
    # Returns all IPs for an interface (newline-separated)
    local iface="$1"

    # Get IPv4
    ip -4 addr show dev "$iface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' || true

    # Get IPv6 (excluding link-local)
    ip -6 addr show dev "$iface" 2>/dev/null | grep -oP 'inet6 \K[0-9a-f:]+' | grep -v '^fe80:' || true
}

_suricata_iface_get_public_ips() {
    # Returns public (non-private) IPs for an interface (newline-separated)
    local iface="$1"
    local ips

    ips=$(_suricata_iface_get_ips "$iface")

    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        if ! _suricata_iface_is_private_ip "$ip"; then
            echo "$ip"
        fi
    done <<< "$ips"
}

_suricata_iface_get_public_ip_ifaces() {
    # Returns interfaces that have at least one public IP (newline-separated)
    local all_ifaces
    all_ifaces=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//')

    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue
        local public_ips
        public_ips=$(_suricata_iface_get_public_ips "$iface")
        if [[ -n "$public_ips" ]]; then
            echo "$iface"
        fi
    done <<< "$all_ifaces"
}

# =============================================================================
# SCORING (for display purposes only - decision uses hard gates)
# =============================================================================

_suricata_iface_calculate_score() {
    # Calculate score for an interface (for display/explainability)
    local iface="$1"
    local score=0
    local reasons=""

    # Default route: +100
    if _suricata_iface_get_default_route_ifaces | grep -qxF "$iface"; then
        score=$((score + 100))
        reasons+="default_route,"
    fi

    # Public IP: +60
    local public_ips
    public_ips=$(_suricata_iface_get_public_ips "$iface")
    if [[ -n "$public_ips" ]]; then
        score=$((score + 60))
        reasons+="public_ip,"
    fi

    # Routes to non-private networks: +40
    if ip route 2>/dev/null | grep -v default | grep "dev $iface" | grep -qvE '(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.)'; then
        score=$((score + 40))
        reasons+="public_routes,"
    fi

    # Virtual interface: -80
    if _suricata_iface_is_virtual "$iface"; then
        score=$((score - 80))
        reasons+="virtual,"
    fi

    # No IP or link-local only: -50
    local all_ips
    all_ips=$(_suricata_iface_get_ips "$iface")
    if [[ -z "$all_ips" ]]; then
        score=$((score - 50))
        reasons+="no_ip,"
    fi

    # Has master (is slave): -100
    local master
    master=$(_suricata_iface_get_master "$iface")
    if [[ -n "$master" ]]; then
        score=$((score - 100))
        reasons+="has_master,"
    fi

    # Remove trailing comma
    reasons="${reasons%,}"

    echo "$score|$reasons"
}

# =============================================================================
# INTERFACE SCANNING
# =============================================================================

_suricata_iface_scan_all() {
    # Returns all UP interfaces with metadata (pipe-delimited)
    # Format: IFACE|STATE|SCORE|IPs|DEFAULT|PUBLIC|MASTER|TYPE|REASONS

    local all_ifaces
    all_ifaces=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//')

    local default_ifaces
    default_ifaces=$(_suricata_iface_get_default_route_ifaces)

    while IFS= read -r iface; do
        [[ -z "$iface" ]] && continue

        local state type master ips public_ips score_data score reasons
        local has_default="no" has_public="no"

        state=$(_suricata_iface_get_state "$iface")
        type=$(_suricata_iface_get_type "$iface")
        master=$(_suricata_iface_get_master "$iface")
        ips=$(_suricata_iface_get_ips "$iface" | tr '\n' ',' | sed 's/,$//')
        public_ips=$(_suricata_iface_get_public_ips "$iface" | tr '\n' ',' | sed 's/,$//')

        # Check default route
        if echo "$default_ifaces" | grep -qxF "$iface"; then
            has_default="yes"
        fi

        # Check public IP
        if [[ -n "$public_ips" ]]; then
            has_public="yes"
        fi

        # Calculate score
        score_data=$(_suricata_iface_calculate_score "$iface")
        score=$(echo "$score_data" | cut -d'|' -f1)
        reasons=$(echo "$score_data" | cut -d'|' -f2)

        # Add "excluded" to reasons if virtual
        if _suricata_iface_is_virtual "$iface"; then
            [[ -n "$reasons" ]] && reasons+=","
            reasons+="excluded"
        fi

        # Output format: IFACE|STATE|SCORE|IPs|DEFAULT|PUBLIC|MASTER|TYPE|REASONS
        echo "$iface|$state|$score|${ips:-none}|$has_default|$has_public|${master:--}|$type|${reasons:-none}"

    done <<< "$all_ifaces"
}

# =============================================================================
# HARD GATE DECISION (NOT percentages)
# =============================================================================

_suricata_iface_can_auto_enable() {
    # Hard gate check for auto-enabling Suricata
    # Returns: 0 = auto-enable allowed, 1 = selection required
    # Outputs reason to stdout

    local include_virtual="${SURICATA_INCLUDE_VIRTUAL:-false}"
    local allow_multi="${SURICATA_ALLOW_MULTI:-false}"

    # Get all UP interfaces
    local candidates=()
    local effective_candidates=()
    local default_ifaces
    default_ifaces=$(_suricata_iface_get_default_route_ifaces)

    while IFS='|' read -r iface state score ips has_default has_public master type reasons; do
        [[ -z "$iface" ]] && continue
        [[ "$state" != "UP" ]] && continue

        # Skip virtual interfaces unless explicitly included
        if [[ "$include_virtual" != "true" ]] && _suricata_iface_is_virtual "$iface"; then
            continue
        fi

        # Skip interfaces that are slaves (have master)
        if [[ "$master" != "-" ]]; then
            continue
        fi

        # Skip loopback
        [[ "$iface" == "lo" ]] && continue

        candidates+=("$iface")

        # Check if this is an effective capture interface
        # (has default route OR has public IP)
        if [[ "$has_default" == "yes" ]] || [[ "$has_public" == "yes" ]]; then
            effective_candidates+=("$iface")
        fi

    done < <(_suricata_iface_scan_all)

    # Gate 1: No effective interfaces found
    if [[ ${#effective_candidates[@]} -eq 0 ]]; then
        echo "no_effective_interface"
        echo "REASON: No capture interface found (no default route or public IP)"
        return 1
    fi

    # Gate 2: Multiple effective interfaces
    if [[ ${#effective_candidates[@]} -gt 1 ]]; then
        if [[ "$allow_multi" == "true" ]]; then
            # Multi-interface mode explicitly allowed
            printf '%s\n' "${effective_candidates[@]}"
            return 0
        else
            echo "multiple_interfaces"
            echo "REASON: Multiple capture interfaces detected (${effective_candidates[*]})"
            echo "FIX: Use 'nftban suricata iface set X' or enable SURICATA_ALLOW_MULTI=true"
            return 1
        fi
    fi

    # Gate 3: Single effective interface - additional checks
    local the_iface="${effective_candidates[0]}"
    local iface_state
    iface_state=$(_suricata_iface_get_state "$the_iface")

    # Check interface is UP
    if [[ "$iface_state" != "UP" ]]; then
        echo "interface_down"
        echo "REASON: Detected interface $the_iface is DOWN"
        return 1
    fi

    # Check if top candidate is virtual (shouldn't happen after filter, but safety check)
    if _suricata_iface_is_virtual "$the_iface"; then
        echo "virtual_interface"
        echo "REASON: Top candidate $the_iface is a virtual interface"
        return 1
    fi

    # Gate 4: Multiple default routes to different interfaces
    local default_count
    default_count=$(echo "$default_ifaces" | grep -v '^$' | wc -l)
    if [[ $default_count -gt 1 ]]; then
        # Check if all default routes go to the same interface after resolution
        local resolved_defaults
        resolved_defaults=$(_suricata_iface_resolve_effective "$(echo "$default_ifaces" | tr '\n' ',')")
        local resolved_count
        resolved_count=$(echo "$resolved_defaults" | grep -v '^$' | wc -l)

        if [[ $resolved_count -gt 1 ]]; then
            echo "multiple_default_routes"
            echo "REASON: Multiple default routes to different interfaces"
            return 1
        fi
    fi

    # All gates passed - auto-enable allowed
    echo "$the_iface"
    return 0
}

# =============================================================================
# VALIDATION
# =============================================================================

_suricata_iface_validate() {
    # Validates a user-specified interface
    # Args: $1 = interface name
    # Returns: 0 = valid, 1 = invalid (reason on stdout)
    local iface="$1"

    # Check exists
    if [[ ! -d "/sys/class/net/$iface" ]]; then
        echo "Interface '$iface' does not exist"
        return 1
    fi

    # Check state
    local state
    state=$(_suricata_iface_get_state "$iface")
    if [[ "$state" != "UP" ]]; then
        echo "Interface '$iface' is $state (not UP)"
        return 1
    fi

    # Check for master (warn but don't fail)
    local master
    master=$(_suricata_iface_get_master "$iface")
    if [[ -n "$master" ]]; then
        echo "WARNING: Interface '$iface' has master '$master'"
        echo "  Capturing on '$iface' and '$master' would duplicate traffic"
        echo "  Recommendation: Use '$master' instead"
        # Return 2 to indicate "proceed with warning"
        return 2
    fi

    return 0
}

# =============================================================================
# YAML CONFIGURATION
# =============================================================================

_suricata_iface_configure_yaml() {
    # Configures af-packet section in suricata.yaml
    # Args: $1 = comma-separated interfaces, $2 = suricata.yaml path
    local interfaces="$1"
    local yaml_path="${2:-${DISTRO_PATHS[suricata_yaml]:-/etc/suricata/suricata.yaml}}"
    local cluster_id_base="${SURICATA_CLUSTER_ID_BASE:-99}"

    if [[ ! -f "$yaml_path" ]]; then
        echo "ERROR: suricata.yaml not found at $yaml_path"
        return 1
    fi

    # Split interfaces
    IFS=',' read -ra iface_array <<< "$interfaces"

    if [[ ${#iface_array[@]} -eq 0 ]]; then
        echo "ERROR: No interfaces specified"
        return 1
    fi

    # Backup current config
    cp "$yaml_path" "${yaml_path}.bak.$(date +%Y%m%d-%H%M%S)"

    # Build af-packet configuration
    local af_packet_config=""
    local cluster_id=$cluster_id_base

    for iface in "${iface_array[@]}"; do
        iface=$(echo "$iface" | xargs)  # trim
        [[ -z "$iface" ]] && continue

        af_packet_config+="  - interface: $iface
    cluster-id: $cluster_id
    cluster-type: cluster_flow
    defrag: yes
    use-mmap: yes
    tpacket-v3: yes
"
        cluster_id=$((cluster_id + 1))
    done

    # Update suricata.yaml using sed
    # This replaces the af-packet section

    # Create a temp file with the new af-packet config
    local temp_file
    temp_file=$(mktemp)
    cat > "$temp_file" << EOF
af-packet:
$af_packet_config
EOF

    # Replace af-packet section in suricata.yaml
    # This is a simplistic approach - for production use a proper YAML parser
    if grep -q "^af-packet:" "$yaml_path"; then
        # Find line number of af-packet and next top-level section
        local start_line end_line
        start_line=$(grep -n "^af-packet:" "$yaml_path" | head -1 | cut -d: -f1)

        # Find next top-level section (line starting with letter/no indent after af-packet)
        end_line=$(tail -n +"$((start_line + 1))" "$yaml_path" | grep -n "^[a-z]" | head -1 | cut -d: -f1)

        if [[ -n "$end_line" ]]; then
            end_line=$((start_line + end_line - 1))
            # Replace the section
            head -n "$((start_line - 1))" "$yaml_path" > "${yaml_path}.new"
            cat "$temp_file" >> "${yaml_path}.new"
            tail -n "+$end_line" "$yaml_path" >> "${yaml_path}.new"
            mv "${yaml_path}.new" "$yaml_path"
        else
            # af-packet is at the end - just replace to end
            head -n "$((start_line - 1))" "$yaml_path" > "${yaml_path}.new"
            cat "$temp_file" >> "${yaml_path}.new"
            mv "${yaml_path}.new" "$yaml_path"
        fi
    else
        # No af-packet section exists - append it
        echo "" >> "$yaml_path"
        cat "$temp_file" >> "$yaml_path"
    fi

    rm -f "$temp_file"

    echo "  ✓ af-packet configured for: ${iface_array[*]}"
    return 0
}

# =============================================================================
# CONFIGURATION FILE MANAGEMENT
# =============================================================================

_suricata_iface_load_config() {
    # Load interfaces.conf configuration
    local config_path
    config_path=$(_suricata_iface_get_config_path)

    # Set defaults
    export SURICATA_IFACE_MODE="${SURICATA_IFACE_MODE:-auto}"
    export SURICATA_IFACES="${SURICATA_IFACES:-}"
    export SURICATA_ALLOW_MULTI="${SURICATA_ALLOW_MULTI:-false}"
    export SURICATA_INCLUDE_VIRTUAL="${SURICATA_INCLUDE_VIRTUAL:-false}"
    export SURICATA_CLUSTER_ID_BASE="${SURICATA_CLUSTER_ID_BASE:-99}"

    if [[ -f "$config_path" ]]; then
        # shellcheck source=/dev/null
        source "$config_path"
    fi
}

_suricata_iface_save_config() {
    # Save configuration to interfaces.conf
    local config_path
    config_path=$(_suricata_iface_get_config_path)
    local config_dir
    config_dir=$(dirname "$config_path")

    # Ensure directory exists
    mkdir -p "$config_dir"
    chmod 750 "$config_dir"
    chown root:nftban "$config_dir" 2>/dev/null || true

    # Write config
    cat > "$config_path" << EOF
# =============================================================================
# NFTBan Suricata Interface Configuration
# =============================================================================
# Managed by: nftban suricata iface {list|set|auto}
# Generated: $(date -Iseconds)
# =============================================================================

# Mode: auto or manual
SURICATA_IFACE_MODE="$SURICATA_IFACE_MODE"

# Manual interfaces (comma-separated, only when mode=manual)
SURICATA_IFACES="$SURICATA_IFACES"

# Allow auto-detection to configure multiple interfaces
# false = require manual selection if >1 candidate
# true  = auto-configure all external candidates
SURICATA_ALLOW_MULTI="$SURICATA_ALLOW_MULTI"

# Include virtual interfaces in detection
SURICATA_INCLUDE_VIRTUAL="$SURICATA_INCLUDE_VIRTUAL"

# Cluster ID base for multi-interface af-packet
SURICATA_CLUSTER_ID_BASE="$SURICATA_CLUSTER_ID_BASE"

# Auto-populated by detection (informational)
SURICATA_LAST_DETECTION="$(date -Iseconds)"
SURICATA_LAST_CANDIDATES="$SURICATA_LAST_CANDIDATES"
EOF

    chmod 640 "$config_path"
    chown root:nftban "$config_path" 2>/dev/null || true

    echo "  ✓ Configuration saved to $config_path"
}

# =============================================================================
# COMMANDS
# =============================================================================

cmd_suricata_iface_list() {
    # Show all interfaces with detection details

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Network Interface Detection for Suricata af-packet"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Load config
    _suricata_iface_load_config

    # Print current mode
    echo "  Mode: $SURICATA_IFACE_MODE"
    if [[ "$SURICATA_IFACE_MODE" == "manual" ]] && [[ -n "$SURICATA_IFACES" ]]; then
        echo "  Configured: $SURICATA_IFACES"
    fi
    echo ""

    # Print header
    printf "  %-12s %-6s %6s  %-18s %-8s %-7s %-8s %-8s %s\n" \
        "IFACE" "STATE" "SCORE" "IP(s)" "DEFAULT?" "PUBLIC?" "MASTER" "TYPE" "REASONS"
    printf "  %-12s %-6s %6s  %-18s %-8s %-7s %-8s %-8s %s\n" \
        "-----" "-----" "-----" "----" "--------" "-------" "------" "----" "-------"

    # Print interfaces
    while IFS='|' read -r iface state score ips has_default has_public master type reasons; do
        [[ -z "$iface" ]] && continue

        # Truncate IPs if too long
        if [[ ${#ips} -gt 18 ]]; then
            ips="${ips:0:15}..."
        fi

        # Color coding based on score
        local color=""
        local reset=""
        if [[ -t 1 ]]; then
            if [[ $score -ge 100 ]]; then
                color="\033[32m"  # Green
            elif [[ $score -ge 0 ]]; then
                color="\033[33m"  # Yellow
            else
                color="\033[2m"   # Dim
            fi
            reset="\033[0m"
        fi

        printf "  ${color}%-12s %-6s %6s  %-18s %-8s %-7s %-8s %-8s %s${reset}\n" \
            "$iface" "$state" "$score" "$ips" "$has_default" "$has_public" "$master" "$type" "$reasons"

    done < <(_suricata_iface_scan_all | sort -t'|' -k3 -rn)

    echo ""

    # Run detection and show decision
    echo "─────────────────────────────────────────────────────────────"
    local detection_result
    local detection_status

    detection_result=$(_suricata_iface_can_auto_enable)
    detection_status=$?

    if [[ $detection_status -eq 0 ]]; then
        echo "  Effective Capture Interface(s): $detection_result"
        echo "  Decision: AUTO-ENABLE ALLOWED (single unambiguous interface)"
    else
        local details
        details=$(echo "$detection_result" | tail -n +2)

        echo "  Decision: SELECTION REQUIRED"
        echo ""
        echo "  $details"
    fi

    echo ""
    echo "Commands:"
    echo "  nftban suricata iface set <iface>    Set manual interface"
    echo "  nftban suricata iface auto           Reset to auto-detection"
    echo ""
}

cmd_suricata_iface_set() {
    # Manually set interface(s)
    local interfaces="${1:-}"

    if [[ -z "$interfaces" ]]; then
        echo "ERROR: Interface(s) required"
        echo ""
        echo "Usage: nftban suricata iface set <interface>[,interface2,...]"
        echo ""
        echo "Examples:"
        echo "  nftban suricata iface set eth0"
        echo "  nftban suricata iface set eth0,eth1"
        echo ""
        echo "Run 'nftban suricata iface list' to see available interfaces"
        return 1
    fi

    _check_root "interface set" || return 1

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Setting Suricata Interface(s)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Load current config
    _suricata_iface_load_config

    # Validate each interface
    IFS=',' read -ra iface_array <<< "$interfaces"
    local final_interfaces=()

    for iface in "${iface_array[@]}"; do
        iface=$(echo "$iface" | xargs)  # trim
        [[ -z "$iface" ]] && continue

        echo "  Validating: $iface"

        local validation_result
        local validation_status
        validation_result=$(_suricata_iface_validate "$iface")
        validation_status=$?

        if [[ $validation_status -eq 1 ]]; then
            echo "    ✗ $validation_result"
            return 1
        elif [[ $validation_status -eq 2 ]]; then
            # Warning about master
            echo "    ⚠ $validation_result"

            # Get the master and offer to switch
            local master
            master=$(_suricata_iface_get_master "$iface")

            echo ""
            read -p "    Switch to master '$master' instead? [Y/n]: " switch_answer
            switch_answer=${switch_answer:-y}

            if [[ "${switch_answer,,}" == "y" ]]; then
                echo "    → Switching to: $master"
                final_interfaces+=("$master")
            else
                final_interfaces+=("$iface")
            fi
        else
            echo "    ✓ Valid"
            final_interfaces+=("$iface")
        fi
    done

    if [[ ${#final_interfaces[@]} -eq 0 ]]; then
        echo ""
        echo "  ✗ No valid interfaces"
        return 1
    fi

    # Resolve to effective interfaces (remove duplicates)
    local resolved
    resolved=$(_suricata_iface_resolve_effective "$(IFS=','; echo "${final_interfaces[*]}")")

    # Convert newline-separated to comma-separated
    local final_ifaces
    final_ifaces=$(echo "$resolved" | tr '\n' ',' | sed 's/,$//')

    echo ""
    echo "  Final interfaces: $final_ifaces"

    # Update config
    export SURICATA_IFACE_MODE="manual"
    export SURICATA_IFACES="$final_ifaces"
    export SURICATA_LAST_CANDIDATES="$final_ifaces"

    _suricata_iface_save_config

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  ✅ Interface Configuration Saved                            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Mode: manual"
    echo "  Interfaces: $final_ifaces"
    echo ""
    echo "Next steps:"
    echo "  nftban suricata enable    # Apply and start Suricata"
    echo ""
}

cmd_suricata_iface_auto() {
    # Reset to auto-detection mode

    _check_root "interface auto" || return 1

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Resetting to Auto-Detection Mode"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Load and reset config
    _suricata_iface_load_config

    export SURICATA_IFACE_MODE="auto"
    export SURICATA_IFACES=""

    # Run detection to populate LAST_CANDIDATES
    local detection_result
    detection_result=$(_suricata_iface_can_auto_enable)
    local detection_status=$?

    if [[ $detection_status -eq 0 ]]; then
        export SURICATA_LAST_CANDIDATES="$detection_result"
        echo "  ✓ Auto-detection successful"
        echo "  Detected interface(s): $detection_result"
    else
        export SURICATA_LAST_CANDIDATES=""
        echo "  ⚠ Auto-detection requires manual selection"
        local details
        details=$(echo "$detection_result" | tail -n +2)
        echo "  $details"
    fi

    _suricata_iface_save_config

    echo ""
    echo "  Mode: auto"
    echo ""
    echo "Run 'nftban suricata iface list' to see detection details"
    echo ""
}

cmd_suricata_iface_help() {
    cat << 'EOF'

🔧 Suricata Interface Configuration

USAGE:
    nftban suricata iface <command>

COMMANDS:
    list        Show all interfaces with detection details
    set <X>     Pin to manual mode with interface(s)
    auto        Reset to auto-detection
    help        Show this help message

INTERFACE DETECTION:
    NFTBan automatically detects the optimal interface for Suricata:
    - Scans all network interfaces
    - Identifies physical vs virtual interfaces
    - Resolves master/slave relationships (bridges, bonds)
    - Detects interfaces with default routes
    - Identifies interfaces with public IPs

AUTO-ENABLE CRITERIA:
    Suricata auto-enables when ALL of these are true:
    - Exactly 1 effective capture interface after resolution
    - Interface is non-virtual and UP
    - Interface has default route OR the only public IP

REQUIRES SELECTION WHEN:
    - Multiple effective interfaces detected
    - Multiple default routes to different interfaces
    - Top candidate is a virtual interface
    - No suitable interface found

EXAMPLES:
    # View detection results
    nftban suricata iface list

    # Set single interface
    nftban suricata iface set eth0

    # Set multiple interfaces (requires SURICATA_ALLOW_MULTI=true)
    nftban suricata iface set eth0,eth1

    # Reset to auto-detection
    nftban suricata iface auto

MASTER RESOLUTION:
    When selecting a slave interface (e.g., eth0 in bridge br0),
    NFTBan automatically offers to switch to the master:

    $ nftban suricata iface set eth0
    WARNING: eth0 has master br0
      Capturing on eth0 and br0 would duplicate traffic.
      Switch to master 'br0' instead? [Y/n]: y

CONFIGURATION:
    Settings stored in: /etc/nftban/conf.d/suricata/interfaces.conf

    SURICATA_IFACE_MODE      auto|manual
    SURICATA_IFACES          Comma-separated interfaces (manual mode)
    SURICATA_ALLOW_MULTI     Allow auto-detection of multiple interfaces
    SURICATA_INCLUDE_VIRTUAL Include virtual interfaces in detection

EOF
}

cmd_suricata_iface() {
    # Main router for iface subcommand
    local action="${1:-list}"
    shift || true

    case "$action" in
        list|ls|show)
            cmd_suricata_iface_list
            ;;
        set|pin|manual)
            cmd_suricata_iface_set "$@"
            ;;
        auto|reset|detect)
            cmd_suricata_iface_auto
            ;;
        help|--help|-h)
            cmd_suricata_iface_help
            ;;
        *)
            echo "ERROR: Unknown iface command: $action"
            echo "Run 'nftban suricata iface help' for usage"
            return 1
            ;;
    esac
}

# =============================================================================
# EXPORTS
# =============================================================================

# Export command functions
export -f cmd_suricata_iface
export -f cmd_suricata_iface_list
export -f cmd_suricata_iface_set
export -f cmd_suricata_iface_auto
export -f cmd_suricata_iface_help

# Export detection functions
export -f _suricata_iface_can_auto_enable
export -f _suricata_iface_resolve_effective
export -f _suricata_iface_validate
export -f _suricata_iface_scan_all
export -f _suricata_iface_get_type
export -f _suricata_iface_get_master
export -f _suricata_iface_get_state
export -f _suricata_iface_get_ips
export -f _suricata_iface_get_public_ips
export -f _suricata_iface_get_default_route_ifaces
export -f _suricata_iface_is_virtual
export -f _suricata_iface_is_private_ip

# Export configuration functions
export -f _suricata_iface_load_config
export -f _suricata_iface_save_config
export -f _suricata_iface_configure_yaml
export -f _suricata_iface_get_config_path
