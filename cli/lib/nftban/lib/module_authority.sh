#!/usr/bin/env bash
# =============================================================================
# NFTBan - module enablement authority (v1.228.7)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="module_authority"
# meta:type="lib"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-08"
# meta:description="THE single answer to 'is module X enabled?'. Before v1.228.7 that question had at least four different answers depending on the code path: the module loader read main.conf then main.conf.local; the firewall rebuild's DDoS re-apply gate read main.conf.local ONLY (a host declaring DDOS_ENABLED=true in main.conf silently lost DDoS on every rebuild); PortScan's gate read .local then fell back to main.conf but could not express main=true+local=false; and stale generated fragments on disk acted as de-facto policy wherever they were re-applied without any config check (measured: dns1 enforcing 4 DDoS chains for months with effective config false). Every lifecycle consumer must ask THIS function and nothing else. Fragment presence is NEVER authority."
# meta:inventory.files="/etc/nftban/conf.d/<module>/main.conf, main.conf.local"
# meta:inventory.binaries="grep"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR"
# meta:inventory.config_files="conf.d/*/main.conf,conf.d/*/main.conf.local"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (read-only)"
# =============================================================================

# Guard against double-sourcing.
[[ -n "${_NFTBAN_MODULE_AUTHORITY_LOADED:-}" ]] && return 0
_NFTBAN_MODULE_AUTHORITY_LOADED=1

# The per-module enablement variable. Modules are not uniform, so the mapping
# is EXPLICIT — an unknown module is an error, never a guessed variable name.
_nftban_module_enable_var() {
    case "$1" in
        ddos)     echo "DDOS_ENABLED" ;;
        portscan) echo "PORTSCAN_ENABLED" ;;
        botguard) echo "HTTP_BOTGUARD_ENABLED" ;;
        geoban)   echo "GEOBAN_ENABLED" ;;
        feeds)    echo "FEEDS_ENABLED" ;;
        *)        return 1 ;;
    esac
}

# _nftban_module_read_key <file> <KEY> — echo the last bare value of KEY="..."
# in <file>, or nothing. grep only; never sources (config is data, not code).
_nftban_module_read_key() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    grep -oP "^[[:space:]]*${key}=\"?\K[^\"]+" "$file" 2>/dev/null | tail -1
}

# nftban_module_effective_enabled <module> [KEY]
# Returns 0 iff the module is EFFECTIVELY enabled, resolved exactly as the
# production loader resolves it: base value from main.conf, then main.conf.local
# OVERRIDES iff it assigns the key. An explicit false in .local turns off a true
# in the base (the case the old gates could not express). Missing files resolve
# to disabled — absence of configuration is absence of enablement, never an
# error. Fragment presence on disk is deliberately NOT consulted.
#
# KEY is optional: omit it to use the canonical variable for <module>; pass it
# for the two-argument form kept for existing call sites.
nftban_module_effective_enabled() {
    local module="$1" key="${2:-}"
    if [[ -z "$key" ]]; then
        key="$(_nftban_module_enable_var "$module")" || {
            echo "nftban_module_effective_enabled: unknown module '$module'" >&2
            return 2
        }
    fi
    local base="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/${module}/main.conf"
    local val="false" v

    v="$(_nftban_module_read_key "$base" "$key")"
    [[ -n "$v" ]] && val="$v"
    v="$(_nftban_module_read_key "${base}.local" "$key")"
    [[ -n "$v" ]] && val="$v"

    [[ "$val" == "true" ]]
}

# -----------------------------------------------------------------------------
# nftban_module_set_enabled <module> <true|false>
#
# THE single writer of durable module intent -- the write counterpart to
# nftban_module_effective_enabled above, deliberately homed beside it so read
# authority and write authority live together.
#
# v1.229.7 PR-2: before this, FOUR hand-rolled writers existed (ddos enable,
# ddos disable, portscan enable, portscan disable), each its own
# grep -q / sed -i / echo >> sequence, and each reachable from TWO principals
# -- the operator CLI *and* the nftband daemon. The daemon path is removed in
# this same change; this collapses the remaining four implementations into one.
#
# ⛔ ONLY EXPLICIT OPERATOR ACTIONS MAY CALL THIS.
#    `nftban <module> enable|disable` -- and nothing on a daemon lifecycle path.
#    SERVICE RESTART MUST NOT CHANGE MODULE CONFIGURATION.
# -----------------------------------------------------------------------------
nftban_module_set_enabled() {
    local module="$1" want="$2" key
    case "$want" in
        true|false) ;;
        *) echo "nftban_module_set_enabled: value must be true|false, got '$want'" >&2; return 2 ;;
    esac
    key="$(_nftban_module_enable_var "$module")" || {
        echo "nftban_module_set_enabled: unknown module '$module'" >&2
        return 2
    }
    local local_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/${module}/main.conf.local"
    mkdir -p "$(dirname "$local_conf")" || return 1
    if grep -q "^${key}=" "$local_conf" 2>/dev/null; then
        sed -i "s/^${key}=.*/${key}=\"${want}\"/" "$local_conf" || return 1
    else
        printf '%s="%s"\n' "$key" "$want" >> "$local_conf" || return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# _nftban_module_mode_var <module>  -- canonical MODE key for a module.
# -----------------------------------------------------------------------------
_nftban_module_mode_var() {
    case "$1" in
        ddos)     echo "DDOS_MODE" ;;
        portscan) echo "PORTSCAN_MODE" ;;
        *)        return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# nftban_module_resolve_plan <module>
#
# THE MODE RESOLVER. v1.229.7 PR-3A. Emits a RESOLVED MODULE PLAN as KEY=value
# lines on stdout, for the caller to eval/source once and hand to every consumer.
#
#   ONE operator intent · ONE mode resolution · ONE effective mode
#   ONE reconciliation path · ZERO cross-mode full-pipeline calls
#
# Before this, `auto` was recomputed independently at eight sites against a
# 60-second EVE-freshness window, so a renderer and the daemon could resolve
# differently milliseconds apart.
#
#   ONE RESOLVER IMPLEMENTATION  !=  ONE RESOLUTION PER TRANSACTION
#
# ⛔ resolution_id is WITNESS METADATA, never POLICY AUTHORITY. Nothing decides
#    classic-vs-suricata from it. It exists so consumers can prove they used the
#    SAME upstream decision -- because EQUAL VALUES != SAME DECISION, and two
#    independent resolutions that agree look correct while the single-resolution
#    contract is already broken.
#
#   generated EXACTLY here · IMMUTABLE for the plan's life · copied to every
#   consumer · NEVER regenerated by a consumer · NEVER an input to mode selection
#
# ⛔ DERIVED STATE, NOT DURABLE CONFIGURATION. `MODE=auto` stays the operator's
#    durable intent; effective_mode and resolution_id are evidence about it.
# -----------------------------------------------------------------------------
nftban_module_resolve_plan() {
    local module="${1:-}" mode_var configured effective basis rid now enabled

    # ⛔ PLAN-N1 ENFORCEMENT: SECOND RESOLUTION WITHIN A TRANSACTION IS A
    # CONTRACT VIOLATION -- even when it would produce the SAME effective_mode.
    # A transaction root clears NFTBAN_PLAN_TXN_ID before resolving; anything
    # else resolving while a transaction is open is a second authority.
    #   EQUAL VALUES != SAME DECISION
    if [[ -n "${NFTBAN_PLAN_TXN_ID:-}" ]]; then
        echo "nftban_module_resolve_plan: SECOND RESOLUTION inside transaction ${NFTBAN_PLAN_TXN_ID} — refused." >&2
        echo "  A resolved plan already exists for this transaction. Consumers must CONSUME it," >&2
        echo "  not resolve again. Agreement on effective_mode does not repair a provenance break." >&2
        return 3
    fi

    mode_var="$(_nftban_module_mode_var "$module")" || {
        echo "nftban_module_resolve_plan: unknown module '$module'" >&2
        return 2
    }

    if nftban_module_effective_enabled "$module"; then enabled="true"; else enabled="false"; fi

    local base="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/${module}/main.conf" v
    configured="auto"
    v="$(_nftban_module_read_key "$base" "$mode_var")";        [[ -n "$v" ]] && configured="$v"
    v="$(_nftban_module_read_key "${base}.local" "$mode_var")"; [[ -n "$v" ]] && configured="$v"

    if [[ "$enabled" != "true" ]]; then
        effective="inactive"; basis="module_disabled"
    else
        case "$configured" in
            classic)  effective="classic";  basis="configured_classic" ;;
            suricata) effective="suricata"; basis="configured_suricata" ;;
            hybrid)
                # ⛔ LEGACY INPUT -- ACCEPTED FOR OBSERVATION, NEVER REINTERPRETED.
                # The frozen model has no fourth effective mode, but that does
                # NOT establish that historical `hybrid` MEANT `auto`. The old
                # hybrid path had its own behaviour, and that behaviour is the
                # dual-mode confusion being eliminated. Mapping it onto `auto`
                # would be a NEW POLICY DECISION wearing compatibility clothing.
                #
                #   AUTO   = an active supported resolution policy
                #   HYBRID = legacy configuration input
                #   THEY ARE NOT ALIASES.
                #
                # REMOVING AN INVALID MODE IS NOT AUTHORITY TO SILENTLY
                # REDEFINE WHAT THAT MODE MEANT.
                #
                # Fail closed. Base Layer-0 is unconditional, so this withholds
                # only the higher tier -- it never removes protection. If product
                # evidence later establishes a canonical migration, make it
                # explicit and deliberate, not a side effect of auto semantics.
                effective="unknown"
                basis="legacy_hybrid_requires_explicit_migration"
                ;;
            auto)
                local pred="nftban_${module}_suricata_is_available"
                if [[ "$(type -t "$pred" || true)" != "function" ]]; then
                    effective="classic"; basis="auto_suricata_module_not_loaded"
                elif "$pred" >/dev/null 2>&1; then
                    effective="suricata"; basis="auto_suricata_available"
                else
                    effective="classic"; basis="auto_suricata_unavailable"
                fi
                ;;
            *)
                # ⛔ Fail closed. An unrecognised mode is UNKNOWN, never a guess.
                effective="unknown"; basis="unrecognised_configured_mode:${configured}"
                ;;
        esac
    fi

    rid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null \
           || uuidgen 2>/dev/null \
           || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    printf 'NFTBAN_PLAN_MODULE=%s\n'           "$module"
    printf 'NFTBAN_PLAN_ENABLED=%s\n'          "$enabled"
    printf 'NFTBAN_PLAN_CONFIGURED_MODE=%s\n'  "$configured"
    printf 'NFTBAN_PLAN_EFFECTIVE_MODE=%s\n'   "$effective"
    printf 'NFTBAN_PLAN_RESOLUTION_ID=%s\n'    "$rid"
    printf 'NFTBAN_PLAN_RESOLVED_AT=%s\n'      "$now"
    printf 'NFTBAN_PLAN_RESOLUTION_BASIS=%s\n' "$basis"
    return 0
}

# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# CONVERGENCE GENERATION — the binding that makes a plan record CURRENT
#
# v1.229.7 PR-3A. A plan witness is only usable if it describes the convergence
# that is actually rendered. Without a binding, a perfectly well-formed
# auto->classic record can survive while a later renderer resolved auto->suricata,
# and the validator would derive the wrong expectation from a valid-looking file.
#
#     A PLAN RECORD IS USABLE ONLY IF ITS BINDING IS CURRENT.
#
# Every convergence root BUMPS the generation before it converges; every plan
# publication STAMPS the generation current at publish time. A root that
# re-renders without re-resolving a module therefore leaves that module's record
# behind at an older generation, where it reads as STALE -> UNKNOWN rather than
# as a usable expectation.
#
# ⛔ This is a binding, not an authority. The generation never selects a mode.
# -----------------------------------------------------------------------------
NFTBAN_PLAN_GENERATION_FILE="${NFTBAN_PLAN_GENERATION_FILE:-/run/nftban/convergence-generation}"

nftban_plan_generation_current() {
    local g=""
    [[ -r "$NFTBAN_PLAN_GENERATION_FILE" ]] && read -r g < "$NFTBAN_PLAN_GENERATION_FILE" 2>/dev/null
    # An absent file is generation 0, not an error: a host that has never
    # converged still has a coherent (empty) generation. ENOENT != ABSENCE of
    # meaning -- it IS the pre-convergence generation, and records stamped 0
    # match it until the first real convergence bumps past them.
    [[ "$g" =~ ^[0-9]+$ ]] || g=0
    printf '%s' "$g"
}

nftban_plan_generation_bump() {
    local dir cur next tmp
    dir="$(dirname "$NFTBAN_PLAN_GENERATION_FILE")"
    [[ -d "$dir" ]] || return 0   # no /run/nftban yet: nothing to bind to
    cur="$(nftban_plan_generation_current)"
    next=$(( cur + 1 ))
    tmp="${NFTBAN_PLAN_GENERATION_FILE}.$$"
    printf '%s\n' "$next" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$NFTBAN_PLAN_GENERATION_FILE" 2>/dev/null || rm -f "$tmp"
    return 0
}

# nftban_module_plan_provenance_ok <module>
#
# ⛔ PLAN-N2 ENFORCEMENT: a consumer must carry the SAME plan identity as the
# transaction it runs inside. Three distinct failure classes, deliberately NOT
# collapsed:
#     NO ID                 != TWO DIFFERENT VALID IDS
#     MISSING PROVENANCE    != MIXED PROVENANCE
# -----------------------------------------------------------------------------
nftban_module_plan_provenance_ok() {
    local module="${1:-}"
    if [[ "${NFTBAN_PLAN_MODULE:-}" != "$module" ]]; then
        echo "  plan provenance: no plan for module '$module'" >&2; return 1
    fi
    if [[ -z "${NFTBAN_PLAN_RESOLUTION_ID:-}" ]]; then
        echo "  plan provenance: MISSING resolution_id — contract failure, not a pass." >&2; return 1
    fi
    if [[ -z "${NFTBAN_PLAN_TXN_ID:-}" ]]; then
        echo "  plan provenance: no open transaction — a consumer must run inside one." >&2; return 1
    fi
    if [[ "${NFTBAN_PLAN_RESOLUTION_ID}" != "${NFTBAN_PLAN_TXN_ID}" ]]; then
        echo "  plan provenance: MIXED — consumer carries ${NFTBAN_PLAN_RESOLUTION_ID} inside transaction ${NFTBAN_PLAN_TXN_ID}." >&2
        return 1
    fi
    return 0
}

export -f nftban_plan_generation_current nftban_plan_generation_bump _nftban_module_enable_var _nftban_module_read_key nftban_module_effective_enabled nftban_module_set_enabled _nftban_module_mode_var nftban_module_resolve_plan nftban_module_plan_provenance_ok
