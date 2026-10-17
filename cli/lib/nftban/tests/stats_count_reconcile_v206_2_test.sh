#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.206.2 stats count-reconcile / freshness / label hotfix
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="stats_count_reconcile_v206_2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-25"
# meta:description="v1.206.2 stats reporting hotfix. WORDING-ONLY arms (T1-T4, T6): grep the source text of nftban_stats_format.sh for the freshness line, the Other/Unclass reconciliation text, the Operator/CLI labels, the 'showing X of N' wording and the IPv6 set names. They prove the text exists, NOT that any number is right: v1.235 found feeds counted twice, range endpoints counted and 'of N' on a different basis while these arms passed. Counting truth is owned by stats_counter_bases_v1235_test (behavioural, known-base fixtures). BEHAVIOURAL arm (T5): nftban_stats_manual_provenance over a sandbox blacklist.d (operator/persistent/adopted split, duplicate deduped to operator). Self-contained; no network; no nft mutation."
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
# ⛔ WORDING-ONLY. wording()/wording_absent() grep the SOURCE TEXT of $SRC. A pass
# means the text is present (or absent), never that a printed count is correct:
# v1.235 measured double-counted feeds, counted range endpoints and an "of N" on a
# different basis while every arm below passed. Counting truth:
# stats_counter_bases_v1235_test.sh (behavioural, known-base fixtures).
wording(){ grep -qF -- "$2" "$SRC" && { echo "  [PASS] [wording-only] $1"; PASS=$((PASS+1)); } || { echo "  [FAIL] [wording-only] $1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }; }
wording_absent(){ grep -qE -- "$2" "$SRC" && { echo "  [FAIL] [wording-only] $1"; FAIL=$((FAIL+1)); FAILED+=("$1"); } || { echo "  [PASS] [wording-only] $1"; PASS=$((PASS+1)); }; }
aeq(){ [[ "$1" == "$2" ]] && { echo "  [PASS] $3"; PASS=$((PASS+1)); } || { echo "  [FAIL] $3 (want '$2' got '$1')"; FAIL=$((FAIL+1)); FAILED+=("$3"); }; }

# shellcheck source=/dev/null
source "$SRC"
echo "==============================================="
echo "v1.206.2 stats wording (freshness / reconciliation text / labels)"
echo "==============================================="

echo "[T1] freshness wording"
wording "T1.1a Data source value stays exactly UNIFIED CACHE (v1.167 guard)" '"Data source........." "UNIFIED CACHE"'
wording "T1.1b snapshot age on sibling line" '"Snapshot............" "collected '
wording "T1.2 staleness note present" "may not appear until the next collection"

echo "[T2] Other/Unclass reconciliation TEXT (not a count check)"
wording "T2.1 Other/Unclass bucket label text" "Other/Unclass.."
wording "T2.2 'Other = New ban events' explanation text" "Other = New ban events"
wording "T2.3 different-basis note text" "exceeds New ban events"

echo "[T3] label wording"
wording "T3.1 By-source uses Operator/CLI" "Operator/CLI.."
wording "T3.2 BANS BY MODULE uses OPERATOR/CLI" '"OPERATOR/CLI"'
wording_absent "T3.3 no bare 'Manual..........' by-source label remains" '"Manual\.\.\.\.\.\.\.\.\.\." '
wording_absent "T3.4 no bare \"MANUAL\" module label remains" 'IPs\\n" "MANUAL"'

echo "[T4] active-bans sample wording + IPv6 set names in source"
wording "T4.1 'showing ' wording present (N is not checked)" "showing "
wording "T4.2 source names blacklist_manual_ipv6" "blacklist_manual_ipv6"
wording "T4.3 source names blacklist_ipv6" "blacklist_ipv6"

echo "[T5] v1.206.1 provenance helper — NO regression (behavioural)"
printf '%s\n' 1.2.3.4 5.6.7.8 > "$BD/99-manual.conf"
printf '%s\n' '# c' 9.9.9.9 1.2.3.4 > "$BD/30-persistent-offenders.conf"   # 1.2.3.4 dup → operator wins
IFS=' ' read -r OP PER AD <<< "$(nftban_stats_manual_provenance 4)"
aeq "$OP" "2" "T5.1 operator-manual=2"
aeq "$PER" "1" "T5.2 persistent=1 (dup deduped to operator)"
aeq "$AD" "1" "T5.3 adopted=1 (4-2-1)"

echo "[T6] retraction honored — no false IPv6-producer-omission text in code"
wording_absent "T6.1 no '.blacklist_manual.ipv6 omitted' assertion added" "producer omits .blacklist_manual.ipv6"

echo
echo "==============================================="
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
echo "ALL PASS"
