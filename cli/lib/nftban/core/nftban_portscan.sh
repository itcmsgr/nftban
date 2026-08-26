#!/usr/bin/env bash
# =============================================================================
# NFTBan - Port Scan Detection Module (Dual-Mode Controller)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="nftban_portscan"
# meta:type="core"
# meta:header="Port Scan Detection"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Dual-mode portscan detection with journalctl support"
# meta:inventory.files="/var/lib/nftban/portscan/"
# meta:inventory.binaries="nft,journalctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/portscan/main.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2026-01-11"
# =============================================================================

set -Eeuo pipefail

# v1.229.7 PR-3A: the apply/teardown halves consume a RESOLVED MODULE PLAN from
# nftban_module_resolve_plan (lib/module_authority.sh). The daemon sources this
# file standalone (`bash -c 'source "$1" && nftban_portscan_apply'`), so the authority
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

[[ -n "${NFTBAN_PORTSCAN_LOADED:-}" ]] && return 0
readonly NFTBAN_PORTSCAN_LOADED=1

# =============================================================================
# MODULE METADATA
# =============================================================================

# shellcheck disable=SC2034  # Module metadata used when sourced
readonly PORTSCAN_MODULE_NAME="nftban_portscan"
# shellcheck disable=SC2034  # Module metadata used when sourced
readonly PORTSCAN_MODULE_VERSION="1.0.0"
# shellcheck disable=SC2034  # Module metadata used when sourced
readonly PORTSCAN_MODULE_TYPE="core"
# shellcheck disable=SC2034  # Module metadata used when sourced
readonly PORTSCAN_MODULE_DESCRIPTION="Port Scan Detection Module (Dual-Mode)"

# =============================================================================
# FHS COMPLIANT PATHS
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true
# IMPL-1: ensure _source_local is defined wherever this file is loaded (env.sh idempotent)
declare -F _source_local >/dev/null 2>&1 || source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/env.sh" 2>/dev/null || true
_source_local "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local"

readonly NFTBAN_PORTSCAN_CONFIG_DIR="${NFTBAN_CONFIG_DIR}/conf.d/portscan"
readonly NFTBAN_PORTSCAN_DATA_DIR="${PORTSCAN_DATA_DIR:-${NFTBAN_DATA_DIR}/portscan}"
readonly NFTBAN_PORTSCAN_CACHE_DIR="${PORTSCAN_CACHE_DIR:-${NFTBAN_CACHE_DIR}/portscan}"
readonly NFTBAN_PORTSCAN_LOG_FILE="${PORTSCAN_LOG_FILE:-${NFTBAN_LOG_DIR}/portscan.log}"

# =============================================================================
# LOGGING
# =============================================================================

_nftban_portscan_log() {
    local level="$1"
    local message="$2"

    mkdir -p "$(dirname "$NFTBAN_PORTSCAN_LOG_FILE")" 2>/dev/null || return 1

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [PORTSCAN] [$level] $message" >> "$NFTBAN_PORTSCAN_LOG_FILE"
}

# =============================================================================
# NFTABLES CONFIGURATION
# =============================================================================

readonly NFTBAN_NFT_TABLE_IPV4="${NFTBAN_NFT_TABLE_IPV4:-ip nftban}"
readonly NFTBAN_NFT_TABLE_IPV6="${NFTBAN_NFT_TABLE_IPV6:-ip6 nftban}"
# shellcheck disable=SC2034  # Used by classic/suricata mode modules
readonly NFTBAN_NFT_PORTSCAN_CHAIN="${PORTSCAN_NFT_CHAIN:-portscan_detection}"

# =============================================================================
# RUNTIME STATE
# =============================================================================

declare -g _PORTSCAN_ACTIVE_MODE=""      # Currently active mode
declare -g _PORTSCAN_INITIALIZED=0       # Initialization flag

# =============================================================================
# BANNER FUNCTION
# =============================================================================

nftban_portscan_banner() {
    cat <<'BANNER'
╔═══════════════════════════════════════════════════════════════════════════╗
║  🔍 Port Scan Detection (v1.0 Dual-Mode)                                  ║
║  NFTBan — Open-source Linux IPS and nftables firewall manager             ║
╚═══════════════════════════════════════════════════════════════════════════╝
BANNER
}

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================

# Load main portscan configuration
nftban_portscan_load_config() {
    local config_dir="${NFTBAN_PORTSCAN_CONFIG_DIR}"

    # Load main config
    local main_config="${config_dir}/main.conf"
    local main_local="${config_dir}/main.conf.local"

    if [[ -f "$main_config" ]]; then
        # shellcheck source=/dev/null
        source "$main_config" || true
    fi

    if [[ -f "$main_local" ]]; then
        # shellcheck source=/dev/null
        _source_local "$main_local"
    fi

    # Set defaults
    : "${PORTSCAN_ENABLED:=false}"
    : "${PORTSCAN_MODE:=auto}"
    : "${PORTSCAN_AUTO_CHECK_SERVICE:=true}"
    : "${PORTSCAN_AUTO_CHECK_BINARY:=true}"
    : "${PORTSCAN_AUTO_CHECK_EVE_FILE:=true}"
    : "${PORTSCAN_SURICATA_SERVICE_NAME:=suricata}"
    : "${PORTSCAN_SURICATA_BINARY:=/usr/bin/suricata}"
    : "${PORTSCAN_EVE_FRESHNESS_THRESHOLD:=60}"

    return 0
}

# =============================================================================
# MODE DETECTION
# =============================================================================

# Check if Suricata binary exists
_nftban_portscan_suricata_binary_exists() {
    local binary="${PORTSCAN_SURICATA_BINARY:-/usr/bin/suricata}"
    [[ -x "$binary" ]]
}

# Check if Suricata service is running
_nftban_portscan_suricata_service_running() {
    local service_name="${PORTSCAN_SURICATA_SERVICE_NAME:-suricata}"

    # Try systemctl first
    if command -v systemctl &>/dev/null; then
        if systemctl is-active --quiet "$service_name" 2>/dev/null; then
            return 0
        fi
    fi

    # Fall back to pgrep
    if pgrep -x suricata &>/dev/null; then
        return 0
    fi

    return 1
}

# Check if EVE JSON file is being actively written
_nftban_portscan_suricata_eve_active() {
    local eve_file="${PORTSCAN_SURICATA_EVE_FILE:-/var/log/nftban/suricata/eve-alerts.json}"
    local freshness="${PORTSCAN_EVE_FRESHNESS_THRESHOLD:-60}"

    # Support Suricata 7.x threaded logging (writes to eve-alerts.1.json, eve-alerts.2.json, etc.)
    local eve_dir="${eve_file%/*}"
    local freshest_mtime=0

    shopt -s nullglob
    for f in "$eve_dir"/eve-alerts*.json; do
        [[ -f "$f" ]] || continue
        local m
        m=$(stat -L -c %Y -- "$f" 2>/dev/null) || continue
        (( m > freshest_mtime )) && freshest_mtime=$m
    done
    shopt -u nullglob

    [[ $freshest_mtime -eq 0 ]] && return 1
    local age=$(( $(date +%s) - freshest_mtime ))
    [[ $age -le $freshness ]]
}

# Combined Suricata availability check
_nftban_portscan_suricata_is_available() {
    local check_binary="${PORTSCAN_AUTO_CHECK_BINARY:-true}"
    local check_service="${PORTSCAN_AUTO_CHECK_SERVICE:-true}"
    local check_eve="${PORTSCAN_AUTO_CHECK_EVE_FILE:-true}"

    # Check binary
    if [[ "$check_binary" == "true" ]]; then
        if ! _nftban_portscan_suricata_binary_exists; then
            return 1
        fi
    fi

    # Check service
    if [[ "$check_service" == "true" ]]; then
        if ! _nftban_portscan_suricata_service_running; then
            return 1
        fi
    fi

    # Check EVE file
    if [[ "$check_eve" == "true" ]]; then
        if ! _nftban_portscan_suricata_eve_active; then
            return 1
        fi
    fi

    return 0
}

# Detect which mode to use
_nftban_portscan_detect_mode() {
    local configured_mode="${PORTSCAN_MODE:-auto}"

    # If not auto, use configured mode
    if [[ "$configured_mode" != "auto" ]]; then
        echo "$configured_mode"
        return 0
    fi

    # Auto-detect: check if Suricata is available
    if _nftban_portscan_suricata_is_available; then
        echo "suricata"
        return 0
    fi

    # Fall back to classic
    echo "classic"
}

# =============================================================================
# MODULE LOADING
# =============================================================================

# Source the appropriate mode modules
_nftban_portscan_load_modules() {
    local lib_dir="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
    local core_dir="${lib_dir}/core"

    # Also check for dev paths
    local dev_core_dir=""
    if [[ -d "${BASH_SOURCE[0]%/*}" ]]; then
        dev_core_dir="${BASH_SOURCE[0]%/*}"
    fi

    # Load classic module
    local classic_module=""
    for path in "${core_dir}/nftban_portscan_classic.sh" "${dev_core_dir}/nftban_portscan_classic.sh"; do
        if [[ -f "$path" ]]; then
            classic_module="$path"
            break
        fi
    done

    if [[ -n "$classic_module" ]]; then
        # shellcheck source=/dev/null
        source "$classic_module" || return 1
        # Initialize classic module config and state
        if type -t nftban_portscan_classic_load_config &>/dev/null; then
            nftban_portscan_classic_load_config
        fi
        if type -t nftban_portscan_classic_init_state &>/dev/null; then
            nftban_portscan_classic_init_state
        fi
    fi

    # Load trusted-monitoring-flow exclusion module (event-emit suppression only;
    # empty/opt-in default). Sourced alongside classic so the emit filter is
    # available in nftban_portscan_classic_process_logs.
    local tflow_module=""
    for path in "${core_dir}/nftban_portscan_trusted_flow.sh" "${dev_core_dir}/nftban_portscan_trusted_flow.sh"; do
        if [[ -f "$path" ]]; then tflow_module="$path"; break; fi
    done
    if [[ -n "$tflow_module" ]]; then
        # shellcheck source=/dev/null
        source "$tflow_module" || true
    fi

    # Load suricata module
    local suricata_module=""
    for path in "${core_dir}/nftban_portscan_suricata.sh" "${dev_core_dir}/nftban_portscan_suricata.sh"; do
        if [[ -f "$path" ]]; then
            suricata_module="$path"
            break
        fi
    done

    if [[ -n "$suricata_module" ]]; then
        # shellcheck source=/dev/null
        source "$suricata_module" || return 1
        # Initialize suricata module config and state
        if type -t nftban_portscan_suricata_load_config &>/dev/null; then
            nftban_portscan_suricata_load_config
        fi
        if type -t nftban_portscan_suricata_init_state &>/dev/null; then
            nftban_portscan_suricata_init_state
        fi
    fi

    return 0
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Initialize directory structure
nftban_portscan_init_dirs() {
    local dirs=(
        "$NFTBAN_PORTSCAN_DATA_DIR"
        "$NFTBAN_PORTSCAN_CACHE_DIR"
        "$(dirname "$NFTBAN_PORTSCAN_LOG_FILE")"
    )

    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir" 2>/dev/null || true
            chmod 750 "$dir" 2>/dev/null || true
        fi
    done

    # Create log file if it doesn't exist
    if [[ ! -f "$NFTBAN_PORTSCAN_LOG_FILE" ]]; then
        touch "$NFTBAN_PORTSCAN_LOG_FILE" 2>/dev/null || true
        chmod 640 "$NFTBAN_PORTSCAN_LOG_FILE" 2>/dev/null || true
        chown nftban:nftban "$NFTBAN_PORTSCAN_LOG_FILE" 2>/dev/null || true
    fi

    return 0
}

# Initialize portscan detection
nftban_portscan_init() {
    [[ $_PORTSCAN_INITIALIZED -eq 1 ]] && return 0

    _nftban_portscan_log "INFO" "Initializing portscan detection module"

    # Load configuration
    nftban_portscan_load_config

    # Check if enabled
    if [[ "${PORTSCAN_ENABLED:-false}" != "true" ]]; then
        _nftban_portscan_log "INFO" "Portscan detection is disabled"
        return 0
    fi

    # Initialize directories
    nftban_portscan_init_dirs

    # Load mode modules
    _nftban_portscan_load_modules

    # Detect mode
    # ⛔ v1.229.7 PR-4 READ-PATH MODE CONTRACT. This used the local detector,
    # which resolves `auto` by probing Suricata availability -- a second,
    # independent authority that could report a mode the system had not decided.
    #   STATUS MUST NOT RESOLVE AUTO.
    #   CONFIGURED INTENT != EFFECTIVE DECISION != OBSERVED RUNTIME
    eval "$(nftban_module_report_modes portscan)"
    _PORTSCAN_ACTIVE_MODE="${NFTBAN_REPORT_EFFECTIVE_MODE}"

    _nftban_portscan_log "INFO" "Portscan mode: ${_PORTSCAN_ACTIVE_MODE}"

    _PORTSCAN_INITIALIZED=1
    return 0
}

# =============================================================================
# ENABLE/DISABLE
# =============================================================================

# Enable portscan detection
# -----------------------------------------------------------------------------
# nftban_portscan_reconcile -- THE TRANSACTION ROOT. v1.229.7 PR-3A.
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
nftban_portscan_reconcile() {
    local _plan
    # ⛔ ESTABLISH THE RESOLUTION PRECONDITION BEFORE RESOLVING.
    # `auto` is decided by calling nftban_portscan_suricata_is_available. That
    # function only exists once _nftban_portscan_load_modules has sourced the
    # suricata module -- and unlike ddos (which sources its suricata module at
    # FILE scope) portscan loads its optional modules from a function that the
    # enable/apply paths call only AFTER resolution. So the resolver found no
    # predicate, recorded basis `auto_suricata_module_not_loaded`, and fell back
    # to classic every time: portscan `auto` was structurally incapable of ever
    # resolving to suricata, no matter what the environment actually offered.
    # WITNESSED on lab2/DEB and lab4/RPM 2026-08-24, both families, with the
    # canonical availability predicate observed TRUE:
    #     ddos     -> basis auto_suricata_unavailable      (predicate consulted)
    #     portscan -> basis auto_suricata_module_not_loaded (never consulted)
    #
    #   RESOLVING BEFORE THE INPUTS ARE LOADED IS NOT A RESOLUTION --
    #   IT IS A DEFAULT WEARING A RESOLUTION'''S NAME.
    #
    # Tolerant by design: if the optional module genuinely is not installed the
    # resolver still records `auto_suricata_module_not_loaded`, which is then a
    # TRUE statement about the host rather than an artefact of call ordering.
    # init_state only resets in-memory arrays and re-reads persisted state, so
    # calling the existing loader earlier adds no new system mutation.
    _nftban_portscan_load_modules || true
    # A root OPENS a transaction: clear any inherited plan first, so a nested
    # root cannot silently reuse an outer transaction's identity.
    unset NFTBAN_PLAN_TXN_ID NFTBAN_PLAN_RESOLUTION_ID NFTBAN_PLAN_MODULE
    _plan="$(nftban_module_resolve_plan portscan)" || return 1
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
        echo "nftban_portscan_reconcile: plan-generation authority unavailable — refusing to publish an unbound plan." >&2
        return 4
    fi
    # ⛔ v1.229.11 LANE 6A: JOIN OR OWN — ONE COMMIT PER TRANSACTION, PERFORMED
    # BY WHOEVER OPENED IT. Inside the firewall lane this function runs as a
    # SUBPROCESS of `nftban portscan reload`, with NFTBAN_PLAN_TARGET_GENERATION
    # already exported; it joins that transaction and the LANE commits. Run
    # standalone, it owns the transaction and commits below, after runtime
    # reconciliation has actually completed.
    if [[ -z "${NFTBAN_PLAN_TARGET_GENERATION:-}" ]]; then
        # Propagate rc 7 (CONVERGENCE BUSY) rather than flattening it into the
        # generic publication failure 4 — the operator needs to know which it was.
        nftban_plan_txn_begin portscan || return $?
        _txn_owned="true"
    fi
    # ⛔ THE RECORD IS STAMPED WITH THE UNCOMMITTED TARGET, NOT THE COMMITTED
    # GENERATION. The generation file does not advance until commit, so a record
    # written for the committed generation would either violate the immutability
    # of an already-committed set or be indistinguishable from the state a
    # truncated convergence leaves behind.
    _gen="$(nftban_plan_target_generation)" || _gen=""
    if [[ -z "$_gen" || ! "$_gen" =~ ^[0-9]+$ ]]; then
        echo "nftban_portscan_reconcile: convergence target generation is '${_gen:-<empty>}' — refusing to publish an unbound plan." >&2
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
        echo "nftban_portscan_reconcile: runtime directory $_dir is absent — refusing to publish." >&2
        echo "                        it is owned by systemd-tmpfiles; restore it with:" >&2
        echo "                        systemd-tmpfiles --create /usr/lib/tmpfiles.d/nftban.conf" >&2
        return 4
    fi

    # v1.229.11 lane 6A: records are addressed BY GENERATION and are IMMUTABLE
    # once their generation commits. The generation file is the sole selector.
    local _pf _tmp
    _pf="$(nftban_plan_record_path portscan "$_gen")"
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
        echo "nftban_portscan_reconcile: failed to write the plan record — refusing to publish a partial one." >&2
        if [[ "$_txn_owned" == "true" ]]; then nftban_plan_txn_abort; fi
        return 4
    fi
    chmod 0640 "$_tmp" 2>/dev/null || true
    if ! mv -f "$_tmp" "$_pf" 2>/dev/null; then
        rm -f "$_tmp"
        echo "nftban_portscan_reconcile: atomic publication failed." >&2
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
            echo "         Refusing ALL higher-tier portscan mutation — apply AND teardown." >&2
            echo "         Base Layer-0 protection is unaffected." >&2
            _rc=1
            ;;
        inactive)
            nftban_portscan_teardown || _rc=$?
            ;;
        classic|suricata)
            nftban_portscan_apply || _rc=$?
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
# _nftban_portscan_remove_other_projection <mode-being-applied>
#
# v1.229.7 PR-3B. Removes the OPPOSITE mode's projection so rendered state
# matches the plan and nothing else.
#
# ⛔ ASYMMETRIC BY SUBSTRATE, NOT BY OMISSION. The classic side projects a
# portscan chain and rules into nftables, so entering suricata must remove them.
# The Suricata side creates NO nftables objects for portscan -- its detection is
# daemon-side -- so entering classic has no nft projection to remove and
# `nftban_portscan_suricata_disable` is a state-save only. Do NOT "fix" that by
# inventing a teardown for objects that were never rendered.
#   SAME CONTRACT != SAME IMPLEMENTATION.
# ⛔ Base Layer-0 is never touched.
# -----------------------------------------------------------------------------
_nftban_portscan_remove_other_projection() {
    local other target_mode
    case "${1:-}" in
        classic)  other="nftban_portscan_suricata_disable"; target_mode="suricata" ;;
        suricata) other="nftban_portscan_classic_disable";  target_mode="classic"  ;;
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
        _nftban_portscan_log "ERROR" "exclusivity unestablished: $other missing"
        return 1
    fi
    # The teardown itself is best-effort: a host that never ran the other mode
    # has nothing to remove, and that is not a failure.
    "$other" >/dev/null 2>&1 || true

    # ⛔ FLUSHED != ABSENT -- the same contract violation proven for ddos, with
    # PortScan's own evidence and PortScan's own object inventory.
    # nft_fragment_render_portscan_classic_cleanup emits `flush chain` for
    # portscan_detection in both families, annotated "keeps chain for reference
    # safety". After `nftban portscan reload` across classic -> suricata the
    # plan said suricata while portscan_detection remained, still jumped from
    # base input.
    # WITNESSED package-native on lab4/RPM, merged .7 main:
    #     portscan suricata reload -> CLASSIC_RESIDUE, V4_MISMATCH, V6_MISMATCH
    #
    # ⛔ NOT A PORT OF THE DDOS FIX. The inventory was measured for PortScan
    # independently (converged, lab2/DEB):
    #     classic  : chain portscan_detection  (ip AND ip6) + base jump edges
    #     suricata : NO portscan nft objects at all
    # so only one direction has anything to remove -- which is why entering
    # classic returns early below rather than "purging" an empty projection.
    #   SAME CONTRACT != SAME IMPLEMENTATION.
    _nftban_portscan_purge_projection "$target_mode" || return 1
    return 0
}

# -----------------------------------------------------------------------------
# _nftban_portscan_purge_projection <mode-whose-projection-must-become-absent>
#
# Order is forced by the kernel: jump edges first, then the chain, both families.
# Writes go through nft_fragment_delete_object -- the sanctioned nft writer --
# never directly from this module.
#   AN ALLOWLIST ENTRY IS NOT A COMPLIANCE ARGUMENT.
#
# ⛔ portscan_blocked, if a host has one, is a BAN SET and is never part of the
# classic projection census. The ddos lane proved what happens otherwise:
# deleting the shared ban set aborted the whole apply and left the host DEGRADED
# with no higher-tier projection at all.
#   SHARED OBJECT != OTHER MODE'S PROJECTION
_NFTBAN_PORTSCAN_SHARED_SETS="portscan_blocked"

_nftban_portscan_purge_projection() {
    local mode="${1:-}" fam name kind residue=""

    # Suricata projects no portscan nft object, so there is nothing to remove
    # when entering classic. This is a no-op BY CONSTRUCTION, not an unwritten
    # case -- see the measured inventory above.
    if [[ "$mode" == suricata ]]; then
        return 0
    fi

    for fam in ip ip6; do
        while IFS=' ' read -r kind name; do
            # ⛔ IFS pinned: sourcing the product leaves IFS=$'\n\t' in scope, so a
            # bare read leaves $name empty and the loop silently processes NOTHING
            # while still returning success. That exact bug shipped in the ddos
            # version of this function and was caught only by a population assertion.
            #   NO SUBJECTS PROCESSED != NOTHING TO DO
            [[ -z "$kind" || -z "$name" ]] && continue
            [[ " $_NFTBAN_PORTSCAN_SHARED_SETS " == *" $name "* ]] && continue
            # ⛔ The writer requirement is checked HERE, per object, not up front.
            # Hoisting it to the top of the function made an EMPTY census a hard
            # failure: with nothing to remove there is nothing to establish, and
            # refusing then aborts a legitimate dispatch. plan_projection_v1229_7
            # caught exactly that -- portscan plan=suricata never reached
            # suricata_enable -- and it caught it because the ddos twin checks
            # per object, so the two implementations disagreed.
            #   NOTHING TO REMOVE != FAILURE TO REMOVE
            if ! declare -F nft_fragment_delete_object >/dev/null 2>&1; then
                echo "  ERROR: nft_fragment_delete_object unavailable — cannot establish mode-exclusive projection." >&2
                return 1
            fi
            nft_fragment_delete_object "$fam" "$kind" "$name" || true
        done < <(_nftban_portscan_live_objects "$fam")
    done

    # ⛔ VERIFY, DO NOT ASSUME: the deletes above are individually tolerant, so
    # absence is asserted separately or a stray reference leaves residue at rc0.
    for fam in ip ip6; do
        while IFS=' ' read -r kind name; do
            [[ -z "$name" ]] && continue
            [[ " $_NFTBAN_PORTSCAN_SHARED_SETS " == *" $name "* ]] && continue
            residue="$residue $fam/$kind/$name"
        done < <(_nftban_portscan_live_objects "$fam")
    done

    if [[ -n "$residue" ]]; then
        echo "  ERROR: the ${mode} projection is still present after teardown:${residue}" >&2
        echo "         refusing to claim mode-exclusive projection." >&2
        _nftban_portscan_log "ERROR" "exclusivity unestablished: residue${residue}"
        return 1
    fi
    return 0
}

# Enumerate live higher-tier PortScan objects in one family: "<kind> <name>".
_nftban_portscan_live_objects() {
    local fam="${1:-ip}"
    nft list table "$fam" nftban 2>/dev/null | awk '
        /^[[:space:]]*chain[[:space:]]+portscan_/ { print "chain " $2 }
        /^[[:space:]]*set[[:space:]]+portscan_/   { print "set "   $2 }
    '
}

nftban_portscan_apply() {
    # Load config and modules even if currently disabled — enable needs to work
    # when portscan is off (that's the whole point of enable)
    nftban_portscan_load_config
    nftban_portscan_init_dirs
    _nftban_portscan_load_modules

    # v1.229.7 PR-3A: CONSUME THE PLAN. Same contract as ddos -- identical at the
    # authority layer, separate adapters below. Do NOT rediscover mode from disk.
    local mode
    if [[ "${NFTBAN_PLAN_MODULE:-}" == "portscan" && -n "${NFTBAN_PLAN_EFFECTIVE_MODE:-}" ]]; then
        # ⛔ PLAN-N2: the plan must belong to THIS transaction. Missing and mixed
        # provenance are different failures and both refuse.
        nftban_module_plan_provenance_ok portscan || {
            echo "  ERROR: plan provenance check failed — refusing to apply." >&2
            return 1
        }
        mode="$NFTBAN_PLAN_EFFECTIVE_MODE"
        _nftban_portscan_log "INFO" "consuming plan ${NFTBAN_PLAN_RESOLUTION_ID:-<no-id>} (${NFTBAN_PLAN_RESOLUTION_BASIS:-})"
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
        echo "         Call nftban_portscan_reconcile (the transaction root) instead." >&2
        _nftban_portscan_log "ERROR" "refusing apply: no plan supplied (consumer must receive a plan)"
        return 1
    fi
    _PORTSCAN_ACTIVE_MODE="$mode"

    # ⛔ UNKNOWN stops the higher-tier transaction -- no fallback, no teardown,
    # no fabricated plan. Base Layer-0 is unaffected.
    if [[ "$mode" == "unknown" ]]; then
        echo "  ERROR: effective mode is UNKNOWN (${NFTBAN_PLAN_RESOLUTION_BASIS:-no basis}) — refusing to apply higher-tier portscan." >&2
        echo "         Base Layer-0 protection is unaffected." >&2
        _nftban_portscan_log "ERROR" "refusing apply: effective_mode=unknown basis=${NFTBAN_PLAN_RESOLUTION_BASIS:-}"
        return 1
    fi
    if [[ "$mode" == "inactive" ]]; then
        _nftban_portscan_log "INFO" "module disabled — no higher-tier apply"
        return 0
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Portscan Detection - Mode: ${mode^^}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    _nftban_portscan_log "INFO" "Enabling portscan detection (mode: ${mode})"

    # Step 1: Apply nftables rules FIRST (before persisting config)
    local enable_result=0
    # v1.229.7 PR-3B: PROJECTION IS A PURE FUNCTION OF THE PLAN.
    #
    #   RENDERER CONSUMES A DECISION. RENDERER DOES NOT MAKE A DECISION.
    #
    # Same contract as ddos, separate adapter. The `hybrid` arm that enabled
    # classic AND suricata together is gone: CLASSIC_ACTIVE + SURICATA_ACTIVE is
    # the state this lane exists to remove.
    # ⛔ The renderer must never REPAIR a bad plan.
    case "$mode" in
        classic|suricata) ;;
        # NOTE: `inactive` is handled ABOVE by the PR-3A early return (benign
        # no-op: apply projects nothing; the reconcile root routes inactive to
        # teardown, which owns removal). Deliberately NOT repeated here -- two
        # contradictory statements about one condition is worse than either.
        *)
            echo "  ERROR: effective_mode='${mode}' is not projectable (expected classic|suricata)." >&2
            _nftban_portscan_log "ERROR" "refusing apply: non-projectable effective_mode=${mode}"
            return 1
            ;;
    esac

    # ⛔ EXCLUSIVITY IS PART OF THE PROJECTION, NOT A SIDE EFFECT OF IT.
    #   PLAN DIFFERENCE MUST CONTROL MODE-SPECIFIC PROJECTION.
    # Base Layer-0 is untouched: ALWAYS_ON_BASE_PROTECTION.
    _nftban_portscan_remove_other_projection "$mode" || return 1

    case "$mode" in
        classic)
            echo ""
            echo "  Using CLASSIC mode (native nftables)"
            echo ""
            if type -t nftban_portscan_classic_enable &>/dev/null; then
                nftban_portscan_classic_enable || enable_result=$?
            else
                echo "  ERROR: Classic mode module not loaded!" >&2
                _nftban_portscan_log "ERROR" "Classic mode module not loaded"
                return 1
            fi
            ;;

        suricata)
            echo ""
            echo "  Using SURICATA mode (IDS-integrated)"
            echo ""
            if type -t nftban_portscan_suricata_enable &>/dev/null; then
                nftban_portscan_suricata_enable || enable_result=$?
            else
                echo "  ERROR: Suricata mode module not loaded!" >&2
                _nftban_portscan_log "ERROR" "Suricata mode module not loaded"
                return 1
            fi
            ;;
    esac

    # Step 2: Verify nft rules were actually applied
    if [[ $enable_result -ne 0 ]]; then
        echo ""
        echo "  ❌ ERROR: Failed to apply nftables rules!" >&2
        echo "  Check: is nftband daemon running? (systemctl status nftband)" >&2
        _nftban_portscan_log "ERROR" "Failed to apply nftables rules (exit=$enable_result)"
        return 1
    fi
    return 0
}

# -----------------------------------------------------------------------------
# nftban_portscan_enable -- OPERATOR ORCHESTRATION. CLI-ONLY.
# v1.229.7 PR-2: persists intent, calls the neutral apply, then performs the
# service lifecycle action. NOT daemon-callable.
# -----------------------------------------------------------------------------
nftban_portscan_enable() {
    nftban_portscan_reconcile || return 1

    # v1.229.7 PR-2a: see nftban_ddos_enable -- same unbound-`mode` defect.
    # ⛔ v1.229.7 PR-3B: REPORT WHAT THE TRANSACTION DID, NOT A FRESH GUESS.
    # This called the local detector purely to label the success banner, so the
    # operator could be told "SURICATA" while the transaction had actually
    # applied CLASSIC (or the reverse) whenever availability changed between the
    # two independent resolutions. Only the plan the root published is entitled
    # to answer "which mode did we just enable?".
    #   A REPORT MUST DESCRIBE THE ACTION THAT HAPPENED.
    local mode="${NFTBAN_PLAN_EFFECTIVE_MODE:-${_PORTSCAN_ACTIVE_MODE:-unknown}}"

    # Step 3: Persist PORTSCAN_ENABLED=true ONLY after nft rules succeed.
    # v1.229.7 PR-2: routed through the SINGLE durable-intent writer.
    nftban_module_set_enabled portscan true || return 1
    PORTSCAN_ENABLED="true"

    # Step 4: Auto-restart nftband to activate immediately
    if systemctl is-active nftband &>/dev/null; then
        echo "  Restarting nftband daemon..."
        if systemctl restart nftband 2>/dev/null; then
            echo "  ✅ Daemon restarted — portscan detection is now active"
        else
            echo "  ⚠️  Daemon restart failed — run: systemctl restart nftband" >&2
        fi
    else
        echo "  ⚠️  nftband not running — start with: systemctl start nftband"
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✅ Portscan Detection ENABLED (${mode^^})"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    _nftban_portscan_log "INFO" "Portscan detection enabled successfully"
    return 0
}

# Disable portscan detection
# -----------------------------------------------------------------------------
# nftban_portscan_teardown -- NEUTRAL RUNTIME TEARDOWN. Daemon-callable.
# v1.229.7 PR-2: removes runtime enforcement ONLY. No config write, no restart.
# -----------------------------------------------------------------------------
nftban_portscan_teardown() {
    local mode="${_PORTSCAN_ACTIVE_MODE:-classic}"

    echo ""
    echo "  Disabling portscan detection (${mode})..."

    _nftban_portscan_log "INFO" "Disabling portscan detection"

    case "$mode" in
        classic)
            if type -t nftban_portscan_classic_disable &>/dev/null; then
                nftban_portscan_classic_disable
            fi
            ;;
        suricata)
            if type -t nftban_portscan_suricata_disable &>/dev/null; then
                nftban_portscan_suricata_disable
            fi
            ;;
        hybrid)
            if type -t nftban_portscan_classic_disable &>/dev/null; then
                nftban_portscan_classic_disable
            fi
            if type -t nftban_portscan_suricata_disable &>/dev/null; then
                nftban_portscan_suricata_disable
            fi
            ;;
    esac

    _PORTSCAN_INITIALIZED=0

    echo "  ✅ Portscan detection disabled"
    echo ""

    _nftban_portscan_log "INFO" "Portscan detection disabled"
    return 0
}

# -----------------------------------------------------------------------------
# nftban_portscan_disable -- OPERATOR ORCHESTRATION. CLI-ONLY.
# v1.229.7 PR-2: persists intent, then tears down runtime. NOT daemon-callable.
# -----------------------------------------------------------------------------
nftban_portscan_disable() {
    nftban_module_set_enabled portscan false || return 1
    PORTSCAN_ENABLED="false"
    nftban_portscan_reconcile
}

# =============================================================================
# STATUS
# =============================================================================

# v1.141 PR-B (J-PORT) — JSON renderer for `nftban portscan status --json`.
# Built with jq -n (no string concatenation) so output is valid JSON. Fields
# mirror the text-mode status section labels.
_nftban_portscan_status_json() {
    local is_enabled="${PORTSCAN_ENABLED:-false}"
    local auto_ban="${PORTSCAN_AUTO_BAN:-true}"
    local configured_mode="${PORTSCAN_MODE:-auto}"

    local detected_mode active_mode suricata_available=false
    # ⛔ v1.229.7 PR-4 READ-PATH MODE CONTRACT. This used the local detector,
    # which resolves `auto` by probing Suricata availability -- a second,
    # independent authority that could report a mode the system had not decided.
    #   STATUS MUST NOT RESOLVE AUTO.
    #   CONFIGURED INTENT != EFFECTIVE DECISION != OBSERVED RUNTIME
    eval "$(nftban_module_report_modes portscan)"
    detected_mode="${NFTBAN_REPORT_EFFECTIVE_MODE}"
    active_mode="${_PORTSCAN_ACTIVE_MODE:-$detected_mode}"
    if type -t _nftban_portscan_suricata_is_available &>/dev/null \
       && _nftban_portscan_suricata_is_available; then
        suricata_available=true
    fi

    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg enabled    "$is_enabled" \
            --arg auto_ban   "$auto_ban" \
            --arg cfg_mode   "$configured_mode" \
            --arg det_mode   "$detected_mode" \
            --arg act_mode   "$active_mode" \
            --argjson suri   "$suricata_available" \
            '{
                module: "portscan",
                enabled: ($enabled == "true" or $enabled == "1"),
                auto_ban: ($auto_ban == "true" or $auto_ban == "1"),
                configured_mode: $cfg_mode,
                detected_mode: $det_mode,
                active_mode: $act_mode,
                suricata: { available: $suri }
            }'
        return $?
    fi
    printf '{"module":"portscan","enabled":%s,"auto_ban":%s,"configured_mode":"%s","detected_mode":"%s","active_mode":"%s","suricata":{"available":%s},"jq_unavailable":true}\n' \
        "$([[ "$is_enabled" == "true" ]] && echo true || echo false)" \
        "$([[ "$auto_ban" == "true" ]] && echo true || echo false)" \
        "$configured_mode" "$detected_mode" "$active_mode" \
        "$([[ "$suricata_available" == true ]] && echo true || echo false)"
}

# Get portscan detection status
# v1.141 PR-B (J-PORT): function now takes optional json_mode arg.
# shellcheck disable=SC2120
# (Some internal callers — e.g. line ~937 — invoke this without args; the
# `${1:-false}` default handles that. SC2120 over-fires on optional args.)
nftban_portscan_status() {
    # v1.141 PR-B (J-PORT): json_mode-aware status. When json_mode="true",
    # short-circuit ALL decorative chrome and emit valid JSON via jq -n.
    # Pre-v1.141 had no json_mode parameter; the dispatcher arm at
    # cmd_portscan.sh:441 called it bare, so `--json` got banner+text.
    local json_mode="${1:-false}"

    # v1.19.20 FIX (B6): Ensure config is loaded before using variables
    nftban_portscan_load_config

    if [[ "$json_mode" == "true" ]]; then
        _nftban_portscan_status_json
        return $?
    fi

    # Show unified banner
    if type -t nftban_banner >/dev/null 2>&1; then
        nftban_banner "portscan"
        echo ""
    fi
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  NFTBan Portscan Detection Status                       ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    # ==========================================================================
    # MAIN STATUS - Is it enabled and protecting?
    # ==========================================================================
    # v1.19.20 FIX (B5): Correct default to false (matches config loader)
    local is_enabled="${PORTSCAN_ENABLED:-false}"
    local auto_ban="${PORTSCAN_AUTO_BAN:-true}"

    if [[ "$is_enabled" == "true" ]]; then
        echo "  Status:      ✅ ENABLED - Port scan detection is active"
    else
        echo "  Status:      ❌ DISABLED - Port scan detection is OFF"
        echo ""
        echo "  To enable:   nftban portscan enable"
        echo ""
        return 0
    fi

    if [[ "$auto_ban" == "true" ]]; then
        echo "  Auto-Ban:    ✅ ON - Detected scanners will be automatically banned"
    else
        echo "  Auto-Ban:    ⚠️  OFF - Monitoring only, no automatic bans"
    fi
    echo ""

    # ==========================================================================
    # DETECTION METHOD
    # ==========================================================================
    echo "DETECTION METHOD"
    echo "───────────────────────────────────────────────────────────"

    local configured_mode="${PORTSCAN_MODE:-auto}"
    local detected_mode
    # ⛔ v1.229.7 PR-4 READ-PATH MODE CONTRACT. This used the local detector,
    # which resolves `auto` by probing Suricata availability -- a second,
    # independent authority that could report a mode the system had not decided.
    #   STATUS MUST NOT RESOLVE AUTO.
    #   CONFIGURED INTENT != EFFECTIVE DECISION != OBSERVED RUNTIME
    eval "$(nftban_module_report_modes portscan)"
    detected_mode="${NFTBAN_REPORT_EFFECTIVE_MODE}"
    local active_mode="${_PORTSCAN_ACTIVE_MODE:-$detected_mode}"

    case "$active_mode" in
        suricata)
            echo "  Using:       Suricata IDS (recommended, high accuracy)"
            echo "  Mode:        Suricata is analyzing network traffic in real-time"
            ;;
        classic)
            echo "  Using:       Classic nftables log parsing"
            echo "  Mode:        Monitoring closed port connection attempts"
            ;;
        hybrid)
            echo "  Using:       Hybrid (Suricata + nftables logs)"
            echo "  Mode:        Dual detection for maximum coverage"
            ;;
        *)
            echo "  Using:       Unknown (needs initialization)"
            ;;
    esac
    echo ""

    # ==========================================================================
    # SURICATA STATUS (if relevant)
    # ==========================================================================
    local suricata_available=false
    if _nftban_portscan_suricata_is_available; then
        suricata_available=true
    fi

    echo "SURICATA IDS"
    echo "───────────────────────────────────────────────────────────"
    if [[ "$suricata_available" == "true" ]]; then
        echo "  Available:   ✅ YES - Suricata is installed and running"
        echo "  Service:     $(systemctl is-active suricata 2>/dev/null || echo 'unknown')"

        # Support Suricata 7.x threaded logging: check all eve-alerts*.json files
        local eve_dir="${NFTBAN_LOG_DIR:-/var/log/nftban}/suricata"
        local eve_file="${PORTSCAN_SURICATA_EVE_FILE:-${eve_dir}/eve-alerts.json}"
        local freshest_mtime=0 freshest_file="" now_ts eve_age

        shopt -s nullglob
        for f in "$eve_dir"/eve-alerts*.json; do
            [[ -f "$f" ]] || continue
            local m
            m=$(stat -L -c %Y -- "$f" 2>/dev/null) || continue
            [[ "$m" =~ ^[0-9]+$ ]] || continue
            if (( m > freshest_mtime )); then
                freshest_mtime=$m
                freshest_file="$f"
            fi
        done
        shopt -u nullglob

        if [[ $freshest_mtime -gt 0 ]]; then
            now_ts=$(date +%s)
            eve_age=$(( now_ts - freshest_mtime ))
            local source_note=""
            [[ "$freshest_file" != "$eve_file" ]] && source_note=" (threaded)"
            if [[ $eve_age -lt 300 ]]; then
                echo "  EVE Log:     ✅ Active (updated ${eve_age}s ago${source_note})"
            else
                echo "  EVE Log:     ⚠️  Stale (last update ${eve_age}s ago${source_note})"
            fi
        else
            echo "  EVE Log:     ❌ Not found in $eve_dir"
        fi
    else
        echo "  Available:   ❌ NO - Suricata not available for detection"
        if ! command -v suricata &>/dev/null; then
            echo "  Reason:      Binary not installed"
            echo "  Fix:         nftban setup suricata"
        elif ! systemctl is-active suricata &>/dev/null; then
            echo "  Reason:      Service not running"
            echo "  Fix:         systemctl start suricata"
        else
            # Binary exists and service running — EVE log must be the issue
            # Support Suricata 7.x threaded logging
            local eve_dir="${NFTBAN_LOG_DIR:-/var/log/nftban}/suricata"
            local eve_file="${PORTSCAN_SURICATA_EVE_FILE:-${eve_dir}/eve-alerts.json}"
            local freshest_mtime=0

            shopt -s nullglob
            for f in "$eve_dir"/eve-alerts*.json; do
                [[ -f "$f" ]] || continue
                local m
                m=$(stat -L -c %Y -- "$f" 2>/dev/null) || continue
                [[ "$m" =~ ^[0-9]+$ ]] || continue
                (( m > freshest_mtime )) && freshest_mtime=$m
            done
            shopt -u nullglob

            if [[ $freshest_mtime -eq 0 ]]; then
                echo "  Reason:      EVE log not found in $eve_dir"
                echo "  Fix:         Check Suricata output config (suricata.yaml)"
            else
                local eve_age=$(( $(date +%s) - freshest_mtime ))
                echo "  Reason:      EVE log stale (last update ${eve_age}s ago, threshold: ${PORTSCAN_EVE_FRESHNESS_THRESHOLD:-60}s)"
                echo "  Fix:         Check Suricata is processing traffic: suricata --build-info"
                echo "               Verify EVE output: grep eve-log /etc/suricata/suricata.yaml"
            fi
        fi
    fi
    echo ""

    # ==========================================================================
    # DETECTION SETTINGS
    # ==========================================================================
    echo "DETECTION SETTINGS"
    echo "───────────────────────────────────────────────────────────"
    echo "  Threshold:   ${PORTSCAN_THRESHOLD:-10} unique ports triggers detection"
    echo "  Time Window: ${PORTSCAN_TIME_WINDOW:-300} seconds ($(( ${PORTSCAN_TIME_WINDOW:-300} / 60 )) minutes)"
    echo "  Ban Type:    ${PORTSCAN_BAN_TYPE:-temporary}"
    if [[ "${PORTSCAN_BAN_TYPE:-temporary}" == "temporary" ]]; then
        echo "  Ban Duration: ${PORTSCAN_BAN_TIME:-3600} seconds ($(( ${PORTSCAN_BAN_TIME:-3600} / 60 )) minutes)"
    fi
    echo ""

    # ==========================================================================
    # RECENT ACTIVITY
    # ==========================================================================
    echo "RECENT ACTIVITY (last 24h)"
    echo "───────────────────────────────────────────────────────────"
    local ban_log="${NFTBAN_BAN_LOG:-${NFTBAN_LOG_DIR:-/var/log/nftban}/bans.log}"
    if [[ -f "$ban_log" ]]; then
        local yesterday today scan_bans
        yesterday=$(date -d '24 hours ago' '+%Y-%m-%d' 2>/dev/null || date '+%Y-%m-%d')
        today=$(date '+%Y-%m-%d')
        # Count portscan bans from last 24 hours
        scan_bans=$(grep "|portscan|" "$ban_log" 2>/dev/null | grep -cE "^($yesterday|$today)" || true)
        [[ -z "$scan_bans" ]] && scan_bans=0
        echo "  Port scans detected: $scan_bans"
    else
        echo "  No activity log found"
    fi
    echo ""

    # ==========================================================================
    # DETECTION MODES EXPLAINED
    # ==========================================================================
    echo "DETECTION MODES"
    echo "───────────────────────────────────────────────────────────"
    echo ""
    echo "  classic   - Uses nftables logging of closed port attempts"
    echo "              Parses kernel/journalctl logs for scan patterns"
    echo ""
    echo "  suricata  - Uses Suricata IDS with portscan rules"
    echo "              Better accuracy, lower false positives"
    echo ""
    echo "  hybrid    - LEGACY, NOT SUPPORTED: resolves to unknown and refuses."
    echo "              Running both pipelines at once is an invalid state."
    echo "              Set an explicit mode to migrate."
    echo "              Maximum coverage with redundant detection"
    echo ""
    echo "  auto      - Auto-selects based on Suricata availability"
    echo "              Uses suricata if available, otherwise classic"
    echo ""

    # ==========================================================================
    # CONFIGURATION
    # ==========================================================================
    echo "CONFIGURATION"
    echo "───────────────────────────────────────────────────────────"
    echo ""
    echo "  Config File:  /etc/nftban/conf.d/portscan/main.conf"
    local local_file="/etc/nftban/conf.d/portscan/main.conf.local"
    if [[ -f "$local_file" ]]; then
        echo "  Override File:  $local_file  [Active]"
    else
        echo "  Override File:  $local_file  [Not created]"
    fi
    echo "  Log File:     ${NFTBAN_PORTSCAN_LOG_FILE}"
    echo ""
    echo "  Key Settings:"
    echo "    PORTSCAN_ENABLED=true|false"
    echo "    PORTSCAN_MODE=auto|classic|suricata   (hybrid = legacy, refuses)"
    echo "    PORTSCAN_AUTO_BAN=true|false   - Auto-ban detected scanners"
    echo "    PORTSCAN_THRESHOLD=10          - Ports to trigger detection"
    echo "    PORTSCAN_TIME_WINDOW=300       - Detection window (seconds)"
    echo "    PORTSCAN_BAN_TIME=3600         - Ban duration (seconds)"
    echo ""
    echo "  Note: Put custom settings in main.conf.local (survives upgrades)"
    echo ""

    # Trusted-monitoring-flow exclusion (event-generation suppression only)
    if type -t nftban_portscan_trusted_flow_render &>/dev/null; then
        nftban_portscan_trusted_flow_render
        echo ""
    fi

    # ==========================================================================
    # v1.19.20 (B8): OPEN PORTS VISIBILITY
    # ==========================================================================
    echo "OPEN PORTS (Allowed Inbound - Bypass Detection)"
    echo "───────────────────────────────────────────────────────────"

    local tcp_ports_ipv4="" udp_ports_ipv4="" tcp_ports_ipv6="" udp_ports_ipv6=""

    # IPv4 ports
    if nft list set ip nftban tcp_ports_in &>/dev/null; then
        tcp_ports_ipv4=$(nft list set ip nftban tcp_ports_in 2>/dev/null | \
            grep "elements" | sed 's/.*elements = { //;s/ }$//' | tr -d '\n\t') || true
    fi
    if nft list set ip nftban udp_ports_in &>/dev/null; then
        udp_ports_ipv4=$(nft list set ip nftban udp_ports_in 2>/dev/null | \
            grep "elements" | sed 's/.*elements = { //;s/ }$//' | tr -d '\n\t') || true
    fi

    # IPv6 ports
    if nft list set ip6 nftban tcp_ports_in &>/dev/null; then
        tcp_ports_ipv6=$(nft list set ip6 nftban tcp_ports_in 2>/dev/null | \
            grep "elements" | sed 's/.*elements = { //;s/ }$//' | tr -d '\n\t') || true
    fi
    if nft list set ip6 nftban udp_ports_in &>/dev/null; then
        udp_ports_ipv6=$(nft list set ip6 nftban udp_ports_in 2>/dev/null | \
            grep "elements" | sed 's/.*elements = { //;s/ }$//' | tr -d '\n\t') || true
    fi

    echo "  IPv4:"
    echo "    TCP:  ${tcp_ports_ipv4:-none}"
    echo "    UDP:  ${udp_ports_ipv4:-none}"
    echo ""
    echo "  IPv6:"
    echo "    TCP:  ${tcp_ports_ipv6:-none}"
    echo "    UDP:  ${udp_ports_ipv6:-none}"
    echo ""

    # ==========================================================================
    # v1.19.20 (B9): JUMP RULE VERIFICATION
    # ==========================================================================
    echo "NFTABLES RULE VERIFICATION"
    echo "───────────────────────────────────────────────────────────"

    local chain_rules=""

    # v1.60.6: Validate portscan jump position relative to SYN meter
    # The SYN meter accepts all slow TCP SYN traffic — if portscan jump is
    # after the meter, TCP detection is structurally dead.
    local family_label jump_index meter_index accept_index
    for family_label in "IPv4:ip" "IPv6:ip6"; do
        local label="${family_label%%:*}"
        local fam="${family_label##*:}"
        local meter_name="syn_meter_v4"
        [[ "$fam" == "ip6" ]] && meter_name="syn_meter_v6"

        echo "  ${label} Jump Rule:"

        if ! nft list chain ${fam} nftban input &>/dev/null; then
            echo "    Chain:     ❌ ${fam} nftban input not found"
            echo ""
            continue
        fi

        chain_rules=$(nft -a list chain ${fam} nftban input 2>/dev/null) || true

        # Find jump position
        jump_index=$(echo "$chain_rules" | grep -n "jump portscan_detection" | cut -d: -f1 | head -1) || true
        # Find SYN meter position
        meter_index=$(echo "$chain_rules" | grep -n "${meter_name}" | cut -d: -f1 | head -1) || true
        # Find service accept position
        accept_index=$(echo "$chain_rules" | grep -n '@tcp_ports_in' | head -1 | cut -d: -f1) || true

        if [[ -z "$jump_index" ]]; then
            echo "    Exists:    ❌ NO - Jump rule not found!"
            echo "    TCP+UDP:   ❌ UNREACHABLE - Portscan detection NOT active"
            echo ""
            continue
        fi

        echo "    Exists:    ✅ YES (rule #${jump_index})"

        # Primary check: is jump before SYN meter?
        if [[ -n "$meter_index" ]] && [[ "$meter_index" =~ ^[0-9]+$ ]] && \
           [[ "$jump_index" =~ ^[0-9]+$ ]]; then
            if [[ "$jump_index" -lt "$meter_index" ]]; then
                echo "    Position:  ✅ CORRECT - Before SYN rate meter"
                echo "    TCP+UDP:   ✅ Both protocols visible to detection"
            else
                echo "    Position:  ❌ SHADOWED - After SYN rate meter (rule #${meter_index})"
                echo "    TCP:       ❌ DEAD - SYN meter accepts all slow TCP before portscan"
                echo "    UDP:       ✅ Still detected (bypasses SYN meter)"
                echo "    Fix: nftban portscan restart"
            fi
        elif [[ -n "$accept_index" ]] && [[ "$accept_index" =~ ^[0-9]+$ ]] && \
             [[ "$jump_index" =~ ^[0-9]+$ ]]; then
            # Fallback: check against service accept if meter not found
            if [[ "$jump_index" -lt "$accept_index" ]]; then
                echo "    Position:  ✅ Before service accepts"
                echo "    SYN Meter: ⚠️  UNKNOWN - meter not found, cannot verify TCP path"
            else
                echo "    Position:  ❌ WRONG - After service accepts (rule #${accept_index})"
                echo "    Fix: nftban portscan restart"
            fi
        else
            echo "    Position:  ⚠️  UNKNOWN - Cannot find SYN meter or service rules"
        fi
        echo ""
    done

    # ==========================================================================
    # COMMANDS
    # ==========================================================================
    echo "COMMANDS"
    echo "───────────────────────────────────────────────────────────"
    echo ""
    echo "  nftban portscan enable         - Enable port scan detection"
    echo "  nftban portscan disable        - Disable port scan detection"
    echo "  nftban portscan history        - View detected port scans"
    echo "  nftban portscan check          - Run manual detection now"
    echo "  nftban portscan sync           - Sync logs from journalctl"
    echo "  nftban portscan help           - Show all available commands"
    echo ""

    return 0
}

# =============================================================================
# RUN (PERIODIC PROCESSING)
# =============================================================================

# Run portscan detection cycle
nftban_portscan_run() {
    if [[ "${PORTSCAN_ENABLED:-false}" != "true" ]]; then
        return 0
    fi

    # Initialize if needed
    if [[ $_PORTSCAN_INITIALIZED -eq 0 ]]; then
        nftban_portscan_init
    fi

    local mode="${_PORTSCAN_ACTIVE_MODE}"

    case "$mode" in
        classic)
            if type -t nftban_portscan_classic_run &>/dev/null; then
                nftban_portscan_classic_run
            fi
            ;;
        suricata)
            if type -t nftban_portscan_suricata_run &>/dev/null; then
                nftban_portscan_suricata_run
            fi
            ;;
        hybrid)
            if type -t nftban_portscan_classic_run &>/dev/null; then
                nftban_portscan_classic_run
            fi
            if type -t nftban_portscan_suricata_run &>/dev/null; then
                nftban_portscan_suricata_run
            fi
            ;;
    esac

    return 0
}

# =============================================================================
# CLI INTERFACE
# =============================================================================

# Main CLI handler
nftban_portscan_cli() {
    local cmd="${1:-status}"
    shift || true

    case "$cmd" in
        enable)
            nftban_portscan_enable
            ;;
        disable)
            nftban_portscan_disable
            ;;
        status)
            nftban_portscan_status
            ;;
        run|process)
            nftban_portscan_run
            ;;
        mode)
            echo "Configured: ${PORTSCAN_MODE:-auto}"
            # ⛔ v1.229.7 PR-4 READ-PATH MODE CONTRACT — status must not resolve auto.
            eval "$(nftban_module_report_modes portscan)"
            echo "Configured: ${NFTBAN_REPORT_CONFIGURED_MODE}"
            echo "Active:     ${NFTBAN_REPORT_EFFECTIVE_MODE}"
            # `&& echo` alone would return non-zero when the condition is false,
            # and this is the arm's last command -- under `set -e` that aborts.
            if [[ "${NFTBAN_REPORT_EFFECTIVE_MODE}" == "unknown" ]]; then
                echo "            (${NFTBAN_REPORT_EFFECTIVE_BASIS} — no authoritative decision to report)"
            fi
            ;;
        help|--help|-h)
            echo "Usage: nftban portscan <command>"
            echo ""
            echo "Commands:"
            echo "  enable    Enable portscan detection"
            echo "  disable   Disable portscan detection"
            echo "  status    Show portscan detection status"
            echo "  run       Run detection cycle"
            echo "  mode      Show current mode"
            echo ""
            echo "Configuration: ${NFTBAN_PORTSCAN_CONFIG_DIR}/"
            ;;
        *)
            echo "Unknown command: $cmd"
            echo "Run 'nftban portscan help' for usage"
            return 1
            ;;
    esac

    return 0
}

# =============================================================================
# LOGGING HELPER
# =============================================================================

# Log function (use nftban_log if available, otherwise echo)
if ! type -t nftban_log &>/dev/null; then
    nftban_log() {
        local level="$1"
        local module="$2"
        local message="$3"
        echo "[$(date -Iseconds)] [${level}] [${module}] ${message}" >&2
    }
fi

# =============================================================================
# LOG CHECKING FUNCTIONS (for CLI)
# =============================================================================

# Check/process logs for portscan detection
# Supports both traditional log files and journalctl
nftban_portscan_check() {
    local log_source="${1:-}"

    # Load classic module if needed
    if ! type -t nftban_portscan_classic_process_logs &>/dev/null; then
        local classic_module="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_portscan_classic.sh"
        if [[ -f "$classic_module" ]]; then
            # shellcheck source=/dev/null
            source "$classic_module" || return 1
            nftban_portscan_classic_load_config
            nftban_portscan_classic_init_state
        fi
    fi

    # If journalctl source, run the classic processor which handles it
    if [[ "$log_source" == "journalctl" ]]; then
        echo "Processing kernel logs from journalctl..."
        if type -t nftban_portscan_classic_process_logs &>/dev/null; then
            nftban_portscan_classic_process_logs
        else
            echo "ERROR: Classic portscan module not loaded" >&2
            return 1
        fi
    else
        # Traditional file-based processing
        echo "Processing log file: $log_source"
        if type -t nftban_portscan_classic_process_logs &>/dev/null; then
            # Override the log file temporarily (used by sourced module)
            # consumed by nftban_portscan_classic_process_logs()
            # shellcheck disable=SC2034
            PORTSCAN_CLASSIC_LOG_FILE="$log_source"
            nftban_portscan_classic_process_logs
        else
            echo "ERROR: Classic portscan module not loaded" >&2
            return 1
        fi
    fi

    # Show results
    local tracked=0
    local blocked=0
    # Check if arrays are declared (empty arrays still have count 0)
    if declare -p _PORTSCAN_CLASSIC_IP_PORTS &>/dev/null; then
        tracked="${#_PORTSCAN_CLASSIC_IP_PORTS[@]}"
    fi
    if declare -p _PORTSCAN_CLASSIC_IP_BLOCKED &>/dev/null; then
        blocked="${#_PORTSCAN_CLASSIC_IP_BLOCKED[@]}"
    fi
    echo ""
    echo "Detection Summary:"
    echo "  IPs tracked: $tracked"
    echo "  IPs blocked: $blocked"

    return 0
}

# Sync logs from journalctl to portscan log file
nftban_portscan_sync_logs() {
    local portscan_log="${NFTBAN_PORTSCAN_LOG:-${NFTBAN_LOG_DIR:-/var/log/nftban}/portscan.log}"
    local log_prefix="${PORTSCAN_CLASSIC_LOG_PREFIX:-NFTBAN_PORTSCAN:}"
    local time_range="${1:-24h}"

    # Ensure log directory exists
    local log_dir
    log_dir=$(dirname "$portscan_log")
    mkdir -p "$log_dir" 2>/dev/null || true

    echo "Syncing portscan logs from journalctl (last $time_range)..."

    # Extract portscan entries from journalctl and append to log
    if command -v journalctl &>/dev/null; then
        journalctl -k --since "$time_range ago" --no-pager 2>/dev/null | \
            grep "$log_prefix" >> "$portscan_log" 2>/dev/null || true
        echo "Logs synced to: $portscan_log"
    else
        echo "ERROR: journalctl not available" >&2
        return 1
    fi

    return 0
}

# =============================================================================
# AUTO-INITIALIZATION
# =============================================================================

# Initialize on source if not in library mode
if [[ "${NFTBAN_LIBRARY_MODE:-0}" != "1" ]]; then
    nftban_portscan_load_config
fi

# =============================================================================
# END OF PORTSCAN MODULE
# =============================================================================
