#!/usr/bin/env bash
# shellcheck disable=SC1090,SC2034  # SC1090: Dynamic paths; SC2034: Global arrays used by render module
# =============================================================================
# NFTBan v1.0 - Health Check Config Functions
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Configuration-related health check functions
#
# meta:name="nftban_health_checks_config"
# meta:type="lib"
# meta:header="Health Check Config Functions"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Configuration health check functions for system verification"
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
[[ -n "${_NFTBAN_HEALTH_CHECKS_CONFIG_LOADED:-}" ]] && return 0
_NFTBAN_HEALTH_CHECKS_CONFIG_LOADED=1

# =============================================================================
# CONFIGURATION CHECKS
# =============================================================================

nftban_health_check_config() {
    # Check configuration files
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local config_issues=()

    # Main config directory
    if [[ ! -d "${NFTBAN_CONFIG_DIR}" ]]; then
        config_issues+=("Config directory not found: ${NFTBAN_CONFIG_DIR}")
        status=$HEALTH_ERROR
    fi

    # Check for basic config files
    local config_dir="${NFTBAN_CONFIG_DIR}/conf.d"
    if [[ -d "$config_dir" ]]; then
        # Try to load config files (in subshell) - auto-detects INI vs bash format
        # Check top-level conf files
        for conf_file in "$config_dir"/*.conf; do
            if [[ -f "$conf_file" ]]; then
                # Use auto-detect loader if available, fallback to format-specific handling
                if declare -f nftban_config_load &>/dev/null; then
                    if ! (nftban_config_load "$conf_file") 2>/dev/null; then
                        config_issues+=("Config has syntax errors: $(basename "$conf_file")")
                        status=$HEALTH_ERROR
                    fi
                elif grep -q '^\[' "$conf_file" 2>/dev/null; then
                    # INI format - skip bash sourcing (validated separately)
                    continue
                elif ! (source "$conf_file") 2>/dev/null; then
                    # shellcheck disable=SC1090  # Dynamic source for config validation
                    config_issues+=("Config has syntax errors: $(basename "$conf_file")")
                    status=$HEALTH_ERROR
                fi
            fi
        done

        # Check ALL subdirectory config files — no exclusions
        # Each file is validated by its detected format:
        #   pipe-delimited  (|) : allowed_crawlers.conf, denied_crawlers.conf
        #   colon-delimited (:) : rbls.conf
        #   INI sections    ([) : detected by leading [section] lines
        #   bash KEY=VALUE      : everything else (source validation)
        for subdir in "$config_dir"/*; do
            if [[ -d "$subdir" ]]; then
                for conf_file in "$subdir"/*.conf; do
                    if [[ -f "$conf_file" ]]; then
                        local filename; filename=$(basename "$conf_file")
                        local relative_path; relative_path="$(basename "$subdir")/$filename"

                        # All files must be readable
                        if [[ ! -r "$conf_file" ]]; then
                            config_issues+=("Config not readable: $relative_path")
                            status=$HEALTH_ERROR
                            continue
                        fi

                        # Detect format from first non-comment data line
                        local first_data_line
                        first_data_line=$(grep -v '^[[:space:]]*#\|^[[:space:]]*$' "$conf_file" 2>/dev/null | head -1)

                        if [[ -z "$first_data_line" ]]; then
                            # File has no data lines — skip warning for user template files
                            # (custom.conf, watchlist.conf, 99-manual.conf are empty by design)
                            case "$filename" in
                                custom.conf|watchlist.conf|99-manual.conf) ;;
                                *)
                                    config_issues+=("Config has no data entries: $relative_path")
                                    [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
                                    ;;
                            esac
                        elif [[ "$first_data_line" == *"|"* ]]; then
                            # Pipe-delimited format — validate all data lines have pipes
                            if grep -v '^[[:space:]]*#\|^[[:space:]]*$' "$conf_file" 2>/dev/null | grep -qv '|'; then
                                config_issues+=("Config has invalid pipe-delimited lines: $relative_path")
                                status=$HEALTH_ERROR
                            fi
                        elif [[ "$first_data_line" =~ ^[a-zA-Z0-9._-]+: ]]; then
                            # Colon-delimited format (e.g. rbls.conf: domain:url)
                            if grep -v '^[[:space:]]*#\|^[[:space:]]*$' "$conf_file" 2>/dev/null | grep -qv ':'; then
                                config_issues+=("Config has invalid colon-delimited lines: $relative_path")
                                status=$HEALTH_ERROR
                            fi
                        elif [[ "$first_data_line" == "["* ]]; then
                            # INI format — structure only, no bash sourcing needed
                            :
                        else
                            # Bash KEY=VALUE format — validate with source
                            if declare -f nftban_config_load &>/dev/null; then
                                if ! (nftban_config_load "$conf_file") 2>/dev/null; then
                                    config_issues+=("Config has syntax errors: $relative_path")
                                    status=$HEALTH_ERROR
                                fi
                            elif ! (source "$conf_file") 2>/dev/null; then
                                # shellcheck disable=SC1090  # Dynamic source for config validation
                                config_issues+=("Config has syntax errors: $relative_path")
                                status=$HEALTH_ERROR
                            fi
                        fi
                    fi
                done
            fi
        done
    fi

    # Check system.conf (UID/GID configuration)
    local system_conf="${NFTBAN_DATA_DIR}/config/system.conf"
    if [[ ! -f "$system_conf" ]]; then
        config_issues+=("System config missing: $system_conf (will auto-create)")
        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
    else
        # Verify system.conf is readable and has valid syntax
        # shellcheck disable=SC1090  # Dynamic source for config validation
        if ! (source "$system_conf") 2>/dev/null; then
            config_issues+=("System config has syntax errors: $system_conf")
            status=$HEALTH_ERROR
        else
            # Verify UID/GID values match actual system
            # shellcheck disable=SC1090  # Dynamic source for config validation
            source "$system_conf" 2>/dev/null || true
            # NFTBan v1.0 simplified 2-group model: nftban + nftban-auditor
            local actual_uid actual_gid actual_auditors_gid
            actual_uid=$(id -u nftban 2>/dev/null || echo "MISSING")
            actual_gid=$(id -g nftban 2>/dev/null || echo "MISSING")
            actual_auditors_gid=$(getent group nftban-auditor 2>/dev/null | cut -d: -f3 || echo "MISSING")

            if [[ "$actual_uid" != "$NFTBAN_UID" ]] || \
               [[ "$actual_gid" != "$NFTBAN_GID" ]] || \
               [[ "$actual_auditors_gid" != "${NFTBAN_AUDITORS_GID:-MISSING}" ]]; then
                config_issues+=("System config outdated (UID/GID mismatch, will auto-fix)")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        fi
    fi

    # Store results
    if [[ ${#config_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["config"]="${config_issues[*]}"
        if [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("Config issues: ${config_issues[*]}")
        else
            NFTBAN_HEALTH_WARNINGS+=("Config issues: ${config_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["config"]=$status
    return $status
}

# =============================================================================
# REGISTRY HEALTH CHECK (v1.0.16 - Commands Registry)
# =============================================================================

nftban_health_check_registry() {
    # Check commands.registry.yml and documentation generators
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local registry_issues=()

    # Check registry file exists
    local registry="${NFTBAN_CONFIG_DIR:-/etc/nftban}/commands.registry.yml"
    if [[ ! -f "$registry" ]]; then
        registry_issues+=("Registry missing: $registry")
        status=$HEALTH_ERROR
    else
        # Check registry is readable
        if [[ ! -r "$registry" ]]; then
            registry_issues+=("Registry not readable: $registry")
            status=$HEALTH_ERROR
        else
            # Check registry file size (should be ~100KB+)
            local size
            size=$(stat -c%s "$registry" 2>/dev/null || stat -f%z "$registry" 2>/dev/null || echo "0")
            if [[ $size -lt 10000 ]]; then
                registry_issues+=("Registry suspiciously small: $size bytes (corrupted?)")
                status=$HEALTH_ERROR
            fi

            # Check YAML validity if yq available
            if command -v yq &>/dev/null; then
                if ! yq -r '._metadata.version' "$registry" >/dev/null 2>&1; then
                    registry_issues+=("Registry has invalid YAML syntax")
                    status=$HEALTH_ERROR
                else
                    # Verify metadata
                    local total_commands
                    total_commands=$(yq -r '._metadata.total_commands // 0' "$registry" 2>/dev/null)
                    if [[ $total_commands -lt 40 ]]; then
                        registry_issues+=("Registry appears incomplete: only $total_commands commands (expected 45+)")
                        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
                    fi
                fi
            else
                registry_issues+=("yq not installed - cannot validate YAML (install: pip install yq)")
                [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
            fi
        fi

        # Check registry permissions (should be 644)
        local perms
        perms=$(stat -c "%a" "$registry" 2>/dev/null || stat -f "%Lp" "$registry" 2>/dev/null || echo "000")
        if [[ "$perms" != "644" ]]; then
            registry_issues+=("Registry permissions incorrect: $perms (should be 644)")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    fi

    # Check documentation generators exist and are executable
    local generators=(
        "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/scripts/generate-help.sh"
        "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/scripts/generate-wiki-operator.sh"
        "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/scripts/generate-wiki-auditor.sh"
    )

    for gen in "${generators[@]}"; do
        if [[ ! -f "$gen" ]]; then
            registry_issues+=("Generator missing: $(basename "$gen")")
            status=$HEALTH_ERROR
        elif [[ ! -x "$gen" ]]; then
            registry_issues+=("Generator not executable: $(basename "$gen")")
            [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
        fi
    done

    # Store results
    if [[ ${#registry_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["registry"]="${registry_issues[*]}"
        if [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("Registry issues: ${registry_issues[*]}")
        else
            NFTBAN_HEALTH_WARNINGS+=("Registry issues: ${registry_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["registry"]=$status
    return $status
}

# =============================================================================
# v0.31 INVENTORY HELPERS CHECKS
# =============================================================================

nftban_health_check_v030_helpers() {
    # Check v0.31 inventory helpers
    # Returns: 0=OK, 1=Warning, 2=Error (warnings only - v0.31 is optional)

    local status=$HEALTH_OK
    local helper_issues=()

    # v0.31 inventory helpers
    local helpers=(
        "nftban-procnet"
        "nftban-pkgs"
        "nftban-verify"
        "nftban-firewall"
    )

    local helpers_found=0
    local helpers_executable=0

    for helper in "${helpers[@]}"; do
        local helper_path="/usr/libexec/nftban/$helper"

        if [[ -f "$helper_path" ]]; then
            helpers_found=$((helpers_found + 1))

            if [[ -x "$helper_path" ]]; then
                helpers_executable=$((helpers_executable + 1))
            else
                helper_issues+=("$helper not executable")
                status=$HEALTH_WARNING
            fi
        fi
    done

    # Check if v0.31 mail adapter is present
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_mail_v030.sh" ]]; then
        if [[ ! -r "${NFTBAN_LIB_DIR}/core/nftban_mail_v030.sh" ]]; then
            helper_issues+=("v0.31 mail adapter not readable")
            status=$HEALTH_WARNING
        fi
    fi

    # Check if v0.31 health commands are present
    local health_commands=(
        "nftban-health"
        "nftban-baseline-save"
        "nftban-verify-signature"
    )

    for cmd in "${health_commands[@]}"; do
        if [[ -f "/usr/local/lib/nftban/$cmd" ]]; then
            if [[ ! -x "/usr/local/lib/nftban/$cmd" ]]; then
                helper_issues+=("$cmd not executable")
                status=$HEALTH_WARNING
            fi

            # Check symlink in /usr/local/bin
            if [[ ! -L "/usr/local/bin/$cmd" ]]; then
                helper_issues+=("$cmd symlink missing in /usr/local/bin")
                status=$HEALTH_WARNING
            fi
        fi
    done

    # Store results
    if [[ $helpers_found -eq 0 ]]; then
        # v0.31 not installed - not an error, just informational
        NFTBAN_HEALTH_ISSUES["v030_helpers"]="v0.31 extensions not installed"
    elif [[ ${#helper_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["v030_helpers"]="${helper_issues[*]}"
        NFTBAN_HEALTH_WARNINGS+=("v0.31 issues: ${helper_issues[*]}")
    else
        NFTBAN_HEALTH_ISSUES["v030_helpers"]="All v0.31 helpers OK ($helpers_executable/$helpers_found)"
    fi

    NFTBAN_HEALTH_RESULTS["v030_helpers"]=$status
    return "$status"
}

# =============================================================================
# BASH COMPLETION CHECK
# =============================================================================

nftban_health_check_bash_completion() {
    # Check bash-completion package installation
    # Returns: 0=OK, 1=Warning, 2=Error

    local status=$HEALTH_OK
    local completion_issues=()

    # Check if bash-completion is installed
    # Method 1: Check if main bash_completion script exists
    if [[ ! -f /usr/share/bash-completion/bash_completion ]] && \
       [[ ! -f /etc/bash_completion ]]; then
        completion_issues+=("bash-completion package not installed")
        completion_issues+=("Tab completion for nftban command will not work")
        completion_issues+=("FIX: Install bash-completion package (dnf/apt/yum install bash-completion)")
        status=$HEALTH_WARNING
    else
        # Check if NFTBAN completion file is installed
        local nftban_completion="/usr/share/bash-completion/completions/nftban"
        if [[ ! -f "$nftban_completion" ]]; then
            # Try to auto-install if auto-heal enabled
            if [[ "${NFTBAN_HEALTH_AUTO_HEAL:-false}" == "true" ]]; then
                # Try to find source file
                local completion_src=""
                for dir in "/home/gituser/github/nftban-dev" "/usr/src/nftban" "/opt/nftban"; do
                    if [[ -f "$dir/install/bash-completion/nftban" ]]; then
                        completion_src="$dir/install/bash-completion/nftban"
                        break
                    fi
                done

                if [[ -n "$completion_src" && -f "$completion_src" ]]; then
                    mkdir -p "$(dirname "$nftban_completion")" || return 1
                    if cp "$completion_src" "$nftban_completion"; then
                        chmod 644 "$nftban_completion"
                        completion_issues+=("Bash completion was missing - AUTO-HEALED: installed")
                        status=$HEALTH_WARNING
                    else
                        completion_issues+=("NFTBAN bash completion file missing at $nftban_completion")
                        completion_issues+=("AUTO-HEAL FAILED: Could not copy file")
                        status=$HEALTH_WARNING
                    fi
                else
                    completion_issues+=("NFTBAN bash completion file missing at $nftban_completion")
                    completion_issues+=("AUTO-HEAL FAILED: Source file not found")
                    completion_issues+=("FIX: sudo cp install/bash-completion/nftban /usr/share/bash-completion/completions/nftban")
                    status=$HEALTH_WARNING
                fi
            else
                completion_issues+=("NFTBAN bash completion file missing at $nftban_completion")
                completion_issues+=("FIX: sudo cp install/bash-completion/nftban /usr/share/bash-completion/completions/nftban")
                status=$HEALTH_WARNING
            fi
        else
            # Verify file is readable
            if [[ ! -r "$nftban_completion" ]]; then
                completion_issues+=("NFTBAN completion file exists but is not readable")
                status=$HEALTH_WARNING
            fi
        fi
    fi

    # Store results
    if [[ ${#completion_issues[@]} -gt 0 ]]; then
        NFTBAN_HEALTH_ISSUES["bash_completion"]="${completion_issues[*]}"
        if [[ $status -eq $HEALTH_ERROR ]]; then
            NFTBAN_HEALTH_ERRORS+=("Bash completion issues: ${completion_issues[*]}")
        else
            NFTBAN_HEALTH_WARNINGS+=("Bash completion issues: ${completion_issues[*]}")
        fi
    fi

    NFTBAN_HEALTH_RESULTS["bash_completion"]=$status
    return $status
}

# =============================================================================
# CLI ERROR LOG CHECK
# =============================================================================

nftban_health_check_cli_errors() {
    # Check CLI error log for recent errors
    # Returns: 0=OK, 1=Warnings, 2=Errors

    local status=$HEALTH_OK
    local -a cli_issues=()

    local cli_error_log="${NFTBAN_LOG_DIR}/cli-errors.log"

    # Check if log file exists
    if [[ ! -f "$cli_error_log" ]]; then
        cli_issues+=("✓ No CLI errors logged (log file doesn't exist)")
        NFTBAN_HEALTH_RESULTS["cli_errors"]=$status
        NFTBAN_HEALTH_ISSUES["cli_errors"]="${cli_issues[*]}"
        return $status
    fi

    # Check file size
    local log_size
    log_size=$(stat -f%z "$cli_error_log" 2>/dev/null || stat -c%s "$cli_error_log" 2>/dev/null || echo 0)

    if [[ $log_size -eq 0 ]]; then
        cli_issues+=("✓ No CLI errors logged (empty log)")
        NFTBAN_HEALTH_RESULTS["cli_errors"]=$status
        NFTBAN_HEALTH_ISSUES["cli_errors"]="${cli_issues[*]}"
        return $status
    fi

    # Check for recent errors (last 24 hours)
    local recent_errors=0
    local cutoff_time
    cutoff_time=$(date -d "24 hours ago" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -v-24H '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "")

    if [[ -n "$cutoff_time" ]]; then
        # Count errors in last 24 hours
        while IFS= read -r line; do
            if [[ "$line" =~ ERROR:\ ([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
                local error_time="${BASH_REMATCH[1]}"
                if [[ "$error_time" > "$cutoff_time" ]]; then
                    ((recent_errors++)) || true
                fi
            fi
        done < "$cli_error_log"
    else
        # Fallback: count all ERROR lines
        recent_errors=$(grep -c "^ERROR:" "$cli_error_log" 2>/dev/null || echo 0)
    fi

    # Evaluate error count
    if [[ $recent_errors -eq 0 ]]; then
        cli_issues+=("✓ No recent CLI errors")
    elif [[ $recent_errors -lt 5 ]]; then
        cli_issues+=("Found $recent_errors CLI error(s) in last 24 hours")
        # Show last error so user knows what happened
        local last_error
        last_error=$(tail -1 "$cli_error_log" 2>/dev/null || true)
        [[ -n "$last_error" ]] && cli_issues+=("Last: $last_error")
        cli_issues+=("Log: $cli_error_log")
        status=$HEALTH_WARNING
    elif [[ $recent_errors -lt 20 ]]; then
        cli_issues+=("Found $recent_errors CLI errors in last 24 hours - investigate")
        cli_issues+=("Log: $cli_error_log")
        status=$HEALTH_ERROR
    else
        cli_issues+=("CRITICAL: $recent_errors CLI errors in last 24 hours")
        cli_issues+=("Log: $cli_error_log")
        status=$HEALTH_CRITICAL
    fi

    # Check log size (warn if > 10MB)
    local log_size_mb
    log_size_mb=$((log_size / 1024 / 1024))
    if [[ $log_size_mb -gt 10 ]]; then
        cli_issues+=("CLI error log is ${log_size_mb}MB - consider rotation")
        [[ $status -lt $HEALTH_WARNING ]] && status=$HEALTH_WARNING
    fi

    # Store results
    NFTBAN_HEALTH_RESULTS["cli_errors"]=$status
    NFTBAN_HEALTH_ISSUES["cli_errors"]="${cli_issues[*]}"

    return $status
}

# Export functions
export -f nftban_health_check_config nftban_health_check_registry
export -f nftban_health_check_v030_helpers nftban_health_check_bash_completion
export -f nftban_health_check_cli_errors
