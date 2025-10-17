#!/usr/bin/env bash

# =============================================================================
# NFTBan Rate Limiting Module
# Version: 1.0.0
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Advanced rate limiting with alerts and monitoring
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_RATELIMIT_LOADED:-}" ]] && return 0
readonly NFTBAN_RATELIMIT_LOADED=1

# =============================================================================
# MODULE CONFIGURATION
# =============================================================================
readonly NFTBAN_RATE_LIMIT_FILE="${NFTBAN_DATA_DIR}/rate-limit-tracker.tmp"
readonly NFTBAN_RATE_LIMIT_LOG="${NFTBAN_LOG_DIR}/rate-limit.log"
readonly NFTBAN_RATE_LIMIT_ALERT_FILE="${NFTBAN_DATA_DIR}/rate-limit-alerts.tmp"

# Default rate limits (can be overridden in config)
readonly NFTBAN_DEFAULT_RATE_LIMIT_PER_MINUTE=60
readonly NFTBAN_DEFAULT_RATE_LIMIT_ALERT_THRESHOLD=80  # Percent

# =============================================================================
# RATE LIMIT INITIALIZATION
# =============================================================================

nftban_ratelimit_init() {
    mkdir -p "$(dirname "$NFTBAN_RATE_LIMIT_FILE")"
    mkdir -p "$(dirname "$NFTBAN_RATE_LIMIT_LOG")"
    
    touch "$NFTBAN_RATE_LIMIT_FILE"
    touch "$NFTBAN_RATE_LIMIT_ALERT_FILE"
    
    nftban_log_debug "Rate limiting module initialized"
}

# =============================================================================
# RATE TRACKING
# =============================================================================

# Record a ban attempt
nftban_ratelimit_record_attempt() {
    local current_time
    current_time=$(date +%s)
    
    echo "$current_time" >> "$NFTBAN_RATE_LIMIT_FILE"
    
    # Clean old entries (older than 2 minutes)
    nftban_ratelimit_cleanup
    
    nftban_log_debug "Ban attempt recorded at $current_time"
}

# Clean up old entries
nftban_ratelimit_cleanup() {
    local current_time two_minutes_ago
    current_time=$(date +%s)
    two_minutes_ago=$((current_time - 120))
    
    if [[ -f "$NFTBAN_RATE_LIMIT_FILE" ]]; then
        awk -v cutoff="$two_minutes_ago" '$1 >= cutoff' "$NFTBAN_RATE_LIMIT_FILE" > "${NFTBAN_RATE_LIMIT_FILE}.tmp" 2>/dev/null || true
        mv "${NFTBAN_RATE_LIMIT_FILE}.tmp" "$NFTBAN_RATE_LIMIT_FILE" 2>/dev/null || true
    fi
}

# Get count of attempts in time window
nftban_ratelimit_get_count() {
    local time_window="${1:-60}"  # seconds
    
    if [[ ! -f "$NFTBAN_RATE_LIMIT_FILE" ]]; then
        echo "0"
        return 0
    fi
    
    local current_time cutoff_time
    current_time=$(date +%s)
    cutoff_time=$((current_time - time_window))
    
    awk -v cutoff="$cutoff_time" '$1 >= cutoff' "$NFTBAN_RATE_LIMIT_FILE" 2>/dev/null | wc -l
}

# =============================================================================
# RATE LIMIT CHECKING
# =============================================================================

# Check if rate limit is exceeded
nftban_ratelimit_check() {
    local rate_limit
    rate_limit=$(nftban_get_config "BAN_RATE_LIMIT_PER_MINUTE" "$NFTBAN_DEFAULT_RATE_LIMIT_PER_MINUTE")
    
    # If rate limit is 0, skip check (unlimited)
    if [[ "$rate_limit" == "0" ]]; then
        return 0
    fi
    
    local current_count
    current_count=$(nftban_ratelimit_get_count 60)
    
    if [[ $current_count -ge $rate_limit ]]; then
        nftban_log_error "RATE LIMIT EXCEEDED: $current_count bans/min (limit: $rate_limit)"
        
        # Log to rate limit log
        local timestamp
        timestamp=$(date +'%Y-%m-%d %H:%M:%S')
        echo "[${timestamp}] EXCEEDED: $current_count/$rate_limit bans/min" >> "$NFTBAN_RATE_LIMIT_LOG"
        
        # Send alert
        nftban_ratelimit_send_alert "$current_count" "60" "$rate_limit"
        
        return 1
    fi
    
    # Check warning threshold
    local alert_threshold
    alert_threshold=$(nftban_get_config "BAN_RATE_LIMIT_ALERT_THRESHOLD" "$NFTBAN_DEFAULT_RATE_LIMIT_ALERT_THRESHOLD")
    
    local threshold_value=$(( rate_limit * alert_threshold / 100 ))
    
    if [[ $current_count -ge $threshold_value ]]; then
        local percent=$(( current_count * 100 / rate_limit ))
        nftban_log_warning "Ban rate at ${percent}%: $current_count/$rate_limit per minute"
    fi
    
    return 0
}

# Check rate limit and record attempt
nftban_ratelimit_check_and_record() {
    # Record first
    nftban_ratelimit_record_attempt
    
    # Then check
    nftban_ratelimit_check
}

# =============================================================================
# RATE LIMIT ALERTS
# =============================================================================

# Send rate limit exceeded alert
nftban_ratelimit_send_alert() {
    local ban_count="$1"
    local time_window="$2"
    local rate_limit="$3"
    
    local recipient
    recipient=$(nftban_get_config "NFTBAN_EMAIL_RECIPIENT" "")
    
    if [[ -z "$recipient" ]]; then
        nftban_log_error "CRITICAL: Rate limit exceeded but no email recipient configured!"
        return 1
    fi
    
    # Check if already alerted recently (prevent spam)
    if nftban_ratelimit_was_recently_alerted 300; then  # 5 minutes
        nftban_log_debug "Rate limit alert suppressed (recently sent)"
        return 0
    fi
    
    # Record alert time
    echo "$(date +%s)" >> "$NFTBAN_RATE_LIMIT_ALERT_FILE"
    
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    local subject="[nftban] CRITICAL: Ban Rate Limit Exceeded on $(hostname -f)"
    
    # Get recent ban details
    local recent_bans=""
    if [[ -f "$NFTBAN_BAN_LOG" ]]; then
        recent_bans=$(tail -20 "$NFTBAN_BAN_LOG" | awk -F'|' '{printf "  %s | %s | %s | %s\n", $1, $2, $3, $4}')
    fi
    
    local body="nftban CRITICAL ALERT - Rate Limit Exceeded

WARNING: Abnormal ban activity detected!

Timestamp: $timestamp
Server: $(hostname -f)
Time Window: Last ${time_window} seconds
Ban Attempts: ${ban_count}
Rate Limit: ${rate_limit} per minute
Status: THRESHOLD EXCEEDED

This could indicate:
- Distributed attack (DDoS)
- Misconfigured whitelist
- Legitimate traffic being blocked
- Port scanning activity
- Brute force attack

Recent Ban Attempts (last 20):
$recent_bans

Action Required:
1. Review ban logs: $NFTBAN_BAN_LOG
2. Check for patterns in source IPs
3. Verify whitelist configuration
4. Review jail configurations
5. Check for false positives

Commands to investigate:
  tail -50 $NFTBAN_BAN_LOG
  nftban stats dashboard
  nftban stats top 20

---
This is an automated CRITICAL alert from nftban"
    
    # Send via core email function (always critical priority)
    if nftban_send_email "$recipient" "$subject" "$body" "critical"; then
        nftban_log_warning "CRITICAL: Rate limit alert sent to $recipient"
        return 0
    else
        nftban_log_error "CRITICAL: Failed to send rate limit alert"
        return 1
    fi
}

# Check if alert was recently sent
nftban_ratelimit_was_recently_alerted() {
    local time_window="${1:-300}"  # Default 5 minutes
    
    if [[ ! -f "$NFTBAN_RATE_LIMIT_ALERT_FILE" ]]; then
        return 1
    fi
    
    local current_time cutoff_time
    current_time=$(date +%s)
    cutoff_time=$((current_time - time_window))
    
    local recent_alerts
    recent_alerts=$(awk -v cutoff="$cutoff_time" '$1 >= cutoff' "$NFTBAN_RATE_LIMIT_ALERT_FILE" 2>/dev/null | wc -l)
    
    [[ $recent_alerts -gt 0 ]] && return 0 || return 1
}

# =============================================================================
# RATE LIMIT STATISTICS
# =============================================================================

# Show current rate statistics
nftban_ratelimit_show_stats() {
    echo ""
    echo "======================================================="
    echo "  Rate Limit Statistics"
    echo "======================================================="
    echo ""
    
    local rate_limit
    rate_limit=$(nftban_get_config "BAN_RATE_LIMIT_PER_MINUTE" "$NFTBAN_DEFAULT_RATE_LIMIT_PER_MINUTE")
    
    echo "Configuration:"
    echo "  Rate Limit: $rate_limit per minute"
    
    if [[ "$rate_limit" == "0" ]]; then
        echo "  Status: UNLIMITED"
    fi
    
    local alert_threshold
    alert_threshold=$(nftban_get_config "BAN_RATE_LIMIT_ALERT_THRESHOLD" "$NFTBAN_DEFAULT_RATE_LIMIT_ALERT_THRESHOLD")
    echo "  Alert Threshold: ${alert_threshold}%"
    echo ""
    
    echo "Current Activity:"
    
    local count_1min count_5min count_15min
    count_1min=$(nftban_ratelimit_get_count 60)
    count_5min=$(nftban_ratelimit_get_count 300)
    count_15min=$(nftban_ratelimit_get_count 900)
    
    echo "  Last 1 minute:  $count_1min bans"
    echo "  Last 5 minutes: $count_5min bans"
    echo "  Last 15 minutes: $count_15min bans"
    echo ""
    
    if [[ "$rate_limit" != "0" ]]; then
        local usage_percent=$(( count_1min * 100 / rate_limit ))
        local threshold_value=$(( rate_limit * alert_threshold / 100 ))
        
        echo "Rate Usage:"
        echo "  Current: ${usage_percent}%"
        
        if [[ $count_1min -ge $rate_limit ]]; then
            echo "  Status: EXCEEDED"
        elif [[ $count_1min -ge $threshold_value ]]; then
            echo "  Status: WARNING"
        else
            echo "  Status: NORMAL"
        fi
        echo ""
    fi
    
    # Recent alerts
    if [[ -f "$NFTBAN_RATE_LIMIT_LOG" ]]; then
        echo "Recent Rate Limit Violations:"
        local violations
        violations=$(grep "EXCEEDED" "$NFTBAN_RATE_LIMIT_LOG" 2>/dev/null | tail -5)
        
        if [[ -n "$violations" ]]; then
            echo "$violations" | sed 's/^/  /'
        else
            echo "  (none)"
        fi
        echo ""
    fi
    
    echo "======================================================="
}

# Get rate history for graphing/monitoring
nftban_ratelimit_get_history() {
    local intervals="${1:-10}"  # Number of 1-minute intervals
    
    local current_time
    current_time=$(date +%s)
    
    echo ""
    echo "Ban Rate History (last $intervals minutes):"
    echo ""
    
    for (( i=intervals-1; i>=0; i-- )); do
        local start_time=$((current_time - (i+1)*60))
        local end_time=$((current_time - i*60))
        
        local count
        if [[ -f "$NFTBAN_RATE_LIMIT_FILE" ]]; then
            count=$(awk -v start="$start_time" -v end="$end_time" \
                '$1 >= start && $1 < end' "$NFTBAN_RATE_LIMIT_FILE" 2>/dev/null | wc -l)
        else
            count=0
        fi
        
        local timestamp
        timestamp=$(date -d "@$end_time" +'%H:%M' 2>/dev/null || date -r "$end_time" +'%H:%M')
        
        # Create simple bar graph
        local bar=""
        for (( j=0; j<count; j++ )); do
            bar+="#"
        done
        
        printf "%s | %3d | %s\n" "$timestamp" "$count" "$bar"
    done
    
    echo ""
}

# =============================================================================
# RATE LIMIT RESET
# =============================================================================

# Reset rate limit tracker
nftban_ratelimit_reset() {
    rm -f "$NFTBAN_RATE_LIMIT_FILE"
    touch "$NFTBAN_RATE_LIMIT_FILE"
    
    nftban_log_info "Rate limit tracker reset"
    
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] RESET: Rate limit tracker cleared" >> "$NFTBAN_RATE_LIMIT_LOG"
}

# Reset alert tracker
nftban_ratelimit_reset_alerts() {
    rm -f "$NFTBAN_RATE_LIMIT_ALERT_FILE"
    touch "$NFTBAN_RATE_LIMIT_ALERT_FILE"
    
    nftban_log_info "Rate limit alert tracker reset"
}

# =============================================================================
# RATE LIMIT CONFIGURATION
# =============================================================================

# Set rate limit
nftban_ratelimit_set_limit() {
    local limit="$1"
    
    if [[ ! "$limit" =~ ^[0-9]+$ ]]; then
        nftban_log_error "Invalid rate limit: $limit (must be a number)"
        return 1
    fi
    
    nftban_set_config "BAN_RATE_LIMIT_PER_MINUTE" "$limit"
    
    if [[ "$limit" == "0" ]]; then
        nftban_log_success "Rate limiting disabled (unlimited)"
    else
        nftban_log_success "Rate limit set to: $limit per minute"
    fi
    
    return 0
}

# Set alert threshold
nftban_ratelimit_set_alert_threshold() {
    local threshold="$1"
    
    if [[ ! "$threshold" =~ ^[0-9]+$ ]] || [[ $threshold -lt 1 ]] || [[ $threshold -gt 100 ]]; then
        nftban_log_error "Invalid threshold: $threshold (must be 1-100)"
        return 1
    fi
    
    nftban_set_config "BAN_RATE_LIMIT_ALERT_THRESHOLD" "$threshold"
    nftban_log_success "Alert threshold set to: ${threshold}%"
    
    return 0
}

# =============================================================================
# RATE LIMIT MONITORING
# =============================================================================

# Monitor rate in real-time
nftban_ratelimit_monitor() {
    nftban_log_info "Starting rate limit monitoring (Ctrl+C to stop)..."
    echo ""
    
    trap 'echo ""; nftban_log_info "Monitoring stopped"; exit 0' INT
    
    while true; do
        clear
        
        echo "======================================================="
        echo "  Rate Limit Real-Time Monitor"
        echo "======================================================="
        echo ""
        echo "Time: $(date +'%Y-%m-%d %H:%M:%S')"
        echo ""
        
        nftban_ratelimit_show_stats
        
        echo ""
        nftban_ratelimit_get_history 15
        
        echo ""
        echo "Press Ctrl+C to stop monitoring"
        
        sleep 5
    done
}

# =============================================================================
# RATE LIMIT REPORTING
# =============================================================================

# Generate rate limit report
nftban_ratelimit_generate_report() {
    local output_file="${1:-/tmp/nftban-ratelimit-report-$(date +%Y%m%d-%H%M%S).txt}"
    
    nftban_log_info "Generating rate limit report: $output_file"
    
    {
        echo "======================================================="
        echo "  nftban Rate Limit Report"
        echo "======================================================="
        echo ""
        echo "Generated: $(date +'%Y-%m-%d %H:%M:%S')"
        echo "Server: $(hostname -f)"
        echo ""
        
        echo "Configuration:"
        echo "  Rate Limit: $(nftban_get_config "BAN_RATE_LIMIT_PER_MINUTE" "$NFTBAN_DEFAULT_RATE_LIMIT_PER_MINUTE") per minute"
        echo "  Alert Threshold: $(nftban_get_config "BAN_RATE_LIMIT_ALERT_THRESHOLD" "$NFTBAN_DEFAULT_RATE_LIMIT_ALERT_THRESHOLD")%"
        echo ""
        
        echo "Current Statistics:"
        nftban_ratelimit_show_stats
        
        echo ""
        echo "Activity History:"
        nftban_ratelimit_get_history 60
        
        echo ""
        echo "Recent Violations:"
        if [[ -f "$NFTBAN_RATE_LIMIT_LOG" ]]; then
            tail -50 "$NFTBAN_RATE_LIMIT_LOG" | sed 's/^/  /'
        else
            echo "  (none)"
        fi
        
        echo ""
        echo "======================================================="
        echo "  End of Report"
        echo "======================================================="
        
    } > "$output_file"
    
    nftban_log_success "Report generated: $output_file"
    echo "$output_file"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_ratelimit_init
export -f nftban_ratelimit_record_attempt
export -f nftban_ratelimit_cleanup
export -f nftban_ratelimit_get_count
export -f nftban_ratelimit_check
export -f nftban_ratelimit_check_and_record
export -f nftban_ratelimit_send_alert
export -f nftban_ratelimit_was_recently_alerted
export -f nftban_ratelimit_show_stats
export -f nftban_ratelimit_get_history
export -f nftban_ratelimit_reset
export -f nftban_ratelimit_reset_alerts
export -f nftban_ratelimit_set_limit
export -f nftban_ratelimit_set_alert_threshold
export -f nftban_ratelimit_monitor
export -f nftban_ratelimit_generate_report

# Auto-initialize
nftban_ratelimit_init

nftban_log_debug "NFTBan Rate Limiting Module loaded"
