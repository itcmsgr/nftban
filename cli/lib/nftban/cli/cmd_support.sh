#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.9.4 - Support Bundle Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Collect diagnostic information for troubleshooting
#
# meta:name="cmd_support"
# meta:type="cli"
# meta:header="Support Bundle Command"
# meta:version="1.50.1"
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
# meta:updated_date="2026-03-28"
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

# Bootstrap paths (nftban.conf will make them readonly)
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"
: "${NFTBAN_DATA_DIR:=/var/lib/nftban}"
: "${NFTBAN_LOG_DIR:=${NFTBAN_LOG_DIR}}"
: "${NFTBAN_GIT_REPO:=/opt/nftban}"

# Load main config (sets readonly paths)
source "${NFTBAN_CONFIG_DIR}/nftban.conf" 2>/dev/null || true

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
    mkdir -p "$sys_dir" || return 1

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

    # Journald disk usage (capacity-pressure diagnosis)
    if command -v journalctl &>/dev/null; then
        journalctl --disk-usage > "$sys_dir/journald-disk-usage.txt" 2>&1 || true
        _support_log OK "Journald disk usage"
    fi

    # OOM-kill evidence (kernel ring buffer + journal; read-only, bounded to last 50 matches)
    {
        echo "# OOM-kill / out-of-memory evidence"
        echo "# Collected: $(date -Iseconds)"
        echo ""
        echo "=== journalctl -k (oom matches, last 50) ==="
        if command -v journalctl &>/dev/null; then
            journalctl -k --no-pager 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process|oom_reaper' | tail -50 || echo "(none)"
        else
            echo "(journalctl not available)"
        fi
        echo ""
        echo "=== dmesg (oom matches, last 50) ==="
        if command -v dmesg &>/dev/null; then
            dmesg 2>/dev/null | grep -iE 'out of memory|oom-kill|killed process|oom_reaper' | tail -50 || echo "(none or insufficient privilege)"
        else
            echo "(dmesg not available)"
        fi
    } > "$sys_dir/oom-evidence.txt"
    _support_log OK "OOM-kill evidence"
}

_collect_nftables() {
    local bundle_dir="$1"
    local nft_dir="$bundle_dir/nftables"
    mkdir -p "$nft_dir" || return 1

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
    mkdir -p "$conf_dir" || return 1

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
    mkdir -p "$log_dir" || return 1

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
    mkdir -p "$update_dir" || return 1

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
    mkdir -p "$net_dir" || return 1

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
    mkdir -p "$svc_dir" || return 1

    if ! command -v systemctl &>/dev/null; then
        _support_log SKIP "Systemd services (systemctl not found)"
        return 0
    fi

    # All NFTBan/nftband units (dynamic — services, sockets, timers; not a fixed list).
    # Covers nftband.service/.socket, nftban-soak, nftban-botscan, etc.
    local units
    units=$(systemctl list-unit-files 'nftban*' 'nftband*' 'nftables.service' --no-legend 2>/dev/null \
            | awk '{print $1}' | grep -E '\.(service|socket|timer)$' | sort -u)
    local nunits=0
    for unit in $units; do
        systemctl status "$unit" --no-pager > "$svc_dir/${unit}.txt" 2>&1 || true
        nunits=$((nunits + 1))
    done
    _support_log OK "Systemd unit status ($nunits nftban/nftband units)"

    # Failed units (whole-system) — DEGRADED diagnosis
    systemctl --failed --all --no-pager > "$svc_dir/failed-units.txt" 2>&1 || true
    _support_log OK "Failed units"

    # Per-unit Result / restart / OOM properties (actionable failure signal)
    {
        echo "# Per-unit properties (Result / ExecMainStatus / NRestarts / OOM)"
        echo "# Collected: $(date -Iseconds)"
        for unit in $units; do
            echo ""
            echo "=== $unit ==="
            systemctl show "$unit" \
                -p ActiveState -p SubState -p Result -p ExecMainStatus -p ExecMainCode \
                -p NRestarts -p OOMPolicy -p MemoryCurrent -p MemoryMax -p ActiveEnterTimestamp \
                2>/dev/null || echo "(show failed)"
        done
    } > "$svc_dir/unit-properties.txt"
    _support_log OK "Unit Result/OOM properties"

    # Timer status
    systemctl list-timers 'nftban*' 'nftband*' --all --no-pager > "$svc_dir/timers.txt" 2>&1 || true
}

_collect_install_info() {
    local bundle_dir="$1"
    local install_dir="$bundle_dir/install"
    mkdir -p "$install_dir" || return 1

    # Detect install type
    {
        echo "# NFTBan Installation Info"
        echo "# Collected: $(date -Iseconds)"
        echo ""

        # Install type detection
        echo "=== Install Type ==="
        if [[ -f ${NFTBAN_CONFIG_DIR}/.install_type ]]; then
            echo "Install type file: $(cat ${NFTBAN_CONFIG_DIR}/.install_type)"
        elif rpm -q nftban-core &>/dev/null 2>&1; then
            echo "Install type: rpm"
            echo ""
            echo "=== RPM Package Info ==="
            rpm -qi nftban-core 2>&1 || true
        elif dpkg -l nftban 2>/dev/null | grep -q '^ii'; then
            echo "Install type: deb"
            echo ""
            echo "=== DEB Package Info ==="
            dpkg -l nftban 2>&1 || true
            dpkg -s nftban 2>&1 || true
        elif [[ -d "${NFTBAN_GIT_REPO:-/opt/nftban}/.git" ]]; then
            echo "Install type: git"
            echo "Git repo: ${NFTBAN_GIT_REPO:-/opt/nftban}"
        else
            echo "Install type: unknown"
        fi
        echo ""

        # PATH info
        echo "=== PATH ==="
        echo "PATH=$PATH"
        echo ""
        echo "which nftban: $(which nftban 2>&1 || echo 'not found')"
        echo "which nftban-core: $(which nftban-core 2>&1 || echo 'not found')"
        echo "which nft: $(which nft 2>&1 || echo 'not found')"
        echo ""

    } > "$install_dir/install-type.txt"
    _support_log OK "Install type detection"

    # Machine-written install/upgrade state (INSTALL_STATE / INSTALL_VERSION /
    # PHASE_REACHED / FAILURE_REASON / REBUILD_EXIT_CODE) — DEGRADED/upgrade diagnosis.
    local state_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/install_state"
    if [[ -f "$state_file" ]]; then
        {
            echo "# install_state (machine-written; do not edit)"
            echo "# Source: $state_file"
            echo "# Collected: $(date -Iseconds)"
            echo ""
            cat "$state_file"
        } > "$install_dir/install_state.txt" 2>&1
        _support_log OK "install_state"
    else
        _support_log SKIP "install_state (not present: $state_file)"
    fi
}

_collect_binaries() {
    local bundle_dir="$1"
    local bin_dir="$bundle_dir/binaries"
    mkdir -p "$bin_dir" || return 1

    {
        echo "# NFTBan Binary Info"
        echo "# Collected: $(date -Iseconds)"
        echo ""

        # Binary locations
        echo "=== Binary Locations ==="
        for bin_path in /usr/sbin/nftban /usr/lib/nftban/bin/nftban-core \
                        /usr/lib/nftban/bin/nftband; do
            if [[ -f "$bin_path" ]]; then
                echo "$bin_path: $(ls -la "$bin_path" 2>&1)"
            else
                echo "$bin_path: NOT FOUND"
            fi
        done
        echo ""

        # Go binary versions
        echo "=== Go Binary Versions ==="
        for binary in nftban-core nftband; do
            local bin_path="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/$binary"

            if [[ -x "$bin_path" ]]; then
                echo "$binary: $("$bin_path" --version 2>&1 | head -1 || echo 'version failed')"
            else
                echo "$binary: not executable or not found"
            fi
        done
        echo ""

        # Capabilities
        echo "=== Binary Capabilities ==="
        if command -v getcap &>/dev/null; then
            for bin_path in /usr/lib/nftban/bin/nftban-core /usr/lib/nftban/bin/nftband; do
                if [[ -f "$bin_path" ]]; then
                    echo "$bin_path: $(getcap "$bin_path" 2>&1 || echo 'no caps')"
                fi
            done
        else
            echo "getcap not available"
        fi
        echo ""

        # File permissions on critical files
        echo "=== Critical File Permissions ==="
        for path in /usr/sbin/nftban ${NFTBAN_CONFIG_DIR}/nftban.conf \
                    /usr/lib/nftban/lib/nft_schema.sh ${NFTBAN_DATA_DIR}; do
            if [[ -e "$path" ]]; then
                ls -la "$path" 2>&1
            else
                echo "$path: NOT FOUND"
            fi
        done

    } > "$bin_dir/binaries.txt"
    _support_log OK "Binary information"
}

_collect_distro_config() {
    local bundle_dir="$1"
    local distro_dir="$bundle_dir/distro"
    mkdir -p "$distro_dir" || return 1

    {
        echo "# Distro Configuration"
        echo "# Collected: $(date -Iseconds)"
        echo ""

        # OS detection
        echo "=== OS Detection ==="
        if [[ -f /etc/os-release ]]; then
            source /etc/os-release || true
            echo "ID: ${ID:-unknown}"
            echo "VERSION_ID: ${VERSION_ID:-unknown}"
            echo "PRETTY_NAME: ${PRETTY_NAME:-unknown}"
        fi
        echo ""

        # Distro config file
        echo "=== Distro Config Files ==="
        ls -la "${NFTBAN_CONFIG_DIR}/distros/" 2>&1 || echo "${NFTBAN_CONFIG_DIR}/distros/ not found"
        echo ""

        # Active distro config
        local distro_id="${ID:-unknown}"
        local distro_version="${VERSION_ID:-unknown}"
        local expected_config="${NFTBAN_CONFIG_DIR}/distros/${distro_id}-${distro_version}.conf"
        echo "=== Expected Config: $expected_config ==="
        if [[ -f "$expected_config" ]]; then
            echo "EXISTS: yes"
            echo "Content preview:"
            head -30 "$expected_config"
        else
            echo "EXISTS: no"
            echo "Available configs:"
            ls ${NFTBAN_CONFIG_DIR}/distros/*.conf 2>/dev/null || echo "none"
        fi

    } > "$distro_dir/distro-config.txt"
    _support_log OK "Distro configuration"
}

_collect_fhs_structure() {
    local bundle_dir="$1"
    local fhs_dir="$bundle_dir/fhs"
    mkdir -p "$fhs_dir" || return 1

    {
        echo "# FHS Directory Structure"
        echo "# Collected: $(date -Iseconds)"
        echo ""

        # Key directories
        echo "=== Key Directories ==="
        for dir in ${NFTBAN_CONFIG_DIR} /usr/lib/nftban ${NFTBAN_DATA_DIR} ${NFTBAN_LOG_DIR} \
                   "${NFTBAN_RUN_DIR:-/run/nftban}" /usr/share/nftban; do
            if [[ -d "$dir" ]]; then
                echo "$dir: $(ls -ld "$dir" 2>&1)"
            else
                echo "$dir: NOT FOUND"
            fi
        done
        echo ""

        # Detailed listing
        echo "=== /etc/nftban structure ==="
        find ${NFTBAN_CONFIG_DIR} -type f -o -type d 2>/dev/null | head -50 || echo "not accessible"
        echo ""

        echo "=== /var/lib/nftban structure ==="
        find ${NFTBAN_DATA_DIR} -type f -o -type d 2>/dev/null | head -50 || echo "not accessible"
        echo ""

        # Disk space
        echo "=== Disk Space ==="
        df -h ${NFTBAN_CONFIG_DIR} ${NFTBAN_DATA_DIR} ${NFTBAN_LOG_DIR} 2>/dev/null || df -h / 2>/dev/null
        echo ""

        # Immutable flags
        echo "=== Immutable Flags (chattr) ==="
        if command -v lsattr &>/dev/null; then
            lsattr /usr/lib/nftban/lib/*.sh 2>/dev/null | grep -E '^....i' || echo "No immutable files found"
        else
            echo "lsattr not available"
        fi

    } > "$fhs_dir/fhs-structure.txt"
    _support_log OK "FHS directory structure"
}

_collect_whitelist_blacklist() {
    local bundle_dir="$1"
    local lists_dir="$bundle_dir/lists"
    mkdir -p "$lists_dir" || return 1

    # Whitelist files
    if [[ -d ${NFTBAN_CONFIG_DIR}/whitelist.d ]]; then
        {
            echo "# Whitelist Files"
            echo "# Collected: $(date -Iseconds)"
            echo ""
            for wl in ${NFTBAN_CONFIG_DIR}/whitelist.d/*.conf; do
                if [[ -f "$wl" ]]; then
                    echo "=== $(basename "$wl") ==="
                    cat "$wl"
                    echo ""
                fi
            done
        } > "$lists_dir/whitelists.txt"
        _support_log OK "Whitelist files"
    else
        _support_log SKIP "Whitelist files (directory not found)"
    fi

    # Blacklist summary (don't dump full lists - could be huge)
    {
        echo "# Blacklist Summary"
        echo "# Collected: $(date -Iseconds)"
        echo ""
        if [[ -d ${NFTBAN_DATA_DIR}/blacklists ]]; then
            echo "=== Blacklist Files ==="
            ls -la ${NFTBAN_DATA_DIR}/blacklists/ 2>&1
            echo ""
            echo "=== Entry Counts ==="
            for bl in ${NFTBAN_DATA_DIR}/blacklists/*.txt; do
                if [[ -f "$bl" ]]; then
                    echo "$(basename "$bl"): $(wc -l < "$bl") entries"
                fi
            done 2>/dev/null || echo "No blacklist files"
        else
            echo "Blacklist directory not found"
        fi
    } > "$lists_dir/blacklist-summary.txt"
    _support_log OK "Blacklist summary"
}

_collect_geoip() {
    local bundle_dir="$1"
    local geoip_dir="$bundle_dir/geoip"
    mkdir -p "$geoip_dir" || return 1

    {
        echo "# GeoIP Database Info"
        echo "# Collected: $(date -Iseconds)"
        echo ""

        local db_path="${NFTBAN_DATA_DIR}/geoip/dbip-country-lite.mmdb"
        echo "=== Database File ==="
        if [[ -f "$db_path" ]]; then
            echo "Path: $db_path"
            echo "Size: $(ls -lh "$db_path" | awk '{print $5}')"
            echo "Modified: $(stat -c '%y' "$db_path" 2>/dev/null || stat -f '%Sm' "$db_path" 2>/dev/null)"

            # Calculate age
            local db_mtime file_age_days
            db_mtime=$(stat -c '%Y' "$db_path" 2>/dev/null || stat -f '%m' "$db_path" 2>/dev/null)
            file_age_days=$(( ($(date +%s) - db_mtime) / 86400 ))
            echo "Age: ${file_age_days} days"

            if [[ $file_age_days -gt 30 ]]; then
                echo "WARNING: Database is older than 30 days!"
            fi
        else
            echo "Database NOT FOUND at $db_path"
        fi
        echo ""

        # GeoIP config
        echo "=== GeoIP Configuration ==="
        if [[ -f ${NFTBAN_CONFIG_DIR}/conf.d/geoip/main.conf ]]; then
            grep -v '^#' ${NFTBAN_CONFIG_DIR}/conf.d/geoip/main.conf | grep -v '^$' || echo "empty config"
        else
            echo "Config not found"
        fi

    } > "$geoip_dir/geoip-info.txt"
    _support_log OK "GeoIP database info"
}

_collect_daemon_status() {
    local bundle_dir="$1"
    local daemon_dir="$bundle_dir/daemon"
    mkdir -p "$daemon_dir" || return 1

    {
        echo "# NFTBan Daemon Status"
        echo "# Collected: $(date -Iseconds)"
        echo ""

        # Socket status
        echo "=== nftband.socket ==="
        systemctl status nftband.socket --no-pager 2>&1 || echo "socket not found"
        echo ""

        # Daemon status
        echo "=== nftband.service ==="
        systemctl status nftband.service --no-pager 2>&1 || echo "service not found"
        echo ""

        # Socket file
        echo "=== Socket File ==="
        ls -la "${NFTBAN_RUN_DIR:-/run/nftban}/nftband.sock" 2>&1 || echo "socket file not found"
        echo ""

        # Test daemon connectivity
        echo "=== Daemon Connectivity Test ==="
        if [[ -S "${NFTBAN_RUN_DIR:-/run/nftban}/nftband.sock" ]]; then
            if command -v socat &>/dev/null; then
                echo '{"action":"ping"}' | timeout 5 socat - "UNIX-CONNECT:${NFTBAN_RUN_DIR:-/run/nftban}/nftband.sock" 2>&1 || echo "ping failed"
            else
                echo "socat not available for connectivity test"
            fi
        else
            echo "Socket not available"
        fi

    } > "$daemon_dir/daemon-status.txt"
    _support_log OK "Daemon status"
}

_collect_recent_activity() {
    local bundle_dir="$1"
    local activity_dir="$bundle_dir/activity"
    mkdir -p "$activity_dir" || return 1

    # Recent bans from journal
    {
        echo "# Recent Ban Activity"
        echo "# Collected: $(date -Iseconds)"
        echo ""

        echo "=== Last 20 Ban Events ==="
        if command -v journalctl &>/dev/null; then
            journalctl -u nftband -u nftban --no-pager --since "24 hours ago" 2>/dev/null | \
                grep -iE '(ban|block|reject|drop)' | tail -20 || echo "No ban events found"
        fi
        echo ""

        echo "=== Last 10 Errors ==="
        if command -v journalctl &>/dev/null; then
            journalctl -u nftband -u nftban -p err --no-pager --since "24 hours ago" -n 10 2>&1 || echo "No errors"
        fi

    } > "$activity_dir/recent-bans.txt"
    _support_log OK "Recent ban activity"

    # Feed status
    {
        echo "# Feed Status"
        echo "# Collected: $(date -Iseconds)"
        echo ""

        echo "=== Feed Configuration ==="
        if [[ -f ${NFTBAN_CONFIG_DIR}/conf.d/feeds.conf ]]; then
            grep -E '^FEED_.*_ENABLED=' ${NFTBAN_CONFIG_DIR}/conf.d/feeds.conf 2>/dev/null || echo "No feeds configured"
        else
            echo "feeds.conf not found"
        fi
        echo ""

        echo "=== Feed Files ==="
        if [[ -d ${NFTBAN_DATA_DIR}/feeds ]]; then
            ls -la ${NFTBAN_DATA_DIR}/feeds/ 2>&1
        else
            echo "Feed directory not found"
        fi

    } > "$activity_dir/feed-status.txt"
    _support_log OK "Feed status"
}

_collect_mail_status() {
    local bundle_dir="$1"
    local mail_dir="$bundle_dir/mail"
    mkdir -p "$mail_dir" || return 1

    {
        echo "# Mail System Status"
        echo "# Collected: $(date -Iseconds)"
        echo ""

        echo "=== Mail Configuration ==="
        if [[ -f ${NFTBAN_CONFIG_DIR}/conf.d/mail.conf ]]; then
            # Redact passwords but show config structure
            grep -v -E '(PASS|SECRET|TOKEN)' ${NFTBAN_CONFIG_DIR}/conf.d/mail.conf 2>/dev/null || echo "Could not read"
        else
            echo "mail.conf not found"
        fi
        echo ""

        echo "=== Mail System Detection ==="
        for mta in postfix sendmail exim4 msmtp mailx; do
            if command -v "$mta" &>/dev/null; then
                echo "$mta: $(which "$mta")"
            fi
        done
        echo ""

        echo "=== Mail Queue ==="
        if command -v mailq &>/dev/null; then
            mailq 2>&1 | head -20 || echo "mailq failed"
        else
            echo "mailq not available"
        fi
        echo ""

        echo "=== SMTP Ports ==="
        ss -tlnp 2>/dev/null | grep -E ':25|:465|:587' || echo "No SMTP ports listening locally"

    } > "$mail_dir/mail-status.txt"
    _support_log OK "Mail system status"
}

_collect_module_status() {
    local bundle_dir="$1"
    local mod_dir="$bundle_dir/modules"
    mkdir -p "$mod_dir" || return 1

    # Collect individual module status
    if command -v nftban &>/dev/null; then
        # DDoS module
        {
            echo "# DDoS Module Status"
            echo "# Collected: $(date -Iseconds)"
            echo ""
            nftban ddos status 2>&1 || echo "Command failed"
        } > "$mod_dir/ddos.txt"

        # Portscan module
        {
            echo "# Portscan Module Status"
            echo "# Collected: $(date -Iseconds)"
            echo ""
            nftban portscan status 2>&1 || echo "Command failed"
        } > "$mod_dir/portscan.txt"

        # GeoBan module
        {
            echo "# GeoBan Module Status"
            echo "# Collected: $(date -Iseconds)"
            echo ""
            nftban geoban status 2>&1 || echo "Command failed"
        } > "$mod_dir/geoban.txt"

        # Feeds module
        {
            echo "# Feeds Module Status"
            echo "# Collected: $(date -Iseconds)"
            echo ""
            nftban feeds status 2>&1 || echo "Command failed"
        } > "$mod_dir/feeds.txt"

        # RBL module
        {
            echo "# RBL Module Status"
            echo "# Collected: $(date -Iseconds)"
            echo ""
            nftban rbl status 2>&1 || echo "Command failed"
            echo ""
            echo "=== RBL Check Results (cached) ==="
            if [[ -d /var/cache/nftban/rbl ]]; then
                ls -la /var/cache/nftban/rbl/ 2>&1 || true
                for f in /var/cache/nftban/rbl/*.json; do
                    [[ -f "$f" ]] && echo "$(basename "$f"): $(cat "$f" 2>/dev/null | head -5)" || true
                done
            fi
        } > "$mod_dir/rbl.txt"

        # Login monitor
        {
            echo "# Login Monitor Status"
            echo "# Collected: $(date -Iseconds)"
            echo ""
            nftban login status 2>&1 || echo "Command failed"
        } > "$mod_dir/login.txt"

        _support_log OK "Module status (6 modules)"
    else
        _support_log SKIP "Module status (nftban not in PATH)"
    fi
}

_collect_stats_summary() {
    local bundle_dir="$1"

    if ! command -v nftban &>/dev/null; then
        _support_log SKIP "Stats summary (nftban not in PATH)"
        return 0
    fi

    {
        echo "# Statistics Summary"
        echo "# Collected: $(date -Iseconds)"
        echo ""
        nftban stats 2>&1 || echo "Stats command failed"
        echo ""
        echo "=== Top IPs ==="
        nftban stats top --limit 10 2>&1 || echo "Top IPs failed"
    } > "$bundle_dir/stats-summary.txt"
    _support_log OK "Statistics summary"
}

_collect_disk_usage() {
    local bundle_dir="$1"

    {
        echo "# NFTBan Disk Usage"
        echo "# Collected: $(date -Iseconds)"
        echo ""

        echo "=== Directory Sizes ==="
        for dir in ${NFTBAN_CONFIG_DIR} ${NFTBAN_DATA_DIR} ${NFTBAN_LOG_DIR} /var/cache/nftban /usr/lib/nftban; do
            if [[ -d "$dir" ]]; then
                echo "$dir: $(du -sh "$dir" 2>/dev/null | cut -f1)"
            fi
        done
        echo ""

        echo "=== Large Files (>10MB) ==="
        find ${NFTBAN_DATA_DIR} ${NFTBAN_LOG_DIR} /var/cache/nftban -type f -size +10M 2>/dev/null | \
            while read -r f; do
                echo "$f: $(du -h "$f" 2>/dev/null | cut -f1)"
            done || echo "None found"
        echo ""

        echo "=== Disk Space Available ==="
        df -h / /var 2>/dev/null | head -5

    } > "$bundle_dir/disk-usage.txt"
    _support_log OK "Disk usage"
}

_collect_cron_jobs() {
    local bundle_dir="$1"

    {
        echo "# NFTBan Cron Jobs"
        echo "# Collected: $(date -Iseconds)"
        echo ""

        echo "=== /etc/cron.d/nftban* ==="
        for f in /etc/cron.d/nftban*; do
            if [[ -f "$f" ]]; then
                echo "--- $(basename "$f") ---"
                cat "$f"
                echo ""
            fi
        done 2>/dev/null || echo "No nftban cron files"

        echo "=== Root Crontab (nftban entries) ==="
        crontab -l 2>/dev/null | grep -i nftban || echo "No nftban entries in root crontab"
        echo ""

        echo "=== Systemd Timers ==="
        systemctl list-timers 'nftban*' --no-pager 2>&1 || echo "No timers or systemctl not available"

    } > "$bundle_dir/cron-jobs.txt"
    _support_log OK "Cron jobs and timers"
}

_collect_recent_errors() {
    local bundle_dir="$1"

    {
        echo "# Recent Errors and Warnings"
        echo "# Collected: $(date -Iseconds)"
        echo ""

        echo "=== Journal Errors (last 24h) ==="
        if command -v journalctl &>/dev/null; then
            journalctl -u 'nftban*' --since "24 hours ago" --no-pager -p err 2>&1 | tail -100 || echo "No errors"
        fi
        echo ""

        echo "=== Log File Errors ==="
        if [[ -d ${NFTBAN_LOG_DIR} ]]; then
            grep -h -i -E '(error|fail|critical|warn)' ${NFTBAN_LOG_DIR}/*.log 2>/dev/null | tail -50 || echo "No errors in log files"
        fi

    } > "$bundle_dir/recent-errors.txt"
    _support_log OK "Recent errors"
}

_collect_ssh_port() {
    local bundle_dir="$1"
    local ssh_dir="$bundle_dir/ssh"
    mkdir -p "$ssh_dir" || return 1

    {
        echo "# SSH Port Diagnostics"
        echo "# Collected: $(date -Iseconds)"
        echo ""

        # sshd_config port
        echo "=== sshd_config ==="
        if [[ -f /etc/ssh/sshd_config ]]; then
            grep -Ei '^[[:space:]]*(Port|ListenAddress)' /etc/ssh/sshd_config 2>/dev/null || echo "No explicit Port/ListenAddress (default 22)"
            # Include drop-in configs
            for inc in /etc/ssh/sshd_config.d/*.conf; do
                [[ -f "$inc" ]] || continue
                local port_line
                port_line=$(grep -Ei '^[[:space:]]*Port' "$inc" 2>/dev/null) || true
                [[ -n "$port_line" ]] && echo "  $inc: $port_line" || true
            done
        else
            echo "/etc/ssh/sshd_config not found"
        fi
        echo ""

        # State file
        echo "=== NFTBan SSH State ==="
        local state_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/ssh_port"
        if [[ -f "$state_file" ]]; then
            echo "State file: $(cat "$state_file")"
        else
            echo "No state file ($state_file)"
        fi
        echo ""

        # Live listening port
        echo "=== Live SSH Listening ==="
        ss -tlnp 2>/dev/null | grep -E 'sshd|:22\b' || echo "No sshd listeners found"
        echo ""

        # nftables tcp_ports_in set (IPv4 + IPv6)
        echo "=== nft tcp_ports_in (SSH) ==="
        if command -v nft &>/dev/null; then
            echo "# IPv4:"
            nft list set ip nftban tcp_ports_in 2>/dev/null || echo "Set not found"
            echo ""
            echo "# IPv6:"
            nft list set ip6 nftban tcp_ports_in 2>/dev/null || echo "Set not found"
        fi
        echo ""

        # nftables.conf SSH port
        echo "=== /etc/nftban/nftables.conf SSH ==="
        if [[ -f /etc/nftban/nftables.conf ]]; then
            grep -n 'ssh\|22\|__SSH_PORT__' /etc/nftban/nftables.conf 2>/dev/null | head -5 || echo "No SSH references"
        fi

    } > "$ssh_dir/ssh-port.txt"
    _support_log OK "SSH port diagnostics"
}

_collect_firewall_conflicts() {
    local bundle_dir="$1"
    local conflict_dir="$bundle_dir/conflicts"
    mkdir -p "$conflict_dir" || return 1

    {
        echo "# Firewall Conflict Detection"
        echo "# Collected: $(date -Iseconds)"
        echo ""

        # Ghost table scan
        echo "=== Ghost Tables (iptables-nft artifacts) ==="
        if command -v nft &>/dev/null; then
            local all_tables
            all_tables=$(nft list tables 2>/dev/null) || all_tables=""
            local ghost_candidates=("ip filter" "ip6 filter" "ip nat" "ip6 nat" "ip mangle" "ip6 mangle" "ip security" "ip6 security" "inet firewalld" "inet filter")
            for gt in "${ghost_candidates[@]}"; do
                if echo "$all_tables" | grep -qF "table $gt"; then
                    echo "  FOUND: $gt"
                else
                    echo "  clean: $gt"
                fi
            done
        else
            echo "nft not available"
        fi
        echo ""

        # CSF detection
        echo "=== CSF (ConfigServer Firewall) ==="
        if [[ -f /etc/csf/csf.conf ]]; then
            echo "CSF installed: /etc/csf/csf.conf"
            grep -E '^TESTING\s*=' /etc/csf/csf.conf 2>/dev/null || true
            grep -E '^TCP_IN\s*=' /etc/csf/csf.conf 2>/dev/null || true
            systemctl is-active csf 2>/dev/null && echo "CSF service: active" || echo "CSF service: inactive/not found"
        else
            echo "CSF not installed"
        fi
        echo ""

        # firewalld detection
        echo "=== firewalld ==="
        if command -v firewall-cmd &>/dev/null; then
            echo "firewalld installed"
            systemctl is-active firewalld 2>/dev/null && echo "firewalld: active" || echo "firewalld: inactive"
        else
            echo "firewalld not installed"
        fi
        echo ""

        # iptables-nft detection
        echo "=== iptables backend ==="
        if command -v iptables &>/dev/null; then
            echo "iptables version: $(iptables --version 2>&1)"
            if iptables --version 2>&1 | grep -q 'nf_tables'; then
                echo "Backend: nf_tables (iptables-nft)"
            else
                echo "Backend: legacy"
            fi
        else
            echo "iptables not installed"
        fi

    } > "$conflict_dir/firewall-conflicts.txt"
    _support_log OK "Firewall conflict detection"
}

_collect_config_divergence() {
    local bundle_dir="$1"
    local div_dir="$bundle_dir/config-divergence"
    mkdir -p "$div_dir" || return 1

    {
        echo "# Config Divergence Detection"
        echo "# Collected: $(date -Iseconds)"
        echo ""

        # .rpmnew files
        echo "=== RPM .rpmnew Files ==="
        local rpmnew_count=0
        while IFS= read -r -d '' f; do
            echo "  FOUND: $f ($(stat -c '%y' "$f" 2>/dev/null || echo 'unknown date'))"
            rpmnew_count=$((rpmnew_count + 1))
        done < <(find /etc/nftban -name '*.rpmnew' -print0 2>/dev/null)
        [[ $rpmnew_count -eq 0 ]] && echo "  None found"
        echo ""

        # .dpkg-dist files
        echo "=== DEB .dpkg-dist Files ==="
        local dpkg_count=0
        while IFS= read -r -d '' f; do
            echo "  FOUND: $f ($(stat -c '%y' "$f" 2>/dev/null || echo 'unknown date'))"
            dpkg_count=$((dpkg_count + 1))
        done < <(find /etc/nftban -name '*.dpkg-dist' -print0 2>/dev/null)
        [[ $dpkg_count -eq 0 ]] && echo "  None found"
        echo ""

        # Placeholder check in live config
        echo "=== Placeholder Check (nftables.conf) ==="
        if [[ -f /etc/nftban/nftables.conf ]]; then
            local placeholders
            placeholders=$(grep -cE '__SSH_PORT__|__CT_LIMIT_SSH__|__CT_LIMIT_HTTP__|__CT_LIMIT_MAIL__' /etc/nftban/nftables.conf 2>/dev/null) || placeholders=0
            if [[ "$placeholders" -gt 0 ]]; then
                echo "  CRITICAL: $placeholders raw placeholders found — BOOT UNSAFE"
                grep -n '__SSH_PORT__\|__CT_LIMIT_' /etc/nftban/nftables.conf 2>/dev/null
            else
                echo "  OK: No raw placeholders — boot safe"
            fi
        else
            echo "  /etc/nftban/nftables.conf not found"
        fi
        echo ""

        # Template availability
        echo "=== Template File ==="
        local tpl="/usr/lib/nftban/templates/nftables.conf.tpl"
        if [[ -f "$tpl" ]]; then
            echo "  Present: $tpl ($(stat -c '%y' "$tpl" 2>/dev/null || echo 'unknown date'))"
        else
            echo "  Missing: $tpl (pre-v1.50.0 install)"
        fi

    } > "$div_dir/config-divergence.txt"
    _support_log OK "Config divergence detection"
}

_collect_feeds_nft_mismatch() {
    local bundle_dir="$1"
    local feeds_dir="$bundle_dir/feeds-mismatch"
    mkdir -p "$feeds_dir" || return 1

    {
        echo "# Feeds vs NFT Set Mismatch Check"
        echo "# Collected: $(date -Iseconds)"
        echo ""

        # Feed files on disk
        echo "=== Feed Files on Disk ==="
        local disk_total=0
        local data_feeds="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds"
        if [[ -d "$data_feeds" ]]; then
            for feed_file in "$data_feeds"/*.txt; do
                [[ -f "$feed_file" ]] || continue
                local count
                count=$(grep -cE '^[0-9]' "$feed_file" 2>/dev/null) || count=0
                echo "  $(basename "$feed_file"): $count IPs"
                disk_total=$((disk_total + count))
            done
            echo "  TOTAL on disk: $disk_total IPs"
        else
            echo "  Feed directory not found ($data_feeds)"
        fi
        echo ""

        # NFT set counts
        echo "=== NFT Set Element Counts ==="
        if command -v nft &>/dev/null; then
            for setname in blacklist_ipv4 blacklist_ipv6; do
                local nft_family="ip"
                [[ "$setname" == *_ipv6 ]] && nft_family="ip6"
                local nft_count
                nft_count=$(nft -j list set "$nft_family" nftban "$setname" 2>/dev/null | grep -o '"elem"' | wc -l) || nft_count=0
                # Fallback: count elements line by line
                if [[ "$nft_count" -eq 0 ]]; then
                    nft_count=$(nft list set "$nft_family" nftban "$setname" 2>/dev/null | grep -cE '^\s+[0-9]') || nft_count=0
                fi
                echo "  $setname: $nft_count elements"
            done
        else
            echo "  nft not available"
        fi
        echo ""

        # Mismatch verdict
        echo "=== Mismatch Verdict ==="
        if [[ "$disk_total" -gt 0 ]]; then
            local nft_v4
            nft_v4=$(nft list set ip nftban blacklist_ipv4 2>/dev/null | grep -cE '^\s+[0-9]') || nft_v4=0
            if [[ "$nft_v4" -eq 0 ]]; then
                echo "  WARNING: $disk_total IPs on disk but 0 in nft — feeds not loaded"
                echo "  Fix: nftban feeds update && nftban sync"
            else
                echo "  OK: disk=$disk_total nft=$nft_v4"
            fi
        else
            echo "  No feed IPs on disk — nothing to compare"
        fi

    } > "$feeds_dir/feeds-nft-mismatch.txt"
    _support_log OK "Feeds vs NFT mismatch check"
}

_collect_panel_detection() {
    local bundle_dir="$1"
    local panel_dir="$bundle_dir/panel"
    mkdir -p "$panel_dir" || return 1

    {
        echo "# Control Panel Detection"
        echo "# Collected: $(date -Iseconds)"
        echo ""

        # DirectAdmin
        echo "=== DirectAdmin ==="
        if [[ -d /usr/local/directadmin ]]; then
            echo "Installed: /usr/local/directadmin"
            /usr/local/directadmin/directadmin v 2>/dev/null || echo "Version unknown"
            # BFM status
            if [[ -f /usr/local/directadmin/conf/directadmin.conf ]]; then
                grep -i 'brute_force' /usr/local/directadmin/conf/directadmin.conf 2>/dev/null | head -5 || echo "No BFM config"
            fi
        else
            echo "Not installed"
        fi
        echo ""

        # cPanel
        echo "=== cPanel ==="
        if [[ -f /usr/local/cpanel/version ]]; then
            echo "Installed: $(cat /usr/local/cpanel/version 2>/dev/null)"
            # cPHulk status
            if command -v whmapi1 &>/dev/null; then
                whmapi1 configureservice service=cphulkd 2>/dev/null | grep -E 'enabled|running' | head -3 || echo "cPHulk status unknown"
            fi
        else
            echo "Not installed"
        fi
        echo ""

        # Plesk
        echo "=== Plesk ==="
        if [[ -f /usr/local/psa/version ]]; then
            echo "Installed: $(cat /usr/local/psa/version 2>/dev/null)"
            # Plesk Firewall extension
            if [[ -d /usr/local/psa/admin/plib/modules/firewall ]]; then
                echo "Plesk Firewall extension: installed"
            else
                echo "Plesk Firewall extension: not installed"
            fi
        else
            echo "Not installed"
        fi
        echo ""

        # CSF on panels
        echo "=== CSF with Panel ==="
        if [[ -f /etc/csf/csf.conf ]]; then
            echo "CSF installed"
            grep -E '^TESTING\s*=' /etc/csf/csf.conf 2>/dev/null || true
            if [[ -f /usr/local/cpanel/version ]]; then
                echo "Panel: cPanel (CSF+cPanel combo)"
            elif [[ -d /usr/local/directadmin ]]; then
                echo "Panel: DirectAdmin (CSF+DA combo)"
            fi
        fi

    } > "$panel_dir/panel-detection.txt"
    _support_log OK "Control panel detection"
}

_collect_boot_safety() {
    local bundle_dir="$1"
    local boot_dir="$bundle_dir/boot-safety"
    mkdir -p "$boot_dir" || return 1

    {
        echo "# Boot Safety Check"
        echo "# Collected: $(date -Iseconds)"
        echo ""

        local nftables_conf="/etc/nftban/nftables.conf"
        local template="/usr/lib/nftban/templates/nftables.conf.tpl"

        # Config file exists
        echo "=== Config File Status ==="
        if [[ -f "$nftables_conf" ]]; then
            echo "Config: $nftables_conf ($(stat -c '%s bytes, %y' "$nftables_conf" 2>/dev/null))"
        else
            echo "CRITICAL: $nftables_conf NOT FOUND — no firewall on boot"
        fi
        echo ""

        # Placeholder scan
        echo "=== Placeholder Scan ==="
        if [[ -f "$nftables_conf" ]]; then
            local ph_count
            ph_count=$(grep -cE '__[A-Z_]+__' "$nftables_conf" 2>/dev/null) || ph_count=0
            if [[ "$ph_count" -gt 0 ]]; then
                echo "CRITICAL: $ph_count raw placeholders — nftables will fail on boot"
                grep -n '__[A-Z_]+__' "$nftables_conf" 2>/dev/null
            else
                echo "OK: No raw placeholders"
            fi
        fi
        echo ""

        # nft validation
        echo "=== Config Validation ==="
        if command -v nft &>/dev/null && [[ -f "$nftables_conf" ]]; then
            if nft -c -f "$nftables_conf" 2>&1; then
                echo "PASS: nft -c -f validates successfully"
            else
                echo "FAIL: nft -c -f validation failed"
            fi
        else
            echo "Cannot validate (nft or config missing)"
        fi
        echo ""

        # nftables.service include chain
        echo "=== nftables.service Include Chain ==="
        if [[ -f /etc/sysconfig/nftables.conf ]]; then
            echo "Source: /etc/sysconfig/nftables.conf"
            grep -n 'include.*nftban' /etc/sysconfig/nftables.conf 2>/dev/null || echo "No nftban include found"
        elif [[ -f /etc/nftables.conf ]]; then
            echo "Source: /etc/nftables.conf"
            grep -n 'include.*nftban' /etc/nftables.conf 2>/dev/null || echo "No nftban include found"
        fi
        echo ""

        # Template file
        echo "=== Template ==="
        if [[ -f "$template" ]]; then
            echo "Template: $template (present)"
        else
            echo "Template: $template (MISSING — pre-v1.50.0?)"
        fi

    } > "$boot_dir/boot-safety.txt"
    _support_log OK "Boot safety check"
}

_collect_ipc_test() {
    local bundle_dir="$1"
    local ipc_dir="$bundle_dir/ipc"
    mkdir -p "$ipc_dir" || return 1

    {
        echo "# NFTBand IPC Connectivity Test"
        echo "# Collected: $(date -Iseconds)"
        echo ""

        local sock="${NFTBAN_RUN_DIR:-/run/nftban}/nftband.sock"

        echo "=== Socket Status ==="
        if [[ -S "$sock" ]]; then
            echo "Socket: $sock (exists)"
            ls -la "$sock" 2>&1
        else
            echo "Socket: $sock (NOT FOUND)"
            echo "nftband may not be running"
        fi
        echo ""

        echo "=== systemd Socket Activation ==="
        systemctl is-active nftband.socket 2>/dev/null && echo "nftband.socket: active" || echo "nftband.socket: inactive/missing"
        systemctl is-active nftband.service 2>/dev/null && echo "nftband.service: active" || echo "nftband.service: inactive"
        echo ""

        echo "=== IPC Quick Sync Test ==="
        if command -v nftban &>/dev/null; then
            if timeout 10s nftban sync --quick 2>&1; then
                echo "IPC sync: OK"
            else
                echo "IPC sync: FAILED (exit $?)"
            fi
        else
            echo "nftban not in PATH"
        fi

    } > "$ipc_dir/ipc-test.txt"
    _support_log OK "IPC connectivity test"
}

_collect_postinst_history() {
    local bundle_dir="$1"
    local hist_dir="$bundle_dir/install-history"
    mkdir -p "$hist_dir" || return 1

    {
        echo "# Package Install/Upgrade History"
        echo "# Collected: $(date -Iseconds)"
        echo ""

        echo "=== RPM History ==="
        if command -v rpm &>/dev/null; then
            rpm -qa --last 2>/dev/null | grep -i nftban | head -20 || echo "No nftban RPMs in history"
        else
            echo "rpm not available"
        fi
        echo ""

        echo "=== DEB History ==="
        if [[ -f /var/log/dpkg.log ]]; then
            grep -i nftban /var/log/dpkg.log 2>/dev/null | tail -20 || echo "No nftban entries in dpkg.log"
        elif [[ -f /var/log/dpkg.log.1 ]]; then
            grep -i nftban /var/log/dpkg.log.1 2>/dev/null | tail -20 || echo "No nftban entries"
        else
            echo "dpkg.log not available"
        fi
        echo ""

        echo "=== DNF/YUM Transaction History ==="
        if command -v dnf &>/dev/null; then
            dnf history list 2>/dev/null | head -20 || echo "dnf history unavailable"
        elif command -v yum &>/dev/null; then
            yum history list 2>/dev/null | head -20 || echo "yum history unavailable"
        fi
        echo ""

        echo "=== Install State File ==="
        if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/.install_type" ]]; then
            echo "Type: $(cat "${NFTBAN_CONFIG_DIR:-/etc/nftban}/.install_type" 2>/dev/null)"
        fi
        if [[ -f "${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/install_date" ]]; then
            echo "Install date: $(cat "${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/install_date" 2>/dev/null)"
        fi

    } > "$hist_dir/install-history.txt"
    _support_log OK "Package install history"
}

_collect_botguard_status() {
    local bundle_dir="$1"
    local mod_dir="$bundle_dir/modules"
    mkdir -p "$mod_dir" || return 1

    {
        echo "# BotGuard Module Status"
        echo "# Collected: $(date -Iseconds)"
        echo ""
        if command -v nftban &>/dev/null; then
            nftban botguard status 2>&1 || echo "Command failed or module not available"
        else
            echo "nftban not in PATH"
        fi

        # v1.191 8B inc6B2 — bounded, read-only TEMPORARY decision-cache diagnostics. Aggregate
        # only (no full-cache dump, no IP list); degrade-safe; never fails the support bundle.
        echo ""
        if ! declare -f nftban_botguard_explain_diag_aggregate >/dev/null 2>&1; then
            # shellcheck source=/dev/null
            [[ -f "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" ]] && source "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" 2>/dev/null || true
            # shellcheck source=/dev/null
            [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_botguard_explain.sh" ]] && source "${NFTBAN_LIB_DIR}/lib/nftban_botguard_explain.sh" 2>/dev/null || true
        fi
        if declare -f nftban_botguard_explain_diag_aggregate >/dev/null 2>&1; then
            nftban_botguard_explain_diag_aggregate 2>/dev/null || echo "BotGuard temporary cache diagnostics: unavailable"
        else
            echo "BotGuard temporary cache diagnostics: unavailable (explain client not loaded; durable nft-set checks remain authoritative)"
        fi
    } > "$mod_dir/botguard.txt"
    _support_log OK "BotGuard module status"
}

_collect_suricata_status() {
    local bundle_dir="$1"
    local mod_dir="$bundle_dir/modules"
    mkdir -p "$mod_dir" || return 1

    {
        echo "# Suricata Module Status"
        echo "# Collected: $(date -Iseconds)"
        echo ""
        if command -v nftban &>/dev/null; then
            nftban suricata status 2>&1 || echo "Command failed or module not available"
            echo ""
            echo "=== Suricata Service ==="
            systemctl is-active suricata 2>/dev/null && echo "suricata: active" || echo "suricata: inactive/not installed"
            echo ""
            echo "=== Suricata Logs (last 10 alerts) ==="
            if [[ -f /var/log/suricata/fast.log ]]; then
                tail -10 /var/log/suricata/fast.log 2>/dev/null || echo "Cannot read fast.log"
            elif [[ -f /var/log/suricata/eve.json ]]; then
                tail -5 /var/log/suricata/eve.json 2>/dev/null || echo "Cannot read eve.json"
            else
                echo "No Suricata log files found"
            fi
        else
            echo "nftban not in PATH"
        fi
    } > "$mod_dir/suricata.txt"
    _support_log OK "Suricata module status"
}

# =============================================================================
# MAIN COMMAND HANDLERS
# =============================================================================

_cmd_support_bundle() {
    local include_network="${1:-false}"
    local email_recipient="${2:-}"

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

    # Always collect these - Core diagnostics
    _collect_version "$bundle_dir"
    _collect_system "$bundle_dir"
    _collect_install_info "$bundle_dir"
    _collect_binaries "$bundle_dir"
    _collect_distro_config "$bundle_dir"
    _collect_fhs_structure "$bundle_dir"
    _collect_nftables "$bundle_dir"
    _collect_configs "$bundle_dir"
    _collect_whitelist_blacklist "$bundle_dir"
    _collect_geoip "$bundle_dir"
    _collect_logs "$bundle_dir"
    _collect_health "$bundle_dir"
    _collect_status "$bundle_dir"
    _collect_daemon_status "$bundle_dir"
    _collect_recent_activity "$bundle_dir"
    _collect_update_info "$bundle_dir"
    _collect_services "$bundle_dir"

    # Extended diagnostics (v1.9.4)
    _collect_mail_status "$bundle_dir"
    _collect_module_status "$bundle_dir"
    _collect_stats_summary "$bundle_dir"
    _collect_disk_usage "$bundle_dir"
    _collect_cron_jobs "$bundle_dir"
    _collect_recent_errors "$bundle_dir"

    # v1.50.1: Deploy safety + operational diagnostics
    _collect_ssh_port "$bundle_dir"
    _collect_firewall_conflicts "$bundle_dir"
    _collect_config_divergence "$bundle_dir"
    _collect_feeds_nft_mismatch "$bundle_dir"
    _collect_panel_detection "$bundle_dir"
    _collect_boot_safety "$bundle_dir"
    _collect_ipc_test "$bundle_dir"
    _collect_postinst_history "$bundle_dir"
    _collect_botguard_status "$bundle_dir"
    _collect_suricata_status "$bundle_dir"

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

        # Email support bundle if requested
        if [[ -n "$email_recipient" ]]; then
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Sending bundle via email..."
            echo ""

            # Load mail module if available
            local mail_lib="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_mail.sh"
            if [[ -f "$mail_lib" ]]; then
                # shellcheck source=/dev/null
                source "$mail_lib" 2>/dev/null || true
            fi

            # Prepare email body
            local hostname_val
            hostname_val="$(hostname -f 2>/dev/null || hostname)"
            local email_body
            email_body=$(cat <<EOF
NFTBan Support Bundle

Server: $hostname_val
Bundle: $bundle_name
Size: $size
Generated: $(date -Iseconds)

This diagnostic bundle was generated by 'nftban support --email'.

Contents include:
- System and version information
- Configuration files (secrets redacted)
- Health check results
- Module status (DDoS, portscan, geoban, feeds, RBL, login)
- Recent logs and errors
- nftables ruleset
- Service/timer status

IMPORTANT: Review the attached bundle before forwarding.
It may contain sensitive infrastructure information.

---
NFTBan v${NFTBAN_VERSION:-unknown}
https://nftban.com
EOF
)
            # Try to send via nftban_mail_send with attachment
            if declare -f nftban_mail_send &>/dev/null; then
                # nftban_mail_send supports attachments
                if nftban_mail_send "$email_body" "$email_recipient" "$output_file" 2>/dev/null; then
                    _support_log OK "Bundle sent to: $email_recipient"
                else
                    _support_log WARN "Email failed - bundle saved locally"
                    echo ""
                    echo "  Transfer manually using:"
                    echo "    scp $output_file user@remote:/path/"
                    echo "    # or"
                    echo "    cat $output_file | base64 > bundle.b64"
                fi
            else
                # Fallback: try mutt or mail with attachment
                if command -v mutt &>/dev/null; then
                    echo "$email_body" | mutt -s "[NFTBan] Support Bundle - $hostname_val" \
                        -a "$output_file" -- "$email_recipient" 2>/dev/null && \
                        _support_log OK "Bundle sent via mutt to: $email_recipient" || \
                        _support_log WARN "mutt failed - bundle saved locally"
                elif command -v mail &>/dev/null; then
                    # Some mail implementations support -A for attachments
                    echo "$email_body" | mail -s "[NFTBan] Support Bundle - $hostname_val" \
                        -A "$output_file" "$email_recipient" 2>/dev/null && \
                        _support_log OK "Bundle sent via mail to: $email_recipient" || \
                        _support_log WARN "mail attachment failed - bundle saved locally"
                else
                    _support_log WARN "No mail client available - bundle saved locally"
                    echo ""
                    echo "  Transfer manually using:"
                    echo "    scp $output_file user@remote:/path/"
                fi
            fi
            echo ""
        fi

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
  (none)         Create support bundle tarball
  --quick        Quick diagnostics to terminal (no file)
  --network      Include network info (ip addr, routes, ports)
  --output DIR   Output directory (default: /tmp)
  --email ADDR   Send bundle via email to specified address
  --email        Send bundle to default NFTBAN_MAIL_RECIPIENT
  --help         Show this help

OUTPUT:
  Creates: /tmp/nftban-support-YYYYMMDD-HHMMSS.tar.gz

  Bundle contents:
    - version.txt         NFTBan and git version
    - system/             OS, kernel, memory, SELinux/AppArmor
    - install/            Install type (git/rpm/deb), PATH, which
    - binaries/           Binary locations, versions, capabilities
    - distro/             Distro detection, config file status
    - fhs/                Directory structure, permissions, disk space
    - nftables/           Ruleset, tables, sets, counters
    - config/             Config files (secrets redacted)
    - lists/              Whitelist files, blacklist summary
    - geoip/              Database status, age, config
    - logs/               Recent logs (last 24h)
    - health.txt          Health check output
    - status.txt          NFTBan status
    - daemon/             nftband socket/service, connectivity
    - activity/           Recent bans, feed status
    - update/             Update check and backup list
    - services/           Systemd service/timer status
    - network/            Network info (if --network)
    - modules/            Module status (ddos, portscan, geoban, feeds, rbl, login,
                          botguard, suricata)
    - mail/               Mail system status and configuration
    - stats-summary.txt   Current statistics and top IPs
    - disk-usage.txt      NFTBan directory sizes
    - cron-jobs.txt       Scheduled tasks and timers
    - recent-errors.txt   Recent errors from logs
    - ssh/                SSH port detection (sshd_config, ss, nft set)
    - conflicts/          Ghost tables, CSF, firewalld, iptables-nft backend
    - config-divergence/  .rpmnew/.dpkg-dist files, placeholder detection
    - feeds-mismatch/     Feed files on disk vs NFT set element counts
    - panel/              Control panel detection (DA, cPanel, Plesk, CSF)
    - boot-safety/        Placeholder scan, nft -c -f validation, include chain
    - ipc/                nftband socket + IPC sync test
    - install-history/    RPM/DEB install and upgrade history
    - MANIFEST.txt        Bundle inventory

SECURITY:
  - Secrets (API keys, tokens, passwords) are automatically redacted
  - Review bundle before sharing publicly
  - Network info excluded by default (may reveal infrastructure)

EXAMPLES:
  nftban support                       # Create full support bundle
  nftban support --quick               # Quick terminal diagnostics
  nftban support --network             # Include network information
  nftban support --output /home        # Save to different directory
  nftban support --email admin@x.com   # Create bundle and email it
  nftban support --email               # Email to default recipient

WHEN REPORTING ISSUES:
  1. Run: nftban support
  2. Review the bundle for sensitive data
  3. Transfer/email the bundle:
     - Use --email to send directly
     - Or: scp /tmp/nftban-support-*.tar.gz user@remote:/path/
  4. Include with your report:
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
    local email_recipient=""

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
            --email|-e)
                # Check if next arg is an email address or use default
                if [[ -n "${2:-}" && ! "${2:-}" =~ ^- ]]; then
                    email_recipient="$2"
                    shift 2
                else
                    # Use default from config
                    email_recipient="${NFTBAN_MAIL_RECIPIENT:-}"
                    if [[ -z "$email_recipient" ]]; then
                        echo "ERROR: --email requires an address or NFTBAN_MAIL_RECIPIENT must be set" >&2
                        return 1
                    fi
                    shift
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

    _cmd_support_bundle "$include_network" "$email_recipient"
}

# Alias for support-bundle
nftban_cmd_support_bundle() {
    nftban_cmd_support "$@"
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_support
export -f nftban_cmd_support_bundle

# If executed directly, run.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_support "$@"
fi
