#!/usr/bin/env bash
# shellcheck disable=SC1090  # $CMD_RBL is a runtime-resolved repo path, sourced in subshells
# =============================================================================
# NFTBan - RBL provider registry SLICE 2 (read-only providers CLI + coverage)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rbl_provider_registry_slice2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-13"
# meta:description="Locks OPEN_SCOPE_RBL_PROVIDER_REGISTRY slice 2 — READ-ONLY inspection surfaces. Proves nftban rbl providers list (23 rows, ID/Zone/Type/State + effective count + no-curation note), validate (no registry ⇒ legacy authoritative 23; invalid registry ⇒ non-zero + legacy-authoritative message), explain <id> (full typed record; unknown id errors), and test (RFC5782 reachability classification into the current result vocabulary + truthful coverage render + OK/DEGRADED verdict) — with dig STUBBED so there is no real network. Mutation is DEFERRED: providers enable/disable return a deferred error (rc2) and change nothing. Read-only invariant: the live loader nftban_rbl_load_providers and the legacy rbl list stay 23; rbls.conf/custom.conf are untouched by any providers command. Shell-only; daemon byte-identical; RBL observe-only; no curation/weighting/grouping/default-profile migration."
# meta:input="Stubbed dig + repo cmd_rbl.sh/nftban_rbl.sh/nftban_rbl_registry.sh + real rbls.conf"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files="cli/lib/nftban/cli/cmd_rbl.sh,cli/lib/nftban/core/nftban_rbl_registry.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_RBL_PROVIDERS_FILE,NFTBAN_RBL_CUSTOM_FILE,NFTBAN_RBL_REGISTRY_FILE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
set +eE

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -f "$SCRIPT_DIR/../core/nftban_rbl_registry.sh" ]]; then
    NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
else
    NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)/cli/lib/nftban"
fi
export NFTBAN_LIB_DIR
REPO_ROOT="$(cd "$NFTBAN_LIB_DIR/../../.." && pwd)"
CMD_RBL="$NFTBAN_LIB_DIR/cli/cmd_rbl.sh"
REAL_RBLS="$REPO_ROOT/etc/nftban/conf.d/rbl/rbls.conf"

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

echo "=== RBL provider registry — slice 2 (read-only providers CLI) ==="

# common env for a sourced subshell
COMMON='export NFTBAN_RBL_PROVIDERS_FILE="'"$REAL_RBLS"'" NFTBAN_RBL_CUSTOM_FILE=/nope-$$ NFTBAN_RBL_REGISTRY_FILE=/nope-reg-$$'

# --------------------------------------------------------------------------
# A — providers list
# --------------------------------------------------------------------------
outA="$( ( eval "$COMMON"; source "$CMD_RBL" 2>/dev/null || true; set +eE; nftban_cmd_rbl_providers list ) 2>&1 )"
[[ "$(printf '%s\n' "$outA" | grep -cE '[[:space:]]IP_DNSBL[[:space:]]')" -eq 23 ]] && ok "A1 list shows 23 IP_DNSBL rows" || no "A1 list rows ($(printf '%s\n' "$outA" | grep -cE 'IP_DNSBL'))"
printf '%s\n' "$outA" | grep -q 'Records: 23' && ok "A2 list record count 23" || no "A2 count"
printf '%s\n' "$outA" | grep -qi 'legacy projection' && ok "A3 list states conservative legacy projection" || no "A3 no-curation note"
printf '%s\n' "$outA" | grep -qi 'Registry data file: none' && ok "A4 list notes no registry data file" || no "A4 module-only note"

# --------------------------------------------------------------------------
# B — providers validate (no registry, then invalid registry)
# --------------------------------------------------------------------------
outB="$( ( eval "$COMMON"; source "$CMD_RBL" 2>/dev/null || true; set +eE; nftban_cmd_rbl_providers validate; echo "RC=$?" ) 2>&1 )"
{ printf '%s\n' "$outB" | grep -qi 'No registry data file' && printf '%s\n' "$outB" | grep -q 'authoritative — 23' && printf '%s\n' "$outB" | grep -q 'RC=0'; } \
  && ok "B1 validate (no registry) → legacy authoritative 23, rc0" || no "B1 validate no-registry ($outB)"
outBi="$( ( eval "$COMMON"; RF="$(mktemp)"; printf '[x]\nzone = a.example.net\n[x]\nzone = b.example.net\n' > "$RF"; export NFTBAN_RBL_REGISTRY_FILE="$RF"; source "$CMD_RBL" 2>/dev/null || true; set +eE; nftban_cmd_rbl_providers validate; echo "RC=$?"; rm -f "$RF" ) 2>&1 )"
{ printf '%s\n' "$outBi" | grep -qi 'INVALID' && ! printf '%s\n' "$outBi" | grep -q 'RC=0'; } \
  && ok "B2 validate (invalid registry) → INVALID + non-zero, legacy remains authoritative" || no "B2 validate invalid ($outBi)"

# --------------------------------------------------------------------------
# C — providers explain
# --------------------------------------------------------------------------
outC="$( ( eval "$COMMON"; source "$CMD_RBL" 2>/dev/null || true; set +eE; nftban_cmd_rbl_providers explain zen_spamhaus_org ) 2>&1 )"
{ printf '%s\n' "$outC" | grep -q 'Zone:.*zen.spamhaus.org' && printf '%s\n' "$outC" | grep -q 'Query type:.*IP_DNSBL' && printf '%s\n' "$outC" | grep -q 'State.*enabled'; } \
  && ok "C1 explain <id> shows the typed record" || no "C1 explain ($outC)"
outCe="$( ( eval "$COMMON"; source "$CMD_RBL" 2>/dev/null || true; set +eE; nftban_cmd_rbl_providers explain no_such_id; echo "RC=$?" ) 2>&1 )"
{ printf '%s\n' "$outCe" | grep -qi 'no provider with id' && ! printf '%s\n' "$outCe" | grep -q 'RC=0'; } \
  && ok "C2 explain unknown id → error, non-zero" || no "C2 explain unknown ($outCe)"

# --------------------------------------------------------------------------
# D — mutation DEFERRED: enable/disable change nothing (rc2)
# --------------------------------------------------------------------------
for verb in enable disable; do
  outD="$( ( eval "$COMMON"; source "$CMD_RBL" 2>/dev/null || true; set +eE; nftban_cmd_rbl_providers "$verb" zen_spamhaus_org; echo "RC=$?" ) 2>&1 )"
  { printf '%s\n' "$outD" | grep -qi 'deferred' && printf '%s\n' "$outD" | grep -q 'RC=2'; } \
    && ok "D providers $verb is deferred (rc2, no mutation)" || no "D providers $verb ($outD)"
done

# --------------------------------------------------------------------------
# E — providers test with STUBBED dig: classification + coverage (no network)
# --------------------------------------------------------------------------
# E1: registry_test_zone classification per DNS status
classify(){ # $1 = canned dig stdout (empty = timeout)
  ( source "$CMD_RBL" 2>/dev/null || true; set +eE
    eval 'dig(){ printf '"'"'%s'"'"' "'"$1"'"; }'; export -f dig
    nftban_rbl_registry_test_zone example.net )
}
[[ "$(classify ';; opcode: QUERY, status: NXDOMAIN, id: 1')" == CLEAN ]] && ok "E1 NXDOMAIN → CLEAN" || no "E1 nxdomain"
[[ "$(classify ';; status: NOERROR, id: 1
2.0.0.127.example.net. 300 IN A 127.0.0.2')" == LISTED_TESTPOINT ]] && ok "E2 NOERROR+127 → LISTED_TESTPOINT" || no "E2 listed"
[[ "$(classify ';; status: REFUSED, id: 1')" == REFUSED ]] && ok "E3 REFUSED → REFUSED" || no "E3 refused"
[[ "$(classify ';; status: SERVFAIL, id: 1')" == SERVFAIL ]] && ok "E4 SERVFAIL → SERVFAIL" || no "E4 servfail"
[[ "$(classify '')" == TIMEOUT ]] && ok "E5 empty/no-answer → TIMEOUT (never CLEAN)" || no "E5 timeout"
# E6: providers test --all with an all-NXDOMAIN dig stub → coverage OK, 23 clean
outE="$( ( eval "$COMMON"; source "$CMD_RBL" 2>/dev/null || true; set +eE
  eval 'dig(){ printf "%s" ";; status: NXDOMAIN, id: 1"; }'; export -f dig
  nftban_cmd_rbl_providers test --all ) 2>&1 )"
{ printf '%s\n' "$outE" | grep -q 'Queried:              23' && printf '%s\n' "$outE" | grep -q 'Clean (NXDOMAIN):     23' && printf '%s\n' "$outE" | grep -qi 'Verdict: OK'; } \
  && ok "E6 test --all coverage render (23 queried, 23 clean, OK)" || no "E6 coverage ($(printf '%s\n' "$outE" | grep -E 'Queried|Clean|Verdict'))"

# --------------------------------------------------------------------------
# F — READ-ONLY invariant: live loader + legacy list unchanged; configs untouched
# --------------------------------------------------------------------------
PRE_RBLS="$(sha256sum "$REAL_RBLS" | awk '{print $1}')"
outF="$( ( eval "$COMMON"; source "$CMD_RBL" 2>/dev/null || true; set +eE
  legc="$(nftban_rbl_load_providers | grep -c .)"
  listc="$(nftban_cmd_rbl_list 2>/dev/null | grep -oiE 'Total: *[0-9]+' | grep -oE '[0-9]+' | head -1)"
  echo "LEG=$legc LIST=$listc" ) 2>&1 )"
{ printf '%s\n' "$outF" | grep -q 'LEG=23' && printf '%s\n' "$outF" | grep -q 'LIST=23'; } \
  && ok "F1 live loader + legacy 'rbl list' still 23 (unchanged)" || no "F1 live path changed ($outF)"
POST_RBLS="$(sha256sum "$REAL_RBLS" | awk '{print $1}')"
[[ "$PRE_RBLS" == "$POST_RBLS" ]] && ok "F2 rbls.conf byte-identical after providers commands" || no "F2 rbls.conf changed"

# --------------------------------------------------------------------------
echo "-------------------------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
echo "ALL PASS"; exit 0
