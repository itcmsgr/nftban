#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan - Maintenance Script (Always Active)
# =============================================================================
# meta:name="maintenance"
# meta:type="script"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Runs critical safety checks (SSH monitoring, autoheal, IP changes)"
# meta:inventory.files=""
# meta:inventory.binaries="systemctl,nft"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LOG_DIR"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="nftban-maintenance.timer"
# meta:inventory.network=""
# meta:inventory.privileges="nft read/write via IPC"
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# IPC CLIENT (Single-Writer Architecture)
# =============================================================================
# All nft WRITE operations go through daemon via IPC
# See: ARCHITECTURE-NFT-POLICY.md

# Source IPC client library
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_ipc.sh" ]]; then
    # shellcheck source=/usr/lib/nftban/lib/nft_ipc.sh
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_ipc.sh" || return 1
else
    echo "FATAL: nft_ipc.sh not found - cannot perform firewall operations" >&2
    exit 1
fi

# Source timestamp library (graceful fallback)
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" ]]; then
    # shellcheck source=/usr/lib/nftban/lib/nftban_timestamp.sh
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" || return 1
fi

# Source file utilities library (graceful fallback)
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_file_utils.sh" ]]; then
    # shellcheck source=/usr/lib/nftban/lib/nftban_file_utils.sh
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_file_utils.sh" || return 1
fi
IFS=$'\n\t'
umask 027

# v1.228.4 PR-3 typed nft probe authority. Sourced early so every probe on this
# path is typed. NOTE: the script-scope IFS above is exactly why the old unquoted
# "$NFTBAN_TABLE_IPV4" expansions reached nft as one fused argv element.
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_probe.sh"
_MAINT_PROBE_UNREADABLE=0

# =============================================================================
# CONFIGURATION
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true
# v1.19.0: Source .local override (user customizations survive package updates)
# IMPL-1: ensure _source_local helper is defined (env.sh is idempotent)
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/env.sh" 2>/dev/null || true
_source_local "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local"

# NFTables table names (must match nft_schema.sh)
: "${NFTBAN_TABLE_IPV4:=ip nftban}"
: "${NFTBAN_TABLE_IPV6:=ip6 nftban}"

LOGFILE="${NFTBAN_LOG_DIR}/maintenance.log"
LOCKFILE="${NFTBAN_RUN_DIR}/maintenance.lock"

# =============================================================================
# LOGGING
# =============================================================================

log() {
    local level="$1"
    shift
    # BUG-L65 FIX: Strip ANSI escape codes before writing to log file
    # Terminal output keeps colors, file output is clean
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo "$msg"
    echo "$msg" | sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g' >> "$LOGFILE"
}

# v1.193.0 PR-B (table-absent maintenance-log noise): a single 'no-table' sample
# from nftban_ssh_apply_state can be a TRANSIENT firewall transition window
# (a rebuild/reload re-applying the schema) rather than a genuine absence. Before
# emitting the noisy "table absent" WARN, re-probe the LIVE nftban table a few
# times over a short bounded grace. If it reappears → transient → caller logs a
# quiet INFO instead. If still absent across the grace → GENUINE table-absent
# (e.g. while install_state COMMITTED) → caller logs the WARN (real failure kept).
# This ONLY changes the maintenance LOG path; it does not touch the FW-transition
# harm counter (table_absent_while_committed_count), firewall load/rebuild
# semantics, install_state, or any set. Returns 0 = genuinely absent, 1 = transient.
# A1 central-comms: emit a system IP-change notice through the CENTRAL mail authority
# instead of a direct root mailer (which silently failed on daemonless/minimal hosts and
# hardcoded the root recipient). INFO-severity operational notice; recipient terminates at
# NFTBAN_MAIL_RECIPIENT. No direct transport, no hardcoded recipient.
_maint_ipchange_alert() {
    local family="$1" ip="$2"
    if ! declare -F nftban_mail_alert >/dev/null 2>&1 && [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_mail.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_mail.sh" 2>/dev/null || true
    fi
    if ! declare -F nftban_mail_alert >/dev/null 2>&1; then
        log "WARN" "central mail authority unavailable — ${family} change notice not sent (no direct fallback)"
        return 0
    fi
    local host; host=$(hostname 2>/dev/null)
    nftban_mail_alert \
        "[NFTBan] ${family} Address Auto-Updated on ${host}" \
        "NFTBan info (INFO/operational): system ${family} changed to ${ip}, auto-whitelisted and firewall reloaded on ${host} at $(date)." \
        "" || true
}

# v1.228.4 PR-3: TYPED re-check. Returns 0 only for a table that is VERIFIABLY
# absent across the whole grace window. A window in which the ruleset could not be
# READ returns 2 — neither "absent" nor "present", so the caller cannot collapse it.
#
# The old form expanded $_tbl UNQUOTED under the script-scope IFS=$'\n\t' set at
# line 48, so "ip nftban" did NOT word-split and reached nft as ONE argv element.
# The typed probe takes family and table as separate parameters, making that class
# of defect unrepresentable.
_maint_table_absent_confirmed() {
    local _fam="${1:-ip}" _tab="${2:-nftban}" _i
    for _i in 1 2 3; do
        sleep "${_MAINT_TABLE_RECHECK_SLEEP:-0.4}"
        nftban_nft_probe_table "$_fam" "$_tab" maintenance || true
        case "$NFTBAN_NFT_PROBE_VERDICT" in
            PRESENT)     return 1 ;;   # reappeared → transient transition window
            CANNOT_READ) return 2 ;;   # unreadable → absence is NOT established
        esac
    done
    return 0   # ABSENT across the whole grace window → genuine
}

# _maint_active_ssh_peers <port>... — echo the PEER IP of every established SSH
# session, one per line, loopback excluded. Empty output = genuinely no sessions.
#
# RUNTIME_VERIFIED 2026-08-14 (srv2 :55000 + srv3 :22, both v1.228.11): the code
# this replaces produced an EMPTY result on EVERY host and EVERY port, so the
# active-session lockout protection was inert fleet-wide. Two layered defects:
#
#   1. DOMINANT — the peer was read as $5. `ss -tn state established` OMITS the
#      State column, so a data row is:
#          $1 Recv-Q   $2 Send-Q   $3 Local Address:Port   $4 Peer Address:Port
#      i.e. $5 is empty. $NF is used here because it is the peer column in BOTH
#      layouts (with State present it is $5, without it is $4).
#   2. MASKED BY 1 — the filter hardcoded :22 even though step [1/10] has already
#      detected the real listeners into SSH_PORTS. Once defect 1 is fixed, a host
#      with SSH on 55000 would still whitelist nothing.
#
# Fixing either one alone yields a FALSE "fixed" signal, so both land together.
#
# The header line is NOT skipped by row number: its $NF is the literal
# "Address:Port", which cannot match the IP patterns below. Filtering by shape
# rather than by NR>1 means a session is still protected on any ss build that
# omits the header — dropping the only live session there would be a lockout.
_maint_active_ssh_peers() {
    local _filter="" _p
    for _p in "$@"; do
        [[ "$_p" =~ ^[0-9]+$ ]] || continue
        [[ -n "$_filter" ]] && _filter+=" or "
        _filter+="dport = :$_p or sport = :$_p"
    done
    [[ -n "$_filter" ]] || _filter="dport = :22 or sport = :22"

    ss -tn state established "( $_filter )" 2>/dev/null | \
        awk '{print $NF}' | \
        grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-f:]+:+)+[0-9a-f]+' | \
        grep -v '^127\.' | \
        grep -v '^::1' | \
        sort -u || true
}

# =============================================================================
# LOCKING (Prevent concurrent runs)
# =============================================================================
# NOTE: Locking is handled by systemd via flock (see nftban-maintenance.service)
# The flock command wraps this script: flock -n /run/nftban/maintenance.lock
# This means systemd creates the lock file BEFORE the script runs.
# DO NOT add internal lock checks here - they conflict with flock and cause
# "Maintenance already running (lock exists)" false positives.
# =============================================================================

acquire_lock() {
    # Locking handled by systemd flock - just ensure directory exists
    mkdir -p "$(dirname "$LOCKFILE")" 2>/dev/null || true
    # Write PID for debugging (flock already holds the lock)
    echo $$ > "$LOCKFILE" 2>/dev/null || true
}

release_lock() {
    # Lock file released automatically by flock when script exits
    # Just clean up our PID marker
    rm -f "$LOCKFILE" 2>/dev/null || true
}

trap release_lock EXIT

# =============================================================================
# MAIN MAINTENANCE TASKS
# =============================================================================

main() {
    acquire_lock

    log "INFO" "NFTBan Maintenance Starting"

    # v1.32.0: Cache table existence check (avoids 4 redundant kernel calls)
    # v1.228.4 PR-3: typed. "not available" now distinguishes ABSENT from
    # CANNOT_READ; the latter marks the whole run as failed rather than silently
    # gating features off as though the firewall were simply not there.
    local _nft_table_available=false
    nftban_nft_probe_table ip nftban maintenance || true
    case "$NFTBAN_NFT_PROBE_VERDICT" in
        PRESENT)
            _nft_table_available=true ;;
        CANNOT_READ)
            _MAINT_PROBE_UNREADABLE=1
            log "ERROR" "Cannot read the nftables ruleset — firewall state is UNKNOWN, not absent."
            log "ERROR" "$(nftban_nft_probe_diagnostic)"
            ;;
    esac

    # ==========================================================================
    # 1. SSH Port Monitoring (CRITICAL - Lockout Prevention)
    # ==========================================================================
    log "INFO" "[1/10] Checking SSH port configuration..."

    # Auto-detect current SSH port(s). v1.145 PR-B: use the union detector
    # (ListenAddress-aware, multi-port) instead of scalar `head -1` sshd_config
    # parsing. SSH_PORTS = full union for firewall ENFORCEMENT (every real
    # listener port protected, lockout-safe); SSH_PORT = primary for the
    # single-value whitelist/state/alert logic below (display/back-compat).
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/ssh_port_detect.sh" 2>/dev/null || true
    SSH_PORTS=()
    if declare -f nftban_detect_ssh_ports >/dev/null 2>&1; then
        mapfile -t SSH_PORTS < <(nftban_detect_ssh_ports 2>/dev/null || true)
    fi
    [[ ${#SSH_PORTS[@]} -eq 0 ]] && SSH_PORTS=(22)
    SSH_PORT="${SSH_PORTS[0]}"

    # Check if SSH port is whitelisted
    SSH_WHITELIST="${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf"
    SSH_PORT_STATE="${NFTBAN_DATA_DIR}/state/ssh_port_alert.state"
    # Track the currently active SSH port (for cleanup when port changes back)
    SSH_PORT_ACTIVE="${NFTBAN_DATA_DIR}/state/ssh_port_active.state"

    if [[ -f "$SSH_WHITELIST" ]]; then
        # Check if current SSH port is in whitelist (format: PORT/PROTOCOL)
        if grep -qE "^${SSH_PORT}/(T|tcp)" "$SSH_WHITELIST" 2>/dev/null; then
            log "INFO" "SSH port check: config OK (port $SSH_PORT whitelisted)"

            # v1.145 PR-C2: re-probe the LIVE kernel (NEVER the once-cached
            # _nft_table_available) immediately before applying. A table absent
            # at timer-start but present now must not be skipped; conversely
            # state must not advance when the kernel is not actually ready.
            # Ensure EVERY detected SSH port is in BOTH tcp_ports_in AND
            # ssh_ports (additive, idempotent). Removal stays conservative.
            local _apply_state _sp _set
            _apply_state=$(nftban_ssh_apply_state "${NFTBAN_TABLE_IPV4}" 2>/dev/null || echo no-table)
            case "$_apply_state" in
                ready)
                    for _sp in "${SSH_PORTS[@]}"; do
                        for _set in tcp_ports_in ssh_ports; do
                            if ! nft list set ${NFTBAN_TABLE_IPV4} "$_set" 2>/dev/null | grep -qw "$_sp"; then
                                log "WARN" "SSH port $_sp missing from $_set - auto-fixing (both-set parity)..."
                                nft_ipc_add_element "${NFTBAN_TABLE_IPV4}" "$_set" "$_sp" 2>/dev/null || true
                                nft_ipc_add_element "${NFTBAN_TABLE_IPV6}" "$_set" "$_sp" 2>/dev/null || true
                            fi
                        done
                    done
                    # Clear alert state + refresh active-port marker ONLY when the
                    # kernel is verified ready (PR-C2: never claim success blind).
                    rm -f "$SSH_PORT_STATE" 2>/dev/null || true
                    mkdir -p "${NFTBAN_DATA_DIR}/state" || return 1
                    echo "$SSH_PORT" > "${SSH_PORT_ACTIVE}.tmp" && mv -f "${SSH_PORT_ACTIVE}.tmp" "$SSH_PORT_ACTIVE"
                    ;;
                no-table)
                    # v1.193.0 PR-B: suppress transient transition-window noise.
                    # v1.228.4 PR-3: three outcomes, not two. The message that ran
                    # ~927 times per host claimed ABSENCE when the real condition was
                    # UNREADABILITY — the ruleset was present and fine.
                    _maint_table_absent_confirmed ip nftban
                    case $? in
                        0)  log "WARN" "nftban firewall table VERIFIED ABSENT — SSH-port enforcement skipped this run (state NOT advanced). Run: nftban firewall reload" ;;
                        1)  log "INFO" "nftban table briefly unavailable during a firewall transition (re-sample shows it present) — SSH-port enforcement deferred to next run; no action needed." ;;
                        2)  _MAINT_PROBE_UNREADABLE=1
                            log "ERROR" "Cannot read the nftables ruleset — firewall presence is UNKNOWN, NOT absent. SSH-port enforcement skipped."
                            log "ERROR" "$(nftban_nft_probe_diagnostic)"
                            log "ERROR" "No remediation is suggested from an unknown cause — diagnose the unit sandbox first." ;;
                    esac
                    ;;
                cannot-read)
                    # v1.228.4 PR-3: the read FAILED. Existence is unknown, so no
                    # claim of absence and no remediation advice is emitted.
                    _MAINT_PROBE_UNREADABLE=1
                    log "ERROR" "Cannot read the nftables ruleset — firewall presence is UNKNOWN, NOT absent. SSH-port enforcement skipped."
                    log "ERROR" "$(nftban_nft_probe_diagnostic)"
                    log "ERROR" "No remediation is suggested from an unknown cause — diagnose the unit sandbox first."
                    ;;
                no-sets)
                    log "WARN" "nftban set-driven schema (tcp_ports_in/ssh_ports) not loaded — SSH-port enforcement skipped (state NOT advanced). Run: nftban firewall reload"
                    ;;
            esac
        else
            # Check if we already alerted about this port change
            if [[ -f "$SSH_PORT_STATE" ]]; then
                LAST_ALERT_PORT=$(cat "$SSH_PORT_STATE" 2>/dev/null || echo "")
                if [[ "$LAST_ALERT_PORT" == "$SSH_PORT" ]]; then
                    # Already alerted about this port, skip alert (no spam)
                    # C10 fix: use 'true' instead of 'return 0' to continue remaining maintenance tasks
                    log "INFO" "SSH port $SSH_PORT already updated (waiting for firewall reload)"
                    true
                fi
            fi

            # SSH port changed but not whitelisted - AUTO-FIX
            log "WARN" "SSH port changed to $SSH_PORT but not whitelisted!"
            log "INFO" "Auto-updating SSH port whitelist (lockout prevention)..."

            # Get the OLD SSH port that was auto-added (for cleanup)
            OLD_SSH_PORT=""
            if [[ -f "$SSH_PORT_ACTIVE" ]]; then
                OLD_SSH_PORT=$(cat "$SSH_PORT_ACTIVE" 2>/dev/null || echo "")
                # Validate it's a number and different from current
                if [[ -n "$OLD_SSH_PORT" ]] && [[ "$OLD_SSH_PORT" =~ ^[0-9]+$ ]] && [[ "$OLD_SSH_PORT" != "$SSH_PORT" ]]; then
                    log "INFO" "Detected old SSH port $OLD_SSH_PORT (will be removed from firewall)"
                else
                    OLD_SSH_PORT=""
                fi
            fi

            # Backup old whitelist (use library timestamp with fallback)
            local backup_timestamp
            if declare -f nftban_timestamp_file >/dev/null 2>&1; then
                backup_timestamp=$(nftban_timestamp_file)
            else
                backup_timestamp=$(date +%Y%m%d_%H%M%S)
            fi
            cp "$SSH_WHITELIST" "${SSH_WHITELIST}.backup.${backup_timestamp}"

            # Update whitelist with new SSH port (format: PORT/PROTOCOL)
            # v1.59.1 TOCTOU: Atomic write — temp+chmod+mv (prevents window with wrong perms)
            cat > "${SSH_WHITELIST}.tmp" <<EOF
# SSH port auto-updated by maintenance: $(date '+%Y-%m-%d %H:%M:%S')
# DO NOT DELETE - LOCKOUT RISK!
# Port format: PORT/PROTOCOL where PROTOCOL = T/tcp, U/udp, or B/both
${SSH_PORT}/T
EOF
            chmod 644 "${SSH_WHITELIST}.tmp"
            mv -f "${SSH_WHITELIST}.tmp" "$SSH_WHITELIST"

            log "INFO" "SSH port $SSH_PORT added to whitelist"

            # Firewall update for the changed SSH port. v1.145 PR-C2: re-probe
            # the LIVE kernel (never the once-cached _nft_table_available);
            # add-before-delete; VERIFY both sets carry the new port; advance the
            # active-port state ONLY on verified kernel success.
            log "INFO" "Applying SSH-port change to firewall (verified)..."
            local _kernel_applied=false
            local _autofix_state
            _autofix_state=$(nftban_ssh_apply_state "${NFTBAN_TABLE_IPV4}" 2>/dev/null || echo no-table)
            if [[ "$_autofix_state" == "ready" ]]; then
                # FIRST: add the NEW port to BOTH sets (IPv4+IPv6) before removing old.
                nft_ipc_add_element "${NFTBAN_TABLE_IPV4}" tcp_ports_in "$SSH_PORT" 2>/dev/null || true
                nft_ipc_add_element "${NFTBAN_TABLE_IPV6}" tcp_ports_in "$SSH_PORT" 2>/dev/null || true
                nft_ipc_add_element "${NFTBAN_TABLE_IPV4}" ssh_ports "$SSH_PORT" 2>/dev/null || true
                nft_ipc_add_element "${NFTBAN_TABLE_IPV6}" ssh_ports "$SSH_PORT" 2>/dev/null || true

                # VERIFY the kernel actually carries the new port in BOTH sets.
                if nftban_ssh_port_in_both_sets "${NFTBAN_TABLE_IPV4}" "$SSH_PORT"; then
                    _kernel_applied=true
                    log "INFO" "SSH port $SSH_PORT verified in tcp_ports_in + ssh_ports (kernel applied)"
                    # THEN: conservatively remove the OLD port from BOTH sets,
                    # only if it is no longer a listener and not the active session.
                    if [[ -n "$OLD_SSH_PORT" ]]; then
                        local _active_ssh_port="${SSH_CLIENT##* }" _old_still_listener=0 _u
                        for _u in "${SSH_PORTS[@]}"; do
                            if [[ "$_u" == "$OLD_SSH_PORT" ]]; then _old_still_listener=1; break; fi
                        done
                        if [[ "$_old_still_listener" -eq 0 && "$OLD_SSH_PORT" != "${_active_ssh_port:-}" ]]; then
                            log "INFO" "Removing stale old SSH port $OLD_SSH_PORT from firewall (both sets)..."
                            local _dset
                            for _dset in tcp_ports_in ssh_ports; do
                                nft_ipc_delete_element "${NFTBAN_TABLE_IPV4}" "$_dset" "$OLD_SSH_PORT" 2>/dev/null || true
                                nft_ipc_delete_element "${NFTBAN_TABLE_IPV6}" "$_dset" "$OLD_SSH_PORT" 2>/dev/null || true
                            done
                        else
                            log "INFO" "Keeping old SSH port $OLD_SSH_PORT (still a listener or active session)"
                        fi
                    fi
                else
                    log "WARN" "SSH port $SSH_PORT NOT confirmed in kernel sets after add — apply incomplete, active state NOT advanced. Run: nftban firewall reload"
                fi
            elif [[ "$_autofix_state" == "no-sets" ]]; then
                log "WARN" "nftban set-driven schema not loaded (tcp_ports_in/ssh_ports missing) — SSH port whitelisted in config but NOT applied. Run: nftban firewall reload"
            else
                # v1.193.0 PR-B: suppress transient transition-window noise; keep genuine absence.
                if _maint_table_absent_confirmed "${NFTBAN_TABLE_IPV4}"; then
                    log "WARN" "nftban firewall table absent — SSH port whitelisted in config but NOT applied. Run: nftban firewall reload"
                else
                    log "INFO" "nftban table briefly unavailable during a firewall transition (re-sample shows it present) — SSH-port apply deferred to next run; no action needed."
                fi
            fi

            # Alert-dedup marker (independent of apply outcome — prevents spam).
            mkdir -p "${NFTBAN_DATA_DIR}/state" || return 1
            echo "$SSH_PORT" > "${SSH_PORT_STATE}.tmp" && mv -f "${SSH_PORT_STATE}.tmp" "$SSH_PORT_STATE"
            # v1.145 PR-C2: advance the ACTIVE-port marker ONLY on verified kernel
            # success — never record success when the kernel did not change.
            if [[ "$_kernel_applied" == "true" ]]; then
                echo "$SSH_PORT" > "${SSH_PORT_ACTIVE}.tmp" && mv -f "${SSH_PORT_ACTIVE}.tmp" "$SSH_PORT_ACTIVE"
            else
                log "WARN" "Active SSH-port state NOT advanced to $SSH_PORT (kernel apply unverified) — prevents a false 'applied' record."
            fi

            # Send alert via NFTBan unified mail mechanism (ONLY ONCE)
            if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/mail.conf" ]]; then
                local alert_msg="NFTBan Security Alert: SSH port changed to $SSH_PORT"
                [[ -n "$OLD_SSH_PORT" ]] && alert_msg+=", old port $OLD_SSH_PORT removed"
                alert_msg+=", auto-whitelisted on $(hostname) at $(date) (kernel applied=$_kernel_applied)"
                nftban_mail_send "$alert_msg" 2>/dev/null || true
            fi
        fi
    else
        # SSH whitelist missing - create it
        log "WARN" "SSH whitelist missing - creating..."
        mkdir -p "${NFTBAN_CONFIG_DIR}/ports.d" || return 1
        # v1.59.1 TOCTOU: Atomic write — temp+chmod+mv (prevents window with wrong perms)
        cat > "${SSH_WHITELIST}.tmp" <<EOF
# SSH port auto-added during maintenance: $(date '+%Y-%m-%d %H:%M:%S')
# DO NOT DELETE - LOCKOUT RISK!
# Port format: PORT/PROTOCOL where PROTOCOL = T/tcp, U/udp, or B/both
${SSH_PORT}/T
EOF
        chmod 644 "${SSH_WHITELIST}.tmp"
        mv -f "${SSH_WHITELIST}.tmp" "$SSH_WHITELIST"
        # Track this as the active SSH port (atomic write)
        mkdir -p "${NFTBAN_DATA_DIR}/state" || return 1
        echo "$SSH_PORT" > "${SSH_PORT_ACTIVE}.tmp" && mv -f "${SSH_PORT_ACTIVE}.tmp" "$SSH_PORT_ACTIVE"
        log "INFO" "Created SSH whitelist with port $SSH_PORT"
    fi

    # ==========================================================================
    # 1b. SYNPROXY Jump Order Check (CRITICAL - SSH Lockout Prevention)
    # ==========================================================================
    # v1.33.0: If DDoS SYNPROXY is enabled, its jump in the input chain MUST be
    # BEFORE 'ct state established,related accept'. Otherwise, notracked packets
    # (from SYNPROXY raw rules) never match conntrack and get dropped by policy,
    # causing SSH lockout for non-whitelisted IPs.
    if [[ "$_nft_table_available" == "true" ]]; then
        local family
        for family in ip ip6; do
            local table_fam="${family} nftban"
            # Check if SYNPROXY jump exists in the chain
            local synproxy_handle established_handle
            synproxy_handle=$(nft -a list chain ${table_fam} input 2>/dev/null \
                | grep 'jump ddos_synproxy' | grep -oP 'handle \K\d+' | head -1 || true)
            established_handle=$(nft -a list chain ${table_fam} input 2>/dev/null \
                | grep 'ct state established,related accept' | grep -oP 'handle \K\d+' | head -1 || true)

            if [[ -n "$synproxy_handle" ]] && [[ -n "$established_handle" ]]; then
                # Both exist — check ordering (lower handle = earlier in chain)
                if [[ "$synproxy_handle" -gt "$established_handle" ]]; then
                    log "WARN" "SYNPROXY jump is AFTER established rule in ${family} — SSH lockout risk!"
                    log "INFO" "Auto-fixing: moving SYNPROXY jump before established rule..."
                    # Remove the misplaced jump
                    nft delete rule ${table_fam} input handle "$synproxy_handle" 2>/dev/null || true
                    # Re-insert before established,related
                    nft insert rule ${table_fam} input position "$established_handle" \
                        jump ddos_synproxy comment "\"SYNPROXY protection\"" 2>/dev/null || {
                        log "WARN" "Failed to reposition SYNPROXY jump in ${family}"
                    }
                    log "INFO" "SYNPROXY jump repositioned in ${family} input chain"
                fi
            fi
        done
    fi

    # ==========================================================================
    # 1c. SYNPROXY vs SSH Port Correlation (CRITICAL - SSH Lockout Prevention)
    # ==========================================================================
    # v1.33.0: SYNPROXY notrack on the SSH port breaks conntrack-based whitelist/
    # blacklist. The DDoS module doesn't know which port SSH uses, so if the SSH
    # port is in the SYNPROXY notrack rules (from old defaults or user config),
    # non-whitelisted IPs get locked out of SSH.
    #
    # This check: if SSH port appears in raw prerouting notrack → remove it and
    # rebuild the raw rules without the SSH port.
    if [[ "$_nft_table_available" == "true" ]] && [[ -n "$SSH_PORT" ]]; then
        local family
        for family in ip ip6; do
            # Check if raw prerouting has a notrack rule that includes the SSH port
            local raw_rule
            raw_rule=$(nft -a list chain ${family} raw prerouting 2>/dev/null \
                | grep -i 'SYNPROXY.*notrack' || true)

            if [[ -n "$raw_rule" ]]; then
                # Check if SSH port is in the port list of this rule
                # The rule looks like: tcp dport { 22, 80, 443, ... } ... notrack
                if echo "$raw_rule" | grep -qwE "(dport ${SSH_PORT}[^0-9]|[{,] *${SSH_PORT}[},[:space:]])"; then
                    log "WARN" "SSH port ${SSH_PORT} found in SYNPROXY notrack rules (${family}) — lockout risk!"
                    log "INFO" "Removing SYNPROXY raw rule containing SSH port..."

                    # Remove the offending rule by handle
                    local raw_handle
                    raw_handle=$(echo "$raw_rule" | grep -oP 'handle \K\d+' | head -1 || true)
                    if [[ -n "$raw_handle" ]]; then
                        nft delete rule ${family} raw prerouting handle "$raw_handle" 2>/dev/null && {
                            log "INFO" "Removed SYNPROXY notrack rule (handle ${raw_handle}) from ${family} raw"

                            # Rebuild the rule WITHOUT the SSH port
                            local old_ports new_ports
                            # Extract port list from the removed rule
                            old_ports=$(echo "$raw_rule" | grep -oP '\{ *\K[^}]+' | tr -d ' ')
                            # Remove SSH port from the list
                            new_ports=$(echo "$old_ports" | tr ',' '\n' | grep -vxF "$SSH_PORT" | tr '\n' ',' | sed 's/,$//')

                            if [[ -n "$new_ports" ]]; then
                                nft add rule ${family} raw prerouting \
                                    tcp dport "{ ${new_ports} }" tcp flags syn / "syn,ack,fin,rst" \
                                    notrack comment "\"SYNPROXY: notrack SYN\"" 2>/dev/null && {
                                    log "INFO" "Rebuilt SYNPROXY notrack in ${family} without SSH port (ports: ${new_ports})"
                                } || {
                                    log "WARN" "Failed to rebuild SYNPROXY notrack in ${family}"
                                }
                            else
                                log "INFO" "No ports remaining for SYNPROXY notrack in ${family} — rule removed"
                            fi
                        } || {
                            log "WARN" "Failed to remove SYNPROXY notrack rule from ${family} raw"
                        }
                    fi
                fi
            fi
        done
    fi

    # ==========================================================================
    # 2. System IP Monitoring (Lockout Prevention)
    # ==========================================================================
    log "INFO" "[2/10] Checking system IP addresses..."

    IP_ALERT_STATE="${NFTBAN_DATA_DIR}/state/ip_change_alert.state"

    # Create system whitelist if missing (CRITICAL FOR LOCKOUT PREVENTION)
    # v1.59.0 SEC-2: Atomic write via temp file to prevent TOCTOU race
    if [[ ! -f "${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf" ]]; then
        log "WARN" "System whitelist missing - creating now (lockout prevention)..."
        mkdir -p "${NFTBAN_CONFIG_DIR}/whitelist.d" || return 1
        local _wl_tmp
        _wl_tmp="${NFTBAN_CONFIG_DIR}/whitelist.d/.00-system.conf.tmp.$$"
        cat > "$_wl_tmp" <<EOF
# NFTBan System IP Whitelist (Auto-Generated)
# This file contains server IPs and SSH client IPs for lockout prevention
# DO NOT EDIT - Automatically managed by maintenance script
# Generated: $(date)

# Server IPs (from interfaces)
EOF

        # Add all server IPs from interfaces
        ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | while read -r ip; do
            echo "$ip  # Server IPv4 (auto-detected)" >> "$_wl_tmp"
            log "INFO" "Added server IPv4 to whitelist: $ip"
        done || true

        ip -6 addr show | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^::1$' | grep -v '^fe80:' | while read -r ip; do
            echo "$ip  # Server IPv6 (auto-detected)" >> "$_wl_tmp"
            log "INFO" "Added server IPv6 to whitelist: $ip"
        done || true

        # Add SSH client IP if available
        if [[ -n "${SSH_CLIENT:-}" ]]; then
            SSH_IP="${SSH_CLIENT%% *}"
            echo "$SSH_IP  # SSH client IP (auto-detected)" >> "$_wl_tmp"
            log "INFO" "Added SSH client IP to whitelist: $SSH_IP"
        fi

        # Atomic: set permissions on temp file, then move into place
        chmod 640 "$_wl_tmp"
        chown root:nftban "$_wl_tmp" 2>/dev/null || true
        mv -f "$_wl_tmp" "${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf"
        log "INFO" "System whitelist created with all server and client IPs"

        # Reload firewall to apply whitelist
        if nftban firewall reload >/dev/null 2>&1; then
            log "INFO" "✅ Firewall reloaded - system IPs now protected"
        else
            log "WARN" "Firewall reload failed - whitelist created but not yet active"
        fi
    fi

    # Check if system IPs have changed
    if [[ -f "${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf" ]]; then
        # Get current public IPs
        current_ipv4=$(curl -s -4 --max-time 5 ifconfig.me 2>/dev/null || echo "")
        current_ipv6=$(curl -s -6 --max-time 5 ifconfig.me 2>/dev/null || echo "")

        # Validate IPv4 format - reject HTTP error messages and non-IP responses
        # Must match exact IPv4 pattern: 1-3 digits, dot, 1-3 digits, dot, 1-3 digits, dot, 1-3 digits
        if [[ -n "$current_ipv4" ]] && ! [[ "$current_ipv4" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            log "WARN" "Invalid IPv4 response from ifconfig.me (got: ${current_ipv4:0:50}...)"
            current_ipv4=""
        fi

        # v1.59.1: Validate IPv6 format — reject HTTP error messages and non-IP responses
        # Must match hex digits and colons, optional CIDR suffix
        if [[ -n "$current_ipv6" ]] && ! [[ "$current_ipv6" =~ ^[0-9a-fA-F:]+$ ]]; then
            log "WARN" "Invalid IPv6 response from ifconfig.me (got: ${current_ipv6:0:50}...)"
            current_ipv6=""
        fi

        local _wl_file="${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf"

        # Check if IPv4 changed
        if [[ -n "$current_ipv4" ]] && ! grep -q "$current_ipv4" "$_wl_file" 2>/dev/null; then
            # Check if we already alerted about this IP
            if [[ -f "$IP_ALERT_STATE" ]] && grep -q "$current_ipv4" "$IP_ALERT_STATE" 2>/dev/null; then
                # Already alerted about this IP, skip alert (no spam)
                log "INFO" "IPv4 $current_ipv4 already in pending whitelist"
            else
                log "WARN" "System IPv4 changed: $current_ipv4 (not in whitelist)"
                log "INFO" "Auto-adding to whitelist (lockout prevention)..."

                # v1.59.1 TOCTOU: Atomic append — copy+append+chmod+mv
                cp "$_wl_file" "${_wl_file}.tmp"
                echo "# Auto-added by maintenance: $(date)" >> "${_wl_file}.tmp"
                echo "$current_ipv4" >> "${_wl_file}.tmp"
                chmod 644 "${_wl_file}.tmp"
                mv -f "${_wl_file}.tmp" "$_wl_file"
                log "INFO" "✅ Added $current_ipv4 to whitelist"

                # ATOMIC firewall update via daemon IPC (single-writer architecture)
                log "INFO" "Adding IP $current_ipv4 to firewall whitelist via daemon..."
                if [[ "$_nft_table_available" == "true" ]]; then
                    # Firewall is active - add IP via IPC
                    if nft_ipc_add_element "${NFTBAN_TABLE_IPV4}" whitelist_ipv4 "$current_ipv4"; then
                        log "INFO" "✅ IP $current_ipv4 whitelisted via daemon (no lockout risk)"
                    else
                        # IPC failed - daemon may be down, use full reload
                        log "WARN" "Daemon IPC failed, using safe full reload..."
                        if nftban firewall reload >/dev/null 2>&1; then
                            log "INFO" "✅ Firewall reloaded - IP $current_ipv4 now protected"
                        else
                            log "WARN" "Reload failed - IP whitelisted in config but not yet active"
                        fi
                    fi
                else
                    log "WARN" "Firewall not initialized - IP whitelist updated but not applied"
                fi

                # Save alert state to prevent spam (only alert once per IP)
                mkdir -p "${NFTBAN_DATA_DIR}/state" || return 1
                echo "$current_ipv4 $(date)" >> "$IP_ALERT_STATE"

                # Send IP-change notice via the central mail authority (ONLY ONCE)
                _maint_ipchange_alert "IPv4" "$current_ipv4"
            fi
        fi

        # v1.59.1: IPv6 parity — auto-add IPv6 when public address changes (lockout prevention)
        if [[ -n "$current_ipv6" ]] && ! grep -q "$current_ipv6" "$_wl_file" 2>/dev/null; then
            if [[ -f "$IP_ALERT_STATE" ]] && grep -q "$current_ipv6" "$IP_ALERT_STATE" 2>/dev/null; then
                log "INFO" "IPv6 $current_ipv6 already in pending whitelist"
            else
                log "WARN" "System IPv6 changed: $current_ipv6 (not in whitelist)"
                log "INFO" "Auto-adding IPv6 to whitelist (lockout prevention)..."

                # Atomic append — copy+append+chmod+mv
                cp "$_wl_file" "${_wl_file}.tmp"
                echo "# Auto-added IPv6 by maintenance: $(date)" >> "${_wl_file}.tmp"
                echo "$current_ipv6" >> "${_wl_file}.tmp"
                chmod 644 "${_wl_file}.tmp"
                mv -f "${_wl_file}.tmp" "$_wl_file"
                log "INFO" "✅ Added $current_ipv6 to whitelist"

                # Firewall update via daemon IPC
                if [[ "$_nft_table_available" == "true" ]]; then
                    if nft_ipc_add_element "${NFTBAN_TABLE_IPV6}" whitelist_ipv6 "$current_ipv6"; then
                        log "INFO" "✅ IPv6 $current_ipv6 whitelisted via daemon (no lockout risk)"
                    else
                        log "WARN" "Daemon IPC failed for IPv6, using safe full reload..."
                        if nftban firewall reload >/dev/null 2>&1; then
                            log "INFO" "✅ Firewall reloaded - IPv6 $current_ipv6 now protected"
                        else
                            log "WARN" "Reload failed - IPv6 whitelisted in config but not yet active"
                        fi
                    fi
                else
                    log "WARN" "Firewall not initialized - IPv6 whitelist updated but not applied"
                fi

                # Save alert state
                mkdir -p "${NFTBAN_DATA_DIR}/state" || return 1
                echo "$current_ipv6 $(date)" >> "$IP_ALERT_STATE"

                # Send IPv6-change notice via the central mail authority (ONLY ONCE)
                _maint_ipchange_alert "IPv6" "$current_ipv6"
            fi
        fi

        # v1.19.5: Ensure ALL IPs in 00-system.conf are loaded into nftables sets
        # After reboot, nftables sets are recreated empty — re-sync from file
        while IFS= read -r line; do
            # Strip comments and whitespace
            local entry="${line%%#*}"
            entry="${entry%% *}"
            entry="${entry%%	*}"
            [[ -z "$entry" ]] && continue

            # v1.19.27 SECURITY: Strict IP validation before nft command (defense-in-depth)
            # Prevents command injection if whitelist file is compromised
            if [[ "$entry" == *:* ]]; then
                # IPv6: Only allow hex digits and colons
                if [[ ! "$entry" =~ ^[0-9a-fA-F:]+(/[0-9]+)?$ ]]; then
                    log "WARN" "Skipping invalid IPv6 entry in whitelist: $entry"
                    continue
                fi
                if ! nft get element ip6 nftban whitelist_ipv6 "{ $entry }" &>/dev/null; then
                    # v1.32.0: Route writes through daemon IPC (lock + OpQueue)
                    if nft_ipc_add_element "ip6 nftban" whitelist_ipv6 "$entry" 2>/dev/null; then
                        log "INFO" "Re-synced IPv6 to nftables whitelist: $entry"
                    fi
                fi
            elif [[ "$entry" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]+)?$ ]]; then
                # IPv4: Strict format check (4 octets, optional CIDR)
                if ! nft get element ip nftban whitelist_ipv4 "{ $entry }" &>/dev/null; then
                    # v1.32.0: Route writes through daemon IPC (lock + OpQueue)
                    if nft_ipc_add_element "ip nftban" whitelist_ipv4 "$entry" 2>/dev/null; then
                        log "INFO" "Re-synced IPv4 to nftables whitelist: $entry"
                    fi
                fi
            else
                log "WARN" "Skipping invalid entry in whitelist: $entry"
            fi
        done < "${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf"

        log "INFO" "System IP check: OK"
    else
        log "WARN" "System whitelist not found: ${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf"
    fi

    # ==========================================================================
    # 3. Active SSH Session Protection (Auto-Whitelist Logged-In Users)
    # ==========================================================================
    log "INFO" "[3/10] Protecting active SSH sessions..."

    # File to track active SSH IPs with timestamps
    ACTIVE_SSH_WHITELIST="${NFTBAN_DATA_DIR}/state/active_ssh_whitelist.state"
    mkdir -p "${NFTBAN_DATA_DIR}/state" || return 1

    # Get all current SSH connections (excluding localhost) on every REAL SSH
    # listener port, not a hardcoded :22. SSH_PORTS is populated by step [1/10]
    # above (same function scope, always runs first) and is never empty there;
    # the :-22 fallback only covers a future reordering.
    # See _maint_active_ssh_peers for the two defects this replaced.
    CURRENT_SSH_IPS=$(_maint_active_ssh_peers "${SSH_PORTS[@]:-22}")

    # Update active SSH whitelist timestamp file
    : > "$ACTIVE_SSH_WHITELIST.new"

    if [[ -n "$CURRENT_SSH_IPS" ]]; then
        log "INFO" "Found active SSH connections, auto-whitelisting..."

        for ip in $CURRENT_SSH_IPS; do
            # Add IP to temp_whitelist via daemon IPC (single-writer architecture)
            # Timeout refreshes every 15min while user stays logged in
            # 4h = 14400 seconds
            # v1.32.0: Simplified — nft_ipc_add_element with timeout is idempotent
            # (upserts: creates if missing, refreshes timeout if exists, 0 kernel reads)
            if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                # IPv4 - add/refresh with 4 hour timeout via daemon IPC
                if nft_ipc_add_element "${NFTBAN_TABLE_IPV4}" temp_whitelist_ipv4 "$ip" 14400 2>/dev/null; then
                    log "INFO" "Auto-whitelisted active SSH session: $ip (4h timeout, via daemon)"
                fi
            else
                # IPv6 - add/refresh with 4 hour timeout via daemon IPC
                if nft_ipc_add_element "${NFTBAN_TABLE_IPV6}" temp_whitelist_ipv6 "$ip" 14400 2>/dev/null; then
                    log "INFO" "Auto-whitelisted active SSH session: $ip (4h timeout, via daemon)"
                fi
            fi

            # Track this IP with current timestamp (for monitoring)
            local current_ts
            if declare -f nftban_timestamp_unix >/dev/null 2>&1; then
                current_ts=$(nftban_timestamp_unix)
            else
                current_ts=$(date +%s)
            fi
            echo "$ip $current_ts" >> "$ACTIVE_SSH_WHITELIST.new"
        done

        mv "$ACTIVE_SSH_WHITELIST.new" "$ACTIVE_SSH_WHITELIST"
    else
        log "INFO" "No active SSH sessions to protect"
        : > "$ACTIVE_SSH_WHITELIST"
    fi

    # Note: Cleanup handled automatically by nftables timeout
    # IPs expire after 4 hours if not refreshed
    log "INFO" "Active SSH session protection: OK (nftables auto-cleanup after 4h)"

    # ==========================================================================
    # 4. Auto-Heal (Fix Permissions, Directories)
    # ==========================================================================
    log "INFO" "[4/10] Running auto-heal..."

    if [[ -f "${NFTBAN_LIB_DIR}/helpers/autoheal.sh" ]]; then
        if "${NFTBAN_LIB_DIR}/helpers/autoheal.sh" >> "$LOGFILE" 2>&1; then
            log "INFO" "Auto-heal: OK"
        else
            log "WARN" "Auto-heal reported issues (check log)"
        fi
    else
        log "ERROR" "Autoheal script not found: ${NFTBAN_LIB_DIR}/helpers/autoheal.sh"
    fi

    # ==========================================================================
    # 5. Trend Data Collection — REMOVED in v1.46.0
    # ==========================================================================
    # Trend collection + cleanup now handled exclusively by:
    #   - nftban-watchdog.timer (every 2min) — trend collection + cleanup
    #   - Go daemon (stats.CleanupHistory, stats.CleanupProfiles, Recorder.Cleanup)
    # Removed from maintenance to eliminate duplicate execution (L1 audit finding).
    log "INFO" "[5/10] Trend collection: Handled by watchdog timer (skipped)"

    # ==========================================================================
    # 6. Configuration Validation (Critical Files)
    # ==========================================================================
    log "INFO" "[6/10] Validating critical configuration..."

    local config_ok=true

    # Check SSH port whitelist
    if [[ ! -f "${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf" ]]; then
        log "ERROR" "SSH port whitelist missing: ${NFTBAN_CONFIG_DIR}/ports.d/00-ssh.conf"
        config_ok=false
    fi

    # Check system whitelist
    if [[ ! -f "${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf" ]]; then
        log "WARN" "System whitelist missing: ${NFTBAN_CONFIG_DIR}/whitelist.d/00-system.conf"
        config_ok=false
    fi

    # Check main config
    if [[ ! -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
        log "ERROR" "Main config missing: ${NFTBAN_CONFIG_DIR}/nftban.conf"
        config_ok=false
    fi

    if $config_ok; then
        log "INFO" "Configuration validation: OK"
    else
        log "WARN" "Configuration validation: Issues found"
    fi

    # ==========================================================================
    # 7. Portscan Stealth Aggregation (Every 15 min)
    # ==========================================================================
    log "INFO" "[7/10] Running portscan stealth aggregation..."

    # BUGFIX v1.78.1: Check if portscan module is enabled before running aggregation
    # Load portscan config to check enabled status (main.conf.local overrides main.conf)
    local _ps_enabled="false"
    # shellcheck source=/dev/null
    [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/portscan/main.conf" ]] && \
        source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/portscan/main.conf" 2>/dev/null || true
    # shellcheck source=/dev/null
    [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/portscan/main.conf.local" ]] && \
        _source_local "${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/portscan/main.conf.local"
    _ps_enabled="${PORTSCAN_ENABLED:-false}"

    if [[ "$_ps_enabled" != "true" ]]; then
        log "INFO" "Portscan aggregation: Skipped (PORTSCAN_ENABLED=${_ps_enabled})"
    elif [[ -f "${NFTBAN_LIB_DIR}/core/nftban_portscan_classic.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_portscan_classic.sh" 2>/dev/null || true

        # Process kernel logs → emit micro-events for aggregation
        # Without this step, aggregate() finds no events to analyze
        if declare -f nftban_portscan_classic_process_logs >/dev/null 2>&1; then
            nftban_portscan_classic_process_logs 2>/dev/null || true
        fi

        # Run aggregation if function exists
        if declare -f nftban_portscan_aggregate >/dev/null 2>&1; then
            if nftban_portscan_aggregate --since 24h --ban 2>/dev/null; then
                log "INFO" "Portscan aggregation: OK"
            else
                log "WARN" "Portscan aggregation: Issues found"
            fi
        else
            log "INFO" "Portscan aggregation: Skipped (function not available)"
        fi
    else
        log "INFO" "Portscan aggregation: Skipped (module not loaded)"
    fi

    # ==========================================================================
    # 8. Firewall Conflict Drift Detection (Every 15 min)
    # ==========================================================================
    log "INFO" "[8/10] Checking for firewall conflicts (drift guard)..."

    # Load conflict detection library
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_firewall_conflicts.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_firewall_conflicts.sh" 2>/dev/null || true

        # Reset conflict state (these are populated by nftban_detect_all_conflicts)
        NFTBAN_FIREWALL_CONFLICTS=()
        # shellcheck disable=SC2034  # Used by conflict detection library
        NFTBAN_FIREWALL_FIXES=()
        NFTBAN_FIREWALL_SEVERITY=${CONFLICT_NONE:-0}

        # Run all conflict detectors
        if declare -f nftban_detect_all_conflicts >/dev/null 2>&1; then
            nftban_detect_all_conflicts 2>/dev/null || true

            # Check severity (CONFLICT_CRITICAL=3)
            if [[ ${NFTBAN_FIREWALL_SEVERITY:-0} -ge 3 ]]; then
                log "CRITICAL" "Firewall conflicts detected!"
                for conflict in "${NFTBAN_FIREWALL_CONFLICTS[@]}"; do
                    log "WARN" "  $conflict"
                done

                # Read policy from config (default: alert)
                local drift_policy="${NFTBAN_DRIFT_POLICY:-alert}"

                case "$drift_policy" in
                    auto)
                        log "INFO" "DRIFT_POLICY=auto - Auto-disabling conflicts..."
                        # Use existing removal functions
                        for conflict in "${NFTBAN_FIREWALL_CONFLICTS[@]}"; do
                            case "$conflict" in
                                *CSF*|*LFD*)
                                    declare -f nftban_remove_csf >/dev/null 2>&1 && nftban_remove_csf 2>/dev/null || true
                                    ;;
                                *UFW*)
                                    declare -f nftban_remove_ufw >/dev/null 2>&1 && nftban_remove_ufw 2>/dev/null || true
                                    ;;
                                *firewalld*|*FIREWALLD*)
                                    declare -f nftban_remove_firewalld >/dev/null 2>&1 && nftban_remove_firewalld 2>/dev/null || true
                                    ;;
                                *fail2ban*|*FAIL2BAN*)
                                    declare -f nftban_remove_fail2ban >/dev/null 2>&1 && nftban_remove_fail2ban 2>/dev/null || true
                                    ;;
                            esac
                        done
                        log "INFO" "Conflicts auto-disabled"
                        ;;
                    alert)
                        log "WARN" "DRIFT_POLICY=alert - Admin action required!"
                        log "WARN" "Run: nftban health conflicts --fix"
                        # Send alert if mail configured
                        if declare -f nftban_mail_send >/dev/null 2>&1; then
                            nftban_mail_send "NFTBan DRIFT ALERT: Firewall conflicts detected on $(hostname). Run: nftban health conflicts --fix" 2>/dev/null || true
                        fi
                        ;;
                    quarantine)
                        log "CRITICAL" "DRIFT_POLICY=quarantine - Stopping NFTBan to prevent firewall fight!"
                        systemctl stop nftban 2>/dev/null || true
                        ;;
                    *)
                        log "INFO" "DRIFT_POLICY=$drift_policy - No action taken"
                        ;;
                esac
            else
                log "INFO" "Firewall conflict check: OK (no conflicts)"
            fi
        else
            log "WARN" "Conflict detection function not available"
        fi
    else
        log "INFO" "Conflict detection: Skipped (library not found)"
    fi

    # ==========================================================================
    # 9. DDoS Penalty Ladder Scan (v1.60.2)
    # ==========================================================================
    log "INFO" "[9/10] DDoS penalty ladder scan..."

    # Source DDoS classic module for penalty scan function
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_ddos_classic.sh" ]]; then
        # Only source if not already loaded
        if ! declare -f nftban_ddos_penalty_scan >/dev/null 2>&1; then
            source "${NFTBAN_LIB_DIR}/core/nftban_ddos_classic.sh" 2>/dev/null || true
        fi

        if declare -f nftban_ddos_penalty_scan >/dev/null 2>&1; then
            nftban_ddos_penalty_scan 2>/dev/null || true
            log "INFO" "DDoS penalty scan: OK"
        else
            log "INFO" "DDoS penalty scan: Skipped (function not available)"
        fi
    else
        log "INFO" "DDoS penalty scan: Skipped (module not found)"
    fi

    # ==========================================================================
    # 9b. Log-retention effective-policy regeneration (v1.222.0 R2)
    # ==========================================================================
    # Picks up filesystem-capacity changes and operator conf.d/logs.conf edits by
    # regenerating /etc/logrotate.d/nftban. Deterministic + fail-safe: identical
    # inputs render byte-identically (idempotent no-op), and any failure preserves
    # the previous valid policy. This is the standing regeneration path (config
    # changes are reflected within one maintenance cycle).
    local _lr_core_bin="${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-core}"
    if [[ -x "$_lr_core_bin" ]]; then
        # Z1: FIRST complete/undo any activation interrupted by a crash, so the
        # on-disk policy set is uniform before the system logrotate timer can
        # consume it and before we (possibly) skip regeneration for unchanged
        # inputs. Deterministic + idempotent (no-op when nothing is pending).
        if "$_lr_core_bin" logretention recover >/dev/null 2>&1; then
            :
        fi
        if "$_lr_core_bin" logretention generate timer >/dev/null 2>&1; then
            log "INFO" "Log-retention policy: regenerated (OK)"
        else
            log "INFO" "Log-retention policy: regeneration skipped (previous policy retained)"
        fi
    fi

    # ==========================================================================
    # 9c. Legacy rebuild_* backup migration (v1.229.3 0C) — ONE-TIME, bounded
    # ==========================================================================
    # Resolves the pre-0B recovery population that carries no transaction terminal
    # discriminator and is therefore permanently non-prunable under 0B's
    # fail-closed rule. Runs inside the EXISTING maintenance authority -- no new
    # service, timer or cleaner -- and takes the canonical nft_operations.lock, so
    # a participating rebuild cannot execute its protected section concurrently.
    #
    # Structurally idempotent: once only the protected floor remains, the
    # candidate set is empty and later cycles delete nothing. No completion
    # marker is written, because a marker would assert historical facts this
    # migration deliberately does not claim.
    if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_legacy_backup_migration.sh" ]]; then
        source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_legacy_backup_migration.sh" 2>/dev/null || true
        if declare -f nftban_legacy_backup_migrate &>/dev/null; then
            local _lbm_out
            _lbm_out=$(nftban_legacy_backup_migrate 2>/dev/null) || true
            case "$_lbm_out" in
                *"LBM_RESULT=OK removed=0"*)  : ;;   # steady state, stay quiet
                *"LBM_RESULT=OK"*)            log "INFO" "Legacy backup migration: ${_lbm_out}" ;;
                *"REFUSED"*)                  log "INFO" "Legacy backup migration: deferred (${_lbm_out})" ;;
            esac
        fi
    fi

    # ==========================================================================
    # 10. Complete
    # ==========================================================================
    # v1.228.4 PR-3: VERDICT HONESTY.
    # A run in which the nftables ruleset could not be read has NOT completed its
    # work. Previously such a run still logged "Complete" and returned 0, so systemd
    # recorded Result=success — which is why a 100%-failure path went unnoticed on
    # 11/11 hosts for 9.7+ days. No systemd-based monitor could ever have caught it.
    # The monotonic latch is authoritative: any CANNOT_READ anywhere in this run
    # degrades the whole run, regardless of what a later probe returned.
    if [[ "${_MAINT_PROBE_UNREADABLE:-0}" -ne 0 ]] || nftban_nft_probe_session_degraded; then
        log "ERROR" "[10/10] NFTBan Maintenance INCOMPLETE — the nftables ruleset could not be read."
        log "ERROR" "Firewall state is UNKNOWN. Maintenance work depending on it was SKIPPED."
        return 1
    fi

    log "INFO" "[10/10] NFTBan Maintenance Complete"

    return 0
}

# =============================================================================
# RUN
# =============================================================================

main "$@"
