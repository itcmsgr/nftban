#!/usr/bin/env bash
# =============================================================================
# NFTBan - DDoS Protection Module - MAIN CONTROLLER
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Dual-mode DDoS protection with auto-detection
#
# meta:name="nftban_ddos"
# meta:type="core"
# meta:header="DDoS Protection"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description**
# Main controller for DDoS protection with dual-mode support:
#
#   CLASSIC MODE:  Pure nftables (no Suricata required)
#   SURICATA MODE: IDS-integrated with scoring engine
#   HYBRID MODE:   Classic as Layer 0 + Suricata as Layer 1
#   AUTO MODE:     Auto-detect best mode based on system
#
# **Mode Selection Logic:**
#   1. The transaction root resolves DDOS_MODE (auto|classic|suricata) ONCE
#      and publishes a plan; consumers read that plan and never re-resolve.
#      `hybrid` is LEGACY: it resolves to `unknown` and refuses (v1.229.7).
#   2. If "auto": detect Suricata availability
#   3. Load appropriate sub-module
#
# meta:description="Dual-mode DDoS protection with auto-detection"
# meta:depends="bash>=4.0,nftables>=0.9.0"
# meta:inventory.files=""
# meta:inventory.binaries="nft,systemctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/ddos/main.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# meta:created_date="2025-12-01"
# meta:updated_date="2026-02-05"
# =============================================================================

set -Eeuo pipefail

# v1.229.7 PR-3A: the apply/teardown halves consume a RESOLVED MODULE PLAN from
# nftban_module_resolve_plan (lib/module_authority.sh). The daemon sources this
# file standalone (`bash -c 'source "$1" && nftban_ddos_apply'`), so the authority
# must be guard-sourced here rather than assumed present.
# shellcheck source=/usr/lib/nftban/lib/module_authority.sh
if ! declare -F nftban_module_resolve_plan >/dev/null 2>&1 && \
   [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/module_authority.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/module_authority.sh" 2>/dev/null || true
fi
IFS=$'\n\t'
umask 027

# =============================================================================
# MODULE GUARD
# =============================================================================

[[ -n "${NFTBAN_DDOS_LOADED:-}" ]] && return 0
readonly NFTBAN_DDOS_LOADED=1

# =============================================================================
# MODULE METADATA
# =============================================================================

# shellcheck disable=SC2034  # Module metadata used when sourced
readonly DDOS_MODULE_NAME="nftban_ddos"
# shellcheck disable=SC2034  # Module metadata used when sourced
readonly DDOS_MODULE_VERSION="1.0.0"
# shellcheck disable=SC2034  # Module metadata used when sourced
readonly DDOS_MODULE_TYPE="core"
# shellcheck disable=SC2034  # Module metadata used when sourced
readonly DDOS_MODULE_DESCRIPTION="DDoS Protection (Dual-Mode)"

# =============================================================================
# PATHS
# =============================================================================

: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
NFTBAN_DDOS_LIB_DIR="$NFTBAN_LIB_DIR"
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"
NFTBAN_DDOS_CONFIG_DIR="$NFTBAN_CONFIG_DIR"
readonly NFTBAN_DDOS_LOG_FILE="${NFTBAN_LOG_DIR:-/var/log/nftban}/ddos.log"

# =============================================================================
# LOAD SHARED LIBRARIES
# =============================================================================

# Source timestamp utilities (with graceful fallback)
if [[ -f "${NFTBAN_DDOS_LIB_DIR}/lib/nftban_timestamp.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_DDOS_LIB_DIR}/lib/nftban_timestamp.sh" || return 1
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/../lib/nftban_timestamp.sh" ]]; then
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/nftban_timestamp.sh" || return 1
fi

# Source file utilities (with graceful fallback)
if [[ -f "${NFTBAN_DDOS_LIB_DIR}/lib/nftban_file_utils.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_DDOS_LIB_DIR}/lib/nftban_file_utils.sh" || return 1
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/../lib/nftban_file_utils.sh" ]]; then
    # shellcheck source=/dev/null
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/nftban_file_utils.sh" || return 1
fi

# =============================================================================
# LOAD SUB-MODULES
# =============================================================================

# Source classic module
if [[ -f "${NFTBAN_DDOS_LIB_DIR}/core/nftban_ddos_classic.sh" ]]; then
    source "${NFTBAN_DDOS_LIB_DIR}/core/nftban_ddos_classic.sh" || return 1
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/nftban_ddos_classic.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/nftban_ddos_classic.sh" || return 1
fi

# Source suricata module
if [[ -f "${NFTBAN_DDOS_LIB_DIR}/core/nftban_ddos_suricata.sh" ]]; then
    source "${NFTBAN_DDOS_LIB_DIR}/core/nftban_ddos_suricata.sh" || return 1
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/nftban_ddos_suricata.sh" ]]; then
    source "$(dirname "${BASH_SOURCE[0]}")/nftban_ddos_suricata.sh" || return 1
fi

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================

_nftban_ddos_load_config() {
    local main_config="${NFTBAN_DDOS_CONFIG_DIR}/conf.d/ddos/main.conf"
    local main_local="${NFTBAN_DDOS_CONFIG_DIR}/conf.d/ddos/main.conf.local"

    # Load defaults first
    if [[ -f "$main_config" ]]; then
        # shellcheck source=/dev/null
        source "$main_config" || true
    fi

    # Load user overrides (takes precedence)
    if [[ -f "$main_local" ]]; then
        # shellcheck source=/dev/null
        # IMPL-1: ensure _source_local is defined wherever this file is loaded (env.sh idempotent)
        declare -F _source_local >/dev/null 2>&1 || source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/env.sh" 2>/dev/null || true
        _source_local "$main_local"
    fi

    # Set defaults
    : "${DDOS_ENABLED:=false}"
    : "${DDOS_MODE:=auto}"
    : "${DDOS_AUTO_CHECK_SERVICE:=true}"
    : "${DDOS_AUTO_CHECK_BINARY:=true}"
    : "${DDOS_AUTO_CHECK_EVE_FILE:=true}"
    : "${DDOS_SURICATA_SERVICE_NAME:=suricata}"
    : "${DDOS_SURICATA_BINARY:=/usr/bin/suricata}"
    : "${DDOS_EVE_FRESHNESS_THRESHOLD:=60}"
    : "${DDOS_HYBRID_CLASSIC_LAYER0:=true}"
    : "${DDOS_NFT_TABLE_IPV4:=ip nftban}"
    : "${DDOS_NFT_TABLE_IPV6:=ip6 nftban}"
    : "${DDOS_NFT_CHAIN:=ddos_protection}"
}

# =============================================================================
# LOGGING
# =============================================================================

_nftban_ddos_log() {
    local level="$1"
    local message="$2"

    mkdir -p "$(dirname "$NFTBAN_DDOS_LOG_FILE")" 2>/dev/null || return 1

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DDOS] [$level] $message" >> "$NFTBAN_DDOS_LOG_FILE"
}

# =============================================================================
# BANNER
# =============================================================================

_nftban_ddos_banner() {
    if type -t nftban_banner >/dev/null 2>&1; then
        nftban_banner
    else
        echo "╔═══════════════════════════════════════════════════════════════════════════╗"
        echo "║  🛡️  DDoS Protection                                                      ║"
        echo "║  NFTBan — Open-source Linux IPS and nftables firewall manager            ║"
        echo "╚═══════════════════════════════════════════════════════════════════════════╝"
    fi
}

# =============================================================================
# MODE DETECTION
# =============================================================================

# Detect the best mode based on system state
_nftban_ddos_detect_mode() {
    local configured_mode="${DDOS_MODE:-auto}"

    # If mode is explicitly set (not auto), return it
    if [[ "$configured_mode" != "auto" ]]; then
        echo "$configured_mode"
        return 0
    fi

    # Auto-detection: check if Suricata is available
    if type -t nftban_ddos_suricata_is_available &>/dev/null; then
        if nftban_ddos_suricata_is_available; then
            echo "suricata"
            return 0
        fi
    fi

    # Fallback to classic
    echo "classic"
}

# Get current active mode
nftban_ddos_get_mode() {
    _nftban_ddos_load_config
    # ⛔ v1.229.7 PR-4 READ-PATH MODE CONTRACT. This used the local detector,
    # which resolves `auto` by probing Suricata availability -- a second,
    # independent authority that could report a mode the system had not decided.
    #   STATUS MUST NOT RESOLVE AUTO.
    #   CONFIGURED INTENT != EFFECTIVE DECISION != OBSERVED RUNTIME
    eval "$(nftban_module_report_modes ddos)"; printf '%s\n' "${NFTBAN_REPORT_EFFECTIVE_MODE}"
}

# Check if Suricata is available (wrapper)
nftban_ddos_suricata_available() {
    _nftban_ddos_load_config

    if type -t nftban_ddos_suricata_is_available &>/dev/null; then
        nftban_ddos_suricata_is_available
        return $?
    fi

    return 1
}

# =============================================================================
# PUBLIC API - ENABLE
# =============================================================================

# -----------------------------------------------------------------------------
# nftban_ddos_reconcile -- THE TRANSACTION ROOT. v1.229.7 PR-3A.
#
# Resolves the module plan EXACTLY ONCE, then dispatches. Every root calls this:
# CLI enable/disable, daemon Start, firewall reload/rebuild. The adapters below
# are pure CONSUMERS and refuse to run without a supplied plan.
#
#   ONE operator intent · ONE mode resolution · ONE effective mode
#   ONE reconciliation path · ZERO cross-mode full-pipeline calls
#
# ⛔ inactive and unknown are DIFFERENT and must stay different:
#     inactive = a VALID resolved state   -> teardown higher tier, success
#     unknown  = an INVALID/unresolved contract state -> REFUSE ALL MUTATION
#   Letting teardown read unknown as inactive would turn malformed intent into
#   destructive cleanup. Base Layer-0 is unconditional either way.
# -----------------------------------------------------------------------------
nftban_ddos_reconcile() {
    local _plan
    # A root OPENS a transaction: clear any inherited plan first, so a nested
    # root cannot silently reuse an outer transaction's identity.
    unset NFTBAN_PLAN_TXN_ID NFTBAN_PLAN_RESOLUTION_ID NFTBAN_PLAN_MODULE
    _plan="$(nftban_module_resolve_plan ddos)" || return 1
    eval "$_plan"
    NFTBAN_PLAN_TXN_ID="$NFTBAN_PLAN_RESOLUTION_ID"
    export NFTBAN_PLAN_TXN_ID

    # Publish the plan as a TRANSIENT DERIVED OBSERVATION for cross-process
    # consumers (the Go validator cannot resolve `auto` and must not become a
    # second resolver). /run is tmpfiles-declared and does not survive reboot --
    # deliberately, because a resolution is valid for ONE transaction.
    # ⛔ DERIVED EVIDENCE, NOT DURABLE CONFIGURATION. MODE=auto stays the
    #    operator's intent; this record only says what it resolved to, and when.
    # ⛔ EMPTY BINDING MUST BE UNREPRESENTABLE.
    #
    # This block previously interpolated the generation directly into the record:
    #     printf 'NFTBAN_PLAN_BOUND_GENERATION=%s\n' "$(nftban_plan_generation_current)"
    # A command substitution that yielded nothing wrote an EMPTY field, and the
    # record was published anyway -- unbound and unusable. The validator then
    # correctly rejected it as UNKNOWN, which degraded health and made
    # `firewall rebuild` exit 1. Measured: pre-v1.229.7 rebuild rc=0 3/3;
    # v1.229.7 rebuild rc=1 5/5 on a clean package-native host, both distros.
    #
    #   AN INVALID PLAN MUST NEVER BE MADE DURABLE
    #   MERELY SO A LATER VALIDATOR CAN REJECT IT.
    #
    # The binding is now obtained and VALIDATED before any serialization. If it
    # cannot be established the publication fails and the convergence
    # transaction fails with it -- no record is written at all.
    # ⛔ Do NOT substitute a default, reuse the previous record's generation, or
    #    infer one from the environment. That would manufacture authority.
    local _gen _txn_owned="false"
    if ! declare -F nftban_plan_generation_current >/dev/null 2>&1 \
    || ! declare -F nftban_plan_txn_begin >/dev/null 2>&1; then
        echo "nftban_ddos_reconcile: plan-generation authority unavailable — refusing to publish an unbound plan." >&2
        return 4
    fi
    # ⛔ v1.229.11 LANE 6A: JOIN OR OWN — ONE COMMIT PER TRANSACTION, PERFORMED
    # BY WHOEVER OPENED IT. Inside the firewall lane this function runs as a
    # SUBPROCESS of `nftban ddos reload`, with NFTBAN_PLAN_TARGET_GENERATION
    # already exported; it joins that transaction and the LANE commits. Run
    # standalone, it owns the transaction and commits below, after runtime
    # reconciliation has actually completed.
    if [[ -z "${NFTBAN_PLAN_TARGET_GENERATION:-}" ]]; then
        # Propagate rc 7 (CONVERGENCE BUSY) rather than flattening it into the
        # generic publication failure 4 — the operator needs to know which it was.
        nftban_plan_txn_begin ddos || return $?
        _txn_owned="true"
    fi
    # ⛔ THE RECORD IS STAMPED WITH THE UNCOMMITTED TARGET, NOT THE COMMITTED
    # GENERATION. The generation file does not advance until commit, so a record
    # written for the committed generation would either violate the immutability
    # of an already-committed set or be indistinguishable from the state a
    # truncated convergence leaves behind.
    _gen="$(nftban_plan_target_generation)" || _gen=""
    if [[ -z "$_gen" || ! "$_gen" =~ ^[0-9]+$ ]]; then
        echo "nftban_ddos_reconcile: convergence target generation is '${_gen:-<empty>}' — refusing to publish an unbound plan." >&2
        if [[ "$_txn_owned" == "true" ]]; then nftban_plan_txn_abort; fi
        return 4
    fi

    # ⛔ A REQUIRED PUBLICATION MAY NOT BE GUARDED BY AN OPTIONAL EXISTENCE CHECK.
    # The old `if [[ -d ... ]]` had no else, so a missing runtime directory was a
    # silent no-op. Creating the directory we own is not inventing a plan; the
    # root still resolves, this only makes the resolved decision observable.
    local _dir="${NFTBAN_PLAN_RECORD_DIR:-/run/nftban}"
    # ⛔ DO NOT create the canonical runtime directory here. /run/nftban is owned
    # by systemd-tmpfiles (see /usr/lib/tmpfiles.d/nftban.conf) and must carry
    # its declared ownership: the daemon's socket lives there. An earlier
    # revision used `mkdir -p`, which recreated it as ROOT and produced
    #   "unsafe path transition /run/nftban (owned by nftban) -> (owned by root)"
    # A publisher silently taking ownership of another authority's directory is
    # the same defect class this lane removes, one level down.
    #   ESTABLISHING A PREREQUISITE != SEIZING ANOTHER AUTHORITY'S RESOURCE.
    # A missing runtime directory is an ANOMALY the operator must see, not
    # something to paper over: fail the transaction and say why.
    # (A caller-supplied NFTBAN_PLAN_RECORD_DIR — lab/test isolation — is the
    # caller's own directory and is created by the caller.)
    if [[ ! -d "$_dir" ]]; then
        echo "nftban_ddos_reconcile: runtime directory $_dir is absent — refusing to publish." >&2
        echo "                        it is owned by systemd-tmpfiles; restore it with:" >&2
        echo "                        systemd-tmpfiles --create /usr/lib/tmpfiles.d/nftban.conf" >&2
        return 4
    fi

    # v1.229.11 lane 6A: records are addressed BY GENERATION and are IMMUTABLE
    # once their generation commits. The generation file is the sole selector.
    local _pf _tmp
    _pf="$(nftban_plan_record_path ddos "$_gen")"
    _tmp="${_pf}.tmp.$$"
    if ! {
            printf 'NFTBAN_PLAN_MODULE=%s\n'           "$NFTBAN_PLAN_MODULE"
            printf 'NFTBAN_PLAN_ENABLED=%s\n'          "$NFTBAN_PLAN_ENABLED"
            printf 'NFTBAN_PLAN_CONFIGURED_MODE=%s\n'  "$NFTBAN_PLAN_CONFIGURED_MODE"
            printf 'NFTBAN_PLAN_EFFECTIVE_MODE=%s\n'   "$NFTBAN_PLAN_EFFECTIVE_MODE"
            printf 'NFTBAN_PLAN_RESOLUTION_ID=%s\n'    "$NFTBAN_PLAN_RESOLUTION_ID"
            printf 'NFTBAN_PLAN_RESOLVED_AT=%s\n'      "$NFTBAN_PLAN_RESOLVED_AT"
            printf 'NFTBAN_PLAN_RESOLUTION_BASIS=%s\n' "$NFTBAN_PLAN_RESOLUTION_BASIS"
            printf 'NFTBAN_PLAN_BOUND_GENERATION=%s\n' "$_gen"
        } > "$_tmp" 2>/dev/null; then
        rm -f "$_tmp"
        echo "nftban_ddos_reconcile: failed to write the plan record — refusing to publish a partial one." >&2
        if [[ "$_txn_owned" == "true" ]]; then nftban_plan_txn_abort; fi
        return 4
    fi
    chmod 0640 "$_tmp" 2>/dev/null || true
    if ! mv -f "$_tmp" "$_pf" 2>/dev/null; then
        rm -f "$_tmp"
        echo "nftban_ddos_reconcile: atomic publication failed." >&2
        if [[ "$_txn_owned" == "true" ]]; then nftban_plan_txn_abort; fi
        return 4
    fi
    export NFTBAN_PLAN_MODULE NFTBAN_PLAN_ENABLED NFTBAN_PLAN_CONFIGURED_MODE \
           NFTBAN_PLAN_EFFECTIVE_MODE NFTBAN_PLAN_RESOLUTION_ID \
           NFTBAN_PLAN_RESOLVED_AT NFTBAN_PLAN_RESOLUTION_BASIS

    # ⛔ v1.229.11 LANE 6A: RUNTIME RECONCILIATION HAPPENS BEFORE THE COMMIT.
    # The generation becomes authoritative ONLY after the work it describes has
    # completed successfully.
    #     IF convergence-generation=N, THE TRANSACTION FOR N COMPLETED.
    local _rc=0
    case "$NFTBAN_PLAN_EFFECTIVE_MODE" in
        unknown)
            echo "  ERROR: effective mode is UNKNOWN (${NFTBAN_PLAN_RESOLUTION_BASIS:-no basis})." >&2
            echo "         Refusing ALL higher-tier DDoS mutation — apply AND teardown." >&2
            echo "         Base Layer-0 protection is unaffected." >&2
            _rc=1
            ;;
        inactive)
            nftban_ddos_teardown || _rc=$?
            ;;
        classic|suricata)
            nftban_ddos_apply || _rc=$?
            ;;
        *)
            echo "  ERROR: unhandled effective mode '${NFTBAN_PLAN_EFFECTIVE_MODE}'." >&2
            _rc=1
            ;;
    esac

    if [[ "$_txn_owned" == "true" ]]; then
        if (( _rc == 0 )); then
            # THE ONLY PLACE THIS PATH ADVANCES THE GENERATION.
            nftban_plan_txn_commit || _rc=$?
        else
            # ⛔ FAILURE BEFORE COMMIT: generation stays N, N remains fully
            # readable, the staged N+1 set is discarded. NOTHING is rolled back,
            # because nothing inconsistent was ever made authoritative.
            nftban_plan_txn_abort
        fi
    fi
    return "$_rc"
}

# -----------------------------------------------------------------------------
# _nftban_ddos_remove_other_projection <mode-being-applied>
#
# v1.229.7 PR-3B. Removes the OPPOSITE mode's projection so the rendered state
# matches the plan and nothing else. Best-effort by design: a host that never ran
# the other mode has nothing to remove, and that is not a failure.
#
# ⛔ Scoped to higher-tier DDoS objects only. Base Layer-0 is never touched.
# ⛔ This is projection hygiene, NOT a mode decision: it acts on the mode it was
#    given and never inspects live state to choose one.
# -----------------------------------------------------------------------------
_nftban_ddos_remove_other_projection() {
    local other target_mode
    case "${1:-}" in
        classic)  other="nftban_ddos_suricata_disable"; target_mode="suricata" ;;
        suricata) other="nftban_ddos_classic_disable";  target_mode="classic"  ;;
        *)        return 0 ;;
    esac
    # ⛔ NO SILENT NO-OP. The earlier shape was `if type -t <fn>; then <fn>; fi`
    # with no else, so a MISSING entrypoint made exclusivity vanish at rc0 --
    # both projections could then coexist while this function reported success.
    # That is the exact defect the mode-authority SILENT_NO_OP check exists to
    # catch, and it caught this one.
    #   SELECTED MODE + MISSING ENTRYPOINT MUST NEVER BE rc0.
    # Refusing is the only honest outcome: returning 0 would claim a
    # mode-exclusive projection this function did not establish.
    if ! type -t "$other" &>/dev/null; then
        echo "  ERROR: $other is unavailable — cannot establish that the other mode's projection is absent." >&2
        _nftban_ddos_log "ERROR" "exclusivity unestablished: $other missing"
        return 1
    fi
    # The teardown itself is best-effort: a host that never ran the other mode
    # has nothing to remove, and that is not a failure.
    "$other" >/dev/null 2>&1 || true

    # ⛔ FLUSHED != ABSENT.
    # The disable entrypoints above have FLUSH semantics by design -- every
    # cleanup fragment emits `flush chain`, documented as "removes all rules but
    # keeps chain for reference safety", because a chain that is still jumped to
    # cannot be deleted. That is defensible for the operator-facing
    # `nftban ddos disable`, and it is NOT sufficient here: this function's whole
    # contract is that the OTHER mode's projection is ABSENT.
    #
    # WITNESSED on merged .7 main (e2555b65), lab2/DEB + lab4/RPM, via the exact
    # operator path `nftban ddos reload` across classic -> suricata:
    #     plan effective = suricata
    #     ddos_protection/ddos_sanity/ddos_prefix = PRESENT, rules=0,
    #     still jumped from base input in BOTH families
    #     nftban-validate: Status DEGRADED,
    #       VAL-CHAIN-004 "Helper chain exists but has no rules (no-op jump target)" x6
    # The product's own validator calls this state degraded, so leaving it is a
    # convergence-contract violation, not a matter of taste.
    #
    # ⛔ A REBUILD PASS DOES NOT PROVE A TRANSITION-SPECIFIC TEARDOWN PATH.
    # `firewall rebuild` passed every matrix row here only because it recreates
    # the table from scratch and therefore never creates the opposite mode's
    # objects -- it never exercised cross-mode teardown at all. Only the reload
    # root does.
    #
    # This helper owns the transition ordering, so it can safely be stronger than
    # the shared disable entrypoints without changing their semantics for other
    # callers.
    _nftban_ddos_purge_projection "$target_mode" || return 1
    return 0
}

# -----------------------------------------------------------------------------
# _nftban_ddos_purge_projection <mode-whose-projection-must-become-absent>
#
# Structural removal of ONE mode's nft objects, in both families, in the only
# order the kernel permits:
#     1. remove inbound jump edges   (a referenced chain cannot be deleted)
#     2. delete the now-unreferenced chains
#     3. delete that mode's sets     (freed once the chains referencing them go)
#
# ⛔ THE INVENTORY IS DERIVED FROM THE LIVE TABLE, NOT HARDCODED.
# A static name list here would be a SECOND inventory authority next to the
# fragment renderers, and would silently miss any object a renderer later adds --
# residue that no test names is exactly the failure this function exists to stop.
# Suricata owns exactly one object, so classic-owned is expressible as "every
# ddos_* object that is not suricata-owned" and stays correct as classic grows.
#   OBSERVED INVENTORY (converged, lab2/DEB + lab4/RPM, 2026-08-24)
#     classic  : chains ddos_sanity ddos_prefix ddos_protection ddos_penalty
#                sets   ddos_prefix_syn ddos_prefix_conn ddos_dns_udp
#                       ddos_icmp_flood ddos_udp_flood ddos_limit_10s
#                       ddos_limit_5m ddos_drop_5m ddos_ban_1h   (ip6: +"6")
#     suricata : set    ddos_blocked
# -----------------------------------------------------------------------------
# ⛔ ddos_blocked is SHARED, NOT suricata-exclusive.
# classic declares it (DDOS_CLASSIC_BLOCK_SET) and suricata writes to the same
# set; a freshly built classic host simply has not created it yet, which made an
# early measurement look like "suricata-only". The product's own validator
# settles it: on an UNPATCHED control host, `suricata -> classic` reload ends
# with ddos_blocked PRESENT and Status: PROTECTED -- so its presence in classic
# mode is not drift, and cross-mode teardown must never remove it. Deleting it
# aborted the entire classic apply and left the host DEGRADED with no
# higher-tier projection at all.
#   SHARED OBJECT != OTHER MODE'S PROJECTION
_NFTBAN_DDOS_SHARED_SETS="ddos_blocked"

_nftban_ddos_purge_projection() {
    local mode="${1:-}" fam name kind residue=""

    # ⛔ THE EXCLUSIVITY IS ONE-DIRECTIONAL, BECAUSE THE SUBSTRATE IS ASYMMETRIC.
    # Suricata mode's entire nft footprint is the SHARED ban set, so there is no
    # suricata-exclusive object for classic to displace: purging "the suricata
    # projection" is a no-op by construction, not an unimplemented case.
    # Asserting a removal here would mean deleting the shared set.
    #   SAME MODE CONTRACT != SAME KERNEL OBJECT SHAPE
    # The observable contract still holds in both directions and is proven at
    # runtime: entering classic yields the classic projection, entering suricata
    # yields no classic residue.
    if [[ "$mode" == suricata ]]; then
        return 0
    fi

    for fam in ip ip6; do
        # Base Layer-0 lives in `input`/`forward` and never matches ddos_*, so
        # base protection cannot be removed here: ALWAYS_ON_BASE_PROTECTION.
        # ⛔ PIN IFS. Sourcing the product leaves a non-default IFS in scope, so a
        # bare `read -r kind name` put the WHOLE line into $kind and left $name
        # empty -- every object then tripped the emptiness guard and was skipped,
        # so the purge deleted nothing AND reported no residue, at rc=0. A silent
        # no-op wearing a success code is the exact defect class this lane exists
        # to remove, and it reappeared inside the fix for it.
        #   INHERITED IFS IS PART OF THE CALLER'S STATE, NOT A CONSTANT.
        while IFS=' ' read -r kind name; do
            [[ -z "$kind" || -z "$name" ]] && continue
            # Everything ddos_* EXCEPT the shared ban set is classic-owned.
            [[ " $_NFTBAN_DDOS_SHARED_SETS " == *" $name "* ]] && continue
            # ⛔ WRITES GO THROUGH THE SANCTIONED WRITER, NOT FROM HERE.
            # nft_fragment_delete_object owns jump removal + deletion order and
            # lives in the fragment authority, which the nft write policy
            # permits. Writing nft directly from this module would have required
            # adding it to the policy allowlist -- silencing the check rather
            # than satisfying it.
            #   AN ALLOWLIST ENTRY IS NOT A COMPLIANCE ARGUMENT.
            # A missing writer is a hard failure: claiming exclusivity we cannot
            # establish is the silent-no-op this lane exists to remove.
            if ! declare -F nft_fragment_delete_object >/dev/null 2>&1; then
                echo "  ERROR: nft_fragment_delete_object unavailable — cannot establish mode-exclusive projection." >&2
                return 1
            fi
            nft_fragment_delete_object "$fam" "$kind" "$name" || true
        done < <(_nftban_ddos_live_objects "$fam")
    done

    # ⛔ VERIFY, DO NOT ASSUME. Best-effort deletes above are individually
    # tolerant, so absence must be asserted afterwards or a stray reference would
    # leave residue at rc0 -- the same silent-no-op class this lane removes.
    for fam in ip ip6; do
        while IFS=' ' read -r kind name; do   # IFS pinned: see note above
            [[ -z "$name" ]] && continue
            [[ " $_NFTBAN_DDOS_SHARED_SETS " == *" $name "* ]] && continue
            residue="$residue $fam/$kind/$name"
        done < <(_nftban_ddos_live_objects "$fam")
    done

    if [[ -n "$residue" ]]; then
        echo "  ERROR: the ${mode} projection is still present after teardown:${residue}" >&2
        echo "         refusing to claim mode-exclusive projection." >&2
        _nftban_ddos_log "ERROR" "exclusivity unestablished: residue${residue}"
        return 1
    fi
    return 0
}

# Enumerate live higher-tier DDoS objects in one family: "<kind> <name>" lines.
# Text output of `nft list table` is used deliberately: it needs no JSON parser
# in this layer, and an unreadable/absent table yields NOTHING, which the callers
# treat as "nothing to remove" -- never as a silent success for objects that do
# exist. ABSENT_QUERY != RESOURCE_ABSENT is handled by the verify pass above,
# which re-reads the same way and would still see any object that survived.
_nftban_ddos_live_objects() {
    local fam="${1:-ip}"
    nft list table "$fam" nftban 2>/dev/null | awk '
        /^[[:space:]]*chain[[:space:]]+ddos_/ { print "chain " $2 }
        /^[[:space:]]*set[[:space:]]+ddos_/   { print "set "   $2 }
    '
}

nftban_ddos_apply() {
    _nftban_ddos_load_config
    _nftban_ddos_banner

    # Create log file if it doesn't exist
    if [[ ! -f "$NFTBAN_DDOS_LOG_FILE" ]]; then
        mkdir -p "$(dirname "$NFTBAN_DDOS_LOG_FILE")" 2>/dev/null || true
        touch "$NFTBAN_DDOS_LOG_FILE" 2>/dev/null || true
        chmod 640 "$NFTBAN_DDOS_LOG_FILE" 2>/dev/null || true
        chown nftban:nftban "$NFTBAN_DDOS_LOG_FILE" 2>/dev/null || true
    fi

    # Detect mode
    # v1.229.7 PR-3A: CONSUME THE PLAN. Do NOT rediscover the mode from disk.
    # A plan supplied by the caller (NFTBAN_PLAN_*) is the transaction's single
    # resolution; only when none is supplied is this the transaction boundary
    # and we resolve here, exactly once.
    #   ONE RESOLVER IMPLEMENTATION != ONE RESOLUTION PER TRANSACTION
    local mode
    if [[ "${NFTBAN_PLAN_MODULE:-}" == "ddos" && -n "${NFTBAN_PLAN_EFFECTIVE_MODE:-}" ]]; then
        # ⛔ PLAN-N2: the plan must belong to THIS transaction. Missing and mixed
        # provenance are different failures and both refuse.
        nftban_module_plan_provenance_ok ddos || {
            echo "  ERROR: plan provenance check failed — refusing to apply." >&2
            return 1
        }
        mode="$NFTBAN_PLAN_EFFECTIVE_MODE"
        _nftban_ddos_log "INFO" "consuming plan ${NFTBAN_PLAN_RESOLUTION_ID:-<no-id>} (${NFTBAN_PLAN_RESOLUTION_BASIS:-})"
    else
        # ⛔ NO PLAN AT A CONSUMER = CONTRACT FAILURE.
        # This deliberately does NOT fall back to resolving one. A downstream
        # helper that resolves "when convenient" is how "resolve once" degrades
        # back into "resolve wherever" -- and it would make PLAN-N1 bypassable,
        # because a forgotten plan parameter would silently mint a second
        # authority instead of failing.
        #   TRANSACTION ROOT   may resolve exactly once
        #   DOWNSTREAM CONSUMER must RECEIVE the plan
        echo "  ERROR: no resolved module plan supplied — refusing to apply." >&2
        echo "         Call nftban_ddos_reconcile (the transaction root) instead." >&2
        _nftban_ddos_log "ERROR" "refusing apply: no plan supplied (consumer must receive a plan)"
        return 1
    fi

    # ⛔ UNKNOWN stops the higher-tier transaction. It must NOT fall back to
    # classic or suricata, must NOT tear down as if disabled, and must NOT
    # fabricate a new plan. Base Layer-0 is unconditional, so this is
    # fail-closed at the HIGHER TIER, never a whole-firewall failure.
    if [[ "$mode" == "unknown" ]]; then
        echo "  ERROR: effective mode is UNKNOWN (${NFTBAN_PLAN_RESOLUTION_BASIS:-no basis}) — refusing to apply higher-tier DDoS." >&2
        echo "         Base Layer-0 protection is unaffected." >&2
        _nftban_ddos_log "ERROR" "refusing apply: effective_mode=unknown basis=${NFTBAN_PLAN_RESOLUTION_BASIS:-}"
        return 1
    fi
    # inactive = module disabled: no higher-tier apply, and not an error.
    if [[ "$mode" == "inactive" ]]; then
        _nftban_ddos_log "INFO" "module disabled — no higher-tier apply"
        return 0
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  DDoS Protection - Mode: ${mode^^}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    _nftban_ddos_log "INFO" "Enabling DDoS protection (mode=$mode)"

    # Step 1: Apply nftables rules FIRST (before persisting config)
    local enable_result=0
    # v1.229.7 PR-3B: PROJECTION IS A PURE FUNCTION OF THE PLAN.
    #
    #   RENDERER CONSUMES A DECISION. RENDERER DOES NOT MAKE A DECISION.
    #
    # Exactly two modes are projectable. `hybrid` is NOT one of them: an arm here
    # enabled classic AND suricata together, which is the CLASSIC_ACTIVE +
    # SURICATA_ACTIVE state this lane exists to remove. It is gone, and no mode
    # outside the closed set may be projected.
    # ⛔ The renderer must never REPAIR a bad plan -- it may not decide that
    #    Suricata looks available and reconstruct an answer the plan did not give.
    case "$mode" in
        classic|suricata) ;;
        # NOTE: `inactive` is handled ABOVE by the PR-3A early return (benign
        # no-op: apply projects nothing; the reconcile root routes inactive to
        # teardown, which owns removal). Deliberately NOT repeated here -- two
        # contradictory statements about one condition is worse than either.
        *)
            echo "  ERROR: effective_mode='${mode}' is not projectable (expected classic|suricata)." >&2
            _nftban_ddos_log "ERROR" "refusing apply: non-projectable effective_mode=${mode}"
            return 1
            ;;
    esac

    # ⛔ EXCLUSIVITY IS PART OF THE PROJECTION, NOT A SIDE EFFECT OF IT.
    # Entering a mode did not previously remove the other mode's objects, so a
    # plan switch left BOTH pipelines live -- exactly the drift the validator
    # reports as `unexpected_objects_present`. Removing the opposite projection
    # first is what makes the plan, and only the plan, decide what is rendered.
    #   PLAN DIFFERENCE MUST CONTROL MODE-SPECIFIC PROJECTION.
    # Base Layer-0 is untouched by both arms: ALWAYS_ON_BASE_PROTECTION.
    _nftban_ddos_remove_other_projection "$mode" || return 1

    case "$mode" in
        classic)
            echo ""
            echo "  Using CLASSIC mode (native nftables)"
            echo ""
            if type -t nftban_ddos_classic_enable &>/dev/null; then
                nftban_ddos_classic_enable || enable_result=$?
            else
                echo "  ERROR: Classic module not loaded!" >&2
                return 1
            fi
            ;;

        suricata)
            echo ""
            echo "  Using SURICATA mode (IDS-integrated)"
            if type -t nftban_ddos_suricata_get_status &>/dev/null; then
                echo "  Status: $(nftban_ddos_suricata_get_status)"
            fi
            echo ""
            if type -t nftban_ddos_suricata_enable &>/dev/null; then
                nftban_ddos_suricata_enable || enable_result=$?
            else
                echo "  ERROR: Suricata module not loaded!" >&2
                return 1
            fi
            ;;
    esac

    # Step 2: Verify nft rules were actually applied
    if [[ $enable_result -ne 0 ]]; then
        echo ""
        echo "  ❌ ERROR: Failed to apply nftables rules!" >&2
        echo "  Check: is nftband daemon running? (systemctl status nftband)" >&2
        _nftban_ddos_log "ERROR" "Failed to apply nftables rules (exit=$enable_result)"
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# nftban_ddos_enable -- OPERATOR ORCHESTRATION. CLI-ONLY.
# v1.229.7 PR-2: persists intent, calls the neutral apply, then performs the
# service lifecycle action. NOT daemon-callable.
# -----------------------------------------------------------------------------
nftban_ddos_enable() {
    _nftban_ddos_load_config
    nftban_ddos_reconcile || return 1

    # v1.229.7 PR-2a: `mode` is local to nftban_ddos_apply, so the success
    # banner below referenced an UNBOUND variable. Under `set -Eeuo pipefail`
    # (:41) that is fatal -- the command aborted AFTER persisting intent and
    # AFTER restarting nftband, returning non-zero to its caller.
    # ⛔ v1.229.7 PR-3B: REPORT WHAT THE TRANSACTION DID, NOT A FRESH GUESS.
    # This called the local detector purely to label the success banner, so the
    # operator could be told "SURICATA" while the transaction had actually
    # applied CLASSIC (or the reverse) whenever availability changed between the
    # two independent resolutions. Only the plan the root published is entitled
    # to answer "which mode did we just enable?".
    #   A REPORT MUST DESCRIBE THE ACTION THAT HAPPENED.
    local mode="${NFTBAN_PLAN_EFFECTIVE_MODE:-unknown}"

    # Step 3: Persist DDOS_ENABLED=true ONLY after nft rules succeed.
    # v1.229.7 PR-2: routed through the SINGLE durable-intent writer.
    nftban_module_set_enabled ddos true || return 1
    DDOS_ENABLED="true"

    # Step 4: Auto-restart nftband to activate immediately
    if systemctl is-active nftband &>/dev/null; then
        echo "  Restarting nftband daemon..."
        if systemctl restart nftband 2>/dev/null; then
            echo "  ✅ Daemon restarted — DDoS protection is now active"
        else
            echo "  ⚠️  Daemon restart failed — run: systemctl restart nftband" >&2
        fi
    else
        echo "  ⚠️  nftband not running — start with: systemctl start nftband"
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✅ DDoS Protection ENABLED (${mode^^})"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    return 0
}

# =============================================================================
# PUBLIC API - DISABLE
# =============================================================================

# -----------------------------------------------------------------------------
# nftban_ddos_teardown -- NEUTRAL RUNTIME TEARDOWN. Daemon-callable.
# v1.229.7 PR-2: removes runtime enforcement ONLY. Writes no config and
# restarts no service. Stopping a service must not turn a module off durably.
# -----------------------------------------------------------------------------
nftban_ddos_teardown() {
    _nftban_ddos_load_config
    _nftban_ddos_banner

    # v1.229.7 PR-3B: the mode detection here was DEAD -- its result was never
    # read, and teardown removes BOTH pipelines unconditionally (correct:
    # teardown is mode-independent). Removing it also removes a second-authority
    # invocation from a mutation path.

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Disabling DDoS Protection..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    _nftban_ddos_log "INFO" "Disabling DDoS protection"

    # Disable both modes to ensure clean state
    if type -t nftban_ddos_classic_disable &>/dev/null; then
        nftban_ddos_classic_disable 2>/dev/null || true
    fi

    if type -t nftban_ddos_suricata_disable &>/dev/null; then
        nftban_ddos_suricata_disable 2>/dev/null || true
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✅ DDoS Protection DISABLED                             ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    return 0
}

# -----------------------------------------------------------------------------
# nftban_ddos_disable -- OPERATOR ORCHESTRATION. CLI-ONLY.
# v1.229.7 PR-2: persists intent, then tears down runtime. NOT daemon-callable.
# -----------------------------------------------------------------------------
nftban_ddos_disable() {
    _nftban_ddos_load_config
    nftban_module_set_enabled ddos false || return 1
    DDOS_ENABLED="false"
    nftban_ddos_reconcile
}

# =============================================================================
# PUBLIC API - STATUS
# =============================================================================

# v1.141 PR-B (J-DDOS) — JSON renderer for `nftban ddos status --json`.
# Built with jq -n (no string concatenation) so output is valid JSON even
# when any field carries quotes / unicode / shell-special chars. Fields
# match the text-mode status section labels exactly.
_nftban_ddos_status_json() {
    local mode="${1:-unknown}"
    local configured_mode="${2:-auto}"

    # Suricata sub-status — best-effort, never block JSON emission.
    local suricata_binary="unknown" suricata_service="unknown"
    local suricata_eve="unknown" suricata_available="unknown"
    local suricata_version=""
    if type -t nftban_ddos_suricata_binary_exists &>/dev/null; then
        if nftban_ddos_suricata_binary_exists; then
            suricata_binary="present"
            suricata_version=$(suricata -V 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' || true)
        else
            suricata_binary="absent"
        fi
    fi
    if type -t nftban_ddos_suricata_service_running &>/dev/null; then
        if nftban_ddos_suricata_service_running; then suricata_service="running"; else suricata_service="stopped"; fi
    fi
    if type -t nftban_ddos_suricata_eve_active &>/dev/null; then
        if nftban_ddos_suricata_eve_active; then suricata_eve="active"; else suricata_eve="stale"; fi
    fi
    if type -t nftban_ddos_suricata_is_available &>/dev/null; then
        if nftban_ddos_suricata_is_available; then suricata_available="available"; else suricata_available="unavailable"; fi
    fi

    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg enabled    "${DDOS_ENABLED:-false}" \
            --arg cfg_mode   "$configured_mode" \
            --arg act_mode   "$mode" \
            --arg s_bin      "$suricata_binary" \
            --arg s_ver      "$suricata_version" \
            --arg s_svc      "$suricata_service" \
            --arg s_eve      "$suricata_eve" \
            --arg s_avail    "$suricata_available" \
            '{
                module: "ddos",
                enabled: ($enabled == "true" or $enabled == "1"),
                configured_mode: $cfg_mode,
                active_mode: $act_mode,
                suricata: {
                    binary: $s_bin,
                    version: (if $s_ver == "" then null else $s_ver end),
                    service: $s_svc,
                    eve_log: $s_eve,
                    available: $s_avail
                }
            }'
        return $?
    fi
    # jq absent — emit a minimal hand-built object (still valid JSON; safe
    # because every value is a known constrained string from above).
    printf '{"module":"ddos","enabled":%s,"configured_mode":"%s","active_mode":"%s","suricata":{"binary":"%s","service":"%s","eve_log":"%s","available":"%s","jq_unavailable":true}}\n' \
        "$([[ "${DDOS_ENABLED:-false}" == "true" ]] && echo true || echo false)" \
        "$configured_mode" "$mode" "$suricata_binary" "$suricata_service" "$suricata_eve" "$suricata_available"
}

# v1.141 PR-B (J-DDOS): function now takes optional json_mode arg.
# shellcheck disable=SC2120
# (Internal callers may invoke without args; `${1:-false}` default handles
# that. SC2120 over-fires on optional args.)
nftban_ddos_status() {
    # v1.141 PR-B (J-DDOS): json_mode-aware status. When called with
    # json_mode="true", short-circuit ALL decorative chrome (banner +
    # ━━━ heading bars + text body) and emit a single valid JSON object
    # constructed via jq -n (no string concatenation). Pre-v1.141 this
    # function had no json_mode parameter; the dispatcher arm at
    # cmd_ddos.sh:384 called it bare, producing banner + text on
    # `nftban ddos status --json` (cruel-judge §3 E_J6).
    local json_mode="${1:-false}"

    _nftban_ddos_load_config

    local mode
    # ⛔ v1.229.7 PR-4 READ-PATH MODE CONTRACT. This used the local detector,
    # which resolves `auto` by probing Suricata availability -- a second,
    # independent authority that could report a mode the system had not decided.
    #   STATUS MUST NOT RESOLVE AUTO.
    #   CONFIGURED INTENT != EFFECTIVE DECISION != OBSERVED RUNTIME
    eval "$(nftban_module_report_modes ddos)"
    mode="${NFTBAN_REPORT_EFFECTIVE_MODE}"
    local configured_mode="${DDOS_MODE:-auto}"

    if [[ "$json_mode" == "true" ]]; then
        _nftban_ddos_status_json "$mode" "$configured_mode"
        return $?
    fi

    _nftban_ddos_banner

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  DDoS Protection Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Module Enabled:    ${DDOS_ENABLED}"
    echo "  Configured Mode:   ${configured_mode}"
    echo "  Active Mode:       ${mode}"
    echo ""

    # Suricata availability
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Suricata Detection"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if type -t nftban_ddos_suricata_binary_exists &>/dev/null; then
        if nftban_ddos_suricata_binary_exists; then
            local version
            version=$(suricata -V 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' || echo "?")
            echo "  Binary:    ✅ FOUND (v$version)"
        else
            echo "  Binary:    ❌ NOT FOUND"
        fi
    else
        echo "  Binary:    ⚠️  Check unavailable"
    fi

    if type -t nftban_ddos_suricata_service_running &>/dev/null; then
        if nftban_ddos_suricata_service_running; then
            echo "  Service:   ✅ RUNNING"
        else
            echo "  Service:   ❌ STOPPED"
        fi
    else
        echo "  Service:   ⚠️  Check unavailable"
    fi

    if type -t nftban_ddos_suricata_eve_active &>/dev/null; then
        local eve_file="${DDOS_SURICATA_EVE_FILE:-/var/log/nftban/suricata/eve-alerts.json}"
        if [[ -f "$eve_file" ]]; then
            if nftban_ddos_suricata_eve_active; then
                local size
                size=$(du -h "$eve_file" 2>/dev/null | cut -f1)
                echo "  EVE Log:   ✅ ACTIVE ($size)"
            else
                echo "  EVE Log:   ⚠️  STALE (not updated recently)"
            fi
        else
            echo "  EVE Log:   ❌ NOT FOUND ($eve_file)"
        fi
    fi

    if type -t nftban_ddos_suricata_is_available &>/dev/null; then
        echo ""
        if nftban_ddos_suricata_is_available; then
            echo "  Suricata:  ✅ AVAILABLE (ready for use)"
        else
            echo "  Suricata:  ❌ NOT AVAILABLE"
            # Explain WHY it's not available (same pattern as portscan)
            if ! type -t nftban_ddos_suricata_binary_exists &>/dev/null || ! nftban_ddos_suricata_binary_exists; then
                echo "  Reason:    Binary not installed"
                echo "  Fix:       apt install suricata / dnf install suricata"
            elif ! type -t nftban_ddos_suricata_service_running &>/dev/null || ! nftban_ddos_suricata_service_running; then
                echo "  Reason:    Service not running"
                echo "  Fix:       systemctl start suricata"
            else
                # Binary + service OK → EVE log must be the issue
                # Support Suricata 7.x threaded logging: check all eve-alerts*.json files
                local diag_eve_dir="${NFTBAN_LOG_DIR:-/var/log/nftban}/suricata"
                local diag_freshest_mtime=0

                shopt -s nullglob
                for f in "$diag_eve_dir"/eve-alerts*.json; do
                    [[ -f "$f" ]] || continue
                    local m
                    m=$(stat -L -c %Y -- "$f" 2>/dev/null) || continue
                    [[ "$m" =~ ^[0-9]+$ ]] || continue
                    (( m > diag_freshest_mtime )) && diag_freshest_mtime=$m
                done
                shopt -u nullglob

                if [[ $diag_freshest_mtime -eq 0 ]]; then
                    echo "  Reason:    EVE log not found in $diag_eve_dir"
                    echo "  Fix:       Check Suricata output config (suricata.yaml)"
                else
                    local diag_age=$(( $(date +%s) - diag_freshest_mtime ))
                    echo "  Reason:    EVE log stale (last update ${diag_age}s ago, threshold: ${DDOS_EVE_FRESHNESS_THRESHOLD:-60}s)"
                    echo "  Fix:       Check Suricata is processing traffic: suricata --build-info"
                    echo "             Verify EVE output: grep eve-log /etc/suricata/suricata.yaml"
                fi
            fi
        fi
    fi

    echo ""

    # Show mode-specific status
    case "$mode" in
        classic)
            if type -t nftban_ddos_classic_status &>/dev/null; then
                nftban_ddos_classic_status
            fi
            ;;
        suricata|hybrid)
            if type -t nftban_ddos_suricata_status &>/dev/null; then
                nftban_ddos_suricata_status
            fi
            ;;
    esac

    # ==========================================================================
    # DETECTION MODES EXPLAINED
    # ==========================================================================
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Detection Modes"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  classic   - Uses nftables rate limiting and connection tracking"
    echo "              Good for basic protection without external dependencies"
    echo ""
    echo "  suricata  - Uses Suricata IDS for advanced threat detection"
    echo "              Better accuracy, detects complex attack patterns"
    echo ""
    echo "  hybrid    - LEGACY, NOT SUPPORTED: resolves to unknown and refuses."
    echo "              Running both pipelines at once is an invalid state."
    echo "              Set an explicit mode to migrate."
    echo "              Maximum protection with redundant detection layers"
    echo ""
    echo "  auto      - Auto-selects based on Suricata availability"
    echo "              Uses suricata if available, otherwise classic"
    echo ""

    # ==========================================================================
    # CONFIGURATION
    # ==========================================================================
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Configuration"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Config File:  /etc/nftban/conf.d/ddos/main.conf"
    local local_file="/etc/nftban/conf.d/ddos/main.conf.local"
    if [[ -f "$local_file" ]]; then
        echo "  Override File:  $local_file  [Active]"
    else
        echo "  Override File:  $local_file  [Not created]"
    fi
    echo "  Log File:     ${NFTBAN_DDOS_LOG_FILE}"
    echo ""
    echo "  Key Settings:"
    echo "    DDOS_ENABLED=true|false     - Enable/disable DDoS protection"
    echo "    DDOS_MODE=auto|classic|suricata   (hybrid = legacy, refuses)"
    echo "    DDOS_SYN_RATE=25            - SYN packets per second limit"
    echo "    DDOS_CONN_LIMIT=100         - Max connections per IP"
    echo ""
    echo "  Note: Put custom settings in main.conf.local (survives upgrades)"
    echo ""

    # ==========================================================================
    # COMMANDS
    # ==========================================================================
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Commands"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  nftban ddos enable            - Enable DDoS protection"
    echo "  nftban ddos disable           - Disable DDoS protection"
    echo "  nftban ddos test              - Test protection rules"
    echo "  nftban ddos help              - Show all available commands"
    echo ""

    return 0
}

# =============================================================================
# PUBLIC API - TEST (For scripting/automation)
# =============================================================================

nftban_ddos_test() {
    _nftban_ddos_load_config

    local mode
    # ⛔ v1.229.7 PR-4 READ-PATH MODE CONTRACT. This used the local detector,
    # which resolves `auto` by probing Suricata availability -- a second,
    # independent authority that could report a mode the system had not decided.
    #   STATUS MUST NOT RESOLVE AUTO.
    #   CONFIGURED INTENT != EFFECTIVE DECISION != OBSERVED RUNTIME
    eval "$(nftban_module_report_modes ddos)"
    mode="${NFTBAN_REPORT_EFFECTIVE_MODE}"

    echo "mode=$mode"
    echo "enabled=$DDOS_ENABLED"
    echo "configured_mode=$DDOS_MODE"

    if type -t nftban_ddos_suricata_is_available &>/dev/null; then
        if nftban_ddos_suricata_is_available; then
            echo "suricata_available=true"
        else
            echo "suricata_available=false"
        fi
    else
        echo "suricata_available=unknown"
    fi

    return 0
}

# =============================================================================
# CLI DISPATCHER (for direct script execution)
# =============================================================================

_nftban_ddos_cli() {
    local cmd="${1:-status}"
    shift || true

    case "$cmd" in
        enable)
            nftban_ddos_enable "$@"
            ;;
        disable)
            nftban_ddos_disable "$@"
            ;;
        status)
            nftban_ddos_status "$@"
            ;;
        test)
            nftban_ddos_test "$@"
            ;;
        mode)
            nftban_ddos_get_mode
            ;;
        help|--help|-h)
            echo "Usage: nftban ddos <command>"
            echo ""
            echo "Commands:"
            echo "  enable     Enable DDoS protection (auto-detects mode)"
            echo "  disable    Disable DDoS protection"
            echo "  status     Show current status"
            echo "  mode       Show active mode (classic/suricata)"
            echo "  test       Output status in key=value format"
            echo ""
            echo "Modes:"
            echo "  auto       Auto-detect (use Suricata if available, else Classic)"
            echo "  classic    Force Classic mode (nftables-only)"
            echo "  suricata   Force Suricata mode (requires Suricata)"
            echo "  hybrid     LEGACY — refuses; migrate to an explicit mode"
            echo ""
            echo "Configuration:"
            echo "  ${NFTBAN_DDOS_CONFIG_DIR}/conf.d/ddos/main.conf"
            echo "  ${NFTBAN_DDOS_CONFIG_DIR}/conf.d/ddos/classic.conf"
            echo "  ${NFTBAN_DDOS_CONFIG_DIR}/conf.d/ddos/suricata.conf"
            echo ""
            ;;
        *)
            echo "Unknown command: $cmd"
            echo "Run 'nftban ddos help' for usage"
            return 1
            ;;
    esac
}

# Run CLI if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _nftban_ddos_cli "$@"
fi

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_ddos_enable
export -f nftban_ddos_disable
export -f nftban_ddos_status
export -f nftban_ddos_test
export -f nftban_ddos_get_mode
export -f nftban_ddos_suricata_available
