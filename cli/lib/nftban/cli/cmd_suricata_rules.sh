#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0 - Suricata IDS CLI Command - Rules Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Rules, SID, and Category management commands for Suricata
#
# meta:name="cmd_suricata_rules"
# meta:type="cli"
# meta:header="Suricata Rules Module"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Rules, SID, and Category management commands for Suricata"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# Loaded by: cmd_suricata.sh (inherits strict mode)
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_CMD_SURICATA_RULES_LOADED:-}" ]] && return 0
_CMD_SURICATA_RULES_LOADED="true"

# =============================================================================
# COMMAND: rules
# =============================================================================

cmd_suricata_rules() {
    local action="${1:-help}"
    shift || true

    case "$action" in
        status)
            # Use helper function
            _suricata_rules_status "false"
            ;;

        update)
            _check_root "rules update" || return 1

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  🛡️  Updating Suricata Rules (Profile-Aware)"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            if ! command -v suricata-update &>/dev/null; then
                echo "✗ suricata-update not installed"
                echo ""
                echo "Install:"
                echo "  pip3 install --upgrade suricata-update"
                return 1
            fi

            # Source the effective config generator
            local helper_file="${_NFTBAN_LIB_DIR:-/usr/share/nftban/lib/nftban}/helpers/suricata_effective_config.sh"
            if [[ -f "$helper_file" ]]; then
                # shellcheck source=/dev/null
                source "$helper_file" || return 1
            else
                echo "⚠️  Effective config generator not found, using legacy mode"
                echo "  (Missing: $helper_file)"
                echo ""
            fi

            # 1. Generate effective config (profile, modules, role)
            echo "  → Generating effective configuration..."
            local profile_role=""
            if declare -f suricata_generate_effective_config &>/dev/null; then
                profile_role=$(suricata_generate_effective_config "true")
                local profile="${profile_role%%:*}"
                local role="${profile_role##*:}"
                echo "  ✓ Profile: $profile, Role: $role"
            else
                echo "  ⚠️  Legacy mode: no profile/module awareness"
            fi

            # 2. Create backup before update
            echo "  → Creating backup..."
            _suricata_backup_rules >/dev/null

            # 3. Update rule sources
            echo "  → Updating rule sources..."
            suricata-update update-sources 2>/dev/null || true

            # 4. Build suricata-update command with proper flags
            # v1.19.0: Use array instead of eval (R16)
            local -a update_args=()

            # Add disable.conf.d if it exists and has files
            local disable_dir="${SURICATA_CONFIG_DIR:-/etc/suricata}/disable.conf.d"
            if [[ -d "$disable_dir" ]]; then
                for conf_file in "$disable_dir"/*.conf; do
                    [[ -f "$conf_file" ]] && update_args+=("--disable-conf=$conf_file")
                done
            fi

            # Also include standard disable.conf if it exists
            local disable_conf="${SURICATA_CONFIG_DIR:-/etc/suricata}/disable.conf"
            [[ -f "$disable_conf" ]] && update_args+=("--disable-conf=$disable_conf")

            # Include enable.conf if it exists
            local enable_conf="${SURICATA_CONFIG_DIR:-/etc/suricata}/enable.conf"
            [[ -f "$enable_conf" ]] && update_args+=("--enable-conf=$enable_conf")

            # Include local rules if they exist
            local local_rules="${NFTBAN_SURICATA_DIR:-/etc/nftban/suricata}/rules/local.rules"
            [[ -f "$local_rules" ]] && update_args+=("--local=$local_rules")

            echo "  → Downloading and filtering rules..."
            if ! suricata-update "${update_args[@]}"; then
                echo "  ✗ Rule update failed"
                return 1
            fi

            # 5. Check if restart is needed (dedupe)
            local should_restart=true
            if declare -f _suricata_should_restart &>/dev/null; then
                if ! _suricata_should_restart; then
                    should_restart=false
                    echo "  ✓ Rules unchanged, skipping restart"
                fi
            fi

            # 6. Restart if needed
            if [[ "$should_restart" == "true" ]]; then
                echo ""
                echo "  → Restarting Suricata to load new rules..."
                systemctl restart "$SURICATA_SERVICE" || {
                    echo "  ✗ Failed to restart Suricata"
                    return 1
                }

                sleep 2
                if _suricata_is_running; then
                    echo "  ✓ Suricata restarted successfully"
                else
                    echo "  ✗ Suricata failed to restart"
                    return 1
                fi
            fi

            # 7. Record effective state for future dedupe
            if declare -f _suricata_record_effective_state &>/dev/null; then
                local profile="${profile_role%%:*}"
                local role="${profile_role##*:}"
                _suricata_record_effective_state "${profile:-unknown}" "${role:-unknown}"
                echo "  ✓ State recorded for dedupe"
            fi

            # 8. Validate rule count against profile budget
            local rules_file="${SURICATA_RULES_DIR:-/var/lib/suricata/rules}/suricata.rules"
            if [[ -f "$rules_file" ]]; then
                local rule_count
                rule_count=$(grep -c "^alert\|^drop\|^reject" "$rules_file" 2>/dev/null || echo 0)
                echo ""
                echo "  📊 Rule count: $rule_count"

                # Check against profile budget
                local profile="${profile_role%%:*}"
                local max_rules=60000
                case "${profile:-standard}" in
                    minimal)  max_rules=10000 ;;
                    standard) max_rules=25000 ;;
                    maximum)  max_rules=60000 ;;
                esac

                if [[ $rule_count -gt $max_rules ]]; then
                    echo "  ⚠️  WARNING: Rule count $rule_count exceeds profile '$profile' budget of $max_rules"
                    echo "     Consider reviewing disable.conf or switching profile"
                fi
            fi

            echo ""
            echo "✅ Rules updated successfully"
            echo ""
            ;;

        rollback)
            local backup_name="${1:-}"
            if [[ -z "$backup_name" ]]; then
                echo "ERROR: Backup name required" >&2
                echo ""
                echo "Usage: nftban suricata rules rollback <BACKUP_NAME>"
                echo ""
                echo "List backups with: nftban suricata rules list-backups"
                return 1
            fi
            _suricata_rules_rollback "$backup_name" "false"
            ;;

        list-backups|backups)
            _suricata_rules_list_backups "false"
            ;;

        apply)
            _suricata_rules_apply "false"
            ;;

        list)
            echo ""
            echo "Suricata Rule Files:"
            if [[ -d "${SURICATA_RULES_DIR}" ]]; then
                ls -lh "${SURICATA_RULES_DIR}"/*.rules 2>/dev/null || echo "No rule files found"
            else
                echo "Rules directory not found"
            fi
            echo ""
            ;;

        verify)
            # Verify rules are present and loadable - used by ExecStartPre
            # Exit 0 = ready, Exit 1 = not ready (with fix command)
            local quiet="${1:-}"
            local rules_file="${SURICATA_RULES_DIR}/suricata.rules"
            local exit_code=0

            # Check 1: Rules file exists and non-empty
            if [[ ! -f "$rules_file" ]] || [[ ! -s "$rules_file" ]]; then
                [[ "$quiet" != "--quiet" ]] && {
                    echo "FAIL: Rules file missing or empty: $rules_file"
                    echo "FIX:  suricata-update && systemctl restart suricata"
                }
                exit_code=1
            fi

            # Check 2: YAML references the rules (optional but helpful)
            if [[ -f /etc/suricata/suricata.yaml ]]; then
                local yaml_rules_path
                yaml_rules_path=$(grep -E "^default-rule-path:" /etc/suricata/suricata.yaml 2>/dev/null | awk '{print $2}' | tr -d '"' || echo "")
                if [[ -n "$yaml_rules_path" ]] && [[ ! -d "$yaml_rules_path" ]]; then
                    [[ "$quiet" != "--quiet" ]] && {
                        echo "WARN: YAML default-rule-path doesn't exist: $yaml_rules_path"
                    }
                fi
            fi

            # Check 3: Config syntax (optional, slower)
            if [[ "$1" == "--full" ]] && command -v suricata &>/dev/null; then
                if ! suricata -T -c /etc/suricata/suricata.yaml &>/dev/null; then
                    [[ "$quiet" != "--quiet" ]] && {
                        echo "FAIL: Suricata config test failed"
                        echo "FIX:  suricata -T -c /etc/suricata/suricata.yaml"
                    }
                    exit_code=1
                fi
            fi

            if [[ $exit_code -eq 0 ]]; then
                [[ "$quiet" != "--quiet" ]] && echo "OK: Rules verified"
            fi
            return $exit_code
            ;;

        ensure)
            # Auto-heal: Download rules if missing, then verify
            # Invoked from nftban health fix, auto-heal mode
            local rules_file="${SURICATA_RULES_DIR}/suricata.rules"

            # Check if rules exist
            if [[ -f "$rules_file" ]] && [[ -s "$rules_file" ]]; then
                echo "OK: Rules already present"
                return 0
            fi

            echo "Rules missing - downloading..."

            # Need root for suricata-update
            if [[ $EUID -ne 0 ]]; then
                echo "FAIL: Root required to download rules"
                echo "FIX:  sudo nftban suricata rules ensure"
                return 1
            fi

            # Download rules
            if ! command -v suricata-update &>/dev/null; then
                echo "FAIL: suricata-update not installed"
                echo "FIX:  pip3 install suricata-update"
                return 1
            fi

            suricata-update update-sources 2>/dev/null || true
            if suricata-update; then
                echo "OK: Rules downloaded"
                # Restart Suricata to load rules
                if systemctl is-active --quiet suricata.service; then
                    systemctl restart suricata.service
                    echo "OK: Suricata restarted"
                fi
                return 0
            else
                echo "FAIL: suricata-update failed"
                return 1
            fi
            ;;

        generate)
            _check_root "rules generate" || return 1

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  📝 Generating Suricata Rules List"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata rules-generate; then
                echo "✗ Rules generation failed"
                return 1
            fi

            echo ""
            ;;

        stats)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  📊 Suricata Rules Statistics"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata rules-stats; then
                echo "✗ Failed to get stats"
                return 1
            fi

            echo ""
            ;;

        init)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  🔧 Initializing Suricata Configuration"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata rules-init; then
                echo "✗ Initialization failed"
                return 1
            fi

            echo ""
            ;;

        help|*)
            cat << 'EOF'

📜 Suricata Rules Management

USAGE:
    nftban suricata rules <command>

COMMANDS:
    status        Show ruleset status (counts, last update, sources)
    verify        Verify rules are present and loadable (used by systemd)
    ensure        Auto-heal: download rules if missing (used by health fix)
    update        Update rules (profile-aware, module-aware, dedupe)
    rollback      Restore from a backup (requires root)
    list-backups  List available rule backups
    apply         Apply pending changes (run suricata-update + reload)
    generate      Generate enabled.list from service scan (requires root)
    stats         Show rules statistics (calls Go backend)
    init          Initialize configuration files
    list          List installed rule files
    help          Show this help message

PROFILE-AWARE UPDATE:
    The 'update' command now uses a unified pipeline:

    1. AUTO-PROFILE:    Detects optimal profile (minimal/standard/maximum)
                        based on CPU/RAM and distro (RHEL uses 5x more memory)

    2. MODULE OVERLAP:  Disables Suricata rules that overlap with enabled
                        nftban modules (login SSH, portscan, ddos)

    3. ROLE DETECTION:  Detects server role (web/mail/hosting) and adjusts
                        rule coverage accordingly

    4. DEDUPE:          Only restarts Suricata if rules actually changed
                        (saves unnecessary service disruption)

    5. VALIDATION:      Checks rule count against profile budget

    Config files generated:
      /etc/suricata/disable.conf.d/nftban-profile.conf  (profile disables)
      /etc/suricata/disable.conf.d/nftban-modules.conf  (module overlaps)
      /etc/nftban/suricata/state/effective.json         (state for dedupe)

WORKFLOW:
    1. Check status:     nftban suricata rules status
    2. Make changes:     nftban suricata sid disable <SID>
                         nftban suricata category enable emerging-malware
    3. Apply changes:    nftban suricata rules apply
    4. Verify:           nftban suricata rules status

BACKUP & ROLLBACK:
    # List available backups
    nftban suricata rules list-backups

    # Rollback to a specific backup
    nftban suricata rules rollback 20260202-120000

    Backups are created automatically before any rule changes.

EXAMPLES:
    # Show current ruleset status
    nftban suricata rules status

    # Update to latest rules (profile-aware, module-aware)
    nftban suricata rules update

    # Apply local changes (SID/category modifications)
    nftban suricata rules apply

PROFILE BUDGETS:
    Profile     Max Rules   Max RAM (RHEL)   Max RAM (Debian)
    --------    ---------   --------------   ----------------
    minimal     10,000      600 MB           150 MB
    standard    25,000      1,500 MB         400 MB
    maximum     60,000      2,500 MB         800 MB

NOTES:
    - Rules are updated automatically via systemd timer (weekly)
    - Profile auto-detects based on system resources
    - Module overlaps prevent double-detection with nftban modules
    - Dedupe prevents unnecessary Suricata restarts
    - Backups are kept in /etc/nftban/suricata/state/last-good/

EOF
            ;;
    esac
}

# =============================================================================
# COMMAND: sid (SID Statistics)
# =============================================================================

cmd_suricata_sid() {
    local action="${1:-help}"
    shift || true

    case "$action" in
        enable)
            local sid="${1:-}"
            if [[ -z "$sid" ]]; then
                echo "ERROR: SID required" >&2
                echo ""
                echo "Usage: nftban suricata sid enable <SID>"
                return 1
            fi
            _suricata_sid_enable "$sid" "false"
            ;;

        disable)
            local sid="${1:-}"
            if [[ -z "$sid" ]]; then
                echo "ERROR: SID required" >&2
                echo ""
                echo "Usage: nftban suricata sid disable <SID>"
                return 1
            fi
            _suricata_sid_disable "$sid" "false"
            ;;

        list)
            local type="${1:-all}"
            _suricata_sid_list "$type" "false"
            ;;

        stats)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  📊 Suricata SID Statistics"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata sid-stats; then
                echo "✗ Failed to get SID statistics"
                return 1
            fi

            echo ""
            ;;

        info)
            local sid="${1:-}"

            if [[ -z "$sid" ]]; then
                echo "ERROR: SID required" >&2
                echo ""
                echo "Usage: nftban suricata sid info <SID>"
                echo ""
                echo "Example:"
                echo "  nftban suricata sid info 2100498"
                echo ""
                return 1
            fi

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  🔍 SID Information: $sid"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata sid-info "$sid"; then
                echo "✗ SID not found or failed to retrieve information"
                return 1
            fi

            echo ""
            ;;

        top)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  🏆 Top 20 Most Triggered SIDs"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata sid-top; then
                echo "✗ Failed to get top SIDs"
                return 1
            fi

            echo ""
            ;;

        recent)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ⏱️  Recent SID Triggers (Last 24 Hours)"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata sid-recent; then
                echo "✗ Failed to get recent SIDs"
                return 1
            fi

            echo ""
            ;;

        help|*)
            cat << 'EOF'

🔢 Suricata SID Management

USAGE:
    nftban suricata sid <command>

COMMANDS:
    enable <SID>    Force-enable a specific SID (add to enable.conf)
    disable <SID>   Disable a specific SID (add to disable.conf)
    list [type]     List SID overrides (enabled, disabled, or all)
    stats           Show overall SID statistics summary
    info <SID>      Show detailed information for a specific SID
    top             Show top 20 most triggered SIDs
    recent          Show SIDs triggered in last 24 hours
    help            Show this help message

ENABLING/DISABLING RULES:
    # Disable a noisy or false-positive rule
    nftban suricata sid disable 2100498

    # Force-enable a rule from a disabled category
    nftban suricata sid enable 2024792

    # List all overrides
    nftban suricata sid list

    # Apply changes
    nftban suricata rules apply

WORKFLOW:
    1. Identify problematic SID:   nftban suricata sid top
    2. Get details:                nftban suricata sid info 2100498
    3. Disable it:                 nftban suricata sid disable 2100498
    4. Apply changes:              nftban suricata rules apply

CONFIG FILES:
    Enable:  /etc/nftban/suricata/rules/enable.conf
    Disable: /etc/nftban/suricata/rules/disable.conf

    These files are processed by suricata-update:
    - enable.conf overrides disable.conf
    - Individual SIDs override category settings

EXAMPLES:
    # Disable a false-positive rule
    nftban suricata sid disable 2100498

    # Enable a rule from disabled category
    nftban suricata sid enable 2024792

    # View all disabled SIDs
    nftban suricata sid list disabled

NOTES:
    - Changes require 'nftban suricata rules apply' to take effect
    - Backups are created automatically before changes
    - SID overrides persist across ruleset updates

EOF
            ;;
    esac
}

# =============================================================================
# COMMAND: category (Rule Category Management)
# =============================================================================

cmd_suricata_category() {
    local action="${1:-help}"
    shift || true

    case "$action" in
        list)
            _suricata_category_list "false"
            ;;

        enable)
            local category="${1:-}"
            if [[ -z "$category" ]]; then
                echo "ERROR: Category name required" >&2
                echo ""
                echo "Usage: nftban suricata category enable <CATEGORY>"
                echo ""
                echo "List categories with: nftban suricata category list"
                return 1
            fi
            _suricata_category_set "$category" "enabled" "false"
            ;;

        disable)
            local category="${1:-}"
            if [[ -z "$category" ]]; then
                echo "ERROR: Category name required" >&2
                echo ""
                echo "Usage: nftban suricata category disable <CATEGORY>"
                echo ""
                echo "List categories with: nftban suricata category list"
                return 1
            fi
            _suricata_category_set "$category" "disabled" "false"
            ;;

        help|*)
            cat << 'EOF'

📂 Suricata Rule Category Management

USAGE:
    nftban suricata category <command>

COMMANDS:
    list              List all categories with their status
    enable <CAT>      Enable a rule category
    disable <CAT>     Disable a rule category
    help              Show this help message

CATEGORY NAMES:
    Common ET Open categories:
    - emerging-malware      Core malware detection
    - emerging-trojan       Trojan/RAT detection
    - emerging-exploit      Exploit attempts
    - emerging-scan         Port scanning/reconnaissance
    - emerging-dos          DoS/DDoS attacks
    - emerging-web_server   Web server attacks
    - emerging-web_client   Client-side attacks
    - emerging-dns          DNS-based threats
    - emerging-policy       Policy violations (noisy)
    - emerging-tor          Tor exit node detection

WORKFLOW:
    # List current category status
    nftban suricata category list

    # Disable noisy policy rules
    nftban suricata category disable emerging-policy

    # Enable SQL injection detection
    nftban suricata category enable emerging-sql

    # Apply changes
    nftban suricata rules apply

EXAMPLES:
    # Disable all policy rules (reduces noise)
    nftban suricata category disable emerging-policy

    # Enable VOIP rules (if you run SIP/VOIP)
    nftban suricata category enable emerging-voip

    # Disable FTP rules (if you don't use FTP)
    nftban suricata category disable emerging-ftp

CONFIG FILE:
    /etc/nftban/suricata/rules/categories.enabled

    Format: category-name = enabled|disabled

NOTES:
    - Changes require 'nftban suricata rules apply' to take effect
    - Individual SID overrides take precedence over categories
    - Disabling unused categories improves performance

EOF
            ;;
    esac
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f cmd_suricata_rules
export -f cmd_suricata_sid
export -f cmd_suricata_category
