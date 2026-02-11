#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - CI Guard: Block Recursive Permissions
# =============================================================================
# meta:name="check-recursive-permissions"
# meta:type="tool"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Prevent introduction of recursive permission commands"
# meta:inventory.files=""
# meta:inventory.binaries="git,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# This script blocks:
#   - chmod -R (recursive mode changes)
#   - chown -R (recursive ownership changes)
#
# These are dangerous because:
#   1. They can change permissions on user-edited config files
#   2. They create race conditions with other processes
#   3. They bypass the canonical FHS spec
#
# Instead, use:
#   - systemd-tmpfiles for runtime directories
#   - Package %files or dh_installdirs for package directories
#   - Explicit per-file permissions for specific files
# =============================================================================

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

REPO_ROOT="$(git rev-parse --show-toplevel)"

# Files to check (staged files only)
# Exclude: this script, packaging/build_nftban.sh (legacy), and health_check.sh (contains grep patterns)
FILES=$(git diff --cached --name-only --diff-filter=ACMR | grep -E '\.(sh|spec|postinst|preinst|postrm|prerm)$' | grep -v 'check-recursive-permissions.sh' | grep -v 'packaging/build_nftban.sh' | grep -v 'health_check.sh' || true)

if [[ -z "$FILES" ]]; then
    echo -e "${GREEN}[OK]${NC} No shell/packaging files to check"
    exit 0
fi

ERRORS=0

echo "Checking for recursive permission commands..."

for file in $FILES; do
    filepath="${REPO_ROOT}/${file}"

    if [[ ! -f "$filepath" ]]; then
        continue
    fi

    # Check for chmod -R (various forms)
    if grep -n -E '(chmod\s+-R|chmod\s+--recursive)' "$filepath" 2>/dev/null; then
        echo -e "${RED}[ERROR]${NC} $file contains 'chmod -R'"
        echo "  Use explicit permissions or systemd-tmpfiles instead"
        ERRORS=$((ERRORS + 1))
    fi

    # Check for chown -R (various forms)
    if grep -n -E '(chown\s+-R|chown\s+--recursive)' "$filepath" 2>/dev/null; then
        echo -e "${RED}[ERROR]${NC} $file contains 'chown -R'"
        echo "  Use explicit ownership or systemd-tmpfiles instead"
        ERRORS=$((ERRORS + 1))
    fi
done

if [[ $ERRORS -gt 0 ]]; then
    echo ""
    echo -e "${RED}[FAILED]${NC} Found $ERRORS recursive permission command(s)"
    echo ""
    echo "Recursive chmod/chown is prohibited because:"
    echo "  1. It changes permissions on user-edited config files"
    echo "  2. It creates race conditions with running services"
    echo "  3. It bypasses the canonical FHS spec"
    echo ""
    echo "Solutions:"
    echo "  - Use systemd-tmpfiles for runtime dirs (/var/lib, /var/log, etc.)"
    echo "  - Use find with -maxdepth for first-level subdirs only"
    echo "  - Use explicit per-file permissions for specific files"
    echo ""
    echo "See: build/fhs-spec.yaml for canonical directory specifications"
    exit 1
fi

echo -e "${GREEN}[OK]${NC} No recursive permission commands found"
exit 0
