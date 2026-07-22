#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.169 CLI-BUG-3: `whitelist list` timed/session vs durable labeling
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="whitelist_list_timed_label_v169_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-09"
# meta:description="Locks v1.169 CLI-BUG-3: nftban whitelist list must LABEL timed/session entries distinctly from durable ones. Since v1.168 a timed kernel element renders as '1.2.3.4 timeout 30m expires 29m55s'; the pre-v1.169 list printed that raw text appended to the IP, unlabeled. Exercises the two pure formatters sourced from cmd_whitelist.sh: nftban_whitelist_fmt_element (labels TIMED (expires in …) vs DURABLE, IP first) and nftban_whitelist_bare_ip (strips the timeout suffix so --json values stay valid IPs). Hermetic: sources the real cmd_whitelist.sh from the repo with NFTBAN_LIB_DIR pointed at the repo tree; no nft, no host, no root, no writes."
# meta:input="None (sources repo cmd_whitelist.sh, calls pure formatters)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep"
# meta:inventory.files="cli/lib/nftban/cli/cmd_whitelist.sh"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="whitelist_list_timed_label_v169_test"
# meta:ta.owner="whitelist"
# meta:ta.module="whitelist"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
WL_SRC="$REPO_ROOT/cli/lib/nftban/cli/cmd_whitelist.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

[[ -f "$WL_SRC" ]] || { echo "source not found: $WL_SRC"; exit 1; }

# Run a formatter in a subshell that sources the real module against the repo
# tree (avoids the installed /usr/lib path + the direct-exec tail guard).
fmt(){ NFTBAN_LIB_DIR="$REPO_ROOT/cli/lib/nftban" bash -c '
  source "'"$WL_SRC"'" >/dev/null 2>&1 || true
  nftban_whitelist_fmt_element "$1"' _ "$1"; }
bare(){ NFTBAN_LIB_DIR="$REPO_ROOT/cli/lib/nftban" bash -c '
  source "'"$WL_SRC"'" >/dev/null 2>&1 || true
  nftban_whitelist_bare_ip "$1"' _ "$1"; }

echo "=== nftban_whitelist_fmt_element: timed entry is LABELED (not raw) ==="
out=$(fmt "203.0.113.77 timeout 30m expires 29m55s102ms")
if grep -q "203.0.113.77" <<<"$out" && grep -q "TIMED" <<<"$out" && grep -q "expires in 29m55s102ms" <<<"$out"; then
  ok "timed → 'TIMED (expires in 29m55s102ms)' (${out//[[:space:]]/ })"
else
  no "timed entry not labeled correctly" "${out//[[:space:]]/ }"
fi
# the raw 'timeout 30m expires' run must NOT appear verbatim after the IP
if grep -qE '203\.0\.113\.77[[:space:]]+timeout 30m expires' <<<"$out"; then
  no "raw 'timeout … expires …' still printed verbatim (CLI-BUG-3 not fixed)"
else
  ok "raw nft timeout text not printed verbatim"
fi

echo "=== durable (bare) entry is LABELED DURABLE, no TIMED ==="
out=$(fmt "192.168.1.5")
if grep -q "192.168.1.5" <<<"$out" && grep -q "DURABLE" <<<"$out" && ! grep -q "TIMED" <<<"$out"; then
  ok "durable → DURABLE (${out//[[:space:]]/ })"
else
  no "durable entry mislabeled" "${out//[[:space:]]/ }"
fi

echo "=== timed without expires token (edge) → TIMED, no crash ==="
out=$(fmt "10.0.0.1 timeout 30m")
if grep -q "10.0.0.1" <<<"$out" && grep -q "TIMED" <<<"$out"; then
  ok "timed-no-expires → TIMED (${out//[[:space:]]/ })"
else
  no "timed-no-expires mishandled" "${out//[[:space:]]/ }"
fi

echo "=== nftban_whitelist_bare_ip strips timeout suffix (valid --json value) ==="
b=$(bare "203.0.113.77 timeout 30m expires 29m55s")
if [[ "$b" == "203.0.113.77" ]]; then ok "timed → bare '203.0.113.77'"; else no "bare_ip(timed)='$b' want 203.0.113.77"; fi
b=$(bare "192.168.1.5")
if [[ "$b" == "192.168.1.5" ]]; then ok "bare → '192.168.1.5'"; else no "bare_ip(bare)='$b' want 192.168.1.5"; fi

echo "================================================================"
echo "whitelist_list_timed_label_v169_test: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
