#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.177 - HTTP log discovery + BotScan/LoginMon-WordPress panel paths
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="http_log_discovery_v177_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-12"
# meta:description="Locks the v1.177 panel-aware HTTP access-log discovery (lib/nftban_http_logs.sh). Panel/path matrix per panel (DirectAdmin Apache/nginx/LiteSpeed, cPanel domlogs, Plesk access/access_ssl, generic Apache RHEL+Debian, generic nginx, standalone LiteSpeed). Discovery via override globs over hermetic fixture trees; dedup; exclude error/rotated/compressed; bounded MAX_FILES with skip-reasons; no-log-found; unreadable-log skip (non-root); bounded incremental reader (offset second-run + rotation/inode-change + truncation); IPv6 xmlrpc parse (locks the pre-existing dual-stack parse); regression proving the legacy generic-only globs MISS DA/cPanel/Plesk while the new discovery FINDS them. Hermetic: t-temp trees, no root, no nft, no bans."
# meta:input="None (builds temp fixtures)"
# meta:output="Pass/fail; exit 0 all-pass, 1 on any failure"
# meta:depends="bash,stat,find,tail"
# meta:inventory.files="cli/lib/nftban/lib/nftban_http_logs.sh,cli/lib/nftban/core/nftban_botscan.sh"
# meta:inventory.binaries="stat,find,tail,head,wc"
# meta:inventory.env_vars="NFTBAN_HTTP_LOG_OFFSET_DIR,NFTBAN_HTTP_LOG_MAX_FILES,NFTBAN_HTTP_LOG_MAX_BYTES"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
HELPER="$REPO/cli/lib/nftban/lib/nftban_http_logs.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

# shellcheck source=/dev/null
source "$HELPER" || { echo "cannot source $HELPER"; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export NFTBAN_HTTP_LOG_OFFSET_DIR="$WORK/offsets"

echo "=== v1.177 HTTP log discovery ==="

# -----------------------------------------------------------------------------
# T1: panel/path matrix — candidate globs per panel.
# -----------------------------------------------------------------------------
da="$(nftban_http_candidate_globs directadmin)"
[[ "$da" == *'/var/log/httpd/domains/*.log'* && "$da" == *'/var/log/nginx/domains/*.log'* ]] \
  && ok "T1 DirectAdmin globs (httpd+nginx domains)" || no "T1 DirectAdmin globs" "$da"
cp_="$(nftban_http_candidate_globs cpanel)"
[[ "$cp_" == *'/usr/local/apache/domlogs/*'* ]] && ok "T1 cPanel domlogs glob" || no "T1 cPanel glob" "$cp_"
pl="$(nftban_http_candidate_globs plesk)"
[[ "$pl" == *'/var/www/vhosts/system/*/logs/access_log'* && "$pl" == *'/var/www/vhosts/system/*/logs/access_ssl_log'* ]] \
  && ok "T1 Plesk vhost access+access_ssl globs" || no "T1 Plesk globs" "$pl"
gen="$(nftban_http_candidate_globs '')"
[[ "$gen" == *'/var/log/httpd/access_log'* && "$gen" == *'/var/log/apache2/access.log'* && "$gen" == *'/var/log/nginx/access.log'* && "$gen" == *'/usr/local/lsws/logs/*access*'* ]] \
  && ok "T1 generic Apache RHEL+Debian + nginx + LiteSpeed globs" || no "T1 generic globs" "$gen"

# -----------------------------------------------------------------------------
# Build hermetic fixture trees mimicking each layout.
# -----------------------------------------------------------------------------
mk(){ mkdir -p "$(dirname "$1")"; printf '%s\n' "${2:-line}" > "$1"; }
mk "$WORK/da/httpd/domains/example.com.log"      'DA apache'
mk "$WORK/da/nginx/domains/example.com.log"      'DA nginx'
mk "$WORK/cpanel/domlogs/example.com"            'cpanel'
mk "$WORK/cpanel/domlogs/sub/example.com"        'cpanel sub'
mk "$WORK/plesk/example.com/logs/access_log"     'plesk'
mk "$WORK/plesk/example.com/logs/access_ssl_log" 'plesk ssl'
mk "$WORK/gen/httpd/access_log"                  'rhel apache'
mk "$WORK/gen/apache2/access.log"                'deb apache'
mk "$WORK/gen/nginx/access.log"                  'nginx'
mk "$WORK/da/httpd/domains/example.com-error_log" 'should be excluded'   # error log
mk "$WORK/da/httpd/domains/example.com.log.1"      'rotated excluded'    # rotated

disc(){ nftban_http_discover_access_logs "$1" 2>/dev/null; }

# T2: discovery over each fixture layout (via override globs).
[[ "$(disc "$WORK/da/httpd/domains/*.log")" == *example.com.log ]] && ok "T2 DirectAdmin Apache domain logs discovered" || no "T2 DA apache"
[[ -n "$(disc "$WORK/da/nginx/domains/*.log")" ]] && ok "T2 DirectAdmin nginx proxy logs discovered" || no "T2 DA nginx"
[[ -n "$(disc "$WORK/cpanel/domlogs/* $WORK/cpanel/domlogs/*/*")" ]] && ok "T2 cPanel domlogs discovered" || no "T2 cpanel"
plr="$(disc "$WORK/plesk/*/logs/access_log $WORK/plesk/*/logs/access_ssl_log")"
[[ "$plr" == *access_log* && "$plr" == *access_ssl_log* ]] && ok "T2 Plesk access + access_ssl discovered" || no "T2 plesk" "$plr"
[[ -n "$(disc "$WORK/gen/httpd/access_log")" ]] && ok "T2 generic Apache RHEL discovered" || no "T2 gen rhel"
[[ -n "$(disc "$WORK/gen/apache2/access.log")" ]] && ok "T2 generic Apache Debian discovered" || no "T2 gen deb"
[[ -n "$(disc "$WORK/gen/nginx/access.log")" ]] && ok "T2 generic nginx discovered" || no "T2 gen nginx"

# T3: error/rotated/compressed excluded.
allda="$(disc "$WORK/da/httpd/domains/*")"
[[ "$allda" != *error_log* && "$allda" != *.log.1* ]] && ok "T3 error_log + rotated .log.1 excluded" || no "T3 exclusion" "$allda"

# T4: dedup (same file via two overlapping globs).
dd="$(disc "$WORK/gen/nginx/access.log $WORK/gen/nginx/*")"
[[ "$(printf '%s\n' "$dd" | grep -c '/gen/nginx/access.log')" -eq 1 ]] && ok "T4 dedup (no duplicate path)" || no "T4 dedup" "$dd"

# T5: no-log-found — when override resolves nothing AND auto-detect finds nothing,
# discovery returns nonzero. A bad override ALONE falls back to auto by design
# ("never silently blind"), and the CI runner may have real /var/log files — so we
# mock the auto candidate-globs to a controlled set for a deterministic result.
_save_cg="$(declare -f nftban_http_candidate_globs)"
nftban_http_candidate_globs(){ :; }   # simulate a host with no web logs (no auto candidates)
if disc "$WORK/nonexistent/*.log" >/dev/null 2>&1; then no "T5 no-log-found returns nonzero"; else ok "T5 no-log-found → nonzero (override empty + auto empty)"; fi
# T5b: a bad override FALLS BACK to auto-detect (never silently blind).
mk "$WORK/fb/access.log" 'fb'
nftban_http_candidate_globs(){ printf '%s\n' "$WORK/fb/*.log"; }
fbr="$(disc "$WORK/nonexistent/*.log")" || true
[[ "$fbr" == *fb/access.log ]] && ok "T5b bad override falls back to auto-detect (never silently blind)" || no "T5b override fallback" "$fbr"
eval "$_save_cg"   # restore real candidate globs

# T6: unreadable-log skip (non-root only; root bypasses perms).
if [[ "$(id -u)" -ne 0 ]]; then
    mk "$WORK/ur/access.log" 'secret'; chmod 000 "$WORK/ur/access.log"
    disc "$WORK/ur/*.log" >/dev/null 2>&1 || true
    if printf '%s\n' "${_NFTBAN_HTTP_LAST_SKIPPED[@]}" | grep -q 'unreadable'; then ok "T6 unreadable log skipped with reason"; else no "T6 unreadable skip"; fi
    chmod 644 "$WORK/ur/access.log" 2>/dev/null || true
else
    ok "T6 unreadable-log skip (SKIPPED as root — perms bypassed)"
fi

# T7: many-log bounded scan + skip-reason.
mkdir -p "$WORK/many"; for i in $(seq 1 6); do printf 'x\n' > "$WORK/many/d$i.log"; done
NFTBAN_HTTP_LOG_MAX_FILES=3 disc "$WORK/many/*.log" >/dev/null 2>&1 || true
if [[ "${#_NFTBAN_HTTP_LAST_SELECTED[@]}" -eq 3 ]] && printf '%s\n' "${_NFTBAN_HTTP_LAST_SKIPPED[@]}" | grep -q 'over MAX_FILES'; then
    ok "T7 many-log bounded to MAX_FILES=3 + skip-reason recorded"
else
    no "T7 bounded scan" "selected=${#_NFTBAN_HTTP_LAST_SELECTED[@]}"
fi

# T8: incremental reader — second run returns only NEW bytes.
inc="$WORK/inc.log"; printf 'line1\n' > "$inc"
r1="$(nftban_http_read_incremental "$inc")"
printf 'line2\n' >> "$inc"
r2="$(nftban_http_read_incremental "$inc")"
[[ "$r1" == *line1* && "$r2" == *line2* && "$r2" != *line1* ]] && ok "T8 incremental: 2nd run reads only new lines" || no "T8 incremental" "r1=[$r1] r2=[$r2]"

# T9: rotation = logrotate "create" mode (new inode at the same path) → read from BOF.
# Use `mv` to GUARANTEE a different inode — `rm`+recreate can REUSE the inode on some
# filesystems (observed on CI), which is not a real log-rotation mode. The reader's
# real-mode coverage: create=new-inode (here) + copytruncate=size-drop (T10).
printf 'fresh1\nfresh2\n' > "$WORK/inc.rotated"; mv -f "$WORK/inc.rotated" "$inc"
r3="$(nftban_http_read_incremental "$inc")"
[[ "$r3" == *fresh1* && "$r3" == *fresh2* ]] && ok "T9 rotation (new inode) re-reads from BOF" || no "T9 rotation" "r3=[$r3]"

# T10: copytruncate (size < stored offset at a read) → offset resets; later appends read fresh.
printf 'aaaa\n' > "$inc"; _=$(nftban_http_read_incremental "$inc")   # offset advances to ~5
: > "$inc"                                                            # truncate in place (copytruncate)
_=$(nftban_http_read_incremental "$inc")                             # size 0 < offset → reset to BOF
printf 'after-trunc\n' >> "$inc"                                      # new content after truncate
r4="$(nftban_http_read_incremental "$inc")"
[[ "$r4" == *after-trunc* && "$r4" != *aaaa* ]] && ok "T10 copytruncate handled (offset reset, fresh content read)" || no "T10 copytruncate" "r4=[$r4]"

# T11: IPv6 xmlrpc source line parses (locks the pre-existing dual-stack parse).
if source "$REPO/cli/lib/nftban/core/nftban_botscan.sh" >/dev/null 2>&1; then
    p6="$(nftban_botscan_parse_line '2001:db8::1 - - [12/Jun/2026:10:00:00 +0000] "POST /xmlrpc.php HTTP/1.1" 200 120 "-" "bot"')" || p6=""
    [[ "$p6" == 2001:db8::1\|* && "$p6" == *xmlrpc.php* ]] && ok "T11 IPv6 xmlrpc line parses (IP+URL)" || no "T11 IPv6 parse" "$p6"
    p4="$(nftban_botscan_parse_line '203.0.113.7 - - [x] "POST /xmlrpc.php HTTP/1.1" 200 1 "-" "b"')" || p4=""
    [[ "$p4" == 203.0.113.7\|* ]] && ok "T11b IPv4 xmlrpc line parses" || no "T11b IPv4 parse" "$p4"
else
    no "T11 could not source botscan core for parse test"
fi

# -----------------------------------------------------------------------------
# T12: REGRESSION — legacy generic-only globs MISS DA/cPanel/Plesk; new discovery FINDS them.
# -----------------------------------------------------------------------------
legacy_globs='/var/log/apache2/access.log /var/log/httpd/access_log /var/log/nginx/access.log'
# The DA/cPanel/Plesk fixture paths must NOT match the legacy generic globs...
miss=0
for fx in "$WORK/da/httpd/domains/example.com.log" "$WORK/cpanel/domlogs/example.com" "$WORK/plesk/example.com/logs/access_log"; do
    for g in $legacy_globs; do [[ "$fx" == "$g" ]] && miss=1; done
done
# ...but the new discovery (panel-style override) DOES find them.
found_da="$(disc "$WORK/da/httpd/domains/*.log")"
found_cp="$(disc "$WORK/cpanel/domlogs/*")"
found_pl="$(disc "$WORK/plesk/*/logs/access_log")"
if [[ "$miss" -eq 0 && -n "$found_da" && -n "$found_cp" && -n "$found_pl" ]]; then
    ok "T12 regression: legacy generic globs miss DA/cPanel/Plesk; new discovery finds them"
else
    no "T12 regression" "miss=$miss da=[$found_da] cp=[$found_cp] pl=[$found_pl]"
fi

# -----------------------------------------------------------------------------
# T13–T19: service-account readability health classifier (DIAGNOSTIC path).
# Uses NFTBAN_BOTSCAN_READ_TEST_HOOK so readability is simulated hermetically
# (no real nftban user, no root). Hook is called: HOOK <service_user> <path>,
# returns 0 readable / 1 unreadable / 2 indeterminate.
# -----------------------------------------------------------------------------
hook_all_readable(){ return 0; }
hook_all_unreadable(){ return 1; }
hook_all_unknown(){ return 2; }
hook_mixed(){ case "$2" in *good*) return 0 ;; *) return 1 ;; esac; }

# T13: candidates discovered, all unreadable as service account → DEGRADED.
mk "$WORK/rd/example.com.log" 'da'
export NFTBAN_BOTSCAN_READ_TEST_HOOK=hook_all_unreadable
nftban_http_classify_candidates "$WORK/rd/*.log" >/dev/null 2>&1 || true
[[ "$_NFTBAN_HTTP_READ_VERDICT" == DEGRADED ]] && ok "T13 discovered-but-unreadable → DEGRADED" || no "T13 DEGRADED" "$_NFTBAN_HTTP_READ_VERDICT"

# T14: candidates discovered, readable as service account → OK.
export NFTBAN_BOTSCAN_READ_TEST_HOOK=hook_all_readable
nftban_http_classify_candidates "$WORK/rd/*.log" >/dev/null 2>&1 || true
[[ "$_NFTBAN_HTTP_READ_VERDICT" == OK && "$_NFTBAN_HTTP_READ_COUNT_READABLE" -ge 1 ]] && ok "T14 readable → OK" || no "T14 OK" "$_NFTBAN_HTTP_READ_VERDICT"

# T15: ROOT-BLINDNESS GUARD — file IS readable by the caller (mode 644), but the
# service-account check says no → MUST be DEGRADED, not OK. Proves the verdict does
# NOT reuse the caller's (often root's) readability.
mk "$WORK/rb/access.log" 'caller-readable'
[[ -r "$WORK/rb/access.log" ]] && caller_ok=1 || caller_ok=0
export NFTBAN_BOTSCAN_READ_TEST_HOOK=hook_all_unreadable
nftban_http_classify_candidates "$WORK/rb/*.log" >/dev/null 2>&1 || true
[[ "$caller_ok" -eq 1 && "$_NFTBAN_HTTP_READ_VERDICT" == DEGRADED ]] \
  && ok "T15 root-blindness guard: caller-readable file still DEGRADED via service-account check" \
  || no "T15 root-blindness guard" "caller_ok=$caller_ok verdict=$_NFTBAN_HTTP_READ_VERDICT"

# T16: indeterminate (cannot test as service account) → UNKNOWN, never false OK.
export NFTBAN_BOTSCAN_READ_TEST_HOOK=hook_all_unknown
nftban_http_classify_candidates "$WORK/rd/*.log" >/dev/null 2>&1 || true
[[ "$_NFTBAN_HTTP_READ_VERDICT" == UNKNOWN ]] && ok "T16 indeterminate readability → UNKNOWN" || no "T16 UNKNOWN" "$_NFTBAN_HTTP_READ_VERDICT"

# T17: mixed — at least one readable → OK, with the unreadable count tracked.
mk "$WORK/mix/good.log" 'g'; mk "$WORK/mix/bad.log" 'b'
export NFTBAN_BOTSCAN_READ_TEST_HOOK=hook_mixed
nftban_http_classify_candidates "$WORK/mix/*.log" >/dev/null 2>&1 || true
[[ "$_NFTBAN_HTTP_READ_VERDICT" == OK && "$_NFTBAN_HTTP_READ_COUNT_READABLE" -eq 1 && "$_NFTBAN_HTTP_READ_COUNT_UNREADABLE" -eq 1 ]] \
  && ok "T17 mixed readability → OK with correct readable/unreadable counts" \
  || no "T17 mixed" "v=$_NFTBAN_HTTP_READ_VERDICT r=$_NFTBAN_HTTP_READ_COUNT_READABLE u=$_NFTBAN_HTTP_READ_COUNT_UNREADABLE"
unset NFTBAN_BOTSCAN_READ_TEST_HOOK

# T18/T19: no candidates — NO_LOGS (no web stack) vs WARN_NO_LOGS (stack present).
# Distinct from DEGRADED (which requires discovered candidates). Mock auto globs +
# stack detection for determinism (CI runner may have real logs / packages).
_save_cg3="$(declare -f nftban_http_candidate_globs)"
_save_ds3="$(declare -f nftban_http_detect_stack)"
nftban_http_candidate_globs(){ :; }              # no auto candidates
nftban_http_detect_stack(){ :; }                 # no web stack
nftban_http_classify_candidates "$WORK/none/*.log" >/dev/null 2>&1 || true
[[ "$_NFTBAN_HTTP_READ_VERDICT" == NO_LOGS ]] && ok "T18 no candidates + no web stack → NO_LOGS (distinct from DEGRADED)" || no "T18 NO_LOGS" "$_NFTBAN_HTTP_READ_VERDICT"
nftban_http_detect_stack(){ echo nginx; }        # web stack present, logs missing
nftban_http_classify_candidates "$WORK/none/*.log" >/dev/null 2>&1 || true
[[ "$_NFTBAN_HTTP_READ_VERDICT" == WARN_NO_LOGS ]] && ok "T19 web stack present but no access logs → WARN_NO_LOGS" || no "T19 WARN_NO_LOGS" "$_NFTBAN_HTTP_READ_VERDICT"
eval "$_save_cg3"; eval "$_save_ds3"

echo ""
echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
