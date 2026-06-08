#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.167 PR-1 guard: unified feed-IP / feed-file counters
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="feed_counters_unify_v167_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-08"
# meta:description="Hermetic guard for the v1.167 PR-1 feed-counter unification (BUG-CtCount-feeds). Three feed-count computations (cmd_status feeds.count, nftban_stats_collect cat-all wc -l, cmd_feeds per-feed aggregate) previously disagreed because each rolled its own resolution. PR-1 lifts the canonical v1.141 PR-C enabled-feed resolution (discover_all -> ENABLED==true -> lowercase -> <data>/feeds/<feed>.txt) into lib/nftban_feed_counters.sh with two pure helpers. This test sources that lib with stubbed feed-discovery primitives over a temp feeds dir and asserts: nftban_feed_ips_total sums non-empty lines across ENABLED feed files only (10+5+0=15), nftban_feed_file_count counts existing ENABLED feed files (3), disabled feeds are excluded, and an empty/absent feeds dir yields 0/0. Static; no host/nft/root."
# meta:inventory.files="cli/lib/nftban/lib/nftban_feed_counters.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_DATA_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$TEST_DIR/../lib/nftban_feed_counters.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

[[ -f "$LIB" ]] || { echo "helper lib not found at $LIB"; exit 1; }

echo "feed-counter unification guard (v1.167 PR-1):"

# --- temp feeds workspace -----------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FEEDS="$WORK/feeds"
mkdir -p "$FEEDS"

# 3 ENABLED feeds with 10, 5, 0 non-empty IP lines; 1 DISABLED feed with 99
# lines that MUST NOT be counted; 1 orphan .txt with no config entry.
seq 1 10  | sed 's/^/10.0.0./'       > "$FEEDS/feed_a.txt"   # 10 lines
seq 1 5   | sed 's/^/10.0.1./'       > "$FEEDS/feed_b.txt"   # 5 lines
: > "$FEEDS/feed_c.txt"                                       # 0 lines (exists)
seq 1 99  | sed 's/^/10.9.9./'       > "$FEEDS/feed_dis.txt" # 99 (disabled)
seq 1 42  | sed 's/^/10.8.8./'       > "$FEEDS/orphan.txt"   # not in config

# Inject a couple of blank/whitespace lines into feed_a — non-empty count must
# stay 10 (blank lines are not IPs).
printf '\n   \n' >> "$FEEDS/feed_a.txt"

# --- stub the feed-discovery primitives (the real ones read config files) -----
nftban_feeds_discover_all() { printf '%s\n' "FEED_A" "FEED_B" "FEED_C" "FEED_DIS"; }
nftban_feeds_get_property() {
    # $1=feed name, $2=property (we only answer ENABLED)
    case "$2" in
        ENABLED)
            case "$1" in
                FEED_DIS) echo "false" ;;
                *)        echo "true"  ;;
            esac
            ;;
        *) echo "" ;;
    esac
}
export -f nftban_feeds_discover_all nftban_feeds_get_property

# Source helper AFTER stubbing so its ensure-lib step sees the primitives.
export NFTBAN_DATA_DIR="$WORK"
# shellcheck source=/dev/null
source "$LIB"

# --- (a) IP total = 10 + 5 + 0 = 15 (disabled + orphan excluded, blanks skip) -
ips=$(nftban_feed_ips_total)
[[ "$ips" == "15" ]] \
    && ok "nftban_feed_ips_total == 15 (enabled feeds, non-empty lines only)" \
    || no "nftban_feed_ips_total wrong" "got '$ips', want 15"

# --- (b) file count = 3 enabled feed files exist -----------------------------
files=$(nftban_feed_file_count)
[[ "$files" == "3" ]] \
    && ok "nftban_feed_file_count == 3 (enabled feed files that exist)" \
    || no "nftban_feed_file_count wrong" "got '$files', want 3"

# --- (c) empty feeds dir -> 0 / 0 --------------------------------------------
EMPTY="$(mktemp -d)"
mkdir -p "$EMPTY/feeds"
(
    export NFTBAN_DATA_DIR="$EMPTY"
    e_ips=$(nftban_feed_ips_total)
    e_files=$(nftban_feed_file_count)
    [[ "$e_ips" == "0" && "$e_files" == "0" ]]
) \
    && ok "empty feeds dir -> ips=0 files=0" \
    || no "empty feeds dir not zeroed"
rm -rf "$EMPTY"

# --- (d) absent feeds dir -> 0 / 0 (robust to missing dir) -------------------
GONE="$(mktemp -d)"   # no feeds/ subdir at all
(
    export NFTBAN_DATA_DIR="$GONE"
    g_ips=$(nftban_feed_ips_total)
    g_files=$(nftban_feed_file_count)
    [[ "$g_ips" == "0" && "$g_files" == "0" ]]
) \
    && ok "absent feeds dir -> ips=0 files=0" \
    || no "absent feeds dir not zeroed"
rm -rf "$GONE"

# --- (e) BOTH cmd_status.sh feed surfaces route through the helper -----------
# v1.167 blocker fix: Lane A originally missed the cmd_status.sh:~914 "Threat
# Feeds … Active" surface (counted all *.txt incl. disabled/orphans). Assert
# every bare `find … feeds … *.txt … wc -l` in cmd_status.sh is helper-guarded
# (declare -f nftban_feed_file_count fallback), and the helper is referenced on
# both surfaces.
STATUS_SH="$TEST_DIR/../cli/cmd_status.sh"
if [[ -f "$STATUS_SH" ]]; then
    helper_refs=$(grep -c 'nftban_feed_file_count' "$STATUS_SH" || true)
    bare_finds=$(grep -cE 'find .*feeds.*\*\.txt.*-type f.*wc -l' "$STATUS_SH" || true)
    guards=$(grep -c 'declare -f nftban_feed_file_count' "$STATUS_SH" || true)
    [[ "$helper_refs" -ge 2 ]] \
        && ok "cmd_status.sh routes both feed surfaces through nftban_feed_file_count ($helper_refs refs)" \
        || no "cmd_status.sh feed surfaces not both routed through the helper ($helper_refs)"
    [[ "$guards" -ge "$bare_finds" ]] \
        && ok "every bare feed find in cmd_status.sh is helper-guarded (guards=$guards >= finds=$bare_finds)" \
        || no "unguarded bare feed find remains in cmd_status.sh (guards=$guards < finds=$bare_finds)"
else
    no "cmd_status.sh not found for Lane-A coverage check"
fi

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
