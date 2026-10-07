#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - C20: an upgrade STOPS before erasing forward rules NFTBan did not create
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="upgrade_forward_stop_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-07"
# meta:description="C20 (owner D5, 2026-10-06): the package upgrade STOPS before the destructive change it cannot preserve and shows the rules. Drives the REAL nftban_forward_unmanaged_preflight (cli/lib/nftban/lib/nftban_immutable_owned.sh, the maintainer-script library inlined into the DEB scripts and the RPM scriptlets) under /bin/sh against a stub nft. Arms: F1 no nft -> proceed; F2 no nftban table -> proceed; F3 empty forward chain -> proceed; F4 ip forward rules -> STOP (rc 1), every rule listed in the migration plan (UNMAPPED without a route), 'STOPPED'; F5 ip6 rules only -> STOP; F6 forward chain absent -> proceed; F7 chain unreadable (other error) -> STOP as UNKNOWN; F8 NFTBAN_ACCEPT_FORWARD_RULE_LOSS=1 -> proceed with the acceptance line; F9 the DEB preinst calls it for install|upgrade BEFORE the immutable-flag unlock (nothing changed yet) and the RPM %pre calls it with exit 1. Regression only; the packaged proof is an upgrade of a host with a hand-inserted forward rule."
# meta:inventory.files="cli/lib/nftban/lib/nftban_immutable_owned.sh,packaging/deb/preinst,packaging/build_nftban.sh"
# meta:inventory.binaries="bash,sh,mktemp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="upgrade_forward_stop_v1235_test"
# meta:ta.owner="packaging"
# meta:ta.module="upgrade-forward-stop"
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
IFS=$'\n\t'
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
LIB="$REPO/cli/lib/nftban/lib/nftban_immutable_owned.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235 C20: upgrade stops before erasing forward rules NFTBan did not create ==="
[[ -f "$LIB" ]] || { echo "  NOT_EXECUTED: $LIB missing"; echo "RESULT: NOT_EXECUTED"; exit 3; }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/nonft"
# Stub nft driven by files: tables.<fam> present = table exists; fwd.<fam> = chain listing;
# fwderr.<fam> = error text (chain read fails with it).
cat > "$SB/bin/nft" <<'EOF'
#!/bin/sh
case "$1 $2" in
    "list table") [ -e "$SBX/tables.$3" ] && exit 0; echo "Error: No such file or directory" >&2; exit 1 ;;
    "-a list")
        fam="$4"
        if [ -e "$SBX/fwderr.$fam" ]; then cat "$SBX/fwderr.$fam" >&2; exit 1; fi
        if [ -e "$SBX/fwd.$fam" ]; then cat "$SBX/fwd.$fam"; exit 0; fi
        echo "Error: No such file or directory" >&2; exit 1 ;;
esac
exit 0
EOF
chmod +x "$SB/bin/nft"

reset() { rm -f "$SB"/tables.* "$SB"/fwd.* "$SB"/fwderr.*; }
chain() {  # fam rules...
    local fam="$1"; shift
    { printf 'table %s nftban {\n\tchain forward { # handle 2\n\t\ttype filter hook forward priority filter; policy drop;\n' "$fam"
      local r; for r in "$@"; do printf '\t\t%s\n' "$r"; done
      printf '\t}\n}\n'; } > "$SB/fwd.$fam"
}
# run [PATH-dir] [env...] -> rc in $rc, stderr in $SB/err
run() {
    local pathdir="$1"; shift
    rc=0
    env -i PATH="$pathdir:/usr/bin:/bin" SBX="$SB" "$@" sh -c '. "$1"; nftban_forward_unmanaged_preflight' _ "$LIB" 2>"$SB/err" || rc=$?
}

# F1: PATH holds no nft at all
reset; rc=0; env -i PATH="$SB/nonft" SBX="$SB" /bin/sh -c '. "$1"; nftban_forward_unmanaged_preflight' _ "$LIB" 2>"$SB/err" || rc=$?
[[ $rc -eq 0 ]] && ok "F1 no nft -> proceed" || no "F1 no nft" "rc=$rc"

reset; run "$SB/bin"
[[ $rc -eq 0 ]] && ok "F2 no nftban table -> proceed (nothing to erase)" || no "F2 no table" "rc=$rc $(cat "$SB/err")"

reset; : > "$SB/tables.ip"; : > "$SB/tables.ip6"; chain ip; chain ip6; run "$SB/bin"
[[ $rc -eq 0 ]] && ok "F3 empty forward chains -> proceed" || no "F3 empty chain" "rc=$rc $(cat "$SB/err")"

reset; : > "$SB/tables.ip"; : > "$SB/tables.ip6"; chain ip 'ip saddr 198.51.100.0/24 accept # handle 94' 'ct state established,related accept # handle 91'; chain ip6; run "$SB/bin"
if [[ $rc -eq 1 ]] && grep -q 'ip saddr 198.51.100.0/24 accept # handle 94' "$SB/err" && grep -q 'ct state established,related accept # handle 91' "$SB/err" \
   && grep -q 'STOPPED' "$SB/err" && grep -q 'migration plan [0-9a-f]\{12\}' "$SB/err" && grep -q 'UNMAPPED' "$SB/err" && ! grep -q 'chain forward' "$SB/err"; then
    ok "F4 ip forward rules -> STOP, both rules listed in a migration plan (no route for the prefix: UNMAPPED)"
else no "F4 ip rules" "rc=$rc $(tr '\n' '|' < "$SB/err")"; fi

reset; : > "$SB/tables.ip"; : > "$SB/tables.ip6"; chain ip; chain ip6 'ip6 saddr 2001:db8::/32 accept # handle 7'; run "$SB/bin"
[[ $rc -eq 1 ]] && grep -q 'ip6 saddr 2001:db8::/32 accept' "$SB/err" && ok "F5 ip6 forward rules only -> STOP" || no "F5 ip6 rules" "rc=$rc"

reset; : > "$SB/tables.ip"; run "$SB/bin"
[[ $rc -eq 0 ]] && ok "F6 table without a forward chain -> proceed" || no "F6 chain absent" "rc=$rc $(cat "$SB/err")"

reset; : > "$SB/tables.ip"; echo "Error: Could not process rule: Operation not permitted" > "$SB/fwderr.ip"; run "$SB/bin"
[[ $rc -eq 1 ]] && grep -q 'UNKNOWN' "$SB/err" && ok "F7 forward chain unreadable -> STOP as UNKNOWN (destructive change)" || no "F7 unreadable" "rc=$rc"

reset; : > "$SB/tables.ip"; chain ip 'ip saddr 198.51.100.0/24 accept # handle 94'; run "$SB/bin" NFTBAN_ACCEPT_FORWARD_RULE_LOSS=1
[[ $rc -eq 0 ]] && grep -q 'accepts the loss' "$SB/err" && grep -q 'handle 94' "$SB/err" && ok "F8 explicit NFTBAN_ACCEPT_FORWARD_RULE_LOSS=1 -> proceed, rules still listed" || no "F8 override" "rc=$rc"

# F9: call sites, before anything changes
PRE="$REPO/packaging/deb/preinst"; SPEC="$REPO/packaging/build_nftban.sh"
l_call=$(grep -n -m1 'if ! nftban_forward_unmanaged_preflight; then' "$PRE" | cut -d: -f1)
l_unlock=$(grep -n -m1 'nftban_immut_unlock_owned |' "$PRE" | cut -d: -f1)
if [[ -n "$l_call" && -n "$l_unlock" && "$l_call" -lt "$l_unlock" ]] && grep -q '^nftban_forward_unmanaged_preflight || exit 1$' "$SPEC"; then
    ok "F9 DEB preinst calls it before the immutable unlock; RPM %pre calls it with exit 1"
else no "F9 call sites" "deb call=$l_call unlock=$l_unlock rpm=$(grep -c 'nftban_forward_unmanaged_preflight || exit 1' "$SPEC")"; fi

echo ""
echo "RESULT: $([[ $FAIL -eq 0 ]] && echo PASS || echo FAIL) (pass=$PASS fail=$FAIL)"
[[ $FAIL -eq 0 ]]
