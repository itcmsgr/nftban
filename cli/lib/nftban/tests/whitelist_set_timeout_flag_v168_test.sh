#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.168 CLI-BUG-2: whitelist sets carry the 'timeout' flag (render)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="whitelist_set_timeout_flag_v168_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-09"
# meta:description="Locks the v1.168 CLI-BUG-2 render prerequisite: the four whitelist set declarations — whitelist_ipv4 + whitelist_ipv6 in BOTH the static boot-baseline install/nftables/nftables.conf AND the rebuild template install/nftables/nftables.conf.tpl — must declare 'flags interval, timeout' (not 'flags interval' alone). Without the timeout flag the kernel set cannot hold a per-element timeout, so 'whitelist add --ttl' entries can never expire in-kernel. The blacklist sets already carry interval+timeout; this aligns whitelist. Necessary-but-not-sufficient on its own: the daemon-Go timeout sync (loader ExpiresAt -> GetWhitelistSnapshotWithExpiry -> FullSync AddIPWithTimeout) is the runtime authority; see the Go guard TestRemainingTimeout_TTLSurvivesFullSync. If the 'nft' binary is available the rendered static file is also syntax-checked (nft -c)."
# meta:input="None (reads repo source files read-only)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep,awk,nft(optional)"
# meta:inventory.files="install/nftables/nftables.conf,install/nftables/nftables.conf.tpl"
# meta:inventory.binaries="bash,grep,awk,nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="whitelist_set_timeout_flag_v168_test"
# meta:ta.owner="whitelist"
# meta:ta.module="whitelist-set-timeout-flag"
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
CONF="$REPO_ROOT/install/nftables/nftables.conf"
TPL="$REPO_ROOT/install/nftables/nftables.conf.tpl"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

# assert_set_has_timeout <file> <setname>
# Within the named set block, the 'flags' line must include 'timeout'.
assert_set_has_timeout(){
  local file="$1" set="$2"
  local flags
  flags=$(awk -v want="$set" '
    $0 ~ "set " want " \\{" { inblock=1; next }
    inblock && /^[[:space:]]*flags/ { print; inblock=0 }
    inblock && /^[[:space:]]*\}/ { inblock=0 }
  ' "$file")
  if [[ -z "$flags" ]]; then
    no "$(basename "$file"): $set has no flags line"
  elif grep -qE '\btimeout\b' <<< "$flags"; then
    ok "$(basename "$file"): $set flags carry timeout (${flags//[[:space:]]/ })"
  else
    no "$(basename "$file"): $set flags MISSING timeout" "${flags//[[:space:]]/ }"
  fi
}

for f in "$CONF" "$TPL"; do
  [[ -f "$f" ]] || { echo "file not found: $f"; exit 1; }
done

echo "=== whitelist sets declare 'timeout' flag (static + template) ==="
assert_set_has_timeout "$CONF" "whitelist_ipv4"
assert_set_has_timeout "$CONF" "whitelist_ipv6"
assert_set_has_timeout "$TPL"  "whitelist_ipv4"
assert_set_has_timeout "$TPL"  "whitelist_ipv6"

echo "=== regression: no whitelist set left as bare 'flags interval' ==="
# A whitelist flags line of exactly 'flags interval' (no timeout) is the bug.
if awk '
  /set whitelist_ipv[46] \{/ { inblock=1; next }
  inblock && /^[[:space:]]*flags[[:space:]]+interval[[:space:]]*$/ { found=1 }
  inblock && /^[[:space:]]*\}/ { inblock=0 }
  END { exit(found?0:1) }
' "$CONF" "$TPL"; then
  no "a whitelist set still declares bare 'flags interval' (no timeout)"
else
  ok "no whitelist set declares bare 'flags interval'"
fi

echo "=== (optional) nft -c syntax check of static boot-baseline ==="
# nft -c -f on a full ruleset still initializes the netlink cache, which needs
# root/CAP_NET_ADMIN. Only attempt it as root (CI/lab); otherwise skip — the
# hermetic grep assertions above are the hard gate, this is best-effort.
if ! command -v nft >/dev/null 2>&1; then
  echo "  • nft not installed — skipping syntax check (hermetic grep checks still ran)"
elif [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "  • not root — skipping nft -c (needs CAP_NET_ADMIN; runs in CI/lab as root)"
elif nft -c -f "$CONF" >/dev/null 2>&1; then
  ok "nft -c accepts $CONF"
else
  no "nft -c rejected $CONF" "$(nft -c -f "$CONF" 2>&1 | head -1)"
fi

echo "================================================================"
echo "whitelist_set_timeout_flag_v168_test: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
