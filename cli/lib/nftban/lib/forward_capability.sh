#!/usr/bin/env bash
# =============================================================================
# NFTBan - forward-hook capability authority (v1.231.0 F-01)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="forward_capability"
# meta:type="library"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-14"
# meta:description="Single authority for the hook-forward base chain policy. Reads the host forwarding capability (net.ipv4.ip_forward, net.ipv6.conf.all.forwarding) PER FAMILY and rewrites the rendered ruleset's forward chain accordingly. On a non-forwarding host it is a byte-identical no-op."
# meta:input="a rendered nft ruleset file; /proc/sys/net/{ipv4/ip_forward,ipv6/conf/all/forwarding}"
# meta:output="the same file, forward chain rewritten only where that family forwards"
# meta:depends="bash,awk,cat,mktemp"
# meta:inventory.files="/proc/sys/net/ipv4/ip_forward,/proc/sys/net/ipv6/conf/all/forwarding"
# meta:inventory.binaries="bash,awk,cat,mktemp"
# meta:inventory.env_vars="NFTBAN_FORWARD_PROC_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
#
# ⛔ WHY THIS EXISTS — F-01
# FORWARD-CHAIN-EMPTY-POLICY-DROP-BLACKHOLES-ROUTED-TRAFFIC (CRITICAL, GA_BLOCKING).
#
# install/nftables/nftables.conf{,.tpl} ship, unconditionally and in BOTH families:
#
#     chain forward { type filter hook forward priority 0; policy drop; }
#
# An EMPTY base chain with policy drop. THE MECHANISM IS NFTABLES HOOK COMPOSITION,
# not our rule text: at a shared hook every base chain is evaluated, `accept` is NOT
# terminal across tables (the packet continues to the other tables at that hook) but
# `drop` IS terminal immediately. So this chain vetoes every other table's accept at
# hook forward — Docker, podman, libvirt/KVM, LXC, k8s CNI, or a plain router.
# Measured in network namespaces on Rocky 9.8, Rocky 10.0 and Ubuntu 24.04 at
# v1.229.14: with the nftban table present, forwarding is BLOCKED in both families;
# deleting ONLY the nftban table restores it. Not nft-version and not kernel dependent.
#
# Before this file, `ip_forward` was read ZERO times in the entire product. The drop
# policy was a static default with no host-capability gate at all.
#
# ⛔ WHAT CHANGES, AND FOR WHOM
#   NON-FORWARDING HOST (ip_forward=0)  -> NOTHING. nftban_forward_render() returns
#       early and the file is byte-identical. The chain keeps `policy drop` and zero
#       rules: the shipped artifact, unedited. Every non-routing host is unaffected.
#   FORWARDING HOST (ip_forward=1)      -> that family's forward chain is rewritten to
#       `policy accept` PLUS the ban sets, so forwarded traffic is no longer blackholed
#       AND is now actually policed. The shipped chain had no rules at all, so it was
#       fail-closed but never protective; where an operator worked around the drop,
#       forwarded traffic received no ban enforcement whatsoever.
#
# The gate is PER FAMILY on purpose: a host that routes IPv4 but not IPv6 keeps the v6
# drop policy, which is moot there because the kernel will not forward v6 anyway.
#
# ⛔ NO `ct state invalid drop` IN THE FORWARDING CHAIN — deliberate, not an omission.
# The input chain carries one, but a router legitimately sees flows its own conntrack
# cannot classify (asymmetric paths, mid-stream takeover, conntrack restart). Dropping
# those would reintroduce an availability defect of exactly F-01's class, on exactly the
# hosts F-01 breaks. The only packets this chain drops are ones whose source or
# destination is banned.
#
# ⛔ SINGLE AUTHORITY. This runs from _firewall_substitute_placeholders (cmd_firewall.sh),
# which is the ONE render authority — rebuild, reload and the boot projection all reach
# the kernel through it, so install-time and rebuild-time detection are the same code
# evaluated fresh on every render. A second render path would be the exact duplication
# scripts/ci/check-firewall-projection-authority.sh exists to prevent.
#
# THE SHIPPED ARTIFACTS ARE NOT EDITED. They remain the non-forwarding baseline, which
# keeps install/nftables/nftables.conf enforcement-identical to the rendered template
# (check-firewall-projection-authority.sh P3) and keeps the fleet delta at exactly zero.
# =============================================================================

# Idempotent load guard. Written as an if-block, not `[[ ]] && return`, so that a
# first load under `set -e` does not abort the caller on the guard's own false test.
if [[ -n "${NFTBAN_FORWARD_CAPABILITY_LOADED:-}" ]]; then
    return 0
fi
NFTBAN_FORWARD_CAPABILITY_LOADED=1

# -----------------------------------------------------------------------------
# nftban_forward_proc_root
#
# The procfs base the capability is read from. Overridable ONLY so the hermetic
# test can present a synthetic capability. It is a READ path with no policy
# argument, so it cannot be used to relax enforcement anywhere. Inside
# `ip netns exec` the real /proc/sys/net is already namespace-local, which is why
# the netns regression test needs no override at all and exercises the real read.
# -----------------------------------------------------------------------------
nftban_forward_proc_root() {
    printf '%s' "${NFTBAN_FORWARD_PROC_ROOT:-/proc}"
}

# -----------------------------------------------------------------------------
# nftban_forwarding_enabled <family>   family = ipv4 | ipv6
#
# 0 = this family forwards, 1 = it does not.
#
# UNREADABLE IS NOT ENABLED. If the sysctl cannot be read we report "not
# forwarding", which preserves the shipped behaviour exactly rather than opening
# the forward hook on the strength of a failed observation.
# -----------------------------------------------------------------------------
nftban_forwarding_enabled() {
    local family="${1:-}" path value
    case "$family" in
        ipv4) path="$(nftban_forward_proc_root)/sys/net/ipv4/ip_forward" ;;
        ipv6) path="$(nftban_forward_proc_root)/sys/net/ipv6/conf/all/forwarding" ;;
        *)    return 1 ;;
    esac
    [[ -r "$path" ]] || return 1
    value="$(cat "$path" 2>/dev/null)" || return 1
    [[ "$value" == "1" ]]
}

# -----------------------------------------------------------------------------
# nftban_forward_capability
#
# One word for the host as a whole, for operator-facing reporting:
#   forwarding  - at least one family forwards
#   host-only   - neither does (the shipped default; zero behavioural delta)
# -----------------------------------------------------------------------------
nftban_forward_capability() {
    if nftban_forwarding_enabled ipv4 || nftban_forwarding_enabled ipv6; then
        printf 'forwarding'
    else
        printf 'host-only'
    fi
}

# -----------------------------------------------------------------------------
# nftban_forward_chain_policy <family>
#
# The base-chain policy NFTBan will actually carry at hook forward for that
# family on THIS host. Schema validation must ASK this rather than assume `drop`,
# or a correctly-rendered routing host reads back as a policy violation.
# -----------------------------------------------------------------------------
nftban_forward_chain_policy() {
    if nftban_forwarding_enabled "${1:-}"; then printf 'accept'; else printf 'drop'; fi
}

# -----------------------------------------------------------------------------
# nftban_forward_chain_body <family>
#
# The rule lines for a FORWARDING family, without the chain header or braces;
# callers indent them.
#
# Ban enforcement is applied to BOTH saddr and daddr: on a router the banned host
# may be at either end of a forwarded flow, unlike hook input where it is always
# the source. Rule order mirrors the input chain's documented order (trust, then
# ban). Counters are ANONYMOUS so the rewrite needs no new named-counter
# declarations in the table block.
# -----------------------------------------------------------------------------
nftban_forward_chain_body() {
    local family="${1:-}"
    if [[ "$family" == "ipv4" ]]; then
        cat <<'V4BODY'
ip saddr @whitelist_ipv4 counter accept comment "NFTBAN_FORWARD: trusted source"
ip saddr @blacklist_manual_ipv4 counter drop comment "NFTBAN_FORWARD: banned source (manual)"
ip daddr @blacklist_manual_ipv4 counter drop comment "NFTBAN_FORWARD: banned destination (manual)"
ip saddr @blacklist_ipv4 counter drop comment "NFTBAN_FORWARD: banned source (feed/geo)"
ip daddr @blacklist_ipv4 counter drop comment "NFTBAN_FORWARD: banned destination (feed/geo)"
V4BODY
    else
        cat <<'V6BODY'
ip6 saddr @whitelist_ipv6 counter accept comment "NFTBAN_FORWARD: trusted source"
ip6 saddr @blacklist_manual_ipv6 counter drop comment "NFTBAN_FORWARD: banned source (manual)"
ip6 daddr @blacklist_manual_ipv6 counter drop comment "NFTBAN_FORWARD: banned destination (manual)"
ip6 saddr @blacklist_ipv6 counter drop comment "NFTBAN_FORWARD: banned source (feed/geo)"
ip6 daddr @blacklist_ipv6 counter drop comment "NFTBAN_FORWARD: banned destination (feed/geo)"
V6BODY
    fi
}

# -----------------------------------------------------------------------------
# nftban_forward_render <file>
#
# Rewrites <file> IN PLACE. For each `table ip|ip6 nftban` block whose family
# forwards, the whole `chain forward { ... }` block is replaced with the
# routing-safe chain. Every other byte is passed through untouched, so on a
# non-forwarding host the output is byte-identical to the input.
#
# The chain block is located by BRACE DEPTH, not by matching the single line the
# current artifact happens to contain, so the function is IDEMPOTENT: running it
# over an already-rendered forwarding chain reproduces the same result.
#
# FAIL-CLOSED. If the host forwards and no forward chain was rewritten, the input
# file is left untouched and 1 is returned. The caller MUST abort before `nft -f`:
# applying the un-rewritten ruleset is precisely the F-01 outage.
# -----------------------------------------------------------------------------
nftban_forward_render() {
    local file="${1:-}"
    local v4=0 v6=0 tmp

    if [[ -z "$file" || ! -f "$file" || ! -r "$file" ]]; then
        echo "[NFTBan ERROR] forward render: file not readable: ${file:-<unset>}" >&2
        return 1
    fi

    nftban_forwarding_enabled ipv4 && v4=1
    nftban_forwarding_enabled ipv6 && v6=1

    # Host-only box: no rewrite, and therefore no risk of one. This early return is
    # what makes the change a guaranteed no-op for every non-routing host.
    if [[ "$v4" == "0" && "$v6" == "0" ]]; then
        return 0
    fi

    local body4 body6
    body4="$(nftban_forward_chain_body ipv4)"
    body6="$(nftban_forward_chain_body ipv6)"

    tmp="$(mktemp "${file}.fwd.XXXXXX")" || {
        echo "[NFTBan ERROR] forward render: mktemp failed next to $file" >&2
        return 1
    }

    if ! awk -v V4="$v4" -v V6="$v6" -v BODY4="$body4" -v BODY6="$body6" '
        function emit_chain(indent, policy, body,    n, parts, i) {
            printf "%schain forward {\n", indent
            printf "%s    type filter hook forward priority 0; policy %s;\n", indent, policy
            printf "%s    # v1.231.0 F-01 FORWARDING HOST. This family forwards, so an empty\n", indent
            printf "%s    # policy-drop chain here would veto every other table accept at hook\n", indent
            printf "%s    # forward and blackhole all routed traffic. Ban sets are applied to\n", indent
            printf "%s    # BOTH ends of the flow; unmatched forwarded traffic is accepted.\n", indent
            n = split(body, parts, "\n")
            for (i = 1; i <= n; i++) if (parts[i] != "") printf "%s    %s\n", indent, parts[i]
            printf "%s}\n", indent
        }
        {
            line = $0
            if (inchain) {
                o = gsub(/\{/, "{", line); c = gsub(/\}/, "}", line)
                depth += o - c
                if (depth <= 0) inchain = 0
                if (replace) next
                print; next
            }
            if (line ~ /^[ \t]*table[ \t]+ip[ \t]+nftban[ \t]*\{/)       { fam = "ip"  }
            else if (line ~ /^[ \t]*table[ \t]+ip6[ \t]+nftban[ \t]*\{/) { fam = "ip6" }
            if (line ~ /^[ \t]*chain[ \t]+forward[ \t]*\{[ \t]*$/) {
                indent = line; sub(/[^ \t].*$/, "", indent)
                replace = ((fam == "ip" && V4 == "1") || (fam == "ip6" && V6 == "1"))
                inchain = 1; depth = 1
                if (replace) {
                    emit_chain(indent, "accept", (fam == "ip" ? BODY4 : BODY6))
                    rewrote++
                    next
                }
                print; next
            }
            print
        }
        END {
            # The host forwards, so at least one chain MUST have been rewritten.
            # Zero is a silent miss (unrecognised ruleset shape), never a success.
            if (rewrote == 0) exit 9
        }
    ' "$file" > "$tmp"; then
        rm -f "$tmp"
        echo "[NFTBan ERROR] forward render: no hook-forward chain was rewritten in $file" >&2
        echo "[NFTBan ERROR]   this host forwards (ipv4=$v4 ipv6=$v6) but the ruleset shape was not" >&2
        echo "[NFTBan ERROR]   recognised. Refusing to apply a ruleset that would blackhole all" >&2
        echo "[NFTBan ERROR]   forwarded traffic (F-01). The existing firewall is unchanged." >&2
        return 1
    fi

    cat "$tmp" > "$file" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    return 0
}
