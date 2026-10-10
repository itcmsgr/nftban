#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.235 firewall authority: one decision, obeyed by every writer
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="firewall_authority_v1235_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-10-10"
# meta:description="v1.235 Train D CRITICAL BUG-PURGE-LEAVES-NFTBAN-UNITS-ENABLED-REFUSED-INSTALL-ACTIVATES-AT-BOOT (owner 2026-10-10): a refused install was observed enforcing NFTBan policy-drop rules ~10 min after a reboot (stale enablement + the maintenance 'lockout prevention' reload). A1: the REAL lib/service_control.sh nftban_firewall_authority answers the SHARED table scripts/ci/data/firewall-authority-cases.tsv (Go state.FirewallAuthority is held to the same table) for every row, built as real files (services.conf, install_state, installer.lock, a /proc/locks image). A2: a PID file without the kernel lock is not a held lock. A3: the REAL nft_ipc_request refuses WITHOUT connecting when authority is denied (stub socat never runs) and connects when granted. S1: every firewall verb that loads rules (init/reload/rebuild/reset/restore, active render-boot) calls the authority guard. S2: nftband and the 13 automatic units carry ExecCondition=nftband --authority-check (privileged '+' for the automatic ones). S3: maintenance, autoheal, rebuild-recovery, firewall-init, health auto-heal and health fix consult the decision before any write. S4: DEB prerm stops AND disables the active units; postrm purge removes leftover enablement links only when they point at the packaged unit path."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,awk,grep,sed,stat,mktemp"
# meta:inventory.files=""
# meta:inventory.binaries="bash,awk,grep,sed,stat,mktemp"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_STATE_DIR,NFTBAN_PROC_LOCKS,NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="firewall_authority_v1235_test"
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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
LIBDIR="$REPO_ROOT/cli/lib/nftban"
SVC="$LIBDIR/lib/service_control.sh"
TBL="$REPO_ROOT/scripts/ci/data/firewall-authority-cases.tsv"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

PASS=0; FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS+1)); }
ko() { echo "  ✗ $1"; FAIL=$((FAIL+1)); }

# build_case <dir> <bypass> <switch> <statefile> <state> <authority> <lock>
build_case() {
    local d="$1" sw="$3" sf="$4" st="$5" au="$6" lk="$7"
    rm -rf "$d"; mkdir -p "$d/etc/conf.d" "$d/state"
    printf '%s\n' "$2" > "$d/bypass"
    case "$sw" in
        on)      echo "NFTBAN_ENABLED=true"  > "$d/etc/conf.d/services.conf" ;;
        off)     echo "NFTBAN_ENABLED=false" > "$d/etc/conf.d/services.conf" ;;
        invalid) echo "NFTBAN_ENABLED=maybe" > "$d/etc/conf.d/services.conf" ;;
        unknown) mkdir -p "$d/etc/conf.d/services.conf" ;;
    esac
    case "$sf" in
        present)
            { echo "# NFTBan Install State — machine-written, do not edit"
              [[ "$st" != "-" ]] && echo "INSTALL_STATE=$st"
              echo "AUTHORITY=${au#-}"; } > "$d/state/install_state" ;;
        unreadable) mkdir -p "$d/state/install_state" ;;
    esac
    echo "1: POSIX  ADVISORY  WRITE 999 fd:00:12 0 EOF" > "$d/locks"
    if [[ "$lk" == live || "$lk" == stale ]]; then
        echo 4242 > "$d/state/installer.lock"
        [[ "$lk" == live ]] && echo "2: FLOCK  ADVISORY  WRITE 4242 fd:00:$(stat -c %i "$d/state/installer.lock") 0 EOF" >> "$d/locks"
    fi
    return 0
}

# decide <dir>: the REAL shell decision in a fresh shell (the library guards against re-sourcing).
decide() {
    local d="$1"
    NFTBAN_CONFIG_DIR="$d/etc" NFTBAN_STATE_DIR="$d/state" NFTBAN_PROC_LOCKS="$d/locks" \
    NFTBAN_LIB_DIR="$LIBDIR" BYPASS="$(cat "$d/bypass")" bash -c '
        source "$1" >/dev/null 2>&1
        nftban_emergency_bypass_active() { [[ "$BYPASS" == yes ]]; }
        nftban_firewall_authority || true' _ "$SVC" 2>/dev/null
}

echo "=== A1. shared decision table ==="
n=0; bad=""
while IFS=$'\t' read -r c_by c_sw c_sf c_st c_au c_lk c_v c_r || [[ -n "${c_by:-}" ]]; do
    [[ -z "$c_by" || "$c_by" == \#* ]] && continue
    n=$((n+1))
    build_case "$SB/c" "$c_by" "$c_sw" "$c_sf" "$c_st" "$c_au" "$c_lk"
    out="$(decide "$SB/c")"
    got="${out%% *}"; rest="${out#* }"; got_r="${rest%% *}"
    [[ "$got" == "$c_v" && "$got_r" == "$c_r" ]] \
        || bad+=" [${c_by} ${c_sw} ${c_sf} ${c_st} ${c_au} ${c_lk}: got '${out}' want ${c_v} ${c_r}]"
done < "$TBL"
if [[ $n -ge 35 && -z "$bad" ]]; then ok "A1 nftban_firewall_authority gives the shared table's answer for all $n rows"
else ko "A1 decision mismatch (rows=$n):${bad:0:2000}"; fi

echo "=== A2. a PID file is not a held lock ==="
build_case "$SB/l" no on present PREPARE_COMPLETE TAKEOVER stale
ino=$(stat -c %i "$SB/l/state/installer.lock")
a2bad=""
for locks in "" \
    "1: FLOCK  ADVISORY  WRITE 4242 fd:00:$((ino+1)) 0 EOF" \
    "1: FLOCK  ADVISORY  WRITE 4243 fd:00:${ino} 0 EOF" \
    "1: POSIX  ADVISORY  WRITE 4242 fd:00:${ino} 0 EOF" \
    "1: -> FLOCK  ADVISORY  WRITE 4242 fd:00:${ino} 0 EOF"; do
    printf '%s\n' "$locks" > "$SB/l/locks"
    out="$(decide "$SB/l")"
    [[ "$out" == "DENIED transaction-interrupted"* ]] || a2bad+=" [${locks:-empty}: $out]"
done
printf '1: FLOCK  ADVISORY  WRITE 4242 fd:00:%s 0 EOF\n' "$ino" > "$SB/l/locks"
out="$(decide "$SB/l")"
[[ "$out" == "GRANTED transaction"* ]] || a2bad+=" [held: $out]"
[[ -z "$a2bad" ]] && ok "A2 only the kernel lock table (FLOCK, same inode, recorded PID) makes the lock held" || ko "A2$a2bad"

echo "=== A3. nft_ipc_request refuses before connecting ==="
mkdir -p "$SB/bin"; : > "$SB/socat.calls"
cat > "$SB/bin/socat" <<EOF
#!/usr/bin/env bash
echo called >> "$SB/socat.calls"; cat >/dev/null; echo '{"success":true}'
EOF
chmod +x "$SB/bin/socat"
ipc_run() { # <case dir> -> response; socat calls counted in socat.calls
    local d="$1"
    PATH="$SB/bin:$PATH" NFTBAN_CONFIG_DIR="$d/etc" NFTBAN_STATE_DIR="$d/state" NFTBAN_PROC_LOCKS="$d/locks" \
    NFTBAN_LIB_DIR="$LIBDIR" NFTBAN_DAEMON_SOCKET="$SB/sock" bash -c '
        source "$1" >/dev/null 2>&1 || true
        nft_ipc_request ping "{}" || true' _ "$LIBDIR/lib/nft_ipc.sh" 2>/dev/null
}
build_case "$SB/d" no on present FAILED_AUTHORITY_ABORT ABORT none
resp="$(ipc_run "$SB/d")"
if [[ "$resp" == *'"success":false'*refused*refused* && ! -s "$SB/socat.calls" ]]; then
    ok "A3a refused install: nft_ipc_request answers 'refused (refused: ...)' and runs no socat"
else ko "A3a denied request: resp='$resp' socat_calls=$(wc -l < "$SB/socat.calls")"; fi
build_case "$SB/g" no on present COMMITTED TAKEOVER none
resp="$(ipc_run "$SB/g")"
if [[ "$resp" != *refused* ]]; then ok "A3b authorized install: the gate lets the request through ($resp)"
else ko "A3b granted request refused: $resp"; fi
# No hermetic unix socket here, so "never connects" is held by ORDER: in nft_ipc_request the
# decision comes before the socket test and before socat.
body="$(awk '/^nft_ipc_request\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$LIBDIR/lib/nft_ipc.sh")"
l_a=$(grep -n '_nft_ipc_authority' <<< "$body" | head -1 | cut -d: -f1)
l_s=$(grep -n 'socat\|NFTBAN_DAEMON_SOCKET' <<< "$body" | head -1 | cut -d: -f1)
[[ -n "$l_a" && -n "$l_s" && "$l_a" -lt "$l_s" ]] && ok "A3c the decision precedes any socket use in nft_ipc_request" \
    || ko "A3c order: authority line ${l_a:-?} vs first socket use ${l_s:-?}"

echo "=== S1. firewall verbs call the authority guard ==="
FW="$LIBDIR/cli/cmd_firewall.sh"
s1bad=""
for verb in "firewall init" "firewall reload" "firewall rebuild" "firewall reset" "firewall restore" "firewall render-boot"; do
    grep -q "_fw_authority_guard \"$verb\"" "$FW" || s1bad+=" $verb"
done
grep -q '_fw_authority_guard "firewall takeover"' "$FW" && s1bad+=" takeover-must-not-be-gated"
[[ -z "$s1bad" ]] && ok "S1 init/reload/rebuild/reset/restore/render-boot are gated; takeover (the approval path) is not" || ko "S1:$s1bad"

echo "=== S2. units carry the ExecCondition ==="
U="$REPO_ROOT/install/systemd"; s2bad=""
grep -qx 'ExecCondition=/usr/lib/nftban/bin/nftband --authority-check' "$U/nftband.service" || s2bad+=" nftband"
for u in maintenance health health-fix watchdog queue core-feeds geoban-refresh botscan botscan-collector \
         rbl-check rebuild-recovery firewall-init tunnel; do
    grep -qx 'ExecCondition=+/usr/lib/nftban/bin/nftband --authority-check' "$U/nftban-$u.service" || s2bad+=" $u"
done
[[ -z "$s2bad" ]] && ok "S2 nftband + 13 automatic units are skipped without authority" || ko "S2 missing:$s2bad"

echo "=== S3. automatic repair paths consult the decision ==="
s3bad=""
grep -q '_nft_ipc_authority' "$LIBDIR/cron/maintenance.sh" || s3bad+=" maintenance"
grep -q 'nftban_firewall_authority' "$LIBDIR/helpers/autoheal.sh" || s3bad+=" autoheal"
grep -q 'nftban_firewall_authority' "$LIBDIR/core/nftban_rebuild_recovery.sh" || s3bad+=" rebuild-recovery"
grep -q '_nft_ipc_authority' "$REPO_ROOT/install/helpers/firewall-init-with-delay.sh" || s3bad+=" firewall-init"
grep -q 'nftban_refuse_without_authority "health fix' "$LIBDIR/cli/cmd_health_core.sh" || s3bad+=" health-fix"
grep -q 'Auto-heal: DISABLED for this run' "$LIBDIR/cli/cmd_health_core.sh" || s3bad+=" health-auto-heal"
# autoheal: the decision precedes the first timer/daemon/rebuild action
ah="$LIBDIR/helpers/autoheal.sh"
l_gate=$(grep -n 'nftban_firewall_authority' "$ah" | head -1 | cut -d: -f1)
l_first=$(grep -n 'systemctl enable "\$timer"\|systemctl start nftband\|firewall rebuild' "$ah" | head -1 | cut -d: -f1)
[[ -n "$l_gate" && -n "$l_first" && "$l_gate" -lt "$l_first" ]] || s3bad+=" autoheal-order(${l_gate:-?}>${l_first:-?})"
[[ -z "$s3bad" ]] && ok "S3 maintenance, autoheal, rebuild-recovery, firewall-init, health fix/auto-heal check authority first" || ko "S3:$s3bad"

echo "=== S4. purge leaves no NFTBan enablement ==="
s4bad=""
PR="$REPO_ROOT/packaging/deb/prerm"
awk '/BEGIN GENERATED systemd cleanup/{g=1} g&&/nftband.socket; do/{f=1;next} f{print; if(/^ *done/) exit}' "$PR" > "$SB/prerm_loop"
grep -q 'deb-systemd-invoke stop' "$SB/prerm_loop" || s4bad+=" prerm-stop"
grep -q 'systemctl disable "\$unit"' "$SB/prerm_loop" || s4bad+=" prerm-disable"
# postrm sweep, executed against a sandbox /etc/systemd/system
PO="$REPO_ROOT/packaging/deb/postrm"
awk '/deb-systemd-helper purge removes only links it created/{f=1} f{print} f&&/^        done$/{exit}' "$PO" > "$SB/sweep.sh"
ES="$SB/etc/systemd/system"; mkdir -p "$ES/multi-user.target.wants" "$ES/timers.target.wants" "$ES/sockets.target.wants"
ln -s /usr/lib/systemd/system/nftband.service "$ES/multi-user.target.wants/nftband.service"
ln -s /lib/systemd/system/nftban-maintenance.timer "$ES/timers.target.wants/nftban-maintenance.timer"
ln -s /usr/lib/systemd/system/nftband.socket "$ES/sockets.target.wants/nftband.socket"
ln -s /etc/systemd/system/nftban-custom.service "$ES/multi-user.target.wants/nftban-custom.service"
ln -s /usr/lib/systemd/system/ssh.service "$ES/multi-user.target.wants/ssh.service"
sed "s#/etc/systemd/system/#$ES/#g" "$SB/sweep.sh" > "$SB/sweep_sb.sh"
sh -e "$SB/sweep_sb.sh" >/dev/null 2>&1 || s4bad+=" sweep-rc"
[[ -L "$ES/multi-user.target.wants/nftband.service" ]] && s4bad+=" nftband-left"
[[ -L "$ES/timers.target.wants/nftban-maintenance.timer" ]] && s4bad+=" timer-left"
[[ -L "$ES/sockets.target.wants/nftband.socket" ]] && s4bad+=" socket-left"
[[ -L "$ES/multi-user.target.wants/nftban-custom.service" ]] || s4bad+=" operator-unit-removed"
[[ -L "$ES/multi-user.target.wants/ssh.service" ]] || s4bad+=" foreign-unit-removed"
[[ -z "$s4bad" ]] && ok "S4 prerm stops+disables; purge sweep removes packaged-unit links (dangling too), keeps operator and foreign links" || ko "S4:$s4bad"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
