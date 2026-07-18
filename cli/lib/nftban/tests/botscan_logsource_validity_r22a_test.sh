#!/usr/bin/env bash
# =============================================================================
# NFTBan - BotScan log-source validity & health-state truth (R22A) tests
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="botscan_logsource_validity_r22a"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-18"
# meta:description="R22A BotScan log-source VALIDITY & health-state truth. Locks: cPanel domlogs excludes non-HTTP files (ftpxferlog/.offset/.bytes/-imap_log); readable non-HTTP content -> INVALID_SOURCE (the false-healthy fix); empty valid access log -> NEVER_OBSERVED (bound, no data; not OK, not DEGRADED); valid-but-quiet -> OK (never falsely DEGRADED); valid active -> OK; Plesk empty access_log -> NEVER_OBSERVED; DirectAdmin valid preserved -> OK; mixed valid+invalid -> OK with invalid counted; nginx JSON escaped-slash access log -> OK; ftp.example.com domain not over-excluded. Hermetic: temp trees, readability test-hook forces service-account readability so CONTENT validity is what is exercised; no root, no nft, no bans."
# meta:inventory.files="cli/lib/nftban/lib/nftban_http_logs.sh"
# meta:inventory.binaries="bash,grep,tail,stat,date,mktemp,printf"
# meta:inventory.env_vars="NFTBAN_BOTSCAN_READ_TEST_HOOK,NFTBAN_BOTSCAN_SERVICE_USER,NFTBAN_HTTP_LOG_MAX_FILES,NFTBAN_HTTP_ACTIVITY_WINDOW_SEC"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO/cli/lib/nftban/lib/nftban_http_logs.sh"

P=0; F=0
ok(){ echo "  ✓ $1"; P=$((P+1)); }
no(){ echo "  ✗ $1 ${2:-}"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

AL(){ printf '203.0.113.7 - - [01/Jan/2026:12:00:00 +0000] "GET /%s HTTP/1.1" 200 128 "-" "r22a"\n' "${1:-x}"; }

# Force readability-as-service so the CONTENT-validity path is what is tested.
# (env-var hook consumed by nftban_http_service_can_read in the sourced lib)
allread(){ return 0; }
export NFTBAN_BOTSCAN_READ_TEST_HOOK=allread

echo "=== R22A BotScan log-source validity & health-state truth ==="

# --- CLASS exclusion on the BIND path: cPanel domlogs must reject non-HTTP files ---
mkdir -p "$WORK/cp/domlogs"
AL example.com > "$WORK/cp/domlogs/example.com"                 # valid HTTP access log
AL example.com > "$WORK/cp/domlogs/example.com-ssl_log"         # valid (ssl access)
printf 'ftp transfer junk\n'   > "$WORK/cp/domlogs/ftpxferlog"          # FTP transfer log
printf 'binary\n'              > "$WORK/cp/domlogs/example.com.offset"  # offset state file
printf '12345\n'               > "$WORK/cp/domlogs/example.com.bytes"   # byte-count state
printf 'imap login junk\n'     > "$WORK/cp/domlogs/example.com-imap_log" # mail log
sel="$(nftban_http_discover_access_logs "$WORK/cp/domlogs/*" 2>/dev/null)"
[[ "$sel" == *"/example.com"* ]] && ok "cPanel binds the valid HTTP access log" || no "cpanel valid bind" "$sel"
if [[ "$sel" != *ftpxferlog* && "$sel" != *.offset* && "$sel" != *.bytes* && "$sel" != *imap_log* ]]; then
    ok "cPanel EXCLUDES ftpxferlog/.offset/.bytes/-imap_log (non-HTTP)"
else no "cpanel exclusion" "$sel"; fi

# --- CONTENT (bind): a non-empty non-HTTP file is NOT bound for scanning ---
mkdir -p "$WORK/inv"; printf 'this is not an http access log\nrandom junk line\n' > "$WORK/inv/access.log"
selinv="$(nftban_http_discover_access_logs "$WORK/inv/*.log" 2>/dev/null || true)"
[[ -z "$selinv" ]] && ok "non-HTTP content NOT bound for scanning (bind-path validity)" || no "invalid not bound" "$selinv"

# --- HEALTH: readable non-HTTP content → INVALID_SOURCE (the false-healthy FIX) ---
v="$(nftban_http_classify_candidates "$WORK/inv/*.log" 2>/dev/null)"
[[ "$v" == "INVALID_SOURCE" ]] && ok "readable non-HTTP content → INVALID_SOURCE (never healthy)" || no "invalid_source verdict" "$v"

# --- EMPTY valid path → NEVER_OBSERVED (bound, no data; not OK, not DEGRADED) ---
mkdir -p "$WORK/emp"; : > "$WORK/emp/access.log"
v="$(nftban_http_classify_candidates "$WORK/emp/*.log" 2>/dev/null)"
[[ "$v" == "NEVER_OBSERVED" ]] && ok "empty valid access log → NEVER_OBSERVED (not OK, not DEGRADED)" || no "never_observed verdict" "$v"
# and an empty valid log IS still bound (correct source, no data yet)
selemp="$(nftban_http_discover_access_logs "$WORK/emp/*.log" 2>/dev/null || true)"
[[ "$selemp" == *"/access.log"* ]] && ok "empty valid access log is still BOUND (correct source)" || no "empty bound" "$selemp"

# --- VALID quiet (old mtime) → OK, never falsely DEGRADED ---
mkdir -p "$WORK/q"; AL quiet > "$WORK/q/access.log"; touch -d '2020-01-01 00:00:00' "$WORK/q/access.log" 2>/dev/null || true
v="$(nftban_http_classify_candidates "$WORK/q/*.log" 2>/dev/null)"
[[ "$v" == "OK" ]] && ok "valid-but-quiet access log → OK (NOT DEGRADED)" || no "valid_quiet verdict" "$v"

# --- VALID active → OK ---
mkdir -p "$WORK/a"; AL active > "$WORK/a/access.log"
v="$(nftban_http_classify_candidates "$WORK/a/*.log" 2>/dev/null)"
[[ "$v" == "OK" ]] && ok "valid active access log → OK" || no "valid_active verdict" "$v"

# --- Plesk empty access_log → NEVER_OBSERVED ---
mkdir -p "$WORK/pl/example.com/logs"; : > "$WORK/pl/example.com/logs/access_log"
v="$(nftban_http_classify_candidates "$WORK/pl/*/logs/access_log" 2>/dev/null)"
[[ "$v" == "NEVER_OBSERVED" ]] && ok "Plesk empty access_log → NEVER_OBSERVED" || no "plesk empty verdict" "$v"

# --- DirectAdmin valid preserved → OK (no regression) ---
mkdir -p "$WORK/da/domains"; AL da > "$WORK/da/domains/example.com.log"
v="$(nftban_http_classify_candidates "$WORK/da/domains/*.log" 2>/dev/null)"
[[ "$v" == "OK" ]] && ok "DirectAdmin valid domain log → OK (preserved)" || no "da preserved verdict" "$v"

# --- MIXED valid + invalid readable → OK (a valid source wins), invalid counted ---
# Call classify DIRECTLY (not in $(...)) so the per-state global counters are
# visible in this shell.
mkdir -p "$WORK/mix"; AL good > "$WORK/mix/example.com"; printf 'not http at all\n' > "$WORK/mix/other.log"
nftban_http_classify_candidates "$WORK/mix/example.com $WORK/mix/other.log" >/dev/null 2>&1 || true
v="$_NFTBAN_HTTP_READ_VERDICT"
if [[ "$v" == "OK" && "${_NFTBAN_HTTP_COUNT_VALID}" -ge 1 && "${_NFTBAN_HTTP_COUNT_INVALID}" -ge 1 ]]; then
    ok "mixed valid+invalid → OK (valid wins), invalid counted"
else no "mixed verdict" "v=$v valid=${_NFTBAN_HTTP_COUNT_VALID} invalid=${_NFTBAN_HTTP_COUNT_INVALID}"; fi

# --- nginx JSON access log (escaped slash "GET \/ HTTP\/1.1") → OK, NOT INVALID ---
mkdir -p "$WORK/js"
printf '{"remote":"203.0.113.5","request":"GET \\/wp-login.php HTTP\\/1.1","status":200}\n' > "$WORK/js/access.json"
v="$(nftban_http_classify_candidates "$WORK/js/*.json" 2>/dev/null)"
[[ "$v" == "OK" ]] && ok "nginx JSON access log (escaped slash) → OK (not false INVALID)" || no "json escaped-slash" "$v"
# and access.json must NOT be name-excluded (a JSON-formatted access log is valid)
seljs="$(nftban_http_discover_access_logs "$WORK/js/*.json" 2>/dev/null || true)"
[[ "$seljs" == *access.json* ]] && ok "access.json bound (not excluded by name)" || no "json name-excluded" "$seljs"

# --- domain literally containing 'ftp' must NOT be over-excluded ---
mkdir -p "$WORK/dom/domlogs"; AL x > "$WORK/dom/domlogs/ftp.example.com"
seld="$(nftban_http_discover_access_logs "$WORK/dom/domlogs/*" 2>/dev/null || true)"
[[ "$seld" == *ftp.example.com* ]] && ok "ftp.example.com access log NOT over-excluded" || no "ftp-domain over-excluded" "$seld"

echo "=== RESULT: $P passed, $F failed ==="
[[ $F -eq 0 ]]
