#!/usr/bin/env bash
# =============================================================================
# NFTBan - derived-state reconciliation (v1.228.8 PR2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
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
nftban_dsr_validate_plan() { # stdin or $1=file -> rc 0 valid
    local plan; plan="$(cat "${1:-/dev/stdin}")"
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

_nftban_dsr_verify_feeds()  { _nftban_dsr_kernel_set_count ip blacklist_ipv4; }
_nftban_dsr_verify_geoban() { _nftban_dsr_kernel_set_count ip blacklist_ipv4; }

nftban_dsr_verify() { # $1=plan text -> echoes final state, rc 0 only if RECONCILED/EMPTY
    local plan="$1" p planned fn count
    p="$(_nftban_dsr_plan_get "$plan" producer)"
    planned="$(_nftban_dsr_plan_get "$plan" planned_state)"
    if [[ "$planned" == "$NFTBAN_DSR_EMPTY" ]]; then echo "$NFTBAN_DSR_EMPTY"; return 0; fi
    fn="$(nftban_dsr_field "$p" verify_function)"
    declare -f "$fn" >/dev/null 2>&1 || { echo "$NFTBAN_DSR_UNKNOWN"; return 1; }
    count="$("$fn")"
    if [[ "$count" == "UNKNOWN" ]]; then echo "$NFTBAN_DSR_UNKNOWN"; return 1; fi
    if [[ "${count:-0}" -gt 0 ]]; then echo "$NFTBAN_DSR_RECONCILED"; return 0; fi
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
