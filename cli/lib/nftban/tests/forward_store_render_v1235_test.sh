#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - forwarding store, render projection and CLI (owner D1-D4, Q1/Q2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="forward_store_render_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-08"
# meta:description="v1.235 forwarding (owner D1-D4; bans Q1/Q2 2026-10-08). Drives the REAL lib/nftban_forward.sh and the REAL _firewall_substitute_placeholders over the REAL template. S1 store validation: bad type, port 0/08/65536, bad family, bad v4/v6 source, bad interface name are each refused; valid records accepted. S2 an empty store renders no element line and leaves no placeholder. S3 records render into the right sets: egress/uplink in both families, publish tcp/udp per family, 'any' = 0.0.0.0/0 and ::/0. S4 an invalid store line is reported and skipped at render (never guessed). S5 an unreadable store REFUSES the render. S6 the forward chain order in the template is bans (whitelist exemption, never an accept) -> return path -> invalid -> egress -> publish, every rule tagged nftban:fwd:, policy drop, both families. S7 add/remove write atomically and deduplicate (same key = already present). S8 allow egress refuses an unrecognised bridge (no override). S9 the template does not contain a whitelist ACCEPT in the forward chain. Parse/behaviour of the rendered ruleset is proven on labs (nft -c, netns), not here."
# meta:inventory.files="cli/lib/nftban/lib/nftban_forward.sh,cli/lib/nftban/cli/cmd_firewall.sh,install/nftables/nftables.conf.tpl"
# meta:inventory.binaries="bash,mktemp,awk"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="forward_store_render_v1235_test"
# meta:ta.owner="firewall"
# meta:ta.module="forward-policy"
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
TPL="$REPO/install/nftables/nftables.conf.tpl"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235 forwarding store, render and CLI ==="
[[ -f "$LIBDIR/lib/nftban_forward.sh" && -f "$TPL" ]] || { echo "  NOT_EXECUTED: subject missing"; echo "RESULT: NOT_EXECUTED"; exit 3; }
SB="$(mktemp -d)"
trap 'chmod -R u+w "$SB" 2>/dev/null; rm -rf "$SB"' EXIT
mkdir -p "$SB/etc/forward.d" "$SB/bin"
cat > "$SB/bin/id" <<'EOF'
#!/bin/sh
[ "$1" = "-u" ] && { echo 0; exit 0; }
exec /usr/bin/id "$@"
EOF
chmod +x "$SB/bin/id"
STORE="$SB/etc/forward.d/forward.conf"
lib() { env -i PATH="$SB/bin:/usr/bin:/bin" HOME="$SB" NFTBAN_CONFIG_DIR="$SB/etc" NFTBAN_LIB_DIR="$LIBDIR" bash -c 'source "$1/lib/nftban_forward.sh"; shift; eval "$*"' _ "$LIBDIR" "$@"; }
render() { env -i PATH="/usr/bin:/bin" HOME="$SB" NFTBAN_CONFIG_DIR="$SB/etc" NFTBAN_LIB_DIR="$LIBDIR" \
    bash -c 'source "$1/cli/cmd_firewall.sh" >/dev/null 2>&1; _firewall_substitute_placeholders "$2" "$3"' _ "$LIBDIR" "$TPL" "$1"; }

# S1 validation
bad=0
for r in 'bogus|x' 'egress|bad name' 'egress|waytoolongifname0' 'publish|sctp|80|4|any' 'publish|tcp|0|4|any' 'publish|tcp|08|4|any' \
         'publish|tcp|65536|4|any' 'publish|tcp|80|5|any' 'publish|tcp|80|4|300.1.1.1' 'publish|tcp|80|4|192.0.2.0/33' 'publish|tcp|80|6|192.0.2.1'; do
    lib "nftban_forward_valid_record '$r'" >/dev/null 2>&1 && { bad=1; echo "      accepted (wrong): $r"; }
done
good=0
for r in 'egress|docker0' 'uplink|eth0' 'publish|tcp|15432|4|192.0.2.0/24' 'publish|udp|53|6|2001:db8::/32' 'publish|tcp|443|4|any' 'publish|tcp|443|6|::1'; do
    lib "nftban_forward_valid_record '$r'" >/dev/null 2>&1 || { good=1; echo "      refused (wrong): $r"; }
done
[[ $bad -eq 0 && $good -eq 0 ]] && ok "S1 record validation (11 invalid refused, 6 valid accepted)" || no "S1 validation"

# S2 empty store
: > "$STORE"; render "$SB/r0.nft" 2>"$SB/r0.err" || true
if [[ -s "$SB/r0.nft" ]] && ! grep -q '__[A-Z0-9_]*__' "$SB/r0.nft" && ! grep -qE 'elements = \{.*("docker0"| \. )' "$SB/r0.nft"; then ok "S2 empty store -> no element lines, no placeholder left"
else no "S2 empty render" "$(head -3 "$SB/r0.err")"; fi

# S3 records
printf '%s\n' 'egress|docker0|t|d' 'egress|br-938df9175c79|t|d' 'uplink|eth0|t|d' 'publish|tcp|15432|4|192.0.2.0/24|t|d' 'publish|tcp|18080|4|any|t|d' \
              'publish|udp|5353|6|2001:db8::/32|t|d' 'publish|tcp|18080|6|any|t|d' > "$STORE"
render "$SB/r1.nft" 2>"$SB/r1.err" || true
eg=$(grep -c 'elements = { "docker0", "br-938df9175c79" }' "$SB/r1.nft" || true); up=$(grep -c 'elements = { "eth0" }' "$SB/r1.nft" || true)
if [[ $eg -eq 2 && $up -eq 2 ]] && grep -q 'elements = { 15432 . 192.0.2.0/24, 18080 . 0.0.0.0/0 }' "$SB/r1.nft" \
   && grep -q 'elements = { 18080 . ::/0 }' "$SB/r1.nft" && grep -q 'elements = { 5353 . 2001:db8::/32 }' "$SB/r1.nft" && ! grep -q '__[A-Z0-9_]*__' "$SB/r1.nft"; then
    ok "S3 records -> egress/uplink in both families; publish per proto and family; any = 0.0.0.0/0 and ::/0"
else no "S3 render" "egress lines=$eg uplink lines=$up"; fi

# S4 invalid line at render
printf '%s\n' 'egress|docker0|t|d' 'nonsense|x' > "$STORE"; render "$SB/r2.nft" 2>"$SB/r2.err" || true
grep -q 'invalid record skipped' "$SB/r2.err" && grep -q 'elements = { "docker0" }' "$SB/r2.nft" && ok "S4 invalid store line reported and skipped; valid ones rendered" || no "S4 invalid line"

# S5 unreadable store refuses the render
if [[ $(id -u) -ne 0 ]]; then
    chmod 000 "$STORE"; rc=0; render "$SB/r3.nft" 2>"$SB/r3.err" || rc=$?; chmod 644 "$STORE"
    [[ $rc -ne 0 ]] && grep -q 'render refused' "$SB/r3.err" && ok "S5 unreadable store -> render REFUSED (running rules kept)" || no "S5 unreadable" "rc=$rc"
else echo "  [NOT_EXECUTED] S5 unreadable store (root reads mode-000 files)"; fi

# S6/S9 chain order and tags, both families
order_ok=1
for fam in ip ip6; do
    sa="ip saddr"; F=ipv4; [[ $fam == ip6 ]] && { sa="ip6 saddr"; F=ipv6; }
    blk=$(awk -v t="table $fam nftban {" '$0==t{p=1} p&&/^    chain forward \{/{c=1} c{print} c&&/^    \}/{exit}' "$TPL")
    seq=$(printf '%s\n' "$blk" | grep -oE 'comment "nftban:fwd:[a-z-]+"' | sed 's/.*fwd:\([a-z-]*\)"/\1/' | paste -sd' ' -)
    [[ "$seq" == "ban-manual ban ct invalid egress publish-tcp publish-udp" ]] || { order_ok=0; echo "      $fam order: $seq"; }
    [[ "$blk" == *"policy drop;"* ]] || { order_ok=0; echo "      $fam: no policy drop"; }
    [[ "$blk" == *"$sa != @whitelist_$F $sa @blacklist_$F counter drop"* ]] || { order_ok=0; echo "      $fam: ban rule without whitelist exemption"; }
    wla=$(printf '%s\n' "$blk" | grep -vE '^[[:space:]]*#' | grep -E 'whitelist' | grep -cw 'accept' || true)
    [[ "$wla" -eq 0 ]] || { order_ok=0; echo "      $fam: whitelist ACCEPT present"; }
    untag=$(printf '%s\n' "$blk" | grep -vE '^[[:space:]]*#' | grep -E ' (accept|drop) ' | grep -vc 'nftban:fwd:' || true)
    [[ "$untag" -eq 0 ]] || { order_ok=0; echo "      $fam: $untag untagged rule(s)"; }
done
[[ $order_ok -eq 1 ]] && ok "S6/S9 forward order bans -> ct -> invalid -> egress -> publish; whitelist only as ban exemption; all tagged; policy drop (ip, ip6)" || no "S6 chain order"

# S7 add / remove / dedupe
: > "$STORE"
r1=0; lib "nftban_forward_add 'egress|docker0' 'first'" >/dev/null 2>&1 || r1=$?
r2=0; lib "nftban_forward_add 'egress|docker0' 'again'" >/dev/null 2>&1 || r2=$?
r3=0; lib "nftban_forward_remove 'egress|docker0'" >/dev/null 2>&1 || r3=$?
r4=0; lib "nftban_forward_remove 'egress|docker0'" >/dev/null 2>&1 || r4=$?
[[ $r1 -eq 0 && $r2 -eq 3 && $r3 -eq 0 && $r4 -eq 4 ]] && ! grep -q docker0 "$STORE" && ok "S7 add (0), duplicate (3 already present), remove (0), remove again (4 not present)" || no "S7 add/remove" "$r1 $r2 $r3 $r4"

# S8 recognised bridge only
rc=0; out=$(lib "nftban_forward_cli allow egress virbr0" 2>&1) || rc=$?
[[ $rc -ne 0 ]] && [[ "$out" == *'not a recognised and tested bridge'* ]] && ! grep -q virbr0 "$STORE" && ok "S8 allow egress refuses an unrecognised bridge (virbr0), nothing written" || no "S8 unrecognised bridge" "rc=$rc"

echo ""
echo "RESULT: $([[ $FAIL -eq 0 ]] && echo PASS || echo FAIL) (pass=$PASS fail=$FAIL)"
[[ $FAIL -eq 0 ]]
