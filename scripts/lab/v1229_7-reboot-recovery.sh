#!/usr/bin/env bash
# =============================================================================
# NFTBan — scripted reboot + recovery + post-reboot assertion (v1.229.7)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v1229_7_reboot_recovery"
# meta:type="lab"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-24"
# meta:description="Reboots a lab host, waits for it to return, VERIFIES IT IS THE SAME HOST (boot id changed, hostname and machine-id unchanged), then re-runs the convergence assertions. A host that does not return is a fail-fast condition because every downstream row would be invalid."
# =============================================================================
#
# ⛔ SAME HOST, NEW BOOT. Reconnecting is not enough: assert machine-id is
#    UNCHANGED (it is the same machine) and boot_id CHANGED (it really rebooted).
#    Without both, "reboot persistence" could be proven against a host that
#    never rebooted, or against a different host entirely.
# =============================================================================
set -uo pipefail
HOST="${1:?usage: $0 <ssh-host> <distro-label>}"
LABEL="${2:?}"
SSH=(ssh -i "$HOME/.ssh/id_ed25519" -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "root@$HOST")

id_of(){ "${SSH[@]}" 'echo "$(cat /etc/machine-id 2>/dev/null) $(cat /proc/sys/kernel/random/boot_id 2>/dev/null) $(hostname)"' 2>/dev/null; }

before="$(id_of)"
[[ -z "$before" ]] && { echo "FATAL: cannot reach $HOST before reboot"; exit 2; }
read -r mid_b bid_b hn_b <<<"$before"
echo "  pre-reboot : machine-id=${mid_b:0:8} boot-id=${bid_b:0:8} host=$hn_b"

"${SSH[@]}" 'systemctl reboot' >/dev/null 2>&1 || true
sleep 15

deadline=$(( SECONDS + 420 ))
after=""
while (( SECONDS < deadline )); do
    after="$(id_of)" && [[ -n "$after" ]] && break
    sleep 10
done
[[ -z "$after" ]] && { echo "FATAL: $HOST did not return within 420s — downstream evidence would be invalid"; exit 2; }
read -r mid_a bid_a hn_a <<<"$after"
echo "  post-reboot: machine-id=${mid_a:0:8} boot-id=${bid_a:0:8} host=$hn_a"

# --- identity verification --------------------------------------------------
[[ "$mid_a" == "$mid_b" ]] || { echo "FATAL: machine-id CHANGED — this is not the same host"; exit 2; }
[[ "$hn_a"  == "$hn_b"  ]] || { echo "FATAL: hostname changed ($hn_b -> $hn_a)"; exit 2; }
[[ "$bid_a" != "$bid_b" ]] || { echo "FATAL: boot-id UNCHANGED — the host did NOT actually reboot"; exit 2; }
echo "  identity   : same machine, new boot — verified"

# settle: units and the firewall need to converge before observation
"${SSH[@]}" 'for i in $(seq 1 30); do systemctl is-system-running 2>/dev/null | grep -qE "running|degraded" && break; sleep 5; done' >/dev/null 2>&1
sleep 10

echo "  --- post-reboot convergence assertions ---"
"${SSH[@]}" "EVIDENCE_DIR=/var/tmp/nftban-matrix-reboot MATRIX_REBOOT_ONLY=1 bash /root/v1229_7-convergence-matrix.sh '$LABEL'" 2>&1 | tail -20
