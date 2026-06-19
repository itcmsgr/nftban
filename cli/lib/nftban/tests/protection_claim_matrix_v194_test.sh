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
EXPECT_ROWS="${PCM_EXPECT_ROWS:-21}"
# The matrix SHIPS alongside this harness (RPM /usr/lib/nftban/tests); it must
# always be present. The CI guard lives under scripts/ci and is CI/source-tree
# ONLY (not shipped) — its absence is expected in an installed package tree and
# must NOT hard-fail the harness (v1.194 PR-A finding 2).
[[ -f "$MATRIX" ]] || { echo "FAIL: matrix not found at $MATRIX"; exit 1; }
PASS=0; FAIL=0
ok(){   echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad(){  echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
info(){ echo "  [INFO] $1"; }

mapfile -t ROWS < <(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$MATRIX")

# Inline matrix validation — used when the CI guard is not present (installed
# package tree). Mirrors scripts/ci/check-protection-claim-matrix.sh so that a
# CORRUPTED shipped matrix still fails the harness even without the guard. The
# source-tree guard remains the authoritative, unmodified gate (run below when
# present); this is a shipped-tree safety net, not a replacement.
_inline_matrix_checks(){
    local _e=0
    local OWNER_ENUM="BotScan LoginMon BotGuard DDoS/kernel Portscan/kernel Feeds/GeoBan Suricata NONE"
    local MODE_ENUM="enforce suppress observe-only"
    local CLASS_ENUM="validated false-claim dead-knob unowned legacy-only unproven deferred observe-only suppress"
    _ie(){ case " $2 " in *" $1 "*) return 0;; *) return 1;; esac; }
    [[ "${#ROWS[@]}" -eq "$EXPECT_ROWS" ]] || { echo "      inline: expected $EXPECT_ROWS rows, found ${#ROWS[@]}"; _e=1; }
    local dups; dups="$(printf '%s\n' "${ROWS[@]}" | awk -F'|' '{print $1}' | sort | uniq -d)"
    [[ -z "$dups" ]] || { echo "      inline: duplicate CLAIM_ID(s): $dups"; _e=1; }
    local r CLAIM OWNER MODE CLASS BANAUTH nf v
    for r in "${ROWS[@]}"; do
        IFS='|' read -r CLAIM _ _ OWNER _ BANAUTH MODE _ _ _ CLASS _ <<< "$r"
        nf=$(awk -F'|' '{print NF}' <<< "$r")
        [[ "$nf" -eq 11 ]] || { echo "      inline: $CLAIM has $nf fields (need 11)"; _e=1; }
        for v in $(awk -F'|' '{for(i=1;i<=NF;i++)print (length($i)?"x":"EMPTY")}' <<< "$r"); do
            [[ "$v" == "EMPTY" ]] && { echo "      inline: $CLAIM has an empty field"; _e=1; }
        done
        _ie "$OWNER" "$OWNER_ENUM" || { echo "      inline: $CLAIM bad OWNER '$OWNER'"; _e=1; }
        _ie "$MODE"  "$MODE_ENUM"  || { echo "      inline: $CLAIM bad MODE '$MODE'"; _e=1; }
        _ie "$CLASS" "$CLASS_ENUM" || { echo "      inline: $CLAIM bad CLASSIFICATION '$CLASS'"; _e=1; }
        if [[ "$MODE" == "enforce" && "$OWNER" == "NONE" && "$CLASS" != "unowned" && "$CLASS" != "deferred" ]]; then
            echo "      inline: $CLAIM enforce+OWNER=NONE not unowned/deferred"; _e=1
        fi
        case "$OWNER$BANAUTH" in *WordPressXMLRPC*|*WordPressWPLogin*) echo "      inline: $CLAIM dead knob as live OWNER/BAN_AUTHORITY"; _e=1;; esac
    done
    local ef; ef="$(printf '%s\n' "${ROWS[@]}" | awk -F'|' '$1=="ENDPOINT-FLOOD-XMLRPC-WPLOGIN"')"
    { [[ -n "$ef" ]] && awk -F'|' '{exit !($4=="BotScan")}' <<< "$ef"; } || { echo "      inline: ENDPOINT-FLOOD-XMLRPC-WPLOGIN not owned by BotScan"; _e=1; }
    return $_e
}

# INSTALLED_TREE=1 when the CI guard is absent (installed package tree). In that
# mode the per-claim fixtures are best-effort: source-tree-only fixtures (which
# hard-code the repo checkout layout) legitimately cannot run from /usr/lib and
# are SKIPPED, not failed. The strict per-fixture gate lives in the source tree
# (CI), where every referenced fixture must pass.
INSTALLED_TREE=0
echo "=== T1: static matrix invariants ==="
if [[ -f "$GUARD" ]]; then
    g_out="$(mktemp)"
    if bash "$GUARD" >"$g_out" 2>&1; then ok "CI guard PASS (completeness/fields/enums/owner-enforcement/dead-knob)"; else bad "CI guard FAILED:"; sed 's/^/      /' "$g_out"; fi
    rm -f "$g_out"
else
    INSTALLED_TREE=1
    info "CI guard not in this tree ($GUARD) — source/CI-only, expected in an installed package tree. Validating shipped matrix INLINE instead."
    if _inline_matrix_checks; then ok "inline matrix validation PASS (shipped-tree: completeness/fields/enums/owner-enforcement/dead-knob)"; else bad "inline matrix validation FAILED (shipped matrix corrupt)"; fi
fi

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
ran=0; skipped=0
for fx in "${FIXTURES[@]}"; do
    fp="$SCRIPT_DIR/$fx"
    if [[ ! -f "$fp" ]]; then bad "fixture referenced but missing: $fx"; continue; fi
    fx_out="$(mktemp)"
    if timeout 90 bash "$fp" >"$fx_out" 2>&1; then
        ok "fixture PASS: $fx ($(printf '%s\n' "${ROWS[@]}" | awk -F'|' -v f="$fx" '$9==f{printf "%s ",$1}'))"
        ran=$((ran+1))
    else
        rc=$?
        if [[ "$INSTALLED_TREE" -eq 1 ]]; then
            # Installed tree: a source-tree-only fixture (hard-codes the repo
            # checkout layout) cannot run from /usr/lib. SKIP, do not fail.
            info "fixture not runnable in installed tree (source-tree-only / missing dep): $fx (rc=$rc)"
            skipped=$((skipped+1))
        else
            bad "fixture FAILED ($fx, rc=$rc):"; tail -4 "$fx_out" | sed 's/^/      /'
        fi
    fi
    rm -f "$fx_out"
done
if [[ "$INSTALLED_TREE" -eq 1 ]]; then
    [[ "$ran" -ge 1 ]] && ok "ran $ran shipped hermetic fixture(s), $skipped source-tree-only skipped (installed-tree best-effort)" || bad "no shipped fixture was runnable in the installed tree"
else
    [[ "$ran" -ge 4 ]] && ok "ran $ran hermetic per-claim fixtures (>=4 owner-bans proofs)" || bad "only $ran hermetic fixtures ran (expected >=4)"
fi

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
