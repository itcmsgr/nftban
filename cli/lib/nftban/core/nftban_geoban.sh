#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - GeoBan Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Wrapper for Go-based country blocking (nftban-geoip geoban)
#
# meta:name=nftban_geoban
# meta:type=core
# meta:header=GeoBan Core
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Country-based IP blocking using nftban-geoip Go binary
# meta:input=Country codes (ISO alpha-2)
# meta:output=IP lists to nftables, tracking JSON to /etc/nftban/geoban.d/
#
# **Inventory & Requirements**
# meta:depends=bash,nftban-geoip (Go binary)
#
# meta:created_date=2025-11-05
# meta:updated_date=2025-11-24
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

# Load logging modules if available (uses central config paths)
if [[ -f "${NFTBAN_LIB_DIR}/helpers/nftban_logger.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/helpers/nftban_logger.sh"
    source "${NFTBAN_LIB_DIR}/helpers/nftban_audit.sh"
    LOGGING_ENABLED=true
else
    LOGGING_ENABLED=false
fi

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

# Load configuration (uses central config paths)
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
        nftban_info "Enable it in ${NFTBAN_CONFIG_DIR}/conf.d/nftban-go.conf.local:"
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

# Apply GeoBan rules to nftables (minimal MVP implementation)
# Creates geoban_blocked_v4 set and geoban_input chain
nftban_geoban_apply_to_nftables() {
    local table="inet"
    local tname="nftban"
    local set_v4="geoban_blocked_v4"
    local set_v6="geoban_blocked_v6"
    local chain="geoban_input"

    nftban_info "Applying GeoBan rules to nftables..."

    # Check if nftables is available
    if ! command -v nft &>/dev/null; then
        nftban_error "nft command not found"
        return 1
    fi

    # Check if table exists
    if ! nft list table "$table" "$tname" &>/dev/null; then
        nftban_error "Table $table $tname does not exist"
        nftban_info "Run: nft -f /etc/nftables.conf"
        return 1
    fi

    # 1. Ensure IPv4 set exists (should already exist from Phase 0)
    if ! nft list set "$table" "$tname" "$set_v4" &>/dev/null; then
        nftban_info "Creating set: $set_v4"
        nft add set "$table" "$tname" "$set_v4" '{ type ipv4_addr; flags interval; comment "GeoBan blocked countries (IPv4)"; }' || {
            nftban_error "Failed to create set $set_v4"
            return 1
        }
    fi

    # 2. Flush old contents
    nftban_info "Flushing old GeoBan entries..."
    nft flush set "$table" "$tname" "$set_v4" || {
        nftban_error "Failed to flush set $set_v4"
        return 1
    }

    # 3. Load all banned country CIDRs into set
    local ban_files=()
    mapfile -t ban_files < <(find "${GEOBAN_FILES_DIR}" -name "50-ban-*.conf" 2>/dev/null)

    if [[ ${#ban_files[@]} -eq 0 ]]; then
        nftban_warn "No banned country files found in ${GEOBAN_FILES_DIR}"
        nftban_info "GeoBan set is empty (no countries banned)"
        return 0
    fi

    nftban_info "Loading CIDRs from ${#ban_files[@]} country file(s)..."

    # Build CIDR list (all elements in ONE command for efficiency)
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

    if [[ $cidr_count -eq 0 ]]; then
        nftban_warn "No valid CIDRs found in ban files"
        return 0
    fi

    # Apply all elements in ONE command (much faster than individual adds)
    nftban_info "Adding $cidr_count CIDRs to $set_v4..."

    # Build comma-separated list
    local cidr_list=""
    for cidr in "${cidrs[@]}"; do
        cidr_list+="$cidr,"
    done
    cidr_list="${cidr_list%,}"  # Remove trailing comma

    # Single command: add element to geoban set (v0.7.3: uses unified blacklist)
    local nft_output
    nft_output=$(nft add element "$table" "$tname" "$set_v4" "{ $cidr_list }" 2>&1)
    local nft_exit=$?

    if [[ $nft_exit -eq 0 ]]; then
        nftban_success "Loaded $cidr_count CIDRs into $set_v4"
    else
        nftban_error "Failed to load CIDRs (nft command failed)"
        nftban_error "nft output: $nft_output"
        return 1
    fi

    # 4. Ensure geoban_input chain exists (priority filter-15)
    if ! nft list chain "$table" "$tname" "$chain" &>/dev/null; then
        nftban_info "Creating GeoBan input chain at priority filter-15..."
        nft add chain "$table" "$tname" "$chain" '{ type filter hook input priority filter - 15; policy accept; }' || {
            nftban_error "Failed to create chain $chain"
            return 1
        }
        nftban_success "Created chain: $chain"
    fi

    # 5. Ensure drop rule exists in geoban_input chain
    # Check if rule already exists (avoid duplicates)
    if nft list chain "$table" "$tname" "$chain" 2>/dev/null | grep -q "GeoBan blocked IPv4"; then
        nftban_info "GeoBan drop rule already exists"
    else
        nftban_info "Adding GeoBan drop rule..."
        nft add rule "$table" "$tname" "$chain" ip saddr "@$set_v4" drop comment "GeoBan blocked IPv4" || {
            nftban_error "Failed to add drop rule"
            return 1
        }
        nftban_success "Added drop rule to $chain"
    fi

    # 6. Summary
    echo ""
    nftban_success "GeoBan nftables integration complete!"
    nftban_info "Set: $set_v4 ($cidr_count CIDRs)"
    nftban_info "Chain: $chain (priority filter-15)"
    nftban_info "Rule: ip saddr @$set_v4 drop"
    echo ""
    nftban_info "GeoBan is now ACTIVELY BLOCKING at firewall level"
    nftban_info "Verify: nft list set $table $tname $set_v4"
    nftban_info "Verify: nft list chain $table $tname $chain"

    return 0
}

# Remove GeoBan nftables rules (cleanup)
nftban_geoban_remove_from_nftables() {
    local table="inet"
    local tname="nftban"
    local set_v4="geoban_blocked_v4"
    local chain="geoban_input"

    nftban_info "Removing GeoBan from nftables..."

    # Flush set
    if nft list set "$table" "$tname" "$set_v4" &>/dev/null; then
        nft flush set "$table" "$tname" "$set_v4" && \
            nftban_success "Flushed $set_v4" || \
            nftban_warn "Failed to flush $set_v4"
    fi

    # Note: We don't delete the chain/set (they're in the template)
    # Just flush the contents
    nftban_info "GeoBan sets flushed (rules remain for future use)"

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

    if [[ $ip_count -lt 10 ]]; then
        nftban_error "Downloaded only $ip_count IP ranges for $cc (expected more)"
        nftban_warn "This may indicate an invalid country code or IPDENY service issue"
        rm -f "$cache_file"
        return 1
    fi

    # Copy to output location with header comment
    {
        echo "# NFTBan GeoBan - Country: $cc"
        echo "# Action: $action"
        echo "# Source: IPDENY (bash fallback mode)"
        echo "# Downloaded: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
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
  "downloaded": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
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
            ((failed++))
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
            ((success++))
        else
            nftban_error "Failed to ban ${cc}"
            ((failed++))
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
        nftban_queue_add "geoban_apply" "Countries banned: $*" >/dev/null 2>&1

        nftban_info "✅ GeoBan configured successfully"
        nftban_info "   NFTables update queued (processed every 2 minutes)"
        nftban_info "   Check queue: tail -f ${NFTBAN_LOG_DIR}/queue.log"
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
            ((failed++))
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
                ((success++))
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
            ((success++))
        else
            nftban_error "Country $cc not found in ban list"
            ((failed++))
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
        nftban_queue_add "geoban_apply" "Countries unbanned: $*" >/dev/null 2>&1

        nftban_info "✅ GeoBan configured successfully"
        nftban_info "   NFTables update queued (processed every 2 minutes)"
        nftban_info "   Check queue: tail -f ${NFTBAN_LOG_DIR}/queue.log"
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
            ((failed++))
            continue
        }

        nftban_info "Whitelisting country: ${cc}"

        # Use smart fetch (Go with bash fallback)
        if nftban_geoban_fetch_country "${cc}" "whitelist"; then
            nftban_success "Successfully whitelisted ${cc}"
            ((success++))
        else
            nftban_error "Failed to whitelist ${cc}"
            ((failed++))
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
            ((failed++))
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
                ((success++))
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
            ((success++))
        else
            nftban_error "Country $cc not found in whitelist"
            ((failed++))
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

    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  🌍 GeoBan Active Countries                              ║"
    echo "║  nftban — Simplifying Linux Firewall Management         ║"
    echo "╚══════════════════════════════════════════════════════════╝"
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
                ((banned_count++))
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
                ((whitelist_count++))
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

                ((updated++))
            else
                nftban_error "Failed to update ${cc}"
                ((failed++))
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

    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  🌍 GeoBan Status                                        ║"
    echo "║  nftban — Simplifying Linux Firewall Management         ║"
    echo "╚══════════════════════════════════════════════════════════╝"
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
