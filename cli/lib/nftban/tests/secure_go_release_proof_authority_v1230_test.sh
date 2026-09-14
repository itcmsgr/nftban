#!/usr/bin/env bash
# =============================================================================
# NFTBan - Secure Go release-proof authority (v1.230.0)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="secure_go_release_proof_authority_v1230_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-14"
# meta:description="Locks the v1.230.0 release-proof authority in secure-go.yml against the MEASURED negative specimen FINAL_RELEASE_SHA 5ab8d328, where a release-source commit (VERSION/VERSION_DATE/CHANGELOG changed, ZERO Go files) made paths-filter report go_changed=false, skipped Go Security Analysis, and still turned the REQUIRED context Build,Test,Scan(Go) green — govulncheck and go test -race -cover never ran on the commit that ships. Extracts the SHIPPED gate script out of the workflow (subject == shipped artifact, never a reimplementation), substitutes the GitHub expressions, and drives it. Asserts: the release specimen with analyze=skipped FAILS; the same specimen with analyze=success PASSES; an ordinary docs-only PR still PASSES with NO security claim (behaviour preserved); DEFAULT DENY holds for an empty release_changed; and statically that analyze.if consults release_changed and force_full_analysis. Static, hermetic; no network, no host."
# meta:ta.id="secure_go_release_proof_authority_v1230_test"
# meta:ta.owner="release"
# meta:ta.module="secure-go-release-proof"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="60"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files=".github/workflows/secure-go.yml"
# meta:inventory.binaries="bash,awk,sed"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
WF="$ROOT/.github/workflows/secure-go.yml"
PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
no(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "=== Secure Go release-proof authority (v1.230.0) ==="
[[ -f "$WF" ]] || { echo "  [FAIL] workflow absent: $WF"; exit 1; }

# ---------------------------------------------------------------------------
# The SUBJECT is the shipped gate script, extracted from the workflow — never a
# reimplementation. GUARD SUBJECT == GUARD INPUT.
# ---------------------------------------------------------------------------
extract_gate(){
    awk '/^      - name: Evaluate result/{f=1;next} f&&/^        run: \|/{g=1;next} g{ if ($0 ~ /^      - / || $0 ~ /^  [a-z]/) exit; print }' "$WF" \
      | sed -e 's/^          //'
}
GATE="$(extract_gate)"
if [[ -z "$GATE" ]]; then no "could not extract the gate script from the workflow"; echo "FAILS=1"; exit 1; fi
grep -q 'SCAN_REQUIRED' <<<"$GATE" && ok "extracted the shipped gate script (subject == artifact)" \
                                   || no "extracted block is not the gate script"

# Drive the real script with substituted GitHub expressions.
run_gate(){ # <filter.result> <go_changed> <release_changed> <analyze.result> <event> <force_full>
    local d; d="$(mktemp -d)"
    { printf '%s\n' "$GATE"; } > "$d/gate.sh"
    sed -i \
      -e "s|\${{ needs.filter.result }}|$1|g" \
      -e "s|\${{ needs.filter.outputs.go_changed }}|$2|g" \
      -e "s|\${{ needs.filter.outputs.release_changed }}|$3|g" \
      -e "s|\${{ needs.analyze.result }}|$4|g" \
      -e "s|\${{ github.event_name }}|$5|g" \
      -e "s|\${{ inputs.force_full_analysis }}|$6|g" \
      "$d/gate.sh"
    bash "$d/gate.sh" >/dev/null 2>&1; local rc=$?
    rm -rf "$d"; return $rc
}

# ---------------------------------------------------------------------------
# (1) THE MOTIVATING DEFECT — the exact 5ab8d328 specimen. MUST FAIL.
#     release metadata changed · 0 Go files · analyze skipped · aggregate was green
# ---------------------------------------------------------------------------
echo "=== (1) release-source specimen with analyze SKIPPED must FAIL (the 5ab8d328 defect) ==="
if run_gate success false true skipped pull_request ""; then
    no "release-source commit with a SKIPPED analysis was accepted — the 5ab8d328 defect is back"
else
    ok "release-source + analyze skipped REJECTED"
fi

# ---------------------------------------------------------------------------
# (2) Same specimen, proof actually executed. MUST PASS.
# ---------------------------------------------------------------------------
echo "=== (2) release-source specimen with analyze SUCCESS must PASS ==="
if run_gate success false true success pull_request ""; then
    ok "release-source + analyze success ACCEPTED"
else
    no "release-source with a completed analysis was rejected"
fi

# ---------------------------------------------------------------------------
# (3) BEHAVIOUR PRESERVED — an ordinary docs-only PR still passes, making no claim.
# ---------------------------------------------------------------------------
echo "=== (3) ordinary docs-only PR still PASSES (no regression) ==="
if run_gate success false false skipped pull_request ""; then
    ok "docs-only PR unaffected"
else
    no "docs-only PR now blocked — the fix over-reached"
fi

# ---------------------------------------------------------------------------
# (4) DEFAULT DENY — an empty release_changed is NOT "no release change".
# ---------------------------------------------------------------------------
echo "=== (4) empty release_changed is UNKNOWN, not false ==="
if run_gate success false "" skipped pull_request ""; then
    no "empty release_changed accepted as 'no release change'"
else
    ok "empty release_changed REJECTED (default deny)"
fi

# ---------------------------------------------------------------------------
# (5) Go-subject change still required, unchanged.
# ---------------------------------------------------------------------------
echo "=== (5) go_changed=true + analyze skipped still FAILS ==="
if run_gate success true false skipped pull_request ""; then
    no "Go change with a skipped analysis accepted"
else
    ok "Go change + analyze skipped REJECTED"
fi

# ---------------------------------------------------------------------------
# (6) STATIC — analyze must actually consult the new authorities, or the gate
#     logic above could be correct while the job never runs.
# ---------------------------------------------------------------------------
echo "=== (6) analyze.if consults release_changed and force_full_analysis ==="
# NOTE: terminate on the condition's OWN closing paren (a line that is exactly spaces + ')').
# An earlier form exited on the first ')' — which `always() && (` contains — and silently
# extracted one line. The assertions below then failed against a CORRECT workflow.
ANALYZE_IF="$(awk '/^  analyze:/{f=1} f&&/^    if: >-/{g=1;next} g{ if ($0 ~ /^      \)[[:space:]]*$/) exit; print }' "$WF")"
grep -q "release_changed == 'true'" <<<"$ANALYZE_IF" && ok "analyze.if consults release_changed" \
                                                     || no "analyze.if does NOT consult release_changed"
grep -q "force_full_analysis" <<<"$ANALYZE_IF" && ok "analyze.if consults force_full_analysis" \
                                               || no "analyze.if does NOT consult force_full_analysis"
grep -qE "^            release:" "$WF" && ok "filter declares the release-authority paths" \
                                       || no "filter has no release-authority paths"
for f in VERSION VERSION_DATE CHANGELOG.md; do
    grep -qE "^              - '$f'" "$WF" && ok "release filter covers $f" || no "release filter omits $f"
done

echo "=== secure-go release-proof: PASS=$PASS FAILS=$FAIL ==="
[[ $FAIL -eq 0 ]] || exit 1
exit 0
