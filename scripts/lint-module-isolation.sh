#!/usr/bin/env bash
# =============================================================================
# NFTBan Module Isolation Lint (R-10)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="lint_module_isolation"
# meta:type="ci"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-12"
# meta:description="CI lint: enforce module-isolation invariants per V110 R-10"
# meta:input="None"
# meta:output="PASS/FAIL lint result to stdout"
# meta:depends="grep,awk,sort,uniq"
# meta:inventory.files="scripts/lint-module-isolation.sh"
# meta:inventory.binaries="grep,awk,sort,uniq"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Origin:
#   V110 R-10 isolation lint/test (REMEDIATION_PLAN.md §B / FM-J).
#   Workspace anchor: AUDIT_190_MODULE_ISOLATION/.
#   Recommended path per V110_MOD_ISOLATION_DELTA_AUDIT.md §5.
#
# Invariants enforced (all 3 MUST pass):
#   A1 — Distinct ModuleName across registered Module implementers
#        (rejects accidental name reuse across modules)
#   A2 — Every `eventbus.NewEvent(eventbus.EventBan, ...)` publish uses the
#        calling module's own ModuleName constant (rejects misattribution)
#   A3 — No NEW cross-module Status().Extra key reuse beyond the documented
#        baseline allowlist (locks current state; blocks regression)
#
# Scope:
#   - Scans internal/ for files containing `func (m *Module) Name() string`
#   - Auto-discovers registered Module implementers (no hardcoded list)
#
# Schema impact: NONE. Lint is repository-static; no metric or schema touch.
#
# Exit codes:
#   0  All invariants pass
#   1  One or more invariants violated
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

failures=0

# =============================================================================
# Auto-discover registered Module implementers
# =============================================================================
# A registered Module implementer has:
#   - `func (m *Module) Name() string { return ... }` (per internal/module/module.go)
#   - A package-level `ModuleName = "..."` constant
# =============================================================================

echo "=== Discovering registered Module implementers ==="
mapfile -t MODULE_FILES < <(grep -rl 'func (m \*Module) Name() string' internal/ 2>/dev/null | sort -u)

if [[ ${#MODULE_FILES[@]} -eq 0 ]]; then
    echo "::error::No Module implementers discovered in internal/ — lint cannot run"
    exit 1
fi

echo "Discovered ${#MODULE_FILES[@]} Module implementer(s):"
for f in "${MODULE_FILES[@]}"; do
    echo "  - $f"
done
echo

# =============================================================================
# A1: Distinct ModuleName across all Module implementers
# =============================================================================
# Rejects: two modules sharing the same Name() identity (collision).
# =============================================================================

echo "=== A1: Distinct ModuleName ==="
a1_violations=0

declare -A module_names
for f in "${MODULE_FILES[@]}"; do
    # Extract the ModuleName constant declaration (allow extra whitespace + comments)
    name=$(grep -E '^\s*ModuleName\s*=\s*"[^"]+"' "$f" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    if [[ -z "$name" ]]; then
        echo "::error file=$f::A1 — file declares func (m *Module) Name() but no ModuleName const found"
        a1_violations=$((a1_violations + 1))
        continue
    fi
    if [[ -n "${module_names[$name]:-}" ]]; then
        echo "::error file=$f::A1 — ModuleName \"$name\" collides with ${module_names[$name]}"
        a1_violations=$((a1_violations + 1))
    else
        module_names[$name]="$f"
        echo "  ✓ $f → ModuleName=\"$name\""
    fi
done

if [[ $a1_violations -gt 0 ]]; then
    echo "::error::A1 failed: $a1_violations distinct-ModuleName violation(s)"
    failures=$((failures + a1_violations))
else
    echo "✓ A1: ${#module_names[@]} distinct ModuleName(s) confirmed"
fi
echo

# =============================================================================
# A2: EventBan publish uses module-owned source label
# =============================================================================
# Every `eventbus.NewEvent(eventbus.EventBan, <arg>)` publish in a Module
# implementer file must pass that file's own ModuleName constant as <arg>.
# Rejects: cross-attribution (e.g., loginmon publishing EventBan with
# ModuleName from ddos), or empty/literal-string sources.
# =============================================================================

echo "=== A2: EventBan source label ==="
a2_violations=0

# Build map: module_dir → ModuleName for quick lookup
declare -A dir_to_name
for f in "${MODULE_FILES[@]}"; do
    dir=$(dirname "$f")
    name=$(grep -E '^\s*ModuleName\s*=\s*"[^"]+"' "$f" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
    dir_to_name[$dir]="$name"
done

# Scan every Module-implementer dir for EventBan publishes
for f in "${MODULE_FILES[@]}"; do
    dir=$(dirname "$f")
    expected_name="${dir_to_name[$dir]}"
    # Find all files in the module dir that publish EventBan
    while IFS=: read -r src lineno content; do
        # Extract the second argument to NewEvent(eventbus.EventBan, <arg>)
        # Patterns covered:
        #   NewEvent(eventbus.EventBan, ModuleName)
        #   NewEvent(eventbus.EventBan, ModuleName).
        arg=$(echo "$content" | sed -nE 's/.*NewEvent\(eventbus\.EventBan,\s*([A-Za-z_][A-Za-z0-9_]*)[\)\.,].*/\1/p')
        if [[ -z "$arg" ]]; then
            # Try to extract a string literal (which would be a violation — must use the const)
            literal=$(echo "$content" | sed -nE 's/.*NewEvent\(eventbus\.EventBan,\s*"([^"]+)"[\)\.,].*/\1/p')
            if [[ -n "$literal" ]]; then
                echo "::error file=$src,line=$lineno::A2 — EventBan publish uses string literal \"$literal\" (must use module's ModuleName const)"
                a2_violations=$((a2_violations + 1))
            fi
            continue
        fi
        if [[ "$arg" != "ModuleName" ]]; then
            echo "::error file=$src,line=$lineno::A2 — EventBan publish in $expected_name module uses identifier \"$arg\" (must use ModuleName const for this module)"
            a2_violations=$((a2_violations + 1))
        fi
    done < <(grep -rn 'NewEvent(eventbus\.EventBan,' "$dir"/ 2>/dev/null || true)
done

if [[ $a2_violations -gt 0 ]]; then
    echo "::error::A2 failed: $a2_violations EventBan-source-label violation(s)"
    failures=$((failures + a2_violations))
else
    echo "✓ A2: all EventBan publishes use module-owned ModuleName const"
fi
echo

# =============================================================================
# A3: Status().Extra cross-module check
# =============================================================================
# Locks the current baseline of cross-module Extra-key reuse and blocks NEW
# cross-module key introductions. The baseline allowlist captures keys that
# are legitimately shared concepts across modules at v1.109.0 HEAD.
# Future shared-concept additions require deliberate allowlist update.
#
# Baseline as of v1.109.0 (commit 25746b93; verified 2026-05-12):
#   mode                  — ddos, portscan, loginmon
#   suricata_available    — ddos, portscan, loginmon
#   tracked_ips           — loginmon, botguard
# =============================================================================

echo "=== A3: Status.Extra cross-module check ==="
a3_violations=0

# Documented baseline of shared concepts (intentional cross-module reuse).
# Adding new entries here is a deliberate decision requiring code review.
BASELINE_ALLOWLIST=(
    "mode"
    "suricata_available"
    "tracked_ips"
)

is_allowlisted() {
    local key="$1"
    local entry
    for entry in "${BASELINE_ALLOWLIST[@]}"; do
        if [[ "$entry" == "$key" ]]; then
            return 0
        fi
    done
    return 1
}

# For each module, collect its Extra keys
declare -A key_owners  # key → space-separated list of module names that write it

for f in "${MODULE_FILES[@]}"; do
    dir=$(dirname "$f")
    name="${dir_to_name[$dir]}"
    # Match: m.status.Extra["KEY"] = ... or m.Extra["KEY"] = ...
    while IFS= read -r line; do
        key=$(echo "$line" | sed -nE 's/.*Extra\["([^"]+)"\]\s*=.*/\1/p')
        [[ -z "$key" ]] && continue
        # Record this module as a writer of this key
        existing="${key_owners[$key]:-}"
        if [[ -z "$existing" ]]; then
            key_owners[$key]="$name"
        elif ! grep -qw "$name" <<<"$existing"; then
            key_owners[$key]="$existing $name"
        fi
    done < <(grep -rh 'Extra\["[^"]\+"\]\s*=' "$dir"/ 2>/dev/null || true)
done

# Check for cross-module reuse outside the allowlist
for key in "${!key_owners[@]}"; do
    owners="${key_owners[$key]}"
    # Count distinct owner words
    count=$(echo "$owners" | tr ' ' '\n' | sort -u | grep -c .)
    if [[ $count -gt 1 ]]; then
        if is_allowlisted "$key"; then
            echo "  ◦ baseline-allowed: \"$key\" shared by: $owners"
        else
            echo "::error::A3 — cross-module Extra key \"$key\" written by multiple modules ($owners); add to BASELINE_ALLOWLIST if intentional, or rename in one of the modules"
            a3_violations=$((a3_violations + 1))
        fi
    fi
done

if [[ $a3_violations -gt 0 ]]; then
    echo "::error::A3 failed: $a3_violations new cross-module Extra-key collision(s)"
    failures=$((failures + a3_violations))
else
    echo "✓ A3: no new cross-module Extra-key collisions (${#BASELINE_ALLOWLIST[@]} baseline keys allowlisted)"
fi
echo

# =============================================================================
# Summary
# =============================================================================

if [[ $failures -gt 0 ]]; then
    echo "::error::R-10 module-isolation lint FAILED with $failures violation(s)"
    exit 1
fi

echo "✓ R-10 module-isolation lint PASSED (A1 + A2 + A3)"
exit 0
