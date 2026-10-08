#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - forward migration: one mapper, plan approval by id, STOP otherwise
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="forward_migration_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-08"
# meta:description="Owner 2026-10-08 forward migration conditions. Drives the REAL package entry point nftban_forward_unmanaged_preflight and the shared mapper (cli/lib/nftban/lib/nftban_immutable_owned.sh) under /bin/sh with a stub nft (forward chain listing) and a stub ip (routes), plus the CLI nftban_forward_migrate (lib/nftban_forward.sh). Arms: M1 srv1-shaped unmanaged rules without approval -> STOP, plan + id + exact approve command printed, store NOT written; M2 NFTBAN_FORWARD_MIGRATE=<that id> -> proceed, store holds egress for both bridges + the uplink (deduplicated), every DIFF printed; M3 wrong id -> STOP, store unchanged; M4 an UNMAPPED rule -> STOP even with that plan's id; M5 a prefix that is not exactly one interface -> UNMAPPED -> STOP; M6 an invalid existing record -> STOP, store bytes unchanged; M7 only NFTBan-tagged rules -> proceed, no plan; M8 store dir not writable -> STOP, nothing written; M9 the plan id ignores rule handles (stable); M10 the CLI migrate prints the SAME plan id as the package path; M10b the same with TWO uplinks and the CLI under the real strict.sh IFS (audit H10). Regression only; continuity of traffic is proven in the Docker lab."
# meta:inventory.files="cli/lib/nftban/lib/nftban_immutable_owned.sh,cli/lib/nftban/lib/nftban_forward.sh"
# meta:inventory.binaries="bash,sh,mktemp,sha256sum"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="forward_migration_v1235_test"
# meta:ta.owner="firewall"
# meta:ta.module="forward-migration"
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
LIBDIR="$REPO/cli/lib/nftban"
LIB="$LIBDIR/lib/nftban_immutable_owned.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235 forward migration (owner conditions 2026-10-08) ==="
[[ -f "$LIB" && -f "$LIBDIR/lib/nftban_forward.sh" ]] || { echo "  NOT_EXECUTED: subject missing"; echo "RESULT: NOT_EXECUTED"; exit 3; }
command -v sha256sum >/dev/null 2>&1 || { echo "  NOT_EXECUTED: sha256sum missing"; echo "RESULT: NOT_EXECUTED"; exit 3; }

SB="$(mktemp -d)"
trap 'chmod u+w "$SB/etc/forward.d" 2>/dev/null; rm -rf "$SB"' EXIT   # M8 makes only this dir read-only
mkdir -p "$SB/bin" "$SB/etc"
cat > "$SB/bin/nft" <<'EOF'
#!/bin/sh
[ "$1 $2 $3" = "-a list chain" ] || exit 0
f="$SBX/fwd.$4"; [ -e "$f" ] && { cat "$f"; exit 0; }
echo "Error: No such file or directory" >&2; exit 1
EOF
cat > "$SB/bin/ip" <<'EOF'
#!/bin/sh
# ip -o -4|-6 route show default | ip -o -4|-6 route show exact <prefix>
fam="$2"
case "$5" in
    default) [ -e "$SBX/default$fam" ] && cat "$SBX/default$fam"; exit 0 ;;
    exact) k=$(printf '%s' "$6" | tr '/:' '__'); [ -e "$SBX/route$k" ] && cat "$SBX/route$k"; exit 0 ;;
esac
exit 0
EOF
chmod +x "$SB/bin/nft" "$SB/bin/ip"

chain() {  # fam rules...
    local fam="$1"; shift
    { printf 'table %s nftban {\n\tchain forward { # handle 2\n\t\ttype filter hook forward priority filter; policy drop;\n' "$fam"
      local r; for r in "$@"; do printf '\t\t%s\n' "$r"; done; printf '\t}\n}\n'; } > "$SB/fwd.$fam"
}
fresh() {
    rm -rf "${SB:?}/etc" "${SB:?}"/fwd.* "${SB:?}"/route* "${SB:?}"/default*; mkdir -p "$SB/etc"
    printf 'default via 192.0.2.1 dev eth0 proto static\n' > "$SB/default-4"
    printf '172.18.0.0/16 dev br-938df9175c79 proto kernel scope link src 172.18.0.1\n' > "$SB/route172.18.0.0_16"
    printf '172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1 linkdown\n' > "$SB/route172.17.0.0_16"
}
SRV1=( 'ip saddr 172.18.0.0/16 accept # handle 94' 'ip saddr 172.18.0.0/16 accept # handle 93' 'ip saddr 172.17.0.0/16 accept # handle 92'
       'ct state established,related accept # handle 91' 'ct state established,related accept # handle 90' 'ip saddr 172.17.0.0/16 accept # handle 89' )
pre() {  # env... -> rc, stderr in $SB/err
    rc=0
    env -i PATH="$SB/bin:/usr/bin:/bin" SBX="$SB" NFTBAN_CONFIG_DIR="$SB/etc" "$@" \
        sh -c '. "$1"; nftban_forward_unmanaged_preflight' _ "$LIB" 2>"$SB/err" || rc=$?
}
plan_id() { sed -n 's/^nftban: migration plan \([0-9a-f]\{12\}\) .*/\1/p;T;q' "$SB/err"; }
STORE="$SB/etc/forward.d/forward.conf"

fresh; chain ip "${SRV1[@]}"; pre
ID=$(plan_id)
if [[ $rc -eq 1 && -n "$ID" ]] && grep -q "NFTBAN_FORWARD_MIGRATE=$ID" "$SB/err" && grep -q 'RECORD egress|br-938df9175c79' "$SB/err" \
   && grep -q 'RECORD egress|docker0' "$SB/err" && grep -q 'NOT EQUIVALENT' "$SB/err" && [[ ! -e "$STORE" ]]; then
    ok "M1 srv1-shaped rules, no approval -> STOP; plan $ID with DIFFs and the exact approve command; store NOT written"
else no "M1 no approval" "rc=$rc id=$ID store=$([[ -e "$STORE" ]] && echo written || echo none)"; fi

pre NFTBAN_FORWARD_MIGRATE="$ID"
if [[ $rc -eq 0 && -f "$STORE" ]] && [[ $(grep -c '^egress|br-938df9175c79|' "$STORE") -eq 1 && $(grep -c '^egress|docker0|' "$STORE") -eq 1 && $(grep -c '^uplink|eth0|' "$STORE") -eq 1 ]] \
   && grep -q 'DIFF bans are evaluated BEFORE the return path' "$SB/err"; then
    ok "M2 NFTBAN_FORWARD_MIGRATE=<plan id> -> proceed; store: egress x2 + uplink eth0, each once (deduplicated)"
else no "M2 approved" "rc=$rc store=$(tr '\n' ';' < "$STORE" 2>/dev/null)"; fi

fresh; chain ip "${SRV1[@]}"; pre NFTBAN_FORWARD_MIGRATE=000000000000
[[ $rc -eq 1 && ! -e "$STORE" ]] && grep -q 'does not match this plan' "$SB/err" && ok "M3 wrong plan id -> STOP, nothing written" || no "M3 wrong id" "rc=$rc"

fresh; chain ip "${SRV1[@]}" 'tcp dport 22 accept # handle 95'; pre; ID4=$(plan_id); pre NFTBAN_FORWARD_MIGRATE="$ID4"
[[ $rc -eq 1 && ! -e "$STORE" ]] && grep -q 'UNMAPPED' "$SB/err" && ok "M4 an UNMAPPED rule -> STOP even with that plan's id; nothing written" || no "M4 unmapped" "rc=$rc"

fresh; chain ip 'ip saddr 198.51.100.0/24 accept # handle 7'; pre; ID5=$(plan_id); pre NFTBAN_FORWARD_MIGRATE="$ID5"
[[ $rc -eq 1 && ! -e "$STORE" ]] && grep -q 'not the network of exactly one interface' "$SB/err" && ok "M5 prefix not exactly one interface -> UNMAPPED -> STOP" || no "M5 no route" "rc=$rc"

fresh; chain ip "${SRV1[@]}"; mkdir -p "$SB/etc/forward.d"; printf 'egress|docker0|x|y\nnonsense|line\n' > "$STORE"; before=$(sha256sum "$STORE")
pre; ID6=$(plan_id); pre NFTBAN_FORWARD_MIGRATE="$ID6"
[[ $rc -eq 1 && "$(sha256sum "$STORE")" == "$before" ]] && grep -q 'invalid record' "$SB/err" && ok "M6 invalid existing record -> STOP, store bytes unchanged" || no "M6 invalid store" "rc=$rc"

fresh; chain ip 'ct state established,related counter packets 0 bytes 0 accept comment "nftban:fwd:ct" # handle 5'; pre
[[ $rc -eq 0 ]] && ! grep -q 'migration plan' "$SB/err" && ok "M7 only NFTBan-tagged rules -> proceed, no plan" || no "M7 managed only" "rc=$rc"

if [[ $(id -u) -ne 0 ]]; then
    fresh; chain ip "${SRV1[@]}"; mkdir -p "$SB/etc/forward.d"; chmod a-w "$SB/etc/forward.d"; pre; ID8=$(plan_id); pre NFTBAN_FORWARD_MIGRATE="$ID8"
    chmod u+w "$SB/etc/forward.d"
    [[ $rc -eq 1 && ! -e "$STORE" ]] && ok "M8 store dir not writable -> STOP, nothing written" || no "M8 unwritable" "rc=$rc"
else
    echo "  [NOT_EXECUTED] M8 unwritable store dir (root ignores directory permissions)"
fi

fresh; chain ip "${SRV1[@]}"; pre; a=$(plan_id)
chain ip 'ip saddr 172.18.0.0/16 accept # handle 194' 'ip saddr 172.18.0.0/16 accept # handle 193' 'ip saddr 172.17.0.0/16 accept # handle 192' \
         'ct state established,related accept # handle 191' 'ct state established,related accept # handle 190' 'ip saddr 172.17.0.0/16 accept # handle 189'; pre; b=$(plan_id)
[[ -n "$a" && "$a" == "$b" ]] && ok "M9 plan id is stable across rule handles ($a)" || no "M9 plan id" "$a vs $b"

fresh; chain ip "${SRV1[@]}"; pre; pid=$(plan_id)
cid=$(env -i PATH="$SB/bin:/usr/bin:/bin" SBX="$SB" NFTBAN_CONFIG_DIR="$SB/etc" NFTBAN_LIB_DIR="$LIBDIR" \
    bash -c 'source "$1/lib/nftban_forward.sh"; nftban_forward_migrate' _ "$LIBDIR" 2>/dev/null | sed -n 's/^Migration plan \([0-9a-f]\{12\}\) .*/\1/p' | sed -n 1p)
[[ -n "$pid" && "$cid" == "$pid" ]] && ok "M10 CLI migrate prints the SAME plan id as the package path ($pid)" || no "M10 CLI vs package" "cli=$cid pkg=$pid"

# M10b (audit H10, 2026-10-08): TWO uplinks, and the CLI side under the REAL CLI shell setup
# (lib/strict.sh: IFS=$'\n\t'). The mapper splits the uplink list on whitespace; under the CLI's
# IFS a space-separated list did not split, so the CLI and the package could print different ids.
fresh; printf 'default via 2001:db8::1 dev eth1 proto static metric 1024\n' > "$SB/default-6"
chain ip "${SRV1[@]}"; pre; pid2=$(plan_id); nrec=$(grep -o 'RECORD uplink|[A-Za-z0-9_.:-]*' "$SB/err" | sort -u | wc -l)
cid2=$(env -i PATH="$SB/bin:/usr/bin:/bin" SBX="$SB" NFTBAN_CONFIG_DIR="$SB/etc" NFTBAN_LIB_DIR="$LIBDIR" \
    bash -c 'source "$1/lib/strict.sh" >/dev/null 2>&1; source "$1/lib/nftban_forward.sh"; nftban_forward_migrate' _ "$LIBDIR" 2>/dev/null | sed -n 's/^Migration plan \([0-9a-f]\{12\}\) .*/\1/p' | sed -n 1p)
[[ "$nrec" -eq 2 && -n "$pid2" && "$cid2" == "$pid2" ]] && ok "M10b two uplinks: the package records both distinct uplinks, and the CLI under strict.sh prints the SAME plan id ($pid2)" \
    || no "M10b two uplinks" "package uplink records=$nrec cli=$cid2 pkg=$pid2"

echo ""
echo "RESULT: $([[ $FAIL -eq 0 ]] && echo PASS || echo FAIL) (pass=$PASS fail=$FAIL)"
[[ $FAIL -eq 0 ]]
