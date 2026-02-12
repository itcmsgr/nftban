#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Login Monitor with Auto-Ban
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_login_alert"
# meta:type="core"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Monitors system logins, detects brute-force, and auto-bans attackers"
# meta:inventory.files=""
# meta:inventory.binaries="last,journalctl"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files="/etc/nftban/conf.d/login_alert.conf"
# meta:inventory.systemd_units="nftban-login-monitor.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

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
# NFTBAN_LIB_DIR is set by the calling script (cmd_login.sh, etc.)
# Use bootstrap pattern to avoid readonly conflicts with env.sh
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"

# Load main nftban.conf for NFTBAN_BIN and other core paths
# This MUST be sourced before using NFTBAN_BIN variable
if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
    # shellcheck source=/etc/nftban/nftban.conf
    source "${NFTBAN_CONFIG_DIR}/nftban.conf"
fi

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/strict.sh"
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/version.sh"
fi

# Load timestamp library for unified timestamp generation
# shellcheck source=/usr/lib/nftban/lib/nftban_timestamp.sh
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh"
fi

# Load alert throttle library for unified alert throttling
# shellcheck source=/usr/lib/nftban/lib/nftban_alert_throttle.sh
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_alert_throttle.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_alert_throttle.sh"
fi

# Load distro configuration for cross-distro service name compatibility
# shellcheck source=/usr/lib/nftban/lib/nftban_distro_config.sh
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_distro_config.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_distro_config.sh"
fi

# Load base config first (defaults)
if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf" ]]; then
    source "${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf"
fi

# Load local overrides (user customizations)
if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf.local" ]]; then
    source "${NFTBAN_CONFIG_DIR}/conf.d/login_alert.conf.local"
fi

# Load global mail module for centralized email
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_mail.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_mail.sh"
fi

# Defaults if not set (NO module-specific email - use global NFTBAN_MAIL_RECIPIENT)
NFTBAN_LOGIN_ALERT_ENABLED="${NFTBAN_LOGIN_ALERT_ENABLED:-true}"
NFTBAN_LOGIN_ALERT_SSH="${NFTBAN_LOGIN_ALERT_SSH:-true}"
NFTBAN_LOGIN_ALERT_SU="${NFTBAN_LOGIN_ALERT_SU:-true}"
NFTBAN_LOGIN_ALERT_SUDO="${NFTBAN_LOGIN_ALERT_SUDO:-true}"
NFTBAN_LOGIN_ALERT_CONSOLE="${NFTBAN_LOGIN_ALERT_CONSOLE:-false}"
NFTBAN_LOGIN_ALERT_GEOIP="${NFTBAN_LOGIN_ALERT_GEOIP:-true}"
NFTBAN_LOGIN_ALERT_FORMAT="${NFTBAN_LOGIN_ALERT_FORMAT:-html}"
NFTBAN_LOGIN_ALERT_LOG="${NFTBAN_LOGIN_ALERT_LOG:-${NFTBAN_LOG_DIR:-/var/log/nftban}/login_alert.log}"
NFTBAN_LOGIN_MONITOR_INTERVAL="${NFTBAN_LOGIN_MONITOR_INTERVAL:-5}"
NFTBAN_LOGIN_WHITELIST="${NFTBAN_LOGIN_WHITELIST:-}"
NFTBAN_LOGIN_ALERT_FAILED="${NFTBAN_LOGIN_ALERT_FAILED:-true}"
# Ban threshold: 10 failures in 5 minutes (300 seconds)
NFTBAN_LOGIN_FAILED_THRESHOLD="${NFTBAN_LOGIN_FAILED_THRESHOLD:-10}"
NFTBAN_LOGIN_FAILED_WINDOW="${NFTBAN_LOGIN_FAILED_WINDOW:-300}"

# Email alert mode: realtime, digest, or both
NFTBAN_LOGIN_ALERT_MODE="${NFTBAN_LOGIN_ALERT_MODE:-realtime}"
NFTBAN_LOGIN_DIGEST_TIME="${NFTBAN_LOGIN_DIGEST_TIME:-08:00}"
NFTBAN_LOGIN_DIGEST_FILE="${NFTBAN_LOGIN_DIGEST_FILE:-/var/lib/nftban/login_digest.json}"

# Template paths
NFTBAN_TEMPLATE_DIR="${NFTBAN_TEMPLATE_DIR:-/usr/share/nftban/templates/alerts}"

# Tracking failed attempts
declare -A NFTBAN_FAILED_ATTEMPTS
declare -A NFTBAN_FAILED_TIMESTAMPS

# Central bans.log path for stats integration
NFTBAN_BAN_LOG="${NFTBAN_LOG_DIR:-/var/log/nftban}/bans.log"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

nftban_login_alert_log() {
    # Log to file and optionally syslog
    local message="$1"
    local timestamp

    # Use timestamp library with graceful fallback
    if declare -f nftban_timestamp_date &>/dev/null && declare -f nftban_timestamp_time &>/dev/null; then
        timestamp="$(nftban_timestamp_date) $(nftban_timestamp_time)"
    else
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    fi

    # Ensure log directory exists
    mkdir -p "$(dirname "$NFTBAN_LOGIN_ALERT_LOG")"

    # Log to file
    echo "[$timestamp] $message" >> "$NFTBAN_LOGIN_ALERT_LOG"

    # Log to syslog
    logger -t nftban-login-alert "$message"
}

nftban_login_write_bans_log() {
    # Write ban entry to central bans.log for stats integration
    # Format: DATE|TIME|SOURCE|IP|COUNTRY|STATUS|REASON
    # (matches pkg/banlog/banlog.go canonical format)
    local ip="$1"
    local reason="$2"
    local country="${3:-UNK}"

    local log_dir
    log_dir=$(dirname "$NFTBAN_BAN_LOG")

    # Ensure log directory exists
    mkdir -p "$log_dir"

    # Get current date and time using timestamp library with graceful fallback
    local date_str time_str
    if declare -f nftban_timestamp_date &>/dev/null; then
        date_str=$(nftban_timestamp_date)
    else
        date_str=$(date '+%Y-%m-%d')
    fi
    if declare -f nftban_timestamp_time &>/dev/null; then
        time_str=$(nftban_timestamp_time)
    else
        time_str=$(date '+%H:%M:%S')
    fi

    # Sanitize reason (replace pipe characters to preserve format)
    reason="${reason//|/-}"
    reason="${reason//$'\n'/ }"
    reason="${reason//$'\r'/ }"

    # Write canonical format: DATE|TIME|SOURCE|IP|COUNTRY|STATUS|REASON
    echo "${date_str}|${time_str}|login|${ip}|${country}|BANNED|${reason}" >> "$NFTBAN_BAN_LOG"

    nftban_login_alert_log "Wrote ban to bans.log: ${ip} (${reason})"
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
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_geoip_go.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_geoip_go.sh"

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
# DIGEST FUNCTIONS
# =============================================================================

nftban_login_digest_add() {
    # Add an alert to the digest file for daily summary
    # Args: $1=event_type, $2=user, $3=ip, $4=service, $5=status, $6=details, $7=geoip, $8=timestamp

    local event_type="$1"
    local user="$2"
    local ip="$3"
    local service="$4"
    local status="$5"
    local details="$6"
    local geoip="$7"
    local timestamp="$8"

    local digest_file="${NFTBAN_LOGIN_DIGEST_FILE:-/var/lib/nftban/login_digest.json}"
    local digest_dir
    digest_dir=$(dirname "$digest_file")

    # Ensure directory exists
    mkdir -p "$digest_dir"

    # Create empty JSON array if file doesn't exist or is empty
    if [[ ! -s "$digest_file" ]]; then
        echo "[]" > "$digest_file"
    fi

    # Build JSON entry (escape special characters)
    local json_entry
    json_entry=$(cat <<EOF
{
  "timestamp": "$timestamp",
  "event_type": "$event_type",
  "user": "$user",
  "ip": "$ip",
  "service": "$service",
  "status": "$status",
  "details": "$details",
  "geoip": "$geoip"
}
EOF
)

    # Append to JSON array using jq if available, fallback to sed
    if command -v jq &>/dev/null; then
        local tmp_file="${digest_file}.tmp"
        jq --argjson entry "$json_entry" '. += [$entry]' "$digest_file" > "$tmp_file" 2>/dev/null && mv "$tmp_file" "$digest_file"
    else
        # Fallback: simple append (less robust but works)
        # Remove trailing ] and add entry
        sed -i '$ s/]$//' "$digest_file"
        # Add comma if not first entry
        if grep -q '{' "$digest_file"; then
            echo "," >> "$digest_file"
        fi
        echo "$json_entry" >> "$digest_file"
        echo "]" >> "$digest_file"
    fi

    nftban_login_alert_log "Added alert to digest: $user@$ip ($status)"
}

nftban_login_digest_clear() {
    # Clear the digest file after sending
    local digest_file="${NFTBAN_LOGIN_DIGEST_FILE:-/var/lib/nftban/login_digest.json}"
    echo "[]" > "$digest_file"
    nftban_login_alert_log "Digest file cleared"
}

nftban_login_digest_count() {
    # Count alerts in digest file
    local digest_file="${NFTBAN_LOGIN_DIGEST_FILE:-/var/lib/nftban/login_digest.json}"

    if [[ ! -s "$digest_file" ]]; then
        echo "0"
        return
    fi

    if command -v jq &>/dev/null; then
        jq 'length' "$digest_file" 2>/dev/null || echo "0"
    else
        grep -c '"timestamp"' "$digest_file" 2>/dev/null || echo "0"
    fi
}

nftban_login_digest_send() {
    # Send daily login digest email
    # Usage: called by nftban report run daily (if mode=digest or mode=both)

    local digest_file="${NFTBAN_LOGIN_DIGEST_FILE:-/var/lib/nftban/login_digest.json}"
    local count
    count=$(nftban_login_digest_count)

    if [[ "$count" -eq 0 ]]; then
        nftban_login_alert_log "No login alerts to digest"
        return 0
    fi

    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)
    local timestamp
    # Use timestamp library with graceful fallback
    if declare -f nftban_timestamp_local &>/dev/null; then
        # nftban_timestamp_local returns ISO format, add timezone name for display
        timestamp="$(nftban_timestamp_date) $(nftban_timestamp_time) $(date '+%Z')"
    else
        timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    fi
    local date_range
    date_range=$(date -d 'yesterday' '+%Y-%m-%d')

    nftban_login_alert_log "Sending login digest with $count alerts"

    # Parse digest data
    local failed_count=0
    local success_count=0
    local unique_ips=""
    local alerts_html=""

    if command -v jq &>/dev/null && [[ -s "$digest_file" ]]; then
        failed_count=$(jq '[.[] | select(.status == "FAILED")] | length' "$digest_file" 2>/dev/null || echo "0")
        success_count=$(jq '[.[] | select(.status == "SUCCESS")] | length' "$digest_file" 2>/dev/null || echo "0")
        unique_ips=$(jq -r '[.[].ip] | unique | length' "$digest_file" 2>/dev/null || echo "0")

        # Build alerts table rows
        alerts_html=$(jq -r '.[] | "<tr><td>\(.timestamp)</td><td>\(.user)</td><td><code>\(.ip)</code></td><td>\(.service)</td><td><span class=\"status-\(.status | ascii_downcase)\">\(.status)</span></td><td>\(.geoip)</td></tr>"' "$digest_file" 2>/dev/null || echo "")
    fi

    # Build HTML email
    local html
    html=$(cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>NFTBan Login Digest</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 0; padding: 20px; background: #f5f5f5; }
        .container { max-width: 800px; margin: 0 auto; background: white; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        .header { background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); color: white; padding: 30px; border-radius: 8px 8px 0 0; }
        .header h1 { margin: 0 0 10px 0; font-size: 24px; }
        .header .date { opacity: 0.9; font-size: 14px; }
        .summary { display: flex; gap: 20px; padding: 20px 30px; background: #f8f9fa; border-bottom: 1px solid #eee; }
        .summary-box { flex: 1; text-align: center; padding: 15px; background: white; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        .summary-box .number { font-size: 32px; font-weight: bold; color: #333; }
        .summary-box .label { font-size: 12px; color: #666; text-transform: uppercase; }
        .summary-box.failed .number { color: #dc3545; }
        .summary-box.success .number { color: #28a745; }
        .content { padding: 30px; }
        table { width: 100%; border-collapse: collapse; font-size: 13px; }
        th { background: #f8f9fa; padding: 12px 8px; text-align: left; border-bottom: 2px solid #dee2e6; font-weight: 600; }
        td { padding: 10px 8px; border-bottom: 1px solid #eee; }
        tr:hover { background: #f8f9fa; }
        code { background: #e9ecef; padding: 2px 6px; border-radius: 3px; font-size: 12px; }
        .status-failed { color: #dc3545; font-weight: bold; }
        .status-success { color: #28a745; }
        .status-suspicious { color: #ffc107; }
        .footer { text-align: center; padding: 20px; color: #666; font-size: 12px; border-top: 1px solid #eee; }
        .footer a { color: #667eea; text-decoration: none; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>📊 NFTBan Login Digest</h1>
            <div class="date">Server: $hostname | Date: $date_range</div>
        </div>

        <div class="summary">
            <div class="summary-box">
                <div class="number">$count</div>
                <div class="label">Total Alerts</div>
            </div>
            <div class="summary-box failed">
                <div class="number">$failed_count</div>
                <div class="label">Failed Logins</div>
            </div>
            <div class="summary-box success">
                <div class="number">$success_count</div>
                <div class="label">Successful</div>
            </div>
            <div class="summary-box">
                <div class="number">$unique_ips</div>
                <div class="label">Unique IPs</div>
            </div>
        </div>

        <div class="content">
            <h2>Login Events</h2>
            <table>
                <thead>
                    <tr>
                        <th>Timestamp</th>
                        <th>User</th>
                        <th>IP Address</th>
                        <th>Service</th>
                        <th>Status</th>
                        <th>Location</th>
                    </tr>
                </thead>
                <tbody>
                    $alerts_html
                </tbody>
            </table>
        </div>

        <div class="footer">
            <strong>nftban — Simplifying Linux Firewall Management</strong><br>
            <a href="https://nftban.com">https://nftban.com</a><br>
            Generated: $timestamp
        </div>
    </div>
</body>
</html>
EOF
)

    # Send email using global mail system
    local subject="[NFTBan] Daily Login Digest: $count alerts - $hostname"

    # Send via NFTBan unified mail mechanism
    if nftban_mail_send "$html" 2>/dev/null; then
        nftban_login_alert_log "Login digest sent successfully ($count alerts)"
        # Clear digest after successful send
        nftban_login_digest_clear
        return 0
    else
        nftban_login_alert_log "Failed to send login digest"
        return 1
    fi
}

# =============================================================================
# ALERT FUNCTIONS
# =============================================================================

nftban_login_send_alert() {
    # Send login alert email based on configured mode
    # Args: $1=event_type, $2=user, $3=ip, $4=service, $5=status, $6=details

    local event_type="$1"
    local user="$2"
    local ip="$3"
    local service="$4"
    local status="$5"
    local details="${6:-}"

    # Alert throttling: prevent storm of alerts from same IP
    # Use throttle library with graceful fallback (default: 60 seconds per IP)
    local throttle_key="login_alert_${ip}"
    if declare -f nftban_should_alert &>/dev/null; then
        if ! nftban_should_alert "$throttle_key" 60; then
            nftban_login_alert_log "Alert throttled for IP $ip (sent recently)"
            return 0
        fi
    fi

    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)
    local timestamp
    # Use timestamp library with graceful fallback
    if declare -f nftban_timestamp_date &>/dev/null && declare -f nftban_timestamp_time &>/dev/null; then
        timestamp="$(nftban_timestamp_date) $(nftban_timestamp_time) $(date '+%Z')"
    else
        timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')
    fi
    local geoip
    geoip=$(nftban_login_get_geoip "$ip")

    # Build subject
    local subject="[NFTBan] $status Login: $user @ $hostname"

    # Handle alert based on mode
    local mode="${NFTBAN_LOGIN_ALERT_MODE:-realtime}"

    case "$mode" in
        realtime)
            # Send email immediately (original behavior)
            if [[ "$NFTBAN_LOGIN_ALERT_FORMAT" == "html" ]]; then
                nftban_login_send_html_alert "$subject" "$event_type" "$user" "$ip" "$service" "$status" "$geoip" "$details" "$hostname" "$timestamp"
            else
                nftban_login_send_text_alert "$subject" "$event_type" "$user" "$ip" "$service" "$status" "$geoip" "$details" "$hostname" "$timestamp"
            fi
            ;;
        digest)
            # Only add to digest, no immediate email
            nftban_login_digest_add "$event_type" "$user" "$ip" "$service" "$status" "$details" "$geoip" "$timestamp"
            ;;
        both)
            # Send immediate email AND add to digest
            if [[ "$NFTBAN_LOGIN_ALERT_FORMAT" == "html" ]]; then
                nftban_login_send_html_alert "$subject" "$event_type" "$user" "$ip" "$service" "$status" "$geoip" "$details" "$hostname" "$timestamp"
            else
                nftban_login_send_text_alert "$subject" "$event_type" "$user" "$ip" "$service" "$status" "$geoip" "$details" "$hostname" "$timestamp"
            fi
            nftban_login_digest_add "$event_type" "$user" "$ip" "$service" "$status" "$details" "$geoip" "$timestamp"
            ;;
        *)
            # Unknown mode, default to realtime
            nftban_login_alert_log "Unknown alert mode: $mode, using realtime"
            if [[ "$NFTBAN_LOGIN_ALERT_FORMAT" == "html" ]]; then
                nftban_login_send_html_alert "$subject" "$event_type" "$user" "$ip" "$service" "$status" "$geoip" "$details" "$hostname" "$timestamp"
            else
                nftban_login_send_text_alert "$subject" "$event_type" "$user" "$ip" "$service" "$status" "$geoip" "$details" "$hostname" "$timestamp"
            fi
            ;;
    esac
}

nftban_login_send_text_alert() {
    # Send plain text alert using global mail system
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

    # Send via NFTBan unified mail mechanism
    nftban_mail_send "$body"
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
    <meta name="generator" content="NFTBan v1.0.0">
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

    # Send via NFTBan unified mail mechanism
    # Email is OPTIONAL - if it fails, just log it but don't crash the monitor
    if ! nftban_mail_send "$html" 2>/dev/null; then
        nftban_login_alert_log "Email alert failed"
    fi
}

# =============================================================================
# MONITORING FUNCTIONS
# =============================================================================

nftban_login_monitor_ssh() {
    # Monitor SSH logins via journalctl

    # Get correct SSH service name for this distribution
    local ssh_service="sshd"  # Default fallback
    local ssh_session_service=""
    if declare -f nftban_distro_get_service >/dev/null 2>&1; then
        ssh_service=$(nftban_distro_get_service "sshd")
        ssh_session_service=$(nftban_distro_get_service "sshd_session")
        # If empty, fall back to sshd
        ssh_service="${ssh_service:-sshd}"
    fi

    # Build journalctl units from distro config
    # sshd_session is defined in distro config for systems that use separate session unit
    local -a journal_units=("-u" "${ssh_service}")
    if [[ -n "${ssh_session_service}" ]]; then
        journal_units+=("-u" "${ssh_session_service}")
        nftban_login_alert_log "Monitoring SSH services: ${ssh_service}, ${ssh_session_service}"
    else
        nftban_login_alert_log "Monitoring SSH service: ${ssh_service}"
    fi

    # CRITICAL: Use process substitution instead of pipe to avoid subshell
    # With pipe (|), the while loop runs in a subshell and NFTBAN_FAILED_ATTEMPTS
    # array changes are lost. Process substitution keeps the loop in current shell.
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
                nftban_login_alert_log "SSH login: $user from $ip (method: $method)"
                nftban_login_send_alert "SSH Login" "$user" "$ip" "SSH" "SUCCESS" "Authentication method: $method"
            fi
        fi

        # Failed login (existing user)
        if [[ "$message" =~ ^Failed\ (password|publickey)\ for\ ([^[:space:]]+)\ from\ ([0-9.]+) ]]; then
            local method="${BASH_REMATCH[1]}"
            local user="${BASH_REMATCH[2]}"
            local ip="${BASH_REMATCH[3]}"

            nftban_login_track_failed "$user" "$ip" "SSH"
        fi

        # Invalid user (username enumeration attack)
        if [[ "$message" =~ ^Invalid\ user\ ([^[:space:]]+)\ from\ ([0-9.]+) ]]; then
            local user="${BASH_REMATCH[1]}"
            local ip="${BASH_REMATCH[2]}"

            nftban_login_track_failed "$user" "$ip" "SSH"
        fi

        # Failed password for invalid user
        if [[ "$message" =~ ^Failed\ password\ for\ invalid\ user\ ([^[:space:]]+)\ from\ ([0-9.]+) ]]; then
            local user="${BASH_REMATCH[1]}"
            local ip="${BASH_REMATCH[2]}"

            nftban_login_track_failed "$user" "$ip" "SSH"
        fi

        # Too many authentication failures (rapid brute-force indicator)
        if [[ "$message" =~ ^Received\ disconnect\ from\ ([0-9.]+).*[Tt]oo\ many\ authentication\ failures ]]; then
            local ip="${BASH_REMATCH[1]}"

            nftban_login_track_failed "unknown" "$ip" "SSH"
        fi
    done < <(journalctl "${journal_units[@]}" -f -n 0 --output=json 2>/dev/null)
}

nftban_login_track_failed() {
    # Track failed login attempts
    local user="$1"
    local ip="$2"
    local service="$3"

    local key="${user}@${ip}"
    local now
    # Use timestamp library with graceful fallback
    if declare -f nftban_timestamp_unix &>/dev/null; then
        now=$(nftban_timestamp_unix)
    else
        now=$(date +%s)
    fi

    # Initialize if first attempt
    if [[ -z "${NFTBAN_FAILED_ATTEMPTS[$key]:-}" ]]; then
        NFTBAN_FAILED_ATTEMPTS[$key]=1
        NFTBAN_FAILED_TIMESTAMPS[$key]=$now
    else
        # Check if within time window
        local first_attempt="${NFTBAN_FAILED_TIMESTAMPS[$key]}"
        local elapsed
        elapsed=$((now - first_attempt))

        if [[ $elapsed -lt $NFTBAN_LOGIN_FAILED_WINDOW ]]; then
            # Increment counter
            NFTBAN_FAILED_ATTEMPTS[$key]=$((${NFTBAN_FAILED_ATTEMPTS[$key]} + 1))

            # Check threshold
            if [[ ${NFTBAN_FAILED_ATTEMPTS[$key]} -ge $NFTBAN_LOGIN_FAILED_THRESHOLD ]]; then
                nftban_login_alert_log "Multiple failed attempts: $user from $ip ($service)"

                # Send alert
                nftban_login_send_alert "Failed Login Attempts" "$user" "$ip" "$service" "FAILED" \
                    "Failed attempts: ${NFTBAN_FAILED_ATTEMPTS[$key]} in ${elapsed} seconds"

                # BAN THE IP (v1.0 replaces fail2ban)
                local ban_reason="${service} brute-force (${NFTBAN_FAILED_ATTEMPTS[$key]} failed attempts)"
                nftban_login_alert_log "Banning IP $ip for ${ban_reason}"

                # Use NFTBAN_BIN from central config (set during install by install_configs.sh)
                # Config is single source of truth - no runtime detection
                local nftban_cmd="${NFTBAN_BIN:-/usr/sbin/nftban}"

                # Pre-flight checks with clear error messages
                if [[ ! -x "$nftban_cmd" ]]; then
                    nftban_login_alert_log "ERROR: NFTBAN_BIN=$nftban_cmd not executable. Check config /etc/nftban/nftban.conf"
                else
                    # Check if daemon socket exists (IPC required for banning)
                    local ipc_socket="${NFTBAN_RUN_DIR:-/run/nftban}/nftband.sock"
                    if [[ ! -S "$ipc_socket" ]]; then
                        nftban_login_alert_log "ERROR: Cannot ban $ip - daemon not running (socket missing: $ipc_socket)"
                    else
                        # Execute ban with captured error for debugging
                        # Capture exit code properly before || true prevents set -e crash
                        local ban_output ban_exit
                        ban_output=$("$nftban_cmd" ban "$ip" --source login --reason "${service}_brute_force (${NFTBAN_FAILED_ATTEMPTS[$key]} failed attempts)" 2>&1) && ban_exit=0 || ban_exit=$?
                        if [[ $ban_exit -ne 0 ]]; then
                            nftban_login_alert_log "ERROR: Ban failed (exit=$ban_exit): $ban_output"
                        fi
                    fi
                fi

                # Write to bans.log for stats integration (keeps both logs for compatibility)
                # Get country code for bans.log entry
                local country_code="UNK"
                if [[ "$NFTBAN_LOGIN_ALERT_GEOIP" == "true" ]]; then
                    # Extract just the country code from geoip output (e.g., "US" from "US, United States")
                    local geoip_data
                    geoip_data=$(nftban_login_get_geoip "$ip" 2>/dev/null)
                    if [[ -n "$geoip_data" && "$geoip_data" != "GeoIP"* && "$geoip_data" != "Unknown" ]]; then
                        # Extract first field (country code) if comma-separated
                        country_code="${geoip_data%%,*}"
                        country_code="${country_code%% *}"  # Remove trailing spaces
                        # Ensure it's a valid 2-letter code
                        if [[ ! "$country_code" =~ ^[A-Z]{2}$ ]]; then
                            country_code="UNK"
                        fi
                    fi
                fi
                nftban_login_write_bans_log "$ip" "$ban_reason" "$country_code"

                # Reset counter
                unset 'NFTBAN_FAILED_ATTEMPTS[$key]'
                unset 'NFTBAN_FAILED_TIMESTAMPS[$key]'
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

    nftban_login_alert_log "Starting login monitoring (interval: ${NFTBAN_LOGIN_MONITOR_INTERVAL}s)"

    if [[ "$NFTBAN_LOGIN_ALERT_SSH" == "true" ]]; then
        nftban_login_monitor_ssh &
    fi

    # Wait for all background jobs
    wait
}

# =============================================================================
# TEST FUNCTIONS
# =============================================================================

nftban_login_alert_test() {
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

export -f nftban_login_alert_log
export -f nftban_login_write_bans_log
export -f nftban_login_is_whitelisted
export -f nftban_login_get_geoip
export -f nftban_login_digest_add
export -f nftban_login_digest_clear
export -f nftban_login_digest_count
export -f nftban_login_digest_send
export -f nftban_login_send_alert
export -f nftban_login_send_text_alert
export -f nftban_login_send_html_alert
export -f nftban_login_monitor_ssh
export -f nftban_login_track_failed
export -f nftban_login_monitor_all
export -f nftban_login_alert_test
