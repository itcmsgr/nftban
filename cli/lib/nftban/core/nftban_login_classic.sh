#!/usr/bin/env bash
# shellcheck disable=SC1090  # Dynamic config paths, cannot follow
# =============================================================================
# NFTBan v1.0 - Login Monitor Classic Mode Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: journalctl/log file based login monitoring
#
# meta:name="nftban_login_classic"
# meta:type="core"
# meta:header="Login Monitor Classic Mode"
# meta:version="1.47.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Classic mode login monitoring using journalctl and log files"
# meta:input="System journals and log files"
# meta:output="Failed login detection and ban actions"
# meta:depends="bash,journalctl,nftban_login.sh"
# meta:created_date="2025-12-01"
# meta:updated_date="2026-02-04"
#
# meta:inventory.files=""
# meta:inventory.binaries="journalctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/login/main.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# MODULE GUARD
# =============================================================================

[[ -n "${NFTBAN_LOGIN_CLASSIC_LOADED:-}" ]] && return 0
readonly NFTBAN_LOGIN_CLASSIC_LOADED=1

# v1.177: shared panel-aware HTTP access-log discovery (WordPress parity).
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_http_logs.sh" 2>/dev/null || true

# =============================================================================
# MODULE METADATA
# =============================================================================

# shellcheck disable=SC2034  # Module metadata used when sourced
readonly LOGIN_CLASSIC_MODULE_NAME="nftban_login_classic"
# shellcheck disable=SC2034  # Module metadata used when sourced
readonly LOGIN_CLASSIC_MODULE_VERSION="1.0.0"

# =============================================================================
# STATE TRACKING
# =============================================================================

# Failed attempt tracking (IP -> count)
declare -gA _LOGIN_CLASSIC_FAIL_COUNT=()
# Failed attempt first timestamp (IP -> timestamp)
declare -gA _LOGIN_CLASSIC_FAIL_FIRST=()
# Last seen service per IP (IP -> service)
declare -gA _LOGIN_CLASSIC_LAST_SERVICE=()
# Username enumeration tracking (IP -> comma-separated usernames)
declare -gA _LOGIN_CLASSIC_USERS_PER_IP=()
# Velocity tracking (IP -> timestamp of first event in burst window)
declare -gA _LOGIN_CLASSIC_VELOCITY_FIRST=()
# Velocity event count (IP -> count in velocity window)
declare -gA _LOGIN_CLASSIC_VELOCITY_COUNT=()
# Score tracking (IP -> current score) for decay (v1.18.9)
declare -gA _LOGIN_CLASSIC_SCORE=()
# Score timestamp (IP -> last event timestamp) for decay (v1.18.9)
declare -gA _LOGIN_CLASSIC_SCORE_TIME=()
# Distributed attack tracking (username -> comma-separated IPs) (v1.18.9)
declare -gA _LOGIN_CLASSIC_USER_IPS=()
# Running flag
declare -g _LOGIN_CLASSIC_RUNNING=0
# PIDs of background monitors
declare -gA _LOGIN_CLASSIC_MONITOR_PIDS=()
# Persistent journal cursor file (v1.18.9)
declare -g _LOGIN_CLASSIC_CURSOR_FILE="${NFTBAN_RUN_DIR:-/run/nftban}/login-journal-cursor"

# =============================================================================
# INITIALIZATION
# =============================================================================

nftban_login_classic_init() {
    nftban_login_log "INFO" "Initializing classic mode..."

    # Load state from disk if exists (safe line-by-line parsing, no source)
    local state_file="${LOGIN_CLASSIC_STATE_FILE:-/var/lib/nftban/login-classic-state.db}"
    if [[ -f "$state_file" ]]; then
        while IFS='=' read -r key value; do
            # Skip comments and blank lines
            [[ -z "$key" || "$key" =~ ^# ]] && continue
            # Only allow known variable patterns with safe values
            [[ "$key" =~ ^_LOGIN_CLASSIC_(FAIL_COUNT|FAIL_FIRST|LAST_SERVICE|USERS_PER_IP|VELOCITY_FIRST|VELOCITY_COUNT|SCORE|SCORE_TIME|USER_IPS)(\[[^]]+\])?$ ]] || continue
            [[ "$value" =~ ^[0-9a-zA-Z.,_:\ -]+$ ]] || continue
            declare "$key=$value" 2>/dev/null || true
        done < "$state_file"
    fi

    # Ban threshold: 10 failures in 5 minutes (300 seconds) for all services
    : "${LOGIN_CLASSIC_FAIL_THRESHOLD:=10}"
    : "${LOGIN_CLASSIC_FAIL_WINDOW:=300}"
    : "${LOGIN_CLASSIC_SCORE_FAILED:=0.10}"
    : "${LOGIN_CLASSIC_SCORE_INVALID_USER:=0.15}"
    : "${LOGIN_CLASSIC_SCORE_ROOT_ATTEMPT:=0.25}"
    : "${LOGIN_CLASSIC_THRESHOLD_BLOCK_SHORT:=0.45}"
    : "${LOGIN_CLASSIC_THRESHOLD_BLOCK_LONG:=0.65}"
    : "${LOGIN_CLASSIC_BAN_DURATION_SHORT:=900}"
    : "${LOGIN_CLASSIC_BAN_DURATION_LONG:=3600}"

    # Username enumeration detection (v1.18.8)
    : "${LOGIN_CLASSIC_ENUMERATION_THRESHOLD:=5}"
    : "${LOGIN_CLASSIC_SCORE_ENUMERATION:=0.20}"

    # Velocity/burst detection (v1.18.8)
    : "${LOGIN_CLASSIC_VELOCITY_WINDOW:=30}"
    : "${LOGIN_CLASSIC_VELOCITY_THRESHOLD:=5}"
    : "${LOGIN_CLASSIC_SCORE_VELOCITY:=0.25}"

    # Score decay over time (v1.18.9) - prevent permanent score inflation
    : "${LOGIN_CLASSIC_SCORE_DECAY_RATE:=0.01}"    # Score points to decay per minute
    : "${LOGIN_CLASSIC_SCORE_DECAY_INTERVAL:=60}"   # Seconds between decay applications

    # Distributed attack detection (v1.18.9) - same username from multiple IPs
    : "${LOGIN_CLASSIC_DISTRIBUTED_THRESHOLD:=3}"   # IPs per username to trigger
    : "${LOGIN_CLASSIC_SCORE_DISTRIBUTED:=0.30}"    # Score bonus for distributed attack

    # Persistent event cursor (v1.18.9) - prevent double-processing on restart
    : "${LOGIN_CLASSIC_CURSOR_ENABLED:=true}"
    mkdir -p "$(dirname "$_LOGIN_CLASSIC_CURSOR_FILE")" 2>/dev/null || true

    # bc dependency validation with integer fallback (v1.18.8)
    if ! command -v bc &>/dev/null; then
        nftban_login_log "WARN" "bc not found, using integer scoring mode"
        export LOGIN_USE_INTEGER_SCORING=1
        # Convert float thresholds to integer (multiply by 100)
        : "${LOGIN_CLASSIC_THRESHOLD_BLOCK_SHORT_INT:=45}"
        : "${LOGIN_CLASSIC_THRESHOLD_BLOCK_LONG_INT:=65}"
    fi

    return 0
}

# =============================================================================
# JOURNALCTL MONITORING
# =============================================================================

# Start monitoring a specific service via journalctl
_nftban_login_classic_monitor_journal() {
    local service="$1"
    local units="$2"
    local pattern_failed="$3"
    local pattern_invalid="${4:-}"

    nftban_login_log "INFO" "Starting journal monitor for $service (units: $units)"

    # Build journalctl command
    # BUG-MED-003 FIX: Remove -n 0 flag - incompatible with systemd 257+ (Fedora 43+)
    # The -f flag already implies "start from now", -n 0 caused pipe issues
    local -a journal_cmd=(journalctl -f)

    # Persistent cursor support (v1.18.9) - prevent double-processing on restart
    local cursor_file="${_LOGIN_CLASSIC_CURSOR_FILE}.${service}"
    if [[ "${LOGIN_CLASSIC_CURSOR_ENABLED:-true}" == "true" && -f "$cursor_file" ]]; then
        local saved_cursor
        saved_cursor=$(cat "$cursor_file" 2>/dev/null)
        if [[ -n "$saved_cursor" ]]; then
            journal_cmd+=(--after-cursor="$saved_cursor")
            nftban_login_log "INFO" "Resuming $service from saved cursor"
        fi
    fi

    # Add journal filter
    # v1.47.0: For SSH service, use _COMM=sshd instead of -u sshd
    # This works across ALL OpenSSH versions including 9.9+ sshd-session split
    # where auth failures may be logged under sshd-session unit instead of sshd
    if [[ "$service" == "ssh" ]]; then
        journal_cmd+=(_COMM=sshd)
    else
        IFS=',' read -ra unit_array <<< "$units"
        for unit in "${unit_array[@]}"; do
            journal_cmd+=(-u "$unit")
        done
    fi

    # Use JSON output if jq is available
    if command -v jq &>/dev/null && [[ "${LOGIN_CLASSIC_JOURNALCTL_JSON:-true}" == "true" ]]; then
        journal_cmd+=(--output=json --show-cursor)
        # v1.19.26: Add || true to prevent errexit on pipe close (journalctl -f exits 1 when pipe closes)
        "${journal_cmd[@]}" 2>/dev/null | while read -r line; do
            # Save cursor for persistence (v1.18.9)
            local cursor
            cursor=$(echo "$line" | jq -r '.__CURSOR // empty' 2>/dev/null)
            if [[ -n "$cursor" && "${LOGIN_CLASSIC_CURSOR_ENABLED:-true}" == "true" ]]; then
                echo "$cursor" > "${cursor_file}.tmp" 2>/dev/null && mv -f "${cursor_file}.tmp" "$cursor_file" 2>/dev/null || true
            fi

            local message
            message=$(echo "$line" | jq -r '.MESSAGE // empty' 2>/dev/null) || continue
            [[ -z "$message" ]] && continue
            _nftban_login_classic_process_message "$service" "$message" "$pattern_failed" "$pattern_invalid"
        done || true
    else
        # Fallback to text parsing
        # v1.19.26: Add || true to prevent errexit on pipe close
        "${journal_cmd[@]}" 2>/dev/null | while read -r line; do
            _nftban_login_classic_process_message "$service" "$line" "$pattern_failed" "$pattern_invalid"
        done || true
    fi
}

# Process a log message and extract IP/user
_nftban_login_classic_process_message() {
    local service="$1"
    local message="$2"
    local pattern_failed="$3"
    local pattern_invalid="${4:-}"

    local ip=""
    local user=""
    local event_type="failed"

    # SSH patterns
    if [[ "$service" == "ssh" ]]; then
        # Failed password for user from IP
        if [[ "$message" =~ Failed\ password\ for\ ([^[:space:]]+)\ from\ ([0-9a-fA-F.:]+) ]]; then
            user="${BASH_REMATCH[1]}"
            ip="${BASH_REMATCH[2]}"
        # Failed password for invalid user
        elif [[ "$message" =~ Failed\ password\ for\ invalid\ user\ ([^[:space:]]+)\ from\ ([0-9a-fA-F.:]+) ]]; then
            user="${BASH_REMATCH[1]}"
            ip="${BASH_REMATCH[2]}"
            event_type="invalid_user"
        # Invalid user from IP
        elif [[ "$message" =~ Invalid\ user\ ([^[:space:]]+)\ from\ ([0-9a-fA-F.:]+) ]]; then
            user="${BASH_REMATCH[1]}"
            ip="${BASH_REMATCH[2]}"
            event_type="invalid_user"
        # Disconnected preauth (potential scan)
        elif [[ "$message" =~ Disconnected\ from.*\ ([0-9a-fA-F.:]+).*preauth ]]; then
            ip="${BASH_REMATCH[1]}"
            user="unknown"
            event_type="preauth"
        # Too many authentication failures
        elif [[ "$message" =~ ([0-9a-fA-F.:]+).*[Tt]oo\ many\ authentication\ failures ]]; then
            ip="${BASH_REMATCH[1]}"
            user="unknown"
            event_type="too_many"
        fi
    fi

    # Mail patterns (Dovecot, Exim, Postfix)
    if [[ "$service" == "dovecot" ]] || [[ "$service" == "exim" ]] || [[ "$service" == "postfix" ]]; then
        # Generic: auth failure from IP
        if [[ "$message" =~ [Aa]uth.*fail.*rip=([0-9a-fA-F.:]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            user="unknown"
        elif [[ "$message" =~ [Aa]uthentication\ fail.*from\ ([0-9a-fA-F.:]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            user="unknown"
        # SASL authentication failed (Postfix)
        # Format: "warning: hostname[IP]: SASL LOGIN authentication failed"
        elif [[ "$message" =~ \[([0-9a-fA-F.:]+)\].*SASL.*authentication\ failed ]]; then
            ip="${BASH_REMATCH[1]}"
            user="unknown"
        # Alternative SASL format (IP after SASL)
        elif [[ "$message" =~ SASL.*authentication\ failed.*\[([0-9a-fA-F.:]+)\] ]]; then
            ip="${BASH_REMATCH[1]}"
            user="unknown"
        fi
    fi

    # FTP patterns (Pure-FTPd, vsftpd)
    if [[ "$service" == "pureftpd" ]] || [[ "$service" == "vsftpd" ]] || [[ "$service" == "proftpd" ]]; then
        if [[ "$message" =~ [Aa]uthentication\ fail.*@([0-9a-fA-F.:]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            user="unknown"
        elif [[ "$message" =~ FAIL\ LOGIN.*from\ ([0-9a-fA-F.:]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            user="unknown"
        elif [[ "$message" =~ \[([0-9a-fA-F.:]+)\].*Login\ failed ]]; then
            ip="${BASH_REMATCH[1]}"
            user="unknown"
        fi
    fi

    # If we found an IP, process the event
    if [[ -n "$ip" ]]; then
        _nftban_login_classic_process_event "$ip" "$user" "$service" "$event_type"
    fi
}

# =============================================================================
# LOG FILE MONITORING
# =============================================================================

# Monitor a log file for patterns
_nftban_login_classic_monitor_file() {
    local service="$1"
    local log_file="$2"
    local pattern="$3"

    [[ ! -f "$log_file" ]] && return 1

    nftban_login_log "INFO" "Starting file monitor for $service ($log_file)"

    tail -F "$log_file" 2>/dev/null | while read -r line; do
        _nftban_login_classic_process_web_log "$service" "$line" "$pattern"
    done
}

# Process web log line (Apache/Nginx)
_nftban_login_classic_process_web_log() {
    local service="$1"
    local line="$2"
    local pattern="$3"

    local ip=""

    # WordPress/XML-RPC: POST to wp-login.php or xmlrpc.php
    if [[ "$service" == "wordpress" ]] || [[ "$service" == "xmlrpc" ]]; then
        if [[ "$line" =~ ^([0-9a-fA-F.:]+).*POST.*/wp-login\.php ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "wordpress" "login_attempt"
        elif [[ "$line" =~ ^([0-9a-fA-F.:]+).*POST.*/xmlrpc\.php ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "xmlrpc" "xmlrpc_post"
        fi
    fi

    # Apache/Nginx HTTP auth failure (401)
    if [[ "$service" == "apache" ]] || [[ "$service" == "nginx" ]]; then
        if [[ "$line" =~ user.*authentication\ failure.*client:\ ([0-9a-fA-F.:]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "$service" "http_auth"
        fi
    fi

    # DirectAdmin
    # v1.48.0: Fixed regex — DA format is "'IP' N failed login attempts. Account 'user'"
    # NOT cPanel format "FAILED LOGIN...ip=X.X.X.X"
    if [[ "$service" == "directadmin" ]]; then
        if [[ "$line" =~ \'([0-9a-fA-F.:]+)\'.*failed\ login ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "directadmin" "failed"
        fi
    fi

    # cPanel login failure (v1.18.8, v1.48.0: added access_log 401 format)
    # Real format (access_log): "IP - user [date] "POST /login/?login_only=1" 401"
    # Legacy format (login_log): "FAILED LOGIN user=admin ip=1.2.3.4"
    if [[ "$service" == "cpanel" ]]; then
        # v1.48.0: Real cPanel access_log — "IP - user [date] POST /login/ 401"
        if [[ "$line" =~ ^([0-9a-fA-F.:]+).*POST.*/login/.*\ 401\  ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "cpanel" "failed"
        elif [[ "$line" =~ FAILED.*ip=([0-9a-fA-F.:]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "cpanel" "failed"
        elif [[ "$line" =~ [Ii]nvalid.*ip=([0-9a-fA-F.:]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "cpanel" "invalid"
        fi
    fi

    # Plesk login failure (v1.18.8, v1.48.0: fixed regex for real Plesk format)
    # Real format: "[Action Log] Failed login attempt with login 'user' from IP 1.2.3.4"
    if [[ "$service" == "plesk" ]]; then
        # v1.48.0: Real Plesk panel.log format — "Failed login attempt...from IP X.X.X.X"
        if [[ "$line" =~ [Ff]ailed\ login.*from\ IP\ ([0-9a-fA-F.:]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "plesk" "failed"
        elif [[ "$line" =~ [Aa]uthentication\ failed.*from\ ([0-9a-fA-F.:]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "plesk" "failed"
        elif [[ "$line" =~ [Ii]ncorrect.*password.*from.*([0-9a-fA-F.:]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "plesk" "failed"
        elif [[ "$line" =~ [Ii]nvalid\ credentials.*from\ ([0-9a-fA-F.:]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "plesk" "invalid"
        fi
    fi

    # Mail services (Postfix SASL, Dovecot) from /var/log/maillog or /var/log/mail.log
    if [[ "$service" == "mail" ]] || [[ "$service" == "postfix_file" ]]; then
        # Postfix SASL: "warning: hostname[IP]: SASL LOGIN authentication failed"
        if [[ "$line" =~ \[([0-9a-fA-F.:]+)\].*SASL.*authentication\ failed ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "postfix" "sasl_auth_fail"
        # Alternative: "SASL ... failed ... [IP]"
        elif [[ "$line" =~ SASL.*authentication\ failed.*\[([0-9a-fA-F.:]+)\] ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "postfix" "sasl_auth_fail"
        # Dovecot from mail log: "auth failed ... rip=IP"
        elif [[ "$line" =~ [Aa]uth.*fail.*rip=([0-9a-fA-F.:]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "dovecot" "auth_fail"
        # Generic authentication failure from mail log
        elif [[ "$line" =~ [Aa]uthentication\ fail.*from\ ([0-9a-fA-F.:]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "mail" "auth_fail"
        fi
    fi

    # Exim log file patterns (cPanel, DirectAdmin)
    # Format: "2026-02-12 10:30:45 H=hostname [IP] ... authenticator failed"
    # Or: "2026-02-12 10:30:45 [IP] rejected ... AUTH ... failed"
    if [[ "$service" == "exim_file" ]]; then
        # Exim authenticator failed: "H=hostname [IP] ... authenticator failed"
        if [[ "$line" =~ \[([0-9a-fA-F.:]+)\].*authenticator\ failed ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "exim" "auth_fail"
        # Exim AUTH failed: "[IP] ... AUTH ... failed"
        elif [[ "$line" =~ \[([0-9a-fA-F.:]+)\].*AUTH.*failed ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "exim" "auth_fail"
        # Exim login failed: "login failed ... [IP]" or "[IP] ... login failed"
        elif [[ "$line" =~ \[([0-9a-fA-F.:]+)\].*login\ failed ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "exim" "login_fail"
        elif [[ "$line" =~ login\ failed.*\[([0-9a-fA-F.:]+)\] ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "exim" "login_fail"
        # Exim rejected AUTH: "rejected ... AUTH"
        elif [[ "$line" =~ \[([0-9a-fA-F.:]+)\].*rejected.*AUTH ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "exim" "auth_rejected"
        fi
    fi
}

# =============================================================================
# SCORE DECAY (v1.18.9)
# =============================================================================

# Apply score decay over time to prevent permanent inflation
_nftban_login_classic_apply_decay() {
    local ip="$1"
    local now
    now=$(date +%s)

    # Get last score time
    local last_time="${_LOGIN_CLASSIC_SCORE_TIME[$ip]:-}"
    if [[ -z "$last_time" ]]; then
        _LOGIN_CLASSIC_SCORE_TIME[$ip]=$now
        return 0
    fi

    # Calculate elapsed minutes
    local elapsed=$((now - last_time))
    local decay_interval="${LOGIN_CLASSIC_SCORE_DECAY_INTERVAL:-60}"

    if [[ $elapsed -lt $decay_interval ]]; then
        return 0  # Not enough time passed
    fi

    # Calculate decay amount
    local decay_rate="${LOGIN_CLASSIC_SCORE_DECAY_RATE:-0.01}"
    local minutes=$((elapsed / 60))
    local current_score="${_LOGIN_CLASSIC_SCORE[$ip]:-0}"

    if [[ "$current_score" == "0" ]]; then
        _LOGIN_CLASSIC_SCORE_TIME[$ip]=$now
        return 0
    fi

    # Apply decay (score -= decay_rate * minutes)
    local new_score
    if command -v bc &>/dev/null; then
        new_score=$(echo "$current_score - ($decay_rate * $minutes)" | bc -l)
        # Ensure non-negative
        if (( $(echo "$new_score < 0" | bc -l) )); then
            new_score="0"
        fi
    else
        # Integer fallback
        local decay_amount=$((minutes * 1))  # 1 point per minute
        local int_score=$((current_score * 100))
        int_score=$((int_score - decay_amount))
        [[ $int_score -lt 0 ]] && int_score=0
        new_score=$int_score
    fi

    _LOGIN_CLASSIC_SCORE[$ip]="$new_score"
    _LOGIN_CLASSIC_SCORE_TIME[$ip]=$now

    if [[ "$new_score" != "$current_score" ]]; then
        nftban_login_log "DEBUG" "Score decay for $ip: $current_score -> $new_score (${minutes}m elapsed)"
    fi
}

# =============================================================================
# EVENT PROCESSING
# =============================================================================

# Process a detected failed login event
_nftban_login_classic_process_event() {
    local ip="$1"
    local user="$2"
    local service="$3"
    local event_type="$4"
    local now
    now=$(date +%s)

    # Skip whitelisted IPs
    if _nftban_login_classic_is_whitelisted "$ip"; then
        return 0
    fi

    # Track unique usernames per IP for enumeration detection (v1.18.8)
    if [[ -n "$user" && "$user" != "unknown" ]]; then
        local ip_users="${_LOGIN_CLASSIC_USERS_PER_IP[$ip]:-}"
        if [[ ! ",$ip_users," == *",$user,"* ]]; then
            _LOGIN_CLASSIC_USERS_PER_IP[$ip]="${ip_users:+$ip_users,}$user"
        fi

        # Track distributed attacks - same username from multiple IPs (v1.18.9)
        local user_ips="${_LOGIN_CLASSIC_USER_IPS[$user]:-}"
        if [[ ! ",$user_ips," == *",$ip,"* ]]; then
            _LOGIN_CLASSIC_USER_IPS[$user]="${user_ips:+$user_ips,}$ip"
        fi
    fi

    # Apply score decay before calculating new score (v1.18.9)
    _nftban_login_classic_apply_decay "$ip"

    # Track velocity (rapid-fire attacks) (v1.18.8)
    local velocity_first="${_LOGIN_CLASSIC_VELOCITY_FIRST[$ip]:-}"
    local velocity_window="${LOGIN_CLASSIC_VELOCITY_WINDOW:-30}"
    if [[ -z "$velocity_first" ]] || [[ $((now - velocity_first)) -gt $velocity_window ]]; then
        # Reset velocity tracking
        _LOGIN_CLASSIC_VELOCITY_FIRST[$ip]=$now
        _LOGIN_CLASSIC_VELOCITY_COUNT[$ip]=1
    else
        # Increment velocity counter
        ((_LOGIN_CLASSIC_VELOCITY_COUNT[$ip]++)) || true
    fi

    # Get service-specific thresholds
    local threshold_var="LOGIN_SERVICE_${service^^}_FAIL_THRESHOLD"
    local window_var="LOGIN_SERVICE_${service^^}_FAIL_WINDOW"
    local threshold="${!threshold_var:-${LOGIN_CLASSIC_FAIL_THRESHOLD:-5}}"
    local window="${!window_var:-${LOGIN_CLASSIC_FAIL_WINDOW:-300}}"

    # Track the attempt
    local key="${service}:${ip}"

    if [[ -z "${_LOGIN_CLASSIC_FAIL_FIRST[$key]:-}" ]]; then
        # First failure
        _LOGIN_CLASSIC_FAIL_COUNT[$key]=1
        _LOGIN_CLASSIC_FAIL_FIRST[$key]=$now
    else
        # Check if within window
        local first="${_LOGIN_CLASSIC_FAIL_FIRST[$key]}"
        local elapsed
        elapsed=$((now - first))

        if [[ $elapsed -lt $window ]]; then
            # Within window - increment (|| true to avoid set -e exit)
            ((_LOGIN_CLASSIC_FAIL_COUNT[$key]++)) || true
        else
            # Outside window - reset
            _LOGIN_CLASSIC_FAIL_COUNT[$key]=1
            _LOGIN_CLASSIC_FAIL_FIRST[$key]=$now
        fi
    fi

    local count="${_LOGIN_CLASSIC_FAIL_COUNT[$key]}"
    _LOGIN_CLASSIC_LAST_SERVICE[$ip]="$service"

    nftban_login_log "DEBUG" "Event: $service $event_type from $ip (user: $user, count: $count/$threshold)"

    # Calculate score
    local score
    score=$(_nftban_login_classic_calculate_score "$ip" "$user" "$service" "$event_type" "$count")

    # Check thresholds
    if (( $(echo "$score >= ${LOGIN_CLASSIC_THRESHOLD_BLOCK_LONG:-0.65}" | bc -l) )); then
        # Long ban
        local duration="${LOGIN_CLASSIC_BAN_DURATION_LONG:-3600}"
        nftban_login_log "INFO" "Banning $ip (long) - score: $score, service: $service"
        nftban_login_ban "$ip" "${service}_brute_force" "$duration" "$service"
        _nftban_login_classic_clear_ip "$ip"
    elif (( $(echo "$score >= ${LOGIN_CLASSIC_THRESHOLD_BLOCK_SHORT:-0.45}" | bc -l) )); then
        # Short ban
        local duration="${LOGIN_CLASSIC_BAN_DURATION_SHORT:-900}"
        nftban_login_log "INFO" "Banning $ip (short) - score: $score, service: $service"
        nftban_login_ban "$ip" "${service}_brute_force" "$duration" "$service"
        _nftban_login_classic_clear_ip "$ip"
    elif [[ $count -ge $threshold ]]; then
        # Threshold-based ban (fallback)
        local duration="${LOGIN_CLASSIC_BAN_DURATION_SHORT:-900}"
        nftban_login_log "INFO" "Banning $ip (threshold) - count: $count, service: $service"
        nftban_login_ban "$ip" "${service}_threshold" "$duration" "$service"
        _nftban_login_classic_clear_ip "$ip"
    fi
}

# Calculate risk score for an event
_nftban_login_classic_calculate_score() {
    local ip="$1"
    local user="$2"
    local service="$3"
    local event_type="$4"
    local count="$5"

    local score=0

    # Base score for failed attempt
    score=$(echo "$score + ${LOGIN_CLASSIC_SCORE_FAILED:-0.10}" | bc -l)

    # Invalid user penalty
    if [[ "$event_type" == "invalid_user" ]]; then
        score=$(echo "$score + ${LOGIN_CLASSIC_SCORE_INVALID_USER:-0.15}" | bc -l)
    fi

    # Root login attempt penalty
    if [[ "$user" == "root" ]] || [[ "$user" == "admin" ]] || [[ "$user" == "administrator" ]]; then
        score=$(echo "$score + ${LOGIN_CLASSIC_SCORE_ROOT_ATTEMPT:-0.25}" | bc -l)
    fi

    # Honeypot user penalty
    local honeypot_users="${LOGIN_CLASSIC_HONEYPOT_USERS:-admin,root,test,guest,user,administrator,oracle,mysql,postgres}"
    if [[ ",$honeypot_users," == *",$user,"* ]]; then
        score=$(echo "$score + ${LOGIN_CLASSIC_SCORE_HONEYPOT_USER:-0.20}" | bc -l)
    fi

    # Repetition bonuses
    if [[ $count -ge 10 ]]; then
        score=$(echo "$score + ${LOGIN_CLASSIC_SCORE_REPEAT_10:-0.25}" | bc -l)
    elif [[ $count -ge 5 ]]; then
        score=$(echo "$score + ${LOGIN_CLASSIC_SCORE_REPEAT_5:-0.15}" | bc -l)
    elif [[ $count -ge 3 ]]; then
        score=$(echo "$score + ${LOGIN_CLASSIC_SCORE_REPEAT_3:-0.10}" | bc -l)
    fi

    # Multi-service attack
    local service_count=0
    for key in "${!_LOGIN_CLASSIC_FAIL_COUNT[@]}"; do
        if [[ "$key" == *":$ip" ]]; then
            # Use || true to avoid set -e exit on 0++ (evaluates to false)
            ((service_count++)) || true
        fi
    done
    if [[ $service_count -gt 1 ]]; then
        score=$(echo "$score + ${LOGIN_CLASSIC_SCORE_MULTI_SERVICE:-0.15}" | bc -l)
    fi

    # Username enumeration detection (v1.18.8)
    local unique_users=0
    if [[ -n "${_LOGIN_CLASSIC_USERS_PER_IP[$ip]:-}" ]]; then
        unique_users=$(echo "${_LOGIN_CLASSIC_USERS_PER_IP[$ip]}" | tr ',' '\n' | wc -l)
    fi
    if [[ $unique_users -gt ${LOGIN_CLASSIC_ENUMERATION_THRESHOLD:-5} ]]; then
        score=$(echo "$score + ${LOGIN_CLASSIC_SCORE_ENUMERATION:-0.20}" | bc -l)
        nftban_login_log "DEBUG" "Enumeration detected from $ip: $unique_users unique users"
    fi

    # Velocity/burst detection (v1.18.8)
    local velocity_count="${_LOGIN_CLASSIC_VELOCITY_COUNT[$ip]:-0}"
    if [[ $velocity_count -gt ${LOGIN_CLASSIC_VELOCITY_THRESHOLD:-5} ]]; then
        score=$(echo "$score + ${LOGIN_CLASSIC_SCORE_VELOCITY:-0.25}" | bc -l)
        nftban_login_log "DEBUG" "Velocity attack detected from $ip: $velocity_count events in ${LOGIN_CLASSIC_VELOCITY_WINDOW:-30}s"
    fi

    # Distributed attack detection (v1.18.9) - same username from multiple IPs
    if [[ -n "$user" && "$user" != "unknown" && -n "${_LOGIN_CLASSIC_USER_IPS[$user]:-}" ]]; then
        local unique_ips_for_user
        unique_ips_for_user=$(echo "${_LOGIN_CLASSIC_USER_IPS[$user]}" | tr ',' '\n' | wc -l)
        if [[ $unique_ips_for_user -ge ${LOGIN_CLASSIC_DISTRIBUTED_THRESHOLD:-3} ]]; then
            score=$(echo "$score + ${LOGIN_CLASSIC_SCORE_DISTRIBUTED:-0.30}" | bc -l)
            nftban_login_log "DEBUG" "Distributed attack on user $user: $unique_ips_for_user IPs"
        fi
    fi

    # Service-specific multiplier
    local multiplier_var="LOGIN_SERVICE_${service^^}_RISK_MULTIPLIER"
    local multiplier="${!multiplier_var:-1.0}"
    score=$(echo "$score * $multiplier" | bc -l)

    # Cap at 1.0
    if (( $(echo "$score > 1.0" | bc -l) )); then
        score="1.0"
    fi

    echo "$score"
}

# Check if IP is whitelisted
_nftban_login_classic_is_whitelisted() {
    local ip="$1"

    # Localhost
    if [[ "${LOGIN_WHITELIST_LOCALHOST:-true}" == "true" ]]; then
        [[ "$ip" == "127.0.0.1" ]] && return 0
        [[ "$ip" == "::1" ]] && return 0
    fi

    # Private networks — v1.19.0: IPv4 + IPv6 parity (RFC 1918 + RFC 4193)
    if [[ "${LOGIN_WHITELIST_PRIVATE:-true}" == "true" ]]; then
        # IPv4 private (RFC 1918)
        [[ "$ip" =~ ^10\. ]] && return 0
        [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
        [[ "$ip" =~ ^192\.168\. ]] && return 0
        # IPv6 private (RFC 4193 ULA + link-local)
        [[ "$ip" =~ ^[Ff][CcDd] ]] && return 0
        [[ "$ip" =~ ^[Ff][Ee]80: ]] && return 0
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

# Clear tracking for an IP after ban
_nftban_login_classic_clear_ip() {
    local ip="$1"

    for key in "${!_LOGIN_CLASSIC_FAIL_COUNT[@]}"; do
        if [[ "$key" == *":$ip" ]]; then
            unset "_LOGIN_CLASSIC_FAIL_COUNT[$key]"
            unset "_LOGIN_CLASSIC_FAIL_FIRST[$key]"
        fi
    done
    unset "_LOGIN_CLASSIC_LAST_SERVICE[$ip]"
    # Clear enumeration and velocity tracking (v1.18.8)
    unset "_LOGIN_CLASSIC_USERS_PER_IP[$ip]"
    unset "_LOGIN_CLASSIC_VELOCITY_FIRST[$ip]"
    unset "_LOGIN_CLASSIC_VELOCITY_COUNT[$ip]"
}

# =============================================================================
# SMART LOG SOURCE DETECTION
# =============================================================================

# Check if a service has recent journal entries (smart detection)
# Returns 0 if journal has entries, 1 if empty/unavailable
_nftban_login_classic_journal_has_entries() {
    local units="$1"
    local check_window="${2:-5 min ago}"

    # Build journalctl command to check for entries
    local -a journal_cmd=(journalctl --since "$check_window" -q)

    IFS=',' read -ra unit_array <<< "$units"
    for unit in "${unit_array[@]}"; do
        journal_cmd+=(-u "$unit")
    done

    # Check if any entries exist (limit to 1 for speed)
    local count
    count=$("${journal_cmd[@]}" 2>/dev/null | head -1 | wc -l)

    [[ $count -gt 0 ]]
}

# Find available mail log file
_nftban_login_classic_find_mail_log() {
    local log_file=""
    for f in "${LOGIN_SERVICE_MAIL_LOG:-}" \
             "/var/log/maillog" \
             "/var/log/mail.log"; do
        if [[ -n "$f" ]] && [[ -f "$f" ]]; then
            log_file="$f"
            break
        fi
    done
    echo "$log_file"
}

# Find available Exim log file
_nftban_login_classic_find_exim_log() {
    local log_file=""
    for f in "${LOGIN_SERVICE_EXIM_LOG:-}" \
             "/var/log/exim_mainlog" \
             "/var/log/exim/mainlog" \
             "/var/log/exim4/mainlog"; do
        if [[ -n "$f" ]] && [[ -f "$f" ]]; then
            log_file="$f"
            break
        fi
    done
    echo "$log_file"
}

# =============================================================================
# MAIN OPERATIONS
# =============================================================================

# Start classic mode monitoring
nftban_login_classic_start() {
    if [[ $_LOGIN_CLASSIC_RUNNING -eq 1 ]]; then
        nftban_login_log "WARN" "Classic mode already running"
        return 0
    fi

    _LOGIN_CLASSIC_RUNNING=1
    nftban_login_log "INFO" "Starting classic mode monitoring"

    # =========================================================================
    # SSH - always use journal (SSH always logs to systemd)
    # =========================================================================
    if nftban_login_service_detected "ssh"; then
        local units="${LOGIN_SERVICE_SSH_UNITS:-sshd,ssh}"
        nftban_login_log "INFO" "SSH: using journal ($units)"
        _nftban_login_classic_monitor_journal "ssh" "$units" "" &
        _LOGIN_CLASSIC_MONITOR_PIDS[ssh]=$!
    fi

    # =========================================================================
    # DOVECOT - smart detection: journal OR mail log file
    # =========================================================================
    if nftban_login_service_detected "dovecot"; then
        local units="${LOGIN_SERVICE_DOVECOT_UNITS:-dovecot}"
        if _nftban_login_classic_journal_has_entries "$units"; then
            nftban_login_log "INFO" "Dovecot: using journal ($units)"
            _nftban_login_classic_monitor_journal "dovecot" "$units" "" &
            _LOGIN_CLASSIC_MONITOR_PIDS[dovecot]=$!
        else
            local mail_log
            mail_log=$(_nftban_login_classic_find_mail_log)
            if [[ -n "$mail_log" ]]; then
                nftban_login_log "INFO" "Dovecot: journal empty, using file ($mail_log)"
                _nftban_login_classic_monitor_file "postfix_file" "$mail_log" "" &
                _LOGIN_CLASSIC_MONITOR_PIDS[dovecot_file]=$!
            else
                nftban_login_log "WARN" "Dovecot: no log source available"
            fi
        fi
    fi

    # =========================================================================
    # POSTFIX - smart detection: journal OR mail log file (not both)
    # =========================================================================
    if nftban_login_service_detected "postfix"; then
        local units="${LOGIN_SERVICE_POSTFIX_UNITS:-postfix}"
        # Also check postfix@- for Plesk/systemd template units
        local extended_units="${units},postfix@-"

        if _nftban_login_classic_journal_has_entries "$extended_units"; then
            nftban_login_log "INFO" "Postfix: using journal ($units)"
            _nftban_login_classic_monitor_journal "postfix" "$extended_units" "" &
            _LOGIN_CLASSIC_MONITOR_PIDS[postfix]=$!
        else
            local mail_log
            mail_log=$(_nftban_login_classic_find_mail_log)
            if [[ -n "$mail_log" ]]; then
                nftban_login_log "INFO" "Postfix: journal empty, using file ($mail_log)"
                _nftban_login_classic_monitor_file "postfix_file" "$mail_log" "" &
                _LOGIN_CLASSIC_MONITOR_PIDS[postfix_file]=$!
            else
                nftban_login_log "WARN" "Postfix: no log source available"
            fi
        fi
    # If no postfix but dovecot wasn't started with file monitor, check mail log
    elif [[ -z "${_LOGIN_CLASSIC_MONITOR_PIDS[dovecot_file]:-}" ]]; then
        local mail_log
        mail_log=$(_nftban_login_classic_find_mail_log)
        if [[ -n "$mail_log" ]]; then
            nftban_login_log "INFO" "Mail log: starting file monitor ($mail_log)"
            _nftban_login_classic_monitor_file "postfix_file" "$mail_log" "" &
            _LOGIN_CLASSIC_MONITOR_PIDS[mail_file]=$!
        fi
    fi

    # =========================================================================
    # EXIM - smart detection: journal OR exim log file (not both)
    # =========================================================================
    if nftban_login_service_detected "exim"; then
        local units="${LOGIN_SERVICE_EXIM_UNITS:-exim,exim4}"

        if _nftban_login_classic_journal_has_entries "$units"; then
            nftban_login_log "INFO" "Exim: using journal ($units)"
            _nftban_login_classic_monitor_journal "exim" "$units" "" &
            _LOGIN_CLASSIC_MONITOR_PIDS[exim]=$!
        else
            local exim_log
            exim_log=$(_nftban_login_classic_find_exim_log)
            if [[ -n "$exim_log" ]]; then
                nftban_login_log "INFO" "Exim: journal empty, using file ($exim_log)"
                _nftban_login_classic_monitor_file "exim_file" "$exim_log" "" &
                _LOGIN_CLASSIC_MONITOR_PIDS[exim_file]=$!
            else
                nftban_login_log "WARN" "Exim: no log source available"
            fi
        fi
    fi

    # =========================================================================
    # FTP SERVICES - use journal (FTP services typically log to systemd)
    # =========================================================================

    # Pure-FTPd
    if nftban_login_service_detected "pureftpd"; then
        local units="${LOGIN_SERVICE_PUREFTPD_UNITS:-pure-ftpd}"
        nftban_login_log "INFO" "Pure-FTPd: using journal ($units)"
        _nftban_login_classic_monitor_journal "pureftpd" "$units" "" &
        _LOGIN_CLASSIC_MONITOR_PIDS[pureftpd]=$!
    fi

    # vsftpd
    if nftban_login_service_detected "vsftpd"; then
        local units="${LOGIN_SERVICE_VSFTPD_UNITS:-vsftpd}"
        nftban_login_log "INFO" "vsftpd: using journal ($units)"
        _nftban_login_classic_monitor_journal "vsftpd" "$units" "" &
        _LOGIN_CLASSIC_MONITOR_PIDS[vsftpd]=$!
    fi

    # ProFTPD
    if nftban_login_service_detected "proftpd"; then
        local units="${LOGIN_SERVICE_PROFTPD_UNITS:-proftpd}"
        nftban_login_log "INFO" "ProFTPD: using journal ($units)"
        _nftban_login_classic_monitor_journal "proftpd" "$units" "" &
        _LOGIN_CLASSIC_MONITOR_PIDS[proftpd]=$!
    fi

    # Start WordPress monitor(s) — file-based.
    # v1.177 parity (SHELL/CLASSIC-MODE SURFACE ONLY): use the shared panel-aware
    # discovery (DirectAdmin/cPanel/Plesk per-domain logs) instead of the legacy
    # generic single-file find, so WordPress detection is not blind WHEN THIS SHELL
    # CLASSIC PATH RUNS. tail -F is one process per file, so the number of live
    # monitors is BOUNDED (LOGIN_SERVICE_WORDPRESS_MAX_MONITORS); the batch BotScan
    # path covers the full set, while this live-tails the most-recently-active subset.
    # NOTE (v1.177 B-split): the deployed runtime is the GO daemon (internal/loginmon),
    # NOT this shell-classic path — so this change does NOT close runtime daemon
    # LoginMon-WordPress detection. The Go-daemon WordPress/web watcher is DEFERRED
    # to v1.178 (V1_178_LOGINMON_WEB_RUNTIME_AUTHORITY_SCOPE_STUB.md). This block is
    # legacy/classic-mode + CLI support.
    if nftban_login_service_detected "wordpress"; then
        local -a _wp_logs=()
        local f
        if declare -F nftban_http_discover_access_logs >/dev/null 2>&1; then
            while IFS= read -r f; do [[ -n "$f" ]] && _wp_logs+=("$f"); done \
                < <(nftban_http_discover_access_logs "${LOGIN_SERVICE_WORDPRESS_LOG_PATHS:-}")
        fi
        if [[ ${#_wp_logs[@]} -eq 0 ]]; then
            # Back-compat fallback: legacy generic single-file find.
            for f in "${LOGIN_SERVICE_WORDPRESS_LOG_APACHE:-/var/log/apache2/access.log}" \
                     "${LOGIN_SERVICE_WORDPRESS_LOG_HTTPD:-/var/log/httpd/access_log}" \
                     "${LOGIN_SERVICE_WORDPRESS_LOG_NGINX:-/var/log/nginx/access.log}"; do
                [[ -f "$f" ]] && { _wp_logs+=("$f"); break; }
            done
        fi

        local _wp_cap="${LOGIN_SERVICE_WORDPRESS_MAX_MONITORS:-50}"
        local _wp_started=0 _wp_idx=0
        for f in "${_wp_logs[@]}"; do
            [[ "$_wp_started" -ge "$_wp_cap" ]] && break
            local _key="wordpress"; [[ "$_wp_idx" -gt 0 ]] && _key="wordpress_${_wp_idx}"
            _nftban_login_classic_monitor_file "wordpress" "$f" "" &
            _LOGIN_CLASSIC_MONITOR_PIDS[$_key]=$!
            _wp_started=$((_wp_started + 1)); _wp_idx=$((_wp_idx + 1))
        done
        if [[ "$_wp_started" -gt 0 ]]; then
            nftban_login_log "INFO" "WordPress: monitoring ${_wp_started}/${#_wp_logs[@]} discovered access log(s) (cap ${_wp_cap})"
        fi
    fi

    # Start DirectAdmin monitor (file-based)
    if nftban_login_service_detected "directadmin"; then
        local log_file="${LOGIN_SERVICE_DIRECTADMIN_LOG:-/var/log/directadmin/login.log}"
        if [[ -f "$log_file" ]]; then
            _nftban_login_classic_monitor_file "directadmin" "$log_file" "" &
            _LOGIN_CLASSIC_MONITOR_PIDS[directadmin]=$!
        fi
    fi

    # =========================================================================
    # CPANEL - file-based monitoring (v1.18.8, v1.48.0: fixed log path)
    # v1.48.0: cPanel logs login failures as HTTP 401 in access_log, NOT login_log
    # =========================================================================
    if nftban_login_service_detected "cpanel"; then
        local log_file="${LOGIN_SERVICE_CPANEL_LOG:-/usr/local/cpanel/logs/access_log}"
        if [[ -f "$log_file" ]]; then
            nftban_login_log "INFO" "cPanel: starting file monitor ($log_file)"
            _nftban_login_classic_monitor_file "cpanel" "$log_file" "" &
            _LOGIN_CLASSIC_MONITOR_PIDS[cpanel]=$!
        else
            nftban_login_log "WARN" "cPanel: log file not found ($log_file)"
        fi
    fi

    # =========================================================================
    # PLESK - file-based monitoring (v1.18.8)
    # =========================================================================
    if nftban_login_service_detected "plesk"; then
        local log_file="${LOGIN_SERVICE_PLESK_LOG:-/var/log/plesk/panel.log}"
        if [[ -f "$log_file" ]]; then
            nftban_login_log "INFO" "Plesk: starting file monitor ($log_file)"
            _nftban_login_classic_monitor_file "plesk" "$log_file" "" &
            _LOGIN_CLASSIC_MONITOR_PIDS[plesk]=$!
        else
            nftban_login_log "WARN" "Plesk: log file not found ($log_file)"
        fi
    fi

    # Wait for all monitors
    wait
}

# Stop classic mode monitoring
nftban_login_classic_stop() {
    _LOGIN_CLASSIC_RUNNING=0

    for service in "${!_LOGIN_CLASSIC_MONITOR_PIDS[@]}"; do
        local pid="${_LOGIN_CLASSIC_MONITOR_PIDS[$service]}"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            nftban_login_log "INFO" "Stopped $service monitor (PID: $pid)"
        fi
        unset "_LOGIN_CLASSIC_MONITOR_PIDS[$service]"
    done

    # Save state
    _nftban_login_classic_save_state
}

# Save state to disk
_nftban_login_classic_save_state() {
    local state_file="${LOGIN_CLASSIC_STATE_FILE:-/var/lib/nftban/login-classic-state.db}"
    mkdir -p "$(dirname "$state_file")" || return 1

    {
        echo "# Login Classic State - $(date)"
        for key in "${!_LOGIN_CLASSIC_FAIL_COUNT[@]}"; do
            echo "_LOGIN_CLASSIC_FAIL_COUNT[$key]=${_LOGIN_CLASSIC_FAIL_COUNT[$key]}"
        done
        for key in "${!_LOGIN_CLASSIC_FAIL_FIRST[@]}"; do
            echo "_LOGIN_CLASSIC_FAIL_FIRST[$key]=${_LOGIN_CLASSIC_FAIL_FIRST[$key]}"
        done
    } > "$state_file"
}

# Get status
nftban_login_classic_status() {
    echo "Classic Mode Status:"
    echo "  Running: $_LOGIN_CLASSIC_RUNNING"
    echo "  Active Monitors:"
    for service in "${!_LOGIN_CLASSIC_MONITOR_PIDS[@]}"; do
        local pid="${_LOGIN_CLASSIC_MONITOR_PIDS[$service]}"
        local status="stopped"
        [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && status="running (PID: $pid)"
        echo "    - $service: $status"
    done
    echo "  Tracked IPs: ${#_LOGIN_CLASSIC_FAIL_COUNT[@]}"
}

# Enable classic mode
nftban_login_classic_enable() {
    nftban_login_log "INFO" "Enabling classic mode"
    return 0
}

# Disable classic mode
nftban_login_classic_disable() {
    nftban_login_classic_stop
    return 0
}

# Test classic mode
nftban_login_classic_test() {
    echo "Classic Mode Test:"
    echo "  jq available: $(command -v jq &>/dev/null && echo "yes" || echo "no")"
    echo "  journalctl available: $(command -v journalctl &>/dev/null && echo "yes" || echo "no")"

    # Test pattern matching
    local test_line='Failed password for root from 192.168.1.100 port 22 ssh2'
    echo "  Testing pattern match..."
    if [[ "$test_line" =~ Failed\ password\ for\ ([^[:space:]]+)\ from\ ([0-9a-fA-F.:]+) ]]; then
        echo "    User: ${BASH_REMATCH[1]}, IP: ${BASH_REMATCH[2]}"
        echo "    Pattern matching: OK"
    else
        echo "    Pattern matching: FAILED"
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_login_classic_init
export -f nftban_login_classic_start
export -f nftban_login_classic_stop
export -f nftban_login_classic_status
export -f nftban_login_classic_enable
export -f nftban_login_classic_disable
export -f nftban_login_classic_test
