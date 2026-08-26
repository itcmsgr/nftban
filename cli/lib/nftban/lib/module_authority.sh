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
# ⛔ EXPORTED. `export -f nftban_plan_generation_current` sends the FUNCTION to
# child processes; without exporting the variable it depends on, that inherited
# function runs with NFTBAN_PLAN_GENERATION_FILE UNSET and returns EMPTY.
# Measured: parent gen=[6] var=[/run/nftban/convergence-generation]
#           child  gen=[]  var=[UNSET]
# That is why the whole firewall lane (reload/rebuild/reset), which invokes
# `nftban <mod> reload` as a subprocess, published UNBOUND plan records while a
# standalone module reload and the daemon published correctly.
#   AN EXPORTED FUNCTION MUST NOT DEPEND ON AN UNEXPORTED VARIABLE.
export NFTBAN_PLAN_GENERATION_FILE="${NFTBAN_PLAN_GENERATION_FILE:-/run/nftban/convergence-generation}"
# v1.229.7 PR-4: the transient plan-record directory, as a variable so the read
# contract is testable without rewriting source text. Mirrors validator.RunDir.
export NFTBAN_PLAN_RECORD_DIR="${NFTBAN_PLAN_RECORD_DIR:-/run/nftban}"

nftban_plan_generation_current() {
    # Defence in depth: an inherited copy of this function must still resolve the
    # canonical path if the variable did not travel with it. This is the SAME
    # canonical location, not an invented one -- it manufactures no authority.
    local gf="${NFTBAN_PLAN_GENERATION_FILE:-/run/nftban/convergence-generation}"
    local g=""
    [[ -r "$gf" ]] && read -r g < "$gf" 2>/dev/null
    # An absent file is generation 0, not an error: a host that has never
    # converged still has a coherent (empty) generation. ENOENT != ABSENCE of
    # meaning -- it IS the pre-convergence generation, and records stamped 0
    # match it until the first real convergence bumps past them.
    [[ "$g" =~ ^[0-9]+$ ]] || g=0
    printf '%s' "$g"
}

# ⛔ v1.229.11 LANE 6A — IS DELETED, NOT DEPRECATED.
#
# It advanced the generation as a STANDALONE act, decoupled from whether the
# convergence it announced had happened. That is the defect this lane removes,
# and leaving the primitive in place — exported, callable, with no callers —
# would leave the invariant a CONVENTION that the next caller can break.
#
#	THE GENERATION ADVANCES IN nftban_plan_txn_commit, OR NOWHERE.
#
# A guard in mode_plan_exclusivity asserts that structurally: exactly one
# function in the tree writes the generation file, and it is the commit.

# -----------------------------------------------------------------------------
# nftban_module_report_modes <module>
#
# v1.229.7 PR-4. THE READ-PATH MODE CONTRACT.
#
#     STATUS MUST NOT RESOLVE AUTO.
#     CONFIGURED INTENT != EFFECTIVE DECISION != OBSERVED RUNTIME
#
# Emits two of the three report axes (the third, observed runtime, is each
# caller's own independent observation and is never derived here):
#
#     NFTBAN_REPORT_CONFIGURED_MODE  durable operator intent, VERBATIM --
#                                    classic | suricata | auto | a legacy or
#                                    invalid value exactly as configured
#     NFTBAN_REPORT_EFFECTIVE_MODE   classic | suricata | inactive | unknown
#     NFTBAN_REPORT_EFFECTIVE_BASIS  why effective_mode is what it is
#
# ⛔ This function NEVER:
#      resolves `auto`                    (that is the transaction root's job)
#      probes Suricata availability        (that is how the old detector guessed)
#      infers effective_mode from observed kernel objects
#      falls back from a broken/missing plan to the configured mode
#      mutates anything
#
# ⛔ OBSERVED STATE != AUTHORITY TO RECONSTRUCT THE DECISION. A caller may report
#    "classic objects are present"; it may NOT conclude "effective_mode=classic".
#
# ⛔ STATUS MUST NOT CLAIM EFFECT FRESHNESS FROM VALUE FRESHNESS. An explicit
#    configured mode does not prove the currently effective transaction used it:
#    with no current plan the answer is still `unknown`.
#
# One valid special case: a DISABLED module is `inactive`, because disabling
# requires no choice between classic and Suricata. That is the existing
# short-circuit, deliberately not broadened into another resolver.
#
# This mirrors internal/validator readEffectiveMode. The two implementations
# must agree; a drift guard asserts the rule set is identical.
# -----------------------------------------------------------------------------
nftban_module_report_modes() {
    local module="${1:-}" configured effective basis
    case "$module" in
        ddos|portscan) ;;
        *) echo "nftban_module_report_modes: unknown module '${module}'" >&2; return 2 ;;
    esac

    # Same base + .local layering nftban_module_effective_enabled uses, so the
    # reported intent is the intent that actually applies.
    local mode_key base v
    mode_key="$(_nftban_module_mode_var "$module")" || return 2
    base="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/${module}/main.conf"
    configured="auto"
    v="$(_nftban_module_read_key "$base" "$mode_key")";        [[ -n "$v" ]] && configured="$v"
    v="$(_nftban_module_read_key "${base}.local" "$mode_key")"; [[ -n "$v" ]] && configured="$v"

    # DISABLED -> inactive. The one valid short-circuit.
    if ! nftban_module_effective_enabled "$module"; then
        effective="inactive"; basis="module_disabled"
        printf 'NFTBAN_REPORT_CONFIGURED_MODE=%s
' "$configured"
        printf 'NFTBAN_REPORT_EFFECTIVE_MODE=%s
'  "$effective"
        printf 'NFTBAN_REPORT_EFFECTIVE_BASIS=%s
' "$basis"
        return 0
    fi

    # v1.229.11 lane 6A: SNAPSHOT-CONFIRMED READ. The generation is read, the
    # record for THAT generation is read, then the generation is read again. If
    # it moved underneath us the snapshot is incoherent and we retry.
    #     A COHERENT SNAPSHOT WITHOUT LOCKING READERS.
    # ⛔ Read-only commands MUST NOT take the convergence lock — a status query
    # must never be able to block, or be blocked by, a converging writer.
    local p_module="" p_effective="" p_configured="" p_gen=""
    local snap_gen="" snap_ok="false" _try g1 g2 pf
    # ⛔ IN-TRANSACTION VERIFICATION. Commit-last is only meaningful if the
    # writer can VERIFY the set it staged BEFORE making it authoritative. When
    # NFTBAN_PLAN_TARGET_GENERATION is set this process belongs to the open
    # transaction, so it selects the target and no re-read is needed — the
    # generation cannot move underneath a writer that owns it.
    # Only the writer's own process tree carries that variable, so every
    # external reader is unaffected and still sees the COMMITTED generation.
    #     THE VERIFIER OF A TRANSACTION READS THAT TRANSACTION.
    #     EVERY OTHER READER READS WHAT IS COMMITTED.
    if [[ -n "${NFTBAN_PLAN_TARGET_GENERATION:-}" ]]; then
        snap_gen="$NFTBAN_PLAN_TARGET_GENERATION"; snap_ok="true"
        pf="$(nftban_plan_record_path "$module" "$snap_gen")"
        if [[ -r "$pf" ]]; then
            local tline tk tv
            while IFS= read -r tline; do
                tk="${tline%%=*}"; tv="${tline#*=}"
                case "$tk" in
                    NFTBAN_PLAN_MODULE)           p_module="$tv" ;;
                    NFTBAN_PLAN_EFFECTIVE_MODE)   p_effective="$tv" ;;
                    NFTBAN_PLAN_CONFIGURED_MODE)  p_configured="$tv" ;;
                    NFTBAN_PLAN_BOUND_GENERATION) p_gen="$tv" ;;
                esac
            done < "$pf"
        fi
    fi
    for (( _try = 0; _try < ${NFTBAN_PLAN_SNAPSHOT_RETRIES:-3}; _try++ )); do
        # ⛔ STRING TEST, NOT ARITHMETIC. Written as a (( )) loop condition,
        # `snap_ok != "true"` would be evaluated ARITHMETICALLY: both operands
        # resolve as unset variable names to 0, the condition is false, and the
        # snapshot loop would never execute at all.
        #     A STRING COMPARISON INSIDE (( )) IS NOT A STRING COMPARISON.
        [[ "$snap_ok" == "true" ]] && break
        g1="$(nftban_plan_generation_current)"
        p_module=""; p_effective=""; p_configured=""; p_gen=""
        pf="$(nftban_plan_record_path "$module" "$g1")"
        # MIGRATION READ. A host converged before v1.229.11 carries an
        # unsuffixed record. It is accepted ONLY if it declares the generation
        # we just selected, so this reads existing state without inventing any.
        #     A COMPATIBILITY READ MAY NOT RELAX THE BINDING CHECK.
        [[ -r "$pf" ]] || pf="${NFTBAN_PLAN_RECORD_DIR}/module-plan-${module}.env"
        if [[ -r "$pf" ]]; then
            local line k v
            while IFS= read -r line; do
                k="${line%%=*}"; v="${line#*=}"
                case "$k" in
                    NFTBAN_PLAN_MODULE)           p_module="$v" ;;
                    NFTBAN_PLAN_EFFECTIVE_MODE)   p_effective="$v" ;;
                    NFTBAN_PLAN_CONFIGURED_MODE)  p_configured="$v" ;;
                    NFTBAN_PLAN_BOUND_GENERATION) p_gen="$v" ;;
                esac
            done < "$pf"
        fi
        g2="$(nftban_plan_generation_current)"
        if [[ "$g1" == "$g2" ]]; then snap_gen="$g1"; snap_ok="true"; break; fi
    done

    effective="unknown"; basis="no_current_plan"
    if [[ "$snap_ok" != "true" ]]; then
        # The generation moved on every attempt. This is NOT corruption and NOT
        # a missing plan — it is an active convergence, and saying so keeps the
        # two apart for a later health surface.
        #     STILL MOVING != BROKEN.
        basis="convergence_in_progress"
    elif [[ -z "$p_module" ]]; then
        basis="no_current_plan"
    elif [[ "$p_module" != "$module" || -z "$p_configured" ]]          || [[ "$p_effective" != "classic" && "$p_effective" != "suricata" && "$p_effective" != "inactive" ]]; then
        basis="plan_malformed"
    elif [[ -z "$p_gen" || "$p_gen" != "$snap_gen" ]]; then
        basis="plan_not_bound_to_current_convergence"
    elif [[ "$p_configured" != "$configured" ]]; then
        basis="plan_superseded_by_config_change"
    elif [[ ( "$configured" == "classic" || "$configured" == "suricata" ) && "$p_effective" != "$configured" ]]; then
        basis="plan_contradicts_explicit_intent"
    else
        effective="$p_effective"; basis="current_plan"
    fi

    printf 'NFTBAN_REPORT_CONFIGURED_MODE=%s
' "$configured"
    printf 'NFTBAN_REPORT_EFFECTIVE_MODE=%s
'  "$effective"
    printf 'NFTBAN_REPORT_EFFECTIVE_BASIS=%s
' "$basis"
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

# =============================================================================
# v1.229.11 LANE 6A — THE CONVERGENCE COMMIT TRANSACTION
# =============================================================================
# ⛔ WHY THIS EXISTS. Before v1.229.11 all three firewall mutators bumped the
# generation FIRST and republished plan records LAST:
#     cmd_firewall.sh  reload  bump :2082 -> republish :2240/:2252
#                      rebuild bump :3106 -> republish :3592/:3607
#                      reset   bump :3860 -> republish :3942/:3952
# Both readers (this file, and internal/nftbanconf/modeplan.go) require EXACT
# equality between a record's BOUND_GENERATION and the generation file, so for
# the ENTIRE duration of every convergence the authoritative state was
# self-inconsistent and every reader resolved UNKNOWN. Measured on srv3: a
# 453-second window. That window was not a rare race — it was entered on every
# single convergence, by design.
#
#     THE WINDOW WAS NOT A RACE. IT WAS THE NORMAL STATE.
#
# srv3's observed `gen=1, bound=0` was that window MADE PERMANENT when the
# installer's 60s timeout killed the rebuild before republication. The kill did
# not create the inconsistency; it froze one the design always passed through.
#
# ⛔ REORDERING ALONE CANNOT FIX IT. With exact-equality readers, publishing
# plans first and bumping last merely INVERTS the mismatch (bound=N+1 vs gen=N).
#     MOVING EITHER SIDE ONLY MOVES THE WINDOW.
#
# THE MODEL. Plan records are addressed BY GENERATION and are IMMUTABLE once
# their generation commits. The generation file is the SOLE selector and the
# SOLE commit point — one atomic rename switches the entire set:
#
#     /run/nftban/module-plan-ddos.env.42
#     /run/nftban/module-plan-portscan.env.42
#     /run/nftban/convergence-generation      -> 42
#
#     WRITER   begin -> stage *.env.N+1 -> validate -> COMMIT generation LAST
#     READER   G = read(generation) ; read *.env.G ; confirm G unchanged
#     FAILURE  generation stays N · N remains fully readable · N+1 discarded
#
# A single-value read of the generation SELECTS a whole coherent set, which is
# the invariant this lane exists to establish:
#
#     READERS MUST SEE EITHER COMPLETE N OR COMPLETE N+1 — NEVER A MIXTURE.
#
# ⛔ A symlinked plans directory was REJECTED: `current-plans -> plans/42` would
# be a SECOND selector, forcing a ruling on which of the two is canonical.
#     TWO SELECTORS FOR THE SAME STATE IS THE AMBIGUITY BEING REMOVED.
# -----------------------------------------------------------------------------

# Bounded retained history. Reaping never touches the committed generation or
# its immediate predecessors, so a reader that has already read G can still open
# G's records. This is a BOUND, not a proof of race-freedom — see the snapshot
# re-read in nftban_module_resolve_plan, which is what actually makes a reader
# coherent without forcing read-only commands to take the convergence lock.
export NFTBAN_PLAN_RETAIN_GENERATIONS="${NFTBAN_PLAN_RETAIN_GENERATIONS:-3}"
export NFTBAN_PLAN_SNAPSHOT_RETRIES="${NFTBAN_PLAN_SNAPSHOT_RETRIES:-3}"

# The modules that actually PUBLISH plan records. This is deliberately NOT the
# enablement set from _nftban_module_enable_var: botguard, geoban and feeds are
# enablement-bearing but publish no plan, and requiring a record from them would
# manufacture an artifact contract that no writer honours.
#     THE REQUIRED SET IS DERIVED FROM THE WRITERS, NOT FROM THE MODULE LIST.
# ⛔ ONE PER LINE, NOT SPACE-SEPARATED. strict.sh sets IFS=$'\n\t', so a
# space-separated list does NOT word-split in any consumer that runs under it —
# `for m in $(...)` would iterate ONCE over the literal string "ddos portscan"
# and every module lookup would fail as an unknown module.
#     A LIST FORMAT THAT DEPENDS ON THE AMBIENT IFS IS NOT A LIST.
_nftban_plan_bearing_modules() { printf 'ddos\nportscan\n'; }

# nftban_plan_record_path <module> <generation>
nftban_plan_record_path() {
    printf '%s/module-plan-%s.env.%s' \
        "${NFTBAN_PLAN_RECORD_DIR:-/run/nftban}" "${1:?module}" "${2:?generation}"
}

# nftban_plan_target_generation
#
# The generation a writer must stamp records with. Inside an open transaction
# that is the UNCOMMITTED target; outside one there is no target and callers
# must not invent a value.
#     ⛔ EXPORTED VARIABLE, DELIBERATELY. `nftban ddos reload` runs as a
#     SUBPROCESS of the firewall lane. The v1.229.7 defect documented at the top
#     of this file — an exported FUNCTION depending on an UNEXPORTED VARIABLE —
#     is exactly the trap this would fall into otherwise.
nftban_plan_target_generation() {
    if [[ -n "${NFTBAN_PLAN_TARGET_GENERATION:-}" ]]; then
        printf '%s' "$NFTBAN_PLAN_TARGET_GENERATION"; return 0
    fi
    return 1
}

# _nftban_plan_record_valid <file> <expected_module> <expected_generation>
# Structural validation only. A present-but-invalid record is a BROKEN CONTRACT,
# never evidence of absence.
_nftban_plan_record_valid() {
    local f="$1" want_mod="$2" want_gen="$3"
    [[ -r "$f" ]] || return 1
    local line k v r_mod="" r_eff="" r_cfg="" r_gen=""
    while IFS= read -r line; do
        k="${line%%=*}"; v="${line#*=}"
        case "$k" in
            NFTBAN_PLAN_MODULE)           r_mod="$v" ;;
            NFTBAN_PLAN_EFFECTIVE_MODE)   r_eff="$v" ;;
            NFTBAN_PLAN_CONFIGURED_MODE)  r_cfg="$v" ;;
            NFTBAN_PLAN_BOUND_GENERATION) r_gen="$v" ;;
        esac
    done < "$f"
    [[ "$r_mod" == "$want_mod" ]]  || return 1
    [[ "$r_gen" == "$want_gen" ]]  || return 1
    [[ -n "$r_cfg" ]]              || return 1
    case "$r_eff" in classic|suricata|inactive) ;; *) return 1 ;; esac
    return 0
}

# nftban_plan_txn_required_modules
#
# REQUIRED(target) = plan-bearing AND enabled AND
#                    ( re-resolved by this transaction OR already had a record
#                      in the committed generation )
#
# ⛔ NON-REGRESSING, NOT MANUFACTURING. A module that has never converged is not
# conjured into the required set — that would make an unrelated `nftban ddos
# reload` fail on a host where portscan has never run. But a module that HAD a
# record at N must still have one at N+1, which is precisely what makes a
# truncated rebuild detectable instead of silently committable.
#
# ⛔ DISABLED MODULES ARE EXCLUDED. Where no plan is required, ABSENCE IS
# EXPLICITLY VALID — it is never read as missing state.
nftban_plan_txn_required_modules() {
    local cur target m out=""
    cur="$(nftban_plan_generation_current)"
    target="${NFTBAN_PLAN_TARGET_GENERATION:-}"
    local rc
    while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        # ⛔ rc MUST be captured from the call itself. Inside `if ! cmd; then`,
        # `$?` is the status of the NEGATION (always 0), not of cmd — so an
        # UNKNOWN-module rc of 2 would read as 0 and be silently swallowed.
        #     A NEGATED TEST DESTROYS THE EXIT STATUS IT WAS TESTING.
        nftban_module_effective_enabled "$m"; rc=$?
        if (( rc >= 2 )); then
            echo "nftban_plan_txn_required_modules: unknown module '$m' — refusing to compute a required set." >&2
            return 2
        fi
        # rc 1 = disabled. Not required, and its ABSENCE IS EXPLICITLY VALID.
        (( rc != 0 )) && continue
        case $'\n'"${NFTBAN_PLAN_TXN_RERESOLVE:-}"$'\n' in
            *$'\n'"$m"$'\n'*) out="${out}${m}"$'\n'; continue ;;
        esac
        [[ -n "$target" ]] || continue
        if [[ -r "$(nftban_plan_record_path "$m" "$cur")" ]] \
        || [[ -r "${NFTBAN_PLAN_RECORD_DIR:-/run/nftban}/module-plan-${m}.env" ]]; then
            out="${out}${m}"$'\n'
        fi
    done < <(_nftban_plan_bearing_modules)
    printf '%s' "$out"
}

# =============================================================================
# v1.229.11 LANE 7 — CONVERGENCE TRANSACTION SERIALIZATION
# =============================================================================
# ⛔ NO NEW LOCK. This participates in the EXISTING canonical authority:
#     /run/nftban/nft_operations.lock   (internal/nftlock/lock.go:44)
# declared as "the canonical lock file for all nft operations", honoured by the
# Go daemon reconciliation, the OpQueue drain, botguard, and — since v1.229.3
# P0-J — by _firewall_rebuild_serialized. A fourth lock path would be a fourth
# authority.
#     REUSE THE CANONICAL LOCK. DO NOT INVENT A SECOND ONE.
#
# WHAT LANE 7 ACTUALLY FIXES IS COVERAGE, NOT ABSENCE. Before this, exactly one
# convergence owner was serialized:
#     _firewall_rebuild_core   COVERED   (fd 8, since v1.229.3)
#     firewall_reload          NOT       bumps, converges and commits holding nothing
#     firewall_reset           NOT       same
#     nftban ddos reload       NOT       owns a transaction, holding nothing
#     nftban portscan reload   NOT       same
# Serializing the rebuild while leaving a module-owned transaction free to race
# it protects the loudest path and leaves the quiet ones open.
#
# The lock is taken HERE, at the single chokepoint where a transaction is OWNED,
# so every owner is covered by construction and joiners never re-acquire:
#     ONE LOCK · ONE TRANSACTION OWNER · ONE TARGET GENERATION · ONE COMMIT AUTHORITY
#
# ⛔ RE-ENTRANCY IS MANDATORY, NOT DEFENSIVE. _firewall_rebuild_serialized
# already holds this exact lock before it calls into the transaction. A second
# flock on the same file from the same process would block against itself until
# the timeout and then REFUSE a rebuild that was already correctly serialized.
# The tree carries a recorded incident of exactly this shape:
#   nftban_health_checks_services.sh:632 "Dual locking (flock + script) causes
#   permanent lock state".
#     A LOCK THAT DEADLOCKS AGAINST ITS OWN HOLDER IS NOT SERIALIZATION.
# NFTBAN_NFTLOCK_HELD is EXPORTED, so `nftban ddos reload` running as a
# subprocess of the firewall lane also knows the lock is already held — and it
# genuinely is: the fd is inherited across fork/exec.
#
# ⛔ READ-ONLY PATHS TAKE NOTHING. nftban_module_report_modes never calls this.
# A status query must never block, or be blocked by, a converging writer — which
# is why the reader uses a snapshot re-read instead.
# -----------------------------------------------------------------------------

# _nftban_plan_lock_acquire — sets NFTBAN_PLAN_TXN_LOCKFD to the fd if THIS call
# acquired the lock, or to empty if an ancestor already holds it. Returns
# non-zero if the lock could not be taken.
#
# ⛔ SETS A VARIABLE; DOES NOT ECHO. It MUST be called directly, never as
# `x="$(_nftban_plan_lock_acquire)"`. Command substitution runs the function in a
# SUBSHELL: the fd would be opened and flocked inside that subshell, and the
# kernel would release the lock the instant the substitution returned. The first
# revision of this function did exactly that, and the concurrency suite caught it
# — two owners opened the same transaction concurrently while the code "held" a
# lock that had already evaporated.
#     A LOCK ACQUIRED IN A SUBSHELL IS RELEASED WHEN THAT SUBSHELL EXITS.
_nftban_plan_lock_acquire() {
    NFTBAN_PLAN_TXN_LOCKFD=""
    if [[ -n "${NFTBAN_NFTLOCK_HELD:-}" ]]; then
        return 0             # an ancestor holds it; do NOT re-acquire
    fi
    local path="${NFTBAN_RUN_DIR:-/run/nftban}/nft_operations.lock"
    # ⛔ FAIL-FAST IS THE DEFAULT. A bounded wait serializes correctly but LIES TO
    # THE OPERATOR: two administrators each run a mutation, both are told it
    # succeeded, and neither learns they collided. Measured on lab2 before this
    # change — two concurrent rebuilds, A rc=0 and B rc=0, generation 28 -> 30.
    #     SERIALIZATION CORRECTNESS AND OPERATOR TRUTH ARE NOT THE SAME PROPERTY.
    # Waiting remains available, but ONLY as EXPLICIT caller policy: a caller
    # that genuinely needs to queue sets NFTBAN_PLAN_LOCK_WAIT deliberately.
    #     ONE CANONICAL LOCK AUTHORITY, WITH CALLER POLICY EXPLICIT —
    #     never every caller inventing its own timeout.
    local wait="${NFTBAN_PLAN_LOCK_WAIT:-}"
    if ! declare -F flock >/dev/null 2>&1 && ! command -v flock >/dev/null 2>&1; then
        echo "nftban_plan_txn_begin: flock(1) unavailable — refusing to converge UNSERIALIZED." >&2
        return 1
    fi
    local fd
    # Auto-allocated fd: fd 8 is the rebuild's nftlock and fd 9 is the
    # session-whitelist critical section in the same file. Hardcoding a number
    # here could silently clobber either.
    if ! eval 'exec {fd}>>"$path"' 2>/dev/null; then
        echo "nftban_plan_txn_begin: cannot open $path — convergence NOT started." >&2
        return 1
    fi
    local _got=0
    if [[ -n "$wait" ]]; then
        flock -w "$wait" "$fd" && _got=1        # explicit caller policy: queue
    else
        flock -n "$fd" && _got=1                # default: refuse immediately
    fi
    if (( _got == 0 )); then
        # ⛔ THIS IS ITS OWN VERDICT CLASS. It is not "the convergence failed" —
        # it is "the convergence never began". Nothing has been mutated.
        eval "exec ${fd}>&-"
        echo "ERROR: convergence already in progress — this operation was REFUSED." >&2
        echo "       Another nft operation holds the convergence lock: reconciliation," >&2
        echo "       an OpQueue drain, a firewall rebuild/reload/reset, or a module reload." >&2
        echo "       NOTHING was mutated; existing enforcement is unchanged." >&2
        echo "       Wait for it to finish, then retry." >&2
        return 1
    fi
    export NFTBAN_NFTLOCK_HELD=1
    NFTBAN_PLAN_TXN_LOCKFD="$fd"
    return 0
}

# _nftban_plan_lock_release <fd-or-empty>
_nftban_plan_lock_release() {
    local fd="${1:-}"
    [[ -n "$fd" ]] || return 0        # we did not acquire it; not ours to release
    eval "exec ${fd}>&-" 2>/dev/null || true
    unset NFTBAN_NFTLOCK_HELD
    return 0
}

# nftban_plan_txn_begin <module-to-be-re-resolved>...
#
# Opens a convergence transaction. Computes the target, exports it, and carries
# forward the committed records of any required module this transaction will NOT
# re-resolve, so the target generation describes a COMPLETE set.
#     ⛔ CARRY-FORWARD IS EXPLICIT AND HAPPENS AT BEGIN. Doing it at commit
#     instead would let a truncated rebuild inherit the previous generation's
#     records and commit anyway — reintroducing the exact defect being fixed.
nftban_plan_txn_begin() {
    local dir="${NFTBAN_PLAN_RECORD_DIR:-/run/nftban}"
    local cur target m src dst tmp
    if [[ -n "${NFTBAN_PLAN_TARGET_GENERATION:-}" ]]; then
        echo "nftban_plan_txn_begin: a transaction is already open (target ${NFTBAN_PLAN_TARGET_GENERATION})." >&2
        return 3
    fi
    if [[ ! -d "$dir" ]]; then
        echo "nftban_plan_txn_begin: $dir absent — convergence transaction NOT opened." >&2
        echo "                       it is owned by systemd-tmpfiles; restore it with:" >&2
        echo "                       systemd-tmpfiles --create /usr/lib/tmpfiles.d/nftban.conf" >&2
        return 5
    fi
    # ⛔ ACQUIRE BEFORE READING THE GENERATION. If two writers both read N and
    # then serialize, both compute target N+1 and the second silently overwrites
    # the first's staged set.
    #     THE READ THAT CHOOSES THE TARGET MUST BE INSIDE THE LOCK.
    # ⛔ DIRECT CALL, NOT COMMAND SUBSTITUTION — see the note on the function.
    # rc 7 = CONVERGENCE BUSY. A DISTINCT code, deliberately: an operator must be
    # able to tell "someone else is converging" from "your convergence broke".
    #     A REFUSAL AND A FAILURE ARE DIFFERENT FACTS.
    _nftban_plan_lock_acquire || return 7
    local _lockfd="${NFTBAN_PLAN_TXN_LOCKFD:-}"

    cur="$(nftban_plan_generation_current)" || cur=""
    # ⛔ EMPTY BINDING MUST BE UNREPRESENTABLE — ENFORCED AT TRANSACTION OPEN.
    # This check used to live in the publisher. Moving the binding to the
    # transaction moved the obligation with it: an empty or non-numeric current
    # generation would otherwise arithmetic-coerce to 0 here and silently target
    # generation 1, republishing a whole host onto a generation nothing reached.
    #     A BROKEN GENERATION AUTHORITY MUST FAIL THE TRANSACTION, NOT DEFAULT IT.
    if [[ -z "$cur" || ! "$cur" =~ ^[0-9]+$ ]]; then
        echo "nftban_plan_txn_begin: convergence generation authority returned '${cur:-<empty>}' — transaction NOT opened." >&2
        _nftban_plan_lock_release "$_lockfd"; unset NFTBAN_PLAN_TXN_LOCKFD
        return 5
    fi
    target=$(( cur + 1 ))
    export NFTBAN_PLAN_TARGET_GENERATION="$target"
    # Newline-separated for the same IFS reason as the bearing-module list.
    NFTBAN_PLAN_TXN_RERESOLVE=""
    for m in "$@"; do NFTBAN_PLAN_TXN_RERESOLVE="${NFTBAN_PLAN_TXN_RERESOLVE}${m}"$'\n'; done
    NFTBAN_PLAN_TXN_RERESOLVE="${NFTBAN_PLAN_TXN_RERESOLVE%$'\n'}"
    export NFTBAN_PLAN_TXN_RERESOLVE

    # ⛔ IMMUTABILITY. If records for the target already exist, a previous
    # transaction staged them and did not commit. They are uncommitted by
    # definition (the generation file does not point at them), so clearing them
    # discards nothing authoritative — but never touch a COMMITTED generation.
    while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        rm -f "$(nftban_plan_record_path "$m" "$target")" 2>/dev/null || true
        rm -f "$(nftban_plan_record_path "$m" "$target")".tmp.* 2>/dev/null || true
    done < <(_nftban_plan_bearing_modules)

    local required
    required="$(nftban_plan_txn_required_modules)" || { nftban_plan_txn_abort; return 2; }
    while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        case $'\n'"${NFTBAN_PLAN_TXN_RERESOLVE}"$'\n' in *$'\n'"$m"$'\n'*) continue ;; esac
        src="$(nftban_plan_record_path "$m" "$cur")"
        [[ -r "$src" ]] || src="${dir}/module-plan-${m}.env"
        if [[ ! -r "$src" ]]; then
            echo "nftban_plan_txn_begin: required module '$m' has no record at generation $cur — cannot carry forward." >&2
            nftban_plan_txn_abort
            return 4
        fi
        dst="$(nftban_plan_record_path "$m" "$target")"
        tmp="${dst}.tmp.$$"
        if ! sed "s/^NFTBAN_PLAN_BOUND_GENERATION=.*/NFTBAN_PLAN_BOUND_GENERATION=${target}/" \
                "$src" > "$tmp" 2>/dev/null; then
            rm -f "$tmp"
            echo "nftban_plan_txn_begin: failed to carry '$m' forward to generation $target." >&2
            nftban_plan_txn_abort
            return 4
        fi
        chmod 0640 "$tmp" 2>/dev/null || true
        if ! mv -f "$tmp" "$dst" 2>/dev/null; then
            rm -f "$tmp"
            echo "nftban_plan_txn_begin: atomic staging of '$m' failed." >&2
            nftban_plan_txn_abort
            return 4
        fi
    # ⛔ '%s\n', NOT '%s'. `$(...)` strips trailing newlines, so a bare %s feeds
    # the loop a final line with NO terminator — `read` consumes it, sets the
    # variable, and STILL returns non-zero, so the loop exits WITHOUT running the
    # body for the last element. The last required module would be silently
    # skipped: never carried forward, never validated before commit.
    #     A LOOP THAT DROPS ITS LAST ELEMENT VALIDATES A SMALLER SET THAN IT CLAIMS.
    done < <(printf '%s\n' "$required")
    return 0
}

# nftban_plan_txn_abort
# Removes ONLY uncommitted target artifacts. The committed generation and every
# record belonging to it are left exactly as they were.
nftban_plan_txn_abort() {
    local target="${NFTBAN_PLAN_TARGET_GENERATION:-}" m
    if [[ -n "$target" ]]; then
        while IFS= read -r m; do
            [[ -n "$m" ]] || continue
            rm -f "$(nftban_plan_record_path "$m" "$target")" 2>/dev/null || true
            rm -f "$(nftban_plan_record_path "$m" "$target")".tmp.* 2>/dev/null || true
        done < <(_nftban_plan_bearing_modules)
    fi
    _nftban_plan_lock_release "${NFTBAN_PLAN_TXN_LOCKFD:-}"
    unset NFTBAN_PLAN_TARGET_GENERATION NFTBAN_PLAN_TXN_RERESOLVE NFTBAN_PLAN_TXN_LOCKFD
    return 0
}

# nftban_plan_txn_commit
#
# THE ONLY PLACE THE GENERATION EVER ADVANCES. Validates that every required
# module has a structurally valid record bound to the target, then performs the
# single atomic rename that makes the whole set authoritative.
nftban_plan_txn_commit() {
    local target="${NFTBAN_PLAN_TARGET_GENERATION:-}"
    local gf="${NFTBAN_PLAN_GENERATION_FILE:-/run/nftban/convergence-generation}"
    local m required tmp
    if [[ -z "$target" ]]; then
        echo "nftban_plan_txn_commit: no open transaction — nothing to commit." >&2
        return 3
    fi
    required="$(nftban_plan_txn_required_modules)" || { nftban_plan_txn_abort; return 2; }
    while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        if ! _nftban_plan_record_valid "$(nftban_plan_record_path "$m" "$target")" "$m" "$target"; then
            echo "nftban_plan_txn_commit: module '$m' has no valid record for generation $target." >&2
            echo "                        CONVERGENCE DID NOT COMPLETE — generation NOT advanced." >&2
            nftban_plan_txn_abort
            return 6
        fi
    # ⛔ '%s\n', NOT '%s'. `$(...)` strips trailing newlines, so a bare %s feeds
    # the loop a final line with NO terminator — `read` consumes it, sets the
    # variable, and STILL returns non-zero, so the loop exits WITHOUT running the
    # body for the last element. The last required module would be silently
    # skipped: never carried forward, never validated before commit.
    #     A LOOP THAT DROPS ITS LAST ELEMENT VALIDATES A SMALLER SET THAN IT CLAIMS.
    done < <(printf '%s\n' "$required")
    tmp="${gf}.$$"
    if ! printf '%s\n' "$target" > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        echo "nftban_plan_txn_commit: cannot write $tmp — generation NOT advanced." >&2
        nftban_plan_txn_abort
        return 5
    fi
    chmod 0644 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$gf" 2>/dev/null; then
        rm -f "$tmp"
        echo "nftban_plan_txn_commit: atomic commit of $gf failed — generation NOT advanced." >&2
        nftban_plan_txn_abort
        return 5
    fi
    _nftban_plan_lock_release "${NFTBAN_PLAN_TXN_LOCKFD:-}"
    unset NFTBAN_PLAN_TARGET_GENERATION NFTBAN_PLAN_TXN_RERESOLVE NFTBAN_PLAN_TXN_LOCKFD
    nftban_plan_generation_reap "$target"
    return 0
}

# nftban_plan_generation_reap <committed>
# Retains NFTBAN_PLAN_RETAIN_GENERATIONS generations ending at <committed>.
#     ⛔ THIS IS A BOUND, NOT A PROOF. A reader descheduled after reading G could
#     in principle find G reaped by the time it opens the record. That is why the
#     reader re-reads the generation and retries rather than trusting retention.
nftban_plan_generation_reap() {
    local committed="${1:-}" dir="${NFTBAN_PLAN_RECORD_DIR:-/run/nftban}"
    [[ "$committed" =~ ^[0-9]+$ ]] || return 0
    local floor=$(( committed - NFTBAN_PLAN_RETAIN_GENERATIONS + 1 ))
    if (( floor < 0 )); then floor=0; fi
    local f base g
    for f in "$dir"/module-plan-*.env.*; do
        [[ -e "$f" ]] || continue
        base="${f##*/}"; g="${base##*.env.}"
        [[ "$g" =~ ^[0-9]+$ ]] || continue
        (( g < floor )) && rm -f "$f" 2>/dev/null || true
    done
    return 0
}

export -f _nftban_plan_lock_acquire _nftban_plan_lock_release nftban_plan_record_path nftban_plan_target_generation _nftban_plan_bearing_modules \
    _nftban_plan_record_valid nftban_plan_txn_required_modules nftban_plan_txn_begin \
    nftban_plan_txn_abort nftban_plan_txn_commit nftban_plan_generation_reap
export -f nftban_module_report_modes nftban_plan_generation_current _nftban_module_enable_var _nftban_module_read_key nftban_module_effective_enabled nftban_module_set_enabled _nftban_module_mode_var nftban_module_resolve_plan nftban_module_plan_provenance_ok
