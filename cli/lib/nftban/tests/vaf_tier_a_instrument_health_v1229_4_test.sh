#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.4 F2a — TIER-A INSTRUMENT-HEALTH CONTROL
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="vaf-tier-a-instrument-health-v1229-4-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-18"
# meta:description="Deterministic per-run health control for the two Tier-A vulnerability instruments. Adoption-time testing does not survive silent decay: the govulncheck converter presumably worked once, then degraded into valid-but-empty SARIF while every run stayed green. Each instrument is exercised against a pinned NATIVE local database and minimal synthetic subjects, asserting hand-declared required IDs and their expected native classification. Proves the instrument can still DISTINGUISH a known finding from clean, not merely that it ran."
# meta:inventory.files="cli/lib/nftban/tests/fixtures/vaf_tier_a"
# meta:inventory.privileges="none"
# meta:ta.id="vaf_tier_a_instrument_health_v1229_4_test"
# meta:ta.owner="cross-cutting"
# meta:ta.module="core"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
#
#   THE PROPERTY UNDER TEST — asked of every Tier-A invocation:
#
#       CAN THIS INVOCATION STILL DISTINGUISH  KNOWN FINDING  from  CLEAN ?
#
#   ⛔ POSITIVE_CONTROL != "some result appeared".
#      A control asserting only that a finding appeared would have passed against the
#      deleted govulncheck converter, which emitted every finding as `warning`. The
#      negative arm therefore asserts a LEVEL TRANSITION (error -> note for the SAME id),
#      not an absence.
#
#   ⛔ EXPECTED ANSWERS ARE HAND-DECLARED AND READ, NEVER GENERATED.
#      Scanner output is not its own expectation authority.
#
#   ⛔ REQUIRED IDS, NEVER TOTAL COUNTS.  CARDINALITY_PRECONDITION is one implementation
#      of INDEPENDENT_EXPECTATION_PRECONDITION, not the universal form.
#
#   ⛔ NO NETWORK. Both databases are local fixtures; both scanners run offline.
#
#   ⛔ INSTRUMENT ABSENT != PASS. An unavailable scanner yields UNAVAILABLE and is never
#      counted as a pass. Set VAF_REQUIRE_INSTRUMENTS=1 (the Tier-A path) to make
#      absence fatal.
#
#   ⛔ WITNESS SUBJECT NOT FOUND != WITNESS SKIPPED != PASS.
#      A harness MUST FAIL when its canonical production subject cannot be located.
#
#   FALSIFICATION EVIDENCE (measured 2026-08-18; these arms are not vacuous):
#      INV-2  swap subjects — expect error where the tool yields note   -> GVC-P DETECTED
#      INV-3  advisory mutated so the vulnerable subject reads as fixed -> OSV-P DETECTED
#      INV-4  vulnerability ID renamed in the local DB                  -> GVC-P/N DETECTED
#      INV-5  DB population emptied entirely                            -> GVC-P/N DETECTED
#      INV-1  advisory's symbol list emptied  = NON-DISCRIMINATING MUTATION (not a pass,
#             not a failed inversion): without symbol data govulncheck falls back to
#             module-level affectedness, so the level legitimately stays `error`.
#      INV-2 is the load-bearing one — it attacks the exact semantic (error vs note) that
#      the deleted converter destroyed by emitting everything as `warning`.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX="$SCRIPT_DIR/fixtures/vaf_tier_a"
EXP="$FIX/expected/EXPECTED_ANSWERS.tsv"
FAIL=0
OSV_STATE=UNAVAILABLE
GVC_STATE=UNAVAILABLE
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }
info(){ echo "        $1"; }

echo "=== VAF Tier-A instrument health (v1.229.4 F2a) ==="
for f in "$EXP" "$FIX/osv/db/osv-scanner/Go/all.zip" "$FIX/govulncheck/db/index/db.json"; do
    [[ -e "$f" ]] || { echo "  SUBJECT_NOT_FOUND: $f"; echo "RESULT: FAIL"; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "  SUBJECT_NOT_FOUND: python3"; echo "RESULT: FAIL"; exit 1; }

# ---- expectation authority: READ, never computed --------------------------------
exp_of(){ awk -F'\t' -v i="$1" -v a="$2" '!/^#/ && $1==i && $2==a {print $3"\t"$4; exit}' "$EXP"; }
req_id(){ exp_of "$1" "$2" | cut -f1; }
req_ex(){ exp_of "$1" "$2" | cut -f2; }

# G0 · the expectation file must not be a scanner artifact ------------------------
# A control whose expectations were produced by the scanner it checks proves only
# self-consistency. Assert the file is declarative TSV, not a scanner output format.
if grep -qE '"\$schema"|"runs"|"sarif"|"results"' "$EXP" 2>/dev/null; then
    fail "G0 the expectation file contains scanner-artifact structure — it may have been generated"
else
    pass "G0 expectation authority is declarative (no SARIF/JSON scanner structure present)"
fi
if [[ -n "$(req_id osv positive)" && -n "$(req_ex govulncheck negative)" ]]; then
    pass "G0b expectations parse: osv/positive=$(req_id osv positive) govulncheck/negative expectation=$(req_ex govulncheck negative)"
else
    fail "G0b expectation rows are missing or unparseable — nothing can be asserted"
    echo "RESULT: FAIL"; exit 1
fi

# ---- fixture identity — CONTENT + FIXTURE-RELATIVE NAME, never the checkout path -----
# ⛔ `sha256sum <file>` SERIALIZES THE PATH INTO ITS OUTPUT. The previous form hashed that
#    output, so the displayed identity changed with the checkout directory: MEASURED
#    e8c24245 vs a38ed47c for BYTE-IDENTICAL fixtures. An identity that varies with where
#    the tree happens to sit is not an identity.
#      CONTENT IDENTITY MUST DERIVE FROM CONTENT BYTES.
#
# Hashing only the sorted CONTENT digests would be path-independent but would also make a
# rename or a member swap invisible, since two different trees sharing a multiset of file
# contents would collide. Fixture MEMBERSHIP is part of what identity means here, so each
# member contributes  <fixture-relative-path> <content-sha256>  and the sorted manifest is
# hashed. Excluded by construction: absolute paths, temp dir names, mtime, ownership and
# filesystem traversal order.
fixture_identity(){
    local root="$1"
    ( cd "$root" 2>/dev/null || return 1
      find . -type f -print0 \
        | LC_ALL=C sort -z \
        | while IFS= read -r -d '' f; do
              printf '%s %s\n' "${f#./}" "$(sha256sum < "$f" | cut -d' ' -f1)"
          done \
        | sha256sum | cut -d' ' -f1 )
}

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT

# =============================================================================
# G1 · REPOSITORY FIXTURE ISOLATION GUARD
# =============================================================================
#
#   ⛔ F2 CONTROL SUBJECT MUST NOT BECOME PRODUCT ANALYSIS SUBJECT
#      unless that is the property being tested.
#
#   REGRESSION WITNESS for a defect this harness committed: the fixture subjects were
#   first stored as LIVE main.go / go.mod. That single choice did three unwanted things
#   at once —
#       1. entered go_changed=true trigger space (a fixture-only PR made the Go security
#          lane run, and it reported the product's real findings)
#       2. entered repository-wide Go/security analysis scope (govulncheck, gosec,
#          CodeQL, Semgrep would carry control source forever)
#       3. acquired unrelated product policy obligations (SPDX header validation)
#
#   ⛔ FIXTURE_SOURCE_PRESENT_IN_REPOSITORY != FIXTURE_ISOLATED_FROM_PRODUCT_ANALYSIS
#   ⛔ SECURITY CONTROL FIXTURES MUST NOT ACCIDENTALLY EXPAND THE PRODUCT SUBJECT OF
#      UNRELATED VALIDATORS.
#
#   The repository stores INERT DATA (*.go.txt / go.mod.txt); the control materializes an
#   ephemeral subject at run time and destroys it. This guard fails if anyone renames the
#   inert data back into live Go files. Bound to the fixture directory ONLY — never a
#   repository-wide search.
LIVE_GO="$(find "$FIX" \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' \) -type f 2>/dev/null)"
if [[ -z "$LIVE_GO" ]]; then
    pass "G1 fixture data is inert — no live *.go / go.mod / go.sum under $(basename "$FIX")"
else
    fail "G1 LIVE GO SOURCE inside the fixture directory — the control subject has re-entered the product Go surface"
    sed 's/^/          /' <<<"$LIVE_GO"
fi

# ---- materialization: inert data -> ephemeral subject ---------------------------
# ⛔ CONTROL MATERIALIZATION != PRODUCT SOURCE MUTATION. Everything below is written
#    inside the mktemp-owned tree and removed by the EXIT trap.
SUBJ="$TMP/subjects"
materialize(){ # $1 = fixture-relative subject dir -> echoes the materialized path
    local src="$FIX/$1" dst="$SUBJ/$1" f base
    mkdir -p "$dst" || return 1
    shopt -s nullglob
    for f in "$src"/*.txt; do
        base="$(basename "$f" .txt)"
        cp -- "$f" "$dst/$base" || return 1
    done
    shopt -u nullglob
    printf '%s' "$dst"
}
MAT_OK=1
for s in govulncheck/subject_positive govulncheck/subject_negative osv/subject_vulnerable osv/subject_fixed; do
    materialize "$s" >/dev/null || { fail "G2 materialization failed for $s"; MAT_OK=0; }
done
# ⛔ Assert the EXACT expected files exist before any scanner is invoked. A scanner
#    pointed at an empty directory reports zero findings and looks clean.
declare -A WANT=(
  [govulncheck/subject_positive]="go.mod main.go"
  [govulncheck/subject_negative]="go.mod main.go"
  [osv/subject_vulnerable]="go.mod"
  [osv/subject_fixed]="go.mod"
)
for s in "${!WANT[@]}"; do
    for w in ${WANT[$s]}; do
        [[ -s "$SUBJ/$s/$w" ]] || { fail "G2 materialized subject $s is missing $w — a scanner would read this as clean"; MAT_OK=0; }
    done
done
if [[ "$MAT_OK" -eq 1 ]]; then
    pass "G2 all four subjects materialized into the temp tree with their exact expected files"
else
    echo "RESULT: FAIL"; exit 1
fi

# =============================================================================
# INSTRUMENT 1 — osv-scanner (version/dependency semantics)
# =============================================================================
echo
echo "--- osv-scanner ---"
OSV_BIN="${OSV_SCANNER_BIN:-$(command -v osv-scanner 2>/dev/null || true)}"
if [[ -z "$OSV_BIN" || ! -x "$OSV_BIN" ]]; then
    info "INSTRUMENT_UNAVAILABLE: osv-scanner not found (set OSV_SCANNER_BIN). ⛔ NOT A PASS."
else
    OSV_VER="$("$OSV_BIN" --version 2>&1 | head -1)"
    info "instrument: $OSV_VER"
    info "db fixture sha256: $(sha256sum "$FIX/osv/db/osv-scanner/Go/all.zip" | cut -d' ' -f1)"
    export OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY="$FIX/osv/db"
    osv_ids(){ # $1 = json path -> newline-separated ids
        python3 -c "
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(9)
print('\n'.join(v['id'] for r in d.get('results',[]) for p in r.get('packages',[]) for v in p.get('vulnerabilities',[])))" "$1"
    }
    RID="$(req_id osv positive)"

    # -- POSITIVE ------------------------------------------------------------
    set +e
    "$OSV_BIN" scan source --lockfile="$SUBJ/osv/subject_vulnerable/go.mod" --offline --no-resolve \
        --format=json --output="$TMP/osv_pos.json" >"$TMP/osv_pos.out" 2>"$TMP/osv_pos.err"
    P_RC=$?
    set -e
    if ! IDS="$(osv_ids "$TMP/osv_pos.json")"; then
        fail "OSV-P artifact is not parseable — ⛔ an unparseable artifact is NOT an empty one (rc=$P_RC)"
    elif grep -qx "$RID" <<<"$IDS"; then
        pass "OSV-P POSITIVE: required id $RID PRESENT (rc=$P_RC) — the instrument still detects"
    else
        fail "OSV-P POSITIVE: required id $RID ABSENT (rc=$P_RC) — instrument cannot detect a known finding"
        info "observed: $(tr '\n' ' ' <<<"$IDS")"
    fi

    # -- NEGATIVE ------------------------------------------------------------
    set +e
    "$OSV_BIN" scan source --lockfile="$SUBJ/osv/subject_fixed/go.mod" --offline --no-resolve \
        --format=json --output="$TMP/osv_neg.json" >"$TMP/osv_neg.out" 2>"$TMP/osv_neg.err"
    N_RC=$?
    set -e
    if ! IDS="$(osv_ids "$TMP/osv_neg.json")"; then
        fail "OSV-N artifact is not parseable (rc=$N_RC)"
    elif grep -qx "$RID" <<<"$IDS"; then
        fail "OSV-N NEGATIVE: $RID reported against the FIXED subject — the instrument cannot discriminate"
    else
        pass "OSV-N NEGATIVE: required id $RID correctly ABSENT for the fixed version (rc=$N_RC)"
    fi

    # -- FAILURE -------------------------------------------------------------
    # ⛔ This arm is EXPECTED TO EXPOSE VAF-C1a. The production classifier labels a
    # database-unavailable failure as "suppression drift". F2 must NOT lower its
    # expectation to accommodate a proven defect — the arm is C1a's regression witness.
    OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY="$TMP/db-absent"
    export OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY
    set +e
    "$OSV_BIN" scan source --lockfile="$SUBJ/osv/subject_vulnerable/go.mod" --offline --no-resolve \
        --format=json --output="$TMP/osv_fail.json" >"$TMP/osv_fail.out" 2>"$TMP/osv_fail.err"
    F_RC=$?
    set -e
    F_IDS="$(osv_ids "$TMP/osv_fail.json" 2>/dev/null || true)"
    F_COUNT="$(grep -c . <<<"${F_IDS:-}" || true)"
    if [[ "$F_RC" -eq 0 ]]; then
        fail "OSV-F FAILURE: DB unavailable returned rc=0 — an observation failure rendered as success"
    elif [[ "${F_COUNT:-0}" -eq 0 ]] && grep -qi 'no offline version of the OSV database' "$TMP/osv_fail.err"; then
        pass "OSV-F FAILURE: DB unavailable -> rc=$F_RC + zero findings + explicit DB diagnostic"
        info "⛔ VALID EMPTY ARTIFACT != CLEAN. rc alone carries this; the artifact looks clean."
        info "⛔ rc=$F_RC is a DB-UNAVAILABLE WITNESS, not a universal scanner-failure code."
    else
        fail "OSV-F FAILURE: DB-unavailable state not identifiable (rc=$F_RC, ids=$F_COUNT)"
    fi
    unset OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY
    OSV_STATE=EXERCISED
fi

# =============================================================================
# INSTRUMENT 2 — govulncheck (source call-reachability semantics)
# =============================================================================
echo
echo "--- govulncheck ---"
GVC_BIN="${GOVULNCHECK_BIN:-$(command -v govulncheck 2>/dev/null || true)}"
GO_BIN="$(command -v go 2>/dev/null || true)"
if [[ -z "$GVC_BIN" || ! -x "$GVC_BIN" || -z "$GO_BIN" ]]; then
    info "INSTRUMENT_UNAVAILABLE: govulncheck and/or go not found (set GOVULNCHECK_BIN). ⛔ NOT A PASS."
else
    info "instrument: $("$GVC_BIN" -version 2>&1 | grep -i '^Scanner:' || echo 'version unknown')"
    info "db fixture identity: $(fixture_identity "$FIX/govulncheck/db")"
    RID="$(req_id govulncheck positive)"
    gvc_level(){ # $1 sarif, $2 id -> level or empty
        python3 -c "
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: sys.exit(9)
print('\n'.join(r.get('level','') for run in d.get('runs',[]) for r in run.get('results',[]) if r.get('ruleId')==sys.argv[2]))" "$1" "$2"
    }
    run_gvc(){ # $1 subject dir, $2 out prefix, $3 db path
        ( cd "$SUBJ/govulncheck/$1" && "$GVC_BIN" -db "file://$3" -format sarif ./... ) \
            >"$TMP/$2.sarif" 2>"$TMP/$2.err"
    }

    # -- POSITIVE ------------------------------------------------------------
    set +e; run_gvc subject_positive gvc_pos "$FIX/govulncheck/db"; P_RC=$?; set -e
    LV="$(gvc_level "$TMP/gvc_pos.sarif" "$RID" 2>/dev/null || echo PARSE_FAIL)"
    if [[ "$LV" == "PARSE_FAIL" ]]; then
        fail "GVC-P SARIF not parseable (rc=$P_RC) — ⛔ unparseable != empty"
    elif [[ "$LV" == "error" ]]; then
        pass "GVC-P POSITIVE: $RID at level=error — REACHABLE correctly identified (rc=$P_RC)"
        info "⛔ rc=$P_RC is expected: SARIF mode exits 0 WITH findings. rc is never the verdict."
    else
        fail "GVC-P POSITIVE: $RID level='$LV', expected 'error'"
    fi

    # -- NEGATIVE (LEVEL TRANSITION, not absence) ----------------------------
    set +e; run_gvc subject_negative gvc_neg "$FIX/govulncheck/db"; N_RC=$?; set -e
    LV="$(gvc_level "$TMP/gvc_neg.sarif" "$RID" 2>/dev/null || echo PARSE_FAIL)"
    if [[ "$LV" == "note" ]]; then
        pass "GVC-N NEGATIVE: $RID STILL PRESENT but at level=note — present-not-proven-reachable"
        info "⛔ This is the semantic the deleted converter destroyed (it emitted everything as 'warning')."
    elif [[ "$LV" == "error" ]]; then
        fail "GVC-N NEGATIVE: $RID still level=error although the symbol is never called — reachability analysis is not discriminating"
    elif [[ -z "$LV" ]]; then
        fail "GVC-N NEGATIVE: $RID absent entirely; expected PRESENT at level=note (the arm asserts a transition, not an absence)"
    else
        fail "GVC-N NEGATIVE: $RID level='$LV', expected 'note'"
    fi

    # -- FAILURE -------------------------------------------------------------
    set +e; run_gvc subject_positive gvc_fail "$TMP/db-does-not-exist"; F_RC=$?; set -e
    if [[ "$F_RC" -ne 0 ]] && [[ ! -s "$TMP/gvc_fail.sarif" ]]; then
        pass "GVC-F FAILURE: DB unavailable -> rc=$F_RC + zero-byte SARIF (no observation exists)"
        info "PR-B's shipped guard [[ ! -s govulncheck.sarif ]] classifies this OBSERVATION_FAILURE."
    else
        fail "GVC-F FAILURE: DB-unavailable did not fail closed (rc=$F_RC, sarif bytes=$(wc -c <"$TMP/gvc_fail.sarif"))"
    fi
    GVC_STATE=EXERCISED
fi

# =============================================================================
# VAF-C1a REGRESSION WITNESS — the PRODUCTION classifier, not the scanner
# =============================================================================
#
# The arms above prove the INSTRUMENTS behave correctly. They do not touch the
# production verdict logic that turns an observation into a CLASSIFICATION.
#
# F1 measured the gap: DB unavailable yields rc=127 plus a VALID, PARSEABLE, ZERO-finding
# artifact. The shipped OSV verdict fails CLOSED (correct) but labels it
# "OSV suppression drift ... osv-scanner.toml lists ignores that match nothing" — routing an
# operator to a file that has no fault, and collapsing FAILED into DRIFT. VAF requires those
# to stay distinct (STALE != UNKNOWN).
#
# ⛔ F2 MUST NOT LOWER ITS EXPECTATION TO ACCOMMODATE A PROVEN DEFECT.
#   So this arm states the CORRECT expectation and reports the deviation. It is non-fatal
#   until VAF-C1a lands; set VAF_REQUIRE_C1A=1 (C1a's PR does this) to make it binding.
#   ⛔ It never asserts the WRONG behaviour — a witness that locks in a bug is worse than none.
echo
echo "--- VAF-C1a witness: production OSV classifier on an observation failure ---"
# ⛔ The workflow is a REPO-RESIDENT subject: it is always present in a correct checkout.
#   Its absence is a FAILURE, never a skip. (An earlier revision of this arm resolved the
#   path one level short, printed SUBJECT_NOT_FOUND, and still reported RESULT: PASS —
#   the very false-green shape this file exists to prevent.)
WF="$(cd "$SCRIPT_DIR/../../../.." 2>/dev/null && pwd)/.github/workflows/osv-scanner.yml"
if [[ ! -f "$WF" ]]; then
    fail "C1a-W SUBJECT_NOT_FOUND: $WF — a repo-resident subject is missing; absence is not a skip"
else
    python3 - "$WF" "$TMP/verdict.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for job in d.get('jobs', {}).values():
    for st in job.get('steps', []):
        if str(st.get('name','')).startswith('OSV verdict'):
            open(sys.argv[2],'w').write(st['run']); sys.exit(0)
sys.exit(3)
PY
    if [[ ! -s "$TMP/verdict.sh" ]]; then
        fail "C1a-W could not extract the production 'OSV verdict' step — the classifier could not be evaluated"
    else
        # Reproduce the measured observation-failure state exactly:
        #   a VALID SARIF carrying ZERO results, with the scanner's DB-unavailable exit status.
        printf '{"version":"2.1.0","runs":[{"results":[]}]}' > "$TMP/osv-results.sarif"
        set +e
        C_OUT="$( cd "$TMP" && SARIF_READY=true OSV_EXIT=127 bash verdict.sh 2>&1 )"
        C_RC=$?
        set -e
        if [[ "$C_RC" -eq 0 ]]; then
            fail "C1a-W the production classifier returned SUCCESS for an observation failure — FAIL-OPEN"
        elif grep -q '::error title=OSV suppression drift::' <<<"$C_OUT"; then
            # ⛔ BINDING SINCE VAF-C1a. Was non-fatal while the defect was open; C1a repaired
            #    the classifier, so a regression back to "drift" is now a hard failure.
            fail "C1a-W REGRESSION: a database-unavailable observation failure is classified as suppression drift"
            info "  ⛔ FAILED != DRIFT. This sends an operator to osv-scanner.toml for a fault that is not there."
            info "  observed: $(grep -o 'title=[^:]*' <<<"$C_OUT" | head -1)"
        elif grep -q '::error title=OSV observation failure::' <<<"$C_OUT"; then
            pass "C1a-W production classifier reports OBSERVATION FAILURE for rc=127 + valid empty artifact"
            info "⛔ VALID EMPTY ARTIFACT != CLEAN. Both states fail closed — but not under the same name."
        else
            fail "C1a-W classifier produced an unrecognised verdict (rc=$C_RC)"
            sed 's/^/          /' <<<"$C_OUT" | head -3
        fi
        # ---- the OTHER side of the discrimination: rc=1 must STILL be drift -------
        # A "fix" that relabels everything as observation failure would destroy the
        # distinction in the opposite direction. Both names must remain reachable.
        set +e
        D_OUT="$( cd "$TMP" && SARIF_READY=true OSV_EXIT=1 bash verdict.sh 2>&1 )"
        D_RC=$?
        set -e
        if [[ "$D_RC" -ne 0 ]] && grep -q '::error title=OSV suppression drift::' <<<"$D_OUT"; then
            pass "C1a-W2 rc=1 + zero findings is STILL classified as suppression drift (discrimination is two-way)"
        else
            fail "C1a-W2 rc=1 no longer classifies as suppression drift — the repair collapsed the distinction the other way"
        fi
    fi
fi

# =============================================================================
echo
echo "INSTRUMENT COVERAGE:  osv-scanner=$OSV_STATE  govulncheck=$GVC_STATE"
if [[ "$OSV_STATE" != EXERCISED || "$GVC_STATE" != EXERCISED ]]; then
    echo "⛔ AN UNAVAILABLE INSTRUMENT IS NOT A PASS — its detection capability is UNKNOWN this run."
    if [[ "${VAF_REQUIRE_INSTRUMENTS:-0}" == "1" ]]; then
        fail "VAF_REQUIRE_INSTRUMENTS=1 and an instrument was unavailable"
    fi
fi
echo
[[ $FAIL -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
