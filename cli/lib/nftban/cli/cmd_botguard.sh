#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.21.0 - HTTP Bot Guard CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# Purpose: CLI for HTTP Bot Guard — enable, disable, status, test
#
# meta:name="cmd_botguard"
# meta:type="cli"
# meta:header="Bot Guard CLI"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI handler for HTTP Bot Guard (crawler detection & protection)"
# meta:input="Command line arguments (enable, disable, status, test)"
# meta:output="Bot guard management output"
# meta:depends="bash"
#
# meta:inventory.files=""
# meta:inventory.binaries="nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/botguard/main.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2026-03-14"
# =============================================================================

set -Eeuo pipefail

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load common CLI helpers (provides cmd_init, cmd_error, cmd_is_json_mode, etc.)
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/cmd_common.sh" || return 1

# Initialize CLI environment
cmd_init

# Load NFT schema for the THREE-VALUED COUNT ARITHMETIC (v1.231.0 FU-5).
# nftban_count_is_known / nftban_count_sum / nftban_count_json are the single
# authority for "known-0 vs known-N vs UNKNOWN"; BotGuard's counters must be
# able to say UNKNOWN, so this library is a hard dependency of this file.
# shellcheck source=/usr/lib/nftban/lib/nft_schema.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" || return 1
fi

# =============================================================================
# HELP TEXT
# =============================================================================

_nftban_botguard_help() {
    source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
    nftban_banner

    cat <<'HELP'

USAGE:
    nftban botguard <command> [options]

COMMANDS:
    enable              Enable HTTP Bot Guard protection
    disable             Disable HTTP Bot Guard protection
    status              Show bot guard status and statistics
    config              Show bot guard configuration
    stats               Show bot guard set statistics
    test <ip>           Test classification for a specific IP
    list [--set=NAME]   List IPs in bot guard sets
    verify <ip>         Manual FCrDNS verification for an IP
    help                Show this help message

DESCRIPTION:
    HTTP Bot Guard provides automated crawler detection and protection
    using a three-clock hybrid architecture:

      Clock 1 (Kernel):  nft meter marks suspect IPs per-packet
      Clock 2 (Go 60s):  Classification + FCrDNS verification loop
      Clock 3 (Shell):   Botscan batch pattern matching (10 min)

    Bot Guard is a SEPARATE module from DDoS protection. Both can run
    independently. Bot Guard adds HTTP-specific bot classification on
    top of DDoS rate limiting.

CONFIGURATION:
    /etc/nftban/conf.d/botguard/main.conf
    /etc/nftban/conf.d/botguard/main.conf.local       (user overrides)
    /etc/nftban/conf.d/botguard/allowed_crawlers.conf  (verified bots)
    /etc/nftban/conf.d/botguard/denied_crawlers.conf   (blocked bots)

EXAMPLES:
    nftban botguard enable                # Enable bot guard
    nftban botguard status                # Show current status
    nftban botguard test 1.2.3.4          # Test IP classification
    nftban botguard list --set=allow      # Show verified crawlers
    nftban botguard verify 66.249.79.1    # FCrDNS check (Googlebot)
    nftban botguard status --json         # JSON output for scripting

HELP
}

# =============================================================================
# CONFIG HELPERS
# =============================================================================

_BOTGUARD_CONF="/etc/nftban/conf.d/botguard/main.conf"
_BOTGUARD_CONF_LOCAL="/etc/nftban/conf.d/botguard/main.conf.local"

# Read a config value (local override takes precedence)
_botguard_config_get() {
    local key="$1"
    local default="${2:-}"
    local value=""

    # Check local override first
    if [[ -f "$_BOTGUARD_CONF_LOCAL" ]]; then
        value=$(grep -m1 "^${key}=" "$_BOTGUARD_CONF_LOCAL" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
    fi

    # Fall back to main config
    if [[ -z "$value" && -f "$_BOTGUARD_CONF" ]]; then
        value=$(grep -m1 "^${key}=" "$_BOTGUARD_CONF" 2>/dev/null | cut -d'=' -f2- | tr -d '"' || true)
    fi

    echo "${value:-$default}"
}

# Write a config value to local override (atomic)
_botguard_config_set() {
    local key="$1"
    local value="$2"

    mkdir -p "$(dirname "$_BOTGUARD_CONF_LOCAL")"

    # Source atomic file ops if not already loaded
    if ! declare -F nftban_atomic_write >/dev/null 2>&1; then
        # shellcheck source=../core/nftban_file_ops.sh
        source "${NFTBAN_LIB_DIR}/core/nftban_file_ops.sh" 2>/dev/null || true
    fi

    local content
    if [[ -f "$_BOTGUARD_CONF_LOCAL" ]]; then
        if grep -q "^${key}=" "$_BOTGUARD_CONF_LOCAL" 2>/dev/null; then
            # Replace existing key
            content=$(sed "s|^${key}=.*|${key}=\"${value}\"|" "$_BOTGUARD_CONF_LOCAL")
        else
            # Append new key
            content=$(cat "$_BOTGUARD_CONF_LOCAL")
            content="${content}"$'\n'"${key}=\"${value}\""
        fi
    else
        # Create new config
        content="# NFTBan HTTP Bot Guard - Local Overrides
# This file overrides values from main.conf
# Generated by: nftban botguard enable/disable
${key}=\"${value}\""
    fi

    if declare -F nftban_atomic_write >/dev/null 2>&1; then
        echo "$content" | nftban_atomic_write "$_BOTGUARD_CONF_LOCAL"
    else
        echo "$content" > "$_BOTGUARD_CONF_LOCAL"
    fi
}

# =============================================================================
# v1.79.0 BUG-3 FIX: Kernel truth helpers for set counts
# Invariant INV-BOT-002: Status counters must match kernel truth.
# See: BUGFIX_v1.79_IDEMPOTENCY_PREDICATES.md
# =============================================================================

# Count elements in an nftables set directly from kernel (v1.79.0 + v1.80.0 fix)
# Returns: an integer count, OR the literal string UNKNOWN when the kernel could
#          not be read at all (nft missing, permission denied, set absent).
# Usage: _botguard_kernel_set_count "ip nftban" "http_bot_suspect"
# v1.80.0: Fixed regex that matched metadata (size, flags) instead of actual IPs
# v1.231.0 ARGV SPLIT. `$table` carries "<family> <table>" as ONE string that has
# to reach nft as TWO argv words. The historical spelling relied on the AMBIENT
# IFS to split an unquoted `$table` -- but line 38 of this file sources
# lib/cmd_common.sh, which sources lib/strict.sh, which sets IFS=$'\n\t': NO
# SPACE. So `nft list set $table "$set_name"` expanded to the four-word argv
#   list / set / "ip nftban" / http_bot_suspect
# and nft rejected it. EVERY call failed, and the failure arm of this helper
# returns a count, so the count was structurally 0 no matter what the kernel
# held. Measured with an argv-faithful nft stub: ARGC=4, third word "ip nftban".
# Split on an EXPLICITLY PINNED IFS rather than inheriting whatever the caller
# left in the ambient one.
#
# v1.231.0 (FU-5): the unreadable arm used to `echo "0"`. "I could not look" and
# "I looked and the set is empty" are DIFFERENT claims, and only one of them is a
# measurement. A BotGuard status that prints 0 suspects because nft could not be
# reached reads to an operator as "nothing is being classified" — the same report
# a healthy idle host produces. Callers MUST branch with nftban_count_is_known
# and MUST NOT coerce UNKNOWN back to 0.
#
# The `elements = {` absent branch below is NOT this case: the set was read and
# genuinely holds nothing, which is a legitimate known 0 and stays 0.
_botguard_kernel_set_count() {
    local table="$1"
    local set_name="$2"

    local -a _tbl=()
    IFS=' ' read -r -a _tbl <<< "$table"

    # Get set content
    local output
    # COMPOSED v1.231.0: F's argv split supplies the READ, C's three-valued
    # contract supplies the VERDICT when the read does not happen. The two are
    # not alternatives -- before the argv fix this call could never succeed, so
    # the UNKNOWN arm below was the ONLY arm ever taken and would have reported
    # UNKNOWN for every set on a healthy host. Fixing HOW the value is obtained
    # is what makes "could not obtain it" a rare and therefore meaningful answer.
    output=$(nft list set "${_tbl[@]+"${_tbl[@]}"}" "$set_name" 2>/dev/null) || { echo "UNKNOWN"; return 0; }

    # v1.80.0 FIX: Only count elements within "elements = { ... }" section
    # If no elements section exists, the set is empty
    #
    # v1.231.0 EPIPE FAIL-TO-ZERO FIX. This test MUST NOT be a pipeline.
    # Piping the captured output into a quiet grep short-circuits: grep -q exits
    # at the FIRST match, and that match is on the 6th line of `nft list set`.
    # The producing subshell still has the whole element list to write, blocks on
    # the 64 KiB pipe buffer, and dies of SIGPIPE (128+13=141). This file runs
    # under `set -Eeuo pipefail` (see the `set` at the top of this file), so
    # pipefail adopts 141 as the PIPELINE's status even though grep MATCHED, and
    # the `!` then inverts a successful match into "no elements section" -> "0".
    # Measured on this shape: 928 elements / 43,629 B -> rc 0; 929 elements /
    # 43,677 B -> rc 141. Production rulesets are 168-196 KB, so `nftban botguard
    # status` reported 0 suspects for a set holding thousands. Present since
    # v1.80.0. Ignoring SIGPIPE does NOT help: the producer then takes EPIPE and
    # returns 1, which pipefail adopts just the same. The defect is in the
    # SHORT-CIRCUITING CONSUMER, not in the signal disposition -- so the fix is to
    # have no pipe at all. Pure-bash substring match: one process, no producer,
    # no buffer, size-independent.
    if [[ "$output" != *'elements = {'* ]]; then
        echo "0"
        return
    fi

    # Extract elements section only, then count actual IPs
    # Elements format: "elements = { ip1 timeout Xh, ip2 timeout Yh }"
    # Each element has " timeout " after the IP (not at line start like "flags timeout")
    local elements_section
    elements_section=$(echo "$output" | sed -n '/elements = {/,/}/p')

    # Count by matching " timeout " pattern - each element has exactly one
    # This avoids matching "flags timeout" which appears in set definition
    # v1.231.0 (FU-5): `grep -o` exits 1 when it matches nothing, and this file
    # runs under `set -Eeuo pipefail`, so an `elements = {` block with no
    # ` timeout ` occurrence made the PIPELINE fail and aborted the caller
    # mid-report. `wc -l` has already printed 0 by then, so the correct recovery
    # is 0 — the set WAS read and it holds no timed elements. This is a known 0,
    # not UNKNOWN. `_nftban_botguard_stats` previously carried its own `|| true`
    # for the same reason; routing it through this helper moves that guard here.
    local count
    count=$(echo "$elements_section" | grep -o ' timeout ' | wc -l) || count=0
    echo "${count:-0}"
}

# v1.231.0: SET MEMBERSHIP, not text containment.
#
# `nftban botguard test <ip>` used to ask the question by piping an unquoted
# `nft list set $table "$set_name"` straight into a quiet grep for the address,
# which was wrong in three independent ways, two of them producing a SECURITY
# FALSE NEGATIVE -- "IP not found in any bot guard set" for an IP that is in it:
#
#  1. ARGV. Unquoted `$table` under strict.sh's IFS=$'\n\t' reached nft as one
#     word ("ip nftban"), so every lookup failed and every answer was "not found".
#     See _botguard_kernel_set_count for the full derivation.
#  2. EPIPE. `grep -q` exits at its FIRST match. Here the producer is `nft`
#     itself, so on a large set nft is still writing when grep leaves, takes
#     SIGPIPE, and pipefail adopts 141 -- A MATCH BECOMES A MISS. The earlier the
#     IP sits in the set, the more reliably it is missed: position-dependent as
#     well as size-dependent.
#  3. CONTAINMENT != MEMBERSHIP. This one is independent of the pipe, and it cuts
#     the other way -- a FALSE POSITIVE. `grep` searched the ENTIRE rendered set
#     (headers, `type ipv4_addr`, `size`, flags, timeouts, expiry stamps) for the
#     needle as an unanchored BASIC REGULAR EXPRESSION:
#       - `.` is a wildcard, so 10.0.0.1 matched a rendered 10x0y0z1;
#       - the match was a substring, so 10.0.0.1 matched the DIFFERENT address
#         10.0.0.12, and reported membership in a set that does not hold it;
#       - a needle carrying regex metacharacters (`.*`, `[0-9]`) was interpreted,
#         not compared.
#
# The replacement answers the question that was actually being asked: is there an
# ELEMENT of this set whose address is EXACTLY this string. It narrows to the
# `elements = { ... }` block, walks the comma-separated elements, takes each
# element's first whitespace-delimited field (the address; `timeout`/`expires`
# metadata follows it) and compares with `==` against a QUOTED right-hand side,
# which is a literal string comparison and not a pattern match.
#
# Pure parameter expansion throughout: no pipeline, no subshell producer, no
# word-splitting and no globbing over kernel-derived text. Size- and
# position-independent by construction.
#
# An element spelled as an interval ("a-b") or prefix ("a/len") is compared as
# the literal element text; this helper answers membership, not containment.
_botguard_set_contains_ip() {
    local output="$1"
    local needle="$2"

    [[ -n "$needle" ]] || return 1

    # Narrow to the elements block. No block -> the set was read and is empty.
    local body="${output#*elements = \{}"
    [[ "$body" != "$output" ]] || return 1
    body="${body%%\}*}"

    local rest="$body" elem field
    while [[ -n "$rest" ]]; do
        elem="${rest%%,*}"
        if [[ "$elem" == "$rest" ]]; then rest=""; else rest="${rest#*,}"; fi
        # Trim leading whitespace (elements are rendered indented, one per line).
        elem="${elem#"${elem%%[![:space:]]*}"}"
        # The address is the first whitespace-delimited field of the element.
        field="${elem%%[[:space:]]*}"
        [[ "$field" == "$needle" ]] && return 0
    done
    return 1
}

# Check if nftables set exists (v1.79.0)
_botguard_kernel_set_exists() {
    local table="$1"
    local set_name="$2"
    # v1.231.0 ARGV SPLIT — see _botguard_kernel_set_count above. Under strict.sh's
    # IFS=$'\n\t' the unquoted `$table` was ONE argv word, so this predicate was
    # FALSE for every set that exists. It gates all twelve counters in
    # _nftban_botguard_stats, each of which therefore kept its 0 initialiser.
    local -a _tbl=()
    IFS=' ' read -r -a _tbl <<< "$table"
    nft list set "${_tbl[@]+"${_tbl[@]}"}" "$set_name" &>/dev/null
}

# =============================================================================
# COMMANDS
# =============================================================================

_nftban_botguard_enable() {
    local json_mode="${1:-false}"

    _botguard_config_set "HTTP_BOTGUARD_ENABLED" "true"

    # Apply nft fragment: create sets + rules + jump chains
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/lib/nft_fragment.sh" || true
    # v1.150 (MOD-05): capture the fragment rc. Previously a fragment failure
    # only warned, then the function unconditionally claimed "enabled" + rc=0
    # while HTTP_BOTGUARD_ENABLED=true was already persisted → BotGuard inert
    # but reported active. Keep the config write (so a later `nftban rebuild`
    # picks it up) but make the result honest: do NOT claim "enabled", and
    # return non-zero so callers/automation see the failure.
    local fragment_rc=0
    if declare -f nft_fragment_enable_module &>/dev/null; then
        nft_fragment_enable_module "botguard" || fragment_rc=$?
    fi

    if [[ $fragment_rc -ne 0 ]]; then
        if [[ "$json_mode" == "true" ]]; then
            printf '{"status":"error","message":"HTTP Bot Guard configured but rules NOT applied","hint":"run: nftban rebuild","rules_applied":false}\n'
        else
            echo "ERROR: HTTP Bot Guard configured but rules were NOT applied." >&2
            echo "       The config is saved (HTTP_BOTGUARD_ENABLED=true) but the firewall" >&2
            echo "       rules failed to load. Run: nftban rebuild" >&2
        fi
        return 1
    fi

    # Auto-restart nftband to activate immediately
    local restart_ok="false"
    if systemctl is-active nftband &>/dev/null; then
        if systemctl restart nftband 2>/dev/null; then
            restart_ok="true"
        fi
    fi

    if [[ "$json_mode" == "true" ]]; then
        printf '{"status":"ok","message":"HTTP Bot Guard enabled","daemon_restarted":%s}\n' "$restart_ok"
    else
        echo "HTTP Bot Guard enabled."
        if [[ "$restart_ok" == "true" ]]; then
            echo "Daemon restarted — Bot Guard is now active."
        else
            echo "Note: nftband not running. Start with: systemctl start nftband"
        fi
    fi
}

_nftban_botguard_disable() {
    local json_mode="${1:-false}"

    _botguard_config_set "HTTP_BOTGUARD_ENABLED" "false"

    # Remove nft fragment: cleanup sets + rules
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/lib/nft_fragment.sh" || true
    if declare -f nft_fragment_disable_module &>/dev/null; then
        nft_fragment_disable_module "botguard" || true
    fi

    # Auto-restart nftband to deactivate immediately
    local restart_ok="false"
    if systemctl is-active nftband &>/dev/null; then
        if systemctl restart nftband 2>/dev/null; then
            restart_ok="true"
        fi
    fi

    if [[ "$json_mode" == "true" ]]; then
        printf '{"status":"ok","message":"HTTP Bot Guard disabled","daemon_restarted":%s}\n' "$restart_ok"
    else
        echo "HTTP Bot Guard disabled."
        if [[ "$restart_ok" == "true" ]]; then
            echo "Daemon restarted — Bot Guard is now inactive."
        else
            echo "Note: nftband not running. No action needed."
        fi
    fi
}

_nftban_botguard_status() {
    local json_mode="${1:-false}"
    local enabled
    enabled=$(_botguard_config_get "HTTP_BOTGUARD_ENABLED" "false")

    local loop_interval
    loop_interval=$(_botguard_config_get "HTTP_BOT_FAST_LOOP_INTERVAL" "60")

    local pressure_interval
    pressure_interval=$(_botguard_config_get "HTTP_BOT_FAST_LOOP_PRESSURE_INTERVAL" "40")

    local suspect_rate
    suspect_rate=$(_botguard_config_get "HTTP_BOT_SUSPECT_RATE" "30/second")

    # v1.79.0 BUG-3 FIX: Read kernel sets directly for counts (INV-BOT-002)
    # Previous code used "grep -c timeout" which could count wrong elements.
    # Now we count actual IP elements from kernel truth.
    # v1.231.0 (FU-5): `source` and `freshness_at` are AUTHORITY CLAIMS about the
    # numbers printed beside them. They used to be stamped unconditionally, before
    # a single set was read, so a host where nft could not be reached at all still
    # published twelve zeros labelled source="kernel" with a current timestamp —
    # a reading that was never taken, presented as the freshest possible one.
    # Both are now DERIVED from what the reads actually returned.
    #
    # Each counter is read directly. _botguard_kernel_set_count already returns
    # UNKNOWN when `nft list set` fails, which covers both "set absent" and "nft
    # unreadable" — the two cases the previous _botguard_kernel_set_exists probe
    # collapsed into the integer 0. A set that exists and is empty still returns 0.
    local ipv4_suspects ipv6_suspects
    local ipv4_pending ipv6_pending
    local ipv4_allow ipv6_allow
    local ipv4_grey ipv6_grey
    local ipv4_ban ipv6_ban
    local ipv4_emergency ipv6_emergency

    ipv4_suspects=$(_botguard_kernel_set_count "ip nftban" "http_bot_suspect")
    ipv6_suspects=$(_botguard_kernel_set_count "ip6 nftban" "http_bot_suspect6")
    ipv4_pending=$(_botguard_kernel_set_count "ip nftban" "http_bot_pending")
    ipv6_pending=$(_botguard_kernel_set_count "ip6 nftban" "http_bot_pending6")
    ipv4_allow=$(_botguard_kernel_set_count "ip nftban" "http_bot_allow")
    ipv6_allow=$(_botguard_kernel_set_count "ip6 nftban" "http_bot_allow6")
    ipv4_grey=$(_botguard_kernel_set_count "ip nftban" "http_bot_grey")
    ipv6_grey=$(_botguard_kernel_set_count "ip6 nftban" "http_bot_grey6")
    ipv4_ban=$(_botguard_kernel_set_count "ip nftban" "http_bot_ban")
    ipv6_ban=$(_botguard_kernel_set_count "ip6 nftban" "http_bot_ban6")
    ipv4_emergency=$(_botguard_kernel_set_count "ip nftban" "http_bot_emergency")
    ipv6_emergency=$(_botguard_kernel_set_count "ip6 nftban" "http_bot_emergency6")

    # Derive the authority claim from the readings themselves.
    #   kernel          — every counter was established from the kernel
    #   kernel-partial  — some were; the timestamp applies to those only
    #   unavailable     — none were; there is nothing for a timestamp to date
    local _known=0 _total=0 _c
    for _c in "$ipv4_suspects" "$ipv6_suspects" "$ipv4_pending" "$ipv6_pending" \
              "$ipv4_allow" "$ipv6_allow" "$ipv4_grey" "$ipv6_grey" \
              "$ipv4_ban" "$ipv6_ban" "$ipv4_emergency" "$ipv6_emergency"; do
        _total=$((_total + 1))
        nftban_count_is_known "$_c" && _known=$((_known + 1))
    done

    local source freshness_at freshness_json
    if [[ "$_known" -eq 0 ]]; then
        source="unavailable"
        freshness_at=""
        freshness_json="null"
    else
        [[ "$_known" -eq "$_total" ]] && source="kernel" || source="kernel-partial"
        freshness_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        freshness_json="\"${freshness_at}\""
    fi

    # Check daemon status via IPC
    local daemon_running="false"
    if systemctl is-active nftband &>/dev/null; then
        daemon_running="true"
    fi

    # v1.79.0: Check if BotGuard chain exists (structural health)
    local structural_present="false"
    if nft list chain ip nftban http_bot_guard &>/dev/null; then
        structural_present="true"
    fi

    if [[ "$json_mode" == "true" ]]; then
        # v1.79.0: Enhanced JSON with kernel truth metadata
        # v1.231.0 (FU-5): counts render through nftban_count_json, so an
        # unestablished count is JSON `null` and never the number 0. Consumers
        # MUST test for null; a `// 0` default re-manufactures the false zero by
        # a longer route. freshness_at is likewise `null` (not "") when nothing
        # was measured — an empty string is still a claim that a read happened.
        printf '{"enabled":%s,"daemon_running":%s,"loop_interval":%s,"pressure_interval":%s,"suspect_rate":"%s","source":"%s","freshness_at":%s,"structural_present":%s,"sets":{"suspect":{"v4":%s,"v6":%s},"pending":{"v4":%s,"v6":%s},"allow":{"v4":%s,"v6":%s},"grey":{"v4":%s,"v6":%s},"ban":{"v4":%s,"v6":%s},"emergency":{"v4":%s,"v6":%s}}}\n' \
            "$enabled" "$daemon_running" "$loop_interval" "$pressure_interval" \
            "$suspect_rate" "$source" "$freshness_json" "$structural_present" \
            "$(nftban_count_json "$ipv4_suspects")" "$(nftban_count_json "$ipv6_suspects")" \
            "$(nftban_count_json "$ipv4_pending")" "$(nftban_count_json "$ipv6_pending")" \
            "$(nftban_count_json "$ipv4_allow")" "$(nftban_count_json "$ipv6_allow")" \
            "$(nftban_count_json "$ipv4_grey")" "$(nftban_count_json "$ipv6_grey")" \
            "$(nftban_count_json "$ipv4_ban")" "$(nftban_count_json "$ipv6_ban")" \
            "$(nftban_count_json "$ipv4_emergency")" "$(nftban_count_json "$ipv6_emergency")"
    else
        echo "=== HTTP Bot Guard Status ==="
        echo ""
        echo "  Module:             $([[ "$enabled" == "true" ]] && echo "ENABLED" || echo "disabled")"
        echo "  Daemon:             $([[ "$daemon_running" == "true" ]] && echo "RUNNING" || echo "stopped")"
        echo "  Structure:          $([[ "$structural_present" == "true" ]] && echo "PRESENT" || echo "missing")"
        echo "  Loop interval:      ${loop_interval}s (${pressure_interval}s under pressure)"
        echo "  Suspect rate:       $suspect_rate"
        echo ""
        # v1.231.0 (FU-5): a counter that was never established prints UNKNOWN,
        # not 0. The header states what the reading actually was rather than
        # asserting "kernel" with a current timestamp regardless of outcome.
        echo "  Kernel Sets (source: $source, ${freshness_at:-not read}):"
        printf "    %-12s  %7s  %7s\n" "" "IPv4" "IPv6"
        printf "    %-12s  %7s  %7s\n" "───────────" "───────" "───────"
        printf "    %-12s  %7s  %7s\n" "suspect" "$ipv4_suspects" "$ipv6_suspects"
        printf "    %-12s  %7s  %7s\n" "pending" "$ipv4_pending" "$ipv6_pending"
        printf "    %-12s  %7s  %7s\n" "allow" "$ipv4_allow" "$ipv6_allow"
        printf "    %-12s  %7s  %7s\n" "grey" "$ipv4_grey" "$ipv6_grey"
        printf "    %-12s  %7s  %7s\n" "ban" "$ipv4_ban" "$ipv6_ban"
        printf "    %-12s  %7s  %7s\n" "emergency" "$ipv4_emergency" "$ipv6_emergency"
        if [[ "$_known" -lt "$_total" ]]; then
            echo ""
            echo "    ❌ UNKNOWN = the set could not be read from nftables."
            echo "       This is NOT the same as an empty set; no count was taken."
            echo "       FIX: systemctl restart nftband"
        fi
        echo ""
        echo "  Config:             $_BOTGUARD_CONF"
        if [[ -f "$_BOTGUARD_CONF_LOCAL" ]]; then
            echo "  Local overrides:    $_BOTGUARD_CONF_LOCAL"
        fi
    fi
}

_nftban_botguard_test() {
    local ip="${1:-}"
    local json_mode="${2:-false}"

    if [[ -z "$ip" ]]; then
        cmd_error "Usage: nftban botguard test <ip>" "$json_mode"
        return 1
    fi

    # Check if IP is in any bot guard set
    local found_in=""
    for set_name in http_bot_suspect http_bot_allow http_bot_ban http_bot_grey http_bot_emergency http_bot_pending; do
        local table="ip nftban"
        # Check if IPv6
        if [[ "$ip" == *":"* ]]; then
            table="ip6 nftban"
            set_name="${set_name}6"
        fi

        local _set_out=""
        local -a _tbl=()
        IFS=' ' read -r -a _tbl <<< "$table"
        _set_out=$(nft list set "${_tbl[@]+"${_tbl[@]}"}" "$set_name" 2>/dev/null) || _set_out=""

        if [[ -n "$_set_out" ]] && _botguard_set_contains_ip "$_set_out" "$ip"; then
            found_in="$set_name"
            break
        fi
    done

    if [[ "$json_mode" == "true" ]]; then
        if [[ -n "$found_in" ]]; then
            printf '{"ip":"%s","found":true,"set":"%s"}\n' "$ip" "$found_in"
        else
            printf '{"ip":"%s","found":false,"set":null}\n' "$ip"
        fi
    else
        if [[ -n "$found_in" ]]; then
            echo "IP $ip found in set: $found_in"
        else
            echo "IP $ip not found in any bot guard set"
        fi
    fi
}

_nftban_botguard_list() {
    local set_filter="${1:-all}"
    local json_mode="${2:-false}"

    # Parse --set= argument
    case "$set_filter" in
        --set=*) set_filter="${set_filter#--set=}" ;;
    esac

    local sets
    case "$set_filter" in
        allow)     sets="http_bot_allow" ;;
        ban)       sets="http_bot_ban" ;;
        grey)      sets="http_bot_grey" ;;
        pending)   sets="http_bot_pending" ;;
        suspect)   sets="http_bot_suspect" ;;
        emergency) sets="http_bot_emergency" ;;
        all)       sets="http_bot_suspect http_bot_pending http_bot_allow http_bot_grey http_bot_ban http_bot_emergency" ;;
        *)
            cmd_error "Unknown set: $set_filter. Use: allow, ban, grey, pending, suspect, emergency, all" "$json_mode"
            return 1
            ;;
    esac

    if [[ "$json_mode" == "true" ]]; then
        printf '{"sets":['
        local first="true"
        for set_name in $sets; do
            local ipv4_output ipv6_output
            ipv4_output=$(nft list set ip nftban "$set_name" 2>/dev/null || true)
            ipv6_output=$(nft list set ip6 nftban "${set_name}6" 2>/dev/null || true)
            if [[ "$first" == "true" ]]; then first="false"; else printf ','; fi
            printf '{"name":"%s","ipv4":"%s","ipv6":"%s"}' \
                "$set_name" \
                "$(echo "$ipv4_output" | grep -c "timeout" 2>/dev/null || true)" \
                "$(echo "$ipv6_output" | grep -c "timeout" 2>/dev/null || true)"
        done
        printf ']}\n'
    else
        for set_name in $sets; do
            echo "=== $set_name (IPv4) ==="
            if nft list set ip nftban "$set_name" 2>/dev/null; then
                true
            else
                echo "  (set not found or empty)"
            fi
            echo ""
            echo "=== ${set_name}6 (IPv6) ==="
            if nft list set ip6 nftban "${set_name}6" 2>/dev/null; then
                true
            else
                echo "  (set not found or empty)"
            fi
            echo ""
        done
    fi
}

_nftban_botguard_verify() {
    local ip="${1:-}"
    local json_mode="${2:-false}"

    if [[ -z "$ip" ]]; then
        cmd_error "Usage: nftban botguard verify <ip>" "$json_mode"
        return 1
    fi

    # Step 1: Reverse DNS lookup
    local ptr_result hostname
    ptr_result=$(dig +short -x "$ip" 2>/dev/null || true)
    hostname=$(echo "$ptr_result" | head -1 | sed 's/\.$//')

    if [[ -z "$hostname" ]]; then
        if [[ "$json_mode" == "true" ]]; then
            printf '{"ip":"%s","status":"no_rdns","hostname":null,"forward_match":false}\n' "$ip"
        else
            echo "IP: $ip"
            echo "Status: NO REVERSE DNS"
            echo "No PTR record found"
        fi
        return 0
    fi

    # Step 2: Forward DNS confirmation
    local fwd_result fwd_match="false"
    if [[ "$ip" == *":"* ]]; then
        fwd_result=$(dig +short AAAA "$hostname" 2>/dev/null || true)
    else
        fwd_result=$(dig +short A "$hostname" 2>/dev/null || true)
    fi

    if echo "$fwd_result" | grep -qF "$ip"; then
        fwd_match="true"
    fi

    # Step 3: Check against allowed crawlers config
    local bot_name="unknown"
    local allowed_conf="/etc/nftban/conf.d/botguard/allowed_crawlers.conf"
    if [[ -f "$allowed_conf" ]]; then
        local host_lower
        host_lower=$(echo "$hostname" | tr '[:upper:]' '[:lower:]')
        while IFS='|' read -r name domains _rest; do
            [[ "$name" =~ ^# ]] && continue
            [[ -z "$name" ]] && continue
            IFS=',' read -ra domain_list <<< "$domains"
            for domain in "${domain_list[@]}"; do
                domain=$(echo "$domain" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
                if [[ "$host_lower" == *".${domain}" || "$host_lower" == "$domain" ]]; then
                    bot_name="$name"
                    break 2
                fi
            done
        done < "$allowed_conf"
    fi

    local status="failed"
    if [[ "$fwd_match" == "true" && "$bot_name" != "unknown" ]]; then
        status="verified"
    elif [[ "$fwd_match" == "true" ]]; then
        status="forward_confirmed"
    fi

    if [[ "$json_mode" == "true" ]]; then
        printf '{"ip":"%s","status":"%s","hostname":"%s","forward_match":%s,"bot_name":"%s"}\n' \
            "$ip" "$status" "$hostname" "$fwd_match" "$bot_name"
    else
        echo "=== FCrDNS Verification ==="
        echo ""
        echo "  IP:               $ip"
        echo "  Reverse DNS:      $hostname"
        echo "  Forward match:    $fwd_match"
        echo "  Bot identity:     $bot_name"
        echo "  Status:           $status"
        echo ""
        if [[ "$status" == "verified" ]]; then
            echo "  Result: VERIFIED — $bot_name crawler confirmed via FCrDNS"
        elif [[ "$status" == "forward_confirmed" ]]; then
            echo "  Result: Forward DNS confirmed but hostname not in allowed list"
        else
            echo "  Result: FAILED — FCrDNS verification did not pass"
        fi
    fi
}

# =============================================================================
# CONFIG / STATS SUBCOMMANDS (v1.29.0)
# =============================================================================

_nftban_botguard_config() {
    local json_mode="${1:-false}"

    local config_file="$_BOTGUARD_CONF"
    local config_local="$_BOTGUARD_CONF_LOCAL"

    local enabled
    enabled=$(_botguard_config_get "HTTP_BOTGUARD_ENABLED" "false")
    local suspect_rate
    suspect_rate=$(_botguard_config_get "HTTP_BOT_SUSPECT_RATE" "30/second")
    local loop_interval
    loop_interval=$(_botguard_config_get "HTTP_BOT_FAST_LOOP_INTERVAL" "60")
    local pressure_interval
    pressure_interval=$(_botguard_config_get "HTTP_BOT_FAST_LOOP_PRESSURE_INTERVAL" "40")
    local batch_interval
    batch_interval=$(_botguard_config_get "HTTP_BOT_BOTSCAN_INTERVAL" "600")
    local suspect_timeout
    suspect_timeout=$(_botguard_config_get "HTTP_BOT_SUSPECT_TIMEOUT" "300")

    if [[ "$json_mode" == "true" ]]; then
        printf '{"config_file":"%s","config_local":"%s","local_exists":%s,"settings":{"enabled":%s,"suspect_rate":"%s","loop_interval":%s,"pressure_interval":%s,"batch_interval":%s,"suspect_timeout":%s}}\n' \
            "$config_file" "$config_local" \
            "$([[ -f "$config_local" ]] && echo "true" || echo "false")" \
            "$enabled" "$suspect_rate" "$loop_interval" "$pressure_interval" \
            "$batch_interval" "$suspect_timeout"
    else
        echo "Bot Guard Configuration"
        echo "======================="
        echo ""
        echo "  Config File:        $config_file"
        echo "  Override File:      $config_local"
        if [[ -f "$config_local" ]]; then
            echo "  Status:             [Override Active]"
        else
            echo "  Status:             [Using defaults]"
        fi
        echo ""
        echo "Settings:"
        echo "  Enabled:            $enabled"
        echo "  Suspect Rate:       $suspect_rate"
        echo "  Loop Interval:      ${loop_interval}s"
        echo "  Pressure Interval:  ${pressure_interval}s"
        echo "  Batch Interval:     ${batch_interval}s"
        echo "  Suspect Timeout:    ${suspect_timeout}s"
        echo ""
        echo "To override settings, create/edit: $config_local"
    fi
}

_nftban_botguard_stats() {
    local json_mode="${1:-false}"

    # Count IPs in each set.
    #
    # v1.231.0 (FU-5): the pre-seeded zeros below were only overwritten when
    # `nft list set` succeeded, so an unreadable kernel published twelve zeros
    # that no read produced. They now start at UNKNOWN, which is what an
    # unperformed measurement is, and _botguard_kernel_set_count supplies the
    # same three-valued result used by `nftban botguard status`.
    local suspect_v4=UNKNOWN suspect_v6=UNKNOWN
    local allow_v4=UNKNOWN allow_v6=UNKNOWN
    local ban_v4=UNKNOWN ban_v6=UNKNOWN
    local grey_v4=UNKNOWN grey_v6=UNKNOWN
    local pending_v4=UNKNOWN pending_v6=UNKNOWN
    local emergency_v4=UNKNOWN emergency_v6=UNKNOWN

    for set_pair in \
        "http_bot_suspect:suspect_v4:suspect_v6" \
        "http_bot_allow:allow_v4:allow_v6" \
        "http_bot_ban:ban_v4:ban_v6" \
        "http_bot_grey:grey_v4:grey_v6" \
        "http_bot_pending:pending_v4:pending_v6" \
        "http_bot_emergency:emergency_v4:emergency_v6"; do

        local set_name="${set_pair%%:*}"
        local rest="${set_pair#*:}"
        local v4_var="${rest%%:*}"
        local v6_var="${rest#*:}"

        # v1.231.0 (FU-5): one read per set instead of an exists-probe followed
        # by a count, and the result is the shared three-valued count. The old
        # `grep -c "timeout"` also counted the set's OWN `flags timeout` and
        # `timeout <n>` header lines as if they were elements — the same defect
        # v1.80.0 fixed for `botguard status` but never applied here — so these
        # figures were inflated on every non-empty set as well as fabricated on
        # an unreadable one. _botguard_kernel_set_count counts only elements
        # inside `elements = { ... }`.
        local v4_count v6_count
        v4_count=$(_botguard_kernel_set_count "ip nftban" "$set_name")
        v6_count=$(_botguard_kernel_set_count "ip6 nftban" "${set_name}6")

        declare "$v4_var=$v4_count"
        declare "$v6_var=$v6_count"
    done

    local daemon_running="false"
    if systemctl is-active nftband &>/dev/null; then
        daemon_running="true"
    fi

    if [[ "$json_mode" == "true" ]]; then
        # v1.231.0 (FU-5): null, never 0, for a count nobody established.
        printf '{"daemon_running":%s,"sets":{"suspect":{"v4":%s,"v6":%s},"allow":{"v4":%s,"v6":%s},"ban":{"v4":%s,"v6":%s},"grey":{"v4":%s,"v6":%s},"pending":{"v4":%s,"v6":%s},"emergency":{"v4":%s,"v6":%s}}}\n' \
            "$daemon_running" \
            "$(nftban_count_json "$suspect_v4")" "$(nftban_count_json "$suspect_v6")" \
            "$(nftban_count_json "$allow_v4")" "$(nftban_count_json "$allow_v6")" \
            "$(nftban_count_json "$ban_v4")" "$(nftban_count_json "$ban_v6")" \
            "$(nftban_count_json "$grey_v4")" "$(nftban_count_json "$grey_v6")" \
            "$(nftban_count_json "$pending_v4")" "$(nftban_count_json "$pending_v6")" \
            "$(nftban_count_json "$emergency_v4")" "$(nftban_count_json "$emergency_v6")"
    else
        echo "Bot Guard Statistics"
        echo "===================="
        echo ""
        echo "  Daemon Running:   $daemon_running"
        echo ""
        printf "  %-12s  %7s  %7s\n" "Set" "IPv4" "IPv6"
        printf "  %-12s  %7s  %7s\n" "───────────" "───────" "───────"
        printf "  %-12s  %7s  %7s\n" "suspect" "$suspect_v4" "$suspect_v6"
        printf "  %-12s  %7s  %7s\n" "pending" "$pending_v4" "$pending_v6"
        printf "  %-12s  %7s  %7s\n" "allow" "$allow_v4" "$allow_v6"
        printf "  %-12s  %7s  %7s\n" "grey" "$grey_v4" "$grey_v6"
        printf "  %-12s  %7s  %7s\n" "ban" "$ban_v4" "$ban_v6"
        printf "  %-12s  %7s  %7s\n" "emergency" "$emergency_v4" "$emergency_v6"
        # v1.231.0 (FU-5): name what UNKNOWN means where the operator reads it.
        local _s
        for _s in "$suspect_v4" "$suspect_v6" "$pending_v4" "$pending_v6" \
                  "$allow_v4" "$allow_v6" "$grey_v4" "$grey_v6" \
                  "$ban_v4" "$ban_v6" "$emergency_v4" "$emergency_v6"; do
            if ! nftban_count_is_known "$_s"; then
                echo ""
                echo "  ❌ UNKNOWN = the set could not be read from nftables."
                echo "     This is NOT the same as an empty set; no count was taken."
                echo "     FIX: systemctl restart nftband"
                break
            fi
        done
        echo ""
    fi
}

# =============================================================================
# MAIN DISPATCH
# =============================================================================

nftban_cmd_botguard() {
    local action="${1:-help}"
    shift || true

    # Detect JSON mode
    local json_mode="false"
    for arg in "$@"; do
        if [[ "$arg" == "--json" ]]; then
            json_mode="true"
            break
        fi
    done

    case "$action" in
        enable)
            _nftban_botguard_enable "$json_mode"
            ;;
        disable)
            _nftban_botguard_disable "$json_mode"
            ;;
        status)
            _nftban_botguard_status "$json_mode"
            ;;
        config)
            _nftban_botguard_config "$json_mode"
            ;;
        stats)
            _nftban_botguard_stats "$json_mode"
            ;;
        test)
            local ip="${1:-}"
            shift || true
            _nftban_botguard_test "$ip" "$json_mode"
            ;;
        list)
            local set_arg="${1:---set=all}"
            shift || true
            _nftban_botguard_list "$set_arg" "$json_mode"
            ;;
        verify)
            local ip="${1:-}"
            shift || true
            _nftban_botguard_verify "$ip" "$json_mode"
            ;;
        help|--help|-h)
            _nftban_botguard_help
            ;;
        *)
            cmd_error "Unknown command: $action. Use: enable, disable, status, config, stats, test, list, verify, help" "$json_mode"
            return 1
            ;;
    esac
}

# =============================================================================
# EXPORT FOR MAIN CLI
# =============================================================================

export -f nftban_cmd_botguard
export -f _nftban_botguard_help
export -f _nftban_botguard_enable
export -f _nftban_botguard_disable
export -f _nftban_botguard_status
export -f _nftban_botguard_test
export -f _nftban_botguard_list
export -f _nftban_botguard_verify
export -f _nftban_botguard_config
export -f _nftban_botguard_stats
export -f _botguard_config_get
export -f _botguard_config_set
# v1.79.0: Kernel truth helpers (BUG-3 fix)
export -f _botguard_kernel_set_count
export -f _botguard_kernel_set_exists
# v1.231.0: set-membership predicate for `botguard test`
export -f _botguard_set_contains_ip

# Execute if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_botguard "$@"
fi
