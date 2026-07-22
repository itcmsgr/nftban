#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="check-ci-bash-baseline-selftest"
# meta:type="script"
# meta:version="1.226.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Hermetic self-tests for check-ci-bash-baseline.sh: proves the integrity gate passes clean baselines and blocks drift/regression/dup/empty-manifest"
# meta:inventory.files="scripts/ci/check-ci-bash-baseline.sh"
# meta:inventory.binaries="bash,git,mktemp,grep,printf,cat"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Self-tests for scripts/ci/check-ci-bash-baseline.sh (v1.226.0 PR-C).
# Hermetic: builds synthetic git repos with a small index + baseline + manifest
# and asserts the BLOCKING integrity gate passes clean baselines and BLOCKS
# every drift/regression condition. All values synthetic.
#
# Expected-nonzero gate calls are captured in compounds (`... && bad || ok`) so
# the required `set -Eeuo pipefail` never aborts on an intended failure.
# =============================================================================
set -Eeuo pipefail

GATE="$(cd "$(dirname "$0")" && pwd)/check-ci-bash-baseline.sh"
FAIL=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s  %s\n' "$1" "${2:-}"; FAIL=1; }

# synthetic index: 4 ci-bash rows (t1..t4) + a non-ci-bash row (ignored)
IDXHDR=$'id\tpath\towner\ttype\tmodule\texecution_class\tgate\th\trr\trn\trs\trnft\trp\ttimeout\texcl\tact'
mkrepo() {
    local r; r="$(mktemp -d)"; git init -q "$r"; git -C "$r" config user.email t@t; git -C "$r" config user.name t
    mkdir -p "$r/scripts/ci"
    { printf '#\n#\n#\n%s\n' "$IDXHDR"
      for id in t1 t2 t3 t4; do printf '%s\tcli/lib/nftban/tests/%s.sh\to\tt\tm\tC\tci-bash\tt\tf\tf\tf\tf\tf\t\t\t\n' "$id" "$id"; done
      printf 'x1\tcli/lib/nftban/tests/x1.sh\to\tt\tm\tC\tpolicy-gates\tt\tf\tf\tf\tf\tf\t\t\t\n'
    } > "$r/scripts/ci/test-authority-index.tsv"
    # baseline: SELECTED=4 FAIL=1, accepted failing id = t3
    { printf 'CI_BASH_SELECTED=4\nCI_BASH_PASS=3\nCI_BASH_FAIL=1\nCI_BASH_TIMEOUT=0\nCI_BASH_ENFORCEMENT=INFORMATIONAL_BASELINE\nCI_BASH_INFORMATIONAL_BASELINE_SHA=x\n'
      printf 'FAIL\tt3\tsource-spec-drift\n'
    } > "$r/scripts/ci/ci-bash-informational-baseline.tsv"
    printf '%s' "$r"
}
manifest() {  # repo  then rows "STATUS id" on stdin -> writes ci-bash-manifest.txt with matching SELECTED/FAIL
    local r="$1"; shift
    local tmp; tmp="$(mktemp)"; cat > "$tmp"
    local sel pass fl to
    # grep -c returns nonzero on a zero count (e.g. no TIMEOUT rows); guard under -e
    sel="$(grep -c . "$tmp" || true)"; pass="$(grep -c '^PASS ' "$tmp" || true)"
    fl="$(grep -c '^FAIL ' "$tmp" || true)"; to="$(grep -c '^TIMEOUT ' "$tmp" || true)"
    { printf '# manifest\nGATE\tci-bash\nSELECTED\t%s\nPASS\t%s\nFAIL\t%s\nTIMEOUT\t%s\n' "$sel" "$pass" "$fl" "$to"
      while read -r st id; do printf 'TEST\t%s\t%s\n' "$st" "$id"; done < "$tmp"
    } > "$r/ci-bash-manifest.txt"
    rm -f "$tmp"
}
runc() { ( cd "$1" && "$GATE" "$1/ci-bash-manifest.txt" ); }

# clean baseline: exactly the accepted fail (t3), t1/t2/t4 pass -> exit 0
t_clean() { local r; r="$(mkrepo)"; manifest "$r" <<<$'PASS t1\nPASS t2\nFAIL t3\nPASS t4'
    runc "$r" >/dev/null 2>&1 && ok "clean baseline passes" || bad clean; rm -rf "$r"; }
# NEW failing id t2 (regression) -> block
t_regress() { local r; r="$(mkrepo)"; manifest "$r" <<<$'PASS t1\nFAIL t2\nFAIL t3\nPASS t4'
    runc "$r" >/dev/null 2>&1 && bad regress_not_blocked || ok "new failing id (regression) BLOCKED"; rm -rf "$r"; }
# improvement: t3 now passes, 0 fails -> allowed (exit 0)
t_improve() { local r; r="$(mkrepo)"; manifest "$r" <<<$'PASS t1\nPASS t2\nPASS t3\nPASS t4'
    runc "$r" >/dev/null 2>&1 && ok "improvement (accepted id now passes) allowed" || bad improve_blocked; rm -rf "$r"; }
# disappeared test: only 3 selected -> block (SELECTED != index count 4)
t_disappear() { local r; r="$(mkrepo)"; manifest "$r" <<<$'PASS t1\nPASS t2\nFAIL t3'
    runc "$r" >/dev/null 2>&1 && bad disappear_not_blocked || ok "disappeared test BLOCKED"; rm -rf "$r"; }
# extra/unknown test executed -> block (id set mismatch)
t_extra() { local r; r="$(mkrepo)"; manifest "$r" <<<$'PASS t1\nPASS t2\nFAIL t3\nPASS t4\nPASS t9'
    runc "$r" >/dev/null 2>&1 && bad extra_not_blocked || ok "unknown extra test BLOCKED"; rm -rf "$r"; }
# duplicate execution -> block
t_dup() { local r; r="$(mkrepo)"
    # 4 rows but t1 twice, t4 missing -> SELECTED still 4, but duplicate + idset mismatch
    manifest "$r" <<<$'PASS t1\nPASS t1\nPASS t2\nFAIL t3'
    runc "$r" >/dev/null 2>&1 && bad dup_not_blocked || ok "duplicate execution BLOCKED"; rm -rf "$r"; }
# empty manifest -> block (step never executed)
t_empty() { local r; r="$(mkrepo)"; : > "$r/ci-bash-manifest.txt"
    runc "$r" >/dev/null 2>&1 && bad empty_not_blocked || ok "empty manifest (step did not run) BLOCKED"; rm -rf "$r"; }
# missing manifest -> block
t_missing() { local r; r="$(mkrepo)"; rm -f "$r/ci-bash-manifest.txt"
    runc "$r" >/dev/null 2>&1 && bad missing_not_blocked || ok "missing manifest BLOCKED"; rm -rf "$r"; }

for t in t_clean t_regress t_improve t_disappear t_extra t_dup t_empty t_missing; do "$t"; done
echo
if [ "$FAIL" -eq 0 ]; then echo "CHECK_CI_BASH_BASELINE_SELFTEST_PASS"; exit 0
else echo "CHECK_CI_BASH_BASELINE_SELFTEST_FAIL"; exit 1; fi
