#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.188 - B2 BOTSCAN-BADBOT-EASY-UX (Option A) guard test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="b2_badbot_aibot_v188_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-15"
# meta:description="B2 BOTSCAN-BADBOT-EASY-UX Option A (migrate-and-preserve). Guards: (1) no duplicate AI token across badbots/aibots; (2) migration preserves active state (GPTBot/CCBot/Bytespider hard-ban, ClaudeBot off); (3) new AI tokens observe/disabled (PerplexityBot off); (4) robots.txt-only tokens never ban (guard + not a pattern); (5) user-action fetchers never ban; (6) blockbot/allowbot change effective state via override.local + blockbot refuses never-ban tokens; (7) override.local survives a simulated upgrade (operator decisions preserved); (8) packaging no-clobber — spec ships *.patterns config(noreplace) glob (covers aibots.patterns) and does NOT package override.local. Hermetic: copies the real pattern files into a temp dir; no host/nft/IPC/daemon."
#
# meta:inventory.files="b2_badbot_aibot_v188_test.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,BOTSCAN_PATTERNS_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NFTBAN_LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"; export NFTBAN_LIB_DIR
REPO_ROOT="$(cd "$NFTBAN_LIB_DIR/../../.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

SHIPPED="$REPO_ROOT/etc/nftban/patterns.d/botscan"
[[ -f "$SHIPPED/aibots.patterns" ]] || fail "aibots.patterns not shipped at $SHIPPED"

# Hermetic patterns dir = copies of the real shipped files.
export BOTSCAN_PATTERNS_DIR="$tmp/patterns" NFTBAN_DATA_DIR="$tmp/data" \
       BOTSCAN_STATE_FILE="$tmp/s" BOTSCAN_LOG_FILE="$tmp/b.log" NFTBAN_CONFIG_DIR="$tmp/noetc"
mkdir -p "$BOTSCAN_PATTERNS_DIR" "$NFTBAN_DATA_DIR"
cp "$SHIPPED"/*.patterns "$BOTSCAN_PATTERNS_DIR/"
# shellcheck source=/dev/null
source "$NFTBAN_LIB_DIR/core/nftban_botscan.sh"

# ---- (1) no duplicate AI token across badbots/aibots ----
for tok in GPTBOT CCBOT BYTESPIDER CLAUDEBOT; do
    grep -qE "^${tok}\|" "$BOTSCAN_PATTERNS_DIR/aibots.patterns" || fail "1: $tok missing from aibots"
    grep -qE "^${tok}\|" "$BOTSCAN_PATTERNS_DIR/badbots.patterns" && fail "1: $tok still in badbots (duplicate owner)"
done
echo "PASS 1: AI tokens have one owner (aibots), not duplicated in badbots"

# ---- (2) migration preserves active state ----
nftban_botscan_load_patterns
[[ -n "${_BOTSCAN_PATTERNS[GPTBOT]:-}" ]]     || fail "2: GPTBot should be enabled (preserved hard-ban)"
[[ -n "${_BOTSCAN_PATTERNS[CCBOT]:-}" ]]      || fail "2: CCBot should be enabled (preserved)"
[[ -n "${_BOTSCAN_PATTERNS[BYTESPIDER]:-}" ]] || fail "2: Bytespider should be enabled (preserved)"
[[ -z "${_BOTSCAN_PATTERNS[CLAUDEBOT]:-}" ]]  || fail "2: ClaudeBot should be OFF (preserved observe)"
echo "PASS 2: migration preserved live state (GPTBot/CCBot/Bytespider on, ClaudeBot off)"

# ---- (3) new AI tokens observe/disabled by default ----
[[ -z "${_BOTSCAN_PATTERNS[PERPLEXITYBOT]:-}" ]] || fail "3: PerplexityBot must ship disabled (observe)"
grep -qE "^PERPLEXITYBOT\|.*\|false\|" "$BOTSCAN_PATTERNS_DIR/aibots.patterns" || fail "3: PerplexityBot not ENABLED=false in file"
echo "PASS 3: new AI token (PerplexityBot) ships observe/disabled"

# ---- (4) robots.txt-only tokens never ban (guard + not a pattern) ----
nftban_botscan_neverban_token "Google-Extended"  || fail "4: Google-Extended must be guarded"
nftban_botscan_neverban_token "Applebot-Extended" || fail "4: Applebot-Extended must be guarded"
# data lines only (NAME|...); comments (#) legitimately document the never-ban list
grep -rhE '^[A-Za-z]' "$BOTSCAN_PATTERNS_DIR"/*.patterns | grep -iqE "applebot-extended|google-extended" && fail "4: robots.txt-only token must NOT be a ban pattern (data line)"
echo "PASS 4: robots.txt-only tokens guarded + not present as patterns"

# ---- (5) user-action fetchers never ban ----
nftban_botscan_neverban_token "ChatGPT-User"    || fail "5: ChatGPT-User must be guarded"
nftban_botscan_neverban_token "Perplexity-User" || fail "5: Perplexity-User must be guarded"
nftban_botscan_neverban_token "GPTBot" && fail "5: GPTBot must NOT be guarded (it is ban-eligible)"
echo "PASS 5: user-action fetchers guarded; real scrapers not over-guarded"

# ---- (6) blockbot/allowbot change effective state; blockbot refuses never-ban ----
nftban_botscan_blockbot "ClaudeBot" >/dev/null || fail "6: blockbot ClaudeBot failed"
nftban_botscan_load_patterns
[[ -n "${_BOTSCAN_PATTERNS[CLAUDEBOT]:-}" ]] || fail "6: blockbot did not enable ClaudeBot via override.local"
nftban_botscan_allowbot "GPTBot" >/dev/null || fail "6: allowbot GPTBot failed"
nftban_botscan_load_patterns
[[ -z "${_BOTSCAN_PATTERNS[GPTBOT]:-}" ]] || fail "6: allowbot did not disable GPTBot via override.local"
rc=0; nftban_botscan_blockbot "googlebot" >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] || fail "6: blockbot googlebot must be REFUSED (never-ban)"
grep -qiE "^googlebot\|" "$BOTSCAN_PATTERNS_DIR/override.local" 2>/dev/null && fail "6: refused token must not be written to override.local"
echo "PASS 6: blockbot/allowbot flip effective state via override.local; never-ban refused"

# ---- (7) override.local survives a simulated upgrade ----
# Upgrade = shipped *.patterns replaced (re-copied), override.local untouched (operator file).
cp -f "$SHIPPED"/*.patterns "$BOTSCAN_PATTERNS_DIR/"   # simulate package payload refresh
nftban_botscan_load_patterns
[[ -n "${_BOTSCAN_PATTERNS[CLAUDEBOT]:-}" ]] || fail "7: override (ClaudeBot on) lost after upgrade"
[[ -z "${_BOTSCAN_PATTERNS[GPTBOT]:-}" ]]   || fail "7: override (GPTBot off) lost after upgrade"
echo "PASS 7: override.local decisions survive a simulated package upgrade"

# ---- (8) packaging no-clobber: spec ships *.patterns config(noreplace), NOT override.local ----
SPEC="$REPO_ROOT/build/packages/SPECS/nftban-core.spec"
grep -qE "%config\(noreplace\) /etc/nftban/patterns.d/botscan/\*\.patterns" "$SPEC" \
    || fail "8: spec must ship *.patterns as config(noreplace) glob (covers aibots.patterns)"
grep -q "override.local" "$SPEC" && fail "8: spec must NOT package override.local (operator-owned; would clobber on upgrade)"
echo "PASS 8: aibots.patterns auto-covered by config(noreplace) glob; override.local not packaged"

echo "PASS: B2 BOTSCAN-BADBOT-EASY-UX Option A (migrate+preserve, observe-default, never-ban guard, override.local no-clobber)"
