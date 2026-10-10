#!/usr/bin/env bash
# =============================================================================
# NFTBan - Bot Scanner Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# Purpose: Detect and block bot scanners, webshell probes, exploit attempts
#
# meta:name="nftban_botscan"
# meta:type="core"
# meta:header="Bot Scanner Detection Engine"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="Bot scanner detection using pattern matching on access logs"
# meta:inventory.files="/usr/lib/nftban/core/nftban_botscan.sh"
# meta:inventory.binaries="nft,grep,awk"
# meta:inventory.env_vars="BOTSCAN_ENABLED,BOTSCAN_PATTERNS_DIR"
# meta:inventory.config_files="/etc/nftban/conf.d/botscan/main.conf"
# meta:inventory.systemd_units="none"
# meta:inventory.network="none"
# meta:inventory.privileges="root:read-logs,nftables"
# meta:created_date="2026-01-11"
# meta:updated_date="2026-01-11"
# =============================================================================

# Enhanced strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_BOTSCAN_LOADED:-}" ]] && return 0
readonly NFTBAN_BOTSCAN_LOADED=1

# =============================================================================
# SHARED LIBRARIES
# =============================================================================

# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_file_utils.sh" 2>/dev/null || true
# v1.177: shared panel-aware HTTP access-log discovery (DirectAdmin/cPanel/Plesk).
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_http_logs.sh" 2>/dev/null || true
# v1.207 — smart-adaptive controller (pressure/backlog/mode/health/recording-discipline).
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_botscan_adaptive.sh" 2>/dev/null || true

# =============================================================================
# CONFIGURATION
# =============================================================================

# Load config if not already loaded
nftban_botscan_load_config() {
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/botscan/main.conf"
    local config_local="${config_file}.local"

    # Defaults
    : "${BOTSCAN_ENABLED:=true}"
    : "${BOTSCAN_ACTION_MODE:=both}"
    : "${BOTSCAN_LOG_AUTO:=true}"
    : "${BOTSCAN_LOG_APACHE:=/var/log/apache2/access.log}"
    : "${BOTSCAN_LOG_APACHE_ALT:=/var/log/httpd/access_log}"
    : "${BOTSCAN_LOG_NGINX:=/var/log/nginx/access.log}"
    # v1.177: optional multi-path/glob override (space/newline list). When set it is
    # preferred; if it resolves to no readable file we fall back to panel-aware
    # auto-detect (never silently blind). Legacy single-path vars above stay honored.
    : "${BOTSCAN_LOG_PATHS:=}"
    # v1.178-A: read-authority spool produced by nftban-botscan-collector.service.
    : "${BOTSCAN_SPOOL_DIR:=/var/lib/nftban/botscan/spool}"
    : "${BOTSCAN_DEFAULT_THRESHOLD:=5}"
    : "${BOTSCAN_DEFAULT_WINDOW:=60}"
    : "${BOTSCAN_DEFAULT_BAN_SHORT:=1800}"
    : "${BOTSCAN_DEFAULT_BAN_LONG:=7200}"
    : "${BOTSCAN_404_TRACKING:=true}"
    : "${BOTSCAN_404_THRESHOLD:=50}"
    : "${BOTSCAN_404_WINDOW:=300}"
    : "${BOTSCAN_404_BAN:=3600}"
    # BOTSCAN-ENDPOINT-FLOOD (PROTECTION-CLAIM-MATRIX HIGH) — per-IP/per-endpoint POST
    # volume to sensitive endpoints (xmlrpc.php / wp-login.php), STATUS-INDEPENDENT (200
    # counts — WordPress xmlrpc brute/amplification returns 200). Owner: BotScan. NOT
    # LoginMon (credential-failure only; cannot see the 200-body auth result) and NOT
    # BotGuard (L3/L4 burst/concurrency only). Counted in the proven 404-tail re-read so it
    # inherits 404-flood reliability; emitted via the batch-signal path (never the buggy
    # direct ban_ip --duration branch, BUG-BOTSCAN-DIRECT-BAN-FLAG).
    : "${BOTSCAN_ENDPOINT_FLOOD_ENABLED:=true}"
    : "${BOTSCAN_ENDPOINT_FLOOD_METHOD:=POST}"
    : "${BOTSCAN_ENDPOINT_FLOOD_THRESHOLD:=30}"   # POSTs / window / IP / endpoint (lab-tuned; well above legit Jetpack/pingback)
    : "${BOTSCAN_ENDPOINT_FLOOD_WINDOW:=60}"
    : "${BOTSCAN_ENDPOINT_FLOOD_BAN:=3600}"
    : "${BOTSCAN_ENDPOINT_FLOOD_ENDPOINTS:=xmlrpc.php wp-login.php}"
    # v1.234.0 — the v1.192.2 WP-admin "authenticated context" gate is RETIRED
    # (BUG-BOTSCAN-WPADMIN-AUTH-CONTEXT-IS-CYCLE-SCOPED-BANS-LOGGED-IN-EDITORS).
    # It inferred a login from `POST /wp-login.php -> 302` and then suppressed EXP_WPREST /
    # WS_WPADMIN for that IP for one cycle. An access log cannot prove an application
    # session: a 302 is also returned for lost-password, logout and interim flows, and a
    # real session outlives both the 10-minute cycle and the client's IP (measured on a
    # production host: three false bans of one editor in one day). BotScan now reports
    # authentication context as UNKNOWN and does not need it: the false positive came
    # from a substring match (`/wp-json/wp/v2/users` matched `/users/me`, which the
    # editor polls), which the pattern contract below corrects for every client.
    # BOTSCAN_WPADMIN_CONTEXT_GATE / _PATTERNS / _LOGIN_PATH are no longer read.
    # v1.187 Lane A — BOTSCAN-SCAN-THROUGHPUT. Forward-cursor per-file per-cycle window
    # (drains backlog forward instead of the v1.185 64 KiB tail-bias), a C-speed candidate
    # prefilter before the per-line bash matcher, and an independent 404 fixed-tail re-read
    # window (Option 1) that preserves 404-burst detection the forward cursor would fragment.
    : "${BOTSCAN_SCAN_MAX_BYTES_PER_FILE:=1048576}"
    : "${BOTSCAN_SCAN_PREFILTER:=true}"
    : "${BOTSCAN_404_TAIL_BYTES:=2097152}"
    # v1.187.1 — per-cycle A4 404-tail total-bytes backstop (bounds budget=0/interactive runs;
    # the shared soft-deadline bounds normal cycles). Default 32 MiB.
    : "${BOTSCAN_404_TAIL_TOTAL_BYTES:=33554432}"
    : "${BOTSCAN_PROGRESSIVE_ENABLED:=true}"
    : "${BOTSCAN_PROGRESSIVE_MULTIPLIER:=2}"
    : "${BOTSCAN_PROGRESSIVE_MAX:=86400}"
    : "${BOTSCAN_PATTERNS_DIR:=${NFTBAN_CONFIG_DIR:-/etc/nftban}/patterns.d/botscan}"
    : "${BOTSCAN_WHITELIST_BOTS:=googlebot,bingbot,yandexbot,duckduckbot,slurp,facebot}"
    # v1.189 FCrDNS — verified-crawler whitelist (forward-confirmed rDNS at analyze-time).
    : "${BOTSCAN_VERIFY_CRAWLERS:=true}"   # off = legacy UA-substring blanket whitelist
    : "${BOTSCAN_VERIFY_TIMEOUT:=2}"       # per-lookup hard timeout (s); realistic for cold rDNS, still bounded (PTR+forward ≤ ~4s/IP)
    : "${BOTSCAN_VERIFY_CACHE_DIR:=${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/crawler-verify}"
    : "${BOTSCAN_VERIFY_TTL_OK:=86400}"    # positive (verified) cache TTL
    : "${BOTSCAN_VERIFY_TTL_BAD:=21600}"   # negative (mismatch/NXDOMAIN) TTL (6h)
    : "${BOTSCAN_VERIFY_TTL_ERR:=1800}"    # timeout/resolver-error TTL (30m)
    : "${BOTSCAN_WHITELIST_PATHS:=/robots\\.txt|/favicon\\.ico|/sitemap\\.xml|/ads\\.txt}"
    : "${BOTSCAN_USE_GLOBAL_WHITELIST:=true}"
    : "${BOTSCAN_STATE_FILE:=${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan-state.db}"
    : "${BOTSCAN_LOG_FILE:=${NFTBAN_LOG_DIR:-/var/log/nftban}/botscan.log}"
    : "${BOTSCAN_DEBUG:=false}"

    # Source config files
    # shellcheck source=/dev/null
    source "$config_file" 2>/dev/null || true
    # shellcheck source=/dev/null
    # IMPL-1: ensure _source_local is defined wherever this file is loaded (env.sh idempotent)
    declare -F _source_local >/dev/null 2>&1 || source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/env.sh" 2>/dev/null || true
    # v1.234.0 (BUG-BOTSCAN-OVERRIDE-LOCAL-CREATED-UNREADABLE-BY-SCANNER): _source_local
    # skips an unreadable file without a word, so an operator override that the scanner's
    # account cannot read looked applied and was not. Say so (never an error: defaults apply).
    [[ -e "$config_local" && ! -r "$config_local" ]] && _botscan_warn_unreadable "$config_local"
    _source_local "$config_local"
    return 0
}

# v1.234.0 — one visible warning (stderr + syslog) for an operator file BotScan must read
# but cannot (typically root:root 0600 while the scanner runs as the service account).
_botscan_warn_unreadable() {
    local f="${1:-?}"
    printf "[WARN] botscan: %s exists but is NOT readable by %s — its settings are IGNORED (expected mode 0640, group of %s)\n" \
        "$f" "$(id -un 2>/dev/null || echo "uid $(id -u)")" "$(dirname -- "$f")" >&2
    if command -v logger >/dev/null 2>&1; then
        logger -t nftban-botscan -p user.warning "unreadable operator file ignored: $f" 2>/dev/null || true
    fi
    return 0
}

# =============================================================================
# STATE MANAGEMENT
# =============================================================================

# Associative arrays for tracking
declare -gA _BOTSCAN_IP_HITS        # IP -> hit count
# v1.219.0 truth-fix: batch signals emitted this cycle.
# v1.231.0 P0-B: this variable is now a PARENT-SIDE MIRROR of the durable counter
# sink below, reconciled in nftban_botscan_process_logs once the analyze fork has
# exited. It is NOT the authority — see the sink block for why it cannot be.
declare -gi _BOTSCAN_SIGNALS_EMITTED=0
# v1.231.0 P0-B — cross-boundary counter sink state (see the sink block below).
declare -g  _BOTSCAN_COUNTER_FILE=""
declare -gi _BOTSCAN_COUNTER_OWNED=0   # 1 = this process created it and must remove it
declare -gA _BOTSCAN_IP_PATTERNS    # IP -> matched patterns
declare -gA _BOTSCAN_IP_FIRST_SEEN  # IP -> first seen timestamp
declare -gA _BOTSCAN_IP_LAST_SEEN   # IP -> last seen timestamp
declare -gA _BOTSCAN_IP_404_COUNT      # IP -> 404 count
declare -gA _BOTSCAN_IP_404_FIRST_SEEN # IP -> EARLIEST counted REQUEST time (v1.234: log-line time, never scan time)
declare -gA _BOTSCAN_IP_404_LAST_SEEN  # IP -> LATEST counted REQUEST time (v1.234)
declare -gA _BOTSCAN_PATTERNS          # Pattern name -> pattern definition
declare -gA _BOTSCAN_IP_CRAWLER_CLAIM  # v1.189 FCrDNS: IP -> claimed search-crawler family (UA-claimed; verified at analyze-time)
declare -gA _BOTSCAN_IP_ENDPOINT_COUNT      # BOTSCAN-ENDPOINT-FLOOD: "ip|endpoint" -> POST count (status-independent)
declare -gA _BOTSCAN_IP_ENDPOINT_FIRST_SEEN # "ip|endpoint" -> EARLIEST counted REQUEST time (cycle-scoped, reset by count_404_tail)
declare -gA _BOTSCAN_IP_ENDPOINT_LAST_SEEN  # "ip|endpoint" -> LATEST counted REQUEST time (v1.234)
declare -ga _BOTSCAN_ENDPOINT_FLOOD_LIST    # parsed endpoint tokens (rebuilt per cycle)
# v1.234.0 — pattern evidence in REQUEST time (BUG-BOTSCAN-PATTERN-WINDOW-USES-SCAN-TIME-NOT-REQUEST-TIME)
declare -gA _BOTSCAN_DISTINCT_SEEN          # "ip<US>pattern<US>target" -> 1 (distinct-* patterns count a target once)
declare -gA _BOTSCAN_IPPAT_TS               # "ip<US>pattern" -> space-separated request epochs (each pattern judged on its own evidence)
declare -ga _BS_MATCHES=() _BS_MATCH_MODES=()   # every pattern the current line matched (match_url_g)
declare -gA _BOTSCAN_PROBE_TS                 # IP -> request epochs of DISTINCT probe targets across distinct-* rules
declare -gA _BOTSCAN_PROBE_SEEN               # "ip<US>target" -> 1 (a target counts once in the cross-rule probe aggregate)
declare -g  _BS_CYCLE_NOW=""                # the cycle's reference "now" (nftban_timestamp_unix), set by init_state
declare -gi _BS_T_PAT_STALE=0 _BS_T_PAT_UNREADABLE=0 _BS_T_PAT_FUTURE=0 _BS_T_PAT_REPEAT=0
declare -gi _BS_T_TAIL_UNREADABLE=0 _BS_T_TAIL_FUTURE=0 _BS_T_UA_UNPARSED=0

# v1.234.0 — EVIDENCE HORIZON D for URL/UA pattern evidence (design V1_234_0_BOTSCAN404_DESIGN.md
# §15 C3: a burst is actionable iff max(ts)-min(ts) <= W AND 0 <= now-max(ts) <= D).
# Pattern lines arrive through the FORWARD cursor, so each byte is examined once and a
# normal delivery delay (collector period + processor period + one run) is expected; D must
# cover it or real attacks go undetected. Evidence older than D (a drained backlog, a
# re-delivered object) is out of contract: it is COUNTED as stale and REPORTED, never
# enforced. D is DERIVED from the shipped timer units, not a tunable (owner: no new config key
# for D in this release); botscan_detection_correctness_v1234_test fails if the units drift
# above these bounds. PROVISIONAL: the deterministic service bound is PR-1 work.
readonly _BS_COLLECTOR_PERIOD_MAX=390     # nftban-botscan-collector.timer OnUnitActiveSec 5min + RandomizedDelaySec 1min + AccuracySec 30s
readonly _BS_PROCESSOR_PERIOD_MAX=750     # nftban-botscan.timer OnUnitActiveSec 10min + RandomizedDelaySec 2min + AccuracySec 30s
readonly _BS_PROCESSOR_RUN_MAX=300        # nftban-botscan.service TimeoutStartSec
# One skipped cycle of each timer (shared lock contention) plus one full processor run.
readonly _BS_PATTERN_EVIDENCE_HORIZON=$(( 2 * _BS_COLLECTOR_PERIOD_MAX + 2 * _BS_PROCESSOR_PERIOD_MAX + _BS_PROCESSOR_RUN_MAX ))

# Initialize state
nftban_botscan_init_state() {
    _BOTSCAN_IP_HITS=()
    _BOTSCAN_IP_PATTERNS=()
    _BOTSCAN_IP_FIRST_SEEN=()
    _BOTSCAN_SIGNALS_EMITTED=0   # v1.219.0 truth-fix: real per-cycle batch-signal count (was always 0)
    _BOTSCAN_IP_LAST_SEEN=()
    _BOTSCAN_IP_404_COUNT=()
    _BOTSCAN_IP_404_FIRST_SEEN=()
    _BOTSCAN_IP_404_LAST_SEEN=()
    _BOTSCAN_IP_CRAWLER_CLAIM=()
    _BOTSCAN_IP_ENDPOINT_COUNT=()
    _BOTSCAN_IP_ENDPOINT_FIRST_SEEN=()
    _BOTSCAN_IP_ENDPOINT_LAST_SEEN=()
    _BOTSCAN_ENDPOINT_FLOOD_LIST=()
    _BOTSCAN_DISTINCT_SEEN=()
    _BOTSCAN_IPPAT_TS=()
    _BOTSCAN_PROBE_TS=()
    _BOTSCAN_PROBE_SEEN=()
    _BS_T_PAT_STALE=0; _BS_T_PAT_UNREADABLE=0; _BS_T_PAT_FUTURE=0; _BS_T_PAT_REPEAT=0
    _BS_T_TAIL_UNREADABLE=0; _BS_T_TAIL_FUTURE=0; _BS_T_UA_UNPARSED=0
    # One reference "now" per cycle (overridable through nftban_timestamp_unix, like the tail).
    _BS_CYCLE_NOW="$(nftban_timestamp_unix 2>/dev/null || date +%s)"
    [[ "$_BS_CYCLE_NOW" =~ ^[0-9]+$ ]] || printf -v _BS_CYCLE_NOW '%(%s)T' -1
    # IFS=' ' is REQUIRED: the module runs under strict IFS=$'\n\t' (no space) → a bare
    # read -ra would yield ONE token "xmlrpc.php wp-login.php" that never matches (v1.186.1 class).
    [[ "${BOTSCAN_ENDPOINT_FLOOD_ENABLED:-true}" == "true" ]] && IFS=' ' read -ra _BOTSCAN_ENDPOINT_FLOOD_LIST <<< "${BOTSCAN_ENDPOINT_FLOOD_ENDPOINTS:-}"
    # v1.231.0 P0-B — open this cycle's cross-boundary counter sink.
    nftban_botscan_counters_reset
    # ⛔ EXPLICIT: the `[[ ... ]] && ...` above is the reason this `return 0` exists.
    # With BOTSCAN_ENDPOINT_FLOOD_ENABLED=false that AND-list is the value of the
    # function and init_state returned 1. cli/lib/nftban/cli/cmd_botscan.sh arms
    # `set -Eeuo pipefail` and calls nftban_botscan_check -> process_logs ->
    # init_state as a BARE command, so a documented config key aborted the entire
    # scan cycle before a single log line was read. A function's terminal status is
    # part of its contract — state it, never inherit it from the last conditional.
    return 0
}

# =============================================================================
# CROSS-BOUNDARY COUNTER SINK (v1.231.0 P0-B)
# =============================================================================
# WHY A FILE AND NOT A VARIABLE
#   nftban_botscan_analyze is invoked from nftban_botscan_process_logs across a
#   FORK. Every emitted signal and every ban is counted inside that fork. Shell
#   variable propagation is parent -> child ONLY, so 100% of those mutations were
#   discarded and signals_emitted_total / bans_emitted_total were structurally 0
#   on every host, forever. `declare -g` and `export` cannot fix this; only a
#   channel that outlives the child can. A file-backed sink is proven to cross
#   this exact boundary in-tree: nftban_http_logs.sh commits its read cursor from
#   inside the process substitution feeding the scan loop and it survives.
#
# WHY APPEND-ONLY
#   Increments append one "<name> <delta>" record; a read SUMS the records. There
#   is NO read-modify-write on the increment path, so a lost update is impossible
#   BY CONSTRUCTION rather than by discipline. (Contrast _ptf_state_incr in
#   nftban_portscan_trusted_flow.sh: its lock helper _ptf_state_lock is defined
#   and never called, so that increment is an unlocked read-modify-write. A
#   lost-counter defect must not be repaired with a lost-update defect.)
#   flock is still taken when available so parallel writers sharing one sink
#   serialize cleanly; its absence degrades ordering, never correctness.
#
# BOUNDING
#   The sink is PER CYCLE and PER PROCESS: nftban_botscan_init_state truncates or
#   creates it, process_logs removes it, and the record count cannot exceed the
#   signals + bans emitted in that one cycle. Orphans from a process that died
#   mid-cycle are reaped by age under an exact name pattern.
#
# fd HANDLING
#   The lock fd is AUTO-ALLOCATED (`exec {fd}>>`). lib/module_authority.sh:785-786
#   documents fd 8 = rebuild nftlock and fd 9 = session whitelist; neither is
#   hardcoded here.
#
# GENERALITY
#   _nftban_counter_file_add/_get take the sink path explicitly and address NAMED
#   counters, so a second consumer binds its own file. (Reuse for P0-A4 telemetry
#   is anticipated; A4 itself is NOT implemented here.)

# _nftban_counter_file_add <file> <name> <delta>
_nftban_counter_file_add() {
    local f="${1:-}" name="${2:-}" delta="${3:-1}"
    [[ -n "$f" && -n "$name" ]] || return 0
    [[ "$delta" =~ ^-?[0-9]+$ ]] || return 0
    local rec; printf -v rec '%s %s\n' "$name" "$delta"
    local lfd=""
    if command -v flock >/dev/null 2>&1 && exec {lfd}>>"${f}.lock" 2>/dev/null; then
        # A lock timeout is NOT a drop: the append is atomic on its own.
        flock -w 5 "$lfd" 2>/dev/null || true
        printf '%s' "$rec" >> "$f" 2>/dev/null || { exec {lfd}>&- 2>/dev/null; return 1; }
        exec {lfd}>&- 2>/dev/null
        return 0
    fi
    printf '%s' "$rec" >> "$f" 2>/dev/null || return 1
    return 0
}

# _nftban_counter_file_get <file> <name>  -> integer on stdout (0 if unknown)
_nftban_counter_file_get() {
    local f="${1:-}" name="${2:-}" v=0
    if [[ -n "$f" && -n "$name" && -s "$f" ]]; then
        v="$(awk -v k="$name" '$1==k { s += $2 } END { printf "%d", s+0 }' "$f" 2>/dev/null)" || v=0
    fi
    [[ "$v" =~ ^-?[0-9]+$ ]] || v=0
    printf '%s' "$v"
}

# BotScan bindings.
nftban_botscan_counter_add() { _nftban_counter_file_add "${_BOTSCAN_COUNTER_FILE:-}" "${1:-}" "${2:-1}"; }
nftban_botscan_counter_get() { _nftban_counter_file_get "${_BOTSCAN_COUNTER_FILE:-}" "${1:-}"; }

# Open (and zero) this cycle's sink. Called from nftban_botscan_init_state, i.e.
# in the PARENT, before the fork — the child inherits the resolved path.
nftban_botscan_counters_reset() {
    nftban_botscan_counters_release
    local dir="${BOTSCAN_COUNTER_DIR:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/counters}"
    local f=""
    # $$ is the ORIGINAL shell's pid and is stable inside subshells, so the child
    # writes to the same per-cycle file the parent will read.
    if mkdir -p "$dir" 2>/dev/null && : > "${dir}/cycle.$$.counters" 2>/dev/null; then
        f="${dir}/cycle.$$.counters"
        # Bounded orphan reap: EXACT basename shape, this directory only, age-floored
        # so a live writer's sink is out of scope. Never a directory-wide glob.
        find "$dir" -maxdepth 1 -type f \( -name 'cycle.*.counters' -o -name 'cycle.*.counters.lock' \) \
             -mmin +60 ! -name "cycle.$$.counters" ! -name "cycle.$$.counters.lock" -delete 2>/dev/null || true
    else
        # Data dir unwritable (unprivileged interactive run): fall back to TMPDIR so
        # the boundary-crossing channel still exists.
        f="$(mktemp "${TMPDIR:-/tmp}/nftban-botscan-counters.XXXXXX" 2>/dev/null)" || f=""
        [[ -z "$f" ]] && echo "[botscan] WARN: no writable counter sink (${dir}, ${TMPDIR:-/tmp}) — per-cycle signal/ban counts will report 0" >&2
    fi
    _BOTSCAN_COUNTER_FILE="$f"
    [[ -n "$f" ]] && _BOTSCAN_COUNTER_OWNED=1 || _BOTSCAN_COUNTER_OWNED=0
    return 0
}

# Close this cycle's sink. Safe to call when none is open.
nftban_botscan_counters_release() {
    if [[ "${_BOTSCAN_COUNTER_OWNED:-0}" -eq 1 && -n "${_BOTSCAN_COUNTER_FILE:-}" ]]; then
        rm -f -- "${_BOTSCAN_COUNTER_FILE}" "${_BOTSCAN_COUNTER_FILE}.lock" 2>/dev/null || true
    fi
    _BOTSCAN_COUNTER_FILE=""
    _BOTSCAN_COUNTER_OWNED=0
    return 0
}

# =============================================================================
# PATTERN MANAGEMENT
# =============================================================================

# v1.214.0 OPEN_BOTSCAN_PATTERN_DELIMITER_FIX — record-parse constants.
# The 8-field .patterns record NAME|PATTERN|MATCH_TYPE|THRESHOLD|WINDOW|BAN|ENABLED|DESCRIPTION
# is '|'-delimited, but the PATTERN field legally contains regex alternation '|'. A naive
# `IFS='|' read` mis-splits any '|'-bearing pattern (3 shipped: EXP_CGIBIN/EXP_SQLBACKUP/
# SCAN_BACKUP_SQL) → truncated regex → RE2 skips it (dead). The parser below peels the record
# from both ends so the pattern (the middle) is preserved intact, and the INTERNAL
# _BOTSCAN_PATTERNS representation is joined/split on ASCII Unit Separator (\x1f) — which a
# regex can never contain — so the hot-path/threshold/prefilter re-splits never re-corrupt it.
readonly _BS_US=$'\x1f'                                        # internal '|'-safe field delimiter
# v1.234.0 adds two generic families (see nftban_botscan_match_url_g):
#   path-*      the regex is applied to the request PATH only (query string excluded), so a
#               route signature cannot be satisfied by, or evaded through, the query;
#   distinct-*  the regex is applied to the raw request target (path?query) and each
#               DISTINCT target counts once per IP per pattern -- enumeration and probing
#               are evidenced by VARIETY, so an application polling one URL cannot multiply
#               its own evidence.
# An older module does not know these types and skips such a record with a visible WARN
# (never mis-applies it).
readonly _BS_VALID_MATCH_TYPES=" url-404 url-any url-get url-post path-404 path-any path-get path-post distinct-404 distinct-any distinct-get distinct-post useragent "  # supported set (matcher case at match_url_g)

# _botscan_parse_record <record-line> — anchored parse of ONE shipped/operator .patterns
# record. Peels NAME from the FRONT (first '|') and the 6 constrained trailing fields from
# the BACK (description,enabled,ban,window,threshold,match_type via repeated '##*|'/'%|*');
# whatever remains in the middle is the pattern (may legally contain '|'). Strips CRLF '\r'.
# On success sets globals _BSREC_{name,pattern,match_type,threshold,window,ban,enabled,
# description} and returns 0. Returns 1 for a blank/comment line (skip silently). Returns 2
# for a malformed record (too few fields, or a peeled constrained field fails validation —
# e.g. a stray '|' in the free-text description shifted the trailing fields): emits a VISIBLE
# WARN (stderr + logger) and the caller MUST skip it — NEVER store a corrupted record.
_botscan_parse_record() {
    local line="${1-}"
    line="${line%$'\r'}"                                   # strip trailing CR (CRLF files)
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && return 1

    # A valid record has >= 7 '|' (8 fields; a '|'-alternation pattern only adds more). Fewer
    # => the record cannot be peeled into 8 fields → malformed.
    local _pipes="${line//[!|]/}"
    if [[ "${#_pipes}" -lt 7 ]]; then
        _botscan_warn_bad_record "${line%%|*}" "too few fields (< 8)"
        return 2
    fi

    local rest description enabled ban window threshold match_type pattern
    _BSREC_name="${line%%|*}"; rest="${line#*|}"
    description="${rest##*|}"; rest="${rest%|*}"
    enabled="${rest##*|}";     rest="${rest%|*}"
    ban="${rest##*|}";         rest="${rest%|*}"
    window="${rest##*|}";      rest="${rest%|*}"
    threshold="${rest##*|}";   rest="${rest%|*}"
    match_type="${rest##*|}";  rest="${rest%|*}"
    pattern="$rest"                                        # the middle — legally '|'-bearing

    # Constrained-field validation: a stray '|' in the description would shift the trailing
    # fields, so validate them (and a non-empty pattern) → a shifted record fails VISIBLY
    # instead of being silently stored corrupted.
    local why=""
    if   [[ -z "$pattern" ]]; then why="empty pattern"
    elif [[ "$_BS_VALID_MATCH_TYPES" != *" $match_type "* ]]; then why="unknown match_type '$match_type'"
    elif [[ ! "$threshold" =~ ^[0-9]+$ ]]; then why="non-integer threshold '$threshold'"
    elif [[ ! "$window"    =~ ^[0-9]+$ ]]; then why="non-integer window '$window'"
    elif [[ ! "$ban"       =~ ^[0-9]+$ ]]; then why="non-integer ban '$ban'"
    elif [[ "$enabled" != "true" && "$enabled" != "false" ]]; then why="non-boolean enabled '$enabled'"
    fi
    if [[ -n "$why" ]]; then
        _botscan_warn_bad_record "$_BSREC_name" "$why"
        return 2
    fi

    _BSREC_pattern="$pattern"
    _BSREC_match_type="$match_type"
    _BSREC_threshold="$threshold"
    _BSREC_window="$window"
    _BSREC_ban="$ban"
    _BSREC_enabled="$enabled"
    _BSREC_description="$description"
    return 0
}

# Visible malformed-record warning (stderr + syslog, non-fatal).
_botscan_warn_bad_record() {
    local name="${1:-?}" why="${2:-invalid}"
    printf "[WARN] botscan: malformed pattern record '%s' — skipped (%s)\n" "$name" "$why" >&2
    if command -v logger >/dev/null 2>&1; then
        logger -t nftban-botscan -p user.warning "malformed pattern record '$name' skipped ($why)" 2>/dev/null || true
    fi
    return 0
}

# =============================================================================
# v1.234.0 — PATTERN SOURCES: shipped defaults vs operator files
# =============================================================================
# Before v1.234 the shipped rule files lived in /etc/nftban/patterns.d/botscan as
# package-owned config. Measured on the published v1.233.1 packages:
#   RPM  %config(noreplace) -> a locally edited file is KEPT on upgrade and the new
#        defaults land in .rpmnew, so the old (defective) rules stay ACTIVE;
#   DEB  not a conffile     -> a local edit is silently OVERWRITTEN on upgrade, and
#        operator records in custom.patterns were lost at every upgrade.
# Now:
#   shipped defaults  ${NFTBAN_LIB_DIR}/data/botscan_<category>.patterns
#                     package payload, replaced on every upgrade, never edited;
#   operator surface  ${BOTSCAN_PATTERNS_DIR} (/etc/nftban/patterns.d/botscan):
#                     override.local  NAME|true|false  — the ONE mechanism to enable or
#                                     disable any rule (unchanged since v1.188);
#                     *.patterns      operator records (custom.patterns, local files).
# An operator record that reuses a SHIPPED name is IGNORED and reported: to change a
# shipped rule, disable it in override.local and add your own record under a new
# name. That is what keeps a stale copy of an old shipped file from silently
# re-activating superseded rules. Package upgrades never touch the operator surface;
# nftban_botscan_migrate_legacy_patterns converts pre-v1.234 edits once.
readonly _BS_LEGACY_SHIPPED_CATEGORIES=" aibots badbots exploit scanner webshell "
# RETIRED shipped rule names (owner decisions). A retired name is reserved: no operator
# record, legacy copy or override.local `NAME|true` can re-activate it (reported, once per
# cycle); `NAME|false` in override.local is accepted silently (it is already the state).
#   EMPTY_UA  v1.234.0 — duplicate of SINGLE_DASH; extra coverage ("UA ends in -") over-broad
readonly _BS_RETIRED_PATTERN_NAMES=" EMPTY_UA "
nftban_botscan_pattern_retired() { [[ "$_BS_RETIRED_PATTERN_NAMES" == *" ${1:-} "* ]]; }
nftban_botscan_shipped_patterns_dir() {
    printf '%s' "${BOTSCAN_SHIPPED_PATTERNS_DIR-${NFTBAN_LIB_DIR:-/usr/lib/nftban}/data}"
}

# nftban_botscan_pattern_files -> one "origin<TAB>category<TAB>path" line per file:
# shipped files first, then operator files (each group in glob order).
nftban_botscan_pattern_files() {
    local sd od f cat
    sd="$(nftban_botscan_shipped_patterns_dir)"; od="${BOTSCAN_PATTERNS_DIR:-}"
    if [[ -n "$sd" && -d "$sd" ]]; then
        for f in "$sd"/botscan_*.patterns; do
            [[ -f "$f" ]] || continue
            cat="${f##*/}"; cat="${cat#botscan_}"; cat="${cat%.patterns}"
            printf 'shipped\t%s\t%s\n' "$cat" "$f"
        done
    fi
    if [[ -n "$od" && -d "$od" && "$od" != "$sd" ]]; then
        for f in "$od"/*.patterns; do
            [[ -f "$f" ]] || continue
            cat="${f##*/}"; cat="${cat%.patterns}"
            printf 'operator\t%s\t%s\n' "$cat" "$f"
        done
    fi
    return 0
}

# nftban_botscan_pattern_sidecars [all] -> stale pattern files in the operator dir that
# are NOT loaded: package-manager leftovers (.rpmsave/.rpmnew/.rpmorig/.dpkg-*) and
# unmigrated pre-v1.234 copies (.nftban-saved). With "all", migrated copies
# (.migrated-v1234) are listed too. One path per line.
nftban_botscan_pattern_sidecars() {
    local od="${BOTSCAN_PATTERNS_DIR:-}" f
    [[ -n "$od" && -d "$od" ]] || return 0
    for f in "$od"/*.patterns.rpmsave "$od"/*.patterns.rpmnew "$od"/*.patterns.rpmorig \
             "$od"/*.patterns.dpkg-* "$od"/*.patterns.nftban-saved; do
        [[ -e "$f" ]] && printf '%s\n' "$f"
    done
    if [[ "${1:-}" == "all" ]]; then
        # v1.235 (BUG-BOTSCAN-STATUS-MISSES-DEB-MIGRATED-PATTERN-FILES): the migration renames
        # the file it PROCESSED, so the suffix follows the input's name: DEB
        # <cat>.patterns.nftban-saved.migrated-v1234, RPM <cat>.patterns.rpmsave.migrated-v1234,
        # file-drop <cat>.patterns.migrated-v1234. The old glob matched only the last.
        for f in "$od"/*.patterns*.migrated-v1234; do [[ -e "$f" ]] && printf '%s\n' "$f"; done
    fi
    return 0
}

# Load patterns from file
# Format: NAME|PATTERN|MATCH_TYPE|THRESHOLD|WINDOW|BAN|ENABLED|DESCRIPTION
nftban_botscan_load_patterns() {
    local patterns_dir="${BOTSCAN_PATTERNS_DIR}"
    local pattern_count=0

    _BOTSCAN_PATTERNS=()

    # override.local (NAME|true|false) WINS over the ENABLED column of any record —
    # shipped or operator — without editing a file (v1.188 B2). Operator-created, never
    # package-owned. It is NOT a *.patterns file, so the glob never loads it as rules.
    local override_file="${patterns_dir}/override.local"
    local -A _override=()
    [[ -e "$override_file" && ! -r "$override_file" ]] && _botscan_warn_unreadable "$override_file"
    if [[ -r "$override_file" ]]; then
        local oname ostate
        while IFS='|' read -r oname ostate _; do
            [[ -z "$oname" || "$oname" =~ ^# ]] && continue
            oname="${oname// /}"; ostate="${ostate// /}"
            if nftban_botscan_pattern_retired "$oname"; then
                [[ "$ostate" == "true" ]] && printf "[WARN] botscan: override.local enables %s, a RETIRED rule — ignored (it cannot be re-activated)\n" "$oname" >&2
                continue
            fi
            [[ "$ostate" == "true" || "$ostate" == "false" ]] && _override["$oname"]="$ostate"
        done < "$override_file"
    fi

    local -A _origin=()          # NAME -> origin of the record that owns it
    local src cat pattern_file _dups _retired_hits=""
    while IFS=$'\t' read -r src cat pattern_file; do
        [[ -n "$pattern_file" ]] || continue
        # v1.234.0 — an unreadable pattern file is reported, not a silent gap (and not an
        # errexit abort on the redirection below).
        if [[ ! -r "$pattern_file" ]]; then _botscan_warn_unreadable "$pattern_file"; continue; fi
        _dups=0
        local _bs_line
        while IFS= read -r _bs_line || [[ -n "$_bs_line" ]]; do
            # v1.214.0 anchored parse (rc1=blank/comment skip, rc2=malformed WARN+skip).
            _botscan_parse_record "$_bs_line" || continue

            # v1.234.0 — a retired name is never loaded, from any source.
            if nftban_botscan_pattern_retired "$_BSREC_name"; then
                [[ "$_BSREC_enabled" == "true" ]] && _retired_hits+=" ${_BSREC_name}@${pattern_file##*/}"
                continue
            fi
            # v1.234.0 — a shipped name is owned by the shipped record (enabled or not).
            if [[ "$src" == "operator" && "${_origin[$_BSREC_name]:-}" == "shipped" ]]; then
                _dups=$(( _dups + 1 )); continue
            fi
            _origin["$_BSREC_name"]="$src"

            # override.local wins over the ENABLED column (no-clobber).
            local eff_enabled="${_override[$_BSREC_name]:-$_BSREC_enabled}"
            [[ "$eff_enabled" != "true" ]] && { unset "_BOTSCAN_PATTERNS[$_BSREC_name]"; continue; }

            # v1.214.0 — store name -> "pattern<US>match_type<US>threshold<US>window<US>ban<US>description"
            # with an ASCII Unit Separator join so the pattern's own '|' survives every downstream
            # re-split (hot-path :755, threshold :906, prefilter build :1004).
            _BOTSCAN_PATTERNS["$_BSREC_name"]="${_BSREC_pattern}${_BS_US}${_BSREC_match_type}${_BS_US}${_BSREC_threshold}${_BS_US}${_BSREC_window}${_BS_US}${_BSREC_ban}${_BS_US}${_BSREC_description}"
            pattern_count=$((pattern_count + 1))

        done < "$pattern_file"
        if (( _dups > 0 )); then
            local _hint="to change a shipped rule, disable it in override.local and add your own record under a new name"
            [[ "$_BS_LEGACY_SHIPPED_CATEGORIES" == *" $cat "* ]] && \
                _hint="this looks like a pre-v1.234 copy of a shipped file: defaults now ship in $(nftban_botscan_shipped_patterns_dir); remove it (edits are migrated by the package, see 'nftban botscan status')"
            printf "[WARN] botscan: %s: %d record(s) reuse shipped pattern names and are IGNORED — %s\n" "$pattern_file" "$_dups" "$_hint" >&2
            command -v logger >/dev/null 2>&1 && logger -t nftban-botscan -p user.warning "$pattern_file: $_dups record(s) reuse shipped pattern names, ignored" 2>/dev/null || true
        fi
    done < <(nftban_botscan_pattern_files)

    if [[ -n "$_retired_hits" ]]; then
        printf "[WARN] botscan: RETIRED rule record(s) ignored:%s — they cannot be re-activated; remove them\n" "$_retired_hits" >&2
    fi
    # v1.234.0 — stale pattern files are NOT loaded; say so every cycle until removed.
    local _stale=()
    mapfile -t _stale < <(nftban_botscan_pattern_sidecars)
    if (( ${#_stale[@]} > 0 )); then
        printf "[WARN] botscan: %d stale pattern file(s) in %s are NOT active (package-manager or pre-v1.234 copies): %s — see 'nftban botscan status'\n" \
            "${#_stale[@]}" "$patterns_dir" "${_stale[*]##*/}" >&2
    fi

    [[ "$BOTSCAN_DEBUG" == "true" ]] && echo "[DEBUG] Loaded $pattern_count patterns" >&2
    return 0
}

# =============================================================================
# v1.234.0 — one-time migration of pre-v1.234 pattern files (package maintainer
# scripts: DEB postinst, RPM %post; idempotent; never edits a shipped file).
# =============================================================================
# Inputs, all in the operator dir:
#   <cat>.patterns.rpmsave       RPM: a locally edited legacy file (rpm renames it when
#                                the new package no longer owns it)
#   <cat>.patterns.nftban-saved  DEB: preinst copied a locally edited legacy file
#                                before dpkg removed it
#   <cat>.patterns               a legacy file still present (file-drop / source host)
# for <cat> in aibots badbots exploit scanner webshell, and custom.patterns(.rpmsave|
# .nftban-saved), which is operator data and is restored as-is.
# Per record of a legacy file:
#   name not shipped                   -> kept ACTIVE: appended to local-migrated.patterns
#   ENABLED differs from the shipped   -> the operator's decision is kept: NAME|state is
#   default                               written to override.local (unless already there)
#   regex/type/threshold/window/ban    -> NOT applied (it would re-activate a superseded
#   differ                                definition); listed in the report
# The processed file is renamed <file>.migrated-v1234 (kept for review, not loaded).
# Report: ${NFTBAN_DATA_DIR}/botscan/pattern-migration.report. Prints a one-line summary.
nftban_botscan_migrate_legacy_patterns() {
    local od="${BOTSCAN_PATTERNS_DIR:-${NFTBAN_CONFIG_DIR:-/etc/nftban}/patterns.d/botscan}"
    local tpl="${BOTSCAN_CUSTOM_PATTERNS_TEMPLATE:-/usr/share/nftban/templates/patterns.d/botscan/custom.patterns}"
    local rep_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan"
    local report="${rep_dir}/pattern-migration.report"
    [[ -d "$od" ]] || return 0
    mkdir -p "$rep_dir" 2>/dev/null || true
    local grp_ref="$od"
    _bs_mig_perm() { chmod 0640 "$1" 2>/dev/null || true; chgrp --reference="$grp_ref" "$1" 2>/dev/null || true; }

    # --- custom.patterns: operator data. Restore a saved copy, else seed if absent.
    local cs
    if [[ ! -e "$od/custom.patterns" ]]; then
        for cs in "$od/custom.patterns.rpmsave" "$od/custom.patterns.nftban-saved"; do
            if [[ -f "$cs" ]]; then mv -f "$cs" "$od/custom.patterns" && _bs_mig_perm "$od/custom.patterns"; break; fi
        done
        if [[ ! -e "$od/custom.patterns" && -f "$tpl" ]]; then
            cp -p "$tpl" "$od/custom.patterns" 2>/dev/null && _bs_mig_perm "$od/custom.patterns"
        fi
    fi
    rm -f -- "$od/custom.patterns.nftban-saved" 2>/dev/null || true

    # --- shipped defaults (name -> pattern<US>type<US>thr<US>win<US>ban, and enabled)
    local -A _sdef=() _sen=()
    local src cat f
    while IFS=$'\t' read -r src cat f; do
        [[ "$src" == "shipped" ]] || continue
        local l
        while IFS= read -r l || [[ -n "$l" ]]; do
            _botscan_parse_record "$l" 2>/dev/null || continue
            _sdef["$_BSREC_name"]="${_BSREC_pattern}${_BS_US}${_BSREC_match_type}${_BS_US}${_BSREC_threshold}${_BS_US}${_BSREC_window}${_BS_US}${_BSREC_ban}"
            _sen["$_BSREC_name"]="$_BSREC_enabled"
        done < "$f"
    done < <(nftban_botscan_pattern_files)
    if (( ${#_sdef[@]} == 0 )); then
        echo "botscan pattern migration: shipped defaults not found in $(nftban_botscan_shipped_patterns_dir) — nothing migrated (legacy files left in place)"
        return 0
    fi

    # --- existing override.local decisions are never overwritten
    local -A _ov=()
    local on os
    if [[ -r "$od/override.local" ]]; then
        while IFS='|' read -r on os _; do [[ -z "$on" || "$on" =~ ^# ]] && continue; _ov["${on// /}"]=1; done < "$od/override.local"
    fi

    # --- v1.235 (BUG-BOTSCAN-PATTERN-MIGRATION-NOT-APPLIED-DEFINITIONS-SILENT): definitions
    # that a RELEASED version shipped (data/botscan_legacy_shipped.list, generated from the
    # release tags by scripts/generate-botscan-legacy-shipped.sh). Comparing only with the
    # v1.234 defaults reported every definition v1.234 itself changed (url-* -> distinct-*,
    # regex hardening) as an operator edit: "82 edited definition(s) NOT applied" on every
    # rollout host, with untouched files (legacy files untouched since install). An old definition that
    # matches one of these is UNEDITED: it is upgraded to the v1.234 default silently.
    #   _ldef[name|pattern|type|thr|win|ban] = " <enabled values shipped with it> "
    local -A _ldef=()
    local _lrec _lk _le _have_legacy=0
    _lrec="$(nftban_botscan_shipped_patterns_dir)/botscan_legacy_shipped.list"
    if [[ -r "$_lrec" ]]; then
        while IFS= read -r l || [[ -n "$l" ]]; do
            [[ -z "$l" || "$l" == \#* ]] && continue
            _le="${l##*|}"; _lk="${l%|*}"
            _ldef["$_lk"]="${_ldef[$_lk]:- } ${_le} "
            _have_legacy=1
        done < "$_lrec"
    fi
    (( _have_legacy )) || printf '%s WARNING: %s missing — every definition that differs from the v1.234 default is reported as edited (cannot tell old shipped from operator edits)\n' \
        "$(date -u +%FT%TZ 2>/dev/null || echo unknown)" "$_lrec" >> "$report" 2>/dev/null || true

    local n_files=0 n_state=0 n_kept=0 n_dropped=0 n_upgraded=0 ts c sfx
    ts="$(date -u +%FT%TZ 2>/dev/null || echo unknown)"
    # IFS-independent split: the module runs under IFS=$'\n\t' (v1.186.1 class)
    local -a _cats=()
    IFS=' ' read -ra _cats <<< "$_BS_LEGACY_SHIPPED_CATEGORIES"
    for c in "${_cats[@]}"; do
        for sfx in ".patterns" ".patterns.rpmsave" ".patterns.nftban-saved"; do
            f="$od/${c}${sfx}"
            [[ -f "$f" ]] || continue
            n_files=$(( n_files + 1 ))
            printf '%s legacy file %s\n' "$ts" "$f" >> "$report" 2>/dev/null || true
            local l
            while IFS= read -r l || [[ -n "$l" ]]; do
                _botscan_parse_record "$l" 2>/dev/null || continue
                local nm="$_BSREC_name"
                if nftban_botscan_pattern_retired "$nm"; then
                    printf '  retired %s: not migrated (rule retired; cannot be re-activated)\n' "$nm" >> "$report" 2>/dev/null || true
                    continue
                fi
                if [[ -z "${_sdef[$nm]:-}" ]]; then
                    printf '%s\n' "$l" >> "$od/local-migrated.patterns" 2>/dev/null && n_kept=$(( n_kept + 1 ))
                    printf '  kept   %s (not a shipped name) -> local-migrated.patterns\n' "$nm" >> "$report" 2>/dev/null || true
                    continue
                fi
                local _dk="${nm}|${_BSREC_pattern}|${_BSREC_match_type}|${_BSREC_threshold}|${_BSREC_window}|${_BSREC_ban}"
                local _pristine=0
                [[ -n "${_ldef[$_dk]:-}" ]] && _pristine=1
                # State: an operator decision only when it differs from what was SHIPPED with
                # this exact definition (an unedited record carries the old default's state).
                local _state_edited=1
                (( _pristine )) && [[ "${_ldef[$_dk]}" == *" ${_BSREC_enabled} "* ]] && _state_edited=0
                if (( _state_edited )) && [[ "$_BSREC_enabled" != "${_sen[$nm]}" && -z "${_ov[$nm]:-}" ]]; then
                    printf '%s|%s|migrated from %s (v1.234)\n' "$nm" "$_BSREC_enabled" "${f##*/}" >> "$od/override.local" 2>/dev/null \
                        && { _ov["$nm"]=1; n_state=$(( n_state + 1 )); }
                    printf '  state  %s -> override.local %s\n' "$nm" "$_BSREC_enabled" >> "$report" 2>/dev/null || true
                fi
                local _cur="${_BSREC_pattern}${_BS_US}${_BSREC_match_type}${_BS_US}${_BSREC_threshold}${_BS_US}${_BSREC_window}${_BS_US}${_BSREC_ban}"
                if [[ "$_cur" == "${_sdef[$nm]}" ]]; then
                    :   # identical to the v1.234 default: nothing to report
                elif (( _pristine )); then
                    n_upgraded=$(( n_upgraded + 1 ))
                    printf '  upgraded %s: unedited previously shipped definition -> v1.234 default\n' "$nm" >> "$report" 2>/dev/null || true
                else
                    n_dropped=$(( n_dropped + 1 ))
                    local _new="${_sdef[$nm]//$_BS_US/|}"
                    printf '  NOT APPLIED %s: your edited definition (%s|%s|%s|%s|%s) matches no shipped release; the v1.234 default (%s) applies; re-create yours under a new name if still wanted\n' \
                        "$nm" "$_BSREC_pattern" "$_BSREC_match_type" "$_BSREC_threshold" "$_BSREC_window" "$_BSREC_ban" "$_new" >> "$report" 2>/dev/null || true
                fi
            done < "$f"
            mv -f "$f" "${f}.migrated-v1234" 2>/dev/null || true
        done
    done
    [[ -f "$od/override.local" ]] && _bs_mig_perm "$od/override.local"
    [[ -f "$od/local-migrated.patterns" ]] && _bs_mig_perm "$od/local-migrated.patterns"
    if (( n_files > 0 )); then
        echo "botscan pattern migration: ${n_files} legacy file(s): ${n_upgraded} unedited shipped definition(s) upgraded, ${n_state} enable/disable decision(s) -> override.local, ${n_kept} operator record(s) kept, ${n_dropped} edited definition(s) NOT applied (report: ${report})"
    fi
    return 0
}

# v1.234.0 — read override.local into the caller's associative array named $1.
_botscan_read_overrides() {
    local -n _ro_out="$1"
    local f="${BOTSCAN_PATTERNS_DIR}/override.local" on os
    [[ -r "$f" ]] || return 0
    while IFS='|' read -r on os _; do
        [[ -z "$on" || "$on" =~ ^# ]] && continue
        on="${on// /}"; os="${os// /}"
        [[ "$os" == "true" || "$os" == "false" ]] && _ro_out["$on"]="$os"
    done < "$f"
    return 0
}

# List all patterns (v1.234.0: shipped + operator files; ENABLED is the EFFECTIVE state,
# '*' = set by override.local; operator records that reuse a shipped name are ignored,
# exactly as the loader ignores them).
nftban_botscan_list_patterns() {
    local filter="${1:-all}"  # all, enabled, disabled, category
    local category="${2:-}"
    local -A _ov=() _owner=()
    _botscan_read_overrides _ov

    printf "%-20s %-8s %-10s %-6s %-6s %-6s %s\n" "NAME" "ENABLED" "MATCH" "THRESH" "WINDOW" "BAN" "DESCRIPTION"
    printf "%s\n" "$(printf '=%.0s' {1..100})"

    local src cat pattern_file
    while IFS=$'\t' read -r src cat pattern_file; do
        [[ -r "$pattern_file" ]] || continue
        local _bs_line
        while IFS= read -r _bs_line || [[ -n "$_bs_line" ]]; do
            _botscan_parse_record "$_bs_line" 2>/dev/null || continue
            [[ "$src" == "operator" && "${_owner[$_BSREC_name]:-}" == "shipped" ]] && continue
            _owner["$_BSREC_name"]="$src"
            [[ -n "$category" && "$cat" != "$category" ]] && continue
            local eff="${_ov[$_BSREC_name]:-$_BSREC_enabled}" mark
            mark="$eff"; [[ -n "${_ov[$_BSREC_name]:-}" ]] && mark="${eff}*"
            case "$filter" in
                enabled)  [[ "$eff" != "true" ]] && continue ;;
                disabled) [[ "$eff" == "true" ]] && continue ;;
            esac
            printf "%-20s %-8s %-10s %-6s %-6s %-6s %s\n" \
                "$_BSREC_name" "$mark" "$_BSREC_match_type" "$_BSREC_threshold" "$_BSREC_window" "$_BSREC_ban" "${_BSREC_description:0:40}"
        done < "$pattern_file"
    done < <(nftban_botscan_pattern_files)
    return 0
}

# Add custom pattern
nftban_botscan_add_pattern() {
    local name="$1"
    local pattern="$2"
    local match_type="${3:-url-404}"
    local threshold="${4:-$BOTSCAN_DEFAULT_THRESHOLD}"
    local window="${5:-$BOTSCAN_DEFAULT_WINDOW}"
    local ban="${6:-$BOTSCAN_DEFAULT_BAN_SHORT}"
    local description="${7:-Custom pattern}"

    local custom_file="${BOTSCAN_PATTERNS_DIR}/custom.patterns"

    # Check if pattern already exists
    if grep -q "^${name}|" "$custom_file" 2>/dev/null; then
        echo "ERROR: Pattern '$name' already exists" >&2
        return 1
    fi
    if nftban_botscan_pattern_retired "$name"; then
        echo "ERROR: '$name' is a RETIRED rule name and cannot be re-used." >&2
        return 1
    fi
    # v1.234.0 — a shipped name is owned by the shipped rule; an operator record under
    # that name would be ignored by the loader, so refuse it here with the way forward.
    local _src _cat _f _l
    while IFS=$'\t' read -r _src _cat _f; do
        [[ "$_src" == shipped && -r "$_f" ]] || continue
        while IFS= read -r _l || [[ -n "$_l" ]]; do
            _botscan_parse_record "$_l" 2>/dev/null || continue
            if [[ "$_BSREC_name" == "$name" ]]; then
                echo "ERROR: '$name' is a shipped rule. Disable it (nftban botscan patterns disable $name) and add yours under a new name." >&2
                return 1
            fi
        done < "$_f"
    done < <(nftban_botscan_pattern_files)

    # Add pattern (custom.patterns is operator data since v1.234: never package-owned)
    local _new=0; [[ -e "$custom_file" ]] || _new=1
    echo "${name}|${pattern}|${match_type}|${threshold}|${window}|${ban}|true|${description}" >> "$custom_file"
    if (( _new )); then chmod 0640 "$custom_file" 2>/dev/null || true; chgrp --reference="${BOTSCAN_PATTERNS_DIR}" "$custom_file" 2>/dev/null || true; fi
    echo "Added pattern: $name"
    return 0
}

# Remove custom pattern
nftban_botscan_remove_pattern() {
    local name="$1"
    local custom_file="${BOTSCAN_PATTERNS_DIR}/custom.patterns"

    if ! grep -q "^${name}|" "$custom_file" 2>/dev/null; then
        echo "ERROR: Pattern '$name' not found in custom.patterns" >&2
        return 1
    fi

    # v1.19.0: Escape pattern name for safe sed usage (R23)
    local safe_name
    safe_name=$(printf '%s' "$name" | sed 's/[[\.*^$()+?{}|/]/\\&/g')
    sed -i "/^${safe_name}|/d" "$custom_file"
    echo "Removed pattern: $name"
    return 0
}

# Enable/disable pattern.
# v1.234.0 (DEBT-BOTSCAN-CLI-MUTATES-SHIPPED-PATTERN-CONFFILES): this used `sed -i` on the
# shipped rule file, which made the file "locally modified" (RPM then kept it over every
# later fix, DEB overwrote the decision at the next upgrade). It now records the decision
# in override.local — the same mechanism as allowbot/blockbot — and never edits a file
# that a package ships.
nftban_botscan_toggle_pattern() {
    local name="$1"
    local action="$2"  # enable or disable
    local new_state
    [[ "$action" == "enable" ]] && new_state="true" || new_state="false"
    if nftban_botscan_pattern_retired "$name"; then
        if [[ "$new_state" == "true" ]]; then echo "ERROR: '$name' is a RETIRED rule and cannot be enabled." >&2; return 1; fi
        echo "Pattern $name is retired (already inactive); nothing to do."
        return 0
    fi

    local src cat f found=0
    while IFS=$'\t' read -r src cat f; do
        [[ -r "$f" ]] || continue
        local l
        while IFS= read -r l || [[ -n "$l" ]]; do
            _botscan_parse_record "$l" 2>/dev/null || continue
            [[ "$_BSREC_name" == "$name" ]] && { found=1; break; }
        done < "$f"
        (( found )) && break
    done < <(nftban_botscan_pattern_files)
    if (( ! found )); then echo "ERROR: Pattern '$name' not found" >&2; return 1; fi
    nftban_botscan_set_override "$name" "$new_state" || { echo "ERROR: could not write override.local for $name" >&2; return 1; }
    echo "${action^}d pattern: $name (override.local)"
    return 0
}

# =============================================================================
# v1.188 B2 — BOT POLICY (bots / blockbot / allowbot) helpers
# =============================================================================

# Never-ban guard. These tokens must NEVER be hard-banned on User-Agent:
#   robots.txt-only control tokens (Google-Extended/Applebot-Extended have NO request
#   UA → a ban can never match; it is a category error), legitimate index UAs
#   (Googlebot/Bingbot/Applebot — banning delists the site), and user-action fetchers
#   (ChatGPT-User/Perplexity-User/Claude-User — a human triggered the fetch).
# Returns 0 (guarded) / 1 (not guarded). Case-insensitive substring match.
nftban_botscan_neverban_token() {
    local q; q=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    [[ -z "$q" ]] && return 1
    local t
    for t in google-extended applebot-extended googlebot bingbot applebot \
             facebookexternalhit chatgpt-user perplexity-user claude-user; do
        [[ "$q" == *"$t"* ]] && return 0
    done
    return 1
}

# Resolve a user token (pattern NAME or UA substring, case-insensitive) to the
# canonical pattern NAME used as the override.local / loader key. Echoes NAME, or
# nothing + rc=1 if not found. Interactive-only (blockbot/allowbot), never hot-path.
nftban_botscan_resolve_name() {
    local q; q=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
    [[ -z "$q" ]] && return 1
    local f name pattern lc_name lc_pat _src _cat
    while IFS=$'\t' read -r _src _cat f; do
        [[ -r "$f" ]] || continue
        local _bs_line
        while IFS= read -r _bs_line || [[ -n "$_bs_line" ]]; do
            _botscan_parse_record "$_bs_line" || continue
            name="$_BSREC_name"; pattern="$_BSREC_pattern"
            lc_name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
            lc_pat=$(printf '%s' "$pattern" | tr '[:upper:]' '[:lower:]')
            if [[ "$q" == "$lc_name" || "$q" == "$lc_pat" ]]; then
                printf '%s' "$name"; return 0
            fi
        done < "$f"
    done < <(nftban_botscan_pattern_files)
    return 1
}

# Write an enable/disable decision to override.local (3-tier no-clobber; NEVER edits
# the shipped config(noreplace) *.patterns). Args: NAME, state(true|false). The file
# is operator-created (not package-owned) so DEB/RPM upgrades never clobber it.
nftban_botscan_set_override() {
    local name="${1:-}" state="${2:-}"
    [[ -n "$name" && ( "$state" == "true" || "$state" == "false" ) ]] || return 2
    local dir="${BOTSCAN_PATTERNS_DIR}"
    local override_file="${dir}/override.local"
    mkdir -p "$dir" 2>/dev/null || true
    local tmp; tmp=$(mktemp "${override_file}.XXXXXX" 2>/dev/null) || return 1
    # carry forward all OTHER entries; replace any prior line for this name
    if [[ -r "$override_file" ]]; then
        grep -viE "^[[:space:]]*${name}[[:space:]]*\|" "$override_file" 2>/dev/null >> "$tmp" || true
    fi
    printf '%s|%s\n' "$name" "$state" >> "$tmp"
    # v1.234.0 (BUG-BOTSCAN-OVERRIDE-LOCAL-CREATED-UNREADABLE-BY-SCANNER): mktemp creates
    # 0600 root:root, and the scanner runs as the unprivileged service account, so the
    # override was SILENTLY ignored (`[[ -r ]]` false in load_patterns). Give it the
    # pattern directory's group and the shipped pattern files' mode (0640).
    chmod 0640 "$tmp" 2>/dev/null || true
    chgrp --reference="$dir" "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$override_file" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    return 0
}

# blockbot <token> — enable a bot pattern (operator opt-in) via override.local.
# Refuses never-ban tokens with an explanation. Resolves token→NAME.
nftban_botscan_blockbot() {
    local token="${1:-}"
    [[ -n "$token" ]] || { echo "Usage: nftban botscan blockbot <bot-name>" >&2; return 2; }
    if nftban_botscan_neverban_token "$token"; then
        echo "✗ Refusing to ban '$token': it is a never-ban token." >&2
        echo "  robots.txt-only (Google-Extended/Applebot-Extended) have no request UA to match;" >&2
        echo "  legitimate index UAs (Googlebot/Bingbot/Applebot) would delist the site;" >&2
        echo "  user-action fetchers (ChatGPT-User/Perplexity-User) are human-initiated. Not banned." >&2
        return 1
    fi
    local name; name=$(nftban_botscan_resolve_name "$token") || {
        echo "✗ Unknown bot '$token'. See: nftban botscan bots" >&2; return 1; }
    nftban_botscan_set_override "$name" "true" || { echo "✗ Could not write override for $name" >&2; return 1; }
    echo "✓ blockbot: $name enabled (override.local) — bans on next scan cycle."
    return 0
}

# allowbot <token> — disable a bot pattern (operator allow) via override.local.
nftban_botscan_allowbot() {
    local token="${1:-}"
    [[ -n "$token" ]] || { echo "Usage: nftban botscan allowbot <bot-name>" >&2; return 2; }
    local name; name=$(nftban_botscan_resolve_name "$token") || {
        echo "✗ Unknown bot '$token'. See: nftban botscan bots" >&2; return 1; }
    nftban_botscan_set_override "$name" "false" || { echo "✗ Could not write override for $name" >&2; return 1; }
    echo "✓ allowbot: $name disabled (override.local) — no longer banned."
    return 0
}

# bots [category] [--enabled|--disabled] — friendly category listing (override-aware).
# Shows the EFFECTIVE enabled state (shipped ENABLED column overridden by override.local).
nftban_botscan_bots() {
    local category="" filter="all" a
    for a in "$@"; do
        case "$a" in
            --enabled)  filter="enabled" ;;
            --disabled) filter="disabled" ;;
            scanner|badbots|aibots|custom|webshell|exploit) category="$a" ;;
        esac
    done
    # Load effective state via the override-aware loader.
    local -A _ov=() _owner=()
    _botscan_read_overrides _ov
    printf "%-22s %-9s %-9s %-10s %s\n" "NAME" "CATEGORY" "EFFECTIVE" "MATCH" "DESCRIPTION"
    printf '%s\n' "$(printf '=%.0s' {1..92})"
    local f cat eff src
    while IFS=$'\t' read -r src cat f; do
        [[ -r "$f" ]] || continue
        [[ -n "$category" && "$cat" != "$category" ]] && continue
        local _bs_line
        while IFS= read -r _bs_line || [[ -n "$_bs_line" ]]; do
            _botscan_parse_record "$_bs_line" 2>/dev/null || continue
            [[ "$src" == "operator" && "${_owner[$_BSREC_name]:-}" == "shipped" ]] && continue
            _owner["$_BSREC_name"]="$src"
            eff="${_ov[$_BSREC_name]:-$_BSREC_enabled}"
            case "$filter" in
                enabled)  [[ "$eff" != "true" ]] && continue ;;
                disabled) [[ "$eff" == "true" ]] && continue ;;
            esac
            local mark="$eff"; [[ -n "${_ov[$_BSREC_name]:-}" ]] && mark="${eff}*"
            printf "%-22s %-9s %-9s %-10s %s\n" "$_BSREC_name" "$cat" "$mark" "$_BSREC_match_type" "${_BSREC_description:0:38}"
        done < "$f"
    done < <(nftban_botscan_pattern_files)
    echo ""
    echo "  EFFECTIVE '*' = set by override.local (your blockbot/allowbot decision)."
    return 0
}

# =============================================================================
# LOG PARSING
# =============================================================================

# Find access log
# v1.177: full panel-aware discovery — emits ALL access logs to scan (one per line),
# deduped. Source order: BOTSCAN_LOG_PATHS override / panel-aware auto (shared helper)
# PLUS the legacy single-path vars as an existence-filtered back-compat safety net.
nftban_botscan_discover_logs() {
    local -a logs=()
    local f
    # v1.178-A read-authority: SPOOL-FIRST. If the separate privileged collector
    # (nftban-botscan-collector.service, CAP_DAC_READ_SEARCH) produced a spool, the
    # unprivileged scanner reads ONLY the spool — it already holds the privileged-read
    # content the scanner cannot obtain directly on DA/cPanel/0640 hosts. If no spool
    # (collector absent/empty), fall back to direct discovery (legacy behavior; will
    # report DEGRADED on blocked hosts via the v1.177 diagnostic).
    local _spool="${BOTSCAN_SPOOL_DIR:-/var/lib/nftban/botscan/spool}"
    if [[ -d "$_spool" ]]; then
        local -a _sp=()
        for f in "$_spool"/*; do [[ -f "$f" && -r "$f" && -s "$f" ]] && _sp+=("$f"); done
        if [[ ${#_sp[@]} -gt 0 ]]; then printf '%s\n' "${_sp[@]}"; return 0; fi
    fi
    if declare -F nftban_http_discover_access_logs >/dev/null 2>&1; then
        while IFS= read -r f; do [[ -n "$f" ]] && logs+=("$f"); done \
            < <(nftban_http_discover_access_logs "${BOTSCAN_LOG_PATHS:-}")
    fi
    # Legacy single-file vars (back-compat; honors a custom-pointed path).
    for f in "$BOTSCAN_LOG_NGINX" "$BOTSCAN_LOG_APACHE" "$BOTSCAN_LOG_APACHE_ALT"; do
        [[ -n "$f" && -f "$f" && -r "$f" ]] && logs+=("$f")
    done
    [[ ${#logs[@]} -eq 0 ]] && return 1
    # Dedup, preserve order.
    local -A seen=(); local -a uniq=()
    for f in "${logs[@]}"; do [[ -n "${seen[$f]:-}" ]] && continue; seen[$f]=1; uniq+=("$f"); done
    printf '%s\n' "${uniq[@]}"
    return 0
}

# Back-compat single-path finder (status display, optional arg default). Returns
# the first discovered log, or "" if none.
nftban_botscan_find_log() {
    nftban_botscan_discover_logs 2>/dev/null | head -1
}

# v1.209.3 — reap a fully-consumed collector spool file (cursor-coordinated). The
# disk-backed spool (off tmpfs) is bounded by reaping each file once the forward
# scanner cursor has drained it to EOF. SAFETY GATES (all must hold):
#   1. the file is UNDER the spool dir — never deletes a real access log;
#   2. the file is non-empty and the scanner's persisted offset (inode:offset state
#      written by nftban_http_read_incremental) is >= the file size → fully read.
# The caller runs only on the batch/processor path, which holds the processor lock
# the collector also takes — so no collector append can race this delete. After
# reaping we drop BOTH the spool file and its cursor; the next collector cycle
# recreates the file fresh and the scanner reads it from offset 0 (collector source
# offsets are independent) → no duplicate, no loss. Returns 0 if reaped, 1 otherwise.
# Canonical cursor namespace for BotScan spool subjects, plus the historical
# directories that may still hold pre-migration cursor state. The spool dir the
# caller actually passes is ALWAYS added as a migration candidate too, so the
# path-derived cursor of the CURRENT location is picked up wherever the spool
# lives — which is what makes this migration survive the next relocation instead
# of only repairing the one v1.209.3 performed. Identity is now the
# LOGICAL subject (namespace + spool basename), so relocating the spool again can
# never orphan the cursor set the way v1.209.3 did.
: "${BOTSCAN_SPOOL_CURSOR_NS:=_botscan_spool_}"
: "${BOTSCAN_SPOOL_CURSOR_LEGACY_DIRS:=/run/nftban/botscan /var/lib/nftban/botscan/spool}"

# Reclaim a BotScan-owned spool object. Two bounded cases, both namespace-gated:
#
#   1. EMPTY      size == 0 -> no unread payload exists, so NO cursor is required
#                 to establish completion. Note the scanner enumerates with -s,
#                 so an empty spool file is never scanned and therefore could
#                 never become reclaimable through the normal completed path.
#   2. COMPLETED  cursor authority proves offset >= size.
#
# Everything else KEEPS. In particular a MISSING or CONFLICTING cursor is UNKNOWN
# authority — it is NOT offset zero and it is NOT permission to delete.
#
#   AGE IS NEVER THE DELETION AUTHORITY.
#
# Returns 0 if reclaimed, 1 otherwise. Echoes a verdict on fd 3 when open.
nftban_botscan_reap_consumed_spool() {
    local f="$1" spooldir="$2" offdir="$3"

    # --- structural gates: BotScan-owned spool objects only ------------------
    [[ -n "$spooldir" && "$f" == "$spooldir"/* ]] || return 1   # inside the namespace
    [[ "$f" != *"/.."* ]]                          || return 1   # no traversal
    [[ -L "$f" ]] && return 1                                    # never a symlink
    [[ -f "$f" ]] || return 1                                    # regular files only
    local base; base="$(basename -- "$f")"
    # Expected BotScan spool basename shape: the collector encodes the source path
    # as _var_log_... — anything else in this directory is not ours to delete.
    [[ "$base" == _* ]] || return 1

    local sz; sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
    [[ "$sz" =~ ^[0-9]+$ ]] || return 1

    # --- case 1: empty -> no payload to lose, no cursor needed ----------------
    if [[ "$sz" -eq 0 ]]; then
        rm -f -- "$f" 2>/dev/null || true
        return 0
    fi

    # --- case 2: completion must be PROVEN by cursor authority ----------------
    local res state statefile off=""
    res="$(NFTBAN_HTTP_LOG_OFFSET_DIR="$offdir" \
           NFTBAN_HTTP_CURSOR_NS="${BOTSCAN_SPOOL_CURSOR_NS}" \
           NFTBAN_HTTP_CURSOR_LEGACY_DIRS="${spooldir} ${BOTSCAN_SPOOL_CURSOR_LEGACY_DIRS}" \
           nftban_http_cursor_resolve "$f" 2>/dev/null)"
    statefile="${res%%|*}"; state="${res##*|}"

    case "$state" in
        CURRENT|MIGRATED) : ;;
        CONFLICT)
            # Two authorities disagree. Report and KEEP — never pick the value
            # that happens to authorize deletion.
            # Use the module's own log file, the same sink the SIGNAL/BANNED
            # records use — no invented logging interface.
            [[ -n "${BOTSCAN_LOG_FILE:-}" ]] && \
                echo "$(date -Iseconds)|botscan-spool|${base}|0|CURSOR_CONFLICT|keeping — two cursor authorities disagree, no deletion authority" \
                >> "$BOTSCAN_LOG_FILE" 2>/dev/null || true
            return 1 ;;
        *) return 1 ;;   # ABSENT -> UNKNOWN completion -> KEEP
    esac

    [[ -r "$statefile" ]] || return 1
    IFS=':' read -r _ off < "$statefile" 2>/dev/null || return 1
    [[ "$off" =~ ^[0-9]+$ ]] || return 1

    if [[ "$off" -ge "$sz" ]]; then
        rm -f -- "$f" "$statefile" 2>/dev/null || true
        return 0
    fi
    return 1
}

# Bounded spool reclamation sweep. Runs every scanner cycle so the bound stays a
# BOUND and not a LATCH: when the spool reaches its cap the collector asserts
# backpressure and stops appending, so unless completed work is retired here the
# spool can never fall back under cap and collection never resumes.
#
#   WHEN THE SPOOL REACHES ITS BOUND THE SYSTEM MUST RETIRE COMPLETED WORK
#   SO NEW ELIGIBLE WORK CAN ENTER. THE BOUND MUST REMAIN BOUNDED.
#
# This does NOT raise the cap. Raising the cap moves the failure point; it does
# not restore forward progress.
nftban_botscan_reclaim_spool() {
    local spooldir="${1:-${BOTSCAN_SPOOL_DIR:-/var/lib/nftban/botscan/spool}}"
    local offdir="${2:-${NFTBAN_HTTP_LOG_OFFSET_DIR:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/proc-offsets}}"
    [[ -d "$spooldir" ]] || return 0
    local f reclaimed=0 kept=0
    for f in "$spooldir"/*; do
        [[ -e "$f" ]] || continue
        if nftban_botscan_reap_consumed_spool "$f" "$spooldir" "$offdir"; then
            reclaimed=$((reclaimed+1))
        else
            kept=$((kept+1))
        fi
    done
    printf '%s %s\n' "$reclaimed" "$kept"
    return 0
}


# Parse access log line
# Returns: IP|URL|METHOD|STATUS|USER_AGENT
# v1.187.1 — NO-FORK parser. Sets the globals _BS_IP/_BS_URL/_BS_METHOD/_BS_STATUS/_BS_UA
# and returns 0 (parsed) / 1 (no match). The hot scan loops call THIS directly so a busy
# host no longer forks a subshell per log line (the v1.187.1 cycle-timeout fix: a 4.2 MB DA
# log was ~123s / 5497 lines = ~22 ms/line, dominated by per-line command-substitution forks
# — parse + match + timestamp). Regex semantics are byte-identical to the previous version.
# v1.234.0 — REQUEST time of an access-log line, from its own %t field:
#     [dd/Mon/yyyy:HH:MM:SS +zzzz]   (Apache/nginx/LiteSpeed common+combined)
# Sets _BS_REQ_TS (UTC epoch seconds). Returns 1 when the field is missing, malformed or
# out of range -- the caller then EXCLUDES the line: a line whose time cannot be read is
# never counted as a fresh event ("parse failure is not now").
# Fork-free (the tail loop is hot): bash regex + a month table + days-from-civil arithmetic,
# honouring the line's own UTC offset. 10# everywhere: "08"/"09" are not octal.
#     MEASURED (dns4, 2026-09-24): without this, 50 404s spread over FIVE WEEKS in the copied
#     log were counted as "50 in 55s" -- 55 s was the scan duration -- and a legitimate
#     client was banned every ~3.5 h.
nftban_botscan_request_epoch() {
    local _l="$1"
    [[ "$_l" =~ \[([0-9]{2})/([A-Z][a-z]{2})/([0-9]{4}):([0-9]{2}):([0-9]{2}):([0-9]{2})\ ([+-])([0-9]{2})([0-9]{2})\] ]] || return 1
    local _d=$((10#${BASH_REMATCH[1]})) _mo=0 _y=$((10#${BASH_REMATCH[3]}))
    local _H=$((10#${BASH_REMATCH[4]})) _M=$((10#${BASH_REMATCH[5]})) _S=$((10#${BASH_REMATCH[6]}))
    local _sg="${BASH_REMATCH[7]}" _oh=$((10#${BASH_REMATCH[8]})) _om=$((10#${BASH_REMATCH[9]}))
    case "${BASH_REMATCH[2]}" in
        Jan) _mo=1;; Feb) _mo=2;; Mar) _mo=3;; Apr) _mo=4;; May) _mo=5;; Jun) _mo=6;;
        Jul) _mo=7;; Aug) _mo=8;; Sep) _mo=9;; Oct) _mo=10;; Nov) _mo=11;; Dec) _mo=12;;
        *) return 1;;
    esac
    (( _d >= 1 && _d <= 31 && _H <= 23 && _M <= 59 && _S <= 60 && _oh <= 23 && _om <= 59 && _y >= 1970 )) || return 1
    # days from civil (proleptic Gregorian; H. Hinnant) -- the year starts in March
    local _yy=$(( _mo <= 2 ? _y - 1 : _y ))
    local _era=$(( _yy / 400 )) _yoe _doy _doe _off
    _yoe=$(( _yy - _era * 400 ))
    _doy=$(( (153 * (_mo > 2 ? _mo - 3 : _mo + 9) + 2) / 5 + _d - 1 ))
    _doe=$(( _yoe * 365 + _yoe / 4 - _yoe / 100 + _doy ))
    _off=$(( _oh * 3600 + _om * 60 ))
    [[ "$_sg" == "-" ]] && _off=$(( -_off ))
    _BS_REQ_TS=$(( (_era * 146097 + _doe - 719468) * 86400 + _H * 3600 + _M * 60 + _S - _off ))
    return 0
}

nftban_botscan_parse_line_g() {
    local line="$1"

    # Combined Log Format: IP - - [date] "METHOD URL PROTO" STATUS SIZE "REFERER" "UA"
    # IPv4 and IPv6 compatible (v1.19.0, v1.19.12 bracket fix R22)
    # Handles: 192.168.1.1, 2001:db8::1, [2001:db8::1]:8080
    if [[ "$line" =~ ^\[?([0-9a-fA-F.:]+)\]?.*\"([A-Z]+)\ ([^\"\ ]+).*\"\ ([0-9]+) ]]; then
        _BS_IP="${BASH_REMATCH[1]}"
        _BS_METHOD="${BASH_REMATCH[2]}"
        _BS_URL="${BASH_REMATCH[3]}"
        _BS_STATUS="${BASH_REMATCH[4]}"

        # Extract user agent — the LAST quoted field. v1.234.0
        # (BUG-BOTSCAN-UA-PARSE-ESCAPED-QUOTE-BECOMES-DASH): Apache/nginx escape a quote
        # inside a field as \", so the field is a run of (non-quote, non-backslash) or
        # (backslash + any char). The old `"([^"]+)"$` failed on any UA containing an
        # escaped quote at its end and returned "-", which fired SINGLE_DASH on real
        # visitors and hid the UA from every useragent rule.
        #   logged "-" or ""        -> "-"  (the client really sent no User-Agent)
        #   no trailing quoted field -> ""  UNKNOWN (common log format, truncated or
        #                                   malformed line): never "-", so an unparseable
        #                                   line is not converted into "empty-UA" evidence;
        #                                   useragent rules skip an empty UA; counted and
        #                                   reported (BOTSCAN_PARSE ua_unparsed=N).
        if [[ "$line" =~ \"(([^\"\\]|\\.)*)\"$ ]]; then
            _BS_UA="${BASH_REMATCH[1]}"
            [[ -n "$_BS_UA" ]] || _BS_UA="-"
        else
            _BS_UA=""
            _BS_T_UA_UNPARSED=$(( ${_BS_T_UA_UNPARSED:-0} + 1 ))
        fi

        return 0
    fi

    return 1
}

# Echo-API wrapper — UNCHANGED output contract (IP|URL|METHOD|STATUS|UA). Used by
# cmd_botscan (emulate) and existing tests. Delegates to the no-fork parser so the two
# can never drift.
nftban_botscan_parse_line() {
    nftban_botscan_parse_line_g "$1" || return 1
    echo "${_BS_IP}|${_BS_URL}|${_BS_METHOD}|${_BS_STATUS}|${_BS_UA}"
}

# Check if IP is whitelisted — v1.19.0: IPv4/IPv6 parity
# v1.189 FCrDNS — allowed PTR-suffix regex per rDNS-verifiable crawler family.
# Echoes the suffix ERE + rc=0 for verifiable families; rc=1 for families with NO
# documented rDNS convention (e.g. facebot) → those keep the legacy UA whitelist.
# Provider-documented suffixes ONLY (Google/Bing forward-confirmed-rDNS method).
nftban_botscan_crawler_family_suffix() {
    case "${1,,}" in
        googlebot)        echo '(^|\.)(googlebot\.com|google\.com|googleusercontent\.com)$' ;;
        bingbot|msnbot)   echo '(^|\.)search\.msn\.com$' ;;
        yandexbot|yandex) echo '(^|\.)(yandex\.com|yandex\.ru|yandex\.net)$' ;;
        duckduckbot)      echo '(^|\.)duckduckgo\.com$' ;;
        slurp)            echo '(^|\.)crawl\.yahoo\.net$' ;;
        applebot)         echo '(^|\.)applebot\.apple\.com$' ;;
        baiduspider)      echo '(^|\.)crawl\.baidu\.com$' ;;
        *) return 1 ;;
    esac
    return 0
}

# v1.189 FCrDNS — resolver selection (self-contained; botscan must NOT depend on the RBL
# module being sourced). Prefers host (legacy parser-friendly), then dig, then nslookup.
# Echoes the binary name, or empty if none available.
nftban_botscan_resolver() {
    if command -v host >/dev/null 2>&1; then echo "host"
    elif command -v dig >/dev/null 2>&1; then echo "dig"
    elif command -v nslookup >/dev/null 2>&1; then echo "nslookup"
    else echo ""; fi
}

# v1.189 FCrDNS — forward-confirmed reverse DNS verification of a claimed crawler.
# ANALYZE-TIME ONLY (per unique candidate IP) — NEVER called from the per-line hot path
# (that path stays fork-free, v1.187.1). Returns 0 (verified real crawler) / 1 (not).
# Fail-closed: no PTR / suffix mismatch / forward mismatch / timeout / resolver error ⇒ 1.
# Cached by ip+family (positive 24h / negative 6h / error 30m); atomic in-flight guard so a
# flood does not fan out N lookups; hard per-lookup timeouts. Reuses the RBL resolver chain.
nftban_botscan_verify_crawler() {
    local ip="$1" family="$2"
    [[ "${BOTSCAN_VERIFY_CRAWLERS:-true}" == "true" ]] || return 1
    local suffix; suffix=$(nftban_botscan_crawler_family_suffix "$family") || return 1
    local cdir="${BOTSCAN_VERIFY_CACHE_DIR:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/crawler-verify}"
    local key cf cached now age ttl
    key=$(printf '%s_%s' "$ip" "${family,,}" | tr -c 'A-Za-z0-9_.:-' '_')
    cf="${cdir}/${key}"
    if [[ -r "$cf" ]]; then
        IFS='|' read -r cached _ < "$cf" 2>/dev/null || true
        now=$(date +%s); age=$(( now - $(stat -c %Y "$cf" 2>/dev/null || echo "$now") ))
        case "$cached" in
            OK)  ttl="${BOTSCAN_VERIFY_TTL_OK:-86400}" ;;
            BAD) ttl="${BOTSCAN_VERIFY_TTL_BAD:-21600}" ;;
            *)   ttl="${BOTSCAN_VERIFY_TTL_ERR:-1800}" ;;
        esac
        if [[ "$age" -lt "$ttl" ]]; then
            [[ "$cached" == "OK" ]] && return 0 || return 1
        fi
    fi
    mkdir -p "$cdir" 2>/dev/null || true
    # atomic in-flight guard: if another verification for this key is running, treat as
    # unknown (=not verified) this cycle rather than fan out a second lookup.
    local lock="${cf}.lock"
    mkdir "$lock" 2>/dev/null || return 1
    local resolver to verdict="ERR" ptr="" fwd=""
    resolver=$(nftban_botscan_resolver)
    to="${BOTSCAN_VERIFY_TIMEOUT:-1}"
    if [[ -n "$resolver" ]]; then
        case "$resolver" in
            host)     ptr=$(timeout "$to" host -t PTR "$ip" 2>/dev/null | grep -oiE 'pointer [^ ]+' | awk '{print $2}' | sed 's/\.$//' | head -1) ;;
            dig)      ptr=$(timeout "$to" dig +short -x "$ip" 2>/dev/null | sed 's/\.$//' | head -1) ;;
            nslookup) ptr=$(timeout "$to" nslookup -type=PTR "$ip" 2>/dev/null | grep -oiE 'name = [^ ]+' | awk '{print $3}' | sed 's/\.$//' | head -1) ;;
        esac
        if [[ -n "$ptr" ]] && printf '%s' "$ptr" | grep -qiE "$suffix"; then
            case "$resolver" in
                host)     fwd=$(timeout "$to" host "$ptr" 2>/dev/null | grep -oiE 'address[: ] *[0-9a-f:.]+' | grep -oiE '[0-9a-f:.]+$') ;;
                dig)      fwd=$({ timeout "$to" dig +short A "$ptr" 2>/dev/null; timeout "$to" dig +short AAAA "$ptr" 2>/dev/null; } | sed 's/\.$//') ;;
                nslookup) fwd=$(timeout "$to" nslookup "$ptr" 2>/dev/null | grep -oiE 'address: [0-9a-f:.]+' | awk '{print $2}') ;;
            esac
            if printf '%s\n' "$fwd" | grep -qxF "$ip"; then verdict="OK"; else verdict="BAD"; fi
        else
            verdict="BAD"
        fi
    fi
    printf '%s|%s\n' "$verdict" "$ptr" > "$cf" 2>/dev/null || true
    rmdir "$lock" 2>/dev/null || true
    [[ "$verdict" == "OK" ]] && return 0 || return 1
}

nftban_botscan_is_whitelisted() {
    local ip="$1"
    local ua="${2:-}"

    # Localhost (both families)
    [[ "$ip" == "127.0.0.1" || "$ip" == "::1" ]] && return 0

    # Private networks (both families — never ban internal traffic)
    [[ "$ip" =~ ^10\. ]] && return 0
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0
    [[ "$ip" =~ ^[Ff][CcDd] ]] && return 0
    [[ "$ip" =~ ^[Ff][Ee]80: ]] && return 0

    # v1.209.x F2: daemon-published never-ban exemption list (admin/management/whitelist/
    # system/live-SSH). Cheap EXACT-match — no nft read needed, so it works under the
    # unprivileged scanner (which cannot query the nft whitelist set on most hosts). This
    # is early signal-suppression / defense-in-depth ONLY; range-aware coverage and the
    # authoritative never-ban invariant are enforced by the daemon at the ban-apply
    # boundary (Backend.Ban), independent of this gate.
    local _exempt_file="${BOTSCAN_EXEMPT_FILE:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/exempt.list}"
    if [[ -r "$_exempt_file" ]] && grep -qxF "$ip" "$_exempt_file" 2>/dev/null; then
        return 0
    fi

    # Check global whitelist
    if [[ "$BOTSCAN_USE_GLOBAL_WHITELIST" == "true" ]]; then
        if type -t nftban_is_whitelisted &>/dev/null; then
            nftban_is_whitelisted "$ip" && return 0
        fi
    fi

    # Check bot whitelist (user agent)
    if [[ -n "$ua" ]]; then
        # IFS-safe split: strict.sh sets IFS=$'\n\t', so space-separated vars need explicit splitting
        local bot _whitelist_bots
        IFS=' ' read -ra _whitelist_bots <<< "${BOTSCAN_WHITELIST_BOTS//,/ }"
        for bot in "${_whitelist_bots[@]}"; do
            if [[ "${ua,,}" =~ ${bot,,} ]]; then
                # v1.189 FCrDNS: UA is attacker-controlled. For rDNS-verifiable families,
                # do NOT blanket-whitelist here (that is the spoofable evasion bug). Record
                # the claim (cheap, no fork) and KEEP COUNTING; analyze() verifies per-IP and
                # exempts ONLY verified crawlers from the 404-flood ban (fail-closed). For
                # families with no rDNS convention (e.g. facebot), keep the legacy whitelist.
                if [[ "${BOTSCAN_VERIFY_CRAWLERS:-true}" == "true" ]] \
                   && nftban_botscan_crawler_family_suffix "$bot" >/dev/null 2>&1; then
                    _BOTSCAN_IP_CRAWLER_CLAIM["$ip"]="$bot"
                    return 1
                fi
                return 0
            fi
        done
    fi

    return 1
}

# Check if URL is whitelisted
nftban_botscan_is_path_whitelisted() {
    local url="$1"

    if [[ "$url" =~ $BOTSCAN_WHITELIST_PATHS ]]; then
        return 0
    fi

    return 1
}

# =============================================================================
# DETECTION ENGINE
# =============================================================================

# Match URL against patterns
# Returns: matched pattern name or empty
# v1.187.1 — NO-FORK matcher. Sets _BS_MATCHED to the matched pattern name ("" if none) and
# returns 0 (match) / 1 (no match). Same iteration order + match-type semantics as the echo
# API; called directly from the hot path (process_entry) to drop the per-line subshell fork.
nftban_botscan_match_url_g() {
    local url="$1"
    local method="$2"
    local status="$3"
    local ua="${4:-}"
    _BS_MATCHED=""
    _BS_MATCHED_MODE="hits"
    # v1.234.0 — collect EVERY matching pattern (a line can be evidence for several rules,
    # e.g. `/.env` for both EXP_ENVFILE and SCAN_HIDDEN). Attributing it only to the first
    # match in hash order split the evidence of one request between rules arbitrarily.
    # _BS_MATCHED / _BS_MATCHED_MODE keep the first match (the echo API contract).
    _BS_MATCHES=(); _BS_MATCH_MODES=()
    # v1.234.0 — the request PATH (the target without its query string). path-* patterns
    # match it; distinct-* patterns match the raw target and count distinct targets.
    local path="${url%%\?*}"

    local name def pattern match_type
    for name in "${!_BOTSCAN_PATTERNS[@]}"; do
        def="${_BOTSCAN_PATTERNS[$name]}"

        IFS="$_BS_US" read -r pattern match_type _ _ _ _ <<< "$def"  # v1.214.0 '|'-safe internal split

        # Check match type
        case "$match_type" in
            path-404)
                [[ "$status" != "404" ]] && continue
                if [[ "$path" =~ $pattern ]]; then _BS_MATCHES+=("$name"); _BS_MATCH_MODES+=("hits"); fi
                ;;
            path-post)
                [[ "$method" != "POST" ]] && continue
                if [[ "$path" =~ $pattern ]]; then _BS_MATCHES+=("$name"); _BS_MATCH_MODES+=("hits"); fi
                ;;
            path-get)
                [[ "$method" != "GET" ]] && continue
                if [[ "$path" =~ $pattern ]]; then _BS_MATCHES+=("$name"); _BS_MATCH_MODES+=("hits"); fi
                ;;
            path-any)
                if [[ "$path" =~ $pattern ]]; then _BS_MATCHES+=("$name"); _BS_MATCH_MODES+=("hits"); fi
                ;;
            distinct-404)
                [[ "$status" != "404" ]] && continue
                if [[ "$url" =~ $pattern ]]; then _BS_MATCHES+=("$name"); _BS_MATCH_MODES+=("distinct"); fi
                ;;
            distinct-post)
                [[ "$method" != "POST" ]] && continue
                if [[ "$url" =~ $pattern ]]; then _BS_MATCHES+=("$name"); _BS_MATCH_MODES+=("distinct"); fi
                ;;
            distinct-get)
                [[ "$method" != "GET" ]] && continue
                if [[ "$url" =~ $pattern ]]; then _BS_MATCHES+=("$name"); _BS_MATCH_MODES+=("distinct"); fi
                ;;
            distinct-any)
                if [[ "$url" =~ $pattern ]]; then _BS_MATCHES+=("$name"); _BS_MATCH_MODES+=("distinct"); fi
                ;;
            url-404)
                [[ "$status" != "404" ]] && continue
                # Match URL pattern
                if [[ "$url" =~ $pattern ]]; then _BS_MATCHES+=("$name"); _BS_MATCH_MODES+=("hits"); fi
                ;;
            url-post)
                [[ "$method" != "POST" ]] && continue
                if [[ "$url" =~ $pattern ]]; then _BS_MATCHES+=("$name"); _BS_MATCH_MODES+=("hits"); fi
                ;;
            url-get)
                [[ "$method" != "GET" ]] && continue
                if [[ "$url" =~ $pattern ]]; then _BS_MATCHES+=("$name"); _BS_MATCH_MODES+=("hits"); fi
                ;;
            url-any)
                if [[ "$url" =~ $pattern ]]; then _BS_MATCHES+=("$name"); _BS_MATCH_MODES+=("hits"); fi
                ;;
            useragent)
                # Match against user-agent string
                if [[ -n "$ua" && "$ua" =~ $pattern ]]; then _BS_MATCHES+=("$name"); _BS_MATCH_MODES+=("hits"); fi
                ;;
        esac
    done

    if [[ "${#_BS_MATCHES[@]}" -gt 0 ]]; then
        _BS_MATCHED="${_BS_MATCHES[0]}"; _BS_MATCHED_MODE="${_BS_MATCH_MODES[0]}"
        return 0
    fi
    return 1
}

# Echo-API wrapper — UNCHANGED contract (echoes the matched pattern name, returns 1 on no
# match). Used by cmd_botscan (emulate). Delegates to the no-fork matcher.
nftban_botscan_match_url() {
    nftban_botscan_match_url_g "$@" || return 1
    echo "$_BS_MATCHED"
}

# Process log entry
# Args: ip url method status ua [request_epoch]
# v1.234.0 — the 6th argument is the REQUEST time of the line (nftban_botscan_request_epoch).
# The scan loop always passes it; an empty or non-numeric value means the line's time could
# not be read and the line contributes NO pattern evidence (it is counted and reported as
# unreadable, never placed at "now"). A caller that passes only 5 arguments (interactive
# emulate, unit tests) is an API caller with no log line: its event is placed at the cycle's
# "now". Evidence whose request time is in the future, or older than the evidence horizon D,
# is excluded and reported.
nftban_botscan_process_entry() {
    local ip="$1"
    local url="$2"
    local method="$3"
    local status="$4"
    local ua="$5"
    local now="${_BS_CYCLE_NOW:-}"
    [[ "$now" =~ ^[0-9]+$ ]] || printf -v now '%(%s)T' -1 2>/dev/null || now=$(date +%s)
    local req_ts
    if [[ $# -ge 6 ]]; then req_ts="$6"; else req_ts="$now"; fi

    # Check whitelists
    nftban_botscan_is_whitelisted "$ip" "$ua" && return 0
    nftban_botscan_is_path_whitelisted "$url" && return 0

    # (v1.234.0: the dead main-loop 404 counter is removed -- design §5; the 404 arrays are
    #  owned by nftban_botscan_count_404_tail, which resets them before counting.)

    # Match against patterns (URL and user-agent) — v1.187.1 no-fork matcher (was a per-line
    # command-substitution fork). errexit-safe: the && only assigns on a match.
    nftban_botscan_match_url_g "$url" "$method" "$status" "$ua" || return 0

    # v1.234.0 — place the evidence in REQUEST time.
    if [[ ! "$req_ts" =~ ^[0-9]+$ ]]; then _BS_T_PAT_UNREADABLE=$(( _BS_T_PAT_UNREADABLE + 1 )); return 0; fi
    if (( req_ts > now )); then _BS_T_PAT_FUTURE=$(( _BS_T_PAT_FUTURE + 1 )); return 0; fi
    if (( now - req_ts > _BS_PATTERN_EVIDENCE_HORIZON )); then _BS_T_PAT_STALE=$(( _BS_T_PAT_STALE + 1 )); return 0; fi

    local _mi matched_pattern _mm _counted=0
    for (( _mi=0; _mi<${#_BS_MATCHES[@]}; _mi++ )); do
        matched_pattern="${_BS_MATCHES[_mi]}"; _mm="${_BS_MATCH_MODES[_mi]}"
        if [[ "$_mm" == "distinct" ]]; then
            # distinct-* patterns: an identical target already counted for this IP and
            # pattern adds no evidence (a client polling one route is not enumerating).
            local _dk="${ip}${_BS_US}${matched_pattern}${_BS_US}${url}"
            if [[ -n "${_BOTSCAN_DISTINCT_SEEN[$_dk]:-}" ]]; then _BS_T_PAT_REPEAT=$(( _BS_T_PAT_REPEAT + 1 )); continue; fi
            _BOTSCAN_DISTINCT_SEEN["$_dk"]=1
            # Cross-rule probe aggregate: probing is VARIETY, so distinct targets of
            # DIFFERENT probe rules corroborate each other (each target once).
            local _pk="${ip}${_BS_US}${url}"
            if [[ -z "${_BOTSCAN_PROBE_SEEN[$_pk]:-}" ]]; then
                _BOTSCAN_PROBE_SEEN["$_pk"]=1
                _BOTSCAN_PROBE_TS["$ip"]="${_BOTSCAN_PROBE_TS[$ip]:-} $req_ts"
            fi
        fi
        _BOTSCAN_IP_PATTERNS["$ip"]="${_BOTSCAN_IP_PATTERNS[$ip]:-} $matched_pattern"
        _BOTSCAN_IPPAT_TS["${ip}${_BS_US}${matched_pattern}"]="${_BOTSCAN_IPPAT_TS[${ip}${_BS_US}${matched_pattern}]:-} $req_ts"
        _counted=1
    done
    (( _counted )) || return 0

    # Update tracking (one tracked hit per LINE; first/last seen are REQUEST times)
    _BOTSCAN_IP_HITS["$ip"]=$(( ${_BOTSCAN_IP_HITS[$ip]:-0} + 1 ))
    if [[ -z "${_BOTSCAN_IP_FIRST_SEEN[$ip]:-}" ]] || (( req_ts < ${_BOTSCAN_IP_FIRST_SEEN[$ip]} )); then _BOTSCAN_IP_FIRST_SEEN["$ip"]="$req_ts"; fi
    if [[ -z "${_BOTSCAN_IP_LAST_SEEN[$ip]:-}" ]] || (( req_ts > ${_BOTSCAN_IP_LAST_SEEN[$ip]} )); then _BOTSCAN_IP_LAST_SEEN["$ip"]="$req_ts"; fi

    [[ "$BOTSCAN_DEBUG" == "true" ]] && echo "[DEBUG] $ip matched ${_BS_MATCHES[*]}: $url" >&2

    return 0
}

# v1.234.0 — nftban_botscan_max_in_window <window> <epoch>...
# Echoes the largest number of the given request epochs that fit in ANY window of <window>
# seconds (max(ts)-min(ts) <= window, both ends inclusive). A sliding window over REQUEST
# time: it measures density, not how long the scan took.
nftban_botscan_max_in_window() {
    local w="$1"; shift
    local -a ts=()
    [[ $# -gt 0 ]] || { echo 0; return 0; }
    mapfile -t ts < <(printf '%s\n' "$@" | sort -n)
    local n=${#ts[@]} l=0 r best=0
    for (( r=0; r<n; r++ )); do
        while (( ts[r] - ts[l] > w )); do l=$(( l + 1 )); done
        (( r - l + 1 > best )) && best=$(( r - l + 1 ))
    done
    echo "$best"
}

# Analyze tracked IPs and ban if threshold exceeded
nftban_botscan_analyze() {
    local now
    now=$(nftban_timestamp_unix 2>/dev/null || date +%s)
    local banned=0

    for ip in "${!_BOTSCAN_IP_HITS[@]}"; do
        local hits="${_BOTSCAN_IP_HITS[$ip]}"
        local patterns="${_BOTSCAN_IP_PATTERNS[$ip]:-}"
        # v1.234.0 — the v1.192.2 per-IP "authenticated WP-admin" suppression is retired (see
        # load_config). Authentication context is UNKNOWN to an access-log scanner; detection
        # does not depend on it.

        # v1.234.0 — EACH PATTERN IS JUDGED ON ITS OWN EVIDENCE
        # (BUG-BOTSCAN-PATTERN-THRESHOLD-CAPPED-AT-DEFAULT). The old decision seeded the
        # threshold/window with BOTSCAN_DEFAULT_THRESHOLD (5) / _WINDOW (60), kept the
        # minimum, and compared the SUM of hits across different patterns: every rule
        # documented above 5 banned at 5 (measured fleet-wide: 1,155 signals below the
        # documented threshold), and hits of unrelated rules topped each other up.
        # Now a pattern fires iff ITS OWN events reach ITS documented threshold within ITS
        # documented window, measured in REQUEST time (a sliding window over the lines'
        # own timestamps — the old `now - first_seen` measured how long the scan took).
        # The ban uses the longest documented duration among the patterns that FIRED.
        # (Supersedes design ruling C5 "keep per-IP aggregation"; owner to confirm.)
        #
        # Split the space-joined matched-pattern list IFS-INDEPENDENTLY. The lib sets a
        # global IFS=$'\n\t' (no space) at source time, so an unquoted `for x in $patterns`
        # over " NAME" keeps the leading space → key lookup misses (v1.186.1 class).
        local -a _ip_pats=() _fired=()
        local -A _ip_pat_seen=()
        local ban_duration="" _fired_desc=""
        IFS=$' \t\n' read -ra _ip_pats <<< "$patterns"
        for pattern_name in "${_ip_pats[@]}"; do
            [[ -z "$pattern_name" || -n "${_ip_pat_seen[$pattern_name]:-}" ]] && continue
            _ip_pat_seen["$pattern_name"]=1
            local def="${_BOTSCAN_PATTERNS[$pattern_name]:-}"
            [[ -z "$def" ]] && continue

            local p_threshold p_window p_ban
            IFS="$_BS_US" read -r _ _ p_threshold p_window p_ban _ <<< "$def"  # v1.214.0 '|'-safe internal split
            [[ "$p_threshold" =~ ^[0-9]+$ && "$p_window" =~ ^[0-9]+$ && "$p_ban" =~ ^[0-9]+$ ]] || continue
            (( p_threshold >= 1 )) || p_threshold=1

            local -a _p_ts=()
            IFS=$' \t\n' read -ra _p_ts <<< "${_BOTSCAN_IPPAT_TS[${ip}${_BS_US}${pattern_name}]:-}"
            (( ${#_p_ts[@]} >= p_threshold )) || continue
            local _p_in
            _p_in="$(nftban_botscan_max_in_window "$p_window" "${_p_ts[@]}")"
            (( _p_in >= p_threshold )) || continue
            _fired+=("$pattern_name")
            _fired_desc+=" ${pattern_name} ${_p_in}/${p_threshold} in ${p_window}s;"
            [[ -z "$ban_duration" || "$p_ban" -gt "$ban_duration" ]] && ban_duration="$p_ban"
        done

        # PROBE VARIETY — the ONLY cross-rule aggregation (owner-approved definition,
        # documented in the shipped pattern-file headers):
        #   rules      every enabled distinct-* record
        #   counted    DISTINCT request targets (path+query) from this IP that matched any
        #              of them; each target once (_BOTSCAN_PROBE_SEEN), whatever rules it hit
        #   threshold  the LOWEST THRESHOLD among the distinct-* rules this IP matched
        #   window     the SHORTEST WINDOW among them, sliding over request time
        #   ban        the LONGEST BAN among them; reason "probe-variety N/T distinct targets in Ws"
        #   configured only through those records (override.local disabling a rule
        #              removes it); no separate key.
        # Rationale: probing is evidenced by variety — ten different backup/admin/shell
        # names from one client is a scan even if no single rule reached its own threshold.
        # Hit-counting rules (exploit payloads, UA rates) never sum across rules.
        # Tests: botscan_detection_correctness_v1234_test R13 (positive, N-1, window,
        # repetition, benign client).
        if [[ -n "${_BOTSCAN_PROBE_TS[$ip]:-}" ]]; then
            local _pt="" _pw="" _pb="" _pn _pdef _pmt _pth _pwi _pba
            for _pn in "${!_ip_pat_seen[@]}"; do
                _pdef="${_BOTSCAN_PATTERNS[$_pn]:-}"; [[ -n "$_pdef" ]] || continue
                IFS="$_BS_US" read -r _ _pmt _pth _pwi _pba _ <<< "$_pdef"
                [[ "$_pmt" == distinct-* && "$_pth" =~ ^[0-9]+$ && "$_pwi" =~ ^[0-9]+$ && "$_pba" =~ ^[0-9]+$ ]] || continue
                [[ -z "$_pt" || "$_pth" -lt "$_pt" ]] && _pt="$_pth"
                [[ -z "$_pw" || "$_pwi" -lt "$_pw" ]] && _pw="$_pwi"
                [[ -z "$_pb" || "$_pba" -gt "$_pb" ]] && _pb="$_pba"
            done
            if [[ -n "$_pt" ]]; then
                local -a _pr_ts=()
                IFS=$' \t\n' read -ra _pr_ts <<< "${_BOTSCAN_PROBE_TS[$ip]}"
                if (( ${#_pr_ts[@]} >= _pt )); then
                    local _pr_in
                    _pr_in="$(nftban_botscan_max_in_window "$_pw" "${_pr_ts[@]}")"
                    if (( _pr_in >= _pt )); then
                        _fired+=("probe-variety")
                        _fired_desc+=" probe-variety ${_pr_in}/${_pt} distinct targets in ${_pw}s;"
                        [[ -z "$ban_duration" || "$_pb" -gt "$ban_duration" ]] && ban_duration="$_pb"
                    fi
                fi
            fi
        fi

        if [[ "${#_fired[@]}" -gt 0 ]]; then
            # v1.191 8B inc3 — URL/UA pattern bans are scanner/webshell/exploit probes by
            # definition (this module's purpose); label the signal accordingly, then clear.
            BOTSCAN_SIGNAL_REQUEST_CLASS="$(nftban_botscan_classify_request_class "" "" "" "scanner pattern: $patterns")"
            nftban_botscan_ban_ip "$ip" "$ban_duration" "botscan" "Matched patterns: $patterns (hits: $hits; fired (request time):${_fired_desc%;})"
            BOTSCAN_SIGNAL_REQUEST_CLASS=""
            banned=$((banned + 1))
            nftban_botscan_counter_add bans_emitted 1 || true
        fi
    done

    # Check 404 flood (enforce BOTSCAN_404_WINDOW)
    if [[ "$BOTSCAN_404_TRACKING" == "true" ]]; then
        # v1.234.0: counts hold only events whose REQUEST time is inside the window, and the
        # span is measured between request times -- never scan time (see count_404_tail).
        for ip in "${!_BOTSCAN_IP_404_COUNT[@]}"; do
            local count="${_BOTSCAN_IP_404_COUNT[$ip]}"
            local first_seen="${_BOTSCAN_IP_404_FIRST_SEEN[$ip]:-}" last_seen="${_BOTSCAN_IP_404_LAST_SEEN[$ip]:-}"
            [[ "$first_seen" =~ ^[0-9]+$ && "$last_seen" =~ ^[0-9]+$ ]] || continue   # no request time => no decision
            local elapsed=$(( last_seen - first_seen ))
            if [[ "$count" -ge "$BOTSCAN_404_THRESHOLD" && "$elapsed" -le "$BOTSCAN_404_WINDOW" ]]; then
                # v1.189 FCrDNS — a CLAIMED search-crawler that is forward-confirmed-rDNS
                # verified is exempt from the 404-flood ban ONLY (real crawlers legitimately
                # hit 404s). Verification runs HERE (per unique candidate IP), never per line.
                # Unverified / mismatch / timeout = spoofer ⇒ ban (fail-closed). This does NOT
                # whitelist the IP from exploit/webshell/scanner URL-pattern bans (those are
                # handled in the pattern loop above and are NEVER exempted by crawler-verify).
                local _claim="${_BOTSCAN_IP_CRAWLER_CLAIM[$ip]:-}"
                if [[ -n "$_claim" ]] && nftban_botscan_verify_crawler "$ip" "$_claim"; then
                    [[ "$BOTSCAN_DEBUG" == "true" ]] && echo "[DEBUG] verified crawler ${_claim} (${ip}) — exempt from 404-flood" >&2
                    continue
                fi
                local _reason="404 flood: $count in ${elapsed}s (request time)"
                [[ -n "$_claim" ]] && _reason="fake_bot_ua (${_claim} unverified) — ${_reason}"
                # v1.191 8B inc3 — fake_bot_ua → scanner; a plain 404-flood carries no path
                # evidence here, so it stays the honest fallback (mixed), never guessed.
                BOTSCAN_SIGNAL_REQUEST_CLASS="$(nftban_botscan_classify_request_class "GET" "" "404" "$_reason")"
                nftban_botscan_ban_ip "$ip" "$BOTSCAN_404_BAN" "botscan-404" "$_reason"
                BOTSCAN_SIGNAL_REQUEST_CLASS=""
                banned=$((banned + 1))
                nftban_botscan_counter_add bans_emitted 1 || true
            fi
        done
    fi

    # BOTSCAN-ENDPOINT-FLOOD — per-IP/per-endpoint POST-volume bans (counts populated by
    # count_404_tail in the same proven tail re-read). Emitted via the BATCH-SIGNAL path
    # ONLY — never nftban_botscan_ban_ip's direct branch (BUG-BOTSCAN-DIRECT-BAN-FLAG).
    if [[ "${BOTSCAN_ENDPOINT_FLOOD_ENABLED:-true}" == "true" ]]; then
        local _k
        for _k in "${!_BOTSCAN_IP_ENDPOINT_COUNT[@]}"; do
            local _cnt="${_BOTSCAN_IP_ENDPOINT_COUNT[$_k]}"
            local _fs="${_BOTSCAN_IP_ENDPOINT_FIRST_SEEN[$_k]:-}" _ls="${_BOTSCAN_IP_ENDPOINT_LAST_SEEN[$_k]:-}"
            [[ "$_fs" =~ ^[0-9]+$ && "$_ls" =~ ^[0-9]+$ ]] || continue   # no request time => no decision
            local _el=$(( _ls - _fs ))
            [[ "$_cnt" -ge "$BOTSCAN_ENDPOINT_FLOOD_THRESHOLD" && "$_el" -le "$BOTSCAN_ENDPOINT_FLOOD_WINDOW" ]] || continue
            local _efip="${_k%%|*}" _efep="${_k#*|}"
            local _efreason="endpoint_flood ${BOTSCAN_ENDPOINT_FLOOD_METHOD} ${_efep}: ${_cnt} in ${_el}s (request time)"
            # v1.234.0 — never ban a shared CDN edge (endpoint-flood path).
            nftban_botscan_shared_edge_guard "$_efip" "botscan-endpoint-flood" "$_efreason" && continue
            if [[ "$BOTSCAN_ACTION_MODE" == "alert" ]]; then
                echo "[ALERT] Would ban ${_efip} for ${BOTSCAN_ENDPOINT_FLOOD_BAN}s: ${_efreason}"
            else
                # batch-signal path (mirrors ban_ip's batch branch; NOT the direct branch)
                # v1.191 8B inc3 — real method+endpoint evidence → dynamic_abuse.
                BOTSCAN_SIGNAL_REQUEST_CLASS="$(nftban_botscan_classify_request_class "${BOTSCAN_ENDPOINT_FLOOD_METHOD}" "${_efep}" "" "endpoint_flood")"
                BOTSCAN_SIGNAL_REQUESTED_TTL="${BOTSCAN_ENDPOINT_FLOOD_BAN}" nftban_botscan_write_signal "${_efip}" 80 "ban" "botscan-endpoint-flood" "${_efreason}"
                BOTSCAN_SIGNAL_REQUEST_CLASS=""
                echo "$(date -Iseconds)|botscan-endpoint-flood|${_efip}|${BOTSCAN_ENDPOINT_FLOOD_BAN}|SIGNAL|${_efreason}" >> "$BOTSCAN_LOG_FILE"
            fi
            banned=$((banned + 1))
            nftban_botscan_counter_add bans_emitted 1 || true
        done
    fi

    # v1.231.0 P0-B — B2. This function USED TO `return $banned`, i.e. it encoded a
    # COUNT in its EXIT STATUS while its only caller captured STDOUT. Consequences,
    # all measured: count>0 made rc!=0 which tripped the caller's `|| banned=0`;
    # count==0 left stdout empty on the batch-signal path; so the caller's value was
    # ALWAYS "" or 0. Exit status is additionally mod-256, so the channel silently
    # wrapped at 256 bans. The count now travels on the explicit sink channel and the
    # exit status means only what an exit status may mean: did this run succeed.
    return 0
}

# v1.234.0 — nftban_botscan_prefilter_relax <ERE>
# Echoes a regex that matches a whole access-log LINE wherever <ERE> matches the request
# path/target inside it (a sound superset): an anchor `^` at the start of the regex or of a
# group/alternative is dropped, and an anchor `$` at the end of the regex or of a
# group/alternative becomes `([ ?"]|$)` (in a log line the target is followed by a space,
# its path by `?`). Bracket expressions and escapes are copied verbatim.
nftban_botscan_prefilter_relax() {
    local p="$1" out="" c nx i len=${#1} inb=0 bpos=0
    for (( i=0; i<len; i++ )); do
        c="${p:i:1}"
        if (( inb )); then
            out+="$c"
            # a ']' right after '[' or '[^' is a literal member, not the end
            if [[ "$c" == "]" ]] && (( i > bpos )); then inb=0; fi
            continue
        fi
        case "$c" in
            \\) out+="$c"; (( i + 1 < len )) && { i=$(( i + 1 )); out+="${p:i:1}"; } ;;
            "[")  out+="$c"; inb=1; bpos=$(( i + 1 ))
                  [[ "${p:i+1:1}" == "^" ]] && { i=$(( i + 1 )); out+="^"; bpos=$(( i + 1 )); } ;;
            "^")  if [[ -z "$out" || "${out: -1}" == "(" || "${out: -1}" == "|" ]]; then :; else out+="$c"; fi ;;
            "\$") nx="${p:i+1:1}"
                  if [[ -z "$nx" || "$nx" == ")" || "$nx" == "|" ]]; then out+='([ ?"]|$)'; else out+="$c"; fi ;;
            *)    out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

# v1.187 Lane A — build a C-speed candidate prefilter (ERE) from the ENABLED patterns
# plus a 404-status keeper, into file $1. A line is a CANDIDATE if it could match ANY
# enabled pattern OR (when 404-tracking is on) carries a 404 status. The filter is a
# SOUND SUPERSET of the accurate bash matcher: patterns are emitted as ERE (same engine
# semantics as the matcher's `[[ =~ ]]`) with line-anchors (^ $) stripped so a URL/UA-
# anchored pattern still matches its field anywhere inside the WHOLE log line (broadening
# only). GNU grep -E is DFA-based → linear time, so this cannot ReDoS-stall (the bash
# regex matcher then runs only on the surviving candidates). Returns non-zero (→ caller
# skips the prefilter, no behavior change) when there is nothing to filter on.
nftban_botscan_build_prefilter() {
    local out="$1"
    : > "$out" 2>/dev/null || return 1
    local n=0 name def pat mt
    for name in "${!_BOTSCAN_PATTERNS[@]}"; do
        def="${_BOTSCAN_PATTERNS[$name]}"
        IFS="$_BS_US" read -r pat mt _ _ _ _ <<< "$def"  # v1.214.0 '|'-safe internal split → intact regex to Go matcher
        [[ -z "$pat" ]] && continue
        case "$mt" in
            # v1.234.0 — path-*/distinct-* regexes carry route boundaries INSIDE groups
            # (`(\?|$)`, `(^|/)`). Stripping only the outer anchors would leave an inner `$`
            # that can never match inside a whole log line (the target is followed by a
            # space), and the prefilter would silently DROP real candidates. Relax every
            # anchor so the prefilter stays a sound superset.
            path-*|distinct-*) pat="$(nftban_botscan_prefilter_relax "$pat")" ;;
            useragent)
                # v1.234.0 — an ANCHORED UA rule is anchored to the UA FIELD, which in a log
                # line is the last quoted field: `^-$` -> `"-"$`. Stripping the anchors made it
                # bare `-`, which is in every common-log line, so the prefilter kept EVERY line
                # on every host (BUG-BOTSCAN-PREFILTER-KEEPS-EVERY-LINE-EMPTY-UA-ANCHOR-STRIP).
                local _ua_l="" _ua_r=""
                [[ "$pat" == ^* ]] && { pat="${pat#^}"; _ua_l='"'; }
                [[ "$pat" == *\$ && "$pat" != *\\\$ ]] && { pat="${pat%\$}"; _ua_r='"$'; }
                pat="${_ua_l}${pat}${_ua_r}" ;;
            *) pat="${pat#^}"; pat="${pat%\$}" ;;   # strip line-anchors → match the field within the line
        esac
        [[ -z "$pat" ]] && continue
        printf '%s\n' "$pat" >> "$out"
        n=$((n + 1))
    done
    # v1.234.0 — keep lines WITHOUT a trailing quoted User-Agent field (common log format,
    # truncated or malformed): they must reach the parser so they are COUNTED and reported
    # (BOTSCAN_PARSE ua_unparsed=N) instead of vanishing in the prefilter. On a host that logs
    # in common format this keeps every line — the prefilter cannot help there, and the
    # report says why.
    printf '%s\n' '[^"]$' >> "$out"
    n=$((n + 1))
    if [[ "${BOTSCAN_404_TRACKING:-true}" == "true" ]]; then
        # Keep every 404-status line (common/combined format: "...REQUEST..." 404 <bytes>),
        # independent of patterns, so the 404-flood path never loses candidates.
        printf '%s\n' '" 404 ' >> "$out"
        printf '%s\n' ' 404 ' >> "$out"
        n=$((n + 1))
    fi
    [[ "$n" -gt 0 ]]
}

# v1.187 Lane A / v1.187.1 — 404-window OPTION 1 (fixed-tail re-read), INDEPENDENT of the
# forward processor cursor (does NOT read/advance its offset). Re-reads a bounded tail of
# each file, prefilters to 404 lines (C-speed), counts per-IP 404s into analyze()'s arrays.
# v1.187.1 BOUNDS this stage (v1.187.0 A4 was unbounded → srv2 126-log/131MB cycle blew past
# TimeoutStartSec=300; `V1_187_1_BOTSCAN_404_TAIL_BOUND_HOTFIX_SCOPE.md`):
#   (1) shares the cycle soft-deadline (start_secs + BOTSCAN_SCAN_BUDGET_SECS) — checked
#       BETWEEN files, breaks cleanly (always processing ≥1 file so 404 coverage + rotation
#       make forward progress even when the main loop consumed most of the budget);
#   (2) a per-cycle total-bytes backstop (BOTSCAN_404_TAIL_TOTAL_BYTES) for budget=0 runs;
#   (3) an anti-starvation rotation cursor (404-rotate, separate from the main scan-rotate)
#       so every file's 404 tail is covered across successive cycles.
# 404-flood detection is preserved: each scanned file's full tail is counted; rotation +
# the (steady-state) freed budget cover the rest across cycles. Honors the whitelists.
# Args: <start_secs> <budget_secs> -- <file>...
nftban_botscan_count_404_tail() {
    # Runs if EITHER 404-flood OR endpoint-flood is on (both ride this proven tail re-read).
    local _bs_404_on="${BOTSCAN_404_TRACKING:-true}"
    local _bs_ef_on="${BOTSCAN_ENDPOINT_FLOOD_ENABLED:-true}"
    [[ "$_bs_404_on" == "true" || "$_bs_ef_on" == "true" ]] || return 0
    local start_secs="${1:-$SECONDS}" budget="${2:-0}"; shift 2
    local now; now=$(nftban_timestamp_unix 2>/dev/null || date +%s)
    local tail_bytes="${BOTSCAN_404_TAIL_BYTES:-2097152}"
    local max_total="${BOTSCAN_404_TAIL_TOTAL_BYTES:-33554432}"
    # Reset so the count reflects ONLY this cycle's scanned tails.
    _BOTSCAN_IP_404_COUNT=()
    _BOTSCAN_IP_404_FIRST_SEEN=()
    _BOTSCAN_IP_404_LAST_SEEN=()
    # v1.234.0 — every counted event is placed by its REQUEST time. A line counts toward a
    # rule only if  0 <= now - request_ts <= WINDOW  (both bounds inclusive). A future
    # time (even by 1 s) or an unreadable one is excluded and reported -- never "now".
    local _w404=$(( ${BOTSCAN_404_WINDOW:-300} )) _wef=$(( ${BOTSCAN_ENDPOINT_FLOOD_WINDOW:-60} ))
    local _t_old=0 _t_bad=0 _t_future=0 _t_counted=0
    # BOTSCAN-ENDPOINT-FLOOD — reset cycle-scoped counts + (re)parse the endpoint token list,
    # and widen the C-speed tail grep so endpoint POST lines (any status) survive alongside
    # 404 lines. Without widening, a POST /xmlrpc.php 200 would be filtered out before counting.
    _BOTSCAN_IP_ENDPOINT_COUNT=()
    _BOTSCAN_IP_ENDPOINT_FIRST_SEEN=()
    _BOTSCAN_IP_ENDPOINT_LAST_SEEN=()
    _BOTSCAN_ENDPOINT_FLOOD_LIST=()
    # IFS=' ' REQUIRED under strict IFS=$'\n\t' (else one space-joined token; v1.186.1 class).
    [[ "$_bs_ef_on" == "true" ]] && IFS=' ' read -ra _BOTSCAN_ENDPOINT_FLOOD_LIST <<< "${BOTSCAN_ENDPOINT_FLOOD_ENDPOINTS:-}"
    local _bs_tail_grep=""
    [[ "$_bs_404_on" == "true" ]] && _bs_tail_grep='" 404 | 404 '
    if [[ "$_bs_ef_on" == "true" ]]; then
        local _ept _eptok
        for _ept in "${_BOTSCAN_ENDPOINT_FLOOD_LIST[@]}"; do
            _eptok="${_ept//./\\.}"            # ERE-escape dots
            [[ -n "$_bs_tail_grep" ]] && _bs_tail_grep+="|"
            _bs_tail_grep+="$_eptok"
        done
    fi
    [[ -z "$_bs_tail_grep" ]] && return 0
    local files=("$@")
    local n=${#files[@]}
    [[ "$n" -eq 0 ]] && return 0
    # Anti-starvation rotation cursor (next cycle resumes where this one stopped).
    local rot_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/404-rotate" rot=0
    mkdir -p "${rot_file%/*}" 2>/dev/null || true
    [[ -r "$rot_file" ]] && IFS= read -r rot < "$rot_file" 2>/dev/null
    [[ "$rot" =~ ^[0-9]+$ ]] || rot=0
    rot=$(( rot % n ))
    local consumed=0 covered=0 i idx f line
    for (( i=0; i<n; i++ )); do
        # Shared cycle soft-deadline — but always cover ≥1 file (forward 404 progress + rotation).
        if [[ "$covered" -gt 0 && "$budget" -gt 0 && $(( SECONDS - start_secs )) -ge "$budget" ]]; then break; fi
        # Per-cycle total-bytes backstop (bounds budget=0 / interactive runs); ≥1 file always.
        if [[ "$covered" -gt 0 && "$max_total" -gt 0 && "$consumed" -ge "$max_total" ]]; then break; fi
        idx=$(( (rot + i) % n ))
        f="${files[$idx]}"
        covered=$(( covered + 1 ))
        [[ -f "$f" && -r "$f" ]] || continue
        consumed=$(( consumed + tail_bytes ))
        while IFS= read -r line; do
            nftban_botscan_parse_line_g "$line" || continue   # v1.187.1 no-fork
            nftban_botscan_is_whitelisted "$_BS_IP" "$_BS_UA" && continue
            # v1.234.0 — place the event in REQUEST time (fork-free); unreadable => excluded.
            if ! nftban_botscan_request_epoch "$line"; then _t_bad=$(( _t_bad + 1 )); continue; fi
            if (( _BS_REQ_TS > now )); then _t_future=$(( _t_future + 1 )); continue; fi
            # BOTSCAN-ENDPOINT-FLOOD: STATUS-INDEPENDENT POST volume to sensitive endpoints.
            # Fork-free (builtin == only); only POSTs enter the tiny endpoint loop.
            if [[ "$_bs_ef_on" == "true" && "$_BS_METHOD" == "$BOTSCAN_ENDPOINT_FLOOD_METHOD" ]]; then
                local _efep
                for _efep in "${_BOTSCAN_ENDPOINT_FLOOD_LIST[@]}"; do
                    if [[ "$_BS_URL" == *"$_efep"* ]]; then
                        (( _BS_REQ_TS >= now - _wef )) || break      # outside the endpoint window
                        local _efk="${_BS_IP}|${_efep}"
                        _BOTSCAN_IP_ENDPOINT_COUNT["$_efk"]=$(( ${_BOTSCAN_IP_ENDPOINT_COUNT[$_efk]:-0} + 1 ))
                        if [[ -z "${_BOTSCAN_IP_ENDPOINT_FIRST_SEEN[$_efk]:-}" ]] || (( _BS_REQ_TS < _BOTSCAN_IP_ENDPOINT_FIRST_SEEN[$_efk] )); then
                            _BOTSCAN_IP_ENDPOINT_FIRST_SEEN["$_efk"]="$_BS_REQ_TS"
                        fi
                        if [[ -z "${_BOTSCAN_IP_ENDPOINT_LAST_SEEN[$_efk]:-}" ]] || (( _BS_REQ_TS > _BOTSCAN_IP_ENDPOINT_LAST_SEEN[$_efk] )); then
                            _BOTSCAN_IP_ENDPOINT_LAST_SEEN["$_efk"]="$_BS_REQ_TS"
                        fi
                        break
                    fi
                done
            fi
            # 404 flood (status-specific)
            [[ "$_bs_404_on" == "true" && "$_BS_STATUS" == "404" ]] || continue
            nftban_botscan_is_path_whitelisted "$_BS_URL" && continue
            if (( _BS_REQ_TS < now - _w404 )); then _t_old=$(( _t_old + 1 )); continue; fi
            _t_counted=$(( _t_counted + 1 ))
            _BOTSCAN_IP_404_COUNT["$_BS_IP"]=$(( ${_BOTSCAN_IP_404_COUNT[$_BS_IP]:-0} + 1 ))
            if [[ -z "${_BOTSCAN_IP_404_FIRST_SEEN[$_BS_IP]:-}" ]] || (( _BS_REQ_TS < _BOTSCAN_IP_404_FIRST_SEEN[$_BS_IP] )); then
                _BOTSCAN_IP_404_FIRST_SEEN["$_BS_IP"]="$_BS_REQ_TS"
            fi
            if [[ -z "${_BOTSCAN_IP_404_LAST_SEEN[$_BS_IP]:-}" ]] || (( _BS_REQ_TS > _BOTSCAN_IP_404_LAST_SEEN[$_BS_IP] )); then
                _BOTSCAN_IP_404_LAST_SEEN["$_BS_IP"]="$_BS_REQ_TS"
            fi
        done < <( tail -c "$tail_bytes" -- "$f" 2>/dev/null | LC_ALL=C grep -E "$_bs_tail_grep" 2>/dev/null || true )
    done
    # Persist rotation: next cycle starts after the last file covered this cycle.
    printf '%s\n' "$(( (rot + covered) % n ))" > "${rot_file}.tmp" 2>/dev/null && mv -f "${rot_file}.tmp" "$rot_file" 2>/dev/null || true
    # v1.234.0 — make the request-time gate visible: excluded lines are REPORTED, not silent.
    _BOTSCAN_404_TIME_STATS="counted=${_t_counted} old=${_t_old} unreadable_time=${_t_bad} future=${_t_future} window=${_w404}s"
    _BS_T_TAIL_UNREADABLE=$_t_bad; _BS_T_TAIL_FUTURE=$_t_future
    [[ "${BOTSCAN_DEBUG:-false}" == "true" ]] && echo "[DEBUG] botscan-404 request-time gate: ${_BOTSCAN_404_TIME_STATS}" >&2
    return 0
}

# Write a batch signal to JSONL for Go daemon (Clock 2) consumption
# Args: ip, score, action, reasons...
# v1.191 8B (Amendment B / increment 3) — PURE request-class classifier. Maps the available
# request evidence (HTTP method, request path, response status, optional detector hint) to the
# LOCKED request_class taxonomy carried in batch_signals.jsonl. Pure: no side effects, no global
# reads/writes; echoes exactly ONE enum value and ALWAYS one of the eight valid classes (never
# an invalid string → stays aligned with the increment-2 Go guard NormalizedRequestClass()).
# Enforcement thresholds are deliberately NOT here — this only LABELS traffic; the daemon
# cache/guard decides allow/grey/ban in a later increment, and must NOT re-derive the class by
# text-grepping reasons.
#
# Ordering (CLEAR dynamic/scanner abuse wins over browser-like classes; browser-like admin/ajax
# and static/e-shop classes win over the crude ".php means abuse" heuristic; this increment NEVER
# classifies on request rate alone):
#   1. scanner       — exploit/webshell/probe path OR fake_bot_ua/scanner/webshell/exploit hint
#   2. dynamic_abuse — xmlrpc.php / wp-login.php / endpoint-flood (explicit abuse endpoints)
#   3. login_api     — explicit login/auth-API abuse marker (narrow; distinct from generic abuse)
#   4. admin_ajax    — admin-ajax.php / wp-json/wc-* / users/me?context=edit (browser/session)
#   5. dynamic_abuse — generic POST/dynamic .php|/api|/wp-json loop NOT matched above
#   6. static404     — GET/HEAD static asset with 404/410 (incl. retina/@2x/product variants)
#   7. eshop_fanout  — GET/HEAD static asset in WooCommerce/e-shop/gallery/product/media context
#   8. static        — GET/HEAD static asset, non-404, no e-shop context
#   9. mixed         — fallback for unknown / ambiguous / unsupported evidence
# Args: <method> <path> <status> [hint]
nftban_botscan_classify_request_class() {
    local m="${1:-}" path="${2:-}" status="${3:-}" hint="${4:-}"
    local p h noq q ext
    m="${m^^}"                 # method upper
    p="${path,,}"              # path lower
    h="${hint,,}"              # hint lower
    noq="${p%%\?*}"            # path without query
    q=""; [[ "$p" == *\?* ]] && q="${p#*\?}"
    ext="${noq##*.}"           # candidate extension (query already stripped)

    # ---- 1. scanner — exploit/webshell/probe paths or detector hint (highest priority) ----
    if [[ "$h" =~ (fake_bot_ua|scanner|webshell|exploit|probe) ]]; then echo "scanner"; return 0; fi
    if [[ "$noq" =~ (^|/)\.(env|git|aws|ssh)(/|\.|$) ]] \
       || [[ "$noq" =~ appsettings\.json ]] \
       || [[ "$noq" =~ wp-config\.php ]] \
       || [[ "$noq" =~ /vendor/phpunit/ ]] \
       || [[ "$noq" =~ eval-stdin\.php ]] \
       || [[ "$noq" =~ /(phpmyadmin|adminer)(/|$) ]] \
       || [[ "$noq" =~ /wp-admin/(setup-config|install)\.php ]] \
       || [[ "$noq" =~ /(cgi-bin|actuator|solr|boaform)/ ]] \
       || [[ "$noq" =~ shell\.php ]] \
       || [[ "$noq" =~ /wp-content/uploads/.*\.php ]]; then
        echo "scanner"; return 0
    fi

    # ---- 2. dynamic_abuse — explicit abuse endpoints (preserve endpoint-flood behavior) ----
    if [[ "$h" =~ (endpoint_flood|xmlrpc|wp-login|brute) ]] \
       || [[ "$noq" =~ /xmlrpc\.php ]] \
       || [[ "$noq" =~ /wp-login\.php ]]; then
        echo "dynamic_abuse"; return 0
    fi

    # ---- 3. login_api — narrow, explicit login/auth-API marker only ----
    if [[ "$h" =~ (login_api|auth_api) ]] \
       || [[ "$noq" =~ /(oauth|openid-connect)(/|$) ]]; then
        echo "login_api"; return 0
    fi

    # ---- 4. admin_ajax — legitimate browser/session admin/ajax (wins over crude .php=abuse) ----
    if [[ "$noq" =~ /wp-admin/admin-ajax\.php ]] \
       || [[ "$noq" =~ /wp-json/wc- ]] \
       || [[ "$noq" =~ /wp-json/wc/store/ ]] \
       || { [[ "$noq" =~ /wp-json/wp/v2/users/me ]] && [[ "$q" =~ context=edit ]]; } \
       || [[ "$noq" =~ /wp-admin/(index|edit|admin)\.php ]]; then
        echo "admin_ajax"; return 0
    fi

    # ---- 5. dynamic_abuse — generic dynamic POST/.php|/api loop NOT matched above ----
    if { [[ "$m" == POST || "$m" == PUT || "$m" == DELETE ]] && [[ "$noq" =~ \.php(/|$) ]]; } \
       || { [[ "$m" == POST || "$m" == PUT ]] && [[ "$noq" =~ ^/(api|wp-json)/ ]]; } \
       || [[ "$h" =~ (high_rate|php_loop|api_loop|dynamic_abuse) ]]; then
        echo "dynamic_abuse"; return 0
    fi

    # ---- 6/7/8. static family (GET/HEAD static asset by extension) ----
    local is_static=0
    case "$ext" in
        css|js|png|jpg|jpeg|webp|gif|svg|ico|woff|woff2|ttf|map|avif|eot|mp4|webm) is_static=1 ;;
    esac
    if [[ "$is_static" == 1 ]] && [[ "$m" == GET || "$m" == HEAD || -z "$m" ]]; then
        # 6. static404 — any static asset returning 404/410 (retina/@2x/product variants).
        #    Checked BEFORE e-shop fan-out so a missing retina/gallery asset never reads as abuse.
        if [[ "$status" == 404 || "$status" == 410 ]]; then echo "static404"; return 0; fi
        # 7. eshop_fanout — browser-like asset fan-out in e-shop/gallery/product/media context.
        if [[ "$noq" =~ (woocommerce|/wp-content/uploads/|/product|/product-category|/shop|/cart|/gallery|/media/|lightbox|lazy|thumbnail|/zoom|-[0-9]+x[0-9]+\.|@[0-9]x\.) ]] \
           || [[ "$q" =~ (ver=|[?\&]v=|cache) ]]; then
            echo "eshop_fanout"; return 0
        fi
        # 8. static — plain static asset, non-404, no e-shop context.
        echo "static"; return 0
    fi

    # ---- 9. mixed — unknown / ambiguous / unsupported evidence ----
    echo "mixed"
}

nftban_botscan_write_signal() {
    local ip="$1"
    local score="$2"
    local action="$3"
    shift 3
    local reasons=("$@")

    # v1.219.0 truth-fix: count every emitted batch signal for signals_emitted_total.
    # v1.231.0 P0-B: every caller of this function runs inside the analyze fork, so the
    # variable below NEVER reaches the parent. The sink is the authority; the variable is
    # kept only so an in-fork reader still sees a consistent value.
    _BOTSCAN_SIGNALS_EMITTED=$(( ${_BOTSCAN_SIGNALS_EMITTED:-0} + 1 ))
    nftban_botscan_counter_add signals_emitted 1 || true

    local signal_file="${BOTSCAN_BATCH_SIGNAL_FILE:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/botguard/batch_signals.jsonl}"

    # Build JSON reasons array
    local reasons_json="["
    local first=true
    for r in "${reasons[@]}"; do
        if [[ "$first" == "true" ]]; then
            reasons_json+="\"${r//\"/\\\"}\""
            first=false
        else
            reasons_json+=",\"${r//\"/\\\"}\""
        fi
    done
    reasons_json+="]"

    local ts
    ts=$(date +%s)

    # v1.191 8B (Amendment B): additive structured fields. family derived from the IP;
    # request_class from the optional BOTSCAN_SIGNAL_REQUEST_CLASS the caller/classifier
    # sets (default "mixed" until the increment-3 request-class classifier populates it);
    # confidence optional via BOTSCAN_SIGNAL_CONFIDENCE. Old consumers ignore the new keys;
    # the Go reader uses the structured fields (never a grep of reasons).
    local family="ipv4"; [[ "$ip" == *:* ]] && family="ipv6"
    local request_class="${BOTSCAN_SIGNAL_REQUEST_CLASS:-mixed}"
    local conf_json=""
    if [[ -n "${BOTSCAN_SIGNAL_CONFIDENCE:-}" && "${BOTSCAN_SIGNAL_CONFIDENCE}" =~ ^[0-9]+$ ]]; then
        conf_json=",\"confidence\":${BOTSCAN_SIGNAL_CONFIDENCE}"
    fi
    # v1.234.0 — carry the rule's REQUESTED ban duration (the caller sets
    # BOTSCAN_SIGNAL_REQUESTED_TTL). Informational: the daemon keeps its established
    # grey/ban mapping and logs/records requested beside effective.
    if [[ -n "${BOTSCAN_SIGNAL_REQUESTED_TTL:-}" && "${BOTSCAN_SIGNAL_REQUESTED_TTL}" =~ ^[0-9]+$ && "${BOTSCAN_SIGNAL_REQUESTED_TTL}" -gt 0 ]]; then
        conf_json+=",\"requested_ttl_sec\":${BOTSCAN_SIGNAL_REQUESTED_TTL}"
    fi

    # v1.212 (OPEN_BOTSCAN_LOST_BAN_SIGNAL) — build the JSONL line once, then append it under a
    # SHARED flock so the Go consumer's atomic rename-then-consume hand-off can never destroy a
    # signal written in the read->hand-off window. The daemon takes this SAME lock only around its
    # O(1) rename of the signal file, so an append and the rename are mutually exclusive. The lock
    # is a STABLE sibling lockfile that is never renamed. Degrade SAFELY when flock is unavailable:
    # still append (O_APPEND keeps the single write line-atomic; the daemon rename stays the primary
    # guard) — NEVER silently drop the signal; a write failure is surfaced (return 1).
    local signal_line
    printf -v signal_line '{"ip":"%s","score":%d,"reasons":%s,"action":"%s","ts":%d,"family":"%s","request_class":"%s"%s}\n' \
        "${ip//\"/\\\"}" "$score" "$reasons_json" "${action//\"/\\\"}" "$ts" \
        "$family" "${request_class//\"/\\\"}" "$conf_json"

    local lock_file="${signal_file}.lock"
    if command -v flock >/dev/null 2>&1; then
        # Serialize concurrent write_signal callers AND cooperate with the daemon rename. `-w 5`
        # waits briefly rather than dropping the signal; on timeout / unopenable lockfile the
        # subshell exits non-zero and we fall through to a safe unlocked append (never a drop).
        if (
            flock -w 5 9 || exit 9
            printf '%s' "$signal_line" >> "$signal_file"
        ) 9>"$lock_file" 2>/dev/null; then
            return 0
        fi
    fi

    # flock binary absent, lockfile unopenable, or lock timed out → safe unlocked append. A real
    # write failure (disk full / perms) is made visible instead of silently lost.
    if ! printf '%s' "$signal_line" >> "$signal_file"; then
        echo "[ERROR] botscan: failed to write batch signal for ${ip}" >&2
        return 1
    fi
    return 0
}

# =============================================================================
# v1.234.0 — SHARED CDN EDGES (BUG-BOTSCAN-BANS-CDN-EDGE-IPS-WHEN-WEB-LOG-RECORDS-PROXY-ADDRESS)
# =============================================================================
# Measured on a production host: nginx behind Cloudflare without real-IP restoration logs
# the Cloudflare EDGE as the client, and BotScan banned 48 edges for 24 h — every visitor
# routed through them was dropped. An address inside a published CDN edge / platform
# egress range is a SHARED proxy identity: BotScan never bans it. This is a guard in the
# ENFORCEMENT path only (every ban BotScan emits passes nftban_botscan_shared_edge_guard;
# the daemon refuses the same ranges again at apply time). Nothing is whitelisted or
# accepted by the firewall, and no other detector is affected.
# Behind a CDN, a firewall ban is in any case not a block: proxied requests arrive from
# the edge, so banning the visitor's address would not stop them, and banning the edge
# blocks everyone. The remedy is real-IP restoration in the web server; the skip line says so.
# Sources (merged, admission-checked: v4 prefix >= /8, v6 >= /16):
#   1. the packaged snapshot ${NFTBAN_LIB_DIR}/data/botscan_shared_edges.tsv (always present,
#      works offline; refreshed per release from the provider's published list);
#   2. a newer published list fetched by `nftban trust` (read-only use of its cache;
#      optional; BotScan never depends on that path working).
declare -ga _BS_EDGE4_NET=() _BS_EDGE4_MASK=() _BS_EDGE4_LABEL=() _BS_EDGE6_G=() _BS_EDGE6_LEN=() _BS_EDGE6_LABEL=()
declare -g  _BS_EDGE_LOADED="" _BS_EDGE_MATCH="" _BS_EDGE_SOURCES=""
declare -gi _BS_EDGE_REJECTED=0

# _bs_v4_int A.B.C.D -> sets _BS_V4 (integer); rc1 if malformed
_bs_v4_int() {
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]})) c=$((10#${BASH_REMATCH[3]})) d=$((10#${BASH_REMATCH[4]}))
    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
    _BS_V4=$(( (a << 24) | (b << 16) | (c << 8) | d ))
    return 0
}
# _bs_v6_groups ADDR -> sets _BS_V6 to 8 space-separated decimal groups; rc1 if malformed
_bs_v6_groups() {
    local a="${1,,}" head tail i n
    [[ "$a" =~ ^[0-9a-f:]+$ && "$a" == *:* ]] || return 1
    local -a H=() T=() G=()
    if [[ "$a" == *::* ]]; then
        head="${a%%::*}"; tail="${a#*::}"
        [[ "$tail" == *::* ]] && return 1
        [[ -n "$head" ]] && IFS=':' read -ra H <<< "$head"
        [[ -n "$tail" ]] && IFS=':' read -ra T <<< "$tail"
        n=$(( 8 - ${#H[@]} - ${#T[@]} )); (( n >= 1 )) || return 1
        G=("${H[@]}"); for (( i=0; i<n; i++ )); do G+=(0); done; G+=("${T[@]}")
    else
        IFS=':' read -ra G <<< "$a"
    fi
    (( ${#G[@]} == 8 )) || return 1
    _BS_V6=""
    for i in "${G[@]}"; do
        [[ "$i" =~ ^[0-9a-f]{1,4}$ ]] || return 1
        _BS_V6+="$((16#$i)) "
    done
    _BS_V6="${_BS_V6% }"
    return 0
}
# _bs_edge_admit LABEL CIDR -> appends to the range arrays; counts rejects
_bs_edge_admit() {
    local label="$1" cidr="$2" net len
    net="${cidr%/*}"; len="${cidr##*/}"
    [[ "$cidr" == */* && "$len" =~ ^[0-9]{1,3}$ ]] || { _BS_EDGE_REJECTED=$(( _BS_EDGE_REJECTED + 1 )); return 0; }
    len=$((10#$len))
    if [[ "$net" == *.* ]] && _bs_v4_int "$net" && (( len >= 8 && len <= 32 )); then
        local mask=$(( (0xFFFFFFFF << (32 - len)) & 0xFFFFFFFF ))
        _BS_EDGE4_NET+=( $(( _BS_V4 & mask )) ); _BS_EDGE4_MASK+=( "$mask" ); _BS_EDGE4_LABEL+=( "$label $cidr" )
    elif [[ "$net" == *:* ]] && _bs_v6_groups "$net" && (( len >= 16 && len <= 128 )); then
        _BS_EDGE6_G+=( "$_BS_V6" ); _BS_EDGE6_LEN+=( "$len" ); _BS_EDGE6_LABEL+=( "$label $cidr" )
    else
        _BS_EDGE_REJECTED=$(( _BS_EDGE_REJECTED + 1 ))
    fi
    return 0
}
# nftban_botscan_load_shared_edges — load once per process (idempotent).
nftban_botscan_load_shared_edges() {
    [[ -n "$_BS_EDGE_LOADED" ]] && return 0
    _BS_EDGE_LOADED=1
    _BS_EDGE4_NET=(); _BS_EDGE4_MASK=(); _BS_EDGE4_LABEL=(); _BS_EDGE6_G=(); _BS_EDGE6_LEN=(); _BS_EDGE6_LABEL=()
    _BS_EDGE_REJECTED=0; _BS_EDGE_SOURCES=""
    local snap="${BOTSCAN_SHARED_EDGE_FILE-${NFTBAN_LIB_DIR:-/usr/lib/nftban}/data/botscan_shared_edges.tsv}"
    local prov list cidr l
    if [[ -n "$snap" && -r "$snap" ]]; then
        while IFS=$'\t' read -r prov list cidr; do
            [[ -z "$prov" || "$prov" == \#* ]] && continue
            _bs_edge_admit "${prov} ${list}" "$cidr"
        done < "$snap"
        _BS_EDGE_SOURCES+="snapshot:${snap} "
    fi
    local tdir="${BOTSCAN_TRUST_CACHE_DIR-/var/cache/nftban/trust}" f p fam
    if [[ -n "$tdir" && -d "$tdir" ]]; then
        for p in cloudflare fastly quiccloud; do
            for fam in ipv4 ipv6; do
                f="$tdir/${p}-${fam}.txt"
                [[ -r "$f" ]] || continue
                while IFS= read -r l || [[ -n "$l" ]]; do
                    l="${l%%#*}"; l="${l//[[:space:]]/}"
                    [[ -n "$l" ]] && _bs_edge_admit "${p} trust-cache-${fam}" "$l"
                done < "$f"
                _BS_EDGE_SOURCES+="trust-cache:${f} "
            done
        done
    fi
    return 0
}
# nftban_botscan_shared_edge IP -> rc0 and _BS_EDGE_MATCH="<provider> <list> <cidr>" if IP is
# inside a shared-edge range (IPv4-mapped IPv6 is checked as IPv4).
nftban_botscan_shared_edge() {
    local ip="${1#[}"; ip="${ip%]}"; local i
    _BS_EDGE_MATCH=""
    nftban_botscan_load_shared_edges
    [[ "${ip,,}" == ::ffff:*.* ]] && ip="${ip##*:}"
    if [[ "$ip" == *.* ]]; then
        _bs_v4_int "$ip" || return 1
        for (( i=0; i<${#_BS_EDGE4_NET[@]}; i++ )); do
            if (( (_BS_V4 & _BS_EDGE4_MASK[i]) == _BS_EDGE4_NET[i] )); then _BS_EDGE_MATCH="${_BS_EDGE4_LABEL[i]}"; return 0; fi
        done
        return 1
    fi
    _bs_v6_groups "$ip" || return 1
    local -a A=() N=()
    IFS=' ' read -ra A <<< "$_BS_V6"
    local len full rem k ok
    for (( i=0; i<${#_BS_EDGE6_G[@]}; i++ )); do
        IFS=' ' read -ra N <<< "${_BS_EDGE6_G[i]}"
        len="${_BS_EDGE6_LEN[i]}"; full=$(( len / 16 )); rem=$(( len % 16 )); ok=1
        for (( k=0; k<full; k++ )); do (( A[k] == N[k] )) || { ok=0; break; }; done
        if (( ok && rem > 0 )); then
            local m=$(( (0xFFFF << (16 - rem)) & 0xFFFF ))
            (( (A[full] & m) == (N[full] & m) )) || ok=0
        fi
        if (( ok )); then _BS_EDGE_MATCH="${_BS_EDGE6_LABEL[i]}"; return 0; fi
    done
    return 1
}
# nftban_botscan_shared_edge_guard IP SOURCE REASON -> rc0 = SKIPPED (caller must not ban);
# rc1 = not a shared edge (proceed). Writes the visible reason to botscan.log
# (SKIPPED_SHARED_EDGE) and counts it on the cycle's counter sink.
nftban_botscan_shared_edge_guard() {
    local ip="$1" source="$2" reason="$3"
    nftban_botscan_shared_edge "$ip" || return 1
    local why="skipped: address is a shared CDN edge (${_BS_EDGE_MATCH}); the web log records the proxy, not the client; configure real-IP restoration in the web server"
    if [[ "${BOTSCAN_ACTION_MODE:-}" == "alert" ]]; then
        echo "[ALERT] Would NOT ban $ip — ${why} (${reason})"
    fi
    echo "$(date -Iseconds)|$source|$ip|0|SKIPPED_SHARED_EDGE|${why} — ${reason}" >> "${BOTSCAN_LOG_FILE:-/dev/null}" 2>/dev/null || true
    nftban_botscan_counter_add shared_edge_skipped 1 || true
    return 0
}

# Ban IP
nftban_botscan_ban_ip() {
    local ip="$1"
    local duration="$2"
    local source="$3"
    local reason="$4"

    # v1.234.0 — never ban a shared CDN edge (pattern and 404-flood paths; all modes).
    nftban_botscan_shared_edge_guard "$ip" "$source" "$reason" && return 0

    [[ "$BOTSCAN_ACTION_MODE" == "alert" ]] && {
        echo "[ALERT] Would ban $ip for ${duration}s: $reason"
        return 0
    }

    # Clock 3 batch signal mode: write JSONL for Go daemon instead of direct ban
    if [[ "${BOTSCAN_BATCH_SIGNAL_MODE:-false}" == "true" ]]; then
        local score=80
        local action="ban"
        # Shorter bans → grey instead of ban
        if [[ "$duration" -le 1800 ]]; then
            score=50
            action="grey"
        fi
        BOTSCAN_SIGNAL_REQUESTED_TTL="$duration" nftban_botscan_write_signal "$ip" "$score" "$action" "$source" "$reason"
        echo "$(date -Iseconds)|$source|$ip|${duration}|SIGNAL|$reason" >> "$BOTSCAN_LOG_FILE"
        return 0
    fi

    # Direct ban mode (legacy/standalone)
    if type -t nftban_ban &>/dev/null; then
        nftban_ban "$ip" "$duration" "$source" "$reason"
    elif [[ -x "${NFTBAN_BIN:-/usr/sbin/nftban}" ]]; then
        "${NFTBAN_BIN:-/usr/sbin/nftban}" ban "$ip" --timeout "$duration" --source "$source" --reason "$reason" 2>/dev/null
    else
        echo "[ERROR] Cannot ban $ip - nftban not available" >&2
        return 1
    fi

    # Log
    echo "$(date -Iseconds)|$source|$ip|${duration}|BANNED|$reason" >> "$BOTSCAN_LOG_FILE"

    return 0
}

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================

# Process logs (main entry point)
# =============================================================================
# v1.232 — CURSOR OFFSET READBACK (completion-priority input)
# =============================================================================
# Mirrors the READER's cursor identity exactly. ⛔ Deriving a second, independent
# path-based identity here is precisely how the v1.209.3 relocation orphaned the
# cursor set fleet-wide; this calls nftban_http_cursor_key with the SAME namespace
# the reader uses for the same subject, and never pattern-matches a neighbour.
_nftban_botscan_cursor_offset() {
    local f="$1" ns="" key sf v
    [[ "$f" == "${BOTSCAN_SPOOL_DIR:-/var/lib/nftban/botscan/spool}"/* ]] \
        && ns="${BOTSCAN_SPOOL_CURSOR_NS:-_botscan_spool_}"
    if declare -F nftban_http_cursor_key >/dev/null 2>&1; then
        key="$(NFTBAN_HTTP_CURSOR_NS="$ns" nftban_http_cursor_key "$f")"
    else
        printf '0'; return 0
    fi
    sf="${NFTBAN_HTTP_LOG_OFFSET_DIR:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/proc-offsets}/${key}"
    [[ -r "$sf" ]] || { printf '0'; return 0; }
    IFS= read -r v < "$sf" 2>/dev/null || v=""
    v="${v#*:}"
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
    printf '%s' "$v"
}

nftban_botscan_process_logs() {
    local log_file="${1:-}"
    # $2 (legacy "time_window") is accepted and ignored: every window is the matched
    # pattern's own, evaluated in request time (v1.234.0).

    [[ "$BOTSCAN_ENABLED" != "true" ]] && {
        echo "Bot scanner is disabled"
        # v1.207 recording-discipline: a disabled module records DISABLED_BY_CONFIG
        # ONLY if it has a prior meaningful run-state; a disabled+never-run module
        # writes NOTHING (no counters/noise, and never a fake "0 clean").
        if declare -F nftban_botscan_record_runstate >/dev/null 2>&1; then
            nftban_botscan_record_runstate ts="$(date +%s)" health_state="DISABLED_BY_CONFIG" disabled_reason="BOTSCAN_ENABLED!=true"
        fi
        return 0
    }

    # v1.177: discover ALL panel-aware access logs (multi-log), not just the first.
    # An explicit single arg still pins one file (back-compat / tests).
    local -a logs=()
    local f
    if [[ -n "$log_file" ]]; then
        logs+=("$log_file")
    else
        while IFS= read -r f; do [[ -n "$f" ]] && logs+=("$f"); done < <(nftban_botscan_discover_logs)
        if [[ ${#logs[@]} -eq 0 ]]; then
            echo "ERROR: No access log found" >&2
            echo "  Hint: run 'nftban botscan logs --detect' to see candidate paths and panel detection." >&2
            echo "  Or set BOTSCAN_LOG_PATHS in /etc/nftban/conf.d/botscan/main.conf to your access-log glob(s)." >&2
            # v1.208 — enabled but no web access logs discovered (common on non-web hosts).
            # Record NO_INPUT_DISCOVERED (informational, NOT clean, NOT a failure) instead of
            # leaving a perpetual NO_RUN_YET / absent run-state.
            if declare -F nftban_botscan_record_runstate >/dev/null 2>&1; then
                nftban_botscan_record_runstate ts="$(date +%s)" health_state="NO_INPUT_DISCOVERED" \
                    pressure_state="NORMAL" scan_mode="NONE" backlog_state="STABLE" \
                    disabled_reason="no access logs discovered on this host"
            fi
            return 1
        fi
    fi

    # Initialize
    nftban_botscan_init_state
    nftban_botscan_load_patterns

    echo "Processing: ${#logs[@]} access log(s)"
    echo "Patterns loaded: ${#_BOTSCAN_PATTERNS[@]}"

    # v1.207 SMART-ADAPTIVE controller — derive pressure + scan_mode from EXISTING
    # signals (watchdog trend + /proc/loadavg + forward-cursor backlog) and modulate
    # the EXISTING per-file cap. REUSE only; no new collectors; no schema change.
    local _BS_PRESSURE="NORMAL" _BS_BACKLOG="STABLE" _BS_MODE="FULL" _BS_BYTES=0
    if declare -F nftban_botscan_select_mode >/dev/null 2>&1; then
        local _lr _l5 _mem _io _behind _rr=0 _bh=0 _prev=0
        _lr=$(nftban_botscan_load_ratio)
        IFS=' ' read -r _l5 _mem _io < <(nftban_botscan_watchdog_pressure)
        IFS=' ' read -r _BS_BYTES _behind < <(nftban_botscan_backlog "${logs[@]}")
        if [[ -f "${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/runstate.json" ]] && command -v jq &>/dev/null; then
            local _ld; IFS=' ' read -r _ld _bh _prev < <(jq -r '"\(.last_duration_sec//0) \(.last_budget_hit//0) \(.backlog_bytes//0)"' "${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/runstate.json" 2>/dev/null)
            local _bud="${BOTSCAN_SCAN_BUDGET_SECS:-180}"; [[ "$_bud" -ge 1 ]] || _bud=180
            _rr=$(awk -v d="${_ld:-0}" -v b="$_bud" 'BEGIN{printf "%.2f",(b>0?d/b:0)}')
        fi
        _BS_PRESSURE=$(nftban_botscan_pressure_state "$_lr" "$_rr" "${_bh:-0}" "${_mem:-0}" "${_io:-0}")
        _BS_BACKLOG=$(nftban_botscan_backlog_state "${_BS_BYTES:-0}" "${_prev:-0}")
        _BS_MODE=$(nftban_botscan_select_mode "$_BS_PRESSURE" "$_BS_BACKLOG")
        case "$_BS_MODE" in
            FAIR_SHARE) export BOTSCAN_SCAN_MAX_BYTES_PER_FILE=$(( ${BOTSCAN_SCAN_MAX_BYTES_PER_FILE:-262144} / 2 )) ;;
            SURVIVAL)   export BOTSCAN_SCAN_MAX_BYTES_PER_FILE=$(( ${BOTSCAN_SCAN_MAX_BYTES_PER_FILE:-262144} / 4 )); export BOTSCAN_SCAN_PREFILTER=true ;;
        esac
        echo "Adaptive: pressure=$_BS_PRESSURE backlog=$_BS_BACKLOG mode=$_BS_MODE (load_ratio=$_lr)"
    fi

    # v1.185 CORE-BOTSCAN-PROCESSOR-TIMEOUT-AT-SCALE — DEADLINE-AWARE SELF-BOUND.
    # Fleet-proven failure: on high-ENTRY-VOLUME hosts (srv2 120 logs 0/53, srv4 17 logs
    # 0/46, dns2 5 logs 0/55 — VOLUME, not file count) one cycle's burst × 137-pattern
    # matching can't finish before the systemd TimeoutStartSec SIGTERM, so analyze/ban
    # (below) never runs and BotScan bans nothing. Fix = bound the WORK per cycle so the
    # scan finishes and BANS cleanly before the kill, and resumes next cycle:
    #   (1) per-file read cap (NFTBAN_HTTP_LOG_MAX_BYTES, scoped here to the botscan scan)
    #       so each WHOLE file's chunk is bounded and always fully processed in this cycle
    #       — the cursor's offset then correctly reflects processed bytes (no within-file
    #       break, which would strand emitted-but-unconsumed bytes since the shared reader
    #       commits offset=size on READ);
    #   (2) a SOFT time budget (BOTSCAN_SCAN_BUDGET_SECS; 0 = unlimited for interactive
    #       `botscan check`) checked BETWEEN files — stop cleanly at a file boundary;
    #   (3) anti-starvation rotation so every file is scanned across successive cycles.
    # KNOWN LIMITATION (follow-up, NOT v1.185 — touches the shared reader, out of locked
    # scope): under sustained traffic exceeding the per-file cap each cycle the shared
    # reader is tail-biased (processes newest, advances offset to size), so the oldest
    # over-cap bytes of that cycle are not scanned. v1.185 fixes the never-completes/
    # never-bans class; full zero-loss is a separate shared-reader lane.
    local budget="${BOTSCAN_SCAN_BUDGET_SECS:-0}"
    local start_secs=$SECONDS
    local deadline_hit=0
    # Bound each file's per-cycle read so a single whole file is always processable inside a
    # budget slice. v1.187.1 lowered the default 1 MiB → 256 KiB (~1.3k lines) as a cheap
    # time backstop: combined with the no-fork parse/match path a 256 KiB slice processes in
    # well under a second, so no single file can push the cycle toward TimeoutStartSec even on
    # a 126-log/921 MB DA host. The rotation cursor still covers every file across cycles.
    # Scoped to this scan process only — the privileged collector keeps its own (larger) cap.
    # Only narrow it (never widen a caller-set smaller value).
    local _scan_cap="${BOTSCAN_SCAN_MAX_BYTES_PER_FILE:-262144}"
    if [[ -z "${NFTBAN_HTTP_LOG_MAX_BYTES:-}" || "${NFTBAN_HTTP_LOG_MAX_BYTES}" -gt "$_scan_cap" ]]; then
        export NFTBAN_HTTP_LOG_MAX_BYTES="$_scan_cap"
    fi
    # v1.187 Lane A — FORWARD cursor on a DEDICATED offset dir (distinct offset semantics,
    # and distinct from the collector's offsets) so the scanner drains a backlog FORWARD
    # across cycles instead of tail-skipping. Auto-discovered incremental path only (an
    # explicit pinned log_file / interactive `check` keeps the simple tail read).
    if [[ -z "$log_file" ]]; then
        export NFTBAN_HTTP_LOG_READ_FORWARD=true
        export NFTBAN_HTTP_LOG_OFFSET_DIR="${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/proc-offsets"
    fi
    # v1.187 Lane A — build the C-speed candidate prefilter once for this cycle.
    local _pf=""
    if [[ "${BOTSCAN_SCAN_PREFILTER:-true}" == "true" ]]; then
        _pf="$(mktemp 2>/dev/null)" || _pf=""
        [[ -n "$_pf" ]] && { nftban_botscan_build_prefilter "$_pf" || { rm -f "$_pf"; _pf=""; }; }
    fi
    # v1.209.1 — resolve the prefilter ENGINE once. The legacy `grep -E -f "$_pf"` is rejected
    # WHOLESALE by GNU grep (rc=2) when any pattern mis-splits on the '|' field delimiter (3 such
    # alternation patterns ship today) → with `2>/dev/null || true` the prefilter silently returns
    # EMPTY → process_entry never runs → pattern-based detection is dead. The bounded Go helper
    # skips those broken patterns visibly and runs the valid corpus. Selection is fail-SAFE: any
    # helper problem falls through to unfiltered pass-through (detection preserved), NEVER empty.
    local _bs_pf_bin=""
    if [[ -n "$_pf" ]]; then
        local _cand; _cand="$(command -v nftban-botscan-matcher 2>/dev/null)"
        [[ -z "$_cand" ]] && _cand="${NFTBAN_BIN_DIR:-/usr/lib/nftban/bin}/nftban-botscan-matcher"
        local _chk
        if [[ -x "$_cand" ]] && _chk="$("$_cand" --check "$_pf" 2>&1)"; then
            _bs_pf_bin="$_cand"
            # Visible once per cycle: usable/skipped counts (skipped = the |-delimiter-broken patterns).
            echo "[botscan] prefilter engine: Go matcher — ${_chk##*matcher: }" >&2
        else
            echo "[botscan] WARN: Go prefilter helper unavailable/invalid — unfiltered pass-through (detection preserved; slower). Install nftban-botscan-matcher." >&2
        fi
    fi
    # Anti-starvation rotation: persist where the last cycle stopped so a host whose
    # backlog exceeds one budget still scans EVERY file over successive cycles instead
    # of always draining the first files and starving the tail.
    local rot_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/scan-rotate"
    local n=${#logs[@]} rot=0
    if [[ -z "$log_file" && "$n" -gt 0 ]]; then
        mkdir -p "${rot_file%/*}" 2>/dev/null || true
        [[ -r "$rot_file" ]] && IFS= read -r rot < "$rot_file" 2>/dev/null
        [[ "$rot" =~ ^[0-9]+$ ]] || rot=0
        rot=$(( rot % n ))
    fi

    # =========================================================================
    # v1.232 INTER-CYCLE RESUME — hold the rotation on an unfinished object.
    # =========================================================================
    # ⛔ THE DEFECT THIS REPLACES. The first attempt at completion priority used a
    # BINARY predicate — "off > 0 && off < size" — to put in-progress objects first.
    # On a real backlog EVERY object is already in-progress, so the partition
    # separated nothing, plain rotation order applied, and after a deadline stop
    # `rot` advanced past the half-drained object, which then waited a FULL rotation
    # (~40 cycles on srv3) before being touched again. Per-object progress stayed
    # effectively round-robin: measured ~40 KiB/object/cycle against the published
    # artifact's ~39 KiB — the same to within noise, because throughput is
    # DEADLINE-bound, not read-pattern-bound. THE PREDICATE HAD NO DISCRIMINATORY
    # POWER IN EXACTLY THE STATE IT WAS WRITTEN FOR, and no lab fixture could expose
    # that because every fixture's objects finished inside one cycle.
    #
    # THE CONTRACT: if a cycle stops mid-object, PIN that object; the next cycle
    # resumes IT FIRST and keeps resuming it until EOF and retirement; only then does
    # rotation advance.
    #
    # ⛔ TWO CONSTRAINTS, both load-bearing:
    #   (1) A PIN MUST NEVER BE PERMANENT. An object that becomes unreadable, is
    #       retired, is replaced (inode change), completes, or simply refuses to
    #       finish must release the pin — otherwise one bad object deadlocks the
    #       whole queue and starves every other object, which is a worse failure
    #       than the one being fixed. Every escape below is explicit and logged.
    #   (2) THE PIN CHANGES ORDER, NEVER THE RESOURCE CEILING. The cycle deadline is
    #       untouched; a pinned object gets the same bounded budget any object gets.
    local _bs_pin_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/scan-pin"
    local _bs_pinned="" _bs_pin_tries=0
    if [[ -z "$log_file" && "$n" -gt 0 && -r "$_bs_pin_file" ]]; then
        IFS='|' read -r _bs_pinned _bs_pin_tries < "$_bs_pin_file" 2>/dev/null || true
        [[ "${_bs_pin_tries:-}" =~ ^[0-9]+$ ]] || _bs_pin_tries=0
    fi
    if [[ -n "$_bs_pinned" ]]; then
        local _bs_pp="" _bs_e _bs_drop=""
        for _bs_e in "${logs[@]}"; do
            [[ "$(basename "$_bs_e")" == "$_bs_pinned" ]] && { _bs_pp="$_bs_e"; break; }
        done
        if   [[ -z "$_bs_pp"    ]]; then _bs_drop="no longer in the scan set (retired or rotated out)"
        elif [[ ! -f "$_bs_pp"  ]]; then _bs_drop="not a regular file"
        elif [[ ! -r "$_bs_pp"  ]]; then _bs_drop="unreadable"
        elif (( _bs_pin_tries >= ${BOTSCAN_SCAN_PIN_MAX_CYCLES:-64} )); then
            _bs_drop="pin budget exhausted after ${_bs_pin_tries} cycles"
        else
            local _bs_po _bs_ps
            _bs_po="$(_nftban_botscan_cursor_offset "$_bs_pp")"
            _bs_ps="$(stat -c%s "$_bs_pp" 2>/dev/null || echo 0)"
            [[ "$_bs_po" =~ ^[0-9]+$ ]] || _bs_drop="cursor unreadable or conflicted"
            [[ -z "$_bs_drop" && "$_bs_po" -ge "$_bs_ps" ]] && _bs_drop="already complete"
        fi
        if [[ -n "$_bs_drop" ]]; then
            echo "[botscan] releasing pinned object ${_bs_pinned}: ${_bs_drop}"
            rm -f "$_bs_pin_file" 2>/dev/null || true
            _bs_pinned=""; _bs_pin_tries=0
        else
            # Pinned object first; every other object keeps its rotation order behind
            # it. A NEWLY ARRIVED object therefore cannot take priority from a pinned
            # one — it queues behind, exactly as an old object does.
            local -a _bs_ord=("$_bs_pp")
            for _bs_e in "${logs[@]}"; do [[ "$_bs_e" == "$_bs_pp" ]] || _bs_ord+=("$_bs_e"); done
            logs=("${_bs_ord[@]}")
            rot=0
        fi
    fi

    local processed=0 files_done=0 i idx f _bs_last_f=''
    local -a _bs_reap_after_tail=()
    for (( i=0; i<n; i++ )); do
        # Deadline check BETWEEN files only (clean boundary). A whole file is always read+
        # processed atomically so the cursor offset reflects exactly what was processed;
        # never break mid-file (that would strand emitted-but-unconsumed bytes).
        if [[ "$budget" -gt 0 && $(( SECONDS - start_secs )) -ge "$budget" ]]; then
            deadline_hit=1; break
        fi
        idx=$(( (rot + i) % n ))
        f="${logs[$idx]}"
        _bs_last_f="$f"
        # =====================================================================
        # v1.232 DEPTH-FIRST DRAIN — the root cause this release closes.
        # =====================================================================
        # ⛔ THE DEFECT. This loop used to perform EXACTLY ONE bounded read per
        # object per cycle and then move on, so an object of K chunks needed at
        # least K CYCLES to reach EOF — unconditionally. FALSIFIED on lab2 against
        # main eb909b4d: ONE object, ONE cycle, BOTSCAN_SCAN_BUDGET_SECS=0
        # (UNLIMITED) and nothing else in the spool still advanced the cursor by
        # EXACTLY ONE CAP (4096 of 41040 B). With the budget unlimited and the
        # object alone, the stop was STRUCTURAL, not a deadline. Consequence on
        # srv3: 47 objects x 1.09 GB never retired anything, so the spool never
        # fell and backpressure never cleared.
        #
        # ⛔ SURVIVAL AND ROTATION WERE AMPLIFIERS, NOT THE CAUSE. The falsifier
        # ran in mode=FULL covering 47/47 files with the budget never hit — the
        # most favourable conditions available — and STILL reached at_EOF=0 with
        # the spool unchanged. The SURVIVAL cap division and the rotation breadth
        # multiply K; they do not create it. Fixing either ALONE would have left
        # the one-chunk-per-cycle law intact.
        #
        # THE CONTRACT: keep reading the SAME object until it reaches EOF, then
        # let it retire, and only then advance. Bounded by the EXISTING cycle
        # deadline — never a second independent budget — and the reader persists
        # the cursor on every pass, so a mid-object stop leaves durable progress
        # and the next cycle resumes the SAME object rather than replaying it.
        local _bs_pass=0 _bs_chunk_lines _bs_rts
        while :; do
        _bs_chunk_lines=0
        while IFS= read -r line; do
            _bs_chunk_lines=$((_bs_chunk_lines + 1))
            nftban_botscan_parse_line_g "$line" || continue   # v1.187.1 no-fork (was $(parse_line))
            # v1.234.0 — the line's own REQUEST time; "" = unreadable (excluded, reported).
            _bs_rts=""; nftban_botscan_request_epoch "$line" && _bs_rts="$_BS_REQ_TS"
            nftban_botscan_process_entry "$_BS_IP" "$_BS_URL" "$_BS_METHOD" "$_BS_STATUS" "$_BS_UA" "$_bs_rts"
            processed=$((processed + 1))
        done < <(
            {
                if [[ -n "$log_file" ]]; then tail -1000 -- "$f" 2>/dev/null
                elif declare -F nftban_http_read_incremental >/dev/null 2>&1; then
                    # v1.229.10: when reading a SPOOL subject the reader must use the
                    # SAME canonical cursor identity the reaper uses. Two independent
                    # path-derived identities are exactly how the v1.209.3 relocation
                    # orphaned the cursor set fleet-wide.
                    #   ONE LOGICAL SPOOL SUBJECT -> ONE CANONICAL CURSOR IDENTITY
                    #   -> SAME IDENTITY USED BY READER AND REAPER.
                    if [[ "$f" == "${BOTSCAN_SPOOL_DIR:-/var/lib/nftban/botscan/spool}"/* ]]; then
                        NFTBAN_HTTP_CURSOR_NS="${BOTSCAN_SPOOL_CURSOR_NS:-_botscan_spool_}" \
                        NFTBAN_HTTP_CURSOR_LEGACY_DIRS="${BOTSCAN_SPOOL_CURSOR_LEGACY_DIRS:-/run/nftban/botscan /var/lib/nftban/botscan/spool}" \
                            nftban_http_read_incremental "$f"
                    else
                        nftban_http_read_incremental "$f"
                    fi
                else tail -1000 -- "$f" 2>/dev/null; fi
            } | { if [[ -n "$_bs_pf_bin" ]]; then "$_bs_pf_bin" --filter "$_pf" 2>/dev/null || cat; else cat; fi; }
        )
            _bs_pass=$(( _bs_pass + 1 ))
            # EOF: in FORWARD mode the reader emits nothing once the cursor has
            # reached the object's size. An empty pass is therefore "drained".
            (( _bs_chunk_lines == 0 )) && break
            # A PINNED single file uses a fixed `tail` read, not the incremental
            # cursor, so draining it would re-read the same tail forever.
            [[ -n "$log_file" ]] && break
            # Bounded by the EXISTING cycle deadline. Stopping here is SAFE: the
            # cursor was persisted by the reader on this pass.
            if [[ "$budget" -gt 0 && $(( SECONDS - start_secs )) -ge "$budget" ]]; then
                deadline_hit=1; break
            fi
        done
        files_done=$((files_done + 1))
        # v1.209.3: reap this spool file if it is now fully consumed, so the disk-backed
        # spool does not accumulate. SAFE: only the BATCH (processor) path runs this, it
        # holds the processor lock that the collector also takes (no append races the
        # delete), and the helper reaps ONLY files under the spool dir (never a real log).
        # BOTSCAN_SPOOL_REAP=false disables it (default on) — used by the cursor/rotation
        # unit tests that re-scan a STATIC spool across cycles, and an operator safety
        # valve (bounding then relies on the collector total-dir cap + backpressure).
        if [[ "${BOTSCAN_BATCH_SIGNAL_MODE:-}" == "true" && -z "$log_file" && "${BOTSCAN_SPOOL_REAP:-true}" == "true" ]]; then
            # ⛔ `|| true` IS LOAD-BEARING — DO NOT REMOVE IT AS REDUNDANT.
            # The reaper returns 1 for KEPT, which is a NORMAL outcome, not an
            # error: "ABSENT -> UNKNOWN completion -> KEEP", not-yet-at-EOF, a
            # symlink, or a cursor conflict all return 1 while behaving exactly
            # as intended. This file sets `set -Eeuo pipefail` at line 28, which
            # arms errexit in ANY shell that sources it, so an UNGUARDED call
            # aborted the whole scan cycle at the FIRST object that was merely
            # KEPT — the overwhelmingly common case on a backlogged host, where
            # almost nothing is complete yet.
            # MEASURED on lab2: reaper rc=1 for a not-completed object (file
            # correctly retained); the same call under `set -Eeuo pipefail`
            # terminated the enclosing shell before the next statement ran.
            # The sibling call site at :833 already avoids this by using
            # `if nftban_botscan_reap_consumed_spool ...; then`, and
            # botscan_spool_cursor_identity_v1229_10_test guards every call with
            # `|| true` for exactly this reason. This site was the outlier.
            # ⛔ REACHABILITY IS CALLER-DEPENDENT AND NOT YET PROVEN IN PRODUCTION:
            # a caller that invokes the scan via `if`/`||` disarms errexit and
            # would not abort. srv3 cycles reached 6-7 files, so it was NOT
            # aborting there. Fixed regardless — a normal outcome must never be
            # able to terminate the cycle, whatever the caller happens to do.
            # v1.234.0 (BUG-BOTSCAN-REAP-BEFORE-404-TAIL-BLINDS-DRAINED-SPOOL): the reap is
            # DEFERRED until nftban_botscan_count_404_tail has read this object. Reaping here
            # deleted a drained object before the 404/endpoint tail could see it, so on a
            # healthy host (every object drained each cycle) both flood detectors were blind.
            _bs_reap_after_tail+=("$f")
        fi
    done

    # v1.232 INTER-CYCLE RESUME — set or clear the pin for the next cycle.
    # Pin ONLY when the object we were on is still short of EOF; clearing on
    # completion is what lets rotation advance after a retirement.
    if [[ -z "$log_file" && -n "${_bs_last_f:-}" ]]; then
        local _bs_lo _bs_ls
        _bs_lo="$(_nftban_botscan_cursor_offset "$_bs_last_f")"
        _bs_ls="$(stat -c%s "$_bs_last_f" 2>/dev/null || echo 0)"
        if [[ -f "$_bs_last_f" && "$_bs_lo" =~ ^[0-9]+$ && "$_bs_lo" -lt "$_bs_ls" ]]; then
            # v1.235 (OPEN-BOTSCAN-SCAN-PIN-RETRY-BUDGET-IS-GLOBAL-NOT-PER-OBJECT): the attempt
            # budget is PER OBJECT. The same pinned object continues its count; a different
            # object starts at 1. Before, a new object inherited the previous object's count
            # (srv3: ...egialion-iqia.com.log|16 -> ...getsfinance.gr.log|17), so "pin budget
            # exhausted after N cycles" could name an object pinned for a single cycle.
            local _bs_next_tries=1
            [[ "$(basename "$_bs_last_f")" == "$_bs_pinned" ]] && _bs_next_tries=$(( _bs_pin_tries + 1 ))
            printf '%s|%s\n' "$(basename "$_bs_last_f")" "$_bs_next_tries" \
                > "${_bs_pin_file}.tmp" 2>/dev/null \
                && mv -f "${_bs_pin_file}.tmp" "$_bs_pin_file" 2>/dev/null || true
        else
            rm -f "$_bs_pin_file" 2>/dev/null || true
        fi
    fi

    # Persist rotation cursor: next cycle starts at the first file we did not TOUCH.
    # ⛔ This comment previously claimed "the first file we did NOT finish", which
    # the code did not implement: `rot` advances by files_done, and files_done
    # counts every file TOUCHED, including one left far from EOF. That gap is now
    # closed from the other side — the drain above finishes an object before
    # advancing — so touched and finished coincide except when the deadline stops
    # a drain mid-object, and COMPLETION PRIORITY puts that object first next cycle.
    if [[ -z "$log_file" && "$n" -gt 0 ]]; then
        printf '%s\n' "$(( (rot + files_done) % n ))" > "${rot_file}.tmp" 2>/dev/null \
            && mv -f "${rot_file}.tmp" "$rot_file" 2>/dev/null || true
    fi

    echo "Processed: $processed entries (${files_done}/${n} files this cycle)"
    [[ "$deadline_hit" -eq 1 ]] && echo "Deadline budget (${budget}s) reached — analyzing partial batch; remaining files resume next cycle"
    echo "IPs tracked: ${#_BOTSCAN_IP_HITS[@]}"

    # v1.187 Lane A — 404-window OPTION 1: independent fixed-tail re-read (does NOT touch
    # the forward cursor offset) so 404-burst detection is preserved despite the forward
    # cursor only seeing one slice per cycle. Authoritative source for the 404 counters.
    nftban_botscan_count_404_tail "$start_secs" "$budget" "${logs[@]}"
    [[ -n "$_pf" ]] && rm -f "$_pf"
    # v1.234.0 — count BEFORE cleanup: only now may drained objects be reaped (see above).
    local _bs_rf
    for _bs_rf in "${_bs_reap_after_tail[@]}"; do
        nftban_botscan_reap_consumed_spool "$_bs_rf" \
            "${BOTSCAN_SPOOL_DIR:-/var/lib/nftban/botscan/spool}" \
            "${NFTBAN_HTTP_LOG_OFFSET_DIR:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/proc-offsets}" || true
    done
    # v1.229.10 — bounded spool reclamation, EVERY cycle. (v1.234.0: moved AFTER the
    # 404/endpoint tail for the same count-before-cleanup reason as the per-file reap.) The per-file reap above
    # only ever sees files this cycle actually reached; with a deadline budget most
    # of the spool is deferred, and empty spool files are never enumerated at all
    # (the scan list uses -s). Without this sweep the spool can sit at its cap with
    # completed work still on disk, backpressure permanently asserted and collection
    # never resuming. This retires only PROVEN-completed or EMPTY BotScan-owned
    # objects; it never raises the cap.
    if [[ -z "$log_file" && "${BOTSCAN_SPOOL_REAP:-true}" == "true" ]] \
       && declare -F nftban_botscan_reclaim_spool >/dev/null 2>&1; then
        local _rc_out _rc_n _rc_k
        _rc_out="$(nftban_botscan_reclaim_spool \
            "${BOTSCAN_SPOOL_DIR:-/var/lib/nftban/botscan/spool}" \
            "${NFTBAN_HTTP_LOG_OFFSET_DIR:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/proc-offsets}" 2>/dev/null)" || _rc_out=""
        _rc_n="${_rc_out%% *}"; _rc_k="${_rc_out##* }"
        [[ "${_rc_n:-0}" =~ ^[0-9]+$ ]] && [[ "${_rc_n:-0}" -gt 0 ]] && \
            echo "Spool reclaimed: ${_rc_n} object(s) retired, ${_rc_k} kept"
    fi

    # v1.234.0 — ONE aggregate line when any evidence was excluded for its REQUEST time
    # (owner ruling rev 2: unreadable != zero activity, future != fresh activity; a drained
    # backlog older than the evidence horizon is OVERDUE, reported, never enforced).
    # No enforcement effect.
    if (( _BS_T_UA_UNPARSED > 0 )); then
        echo "BOTSCAN_PARSE ua_unparsed=${_BS_T_UA_UNPARSED} (lines without a trailing quoted User-Agent field: useragent rules skipped for them, never read as an empty UA)"
    fi
    if (( _BS_T_PAT_STALE + _BS_T_PAT_UNREADABLE + _BS_T_PAT_FUTURE + _BS_T_TAIL_UNREADABLE + _BS_T_TAIL_FUTURE > 0 )); then
        echo "BOTSCAN_TIME_FILTER pattern_stale=${_BS_T_PAT_STALE} pattern_unreadable_time=${_BS_T_PAT_UNREADABLE} pattern_future=${_BS_T_PAT_FUTURE} tail_unreadable_time=${_BS_T_TAIL_UNREADABLE} tail_future=${_BS_T_TAIL_FUTURE} horizon=${_BS_PATTERN_EVIDENCE_HORIZON}s"
    fi

    # Analyze and ban — ALWAYS runs (even on a partial/deadline-bounded batch) so a
    # high-volume host still produces bans every cycle instead of zero.
    # v1.231.0 P0-B — THE EXECUTION BOUNDARY.
    # analyze still runs in its own process, so its variable scope stays isolated
    # exactly as it was under `$( )`. What changed is the channel:
    #   * its stdout is NO LONGER captured, so BOTSCAN_ACTION_MODE=alert prose now
    #     reaches the operator instead of being swallowed — and can no longer be
    #     interpolated into the $(( )) arithmetic in record_runstate;
    #   * both counts are read back from the durable sink, not from a variable the
    #     fork could never write and not from an exit status.
    local banned=0 _analyze_rc=0
    ( nftban_botscan_analyze ) || _analyze_rc=$?
    [[ "$_analyze_rc" -ne 0 ]] && echo "[botscan] WARN: analyze exited rc=${_analyze_rc} — counts below may be partial" >&2
    banned="$(nftban_botscan_counter_get bans_emitted)"
    # v1.234.0 — shared CDN edges: one aggregate line when bans were skipped, and a loud
    # line if no shared-edge data could be loaded (edges are then NOT protected).
    local _edge_skipped; _edge_skipped="$(nftban_botscan_counter_get shared_edge_skipped)"
    nftban_botscan_load_shared_edges
    if (( ${#_BS_EDGE4_NET[@]} + ${#_BS_EDGE6_G[@]} == 0 )); then
        echo "BOTSCAN_SHARED_EDGE ranges=UNMEASURED (no shared-edge data loaded): CDN edge addresses are NOT protected from BotScan bans"
    elif [[ "${_edge_skipped:-0}" -gt 0 ]]; then
        echo "BOTSCAN_SHARED_EDGE skipped=${_edge_skipped} ban(s) of shared CDN edge addresses (the web server logs the proxy, not the visitor; configure real-IP restoration; reasons in ${BOTSCAN_LOG_FILE:-botscan.log} as SKIPPED_SHARED_EDGE)"
    fi
    # Reconcile the parent-side mirror so every in-process reader of the documented
    # v1.219.0 variable sees this cycle's real count.
    _BOTSCAN_SIGNALS_EMITTED="$(nftban_botscan_counter_get signals_emitted)"
    echo "Banned: $banned IPs"

    # v1.207 — record run-state + health (recording-discipline honored in the writer).
    # INVARIANT: 0 scanned is NEVER "clean" — a host with input (n>0) but 0 processed
    # is DEGRADED_INPUT_BLIND; budget-hit / growing-backlog are DEGRADED + visible.
    if declare -F nftban_botscan_record_runstate >/dev/null 2>&1; then
        local _dur=$(( SECONDS - start_secs )) _hasin=0 _health
        [[ "$n" -gt 0 ]] && _hasin=1
        _health=$(nftban_botscan_health_state "${BOTSCAN_ENABLED:-true}" "$processed" "$banned" "$deadline_hit" "$_BS_BACKLOG" "$_hasin" 0)
        nftban_botscan_record_runstate \
            ts="$(date +%s)" dur="$_dur" lines_seen="$processed" lines_scanned="$processed" \
            budget_hit="$deadline_hit" backlog_bytes="${_BS_BYTES:-0}" \
            vhosts_scanned="$files_done" vhosts_deferred="$(( n - files_done ))" \
            bans="$banned" signals="${_BOTSCAN_SIGNALS_EMITTED:-0}" \
            unique_ips="${#_BOTSCAN_IP_HITS[@]}" \
            pressure_state="$_BS_PRESSURE" scan_mode="$_BS_MODE" \
            backlog_state="$_BS_BACKLOG" health_state="$_health" load_ratio="${_lr:-0}" \
            shared_edge_skipped="${_edge_skipped:-0}" shared_edge_ranges="$(( ${#_BS_EDGE4_NET[@]} + ${#_BS_EDGE6_G[@]} ))"
    fi

    # v1.231.0 P0-B — close this cycle's counter sink. Everything durable has been
    # written by now; keeping the journal past the cycle would only unbound it.
    nftban_botscan_counters_release

    return 0
}

# Check/run once
nftban_botscan_check() {
    nftban_botscan_load_config
    nftban_botscan_process_logs "$@"
}

# v1.234.0 — requested vs effective ban duration, derived from the daemon's per-ban
# evidence record (never a claim). The rule's BAN value is what BotScan REQUESTS; the
# daemon enforces its own grey/ban mapping. Prints one "Ban duration:" line.
nftban_botscan_duration_truth() {
    local f="$1" l n=0 withreq=0 longer=0 last_req="" last_eff=""
    if [[ ! -r "$f" ]]; then
        echo "Ban duration:   UNMEASURED (no readable ban evidence at $f)"
        return 0
    fi
    while IFS= read -r l; do
        [[ "$l" =~ \"ttl_sec\":([0-9]+) ]] || continue
        n=$(( n + 1 )); last_eff="${BASH_REMATCH[1]}"; last_req=""
        if [[ "$l" =~ \"requested_ttl_sec\":([0-9]+) && "${BASH_REMATCH[1]}" -gt 0 ]]; then
            last_req="${BASH_REMATCH[1]}"; withreq=$(( withreq + 1 ))
            (( last_eff > last_req )) && longer=$(( longer + 1 ))
        fi
    done < "$f"
    if (( n == 0 )); then echo "Ban duration:   no BotScan ban recorded yet"; return 0; fi
    echo "Ban duration:   last ban requested ${last_req:-unknown (older record)}${last_req:+s}, enforced ${last_eff}s; ${longer} of ${withreq} bans with a recorded request were enforced longer than requested (batch mode, production: BAN selects a class, <=1800 s -> grey 3600 s, >1800 s -> ban 86400 s; direct mode honours BAN)"
    return 0
}

# Status
nftban_botscan_status() {
    nftban_botscan_load_config

    echo "HTTP Exploit Scanner (BotScan) Status"
    echo "====================================="
    echo ""
    echo "Enabled:        $BOTSCAN_ENABLED"
    echo "Timer:          $(systemctl is-active nftban-botscan.timer 2>/dev/null || echo inactive) (nftban-botscan.timer)"
    echo "Action Mode:    $BOTSCAN_ACTION_MODE"
    echo "Patterns Dir:   $BOTSCAN_PATTERNS_DIR (operator: override.local + your *.patterns)"
    echo "Shipped rules:  $(nftban_botscan_shipped_patterns_dir)/botscan_*.patterns (package defaults; never edit)"
    echo ""

    # Count patterns (v1.234.0: shipped + operator, EFFECTIVE state, as the loader sees them)
    local total=0 enabled=0 n_shipped=0 n_oper=0 _src _cat pattern_file
    local -A _ov=() _owner=()
    _botscan_read_overrides _ov
    while IFS=$'\t' read -r _src _cat pattern_file; do
        [[ -r "$pattern_file" ]] || continue
        [[ "$_src" == shipped ]] && n_shipped=$((n_shipped + 1)) || n_oper=$((n_oper + 1))
        local _bs_line
        while IFS= read -r _bs_line || [[ -n "$_bs_line" ]]; do
            _botscan_parse_record "$_bs_line" 2>/dev/null || continue
            [[ "$_src" == "operator" && "${_owner[$_BSREC_name]:-}" == "shipped" ]] && continue
            _owner["$_BSREC_name"]="$_src"
            total=$((total + 1))
            [[ "${_ov[$_BSREC_name]:-$_BSREC_enabled}" == "true" ]] && enabled=$((enabled + 1))
        done < "$pattern_file"
    done < <(nftban_botscan_pattern_files)

    echo "Patterns:       $enabled enabled / $total total (${n_shipped} shipped file(s), ${n_oper} operator file(s))"
    local -a _st=() _all=()
    mapfile -t _st < <(nftban_botscan_pattern_sidecars)
    mapfile -t _all < <(nftban_botscan_pattern_sidecars all)
    if (( ${#_st[@]} > 0 )); then
        echo "Stale patterns: ${#_st[@]} file(s) NOT active — review and remove: ${_st[*]##*/}"
    fi
    if (( ${#_all[@]} > ${#_st[@]} )); then
        echo "Migrated:       $(( ${#_all[@]} - ${#_st[@]} )) pre-v1.234 file(s) converted (kept for review, not loaded); report: ${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/pattern-migration.report"
    fi
    nftban_botscan_duration_truth "${BOTSCAN_BAN_EVIDENCE_FILE:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/botguard/botscan_ban_evidence.jsonl}"
    # v1.234.0 — shared CDN edges: ranges in force + bans skipped (from the run-state record)
    nftban_botscan_load_shared_edges
    local _er=$(( ${#_BS_EDGE4_NET[@]} + ${#_BS_EDGE6_G[@]} )) _el="UNMEASURED" _et="UNMEASURED" _rs="${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan/runstate.json"
    if [[ -r "$_rs" ]] && command -v jq >/dev/null 2>&1; then
        _el="$(jq -r '.shared_edge_skipped_last // "UNMEASURED"' "$_rs" 2>/dev/null || echo UNMEASURED)"
        _et="$(jq -r '.shared_edge_skipped_total // "UNMEASURED"' "$_rs" 2>/dev/null || echo UNMEASURED)"
    fi
    if (( _er == 0 )); then
        echo "CDN edges:      NOT PROTECTED — no shared-edge range data loaded (expected ${NFTBAN_LIB_DIR:-/usr/lib/nftban}/data/botscan_shared_edges.tsv)"
    else
        echo "CDN edges:      ${_er} shared-edge range(s) never banned (${_BS_EDGE_SOURCES% }); bans skipped: last cycle ${_el}, total ${_et}"
        if [[ "$_et" =~ ^[0-9]+$ && "$_et" -gt 0 ]]; then
            echo "                A web server here logs a CDN edge as the client: configure real-IP restoration"
            echo "                (nginx real_ip / Apache mod_remoteip). Behind a CDN a firewall ban does not block proxied requests."
        fi
    fi
    echo ""

    # Log source
    local log
    log=$(nftban_botscan_find_log)
    echo "Log Source:     ${log:-NOT FOUND}"

    # Service-account readability health (v1.177). Evaluated AS the service account
    # (nftban), not the caller — root could read panel logs the timer cannot.
    if declare -F nftban_http_classify_candidates >/dev/null 2>&1; then
        local svc="${NFTBAN_BOTSCAN_SERVICE_USER:-nftban}"
        nftban_http_classify_candidates "${BOTSCAN_LOG_PATHS:-}" >/dev/null 2>&1 || true
        local verdict="${_NFTBAN_HTTP_READ_VERDICT:-UNKNOWN}"
        # v1.178-A: collector spool feeds the scanner even when direct source is unreadable.
        local _spool="${BOTSCAN_SPOOL_DIR:-/var/lib/nftban/botscan/spool}" _spool_fed=0 _sf
        if [[ -d "$_spool" ]]; then
            for _sf in "$_spool"/*; do [[ -f "$_sf" && -r "$_sf" && -s "$_sf" ]] && { _spool_fed=1; break; }; done
        fi
        if [[ "$_spool_fed" -eq 1 && ( "$verdict" == "DEGRADED" || "$verdict" == "UNKNOWN" ) ]]; then
            echo "Readability:    OK via collector spool (direct source ${verdict} for ${svc}; collector feeding ${_spool})"
        else
            echo "Log source:     ${verdict} (valid:${_NFTBAN_HTTP_COUNT_VALID} never-observed:${_NFTBAN_HTTP_COUNT_NEVER} invalid:${_NFTBAN_HTTP_COUNT_INVALID} unreadable:${_NFTBAN_HTTP_READ_COUNT_UNREADABLE} of ${_NFTBAN_HTTP_READ_COUNT_TOTAL} as ${svc})"
            case "$verdict" in
                DEGRADED)
                    echo "                BOTSCAN_READ_AUTHORITY open: access logs discovered but unreadable by the"
                    echo "                service account — install/enable nftban-botscan-collector.service (read-authority)." ;;
                INVALID_SOURCE)
                    echo "                Bound file(s) are NOT HTTP access logs (FTP/offset/byte-count/state files) —"
                    echo "                BotScan is not scanning web traffic. Set BOTSCAN_LOG_PATHS to the real access-log glob(s)." ;;
                NEVER_OBSERVED)
                    echo "                Valid access log(s) bound but empty — no HTTP request logged yet (not a failure, not degraded)." ;;
            esac
        fi
    fi

    return 0
}

# Initialize on source
nftban_botscan_load_config
