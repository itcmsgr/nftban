#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# check-pipefail-epipe-shortcircuit.sh — v1.228.9 recurrence guard.
#
# THE SHAPE
#     set -o pipefail
#     producer | <consumer that stops reading early>
#
# A consumer that exits before end-of-input closes the pipe. The producer's next
# write takes SIGPIPE (exit 141) and `pipefail` propagates that as a FAILED
# pipeline — even though the consumer's own answer was correct. Whether it fires
# depends on how much the producer had left to write, so the same expression
# passes on a small output and fails on a large one.
#
# MEASURED IN THIS TRAIN: seven occurrences across the v1.228.8/.9 control
# plane. It made the control-enforcement gate report "no CI consumer" for gates
# that were correctly wired; made a DEP-5 control claim the ownership gate had
# regressed to string matching; and failed BC8 in CI while passing locally.
# Two sat inside CLASSIFICATION logic, where a flaky negative changes a policy
# disposition rather than just a test result — an EPIPE there would misclassify
# a generated artifact as not generated.
#
# PRECISION — this guard bans one shape, not a command:
#   flagged      producer | grep -q ...      where pipefail is in effect
#   NOT flagged  grep -q PATTERN file        (no upstream, cannot EPIPE)
#   NOT flagged  producer | wc -l            (wc reads to EOF, never closes early)
# The fix is to count, or to drain, instead of short-circuiting:
#   [[ "$(producer | grep -c PATTERN || true)" -gt 0 ]]
#   out="$(producer)"; [[ "$out" == *PATTERN* ]]
#
# =============================================================================
# v1.231.0 LANE G — FOURTH POPULATION CORRECTION *AND* A DETECTOR CORRECTION
# =============================================================================
#
# History of this file's population, each correction recorded because each was a
# case of the rule being right and the SUBJECT being wrong:
#   1st  scoped by the filename pattern `scripts/ci/check-*.sh`. A script is
#        merge-deciding because CI INVOKES IT, not because of how it was named;
#        scripts/ci/migration-coverage-gate.sh had its own blocking workflow and
#        carried the forbidden form in the FAIL-OPEN direction, unscanned.
#   2nd  the executed shell-test corpus was excluded as "noise". The verdicts of
#        the tests the CI runner executes as BLOCKING evidence ARE merge
#        decisions; v131_pr_a_2_double_zero_sweep_test was ~95% blind because of
#        exactly this shape and reported PASS over four real product defects.
#   3rd  the workflow-reference regex forbade '/', so four workflow-invoked
#        scripts one directory deeper were silently excluded. Now asserted by
#        assert_no_depth_exclusion() rather than claimed.
#   4th  (THIS CHANGE) the union of the two populations was 428 files, of which
#        ZERO were product code. The guard governed the control plane and the
#        product's TESTS — never the product. A read-only census over every
#        shell file under cli/ (551 sites, 121 files) found 74 SIGPIPE-SENSITIVE
#        sites, 39 of them on a security- or count-reporting surface, all of
#        them outside every population this guard had ever scanned.
#
# THE DETECTOR WAS ALSO WRONG, INDEPENDENTLY OF THE POPULATION.
#
# (a) THE BUILTIN-PRODUCER EXEMPTION IS EMPIRICALLY FALSE — REMOVED.
#     The previous matcher carried
#         | grep -vE '(^|[^A-Za-z_])(echo|printf)[^|]*\|[[:space:]]*grep'
#     justified as "a BUILTIN producer cannot be EPIPE'd in practice: echo/printf
#     complete before grep can exit". MEASURED FALSE on this workstation, bash
#     5.x, `set -Eeuo pipefail`, producer written in the real `nft list set` line
#     shape, marker matched on line 1 (so the consumer exits immediately):
#
#         producer bytes   `echo "$v" | grep -q 'elements = {'`
#              9,177       rc=0    (0/20 non-zero)
#             72,953       rc=141  (19/20 non-zero)
#            202,399       rc=141  (20/20 non-zero)
#            407,281       rc=141  (20/20 non-zero)
#         202,399 with printf instead of echo -> rc=141
#
#     A builtin writes through the same 64 KiB kernel pipe buffer as any other
#     producer. Past the buffer it blocks, the consumer exits, and the builtin
#     takes SIGPIPE like anything else. The exemption did not describe a
#     mechanism; it described a small test case. cli/lib/nftban/cli/cmd_botguard.sh
#     is exactly that shape and reports 0 elements for a production-sized set.
#
#     The replacement rule is about the CONSUMER, which is where the correctness
#     property actually lives: a consumer that can stop reading before EOF can
#     EPIPE its producer, whatever the producer is. No producer is exempt.
#
# (b) THE CONSUMER SET WAS TOO NARROW. The old matcher recognised only
#     `grep -[a-zA-Z]*q`. Replaying it over the census's 74 SIGPIPE-sensitive
#     sites caught 35: 21 were lost to the false builtin exemption above and 18
#     because the consumer was `head`, which the matcher never looked for.
#     47% detection. Now recognised, each because it can exit before EOF:
#         grep -q / -qF / -qE / -qw / -qxF     stops at the first match
#         grep -m N / --max-count              stops after N matches
#         grep -l                              stops at the first match (stdin)
#         head (-n, -c, or bare)               stops after the requested amount
#         sed with a `q`/`Q` command           stops at the quit
#         awk with an `exit` statement         stops at the exit
#     NOT recognised, because they read to EOF and therefore cannot close the
#     pipe early: wc, sort, tail, cat, sha256sum, tee, tr, cut, uniq, jq.
#     `sed q` and `awk … exit` ARE included: they are the same correctness
#     property, and the census found 11 `awk … exit` sites in the product. They
#     were measured as a class, not assumed — `head` is the same mechanism and
#     was measured directly: `echo "$v" | head -n 1` returned 141 at 202,399
#     bytes WITH THE CORRECT VALUE on stdout, which is the whole hazard: the
#     answer is right and the status is wrong.
#
# WHAT THIS CHANGE DOES **NOT** CLAIM. The EPIPE class is NOT closed. The census
# proves the opposite: 74 sensitive sites plus 162 that need a host probe to
# classify at all. Active release-blocking instances are fixed in other lanes;
# what this file does is bring the product population under an enforceable
# ratchet and register the remaining classified debt explicitly, so it is owed
# work rather than invisible work.
# =============================================================================
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

PKG_MANIFEST="packaging/build_nftban.sh"
REGISTRY="scripts/ci/data/pipefail-epipe-exposure-registry.tsv"
INVENTORY="scripts/ci/data/pipefail-epipe-test-corpus-inventory.tsv"
ALLOW="scripts/ci/data/pipefail-epipe-allowlist.txt"

# The ONE directory deliberately kept out of the product population, declared
# here rather than buried in a regex. It is not unscanned: it is the subject of
# test_corpus_population() below, under the per-file count ratchet. The
# assert_product_population() closure check PROVES that claim rather than
# repeating it.
PRODUCT_EXCLUDED_DIR="cli/lib/nftban/tests"

# =============================================================================
# DETECTOR — shared by every population, so a plane cannot be scanned by a
# weaker rule than its neighbour.
# =============================================================================

# _epipe_classify — does the text following a pipe bar start a consumer that can
# stop reading before EOF? Sets _EPIPE_C to the consumer label; returns 1 if not.
_epipe_classify() {
    local seg="$1" a b
    _EPIPE_C=""
    seg="${seg#"${seg%%[![:space:]]*}"}"
    # Truncate at the next REAL pipeline boundary — a bar with whitespace on one
    # side. A bar inside a quoted argument (`awk -F'|'`, `sed 's/|/,/'`) is
    # written WITHOUT surrounding whitespace, so this keeps the consumer's own
    # program text intact instead of cutting it in half. MEASURED: without this,
    # `grep -a … | awk -F'|' 'NR==1 {print $1; exit}'` in
    # cli/lib/nftban/core/nftban_stats_collect.sh:555 classified as "no exit".
    a="${seg%%[[:space:]]|*}"
    b="${seg%%|[[:space:]]*}"
    if [[ ${#a} -le ${#b} ]]; then seg="$a"; else seg="$b"; fi
    seg="${seg#command }"; seg="${seg#exec }"
    seg="${seg#/usr/bin/}"; seg="${seg#/bin/}"
    case "$seg" in
        grep|grep\ *|egrep|egrep\ *|fgrep|fgrep\ *)
            if [[ $seg =~ (^|[[:space:]])-[A-Za-z]*q[A-Za-z]*([[:space:]]|$) ]]; then _EPIPE_C='grep-q'; return 0; fi
            if [[ $seg =~ (^|[[:space:]])(-m[[:space:]]*[0-9]|--max-count) ]]; then _EPIPE_C='grep-m'; return 0; fi
            if [[ $seg =~ (^|[[:space:]])-[A-Za-z]*l[A-Za-z]*([[:space:]]|$) ]]; then _EPIPE_C='grep-l'; return 0; fi
            return 1 ;;
        head|head\ *) _EPIPE_C='head'; return 0 ;;
        sed|sed\ *)
            if [[ $seg =~ (^|[\;\{\'\"[:space:]])[0-9]*[qQ]([\;\}\'\"[:space:]]|$) ]]; then _EPIPE_C='sed-q'; return 0; fi
            return 1 ;;
        awk|awk\ *|gawk|gawk\ *|mawk|mawk\ *)
            if [[ $seg =~ (^|[^A-Za-z_])exit([^A-Za-z_]|$) ]]; then _EPIPE_C='awk-exit'; return 0; fi
            return 1 ;;
    esac
    return 1
}

# detect_sites — emits "<line-number>\t<consumers>" for every flagged line of $1.
# Reads the file ONCE into an array: no `sed -n Np` per candidate, and above all
# no pipeline of its own that could carry the defect it is looking for.
detect_sites() {
    local f="$1" i=0 line stripped rest seg cons
    local -a LINES=()
    mapfile -t LINES < "$f" 2>/dev/null || return 0
    for ((i = 0; i < ${#LINES[@]}; i++)); do
        line="${LINES[$i]}"
        [[ "$line" == *"|"* ]] || continue
        # MENTION != CODE. Testing `\#*` against the RAW line only matches a
        # comment at column 0; an INDENTED comment describing the forbidden form
        # was once reported as the form itself. Strip leading whitespace first.
        stripped="${line#"${line%%[![:space:]]*}"}"
        case "$stripped" in \#*) continue ;; esac
        case "$line" in *"# epipe-ok"*) continue ;; esac
        cons=""
        rest="$line"
        while [[ "$rest" == *"|"* ]]; do
            rest="${rest#*|}"
            # `||` IS NOT A PIPE. `[ -z "$x" ] || grep -qF pat file` has no
            # pipeline at all — grep reads a FILE. Consume both bars and move on.
            if [[ "$rest" == "|"* ]]; then rest="${rest#|}"; continue; fi
            seg="${rest#&}"   # `|&` also pipes stderr; still a pipe
            if _epipe_classify "$seg"; then
                case ",$cons," in *",$_EPIPE_C,"*) : ;; *) cons="${cons:+$cons,}$_EPIPE_C" ;; esac
            fi
        done
        [[ -n "$cons" ]] && printf '%s\t%s\n' "$((i + 1))" "$cons"
    done
    return 0
}

# Content-anchored identity. Line NUMBERS drift on any edit and would locate the
# subject by position; the fingerprint is the whitespace-normalised line text, so
# a registry row survives every edit that does not change the pipeline itself.
epipe_fingerprint() {
    local s="$1" h
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    while [[ "$s" == *"  "* ]]; do s="${s//  / }"; done
    h="$(printf '%s' "$s" | sha256sum)"   # sha256sum reads to EOF — cannot EPIPE
    printf '%s' "${h:0:16}"
}

declares_pipefail() {
    grep -qE '^[[:space:]]*set[[:space:]]+-[A-Za-z]*o?[[:space:]]*pipefail|set[[:space:]]+-o[[:space:]]+pipefail' "$1" 2>/dev/null
}

is_shell_file() {
    local f="$1" first=""
    [[ -f "$f" ]] || return 1
    case "$f" in *.sh) return 0 ;; esac
    read -r first < "$f" 2>/dev/null || return 1
    # `*sh*` already covers bash/dash/ksh/zsh shebangs; a separate `*bash*`
    # alternative would be dead.
    case "$first" in \#\!*sh*) return 0 ;; esac
    return 1
}

# =============================================================================
# POPULATIONS — each derived from an EXECUTION AUTHORITY, never from a path regex
# =============================================================================

# gate_population — the authority is CI WIRING, not a naming convention.
# Mechanically derived so it cannot drift into a hand-curated list, which would
# just replace one proxy with another. DEPTH-AGNOSTIC: the character class
# permits '/', so a workflow-invoked script is in scope however deeply nested.
#
# ⛔ EVERY ARM ENDS IN `|| true`. MEASURED v1.231.0 Lane G: with `set -o pipefail`
# armed, `{ …; grep …; } | sort -u` takes the GROUP's status from its last
# command, so a `grep` that simply found nothing made this function return 1 —
# and under errexit that KILLED the guard mid-run, after the first arm and before
# the three assertions. The observed symptom was `rc=1` with no FAIL line
# attributing it to anything. ZERO MATCHES IS AN ANSWER, NOT AN ERROR.
gate_population() {
    {
        git ls-files 'scripts/ci/check-*.sh' 2>/dev/null || true
        grep -rhoE 'scripts/ci/[A-Za-z0-9._/-]+\.sh' .github/workflows/ 2>/dev/null || true
    } | sort -u
}

# test_corpus_population — the tests the runner actually executes for a BLOCKING
# gate, read from the canonical authority index. A test whose verdict is merge
# evidence is a merge-deciding subject.
test_corpus_population() {
    awk -F'\t' '$7=="ci-bash" || $7=="policy-gates" { print $2 }' \
        scripts/ci/test-authority-index.tsv 2>/dev/null | sort -u
}

# packaged_lib_subdirs — the payload subtrees the RPM %files manifest declares
# under /usr/lib/nftban. This is the PACKAGING AUTHORITY: a directory added to
# the package enters the population without anyone editing this file.
packaged_lib_subdirs() {
    { grep -oE '^/usr/lib/nftban/[A-Za-z0-9_-]+/\*$' "$PKG_MANIFEST" 2>/dev/null || true; } \
        | sed -E 's|^/usr/lib/nftban/||; s|/\*$||' | sort -u
}

# execstart_sources — every shipped systemd unit's ExecStart*= target, mapped
# back to its source path through the staging rules in the packaging manifest.
# Cited by the COMMAND TEXT, not by line number, so the citation survives edits
# above it — grep packaging/build_nftban.sh for each:
#     cli/sbin/nftban        -> /usr/sbin/nftban
#         `install -D -m 0750 cli/sbin/nftban %{buildroot}/usr/sbin/nftban`
#     cli/sbin/<helper>      -> /usr/lib/nftban/sbin/<helper>
#         `install -m 0755 cli/sbin/<helper> %{buildroot}/usr/lib/nftban/sbin/`
#         and the DEB loop `for script in nftban-apply nftban-confirm …`
#     cli/lib/nftban/<rest>  -> /usr/lib/nftban/<rest>
#         `cp -r cli/lib/nftban/* %{buildroot}/usr/lib/nftban/` (RPM) and
#         `cp -r "${PROJECT_ROOT}/cli/lib/nftban"/* "${deb_root}/usr/lib/nftban/"`
#     install/<rest>         -> /usr/lib/nftban/<rest>
#         `install -D -m 0755 install/helpers/… %{buildroot}/usr/lib/nftban/helpers/…`
# A unit that starts a shell script IS the product execution plane, by
# definition, and needs no further argument about naming or location.
execstart_sources() {
    local t rest cand
    while IFS= read -r t; do
        [[ -n "$t" ]] || continue
        case "$t" in
            /usr/sbin/nftban) cand="cli/sbin/nftban" ;;
            /usr/lib/nftban/sbin/*) cand="cli/sbin/${t#/usr/lib/nftban/sbin/}" ;;
            /usr/lib/nftban/*)
                rest="${t#/usr/lib/nftban/}"
                cand="cli/lib/nftban/$rest"
                [[ -f "$cand" ]] || cand="install/$rest"
                ;;
            *) continue ;;
        esac
        [[ -f "$cand" ]] && printf '%s\n' "$cand"
    done < <({ grep -rhoE '^ExecStart[A-Za-z]*=[^ ]*' install/systemd packaging/systemd 2>/dev/null || true; } \
             | sed -E 's/^ExecStart[A-Za-z]*=//; s/^[+!@-]+//' | sort -u)
    return 0
}

# product_population — the shell the package SHIPS and the units EXECUTE.
#
# ⛔ NOT A PATH REGEX. A path regex is precisely how the gap this corrects was
# created: `scripts/ci/` was a literal prefix in both arms of gate_population(),
# and nothing outside it could ever be scanned no matter how merge-deciding or
# how dangerous it was. The authority here is the packaging manifest plus the
# systemd units, so the population is a CONSEQUENCE of what ships and what runs.
product_population() {
    {
        local d
        while IFS= read -r d; do
            [[ -n "$d" ]] || continue
            # /usr/lib/nftban/bin/* is the Go payload, staged from bin/ — not shell.
            [[ "$d" == "bin" ]] && continue
            # /usr/lib/nftban/sbin/* is staged from cli/sbin/, covered below.
            [[ -d "cli/lib/nftban/$d" ]] || continue
            git ls-files "cli/lib/nftban/$d/*" 2>/dev/null
        done < <(packaged_lib_subdirs)
        # `/usr/lib/nftban/*.sh` — the top-level payload line of the same manifest.
        # `:(glob)` is load-bearing. A PLAIN git pathspec `*` matches across '/',
        # so `cli/lib/nftban/*.sh` silently resolved to all 620 shell files in the
        # subtree: it made the manifest-derived arm above redundant, and it made a
        # MISSING packaging manifest look like a fully populated plane — the
        # assertion written to catch an empty population would have been the thing
        # hiding it. MEASURED: 620 files plain, 1 with `:(glob)`.
        git ls-files ':(glob)cli/lib/nftban/*.sh' 2>/dev/null
        # cli/sbin -> /usr/sbin/nftban + /usr/lib/nftban/sbin/*
        git ls-files 'cli/sbin/*' 2>/dev/null
        execstart_sources
    } | sort -u | {
        local f
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            case "$f" in "$PRODUCT_EXCLUDED_DIR"/*) continue ;; esac
            # `if`, not `&&`. A while loop's status is its LAST BODY COMMAND, so
            # `is_shell_file "$f" && printf …` made the loop return 1 whenever the
            # final candidate was not a shell file — and with pipefail that became
            # the function's status, which under errexit killed the caller before
            # the empty-population assertion could fire. MEASURED: the guard exited
            # rc=1 at "product population assertion" printing no FAIL line at all.
            if is_shell_file "$f"; then printf '%s\n' "$f"; fi
        done
    }
}

# =============================================================================
# ASSERTIONS — a population bug of this shape is invisible: the guard still runs,
# still prints OK, and simply inspects less. So the populations are PROVEN, not
# trusted. Each helper prints its failures and echoes the failure COUNT.
# =============================================================================

# ⛔ The failure LINES go to stdout and the COUNT comes back in a GLOBAL. These
# helpers used to `printf` their failures and then `printf '%d' "$bad"` as the
# function's only return channel, so a caller writing `n="$(assert_...)"`
# swallowed every FAIL line into the variable and then compared a multi-line
# string with `-eq 0` — which bash evaluates as 0. The assertion reported OK
# while failing. An assertion whose failures are captured by its own return
# channel cannot assert anything.
assert_no_depth_exclusion() {
    local referenced pop missing=0 f
    # `grep -c`/`grep -r` exit 1 on zero matches. A repository with no workflow
    # references is a legitimate state (and is exactly the state an isolated
    # fixture is in); letting that rc kill the run under errexit would turn an
    # empty result into a crash, which is the ABSENT_QUERY != RESOURCE_ABSENT
    # confusion in its most expensive form — the guard stops before its remaining
    # arms run and the exit code says "failed" without naming a subject.
    referenced="$(grep -rhoE 'scripts/ci/[A-Za-z0-9._/-]+\.sh' .github/workflows/ 2>/dev/null | sort -u || true)"
    # Materialise the population ONCE into a variable. Writing this as
    # `gate_population | grep -qxF "$f"` would be the very shape this guard bans —
    # and exempting it with `# epipe-ok` would be the guard excusing itself. A
    # here-string has no pipeline, so no producer can be EPIPE'd.
    pop="$(gate_population)"
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        [[ -f "$f" ]] || continue
        if ! grep -qxF "$f" <<< "$pop"; then
            printf 'FAIL [EPIPE_POPULATION_DEPTH_EXCLUSION] %s is workflow-invoked but not in the scanned population\n' "$f"
            missing=$((missing + 1))
        fi
    done <<< "$referenced"
    DEPTH_ASSERT_FAILS="$missing"
}

# assert_product_population — the population correction is only worth what it can
# PROVE. Five closure properties, each of which, if it broke, would let the
# product plane silently shrink back toward the empty set it used to be.
assert_product_population() {
    local pop n bad=0 d f entry pipefail_entrypoints=0 entrypoint_gaps=0

    pop="$(product_population)"
    # `grep -c` prints 0 and EXITS 1 on zero matches. Left as the final command of
    # an `&&` list it takes errexit with it, and the guard dies here with no
    # attributable FAIL line — which is how an EMPTY population would have escaped
    # the very assertion written to catch it.
    n=0
    if [[ -n "$pop" ]]; then n="$(grep -c '' <<< "$pop")" || n=0; fi

    # A1 — NON-EMPTY. A gate that is green because its population is empty is not
    # a gate. This is the loud failure the previous three population corrections
    # each had to be discovered by hand instead of being told.
    if [[ "$n" -eq 0 ]]; then
        printf 'FAIL [EPIPE_PRODUCT_POPULATION_EMPTY] product_population() resolved to 0 files — the product execution plane is UNSCANNED\n'
        PRODUCT_ASSERT_FAILS=$((bad + 1))
        return 0
    fi

    # A2 — PACKAGING CLOSURE. Every tracked shell file in a subtree the %files
    # manifest ships must be in the population. A packaging change that adds a
    # directory, or a refactor that moves code into one, cannot slip past.
    while IFS= read -r d; do
        [[ -n "$d" ]] || continue
        [[ "$d" == "bin" ]] && continue
        [[ -d "cli/lib/nftban/$d" ]] || continue
        [[ "cli/lib/nftban/$d" == "$PRODUCT_EXCLUDED_DIR" ]] && continue
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            is_shell_file "$f" || continue
            if ! grep -qxF "$f" <<< "$pop"; then
                printf 'FAIL [EPIPE_PRODUCT_POPULATION_GAP] %s is shipped by %s but is not in the scanned population\n' "$f" "$PKG_MANIFEST"
                bad=$((bad + 1))
            fi
        done < <(git ls-files "cli/lib/nftban/$d/*" 2>/dev/null)
    done < <(packaged_lib_subdirs)

    # A3 — ENTRYPOINT CLOSURE. Every cli/sbin entrypoint is packaged (/usr/sbin
    # or /usr/lib/nftban/sbin) and must be scanned.
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        is_shell_file "$f" || continue
        if ! grep -qxF "$f" <<< "$pop"; then
            printf 'FAIL [EPIPE_PRODUCT_POPULATION_GAP] %s is a packaged entrypoint but is not in the scanned population\n' "$f"
            bad=$((bad + 1))
        fi
    done < <(git ls-files 'cli/sbin/*' 2>/dev/null)

    # A4 — EXECSTART CLOSURE. Anything a shipped unit starts is in the plane.
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        case "$f" in "$PRODUCT_EXCLUDED_DIR"/*) continue ;; esac
        is_shell_file "$f" || continue
        if ! grep -qxF "$f" <<< "$pop"; then
            printf 'FAIL [EPIPE_PRODUCT_POPULATION_GAP] %s is a systemd ExecStart target but is not in the scanned population\n' "$f"
            bad=$((bad + 1))
        fi
    done < <(execstart_sources)

    # A5 — THE DECLARED EXCLUSION MUST BE COVERED ELSEWHERE. cli/lib/nftban/tests
    # is left out of this plane only because test_corpus_population() owns it. If
    # that stops being true the exclusion becomes a hole, so prove it every run.
    entry="$(test_corpus_population)"
    if ! grep -qE "^$PRODUCT_EXCLUDED_DIR/" <<< "$entry"; then
        printf 'FAIL [EPIPE_EXCLUSION_UNCOVERED] %s is excluded from the product plane but no longer appears in the executed-test corpus — the exclusion is now a hole\n' "$PRODUCT_EXCLUDED_DIR"
        bad=$((bad + 1))
    fi

    # A6 — THE PIPEFAIL PREMISE. The product plane is scanned WITHOUT a per-file
    # `set -o pipefail` precondition, because 13 of its files are sourced
    # libraries that INHERIT pipefail from the entrypoint that sources them. That
    # premise rests on every cli/sbin entrypoint declaring it. Assert the premise
    # instead of relying on it; if an entrypoint ever drops pipefail the scan of
    # the libraries it owns becomes an overclaim, and this says so.
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        is_shell_file "$f" || continue
        pipefail_entrypoints=$((pipefail_entrypoints + 1))
        if ! declares_pipefail "$f"; then
            printf 'FAIL [EPIPE_PIPEFAIL_PREMISE] %s is a packaged entrypoint that does NOT declare pipefail — the inherited-pipefail premise no longer holds for the libraries it sources\n' "$f"
            entrypoint_gaps=$((entrypoint_gaps + 1))
            bad=$((bad + 1))
        fi
    done < <(git ls-files 'cli/sbin/*' 2>/dev/null)
    if [[ "$pipefail_entrypoints" -eq 0 ]]; then
        printf 'FAIL [EPIPE_PIPEFAIL_PREMISE] no packaged entrypoints found — the inherited-pipefail premise is unverifiable\n'
        bad=$((bad + 1))
    fi

    PRODUCT_ASSERT_FAILS="$bad"
}

# =============================================================================
# ARM 1 — DECLARED-EXPOSURE RATCHET over the gate plane AND the product plane
# =============================================================================
#
# 551 product sites cannot be wired as hard failures: that would block every
# change on inherited debt and would be scope expansion by another name (the
# reason the first correction stopped at the gate plane). The registry is how the
# debt becomes VISIBLE AND OWED instead of invisible. Three directions, because a
# one-directional ratchet rots:
#
#   detected but not declared        -> FAIL  new exposure introduced
#   declared but no longer detected  -> FAIL  silent drift; reconcile the registry
#                                             so a real fix is locked in and a
#                                             disappearance is never unexplained
#   declared, file no longer in the  -> FAIL  rotting row: nothing consumes it,
#   population at all                        so it can no longer constrain anything
#
# Identity is the whitespace-normalised line CONTENT, never the line number.
declare -A DETECTED=()
declare -A DETECTED_CONS=()
declare -A DETECTED_FILE_SEEN=()

scan_plane() {
    local plane="$1" require_pipefail="$2" f ln cons key fp line
    local -a LINES=()
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        [[ -f "$f" ]] || continue
        # Marked as seen BEFORE the pipefail precondition: if a file drops
        # pipefail its declared rows must read as STALE ("reconcile"), not as
        # ORPHAN ("nothing consumes this row") — the file is still in the plane.
        DETECTED_FILE_SEEN["$plane|$f"]=1
        if [[ "$require_pipefail" == "yes" ]]; then
            declares_pipefail "$f" || continue
        fi
        mapfile -t LINES < "$f" 2>/dev/null || continue
        while IFS=$'\t' read -r ln cons; do
            [[ -n "$ln" ]] || continue
            line="${LINES[$((ln - 1))]}"
            [[ -f "$ALLOW" ]] && grep -qxF "$f:$ln" "$ALLOW" 2>/dev/null && continue
            fp="$(epipe_fingerprint "$line")"
            key="$plane|$f|$fp"
            DETECTED["$key"]=$(( ${DETECTED["$key"]:-0} + 1 ))
            DETECTED_CONS["$key"]="$cons"
        done < <(detect_sites "$f")
    done < <("$3")
}

# Sourced by scripts/ci/gen-pipefail-epipe-inventory.sh with EPIPE_GUARD_LIB_ONLY=1
# so the generator and the gate share ONE detector and ONE set of populations. A
# duplicated matcher is exactly how a generated baseline drifts away from the gate
# that consumes it, and the drift is invisible until it is load-bearing. The
# dependency runs one way only: the gate is still standalone and needs nothing.
if [[ "${EPIPE_GUARD_LIB_ONLY:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

echo "== short-circuiting consumers downstream of a pipe, under pipefail =="

# The gate plane keeps the per-file pipefail precondition: each of those scripts
# is invoked directly by a workflow, so it IS its own entrypoint and pipefail is
# in effect only if it says so. The product plane does not, for the reason
# asserted in A6.
scan_plane gate yes gate_population
scan_plane product no product_population

declare -A REG_ROWS=()
registry_missing=0
if [[ ! -f "$REGISTRY" ]]; then
    printf 'FAIL [EPIPE_REGISTRY_MISSING] %s absent — cannot ratchet an undeclared population\n' "$REGISTRY"
    registry_missing=1
else
    while IFS=$'\t' read -r _plane _file _fp _n _cons _class _note; do
        [[ -z "$_plane" || "$_plane" == \#* ]] && continue
        REG_ROWS["$_plane|$_file|$_fp"]="$_n"
    done < "$REGISTRY"
fi

undeclared=0
registry_dev=0
if [[ "$registry_missing" -eq 0 ]]; then
    for key in "${!DETECTED[@]}"; do
        n="${DETECTED[$key]}"
        r="${REG_ROWS[$key]-}"
        if [[ -z "$r" ]]; then
            printf 'FAIL [EPIPE_UNDECLARED] %s (%s) — %d site(s), not declared in %s\n' \
                "${key//|/ }" "${DETECTED_CONS[$key]}" "$n" "$REGISTRY"
            undeclared=$((undeclared + 1))
        elif [[ "$n" -gt "$r" ]]; then
            printf 'FAIL [EPIPE_UNDECLARED] %s (%s) — %d site(s), registry declares %s\n' \
                "${key//|/ }" "${DETECTED_CONS[$key]}" "$n" "$r"
            undeclared=$((undeclared + 1))
        fi
    done
    for key in "${!REG_ROWS[@]}"; do
        r="${REG_ROWS[$key]}"
        n="${DETECTED[$key]:-0}"
        _plane="${key%%|*}"; _rest="${key#*|}"; _file="${_rest%|*}"
        if [[ -z "${DETECTED_FILE_SEEN["$_plane|$_file"]:-}" ]]; then
            printf 'FAIL [EPIPE_REGISTRY_ORPHAN] %s — declared on plane "%s" but that file is no longer in the scanned population; nothing consumes this row\n' \
                "$_file" "$_plane"
            registry_dev=$((registry_dev + 1))
        elif [[ "$n" -lt "$r" ]]; then
            printf 'FAIL [EPIPE_REGISTRY_STALE] %s — %d site(s) detected, registry declares %d; reconcile the registry so the change is recorded\n' \
                "$_file" "$n" "$r"
            registry_dev=$((registry_dev + 1))
        fi
    done
fi

[[ $((undeclared + registry_missing)) -eq 0 ]] && echo "  [OK] every short-circuiting pipeline in the gate and product planes is declared"
[[ $registry_dev -eq 0 ]] && echo "  [OK] no declared exposure disappeared or rotted without reconciliation"
printf 'PIPEFAIL_EPIPE_SHORT_CIRCUIT_SITES = %d\n' "$((undeclared + registry_missing))"
printf 'PIPEFAIL_EPIPE_REGISTRY_DEVIATIONS = %d\n' "$registry_dev"

fail=$((undeclared + registry_missing + registry_dev))

# =============================================================================
# ARM 2 — population assertions
# =============================================================================
echo "== population depth-exclusion assertion =="
DEPTH_ASSERT_FAILS=0
assert_no_depth_exclusion
depth_missing="$DEPTH_ASSERT_FAILS"
if [[ "$depth_missing" -eq 0 ]]; then
    echo "  [OK] every workflow-invoked scripts/ci script is in the scanned population (any depth)"
else
    echo "  $depth_missing workflow-invoked script(s) excluded by path depth"
fi
printf 'PIPEFAIL_EPIPE_DEPTH_EXCLUSIONS = %d\n' "$depth_missing"
fail=$((fail + depth_missing))

echo "== product population assertion =="
PRODUCT_ASSERT_FAILS=0
assert_product_population
product_bad="$PRODUCT_ASSERT_FAILS"
if [[ "$product_bad" -eq 0 ]]; then
    printf '  [OK] product execution plane scanned: %d file(s), packaging + ExecStart closure proven\n' \
        "$(product_population | grep -c '' || true)"
else
    echo "  $product_bad product-population assertion failure(s)"
fi
printf 'PIPEFAIL_EPIPE_PRODUCT_POPULATION_FAILURES = %d\n' "$product_bad"
fail=$((fail + product_bad))

# =============================================================================
# ARM 3 — executed-test corpus, bound to the recorded per-file inventory
# =============================================================================
#
# The test corpus stays on COUNTS rather than content-anchored rows, deliberately:
# 722 flagged lines across ~300 test files would make every test edit a registry
# edit, and a test's identity is not what is at stake there — its GROWTH is. The
# count ratchet already fails in both directions. The security-bearing sites the
# census classified are all in the product plane, which IS content-anchored.
count_sites() {
    local f="$1" n=0
    declares_pipefail "$f" || { printf '0'; return; }
    while IFS=$'\t' read -r _ln _cons; do
        [[ -n "$_ln" ]] || continue
        n=$((n + 1))
    done < <(detect_sites "$f")
    printf '%d' "$n"
}

echo "== executed-test corpus vs recorded inventory =="
corpus_fail=0
if [[ ! -f "$INVENTORY" ]]; then
    echo "FAIL [EPIPE_INVENTORY_MISSING] $INVENTORY absent — cannot ratchet an unmeasured population"
    corpus_fail=1
else
    declare -A RECORDED=()
    while IFS=$'\t' read -r _f _n; do
        [[ "$_f" == \#* || -z "$_f" ]] && continue
        RECORDED["$_f"]="$_n"
    done < "$INVENTORY"
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        n="$(count_sites "$f")"
        r="${RECORDED[$f]-}"
        if [[ -z "$r" ]]; then
            if [[ "$n" -gt 0 ]]; then
                printf 'FAIL [EPIPE_UNDECLARED] %s — %d timing-dependent site(s), not in the inventory\n' "$f" "$n"
                corpus_fail=$((corpus_fail + 1))
            fi
        elif [[ "$n" -gt "$r" ]]; then
            printf 'FAIL [EPIPE_NEW_DEBT] %s — %d site(s), inventory records %d\n' "$f" "$n" "$r"
            corpus_fail=$((corpus_fail + 1))
        elif [[ "$n" -lt "$r" ]]; then
            printf 'FAIL [EPIPE_INVENTORY_STALE] %s — %d site(s), inventory records %d; regenerate to lock the improvement in\n' "$f" "$n" "$r"
            corpus_fail=$((corpus_fail + 1))
        fi
    done < <(test_corpus_population)
    for f in "${!RECORDED[@]}"; do
        [[ -f "$f" ]] || { printf 'FAIL [EPIPE_INVENTORY_STALE] %s — recorded but no longer present; regenerate\n' "$f"; corpus_fail=$((corpus_fail + 1)); }
    done
fi
[[ $corpus_fail -eq 0 ]] && echo "  [OK] executed-test corpus matches the recorded inventory (no new timing-dependent assertions)"
printf 'PIPEFAIL_EPIPE_TEST_CORPUS_DEVIATIONS = %d\n' "$corpus_fail"

exit $(( (fail + corpus_fail) > 0 ? 1 : 0 ))
