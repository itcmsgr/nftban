#!/usr/bin/env bash
# =============================================================================
# NFTBan - Portscan Protection Classic Mode
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="nftban_portscan_classic"
# meta:type="module"
# meta:header="Portscan Classic Mode"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Pure nftables-based portscan detection with journalctl support"
# meta:inventory.files="/var/lib/nftban/portscan-state.db"
# meta:inventory.binaries="nft,journalctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/portscan/classic.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-10-26"
# meta:updated_date="2026-01-11"
# =============================================================================
# shellcheck disable=SC1083  # Braces in nftables syntax are literal, not bash
# =============================================================================

set -Eeuo pipefail

# Prevent double sourcing
[[ -n "${_NFTBAN_PORTSCAN_CLASSIC_LOADED:-}" ]] && return 0
declare -g _NFTBAN_PORTSCAN_CLASSIC_LOADED=1

# Load fragment and IPC libraries for single-writer architecture
# See: ARCHITECTURE-NFT-POLICY.md
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nft_fragment.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_timestamp.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_file_utils.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_alert_throttle.sh" 2>/dev/null || true
# v1.229.x PORTSCAN-CURSOR: canonical incremental file reader (inode:offset,
# rotation/truncation, forward drain). Reused, never reimplemented — the same
# authority BotScan consumes. Guarded: absence degrades to the legacy bounded
# read, never to silence.
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_http_logs.sh" 2>/dev/null || true

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================

# Load classic mode configuration
nftban_portscan_classic_load_config() {
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/portscan/classic.conf"
    local local_config="${config_file%.conf}.conf.local"

    # Load base config
    if [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file" || true
    else
        _nftban_portscan_classic_log "WARN" "Config not found: $config_file"
    fi

    # Load local overrides
    if [[ -f "$local_config" ]]; then
        # shellcheck source=/dev/null
        # IMPL-1: ensure _source_local is defined wherever this file is loaded (env.sh idempotent)
        declare -F _source_local >/dev/null 2>&1 || source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/env.sh" 2>/dev/null || true
        _source_local "$local_config"
    fi

    # Set defaults
    : "${PORTSCAN_CLASSIC_LOG_PREFIX:=NFTBAN_PORTSCAN:}"
    : "${PORTSCAN_CLASSIC_LOG_FILE:=/var/log/kern.log}"
    : "${PORTSCAN_CLASSIC_MIN_PORTS:=5}"
    : "${PORTSCAN_CLASSIC_TIME_WINDOW:=60}"
    : "${PORTSCAN_CLASSIC_VERTICAL_PORTS:=10}"
    : "${PORTSCAN_CLASSIC_HORIZONTAL_TARGETS:=5}"
    : "${PORTSCAN_CLASSIC_ACTION:=block}"
    : "${PORTSCAN_CLASSIC_BAN_DEFAULT:=1800}"
    : "${PORTSCAN_CLASSIC_MAX_TRACKED_IPS:=10000}"
    : "${PORTSCAN_CLASSIC_LOG_RATE:=10/second}"
    : "${PORTSCAN_CLASSIC_LOG_BURST:=50}"
    : "${PORTSCAN_CLASSIC_STATE_FILE:=/var/lib/nftban/portscan-state.db}"

    return 0
}

# =============================================================================
# LOGGING
# =============================================================================

# Module output log file for portscan classic mode debug/info messages.
# IMPORTANT: This is the MODULE OUTPUT log, NOT the kernel input source.
# The kernel input source is PORTSCAN_CLASSIC_LOG_FILE (set in classic.conf line 32).
# These MUST be different variables — see portscan-log-collision bugfix.
PORTSCAN_CLASSIC_MODULE_LOG="${PORTSCAN_CLASSIC_MODULE_LOG:-${NFTBAN_LOG_DIR:-/var/log/nftban}/portscan-classic.log}"

_nftban_portscan_classic_log() {
    local level="$1"
    local message="$2"
    local log_file="${PORTSCAN_CLASSIC_MODULE_LOG:-${NFTBAN_LOG_DIR:-/var/log/nftban}/portscan-classic.log}"

    # Create log directory if needed
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || return 1

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CLASSIC] [$level] $message" >> "$log_file"
}

# =============================================================================
# MICRO-EVENT EMISSION (for stealth aggregation)
# =============================================================================
# Emits structured scan events for later aggregation by timer job.
# Uses journald (preferred) for rotation-safe, queryable storage.

_nftban_portscan_emit_event() {
    local src="$1"
    local dst="$2"
    local dpt="$3"
    local proto="$4"
    local flags="${5:-SYN}"
    local log_ts="${6:-}"

    # Use original log timestamp if provided, else current time
    local ts
    if [[ -n "$log_ts" ]]; then
        ts="$log_ts"
    else
        # Use timestamp library if available, fallback to date
        if declare -f nftban_timestamp_local &>/dev/null; then
            ts=$(nftban_timestamp_local)
        else
            ts=$(date -Iseconds)
        fi
    fi

    # Emit to journald with dedicated tag for easy querying
    # Query with: journalctl -t nftban-portscan-event --since "24 hours ago"
    if command -v logger &>/dev/null; then
        logger -t nftban-portscan-event "ts=${ts} src=${src} dst=${dst} proto=${proto} dpt=${dpt} flags=${flags}"
    fi

    # Also write to file for systems without journald queryable by tag
    local event_log="${NFTBAN_LOG_DIR:-/var/log/nftban}/portscan-events.log"
    mkdir -p "$(dirname "$event_log")" 2>/dev/null || return 1
    echo "ts=${ts} src=${src} dst=${dst} proto=${proto} dpt=${dpt} flags=${flags}" >> "$event_log"
}

# =============================================================================
# STARTUP SELF-CHECK
# =============================================================================
# Verifies nftables has the expected LOG prefix to prevent silent "no detections"

_nftban_portscan_verify_prefix() {
    local expected_prefix="${PORTSCAN_CLASSIC_LOG_PREFIX:-NFTBAN_PORTSCAN:}"
    local legacy_prefix="${PORTSCAN_CLASSIC_LOG_PREFIX_LEGACY:-nftban: portscan:}"

    # Check live ruleset for either prefix
    local ruleset
    # `|| return 0` reported the LOG-prefix as verified whenever the ruleset
    # could not be read. Not verified is its own outcome, not a pass.
    ruleset=$(nft list ruleset 2>/dev/null) || {
        _nftban_portscan_classic_log "WARN" "UNKNOWN: ruleset unreadable - LOG prefix NOT verified (this is not a pass)"
        return 2
    }
    if [[ -z "${ruleset//[[:space:]]/}" ]]; then
        _nftban_portscan_classic_log "WARN" "UNKNOWN: ruleset read returned no output - LOG prefix NOT verified"
        return 2
    fi

    if [[ "$ruleset" == *"$expected_prefix"* ]]; then
        _nftban_portscan_classic_log "INFO" "Prefix verified: $expected_prefix found in live ruleset"
        return 0
    elif [[ "$ruleset" == *"$legacy_prefix"* ]]; then
        _nftban_portscan_classic_log "WARN" "Legacy prefix in use: '$legacy_prefix' - parser will accept it, but consider reloading nftables"
        return 0
    else
        _nftban_portscan_classic_log "ERROR" "CRITICAL: No portscan LOG prefix found in live ruleset!"
        _nftban_portscan_classic_log "ERROR" "Expected '$expected_prefix' or '$legacy_prefix'"
        _nftban_portscan_classic_log "ERROR" "Portscan detection will NOT work until nftables rules are loaded"
        return 1
    fi
}

# =============================================================================
# STATE TRACKING
# =============================================================================

# In-memory tracking arrays (initialized empty to prevent unbound-variable
# errors under set -u when accessed before nftban_portscan_classic_init_state)
declare -gA _PORTSCAN_CLASSIC_IP_PORTS=()       # IP -> ports seen (space-separated)
declare -gA _PORTSCAN_CLASSIC_IP_TIMESTAMPS=()  # IP -> timestamps (space-separated)
declare -gA _PORTSCAN_CLASSIC_IP_TARGETS=()     # IP -> target IPs (space-separated)
declare -gA _PORTSCAN_CLASSIC_IP_BLOCKED=()     # IP -> block timestamp
declare -gA _PORTSCAN_CLASSIC_IP_BAN_COUNT=()   # IP -> number of times banned

# Initialize state tracking
nftban_portscan_classic_init_state() {
    _PORTSCAN_CLASSIC_IP_PORTS=()
    _PORTSCAN_CLASSIC_IP_TIMESTAMPS=()
    _PORTSCAN_CLASSIC_IP_TARGETS=()
    _PORTSCAN_CLASSIC_IP_BLOCKED=()
    _PORTSCAN_CLASSIC_IP_BAN_COUNT=()

    # Load persistent state if exists
    if [[ -f "${PORTSCAN_CLASSIC_STATE_FILE}" ]]; then
        nftban_portscan_classic_load_state
    fi

    return 0
}

# Save state to disk
nftban_portscan_classic_save_state() {
    local state_file="${PORTSCAN_CLASSIC_STATE_FILE}"
    local state_dir
    state_dir=$(dirname "$state_file")

    mkdir -p "$state_dir" 2>/dev/null || true

    {
        # Use timestamp library if available, fallback to date
        local state_ts
        if declare -f nftban_timestamp_local &>/dev/null; then
            state_ts=$(nftban_timestamp_local)
        else
            state_ts=$(date -Iseconds)
        fi
        echo "# NFTBan Portscan Classic State - ${state_ts}"
        echo "# Format: TYPE|IP|DATA"

        for ip in "${!_PORTSCAN_CLASSIC_IP_BLOCKED[@]}"; do
            echo "BLOCKED|${ip}|${_PORTSCAN_CLASSIC_IP_BLOCKED[$ip]}"
        done

        for ip in "${!_PORTSCAN_CLASSIC_IP_BAN_COUNT[@]}"; do
            echo "BAN_COUNT|${ip}|${_PORTSCAN_CLASSIC_IP_BAN_COUNT[$ip]}"
        done
    } > "${state_file}.tmp" && mv "${state_file}.tmp" "${state_file}"

    return 0
}

# Load state from disk
nftban_portscan_classic_load_state() {
    local state_file="${PORTSCAN_CLASSIC_STATE_FILE}"

    [[ -f "$state_file" ]] || return 0

    while IFS='|' read -r type ip data; do
        [[ "$type" =~ ^# ]] && continue
        [[ -z "$type" ]] && continue

        case "$type" in
            BLOCKED)
                _PORTSCAN_CLASSIC_IP_BLOCKED["$ip"]="$data"
                ;;
            BAN_COUNT)
                _PORTSCAN_CLASSIC_IP_BAN_COUNT["$ip"]="$data"
                ;;
        esac
    done < "$state_file"

    return 0
}

# =============================================================================
# NFTABLES RULES (via IPC - single-writer architecture)
# =============================================================================

# Create nftables chain for portscan detection
# Uses fragment renderer + IPC instead of direct nft calls
nftban_portscan_classic_create_chain() {
    _nftban_portscan_classic_log "INFO" "Creating portscan detection chain via IPC"

    # Chain creation is handled by the fragment in add_rules
    # This function is kept for compatibility but is now a no-op
    # The fragment includes "add chain" which is idempotent
    return 0
}

# Add logging rules for portscan detection
# Uses fragment renderer + IPC instead of direct nft calls
nftban_portscan_classic_add_rules() {
    _nftban_portscan_classic_log "INFO" "Adding portscan logging rules via IPC"

    # Check if IPC is available
    if ! type -t nft_fragment_render_portscan_classic &>/dev/null; then
        _nftban_portscan_classic_log "ERROR" "Fragment library not loaded"
        return 1
    fi

    # Render the fragment with current configuration
    local fragment_path
    fragment_path=$(nft_fragment_render_portscan_classic) || {
        _nftban_portscan_classic_log "ERROR" "Failed to render fragment"
        return 1
    }

    _nftban_portscan_classic_log "DEBUG" "Fragment rendered: $fragment_path"

    # Apply via IPC
    if ! nft_fragment_apply "$fragment_path"; then
        _nftban_portscan_classic_log "ERROR" "Failed to apply fragment via IPC"
        return 1
    fi

    _nftban_portscan_classic_log "INFO" "Portscan rules applied via IPC"
    return 0
}

# Add jump to portscan chain from input chain
# Uses fragment renderer + IPC instead of direct nft calls
nftban_portscan_classic_add_jump() {
    local table_ipv4="${PORTSCAN_NFT_TABLE_IPV4:-ip nftban}"
    local chain="${PORTSCAN_NFT_CHAIN:-portscan_detection}"

    _nftban_portscan_classic_log "INFO" "Adding jump to portscan chain via IPC"

    # Check if jump already exists (to avoid duplicates)
    if nft_fragment_has_jump "$table_ipv4" "$chain" 2>/dev/null; then
        _nftban_portscan_classic_log "DEBUG" "Jump rule already exists, skipping"
        return 0
    fi

    # Render and apply jump fragment
    local fragment_path
    fragment_path=$(nft_fragment_render_portscan_classic_jump) || {
        _nftban_portscan_classic_log "ERROR" "Failed to render jump fragment"
        return 1
    }

    if ! nft_fragment_apply "$fragment_path"; then
        _nftban_portscan_classic_log "ERROR" "Failed to apply jump fragment via IPC"
        return 1
    fi

    _nftban_portscan_classic_log "INFO" "Jump rules applied via IPC"
    return 0
}

# Remove portscan rules
# Uses fragment renderer + IPC instead of direct nft calls
nftban_portscan_classic_remove_rules() {
    _nftban_portscan_classic_log "INFO" "Removing portscan rules via IPC"

    # Render cleanup fragment
    local fragment_path
    fragment_path=$(nft_fragment_render_portscan_classic_cleanup) || {
        _nftban_portscan_classic_log "ERROR" "Failed to render cleanup fragment"
        return 1
    }

    # Apply via IPC
    if ! nft_fragment_apply "$fragment_path"; then
        _nftban_portscan_classic_log "ERROR" "Failed to apply cleanup fragment via IPC"
        return 1
    fi

    _nftban_portscan_classic_log "INFO" "Portscan rules removed via IPC"
    return 0
}

# =============================================================================
# LOG PARSING
# =============================================================================

# Find the correct log source
# Returns: file path OR "journalctl" for systemd journal
nftban_portscan_classic_find_log() {
    local log_file="${PORTSCAN_CLASSIC_LOG_FILE}"
    local alt_logs="${PORTSCAN_CLASSIC_LOG_FILE_ALT:-/var/log/messages,/var/log/syslog}"
    local use_journalctl="${PORTSCAN_CLASSIC_USE_JOURNALCTL:-auto}"

    # Check if journalctl is explicitly enabled or auto-detect
    if [[ "$use_journalctl" == "true" ]]; then
        if command -v journalctl &>/dev/null; then
            echo "journalctl"
            return 0
        fi
    fi

    # Check primary log file
    if [[ -f "$log_file" ]]; then
        echo "$log_file"
        return 0
    fi

    # Check alternatives
    IFS=',' read -ra alt_array <<< "$alt_logs"
    for alt in "${alt_array[@]}"; do
        alt=$(echo "$alt" | xargs)  # trim whitespace
        if [[ -f "$alt" ]]; then
            echo "$alt"
            return 0
        fi
    done

    # Default to syslog
    if [[ -f "/var/log/syslog" ]]; then
        echo "/var/log/syslog"
        return 0
    fi

    # Auto-detect: if no traditional log files exist and journalctl is available, use it
    # This handles systemd-only systems (Fedora, RHEL 8+, AlmaLinux 9, etc.)
    if [[ "$use_journalctl" == "auto" ]] && command -v journalctl &>/dev/null; then
        echo "journalctl"
        return 0
    fi

    return 1
}

# Parse a log line for portscan info
# Returns: SRC_IP|DST_IP|DST_PORT|PROTO
nftban_portscan_classic_parse_line() {
    local line="$1"
    local log_prefix="${PORTSCAN_CLASSIC_LOG_PREFIX:-NFTBAN_PORTSCAN:}"
    local log_prefix_legacy="${PORTSCAN_CLASSIC_LOG_PREFIX_LEGACY:-nftban: portscan:}"

    # Check if this is our log entry (literal substring match, not regex)
    # Accepts both new prefix (NFTBAN_PORTSCAN:) and legacy (nftban: portscan:)
    [[ "$line" == *"$log_prefix"* || "$line" == *"$log_prefix_legacy"* ]] || return 1

    local src_ip="" dst_ip="" dst_port="" proto=""

    # Extract source IP
    if [[ "$line" =~ SRC=([0-9a-fA-F.:]+) ]]; then
        src_ip="${BASH_REMATCH[1]}"
    fi

    # Extract destination IP
    if [[ "$line" =~ DST=([0-9a-fA-F.:]+) ]]; then
        dst_ip="${BASH_REMATCH[1]}"
    fi

    # Extract destination port
    if [[ "$line" =~ DPT=([0-9]+) ]]; then
        dst_port="${BASH_REMATCH[1]}"
    fi

    # Extract protocol
    if [[ "$line" =~ PROTO=([A-Z]+) ]]; then
        proto="${BASH_REMATCH[1]}"
    fi

    # Validate we got required fields
    [[ -n "$src_ip" && -n "$dst_port" ]] || return 1

    echo "${src_ip}|${dst_ip}|${dst_port}|${proto}"
    return 0
}

# Extract timestamp from syslog line (e.g., "Feb 07 00:54:21")
# Returns ISO format for micro-events
_nftban_portscan_extract_timestamp() {
    local line="$1"
    local ts=""

    # Match syslog format: "Feb 07 00:54:21" or ISO format from journalctl
    if [[ "$line" =~ ^([A-Z][a-z]{2}\ +[0-9]+\ [0-9:]+) ]]; then
        # Syslog format - convert to ISO (use current year)
        local syslog_ts="${BASH_REMATCH[1]}"
        ts=$(date -d "$syslog_ts" -Iseconds 2>/dev/null) || {
            if declare -f nftban_timestamp_local &>/dev/null; then
                ts=$(nftban_timestamp_local)
            else
                ts=$(date -Iseconds)
            fi
        }
    elif [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+) ]]; then
        # Already ISO format
        ts="${BASH_REMATCH[1]}"
    else
        # Use timestamp library if available, fallback to date
        if declare -f nftban_timestamp_local &>/dev/null; then
            ts=$(nftban_timestamp_local)
        else
            ts=$(date -Iseconds)
        fi
    fi
    echo "$ts"
}

# Process log entries and detect portscans
# =============================================================================
# v1.229.x PORTSCAN-CURSOR — replay elimination
# =============================================================================
# The window readers below used to re-read the SAME tail every cycle with no
# record of what had already been consumed, so each cycle re-emitted events it
# had emitted before. Measured on srv3: 4.6x window amplification (5000 lines ->
# 1079 unique), one line re-emitted 24x, portscan-events.log growing ~16 lines/s.
#
# DETECTION IS UNCHANGED. Thresholds read _IP_PORTS / _IP_TARGETS, and both
# deduplicate on insert, so replay never contributed to a threshold. The only
# timestamp-sensitive branch (strobe, duration < 10) was HARMED by replay, which
# appended a fresh cycle-time per replayed line and stretched the duration.
#
# TWO SOURCES, TWO EXISTING AUTHORITIES, NEITHER INVENTED HERE:
#   file     -> nftban_http_read_incremental (lib/nftban_http_logs.sh)
#   journald -> --after-cursor / --show-cursor (the LoginMon model,
#               core/nftban_login_classic.sh)
#
# ⚠ COMMIT SEMANTICS DIFFER BETWEEN THE TWO — stated plainly rather than
# papered over:
#
#   FILE     = AT-MOST-ONCE. nftban_http_read_incremental persists the new
#              offset immediately after writing bytes to stdout and before the
#              consumer has finished reading them. PortScan inherits that
#              established behaviour unchanged; it is what BotScan already
#              relies on. A crash mid-batch loses that batch.
#   JOURNALD = AT-LEAST-ONCE. This module owns that code, so the cursor is
#              committed ONLY after the batch has passed through the processing
#              loop. Advancing first would trade replay for permanently skipped
#              records, which is the worse failure.
: "${PORTSCAN_CLASSIC_CURSOR_ENABLED:=true}"
: "${PORTSCAN_CLASSIC_CURSOR_DIR:=${NFTBAN_DATA_DIR:-/var/lib/nftban}/portscan/log-cursors}"
: "${PORTSCAN_CLASSIC_CURSOR_MAX_BYTES:=1048576}"

# Report ONCE per cycle, before the read, when the unread backlog exceeds the
# incremental cap and older records will therefore be skipped.
#
# This READS the shared reader's state file (inode:offset) rather than owning it.
# The coupling is deliberate and one-directional: PortScan never WRITES that file,
# and every parse step below fails closed to "no warning". If the reader's format
# ever changes, this degrades to silence on the WARN only — it can never affect
# detection, and it can never invent a backlog that is not there.
_nftban_portscan_classic_warn_backlog() {
    local f="$1" size ino key state prev_ino prev_off backlog cap
    cap="${PORTSCAN_CLASSIC_CURSOR_MAX_BYTES:-1048576}"
    size="$(stat -c %s "$f" 2>/dev/null)" || return 0
    ino="$(stat -c %i "$f" 2>/dev/null)"  || return 0
    [[ "$size" =~ ^[0-9]+$ && "$ino" =~ ^[0-9]+$ ]] || return 0
    key="$(printf '%s' "$f" | tr '/' '_')"
    state="${PORTSCAN_CLASSIC_CURSOR_DIR}/${key}"
    # No cursor yet: the bounded current tail IS the intended first read, not a skip.
    [[ -r "$state" ]] || return 0
    IFS=':' read -r prev_ino prev_off < "$state" 2>/dev/null || return 0
    [[ "$prev_ino" =~ ^[0-9]+$ && "$prev_off" =~ ^[0-9]+$ ]] || return 0
    # Rotation is a different condition and is handled by the reader, not a backlog.
    [[ "$prev_ino" == "$ino" ]] || return 0
    backlog=$(( size - prev_off ))
    (( backlog > cap )) || return 0
    _nftban_portscan_classic_log "WARN" \
        "PortScan log backlog exceeds incremental read cap; older records will be skipped to preserve live-tail detection (path=${f} backlog_bytes=${backlog} cap_bytes=${cap})"
}

# Emit only records not yet consumed from a FILE source.
#
# READ MODE — tail-biased (the shared reader's DEFAULT). Do not re-enable
# NFTBAN_HTTP_LOG_READ_FORWARD here. Forward mode is correct for BotScan, which
# owns its spool and legitimately drains backlog, and WRONG for PortScan, which
# consumes an external live system log. Proven on srv3 (kern.log, 484 MB), three
# separate runtime failures came from that one line:
#
#   D1 CURSOR NEVER PERSISTED. Forward mode runs `tail -c +N file | head -c CAP`;
#      on a file larger than CAP, head exits early, tail takes SIGPIPE (141),
#      pipefail propagates it and errexit aborts the process-substitution subshell
#      BEFORE the reader persists its offset. maintenance.sh and this module both
#      run `set -Eeuo pipefail`, so in production the cursor was never written and
#      the whole feature was inert. Measured: set-e+pipefail -> cursor absent;
#      any other combination -> cursor present.
#   D2 BOF BOOTSTRAP. With no cursor, prev_ino=0 never matches the real inode, so
#      the reader treats first use as ROTATION and starts at byte 0. Forward mode
#      then drains CAP bytes per cycle: ~8 hours to reach the tail of a 484 MB log
#      that keeps growing, i.e. current scans unread. Replay traded for blindness.
#   D3 the original replay, left unfixed because D1 made the fix inert.
#
# Tail-biased mode fixes all three: `start` is clamped to size-CAP so the first
# read is the CURRENT tail and the offset is seeded at EOF; `tail` then emits
# ≈exactly CAP bytes so head does not close early and the SIGPIPE abort does not
# arise. Verified on the live file under `set -Eeuo pipefail` inside this exact
# pipeline: call 1 -> bounded current tail + cursor seeded at EOF, call 2 -> only
# the newly appended records, call 3 -> zero.
#
# The trade is explicit: falling more than CAP behind SKIPS the excess instead of
# lagging. For a live detector that is the correct side — stale records are worth
# less than current ones — but the skip must never be silent, hence the WARN above.
#
# Degradation ladder (a broken cursor must never look like "nothing happened"):
#   cursor disabled / reader absent -> legacy bounded read, silent (by design)
#   state dir unwritable            -> legacy bounded read + WARN
#   backlog > cap                   -> incremental read + WARN (records skipped)
_nftban_portscan_classic_read_file_source() {
    local f="$1"
    if [[ "${PORTSCAN_CLASSIC_CURSOR_ENABLED:-true}" == "true" ]] \
       && type -t nftban_http_read_incremental &>/dev/null; then
        if mkdir -p "$PORTSCAN_CLASSIC_CURSOR_DIR" 2>/dev/null; then
            _nftban_portscan_classic_warn_backlog "$f"
            NFTBAN_HTTP_LOG_OFFSET_DIR="$PORTSCAN_CLASSIC_CURSOR_DIR" \
            NFTBAN_HTTP_LOG_MAX_BYTES="$PORTSCAN_CLASSIC_CURSOR_MAX_BYTES" \
            nftban_http_read_incremental "$f"
            return 0
        fi
        _nftban_portscan_classic_log "WARN" \
            "cursor state dir not writable (${PORTSCAN_CLASSIC_CURSOR_DIR}) — falling back to bounded re-read; replay suppression INACTIVE"
    fi
    { tail -5000 "$f" 2>/dev/null || true; }
}

# Fetch a journald batch into $1, echoing the batch's end cursor on stdout.
# The cursor is NOT persisted here — the caller commits it only after the batch
# has been processed.
_nftban_portscan_classic_journal_fetch() {
    local out="$1" window="$2"
    local cursor_file="${PORTSCAN_CLASSIC_CURSOR_DIR}/journal.cursor"
    local -a jcmd=(journalctl -k --no-pager --show-cursor)
    local resumed=false

    if [[ "${PORTSCAN_CLASSIC_CURSOR_ENABLED:-true}" == "true" && -r "$cursor_file" ]]; then
        local saved
        saved=$(cat "$cursor_file" 2>/dev/null) || saved=""
        if [[ -n "$saved" ]]; then
            jcmd+=(--after-cursor="$saved")
            resumed=true
        else
            _nftban_portscan_classic_log "WARN" \
                "journal cursor file present but unreadable/empty — bounded re-read this cycle; replay suppression INACTIVE"
        fi
    fi
    # BOOTSTRAP (no cursor yet) is not a failure: bound by the time window
    # exactly as before, and this cycle establishes the cursor.
    [[ "$resumed" == "true" ]] || jcmd+=(--since "${window} seconds ago")

    "${jcmd[@]}" >"$out" 2>/dev/null || true
    # journalctl prints "-- cursor: <c>" as the final line under --show-cursor.
    sed -n 's/^-- cursor: //p' "$out" 2>/dev/null | tail -1
}

# Emit the journald records to process this cycle.
#   batch file present -> the cursor-resumed batch already fetched
#   batch file absent   -> legacy bounded read (degraded: replays, never blind)
_nftban_portscan_classic_journal_stream() {
    local batch="$1" window="$2"
    if [[ -n "$batch" && -r "$batch" ]]; then
        cat "$batch" 2>/dev/null || true
        return 0
    fi
    { journalctl -k --since "${window} seconds ago" --no-pager 2>/dev/null || true; }
}

# Commit a journald cursor atomically. Called ONLY after successful processing.
_nftban_portscan_classic_journal_commit() {
    local cursor="$1"
    [[ -n "$cursor" && "${PORTSCAN_CLASSIC_CURSOR_ENABLED:-true}" == "true" ]] || return 0
    local cursor_file="${PORTSCAN_CLASSIC_CURSOR_DIR}/journal.cursor"
    if ! mkdir -p "$PORTSCAN_CLASSIC_CURSOR_DIR" 2>/dev/null; then
        _nftban_portscan_classic_log "WARN" \
            "cannot create cursor dir — journal cursor NOT advanced; next cycle will re-read (replay, not loss)"
        return 0
    fi
    if printf '%s\n' "$cursor" > "${cursor_file}.tmp" 2>/dev/null; then
        mv -f "${cursor_file}.tmp" "$cursor_file" 2>/dev/null || \
            _nftban_portscan_classic_log "WARN" "journal cursor commit failed — next cycle re-reads this batch"
    else
        _nftban_portscan_classic_log "WARN" "journal cursor write failed — next cycle re-reads this batch"
    fi
    return 0
}

nftban_portscan_classic_process_logs() {
    # BUGFIX v1.78.1: Self-initialize config before using variables
    # Invariant: No module function may assume config is loaded by its caller
    nftban_portscan_classic_load_config 2>/dev/null || true

    local log_source
    log_source=$(nftban_portscan_classic_find_log) || {
        _nftban_portscan_classic_log "ERROR" "No log source found (checked /var/log/kern.log, /var/log/messages, /var/log/syslog, journalctl)"
        return 1
    }

    # All config variables use safe defaults for strict mode (set -u)
    local log_prefix="${PORTSCAN_CLASSIC_LOG_PREFIX:-NFTBAN_PORTSCAN:}"
    local log_prefix_legacy="${PORTSCAN_CLASSIC_LOG_PREFIX_LEGACY:-nftban: portscan:}"
    local time_window="${PORTSCAN_CLASSIC_TIME_WINDOW:-60}"
    local current_time
    # Use timestamp library if available, fallback to date
    if declare -f nftban_timestamp_unix &>/dev/null; then
        current_time=$(nftban_timestamp_unix)
    else
        current_time=$(date +%s)
    fi
    local cutoff_time
    cutoff_time=$((current_time - time_window))

    # Escape regex metacharacters in log prefixes for safe use in grep -E
    # This prevents injection attacks if config values contain special characters
    local log_prefix_escaped log_prefix_legacy_escaped
    log_prefix_escaped=$(printf '%s' "$log_prefix" | sed 's/[][\.|$(){}?+*^]/\\&/g')
    log_prefix_legacy_escaped=$(printf '%s' "$log_prefix_legacy" | sed 's/[][\.|$(){}?+*^]/\\&/g')

    # Read recent log entries - handle both file and journalctl
    # Accept both new and legacy prefixes for backwards compatibility
    # Use process substitution with direct commands instead of eval for safety
    if [[ "$log_source" == "journalctl" ]]; then
        # Use journalctl for kernel logs on systemd systems
        _nftban_portscan_classic_log "DEBUG" "Reading from journalctl (kernel logs)"
        local _ps_jbatch _ps_jcursor=""
        _ps_jbatch=$(mktemp "${TMPDIR:-/tmp}/nftban-portscan-journal.XXXXXX" 2>/dev/null) || _ps_jbatch=""
        if [[ -z "$_ps_jbatch" ]]; then
            # DEGRADED, NOT BLIND. An earlier version pointed the batch at
            # /dev/null here: it logged a warning and then processed nothing,
            # which is exactly the "cursor failure looks like nothing happened"
            # outcome this lane exists to prevent. The stream helper now performs
            # the legacy bounded read directly, so detection continues with
            # replay (the old behaviour) rather than silently stopping.
            _nftban_portscan_classic_log "WARN" \
                "cannot create journal batch file — falling back to bounded re-read; replay suppression INACTIVE this cycle"
        else
            _ps_jcursor=$(_nftban_portscan_classic_journal_fetch "$_ps_jbatch" "$time_window")
        fi
        while IFS= read -r line; do
            local parsed
            parsed=$(nftban_portscan_classic_parse_line "$line") || continue

            IFS='|' read -r src_ip dst_ip dst_port proto <<< "$parsed"

            # Skip whitelisted IPs - HARD GATE (no state accumulation)
            if nftban_portscan_classic_is_whitelisted "$src_ip"; then
                continue
            fi

            # Trusted-monitoring-flow exclusion: suppress EVENT GENERATION (no event,
            # no spool/state entry) ONLY for an exactly-declared, within-rate trusted
            # flow tuple. Any dimension mismatch or an over-rate matching flow falls
            # through to the normal emit+record path (abnormal behaviour stays visible).
            # Firewall acceptance, ban authority, whitelist, and the classifier are unchanged.
            if type -t nftban_portscan_trusted_flow_suppress &>/dev/null \
               && nftban_portscan_trusted_flow_suppress "$src_ip" "$dst_ip" "$dst_port" "$proto"; then
                continue
            fi

            # Emit micro-event for stealth aggregation (uses original log timestamp)
            local log_ts
            log_ts=$(_nftban_portscan_extract_timestamp "$line")
            _nftban_portscan_emit_event "$src_ip" "$dst_ip" "$dst_port" "$proto" "SYN" "$log_ts"

            # Record this connection for realtime detection
            nftban_portscan_classic_record_connection "$src_ip" "$dst_ip" "$dst_port" "$current_time"

        # v1.229.x PORTSCAN-CURSOR: resume after the last COMMITTED cursor so
        # already-consumed records are not re-emitted. tail caps retained as a
        # volume bound. The batch is buffered because the cursor must not be
        # committed until the loop below has actually processed it.
        # NOTE the braces around grep: `grep ... || true | { tail ...; }` parses as
        # `grep || (true | tail)`, which silently DROPS the tail cap whenever grep
        # matches. Bracing keeps the cap on the match path, as the file branch does.
        done < <({ _nftban_portscan_classic_journal_stream "$_ps_jbatch" "$time_window"; } | { tail -5000 || true; } | { grep -E -- "${log_prefix_escaped}|${log_prefix_legacy_escaped}" 2>/dev/null || true; } | { tail -1000 || true; })

        # COMMIT-AFTER-PROCESSING. Reaching this point means the loop drained
        # without aborting the function, so the cursor may advance. Advancing
        # before this would convert replay into permanently skipped records.
        _nftban_portscan_classic_journal_commit "$_ps_jcursor"
        [[ -n "$_ps_jbatch" ]] && rm -f "$_ps_jbatch" 2>/dev/null || true
    else
        # grep returns 1 when no matches found - use || true to handle this
        _nftban_portscan_classic_log "DEBUG" "Reading from file: $log_source"
        while IFS= read -r line; do
            local parsed
            parsed=$(nftban_portscan_classic_parse_line "$line") || continue

            IFS='|' read -r src_ip dst_ip dst_port proto <<< "$parsed"

            # Skip whitelisted IPs - HARD GATE (no state accumulation)
            if nftban_portscan_classic_is_whitelisted "$src_ip"; then
                continue
            fi

            # Trusted-monitoring-flow exclusion: suppress EVENT GENERATION (no event,
            # no spool/state entry) ONLY for an exactly-declared, within-rate trusted
            # flow tuple. Any dimension mismatch or an over-rate matching flow falls
            # through to the normal emit+record path (abnormal behaviour stays visible).
            # Firewall acceptance, ban authority, whitelist, and the classifier are unchanged.
            if type -t nftban_portscan_trusted_flow_suppress &>/dev/null \
               && nftban_portscan_trusted_flow_suppress "$src_ip" "$dst_ip" "$dst_port" "$proto"; then
                continue
            fi

            # Emit micro-event for stealth aggregation (uses original log timestamp)
            local log_ts
            log_ts=$(_nftban_portscan_extract_timestamp "$line")
            _nftban_portscan_emit_event "$src_ip" "$dst_ip" "$dst_port" "$proto" "SYN" "$log_ts"

            # Record this connection for realtime detection
            nftban_portscan_classic_record_connection "$src_ip" "$dst_ip" "$dst_port" "$current_time"

        # v1.82 Step 5: Performance fix for high-volume log files.
        # Previously: grep entire file then tail -1000 (scans 300K+ lines).
        # Now: tail -5000 first (bound input), then grep (filter matches),
        # then tail -1000 (limit output). This caps processing regardless
        # of total file size. 5000 raw lines ≈ covers several minutes of
        # high-volume portscan logging with margin.
        # SIGPIPE fix: { cmd || true; } prevents pipefail exit 141.
        # v1.229.x PORTSCAN-CURSOR: emit only bytes not yet consumed (inode:offset
        # via the canonical incremental reader). AT-MOST-ONCE — see the commit
        # semantics note above. tail caps retained as a volume bound.
        done < <({ _nftban_portscan_classic_read_file_source "$log_source"; } | { tail -5000 || true; } | { grep -E -- "${log_prefix_escaped}|${log_prefix_legacy_escaped}" 2>/dev/null || true; } | { tail -1000 || true; })
    fi

    # Analyze and block if needed
    nftban_portscan_classic_analyze_all

    # Save state for progressive banning persistence
    nftban_portscan_classic_save_state

    return 0
}

# =============================================================================
# CONNECTION TRACKING
# =============================================================================

# Record a connection attempt
nftban_portscan_classic_record_connection() {
    local src_ip="$1"
    local dst_ip="$2"
    local dst_port="$3"
    local timestamp="$4"

    local max_tracked="${PORTSCAN_CLASSIC_MAX_TRACKED_IPS}"

    # Check if we're tracking too many IPs
    if [[ ${#_PORTSCAN_CLASSIC_IP_PORTS[@]} -ge $max_tracked ]]; then
        nftban_portscan_classic_cleanup_old_entries
    fi

    # Add port to tracked list for this IP
    local current_ports="${_PORTSCAN_CLASSIC_IP_PORTS[$src_ip]:-}"
    local port_pattern=" ${dst_port} "
    if [[ ! " $current_ports " =~ $port_pattern ]]; then
        _PORTSCAN_CLASSIC_IP_PORTS["$src_ip"]="${current_ports} ${dst_port}"
    fi

    # Add timestamp
    local current_timestamps="${_PORTSCAN_CLASSIC_IP_TIMESTAMPS[$src_ip]:-}"
    _PORTSCAN_CLASSIC_IP_TIMESTAMPS["$src_ip"]="${current_timestamps} ${timestamp}"

    # Add target if different from self
    if [[ -n "$dst_ip" ]]; then
        local current_targets="${_PORTSCAN_CLASSIC_IP_TARGETS[$src_ip]:-}"
        local target_pattern=" ${dst_ip} "
        if [[ ! " $current_targets " =~ $target_pattern ]]; then
            _PORTSCAN_CLASSIC_IP_TARGETS["$src_ip"]="${current_targets} ${dst_ip}"
        fi
    fi

    return 0
}

# Cleanup old tracking entries
nftban_portscan_classic_cleanup_old_entries() {
    local time_window="${PORTSCAN_CLASSIC_TIME_WINDOW}"
    local current_time
    # Use timestamp library if available, fallback to date
    if declare -f nftban_timestamp_unix &>/dev/null; then
        current_time=$(nftban_timestamp_unix)
    else
        current_time=$(date +%s)
    fi
    local cutoff_time
    cutoff_time=$((current_time - time_window))

    for ip in "${!_PORTSCAN_CLASSIC_IP_TIMESTAMPS[@]}"; do
        local timestamps="${_PORTSCAN_CLASSIC_IP_TIMESTAMPS[$ip]}"
        local new_timestamps=""
        local has_recent=false

        # Use read -ra to properly split into array. v1.156 PR-D: timestamps
        # are space-joined (see assignment "${current_timestamps} ${timestamp}"
        # at the tracker), so split on whitespace EXPLICITLY. A bare read -ra
        # would inherit a strict IFS=$'\n\t' (strict.sh) from the caller and
        # collapse the whole string into one element — same bug family as the
        # v1.152 feeds-select fix.
        local -a ts_array
        IFS=$' \t\n' read -ra ts_array <<< "$timestamps"

        for ts in "${ts_array[@]}"; do
            # Skip empty or non-numeric entries
            [[ -z "$ts" || ! "$ts" =~ ^[0-9]+$ ]] && continue

            if [[ $ts -ge $cutoff_time ]]; then
                new_timestamps="${new_timestamps} ${ts}"
                has_recent=true
            fi
        done

        if [[ "$has_recent" == "true" ]]; then
            _PORTSCAN_CLASSIC_IP_TIMESTAMPS["$ip"]="$new_timestamps"
        else
            # No recent activity, remove tracking
            unset "_PORTSCAN_CLASSIC_IP_PORTS[$ip]"
            unset "_PORTSCAN_CLASSIC_IP_TIMESTAMPS[$ip]"
            unset "_PORTSCAN_CLASSIC_IP_TARGETS[$ip]"
        fi
    done

    return 0
}

# =============================================================================
# SCAN DETECTION
# =============================================================================

# Analyze all tracked IPs for portscan behavior
nftban_portscan_classic_analyze_all() {
    local min_ports="${PORTSCAN_CLASSIC_MIN_PORTS}"

    for ip in "${!_PORTSCAN_CLASSIC_IP_PORTS[@]}"; do
        # Skip already blocked IPs
        [[ -n "${_PORTSCAN_CLASSIC_IP_BLOCKED[$ip]:-}" ]] && continue

        local scan_type
        # detect_scan_type returns 1 if no scan detected - that's normal behavior
        scan_type=$(nftban_portscan_classic_detect_scan_type "$ip") || true

        if [[ -n "$scan_type" ]]; then
            nftban_portscan_classic_handle_detection "$ip" "$scan_type"
        fi
    done

    return 0
}

# v1.204 PORTSCAN GO-CLASSIFIER: read the live known-open service-port set
# (tcp_ports_in) so the Go classifier can EXCLUDE those ports from scan scoring.
# These ports are allowed context, never scan evidence.
_nftban_portscan_classic_known_open_ports() {
    local fam_table="${NFTBAN_TABLE_IPV4:-ip nftban}"
    nft list set ${fam_table} tcp_ports_in 2>/dev/null \
        | tr ',{}' '\n' | grep -oE '[0-9]+' | sort -un | tr '\n' ' '
}

# v1.204: obtain the TYPED Go verdict for one IP. Builds the per-IP request JSON
# (events from the tracked ports/target/timestamps + known-open set + thresholds),
# pipes it to `nftban-core portscan-classify`, logs the old-vs-new shadow line, and
# echoes the Go scan_type (empty when action=allow). Pure decision call — the shell
# (root) remains the log reader; nftban-core does not read logs or write sets.
_nftban_portscan_classic_go_verdict() {
    local ip="$1" family="${2:-ipv4}"
    local core_bin="${NFTBAN_CORE_BIN:-/usr/lib/nftban/bin/nftban-core}"
    [[ -x "$core_bin" ]] || { echo ""; return 0; }

    local ports="${_PORTSCAN_CLASSIC_IP_PORTS[$ip]:-}"
    local targets="${_PORTSCAN_CLASSIC_IP_TARGETS[$ip]:-}"
    local timestamps="${_PORTSCAN_CLASSIC_IP_TIMESTAMPS[$ip]:-}"
    local one_target; one_target=$(echo "$targets" | tr ' ' '\n' | grep -v '^$' | head -1)
    local known_open; known_open=$(_nftban_portscan_classic_known_open_ports)

    # Build events[] (pair each port with the IP's first target + a timestamp).
    local -a parr tarr
    IFS=$' \t\n' read -ra parr <<< "$ports"
    IFS=$' \t\n' read -ra tarr <<< "$timestamps"
    local events="" i=0 sep=""
    for p in "${parr[@]}"; do
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        local ts="${tarr[$i]:-0}"; [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
        events+="${sep}{\"port\":${p},\"target\":\"${one_target}\",\"ts\":${ts}}"; sep=","
        i=$((i+1))
    done
    local ko_json; ko_json=$(echo "$known_open" | tr ' ' '\n' | grep -E '^[0-9]+$' | paste -sd, -)

    local req
    req=$(printf '{"ip":"%s","family":"%s","known_open_ports":[%s],"block_range":%s,"vertical_ports":%s,"horizontal_targets":%s,"strobe_ports":%s,"strobe_window_sec":10,"events":[%s]}' \
        "$ip" "$family" "${ko_json:-}" "${PORTSCAN_CLASSIC_BLOCK_RANGE:-0}" "${PORTSCAN_CLASSIC_VERTICAL_PORTS:-0}" \
        "${PORTSCAN_CLASSIC_HORIZONTAL_TARGETS:-0}" "${PORTSCAN_CLASSIC_STROBE_PORTS:-0}" "$events")

    local verdict; verdict=$(printf '%s' "$req" | "$core_bin" portscan-classify 2>/dev/null) || { echo ""; return 0; }
    local scan_type action kc uc
    scan_type=$(printf '%s' "$verdict" | grep -oE '"scan_type":"[^"]*"' | cut -d'"' -f4)
    action=$(printf '%s' "$verdict" | grep -oE '"action":"[^"]*"' | cut -d'"' -f4)
    kc=$(printf '%s' "$verdict" | grep -oE '"known_open_count":[0-9]+' | grep -oE '[0-9]+')
    uc=$(printf '%s' "$verdict" | grep -oE '"unexpected_count":[0-9]+' | grep -oE '[0-9]+')

    # Shadow line: old shell verdict (total-port-count heuristic) vs new Go verdict.
    local old_pc; old_pc=$(echo "$ports" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l)
    local old_v="none"
    [[ ${old_pc:-0} -ge ${PORTSCAN_CLASSIC_VERTICAL_PORTS:-99999} || ${old_pc:-0} -ge ${PORTSCAN_CLASSIC_STROBE_PORTS:-99999} ]] && old_v="ban-capable"
    _nftban_portscan_classic_log "INFO" "PORTSCAN_SHADOW old=${old_v} new=${scan_type:-none} known_open_count=${kc:-0} unexpected_count=${uc:-0} family=${family} src_ip=${ip} action=${action:-allow}"

    [[ "$action" == "ban" ]] && echo "$scan_type" || echo ""
}

# Detect what type of scan an IP is performing
nftban_portscan_classic_detect_scan_type() {
    local ip="$1"

    # v1.204 PORTSCAN GO-CLASSIFIER mode gate (default shadow = safe, no behavior
    # change; 'go' enforces the typed known-open-aware verdict [the FP fix]; 'shell'
    # = legacy). Shadow/go both emit the old-vs-new shadow audit line.
    local classifier_mode="${PORTSCAN_CLASSIC_CLASSIFIER:-shadow}"
    local family="ipv4"; [[ "$ip" == *:* ]] && family="ipv6"
    if [[ "$classifier_mode" == "go" || "$classifier_mode" == "shadow" ]]; then
        local go_scan; go_scan=$(_nftban_portscan_classic_go_verdict "$ip" "$family")
        if [[ "$classifier_mode" == "go" ]]; then
            # Authoritative: the Go classifier owns the verdict (known-open excluded).
            [[ -n "$go_scan" ]] && { echo "$go_scan"; return 0; }
            return 1
        fi
        # shadow: comparison logged above; legacy shell logic below still enforces.
    fi

    local ports="${_PORTSCAN_CLASSIC_IP_PORTS[$ip]:-}"
    local targets="${_PORTSCAN_CLASSIC_IP_TARGETS[$ip]:-}"

    # Count unique ports
    local port_count
    port_count=$(echo "$ports" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l)

    # Count unique targets
    local target_count
    target_count=$(echo "$targets" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l)

    local vertical_threshold="${PORTSCAN_CLASSIC_VERTICAL_PORTS}"
    local horizontal_threshold="${PORTSCAN_CLASSIC_HORIZONTAL_TARGETS}"
    local block_threshold="${PORTSCAN_CLASSIC_BLOCK_RANGE}"
    local strobe_ports="${PORTSCAN_CLASSIC_STROBE_PORTS}"

    # Check for block scan (scanning port ranges)
    if [[ $port_count -ge $block_threshold ]]; then
        echo "block"
        return 0
    fi

    # Check for vertical scan (many ports on one target)
    if [[ $port_count -ge $vertical_threshold && $target_count -le 1 ]]; then
        echo "vertical"
        return 0
    fi

    # Check for horizontal scan (same ports across many targets)
    if [[ $target_count -ge $horizontal_threshold && $port_count -le 3 ]]; then
        echo "horizontal"
        return 0
    fi

    # Check for strobe scan (rapid scanning of common ports)
    if [[ $port_count -ge $strobe_ports ]]; then
        local timestamps="${_PORTSCAN_CLASSIC_IP_TIMESTAMPS[$ip]}"
        # Convert to array, filtering empty elements. v1.156 PR-D: timestamps
        # are space-joined, so split on whitespace EXPLICITLY — a bare read -ra
        # would collapse them into one element under a strict IFS=$'\n\t' caller.
        local -a ts_array
        IFS=$' \t\n' read -ra ts_array <<< "$timestamps"
        local ts_count=${#ts_array[@]}

        if [[ $ts_count -gt 1 ]]; then
            # Get first and last timestamps (ensure single values)
            local first_ts="${ts_array[0]}"
            local last_ts="${ts_array[$((ts_count-1))]}"

            # Validate timestamps are numeric before arithmetic
            if [[ "$first_ts" =~ ^[0-9]+$ ]] && [[ "$last_ts" =~ ^[0-9]+$ ]]; then
                local duration=$((last_ts - first_ts))

                # If many connections in short time
                if [[ $duration -lt 10 && $port_count -ge $strobe_ports ]]; then
                    echo "strobe"
                    return 0
                fi
            fi
        fi
    fi

    # Check minimum port threshold
    local min_ports="${PORTSCAN_CLASSIC_MIN_PORTS}"
    if [[ $port_count -ge $min_ports ]]; then
        # v1.149.0 false-ban hardening: the "generic" remainder here is non-rapid
        # (rapid low-port bursts were already caught by the strobe path above),
        # single-target (horizontal caught multi-target above), with MIN_PORTS..
        # (VERTICAL-1) distinct ports — the bursty/NAT/admin multi-service profile.
        # Require DIVERSITY corroboration before this auto-bans; otherwise downgrade
        # to log/alert only so a legitimate source is not banned on port-count alone.
        if _nftban_portscan_classic_generic_corroborated "$port_count"; then
            echo "generic"
        else
            echo "generic-observe"
        fi
        return 0
    fi

    return 1
}

# v1.149.0 — corroboration gate for the "generic" classification (classic mode
# only; suricata mode bans on IDS-alert score and is left untouched). Returns 0
# (corroborated → may ban) when the distinct-port count reaches the corroboration
# floor (default: the vertical-scan threshold), else 1 (downgrade to log/alert).
# Corroboration is diversity-only by design: sensitive-port or event-volume
# corroboration would re-ban the admin/NAT case this hardening exists to prevent.
_nftban_portscan_classic_generic_corroborated() {
    local port_count="$1"
    # Disabled → restore pre-v1.149 behavior (generic bans at MIN_PORTS).
    [[ "${PORTSCAN_CLASSIC_GENERIC_CORROBORATE:-true}" != "true" ]] && return 0
    local floor="${PORTSCAN_CLASSIC_GENERIC_CORROBORATE_PORTS:-}"
    [[ -z "$floor" ]] && floor="${PORTSCAN_CLASSIC_VERTICAL_PORTS:-10}"
    [[ "$port_count" -ge "$floor" ]] && return 0
    return 1
}

# =============================================================================
# BLOCKING
# =============================================================================

# Handle detected portscan
nftban_portscan_classic_handle_detection() {
    local ip="$1"
    local scan_type="$2"

    local action="${PORTSCAN_CLASSIC_ACTION}"

    # v1.149.0: an uncorroborated "generic" detection is observe-only — it is
    # logged/alerted but NEVER auto-banned, regardless of PORTSCAN_CLASSIC_ACTION.
    # This is the false-ban guard for bursty/NAT/admin multi-service traffic.
    if [[ "$scan_type" == "generic-observe" ]]; then
        _nftban_portscan_classic_log "INFO" "Observed uncorroborated generic activity from ${ip} (below diversity floor — NOT banned; set PORTSCAN_CLASSIC_GENERIC_CORROBORATE=false to restore legacy banning)"
        if [[ "$action" == "alert" || "$action" == "block_and_alert" ]]; then
            nftban_portscan_classic_send_alert "$ip" "generic-observe"
        fi
        return 0
    fi

    _nftban_portscan_classic_log "WARN" "Detected ${scan_type} scan from ${ip}"

    case "$action" in
        block)
            nftban_portscan_classic_block_ip "$ip" "$scan_type"
            ;;
        log)
            _nftban_portscan_classic_log "INFO" "Logged ${scan_type} scan from ${ip} (no block)"
            ;;
        alert)
            nftban_portscan_classic_send_alert "$ip" "$scan_type"
            ;;
        block_and_alert)
            nftban_portscan_classic_block_ip "$ip" "$scan_type"
            nftban_portscan_classic_send_alert "$ip" "$scan_type"
            ;;
    esac

    return 0
}

# Block an IP
# Uses IPC instead of direct nft calls (single-writer architecture)
nftban_portscan_classic_block_ip() {
    local ip="$1"
    local scan_type="$2"

    # Determine ban duration
    local duration
    case "$scan_type" in
        vertical)   duration="${PORTSCAN_CLASSIC_BAN_VERTICAL:-1800}" ;;
        horizontal) duration="${PORTSCAN_CLASSIC_BAN_HORIZONTAL:-3600}" ;;
        block)      duration="${PORTSCAN_CLASSIC_BAN_BLOCK:-7200}" ;;
        strobe)     duration="${PORTSCAN_CLASSIC_BAN_STROBE:-600}" ;;
        *)          duration="${PORTSCAN_CLASSIC_BAN_DEFAULT:-1800}" ;;
    esac

    # Progressive banning
    if [[ "${PORTSCAN_CLASSIC_PROGRESSIVE_BAN:-true}" == "true" ]]; then
        local ban_count="${_PORTSCAN_CLASSIC_IP_BAN_COUNT[$ip]:-0}"
        local multiplier="${PORTSCAN_CLASSIC_PROGRESSIVE_MULTIPLIER:-2}"
        local max_duration="${PORTSCAN_CLASSIC_PROGRESSIVE_MAX:-86400}"

        if [[ $ban_count -gt 0 ]]; then
            duration=$((duration * multiplier * ban_count))
            [[ $duration -gt $max_duration ]] && duration=$max_duration
        fi

        _PORTSCAN_CLASSIC_IP_BAN_COUNT["$ip"]=$((ban_count + 1))
    fi

    # Use nftban ban command if available (preferred - handles all logic)
    if type -t nftban_ban &>/dev/null; then
        nftban_ban "$ip" \
            --timeout "$duration" \
            --reason "portscan:${scan_type}" \
            --source "portscan-classic"
    # Fall back to IPC directly (single-writer architecture)
    elif type -t nft_ipc_ban &>/dev/null; then
        nft_ipc_ban "$ip" "$duration" "portscan:${scan_type}" "portscan-classic"
    else
        _nftban_portscan_classic_log "ERROR" "No ban method available (IPC library not loaded)"
        return 1
    fi

    # Record block - use timestamp library if available
    if declare -f nftban_timestamp_unix &>/dev/null; then
        _PORTSCAN_CLASSIC_IP_BLOCKED["$ip"]=$(nftban_timestamp_unix)
    else
        _PORTSCAN_CLASSIC_IP_BLOCKED["$ip"]=$(date +%s)
    fi

    _nftban_portscan_classic_log "INFO" "Blocked ${ip} for ${duration}s (${scan_type} scan)"

    return 0
}

# Send alert notification
nftban_portscan_classic_send_alert() {
    local ip="$1"
    local scan_type="$2"

    # Check alert throttling (avoid alert storms for same IP/scan_type)
    # Throttle per IP to prevent flooding on repeated scans from same source
    local throttle_key="portscan_${scan_type}_${ip//[^a-zA-Z0-9]/_}"
    local throttle_seconds="${PORTSCAN_ALERT_THROTTLE_SECONDS:-3600}"

    if declare -f nftban_should_alert &>/dev/null; then
        if ! nftban_should_alert "$throttle_key" "$throttle_seconds"; then
            _nftban_portscan_classic_log "DEBUG" "Alert throttled for ${ip} (${scan_type})"
            return 0
        fi
    fi

    local ports="${_PORTSCAN_CLASSIC_IP_PORTS[$ip]:-unknown}"
    local port_count
    port_count=$(echo "$ports" | tr ' ' '\n' | grep -v '^$' | wc -l)

    local message="Portscan detected: ${scan_type} scan from ${ip} (${port_count} ports)"

    # Email notification via NFTBan unified mail mechanism
    # Per-module override: PORTSCAN_NOTIFY_EMAIL_TO, fallback: NFTBAN_MAIL_RECIPIENT
    if [[ "${PORTSCAN_NOTIFY_EMAIL:-false}" == "true" ]]; then
        local recipient="${PORTSCAN_NOTIFY_EMAIL_TO:-${NFTBAN_MAIL_RECIPIENT:-}}"
        if [[ -n "$recipient" ]]; then
            NFTBAN_MAIL_SUBJECT_OVERRIDE="NFTBan Port Scan Alert" nftban_mail_send "$message" "$recipient" 2>/dev/null || true
        fi
    fi

    # Webhook notification
    if [[ "${PORTSCAN_NOTIFY_WEBHOOK:-false}" == "true" && -n "${PORTSCAN_NOTIFY_WEBHOOK_URL:-}" ]]; then
        curl -s -X POST "${PORTSCAN_NOTIFY_WEBHOOK_URL}" \
            -H "Content-Type: application/json" \
            -d "{\"type\":\"portscan\",\"ip\":\"${ip}\",\"scan_type\":\"${scan_type}\",\"ports\":${port_count}}" \
            2>/dev/null || true
    fi

    return 0
}

# =============================================================================
# WHITELIST
# =============================================================================

# Check if IP is whitelisted
nftban_portscan_classic_is_whitelisted() {
    local ip="$1"

    # Localhost
    if [[ "${PORTSCAN_WHITELIST_LOCALHOST:-true}" == "true" ]]; then
        case "$ip" in
            127.*|::1|0.0.0.0) return 0 ;;
        esac
    fi

    # Private networks
    if [[ "${PORTSCAN_WHITELIST_PRIVATE:-true}" == "true" ]]; then
        case "$ip" in
            10.*|172.1[6-9].*|172.2[0-9].*|172.3[0-1].*|192.168.*) return 0 ;;
            fc*|fd*) return 0 ;;  # IPv6 private
        esac
    fi

    # Central whitelist check (SINGLE SOURCE OF TRUTH)
    # Uses nft_schema.sh nftban_is_whitelisted() which checks:
    # 1. nftables whitelist sets (whitelist_ipv4/whitelist_ipv6)
    # 2. /etc/nftban/whitelist.d/*.conf files
    if declare -f nftban_is_whitelisted &>/dev/null; then
        nftban_is_whitelisted "$ip" && return 0
    fi

    return 1
}

# =============================================================================
# MODULE LIFECYCLE
# =============================================================================

# Enable classic portscan detection
nftban_portscan_classic_enable() {
    _nftban_portscan_classic_log "INFO" "Enabling classic portscan detection"

    # Load configuration
    nftban_portscan_classic_load_config

    # Initialize state
    nftban_portscan_classic_init_state

    # Create nftables chain and rules
    nftban_portscan_classic_create_chain
    nftban_portscan_classic_add_rules
    nftban_portscan_classic_add_jump

    # Verify prefix is in live ruleset (prevents silent "no detections")
    _nftban_portscan_verify_prefix || {
        _nftban_portscan_classic_log "WARN" "Prefix verification failed - detection may not work"
    }

    _nftban_portscan_classic_log "INFO" "Classic portscan detection enabled"
    return 0
}

# Disable classic portscan detection
nftban_portscan_classic_disable() {
    _nftban_portscan_classic_log "INFO" "Disabling classic portscan detection"

    # Save state before disabling
    nftban_portscan_classic_save_state

    # Remove rules
    nftban_portscan_classic_remove_rules

    _nftban_portscan_classic_log "INFO" "Classic portscan detection disabled"
    return 0
}

# Process pending detections (called periodically)
nftban_portscan_classic_run() {
    # Process logs
    nftban_portscan_classic_process_logs

    # Cleanup old entries
    nftban_portscan_classic_cleanup_old_entries

    return 0
}

# =============================================================================
# STEALTH AGGREGATION (Runs every 15 min via maintenance timer)
# =============================================================================
# Catches low-and-slow scans that evade realtime detection.
# Uses scoring from nftban_portscan_suricata.sh patterns.

# Sensitive ports (higher weight in scoring)
# Sensitive ports - higher weight in scoring (can be overridden by config)
: "${PORTSCAN_SENSITIVE_PORTS:=22,23,25,53,80,110,111,135,139,143,389,443,445,465,512,513,514,587,631,873,902,1080,1433,1521,2049,2375,3306,3389,5000,5432,5601,5900,6379,8080,8443,9000,9200,9300,11211,27017}"

# Aggregation function - called by maintenance.sh every 15 min
nftban_portscan_aggregate() {
    local since="${1:---since 24h}"
    local do_ban=false
    [[ "$*" == *"--ban"* ]] && do_ban=true

    _nftban_portscan_classic_log "INFO" "Starting stealth aggregation (since=$since, ban=$do_ban)"

    # Load config
    nftban_portscan_classic_load_config 2>/dev/null || true

    # Thresholds for stealth detection (higher than realtime = 99% certainty)
    local min_events="${PORTSCAN_AGG_MIN_EVENTS:-8}"
    local min_unique_ports="${PORTSCAN_AGG_MIN_UNIQUE_PORTS:-20}"
    local score_threshold="${PORTSCAN_AGG_SCORE_THRESHOLD:-25}"

    # Read events from journald (preferred) or file.
    # v1.82: Added tail -10000 cap on journalctl output to prevent timeout
    # on high-volume hosts (monitor: 1.4M+ journal entries caused SIGTERM).
    local events=""
    if command -v journalctl &>/dev/null; then
        events=$(journalctl -t nftban-portscan-event --since "24 hours ago" --no-pager 2>/dev/null | { grep "src=" || true; } | { tail -10000 || true; })
    fi

    # Fallback to file if journald empty
    if [[ -z "$events" ]] && [[ -f "${NFTBAN_LOG_DIR:-/var/log/nftban}/portscan-events.log" ]]; then
        events=$({ tail -10000 "${NFTBAN_LOG_DIR:-/var/log/nftban}/portscan-events.log" 2>/dev/null || true; })
    fi

    if [[ -z "$events" ]]; then
        _nftban_portscan_classic_log "INFO" "No events to aggregate"
        return 0
    fi

    # Aggregate by source IP
    declare -A ip_events ip_ports ip_first ip_last

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local src="" dpt="" ts=""
        # Parse key=value format
        if [[ "$line" =~ src=([0-9a-fA-F.:]+) ]]; then src="${BASH_REMATCH[1]}"; fi
        if [[ "$line" =~ dpt=([0-9]+) ]]; then dpt="${BASH_REMATCH[1]}"; fi
        if [[ "$line" =~ ts=([0-9T:+-]+) ]]; then ts="${BASH_REMATCH[1]}"; fi

        [[ -z "$src" ]] && continue

        # Skip whitelisted IPs (HARD GATE - no state accumulation)
        if nftban_portscan_classic_is_whitelisted "$src"; then
            continue
        fi

        # Aggregate
        ip_events[$src]=$(( ${ip_events[$src]:-0} + 1 ))
        ip_ports[$src]="${ip_ports[$src]:-} $dpt"

        # Track first/last seen for span calculation
        local ts_epoch
        if declare -f nftban_timestamp_to_unix &>/dev/null && [[ -n "$ts" ]]; then
            ts_epoch=$(nftban_timestamp_to_unix "$ts")
            # Fallback if conversion failed
            if [[ "$ts_epoch" == "0" ]]; then
                ts_epoch=$(date -d "$ts" +%s 2>/dev/null || nftban_timestamp_unix 2>/dev/null || date +%s)
            fi
        else
            ts_epoch=$(date -d "$ts" +%s 2>/dev/null || date +%s)
        fi
        [[ -z "${ip_first[$src]:-}" ]] && ip_first[$src]=$ts_epoch
        ip_last[$src]=$ts_epoch

    done <<< "$events"

    local banned=0 detected=0

    # Analyze each IP
    for src in "${!ip_events[@]}"; do
        local event_count=${ip_events[$src]}
        local ports="${ip_ports[$src]}"
        local unique_ports
        unique_ports=$(echo "$ports" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l)

        # Calculate score (reusing patterns from suricata scoring)
        local score=0

        # +1 per event
        score=$((score + event_count))

        # +0.3 per unique port (capped)
        local port_score=$((unique_ports * 3 / 10))
        score=$((score + port_score))

        # +2 per sensitive port hit
        local sensitive_hits=0
        for port in $(echo "$ports" | tr ' ' '\n' | sort -u); do
            if [[ ",$PORTSCAN_SENSITIVE_PORTS," == *",$port,"* ]]; then
                # v1.19.20 FIX
                ((sensitive_hits++)) || true
            fi
        done
        score=$((score + sensitive_hits * 2))

        # +3 if periodicity detected (events spread over 6+ hours)
        local span_hours=0
        if [[ -n "${ip_first[$src]:-}" ]] && [[ -n "${ip_last[$src]:-}" ]]; then
            span_hours=$(( (ip_last[$src] - ip_first[$src]) / 3600 ))
            if [[ $span_hours -ge 6 ]]; then
                score=$((score + 3))
            fi
        fi

        # +2 if persistent (span >= 6 hours)
        if [[ $span_hours -ge 6 ]]; then
            score=$((score + 2))
        fi

        # Check ban threshold (99% certainty)
        # Require: score >= 25 AND events >= 8 AND unique_ports >= 20
        if [[ $score -ge $score_threshold ]] && \
           [[ $event_count -ge $min_events ]] && \
           [[ $unique_ports -ge $min_unique_ports ]]; then

            # v1.19.20 FIX
            ((detected++)) || true

            local reason="stealth_scan: events=$event_count unique=$unique_ports sensitive=$sensitive_hits span=${span_hours}h score=$score"
            _nftban_portscan_classic_log "WARN" "Stealth scan detected: $src - $reason"

            if [[ "$do_ban" == "true" ]]; then
                # Ban with detailed reason
                local duration="${PORTSCAN_AGG_BAN_DURATION:-3600}"

                if type -t nftban_ban &>/dev/null; then
                    # v1.19.20 FIX
                    nftban_ban "$src" \
                        --timeout "$duration" \
                        --reason "portscan:stealth:$reason" \
                        --source "portscan-aggregate" 2>/dev/null && { ((banned++)) || true; }
                elif type -t nft_ipc_ban &>/dev/null; then
                    local ipc_result
                    if ipc_result=$(nft_ipc_ban "$src" "$duration" "portscan:stealth" "portscan-aggregate" 2>&1); then
                        # v1.19.20 FIX
                        ((banned++)) || true
                    else
                        _nftban_portscan_classic_log "ERROR" "IPC ban failed for $src: $ipc_result"
                    fi
                fi
            fi
        fi
    done

    _nftban_portscan_classic_log "INFO" "Aggregation complete: detected=$detected banned=$banned"
    return 0
}

# Export aggregation function
export -f nftban_portscan_aggregate

# =============================================================================
# END OF CLASSIC MODE IMPLEMENTATION
# =============================================================================
