#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - System IP Auto-Detection Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_system_ip"
# meta:type="core"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-11-05"
# meta:description="Automatic detection and protection of system IPs with atomic operations"
# meta:input="Network interfaces and current connections"
# meta:output="Auto-whitelisted system IPs and synchronization to nftables"
# meta:depends="ip,hostname,nftban_file_ops.sh,nft"
# meta:platform="linux"
# meta:inventory.files="/etc/nftban/whitelist.d/00-system.conf"
# meta:inventory.binaries="ip,hostname,nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/whitelist.d/00-system.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

# Strict mode for production-grade security
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_SYSTEM_IP_LOADED:-}" ]] && return 0
readonly NFTBAN_SYSTEM_IP_LOADED=1

# Default paths (may be overridden by caller)
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"

# Load dependencies
if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_file_ops.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/core/nftban_file_ops.sh"
fi

: "${NFTBAN_WHITELIST_SYSTEM:=/etc/nftban/whitelist.d/00-system.conf}"

# =============================================================================
# PUBLIC IP DETECTION
# =============================================================================

nftban_get_public_ip() {
    local ip_type="$1"  # ipv4 or ipv6
    local ip=""

    # Primary method: Use ip command (fast, reliable, no network dependency)
    if command -v ip &>/dev/null; then
        if [[ "$ip_type" == "ipv4" ]]; then
            # Get first global IPv4 (excluding loopback)
            ip=$(ip -4 addr show scope global 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
        else
            # Get first global IPv6 (excluding link-local fe80::)
            ip=$(ip -6 addr show scope global 2>/dev/null | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^fe80:' | head -1)
        fi

        # Return if found via ip command
        if [[ -n "$ip" ]]; then
            echo "$ip"
            return 0
        fi
    fi

    # Fallback method: External services (if ip command unavailable or no result)
    local services=(
        "https://api.ipify.org"
        "https://icanhazip.com"
        "https://ident.me"
        "https://ifconfig.me/ip"
    )

    for service in "${services[@]}"; do
        if command -v curl &>/dev/null; then
            if [[ "$ip_type" == "ipv4" ]]; then
                ip=$(curl -4 -s --connect-timeout 3 "$service" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
            else
                # Fixed IPv6 regex - more strict to avoid matching timestamps
                ip=$(curl -6 -s --connect-timeout 3 "$service" 2>/dev/null | grep -Eo '(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:))' | head -1)
            fi
            [[ -n "$ip" ]] && break
        elif command -v wget &>/dev/null; then
            if [[ "$ip_type" == "ipv4" ]]; then
                ip=$(wget -4 -q -O - --timeout=3 "$service" 2>/dev/null | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
            else
                # Fixed IPv6 regex - more strict to avoid matching timestamps
                ip=$(wget -6 -q -O - --timeout=3 "$service" 2>/dev/null | grep -Eo '(([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:))' | head -1)
            fi
            [[ -n "$ip" ]] && break
        fi
    done

    echo "$ip"
}

# =============================================================================
# CURRENT USER IP DETECTION
# =============================================================================

nftban_get_current_user_ip() {
    # Try SSH_CLIENT first (most reliable for SSH connections)
    local ssh_client="${SSH_CLIENT%% *}"
    if [[ -n "$ssh_client" ]]; then
        echo "$ssh_client"
        return 0
    fi

    # Try SSH_CONNECTION
    if [[ -n "${SSH_CONNECTION}" ]]; then
        echo "${SSH_CONNECTION%% *}"
        return 0
    fi

    # Try who command
    local who_output
    who_output=$(who -u 2>/dev/null | awk '{print $NF}' | tr -d '()' | head -1)
    if [[ -n "$who_output" && "$who_output" != "0.0.0.0" && "$who_output" != ":0" ]]; then
        echo "$who_output"
        return 0
    fi

    # Try last command
    local last_ip
    last_ip=$(last -i 2>/dev/null | grep "still logged in" | awk '{print $3}' | head -1)
    if [[ -n "$last_ip" && "$last_ip" != "0.0.0.0" ]]; then
        echo "$last_ip"
        return 0
    fi

    # No remote connection detected
    return 1
}

# =============================================================================
# INTERFACE IP DETECTION
# =============================================================================

nftban_get_interface_ips() {
    # Get all IPv4 and IPv6 addresses from all interfaces
    # Excludes 127.0.0.1 and ::1 (handled separately)
    ip -o addr show 2>/dev/null | \
        awk '/inet/ {gsub(/\/.*/, "", $4); print $4}' | \
        grep -v "^127\." | \
        grep -v "^::1$" | \
        sort -u
}

# =============================================================================
# CHECK IF IP ALREADY WHITELISTED
# =============================================================================

nftban_is_ip_whitelisted() {
    local ip="$1"

    # Check if IP exists in system whitelist
    [[ -f "$NFTBAN_WHITELIST_SYSTEM" ]] || return 1

    # Match IP at start of line (with optional CIDR)
    grep -qE "^${ip}([[:space:]]|/|$)" "$NFTBAN_WHITELIST_SYSTEM" 2>/dev/null
}

# =============================================================================
# ADD IP TO SYSTEM WHITELIST (ATOMIC)
# =============================================================================

nftban_add_system_ip() {
    local ip="$1"
    local comment="$2"

    # Skip if already whitelisted
    if nftban_is_ip_whitelisted "$ip"; then
        echo "[SKIP] Already whitelisted: $ip"
        return 0
    fi

    # Ensure whitelist file exists
    if [[ ! -f "$NFTBAN_WHITELIST_SYSTEM" ]]; then
        mkdir -p "$(dirname "$NFTBAN_WHITELIST_SYSTEM")"
        cat > "$NFTBAN_WHITELIST_SYSTEM" <<'HEADER'
# NFTBan System Whitelist - Auto-Generated
# DO NOT EDIT MANUALLY - Use: nftban whitelist-system sync
# This file contains auto-detected system IPs (localhost, interfaces, public IPs)
HEADER
    fi

    # Add IP using atomic append
    if declare -f nftban_atomic_append >/dev/null 2>&1; then
        echo "$ip  # $comment (added: $(date -u +'%Y-%m-%d %H:%M:%S UTC'))" | \
            nftban_atomic_append "$NFTBAN_WHITELIST_SYSTEM"
    else
        # Fallback to regular append if atomic not available
        echo "$ip  # $comment (added: $(date -u +'%Y-%m-%d %H:%M:%S UTC'))" >> "$NFTBAN_WHITELIST_SYSTEM"
    fi

    # Also add to nftables immediately (don't wait for sync)
    if command -v nft &>/dev/null; then
        if [[ "$ip" =~ : ]]; then
            # IPv6
            nft add element ip6 nftban whitelist_ipv6 "{ $ip }" 2>/dev/null || true
        else
            # IPv4
            nft add element ip nftban whitelist_ipv4 "{ $ip }" 2>/dev/null || true
        fi
    fi

    echo "[ADD] Whitelisted: $ip ($comment)"
}

# =============================================================================
# REMOVE IP FROM BLACKLISTS
# =============================================================================

nftban_remove_from_blacklists() {
    local ip="$1"
    local removed=0

    # Find all blacklist files
    local blacklist_files=(
        /etc/nftban/blacklist.d/*.conf
    )

    for file in "${blacklist_files[@]}"; do
        [[ ! -f "$file" ]] && continue

        # Check if IP exists in this blacklist
        if grep -qE "^${ip}([[:space:]]|/|$)" "$file" 2>/dev/null; then
            echo "  [REMOVE] Removing $ip from $(basename "$file")"

            # Remove IP using atomic operation
            if declare -f nftban_atomic_write >/dev/null 2>&1; then
                grep -vE "^${ip}([[:space:]]|/|$)" "$file" | nftban_atomic_write "$file"
            else
                # Fallback to temp file
                local tmpfile
                tmpfile=$(mktemp)
                grep -vE "^${ip}([[:space:]]|/|$)" "$file" > "$tmpfile"
                mv "$tmpfile" "$file"
            fi

            removed=$((removed + 1)) || true
        fi
    done

    return $removed
}

# =============================================================================
# AUTO-DETECT AND WHITELIST ALL SYSTEM IPS
# =============================================================================

nftban_whitelist_system_sync() {
    # Args: $1 = quick_mode (true/false) - skip public IP detection for faster install
    local quick_mode="${1:-false}"

    echo "═══════════════════════════════════════════════════════"
    echo "NFTBan System IP Auto-Detection"
    [[ "$quick_mode" == "true" ]] && echo "(Quick mode - skipping public IP detection)"
    echo "═══════════════════════════════════════════════════════"
    echo ""

    local protected=0
    local removed_from_blacklist=0
    local steps=5
    [[ "$quick_mode" == "true" ]] && steps=3

    # 1. Localhost IPs
    echo "[1/${steps}] Protecting localhost..."
    for ip in "127.0.0.1" "::1"; do
        if nftban_add_system_ip "$ip" "Localhost (critical)"; then
            protected=$((protected + 1)) || true
        fi
        # Ensure not in blacklist
        if nftban_remove_from_blacklists "$ip"; then
            removed_from_blacklist=$((removed_from_blacklist + 1)) || true
        fi
    done
    echo ""

    # 2. Interface IPs
    echo "[2/${steps}] Protecting server interface IPs..."
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        if nftban_add_system_ip "$ip" "Server interface (auto-detected)"; then
            protected=$((protected + 1)) || true
        fi
        # Ensure not in blacklist
        if nftban_remove_from_blacklists "$ip"; then
            removed_from_blacklist=$((removed_from_blacklist + 1)) || true
        fi
    done < <(nftban_get_interface_ips)
    echo ""

    # 3. Public IPs (skip in quick mode - HTTP calls are slow)
    if [[ "$quick_mode" != "true" ]]; then
        echo "[3/${steps}] Detecting public IPs..."

        # Public IPv4
        local public_ipv4
        public_ipv4=$(nftban_get_public_ip "ipv4")
        if [[ -n "$public_ipv4" ]]; then
            if nftban_add_system_ip "$public_ipv4" "Server public IPv4 (auto-detected)"; then
                protected=$((protected + 1)) || true
            fi
            # Ensure not in blacklist
            if nftban_remove_from_blacklists "$public_ipv4"; then
                removed_from_blacklist=$((removed_from_blacklist + 1)) || true
            fi
        else
            echo "[SKIP] No public IPv4 detected"
        fi

        # Public IPv6
        local public_ipv6
        public_ipv6=$(nftban_get_public_ip "ipv6")
        if [[ -n "$public_ipv6" ]]; then
            if nftban_add_system_ip "$public_ipv6" "Server public IPv6 (auto-detected)"; then
                protected=$((protected + 1)) || true
            fi
            # Ensure not in blacklist
            if nftban_remove_from_blacklists "$public_ipv6"; then
                removed_from_blacklist=$((removed_from_blacklist + 1)) || true
            fi
        else
            echo "[SKIP] No public IPv6 detected"
        fi
        echo ""
    fi

    # Step N-1: Cleanup blacklists summary
    local step_cleanup=$((steps - 1))
    echo "[${step_cleanup}/${steps}] Ensuring system IPs not in blacklists..."
    if [[ $removed_from_blacklist -gt 0 ]]; then
        echo "  Removed $removed_from_blacklist IP(s) from blacklists"
    else
        echo "  No conflicts found"
    fi
    echo ""

    # Step N: Summary
    echo "[${steps}/${steps}] Summary"
    echo "  Protected: $protected system IP(s)"
    echo "  Removed from blacklists: $removed_from_blacklist IP(s)"
    [[ "$quick_mode" == "true" ]] && echo "  Note: Run 'nftban whitelist-system sync' later for public IP detection"
    echo ""
    echo "═══════════════════════════════════════════════════════"

    # Reload nftables if atomic reload available (skip verbose output in quick mode)
    if declare -f nftban_atomic_reload >/dev/null 2>&1; then
        [[ "$quick_mode" != "true" ]] && echo "" && echo "Syncing to nftables..."
        nftban_atomic_reload 2>/dev/null || true
    fi
}

# =============================================================================
# WHITELIST CURRENT USER (whitelistme)
# =============================================================================

nftban_whitelistme() {
    echo "═══════════════════════════════════════════════════════"
    echo "NFTBan: Whitelist Current User"
    echo "═══════════════════════════════════════════════════════"
    echo ""

    # Detect current user IP
    local current_ip
    current_ip=$(nftban_get_current_user_ip)

    if [[ -z "$current_ip" ]]; then
        echo "❌ ERROR: Could not detect your IP address"
        echo ""
        echo "Possible reasons:"
        echo "  • You are on the local console (not SSH)"
        echo "  • Connection info not available"
        echo ""
        echo "To manually whitelist your IP:"
        echo "  nftban whitelist add <YOUR_IP>"
        echo ""
        return 1
    fi

    echo "Detected your IP: $current_ip"
    echo ""

    # Check if already whitelisted
    if nftban_is_ip_whitelisted "$current_ip"; then
        echo "✓ Your IP is already whitelisted!"
        echo ""
        return 0
    fi

    # Ask for confirmation
    echo "⚠️  This will add your IP to the system whitelist"
    echo "   (You will NEVER be banned from this server)"
    echo ""
    read -p "Type 'YES' to confirm: " confirm

    if [[ "$confirm" != "YES" ]]; then
        echo "Cancelled."
        return 1
    fi

    # Add to whitelist
    if nftban_add_system_ip "$current_ip" "Current user (whitelistme on $(date +'%Y-%m-%d'))"; then
        echo ""
        echo "✓ SUCCESS! Your IP has been whitelisted"
        echo ""
        echo "IP: $current_ip"
        echo "Status: Protected from all bans"
        echo ""

        # Reload nftables if available
        if declare -f nftban_atomic_reload >/dev/null 2>&1; then
            echo "Syncing to nftables..."
            nftban_atomic_reload
            echo ""
        fi

        echo "═══════════════════════════════════════════════════════"
        return 0
    else
        echo ""
        echo "❌ ERROR: Failed to whitelist your IP"
        return 1
    fi
}

# =============================================================================
# SHOW SYSTEM WHITELIST
# =============================================================================

nftban_show_system_whitelist() {
    # Check for --json flag
    local json_output=false
    if [[ "${1:-}" == "--json" ]]; then
        json_output=true
    fi

    if [[ ! -f "$NFTBAN_WHITELIST_SYSTEM" ]]; then
        if [[ "$json_output" == true ]]; then
            json_output_error "System whitelist not found: $NFTBAN_WHITELIST_SYSTEM"
        else
            echo "❌ System whitelist not found: $NFTBAN_WHITELIST_SYSTEM"
            echo ""
            echo "Run: nftban whitelist-system sync"
        fi
        return 1
    fi

    # Extract IPs
    local ipv4_list ipv6_list
    ipv4_list=$(grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" "$NFTBAN_WHITELIST_SYSTEM" 2>/dev/null | awk '{print $1}' || true)
    ipv6_list=$(grep -E "^[0-9a-fA-F]*:[0-9a-fA-F:]*" "$NFTBAN_WHITELIST_SYSTEM" 2>/dev/null | awk '{print $1}' || true)

    if [[ "$json_output" == true ]]; then
        # JSON output
        local ipv4_json ipv6_json
        if [[ -n "$ipv4_list" ]]; then
            ipv4_json=$(echo "$ipv4_list" | jq -R -s -c 'split("\n") | map(select(length > 0))')
        else
            ipv4_json="[]"
        fi

        if [[ -n "$ipv6_list" ]]; then
            ipv6_json=$(echo "$ipv6_list" | jq -R -s -c 'split("\n") | map(select(length > 0))')
        else
            ipv6_json="[]"
        fi

        cat <<EOF
{
  "success": true,
  "data": {
    "file": "$NFTBAN_WHITELIST_SYSTEM",
    "ipv4": $ipv4_json,
    "ipv6": $ipv6_json,
    "total": $(echo "$ipv4_list $ipv6_list" | wc -w)
  }
}
EOF
    else
        # Human-readable output
        echo "═══════════════════════════════════════════════════════"
        echo "NFTBan System Whitelist"
        echo "═══════════════════════════════════════════════════════"
        echo ""
        echo "File: $NFTBAN_WHITELIST_SYSTEM"
        echo ""

        # Count IPs
        local ipv4_count ipv6_count
        ipv4_count=$(echo "$ipv4_list" | wc -w)
        ipv6_count=$(echo "$ipv6_list" | wc -w)

        echo "IPv4: $ipv4_count entries"
        echo "IPv6: $ipv6_count entries"
        echo ""

        echo "Protected IPs:"
        echo ""

        # Show all IPs with comments
        grep -vE "^[[:space:]]*#|^[[:space:]]*$" "$NFTBAN_WHITELIST_SYSTEM" | \
            awk '{
                ip = $1
                comment = ""
                for(i=3; i<=NF; i++) comment = comment $i " "
                printf "  %-40s %s\n", ip, comment
            }' || echo "  (empty)"

        echo ""
        echo "═══════════════════════════════════════════════════════"
    fi
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_get_public_ip
export -f nftban_get_current_user_ip
export -f nftban_get_interface_ips
export -f nftban_is_ip_whitelisted
export -f nftban_add_system_ip
export -f nftban_whitelist_system_sync
export -f nftban_whitelistme
export -f nftban_show_system_whitelist
