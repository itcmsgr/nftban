#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - CI Gate: nft Write Detection
# =============================================================================
# meta:name="check-nft-writes"
# meta:type="script"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Enforce single-writer architecture for nftables operations"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# TWO-TIER ENFORCEMENT:
#   WRITE operations - ENFORCED (blocks PR when not in allowed paths)
#   READ operations  - WARNED (allowed temporarily during migration)
#
# Exit codes:
#   0 = No WRITE violations (READ warnings don't fail)
#   1 = WRITE violations found (PR must not merge)
#
# Usage:
#   ./scripts/ci/check-nft-writes.sh              # Enforce writes, warn reads
#   ./scripts/ci/check-nft-writes.sh --warn-all   # Warn only (migration mode)
# =============================================================================

set -Eeuo pipefail

# Mode
WARN_ALL=0
[[ "${1:-}" == "--warn-all" ]] && WARN_ALL=1

# =============================================================================
# PATTERNS
# =============================================================================

# WRITE operations - these MUST go through daemon (ENFORCED)
# Matches: nft add, nft delete, nft flush, nft insert, nft create, nft destroy, nft replace
NFT_WRITE_PATTERN='nft[[:space:]]+(add|delete|flush|insert|create|destroy|replace)[[:space:]]'

# Also catch: nft -f (apply ruleset)
NFT_APPLY_PATTERN='nft[[:space:]]+-[cfj]*f[[:space:]]'

# Go exec.Command patterns for writes
# Catches: add, delete, flush, insert, create
# Note: "-f" is handled separately to exclude "-c", "-f" (validation only)
GO_WRITE_PATTERN='exec\.Command\("nft".*"(add|delete|flush|insert|create)"'
GO_APPLY_PATTERN='exec\.Command\("nft",\s*"-f"'

# READ operations - allowed temporarily but should migrate (WARNED)
# Matches: nft list, nft get
NFT_READ_PATTERN='nft[[:space:]]+(list|get)[[:space:]]'

# Allowed paths (daemon implementation + emergency fallback)
ALLOWED_REGEX='^(cmd/nftband/|internal/nftbackend/|scripts/ci/|cli/lib/nftban/lib/nft_ipc\.sh)'

# =============================================================================
# MAIN
# =============================================================================

echo "========================================"
echo "NFTBan Architecture Check: nft Operations"
echo "========================================"
echo ""
echo "Policy: All nft WRITE operations must go through nftband daemon"
echo "See: ARCHITECTURE-NFT-POLICY.md"
echo ""

WRITE_FILE=$(mktemp)
READ_FILE=$(mktemp)
trap 'rm -f "$WRITE_FILE" "$READ_FILE"' EXIT

# -----------------------------------------------------------------------------
# WRITE VIOLATIONS (ENFORCED)
# -----------------------------------------------------------------------------

echo "Scanning for WRITE violations..."

# Shell: nft add/delete/flush/insert/create/destroy/replace
grep -rn -E "$NFT_WRITE_PATTERN" \
    --include="*.sh" \
    cli/ pkg/ install/ 2>/dev/null | \
    grep -v -E "$ALLOWED_REGEX" | \
    grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' | \
    grep -v -E 'echo.*nft[[:space:]]+(add|delete|flush)' | \
    grep -v -E 'printf.*nft[[:space:]]+(add|delete|flush)' \
    >> "$WRITE_FILE" || true

# Shell: nft -f (apply ruleset)
grep -rn -E "$NFT_APPLY_PATTERN" \
    --include="*.sh" \
    cli/ pkg/ install/ 2>/dev/null | \
    grep -v -E "$ALLOWED_REGEX" | \
    grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' \
    >> "$WRITE_FILE" || true

# Go: exec.Command("nft", "add/delete/flush...")
grep -rn -E "$GO_WRITE_PATTERN" \
    --include="*.go" \
    pkg/ cmd/ 2>/dev/null | \
    grep -v -E "$ALLOWED_REGEX" \
    >> "$WRITE_FILE" || true

# Go: exec.Command("nft", "-f", ...) but NOT "-c", "-f" (validation)
grep -rn -E "$GO_APPLY_PATTERN" \
    --include="*.go" \
    pkg/ cmd/ 2>/dev/null | \
    grep -v -E "$ALLOWED_REGEX" | \
    grep -v '"-c"' \
    >> "$WRITE_FILE" || true

# Deduplicate
sort -u "$WRITE_FILE" -o "$WRITE_FILE"
WRITE_COUNT=$(wc -l < "$WRITE_FILE" | tr -d ' ')

# -----------------------------------------------------------------------------
# READ VIOLATIONS (WARNED)
# -----------------------------------------------------------------------------

echo "Scanning for READ operations (informational)..."

grep -rn -E "$NFT_READ_PATTERN" \
    --include="*.sh" \
    cli/ pkg/ install/ 2>/dev/null | \
    grep -v -E "$ALLOWED_REGEX" | \
    grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' \
    >> "$READ_FILE" || true

sort -u "$READ_FILE" -o "$READ_FILE"
READ_COUNT=$(wc -l < "$READ_FILE" | tr -d ' ')

# =============================================================================
# OUTPUT
# =============================================================================

echo ""
echo "========================================"
echo "RESULTS"
echo "========================================"
echo ""

# WRITE violations
if [[ "$WRITE_COUNT" -gt 0 ]]; then
    echo "WRITE VIOLATIONS: $WRITE_COUNT (MUST FIX)"
    echo "----------------------------------------"
    echo "Files with WRITE violations:"
    cut -d: -f1 "$WRITE_FILE" | sort | uniq -c | sort -rn | while read -r count file; do
        echo "  $file ($count)"
    done
    echo ""
    echo "Details:"
    cat "$WRITE_FILE"
    echo ""
else
    echo "WRITE VIOLATIONS: 0 (PASS)"
fi

echo ""

# READ warnings
if [[ "$READ_COUNT" -gt 0 ]]; then
    echo "READ OPERATIONS: $READ_COUNT (info only, not enforced)"
    echo "----------------------------------------"
    echo "Files with direct nft reads:"
    cut -d: -f1 "$READ_FILE" | sort | uniq -c | sort -rn | head -10 | while read -r count file; do
        echo "  $file ($count)"
    done
    echo "  (showing top 10, $READ_COUNT total)"
else
    echo "READ OPERATIONS: 0"
fi

echo ""
echo "========================================"

# =============================================================================
# EXIT CODE
# =============================================================================

if [[ "$WRITE_COUNT" -eq 0 ]]; then
    echo "RESULT: PASS - No WRITE violations"
    echo ""
    exit 0
fi

# WRITE violations exist
echo ""
echo "To fix WRITE violations:"
echo "  1. For bash: use nft_ipc_* functions from lib/nft_ipc.sh"
echo "  2. For Go: use pkg/ipc.Client{}.Call()"
echo "  3. For bulk operations: use nft_ipc_apply_ruleset with .nft files"
echo ""
echo "See: ARCHITECTURE-NFT-POLICY.md"
echo ""

if [[ "$WARN_ALL" -eq 1 ]]; then
    echo "MODE: --warn-all (migration in progress, not enforced)"
    exit 0
else
    echo "MODE: ENFORCED (PR will fail)"
    exit 1
fi
