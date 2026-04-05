#!/usr/bin/env bash
# =============================================================================
# NFTBan Registry Parity Lint (G15)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="lint_registry_parity"
# meta:type="ci"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-05"
# meta:description="CI lint: verify commands.registry.yml entries have matching CLI handler, man page, and completion"
# meta:input="None"
# meta:output="PASS/FAIL lint result to stdout"
# meta:depends=""
# meta:inventory.files="scripts/lint-registry-parity.sh"
# meta:inventory.binaries="grep,sed"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Gates:
#   G15: Every command in registry has a matching bash completion entry
#
# Exit codes:
#   0  All checks passed
#   1  One or more gaps found
# =============================================================================

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGISTRY="$REPO_ROOT/commands.registry.yml"
COMPLETION="$REPO_ROOT/install/bash-completion/nftban"
MANPAGE="$REPO_ROOT/install/man/man8/nftban.8"

# Meta entries to skip (not actual commands)
SKIP_ENTRIES="global_options standard_params"

errors=0

echo "=== Registry Parity Lint (G15) ==="
echo ""

# Extract top-level command names from registry
mapfile -t registry_cmds < <(grep -E '^[a-z][a-z_-]+:$' "$REGISTRY" | sed 's/:$//')

# Extract completion commands list
completion_cmds=$(grep -m1 'local commands=' "$COMPLETION" | sed 's/.*local commands="//;s/".*//')

echo "Registry commands: ${#registry_cmds[@]}"
echo "Checking parity..."
echo ""

# G15-A: Every registry command must appear in bash completion
echo "--- G15-A: Completion parity ---"
comp_gaps=0
for cmd in "${registry_cmds[@]}"; do
    # Skip meta entries
    skip=false
    for s in $SKIP_ENTRIES; do
        [[ "$cmd" == "$s" ]] && skip=true
    done
    $skip && continue

    if ! echo " $completion_cmds " | grep -qw "$cmd"; then
        echo "  FAIL: '$cmd' in registry but missing from completion"
        ((comp_gaps++)) || true
    fi
done

if [[ $comp_gaps -eq 0 ]]; then
    echo "  ✓ All registry commands found in completion"
else
    echo "  ✗ $comp_gaps command(s) missing from completion"
    ((errors += comp_gaps)) || true
fi

# G15-B: Every registry command should appear in man page
echo ""
echo "--- G15-B: Man page parity ---"
man_gaps=0
for cmd in "${registry_cmds[@]}"; do
    skip=false
    for s in $SKIP_ENTRIES; do
        [[ "$cmd" == "$s" ]] && skip=true
    done
    $skip && continue

    # Man page uses .B command or .B command \fR patterns
    # Hyphens in troff are escaped as \- so check both forms
    man_cmd="${cmd//-/\\-}"
    if ! grep -qE "^\.B ${cmd}( |$)" "$MANPAGE" 2>/dev/null && \
       ! grep -qF ".B ${man_cmd}" "$MANPAGE" 2>/dev/null; then
        echo "  WARN: '$cmd' in registry but not documented in man page"
        ((man_gaps++)) || true
    fi
done

if [[ $man_gaps -eq 0 ]]; then
    echo "  ✓ All registry commands found in man page"
else
    echo "  ⚠ $man_gaps command(s) not in man page (warnings only)"
fi

echo ""
if [[ $errors -gt 0 ]]; then
    echo "✗ Registry parity lint: FAIL ($errors error(s))"
    exit 1
else
    echo "✓ Registry parity lint: PASS"
    if [[ $man_gaps -gt 0 ]]; then
        echo "  ($man_gaps man page warning(s) — non-blocking)"
    fi
    exit 0
fi
