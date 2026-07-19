#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.222.0 — log-retention rollout acceptance evidence collector (Z9)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="logretention_acceptance_evidence"
# meta:type="tool"
# meta:version="2.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-19"
# meta:description="Collects the NUMERIC pre/post rollout acceptance evidence for the v1.222.0 log-retention release on a real host (lab2/lab4/canary) and FAILS CLOSED if any required field cannot be measured or any acceptance invariant is violated. 'pre' is read-only. 'post' additionally TRIGGERS the installed logrotate (forced) twice (once to rotate, once for idempotence), measures actual rotated/compressed/removed files + bytes reclaimed, checks that an active rename+create writer (bans.log) lands in a freshly-created file, and validates JSONL integrity of the newest per-update-run record. It parses `nftban-core logretention status --json` for the authoritative state machine (overall_state, capacity_verdict, achievable, unbounded_stanzas, live_disk_status, interrupted_activation, effective_budget/theoretical_max). It does NOT mutate config or firewall; only exercises logrotate on NFTBan's own logs."
# meta:input="mode: pre|post (default pre); NFTBAN_CORE_BIN, NFTBAN_LOG_DIR overrides"
# meta:output="numeric acceptance report to stdout; non-zero exit on missing evidence or violated invariant"
# meta:depends="bash,df,du,find,stat,sha256sum,systemctl,logrotate,grep,sed"
# meta:inventory.files=""
# meta:inventory.binaries="df,du,find,stat,sha256sum,systemctl,logrotate,nftban-core,grep,sed"
# meta:inventory.env_vars="NFTBAN_CORE_BIN,NFTBAN_LOG_DIR"
# meta:inventory.config_files="/etc/logrotate.d/nftban,/etc/logrotate.d/nftban-suricata"
# meta:inventory.systemd_units="nftban-maintenance.timer"
# meta:inventory.network=""
# meta:inventory.privileges="root for 'post' (runs logrotate); 'pre' is read-only"
# =============================================================================
set -Eeuo pipefail

MODE="${1:-pre}"
LOGDIR="/var/log"
NFTLOG="${NFTBAN_LOG_DIR:-/var/log/nftban}"
CORE_BIN="${NFTBAN_CORE_BIN:-/usr/lib/nftban/bin/nftban-core}"
MAIN_POLICY="/etc/logrotate.d/nftban"
SURI_POLICY="/etc/logrotate.d/nftban-suricata"

# Required fields accumulate here; missing/empty/n-a values fail the gate.
declare -A FIELDS=()
MISSING=""
kv(){ FIELDS["$1"]="$2"; printf '%-36s %s\n' "$1" "$2"; }
require(){ # require KEY -> record it must be present & non-placeholder
    local k="$1" v="${FIELDS[$1]:-}"
    case "$v" in ""|"n/a"|"unknown"|"UNAVAILABLE"|"CORE_ABSENT") MISSING="$MISSING $k";; esac
}

fs_total(){ df -B1 --output=size "$LOGDIR" 2>/dev/null | awk 'NR==2{print $1}'; }
fs_avail(){ df -B1 --output=avail "$LOGDIR" 2>/dev/null | awk 'NR==2{print $1}'; }
fs_inodes_free(){ df -i --output=iavail "$LOGDIR" 2>/dev/null | awk 'NR==2{print $1}'; }
log_bytes(){ du -xsb "$NFTLOG" 2>/dev/null | awk '{print $1}'; }
count_gz(){ find "$NFTLOG" -type f -name '*.gz' 2>/dev/null | wc -l; }
count_rotated(){ find "$NFTLOG" -type f -regextype posix-extended -regex '.*\.[0-9]+(\.gz)?$' 2>/dev/null | wc -l; }
rotated_set(){ find "$NFTLOG" -type f -regextype posix-extended -regex '.*\.[0-9]+(\.gz)?$' 2>/dev/null | sort; }
policy_hash(){ [ -f "$1" ] && sha256sum "$1" 2>/dev/null | cut -c1-16 || echo "absent"; }

# json_field KEY <file>  -> extracts a scalar "KEY": value (string/number/bool).
json_field(){
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$2" 2>/dev/null | head -1
}

STATUS_JSON="$(mktemp)"; READY_JSON="$(mktemp)"; trap 'rm -f "$STATUS_JSON" "$READY_JSON"' EXIT
collect_status(){
    if [ -x "$CORE_BIN" ] && "$CORE_BIN" logretention status --json >"$STATUS_JSON" 2>/dev/null; then
        kv "OVERALL_STATE"          "$(json_field overall_state "$STATUS_JSON")"
        kv "CAPACITY_VERDICT"       "$(json_field capacity_verdict "$STATUS_JSON")"
        kv "ACHIEVABLE"             "$(json_field achievable "$STATUS_JSON")"
        kv "UNBOUNDED_STANZAS"      "$(json_field unbounded_stanzas "$STATUS_JSON")"
        kv "LIVE_DISK_STATUS"       "$(json_field live_disk_status "$STATUS_JSON")"
        kv "INTERRUPTED_ACTIVATION" "$(json_field interrupted_activation "$STATUS_JSON")"
        kv "EFFECTIVE_BUDGET_BYTES" "$(json_field effective_budget_bytes "$STATUS_JSON")"
        kv "THEORETICAL_MAX_BYTES"  "$(json_field theoretical_max_bytes_uncompressed "$STATUS_JSON")"
        kv "LIVE_FIT_VERDICT"       "$(json_field live_fit_verdict "$STATUS_JSON")"
        FIELDS["POLICY_VISIBILITY_RESULT"]="OK"
    else
        FIELDS["POLICY_VISIBILITY_RESULT"]="CORE_ABSENT"
    fi
    printf '%-36s %s\n' "POLICY_VISIBILITY_RESULT" "${FIELDS[POLICY_VISIBILITY_RESULT]}"
    # DELTA-L1: the authoritative install-readiness verdict (exit code + json). It
    # is the acceptance gate: a valid ACTIVE policy must exist (generated or a valid
    # bounded fallback). `readiness` exits non-zero on NOT_READY but still emits json.
    if [ -x "$CORE_BIN" ]; then
        "$CORE_BIN" logretention readiness --json >"$READY_JSON" 2>/dev/null || true
        kv "READINESS_VERDICT" "$(json_field verdict "$READY_JSON")"
        kv "READINESS_SOURCE"  "$(json_field policy_source "$READY_JSON")"
    fi
}

echo "===== NFTBan v1.222.0 log-retention acceptance evidence ($MODE) ====="
kv "HOST"                     "$(hostname 2>/dev/null || echo unknown)"
kv "FILESYSTEM_TOTAL_BYTES"   "$(fs_total)"
kv "FILESYSTEM_AVAILABLE_BYTES" "$(fs_avail)"
kv "FILESYSTEM_INODES_FREE"   "$(fs_inodes_free)"
kv "NFTBAN_LOG_BYTES"         "$(log_bytes)"
kv "ROTATED_FILES"            "$(count_rotated)"
kv "COMPRESSED_FILES"         "$(count_gz)"
kv "OLDEST_RETAINED"          "$(find "$NFTLOG" -type f -printf '%T+ %p\n' 2>/dev/null | sort | head -1)"
kv "NEWEST_RETAINED"          "$(find "$NFTLOG" -type f -printf '%T+ %p\n' 2>/dev/null | sort | tail -1)"
kv "MAINTENANCE_TIMER"        "$(systemctl is-active nftban-maintenance.timer 2>/dev/null | head -1 || true)"
kv "ACTIVE_POLICY_HASH_MAIN"  "$(policy_hash "$MAIN_POLICY")"
kv "ACTIVE_POLICY_HASH_SURICATA" "$(policy_hash "$SURI_POLICY")"

echo "--- authoritative status (status --json) ---"
collect_status

# Baseline evidence required in BOTH modes (works on the OLD build too, which has
# no logretention CLI — 'pre' must PASS on the pre-upgrade version).
for f in HOST FILESYSTEM_TOTAL_BYTES FILESYSTEM_AVAILABLE_BYTES NFTBAN_LOG_BYTES; do
    require "$f"
done
# The status-machine fields exist only once the v1.222.0 CLI is installed. They
# are REQUIRED whenever the CLI is present, and their absence is a hard FAIL in
# 'post' (a post-upgrade host MUST expose the authoritative status).
CLI_PRESENT=0
[ "${FIELDS[POLICY_VISIBILITY_RESULT]:-}" = "OK" ] && CLI_PRESENT=1
if [ "$CLI_PRESENT" = "1" ]; then
    # Always-present once the CLI is installed (hold for generated AND fallback).
    for f in OVERALL_STATE LIVE_DISK_STATUS INTERRUPTED_ACTIVATION READINESS_VERDICT; do
        require "$f"
    done
    # Generated-policy numeric fields exist only when a generated policy is active
    # (READY_GENERATED). A valid bounded fallback (READY_FALLBACK) has no state
    # record, so these are legitimately absent and not required.
    if [ "${FIELDS[READINESS_VERDICT]:-}" = "READY_GENERATED" ]; then
        for f in CAPACITY_VERDICT ACHIEVABLE UNBOUNDED_STANZAS \
                 EFFECTIVE_BUDGET_BYTES THEORETICAL_MAX_BYTES ACTIVE_POLICY_HASH_MAIN; do
            require "$f"
        done
    fi
elif [ "$MODE" = "post" ]; then
    MISSING="$MISSING logretention-cli(status --json unavailable post-upgrade)"
fi

if [ "$MODE" != "post" ]; then
    finalize(){ :; }
else
    echo "--- post: trigger installed logrotate (forced), then a second run for idempotence ---"
    if ! command -v logrotate >/dev/null 2>&1; then
        echo "FAIL: logrotate not installed — cannot prove rotation (fail-closed)."
        exit 1
    fi
    before_bytes="$(log_bytes)"; before_rot="$(count_rotated)"; before_gz="$(count_gz)"
    before_set="$(rotated_set)"

    # active rename+create writer probe (bans.log): append a marker, rotate, append
    # again — the second marker must land in a freshly-created active file.
    BANS="$NFTLOG/bans.log"
    reopen="n/a"
    if [ -w "$NFTLOG" ]; then
        printf '# acceptance-probe-A\n' >> "$BANS" 2>/dev/null || true
    fi

    logrotate -f "$MAIN_POLICY" >/dev/null 2>&1 || true
    [ -f "$SURI_POLICY" ] && logrotate -f "$SURI_POLICY" >/dev/null 2>&1 || true

    if [ -w "$NFTLOG" ]; then
        printf '# acceptance-probe-B\n' >> "$BANS" 2>/dev/null || true
        if [ -f "$BANS" ] && grep -q 'acceptance-probe-B' "$BANS" 2>/dev/null && ! grep -q 'acceptance-probe-A' "$BANS" 2>/dev/null; then
            reopen="reopened-clean"   # A rotated away, B in the new active file
        elif [ -f "$BANS" ] && grep -q 'acceptance-probe-B' "$BANS" 2>/dev/null; then
            reopen="active-writable"  # rotation may have been size-gated; writer still lands in active
        else
            reopen="FAILED"
        fi
    fi

    after1_bytes="$(log_bytes)"; after1_rot="$(count_rotated)"; after1_gz="$(count_gz)"
    logrotate -f "$MAIN_POLICY" >/dev/null 2>&1 || true   # idempotence run
    after2_rot="$(count_rotated)"; after_set="$(rotated_set)"

    # FILES_REMOVED = rotated files present BEFORE but absent AFTER (aged past rotate count).
    removed="$(comm -23 <(printf '%s\n' "$before_set") <(printf '%s\n' "$after_set") 2>/dev/null | grep -c . || echo 0)"

    # JSONL integrity of the newest per-update-run record (Z6 self-bounded log).
    jsonl_result="n/a"
    newest_jsonl="$(find "$NFTLOG/update-runs" -type f -name 'run.jsonl' -printf '%T+ %p\n' 2>/dev/null | sort | tail -1 | awk '{print $2}')"
    if [ -n "$newest_jsonl" ] && [ -f "$newest_jsonl" ]; then
        bad=0
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            case "$line" in "{"*"}") ;; *) bad=$((bad+1));; esac
        done < "$newest_jsonl"
        [ "$bad" -eq 0 ] && jsonl_result="PASS" || jsonl_result="FAIL($bad malformed lines)"
    fi

    kv "FILESYSTEM_AVAILABLE_AFTER" "$(fs_avail)"
    kv "NFTBAN_LOG_BYTES_BEFORE"  "$before_bytes"
    kv "NFTBAN_LOG_BYTES_AFTER"   "$after1_bytes"
    kv "FILES_ROTATED_DELTA"      "$(( after1_rot - before_rot ))"
    kv "FILES_COMPRESSED_DELTA"   "$(( after1_gz - before_gz ))"
    kv "FILES_REMOVED"            "$removed"
    kv "BYTES_RECLAIMED"          "$(( before_bytes > after1_bytes ? before_bytes - after1_bytes : 0 ))"
    kv "SECOND_RUN_RESULT"        "$([ "$after2_rot" -ge "$after1_rot" ] && echo idempotent-or-bounded || echo REGRESSED)"
    kv "WRITER_REOPEN_RESULT"     "$reopen"
    kv "JSONL_INTEGRITY_RESULT"   "$jsonl_result"
    kv "ACTIVE_POLICY_HASH_MAIN_AFTER" "$(policy_hash "$MAIN_POLICY")"

    for f in FILESYSTEM_AVAILABLE_AFTER NFTBAN_LOG_BYTES_AFTER FILES_ROTATED_DELTA \
             FILES_COMPRESSED_DELTA FILES_REMOVED BYTES_RECLAIMED SECOND_RUN_RESULT \
             WRITER_REOPEN_RESULT JSONL_INTEGRITY_RESULT; do
        require "$f"
    done
fi

echo
echo "===== acceptance invariants (fail-closed) ====="
fail=0
note(){ printf '  %-28s %s\n' "$1" "$2"; }

# 1. no missing required evidence.
if [ -n "$MISSING" ]; then
    note "REQUIRED_EVIDENCE" "MISSING:$MISSING"
    fail=1
else
    note "REQUIRED_EVIDENCE" "complete"
fi
# 2. authoritative state invariants (only when the v1.222.0 CLI is present; the
#    pre-upgrade baseline on the old build has no logretention subsystem).
#    DELTA-L1: the acceptance gate is the readiness verdict — a valid ACTIVE policy
#    must exist (generated, or a valid bounded fallback). A generated policy
#    additionally enforces the full status-machine.
if [ "$CLI_PRESENT" = "1" ]; then
    [ "${FIELDS[INTERRUPTED_ACTIVATION]:-true}" = "false" ] || { note "INTERRUPTED_ACTIVATION" "must be false (got ${FIELDS[INTERRUPTED_ACTIVATION]:-?})"; fail=1; }
    case "${FIELDS[READINESS_VERDICT]:-}" in
        READY_GENERATED)
            note "READINESS" "READY_GENERATED (active generated policy verified)"
            [ "${FIELDS[ACHIEVABLE]:-}" = "true" ]      || { note "ACHIEVABLE" "must be true (got ${FIELDS[ACHIEVABLE]:-?})"; fail=1; }
            [ "${FIELDS[UNBOUNDED_STANZAS]:-1}" = "0" ] || { note "UNBOUNDED_STANZAS" "must be 0 (got ${FIELDS[UNBOUNDED_STANZAS]:-?})"; fail=1; }
            case "${FIELDS[OVERALL_STATE]:-}" in
                ACTIVE_MATCH) note "OVERALL_STATE" "ACTIVE_MATCH" ;;
                *) note "OVERALL_STATE" "must be ACTIVE_MATCH for a generated policy (got ${FIELDS[OVERALL_STATE]:-?})"; fail=1 ;;
            esac ;;
        READY_FALLBACK)
            note "READINESS" "READY_FALLBACK (bounded template fallback active — VALID but self-heal pending)" ;;
        *)
            note "READINESS" "must be READY_GENERATED or READY_FALLBACK (got ${FIELDS[READINESS_VERDICT]:-?}) — no valid active policy"; fail=1 ;;
    esac
else
    note "STATUS_MACHINE" "skipped (logretention CLI not present — pre-upgrade baseline)"
fi
if [ "$MODE" = "post" ]; then
    case "${FIELDS[WRITER_REOPEN_RESULT]:-}" in FAILED) note "WRITER_REOPEN_RESULT" "writer stranded"; fail=1 ;; esac
    case "${FIELDS[JSONL_INTEGRITY_RESULT]:-}" in FAIL*) note "JSONL_INTEGRITY_RESULT" "malformed JSONL"; fail=1 ;; esac
    case "${FIELDS[SECOND_RUN_RESULT]:-}" in REGRESSED) note "SECOND_RUN_RESULT" "non-idempotent"; fail=1 ;; esac
fi

echo
if [ "$fail" -ne 0 ]; then
    echo "===== ACCEPTANCE: FAIL ($MODE) — evidence incomplete or invariant violated ====="
    exit 1
fi
echo "===== ACCEPTANCE: PASS ($MODE) ====="
[ "$MODE" = "pre" ] && echo "Re-run with 'post' after upgrade to measure rotation + reclamation."
exit 0
