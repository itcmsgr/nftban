#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.206.1 stats manual-ban provenance attribution (hotfix)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="stats_manual_provenance_v206_1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-25"
# meta:description="Tests the v1.206.1 stats hotfix for BUG-STATS-MANUAL-MISATTRIBUTION + BUG-STATS-COUNT-DIVERGENCE. Asserts nftban_stats_manual_provenance() splits the live manual-hash-set total into operator-manual (99-manual.conf), persistent/loginmon (30-persistent-offenders.conf) and adopted/unknown (remainder); that a persistent-offender IP is NOT attributed to operator manual; that operator-manual is reserved for 99-manual.conf; that adopted is clamped >=0 when files exceed the total; and that the dashboard renderer carries the new count-semantics labels (manual-set, persistent/loginmon provenance, ban EVENTS, By source). Self-contained; no network; no nft."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,mktemp"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR
SRC="$NFTBAN_LIB_DIR/core/nftban_stats_format.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export NFTBAN_CONFIG_DIR="$SANDBOX/etc"
mkdir -p "$NFTBAN_CONFIG_DIR/blacklist.d"
BD="$NFTBAN_CONFIG_DIR/blacklist.d"

PASS=0; FAIL=0; FAILED=()
aeq(){ if [[ "$1" == "$2" ]]; then printf "  [PASS] %s\n" "$3"; PASS=$((PASS+1)); else printf "  [FAIL] %s (want '%s' got '%s')\n" "$3" "$2" "$1"; FAIL=$((FAIL+1)); FAILED+=("$3"); fi; }

# shellcheck source=/dev/null
source "$SRC"

echo "==============================================="
echo "v1.206.1 stats manual provenance test suite"
echo "==============================================="

# 5 operator-manual + 3 persistent(loginmon); live manual-set total = 10 → adopted 2
printf '%s\n' '1.1.1.1' '1.1.1.2' '1.1.1.3' '1.1.1.4 # note' '1.1.1.5' > "$BD/99-manual.conf"
printf '%s\n' '# header comment' '2.2.2.1  # >=10 bans in 24h from loginmon' '2.2.2.2' '2.2.2.3' > "$BD/30-persistent-offenders.conf"

IFS=" " read -r OP PER AD <<< "$(nftban_stats_manual_provenance 10)"
echo "[T1] split of total=10 with op=5 per=3 → $OP/$PER/$AD"
aeq "$OP"  "5" "T1.1 operator-manual = 99-manual.conf non-comment lines"
aeq "$PER" "3" "T1.2 persistent/loginmon = 30-persistent-offenders.conf non-comment lines"
aeq "$AD"  "2" "T1.3 adopted = total - operator - persistent"

# persistent-only: total 3, op 0 → persistent 3, adopted 0 (NOT counted as operator manual)
: > "$BD/99-manual.conf"
IFS=" " read -r OP PER AD <<< "$(nftban_stats_manual_provenance 3)"
aeq "$OP"  "0" "T2.1 no operator manual when 99-manual.conf empty"
aeq "$PER" "3" "T2.2 persistent-offenders attributed to persistent (NOT operator)"
aeq "$AD"  "0" "T2.3 adopted 0"

# precedence + no-double-count: IP in BOTH files counts once, as operator
printf '%s\n' '7.7.7.7' '8.8.8.8' > "$BD/99-manual.conf"          # 2 operator
printf '%s\n' '7.7.7.7  # also persistent' '9.9.9.9' > "$BD/30-persistent-offenders.conf"  # 7.7.7.7 dup, 9.9.9.9 new
IFS=" " read -r OP PER AD <<< "$(nftban_stats_manual_provenance 3)"
aeq "$OP"  "2" "T3a operator = 2 (7.7.7.7, 8.8.8.8)"
aeq "$PER" "1" "T3a persistent = 1 (9.9.9.9 only; 7.7.7.7 deduped to operator)"
aeq "$AD"  "0" "T3a adopted = 0 (3 total = 2 op + 1 per, no double-count)"
# restore the T1/T2 fixture for the clamp test below
printf '%s\n' '1.1.1.1' '1.1.1.2' '1.1.1.3' '1.1.1.4 # note' '1.1.1.5' > "$BD/99-manual.conf"
printf '%s\n' '# header comment' '2.2.2.1' '2.2.2.2' '2.2.2.3' > "$BD/30-persistent-offenders.conf"

# files exceed total (stale) → adopted clamped to 0, never negative
IFS=" " read -r OP PER AD <<< "$(nftban_stats_manual_provenance 1)"
aeq "$AD" "0" "T3 adopted clamped >=0 when files exceed live total"

# zero total with empty files → all zero (true-empty case; renderer only shows
# provenance when manual_total>0, so this is the meaningful zero path)
: > "$BD/99-manual.conf"; : > "$BD/30-persistent-offenders.conf"
IFS=" " read -r OP PER AD <<< "$(nftban_stats_manual_provenance 0)"
aeq "$OP/$PER/$AD" "0/0/0" "T4 zero total + empty files → 0/0/0"

echo "[T5] renderer carries the new count-semantics + provenance labels"
grep -q 'incl. manual-set:' "$SRC"                       && { echo "  [PASS] T5.1 Direct Bans relabeled 'incl. manual-set'"; PASS=$((PASS+1)); } || { echo "  [FAIL] T5.1"; FAIL=$((FAIL+1)); FAILED+=("T5.1"); }
grep -q 'persistent/loginmon' "$SRC"                     && { echo "  [PASS] T5.2 provenance split rendered"; PASS=$((PASS+1)); } || { echo "  [FAIL] T5.2"; FAIL=$((FAIL+1)); FAILED+=("T5.2"); }
grep -q 'New ban events' "$SRC"                          && { echo "  [PASS] T5.3 'New ban events' label"; PASS=$((PASS+1)); } || { echo "  [FAIL] T5.3"; FAIL=$((FAIL+1)); FAILED+=("T5.3"); }
grep -q 'By source (ban events, this period)' "$SRC"     && { echo "  [PASS] T5.4 'By source' window label"; PASS=$((PASS+1)); } || { echo "  [FAIL] T5.4"; FAIL=$((FAIL+1)); FAILED+=("T5.4"); }
grep -q 'sample unavailable' "$SRC" && { echo "  [PASS] T5.5 empty-sample reason"; PASS=$((PASS+1)); } || { echo "  [FAIL] T5.5"; FAIL=$((FAIL+1)); FAILED+=("T5.5"); }

echo
echo "==============================================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
echo "ALL PASS"
