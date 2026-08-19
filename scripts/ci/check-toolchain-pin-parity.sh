#!/usr/bin/env bash
# =============================================================================
# NFTBan CI — GO TOOLCHAIN PIN PARITY  (v1.229.4 VAF-0 Stage 2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="check-toolchain-pin-parity"
# meta:type="ci"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="BLOCKING. THE single authority for GO_TOOLCHAIN_PIN_PARITY. go.mod is the canonical Go version; every registered live workflow pin must equal it. PR-C moved 20 live declarations across 19 files with no guard at all, and the SOFT-COUPLED pins (jobs without GOTOOLCHAIN=local) would have drifted SILENTLY because Go auto-upgrades to satisfy go.mod and the job still goes green. Asserts BOTH value parity and location parity, so a pin cannot diverge, vanish, or appear unregistered. Static; reads go.mod, the declared pin population and the workflow files; no host."
# meta:inventory.files="go.mod,scripts/ci/data/go-toolchain-pins.tsv,.github/workflows"
# meta:inventory.privileges="none"
# =============================================================================
#
#   CANONICAL_VERSION   go.mod `go X`                  <- the only value authority
#   EXPECTED_POPULATION scripts/ci/data/go-toolchain-pins.tsv  <- READ, never generated
#   OBSERVED_VALUES     parsed from those exact declared locations
#
#   ⛔ THE EXPECTED POPULATION IS NOT DISCOVERED BY GREPPING FOR THE CURRENT VERSION.
#      CURRENT REALITY -> GENERATES EXPECTATION -> VALIDATES CURRENT REALITY
#      = SELF-CONSISTENCY, NOT FALSIFIABILITY.
#
#   TWO INDEPENDENT ASSERTIONS:
#      VALUE PARITY     every registered pin == canonical go.mod version
#      LOCATION PARITY  classified live pin set == declared expected set, BOTH DIRECTIONS
#
#   Location parity is the half that catches tomorrow's 20th pin. Without it, a new
#   workflow could introduce an unregistered live toolchain pin and this guard would
#   never know it exists.
#
#   ⛔ DISCOVERY IS VALUE-INDEPENDENT. It recognises the declaration FORM, never the
#      version string — a pin left at an old version must still be DISCOVERED, then fail
#      value parity. Discovery keyed on the current version would be blind to exactly the
#      drift it exists to catch.
#
#   ⛔ HISTORICAL REFERENCE != LIVE DECLARATION. Comments and CHANGELOG entries naming an
#      old Go version are correct history and must never fail this guard.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GOMOD="$ROOT/go.mod"
DECL="$ROOT/scripts/ci/data/go-toolchain-pins.tsv"
WFDIR="$ROOT/.github/workflows"
RC=0
ok(){ echo "  [PASS] $1"; }
no(){ echo "  [FAIL] $1"; RC=1; }

echo "=== Go toolchain pin parity (v1.229.4 VAF-0 Stage 2) ==="
# ⛔ Repo-resident subjects: absence is a FAILURE, never a skip.
[[ -f "$GOMOD" ]] || { echo "  SUBJECT_NOT_FOUND: $GOMOD"; echo "RESULT: FAIL"; exit 1; }
[[ -d "$WFDIR" ]] || { echo "  SUBJECT_NOT_FOUND: $WFDIR"; echo "RESULT: FAIL"; exit 1; }
if [[ ! -f "$DECL" ]]; then
    echo "  [FAIL] EXPECTED_POPULATION_MISSING: $DECL is absent."
    echo "         ⛔ A MISSING DECLARATION IS NOT AN EMPTY POPULATION — nothing can be asserted."
    echo "RESULT: FAIL"; exit 1
fi

# ---- canonical value authority ------------------------------------------------
CANON="$(awk '/^go [0-9]/{print $2; exit}' "$GOMOD")"
if [[ ! "$CANON" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    no "go.mod carries no parseable 'go <version>' directive (got '${CANON:-<none>}')"
    echo "RESULT: FAIL"; exit 1
fi
ok "canonical Go version from go.mod = $CANON"

# ---- declared expected population ----------------------------------------------
EXPECTED_TOTAL="$(awk -F'\t' '$1=="expected_total"{print $2; exit}' "$DECL" | tr -d '[:space:]')"
[[ "$EXPECTED_TOTAL" =~ ^[0-9]+$ ]] || { no "expected_total is missing or non-numeric"; echo "RESULT: FAIL"; exit 1; }

DECL_ROWS="$(awk -F'\t' '$1=="pin" && NF>=4 {print $2"\t"$3"\t"$4}' "$DECL" | sort)"
DECL_COUNT="$(grep -c . <<<"${DECL_ROWS:-}" || true)"
if [[ "${DECL_COUNT:-0}" -eq 0 ]]; then
    no "EXPECTED_POPULATION_EMPTY: the declaration lists ZERO pin locations."
    echo "         ⛔ 0 LOCATIONS != 0 DIVERGENCES, and 0 DIVERGENCES != PASS."
    echo "RESULT: FAIL"; exit 1
fi
ok "declared population: $DECL_COUNT file/key group(s), expected_total=$EXPECTED_TOTAL live pin(s)"

# ---- VALUE-INDEPENDENT structural discovery -------------------------------------
# Recognises the declaration FORM. A literal value is a live pin whatever it says;
# `${{ ... }}` is a DERIVED reference and inherits from a registered pin in the same file.
discover(){
    python3 - "$WFDIR" <<'PY'
import re,sys,os,glob
pat=re.compile(r'^(?P<pre>[^#]*?)\b(?P<key>go-version|GO_VERSION)\s*:\s*(?P<val>.+?)\s*$')
out={}
for f in sorted(glob.glob(os.path.join(sys.argv[1],"*.yml"))):
    rel=os.path.relpath(f, os.path.dirname(os.path.dirname(sys.argv[1])))
    for line in open(f, encoding="utf-8"):
        if line.lstrip().startswith("#"): continue
        m=pat.match(line.rstrip("\n"))
        if not m: continue
        if m.group("val").strip().startswith("${{"):   # derived reference
            continue
        out[(rel,m.group("key"))]=out.get((rel,m.group("key")),0)+1
for (rel,key),c in sorted(out.items()):
    print("%s\t%s\t%d"%(rel,key,c))
PY
}
OBS_ROWS="$(discover | sort)"
OBS_TOTAL=$(awk -F'\t' '{s+=$3} END{print s+0}' <<<"${OBS_ROWS:-}")

# ---- ASSERTION 1 · LOCATION PARITY (both directions) ----------------------------
UNREGISTERED="$(comm -13 <(printf '%s\n' "$DECL_ROWS") <(printf '%s\n' "$OBS_ROWS"))"
MISSING="$(comm -23 <(printf '%s\n' "$DECL_ROWS") <(printf '%s\n' "$OBS_ROWS"))"
if [[ -z "$UNREGISTERED" && -z "$MISSING" ]]; then
    ok "LOCATION PARITY: classified live pin set == declared expected set"
else
    if [[ -n "$MISSING" ]]; then
        no "DECLARED PIN LOCATION(S) NOT FOUND — a registered pin vanished or changed shape:"
        sed 's/^/           /' <<<"$MISSING"
        echo "           -> If the removal is intended, REMOVE THE ROW deliberately and say why."
    fi
    if [[ -n "$UNREGISTERED" ]]; then
        no "UNREGISTERED LIVE TOOLCHAIN PIN(S) — present in a workflow but outside the authority map:"
        sed 's/^/           /' <<<"$UNREGISTERED"
        echo "           -> A new live Go pin must be REGISTERED in $(basename "$DECL"), not left unclassified."
    fi
fi

# ---- ASSERTION 2 · VALUE PARITY at every declared location ----------------------
CHECKED=0
while IFS=$'\t' read -r file key count; do
    [[ -n "${file:-}" ]] || continue
    path="$ROOT/$file"
    if [[ ! -f "$path" ]]; then
        no "declared pin file is absent: $file"
        continue
    fi
    # value-independent extraction of every literal for this key
    vals="$(python3 - "$path" "$key" <<'PY'
import re,sys
pat=re.compile(r'^[^#]*?\b%s\s*:\s*(.+?)\s*$' % re.escape(sys.argv[2]))
for line in open(sys.argv[1], encoding="utf-8"):
    if line.lstrip().startswith("#"): continue
    m=pat.match(line.rstrip("\n"))
    if not m: continue
    v=m.group(1).strip()
    if v.startswith("${{"): continue
    print(v.strip("'\""))
PY
)"
    found="$(grep -c . <<<"${vals:-}" || true)"
    if [[ "${found:-0}" -ne "$count" ]]; then
        no "$file [$key]: expected $count live pin(s), found ${found:-0}"
        continue
    fi
    while IFS= read -r v; do
        [[ -n "$v" ]] || continue
        CHECKED=$((CHECKED+1))
        if [[ "$v" != "$CANON" ]]; then
            no "$file [$key]: pin '$v' != canonical go.mod '$CANON'"
            echo "           ⛔ SOFT-COUPLED JOB GREEN != DECLARED PIN COHERENT — a job without"
            echo "              GOTOOLCHAIN=local auto-upgrades and passes while the pin lies."
        fi
    done <<<"$vals"
done <<<"$DECL_ROWS"

# ---- observed-count postcondition ----------------------------------------------
if [[ "$CHECKED" -eq "$EXPECTED_TOTAL" ]]; then
    ok "VALUE PARITY: $CHECKED/$EXPECTED_TOTAL registered pin(s) equal the canonical version"
else
    no "COVERAGE SHORT: checked $CHECKED of $EXPECTED_TOTAL declared pins — a partial pass is not a pass"
fi
if [[ "$OBS_TOTAL" -ne "$EXPECTED_TOTAL" ]]; then
    no "observed live pin total $OBS_TOTAL != declared expected_total $EXPECTED_TOTAL"
fi

# ---- the declaration must not become self-generating ---------------------------
if grep -qiE '^\s*(ls|find|grep|awk|python)' "$DECL"; then
    no "the declaration contains enumeration logic — it must be hand-maintained data"
else
    ok "the declaration is declarative data, not a rediscovery of current reality"
fi

echo
[[ $RC -eq 0 ]] && echo "RESULT: toolchain pin parity PASS" || echo "RESULT: toolchain pin parity FAIL"
exit $RC
