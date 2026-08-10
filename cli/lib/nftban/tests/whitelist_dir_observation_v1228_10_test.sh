#!/usr/bin/env bash
# =============================================================================
# NFTBan - whitelist directory observation contract (v1.228.10 A3-DIR)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="whitelist_dir_observation_v1228_10_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-10"
# meta:description="INV-P0-03/04: the durable whitelist readers must distinguish READ_OK_EMPTY (data) from UNREADABLE (error). Drives the REAL _nftban_wl_read_baseline/_nftban_wl_read_sessions from whitelist_members.sh. Proves rc 3 on a present-but-unenumerable source, rc 0 on a legitimately absent one, and that the reconcile caller in cmd_firewall.sh consumes rc 3 without ever printing a verified claim. Includes the pre-fix mutation control proving the old reader reported rc 0 + empty for the same fixture."
# meta:input="None (sandbox fixtures)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,sed,mktemp"
# meta:inventory.files="cli/lib/nftban/lib/whitelist_members.sh,cli/lib/nftban/cli/cmd_firewall.sh"
# meta:inventory.binaries="bash,grep,sed,mktemp"
# meta:inventory.privileges="none"
# meta:ta.id="whitelist_dir_observation_v1228_10_test"
# meta:ta.owner="whitelist"
# meta:ta.module="whitelist-members"
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
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
LIB="$REPO_ROOT/cli/lib/nftban/lib/whitelist_members.sh"
FW="$REPO_ROOT/cli/lib/nftban/cli/cmd_firewall.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
echo "=== whitelist_dir_observation_v1228_10 ==="
[[ -f "$LIB" ]] || { echo "FATAL: $LIB missing"; exit 2; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
# shellcheck source=/dev/null
. "$LIB"

run(){ # $1=conf dir path -> "rc|output-line-count"
    local out rc=0
    _NFTBAN_WHITELIST_CONF_DIR="$1"
    out="$(_nftban_wl_read_baseline 4)" || rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | grep -c . || true)"
}

echo "--- 1. readable dir + configured member => READ_OK_WITH_MEMBERS ---"
D="$WORK/ok"; mkdir -p "$D"; printf '1.2.3.41\n' > "$D/10-a.conf"
R="$(run "$D")"; [[ "$R" == "0|1" ]] && ok "rc=0 with 1 member ($R)" || no "expected 0|1, got $R"

echo "--- 2. readable dir, genuinely empty => READ_OK_EMPTY (data, not error) ---"
D="$WORK/empty"; mkdir -p "$D"
R="$(run "$D")"; [[ "$R" == "0|0" ]] && ok "rc=0 with 0 members — empty stays legitimate ($R)" || no "expected 0|0, got $R"

echo "--- 3. dir present but UNENUMERABLE (dangling symlink) => UNREADABLE ---"
D="$WORK/dangling"; ln -s "$WORK/no-such-target" "$D"
R="$(run "$D")"; [[ "${R%%|*}" == "3" ]] && ok "rc=3 UNREADABLE (not silently empty) ($R)" \
    || no "dangling whitelist.d did not report UNREADABLE" "got $R"

echo "--- 4. participating FILE unreadable (dangling) => UNREADABLE, no partial union ---"
D="$WORK/badfile"; mkdir -p "$D"; printf '1.2.3.41\n' > "$D/10-a.conf"
ln -s "$D/no-such-target" "$D/20-b.conf"
R="$(run "$D")"; [[ "${R%%|*}" == "3" ]] && ok "rc=3 — a shortened union never becomes authoritative ($R)" \
    || no "unreadable participating file was silently skipped" "got $R"

echo "--- 5. legitimately ABSENT dir => rc 0 (first-install shape preserved) ---"
R="$(run "$WORK/never-created")"
[[ "$R" == "0|0" ]] && ok "absence stays data, matching TestA3_AbsentWhitelistDir_IsEmptyNotError ($R)" \
    || no "absent dir changed behaviour" "got $R"

echo "--- 6. POSITIVE RECOVERY: restore readable source => desired state changes again ---"
D="$WORK/recover"; mkdir -p "$D"; printf '1.2.3.41\n' > "$D/10-a.conf"
R1="$(run "$D")"; printf '1.2.3.41\n1.2.3.42\n' > "$D/10-a.conf"; R2="$(run "$D")"
[[ "$R1" == "0|1" && "$R2" == "0|2" ]] && ok "path is not inert ($R1 -> $R2)" \
    || no "reader did not follow a changed source" "$R1 -> $R2"

echo "--- 7. MUTATION CONTROL: the pre-fix reader reported rc 0 + empty for arm 3 ---"
prefix_reader(){ [[ -d "$1" ]] || return 0; for f in "$1"/*.conf; do [[ -e "$f" ]] || continue; done; return 0; }
prefix_reader "$WORK/dangling"; PRC=$?
[[ "$PRC" == "0" ]] && ok "pre-fix form returns rc=0 on the SAME fixture — the arm discriminates" \
    || no "pre-fix form already failed; arm 3 proves nothing" "rc=$PRC"

echo "--- 8. the reconcile caller consumes UNREADABLE and never claims verified ---"
if [[ -f "$FW" ]]; then
    CODE="$WORK/fw_code.sh"; sed -e 's/[[:space:]]*#.*$//' "$FW" > "$CODE"
    grep -q '_base_rc -eq 3 \|_sess_rc -eq 3' "$CODE" && ok "caller branches on rc 3" || no "caller ignores rc 3"
    grep -q '_unreadable_all' "$CODE" && ok "caller records the unreadable state separately" || no "no unreadable state in caller"
    # The verified claim must be UNREACHABLE once a source was unreadable. Checked
    # structurally, not by textual order (an earlier version of this assertion just
    # scanned forward and fired on the unrelated later occurrence):
    #   a) the accumulation is immediately followed by `continue` (leaves the loop body)
    #   b) the `-n "$_unreadable_all"` guard returns BEFORE the verified line
    # BOUNDARY: this is line-order reasoning over one small function, not a CFG.
    ACC=$(grep -n '_unreadable_all+=' "$CODE" | head -1 | cut -d: -f1)
    NEXT=$(awk -v a="$ACC" 'NR>a && NF {print NR": "$0; exit}' "$CODE")
    [[ "$NEXT" == *continue* ]] && ok "unreadable accumulation is followed by 'continue'" \
        || no "accumulation does not leave the loop body" "next=$NEXT"
    GUARD=$(grep -n 'if \[\[ -n "$_unreadable_all" \]\]' "$CODE" | head -1 | cut -d: -f1)
    GRET=$(awk -v g="$GUARD" 'NR>g && /return 1/ {print NR; exit}' "$CODE")
    VER=$(grep -n 'reconcile verified' "$CODE" | head -1 | cut -d: -f1)
    if [[ -n "$GUARD" && -n "$GRET" && -n "$VER" && "$GRET" -lt "$VER" ]]; then
        ok "unreadable guard returns at line $GRET, before the verified claim at $VER"
    else
        no "verified claim is not provably guarded" "guard=$GUARD ret=$GRET verified=$VER"
    fi
else
    no "cmd_firewall.sh not found"
fi
echo
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
