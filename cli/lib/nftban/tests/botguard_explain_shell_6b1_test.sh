#!/usr/bin/env bash
# =============================================================================
# NFTBan - BotGuard explain shell client (v1.191 8B inc6B1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="botguard_explain_shell_6b1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-16"
# meta:description="Hermetic tests for the read-only BotGuard explain shell client (nftban_botguard_explain.sh) wired into search/emulate/debug. Stubs nft_ipc_request to drive daemon-available, daemon-down, malformed-JSON, and per-state cases without a live daemon, and verifies degrade-safety, TEMPORARY labeling, no durable claim, single-IP scope, no cache mutation, and no shell-side cache file."
#
# meta:inventory.files="botguard_explain_shell_6b1_test.sh"
# meta:inventory.binaries="bash,jq"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="botguard_explain_shell_6b1_test"
# meta:ta.owner="botguard"
# meta:ta.module="botguard-explain-client"
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

# Source ONLY the explain client (not nft_ipc.sh) so our stub nft_ipc_request controls IPC.
# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/lib/nftban_botguard_explain.sh"

# --- stub IPC -----------------------------------------------------------------
STUB_RESPONSE=""; STUB_RC=0; STUB_METHODS="$tmp/methods"; : > "$STUB_METHODS"
nft_ipc_request() {
    echo "$1" >> "$STUB_METHODS"      # record the method invoked
    [[ "$STUB_RC" == "1" ]] && return 1
    printf '%s' "$STUB_RESPONSE"
    return 0
}

ok_resp() { # state class -> a successful daemon explain response
    local state="$1" cls="$2"
    STUB_RC=0
    STUB_RESPONSE="{\"success\":true,\"data\":{\"ip\":\"1.2.3.4\",\"family\":\"ipv4\",\"request_class\":\"$cls\",\"state\":\"$state\",\"temporary\":true,\"present\":true,\"reason\":\"batch_signal:ban\",\"evidence_summary\":\"e\",\"ttl_remaining_ms\":3600000,\"cache_available\":true,\"durable_authority\":\"not_evaluated\",\"source\":\"botguard_decision_cache\"}}"
}
absent_resp() {
    STUB_RC=0
    STUB_RESPONSE="{\"success\":true,\"data\":{\"ip\":\"1.2.3.4\",\"present\":false,\"temporary\":true,\"state\":\"unknown\",\"cache_available\":true,\"durable_authority\":\"not_evaluated\",\"source\":\"botguard_decision_cache\"}}"
}

# === SHELL_EXPLAIN_HELPER_DAEMON_UNAVAILABLE_DEGRADES ===
STUB_RC=1; STUB_RESPONSE=""
j=$(nftban_botguard_explain_json 1.2.3.4)
[[ "$(jq -r '.cache_available' <<<"$j")" == "false" ]] || fail "daemon-down must degrade cache_available=false"
[[ "$(jq -r '.state' <<<"$j")" == "unavailable" ]] || fail "daemon-down must report state=unavailable"
pass "SHELL_EXPLAIN_HELPER_DAEMON_UNAVAILABLE_DEGRADES"

# === SHELL_EXPLAIN_HELPER_MALFORMED_JSON_DEGRADES ===
STUB_RC=0; STUB_RESPONSE='not-json{{{'
j=$(nftban_botguard_explain_json 1.2.3.4)
[[ "$(jq -r '.cache_available' <<<"$j")" == "false" ]] || fail "malformed JSON must degrade"
pass "SHELL_EXPLAIN_HELPER_MALFORMED_JSON_DEGRADES"

# === SEARCH_PRESERVES_DURABLE_SET_TRUTH_WITH_CACHE_AVAILABLE ===
ok_resp blocked_temporarily scanner
out=$(nftban_botguard_explain_render 1.2.3.4)
grep -q "TEMPORARY — not durable" <<<"$out" || fail "render must label section TEMPORARY/not-durable"
grep -qi "STATUS: BANNED\|WHITELISTED" <<<"$out" && fail "cache section must not emit durable verdicts"
pass "SEARCH_PRESERVES_DURABLE_SET_TRUTH_WITH_CACHE_AVAILABLE"

# === SEARCH_PRESERVES_DURABLE_SET_TRUTH_WITH_CACHE_UNAVAILABLE ===
STUB_RC=1; STUB_RESPONSE=""
out=$(nftban_botguard_explain_render 1.2.3.4)
grep -q "unavailable" <<<"$out" || fail "must show cache unavailable"
grep -qi "STATUS: NOT BANNED\|✓ STATUS" <<<"$out" && fail "cache-unavailable must not assert a durable verdict"
pass "SEARCH_PRESERVES_DURABLE_SET_TRUTH_WITH_CACHE_UNAVAILABLE"

# === SEARCH_LABELS_CACHE_STATE_TEMPORARY ===
ok_resp blocked_temporarily scanner
out=$(nftban_botguard_explain_render 1.2.3.4)
grep -q "(temporary)" <<<"$out" || fail "state must be labeled (temporary)"
pass "SEARCH_LABELS_CACHE_STATE_TEMPORARY"

# === SEARCH_CACHE_FAILURE_DOES_NOT_IMPLY_SAFE ===
STUB_RC=1; STUB_RESPONSE=""
out=$(nftban_botguard_explain_render 1.2.3.4)
# The disclaimer must be present (this IS the not-imply-safe guarantee)...
grep -q "does NOT imply" <<<"$out" || fail "cache failure must carry the not-safe disclaimer"
# ...and there must be no POSITIVE safe verdict (✓ status marker / "STATUS:" verdict line).
grep -qE "✓ STATUS|STATUS: (NOT BANNED|WHITELISTED)" <<<"$out" && fail "must not positively imply safe/clean"
pass "SEARCH_CACHE_FAILURE_DOES_NOT_IMPLY_SAFE"

# === EMULATE_SHOWS_CACHE_DECISION_READ_ONLY ===
ok_resp legit_temporarily static
grep -q "Would SUPPRESS" <<<"$(nftban_botguard_explain_emulate_note 1.2.3.4)" || fail "legit → would suppress"
ok_resp blocked_temporarily scanner
grep -q "Would PRESERVE" <<<"$(nftban_botguard_explain_emulate_note 1.2.3.4)" || fail "blocked → would preserve"
ok_resp ambiguous mixed
grep -q "Would DEFER" <<<"$(nftban_botguard_explain_emulate_note 1.2.3.4)" || fail "ambiguous → would defer"
pass "EMULATE_SHOWS_CACHE_DECISION_READ_ONLY"

# === EMULATE_CACHE_FAILURE_DOES_NOT_CHANGE_DURABLE_WOULD_BAN ===
STUB_RC=1; STUB_RESPONSE=""
out=$(nftban_botguard_explain_emulate_note 1.2.3.4)
grep -q "durable decision above is unaffected" <<<"$out" || fail "emulate cache-failure must state durable decision unaffected"
pass "EMULATE_CACHE_FAILURE_DOES_NOT_CHANGE_DURABLE_WOULD_BAN"

# === DEBUG_BOTGUARD_SHOWS_SINGLE_IP_CACHE_RECORD ===
ok_resp blocked_temporarily scanner
out=$(nftban_botguard_explain_render 1.2.3.4)
grep -q "Request class:     scanner" <<<"$out" || fail "debug record must show request_class"
grep -q "State:             blocked_temporarily" <<<"$out" || fail "debug record must show state"
pass "DEBUG_BOTGUARD_SHOWS_SINGLE_IP_CACHE_RECORD"

# === DEBUG_BOTGUARD_NO_FULL_CACHE_DUMP ===
: > "$STUB_METHODS"; ok_resp blocked_temporarily scanner
out=$(nftban_botguard_explain_render 9.9.9.9)
# Only the queried IP's method call should have been made (single-IP scope), and no other IP leaks.
[[ "$(sort -u "$STUB_METHODS")" == "explain_ip" ]] || fail "render must call only explain_ip"
grep -qE "5\.5\.5\.5|0\.0\.0\.0" <<<"$out" && fail "render must not leak unrelated IPs"
pass "DEBUG_BOTGUARD_NO_FULL_CACHE_DUMP"

# === DEBUG_BOTGUARD_DEGRADES_WHEN_DAEMON_DOWN ===
STUB_RC=1; STUB_RESPONSE=""
grep -q "unavailable" <<<"$(nftban_botguard_explain_render 1.2.3.4)" || fail "debug must degrade when daemon down"
pass "DEBUG_BOTGUARD_DEGRADES_WHEN_DAEMON_DOWN"

# === NO_CACHE_MUTATION_COMMANDS_EXIST ===
# The explain client must only ever invoke the read-only explain_ip verb.
m=$(grep -oE 'nft_ipc_request "[a-z_]+"' "$NFTBAN_LIB_DIR/lib/nftban_botguard_explain.sh" | grep -oE '"[a-z_]+"' | tr -d '"' | sort -u)
[[ "$m" == "explain_ip" ]] || fail "explain client must only call explain_ip, found: $m"
# No cache-mutation subcommand/verb tokens in the touched CLI surfaces.
if grep -rnE "cache_(add|trust|block|set)|botguard_cache_set|nftban cache (add|trust|block|set)" \
    "$NFTBAN_LIB_DIR/lib/nftban_botguard_explain.sh" \
    "$NFTBAN_LIB_DIR/cli/cmd_search.sh" "$NFTBAN_LIB_DIR/cli/cmd_emulate.sh" "$NFTBAN_LIB_DIR/cli/cmd_debug.sh" 2>/dev/null; then
    fail "no cache-mutation command/verb may exist on these surfaces"
fi
pass "NO_CACHE_MUTATION_COMMANDS_EXIST"

# === NO_SHELL_PARALLEL_CACHE_CREATED ===
workdir="$tmp/work"; mkdir -p "$workdir"
( cd "$workdir" && HOME="$workdir" ok_resp blocked_temporarily scanner; \
  HOME="$workdir" nftban_botguard_explain_json 1.2.3.4 >/dev/null; \
  HOME="$workdir" nftban_botguard_explain_render 1.2.3.4 >/dev/null )
created=$(find "$workdir" -type f | wc -l)
[[ "$created" -eq 0 ]] || fail "explain client must not create any shell-side cache file (found $created)"
pass "NO_SHELL_PARALLEL_CACHE_CREATED"

# === EXPLAIN_QUERY_DOES_NOT_MUTATE_CACHE ===
: > "$STUB_METHODS"; ok_resp blocked_temporarily scanner
nftban_botguard_explain_json 1.2.3.4 >/dev/null
nftban_botguard_explain_render 1.2.3.4 >/dev/null
nftban_botguard_explain_emulate_note 1.2.3.4 >/dev/null
badm=$(grep -vx "explain_ip" "$STUB_METHODS" | sort -u || true)
[[ -z "$badm" ]] || fail "explain path must ONLY use explain_ip, saw mutation methods: $badm"
pass "EXPLAIN_QUERY_DOES_NOT_MUTATE_CACHE"

# === Registry / export alignment (operator instruction) ===
grep -q 'export -f nftban_debug_botguard' "$NFTBAN_LIB_DIR/cli/cmd_debug.sh" || fail "nftban_debug_botguard must be exported"
grep -q 'botguard <ip>' "$NFTBAN_LIB_DIR/cli/cmd_debug.sh" || fail "debug usage must list botguard <ip>"
pass "DEBUG_BOTGUARD_EXPORT_AND_USAGE_ALIGNED"

echo
echo "ALL PASS: BotGuard explain shell client (v1.191 8B inc6B1)"
