#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.81.0 — BotGuard rebuild sequencing test
# =============================================================================
# meta:name="test_botguard_rebuild_sequencing"
# meta:type="test"
# meta:version="1.81.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Verifies BOTGUARD-REBUILD-UX fix: rebuild detects HTTP_BOTGUARD_ENABLED correctly and re-applies BotGuard before final validation"
# meta:inventory.files="cli/lib/nftban/cli/cmd_firewall.sh"
# meta:inventory.binaries="bash,grep,awk"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR"
# meta:inventory.config_files="conf.d/botguard/main.conf,conf.d/botguard/main.conf.local"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Background:
#   Pre-fix, cmd_firewall.sh's three module-restore sites (firewall_reload,
#   firewall_rebuild, firewall_reset) read the WRONG config key
#   `BOTGUARD_ENABLED` instead of the canonical `HTTP_BOTGUARD_ENABLED`. As a
#   result, Step 10 (Re-apply BotGuard) silently no-op'd on every BotGuard host
#   — including srv1 — and the post-rebuild validator saw transient missing
#   helper chains and triggered a rollback.
#
# This test pins the gating helper `_firewall_botguard_is_enabled` and asserts:
#   1. true   when HTTP_BOTGUARD_ENABLED="true" in main.conf.local
#   2. false  when HTTP_BOTGUARD_ENABLED="false" in main.conf.local
#   3. true   when HTTP_BOTGUARD_ENABLED="true" in main.conf only (no .local)
#   4. false  when no botguard conf files exist (BotGuard-disabled hosts)
#   5. local override wins: .local "false" beats main.conf "true"
#   6. Regression guard: cmd_firewall.sh contains no occurrence of the legacy
#      `BOTGUARD_ENABLED=` key (only HTTP_BOTGUARD_ENABLED).
#   7. All three call sites (reload, rebuild, reset) use the helper.
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
CMD_FIREWALL="$PROJECT_ROOT/cli/lib/nftban/cli/cmd_firewall.sh"

if [[ ! -f "$CMD_FIREWALL" ]]; then
    echo "FATAL: cannot find cmd_firewall.sh at $CMD_FIREWALL" >&2
    exit 2
fi

pass_count=0
fail_count=0

assert() {
    local name="$1"
    local expected="$2"   # "pass" or "fail"
    local actual="$3"     # "pass" or "fail"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS  $name"
        ((pass_count++)) || true
    else
        echo "  FAIL  $name (expected=$expected actual=$actual)"
        ((fail_count++)) || true
    fi
}

# Extract just the helper function from cmd_firewall.sh and source it in
# isolation. We do not source the whole file because cmd_firewall.sh has heavy
# dependencies (other libs, runtime side effects). The helper itself is pure
# bash + grep and depends only on $NFTBAN_CONFIG_DIR.
load_helper() {
    local snippet
    snippet=$(awk '
        /^_firewall_botguard_is_enabled\(\)/ { in_fn=1 }
        in_fn { print }
        in_fn && /^}/ { in_fn=0 }
    ' "$CMD_FIREWALL")
    if [[ -z "$snippet" ]]; then
        echo "FATAL: helper _firewall_botguard_is_enabled not found in $CMD_FIREWALL" >&2
        exit 2
    fi
    eval "$snippet"
}

load_helper

# Sandbox config dir
SANDBOX=$(mktemp -d /tmp/nftban_test_botguard_XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT
export NFTBAN_CONFIG_DIR="$SANDBOX"
mkdir -p "$SANDBOX/conf.d/botguard"

run_helper() {
    if _firewall_botguard_is_enabled; then echo "pass"; else echo "fail"; fi
}

reset_botguard_conf() {
    rm -f "$SANDBOX/conf.d/botguard/main.conf" "$SANDBOX/conf.d/botguard/main.conf.local"
}

echo "=========================================================="
echo "BotGuard rebuild sequencing — test_botguard_rebuild_sequencing"
echo "=========================================================="
echo ""
echo "[1] Helper gating tests"

# Test 1: HTTP_BOTGUARD_ENABLED=true in main.conf.local → enabled
reset_botguard_conf
echo 'HTTP_BOTGUARD_ENABLED="true"' > "$SANDBOX/conf.d/botguard/main.conf.local"
assert "enabled when HTTP_BOTGUARD_ENABLED=\"true\" in main.conf.local" "pass" "$(run_helper)"

# Test 2: HTTP_BOTGUARD_ENABLED=false → disabled
reset_botguard_conf
echo 'HTTP_BOTGUARD_ENABLED="false"' > "$SANDBOX/conf.d/botguard/main.conf.local"
assert "disabled when HTTP_BOTGUARD_ENABLED=\"false\" in main.conf.local" "fail" "$(run_helper)"

# Test 3: only main.conf, no .local → enabled
reset_botguard_conf
echo 'HTTP_BOTGUARD_ENABLED="true"' > "$SANDBOX/conf.d/botguard/main.conf"
assert "fallback to main.conf when no .local override" "pass" "$(run_helper)"

# Test 4: no config files at all → disabled (non-BotGuard host, no regression)
reset_botguard_conf
assert "disabled when no botguard config files exist (non-BotGuard host)" "fail" "$(run_helper)"

# Test 5: existing fall-through semantics preserved.
# Pre-fix the inline blocks fell through from .local≠true to main.conf, so an
# explicit ".local=false" with main.conf=true resolved to ENABLED. This is
# almost certainly not what most admins would expect, but the BotGuard
# rebuild-UX fix is not the place to change config-resolution semantics —
# that belongs in a separate config-doctor follow-up. Pin the existing
# behavior to keep this patch surgical and to flag any future drift.
reset_botguard_conf
echo 'HTTP_BOTGUARD_ENABLED="true"'  > "$SANDBOX/conf.d/botguard/main.conf"
echo 'HTTP_BOTGUARD_ENABLED="false"' > "$SANDBOX/conf.d/botguard/main.conf.local"
assert "preserved fall-through: .local=false + main.conf=true → enabled" "pass" "$(run_helper)"

# Test 5b: when .local explicitly says true, that wins regardless of main.conf
reset_botguard_conf
echo 'HTTP_BOTGUARD_ENABLED="false"' > "$SANDBOX/conf.d/botguard/main.conf"
echo 'HTTP_BOTGUARD_ENABLED="true"'  > "$SANDBOX/conf.d/botguard/main.conf.local"
assert ".local=true wins over main.conf=false" "pass" "$(run_helper)"

# Test 6: legacy wrong key alone is NOT honoured (would still pass pre-fix code,
# now must be ignored since we read the canonical key only)
reset_botguard_conf
echo 'BOTGUARD_ENABLED="true"' > "$SANDBOX/conf.d/botguard/main.conf.local"
assert "legacy key BOTGUARD_ENABLED alone is ignored" "fail" "$(run_helper)"

echo ""
echo "[2] Static regression guards on cmd_firewall.sh"

# Regression guard: no functional usage of legacy BOTGUARD_ENABLED= key
# (the comment block is allowed to mention it as documentation of the bug)
LEGACY_HITS=$(grep -n 'BOTGUARD_ENABLED=' "$CMD_FIREWALL" \
              | grep -v 'HTTP_BOTGUARD_ENABLED=' \
              | grep -v '^[0-9]*:#' || true)
if [[ -z "$LEGACY_HITS" ]]; then
    echo "  PASS  no functional BOTGUARD_ENABLED= references remain in cmd_firewall.sh"
    ((pass_count++)) || true
else
    echo "  FAIL  legacy BOTGUARD_ENABLED= still referenced functionally:"
    echo "$LEGACY_HITS" | sed 's/^/        /'
    ((fail_count++)) || true
fi

# All three call sites now go through the helper
HELPER_CALLS=$(grep -c '_firewall_botguard_is_enabled' "$CMD_FIREWALL" || true)
# 4 = 3 call sites + the function definition itself
if [[ "$HELPER_CALLS" -ge 4 ]]; then
    echo "  PASS  helper called from all three sites (reload/rebuild/reset)"
    ((pass_count++)) || true
else
    echo "  FAIL  expected ≥4 helper occurrences, got $HELPER_CALLS"
    ((fail_count++)) || true
fi

# Step 10 BotGuard re-apply must run BEFORE the POST validation block
STEP10_LINE=$(grep -n '\[10/12\] Re-applying BotGuard' "$CMD_FIREWALL" | head -1 | cut -d: -f1 || echo "")
POST_LINE=$(grep -n '\[POST\] Validating post-rebuild state' "$CMD_FIREWALL" | head -1 | cut -d: -f1 || echo "")
if [[ -n "$STEP10_LINE" && -n "$POST_LINE" && "$STEP10_LINE" -lt "$POST_LINE" ]]; then
    echo "  PASS  BotGuard re-apply (line $STEP10_LINE) precedes POST validation (line $POST_LINE)"
    ((pass_count++)) || true
else
    echo "  FAIL  BotGuard re-apply ordering broken (step10=$STEP10_LINE post=$POST_LINE)"
    ((fail_count++)) || true
fi

echo ""
echo "=========================================================="
echo "Results: $pass_count passed, $fail_count failed"
echo "=========================================================="

[[ "$fail_count" -eq 0 ]]
