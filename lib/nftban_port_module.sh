#!/usr/bin/env bash

# BUG51 FIX: Add strict mode for production-grade security
set -Eeuo pipefail
IFS=$'\n\t'
umask 027


# =============================================================================
# NFTBan Port Management Module
# Version: 0.9.2
# Location: lib/nftban_port_module.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Advanced port configuration with validation and rule generation
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_PORT_LOADED:-}" ]] && return 0
readonly NFTBAN_PORT_LOADED=1

# =============================================================================
# MODULE CONFIGURATION
# =============================================================================
readonly NFTBAN_PORT_CONFIG_DIR="${NFTBAN_CONFIG_DIR}/ports"
readonly NFTBAN_IPV4_INPUT_PORTS="${NFTBAN_PORT_CONFIG_DIR}/ipv4-input.conf"
readonly NFTBAN_IPV4_OUTPUT_PORTS="${NFTBAN_PORT_CONFIG_DIR}/ipv4-output.conf"
readonly NFTBAN_IPV6_INPUT_PORTS="${NFTBAN_PORT_CONFIG_DIR}/ipv6-input.conf"
readonly NFTBAN_IPV6_OUTPUT_PORTS="${NFTBAN_PORT_CONFIG_DIR}/ipv6-output.conf"
readonly NFTBAN_PORT_LOG="${NFTBAN_LOG_DIR}/port-management.log"

# =============================================================================
# PORT VALIDATION
# =============================================================================

# Validate single port number
nftban_port_validate_single() {
    local port="$1"
    
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( port >= 1 && port <= 65535 )) || return 1
    
    return 0
}

# Validate port range
nftban_port_validate_range() {
    local range="$1"
    
    [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]] || return 1
    
    local start="${BASH_REMATCH[1]}"
    local end="${BASH_REMATCH[2]}"
    
    nftban_port_validate_single "$start" || return 1
    nftban_port_validate_single "$end" || return 1
    
    (( start <= end )) || return 1
    
    return 0
}

# Validate port token (single port or range)
nftban_port_validate_token() {
    local token="$1"
    
    if [[ "$token" =~ ^[0-9]+$ ]]; then
        nftban_port_validate_single "$token"
    elif [[ "$token" =~ ^[0-9]+-[0-9]+$ ]]; then
        nftban_port_validate_range "$token"
    else
        return 1
    fi
}

# BUG54 FIX: Normalize protocol names (accept tcp/udp/both AND T/U/B)
nftban_port_normalize_protocol() {
    local proto="$1"

    # Convert to lowercase for case-insensitive matching
    case "${proto,,}" in
        tcp|t) echo "T" ;;
        udp|u) echo "U" ;;
        both|b|all) echo "B" ;;
        *)
            nftban_log_error "Invalid protocol: $proto"
            nftban_log_error "Valid options: tcp, udp, both (or T, U, B)"
            return 1
            ;;
    esac
}

# Validate protocol code
nftban_port_validate_protocol() {
    local proto="$1"

    [[ "$proto" =~ ^[TUB]$ ]] || return 1
    return 0
}

# Validate port configuration line
nftban_port_validate_line() {
    local line="$1"
    
    # Format: PORT|PROTOCOL
    # Examples: 22|T, 80-443|T, 53|U, 8080|B
    
    [[ "$line" =~ ^([0-9]+-?[0-9]*)\|([TUB])$ ]] || return 1
    
    local port="${BASH_REMATCH[1]}"
    local proto="${BASH_REMATCH[2]}"
    
    nftban_port_validate_token "$port" || return 1
    nftban_port_validate_protocol "$proto" || return 1
    
    return 0
}

# =============================================================================
# PORT CONFIGURATION INITIALIZATION
# =============================================================================

nftban_port_init() {
    nftban_log_info "Initializing port configuration..."
    
    mkdir -p "$NFTBAN_PORT_CONFIG_DIR"
    
    local port_files=(
        "$NFTBAN_IPV4_INPUT_PORTS"
        "$NFTBAN_IPV4_OUTPUT_PORTS"
        "$NFTBAN_IPV6_INPUT_PORTS"
        "$NFTBAN_IPV6_OUTPUT_PORTS"
    )
    
    for file in "${port_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            cat > "$file" << 'EOF'
# =============================================================================
# nftban Port Configuration
# =============================================================================
# Format: PORT|PROTOCOL
# Protocol codes:
#   T = TCP only
#   U = UDP only
#   B = Both TCP and UDP
#
# Examples:
#   22|T         # SSH (TCP)
#   53|U         # DNS (UDP)
#   80|T         # HTTP (TCP)
#   443|T        # HTTPS (TCP)
#   8080-8090|T  # Port range (TCP)
#   123|U        # NTP (UDP)
#   3000|B       # Custom app (TCP+UDP)
# =============================================================================

EOF
            chmod 644 "$file"
            nftban_log_debug "Created port config: $(basename "$file")"
        fi
    done
    
    # Add common ports to INPUT if file is empty
    if [[ ! -s "$NFTBAN_IPV4_INPUT_PORTS" ]]; then
        cat >> "$NFTBAN_IPV4_INPUT_PORTS" << 'EOF'
# Common services (add/remove as needed)
22|T         # SSH
80|T         # HTTP
443|T        # HTTPS
EOF
    fi
    
    nftban_log_success "Port configuration initialized"
}

# =============================================================================
# PORT MANAGEMENT
# =============================================================================

# Add port to configuration
nftban_port_add() {
    local port="$1"
    local protocol_input="${2:-T}"  # Default TCP
    local direction="${3:-input}"
    local ip_version="${4:-4}"

    # Validate inputs
    nftban_port_validate_token "$port" || {
        nftban_log_error "Invalid port format: $port"
        nftban_log_error "Examples: 22, 80-443, 8080"
        return 1
    }

    # BUG54 FIX: Normalize protocol (accept both 'tcp' and 'T')
    local protocol
    protocol=$(nftban_port_normalize_protocol "$protocol_input") || {
        nftban_log_error "Examples:"
        nftban_log_error "  nftban port add 22 tcp"
        nftban_log_error "  nftban port add 80 T"
        nftban_log_error "  nftban port add 53 both"
        return 1
    }
    
    # Select config file
    local config_file
    if [[ "$ip_version" == "4" ]]; then
        if [[ "$direction" == "input" ]]; then
            config_file="$NFTBAN_IPV4_INPUT_PORTS"
        else
            config_file="$NFTBAN_IPV4_OUTPUT_PORTS"
        fi
    else
        if [[ "$direction" == "input" ]]; then
            config_file="$NFTBAN_IPV6_INPUT_PORTS"
        else
            config_file="$NFTBAN_IPV6_OUTPUT_PORTS"
        fi
    fi
    
    # Check if already exists
    local entry="${port}|${protocol}"
    if grep -qE "^${port}\|${protocol}$" "$config_file" 2>/dev/null; then
        nftban_log_warning "Port already configured: $entry"
        return 0
    fi
    
    # Add to config file
    echo "$entry" >> "$config_file"
    
    nftban_log_success "Added port: $entry to IPv${ip_version} ${direction}"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ADD: $entry -> $(basename "$config_file")" >> "$NFTBAN_PORT_LOG"
    
    return 0
}

# Remove port from configuration
nftban_port_remove() {
    local port="$1"
    local protocol_input="${2:-T}"
    local direction="${3:-input}"
    local ip_version="${4:-4}"

    # BUG54 FIX: Normalize protocol
    local protocol
    protocol=$(nftban_port_normalize_protocol "$protocol_input") || return 1
    
    # Select config file
    local config_file
    if [[ "$ip_version" == "4" ]]; then
        if [[ "$direction" == "input" ]]; then
            config_file="$NFTBAN_IPV4_INPUT_PORTS"
        else
            config_file="$NFTBAN_IPV4_OUTPUT_PORTS"
        fi
    else
        if [[ "$direction" == "input" ]]; then
            config_file="$NFTBAN_IPV6_INPUT_PORTS"
        else
            config_file="$NFTBAN_IPV6_OUTPUT_PORTS"
        fi
    fi
    
    if [[ ! -f "$config_file" ]]; then
        nftban_log_error "Config file not found: $config_file"
        return 1
    fi
    
    # Check if exists
    if ! grep -qE "^${port}\|${protocol}$" "$config_file" 2>/dev/null; then
        nftban_log_error "Port not found: ${port}|${protocol}"
        return 1
    fi
    
    # Remove from config
    sed -i "/^${port}|${protocol}$/d" "$config_file"
    
    nftban_log_success "Removed port: ${port}|${protocol} from IPv${ip_version} ${direction}"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] REMOVE: ${port}|${protocol} <- $(basename "$config_file")" >> "$NFTBAN_PORT_LOG"
    
    return 0
}

# List configured ports
nftban_port_list() {
    local filter="${1:-all}"  # all, input, output, ipv4, ipv6
    
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Configured Ports"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    
    # Helper function to display ports from a file
    display_ports() {
        local file="$1"
        local label="$2"
        
        if [[ ! -f "$file" ]]; then
            echo "  File not found"
            return
        fi
        
        echo -e "${NFTBAN_CYAN}${label}:${NFTBAN_NC}"
        
        local count=0
        while IFS='|' read -r port proto; do
            # Skip empty lines and comments
            [[ -z "$port" || "$port" =~ ^# ]] && continue
            
            ((count++)) || true
            
            local proto_name
            case "$proto" in
                T) proto_name="TCP" ;;
                U) proto_name="UDP" ;;
                B) proto_name="TCP+UDP" ;;
                *) proto_name="$proto" ;;
            esac
            
            printf "  %-20s %-10s\n" "$port" "$proto_name"
        done < <(grep -vE '^#|^$' "$file" 2>/dev/null || true)
        
        if [[ $count -eq 0 ]]; then
            echo "  (none)"
        fi
        echo ""
    }
    
    # Display based on filter
    case "$filter" in
        all)
            display_ports "$NFTBAN_IPV4_INPUT_PORTS" "IPv4 INPUT"
            display_ports "$NFTBAN_IPV4_OUTPUT_PORTS" "IPv4 OUTPUT"
            display_ports "$NFTBAN_IPV6_INPUT_PORTS" "IPv6 INPUT"
            display_ports "$NFTBAN_IPV6_OUTPUT_PORTS" "IPv6 OUTPUT"
            ;;
        input)
            display_ports "$NFTBAN_IPV4_INPUT_PORTS" "IPv4 INPUT"
            display_ports "$NFTBAN_IPV6_INPUT_PORTS" "IPv6 INPUT"
            ;;
        output)
            display_ports "$NFTBAN_IPV4_OUTPUT_PORTS" "IPv4 OUTPUT"
            display_ports "$NFTBAN_IPV6_OUTPUT_PORTS" "IPv6 OUTPUT"
            ;;
        ipv4)
            display_ports "$NFTBAN_IPV4_INPUT_PORTS" "IPv4 INPUT"
            display_ports "$NFTBAN_IPV4_OUTPUT_PORTS" "IPv4 OUTPUT"
            ;;
        ipv6)
            display_ports "$NFTBAN_IPV6_INPUT_PORTS" "IPv6 INPUT"
            display_ports "$NFTBAN_IPV6_OUTPUT_PORTS" "IPv6 OUTPUT"
            ;;
        *)
            nftban_log_error "Unknown filter: $filter"
            return 1
            ;;
    esac
    
    echo "═══════════════════════════════════════════════════════"
}

# =============================================================================
# NFTABLES RULE GENERATION
# =============================================================================

# Generate nftables rules from port configuration
nftban_port_generate_rules() {
    local file="$1"
    local chain="$2"  # input or output
    
    [[ -f "$file" ]] || return 0
    
    while IFS='|' read -r port protocol; do
        # Skip empty lines and comments
        [[ -z "$port" || "$port" =~ ^# ]] && continue
        
        # Validate line
        nftban_port_validate_line "${port}|${protocol}" || {
            nftban_log_warning "Invalid port line: ${port}|${protocol}"
            continue
        }
        
        # Handle port ranges
        if [[ "$port" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start="${BASH_REMATCH[1]}"
            local end="${BASH_REMATCH[2]}"
            
            case "$protocol" in
                T)
                    echo "    tcp dport ${start}-${end} accept"
                    ;;
                U)
                    echo "    udp dport ${start}-${end} accept"
                    ;;
                B)
                    echo "    tcp dport ${start}-${end} accept"
                    echo "    udp dport ${start}-${end} accept"
                    ;;
            esac
        else
            # Single port
            case "$protocol" in
                T)
                    echo "    tcp dport $port accept"
                    ;;
                U)
                    echo "    udp dport $port accept"
                    ;;
                B)
                    echo "    tcp dport $port accept"
                    echo "    udp dport $port accept"
                    ;;
            esac
        fi
    done < <(grep -vE '^#|^$' "$file" 2>/dev/null || true)
}

# Apply port rules to nftables
nftban_port_apply_to_nftables() {
    local direction="$1"  # input or output
    
    nftban_log_info "Applying port rules to nftables ($direction)..."
    
    if ! nftban_check_nftables_table; then
        nftban_log_error "nftables table not initialized"
        return 1
    fi
    
    # Determine config files
    local ipv4_config ipv6_config
    if [[ "$direction" == "input" ]]; then
        ipv4_config="$NFTBAN_IPV4_INPUT_PORTS"
        ipv6_config="$NFTBAN_IPV6_INPUT_PORTS"
    else
        ipv4_config="$NFTBAN_IPV4_OUTPUT_PORTS"
        ipv6_config="$NFTBAN_IPV6_OUTPUT_PORTS"
    fi
    
    local rules_applied=0
    
    # Process IPv4 ports
    if [[ -f "$ipv4_config" ]]; then
        while IFS='|' read -r port protocol; do
            [[ -z "$port" || "$port" =~ ^# ]] && continue

            case "$protocol" in
                T)
                    nft add rule ip "$NFTBAN_NFT_TABLE_V4" "$direction" tcp dport "$port" accept 2>/dev/null && ((rules_applied++)) || true
                    ;;
                U)
                    nft add rule ip "$NFTBAN_NFT_TABLE_V4" "$direction" udp dport "$port" accept 2>/dev/null && ((rules_applied++)) || true
                    ;;
                B)
                    nft add rule ip "$NFTBAN_NFT_TABLE_V4" "$direction" tcp dport "$port" accept 2>/dev/null && ((rules_applied++)) || true
                    nft add rule ip "$NFTBAN_NFT_TABLE_V4" "$direction" udp dport "$port" accept 2>/dev/null && ((rules_applied++)) || true
                    ;;
            esac
        done < <(grep -vE '^#|^$' "$ipv4_config" 2>/dev/null || true)
    fi
    
    # Process IPv6 ports
    if [[ -f "$ipv6_config" ]]; then
        while IFS='|' read -r port protocol; do
            [[ -z "$port" || "$port" =~ ^# ]] && continue

            case "$protocol" in
                T)
                    nft add rule ip6 "$NFTBAN_NFT_TABLE_V6" "$direction" tcp dport "$port" accept 2>/dev/null && ((rules_applied++)) || true
                    ;;
                U)
                    nft add rule ip6 "$NFTBAN_NFT_TABLE_V6" "$direction" udp dport "$port" accept 2>/dev/null && ((rules_applied++)) || true
                    ;;
                B)
                    nft add rule ip6 "$NFTBAN_NFT_TABLE_V6" "$direction" tcp dport "$port" accept 2>/dev/null && ((rules_applied++)) || true
                    nft add rule ip6 "$NFTBAN_NFT_TABLE_V6" "$direction" udp dport "$port" accept 2>/dev/null && ((rules_applied++)) || true
                    ;;
            esac
        done < <(grep -vE '^#|^$' "$ipv6_config" 2>/dev/null || true)
    fi
    
    nftban_log_success "Applied $rules_applied port rules to $direction chain"
    return 0
}

# Validate all port configurations
nftban_port_validate_all() {
    nftban_log_info "Validating all port configurations..."
    
    local total=0
    local valid=0
    local invalid=0
    
    local files=(
        "$NFTBAN_IPV4_INPUT_PORTS"
        "$NFTBAN_IPV4_OUTPUT_PORTS"
        "$NFTBAN_IPV6_INPUT_PORTS"
        "$NFTBAN_IPV6_OUTPUT_PORTS"
    )
    
    for file in "${files[@]}"; do
        [[ ! -f "$file" ]] && continue
        
        local filename=$(basename "$file")
        echo ""
        echo "Validating: $filename"
        
        while IFS= read -r line; do
            # Skip empty lines and comments
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            
            ((total++)) || true
            
            if nftban_port_validate_line "$line"; then
                ((valid++)) || true
                echo -e "  ${NFTBAN_GREEN}✓${NFTBAN_NC} $line"
            else
                ((invalid++)) || true
                echo -e "  ${NFTBAN_RED}✗${NFTBAN_NC} $line (INVALID)"
            fi
        done < "$file"
    done
    
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "Validation Summary:"
    echo "  Total entries: $total"
    echo "  Valid: $valid"
    echo "  Invalid: $invalid"
    echo "═══════════════════════════════════════════════════════"
    
    if [[ $invalid -gt 0 ]]; then
        nftban_log_warning "Found $invalid invalid port configurations"
        return 1
    fi
    
    nftban_log_success "All port configurations are valid"
    return 0
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_port_init
export -f nftban_port_add
export -f nftban_port_remove
export -f nftban_port_list
export -f nftban_port_normalize_protocol
export -f nftban_port_validate_line
export -f nftban_port_validate_all
export -f nftban_port_generate_rules
export -f nftban_port_apply_to_nftables

nftban_log_debug "NFTBan Port Management Module loaded (BUG54 fix applied)"
