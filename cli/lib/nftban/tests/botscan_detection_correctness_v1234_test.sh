#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.234.0 - BotScan detection correctness (pattern contract + request time)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="botscan_detection_correctness_v1234_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-30"
# meta:description="BUG-BOTSCAN-WPADMIN-AUTH-CONTEXT-IS-CYCLE-SCOPED-BANS-LOGGED-IN-EDITORS + BUG-BOTSCAN-PATTERN-WINDOW-USES-SCAN-TIME-NOT-REQUEST-TIME + 404/endpoint tail replay. Drives the REAL timer path (nftban_botscan_check over a spool, batch-signal mode, one process per cycle, pinned now) and asserts on the durable ban witness (batch_signals.jsonl). Arms: a redacted production editing session replayed on its recorded timer schedule (no ban, across cycles and an IP change without login); CMS-neutral repeated application traffic (no ban); expired and re-delivered evidence (no ban; reported); consumed evidence not counted twice (pattern cursor and 404/endpoint tail); malicious positive controls per class (enumeration, exploit route, scanner variety, UA, latency-realistic delivery, 404 flood, endpoint flood); route/query/trailing-slash/window/horizon/future/unreadable boundaries; retired WP login gate grants no trust; in-test negative controls (old record restored, fresh-shifted fixture) proving each no-ban arm can fail; structural: the evidence horizon covers the shipped timer units and the prefilter stays a sound superset. Set BSDC_SUBJECT_ROOT to an immutable older tree (e.g. a v1.233.1 worktree) to run the same arms against it: arms whose behaviour differs must FAIL there."
#
# meta:inventory.files="botscan_detection_correctness_v1234_test.sh,fixtures/botscan/wp_editor_session_redacted.tsv,fixtures/botscan/wp_editor_session_schedule.tsv"
# meta:inventory.binaries="bash,grep,sort,mktemp,cp,date"
# meta:inventory.env_vars="BSDC_SUBJECT_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="botscan_detection_correctness_v1234_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan"
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
export LC_ALL=C TZ=UTC     # CLF month names are English; epochs are UTC

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SUBJECT_ROOT="${BSDC_SUBJECT_ROOT:-$REPO_ROOT}"
FIX_DIR="$SCRIPT_DIR/fixtures/botscan"
SUBJ_LIB="$SUBJECT_ROOT/cli/lib/nftban"
SUBJ_PAT="$SUBJECT_ROOT/etc/nftban/patterns.d/botscan"

notexec() { echo "NOT_EXECUTED: $*" >&2; exit 2; }
[[ -r "$SUBJ_LIB/core/nftban_botscan.sh" ]] || notexec "subject module missing: $SUBJ_LIB/core/nftban_botscan.sh"
[[ -d "$SUBJ_PAT" ]] || notexec "subject pattern dir missing: $SUBJ_PAT"
[[ -r "$FIX_DIR/wp_editor_session_redacted.tsv" && -r "$FIX_DIR/wp_editor_session_schedule.tsv" ]] || notexec "fixtures missing under $FIX_DIR"
echo "subject: $SUBJECT_ROOT"

ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
[[ -n "${BSDC_KEEP:-}" ]] && { trap - EXIT; echo "sandbox kept: $ROOT"; }

# ---------------------------------------------------------------------------
# Harness. Every cycle is a FRESH bash process (as under the systemd timer), running the
# production entry point nftban_botscan_check in batch-signal mode over a spool directory,
# with `now` pinned through nftban_timestamp_unix. The durable witness is the batch-signal
# JSONL the daemon consumes; the arm asserts on it, never on stdout prose.
# ---------------------------------------------------------------------------
# `date +%s` shim: some subject code paths read the wall clock with `date +%s` instead of
# nftban_timestamp_unix (v1.233.1's 404/endpoint analyze did). Pin those too, so every
# subject is judged against the SAME "now" (otherwise an older subject's arm would be an
# observation failure, not a verdict). Every other `date` invocation passes through.
mkdir -p "$ROOT/bin"
REAL_DATE="$(command -v date)"
cat > "$ROOT/bin/date" <<SHIM
#!/usr/bin/env bash
if [[ "\${1:-}" == "+%s" && -n "\${BSDC_NOW:-}" ]]; then echo "\$BSDC_NOW"; exit 0; fi
exec "$REAL_DATE" "\$@"
SHIM
chmod +x "$ROOT/bin/date"

cat > "$ROOT/cycle.sh" <<'CYCLE'
set -Eeuo pipefail
SB="$1"; NOW="$2"; SUBJ_LIB="$3"
export LC_ALL=C TZ=UTC BSDC_NOW="$NOW" PATH="$4:$PATH"
export NFTBAN_LIB_DIR="$SUBJ_LIB" NFTBAN_DATA_DIR="$SB/data" NFTBAN_LOG_DIR="$SB/log" \
       NFTBAN_CONFIG_DIR="$SB/noetc" BOTSCAN_SPOOL_DIR="$SB/spool" BOTSCAN_PATTERNS_DIR="$SB/patterns" \
       BOTSCAN_LOG_FILE="$SB/botscan.log" BOTSCAN_STATE_FILE="$SB/state.db" \
       BOTSCAN_ENABLED=true BOTSCAN_BATCH_SIGNAL_MODE=true BOTSCAN_SCAN_BUDGET_SECS=0 \
       BOTSCAN_VERIFY_CRAWLERS=false BOTSCAN_USE_GLOBAL_WHITELIST=false
[[ -f "$SB/env" ]] && . "$SB/env"
# shellcheck source=/dev/null
source "$SUBJ_LIB/core/nftban_botscan.sh"
nftban_timestamp_unix() { echo "$NOW"; }
# Called exactly as cli/sbin/nftban-botscan-processor calls it (`nftban_botscan_check || result=$?`):
# the production caller is a conditional context, which disarms errexit inside the module.
# A bare call would abort on the pre-existing `_cand="$(command -v nftban-botscan-matcher)"`
# when the helper is not on PATH (design §12a side observation) — a harness artefact.
rc=0; nftban_botscan_check || rc=$?
exit "$rc"
CYCLE

# Spool objects are named the way the collector names them (`_<source path with / -> _>`):
# the processor's per-file reaper only retires `_*` objects, so this name is what makes the
# reap-after-drain path (A4) part of every arm, as on a production host.
OBJ="_var_log_httpd_domains_site.example.log"
# new_sb NAME -> sandbox path (shipped patterns of the SUBJECT copied in)
new_sb() {
    local sb="$ROOT/$1"
    mkdir -p "$sb/data/botguard" "$sb/log" "$sb/noetc" "$sb/spool" "$sb/patterns"
    cp "$SUBJ_PAT"/*.patterns "$sb/patterns/"
    : > "$sb/data/botguard/batch_signals.jsonl"
    printf '%s' "$sb"
}
# cycle SB NOW  (rc is asserted: a cycle that did not run is NOT a verdict)
CYC_N=0
cycle() {
    local sb="$1" now="$2" rc=0 f any=0
    CYC_N=$(( CYC_N + 1 ))
    # A real host always has other traffic. The processor reaps a drained object, and an
    # EMPTY spool makes the product report "No access log found" (rc 1) — so keep one benign
    # filler object from an unrelated client, placed at the cycle's own time.
    for f in "$sb"/spool/*; do [[ -s "$f" ]] && { any=1; break; }; done
    [[ "$any" -eq 1 ]] || printf '45.33.32.250 - - [%s] "GET /index.html HTTP/1.1" 200 512 "-" "Mozilla/5.0"\n' "$(clf "$now")" >> "$sb/spool/_var_log_httpd_domains_other.example.log"
    bash "$ROOT/cycle.sh" "$sb" "$now" "$SUBJ_LIB" "$ROOT/bin" > "$sb/cycle_${CYC_N}.out" 2>&1 || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        echo "--- cycle output ($sb @ $now) ---" >&2; tail -20 "$sb/cycle_${CYC_N}.out" >&2
        notexec "cycle rc=$rc (subject did not complete a cycle)"
    fi
    grep -q '^Processed: ' "$sb/cycle_${CYC_N}.out" || notexec "cycle produced no 'Processed:' line ($sb)"
    LAST_OUT="$sb/cycle_${CYC_N}.out"
}
# signals SB IP -> number of ban signals for IP (exact JSON key match)
signals() {
    local f="$1/data/botguard/batch_signals.jsonl" n=0 l
    [[ -r "$f" ]] || { echo 0; return 0; }
    while IFS= read -r l; do [[ "$l" == *"\"ip\":\"$2\""* ]] && n=$(( n + 1 )); done < "$f"
    echo "$n"
}
# sigttl SB IP -> requested_ttl_sec carried by the FIRST ban signal for IP ("absent" if none)
sigttl() {
    local f="$1/data/botguard/batch_signals.jsonl" l
    while IFS= read -r l; do
        if [[ "$l" == *"\"ip\":\"$2\""* ]]; then
            if [[ "$l" =~ \"requested_ttl_sec\":([0-9]+) ]]; then echo "${BASH_REMATCH[1]}"; else echo absent; fi
            return 0
        fi
    done < "$f"
    echo absent
}
# clf EPOCH -> CLF timestamp (fork-free, UTC, English month)
clf() { local o; printf -v o '%(%d/%b/%Y:%H:%M:%S +0000)T' "$1"; printf '%s' "$o"; }
# emit SB IP EPOCH METHOD TARGET STATUS [UA] -> append one access-log line to the spool object
emit() {
    local ua="${7:-Mozilla/5.0 (X11; Linux x86_64) Firefox/140.0}"
    printf '%s - - [%s] "%s %s HTTP/1.1" %s 512 "-" "%s"\n' "$2" "$(clf "$3")" "$4" "$5" "$6" "$ua" >> "$1/spool/$OBJ"
}

PASS=0; FAIL=0; ARMS_RUN=0; declare -a FAILED=()
ok()  { PASS=$(( PASS + 1 )); echo "PASS $1"; }
bad() { FAIL=$(( FAIL + 1 )); FAILED+=("$1"); echo "FAIL $1" >&2; }
check() { # check NAME ACTUAL OP EXPECTED
    local name="$1" a="$2" op="$3" e="$4" r=1
    case "$op" in
        eq) [[ "$a" -eq "$e" ]] && r=0 ;;
        ge) [[ "$a" -ge "$e" ]] && r=0 ;;
    esac
    if [[ "$r" -eq 0 ]]; then ok "$name (got $a)"; else bad "$name (got $a, want $op $e)"; fi
}
arm_begin() { ARMS_RUN=$(( ARMS_RUN + 1 )); echo "== $1"; }

T0=1790740800   # 2026-09-30T00:00:00Z — synthetic arms are placed relative to this day

# =============================================================================
# R1/R2 — REPLAY: the recorded editing session on its recorded timer schedule.
# The editor polls /wp-json/wp/v2/users/me; the login POST happened in an EARLIER cycle
# for .21 and .23, and NEVER for .22 (same person, new ISP address). Ordinary repeated
# application traffic across many cycles must produce NO ban for any of the three.
# (v1.233.1 bans .21 at the 08:15:44 and 08:26:15 cycles, .22 at 09:18:08 and .23 at
# 12:25:42 — exactly the production record.)
# =============================================================================
replay() { # replay SB -> delivers the fixture on the schedule and runs every P cycle
    local sb="$1" e l k tc delivered=0 total
    local -a FE=() FL=()
    while IFS=$'\t' read -r e l; do [[ "$e" == \#* || -z "$e" ]] && continue; FE+=("$e"); FL+=("$l"); done < "$FIX_DIR/wp_editor_session_redacted.tsv"
    total=${#FE[@]}
    while IFS=$'\t' read -r tc k; do
        [[ "$tc" == \#* || -z "$tc" ]] && continue
        if [[ "$k" == "C" ]]; then
            REPLAY_LAST_C="$tc"
            while (( delivered < total )) && (( FE[delivered] <= tc )); do
                printf '%s\n' "${FL[delivered]}" >> "$sb/spool/$OBJ"; delivered=$(( delivered + 1 ))
            done
        else
            cycle "$sb" "$tc"
            REPLAY_TRACE+="$(date -u -d "@$tc" +%H:%M:%S) .21=$(signals "$sb" 45.33.32.21) .22=$(signals "$sb" 45.33.32.22) .23=$(signals "$sb" 45.33.32.23)"$'\n'
        fi
    done < "$FIX_DIR/wp_editor_session_schedule.tsv"
    REPLAY_DELIVERED=$delivered; REPLAY_TOTAL=$total
    REPLAY_DUE=0; for e in "${FE[@]}"; do if (( e <= REPLAY_LAST_C )); then REPLAY_DUE=$(( REPLAY_DUE + 1 )); fi; done
}
arm_begin "R1/R2 replay: recorded editing session, recorded schedule"
REPLAY_TRACE=""
sbR="$(new_sb replay)"
replay "$sbR"
echo "   fixture lines: $REPLAY_TOTAL (due by the last recorded collector run: $REPLAY_DUE)"
check "R1 replay delivered every fixture line up to the last recorded collector run" "$REPLAY_DELIVERED" eq "$REPLAY_DUE"
check "R1 editor .21 (login in an earlier cycle) never banned" "$(signals "$sbR" 45.33.32.21)" eq 0
check "R2 editor .22 (IP change, no login at all) never banned" "$(signals "$sbR" 45.33.32.22)" eq 0
check "R1 editor .23 (login in an earlier cycle) never banned" "$(signals "$sbR" 45.33.32.23)" eq 0
echo "   diagnostic (cumulative signals after each processor cycle, observed not asserted):"
_tr="$(grep -v -e ' .21=0 .22=0 .23=0$' -e '^$' <<<"$REPLAY_TRACE" || true)"
if [[ -n "$_tr" ]]; then sed 's/^/     /' <<<"$_tr"; else echo "     (no signal at any cycle)"; fi

# NC-R: negative control on the SAME replay — restore the pre-v1.234 EXP_WPREST record
# (substring, every hit counts) on this subject. The arm must now ban: it proves R1 is
# decided by the pattern contract, not by some incidental property of the harness.
arm_begin "NC-R negative control: old EXP_WPREST record restored"
sbN="$(new_sb replay_nc)"
printf '%s\n' 'EXP_WPREST|/wp-json/wp/v2/users|url-get|5|300|1800|true|pre-v1.234 record (negative control)' > "$sbN/patterns/zz_negative_control.patterns"
REPLAY_TRACE=""
replay "$sbN"
check "NC-R old record bans the editor (.21) — arm R1 has power" "$(signals "$sbN" 45.33.32.21)" ge 1

# =============================================================================
# R3 — CMS-NEUTRAL ordinary repeated application traffic, three cycles, each source a
# legitimate endpoint whose path contains a suspicious substring or a missing resource
# polled by an application. Repetition of ONE target is not probing.
# =============================================================================
arm_begin "R3 CMS-neutral repeated application traffic"
sb3="$(new_sb neutral)"
for c in 0 1 2; do
    base=$(( T0 + 3600 + c * 600 ))
    for (( s=0; s<600; s+=15 )); do
        emit "$sb3" 45.33.32.31 $(( base + s )) GET '/server-status?auto' 200 'monitor/1.0'
        emit "$sb3" 45.33.32.32 $(( base + s )) GET '/actuator/health' 200 'kube-probe/1.30'
        emit "$sb3" 45.33.32.33 $(( base + s )) GET '/api/v1/feature-flags' 404
        emit "$sb3" 45.33.32.34 $(( base + s )) GET '/metrics' 404 'Prometheus/2.53'
    done
    for (( s=0; s<60; s+=20 )); do emit "$sb3" 45.33.32.35 $(( base + s )) GET '/blog/redis-caching-guide/' 200; done
    cycle "$sb3" $(( base + 600 + 90 ))
done
for ip in 31 32 33 34 35; do check "R3 benign repeated source 45.33.32.$ip not banned (3 cycles)" "$(signals "$sb3" 45.33.32.$ip)" eq 0; done
# NC-R3: the same polling with the pre-v1.234 record semantics must ban (arm has power).
arm_begin "NC-R3 negative control: server-status record as url-any hit counting"
sb3n="$(new_sb neutral_nc)"
printf '%s\n' 'EXP_SERVERSTATUS|/server-status|url-any|3|60|1800|true|pre-v1.234 record (negative control)' > "$sb3n/patterns/zz_negative_control.patterns"
for (( s=0; s<600; s+=15 )); do emit "$sb3n" 45.33.32.31 $(( T0 + 3600 + s )) GET '/server-status?auto' 200 'monitor/1.0'; done
cycle "$sb3n" $(( T0 + 3600 + 690 ))
check "NC-R3 old record bans the monitor — arm R3 has power" "$(signals "$sb3n" 45.33.32.31)" ge 1

# =============================================================================
# R4 — EXPIRED and RE-DELIVERED evidence (request time decides, never scan time).
# =============================================================================
arm_begin "R4a expired: a 3-day-old backlog is not evidence now"
sb4="$(new_sb stale)"
now4=$(( T0 + 7200 )); old=$(( now4 - 3 * 86400 ))
emit "$sb4" 45.33.32.41 "$old" GET '/.git/config' 404                       # threshold 1
emit "$sb4" 45.33.32.42 "$old" GET '/.env' 404; emit "$sb4" 45.33.32.42 $(( old + 30 )) GET '/api/.env' 404   # threshold 2
for i in 1 2 3 4 5 6; do emit "$sb4" 45.33.32.43 $(( old + i )) GET "/wp-json/wp/v2/users/$i" 200; done
cycle "$sb4" "$now4"
check "R4a 3-day-old exploit hit not banned" "$(signals "$sb4" 45.33.32.41)" eq 0
check "R4a 3-day-old .env pair not banned" "$(signals "$sb4" 45.33.32.42)" eq 0
check "R4a 3-day-old enumeration not banned" "$(signals "$sb4" 45.33.32.43)" eq 0
if grep -q '^BOTSCAN_TIME_FILTER .*pattern_stale=[1-9]' "$LAST_OUT"; then ok "R4a stale evidence is REPORTED (BOTSCAN_TIME_FILTER)"; else bad "R4a stale evidence not reported"; fi

arm_begin "R4b spread: hits days apart are not a burst"
sb4b="$(new_sb spread)"
emit "$sb4b" 45.33.32.44 $(( now4 - 3 * 86400 )) GET '/.env' 404
emit "$sb4b" 45.33.32.44 $(( now4 - 120 )) GET '/.env.bak' 404
cycle "$sb4b" "$now4"
check "R4b .env hits 3 days apart (threshold 2) not banned" "$(signals "$sb4b" 45.33.32.44)" eq 0

arm_begin "NC-R4 control: the same evidence, fresh, IS banned"
sb4n="$(new_sb stale_nc)"
emit "$sb4n" 45.33.32.41 $(( now4 - 300 )) GET '/.git/config' 404
emit "$sb4n" 45.33.32.42 $(( now4 - 300 )) GET '/.env' 404; emit "$sb4n" 45.33.32.42 $(( now4 - 270 )) GET '/api/.env' 404
for i in 1 2 3 4 5 6; do emit "$sb4n" 45.33.32.43 $(( now4 - 300 + i )) GET "/wp-json/wp/v2/users/$i" 200; done
cycle "$sb4n" "$now4"
check "NC-R4 fresh exploit hit banned" "$(signals "$sb4n" 45.33.32.41)" ge 1
check "NC-R4 fresh .env pair banned" "$(signals "$sb4n" 45.33.32.42)" ge 1
check "NC-R4 fresh enumeration banned" "$(signals "$sb4n" 45.33.32.43)" ge 1

arm_begin "R4c re-delivery: a rescan of consumed lines an hour later is not a fresh ban"
sb4c="$(new_sb redeliver)"
printf 'export BOTSCAN_SPOOL_REAP=false\n' > "$sb4c/env"
t=$(( T0 + 10800 ))
emit "$sb4c" 45.33.32.45 $(( t - 60 )) GET '/.git/config' 404
cycle "$sb4c" "$t"
first=$(signals "$sb4c" 45.33.32.45)
rm -f "$sb4c"/data/botscan/proc-offsets/*      # cursor lost: the next cycle re-reads the object from byte 0
cycle "$sb4c" $(( t + 3600 ))
check "R4c fresh hit banned once on first delivery" "$first" eq 1
check "R4c re-read 1 h later adds no signal" "$(signals "$sb4c" 45.33.32.45)" eq 1

# =============================================================================
# R5 — CONSUMED evidence is not counted again (no new bytes; the 404/endpoint tail
# re-reads the same 2 MiB every cycle).
# =============================================================================
arm_begin "R5 consumed evidence, 3 cycles, no new bytes"
sb5="$(new_sb consumed)"
printf 'export BOTSCAN_SPOOL_REAP=false\n' > "$sb5/env"
t=$(( T0 + 14400 ))
emit "$sb5" 45.33.32.51 $(( t - 30 )) GET '/.git/config' 404                       # pattern, forward cursor
for (( i=0; i<60; i++ )); do emit "$sb5" 45.33.32.52 $(( t - 90 + i )) GET "/missing-$i.html" 404; done   # 404 flood
for (( i=0; i<40; i++ )); do emit "$sb5" 45.33.32.53 $(( t - 40 + i / 2 )) POST '/xmlrpc.php' 200; done  # endpoint flood
cycle "$sb5" "$t"; cycle "$sb5" $(( t + 600 )); cycle "$sb5" $(( t + 1200 ))
check "R5 pattern hit: exactly one signal over 3 cycles" "$(signals "$sb5" 45.33.32.51)" eq 1
check "R5 404 flood: exactly one signal over 3 cycles (tail re-read)" "$(signals "$sb5" 45.33.32.52)" eq 1
check "R5 endpoint flood: exactly one signal over 3 cycles (tail re-read)" "$(signals "$sb5" 45.33.32.53)" eq 1

arm_begin "R5b 404 flood spread over 30 days is not a flood"
sb5b="$(new_sb spread404)"
t=$(( T0 + 18000 ))
for (( i=0; i<60; i++ )); do emit "$sb5b" 45.33.32.54 $(( t - 30 * 86400 + i * 43200 )) GET "/old-$i.html" 404; done
cycle "$sb5b" "$t"
check "R5b 60x404 over 30 days not banned" "$(signals "$sb5b" 45.33.32.54)" eq 0

# =============================================================================
# R6 — MALICIOUS positive controls, per detection class. Must ban.
# =============================================================================
arm_begin "R6 positive controls"
sb6="$(new_sb positive)"
t=$(( T0 + 21600 ))
for i in 1 2 3 4 5 6; do emit "$sb6" 45.33.32.61 $(( t - 200 + i )) GET "/wp-json/wp/v2/users/$i" 200; done                # enumeration: IDs
for i in 1 2 3 4 5; do emit "$sb6" 45.33.32.62 $(( t - 200 + i )) GET "/?rest_route=/wp/v2/users/$i" 200; done           # enumeration: rest_route
for i in 1 2 3 4 5; do emit "$sb6" 45.33.32.63 $(( t - 200 + i )) GET "/wp-json/wp/v2/users/?page=$i" 200; done          # collection + slash + query
for i in 1 2 3 4 5; do emit "$sb6" 45.33.32.64 $(( t - 200 + i )) GET "/index.php?rest_route=%2Fwp%2Fv2%2Fusers%2F$i" 401; done  # encoded
emit "$sb6" 45.33.32.65 $(( t - 100 )) GET '/.git/config' 404                                                               # exploit route, threshold 1
for i in 1 2 3; do emit "$sb6" 45.33.32.66 $(( t - 100 + i )) GET "/actuator/env?x=$i" 200; done                         # exploit route (actuator)
for p in /backup.zip /old.zip /db.sql?download=1 /site.tar.gz /config.bak /x.old /.env.save /wp-config.php.orig /admin/login /test/; do
    emit "$sb6" 45.33.32.67 $(( t - 100 )) GET "$p" 404; done                                                             # scanner variety
emit "$sb6" 45.33.32.68 $(( t - 100 )) GET '/' 200 'Nuclei - Open-source project (github.com/projectdiscovery/nuclei)'              # UA
for (( i=0; i<60; i++ )); do emit "$sb6" 45.33.32.69 $(( t - 100 + i )) GET "/nope-$i.php" 404; done                     # 404 flood
for (( i=0; i<40; i++ )); do emit "$sb6" 45.33.32.70 $(( t - 40 + i / 2 )) POST '/wp-login.php' 200; done               # endpoint flood
cycle "$sb6" "$t"
check "R6 enumeration by numeric IDs banned" "$(signals "$sb6" 45.33.32.61)" ge 1
check "R6 enumeration via ?rest_route= banned" "$(signals "$sb6" 45.33.32.62)" ge 1
check "R6 enumeration of the collection with trailing slash + query banned" "$(signals "$sb6" 45.33.32.63)" ge 1
check "R6 enumeration via URL-encoded rest_route banned" "$(signals "$sb6" 45.33.32.64)" ge 1
check "R6 threshold-1 exploit route banned" "$(signals "$sb6" 45.33.32.65)" ge 1
check "R6 actuator sensitive endpoint (with query) banned" "$(signals "$sb6" 45.33.32.66)" ge 1
check "R6 scanner probing variety banned" "$(signals "$sb6" 45.33.32.67)" ge 1
check "R6 scanner User-Agent banned" "$(signals "$sb6" 45.33.32.68)" ge 1
check "R6 fresh 404 flood banned" "$(signals "$sb6" 45.33.32.69)" ge 1
check "R6 fresh endpoint flood banned" "$(signals "$sb6" 45.33.32.70)" ge 1

# (e) duration visibility: every signal carries the duration the rule REQUESTS — the
# patterns.d BAN column (EXP_WPREST 1800, EXP_GITCONFIG 7200), BOTSCAN_404_BAN (3600) and
# BOTSCAN_ENDPOINT_FLOOD_BAN (3600). The daemon keeps its grey/ban mapping (asserted in
# botscan_signal_ttl_v1234_test.go) and records requested beside effective.
for pair in 61:1800 65:7200 69:3600 70:3600; do
    got="$(sigttl "$sb6" "45.33.32.${pair%%:*}")"
    if [[ "$got" == "${pair##*:}" ]]; then ok "R6 signal for .${pair%%:*} carries the requested duration ${pair##*:}s"
    else bad "R6 signal for .${pair%%:*} carries requested_ttl_sec=$got, rule requests ${pair##*:}s"; fi
done

arm_begin "R6b latency-realistic delivery: pattern evidence 12 minutes old is still evidence"
sb6b="$(new_sb latency)"
t=$(( T0 + 25200 ))
emit "$sb6b" 45.33.32.71 $(( t - 720 )) GET '/.git/config' 404
for i in 1 2 3 4 5; do emit "$sb6b" 45.33.32.72 $(( t - 720 + i )) GET "/wp-json/wp/v2/users/$i" 200; done
cycle "$sb6b" "$t"
check "R6b exploit hit delivered 12 min late banned" "$(signals "$sb6b" 45.33.32.71)" ge 1
check "R6b enumeration delivered 12 min late banned" "$(signals "$sb6b" 45.33.32.72)" ge 1

# =============================================================================
# R7 — BOUNDARIES: route, query, trailing slash, window, horizon, future, unreadable.
# =============================================================================
arm_begin "R7 boundaries"
sb7="$(new_sb bounds)"
t=$(( T0 + 28800 ))
for (( i=0; i<20; i++ )); do                                   # /users/me in every form: never enumeration
    emit "$sb7" 45.33.32.81 $(( t - 250 + i )) GET '/wp-json/wp/v2/users/me' 200
    emit "$sb7" 45.33.32.81 $(( t - 250 + i )) GET "/wp-json/wp/v2/users/me?context=edit&_locale=user&n=$i" 200
    emit "$sb7" 45.33.32.81 $(( t - 250 + i )) GET '/wp-json/wp/v2/users/me/' 401
    emit "$sb7" 45.33.32.81 $(( t - 250 + i )) GET '/?rest_route=/wp/v2/users/me' 200
done
for i in 0 1 2 3 4; do emit "$sb7" 45.33.32.82 $(( t - 400 + i * 75 )) GET "/wp-json/wp/v2/users/$(( i + 1 ))" 200; done   # span 300 s
for i in 0 1 2 3 4; do emit "$sb7" 45.33.32.83 $(( t - 400 + i * 76 )) GET "/wp-json/wp/v2/users/$(( i + 1 ))" 200; done   # span 304 s
for i in 1 2 3 4 5 6 7 8; do emit "$sb7" 45.33.32.84 $(( t - 100 )) GET '/wp-json/wp/v2/users/1' 200; done                 # one target repeated
emit "$sb7" 45.33.32.85 $(( t + 60 )) GET '/.git/config' 404                                                           # future
printf '45.33.32.86 - - [30/Sepx/2026:07:00:00 +0000] "GET /.git/config HTTP/1.1" 404 512 "-" "x"\n' >> "$sb7/spool/$OBJ"   # unreadable time
cycle "$sb7" "$t"
check "R7 /users/me (query, trailing slash, rest_route) x80 not banned" "$(signals "$sb7" 45.33.32.81)" eq 0
check "R7 5 distinct IDs within exactly 300 s banned (inclusive)" "$(signals "$sb7" 45.33.32.82)" ge 1
check "R7 5 distinct IDs spread over 304 s not banned" "$(signals "$sb7" 45.33.32.83)" eq 0
check "R7 one numeric ID requested 8x is not enumeration" "$(signals "$sb7" 45.33.32.84)" eq 0
check "R7 future-dated line not banned" "$(signals "$sb7" 45.33.32.85)" eq 0
check "R7 unreadable-time line not banned" "$(signals "$sb7" 45.33.32.86)" eq 0
if grep -q '^BOTSCAN_TIME_FILTER .*pattern_unreadable_time=[1-9].*' "$LAST_OUT" && grep -q '^BOTSCAN_TIME_FILTER .*pattern_future=[1-9]' "$LAST_OUT"; then
    ok "R7 future and unreadable evidence REPORTED"; else bad "R7 future/unreadable evidence not reported"; fi

arm_begin "R7b evidence horizon edge"
# D is read from the subject; an older subject has no D -> this arm is a FAIL there by design.
D="$(bash -c 'export NFTBAN_DATA_DIR="$1/data" NFTBAN_LIB_DIR="$2"; source "$2/core/nftban_botscan.sh" >/dev/null 2>&1; echo "${_BS_PATTERN_EVIDENCE_HORIZON:-}"' _ "$ROOT/hz" "$SUBJ_LIB" 2>/dev/null || true)"
if [[ "$D" =~ ^[0-9]+$ ]]; then
    sb7b="$(new_sb horizon)"
    t=$(( T0 + 32400 ))
    emit "$sb7b" 45.33.32.87 $(( t - D )) GET '/.git/config' 404
    emit "$sb7b" 45.33.32.88 $(( t - D - 1 )) GET '/.git/config' 404
    cycle "$sb7b" "$t"
    check "R7b hit at age == D (${D}s) counts" "$(signals "$sb7b" 45.33.32.87)" ge 1
    check "R7b hit at age == D+1 does not" "$(signals "$sb7b" 45.33.32.88)" eq 0
else
    bad "R7b subject defines no evidence horizon (_BS_PATTERN_EVIDENCE_HORIZON)"
fi

# =============================================================================
# R8 — the retired v1.192.2 gate: an inferred login grants no trust.
# =============================================================================
arm_begin "R8 login 302 in the same cycle does not exempt enumeration"
sb8="$(new_sb nogate)"
t=$(( T0 + 36000 ))
emit "$sb8" 45.33.32.91 $(( t - 300 )) POST '/wp-login.php?action=lostpassword' 302
for i in 1 2 3 4 5 6; do emit "$sb8" 45.33.32.91 $(( t - 250 + i )) GET "/wp-json/wp/v2/users/$i" 200; done
cycle "$sb8" "$t"
check "R8 enumeration after a login-looking 302 still banned" "$(signals "$sb8" 45.33.32.91)" ge 1

# =============================================================================
# R9 — each pattern fires at ITS documented threshold; unrelated patterns never top
# each other up (BUG-BOTSCAN-PATTERN-THRESHOLD-CAPPED-AT-DEFAULT).
# =============================================================================
arm_begin "R9 documented thresholds, judged per pattern"
sb9="$(new_sb perpattern)"
t=$(( T0 + 39600 ))
for (( i=0; i<19; i++ )); do emit "$sb9" 45.33.32.101 $(( t - 60 + i * 2 )) GET "/p$i" 200 'Mozilla/5.0 (compatible; PetalBot)'; done   # 19 < 20
for (( i=0; i<20; i++ )); do emit "$sb9" 45.33.32.102 $(( t - 60 + i * 2 )) GET "/p$i" 200 'Mozilla/5.0 (compatible; PetalBot)'; done   # 20 == 20
emit "$sb9" 45.33.32.103 $(( t - 50 )) GET '/.git/HEAD' 200; emit "$sb9" 45.33.32.103 $(( t - 40 )) GET '/server-status' 200         # 1/2 + 1/3
emit "$sb9" 45.33.32.104 $(( t - 50 )) GET '/.git/HEAD' 200; emit "$sb9" 45.33.32.104 $(( t - 40 )) GET '/.git/index' 200           # 2/2
cycle "$sb9" "$t"
check "R9 PetalBot 19 hits (documented 20/60) not banned" "$(signals "$sb9" 45.33.32.101)" eq 0
check "R9 PetalBot 20 hits banned (fires at T)" "$(signals "$sb9" 45.33.32.102)" ge 1
check "R9 one hit each of two different rules (T=2, T=3) is not a ban" "$(signals "$sb9" 45.33.32.103)" eq 0
check "R9 two hits of the T=2 rule banned" "$(signals "$sb9" 45.33.32.104)" ge 1

# =============================================================================
# R10 — a User-Agent containing escaped quotes is parsed, not read as "-"
# (BUG-BOTSCAN-UA-PARSE-ESCAPED-QUOTE-BECOMES-DASH).
# =============================================================================
arm_begin "R10 escaped-quote User-Agent"
sb10="$(new_sb uaquote)"
t=$(( T0 + 43200 ))
for (( i=0; i<25; i++ )); do emit "$sb10" 45.33.32.105 $(( t - 55 + i * 2 )) GET "/page-$i/" 200 '\"Mozilla/5.0 (Windows NT 10.0) Chrome/140.0\"'; done
emit "$sb10" 45.33.32.106 $(( t - 30 )) GET '/' 200 '\"sqlmap/1.7#stable\"'
# common log format (no User-Agent field at all): unparseable UA must not become "-"
for (( i=0; i<25; i++ )); do printf '45.33.32.107 - - [%s] "GET /page-%d/ HTTP/1.1" 200 512\n' "$(clf $(( t - 55 + i * 2 )))" "$i" >> "$sb10/spool/$OBJ"; done
# negative control: a client that really sends NO User-Agent ("-") 25x in 50 s still meets
# SINGLE_DASH's documented 20/60 s
for (( i=0; i<25; i++ )); do emit "$sb10" 45.33.32.108 $(( t - 55 + i * 2 )) GET "/page-$i/" 200 '-'; done
cycle "$sb10" "$t"
check "R10 real visitor with an escaped-quote UA (25 req/50 s) not banned as an empty UA" "$(signals "$sb10" 45.33.32.105)" eq 0
check "R10 scanner UA inside escaped quotes still matched (sqlmap)" "$(signals "$sb10" 45.33.32.106)" ge 1
check "R10 common-format lines (no UA field) are not empty-UA evidence" "$(signals "$sb10" 45.33.32.107)" eq 0
check "R10 NC: a real empty UA (\"-\") at 25/50 s is still banned by SINGLE_DASH" "$(signals "$sb10" 45.33.32.108)" ge 1
if grep -q '^BOTSCAN_PARSE ua_unparsed=[1-9]' "$LAST_OUT"; then ok "R10 unparseable User-Agent lines are REPORTED"; else bad "R10 unparseable User-Agent lines not reported"; fi

# =============================================================================
# R11 — a LARGE months-old backlog (the stalled-timer / 1 GiB July spool case) resumed
# in one cycle: exploit hits, a 404 flood and an endpoint flood, all months old.
# =============================================================================
arm_begin "R11 months-old backlog resumed"
sb11="$(new_sb oldbacklog)"
t=$(( T0 + 46800 )); jul=$(( t - 80 * 86400 ))
{
    for (( i=0; i<1500; i++ )); do printf '45.33.32.199 - - [%s] "GET /page-%d/ HTTP/1.1" 200 512 "-" "Mozilla/5.0"\n' "$(clf $(( jul + i )))" "$i"; done
    for (( i=0; i<40; i++ )); do printf '45.33.32.1%02d - - [%s] "GET /.git/config HTTP/1.1" 404 512 "-" "x"\n' "$(( 10 + i % 40 ))" "$(clf $(( jul + 2000 + i )))"; done
    for (( i=0; i<200; i++ )); do printf '45.33.32.111 - - [%s] "GET /miss-%d.php HTTP/1.1" 404 512 "-" "x"\n' "$(clf $(( jul + 3000 + i / 4 )))" "$i"; done
    for (( i=0; i<200; i++ )); do printf '45.33.32.112 - - [%s] "POST /xmlrpc.php HTTP/1.1" 200 512 "-" "x"\n' "$(clf $(( jul + 4000 + i / 10 )))"; done
    for (( i=0; i<5; i++ )); do printf '45.33.32.113 - - [%s] "GET / HTTP/1.1" 200 512 "-" "sqlmap/1.7"\n' "$(clf $(( jul + 5000 + i )))"; done
} >> "$sb11/spool/$OBJ"
cycle "$sb11" "$t"
b11=0; for (( i=10; i<50; i++ )); do b11=$(( b11 + $(signals "$sb11" "45.33.32.1$(printf '%02d' "$i")") )); done
check "R11 80-day-old exploit hits (40 IPs) not banned" "$b11" eq 0
check "R11 80-day-old 404 flood not banned" "$(signals "$sb11" 45.33.32.111)" eq 0
check "R11 80-day-old endpoint flood not banned" "$(signals "$sb11" 45.33.32.112)" eq 0
check "R11 80-day-old scanner UA not banned" "$(signals "$sb11" 45.33.32.113)" eq 0
if grep -q '^BOTSCAN_TIME_FILTER .*pattern_stale=[1-9]' "$LAST_OUT"; then ok "R11 the stale backlog is REPORTED"; else bad "R11 stale backlog not reported"; fi

# =============================================================================
# R12 — a spool object kept forever by CURSOR_CONFLICT (two cursor authorities
# disagree -> the reaper keeps it, measured on a production host for 1,514 cycles).
# Its 2 MiB tail is re-read every cycle: one burst must be ONE signal, not one per cycle.
# =============================================================================
arm_begin "R12 CURSOR_CONFLICT object re-read every cycle"
sb12="$(new_sb conflict)"
t=$(( T0 + 50400 ))
for (( i=0; i<60; i++ )); do emit "$sb12" 45.33.32.121 $(( t - 70 + i )) GET "/gone-$i.html" 404; done
for (( i=0; i<40; i++ )); do emit "$sb12" 45.33.32.122 $(( t - 40 + i / 2 )) POST '/xmlrpc.php' 200; done
mkdir -p "$sb12/data/botscan/proc-offsets"
printf '0:0\n' > "$sb12/data/botscan/proc-offsets/_botscan_spool_$OBJ"                                          # canonical
printf '1:1\n' > "$sb12/data/botscan/proc-offsets/$(printf '%s/' "$sb12/spool" | tr '/' '_')$OBJ"               # legacy, disagreeing
cycle "$sb12" "$t"; cycle "$sb12" $(( t + 600 )); cycle "$sb12" $(( t + 1200 ))
if [[ -f "$sb12/spool/$OBJ" ]] && grep -q 'CURSOR_CONFLICT' "$sb12/botscan.log"; then
    ok "R12 precondition: the object was KEPT under CURSOR_CONFLICT for 3 cycles"
    check "R12 404 flood in the kept object: exactly one signal over 3 cycles" "$(signals "$sb12" 45.33.32.121)" eq 1
    check "R12 endpoint flood in the kept object: exactly one signal over 3 cycles" "$(signals "$sb12" 45.33.32.122)" eq 1
else
    bad "R12 precondition NOT met (object reaped or no CURSOR_CONFLICT) — arm not executed"
fi

# =============================================================================
# S — STRUCTURAL: evidence horizon vs the shipped timer units; prefilter soundness.
# =============================================================================
arm_begin "S1 evidence horizon covers the shipped timer units"
unit() { # unit FILE KEY -> seconds (first KEY= line; no pipe into a short-circuiting consumer)
    local l v=""
    while IFS= read -r l; do [[ "$l" == "$2="* ]] && { v="${l#*=}"; break; }; done < "$REPO_ROOT/install/systemd/$1"
    case "$v" in *min) v=$(( ${v%min} * 60 ));; *s) v="${v%s}";; esac
    [[ "$v" =~ ^[0-9]+$ ]] && echo "$v" || echo "MISSING:$1:$2"   # unreadable is never 0
}
U=( "$(unit nftban-botscan-collector.timer OnUnitActiveSec)" "$(unit nftban-botscan-collector.timer RandomizedDelaySec)" "$(unit nftban-botscan-collector.timer AccuracySec)"
    "$(unit nftban-botscan.timer OnUnitActiveSec)" "$(unit nftban-botscan.timer RandomizedDelaySec)" "$(unit nftban-botscan.timer AccuracySec)"
    "$(unit nftban-botscan.service TimeoutStartSec)" )
if [[ "${U[*]}" == *MISSING* ]]; then
    bad "S1 cannot derive the delivery bound from the timer units: ${U[*]}"
elif [[ ! "$D" =~ ^[0-9]+$ ]]; then
    bad "S1 subject defines no evidence horizon"
else
    need=$(( 2 * (U[0] + U[1] + U[2]) + 2 * (U[3] + U[4] + U[5]) + U[6] ))
    check "S1 D >= 2*collector + 2*processor period + one processor run (${need}s)" "$D" ge "$need"
fi

arm_begin "S2 prefilter keeps every positive-control line (per-pattern relaxed regex)"
S2_OUT="$(bash -c '
    set -uo pipefail; export LC_ALL=C NFTBAN_DATA_DIR="$1/data" BOTSCAN_PATTERNS_DIR="$2" NFTBAN_CONFIG_DIR=/nonexistent NFTBAN_LIB_DIR="$3"
    source "$3/core/nftban_botscan.sh" >/dev/null 2>&1; nftban_botscan_load_config; nftban_botscan_load_patterns
    declare -F nftban_botscan_prefilter_relax >/dev/null || { echo "NORELAX"; exit 0; }
    miss=0
    while IFS="|" read -r name tgt st; do
        IFS=$'"'"'\x1f'"'"' read -r pat mt _ <<< "${_BOTSCAN_PATTERNS[$name]}"
        case "$mt" in path-*|distinct-*) rx="$(nftban_botscan_prefilter_relax "$pat")";; *) rx="${pat#^}"; rx="${rx%\$}";; esac
        line="45.33.32.99 - - [30/Sep/2026:08:00:00 +0000] \"GET $tgt HTTP/1.1\" $st 5 \"-\" \"x\""
        if [[ ! "$line" =~ $rx ]]; then echo "MISS $name $tgt"; miss=$((miss+1)); fi
    done <<L
EXP_WPREST|/wp-json/wp/v2/users|200
EXP_WPREST|/wp-json/wp/v2/users/|200
EXP_WPREST|/wp-json/wp/v2/users/7|200
EXP_WPREST|/wp-json/wp/v2/users?per_page=100|200
EXP_WPREST|/?rest_route=/wp/v2/users|200
EXP_WPREST|/?rest_route=%2Fwp%2Fv2%2Fusers%2F3|200
EXP_ACTUATOR|/actuator/env|200
EXP_ACTUATOR|/actuator/env?x=1|200
EXP_REDIS|/redis|404
EXP_TIMTHUMB|/timthumb.php|404
SCAN_BACKUP_ZIP|/backup.zip|404
SCAN_BACKUP_ZIP|/backup.zip?x=1|404
WS_SHORT_2|/ab.php|404
WS_WPADMIN|/wp-admin/x.php.php|200
L
    echo "MISSES=$miss"
' _ "$ROOT/s2" "$SUBJ_PAT" "$SUBJ_LIB" 2>&1 || true)"
if grep -q '^MISSES=0$' <<<"$S2_OUT"; then ok "S2 prefilter sound for every positive control"; else bad "S2 prefilter drops candidates: $(tr '\n' ' ' <<<"$S2_OUT")"; fi

arm_begin "S3 DirectAdmin nginx_proxy reads one log family"
S3_OUT="$(bash -c '
    set -uo pipefail; printf "x=1\nnginx_proxy=1\n" > "$1/da_proxy.conf"
    source "$2/lib/nftban_http_logs.sh" >/dev/null 2>&1
    echo "PROXY:$(NFTBAN_DA_CONF="$1/da_proxy.conf" nftban_http_candidate_globs directadmin | tr "\n" " ")"
    echo "PLAIN:$(NFTBAN_DA_CONF="$1/absent.conf" nftban_http_candidate_globs directadmin | tr "\n" " ")"
' _ "$ROOT" "$SUBJ_LIB" 2>&1 || true)"
if grep -q '^PROXY:.*/var/log/nginx/domains/' <<<"$S3_OUT" && ! grep -q '^PROXY:.*/var/log/httpd/domains/' <<<"$S3_OUT"; then
    ok "S3 nginx_proxy=1: only the nginx (front-end) family is read"; else bad "S3 nginx_proxy=1 still reads both families: $S3_OUT"; fi
if grep -q '^PLAIN:.*/var/log/httpd/domains/' <<<"$S3_OUT" && grep -q '^PLAIN:.*/var/log/nginx/domains/' <<<"$S3_OUT"; then
    ok "S3 without nginx_proxy both families are still read"; else bad "S3 plain DirectAdmin lost a family: $S3_OUT"; fi

arm_begin "S4 override.local is readable by the scanner's group"
S4_OUT="$(bash -c '
    set -uo pipefail; d="$1/pat_override"; mkdir -p "$d"; chmod 0750 "$d"
    g2=""; for g in $(id -G); do [[ "$g" != "$(id -g)" ]] && { g2="$g"; break; }; done
    [[ -n "$g2" ]] && chgrp "$g2" "$d"
    export NFTBAN_LIB_DIR="$2" NFTBAN_DATA_DIR="$1/s4data" BOTSCAN_PATTERNS_DIR="$d"
    source "$2/core/nftban_botscan.sh" >/dev/null 2>&1
    nftban_botscan_set_override EXP_WPREST false; umask 077; nftban_botscan_set_override EXP_WPREST true
    echo "MODE=$(stat -c %a "$d/override.local") FGRP=$(stat -c %g "$d/override.local") DGRP=$(stat -c %g "$d") G2=${g2:-none}"
' _ "$ROOT" "$SUBJ_LIB" 2>&1 || true)"
if [[ "$S4_OUT" =~ MODE=640\ FGRP=([0-9]+)\ DGRP=([0-9]+)\ G2=(.*) ]]; then
    ok "S4 override.local mode 0640 even under umask 077"
    if [[ "${BASH_REMATCH[3]}" == none ]]; then echo "   S4 group arm NOT_EXECUTED: no secondary group available on this host (diagnostic)"
    elif [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]]; then ok "S4 override.local carries the pattern directory's group"
    else bad "S4 override.local group ${BASH_REMATCH[1]} != directory group ${BASH_REMATCH[2]}"; fi
else
    bad "S4 override.local not group-readable: $S4_OUT"
fi

arm_begin "S5 an unreadable operator override is reported, a readable one applies"
sb5o="$(new_sb override_vis)"
t=$(( T0 + 54000 ))
printf 'SQLMAP|false\n' > "$sb5o/patterns/override.local"; chmod 0640 "$sb5o/patterns/override.local"
emit "$sb5o" 45.33.32.131 $(( t - 30 )) GET '/' 200 'sqlmap/1.7'
cycle "$sb5o" "$t"
check "S5 readable override.local disables the rule (sqlmap not banned)" "$(signals "$sb5o" 45.33.32.131)" eq 0
if [[ "$(id -u)" -ne 0 ]]; then
    chmod 0000 "$sb5o/patterns/override.local"
    emit "$sb5o" 45.33.32.132 $(( t + 570 )) GET '/' 200 'sqlmap/1.7'
    cycle "$sb5o" $(( t + 600 ))
    if grep -q 'override.local exists but is NOT readable' "$LAST_OUT"; then ok "S5 unreadable override.local is REPORTED (not silently ignored)"; else bad "S5 unreadable override.local silently ignored"; fi
    check "S5 with the override unreadable the shipped rule applies (visible, fail-safe)" "$(signals "$sb5o" 45.33.32.132)" ge 1
    chmod 0640 "$sb5o/patterns/override.local"
else
    echo "   S5 unreadable arm NOT_EXECUTED: running as root (root reads a 0000 file)"
fi

arm_begin "S6 requested vs effective ban duration is visible in status"
S6_OUT="$(bash -c '
    export NFTBAN_LIB_DIR="$2" NFTBAN_DATA_DIR="$1/s6data"
    source "$2/core/nftban_botscan.sh" >/dev/null 2>&1
    declare -F nftban_botscan_duration_truth >/dev/null || { echo "NOFUNC"; exit 0; }
    f="$1/s6_evidence.jsonl"
    printf "%s\n" "{\"ip\":\"45.33.32.61\",\"action\":\"grey\",\"ttl_sec\":3600,\"requested_ttl_sec\":1800}" \
                  "{\"ip\":\"45.33.32.62\",\"action\":\"ban\",\"ttl_sec\":86400,\"requested_ttl_sec\":3600}" > "$f"
    nftban_botscan_duration_truth "$f"; nftban_botscan_duration_truth "$1/absent.jsonl"
' _ "$ROOT" "$SUBJ_LIB" 2>&1 || true)"
if grep -q 'last ban requested 3600s, enforced 86400s; 2 of 2 bans with a recorded request were enforced longer than requested' <<<"$S6_OUT"; then
    ok "S6 status shows requested beside effective, from the ban evidence"; else bad "S6 duration visibility missing: $(tr '\n' ' ' <<<"$S6_OUT")"; fi
if grep -q 'Ban duration:   UNMEASURED' <<<"$S6_OUT"; then ok "S6 no evidence -> UNMEASURED, never a claim"; else bad "S6 absent evidence not reported as UNMEASURED"; fi

# =============================================================================
echo "----"
EXPECTED_ARMS=25
echo "arms run: $ARMS_RUN/$EXPECTED_ARMS  pass=$PASS fail=$FAIL"
[[ "$ARMS_RUN" -eq "$EXPECTED_ARMS" ]] || { echo "INCOMPLETE: $ARMS_RUN of $EXPECTED_ARMS arms ran" >&2; exit 1; }
if [[ "$FAIL" -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}" >&2; exit 1; fi
echo "PASS: botscan detection correctness (pattern contract + request time + replay)"
