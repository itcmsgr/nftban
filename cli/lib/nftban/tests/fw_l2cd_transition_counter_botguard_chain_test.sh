#!/usr/bin/env bash
# =============================================================================
# NFTBan - L2c+L2d guard: transition fail-open counter wiring + BotGuard chain name
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="fw_l2cd_transition_counter_botguard_chain_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-06"
# meta:description="Guards the L2c+L2d shell fixes. L2c: the firewall rebuild wires the existing transition-health blacklist-empty fail-open counter (fth_note_blacklist_empty) — fires only when the blacklist held bans before the rebuild but is empty after restore; also unit-tests the _fw_count_dump_elems element counter (multiline-safe). L2d: the BotGuard rebuild check uses the real chain name (http_bot_guard / BOTGUARD_NFT_CHAIN), not the nonexistent botguard_filter. Hermetic: greps the shipped source + extracts one function; no host/nft/IPC/daemon."
# meta:input="None (self-contained)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep"
# meta:inventory.files="cli/lib/nftban/cli/cmd_firewall.sh"
# meta:inventory.binaries="bash,awk,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
FW="$REPO_ROOT/cli/lib/nftban/cli/cmd_firewall.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
[[ -f "$FW" ]] || { echo "FATAL: $FW not found" >&2; exit 2; }

# ---- L2d: BotGuard chain-name drift ----
grep -qE 'nft list chain ip nftban botguard_filter' "$FW" \
  && no "L2d: stale botguard_filter chain check still present" \
  || ok "L2d: stale botguard_filter chain check removed"
grep -qE 'BOTGUARD_NFT_CHAIN:-http_bot_guard' "$FW" \
  && ok "L2d: BotGuard check uses real chain (BOTGUARD_NFT_CHAIN:-http_bot_guard)" \
  || no "L2d: real BotGuard chain name not referenced in rebuild check"

# ---- L2c: fail-open counter wiring ----
grep -qE 'fth_note_blacklist_empty "\$_bl_before"' "$FW" \
  && ok "L2c: fth_note_blacklist_empty wired into rebuild" \
  || no "L2c: fth_note_blacklist_empty not called from rebuild"
# fires only on had-bans-before AND empty-after (not 'currently empty')
grep -qE '\$_bl_before" -gt 0 && "\$_rs_total" -eq 0' "$FW" \
  && ok "L2c: guard is (before>0 && restored==0) — harm-keyed, not 'currently empty'" \
  || no "L2c: fail-open condition not (before>0 && restored==0)"

# ---- L2c: _fw_count_dump_elems correctness (extract + run) ----
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FN="$WORK/fn.sh"
awk '/^_fw_count_dump_elems\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$FW" > "$FN"
grep -q '_fw_count_dump_elems()' "$FN" && ok "extracted _fw_count_dump_elems()" || no "could not extract _fw_count_dump_elems()"
# shellcheck source=/dev/null
source "$FN"

D="$WORK/set.nft"
printf 'table ip nftban {\n\tset blacklist_manual_ipv4 {\n\t\telements = { 1.2.3.4 timeout 1h expires 59m,\n\t\t\t5.6.7.8 timeout 2h expires 1h,\n\t\t\t9.9.9.9 timeout 30m expires 5m }\n\t}\n}\n' > "$D"
c=$(_fw_count_dump_elems "$D")
[[ "$c" == "3" ]] && ok "counts 3 elements in a wrapped/multiline dump" || no "wrong element count" "got=$c want=3"

printf 'table ip nftban {\n\tset blacklist_ipv4 {\n\t\telements = { 10.0.0.0/8 }\n\t}\n}\n' > "$WORK/one.nft"
[[ "$(_fw_count_dump_elems "$WORK/one.nft")" == "1" ]] && ok "counts 1 (single CIDR)" || no "single-element count wrong"

printf 'table ip nftban {\n\tset blacklist_ipv4 {\n\t\ttype ipv4_addr\n\t}\n}\n' > "$WORK/empty.nft"
[[ "$(_fw_count_dump_elems "$WORK/empty.nft")" == "0" ]] && ok "counts 0 (no elements block)" || no "empty-set count wrong"
[[ "$(_fw_count_dump_elems "$WORK/missing.nft")" == "0" ]] && ok "counts 0 (missing file)" || no "missing-file count wrong"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
