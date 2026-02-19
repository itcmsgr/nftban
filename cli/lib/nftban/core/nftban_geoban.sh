#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - GeoBan Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Wrapper for Go-based country blocking (nftban-geoip geoban)
#
# meta:name="nftban_geoban"
# meta:type="module"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-11-05"
#
# meta:description="Country-based IP blocking using nftban-geoip Go binary"
# meta:input="Country codes (ISO alpha-2)"
# meta:output="IP lists to nftables, tracking JSON to /etc/nftban/geoban.d/"
# meta:depends="bash,nftban-geoip"
#
# meta:inventory.files="nftban.conf,nft_schema.sh,nftban_logger.sh,nftban_audit.sh,nft_ipc.sh,nft_fragment.sh"
# meta:inventory.binaries="nftban-geoip"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files="/etc/nftban/nftban.conf,/etc/nftban/geoban.d/"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
# =============================================================================

set -Eeuo pipefail

# Source central environment loader (single source of truth for paths)
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/env.sh"

# Source NFT schema for canonical table/set names
# shellcheck source=/dev/null
[[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_schema.sh" ]] && source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_schema.sh"

# Load logging modules if available (uses central config paths)
if [[ -f "${NFTBAN_LIB_DIR}/helpers/nftban_logger.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/helpers/nftban_logger.sh"
    source "${NFTBAN_LIB_DIR}/helpers/nftban_audit.sh"
    LOGGING_ENABLED=true
else
    LOGGING_ENABLED=false
fi

# Load IPC library for single-writer architecture
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nft_fragment.sh" 2>/dev/null || true

# Load shared utility libraries
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_timestamp.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_file_utils.sh" 2>/dev/null || true

# Note: nftban_task_queue.sh is sourced by queue processor, not here (avoid circular dependency)

# Simple output functions (with file logging support)
readonly MODULE_LOG_FILE="${NFTBAN_LOG_DIR}/geoban.log"

nftban_info() {
    echo "[INFO] $*"
    if [[ "$LOGGING_ENABLED" == "true" ]]; then
        nftban_log_to_module_file "$MODULE_LOG_FILE" "INFO" "$*"
    fi
}

nftban_success() {
    echo "[SUCCESS] $*"
    if [[ "$LOGGING_ENABLED" == "true" ]]; then
        nftban_log_to_module_file "$MODULE_LOG_FILE" "SUCCESS" "$*"
    fi
}

nftban_error() {
    echo "[ERROR] $*" >&2
    if [[ "$LOGGING_ENABLED" == "true" ]]; then
        nftban_log_to_module_file "$MODULE_LOG_FILE" "ERROR" "$*"
    fi
}

nftban_warn() {
    echo "[WARN] $*" >&2
    if [[ "$LOGGING_ENABLED" == "true" ]]; then
        nftban_log_to_module_file "$MODULE_LOG_FILE" "WARN" "$*"
    fi
}

# Load configuration (new standard paths)
[[ -f "${NFTBAN_CONFIG_DIR}/conf.d/geoban/main.conf" ]] && source "${NFTBAN_CONFIG_DIR}/conf.d/geoban/main.conf"
[[ -f "${NFTBAN_CONFIG_DIR}/conf.d/geoban/main.conf.local" ]] && source "${NFTBAN_CONFIG_DIR}/conf.d/geoban/main.conf.local"
# Legacy path support (deprecated - will be removed in v2.0)
[[ -f "${NFTBAN_CONFIG_DIR}/conf.d/nftban-go.conf" ]] && source "${NFTBAN_CONFIG_DIR}/conf.d/nftban-go.conf"
[[ -f "${NFTBAN_CONFIG_DIR}/conf.d/nftban-go.conf.local" ]] && source "${NFTBAN_CONFIG_DIR}/conf.d/nftban-go.conf.local"

# =============================================================================
# CONFIGURATION DEFAULTS (uses central config paths)
# =============================================================================

: "${GEOBAN_ENABLED:=true}"
: "${GEOBAN_ATOMIC:=true}"
: "${GEOBAN_FILES_DIR:=${NFTBAN_CONFIG_DIR}/geoban.d}"
: "${GEOBAN_CACHE_DIR:=${NFTBAN_CACHE_DIR}/geoban}"
: "${GEOBAN_TRACKING_DIR:=${NFTBAN_DATA_DIR}/geoban/tracking}"

# Binary location (architecture detection) - uses central config paths
GEOIP_BINARY=""
if [[ -f "${NFTBAN_LIB_DIR}/bin/.real/nftban-geoip-x86_64" ]] && [[ "$(uname -m)" == "x86_64" ]]; then
    GEOIP_BINARY="${NFTBAN_LIB_DIR}/bin/.real/nftban-geoip-x86_64"
elif [[ -f "${NFTBAN_LIB_DIR}/bin/.real/nftban-geoip-aarch64" ]] && [[ "$(uname -m)" == "aarch64" ]]; then
    GEOIP_BINARY="${NFTBAN_LIB_DIR}/bin/.real/nftban-geoip-aarch64"
elif [[ -f "${NFTBAN_LIB_DIR}/bin/nftban-geoip" ]]; then
    GEOIP_BINARY="${NFTBAN_LIB_DIR}/bin/nftban-geoip"
fi

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Check if GeoBan is enabled
nftban_geoban_check_enabled() {
    if [[ "${GEOBAN_ENABLED}" != "true" ]]; then
        nftban_error "GeoBan is disabled in configuration"
        nftban_info "Enable it in ${NFTBAN_CONFIG_DIR}/conf.d/geoban/main.conf.local:"
        nftban_info "  GEOBAN_ENABLED=\"true\""
        return 1
    fi
    return 0
}

# Check if Go binary exists
nftban_geoban_check_binary() {
    if [[ -z "${GEOIP_BINARY}" ]] || [[ ! -x "${GEOIP_BINARY}" ]]; then
        nftban_error "nftban-geoip binary not found or not executable"
        nftban_info "Expected location: ${NFTBAN_LIB_DIR}/bin/.real/nftban-geoip-$(uname -m)"
        nftban_info "Run: ./build.sh to build Go binaries"
        return 1
    fi
    return 0
}

# Ensure directories exist
nftban_geoban_ensure_directories() {
    mkdir -p "${GEOBAN_FILES_DIR}" 2>/dev/null
    mkdir -p "${GEOBAN_CACHE_DIR}" 2>/dev/null
    mkdir -p "${GEOBAN_TRACKING_DIR}" 2>/dev/null

    # Set permissions
    chmod 750 "${GEOBAN_FILES_DIR}" 2>/dev/null
    chmod 750 "${GEOBAN_CACHE_DIR}" 2>/dev/null
    chmod 750 "${GEOBAN_TRACKING_DIR}" 2>/dev/null
}

# Validate country code
nftban_geoban_validate_country_code() {
    local cc="$1"

    # Must be exactly 2 uppercase letters
    if [[ ! "${cc}" =~ ^[A-Z]{2}$ ]]; then
        nftban_error "Invalid country code: ${cc}"
        nftban_info "Country codes must be 2-letter ISO alpha-2 (e.g., US, GB, CN, RU)"
        return 1
    fi

    return 0
}

# =============================================================================
# NFTABLES INTEGRATION (Phase 1)
# =============================================================================

# Apply GeoBan rules to nftables
# v2.1: Adds GeoBan CIDRs to main blacklist_ipv4/blacklist_ipv6 sets
# No separate geoban sets - CIDR aggregation, lower memory, no duplicates
nftban_geoban_apply_to_nftables() {
    # Use correct table families (consistent with rest of nftban)
    local table_v4="${NFTBAN_TABLE_IPV4:-ip nftban}"
    local table_v6="${NFTBAN_TABLE_IPV6:-ip6 nftban}"
    # v2.1: All bans go to main blacklist (source tracked in daemon DB)
    local set_v4="blacklist_ipv4"
    local set_v6="blacklist_ipv6"

    nftban_info "Applying GeoBan to blacklist sets (v2.1: unified blacklist)..."

    # Check if nftables is available
    if ! command -v nft &>/dev/null; then
        nftban_error "nft command not found"
        return 1
    fi

    # Check if IPv4 table exists (required)
    if ! nft list table $table_v4 &>/dev/null; then
        nftban_error "Table $table_v4 does not exist"
        nftban_info "Run: nft -f ${NFTBAN_NFTABLES_CONF:-/etc/nftables.conf}"
        return 1
    fi

    # Check if IPv6 table exists (optional, warn if missing)
    local has_ipv6=true
    if ! nft list table $table_v6 &>/dev/null; then
        nftban_warn "Table $table_v6 does not exist - IPv6 geoban disabled"
        has_ipv6=false
    fi

    # =========================================================================
    # 1. Verify geoban sets exist (should be in base config)
    # =========================================================================

    if ! nft list set $table_v4 "$set_v4" &>/dev/null; then
        nftban_error "Set $set_v4 does not exist in $table_v4"
        nftban_info "Base nftables config missing. Run: nft -f ${NFTBAN_NFTABLES_CONF:-/etc/nftables.conf}"
        return 1
    fi

    if [[ "$has_ipv6" == "true" ]]; then
        if ! nft list set $table_v6 "$set_v6" &>/dev/null; then
            nftban_warn "Set $set_v6 does not exist in $table_v6"
            has_ipv6=false
        fi
    fi

    # =========================================================================
    # 2. Load all banned country CIDRs from geoban.d/
    # =========================================================================

    local ban_files=()
    mapfile -t ban_files < <(find "${GEOBAN_FILES_DIR}" -name "50-ban-*.conf" 2>/dev/null)

    if [[ ${#ban_files[@]} -eq 0 ]]; then
        nftban_warn "No banned country files found in ${GEOBAN_FILES_DIR}"
        nftban_info "Use: nftban geoip ban <CC> to add countries"
        return 0
    fi

    nftban_info "Loading CIDRs from ${#ban_files[@]} country file(s)..."

    # Separate IPv4 and IPv6 addresses
    local cidrs_v4=()
    local cidrs_v6=()
    local cidr_count_v4=0
    local cidr_count_v6=0

    for file in "${ban_files[@]}"; do
        while IFS= read -r line; do
            # Skip empty lines and comments
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^#.* ]] && continue

            # Check if IPv4 or IPv6
            if [[ "$line" =~ : ]]; then
                # IPv6 (contains colons)
                cidrs_v6+=("$line")
                ((cidr_count_v6++))
            else
                # IPv4 (no colons)
                cidrs_v4+=("$line")
                ((cidr_count_v4++))
            fi
        done < "$file"
    done

    local total_cidrs=$((cidr_count_v4 + cidr_count_v6))
    if [[ $total_cidrs -eq 0 ]]; then
        nftban_warn "No valid CIDRs found in ban files"
        return 0
    fi

    # =========================================================================
    # 3. Add IPv4 CIDRs to blacklist_ipv4
    # NOTE: We ADD elements. Set can be flushed on full refresh.
    # =========================================================================

    if [[ $cidr_count_v4 -gt 0 ]]; then
        nftban_info "Adding $cidr_count_v4 IPv4 CIDRs to $set_v4..."

        # Build comma-separated list
        local cidr_list_v4=""
        for cidr in "${cidrs_v4[@]}"; do
            cidr_list_v4+="$cidr,"
        done
        cidr_list_v4="${cidr_list_v4%,}"  # Remove trailing comma

        local element_fragment="/etc/nftban/rules.d/geoban-elements-v4-$$.nft"
        echo "add element $table_v4 $set_v4 { $cidr_list_v4 }" > "$element_fragment"

        if nft_ipc_apply_ruleset "$element_fragment" 2>/dev/null; then
            rm -f "$element_fragment" 2>/dev/null
            nftban_success "Added $cidr_count_v4 IPv4 CIDRs to $set_v4"
        else
            rm -f "$element_fragment" 2>/dev/null
            nftban_error "Failed to add IPv4 CIDRs (IPC command failed)"
            return 1
        fi
    fi

    # =========================================================================
    # 4. Add IPv6 CIDRs to blacklist_ipv6
    # =========================================================================

    if [[ "$has_ipv6" == "true" && $cidr_count_v6 -gt 0 ]]; then
        nftban_info "Adding $cidr_count_v6 IPv6 CIDRs to $set_v6..."

        # Build comma-separated list
        local cidr_list_v6=""
        for cidr in "${cidrs_v6[@]}"; do
            cidr_list_v6+="$cidr,"
        done
        cidr_list_v6="${cidr_list_v6%,}"  # Remove trailing comma

        local element_fragment="/etc/nftban/rules.d/geoban-elements-v6-$$.nft"
        echo "add element $table_v6 $set_v6 { $cidr_list_v6 }" > "$element_fragment"

        if nft_ipc_apply_ruleset "$element_fragment" 2>/dev/null; then
            rm -f "$element_fragment" 2>/dev/null
            nftban_success "Added $cidr_count_v6 IPv6 CIDRs to $set_v6"
        else
            rm -f "$element_fragment" 2>/dev/null
            nftban_warn "Failed to add IPv6 CIDRs (IPC command failed)"
        fi
    fi

    # =========================================================================
    # 5. Summary - NO chain/rules needed (geoban sets already have rules)
    # =========================================================================

    echo ""
    nftban_success "GeoBan applied to dedicated geoban sets!"
    nftban_info "IPv4: $cidr_count_v4 CIDRs added to $table_v4 $set_v4"
    if [[ "$has_ipv6" == "true" && $cidr_count_v6 -gt 0 ]]; then
        nftban_info "IPv6: $cidr_count_v6 CIDRs added to $table_v6 $set_v6"
    elif [[ $cidr_count_v6 -gt 0 ]]; then
        nftban_warn "IPv6: $cidr_count_v6 CIDRs found but IPv6 table not available"
    fi
    echo ""
    nftban_info "GeoBan is now ACTIVELY BLOCKING at firewall level"
    nftban_info "Verify: nft list set $table_v4 $set_v4 | head -20"

    return 0
}

# Remove GeoBan entries from dedicated geoban sets (cleanup)
# Uses dedicated blacklist_ipv4/blacklist_ipv6 sets - safe to flush entirely
nftban_geoban_remove_from_nftables() {
    local table_v4="${NFTBAN_TABLE_IPV4:-ip nftban}"
    local table_v6="${NFTBAN_TABLE_IPV6:-ip6 nftban}"
    # DEDICATED GEOBAN SETS: Separate from feeds/auto/manual
    local set_v4="blacklist_ipv4"
    local set_v6="blacklist_ipv6"

    nftban_info "Removing GeoBan entries from dedicated geoban sets..."

    # Check for banned country files
    local ban_files=()
    mapfile -t ban_files < <(find "${GEOBAN_FILES_DIR}" -name "50-ban-*.conf" 2>/dev/null)

    if [[ ${#ban_files[@]} -eq 0 ]]; then
        nftban_info "No GeoBan entries to remove"
        return 0
    fi

    # Collect all GeoBan CIDRs from ban files
    local cidrs_v4=()
    local cidrs_v6=()

    for file in "${ban_files[@]}"; do
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^#.* ]] && continue

            if [[ "$line" =~ : ]]; then
                cidrs_v6+=("$line")
            else
                cidrs_v4+=("$line")
            fi
        done < "$file"
    done

    # Remove IPv4 entries from geoban set
    if [[ ${#cidrs_v4[@]} -gt 0 ]]; then
        nftban_info "Removing ${#cidrs_v4[@]} IPv4 CIDRs from $set_v4..."

        local cidr_list_v4=""
        for cidr in "${cidrs_v4[@]}"; do
            cidr_list_v4+="$cidr,"
        done
        cidr_list_v4="${cidr_list_v4%,}"

        local delete_fragment="/etc/nftban/rules.d/geoban-delete-v4-$$.nft"
        echo "delete element $table_v4 $set_v4 { $cidr_list_v4 }" > "$delete_fragment"

        if nft_ipc_apply_ruleset "$delete_fragment" 2>/dev/null; then
            rm -f "$delete_fragment" 2>/dev/null
            nftban_success "Removed ${#cidrs_v4[@]} IPv4 CIDRs from $set_v4"
        else
            rm -f "$delete_fragment" 2>/dev/null
            nftban_warn "Failed to remove some IPv4 CIDRs (may not exist in set)"
        fi
    fi

    # Remove IPv6 entries from geoban set
    if [[ ${#cidrs_v6[@]} -gt 0 ]]; then
        nftban_info "Removing ${#cidrs_v6[@]} IPv6 CIDRs from $set_v6..."

        local cidr_list_v6=""
        for cidr in "${cidrs_v6[@]}"; do
            cidr_list_v6+="$cidr,"
        done
        cidr_list_v6="${cidr_list_v6%,}"

        local delete_fragment="/etc/nftban/rules.d/geoban-delete-v6-$$.nft"
        echo "delete element $table_v6 $set_v6 { $cidr_list_v6 }" > "$delete_fragment"

        if nft_ipc_apply_ruleset "$delete_fragment" 2>/dev/null; then
            rm -f "$delete_fragment" 2>/dev/null
            nftban_success "Removed ${#cidrs_v6[@]} IPv6 CIDRs from $set_v6"
        else
            rm -f "$delete_fragment" 2>/dev/null
            nftban_warn "Failed to remove some IPv6 CIDRs (may not exist in set)"
        fi
    fi

    nftban_info "GeoBan entries removed from dedicated geoban sets"
    return 0
}

# =============================================================================
# BASH FALLBACK FUNCTIONS (NO GO BINARY REQUIRED)
# =============================================================================

nftban_geoban_fetch_bash() {
    # Download country IP ranges from IPDENY (bash-only, no Go required)
    # Args: $1 = country code, $2 = action (ban/whitelist)
    # Returns: 0 if success, 1 if failed

    local cc="$1"
    local action="${2:-ban}"
    local cc_lower="${cc,,}"

    nftban_info "Downloading $cc IP ranges from IPDENY (bash mode)"

    # Ensure directories exist
    mkdir -p "$GEOBAN_CACHE_DIR" "$GEOBAN_FILES_DIR" "$GEOBAN_TRACKING_DIR"

    # Determine file prefix based on action
    local prefix
    case "$action" in
        ban)
            prefix="50-ban"
            ;;
        whitelist)
            prefix="40-whitelist"
            ;;
        *)
            nftban_error "Invalid action: $action"
            return 1
            ;;
    esac

    local cache_file="$GEOBAN_CACHE_DIR/${cc}.txt"
    local output_file="$GEOBAN_FILES_DIR/${prefix}-${cc}.conf"
    local tracking_file="$GEOBAN_TRACKING_DIR/${cc}.json"

    # Download IPv4 ranges from IPDENY
    nftban_info "Fetching IPv4 ranges for $cc from ipdeny.com..."

    if ! curl -s -f "https://www.ipdeny.com/ipblocks/data/countries/${cc_lower}.zone" \
        -o "$cache_file" --max-time 30; then
        nftban_error "Failed to download $cc from IPDENY"
        nftban_info "URL: https://www.ipdeny.com/ipblocks/data/countries/${cc_lower}.zone"
        return 1
    fi

    # Validate download
    if [[ ! -s "$cache_file" ]]; then
        nftban_error "Downloaded file is empty for $cc"
        rm -f "$cache_file"
        return 1
    fi

    # Count IPs
    local ip_count
    ip_count=$(wc -l < "$cache_file")

    # BUG-MED-004 FIX: Accept countries with 1+ CIDR (e.g., North Korea has only 1)
    # Changed from 10 to 1 - some countries have very small IP allocations
    if [[ $ip_count -lt 1 ]]; then
        nftban_error "Downloaded 0 IP ranges for $cc (empty response)"
        nftban_warn "This may indicate an invalid country code or IPDENY service issue"
        rm -f "$cache_file"
        return 1
    fi

    # Copy to output location with header comment
    {
        echo "# NFTBan GeoBan - Country: $cc"
        echo "# Action: $action"
        echo "# Source: IPDENY (bash fallback mode)"
        echo "# Downloaded: $(nftban_timestamp 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# IP Ranges: $ip_count"
        echo "#"
        cat "$cache_file"
    } > "$output_file"

    # Create tracking JSON (simple format for bash mode)
    cat > "$tracking_file" <<EOF
{
  "country": "$cc",
  "action": "$action",
  "source": "bash",
  "ipv4_count": $ip_count,
  "ipv6_count": 0,
  "downloaded": "$(nftban_timestamp 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)",
  "url": "https://www.ipdeny.com/ipblocks/data/countries/${cc_lower}.zone"
}
EOF

    nftban_success "Downloaded $ip_count IPv4 ranges for $cc (bash mode)"
    nftban_info "File: $output_file"

    return 0
}

nftban_geoban_check_binary_soft() {
    # Soft check: returns 0 if Go binary exists, 1 if not (no error messages)
    # Used to decide between Go and bash mode

    if [[ -n "${GEOIP_BINARY}" ]] && [[ -x "${GEOIP_BINARY}" ]]; then
        return 0
    fi
    return 1
}

nftban_geoban_fetch_country() {
    # Smart fetch: Try Go first, fallback to bash
    # Args: $1 = country code, $2 = action (ban/whitelist)
    # Returns: 0 if success, 1 if failed

    local cc="$1"
    local action="${2:-ban}"

    # Try Go binary first if available
    if nftban_geoban_check_binary_soft; then
        nftban_info "Using Go binary for fast loading (recommended)"

        if "${GEOIP_BINARY}" geoban fetch "${cc}" \
            --action "$action" \
            --atomic="${GEOBAN_ATOMIC}" \
            --files-dir="${GEOBAN_FILES_DIR}" \
            --tracking-dir="${GEOBAN_TRACKING_DIR}" \
            --cache-dir="${GEOBAN_CACHE_DIR}" 2>&1; then
            return 0
        else
            nftban_warn "Go binary failed, falling back to bash mode"
        fi
    else
        nftban_info "Go binary not found - using bash fallback (slower but works)"
    fi

    # Bash fallback: download from IPDENY
    nftban_geoban_fetch_bash "$cc" "$action"
    return $?
}

# =============================================================================
# CORE FUNCTIONS
# =============================================================================

# Ban countries (add to blacklist)
nftban_geoban_ban_countries() {
    local countries=("$@")

    # Checks
    nftban_geoban_check_enabled || return 1
    # Don't fail if binary missing - we have bash fallback now!
    # nftban_geoban_check_binary || return 1
    nftban_geoban_ensure_directories

    if [[ ${#countries[@]} -eq 0 ]]; then
        nftban_error "No countries specified"
        nftban_info "Usage: nftban geoip ban <CC> [CC...]"
        nftban_info "Example: nftban geoip ban CN RU KP"
        return 1
    fi

    # Process each country
    local success=0
    local failed=0

    for cc in "${countries[@]}"; do
        # Uppercase country code
        cc=$(echo "${cc}" | tr '[:lower:]' '[:upper:]')

        # Validate
        nftban_geoban_validate_country_code "${cc}" || {
            ((++failed))
            continue
        }

        nftban_info "Banning country: ${cc}"

        # Use smart fetch (Go with bash fallback)
        if nftban_geoban_fetch_country "${cc}" "ban"; then
            nftban_success "Successfully banned ${cc}"
            # Audit log the action
            if [[ "$LOGGING_ENABLED" == "true" ]]; then
                nftban_audit_geoban "block" "${cc}" "geoban_ban_countries"
            fi
            ((++success))
        else
            nftban_error "Failed to ban ${cc}"
            ((++failed))
        fi
    done

    # Summary
    echo ""
    nftban_info "Summary: ${success} succeeded, ${failed} failed"

    if [[ ${success} -gt 0 ]]; then
        nftban_info "View banned countries: nftban geoip list"
        echo ""

        # ARCHITECTURE COMPLIANCE: Always use timer-based queue for nftables sync
        # NEVER execute synchronous sync - all feeds/ban/unban/countries managed by timer
        # This prevents 30+ second hangs with large IP sets and respects async architecture
        if command -v nftban_queue_add &>/dev/null; then
            nftban_queue_add "geoban_apply" "Countries banned: $*" >/dev/null 2>&1
            nftban_info "✅ GeoBan configured successfully"
            nftban_info "   NFTables update queued (processed every 2 minutes)"
            nftban_info "   Check queue: tail -f ${NFTBAN_LOG_DIR}/queue.log"
        else
            # Fallback: trigger immediate sync since queue not available
            nftban sync --quick 2>/dev/null || true
            nftban_info "✅ GeoBan configured and applied successfully"
        fi
        echo ""
    fi

    [[ ${failed} -eq 0 ]] && return 0 || return 1
}

# Remove country ban
nftban_geoban_unban_countries() {
    local countries=("$@")

    # Checks
    nftban_geoban_check_enabled || return 1
    # Don't fail if binary missing - bash mode can remove files directly

    if [[ ${#countries[@]} -eq 0 ]]; then
        nftban_error "No countries specified"
        nftban_info "Usage: nftban geoip unban <CC> [CC...]"
        nftban_info "Example: nftban geoip unban CN RU"
        return 1
    fi

    # Process each country
    local success=0
    local failed=0

    for cc in "${countries[@]}"; do
        # Uppercase country code
        cc=$(echo "${cc}" | tr '[:lower:]' '[:upper:]')

        # Validate
        nftban_geoban_validate_country_code "${cc}" || {
            ((++failed))
            continue
        }

        nftban_info "Unbanning country: ${cc}"

        # Try Go binary first if available
        if nftban_geoban_check_binary_soft; then
            if "${GEOIP_BINARY}" geoban remove "${cc}" \
                --action ban \
                --atomic="${GEOBAN_ATOMIC}" \
                --files-dir="${GEOBAN_FILES_DIR}" \
                --tracking-dir="${GEOBAN_TRACKING_DIR}" 2>&1; then

                nftban_success "Successfully unbanned ${cc}"
                # Audit log the action
                if [[ "$LOGGING_ENABLED" == "true" ]]; then
                    nftban_audit_geoban "unblock" "${cc}" "geoban_unban_countries"
                fi
                ((++success))
                continue
            else
                nftban_warn "Go binary failed, using bash fallback"
            fi
        fi

        # Bash fallback: just remove the files
        local ban_file="$GEOBAN_FILES_DIR/50-ban-${cc}.conf"
        local tracking_file="$GEOBAN_TRACKING_DIR/${cc}.json"
        local cache_file="$GEOBAN_CACHE_DIR/${cc}.txt"

        if [[ -f "$ban_file" ]]; then
            rm -f "$ban_file" "$tracking_file" "$cache_file"
            nftban_success "Successfully unbanned ${cc} (bash mode)"
            # Audit log the action
            if [[ "$LOGGING_ENABLED" == "true" ]]; then
                nftban_audit_geoban "unblock" "${cc}" "geoban_unban_countries"
            fi
            ((++success))
        else
            nftban_error "Country $cc not found in ban list"
            ((++failed))
        fi
    done

    # Summary
    echo ""
    nftban_info "Summary: ${success} succeeded, ${failed} failed"

    if [[ ${success} -gt 0 ]]; then
        echo ""

        # Add apply task to queue (processed by systemd timer every 2 minutes)
        # ARCHITECTURE COMPLIANCE: Always use timer-based queue for nftables sync
        # NEVER execute synchronous sync - all feeds/ban/unban/countries managed by timer
        # This prevents 30+ second hangs with large IP sets and respects async architecture
        if command -v nftban_queue_add &>/dev/null; then
            nftban_queue_add "geoban_apply" "Countries unbanned: $*" >/dev/null 2>&1
            nftban_info "✅ GeoBan configured successfully"
            nftban_info "   NFTables update queued (processed every 2 minutes)"
            nftban_info "   Check queue: tail -f ${NFTBAN_LOG_DIR}/queue.log"
        else
            # Fallback: trigger immediate sync since queue not available
            nftban sync --quick 2>/dev/null || true
            nftban_info "✅ GeoBan configured and applied successfully"
        fi
        echo ""
    fi

    [[ ${failed} -eq 0 ]] && return 0 || return 1
}

# Whitelist countries
nftban_geoban_whitelist_countries() {
    local countries=("$@")

    # Checks
    nftban_geoban_check_enabled || return 1
    # Don't fail if binary missing - we have bash fallback!
    nftban_geoban_ensure_directories

    if [[ ${#countries[@]} -eq 0 ]]; then
        nftban_error "No countries specified"
        nftban_info "Usage: nftban geoip whitelist <CC> [CC...]"
        nftban_info "Example: nftban geoip whitelist US GB DE"
        return 1
    fi

    # Process each country
    local success=0
    local failed=0

    for cc in "${countries[@]}"; do
        # Uppercase country code
        cc=$(echo "${cc}" | tr '[:lower:]' '[:upper:]')

        # Validate
        nftban_geoban_validate_country_code "${cc}" || {
            ((++failed))
            continue
        }

        nftban_info "Whitelisting country: ${cc}"

        # Use smart fetch (Go with bash fallback)
        if nftban_geoban_fetch_country "${cc}" "whitelist"; then
            nftban_success "Successfully whitelisted ${cc}"
            ((++success))
        else
            nftban_error "Failed to whitelist ${cc}"
            ((++failed))
        fi
    done

    # Summary
    echo ""
    nftban_info "Summary: ${success} succeeded, ${failed} failed"

    if [[ ${success} -gt 0 ]]; then
        nftban_info "View whitelisted countries: nftban geoip list"
    fi

    [[ ${failed} -eq 0 ]] && return 0 || return 1
}

# Remove country whitelist
nftban_geoban_unwhitelist_countries() {
    local countries=("$@")

    # Checks
    nftban_geoban_check_enabled || return 1
    # Don't fail if binary missing - bash mode can remove files directly

    if [[ ${#countries[@]} -eq 0 ]]; then
        nftban_error "No countries specified"
        nftban_info "Usage: nftban geoip unwhitelist <CC> [CC...]"
        nftban_info "Example: nftban geoip unwhitelist US"
        return 1
    fi

    # Process each country
    local success=0
    local failed=0

    for cc in "${countries[@]}"; do
        # Uppercase country code
        cc=$(echo "${cc}" | tr '[:lower:]' '[:upper:]')

        # Validate
        nftban_geoban_validate_country_code "${cc}" || {
            ((++failed))
            continue
        }

        nftban_info "Removing whitelist for country: ${cc}"

        # Try Go binary first if available
        if nftban_geoban_check_binary_soft; then
            if "${GEOIP_BINARY}" geoban remove "${cc}" \
                --action whitelist \
                --atomic="${GEOBAN_ATOMIC}" \
                --files-dir="${GEOBAN_FILES_DIR}" \
                --tracking-dir="${GEOBAN_TRACKING_DIR}" 2>&1; then

                nftban_success "Successfully removed whitelist for ${cc}"
                ((++success))
                continue
            else
                nftban_warn "Go binary failed, using bash fallback"
            fi
        fi

        # Bash fallback: just remove the files
        local whitelist_file="$GEOBAN_FILES_DIR/40-whitelist-${cc}.conf"
        local tracking_file="$GEOBAN_TRACKING_DIR/${cc}.json"
        local cache_file="$GEOBAN_CACHE_DIR/${cc}.txt"

        if [[ -f "$whitelist_file" ]]; then
            rm -f "$whitelist_file" "$tracking_file" "$cache_file"
            nftban_success "Successfully removed whitelist for ${cc} (bash mode)"
            ((++success))
        else
            nftban_error "Country $cc not found in whitelist"
            ((++failed))
        fi
    done

    # Summary
    echo ""
    nftban_info "Summary: ${success} succeeded, ${failed} failed"

    [[ ${failed} -eq 0 ]] && return 0 || return 1
}

# List active GeoBan countries
nftban_geoban_list() {
    nftban_geoban_check_enabled || return 1

    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║  🌍 GeoBan Active Countries                                              ║"
    echo "║  NFTBan — Open-source Linux IPS and nftables firewall manager            ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo ""

    # Check for banned countries
    local banned_files=("${GEOBAN_FILES_DIR}"/50-ban-*.conf)
    local banned_count=0

    if [[ -e "${banned_files[0]}" ]]; then
        echo "🚫 Banned Countries:"
        for file in "${banned_files[@]}"; do
            if [[ -f "${file}" ]]; then
                local cc
                cc=$(basename "${file}" | sed -n 's/50-ban-\(.*\)\.conf/\1/p')
                local ipv4_count
                ipv4_count=$(grep -c "^[0-9]" "${file}" 2>/dev/null || echo "0")
                local ipv6_count
                ipv6_count=$(grep -c ":" "${file}" 2>/dev/null || echo "0")
                echo "   ${cc} - ${ipv4_count} IPv4 ranges, ${ipv6_count} IPv6 ranges"
                ((++banned_count))
            fi
        done
        echo ""
    else
        echo "🚫 Banned Countries: None"
        echo ""
    fi

    # Check for whitelisted countries
    local whitelist_files=("${GEOBAN_FILES_DIR}"/40-whitelist-*.conf)
    local whitelist_count=0

    if [[ -e "${whitelist_files[0]}" ]]; then
        echo "✅ Whitelisted Countries:"
        for file in "${whitelist_files[@]}"; do
            if [[ -f "${file}" ]]; then
                local cc
                cc=$(basename "${file}" | sed -n 's/40-whitelist-\(.*\)\.conf/\1/p')
                local ipv4_count
                ipv4_count=$(grep -c "^[0-9]" "${file}" 2>/dev/null || echo "0")
                local ipv6_count
                ipv6_count=$(grep -c ":" "${file}" 2>/dev/null || echo "0")
                echo "   ${cc} - ${ipv4_count} IPv4 ranges, ${ipv6_count} IPv6 ranges"
                ((++whitelist_count))
            fi
        done
        echo ""
    else
        echo "✅ Whitelisted Countries: None"
        echo ""
    fi

    # Summary
    echo "📊 Summary:"
    echo "   Banned: ${banned_count}"
    echo "   Whitelisted: ${whitelist_count}"
    echo "   Files directory: ${GEOBAN_FILES_DIR}"
    echo ""

    # Usage hints
    if [[ ${banned_count} -eq 0 ]] && [[ ${whitelist_count} -eq 0 ]]; then
        echo "💡 Usage:"
        echo "   nftban geoip ban CN RU       - Ban China and Russia"
        echo "   nftban geoip whitelist US GB - Whitelist US and UK"
        echo ""
    fi
}

# Update all active GeoBan countries
nftban_geoban_update() {
    nftban_geoban_check_enabled || return 1
    nftban_geoban_check_binary || return 1

    nftban_info "Updating all active GeoBan countries..."
    echo ""

    # Find all active countries
    local all_files=("${GEOBAN_FILES_DIR}"/*-*.conf)
    local updated=0
    local failed=0

    if [[ ! -e "${all_files[0]}" ]]; then
        nftban_warn "No GeoBan countries configured"
        nftban_info "Use: nftban geoip ban <CC> to add countries"
        return 0
    fi

    for file in "${all_files[@]}"; do
        if [[ -f "${file}" ]]; then
            local basename
            basename=$(basename "${file}" .conf)
            local cc=""
            local action=""

            # Parse filename: 50-ban-CN.conf or 40-whitelist-US.conf
            if [[ "${basename}" =~ ^[0-9]+-ban-(.*)$ ]]; then
                cc="${BASH_REMATCH[1]}"
                action="ban"
            elif [[ "${basename}" =~ ^[0-9]+-whitelist-(.*)$ ]]; then
                cc="${BASH_REMATCH[1]}"
                action="whitelist"
            else
                continue
            fi

            nftban_info "Updating ${action}: ${cc}"

            # Call Go binary
            if "${GEOIP_BINARY}" geoban fetch "${cc}" \
                --action "${action}" \
                --atomic="${GEOBAN_ATOMIC}" \
                --files-dir="${GEOBAN_FILES_DIR}" \
                --tracking-dir="${GEOBAN_TRACKING_DIR}" \
                --cache-dir="${GEOBAN_CACHE_DIR}"; then

                ((++updated))
            else
                nftban_error "Failed to update ${cc}"
                ((++failed))
            fi
        fi
    done

    # Summary
    echo ""
    nftban_info "Update complete: ${updated} updated, ${failed} failed"

    [[ ${failed} -eq 0 ]] && return 0 || return 1
}

# Show GeoBan status
nftban_geoban_status() {
    nftban_geoban_check_enabled || return 1

    echo "╔═══════════════════════════════════════════════════════════════════════════╗"
    echo "║  🌍 GeoBan Status                                                        ║"
    echo "║  NFTBan — Open-source Linux IPS and nftables firewall manager            ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    echo ""

    # Configuration
    echo "📋 Configuration:"
    echo "   Enabled: ${GEOBAN_ENABLED}"
    echo "   Atomic operations: ${GEOBAN_ATOMIC}"
    echo "   Files directory: ${GEOBAN_FILES_DIR}"
    echo "   Cache directory: ${GEOBAN_CACHE_DIR}"
    echo "   Tracking directory: ${GEOBAN_TRACKING_DIR}"
    echo ""

    # Binary status
    echo "🔧 Go Binary:"
    if [[ -n "${GEOIP_BINARY}" ]] && [[ -x "${GEOIP_BINARY}" ]]; then
        local version
        version=$("${GEOIP_BINARY}" version 2>/dev/null | grep -oP 'v\S+' || echo "unknown")
        echo "   Binary: ${GEOIP_BINARY}"
        echo "   Version: ${version}"
        echo "   Status: ✅ Available"
    else
        echo "   Status: ❌ Not found"
    fi
    echo ""

    # Active countries count
    local banned_count
    banned_count=$(ls -1 "${GEOBAN_FILES_DIR}"/50-ban-*.conf 2>/dev/null | wc -l)
    local whitelist_count
    whitelist_count=$(ls -1 "${GEOBAN_FILES_DIR}"/40-whitelist-*.conf 2>/dev/null | wc -l)

    echo "📊 Active Countries:"
    echo "   Banned: ${banned_count}"
    echo "   Whitelisted: ${whitelist_count}"
    echo ""

    # Cache status
    if [[ -d "${GEOBAN_CACHE_DIR}" ]]; then
        local cache_files
        cache_files=$(find "${GEOBAN_CACHE_DIR}" -type f 2>/dev/null | wc -l)
        local cache_size
        cache_size=$(du -sh "${GEOBAN_CACHE_DIR}" 2>/dev/null | awk '{print $1}')
        echo "💾 Cache:"
        echo "   Files: ${cache_files}"
        echo "   Size: ${cache_size}"
    fi
    echo ""

    # Commands
    echo "💡 Commands:"
    echo "   nftban geoip ban <CC>        - Ban country"
    echo "   nftban geoip unban <CC>      - Remove ban"
    echo "   nftban geoip whitelist <CC>  - Whitelist country"
    echo "   nftban geoip list            - List active countries"
    echo "   nftban geoip update          - Update all countries"
    echo ""
}

# =============================================================================
# END OF MODULE
# =============================================================================
