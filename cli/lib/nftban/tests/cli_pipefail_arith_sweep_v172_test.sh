#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.172 CLI-PIPEFAIL-ARITH full-class sweep
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_pipefail_arith_sweep_v172_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-11"
# meta:description="Locks the v1.172 CLI-PIPEFAIL-ARITH sweep. Under set -Eeuo pipefail a `… | <emit-on-empty> … || <fallback>` inside $() double-emits when an early pipe stage (zero-match grep rc=1, head-closes-pipe SIGPIPE, or a jq parse error) fails while the final stage already printed a default → e.g. '0\\n0'; the consumer's [[ $X -eq/-gt ]] / jq tonumber then crashes. Part A (behavioral): the two fixed report_email count idioms single-emit on an empty nft-style set, and a wrapped grep|wc never doubles. Part B (static source lint): the previously-broken sites no longer carry the unsafe `wc -l || echo`, `grep -c | grep -c`, or `jq length … || echo` forms that feed arith; the re-readonly guard is present in cmd_wizard; the dead grep-c chain is gone from stats_format. Hermetic: no host/root/nft/daemon."
# meta:input="None (temp files; sources nothing privileged)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,grep,wc,jq"
# meta:inventory.files="cli/lib/nftban/core/nftban_report_email.sh,cli/lib/nftban/lib/nftban_report_data.sh,cli/lib/nftban/cli/cmd_ddos.sh,cli/lib/nftban/cli/cmd_stats.sh,cli/lib/nftban/cli/cmd_cleanup.sh,cli/lib/nftban/cli/cmd_login.sh,cli/lib/nftban/core/nftban_login_alert.sh,cli/lib/nftban/cli/cmd_update.sh,cli/lib/nftban/cli/cmd_watchdog.sh,cli/lib/nftban/core/nftban_health_checks_services.sh,cli/lib/nftban/lib/service_control.sh,cli/lib/nftban/cli/cmd_wizard.sh,cli/lib/nftban/core/nftban_stats_format.sh"
# meta:inventory.binaries="bash,jq,grep,wc"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
SRC="$REPO_ROOT/cli/lib/nftban"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

command -v jq >/dev/null 2>&1 || { echo "jq required for this test"; exit 1; }

echo "== Part A: behavioral — the fixed idioms single-emit under pipefail =="

# A1: the report_email v4-count idiom (wrapped grep | wc) on a set with NO IPv4
# matches must produce exactly one integer line (the old `grep -oE | wc -l || echo 0`
# produced "0\n0" → `$(( ))` crash).
emulate_v4_count() {
  # mimic: nft output piped through the fixed producer
  printf '%s\n' "$1" | { grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' || true; } | wc -l
}
out=$(emulate_v4_count "table ip nftban { set blacklist_ipv4 { } }")
out=${out//[^0-9]/}; out=${out:-0}
if [[ "$out" == "0" ]] && { v=$(( out + 0 )); [[ "$v" -eq 0 ]]; }; then
  ok "A1 empty-set v4 count single-emits a usable 0 (no arith crash)"
else
  no "A1 empty-set v4 count" "got '$out'"
fi

# A2: a populated set yields the real count, still single-emit.
out=$(emulate_v4_count "1.2.3.4
5.6.7.8")
out=${out//[^0-9]/}; out=${out:-0}
[[ "$out" == "2" ]] && ok "A2 populated v4 count = 2" || no "A2 populated v4 count" "got '$out'"

# A3: the wrapped `{ grep || true; } | wc -l` never double-emits even when grep
# fails AND a stray trailing default would have fired.
probe=$({ grep -oE 'ZZZ' <<<"no match here" || true; } | wc -l)
probe=${probe//[^0-9]/}
[[ "$probe" == "0" ]] && ok "A3 wrapped grep|wc emits one 0 on zero match" || no "A3 wrapped grep|wc" "got '$probe'"

# A4: jq -s 'add // [] | length' yields ONE integer for a single array AND for
# accidentally-appended arrays (the digest/history count idiom).
single=$(printf '%s' '[1,2,3]' | jq -s 'add // [] | length' 2>/dev/null)
appended=$(printf '%s' '[1,2][3,4,5]' | jq -s 'add // [] | length' 2>/dev/null)
empty=$(printf '%s' '' | jq -s 'add // [] | length' 2>/dev/null)
[[ "$single" == "3" && "$appended" == "5" && "$empty" == "0" ]] \
  && ok "A4 jq -s add//[]|length single-emits (single=3 appended=5 empty=0)" \
  || no "A4 jq -s add count" "single='$single' appended='$appended' empty='$empty'"

echo "== Part B: static source lint — unsafe arith-fed idioms are gone =="

# Helper: assert a regex does NOT match in a file.
absent(){ # <file> <ere> <label>
  local f="$SRC/$1"
  if [[ ! -f "$f" ]]; then no "$3" "missing $1"; return; fi
  if grep -nE "$2" "$f" >/dev/null 2>&1; then
    no "$3" "still present: $(grep -nE "$2" "$f" | head -1)"
  else ok "$3"; fi
}
present(){ # <file> <ere> <label>
  local f="$SRC/$1"
  if [[ -f "$f" ]] && grep -nE "$2" "$f" >/dev/null 2>&1; then ok "$3"; else no "$3" "expected pattern in $1"; fi
}

# B1: report_email v4 counts no longer use `… | wc -l || echo 0` (the double-emit).
absent "core/nftban_report_email.sh" 'wc -l \|\| echo 0' "B1 report_email: no 'wc -l || echo 0'"
# B2: report_data unique-IP count likewise.
absent "lib/nftban_report_data.sh" 'wc -l \|\| echo 0' "B2 report_data: no 'wc -l || echo 0'"
# B3: ddos blocked_24h/total no longer end the jq pipe with `|| echo "0"`.
absent "cli/cmd_ddos.sh" "jq -s '. \| length' 2>/dev/null \|\| echo" "B3 ddos: no 'jq -s length … || echo'"
# B4: ddos packets/bytes no longer use `head -1 || echo "0"`.
absent "cli/cmd_ddos.sh" 'head -1 \|\| echo' "B4 ddos: no 'head -1 || echo'"
# B5: stats repeat-offenders count is now 2>/dev/null guarded (not a bare jq into arith).
absent "cli/cmd_stats.sh" "jq '. \| length'\)$" "B5 stats: no bare 'jq . | length)' into count"
# B6: cleanup ip_count is guarded (no bare `jq -r 'length'` straight into [[ -eq ]]).
absent "cli/cmd_cleanup.sh" "jq -r 'length'\)$" "B6 cleanup: no bare 'jq -r length)'"
# B7: login + update + login_alert use the robust slurp form.
present "cli/cmd_login.sh"  "jq -s 'add // \[\] \| length'" "B7a login: uses 'jq -s add//[]|length'"
present "cli/cmd_update.sh" "jq -s 'add // \[\] \| length'" "B7b update: uses 'jq -s add//[]|length'"
present "core/nftban_login_alert.sh" "jq -s 'add // \[\] \| length'" "B7c login_alert: uses 'jq -s add//[]|length'"
absent  "cli/cmd_login.sh"  "jq 'length' \"\\\$digest_file\" 2>/dev/null \|\| echo" "B7d login: old 'jq length || echo' gone"
# B8: watchdog history count coerces null → [] and sanitizes.
present "cli/cmd_watchdog.sh" "jq -c '.data.history // \[\]'" "B8 watchdog: history coerced via // []"
# B9: new arith-fed siblings wrapped (fd_count, timers_active).
absent "core/nftban_health_checks_services.sh" 'wc -l \|\| echo 0' "B9a health: fd_count no 'wc -l || echo 0'"
absent "lib/service_control.sh" 'wc -l \|\| echo 0' "B9b service_control: timers no 'wc -l || echo 0'"
# B10: stats_format dead grep-c | grep-c chain removed (match the real quoted code,
# not this/other explanatory comments that mention the pattern).
absent "core/nftban_stats_format.sh" 'grep -c "[A-Z].*\| grep -cE "' "B10 stats_format: dead 'grep -c | grep -cE' gone"
# B11: cmd_wizard re-readonly guard present (no bare readonly on the two vars).
present "cli/cmd_wizard.sh" '\|\| readonly NFTBAN_CONFIG_LOCAL=' "B11a wizard: guarded readonly NFTBAN_CONFIG_LOCAL"
present "cli/cmd_wizard.sh" '\|\| readonly NFTBAN_PROFILE_CURRENT=' "B11b wizard: guarded readonly NFTBAN_PROFILE_CURRENT"

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
