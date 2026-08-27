#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="capability_management_access_v1229_12_test" meta:type="test" meta:version="1.229.12" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="B03 E05 adapter: durable/projection/rule-order states with unreadable-evidence inversions"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
set -uo pipefail
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
# shellcheck source=/dev/null
source "$LIB/capability.sh"
# shellcheck source=/dev/null
source "$LIB/capability_management_access.sh"
SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
export NFTBAN_CONFIG_DIR="$SB"; mkdir -p "$SB/whitelist.d"
ADDR="203.0.113.200"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }
want(){ local got; got=$(nftban_capability_management_access "$2")
        [[ "${got%% *}" == "$1" ]] && ok "$3 -> $1" || no "$3 expected=$1 got='${got%% *}' (${got})"; }

# Stub nft so the adapter's projection/order reads are controllable.
PROJ=""; ORDER=""
nft(){
  case "$*" in
    *"list set"*whitelist*) [[ "$PROJ" == "unreadable" ]] && return 1
                            [[ "$PROJ" == "present" ]] && { echo "set whitelist_ipv4 { elements = { $ADDR } }"; return 0; }
                            echo "set whitelist_ipv4 { elements = { 198.51.100.1 } }"; return 0 ;;
    *"list chain"*input*)   [[ "$ORDER" == "unreadable" ]] && return 1
                            if [[ "$ORDER" == "inverted" ]]; then
                              echo "ip saddr @blacklist_ipv4 drop"; echo "ip saddr @whitelist_ipv4 accept"
                            else
                              echo "ip saddr @whitelist_ipv4 accept"; echo "ip saddr @blacklist_ipv4 drop"
                            fi; return 0 ;;
  esac; return 1; }
export -f nft 2>/dev/null || true

echo "== CAPABLE: durable + projected + correct order =="
echo "$ADDR" > "$SB/whitelist.d/00-local.conf"; PROJ=present; ORDER=correct
want CAPABLE "$ADDR" "durable + projected + accept-before-drop"

echo "== DEGRADED: the LIVE dns4 shape — declared but not projected =="
PROJ=absent; ORDER=correct
want DEGRADED "$ADDR" "durable YES, projection NO"

echo "== DEGRADED: projected but not durable — a rebuild may drop it =="
rm -f "$SB/whitelist.d/00-local.conf"; echo "198.51.100.9" > "$SB/whitelist.d/00-local.conf"
PROJ=present; ORDER=correct
want DEGRADED "$ADDR" "projection YES, durable NO"

echo "== DEGRADED: projected and durable, but DROP precedes ACCEPT =="
echo "$ADDR" > "$SB/whitelist.d/00-local.conf"; PROJ=present; ORDER=inverted
want DEGRADED "$ADDR" "rule order inverted"

echo "== INCAPABLE: absent from BOTH authorities =="
rm -f "$SB/whitelist.d/00-local.conf"; echo "198.51.100.9" > "$SB/whitelist.d/00-local.conf"
PROJ=absent; ORDER=correct
want INCAPABLE "$ADDR" "durable NO, projection NO"

echo "== UNKNOWN: evidence unreadable is NEVER a pass =="
echo "$ADDR" > "$SB/whitelist.d/00-local.conf"; PROJ=unreadable; ORDER=correct
want UNKNOWN "$ADDR" "projection set unreadable"
PROJ=present; ORDER=unreadable
want UNKNOWN "$ADDR" "input chain unreadable"
PROJ=present; ORDER=correct
export NFTBAN_CONFIG_DIR="$SB/nonexistent"
want UNKNOWN "$ADDR" "durable authority directory unreadable"
export NFTBAN_CONFIG_DIR="$SB"

echo "== UNKNOWN: no resolvable management address =="
( unset SSH_CLIENT SSH_CONNECTION
  got=$(nftban_capability_management_access "")
  [[ "${got%% *}" == "UNKNOWN" ]] ) && ok "no address resolvable -> UNKNOWN" || no "no address should be UNKNOWN"

echo "== the adapter OBSERVES ONLY — it must not mutate =="
before=$(find "$SB" -type f | sort | md5sum)
PROJ=absent; nftban_capability_management_access "$ADDR" >/dev/null
after=$(find "$SB" -type f | sort | md5sum)
[[ "$before" == "$after" ]] && ok "no files created or removed by observation" || no "adapter mutated config state"

echo
echo "TOTAL: pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
