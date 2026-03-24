#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0 - Suricata IDS CLI Command - Tools Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Profile, Scan, Services, and EVE commands for Suricata
#
# meta:name="cmd_suricata_tools"
# meta:type="cli"
# meta:header="Suricata Tools Module"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Profile, Scan, Services, and EVE commands for Suricata"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="conditional"
#
# Loaded by: cmd_suricata.sh (inherits strict mode)
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_CMD_SURICATA_TOOLS_LOADED:-}" ]] && return 0
_CMD_SURICATA_TOOLS_LOADED="true"

# =============================================================================
# COMMAND: profile
# =============================================================================

cmd_suricata_profile() {
    local action="${1:-help}"
    shift || true

    case "$action" in
        detect)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  🔍 Detecting Optimal Suricata Profile"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend for detection
            if ! nftban-core suricata profile-detect; then
                echo "✗ Profile detection failed"
                return 1
            fi

            echo ""
            ;;

        set|apply)
            local profile_name="${1:-}"

            if [[ -z "$profile_name" ]]; then
                echo "ERROR: Profile name required" >&2
                echo ""
                echo "Usage: nftban suricata profile set <PROFILE>"
                echo ""
                echo "Available profiles:"
                echo "  minimal   - 2 cores / 2 GB RAM (low resource usage)"
                echo "  standard  - 4 cores / 4-8 GB RAM (balanced, default)"
                echo "  maximum   - 8+ cores / 8-16 GB RAM (deep inspection)"
                echo ""
                return 1
            fi

            _check_root "profile set" || return 1

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ⚙️  Applying Suricata Profile: $profile_name"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend to apply profile
            if ! nftban-core suricata profile-apply "$profile_name"; then
                echo ""
                echo "✗ Failed to apply profile"
                return 1
            fi

            echo ""
            echo "  ✓ Profile applied successfully"
            echo ""

            # Restart Suricata if running
            if _suricata_is_running; then
                echo "  → Restarting Suricata to load new configuration..."
                if systemctl restart "$SURICATA_SERVICE" 2>/dev/null; then
                    sleep 2
                    if _suricata_is_running; then
                        echo "  ✓ Suricata restarted successfully"
                    else
                        echo "  ✗ Suricata failed to restart - check logs"
                        return 1
                    fi
                else
                    echo "  ⚠  Could not restart Suricata (not running?)"
                fi
            else
                echo "  ℹ  Suricata is not running - start it to use new profile"
            fi

            echo ""
            echo "✅ Profile configuration complete"
            echo ""
            ;;

        show|current|status)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  📊 Current Suricata Profile"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend to show current profile
            if ! nftban-core suricata profile-show; then
                echo "✗ Failed to determine current profile"
                return 1
            fi

            echo ""
            ;;

        validate|check)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ✅ Validating Suricata Profile Configuration"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend to validate profile
            if nftban-core suricata profile-validate; then
                echo ""
                echo "✅ Profile configuration is valid"
                echo ""
            else
                echo ""
                echo "✗ Profile validation failed"
                echo ""
                echo "Fix this by running:"
                echo "  nftban suricata profile detect"
                echo "  nftban suricata profile set <PROFILE>"
                echo ""
                return 1
            fi
            ;;

        help|*)
            cat << 'EOF'

🛡️  Suricata Profile Management

USAGE:
    nftban suricata profile <command>

COMMANDS:
    detect      Auto-detect optimal profile based on CPU/RAM
    set         Apply a specific profile (minimal/standard/maximum)
    show        Display current active profile
    validate    Validate profile configuration
    help        Show this help message

PROFILES:
    minimal     2 cores / 2 GB RAM
                - Ring size: 50k
                - Flow timeout: 60s
                - HTTP body: disabled
                - Detection: low
                - Use case: Tiny VPS, stability first

    standard    4 cores / 4-8 GB RAM (DEFAULT)
                - Ring size: 100k
                - Flow timeout: 120s
                - HTTP body: 30KB
                - Detection: medium
                - Use case: Most servers, balanced

    maximum     8+ cores / 8-16 GB RAM
                - Ring size: 300k
                - Flow timeout: 300s
                - HTTP body: 30KB (full)
                - Detection: high
                - Use case: High traffic, deep inspection

EXAMPLES:
    # Auto-detect and apply optimal profile:
    nftban suricata profile detect
    nftban suricata profile set standard

    # Check current profile:
    nftban suricata profile show

    # Validate configuration:
    nftban suricata profile validate

NOTES:
    - Profile changes require Suricata restart to take effect
    - Profiles are YAML templates in /etc/nftban/suricata/profiles/
    - Active config: /etc/suricata/suricata.yaml (symlink)
    - Profile setting stored in: /etc/nftban/suricata/config/profile.conf

EOF
            ;;
    esac
}

# =============================================================================
# COMMAND: scan
# =============================================================================

cmd_suricata_scan() {
    local action="${1:-quick}"

    case "$action" in
        quick)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  🔍 Scanning localhost for services..."
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata scan; then
                echo "✗ Service scan failed"
                return 1
            fi

            echo ""
            ;;

        deep)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  🔬 Deep scanning localhost (protocol probes)..."
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata scan-deep; then
                echo "✗ Deep scan failed"
                return 1
            fi

            echo ""
            ;;

        help|*)
            cat << 'EOF'

🔍 Suricata Service Scanner

USAGE:
    nftban suricata scan [quick|deep]

COMMANDS:
    quick       Quick port scan (default)
    deep        Deep scan with protocol probes
    help        Show this help message

DESCRIPTION:
    Scans localhost for running services and auto-configures
    Suricata to enable only relevant rule categories.

    This reduces CPU/RAM usage by 50-70% by loading only
    the rules needed for your actual services.

EXAMPLES:
    # Quick scan
    nftban suricata scan

    # Deep scan with protocol detection
    nftban suricata scan deep

WHAT IT DOES:
    1. Scans common ports (HTTP, HTTPS, SSH, MySQL, DNS, etc.)
    2. Detects running services
    3. Maps services to Suricata rule categories
    4. Generates /etc/nftban/suricata/config/suricata.auto.conf
    5. Merges with local.conf to create effective.conf

NEXT STEPS:
    After scanning, generate the rules list:
      nftban suricata rules generate

    Then restart Suricata:
      systemctl restart suricata

EOF
            ;;
    esac
}

# =============================================================================
# COMMAND: services
# =============================================================================

cmd_suricata_services() {
    local action="${1:-list}"

    case "$action" in
        list)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  📋 Suricata Service Configuration"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Show current config files
            local config_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}/suricata/config"

            if [[ -f "$config_dir/suricata.auto.conf" ]]; then
                echo "Auto-detected configuration:"
                echo "  (from last scan)"
                echo ""
                cat "$config_dir/suricata.auto.conf" | grep -v "^#" | grep -v "^$"
                echo ""
            else
                echo "⚠  No auto-detected configuration found"
                echo "   Run: nftban suricata scan"
                echo ""
            fi

            if [[ -f "$config_dir/suricata.local.conf" ]]; then
                echo "Manual overrides:"
                echo "  (from local.conf)"
                echo ""
                cat "$config_dir/suricata.local.conf" | grep -v "^#" | grep -v "^$"
                echo ""
            fi

            ;;

        help|*)
            cat << 'EOF'

📋 Suricata Service Management

USAGE:
    nftban suricata services <command>

COMMANDS:
    list        Show current service configuration
    help        Show this help message

CONFIGURATION FILES:
    /etc/nftban/suricata/config/
    ├── suricata.auto.conf       (auto-detected, generated)
    ├── suricata.local.conf      (manual overrides, user-edited)
    └── suricata.effective.conf  (merged result, generated)

WORKFLOW:
    1. Scan:     nftban suricata scan
    2. Override: Edit /etc/nftban/suricata/config/suricata.local.conf
    3. Generate: nftban suricata rules generate
    4. Restart:  systemctl restart suricata

EOF
            ;;
    esac
}

# =============================================================================
# EVE HELPER FUNCTIONS
# =============================================================================

# Helper: Load EVE path from config
_eve_get_path() {
    # Try central config variable first
    if [[ -n "${NFTBAN_SURICATA_EVE_LOG:-}" ]]; then
        echo "$NFTBAN_SURICATA_EVE_LOG"
        return
    fi

    # Try loading from config files
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"
    local local_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local"

    if [[ -f "$local_conf" ]]; then
        local val
        val=$(grep -E "^NFTBAN_SURICATA_EVE_LOG=" "$local_conf" 2>/dev/null | cut -d'"' -f2 || true)
        [[ -n "$val" ]] && { echo "$val"; return; }
    fi

    if [[ -f "$config_file" ]]; then
        local val
        val=$(grep -E "^NFTBAN_SURICATA_EVE_LOG=" "$config_file" 2>/dev/null | cut -d'"' -f2 || true)
        [[ -n "$val" ]] && { echo "$val"; return; }
    fi

    # Default path
    echo "${NFTBAN_LOG_DIR:-/var/log/nftban}/suricata/eve-alerts.json"
}

# Helper: Format bytes to human readable
_eve_format_bytes() {
    local bytes="$1"
    if command -v numfmt &>/dev/null; then
        numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B"
    else
        if [[ $bytes -ge 1073741824 ]]; then
            echo "$(( bytes / 1073741824 ))GB"
        elif [[ $bytes -ge 1048576 ]]; then
            echo "$(( bytes / 1048576 ))MB"
        elif [[ $bytes -ge 1024 ]]; then
            echo "$(( bytes / 1024 ))KB"
        else
            echo "${bytes}B"
        fi
    fi
}

# Helper: Format time difference to human readable
_eve_format_age() {
    local seconds="$1"
    if [[ $seconds -lt 60 ]]; then
        echo "${seconds}s ago"
    elif [[ $seconds -lt 3600 ]]; then
        echo "$(( seconds / 60 ))m $(( seconds % 60 ))s ago"
    elif [[ $seconds -lt 86400 ]]; then
        echo "$(( seconds / 3600 ))h $(( (seconds % 3600) / 60 ))m ago"
    else
        echo "$(( seconds / 86400 ))d $(( (seconds % 86400) / 3600 ))h ago"
    fi
}

# =============================================================================
# COMMAND: eve check
# =============================================================================

cmd_suricata_eve_check() {
    # Color definitions (use globals if available, fallback to local)
    local C_RESET="${NFTBAN_COLOR_RESET:-\033[0m}"
    local C_BOLD="${NFTBAN_COLOR_BOLD:-\033[1m}"
    local C_RED="${NFTBAN_COLOR_RED:-\033[31m}"
    local C_GREEN="${NFTBAN_COLOR_GREEN:-\033[32m}"
    local C_YELLOW="${NFTBAN_COLOR_YELLOW:-\033[33m}"
    local C_CYAN="${NFTBAN_COLOR_CYAN:-\033[36m}"
    local C_DIM="${NFTBAN_COLOR_DIM:-\033[2m}"

    # Disable colors if not a terminal
    if [[ ! -t 1 ]] || [[ "${NO_COLOR:-}" == "1" ]]; then
        C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_DIM=""
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📋 Suricata EVE JSON Health Check"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    local eve_path
    eve_path=$(_eve_get_path)

    # -------------------------------------------------------------------------
    # Section 1: File Information
    # -------------------------------------------------------------------------
    echo -e "${C_BOLD}EVE File Information${C_RESET}"
    echo "─────────────────────────────────────────────────────────"
    echo -e "  Path:          ${C_CYAN}${eve_path}${C_RESET}"

    # Check file exists
    if [[ ! -e "$eve_path" ]]; then
        echo -e "  Status:        ${C_RED}✗ FILE NOT FOUND${C_RESET}"
        echo ""
        echo -e "${C_YELLOW}Troubleshooting:${C_RESET}"
        echo "  1. Ensure Suricata is installed: nftban suricata status"
        echo "  2. Check if Suricata is running: systemctl status suricata"
        echo "  3. Verify EVE output in Suricata config"
        echo "  4. Check log directory exists: ls -la ${NFTBAN_LOG_DIR}/suricata/"
        echo ""
        return 1
    fi

    # Check readable
    if [[ ! -r "$eve_path" ]]; then
        echo -e "  Status:        ${C_RED}✗ NOT READABLE${C_RESET} (permission denied)"
        echo ""
        echo -e "${C_YELLOW}Fix:${C_RESET}"
        echo "  sudo chmod 640 $eve_path"
        echo "  sudo chown suricata:nftban $eve_path"
        echo ""
        return 1
    fi

    echo -e "  Status:        ${C_GREEN}✓ EXISTS & READABLE${C_RESET}"

    # File stats
    local file_size file_mtime now age_seconds
    # Use -L to follow symlinks (eve-alerts.json -> eve.json)
    file_size=$(stat -L -c %s "$eve_path" 2>/dev/null || echo "0")
    file_mtime=$(stat -L -c %Y "$eve_path" 2>/dev/null || echo "0")
    now=$(date +%s)
    age_seconds=$(( now - file_mtime ))

    local mtime_human
    mtime_human=$(date -d "@$file_mtime" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "$file_mtime" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")

    echo -e "  Size:          ${C_BOLD}$(_eve_format_bytes "$file_size")${C_RESET}"
    echo -e "  Last Modified: ${mtime_human} ($(_eve_format_age "$age_seconds"))"

    # Staleness warning
    if [[ $age_seconds -gt 600 ]]; then
        echo -e "  ${C_YELLOW}⚠ File not updated in 10+ minutes - Suricata may be stalled${C_RESET}"
    elif [[ $age_seconds -gt 300 ]]; then
        echo -e "  ${C_YELLOW}⊘ File not updated in 5+ minutes${C_RESET}"
    else
        echo -e "  Activity:      ${C_GREEN}✓ Recently updated${C_RESET}"
    fi

    echo ""

    # -------------------------------------------------------------------------
    # Section 2: JSON Validity Check
    # -------------------------------------------------------------------------
    echo -e "${C_BOLD}JSON Validity${C_RESET}"
    echo "─────────────────────────────────────────────────────────"

    if [[ $file_size -eq 0 ]]; then
        echo -e "  Status:        ${C_YELLOW}⊘ FILE IS EMPTY${C_RESET}"
        echo "  (No events logged yet - this is normal for fresh installs)"
        echo ""
    else
        # Sample last 100 lines and check JSON validity
        local sample_lines=100
        local valid_count=0
        local invalid_count=0
        local total_sampled=0

        if command -v jq &>/dev/null; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                ((total_sampled++)) || true
                if echo "$line" | jq -e . &>/dev/null; then
                    ((valid_count++)) || true
                else
                    ((invalid_count++)) || true
                fi
            done < <(tail -n "$sample_lines" "$eve_path" 2>/dev/null)

            if [[ $total_sampled -eq 0 ]]; then
                echo -e "  Status:        ${C_YELLOW}⊘ NO DATA TO SAMPLE${C_RESET}"
            elif [[ $invalid_count -eq 0 ]]; then
                echo -e "  Status:        ${C_GREEN}✓ VALID${C_RESET} (${valid_count}/${total_sampled} lines OK)"
            elif [[ $invalid_count -lt 5 ]]; then
                echo -e "  Status:        ${C_YELLOW}⊘ MOSTLY VALID${C_RESET} (${valid_count} valid, ${invalid_count} invalid)"
                echo -e "  ${C_DIM}(Minor corruption may occur during log rotation)${C_RESET}"
            else
                echo -e "  Status:        ${C_RED}✗ INVALID JSON${C_RESET} (${invalid_count}/${total_sampled} lines corrupted)"
                echo -e "  ${C_YELLOW}Consider rotating or recreating the log file${C_RESET}"
            fi
        else
            # Fallback: basic JSON structure check without jq
            local first_char
            first_char=$(tail -n 1 "$eve_path" 2>/dev/null | head -c 1)
            if [[ "$first_char" == "{" ]]; then
                echo -e "  Status:        ${C_GREEN}✓ APPEARS VALID${C_RESET} (jq not installed for full check)"
            else
                echo -e "  Status:        ${C_YELLOW}⊘ UNKNOWN${C_RESET} (install jq for validation)"
            fi
        fi
        echo ""
    fi

    # -------------------------------------------------------------------------
    # Section 3: Alert Counts by Time Window
    # -------------------------------------------------------------------------
    echo -e "${C_BOLD}Alert Statistics${C_RESET}"
    echo "─────────────────────────────────────────────────────────"

    if [[ $file_size -eq 0 ]]; then
        echo "  No alerts to analyze (file is empty)"
        echo ""
    elif ! command -v jq &>/dev/null; then
        echo -e "  ${C_YELLOW}⊘ jq not installed - cannot analyze alerts${C_RESET}"
        echo "  Install: sudo dnf install jq  OR  sudo apt install jq"
        echo ""
    else
        local now_epoch
        now_epoch=$(date +%s)
        local one_min_ago=$((now_epoch - 60))
        local five_min_ago=$((now_epoch - 300))
        local one_hour_ago=$((now_epoch - 3600))

        # Read recent portion of file (last 10000 lines for performance)
        local alerts_1m=0
        local alerts_5m=0
        local alerts_1h=0
        local total_alerts=0

        # Use a single pass through the file for efficiency
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue

            # Parse timestamp and check if it's an alert
            local ts event_type
            if ! ts=$(echo "$line" | jq -r '.timestamp // empty' 2>/dev/null); then
                continue
            fi
            event_type=$(echo "$line" | jq -r '.event_type // empty' 2>/dev/null)

            [[ "$event_type" != "alert" ]] && continue
            ((total_alerts++)) || true

            # Convert timestamp to epoch
            local event_epoch
            # Handle ISO 8601 format: 2024-01-15T10:30:00.123456+0000
            event_epoch=$(date -d "${ts}" +%s 2>/dev/null || echo "0")
            [[ "$event_epoch" == "0" ]] && continue

            if [[ $event_epoch -ge $one_min_ago ]]; then
                ((alerts_1m++)) || true
            fi
            if [[ $event_epoch -ge $five_min_ago ]]; then
                ((alerts_5m++)) || true
            fi
            if [[ $event_epoch -ge $one_hour_ago ]]; then
                ((alerts_1h++)) || true
            fi
        done < <(tail -n 10000 "$eve_path" 2>/dev/null)

        # Display with color coding
        local rate_1m rate_5m rate_1h
        rate_1m=$(echo "scale=1; $alerts_1m / 1" | bc 2>/dev/null || echo "$alerts_1m")
        rate_5m=$(echo "scale=1; $alerts_5m / 5" | bc 2>/dev/null || echo "$(( alerts_5m / 5 ))")
        rate_1h=$(echo "scale=1; $alerts_1h / 60" | bc 2>/dev/null || echo "$(( alerts_1h / 60 ))")

        # Color based on alert rate
        local c_1m="$C_GREEN" c_5m="$C_GREEN" c_1h="$C_GREEN"
        [[ $alerts_1m -gt 10 ]] && c_1m="$C_YELLOW"
        [[ $alerts_1m -gt 50 ]] && c_1m="$C_RED"
        [[ $alerts_5m -gt 50 ]] && c_5m="$C_YELLOW"
        [[ $alerts_5m -gt 200 ]] && c_5m="$C_RED"
        [[ $alerts_1h -gt 500 ]] && c_1h="$C_YELLOW"
        [[ $alerts_1h -gt 2000 ]] && c_1h="$C_RED"

        printf "  %-16s ${c_1m}%6d${C_RESET}  (%s/min)\n" "Last 1 minute:" "$alerts_1m" "$rate_1m"
        printf "  %-16s ${c_5m}%6d${C_RESET}  (%s/min avg)\n" "Last 5 minutes:" "$alerts_5m" "$rate_5m"
        printf "  %-16s ${c_1h}%6d${C_RESET}  (%s/min avg)\n" "Last 1 hour:" "$alerts_1h" "$rate_1h"

        if [[ $total_alerts -eq 0 ]]; then
            echo ""
            echo -e "  ${C_DIM}No alerts found in sampled data${C_RESET}"
        fi
        echo ""

        # -------------------------------------------------------------------------
        # Section 4: Top Signatures (Last 10 Minutes)
        # -------------------------------------------------------------------------
        echo -e "${C_BOLD}Top Signatures (Last 10 Minutes)${C_RESET}"
        echo "─────────────────────────────────────────────────────────"

        local ten_min_ago=$((now_epoch - 600))
        local sig_data

        # Extract signatures from last 10 minutes
        sig_data=$(tail -n 10000 "$eve_path" 2>/dev/null | \
            jq -r --argjson cutoff "$ten_min_ago" '
                select(.event_type == "alert") |
                select((.timestamp | sub("\\.[0-9]+.*"; "") | strptime("%Y-%m-%dT%H:%M:%S") | mktime) >= $cutoff) |
                "\(.alert.signature_id // "unknown")|\(.alert.signature // "Unknown Signature")"
            ' 2>/dev/null || echo "")

        if [[ -z "$sig_data" ]]; then
            echo "  No signatures triggered in last 10 minutes"
        else
            # Count and sort signatures
            echo "$sig_data" | sort | uniq -c | sort -rn | head -5 | while read -r count sig_info; do
                local sid sig_name
                sid=$(echo "$sig_info" | cut -d'|' -f1)
                sig_name=$(echo "$sig_info" | cut -d'|' -f2-)
                # Truncate long signature names
                [[ ${#sig_name} -gt 45 ]] && sig_name="${sig_name:0:42}..."
                printf "  ${C_CYAN}%5d${C_RESET}  [SID:%-8s] %s\n" "$count" "$sid" "$sig_name"
            done
        fi
        echo ""
    fi

    # -------------------------------------------------------------------------
    # Section 5: Quick Actions
    # -------------------------------------------------------------------------
    echo -e "${C_BOLD}Quick Actions${C_RESET}"
    echo "─────────────────────────────────────────────────────────"
    echo "  View live alerts:   tail -f $eve_path | jq 'select(.event_type==\"alert\")'"
    echo "  Top SIDs all time:  nftban suricata sid top"
    echo "  SID details:        nftban suricata sid info <SID>"
    echo "  Full status:        nftban suricata status"
    echo ""
}

# =============================================================================
# COMMAND: eve
# =============================================================================

cmd_suricata_eve() {
    local action="${1:-check}"
    shift || true

    case "$action" in
        check)
            cmd_suricata_eve_check
            ;;
        help|--help|-h)
            cat << 'EOF'

📋 Suricata EVE JSON Log Check

USAGE:
    nftban suricata eve [check]

COMMANDS:
    check       Check EVE JSON health and statistics (default)
    help        Show this help message

DESCRIPTION:
    Comprehensive health check for Suricata's EVE JSON log file.
    Validates file accessibility, JSON integrity, and provides
    alert statistics with time-based breakdowns.

WHAT IT CHECKS:
    - EVE file path from configuration
    - File existence and read permissions
    - Last write time and file size
    - JSON validity (samples last 100 lines)
    - Alert counts: last 1m, 5m, 1h
    - Top 5 signatures from last 10 minutes

EXAMPLES:
    # Run health check
    nftban suricata eve check

    # Or simply (check is default)
    nftban suricata eve

OUTPUT SECTIONS:
    1. EVE File Information
       - Path, status, size, last modified

    2. JSON Validity
       - Validates JSON structure of recent entries
       - Detects corruption from log rotation

    3. Alert Statistics
       - Time-windowed alert counts
       - Rate calculations (alerts/min)

    4. Top Signatures
       - Most triggered rules in last 10 minutes
       - Includes SID and signature name

COLOR CODING:
    Green   - Healthy / low activity
    Yellow  - Warning / moderate activity
    Red     - Issue / high activity

REQUIREMENTS:
    - jq (recommended for full functionality)
    - Read access to EVE log file

EOF
            ;;
        *)
            echo "ERROR: Unknown eve subcommand: $action" >&2
            echo "Run 'nftban suricata eve help' for usage"
            return 1
            ;;
    esac
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f cmd_suricata_profile
export -f cmd_suricata_scan
export -f cmd_suricata_services
export -f cmd_suricata_eve
export -f cmd_suricata_eve_check
export -f _eve_get_path
export -f _eve_format_bytes
export -f _eve_format_age
