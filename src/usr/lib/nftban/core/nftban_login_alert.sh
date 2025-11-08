#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.6 - Login Alert Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Login monitoring and alerting
#
# meta:name=nftban_login_alert
# meta:type=core
# meta:header=Login Alert Module
# meta:version=0.32.6
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Monitors and alerts on system logins with GeoIP enrichment
# meta:input=System login events and user sessions
# meta:output=Login alerts and notifications
#
# **Inventory & Requirements**
# meta:depends=nftban_geoip_go.sh,last,journalctl
#
# meta:created_date=2025-11-05
# =============================================================================

# Enhanced strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_LOGIN_ALERT_LOADED:-}" ]] && return 0
readonly NFTBAN_LOGIN_ALERT_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================

# Load configuration
NFTBAN_CONFIG_DIR="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf" ]]; then
    source "${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf"
fi

# Defaults if not set
NFTBAN_LOGIN_ALERT_ENABLED="${NFTBAN_LOGIN_ALERT_ENABLED:-true}"
NFTBAN_LOGIN_ALERT_EMAIL="${NFTBAN_LOGIN_ALERT_EMAIL:-root@localhost}"
NFTBAN_LOGIN_ALERT_SSH="${NFTBAN_LOGIN_ALERT_SSH:-true}"
NFTBAN_LOGIN_ALERT_SU="${NFTBAN_LOGIN_ALERT_SU:-true}"
NFTBAN_LOGIN_ALERT_SUDO="${NFTBAN_LOGIN_ALERT_SUDO:-true}"
NFTBAN_LOGIN_ALERT_CONSOLE="${NFTBAN_LOGIN_ALERT_CONSOLE:-false}"
NFTBAN_LOGIN_ALERT_GEOIP="${NFTBAN_LOGIN_ALERT_GEOIP:-true}"
NFTBAN_LOGIN_ALERT_FORMAT="${NFTBAN_LOGIN_ALERT_FORMAT:-html}"
NFTBAN_LOGIN_ALERT_LOG="${NFTBAN_LOGIN_ALERT_LOG:-/var/log/nftban/login_alert.log}"
NFTBAN_LOGIN_MONITOR_INTERVAL="${NFTBAN_LOGIN_MONITOR_INTERVAL:-5}"
NFTBAN_LOGIN_WHITELIST="${NFTBAN_LOGIN_WHITELIST:-}"
NFTBAN_LOGIN_ALERT_FAILED="${NFTBAN_LOGIN_ALERT_FAILED:-true}"
NFTBAN_LOGIN_FAILED_THRESHOLD="${NFTBAN_LOGIN_FAILED_THRESHOLD:-3}"
NFTBAN_LOGIN_FAILED_WINDOW="${NFTBAN_LOGIN_FAILED_WINDOW:-300}"

# Template paths
NFTBAN_TEMPLATE_DIR="${NFTBAN_TEMPLATE_DIR:-/usr/share/nftban/templates/alerts}"

# Tracking failed attempts
declare -A NFTBAN_FAILED_ATTEMPTS
declare -A NFTBAN_FAILED_TIMESTAMPS

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

nftban_login_log() {
    # Log to file and optionally syslog
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Ensure log directory exists
    mkdir -p "$(dirname "$NFTBAN_LOGIN_ALERT_LOG")"

    # Log to file
    echo "[$timestamp] $message" >> "$NFTBAN_LOGIN_ALERT_LOG"

    # Log to syslog
    logger -t nftban-login-alert "$message"
}

nftban_login_is_whitelisted() {
    # Check if IP is whitelisted
    local ip="$1"

    for whitelisted in $NFTBAN_LOGIN_WHITELIST; do
        if [[ "$ip" == "$whitelisted" ]]; then
            return 0
        fi
    done

    return 1
}

nftban_login_get_geoip() {
    # Get GeoIP information for IP
    local ip="$1"

    if [[ "$NFTBAN_LOGIN_ALERT_GEOIP" != "true" ]]; then
        echo "GeoIP disabled"
        return 0
    fi

    # Load GeoIP module if available
    if [[ -f "/usr/lib/nftban/core/nftban_geoip_go.sh" ]]; then
        source "/usr/lib/nftban/core/nftban_geoip_go.sh"

        if nftban_geoip_check_available 2>/dev/null; then
            nftban_geoip_get_compact_full "$ip" 2>/dev/null || echo "Unknown"
        else
            echo "GeoIP unavailable"
        fi
    else
        echo "GeoIP not installed"
    fi
}

# =============================================================================
# ALERT FUNCTIONS
# =============================================================================

nftban_login_send_alert() {
    # Send login alert email
    # Args: $1=event_type, $2=user, $3=ip, $4=service, $5=status, $6=details

    local event_type="$1"
    local user="$2"
    local ip="$3"
    local service="$4"
    local status="$5"
    local details="${6:-}"

    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    local geoip
    geoip=$(nftban_login_get_geoip "$ip")

    # Build subject
    local subject="[NFTBan] $status Login: $user @ $hostname"

    if [[ "$NFTBAN_LOGIN_ALERT_FORMAT" == "html" ]]; then
        nftban_login_send_html_alert "$subject" "$event_type" "$user" "$ip" "$service" "$status" "$geoip" "$details" "$hostname" "$timestamp"
    else
        nftban_login_send_text_alert "$subject" "$event_type" "$user" "$ip" "$service" "$status" "$geoip" "$details" "$hostname" "$timestamp"
    fi
}

nftban_login_send_text_alert() {
    # Send plain text alert
    local subject="$1"
    local event_type="$2"
    local user="$3"
    local ip="$4"
    local service="$5"
    local status="$6"
    local geoip="$7"
    local details="$8"
    local hostname="$9"
    local timestamp="${10}"

    local body
    body=$(cat <<EOF
NFTBan Login Alert
==================

Event Type: $event_type
Status: $status
Timestamp: $timestamp

User Information:
  Username: $user
  Service: $service

Connection Information:
  IP Address: $ip
  Location: $geoip
  Hostname: $hostname

Additional Details:
$details

---
nftban — Simplifying Linux Firewall Management
https://nftban.com
EOF
)

    echo "$body" | mail -s "$subject" "$NFTBAN_LOGIN_ALERT_EMAIL"
}

nftban_login_send_html_alert() {
    # Send HTML alert
    local subject="$1"
    local event_type="$2"
    local user="$3"
    local ip="$4"
    local service="$5"
    local status="$6"
    local geoip="$7"
    local details="$8"
    local hostname="$9"
    local timestamp="${10}"

    # Status color
    local status_color="#28a745"  # green for success
    if [[ "$status" == "FAILED" ]]; then
        status_color="#dc3545"  # red for failed
    elif [[ "$status" == "SUSPICIOUS" ]]; then
        status_color="#ffc107"  # yellow for suspicious
    fi

    local html
    html=$(cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="author" content="Antonios Voulvoulis, contact@nftban.com">
    <meta name="generator" content="NFTBan v0.32.6">
    <meta name="homepage" content="https://nftban.com">
    <title>NFTBan Login Alert</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            margin: 0;
            padding: 20px;
            background-color: #f5f5f5;
        }
        .container {
            max-width: 600px;
            margin: 0 auto;
            background: white;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            border-radius: 8px 8px 0 0;
        }
        .header h1 {
            margin: 0 0 10px 0;
            font-size: 24px;
        }
        .status-badge {
            display: inline-block;
            padding: 5px 15px;
            border-radius: 20px;
            background: $status_color;
            color: white;
            font-weight: bold;
            font-size: 14px;
        }
        .content {
            padding: 30px;
        }
        .info-section {
            margin-bottom: 25px;
        }
        .info-section h2 {
            margin: 0 0 15px 0;
            font-size: 18px;
            color: #333;
            border-bottom: 2px solid #667eea;
            padding-bottom: 8px;
        }
        .info-row {
            display: flex;
            padding: 10px 0;
            border-bottom: 1px solid #eee;
        }
        .info-label {
            font-weight: bold;
            color: #666;
            width: 140px;
            flex-shrink: 0;
        }
        .info-value {
            color: #333;
            flex-grow: 1;
        }
        .details-box {
            background: #f8f9fa;
            padding: 15px;
            border-radius: 4px;
            border-left: 4px solid #667eea;
            font-family: monospace;
            font-size: 13px;
            white-space: pre-wrap;
        }
        .footer {
            text-align: center;
            padding: 20px;
            color: #666;
            font-size: 12px;
        }
        .footer a {
            color: #667eea;
            text-decoration: none;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🔐 NFTBan Login Alert</h1>
            <span class="status-badge">$status</span>
        </div>

        <div class="content">
            <div class="info-section">
                <h2>Event Information</h2>
                <div class="info-row">
                    <div class="info-label">Event Type:</div>
                    <div class="info-value">$event_type</div>
                </div>
                <div class="info-row">
                    <div class="info-label">Timestamp:</div>
                    <div class="info-value">$timestamp</div>
                </div>
                <div class="info-row">
                    <div class="info-label">Server:</div>
                    <div class="info-value">$hostname</div>
                </div>
            </div>

            <div class="info-section">
                <h2>User Information</h2>
                <div class="info-row">
                    <div class="info-label">Username:</div>
                    <div class="info-value"><strong>$user</strong></div>
                </div>
                <div class="info-row">
                    <div class="info-label">Service:</div>
                    <div class="info-value">$service</div>
                </div>
            </div>

            <div class="info-section">
                <h2>Connection Information</h2>
                <div class="info-row">
                    <div class="info-label">IP Address:</div>
                    <div class="info-value"><code>$ip</code></div>
                </div>
                <div class="info-row">
                    <div class="info-label">Location:</div>
                    <div class="info-value">$geoip</div>
                </div>
            </div>

            <div class="info-section">
                <h2>Additional Details</h2>
                <div class="details-box">$details</div>
            </div>
        </div>

        <div class="footer">
            <strong>nftban — Simplifying Linux Firewall Management</strong><br>
            <a href="https://nftban.com">https://nftban.com</a>
        </div>
    </div>
</body>
</html>
EOF
)

    echo "$html" | mail -s "$subject" -a "Content-Type: text/html" "$NFTBAN_LOGIN_ALERT_EMAIL"
}

# =============================================================================
# MONITORING FUNCTIONS
# =============================================================================

nftban_login_monitor_ssh() {
    # Monitor SSH logins via journalctl

    journalctl -u sshd -f -n 0 --output=json 2>/dev/null | \
    while read -r line; do
        # Parse JSON log entry
        local message
        message=$(echo "$line" | jq -r '.MESSAGE // empty')

        # Successful login
        if [[ "$message" =~ ^Accepted\ (password|publickey)\ for\ ([^[:space:]]+)\ from\ ([0-9.]+) ]]; then
            local method="${BASH_REMATCH[1]}"
            local user="${BASH_REMATCH[2]}"
            local ip="${BASH_REMATCH[3]}"

            # Check whitelist
            if ! nftban_login_is_whitelisted "$ip"; then
                nftban_login_log "SSH login: $user from $ip (method: $method)"
                nftban_login_send_alert "SSH Login" "$user" "$ip" "SSH" "SUCCESS" "Authentication method: $method"
            fi
        fi

        # Failed login
        if [[ "$message" =~ ^Failed\ (password|publickey)\ for\ ([^[:space:]]+)\ from\ ([0-9.]+) ]]; then
            local method="${BASH_REMATCH[1]}"
            local user="${BASH_REMATCH[2]}"
            local ip="${BASH_REMATCH[3]}"

            nftban_login_track_failed "$user" "$ip" "SSH"
        fi
    done
}

nftban_login_track_failed() {
    # Track failed login attempts
    local user="$1"
    local ip="$2"
    local service="$3"

    local key="${user}@${ip}"
    local now
    now=$(date +%s)

    # Initialize if first attempt
    if [[ -z "${NFTBAN_FAILED_ATTEMPTS[$key]:-}" ]]; then
        NFTBAN_FAILED_ATTEMPTS[$key]=1
        NFTBAN_FAILED_TIMESTAMPS[$key]=$now
    else
        # Check if within time window
        local first_attempt="${NFTBAN_FAILED_TIMESTAMPS[$key]}"
        local elapsed=$((now - first_attempt))

        if [[ $elapsed -lt $NFTBAN_LOGIN_FAILED_WINDOW ]]; then
            # Increment counter
            NFTBAN_FAILED_ATTEMPTS[$key]=$((${NFTBAN_FAILED_ATTEMPTS[$key]} + 1))

            # Check threshold
            if [[ ${NFTBAN_FAILED_ATTEMPTS[$key]} -ge $NFTBAN_LOGIN_FAILED_THRESHOLD ]]; then
                nftban_login_log "Multiple failed attempts: $user from $ip ($service)"
                nftban_login_send_alert "Failed Login Attempts" "$user" "$ip" "$service" "FAILED" \
                    "Failed attempts: ${NFTBAN_FAILED_ATTEMPTS[$key]} in ${elapsed} seconds"

                # Reset counter
                unset NFTBAN_FAILED_ATTEMPTS[$key]
                unset NFTBAN_FAILED_TIMESTAMPS[$key]
            fi
        else
            # Reset if outside window
            NFTBAN_FAILED_ATTEMPTS[$key]=1
            NFTBAN_FAILED_TIMESTAMPS[$key]=$now
        fi
    fi
}

nftban_login_monitor_all() {
    # Monitor all configured login types

    nftban_login_log "Starting login monitoring (interval: ${NFTBAN_LOGIN_MONITOR_INTERVAL}s)"

    if [[ "$NFTBAN_LOGIN_ALERT_SSH" == "true" ]]; then
        nftban_login_monitor_ssh &
    fi

    # Wait for all background jobs
    wait
}

# =============================================================================
# TEST FUNCTIONS
# =============================================================================

nftban_login_test() {
    # Test login alert system

    echo "Testing NFTBan Login Alert System"
    echo "=================================="
    echo ""

    # Check configuration
    echo "Configuration:"
    echo "  Enabled: $NFTBAN_LOGIN_ALERT_ENABLED"
    echo "  Email: $NFTBAN_LOGIN_ALERT_EMAIL"
    echo "  Format: $NFTBAN_LOGIN_ALERT_FORMAT"
    echo "  GeoIP: $NFTBAN_LOGIN_ALERT_GEOIP"
    echo ""

    # Check GeoIP
    if [[ "$NFTBAN_LOGIN_ALERT_GEOIP" == "true" ]]; then
        echo "Testing GeoIP:"
        local geoip
        geoip=$(nftban_login_get_geoip "8.8.8.8")
        echo "  8.8.8.8 → $geoip"
        echo ""
    fi

    # Test email
    echo "Sending test alert..."
    nftban_login_send_alert \
        "TEST" \
        "testuser" \
        "8.8.8.8" \
        "SSH" \
        "SUCCESS" \
        "This is a test alert from NFTBan login monitoring system."

    echo "✓ Test alert sent to $NFTBAN_LOGIN_ALERT_EMAIL"
    echo ""
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_login_log
export -f nftban_login_is_whitelisted
export -f nftban_login_get_geoip
export -f nftban_login_send_alert
export -f nftban_login_send_text_alert
export -f nftban_login_send_html_alert
export -f nftban_login_monitor_ssh
export -f nftban_login_track_failed
export -f nftban_login_monitor_all
export -f nftban_login_test
