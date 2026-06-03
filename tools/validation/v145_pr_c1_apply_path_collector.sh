#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.145 - PR-C1 apply-path root-cause collector (READ-ONLY)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v145_pr_c1_apply_path_collector" meta:type="tool" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="READ-ONLY diagnostic collector for the v1.145 PR-C1 apply-path root-cause (why _nft_table_available can be false while the nftban table exists). Captures table-probe transience, lock/concurrency correlation, systemd context, socket-activation state, and SSH-port config/state. Mutates NOTHING: no nft add/delete/flush, no reload, no restart, no SSH-port change."
# meta:input="None"
# meta:output="Structured diagnostic record on stdout"
# meta:depends="bash,nft,ss,systemctl,journalctl,sshd"
# meta:inventory.files=""
# meta:inventory.binaries="nft,ss,systemctl,journalctl,sshd,fuser"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_DATA_DIR,NFTBAN_TABLE_IPV4,NFTBAN_TABLE_IPV6"
# meta:inventory.config_files="/etc/nftban/nftban.conf,/etc/nftban/nftban.conf.local,/etc/ssh/sshd_config"
# meta:inventory.systemd_units="nftban-maintenance.service,ssh.socket"
# meta:inventory.network=""
# meta:inventory.privileges="root (read-only nft/ss/journal/sshd -T)"
# =============================================================================
#
# READ-ONLY by construction: every external call is a query (list/show/read).
# There is NO nft add/delete/flush, NO firewall reload/rebuild, NO service
# restart, NO sshd_config edit, NO SSH-port change. Safe to run on lab and
# (read-only) service hosts. Probe count defaults to 50 quick `nft list table`
# calls to detect transient rc flaps (H1/H2); override with arg1.
set -Eeuo pipefail

PROBES="${1:-50}"
HOSTN="$(hostname 2>/dev/null || echo unknown)"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"

echo "============================================================"
echo "V145 PR-C1 apply-path collector (READ-ONLY)"
echo "host=$HOSTN  utc=$TS  probes=$PROBES"
echo "MODE: read-only — no nft mutation, no reload, no restart"
echo "============================================================"

# Effective table vars — mirror maintenance.sh resolution (conf then default).
NFTBAN_CONFIG_DIR="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
# shellcheck source=/dev/null
source "$NFTBAN_CONFIG_DIR/nftban.conf" 2>/dev/null || true
# shellcheck source=/dev/null
source "$NFTBAN_CONFIG_DIR/nftban.conf.local" 2>/dev/null || true
: "${NFTBAN_TABLE_IPV4:=ip nftban}"
: "${NFTBAN_TABLE_IPV6:=ip6 nftban}"
echo "[vars] NFTBAN_TABLE_IPV4='$NFTBAN_TABLE_IPV4'  NFTBAN_TABLE_IPV6='$NFTBAN_TABLE_IPV6'  (H4: override iff not ip/ip6 nftban)"

# --- H1/H2: rapid re-probe of the once-cached existence check ---------------
echo "[probe] rapid 'nft list table' x$PROBES (detect transient rc flaps)"
probe_set() {
    local label="$1"; shift
    local fails=0 i rc h
    for ((i=0; i<PROBES; i++)); do
        rc=0; nft list table "$@" >/dev/null 2>&1 || rc=$?
        if [[ $rc -ne 0 ]]; then
            fails=$((fails+1))
            h=""
            if command -v fuser >/dev/null 2>&1; then
                h="$(fuser /run/nftban/nft_operations.lock 2>/dev/null | tr -s ' ' || true)"
            fi
            echo "    FLAP $label iter=$i rc=$rc nft_operations.lock-holders='${h:-none}'"
        fi
    done
    echo "  $label: $((PROBES-fails))/$PROBES ok, $fails transient failures"
}
# NOTE: $NFTBAN_TABLE_IPV4 is intentionally unquoted (two words: family name).
# shellcheck disable=SC2086
probe_set "ip nftban " $NFTBAN_TABLE_IPV4
# shellcheck disable=SC2086
probe_set "ip6 nftban" $NFTBAN_TABLE_IPV6

# Single explicit probe with rc + stderr captured.
_rc=0
# shellcheck disable=SC2086  # table var is intentionally two words (family name)
_err="$(nft list table $NFTBAN_TABLE_IPV4 2>&1 >/dev/null || true)"
# shellcheck disable=SC2086
nft list table $NFTBAN_TABLE_IPV4 >/dev/null 2>&1 || _rc=$?
echo "[probe] single ip nftban: rc=$_rc stderr='${_err}'"

# --- all tables (family/legacy/inet mismatch — H4) --------------------------
echo "[tables] nft list tables:"
nft list tables 2>&1 | sed 's/^/  /' || true

# --- locks / concurrency (H2) ----------------------------------------------
echo "[locks] /run/nftban lock state + holders:"
for L in maintenance.lock nft_operations.lock update.lock; do
    p="/run/nftban/$L"
    if [[ -e "$p" ]]; then
        hold="none"
        command -v fuser >/dev/null 2>&1 && hold="$(fuser "$p" 2>/dev/null | tr -s ' ' || echo none)"
        echo "  $L: present  holders='${hold:-none}'  mtime=$(stat -c %y "$p" 2>/dev/null || echo ?)"
    else
        echo "  $L: absent"
    fi
done

# --- systemd context (H3) ---------------------------------------------------
echo "[systemd] nftban-maintenance.service:"
systemctl show nftban-maintenance.service \
    -p User -p CapabilityBoundingSet -p AmbientCapabilities -p PrivateNetwork \
    -p RestrictNamespaces -p ActiveState -p Result -p ExecMainStatus 2>/dev/null \
    | sed 's/^/  /' || true
echo "  maintenance.timer active=$(systemctl is-active nftban-maintenance.timer 2>/dev/null || echo n/a)"

# --- socket activation (ties to PR-D) ---------------------------------------
echo "[ssh] socket/service state:"
for u in ssh.socket sshd.socket ssh.service sshd.service; do
    # is-active returns non-zero for inactive units; capture its word regardless.
    _st="$(systemctl is-active "$u" 2>/dev/null || true)"
    echo "  $u: ${_st:-unknown}"
done
echo "  sshd -T port: $(sshd -T 2>/dev/null | grep '^port ' | awk '{print $2}' | tr '\n' ' ' || echo n/a)"
echo "  ss sshd listeners:"
ss -tlnp 2>/dev/null | grep -i sshd | sed 's/^/    /' || echo "    (none)"

# --- SSH-port config/state (alignment / migration check) --------------------
echo "[state] ssh_port_active.state: $(cat "${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/ssh_port_active.state" 2>/dev/null || echo none)"
echo "[state] ports.d/00-ssh.conf: $(grep -vhE '^#|^$' "${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf" 2>/dev/null | tr '\n' ' ' || echo none)"
echo "[state] sshd_config Port lines: $(grep -hE '^[[:space:]]*Port[[:space:]]' /etc/ssh/sshd_config 2>/dev/null | tr '\n' ' ' || echo '(default 22)')"
echo "[state] sshd_config ListenAddress: $(grep -hiE '^[[:space:]]*ListenAddress[[:space:]]' /etc/ssh/sshd_config 2>/dev/null | tr '\n' ' ' || echo none)"

# --- journals (recent, read-only; bounded + timeout-guarded so the collector
#     never hangs on a high-volume host) ---------------------------------------
echo "[journal] nftban-maintenance (last 5):"
timeout 15 journalctl -u nftban-maintenance.service --no-pager -n 5 2>/dev/null | sed 's/^/  /' || echo "  (none / timed out)"
echo "[journal] reload/rebuild/not-applied markers (unit-scoped, last 5):"
# Unit-scoped + journalctl-side grep (-g) + line cap; whole call timeout-bounded.
timeout 20 journalctl -u nftban-maintenance.service -u nftban-firewall-init.service \
    --no-pager -n 400 -g 'firewall reload|firewall rebuild|nft_table_available|not applied|nftban-installer' 2>/dev/null \
    | tail -5 | sed 's/^/  /' || echo "  (none / timed out)"

echo "============================================================"
echo "END collector — READ-ONLY, no mutation performed."
echo "============================================================"
