#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Debug Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Debug and troubleshooting tools
#
# meta:name="cmd_debug"
# meta:type="cli"
# meta:header="Debug Command"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Debug tools: trace enable/disable, log viewing, diagnostics"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-12-04"
# meta:updated_date="2025-12-04"
# =============================================================================

set -Eeuo pipefail

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"
[[ -z "${NFTBAN_CONFIG_DIR:-}" ]] && readonly NFTBAN_CONFIG_DIR="/etc/nftban"

# Prevent double-loading
[[ -n "${CMD_DEBUG_LOADED:-}" ]] && return 0
readonly CMD_DEBUG_LOADED=1

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_debug() {
    local subcommand="${1:-status}"
    shift || true

    # Source output module for banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
        nftban_banner
    fi
    echo ""

    case "$subcommand" in
        status)
            nftban_debug_status
            ;;
        enable|on)
            nftban_debug_enable "$@"
            ;;
        disable|off)
            nftban_debug_disable "$@"
            ;;
        trace)
            nftban_debug_trace "$@"
            ;;
        logs|log)
            nftban_debug_logs "$@"
            ;;
        dump)
            nftban_debug_dump "$@"
            ;;
        help|--help|-h)
            nftban_cmd_debug_usage
            ;;
        *)
            echo "ERROR: Unknown subcommand: $subcommand" >&2
            nftban_cmd_debug_usage
            return 1
            ;;
    esac
}

# =============================================================================
# STATUS
# =============================================================================

nftban_debug_status() {
    echo "NFTBan Debug Status"
    echo "==================="
    echo ""

    # Check current trace status from config
    local trace_enabled="false"
    local trace_log="${NFTBAN_LOG_DIR:-/var/log/nftban}/debug_trace.log"
    local log_level="INFO"

    if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
        trace_enabled=$(grep -E '^NFTBAN_DEBUG_TRACE=' "${NFTBAN_CONFIG_DIR}/nftban.conf" 2>/dev/null | cut -d'"' -f2 || echo "false")
        trace_log=$(grep -E '^NFTBAN_DEBUG_TRACE_LOG=' "${NFTBAN_CONFIG_DIR}/nftban.conf" 2>/dev/null | cut -d'"' -f2 || echo "${NFTBAN_LOG_DIR:-/var/log/nftban}/debug_trace.log")
        log_level=$(grep -E '^NFTBAN_LOG_LEVEL=' "${NFTBAN_CONFIG_DIR}/nftban.conf" 2>/dev/null | cut -d'"' -f2 || echo "INFO")
    fi

    # Display status
    echo "Debug Trace:"
    if [[ "$trace_enabled" == "true" ]]; then
        echo "  Status:     ✅ ENABLED"
    else
        echo "  Status:     ⚪ Disabled"
    fi
    echo "  Log file:   $trace_log"

    if [[ -f "$trace_log" ]]; then
        local trace_size
        trace_size=$(du -h "$trace_log" 2>/dev/null | cut -f1)
        local trace_lines
        trace_lines=$(wc -l < "$trace_log" 2>/dev/null || echo 0)
        echo "  Log size:   $trace_size ($trace_lines entries)"
    else
        echo "  Log size:   (no log file yet)"
    fi

    echo ""
    echo "Log Level:    $log_level"
    echo ""

    # Show orphan check
    if [[ -f "$trace_log" ]] && [[ "$trace_enabled" == "true" ]]; then
        echo "Recent Trace Activity:"
        echo "─────────────────────────────────────────"
        local start_count end_count
        start_count=$(grep -c '\[START\]' "$trace_log" 2>/dev/null || echo 0)
        end_count=$(grep -c '\[END\]' "$trace_log" 2>/dev/null || echo 0)
        echo "  START entries: $start_count"
        echo "  END entries:   $end_count"

        if [[ $start_count -gt $end_count ]]; then
            local diff=$((start_count - end_count))
            echo "  ⚠️  Potential orphans: $diff (run 'nftban debug trace orphans' to check)"
        else
            echo "  ✅ No orphaned traces detected"
        fi
    fi

    echo ""
    echo "Commands:"
    echo "  nftban debug enable     Enable debug trace"
    echo "  nftban debug disable    Disable debug trace"
    echo "  nftban debug trace      View trace log"
    echo "  nftban debug logs       View main log"
}

# =============================================================================
# ENABLE/DISABLE
# =============================================================================

nftban_debug_enable() {
    local what="${1:-trace}"
    local config_file="${NFTBAN_CONFIG_DIR}/nftban.conf"

    case "$what" in
        trace|all)
            echo "Enabling debug trace..."

            if [[ ! -f "$config_file" ]]; then
                echo "ERROR: Config file not found: $config_file" >&2
                return 1
            fi

            # Check if already enabled
            if grep -q '^NFTBAN_DEBUG_TRACE="true"' "$config_file" 2>/dev/null; then
                echo "Debug trace is already enabled"
                return 0
            fi

            # Update config
            if grep -q '^NFTBAN_DEBUG_TRACE=' "$config_file"; then
                sed -i 's/^NFTBAN_DEBUG_TRACE="false"/NFTBAN_DEBUG_TRACE="true"/' "$config_file"
            else
                echo 'NFTBAN_DEBUG_TRACE="true"' >> "$config_file"
            fi

            # Ensure log directory exists
            local log_dir="${NFTBAN_LOG_DIR:-/var/log/nftban}"
            [[ ! -d "$log_dir" ]] && mkdir -p "$log_dir"

            echo ""
            echo "✅ Debug trace ENABLED"
            echo ""
            echo "What happens now:"
            echo "  - Each script logs START/END with unique trace ID"
            echo "  - Log file: ${NFTBAN_LOG_DIR:-/var/log/nftban}/debug_trace.log"
            echo "  - Check for stuck scripts: nftban debug trace orphans"
            echo ""
            echo "To disable: nftban debug disable"
            ;;

        verbose)
            echo "Enabling verbose logging..."
            if grep -q '^NFTBAN_LOG_LEVEL=' "$config_file"; then
                sed -i 's/^NFTBAN_LOG_LEVEL="[^"]*"/NFTBAN_LOG_LEVEL="DEBUG"/' "$config_file"
            else
                echo 'NFTBAN_LOG_LEVEL="DEBUG"' >> "$config_file"
            fi
            echo "✅ Log level set to DEBUG"
            ;;

        *)
            echo "Unknown debug type: $what"
            echo "Options: trace, verbose, all"
            return 1
            ;;
    esac
}

nftban_debug_disable() {
    local what="${1:-trace}"
    local config_file="${NFTBAN_CONFIG_DIR}/nftban.conf"

    case "$what" in
        trace|all)
            echo "Disabling debug trace..."

            if [[ ! -f "$config_file" ]]; then
                echo "ERROR: Config file not found: $config_file" >&2
                return 1
            fi

            # Update config
            if grep -q '^NFTBAN_DEBUG_TRACE=' "$config_file"; then
                sed -i 's/^NFTBAN_DEBUG_TRACE="true"/NFTBAN_DEBUG_TRACE="false"/' "$config_file"
            fi

            echo "✅ Debug trace DISABLED"
            ;;

        verbose)
            echo "Resetting log level to INFO..."
            if grep -q '^NFTBAN_LOG_LEVEL=' "$config_file"; then
                sed -i 's/^NFTBAN_LOG_LEVEL="DEBUG"/NFTBAN_LOG_LEVEL="INFO"/' "$config_file"
            fi
            echo "✅ Log level set to INFO"
            ;;

        *)
            echo "Unknown debug type: $what"
            return 1
            ;;
    esac
}

# =============================================================================
# TRACE SUBCOMMANDS
# =============================================================================

nftban_debug_trace() {
    local subcommand="${1:-recent}"
    shift || true

    # Source trace library
    if [[ -f "${NFTBAN_LIB_DIR}/helpers/nftban_trace.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/helpers/nftban_trace.sh"
    fi

    case "$subcommand" in
        recent|tail)
            local count="${1:-30}"
            echo "Recent Trace Entries (last $count)"
            echo "════════════════════════════════════════════════════════════════"
            local trace_log="${NFTBAN_DEBUG_TRACE_LOG:-${NFTBAN_LOG_DIR:-/var/log/nftban}/debug_trace.log}"
            if [[ -f "$trace_log" ]]; then
                tail -n "$count" "$trace_log"
            else
                echo "(no trace log file)"
            fi
            ;;

        orphans|stuck)
            local minutes="${1:-5}"
            echo "Checking for Orphaned Traces (older than ${minutes}m)"
            echo "════════════════════════════════════════════════════════════════"
            echo ""
            if type nftban_trace_find_orphans &>/dev/null; then
                nftban_trace_find_orphans "$minutes"
            else
                echo "ERROR: Trace library not loaded" >&2
                return 1
            fi
            ;;

        stats)
            echo "Trace Statistics"
            echo "════════════════════════════════════════════════════════════════"
            if type nftban_trace_stats &>/dev/null; then
                nftban_trace_stats
            else
                # Manual stats
                local trace_log="${NFTBAN_DEBUG_TRACE_LOG:-${NFTBAN_LOG_DIR:-/var/log/nftban}/debug_trace.log}"
                if [[ -f "$trace_log" ]]; then
                    echo "START entries: $(grep -c '\[START\]' "$trace_log" 2>/dev/null || echo 0)"
                    echo "END entries:   $(grep -c '\[END\]' "$trace_log" 2>/dev/null || echo 0)"
                    echo "ERROR entries: $(grep -c '\[ERROR\]' "$trace_log" 2>/dev/null || echo 0)"
                    echo "Log size:      $(du -h "$trace_log" | cut -f1)"
                else
                    echo "(no trace log)"
                fi
            fi
            ;;

        clear|rotate)
            local days="${1:-7}"
            echo "Rotating trace log (keeping ${days} days)..."
            if type nftban_trace_rotate &>/dev/null; then
                nftban_trace_rotate "$days"
            else
                local trace_log="${NFTBAN_DEBUG_TRACE_LOG:-${NFTBAN_LOG_DIR:-/var/log/nftban}/debug_trace.log}"
                if [[ -f "$trace_log" ]]; then
                    mv "$trace_log" "${trace_log}.old"
                    touch "$trace_log"
                    echo "✅ Trace log rotated"
                fi
            fi
            ;;

        *)
            echo "Unknown trace command: $subcommand"
            echo "Options: recent [N], orphans [minutes], stats, clear [days]"
            return 1
            ;;
    esac
}

# =============================================================================
# LOGS
# =============================================================================

nftban_debug_logs() {
    local log_type="${1:-main}"
    local count="${2:-50}"
    local log_dir="${NFTBAN_LOG_DIR:-/var/log/nftban}"

    local log_file=""
    case "$log_type" in
        main|nftban)
            log_file="${log_dir}/nftban.log"
            ;;
        trace)
            log_file="${log_dir}/debug_trace.log"
            ;;
        login)
            log_file="${log_dir}/login-monitor.log"
            ;;
        bans)
            log_file="${log_dir}/bans.log"
            ;;
        all)
            echo "Available log files:"
            echo "─────────────────────────────────────────"
            for f in "${log_dir}"/*.log; do
                if [[ -f "$f" ]]; then
                    local size
                    size=$(du -h "$f" 2>/dev/null | cut -f1)
                    printf "  %-40s %s\n" "$f" "$size"
                fi
            done
            return 0
            ;;
        *)
            # Treat as filename
            if [[ -f "$log_type" ]]; then
                log_file="$log_type"
            elif [[ -f "${log_dir}/${log_type}.log" ]]; then
                log_file="${log_dir}/${log_type}.log"
            else
                echo "Unknown log type: $log_type"
                echo "Options: main, trace, login, bans, all"
                return 1
            fi
            ;;
    esac

    echo "Log: $log_file (last $count lines)"
    echo "════════════════════════════════════════════════════════════════"

    if [[ -f "$log_file" ]]; then
        tail -n "$count" "$log_file"
    else
        echo "(log file does not exist)"
    fi
}

# =============================================================================
# DUMP
# =============================================================================

nftban_debug_dump() {
    local what="${1:-all}"

    echo "NFTBan Debug Dump"
    echo "════════════════════════════════════════════════════════════════"
    echo "Generated: $(date)"
    echo ""

    case "$what" in
        config)
            echo "=== Configuration ==="
            if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
                # v1.19.0: Filter secrets from debug output (R42)
                grep -v '^#' "${NFTBAN_CONFIG_DIR}/nftban.conf" | grep -v '^$' \
                    | sed -E 's/(TOKEN|PASSWORD|SECRET|KEY|APIKEY|API_KEY)=.*/\1=***REDACTED***/i'
            fi
            ;;

        env)
            echo "=== Environment Variables ==="
            # v1.19.0: Filter secret-like env vars from debug output (R42)
            env | grep -E '^NFTBAN_' | sort \
                | sed -E 's/(TOKEN|PASSWORD|SECRET|KEY|APIKEY|API_KEY)=.*/\1=***REDACTED***/i'
            ;;

        services)
            echo "=== NFTBan Services ==="
            systemctl list-units 'nftban*' --no-pager 2>/dev/null || echo "(no systemd services)"
            ;;

        nft)
            echo "=== nftables Sets ==="
            nft list sets 2>/dev/null | head -50 || echo "(nft not available)"
            ;;

        all)
            nftban_debug_dump config
            echo ""
            nftban_debug_dump env
            echo ""
            nftban_debug_dump services
            echo ""
            nftban_debug_dump nft
            ;;

        *)
            echo "Unknown dump type: $what"
            echo "Options: config, env, services, nft, all"
            return 1
            ;;
    esac
}

# =============================================================================
# USAGE
# =============================================================================

nftban_cmd_debug_usage() {
    cat <<EOF
Usage: nftban debug <command> [OPTIONS]

Debug and troubleshooting tools.

Commands:
  status                 Show debug status
  enable [trace|verbose] Enable debug trace or verbose logging
  disable [trace|verbose] Disable debug trace or verbose logging
  trace recent [N]       Show last N trace entries (default: 30)
  trace orphans [MIN]    Find stuck scripts (older than MIN minutes)
  trace stats            Show trace statistics
  trace clear [DAYS]     Rotate trace log, keep DAYS (default: 7)
  logs [TYPE] [N]        View log file (main, trace, login, bans, all)
  dump [WHAT]            Dump debug info (config, env, services, nft, all)

Examples:
  nftban debug status              # Show debug status
  nftban debug enable              # Enable debug trace
  nftban debug enable verbose      # Also enable verbose logging
  nftban debug disable             # Disable debug trace
  nftban debug trace recent 50     # Show last 50 trace entries
  nftban debug trace orphans       # Find stuck/crashed scripts
  nftban debug logs main 100       # Show last 100 main log entries
  nftban debug dump all            # Full debug dump

Debug Trace:
  When enabled, each script logs START/END with unique trace ID.
  If a script has START without matching END = script is stuck/crashed.

  Enable:  nftban debug enable
  Check:   nftban debug trace orphans
  Disable: nftban debug disable

EOF
}

# Export functions
export -f nftban_cmd_debug
export -f nftban_cmd_debug_usage
