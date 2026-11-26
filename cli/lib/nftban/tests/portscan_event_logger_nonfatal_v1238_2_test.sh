#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238.2: a failing logger never aborts the PortScan classic cycle
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="portscan_event_logger_nonfatal_v1238_2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-26"
# meta:description="v1.238.2 (owner 2026-11-26, v1.238.1 RC acceptance). On EL9/EL10 Enforcing nftband_t may not write /dev/log; logger in _nftban_portscan_emit_event exited 1 under the cycle's set -Eeuo pipefail and aborted the whole PortScan classic cycle on the first scan line (strace of the real daemon: 1 logger exec for 30 lines, no record_connection, no state write, no ban). Sources the REAL nftban_portscan_classic.sh in a shell with set -Eeuo pipefail and a logger stub that fails like the denied one (rc 1, 'socket /dev/log: Permission denied'): the event function returns 0, the event is still written to portscan-events.log, the caller continues past it for every line, and nothing of logger's stderr leaks. Static: every logger call in the file is non-fatal. Non-vacuity: the v1.238.1 code aborts. Sandbox only; no firewall change."
# meta:input="cli/lib/nftban/core/nftban_portscan_classic.sh (repo, read-only); temp dirs"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,mktemp,grep"
# meta:inventory.files="cli/lib/nftban/core/nftban_portscan_classic.sh"
# meta:inventory.binaries="bash,mktemp,grep"
# meta:inventory.env_vars="NFTBAN_LOG_DIR,NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="portscan_event_logger_nonfatal_v1238_2_test"
# meta:ta.owner="cli"
# meta:ta.module="portscan-classic"
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
LIBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$LIBDIR/core/nftban_portscan_classic.sh"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
mkdir -p "$W/bin" "$W/log" "$W/etc"
cat > "$W/bin/logger" <<'STUB'
#!/usr/bin/env bash
echo "logger: socket /dev/log: Permission denied" >&2
exit 1
STUB
chmod +x "$W/bin/logger"

# 3 events in a loop, as the cycle does per scan line; the caller prints after each.
out=$(env -i PATH="$W/bin:/usr/bin:/bin" HOME="$W" NFTBAN_LOG_DIR="$W/log" NFTBAN_LIB_DIR="$LIBDIR" \
    NFTBAN_CONFIG_DIR="$W/etc" bash -c '
    set -Eeuo pipefail
    source "$0" >/dev/null 2>&1 || { echo SOURCE_FAILED; exit 9; }
    set -Eeuo pipefail
    for p in 40001 40002 40003; do
        _nftban_portscan_emit_event 192.0.2.50 192.0.2.10 "$p" TCP SYN "2026-11-26T20:12:17+00:00"
        echo "after:$p"
    done
    echo CYCLE_CONTINUED' "$SRC" 2>"$W/stderr")
rc=$?

echo "=== failing logger under set -Eeuo pipefail ==="
[[ "$out" == *"after:40001"*"after:40002"*"after:40003"*"CYCLE_CONTINUED"* && $rc -eq 0 ]] \
    && ok "the cycle continues past the event for every line (rc $rc)" || no "cycle aborted" "rc=$rc out=${out//$'\n'/ }"
n=$(grep -c 'src=192.0.2.50' "$W/log/portscan-events.log" 2>/dev/null || echo 0)
[[ "$n" == 3 ]] && ok "all 3 events still written to portscan-events.log" || no "event file" "lines=$n"
grep -q 'Permission denied' "$W/stderr" && no "logger stderr leaked" "$(cat "$W/stderr")" || ok "logger's stderr does not leak"

echo "=== static: every logger call in the file is non-fatal ==="
bad=$(grep -nE '^[[:space:]]*logger[[:space:]]' "$SRC" | while IFS=: read -r ln _; do
    seg=$(sed -n "${ln},$((ln+1))p" "$SRC")
    [[ "$seg" == *"|| true"* ]] || echo "$ln"
done)
[[ -z "$bad" ]] && ok "no unguarded logger call" || no "unguarded logger at line(s)" "$bad"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
