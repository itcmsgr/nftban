#!/usr/bin/env bash
# =============================================================================
# NFTBan - PortScan Classic realtime detection classifies on EVENT time (v1.233.1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="portscan_classic_event_time_v1233_1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-24"
# meta:description="BUG-PORTSCAN-CLASSIC-REALTIME-RECORDS-SCAN-TIME-STROBE-ALWAYS-RAPID. Drives the REAL classic processing path (nftban_portscan_classic_run / process_logs over a fixture kernel log, file and journald sources) with only side effects stubbed (ban -> witness file; journalctl/nft/logger shims; clock frozen) under set -Eeuo pipefail and the strict.sh IFS. Proves each connection is recorded at its own event time; strobe uses the min/max event span; block/vertical/horizontal/generic are bounded by PORTSCAN_CLASSIC_TIME_WINDOW of event time; stale (resumed/bootstrap), future-dated and malformed-time evidence is excluded (and reported); mid-ingest cleanup keeps still-eligible evidence and expires stale evidence; the Go-shadow request carries the real event times. NFTBAN_TEST_SUBJECT_MODULE selects another module file for inversion runs."
# meta:input="cli/lib/nftban/core/nftban_portscan_classic.sh,cli/lib/nftban/lib/strict.sh,etc/nftban/conf.d/portscan/classic.conf"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,date,grep,sort,mktemp,tail,sed"
# meta:inventory.files=""
# meta:inventory.binaries="bash,date,grep,sort,mktemp,tail,sed"
# meta:inventory.env_vars="NFTBAN_TEST_SUBJECT_MODULE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="portscan_classic_event_time_v1233_1_test"
# meta:ta.owner="portscan"
# meta:ta.module="portscan-classic"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
# Every arm runs in a FRESH bash process that sources the subject module and
# calls the product entry point. Nothing in the classifier, recorder, cleanup
# or reader is replaced; the classifier and cleanup are only WRAPPED
# (call-through) to record what they saw. The shipped classic.conf is copied
# verbatim; only paths (and MAX_TRACKED_IPS for the pressure arm) are overridden
# through the product's own classic.conf.local mechanism.
#
# Clock: nftban_timestamp_unix (the module's time authority) is frozen. The
# first call of a cycle returns NOW (cycle start); later calls return
# NOW + READ_SECS, modelling a read that took READ_SECS seconds.
#
# INVERSION: NFTBAN_TEST_SUBJECT_MODULE=<path to another module file> runs the
# same arms against it (e.g. `git show v1.233.0:<module>` saved to a file).
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
LIB_DIR="$REPO_ROOT/cli/lib/nftban"
STRICT="$LIB_DIR/lib/strict.sh"
SHIPPED_CONF="$REPO_ROOT/etc/nftban/conf.d/portscan/classic.conf"
SUBJECT="${NFTBAN_TEST_SUBJECT_MODULE:-$LIB_DIR/core/nftban_portscan_classic.sh}"

PASS=0; FAIL=0; FAILED=()
ok() { PASS=$((PASS+1)); echo "  [PASS] $1"; }
no() { FAIL=$((FAIL+1)); FAILED+=("$1"); echo "  [FAIL] $1${2:+ — $2}"; }

# The product's IFS, taken from strict.sh itself (not restated here).
STRICT_IFS_LINE=$(grep -m1 -E '^IFS=' "$STRICT") || STRICT_IFS_LINE=""
if [[ "$STRICT_IFS_LINE" == "IFS=\$'\\n\\t'" ]]; then
    eval "$STRICT_IFS_LINE"
else
    echo "PRECONDITION FAILED: strict.sh IFS line not found/changed: '$STRICT_IFS_LINE'"; exit 2
fi
[[ -f "$SUBJECT" ]] || { echo "PRECONDITION FAILED: subject module missing: $SUBJECT"; exit 2; }
[[ -f "$SHIPPED_CONF" ]] || { echo "PRECONDITION FAILED: shipped classic.conf missing"; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/ps-evtime.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

NOW=$(date +%s)
SRC_DST="198.51.100.10"

echo "================================================================="
echo "PortScan Classic event-time classification (v1.233.1)"
echo "subject: $SUBJECT"
echo "================================================================="

# ---------------------------------------------------------------------------
# Fixture helpers. syslog / journalctl -k "short" stamp, event time NOW+offset.
# ---------------------------------------------------------------------------
stamp() { LC_ALL=C date -d "@$1" "+%b %d %H:%M:%S"; }
# kline <offset> <port> <src> [dst]
kline() {
    local t=$((NOW + $1))
    printf '%s lab kernel: NFTBAN_PORTSCAN: IN=eth0 OUT= MAC=00:11:22:33:44:55 SRC=%s DST=%s LEN=44 TOS=0x00 PREC=0x00 TTL=50 ID=1 PROTO=TCP SPT=40000 DPT=%s WINDOW=1024 RES=0x00 SYN URGP=0\n' \
        "$(stamp "$t")" "$3" "${4:-$SRC_DST}" "$2"
}
# rawline <leading-text> <port> <src> [dst]  (for malformed stamps)
rawline() {
    printf '%slab kernel: NFTBAN_PORTSCAN: IN=eth0 OUT= SRC=%s DST=%s LEN=44 PROTO=TCP SPT=40000 DPT=%s SYN URGP=0\n' \
        "$1" "$3" "${4:-$SRC_DST}" "$2"
}

# The driver executed by every arm (fresh process). Quoted heredoc: nothing
# expands at generation time.
DRIVER="$WORK/driver.sh"
cat > "$DRIVER" <<'DRV'
set -Eeuo pipefail
eval "$STRICT_IFS_LINE"
# shellcheck source=/dev/null
source "$SUBJECT"
nftban_ban()  { local IFS=' '; echo "BAN $*" >> "$S/ban.witness"; }
nft_ipc_ban() { local IFS=' '; echo "IPCBAN $*" >> "$S/ban.witness"; }
nftban_timestamp_unix() {
    local b; b=$(<"$S/clock_base")
    if [[ -e "$S/clock.started" ]]; then echo $((b + READ_SECS)); else : > "$S/clock.started"; echo "$b"; fi
}
_f=$(declare -f nftban_portscan_classic_detect_scan_type)
eval "_ps_real_detect${_f#nftban_portscan_classic_detect_scan_type}"
nftban_portscan_classic_detect_scan_type() {
    local r="" rc=0
    r=$(_ps_real_detect "$@") || rc=$?
    echo "ip=$1 -> ${r:-none}" >> "$S/classify.txt"
    [[ -n "$r" ]] && echo "$r"
    return "$rc"
}
_f=$(declare -f nftban_portscan_classic_cleanup_old_entries)
eval "_ps_real_cleanup${_f#nftban_portscan_classic_cleanup_old_entries}"
nftban_portscan_classic_cleanup_old_entries() {
    echo "cleanup tracked=${#_PORTSCAN_CLASSIC_IP_PORTS[@]}" >> "$S/cleanup.calls"
    _ps_real_cleanup "$@"
}
nftban_portscan_classic_load_config
nftban_portscan_classic_init_state
nftban_portscan_classic_run
declare -p _PORTSCAN_CLASSIC_IP_PORTS > "$S/state1.dump" 2>/dev/null || true
if [[ -f "$S/cycle2.lines" ]]; then
    cat "$S/cycle2.lines" >> "$S/kern.log"
    echo "$CYCLE2_BASE" > "$S/clock_base"
    rm -f "$S/clock.started"
    nftban_portscan_classic_process_logs
    declare -p _PORTSCAN_CLASSIC_IP_PORTS > "$S/state2.dump" 2>/dev/null || true
fi
echo COMPLETE > "$S/marker"
DRV

# run_arm <name> <file|journal> <fixture-file> [read_secs] [extra .local lines]
run_arm() {
    local name="$1" kind="$2" fixture="$3" read_secs="${4:-0}" extra="${5:-}"
    local S="$WORK/$name"
    mkdir -p "$S/cfg/conf.d/portscan" "$S/log" "$S/data" "$S/bin"
    cp "$SHIPPED_CONF" "$S/cfg/conf.d/portscan/classic.conf"
    {
        echo "PORTSCAN_CLASSIC_LOG_FILE=\"$S/kern.log\""
        echo "PORTSCAN_CLASSIC_LOG_FILE_ALT=\"$S/none1,$S/none2\""
        if [[ "$kind" == "journal" ]]; then echo 'PORTSCAN_CLASSIC_USE_JOURNALCTL="true"'
        else echo 'PORTSCAN_CLASSIC_USE_JOURNALCTL="false"'; fi
        echo "PORTSCAN_CLASSIC_STATE_FILE=\"$S/data/portscan-state.db\""
        echo "PORTSCAN_CLASSIC_MODULE_LOG=\"$S/log/portscan-classic.log\""
        [[ -n "$extra" ]] && printf '%s\n' "$extra"
    } > "$S/cfg/conf.d/portscan/classic.conf.local"
    cp "$fixture" "$S/kern.log"
    echo "$NOW" > "$S/clock_base"
    printf '#!/bin/sh\necho "logger $*" >> "%s/logger.calls"\n' "$S" > "$S/bin/logger"
    printf '#!/bin/sh\necho "nft $*" >> "%s/nft.calls"\nexit 0\n' "$S" > "$S/bin/nft"
    printf '#!/bin/sh\necho "$@" >> "%s/journalctl.args"\ncat "%s/kern.log"\necho "-- cursor: s=fixture;i=2"\n' "$S" "$S" > "$S/bin/journalctl"
    printf '#!/bin/sh\ncat >> "%s/go.req"\necho >> "%s/go.req"\necho %s\n' "$S" "$S" \
        "'{\"scan_type\":\"\",\"action\":\"allow\",\"known_open_count\":0,\"unexpected_count\":0}'" > "$S/bin/nftban-core-stub"
    chmod +x "$S/bin/"*
    local core_bin="$S/bin/absent-nftban-core"
    [[ -f "$S/use_core_stub" ]] && core_bin="$S/bin/nftban-core-stub"
    local rc=0
    env PATH="$S/bin:$PATH" NFTBAN_LIB_DIR="$LIB_DIR" NFTBAN_CONFIG_DIR="$S/cfg" \
        NFTBAN_LOG_DIR="$S/log" NFTBAN_DATA_DIR="$S/data" NFTBAN_CORE_BIN="$core_bin" TMPDIR="$S" \
        PORTSCAN_CLASSIC_CURSOR_DIR="$S/data/portscan/log-cursors" \
        S="$S" SUBJECT="$SUBJECT" STRICT_IFS_LINE="$STRICT_IFS_LINE" READ_SECS="$read_secs" \
        CYCLE2_BASE="${CYCLE2_BASE:-0}" \
        bash "$DRIVER" > "$S/stdout" 2> "$S/stderr" || rc=$?
    echo "$rc" > "$S/rc"
}

# Arm completion: the subject provably executed to the end.
arm_complete() {
    local S="$WORK/$1" m=""
    [[ -f "$S/marker" ]] && m=$(<"$S/marker")
    if [[ "$m" == "COMPLETE" && "$(<"$S/rc")" == "0" ]]; then
        ok "$1: completed (marker + rc=0)"; return 0
    fi
    no "$1: did NOT complete — result NOT_EXECUTED" "rc=$(<"$S/rc") stderr=$(tail -n 3 "$S/stderr" 2>/dev/null || true)"
    return 1
}
witness() { local f="$WORK/$1/ban.witness"; if [[ -f "$f" ]]; then cat "$f"; fi; }
classify_of() { local f="$WORK/$1/classify.txt" l; [[ -f "$f" ]] || return 0; while IFS= read -r l; do [[ "$l" == "ip=$2 -> "* ]] && echo "${l#ip=$2 -> }"; done < "$f"; }
banned_as() {  # banned_as <arm> <ip> <type>
    local w; w=$(witness "$1")
    [[ "$w" == *"BAN $2 --timeout "*"--reason portscan:$3 "* ]]
}
not_banned() { local w; w=$(witness "$1"); [[ "$w" != *"BAN $2 "* ]]; }
modlog_has() { local f="$WORK/$1/log/portscan-classic.log"; [[ -f "$f" ]] && grep -F -m1 -- "$2" "$f" >/dev/null; }

FX="$WORK/fixtures"; mkdir -p "$FX"

# ---------------------------------------------------------------------------
# SLOW-STROBE — 5 ports over 120 s: NOT strobe, NOT banned (file + journald)
# ---------------------------------------------------------------------------
echo; echo "[SLOW-STROBE] 5 ports over 120 s"
IP=203.0.113.11
{ kline -120 22 $IP; kline -90 80 $IP; kline -60 443 $IP; kline -30 3306 $IP; kline 0 8080 $IP; } > "$FX/slow"
run_arm SLOW_STROBE file "$FX/slow"
run_arm SLOW_STROBE_J journal "$FX/slow"
for a in SLOW_STROBE SLOW_STROBE_J; do
    if arm_complete "$a"; then
        not_banned "$a" $IP && ok "$a: not banned" || no "$a: FALSE BAN" "$(witness "$a")"
        [[ "$(classify_of "$a" $IP)" != *strobe* ]] && ok "$a: not classified strobe" || no "$a: classified strobe" "$(classify_of "$a" $IP)"
    fi
done

# ---------------------------------------------------------------------------
# STEADY-50S — 6 ports over 50 s (10 s apart): not strobe
# ---------------------------------------------------------------------------
echo; echo "[STEADY-50S] 6 ports, one every 10 s"
IP=203.0.113.12
{ kline -50 21 $IP; kline -40 22 $IP; kline -30 25 $IP; kline -20 80 $IP; kline -10 110 $IP; kline 0 443 $IP; } > "$FX/steady"
run_arm STEADY_50S file "$FX/steady"
if arm_complete STEADY_50S; then
    not_banned STEADY_50S $IP && ok "STEADY_50S: not banned" || no "STEADY_50S: FALSE BAN" "$(witness STEADY_50S)"
    [[ "$(classify_of STEADY_50S $IP)" == "generic-observe" ]] && ok "STEADY_50S: generic-observe (v1.149 gate reached, not strobe)" \
        || no "STEADY_50S: expected generic-observe" "$(classify_of STEADY_50S $IP)"
fi

# ---------------------------------------------------------------------------
# FRESH-STROBE — 5 ports in 2 s: strobe, banned (positive control)
# ---------------------------------------------------------------------------
echo; echo "[FRESH-STROBE] 5 ports in 2 s (positive control)"
IP=203.0.113.13
{ kline -2 22 $IP; kline -1 80 $IP; kline -1 443 $IP; kline 0 3306 $IP; kline 0 8080 $IP; } > "$FX/fresh"
run_arm FRESH_STROBE file "$FX/fresh"
run_arm FRESH_STROBE_J journal "$FX/fresh"
for a in FRESH_STROBE FRESH_STROBE_J; do
    if arm_complete "$a"; then
        banned_as "$a" $IP strobe && ok "$a: banned as strobe" || no "$a: strobe NOT banned" "$(witness "$a")"
    fi
done

# ---------------------------------------------------------------------------
# SUB-THRESHOLD — 4 ports fast: no ban
# ---------------------------------------------------------------------------
echo; echo "[SUB-THRESHOLD] 4 ports in 2 s"
IP=203.0.113.14
{ kline -2 22 $IP; kline -1 80 $IP; kline -1 443 $IP; kline 0 3306 $IP; } > "$FX/sub"
run_arm SUB_THRESHOLD file "$FX/sub"
if arm_complete SUB_THRESHOLD; then
    not_banned SUB_THRESHOLD $IP && ok "SUB_THRESHOLD: not banned" || no "SUB_THRESHOLD: FALSE BAN" "$(witness SUB_THRESHOLD)"
fi

# ---------------------------------------------------------------------------
# RESUME/BACKLOG — journald --after-cursor resume; one batch carries hours of
# backlog. Backlog spread must not become one vertical/block scan; a fresh
# burst inside the same batch is still detected (as what it is: strobe).
# ---------------------------------------------------------------------------
echo; echo "[RESUME/BACKLOG] resumed batch: hours of backlog + fresh burst"
IP=203.0.113.15; IP2=203.0.113.16
{
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do kline $(( -14400 + i * 1000 )) $((1000 + i)) $IP; done
    for i in $(seq 1 25); do kline $(( -7200 + i * 60 )) $((2000 + i)) $IP2; done
    kline -3 22 $IP; kline -2 80 $IP; kline -2 443 $IP; kline -1 3306 $IP; kline -1 8080 $IP
} > "$FX/resume"
mkdir -p "$WORK/RESUME/data/portscan/log-cursors"
echo "s=previous;i=1" > "$WORK/RESUME/data/portscan/log-cursors/journal.cursor"
run_arm RESUME journal "$FX/resume"
if arm_complete RESUME; then
    jargs=""; [[ -f "$WORK/RESUME/journalctl.args" ]] && jargs=$(<"$WORK/RESUME/journalctl.args")
    [[ "$jargs" == *"--after-cursor=s=previous;i=1"* ]] && ok "RESUME: precondition — resumed via --after-cursor" \
        || no "RESUME: precondition — resume path NOT exercised" "$jargs"
    banned_as RESUME $IP strobe && ok "RESUME: fresh burst banned as strobe" || no "RESUME: fresh burst not banned as strobe" "$(witness RESUME)"
    w=$(witness RESUME)
    [[ "$w" != *"portscan:vertical"* && "$w" != *"portscan:block"* ]] && ok "RESUME: backlog NOT classified vertical/block" \
        || no "RESUME: backlog produced vertical/block" "$w"
    not_banned RESUME $IP2 && ok "RESUME: backlog-only source not banned" || no "RESUME: backlog-only source banned" "$w"
    modlog_has RESUME "stale=37" && ok "RESUME: stale exclusion visible (stale=37)" \
        || no "RESUME: stale exclusion not reported" "$(grep -F PORTSCAN_EVENT_TIME "$WORK/RESUME/log/portscan-classic.log" 2>/dev/null || true)"
fi

# ---------------------------------------------------------------------------
# EVENT-TIME BOUNDARY for TIME_WINDOW (shipped 60). 10 ports, one target, no
# 10 s window with >= 2 ports. span == 60 -> vertical; span == 61 -> not.
# READ_SECS=5: the last event of the 61 s arm arrived during the read.
# ---------------------------------------------------------------------------
echo; echo "[BOUNDARY] TIME_WINDOW span = window counts; window + 1 does not"
IP=203.0.113.17
offs_eq=(-60 -53 -46 -39 -32 -25 -18 -11 -4 0)
offs_p1=(-60 -53 -46 -39 -32 -25 -18 -11 -4 1)
: > "$FX/beq"; : > "$FX/bp1"
for i in "${!offs_eq[@]}"; do kline "${offs_eq[$i]}" $((100 + i)) $IP >> "$FX/beq"; kline "${offs_p1[$i]}" $((100 + i)) $IP >> "$FX/bp1"; done
run_arm BOUNDARY_EQ file "$FX/beq" 5
run_arm BOUNDARY_P1 file "$FX/bp1" 5
if arm_complete BOUNDARY_EQ; then
    banned_as BOUNDARY_EQ $IP vertical && ok "BOUNDARY_EQ: span 60 = window -> vertical ban" || no "BOUNDARY_EQ: expected vertical" "$(witness BOUNDARY_EQ)"
fi
if arm_complete BOUNDARY_P1; then
    not_banned BOUNDARY_P1 $IP && ok "BOUNDARY_P1: span 61 = window+1 -> not banned" || no "BOUNDARY_P1: FALSE BAN" "$(witness BOUNDARY_P1)"
    [[ "$(classify_of BOUNDARY_P1 $IP)" == "generic-observe" ]] && ok "BOUNDARY_P1: 9 ports per window -> generic-observe" \
        || no "BOUNDARY_P1: expected generic-observe" "$(classify_of BOUNDARY_P1 $IP)"
fi

# ---------------------------------------------------------------------------
# CLEANUP-PRESSURE — MAX_TRACKED_IPS=2. Cycle 1: a strobe 55 s old (valid,
# older than processing time) is ingested while mid-ingest cleanup runs
# (READ_SECS=10: a cutoff taken from processing time would evict it), mixed
# with genuinely stale lines. Cycle 2 (same process, clock +120 s): the
# cycle-1 evidence is now stale and must expire under pressure; fresh stays.
# ---------------------------------------------------------------------------
echo; echo "[CLEANUP-PRESSURE] MAX_TRACKED_IPS=2, valid-old vs stale, two cycles"
A=203.0.113.20; B=203.0.113.21; C=203.0.113.22; D=203.0.113.23; SX=203.0.113.24; E=203.0.113.25
{
    kline -5 22 $B; kline -5 22 $C
    for i in $(seq 1 25); do kline -3600 $((3000 + i)) $SX; done
    kline -55 22 $A; kline -4 23 $D; kline -54 80 $A; kline -54 443 $A; kline -53 3306 $A; kline -53 8080 $A
} > "$FX/pressure"
mkdir -p "$WORK/CLEANUP"
{ kline 115 22 $E; kline 116 23 $E; kline 117 25 $E; kline 118 22 203.0.113.26; kline 118 22 203.0.113.27; } > "$WORK/CLEANUP/cycle2.lines"
CYCLE2_BASE=$((NOW + 120)) run_arm CLEANUP file "$FX/pressure" 10 'PORTSCAN_CLASSIC_MAX_TRACKED_IPS="2"'
if arm_complete CLEANUP; then
    ncl=0; [[ -f "$WORK/CLEANUP/cleanup.calls" ]] && ncl=$(grep -c '^cleanup tracked=' "$WORK/CLEANUP/cleanup.calls" || true)
    (( ncl >= 3 )) && ok "CLEANUP: precondition — cleanup ran under pressure ($ncl calls)" || no "CLEANUP: pressure cleanup did not run" "calls=$ncl"
    banned_as CLEANUP $A strobe && ok "CLEANUP half 1: still-eligible (55 s old) evidence survived -> strobe ban" \
        || no "CLEANUP half 1: eligible evidence lost" "$(witness CLEANUP) / $(classify_of CLEANUP $A)"
    not_banned CLEANUP $SX && ok "CLEANUP: stale source (25 ports, 1 h old) not banned" || no "CLEANUP: stale source banned" "$(witness CLEANUP)"
    s1=""; [[ -f "$WORK/CLEANUP/state1.dump" ]] && s1=$(<"$WORK/CLEANUP/state1.dump")
    [[ "$s1" != *"[$SX]"* ]] && ok "CLEANUP: stale source not tracked after cycle 1" || no "CLEANUP: stale source still tracked" "$s1"
    s2=""; [[ -f "$WORK/CLEANUP/state2.dump" ]] && s2=$(<"$WORK/CLEANUP/state2.dump")
    if [[ -n "$s2" ]]; then
        [[ "$s2" != *"[$A]"* ]] && ok "CLEANUP half 2: cycle-1 evidence expired once stale (cycle 2)" || no "CLEANUP half 2: stale evidence survived" "$s2"
        [[ "$s2" == *"[$E]"* ]] && ok "CLEANUP half 2: fresh cycle-2 evidence kept" || no "CLEANUP half 2: fresh evidence lost" "$s2"
    else
        no "CLEANUP: cycle 2 state dump missing — NOT_EXECUTED"
    fi
fi

# ---------------------------------------------------------------------------
# UNORDERED-EVENT-TIME — out-of-order lines: min/max, never first/last.
# ---------------------------------------------------------------------------
echo; echo "[UNORDERED] out-of-order event times"
IP=203.0.113.30; IPB=203.0.113.31
{
    kline -1 22 $IP; kline -40 80 $IP; kline -2 443 $IP; kline -3 3306 $IP; kline 0 8080 $IP
    kline 0 22 $IPB; kline -3 80 $IPB; kline -1 443 $IPB; kline -2 3306 $IPB; kline -3 8080 $IPB
} > "$FX/unordered"
run_arm UNORDERED file "$FX/unordered"
if arm_complete UNORDERED; then
    not_banned UNORDERED $IP && ok "UNORDERED: first/last span 1 s but min/max span 40 s -> not strobe, not banned" \
        || no "UNORDERED: array-order span used (FALSE strobe)" "$(witness UNORDERED)"
    banned_as UNORDERED $IPB strobe && ok "UNORDERED: out-of-order burst within 3 s -> strobe" || no "UNORDERED: burst missed" "$(witness UNORDERED)"
fi

# ---------------------------------------------------------------------------
# SHADOW-PARITY — the Go request carries the real, eligible event times.
# ---------------------------------------------------------------------------
echo; echo "[SHADOW-PARITY] Go classifier request carries event times"
IP=203.0.113.40
{ kline -3600 9999 $IP; kline -40 22 $IP; kline -30 80 $IP; kline -20 443 $IP; kline -10 3306 $IP; kline 0 8080 $IP; } > "$FX/shadow"
mkdir -p "$WORK/SHADOW"; : > "$WORK/SHADOW/use_core_stub"
run_arm SHADOW file "$FX/shadow"
if arm_complete SHADOW; then
    req=""; [[ -f "$WORK/SHADOW/go.req" ]] && req=$(<"$WORK/SHADOW/go.req")
    if [[ "$req" == *"\"ip\":\"$IP\""* ]]; then
        ok "SHADOW: precondition — Go request captured for $IP"
        got=$({ grep -oE '"ts":[0-9]+' <<< "$req" || true; } | sed 's/"ts"://' | sort -n | tr '\n' ' ')
        want=$(printf '%s\n' $((NOW-40)) $((NOW-30)) $((NOW-20)) $((NOW-10)) "$NOW" | sort -n | tr '\n' ' ')
        [[ "$got" == "$want" ]] && ok "SHADOW: request ts == fixture event times (stale excluded)" || no "SHADOW: request ts wrong" "got=[$got] want=[$want]"
    else
        no "SHADOW: Go request not captured — NOT_EXECUTED" "$req"
    fi
fi

# ---------------------------------------------------------------------------
# MALFORMED-TIME — no parseable event time: excluded (never re-stamped with
# now), enough lines to cross block/vertical/strobe and horizontal thresholds.
# ---------------------------------------------------------------------------
echo; echo "[MALFORMED-TIME] unparseable event time is excluded, never 'now'"
M1=203.0.113.50; M2=203.0.113.51
{
    for i in $(seq 1 13); do rawline "Sep 99 10:00:00 " $((4000 + i)) $M1; done
    for i in $(seq 14 25); do rawline "" $((4000 + i)) $M1; done
    for t in 11 12 13 14 15 16; do rawline "" 22 $M2 "198.51.100.$t"; done
} > "$FX/malformed"
run_arm MALFORMED file "$FX/malformed"
if arm_complete MALFORMED; then
    not_banned MALFORMED $M1 && ok "MALFORMED: 25 ports without event time -> no block/vertical/strobe ban" || no "MALFORMED: banned on processing time" "$(witness MALFORMED)"
    not_banned MALFORMED $M2 && ok "MALFORMED: 6 targets without event time -> no horizontal ban" || no "MALFORMED: horizontal ban on processing time" "$(witness MALFORMED)"
    modlog_has MALFORMED "malformed=31" && ok "MALFORMED: exclusion visible (malformed=31)" \
        || no "MALFORMED: exclusion not reported" "$(grep -F PORTSCAN_EVENT_TIME "$WORK/MALFORMED/log/portscan-classic.log" 2>/dev/null || true)"
    ev=0; [[ -f "$WORK/MALFORMED/log/portscan-events.log" ]] && ev=$(grep -c 'src=' "$WORK/MALFORMED/log/portscan-events.log" || true)
    [[ "$ev" == "31" ]] && ok "MALFORMED: micro-events still emitted (31) — aggregation input unchanged" || no "MALFORMED: micro-event emission changed" "ev=$ev"
fi

# ---------------------------------------------------------------------------
# FUTURE-TIME — event time > processing now is excluded; ts == now counts.
# ---------------------------------------------------------------------------
echo; echo "[FUTURE-TIME] +1 s future excluded; == now eligible"
F1=203.0.113.60; F0=203.0.113.61
{
    kline 1 22 $F1; kline 1 80 $F1; kline 2 443 $F1; kline 2 3306 $F1; kline 3 8080 $F1
    kline 0 22 $F0; kline 0 80 $F0; kline 0 443 $F0; kline 0 3306 $F0; kline 0 8080 $F0
} > "$FX/future"
run_arm FUTURE file "$FX/future"
if arm_complete FUTURE; then
    not_banned FUTURE $F1 && ok "FUTURE: future-dated strobe (+1..+3 s) not banned" || no "FUTURE: future evidence enforced" "$(witness FUTURE)"
    banned_as FUTURE $F0 strobe && ok "FUTURE: boundary ts == now eligible -> strobe" || no "FUTURE: ts == now excluded" "$(witness FUTURE)"
    modlog_has FUTURE "future=5" && ok "FUTURE: exclusion visible (future=5)" \
        || no "FUTURE: exclusion not reported" "$(grep -F PORTSCAN_EVENT_TIME "$WORK/FUTURE/log/portscan-classic.log" 2>/dev/null || true)"
fi

echo; echo "================================================================="
echo "Results: PASS=$PASS  FAIL=$FAIL"
if (( FAIL > 0 )); then
    echo "Failed:"; for t in "${FAILED[@]}"; do echo "  - $t"; done
    exit 1
fi
echo "All tests passed."
exit 0
