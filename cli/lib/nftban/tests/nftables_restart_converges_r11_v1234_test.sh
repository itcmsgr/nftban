#!/usr/bin/env bash
# =============================================================================
# NFTBan - R-11: `nftban nftables restart|reload` preserve the effective state
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="nftables_restart_converges_r11_v1234_test"
# meta:type="test"
# meta:version="1.234.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-29"
# meta:description="R-11 BUG-NFTABLES-RESTART-RELOADS-BOOT-FILE-DROPS-PORTS-BANS-WHITELIST. Through the real cmd_nftables.sh verb functions against a fake kernel (fake nft / systemctl / nftban / nftban-core; the REAL transition-health verifier): C0 control proves a raw service restart loses the state in the fake, so the diff discriminates. A1/A2 restart and reload leave ports, persisted bans and whitelist IDENTICAL (state-diff before == after), never restart/reload nftables.service, and converge through `nftban firewall rebuild`. A3 a failing rebuild makes the verb fail with no success line. A4 a rebuild that exits 0 but leaves the ports skeletal is caught by the effective-state verification. A5 an unmeasurable verification is not success. A6 an inactive unit is started, then converged. On v1.233.1 the verb was `systemctl restart nftables` + rc-only success, so A1-A6 fail there."
# meta:input="cli/lib/nftban/cli/cmd_nftables.sh, cli/lib/nftban/core/nftban_firewall_transition_health.sh"
# meta:output="PASS/FAIL per assertion; exit 1 on any failure"
# meta:depends="bash,mktemp,diff,sort,paste"
# meta:ta.id="nftables_restart_converges_r11_v1234_test"
# meta:ta.owner="firewall"
# meta:ta.module="nftables-lifecycle"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files=""
# meta:inventory.binaries="bash,mktemp,diff,sort,paste"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR,NFTBAN_BIN,PATH"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SUBJECT="$ROOT/cli/lib/nftban/cli/cmd_nftables.sh"
FTH="$ROOT/cli/lib/nftban/core/nftban_firewall_transition_health.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; }

for f in "$SUBJECT" "$FTH"; do
    [[ -f "$f" ]] || { echo "  SUBJECT_NOT_FOUND: $f"; echo "TOTAL: pass=0 fail=1"; exit 1; }
done

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
K="$SB/kernel"; LIB="$SB/lib"; CONF="$SB/conf"; BIN="$SB/bin"; LOG="$SB/calls.log"
mkdir -p "$K" "$LIB/bin" "$LIB/core" "$CONF/ports.d" "$BIN"
cp "$FTH" "$LIB/core/"
printf '22/T/I\n' > "$CONF/ports.d/00-ssh.conf"
printf '18765/T/I\n' > "$CONF/ports.d/90-custom.conf"

# ---- the fake kernel -----------------------------------------------------------
# One file per (family, set), one element per line. `table` marks the nftban tables.
put(){ local f="$K/$1"; shift; : > "$f"; local e; for e in "$@"; do echo "$e" >> "$f"; done; }
live_state(){      # the operator's converged runtime state before the verb
    : > "$K/table"
    for fam in ip ip6; do
        put "$fam.tcp_ports_in" 22 80 443 18765
        put "$fam.tcp_ports_out" 53 80 443
        put "$fam.udp_ports_in"
        put "$fam.udp_ports_out" 53 123
    done
    put ip.blacklist_manual_ipv4 192.0.2.10 192.0.2.11 192.0.2.12
    put ip6.blacklist_manual_ipv6 2001:db8::10
    put ip.whitelist_ipv4 127.0.0.1 198.51.100.7
    put ip6.whitelist_ipv6 ::1 2001:db8::7
}
export K LOG

# nft: read-only listing of the fake kernel.
cat > "$BIN/nft" <<'EOF'
#!/usr/bin/env bash
echo "nft $*" >> "$LOG"
if [[ "$1 $2" == "list set" && "$4" == "nftban" ]]; then
    f="$K/$3.$5"; [[ -f "$K/table" && -f "$f" ]] || exit 1
    printf 'table %s nftban {\n\tset %s {\n\t\ttype inet_service\n' "$3" "$5"
    [[ -s "$f" ]] && printf '\t\telements = { %s }\n' "$(paste -sd, "$f" | sed 's/,/, /g')"
    printf '\t}\n}\n'; exit 0
fi
if [[ "$1 $2" == "list chain" && "$4 $5" == "nftban input" ]]; then
    [[ -f "$K/table" ]] || exit 1
    printf 'chain input {\n\tiif "lo" accept\n\tct state established,related accept\n\ttcp dport @ssh_ports accept\n}\n'; exit 0
fi
if [[ "$1 $2" == "list table" && "$4" == "nftban" ]]; then [[ -f "$K/table" ]]; exit $?; fi
exit 0
EOF

# systemctl: restart/reload/start of nftables re-load the BOOT PROJECTION — the
# measured R-11 reset (template ports, no bans, loopback-only whitelist).
cat > "$BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >> "$LOG"
boot_reset(){
    : > "$K/table"
    for fam in ip ip6; do
        printf '22\n80\n443\n' > "$K/$fam.tcp_ports_in"
        printf '53\n80\n443\n' > "$K/$fam.tcp_ports_out"
        : > "$K/$fam.udp_ports_in"; printf '53\n123\n' > "$K/$fam.udp_ports_out"
    done
    : > "$K/ip.blacklist_manual_ipv4"; : > "$K/ip6.blacklist_manual_ipv6"
    echo 127.0.0.1 > "$K/ip.whitelist_ipv4"; echo ::1 > "$K/ip6.whitelist_ipv6"
    : > "$K/unit_active"
}
case "$*" in
    *is-active*nftables*) [[ -f "$K/unit_active" ]]; exit $? ;;
    *restart*nftables*|*reload*nftables*) boot_reset; exit 0 ;;
    *start*nftables*) [[ -f "$K/unit_active" ]] || boot_reset; exit 0 ;;
esac
exit 0
EOF

# nftban firewall rebuild: the atomic, snapshot-first rebuild. It keeps the live
# bans/whitelist (snapshot restore + durable reconcile) and installs the complete
# effective ports. Failure knobs: rebuild_fail (rc 1, nothing changed) and
# rebuild_lies (rc 0 but ports left skeletal).
cat > "$BIN/nftban" <<'EOF'
#!/usr/bin/env bash
echo "nftban $*" >> "$LOG"
[[ "$1 $2" == "firewall rebuild" ]] || exit 2
[[ -f "$K/rebuild_fail" ]] && { echo "ERROR: rebuild failed (fake)" >&2; exit 1; }
: > "$K/table"
if [[ -f "$K/rebuild_lies" ]]; then
    for fam in ip ip6; do printf '22\n80\n443\n' > "$K/$fam.tcp_ports_in"; done
else
    for fam in ip ip6; do printf '22\n80\n443\n18765\n' > "$K/$fam.tcp_ports_in"; done
fi
exit 0
EOF

cat > "$LIB/bin/nftban-core" <<'EOF'
#!/usr/bin/env bash
[[ -f "$K/core_broken" ]] && exit 1
[[ "$1 $2" == "ports render-effective" ]] || exit 2
echo "NFTBAN_SVC_TCP_IN=22, 80, 443, 18765"
echo "NFTBAN_SVC_TCP_OUT=53, 80, 443"
echo "NFTBAN_SVC_UDP_IN="
echo "NFTBAN_SVC_UDP_OUT=53, 123"
EOF
chmod +x "$BIN"/* "$LIB/bin/nftban-core"

export PATH="$BIN:$PATH" NFTBAN_LIB_DIR="$LIB" NFTBAN_CONFIG_DIR="$CONF" NFTBAN_BIN="$BIN/nftban"
export NFTBAN_STATE_DIR="$SB/state"

# Kernel snapshot through the SAME read interface the product uses (nft list set).
snapshot(){
    local fam set
    for fam in ip ip6; do
        for set in tcp_ports_in tcp_ports_out udp_ports_in udp_ports_out; do
            printf '%s.%s: ' "$fam" "$set"; nft list set "$fam" nftban "$set" 2>/dev/null | tr -d '\n\t'; echo
        done
    done
    for set in "ip blacklist_manual_ipv4" "ip6 blacklist_manual_ipv6" "ip whitelist_ipv4" "ip6 whitelist_ipv6"; do
        # shellcheck disable=SC2086
        printf '%s: ' "$set"; nft list set ${set%% *} nftban ${set##* } 2>/dev/null | tr -d '\n\t'; echo
    done
}

# Run one verb in an isolated shell: the subject enables errexit when sourced.
run_verb(){ # <function>
    ( # shellcheck source=/dev/null
      source "$SUBJECT" >/dev/null 2>&1 || exit 97
      "$1" ) > "$SB/out" 2>&1
}
reset_arm(){ rm -f "$K"/rebuild_fail "$K"/rebuild_lies "$K"/core_broken; : > "$LOG"; live_state; : > "$K/unit_active"; }

echo "== C0  control: the fake reproduces the R-11 reset, so the diff can fail =="
reset_arm
snapshot > "$SB/before"
if grep -q '18765' "$SB/before" && grep -q '192.0.2.10' "$SB/before" && grep -q '198.51.100.7' "$SB/before"; then
    ok "positive control: the snapshot sees the port, the persisted ban and the whitelist entry"
else
    no "snapshot is vacuous — the state-diff below would prove nothing"
fi
systemctl restart nftables.service
snapshot > "$SB/after"
diff -q "$SB/before" "$SB/after" >/dev/null \
    && no "control: a raw service restart left the state unchanged — the diff cannot discriminate" \
    || ok "control: a raw \`systemctl restart nftables\` loses port/bans/whitelist in the fake (R-11 shape)"

arm=0
for verb in restart reload; do
    arm=$((arm + 1))
    echo "== A${arm}  nftables $verb preserves ports, bans and whitelist =="
    reset_arm
    snapshot > "$SB/before"
    rc=0; run_verb "_nftban_nftables_cmd_$verb" || rc=$?
    snapshot > "$SB/after"
    [[ $rc -eq 0 ]] && ok "$verb exits 0" || { no "$verb exited $rc:"; sed 's/^/        /' "$SB/out" | tail -5; }
    if diff -u "$SB/before" "$SB/after" > "$SB/diff"; then
        ok "$verb: state-diff before == after (ports, persisted bans, whitelist; ip + ip6)"
    else
        no "$verb changed the effective state:"; sed 's/^/        /' "$SB/diff" | tail -12
    fi
    grep -qE '^systemctl .*(restart|reload).*nftables' "$LOG" \
        && no "$verb restarted/reloaded nftables.service (the R-11 reset)" \
        || ok "$verb did not restart/reload nftables.service"
    grep -q '^nftban firewall rebuild' "$LOG" \
        && ok "$verb converged through nftban firewall rebuild" \
        || no "$verb did not run the atomic rebuild"
done

echo "== A3  a failing rebuild fails the verb (no false success) =="
reset_arm; : > "$K/rebuild_fail"
rc=0; run_verb _nftban_nftables_cmd_restart || rc=$?
[[ $rc -ne 0 ]] && ok "restart exits non-zero ($rc) when the rebuild fails" || no "restart exited 0 although the rebuild failed"
grep -q '✓' "$SB/out" && no "a success line was printed after a failed rebuild" || ok "no success line after a failed rebuild"

echo "== A4  a rebuild that leaves skeletal ports is caught by verification =="
reset_arm; : > "$K/rebuild_lies"
rc=0; run_verb _nftban_nftables_cmd_restart || rc=$?
if [[ $rc -ne 0 ]] && grep -q '18765' "$SB/out"; then
    ok "restart fails and names the missing effective port 18765"
else
    no "restart did not catch skeletal ports after rc=0 (rc=$rc)"; sed 's/^/        /' "$SB/out" | tail -4
fi
grep -q '✓' "$SB/out" && no "a success line was printed with ports missing" || ok "no success line with ports missing"

echo "== A5  an unmeasurable verification is not success =="
reset_arm; : > "$K/core_broken"
rc=0; run_verb _nftban_nftables_cmd_restart || rc=$?
if [[ $rc -ne 0 ]] && grep -qi 'UNMEASURED' "$SB/out"; then
    ok "restart fails UNMEASURED when the effective-port authority cannot answer"
else
    no "restart reported success without a measurement (rc=$rc)"
fi

echo "== A6  an inactive unit is started, then converged =="
reset_arm; rm -f "$K/unit_active"
rc=0; run_verb _nftban_nftables_cmd_restart || rc=$?
s_line=$(awk '/^systemctl start nftables/ { print NR; exit }' "$LOG")
r_line=$(awk '/^nftban firewall rebuild/ { print NR; exit }' "$LOG")
if [[ $rc -eq 0 && -n "$s_line" && -n "$r_line" && "$r_line" -gt "$s_line" ]]; then
    ok "inactive unit: started first, then the atomic rebuild converged"
else
    no "inactive unit handling wrong (rc=$rc start@${s_line:-none} rebuild@${r_line:-none})"
fi

echo
echo "TOTAL: pass=$pass fail=$fail"
[[ $fail -eq 0 ]] || exit 1
