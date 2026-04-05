#!/usr/bin/env bash
# shellcheck disable=SC1090  # Dynamic config paths, cannot follow
# =============================================================================
# NFTBan v1.0 - Health Render Functions Library
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Output rendering functions (terminal, JSON, summary)
#
# meta:name="nftban_health_render"
# meta:type="library"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-01-09"
# meta:description="Render health check results in various formats"
# meta:input="Health check results arrays"
# meta:output="Formatted output (terminal, JSON)"
# meta:depends="nftban_health.sh"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_HEALTH_RENDER_LOADED:-}" ]] && return 0
_NFTBAN_HEALTH_RENDER_LOADED=1

# REPORTING
# =============================================================================

nftban_health_render_terminal() {
    # Render health check results to terminal - Clean v1.0 layout

    # Helper function to create dot-padded labels (20 char width)
    # Usage: pad_with_dots "Label" -> "Label..............."
    pad_with_dots() {
        local label="$1"
        local width=20
        local len=${#label}
        local dots_needed
        dots_needed=$((width - len))
        if [[ $dots_needed -gt 0 ]]; then
            local dots=""
            for ((i=0; i<dots_needed; i++)); do dots+="."; done
            echo "${label}${dots}"
        else
            echo "$label"
        fi
    }

    # Labels for each check type
    local -A check_labels=(
        [binaries]="Binaries"
        [binary_integrity]="Bin Integrity"
        [paths]="Paths"
        [permissions]="Permissions"
        [auditor_acls]="Auditor ACLs"
        [services]="Services"
        [daemon]="Daemon"
        [modules]="Modules"
        [geoip]="GeoIP"
        [geoban]="GeoBan"
        [databases]="Databases"
        [polkit]="Polkit"
        [bash_completion]="Bash Completion"
        [config]="Configuration"
        [metrics]="Metrics"
        [gui]="Web GUI"
        [nftables_security]="NFT Security"
        [nft_schema]="NFT Schema"
        [conflicting_firewalls]="Firewall Conflicts"
        [suricata]="Suricata"
        [suricata_capture]="Suricata Capture"
        [resources]="Resources"
        [registry]="Registry"
        [systemd_hardening]="Systemd Hardening"
        [memory_protection]="Memory Protection"
        [ssh_port]="SSH Port"
        [boot_safety]="Boot Safety"
        [cli_errors]="CLI Errors"
        [rbl]="RBL"
        [timers]="Timers"
        [fhs]="FHS Layout"
        [nftban_bin]="NFTBan Binary"
        [queue_processor]="Queue Processor"
        [protection]="Protection"
        [maintenance_lock]="Maintenance Lock"
        [login_monitor_ipc]="Login Monitor IPC"
        [portscan_prefix]="Portscan Prefix"
        [v030_helpers]="CLI Helpers"
        [pro]="Pro Features"
        [zabbix]="Zabbix"
        [connectors]="Connectors"
        [watchdog]="Watchdog"
    )

    # v1.24.1: Use exported scalar counts from check_all() (ground truth)
    # The ${NFTBAN_HEALTH_RESULTS+x} test is unreliable for associative arrays
    # declared via dynamic sourcing (bash quirk). Use exported scalars instead.
    local error_count="${NFTBAN_HEALTH_ERROR_COUNT:-0}"
    local warning_count="${NFTBAN_HEALTH_WARNING_COUNT:-0}"

    # Header
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan System Health Check"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # SYSTEM CHECKS section
    echo "SYSTEM CHECKS"
    echo "───────────────────────────────────────────────────────────"

    for check in binaries binary_integrity paths permissions auditor_acls services daemon timers modules config geoip geoban rbl databases nftables_security nft_schema conflicting_firewalls resources fhs nftban_bin queue_processor protection maintenance_lock login_monitor_ipc suricata suricata_capture registry cli_errors ssh_port boot_safety; do
        if [[ -n "${NFTBAN_HEALTH_RESULTS[$check]:-}" ]]; then
            local status=${NFTBAN_HEALTH_RESULTS[$check]}
            local status_text

            case $status in
                0) status_text="OK" ;;
                1) status_text="WARNING" ;;
                2) status_text="ERROR" ;;
                *) status_text="UNKNOWN" ;;
            esac

            local label="${check_labels[$check]:-$check}"
            local padded_label
            padded_label=$(pad_with_dots "$label")

            # v1.28.0: Add context note for config when using built-in defaults
            local context_note=""
            if [[ "$check" == "config" && $status -eq 0 ]]; then
                if [[ ! -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local" ]]; then
                    context_note=" (using defaults)"
                fi
            fi

            printf "  %s %s%s\n" "$padded_label" "$status_text" "$context_note"

            if [[ -n "${NFTBAN_HEALTH_ISSUES[$check]:-}" && $status -gt 0 ]]; then
                echo "    Issue: ${NFTBAN_HEALTH_ISSUES[$check]}"
            fi
        fi
    done
    echo ""

    # OPTIONAL FEATURES section
    echo "OPTIONAL FEATURES"
    echo "───────────────────────────────────────────────────────────"

    for check in systemd_hardening memory_protection metrics zabbix connectors watchdog gui polkit bash_completion portscan_prefix v030_helpers pro; do
        if [[ -n "${NFTBAN_HEALTH_RESULTS[$check]:-}" ]]; then
            local status=${NFTBAN_HEALTH_RESULTS[$check]}
            local status_text

            case $status in
                0) status_text="OK" ;;
                1) status_text="WARNING" ;;
                2) status_text="ERROR" ;;
                3) status_text="CRITICAL" ;;
                4) status_text="NOT INSTALLED" ;;
                5) status_text="DISABLED" ;;
                *) status_text="UNKNOWN" ;;
            esac

            local label="${check_labels[$check]:-$check}"
            local padded_label
            padded_label=$(pad_with_dots "$label")

            printf "  %s %s\n" "$padded_label" "$status_text"
        fi
    done
    echo ""

    # SUMMARY section
    echo "SUMMARY"
    echo "───────────────────────────────────────────────────────────"

    printf "  %s %d\n" "$(pad_with_dots "Errors")" "$error_count"
    printf "  %s %d\n" "$(pad_with_dots "Warnings")" "$warning_count"

    if [[ $error_count -eq 0 && $warning_count -eq 0 ]]; then
        printf "  %s OK\n" "$(pad_with_dots "Overall")"
    elif [[ $error_count -eq 0 ]]; then
        printf "  %s WARNING\n" "$(pad_with_dots "Overall")"
    else
        printf "  %s ERROR\n" "$(pad_with_dots "Overall")"
    fi
    echo ""

    # ERRORS section (only if errors exist)
    if [[ $error_count -gt 0 ]]; then
        echo "ERRORS"
        echo "───────────────────────────────────────────────────────────"
        # Show explicit error messages first
        for error in "${NFTBAN_HEALTH_ERRORS[@]}"; do
            echo "  - $error"
        done
        # Also show issues from checks that have ERROR/CRITICAL status but no explicit ERRORS entry
        # v1.50.1: Only show ERROR (2) and CRITICAL (3) — not DISABLED (5) or NOT_INSTALLED (4)
        for _ek in "${!NFTBAN_HEALTH_RESULTS[@]}"; do
            if [[ "${NFTBAN_HEALTH_RESULTS[$_ek]}" -eq 2 || "${NFTBAN_HEALTH_RESULTS[$_ek]}" -eq 3 ]] && [[ -n "${NFTBAN_HEALTH_ISSUES[$_ek]:-}" ]]; then
                # Check if this issue is already covered in NFTBAN_HEALTH_ERRORS
                local _already_shown=false
                for _existing in "${NFTBAN_HEALTH_ERRORS[@]}"; do
                    if [[ "$_existing" == *"${_ek}"* ]]; then
                        _already_shown=true
                        break
                    fi
                done
                if [[ "$_already_shown" == "false" ]]; then
                    local _label="${check_labels[$_ek]:-$_ek}"
                    echo "  - ${_label}: ${NFTBAN_HEALTH_ISSUES[$_ek]}"
                fi
            fi
        done
        echo ""
    fi

    # WARNINGS section (only if warnings exist)
    if [[ $warning_count -gt 0 ]]; then
        echo "WARNINGS"
        echo "───────────────────────────────────────────────────────────"
        for warning in "${NFTBAN_HEALTH_WARNINGS[@]}"; do
            echo "  - $warning"
        done
        echo ""

        # Helpful context for optional features
        if [[ $error_count -eq 0 ]]; then
            echo "NOTE"
            echo "───────────────────────────────────────────────────────────"
            echo "  Warnings are about OPTIONAL features, not problems."
            echo ""
            echo "  🟢 REQUIRED (working):  Core firewall, banning, health checks"
            echo "  🟡 OPTIONAL (warned):   Queue processing, metrics, web GUI"
            echo ""
            echo "  Your firewall protection is FULLY FUNCTIONAL."
            echo "  Optional features are for high-volume or enterprise setups."
            echo ""
            echo "  To silence warnings: Install optional features or ignore them."
            echo "  More info: nftban help optional"
            echo ""
        fi
    fi

    # QUICK COMMANDS section
    echo "QUICK COMMANDS"
    echo "───────────────────────────────────────────────────────────"
    echo "  nftban health fix        Auto-fix common issues"
    echo "  nftban health summary    One-line status"
    echo "  nftban health --json     JSON output for scripts"
    echo ""
}

nftban_health_render_summary() {
    # Render one-line summary of health status
    # Output: "Health: WARNING (2 warnings, 0 errors)"
    # Returns: 0=OK/WARNING, 2=ERROR
    # v1.37.1: Warnings exit 0 (optional features are not errors)

    # v1.24.1: Use exported scalar counts from check_all() (ground truth)
    local error_count="${NFTBAN_HEALTH_ERROR_COUNT:-0}"
    local warning_count="${NFTBAN_HEALTH_WARNING_COUNT:-0}"

    # Output summary based on status
    if [[ $error_count -eq 0 && $warning_count -eq 0 ]]; then
        echo "Health: OK"
        return 0
    elif [[ $error_count -eq 0 ]]; then
        echo "Health: WARNING ($warning_count warnings)"
        return 0
    else
        echo "Health: ERROR ($error_count errors, $warning_count warnings)"
        return 2
    fi
}

nftban_health_render_json() {
    # Render health check results as JSON
    # Output: Complete JSON object with all health data

    # v1.25: Use shared json_escape() from json_output.sh (dedup)
    # Loaded by cmd_health.sh or main dispatcher; guard for safety
    if ! declare -f json_escape &>/dev/null; then
        source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/helpers/json_output.sh" 2>/dev/null || true
    fi

    # v1.24.1: Use exported scalar counts from check_all() (ground truth)
    local error_count="${NFTBAN_HEALTH_ERROR_COUNT:-0}"
    local warning_count="${NFTBAN_HEALTH_WARNING_COUNT:-0}"

    # Determine overall status
    # v1.37.1: Warnings exit 0 (optional features are not errors)
    local overall_status="ok"
    local exit_code=0
    if [[ $error_count -gt 0 ]]; then
        overall_status="error"
        exit_code=2
    elif [[ $warning_count -gt 0 ]]; then
        overall_status="warning"
        exit_code=0
    fi

    # v1.78.0: Read NFTBan version
    local nftban_version
    nftban_version=$(cat "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/VERSION" 2>/dev/null || echo "unknown")

    echo "{"
    echo "  \"schema_version\": \"1.0.0\","
    echo "  \"timestamp\": \"$(date --iso-8601=seconds)\","
    echo "  \"nftban_version\": \"$nftban_version\","
    echo "  \"overall_status\": \"$overall_status\","
    echo "  \"exit_code\": $exit_code,"
    echo "  \"summary\": {"
    echo "    \"errors\": $error_count,"
    echo "    \"warnings\": $warning_count"
    echo "  },"

    # v1.78.0: Kernel validation data from Go validator
    local _validator_bin="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-validate"
    if [[ -x "$_validator_bin" ]]; then
        local _kernel_json
        _kernel_json=$("$_validator_bin" --json 2>/dev/null || echo '{}')
        echo "  \"kernel\": $_kernel_json,"
    else
        echo "  \"kernel\": {\"status\": \"unavailable\", \"reason\": \"validator binary not found\"},"
    fi

    # v1.78.0: Services status from systemd (head -1 for clean output)
    local _nftband_status _nftables_status _queue_status
    _nftband_status=$(systemctl is-active nftband.service 2>/dev/null | head -1 || echo "unknown")
    _nftables_status=$(systemctl is-active nftables.service 2>/dev/null | head -1 || echo "unknown")
    _queue_status=$(systemctl is-active nftban-queue.service 2>/dev/null | head -1 || echo "unknown")
    echo "  \"services\": {"
    echo "    \"nftband\": \"$_nftband_status\","
    echo "    \"nftables\": \"$_nftables_status\","
    echo "    \"queue\": \"$_queue_status\""
    echo "  },"

    # v1.78.0: Lifecycle data (last rebuild, rollback available)
    local _last_rebuild="null"
    local _rollback_available="false"
    local _backup_dir="/var/lib/nftban/backup"
    if [[ -d "$_backup_dir" ]]; then
        local _latest_snapshot
        _latest_snapshot=$(ls -1dt "$_backup_dir"/rebuild_* 2>/dev/null | head -1)
        if [[ -n "$_latest_snapshot" && -f "$_latest_snapshot/ruleset.nft" ]]; then
            _last_rebuild="\"$(basename "$_latest_snapshot" | sed 's/rebuild_//')\""
            _rollback_available="true"
        fi
    fi
    echo "  \"lifecycle\": {"
    echo "    \"last_rebuild\": $_last_rebuild,"
    echo "    \"rollback_available\": $_rollback_available"
    echo "  },"

    echo "  \"checks\": {"

    # Output ALL check results (iterate over all keys in results array)
    local first=true
    for check in "${!NFTBAN_HEALTH_RESULTS[@]}"; do
        if [[ -n "${NFTBAN_HEALTH_RESULTS[$check]:-}" ]]; then
            [[ "$first" == "false" ]] && echo ","
            first=false

            local status="${NFTBAN_HEALTH_RESULTS[$check]}"
            local status_name="ok"
            [[ $status -eq 1 ]] && status_name="warning"
            [[ $status -eq 2 ]] && status_name="error"
            # shellcheck disable=SC2178  # Intentional string from array
            local issues="${NFTBAN_HEALTH_ISSUES[$check]:-}"

            # shellcheck disable=SC2128  # First element extraction
            local escaped_issues
            # shellcheck disable=SC2128  # First element extraction (issues is string not array here)
            escaped_issues="$(json_escape "$issues")"

            echo -n "    \"$check\": {\"status\": \"$status_name\", \"exit_code\": $status, \"message\": \"$escaped_issues\"}"
        fi
    done

    echo ""
    echo "  },"
    echo "  \"errors\": ["

    # Output errors array
    if [[ $error_count -gt 0 ]]; then
        local first_error=true
        for error in "${NFTBAN_HEALTH_ERRORS[@]}"; do
            [[ "$first_error" == "false" ]] && echo ","
            first_error=false
            local escaped_error
            escaped_error="$(json_escape "$error")"
            echo -n "    \"$escaped_error\""
        done
        echo ""
    fi

    echo "  ],"
    echo "  \"warnings\": ["

    # Output warnings array
    if [[ $warning_count -gt 0 ]]; then
        local first_warn=true
        for warning in "${NFTBAN_HEALTH_WARNINGS[@]}"; do
            [[ "$first_warn" == "false" ]] && echo ","
            first_warn=false
            local escaped_warning
            escaped_warning="$(json_escape "$warning")"
            echo -n "    \"$escaped_warning\""
        done
        echo ""
    fi

    echo "  ],"

    # ==========================================================================
    # EXTENDED DATA (from shared check functions)
    # ==========================================================================
    # Load shared checks library if available
    local checks_lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_checks.sh"
    if [[ -f "$checks_lib" ]] && ! declare -f nftban_check_system_resources &>/dev/null; then
        # shellcheck source=/dev/null
        source "$checks_lib" 2>/dev/null || true
    fi

    echo "  \"extended\": {"

    # System resources (load, memory, disk)
    if declare -f nftban_check_system_resources &>/dev/null; then
        local resources_json
        resources_json=$(nftban_check_system_resources 2>/dev/null | jq -c '.data // {}' 2>/dev/null || echo '{}')
        echo "    \"resources\": $resources_json,"
    else
        echo "    \"resources\": {},"
    fi

    # Suricata status
    if declare -f nftban_check_suricata_status &>/dev/null; then
        local suricata_json
        suricata_json=$(nftban_check_suricata_status 2>/dev/null | jq -c '.data // {}' 2>/dev/null || echo '{}')
        echo "    \"suricata\": $suricata_json,"
    else
        echo "    \"suricata\": {},"
    fi

    # DNS status
    if declare -f nftban_check_dns &>/dev/null; then
        local dns_json
        dns_json=$(nftban_check_dns 2>/dev/null | jq -c '.data // {}' 2>/dev/null || echo '{}')
        echo "    \"dns\": $dns_json,"
    else
        echo "    \"dns\": {},"
    fi

    # Firewall conflicts
    if declare -f nftban_check_firewall_conflict &>/dev/null; then
        # Check each firewall
        local csf_json fw_json ufw_json ipt_json
        csf_json=$(nftban_check_firewall_conflict csf 2>/dev/null | jq -c '.data // {}' 2>/dev/null || echo '{}')
        fw_json=$(nftban_check_firewall_conflict firewalld 2>/dev/null | jq -c '.data // {}' 2>/dev/null || echo '{}')
        ufw_json=$(nftban_check_firewall_conflict ufw 2>/dev/null | jq -c '.data // {}' 2>/dev/null || echo '{}')
        ipt_json=$(nftban_check_firewall_conflict iptables 2>/dev/null | jq -c '.data // {}' 2>/dev/null || echo '{}')
        echo "    \"firewall_conflicts\": {\"csf\":$csf_json,\"firewalld\":$fw_json,\"ufw\":$ufw_json,\"iptables\":$ipt_json}"
    else
        echo "    \"firewall_conflicts\": {}"
    fi

    echo "  }"
    echo "}"

    return $exit_code
}

# =============================================================================
# INSTALLATION VERIFICATION
# =============================================================================

