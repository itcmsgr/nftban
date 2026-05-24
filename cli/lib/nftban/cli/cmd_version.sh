#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Version Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Display version information
#
# meta:name="cmd_version"
# meta:type="cli"
# meta:header="Version Command"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Display NFTBan version information"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# meta:created_date="2025-11-24"
# =============================================================================

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
else
    echo "ERROR: version.sh library not found" >&2
    return 1
fi

# Prevent double-loading
[[ -n "${CMD_VERSION_LOADED:-}" ]] && return 0
readonly CMD_VERSION_LOADED=1

# =============================================================================
# UPDATE CHECK FUNCTION
# =============================================================================

nftban_check_for_updates() {
    # Check GitHub for latest version and compare with installed
    # Usage: nftban version --update

    local repo="${NFTBAN_REPO:-itcmsgr/nftban}"
    local current_version
    current_version="${NFTBAN_VERSION:-unknown}"
    current_version="${current_version#v}"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan Update Check"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    printf "  %-20s %s\n" "Installed version:" "v${current_version}"
    printf "  %-20s %s\n" "Repository:" "github.com/${repo}"
    echo ""

    # Check if curl is available
    if ! command -v curl &>/dev/null; then
        echo "  ❌ Error: curl is required for update check"
        return 1
    fi

    echo "  Checking for updates..."
    echo ""

    # Fetch latest release from GitHub API
    local api_response latest_version latest_date
    api_response=$(curl -sf --max-time 10 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null)

    if [[ -z "$api_response" ]]; then
        # No releases yet, check tags
        api_response=$(curl -sf --max-time 10 "https://api.github.com/repos/${repo}/tags" 2>/dev/null)
        if [[ -n "$api_response" ]]; then
            latest_version=$(echo "$api_response" | grep -oP '"name":\s*"v?\K[0-9]+\.[0-9]+\.[0-9]+[^"]*' | head -1)
        fi
    else
        latest_version=$(echo "$api_response" | grep -oP '"tag_name":\s*"v?\K[0-9]+\.[0-9]+\.[0-9]+[^"]*' | head -1)
        latest_date=$(echo "$api_response" | grep -oP '"published_at":\s*"\K[^"]+' | head -1)
    fi

    if [[ -z "$latest_version" ]]; then
        echo "  ⚠️  Could not fetch latest version from GitHub"
        echo "  Check: https://github.com/${repo}/releases"
        return 1
    fi

    latest_version="${latest_version#v}"
    printf "  %-20s %s\n" "Latest version:" "v${latest_version}"
    [[ -n "$latest_date" ]] && printf "  %-20s %s\n" "Released:" "${latest_date%%T*}"
    echo ""

    # Compare versions
    local cmp_result=0
    if declare -f nftban_version_compare &>/dev/null; then
        nftban_version_compare "$current_version" "$latest_version"
        cmp_result=$?
    else
        # Simple comparison fallback
        if [[ "$current_version" == "$latest_version" ]]; then
            cmp_result=0
        elif [[ "$(printf '%s\n' "$current_version" "$latest_version" | sort -V | head -1)" == "$current_version" ]]; then
            cmp_result=1
        else
            cmp_result=2
        fi
    fi

    # Display result
    case $cmp_result in
        0)
            echo "  ✅ You are running the latest version!"
            ;;
        1)
            echo "  📦 UPDATE AVAILABLE!"
            echo ""
            echo "  To update, run one of:"
            echo "    • curl -fsSL https://get.nftban.com | sudo bash"
            echo "    • Visit: https://github.com/${repo}/releases/latest"
            return 2
            ;;
        2)
            echo "  🔧 You are running a development version (ahead of release)"
            ;;
    esac

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    return 0
}

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_version() {
    # Display version information
    # Usage: nftban version [--short|--numeric|--check|--json]

    local format="full"
    local json_output=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --short|-s|--brief|-b)
                format="short"
                shift
                ;;
            --numeric|-n)
                format="numeric"
                shift
                ;;
            --check|-c)
                format="check"
                shift
                ;;
            --update|-u)
                format="update"
                shift
                ;;
            --json|-j)
                json_output=true
                shift
                ;;
            --help|-h|help)
                nftban_cmd_version_usage
                return 0
                ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                nftban_cmd_version_usage
                return 1
                ;;
        esac
    done

    # Show banner (skip for JSON, short, and numeric output)
    if [[ "$json_output" != "true" ]] && [[ "$format" != "short" ]] && [[ "$format" != "numeric" ]]; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
            if [[ $(type -t nftban_banner) == "function" ]]; then
                nftban_banner
            fi
        fi
        echo ""
    fi

    # Output based on format
    if [[ "$json_output" == "true" ]]; then
        cat <<EOF
{
  "version": "${NFTBAN_VERSION}",
  "version_name": "${NFTBAN_VERSION_NAME}",
  "version_date": "${NFTBAN_VERSION_DATE}",
  "build_date": "${NFTBAN_BUILD_DATE}",
  "components": {
    "cli": "${NFTBAN_CLI_VERSION}",
    "core": "${NFTBAN_CORE_VERSION}",
    "gui": "${NFTBAN_GUI_VERSION}",
    "api": "${NFTBAN_API_VERSION}"
  },
  "requirements": {
    "bash_min": "${NFTBAN_MIN_BASH_VERSION}",
    "nftables_min": "${NFTBAN_MIN_NFT_VERSION}"
  }
}
EOF
    elif [[ "$format" == "short" ]]; then
        nftban_version_short
    elif [[ "$format" == "numeric" ]]; then
        nftban_version_numeric
    elif [[ "$format" == "check" ]]; then
        # Use proper conditional to avoid set -e triggering on non-zero return
        if nftban_version_check_requirements; then
            echo "✅ All requirements met"
            return 0
        else
            echo "❌ Requirements not met"
            return 1
        fi
    elif [[ "$format" == "update" ]]; then
        nftban_check_for_updates
        return $?
    else
        nftban_version_info
    fi

    # Completion marker for test validation (only on success path)
    echo "# NFTBAN_CMD_EXIT: version"
    return 0
}

nftban_cmd_version_usage() {
    cat <<EOF
Usage: nftban version [OPTIONS]

Display NFTBan version information.

OPTIONS:
  --short, -s       Show version number only (e.g., "1.0.0")
  --brief, -b       Alias for --short
  --numeric, -n     Show numeric version for comparison (e.g., "100")
  --check, -c       Check system requirements
  --update, -u      Check GitHub for newer version
  --json, -j        Output in JSON format
  --help, -h        Show this help message

EXAMPLES:
  nftban version                 # Show full version information
  nftban version --short         # Show version number only
  nftban version --brief         # Same as --short
  nftban version --json          # Get version in JSON format
  nftban version --check         # Check system requirements
  nftban version --update        # Check for updates from GitHub

SEE ALSO:
  nftban update                  # Update NFTBan (auto-detects install type)
  nftban update check            # Check if an update is available (no changes)
  nftban update status           # Show install method + update channel

EOF
}

# Export functions
export -f nftban_cmd_version
export -f nftban_cmd_version_usage
export -f nftban_check_for_updates

# =============================================================================
# EXECUTE IF RUN DIRECTLY
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_version "$@"
fi
