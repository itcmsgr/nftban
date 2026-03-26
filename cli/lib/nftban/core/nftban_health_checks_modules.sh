#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034  # SC1090: Dynamic paths; SC2034: Global arrays used by render module
# =============================================================================
# NFTBan v1.0 - Health Check Modules Functions
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Module-related health check functions (geoip, geoban, databases, rbl)
#
# meta:name="nftban_health_checks_modules"
# meta:type="lib"
# meta:header="Health Check Modules Functions"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Module health check functions for system verification"
# meta:depends="nftban_health.sh,nftban_health_checks_core.sh"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
# meta:created_date="2026-02-04"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_HEALTH_CHECKS_MODULES_LOADED:-}" ]] && return 0
_NFTBAN_HEALTH_CHECKS_MODULES_LOADED=1

# =============================================================================
# LOAD SHARED LIBRARIES
# =============================================================================

# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" || return 1
fi

# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_file_utils.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_file_utils.sh" || return 1
fi

# =============================================================================
# MODULE CHECKS
# =============================================================================

nftban_health_check_modules() {
    # Check loaded modules and their functions
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local module_issues=()

    # Core modules that should be loadable
    local core_modules=(
        "nftban_output.sh"
        "nftban_report_port.sh"
        "nftban_report_module.sh"
        "nftban_report_fhs.sh"
        "nftban_geoip_go.sh"
        "nftban_health.sh"
        "nftban_login_alert.sh"
        "nftban_mail.sh"
    )

    for module in "${core_modules[@]}"; do
        local module_path="${NFTBAN_LIB_DIR}/core/$module"
        if [[ ! -f "$module_path" ]]; then
            module_issues+=("Module not found: $module")
            status=$HEALTH_ERROR
        elif [[ ! -r "$module_path" ]]; then
            module_issues+=("Module not readable: $module")
            status=$HEALTH_ERROR
        else
            # Try to source it (in subshell to avoid side effects)
            if ! (source "$module_path") 2>/dev/null; then
                module_issues+=("Module has syntax errors: $module")
                status=$HEALTH_ERROR
            fi
        fi
    done

    # Store results
    if [[ ${#module_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["modules"]="${module_issues[*]}"
        NFTBAN_HEALTH_ERRORS+=("Module issues: ${module_issues[*]}")
    fi

    NFTBAN_HEALTH_RESULTS["modules"]=$status
    return $status
}

# =============================================================================
# GEOIP CHECKS
# =============================================================================

nftban_health_check_geoip() {
    # Check GeoIP system (v0.7.3 unified architecture)
    # - All GeoIP functionality in nftban-core (update, status, lookup)
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local geoip_issues=()

    local nftban_core="${NFTBAN_LIB_DIR}/bin/nftban-core"

    # Check for ANY supported GeoIP database (DB-IP free or MaxMind)
    local db_path=""
    local geoip_dir="${NFTBAN_DATA_DIR}/geoip"
    for db_file in "dbip-country-lite.mmdb" "GeoLite2-City.mmdb" "GeoLite2-Country.mmdb"; do
        if [[ -f "${geoip_dir}/${db_file}" ]]; then
            db_path="${geoip_dir}/${db_file}"
            break
        fi
    done

    # Check nftban-core (REQUIRED CORE MODULE - handles country/feeds/geoip)
    if [[ ! -x "$nftban_core" ]]; then
        # Try fallback paths
        nftban_core=$(command -v nftban-core 2>/dev/null || echo "")
        if [[ -z "$nftban_core" ]]; then
            geoip_issues+=("nftban-core binary NOT FOUND - REQUIRED core module")
            geoip_issues+=("FIX: nftban-core must be installed and compiled (handles country/feeds/geoip)")
            status=$HEALTH_ERROR
            # Store and return immediately - no point checking database if core is missing
            NFTBAN_HEALTH_ISSUES["geoip"]="${geoip_issues[*]}"
            NFTBAN_HEALTH_ERRORS+=("nftban-core: ${geoip_issues[*]}")
            NFTBAN_HEALTH_RESULTS["geoip"]=$status
            return "$status"
        fi
    fi

    # Check database (nftban-core is installed, now check if GeoIP DB is downloaded)
    if [[ -z "$db_path" ]]; then
        geoip_issues+=("GeoIP database not downloaded")
        geoip_issues+=("FIX: Run 'nftban geoip update' to download database")
        status=$HEALTH_ERROR
    elif [[ ! -r "$db_path" ]]; then
        geoip_issues+=("Database not readable: $db_path")
        status=$HEALTH_WARNING
    else
        # Database exists - verify with nftban-core
        if [[ -n "$nftban_core" && -x "$nftban_core" ]]; then
            if ! "$nftban_core" geoip status >/dev/null 2>&1; then
                geoip_issues+=("Database verification failed")
                status=$HEALTH_WARNING
            else
                # Performance test
                local start_time end_time elapsed
                start_time=$(date +%s%N)
                if "$nftban_core" geoip lookup 8.8.8.8 >/dev/null 2>&1; then
                    end_time=$(date +%s%N)
                    elapsed=$(( (end_time - start_time) / 1000 ))

                    if (( elapsed > 10000 )); then
                        geoip_issues+=("Lookup performance degraded: ${elapsed}μs (expected <1000μs)")
                    fi
                else
                    geoip_issues+=("Lookup test failed")
                fi
            fi
        fi
    fi

    # Store results
    if [[ ${#geoip_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["geoip"]="${geoip_issues[*]}"
        if [[ $status -eq $HEALTH_WARNING ]]; then
            NFTBAN_HEALTH_WARNINGS+=("nftban-core: ${geoip_issues[*]}")
        elif [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("nftban-core: ${geoip_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["geoip"]=$status
    return "$status"
}

# =============================================================================
# GEOBAN (COUNTRY BLOCKING) CHECK
# =============================================================================

nftban_health_check_geoban() {
    # Check GeoBan country blocking module
    # This is SEPARATE from GeoIP (database) - GeoBan is the country blocking feature
    # Returns: 0=OK (configured or not needed), 1=Warning, 2=Error

    local status=$HEALTH_OK
    local geoban_issues=()

    # Check for country blocking configurations
    local geoban_dir="${NFTBAN_DATA_DIR}/geoban"
    local blocked_count=0

    if [[ -d "$geoban_dir" ]]; then
        # Count blocked countries
        shopt -s nullglob 2>/dev/null || true
        for file in "$geoban_dir"/*.conf; do
            if [[ -f "$file" ]] && grep -q "^MODE=.*block" "$file" 2>/dev/null; then
                # v1.19.20 FIX
                ((blocked_count++)) || true
            fi
        done
        shopt -u nullglob 2>/dev/null || true
    fi

    # GeoBan is optional - not having it configured is fine
    if [[ $blocked_count -gt 0 ]]; then
        # If GeoBan is configured, verify GeoIP database is available
        local nftban_core="${NFTBAN_LIB_DIR}/bin/nftban-core"
        [[ ! -x "$nftban_core" ]] && nftban_core=$(command -v nftban-core 2>/dev/null || echo "")

        if [[ -n "$nftban_core" ]] && [[ -x "$nftban_core" ]]; then
            if ! "$nftban_core" geoip status >/dev/null 2>&1; then
                geoban_issues+=("GeoBan has $blocked_count countries configured but GeoIP database is missing")
                geoban_issues+=("FIX: Run 'nftban geoip update' to download the database")
                status=$HEALTH_WARNING
            fi
        else
            geoban_issues+=("GeoBan has $blocked_count countries configured but nftban-core is missing")
            status=$HEALTH_WARNING
        fi
    fi

    # Store results
    if [[ ${#geoban_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["geoban"]="${geoban_issues[*]}"
        if [[ $status -eq $HEALTH_WARNING ]]; then
            NFTBAN_HEALTH_WARNINGS+=("geoban: ${geoban_issues[*]}")
        elif [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("geoban: ${geoban_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["geoban"]=$status
    return "$status"
}

# =============================================================================
# DATABASE CHECKS
# =============================================================================

nftban_health_check_databases() {
    # Check database files
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local db_issues=()

    # Auto-detect GeoIP database from config
    local geoip_db=""
    local geoip_dir="${NFTBAN_DATA_DIR}/geoip"
    if [[ -n "${NFTBAN_GEOIP_DATABASE:-}" ]] && [[ -f "${NFTBAN_GEOIP_DATABASE}" ]]; then
        geoip_db="${NFTBAN_GEOIP_DATABASE}"
    else
        # IFS-safe split: strict.sh sets IFS=$'\n\t', so space-separated vars need explicit splitting
        local _geoip_dbs
        IFS=' ' read -ra _geoip_dbs <<< "${NFTBAN_GEOIP_DATABASES:-dbip-country-lite.mmdb GeoLite2-City.mmdb GeoLite2-Country.mmdb}"
        for db_file in "${_geoip_dbs[@]}"; do
            [[ -f "${geoip_dir}/${db_file}" ]] && geoip_db="${geoip_dir}/${db_file}" && break
        done
    fi

    if [[ -n "$geoip_db" ]] && [[ -f "$geoip_db" ]]; then
        # Check age (warn if >90 days old)
        local file_age days_old db_name
        # Use library function with graceful fallback
        if type -t nftban_file_age &>/dev/null; then
            file_age=$(nftban_file_age "$geoip_db")
        else
            file_age=$(( $(date +%s) - $(stat -c %Y "$geoip_db" 2>/dev/null || echo 0) ))
        fi
        days_old=$(( file_age / 86400 ))
        db_name=$(basename "$geoip_db")

        if (( days_old > 90 )); then
            db_issues+=("${db_name} is ${days_old} days old (consider updating)")
            status=$HEALTH_WARNING
        fi
    fi

    # Store results
    if [[ ${#db_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["databases"]="${db_issues[*]}"
        NFTBAN_HEALTH_WARNINGS+=("Database issues: ${db_issues[*]}")
    fi

    NFTBAN_HEALTH_RESULTS["databases"]=$status
    return "$status"
}

# =============================================================================
# RBL CHECK
# =============================================================================

nftban_health_check_rbl() {
    # Check RBL monitoring status (v1.0.24)
    # Returns: 0=OK, 1=WARNING, 2=ERROR
    # Checks: enabled status, last check time, blacklist status

    local status=$HEALTH_OK
    local rbl_issues=()

    # Load RBL configuration
    local rbl_config="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/rbl/main.conf"
    local rbl_cache_dir="${NFTBAN_LOG_DIR:-/var/log/nftban}/rbl"

    # Check if RBL is enabled
    local rbl_enabled="NO"
    if [[ -f "$rbl_config" ]]; then
        rbl_enabled=$(grep -E "^NFTBAN_RBL_ENABLED=" "$rbl_config" 2>/dev/null | cut -d'"' -f2 || echo "NO")
    fi

    if [[ "$rbl_enabled" != "YES" ]]; then
        rbl_issues+=("RBL monitoring disabled (optional)")
        # Not an error - just informational
        NFTBAN_HEALTH_RESULTS["rbl"]=$HEALTH_OK
        NFTBAN_HEALTH_ISSUES["rbl"]="RBL monitoring disabled (enable in $rbl_config)"
        return $HEALTH_OK
    fi

    # Check last check time
    local last_check_file="${rbl_cache_dir}/last_check"
    if [[ -f "$last_check_file" ]]; then
        local last_check last_check_epoch now_epoch hours_ago
        last_check=$(cat "$last_check_file" 2>/dev/null)
        # Use library functions with graceful fallback
        if type -t nftban_timestamp_to_unix &>/dev/null; then
            last_check_epoch=$(nftban_timestamp_to_unix "$last_check")
            [[ "$last_check_epoch" == "0" ]] && last_check_epoch=$(date -d "$last_check" +%s 2>/dev/null || echo 0)
        else
            last_check_epoch=$(date -d "$last_check" +%s 2>/dev/null || echo 0)
        fi
        if type -t nftban_timestamp_unix &>/dev/null; then
            now_epoch=$(nftban_timestamp_unix)
        else
            now_epoch=$(date +%s)
        fi
        hours_ago=$(( (now_epoch - last_check_epoch) / 3600 ))

        if [[ $hours_ago -gt 48 ]]; then
            rbl_issues+=("Last RBL check was ${hours_ago}h ago (stale)")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    else
        # v1.25.0: RBL is optional — unconfigured is INFO, not WARNING
        rbl_issues+=("RBL monitoring not configured (optional feature)")
        rbl_issues+=("  └─ RBL checks if your server IP is blacklisted on spam lists")
        rbl_issues+=("  └─ To enable: nftban rbl enable")
        # Not a warning — user choice to not configure RBL
    fi

    # Check for blacklisted IPs in state file — show WHICH IP on WHICH RBL
    local state_file="${rbl_cache_dir}/state.json"
    if [[ -f "$state_file" ]]; then
        if grep -q '"listed"' "$state_file" 2>/dev/null; then
            status=$HEALTH_ERROR
            # Extract listed IPs from state.json
            local listed_ips=""
            listed_ips=$(grep -B1 '"listed"' "$state_file" 2>/dev/null | grep -oP '^\s*"\K[0-9a-f.:]+' || true)
            if [[ -n "$listed_ips" ]]; then
                while IFS= read -r listed_ip; do
                    [[ -z "$listed_ip" ]] && continue
                    # Check cache file for which RBLs
                    local cache_file="${rbl_cache_dir}/${listed_ip}.cache"
                    local rbl_names=""
                    if [[ -f "$cache_file" ]]; then
                        rbl_names=$(grep "LISTED:" "$cache_file" 2>/dev/null | sed 's/.*LISTED: //' | head -3 | tr '\n' ', ' | sed 's/,$//')
                    fi
                    if [[ -n "$rbl_names" ]]; then
                        rbl_issues+=("BLACKLISTED: $listed_ip on $rbl_names")
                    else
                        rbl_issues+=("BLACKLISTED: $listed_ip (run 'nftban rbl check' for details)")
                    fi
                done <<< "$listed_ips"
            else
                rbl_issues+=("Server IP(s) currently BLACKLISTED on RBLs!")
            fi
            NFTBAN_HEALTH_ERRORS+=("RBL: Server IP blacklisted - run 'nftban rbl check' for details")
        fi
    fi

    # Check RBL timer status
    if systemctl is-enabled nftban-rbl-check.timer &>/dev/null; then
        if ! systemctl is-active nftban-rbl-check.timer &>/dev/null; then
            rbl_issues+=("RBL timer enabled but not active")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    else
        # v1.25.0: RBL timer is optional — disabled is INFO, not WARNING
        rbl_issues+=("RBL auto-check disabled (optional)")
        rbl_issues+=("  └─ Enable daily blacklist monitoring: nftban rbl enable")
        # Not a warning — user choice to not enable RBL timer
    fi

    # Store results
    NFTBAN_HEALTH_RESULTS["rbl"]=$status
    if [[ ${#rbl_issues[@]} -eq 0 ]]; then
        NFTBAN_HEALTH_ISSUES["rbl"]="RBL monitoring active, no blacklistings"
    else
        NFTBAN_HEALTH_ISSUES["rbl"]="${rbl_issues[*]}"
    fi

    return $status
}

# =============================================================================
# PORTSCAN PREFIX CHECK (Bug #24: Log prefix mismatch causes no detection logging)
# =============================================================================

nftban_health_check_portscan_prefix() {
    # Check if nftables portscan log prefix matches what the parser expects
    # Bug found: nftables uses "nftban: portscan: " but parser expects "NFTBAN_PORTSCAN:"
    # Returns: 0=OK, 1=Warning (mismatch found)

    local status=$HEALTH_OK
    local prefix_issues=()

    # Get the expected prefix from config
    local expected_prefix="${PORTSCAN_CLASSIC_LOG_PREFIX:-NFTBAN_PORTSCAN:}"

    # Get actual prefix from nftables ruleset
    local actual_prefix
    actual_prefix=$(nft list ruleset 2>/dev/null | grep -oP 'log prefix "\K[^"]*portscan[^"]*' | head -1 || echo "")

    if [[ -n "$actual_prefix" ]]; then
        # Check if they match (actual should contain expected or vice versa)
        if [[ "$actual_prefix" != *"$expected_prefix"* ]] && [[ "$expected_prefix" != *"$actual_prefix"* ]]; then
            # Normalize for comparison (strip spaces, lowercase)
            local norm_actual norm_expected
            norm_actual=$(echo "$actual_prefix" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
            norm_expected=$(echo "$expected_prefix" | tr -d ' ' | tr '[:upper:]' '[:lower:]')

            if [[ "$norm_actual" != "$norm_expected" ]]; then
                prefix_issues+=("Portscan log prefix MISMATCH:")
                prefix_issues+=("  nftables uses: '$actual_prefix'")
                prefix_issues+=("  parser expects: '$expected_prefix'")
                prefix_issues+=("FIX: Update /etc/nftban/conf.d/portscan/classic.conf PORTSCAN_CLASSIC_LOG_PREFIX")
                status=$HEALTH_WARNING
                NFTBAN_HEALTH_WARNINGS+=("Portscan prefix mismatch - detections not being logged")
            fi
        fi
    fi

    NFTBAN_HEALTH_RESULTS["portscan_prefix"]=$status
    [[ ${#prefix_issues[@]} -gt 0 ]] && NFTBAN_HEALTH_ISSUES["portscan_prefix"]="${prefix_issues[*]}"
    return $status
}

# =============================================================================
# BOTGUARD MODULE CHECK (v1.20.0)
# =============================================================================

nftban_health_check_botguard() {
    # Check HTTP Bot Guard module health
    # Validates: config exists, directories exist, permissions, crawler configs, daemon integration
    # Returns: 0=OK, 1=Warning, 2=Error
    # Auto-fix: Creates missing dirs with correct ownership

    local status=$HEALTH_OK
    local botguard_issues=()
    local auto_fixed=0

    local config_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
    local botguard_conf="$config_dir/conf.d/botguard/main.conf"
    local allowed_conf="$config_dir/conf.d/botguard/allowed_crawlers.conf"
    local denied_conf="$config_dir/conf.d/botguard/denied_crawlers.conf"
    local botguard_data="${NFTBAN_DATA_DIR:-/var/lib/nftban}/botguard"
    local botguard_log="${NFTBAN_LOG_DIR:-/var/log/nftban}/botguard"

    # Check config file
    if [[ ! -f "$botguard_conf" ]]; then
        botguard_issues+=("Config missing: $botguard_conf")
        status=$HEALTH_WARNING
    fi

    # Check crawler config files
    if [[ ! -f "$allowed_conf" ]]; then
        botguard_issues+=("Allowed crawlers config missing: $allowed_conf")
        status=$HEALTH_WARNING
    fi
    if [[ ! -f "$denied_conf" ]]; then
        botguard_issues+=("Denied crawlers config missing: $denied_conf")
        status=$HEALTH_WARNING
    fi

    # Check data directory (auto-fix if root)
    if [[ ! -d "$botguard_data" ]]; then
        if [[ $EUID -eq 0 ]]; then
            mkdir -p "$botguard_data" && chown nftban:nftban "$botguard_data" && chmod 750 "$botguard_data"
            botguard_issues+=("Data directory created (auto-fix): $botguard_data")
            ((auto_fixed++))
        else
            botguard_issues+=("Data directory missing: $botguard_data")
            botguard_issues+=("FIX: mkdir -p $botguard_data && chown nftban:nftban $botguard_data && chmod 750 $botguard_data")
            status=$HEALTH_WARNING
        fi
    else
        # Verify ownership
        local owner
        owner=$(stat -c '%U:%G' "$botguard_data" 2>/dev/null || echo "unknown")
        if [[ "$owner" != "nftban:nftban" ]]; then
            if [[ $EUID -eq 0 ]]; then
                chown nftban:nftban "$botguard_data" && chmod 750 "$botguard_data"
                botguard_issues+=("Data directory ownership fixed (auto-fix): $botguard_data")
                ((auto_fixed++))
            else
                botguard_issues+=("Data directory wrong ownership: $botguard_data (is $owner, expected nftban:nftban)")
                status=$HEALTH_WARNING
            fi
        fi
    fi

    # Check log directory (auto-fix if root)
    if [[ ! -d "$botguard_log" ]]; then
        if [[ $EUID -eq 0 ]]; then
            mkdir -p "$botguard_log" && chown nftban:nftban "$botguard_log" && chmod 750 "$botguard_log"
            botguard_issues+=("Log directory created (auto-fix): $botguard_log")
            ((auto_fixed++))
        else
            botguard_issues+=("Log directory missing: $botguard_log")
            botguard_issues+=("FIX: mkdir -p $botguard_log && chown nftban:nftban $botguard_log && chmod 750 $botguard_log")
            status=$HEALTH_WARNING
        fi
    else
        # Verify ownership
        local owner
        owner=$(stat -c '%U:%G' "$botguard_log" 2>/dev/null || echo "unknown")
        if [[ "$owner" != "nftban:nftban" ]]; then
            if [[ $EUID -eq 0 ]]; then
                chown nftban:nftban "$botguard_log" && chmod 750 "$botguard_log"
                botguard_issues+=("Log directory ownership fixed (auto-fix): $botguard_log")
                ((auto_fixed++))
            else
                botguard_issues+=("Log directory wrong ownership: $botguard_log (is $owner, expected nftban:nftban)")
                status=$HEALTH_WARNING
            fi
        fi
    fi

    # Check if enabled - verify sets exist when enabled
    local enabled="false"
    if [[ -f "$botguard_conf" ]]; then
        # Check local override first, then main config
        local local_conf="$config_dir/conf.d/botguard/main.conf.local"
        if [[ -f "$local_conf" ]]; then
            enabled=$(grep -m1 "^HTTP_BOTGUARD_ENABLED=" "$local_conf" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "")
        fi
        if [[ -z "$enabled" ]]; then
            enabled=$(grep -m1 "^HTTP_BOTGUARD_ENABLED=" "$botguard_conf" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || echo "false")
        fi
    fi

    if [[ "$enabled" == "true" ]]; then
        # Verify nft sets exist when module is enabled
        if ! nft list set ip nftban http_bot_suspect &>/dev/null 2>&1; then
            botguard_issues+=("Bot Guard enabled but http_bot_suspect set not found in nftables")
            botguard_issues+=("FIX: Restart nftband to create sets: systemctl restart nftband")
            status=$HEALTH_WARNING
        fi
        if ! nft list set ip6 nftban http_bot_suspect6 &>/dev/null 2>&1; then
            botguard_issues+=("Bot Guard enabled but http_bot_suspect6 (IPv6) set not found in nftables")
            botguard_issues+=("FIX: Restart nftband to create sets: systemctl restart nftband")
            status=$HEALTH_WARNING
        fi
    fi

    # Store results
    if [[ ${#botguard_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["botguard"]="${botguard_issues[*]}"
        if [[ $status -eq $HEALTH_WARNING ]]; then
            NFTBAN_HEALTH_WARNINGS+=("botguard: ${botguard_issues[*]}")
        elif [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("botguard: ${botguard_issues[*]}")
        fi
    else
        if [[ "$enabled" == "true" ]]; then
            NFTBAN_HEALTH_ISSUES["botguard"]="HTTP Bot Guard enabled and healthy"
        else
            NFTBAN_HEALTH_ISSUES["botguard"]="HTTP Bot Guard installed (disabled)"
        fi
    fi

    NFTBAN_HEALTH_RESULTS["botguard"]=$status
    return "$status"
}

# =============================================================================
# BINARY INTEGRITY CHECK
# =============================================================================

nftban_health_check_binary_integrity() {
    # Validate Go binaries are real ELF files, not corrupted or dummy placeholders
    # Returns: 0=OK, 3=Critical (corrupted binary detected)

    local status=$HEALTH_OK
    local integrity_issues=()
    local binaries=(
        "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-core"
        "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftband"
    )

    # Guard: 'file' command may not be installed on minimal systems
    if ! command -v file >/dev/null 2>&1; then
        NFTBAN_HEALTH_ISSUES["binary_integrity"]="Skipped ('file' command not installed)"
        return $HEALTH_OK
    fi

    for binary in "${binaries[@]}"; do
        if [[ -f "$binary" ]]; then
            local file_type
            file_type=$(file -b "$binary" 2>/dev/null)

            if [[ "$file_type" != *"ELF"* ]]; then
                integrity_issues+=("$binary is NOT a valid ELF binary (got: $file_type)")
                status=$HEALTH_CRITICAL
            elif [[ $(stat -c%s "$binary" 2>/dev/null) -lt 100000 ]]; then
                integrity_issues+=("$binary is suspiciously small (< 100KB)")
                status=$HEALTH_CRITICAL
            fi
        fi
    done

    # Store results
    if [[ ${#integrity_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["binary_integrity"]="${integrity_issues[*]}"
        NFTBAN_HEALTH_ERRORS+=("Binary integrity: ${integrity_issues[*]}")
    else
        NFTBAN_HEALTH_ISSUES["binary_integrity"]="All Go binaries are valid ELF executables"
    fi

    NFTBAN_HEALTH_RESULTS["binary_integrity"]=$status
    return $status
}

# =============================================================================
# TUNNEL SUSPICION CHECK
# =============================================================================

nftban_health_check_tunnel() {
    # Check tunnel suspicion module status (v1.30.0)
    # Returns: 0=OK, 1=WARNING, 2=ERROR
    # Advisory-only module — issues are informational only

    local status=$HEALTH_OK
    local tunnel_issues=()

    # Check if tunnel is enabled
    local tunnel_enabled="NO"
    local tunnel_config="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/tunnel/main.conf"
    local tunnel_config_local="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/tunnel/main.conf.local"
    if [[ -f "$tunnel_config_local" ]]; then
        tunnel_enabled=$(grep -E "^NFTBAN_TUNNEL_ENABLED=" "$tunnel_config_local" 2>/dev/null | cut -d'"' -f2 || echo "NO")
    fi
    [[ -z "$tunnel_enabled" || "$tunnel_enabled" == "NO" ]] && \
        [[ -f "$tunnel_config" ]] && \
        tunnel_enabled=$(grep -E "^NFTBAN_TUNNEL_ENABLED=" "$tunnel_config" 2>/dev/null | cut -d'"' -f2 || echo "NO")

    if [[ "$tunnel_enabled" != "YES" ]]; then
        NFTBAN_HEALTH_RESULTS["tunnel"]=$HEALTH_OK
        NFTBAN_HEALTH_ISSUES["tunnel"]="Tunnel suspicion monitoring disabled (optional)"
        return $HEALTH_OK
    fi

    # Check timer status
    if systemctl is-enabled nftban-tunnel.timer &>/dev/null; then
        if ! systemctl is-active nftban-tunnel.timer &>/dev/null; then
            tunnel_issues+=("Tunnel timer enabled but not active")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    else
        tunnel_issues+=("Tunnel enabled in config but timer not enabled")
        tunnel_issues+=("  FIX: nftban tunnel enable")
        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
    fi

    # Check state directory
    local state_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/tunnel"
    if [[ ! -d "$state_dir" ]]; then
        tunnel_issues+=("Tunnel state directory missing: $state_dir")
        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
    fi

    # Check for HIGH suspicion IPs
    local high_count=0
    if [[ -d "$state_dir" ]]; then
        for state_file in "${state_dir}"/*.state; do
            [[ ! -f "$state_file" ]] && continue
            local level
            level=$(head -1 "$state_file" 2>/dev/null | cut -d'|' -f3)
            [[ "$level" == "HIGH" ]] && high_count=$((high_count + 1))
        done
    fi

    if [[ $high_count -gt 0 ]]; then
        tunnel_issues+=("$high_count HIGH-suspicion DNS tunnel source(s) detected (advisory only)")
        tunnel_issues+=("  Review: nftban tunnel top")
        # Not a health error — advisory only, never bans
    fi

    # Store results
    NFTBAN_HEALTH_RESULTS["tunnel"]=$status
    if [[ ${#tunnel_issues[@]} -eq 0 ]]; then
        NFTBAN_HEALTH_ISSUES["tunnel"]="Tunnel monitoring active, no issues"
    else
        NFTBAN_HEALTH_ISSUES["tunnel"]="${tunnel_issues[*]}"
        if [[ $status -eq $HEALTH_WARNING ]]; then
            NFTBAN_HEALTH_WARNINGS+=("tunnel: ${tunnel_issues[*]}")
        fi
    fi

    return $status
}

# Export functions
export -f nftban_health_check_modules nftban_health_check_geoip
export -f nftban_health_check_geoban nftban_health_check_databases
export -f nftban_health_check_rbl nftban_health_check_portscan_prefix
export -f nftban_health_check_botguard
export -f nftban_health_check_binary_integrity
export -f nftban_health_check_tunnel
