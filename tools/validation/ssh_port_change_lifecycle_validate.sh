#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.155 - SSH-port-change lifecycle validator (READ-ONLY)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="ssh_port_change_lifecycle_validate" meta:type="tool" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="READ-ONLY validator (v1.155 PR-2 / item 3.3) for the SSH-port-change lifecycle invariants. Given the rendered nftables ruleset and the real sshd listeners, it asserts: (a) every sshd listener is in tcp_ports_in; (b) every sshd listener is in ssh_ports; (c) the brute-force ct-count rule references @ssh_ports (the set); (d) there is NO literal 'tcp dport <port>' ct-count rule for an sshd port (must use the set). Exit 0 iff all invariants hold. Mutates NOTHING: no nft write, no reload, no restart, no SSH-port change. Inputs auto-collected on a host, or injected via env for hermetic testing."
# meta:input="Live ruleset + listeners on a host, OR injected via NFTBAN_VALIDATE_RULESET_FILE / NFTBAN_VALIDATE_LISTENERS"
# meta:output="PASS/FAIL lines on stdout; exit 0 on all-pass, non-zero on drift"
# meta:depends="bash,grep,awk,sort,paste,tr"
# meta:inventory.files="cli/lib/nftban/lib/ssh_admin_port_guard.sh,cli/lib/nftban/lib/ssh_port_detect.sh"
# meta:inventory.binaries="nft,ss,sshd,grep,awk,sort,paste,tr"
# meta:inventory.env_vars="NFTBAN_TABLE_IPV4,NFTBAN_VALIDATE_RULESET_FILE,NFTBAN_VALIDATE_LISTENERS,NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root for live collection (read-only nft/ss/sshd -T); none when inputs injected"
# =============================================================================
#
# READ-ONLY by construction: every external call is a query (nft list / ss /
# sshd -T). There is NO nft add/delete/flush, NO reload/rebuild, NO restart,
# NO sshd_config edit, NO SSH-port change.
set -Eeuo pipefail

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }

# --- Input 1: rendered ruleset --------------------------------------------
# Hermetic override: NFTBAN_VALIDATE_RULESET_FILE points at a captured
# `nft list ruleset` (or equivalent) fixture. Otherwise read live (read-only).
_collect_ruleset() {
    if [[ -n "${NFTBAN_VALIDATE_RULESET_FILE:-}" ]]; then
        cat "${NFTBAN_VALIDATE_RULESET_FILE}" 2>/dev/null || true
        return 0
    fi
    command -v nft >/dev/null 2>&1 || return 0
    nft list ruleset 2>/dev/null || true
}

# --- Input 2: sshd listeners ----------------------------------------------
# Hermetic override: NFTBAN_VALIDATE_LISTENERS = space/comma/newline-separated
# port list. Otherwise use the guard lib's detector (read-only).
_collect_listeners() {
    if [[ -n "${NFTBAN_VALIDATE_LISTENERS:-}" ]]; then
        printf '%s\n' "${NFTBAN_VALIDATE_LISTENERS}" | tr ', ' '\n' | grep -E '^[0-9]+$' | sort -un || true
        return 0
    fi
    local guard="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/ssh_admin_port_guard.sh"
    if [[ -r "$guard" ]]; then
        # shellcheck source=/dev/null
        source "$guard" 2>/dev/null || true
        if declare -f _nftban_ssh_listeners >/dev/null 2>&1; then
            _nftban_ssh_listeners 2>/dev/null | sort -un || true
            return 0
        fi
    fi
    # Last-resort direct query (read-only).
    if command -v sshd >/dev/null 2>&1; then
        sshd -T 2>/dev/null | awk '/^port /{print $2}' | sort -un || true
    fi
}

# --- elements of an nftables named set, from a rendered ruleset -----------
# Matches a `set <name> { ... elements = { 22, 2222 } ... }` block (single- or
# multi-line) and prints the numeric elements, sorted-unique.
_set_elements() {
    local ruleset="$1" name="$2"
    # Normalize to a single stream; the `elements = { ... }` clause may span lines.
    printf '%s\n' "$ruleset" \
        | tr '\n' ' ' \
        | grep -oE "set[[:space:]]+${name}[[:space:]]*\{[^}]*elements[[:space:]]*=[[:space:]]*\{[^}]*\}" \
        | grep -oE 'elements[[:space:]]*=[[:space:]]*\{[^}]*\}' \
        | grep -oE '[0-9]+' \
        | sort -un || true
}

main() {
    local ruleset listeners
    ruleset="$(_collect_ruleset)"
    listeners="$(_collect_listeners)"

    echo "============================================================"
    echo "SSH-port-change lifecycle validator (READ-ONLY)"
    echo "MODE: read-only — no nft mutation, no reload, no restart"
    echo "============================================================"

    if [[ -z "$ruleset" ]]; then
        bad "no rendered ruleset available (NFTBAN_VALIDATE_RULESET_FILE unset and 'nft list ruleset' empty)"
    fi
    if [[ -z "$listeners" ]]; then
        bad "no sshd listeners detected (NFTBAN_VALIDATE_LISTENERS unset and detector returned nothing)"
    fi
    if [[ -z "$ruleset" || -z "$listeners" ]]; then
        echo "------------------------------------------------------------"
        echo "RESULT: PASS=$PASS FAIL=$FAIL (cannot validate without both inputs)"
        return 1
    fi

    local tcp_in ssh_set lp
    tcp_in="$(_set_elements "$ruleset" tcp_ports_in)"
    ssh_set="$(_set_elements "$ruleset" ssh_ports)"
    echo "  listeners:     $(printf '%s' "$listeners" | paste -sd, -)"
    echo "  tcp_ports_in:  $(printf '%s' "$tcp_in" | paste -sd, -)"
    echo "  ssh_ports:     $(printf '%s' "$ssh_set" | paste -sd, -)"
    echo "------------------------------------------------------------"

    # (a) every sshd listener ∈ tcp_ports_in
    local miss_a=""
    while IFS= read -r lp; do
        [[ -z "$lp" ]] && continue
        printf '%s\n' "$tcp_in" | grep -qx "$lp" || miss_a+="${miss_a:+,}$lp"
    done <<< "$listeners"
    if [[ -z "$miss_a" ]]; then
        ok "(a) every sshd listener is in tcp_ports_in"
    else
        bad "(a) sshd listener(s) NOT in tcp_ports_in: $miss_a (SSH service port would be filtered)"
    fi

    # (b) every sshd listener ∈ ssh_ports
    local miss_b=""
    while IFS= read -r lp; do
        [[ -z "$lp" ]] && continue
        printf '%s\n' "$ssh_set" | grep -qx "$lp" || miss_b+="${miss_b:+,}$lp"
    done <<< "$listeners"
    if [[ -z "$miss_b" ]]; then
        ok "(b) every sshd listener is in ssh_ports"
    else
        bad "(b) sshd listener(s) NOT in ssh_ports: $miss_b (brute-force rate-limit would miss this port)"
    fi

    # (c) the brute-force ct-count rule references @ssh_ports (the set)
    if printf '%s\n' "$ruleset" | grep -Eq 'tcp[[:space:]]+dport[[:space:]]+@ssh_ports[[:space:]].*ct[[:space:]]+count'; then
        ok "(c) brute-force ct-count rule references @ssh_ports"
    else
        bad "(c) no 'tcp dport @ssh_ports ... ct count' rule found (set-driven rate-limit missing)"
    fi

    # (d) NO literal 'tcp dport <sshport> ... ct count' rule for an sshd port
    #     (it must go through the set, not a hardcoded literal).
    local lit_bad=""
    while IFS= read -r lp; do
        [[ -z "$lp" ]] && continue
        if printf '%s\n' "$ruleset" \
            | grep -E "tcp[[:space:]]+dport[[:space:]]+${lp}[[:space:]].*ct[[:space:]]+count" \
            | grep -qv '@ssh_ports'; then
            lit_bad+="${lit_bad:+,}$lp"
        fi
    done <<< "$listeners"
    if [[ -z "$lit_bad" ]]; then
        ok "(d) no literal 'tcp dport <sshport> ... ct count' rule (set-driven only)"
    else
        bad "(d) literal ct-count rule for sshd port(s) $lit_bad — must use @ssh_ports, not a literal dport"
    fi

    echo "------------------------------------------------------------"
    echo "RESULT: PASS=$PASS FAIL=$FAIL"
    [[ $FAIL -eq 0 ]]
}

main "$@"
