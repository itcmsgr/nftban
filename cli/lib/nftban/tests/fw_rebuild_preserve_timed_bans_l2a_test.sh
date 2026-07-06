#!/usr/bin/env bash
# =============================================================================
# NFTBan - L2a rebuild timed-ban preservation + restore-parser correctness
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="fw_rebuild_preserve_timed_bans_l2a_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-06"
# meta:description="Hermetic test for the L2a firewall-rebuild fix: extracts the REAL _fw_restore_timed_set() from cmd_firewall.sh and verifies it (1) parses wrapped/multiline nft set dumps, (2) re-applies timeout-bearing elements with their REMAINING ttl (expires), never the original timeout, (3) skips expired (expires 0s) elements, (4) restores permanent and CIDR (feed) elements, (5) skips unparseable elements without emitting invalid nft. Uses a mock nft to capture emitted add-element payloads. No host/nft/IPC/daemon."
# meta:input="None (self-contained; extracts function verbatim from source)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,grep,mktemp"
# meta:inventory.files="cli/lib/nftban/cli/cmd_firewall.sh"
# meta:inventory.binaries="bash,awk,grep,mktemp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
SRC="$REPO_ROOT/cli/lib/nftban/cli/cmd_firewall.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

[[ -f "$SRC" ]] || { echo "FATAL: source not found: $SRC" >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CAP="$WORK/nft_capture.txt"; : > "$CAP"

# Extract the REAL _fw_restore_timed_set() verbatim from the shipped source.
FN="$WORK/fn.sh"
awk '/^_fw_restore_timed_set\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SRC" > "$FN"
if grep -q '_fw_restore_timed_set()' "$FN"; then ok "extracted _fw_restore_timed_set() from cmd_firewall.sh"; else no "could not extract _fw_restore_timed_set() from source"; fi

# Mock nft: record every add-element invocation, succeed.
nft() { echo "$*" >> "$CAP"; return 0; }
export -f nft 2>/dev/null || true
# shellcheck source=/dev/null
source "$FN"

# Fixture 1: blacklist_manual_ipv4 — wrapped/multiline, timeout+expires, one expired.
D1="$WORK/blacklist_manual_ipv4.nft"
cat > "$D1" <<'EOF'
table ip nftban {
	set blacklist_manual_ipv4 {
		type ipv4_addr
		flags interval,timeout
		elements = { 1.2.3.4 timeout 1h expires 59m30s,
			5.6.7.8 timeout 30m expires 0s,
			9.10.11.12 timeout 2h expires 1h58m }
	}
}
EOF

out1="$(_fw_restore_timed_set "$D1" "ip nftban" "blacklist_manual_ipv4" false || true)"
IFS=' ' read -r r1 s1 e1 <<<"$out1"

# TTL preserved (remaining expires, NOT the original timeout)
grep -q '1.2.3.4 timeout 59m30s' "$CAP"  && ok "timed ban re-applied with REMAINING ttl (59m30s), not original (1h)" \
                                        || no "remaining-ttl not used for 1.2.3.4" "$(tr '\n' '|' <"$CAP")"
grep -q '9.10.11.12 timeout 1h58m' "$CAP" && ok "second timed ban re-applied with remaining ttl (1h58m)" \
                                          || no "remaining-ttl not used for 9.10.11.12"
# Original full timeout must NOT be emitted
grep -q '1.2.3.4 timeout 1h[^0-9]' "$CAP" && no "original timeout (1h) was emitted for 1.2.3.4 (ttl reset bug)" \
                                          || ok "original full timeout (1h) not emitted (no TTL reset)"
# Expired element skipped
grep -q '5.6.7.8' "$CAP" && no "expired element (expires 0s) was restored" \
                         || ok "expired element (expires 0s) skipped"
# Counts
[[ "$r1" == "2" && "$e1" == "1" ]] && ok "counts: restored=2 expired=1" || no "counts wrong" "restored=$r1 skipped=$s1 expired=$e1"

# Fixture 2: feed blacklist_ipv4 — permanent + CIDR (no timeout).
: > "$CAP"
D2="$WORK/blacklist_ipv4.nft"
cat > "$D2" <<'EOF'
table ip nftban {
	set blacklist_ipv4 {
		type ipv4_addr
		flags interval
		elements = { 10.0.0.0/8, 192.168.1.5 }
	}
}
EOF
out2="$(_fw_restore_timed_set "$D2" "ip nftban" "blacklist_ipv4" false || true)"
IFS=' ' read -r r2 _ _ <<<"$out2"
grep -q '10.0.0.0/8' "$CAP" && grep -q '192.168.1.5' "$CAP" && ok "feed blacklist restore works (CIDR + host, permanent)" \
                                                            || no "feed blacklist restore failed" "$(tr '\n' '|' <"$CAP")"
grep -q 'timeout' "$CAP" && no "permanent feed elements were given a timeout" || ok "permanent feed elements restored without timeout"
[[ "$r2" == "2" ]] && ok "feed counts: restored=2" || no "feed counts wrong" "restored=$r2"

# Fixture 3: unparseable element skipped (no invalid nft emitted).
: > "$CAP"
D3="$WORK/blacklist_manual_ipv6.nft"
cat > "$D3" <<'EOF'
	set blacklist_manual_ipv6 {
		elements = { 2001:db8::1 timeout 1h expires 55m, not-an-ip timeout 1h expires 40m }
	}
EOF
out3="$(_fw_restore_timed_set "$D3" "ip6 nftban" "blacklist_manual_ipv6" false || true)"
IFS=' ' read -r r3 s3 _ <<<"$out3"
grep -q '2001:db8::1 timeout 55m' "$CAP" && ok "valid ipv6 timed ban restored (remaining ttl)" || no "ipv6 timed ban not restored"
grep -q 'not-an-ip' "$CAP" && no "unparseable element emitted to nft" || ok "unparseable element skipped (no invalid nft)"
[[ "$r3" == "1" && "$s3" == "1" ]] && ok "mixed valid/invalid counts: restored=1 skipped=1" || no "mixed counts wrong" "restored=$r3 skipped=$s3"

# Fixture 4: missing dump file → no-op, zero counts.
out4="$(_fw_restore_timed_set "$WORK/does_not_exist.nft" "ip nftban" "blacklist_ipv4" true || true)"
[[ "$out4" == "0 0 0" ]] && ok "missing snapshot file → 0 0 0 (safe no-op)" || no "missing file not handled" "$out4"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
