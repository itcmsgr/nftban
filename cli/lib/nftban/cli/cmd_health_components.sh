#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0 - Health Check CLI Command - Components Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Component health checks: services, modules, binaries, permissions,
#          geoip, pro, install, registries
#
# meta:name="cmd_health_components"
# meta:type="cli"
# meta:header="Health Check Components Module"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Component health checks: services, modules, binaries, permissions, geoip, pro, install, registries"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="conditional"
#
# Loaded by: cmd_health.sh (inherits strict mode)
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_CMD_HEALTH_COMPONENTS_LOADED:-}" ]] && return 0
_CMD_HEALTH_COMPONENTS_LOADED="true"

# =============================================================================
# COMMAND: services
# =============================================================================

nftban_health_cmd_services() {
    # Check systemd services status
    # Args: none

    # Load health module
    if ! declare -f nftban_health_check_services >/dev/null 2>&1; then
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || {
            echo "ERROR: Failed to load health check module" >&2
            return 1
        }
    fi

    echo "NFTBan Services Status"
    echo "======================"
    echo ""

    nftban_health_init

    # Check services (capture result immediately to avoid strict mode issues)
    local result=0
    nftban_health_check_services || result=$?

    # Display results
    if [[ $result -eq 0 ]]; then
        echo "✅ All services: OK"
    elif [[ $result -eq 1 ]]; then
        echo "⚠️  Services: WARNING"
        if [[ -n "${NFTBAN_HEALTH_ISSUES[services]:-}" ]]; then
            echo "  ${NFTBAN_HEALTH_ISSUES[services]}"
        fi
    else
        echo "❌ Services: ERROR"
        if [[ -n "${NFTBAN_HEALTH_ISSUES[services]:-}" ]]; then
            echo "  ${NFTBAN_HEALTH_ISSUES[services]}"
        fi
    fi

    echo ""
    return $result
}

# =============================================================================
# COMMAND: modules
# =============================================================================

nftban_health_cmd_modules() {
    # Check loaded modules
    # Args: none

    # Load health module
    if ! declare -f nftban_health_check_modules >/dev/null 2>&1; then
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || {
            echo "ERROR: Failed to load health check module" >&2
            return 1
        }
    fi

    echo "NFTBan Modules Status"
    echo "====================="
    echo ""

    nftban_health_init

    # Check modules (capture result immediately to avoid strict mode issues)
    local result=0
    nftban_health_check_modules || result=$?

    # Display results
    if [[ $result -eq 0 ]]; then
        echo "✅ All modules: OK"
    elif [[ $result -eq 1 ]]; then
        echo "⚠️  Modules: WARNING"
        if [[ -n "${NFTBAN_HEALTH_ISSUES[modules]:-}" ]]; then
            echo "  ${NFTBAN_HEALTH_ISSUES[modules]}"
        fi
    else
        echo "❌ Modules: ERROR"
        if [[ -n "${NFTBAN_HEALTH_ISSUES[modules]:-}" ]]; then
            echo "  ${NFTBAN_HEALTH_ISSUES[modules]}"
        fi
    fi

    echo ""
    return $result
}

# =============================================================================
# COMMAND: binaries
# =============================================================================

nftban_health_cmd_binaries() {
    # Check required binaries
    # Args: none

    # Load health module
    if ! declare -f nftban_health_check_binaries >/dev/null 2>&1; then
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || {
            echo "ERROR: Failed to load health check module" >&2
            return 1
        }
    fi

    echo "NFTBan Binaries Status"
    echo "======================"
    echo ""

    nftban_health_init

    # Check binaries (capture result immediately to avoid strict mode issues)
    local result=0
    nftban_health_check_binaries || result=$?

    # Display results
    if [[ $result -eq 0 ]]; then
        echo "✅ All binaries: OK"
    elif [[ $result -eq 1 ]]; then
        echo "⚠️  Binaries: WARNING"
        if [[ -n "${NFTBAN_HEALTH_ISSUES[binaries]:-}" ]]; then
            echo "  ${NFTBAN_HEALTH_ISSUES[binaries]}"
        fi
    else
        echo "❌ Binaries: ERROR"
        if [[ -n "${NFTBAN_HEALTH_ISSUES[binaries]:-}" ]]; then
            echo "  ${NFTBAN_HEALTH_ISSUES[binaries]}"
        fi
    fi

    echo ""
    return $result
}

# =============================================================================
# COMMAND: permissions
# =============================================================================

nftban_health_cmd_permissions() {
    # Check file permissions
    # Args: none

    # Load health module
    if ! declare -f nftban_health_check_permissions >/dev/null 2>&1; then
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || {
            echo "ERROR: Failed to load health check module" >&2
            return 1
        }
    fi

    echo "NFTBan Permissions Status"
    echo "========================="
    echo ""

    nftban_health_init

    # Check permissions (capture result immediately to avoid strict mode issues)
    local result=0
    nftban_health_check_permissions || result=$?

    # Display results
    if [[ $result -eq 0 ]]; then
        echo "✅ Permissions: OK"
    elif [[ $result -eq 1 ]]; then
        echo "⚠️  Permissions: WARNING"
        if [[ -n "${NFTBAN_HEALTH_ISSUES[permissions]:-}" ]]; then
            echo "  ${NFTBAN_HEALTH_ISSUES[permissions]}"
        fi
    else
        echo "❌ Permissions: ERROR"
        if [[ -n "${NFTBAN_HEALTH_ISSUES[permissions]:-}" ]]; then
            echo "  ${NFTBAN_HEALTH_ISSUES[permissions]}"
        fi
    fi

    echo ""
    return $result
}

# =============================================================================
# COMMAND: geoip
# =============================================================================

nftban_health_cmd_geoip() {
    # Check GeoIP system status
    # Args: none

    # Load health module
    if ! declare -f nftban_health_check_geoip >/dev/null 2>&1; then
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || {
            echo "ERROR: Failed to load health check module" >&2
            return 1
        }
    fi

    echo "NFTBan GeoIP System Status"
    echo "=========================="
    echo ""

    nftban_health_init

    # Check GeoIP (capture result immediately to avoid strict mode issues)
    local result=0
    nftban_health_check_geoip || result=$?

    # Display results
    if [[ $result -eq 0 ]]; then
        echo "✅ GeoIP system: OK"

        # Show additional details if available
        local binary_path="${NFTBAN_LIB_DIR}/bin/nftban-geoip"
        local db_path
        db_path=$(cmd_get_geoip_database 2>/dev/null) || db_path=""

        if [[ -x "$binary_path" ]]; then
            local version
            version=$("$binary_path" version 2>/dev/null || echo "unknown")
            echo "  Binary: $binary_path"
            echo "  Version: $version"
        fi

        if [[ -n "$db_path" ]] && [[ -f "$db_path" ]]; then
            local db_size
            db_size=$(du -h "$db_path" | cut -f1)
            echo "  Database: $db_path"
            echo "  Size: $db_size"
        fi

        # Performance test
        if [[ -x "$binary_path" && -f "$db_path" ]]; then
            echo ""
            echo "  Performance test (8.8.8.8):"
            local start_time end_time elapsed
            start_time=$(date +%s%N)
            "$binary_path" lookup 8.8.8.8 >/dev/null 2>&1
            end_time=$(date +%s%N)
            elapsed=$(( (end_time - start_time) / 1000 ))
            echo "  Lookup time: ${elapsed} microseconds"
        fi
    elif [[ $result -eq 1 ]]; then
        # Check if it's just "not installed" (info) vs actual warning
        local issues="${NFTBAN_HEALTH_ISSUES[geoip]:-}"
        if [[ "$issues" == *"not installed (optional feature)"* ]]; then
            echo "ℹ️  GeoIP system: NOT INSTALLED (optional)"
            echo "  └─ To enable GeoIP features: nftban geoip update"
        else
            echo "⚠️  GeoIP system: WARNING"
            if [[ -n "$issues" ]]; then
                echo "  ${issues}"
            fi
        fi
    else
        echo "❌ GeoIP system: ERROR"
        if [[ -n "${NFTBAN_HEALTH_ISSUES[geoip]:-}" ]]; then
            echo "  ${NFTBAN_HEALTH_ISSUES[geoip]}"
        fi
    fi

    echo ""
    return $result
}

# =============================================================================
# COMMAND: pro
# =============================================================================

nftban_health_cmd_pro() {
    # Check NFTBan Pro subscription status
    # Args: none

    # Load health module
    if ! declare -f nftban_health_check_pro >/dev/null 2>&1; then
        source "${NFTBAN_LIB_DIR}/core/nftban_health.sh" || {
            echo "ERROR: Failed to load health check module" >&2
            return 1
        }
    fi

    echo "NFTBan Pro Subscription Status"
    echo "==============================="
    echo ""

    nftban_health_init

    # Check Pro (capture result immediately to avoid strict mode issues)
    local result=0
    nftban_health_check_pro || result=$?

    # Display results
    if [[ $result -eq 0 ]]; then
        echo "✅ Pro subscription: OK"
    elif [[ $result -eq 4 ]]; then
        # HEALTH_NOT_INSTALLED
        echo "ℹ️  Pro subscription: NOT ENABLED"
        echo "  └─ To enable: nftban pro enroll"
    elif [[ $result -eq 1 ]]; then
        echo "⚠️  Pro subscription: WARNING"
    else
        echo "❌ Pro subscription: ERROR"
    fi

    # Show detailed issues if available
    if [[ -n "${NFTBAN_HEALTH_ISSUES[pro]:-}" ]]; then
        echo ""
        echo "Details:"
        # Format with proper indentation
        echo "  ${NFTBAN_HEALTH_ISSUES[pro]}" | sed 's/^/  /'
    fi

    echo ""
    return $result
}

# =============================================================================
# COMMAND: install
# =============================================================================

nftban_health_cmd_install() {
    # Verify installation completeness
    # Usage: nftban health install [--verbose]

    local verbose=0

    for arg in "$@"; do
        case "$arg" in
            --verbose|-v) verbose=1 ;;
            --help|-h)
                echo "Usage: nftban health install [--verbose]"
                echo ""
                echo "Verify NFTBan installation completeness."
                echo "Checks all required timers, services, binaries, directories, and configs."
                echo ""
                echo "Options:"
                echo "  --verbose, -v    Show optional components status"
                return 0
                ;;
        esac
    done

    # Ensure function is loaded
    if ! declare -f nftban_health_verify_installation >/dev/null 2>&1; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_health.sh" ]]; then
            source "${NFTBAN_LIB_DIR}/core/nftban_health.sh"
        fi
    fi

    if ! declare -f nftban_health_verify_installation >/dev/null 2>&1; then
        echo "ERROR: Installation verification function not available" >&2
        return 1
    fi

    nftban_banner "health"
    nftban_health_verify_installation "$verbose"
}

# =============================================================================
# COMMAND: registries
# =============================================================================

nftban_health_cmd_registries() {
    # Check NFTBan registry files validity
    # Args: [--json]

    local format="text"

    for arg in "$@"; do
        case "$arg" in
            --json) format="json" ;;
        esac
    done

    # Use dedicated registry check script if available
    local registry_check="${NFTBAN_LIB_DIR}/health/check_registries.sh"

    if [[ -x "$registry_check" ]]; then
        "$registry_check" "$format"
        return $?
    fi

    # Fallback: inline check
    echo "NFTBan Registry Validation"
    echo "=========================="
    echo ""

    local errors=0
    local warnings=0

    # Registry paths
    local commands_reg="${NFTBAN_LIB_DIR}/../commands.registry.yml"
    local config_reg="${NFTBAN_LIB_DIR}/data/config-registry.json"
    local schema_reg="${NFTBAN_LIB_DIR}/data/config-schema.json"
    local reports_reg="${NFTBAN_LIB_DIR}/data/reports-registry.json"

    # Check commands registry (YAML)
    if [[ -f "$commands_reg" ]]; then
        if python3 -c "import yaml; yaml.safe_load(open('$commands_reg'))" 2>/dev/null; then
            echo "  ✓ commands.registry.yml: Valid"
        else
            echo "  ✗ commands.registry.yml: Invalid YAML"
            # v1.19.20 FIX
            ((errors++)) || true
        fi
    else
        echo "  ⚠ commands.registry.yml: Not found"
        # v1.19.20 FIX
        ((warnings++)) || true
    fi

    # Check JSON registries
    for reg_file in "$config_reg" "$schema_reg" "$reports_reg"; do
        local reg_name
        reg_name=$(basename "$reg_file")
        if [[ -f "$reg_file" ]]; then
            if python3 -m json.tool "$reg_file" >/dev/null 2>&1; then
                echo "  ✓ $reg_name: Valid"
            else
                echo "  ✗ $reg_name: Invalid JSON"
                # v1.19.20 FIX
                ((errors++)) || true
            fi
        else
            echo "  ⚠ $reg_name: Not found"
            # v1.19.20 FIX
            ((warnings++)) || true
        fi
    done

    echo ""
    echo "─────────────────────────────────────────────────────────"

    if [[ $errors -gt 0 ]]; then
        echo "Status: ERROR ($errors errors, $warnings warnings)"
        return 2
    elif [[ $warnings -gt 0 ]]; then
        echo "Status: WARNING ($warnings warnings)"
        return 1
    else
        echo "Status: OK (all registries valid)"
        return 0
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_health_cmd_services
export -f nftban_health_cmd_modules
export -f nftban_health_cmd_binaries
export -f nftban_health_cmd_permissions
export -f nftban_health_cmd_geoip
export -f nftban_health_cmd_pro
export -f nftban_health_cmd_install
export -f nftban_health_cmd_registries
