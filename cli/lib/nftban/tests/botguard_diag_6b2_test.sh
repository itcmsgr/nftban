#!/usr/bin/env bash
# =============================================================================
# NFTBan - BotGuard support/health cache diagnostics (v1.191 8B inc6B2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="botguard_diag_6b2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-16"
# meta:description="Hermetic tests for the bounded read-only BotGuard temporary-cache diagnostics wired into support (aggregate block) and health (WARN-when-enabled line). Stubs nft_ipc_request to drive available/unavailable/malformed cases. Verifies boundedness (no full-cache dump, no per-IP), degrade-safety, WARN-only-when-enabled, no-WARN-when-disabled, empty-cache-is-not-WARN, temporary-vs-durable wording, no schema change, no cache mutation, no shell-side cache, and that the 6B1 surface tests still pass."
#
# meta:inventory.files="botguard_diag_6b2_test.sh"
# meta:inventory.binaries="bash,jq"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="botguard_diag_6b2_test"
# meta:ta.owner="botguard"
# meta:ta.module="botguard-explain-diag"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"; export NFTBAN_LIB_DIR
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not present"; exit 0; }

# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/lib/nftban_botguard_explain.sh"

STUB_RC=0; STUB_RESPONSE=""; STUB_METHODS="$tmp/methods"; : > "$STUB_METHODS"
nft_ipc_request() { echo "$1" >> "$STUB_METHODS"; [[ "$STUB_RC" == "1" ]] && return 1; printf '%s' "$STUB_RESPONSE"; return 0; }
set_available()   { STUB_RC=0; STUB_RESPONSE='{"success":true,"data":{"ip":"192.0.2.0","present":false,"temporary":true,"state":"unknown","cache_available":true,"durable_authority":"not_evaluated","source":"botguard_decision_cache"}}'; }
set_unavailable() { STUB_RC=1; STUB_RESPONSE=""; }
set_malformed()   { STUB_RC=0; STUB_RESPONSE='}}garbage{{'; }

IPV4_RE='[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'
FORBIDDEN='trusted|permanently allowed|permanently blocked|is safe|not banned'

# === SUPPORT_INCLUDES_BOUNDED_BOTGUARD_CACHE_DIAGNOSTICS ===
set_available
out=$(nftban_botguard_explain_diag_aggregate)
grep -q "TEMPORARY, read-only" <<<"$out" || fail "support diag must label TEMPORARY read-only"
grep -q "explain_ip query path: available" <<<"$out" || fail "support diag must show subsystem status"
pass "SUPPORT_INCLUDES_BOUNDED_BOTGUARD_CACHE_DIAGNOSTICS"

# === SUPPORT_DOES_NOT_DUMP_FULL_CACHE ===
set_available
out=$(nftban_botguard_explain_diag_aggregate)
grep -q "no full-cache dump" <<<"$out" || fail "support diag must state no full-cache dump"
if grep -qE "$IPV4_RE" <<<"$out"; then fail "support diag must not list any IPs"; fi
pass "SUPPORT_DOES_NOT_DUMP_FULL_CACHE"

# === SUPPORT_DEGRADES_WHEN_EXPLAIN_UNAVAILABLE ===
set_unavailable
out=$(nftban_botguard_explain_diag_aggregate); rc=$?
[[ "$rc" -eq 0 ]] || fail "support diag must not abort (rc=$rc)"
grep -q "unavailable" <<<"$out" || fail "must show unavailable"
grep -q "durable nft-set checks remain authoritative" <<<"$out" || fail "must point to durable authority"
pass "SUPPORT_DEGRADES_WHEN_EXPLAIN_UNAVAILABLE"

# === SUPPORT_MALFORMED_EXPLAIN_JSON_DOES_NOT_ABORT ===
set_malformed
out=$(nftban_botguard_explain_diag_aggregate); rc=$?
[[ "$rc" -eq 0 ]] || fail "malformed JSON must not abort support diag"
grep -q "unavailable" <<<"$out" || fail "malformed → unavailable diagnostic"
pass "SUPPORT_MALFORMED_EXPLAIN_JSON_DOES_NOT_ABORT"

# === HEALTH_CACHE_UNAVAILABLE_WARN_ONLY_WHEN_BOTGUARD_ENABLED ===
set_unavailable
out=$(nftban_botguard_health_cache_diag "true")
grep -q "^WARN:" <<<"$out" || fail "enabled + unavailable must emit WARN, got: $out"
grep -q "durable nft-set checks remain authoritative" <<<"$out" || fail "WARN must cite durable authority"
grep -q "does NOT imply unprotected" <<<"$out" || fail "WARN must not imply unprotected"
pass "HEALTH_CACHE_UNAVAILABLE_WARN_ONLY_WHEN_BOTGUARD_ENABLED"

# === HEALTH_CACHE_UNAVAILABLE_OMITTED_OR_INFO_WHEN_BOTGUARD_DISABLED ===
set_unavailable
out=$(nftban_botguard_health_cache_diag "false")
[[ -z "$out" ]] || fail "disabled + unavailable must be OMITTED (no WARN), got: $out"
grep -q "WARN" <<<"$out" && fail "disabled must never WARN about cache"
pass "HEALTH_CACHE_UNAVAILABLE_OMITTED_OR_INFO_WHEN_BOTGUARD_DISABLED"

# === HEALTH_NO_PER_IP_CACHE_LISTING ===
set_unavailable; out_w=$(nftban_botguard_health_cache_diag "true")
set_available;   out_i=$(nftban_botguard_health_cache_diag "true")
if grep -qE "$IPV4_RE" <<<"$out_w$out_i"; then fail "health diag must not list any IP"; fi
pass "HEALTH_NO_PER_IP_CACHE_LISTING"

# === HEALTH_NO_SCHEMA_CHANGE ===
# The diagnostics are plain text (WARN:/INFO:), not JSON; no schema field added anywhere.
set_available; out=$(nftban_botguard_health_cache_diag "true")
grep -q '"' <<<"$out" && fail "health diag must be plain text (no JSON keys)"
sf="$NFTBAN_LIB_DIR/data/config-schema.json"
if [[ -f "$sf" ]] && grep -qE 'temp_cache|cache_diag|botguard_cache|decision_cache' "$sf"; then
    fail "schema file $sf must not gain a temporary-cache field"
fi
pass "HEALTH_NO_SCHEMA_CHANGE"

# === HEALTH_NO_INSTALL_STATE_DEGRADED_FROM_EMPTY_TEMP_CACHE ===
# An empty-but-available cache (present=false, cache_available=true) must be INFO, never WARN.
set_available
out=$(nftban_botguard_health_cache_diag "true")
grep -q "^INFO:" <<<"$out" || fail "empty-but-available cache must be INFO, got: $out"
grep -q "^WARN:" <<<"$out" && fail "empty temp cache must NOT produce a WARN/DEGRADED"
pass "HEALTH_NO_INSTALL_STATE_DEGRADED_FROM_EMPTY_TEMP_CACHE"

# === HEALTH_WORDING_SEPARATES_TEMP_CACHE_FROM_DURABLE_AUTHORITY ===
set_available; a=$(nftban_botguard_explain_diag_aggregate)
set_unavailable; w=$(nftban_botguard_health_cache_diag "true")
grep -qi "TEMPORARY" <<<"$a$w" || fail "wording must label TEMPORARY"
grep -qi "durable" <<<"$a$w" || fail "wording must reference durable authority separately"
if grep -qiE "$FORBIDDEN" <<<"$a$w"; then fail "must not use trusted/permanently/safe/not-banned wording"; fi
pass "HEALTH_WORDING_SEPARATES_TEMP_CACHE_FROM_DURABLE_AUTHORITY"

# === NO_CACHE_MUTATION_COMMANDS_EXIST ===
m=$(grep -oE 'nft_ipc_request "[a-z_]+"' "$NFTBAN_LIB_DIR/lib/nftban_botguard_explain.sh" | grep -oE '"[a-z_]+"' | tr -d '"' | sort -u)
[[ "$m" == "explain_ip" ]] || fail "explain client must only call explain_ip, found: $m"
if grep -rnE "cache_(add|trust|block|set)|botguard_cache_set|nftban cache (add|trust|block|set)" \
    "$NFTBAN_LIB_DIR/lib/nftban_botguard_explain.sh" \
    "$NFTBAN_LIB_DIR/cli/cmd_support.sh" "$NFTBAN_LIB_DIR/cli/cmd_health_analysis.sh" 2>/dev/null; then
    fail "no cache-mutation command/verb may exist on these surfaces"
fi
pass "NO_CACHE_MUTATION_COMMANDS_EXIST"

# === NO_SHELL_PARALLEL_CACHE_CREATED / NO_PERSISTED_CACHE_WRITER ===
workdir="$tmp/work"; mkdir -p "$workdir"
( cd "$workdir" && HOME="$workdir" set_available; \
  HOME="$workdir" nftban_botguard_explain_diag_aggregate >/dev/null; \
  HOME="$workdir" nftban_botguard_health_cache_diag true >/dev/null )
created=$(find "$workdir" -type f | wc -l)
[[ "$created" -eq 0 ]] || fail "diagnostics must not create any shell-side/persisted cache file (found $created)"
pass "NO_SHELL_PARALLEL_CACHE_CREATED"
pass "NO_PERSISTED_CACHE_WRITER"

# === EXISTING_SEARCH_EMULATE_DEBUG_6B1_TESTS_STILL_PASS ===
if [[ -f "$SCRIPT_DIR/botguard_explain_shell_6b1_test.sh" ]]; then
    bash "$SCRIPT_DIR/botguard_explain_shell_6b1_test.sh" >/dev/null 2>&1 || fail "6B1 surface tests must still pass"
    pass "EXISTING_SEARCH_EMULATE_DEBUG_6B1_TESTS_STILL_PASS"
else
    fail "6B1 test file missing"
fi

echo
echo "ALL PASS: BotGuard support/health cache diagnostics (v1.191 8B inc6B2)"
