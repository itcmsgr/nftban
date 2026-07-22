#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.126 firewall_reload trust-provider re-merge
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_firewall_trust_remerge_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-22"
# meta:description="Tests for the v1.126 fix that adds a trust-provider re-apply step to firewall_reload. Closes D-FIREWALL-RELOAD-DOES-NOT-REMERGE-TRUST-PROVIDERS (fleet-wide latent defect surfaced by V125 srv3 validation; cmd_firewall.sh::firewall_reload re-applied DDoS/portscan/botguard/feeds per v1.50.1+v1.81.0 but missed trust providers; reload invocations erased trust ranges and they did not auto-re-apply). Tests cover: (a) regression guard that the trust-load invocation is present in firewall_reload, (b) the helper logic gates on TRUST_*_ENABLED, (c) precedence between conf.d/trust.conf and nftban.conf.local, (d) preserved sequencing relative to DDoS/portscan/botguard/feeds steps. Static + behavioral; no host contact; no root required."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,awk,mktemp"
# meta:inventory.files="cli/lib/nftban/cli/cmd_firewall.sh"
# meta:inventory.binaries="bash,grep,awk,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cmd_firewall_trust_remerge_test"
# meta:ta.owner="firewall"
# meta:ta.module="firewall-reload-trust"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
# Defect closed:  D-FIREWALL-RELOAD-DOES-NOT-REMERGE-TRUST-PROVIDERS
# Scope file:     AUDIT_190_LIFECYCLE/V126_TRUST_WHITELIST_RELOAD_MERGE_SCOPE.md
# Reproduction:   V125_VALIDATE_SRV3_DEFERRED_WHITELIST_KERNEL_SYNC_ANOMALY.md §3
# Fix mechanism:  cmd_firewall.sh::firewall_reload now invokes `nftban trust
#                 load` after the botguard re-apply step (Step 4d), gated on
#                 grep of TRUST_*_ENABLED="true" across trust.conf +
#                 nftban.conf.local.
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR

CMD_FIREWALL="${NFTBAN_LIB_DIR}/cli/cmd_firewall.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

assert_contains() {
    # In-process bash pattern matching — avoids the printf|grep SIGPIPE race
    # that fires under `set -o pipefail` when the haystack is large (e.g.,
    # full cmd_firewall.sh file body ~136KB) and grep -q exits early before
    # printf finishes writing.
    local haystack="$1" needle="$2" name="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        printf "  [PASS] %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s\n" "$name"
        printf "         expected to contain: %s\n" "$needle"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
}

assert_eq() {
    local actual="$1" expected="$2" name="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf "  [PASS] %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s (expected '%s', got '%s')\n" "$name" "$expected" "$actual"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
}

echo "=========================================================="
echo "V126 Lane C — firewall_reload trust-provider re-merge test"
echo "=========================================================="

# ---------------------------------------------------------------------------
# §1 Static fixture: cmd_firewall.sh contains the v1.126 Step 4d block
# ---------------------------------------------------------------------------
if [[ ! -f "$CMD_FIREWALL" ]]; then
    echo "FATAL: cmd_firewall.sh not found at $CMD_FIREWALL"
    exit 2
fi

CMD_BODY=$(cat "$CMD_FIREWALL")

assert_contains "$CMD_BODY" \
    "Step 4d (v1.126): Re-apply trust providers if any enabled" \
    "regression_guard_step_4d_comment_present"

assert_contains "$CMD_BODY" \
    "D-FIREWALL-RELOAD-DOES-NOT-REMERGE-TRUST-PROVIDERS" \
    "regression_guard_defect_marker_present"

assert_contains "$CMD_BODY" \
    "nftban trust load" \
    "regression_guard_nftban_trust_load_invocation_present"

assert_contains "$CMD_BODY" \
    'TRUST_[A-Z]+_ENABLED="true"' \
    "regression_guard_enabled_grep_pattern_present"

assert_contains "$CMD_BODY" \
    "Re-applying trust provider rules" \
    "regression_guard_non_quiet_progress_message_present"

assert_contains "$CMD_BODY" \
    "Warning: trust providers enabled but not loadable. Run: nftban trust enable" \
    "regression_guard_subprocess_failure_warning_present"

# ---------------------------------------------------------------------------
# §2 Sequencing: Step 4d must appear AFTER Step 4c (botguard) and BEFORE
# Step 5 (feeds). This preserves the v1.50.1+v1.81.0 ordering invariants.
# ---------------------------------------------------------------------------
BOTGUARD_LINE=$(grep -n "Step 4c (v1.50.1, v1.81.0 key fix): Re-apply botguard" "$CMD_FIREWALL" | head -1 | cut -d: -f1)
TRUST_LINE=$(grep -n "Step 4d (v1.126): Re-apply trust providers" "$CMD_FIREWALL" | head -1 | cut -d: -f1)
FEEDS_LINE=$(grep -n "Step 5 (v1.50.1): Re-sync feeds" "$CMD_FIREWALL" | head -1 | cut -d: -f1)

if [[ -n "$BOTGUARD_LINE" && -n "$TRUST_LINE" && -n "$FEEDS_LINE" ]]; then
    if (( BOTGUARD_LINE < TRUST_LINE && TRUST_LINE < FEEDS_LINE )); then
        printf "  [PASS] sequencing_trust_step_between_botguard_and_feeds (botguard=%d trust=%d feeds=%d)\n" \
            "$BOTGUARD_LINE" "$TRUST_LINE" "$FEEDS_LINE"
        PASS=$((PASS + 1))
    else
        printf "  [FAIL] sequencing_trust_step_between_botguard_and_feeds (botguard=%d trust=%d feeds=%d)\n" \
            "$BOTGUARD_LINE" "$TRUST_LINE" "$FEEDS_LINE"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("sequencing_trust_step_between_botguard_and_feeds")
    fi
else
    printf "  [FAIL] sequencing markers missing: botguard=%s trust=%s feeds=%s\n" \
        "${BOTGUARD_LINE:-MISSING}" "${TRUST_LINE:-MISSING}" "${FEEDS_LINE:-MISSING}"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("sequencing_markers_present")
fi

# ---------------------------------------------------------------------------
# §3 Behavioral: extract the trust-enabled gating logic and verify it gates
# correctly under various TRUST_*_ENABLED fixture combinations.
#
# Strategy: reproduce the inline gating logic in this test (byte-equivalent
# to the production block), run it against sandbox config files, assert the
# resulting _any_trust_enabled value.
# ---------------------------------------------------------------------------
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Mirror the production gating logic (kept in sync with cmd_firewall.sh
# Step 4d block; if production changes, this block must change too — the
# §1 regression-guard tests above will catch comment/marker drift).
detect_any_trust_enabled() {
    local cfg_dir="$1"
    local _any_trust_enabled="false"
    local _trust_packaged="${cfg_dir}/conf.d/trust.conf"
    local _trust_local="${cfg_dir}/nftban.conf.local"
    local _trust_file
    for _trust_file in "$_trust_packaged" "$_trust_local"; do
        if [[ -f "$_trust_file" ]] && \
           grep -qE '^TRUST_[A-Z]+_ENABLED="true"' "$_trust_file" 2>/dev/null; then
            _any_trust_enabled="true"
            break
        fi
    done
    echo "$_any_trust_enabled"
}

# Setup sandbox config directory
mkdir -p "$SANDBOX/conf.d"

# Case 3.1: no config files at all -> false
result=$(detect_any_trust_enabled "$SANDBOX")
assert_eq "$result" "false" "gating_no_config_files_returns_false"

# Case 3.2: trust.conf with all providers disabled (packaged default shape)
cat >"$SANDBOX/conf.d/trust.conf" <<'EOF'
TRUST_ENABLED="true"
TRUST_CLOUDFLARE_ENABLED="false"
TRUST_AWS_ENABLED="false"
TRUST_GOOGLE_ENABLED="false"
EOF
result=$(detect_any_trust_enabled "$SANDBOX")
assert_eq "$result" "false" "gating_all_providers_disabled_returns_false"

# Case 3.3: trust.conf with TRUST_CLOUDFLARE_ENABLED="true" -> true
cat >"$SANDBOX/conf.d/trust.conf" <<'EOF'
TRUST_ENABLED="true"
TRUST_CLOUDFLARE_ENABLED="true"
TRUST_AWS_ENABLED="false"
EOF
result=$(detect_any_trust_enabled "$SANDBOX")
assert_eq "$result" "true" "gating_cloudflare_enabled_returns_true"

# Case 3.4: trust.conf with TRUST_AWS_ENABLED="true" -> true (cross-provider)
cat >"$SANDBOX/conf.d/trust.conf" <<'EOF'
TRUST_CLOUDFLARE_ENABLED="false"
TRUST_AWS_ENABLED="true"
EOF
result=$(detect_any_trust_enabled "$SANDBOX")
assert_eq "$result" "true" "gating_aws_only_enabled_returns_true"

# Case 3.5: srv3-shaped layout — packaged trust.conf disables CLOUDFLARE,
# but operator override in nftban.conf.local enables it. The gating must
# detect the override.
cat >"$SANDBOX/conf.d/trust.conf" <<'EOF'
TRUST_CLOUDFLARE_ENABLED="false"
TRUST_AWS_ENABLED="false"
EOF
cat >"$SANDBOX/nftban.conf.local" <<'EOF'
TRUST_CLOUDFLARE_ENABLED="true"
EOF
result=$(detect_any_trust_enabled "$SANDBOX")
assert_eq "$result" "true" "gating_local_override_enables_returns_true_srv3_shape"

# Case 3.6: multiple providers enabled across both files
cat >"$SANDBOX/conf.d/trust.conf" <<'EOF'
TRUST_CLOUDFLARE_ENABLED="true"
EOF
cat >"$SANDBOX/nftban.conf.local" <<'EOF'
TRUST_AWS_ENABLED="true"
TRUST_GOOGLE_ENABLED="true"
EOF
result=$(detect_any_trust_enabled "$SANDBOX")
assert_eq "$result" "true" "gating_multiple_providers_enabled_returns_true"

# Case 3.7: commented-out lines must NOT trigger the gate (^TRUST anchors
# the grep to start-of-line; # TRUST_X_ENABLED="true" should be ignored).
cat >"$SANDBOX/conf.d/trust.conf" <<'EOF'
# TRUST_CLOUDFLARE_ENABLED="true"
# Example: enable Cloudflare ranges below if you proxy traffic
TRUST_CLOUDFLARE_ENABLED="false"
EOF
rm -f "$SANDBOX/nftban.conf.local"
result=$(detect_any_trust_enabled "$SANDBOX")
assert_eq "$result" "false" "gating_commented_enable_does_not_trigger_returns_false"

# Case 3.8: whitespace-prefixed lines must NOT trigger (^TRUST anchors)
cat >"$SANDBOX/conf.d/trust.conf" <<'EOF'
    TRUST_CLOUDFLARE_ENABLED="true"
TRUST_CLOUDFLARE_ENABLED="false"
EOF
result=$(detect_any_trust_enabled "$SANDBOX")
assert_eq "$result" "false" "gating_indented_enable_does_not_trigger_returns_false"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "=========================================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================================="
if (( FAIL > 0 )); then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi
echo "All v1.126 Lane C trust-remerge tests passed."
exit 0
