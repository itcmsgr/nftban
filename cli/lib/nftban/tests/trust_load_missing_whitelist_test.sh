#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.126.1 - Tests for nftban_trust_load() missing-whitelist-file
#                   strict-warning + non-zero rc behavior
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="trust_load_missing_whitelist_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-23"
# meta:description="Tests for the v1.126.1 hotfix to nftban_trust_load() that adds explicit error reporting + non-zero rc when a provider is configured-enabled but its generated whitelist file at /etc/nftban/whitelist.d/30-trust-<provider>.conf is missing. Pre-v1.126.1 such providers were silently skipped with rc=0, masking broken trust state and defeating the v1.126 Lane C firewall_reload Step 4d re-merge attempt. Closes D-NFTBAN-TRUST-LOAD-SILENT-NOOP-WHEN-PROVIDER-ENABLED-VIA-LOCAL-OVERRIDE (P2; surfaced by V126 srv3 active test 2026-05-23T08:43Z). Tests cover: (a) static guards that the fix markers are present in nftban_trust.sh, (b) behavioral test that calls nftban_trust_load() in a sandbox with provider enabled but no whitelist file and asserts rc=2 + stderr message, (c) negative test that healthy state (provider enabled + whitelist file present) still works, (d) edge case that no-providers-configured stays rc=0 with no false-positive. Static + behavioral; no host contact; no root required (does not exercise _trust_apply_to_nft path)."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,mktemp"
# meta:inventory.files="cli/lib/nftban/core/nftban_trust.sh,cli/lib/nftban/cli/cmd_firewall.sh"
# meta:inventory.binaries="bash,grep,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR,TRUST_CACHE_DIR,TRUST_DATA_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Defect closed:  D-NFTBAN-TRUST-LOAD-SILENT-NOOP-WHEN-PROVIDER-ENABLED-VIA-LOCAL-OVERRIDE
# Scope file:     AUDIT_190_LIFECYCLE/V126_1_LANE_C_HOTFIX_SCOPE.md (§4.6)
# Reproduction:   V126_VALIDATE_SRV3_LANE_C_FAIL_CLOSURE.md §3 + §4
# Fix mechanism:  nftban_trust.sh::nftban_trust_load() now emits stderr error
#                 + returns rc=2 when a provider is configured-enabled but
#                 its whitelist file is missing. cmd_firewall.sh:1549
#                 firewall_reload Step 4d's `|| { warning }` branch now fires,
#                 directing operator to `nftban trust enable <PROVIDER>` as
#                 the canonical repair. No auto-heal (per §4.6.4).
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Test infrastructure
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../" && pwd)"
TRUST_MODULE="${REPO_ROOT}/cli/lib/nftban/core/nftban_trust.sh"
FW_MODULE="${REPO_ROOT}/cli/lib/nftban/cli/cmd_firewall.sh"

PASS_COUNT=0
FAIL_COUNT=0
ASSERTIONS=()

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        ASSERTIONS+=("PASS: $name")
        ((PASS_COUNT++)) || true
    else
        ASSERTIONS+=("FAIL: $name (expected: '$expected'; actual: '$actual')")
        ((FAIL_COUNT++)) || true
    fi
}

assert_match() {
    local name="$1" pattern="$2" actual="$3"
    if echo "$actual" | grep -qE "$pattern"; then
        ASSERTIONS+=("PASS: $name")
        ((PASS_COUNT++)) || true
    else
        ASSERTIONS+=("FAIL: $name (pattern: '$pattern' not found in: $(echo "$actual" | head -c 200))")
        ((FAIL_COUNT++)) || true
    fi
}

assert_nomatch() {
    local name="$1" pattern="$2" actual="$3"
    if ! echo "$actual" | grep -qE "$pattern"; then
        ASSERTIONS+=("PASS: $name")
        ((PASS_COUNT++)) || true
    else
        ASSERTIONS+=("FAIL: $name (pattern: '$pattern' UNEXPECTEDLY found in: $(echo "$actual" | head -c 200))")
        ((FAIL_COUNT++)) || true
    fi
}

# =============================================================================
# §1 — Static guards (fix-code presence)
# =============================================================================
# Verifies the v1.126.1 fix markers are in the modified files.

[[ -f "$TRUST_MODULE" ]] || { echo "FATAL: trust module not found at $TRUST_MODULE"; exit 99; }
[[ -f "$FW_MODULE"    ]] || { echo "FATAL: firewall module not found at $FW_MODULE"; exit 99; }

# Static guard 1: enabled_but_unloadable counter introduced
assert_match "S1: nftban_trust_load tracks enabled_but_unloadable counter" \
    'enabled_but_unloadable' \
    "$(grep 'enabled_but_unloadable' "$TRUST_MODULE" | head -1)"

# Static guard 2: explicit ERROR stderr message references missing whitelist file
assert_match "S2: stderr message names missing whitelist file" \
    'enabled but whitelist file missing' \
    "$(grep '\[ERROR\]' "$TRUST_MODULE" || true)"

# Static guard 3: error message directs operator to nftban trust enable
assert_match "S3: stderr message names canonical repair (nftban trust enable)" \
    'Run: nftban trust enable' \
    "$(grep -E '\[ERROR\].*Run:' "$TRUST_MODULE" || true)"

# Static guard 4: nftban_trust_load returns rc=2 on enabled-but-unloadable
assert_match "S4: nftban_trust_load returns rc=2 for enabled_but_unloadable > 0" \
    'return 2' \
    "$(awk '/^nftban_trust_load/,/^}/' "$TRUST_MODULE" | grep 'return 2' || true)"

# Static guard 5: firewall_reload Step 4d no longer uses 2>&1 to swallow stderr
# (changed from "nftban trust load >/dev/null 2>&1 || {" to "nftban trust load >/dev/null || {")
assert_match "S5: firewall_reload Step 4d preserves stderr from nftban trust load" \
    'nftban trust load >/dev/null \|\|' \
    "$(grep 'nftban trust load >/dev/null' "$FW_MODULE" | head -1)"

# Static guard 6: Step 4d warning message updated to direct operator to `nftban trust enable`
assert_match "S6: firewall_reload Step 4d warning directs operator to nftban trust enable" \
    'Run: nftban trust enable' \
    "$(grep -A 2 'nftban trust load >/dev/null' "$FW_MODULE" | grep 'Run:' || true)"

# Static guard 7: §4.6.4 no-auto-heal — no calls to _trust_download_provider or
# _trust_write_whitelist inside the modified nftban_trust_load function body.
TRUST_LOAD_BODY=$(awk '/^nftban_trust_load\(\)/,/^}/' "$TRUST_MODULE")
assert_nomatch "S7: no _trust_download_provider call added inside nftban_trust_load (no auto-heal)" \
    '_trust_download_provider' \
    "$TRUST_LOAD_BODY"
assert_nomatch "S8: no _trust_write_whitelist call added inside nftban_trust_load (no auto-heal)" \
    '_trust_write_whitelist' \
    "$TRUST_LOAD_BODY"

# =============================================================================
# §2 — Behavioral sandbox tests
# =============================================================================
# Source nftban_trust.sh in a sandbox with a fake TRUST_WHITELIST_DIR and
# fake provider config, then invoke nftban_trust_load directly. The behavioral
# test does NOT exercise _trust_apply_to_nft (that requires root + nftables).
# We specifically test the path where the inner block is SKIPPED due to missing
# whitelist file — which is the v1.126.1 fix surface.

SANDBOX="$(mktemp -d -t nftban-trust-test-XXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/cache" "$SANDBOX/data" "$SANDBOX/whitelist.d" "$SANDBOX/log"

# Override TRUST module paths via env so the sourced module uses sandbox paths.
# The module's `readonly` declarations honor a pre-existing env var.
export TRUST_CACHE_DIR="$SANDBOX/cache"
export TRUST_DATA_DIR="$SANDBOX/data"
export NFTBAN_CONFIG_DIR="$SANDBOX"
mkdir -p "$NFTBAN_CONFIG_DIR/whitelist.d"
export NFTBAN_LOG_DIR="$SANDBOX/log"
export TRUST_LOG_FILE="$NFTBAN_LOG_DIR/trust.log"

# Stub _trust_apply_to_nft so the behavioral tests don't try to talk to nftables.
# (Only used in the §2.3 healthy-state test where the inner block IS reached.)
# We define a stub BEFORE sourcing — bash's `declare -f` precedence means once
# the module is sourced, its definition wins. So we override AFTER sourcing.

# Source the module (set -E will propagate errors; module has its own set -Eeuo)
# Save current set state, allow the source to override, then restore for testing.
set +e
# shellcheck disable=SC1090
source "$TRUST_MODULE" 2>/dev/null || true
set -e

# Override _trust_apply_to_nft to a stub that records invocation but does no nft work.
_trust_apply_to_nft() {
    echo "STUB: _trust_apply_to_nft($1) called" >&2
    return 0
}

# -----------------------------------------------------------------------------
# §2.1 — Behavior: provider enabled, whitelist file MISSING → rc=2 + stderr error
# -----------------------------------------------------------------------------
export TRUST_CLOUDFLARE_ENABLED="true"
# (deliberately do NOT create $NFTBAN_CONFIG_DIR/whitelist.d/30-trust-cloudflare.conf)

CAPTURED_STDOUT=$(mktemp -p "$SANDBOX" stdout.XXX)
CAPTURED_STDERR=$(mktemp -p "$SANDBOX" stderr.XXX)

set +e
nftban_trust_load >"$CAPTURED_STDOUT" 2>"$CAPTURED_STDERR"
RC=$?
set -e

STDOUT="$(cat "$CAPTURED_STDOUT")"
STDERR="$(cat "$CAPTURED_STDERR")"

assert_eq "B1: rc=2 when provider enabled + whitelist file missing" "2" "$RC"
assert_match "B2: stderr names the missing whitelist file path" \
    "30-trust-cloudflare.conf" \
    "$STDERR"
assert_match "B3: stderr directs operator to nftban-trust-enable-CLOUDFLARE" \
    "Run: nftban trust enable CLOUDFLARE" \
    "$STDERR"
assert_match "B4: stderr ERROR prefix used (not just stdout)" \
    '\[ERROR\]' \
    "$STDERR"
assert_match "B5: summary stderr line counts enabled_but_unloadable providers" \
    'enabled but not loaded' \
    "$STDERR"

# -----------------------------------------------------------------------------
# §2.2 — Behavior: NO providers configured → rc=0, no error
# -----------------------------------------------------------------------------
unset TRUST_CLOUDFLARE_ENABLED

CAPTURED_STDOUT=$(mktemp -p "$SANDBOX" stdout.XXX)
CAPTURED_STDERR=$(mktemp -p "$SANDBOX" stderr.XXX)

set +e
nftban_trust_load >"$CAPTURED_STDOUT" 2>"$CAPTURED_STDERR"
RC=$?
set -e

STDOUT="$(cat "$CAPTURED_STDOUT")"
STDERR="$(cat "$CAPTURED_STDERR")"

assert_eq "B6: rc=0 when no providers configured" "0" "$RC"
assert_match "B7: stdout reports no-providers-configured" \
    "No providers configured" \
    "$STDOUT"
assert_nomatch "B8: no ERROR stderr lines when no providers configured" \
    '\[ERROR\]' \
    "$STDERR"

# -----------------------------------------------------------------------------
# §2.3 — Behavior: provider enabled + whitelist file PRESENT → rc=0, loads OK
# -----------------------------------------------------------------------------
export TRUST_CLOUDFLARE_ENABLED="true"
# Create the whitelist file so the inner block is reached.
echo "# nftban test fixture whitelist" > "$NFTBAN_CONFIG_DIR/whitelist.d/30-trust-cloudflare.conf"

CAPTURED_STDOUT=$(mktemp -p "$SANDBOX" stdout.XXX)
CAPTURED_STDERR=$(mktemp -p "$SANDBOX" stderr.XXX)

set +e
nftban_trust_load >"$CAPTURED_STDOUT" 2>"$CAPTURED_STDERR"
RC=$?
set -e

STDOUT="$(cat "$CAPTURED_STDOUT")"
STDERR="$(cat "$CAPTURED_STDERR")"

assert_eq "B9: rc=0 when provider enabled + whitelist file present + stub apply succeeds" "0" "$RC"
assert_match "B10: stdout reports Loaded-CLOUDFLARE" \
    "Loaded: CLOUDFLARE" \
    "$STDOUT"
assert_nomatch "B11: no ERROR stderr lines in healthy-state load" \
    '\[ERROR\]' \
    "$STDERR"

# -----------------------------------------------------------------------------
# §2.4 — Behavior: TWO providers enabled, one healthy + one missing-file → rc=2
# -----------------------------------------------------------------------------
# CLOUDFLARE still enabled with whitelist file present (from §2.3).
# AWS enabled with NO whitelist file → should trigger enabled_but_unloadable for AWS.
export TRUST_AWS_ENABLED="true"

CAPTURED_STDOUT=$(mktemp -p "$SANDBOX" stdout.XXX)
CAPTURED_STDERR=$(mktemp -p "$SANDBOX" stderr.XXX)

set +e
nftban_trust_load >"$CAPTURED_STDOUT" 2>"$CAPTURED_STDERR"
RC=$?
set -e

STDOUT="$(cat "$CAPTURED_STDOUT")"
STDERR="$(cat "$CAPTURED_STDERR")"

assert_eq "B12: rc=2 when at least one provider is enabled_but_unloadable (CF healthy, AWS broken)" "2" "$RC"
assert_match "B13: stdout still reports CLOUDFLARE loaded" \
    "Loaded: CLOUDFLARE" \
    "$STDOUT"
assert_match "B14: stderr names AWS as the unloadable provider" \
    "AWS is enabled but whitelist file missing" \
    "$STDERR"
assert_match "B15: stderr directs to nftban-trust-enable-AWS" \
    "Run: nftban trust enable AWS" \
    "$STDERR"

# Cleanup unsets
unset TRUST_CLOUDFLARE_ENABLED TRUST_AWS_ENABLED

# =============================================================================
# §3 — Test results
# =============================================================================
echo
echo "============================================================"
echo "  trust_load_missing_whitelist_test.sh — results"
echo "  v1.126.1 hotfix for D-NFTBAN-TRUST-LOAD-SILENT-NOOP-WHEN-"
echo "  PROVIDER-ENABLED-VIA-LOCAL-OVERRIDE"
echo "============================================================"
printf '%s\n' "${ASSERTIONS[@]}"
echo "------------------------------------------------------------"
echo "  Total: $((PASS_COUNT + FAIL_COUNT))  PASS: $PASS_COUNT  FAIL: $FAIL_COUNT"
echo "============================================================"

if (( FAIL_COUNT > 0 )); then
    exit 1
fi
exit 0
