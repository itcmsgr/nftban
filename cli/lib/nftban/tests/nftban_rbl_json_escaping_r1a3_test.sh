#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.198 R1a-3 `rbl check --json` escaping (7.3/11.6)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_rbl_json_escaping_r1a3_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-21"
# meta:description="Regression coverage for rbl check --json escaping (cluster 7.3/11.6). The attacker-influenced RBL TXT reason can contain quote/backslash/newline; the JSON object builders (nftban_rbl_json_listed_obj/_status_obj via jq --arg, with the _nftban_rbl_json_str no-jq fallback) must emit valid JSON that round-trips. Production fix predates this (v1.150); this test locks it in."
# meta:input="None (sources core/nftban_rbl.sh; canned TXT fixtures)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,jq"
# meta:inventory.files=""
# meta:inventory.binaries="bash,jq"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="nftban_rbl_json_escaping_r1a3_test"
# meta:ta.owner="rbl"
# meta:ta.module="rbl-json-escaping"
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
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR
RBL="${NFTBAN_LIB_DIR}/core/nftban_rbl.sh"
# shellcheck source=/dev/null
source "$RBL"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1"; }

# valid-JSON + round-trip check for a listed-obj reason field
check_reason() {
    local label="$1" reason="$2"
    local obj rt
    obj=$(nftban_rbl_json_listed_obj "zen.example.org" "$reason" "http://info.example/x")
    if ! printf '%s' "$obj" | jq -e . >/dev/null 2>&1; then bad "$label: not valid JSON"; return; fi
    rt=$(printf '%s' "$obj" | jq -r '.reason')
    if [[ "$rt" == "$reason" ]]; then ok "$label: valid JSON + reason round-trips"; else bad "$label: reason round-trip mismatch"; fi
}

echo "R1a-3 rbl check --json escaping — regression tests"

# 1-5: the five escaping cases on the attacker-influenced TXT reason
check_reason "T1 double-quote"  'blocked: see "policy" page'
check_reason "T2 backslash"     'path C:\\temp\\block reason'
check_reason "T3 newline"       $'line one\nline two'
check_reason "T4 mixed q+bs+nl" $'he said "x" \\ then\nnewline'
check_reason "T5 normal"        'listed in zen; see policy'

# 6: status-obj is valid JSON
if printf '%s' "$(nftban_rbl_json_status_obj "b.barracudacentral.org" "rate_limited" "http://i")" | jq -e . >/dev/null 2>&1; then ok "T6 status-obj is valid JSON"; else bad "T6 status-obj invalid"; fi

# 7: the no-jq fallback escaper produces a valid JSON string that round-trips
NF=$(_nftban_rbl_json_str $'a"b\\c\nd')
if printf '{"reason":%s}' "$NF" | jq -e . >/dev/null 2>&1; then
    rt=$(printf '{"reason":%s}' "$NF" | jq -r .reason)
    [[ "$rt" == $'a"b\\c\nd' ]] && ok "T7 _nftban_rbl_json_str fallback: valid JSON + round-trips" || bad "T7 fallback round-trip mismatch"
else
    bad "T7 fallback produced invalid JSON"
fi

# 8: wiring guard — the rbl check path routes LISTED TXT through the escaped builder (not raw concat)
if grep -qF 'nftban_rbl_json_listed_obj "$rbl_domain" "$txt_record" "$rbl_url"' "$RBL"; then ok "T8 rbl check --json routes raw TXT through the escaped builder"; else bad "T8 rbl check --json no longer uses the escaped builder (regression)"; fi

# 9: helpers present
for fn in nftban_rbl_json_listed_obj nftban_rbl_json_status_obj _nftban_rbl_json_str; do
    declare -F "$fn" >/dev/null 2>&1 && ok "T9 $fn defined" || bad "T9 $fn missing"
done

echo "-----------------------------------------------"
printf 'R1a-3 rbl-json tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
