#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0 - Suricata IDS CLI Command - Advanced Rules Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Local, Custom, and Recommend commands for Suricata
#
# meta:name="cmd_suricata_advanced"
# meta:type="cli"
# meta:header="Suricata Advanced Commands Module"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Local, Custom, and Recommend commands for Suricata"
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
[[ -n "${_CMD_SURICATA_ADVANCED_LOADED:-}" ]] && return 0
_CMD_SURICATA_ADVANCED_LOADED="true"

# =============================================================================
# COMMAND: local (Local User Rules Management)
# =============================================================================

cmd_suricata_local() {
    local action="${1:-help}"
    shift || true

    case "$action" in
        list)
            _suricata_local_list "false"
            ;;

        add)
            local rule="$*"
            if [[ -z "$rule" ]]; then
                echo "ERROR: Rule required" >&2
                echo ""
                echo "Usage: nftban suricata local add '<RULE>'"
                echo ""
                echo "Example:"
                echo "  nftban suricata local add 'alert tcp any any -> any 22 (msg:\"SSH probe\"; sid:1000001; rev:1;)'"
                echo ""
                echo "SID Range: 1000000-1999999 for user rules"
                return 1
            fi
            _suricata_local_add "$rule" "false"
            ;;

        remove)
            local sid="${1:-}"
            if [[ -z "$sid" ]]; then
                echo "ERROR: SID required" >&2
                echo ""
                echo "Usage: nftban suricata local remove <SID>"
                return 1
            fi
            _suricata_local_remove "$sid" "false"
            ;;

        edit)
            local file="${NFTBAN_SURICATA_DIR:-/etc/nftban/suricata}/rules/local.rules"
            if [[ ! -f "$file" ]]; then
                echo "ERROR: Local rules file not found" >&2
                echo "Create rules first with: nftban suricata local add '<rule>'"
                return 1
            fi
            echo ""
            echo "Opening local rules file in editor..."
            echo "File: $file"
            echo ""
            echo "SID Ranges:"
            echo "  1000000-1999999: User local rules (edit this section)"
            echo "  9000000-9999999: NFTBan auto-generated (DO NOT EDIT)"
            echo ""
            "${EDITOR:-vi}" "$file"
            echo ""
            echo "Don't forget to apply changes:"
            echo "  nftban suricata rules apply"
            echo ""
            ;;

        help|*)
            cat << 'EOF'

📝 Local User Rules Management

USAGE:
    nftban suricata local <command>

COMMANDS:
    list          List local user rules
    add <RULE>    Add a new local rule
    remove <SID>  Remove a local rule by SID
    edit          Open local.rules in editor
    help          Show this help message

SID RANGE:
    User local rules MUST use SID range: 1000000-1999999
    (NFTBan auto-generated rules use: 9000000-9999999)

RULE SYNTAX:
    action protocol src_ip src_port -> dst_ip dst_port (options)

    Actions: alert, drop, reject, pass
    Protocol: tcp, udp, icmp, ip

EXAMPLES:
    # Add a rule to detect SSH brute force
    nftban suricata local add 'alert tcp any any -> any 22 (msg:"SSH brute force attempt"; threshold:type both, track by_src, count 5, seconds 60; sid:1000001; rev:1;)'

    # Add a rule to log outbound DNS queries
    nftban suricata local add 'alert udp any any -> any 53 (msg:"DNS query"; sid:1000002; rev:1;)'

    # List current rules
    nftban suricata local list

    # Remove a rule
    nftban suricata local remove 1000001

    # Edit rules manually
    nftban suricata local edit

WORKFLOW:
    1. Add rule:    nftban suricata local add '<rule>'
    2. Verify:      nftban suricata local list
    3. Apply:       nftban suricata rules apply
    4. Monitor:     nftban suricata sid info 1000001

CONFIG FILE:
    /etc/nftban/suricata/rules/local.rules

NOTES:
    - Rules are validated on add (basic syntax check)
    - Changes require 'nftban suricata rules apply' to take effect
    - User rules section is preserved during updates
    - For NFTBan-managed rules, use 'nftban suricata custom'

EOF
            ;;
    esac
}

# =============================================================================
# COMMAND: custom (Custom Rules Management)
# =============================================================================

cmd_suricata_custom() {
    local action="${1:-help}"
    shift || true

    case "$action" in
        add)
            _check_root "custom add" || return 1

            local rule="$1"
            if [[ -z "$rule" ]]; then
                echo "ERROR: Rule required" >&2
                echo ""
                echo "Usage: nftban suricata custom add '<RULE>'"
                echo ""
                echo "Example:"
                echo "  nftban suricata custom add 'alert tcp any any -> any 80 (msg:\"HTTP Traffic\"; sid:9000000; rev:1;)'"
                echo ""
                return 1
            fi

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ➕ Adding Custom Suricata Rule"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata custom-add "$rule"; then
                echo "✗ Failed to add custom rule"
                return 1
            fi

            echo ""
            ;;

        remove)
            _check_root "custom remove" || return 1

            local sid="$1"
            if [[ -z "$sid" ]]; then
                echo "ERROR: SID required" >&2
                echo ""
                echo "Usage: nftban suricata custom remove <SID>"
                echo ""
                echo "Example:"
                echo "  nftban suricata custom remove 9000000"
                echo ""
                return 1
            fi

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  🗑️  Removing Custom Suricata Rule"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata custom-remove "$sid"; then
                echo "✗ Failed to remove custom rule"
                return 1
            fi

            echo ""
            ;;

        edit)
            _check_root "custom edit" || return 1

            local sid="$1"
            local new_rule="$2"

            if [[ -z "$sid" ]] || [[ -z "$new_rule" ]]; then
                echo "ERROR: SID and new rule required" >&2
                echo ""
                echo "Usage: nftban suricata custom edit <SID> '<NEW_RULE>'"
                echo ""
                echo "Example:"
                echo "  nftban suricata custom edit 9000000 'alert tcp any any -> any 80 (msg:\"Updated\"; sid:9000000; rev:2;)'"
                echo ""
                return 1
            fi

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ✏️  Editing Custom Suricata Rule"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata custom-edit "$sid" "$new_rule"; then
                echo "✗ Failed to edit custom rule"
                return 1
            fi

            echo ""
            ;;

        list)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  📋 Custom Suricata Rules"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata custom-list; then
                echo "✗ Failed to list custom rules"
                return 1
            fi

            echo ""
            ;;

        validate)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ✅ Validating Custom Suricata Rules"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata custom-validate; then
                echo "✗ Validation failed"
                return 1
            fi

            echo ""
            ;;

        enable)
            _check_root "custom enable" || return 1

            local sid="$1"
            if [[ -z "$sid" ]]; then
                echo "ERROR: SID required" >&2
                echo ""
                echo "Usage: nftban suricata custom enable <SID>"
                echo ""
                return 1
            fi

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ✅ Enabling Custom Rule"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata custom-enable "$sid"; then
                echo "✗ Failed to enable custom rule"
                return 1
            fi

            echo ""
            ;;

        disable)
            _check_root "custom disable" || return 1

            local sid="$1"
            if [[ -z "$sid" ]]; then
                echo "ERROR: SID required" >&2
                echo ""
                echo "Usage: nftban suricata custom disable <SID>"
                echo ""
                return 1
            fi

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ❌ Disabling Custom Rule"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata custom-disable "$sid"; then
                echo "✗ Failed to disable custom rule"
                return 1
            fi

            echo ""
            ;;

        backup)
            _check_root "custom backup" || return 1

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  💾 Backup Custom Rules"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata custom-backup; then
                echo "✗ Failed to create backup"
                return 1
            fi

            echo ""
            ;;

        rollback)
            _check_root "custom rollback" || return 1

            local backup_name="$1"
            if [[ -z "$backup_name" ]]; then
                echo "ERROR: Backup name required" >&2
                echo ""
                echo "Usage: nftban suricata custom rollback <BACKUP_NAME>"
                echo ""
                echo "List backups with: nftban suricata custom backup"
                echo ""
                return 1
            fi

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  ⏮️  Rollback Custom Rules"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata custom-rollback "$backup_name"; then
                echo "✗ Failed to rollback"
                return 1
            fi

            echo ""
            ;;

        help|*)
            cat << 'EOF'

🔧 Custom Suricata Rules Management

USAGE:
    nftban suricata custom <command>

COMMANDS:
    add         Add a new custom rule
    remove      Remove a custom rule by SID
    edit        Edit an existing custom rule
    list        List all custom rules
    validate    Validate all custom rules
    enable      Enable a disabled rule
    disable     Disable an enabled rule
    backup      Create a backup of custom rules
    rollback    Restore from a backup
    help        Show this help message

SID RANGE:
    Custom rules MUST use SID range: 9000000-9999999
    This prevents conflicts with official rulesets

EXAMPLES:
    # Add a new rule
    nftban suricata custom add 'alert tcp any any -> any 80 (msg:"HTTP Traffic"; sid:9000000; rev:1;)'

    # List all custom rules
    nftban suricata custom list

    # Validate all rules
    nftban suricata custom validate

    # Remove a rule
    nftban suricata custom remove 9000000

    # Disable a rule (comment out)
    nftban suricata custom disable 9000000

    # Create backup
    nftban suricata custom backup

    # Rollback to backup
    nftban suricata custom rollback custom.rules.20240101-120000

WORKFLOW:
    1. Add rule:        nftban suricata custom add '<RULE>'
    2. Validate:        nftban suricata custom validate
    3. Reload Suricata: systemctl reload suricata
    4. Monitor:         nftban suricata sid info <SID>

BACKUPS:
    - Automatic backup before any modification
    - Backups stored in: /etc/nftban/suricata/rules/backups/
    - Last 10 backups are kept
    - Rollback restores previous state

NOTES:
    - All modifications require root
    - Rules are validated before adding/editing
    - Invalid rules will be rejected
    - Changes require Suricata reload to take effect
    - Custom rules file: /etc/nftban/suricata/rules/custom.rules

EOF
            ;;
    esac
}

# =============================================================================
# COMMAND: recommend (Recommendations Engine)
# =============================================================================

cmd_suricata_recommend() {
    local action="${1:-analyze}"

    case "$action" in
        analyze|all)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  💡 Suricata Rule Recommendations"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata recommend; then
                echo "✗ Failed to generate recommendations"
                return 1
            fi

            echo ""
            ;;

        summary)
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  📊 Recommendations Summary"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""

            # Call Go backend
            if ! nftban-core suricata recommend-summary; then
                echo "✗ Failed to generate summary"
                return 1
            fi

            echo ""
            ;;

        help|*)
            cat << 'EOF'

💡 Suricata Recommendations Engine

USAGE:
    nftban suricata recommend [analyze|summary]

COMMANDS:
    analyze     Generate detailed recommendations (default)
    summary     Show summary statistics
    help        Show this help message

DESCRIPTION:
    Analyzes SID trigger statistics and provides intelligent
    recommendations for optimizing your Suricata ruleset.

RECOMMENDATION TYPES:
    ⚠️  False Positives   - Rules triggering excessively from few sources
    🔇 Noise Reduction   - Very noisy rules affecting many sources
    🛡️  Drop Mode        - Attack patterns that should be blocked
    ❌ Disable Rule      - Extremely problematic rules to disable

SEVERITY LEVELS:
    🔴 High    - Immediate action recommended
    🟡 Medium  - Should be addressed soon
    🟢 Low     - Optional optimization

EXAMPLES:
    # Generate detailed recommendations
    nftban suricata recommend

    # Show summary only
    nftban suricata recommend summary

WORKFLOW:
    1. Generate recommendations: nftban suricata recommend
    2. Review high severity items first
    3. Investigate: nftban suricata sid info <SID>
    4. Apply fixes: disable/modify rules as needed
    5. Monitor: nftban suricata sid top

ANALYSIS PATTERNS:
    - False Positive: 100+ triggers from 1-3 sources
    - Noise: 1000+ triggers, widespread sources, low ratio
    - Drop Mode: Attack patterns from many sources
    - Disable: 10,000+ triggers, very recent activity

NOTES:
    - Recommendations based on current statistics
    - Run after collecting data for at least 24 hours
    - Review recommendations before applying changes
    - Some "noisy" rules may be legitimate for your environment

EOF
            ;;
    esac
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f cmd_suricata_local
export -f cmd_suricata_custom
export -f cmd_suricata_recommend
