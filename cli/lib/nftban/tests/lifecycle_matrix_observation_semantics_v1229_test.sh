#!/usr/bin/env bash
# =============================================================================
# NFTBan — UNINSTALL-PR3: lifecycle-matrix observation semantics
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="lifecycle-matrix-observation-semantics-v1229-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-12"
# meta:description="Locks UNINSTALL-PR3 amendments A1-A6 on both lifecycle matrices: missing systemd/nft observation authority yields BLOCKED_ENVIRONMENT instead of a vacuous inactive/absent PASS; aggregation is a closed set where an unknown verdict becomes HARNESS_FAILURE; a mid-run abort before the SUMMARY emits HARNESS_FAILURE (exit 3) rather than masquerading as FAIL/INCOMPLETE; and NOT_IN_SCOPE stays distinct from BLOCKED_ENVIRONMENT. Every negative control is paired with a positive twin."
# meta:inventory.files="scripts/ci/tests/lifecycle_rpm_matrix.sh,scripts/ci/tests/lifecycle_deb_matrix.sh"
# meta:inventory.privileges="none"
# meta:ta.id="lifecycle_matrix_observation_semantics_v1229_test"
# meta:ta.owner="packaging"
# meta:ta.module="uninstall-lifecycle"
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
#   OBSERVATION_FAILURE MUST NEVER BECOME SECURITY_STATE_EMPTY
#
# Removal cases assert NEGATIVE states (`inactive`, `absent`). A probe that
# collapses "the tool is missing" into those values makes the assertion PASS
# having observed nothing — and removal is exactly what this lane must prove.
#
# TAXONOMY (frozen):
#   PASS 0 · TEST_FAILURE 1 · INCOMPLETE 2 · HARNESS_FAILURE 3
#   PASS · FAIL · SKIP · BLOCKED_ENVIRONMENT · NOT_IN_SCOPE
#
# EVERY negative control below has a POSITIVE TWIN. Without the twin, a control
# can "pass" because the assertion never executed at all — the same ASSERT(X==X)
# vacuity this lane keeps re-learning.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
RPM_M="$REPO_ROOT/scripts/ci/tests/lifecycle_rpm_matrix.sh"
DEB_M="$REPO_ROOT/scripts/ci/tests/lifecycle_deb_matrix.sh"

PASS=0; FAIL=0
ok(){ echo "  ✅ $1"; PASS=$((PASS+1)); }
no(){ echo "  ❌ $1"; [ -n "${2:-}" ] && echo "       $2"; FAIL=$((FAIL+1)); }

for f in "$RPM_M" "$DEB_M"; do
    [ -r "$f" ] || { echo "missing matrix: $f"; exit 1; }
done

BASH_ABS="$(command -v bash)"
W=$(mktemp -d); _owner=$$
trap '[ "$$" = "$_owner" ] && rm -rf "$W"' EXIT

# Comments stripped: prose describing a defect must not satisfy an arm.
RPM_CODE=$(sed 's|#.*||' "$RPM_M")
DEB_CODE=$(sed 's|#.*||' "$DEB_M")

# Extract a function body from a matrix, comments stripped.
fn() { printf '%s\n' "$2" | awk -v f="$1" '$0 ~ "^"f"\\(\\) *\\{" {n=1} n{print} n && /^\}$/{exit}'; }

# ---------------------------------------------------------------------------
# NC1/PC1 — missing systemctl must NOT read as "inactive"
# ---------------------------------------------------------------------------
echo "── NC1/PC1  systemctl absent => BLOCKED_ENVIRONMENT, present => real value ─"
probe_harness() { # $1=matrix-code $2=probe-fn  $3=PATH-mode(strip|keep)
    local body; body=$(fn "$2" "$1")
    { echo 'BLOCKED_TOKEN="BLOCKED_ENVIRONMENT"'
      echo "$body"
      echo "$2 nftband.service" ; } > "$W/probe.sh"
    if [ "$3" = strip ]; then
        # A directory with NO systemctl and NO nft, but with coreutils present:
        # the probe must detect absence, not crash on missing helpers.
        mkdir -p "$W/emptybin"
        for t in head printf grep cut sed awk; do
            src=$(command -v "$t" 2>/dev/null) && ln -sf "$src" "$W/emptybin/$t" 2>/dev/null
        done
        PATH="$W/emptybin" "$BASH_ABS" "$W/probe.sh" 2>/dev/null
    else
        "$BASH_ABS" "$W/probe.sh" 2>/dev/null
    fi
}

for pair in "RPM:unit_state" "DEB:unit_active_state"; do
    fam="${pair%%:*}"; pfn="${pair##*:}"
    code=$RPM_CODE; [ "$fam" = DEB ] && code=$DEB_CODE
    got=$(probe_harness "$code" "$pfn" strip)
    [ "$got" = "BLOCKED_ENVIRONMENT" ] \
        && ok "NC1 $fam $pfn: no systemctl => BLOCKED_ENVIRONMENT" \
        || no "NC1 $fam $pfn: no systemctl => '$got' (vacuous if 'inactive')" ""
    # POSITIVE TWIN: with a real PATH the probe must return a genuine state
    # (never the sentinel), proving it is not hard-wired to report BLOCKED.
    got2=$(probe_harness "$code" "$pfn" keep)
    if [ "$got2" = "BLOCKED_ENVIRONMENT" ] && command -v systemctl >/dev/null 2>&1; then
        no "PC1 $fam $pfn: systemctl PRESENT but probe still says BLOCKED" "hard-wired sentinel"
    else
        ok "PC1 $fam $pfn: with a normal PATH returns a real observation ('${got2}')"
    fi
done

# ---------------------------------------------------------------------------
# NC2/PC2 — missing nft must NOT read as "absent"
# ---------------------------------------------------------------------------
echo "── NC2/PC2  nft absent => BLOCKED_ENVIRONMENT ─────────────────────────────"
mkdir -p "$W/emptybin"
RPM_FW=$(fn fw "$RPM_CODE")
{ echo 'BLOCKED_TOKEN="BLOCKED_ENVIRONMENT"'; echo "$RPM_FW"; echo 'fw'; } > "$W/fw.sh"
got=$(PATH="$W/emptybin" "$BASH_ABS" "$W/fw.sh" 2>/dev/null)
[ "$got" = "BLOCKED_ENVIRONMENT" ] \
    && ok "NC2 RPM fw(): no nft => BLOCKED_ENVIRONMENT (not 'absent')" \
    || no "NC2 RPM fw(): no nft => '$got'" "'absent' here is a vacuous pass"
# DEB twin (A6): nft_table_state must use the shared sentinel, not 'nft-absent'.
DEB_NFT=$(fn nft_table_state "$DEB_CODE")
{ echo 'BLOCKED_TOKEN="BLOCKED_ENVIRONMENT"'; echo "$DEB_NFT"; echo 'nft_table_state ip nftban'; } > "$W/nft.sh"
got=$(PATH="$W/emptybin" "$BASH_ABS" "$W/nft.sh" 2>/dev/null)
[ "$got" = "BLOCKED_ENVIRONMENT" ] \
    && ok "NC2 DEB nft_table_state(): no nft => BLOCKED_ENVIRONMENT (A6 normalised)" \
    || no "NC2 DEB nft_table_state(): => '$got'" "A6 wants the shared sentinel"
# POSITIVE TWIN: the probes must still be able to say present/absent.
{ echo 'BLOCKED_TOKEN="BLOCKED_ENVIRONMENT"'
  echo 'nft(){ return 1; }'
  echo 'command(){ [ "$2" = nft ] && return 0; builtin command "$@"; }'
  echo "$RPM_FW"; echo 'fw'; } > "$W/fw_present.sh"
got=$("$BASH_ABS" "$W/fw_present.sh" 2>/dev/null)
[ "$got" = "absent" ] \
    && ok "PC2 fw(): nft PRESENT and table missing => 'absent' (real observation)" \
    || no "PC2 fw(): expected 'absent' with nft present, got '$got'" "probe may be hard-wired"

# ---------------------------------------------------------------------------
# NC3 — harness crash before SUMMARY must be HARNESS_FAILURE (exit 3)
# ---------------------------------------------------------------------------
echo "── NC3  abort before verdict => HARNESS_FAILURE, exit 3 ───────────────────"
# Driven against the REAL matrix: an unreadable candidate aborts it under set -e
# before any SUMMARY. Previously that surfaced as a bare rc=1 with no output.
out=$(NFTBAN_RPM_CASES="R7" bash "$RPM_M" /nonexistent-candidate.rpm 2>&1); rc=$?
[ "$rc" -eq 3 ] && ok "NC3 aborted run exits 3 (HARNESS_FAILURE), not 1/2" \
                || no "NC3 aborted run exited $rc" "1 or 2 masquerades as a real verdict"
case "$out" in
    *'VERDICT=HARNESS_FAILURE'*) ok "NC3 emits an explicit HARNESS_FAILURE verdict line";;
    *) no "NC3 emitted no HARNESS_FAILURE line" "$(printf '%s' "$out" | head -2)";;
esac
case "$out" in
    *'VERDICT=PASS'*) no "NC3 aborted run still claimed PASS" "";;
    *) ok "NC3 aborted run makes no PASS claim";;
esac
# POSITIVE TWIN: the sentinel must be set on the real verdict path, or every run
# would report HARNESS_FAILURE and NC3 would prove nothing.
for pair in "RPM:$RPM_CODE" "DEB:$DEB_CODE"; do
    fam="${pair%%:*}"; c="${pair#*:}"
    n=$(printf '%s\n' "$c" | grep -c 'VERDICT_EMITTED=1')
    [ "${n:-0}" -ge 1 ] && ok "PC3 $fam sets VERDICT_EMITTED=1 on the verdict path ($n site(s))" \
                        || no "PC3 $fam never sets VERDICT_EMITTED=1" "every run would be HARNESS_FAILURE"
done

# ---------------------------------------------------------------------------
# NC4 — one BLOCKED among passes must block closure
# ---------------------------------------------------------------------------
echo "── NC4  a single BLOCKED case forces INCOMPLETE ───────────────────────────"
# The classifier under test must be the MATRIX'S OWN TEXT. An earlier version of
# this arm re-implemented the case statement here; mutating the real matrix then
# changed nothing and the control reported a false pass. Extract and execute the
# shipped `case` block instead.
#   TESTING A REPLICA != TESTING THE CODE
extract_classifier() { # $1=matrix-code  -> a function body operating on $v
    printf '%s\n' "$1" | awk '
        /case "\$v" in|case "\$r" in/ {n=1}
        n{print}
        n && /esac/{exit}'
}
run_classifier() { # $1=matrix-code  $2=verdict-value -> counters
    local blk; blk=$(extract_classifier "$1")
    [ -n "$blk" ] || { echo "NO_CLASSIFIER"; return 0; }
    {   echo 'skipped=0; failed=0; blocked=0; unknown=0; c=X'
        echo "v='$2'; r='$2'"
        printf '%s\n' "$blk"
        echo 'echo "failed=$failed blocked=$blocked skipped=$skipped unknown=$unknown"'
    } > "$W/cls.sh"
    "$BASH_ABS" "$W/cls.sh" 2>/dev/null
}
for pair in "RPM:$RPM_CODE" "DEB:$DEB_CODE"; do
    fam="${pair%%:*}"; c="${pair#*:}"
    r=$(run_classifier "$c" "WEIRD_STATE")
    case "$r" in
        *'unknown=1'*) ok "NC4 $fam SHIPPED classifier routes an unknown verdict to unknown=1";;
        NO_CLASSIFIER) no "NC4 $fam has no case-based classifier" "aggregation is not closed-set";;
        *) no "NC4 $fam shipped classifier SWALLOWED an unknown verdict" "got: $r";;
    esac
    r=$(run_classifier "$c" "BLOCKED_ENVIRONMENT")
    case "$r" in
        *'blocked=1'*) ok "NC4 $fam SHIPPED classifier counts BLOCKED_ENVIRONMENT";;
        *) no "NC4 $fam shipped classifier does not count BLOCKED" "got: $r";;
    esac
    r=$(run_classifier "$c" "NOT_IN_SCOPE")
    case "$r" in
        *'failed=0 blocked=0 skipped=0 unknown=0'*) ok "NC4 $fam NOT_IN_SCOPE increments nothing (non-blocking)";;
        *) no "NC4 $fam NOT_IN_SCOPE was counted as a gap" "got: $r";;
    esac
done

# Local model used only to express the VERDICT precedence (documented, and
# cross-checked against the shipped classifier above).
agg_rpm() { # $1..: verdicts for R1 R2 R3 R4 R7 R8 R11
    local -A R; local i=0 c
    for c in R1 R2 R3 R4 R7 R8 R11; do i=$((i+1)); R[$c]="${!i}"; done
    local skipped=0 failed=0 blocked=0 unknown=0 v
    for c in R1 R2 R3 R4 R7 R8 R11; do
        v="${R[$c]}"
        case "$v" in
            PASS) ;; FAIL) failed=$((failed+1));; SKIP) skipped=$((skipped+1));;
            BLOCKED_ENVIRONMENT) blocked=$((blocked+1));; NOT_IN_SCOPE) ;;
            *) unknown=$((unknown+1));;
        esac
    done
    if [ "$unknown" -gt 0 ]; then echo HARNESS_FAILURE; return; fi
    if [ "$failed"  -gt 0 ]; then echo FAIL;            return; fi
    if [ "$blocked" -gt 0 ]; then echo INCOMPLETE;      return; fi
    if [ "$skipped" -gt 0 ]; then echo INCOMPLETE;      return; fi
    echo PASS
}
v=$(agg_rpm PASS PASS PASS PASS BLOCKED_ENVIRONMENT PASS PASS)
[ "$v" = INCOMPLETE ] && ok "NC4 one BLOCKED among all-PASS => INCOMPLETE" \
                      || no "NC4 got '$v'" "a BLOCKED case must block closure"
# POSITIVE TWIN: without the BLOCKED, the same set must reach PASS — otherwise
# NC4 could pass because the aggregator can never say PASS at all.
v=$(agg_rpm PASS PASS PASS PASS PASS PASS PASS)
[ "$v" = PASS ] && ok "PC4 all-PASS still reaches PASS (aggregator not stuck)" \
                || no "PC4 all-PASS returned '$v'" "aggregator cannot report success"
# NOT_IN_SCOPE must NOT block closure (that is the Layer-A requirement).
v=$(agg_rpm PASS NOT_IN_SCOPE NOT_IN_SCOPE NOT_IN_SCOPE PASS PASS NOT_IN_SCOPE)
[ "$v" = PASS ] && ok "PC4 NOT_IN_SCOPE does not block closure (Layer A can pass)" \
                || no "PC4 scoped run returned '$v'" "Layer A would be permanently INCOMPLETE"
# Unknown verdict must become HARNESS_FAILURE, never fall through to PASS.
v=$(agg_rpm PASS PASS PASS PASS WEIRD_STATE PASS PASS)
[ "$v" = HARNESS_FAILURE ] && ok "NC4 unknown verdict => HARNESS_FAILURE (no default-success)" \
                           || no "NC4 unknown verdict => '$v'" "closed set violated"

# ---------------------------------------------------------------------------
# NC5 — Layer A must declare VM-only cases, not silently omit them
# ---------------------------------------------------------------------------
echo "── NC5  scoped run declares exclusions explicitly ─────────────────────────"
# Bind to the SELECTION SITE. A file-wide substring match passes even when the
# selection block still assigns SKIP, because NOT_IN_SCOPE also appears in the
# aggregator — the guard subject must be the line that DECIDES.
sel_rpm=$(printf '%s\n' "$RPM_CODE" | grep -A2 'want() {' | head -3)
case "$RPM_CODE" in
    *'R['*']="NOT_IN_SCOPE"'*) ok "NC5 RPM assigns NOT_IN_SCOPE at the selection site";;
    *) no "NC5 RPM selection site does not assign NOT_IN_SCOPE" "$sel_rpm";;
esac
sel_deb=$(printf '%s\n' "$DEB_CODE" | grep -A1 'NFTBAN_LIFECYCLE_CASES' | grep 'CASE_RESULT' || true)
case "$(printf '%s\n' "$DEB_CODE" | grep 'CASE_RESULT\["\$c"\]=' | head -3)" in
    *'NOT_IN_SCOPE'*) ok "NC5 DEB selection site assigns NOT_IN_SCOPE (A5 parity)";;
    *) no "NC5 DEB selection site still assigns SKIP" "any subset run would be INCOMPLETE${sel_deb:+ | $sel_deb}";;
esac
# Every case must be reported, in scope or not — silent omission hides coverage.
case "$RPM_CODE" in
    *'NFTBAN_RPM_MATRIX_SCOPE='*) ok "NC5 RPM prints a machine-readable SCOPE line";;
    *) no "NC5 RPM prints no SCOPE line" "a subset run could not be distinguished from a full one";;
esac
case "$DEB_CODE" in
    *'NFTBAN_MATRIX_SCOPE='*) ok "NC5 DEB prints a machine-readable SCOPE line";;
    *) no "NC5 DEB prints no SCOPE line" "";;
esac

# NC5b — a Layer A PASS must not carry a systemd/kernel claim.
for pair in "RPM:$RPM_CODE" "DEB:$DEB_CODE"; do
    fam="${pair%%:*}"; c="${pair#*:}"
    case "$c" in
        *'CLAIMS_SYSTEMD_AUTHORITY=NO'*) ok "NC5b $fam Layer A explicitly disclaims systemd authority";;
        *) no "NC5b $fam never emits CLAIMS_SYSTEMD_AUTHORITY=NO" "a container PASS could read as VM proof";;
    esac
    case "$c" in
        *'CLAIMS_KERNEL_FIREWALL_AUTHORITY=NO'*) ok "NC5b $fam Layer A disclaims kernel-firewall authority";;
        *) no "NC5b $fam never disclaims kernel-firewall authority" "";;
    esac
done
# The VM-only helper must exist AND be used, or the split is decorative.
for pair in "RPM:eq_vm:$RPM_CODE" "DEB:assert_eq_vm:$DEB_CODE"; do
    fam="${pair%%:*}"; rest="${pair#*:}"; h="${rest%%:*}"; c="${rest#*:}"
    n=$(printf '%s\n' "$c" | grep -c "^[[:space:]]*${h} ")
    [ "${n:-0}" -ge 3 ] && ok "NC5b $fam routes $n VM-only assertions through ${h}()" \
                        || no "NC5b $fam uses ${h}() at only ${n} site(s)" "VM assertions still unscoped"
done

# ---------------------------------------------------------------------------
# NC6 — BLOCKED_ENVIRONMENT must never be reclassified as NOT_IN_SCOPE
# ---------------------------------------------------------------------------
echo "── NC6  BLOCKED is never rewritten to NOT_IN_SCOPE ────────────────────────"
BAD=0
for c in "$RPM_CODE" "$DEB_CODE"; do
    # A reclassification would look like assigning NOT_IN_SCOPE on a line that
    # also mentions BLOCKED_ENVIRONMENT.
    hit=$(printf '%s\n' "$c" | grep -F 'NOT_IN_SCOPE' | grep -F 'BLOCKED_ENVIRONMENT' || true)
    [ -n "$hit" ] && { BAD=$((BAD+1)); echo "       $hit"; }
done
[ "$BAD" -eq 0 ] && ok "NC6 no code path maps BLOCKED_ENVIRONMENT onto NOT_IN_SCOPE" \
                 || no "NC6 a reclassification path exists" "$BAD site(s)"
# And the two states must be counted differently by the aggregators.
v1=$(agg_rpm PASS PASS PASS PASS BLOCKED_ENVIRONMENT PASS PASS)
v2=$(agg_rpm PASS PASS PASS PASS NOT_IN_SCOPE PASS PASS)
[ "$v1" != "$v2" ] && ok "NC6 BLOCKED ($v1) and NOT_IN_SCOPE ($v2) aggregate DIFFERENTLY" \
                   || no "NC6 both aggregate to '$v1'" "the distinction is cosmetic only"

# ---------------------------------------------------------------------------
# A3 — comparator propagation is wired into the real assertion helpers
# ---------------------------------------------------------------------------
echo "── A3  comparators refuse to compare a BLOCKED observation ────────────────"
for pair in "RPM:eq:$RPM_CODE" "DEB:assert_eq:$DEB_CODE"; do
    fam="${pair%%:*}"; rest="${pair#*:}"; f="${rest%%:*}"; c="${rest#*:}"
    body=$(fn "$f" "$c")
    case "$body" in
        *'BLOCKED_TOKEN'*) ok "A3 $fam $f() short-circuits on the BLOCKED sentinel";;
        *) no "A3 $fam $f() compares a BLOCKED value as an ordinary string" "";;
    esac
done

# ---------------------------------------------------------------------------
# CI WIRING — Layer A must consume artifacts that the build jobs actually publish
# ---------------------------------------------------------------------------
# The first Layer A run requested `rpm-rocky9` while build-rpm publishes
# `rpm-el9` (named for the EL generation, not the image vendor). The job would
# have failed at artifact download; it was SKIPPED that run for an unrelated
# reason, so the mismatch never surfaced.
#     LAYER_A_EXPECTED_ARTIFACT MUST MATCH BUILD_JOB_PUBLISHED_ARTIFACT
echo "── CI  Layer A artifact names must exist as published artifacts ───────────"
WF="$REPO_ROOT/.github/workflows/build-packages.yml"
if [ ! -r "$WF" ]; then
    no "build-packages.yml unreadable — cannot verify artifact wiring" ""
else
    # Published names: build-rpm/build-deb upload rpm-${distro} / deb-${distro},
    # so the publishable set is derived from those matrices, not hand-listed.
    PUB=$(python3 - "$WF" <<'PYEOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
out = []
for job, prefix in (("build-rpm", "rpm-"), ("build-deb", "deb-")):
    j = d["jobs"].get(job, {})
    for m in j.get("strategy", {}).get("matrix", {}).get("include", []):
        if m.get("distro"):
            out.append(prefix + str(m["distro"]))
print("\n".join(out))
PYEOF
)
    WANT=$(python3 - "$WF" <<'PYEOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
j = d["jobs"].get("lifecycle-layer-a", {})
for m in j.get("strategy", {}).get("matrix", {}).get("include", []):
    if m.get("artifact"):
        print(m["artifact"])
PYEOF
)
    if [ -z "$PUB" ] || [ -z "$WANT" ]; then
        no "could not read build/consumer matrices" "PUB='${PUB}' WANT='${WANT}'"
    else
        ok "build jobs publish: $(printf '%s' "$PUB" | tr '\n' ' ')"
        DRIFT=0
        while read -r a; do
            [ -z "$a" ] && continue
            if printf '%s\n' "$PUB" | grep -qx "$a"; then
                ok "Layer A consumes '$a' — published by a build job"
            else
                DRIFT=$((DRIFT+1)); no "Layer A requests '$a' which NO build job publishes" "download would fail"
            fi
        done <<< "$WANT"
        # Positive control: the check must be able to SEE a mismatch, or the
        # arm above passes only because nothing was compared.
        if printf '%s\n' "$PUB" | grep -qx "rpm-rocky9"; then
            no "control: 'rpm-rocky9' unexpectedly published" "detector cannot distinguish"
        else
            ok "control: a bogus name ('rpm-rocky9') is correctly NOT in the published set"
        fi
        [ "$DRIFT" -eq 0 ] && ok "no producer/consumer artifact drift"
    fi
fi

echo
echo "══ RESULT: PASS=$PASS FAIL=$FAIL ══"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
