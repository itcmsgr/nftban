#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238.2: PortScan finds an EPEL Suricata (/usr/sbin) without losing an explicit path
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="portscan_suricata_binary_discovery_v1238_2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-28"
# meta:description="v1.238.2 (owner 2026-11-28, v1.238.1 RC row 7). On EL9 enforcing with EPEL Suricata running, PortScan auto resolved to classic (basis auto_suricata_unavailable): nftban_portscan_suricata_binary_exists tested only PORTSCAN_SURICATA_BINARY (shipped /usr/bin/suricata) and EPEL installs /usr/sbin/suricata. Sources the REAL nftban_portscan.sh + nftban_portscan_suricata.sh in a sandbox (fixture config dir, fake suricata executables, PATH without the host's sbin). Asserts: default value + binary only in PATH -> found, source PATH; an explicit non-default path that does not exist -> NOT found even though PATH has one (explicit meaning preserved); an explicit executable path -> found, source configured; nothing anywhere -> not found; the status-side private check gives the same answer as the resolver-side check in every case. The default-path case is SKIPPED (named, not passed) when the host itself has /usr/bin/suricata. Sandbox only; no firewall change."
# meta:input="cli/lib/nftban/core/nftban_portscan.sh, cli/lib/nftban/core/nftban_portscan_suricata.sh (repo, read-only); temp dirs"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,mktemp,grep"
# meta:inventory.files="cli/lib/nftban/core/nftban_portscan.sh,cli/lib/nftban/core/nftban_portscan_suricata.sh"
# meta:inventory.binaries="bash,mktemp,grep"
# meta:inventory.env_vars="NFTBAN_LOG_DIR,NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR,PORTSCAN_SURICATA_BINARY"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="portscan_suricata_binary_discovery_v1238_2_test"
# meta:ta.owner="portscan"
# meta:ta.module="portscan"
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
PS="$LIBDIR/core/nftban_portscan.sh"
PSS="$LIBDIR/core/nftban_portscan_suricata.sh"
PASS=0; FAIL=0; SKIP=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
skip(){ SKIP=$((SKIP+1)); echo "  - SKIP $1"; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
mkdir -p "$W/sbin" "$W/custom" "$W/empty" "$W/log" "$W/etc"
printf '#!/bin/sh\nexit 0\n' > "$W/sbin/suricata";  chmod +x "$W/sbin/suricata"
printf '#!/bin/sh\nexit 0\n' > "$W/custom/suri";    chmod +x "$W/custom/suri"

# probe <PATH> <PORTSCAN_SURICATA_BINARY or "-" for unset>
# prints: "<public rc> <private rc> <selected>"
probe() {
    local p="$1" b="$2"
    local -a envv=(PATH="$p" HOME="$W" NFTBAN_LOG_DIR="$W/log" NFTBAN_LIB_DIR="$LIBDIR" NFTBAN_CONFIG_DIR="$W/etc")
    [[ "$b" != "-" ]] && envv+=(PORTSCAN_SURICATA_BINARY="$b")
    env -i "${envv[@]}" bash -c '
        source "$1" >/dev/null 2>&1 || { echo SOURCE_FAILED_PS; exit 9; }
        source "$2" >/dev/null 2>&1 || { echo SOURCE_FAILED_PSS; exit 9; }
        set +e
        nftban_portscan_suricata_binary_exists; r1=$?
        sel="${_PORTSCAN_SURICATA_BINARY_SELECTED:-}"
        _nftban_portscan_suricata_binary_exists; r2=$?
        echo "$r1 $r2 $sel"' _ "$PS" "$PSS" 2>/dev/null
}

echo "=== default value, Suricata only in PATH (the EPEL /usr/sbin case) ==="
if [[ -x /usr/bin/suricata ]]; then
    skip "host has /usr/bin/suricata, so the default path answers first (case not exercised here)"
else
    out=$(probe "$W/sbin:/usr/bin:/bin" "/usr/bin/suricata")
    [[ "$out" == "0 0 $W/sbin/suricata (PATH)" ]] && ok "found via PATH; resolver and status agree ($out)" \
        || no "EPEL-style binary not found" "got: $out"
    out=$(probe "$W/sbin:/usr/bin:/bin" "-")
    [[ "$out" == "0 0 $W/sbin/suricata (PATH)" ]] && ok "unset value behaves as the default ($out)" \
        || no "unset value" "got: $out"
fi

echo "=== explicit non-default path that does not exist: no search ==="
out=$(probe "$W/sbin:/usr/bin:/bin" "$W/custom/missing")
[[ "$out" == "1 1 " ]] && ok "explicit path is honoured: not found although PATH has suricata" \
    || no "explicit path overridden by PATH search" "got: $out"

echo "=== explicit executable path ==="
out=$(probe "$W/empty:/usr/bin:/bin" "$W/custom/suri")
[[ "$out" == "0 0 $W/custom/suri (configured)" ]] && ok "explicit executable used ($out)" \
    || no "explicit executable" "got: $out"

echo "=== nothing anywhere ==="
if [[ -x /usr/bin/suricata || -x /bin/suricata ]]; then
    skip "host has suricata in /usr/bin or /bin (case not exercised here)"
else
    out=$(probe "$W/empty:/usr/bin:/bin" "/usr/bin/suricata")
    [[ "$out" == "1 1 " ]] && ok "not found when no executable exists" || no "phantom binary" "got: $out"
fi

echo "=== enable log line names the selected executable ==="
grep -q 'Suricata portscan detection enabled (binary: ${_PORTSCAN_SURICATA_BINARY_SELECTED' "$PSS" \
    && ok "enable logs the selected executable" || no "enable log line" "missing"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ $FAIL -eq 0 ]]
