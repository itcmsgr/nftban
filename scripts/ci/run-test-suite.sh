#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="run-test-suite"
# meta:type="script"
# meta:version="1.226.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Index-driven shell-test runner: the authority index drives selection + isolated execution by gate"
# meta:inventory.files="scripts/ci/test-authority-index.tsv,scripts/ci/test-authority.py"
# meta:inventory.binaries="bash,git,awk,grep,sort,cut,realpath,timeout,printf,sed,python3"
# meta:inventory.env_vars="GITHUB_STEP_SUMMARY,GITHUB_SHA"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# NFTBan index-driven shell-test runner (v1.226.0 PR-C).
#
# The canonical generated authority index (scripts/ci/test-authority-index.tsv)
# DRIVES shell-test execution. This runner NEVER discovers tests by filesystem
# glob, NEVER sources a test, NEVER eval's, and NEVER builds a command from row
# content — every test path is validated and passed as a single quoted argument
# to an isolated `bash` subprocess with a bounded timeout.
#
#   Modes:
#     run    --gate <gate> [--gate <gate>...]   execute the selected gate(s)
#     report --gate <gate> [...]                list selection WITHOUT executing
#     verify                                     validate the index only
#     summary                                    counts by gate
#
#   A test is selected by its `gate` column. Executable gates run; deferred and
#   lab-manual are reported (never executed, never counted PASS); package-build is
#   selectable only under an explicit package authority (never ordinary CI).
#
#   Exit: 0 = ok · 1 = a validation error / an executed test FAILED or TIMED OUT
#         2 = usage / safety-refusal (bad root, malformed index, unsafe path).
#
#   v1.239 §1.0: a test may declare required named assertions
#   (`# meta:ta.required_assertions="A,B"`, see declared_assertions below). An
#   exit-0 test whose required PASS is missing, or which printed an explicit FAIL
#   for one of them, is a FAIL. With GITHUB_STEP_SUMMARY set, the names and results
#   (test id + commit, never test output) go to the Job Summary. The per-test
#   status line, the RESULT line and the manifest keep their format.
# =============================================================================
set -Eeuo pipefail

INDEX_REL="scripts/ci/test-authority-index.tsv"
TESTS_PREFIX="cli/lib/nftban/tests/"
DEFAULT_TIMEOUT="120"          # seconds per test unless the row declares ta.timeout
EXECUTABLE_GATES="policy-gates ci-bash"     # run in ordinary CI
PACKAGE_GATES="package-build"               # only under --allow-package
KNOWN_GATES="policy-gates ci-bash package-build package-native-deb package-native-rpm lab-manual canary fleet manual-forensic excluded deferred unassigned"
MANIFEST=""                                 # optional --manifest FILE: machine-readable run record
QUARANTINE_FILE=""                          # optional --quarantine FILE: ci-bash quarantine registry
declare -A QID QPAT                          # quarantined id set + expected_failure_pattern (binding)

die_usage() { printf 'run-test-suite: %s\n' "$1" >&2; exit 2; }
log()       { printf '%s\n' "$1" >&2; }

# --- repository root: resolve and REFUSE to run outside the expected repo ------
resolve_root() {
    local root
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || die_usage "not inside a git repository"
    [ -f "$root/$INDEX_REL" ] || die_usage "authority index not found under repo root: $INDEX_REL"
    printf '%s' "$root"
}

# --- index validation (fail-closed): freshness + structural safety ------------
# Reads the committed index; rejects malformed rows / missing paths / duplicate
# id|path / unknown gate / path traversal. Also asserts the index is FRESH vs the
# canonical generator so a stale index cannot silently drive execution.
validate_index() {
    local root="$1" idx="$1/$INDEX_REL"
    # freshness: the generator must reproduce the committed index byte-for-byte
    if command -v python3 >/dev/null 2>&1 && [ -f "$root/scripts/ci/test-authority.py" ]; then
        python3 "$root/scripts/ci/test-authority.py" check >/dev/null 2>&1 \
            || die_usage "authority index is STALE (regenerate: test-authority.py generate)"
    fi
    # structural pass over data rows (skip banner '#' lines and the header row)
    awk -F'\t' -v prefix="$TESTS_PREFIX" -v known="$KNOWN_GATES" '
        BEGIN { split(known, kg, " "); for (i in kg) gate_ok[kg[i]] = 1; ncol = 0 }
        /^#/ { next }
        !seen_header { seen_header = 1; ncol = NF; next }
        {
            if (NF != ncol)        { print "ROW_NCOL " NR; bad = 1; next }
            id = $1; path = $2; gate = $7
            if (id == "")          { print "EMPTY_ID " NR; bad = 1 }
            if (path !~ ("^" prefix)) { print "PATH_PREFIX " NR " " path; bad = 1 }
            if (path ~ /\.\.\//)   { print "PATH_TRAVERSAL " NR " " path; bad = 1 }
            if (path ~ /[ \t]/ && path !~ ("^" prefix "[A-Za-z0-9_./-]+_test\\.sh$")) { }
            if (!(gate in gate_ok)) { print "UNKNOWN_GATE " NR " " gate; bad = 1 }
            if (id in seen_id)     { print "DUP_ID " id; bad = 1 } else seen_id[id] = 1
            if (path in seen_path) { print "DUP_PATH " path; bad = 1 } else seen_path[path] = 1
        }
        END { if (bad) exit 1 }
    ' "$idx" >"$root/.rts_valerr" 2>&1 || {
        log "run-test-suite: index validation FAILED:"; sed 's/^/  /' "$root/.rts_valerr" >&2
        rm -f "$root/.rts_valerr"; exit 2
    }
    rm -f "$root/.rts_valerr"
}

# --- selection: emit "id<TAB>path<TAB>timeout" for rows whose gate matches ------
select_rows() {
    local root="$1"; shift
    local gates=" $* "
    awk -F'\t' -v want="$gates" '
        /^#/ { next }
        !seen_header { seen_header = 1; next }
        {
            id = $1; path = $2; gate = $7; timeout = $14
            if (index(want, " " gate " ") > 0) print id "\t" path "\t" timeout
        }
    ' "$root/$INDEX_REL"
}

# --- run one test as an isolated subprocess with a bounded timeout -------------
# The path is validated (prefix + realpath inside repo) and passed as a single
# quoted argument. Never sourced, never eval'd. Returns PASS/FAIL/TIMEOUT.
# Optional 4th arg = a capture file: when set, the test's combined output is
# written there (used to compute a quarantined test's failure signature).
run_one() {
    local root="$1" path="$2" tmo="$3" cap="${4:-}"
    local abs="$root/$path"
    case "$path" in
        "$TESTS_PREFIX"*_test.sh) ;;
        *) printf 'SAFETY'; return ;;
    esac
    [ -f "$abs" ] || { printf 'MISSING'; return; }
    local real; real="$(realpath -- "$abs" 2>/dev/null || printf '')"
    case "$real" in "$root"/*) ;; *) printf 'SAFETY'; return ;; esac
    [ "$tmo" -gt 0 ] 2>/dev/null || tmo="$DEFAULT_TIMEOUT"
    local rc=0
    if [ -n "$cap" ]; then
        timeout -k 5 "$tmo" bash -- "$abs" </dev/null >"$cap" 2>&1 || rc=$?
    else
        timeout -k 5 "$tmo" bash -- "$abs" </dev/null >/dev/null 2>&1 || rc=$?
    fi
    if [ "$rc" -eq 0 ]; then printf 'PASS'
    elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then printf 'TIMEOUT'
    else printf 'FAIL'; fi
}

# --- load the quarantine registry (id -> expected_failure_pattern) -------------
# Only id + expected_failure_pattern are consumed here; full metadata validity is
# enforced by scripts/ci/check-quarantine-registry.sh (a separate BLOCKING gate).
# A registry row is (tab-separated, QT-tagged):
#   QT id path owner reason finding introduced review_or_expiry disposition \
#      expected_failure_class remediation_lane expected_failure_pattern
# The runner binds a quarantined failure to expected_failure_pattern (a NORMALIZED
# classification substring, e.g. "matcher binary unavailable"), NOT a raw error
# string — so paths/line-numbers/timing/tool-versions may vary but a CHANGED
# failure category is still not silently accepted. An empty pattern binds outcome
# only (any failure of that test is accepted while quarantined).
load_quarantine() {
    local file="$1" id pat
    [ -f "$file" ] || die_usage "quarantine registry not found: $file"
    while IFS=$'\t' read -r tag id _p _o _r _f _i _rv _d _c _l pat; do
        [ "$tag" = "QT" ] || continue
        [ -n "$id" ] || continue
        QID["$id"]=1
        QPAT["$id"]="$pat"
    done < "$file"
}

# --- required named assertions (v1.239 §1.0) -----------------------------------
# A test MAY declare, in its comment header next to its meta:ta.* fields:
#   # meta:ta.required_assertions="NAME_ONE,NAME_TWO"
# Names match ^[A-Z][A-Z0-9_]*$. The test reports each one on its own output line as
#   [PASS] NAME ...      or      [FAIL] NAME ...
# (leading whitespace allowed; the name ends at the first character outside
# [A-Za-z0-9_]). The header is read as inert text, like test-authority.py does:
# comment lines up to the first executable line. Never sourced, never eval'd.
#
# Exit semantics (binding):
#   (a) the test exits non-zero          -> its FAIL/TIMEOUT stands, whatever it printed;
#   (b) exit 0, a required PASS missing  -> FAIL;
#   (c) exit 0, an explicit [FAIL] NAME  -> FAIL (even if a [PASS] NAME is also present);
#   (d) exit 0, every name PASS, no FAIL -> PASS.
# A malformed or duplicate declaration is a FAIL (fail-closed), never "no declaration".
# A test without the header is judged by its exit status alone, exactly as before.
ASSERT_NAME_RE='^[A-Z][A-Z0-9_]*$'
ASSERT_MALFORMED="__MALFORMED__"

# Prints the declared names, one per line (nothing = no declaration).
# Prints ASSERT_MALFORMED for a malformed or repeated declaration.
declared_assertions() {
    local abs="$1" line val name seen=0
    local decl_re='^# meta:ta\.required_assertions="([^"]*)"[[:space:]]*$'
    local -a names=()
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '#!'*) continue ;;
            '#'*) ;;
            *) [ -z "${line//[[:space:]]/}" ] && continue; break ;;
        esac
        case "$line" in '# meta:ta.required_assertions='*) ;; *) continue ;; esac
        if [ "$seen" -eq 1 ] || ! [[ "$line" =~ $decl_re ]]; then
            printf '%s\n' "$ASSERT_MALFORMED"; return 0
        fi
        seen=1; val="${BASH_REMATCH[1]}"
        # empty value or an empty element (leading, trailing or double comma): `read -a`
        # would silently drop a trailing empty field, so reject it here
        case ",$val," in *,,*) printf '%s\n' "$ASSERT_MALFORMED"; return 0 ;; esac
        IFS=',' read -r -a names <<< "$val"
        for name in "${names[@]}"; do
            [[ "$name" =~ $ASSERT_NAME_RE ]] || { printf '%s\n' "$ASSERT_MALFORMED"; return 0; }
        done
    done < "$abs"
    [ "${#names[@]}" -gt 0 ] && printf '%s\n' "${names[@]}"
    return 0
}

# Judges the declared names against the captured output. Prints one
# "NAME<TAB>RESULT" line per name (RESULT = PASS | FAIL | MISSING; a malformed
# declaration gives "DECLARATION<TAB>MALFORMED"). Returns 1 when any is not PASS.
judge_assertions() {
    local cap="$1"; shift
    local name np nf bad=0
    if [ "${1:-}" = "$ASSERT_MALFORMED" ]; then
        printf 'DECLARATION\tMALFORMED\n'; return 1
    fi
    for name in "$@"; do
        # grep -c reads the whole file (no pipe, no early exit); names are validated
        # against ASSERT_NAME_RE, so they are literal inside the pattern.
        np="$(grep -acE "^[[:space:]]*\\[PASS\\][[:space:]]+${name}([^A-Za-z0-9_]|\$)" "$cap" 2>/dev/null || true)"
        nf="$(grep -acE "^[[:space:]]*\\[FAIL\\][[:space:]]+${name}([^A-Za-z0-9_]|\$)" "$cap" 2>/dev/null || true)"
        if [ "${nf:-0}" -gt 0 ]; then printf '%s\tFAIL\n' "$name"; bad=1
        elif [ "${np:-0}" -gt 0 ]; then printf '%s\tPASS\n' "$name"
        else printf '%s\tMISSING\n' "$name"; bad=1; fi
    done
    return "$bad"
}

# GitHub Actions Job Summary: names + results + commit + test id only, never test
# output. Written only when GITHUB_STEP_SUMMARY is set. Every failure here is
# swallowed: the summary can never change a test verdict or the runner's rc.
SUMMARY_STARTED=0
summary_write() {
    local root="$1" gates="$2" id="$3" status="$4" detail="$5"
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
    local sha="${GITHUB_SHA:-}"
    [ -n "$sha" ] || sha="$(git -C "$root" rev-parse HEAD 2>/dev/null || printf 'unknown')"
    local safe_id="${id//[^A-Za-z0-9._-]/?}" name result
    {
        if [ "$SUMMARY_STARTED" -eq 0 ]; then
            printf '### Shell-test assertions (gate %s)\n\n' "${gates//[^A-Za-z0-9 ._-]/?}"
            printf '| Test | Commit | Test result | Assertion | Result |\n|---|---|---|---|---|\n'
        fi
        while IFS=$'\t' read -r name result; do
            [ -n "$name" ] || continue
            printf '| `%s` | `%s` | %s | `%s` | %s |\n' "$safe_id" "${sha:0:12}" "$status" "$name" "$result"
        done <<< "$detail"
    } 2>/dev/null >> "$GITHUB_STEP_SUMMARY" || return 0
    SUMMARY_STARTED=1
    return 0
}

cmd_run() {
    local root="$1"; shift
    local gates=("$@")
    [ "${#gates[@]}" -gt 0 ] || die_usage "run requires at least one --gate"
    local g
    for g in "${gates[@]}"; do
        case " $EXECUTABLE_GATES $PACKAGE_GATES " in *" $g "*) ;; *)
            die_usage "gate '$g' is not executable by this mode" ;; esac
    done
    validate_index "$root"
    # duplicate-selection guard BEFORE executing anything
    local sel; sel="$(select_rows "$root" "${gates[@]}")"
    local nids ndistinct
    nids="$(printf '%s\n' "$sel" | grep -c . || true)"
    ndistinct="$(printf '%s\n' "$sel" | cut -f1 | sort -u | grep -c . || true)"
    [ "$nids" = "$ndistinct" ] || die_usage "duplicate selected test IDs — refusing to execute"
    # optional machine-readable manifest: truncate + header now so a skipped/aborted
    # run leaves an EMPTY-or-absent manifest (the integrity gate treats that as "step
    # did not execute" — fail-closed), never a false record.
    if [ -n "$MANIFEST" ]; then
        : > "$MANIFEST" || die_usage "cannot write manifest: $MANIFEST"
        printf '# run-test-suite manifest (machine-readable, do not edit)\nGATE\t%s\n' "${gates[*]}" >> "$MANIFEST"
    fi
    if [ "$nids" -eq 0 ]; then
        log "run-test-suite: gate(s) '${gates[*]}' selected 0 tests"
        printf 'RESULT gate=%s total=0 pass=0 fail=0 timeout=0\n' "${gates[*]}"
        [ -n "$MANIFEST" ] && printf 'SELECTED\t0\nPASS\t0\nFAIL\t0\nTIMEOUT\t0\n' >> "$MANIFEST"
        return 0
    fi
    # quarantine registry (optional): a quarantined ci-bash test STILL EXECUTES and
    # its failure is REPORTED, but it is excluded from the BLOCKING tally only when
    # its metadata is valid (checked separately) AND its failure signature matches
    # the registered one. Everything non-quarantined must pass.
    [ -n "$QUARANTINE_FILE" ] && load_quarantine "$QUARANTINE_FILE"
    local pass=0 fail=0 tmoc=0 quar=0 sigmis=0 quarpass=0 total=0
    local failed_ids="" sigmis_ids="" quarpass_ids="" manifest_rows=""
    local -A qseen
    local capdir; capdir="$(mktemp -d)"
    while IFS=$'\t' read -r id path tmo; do
        [ -n "$id" ] || continue
        total=$((total+1))
        # Always capture output so a non-quarantined FAIL/TIMEOUT can print a
        # diagnostic tail (CI otherwise discards it) and a quarantined failure can
        # be matched against its expected pattern.
        local res status cap="$capdir/out"
        [ -n "${QID[$id]:-}" ] && qseen["$id"]=1
        res="$(run_one "$root" "$path" "${tmo:-0}" "$cap")"
        # required named assertions: judged only for a test that actually ran. A
        # non-zero exit keeps its verdict (a); an exit-0 test with a missing or
        # explicitly failed required assertion becomes FAIL (b, c).
        local -a adecl=()
        local adetail="" aok=0 _an _ar
        if [ "$res" != "SAFETY" ] && [ "$res" != "MISSING" ]; then
            mapfile -t adecl < <(declared_assertions "$root/$path")
        fi
        if [ "${#adecl[@]}" -gt 0 ]; then
            adetail="$(judge_assertions "$cap" "${adecl[@]}")" || aok=1
            [ "$res" = "PASS" ] && [ "$aok" -ne 0 ] && res="FAIL"
        fi
        if [ -n "${QID[$id]:-}" ]; then
            # quarantined: STILL EXECUTES + is REPORTED. A pass BLOCKS (needs
            # reconciliation / de-quarantine). A failure is accepted only if it
            # matches the registered expected_failure_pattern (category unchanged).
            if [ "$res" = "PASS" ]; then
                pass=$((pass+1)); status="QUAR-PASS"
                quarpass=$((quarpass+1)); quarpass_ids="$quarpass_ids $id"
            else
                local pat="${QPAT[$id]:-}"
                if [ -z "$pat" ] || grep -qF -- "$pat" "$cap" 2>/dev/null; then
                    quar=$((quar+1)); status="QUARANTINED"
                else
                    sigmis=$((sigmis+1)); sigmis_ids="$sigmis_ids $id(pattern-absent)"; status="SIG-MISMATCH"
                fi
            fi
        else
            case "$res" in
                PASS)    pass=$((pass+1)); status="PASS" ;;
                TIMEOUT) tmoc=$((tmoc+1)); failed_ids="$failed_ids $id(TIMEOUT)"; status="TIMEOUT" ;;
                *)       fail=$((fail+1)); failed_ids="$failed_ids $id($res)"; status="$res" ;;
            esac
        fi
        printf '  %-12s %s\n' "$status" "$id" >&2
        # extra lines ONLY when a required assertion is not PASS (the status line
        # above keeps its exact format for every existing reader)
        if [ "$aok" -ne 0 ]; then
            {
                while IFS=$'\t' read -r _an _ar; do
                    [ "$_ar" = "PASS" ] || printf '        · required assertion %s: %s\n' "$_an" "$_ar"
                done <<< "$adetail"
            } >&2 || true
        fi
        if [ "${#adecl[@]}" -gt 0 ]; then
            summary_write "$root" "${gates[*]}" "$id" "$status" "$adetail" || true
        fi
        # diagnostic: on a BLOCKING (non-quarantined) failure, surface the test's
        # own failing lines + output tail so CI shows WHY without a re-run. The whole
        # block is `{ …; } || true` so a no-match grep cannot trip set -e / pipefail.
        if [ "$status" = "FAIL" ] || [ "$status" = "TIMEOUT" ]; then
            {
                grep -aE '✗|✘|✖|\[FAIL\]|FAIL(ED)?:|not ok' "$cap" 2>/dev/null | grep -avE '\[PASS\]|  PASS| ok ' | head -6 | sed 's/^/        · /'
                printf '        ---- %s output tail ----\n' "$id"
                tail -8 "$cap" 2>/dev/null | sed 's/^/        | /'
            } >&2 || true
        fi
        manifest_rows="${manifest_rows}TEST	${status}	${id}"$'\n'
        : > "$cap"
    done < <(printf '%s\n' "$sel" | sort -t$'\t' -k1,1)
    rm -rf "$capdir"
    # disappearance: every quarantined id must have appeared in the selected set
    local vanished="" qid
    for qid in "${!QID[@]}"; do
        [ -n "${qseen[$qid]:-}" ] || vanished="$vanished $qid"
    done
    printf 'RESULT gate=%s total=%d pass=%d fail=%d timeout=%d quarantined=%d sig_mismatch=%d quar_now_pass=%d\n' \
        "${gates[*]}" "$total" "$pass" "$fail" "$tmoc" "$quar" "$sigmis" "$quarpass"
    if [ -n "$MANIFEST" ]; then
        printf 'SELECTED\t%d\nPASS\t%d\nFAIL\t%d\nTIMEOUT\t%d\nQUARANTINED\t%d\nSIG_MISMATCH\t%d\nQUAR_NOW_PASS\t%d\n' \
            "$total" "$pass" "$fail" "$tmoc" "$quar" "$sigmis" "$quarpass" >> "$MANIFEST"
        printf '%s' "$manifest_rows" >> "$MANIFEST"
    fi
    local rc=0
    [ "$fail" -gt 0 ]     && { log "run-test-suite: BLOCKING non-quarantined failures:${failed_ids}"; rc=1; }
    [ "$tmoc" -gt 0 ]     && { log "run-test-suite: BLOCKING timeouts:${failed_ids}"; rc=1; }
    [ "$sigmis" -gt 0 ]   && { log "run-test-suite: BLOCKING quarantine signature mismatch:${sigmis_ids}"; rc=1; }
    [ "$quarpass" -gt 0 ] && { log "run-test-suite: BLOCKING quarantined test(s) now PASSING — reconcile/de-quarantine:${quarpass_ids}"; rc=1; }
    [ -n "$vanished" ]    && { log "run-test-suite: BLOCKING quarantined test(s) not executed (disappeared):${vanished}"; rc=1; }
    return "$rc"
}

cmd_report() {
    local root="$1"; shift
    local gates=("$@")
    [ "${#gates[@]}" -gt 0 ] || die_usage "report requires at least one --gate"
    validate_index "$root"
    local sel; sel="$(select_rows "$root" "${gates[@]}")"
    local n; n="$(printf '%s\n' "$sel" | grep -c . || true)"
    printf 'REPORT gate=%s count=%d (not executed)\n' "${gates[*]}" "$n"
    # Only iterate when the gate actually selected rows. An empty selection makes
    # `printf '%s\n' ""` emit one blank line, whose `[ -n "$id" ] && printf` returns
    # 1 and (under set -e/pipefail) would fail the whole report — a report of zero
    # tests is a valid, non-error outcome (e.g. once all deferred tests are activated).
    if [ "$n" -gt 0 ]; then
        printf '%s\n' "$sel" | sort -t$'\t' -k1,1 | while IFS=$'\t' read -r id path tmo; do
            [ -n "$id" ] && printf '  %-10s %s  %s\n' "REPORTED" "$id" "$path" >&2
        done
    fi
    return 0
}

cmd_summary() {
    local root="$1"
    validate_index "$root"
    awk -F'\t' '/^#/{next} !h{h=1;next} {c[$7]++} END{for(g in c) printf "  %-16s %d\n", g, c[g]}' \
        "$root/$INDEX_REL" | sort
}

main() {
    [ $# -ge 1 ] || die_usage "usage: run-test-suite.sh {run|report|verify|summary} [--gate <gate>]..."
    local mode="$1"; shift
    local root; root="$(resolve_root)"
    local gates=() allow_package=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --gate) shift; [ $# -ge 1 ] || die_usage "--gate needs a value"; gates+=("$1") ;;
            --manifest) shift; [ $# -ge 1 ] || die_usage "--manifest needs a value"; MANIFEST="$1" ;;
            --quarantine) shift; [ $# -ge 1 ] || die_usage "--quarantine needs a value"; QUARANTINE_FILE="$1" ;;
            --allow-package) allow_package=1 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
        shift
    done
    # package-build is executable ONLY with the explicit package authority flag
    local g
    for g in "${gates[@]:-}"; do
        [ "$g" = "package-build" ] && [ "$allow_package" -ne 1 ] \
            && die_usage "gate 'package-build' requires --allow-package (package authority only)"
    done
    case "$mode" in
        run)     cmd_run "$root" "${gates[@]}" ;;
        report)  cmd_report "$root" "${gates[@]}" ;;
        verify)  validate_index "$root"; log "run-test-suite: index VALID"; ;;
        summary) cmd_summary "$root" ;;
        *) die_usage "unknown mode: $mode" ;;
    esac
}

main "$@"
