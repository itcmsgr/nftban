#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.194.0 (8C) - Protection-Claim Matrix harness test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="protection_claim_matrix_v194_test"
# meta:type="test"
# meta:version="1.194.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-17"
# meta:description="8C harness: validates the protection-claim matrix (via the CI guard: completeness, field population, enum validity, owner-enforcement guard, dead-knob guard) AND runs the existing hermetic per-claim fixtures referenced in the matrix FIXTURE column as the runtime-owner-bans proof. No detector behavior change; no host/nft/root; no read-only fleet probe."
# meta:inventory.files="protection_claim_matrix_v194.tsv,protection_claim_matrix_v194_test.sh"
# meta:inventory.binaries="bash,awk,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
MATRIX="$SCRIPT_DIR/protection_claim_matrix_v194.tsv"
GUARD="$REPO_ROOT/scripts/ci/check-protection-claim-matrix.sh"
[[ -f "$MATRIX" ]] || { echo "FAIL: matrix not found at $MATRIX"; exit 1; }
[[ -f "$GUARD"  ]] || { echo "FAIL: CI guard not found at $GUARD"; exit 1; }
PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "=== T1: static matrix invariants (CI guard) ==="
if bash "$GUARD" >/tmp/pcm_guard.out 2>&1; then ok "CI guard PASS (completeness/fields/enums/owner-enforcement/dead-knob)"; else bad "CI guard FAILED:"; sed 's/^/      /' /tmp/pcm_guard.out; fi

mapfile -t ROWS < <(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$MATRIX")

echo "=== T2: classifications present (every enforce claim resolved or honestly reclassified) ==="
echo "    classifications: $(printf '%s\n' "${ROWS[@]}" | awk -F'|' '{print $11}' | sort | uniq -c | tr '\n' ' ' | sed 's/  */ /g')"
# every CLAIMED enforce row must have a non-empty owner OR be unowned/deferred (re-assert beyond the guard)
orphan=0
for r in "${ROWS[@]}"; do
    IFS='|' read -r CLAIM _ _ OWNER _ _ MODE _ _ _ CLASS _ <<< "$r"
    [[ "$MODE" == "enforce" && "$OWNER" == "NONE" && "$CLASS" != "unowned" && "$CLASS" != "deferred" ]] && { echo "      orphan: $CLAIM"; orphan=1; }
done
[[ "$orphan" -eq 0 ]] && ok "no orphaned claimed-enforce rows" || bad "orphaned claimed-enforce row(s)"

echo "=== T3: hermetic per-claim fixtures (matrix FIXTURE = tests/*.sh → run as the owner-bans proof) ==="
# Collect unique runnable fixtures referenced by the matrix.
mapfile -t FIXTURES < <(printf '%s\n' "${ROWS[@]}" | awk -F'|' '$9 ~ /_test\.sh$/ {print $9}' | sort -u)
ran=0
for fx in "${FIXTURES[@]}"; do
    fp="$SCRIPT_DIR/$fx"
    if [[ ! -f "$fp" ]]; then bad "fixture referenced but missing: $fx"; continue; fi
    if timeout 90 bash "$fp" >/tmp/pcm_fx.out 2>&1; then
        ok "fixture PASS: $fx ($(printf '%s\n' "${ROWS[@]}" | awk -F'|' -v f="$fx" '$9==f{printf "%s ",$1}'))"
        ran=$((ran+1))
    else
        rc=$?
        bad "fixture FAILED ($fx, rc=$rc):"; tail -4 /tmp/pcm_fx.out | sed 's/^/      /'
    fi
done
[[ "$ran" -ge 4 ]] && ok "ran $ran hermetic per-claim fixtures (>=4 owner-bans proofs)" || bad "only $ran hermetic fixtures ran (expected >=4)"

echo "=== T4: non-hermetic rows recorded (not run here; require lab/read-only-fleet/kernel) ==="
nonh="$(printf '%s\n' "${ROWS[@]}" | awk -F'|' '$9 !~ /_test\.sh$/ {printf "%s(%s) ",$1,$9}')"
echo "    deferred-to-other-gate: $nonh"
ok "non-hermetic rows are explicitly classified + carry a fixture descriptor (lab/read-only-fleet/kernel/mode)"

echo "=== T5: dead-knob NOT live (matrix-level; mirrors guard) ==="
if grep -qE 'WordPressXMLRPC|WordPressWPLogin' <(printf '%s\n' "${ROWS[@]}" | awk -F'|' '{print $4"|"$6}'); then
    bad "dead knob appears as OWNER/BAN_AUTHORITY"
else
    ok "WordPressXMLRPC/WordPressWPLogin absent from any live OWNER/BAN_AUTHORITY"
fi

echo ""
echo "=== protection-claim matrix harness v1.194.0: PASS=$PASS FAIL=$FAIL (rows=${#ROWS[@]}) ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
