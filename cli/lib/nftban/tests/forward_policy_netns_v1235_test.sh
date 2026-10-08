#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - forward policy behaviour in the kernel (owner D1-D4, Q1/Q2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="forward_policy_netns_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-08"
# meta:description="v1.235 forwarding (owner D1-D4; bans Q1/Q2 2026-10-08), kernel arm. Three throwaway network namespaces: client (198.51.100.2/.3, 2001:db8:1::2/::3), router (uplink eth0 + bridge docker0) and container (172.17.0.2, fd00:17::2). The router loads the ruleset rendered by the REAL _firewall_substitute_placeholders from the REAL template with a store of egress|docker0, uplink|eth0, publish tcp 8080 v4+v6 any, plus a Docker-like DNAT 8080->80 and 8081->81. Per family: F1 published DNAT port reaches the container; F2 an unpublished DNAT port (8081) is dropped; F3 the container reaches the outside (egress); F4 the outside cannot reach the container address directly (no DNAT); F5 a banned client is refused on the published port; F6 (Q1) an established forwarded connection from a client that is then banned stops delivering data (control: same flow unbanned delivers); F7 (Q2) a container-initiated connection towards a banned address fails while an unbanned address still works; F8 whitelist is an exemption from the ban only, never an accept (banned+whitelisted reaches 8080, 8081 still dropped). Preconditions are asserted before the subject; a missed precondition is NOT_EXECUTED (exit 3). Namespaces only: the host ruleset and sysctls are never touched. Root + nftables + python3 required; lab only. Supporting evidence; the Docker lab is the confirmation."
# meta:inventory.files="cli/lib/nftban/cli/cmd_firewall.sh,cli/lib/nftban/lib/nftban_forward.sh,install/nftables/nftables.conf.tpl"
# meta:inventory.binaries="bash,ip,nft,python3,mktemp,sleep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# meta:ta.id="forward_policy_netns_v1235_test"
# meta:ta.owner="firewall"
# meta:ta.module="forward-policy"
# meta:ta.execution_class="ROOT_LAB"
# meta:ta.gate="lab-manual"
# meta:ta.hermetic="false"
# meta:ta.requires_root="true"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="true"
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
ne(){ echo "  NOT_EXECUTED: $1"; echo "RESULT: NOT_EXECUTED"; exit 3; }

echo "=== v1.235 forward policy in the kernel (netns, v4 + v6) ==="
[[ "$(id -u)" -eq 0 ]] || ne "requires root"
for b in nft ip python3; do command -v "$b" >/dev/null 2>&1 || ne "$b not available"; done
[[ -f "$LIBDIR/lib/nftban_forward.sh" && -f "$TPL" ]] || ne "subject missing"

T="fp$$"; NC="${T}c"; NR="${T}r"; NK="${T}k"
WORK="$(mktemp -d)"
PIDS=()
cleanup(){
    local p
    for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
    ip netns del "$NC" 2>/dev/null || true; ip netns del "$NR" 2>/dev/null || true; ip netns del "$NK" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT
for n in "$NC" "$NR" "$NK"; do ip netns add "$n" || ne "cannot create namespace $n"; done
c(){ ip netns exec "$NC" "$@"; }
r(){ ip netns exec "$NR" "$@"; }
k(){ ip netns exec "$NK" "$@"; }

# --- topology (namespaces only) ---------------------------------------------
ip link add "${T}u" netns "$NR" type veth peer name "${T}v" netns "$NC"
r ip link set "${T}u" name eth0
c ip link set "${T}v" name eth0
r ip link add docker0 type bridge
ip link add "${T}b" netns "$NR" type veth peer name "${T}w" netns "$NK"
r ip link set "${T}b" master docker0
k ip link set "${T}w" name eth0
for n in c r k; do $n sysctl -qw net.ipv6.conf.all.accept_dad=0 net.ipv6.conf.default.accept_dad=0; done
r sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1
for n in c r k; do $n ip link set lo up; $n ip link set eth0 up 2>/dev/null || true; done
r ip link set docker0 up; r ip link set "${T}b" up
c ip addr add 198.51.100.2/24 dev eth0; c ip addr add 198.51.100.3/24 dev eth0
c ip -6 addr add 2001:db8:1::2/64 dev eth0 nodad; c ip -6 addr add 2001:db8:1::3/64 dev eth0 nodad
r ip addr add 198.51.100.1/24 dev eth0; r ip -6 addr add 2001:db8:1::1/64 dev eth0 nodad
r ip addr add 172.17.0.1/16 dev docker0; r ip -6 addr add fd00:17::1/64 dev docker0 nodad
k ip addr add 172.17.0.2/16 dev eth0; k ip -6 addr add fd00:17::2/64 dev eth0 nodad
k ip route add default via 172.17.0.1; k ip -6 route add default via fd00:17::1
c ip route add 172.17.0.0/16 via 198.51.100.1; c ip -6 route add fd00:17::/64 via 2001:db8:1::1
mkdir -p "$WORK/etc/forward.d" "$WORK/log"

# --- fixtures: Docker-like DNAT and traffic helpers ---------------------------
cat > "$WORK/nat.nft" <<'EOF'
table ip nat {
	chain prerouting {
		type nat hook prerouting priority dstnat; policy accept;
		tcp dport 8080 dnat to 172.17.0.2:80
		tcp dport 8081 dnat to 172.17.0.2:81
	}
}
table ip6 nat {
	chain prerouting {
		type nat hook prerouting priority dstnat; policy accept;
		tcp dport 8080 dnat to [fd00:17::2]:80
		tcp dport 8081 dnat to [fd00:17::2]:81
	}
}
EOF
cat > "$WORK/t.py" <<'EOF'
import os, socket, sys, threading, time
def handle(conn, peer, port, logdir):
    path = os.path.join(logdir, "p%d_%d" % (port, peer[1]))
    first = True
    try:
        while True:
            d = conn.recv(100)
            if not d:
                break
            with open(path, "ab") as f:
                f.write(d)
            if first:
                conn.sendall(b"ok\n"); first = False
    except OSError:
        pass
    conn.close()
def serve(port, logdir):
    s = socket.create_server(("::", port), family=socket.AF_INET6, dualstack_ipv6=True)
    while True:
        conn, peer = s.accept()
        threading.Thread(target=handle, args=(conn, peer, port, logdir), daemon=True).start()
def sock(host):
    return socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET, socket.SOCK_STREAM)
mode = sys.argv[1]
if mode == "serve":
    for p in sys.argv[3:]:
        threading.Thread(target=serve, args=(int(p), sys.argv[2]), daemon=True).start()
    while True:
        time.sleep(3600)
elif mode == "probe":                  # probe <host> <port> [src]
    s = sock(sys.argv[2]); s.settimeout(2)
    try:
        if len(sys.argv) > 4:
            s.bind((sys.argv[4], 0))
        s.connect((sys.argv[2], int(sys.argv[3]))); s.sendall(b"x")
        sys.exit(0 if s.recv(10).startswith(b"ok") else 1)
    except OSError:
        sys.exit(1)
elif mode == "long":                   # long <host> <port> <src> <flag>: "a", wait flag, "b"
    s = sock(sys.argv[2]); s.settimeout(3)
    try:
        s.bind((sys.argv[4], 0))
        s.connect((sys.argv[2], int(sys.argv[3]))); s.sendall(b"a"); s.recv(10)
    except OSError:
        print("ERR", flush=True); sys.exit(1)
    print(s.getsockname()[1], flush=True)
    while not os.path.exists(sys.argv[5]):
        time.sleep(0.1)
    try:
        s.sendall(b"b")
    except OSError:
        pass
    time.sleep(3); s.close()
EOF
k python3 "$WORK/t.py" serve "$WORK/log" 80 81 & PIDS+=("$!")
c python3 "$WORK/t.py" serve "$WORK/log" 9000 & PIDS+=("$!")
sleep 1
probe(){ local ns="$1"; shift; "$ns" python3 "$WORK/t.py" probe "$@"; }
ban(){ r nft add element "$1" nftban "$2" "{ $3 }"; }
unban(){ r nft delete element "$1" nftban "$2" "{ $3 }"; }
# long <host> <src> [<family> <set> <addr>]: what reached the container ("a" or "ab"); the
# optional element is added to the set after the flow is established, before the second byte.
long(){
    local host="$1" src="$2" flag="$WORK/flag.$RANDOM" out="$WORK/long.$RANDOM" port i lp
    c python3 "$WORK/t.py" long "$host" 8080 "$src" "$flag" > "$out" &
    lp=$!
    for i in $(seq 1 30); do [[ -s "$out" ]] && break; sleep 0.1; done
    port="$(cat "$out" 2>/dev/null || true)"
    [[ "$port" =~ ^[0-9]+$ ]] || { kill "$lp" 2>/dev/null || true; echo "NOCONN"; return 0; }
    if [[ $# -eq 5 ]]; then ban "$3" "$4" "$5"; fi
    : > "$flag"; wait "$lp" 2>/dev/null || true
    cat "$WORK/log/p80_$port" 2>/dev/null || echo "NOLOG"
}

# --- preconditions: with NO filter every path works, so each block below is the rules' ---
r nft -f "$WORK/nat.nft" || ne "DNAT fixture did not load"
for pre in "c 198.51.100.1 8080 198.51.100.2" "c 198.51.100.1 8081 198.51.100.2" "k 198.51.100.2 9000" "c 172.17.0.2 80 198.51.100.2" \
           "c 2001:db8:1::1 8080 2001:db8:1::2" "c 2001:db8:1::1 8081 2001:db8:1::2" "k 2001:db8:1::2 9000" "c fd00:17::2 80 2001:db8:1::2"; do
    IFS=' ' read -r -a a <<<"$pre"
    probe "${a[@]}" || ne "topology precondition failed without any filter: $pre"
done

# --- subject: the REAL render of the REAL template with a forwarding store --------------
printf '%s\n' 'egress|docker0|t|d' 'uplink|eth0|t|d' 'publish|tcp|8080|4|any|t|d' 'publish|tcp|8080|6|any|t|d' > "$WORK/etc/forward.d/forward.conf"
env -i PATH="/usr/sbin:/usr/bin:/sbin:/bin" HOME="$WORK" NFTBAN_CONFIG_DIR="$WORK/etc" NFTBAN_LIB_DIR="$LIBDIR" \
    bash -c 'source "$1/cli/cmd_firewall.sh" >/dev/null 2>&1; _firewall_substitute_placeholders "$2" "$3"' _ "$LIBDIR" "$TPL" "$WORK/rules.nft" \
    2>"$WORK/render.err" || ne "render failed: $(sed -n 1p "$WORK/render.err")"
r nft -f "$WORK/rules.nft" 2>"$WORK/load.err" || ne "rendered ruleset did not load: $(sed -n 1p "$WORK/load.err")"
fc="$(r nft list chain ip nftban forward 2>&1 || true)"
[[ "$fc" == *"policy drop"* && "$fc" == *'"docker0"'* ]] || ne "forward chain/sets not as rendered after load"

for fam in 4 6; do
    if [[ $fam == 4 ]]; then RT=198.51.100.1; CL=198.51.100.2; CL2=198.51.100.3; CT=172.17.0.2; F=ip; S=ipv4
    else RT=2001:db8:1::1; CL=2001:db8:1::2; CL2=2001:db8:1::3; CT=fd00:17::2; F=ip6; S=ipv6; fi
    echo "--- IPv$fam ---"
    probe c "$RT" 8080 "$CL" && ok "F1 v$fam published 8080 (DNAT) reaches the container" || no "F1 v$fam published port blocked"
    probe c "$RT" 8081 "$CL" && no "F2 v$fam unpublished DNAT port 8081 reached the container" || ok "F2 v$fam unpublished DNAT port 8081 dropped"
    probe k "$CL" 9000 && ok "F3 v$fam container reaches the outside (egress docker0 -> eth0)" || no "F3 v$fam egress blocked"
    probe c "$CT" 80 "$CL" && no "F4 v$fam outside reached the container address directly" || ok "F4 v$fam direct access to the container address (no DNAT) dropped"
    ban "$F" "blacklist_$S" "$CL"
    probe c "$RT" 8080 "$CL" && no "F5 v$fam banned client reached the published port" || ok "F5 v$fam banned client refused on the published port"
    probe c "$RT" 8080 "$CL2" && ok "F5b v$fam unbanned neighbour still reaches the published port" || no "F5b v$fam unbanned neighbour blocked"
    probe k "$CL" 9000 && no "F7 (Q2) v$fam container reached a banned address" || ok "F7 (Q2) v$fam container -> banned address fails (replies cut)"
    probe k "$CL2" 9000 && ok "F7b v$fam container -> unbanned address still works" || no "F7b v$fam unbanned egress blocked"
    r nft add element "$F" nftban "whitelist_$S" "{ $CL }"
    probe c "$RT" 8080 "$CL" && ok "F8 v$fam banned+whitelisted reaches the published port (exemption)" || no "F8 v$fam whitelist did not exempt the ban"
    probe c "$RT" 8081 "$CL" && no "F8b v$fam whitelist ACCEPTED an unpublished port" || ok "F8b v$fam whitelist is not an accept (8081 still dropped)"
    r nft delete element "$F" nftban "whitelist_$S" "{ $CL }"
    unban "$F" "blacklist_$S" "$CL"
    ctl="$(long "$RT" "$CL")"
    if [[ "$ctl" != "ab" ]]; then
        no "F6 (Q1) v$fam control: the unbanned long flow delivered '$ctl' (want ab) — cut not attributable"
    else
        got="$(long "$RT" "$CL" "$F" "blacklist_$S" "$CL")"
        unban "$F" "blacklist_$S" "$CL" 2>/dev/null || true
        [[ "$got" == "a" ]] && ok "F6 (Q1) v$fam established flow cut by the ban (control 'ab', after ban 'a')" || no "F6 (Q1) v$fam established flow after the ban delivered '$got' (want a)"
    fi
done

echo ""
echo "RESULT: $([[ $FAIL -eq 0 ]] && echo PASS || echo FAIL) (pass=$PASS fail=$FAIL)"
[[ $FAIL -eq 0 ]]
