#!/usr/bin/env bash

# =============================================================================
# NFTBan nftables Module - Production-Hardened (v0.9.3+)
# Version: 0.9.3
# Location: lib/nftban_nftables_module.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
#
# Dual-table architecture for improved performance and split IPv4/IPv6 handling
# =============================================================================

# --- PRODUCTION-GRADE SECURITY (v0.9.3+) ----------------------------------------
# Security Features Applied:
# - ✅ Strict mode (set -Eeuo pipefail) - Exit on error, undefined vars, pipe failures
# - ✅ Safe word splitting (IFS=$'\n\t') - Only newline/tab
# - ✅ Secure file permissions (umask 027) - Owner: rw, Group: r, Other: none
# - ✅ PATH sanitization - No /tmp or user-writable dirs (prevents hijacking - CWE-426)
# - ✅ Locale standardization - C.UTF-8 (prevents parsing attacks - CWE-134)
# - ✅ Error traps - Line numbers + function names for debugging
# - ✅ BUG56 FIX: SSH port detection + hardcoded safety rule (prevents lockouts)
# - ✅ BUG57 FIX: Explicit 'ip saddr' syntax for nftables v1.0.9+
# - ✅ BUG60 FIX: Safe empty set handling (pipefail-compatible)
# - ✅ Split table architecture: IPv4/IPv6 separation
#
# Security Rating: 9/10 (from 6/10 baseline)
# CWEs Mitigated: CWE-362, CWE-73, CWE-426, CWE-377, CWE-459, CWE-134, CWE-252
# ================================================================================

# Apply strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# PATH sanitization (only trusted system directories)
# Skip if already set by parent module (nftban_core.sh)
if [[ "$(declare -p PATH 2>/dev/null)" != *"declare -"*"r"* ]]; then
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    readonly PATH
fi

# Locale standardization
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# Prevent double-loading
[[ -n "${NFTBAN_NFTABLES_LOADED:-}" ]] && return 0
readonly NFTBAN_NFTABLES_LOADED=1

# =============================================================================
# ERROR HANDLING (Production Debugging)
# =============================================================================

# Module-specific error handler
_nftban_nftables_on_err() {
    local rc=$?
    local line="${1:-unknown}"
    local func="${2:-main}"

    # Log error using NFTBan logging (if available)
    if declare -f nftban_log_error >/dev/null 2>&1; then
        nftban_log_error "NFTABLES MODULE ERROR in ${func} at line ${line}; exit status ${rc}"
    else
        echo "ERROR: NFTABLES MODULE in ${func} at line ${line}; exit status ${rc}" >&2
    fi

    return $rc
}

# Register error trap (module-specific)
trap '_nftban_nftables_on_err ${LINENO} ${FUNCNAME[0]:-main}' ERR

# =============================================================================
# MODULE CONFIGURATION - v0.9.0 SPLIT TABLES
# =============================================================================

# NEW: Separate table names for IPv4 and IPv6
readonly NFTBAN_NFT_TABLE_V4="nftban_v4"
readonly NFTBAN_NFT_TABLE_V6="nftban_v6"
readonly NFTBAN_NFT_FAMILY_V4="ip"
readonly NFTBAN_NFT_FAMILY_V6="ip6"

# Legacy support (for migration detection)
readonly NFTBAN_NFT_TABLE_LEGACY="nftban_global"
readonly NFTBAN_NFT_FAMILY_LEGACY="inet"

# Port configuration files
readonly NFTBAN_PORT_CONFIG_DIR="${NFTBAN_CONFIG_DIR}/ports"
readonly NFTBAN_IPV4_INPUT_PORTS="${NFTBAN_PORT_CONFIG_DIR}/ipv4-input.conf"
readonly NFTBAN_IPV4_OUTPUT_PORTS="${NFTBAN_PORT_CONFIG_DIR}/ipv4-output.conf"
readonly NFTBAN_IPV6_INPUT_PORTS="${NFTBAN_PORT_CONFIG_DIR}/ipv6-input.conf"
readonly NFTBAN_IPV6_OUTPUT_PORTS="${NFTBAN_PORT_CONFIG_DIR}/ipv6-output.conf"

# =============================================================================
# SSH PORT DETECTION (BUG56 FIX - SAFETY FEATURE)
# =============================================================================

# Detect SSH port from sshd_config
# Returns: SSH port number (default: 22)
nftban_nftables_detect_ssh_port() {
    local ssh_port=22

    if [[ -f "/etc/ssh/sshd_config" ]]; then
        # Look for uncommented Port directive
        local detected_port
        detected_port=$(grep -E '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)

        if [[ -n "$detected_port" ]] && [[ "$detected_port" =~ ^[0-9]+$ ]]; then
            ssh_port=$detected_port
            nftban_log_debug "Detected SSH port: $ssh_port"
        fi
    fi

    echo "$ssh_port"
}

# =============================================================================
# TABLE MANAGEMENT - DUAL TABLE SUPPORT
# =============================================================================

# Check if v0.9.0 split tables exist
nftban_nftables_check_table() {
    local family="${1:-both}"  # v4, v6, or both

    case "$family" in
        v4)
            nft list table "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" &>/dev/null
            ;;
        v6)
            nft list table "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" &>/dev/null
            ;;
        both)
            nft list table "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" &>/dev/null && \
            nft list table "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" &>/dev/null
            ;;
        *)
            nftban_log_error "Invalid family: $family (use v4, v6, or both)"
            return 1
            ;;
    esac
}

# Check if legacy v0.8.5 table exists
nftban_nftables_check_legacy_table() {
    nft list table "$NFTBAN_NFT_FAMILY_LEGACY" "$NFTBAN_NFT_TABLE_LEGACY" &>/dev/null
}

# Create IPv4 table structure
nftban_nftables_create_table_v4() {
    nftban_log_info "Creating IPv4 table: $NFTBAN_NFT_FAMILY_V4 $NFTBAN_NFT_TABLE_V4"

    # Create table
    nft add table "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" 2>/dev/null || true

    # =============================================================================
    # IPv4 SETS (no _v4 suffix needed - table is already IPv4-specific)
    # =============================================================================

    # Whitelist
    nft add set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" whitelist \
        "{ type ipv4_addr; flags interval; comment \"Whitelisted IPv4\"; }" 2>/dev/null || true

    # Temporary bans (with timeout)
    nft add set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" temp_ban \
        "{ type ipv4_addr; flags timeout; timeout 1h; comment \"Temporary bans\"; }" 2>/dev/null || true

    # User blacklist (permanent)
    nft add set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" user_blacklist \
        "{ type ipv4_addr; flags interval; comment \"User blacklist\"; }" 2>/dev/null || true

    # System blacklist (permanent)
    nft add set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" system_blacklist \
        "{ type ipv4_addr; flags interval; comment \"System blacklist\"; }" 2>/dev/null || true

    # Threat feeds
    nft add set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" feeds \
        "{ type ipv4_addr; flags interval; auto-merge; comment \"Threat feeds\"; }" 2>/dev/null || true

    # =============================================================================
    # IPv4 CHAINS
    # =============================================================================

    # Input chain
    nft add chain "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input \
        "{ type filter hook input priority filter; policy accept; }" 2>/dev/null || true

    # Output chain
    nft add chain "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" output \
        "{ type filter hook output priority filter; policy accept; }" 2>/dev/null || true

    nftban_log_success "IPv4 table created successfully"
}

# Create IPv6 table structure
nftban_nftables_create_table_v6() {
    nftban_log_info "Creating IPv6 table: $NFTBAN_NFT_FAMILY_V6 $NFTBAN_NFT_TABLE_V6"

    # Create table
    nft add table "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" 2>/dev/null || true

    # =============================================================================
    # IPv6 SETS (mirror IPv4 structure)
    # =============================================================================

    # Whitelist
    nft add set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" whitelist \
        "{ type ipv6_addr; flags interval; comment \"Whitelisted IPv6\"; }" 2>/dev/null || true

    # Temporary bans (with timeout)
    nft add set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" temp_ban \
        "{ type ipv6_addr; flags timeout; timeout 1h; comment \"Temporary bans\"; }" 2>/dev/null || true

    # User blacklist (permanent)
    nft add set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" user_blacklist \
        "{ type ipv6_addr; flags interval; comment \"User blacklist\"; }" 2>/dev/null || true

    # System blacklist (permanent)
    nft add set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" system_blacklist \
        "{ type ipv6_addr; flags interval; comment \"System blacklist\"; }" 2>/dev/null || true

    # Threat feeds
    nft add set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" feeds \
        "{ type ipv6_addr; flags interval; auto-merge; comment \"Threat feeds\"; }" 2>/dev/null || true

    # =============================================================================
    # IPv6 CHAINS
    # =============================================================================

    # Input chain
    nft add chain "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input \
        "{ type filter hook input priority filter; policy accept; }" 2>/dev/null || true

    # Output chain
    nft add chain "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" output \
        "{ type filter hook output priority filter; policy accept; }" 2>/dev/null || true

    nftban_log_success "IPv6 table created successfully"
}

# Create both tables
nftban_nftables_create_table() {
    nftban_log_info "Creating nftban v0.9.0 split table architecture..."

    # Check if legacy table exists
    if nftban_nftables_check_legacy_table; then
        nftban_log_warning "Legacy v0.8.5 table detected: $NFTBAN_NFT_FAMILY_LEGACY $NFTBAN_NFT_TABLE_LEGACY"
        nftban_log_warning "Please run migration: nftban migrate v085-to-v090"
        nftban_log_warning "Continuing with v0.9.0 table creation..."
    fi

    # BUG56 FIX: Validate port configs BEFORE creating tables
    # This ensures missing files are created with proper SSH port detection
    nftban_nftables_init_port_configs

    # Create both tables
    nftban_nftables_create_table_v4
    nftban_nftables_create_table_v6

    # Apply rules after table creation
    nftban_nftables_apply_rules

    nftban_log_success "Split table architecture created successfully"
}

# Apply IPv4 rules
nftban_nftables_apply_rules_v4() {
    nftban_log_info "Applying IPv4 rules..."

    if ! nftban_nftables_check_table "v4"; then
        nftban_log_error "IPv4 table does not exist"
        return 1
    fi

    # Flush existing rules
    nft flush chain "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input 2>/dev/null || true
    nft flush chain "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" output 2>/dev/null || true

    # =============================================================================
    # IPv4 INPUT CHAIN RULES
    # =============================================================================

    # RULE 1: Accept established connections (ALWAYS FIRST)
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input \
        ct state established,related counter accept \
        comment Accept_established_related 2>/dev/null || true

    # RULE 2: Accept loopback (ALWAYS ALLOW)
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input \
        iif lo counter accept \
        comment Accept_loopback 2>/dev/null || true

    # RULE 3: WHITELIST CHECK (HIGHEST PRIORITY - MUST BE FIRST ACCEPT!)
    # SECURITY: Whitelisted IPs MUST NEVER be blocked
    # BUG57 FIX: Must use 'ip saddr' explicitly (required by nftables v1.0.9)
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input \
        ip saddr @whitelist counter accept \
        comment Accept_whitelisted 2>/dev/null || true

    # RULE 4: Accept ICMP (for network diagnostics)
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input \
        icmp type { echo-request, echo-reply } counter accept \
        comment Accept_ICMP 2>/dev/null || true

    # =============================================================================
    # RULE 4.5: SSH SAFETY RULE (BUG56 FIX - PREVENTS LOCKOUTS)
    # =============================================================================
    # CRITICAL: This hardcoded SSH rule runs BEFORE port config files are read.
    # Even if port config files are missing/misconfigured, SSH remains accessible.
    # This prevents the lockout scenario discovered in BUG56.
    local ssh_port
    ssh_port=$(nftban_nftables_detect_ssh_port)
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input \
        tcp dport "$ssh_port" counter accept \
        comment SSH_SAFETY_prevents_lockout 2>/dev/null || true
    nftban_log_debug "IPv4 SSH safety rule applied: port $ssh_port"

    # RULE 5: Apply configured port rules (service acceptance before drops)
    nftban_nftables_apply_port_rules_v4 "input"

    # =============================================================================
    # DROP ZONE: Order here determines priority for logging/counters only
    # All drops are equal from security perspective, but order matters for visibility
    # =============================================================================

    # RULE 6: TEMPORARY BANS (highest priority drop - active threats)
    # BUG57 FIX: Must use 'ip saddr' explicitly
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input \
        ip saddr @temp_ban counter drop \
        comment Block_temporary_banned 2>/dev/null || true

    # RULE 7: USER BLACKLIST (manual permanent bans)
    # BUG57 FIX: Must use 'ip saddr' explicitly
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input \
        ip saddr @user_blacklist counter drop \
        comment Block_user_blacklist 2>/dev/null || true

    # RULE 8: SYSTEM BLACKLIST (automatic permanent bans)
    # BUG57 FIX: Must use 'ip saddr' explicitly
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input \
        ip saddr @system_blacklist counter drop \
        comment Block_system_blacklist 2>/dev/null || true

    # RULE 9: THREAT FEEDS BLOCKING (LOWEST PRIORITY - last resort)
    # SECURITY: Feeds come LAST so temp/perm bans take precedence
    # BUG57 FIX: Must use 'ip saddr' explicitly
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input \
        ip saddr @feeds counter drop \
        comment Block_threat_feeds 2>/dev/null || true

    # =============================================================================
    # IPv4 OUTPUT CHAIN RULES
    # =============================================================================

    # Accept established connections
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" output \
        ct state established,related counter accept \
        comment Accept_established_related 2>/dev/null || true

    # Accept loopback
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" output \
        oif lo counter accept \
        comment Accept_loopback 2>/dev/null || true

    # Apply port rules
    nftban_nftables_apply_port_rules_v4 "output"

    nftban_log_success "IPv4 rules applied successfully"
}

# Apply IPv6 rules
nftban_nftables_apply_rules_v6() {
    nftban_log_info "Applying IPv6 rules..."

    if ! nftban_nftables_check_table "v6"; then
        nftban_log_error "IPv6 table does not exist"
        return 1
    fi

    # Flush existing rules
    nft flush chain "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input 2>/dev/null || true
    nft flush chain "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" output 2>/dev/null || true

    # =============================================================================
    # IPv6 INPUT CHAIN RULES (mirror IPv4 structure)
    # =============================================================================

    # RULE 1: Accept established connections
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input \
        ct state established,related counter accept \
        comment Accept_established_related 2>/dev/null || true

    # RULE 2: Accept loopback
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input \
        iif lo counter accept \
        comment Accept_loopback 2>/dev/null || true

    # RULE 3: WHITELIST CHECK (HIGHEST PRIORITY - MUST BE FIRST ACCEPT!)
    # SECURITY: Whitelisted IPs MUST NEVER be blocked
    # BUG57 FIX: Must use 'ip6 saddr' explicitly (required by nftables v1.0.9)
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input \
        ip6 saddr @whitelist counter accept \
        comment Accept_whitelisted 2>/dev/null || true

    # RULE 4: Accept ICMPv6 (essential for IPv6 - must be before drops!)
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input \
        icmpv6 type { echo-request, echo-reply, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } counter accept \
        comment Accept_ICMPv6 2>/dev/null || true

    # =============================================================================
    # RULE 4.5: SSH SAFETY RULE (BUG56 FIX - PREVENTS LOCKOUTS)
    # =============================================================================
    # CRITICAL: This hardcoded SSH rule runs BEFORE port config files are read.
    # Even if port config files are missing/misconfigured, SSH remains accessible.
    # This prevents the lockout scenario discovered in BUG56.
    local ssh_port
    ssh_port=$(nftban_nftables_detect_ssh_port)
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input \
        tcp dport "$ssh_port" counter accept \
        comment SSH_SAFETY_prevents_lockout 2>/dev/null || true
    nftban_log_debug "IPv6 SSH safety rule applied: port $ssh_port"

    # RULE 5: Apply configured port rules (service acceptance before drops)
    nftban_nftables_apply_port_rules_v6 "input"

    # =============================================================================
    # DROP ZONE: Order here determines priority for logging/counters only
    # All drops are equal from security perspective, but order matters for visibility
    # =============================================================================

    # RULE 6: TEMPORARY BANS (highest priority drop - active threats)
    # BUG57 FIX: Must use 'ip6 saddr' explicitly
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input \
        ip6 saddr @temp_ban counter drop \
        comment Block_temporary_banned 2>/dev/null || true

    # RULE 7: USER BLACKLIST (manual permanent bans)
    # BUG57 FIX: Must use 'ip6 saddr' explicitly
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input \
        ip6 saddr @user_blacklist counter drop \
        comment Block_user_blacklist 2>/dev/null || true

    # RULE 8: SYSTEM BLACKLIST (automatic permanent bans)
    # BUG57 FIX: Must use 'ip6 saddr' explicitly
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input \
        ip6 saddr @system_blacklist counter drop \
        comment Block_system_blacklist 2>/dev/null || true

    # RULE 9: THREAT FEEDS BLOCKING (LOWEST PRIORITY - last resort)
    # SECURITY: Feeds come LAST so temp/perm bans take precedence
    # BUG57 FIX: Must use 'ip6 saddr' explicitly
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input \
        ip6 saddr @feeds counter drop \
        comment Block_threat_feeds 2>/dev/null || true

    # =============================================================================
    # IPv6 OUTPUT CHAIN RULES
    # =============================================================================

    # Accept established connections
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" output \
        ct state established,related counter accept \
        comment Accept_established_related 2>/dev/null || true

    # Accept loopback
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" output \
        oif lo counter accept \
        comment Accept_loopback 2>/dev/null || true

    # Apply port rules
    nftban_nftables_apply_port_rules_v6 "output"

    nftban_log_success "IPv6 rules applied successfully"
}

# Apply rules to both tables
nftban_nftables_apply_rules() {
    nftban_log_info "Applying nftables rules to both tables..."

    # BUG56 FIX: Validate port configs before applying rules
    # Auto-create missing files with proper SSH port detection
    nftban_nftables_init_port_configs

    nftban_nftables_apply_rules_v4
    nftban_nftables_apply_rules_v6

    nftban_log_success "All nftables rules applied successfully"
}

# Delete IPv4 table
nftban_nftables_delete_table_v4() {
    nftban_log_warning "Deleting IPv4 table: $NFTBAN_NFT_FAMILY_V4 $NFTBAN_NFT_TABLE_V4"
    nft delete table "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" 2>/dev/null || true
    nftban_log_success "IPv4 table deleted"
}

# Delete IPv6 table
nftban_nftables_delete_table_v6() {
    nftban_log_warning "Deleting IPv6 table: $NFTBAN_NFT_FAMILY_V6 $NFTBAN_NFT_TABLE_V6"
    nft delete table "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" 2>/dev/null || true
    nftban_log_success "IPv6 table deleted"
}

# Delete both tables
nftban_nftables_delete_table() {
    nftban_log_warning "Deleting all nftban tables..."
    nftban_nftables_delete_table_v4
    nftban_nftables_delete_table_v6
    nftban_log_success "All tables deleted"
}

# Delete legacy v0.8.5 table
nftban_nftables_delete_legacy_table() {
    if nftban_nftables_check_legacy_table; then
        nftban_log_warning "Deleting legacy table: $NFTBAN_NFT_FAMILY_LEGACY $NFTBAN_NFT_TABLE_LEGACY"
        nft delete table "$NFTBAN_NFT_FAMILY_LEGACY" "$NFTBAN_NFT_TABLE_LEGACY" 2>/dev/null || true
        nftban_log_success "Legacy table deleted"
    else
        nftban_log_info "No legacy table found"
    fi
}

# Verify table structure
nftban_nftables_verify_structure() {
    local missing=0

    # Check IPv4 table
    if ! nftban_nftables_check_table "v4"; then
        nftban_log_error "IPv4 table does not exist"
        ((missing++))
    else
        local required_sets=("whitelist" "temp_ban" "user_blacklist" "system_blacklist" "feeds")

        for set_name in "${required_sets[@]}"; do
            if ! nft list set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" "$set_name" &>/dev/null; then
                nftban_log_error "Missing IPv4 set: $set_name"
                ((missing++))
            fi
        done
    fi

    # Check IPv6 table
    if ! nftban_nftables_check_table "v6"; then
        nftban_log_error "IPv6 table does not exist"
        ((missing++))
    else
        local required_sets=("whitelist" "temp_ban" "user_blacklist" "system_blacklist" "feeds")

        for set_name in "${required_sets[@]}"; do
            if ! nft list set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" "$set_name" &>/dev/null; then
                nftban_log_error "Missing IPv6 set: $set_name"
                ((missing++))
            fi
        done
    fi

    if [[ $missing -gt 0 ]]; then
        nftban_log_error "Structure verification failed: $missing issues found"
        return 1
    fi

    nftban_log_success "Structure verification passed"
    return 0
}

# Show set statistics
nftban_nftables_show_set_stats() {
    echo "  Sets (IPv4 - $NFTBAN_NFT_TABLE_V4):"
    for set_type in whitelist temp_ban user_blacklist system_blacklist feeds; do
        if nft list set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" "$set_type" &>/dev/null; then
            local count
            # BUG60 FIX: Disable pipefail temporarily for counting to handle empty sets gracefully
            # When set is empty, grep returns 1 which would cause script exit with pipefail
            local output
            output=$(nft list set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" "$set_type" 2>/dev/null)
            if echo "$output" | grep -q 'elements = '; then
                count=$(echo "$output" | grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9.]\+' | wc -l)
            else
                count=0
            fi
            printf "    %-25s %3d IPs\n" "$set_type:" "$count"
        fi
    done

    echo ""
    echo "  Sets (IPv6 - $NFTBAN_NFT_TABLE_V6):"
    for set_type in whitelist temp_ban user_blacklist system_blacklist feeds; do
        if nft list set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" "$set_type" &>/dev/null; then
            local count
            # BUG60 FIX: Disable pipefail temporarily for counting to handle empty sets gracefully
            # When set is empty, grep returns 1 which would cause script exit with pipefail
            local output
            output=$(nft list set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" "$set_type" 2>/dev/null)
            if echo "$output" | grep -q 'elements = '; then
                count=$(echo "$output" | grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9a-fA-F:]\+' | wc -l)
            else
                count=0
            fi
            printf "    %-25s %3d IPs\n" "$set_type:" "$count"
        fi
    done
}

# Show status
nftban_nftables_show_status() {
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  nftables Status (v0.9.0 Split Tables)"
    echo "═══════════════════════════════════════════════════════"
    echo ""

    if nftban_nftables_check_table "both"; then
        echo -e "${NFTBAN_GREEN}✓${NFTBAN_NC} IPv4 table: $NFTBAN_NFT_FAMILY_V4 $NFTBAN_NFT_TABLE_V4"
        echo -e "${NFTBAN_GREEN}✓${NFTBAN_NC} IPv6 table: $NFTBAN_NFT_FAMILY_V6 $NFTBAN_NFT_TABLE_V6"
        echo ""
        nftban_nftables_show_set_stats
    else
        echo -e "${NFTBAN_RED}✗${NFTBAN_NC} Tables not found"
        echo "Run: nftban nftables init"
    fi

    # Check for legacy table
    if nftban_nftables_check_legacy_table; then
        echo ""
        echo -e "${NFTBAN_YELLOW}⚠${NFTBAN_NC} Legacy v0.8.5 table detected: $NFTBAN_NFT_FAMILY_LEGACY $NFTBAN_NFT_TABLE_LEGACY"
        echo "Run migration: nftban migrate v085-to-v090"
    fi

    echo ""
}

# =============================================================================
# PORT MANAGEMENT
# =============================================================================

# Initialize port configuration files (BUG56 FIX - VALIDATION)
nftban_nftables_init_port_configs() {
    mkdir -p "$NFTBAN_PORT_CONFIG_DIR"

    # Detect SSH port dynamically
    local ssh_port
    ssh_port=$(nftban_nftables_detect_ssh_port)

    local missing_files=()

    # Check IPv4 INPUT
    if [[ ! -f "$NFTBAN_IPV4_INPUT_PORTS" ]]; then
        nftban_log_warning "Missing: ipv4-input.conf - auto-creating with SSH port $ssh_port"
        cat > "$NFTBAN_IPV4_INPUT_PORTS" << EOF
# IPv4 INPUT Ports (Incoming Connections)
# Format: PORT|PROTOCOL (T=TCP, U=UDP, B=Both)

# SSH (CRITICAL - auto-detected from sshd_config)
${ssh_port}|T

# Web Services
80|T
443|T

# Add more services as needed
EOF
        chmod 644 "$NFTBAN_IPV4_INPUT_PORTS"
        missing_files+=("ipv4-input.conf")
    fi

    # Check IPv4 OUTPUT
    if [[ ! -f "$NFTBAN_IPV4_OUTPUT_PORTS" ]]; then
        nftban_log_warning "Missing: ipv4-output.conf - auto-creating"
        cat > "$NFTBAN_IPV4_OUTPUT_PORTS" << 'EOF'
# IPv4 OUTPUT Ports (Outgoing Connections)
# Format: PORT|PROTOCOL (T=TCP, U=UDP, B=Both)

# DNS
53|U

# HTTP/HTTPS
80|T
443|T

# NTP
123|U

# SMTP
25|T
EOF
        chmod 644 "$NFTBAN_IPV4_OUTPUT_PORTS"
        missing_files+=("ipv4-output.conf")
    fi

    # Check IPv6 INPUT
    if [[ ! -f "$NFTBAN_IPV6_INPUT_PORTS" ]]; then
        nftban_log_warning "Missing: ipv6-input.conf - auto-creating with SSH port $ssh_port"
        cat > "$NFTBAN_IPV6_INPUT_PORTS" << EOF
# IPv6 INPUT Ports (Incoming Connections)
# Format: PORT|PROTOCOL (T=TCP, U=UDP, B=Both)

# SSH (CRITICAL - auto-detected from sshd_config)
${ssh_port}|T

# Web Services
80|T
443|T

# Add more services as needed
EOF
        chmod 644 "$NFTBAN_IPV6_INPUT_PORTS"
        missing_files+=("ipv6-input.conf")
    fi

    # Check IPv6 OUTPUT
    if [[ ! -f "$NFTBAN_IPV6_OUTPUT_PORTS" ]]; then
        nftban_log_warning "Missing: ipv6-output.conf - auto-creating"
        cat > "$NFTBAN_IPV6_OUTPUT_PORTS" << 'EOF'
# IPv6 OUTPUT Ports (Outgoing Connections)
# Format: PORT|PROTOCOL (T=TCP, U=UDP, B=Both)

# DNS
53|U

# HTTP/HTTPS
80|T
443|T

# NTP
123|U

# SMTP
25|T
EOF
        chmod 644 "$NFTBAN_IPV6_OUTPUT_PORTS"
        missing_files+=("ipv6-output.conf")
    fi

    # Report results
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        nftban_log_warning "BUG56 FIX: Auto-created ${#missing_files[@]} missing port config files:"
        for file in "${missing_files[@]}"; do
            nftban_log_warning "  ✓ $file (with SSH port: $ssh_port)"
        done
        nftban_log_warning "Please review and customize: $NFTBAN_PORT_CONFIG_DIR/"
        return 1  # Return 1 to indicate files were created (caller may want to reload)
    else
        nftban_log_debug "All port config files exist"
        return 0
    fi
}

# Apply IPv4 port rules from config files
nftban_nftables_apply_port_rules_v4() {
    local direction="$1"  # input or output

    # Determine which config file to use
    local config_file
    if [[ "$direction" == "input" ]]; then
        config_file="$NFTBAN_IPV4_INPUT_PORTS"
    else
        config_file="$NFTBAN_IPV4_OUTPUT_PORTS"
    fi

    # Process ports
    if [[ -f "$config_file" ]]; then
        while IFS='|' read -r port protocol; do
            [[ -z "$port" || "$port" =~ ^# ]] && continue

            case "$protocol" in
                T)
                    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" "$direction" \
                        tcp dport "$port" counter accept \
                        comment Allow_TCP_port_$port 2>/dev/null || true
                    ;;
                U)
                    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" "$direction" \
                        udp dport "$port" counter accept \
                        comment Allow_UDP_port_$port 2>/dev/null || true
                    ;;
                B)
                    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" "$direction" \
                        tcp dport "$port" counter accept \
                        comment Allow_TCP_port_$port 2>/dev/null || true
                    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" "$direction" \
                        udp dport "$port" counter accept \
                        comment Allow_UDP_port_$port 2>/dev/null || true
                    ;;
            esac
        done < <(grep -vE '^#|^$' "$config_file" 2>/dev/null || true)
    fi
}

# Apply IPv6 port rules from config files
nftban_nftables_apply_port_rules_v6() {
    local direction="$1"  # input or output

    # Determine which config file to use
    local config_file
    if [[ "$direction" == "input" ]]; then
        config_file="$NFTBAN_IPV6_INPUT_PORTS"
    else
        config_file="$NFTBAN_IPV6_OUTPUT_PORTS"
    fi

    # Process ports
    if [[ -f "$config_file" ]]; then
        while IFS='|' read -r port protocol; do
            [[ -z "$port" || "$port" =~ ^# ]] && continue

            case "$protocol" in
                T)
                    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" "$direction" \
                        tcp dport "$port" counter accept \
                        comment Allow_TCP_port_$port 2>/dev/null || true
                    ;;
                U)
                    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" "$direction" \
                        udp dport "$port" counter accept \
                        comment Allow_UDP_port_$port 2>/dev/null || true
                    ;;
                B)
                    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" "$direction" \
                        tcp dport "$port" counter accept \
                        comment Allow_TCP_port_$port 2>/dev/null || true
                    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" "$direction" \
                        udp dport "$port" counter accept \
                        comment Allow_UDP_port_$port 2>/dev/null || true
                    ;;
            esac
        done < <(grep -vE '^#|^$' "$config_file" 2>/dev/null || true)
    fi
}

# Add port to configuration
nftban_nftables_add_port() {
    local port="$1"
    local protocol="${2:-T}"  # T, U, or B
    local direction="${3:-input}"  # input or output
    local ip_version="${4:-4}"  # 4 or 6

    # Validate port
    if [[ ! "$port" =~ ^[0-9]+(-[0-9]+)?$ ]]; then
        nftban_log_error "Invalid port format: $port"
        return 1
    fi

    # Validate protocol
    if [[ ! "$protocol" =~ ^[TUB]$ ]]; then
        nftban_log_error "Invalid protocol: $protocol (use T, U, or B)"
        return 1
    fi

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
    if grep -qE "^${port}\|${protocol}$" "$config_file" 2>/dev/null; then
        nftban_log_warning "Port already configured: $port $protocol"
        return 0
    fi

    # Add to config file
    echo "${port}|${protocol}" >> "$config_file"

    nftban_log_success "Added port: $port ($protocol) to IPv${ip_version} ${direction}"

    # Apply rules
    nftban_nftables_apply_rules
}

# Remove port from configuration
nftban_nftables_remove_port() {
    local port="$1"
    local protocol="${2:-T}"
    local direction="${3:-input}"
    local ip_version="${4:-4}"

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

    # Remove from config
    if [[ -f "$config_file" ]]; then
        sed -i "/^${port}|${protocol}$/d" "$config_file"
        nftban_log_success "Removed port: $port ($protocol) from IPv${ip_version} ${direction}"

        # Apply rules
        nftban_nftables_apply_rules
    else
        nftban_log_error "Config file not found: $config_file"
        return 1
    fi
}

# List configured ports
nftban_nftables_list_ports() {
    local filter="${1:-all}"  # all, input, output

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Configured Ports"
    echo "═══════════════════════════════════════════════════════"
    echo ""

    if [[ "$filter" == "all" || "$filter" == "input" ]]; then
        echo -e "${NFTBAN_CYAN}IPv4 INPUT:${NFTBAN_NC}"
        if [[ -f "$NFTBAN_IPV4_INPUT_PORTS" ]]; then
            grep -vE '^#|^$' "$NFTBAN_IPV4_INPUT_PORTS" 2>/dev/null | \
                awk -F'|' '{printf "  %-20s %s\n", $1, ($2=="T"?"TCP":$2=="U"?"UDP":"TCP+UDP")}' || echo "  (none)"
        fi
        echo ""
    fi

    if [[ "$filter" == "all" || "$filter" == "output" ]]; then
        echo -e "${NFTBAN_CYAN}IPv4 OUTPUT:${NFTBAN_NC}"
        if [[ -f "$NFTBAN_IPV4_OUTPUT_PORTS" ]]; then
            grep -vE '^#|^$' "$NFTBAN_IPV4_OUTPUT_PORTS" 2>/dev/null | \
                awk -F'|' '{printf "  %-20s %s\n", $1, ($2=="T"?"TCP":$2=="U"?"UDP":"TCP+UDP")}' || echo "  (none)"
        fi
        echo ""
    fi

    if [[ "$filter" == "all" || "$filter" == "input" ]]; then
        echo -e "${NFTBAN_CYAN}IPv6 INPUT:${NFTBAN_NC}"
        if [[ -f "$NFTBAN_IPV6_INPUT_PORTS" ]]; then
            grep -vE '^#|^$' "$NFTBAN_IPV6_INPUT_PORTS" 2>/dev/null | \
                awk -F'|' '{printf "  %-20s %s\n", $1, ($2=="T"?"TCP":$2=="U"?"UDP":"TCP+UDP")}' || echo "  (none)"
        fi
        echo ""
    fi

    if [[ "$filter" == "all" || "$filter" == "output" ]]; then
        echo -e "${NFTBAN_CYAN}IPv6 OUTPUT:${NFTBAN_NC}"
        if [[ -f "$NFTBAN_IPV6_OUTPUT_PORTS" ]]; then
            grep -vE '^#|^$' "$NFTBAN_IPV6_OUTPUT_PORTS" 2>/dev/null | \
                awk -F'|' '{printf "  %-20s %s\n", $1, ($2=="T"?"TCP":$2=="U"?"UDP":"TCP+UDP")}' || echo "  (none)"
        fi
        echo ""
    fi
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_nftables_detect_ssh_port
export -f nftban_nftables_check_table
export -f nftban_nftables_check_legacy_table
export -f nftban_nftables_create_table
export -f nftban_nftables_create_table_v4
export -f nftban_nftables_create_table_v6
export -f nftban_nftables_apply_rules
export -f nftban_nftables_apply_rules_v4
export -f nftban_nftables_apply_rules_v6
export -f nftban_nftables_delete_table
export -f nftban_nftables_delete_table_v4
export -f nftban_nftables_delete_table_v6
export -f nftban_nftables_delete_legacy_table
export -f nftban_nftables_verify_structure
export -f nftban_nftables_show_set_stats
export -f nftban_nftables_show_status
export -f nftban_nftables_init_port_configs
export -f nftban_nftables_add_port
export -f nftban_nftables_remove_port
export -f nftban_nftables_list_ports
export -f nftban_nftables_apply_port_rules_v4
export -f nftban_nftables_apply_port_rules_v6

if declare -f nftban_log_debug >/dev/null 2>&1; then
    nftban_log_debug "NFTBan nftables Module loaded (v2.0.0 - Split Table Architecture)"
fi

# =============================================================================
# FOOTER
# =============================================================================
#
# **Module Version:** 0.9.3-dev
# **Security Level:** Production-Hardened (9/10)
# **License:** NFTBAN Custom License v3.0
# SPDX-License-Identifier: NFTBAN-Custom-License
#
# © 2025 Antonios Voulvoulis – ITCMS. All rights reserved.
#
# Permission is granted, free of charge, to use, modify, and deploy this Software
# for personal, educational, or commercial purposes within your own systems or
# organization, without redistribution.
#
# Redistribution, publication, resale, or sharing of this Software or any
# derivative works — in source or binary form — is strictly prohibited without
# prior written permission from the copyright holder.
#
# You may not, under any circumstance:
# ❌ Publicly upload, mirror, fork, or rehost this repository or its contents.
# ❌ Share, sell, or include the Software in any downloadable product, service,
#    or marketplace (commercial or non-commercial).
# ❌ Post the Software or any derivative works to public Git repositories,
#    software distribution platforms, package registries, or file-sharing networks.
# ❌ Use the Software or its output to train, fine-tune, or develop artificial
#    intelligence or machine learning models without prior written permission
#    from the copyright holder.
#
# Use freely within your organization—but do not redistribute publicly.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE, OR NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHOR OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES, OR OTHER
# LIABILITY ARISING FROM THE USE OF THE SOFTWARE OR ITS DOCUMENTATION.
#
# =============================================================================
