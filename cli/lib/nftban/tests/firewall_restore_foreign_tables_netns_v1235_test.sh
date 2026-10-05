#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - F-A1-1: restore leaves foreign tables byte-identical (kernel)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="firewall_restore_foreign_tables_netns_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-05"
# meta:description="RESTORE-FROM-FILE-FLUSHES-FOREIGN-TABLES (v1.235 A1), falsifier F-A1-1, kernel arm. In a throwaway network namespace: create Docker-like `ip nat` + `ip filter`, an operator `ip raw` PREROUTING chain (the srv1 shape) and an `inet` operator table, plus live nftban tables; write a backup whose copies of those foreign tables DIFFER from the live ones and whose nftban tables carry a marker element; run the REAL _restore_from_file inside the namespace (systemctl stubbed, so host services are never touched). Asserts: every foreign table is byte-identical to its pre-restore `nft -a list table` (handles included, so it was neither deleted nor re-created); the nftban tables equal the backup's (marker present). Preconditions (namespace, tables present, nftban policy) are asserted before the subject runs; a missed precondition is NOT_EXECUTED (exit 3), never a verdict. FAILS on e79a1173 (flush ruleset + whole-backup load). Root + nftables required; lab only."
# meta:inventory.files="firewall_restore_foreign_tables_netns_v1235_test.sh"
# meta:inventory.binaries="bash,ip,nft,sed,mktemp,cmp"
# meta:inventory.env_vars="A1_SUBJECT_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# meta:ta.id="firewall_restore_foreign_tables_netns_v1235_test"
# meta:ta.owner="firewall"
# meta:ta.module="firewall-restore"
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
FW="${A1_SUBJECT_ROOT:-$REPO}/cli/lib/nftban/cli/cmd_firewall.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
ne(){ echo "  NOT_EXECUTED: $1"; echo "RESULT: NOT_EXECUTED"; exit 3; }

echo "=== v1.235 A1 F-A1-1: foreign tables survive restore (netns) ==="
[[ "$(id -u)" -eq 0 ]] || ne "requires root"
command -v nft >/dev/null 2>&1 || ne "nft not available"
command -v ip  >/dev/null 2>&1 || ne "ip not available"
[[ -f "$FW" ]] || ne "subject not found: $FW"

NS="a1f_$$"
WORK="$(mktemp -d)"
cleanup(){ ip netns del "$NS" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT
ip netns add "$NS" || ne "cannot create network namespace"
inns(){ ip netns exec "$NS" "$@"; }

# Rule files on disk, never a heredoc on a shared stdin (F-01 harness lesson).
cat > "$WORK/live.nft" <<'EOF'
table ip nat {
	chain DOCKER {
		iifname != "br-live" tcp dport 5432 dnat to 172.18.0.3:5432
	}
}
table ip filter {
	chain DOCKER-USER {
	}
}
table ip raw {
	chain PREROUTING {
		type filter hook prerouting priority raw; policy accept;
		ip daddr 172.18.0.2 iifname != "br-live" drop
	}
}
table inet ops {
	chain c {
		type filter hook input priority 10; policy accept;
		tcp dport 9999 counter accept
	}
}
table ip nftban {
	chain input {
		type filter hook input priority filter; policy drop;
		iif "lo" accept
	}
}
table ip6 nftban {
	chain input {
		type filter hook input priority filter; policy drop;
		iif "lo" accept
	}
}
EOF
cat > "$WORK/backup.nft" <<'EOF'
table ip nat {
	chain DOCKER {
		iifname != "br-OLD" tcp dport 7700 dnat to 172.18.0.99:7700
	}
}
table ip raw {
	chain PREROUTING {
		type filter hook prerouting priority raw; policy accept;
		ip daddr 10.9.9.9 drop
	}
}
table inet ops {
	chain c {
		type filter hook input priority 10; policy drop;
	}
}
table ip nftban {
	set restore_marker_v4 {
		type ipv4_addr
		elements = { 198.51.100.77 }
	}
	chain input {
		type filter hook input priority filter; policy drop;
		iif "lo" accept
	}
}
table ip6 nftban {
	set restore_marker_v6 {
		type ipv6_addr
		elements = { 2001:db8::77 }
	}
	chain input {
		type filter hook input priority filter; policy drop;
		iif "lo" accept
	}
}
EOF
inns nft -f "$WORK/live.nft" || ne "could not load the live ruleset in the namespace"

FOREIGN=( "ip nat" "ip filter" "ip raw" "inet ops" )
for t in "${FOREIGN[@]}"; do
    IFS=' ' read -r fam name <<< "$t"
    inns nft -a list table "$fam" "$name" > "$WORK/before_${fam}_${name}" 2>/dev/null \
        || ne "precondition: foreign table $t absent after load"
done
pol="$(inns nft list chain ip nftban input 2>/dev/null)" || ne "precondition: ip nftban absent"
[[ "$pol" == *"policy drop"* ]] || ne "precondition: ip nftban input policy did not read back as drop"
ok "preconditions: namespace, 4 foreign tables, nftban (policy drop) present"

# Run the REAL function inside the namespace. systemctl is stubbed so host services
# are never stopped or started; nft is the real binary, scoped to the namespace.
sed -n '/^_restore_extract_nftban_txn() {/,/^}/p; /^_restore_from_file() {/,/^}/p' "$FW" > "$WORK/fns.sh"
grep -q '^_restore_from_file() {' "$WORK/fns.sh" || ne "_restore_from_file not found in subject"
subj_rc=0
inns bash -c 'systemctl(){ :; }; source "$1"; _restore_from_file "$2"' _ "$WORK/fns.sh" "$WORK/backup.nft" \
    > "$WORK/subject.out" 2>&1 || subj_rc=$?
echo "    subject rc=$subj_rc"

for t in "${FOREIGN[@]}"; do
    IFS=' ' read -r fam name <<< "$t"
    if inns nft -a list table "$fam" "$name" > "$WORK/after_${fam}_${name}" 2>/dev/null \
       && cmp -s "$WORK/before_${fam}_${name}" "$WORK/after_${fam}_${name}"; then
        ok "F-A1-1 foreign table '$t' byte-identical incl. handles"
    else
        no "F-A1-1 foreign table '$t' changed, re-created or removed by restore"
    fi
done
m4="$(inns nft list set ip nftban restore_marker_v4 2>/dev/null || true)"
m6="$(inns nft list set ip6 nftban restore_marker_v6 2>/dev/null || true)"
if [[ "$subj_rc" -eq 0 && "$m4" == *"198.51.100.77"* && "$m6" == *"2001:db8::77"* ]]; then
    ok "nftban tables restored from the backup (markers present, rc=0)"
else
    no "nftban tables not restored from the backup" "rc=$subj_rc"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
