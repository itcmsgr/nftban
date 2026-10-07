#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - port report: DNAT-published ports carry NFTBan's forward verdict
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="port_report_published_forward_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-07"
# meta:description="PORT-REPORT-MISLABELS-DOCKER (v1.235, C19). A port published by a foreign DNAT rule (Docker and others) was reported 'BLOCKED - No firewall rule (default drop)': an input-chain verdict for traffic that takes the forward path. Drives the REAL core/nftban_report_port.sh (its own strict plane, IFS=$'\\n\\t') against a stub nft serving fixture rulesets (documentation address ranges only). Arms: P1 no DNAT -> existing 'No firewall rule (default drop)' kept; P2 foreign DNAT + nftban forward policy drop + 0 accept rules -> 'published by ip nat DNAT -> blocked by the NFTBan forward policy (drop; no accept rule in the nftban forward chain)'; P3 the same + 2 accept rules (one ct state established,related) -> 'NFTBan verdict UNKNOWN ... 2 accept rule(s) ... (not evaluated)'; P4 no nftban forward chain -> UNKNOWN; P5 nft -j unreadable -> a listening port with no input rule is UNKNOWN, never 'No firewall rule'; P6 text ruleset unreadable -> UNKNOWN; P7 a DNAT dport set {5432, 7700} -> both ports attributed; P8 the table view prints UNKNOWN (not NO-RULE) in the firewall column. Never 'reachable'. Regression only: confirmation is the RC smoke row on the packaged candidate. Set PRP_SUBJECT_ROOT to an older tree (e.g. origin/main before this change): P2-P8 FAIL there."
# meta:inventory.files="cli/lib/nftban/core/nftban_report_port.sh"
# meta:inventory.binaries="bash,grep,jq,mktemp"
# meta:inventory.env_vars="PRP_SUBJECT_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="port_report_published_forward_v1235_test"
# meta:ta.owner="firewall"
# meta:ta.module="port-report"
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
ROOT="${PRP_SUBJECT_ROOT:-$REPO}"
MOD="$ROOT/cli/lib/nftban/core/nftban_report_port.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235 C19: DNAT-published ports and NFTBan's forward verdict ==="
[[ -f "$MOD" ]] || { echo "  NOT_EXECUTED: $MOD missing"; echo "RESULT: NOT_EXECUTED"; exit 3; }
command -v jq >/dev/null 2>&1 || { echo "  NOT_EXECUTED: jq missing"; echo "RESULT: NOT_EXECUTED"; exit 3; }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin"
# Stub nft: text from $FIX/text, JSON from $FIX/json; a missing file = the command fails.
cat > "$SB/bin/nft" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "-j" ]]; then [[ -f "$FIX/json" ]] && { cat "$FIX/json"; exit 0; }; exit 1; fi
if [[ "$1 $2" == "list ruleset" ]]; then [[ -f "$FIX/text" ]] && { cat "$FIX/text"; exit 0; }; exit 1; fi
exit 1
EOF
chmod 0755 "$SB/bin/nft"

# Fixture pieces (documentation ranges: 192.0.2.0/24, 198.51.100.0/24).
TEXT='table ip nftban {
	chain input {
		type filter hook input priority filter; policy drop;
		tcp dport 22 accept
	}
}'
dnat_rule(){ # <family> <table> <dport JSON> -> one DNAT rule object
    printf '{"rule":{"family":"%s","table":"%s","chain":"DOCKER","handle":7,"expr":[{"match":{"op":"!=","left":{"meta":{"key":"iifname"}},"right":"br-x"}},{"match":{"op":"==","left":{"payload":{"protocol":"tcp","field":"dport"}},"right":%s}},{"counter":{"packets":0,"bytes":0}},{"dnat":{"addr":"198.51.100.2","port":5432}}]}}' "$1" "$2" "$3"
}
fwd_chain(){ printf '{"chain":{"family":"ip","table":"nftban","name":"forward","handle":3,"type":"filter","hook":"forward","prio":0,"policy":"%s"}}' "$1"; }
acc_saddr='{"rule":{"family":"ip","table":"nftban","chain":"forward","handle":20,"expr":[{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"saddr"}},"right":{"prefix":{"addr":"198.51.100.0","len":24}}}},{"accept":null}]}}'
acc_ct='{"rule":{"family":"ip","table":"nftban","chain":"forward","handle":21,"expr":[{"match":{"op":"in","left":{"ct":{"key":"state"}},"right":["established","related"]}},{"accept":null}]}}'
mkfix(){ # <name> <json objects, comma-separated, or NONE> [notext]
    local d="$SB/$1"; mkdir -p "$d"
    [[ "${3:-}" == notext ]] || printf '%s\n' "$TEXT" > "$d/text"
    [[ "$2" == NONE ]] || printf '{"nftables":[{"metainfo":{"json_schema_version":1}},%s]}\n' "$2" > "$d/json"
    printf '%s' "$d"
}

# exposure <fixture dir> <port> <proto> -> the module's "EXPOSURE|FIREWALL|ICON|DETAIL"
# (the port is marked as listening on a wildcard address, as docker-proxy does)
exposure(){
    env -i PATH="$SB/bin:/usr/bin:/bin" FIX="$1" MOD="$MOD" P="$2" R="$3" bash -c '
        # shellcheck source=/dev/null
        source "$MOD"
        nftban_port_gather_nft_rules
        NFTBAN_PORT_LISTEN_MAP["${R}_${P}_ipv4"]="docker-proxy"
        NFTBAN_PORT_BIND_ADDR["${R}_${P}_ipv4"]="0.0.0.0"
        nftban_port_compute_exposure "$P" "$R"
    ' 2>"$SB/err" || echo "RC=$?"
}

# P1 — no DNAT anywhere: the existing input-chain label is unchanged.
d="$(mkfix p1 "$(fwd_chain drop)")"
r="$(exposure "$d" 5432 tcp)"
[[ "$r" == "BLOCKED|NO-RULE|x|No firewall rule (default drop)" ]] && ok "P1 no DNAT -> existing 'No firewall rule (default drop)' unchanged" || no "P1 control changed" "$r"

# P2 — DNAT + nftban forward policy drop + 0 accept rules.
d="$(mkfix p2 "$(fwd_chain drop),$(dnat_rule ip nat 5432)")"
r="$(exposure "$d" 5432 tcp)"
[[ "$r" == "BLOCKED|BLOCKED|x|published by ip nat DNAT -> blocked by the NFTBan forward policy (drop; no accept rule in the nftban forward chain)" ]] \
    && ok "P2 published + drop + 0 accepts -> blocked by the NFTBan forward policy (drop; no accept rule in the nftban forward chain)" || no "P2" "$r"

# P3 — the same with two accept rules, one of them ct established,related (counted, not special-cased).
d="$(mkfix p3 "$(fwd_chain drop),$(dnat_rule ip nat 5432),$acc_saddr,$acc_ct")"
r="$(exposure "$d" 5432 tcp)"
[[ "$r" == "UNKNOWN|UNKNOWN|?|published by ip nat DNAT -> NFTBan verdict UNKNOWN: the nftban forward chain has 2 accept rule(s) not managed by this report (not evaluated)" ]] \
    && ok "P3 accept rules present (incl. ct established) -> NFTBan verdict UNKNOWN, 2 counted, not evaluated" || no "P3" "$r"
[[ "$r" != *reachable* ]] && ok "P3 never claims 'reachable'" || no "P3 claims reachable" "$r"

# P4 — no nftban forward chain in the JSON.
d="$(mkfix p4 "$(dnat_rule ip nat 5432)")"
r="$(exposure "$d" 5432 tcp)"
[[ "$r" == "UNKNOWN|UNKNOWN|?|published by ip nat DNAT -> UNKNOWN (no nftban forward chain (ip))" ]] && ok "P4 no nftban forward chain -> UNKNOWN" || no "P4" "$r"

# P5 — the JSON ruleset cannot be read (text can): never 'No firewall rule'.
d="$(mkfix p5 NONE)"
r="$(exposure "$d" 5432 tcp)"
[[ "$r" == "UNKNOWN|UNKNOWN|?|UNKNOWN (nft -j ruleset unreadable: published-port check not done)" ]] \
    && ok "P5 nft -j unreadable -> UNKNOWN, not 'No firewall rule'" || no "P5" "$r"

# P6 — nothing can be read.
d="$(mkfix p6 NONE notext)"
r="$(exposure "$d" 5432 tcp)"
[[ "$r" == "UNKNOWN|UNKNOWN|?|UNKNOWN (nft ruleset unreadable)" ]] && ok "P6 ruleset unreadable -> UNKNOWN" || no "P6" "$r"

# P7 — a DNAT dport set: every member is attributed.
d="$(mkfix p7 "$(fwd_chain drop),$(dnat_rule ip nat '{"set":[5432,7700]}')")"
r1="$(exposure "$d" 5432 tcp)"; r2="$(exposure "$d" 7700 tcp)"
[[ "$r1" == *"blocked by the NFTBan forward policy"* && "$r2" == *"blocked by the NFTBan forward policy"* ]] \
    && ok "P7 dport set {5432, 7700} -> both published ports attributed" || no "P7" "$r1 / $r2"

# P8 — the table view shows UNKNOWN in the firewall column (it used to fall to NO-RULE).
d="$(mkfix p8 "$(fwd_chain drop),$(dnat_rule ip nat 5432),$acc_ct")"
t="$(env -i PATH="$SB/bin:/usr/bin:/bin" FIX="$d" MOD="$MOD" bash -c '
    # shellcheck source=/dev/null
    source "$MOD"
    nftban_port_gather_nft_rules
    NFTBAN_PORT_SEEN["5432_tcp"]=1
    NFTBAN_PORT_LISTEN_MAP["tcp_5432_ipv4"]="docker-proxy"
    NFTBAN_PORT_BIND_ADDR["tcp_5432_ipv4"]="0.0.0.0"
    nftban_port_render_table
' 2>&1 || true)"
row="$(grep -E '^5432 ' <<<"$t" || true)"
[[ "$row" == *UNKNOWN* && "$row" != *NO-RULE* && "$row" == *"NFTBan verdict UNKNOWN"* ]] \
    && ok "P8 table view: firewall column UNKNOWN, detail carries the forward verdict" || no "P8 table row" "${row:-<no 5432 row>}"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
