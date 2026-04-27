#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - CLI Help Validation Script
# =============================================================================
# meta:name="validate_cli_help"
# meta:type="script"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Validates that all CLI commands have proper help functions"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Usage: ./validate_cli_help.sh
#
# Exit codes:
#   0 - All commands have help functions
#   N - Number of commands missing help
# =============================================================================

set -Eeuo pipefail

CLI_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/cli"

# Fallback for development environment: resolve repo-relative cli/lib path
# from the script's own location so this works on any clone.
if [[ ! -d "$CLI_DIR" ]]; then
    _self_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
    CLI_DIR="${_self_dir}/../cli/lib/nftban/cli"
fi

if [[ ! -d "$CLI_DIR" ]]; then
    echo "ERROR: CLI directory not found: $CLI_DIR" >&2
    exit 1
fi

echo "=============================================="
echo "NFTBan CLI Help Function Validation"
echo "=============================================="
echo ""
echo "Directory: $CLI_DIR"
echo ""

total=0
missing=0
ok=0

declare -a missing_cmds=()

for cmd_file in "$CLI_DIR"/cmd_*.sh; do
    ((total++))

    cmd_name=$(basename "$cmd_file" .sh | sed 's/cmd_//' | sed 's/_/-/g')
    func_name="${cmd_name//-/_}"

    # Check for any help function pattern
    has_help=false

    for pattern in \
        "_nftban_${func_name}_help()" \
        "show_${func_name}_help()" \
        "show_usage()" \
        "_${func_name}_help()" \
        "${func_name}_help()"
    do
        if grep -q "^${pattern%()}()" "$cmd_file" 2>/dev/null || \
           grep -q "^function ${pattern%()}" "$cmd_file" 2>/dev/null; then
            has_help=true
            break
        fi
    done

    if [[ "$has_help" == "true" ]]; then
        echo "✓ $cmd_name"
        ((ok++))
    else
        echo "✗ $cmd_name - MISSING help function"
        ((missing++))
        missing_cmds+=("$cmd_name")
    fi
done

echo ""
echo "=============================================="
echo "Summary"
echo "=============================================="
echo "Total commands:  $total"
echo "With help:       $ok"
echo "Missing help:    $missing"
echo ""

if [[ $missing -gt 0 ]]; then
    echo "Commands missing help functions:"
    for cmd in "${missing_cmds[@]}"; do
        echo "  - $cmd"
    done
    echo ""
    echo "To add help, create a function in the command file:"
    echo ""
    echo '  _nftban_<command>_help() {'
    echo '      cat <<'\''HELP'\'''
    echo '  USAGE:'
    echo '      nftban <command> [options]'
    echo '  ...'
    echo '  HELP'
    echo '  }'
    echo ""
fi

exit $missing
