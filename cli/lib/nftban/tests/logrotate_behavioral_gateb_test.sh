#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.222.0 — behavioral active-writer rotation test (R10)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="logrotate_behavioral_gateb_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-19"
# meta:description="Behavioral rotation test using the REAL logrotate binary (NOT -d parse-only) against active writers — the class of test the audit noted would have caught the eve-USR2 regression. FAIL-CLOSED: if logrotate is unavailable it FAILS (never silently skips a safety proof). Proves: copytruncate keeps a HELD-FD (daemon/Suricata-style) writer on the live inode across rotation (record before -> rotated file, record after -> active file, no leak); rename+create keeps a per-message-reopen (bans.log-style) writer landing in the freshly-created file with correct mode; tail -F follows across a rename+create rotation without losing records; and a second rotation is idempotent."
# meta:input="None (temp logs + generated logrotate configs; runs real logrotate -f)"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure or missing logrotate"
# meta:depends="bash,logrotate,stat,grep,tail"
# meta:inventory.files=""
# meta:inventory.binaries="logrotate,stat,grep,tail"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (writes only under a temp dir)"
# meta:ta.id="logrotate_behavioral_gateb_test"
# meta:ta.owner="health"
# meta:ta.module="logrotate"
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
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  PASS: %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL: %s\n' "$1${2:+ — $2}"; }

# FAIL-CLOSED: this is a safety proof; without logrotate we cannot prove rotation.
if ! command -v logrotate >/dev/null 2>&1; then
    echo "FAIL: behavioral rotation test requires logrotate — refusing to pass without proving rotation (fail-closed)."
    exit 1
fi
set +e

me="$(id -un) $(id -gn)"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
LOGDIR="$WORK/log"; mkdir -p "$LOGDIR"
STATE="$WORK/lr.state"
rotate(){ logrotate -f -s "$STATE" "$1" >/dev/null 2>&1; }

echo "== copytruncate: held-fd (daemon/Suricata-style) writer stays on the live inode =="
CT="$LOGDIR/ct.log"; : > "$CT"
exec 8>>"$CT"                 # held append fd, as a long-lived daemon holds its log fd
printf 'RECORD_A_ct\n' >&8
cat > "$WORK/ct.conf" <<EOF
$CT {
    rotate 3
    missingok
    notifempty
    copytruncate
    create 0640 $me
}
EOF
rotate "$WORK/ct.conf"
printf 'RECORD_B_ct\n' >&8    # daemon keeps writing via the SAME fd after rotation
exec 8>&-
grep -q RECORD_A_ct "$CT.1"                 && ok "copytruncate: pre-rotation record in rotated .1" || no "A not in .1"
grep -q RECORD_B_ct "$CT"                   && ok "copytruncate: post-rotation record in ACTIVE file (held fd not stranded)" || no "B not in active"
grep -q RECORD_B_ct "$CT.1" 2>/dev/null     && no "copytruncate: post-rotation record leaked into rotated .1" || ok "copytruncate: no leak into .1"

echo "== rename+create: per-message-reopen (bans.log-style) writer + tail -F continuity =="
RC="$LOGDIR/rc.log"; : > "$RC"
appendrc(){ printf '%s\n' "$1" >> "$RC"; }  # open-append-close per message => reopens the path
appendrc RECORD_A_rc
cat > "$WORK/rc.conf" <<EOF
$RC {
    rotate 3
    missingok
    notifempty
    create 0640 $me
}
EOF
FOLLOW="$WORK/follow.out"; : > "$FOLLOW"
tail -F "$RC" > "$FOLLOW" 2>/dev/null &
tpid=$!
sleep 0.4
rotate "$WORK/rc.conf"        # rename+create: RC -> RC.1, fresh RC created
appendrc RECORD_B_rc         # per-message reopen => lands in the NEW active file
sleep 0.6
kill "$tpid" 2>/dev/null || true; wait "$tpid" 2>/dev/null
grep -q RECORD_A_rc "$RC.1"                 && ok "rename+create: pre-rotation record in rotated .1" || no "A not in .1"
grep -q RECORD_B_rc "$RC"                   && ok "rename+create: post-rotation record in the freshly-created active file" || no "B not in active"
grep -q RECORD_B_rc "$RC.1" 2>/dev/null     && no "rename+create: post-rotation record leaked into rotated .1" || ok "rename+create: no leak into .1"
grep -q RECORD_A_rc "$FOLLOW" && grep -q RECORD_B_rc "$FOLLOW" && ok "tail -F followed across rename+create (both records seen)" || no "tail -F lost continuity across rotation"
[ "$(stat -c '%a' "$RC" 2>/dev/null)" = "640" ] && ok "rename+create: new active file recreated with mode 0640" || no "create mode not reproduced" "$(stat -c '%a' "$RC" 2>/dev/null)"

echo "== second rotation is idempotent (writer keeps going) =="
rotate "$WORK/rc.conf"
appendrc RECORD_C_rc
grep -q RECORD_C_rc "$RC" && ok "second rotation: writer continues in the current file" || no "second rotation broke the writer"

echo
echo "======================================================================"
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
