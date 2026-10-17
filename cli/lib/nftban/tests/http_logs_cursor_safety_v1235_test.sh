#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - incremental reader: a stat failure never moves the cursor; long keys persist
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="http_logs_cursor_safety_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-07"
# meta:description="BUG-HTTP-READ-INCREMENTAL-STAT-FAILURE-PERSISTS-0-0-TAIL-SKIP-AND-KEY-COLLISION parts (a), (b) and (c1). Drives the REAL nftban_http_read_incremental (lib/nftban_http_logs.sh) with a PATH stat stub. Arms: B1 a stat failure emits nothing, returns 0 and leaves the cursor file byte-identical (before: size=0 inode=0 persisted as 0:0); B2 the next normal read emits ONLY the lines appended since, in forward and in default (tail) mode - no replay from the beginning; C1 a path whose cursor key would exceed NAME_MAX now persists (key <= 200 bytes, deterministic): its lines are read once and the next read emits only new lines (before: the cursor and the .rd temp file names were too long, so such a log was never read at all); C2 an ordinary path keeps exactly its old key (no migration); P1 PortScan's backlog warning finds the cursor of such a long path (it uses the shared key); T-B0/T-Bm1/T-Bp1 (part a) the tail branch starts at a record start - exact boundary, boundary-1 and boundary+1 - every emitted line is a complete record and the skipped range is counted (NFTBAN_HTTP_TAIL_SKIPPED_BYTES + stderr). Set HCS_SUBJECT_ROOT to an older tree (e.g. origin/main before this change): B1, B2 and C1 FAIL there."
# meta:inventory.files="cli/lib/nftban/lib/nftban_http_logs.sh,cli/lib/nftban/core/nftban_portscan_classic.sh"
# meta:inventory.binaries="bash,stat,mktemp,sha256sum,grep"
# meta:inventory.env_vars="HCS_SUBJECT_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="http_logs_cursor_safety_v1235_test"
# meta:ta.owner="botscan"
# meta:ta.module="http-logs-reader"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
ROOT="${HCS_SUBJECT_ROOT:-$REPO}"
LIB="$ROOT/cli/lib/nftban"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235: incremental reader cursor safety (stat failure, long keys) ==="
[[ -f "$LIB/lib/nftban_http_logs.sh" ]] || { echo "  NOT_EXECUTED: subject missing"; echo "RESULT: NOT_EXECUTED"; exit 3; }

SB="$(mktemp -d)"; trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin"
REAL_STAT="$(command -v stat)"
# stat stub: fails while $SB/stat_fail exists, otherwise the real stat.
cat > "$SB/bin/stat" <<EOF
#!/usr/bin/env bash
[[ -e "$SB/stat_fail" ]] && { echo "stat: injected failure" >&2; exit 1; }
exec "$REAL_STAT" "\$@"
EOF
chmod 0755 "$SB/bin/stat"

# read <mode forward|tail> <file> -> stdout of one real reader call (fresh shell, real lib)
rd(){
    env PATH="$SB/bin:$PATH" NFTBAN_DATA_DIR="$SB" NFTBAN_HTTP_LOG_OFFSET_DIR="$SB/off_$1" \
        NFTBAN_HTTP_LOG_READ_FORWARD="$([[ "$1" == forward ]] && echo true || echo false)" \
        NFTBAN_HTTP_LOG_MAX_BYTES=1048576 LIB="$LIB" F="$2" bash -c '
        # shellcheck source=/dev/null
        source "$LIB/lib/nftban_http_logs.sh" >/dev/null 2>&1 || exit 9
        nftban_http_read_incremental "$F"; echo "RC=$?" >&2
    ' 2> "$SB/rd.err"
}
lines(){ printf 'line-%s\n' "$@"; }

for mode in forward tail; do
    f="$SB/access_${mode}.log"; lines 1 2 3 > "$f"
    out="$(rd "$mode" "$f")"
    [[ "$out" == "$(lines 1 2 3)" ]] || no "B0 ${mode}: first read" "$out"
    cur="$SB/off_$mode/$(env LIB="$LIB" F="$f" bash -c 'source "$LIB/lib/nftban_http_logs.sh" >/dev/null 2>&1; nftban_http_cursor_key "$F"')"
    sha0="$(sha256sum < "$cur" 2>/dev/null)"
    lines 4 5 >> "$f"
    : > "$SB/stat_fail"
    out="$(rd "$mode" "$f")"; rc="$(grep -o 'RC=[0-9]*' "$SB/rd.err")"
    rm -f "$SB/stat_fail"
    sha1="$(sha256sum < "$cur" 2>/dev/null)"
    if [[ -z "$out" && "$rc" == RC=0 && -n "$sha0" && "$sha0" == "$sha1" ]]; then
        ok "B1 ${mode}: stat failure -> nothing emitted, rc 0, cursor file byte-identical"
    else no "B1 ${mode}: stat failure moved the cursor or emitted" "out='${out//$'\n'/ }' $rc cursor_now='$(cat "$cur" 2>/dev/null)'"; fi
    out="$(rd "$mode" "$f")"
    [[ "$out" == "$(lines 4 5)" ]] && ok "B2 ${mode}: the next read emits ONLY the appended lines (no replay)" \
        || no "B2 ${mode}: replay or loss after the stat failure" "got '${out//$'\n'/ }'"
done

# T — part (a): the collector TAIL branch starts at a RECORD start, never mid-record, and the
# jumped range is counted. Fixed 20-byte records "R<18 digits>\n" x 50 = 1000 bytes; MAX is
# chosen so tail = size - MAX lands exactly where each arm needs it. No cursor yet (start 0).
tf="$SB/tail_src.log"; : > "$tf"; for i in $(seq 0 49); do printf 'R%018d\n' "$i" >> "$tf"; done
tail_arm(){ # <arm> <MAX> <expected first record index> <expected aligned offset>
    local arm="$1" max="$2" want="$3" al="$4" out first bad rep
    rm -rf "$SB/off_t_$arm"
    out="$(env PATH="$SB/bin:$PATH" NFTBAN_DATA_DIR="$SB" NFTBAN_HTTP_LOG_OFFSET_DIR="$SB/off_t_$arm" \
        NFTBAN_HTTP_LOG_READ_FORWARD=false NFTBAN_HTTP_LOG_MAX_BYTES="$max" LIB="$LIB" F="$tf" bash -c '
        source "$LIB/lib/nftban_http_logs.sh" >/dev/null 2>&1 || exit 9
        nftban_http_read_incremental "$F"; echo "SKIPPED=${NFTBAN_HTTP_TAIL_SKIPPED_BYTES:-unset}" >&2' 2>"$SB/t.err")"
    first="${out%%$'\n'*}"
    bad="$(grep -cvE '^R[0-9]{18}$' <<<"$out" || true)"
    rep="$(grep -o 'SKIPPED=[0-9a-z]*' "$SB/t.err")"
    if [[ "$first" == "$(printf 'R%018d' "$want")" && "$bad" == 0 && "$rep" == "SKIPPED=$al" ]] && grep -q "tail read skipped $al B" "$SB/t.err"; then
        ok "T-${arm}: first record #${want}, every line a complete record, skipped ${al} B reported"
    else no "T-${arm}" "first='${first}' incomplete_lines=${bad} ${rep:-no-counter} stderr='$(grep -m1 'tail read' "$SB/t.err")'"; fi
}
tail_arm B0   300 35 700    # tail=700, byte[699]=\n: already a record start, nothing more dropped
tail_arm Bm1  301 35 700    # tail=699 (the newline ending record 34): the next record start is 700
tail_arm Bp1  299 36 720    # tail=701 (one byte into record 35): record 35 is partial, dropped

# C1 — a path whose plain key ('/' -> '_') exceeds NAME_MAX.
long="$SB"; for i in 1 2 3 4 5 6 7; do long="$long/dir_with_a_fairly_long_name_number_$i"; done
mkdir -p "$long"; lf="$long/www.example.org.access.log"; lines 1 2 > "$lf"
plain="$(printf '%s' "$lf" | tr '/' '_')"
out1="$(rd forward "$lf")"; lines 3 >> "$lf"; out2="$(rd forward "$lf")"
key="$(env LIB="$LIB" F="$lf" bash -c 'source "$LIB/lib/nftban_http_logs.sh" >/dev/null 2>&1; nftban_http_cursor_key "$F"')"
if (( ${#plain} > 255 )) && [[ "$out1" == "$(lines 1 2)" && "$out2" == "$(lines 3)" && ${#key} -le 200 ]]; then
    ok "C1 key of ${#plain} bytes (> NAME_MAX) now persists as a ${#key}-byte key: the second read emits only the new line"
else no "C1 long-path cursor" "plain=${#plain} key=${#key} out2='${out2//$'\n'/ }'"; fi
key2="$(env LIB="$LIB" F="$lf" bash -c 'source "$LIB/lib/nftban_http_logs.sh" >/dev/null 2>&1; nftban_http_cursor_key "$F"')"
[[ "$key" == "$key2" ]] && ok "C1b the long key is deterministic" || no "C1b long key not deterministic"

# C2 — ordinary paths keep exactly their old key (no migration).
sf="/var/log/httpd/domains/www.example.org.log"
k="$(env LIB="$LIB" F="$sf" bash -c 'source "$LIB/lib/nftban_http_logs.sh" >/dev/null 2>&1; nftban_http_cursor_key "$F"')"
[[ "$k" == "$(printf '%s' "$sf" | tr '/' '_')" ]] && ok "C2 an ordinary path keeps its old key ($k)" || no "C2 ordinary key changed" "$k"
kn="$(env LIB="$LIB" F="$sf" NFTBAN_HTTP_CURSOR_NS=_botscan_spool_ bash -c 'source "$LIB/lib/nftban_http_logs.sh" >/dev/null 2>&1; nftban_http_cursor_key "$F"')"
[[ "$kn" == "_botscan_spool_www.example.org.log" ]] && ok "C2b a namespaced key is unchanged ($kn)" || no "C2b namespaced key changed" "$kn"

# P1 — PortScan's backlog WARN reads the cursor of a long path through the shared key.
if [[ -f "$LIB/core/nftban_portscan_classic.sh" ]]; then
    pd="$SB/pscur"; mkdir -p "$pd"; pl="$long/portscan.log"; lines 1 2 > "$pl"
    env NFTBAN_DATA_DIR="$SB" NFTBAN_HTTP_LOG_OFFSET_DIR="$pd" NFTBAN_HTTP_LOG_MAX_BYTES=1048576 LIB="$LIB" F="$pl" \
        bash -c 'source "$LIB/lib/nftban_http_logs.sh" >/dev/null 2>&1; nftban_http_read_incremental "$F" >/dev/null'
    head -c 4096 /dev/zero | tr '\0' 'x' >> "$pl"; echo >> "$pl"
    env NFTBAN_LIB_DIR="$LIB" NFTBAN_CONFIG_DIR="$SB/etc" NFTBAN_DATA_DIR="$SB" NFTBAN_LOG_DIR="$SB/log" \
        PORTSCAN_CLASSIC_MODULE_LOG="$SB/ps.log" PORTSCAN_CLASSIC_CURSOR_DIR="$pd" PORTSCAN_CLASSIC_CURSOR_MAX_BYTES=1024 \
        LIB="$LIB" F="$pl" bash -c '
        source "$LIB/lib/nftban_http_logs.sh" >/dev/null 2>&1
        source "$LIB/core/nftban_portscan_classic.sh" >/dev/null 2>&1
        _nftban_portscan_classic_warn_backlog "$F"' >/dev/null 2>&1
    grep -q 'backlog exceeds incremental read cap' "$SB/ps.log" 2>/dev/null \
        && ok "P1 PortScan backlog WARN finds the long path's cursor (shared key)" \
        || no "P1 PortScan backlog WARN silent for a long path (key mismatch)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if (( FAIL > 0 )); then echo "RESULT: FAIL"; exit 1; fi
echo "RESULT: PASS"
exit 0
