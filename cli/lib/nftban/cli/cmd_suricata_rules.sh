#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0 - Suricata IDS CLI Command - Rules Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Rules, SID, and Category management commands for Suricata
#
# meta:name="cmd_suricata_rules"
# meta:type="submodule"
# meta:version="1.0.0"
# meta:description="Rules, SID, and Category management commands for Suricata"
# meta:parent="cmd_suricata.sh"
#
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
            echo "  🛡️  Updating Suricata Rules"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            if ! command -v suricata-update &>/dev/null; then
                echo "✗ suricata-update not installed"
                echo ""
                echo "Install:"
                echo "  pip3 install --upgrade suricata-update"
                return 1
            fi

            # Create backup before update
            echo "  → Creating backup..."
            _suricata_backup_rules >/dev/null

            echo "  → Downloading latest rules from ET/Open..."
            suricata-update || {
                echo "  ✗ Rule update failed"
                return 1
            }

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

            echo ""
            echo "✅ Rules updated successfully"
            echo ""
            ;;

        rollback)
            local backup_name="${1:-}"
            if [[ -z "$backup_name" ]]; then
                echo "ERROR: Backup name required"
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
    update        Update rules from ET/Open (requires root)
    rollback      Restore from a backup (requires root)
    list-backups  List available rule backups
    apply         Apply pending changes (run suricata-update + reload)
    generate      Generate enabled.list from service scan (requires root)
    stats         Show rules statistics (calls Go backend)
    init          Initialize configuration files
    list          List installed rule files
    help          Show this help message

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

    # Update to latest ET/Open rules
    nftban suricata rules update

    # Apply local changes (SID/category modifications)
    nftban suricata rules apply

NOTES:
    - Rules are updated automatically via systemd timer (weekly)
    - All changes write to NFTBan config files (never vendor files)
    - Backups are kept in /etc/nftban/suricata/state/last-good/
    - Last 10 backups are retained

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
                echo "ERROR: SID required"
                echo ""
                echo "Usage: nftban suricata sid enable <SID>"
                return 1
            fi
            _suricata_sid_enable "$sid" "false"
            ;;

        disable)
            local sid="${1:-}"
            if [[ -z "$sid" ]]; then
                echo "ERROR: SID required"
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
                echo "ERROR: SID required"
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
                echo "ERROR: Category name required"
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
                echo "ERROR: Category name required"
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
