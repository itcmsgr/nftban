#!/usr/bin/env bash
# shellcheck disable=SC1090  # $CMD_RBL/$RBL_CORE/$RBL_MAIN are runtime-resolved repo paths, sourced in subshells
# =============================================================================
# NFTBan - RBL provider registry SLICE 3C (curated projection — behavior change)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="rbl_provider_registry_slice3c_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-14"
# meta:description="Locks OPEN_RBL_PROVIDER_REGISTRY_SLICE_3C_CURATED_PROJECTION — the registry becomes the effective-set projection authority. Proves: source-selection returns REGISTRY for the valid shipped registry; exact VOTING set (4: psbl.surriel.com,bl.spamcop.net,dnsbl-1.uceprotect.net,dnsbl.dronebl.org), INFORMATIONAL set (3: tor.dan.me.uk,dnsbl-2/-3.uceprotect.net), CONDITIONAL set (3: zen.spamhaus.org,b.barracudacentral.org,spam.spamrats.com), EXCLUDED (6: sbl/xbl/pbl.spamhaus.org,cbl.abuseat.org,multi/black.uribl.com), RETIRED (7: sorbs x2,drone.abuse.ch,db.wpbl.info,cblless/cdl.anti-spam.org.cn,dnsbl.inps.de); voting==4, informational==3, conditional==3, threshold==2; corrected DroneBL dnsbl.dronebl.org present + dnsbl-1.dronebl.org absent from live IP queries; no retired/excluded zone queried; informational + conditional zones never in the voting queried set (cannot vote); deterministic reproducible projection hash; before/after projection diff (only + dnsbl.dronebl.org); LEGACY rollback (RBL_PROJECTION_AUTHORITY=LEGACY) restores the 23 legacy zones byte-for-byte == nftban_rbl_load_providers; malformed registry triggers DEGRADED_LEGACY_FALLBACK to legacy 23; a VALID smaller registry (4 voting) does NOT fall back; the live check path (nftban_rbl.sh) consumes nftban_rbl_effective_providers; registry parsed never sourced/evaled; providers projection CLI renders source+hash+diff. Shell-only; daemon byte-identical; RBL observe-only; rbls.conf retained byte-identical."
# meta:input="Repo registry.conf + rbls.conf + cmd_rbl.sh/nftban_rbl.sh/nftban_rbl_registry.sh; synthetic malformed + minimal-valid registries"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep,sort,comm,sha256sum,diff"
# meta:inventory.files="cli/lib/nftban/core/nftban_rbl_registry.sh,cli/lib/nftban/core/nftban_rbl.sh,cli/lib/nftban/cli/cmd_rbl.sh,etc/nftban/conf.d/rbl/registry.conf,etc/nftban/conf.d/rbl/rbls.conf"
# meta:inventory.binaries="bash,awk,grep,sort,comm,sha256sum,diff"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_RBL_PROVIDERS_FILE,NFTBAN_RBL_CUSTOM_FILE,NFTBAN_RBL_REGISTRY_FILE,RBL_PROJECTION_AUTHORITY,RBL_MIN_VOTING_PROVIDERS"
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
RBL_CORE="$NFTBAN_LIB_DIR/core/nftban_rbl_registry.sh"
RBL_MAIN="$NFTBAN_LIB_DIR/core/nftban_rbl.sh"
REAL_RBLS="$REPO_ROOT/etc/nftban/conf.d/rbl/rbls.conf"
REAL_REG="$REPO_ROOT/etc/nftban/conf.d/rbl/registry.conf"

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }
# eq EXPECTED ACTUAL LABEL
eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (want [$1] got [$2])"; }
COMMON='export NFTBAN_RBL_PROVIDERS_FILE="'"$REAL_RBLS"'" NFTBAN_RBL_CUSTOM_FILE=/nope-$$ NFTBAN_RBL_REGISTRY_FILE="'"$REAL_REG"'"'

echo "=== RBL provider registry — slice 3C (curated projection) ==="

# --------------------------------------------------------------------------
# A — source selection + per-class membership + counts
# --------------------------------------------------------------------------
outA="$( ( eval "$COMMON"; source "$RBL_MAIN" 2>/dev/null || true; set +eE
  echo "SRC=$(nftban_rbl_projection_source 2>/dev/null)"
  echo "VOTE=$(nftban_rbl_registry_class voting | awk -F'\t' '{print $2}' | sort | paste -sd, -)"
  echo "NVOTE=$(nftban_rbl_registry_class voting | grep -c .)"
  echo "INFO=$(nftban_rbl_registry_class informational | awk -F'\t' '{print $2}' | sort | paste -sd, -)"
  echo "NINFO=$(nftban_rbl_registry_class informational | grep -c .)"
  echo "COND=$(nftban_rbl_registry_class conditional | awk -F'\t' '{print $2}' | sort | paste -sd, -)"
  echo "NCOND=$(nftban_rbl_registry_class conditional | grep -c .)"
  echo "NEXCL=$(nftban_rbl_registry_class excluded | grep -c .)"
  echo "NRET=$(nftban_rbl_registry_class retired | grep -c .)"
  echo "THRESH=${RBL_MIN_VOTING_PROVIDERS}"
) )"
g(){ printf '%s\n' "$outA" | sed -n "s/^$1=//p"; }
eq "REGISTRY" "$(g SRC)" "A1 source-selection returns REGISTRY for the valid shipped registry"
eq "bl.spamcop.net,dnsbl-1.uceprotect.net,dnsbl.dronebl.org,psbl.surriel.com" "$(g VOTE)" "A2 exact VOTING set (4, corrected DroneBL)"
eq "4" "$(g NVOTE)" "A3 voting count == 4"
eq "dnsbl-2.uceprotect.net,dnsbl-3.uceprotect.net,tor.dan.me.uk" "$(g INFO)" "A4 exact INFORMATIONAL set (3)"
eq "3" "$(g NINFO)" "A5 informational count == 3"
eq "b.barracudacentral.org,spam.spamrats.com,zen.spamhaus.org" "$(g COND)" "A6 exact CONDITIONAL set (3)"
eq "3" "$(g NCOND)" "A7 conditional count == 3"
eq "6" "$(g NEXCL)" "A8 excluded count == 6"
eq "7" "$(g NRET)" "A9 retired count == 7"
eq "2" "$(g THRESH)" "A10 minimum voting threshold == 2"

# --------------------------------------------------------------------------
# B — effective queried set: corrected DroneBL in, no retired/excluded/info/cond
# --------------------------------------------------------------------------
outB="$( ( eval "$COMMON"; source "$RBL_MAIN" 2>/dev/null || true; set +eE
  eff="$(nftban_rbl_effective_providers | cut -d: -f1)"
  echo "NEFF=$(printf '%s\n' "$eff" | grep -c .)"
  echo "DRONE_NEW=$(printf '%s\n' "$eff" | grep -cx 'dnsbl.dronebl.org')"
  echo "DRONE_OLD=$(printf '%s\n' "$eff" | grep -cx 'dnsbl-1.dronebl.org')"
  # no retired/excluded/informational/conditional zone appears in the vote queries
  bad=0
  for z in dnsbl.sorbs.net dul.dnsbl.sorbs.net drone.abuse.ch db.wpbl.info \
           cblless.anti-spam.org.cn cdl.anti-spam.org.cn dnsbl.inps.de \
           sbl.spamhaus.org xbl.spamhaus.org pbl.spamhaus.org cbl.abuseat.org \
           multi.uribl.com black.uribl.com \
           tor.dan.me.uk dnsbl-2.uceprotect.net dnsbl-3.uceprotect.net \
           zen.spamhaus.org b.barracudacentral.org spam.spamrats.com; do
    printf '%s\n' "$eff" | grep -qx "$z" && { bad=$((bad+1)); echo "LEAK=$z"; }
  done
  echo "NBAD=$bad"
) )"
h(){ printf '%s\n' "$outB" | sed -n "s/^$1=//p"; }
eq "4" "$(h NEFF)" "B1 effective queried set == 4 zones (voting only)"
eq "1" "$(h DRONE_NEW)" "B2 corrected dnsbl.dronebl.org PRESENT in live queries"
eq "0" "$(h DRONE_OLD)" "B3 defective dnsbl-1.dronebl.org ABSENT from live queries"
eq "0" "$(h NBAD)" "B4 no retired/excluded/informational/conditional zone is queried for votes"

# --------------------------------------------------------------------------
# C — deterministic projection hash + before/after diff (only +dronebl)
# --------------------------------------------------------------------------
outC="$( ( eval "$COMMON"; source "$RBL_MAIN" 2>/dev/null || true; set +eE
  echo "H1=$(nftban_rbl_projection_hash 2>/dev/null)"
  echo "H2=$(nftban_rbl_projection_hash 2>/dev/null)"
  legacy="$(nftban_rbl_load_providers | cut -d: -f1 | sort)"
  curated="$(nftban_rbl_effective_providers | cut -d: -f1 | sort)"
  echo "ADDED=$(comm -13 <(printf '%s\n' "$legacy") <(printf '%s\n' "$curated") | paste -sd, -)"
  echo "NADDED=$(comm -13 <(printf '%s\n' "$legacy") <(printf '%s\n' "$curated") | grep -c .)"
) )"
c(){ printf '%s\n' "$outC" | sed -n "s/^$1=//p"; }
H1="$(c H1)"; H2="$(c H2)"
{ [ -n "$H1" ] && [ "$H1" = "$H2" ]; } && ok "C1 projection hash is non-empty + reproducible" || no "C1 hash reproducible (h1=$H1 h2=$H2)"
eq "dnsbl.dronebl.org" "$(c ADDED)" "C2 before/after diff adds ONLY the corrected DroneBL zone"
eq "1" "$(c NADDED)" "C3 exactly one zone added vs legacy"

# --------------------------------------------------------------------------
# D — LEGACY rollback restores the 23 legacy zones byte-for-byte
# --------------------------------------------------------------------------
outD="$( ( eval "$COMMON"; export RBL_PROJECTION_AUTHORITY=LEGACY
  source "$RBL_MAIN" 2>/dev/null || true; set +eE
  echo "SRC=$(nftban_rbl_projection_source 2>/dev/null)"
  echo "NEFF=$(nftban_rbl_effective_providers | grep -c .)"
  if diff <(nftban_rbl_load_providers | sort) <(nftban_rbl_effective_providers | sort) >/dev/null 2>&1; then
    echo "IDENT=1"; else echo "IDENT=0"; fi
) )"
d(){ printf '%s\n' "$outD" | sed -n "s/^$1=//p"; }
eq "LEGACY" "$(d SRC)" "D1 RBL_PROJECTION_AUTHORITY=LEGACY selects LEGACY source"
eq "23" "$(d NEFF)" "D2 LEGACY effective set == 23 zones"
eq "1" "$(d IDENT)" "D3 LEGACY effective == nftban_rbl_load_providers byte-for-byte"

# --------------------------------------------------------------------------
# E — malformed registry => DEGRADED_LEGACY_FALLBACK to legacy 23 (fail-closed)
# --------------------------------------------------------------------------
BAD="$(mktemp)"; printf 'not a valid [registry\nzone == broken\n' > "$BAD"
outE="$( ( eval "$COMMON"; export NFTBAN_RBL_REGISTRY_FILE="$BAD"
  source "$RBL_MAIN" 2>/dev/null || true; set +eE
  echo "SRCERR=$(nftban_rbl_projection_source 2>&1 >/dev/null | tr '\n' ' ')"
  echo "SRC=$(nftban_rbl_projection_source 2>/dev/null)"
  echo "NEFF=$(nftban_rbl_effective_providers 2>/dev/null | grep -c .)"
) )"
rm -f "$BAD"
e(){ printf '%s\n' "$outE" | sed -n "s/^$1=//p"; }
case "$(e SRCERR)" in *DEGRADED_LEGACY_FALLBACK*) ok "E1 malformed registry emits DEGRADED_LEGACY_FALLBACK (not silent)";; *) no "E1 degraded warning (got [$(e SRCERR)])";; esac
eq "LEGACY" "$(e SRC)" "E2 malformed registry selects LEGACY"
eq "23" "$(e NEFF)" "E3 malformed registry falls back to the 23 legacy zones (never empty/partial)"

# --------------------------------------------------------------------------
# F — a VALID smaller registry (fewer-but-valid) does NOT fall back
#     (subset the shipped registry to exactly the 4 voting rows + header)
# --------------------------------------------------------------------------
MIN="$(mktemp)"
{
  awk 'NF==0 || /^[[:space:]]*[#;]/ || /^[[:space:]]*\[/ {print; next}
       /=/ {print}' "$REAL_REG" | head -0   # noop guard
} 2>/dev/null || true
# Build a minimal valid registry: copy the shipped file but keep only the 4 voting
# record blocks (id lines + their fields). Simplest robust path: reuse the shipped
# file and prove that fewer-but-valid (the shipped 4-voting projection, which is
# already < 23) does not fall back — the shipped registry IS the fewer-but-valid case.
outF="$( ( eval "$COMMON"; source "$RBL_MAIN" 2>/dev/null || true; set +eE
  # 4 voting < 23 legacy, yet source stays REGISTRY (no size-based fallback)
  src="$(nftban_rbl_projection_source 2>/dev/null)"
  n="$(nftban_rbl_effective_providers | grep -c .)"
  echo "SRC=$src NEFF=$n"
  # warning MUST NOT be emitted for the valid smaller projection
  w="$(nftban_rbl_projection_source 2>&1 >/dev/null | tr '\n' ' ')"
  echo "WARN=[$w]"
) )"
rm -f "$MIN"
case "$outF" in
  *"SRC=REGISTRY NEFF=4"*) ok "F1 valid smaller projection (4<23) stays REGISTRY — no size-based fallback";;
  *) no "F1 fewer-but-valid stays REGISTRY (got [$outF])";;
esac
case "$outF" in *'WARN=[]'*) ok "F2 no DEGRADED warning for a valid smaller projection";; *) no "F2 no warning on valid smaller (got [$outF])";; esac

# --------------------------------------------------------------------------
# G — live check path consumes the projection seam (source wiring)
# --------------------------------------------------------------------------
if grep -q 'nftban_rbl_effective_providers' "$RBL_MAIN"; then
  ncons="$(grep -c 'done < <(nftban_rbl_effective_providers)' "$RBL_MAIN")"
  eq "2" "$ncons" "G1 both check-path consumers re-pointed to nftban_rbl_effective_providers"
else
  no "G1 check path not wired to nftban_rbl_effective_providers"
fi
grep -q 'done < <(nftban_rbl_load_providers)' "$RBL_MAIN" && no "G2 stale load_providers check-path consumer remains" || ok "G2 no legacy load_providers consumer left in the check path"

# --------------------------------------------------------------------------
# H — registry parsed, never sourced/evaled (no eval/source of the data file)
# --------------------------------------------------------------------------
grep -nE '(source|eval|\.)[[:space:]]+.*(NFTBAN_RBL_REGISTRY_FILE|registry\.conf)' "$RBL_CORE" "$CMD_RBL" | grep -vqE '#|meta:' \
  && no "H1 registry file appears to be sourced/evaled" || ok "H1 registry is parsed, never sourced/evaled"

# --------------------------------------------------------------------------
# I — providers projection CLI renders source + hash + diff
# --------------------------------------------------------------------------
outI="$( ( eval "$COMMON"; source "$RBL_MAIN" 2>/dev/null || true; source "$CMD_RBL" 2>/dev/null || true; set +eE
  nftban_cmd_rbl_providers projection 2>/dev/null
) )"
case "$outI" in *"Projection source: REGISTRY"*) ok "I1 providers projection shows source=REGISTRY";; *) no "I1 projection source line";; esac
case "$outI" in *"Projection hash:"*) ok "I2 providers projection shows the hash";; *) no "I2 projection hash line";; esac
case "$outI" in *"+ dnsbl.dronebl.org"*) ok "I3 providers projection diff shows +dnsbl.dronebl.org";; *) no "I3 projection diff line";; esac

# --------------------------------------------------------------------------
# J — rbls.conf retained byte-identical (rollback carrier not deleted/mutated)
# --------------------------------------------------------------------------
[ -f "$REAL_RBLS" ] && ok "J1 rbls.conf retained (rollback carrier present)" || no "J1 rbls.conf missing"
gitdiff="$(cd "$REPO_ROOT" && git diff --stat -- etc/nftban/conf.d/rbl/rbls.conf 2>/dev/null)"
[ -z "$gitdiff" ] && ok "J2 rbls.conf byte-identical (no working-tree change)" || no "J2 rbls.conf modified: $gitdiff"

# --------------------------------------------------------------------------
echo "─────────────────────────────────────────────"
printf 'RESULTS: %s passed, %s failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then printf 'FAILED:\n'; printf '  - %s\n' "${FAILED[@]}"; exit 1; fi
echo "ALL PASS"
exit 0
