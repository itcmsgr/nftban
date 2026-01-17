#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.2.0 - Support Bundle Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Collect diagnostic information for troubleshooting
#
# meta:name="cmd_support"
# meta:type="cli"
# meta:header="Support Bundle Command"
# meta:version="1.2.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Collect diagnostic information for troubleshooting NFTBan issues"
# meta:inventory.files="/tmp/nftban-support-*.tar.gz"
# meta:inventory.binaries="tar,journalctl,nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2026-01-16"
# meta:updated_date="2026-01-16"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# Prevent double-loading
[[ -n "${NFTBAN_CLI_SUPPORT_LOADED:-}" ]] && return 0
readonly NFTBAN_CLI_SUPPORT_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly SUPPORT_OUTPUT_DIR="${NFTBAN_SUPPORT_DIR:-/tmp}"
readonly SUPPORT_LOG_HOURS="${NFTBAN_SUPPORT_LOG_HOURS:-24}"

# Directories to collect configs from
readonly NFTBAN_CONFIG_DIR="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
readonly NFTBAN_LOG_DIR="${NFTBAN_LOG_DIR:-/var/log/nftban}"
readonly NFTBAN_GIT_REPO="${NFTBAN_GIT_REPO:-/opt/nftban}"

# Patterns for secret redaction
readonly -a SECRET_PATTERNS=(
    's/([Aa][Pp][Ii][-_]?[Kk][Ee][Yy]\s*[=:]\s*)["\x27]?[^"\x27\s]+["\x27]?/\1[REDACTED]/g'
    's/([Tt][Oo][Kk][Ee][Nn]\s*[=:]\s*)["\x27]?[^"\x27\s]+["\x27]?/\1[REDACTED]/g'
    's/([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]\s*[=:]\s*)["\x27]?[^"\x27\s]+["\x27]?/\1[REDACTED]/g'
    's/([Ss][Ee][Cc][Rr][Ee][Tt]\s*[=:]\s*)["\x27]?[^"\x27\s]+["\x27]?/\1[REDACTED]/g'
    's/(Bearer\s+)[A-Za-z0-9._-]+/\1[REDACTED]/g'
    's/([Aa][Uu][Tt][Hh]\s*[=:]\s*)["\x27]?[^"\x27\s]+["\x27]?/\1[REDACTED]/g'
)

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

_support_log() {
    local level="$1"
    shift
    local msg="$*"

    case "$level" in
        INFO)  echo -e "  $msg" ;;
        OK)    echo -e "  \033[0;32m✓\033[0m $msg" ;;
        WARN)  echo -e "  \033[1;33m⚠\033[0m $msg" ;;
        ERROR) echo -e "  \033[0;31m✖\033[0m $msg" >&2 ;;
        SKIP)  echo -e "  \033[0;90m-\033[0m $msg (skipped)" ;;
    esac
}

_support_banner() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Support Bundle"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

_redact_secrets() {
    local input="$1"
    local output="$input"

    for pattern in "${SECRET_PATTERNS[@]}"; do
        output=$(echo "$output" | sed -E "$pattern" 2>/dev/null) || true
    done

    echo "$output"
}

_redact_file() {
    local src="$1"
    local dst="$2"

    if [[ -f "$src" ]]; then
        _redact_secrets "$(cat "$src")" > "$dst"
    fi
}

_safe_cmd() {
    local output_file="$1"
    local description="$2"
    shift 2
    local cmd=("$@")

    echo "# Command: ${cmd[*]}" > "$output_file"
    echo "# Collected: $(date -Iseconds)" >> "$output_file"
    echo "" >> "$output_file"

    if "${cmd[@]}" >> "$output_file" 2>&1; then
        _support_log OK "$description"
        return 0
    else
        echo "# Command failed with exit code: $?" >> "$output_file"
        _support_log WARN "$description (command failed)"
        return 0  # Don't fail bundle for individual command failures
    fi
}

_check_root() {
    if [[ $EUID -ne 0 ]]; then
        _support_log WARN "Running without root - some data may be incomplete"
        return 1
    fi
    return 0
}

# =============================================================================
# COLLECTION FUNCTIONS
# =============================================================================

_collect_version() {
    local bundle_dir="$1"

    echo "# NFTBan Version Information" > "$bundle_dir/version.txt"
    echo "# Collected: $(date -Iseconds)" >> "$bundle_dir/version.txt"
    echo "" >> "$bundle_dir/version.txt"

    # nftban version command
    if command -v nftban &>/dev/null; then
        echo "=== nftban version ===" >> "$bundle_dir/version.txt"
        nftban version >> "$bundle_dir/version.txt" 2>&1 || echo "Command failed" >> "$bundle_dir/version.txt"
        echo "" >> "$bundle_dir/version.txt"
    fi

    # VERSION file
    if [[ -f "$NFTBAN_GIT_REPO/VERSION" ]]; then
        echo "=== VERSION file ===" >> "$bundle_dir/version.txt"
        cat "$NFTBAN_GIT_REPO/VERSION" >> "$bundle_dir/version.txt"
        echo "" >> "$bundle_dir/version.txt"
    fi

    # Git commit
    if [[ -d "$NFTBAN_GIT_REPO/.git" ]]; then
        echo "=== Git Info ===" >> "$bundle_dir/version.txt"
        git -C "$NFTBAN_GIT_REPO" log -1 --format="Commit: %H%nDate: %ci%nMessage: %s" >> "$bundle_dir/version.txt" 2>&1 || true
        echo "" >> "$bundle_dir/version.txt"
    fi

    _support_log OK "Version information"
}

_collect_system() {
    local bundle_dir="$1"
    local sys_dir="$bundle_dir/system"
    mkdir -p "$sys_dir"

    _safe_cmd "$sys_dir/uname.txt" "Kernel info (uname)" uname -a
    _safe_cmd "$sys_dir/os-release.txt" "OS release" cat /etc/os-release
    _safe_cmd "$sys_dir/hostname.txt" "Hostname" hostname -f
    _safe_cmd "$sys_dir/uptime.txt" "Uptime" uptime
    _safe_cmd "$sys_dir/date.txt" "System time" date -Iseconds

    # Memory info
    if [[ -f /proc/meminfo ]]; then
        head -20 /proc/meminfo > "$sys_dir/meminfo.txt" 2>/dev/null
        _support_log OK "Memory info"
    fi

    # SELinux/AppArmor status
    if command -v getenforce &>/dev/null; then
        getenforce > "$sys_dir/selinux.txt" 2>&1
        _support_log OK "SELinux status"
    elif command -v aa-status &>/dev/null; then
        aa-status > "$sys_dir/apparmor.txt" 2>&1 || true
        _support_log OK "AppArmor status"
    fi

    # Container detection
    {
        echo "# Container/VM Detection"
        if [[ -f /.dockerenv ]]; then
            echo "Docker: yes"
        else
            echo "Docker: no"
        fi
        if systemd-detect-virt &>/dev/null; then
            echo "Virtualization: $(systemd-detect-virt 2>/dev/null || echo 'unknown')"
        fi
    } > "$sys_dir/virtualization.txt"
    _support_log OK "Virtualization detection"
}

_collect_nftables() {
    local bundle_dir="$1"
    local nft_dir="$bundle_dir/nftables"
    mkdir -p "$nft_dir"

    if ! command -v nft &>/dev/null; then
        _support_log SKIP "nftables (nft not found)"
        return 0
    fi

    # Full ruleset
    _safe_cmd "$nft_dir/ruleset.txt" "nftables ruleset" nft list ruleset

    # Tables only
    _safe_cmd "$nft_dir/tables.txt" "nftables tables" nft list tables

    # Sets (often contains banned IPs)
    _safe_cmd "$nft_dir/sets.txt" "nftables sets" nft list sets

    # Counters
    _safe_cmd "$nft_dir/counters.txt" "nftables counters" nft list counters
}

_collect_configs() {
    local bundle_dir="$1"
    local conf_dir="$bundle_dir/config"
    mkdir -p "$conf_dir"

    if [[ ! -d "$NFTBAN_CONFIG_DIR" ]]; then
        _support_log SKIP "Config directory ($NFTBAN_CONFIG_DIR not found)"
        return 0
    fi

    # Collect all .conf files with secret redaction
    local count=0
    while IFS= read -r -d '' conf_file; do
        local basename
        basename=$(basename "$conf_file")
        _redact_file "$conf_file" "$conf_dir/$basename"
        count=$((count + 1))
    done < <(find "$NFTBAN_CONFIG_DIR" -maxdepth 2 -name "*.conf" -type f -print0 2>/dev/null)

    if [[ $count -gt 0 ]]; then
        _support_log OK "Config files ($count files, secrets redacted)"
    else
        _support_log SKIP "Config files (none found)"
    fi

    # Collect conf.d directory listing
    if [[ -d "$NFTBAN_CONFIG_DIR/conf.d" ]]; then
        ls -la "$NFTBAN_CONFIG_DIR/conf.d/" > "$conf_dir/conf.d-listing.txt" 2>&1
    fi
}

_collect_logs() {
    local bundle_dir="$1"
    local log_dir="$bundle_dir/logs"
    mkdir -p "$log_dir"

    local since_time
    since_time=$(date -d "$SUPPORT_LOG_HOURS hours ago" '+%Y-%m-%d %H:%M' 2>/dev/null || date '+%Y-%m-%d %H:%M')

    # journalctl logs for nftban
    if command -v journalctl &>/dev/null; then
        journalctl -u nftban -u nftban-webapi -u nftban-feeds \
            --since "$since_time" --no-pager \
            > "$log_dir/journalctl-nftban.txt" 2>&1 || true
        _support_log OK "Systemd journal logs (last ${SUPPORT_LOG_HOURS}h)"
    fi

    # File-based logs
    if [[ -d "$NFTBAN_LOG_DIR" ]]; then
        local log_count=0
        while IFS= read -r -d '' log_file; do
            local basename
            basename=$(basename "$log_file")
            # Only get last 500 lines to keep bundle size reasonable
            tail -500 "$log_file" > "$log_dir/$basename" 2>/dev/null || true
            log_count=$((log_count + 1))
        done < <(find "$NFTBAN_LOG_DIR" -maxdepth 1 -name "*.log" -type f -print0 2>/dev/null)

        if [[ $log_count -gt 0 ]]; then
            _support_log OK "Log files ($log_count files, last 500 lines each)"
        fi
    fi

    # Update log specifically
    if [[ -f "$NFTBAN_LOG_DIR/update.log" ]]; then
        cp "$NFTBAN_LOG_DIR/update.log" "$log_dir/update.log" 2>/dev/null || true
    fi
}

_collect_health() {
    local bundle_dir="$1"

    if ! command -v nftban &>/dev/null; then
        _support_log SKIP "Health check (nftban not in PATH)"
        return 0
    fi

    _safe_cmd "$bundle_dir/health.txt" "Health check" nftban health check
}

_collect_status() {
    local bundle_dir="$1"

    if ! command -v nftban &>/dev/null; then
        _support_log SKIP "Status (nftban not in PATH)"
        return 0
    fi

    _safe_cmd "$bundle_dir/status.txt" "NFTBan status" nftban status
}

_collect_update_info() {
    local bundle_dir="$1"
    local update_dir="$bundle_dir/update"
    mkdir -p "$update_dir"

    if ! command -v nftban &>/dev/null; then
        _support_log SKIP "Update info (nftban not in PATH)"
        return 0
    fi

    # Check for updates
    _safe_cmd "$update_dir/check.txt" "Update check" nftban update --check

    # List backups
    _safe_cmd "$update_dir/backups.txt" "Update backups" nftban update --list

    # Git status in repo
    if [[ -d "$NFTBAN_GIT_REPO/.git" ]]; then
        _safe_cmd "$update_dir/git-status.txt" "Git status" git -C "$NFTBAN_GIT_REPO" status
        _safe_cmd "$update_dir/git-log.txt" "Git log (last 10)" git -C "$NFTBAN_GIT_REPO" log -10 --oneline
    fi
}

_collect_network() {
    local bundle_dir="$1"
    local net_dir="$bundle_dir/network"
    mkdir -p "$net_dir"

    _safe_cmd "$net_dir/ip-addr.txt" "IP addresses" ip addr
    _safe_cmd "$net_dir/ip-route.txt" "Routing table" ip route
    _safe_cmd "$net_dir/ss-tulpn.txt" "Listening ports" ss -tulpn

    # DNS resolution test
    {
        echo "# DNS Resolution Test"
        echo "# Collected: $(date -Iseconds)"
        echo ""
        for host in google.com cloudflare.com; do
            echo "=== $host ==="
            host "$host" 2>&1 || echo "Resolution failed"
            echo ""
        done
    } > "$net_dir/dns-test.txt"
    _support_log OK "DNS resolution test"
}

_collect_services() {
    local bundle_dir="$1"
    local svc_dir="$bundle_dir/services"
    mkdir -p "$svc_dir"

    if ! command -v systemctl &>/dev/null; then
        _support_log SKIP "Systemd services (systemctl not found)"
        return 0
    fi

    # NFTBan-related services
    for svc in nftban nftban-webapi nftban-feeds nftban-sync nftables; do
        if systemctl list-unit-files "${svc}.service" &>/dev/null; then
            systemctl status "$svc" --no-pager > "$svc_dir/${svc}.txt" 2>&1 || true
        fi
    done
    _support_log OK "Systemd service status"

    # Timer status
    systemctl list-timers 'nftban*' --no-pager > "$svc_dir/timers.txt" 2>&1 || true
}

# =============================================================================
# MAIN COMMAND HANDLERS
# =============================================================================

_cmd_support_bundle() {
    local include_network="${1:-false}"

    _support_banner
    echo ""

    # Check root (optional - collection works in user mode too)
    _check_root || true

    # Create temporary bundle directory
    local timestamp
    timestamp=$(date '+%Y%m%d-%H%M%S')
    local bundle_name="nftban-support-$timestamp"
    local bundle_dir
    bundle_dir=$(mktemp -d "/tmp/${bundle_name}.XXXXXX")

    echo "  Collecting diagnostic information..."
    echo ""

    # Always collect these
    _collect_version "$bundle_dir"
    _collect_system "$bundle_dir"
    _collect_nftables "$bundle_dir"
    _collect_configs "$bundle_dir"
    _collect_logs "$bundle_dir"
    _collect_health "$bundle_dir"
    _collect_status "$bundle_dir"
    _collect_update_info "$bundle_dir"
    _collect_services "$bundle_dir"

    # Network info (optional, can be sensitive)
    if [[ "$include_network" == "true" ]]; then
        _collect_network "$bundle_dir"
    else
        _support_log SKIP "Network info (use --network to include)"
    fi

    # Create manifest
    {
        echo "NFTBan Support Bundle"
        echo "====================="
        echo ""
        echo "Generated: $(date -Iseconds)"
        echo "Hostname: $(hostname -f 2>/dev/null || hostname)"
        echo "Bundle ID: $bundle_name"
        echo ""
        echo "Contents:"
        find "$bundle_dir" -type f | sort | while read -r f; do
            echo "  - ${f#$bundle_dir/}"
        done
        echo ""
        echo "IMPORTANT: This bundle may contain sensitive information."
        echo "Review contents before sharing publicly."
    } > "$bundle_dir/MANIFEST.txt"

    # Create tarball
    local output_file="$SUPPORT_OUTPUT_DIR/${bundle_name}.tar.gz"
    if tar -czf "$output_file" -C "$(dirname "$bundle_dir")" "$(basename "$bundle_dir")" 2>/dev/null; then
        # Cleanup temp directory
        rm -rf "$bundle_dir"

        local size
        size=$(du -h "$output_file" | cut -f1)

        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        _support_log OK "Support bundle created"
        echo ""
        echo "  File: $output_file"
        echo "  Size: $size"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  Next steps:"
        echo "    1. Review the bundle for sensitive data"
        echo "    2. Attach to your GitHub issue or support request"
        echo "    3. Include: what you expected vs what happened"
        echo ""

        return 0
    else
        _support_log ERROR "Failed to create tarball"
        rm -rf "$bundle_dir"
        return 1
    fi
}

_cmd_support_quick() {
    # Quick diagnostic output to terminal (no file)
    _support_banner
    echo ""

    echo "=== Version ==="
    if command -v nftban &>/dev/null; then
        nftban version 2>/dev/null || echo "nftban version command failed"
    elif [[ -f "$NFTBAN_GIT_REPO/VERSION" ]]; then
        echo "VERSION file: $(cat "$NFTBAN_GIT_REPO/VERSION")"
    else
        echo "Version unknown"
    fi
    echo ""

    echo "=== System ==="
    uname -a
    echo ""

    echo "=== Health ==="
    if command -v nftban &>/dev/null; then
        nftban health check 2>/dev/null || echo "Health check failed or unavailable"
    else
        echo "nftban not in PATH"
    fi
    echo ""

    echo "=== nftables Status ==="
    if command -v nft &>/dev/null; then
        nft list tables 2>/dev/null || echo "Cannot list tables (permissions?)"
    else
        echo "nft command not found"
    fi
    echo ""

    echo "=== Recent Errors ==="
    if command -v journalctl &>/dev/null; then
        journalctl -u nftban -p err --since "1 hour ago" --no-pager -n 10 2>/dev/null || echo "No recent errors"
    fi
    echo ""
}

_cmd_support_help() {
    cat << 'EOF'
NFTBan Support - Collect diagnostic information for troubleshooting

USAGE:
  nftban support [OPTIONS]
  nftban support-bundle [OPTIONS]

OPTIONS:
  (none)       Create support bundle tarball
  --quick      Quick diagnostics to terminal (no file)
  --network    Include network info (ip addr, routes, ports)
  --output DIR Output directory (default: /tmp)
  --help       Show this help

OUTPUT:
  Creates: /tmp/nftban-support-YYYYMMDD-HHMMSS.tar.gz

  Bundle contents:
    - version.txt         NFTBan and git version
    - system/             OS, kernel, memory info
    - nftables/           Ruleset, tables, sets
    - config/             Config files (secrets redacted)
    - logs/               Recent logs (last 24h)
    - health.txt          Health check output
    - status.txt          NFTBan status
    - update/             Update check and backup list
    - services/           Systemd service status
    - network/            Network info (if --network)
    - MANIFEST.txt        Bundle inventory

SECURITY:
  - Secrets (API keys, tokens, passwords) are automatically redacted
  - Review bundle before sharing publicly
  - Network info excluded by default (may reveal infrastructure)

EXAMPLES:
  nftban support                 # Create full support bundle
  nftban support --quick         # Quick terminal diagnostics
  nftban support --network       # Include network information
  nftban support --output /home  # Save to different directory

WHEN REPORTING ISSUES:
  1. Run: sudo nftban support
  2. Review the bundle for sensitive data
  3. Attach to GitHub issue with:
     - What you expected to happen
     - What actually happened
     - Exact commands run
     - Is the issue persistent or intermittent?

EOF
}

# =============================================================================
# MAIN ENTRY POINT
# =============================================================================

nftban_cmd_support() {
    local include_network="false"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quick|-q)
                _cmd_support_quick
                return $?
                ;;
            --network|-n)
                include_network="true"
                shift
                ;;
            --output|-o)
                if [[ -n "${2:-}" ]]; then
                    SUPPORT_OUTPUT_DIR="$2"
                    shift 2
                else
                    echo "ERROR: --output requires a directory path" >&2
                    return 1
                fi
                ;;
            --help|-h|help)
                _cmd_support_help
                return 0
                ;;
            -*)
                echo "ERROR: Unknown option: $1" >&2
                echo "Run 'nftban support --help' for usage" >&2
                return 1
                ;;
            *)
                shift
                ;;
        esac
    done

    _cmd_support_bundle "$include_network"
}

# Alias for support-bundle
nftban_cmd_support_bundle() {
    nftban_cmd_support "$@"
}

# If sourced, export. If executed directly, run.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_support "$@"
fi
