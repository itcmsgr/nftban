#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.235 - LoginMon classic: the journal cursor follows successful processing
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="login_classic_cursor_after_success_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-07"
# meta:description="BUG-LOGINMON-CLASSIC-TMPFS-CURSOR-COMMIT-BEFORE-PROCESS-NO-RESPAWN part (a) (v1.235, owner 2026-10-07: the cursor is saved only after the required processing SUCCEEDED). Drives the REAL _nftban_login_classic_monitor_journal (core/nftban_login_classic.sh) against a stub journalctl that prints JSON entries with __CURSOR, and a stub _nftban_login_classic_process_message that fails for messages containing FAILME. All roots (NFTBAN_RUN_DIR, NFTBAN_LIB_DIR) point into a sandbox. Arms: C1 every entry succeeds -> cursor = last entry; C2 the last entry fails -> cursor stays at the previous entry (a crash now replays the failed entry); C3 an entry without MESSAGE after a success -> cursor advances to it (nothing to process); C4 a failure followed by a success -> cursor = the later entry (documented: the cursor is one position, not a queue; no in-run retry); C5 a failed entry logs a WARN. Regression test only; the row's other parts (tmpfs cursor, no respawn) are not covered. Set LOGIN_CC_SUBJECT_ROOT to an older tree (e.g. origin/main 7d8381b8): C2 and C5 FAIL there."
# meta:inventory.files="cli/lib/nftban/core/nftban_login_classic.sh"
# meta:inventory.binaries="bash,jq,mktemp"
# meta:inventory.env_vars="LOGIN_CC_SUBJECT_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
# meta:ta.id="login_classic_cursor_after_success_v1235_test"
# meta:ta.owner="loginmon"
# meta:ta.module="loginmon-classic-cursor"
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
IFS=$'\n\t'
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$TEST_DIR/../../../.." && pwd)"
ROOT="${LOGIN_CC_SUBJECT_ROOT:-$REPO}"
LIB="$ROOT/cli/lib/nftban"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "=== v1.235: LoginMon classic journal cursor follows successful processing ==="
command -v jq >/dev/null 2>&1 || { echo "  NOT_EXECUTED: jq not installed"; echo "RESULT: NOT_EXECUTED"; exit 3; }
[[ -f "$LIB/core/nftban_login_classic.sh" ]] \
    || { echo "  NOT_EXECUTED: subject file missing under $ROOT"; echo "RESULT: NOT_EXECUTED"; exit 3; }

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/bin" "$SB/run" "$SB/lib/lib"
# Stub journalctl: prints the entries listed (one JSON object per line) in $SB/entries.
cat > "$SB/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
cat "$SBX/entries"
EOF
chmod +x "$SB/bin/journalctl"

# run_arm <entries...>: each entry is "cursor|message" ("-" = no MESSAGE field).
# Prints the saved cursor (or NONE) on stdout; WARN log lines go to $SB/log.
run_arm() {
    : > "$SB/entries"; : > "$SB/log"; rm -f "$SB/run/"login-journal-cursor*
    local e c m
    for e in "$@"; do
        c="${e%%|*}"; m="${e#*|}"
        if [[ "$m" == "-" ]]; then jq -cn --arg c "$c" '{__CURSOR:$c}' >> "$SB/entries"
        else jq -cn --arg c "$c" --arg m "$m" '{__CURSOR:$c, MESSAGE:$m}' >> "$SB/entries"; fi
    done
    env -i PATH="$SB/bin:/usr/bin:/bin" SBX="$SB" HOME="$SB" \
        NFTBAN_RUN_DIR="$SB/run" NFTBAN_LIB_DIR="$SB/lib" NFTBAN_CONFIG_DIR="$SB/etc" \
        bash -c '
            set -uo pipefail
            nftban_login_log() { echo "$1 $2" >> "$SBX/log"; }
            source "$1"
            _nftban_login_classic_process_message() { [[ "$2" != *FAILME* ]]; }
            _nftban_login_classic_monitor_journal ssh sshd "Failed" "Invalid" >/dev/null 2>&1 || true
        ' _ "$LIB/core/nftban_login_classic.sh"
    if [[ -f "$SB/run/login-journal-cursor.ssh" ]]; then cat "$SB/run/login-journal-cursor.ssh"; else echo NONE; fi
}

got=$(run_arm "c1|ok one" "c2|ok two")
[[ "$got" == "c2" ]] && ok "C1 all entries processed -> cursor = last entry (c2)" || no "C1 all succeed" "cursor=$got"

got=$(run_arm "c1|ok one" "c2|FAILME two")
[[ "$got" == "c1" ]] && ok "C2 last entry FAILED -> cursor stays at c1 (a crash now replays c2)" || no "C2 failed entry advanced the cursor" "cursor=$got"

got=$(run_arm "c1|ok one" "c2|-")
[[ "$got" == "c2" ]] && ok "C3 entry without MESSAGE (nothing to process) -> cursor advances to c2" || no "C3 no-message entry" "cursor=$got"

got=$(run_arm "c1|FAILME one" "c2|ok two")
[[ "$got" == "c2" ]] && ok "C4 failure then success -> cursor = c2 (one position, not a queue: no in-run retry)" || no "C4 failure then success" "cursor=$got"

run_arm "c1|FAILME one" >/dev/null
grep -q "^WARN .*processing failed" "$SB/log" && ok "C5 a failed entry is logged (WARN), never silent" || no "C5 no WARN for a failed entry"

echo ""
echo "RESULT: $([[ $FAIL -eq 0 ]] && echo PASS || echo FAIL) (pass=$PASS fail=$FAIL)"
[[ $FAIL -eq 0 ]]
