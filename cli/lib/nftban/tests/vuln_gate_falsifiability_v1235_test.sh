#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - the vulnerability gates FAIL on what they claim to catch
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="vuln_gate_falsifiability_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-09"
# meta:description="Owner audit 2026-10-09 (gap 5: gates must demonstrably detect the failures they claim to prevent). Extracts the REAL run blocks of .github/workflows/secure-go.yml (Run govulncheck (native SARIF); govulncheck verdict (scanner-native results)) and .github/workflows/osv-scanner.yml (OSV verdict (scanner-native results)) and executes them against ISOLATED fixtures (fake go/govulncheck on PATH, fixture SARIF files; no network, no real scan). Known finding (reachable error-level, present-only note-level, OSV result) -> FAIL; scanner failure (non-zero rc, rc 0 with no artifact, malformed artifact, no validated SARIF, undocumented OSV exit) -> FAIL; scanned toolchain != go.mod directive -> FAIL; OSV unused ignores -> FAIL; clean result -> PASS. govulncheck and OSV exit 0 in SARIF mode even with findings, so a wrapper that trusted the exit code would pass everything: every FAIL arm proves the wrapper does not."
# meta:input="None (self-contained sandbox)"
# meta:output="TOTAL pass/fail; exit 1 on any failed arm"
# meta:depends="bash,awk,python3"
# meta:inventory.files=".github/workflows/secure-go.yml,.github/workflows/osv-scanner.yml"
# meta:inventory.binaries="python3"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
SECURE="$REPO_ROOT/.github/workflows/secure-go.yml"
OSV="$REPO_ROOT/.github/workflows/osv-scanner.yml"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "  [PASS] $1"; }
ko(){ fail=$((fail+1)); echo "  [FAIL] $1"; }
SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT

# step_run <workflow> <exact step name> -> the step's `run: |` block, dedented (no pipe: one awk).
step_run(){
    awk -v want="$2" '
        !found && $0 ~ /^ *- name: / { n=$0; sub(/^ *- name: /, "", n); if (n == want) { found=1; match($0, /^ */); stepind=RLENGTH; next } }
        found && !inrun && $0 ~ /^ *run: \|/ { inrun=1; next }
        found && !inrun && $0 ~ /^ *- name: / { exit }
        inrun {
            if ($0 ~ /^[ \t]*$/) { print ""; next }
            match($0, /^ */); if (RLENGTH <= stepind) exit
            if (!ind) ind=RLENGTH
            print substr($0, ind+1)
        }' "$1"
}
GVC_RUN=$(step_run "$SECURE" "Run govulncheck (native SARIF)")
GVC_VERDICT=$(step_run "$SECURE" "govulncheck verdict (scanner-native results)")
OSV_VERDICT=$(step_run "$OSV" "OSV verdict (scanner-native results)")
for v in GVC_RUN GVC_VERDICT OSV_VERDICT; do
    [[ -n "${!v}" ]] || { ko "INVALID_TEST: step $v not found in the workflow (renamed?)"; echo "TOTAL: pass=$pass fail=$fail"; exit 1; }
done

sarif(){  # <file> <level|none|malformed>
    case "$2" in
        malformed) printf '{"runs":[{"results":[' > "$1" ;;
        none) printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"govulncheck"}},"results":[]}]}\n' > "$1" ;;
        *) printf '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"govulncheck"}},"results":[{"ruleId":"GO-2026-6617","level":"%s","message":{"text":"fixture"}}]}]}\n' "$2" > "$1" ;;
    esac
}

# --- govulncheck verdict: known findings FAIL, failures FAIL, clean PASS ---
gv_verdict(){  # <case> -> rc
    local d="$SB/gv_$1"; rm -rf "$d"; mkdir -p "$d"
    case "$1" in absent) ;; malformed) sarif "$d/govulncheck.sarif" malformed ;; reachable) sarif "$d/govulncheck.sarif" error ;;
        present) sarif "$d/govulncheck.sarif" note ;; clean) sarif "$d/govulncheck.sarif" none ;; esac
    (cd "$d" && bash -eo pipefail -c "$GVC_VERDICT") > "$d/out" 2>&1
}
for c in absent malformed reachable present; do
    rc=0; gv_verdict "$c" || rc=$?
    [[ $rc -ne 0 ]] && ok "govulncheck verdict: $c -> FAIL (rc=$rc)" || ko "govulncheck verdict: $c PASSED (false green)"
done
rc=0; gv_verdict clean || rc=$?
[[ $rc -eq 0 ]] && grep -q "CLEAN" "$SB/gv_clean/out" && ok "govulncheck verdict: clean -> PASS" || ko "govulncheck verdict: clean did not pass (rc=$rc)"

# --- govulncheck run: tool failure / no artifact / toolchain mismatch FAIL; normal run PASS ---
gv_run(){  # <case> -> rc ; fake go + govulncheck on PATH
    local d="$SB/gr_$1"; rm -rf "$d"; mkdir -p "$d/bin" "$d/gopath/bin"
    printf 'module x\n\ngo 1.26.9\n' > "$d/go.mod"
    printf '#!/bin/sh\n[ "$1" = env ] && [ "$2" = GOPATH ] && { echo "%s"; exit 0; }\nexit 0\n' "$d/gopath" > "$d/bin/go"
    local ver="go1.26.9" rcv=0 out=sarif
    case "$1" in toolfail) rcv=3 ;; noartifact) out=empty ;; mismatch) ver="go1.25.13" ;; noversion) ver="" ;; esac
    cat > "$d/gopath/bin/govulncheck" <<EOF
#!/bin/sh
if [ "\$1" = -version ]; then [ -n "$ver" ] && printf 'Go: %s\nScanner: govulncheck@v1.1.4\n' "$ver"; exit 0; fi
[ "$out" = sarif ] && printf '{"version":"2.1.0","runs":[{"results":[]}]}\n'
exit $rcv
EOF
    chmod +x "$d/bin/go" "$d/gopath/bin/govulncheck"
    (cd "$d" && PATH="$d/bin:$PATH" GITHUB_OUTPUT="$d/gh_out" bash -eo pipefail -c "$GVC_RUN") > "$d/out" 2>&1
}
for c in toolfail noartifact mismatch noversion; do
    rc=0; gv_run "$c" || rc=$?
    [[ $rc -ne 0 ]] && ok "govulncheck run: $c -> FAIL (rc=$rc)" || ko "govulncheck run: $c PASSED (false green)"
done
grep -q "SCANNED_TOOLCHAIN_MISMATCH" "$SB/gr_mismatch/out" && ok "toolchain mismatch is named (SCANNED_TOOLCHAIN_MISMATCH)" || ko "toolchain mismatch not named"
rc=0; gv_run normal || rc=$?
[[ $rc -eq 0 && -s "$SB/gr_normal/govulncheck.sarif" ]] && ok "govulncheck run: matching toolchain + artifact -> PASS" || ko "govulncheck run: normal case failed (rc=$rc) $(tail -3 "$SB/gr_normal/out")"

# --- OSV verdict ---
osv_verdict(){  # <case> <SARIF_READY> <OSV_EXIT> -> rc
    local d="$SB/osv_$1"; rm -rf "$d"; mkdir -p "$d"
    case "$1" in malformed) sarif "$d/osv-results.sarif" malformed ;; finding) sarif "$d/osv-results.sarif" warning ;; *) sarif "$d/osv-results.sarif" none ;; esac
    (cd "$d" && SARIF_READY="$2" OSV_EXIT="$3" bash -eo pipefail -c "$OSV_VERDICT") > "$d/out" 2>&1
}
for c in "notready false 0" "malformed true 1" "finding true 1" "unusedignore true 1" "dbfail true 2"; do
    set -- $c; rc=0; osv_verdict "$1" "$2" "$3" || rc=$?
    [[ $rc -ne 0 ]] && ok "OSV verdict: $1 -> FAIL (rc=$rc)" || ko "OSV verdict: $1 PASSED (false green)"
done
rc=0; osv_verdict clean true 0 || rc=$?
[[ $rc -eq 0 ]] && grep -q "CLEAN" "$SB/osv_clean/out" && ok "OSV verdict: clean -> PASS" || ko "OSV verdict: clean did not pass (rc=$rc)"

echo ""
echo "TOTAL: pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
