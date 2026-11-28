#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.238.2: host-owned addresses keep self-ban protection, no kernel accept (shell writers)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="whitelist_ownership_no_accept_v1238_2_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-11-28"
# meta:description="SEC-WHITELIST-SELF-ADDRESSES-INCLUDE-DOCKER-BRIDGE-AND-LINK-LOCAL-INPUT-ACCEPT (owner design 2026-11-28). The shell writers that put addresses straight into whitelist_ipv4/6 must skip addresses NFTBan recorded only because the host owns them, using nftban_whitelist_line_is_ownership_only (lib/nft_ipc.sh), the twin of the Go loader's ownershipOnlyLine (same table as internal/whitelist/loader_ownership_v1238_2_test.go). Checks: (1) the classifier table; (2) nftban_add_system_ip records an ownership address in 00-system.conf (self-ban protection) and makes NO kernel add, while an admin-session address is still added; (3) maintenance's re-sync loop applies the classifier and its public-IP change path no longer adds to the kernel set; (4) the flush restore applies the classifier to 00-system-ip.conf. Non-vacuity: on v1.238.1 the classifier is absent and every writer adds. Sandbox, reserved documentation IPs, stubbed nft/IPC; no traffic and no firewall change."
# meta:input="cli/lib/nftban/lib/nft_ipc.sh, cli/lib/nftban/core/nftban_system_ip.sh, cli/lib/nftban/cron/maintenance.sh, cli/lib/nftban/cli/cmd_flush.sh (repo, read-only); temp dirs"
# meta:output="Pass/fail assertions; exit 0 on all-pass, 1 on any failure"
# meta:depends="bash,mktemp,grep,awk"
# meta:inventory.files="cli/lib/nftban/lib/nft_ipc.sh,cli/lib/nftban/core/nftban_system_ip.sh,cli/lib/nftban/cron/maintenance.sh,cli/lib/nftban/cli/cmd_flush.sh"
# meta:inventory.binaries="bash,mktemp,grep,awk"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR,NFTBAN_WHITELIST_SYSTEM"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="whitelist_ownership_no_accept_v1238_2_test"
# meta:ta.owner="whitelist"
# meta:ta.module="whitelist"
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
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }
W=$(mktemp -d); trap 'rm -rf "${W:?}"' EXIT
mkdir -p "$W/bin" "$W/etc/whitelist.d"

echo "=== (1) classifier table (same rows as the Go loader test) ==="
cls() {   # cls <file> <line> [<prev>] -> own|trust|absent
    env -i PATH="/usr/bin:/bin" NFTBAN_LIB_DIR="$LIB" bash -c '
        source "$1/lib/nft_ipc.sh" >/dev/null 2>&1
        declare -F nftban_whitelist_line_is_ownership_only >/dev/null || { echo absent; exit 0; }
        nftban_whitelist_line_is_ownership_only "$2" "$3" "$4" && echo own || echo trust' _ "$LIB" "$1" "$2" "${3:-}"
}
A=" (added: 2026-11-28 10:00:00 UTC)"
while IFS='|' read -r want file line prev; do
    [[ -z "$want" ]] && continue
    got=$(cls "$file" "$line" "$prev")
    [[ "$got" == "$want" ]] && ok "$want: $file '${line:0:48}'" || no "$file '${line:0:48}'" "got $got, want $want"
done <<EOF
own|00-system.conf|192.0.2.10  # Server interface (auto-detected)$A|
own|00-system.conf|192.0.2.11  # Server public IPv4 (auto-detected)$A|
own|00-system.conf|2001:db8::11  # Server public IPv6 (auto-detected)$A|
own|00-system.conf|192.0.2.12  # Server IPv4 (auto-detected)|
own|00-system.conf|2001:db8::12  # Server IPv6 (auto-detected)|
own|00-system.conf|192.0.2.13|# Auto-added by maintenance: Fri Nov 28 10:00:00 UTC 2026
own|00-system.conf|2001:db8::13|# Auto-added IPv6 by maintenance: Fri Nov 28 10:00:00 UTC 2026
own|00-system-ip.conf|192.0.2.40|
trust|00-system.conf|127.0.0.1  # Localhost (critical)$A|
trust|00-system.conf|198.51.100.20  # Admin session (--protect-session)$A|
trust|00-system.conf|198.51.100.21  # SSH client IP (auto-detected)|
trust|00-system.conf|198.51.100.22  # Current user (whitelistme on 2026-11-28)$A|
trust|00-system.conf|198.51.100.24  # Admin session (enable lockout prevention)$A|
trust|00-system.conf|198.51.100.23|2001:db8::13
trust|99-manual.conf|192.0.2.50  # Server interface (auto-detected)|
EOF

echo "=== (2) nftban_add_system_ip: record for self-ban protection, no kernel add ==="
# Stubs: nft reports "not in set"; systemctl says the daemon runs; IPC and direct writes are recorded.
# "list tables" shows the table so the direct fallback is reachable when timeout cannot run the
# IPC shell function; "get element" says "not in set".
printf '#!/bin/sh\n[ "$1" = list ] && { echo "table ip nftban"; exit 0; }\nexit 1\n' > "$W/bin/nft"
printf '#!/bin/sh\nexit 0\n' > "$W/bin/systemctl"
chmod +x "$W/bin/nft" "$W/bin/systemctl"
addip() {   # addip <ip> <comment> -> "kernel_adds=<n>"
    : > "$W/calls"
    env -i PATH="$W/bin:/usr/bin:/bin" HOME="$W" NFTBAN_LIB_DIR="$LIB" NFTBAN_CONFIG_DIR="$W/etc" \
        NFTBAN_WHITELIST_SYSTEM="$W/etc/whitelist.d/00-system.conf" C="$W/calls" bash -c '
        source "$1/core/nftban_system_ip.sh" >/dev/null 2>&1 || { echo SOURCE_FAILED; exit 0; }
        # one line per call: the sourced library sets IFS to newline+tab, where "$*" joins with newlines
        nft_ipc_add_element(){ { printf "ipc"; printf " %s" "$@"; printf "\n"; } >> "$C"; return 0; }
        nftban_nft_write(){ { printf "nft"; printf " %s" "$@"; printf "\n"; } >> "$C"; return 0; }
        nftban_add_system_ip "$2" "$3" >/dev/null 2>&1
        echo "kernel_adds=$(grep -c . "$C")"' _ "$LIB" "$1" "$2"
}
r=$(addip 192.0.2.10 "Server interface (auto-detected)")
[[ "$r" == "kernel_adds=0" ]] && ok "interface address: no kernel add" || no "interface address" "$r"
grep -q '^192\.0\.2\.10  # Server interface (auto-detected)' "$W/etc/whitelist.d/00-system.conf" 2>/dev/null \
    && ok "interface address recorded in 00-system.conf (self-ban protection)" || no "interface address not recorded"
r=$(addip 192.0.2.11 "Server public IPv4 (auto-detected)")
[[ "$r" == "kernel_adds=0" ]] && ok "public address: no kernel add" || no "public address" "$r"
r=$(addip 198.51.100.20 "Admin session (--protect-session)")
[[ "$r" == "kernel_adds=1" ]] && ok "admin session: still added to the kernel set (anti-lockout)" || no "admin session" "$r"
r=$(addip 127.0.0.1 "Localhost (critical)")
[[ "$r" == "kernel_adds=1" ]] && ok "localhost: still added" || no "localhost" "$r"

echo "=== (3) maintenance: re-sync applies the classifier; public-IP change adds nothing to the kernel ==="
M="$LIB/cron/maintenance.sh"
loop=$(awk '/Ensure ALL IPs in 00-system.conf are loaded into nftables sets/{f=1} f{print} f&&/done < "\$\{NFTBAN_CONFIG_DIR\}\/whitelist.d\/00-system.conf"/{exit}' "$M")
c1=$(awk '/nftban_whitelist_line_is_ownership_only/ && !n {n=NR} END{print n}' <<<"$loop")
c2=$(awk '/nft_ipc_add_element/ && !n {n=NR} END{print n}' <<<"$loop")
[[ -n "$c1" && -n "$c2" && "$c1" -lt "$c2" ]] && ok "re-sync loop classifies each line before any kernel add" || no "re-sync loop" "classifier@${c1:-none} add@${c2:-none}"
if grep -qE 'nft_ipc_add_element .*whitelist_ipv[46] "\$current_ipv[46]"' "$M"; then
    no "public-IP change still adds the host's own address to the kernel set"
else
    ok "public-IP change: no kernel add of the host's own address"
fi

echo "=== (4) flush restore applies the classifier to 00-system-ip.conf ==="
F="$LIB/cli/cmd_flush.sh"
body=$(awk '/^_restore_system_whitelist\(\)/{f=1} f{print} f&&/^}/{exit}' "$F")
grep -q 'nftban_whitelist_line_is_ownership_only' <<<"$body" \
    && ok "flush restore classifies the file lines" || no "flush restore has no classifier"
grep -q 'SSH_CLIENT' <<<"$body" && ok "flush restore still restores the SSH client (anti-lockout)" || no "SSH client restore missing"

echo ""
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
[[ $FAIL -eq 0 ]]
