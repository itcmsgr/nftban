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

# -----------------------------------------------------------------------------
# v1.228.11 — CONTENT dimension (OPEN_FIREWALL_REBUILD_DELETES_POPULATED_FOREIGN_NFT_TABLES)
#
# nftban_classify_table above is the canonical IDENTITY authority: it answers
# "what kind of name is this". It does NOT answer "does this table hold real
# rules", and identity alone was being used to authorize deletion. Measured on a
# disposable AlmaLinux 10.2 host: a populated operator-owned `ip mangle` was
# destroyed by `nftban firewall rebuild` (rc=0) and by `nftban health --fix`,
# with no install, no takeover and no CSF present.
#
#	A NAME MATCH IS NOT OWNERSHIP EVIDENCE.
#
# This adds the missing CONTENT dimension in the same canonical file, so identity
# and content stay in one authority. Mirrors internal/installer/switchop
# ClassifyTable (Go) so both languages classify identically.
#
# Emits one of:
#   TC_CONTENT_ABSENT     — table does not exist
#   TC_CONTENT_EMPTY      — exists, zero rule lines: a compat/distro skeleton
#   TC_CONTENT_POPULATED  — holds rules; ownership NOT established by name
#   TC_CONTENT_UNREADABLE — nft could not be read; observation failure
#
# Conservative by contract: UNREADABLE is never treated as EMPTY.
: "${TC_CONTENT_ABSENT:=TC_CONTENT_ABSENT}"
: "${TC_CONTENT_EMPTY:=TC_CONTENT_EMPTY}"
: "${TC_CONTENT_POPULATED:=TC_CONTENT_POPULATED}"
: "${TC_CONTENT_UNREADABLE:=TC_CONTENT_UNREADABLE}"

nftban_table_content_class() {
    local family="$1" name="$2" out rc=0
    # NOTE: captured, never piped into `grep -q` — a producer killed by SIGPIPE
    # under `set -o pipefail` would report a MATCH as a NON-MATCH and make a
    # populated table read as absent (feedback: OPEN_SIGPIPE_PIPEFAIL_GREP_Q).
    out="$(nft list table "$family" "$name" 2>/dev/null)" || rc=$?
    if [[ $rc -ne 0 ]]; then
        # Distinguish "not there" from "could not read it".
        if nft list tables 2>/dev/null | grep -qx "table ${family} ${name}"; then
            echo "$TC_CONTENT_UNREADABLE"
        else
            echo "$TC_CONTENT_ABSENT"
        fi
        return 0
    fi
    # Count non-structural, non-blank lines. The structural set MIRRORS the Go
    # isStructuralLine EXACTLY (classify.go): table, chain, type, policy, }, #,
    # set, elements, map — and NOTHING else. An earlier version of this list also
    # excluded `counter`/`flags`/`timeout`/`comment`, which silently classified a
    # POPULATED table as EMPTY, because a real rule can begin with `counter`.
    # That made the fix inert while appearing to work; the two languages must
    # classify identically or the shell path reintroduces the defect.
    local rules
    rules="$(printf '%s\n' "$out" \
        | sed 's/^[[:space:]]*//' \
        | grep -vE '^$' \
        | grep -vcE '^(table|chain|type |policy|\}|#|set|elements|map)')" || rules=0
    if [[ "${rules:-0}" -eq 0 ]]; then
        echo "$TC_CONTENT_EMPTY"
    else
        echo "$TC_CONTENT_POPULATED"
    fi
    return 0
}

# _NFTBAN_GHOST_TABLE_IDENTITIES — THE canonical ghost-table identity list.
# v1.228.11: six independent declarations existed (this classifier's case arm,
# _NFTBAN_KNOWN_GHOST_TABLES, the cmd_health_core fallback loop, the Go
# ghostTables[], and two hardcoded delete blocks). Every consumer now derives
# from this one array; scripts/ci/check-ghost-table-drift.sh fails the build if
# the Go list and this list diverge semantically.
#
# Membership here means "this NAME is a known external-authority skeleton
# identity". It does NOT authorize deletion — content still gates that
# (nftban_delete_ghost_table_if_empty).
readonly -a _NFTBAN_GHOST_TABLE_IDENTITIES=(
    "ip filter" "ip6 filter"
    "ip nat" "ip6 nat"
    "ip mangle" "ip6 mangle"
    "ip security" "ip6 security"
    "inet firewalld" "inet filter"
)

# NOTE (v1.228.11): the ghost-delete helper deliberately does NOT live here.
# This file is the CLASSIFIER — identity and content, both read-only. nft WRITE
# authority belongs to files sanctioned by scripts/ci/check-nft-writes.sh, so
# nftban_delete_ghost_table_if_empty lives in nftban_firewall_conflicts.sh.
# Keeping classification write-free is why that gate caught this at all.

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
