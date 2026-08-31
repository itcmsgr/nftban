#!/usr/bin/env bash
# =============================================================================
# NFTBan - derived-state reconciliation (v1.228.8 PR2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="derived_state_reconcile"
# meta:type="lib"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="Plan/validate/bind/apply/verify reconciliation for derived kernel state (feed and GeoBan set elements) that a firewall rebuild wipes. Producers declare a durable source and their own restore entrypoint; this library never learns producer internals."
# meta:inventory.files="/var/lib/nftban/feeds,/etc/nftban/geoban.d"
# meta:inventory.binaries="nft,sha256sum"
# meta:inventory.env_vars="NFTBAN_DATA_DIR,NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root (nft writes)"
#
# WHY THIS EXISTS
# A rebuild renders the ruleset from `delete table` upward, so every DERIVED
# set element is wiped: feed CIDRs and GeoBan country ranges are not operator-
# authored config, they are projections of a durable source on disk. Before
# this library the two restore calls in the rebuild lane were:
#   `nftban geoban sync`      — not a dispatch verb at all; the unknown-command
#                               exit was swallowed by `2>/dev/null || true`
#   `nftban-core feeds sync`  — short-circuits on an unchanged config mtime and
#                               returns SUCCESS; after a rebuild the config has
#                               not changed, so it restored nothing and said so
#                               in the affirmative
# Both reported success while the kernel stayed empty. That is the defect class
# this library exists to make unrepresentable.
#
# CONTRACT
#   DISCOVER SOURCE -> BUILD PLAN -> VALIDATE PLAN -> BIND to source digest
#                   -> APPLY -> POST-VERIFY
#
#   PLAN != APPLY-RECOMPUTED-SILENTLY. A plan carries the digest of the source
#   it was computed from. Apply re-digests the source and REFUSES if it moved:
#   a stale plan is rejected, never executed. Recomputing silently would make
#   the validation step decorative.
#
#   Producers are INDEPENDENT. A partial reconciliation is reported as partial
#   — a producer that restored is not rolled back because a sibling failed.
#   There is no cross-module transaction here and inventing one would be a
#   bigger claim than the code can honour.
#
# ⛔ BotScan is deliberately NOT a producer. Its active-ban state cannot be
#    computed from any durable record (best-effort evidence log, destructive
#    512KB trim against a 24h TTL, no unban tombstone, no reader). Restoring it
#    would require inventing a ban-lifetime policy — tracked separately as
#    OPEN_BOTSCAN_DERIVED_BAN_STATE_AUTHORITY_AND_RECONCILIATION.
# =============================================================================

[[ -n "${_NFTBAN_DSR_LOADED:-}" ]] && return 0
_NFTBAN_DSR_LOADED=1

# --- outcome vocabulary ------------------------------------------------------
# RECONCILED  a restore was performed and post-verify agreed
# EMPTY       producer disabled, or enabled with a legitimately empty source
# UNKNOWN     the source or the kernel could not be read — NOT a clean result
# FAILED      the restore ran and did not achieve the planned state
# STALE_PLAN  the source changed between plan and apply; nothing was applied
readonly NFTBAN_DSR_RECONCILED="RECONCILED"
readonly NFTBAN_DSR_EMPTY="EMPTY"
readonly NFTBAN_DSR_UNKNOWN="UNKNOWN"
readonly NFTBAN_DSR_FAILED="FAILED"
readonly NFTBAN_DSR_PARTIAL="PARTIAL"
readonly NFTBAN_DSR_STALE="STALE_PLAN"

# =============================================================================
# STEP 1 — PRODUCER REGISTRY
# =============================================================================
# Deliberately a table, not a framework. Eight fields, one row per producer.
# Adding a producer means adding a row and three functions; it must never mean
# teaching this library — or the package scripts — anything about its internals.
declare -gA NFTBAN_DSR_REGISTRY=(
    # producer_id | field
    [feeds.enabled_authority]="module:feeds"
    [feeds.durable_source]="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds"
    [feeds.plan_function]="_nftban_dsr_plan_feeds"
    [feeds.apply_function]="_nftban_dsr_apply_feeds"
    [feeds.verify_function]="_nftban_dsr_verify_feeds"
    [feeds.failure_state]="$NFTBAN_DSR_UNKNOWN"
    [feeds.idempotent_expected]="true"

    [geoban.enabled_authority]="module:geoban"
    [geoban.durable_source]="${NFTBAN_CONFIG_DIR:-/etc/nftban}/geoban.d"
    [geoban.plan_function]="_nftban_dsr_plan_geoban"
    [geoban.apply_function]="_nftban_dsr_apply_geoban"
    [geoban.verify_function]="_nftban_dsr_verify_geoban"
    [geoban.failure_state]="$NFTBAN_DSR_UNKNOWN"
    [geoban.idempotent_expected]="true"
)

nftban_dsr_producers() { printf '%s\n' feeds geoban; }

nftban_dsr_field() { # $1=producer $2=field
    printf '%s' "${NFTBAN_DSR_REGISTRY[${1}.${2}]:-}"
}

# =============================================================================
# SOURCE DIGEST — the binding between plan and apply
# =============================================================================
# Content-addressed, not mtime-addressed. The feeds defect was precisely an
# mtime short-circuit deciding nothing needed doing while the kernel was empty;
# a digest describes what the source IS, not when it was last touched.
_nftban_dsr_source_digest() { # $1=dir $2=glob ; echoes digest, rc1 if unreadable
    local dir="$1" glob="$2"
    [[ -d "$dir" ]] || { echo "NO_SOURCE_DIR"; return 0; }
    local files
    # shellcheck disable=SC2086
    files=$(find "$dir" -maxdepth 1 -type f -name "$glob" 2>/dev/null | sort) || return 1
    [[ -z "$files" ]] && { echo "EMPTY_SOURCE"; return 0; }
    printf '%s\n' "$files" | xargs -r sha256sum 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1
}

_nftban_dsr_enabled() { # $1=producer -> 0 enabled, 1 disabled, 2 undetermined
    local auth module
    auth="$(nftban_dsr_field "$1" enabled_authority)"
    module="${auth#module:}"
    if declare -f nftban_module_effective_enabled >/dev/null 2>&1; then
        nftban_module_effective_enabled "$module" >/dev/null 2>&1 && return 0
        return 1
    fi
    return 2   # no authority available: undetermined, never assume enabled
}

# =============================================================================
# STEP 2 — BUILD PLAN (dry run; mutates nothing)
# =============================================================================
# A plan is KEY=VALUE lines on stdout. It records what WOULD be restored and
# the digest it was computed from, so apply can prove the world has not moved.
_nftban_dsr_plan_feeds() {
    local src; src="$(nftban_dsr_field feeds durable_source)"
    local digest; digest="$(_nftban_dsr_source_digest "$src" '*.txt')" || return 1
    local n=0
    if [[ -d "$src" ]]; then
        n=$(find "$src" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | wc -l)
    fi
    printf 'source_digest=%s\nsource_files=%s\n' "$digest" "$n"
}

_nftban_dsr_plan_geoban() {
    local src; src="$(nftban_dsr_field geoban durable_source)"
    local digest; digest="$(_nftban_dsr_source_digest "$src" '50-ban-*.conf')" || return 1
    local n=0
    if [[ -d "$src" ]]; then
        n=$(find "$src" -maxdepth 1 -type f -name '50-ban-*.conf' 2>/dev/null | wc -l)
    fi
    printf 'source_digest=%s\nsource_files=%s\n' "$digest" "$n"
}

nftban_dsr_plan() { # $1=producer -> plan on stdout; rc 0 plan, 1 UNKNOWN
    local p="$1" fn state plan
    fn="$(nftban_dsr_field "$p" plan_function)"
    [[ -n "$fn" ]] && declare -f "$fn" >/dev/null 2>&1 || {
        printf 'producer=%s\nplanned_state=%s\nsource_digest=NONE\nsource_files=0\nreason=no_plan_function\n' "$p" "$NFTBAN_DSR_UNKNOWN"
        return 1
    }

    _nftban_dsr_enabled "$p"
    case $? in
        1) printf 'producer=%s\nplanned_state=%s\nsource_digest=DISABLED\nsource_files=0\nreason=disabled\n' "$p" "$NFTBAN_DSR_EMPTY"; return 0 ;;
        2) printf 'producer=%s\nplanned_state=%s\nsource_digest=NONE\nsource_files=0\nreason=enabled_authority_unavailable\n' "$p" "$NFTBAN_DSR_UNKNOWN"; return 1 ;;
    esac

    plan="$("$fn")" || {
        printf 'producer=%s\nplanned_state=%s\nsource_digest=NONE\nsource_files=0\nreason=source_unreadable\n' "$p" "$NFTBAN_DSR_UNKNOWN"
        return 1
    }
    state="$NFTBAN_DSR_RECONCILED"
    grep -q '^source_digest=EMPTY_SOURCE$\|^source_digest=NO_SOURCE_DIR$' <<<"$plan" && state="$NFTBAN_DSR_EMPTY"
    printf 'producer=%s\nplanned_state=%s\n%s\n' "$p" "$state" "$plan"
}

# =============================================================================
# STEP 3 — VALIDATE PLAN
# =============================================================================
# Reads the plan from STDIN. It deliberately takes no file argument: every
# caller has the plan in hand already, and an unused file path would be an
# untested second way in.
nftban_dsr_validate_plan() { # stdin -> rc 0 valid
    local plan; plan="$(cat)"
    local f
    for f in producer planned_state source_digest source_files; do
        grep -qE "^${f}=" <<<"$plan" || { echo "invalid plan: missing $f" >&2; return 1; }
    done
    grep -qE '^planned_state=(RECONCILED|EMPTY)$' <<<"$plan" || { echo "invalid plan: bad planned_state" >&2; return 1; }
    grep -qE '^source_digest=.+$' <<<"$plan" || { echo "invalid plan: empty digest" >&2; return 1; }
    return 0
}

_nftban_dsr_plan_get() { grep -E "^$2=" <<<"$1" | head -1 | cut -d= -f2-; }

# =============================================================================
# STEP 4 — APPLY (bound to the validated plan)
# =============================================================================
_nftban_dsr_apply_feeds() {
    if declare -f nftban_feeds_sync_to_nftables >/dev/null 2>&1; then
        nftban_feeds_sync_to_nftables; return $?
    fi
    local core="${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-core}"
    # `load`, never `sync`: load reads the durable store unconditionally, while
    # `sync` returns success without acting when the config mtime is unchanged.
    [[ -x "$core" ]] || return 1
    timeout 120s "$core" feeds load
}

_nftban_dsr_apply_geoban() {
    if ! declare -f nftban_geoban_apply_to_nftables >/dev/null 2>&1; then
        local geo="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_geoban.sh"
        # shellcheck source=/dev/null
        [[ -r "$geo" ]] && source "$geo" 2>/dev/null || return 1
    fi
    declare -f nftban_geoban_apply_to_nftables >/dev/null 2>&1 || return 1
    nftban_geoban_apply_to_nftables
}

nftban_dsr_apply() { # $1=plan text -> rc 0 applied, 3 STALE, 1 failed
    local plan="$1" p planned fn now
    p="$(_nftban_dsr_plan_get "$plan" producer)"
    planned="$(_nftban_dsr_plan_get "$plan" planned_state)"
    [[ "$planned" == "$NFTBAN_DSR_EMPTY" ]] && return 0   # nothing to restore

    # STALE-PLAN GUARD. Re-derive the digest and refuse if the source moved
    # since the plan was built. Recomputing a fresh plan here instead would
    # execute actions nobody validated.
    local fresh; fresh="$(nftban_dsr_plan "$p" 2>/dev/null)" || return 1
    now="$(_nftban_dsr_plan_get "$fresh" source_digest)"
    if [[ "$now" != "$(_nftban_dsr_plan_get "$plan" source_digest)" ]]; then
        return 3
    fi

    fn="$(nftban_dsr_field "$p" apply_function)"
    declare -f "$fn" >/dev/null 2>&1 || return 1
    "$fn"
}

# =============================================================================
# STEP 5 — POST-VERIFY
# =============================================================================
# Verification asks the KERNEL, not the applier's return code: a restore that
# exits 0 and leaves the set empty is the exact failure this lane exists for.
_nftban_dsr_kernel_set_count() { # $1=family $2=set -> count, or UNKNOWN
    local out
    out=$(nft -j list set "$1" nftban "$2" 2>/dev/null) || { echo UNKNOWN; return 1; }
    [[ -z "${out//[[:space:]]/}" ]] && { echo UNKNOWN; return 1; }
    printf '%s' "$out" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("UNKNOWN"); raise SystemExit(1)
for o in d.get("nftables",[]):
    s=o.get("set")
    if s: print(len(s.get("elem") or [])); raise SystemExit(0)
print("UNKNOWN"); raise SystemExit(1)' 2>/dev/null || { echo UNKNOWN; return 1; }
}

# =============================================================================
# ⛔ PRODUCER-ATTRIBUTABLE VERIFICATION (D8)
# =============================================================================
# These two functions were LITERALLY IDENTICAL — both counted `ip blacklist_ipv4`
# and reported success on any non-zero count. blacklist_ipv4 is SHARED by feeds,
# geoban and BotScan, so a non-emptiness test cannot attribute a commit to the
# producer that was supposed to make it. Measured 2026-08-31 on lab2: GeoBan
# converted 28 CIDRs to 0, never called nft_ipc_sync_or_apply, printed
# "ACTIVELY BLOCKING", and DSR returned RECONCILED — satisfied entirely by the
# 750 elements FEEDS had put in the same set. 0 of 524,032 intended addresses
# were in the kernel and the reconciler agreed everything was fine.
#
# The oracle must therefore compare THIS producer's intended state against the
# kernel. Comparison is by ADDRESS COVERAGE, not element equality: nftables
# interval sets auto-merge, so `1.0.0.0/24` legitimately appears inside a wider
# live element and a string/element-count comparison would report a false
# failure on a healthy host.
#
# ⛔ SCOPE: this establishes ATTRIBUTION, not enforcement. Partial coverage is
#    reported as PARTIAL and is NOT fatal, because the interaction between
#    geoban ranges and whitelist subtraction/normalisation has NOT yet been
#    measured — a healthy host may legitimately hold less than it intended.
#    Turning a falsely-permissive control into a falsely-fatal one is not an
#    improvement. Only ZERO coverage from non-empty intent is treated as FAILED,
#    which is the measured defect signature.

# -----------------------------------------------------------------------------
# EFFECTIVE INTENT = RAW INTENT − BOGON − OVERSIZED
# -----------------------------------------------------------------------------
# The single writer filters its input before committing. Measured on lab4
# 2026-08-31: a GeoBan source of 198.51.100.0/24 + 203.0.113.0/24 produced
# "[SYNC] CIDR filter: removed 2 problematic entries (bogon=2, oversized=0)" and
# an EMPTY kernel set. Comparing live coverage against RAW intent would therefore
# report FAILED on a perfectly healthy host whose source merely contains reserved
# space. The denominator must be what policy actually allows through.
#
# ⛔ WHITELIST CONTRIBUTES ZERO SUBTRACTION. Measured 2026-08-31, six cases incl.
#    the discriminating one (an exact whitelisted /32 banned with no covering
#    range): the entry was still committed. Whitelist precedence is implemented
#    by RULE ORDER (whitelist accept before blacklist drop), never by removing
#    trusted addresses from the blacklist sets. Do not subtract it.
#
# ⛔ THIS IS A MIRROR, NOT A SECOND POLICY. The authority is Go:
#      internal/setsync/cidr.go :: BogonPrefixes, MinAllowedPrefixLen
#    There is no callable CLI surface to reuse (nftban-core exposes no
#    cidr-filter subcommand), and /var/lib/nftban/state/filter.json records only
#    the GLOBAL last-sync totals (feeds+geoban+blacklist.d combined), so it
#    cannot attribute a filtered entry to one producer. The mirror is therefore
#    unavoidable, and is pinned by a STRUCTURAL PARITY TEST that parses the Go
#    source and fails if the two ever diverge:
#      cli/lib/nftban/tests/cidr_policy_parity_test.sh
NFTBAN_DSR_MIN_PREFIX_LEN=9      # IPv4 prefixes shorter than /9 are rejected
NFTBAN_DSR_BOGON_PREFIXES="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 \
169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 \
198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4 \
255.255.255.255/32"

# Emit one intended entry per line for a producer, family-filtered.
# $1=producer $2=4|6
_nftban_dsr_intended_entries() {
    local p="$1" fam="$2" src pat
    src="$(nftban_dsr_field "$p" durable_source)"
    [[ -d "$src" ]] || return 1
    case "$p" in
        feeds)  pat='*.txt' ;;
        geoban) pat='50-ban-*.conf' ;;
        *)      return 1 ;;
    esac
    # Same parse the producers themselves use: skip blanks and #-comments,
    # discriminate family by the presence of a colon.
    find "$src" -maxdepth 1 -type f -name "$pat" -print0 2>/dev/null \
      | xargs -0 -r cat 2>/dev/null \
      | sed 's/[[:space:]]*$//' \
      | awk -v fam="$fam" '
          /^[[:space:]]*$/ { next }
          /^[[:space:]]*#/ { next }
          { is6 = (index($0, ":") > 0) ? 6 : 4; if (is6 == fam+0) print }'
}

# Echo "<covered> <intended>" in ADDRESSES for a producer, or UNKNOWN.
# $1=producer  (IPv4 only: the coverage oracle is 32-bit, see below)
_nftban_dsr_producer_coverage_fam() { # $1=producer $2=4|6 -> "<covered> <intended>" | UNKNOWN
    local p="$1" fam="$2" live intended famtab set
    if [[ "$fam" == "6" ]]; then famtab="ip6"; set="blacklist_ipv6"; else famtab="ip"; set="blacklist_ipv4"; fi
    live=$(nft -j list set "$famtab" nftban "$set" 2>/dev/null) || { echo UNKNOWN; return 1; }
    [[ -z "${live//[[:space:]]/}" ]] && { echo UNKNOWN; return 1; }
    intended="$(_nftban_dsr_intended_entries "$p" "$fam")" || { echo UNKNOWN; return 1; }
    [[ -z "$intended" ]] && { echo "0 0"; return 0; }

    # ⛔ The env assignments bind to the command they prefix. Putting them before
    #    `printf` set them for printf and NOT for python3, leaving the bogon list
    #    empty while the min-prefix silently fell back to its python default —
    #    the filter appeared to work while doing nothing.
    printf '%s' "$live" \
      | NFTBAN_DSR_FAMILY="$fam" \
        NFTBAN_DSR_BOGON_PREFIXES="$NFTBAN_DSR_BOGON_PREFIXES" \
        NFTBAN_DSR_MIN_PREFIX_LEN="$NFTBAN_DSR_MIN_PREFIX_LEN" \
        python3 -c '
import json, sys, ipaddress

import os
BOGONS = [ipaddress.ip_network(b) for b in
          os.environ.get("NFTBAN_DSR_BOGON_PREFIXES", "").split()]
MINLEN = int(os.environ.get("NFTBAN_DSR_MIN_PREFIX_LEN", "9"))

FAM = int(os.environ.get("NFTBAN_DSR_FAMILY", "4"))

def policy_excluded(n):
    """Mirror of internal/setsync/cidr.go FilterProblematicCIDRs.
    Both filters there are explicitly IPv4-only (the prefix-length check is
    guarded by ip.To4() != nil and BogonPrefixes holds only v4 ranges), so IPv6
    intent is never policy-excluded. Applying v4 rules to v6 would silently
    shrink the denominator."""
    if n.version != 4:
        return False
    if n.prefixlen < MINLEN:
        return True                                   # oversized
    return any(n.overlaps(b) for b in BOGONS)         # bogon

def parse_nets(lines):
    out = []
    for ln in lines:
        ln = ln.strip()
        if not ln:
            continue
        try:
            out.append(ipaddress.ip_network(ln, strict=False))
        except ValueError:
            continue          # malformed intent is not coverage; it is dropped
    return [n for n in out if n.version == FAM]

def net_of(addr, plen):
    return ipaddress.ip_network(str(addr) + "/" + str(plen), strict=False)

def flatten(e, acc):
    """nft -j renders a set element as a bare string, a prefix object, a range
    object, or any of those wrapped in {\"elem\": {\"val\": ...}}."""
    if isinstance(e, str):
        try: acc.append(ipaddress.ip_network(e, strict=False))
        except ValueError: pass
        return
    if not isinstance(e, dict):
        return
    if "elem" in e and isinstance(e["elem"], dict) and "val" in e["elem"]:
        flatten(e["elem"]["val"], acc); return
    if "prefix" in e:
        pf = e["prefix"]
        try: acc.append(net_of(pf["addr"], pf["len"]))
        except Exception: pass
        return
    if "range" in e:
        lo, hi = e["range"]
        try:
            acc.extend(ipaddress.summarize_address_range(
                ipaddress.ip_address(lo), ipaddress.ip_address(hi)))
        except Exception: pass
        return

raw = parse_nets(sys.argv[1].splitlines())
# EFFECTIVE intent: what the single writer would actually accept. Entries the
# daemon filters never reach the kernel, so counting them as intended-but-absent
# would fail a healthy host.
intended = [n for n in raw if not policy_excluded(n)]
if not intended:
    # Either nothing was intended, or EVERYTHING intended was policy-excluded.
    # Both mean "no effective intent" — zero live coverage is then CORRECT, not
    # a failure. Distinguishing the two is the caller, not coverage.
    print("0 0"); raise SystemExit(0)

try:
    doc = json.load(sys.stdin)
except Exception:
    print("UNKNOWN"); raise SystemExit(1)

elems = None
for obj in doc.get("nftables", []):
    st = obj.get("set")
    if st is not None:
        elems = st.get("elem") or []
        break
if elems is None:
    print("UNKNOWN"); raise SystemExit(1)

live_raw = []
for e in elems:
    flatten(e, live_raw)
live = list(ipaddress.collapse_addresses([n for n in live_raw if n.version == FAM])) if live_raw else []

# Coverage, in ADDRESSES, of intended space that is actually present live.
# Element equality is deliberately NOT used: interval sets auto-merge, so an
# intended /24 may be present inside a wider live element.
want = list(ipaddress.collapse_addresses(intended))
want_total = sum(n.num_addresses for n in want)
covered = 0
for n in want:
    enclosing = next((l for l in live if n.subnet_of(l)), None)
    if enclosing is not None:
        covered += n.num_addresses          # fully present
    else:
        covered += sum(l.num_addresses for l in live if l.subnet_of(n))
print(str(covered) + " " + str(want_total))
' "$intended" 2>/dev/null || { echo UNKNOWN; return 1; }
}

# ⛔ NO FAMILY MAY LICENSE SUCCESS FOR THE OTHER. The shared-set defect proved
#    that cross-PRODUCER proof is invalid; the same argument applies across
#    FAMILIES. Each family is measured against its own set and its own intent,
#    then composed conservatively: any family FAILED makes the producer FAILED,
#    any UNAVAILABLE makes it UNAVAILABLE, any PARTIAL makes it PARTIAL, and only
#    every ACTIVE family fully covered yields success. A family with no intent is
#    inactive and neither licenses nor blocks the verdict.
# Emits "<covered> <intended>" for the COMPOSED result so the caller contract and
# its strict arity guard are unchanged.
_nftban_dsr_producer_coverage() { # $1=producer
    local p="$1" r4 r6 c4 i4 c6 i6
    r4="$(_nftban_dsr_producer_coverage_fam "$p" 4)" || r4="UNKNOWN"
    r6="$(_nftban_dsr_producer_coverage_fam "$p" 6)" || r6="UNKNOWN"
    # An unreadable family is UNAVAILABLE for the whole producer — never ignored,
    # because ignoring it would let the readable family speak for both.
    [[ "$r4" == "UNKNOWN" || "$r6" == "UNKNOWN" ]] && { echo UNKNOWN; return 1; }
    read -r c4 i4 <<<"$r4"; read -r c6 i6 <<<"$r6"
    _nftban_dsr_log_family "$p" "$c4" "$i4" "$c6" "$i6"

    # ⛔ NEVER DO ARITHMETIC ON IPv6 COVERAGE IN SHELL. A single /48 is 2^80
    #    addresses; bash integers are 64-bit, so `[[ "$i6" -gt 0 ]]` silently
    #    mis-evaluates and an entirely present IPv6 intent read as absent.
    #    MEASURED: v6 coverage 1208925819614629174706176/1208925819614629174706176
    #    composed to "0 0" (EMPTY). Every comparison below is therefore a STRING
    #    comparison, which is exact at any magnitude.
    _fam_verdict() { # $1=covered $2=intended -> INACTIVE|FULL|NONE|PART
        [[ "$2" == "0" ]] && { echo INACTIVE; return; }
        [[ "$1" == "$2" ]] && { echo FULL; return; }
        [[ "$1" == "0" ]] && { echo NONE; return; }
        echo PART
    }
    local v4 v6
    v4="$(_fam_verdict "$c4" "$i4")"
    v6="$(_fam_verdict "$c6" "$i6")"

    # Conservative composition. An inactive family neither licenses nor blocks.
    [[ "$v4" == "NONE" || "$v6" == "NONE" ]] && { echo "0 1"; return 0; }
    [[ "$v4" == "PART" || "$v6" == "PART" ]] && { echo "1 2"; return 0; }
    local active=0
    [[ "$v4" == "FULL" ]] && active=$((active+1))
    [[ "$v6" == "FULL" ]] && active=$((active+1))
    [[ "$active" -eq 0 ]] && { echo "0 0"; return 0; }   # nothing intended anywhere
    echo "$active $active"
}

# Family detail is recorded even though the composed verdict is what gates, so a
# reader can tell WHICH family fell short rather than only that one did.
_nftban_dsr_log_family() {
    printf '[dsr] %s coverage v4=%s/%s v6=%s/%s\n' "$1" "$2" "$3" "$4" "$5" >&2
}

_nftban_dsr_verify_feeds()  { _nftban_dsr_producer_coverage feeds; }
_nftban_dsr_verify_geoban() { _nftban_dsr_producer_coverage geoban; }

nftban_dsr_verify() { # $1=plan text -> echoes final state, rc 0 only if RECONCILED/EMPTY
    local plan="$1" p planned fn
    p="$(_nftban_dsr_plan_get "$plan" producer)"
    planned="$(_nftban_dsr_plan_get "$plan" planned_state)"
    if [[ "$planned" == "$NFTBAN_DSR_EMPTY" ]]; then echo "$NFTBAN_DSR_EMPTY"; return 0; fi
    fn="$(nftban_dsr_field "$p" verify_function)"
    declare -f "$fn" >/dev/null 2>&1 || { echo "$NFTBAN_DSR_UNKNOWN"; return 1; }
    # The verify contract is now "<covered> <intended>" in ADDRESSES for THIS
    # producer, not a shared-set element count. See the D8 banner above.
    local result covered intended
    result="$("$fn")"
    if [[ -z "$result" || "$result" == "UNKNOWN" ]]; then echo "$NFTBAN_DSR_UNKNOWN"; return 1; fi
    # ⛔ STRICT ARITY. The contract is exactly two whitespace-separated integers.
    #    A single bare number — the PREVIOUS contract — must NOT be accepted:
    #    "${r%% *}" and "${r##* }" both yield N for input "N", which would make
    #    any legacy or future count-returning verifier read as covered==intended,
    #    i.e. a silent full-coverage SUCCESS. Anything not matching is UNKNOWN.
    local -a _fields
    read -r -a _fields <<<"$result"
    if [[ "${#_fields[@]}" -ne 2 ]] \
       || ! [[ "${_fields[0]}" =~ ^[0-9]+$ && "${_fields[1]}" =~ ^[0-9]+$ ]]; then
        echo "$NFTBAN_DSR_UNKNOWN"; return 1
    fi
    covered="${_fields[0]}"; intended="${_fields[1]}"
    if [[ "$intended" -eq 0 ]]; then echo "$NFTBAN_DSR_EMPTY"; return 0; fi
    if [[ "$covered" -eq "$intended" ]]; then echo "$NFTBAN_DSR_RECONCILED"; return 0; fi
    if [[ "$covered" -gt 0 ]]; then
        # NOT fatal: see the D8 scope note. Whitelist subtraction/normalisation
        # has not been measured, so a healthy host may legitimately hold less
        # than it intended. Report the shortfall as evidence and continue.
        echo "$NFTBAN_DSR_PARTIAL"; return 0
    fi
    # Zero coverage from non-empty intent is the measured defect signature:
    # the producer established nothing while the shared set looked populated.
    echo "$NFTBAN_DSR_FAILED"; return 1
}

# =============================================================================
# ORCHESTRATION — truthful partial reconciliation
# =============================================================================
# One producer failing does NOT roll back a sibling that succeeded, and does
# NOT let the overall verdict read as reconciled.
# Reconcile ONE producer through the whole contract. This is the entrypoint the
# firewall/package lifecycle uses: it passes a producer name and gets a verdict,
# never a producer internal.
nftban_dsr_reconcile_one() { # $1=producer -> echoes state; rc 0 only if RECONCILED/EMPTY
    local p="$1" plan state rc
    plan="$(nftban_dsr_plan "$p" 2>/dev/null)"; rc=$?
    if [[ $rc -ne 0 ]] || ! nftban_dsr_validate_plan <<<"$plan" 2>/dev/null; then
        printf '%s\n' "$NFTBAN_DSR_UNKNOWN"; return 1
    fi
    nftban_dsr_apply "$plan"; rc=$?
    case $rc in
        0) state="$(nftban_dsr_verify "$plan")" ;;
        3) state="$NFTBAN_DSR_STALE" ;;
        *) state="$NFTBAN_DSR_FAILED" ;;
    esac
    printf '%s\n' "$state"
    [[ "$state" == "$NFTBAN_DSR_RECONCILED" || "$state" == "$NFTBAN_DSR_EMPTY" ]]
}

nftban_dsr_reconcile_all() {
    local overall="$NFTBAN_DSR_RECONCILED" any_fail=0 p plan state rc
    NFTBAN_DSR_RESULTS=()
    for p in $(nftban_dsr_producers); do
        plan="$(nftban_dsr_plan "$p" 2>/dev/null)"; rc=$?
        if [[ $rc -ne 0 ]] || ! nftban_dsr_validate_plan <<<"$plan" 2>/dev/null; then
            NFTBAN_DSR_RESULTS[$p]="$NFTBAN_DSR_UNKNOWN"; any_fail=1; continue
        fi
        nftban_dsr_apply "$plan"; rc=$?
        case $rc in
            0) state="$(nftban_dsr_verify "$plan")" ;;
            3) state="$NFTBAN_DSR_STALE" ;;
            *) state="$NFTBAN_DSR_FAILED" ;;
        esac
        NFTBAN_DSR_RESULTS[$p]="$state"
        [[ "$state" == "$NFTBAN_DSR_RECONCILED" || "$state" == "$NFTBAN_DSR_EMPTY" ]] || any_fail=1
    done
    [[ $any_fail -eq 1 ]] && overall="PARTIAL"
    printf 'overall=%s\n' "$overall"
    for p in $(nftban_dsr_producers); do printf '%s=%s\n' "$p" "${NFTBAN_DSR_RESULTS[$p]:-$NFTBAN_DSR_UNKNOWN}"; done
    [[ "$overall" == "$NFTBAN_DSR_RECONCILED" ]]
}
declare -gA NFTBAN_DSR_RESULTS
