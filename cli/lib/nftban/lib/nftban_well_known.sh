#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.127 - Well-known infrastructure IP advisory library
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_well_known"
# meta:type="lib"
# meta:version="1.127.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-24"
# meta:description="V127 UX-2 lane: shared helper that identifies well-known public infrastructure IPs (major DNS resolvers from Cloudflare/Google/Quad9/OpenDNS). Used by cmd_ban.sh and cmd_search.sh to surface an advisory + require explicit --yes override before mutating such addresses. Inline list (NO /etc/nftban/ fixture and NO package payload registration) to honor operator constraint that UX-2 must not change packaging behavior. Categories covered: IPv4 + IPv6 anycast resolvers from the 4 most-recognized providers. Out of scope for this initial cut: CIDR matching (treats inputs as exact-match keys), Quad9-secondary unicast, regional anycast variants, CDN edge prefixes (Cloudflare/Akamai/CloudFront IP ranges — those belong to the trust-provider pipeline, not this advisory)."
# meta:input="IP address (string) via nftban_is_well_known_infra_ip <ip>"
# meta:output="rc=0 if well-known (provider name to stdout); rc=1 if not well-known (no output)"
# meta:depends="bash"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Scope: AUDIT_190_LIFECYCLE/V127_FULL_UX_CORRECTION_UMBRELLA_SCOPE.md (UX-2 lane)
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_WELL_KNOWN_LOADED:-}" ]] && return 0

# =============================================================================
# WELL-KNOWN INFRASTRUCTURE IP MAP
# =============================================================================
# Inline associative map: IP -> "provider | description".
# Exact-match only (no CIDR expansion in v1.127.0 — see meta:description
# above for rationale). Future lanes can add CIDR matching if operator scope
# changes.
#
# Curation principle: include ONLY addresses where banning would
# (a) likely produce no security benefit on a typical end-user host AND
# (b) have a high probability of disrupting legitimate name-resolution or
# similar critical infrastructure-class traffic for the operator's users.
# This list is INTENTIONALLY conservative — it is NOT a substitute for the
# trust-provider whitelist mechanism (CDN edge prefixes etc.).
declare -gA _NFTBAN_WELL_KNOWN_IPS=(
    # Cloudflare 1.1.1.1 family (https://1.1.1.1)
    ["1.1.1.1"]="Cloudflare | public DNS resolver (1.1.1.1)"
    ["1.0.0.1"]="Cloudflare | public DNS resolver (1.0.0.1, secondary)"
    ["2606:4700:4700::1111"]="Cloudflare | public DNS resolver (IPv6 primary)"
    ["2606:4700:4700::1001"]="Cloudflare | public DNS resolver (IPv6 secondary)"

    # Google Public DNS (https://developers.google.com/speed/public-dns)
    ["8.8.8.8"]="Google | public DNS resolver (8.8.8.8)"
    ["8.8.4.4"]="Google | public DNS resolver (8.8.4.4, secondary)"
    ["2001:4860:4860::8888"]="Google | public DNS resolver (IPv6 primary)"
    ["2001:4860:4860::8844"]="Google | public DNS resolver (IPv6 secondary)"

    # Quad9 (https://www.quad9.net)
    ["9.9.9.9"]="Quad9 | public DNS resolver with malware filtering (primary)"
    ["149.112.112.112"]="Quad9 | public DNS resolver (secondary)"
    ["2620:fe::fe"]="Quad9 | public DNS resolver (IPv6 primary)"
    ["2620:fe::9"]="Quad9 | public DNS resolver (IPv6 secondary)"

    # Cisco/OpenDNS (https://www.opendns.com)
    ["208.67.222.222"]="Cisco/OpenDNS | public DNS resolver (primary)"
    ["208.67.220.220"]="Cisco/OpenDNS | public DNS resolver (secondary)"
    ["2620:119:35::35"]="Cisco/OpenDNS | public DNS resolver (IPv6 primary)"
    ["2620:119:53::53"]="Cisco/OpenDNS | public DNS resolver (IPv6 secondary)"
)
readonly _NFTBAN_WELL_KNOWN_IPS

# =============================================================================
# PUBLIC API
# =============================================================================

# nftban_is_well_known_infra_ip <ip>
# Returns 0 if the given IP is in the well-known infrastructure map and prints
# "provider | description" to stdout. Returns 1 otherwise (no output).
# Exact match only; no CIDR expansion.
nftban_is_well_known_infra_ip() {
    local ip="${1:-}"
    [[ -z "$ip" ]] && return 1

    # Strip any IPv4-in-IPv6 prefix for matching (operator might pass ::ffff:8.8.8.8)
    local lookup_ip="$ip"
    lookup_ip="${lookup_ip#::ffff:}"

    if [[ -n "${_NFTBAN_WELL_KNOWN_IPS[$lookup_ip]:-}" ]]; then
        printf '%s\n' "${_NFTBAN_WELL_KNOWN_IPS[$lookup_ip]}"
        return 0
    fi
    return 1
}

# nftban_well_known_provider <ip>
# Returns just the provider name (e.g., "Cloudflare") for a well-known IP.
# Returns 1 if not well-known (no output).
nftban_well_known_provider() {
    local ip="${1:-}"
    local descr
    if descr=$(nftban_is_well_known_infra_ip "$ip"); then
        printf '%s\n' "${descr%% |*}"
        return 0
    fi
    return 1
}

# nftban_well_known_warn_block <ip> [stream]
# Emits the standard operator-facing advisory block for a well-known IP.
# Default stream is stderr (intended for cmd_ban.sh refusal path); pass "stdout"
# to send to stdout (intended for cmd_search.sh Quick Actions advisory).
# Caller is responsible for the surrounding context (header, action items).
nftban_well_known_warn_block() {
    local ip="${1:-}"
    local stream="${2:-stderr}"
    local descr provider
    descr=$(nftban_is_well_known_infra_ip "$ip") || return 1
    provider="${descr%% |*}"

    local lines=(
        "[!] Well-known public infrastructure detected: ${ip}"
        "    ${descr}"
        ""
        "    Banning this address would not stop attacker traffic — the IP belongs"
        "    to a public service operating millions of legitimate queries. Banning"
        "    it on this host typically disrupts name-resolution or similar critical"
        "    infrastructure for users on the protected network without providing"
        "    a meaningful security benefit."
        ""
        "    If you genuinely want to proceed (e.g., for a controlled lab test or"
        "    a documented compliance scenario), re-run the command with --yes:"
        ""
        "        nftban ban ${ip} --yes [--timeout SECONDS]"
        ""
        "    Provider docs:  consult ${provider} public-resolver documentation"
        "                    for the canonical IP list before overriding."
    )

    if [[ "$stream" == "stdout" ]]; then
        printf '%s\n' "${lines[@]}"
    else
        printf '%s\n' "${lines[@]}" >&2
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_is_well_known_infra_ip
export -f nftban_well_known_provider
export -f nftban_well_known_warn_block

# =============================================================================
# MARK AS LOADED
# =============================================================================

readonly NFTBAN_WELL_KNOWN_LOADED=1
export NFTBAN_WELL_KNOWN_LOADED
