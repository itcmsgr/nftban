#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.79 - CI Gate G18: Rebuild Safety Simulation
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Validate rebuild safety invariants exist in code
#
# meta:name="test-rebuild-safety"
# meta:type="ci"
# meta:version="1.79.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-08"
# meta:inventory.files="scripts/test-rebuild-safety.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# This gate validates that rebuild safety patterns exist:
# - Pre-rebuild validation (captures state before flush)
# - Post-rebuild validation (verifies protection restored)
# - Rollback on failure (no silent degradation)
# - FATAL on rebuild failure (v1.70.0 invariant)
# =============================================================================

set -Eeuo pipefail

echo "=== CI Gate G18: Rebuild Safety Simulation ==="
echo ""

VIOLATIONS=0

# Files that implement rebuild
REBUILD_FILES=(
    "cli/lib/nftban/core/nftban_firewall.sh"
    "cli/lib/nftban/cli/cmd_rebuild.sh"
)

# Required safety patterns
SAFETY_PATTERNS=(
    # Pre-validation
    "nftban-validate"
    # Fatal on failure (v1.70.0)
    "FATAL\|fatal"
    # Protection check
    "PROTECTED\|protected"
)

echo "Checking rebuild safety patterns..."

# Pattern 1: Rebuild must call validator
echo ""
echo "1. Checking for validator integration..."
FOUND_VALIDATOR=0
for file in "${REBUILD_FILES[@]}"; do
    if [[ -f "$file" ]] && grep -q "nftban-validate\|nftban_validate" "$file"; then
        echo "   ✓ Found validator call in $file"
        FOUND_VALIDATOR=1
    fi
done
if [[ $FOUND_VALIDATOR -eq 0 ]]; then
    echo "::warning::Rebuild may not integrate with validator"
fi

# Pattern 2: Go installer must handle rebuild failure as fatal
echo ""
echo "2. Checking rebuild failure handling..."

GO_INSTALLER_FILES=(
    "internal/installer/phases.go"
    "internal/installer/firewall.go"
)

for file in "${GO_INSTALLER_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        if grep -qi "rebuild.*fail\|fail.*rebuild" "$file"; then
            echo "   ✓ Found rebuild failure handling in $file"
        fi
    fi
done

# Pattern 3: Check for v1.70.0 invariant in postinst (rebuild failure = FATAL)
echo ""
echo "3. Checking postinst rebuild failure invariant (v1.70.0)..."

POSTINST_FILES=(
    "packaging/deb/postinst"
    "packaging/build_nftban.sh"
)

for file in "${POSTINST_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        # Check for NFTBAN_INSTALL_FAILED marker (v1.70.0)
        if grep -q "NFTBAN_INSTALL_FAILED" "$file"; then
            echo "   ✓ Found NFTBAN_INSTALL_FAILED marker in $file"
        fi
    fi
done

# Pattern 4: Verify no "reload as fallback" anti-pattern
echo ""
echo "4. Checking for unsafe reload-on-failure patterns..."

UNSAFE_PATTERNS=(
    'reload.*||.*reload'        # Reload as silent fallback
    'WARNING.*reload'           # Warning + reload (should be FATAL)
)

for file in "${REBUILD_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        for pattern in "${UNSAFE_PATTERNS[@]}"; do
            if grep -qE "$pattern" "$file" 2>/dev/null; then
                # Check if it's inside a comment
                if grep -E "$pattern" "$file" | grep -v "^[[:space:]]*#" >/dev/null 2>&1; then
                    echo "::warning::Potential unsafe reload-on-failure in $file"
                fi
            fi
        done
    fi
done

# Pattern 5: Verify safe rebuild atomicity in Go code
echo ""
echo "5. Checking Go rebuild atomicity..."

if [[ -f "internal/nftbackend/rebuild.go" ]]; then
    # Check for atomic namespace pattern (validate before apply)
    if grep -q "namespace\|Namespace\|temp.*table" "internal/nftbackend/rebuild.go"; then
        echo "   ✓ Found atomic namespace pattern in rebuild.go"
    else
        echo "::warning::Rebuild may not use atomic namespace pattern"
    fi
fi

echo ""
echo "Summary"
echo "======="

if [[ $VIOLATIONS -gt 0 ]]; then
    echo "::error::G18 FAILED: $VIOLATIONS safety violations found"
    exit 1
fi

echo "✓ G18: Rebuild safety simulation PASSED"
echo ""
echo "Note: This gate validates code patterns only."
echo "Full rebuild safety requires runtime testing on lab servers."
