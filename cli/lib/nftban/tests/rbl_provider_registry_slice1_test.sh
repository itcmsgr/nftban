#!/usr/bin/env bash
# =============================================================================
# NFTBan - RBL provider registry SLICE 1 (substrate + flat-list compatibility)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rbl_provider_registry_slice1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-13"
# meta:description="Locks OPEN_SCOPE_RBL_PROVIDER_REGISTRY slice 1. Proves the additive registry substrate NEVER changes provider membership: registry-absent ⇒ nftban_rbl_registry_effective is byte-identical to nftban_rbl_load_providers (real rbls.conf → 23, order preserved); legacy bare zones project into CONSERVATIVE typed records (IP_DNSBL/enabled/PRIMARY/own-group/no-weight); nftban_rbl_registry_records yields one such record per effective zone. Validator is deterministic: duplicate id, duplicate zone, invalid enum, invalid zone name, structural malformation, and unsafe shell content each FAIL; a valid registry passes. A malformed/invalid registry artifact present ⇒ effective STILL returns the authoritative legacy set (never empty). No runtime YAML (INI blocks parsed line-by-line, never sourced). Shell-only; daemon byte-identical; RBL observe-only; rbls.conf unchanged."
# meta:input="Stubbed providers/registry temp files + repo nftban_rbl.sh/nftban_rbl_registry.sh + real rbls.conf"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,sort,cut"
# meta:inventory.files="cli/lib/nftban/core/nftban_rbl_registry.sh,cli/lib/nftban/core/nftban_rbl.sh,etc/nftban/conf.d/rbl/rbls.conf"
# meta:inventory.binaries="bash,sort,cut"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_RBL_PROVIDERS_FILE,NFTBAN_RBL_CUSTOM_FILE,NFTBAN_RBL_REGISTRY_FILE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="rbl_provider_registry_slice1_test"
# meta:ta.owner="rbl"
# meta:ta.module="rbl-provider-registry"
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
set +eE

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -f "$SCRIPT_DIR/../core/nftban_rbl_registry.sh" ]]; then
    NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
else
    NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)/cli/lib/nftban"
fi
export NFTBAN_LIB_DIR
REPO_ROOT="$(cd "$NFTBAN_LIB_DIR/../../.." && pwd)"
RBL_CORE="$NFTBAN_LIB_DIR/core/nftban_rbl.sh"
REAL_RBLS="$REPO_ROOT/etc/nftban/conf.d/rbl/rbls.conf"

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

echo "=== RBL provider registry — slice 1 (substrate + flat-list compat) ==="

# --------------------------------------------------------------------------
# A — registry-absent ⇒ effective byte-identical to legacy; real rbls.conf → 23
# --------------------------------------------------------------------------
(
  # shellcheck source=/dev/null
  source "$RBL_CORE" 2>/dev/null || true
  set +eE
  export NFTBAN_RBL_PROVIDERS_FILE="$REAL_RBLS"
  export NFTBAN_RBL_CUSTOM_FILE="/nonexistent-cust-$$"
  export NFTBAN_RBL_REGISTRY_FILE="/nonexistent-reg-$$"
  leg="$(nftban_rbl_load_providers 2>/dev/null)"
  eff="$(nftban_rbl_registry_effective 2>/dev/null)"
  [[ "$leg" == "$eff" ]] && echo "A1_OK" || echo "A1_FAIL"
  echo "A_COUNT=$(printf '%s\n' "$eff" | grep -c .)"
  # order preserved: identical line-by-line
  diff <(printf '%s\n' "$leg") <(printf '%s\n' "$eff") >/dev/null 2>&1 && echo "A_ORDER_OK" || echo "A_ORDER_FAIL"
) > /tmp/rA.$$ 2>&1
grep -q A1_OK /tmp/rA.$$ && ok "A1 registry-absent effective == legacy (byte-identical)" || no "A1 effective != legacy"
grep -q 'A_COUNT=23' /tmp/rA.$$ && ok "A2 real rbls.conf effective count == 23" || no "A2 count ($(grep A_COUNT /tmp/rA.$$))"
grep -q A_ORDER_OK /tmp/rA.$$ && ok "A3 provider order preserved" || no "A3 order changed"
rm -f /tmp/rA.$$

# --------------------------------------------------------------------------
# B — legacy bare zone → conservative typed record; records() per zone
# --------------------------------------------------------------------------
(
  # shellcheck source=/dev/null
  source "$RBL_CORE" 2>/dev/null || true
  set +eE
  rec="$(nftban_rbl_registry_legacy_record zen.spamhaus.org https://x/)"
  # columns: id zone query_type scope family access weight role group state info_url
  echo "B_ID=$(printf '%s' "$rec" | cut -f1)"
  echo "B_QT=$(printf '%s' "$rec" | cut -f3)"
  echo "B_FAM=$(printf '%s' "$rec" | cut -f5)"
  echo "B_ACC=$(printf '%s' "$rec" | cut -f6)"
  echo "B_WT=[$(printf '%s' "$rec" | cut -f7)]"
  echo "B_ROLE=$(printf '%s' "$rec" | cut -f8)"
  echo "B_GRP=$(printf '%s' "$rec" | cut -f9)"
  echo "B_STATE=$(printf '%s' "$rec" | cut -f10)"
  # records() over a 2-zone providers file: 2 records, all IP_DNSBL + enabled
  PF="$(mktemp)"; printf 'a.example.net:u1\nb.example.org:u2\n' > "$PF"
  export NFTBAN_RBL_PROVIDERS_FILE="$PF" NFTBAN_RBL_CUSTOM_FILE="/nope-$$"
  recs="$(nftban_rbl_registry_records 2>/dev/null)"
  echo "B_RECS=$(printf '%s\n' "$recs" | grep -c .)"
  echo "B_ALLIP=$(printf '%s\n' "$recs" | awk -F'\t' '$3!="IP_DNSBL"{n++} END{print n+0}')"
  echo "B_ALLEN=$(printf '%s\n' "$recs" | awk -F'\t' '$10!="enabled"{n++} END{print n+0}')"
  rm -f "$PF"
) > /tmp/rB.$$ 2>&1
b="$(cat /tmp/rB.$$)"; rm -f /tmp/rB.$$
grep -q 'B_ID=zen_spamhaus_org' <<<"$b" && ok "B1 legacy id = slugified zone" || no "B1 id ($b)"
{ grep -q 'B_QT=IP_DNSBL' <<<"$b" && grep -q 'B_FAM=IPV4_IPV6' <<<"$b" && grep -q 'B_ACC=PUBLIC' <<<"$b" && grep -q 'B_WT=\[\]' <<<"$b" && grep -q 'B_ROLE=PRIMARY' <<<"$b" && grep -q 'B_STATE=enabled' <<<"$b"; } && ok "B2 conservative defaults (IP_DNSBL/IPV4_IPV6/PUBLIC/no-weight/PRIMARY/enabled)" || no "B2 defaults ($b)"
grep -q 'B_GRP=zen_spamhaus_org' <<<"$b" && ok "B3 own-group (nothing grouped/deduped)" || no "B3 group ($b)"
grep -q 'B_RECS=2' <<<"$b" && ok "B4 records() = one record per effective zone" || no "B4 records count ($b)"
{ grep -q 'B_ALLIP=0' <<<"$b" && grep -q 'B_ALLEN=0' <<<"$b"; } && ok "B5 every projected record IP_DNSBL + enabled" || no "B5 non-conservative record ($b)"

# --------------------------------------------------------------------------
# C — validator: deterministic failures + valid passes
# --------------------------------------------------------------------------
reg(){ mktemp; }
runval(){
  # shellcheck source=/dev/null
  ( source "$RBL_CORE" 2>/dev/null || true; set +eE; nftban_rbl_registry_validate "$1" >/tmp/verr.$$ 2>&1; echo "rc=$?"; )
}

VALID="$(reg)"; cat > "$VALID" <<'EOF'
[spamhaus_zen]
zone = zen.spamhaus.org
query_type = IP_DNSBL
family = IPV4_IPV6
access = PUBLIC
role = PRIMARY
group = spamhaus
state = enabled
operational_status = USABLE_PUBLIC
audit_date = 2026-07-13
confidence = HIGH
license = UNVERIFIED
info_url = https://www.spamhaus.org/zen/

[barracuda]
zone = b.barracudacentral.org
query_type = IP_DNSBL
access = CREDENTIALED
state = conditional
operational_status = UNUSABLE_FROM_TESTED_RESOLVER
audit_date = 2026-07-13
confidence = HIGH
license = UNVERIFIED
EOF
grep -q 'rc=0' <<<"$(runval "$VALID")" && ok "C1 valid registry validates (rc0)" || no "C1 valid rejected"

DUPID="$(reg)"; printf '[x]\nzone = a.example.net\n[x]\nzone = b.example.net\n' > "$DUPID"
grep -q 'rc=0' <<<"$(runval "$DUPID")" && no "C2 duplicate id not caught" || ok "C2 duplicate id fails deterministically"

DUPZONE="$(reg)"; printf '[x]\nzone = a.example.net\n[y]\nzone = a.example.net\n' > "$DUPZONE"
grep -q 'rc=0' <<<"$(runval "$DUPZONE")" && no "C3 duplicate zone not caught" || ok "C3 duplicate zone fails deterministically"

BADENUM="$(reg)"; printf '[x]\nzone = a.example.net\nquery_type = BOGUS\n' > "$BADENUM"
grep -q 'rc=0' <<<"$(runval "$BADENUM")" && no "C4 bad enum not caught" || ok "C4 invalid enum fails deterministically"

BADZONE="$(reg)"; printf '[x]\nzone = not_a_dns_name\n' > "$BADZONE"
grep -q 'rc=0' <<<"$(runval "$BADZONE")" && no "C5 invalid zone not caught" || ok "C5 invalid zone name fails deterministically"

MISSZONE="$(reg)"; printf '[x]\nstate = enabled\n' > "$MISSZONE"
grep -q 'rc=0' <<<"$(runval "$MISSZONE")" && no "C6 missing zone not caught" || ok "C6 missing zone fails deterministically"

MALFORMED="$(reg)"; printf 'zone = a.example.net\n' > "$MALFORMED"   # key outside any block
grep -q 'rc=0' <<<"$(runval "$MALFORMED")" && no "C7 stray-key malformation not caught" || ok "C7 structural malformation fails deterministically"

for inj in 'zone = a.example.net$(rm -rf x)' 'info_url = http://x`id`' 'zone = a.example.net;reboot' 'zone = a|b'; do
  U="$(reg)"; printf '[x]\n%s\n' "$inj" > "$U"
  grep -q 'rc=0' <<<"$(runval "$U")" && { no "C8 unsafe content accepted: $inj"; break; } || U_OK=1
  rm -f "$U"
done
[ "${U_OK:-0}" = 1 ] && ok "C8 unsafe shell content rejected (all 4 injection shapes)" || true
rm -f "$VALID" "$DUPID" "$DUPZONE" "$BADENUM" "$BADZONE" "$MISSZONE" "$MALFORMED" /tmp/verr.$$ 2>/dev/null

# --------------------------------------------------------------------------
# D — invalid registry present ⇒ effective STILL = authoritative legacy (never empty)
# --------------------------------------------------------------------------
(
  # shellcheck source=/dev/null
  source "$RBL_CORE" 2>/dev/null || true
  set +eE
  export NFTBAN_RBL_PROVIDERS_FILE="$REAL_RBLS" NFTBAN_RBL_CUSTOM_FILE="/nope-$$"
  BAD="$(mktemp)"; printf '[x]\nzone = a.example.net\n[x]\nzone = b.example.net\n' > "$BAD"  # dup id (invalid)
  export NFTBAN_RBL_REGISTRY_FILE="$BAD"
  eff="$(nftban_rbl_registry_effective 2>/tmp/dwarn.$$)"
  leg="$(nftban_rbl_load_providers 2>/dev/null)"
  echo "D_EQ=$([[ "$eff" == "$leg" ]] && echo 1 || echo 0)"
  echo "D_COUNT=$(printf '%s\n' "$eff" | grep -c .)"
  echo "D_WARN=$(grep -c 'is invalid' /tmp/dwarn.$$ 2>/dev/null || echo 0)"
  rm -f "$BAD" /tmp/dwarn.$$
) > /tmp/rD.$$ 2>&1
d="$(cat /tmp/rD.$$)"; rm -f /tmp/rD.$$
{ grep -q 'D_EQ=1' <<<"$d" && grep -q 'D_COUNT=23' <<<"$d"; } && ok "D1 invalid registry ⇒ effective == legacy (23, never empty/altered)" || no "D1 invalid registry altered effective ($d)"
grep -q 'D_WARN=1' <<<"$d" && ok "D2 invalid registry warns (ignored, not silent)" || no "D2 no warning ($d)"

# --------------------------------------------------------------------------
# E — no runtime YAML dependency; registry never sourced/evaled
# --------------------------------------------------------------------------
# exclude comment lines (the module's own doc says "no runtime YAML")
grep -vE '^[[:space:]]*#' "$NFTBAN_LIB_DIR/core/nftban_rbl_registry.sh" | grep -qiE '\byq\b|import[[:space:]]+yaml|yaml\.(safe_)?load|--yaml' && no "E1 registry pulls a YAML parser" || ok "E1 no runtime YAML parser"
grep -qE '(^|[^_a-z])source[[:space:]]+"?\$?\{?NFTBAN_RBL_REGISTRY_FILE|eval .*REGISTRY' "$NFTBAN_LIB_DIR/core/nftban_rbl_registry.sh" && no "E2 registry sources/evals the artifact" || ok "E2 registry never sources/evals the artifact"

# --------------------------------------------------------------------------
echo "-------------------------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
echo "ALL PASS"; exit 0
