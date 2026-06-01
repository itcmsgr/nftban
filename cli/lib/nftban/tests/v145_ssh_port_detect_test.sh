#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.145 - PR-B SSH-port detection wrapper tests
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v145_ssh_port_detect_test" meta:type="test" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Unit tests for cli/lib/nftban/lib/ssh_port_detect.sh — the ListenAddress-aware pure-bash helper (_nftban_listenaddr_port) and the conservative fallback union (_nftban_ssh_detect_fallback). The Go binary is the primary authority and is covered by internal/installer/detect/ssh_test.go; these cover the install-transition shell fallback."
# meta:input="None (self-contained; temp sshd_config fixtures)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,awk,sort,mktemp"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,awk,sort,mktemp"
# meta:inventory.env_vars="NFTBAN_SSHD_CONFIG,NFTBAN_SSHD_CONFIG_D,NFTBAN_DATA_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/cli/lib/nftban/lib/ssh_port_detect.sh"

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }

echo "== _nftban_listenaddr_port forms =="
check_la() { # token expected
    local got; got=$(_nftban_listenaddr_port "$1")
    if [[ "$got" == "$2" ]]; then ok "'$1' -> '${got:-<none>}'"; else bad "'$1' -> got '$got' want '$2'"; fi
}
check_la "0.0.0.0:22" "22"
check_la "192.0.2.10:55000" "55000"
check_la "[::]:22" "22"
check_la "[2001:db8::10]:55000" "55000"
check_la "0.0.0.0" ""
check_la "::" ""
check_la "2001:db8::10" ""   # bare IPv6 no-port trap

echo "== fallback union (config sources; ss may add host port) =="
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
printf 'Port 22\nListenAddress 0.0.0.0:22\nListenAddress [::]:55000\nListenAddress 2001:db8::10\n' > "$tmp/sshd_config"
export NFTBAN_SSHD_CONFIG="$tmp/sshd_config" NFTBAN_SSHD_CONFIG_D="$tmp/none" \
       NFTBAN_DATA_DIR="$tmp" NFTBAN_CONFIG_DIR="$tmp"
out=$(_nftban_ssh_detect_fallback)
has() { grep -qx "$2" <<<"$1"; }
if has "$out" 22;    then ok "union contains 22";    else bad "union missing 22"; fi
if has "$out" 55000; then ok "union contains 55000"; else bad "union missing 55000"; fi
if has "$out" 10;    then bad "bare-IPv6 port 10 leaked"; else ok "bare-IPv6 port 10 not leaked"; fi
# sorted-unique: 22 must appear exactly once despite Port+ListenAddress both = 22
if [[ "$(grep -cx 22 <<<"$out")" == "1" ]]; then ok "22 de-duplicated (exactly one)"; else bad "22 not de-duplicated"; fi

# conf.local SSH_PORT source
printf 'SSH_PORT="2200"\n' > "$tmp/nftban.conf.local"
out2=$(_nftban_ssh_detect_fallback)
if has "$out2" 2200; then ok "conf.local SSH_PORT picked up"; else bad "conf.local SSH_PORT missed"; fi

echo
echo "RESULT: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
