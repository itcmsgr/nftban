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
# meta:version="1.0.0"
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
# Running flag
declare -g _LOGIN_CLASSIC_RUNNING=0
# PIDs of background monitors
declare -gA _LOGIN_CLASSIC_MONITOR_PIDS=()

# =============================================================================
# INITIALIZATION
# =============================================================================

nftban_login_classic_init() {
    nftban_login_log "INFO" "Initializing classic mode..."

    # Load state from disk if exists
    local state_file="${LOGIN_CLASSIC_STATE_FILE:-/var/lib/nftban/login-classic-state.db}"
    if [[ -f "$state_file" ]]; then
        source "$state_file" 2>/dev/null || true
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

    # Add units
    IFS=',' read -ra unit_array <<< "$units"
    for unit in "${unit_array[@]}"; do
        journal_cmd+=(-u "$unit")
    done

    # Use JSON output if jq is available
    if command -v jq &>/dev/null && [[ "${LOGIN_CLASSIC_JOURNALCTL_JSON:-true}" == "true" ]]; then
        journal_cmd+=(--output=json)
        "${journal_cmd[@]}" 2>/dev/null | while read -r line; do
            local message
            message=$(echo "$line" | jq -r '.MESSAGE // empty' 2>/dev/null) || continue
            [[ -z "$message" ]] && continue
            _nftban_login_classic_process_message "$service" "$message" "$pattern_failed" "$pattern_invalid"
        done
    else
        # Fallback to text parsing
        "${journal_cmd[@]}" 2>/dev/null | while read -r line; do
            _nftban_login_classic_process_message "$service" "$line" "$pattern_failed" "$pattern_invalid"
        done
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
        if [[ "$message" =~ Failed\ password\ for\ ([^[:space:]]+)\ from\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            user="${BASH_REMATCH[1]}"
            ip="${BASH_REMATCH[2]}"
        # Failed password for invalid user
        elif [[ "$message" =~ Failed\ password\ for\ invalid\ user\ ([^[:space:]]+)\ from\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            user="${BASH_REMATCH[1]}"
            ip="${BASH_REMATCH[2]}"
            event_type="invalid_user"
        # Invalid user from IP
        elif [[ "$message" =~ Invalid\ user\ ([^[:space:]]+)\ from\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            user="${BASH_REMATCH[1]}"
            ip="${BASH_REMATCH[2]}"
            event_type="invalid_user"
        # Disconnected preauth (potential scan)
        elif [[ "$message" =~ Disconnected\ from.*\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+).*preauth ]]; then
            ip="${BASH_REMATCH[1]}"
            user="unknown"
            event_type="preauth"
        # Too many authentication failures
        elif [[ "$message" =~ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+).*[Tt]oo\ many\ authentication\ failures ]]; then
            ip="${BASH_REMATCH[1]}"
            user="unknown"
            event_type="too_many"
        fi
    fi

    # Mail patterns (Dovecot, Exim, Postfix)
    if [[ "$service" == "dovecot" ]] || [[ "$service" == "exim" ]] || [[ "$service" == "postfix" ]]; then
        # Generic: auth failure from IP
        if [[ "$message" =~ [Aa]uth.*fail.*rip=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            user="unknown"
        elif [[ "$message" =~ [Aa]uthentication\ fail.*from\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            user="unknown"
        # SASL authentication failed (Postfix)
        # Format: "warning: hostname[IP]: SASL LOGIN authentication failed"
        elif [[ "$message" =~ \[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*SASL.*authentication\ failed ]]; then
            ip="${BASH_REMATCH[1]}"
            user="unknown"
        # Alternative SASL format (IP after SASL)
        elif [[ "$message" =~ SASL.*authentication\ failed.*\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\] ]]; then
            ip="${BASH_REMATCH[1]}"
            user="unknown"
        fi
    fi

    # FTP patterns (Pure-FTPd, vsftpd)
    if [[ "$service" == "pureftpd" ]] || [[ "$service" == "vsftpd" ]] || [[ "$service" == "proftpd" ]]; then
        if [[ "$message" =~ [Aa]uthentication\ fail.*@([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            user="unknown"
        elif [[ "$message" =~ FAIL\ LOGIN.*from\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            user="unknown"
        elif [[ "$message" =~ \[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*Login\ failed ]]; then
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
        if [[ "$line" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+).*POST.*/wp-login\.php ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "wordpress" "login_attempt"
        elif [[ "$line" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+).*POST.*/xmlrpc\.php ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "xmlrpc" "xmlrpc_post"
        fi
    fi

    # Apache/Nginx HTTP auth failure (401)
    if [[ "$service" == "apache" ]] || [[ "$service" == "nginx" ]]; then
        if [[ "$line" =~ user.*authentication\ failure.*client:\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "$service" "http_auth"
        fi
    fi

    # DirectAdmin
    if [[ "$service" == "directadmin" ]]; then
        if [[ "$line" =~ FAILED\ LOGIN.*ip=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "directadmin" "failed"
        fi
    fi

    # Mail services (Postfix SASL, Dovecot) from /var/log/maillog or /var/log/mail.log
    if [[ "$service" == "mail" ]] || [[ "$service" == "postfix_file" ]]; then
        # Postfix SASL: "warning: hostname[IP]: SASL LOGIN authentication failed"
        if [[ "$line" =~ \[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*SASL.*authentication\ failed ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "postfix" "sasl_auth_fail"
        # Alternative: "SASL ... failed ... [IP]"
        elif [[ "$line" =~ SASL.*authentication\ failed.*\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\] ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "postfix" "sasl_auth_fail"
        # Dovecot from mail log: "auth failed ... rip=IP"
        elif [[ "$line" =~ [Aa]uth.*fail.*rip=([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "dovecot" "auth_fail"
        # Generic authentication failure from mail log
        elif [[ "$line" =~ [Aa]uthentication\ fail.*from\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "mail" "auth_fail"
        fi
    fi

    # Exim log file patterns (cPanel, DirectAdmin)
    # Format: "2026-02-12 10:30:45 H=hostname [IP] ... authenticator failed"
    # Or: "2026-02-12 10:30:45 [IP] rejected ... AUTH ... failed"
    if [[ "$service" == "exim_file" ]]; then
        # Exim authenticator failed: "H=hostname [IP] ... authenticator failed"
        if [[ "$line" =~ \[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*authenticator\ failed ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "exim" "auth_fail"
        # Exim AUTH failed: "[IP] ... AUTH ... failed"
        elif [[ "$line" =~ \[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*AUTH.*failed ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "exim" "auth_fail"
        # Exim login failed: "login failed ... [IP]" or "[IP] ... login failed"
        elif [[ "$line" =~ \[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*login\ failed ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "exim" "login_fail"
        elif [[ "$line" =~ login\ failed.*\[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\] ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "exim" "login_fail"
        # Exim rejected AUTH: "rejected ... AUTH"
        elif [[ "$line" =~ \[([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\].*rejected.*AUTH ]]; then
            ip="${BASH_REMATCH[1]}"
            _nftban_login_classic_process_event "$ip" "unknown" "exim" "auth_rejected"
        fi
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

    # Private networks
    if [[ "${LOGIN_WHITELIST_PRIVATE:-true}" == "true" ]]; then
        [[ "$ip" =~ ^10\. ]] && return 0
        [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
        [[ "$ip" =~ ^192\.168\. ]] && return 0
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

    # Start WordPress monitor (file-based)
    if nftban_login_service_detected "wordpress"; then
        local log_file=""
        for f in "${LOGIN_SERVICE_WORDPRESS_LOG_APACHE:-/var/log/apache2/access.log}" \
                 "${LOGIN_SERVICE_WORDPRESS_LOG_HTTPD:-/var/log/httpd/access_log}" \
                 "${LOGIN_SERVICE_WORDPRESS_LOG_NGINX:-/var/log/nginx/access.log}"; do
            [[ -f "$f" ]] && log_file="$f" && break
        done

        if [[ -n "$log_file" ]]; then
            _nftban_login_classic_monitor_file "wordpress" "$log_file" "" &
            _LOGIN_CLASSIC_MONITOR_PIDS[wordpress]=$!
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
    mkdir -p "$(dirname "$state_file")"

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
    if [[ "$test_line" =~ Failed\ password\ for\ ([^[:space:]]+)\ from\ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
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
