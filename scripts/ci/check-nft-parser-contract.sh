#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-nft-parser-contract.sh — v1.228.8 PR1 nft parser-contract gate.
#
# WHY (measured 2026-08-08, fleet incident lineage):
# nft's output representation is VERSION-DEPENDENT — nft 1.0.2 omits the
# `dynamic` flag from `nft -j list sets` JSON (srv3), `nft -j list ruleset`
# never emits inline meters, and text column layouts drift. A parser written
# against one representation silently mis-measures on another. Worse, most
# historical parse sites collapsed a FAILED observation (command error, empty
# output, unparseable JSON) into 0 / absent / healthy — the v1.228.6 limiter
# check reported a saturated 65535-cap set as HEALTHY on 1.0.2 because every
# limiter was skipped by a `"dynamic" in flags` test.
#
# CONTRACT (owner ruling 2026-08-08, PR1_FIX_SCOPE = GATE_PLUS_VERDICT_CRITICAL):
#   UNKNOWN OBSERVATION MUST NOT BECOME
#   KNOWN SAFE / KNOWN ABSENT / ZERO / DESTRUCTIVE AUTHORIZATION.
#
# Every nft READ site is registered. Three data files:
#   data/nft-parser-sites.tsv             per-file pin of nft read-site counts
#                                         (TOTAL coverage — a new read site
#                                         anywhere fails until classified)
#   data/nft-parser-contract-registry.tsv per-site semantics: severity class +
#                                         failure policy for verdict-bearing
#                                         parsers, plus full waiver records
#   data/nft-parser-critical-baseline.tsv reviewed pin of severity + waiver
#                                         tier (makes downgrade and waiver
#                                         growth detectable)
#
# Rules:
#   R1 COVERAGE_PIN      discovered per-file read-site counts == pinned counts,
#                        both directions. BLOCKING. You cannot add an nft read
#                        without re-pinning, and re-pinning is the reviewed act
#                        of classification. This is what forbids NEW debt.
#   R2 SEMANTIC_ANCHOR   every registry row's anchor (a literal source line)
#                        still exists in its file. BLOCKING — a refactor must
#                        carry its registry row forward.
#   R3 CRITICAL_POLICY   severity in {SECURITY_VERDICT, DESTRUCTIVE_DECISION,
#                        HEALTH_VERDICT, AUTHORITY_VERDICT} REQUIRES
#                        failure_policy=UNKNOWN_REQUIRED. BLOCKING, with ONE
#                        exception: a COMPLETE waiver (below).
#   R4 TAIL_VISIBILITY   waivers are machine-counted per tier and printed on
#                        every run (CRITICAL_WAIVERS_TOTAL / TIER1..3), so the
#                        deferred tail is never silent.
#   R5 VOCABULARY        severity/policy from fixed vocabularies. BLOCKING
#                        (a typo'd class is an unclassified site).
#   R6 SEVERITY_LAUNDERING a baselined site's severity may never be downgraded.
#                        BLOCKING. Relabelling a health verdict "display-only"
#                        to pass R3 is the forbidden move; blast radius is a
#                        property of the consumer, not a gate-passing knob.
#   R7 WAIVER_CONTRACT   a waiver requires tier(TIER-1|2|3) + reviewer +
#                        current_behavior + required_behavior +
#                        WAIVED_TO=OPEN_NFT_PARSER_FAILURE_TRUTH_TAIL, and the
#                        site MUST be pre-existing in the baseline. A parser
#                        added after PR1 can never be born waived. BLOCKING.
#   R8 WAIVER_GROWTH     the critical-waiver count may only DECREASE. Growth
#                        requires an explicit reviewed baseline update.
#                        BLOCKING — the waiver set is a bounded debt register,
#                        not a growing exception list.
#
# WAIVED_TO is NOT an allowlist. A waiver means STILL WRONG, deliberately
# deferred, with a named owner and a defined correct behavior. Sites whose
# zero-on-failure semantics are genuinely intentional use
# DISPLAY_ONLY_ZERO_ACCEPTED / METRIC_BEST_EFFORT instead — a different
# mechanism, because it makes a different claim.
#
# Modes:
#   (default)        run the gate against the working tree
#   --emit-pins      regenerate the coverage pin (after a DELIBERATE change)
#   --emit-baseline  regenerate the severity/waiver baseline (reviewed act)
#   --selftest       falsifiability: prove each rule can fail, both directions
#
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DATA_DIR="$REPO_ROOT/scripts/ci/data"
PIN_FILE="$DATA_DIR/nft-parser-sites.tsv"
REG_FILE="$DATA_DIR/nft-parser-contract-registry.tsv"
BASE_FILE="$DATA_DIR/nft-parser-critical-baseline.tsv"

SEVERITY_VOCAB="SECURITY_VERDICT DESTRUCTIVE_DECISION HEALTH_VERDICT AUTHORITY_VERDICT OPERATOR_STATUS METRIC_ONLY DISPLAY_ONLY"
POLICY_VOCAB="UNKNOWN_REQUIRED KNOWN_GAP_FAILS_ZERO DISPLAY_ONLY_ZERO_ACCEPTED METRIC_BEST_EFFORT"
CRITICAL_SEVERITIES="SECURITY_VERDICT DESTRUCTIVE_DECISION HEALTH_VERDICT AUTHORITY_VERDICT"

fail=0
warn=0
viol() { printf 'FAIL [%s] %s\n' "$1" "$2"; fail=$((fail + 1)); }
note() { printf 'WARN [%s] %s\n' "$1" "$2"; warn=$((warn + 1)); }

# ---------------------------------------------------------------------------
# DISCOVERY — the single authority. The pin generator and the checker use
# THIS function, so the guard's subject is exactly the guard's input.
#
# A "read site" is a non-comment source line that invokes nft with a read
# verb (list / get element). Mutations (add/delete/flush/insert/-f) are not
# read sites unless the same line also reads.
#   Shell: cli/lib/nftban/**/*.sh (tests excluded) + cli/sbin executables.
#   Go:    internal/**/*.go (tests excluded), the repo's single-line
#          `"nft", ["-j",] "list"|"get"` invocation style.
# Output: "<repo-relative-file>\t<count>" sorted, one row per file with >0.
# ---------------------------------------------------------------------------
discover_sites() {
    local root="$1"
    {
        # Shell layer — strip comment-only lines, then match read verbs.
        find "$root/cli/lib/nftban" -name '*.sh' -not -path '*/tests/*' -print0 2>/dev/null
        find "$root/cli/sbin" -maxdepth 1 -type f -print0 2>/dev/null
    } | while IFS= read -r -d '' f; do
        local c
        c=$(grep -cE '^[[:space:]]*[^#[:space:]].*\bnft\b[^#]*\b(list|get element)\b' "$f" 2>/dev/null || true)
        if [[ "${c:-0}" -gt 0 ]]; then printf "%s\t%s\n" "${f#"$root"/}" "$c"; fi
    done
    find "$root/internal" -name '*.go' -not -name '*_test.go' -print0 2>/dev/null |
        while IFS= read -r -d '' f; do
            local c
            c=$(grep -cE '"nft"[[:space:]]*,[[:space:]]*("(-j|-a|-t)"[[:space:]]*,[[:space:]]*)*"(list|get)"' "$f" 2>/dev/null || true)
            if [[ "${c:-0}" -gt 0 ]]; then printf "%s\t%s\n" "${f#"$root"/}" "$c"; fi
        done
}

emit_pins() {
    discover_sites "$1" | sort
}

# ---------------------------------------------------------------------------
run_gate() {
    local root="$1" pin_file="$2" reg_file="$3"

    [[ -f "$pin_file" ]] || { viol "COVERAGE_PIN" "pin file missing: $pin_file"; return; }
    [[ -f "$reg_file" ]] || { viol "SEMANTIC_ANCHOR" "registry missing: $reg_file"; return; }

    # R1 — coverage pin, both directions.
    local discovered pinned
    discovered="$(emit_pins "$root")"
    pinned="$(grep -vE '^[[:space:]]*(#|$)' "$pin_file" | sort)"
    if [[ "$discovered" != "$pinned" ]]; then
        while IFS= read -r line; do
            if [[ -z "$line" ]]; then continue; fi
            case "${line:0:1}" in
                '<') viol "COVERAGE_PIN" "UNPINNED nft read site (new/changed): ${line:2} — an nft read requires a registry decision; classify it in $REG_FILE (severity + failure_policy) then regenerate pins with --emit-pins" ;;
                '>') viol "COVERAGE_PIN" "STALE pin (site removed/renamed): ${line:2} — regenerate pins with --emit-pins and retire its registry rows" ;;
            esac
        done < <(diff <(printf '%s\n' "$discovered") <(printf '%s\n' "$pinned") | grep -E '^[<>]' || true)
    fi

    # Baseline (anti-laundering + waiver monotonicity). Absent baseline is a
    # hard failure: without it, severity could be silently downgraded and the
    # waiver set could grow unobserved.
    local base_file="${4:-$BASE_FILE}"
    declare -A BASE_SEV=() BASE_WAIVED=()
    local base_waiver_total=0
    if [[ -f "$base_file" ]]; then
        while IFS=$'\t' read -r bfile banchor bsev btier; do
            if [[ -z "$bfile" || "${bfile:0:1}" == "#" ]]; then continue; fi
            BASE_SEV["$bfile|$banchor"]="$bsev"
            BASE_WAIVED["$bfile|$banchor"]="$btier"
            # Only CRITICAL-severity waivers are counted/bounded: an
            # OPERATOR_STATUS tail row is registered debt but not a gate waiver.
            if [[ "$btier" != "-" ]] && grep -qw "$bsev" <<<"$CRITICAL_SEVERITIES"; then
                base_waiver_total=$((base_waiver_total + 1))
            fi
        done < "$base_file"
    else
        viol "BASELINE" "severity/waiver baseline missing: $base_file (required — it is what makes severity-downgrade and waiver-growth detectable)"
    fi

    # R2/R3/R5/R6/R7 — semantic registry rows.
    local n_known_gap=0 n_unknown_req=0
    local w_t1=0 w_t2=0 w_t3=0 w_total=0
    while IFS=$'\t' read -r rfile anchor severity policy tier reviewer cur req rnote; do
        if [[ -z "$rfile" || "${rfile:0:1}" == "#" ]]; then continue; fi
        if [[ -z "$anchor" || -z "$severity" || -z "$policy" ]]; then
            viol "VOCABULARY" "registry row for '$rfile' is missing anchor/severity/policy fields"
            continue
        fi
        local key="$rfile|$anchor"
        # R5 vocabulary
        grep -qw "$severity" <<<"$SEVERITY_VOCAB" ||
            viol "VOCABULARY" "'$rfile' anchor '$anchor': unknown severity_class '$severity'"
        grep -qw "$policy" <<<"$POLICY_VOCAB" ||
            viol "VOCABULARY" "'$rfile' anchor '$anchor': unknown failure_policy '$policy'"
        # R2 anchor liveness (fixed-string: an anchor is a source line, not a pattern)
        if [[ ! -f "$root/$rfile" ]]; then
            viol "SEMANTIC_ANCHOR" "registry names missing file '$rfile'"
        elif ! grep -qF -- "$anchor" "$root/$rfile"; then
            viol "SEMANTIC_ANCHOR" "'$rfile': anchor not found: '$anchor' (a refactor must carry its registry row forward)"
        fi
        # R6 SEVERITY_LAUNDERING — a baselined site may never be re-labelled
        # to a weaker class. Downgrading severity is the forbidden way to
        # satisfy R3 without fixing (or honestly waiving) the defect.
        if [[ -n "${BASE_SEV[$key]:-}" && "${BASE_SEV[$key]}" != "$severity" ]]; then
            viol "SEVERITY_LAUNDERING" "'$rfile' anchor '$anchor': severity changed ${BASE_SEV[$key]} -> $severity; a site's blast radius is a property of the consumer, not a gate-passing knob. Fix it, waive it honestly, or update the reviewed baseline."
        fi
        # R3 critical policy + waiver contract.
        if grep -qw "$severity" <<<"$CRITICAL_SEVERITIES" && [[ "$policy" != "UNKNOWN_REQUIRED" ]]; then
            local waived=0
            if [[ "$rnote" == *"WAIVED_TO=OPEN_NFT_PARSER_FAILURE_TRUTH_TAIL"* ]]; then
                waived=1
                # Full waiver record required — a bare marker is not a waiver.
                [[ "$tier" =~ ^TIER-[123]$ ]] ||
                    { viol "WAIVER_INCOMPLETE" "'$rfile' anchor '$anchor': waiver needs a finite tier (TIER-1|TIER-2|TIER-3), got '$tier'"; waived=0; }
                [[ -n "$reviewer" && "$reviewer" != "-" ]] ||
                    { viol "WAIVER_INCOMPLETE" "'$rfile' anchor '$anchor': waiver needs a reviewer"; waived=0; }
                [[ -n "$cur" && "$cur" != "-" ]] ||
                    { viol "WAIVER_INCOMPLETE" "'$rfile' anchor '$anchor': waiver needs current_behavior (what is wrong today)"; waived=0; }
                [[ -n "$req" && "$req" != "-" ]] ||
                    { viol "WAIVER_INCOMPLETE" "'$rfile' anchor '$anchor': waiver needs required_behavior (what correct looks like)"; waived=0; }
                # R7 — waivers are for PRE-EXISTING sites only. A parser added
                # after the PR1 baseline may not be born waived.
                if [[ -z "${BASE_WAIVED[$key]:-}" || "${BASE_WAIVED[$key]}" == "-" ]]; then
                    viol "WAIVER_NOT_PREEXISTING" "'$rfile' anchor '$anchor': waiver claimed for a site not in the PR1 waiver baseline — new critical parsers must handle UNKNOWN, they cannot be born waived"
                    waived=0
                fi
            fi
            if [[ $waived -eq 1 ]]; then
                note "WAIVED_CRITICAL" "[$tier] $rfile :: $severity still collapses failure to zero — deferred to OPEN_NFT_PARSER_FAILURE_TRUTH_TAIL. now: $cur | required: $req"
                w_total=$((w_total + 1))
                case "$tier" in
                    TIER-1) w_t1=$((w_t1 + 1)) ;;
                    TIER-2) w_t2=$((w_t2 + 1)) ;;
                    TIER-3) w_t3=$((w_t3 + 1)) ;;
                esac
            else
                viol "CRITICAL_POLICY" "'$rfile' anchor '$anchor': severity $severity requires failure_policy=UNKNOWN_REQUIRED, has '$policy' — a $severity may never be derived from a failure-collapsed zero. Fix it, or record a COMPLETE waiver (tier+reviewer+current+required+WAIVED_TO=OPEN_NFT_PARSER_FAILURE_TRUTH_TAIL)."
            fi
        fi
        if [[ "$policy" == "KNOWN_GAP_FAILS_ZERO" ]]; then n_known_gap=$((n_known_gap + 1)); fi
        if [[ "$policy" == "UNKNOWN_REQUIRED" ]]; then n_unknown_req=$((n_unknown_req + 1)); fi
    done < "$reg_file"

    # R4 — the deferred tail is machine-counted and loud on every run.
    printf 'CRITICAL_WAIVERS_TOTAL=%d\n  TIER1=%d\n  TIER2=%d\n  TIER3=%d\n' "$w_total" "$w_t1" "$w_t2" "$w_t3"
    printf 'INFO registry: %d UNKNOWN_REQUIRED, %d KNOWN_GAP_FAILS_ZERO rows\n' "$n_unknown_req" "$n_known_gap"

    # R8 WAIVER_GROWTH — the waiver set is a bounded debt register, not a
    # growing exception list. It may shrink freely; growth requires an
    # explicit reviewed baseline update.
    if [[ $w_total -gt $base_waiver_total ]]; then
        viol "WAIVER_GROWTH" "critical waivers increased ${base_waiver_total} -> ${w_total}. Waivers may only DECREASE. To add one deliberately, update $base_file in the same reviewed change."
    elif [[ $w_total -lt $base_waiver_total ]]; then
        note "WAIVER_BURNDOWN" "critical waivers decreased ${base_waiver_total} -> ${w_total} — regenerate the baseline to lock the gain in (--emit-baseline)"
    fi
}

# Baseline generator: pins each registered site's severity + waiver tier so a
# later downgrade or a new waiver is detectable. Regenerate ONLY as a reviewed act.
emit_baseline() {
    local reg="${1:-$REG_FILE}"
    printf '# NFTBan nft parser critical/severity baseline (v1.228.8 PR1)\n'
    printf '# file<TAB>anchor<TAB>severity_class<TAB>waiver_tier   (regenerate: --emit-baseline)\n'
    printf '# Guards: severity may not be downgraded (anti-laundering); critical waivers\n'
    printf '# may not increase; a site absent here may never be born waived.\n'
    grep -vE '^[[:space:]]*(#|$)' "$reg" | awk -F'\t' '{print $1"\t"$2"\t"$3"\t"$5}'
}

# ---------------------------------------------------------------------------
selftest() {
    local T
    T="$(mktemp -d)"
    trap 'rm -rf "$T"' RETURN
    mkdir -p "$T/cli/lib/nftban/core" "$T/cli/sbin" "$T/internal/pkg" "$T/scripts/ci/data"

    cat > "$T/cli/lib/nftban/core/mod.sh" <<'EOF'
#!/usr/bin/env bash
# comment mentioning nft list sets must NOT count
count=$(nft -j list sets ip | parse)
legacy=$(nft list set ip nftban s | grep -c elements)
nft add element ip nftban s '{ 1.2.3.4 }'
EOF
    cat > "$T/internal/pkg/p.go" <<'EOF'
package pkg
func f() { exec.Run("nft", "list", "table", "inet", "filter") }
EOF
    local pin="$T/scripts/ci/data/nft-parser-sites.tsv"
    local reg="$T/scripts/ci/data/nft-parser-contract-registry.tsv"
    local base="$T/scripts/ci/data/nft-parser-critical-baseline.tsv"
    emit_pins "$T" > "$pin"
    W='WAIVED_TO=OPEN_NFT_PARSER_FAILURE_TRUTH_TAIL(TIER-1)'
    {
      printf 'cli/lib/nftban/core/mod.sh\tcount=$(nft -j list sets ip | parse)\tHEALTH_VERDICT\tUNKNOWN_REQUIRED\t-\t-\t-\t-\tfixed\n'
      printf 'cli/lib/nftban/core/mod.sh\tlegacy=$(nft list set ip nftban s | grep -c elements)\tHEALTH_VERDICT\tKNOWN_GAP_FAILS_ZERO\tTIER-1\towner\tfail->0\tfail->UNKNOWN\t%s\n' "$W"
      printf 'internal/pkg/p.go\texec.Run("nft", "list", "table", "inet", "filter")\tDESTRUCTIVE_DECISION\tUNKNOWN_REQUIRED\t-\t-\t-\t-\tfixed\n'
    } > "$reg"
    emit_baseline "$reg" > "$base"

    local ok=0 bad=0 saved_reg saved_pin
    saved_reg="$(cat "$reg")"; saved_pin="$(cat "$pin")"
    check() { # label expect_fail(0/1)
        local label="$1" expect="$2" rc=0
        ( fail=0; warn=0; run_gate "$T" "$pin" "$reg" "$base" >/dev/null 2>&1; exit "$fail" ) || rc=$?
        local failed=$(( rc > 0 ? 1 : 0 ))
        if [[ "$failed" -eq "$expect" ]]; then
            printf '  [PASS] %s\n' "$label"; ok=$((ok + 1))
        else
            printf '  [FAIL] %s (expected fail=%s, got fail=%s)\n' "$label" "$expect" "$failed"; bad=$((bad + 1))
        fi
    }
    restore() { printf '%s\n' "$saved_reg" > "$reg"; printf '%s\n' "$saved_pin" > "$pin"; }

    check "clean fixture passes (waiver present, complete)" 0

    # R1 — new debt forbidden
    echo 'x=$(nft list meters ip)' >> "$T/cli/lib/nftban/core/mod.sh"
    check "NEW unpinned read site -> BLOCKING (R1, forbids new debt)" 1
    emit_pins "$T" > "$pin"
    check "re-pinned after classification -> passes" 0
    sed -i '/nft list meters ip/d' "$T/cli/lib/nftban/core/mod.sh"; emit_pins "$T" > "$pin"

    # R2 — phantom anchor
    sed -i 's|count=$(nft -j list sets ip | parse)|count=$(nft -j list sets GONE)|' "$reg" 2>/dev/null || true
    python3 - "$reg" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read()
open(p,'w').write(s.replace('nft -j list sets ip | parse','nft -j list sets GONE_ANCHOR'))
PYEOF
    check "phantom registry anchor -> BLOCKING (R2)" 1
    restore

    # R3/waiver contract — the owner-specified tests
    python3 - "$reg" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read()
open(p,'w').write(s.replace('WAIVED_TO=OPEN_NFT_PARSER_FAILURE_TRUTH_TAIL(TIER-1)','no waiver here'))
PYEOF
    check "waived critical loses WAIVED_TO -> BLOCKING (waiver is load-bearing)" 1
    restore

    python3 - "$reg" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read().split('\n')
out=[]
for l in s:
    f=l.split('\t')
    if len(f)>3 and f[3]=='KNOWN_GAP_FAILS_ZERO':
        f[2]='DISPLAY_ONLY'   # severity laundering: relabel to dodge R3
    out.append('\t'.join(f))
open(p,'w').write('\n'.join(out))
PYEOF
    check "SEVERITY LAUNDERING (critical -> DISPLAY_ONLY) -> BLOCKING (R6)" 1
    restore

    python3 - "$reg" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read().split('\n')
out=[]
for l in s:
    f=l.split('\t')
    if len(f)>4 and f[4]=='TIER-1':
        f[5]='-'; f[6]='-'   # strip reviewer + current_behavior
    out.append('\t'.join(f))
open(p,'w').write('\n'.join(out))
PYEOF
    check "INCOMPLETE waiver (no reviewer/current) -> BLOCKING" 1
    restore

    # R7 — a NEW critical site may not be born waived
    echo 'newcrit=$(nft -j list meters ip | jq .x)' >> "$T/cli/lib/nftban/core/mod.sh"
    emit_pins "$T" > "$pin"
    printf 'cli/lib/nftban/core/mod.sh\tnewcrit=$(nft -j list meters ip | jq .x)\tSECURITY_VERDICT\tKNOWN_GAP_FAILS_ZERO\tTIER-1\towner\tfail->0\tfail->UNKNOWN\t%s\n' "$W" >> "$reg"
    check "NEW critical site born WAIVED -> BLOCKING (R7 pre-existing only)" 1
    sed -i '/nft -j list meters ip/d' "$T/cli/lib/nftban/core/mod.sh"; restore; emit_pins "$T" > "$pin"

    # R8 — waiver growth blocked (add a 2nd waiver to a baselined-unwaived site)
    python3 - "$reg" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read().split('\n')
out=[]
for l in s:
    f=l.split('\t')
    if len(f)>8 and f[3]=='UNKNOWN_REQUIRED' and f[0].endswith('p.go'):
        f[3]='KNOWN_GAP_FAILS_ZERO'; f[4]='TIER-1'; f[5]='owner'; f[6]='fail->delete'; f[7]='fail->no-delete'
        f[8]='WAIVED_TO=OPEN_NFT_PARSER_FAILURE_TRUTH_TAIL(TIER-1)'
    out.append('\t'.join(f))
open(p,'w').write('\n'.join(out))
PYEOF
    check "WAIVER GROWTH (new waiver on baselined-unwaived site) -> BLOCKING (R7/R8)" 1
    restore

    check "comment-only nft mention does NOT drift the pin" 0

    printf '=== selftest: PASS=%d FAIL=%d ===\n' "$ok" "$bad"
    [[ $bad -eq 0 ]]
}

# ---------------------------------------------------------------------------
case "${1:-}" in
    --emit-pins)     emit_pins "$REPO_ROOT" ;;
    --emit-baseline) emit_baseline "$REG_FILE" ;;
    --selftest)  selftest ;;
    *)
        run_gate "$REPO_ROOT" "$PIN_FILE" "$REG_FILE"
        printf 'nft-parser-contract: %d hard violations, %d warnings\n' "$fail" "$warn"
        exit $(( fail > 0 ? 1 : 0 ))
        ;;
esac
