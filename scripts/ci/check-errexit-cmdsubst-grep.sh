#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# check-errexit-cmdsubst-grep.sh — v1.235 H1 recurrence guard.
#
# THE SHAPE
#     set -Eeuo pipefail
#     var=$(grep PATTERN file | cut ... | tr ...)
#
# grep exits 1 when nothing matches. Under pipefail that is the pipeline's
# status, the command substitution returns it, and a bare assignment returns
# the substitution's status — so errexit fires on "the key is not set", which is
# a normal configuration, not an error. No pipe is needed: `var=$(grep ...)`
# alone fails the same way, and so does `var=$(grep -c ...)` on a zero count.
#
# MEASURED (v1.234.0, dns4): conf.d/botscan/main.conf.local held only
# BOTSCAN_404_TRACKING=false. `lm=$(grep -m1 '^BOTSCAN_ACTION_MODE=' ... | cut |
# tr)` failed, errexit killed the process substitution the health renderer reads
# its facts from, and `nftban health` printed BotScan "DISABLED" with empty
# fields for an enabled scanner (BUG-HEALTH-BOTSCAN-FACTS-ERREXIT-ON-LOCAL-CONF-
# WITHOUT-ACTION-MODE). The EPIPE guard does not see this: it bans
# `producer | grep -q`, a different failure (SIGPIPE on the producer).
#
# DETECTED — one logical line (backslash continuations joined) carrying
#     NAME=$( ... grep ... )
# that is not guarded. GUARDED (not reported):
#     NAME=$( grep ... || true )          the substitution cannot fail
#     NAME=$( grep ... ) || NAME=default  the failure is consumed
#     NAME=$( grep ... ) && ...           not the last command of an && list
#     if/elif/while/until NAME=$(...)     errexit is off in a condition
#     local|declare|readonly|export|typeset NAME=$(...)
#                                         the builtin's status masks it (SC2155)
# `[[ ... ]] && NAME=$(grep ...)` IS reported: the assignment is the last
# command of the list, and errexit applies to it.
#
# POPULATION — the health and status surfaces first (owner scope for H1): they
# run inside the dispatcher's errexit (cli/sbin/nftban, lib/strict.sh), and a
# silent abort there turns into a FALSE health claim rather than an error.
#
# REGISTRY — scripts/ci/data/errexit-cmdsubst-grep-registry.tsv declares every
# site the detector finds. It is a DEBT register, not an allowlist:
#     detected, not declared   -> FAIL  new exposure introduced
#     declared, not detected   -> FAIL  fixed or edited; reconcile the row
# A row is keyed by file + the normalised logical line (whitespace collapsed), so
# edits elsewhere in the file do not churn it.
#
# LIMITS (declared, not hidden): a substitution that spans lines without a
# backslash continuation is not seen, and whether errexit is actually in effect
# at a declared site depends on its caller (`main || exit` suspends errexit in
# the main call tree, but not inside a `< <(...)` process substitution). That is
# why every pre-existing row is DEBT with that note rather than "safe".
#
# Usage: check-errexit-cmdsubst-grep.sh [--selftest | --emit-rows]
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REGISTRY="scripts/ci/data/errexit-cmdsubst-grep-registry.tsv"
POPULATION_GLOBS=(
    'cli/lib/nftban/core/nftban_health*.sh'
    'cli/lib/nftban/core/*_health.sh'
    'cli/lib/nftban/cli/cmd_health*.sh'
    'cli/lib/nftban/cli/cmd_status*.sh'
)

# detect <file>... -> "file<TAB>lineno<TAB>normalised logical line", one per finding
detect() {
    awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function norm(s) { gsub(/[ \t]+/, " ", s); return trim(s) }
    # Index of the ")" closing the "(" at position p (1-based), or 0.
    function close_of(s, p,    i, c, depth) {
        depth = 1
        for (i = p + 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (c == "(") depth++
            else if (c == ")") { depth--; if (depth == 0) return i }
        }
        return 0
    }
    function analyse(file, ln, line,    s, rest, off, m, a, p, q, body, after, pre, flagged) {
        s = trim(line)
        if (s == "" || substr(s, 1, 1) == "#") return
        rest = s; off = 0; flagged = 0
        while (match(rest, /(^|[ \t;&|({!])[A-Za-z_][A-Za-z0-9_]*=\$\(/)) {
            m = substr(rest, RSTART, RLENGTH)
            a = off + RSTART + (m ~ /^[ \t;&|({!]/ ? 1 : 0)       # assignment start
            p = off + RSTART + RLENGTH - 2                           # the "$" of "$("
            q = close_of(s, p + 1)   # p + 1 is the "("
            off = off + RSTART + RLENGTH - 1
            rest = substr(s, off + 1)
            if (q == 0) continue
            body = substr(s, p + 2, q - p - 2)
            if (body !~ /(^|[^A-Za-z0-9_-])grep([ \t]|$)/) continue
            if (body ~ /\|\|/) continue
            after = trim(substr(s, q + 1))
            if (after ~ /^(\|\||&&)/) continue
            pre = substr(s, 1, a - 1)
            sub(/.*(;|\|\||&&|\{|then[ \t]|do[ \t]|else[ \t])/, "", pre)
            pre = trim(pre)
            if (pre ~ /^(if|elif|while|until|!)([ \t]|$)/) continue
            if (pre ~ /^(local|declare|readonly|export|typeset)([ \t]|$)/) continue
            flagged = 1
        }
        if (flagged) printf "%s\t%d\t%s\n", file, ln, norm(s)
    }
    FNR == 1 { buf = ""; start = 0 }
    {
        line = $0
        if (buf == "") start = FNR
        if (line ~ /\\$/) { buf = buf substr(line, 1, length(line) - 1) " "; next }
        analyse(FILENAME, start, buf line)
        buf = ""
    }' "$@"
}

population() {
    local g f
    for g in "${POPULATION_GLOBS[@]}"; do
        for f in $g; do [[ -f "$f" ]] && printf '%s\n' "$f"; done
    done | sort -u
}

selftest() {
    local t; t="$(mktemp -d)"
    cat > "$t/fx.sh" <<'FIXTURE'
u1=$(grep -m1 '^K=' "$f" 2>/dev/null | cut -d= -f2- | tr -d '"')
u2=$(grep -c x "$f")
[[ -f "$f" ]] && u3=$(grep '^K=' "$f" | tr -d x)
u4=$(grep -E '^[[:space:]]*K=' "$f" 2>/dev/null | tr -d x \
     | cut -d= -f2-)
g1=$(grep -m1 '^K=' "$f" | cut -d= -f2- || true)
g2=$(grep -m1 '^K=' "$f" | cut -d= -f2-) || g2=""
g3=$(grep '^K=' "$f") && echo found
if g4=$(grep '^K=' "$f"); then :; fi
local g5=$(grep '^K=' "$f")
g6=$(sed -n 1p "$f" | cut -c1)
# c1=$(grep x f)
g7=$(grep -m1 '^K=' "$f" 2>/dev/null | tr -d x \
     | cut -d= -f2- || true)
FIXTURE
    local out want got bad=0
    out="$(detect "$t/fx.sh")"
    want=$'u1\nu2\nu3\nu4'
    got="$(printf '%s\n' "$out" | awk -F'\t' 'NF{split($3,a,"="); s=a[1]; sub(/.*[ \t]/,"",s); print s}')"
    if [[ "$got" == "$want" ]]; then
        echo "SELFTEST detect: PASS (4 unguarded forms found; 7 guarded forms and 1 comment ignored)"
    else
        echo "SELFTEST detect: FAIL — want [${want//$'\n'/ }] got [${got//$'\n'/ }]"; bad=1
    fi
    # Ratchet arms: the exact declared set passes; one undeclared site fails; one
    # stale row fails.
    printf '%s\n' "$out" | awk -F'\t' 'NF{printf "%s\tDEBT\tH1\t%s\n", $1, $3}' > "$t/exact.tsv"
    head -n 3 "$t/exact.tsv" > "$t/undeclared.tsv"
    { cat "$t/exact.tsv"; printf 'x.sh\tDEBT\tH1\tstale=$(grep a b)\n'; } > "$t/stale.tsv"
    local rc_exact=0 rc_undecl=0 rc_stale=0
    ratchet "$t/exact.tsv" "$out" >/dev/null 2>&1 || rc_exact=$?
    ratchet "$t/undeclared.tsv" "$out" >/dev/null 2>&1 || rc_undecl=$?
    ratchet "$t/stale.tsv" "$out" >/dev/null 2>&1 || rc_stale=$?
    if [[ "$rc_exact" -eq 0 && "$rc_undecl" -ne 0 && "$rc_stale" -ne 0 ]]; then
        echo "SELFTEST ratchet: PASS (exact set passes; undeclared site fails; stale row fails)"
    else
        echo "SELFTEST ratchet: FAIL — exact=$rc_exact undeclared=$rc_undecl stale=$rc_stale"; bad=1
    fi
    rm -rf "$t"
    return "$bad"
}

# ratchet <registry> <findings> -> rc 0 only if the two sets are equal and every row is well-formed
ratchet() {
    local reg="$1" findings="$2" fail=0 key file disp handle site
    declare -A declared=() detected=()
    if [[ ! -f "$reg" ]]; then
        echo "FAIL [ERREXIT_GREP_REGISTRY_MISSING] $reg absent — cannot ratchet an undeclared population"
        return 1
    fi
    while IFS=$'\t' read -r file disp handle site; do
        [[ -z "$file" || "$file" == \#* ]] && continue
        case "$disp" in
            DEBT|CONTEXT_SAFE) ;;
            *) echo "FAIL [ERREXIT_GREP_REGISTRY_SCHEMA] $file — disposition '$disp' is not DEBT|CONTEXT_SAFE"; fail=1 ;;
        esac
        [[ -n "$handle" && -n "$site" ]] || { echo "FAIL [ERREXIT_GREP_REGISTRY_SCHEMA] $file — empty handle or site"; fail=1; }
        declared["$file"$'\t'"$site"]=1
    done < "$reg"
    local lineno
    while IFS=$'\t' read -r file lineno site; do
        [[ -z "$file" ]] && continue
        key="$file"$'\t'"$site"
        detected["$key"]=1
        if [[ -z "${declared[$key]+x}" ]]; then
            echo "FAIL [ERREXIT_GREP_UNDECLARED] $file:$lineno — unguarded \`var=\$(grep ...)\` under errexit: $site"
            echo "     fix: \`var=\$(grep ... || true)\` or \`var=\$(grep ...) || var=default\`"
            fail=1
        fi
    done <<<"$findings"
    for key in "${!declared[@]}"; do
        if [[ -z "${detected[$key]+x}" ]]; then
            echo "FAIL [ERREXIT_GREP_STALE] declared but no longer detected (fixed or edited — reconcile the row): ${key//$'\t'/ :: }"
            fail=1
        fi
    done
    return "$fail"
}

cd "$ROOT"
if [[ "${1:-}" == "--selftest" ]]; then
    selftest
    exit $?
fi

mapfile -t files < <(population)
# --emit-rows prints the current findings in registry form (disposition DEBT,
# handle UNTRIAGED) for a human to review and triage; it never writes the file.
if [[ "${1:-}" == "--emit-rows" ]]; then
    detect "${files[@]}" | awk -F'\t' '{printf "%s\tDEBT\tUNTRIAGED-v1235-H1\t%s\n", $1, $3}'
    exit 0
fi
if [[ "${#files[@]}" -eq 0 ]]; then
    echo "FAIL [ERREXIT_GREP_EMPTY_POPULATION] no file matched ${POPULATION_GLOBS[*]} — the guard would pass vacuously"
    exit 1
fi
findings="$(detect "${files[@]}")"
n_found=0
[[ -n "$findings" ]] && n_found="$(printf '%s\n' "$findings" | wc -l)"
rc=0
ratchet "$REGISTRY" "$findings" || rc=$?
echo "ERREXIT_CMDSUBST_GREP population=${#files[@]} files detected=${n_found// /} result=$([[ "$rc" -eq 0 ]] && echo PASS || echo FAIL)"
exit "$rc"
