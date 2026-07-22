#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="run-test-suite"
# meta:type="script"
# meta:version="1.226.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Index-driven shell-test runner: the authority index drives selection + isolated execution by gate"
# meta:inventory.files="scripts/ci/test-authority-index.tsv,scripts/ci/test-authority.py"
# meta:inventory.binaries="bash,git,awk,grep,sort,cut,realpath,timeout,printf,sed,python3"
# meta:inventory.env_vars=""
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
# =============================================================================
set -Eeuo pipefail

INDEX_REL="scripts/ci/test-authority-index.tsv"
TESTS_PREFIX="cli/lib/nftban/tests/"
DEFAULT_TIMEOUT="120"          # seconds per test unless the row declares ta.timeout
EXECUTABLE_GATES="policy-gates ci-bash"     # run in ordinary CI
PACKAGE_GATES="package-build"               # only under --allow-package
KNOWN_GATES="policy-gates ci-bash package-build package-native-deb package-native-rpm lab-manual canary fleet manual-forensic excluded deferred unassigned"
MANIFEST=""                                 # optional --manifest FILE: machine-readable run record

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
run_one() {
    local root="$1" path="$2" tmo="$3"
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
    timeout -k 5 "$tmo" bash -- "$abs" </dev/null >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then printf 'PASS'
    elif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then printf 'TIMEOUT'
    else printf 'FAIL'; fi
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
    local pass=0 fail=0 tmoc=0 total=0 failed_ids="" manifest_rows=""
    # deterministic order: sort by id
    while IFS=$'\t' read -r id path tmo; do
        [ -n "$id" ] || continue
        total=$((total+1))
        local res; res="$(run_one "$root" "$path" "${tmo:-0}")"
        case "$res" in
            PASS)    pass=$((pass+1)) ;;
            TIMEOUT) tmoc=$((tmoc+1)); failed_ids="$failed_ids $id(TIMEOUT)" ;;
            *)       fail=$((fail+1)); failed_ids="$failed_ids $id($res)" ;;
        esac
        printf '  %-8s %s\n' "$res" "$id" >&2
        manifest_rows="${manifest_rows}TEST	${res}	${id}"$'\n'
    done < <(printf '%s\n' "$sel" | sort -t$'\t' -k1,1)
    printf 'RESULT gate=%s total=%d pass=%d fail=%d timeout=%d\n' "${gates[*]}" "$total" "$pass" "$fail" "$tmoc"
    if [ -n "$MANIFEST" ]; then
        printf 'SELECTED\t%d\nPASS\t%d\nFAIL\t%d\nTIMEOUT\t%d\n' "$total" "$pass" "$fail" "$tmoc" >> "$MANIFEST"
        printf '%s' "$manifest_rows" >> "$MANIFEST"
    fi
    if [ "$fail" -gt 0 ] || [ "$tmoc" -gt 0 ]; then
        log "run-test-suite: FAILED tests:${failed_ids}"
        return 1
    fi
    return 0
}

cmd_report() {
    local root="$1"; shift
    local gates=("$@")
    [ "${#gates[@]}" -gt 0 ] || die_usage "report requires at least one --gate"
    validate_index "$root"
    local sel; sel="$(select_rows "$root" "${gates[@]}")"
    local n; n="$(printf '%s\n' "$sel" | grep -c . || true)"
    printf 'REPORT gate=%s count=%d (not executed)\n' "${gates[*]}" "$n"
    printf '%s\n' "$sel" | sort -t$'\t' -k1,1 | while IFS=$'\t' read -r id path tmo; do
        [ -n "$id" ] && printf '  %-10s %s  %s\n' "REPORTED" "$id" "$path" >&2
    done
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
