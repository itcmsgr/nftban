#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.145 - Runtime SSH-port detection wrapper (PR-B)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="ssh_port_detect" meta:type="lib" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Runtime SSH-port detection: union of all SSH listener/config ports via the Go helper binary, with a conservative ListenAddress-aware pure-shell fallback. Replaces scalar head -1 detectors (PR-B)."
# meta:inventory.files=""
# meta:inventory.binaries="nftban-detect-ssh-ports,ss,grep,awk,sort"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_DATA_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files="/etc/ssh/sshd_config,/etc/ssh/sshd_config.d,/etc/nftban/nftban.conf.local"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
#
# Authority model: the Go binary /usr/lib/nftban/bin/nftban-detect-ssh-ports
# (DetectSSHPortsUnion) is the single detector authority shared by the installer
# and runtime. The pure-shell fallback below is conservative and used ONLY when
# the binary is missing (install-transition / partial install). Both emit a
# sorted-unique port list, one per line. No scalar `head -1` SSH detection.
#
# Per NFTBan coding standards this library declares `set -Eeuo pipefail`
# (sourcing it enables strict mode caller-side, matching nft_schema.sh). The
# detection functions below are explicitly hardened to remain correct under
# errexit/pipefail (non-matching greps and head-pipe SIGPIPE are guarded).
set -Eeuo pipefail

NFTBAN_SSH_DETECT_BIN="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-detect-ssh-ports"

# nftban_detect_ssh_ports — print the sorted-unique union of all detected SSH
# ports, one per line. Primary path = the Go helper binary; fallback = shell.
# Returns 0 if at least one port is printed, 1 if none found.
nftban_detect_ssh_ports() {
    # set -e safe: this library is sourced into strict-mode callers, so every
    # command substitution that may exit non-zero is guarded.
    local out=""
    if [[ -x "$NFTBAN_SSH_DETECT_BIN" ]]; then
        out=$("$NFTBAN_SSH_DETECT_BIN" 2>/dev/null) || out=""
        if [[ -n "$out" ]]; then
            printf '%s\n' "$out"
            return 0
        fi
    fi
    out=$(_nftban_ssh_detect_fallback) || out=""
    if [[ -n "$out" ]]; then
        printf '%s\n' "$out"
        return 0
    fi
    return 1
}

# nftban_detect_ssh_primary_port — print ONE port (the lowest of the union).
# DISPLAY / single-value back-compat ONLY. Enforcement paths MUST use the full
# union via nftban_detect_ssh_ports. This named helper exists so a single-value
# need never silently re-introduces `head -1` scalar detection (PR-B rule).
# Prints nothing and returns 1 if no port is detected.
nftban_detect_ssh_primary_port() {
    local first
    # `| head -1` closes the pipe early (SIGPIPE) — guard for pipefail callers.
    first=$(nftban_detect_ssh_ports | head -1) || first=""
    if [[ -n "$first" ]]; then
        printf '%s\n' "$first"
        return 0
    fi
    return 1
}

# _nftban_listenaddr_port <token> — echo the port from a ListenAddress address
# token, or nothing. Mirrors the Go detector's listenAddressPort:
#   host:port        -> port (exactly one colon)
#   [ipv6]:port      -> port (bracketed)
#   host             -> nothing
#   bare ipv6 (::)   -> nothing (the multi-colon no-bracket trap)
_nftban_listenaddr_port() {
    local tok="$1" colons
    if [[ "$tok" =~ ^\[.*\]:([0-9]+)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    colons="${tok//[^:]/}"
    if [[ "${#colons}" -eq 1 && "$tok" =~ :([0-9]+)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

# _nftban_ssh_detect_fallback — conservative pure-shell union (binary missing).
# Sources: ss listeners + sshd_config/drop-in Port + ListenAddress + state file
# + conf.local SSH_PORT. Output: sorted-unique numeric ports. Config paths are
# overridable (NFTBAN_SSHD_CONFIG / NFTBAN_SSHD_CONFIG_D) for tests.
_nftban_ssh_detect_fallback() {
    # Run the whole collection in a subshell with errexit/pipefail OFF so a
    # non-matching grep (a normal "no such directive" outcome) never aborts a
    # strict-mode caller. The subshell's final `sort` determines exit status.
    ( set +e +o pipefail
    local _sshd="${NFTBAN_SSHD_CONFIG:-/etc/ssh/sshd_config}"
    local _sshd_d="${NFTBAN_SSHD_CONFIG_D:-/etc/ssh/sshd_config.d}"
    {
        # 1. ss listeners (IPv4 / IPv6 / dual-stack); port = last colon of the
        #    local-address field; works for 0.0.0.0:22 and [::]:55000.
        ss -tlnp 2>/dev/null | awk '
            /sshd/ {
                n = split($4, a, ":");
                if (a[n] ~ /^[0-9]+$/) print a[n];
            }'

        # 2. sshd_config + drop-ins: Port and ListenAddress.
        local _f _line _tok _p
        for _f in "$_sshd" "$_sshd_d"/*.conf; do
            [[ -f "$_f" ]] || continue
            grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' "$_f" 2>/dev/null | awk '{print $2}'
            while IFS= read -r _line; do
                _tok=$(awk '{print $2}' <<<"$_line")
                _p=$(_nftban_listenaddr_port "$_tok")
                [[ -n "$_p" ]] && printf '%s\n' "$_p"
            done < <(grep -iE '^[[:space:]]*ListenAddress[[:space:]]+' "$_f" 2>/dev/null)
        done

        # 3. state file
        local _sf="${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/ssh_port_active.state"
        [[ -f "$_sf" ]] && grep -E '^[0-9]+$' "$_sf" 2>/dev/null

        # 4. conf.local SSH_PORT=
        local _cl="${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local"
        [[ -f "$_cl" ]] && grep -E '^[[:space:]]*SSH_PORT=' "$_cl" 2>/dev/null \
            | sed -E 's/^[[:space:]]*SSH_PORT=["'"'"']?([0-9]+).*/\1/'
    } 2>/dev/null | grep -E '^[0-9]+$' | awk '$1>=1 && $1<=65535' | sort -un
    )
}
