#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Health Check CLI Handler (Loader)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI interface for system health checks and diagnostics
#
# meta:name="cmd_health"
# meta:type="cli"
# meta:header="Health Check CLI Handler"
# meta:version="1.43.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="CLI commands for health checks including registry validation"
# meta:created_date="2025-11-05"
# meta:updated_date="2026-01-13"
#
# meta:inventory.files=""
# meta:inventory.binaries="python3"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="conditional"
#
# =============================================================================
# MODULE LOADER
# =============================================================================
# Health CLI functions are split into separate files for maintainability:
#
# cmd_health_core.sh       - check, summary, json, report, fix
# cmd_health_components.sh - services, modules, binaries, permissions, geoip, pro, install, registries
# cmd_health_analysis.sh   - conflicts, config, rbl, posture
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true

# Load JSON helper for --json support
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi

JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER" || return 1
fi

# Enhanced strict mode
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_CLI_HEALTH_LOADED:-}" ]] && return 0
readonly NFTBAN_CLI_HEALTH_LOADED=1

# =============================================================================
# MODULE LOADER
# =============================================================================

# Get the directory where this script is located
_cmd_health_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_cmd_health_modules=(
    "cmd_health_core.sh"
    "cmd_health_components.sh"
    "cmd_health_analysis.sh"
)

for _module in "${_cmd_health_modules[@]}"; do
    _module_path="${_cmd_health_dir}/${_module}"
    if [[ -f "$_module_path" ]]; then
        # shellcheck source=/dev/null
        source "$_module_path" || {
            echo "ERROR: Failed to load health module: $_module" >&2
            return 1
        }
    else
        echo "ERROR: Health module not found: $_module_path" >&2
        return 1
    fi
done

# Cleanup temporary variables
unset _cmd_health_modules _module _module_path _cmd_health_dir

# =============================================================================
# MAIN CLI HANDLER
# =============================================================================

nftban_cmd_health() {
    # Main health command handler
    # Args: subcommand [options]

    # V129 PR-C D4: if the first argument is a global flag (not a subcommand),
    # default subcommand to "check" and leave the flag in $@ so the args loop
    # below can parse it. Without this, `nftban health --verbose` mis-sets
    # subcommand="--verbose" and the case below emits "Unknown health command".
    local subcommand
    case "${1:-}" in
        --verbose|-v|--json)
            subcommand="check"
            ;;
        *)
            subcommand="${1:-check}"
            shift || true
            ;;
    esac

    # v1.83 F2 fix: scan for --json AFTER shift, so subcommand position
    # is excluded. Then build a clean args array without --json so it
    # is never leaked to downstream functions (F1 fix).
    #
    # V127 UX-1 item 1.2: also parse --verbose / -v. INFO-severity findings
    # are filtered from default `nftban health` output (alarm-reduction;
    # makes the command usable as a fleet-wide signal). Operators who want
    # INFO details pass --verbose. Like --json, the flag is stripped from
    # clean_args so it never leaks to downstream subcommand handlers.
    # (Scope: AUDIT_190_LIFECYCLE/V127_FULL_UX_CORRECTION_UMBRELLA_SCOPE.md UX-1 item 1.2)
    local json_mode=false
    local verbose_mode=false
    local -a clean_args=()
    for arg in "$@"; do
        if [[ "$arg" == "--json" ]]; then
            json_mode=true
        elif [[ "$arg" == "--verbose" || "$arg" == "-v" ]]; then
            verbose_mode=true
        else
            clean_args+=("$arg")
        fi
    done

    # Load output module (for help banner)
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
    fi

    case "$subcommand" in
        # =================================================================
        # v1.83: TRUTH PATH (default) — Go validator backed, read-only
        # =================================================================
        check|""|truth|axes)
            # v1.83: Default is Go-backed protection truth (4-axis table).
            # This is the primary operator health surface — fast, read-only,
            # deterministic. No side effects, no environment scanning.
            #
            # SF-1 (v1.100.2): the truth path returns 2 on a released/no-tables
            # host (validator exits 2, function returns 2 after rendering a
            # DOWN table). The `|| return $?` idiom keeps that exit code as
            # the dispatcher's exit while suppressing the ERR trap that would
            # otherwise print "ERROR: Script failed" on top of the table.
            nftban_health_cmd_truth "$json_mode" "$verbose_mode" || return $?
            ;;

        # =================================================================
        # v1.83: DIAGNOSTICS PATH — shell environment checks
        # =================================================================
        diagnostics|detailed)
            # v1.84: Extended environment/UX diagnostic checks.
            # These are NOT protection truth — they check packaging,
            # permissions, integrations, and optional features.
            # --auto-heal: trigger fixes for detected issues (requires elevated privileges)
            # --quiet: minimal output (for cron/timer use)
            if [[ "$json_mode" == "true" ]]; then
                nftban_health_cmd_json "${clean_args[@]}"
            else
                nftban_health_cmd_check "${clean_args[@]}"
            fi
            ;;
        --auto-heal)
            # Shorthand: nftban health --auto-heal → diagnostics --auto-heal
            nftban_health_cmd_check "--auto-heal" "${clean_args[@]}"
            ;;
        --quiet)
            # Shorthand: nftban health --quiet → diagnostics --quiet
            nftban_health_cmd_check "--quiet" "${clean_args[@]}"
            ;;

        # =================================================================
        # FIX PATH — side effects (auto-heal)
        # =================================================================
        fix|enforce|--fix)
            nftban_health_cmd_fix "${clean_args[@]}"
            ;;

        # =================================================================
        # MONITORING INTEGRATIONS
        # =================================================================
        --brief|brief)
            nftban_health_cmd_brief "${clean_args[@]}"
            ;;
        --nagios|nagios)
            nftban_health_cmd_nagios "${clean_args[@]}"
            ;;
        summary)
            nftban_health_cmd_summary "${clean_args[@]}"
            ;;
        json|--json)
            # v1.84: "nftban health json" outputs Go validator truth JSON.
            # For diagnostics JSON, use: nftban health diagnostics --json
            # SF-1 (v1.100.2): see check/truth/axes branch above.
            # V127 UX-1 item 1.2: JSON mode is unaffected by the verbose filter
            # — JSON consumers get the full findings array regardless of severity.
            nftban_health_cmd_truth "true" "true" || return $?
            ;;

        # =================================================================
        # DIAGNOSTIC SUBCOMMANDS (environment checks, not truth)
        # =================================================================
        binaries)
            nftban_health_cmd_binaries "${clean_args[@]}"
            ;;
        geoip)
            nftban_health_cmd_geoip "${clean_args[@]}"
            ;;
        pro)
            nftban_health_cmd_pro "${clean_args[@]}"
            ;;
        registries|registry)
            nftban_health_cmd_registries "${clean_args[@]}"
            ;;
        install|verify)
            nftban_health_cmd_install "${clean_args[@]}"
            ;;
        conflicts)
            nftban_health_cmd_conflicts "${clean_args[@]}"
            ;;
        config)
            nftban_health_cmd_config "${clean_args[@]}"
            ;;
        rbl)
            nftban_health_cmd_rbl "${clean_args[@]}"
            ;;
        botguard)
            nftban_health_cmd_botguard "${clean_args[@]}"
            ;;
        fhs)
            if [[ -f "${NFTBAN_LIB_DIR}/cli/cmd_fhs.sh" ]]; then
                # shellcheck source=/dev/null
                source "${NFTBAN_LIB_DIR}/cli/cmd_fhs.sh"
                nftban_cmd_fhs "${clean_args[@]}"
            else
                echo "ERROR: cmd_fhs.sh not found" >&2
                return 1
            fi
            ;;
        posture|security)
            nftban_health_cmd_posture "${clean_args[@]}"
            ;;

        # =================================================================
        # REMOVED / REDIRECTED
        # =================================================================
        report)
            echo "REMOVED: 'nftban health report' was removed in v1.39.0" >&2
            echo "Use: nftban health json" >&2
            return 1
            ;;
        services)
            echo "REMOVED: 'nftban health services' was removed in v1.39.0" >&2
            echo "Use: nftban services" >&2
            return 1
            ;;
        modules)
            echo "REMOVED: 'nftban health modules' was removed in v1.39.0" >&2
            echo "Use: nftban module list" >&2
            return 1
            ;;
        permissions)
            echo "REMOVED: 'nftban health permissions' was removed in v1.39.0" >&2
            echo "Use: nftban fhs" >&2
            return 1
            ;;

        help|-h|--help)
            nftban_health_cmd_help
            ;;
        *)
            echo "ERROR: Unknown health command: $subcommand" >&2
            echo "Run 'nftban health help' for usage information" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# HELP
# =============================================================================

nftban_health_cmd_help() {
    # Show help text

    nftban_banner "health"
    echo ""

    cat << 'EOF'
nftban health - Protection truth and system diagnostics

USAGE:
    nftban health [command] [options]

PROTECTION TRUTH (default):
    (no args), check, truth
                            Show protection state from Go validator (default)
                            Four-axis truth table: config, structural, runtime, effective
                            Fast, read-only, no side effects
                            --json: output frozen schema JSON

DIAGNOSTICS:
    diagnostics [--auto-heal] [--quiet]
                            Run extended environment checks (shell-based)
                            Checks packaging, permissions, integrations, optional features
                            --auto-heal: Automatically fix detected issues (requires elevated privileges)
                            --quiet: Minimal output (for cron/timer use)

    fix, enforce [target]   Auto-fix common issues (requires elevated privileges)
                            Targets: permissions, directories, services, all

    binaries                Check required binaries
    geoip                   Check GeoIP system status
    pro                     Check NFTBan Pro subscription status
    registries              Check registry files validity
    install, verify         Verify installation completeness
    conflicts [--fix]       Detect/remove conflicting firewalls
    config [--verbose]      Show module and config status
    posture, security       Check security posture (low noise)
    botguard                Check BotGuard module status
    rbl                     Check RBL (DNS blocklist) health
    fhs                     Check FHS compliance (delegates to 'nftban fhs')

MONITORING:
    summary                 One-line health summary
    brief                   One-line output for CI/fleet
    nagios                  Nagios/monitoring plugin format
    json                    Full JSON health output

    help                    Show this help message

EXAMPLES:
    # Full system health check
    nftban health check
    nftban health              # Same as 'check'

    # Quick summary for scripts
    nftban health summary      # Output: "Health: WARNING (2 warnings)"

    # JSON for dashboards
    nftban health json | jq .

    # Check specific component
    nftban health geoip
    nftban health binaries
    nftban health botguard     # HTTP Bot Guard health
    nftban health pro          # Pro subscription status

    # Auto-heal during check (combines check + fix)
    nftban health check --auto-heal

    # Quiet mode for cron/timer
    nftban health check --auto-heal --quiet

    # Manual fix (traditional approach)
    nftban health fix all

    # Or use 'enforce' (alias for 'fix')
    nftban health enforce all

    # Verify installation completeness
    nftban health install
    nftban health install --verbose  # Include optional components

    # Check config and module status
    nftban health config             # Show enabled modules + config status
    nftban health config --verbose   # Include config file paths

    # Security posture (low noise check)
    nftban health posture            # SSH, sudo, systemd, MAC (AppArmor/SELinux)
    # Posture is advisory (never changes exit code). Compact summary also shows in
    # 'nftban status'. Posture output is text-only; --json is accepted but the
    # posture subcommand does not serialize posture fields as JSON
    # (see docs/security/MAC_PROFILES_SELINUX_APPARMOR.md §12).

HEALTH STATUS CODES:
    ✅ OK       - All checks passed
    ⚠️  WARNING - Non-critical issues found
    ❌ ERROR    - Critical issues found

AUTO-FIX CAPABILITIES:
    - Create missing directories
    - Fix file ownership (nftban:nftban)
    - Fix file permissions (755, 750, 644, 640)
    - Restart failed services
    - Fix executable permissions

NOTES:
    - Most commands can run as regular user
    - 'fix' command requires elevated privileges (members of the nftban group are authorized via PolicyKit/polkit rules)
    - Run 'check' after 'fix' to verify repairs
    - Health checks are non-destructive

NFTBan — Open-source Linux IPS and nftables firewall manager
EOF
}

# =============================================================================
# EXPORTS
# =============================================================================

# Export main handler
# =============================================================================
# v1.82: Four-axis health truth table (M81-4 implementation)
# =============================================================================
# Reads the Go validator's frozen schema output and renders a per-module
# health table using vocabulary-approved terms only. CLI is presentation
# layer only — it MUST NOT compute health states independently.
# =============================================================================

nftban_health_cmd_truth() {
    # V127 UX-1 item 1.2: 2nd arg is verbose_mode (default false). When false (default),
    # INFO-severity findings are filtered from the rendered text output to avoid the
    # "Findings (1): [INFO] VAL-LOGINMON-001" alarming-but-useless display on healthy
    # idle hosts. JSON mode ignores the filter — JSON consumers get all findings.
    # (Scope: AUDIT_190_LIFECYCLE/V127_FULL_UX_CORRECTION_UMBRELLA_SCOPE.md UX-1 item 1.2)
    local json_mode="${1:-false}"
    local verbose_mode="${2:-false}"
    local validator_bin="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-validate"

    if [[ ! -x "$validator_bin" ]]; then
        # v1.83: Warn and fall back to diagnostics if Go binary missing.
        # Target: remove fallback in v1.84.
        echo "WARNING: Go validator not found at $validator_bin — falling back to diagnostics (deprecated, removal in v1.84)" >&2
        if [[ "$json_mode" == "true" ]]; then
            nftban_health_cmd_json
        else
            nftban_health_cmd_check
        fi
        return
    fi

    # R-2 (issue #470): capture validator exit code without triggering the
    # ERR trap under `set -Eeuo pipefail`. A bare `output=$(...)` assignment
    # propagates the command's non-zero exit to the trap, which kills the
    # health CLI at the exact moment an operator needs it.
    #
    # BASH GOTCHA: `if ! var=$(cmd); then rc=$?; fi` captures $?=0 because
    # the assignment's own exit code is 0 (assignment succeeded), not cmd's.
    # The `cmd || rc=$?` idiom below correctly captures cmd's exit code
    # without firing the ERR trap (|| suppresses trap on left operand).
    local output=""
    local validator_rc=0
    local validator_err_file
    validator_err_file="$(mktemp)"
    output="$("$validator_bin" --json 2>"$validator_err_file")" || validator_rc=$?
    local validator_err=""
    [[ -s "$validator_err_file" ]] && validator_err="$(cat "$validator_err_file")"
    rm -f "$validator_err_file"

    if (( validator_rc != 0 )) || [[ -z "$output" ]]; then
        local summary_err="${validator_err:0:500}"
        if [[ "$json_mode" == "true" ]]; then
            jq -n \
                --arg bin "$validator_bin" \
                --argjson rc "$validator_rc" \
                --arg err "$summary_err" \
                '{
                    schema_version: "1.83.0",
                    status: "down",
                    truth: "failed",
                    validator: { binary: $bin, exit_code: $rc, stderr: $err }
                }'
        else
            echo ""
            echo "NFTBan Health — Four-Axis Truth Table"
            echo "═══════════════════════════════════════════════════════════════"
            echo ""
            printf "  %-14s %s\n" "Overall:" "DOWN"
            printf "  %-14s %s\n" "Truth:" "FAILED (validator exit $validator_rc)"
            printf "  %-14s %s\n" "Validator:" "$validator_bin"
            if [[ -n "$summary_err" ]]; then
                echo ""
                echo "  Validator stderr:"
                # bounded, indented excerpt
                printf '%s\n' "$summary_err" | sed 's/^/    /'
            fi
            echo ""
        fi
        return 2
    fi

    # v1.83: Schema version guard
    local _schema_version
    _schema_version=$(echo "$output" | jq -r '.schema_version // empty' 2>/dev/null)
    local _expected_schema="1.83.0"
    if [[ -n "$_schema_version" && "$_schema_version" != "$_expected_schema" ]]; then
        echo "WARNING: validator schema $_schema_version does not match expected $_expected_schema" >&2
    fi

    if [[ "$json_mode" == "true" ]]; then
        # JSON mode: pass through the frozen schema directly
        echo "$output" | jq '{schema_version, status, service_state, modules, consistency}' 2>/dev/null
        return $?
    fi

    # Text mode: render four-axis table
    local status
    status=$(echo "$output" | jq -r '.status' 2>/dev/null)
    local nftband_state
    nftband_state=$(echo "$output" | jq -r '.service_state.nftband' 2>/dev/null)
    local consistency
    consistency=$(echo "$output" | jq -r '.consistency.kernel_vs_validator' 2>/dev/null)

    echo ""
    echo "NFTBan Health — Four-Axis Truth Table"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    printf "  %-14s %s\n" "Overall:" "$(echo "$status" | tr '[:lower:]' '[:upper:]')"
    printf "  %-14s %s\n" "Daemon:" "$nftband_state"
    printf "  %-14s %s\n" "Consistency:" "$consistency"
    echo ""
    echo "  Module       Config     Structure  Runtime    Effective"
    echo "  ───────────  ─────────  ─────────  ─────────  ─────────"

    # Render each standard module
    for mod in botguard ddos portscan loginmon; do
        local config structural runtime effective
        config=$(echo "$output" | jq -r ".modules.${mod}.config // \"-\"" 2>/dev/null)
        structural=$(echo "$output" | jq -r ".modules.${mod}.structural // \"-\"" 2>/dev/null)
        runtime=$(echo "$output" | jq -r ".modules.${mod}.runtime // \"-\"" 2>/dev/null)
        effective=$(echo "$output" | jq -r ".modules.${mod}.effective // \"-\"" 2>/dev/null)

        # Fix null rendering
        [[ "$config" == "null" ]] && config="-"
        [[ "$structural" == "null" ]] && structural="-"
        [[ "$runtime" == "null" ]] && runtime="-"
        [[ "$effective" == "null" ]] && effective="-"

        printf "  %-11s  %-9s  %-9s  %-9s  %s\n" "$mod" "$config" "$structural" "$runtime" "$effective"
    done

    # Render blacklist (composite)
    echo ""
    echo "  Blacklist    State      Entries"
    echo "  ───────────  ─────────  ───────"
    for sub in manual feeds geoban; do
        local state entries
        state=$(echo "$output" | jq -r ".modules.blacklist.${sub}.state // \"-\"" 2>/dev/null)
        entries=$(echo "$output" | jq -r ".modules.blacklist.${sub}.entries // 0" 2>/dev/null)
        [[ "$state" == "null" ]] && state="-"
        [[ "$entries" == "null" ]] && entries="0"
        printf "  %-11s  %-9s  %s\n" "$sub" "$state" "$entries"
    done

    # Render findings (V127 UX-1 item 1.2: filter by severity).
    #
    # Default (verbose_mode=false): emit only WARN / ERROR findings. If zero remain,
    # print "Findings: none" instead of an alarming "Findings (1):" header. If INFO
    # findings exist, mention the count + how to surface them (--verbose). This makes
    # `nftban health` usable as a fleet-wide signal on healthy idle hosts where the
    # INFO-only state was reading as "something is wrong" pre-V127.
    #
    # Verbose (verbose_mode=true OR called from json|--json branch): emit all findings
    # regardless of severity. JSON consumers always see the full array.
    local total_count info_count visible_count
    total_count=$(echo "$output" | jq '.findings | length' 2>/dev/null || echo "0")
    info_count=$(echo "$output" | jq '[.findings[] | select(.severity == "info" or .severity == "INFO")] | length' 2>/dev/null || echo "0")
    if [[ "$verbose_mode" == "true" ]]; then
        visible_count="$total_count"
    else
        visible_count=$((total_count - info_count))
    fi

    echo ""
    if [[ "$visible_count" -gt 0 ]]; then
        echo "  Findings ($visible_count):"
        if [[ "$verbose_mode" == "true" ]]; then
            echo "$output" | jq -r '.findings[] | "    [\(.severity | ascii_upcase)] \(.code): \(.message)"' 2>/dev/null
        else
            echo "$output" | jq -r '.findings[] | select(.severity != "info" and .severity != "INFO") | "    [\(.severity | ascii_upcase)] \(.code): \(.message)"' 2>/dev/null
        fi
        if [[ "$verbose_mode" != "true" && "$info_count" -gt 0 ]]; then
            echo "    (${info_count} INFO finding(s) hidden — use --verbose to show)"
        fi
    else
        if [[ "$info_count" -gt 0 ]]; then
            echo "  Findings: none (${info_count} INFO finding(s) hidden — use --verbose to show)"
        else
            echo "  Findings: none"
        fi
    fi

    echo ""
}

export -f nftban_health_cmd_truth
export -f nftban_cmd_health

# Export subcommand functions (loaded from modules)
export -f nftban_health_cmd_check
export -f nftban_health_cmd_brief
export -f nftban_health_cmd_summary
export -f nftban_health_cmd_json
export -f nftban_health_cmd_fix
export -f nftban_health_cmd_binaries
export -f nftban_health_cmd_geoip
export -f nftban_health_cmd_pro
export -f nftban_health_cmd_registries
export -f nftban_health_cmd_rbl
export -f nftban_health_cmd_botguard
export -f nftban_health_cmd_posture
export -f nftban_health_cmd_conflicts
export -f nftban_health_cmd_config
export -f nftban_health_cmd_install
export -f nftban_health_cmd_help
