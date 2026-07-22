#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.167 PR-2 guard: CLI output-truth / flag-parity
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_output_truth_v167_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-08"
# meta:description="Hermetic guard for v1.167 PR-2 (CLI output-truth + flag-parity, shell-only, daemon byte-identical). Covers four fixes. (B) JSON no-jq fallback escaping: json_escape() in helpers/json_output.sh produces valid JSON for input containing a double-quote and a backslash, and the cmd_botscan.sh + cmd_debug.sh no-jq fallbacks route their free-form string fields through json_escape(). (C) UX-C5 flag-parity: nftban update --dry-run is caught by an explicit early guard in cmd_update.sh that emits the 3-line ERROR/Hint/Run via _v144_error_with_hint and returns rc=1, instead of routing to the generic Unknown-command path. (D) UX-INFO: the human-readable validate render in cmd_firewall.sh applies a shell-side INFO-severity filter by default (mirrors cmd_health.sh) with a --verbose / NFTBAN_VALIDATE_VERBOSE=1 opt-in; --json output is unaffected. (E) stats label casing: the cache-hit Data source value is all-caps (UNIFIED CACHE) consistent with its DERIVED sibling and the all-caps section headers; the legitimate logic-backed DERIVED cache-miss label is retained (it is NOT spec residue), and no DERIVED badge leaks into cmd_stats.sh / cmd_status.sh. Static + hermetic; sources only helpers/json_output.sh; no daemon, no nft, no host mutation."
# meta:inventory.files="cli/lib/nftban/helpers/json_output.sh,cli/lib/nftban/cli/cmd_botscan.sh,cli/lib/nftban/cli/cmd_debug.sh,cli/lib/nftban/cli/cmd_update.sh,cli/lib/nftban/cli/cmd_firewall.sh,cli/lib/nftban/core/nftban_stats_format.sh"
# meta:inventory.binaries="bash,grep,jq"
# meta:inventory.env_vars="NFTBAN_VALIDATE_VERBOSE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cli_output_truth_v167_test"
# meta:ta.owner="cli"
# meta:ta.module="output-truth"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$TEST_DIR/.." && pwd)"   # cli/lib/nftban

JSON_HELPER="$LIB_DIR/helpers/json_output.sh"
BOTSCAN="$LIB_DIR/cli/cmd_botscan.sh"
DEBUG="$LIB_DIR/cli/cmd_debug.sh"
UPDATE="$LIB_DIR/cli/cmd_update.sh"
FIREWALL="$LIB_DIR/cli/cmd_firewall.sh"
STATS_FMT="$LIB_DIR/core/nftban_stats_format.sh"
STATS_CMD="$LIB_DIR/cli/cmd_stats.sh"
STATUS_CMD="$LIB_DIR/cli/cmd_status.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

for f in "$JSON_HELPER" "$BOTSCAN" "$DEBUG" "$UPDATE" "$FIREWALL" "$STATS_FMT" "$STATS_CMD" "$STATUS_CMD"; do
    [[ -f "$f" ]] || { echo "FATAL: missing required file: $f" >&2; exit 1; }
done

echo "v1.167 PR-2 CLI output-truth / flag-parity guard:"

# =============================================================================
# (B) JSON no-jq fallback escaping
# =============================================================================
echo "[B] JSON no-jq fallback escaping"

# json_escape() must exist in the helper and produce valid JSON for nasty input.
# Source the helper in a subshell so its `set -Eeuo pipefail` / module guard
# does not leak into this test's shell.
B_IN='val with "quote" and \backslash'
B_OUT="$(
    set +e
    # shellcheck source=/dev/null
    source "$JSON_HELPER" >/dev/null 2>&1
    json_escape "$B_IN"
)"

if [[ -n "$B_OUT" ]]; then
    ok "json_escape() is defined and returns output"
else
    no "json_escape() produced no output (helper missing the escaper?)"
fi

# Build a tiny JSON document the same way the fallbacks do and validate it.
B_DOC="{\"field\":\"$B_OUT\"}"
if command -v jq >/dev/null 2>&1; then
    if printf '%s' "$B_DOC" | jq -e . >/dev/null 2>&1; then
        ok "escaped value yields valid JSON (jq parses {\"field\":\"...\"})"
    else
        no "escaped value did NOT yield valid JSON" "$B_DOC"
    fi
    # Round-trip: the decoded value must equal the original raw input.
    B_BACK="$(printf '%s' "$B_DOC" | jq -r '.field' 2>/dev/null || echo '__FAIL__')"
    if [[ "$B_BACK" == "$B_IN" ]]; then
        ok "escaped value round-trips back to the original (quote + backslash preserved)"
    else
        no "round-trip mismatch" "got:[$B_BACK] want:[$B_IN]"
    fi
else
    echo "  (jq not installed — skipping JSON-parse assertions for (B))"
fi

# The fallback branches must actually call json_escape (not raw-interpolate).
if grep -q 'json_escape "\$action_mode"' "$BOTSCAN"; then
    ok "cmd_botscan.sh no-jq fallback escapes \$action_mode"
else
    no "cmd_botscan.sh fallback does not call json_escape on \$action_mode"
fi
if grep -q 'json_escape "\$trace_log"' "$DEBUG" && grep -q 'json_escape "\$log_level"' "$DEBUG"; then
    ok "cmd_debug.sh no-jq fallback escapes \$trace_log and \$log_level"
else
    no "cmd_debug.sh fallback does not escape \$trace_log / \$log_level"
fi

# =============================================================================
# (C) UX-C5 flag-parity: update --dry-run
# =============================================================================
echo "[C] update --dry-run flag-parity guard"

# Static guard present, routed through _v144_error_with_hint, before dispatch.
if grep -qE '\$cmd" == "--dry-run"|grep -qx -- .--dry-run' "$UPDATE"; then
    ok "cmd_update.sh has an explicit --dry-run guard"
else
    no "cmd_update.sh missing the explicit --dry-run guard"
fi
if grep -q -- '--dry-run is not supported' "$UPDATE" \
   && grep -q '_v144_error_with_hint' "$UPDATE"; then
    ok "guard emits the 'not supported' message via _v144_error_with_hint"
else
    no "guard message / helper wiring missing"
fi

# The guard must sit BEFORE the case dispatch (so it never reaches Unknown-command).
guard_ln=$(grep -nE 'is not supported for .nftban update' "$UPDATE" | head -1 | cut -d: -f1 || true)
case_ln=$(grep -nE '^[[:space:]]*case "\$cmd" in' "$UPDATE" | head -1 | cut -d: -f1 || true)
if [[ -n "$guard_ln" && -n "$case_ln" && "$guard_ln" -lt "$case_ln" ]]; then
    ok "guard precedes the 'case \$cmd' dispatch (guard@$guard_ln < case@$case_ln)"
else
    no "guard not strictly before dispatch" "guard@${guard_ln:-?} case@${case_ln:-?}"
fi

# =============================================================================
# (D) UX-INFO: validate shell-side INFO filter
# =============================================================================
echo "[D] validate INFO-severity shell filter"

if grep -q 'select((.severity | ascii_downcase) != "info")' "$FIREWALL"; then
    ok "cmd_firewall.sh default render drops INFO-severity findings (jq select)"
else
    no "cmd_firewall.sh default render does NOT filter INFO findings"
fi
if grep -qF -- '--verbose|-v' "$FIREWALL" && grep -q 'NFTBAN_VALIDATE_VERBOSE' "$FIREWALL"; then
    ok "INFO filter has --verbose / NFTBAN_VALIDATE_VERBOSE opt-in"
else
    no "missing --verbose / NFTBAN_VALIDATE_VERBOSE opt-in"
fi
# verbose path must still emit ALL findings (un-filtered branch present)
if grep -q 'verbose_mode" == "true"' "$FIREWALL"; then
    ok "verbose branch present (shows all findings when opted in)"
else
    no "verbose branch missing"
fi

# Hermetic behavior check: emulate the exact render branch on a sample payload.
if command -v jq >/dev/null 2>&1; then
    SAMPLE='{"status":"protected","findings":[{"severity":"info","code":"VAL-X-001","message":"m1"},{"severity":"warn","code":"VAL-Y-002","message":"m2"}]}'
    default_render="$(printf '%s' "$SAMPLE" | jq -r '.findings[] | select((.severity | ascii_downcase) != "info") | "  [\(.severity | ascii_upcase)] \(.code): \(.message)"')"
    verbose_render="$(printf '%s' "$SAMPLE" | jq -r '.findings[] | "  [\(.severity | ascii_upcase)] \(.code): \(.message)"')"
    if ! grep -q 'VAL-X-001' <<<"$default_render" && grep -q 'VAL-Y-002' <<<"$default_render"; then
        ok "default filter hides INFO (VAL-X-001) but keeps WARN (VAL-Y-002)"
    else
        no "default filter behavior wrong" "$default_render"
    fi
    if grep -q 'VAL-X-001' <<<"$verbose_render"; then
        ok "verbose render surfaces the hidden INFO finding"
    else
        no "verbose render did not surface INFO" "$verbose_render"
    fi
else
    echo "  (jq not installed — skipping behavioral INFO-filter assertions for (D))"
fi

# =============================================================================
# (E) stats DERIVED residue + label casing
# =============================================================================
echo "[E] stats label casing + DERIVED residue"

# No DERIVED badge leaks into the command surfaces named for badge removal.
if ! grep -qi 'DERIVED' "$STATS_CMD" && ! grep -qi 'DERIVED' "$STATUS_CMD"; then
    ok "no DERIVED badge in cmd_stats.sh / cmd_status.sh"
else
    no "DERIVED token present in cmd_stats.sh / cmd_status.sh (expected none)"
fi

# The cache-hit Data source value is now all-caps (casing-consistent).
if grep -qE 'Data source[.]+" "UNIFIED CACHE"' "$STATS_FMT"; then
    ok "cache-hit Data source value is UNIFIED CACHE (casing-consistent)"
else
    no "cache-hit Data source value not aligned to UNIFIED CACHE"
fi

# The legitimate cache-miss DERIVED label (logic-backed, V127 UX-3) is RETAINED.
if grep -qE 'Data source[.]+" "DERIVED \(cache miss' "$STATS_FMT"; then
    ok "legitimate DERIVED cache-miss data-source label retained (not spec residue)"
else
    no "legitimate DERIVED cache-miss label was lost"
fi

# =============================================================================
# SUMMARY
# =============================================================================
echo
echo "v1.167 PR-2 guard: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
