#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# check-mode-authority.sh — static CI guard for the Runtime Mode Authority contract
# =============================================================================
#
# Authority:
#   docs/RUNTIME_MODE_AUTHORITY_CONTRACT.md
#   docs/MODE_ADMISSION_LEDGER.md
#   docs/adr/ADR-0001-runtime-mode-authority.md
#
# What this guard IS:
#   A static drift detector. It enforces the statically decidable subset of the
#   contract's "CI guards" section. Nothing here proves runtime operation.
#
# What this guard IS NOT:
#   Proof that a mode works. Static reachability is one of six promotion
#   requirements (see MODE_ADMISSION_LEDGER.md "Promotion requirements").
#   Anything this guard cannot decide is printed as NOT_YET_VERIFIED with the
#   exact command that WOULD settle it on a live host — never as PASS.
#
# Checks:
#   1 SILENT_NO_OP          Lesson G — `type -t F && F` used as a MODE DISPATCH
#                           branch, where a missing F yields rc0 / no-op.
#   2 ORPHAN_ENTRYPOINT     Lesson C — a mode-specific entrypoint with no caller.
#   3 LEDGER_CONSISTENCY    Ledger completeness + `BROKEN` must not be advertised.
#   4 MARKRUNNING_LIVENESS  Lesson B — MarkRunning() with a worker that can exit
#                           without any status transition. (approximation)
#
# Every check carries a NEGATIVE CONTROL (a synthetic bad tree that the check
# MUST flag) and, where cheap, a POSITIVE CONTROL (a synthetic clean tree that
# the check MUST NOT flag). A check whose negative control does not fire is
# reported NOT_YET_VERIFIED, never PASS — an unfalsifiable guard is not a guard
# (Lesson H).
#
# Known/accepted violations live in scripts/ci/mode-authority-known.txt, each
# row citing its ledger status and a disposition:
#   ACCEPTED_DEBT — tracked, does not block
#   MUST_FIX      — tracked and blocks under the default --fail-on all, because
#                   its ledger row is BROKEN and the contract's standing rule is
#                   an open obligation. Never downgraded to PASS.
# A row that stops reproducing is reported STALE and blocks, so this file cannot
# outlive the defect it records.
#
# Exit codes:  0 = clean   1 = NEW drift, stale allowlist, or (default) MUST_FIX
#              2 = guard fault / bad invocation
# =============================================================================

set -uo pipefail

# -----------------------------------------------------------------------------
# Locations
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
KNOWN_FILE="${SCRIPT_DIR}/mode-authority-known.txt"

RUN_CONTROLS=1
VERBOSE=0

POLICY="${POLICY:-all}"
SCOPE_RAW="${SCOPE_RAW:-}"
CHANGED_FILE="${CHANGED_FILE:-}"
# label used for BROKEN-row findings: a real FAIL under --fail-on all, known
# non-blocking debt under --fail-on drift.
MUSTFIX_LABEL="MUST_FIX"

usage() {
    cat <<'EOF'
Usage: check-mode-authority.sh [--root DIR] [--known FILE] [--no-controls] [-v]

  --root DIR      tree to analyse (default: repository root)
  --known FILE    allowlist of accepted violations
                  (default: scripts/ci/mode-authority-known.txt)
  --no-controls   skip the negative/positive controls (NOT for CI)
  --policy P      drift    : block NEW + STALE. Report MUST_FIX/ACCEPTED_DEBT.
                             CI may pass; admission stays blocked.
                  targeted : also block unresolved MUST_FIX rows INSIDE the
                             declared --scope. Unrelated debt is reported only.
                  all      : block ANY MUST_FIX, NEW or STALE. Global admission.
  --scope LIST    comma-separated modules the change DECLARES it closes
                  (ddos,portscan,loginmon). Required for --policy targeted.
  --changed-paths FILE
                  file of changed paths (one per line). Used to VERIFY that the
                  declared scope covers every mode-authority surface touched.
  --fail-on MODE  deprecated alias: drift|all -> --policy
  -v              print every violation line, including known ones
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)  REPO_ROOT="$(cd -- "$2" && pwd)"; shift 2 ;;
        --known) KNOWN_FILE="$2"; shift 2 ;;
        --no-controls) RUN_CONTROLS=0; shift ;;
        --fail-on)
            case "$2" in
                drift|all) POLICY="$2" ;;
                *) echo "--fail-on expects 'drift' or 'all'" >&2; exit 2 ;;
            esac
            shift 2 ;;
        --policy)
            case "$2" in
                drift|targeted|all) POLICY="$2" ;;
                *) echo "--policy expects drift|targeted|all" >&2; exit 2 ;;
            esac
            shift 2 ;;
        --scope)        SCOPE_RAW="$2"; shift 2 ;;
        --changed-paths) CHANGED_FILE="$2"; shift 2 ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# -----------------------------------------------------------------------------
# Contract constants
# -----------------------------------------------------------------------------
# The four user-facing mode values (ADR-0001 "Context").
MODES=(auto classic suricata hybrid)
# Modules that carry a mode and are tracked in the ledger.
LEDGER_MODULES=(ddos portscan loginmon)

# Mode-specific entrypoints. Format:
#   module|mode|function|defining-file|scope
# scope=external_file : shell libs are sourced units; the caller must live in a
#                       DIFFERENT file, otherwise the function is dead weight.
# scope=any_caller    : Go workers are called from their own package/file by
#                       design (Module.Start), so "outside its file" would be a
#                       false positive; any non-definition caller counts.
ENTRYPOINTS=(
  "portscan|classic|nftban_portscan_classic_run|cli/lib/nftban/core/nftban_portscan_classic.sh|external_file"
  "portscan|suricata|nftban_portscan_suricata_run|cli/lib/nftban/core/nftban_portscan_suricata.sh|external_file"
  "ddos|classic|nftban_ddos_classic_enable|cli/lib/nftban/core/nftban_ddos_classic.sh|external_file"
  "ddos|suricata|nftban_ddos_suricata_process|cli/lib/nftban/core/nftban_ddos_suricata.sh|external_file"
  "loginmon|classic|runJournalWatcher|internal/loginmon/module.go|any_caller"
  "loginmon|suricata|runEVEWatcher|internal/loginmon/module.go|any_caller"
)

# Surfaces that advertise mode values to a human operator. A `BROKEN` ledger row
# must not appear here without an explicit availability marker
# (RUNTIME_MODE_AUTHORITY_CONTRACT.md, "Standing rule for BROKEN").
declare -A HELP_SURFACES=(
  [ddos]="cli/lib/nftban/cli/cmd_ddos.sh cli/lib/nftban/core/nftban_ddos.sh"
  [portscan]="cli/lib/nftban/cli/cmd_portscan.sh cli/lib/nftban/core/nftban_portscan.sh"
  [loginmon]="cli/lib/nftban/cli/cmd_login.sh cli/lib/nftban/core/nftban_login_suricata.sh"
)
SHARED_HELP_SURFACES="cli/lib/nftban/cli/cmd_modes.sh cli/lib/nftban/helpers/nftban_mode.sh install/bash-completion/nftban"
# Words that make a mode listing honest rather than an advertisement.
AVAILABILITY_MARKERS='unavailable|broken|BROKEN|experimental|EXPERIMENTAL|not supported|disabled'

LEDGER_REL="docs/MODE_ADMISSION_LEDGER.md"

# -----------------------------------------------------------------------------
# Bookkeeping
# -----------------------------------------------------------------------------
TMPDIR_GUARD="$(mktemp -d "${TMPDIR:-/tmp}/mode-authority.XXXXXX")" || exit 2
cleanup() { rm -rf "${TMPDIR_GUARD}"; }
trap cleanup EXIT

declare -A KNOWN_KEYS=()
declare -A KNOWN_DISP=()
declare -A KNOWN_STATUS=()
declare -A KNOWN_HIT=()

NEW_TOTAL=0
KNOWN_TOTAL=0
MUSTFIX_TOTAL=0
MUSTFIX_IN_SCOPE=0
SCOPE_VALIDATION=PASS
NYV_TOTAL=0
IN_CONTROL=0
declare -A CHECK_NEW=()
declare -A CHECK_KNOWN=()
declare -A CHECK_MUSTFIX=()
declare -A CHECK_CONTROL=()   # PASS | FAIL | SKIPPED

say()  { printf '%s\n' "$*"; }
head2() { printf '\n== %s\n' "$*"; }

# Allowlist row format (TAB separated):
#   KEY <TAB> DISPOSITION <TAB> LEDGER_STATUS <TAB> NOTE
# DISPOSITION:
#   ACCEPTED_DEBT — recorded, tracked, does NOT fail the build. Use only where
#                   the ledger status is not BROKEN.
#   MUST_FIX      — recorded and STILL FAILS the build. Used for rows the ledger
#                   itself marks BROKEN: the contract's standing rule ("a BROKEN
#                   mode must be hidden, rejected at validation, or explicitly
#                   marked unavailable — never silently selectable") is an open
#                   obligation, not accepted debt. Hiding it in an allowlist
#                   would be exactly the failure this contract exists to stop.
load_known() {
    [[ -f "${KNOWN_FILE}" ]] || return 0
    local line key disp status
    while IFS= read -r line; do
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "${line}" == \#* ]] && continue
        key="${line%%$'\t'*}"
        disp="${line#*$'\t'}";   disp="${disp%%$'\t'*}"
        status="${line#*$'\t'}"; status="${status#*$'\t'}"; status="${status%%$'\t'*}"
        KNOWN_KEYS["${key}"]=1
        KNOWN_DISP["${key}"]="${disp}"
        KNOWN_STATUS["${key}"]="${status}"
    done < "${KNOWN_FILE}"
}

# record CHECK KEY DETAIL — classifies against the allowlist and counts.
record() {
    local check="$1" key="$2" detail="$3"
    # During controls the allowlist is ignored: a control must prove the check
    # itself fires, not that the allowlist happens to name the fixture.
    if [[ ${IN_CONTROL} -eq 1 || -z "${KNOWN_KEYS[${key}]:-}" ]]; then
        CHECK_NEW["${check}"]=$(( ${CHECK_NEW[${check}]:-0} + 1 ))
        NEW_TOTAL=$(( NEW_TOTAL + 1 ))
        say "  NEW VIOLATION  ${key}"
        say "                 ${detail}"
        return
    fi
    KNOWN_HIT["${key}"]=1
    if [[ "${KNOWN_DISP[${key}]}" == "MUST_FIX" ]]; then
        CHECK_MUSTFIX["${check}"]=$(( ${CHECK_MUSTFIX[${check}]:-0} + 1 ))
        MUSTFIX_TOTAL=$(( MUSTFIX_TOTAL + 1 ))
        if [[ "${POLICY}" == "targeted" ]] && in_scope "${key}"; then
            MUSTFIX_IN_SCOPE=$(( MUSTFIX_IN_SCOPE + 1 ))
        fi
        say "  ${MUSTFIX_LABEL}       ${key}"
        say "                 ledger=${KNOWN_STATUS[${key}]} — ${detail}"
        return
    fi
    CHECK_KNOWN["${check}"]=$(( ${CHECK_KNOWN[${check}]:-0} + 1 ))
    KNOWN_TOTAL=$(( KNOWN_TOTAL + 1 ))
    if [[ ${VERBOSE} -eq 1 ]]; then
        say "  KNOWN          ${key}"
        say "                 ledger=${KNOWN_STATUS[${key}]} — ${detail}"
    fi
}

not_yet_verified() {
    local what="$1" cmd="$2"
    NYV_TOTAL=$(( NYV_TOTAL + 1 ))
    say "  NOT_YET_VERIFIED  ${what}"
    say "                    settle with: ${cmd}"
}

# =============================================================================
# CHECK 1 — SILENT_NO_OP  (Lesson G)
# =============================================================================
# Scoping, stated so a reader can judge false positives:
#
#   `type -t F && F` is legitimate in plenty of places (optional helpers,
#   logging shims, availability probes). It is a DEFECT only when it guards the
#   branch that implements a selected mode, because then a missing F is
#   indistinguishable from a successful detection cycle.
#
#   A construct is therefore flagged only when ALL FOUR hold:
#     (a) it sits inside a function whose body contains a `case` with >= 2 of
#         the labels auto|classic|suricata|hybrid  -> a MODE DISPATCH function;
#     (b) the guarded name matches a mode entrypoint shape
#         ^nftban_(portscan|ddos|login|loginmon)_(classic|suricata)_ ;
#     (c) the guarded name is invoked as a BARE COMMAND inside the block
#         (so `echo "$(fn_get_status)"` inside a branch is not flagged);
#     (d) the guard has no `else`/`elif` arm at all, i.e. a missing F falls
#         through with rc0.
#
#   A guard WITH an else arm is not flagged even if the arm is weak — deciding
#   whether an else arm truly fails is left to review, and is listed under
#   NOT_YET_VERIFIED below.
#
#   Function extent heuristic: `name() {` at column 0 to the next `}` at column
#   0. This is the repo's uniform style; a file that departs from it would be
#   under-scanned, not falsely flagged.
# -----------------------------------------------------------------------------
scan_silent_no_op() {
    local root="$1" out="$2"
    : > "${out}"
    local f
    while IFS= read -r f; do
        awk -v FNAME="${f#"${root}"/}" '
        function is_mode_label(s) {
            return (s ~ /^[[:space:]]*(auto|classic|suricata|hybrid)(\|(auto|classic|suricata|hybrid))*\)[[:space:]]*$/)
        }
        { L[NR] = $0 }
        END {
            n = NR
            for (i = 1; i <= n; i++) {
                if (L[i] !~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{[[:space:]]*$/) continue
                fname = L[i]; sub(/\(\).*/, "", fname)
                e = 0
                for (j = i + 1; j <= n; j++) if (L[j] ~ /^\}[[:space:]]*$/) { e = j; break }
                if (e == 0) continue

                # (a) is this a mode dispatch function?
                delete seen; cnt = 0
                for (k = i; k <= e; k++) {
                    if (!is_mode_label(L[k])) continue
                    lbl = L[k]; gsub(/[[:space:]]|\)/, "", lbl)
                    if (!(lbl in seen)) { seen[lbl] = 1; cnt++ }
                }
                if (cnt < 2) { i = e; continue }

                for (k = i; k <= e; k++) {
                    line = L[k]
                    if (!match(line, /(type -t|declare -F)[[:space:]]+[A-Za-z0-9_]+/)) continue
                    g = substr(line, RSTART, RLENGTH)
                    sub(/^(type -t|declare -F)[[:space:]]+/, "", g)
                    # (b) mode entrypoint shape
                    if (g !~ /^nftban_(portscan|ddos|login|loginmon)_(classic|suricata)_/) continue

                    if (line !~ /^[[:space:]]*if[[:space:]]/) {
                        # bare `type -t F ... && F` — the canonical Lesson G form
                        if (line ~ /&&/)
                            printf "%s\t%d\t%s\t%s\t%s\n", FNAME, k, fname, g, "ANDAND"
                        continue
                    }
                    # if-guard: locate the matching fi, note any else/elif at depth 1
                    depth = 1; hasElse = 0; fi = 0
                    for (m = k + 1; m <= e; m++) {
                        if (L[m] ~ /^[[:space:]]*if[[:space:]]/) depth++
                        else if (L[m] ~ /^[[:space:]]*fi[[:space:]]*$/) {
                            depth--
                            if (depth == 0) { fi = m; break }
                        } else if (depth == 1 && L[m] ~ /^[[:space:]]*(else|elif)([[:space:]]|$)/) hasElse = 1
                    }
                    if (fi == 0) continue
                    # (c) bare invocation inside the guarded block
                    bare = 0
                    for (m = k + 1; m < fi; m++)
                        if (L[m] ~ ("^[[:space:]]*" g "([[:space:]]*$|[[:space:]]|;|\\||&)")) bare = 1
                    if (!bare) continue
                    # (d) no else arm at all
                    if (!hasElse)
                        printf "%s\t%d\t%s\t%s\t%s\n", FNAME, k, fname, g, "IF_NO_ELSE"
                }
                i = e
            }
        }' "${f}" >> "${out}"
    done < <(find "${root}/cli" "${root}/install" -name '*.sh' -type f 2>/dev/null | sort)
}

check_silent_no_op() {
    local root="$1" raw="${TMPDIR_GUARD}/sno.$$.tsv"
    scan_silent_no_op "${root}" "${raw}"
    # collapse to one key per (file, dispatcher, guarded fn); keep all line numbers
    local key file line disp fn kind lines
    while IFS= read -r key; do
        file="${key%%|*}"; local rest="${key#*|}"
        disp="${rest%%|*}"; fn="${rest#*|}"
        lines="$(awk -F'\t' -v f="${file}" -v d="${disp}" -v g="${fn}" \
                  '$1==f && $3==d && $4==g {printf "%s%s", (c++?",":""), $2}' "${raw}")"
        kind="$(awk -F'\t' -v f="${file}" -v d="${disp}" -v g="${fn}" \
                  '$1==f && $3==d && $4==g {print $5; exit}' "${raw}")"
        record SILENT_NO_OP "SILENT_NO_OP|${file}|${disp}|${fn}" \
               "${file}:${lines} dispatcher=${disp}() guarded=${fn} form=${kind} (missing fn => rc0 no-op)"
    done < <(awk -F'\t' '{print $1"|"$3"|"$4}' "${raw}" | sort -u)
    # keep unused-var warnings quiet and the parse honest
    : "${line:-}"
}

# =============================================================================
# CHECK 2 — ORPHAN_ENTRYPOINT  (Lesson C)
# =============================================================================
# Caller corpus exclusions, stated so a reader can judge:
#   - the defining file itself (a self-call is not reachability)
#   - `export -f` lines (Lesson C: export is not a caller)
#   - comment lines
#   - this guard script and its allowlist (they name the functions as data)
#   - tests/ and *_test.sh / *_test.go — the contract is explicit that "a
#     synthetic direct call to a private helper does not promote a row", so a
#     test caller does not count as production reachability.
# -----------------------------------------------------------------------------
orphan_callers() {
    local root="$1" fn="$2" defpath="$3" scope="$4"
    if [[ "${scope}" == "external_file" ]]; then
        grep -rnE "(^|[^A-Za-z0-9_])${fn}([^A-Za-z0-9_]|$)" \
             --include='*.sh' "${root}/cli" "${root}/install" "${root}/scripts" 2>/dev/null \
          | grep -v "^${defpath}:" \
          | grep -vE '^[^:]*:[0-9]+:[[:space:]]*#' \
          | grep -v 'export -f' \
          | grep -vE '(^|/)(tests?)/|_test\.sh:' \
          | grep -v 'check-mode-authority\.sh:' \
          | grep -v 'mode-authority-known' || true
    else
        grep -rnE "(^|[^A-Za-z0-9_.])(m|g|s)?\.?${fn}\(" \
             --include='*.go' "$(dirname "${defpath}")" 2>/dev/null \
          | grep -vE "func[[:space:]]*\([^)]*\)[[:space:]]*${fn}\(" \
          | grep -vE '^[^:]*:[0-9]+:[[:space:]]*//' \
          | grep -v '_test\.go:' || true
    fi
}

check_orphan_entrypoint() {
    local root="$1" row module mode fn deffile scope callers defpath
    for row in "${ENTRYPOINTS[@]}"; do
        IFS='|' read -r module mode fn deffile scope <<< "${row}"
        defpath="${root}/${deffile}"
        if [[ ! -f "${defpath}" ]]; then
            say "  SKIP   ${module}/${mode} ${fn} — defining file absent: ${deffile}"
            continue
        fi
        callers="$(orphan_callers "${root}" "${fn}" "${defpath}" "${scope}")"
        if [[ -z "${callers}" ]]; then
            record ORPHAN_ENTRYPOINT "ORPHAN_ENTRYPOINT|${module}|${mode}|${fn}" \
                   "defined ${deffile} — zero callers (scope=${scope}; definition and 'export -f' excluded). Mode name resolves to nothing."
        else
            say "  ok     ${module}/${mode} ${fn} — $(printf '%s\n' "${callers}" | wc -l) caller line(s), scope=${scope}"
        fi
    done
}

# =============================================================================
# CHECK 3 — LEDGER_CONSISTENCY
# =============================================================================
check_ledger() {
    local root="$1"
    local ledger="${root}/${LEDGER_REL}"
    if [[ ! -f "${ledger}" ]]; then
        record LEDGER_CONSISTENCY "LEDGER_CONSISTENCY|missing|ledger|${LEDGER_REL}" \
               "ledger file not found — the contract requires one row per module x mode"
        return
    fi
    local rows="${TMPDIR_GUARD}/ledger.$$.tsv"
    awk -F'|' '
        NF >= 5 && $2 ~ /[A-Za-z]/ {
            m = $2; md = $3; st = $4
            gsub(/[[:space:]`*]/, "", m); gsub(/[[:space:]`*]/, "", md)
            m = tolower(m); md = tolower(md)
            if (md !~ /^(auto|classic|suricata|hybrid)$/) next
            broken = (st ~ /BROKEN/) ? "BROKEN" : "OK"
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", st)
            printf "%s\t%s\t%s\t%s\n", m, md, broken, st
        }' "${ledger}" > "${rows}"

    # 3a — completeness: every module x mode must have a row
    local module mode
    for module in "${LEDGER_MODULES[@]}"; do
        for mode in "${MODES[@]}"; do
            if ! awk -F'\t' -v m="${module}" -v d="${mode}" \
                 'tolower($1)==m && $2==d {found=1} END{exit !found}' "${rows}"; then
                record LEDGER_CONSISTENCY "LEDGER_MISSING_ROW|${module}|${mode}|-" \
                       "${LEDGER_REL} has no row for ${module} x ${mode} — undeclared mode (contract: 'Absence from this ledger means unassessed, not healthy')"
            fi
        done
    done

    # 3b — a BROKEN mode must not be advertised without an availability marker
    local brk surfaces s hits
    while IFS=$'\t' read -r module mode brk _st; do
        [[ "${brk}" == "BROKEN" ]] || continue
        surfaces="${HELP_SURFACES[${module}]:-} ${SHARED_HELP_SURFACES}"
        for s in ${surfaces}; do
            [[ -f "${root}/${s}" ]] || continue
            # A line "advertises the mode vocabulary" when it names >= 2 distinct
            # mode values on one line (covers `auto|classic|suricata|hybrid`,
            # `auto, classic, suricata, hybrid`, and compgen word lists) AND names
            # this mode. Pure comment lines are excluded; so are lines already
            # carrying an availability marker.
            hits="$(awk -v md="${mode}" -v markers="${AVAILABILITY_MARKERS}" '
                /^[[:space:]]*#/ { next }
                {
                    c = 0
                    if ($0 ~ /(^|[^a-z])auto([^a-z]|$)/)     c++
                    if ($0 ~ /(^|[^a-z])classic([^a-z]|$)/)  c++
                    if ($0 ~ /(^|[^a-z])suricata([^a-z]|$)/) c++
                    if ($0 ~ /(^|[^a-z])hybrid([^a-z]|$)/)   c++
                    if (c < 2) next
                    if ($0 !~ ("(^|[^a-z])" md "([^a-z]|$)")) next
                    if ($0 ~ markers) next
                    print NR ":" $0
                }' "${root}/${s}" 2>/dev/null || true)"
            [[ -z "${hits}" ]] && continue
            record LEDGER_CONSISTENCY "LEDGER_BROKEN_ADVERTISED|${module}|${mode}|${s}" \
                   "ledger says ${module}/${mode}=BROKEN but ${s} advertises the mode list with no availability marker at line(s): $(printf '%s\n' "${hits}" | cut -d: -f1 | paste -sd, -)"
        done
    done < "${rows}"

    # 3c — statuses this guard cannot decide
    not_yet_verified "ledger rows above STATICALLY_REACHABLE (FIXTURE_PROVEN / TRAFFIC_PROVEN / SUSTAINED) cannot be confirmed statically" \
        "on a live target: nftban portscan mode set suricata && nftban portscan check && nft list set ip nftban portscan_offenders"
}

# =============================================================================
# CHECK 4 — MARKRUNNING_LIVENESS  (Lesson B)  — APPROXIMATION
# =============================================================================
# This is explicitly a static approximation. It cannot observe a goroutine.
# What it does decide:
#   for every function containing `MarkRunning()`, take every `go <recv>.<w>(`
#   launched in that same function; resolve <w> in the same package; and flag
#   <w> when its body contains a `return` that is NOT the ctx.Done() shutdown
#   path AND the body contains no status transition
#   (MarkStopped|MarkDegraded|MarkFailed|MarkNotRunning).
# Meaning of a hit: "this worker has an exit path after which module status can
# still read RUNNING". It does not prove the path is taken at runtime.
# -----------------------------------------------------------------------------
check_markrunning() {
    local root="$1" f
    local found=0
    while IFS= read -r f; do
        [[ "${f}" == *_test.go ]] && continue
        local pkgdir; pkgdir="$(dirname "${f}")"
        local rel="${f#"${root}"/}"
        local starters; starters="$(awk '
            /^func /{ fn=$0; sub(/^func +(\([^)]*\) *)?/, "", fn); sub(/\(.*/, "", fn); start=NR; body="" ; inb=1 }
            inb { buf[NR]=$0 }
            /^}/ && inb { for (i=start;i<=NR;i++) body = body buf[i] "\n"
                          if (body ~ /MarkRunning\(\)/) {
                              nlines = split(body, arr, "\n")
                              for (i=1;i<=nlines;i++)
                                  if (arr[i] ~ /^[[:space:]]*go [A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*\(/) {
                                      w = arr[i]; sub(/^[[:space:]]*go [A-Za-z_][A-Za-z0-9_]*\./, "", w); sub(/\(.*/, "", w)
                                      print fn "\t" w
                                  }
                          }
                          inb=0; delete buf }
        ' "${f}" | sort -u)"
        [[ -z "${starters}" ]] && continue
        local startfn worker wbody
        while IFS=$'\t' read -r startfn worker; do
            [[ -z "${worker}" ]] && continue
            found=1
            wbody="$(awk -v W="${worker}" '
                $0 ~ ("^func +(\\([^)]*\\) *)?" W "\\(") { inb=1 }
                inb { print }
                inb && /^}/ { inb=0 }
            ' "${pkgdir}"/*.go 2>/dev/null)"
            if [[ -z "${wbody}" ]]; then
                not_yet_verified "worker ${worker} launched from ${rel}:${startfn} not resolvable in package $(basename "${pkgdir}")" \
                    "grep -rn 'func.*${worker}(' ${pkgdir}"
                continue
            fi
            if printf '%s' "${wbody}" | grep -qE 'Mark(Stopped|Degraded|Failed|NotRunning)\('; then
                say "  ok     ${rel}:${startfn}() -> ${worker}() has a status transition"
                continue
            fi
            # a `return` that is not the ctx.Done() shutdown path
            local risky
            risky="$(printf '%s\n' "${wbody}" | awk '
                /ctx\.Done\(\)|<-ctx\.Done/ { guard = NR }
                /^[[:space:]]*return[[:space:]]*$|^[[:space:]]*return [^ ]/ {
                    if (guard == "" || NR - guard > 4) print NR
                }')"
            if [[ -n "${risky}" ]]; then
                record MARKRUNNING_LIVENESS "MARKRUNNING_LIVENESS|${rel}|${startfn}|${worker}" \
                       "${startfn}() calls MarkRunning() then 'go ...${worker}()'; ${worker}() returns on a non-ctx.Done path with no Mark{Stopped,Degraded,Failed} — status can stay RUNNING with a dead worker (STATIC APPROXIMATION)"
            else
                say "  ok     ${rel}:${startfn}() -> ${worker}() has no non-shutdown early return"
            fi
        done <<< "${starters}"
    done < <(find "${root}/internal" "${root}/cmd" -name '*.go' -type f 2>/dev/null | sort)
    if [[ ${found} -eq 0 ]]; then
        not_yet_verified "no MarkRunning()+goroutine pair found under internal/ or cmd/ — check did not exercise" \
            "grep -rn 'MarkRunning()' --include='*.go' ${root}"
    fi
    not_yet_verified "whether a flagged worker's exit path is actually reached, and whether health reports it, is a RUNTIME question" \
        "on a live target: systemctl stop suricata && rm -f /var/log/suricata/eve.json && systemctl restart nftban && nftban login status --json | jq '.running,.healthy'"
}

# =============================================================================
# CONTROLS — every check must be seen to fail (Lesson H)
# =============================================================================
# Each control builds a synthetic tree under a temp dir and asserts the SCANNER
# behaves. Controls call the scanners directly (not `record`), so the counters
# of the real run are untouched.

ctl_pass() { CHECK_CONTROL["$1"]=PASS; say "  control  $1: NEGATIVE CONTROL FIRED (+ positive control clean) -> check is falsifiable"; }
ctl_fail() { CHECK_CONTROL["$1"]=FAIL; say "  control  $1: NEGATIVE CONTROL DID NOT FIRE -> check reported NOT_YET_VERIFIED, not PASS"; }

control_silent_no_op() {
    local bad="${TMPDIR_GUARD}/nc1/bad" good="${TMPDIR_GUARD}/nc1/good"
    mkdir -p "${bad}/cli" "${bad}/install" "${good}/cli" "${good}/install"
    cat > "${bad}/cli/dispatch.sh" <<'EOF'
#!/usr/bin/env bash
nftban_fixture_run() {
    case "$mode" in
        classic)
            if type -t nftban_portscan_classic_run &>/dev/null; then
                nftban_portscan_classic_run
            fi
            ;;
        suricata)
            type -t nftban_portscan_suricata_run &>/dev/null && nftban_portscan_suricata_run
            ;;
    esac
    return 0
}
EOF
    # good tree: same dispatcher, but a missing entrypoint FAILS (contract-compliant)
    cat > "${good}/cli/dispatch.sh" <<'EOF'
#!/usr/bin/env bash
nftban_fixture_run() {
    case "$mode" in
        classic)
            if type -t nftban_portscan_classic_run &>/dev/null; then
                nftban_portscan_classic_run
            else
                echo "FAILED: classic entrypoint missing" >&2
                return 1
            fi
            ;;
        suricata)
            if type -t nftban_portscan_suricata_run &>/dev/null; then
                nftban_portscan_suricata_run
            else
                return 1
            fi
            ;;
    esac
}
# non-dispatch context: legitimate optional helper, must NOT be flagged
nftban_fixture_helper() {
    if type -t nftban_portscan_classic_render &>/dev/null; then
        nftban_portscan_classic_render
    fi
}
EOF
    local rb="${TMPDIR_GUARD}/nc1.bad.tsv" rg="${TMPDIR_GUARD}/nc1.good.tsv"
    scan_silent_no_op "${bad}" "${rb}"
    scan_silent_no_op "${good}" "${rg}"
    local nb ng
    nb="$(wc -l < "${rb}")"; ng="$(wc -l < "${rg}")"
    say "  control  SILENT_NO_OP: bad-tree hits=${nb} (expect >=2), clean-tree hits=${ng} (expect 0)"
    if [[ "${nb}" -ge 2 && "${ng}" -eq 0 ]]; then ctl_pass SILENT_NO_OP; else ctl_fail SILENT_NO_OP; fi
}

control_orphan_entrypoint() {
    local bad="${TMPDIR_GUARD}/nc2/bad" good="${TMPDIR_GUARD}/nc2/good" d
    for d in "${bad}" "${good}"; do
        mkdir -p "${d}/cli/lib/nftban/core" "${d}/install" "${d}/scripts"
        cat > "${d}/cli/lib/nftban/core/nftban_portscan_classic.sh" <<'EOF'
#!/usr/bin/env bash
nftban_portscan_classic_run() { return 0; }
export -f nftban_portscan_classic_run
EOF
    done
    cat > "${good}/cli/lib/nftban/core/nftban_portscan.sh" <<'EOF'
#!/usr/bin/env bash
nftban_portscan_run() { nftban_portscan_classic_run; }
EOF
    local nb ng
    nb="$(CHECK_ORPHAN_PROBE=1 probe_orphan "${bad}")"
    ng="$(CHECK_ORPHAN_PROBE=1 probe_orphan "${good}")"
    say "  control  ORPHAN_ENTRYPOINT: no-caller tree flagged=${nb} (expect 1), with-caller tree flagged=${ng} (expect 0)"
    if [[ "${nb}" -eq 1 && "${ng}" -eq 0 ]]; then ctl_pass ORPHAN_ENTRYPOINT; else ctl_fail ORPHAN_ENTRYPOINT; fi
}

# probe_orphan ROOT — returns how many of the ENTRYPOINTS rows PRESENT in ROOT are orphaned.
probe_orphan() {
    local root="$1" row module mode fn deffile scope defpath callers n=0
    for row in "${ENTRYPOINTS[@]}"; do
        IFS='|' read -r module mode fn deffile scope <<< "${row}"
        defpath="${root}/${deffile}"
        [[ -f "${defpath}" ]] || continue
        callers="$(orphan_callers "${root}" "${fn}" "${defpath}" "${scope}")"
        [[ -z "${callers}" ]] && n=$(( n + 1 ))
    done
    printf '%s' "${n}"
}

control_ledger() {
    local bad="${TMPDIR_GUARD}/nc3/bad"
    mkdir -p "${bad}/docs" "${bad}/cli/lib/nftban/cli"
    cat > "${bad}/${LEDGER_REL}" <<'EOF'
| Module | Mode | Status | Evidence |
|---|---|---|---|
| DDoS | classic | `DECLARED` | fixture |
| DDoS | suricata | **`BROKEN`** | fixture |
EOF
    cat > "${bad}/cli/lib/nftban/cli/cmd_ddos.sh" <<'EOF'
echo "    mode   Show or set protection mode (auto|classic|suricata|hybrid)"
EOF
    local before_new=${NEW_TOTAL} before_nyv=${NYV_TOTAL} hits
    local before_mf=${MUSTFIX_TOTAL} before_k=${KNOWN_TOTAL}
    check_ledger "${bad}" > "${TMPDIR_GUARD}/nc3.out" 2>&1
    hits=$(( NEW_TOTAL - before_new ))
    NEW_TOTAL=${before_new}; NYV_TOTAL=${before_nyv}
    MUSTFIX_TOTAL=${before_mf}; KNOWN_TOTAL=${before_k}
    CHECK_NEW[LEDGER_CONSISTENCY]=0
    CHECK_MUSTFIX[LEDGER_CONSISTENCY]=0
    CHECK_KNOWN[LEDGER_CONSISTENCY]=0
    local missing advertised
    missing="$(grep -c 'LEDGER_MISSING_ROW' "${TMPDIR_GUARD}/nc3.out" || true)"
    advertised="$(grep -c 'LEDGER_BROKEN_ADVERTISED' "${TMPDIR_GUARD}/nc3.out" || true)"
    say "  control  LEDGER_CONSISTENCY: fixture flagged total=${hits} (missing-row=${missing}, broken-advertised=${advertised}); expect missing-row>=10 and broken-advertised>=1"
    if [[ "${missing}" -ge 10 && "${advertised}" -ge 1 ]]; then ctl_pass LEDGER_CONSISTENCY; else ctl_fail LEDGER_CONSISTENCY; fi
}

control_markrunning() {
    local bad="${TMPDIR_GUARD}/nc4/bad" good="${TMPDIR_GUARD}/nc4/good"
    mkdir -p "${bad}/internal/fixture" "${good}/internal/fixture"
    cat > "${bad}/internal/fixture/mod.go" <<'EOF'
package fixture

func (m *Module) Start(ctx context.Context) error {
	m.status.MarkRunning()
	go m.runEVEWatcherFixture(ctx)
	return nil
}

func (m *Module) runEVEWatcherFixture(ctx context.Context) {
	f, err := os.Open("/var/log/suricata/eve.json")
	if err != nil {
		m.status.RecordError(err)
		return
	}
	_ = f
	for {
		select {
		case <-ctx.Done():
			return
		}
	}
}
EOF
    cat > "${good}/internal/fixture/mod.go" <<'EOF'
package fixture

func (m *Module) Start(ctx context.Context) error {
	m.status.MarkRunning()
	go m.runEVEWatcherFixture(ctx)
	return nil
}

func (m *Module) runEVEWatcherFixture(ctx context.Context) {
	f, err := os.Open("/var/log/suricata/eve.json")
	if err != nil {
		m.status.RecordError(err)
		m.status.MarkStopped()
		return
	}
	_ = f
	for {
		select {
		case <-ctx.Done():
			return
		}
	}
}
EOF
    local before_new=${NEW_TOTAL} before_nyv=${NYV_TOTAL} nb ng
    local before_mf=${MUSTFIX_TOTAL} before_k=${KNOWN_TOTAL}
    check_markrunning "${bad}" > "${TMPDIR_GUARD}/nc4.bad.out" 2>&1
    nb=$(( NEW_TOTAL - before_new )); NEW_TOTAL=${before_new}; NYV_TOTAL=${before_nyv}
    check_markrunning "${good}" > "${TMPDIR_GUARD}/nc4.good.out" 2>&1
    ng=$(( NEW_TOTAL - before_new )); NEW_TOTAL=${before_new}; NYV_TOTAL=${before_nyv}
    MUSTFIX_TOTAL=${before_mf}; KNOWN_TOTAL=${before_k}
    CHECK_NEW[MARKRUNNING_LIVENESS]=0
    CHECK_MUSTFIX[MARKRUNNING_LIVENESS]=0
    CHECK_KNOWN[MARKRUNNING_LIVENESS]=0
    say "  control  MARKRUNNING_LIVENESS: no-transition fixture flagged=${nb} (expect 1), MarkStopped fixture flagged=${ng} (expect 0)"
    if [[ "${nb}" -eq 1 && "${ng}" -eq 0 ]]; then ctl_pass MARKRUNNING_LIVENESS; else ctl_fail MARKRUNNING_LIVENESS; fi
}

# =============================================================================
# MAIN
# =============================================================================
load_known

say "NFTBan mode-authority static guard"
say "  root         : ${REPO_ROOT}"
say "  allowlist    : ${KNOWN_FILE} ($(( ${#KNOWN_KEYS[@]} )) accepted row(s))"
say "  authority    : docs/RUNTIME_MODE_AUTHORITY_CONTRACT.md, docs/MODE_ADMISSION_LEDGER.md, docs/adr/ADR-0001-runtime-mode-authority.md"
say "  scope note   : static only. Static reachability is 1 of the 6 promotion"
say "                 requirements in MODE_ADMISSION_LEDGER.md. A clean run of this"
say "                 guard never promotes a ledger row."

FAIL_ON="${POLICY}"
[[ "${POLICY}" != "all" ]] && MUSTFIX_LABEL="KNOWN_MUST_FIX"

# --- scope model -------------------------------------------------------------
# A MUST_FIX key carries its module either in field 2 (ORPHAN_ENTRYPOINT,
# LEDGER_BROKEN_ADVERTISED) or inside a path (MARKRUNNING_LIVENESS).
key_module() { # key -> ddos|portscan|loginmon|unknown
    local k="$1" f2
    f2="$(cut -d"|" -f2 <<<"${k}")"
    case "${f2}" in
        ddos|portscan|loginmon) printf "%s" "${f2}"; return ;;
    esac
    case "${k}" in
        *ddos*)              printf "ddos" ;;
        *portscan*)          printf "portscan" ;;
        *loginmon*|*login*)  printf "loginmon" ;;
        *)                   printf "unknown" ;;
    esac
}
# a changed path -> the module authority surface(s) it touches
path_modules() { # path -> zero or more modules, one per line
    local p="$1"
    case "${p}" in
        internal/ddos/*|*nftban_ddos*|*cmd_ddos*)             echo ddos ;;
        internal/portscan/*|*nftban_portscan*|*cmd_portscan*) echo portscan ;;
        internal/loginmon/*|*nftban_login*|*cmd_login*)       echo loginmon ;;
        # SHARED mode surfaces: a change here touches every module that
        # currently carries a MUST_FIX row referencing the file. Declaring one
        # module while editing shared authority code must not pass.
        *helpers/nftban_mode.sh|*cmd_modes.sh)
            grep -oE "^[A-Z_]+\|(ddos|portscan|loginmon)\|" "${KNOWN_FILE}" 2>/dev/null \
                | cut -d"|" -f2 | sort -u ;;
    esac
}
declare -A SCOPE_SET=()
if [[ -n "${SCOPE_RAW}" ]]; then
    # Explicit bounded parser. No global or persistent IFS mutation (repository
    # security policy flags IFS-based input splitting), no `|| true` concealing a
    # pipeline failure, and tokens validated against an allowlist rather than
    # merely split — an unknown scope must fail deterministically, not silently
    # match nothing and appear to pass.
    #
    # `IFS=` on the read is deliberate even though it is not splitting: it stops
    # read trimming implicitly, so trimming stays explicit and auditable. Only
    # SURROUNDING whitespace is stripped, so a future identifier containing
    # internal spaces would not be corrupted.
    while IFS= read -r _m; do
        _m="${_m#"${_m%%[![:space:]]*}"}"
        _m="${_m%"${_m##*[![:space:]]}"}"
        [[ -z "${_m}" ]] && continue
        case "${_m}" in
            ddos|portscan|loginmon) SCOPE_SET["${_m}"]=1 ;;
            *)
                printf 'Invalid mode-authority scope: %s\n' "${_m}" >&2
                exit 2 ;;
        esac
    # printf '%s\n', NOT '%s': without a trailing newline `read` hits EOF and
    # returns non-zero on the final token, so the while body never runs and EVERY
    # scope parses as empty. That failed silently — the guard simply reported
    # "targeted requires an explicit --scope" for a scope that was supplied.
    done < <(printf '%s\n' "${SCOPE_RAW}" | tr ',' '\n')
fi
in_scope() { [[ -n "${SCOPE_SET[$(key_module "$1")]:-}" ]]; }

head2 "CONTROLS (each check must be seen to fail before its result is trusted)"
if [[ ${RUN_CONTROLS} -eq 1 ]]; then
    IN_CONTROL=1
    control_silent_no_op
    control_orphan_entrypoint
    control_ledger
    control_markrunning
    IN_CONTROL=0
    KNOWN_HIT=()
else
    for c in SILENT_NO_OP ORPHAN_ENTRYPOINT LEDGER_CONSISTENCY MARKRUNNING_LIVENESS; do
        CHECK_CONTROL["${c}"]=SKIPPED
    done
    say "  controls skipped (--no-controls) — all results downgraded to NOT_YET_VERIFIED"
fi

head2 "CHECK 1 — SILENT_NO_OP (Lesson G: selected mode + missing entrypoint must never be rc0)"
say "  scoped to: functions containing a case with >=2 of auto|classic|suricata|hybrid;"
say "             guarded name matching ^nftban_(portscan|ddos|login|loginmon)_(classic|suricata)_;"
say "             guarded name invoked as a bare command; and NO else/elif arm."
check_silent_no_op "${REPO_ROOT}"
not_yet_verified "guards that DO have an else arm are not inspected for whether the arm truly fails" \
    "review by hand: grep -n 'type -t nftban_.*_\\(classic\\|suricata\\)_' -A6 cli/lib/nftban/core/nftban_{ddos,portscan}.sh"

head2 "CHECK 2 — ORPHAN_ENTRYPOINT (Lesson C: existence and export are not reachability)"
check_orphan_entrypoint "${REPO_ROOT}"
not_yet_verified "a caller existing in source does not prove the shipped lifecycle reaches it" \
    "on a live target: systemctl list-timers 'nftban*' && bash -x /usr/lib/nftban/core/nftban_portscan.sh 2>&1 | grep _run"

head2 "CHECK 3 — LEDGER_CONSISTENCY (row completeness + BROKEN must not be advertised)"
check_ledger "${REPO_ROOT}"

head2 "CHECK 4 — MARKRUNNING_LIVENESS (Lesson B: started is not running) [STATIC APPROXIMATION]"
check_markrunning "${REPO_ROOT}"

# -----------------------------------------------------------------------------
# Stale allowlist rows
# -----------------------------------------------------------------------------
head2 "ALLOWLIST HYGIENE"
STALE=0
for k in "${!KNOWN_KEYS[@]}"; do
    if [[ -z "${KNOWN_HIT[${k}]:-}" ]]; then
        say "  STALE  ${k}  (ledger=${KNOWN_STATUS[${k}]}) — no longer detected; remove it from $(basename "${KNOWN_FILE}")"
        STALE=$(( STALE + 1 ))
    fi
done
[[ ${STALE} -eq 0 ]] && say "  no stale rows (${#KNOWN_KEYS[@]}/${#KNOWN_KEYS[@]} accepted rows still reproduce)"

# -----------------------------------------------------------------------------
# Scope validation — the PR must DECLARE what it claims to close.
#
# Changed paths are evidence, never the declaration. A PR touching a module's
# authority code while declaring a different (or no) scope must fail: otherwise
# "targeted" would silently grant admission for surfaces nobody claimed.
#   required:  declared scope  ⊇  modules whose authority surfaces were touched
# -----------------------------------------------------------------------------
if [[ "${POLICY}" == "targeted" ]]; then
    head2 "SCOPE VALIDATION"
    if [[ ${#SCOPE_SET[@]} -eq 0 ]]; then
        say "  FAIL   --policy targeted requires an explicit --scope"
        SCOPE_VALIDATION=FAIL
    else
        say "  declared scope: ${SCOPE_RAW}"
    fi
    if [[ -n "${CHANGED_FILE}" && -r "${CHANGED_FILE}" ]]; then
        declare -A TOUCHED=()
        while IFS= read -r _p; do
            [[ -n "${_p}" ]] || continue
            while IFS= read -r _m; do
                [[ -n "${_m}" ]] && TOUCHED["${_m}"]=1
            done < <(path_modules "${_p}")
        done < "${CHANGED_FILE}"
        if [[ ${#TOUCHED[@]} -eq 0 ]]; then
            say "  no mode-authority surface touched by the changed paths"
        else
            say "  touched authority surfaces: ${!TOUCHED[*]}"
            for _m in "${!TOUCHED[@]}"; do
                if [[ -z "${SCOPE_SET[${_m}]:-}" ]]; then
                    say "  FAIL   '${_m}' authority code is modified but NOT in the declared scope"
                    say "         declared scope must cover every touched surface, or the change"
                    say "         must not touch it. Expand --scope or split the PR."
                    SCOPE_VALIDATION=FAIL
                fi
            done
        fi
    else
        not_yet_verified "declared scope was not verified against changed paths" \
            "pass --changed-paths <(git diff --name-only origin/main...HEAD)"
    fi
    [[ "${SCOPE_VALIDATION}" == "PASS" ]] && say "  scope validation PASS — declaration covers every touched surface"
fi

# -----------------------------------------------------------------------------
# Machine-readable summary
# -----------------------------------------------------------------------------
head2 "MACHINE-READABLE SUMMARY"
RC=0
for c in SILENT_NO_OP ORPHAN_ENTRYPOINT LEDGER_CONSISTENCY MARKRUNNING_LIVENESS; do
    new="${CHECK_NEW[${c}]:-0}"
    known="${CHECK_KNOWN[${c}]:-0}"
    mustfix="${CHECK_MUSTFIX[${c}]:-0}"
    ctl="${CHECK_CONTROL[${c}]:-SKIPPED}"
    if [[ "${ctl}" != "PASS" ]]; then
        result="NOT_YET_VERIFIED"
    elif [[ "${new}" -gt 0 ]]; then
        result="FAIL"
        RC=1
    elif [[ "${mustfix}" -gt 0 ]]; then
        # MUST_FIX = a violation whose ledger row is BROKEN.
        #
        # Under `all` it blocks and is a genuine FAIL. Under `drift` the job
        # itself passes, so calling it "FAIL" would print a failure beside a
        # green workflow — a truth mismatch of exactly the kind this guard
        # exists to prevent. It is classified KNOWN_MUST_FIX instead: known
        # release debt, blocked from admission, non-blocking in this mode.
        # It is never downgraded to PASS and never silently accepted.
        if [[ "${FAIL_ON}" == "all" ]]; then
            result="FAIL"
            RC=1
        else
            result="KNOWN_MUST_FIX"
        fi
    else
        result="PASS"
    fi
    printf 'MODE_AUTHORITY_CHECK=%s RESULT=%s NEW=%s MUST_FIX=%s ACCEPTED_DEBT=%s NEGATIVE_CONTROL=%s\n' \
        "${c}" "${result}" "${new}" "${mustfix}" "${known}" "${ctl}"
done
printf 'MODE_AUTHORITY_STALE_ALLOWLIST_ROWS=%s\n' "${STALE}"
printf 'MODE_AUTHORITY_NOT_YET_VERIFIED=%s\n' "${NYV_TOTAL}"
printf 'MODE_AUTHORITY_NEW_VIOLATIONS=%s\n' "${NEW_TOTAL}"
printf 'MODE_AUTHORITY_MUST_FIX_VIOLATIONS=%s\n' "${MUSTFIX_TOTAL}"
printf 'MODE_AUTHORITY_ACCEPTED_DEBT=%s\n' "${KNOWN_TOTAL}"
printf 'MODE_AUTHORITY_FAIL_ON=%s\n' "${FAIL_ON}"
# NEW drift and a stale allowlist always block. MUST_FIX blocks only under the
# default --fail-on all; under --fail-on drift it stays visible and counted but
# does not gate. It is never downgraded to PASS.
# NEW drift and stale rows always block, under every policy.
if [[ ${NEW_TOTAL} -gt 0 || ${STALE} -gt 0 ]]; then RC=1; fi
case "${POLICY}" in
    all)      [[ ${MUSTFIX_TOTAL}    -gt 0 ]] && RC=1 ;;
    targeted) [[ ${MUSTFIX_IN_SCOPE} -gt 0 ]] && RC=1
              [[ "${SCOPE_VALIDATION}" == "FAIL" ]] && RC=1 ;;
    drift)    : ;;   # known debt reported, never silently accepted
esac
# Admission is a SEPARATE axis from the CI verdict. A ratchet run can be green
# (no new drift) while admission is still blocked by known BROKEN rows.
# POLICY TRUTH. CI success != global admission; targeted closure != unrelated
# debt closure; a deferred defect is never a defect accepted as healthy.
printf 'MODE_AUTHORITY_POLICY=%s\n' "${POLICY}"
printf 'MODE_AUTHORITY_SCOPE=%s\n' "${SCOPE_RAW:-none}"
printf 'MODE_AUTHORITY_MUST_FIX_IN_SCOPE=%s\n' "${MUSTFIX_IN_SCOPE}"

if [[ "${POLICY}" == "targeted" ]]; then
    if [[ "${SCOPE_VALIDATION}" == "FAIL" ]]; then
        printf 'MODE_AUTHORITY_SCOPE_VALIDATION=FAIL\n'
        printf 'MODE_AUTHORITY_ADMISSION_SCOPE_RESULT=FAIL\n'
    elif [[ ${MUSTFIX_IN_SCOPE} -gt 0 ]]; then
        printf 'MODE_AUTHORITY_SCOPE_VALIDATION=PASS\n'
        printf 'MODE_AUTHORITY_ADMISSION_SCOPE_RESULT=FAIL\n'
    else
        printf 'MODE_AUTHORITY_SCOPE_VALIDATION=PASS\n'
        printf 'MODE_AUTHORITY_ADMISSION_SCOPE_RESULT=PASS\n'
    fi
fi

# GLOBAL admission is a separate axis and is NOT granted by a targeted pass.
if [[ ${MUSTFIX_TOTAL} -gt 0 ]]; then
    printf 'MODE_AUTHORITY_GLOBAL_ADMISSION=BLOCKED\n'
else
    printf 'MODE_AUTHORITY_GLOBAL_ADMISSION=ELIGIBLE\n'
fi

if [[ ${RC} -ne 0 ]]; then
    printf 'MODE_AUTHORITY_CI_RESULT=FAIL\n'
elif [[ ${MUSTFIX_TOTAL} -gt 0 ]]; then
    printf 'MODE_AUTHORITY_CI_RESULT=CI_RATCHET_NONBLOCKING\n'
else
    printf 'MODE_AUTHORITY_CI_RESULT=PASS\n'
fi
exit "${RC}"
