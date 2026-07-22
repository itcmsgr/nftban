#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.206.2 stats count-reconcile / freshness / label hotfix
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="stats_count_reconcile_v206_2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-25"
# meta:description="Tests the v1.206.2 stats reporting hotfix (reporting-only): (1) freshness — the UNIFIED CACHE Data source line carries a snapshot age + a staleness note; (2) count reconciliation — an Other/Unclass bucket reconciles by-source to New ban events; (3) label disambiguation — the ambiguous bare 'Manual' by-source/module labels are replaced by 'Operator/CLI', and operator-manual/persistent/adopted provenance remains separated (no regression of the v1.206.1 nftban_stats_manual_provenance helper); (4) active-bans sample prints 'showing X of N' and reads both IPv4 and IPv6 sets. Self-contained; no network; no nft mutation."
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
# meta:ta.id="stats_count_reconcile_v206_2_test"
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
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR
SRC="$NFTBAN_LIB_DIR/core/nftban_stats_format.sh"

SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export NFTBAN_CONFIG_DIR="$SANDBOX/etc"; mkdir -p "$NFTBAN_CONFIG_DIR/blacklist.d"; BD="$NFTBAN_CONFIG_DIR/blacklist.d"
PASS=0; FAIL=0; FAILED=()
has(){ grep -qF -- "$2" "$SRC" && { echo "  [PASS] $1"; PASS=$((PASS+1)); } || { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }; }
hasnt(){ grep -qE -- "$2" "$SRC" && { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); FAILED+=("$1"); } || { echo "  [PASS] $1"; PASS=$((PASS+1)); }; }
aeq(){ [[ "$1" == "$2" ]] && { echo "  [PASS] $3"; PASS=$((PASS+1)); } || { echo "  [FAIL] $3 (want '$2' got '$1')"; FAIL=$((FAIL+1)); FAILED+=("$3"); }; }

# shellcheck source=/dev/null
source "$SRC"
echo "==============================================="
echo "v1.206.2 stats count-reconcile / freshness / labels"
echo "==============================================="

echo "[T1] freshness clarity"
has "T1.1a Data source value stays exactly UNIFIED CACHE (v1.167 guard)" '"Data source........." "UNIFIED CACHE"'
has "T1.1b snapshot age on sibling line" '"Snapshot............" "collected '
has "T1.2 staleness note present" "may not appear until the next collection"

echo "[T2] count reconciliation (Other/Unclass)"
has "T2.1 Other/Unclass bucket label" "Other/Unclass.."
has "T2.2 Other = New ban events − classified explanation" "Other = New ban events"
has "T2.3 over-count different-basis note" "exceeds New ban events"

echo "[T3] label disambiguation"
has "T3.1 By-source uses Operator/CLI" "Operator/CLI.."
has "T3.2 BANS BY MODULE uses OPERATOR/CLI" '"OPERATOR/CLI"'
hasnt "T3.3 no bare 'Manual..........' by-source label remains" '"Manual\.\.\.\.\.\.\.\.\.\." '
hasnt "T3.4 no bare \"MANUAL\" module label remains" 'IPs\\n" "MANUAL"'

echo "[T4] active-bans sample showing X of N + both families"
has "T4.1 'showing X of N' wording" "showing "
has "T4.2 samples IPv6 interval+manual sets" "blacklist_manual_ipv6"
has "T4.3 samples IPv6 interval set" "blacklist_ipv6"

echo "[T5] v1.206.1 provenance helper — NO regression"
printf '%s\n' 1.2.3.4 5.6.7.8 > "$BD/99-manual.conf"
printf '%s\n' '# c' 9.9.9.9 1.2.3.4 > "$BD/30-persistent-offenders.conf"   # 1.2.3.4 dup → operator wins
IFS=' ' read -r OP PER AD <<< "$(nftban_stats_manual_provenance 4)"
aeq "$OP" "2" "T5.1 operator-manual=2"
aeq "$PER" "1" "T5.2 persistent=1 (dup deduped to operator)"
aeq "$AD" "1" "T5.3 adopted=1 (4-2-1)"

echo "[T6] retraction honored — no false IPv6-producer-omission claim in code"
hasnt "T6.1 no '.blacklist_manual.ipv6 omitted' assertion added" "producer omits .blacklist_manual.ipv6"

echo
echo "==============================================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
echo "ALL PASS"
