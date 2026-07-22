#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.170 BUG-STATS-IP-HISTORY: `stats ip` pipefail fix + compressed logs
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="stats_ip_history_v170_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-10"
# meta:description="Locks the v1.170 fix for nftban_stats_ip_history() (core/nftban_stats_collect.sh). (1) SINGLE-EMIT: a zero-match IP under set -Eeuo pipefail must return exactly one JSON [] (the pre-v1.170 grep|awk||echo[] double-emitted '[]\\n[]' → caller jq length '0\\n0' → cmd_stats.sh:924 [[ -eq ]] arith crash). (2) COMPRESSED-LOG COVERAGE: history reads the live bans.log AND rotated/compressed archives (bans.log.1, bans.log.*.gz) via zgrep, so an IP found only in a .gz appears. (3) SORT: multi-source events sorted by timestamp. (4) CALLER GUARD: cmd_stats.sh sanitizes the jq total to one integer. (5) PACKAGING LOCK: gzip stays a declared dep (DEB Depends + RPM Requires) so zgrep/zcat are guaranteed. Hermetic: sources the real core funcs against a temp ban log via STATS_BAN_LOG; no host/root/nft."
# meta:input="None (temp ban log + temp .gz archive)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,gzip(zgrep),jq,awk,grep,sort"
# meta:inventory.files="cli/lib/nftban/core/nftban_stats_collect.sh,cli/lib/nftban/cli/cmd_stats.sh,packaging/deb/control,packaging/build_nftban.sh"
# meta:inventory.binaries="bash,zgrep,jq"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,STATS_BAN_LOG"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="stats_ip_history_v170_test"
# meta:ta.owner="metrics"
# meta:ta.module="stats"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
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
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
CORE="$REPO_ROOT/cli/lib/nftban/core"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

command -v jq >/dev/null 2>&1 || { echo "jq required for this test"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
LOG="$WORK/bans.log"
# live log: 2.2.2.2 (newer) ; rotated .gz: 3.3.3.3 + 4.4.4.4 (older)
printf '2026-06-08T14:22:00|jailssh|sshd|2.2.2.2|bruteforce|ban\n'  > "$LOG"
printf '2026-06-09T10:00:00|jailssh|sshd|4.4.4.4|bruteforce|ban\n' >> "$LOG"
printf '2026-06-01T09:00:00|jailssh|sshd|3.3.3.3|bruteforce|ban\n'  > "$WORK/old.txt"
printf '2026-05-15T08:00:00|jailssh|sshd|4.4.4.4|bruteforce|ban\n' >> "$WORK/old.txt"
gzip -c "$WORK/old.txt" > "$LOG.1.gz"

# Call the REAL function (source nftban_stats.sh first — it sets NFTBAN_BAN_LOG
# from STATS_BAN_LOG — then nftban_stats_collect.sh), under the same strict mode.
hist(){ NFTBAN_LIB_DIR="$REPO_ROOT/cli/lib/nftban" STATS_BAN_LOG="$LOG" bash -c '
  source "'"$CORE"'/nftban_stats.sh" >/dev/null 2>&1 || true
  source "'"$CORE"'/nftban_stats_collect.sh" >/dev/null 2>&1 || { echo "SRCFAIL"; exit 99; }
  nftban_stats_ip_history "$1"' _ "$1"; }

echo "=== (1) zero-match IP under pipefail → exactly one [] (no double-emit) ==="
out=$(hist 9.9.9.9)
if [[ "$out" == "[]" ]] && [[ "$(printf '%s' "$out" | wc -l)" -eq 0 ]] && [[ "$(printf '%s' "$out" | jq '. | length')" == "0" ]]; then
  ok "zero-match → single '[]', jq length 0 (no '[]\\n[]', no arith crash)"
else
  no "zero-match double-emit / garbled" "out=[$out]"
fi

echo "=== (2) live-log IP present ==="
out=$(hist 2.2.2.2)
if [[ "$(echo "$out" | jq '. | length')" == "1" && "$(echo "$out" | jq -r '.[0].timestamp')" == "2026-06-08T14:22:00" ]]; then
  ok "live-log IP 2.2.2.2 → 1 event"
else no "live-log IP wrong" "out=[$out]"; fi

echo "=== (3) compressed-only IP (.gz) appears → rotated-archive coverage ==="
out=$(hist 3.3.3.3)
if [[ "$(echo "$out" | jq '. | length')" == "1" && "$(echo "$out" | jq -r '.[0].action')" == "ban" ]]; then
  ok "compressed-only IP 3.3.3.3 read from bans.log.1.gz"
else no "compressed-log coverage failed" "out=[$out]"; fi

echo "=== (4) IP in BOTH live + .gz → merged, sorted by timestamp ==="
out=$(hist 4.4.4.4)
n=$(echo "$out" | jq '. | length'); first=$(echo "$out" | jq -r '.[0].timestamp'); last=$(echo "$out" | jq -r '.[-1].timestamp')
if [[ "$n" == "2" && "$first" == "2026-05-15T08:00:00" && "$last" == "2026-06-09T10:00:00" ]]; then
  ok "4.4.4.4 → 2 events merged (live+gz), ascending by timestamp"
else no "merge/sort wrong" "n=$n first=$first last=$last"; fi

echo "=== (5) caller cmd_stats.sh sanitizes jq total to one integer ==="
if grep -qE 'jq .\. \| length. 2>/dev/null \| head -1' "$REPO_ROOT/cli/lib/nftban/cli/cmd_stats.sh" \
   && grep -qE 'total=\$\{total//\[\^0-9\]/\}' "$REPO_ROOT/cli/lib/nftban/cli/cmd_stats.sh"; then
  ok "cmd_stats.sh total sanitized (head -1 + strip non-digits)"
else no "cmd_stats.sh total not sanitized"; fi

echo "=== (6) packaging lock: gzip declared (DEB Depends + RPM Requires) ==="
if grep -qE '^[[:space:]]*gzip,' "$REPO_ROOT/packaging/deb/control"; then ok "DEB control Depends: gzip"; else no "DEB control missing gzip"; fi
if grep -qE '^Requires:[[:space:]]+gzip' "$REPO_ROOT/packaging/build_nftban.sh"; then ok "RPM spec Requires: gzip"; else no "RPM spec missing Requires: gzip"; fi

echo "================================================================"
echo "stats_ip_history_v170_test: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
