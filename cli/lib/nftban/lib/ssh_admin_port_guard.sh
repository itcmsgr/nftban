#!/usr/bin/env bash
# =============================================================================
# NFTBan - External admin SSH-port guard (OBS-SSHPORT-55000-FAMILY)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="ssh_admin_port_guard" meta:type="lib" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Warn-only + lockout-net guard for hosts where admin SSH arrives on an EXTERNAL redirect/NAT port (e.g. :55000 -> :22 via firewalld/iptables-nft/provider) that nftban does NOT own. nftban's ssh_ports stays the ACTUAL sshd listener set (it is NOT a NAT manager); before a rebuild/takeover that could disrupt the external redirect, this guard WARNS and session-whitelists the active admin source IP (via the existing IPC whitelist-session path) so SSH survives by IP regardless of the external port. It does NOT import the external port into ssh_ports and does NOT recreate/preserve the redirect."
# meta:inventory.files="/usr/lib/nftban/lib/ssh_port_detect.sh"
# meta:inventory.binaries="ss,grep,awk,sort,paste,tr,nft"
# meta:inventory.env_vars="NFTBAN_EXTERNAL_ADMIN_SSH_PORTS,SSH_CLIENT,SSH_CONNECTION,NFTBAN_NO_PREREBUILD_LOCKOUT,NFTBAN_PREREBUILD_LOCKOUT_TTL,NFTBAN_LIB_DIR,NFTBAN_TABLE_IPV4"
# meta:inventory.config_files="/etc/nftban/conf.d,/etc/nftban/nftban.conf.local"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (read-only audit); lockout-net write goes through the sanctioned IPC whitelist-session path only"
# =============================================================================
# Strategy (operator-locked SELECT_SSHPORT_55000_STRATEGY = WARN_ONLY_PLUS_LOCKOUT_NET):
#   A warn-only + B lockout-net. REJECT importing :55000 into ssh_ports (ssh_ports
#   drives the brute-force ct-count on the real sshd LISTENER; the external port is
#   not a listener). REJECT preserving/recreating the external NAT/redirect (nftban
#   is an ingress IPS, not a NAT manager). No direct nft writes here — the only
#   firewall mutation is via _whitelist_session_add (IPC).
# =============================================================================

# Per NFTBan coding standards this library declares `set -Eeuo pipefail`. It is
# sourced into already-strict callers (cmd_firewall.sh sets it at file top), so
# this is a redundant no-op there; every function below is written set-e-safe
# (failable pipelines/substitutions are guarded with `|| true` / condition context).
set -Eeuo pipefail

# nftban_ssh_external_admin_ports — print declared external admin SSH ports (operator
# config NFTBAN_EXTERNAL_ADMIN_SSH_PORTS, comma/space separated), sorted-unique numeric.
nftban_ssh_external_admin_ports() {
    local raw="${NFTBAN_EXTERNAL_ADMIN_SSH_PORTS:-}"
    [[ -z "$raw" ]] && return 0
    printf '%s\n' "$raw" | tr ', ' '\n' | grep -E '^[0-9]+$' | awk '$1>=1 && $1<=65535' | sort -un
}

# nftban_ssh_active_admin_ip — source IP of the current SSH session, or nothing.
nftban_ssh_active_admin_ip() {
    if [[ -n "${SSH_CLIENT:-}" ]]; then printf '%s\n' "${SSH_CLIENT%% *}"; return 0; fi
    if [[ -n "${SSH_CONNECTION:-}" ]]; then printf '%s\n' "${SSH_CONNECTION%% *}"; return 0; fi
    return 1
}

# nftban_ssh_active_admin_port — server port the current SSH session landed on
# (post-DNAT, so on an external-redirect host this is the real listener, e.g. 22).
nftban_ssh_active_admin_port() {
    if [[ -n "${SSH_CONNECTION:-}" ]]; then printf '%s\n' "${SSH_CONNECTION##* }"; return 0; fi
    # SSH_CLIENT = "<client-ip> <client-port> <server-port>" — 3rd field is the local port.
    if [[ -n "${SSH_CLIENT:-}" ]]; then
        local _p; _p=$(printf '%s\n' "${SSH_CLIENT}" | awk '{print $3}')
        [[ -n "$_p" ]] && { printf '%s\n' "$_p"; return 0; }
    fi
    return 1
}

# _nftban_ssh_ports_kernel — read-only: the ports currently in the nftban ssh_ports set.
_nftban_ssh_ports_kernel() {
    nft list set "${NFTBAN_TABLE_IPV4:-ip nftban}" ssh_ports 2>/dev/null \
        | grep -oE 'elements = \{[^}]*\}' | grep -oE '[0-9]+' | sort -un
}

# _nftban_ssh_listeners — sshd listener ports (via the v1.145 detector if present).
_nftban_ssh_listeners() {
    if declare -f nftban_detect_ssh_ports >/dev/null 2>&1; then
        nftban_detect_ssh_ports 2>/dev/null
    elif [[ -r "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/ssh_port_detect.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/ssh_port_detect.sh" 2>/dev/null
        nftban_detect_ssh_ports 2>/dev/null
    else
        ss -tlnH 2>/dev/null | awk '{print $4}' | grep -oE ':[0-9]+$' | tr -d ':' | sort -un
    fi
}

# _nftban_sshd_configured_ports — read-only: the Port value(s) sshd is CONFIGURED with
# (from `sshd -T`), sorted-unique numeric. This is the EFFECTIVE config, which on a
# socket-activated sshd may differ from what is actually being listened on (the socket
# unit owns the ListenStream until it is restarted). Empty if sshd is unavailable.
_nftban_sshd_configured_ports() {
    command -v sshd >/dev/null 2>&1 || return 0
    sshd -T 2>/dev/null | awk '/^port /{print $2}' | grep -E '^[0-9]+$' | sort -un || true
}

# _nftban_ssh_socket_activated — read-only: succeed (rc 0) iff sshd is socket-activated,
# i.e. an ssh.socket / sshd.socket unit is active. On such a host a changed `Port` in
# sshd_config does NOT take effect until that socket unit is restarted, because the
# socket unit (not sshd) owns the ListenStream. Returns 1 on a plain sshd.service host.
_nftban_ssh_socket_activated() {
    command -v systemctl >/dev/null 2>&1 || return 1
    local u st
    for u in ssh.socket sshd.socket; do
        st="$(systemctl is-active "$u" 2>/dev/null || true)"
        [[ "$st" == "active" ]] && return 0
    done
    return 1
}

# nftban_ssh_socket_port_mismatch_audit — PR-1 (item 3.2): on a SOCKET-ACTIVATED sshd,
# detect when the configured Port (`sshd -T`) no longer matches the actual listeners
# (the socket unit was not restarted after the config change). Read-only: no nft, no
# restart. Emits ONE calm warning naming the class + the VERBATIM remediation when, and
# only when, configured != listening AND sshd is socket-activated. Silent otherwise.
nftban_ssh_socket_port_mismatch_audit() {
    # Only socket-activated sshd has this pitfall; plain sshd.service applies Port on
    # reload, so configured==listening by construction → nothing to warn about.
    _nftban_ssh_socket_activated || return 0
    local configured listening
    configured="$(_nftban_sshd_configured_ports | paste -sd, -)" || true
    listening="$(_nftban_ssh_listeners 2>/dev/null | sort -un | paste -sd, -)" || true
    # If we cannot read either side, do not guess.
    [[ -z "$configured" || -z "$listening" ]] && return 0
    [[ "$configured" == "$listening" ]] && return 0
    {
        echo "  ⚠ socket-activated sshd port mismatch: sshd is CONFIGURED for :${configured}"
        echo "    but is actually LISTENING on :${listening}. On a socket-activated sshd the"
        echo "    ssh.socket unit owns the ListenStream, so a changed Port in sshd_config does"
        echo "    not take effect until the socket unit is restarted. nftban protects the REAL"
        echo "    listeners; ssh_ports follows :${listening} until the socket is reloaded. To apply"
        echo "    the configured port, restart the socket unit:"
        echo "      systemctl daemon-reload && systemctl restart ssh.socket"
    } >&2
    return 0
}

# nftban_ssh_admin_port_audit — S1: read-only report of sshd listeners vs ssh_ports vs
# declared external admin ports + the active admin session, flagging external redirects.
nftban_ssh_admin_port_audit() {
    local listeners ssh_set declared active_ip active_port mismatch=0 p
    listeners=$(_nftban_ssh_listeners | paste -sd, -) || true
    ssh_set=$(_nftban_ssh_ports_kernel | paste -sd, -) || true
    declared=$(nftban_ssh_external_admin_ports | paste -sd, -) || true
    active_ip=$(nftban_ssh_active_admin_ip 2>/dev/null || echo "(not an ssh session)")
    active_port=$(nftban_ssh_active_admin_port 2>/dev/null || echo "-")
    echo "SSH admin-port audit (OBS-SSHPORT-55000-FAMILY):"
    echo "  sshd listeners (detected):     ${listeners:-none}"
    echo "  nftban ssh_ports (protected):  ${ssh_set:-none}"
    echo "  declared external admin ports: ${declared:-none}   (set NFTBAN_EXTERNAL_ADMIN_SSH_PORTS to declare)"
    echo "  active admin session:          ip=${active_ip}  landed-port=${active_port}"
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        if ! _nftban_ssh_listeners | grep -qx "$p"; then
            echo "  ⚠ external admin port :$p is NOT an sshd listener → it reaches :$active_port via an EXTERNAL redirect/NAT"
            echo "    (firewalld / iptables-nft / provider / panel). nftban does NOT own that path; a rebuild/takeover may"
            echo "    disrupt :$p while ssh_ports (${ssh_set:-?}) stays valid. nftban will NOT import :$p into ssh_ports"
            echo "    (it is not a listener) and will NOT recreate the NAT — keep the redirect in the host firewall layer."
            mismatch=1
        fi
    done < <(nftban_ssh_external_admin_ports)
    [[ $mismatch -eq 0 ]] && echo "  ✓ no external-admin-port mismatch (ssh_ports reflects the real sshd listeners)."
    # PR-1 (item 3.2): socket-activated sshd port-mismatch section (text-mode; warns to
    # stderr only on a real mismatch, otherwise silent — does not break audit output).
    nftban_ssh_socket_port_mismatch_audit || true
    return 0
}

# _nftban_ssh_external_admin_risk_ports — print the declared external admin ports that
# are NOT a real sshd listener (i.e. the external :55000->:22 redirect risk class).
# Empty output = no risk: a normal :22 host (nothing declared) or a host where the
# declared port is a genuine sshd listener (already in ssh_ports via normal detection).
_nftban_ssh_external_admin_risk_ports() {
    local declared listeners p
    declared=$(nftban_ssh_external_admin_ports) || true
    [[ -z "$declared" ]] && return 0
    listeners=$(_nftban_ssh_listeners 2>/dev/null) || true
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        # If the declared port is a real listener it is in-authority (no risk); skip it.
        printf '%s\n' "$listeners" | grep -qx "$p" || printf '%s\n' "$p"
    done <<< "$declared"
}

# nftban_ssh_pre_rebuild_lockout_guard <op> [op-args...] — S2: called BEFORE a
# rebuild/reload/takeover. NARROWED (operator N1 decision 2026-06-05): acts ONLY on the
# external-admin-port RISK class — a declared NFTBAN_EXTERNAL_ADMIN_SSH_PORTS port that
# is NOT a real sshd listener (external :55000->:22 redirect). For that class it WARNS
# and session-whitelists the active admin source IP (IPC lockout-net), so SSH survives
# by IP while the external redirect is disturbed. It is a TRUE no-op on a normal :22
# host and on a host with a native :55000 listener (no warning, no whitelist, no nested
# reload), as well as when not in an SSH session, on dry-run, on opt-out, or on re-entry.
nftban_ssh_pre_rebuild_lockout_guard() {
    local op="${1:-rebuild}"; shift 2>/dev/null || true
    # re-entry / recursion guard: whitelist-session add itself triggers a reload.
    [[ "${_NFTBAN_PREREBUILD_GUARD_ACTIVE:-0}" == "1" ]] && return 0
    [[ "${NFTBAN_NO_PREREBUILD_LOCKOUT:-0}" == "1" ]] && return 0
    local admin_ip; admin_ip=$(nftban_ssh_active_admin_ip 2>/dev/null) || return 0
    [[ -z "$admin_ip" ]] && return 0
    # NARROWED gate: only the external-admin-port risk class triggers warn + lockout-net.
    # Normal :22 / native :55000-listener hosts have no risk → true no-op below.
    local risk; risk=$(_nftban_ssh_external_admin_risk_ports | paste -sd, -) || true
    [[ -z "$risk" ]] && return 0
    local dry=0 a
    for a in "$@"; do case "$a" in --dry-run|-n) dry=1 ;; esac; done
    local ssh_set; ssh_set=$(_nftban_ssh_ports_kernel | paste -sd, -) || true
    {
        echo "  ⚠ NFTBan ${op}: external admin SSH port(s) (:${risk}) reach sshd via an EXTERNAL redirect/NAT,"
        echo "    not an sshd listener. nftban ssh_ports stays the ACTUAL listener set (${ssh_set:-?}); nftban will"
        echo "    NOT preserve the external NAT/redirect for :${risk} (host-managed: firewalld/iptables-nft/provider)."
    } >&2
    if [[ $dry -eq 1 ]]; then
        echo "  (dry-run: would session-whitelist ${admin_ip} as a ${op} lockout-net; no change made)" >&2
        return 0
    fi
    # Lockout-net via the sanctioned IPC whitelist-session path (no direct nft).
    if declare -f _whitelist_session_add >/dev/null 2>&1; then
        export _NFTBAN_PREREBUILD_GUARD_ACTIVE=1
        if _whitelist_session_add "$admin_ip" --ttl "${NFTBAN_PREREBUILD_LOCKOUT_TTL:-1h}" \
               --reason "pre-${op}-lockout-net" >/dev/null 2>&1; then
            echo "  ✓ lockout-net: ${admin_ip} session-whitelisted for the ${op} (TTL ${NFTBAN_PREREBUILD_LOCKOUT_TTL:-1h})." >&2
        else
            echo "  (lockout-net: could not session-whitelist ${admin_ip}; proceeding — :ssh_ports access unaffected)" >&2
        fi
        unset _NFTBAN_PREREBUILD_GUARD_ACTIVE
    fi
    return 0
}

export -f nftban_ssh_external_admin_ports nftban_ssh_active_admin_ip nftban_ssh_active_admin_port \
          _nftban_ssh_ports_kernel _nftban_ssh_listeners _nftban_ssh_external_admin_risk_ports \
          _nftban_sshd_configured_ports _nftban_ssh_socket_activated nftban_ssh_socket_port_mismatch_audit \
          nftban_ssh_admin_port_audit nftban_ssh_pre_rebuild_lockout_guard 2>/dev/null || true
