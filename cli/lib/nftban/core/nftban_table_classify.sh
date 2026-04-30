#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.100 Amendment 4 - nft Table Classifier (PR26.6 / 6A)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_table_classify"
# meta:type="lib"
# meta:version="1.100.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-30"
# meta:description="Classify nft tables before destructive cleanup — TAKEOVER-PRESERVES-NON-NFTBAN-AUTHORITY-001"
# meta:inventory.files="cli/lib/nftban/core/nftban_table_classify.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Invariant TAKEOVER-PRESERVES-NON-NFTBAN-AUTHORITY-001:
#   During takeover and rebuild, nftban may disable external firewall
#   authority through reversible lifecycle operations, but must not
#   destructively delete non-nftban-owned authority or operator-safety
#   assets.
#
# Replaces the prior allowlist-sweep pattern that silently called
#   nft delete table <every-non-allowlisted-table>
# which on dns2 (2026-04-30) wiped operator-retained inet ssh_safety.
#
# Classes:
#   NFTBAN_OWNED              — flush/delete authorized
#   EXTERNAL_AUTHORITY_GHOST  — delete authorized (CSF/firewalld iptables-nft compat)
#   KERNEL_DEFAULT            — preserve silently (ip raw, ip6 raw)
#   OPERATOR_SAFETY           — preserve, emit warning (default policy in PR26.6)
# =============================================================================

set -Eeuo pipefail

[[ -n "${_NFTBAN_TABLE_CLASSIFY_LOADED:-}" ]] && return 0
_NFTBAN_TABLE_CLASSIFY_LOADED=1

# shellcheck disable=SC2034
readonly TC_NFTBAN_OWNED="NFTBAN_OWNED"
# shellcheck disable=SC2034
readonly TC_EXTERNAL_AUTHORITY_GHOST="EXTERNAL_AUTHORITY_GHOST"
# shellcheck disable=SC2034
readonly TC_KERNEL_DEFAULT="KERNEL_DEFAULT"
# shellcheck disable=SC2034
readonly TC_OPERATOR_SAFETY="OPERATOR_SAFETY"

# nftban_classify_table — classify a single nft table by family + name.
#
# Input (positional):
#   $1 family — one of: ip, ip6, inet, arp, bridge, netdev
#   $2 name   — table name
# Output:
#   prints classification token to stdout (one of TC_* values)
# Exit code: always 0
#
# Pinned table sets are kept in this single function so
# install-side, rebuild-side, and autoheal-side all agree.
nftban_classify_table() {
    local family="$1"
    local name="$2"
    local spec="${family} ${name}"

    case "$spec" in
        # NFTBan-owned tables
        "ip nftban"|"ip6 nftban"|"inet nftban"|"inet nftban_install_emergency")
            echo "$TC_NFTBAN_OWNED"
            return 0
            ;;
        # Kernel default empty tables (always present on EL9+, harmless)
        "ip raw"|"ip6 raw")
            echo "$TC_KERNEL_DEFAULT"
            return 0
            ;;
        # External firewall ghost tables — created by iptables-nft compat
        # layer (CSF/lfd, firewalld, fail2ban, docker). Delete authorized
        # during takeover-driven rebuild.
        "ip filter"|"ip6 filter"|\
        "ip nat"|"ip6 nat"|\
        "ip mangle"|"ip6 mangle"|\
        "ip security"|"ip6 security"|\
        "inet firewalld"|"inet filter")
            echo "$TC_EXTERNAL_AUTHORITY_GHOST"
            return 0
            ;;
        *)
            # Anything else — including operator-retained tables such as
            # `inet ssh_safety` — is OPERATOR_SAFETY. PR26.6 default policy
            # is WARN-and-preserve.
            echo "$TC_OPERATOR_SAFETY"
            return 0
            ;;
    esac
}

# nftban_classify_table_line — accept "table <family> <name>" line as
# emitted by `nft list tables` and route through nftban_classify_table.
nftban_classify_table_line() {
    local line="$1"
    # Strip leading "table "
    local rest="${line#table }"
    # Split on first whitespace
    local family="${rest%% *}"
    local name="${rest#* }"
    if [[ -z "$family" || -z "$name" || "$family" == "$name" ]]; then
        echo "$TC_OPERATOR_SAFETY"
        return 0
    fi
    nftban_classify_table "$family" "$name"
}

# nftban_table_should_delete_for_takeover — true (rc 0) if the table
# may be destructively deleted during takeover-driven rebuild cleanup.
#
# NFTBAN_OWNED → false (the rebuild flushes nftban tables itself, does
#   not nft-delete them — preserving set state references).
# EXTERNAL_AUTHORITY_GHOST → true.
# KERNEL_DEFAULT, OPERATOR_SAFETY → false.
nftban_table_should_delete_for_takeover() {
    local family="$1"
    local name="$2"
    local class
    class="$(nftban_classify_table "$family" "$name")"
    [[ "$class" == "$TC_EXTERNAL_AUTHORITY_GHOST" ]]
}
