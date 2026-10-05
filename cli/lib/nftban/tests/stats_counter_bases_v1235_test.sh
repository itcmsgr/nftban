#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.235 stats/health counter-base regression (BUG-STATS-COUNTERS-MIXED-BASES)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="stats_counter_bases_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-05"
# meta:description="BEHAVIORAL regression for the v1.235 counter-base fix, reproduced from a production v1.234.0 host whose stats page showed 1,913 live / 3,309 TOTAL / sample 'of 1,960' / by-source total exceeding events, while health showed 'feeds loaded 0'. Runs the REAL nftban_stats_generate_dashboard (both the unified-cache and the cache-miss paths) and the REAL cmd_health.sh blacklist-table loop (extracted, never retyped) over a kernel fixture that contains single IPs, CIDR prefixes and RANGES. Asserts one base per figure: TOTAL == Blocked IPs (live); the sample N counts a range/CIDR as ONE element and equals the live element count; the feed source-list size is never added to live counts nor summed with ban events; an ABSENT validator entries field never renders as 0. Also runs a v4-only host (no IPv6 sets) under set -Eeuo pipefail with an ERR trap: the dashboard must render with no trap firing."
# meta:input="None (self-contained sandbox; stubbed nft/cache readers)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,awk,jq,mktemp"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,awk,jq,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR,NFTBAN_DATA_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="stats_counter_bases_v1235_test"
# meta:ta.owner="metrics"
# meta:ta.module="stats"
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

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
LIB="${REPO_ROOT}/cli/lib/nftban"
SRC="$LIB/core/nftban_stats_format.sh"
HCMD="$LIB/cli/cmd_health.sh"
for f in "$SRC" "$HCMD"; do
    [[ -f "$f" ]] || { echo "  SUBJECT_NOT_FOUND: $f"; echo "TOTAL: pass=0 fail=1"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "  NOT_EXECUTED: jq not installed"; echo "TOTAL: pass=0 fail=1"; exit 1; }

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
pass=0; fail=0
ok(){ echo "  [PASS] $1"; pass=$((pass+1)); }
ko(){ echo "  [FAIL] $1"; fail=$((fail+1)); }
chk(){ if [[ "$2" == "$3" ]]; then ok "$1 ($2)"; else ko "$1 (want '$3' got '$2')"; fi; }

# ---------------------------------------------------------------------------
# Kernel fixture (documentation ranges only). blacklist_ipv4 = 5 single IPs +
# 1 CIDR prefix + 2 RANGES = 8 ELEMENTS (the endpoint pattern sees 10 tokens).
# blacklist_manual_ipv4 = 3, blacklist_manual_ipv6 = 1  ->  12 live elements.
# ---------------------------------------------------------------------------
mkdir -p "$SB/nft"
cat > "$SB/nft/blacklist_ipv4" <<'EOF'
table ip nftban {
	set blacklist_ipv4 {
		type ipv4_addr
		flags interval
		auto-merge
		elements = { 192.0.2.1, 192.0.2.3, 192.0.2.5,
			     192.0.2.7, 192.0.2.9, 198.51.100.0/24,
			     203.0.113.10-203.0.113.20,
			     203.0.113.40-203.0.113.50 }
	}
}
EOF
cat > "$SB/nft/blacklist_manual_ipv4" <<'EOF'
table ip nftban {
	set blacklist_manual_ipv4 {
		type ipv4_addr
		elements = { 192.0.2.101, 192.0.2.102, 192.0.2.103 }
	}
}
EOF
cat > "$SB/nft/blacklist_manual_ipv6" <<'EOF'
table ip6 nftban {
	set blacklist_manual_ipv6 {
		type ipv6_addr
		elements = { 2001:db8::1 }
	}
}
EOF
LIVE=12        # 8 + 3 + 1 elements
FEEDS=7        # feed SOURCE-LIST entries (a file count, never a kernel count)

# Unified-cache fixture: the exporter counts ELEMENTS (production: 1909 v4 == 731+1178).
cat > "$SB/cache.json" <<EOF
{"blacklist":{"ipv4":{"total":11,"permanent":11,"temporary":0},"ipv6":{"total":1,"permanent":1,"temporary":0}},
 "blacklist_manual":{"ipv4":3,"ipv6":1},
 "feeds":{"ipv4_total":$FEEDS,"ipv6_total":0,"ips_total":$FEEDS},
 "geoban":{"countries_blocked":0}}
EOF

# One driver per arm: the REAL dashboard, sourced, run under strict mode + an ERR
# trap (stricter than the dispatcher, whose `main || exit` suspends errexit), so
# an unguarded no-match aborts HERE instead of hiding.
cat > "$SB/drive.sh" <<'DRV'
set -Eeuo pipefail
IFS=$'\n\t'
trap 'echo "ERR_TRAP_FIRED line=$LINENO cmd=$BASH_COMMAND" >&2; exit 97' ERR
SB="$1"; MODE="$2"; V6="$3"
# nftban_stats.sh (not sourced here) defines this config default.
export STATS_GEOIP_ENABLED=false
export NFTBAN_TABLE_IPV4="ip nftban" NFTBAN_TABLE_IPV6="ip6 nftban"
export NFTBAN_CONFIG_DIR="$SB/etc" NFTBAN_DATA_DIR="$SB/data"
mkdir -p "$NFTBAN_CONFIG_DIR/blacklist.d" "$NFTBAN_DATA_DIR"
timeout(){ shift; "$@"; }
nft(){ # nft list set <family> <table> <set>
    local s="${!#}" f="$SB/nft/${!#}"
    [[ "$s" == *ipv6 && "$V6" == "no" ]] && return 1
    [[ -f "$f" ]] && cat "$f" || return 1
}
hostname(){ echo fixture; }
nftban_stats_unified_available(){ [[ "$MODE" == "cache" ]]; }
nftban_stats_get_unified(){ local v; v=$(jq -r "$1 // empty" "$SB/cache.json" 2>/dev/null) || v=""; echo "${v:-$2}"; }
nftban_stats_ban_sources(){ # producer shape: feeds REPLACED by the list size (nftban_stats_collect.sh)
    echo '{"login":200,"portscan":100,"ddos":0,"manual":15,"feeds":7,"suricata":0}'; }
nftban_stats_count_bans(){ echo 315; }
nftban_stats_count_unique_ips(){ echo 80; }
nftban_stats_count_whitelist(){ echo 4; }
nftban_stats_top_countries(){ :; }
nftban_stats_recent_activity(){ :; }
nftban_nft_count_set(){ echo 0; }
nftban_feeds_discover_all(){ :; }
nftban_feeds_get_property(){ echo false; }
# shellcheck source=/dev/null
source "$SRC_FILE"
nftban_stats_generate_dashboard 2026-10-04 2026-10-05
DRV

run(){ # $1 mode  $2 v6(yes|no)  -> stdout file, rc
    local out="$SB/out_$1_$2" rc=0
    SRC_FILE="$SRC" bash "$SB/drive.sh" "$SB" "$1" "$2" >"$out" 2>"$out.err" || rc=$?
    echo "$rc" > "$out.rc"
}
field(){ awk -v k="$2" 'index($0,k){n=split($0,a," "); v=a[n]; gsub(/,/,"",v); print v; exit}' "$1"; }
sample_n(){ sed -n 's/.*showing [0-9]* of \([0-9]*\).*/\1/p' "$1" | sed -n 1p; }

echo "==============================================="
echo "v1.235 stats/health counter bases"
echo "==============================================="

for mode in cache miss; do
    run "$mode" yes
    o="$SB/out_${mode}_yes"
    echo "[S-$mode] dashboard over the range fixture (unified $mode)"
    chk "S-$mode.0 rendered with no ERR trap" "$(cat "$o.rc")" "0"
    chk "S-$mode.1 Blocked IPs (live) = live ELEMENTS" "$(field "$o" 'Blocked IPs (live)')" "$LIVE"
    chk "S-$mode.2 TOTAL = Blocked IPs (live) (feed list never added)" "$(field "$o" 'TOTAL...')" "$LIVE"
    chk "S-$mode.3 sample N = live ELEMENTS (range/CIDR = one)" "$(sample_n "$o")" "$LIVE"
    if grep -q '203\.0\.113\.10-203\.0\.113\.20' "$o"; then ok "S-$mode.4 a range is listed as ONE token"
    elif grep -qx '  203\.0\.113\.20' "$o"; then ko "S-$mode.4 range endpoint listed as its own element"
    else ok "S-$mode.4 range endpoint not split (range outside the 10-row sample)"; fi
    if grep -q 'exceeds New ban events' "$o"; then ko "S-$mode.5 feed inventory summed with ban events"
    else ok "S-$mode.5 by-source reconciles to events without the feed inventory"; fi
    if grep -qE '^ +Feeds\.{10} +[0-9]' "$o"; then ko "S-$mode.6 feed list size labelled as ban events"
    else ok "S-$mode.6 feed list size not labelled as events"; fi
done

echo "[S-v4only] host with NO IPv6 sets, strict mode + ERR trap"
run cache no
o="$SB/out_cache_no"
chk "S-v4only.0 rendered with no ERR trap" "$(cat "$o.rc")" "0"
grep -q 'ERR_TRAP_FIRED' "$o.err" && ko "S-v4only.1 trap: $(grep -m1 ERR_TRAP_FIRED "$o.err")" || ok "S-v4only.1 no ERR trap line"
chk "S-v4only.2 sample N = v4 elements" "$(sample_n "$o")" "$((LIVE-1))"

# ---------------------------------------------------------------------------
# Health blacklist table: the REAL loop from cmd_health.sh (extracted by its
# anchor comment, never retyped), fed the validator JSON captured on the
# production host (feeds/geoban carry NO entries field: omitempty).
# ---------------------------------------------------------------------------
echo "[H] health blacklist table — absent entries never render as 0"
awk '/# Render blacklist \(composite\)/{c=1} c{print} c&&/^    done$/{exit}' "$HCMD" > "$SB/bl_loop.sh"
if ! grep -q 'for sub in manual feeds geoban' "$SB/bl_loop.sh"; then
    ko "H.0 SUBJECT_FUNCTION_NOT_FOUND: blacklist loop anchor in cmd_health.sh"
else
    {
        echo 'set -Eeuo pipefail'; echo "IFS=\$'\\n\\t'"
        echo 'trap '\''echo ERR_TRAP_FIRED >&2; exit 97'\'' ERR'
        echo 'render(){ local output="$1"'; cat "$SB/bl_loop.sh"; echo '}'
        echo 'render "$(cat "$1")"'
    } > "$SB/bl_drive.sh"
    printf '%s' '{"modules":{"blacklist":{"manual":{"state":"enforcing","entries":1182,"drops":175},"feeds":{"state":"loaded"},"geoban":{"state":"loaded"}}}}' > "$SB/v_prod.json"
    printf '%s' '{"modules":{"blacklist":{"manual":{"state":"idle"},"feeds":{"state":"disabled"},"geoban":{"state":"disabled"}}}}' > "$SB/v_idle.json"
    hrc=0; bash "$SB/bl_drive.sh" "$SB/v_prod.json" > "$SB/h_prod" 2>&1 || hrc=$?
    chk "H.1 renders (rc)" "$hrc" "0"
    chk "H.2 manual shows the counted entries" "$(awk '$1=="manual"{print $3}' "$SB/h_prod")" "1182"
    if awk '$1=="feeds" && $3=="0"{f=1} END{exit !f}' "$SB/h_prod"; then ko "H.3 feeds absent entries rendered as 0"; else ok "H.3 feeds absent entries not rendered as 0"; fi
    if awk '$1=="geoban" && $3=="0"{f=1} END{exit !f}' "$SB/h_prod"; then ko "H.4 geoban absent entries rendered as 0"; else ok "H.4 geoban absent entries not rendered as 0"; fi
    hrc=0; bash "$SB/bl_drive.sh" "$SB/v_idle.json" > "$SB/h_idle" 2>&1 || hrc=$?
    chk "H.5 manual idle (omitempty 0) is a true 0" "$(awk '$1=="manual"{print $3}' "$SB/h_idle")" "0"
fi

echo ""
echo "TOTAL: pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
