#!/usr/bin/env bash
# shellcheck disable=SC1090  # $CMD_RBL/$RBL_CORE are runtime-resolved repo paths, sourced in subshells
# =============================================================================
# NFTBan - RBL provider registry SLICE 3A (typed metadata curation)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rbl_provider_registry_slice3a_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-13"
# meta:description="Locks OPEN_SCOPE_RBL_PROVIDER_REGISTRY slice 3A — typed provider METADATA. Proves the shipped registry.conf: validates deterministically; carries exactly one record per configured rbls.conf zone (23) with unique stable IDs; every record has an ISO audit_date + confidence + license (UNVERIFIED rendered verbatim, never inferred permitted); valid enums incl the new scope/access/role tokens; the accepted metadata decisions are encoded (Spamhaus ZEN=AGGREGATE/conditional, SBL/XBL/PBL=COMPONENT/excluded, CBL replacement=xbl.spamhaus.org, URIBL=DOMAIN_URIBL/excluded, UCEPROTECT L1/L2/L3 scopes, tor=TOR_EXIT/CLASSIFICATION, Barracuda=REGISTERED_RESOLVER, SpamRATS=CREDENTIALED, DroneBL replacement=EXTERNAL:dnsbl.dronebl.org, dead providers=retired, anti-spam.org.cn UNUSABLE_FROM_TESTED_RESOLVER+HIGH_STATUS_LOW_SEMANTICS). The METADATA OVERLAY never changes membership: effective==legacy byte-identical, 23 zones in order, providers enable/disable still rc2. Validator negatives: replacement cycle, undeclared non-EXTERNAL replacement, missing audit_date, missing license, unsafe injection all fail. Registry is parsed, never sourced/evaled. providers list+explain expose the metadata. Shell-only; daemon byte-identical; RBL observe-only; rbls.conf byte-identical."
# meta:input="Repo registry.conf + rbls.conf + cmd_rbl.sh/nftban_rbl.sh/nftban_rbl_registry.sh; synthetic negatives"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep,sort"
# meta:inventory.files="cli/lib/nftban/core/nftban_rbl_registry.sh,cli/lib/nftban/cli/cmd_rbl.sh,etc/nftban/conf.d/rbl/registry.conf,etc/nftban/conf.d/rbl/rbls.conf"
# meta:inventory.binaries="bash,awk,grep,sort"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_RBL_PROVIDERS_FILE,NFTBAN_RBL_CUSTOM_FILE,NFTBAN_RBL_REGISTRY_FILE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="rbl_provider_registry_slice3a_test"
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
CMD_RBL="$NFTBAN_LIB_DIR/cli/cmd_rbl.sh"
RBL_CORE="$NFTBAN_LIB_DIR/core/nftban_rbl_registry.sh"
REAL_RBLS="$REPO_ROOT/etc/nftban/conf.d/rbl/rbls.conf"
REAL_REG="$REPO_ROOT/etc/nftban/conf.d/rbl/registry.conf"

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
COMMON='export NFTBAN_RBL_PROVIDERS_FILE="'"$REAL_RBLS"'" NFTBAN_RBL_CUSTOM_FILE=/nope-$$ NFTBAN_RBL_REGISTRY_FILE="'"$REAL_REG"'"'

echo "=== RBL provider registry — slice 3A (typed metadata) ==="

# --------------------------------------------------------------------------
# A — shipped registry validates + one record per configured zone + unique ids
# --------------------------------------------------------------------------
outA="$( ( eval "$COMMON"; source "$RBL_CORE" 2>/dev/null || true; set +eE
  nftban_rbl_registry_validate "$REAL_REG"; echo "VRC=$?"
  recs="$(nftban_rbl_registry_parse "$REAL_REG")"
  echo "N=$(printf '%s\n' "$recs" | grep -c .)"
  echo "IDS=$(printf '%s\n' "$recs" | awk -F'\t' '{print $1}' | sort -u | grep -c .)"
  # registry zones == rbls.conf zones (membership authority)
  rz="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$REAL_RBLS" | cut -d: -f1 | sed 's/[[:blank:]]//g' | grep . | sort)"
  gz="$(printf '%s\n' "$recs" | awk -F'\t' '{print $2}' | sort)"
  [ "$rz" = "$gz" ] && echo "ZMATCH=1" || echo "ZMATCH=0"
  # every record carries ISO audit_date + non-empty confidence + license
  bad=$(printf '%s\n' "$recs" | awk -F'\t' '$13!~/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/ || $14=="" || $15==""{n++} END{print n+0}')
  echo "MISS=$bad"
) 2>&1 )"
grep -q 'VRC=0' <<<"$outA" && ok "A1 shipped registry.conf validates (rc0)" || no "A1 registry invalid ($outA)"
grep -q 'N=23' <<<"$outA" && ok "A2 exactly 23 typed records" || no "A2 record count ($(grep -o 'N=[0-9]*' <<<"$outA"))"
grep -q 'IDS=23' <<<"$outA" && ok "A3 23 unique stable IDs" || no "A3 ids ($(grep -o 'IDS=[0-9]*' <<<"$outA"))"
grep -q 'ZMATCH=1' <<<"$outA" && ok "A4 exactly one record per configured rbls.conf zone" || no "A4 zone mismatch"
grep -q 'MISS=0' <<<"$outA" && ok "A5 every record carries ISO audit_date + confidence + license" || no "A5 missing metadata ($(grep -o 'MISS=[0-9]*' <<<"$outA"))"

# --------------------------------------------------------------------------
# B — METADATA OVERLAY never changes membership (effective==legacy, 23, order, rc2)
# --------------------------------------------------------------------------
outB="$( ( eval "$COMMON"; source "$CMD_RBL" 2>/dev/null || true; set +eE
  leg="$(nftban_rbl_load_providers)"; eff="$(nftban_rbl_registry_effective 2>/dev/null)"
  [ "$leg" = "$eff" ] && echo "EFFEQ=1" || echo "EFFEQ=0"
  echo "RECS=$(nftban_rbl_registry_records | grep -c .)"
  # legacy rbl list still 23
  echo "LIST=$(nftban_cmd_rbl_list 2>/dev/null | grep -oiE 'Total: *[0-9]+' | grep -oE '[0-9]+' | head -1)"
  nftban_cmd_rbl_providers enable spamhaus_zen >/dev/null 2>&1; echo "EN=$?"
  nftban_cmd_rbl_providers disable spamhaus_zen >/dev/null 2>&1; echo "DIS=$?"
) 2>&1 )"
{ grep -q 'EFFEQ=1' <<<"$outB" && grep -q 'RECS=23' <<<"$outB" && grep -q 'LIST=23' <<<"$outB"; } \
  && ok "B1 overlay: effective==legacy, 23 records, legacy rbl list=23 (membership unchanged)" || no "B1 membership changed ($outB)"
{ grep -q 'EN=2' <<<"$outB" && grep -q 'DIS=2' <<<"$outB"; } && ok "B2 providers enable/disable still rc2 (non-mutating)" || no "B2 enable/disable ($outB)"

# --------------------------------------------------------------------------
# C — accepted metadata decisions encoded (explain <id>)
# --------------------------------------------------------------------------
xget(){ ( eval "$COMMON"; source "$CMD_RBL" 2>/dev/null || true; set +eE; nftban_cmd_rbl_providers explain "$1" 2>/dev/null ); }
chk(){ printf '%s\n' "$2" | grep -qE "$3"; } # $1 label $2 text $3 regex
E="$(xget spamhaus_zen)"; { chk _ "$E" 'Role:.*AGGREGATE' && chk _ "$E" 'State.*conditional' && chk _ "$E" 'Access:.*DQS'; } && ok "C1 Spamhaus ZEN = AGGREGATE/conditional/DQS" || no "C1 zen ($E)"
E="$(xget spamhaus_sbl)"; { chk _ "$E" 'Role:.*COMPONENT' && chk _ "$E" 'Group:.*spamhaus' && chk _ "$E" 'State.*excluded'; } && ok "C2 SBL = COMPONENT/spamhaus/excluded" || no "C2 sbl"
E="$(xget cbl_abuseat)"; chk _ "$E" 'Replacement:.*xbl.spamhaus.org' && ok "C3 CBL replacement = xbl.spamhaus.org (declared)" || no "C3 cbl repl"
E="$(xget uribl_multi)"; { chk _ "$E" 'Query type:.*DOMAIN_URIBL' && chk _ "$E" 'State.*excluded'; } && ok "C4 URIBL = DOMAIN_URIBL/excluded" || no "C4 uribl"
E1="$(xget uceprotect_l1)"; E2="$(xget uceprotect_l2)"; E3="$(xget uceprotect_l3)"
{ chk _ "$E1" 'Scope:.*MAIL_REPUTATION' && chk _ "$E2" 'Scope:.*NETWORK_ALLOCATION' && chk _ "$E3" 'Scope:.*ASN_REPUTATION'; } && ok "C5 UCEPROTECT L1=IP / L2=allocation / L3=ASN" || no "C5 uceprotect"
E="$(xget tor_dan)"; { chk _ "$E" 'Scope:.*TOR_EXIT' && chk _ "$E" 'Role:.*CLASSIFICATION'; } && ok "C6 tor.dan = TOR_EXIT/CLASSIFICATION" || no "C6 tor"
E="$(xget barracuda_brbl)"; chk _ "$E" 'Access:.*REGISTERED_RESOLVER' && ok "C7 Barracuda = REGISTERED_RESOLVER" || no "C7 barracuda"
E="$(xget spamrats)"; { chk _ "$E" 'Access:.*CREDENTIALED' && chk _ "$E" 'State.*conditional'; } && ok "C8 SpamRATS = CREDENTIALED/conditional" || no "C8 spamrats"
# 3A locked the zone-defect replacement metadata (stable); Slice 3C owns the state
# (dronebl activated disabled→enabled at the corrected zone). Lock the persistent
# 3A invariant (replacement=EXTERNAL:dnsbl.dronebl.org); state is asserted by slice3c.
E="$(xget dronebl)"; chk _ "$E" 'Replacement:.*EXTERNAL:dnsbl.dronebl.org' && ok "C9 DroneBL zone-defect replacement=EXTERNAL:dnsbl.dronebl.org" || no "C9 dronebl"

# --------------------------------------------------------------------------
# D — lifecycle: dead=retired; anti-spam.org.cn separates status from semantics;
#     UNVERIFIED license rendered verbatim (never inferred permitted)
# --------------------------------------------------------------------------
for id in sorbs_dnsbl sorbs_dul wpbl inps_de abusech_drone casa_cblless casa_cdl; do
  E="$(xget "$id")"; chk _ "$E" 'State.*retired' || { no "D dead provider $id not retired"; break; }
done
[ $FAIL -eq 0 ] && ok "D1 all shutdown/defunct providers state=retired" 2>/dev/null || true
E="$(xget casa_cblless)"; { chk _ "$E" 'Operational:.*UNUSABLE_FROM_TESTED_RESOLVER' && chk _ "$E" 'Confidence:.*HIGH_STATUS_LOW_SEMANTICS'; } \
  && ok "D2 anti-spam.org.cn: UNUSABLE_FROM_TESTED_RESOLVER + HIGH_STATUS_LOW_SEMANTICS" || no "D2 casa ($E)"
E="$(xget sorbs_dnsbl)"; chk _ "$E" 'License:.*UNVERIFIED' && ok "D3 UNVERIFIED license rendered verbatim (never inferred permitted)" || no "D3 license"

# --------------------------------------------------------------------------
# E — validator NEGATIVES (each deterministically rejected)
# --------------------------------------------------------------------------
reg(){ mktemp; }
val(){ ( eval "$COMMON"; source "$RBL_CORE" 2>/dev/null || true; set +eE; nftban_rbl_registry_validate "$1" >/dev/null 2>&1; echo "rc=$?" ); }
base='operational_status = OK
audit_date = 2026-07-13
confidence = HIGH
license = UNVERIFIED'
CYC="$(reg)"; printf '[a]\nzone = a.example.net\nreplacement = b\n%s\n[b]\nzone = b.example.net\nreplacement = a\n%s\n' "$base" "$base" > "$CYC"
grep -q 'rc=0' <<<"$(val "$CYC")" && no "E1 replacement cycle not caught" || ok "E1 replacement cycle rejected"
UND="$(reg)"; printf '[a]\nzone = a.example.net\nreplacement = c.example.net\n%s\n' "$base" > "$UND"
grep -q 'rc=0' <<<"$(val "$UND")" && no "E2 undeclared non-EXTERNAL replacement not caught" || ok "E2 undeclared replacement rejected"
NOAUD="$(reg)"; printf '[a]\nzone = a.example.net\noperational_status = OK\nconfidence = HIGH\nlicense = UNVERIFIED\n' > "$NOAUD"
grep -q 'rc=0' <<<"$(val "$NOAUD")" && no "E3 missing audit_date not caught" || ok "E3 missing audit_date rejected"
NOLIC="$(reg)"; printf '[a]\nzone = a.example.net\noperational_status = OK\naudit_date = 2026-07-13\nconfidence = HIGH\n' > "$NOLIC"
grep -q 'rc=0' <<<"$(val "$NOLIC")" && no "E4 missing license not caught" || ok "E4 missing license rejected"
INJ="$(reg)"; printf '[a]\nzone = a.example.net\nlicense = free$(rm -rf x)\n%s\n' "$base" > "$INJ"
grep -q 'rc=0' <<<"$(val "$INJ")" && no "E5 unsafe injection not caught" || ok "E5 unsafe field content rejected"
EXT="$(reg)"; printf '[a]\nzone = a.example.net\nreplacement = EXTERNAL:good.example.org\n%s\n' "$base" > "$EXT"
grep -q 'rc=0' <<<"$(val "$EXT")" && ok "E6 EXTERNAL:<dnsname> replacement accepted" || no "E6 EXTERNAL replacement rejected"
rm -f "$CYC" "$UND" "$NOAUD" "$NOLIC" "$INJ" "$EXT"

# --------------------------------------------------------------------------
# F — registry parsed, never sourced/evaled; rbls.conf byte-identical
# --------------------------------------------------------------------------
grep -qE '(^|[^_a-z])(source|eval)[[:space:]]+"?\$?\{?NFTBAN_RBL_REGISTRY_FILE|(source|\.)[[:space:]].*registry\.conf' "$RBL_CORE" \
  && no "F1 registry sourced/evaled" || ok "F1 registry never sourced/evaled"
PRE="$(sha256sum "$REAL_RBLS" | awk '{print $1}')"
( eval "$COMMON"; source "$CMD_RBL" 2>/dev/null || true; set +eE; nftban_cmd_rbl_providers list >/dev/null 2>&1; nftban_cmd_rbl_providers validate >/dev/null 2>&1 )
[ "$PRE" = "$(sha256sum "$REAL_RBLS" | awk '{print $1}')" ] && ok "F2 rbls.conf byte-identical after providers commands" || no "F2 rbls.conf changed"

# --------------------------------------------------------------------------
echo "-------------------------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
echo "ALL PASS"; exit 0
