#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="nftban_port_allow" meta:type="lib" meta:version="1.235.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Per-IP port grants (nftban port allow): the config-file helpers and the REPLAY that re-applies every live grant from access.d/port_allow.conf into the kernel port_allow_* sets. A rebuild/reset re-creates those sets EMPTY (nftables.conf.tpl), so without a replay every per-IP grant on a non-SSH port was lost until re-added by hand (PORT-ALLOW-NOT-REPLAYED-AFTER-REBUILD, measured on lab3 2026-10-03). Callers: firewall rebuild/reset (immediately) and the maintenance cycle (self-heal, also covers boot). Grants go through the daemon IPC (access_allow), never a direct nft call."
# meta:inventory.files="/etc/nftban/access.d/port_allow.conf"
# meta:inventory.binaries="jq,date,awk,mktemp"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR"
# meta:inventory.config_files="/etc/nftban/access.d/port_allow.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network="/run/nftban/nftband.sock"
# meta:inventory.privileges="root"

# Double-load prevention (sourced by cmd_port.sh, cmd_firewall.sh, cron/maintenance.sh)
[[ -n "${_NFTBAN_PORT_ALLOW_LOADED:-}" ]] && return 0 2>/dev/null || true
_NFTBAN_PORT_ALLOW_LOADED=1

# The replay talks to the daemon, so this library must not depend on its caller
# having loaded the IPC client. cmd_firewall.sh never sources nft_ipc.sh: measured
# on lab3 (v1.235 lane), the rebuild-time replay saw nft_ipc_is_daemon_running as
# "command not found" and reported the RUNNING daemon as down.
if ! declare -F nft_ipc_is_daemon_running >/dev/null 2>&1; then
    # shellcheck source=/usr/lib/nftban/lib/nft_ipc.sh
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_ipc.sh" 2>/dev/null || true
fi

# Line format (written by `nftban port allow add`):
#   port|ip|proto|timeout_seconds|comment|added_at_iso8601_utc
# timeout_seconds = 0 means permanent. The duration is stored, not an absolute
# expiry, so the expiry is derived as added_at + timeout_seconds.
nftban_port_allow_config_path() {
    printf '%s' "${NFTBAN_CONFIG_DIR:-/etc/nftban}/access.d/port_allow.conf"
}

# Remaining lifetime of one grant. Prints PERM, EXPIRED or the remaining seconds.
# rc 1 = the stored timeout/date cannot be interpreted (the grant is NOT replayed:
# an unreadable expiry must never become a permanent grant).
nftban_port_allow_remaining() {
    local tsec="$1" iso="$2" now="$3" start left
    [[ "$tsec" =~ ^[0-9]+$ ]] || return 1
    if [[ "$tsec" -eq 0 ]]; then printf 'PERM'; return 0; fi
    start=$(date -u -d "$iso" +%s 2>/dev/null) || return 1
    [[ "$start" =~ ^[0-9]+$ ]] || return 1
    left=$(( start + tsec - now ))
    if [[ "$left" -le 0 ]]; then printf 'EXPIRED'; else printf '%s' "$left"; fi
}

# Remove every config line for exactly <port> <ip> <proto> (field match, not a
# regex: the pre-v1.235 `sed /port|ip|proto|/d` also deleted 8080 when removing
# 80, and treated the dots of the IP as wildcards). Prints the number removed.
nftban_port_allow_drop_entry() {
    local port="$1" ip="$2" proto="$3" conf tmp before after
    conf=$(nftban_port_allow_config_path)
    [[ -f "$conf" ]] || { printf '0'; return 0; }
    tmp=$(mktemp "${conf}.XXXXXX") || return 1
    awk -F'|' -v p="$port" -v i="$ip" -v r="$proto" '!($1==p && $2==i && $3==r)' "$conf" > "$tmp" || { rm -f "$tmp"; return 1; }
    before=$(awk 'END{print NR}' "$conf"); after=$(awk 'END{print NR}' "$tmp")
    chmod 640 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$conf" || { rm -f "$tmp"; return 1; }
    printf '%s' "$(( before - after ))"
}

# Re-apply every live grant to the kernel through the daemon.
# Prints one summary line: "port-allow replay: replayed=N expired=N failed=N invalid=N".
# rc 0 = every live grant was applied (or none configured)
#    1 = at least one grant failed or was unreadable
#    2 = UNMEASURED: the daemon is not running, nothing was applied
nftban_port_allow_replay() {
    local conf replayed=0 expired=0 failed=0 invalid=0
    conf=$(nftban_port_allow_config_path)
    if [[ ! -s "$conf" ]]; then
        printf 'port-allow replay: no grants configured\n'
        return 0
    fi
    if ! nft_ipc_is_daemon_running 2>/dev/null; then
        printf 'port-allow replay: UNMEASURED (daemon not running; grants NOT applied)\n'
        return 2
    fi
    local now port ip proto tsec iso left params response
    now=$(date -u +%s)
    while IFS='|' read -r port ip proto tsec _ iso || [[ -n "$port" ]]; do
        [[ -z "$port" || "$port" == \#* ]] && continue
        proto="${proto,,}"
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -lt 1 || "$port" -gt 65535 ]] \
           || [[ "$proto" != "tcp" && "$proto" != "udp" ]] \
           || [[ "$ip" != *.* && "$ip" != *:* ]]; then
            invalid=$(( invalid + 1 )); continue
        fi
        if ! left=$(nftban_port_allow_remaining "$tsec" "$iso" "$now"); then
            invalid=$(( invalid + 1 )); continue
        fi
        if [[ "$left" == "EXPIRED" ]]; then expired=$(( expired + 1 )); continue; fi
        [[ "$left" == "PERM" ]] && left=0
        if ! params=$(jq -nc --arg ip "$ip" --argjson port "$port" --arg protocol "$proto" \
                         --argjson timeout "$left" \
                         '{ip: $ip, port: $port, protocol: $protocol, timeout: $timeout}'); then
            failed=$(( failed + 1 )); continue
        fi
        response=$(nft_ipc_request "access_allow" "$params" 2>/dev/null) || response=""
        if nft_ipc_success "$response" 2>/dev/null; then
            replayed=$(( replayed + 1 ))
        else
            failed=$(( failed + 1 ))
        fi
    done < "$conf"
    printf 'port-allow replay: replayed=%s expired=%s failed=%s invalid=%s\n' \
        "$replayed" "$expired" "$failed" "$invalid"
    [[ "$failed" -eq 0 && "$invalid" -eq 0 ]] || return 1
    return 0
}
