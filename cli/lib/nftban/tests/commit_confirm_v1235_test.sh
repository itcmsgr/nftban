#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.235 commit-confirm / automatic rollback engine
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="commit_confirm_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-06"
# meta:description="BEHAVIORAL regression for the repaired commit-confirm engine (contract NFTBAN_ROADMAP/CLI_AUDIT_V1235/ROW486_BEHAVIOUR_CONTRACT_V1235.md section 4; the pre-v1.235 mechanism was orphaned and restored by merging). Drives the REAL lib/commit_confirm.sh in a sandbox with stubbed nft, systemd-run and systemctl. Asserts: last-known-good is the APPLIED BASELINE recorded at a successful load; apply refuses without a baseline, while an apply is pending and while a rollback has failed; the rollback is ARMED (systemd-run) BEFORE any nft -f, and a failed arm leaves no record; the change set lists modified, added and removed config files; confirm commits the candidate projection by rename while the rollback is armed and only then records confirmed; a wrong apply ID and a passed deadline are refused; a failed publication keeps the apply pending; a crash after the commit point is completed (no rollback); rollback restores only the change set, leaves a file edited after the apply untouched and lists it as a conflict, never writes files outside the change set, and its single kernel transaction deletes only ip/ip6 nftban; a failed transaction KEEPS the kernel state, records rollback-failed with the verbatim error and the kernel fact, sets the marker and keeps all artifacts (owner D10); boot mode makes no nft call; abandon clears the marker."
# meta:input="None (self-contained sandbox; stubbed system tools)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,awk,grep,sed,tar,sha256sum,flock,join,mktemp"
# meta:inventory.files=""
# meta:inventory.binaries="bash,awk,grep,sed,tar,sha256sum,flock,join,mktemp"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_DATA_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="commit_confirm_v1235_test"
# meta:ta.owner="firewall"
# meta:ta.module="lifecycle"
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

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
LIBDIR="$REPO_ROOT/cli/lib/nftban"
CC="$LIBDIR/lib/commit_confirm.sh"

pass=0; fail=0
ok(){ echo "  [PASS] $1"; pass=$((pass+1)); }
ko(){ echo "  [FAIL] $1"; fail=$((fail+1)); }
has(){ grep -qF -- "$2" "$1" 2>/dev/null; }
has_line(){ grep -qxF -- "$2" "$1" 2>/dev/null; }

echo "==============================================="
echo "v1.235 commit-confirm engine"
echo "==============================================="
if [[ ! -f "$CC" ]]; then
    echo "  [FAIL] D0 commit-confirm engine (FAIL-BY-ABSENCE: cli/lib/nftban/lib/commit_confirm.sh missing)"
    echo "TOTAL: pass=0 fail=1"; exit 1
fi
for t in flock join tar sha256sum; do
    command -v "$t" >/dev/null 2>&1 || { echo "  NOT_EXECUTED: $t not installed"; echo "TOTAL: pass=0 fail=1"; exit 1; }
done

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
STUB="$SB/bin"; mkdir -p "$STUB"
cat > "$STUB/nft" <<'EOF'
#!/usr/bin/env bash
echo "nft $*" >> "$SBX/calls.log"
case "$*" in
    "list tables") printf 'table ip nftban\ntable ip6 nftban\ntable inet labforeign\n' ;;
    "list table ip nftban")  printf 'table ip nftban {\n\tset s { type ipv4_addr; }\n}\n' ;;
    "list table ip6 nftban") printf 'table ip6 nftban {\n}\n' ;;
    "-c -f "*) exit 0 ;;
    "-f "*) a="$*"; f="${a#-f }"; cp "$f" "$SBX/last_tx.nft"; exit "$(cat "$SBX/nft_f_rc" 2>/dev/null || echo 0)" ;;
esac
exit 0
EOF
cat > "$STUB/systemd-run" <<'EOF'
#!/usr/bin/env bash
echo "systemd-run $*" >> "$SBX/calls.log"
exit "$(cat "$SBX/sdrun_rc" 2>/dev/null || echo 0)"
EOF
cat > "$STUB/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$SBX/calls.log"
exit 0
EOF
cat > "$STUB/logger" <<'EOF'
#!/usr/bin/env bash
echo "logger $*" >> "$SBX/calls.log"
EOF
chmod +x "$STUB"/*

fresh(){
    rm -rf "${SB:?}/etc" "${SB:?}/data" "${SB:?}"/calls.log "${SB:?}"/nft_f_rc "${SB:?}"/sdrun_rc "${SB:?}"/last_tx.nft
    mkdir -p "$SB/etc/conf.d" "$SB/etc/ports.d" "$SB/etc/generated" "$SB/data/state"
    : > "$SB/calls.log"
    echo 'A=1' > "$SB/etc/conf.d/a.conf"
    echo '22/T/I' > "$SB/etc/ports.d/00-ssh.conf"
    echo 'KEEP=1' > "$SB/etc/conf.d/untouched.conf"
    echo 'old-projection' > "$SB/etc/generated/nftban-boot.nft"
    echo 'baseline-ruleset' > "$SB/loaded.nft"
}
cc(){  # snippet with the REAL engine loaded
    local rc=0
    env -i PATH="$STUB:/usr/bin:/bin" SBX="$SB" HOME="$SB" \
        NFTBAN_CONFIG_DIR="$SB/etc" NFTBAN_DATA_DIR="$SB/data" NFTBAN_LIB_DIR="$LIBDIR" \
        bash -c 'set -Eeuo pipefail; source "$1"; shift; eval "$1"' _ "$CC" "$1" > "$SB/cc.out" 2>&1 || rc=$?
    return "$rc"
}
REC="$SB/data/state/commit-confirm.state"
get(){ sed -n "s/^$1=//p" "$REC" 2>/dev/null; }
order_ok(){  # systemd-run logged before any "nft -f"
    awk '/^systemd-run /{if(!s) s=NR} /^nft -f /{if(!f) f=NR} END{exit !(s && (!f || s<f))}' "$SB/calls.log"
}
# Stage a pending apply exactly as the engine leaves it after `rebuild --confirm` loaded.
stage_pending(){  # deadline_offset_seconds
    cc 'cc_record_applied_baseline "'"$SB"'/loaded.nft"' || return 1
    echo 'A=2' > "$SB/etc/conf.d/a.conf"            # modified
    echo 'NEW=1' > "$SB/etc/conf.d/new.conf"        # added
    rm -f "$SB/etc/ports.d/00-ssh.conf"             # removed
    cc 'cc_apply_begin 120' || return 1
    echo 'candidate-projection' > "$SB/data/state/commit-confirm/candidate-projection.nft"
    echo 'candidate-ruleset' > "$SB/data/state/commit-confirm/candidate-ruleset.nft"
    local sha; sha=$(sha256sum "$SB/data/state/commit-confirm/candidate-projection.nft" | awk '{print $1}')
    sed -i "s/^candidate_projection_sha=.*/candidate_projection_sha=$sha/" "$REC"
    if [[ -n "${1:-}" ]]; then sed -i "s/^deadline_epoch=.*/deadline_epoch=$(( $(date -u +%s) + $1 ))/" "$REC"; fi
}

# ---- baseline + apply refusals
fresh
cc 'cc_record_applied_baseline "'"$SB"'/loaded.nft"' || true
if [[ -f "$SB/data/state/applied/manifest" && -f "$SB/data/state/applied/config/conf.d/a.conf" ]] \
   && has "$SB/data/state/applied/ruleset.nft" "baseline-ruleset" && has "$SB/data/state/applied/meta" "at="; then
    ok "D1 applied baseline recorded (config copy + manifest + ruleset + time)"
else ko "D1 applied baseline"; fi

fresh
rc=0; cc 'cc_apply_begin 120' || rc=$?
if [[ $rc -ne 0 ]] && has "$SB/cc.out" "no applied baseline" && [[ ! -e "$REC" ]] && ! has "$SB/calls.log" "systemd-run"; then
    ok "D2 apply refuses without an applied baseline (nothing armed, no record)"
else ko "D2 no-baseline refusal (rc=$rc)"; fi

fresh; stage_pending 120
if [[ "$(get status)" == "pending" && -n "$(get apply_id)" ]] && order_ok; then ok "D3 apply arms the rollback (systemd-run) and records pending"
else ko "D3 pending apply"; fi
if has "$SB/calls.log" "--on-active=120s" && has "$SB/calls.log" "firewall rollback $(get apply_id) --auto"; then ok "D4 rollback armed with the exact grace and the apply ID"
else ko "D4 rollback arming arguments"; fi
CS="$SB/data/state/commit-confirm/changeset"
if has "$CS" "./conf.d/a.conf" && has "$CS" "./conf.d/new.conf" && has "$CS" "./ports.d/00-ssh.conf" && ! has "$CS" "untouched.conf"; then
    ok "D5 change set = modified + added + removed files only"
else ko "D5 change set: $(cut -f1 "$CS" 2>/dev/null | tr '\n' ' ')"; fi
rc=0; cc 'cc_apply_begin 120' || rc=$?
if [[ $rc -ne 0 ]] && has "$SB/cc.out" "still pending"; then ok "D6 a second apply is refused while one is pending"
else ko "D6 pending refusal (rc=$rc)"; fi

fresh; cc 'cc_record_applied_baseline "'"$SB"'/loaded.nft"' || true; echo 1 > "$SB/sdrun_rc"; : > "$SB/calls.log"
rc=0; cc 'cc_apply_begin 120' || rc=$?
if [[ $rc -ne 0 && ! -e "$REC" ]] && has "$SB/cc.out" "could not be armed" && ! has "$SB/calls.log" "nft -f"; then
    ok "D7 arm failure aborts with nothing changed and no record"
else ko "D7 arm failure (rc=$rc)"; fi

fresh; cc 'cc_record_applied_baseline "'"$SB"'/loaded.nft"' || true; : > "$SB/data/state/commit-confirm.rollback-failed"
rc=0; cc 'cc_apply_begin 120' || rc=$?
if [[ $rc -ne 0 ]] && has "$SB/cc.out" "ROLLBACK FAILED"; then ok "D8 apply refused while a rollback has failed"
else ko "D8 rollback-failed refusal (rc=$rc)"; fi

# ---- confirm
fresh; stage_pending 120; ID=$(get apply_id)
rc=0; cc "cc_confirm WRONG-ID" || rc=$?
if [[ $rc -ne 0 && "$(get status)" == "pending" ]] && has "$SB/etc/generated/nftban-boot.nft" "old-projection"; then ok "D9 confirm with a wrong apply ID refused, nothing published"
else ko "D9 wrong ID (rc=$rc)"; fi
rc=0; cc "cc_confirm $ID" || rc=$?
if [[ $rc -eq 0 && "$(get status)" == "confirmed" ]] && has "$SB/etc/generated/nftban-boot.nft" "candidate-projection" \
   && has "$SB/data/state/applied/ruleset.nft" "candidate-ruleset" && has "$SB/calls.log" "systemctl stop nftban-commit-rollback-${ID}.timer"; then
    ok "D10 confirm: projection committed, status confirmed, candidate promoted to baseline, rollback unit stopped"
else ko "D10 confirm (rc=$rc status=$(get status))"; fi

fresh; stage_pending -5; ID=$(get apply_id)
rc=0; cc "cc_confirm $ID" || rc=$?
if [[ $rc -ne 0 && "$(get status)" == "pending" ]] && has "$SB/cc.out" "deadline"; then ok "D11 confirm after the deadline refused"
else ko "D11 deadline (rc=$rc)"; fi

fresh; stage_pending 120; ID=$(get apply_id); chmod a-w "$SB/etc/generated"
rc=0; cc "cc_confirm $ID" || rc=$?
chmod u+w "$SB/etc/generated"
if [[ $(id -u) -eq 0 ]]; then
    echo "  [NOT_EXECUTED] D12 publication failure (root ignores the read-only directory)"
elif [[ $rc -ne 0 && "$(get status)" == "pending" ]] && has "$SB/etc/generated/nftban-boot.nft" "old-projection"; then
    ok "D12 publication failure -> confirm FAILS, apply stays pending, rollback stays armed"
else ko "D12 publication failure (rc=$rc status=$(get status))"; fi

# ---- crash after commit point
fresh; stage_pending 120; ID=$(get apply_id)
cp "$SB/data/state/commit-confirm/candidate-projection.nft" "$SB/etc/generated/nftban-boot.nft"
: > "$SB/calls.log"
rc=0; cc "cc_rollback $ID --auto" || rc=$?
if [[ "$(get status)" == "confirmed" ]] && ! has "$SB/calls.log" "nft -f" && has_line "$SB/etc/conf.d/a.conf" "A=2"; then
    ok "D13 crash after the commit point: rollback COMPLETES the confirm, no rollback"
else ko "D13 crash completion (status=$(get status))"; fi

# ---- rollback
fresh; stage_pending 120; ID=$(get apply_id)
echo 'NEW=edited-after-apply' > "$SB/etc/conf.d/new.conf"       # independent later edit
: > "$SB/calls.log"
rc=0; cc "cc_rollback $ID --auto" || rc=$?
if [[ $rc -eq 0 && "$(get status)" == "rolled-back" ]]; then ok "D14 rollback completes (status rolled-back)"
else ko "D14 rollback (rc=$rc status=$(get status))"; fi
if has_line "$SB/etc/conf.d/a.conf" "A=1" && [[ -f "$SB/etc/ports.d/00-ssh.conf" ]]; then ok "D15 change set restored (modified file reverted, removed file restored)"
else ko "D15 change set restore"; fi
if has_line "$SB/etc/conf.d/new.conf" "NEW=edited-after-apply" && [[ "$(get conflicts)" == *"conf.d/new.conf"* ]]; then
    ok "D16 a file edited after the apply is left untouched and listed as a conflict"
else ko "D16 conflict handling (conflicts=$(get conflicts))"; fi
if has_line "$SB/etc/conf.d/untouched.conf" "KEEP=1"; then ok "D17 files outside the change set untouched"
else ko "D17 outside file changed"; fi
T="$SB/last_tx.nft"
if has "$T" "delete table ip nftban" && has "$T" "delete table ip6 nftban" && ! grep -E 'delete table (inet|ip|ip6|arp|bridge|netdev) [^n]|labforeign|flush ruleset' "$T" >/dev/null; then
    ok "D18 one kernel transaction, deleting ONLY ip/ip6 nftban (foreign tables never in it)"
else ko "D18 transaction scope: $(tr '\n' ';' < "$T" 2>/dev/null)"; fi
if has "$T" "set s"; then ok "D19 transaction reloads the exact pre-apply NFTBan tables"
else ko "D19 snapshot not reloaded"; fi

# ---- D10: failed transaction
fresh; stage_pending 120; ID=$(get apply_id); echo 1 > "$SB/nft_f_rc"
rc=0; cc "cc_rollback $ID --auto" || rc=$?
if [[ $rc -ne 0 && "$(get status)" == "rollback-failed" && -e "$SB/data/state/commit-confirm.rollback-failed" ]] \
   && [[ -n "$(get kernel)" ]] && [[ -d "$SB/data/state/applied" && -f "$SB/data/state/commit-confirm/kernel-before.nft" ]]; then
    ok "D20 failed rollback: KEEP + ALARM (status, marker, kernel fact recorded, artifacts kept)"
else ko "D20 failed rollback (rc=$rc status=$(get status))"; fi
if [[ "$(get kernel)" == *"candidate still active"* ]]; then ok "D21 kernel state VERIFIED and reported (candidate still active)"
else ko "D21 kernel fact: $(get kernel)"; fi
if [[ $(grep -c '^nft delete' "$SB/calls.log") -eq 0 ]]; then ok "D22 no NFTBan table deleted outside the (failed) transaction"
else ko "D22 extra delete issued"; fi
rc=0; cc "cc_abandon $ID" || rc=$?
if [[ $rc -eq 0 && ! -e "$SB/data/state/commit-confirm.rollback-failed" && "$(get status)" == "abandoned" ]]; then ok "D23 abandon clears the marker"
else ko "D23 abandon (rc=$rc)"; fi

# ---- boot mode
fresh; stage_pending 120; : > "$SB/calls.log"
rc=0; cc 'cc_boot' || rc=$?
if [[ "$(get status)" == "rolled-back" ]] && ! has "$SB/calls.log" "nft -f" && has_line "$SB/etc/conf.d/a.conf" "A=1"; then
    ok "D24 boot mode: config rolled back, no nft call (old projection already loaded)"
else ko "D24 boot mode (status=$(get status))"; fi

echo ""
echo "TOTAL: pass=$pass fail=$fail"
[[ $fail -eq 0 ]]
