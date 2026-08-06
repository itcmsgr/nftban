#!/usr/bin/env bash
# =============================================================================
# NFTBan - logrotate FHS authority guard (v1.228.5)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="check-logrotate-fhs-authority"
# meta:type="ci-guard"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-06"
# meta:description="v1.228.5 FHS closure guard. A logrotate stanza may only target /var/log. MEASURED defect: the package-generated /etc/logrotate.d/nftban rotated /var/lib/nftban/permissions_audit.log and /var/lib/nftban/reports/*; files there carry SELinux type nftban_var_lib_t, which logrotate_t has NO file-class access to (nftban_log_t gets it via logging_log_file(), nftban_var_lib_t gets only files_type()). One failing stanza fails the WHOLE system-wide logrotate.service, so this made it fail daily on stock EL9 Enforcing (denied { getattr } on permissions_audit.log, denied { read } on the reports dir; Enforcing=FAIL / Permissive=SUCCESS discriminator). CRITICAL: /etc/logrotate.d/nftban is a %ghost GENERATED artifact produced at postinstall by 'nftban-core logretention generate install' from internal/logretention/inventory.go - so this guard checks the GENERATOR (the real authority) as well as the shipped template. Fixing only the template would be silently reverted on every install. Rules operate on EXECUTABLE/declared paths, never comments, so documenting the historical defect cannot trip the guard. Static analysis only - reads files, invokes nothing, contacts no host."
# meta:input="internal/logretention/inventory.go, install/config/*.logrotate"
# meta:output="PASS/FAIL per rule; exit 0 on all-pass, 1 on any violation"
# meta:depends="bash,grep,sed"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,sed"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

FAIL=0
pass(){ printf '  [PASS] %s\n' "$1"; }
fail(){ printf '  [FAIL] %s\n' "$1"; FAIL=1; }

# Only nftban's own state/cache trees are forbidden as rotation targets. A generic
# "/var/lib" match would also flag unrelated third-party paths this project does not own.
FORBIDDEN='/var/(lib|cache)/nftban'

echo "=== R-1: the GENERATOR declares no rotation target outside /var/log ==="
# The generator is the real authority: postinstall regenerates the installed stanza from
# it, so a template-only fix is reverted on the next install. Declared Paths/Olddir only,
# comments stripped.
GEN="internal/logretention/inventory.go"
if [[ ! -r "$GEN" ]]; then
    fail "cannot read $GEN"
else
    g="$(sed -e 's://.*$::' "$GEN" \
         | grep -oE '"(/var/[^"]+)"' | tr -d '"' | grep -E "^${FORBIDDEN}" || true)"
    if [[ -n "$g" ]]; then
        fail "generator declares rotation targets under nftban state/cache:"
        printf '%s\n' "$g" | sort -u | sed 's/^/        /'
        echo "        -> logrotate_t has NO file-class access to nftban_var_lib_t."
        echo "           Move the artifact to /var/log/nftban (already nftban_log_t via"
        echo "           logging_log_file()) — do NOT grant logrotate_t access to state."
    else
        pass "generator declares no /var/lib|/var/cache nftban rotation target"
    fi
fi

echo "=== R-2: shipped templates declare no rotation target outside /var/log ==="
t_all=""
for t in install/config/*.logrotate; do
    [[ -r "$t" ]] || continue
    # stanza path lines only: a leading '/' at column 0, comments stripped
    t_bad="$(sed -e 's:#.*$::' "$t" | grep -oE "^${FORBIDDEN}[^ {]*" || true)"
    # olddir/createolddir targets are a rotation surface too (logrotate must create+rename there)
    o_bad="$(sed -e 's:#.*$::' "$t" | grep -oE "olddir[[:space:]]+${FORBIDDEN}[^ ]*" || true)"
    [[ -n "$t_bad$o_bad" ]] && t_all+="$t:"$'\n'"$t_bad$o_bad"$'\n'
done
if [[ -n "$t_all" ]]; then
    fail "shipped template rotation targets under nftban state/cache:"
    printf '%s\n' "$t_all" | sed 's/^/        /'
else
    pass "shipped templates target only /var/log"
fi

echo "=== R-3: generator and template do not drift on the migrated path ==="
# Both must name the corrected location; a fix applied to one only is the exact failure
# mode this guard exists to prevent.
if grep -qF '/var/log/nftban/permissions_audit.log' "$GEN" 2>/dev/null \
   && grep -qF '/var/log/nftban/permissions_audit.log' install/config/nftban.logrotate 2>/dev/null; then
    pass "permissions_audit.log corrected in BOTH generator and template"
else
    fail "permissions_audit.log path differs between generator and template (or is missing)"
fi

echo "=== R-4: every pattern the MIGRATION moves has a retention owner ==="
# The guard blind spot that let daily/*.json through: R-1..R-3 prove nothing rotates out
# of /var/lib, but said nothing about whether the destination has an owner. The package
# MOVES these artifacts, so it owns their destination lifecycle — a migrated file with no
# stanza is an unowned artifact, the exact class this release closes.
# TWO migration authorities, not one. packaging/deb/postinst carries the DEB scriptlet and
# packaging/build_nftban.sh carries the RPM %post body. They are currently byte-identical
# after unescaping, but NOTHING enforced that — R-4 previously read the DEB copy only, so a
# pattern added to the RPM body alone would have been audited against the wrong source.
MIGSRCS=(packaging/deb/postinst packaging/build_nftban.sh)

# Derive the migrated globs from the migration loop ITSELF.
#
# The previous form ran `grep -oE '\*\.(html|txt|json)'` over the whole function body. Two
# defects, both MEASURED:
#   1. The alternation HARDCODED the answer. Adding "$_o"/*.csv to the migration yielded
#      RESULT: PASS — a newly migrated class silently acquired no retention owner, which is
#      the exact class R-4 exists to close.
#   2. It read COMMENTS as subject. The function documents `path="…/reports/*.html"` in an
#      AVC excerpt, so a comment could satisfy the very assertion the code must satisfy.
# Both are fixed by stripping comments first and reading only the `for _f in "$_o"/…` loop,
# with the extension class left open ([A-Za-z0-9]+). GUARD SUBJECT == GUARD INPUT.
_derive_exts() {
    sed -e 's:#.*$::' "$1" 2>/dev/null \
        | grep -E 'for _f in .*\$_o' | head -1 \
        | grep -oE '\*\.[A-Za-z0-9]+' | sed 's/^\*\.//' | sort -u | tr '\n' ' ' | sed 's/ $//'
}
# The subdirectory list is derived too — hardcoding "" /daily here would drift exactly the
# way the extension list did.
_derive_subs() {
    sed -e 's:#.*$::' "$1" 2>/dev/null \
        | grep -E 'for _sub in' | head -1 \
        | sed -e 's/.*for _sub in //' -e 's/;.*//' -e 's/""//g' | tr -s ' ' | sed 's/^ //;s/ $//'
}

r4=0
declare -A _seen_exts=()
for MIGSRC in "${MIGSRCS[@]}"; do
    if [[ ! -r "$MIGSRC" ]]; then
        fail "cannot read $MIGSRC to derive migrated patterns"; r4=1; continue
    fi
    # FAIL-CLOSED. Zero is never a valid architecture state here: a degenerate read must
    # fail, not pass vacuously. MEASURED — renaming the migration function yielded exts="",
    # the loop never ran, and the rule printed PASS while asserting ZERO patterns.
    if ! grep -q '_nftban_migrate_reports_to_log()' "$MIGSRC" 2>/dev/null; then
        fail "migration function ABSENT or RENAMED in $MIGSRC — R-4 cannot derive its subject"
        r4=1; continue
    fi
    exts="$(_derive_exts "$MIGSRC")"
    subs="$(_derive_subs "$MIGSRC")"
    if [[ -z "$exts" ]]; then
        fail "derived ZERO migrated extensions from $MIGSRC — extraction degenerate, this rule would pass vacuously"
        r4=1; continue
    fi
    _seen_exts["$MIGSRC"]="$exts"

    for sub in "" $subs; do
        for e in $exts; do
            pat="/var/log/nftban/reports${sub}/*.${e}"
            if ! grep -qF "$pat" install/config/nftban.logrotate 2>/dev/null; then
                fail "[$MIGSRC] migrated pattern has NO stanza: $pat"; r4=1
            elif ! grep -qF "$pat" "$GEN" 2>/dev/null; then
                fail "[$MIGSRC] migrated pattern missing from the GENERATOR: $pat"; r4=1
            fi
        done
    done
done

# DRIFT: the two scriptlets must migrate the same classes. If they diverge, one platform
# migrates a class the other leaves behind — and only one of them is audited above.
if [[ "${#_seen_exts[@]}" -eq 2 ]]; then
    if [[ "${_seen_exts[packaging/deb/postinst]}" != "${_seen_exts[packaging/build_nftban.sh]}" ]]; then
        fail "DEB and RPM migrations move DIFFERENT classes: DEB='${_seen_exts[packaging/deb/postinst]}' RPM='${_seen_exts[packaging/build_nftban.sh]}'"
        r4=1
    fi
fi

# Non-vacuity on the destination side: an empty subject set cannot prove ownership.
gen_n="$(grep -cF '/var/log/nftban/reports' "$GEN" 2>/dev/null || echo 0)"
tpl_n="$(grep -cF '/var/log/nftban/reports' install/config/nftban.logrotate 2>/dev/null || echo 0)"
if [[ "$gen_n" -eq 0 ]]; then
    fail "GENERATOR declares ZERO /var/log report patterns — subject set empty, cannot assert ownership"; r4=1
fi
if [[ "$tpl_n" -eq 0 ]]; then
    fail "TEMPLATE declares ZERO /var/log report patterns — subject set empty, cannot assert ownership"; r4=1
fi

[[ "$r4" -eq 0 ]] && pass "every migrated pattern (DEB+RPM: ${_seen_exts[packaging/deb/postinst]:-none}) has a retention owner in BOTH authorities"

echo "=== R-5: no package-owned config assigns a migrated dir back under /var/lib ==="
# THE DEFECT THIS EXISTS TO CATCH. R-1..R-4 proved the logrotate GENERATOR targets
# /var/log. They proved nothing about where the WRITER actually resolves to. The code
# default at cmd_report.sh was already correct:
#     NFTBAN_REPORTS_DIR="${STATS_REPORTS_DIR:-${NFTBAN_LOG_DIR:-/var/log/nftban}/reports}"
# but shipped conf.d STILL assigned STATS_REPORTS_DIR=/var/lib/nftban/reports, so the
# EFFECTIVE value stayed on the old path and nftban-report-daily.service wrote there —
# unrotated — on a candidate that had otherwise "migrated".
#
#   DEFAULT_PATH_CORRECT  !=  EFFECTIVE_PATH_CORRECT
#
# Enumerate every package-owned assignment of the destination variables and reject any
# that resolves under /var/lib or /var/cache. Comments are stripped so documenting the
# old path cannot trip it.
r5=0

# SCOPE. The previous form scanned --include='*.conf' --include='*.sh' under etc/,
# install/config/ and cli/ only. MEASURED blind spots — all of these injected cleanly and
# still produced RESULT: PASS:
#     a *.go  const ReportsDir = "/var/lib/nftban/reports"
#     install/systemd/x.service  Environment=NFTBAN_REPORTS_DIR=/var/lib/nftban/reports
#     config-schema.json  (*.json was not scanned at all)
#     NFTBAN_REPORTS_DIR="${NFTBAN_DATA_DIR}/reports"   (resolves to state, no literal)
# The rule exists to catch DEFAULT_PATH_CORRECT != EFFECTIVE_PATH_CORRECT, and the writer
# it missed was in Go — a language it did not read. Scope now follows the effective value
# wherever it can be declared.
R5_INCLUDES=(--include='*.conf' --include='*.sh' --include='*.go' --include='*.json'
             --include='*.service' --include='*.timer' --include='*.logrotate'
             --include='postinst' --include='preinst' --include='postrm' --include='prerm')
R5_ROOTS=(etc install cli packaging cmd internal)

# COMMENT STRIPPING. The previous form dropped only WHOLE-LINE comments, so a CORRECT
# assignment carrying an ACCURATE trailing comment failed a blocking gate:
#     STATS_REPORTS_DIR="/var/log/nftban/reports"   # v1.228.5: moved from /var/lib/nftban/reports
# The two shipped lines survived only because they wrote "/var/lib" without the rest of the
# path — a one-character margin on a BLOCKING gate. Fix the parser, never the comment:
# comments are removed from the INPUT so the guard's subject is exactly the executable text.
# Line numbers are preserved because sed blanks the comment rather than deleting the line.
# Known limitation: a '#' inside a quoted shell string is treated as a comment. That is the
# same trade-off R-1/R-2 already make, and no package-owned path contains one.
# The corpus is built ONCE. A per-file sed across 1300+ files re-run per rule cost 22s a
# run, which is too slow to sit in front of every push and far too slow for the
# falsifiability harness that exercises this guard a dozen times.
#
# The pre-filter is a deliberate SUPERSET: any line whose CODE could match a rule below
# necessarily contains "report" or "analytics.Init", so filtering on the raw line before
# stripping cannot drop a true positive. Comments are removed AFTER the pre-filter and
# BEFORE any rule is applied, so every rule's subject is still executable text only.
_r5_build_corpus() {
    local line f rest n txt
    grep -rnI -iE 'report|analytics\.Init' "${R5_INCLUDES[@]}" "${R5_ROOTS[@]}" 2>/dev/null \
    | while IFS= read -r line; do
        f="${line%%:*}"; rest="${line#*:}"; n="${rest%%:*}"; txt="${rest#*:}"
        case "$f" in
            *.go)   txt="${txt%%//*}" ;;   # Go line comment
            *.json) : ;;                    # JSON has no comments
            *)      txt="${txt%%#*}" ;;     # shell / systemd / logrotate
        esac
        [[ -n "${txt//[[:space:]]/}" ]] && printf '%s:%s:%s\n' "$f" "$n" "$txt"
    done
}
R5_CORPUS="$(_r5_build_corpus)"

# Legitimate state-class artifacts that DO belong under /var/lib/nftban/reports: these are
# daemon state, not operational history, and tmpfiles.d creates them there by design.
# Matching them is a false positive, not a finding. The prefix is deliberately unanchored —
# the watchdog declares its directory through an indirection,
#     "${NFTBAN_WATCHDOG_REPORT_DIR:=${NFTBAN_DATA_DIR:-/var/lib/nftban}/reports/watchdog}"
# so requiring a literal /var/lib prefix would miss the exemption and flag a correct line.
R5_STATE_OK='/reports/(baseline|watchdog|archive|auditors)'

# KNOWN-INERT DECLARATIONS — reported, never silently passed.
# Three Go declarations name the pre-migration path. Each was traced to ZERO consumers:
# nftbanconf's ReportsDir()/ReportFile() accessors have no caller outside their own package,
# and stats.Config.ReportsDir has no reader at all. They therefore write nothing today.
# They are NOT corrected in v1.228.5 because their CLASS is undetermined — stats.Config sits
# beside watchdog paths, and watchdog reports are state-class by design, so repointing it
# could relocate state rather than fix a defect. That is an owner decision, not a guard's.
# Listed by file + symbol rather than line number so a shifted line cannot silently
# re-arm them, and any NEW occurrence outside this list still FAILS.
R5_KNOWN_INERT='^internal/stats/config\.go:|^internal/nftbanconf/loader\.go:|^internal/configloader/loader\.go:'

_r5_scan() {
    # $1 = ERE matched against the comment-stripped corpus; emits file:line:text
    printf '%s\n' "$R5_CORPUS" | grep -E "$1" 2>/dev/null || true
}

R5_VAR='[Rr][Ee][Pp][Oo][Rr][Tt][Ss]?_?[Dd][Ii][Rr]'
# Assignment operators, plural. Shell/systemd/JSON use '=' or ':', but Go STRUCT LITERALS
# use ':' — `ReportsDir: cfg.DataDir + "/reports"`. A first draft of this rule matched '='
# only and missed internal/nftbanconf/loader.go for exactly that reason.
R5_ASSIGN='[^:=]*[:=]'

_r5_report() {   # $1 = heading, $2 = hits, $3 = "fail"|"warn"
    [[ -z "$2" ]] && return 0
    if [[ "$3" == "warn" ]]; then
        printf '  [WARN] %s\n' "$1"
    else
        fail "$1"; r5=1
    fi
    printf '%s\n' "$2" | sed 's/^/        /'
}

# R-5a: a report-destination declaration that resolves under state/cache, in ANY declaration
# form (shell assignment, systemd Environment=, Go const/struct field, JSON default).
a_all="$(_r5_scan "$R5_VAR" | grep -E '/var/(lib|cache)/nftban' | grep -vE "$R5_STATE_OK" || true)"
a_hits="$(printf '%s' "$a_all" | grep -vE "$R5_KNOWN_INERT" || true)"
a_warn="$(printf '%s' "$a_all" | grep -E  "$R5_KNOWN_INERT" || true)"
_r5_report "report-destination declaration resolves under /var/lib|/var/cache:" "$a_hits" fail
_r5_report "KNOWN-INERT declaration on the pre-migration path (zero consumers; class undetermined — owner decision, tracked NOT fixed in v1.228.5):" "$a_warn" warn

# R-5b: INDIRECTION. No literal old path appears, but the value still resolves into the
# state tree because it is built from the data/state directory.
b_all="$(_r5_scan "${R5_VAR}${R5_ASSIGN}.*(DATA_DIR|STATE_DIR|LIB_DIR|dataDir|DataDir|StateDir)" \
         | grep -vE "$R5_STATE_OK" || true)"
b_hits="$(printf '%s' "$b_all" | grep -vE "$R5_KNOWN_INERT" || true)"
b_warn="$(printf '%s' "$b_all" | grep -E  "$R5_KNOWN_INERT" || true)"
_r5_report "report-destination declaration derives from the state/data dir (resolves outside /var/log):" "$b_hits" fail
_r5_report "KNOWN-INERT indirection onto the state tree (zero consumers; tracked NOT fixed in v1.228.5):" "$b_warn" warn

# R-5c: the Go analytics reports argument — the form that escaped every earlier rule.
# analytics.Init(dataDir, dataDir+"/reports") recreates /var/lib/nftban/reports at RUNTIME,
# after postinstall migrated it away. No identifier named *ReportsDir is involved, so
# R-5a/R-5b cannot see it; it needs its own assertion.
c_hits="$(_r5_scan 'analytics\.Init\([^)]*,[^)]*(dataDir|DataDir)' || true)"
_r5_report "analytics reports directory derived from dataDir (must be LogDir+\"/reports\"):" "$c_hits" fail

# R-5d: a map/registry entry KEYED "reports" whose value is built from the data dir. Same
# defect class as R-5b, but the key carries no "dir" token so the R5_VAR pattern misses it.
d_all="$(_r5_scan '"reports"[[:space:]]*:[[:space:]]*.*(dataDir|DataDir|DATA_DIR)' || true)"
d_hits="$(printf '%s' "$d_all" | grep -vE "$R5_KNOWN_INERT" || true)"
d_warn="$(printf '%s' "$d_all" | grep -E  "$R5_KNOWN_INERT" || true)"
_r5_report "\"reports\" path entry derived from the data dir:" "$d_hits" fail
_r5_report "KNOWN-INERT \"reports\" path entry (zero consumers; tracked NOT fixed in v1.228.5):" "$d_warn" warn

# NON-VACUITY: if the scan matched nothing at all, the file set is wrong and the rule is
# asserting into a vacuum. There is always at least one legitimate declaration.
r5_subject_n="$(_r5_scan '[Rr][Ee][Pp][Oo][Rr][Tt][Ss]?_?[Dd][Ii][Rr]' | wc -l | tr -d ' ')"
if [[ "$r5_subject_n" -eq 0 ]]; then
    fail "R-5 matched ZERO report-destination declarations — the file set or pattern is broken, not the codebase"
    r5=1
fi

if [[ "$r5" -eq 0 ]]; then
    pass "no package-owned report destination resolves under /var/lib|/var/cache ($r5_subject_n declarations examined)"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
    echo "=== RESULT: logrotate FHS authority PASS ==="
else
    echo "=== RESULT: logrotate FHS authority FAIL ==="
fi
exit "$FAIL"
