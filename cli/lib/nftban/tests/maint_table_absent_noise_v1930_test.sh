#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.193.0 PR-B - maintenance table-absent transient-noise suppression
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="maint_table_absent_noise_v1930_test"
# meta:type="test"
# meta:version="1.193.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-17"
# meta:description="PR-B: maintenance.sh re-probes the live nftban table before logging 'table absent' — a transient firewall-transition window (table reappears) is suppressed (quiet INFO), while a GENUINE persistent absence still WARNs. Tests _maint_table_absent_confirmed (transient→rc1, genuine→rc0, reappear→rc1) + static guard that both WARN sites are gated. Hermetic: stubbed nft/sleep, no root/nft/host."
# meta:inventory.files="maint_table_absent_noise_v1930_test.sh"
# meta:inventory.binaries="bash,awk,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="maint_table_absent_noise_v1930_test"
# meta:ta.owner="firewall"
# meta:ta.module="maintenance-table-probe"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAINT="$SCRIPT_DIR/../cron/maintenance.sh"
[[ -f "$MAINT" ]] || { echo "FAIL: maintenance.sh not found at $MAINT"; exit 1; }
PASS=0; FAIL=0
ok(){ echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad(){ echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

# Extract just the helper function (no top-level maintenance side effects).
HELPER="$(awk '/^_maint_table_absent_confirmed\(\)/{f=1} f{print} f&&/^\}/{exit}' "$MAINT")"
[[ -n "$HELPER" ]] || { echo "FAIL: _maint_table_absent_confirmed not found"; exit 1; }
eval "$HELPER"
sleep(){ :; }                              # fast: no real delay
export _MAINT_TABLE_RECHECK_SLEEP=0
# NFTBAN_TABLE_IPV4 left unset → the helper uses its ${NFTBAN_TABLE_IPV4:-ip nftban} fallback.

echo "=== T1: GENUINE absence (table never reappears) → rc0 (caller WARNs) ==="
nft(){ return 1; }
if _maint_table_absent_confirmed; then ok "persistent absence → confirmed genuine (rc0 → WARN kept)"; else bad "genuine absence misclassified as transient"; fi

echo "=== T2: table PRESENT on re-probe → rc1 (transient, suppress to INFO) ==="
nft(){ return 0; }
if _maint_table_absent_confirmed; then bad "present table classified genuine-absent"; else ok "table present → transient (rc1 → suppress noisy WARN)"; fi

echo "=== T3: table REAPPEARS mid-grace (fail then present) → rc1 (transient) ==="
_n3=0; nft(){ _n3=$((_n3+1)); [ "$_n3" -ge 2 ] && return 0 || return 1; }
if _maint_table_absent_confirmed; then bad "reappearing table classified genuine-absent (noise would persist)"; else ok "table reappears within grace → transient (rc1 → suppress)"; fi
unset -f nft 2>/dev/null || true

echo "=== T4: static guard — BOTH 'table absent' WARN sites are gated by the recheck ==="
warn_total=$(grep -cE 'log "WARN" "nftban firewall table absent' "$MAINT")
warn_gated=$(grep -B4 -E 'log "WARN" "nftban firewall table absent' "$MAINT" | grep -cE '_maint_table_absent_confirmed')
echo "    table-absent WARN sites=$warn_total  gated-by-recheck=$warn_gated"
[[ "$warn_total" -ge 2 && "$warn_gated" -ge "$warn_total" ]] \
  && ok "every table-absent WARN ($warn_total) is gated by _maint_table_absent_confirmed" \
  || bad "ungated table-absent WARN remains (total=$warn_total gated=$warn_gated)"

echo "=== T5: helper present + def count (1 def + ≥2 callers) ==="
calls=$(grep -cE '_maint_table_absent_confirmed' "$MAINT")
[[ "$calls" -ge 3 ]] && ok "_maint_table_absent_confirmed defined + called at both sites ($calls refs)" || bad "missing helper def/call ($calls)"

echo "=== T6: no harm-counter / firewall-load semantics touched (noise-only guard) ==="
# the PR-B edit must NOT reset counters or alter nft -f / install_state in maintenance.sh
grep -qE 'firewall_transition_health\.json.*>|: > .*firewall_transition_health|table_absent_while_committed_count *=' "$MAINT" \
  && bad "PR-B touched the FW-transition harm counter (must stay authoritative)" \
  || ok "PR-B does not reset/modify the FW-transition harm counter"

echo ""
echo "=== maintenance table-absent noise v1.193.0: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
