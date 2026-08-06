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
MIGSRC="packaging/deb/postinst"
if [[ ! -r "$MIGSRC" ]]; then
    fail "cannot read $MIGSRC to derive migrated patterns"
else
    # Patterns the migration loop actually moves, derived from the source rather than
    # hardcoded here — a hardcoded list would drift from the migration it audits.
    exts="$(sed -n '/_nftban_migrate_reports_to_log()/,/^        }/p' "$MIGSRC" \
            | grep -oE '\*\.(html|txt|json)' | sort -u | tr -d '*.')"
    subs="$(sed -n '/_nftban_migrate_reports_to_log()/,/^        }/p' "$MIGSRC" \
            | grep -oE 'for _sub in [^;]*' | head -1)"
    r4=0
    for sub in "" "/daily"; do
        for e in $exts; do
            pat="/var/log/nftban/reports${sub}/*.${e}"
            if ! grep -qF "$pat" install/config/nftban.logrotate 2>/dev/null; then
                fail "migrated pattern has NO stanza: $pat"; r4=1
            elif ! grep -qF "$pat" internal/logretention/inventory.go 2>/dev/null; then
                fail "migrated pattern missing from the GENERATOR: $pat"; r4=1
            fi
        done
    done
    [[ "$r4" -eq 0 ]] && pass "every migrated pattern ($(echo $exts | tr ' ' ',') in reports/ and reports/daily/) has a retention owner in BOTH authorities"
fi

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
for var in STATS_REPORTS_DIR NFTBAN_REPORTS_DIR; do
    hits="$(grep -rn --include='*.conf' --include='*.sh' -E "^[[:space:]]*(export[[:space:]]+)?${var}=" \
              etc/ install/config/ cli/ 2>/dev/null \
            | grep -vE ':[0-9]+:[[:space:]]*#' \
            | grep -E '/var/(lib|cache)/nftban' || true)"
    if [[ -n "$hits" ]]; then
        fail "${var} assigned under /var/lib|/var/cache by package-owned config:"
        printf '%s\n' "$hits" | sed 's/^/        /'
        r5=1
    fi
done
if [[ "$r5" -eq 0 ]]; then
    pass "no package-owned assignment of STATS_REPORTS_DIR/NFTBAN_REPORTS_DIR under /var/lib|/var/cache"
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
    echo "=== RESULT: logrotate FHS authority PASS ==="
else
    echo "=== RESULT: logrotate FHS authority FAIL ==="
fi
exit "$FAIL"
