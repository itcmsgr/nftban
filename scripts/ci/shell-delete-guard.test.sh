#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.100.4 — H3.3 Shell-Delete Guard self-test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="ci-shell-delete-guard-test"
# meta:type="ci-script-test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-02"
# meta:description="Self-test for H3.3 shell-delete guard: FAIL-path simulation"
# meta:inventory.files="scripts/ci/shell-delete-guard.test.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars="GITHUB_PR_TITLE, GITHUB_PR_BODY, BASE_REF"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
#
# Exercises the H3.3 guard against synthetic deletion scenarios in a
# throwaway clone of the repo. Verifies the gate FAILs when it should and
# PASSes when it should. Doc-only validation.
#
# Usage: bash scripts/ci/shell-delete-guard.test.sh
# =============================================================================
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

WORK=$(mktemp -d -t h33-selftest.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

declare -i T_PASS=0
declare -i T_FAIL=0

# scenario: simulate deletion(s) on a fresh branch from main, run guard,
# compare exit to expected.
scenario() {
    local label="$1" expect="$2" title="$3" body="$4"
    shift 4
    local deletes=("$@")

    local sub="$WORK/$label"
    git clone --quiet "$REPO_ROOT" "$sub"
    (
        cd "$sub"
        git config user.email selftest@nftban.local
        git config user.name selftest
        # Make sure 'main' exists locally for the guard's BASE_REF=main lookup
        git fetch --quiet origin main >/dev/null 2>&1 || true
        git branch -f main origin/main >/dev/null 2>&1 || true
        git checkout -b selftest-branch >/dev/null 2>&1
        for f in "${deletes[@]}"; do
            if [ -f "$f" ]; then
                git rm -q "$f"
            fi
        done
        git commit --quiet -m "selftest: simulate deletion" --allow-empty
    )

    local got_exit=0
    (
        cd "$sub"
        GITHUB_PR_TITLE="$title" GITHUB_PR_BODY="$body" \
            bash "$REPO_ROOT/scripts/ci/shell-delete-guard.sh" main
    ) > "$WORK/$label.out" 2>&1 || got_exit=$?

    local verdict
    if [ "$expect" = "PASS" ]; then
        if [ "$got_exit" -eq 0 ]; then verdict="OK   (PASS as expected)"; T_PASS=$((T_PASS+1))
        else verdict="FAIL (expected PASS, got FAIL — see $WORK/$label.out)"; T_FAIL=$((T_FAIL+1)); fi
    else
        if [ "$got_exit" -ne 0 ]; then verdict="OK   (FAIL as expected)"; T_PASS=$((T_PASS+1))
        else verdict="FAIL (expected FAIL, got PASS — see $WORK/$label.out)"; T_FAIL=$((T_FAIL+1)); fi
    fi
    printf "%-55s expect=%-4s got_exit=%d  %s\n" "$label" "$expect" "$got_exit" "$verdict"
}

echo "============================================================"
echo "H3.3 self-test — synthetic deletion scenarios"
echo "============================================================"

# --- PASS scenarios ---
scenario "no-deletions" "PASS" "" ""

# --- FAIL scenarios ---
scenario "drop-cmd_ban-no-marker" "FAIL" \
    "feat: drop cmd_ban shell" "" \
    "cli/lib/nftban/cli/cmd_ban.sh"

scenario "drop-cmd_panel-no-marker" "FAIL" \
    "wip" "" \
    "cli/lib/nftban/cli/cmd_panel.sh"

scenario "drop-runtime-creator-with-marker-still-fails" "FAIL" \
    "[MIGRATION-LANE-AUTHORIZED] migrate firewall driver" \
    "Migration of firewall rebuild driver to Go" \
    "cli/lib/nftban/cli/cmd_firewall.sh"

scenario "drop-shared-lib-no-marker" "FAIL" \
    "refactor: drop autoheal" "" \
    "cli/lib/nftban/helpers/autoheal.sh"

scenario "drop-cmd_ban-deprecated-marker-doc-says-shell-owned" "FAIL" \
    "[DEPRECATED-REMOVAL] cleanup operator-facing ban" "" \
    "cli/lib/nftban/cli/cmd_ban.sh"

# --- PASS scenarios with proper authorization ---
# A migration-marker PR with same-PR doc update + Go replacement.
# We simulate by creating a fake Go file + doc-modify in the same branch.
scenario_with_replacement_and_doc() {
    local label="$1" expect="$2" title="$3" body="$4"
    local deleted_file="$5"

    local sub="$WORK/$label"
    git clone --quiet "$REPO_ROOT" "$sub"
    (
        cd "$sub"
        git config user.email selftest@nftban.local
        git config user.name selftest
        git fetch --quiet origin main >/dev/null 2>&1 || true
        git branch -f main origin/main >/dev/null 2>&1 || true
        git checkout -b selftest-branch >/dev/null 2>&1
        # Delete the protected file
        git rm -q "$deleted_file"
        # Add a synthetic Go replacement
        mkdir -p internal/installer/replacement_for_test
        echo "package replacement_for_test" > internal/installer/replacement_for_test/r.go
        # Modify the doc (any change qualifies as "in diff")
        echo >> docs/MIGRATION_COVERAGE.md
        echo "## H3.3 self-test marker — $label" >> docs/MIGRATION_COVERAGE.md
        git add internal/installer/replacement_for_test/r.go docs/MIGRATION_COVERAGE.md
        git commit --quiet -m "selftest: simulate authorized migration"
    )

    local got_exit=0
    (
        cd "$sub"
        GITHUB_PR_TITLE="$title" GITHUB_PR_BODY="$body" \
            bash "$REPO_ROOT/scripts/ci/shell-delete-guard.sh" main
    ) > "$WORK/$label.out" 2>&1 || got_exit=$?

    local verdict
    if [ "$expect" = "PASS" ]; then
        if [ "$got_exit" -eq 0 ]; then verdict="OK   (PASS as expected)"; T_PASS=$((T_PASS+1))
        else verdict="FAIL (expected PASS, got FAIL — see $WORK/$label.out)"; T_FAIL=$((T_FAIL+1)); fi
    else
        if [ "$got_exit" -ne 0 ]; then verdict="OK   (FAIL as expected)"; T_PASS=$((T_PASS+1))
        else verdict="FAIL (expected FAIL, got PASS — see $WORK/$label.out)"; T_FAIL=$((T_FAIL+1)); fi
    fi
    printf "%-55s expect=%-4s got_exit=%d  %s\n" "$label" "$expect" "$got_exit" "$verdict"
}

scenario_with_replacement_and_doc "authorized-migration-cmd_ban-passes" "PASS" \
    "[MIGRATION-LANE-AUTHORIZED] migrate cmd_ban to Go" "" \
    "cli/lib/nftban/cli/cmd_ban.sh"

echo "============================================================"
echo "Self-test summary: $T_PASS scenarios match expected verdict; $T_FAIL mismatches."
if [ "$T_FAIL" -ne 0 ]; then
    echo "H3.3 self-test: FAIL"
    exit 1
fi
echo "H3.3 self-test: PASS"
exit 0
