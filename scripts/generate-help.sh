#!/usr/bin/env bash
# =============================================================================
# NFTBan - Help Generator from Registry
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Generate task-grouped CLI help from commands.registry.yml
#
# Usage: ./scripts/generate-help.sh [--profile operator|auditor]
# Output: Formatted help text for nftban help command
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REGISTRY="${PROJECT_ROOT}/commands.registry.yml"

# =============================================================================
# CONFIGURATION
# =============================================================================

PROFILE="${1:---profile}"
PROFILE="${2:-operator}"

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

    yq -r ".\"$command\".\"$field\" // empty" "$REGISTRY" 2>/dev/null
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

generate_help_header() {
    cat <<'EOF'
NFTBan - Adaptive Firewall Management
======================================

Usage: nftban <command> [subcommand] [options]

Global Options:
  --json        Output in JSON format (where supported)
  --dry-run     Preview changes without applying (for mutating commands)
  --quiet       Suppress non-essential output
  --verbose     Show detailed diagnostic output
  --help, -h    Show command-specific help

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
        local risk_icon="${RISK_ICONS[$risk]:-}"

        # Format: command (icon) - description
        printf "  %-20s %s  %s\n" "$cmd" "$risk_icon" "$description"
    done
}

generate_help_footer() {
    local profile="$1"

    cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Risk Levels:
  ⚡ Core      - Essential, safe operations
  🛠️  Setup     - One-time configuration
  ⚠️  Advanced  - Use with caution, may affect system state

For detailed command help:
  nftban <command> help

Documentation:
  Wiki:    https://github.com/itcmsgr/nftban/wiki
  Issues:  https://github.com/itcmsgr/nftban/issues

Profile: $profile
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
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
