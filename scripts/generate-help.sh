#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Help Generator from Registry
# =============================================================================
# meta:name="generate-help"
# meta:type="script"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Generate task-grouped CLI help from commands.registry.yml"
# meta:inventory.files="commands.registry.yml"
# meta:inventory.binaries="yq"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Usage: ./scripts/generate-help.sh [--profile operator|auditor]
# Output: Formatted help text for nftban help command
# =============================================================================

set -Eeuo pipefail

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

# Determine registry location (installed vs development)
if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/commands.registry.yml" ]]; then
    # Installed location (FHS compliant)
    REGISTRY="${NFTBAN_CONFIG_DIR:-/etc/nftban}/commands.registry.yml"
else
    # Development location (relative to script)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    REGISTRY="${PROJECT_ROOT}/commands.registry.yml"
fi

# =============================================================================
# CONFIGURATION
# =============================================================================

# Reserved for future profile-based filtering
_PROFILE="${2:-operator}"

# Task group names and descriptions
declare -A GROUP_NAMES=(
    ["setup_discovery"]="0. Setup & Discovery"
    ["immediate_action"]="1. Immediate Action"
    ["active_protection"]="2. Active Protection"
    ["infrastructure"]="3. Infrastructure"
    ["intelligence_reporting"]="4. Intelligence & Reporting"
    ["developer_sysadmin"]="5. Developer / SysAdmin"
)

declare -A GROUP_ICONS=(
    ["setup_discovery"]="🛠️"
    ["immediate_action"]="⚡"
    ["active_protection"]="🧱"
    ["infrastructure"]="⚙️"
    ["intelligence_reporting"]="📊"
    ["developer_sysadmin"]="🧪"
)

declare -A GROUP_DESC=(
    ["setup_discovery"]="First-run configuration and system diagnostics"
    ["immediate_action"]="Reactive security - 'Firefighter mode'"
    ["active_protection"]="Proactive hardening - 'Builder mode'"
    ["infrastructure"]="Low-level firewall and policy management"
    ["intelligence_reporting"]="Visibility and observability"
    ["developer_sysadmin"]="Advanced debugging and testing"
)

# Risk level colors (for future terminal coloring)
declare -A RISK_ICONS=(
    ["core"]="⚡"
    ["setup"]="🛠️"
    ["advanced"]="⚠️"
)

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

check_dependencies() {
    if ! command -v yq &>/dev/null; then
        echo "ERROR: yq is required for YAML parsing" >&2
        echo "Install: pip install yq  OR  brew install yq" >&2
        return 1
    fi
}

get_commands_by_category() {
    local category="$1"
    local profile="${2:-operator}"

    # Parse registry and filter by category
    yq -r "
        to_entries |
        map(select(.key != \"_metadata\" and .value.category == \"$category\")) |
        map(.key) |
        .[]
    " "$REGISTRY" 2>/dev/null || true
}

get_command_info() {
    local command="$1"
    local field="$2"

    yq -r ".\"$command\".\"$field\" // \"\"" "$REGISTRY" 2>/dev/null
}

should_show_for_profile() {
    local command="$1"
    local profile="$2"

    local audience
    audience=$(yq -r ".\"$command\".audience // []" "$REGISTRY" 2>/dev/null)

    case "$profile" in
        operator)
            # Operators see everything
            return 0
            ;;
        auditor)
            # Auditors see only auditor-allowed commands
            if echo "$audience" | grep -q "auditor"; then
                return 0
            else
                return 1
            fi
            ;;
        panel)
            # Panels see only panel-exposed commands
            local panel_expose
            panel_expose=$(yq -r ".\"$command\".panel_expose // false" "$REGISTRY" 2>/dev/null)
            [[ "$panel_expose" == "true" ]] && return 0 || return 1
            ;;
        *)
            return 0
            ;;
    esac
}

# =============================================================================
# HELP OUTPUT GENERATION
# =============================================================================

generate_global_options() {
    # Auto-generate global options from registry
    echo "Global Options:"

    # Parse global_options from registry and format for display
    # Note: Use process substitution (not pipe) to avoid subshell where local fails with set -e
    # Note: yq v4 (mikefarah/yq) syntax - uses to_entries[] and select() instead of if/then/else
    local opt desc
    while read -r line; do
        # Reformat for alignment (option on left, description on right)
        opt=$(echo "$line" | sed 's/    .*//')
        desc=$(echo "$line" | sed 's/.*    //')
        printf "  %-18s %s\n" "$opt" "$desc"
    done < <(yq -r '
        .global_options | to_entries[] |
        "  " + .key + ((.value.aliases | select(.) | ", " + join(", ")) // "") + "    " + .value.description
    ' "$REGISTRY" 2>/dev/null)
}

generate_help_header() {
    cat <<'EOF'
NFTBan - Open-source Linux IPS and nftables firewall manager
=============================================================

Usage: nftban <command> [subcommand] [options]

EOF

    # Auto-generate global options from registry (single source of truth)
    generate_global_options

    cat <<'EOF'

Quick Examples:
  nftban status                    # System overview
  nftban ban 1.2.3.4               # Block an IP
  nftban health check              # Run diagnostics
  nftban feeds update              # Update threat intelligence
  nftban firewall reload           # Atomic reload

EOF
}

generate_group_section() {
    local category="$1"
    local profile="$2"

    local group_name="${GROUP_NAMES[$category]}"
    local group_icon="${GROUP_ICONS[$category]}"
    local group_desc="${GROUP_DESC[$category]}"

    # Get commands for this category
    local commands
    commands=$(get_commands_by_category "$category" "$profile")

    # Filter by profile
    local visible_commands=()
    for cmd in $commands; do
        if should_show_for_profile "$cmd" "$profile"; then
            visible_commands+=("$cmd")
        fi
    done

    # Skip empty groups
    [[ ${#visible_commands[@]} -eq 0 ]] && return 0

    echo ""
    echo "$group_icon  $group_name"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "$group_desc"
    echo ""

    # Display commands in this group
    for cmd in "${visible_commands[@]}"; do
        local description
        description=$(get_command_info "$cmd" "description")

        local risk
        risk=$(get_command_info "$cmd" "risk")
        # Note: Empty array subscript fails with set -u, so check first
        local risk_icon=""
        [[ -n "$risk" ]] && risk_icon="${RISK_ICONS[$risk]:-}"

        # Format: command (icon) - description
        printf "  %-20s %s  %s\n" "$cmd" "$risk_icon" "$description"
    done
}

# v1.19.21 FIX: Document exit codes (E2)
generate_help_footer() {
    local profile="$1"

    cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Risk Levels:
  ⚡ Core      - Essential, safe operations
  🛠️  Setup     - One-time configuration
  ⚠️  Advanced  - Use with caution, may affect system state

Exit Codes:
  0  Success   - Command completed without errors
  1  Error     - Command failed (check stderr for details)
  2  Warning   - Command completed with warnings (e.g., missing deps)

For detailed command help:
  nftban <command> help

Documentation:
  Wiki:    https://github.com/itcmsgr/nftban/wiki
  Issues:  https://github.com/itcmsgr/nftban/issues

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
    # V127 UX-6 D-7: removed cosmetic "Profile: $profile" footer line.
    # The label was hardcoded operator-facing text that did not reflect any
    # actual operator-configurable state; auditor/panel profiles continue
    # to filter via existing should_show_for_profile logic (audience +
    # panel_expose), so the runtime profile gating is unaffected.
    # Reversible by restoring the line above.
    # (Scope: AUDIT_190_LIFECYCLE/V127_FULL_UX_CORRECTION_UMBRELLA_SCOPE.md UX-6 D-7)
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Parse arguments
    local profile="operator"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile)
                profile="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [--profile operator|auditor|panel]"
                echo "Generate help output from commands.registry.yml"
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 1
                ;;
        esac
    done

    # Validate profile
    case "$profile" in
        operator|auditor|panel) ;;
        *)
            echo "ERROR: Invalid profile: $profile" >&2
            echo "Valid profiles: operator, auditor, panel" >&2
            exit 1
            ;;
    esac

    # Check dependencies
    check_dependencies || exit 1

    # Check registry exists
    if [[ ! -f "$REGISTRY" ]]; then
        echo "ERROR: Registry not found: $REGISTRY" >&2
        exit 1
    fi

    # Generate help output
    generate_help_header

    # Generate each task group
    generate_group_section "setup_discovery" "$profile"
    generate_group_section "immediate_action" "$profile"
    generate_group_section "active_protection" "$profile"
    generate_group_section "infrastructure" "$profile"
    generate_group_section "intelligence_reporting" "$profile"

    # Developer/SysAdmin group only for operator profile
    if [[ "$profile" == "operator" ]]; then
        generate_group_section "developer_sysadmin" "$profile"
    fi

    generate_help_footer "$profile"
}

main "$@"
