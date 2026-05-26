#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_pro" meta:type="lib" meta:version="1.41.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Manages NFTBan Pro subscription, inventory, and license"
# meta:inventory.files=""
# meta:inventory.binaries="curl"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_DATA_DIR"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network="https://api.nftban.com"
# meta:inventory.privileges="nftban"

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_PRO_LOADED:-}" ]] && return 0
readonly NFTBAN_PRO_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================

# Load main configuration
if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" || true
fi

# Pro endpoints
: "${NFTBAN_PRO_REMOTE_WRITE_URL:=https://pro.nftban.com/api/v1/write}"
: "${NFTBAN_PRO_INVENTORY_URL:=https://pro.nftban.com/api/v1/inventory}"
: "${NFTBAN_PRO_STATUS_URL:=https://pro.nftban.com/api/v1/enroll/status}"

# Local paths
: "${NFTBAN_PRO_TOKEN_FILE:=/etc/nftban/pro.token}"
: "${NFTBAN_PRO_SERVER_ID_FILE:=/etc/nftban/server_id}"
: "${NFTBAN_PRO_DATA_DIR:=/var/lib/nftban/pro}"
: "${NFTBAN_PRO_INVENTORY_FILE:=${NFTBAN_PRO_DATA_DIR}/inventory.json}"
: "${NFTBAN_PRO_INVENTORY_HASH_FILE:=${NFTBAN_PRO_DATA_DIR}/inventory.sha256}"
: "${NFTBAN_PRO_LICENSE_FILE:=${NFTBAN_PRO_DATA_DIR}/license.json}"
: "${NFTBAN_PRO_LAST_SUBMIT_FILE:=${NFTBAN_PRO_DATA_DIR}/last_submit.json}"

# Timeouts
: "${NFTBAN_PRO_TIMEOUT:=30}"

# =============================================================================
# SERVER ID MANAGEMENT
# =============================================================================

nftban_pro_ensure_server_id() {
    # Ensure server_id exists, generate if missing
    #
    # Returns: server_id string
    # Creates: /etc/nftban/server_id if not exists

    local server_id=""

    if [[ -f "$NFTBAN_PRO_SERVER_ID_FILE" ]]; then
        server_id=$(cat "$NFTBAN_PRO_SERVER_ID_FILE" 2>/dev/null | tr -d '\n')
    fi

    if [[ -z "$server_id" ]]; then
        # Generate new server_id using machine-id + random suffix
        local machine_id=""
        if [[ -f /etc/machine-id ]]; then
            machine_id=$(cat /etc/machine-id | head -c 16)
        else
            machine_id=$(head -c 16 /dev/urandom | xxd -p)
        fi

        local random_suffix
        random_suffix=$(head -c 4 /dev/urandom | xxd -p)

        server_id="${machine_id}-${random_suffix}"

        # Ensure directory exists
        mkdir -p "$(dirname "$NFTBAN_PRO_SERVER_ID_FILE")" || return 1

        # Write with secure permissions
        echo "$server_id" > "$NFTBAN_PRO_SERVER_ID_FILE"
        chmod 640 "$NFTBAN_PRO_SERVER_ID_FILE"
        chown root:nftban "$NFTBAN_PRO_SERVER_ID_FILE" 2>/dev/null || true
    fi

    echo "$server_id"
}

nftban_pro_get_server_id() {
    # Get server_id (read-only, does not create)
    #
    # Returns: server_id or empty string

    if [[ -f "$NFTBAN_PRO_SERVER_ID_FILE" ]]; then
        cat "$NFTBAN_PRO_SERVER_ID_FILE" 2>/dev/null | tr -d '\n'
    fi
}

# =============================================================================
# INVENTORY COLLECTION
# =============================================================================

nftban_pro_collect_inventory() {
    # Collect stable inventory fields
    #
    # Fields collected (stable only, no IPs/uptime/load):
    #   - OS distro/version/kernel
    #   - Control panel name/version
    #   - CPU model/cores
    #   - RAM total
    #   - Storage type/totals
    #   - Suricata present/version
    #
    # Output: JSON to stdout

    local server_id
    server_id=$(nftban_pro_get_server_id)

    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)

    # OS info
    local os_distro=""
    local os_version=""
    local os_kernel=""

    if [[ -f /etc/os-release ]]; then
        os_distro=$(grep "^ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
        os_version=$(grep "^VERSION_ID=" /etc/os-release | cut -d= -f2 | tr -d '"')
    fi
    os_kernel=$(uname -r)

    # Control panel detection
    local panel_name="none"
    local panel_version=""

    if [[ -f /usr/local/cpanel/version ]]; then
        panel_name="cpanel"
        panel_version=$(cat /usr/local/cpanel/version 2>/dev/null || echo "")
    elif [[ -f /usr/local/directadmin/directadmin ]]; then
        panel_name="directadmin"
        panel_version=$(/usr/local/directadmin/directadmin v 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")
    elif [[ -f /usr/local/psa/version ]]; then
        panel_name="plesk"
        panel_version=$(cat /usr/local/psa/version 2>/dev/null || echo "")
    elif [[ -d /usr/local/cwp ]]; then
        panel_name="cwp"
        panel_version=""
    elif [[ -d /usr/local/CyberCP ]]; then
        panel_name="cyberpanel"
        panel_version=""
    fi

    # CPU info
    local cpu_model=""
    local cpu_cores=0

    if [[ -f /proc/cpuinfo ]]; then
        cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
        cpu_cores=$(grep -c "^processor" /proc/cpuinfo)
    fi

    # RAM total (in MB)
    local ram_total_mb=0
    if [[ -f /proc/meminfo ]]; then
        local mem_kb
        mem_kb=$(grep "^MemTotal:" /proc/meminfo | awk '{print $2}')
        ram_total_mb=$((mem_kb / 1024))
    fi

    # Storage info
    local storage_type="unknown"
    local storage_total_gb=0

    # Try to detect SSD/HDD
    local root_device
    root_device=$(df / | tail -1 | awk '{print $1}' | sed 's/[0-9]*$//')
    root_device=$(basename "$root_device" 2>/dev/null || echo "")

    if [[ -n "$root_device" ]] && [[ -f "/sys/block/${root_device}/queue/rotational" ]]; then
        local rotational
        rotational=$(cat "/sys/block/${root_device}/queue/rotational" 2>/dev/null || echo "1")
        if [[ "$rotational" == "0" ]]; then
            storage_type="ssd"
        else
            storage_type="hdd"
        fi
    fi

    # Total storage (root filesystem in GB)
    storage_total_gb=$(df -BG / | tail -1 | awk '{print $2}' | tr -d 'G')

    # Suricata detection
    local suricata_present="false"
    local suricata_version=""

    if command -v suricata &>/dev/null; then
        suricata_present="true"
        suricata_version=$(suricata --build-info 2>/dev/null | grep "Suricata version" | grep -oP '\d+\.\d+\.\d+' || echo "")
    fi

    # NFTBan version
    local nftban_version="${NFTBAN_VERSION:-unknown}"

    # Generate JSON
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    cat << EOF
{
  "server_id": "$server_id",
  "hostname": "$hostname",
  "collected_at": "$timestamp",
  "os": {
    "distro": "$os_distro",
    "version": "$os_version",
    "kernel": "$os_kernel"
  },
  "panel": {
    "name": "$panel_name",
    "version": "$panel_version"
  },
  "cpu": {
    "model": "$cpu_model",
    "cores": $cpu_cores
  },
  "memory": {
    "total_mb": $ram_total_mb
  },
  "storage": {
    "type": "$storage_type",
    "total_gb": $storage_total_gb
  },
  "suricata": {
    "present": $suricata_present,
    "version": "$suricata_version"
  },
  "nftban": {
    "version": "$nftban_version"
  }
}
EOF
}

nftban_pro_save_inventory() {
    # Collect and save inventory to disk with SHA256 hash
    #
    # Creates:
    #   - /var/lib/nftban/pro/inventory.json
    #   - /var/lib/nftban/pro/inventory.sha256

    mkdir -p "$NFTBAN_PRO_DATA_DIR" || return 1
    chown nftban:nftban "$NFTBAN_PRO_DATA_DIR" 2>/dev/null || true

    # Collect inventory
    local inventory
    inventory=$(nftban_pro_collect_inventory)

    # Save inventory
    echo "$inventory" > "$NFTBAN_PRO_INVENTORY_FILE"
    chmod 640 "$NFTBAN_PRO_INVENTORY_FILE"

    # Calculate and save hash
    local hash
    hash=$(echo "$inventory" | sha256sum | awk '{print $1}')
    echo "$hash" > "$NFTBAN_PRO_INVENTORY_HASH_FILE"
    chmod 640 "$NFTBAN_PRO_INVENTORY_HASH_FILE"

    echo "$hash"
}

nftban_pro_inventory_changed() {
    # Check if inventory has changed since last save
    #
    # Returns: 0 if changed (or no previous hash), 1 if unchanged

    if [[ ! -f "$NFTBAN_PRO_INVENTORY_HASH_FILE" ]]; then
        return 0  # No previous hash = changed
    fi

    local old_hash
    old_hash=$(cat "$NFTBAN_PRO_INVENTORY_HASH_FILE" 2>/dev/null || echo "")

    local current_inventory
    current_inventory=$(nftban_pro_collect_inventory)

    local new_hash
    new_hash=$(echo "$current_inventory" | sha256sum | awk '{print $1}')

    if [[ "$old_hash" != "$new_hash" ]]; then
        return 0  # Changed
    fi

    return 1  # Unchanged
}

# =============================================================================
# INVENTORY SUBMISSION
# =============================================================================

nftban_pro_submit_inventory() {
    # Submit inventory to Pro endpoint (only if changed)
    #
    # Returns:
    #   0 = Submitted successfully
    #   1 = Submission failed
    #   2 = No change (not submitted)
    #   3 = Token missing
    #   4 = Pro endpoint not available

    local force="${1:-false}"

    # Check token exists
    if [[ ! -f "$NFTBAN_PRO_TOKEN_FILE" ]]; then
        echo "ERROR: Token file not found: $NFTBAN_PRO_TOKEN_FILE" >&2
        return 3
    fi

    local token
    token=$(cat "$NFTBAN_PRO_TOKEN_FILE" | tr -d '\n')

    if [[ -z "$token" ]]; then
        echo "ERROR: Token file is empty" >&2
        return 3
    fi

    # Check if inventory changed (unless forced)
    if [[ "$force" != "true" ]] && ! nftban_pro_inventory_changed; then
        echo "INFO: Inventory unchanged, skipping submission"
        return 2
    fi

    # Save current inventory and get hash
    local hash
    hash=$(nftban_pro_save_inventory)

    # Read inventory
    local inventory
    inventory=$(cat "$NFTBAN_PRO_INVENTORY_FILE")

    # Build submission payload
    local server_id
    server_id=$(nftban_pro_get_server_id)

    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local payload
    payload=$(cat << EOF
{
  "server_id": "$server_id",
  "checksum": "$hash",
  "timestamp": "$timestamp",
  "inventory": $inventory
}
EOF
)

    # Submit to Pro endpoint
    # v1.19.0: Use mktemp instead of predictable PID-based temp files (R17)
    local _pro_tmp_response
    _pro_tmp_response=$(mktemp "${NFTBAN_RUN_DIR:-/run/nftban}/nftban_pro_XXXXXX")
    trap 'rm -f "${_pro_tmp_response:-}"' RETURN

    local response
    local http_code
    http_code=$(curl -sf --connect-timeout "$NFTBAN_PRO_TIMEOUT" \
        -X POST \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        -w "%{http_code}" \
        -o "$_pro_tmp_response" \
        "$NFTBAN_PRO_INVENTORY_URL" 2>/dev/null || echo "000")

    response=$(cat "$_pro_tmp_response" 2>/dev/null || echo "")
    rm -f "$_pro_tmp_response"

    case "$http_code" in
        200|201|202)
            # Success - save submission record
            cat > "$NFTBAN_PRO_LAST_SUBMIT_FILE" << EOF
{
  "submitted_at": "$timestamp",
  "checksum": "$hash",
  "http_code": $http_code,
  "success": true
}
EOF
            echo "OK: Inventory submitted successfully"
            return 0
            ;;
        401)
            echo "ERROR: Invalid token (401 Unauthorized)" >&2
            return 1
            ;;
        402|403)
            echo "ERROR: Subscription inactive or limit exceeded ($http_code)" >&2
            return 1
            ;;
        000)
            echo "ERROR: Could not reach Pro endpoint" >&2
            return 4
            ;;
        *)
            echo "ERROR: Submission failed with HTTP $http_code" >&2
            return 1
            ;;
    esac
}

# =============================================================================
# LICENSE MANAGEMENT
# =============================================================================

nftban_pro_check_license() {
    # Check Pro license/subscription status
    #
    # Returns:
    #   0 = Valid subscription
    #   1 = Invalid/expired subscription
    #   2 = Token missing
    #   3 = Could not reach endpoint

    # Check token exists
    if [[ ! -f "$NFTBAN_PRO_TOKEN_FILE" ]]; then
        return 2
    fi

    local token
    token=$(cat "$NFTBAN_PRO_TOKEN_FILE" | tr -d '\n')

    if [[ -z "$token" ]]; then
        return 2
    fi

    local server_id
    server_id=$(nftban_pro_get_server_id)

    # Query status endpoint
    # v1.19.0: Use mktemp instead of predictable PID-based temp files (R17)
    local _pro_tmp_license
    _pro_tmp_license=$(mktemp "${NFTBAN_RUN_DIR:-/run/nftban}/nftban_pro_XXXXXX")
    trap 'rm -f "${_pro_tmp_license:-}"' RETURN

    local http_code
    http_code=$(curl -sf --connect-timeout "$NFTBAN_PRO_TIMEOUT" \
        -H "Authorization: Bearer $token" \
        -w "%{http_code}" \
        -o "$_pro_tmp_license" \
        "${NFTBAN_PRO_STATUS_URL}?server_id=${server_id}" 2>/dev/null || echo "000")

    local response
    response=$(cat "$_pro_tmp_license" 2>/dev/null || echo "")
    rm -f "$_pro_tmp_license"

    case "$http_code" in
        200)
            # Save license info
            echo "$response" > "$NFTBAN_PRO_LICENSE_FILE"
            chmod 640 "$NFTBAN_PRO_LICENSE_FILE"

            # Check if subscription is active
            local status
            status=$(echo "$response" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")

            if [[ "$status" == "active" ]]; then
                return 0
            else
                return 1
            fi
            ;;
        401|403)
            return 1
            ;;
        000)
            return 3
            ;;
        *)
            return 1
            ;;
    esac
}

nftban_pro_is_enabled() {
    # Check if Pro features are enabled and valid
    #
    # Returns: 0 if enabled and valid, 1 otherwise

    # Check if token exists
    if [[ ! -f "$NFTBAN_PRO_TOKEN_FILE" ]]; then
        return 1
    fi

    # Check cached license (avoid hitting endpoint every time)
    if [[ -f "$NFTBAN_PRO_LICENSE_FILE" ]]; then
        local cached_status
        cached_status=$(jq -r '.status // "unknown"' "$NFTBAN_PRO_LICENSE_FILE" 2>/dev/null || echo "unknown")

        local cached_expires
        cached_expires=$(jq -r '.expires_at // "1970-01-01"' "$NFTBAN_PRO_LICENSE_FILE" 2>/dev/null || echo "1970-01-01")

        # Check if cached license is still valid (not expired)
        local now_epoch
        now_epoch=$(date +%s)
        local expires_epoch
        expires_epoch=$(date -d "$cached_expires" +%s 2>/dev/null || echo "0")

        if [[ "$cached_status" == "active" ]] && [[ $expires_epoch -gt $now_epoch ]]; then
            return 0
        fi
    fi

    # No valid cache - check online
    nftban_pro_check_license
    return $?
}

nftban_pro_disable_remote() {
    # Disable Pro remote submission (when subscription invalid)
    # Keeps local metrics/watchdog running

    # Stop vmagent if it's configured for Pro
    if [[ -f /etc/victoriametrics/vmagent.yml ]]; then
        if grep -q "pro.nftban.com" /etc/victoriametrics/vmagent.yml 2>/dev/null; then
            systemctl stop vmagent 2>/dev/null || true
            systemctl disable vmagent 2>/dev/null || true
            echo "INFO: Disabled vmagent (Pro remote_write)"
        fi
    fi

    # Mark Pro as disabled (polkit-aware refusal instead of a raw write leak)
    mkdir -p "$NFTBAN_PRO_DATA_DIR" 2>/dev/null || true
    if [[ $EUID -ne 0 && ! -w "$NFTBAN_PRO_DATA_DIR" ]]; then
        echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges (update Pro status)" >&2
        return 1
    fi
    printf '{"enabled": false, "reason": "subscription_invalid", "disabled_at": "%s"}\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$NFTBAN_PRO_DATA_DIR/status.json"
}

nftban_pro_enable_remote() {
    # Enable Pro remote submission (when subscription valid)

    # Start vmagent if configured for Pro
    if [[ -f /etc/victoriametrics/vmagent.yml ]]; then
        if grep -q "pro.nftban.com" /etc/victoriametrics/vmagent.yml 2>/dev/null; then
            systemctl enable vmagent 2>/dev/null || true
            systemctl start vmagent 2>/dev/null || true
            echo "INFO: Enabled vmagent (Pro remote_write)"
        fi
    fi

    # Mark Pro as enabled (polkit-aware refusal instead of a raw write leak)
    mkdir -p "$NFTBAN_PRO_DATA_DIR" 2>/dev/null || true
    if [[ $EUID -ne 0 && ! -w "$NFTBAN_PRO_DATA_DIR" ]]; then
        echo "ERROR: PolicyKit/polkit authorization failed or insufficient privileges (update Pro status)" >&2
        return 1
    fi
    printf '{"enabled": true, "enabled_at": "%s"}\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$NFTBAN_PRO_DATA_DIR/status.json"
}

# =============================================================================
# LICENSE TIMER (for systemd timer)
# =============================================================================

nftban_pro_license_check_timer() {
    # Called by license timer to check and enforce subscription status
    # This is the main entry point for the license timer service

    echo "$(date '+%Y-%m-%d %H:%M:%S') Checking Pro license..."

    if nftban_pro_is_enabled; then
        echo "License valid - Pro features enabled"
        nftban_pro_enable_remote
        # NOTE: Inventory submission handled by nftban-pro-inventory.timer (daily)
        # Removed duplicate call here to avoid redundant execution (v1.46.0)
    else
        echo "License invalid - disabling Pro features"
        nftban_pro_disable_remote
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

# =============================================================================
# COMMUNITY STATS (v1.41.0 — anonymous usage stats, opt-in only)
# =============================================================================

NFTBAN_COMMUNITY_CONF="/etc/nftban/conf.d/community_stats.conf"

nftban_pro_cmd_community() {
    local action="${1:-help}"
    shift || true

    case "$action" in
        enable)  nftban_community_enable ;;
        disable) nftban_community_disable ;;
        show)    nftban_community_show ;;
        status)  nftban_community_status ;;
        submit)  nftban_community_submit ;;
        help|--help|-h)
            echo "Usage: nftban pro community {enable|disable|show|status|submit}"
            echo ""
            echo "  enable   - Opt in to anonymous community stats"
            echo "  disable  - Opt out of community stats"
            echo "  show     - Display exact JSON payload (verify no PII)"
            echo "  status   - Show current state and timer info"
            echo "  submit   - Manually submit stats now"
            ;;
        *)
            echo "ERROR: Unknown community action: $action" >&2
            return 1
            ;;
    esac
}

nftban_community_enable() {
    # Create config from default if not exists
    if [[ ! -f "$NFTBAN_COMMUNITY_CONF" ]]; then
        local default_conf="/usr/lib/nftban/install/config/conf.d/community_stats.conf.default"
        if [[ -f "$default_conf" ]]; then
            cp "$default_conf" "$NFTBAN_COMMUNITY_CONF"
        else
            # Create minimal config
            cat > "$NFTBAN_COMMUNITY_CONF" <<'CONFEOF'
COMMUNITY_STATS_ENABLED=yes
COMMUNITY_STATS_ID=""
COMMUNITY_STATS_URL="https://stats.nftban.com/api/v1/community"
CONFEOF
        fi
    fi

    # Generate UUID if not set
    local current_id
    current_id=$(grep -oP 'COMMUNITY_STATS_ID="\K[^"]+' "$NFTBAN_COMMUNITY_CONF" 2>/dev/null || true)
    if [[ -z "$current_id" ]]; then
        local new_id
        new_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || head -c 16 /dev/urandom | xxd -p)
        sed -i "s|COMMUNITY_STATS_ID=\"\"|COMMUNITY_STATS_ID=\"$new_id\"|" "$NFTBAN_COMMUNITY_CONF"
    fi

    # Set enabled
    sed -i 's|COMMUNITY_STATS_ENABLED=.*|COMMUNITY_STATS_ENABLED=yes|' "$NFTBAN_COMMUNITY_CONF"

    # Enable systemd timer if available
    if systemctl list-unit-files nftban-community-stats.timer &>/dev/null; then
        systemctl enable --now nftban-community-stats.timer 2>/dev/null || true
    fi

    echo "Community stats ENABLED."
    echo "Run 'nftban pro community show' to see the exact data being sent."
    echo "Run 'nftban pro community disable' to opt out at any time."
}

nftban_community_disable() {
    if [[ -f "$NFTBAN_COMMUNITY_CONF" ]]; then
        sed -i 's|COMMUNITY_STATS_ENABLED=.*|COMMUNITY_STATS_ENABLED=no|' "$NFTBAN_COMMUNITY_CONF"
    fi

    # Disable timer
    systemctl disable --now nftban-community-stats.timer 2>/dev/null || true

    echo "Community stats DISABLED. No data will be sent."
}

nftban_community_show() {
    echo "Community Stats Payload (this is exactly what gets sent):"
    echo "========================================================="
    nftban_community_build_payload
    echo ""
    echo "NOTE: No hostname, IP addresses, logs, or PII included."
}

nftban_community_status() {
    echo "Community Stats Status:"
    echo "======================="

    if [[ ! -f "$NFTBAN_COMMUNITY_CONF" ]]; then
        echo "  Config:  not configured"
        echo "  Status:  disabled (never enabled)"
        return 0
    fi

    # shellcheck source=/dev/null
    source "$NFTBAN_COMMUNITY_CONF" 2>/dev/null || true

    echo "  Enabled: ${COMMUNITY_STATS_ENABLED:-no}"
    echo "  ID:      ${COMMUNITY_STATS_ID:-not set}"
    echo "  URL:     ${COMMUNITY_STATS_URL:-not set}"

    # Timer status
    if systemctl list-unit-files nftban-community-stats.timer &>/dev/null 2>&1; then
        local timer_state
        timer_state=$(systemctl is-enabled nftban-community-stats.timer 2>/dev/null || echo "not-found")
        local timer_active
        timer_active=$(systemctl is-active nftban-community-stats.timer 2>/dev/null || echo "inactive")
        echo "  Timer:   enabled=$timer_state active=$timer_active"
    else
        echo "  Timer:   not installed"
    fi
}

nftban_community_build_payload() {
    # Build the JSON payload with ONLY non-identifying data
    local os_name os_version nftban_version cpu_bucket ram_bucket panel modules health

    # OS info (generic, not hostname)
    os_name=$(. /etc/os-release 2>/dev/null && echo "${ID:-unknown}" || echo "unknown")
    os_version=$(. /etc/os-release 2>/dev/null && echo "${VERSION_ID:-unknown}" || echo "unknown")

    # NFTBan version — fallback chain to avoid "unknown"
    nftban_version=""
    # 1. Canonical VERSION file
    [[ -z "$nftban_version" ]] && nftban_version=$(cat /usr/lib/nftban/VERSION 2>/dev/null | tr -d '\n')
    # 2. Root VERSION file
    [[ -z "$nftban_version" ]] && nftban_version=$(cat /VERSION 2>/dev/null | tr -d '\n')
    # 3. Package metadata (RPM)
    [[ -z "$nftban_version" ]] && nftban_version=$(rpm -q --queryformat '%{VERSION}' nftban-core 2>/dev/null)
    # 4. Package metadata (DEB)
    [[ -z "$nftban_version" ]] && nftban_version=$(dpkg-query -W -f '${Version}' nftban-core 2>/dev/null | cut -d- -f1)
    # 5. Last resort
    [[ -z "$nftban_version" ]] && nftban_version="unknown"

    # Bucketed CPU (not exact — privacy-preserving)
    local cpu_count
    cpu_count=$(nproc 2>/dev/null || echo "0")
    if [[ "$cpu_count" -le 1 ]]; then cpu_bucket="1"
    elif [[ "$cpu_count" -le 2 ]]; then cpu_bucket="2"
    elif [[ "$cpu_count" -le 4 ]]; then cpu_bucket="2-4"
    elif [[ "$cpu_count" -le 8 ]]; then cpu_bucket="4-8"
    elif [[ "$cpu_count" -le 16 ]]; then cpu_bucket="8-16"
    else cpu_bucket="16+"
    fi

    # Bucketed RAM (not exact)
    local ram_mb
    ram_mb=$(awk '/MemTotal/ { printf "%d", $2/1024 }' /proc/meminfo 2>/dev/null || echo "0")
    if [[ "$ram_mb" -le 1024 ]]; then ram_bucket="<=1GB"
    elif [[ "$ram_mb" -le 2048 ]]; then ram_bucket="1-2GB"
    elif [[ "$ram_mb" -le 4096 ]]; then ram_bucket="2-4GB"
    elif [[ "$ram_mb" -le 8192 ]]; then ram_bucket="4-8GB"
    elif [[ "$ram_mb" -le 16384 ]]; then ram_bucket="8-16GB"
    elif [[ "$ram_mb" -le 32768 ]]; then ram_bucket="16-32GB"
    else ram_bucket="32GB+"
    fi

    # Panel type
    panel="none"
    [[ -d /usr/local/cpanel ]] && panel="cpanel"
    [[ -d /usr/local/psa ]] && panel="plesk"
    [[ -d /usr/local/directadmin ]] && panel="directadmin"

    # Enabled modules (just names, no config)
    modules=$(nftban status --brief 2>/dev/null | grep -oP 'modules:\K.*' || echo "")
    modules="${modules## }"

    # Health status (just ok/warn/error) — legacy field, retained for compat
    health=$(nftban health check --brief 2>/dev/null | head -1 || echo "unknown")

    # Protection state — authoritative, from validator (kernel truth)
    # INVARIANT: health_state is the KERNEL protection verdict, NOT the
    # community enrollment state. These are separate axes:
    #   health_state = PROTECTED | IDLE | DEGRADED | DOWN  (kernel truth)
    #   community    = ENABLED | DISABLED | ERROR          (enrollment status)
    # They MUST NOT be conflated or derived from each other.
    local health_state
    health_state=$(/usr/lib/nftban/bin/nftban-validate --json 2>/dev/null | jq -r '.status // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
    # Normalize to UPPERCASE (canonical — prevents PROTECTED vs protected mismatch)
    health_state=$(echo "$health_state" | tr '[:lower:]' '[:upper:]')

    # Installation ID
    local install_id=""
    if [[ -f "$NFTBAN_COMMUNITY_CONF" ]]; then
        install_id=$(grep -oP 'COMMUNITY_STATS_ID="\K[^"]+' "$NFTBAN_COMMUNITY_CONF" 2>/dev/null || true)
    fi

    # Architecture type
    local arch
    arch=$(uname -m 2>/dev/null || echo "unknown")

    # Package type (deb or rpm)
    local package_type="unknown"
    if command -v dpkg >/dev/null 2>&1 && dpkg -l nftban-core >/dev/null 2>&1; then
        package_type="deb"
    elif command -v rpm >/dev/null 2>&1 && rpm -q nftban-core >/dev/null 2>&1; then
        package_type="rpm"
    fi

    # Server node_id — reuse existing anonymous stable ID (nftban_pro.sh)
    local node_id
    node_id=$(nftban_pro_get_server_id 2>/dev/null || echo "unknown")

    # Output JSON — canonical payload structure
    # INVARIANT: health_state is the kernel protection verdict from the validator.
    # It is NOT the community enrollment state. See state-separation invariant.
    cat <<JSONEOF
{
  "schema_version": 2,
  "node_id": "$node_id",
  "install_id": "$install_id",
  "nftban_version": "$nftban_version",
  "os": "$os_name",
  "os_version": "$os_version",
  "arch": "$arch",
  "package_type": "$package_type",
  "cpu_bucket": "$cpu_bucket",
  "ram_bucket": "$ram_bucket",
  "panel": "$panel",
  "modules": "$modules",
  "health": "$health",
  "health_state": "$health_state",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSONEOF
}

nftban_community_submit() {
    # Read config
    if [[ ! -f "$NFTBAN_COMMUNITY_CONF" ]]; then
        echo "ERROR: Community stats not configured. Run 'nftban pro community enable' first." >&2
        return 1
    fi

    # shellcheck source=/dev/null
    source "$NFTBAN_COMMUNITY_CONF" 2>/dev/null || true

    if [[ "${COMMUNITY_STATS_ENABLED:-no}" != "yes" ]]; then
        echo "Community stats disabled. Enable with 'nftban pro community enable'."
        return 0
    fi

    local url="${COMMUNITY_STATS_URL:-https://stats.nftban.com/api/v1/community}"
    local payload
    payload=$(nftban_community_build_payload)

    echo "Submitting anonymous community stats..."
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --connect-timeout 10 \
        --max-time 30 \
        "$url" 2>/dev/null) || http_code="000"

    case "$http_code" in
        200|201|204)
            echo "Stats submitted successfully."
            return 0
            ;;
        000)
            echo "WARNING: Could not reach stats server (offline or network error)." >&2
            return 1
            ;;
        *)
            echo "WARNING: Stats submission returned HTTP $http_code." >&2
            return 1
            ;;
    esac
}

# =============================================================================
# INSTALL RESULT EVENT (Task 1 — default, minimal, fire-and-forget)
# =============================================================================
# Sends ONE anonymous install_result event after install or first validation.
# Reuses existing server_id, existing curl pattern, existing API endpoint.
#
# INVARIANT: this is a MINIMAL signal. It does NOT require enrollment.
# It does NOT send if the marker file already exists (one-time only).
# It MUST NOT block the installer. Failure is silent.
#
# STATE SEPARATION: health_state here is the kernel protection verdict,
# NOT the community enrollment state. These are independent axes.

: "${NFTBAN_INSTALL_RESULT_MARKER:=${NFTBAN_PRO_DATA_DIR}/install_result_sent}"
: "${NFTBAN_INSTALL_RESULT_URL:=https://pro.nftban.com/api/v1/install-result}"

nftban_send_install_result() {
    # Skip if already sent (one-time only)
    if [[ -f "$NFTBAN_INSTALL_RESULT_MARKER" ]]; then
        return 0
    fi

    # Ensure data directory exists
    mkdir -p "$NFTBAN_PRO_DATA_DIR" 2>/dev/null || return 0

    # Collect minimal anonymous data — reusing existing functions
    local node_id version distro arch package_type health_state

    node_id=$(nftban_pro_ensure_server_id 2>/dev/null || echo "unknown")
    # Version fallback chain (same as community payload)
    local version=""
    [[ -z "$version" ]] && version=$(cat /usr/lib/nftban/VERSION 2>/dev/null | tr -d '\n')
    [[ -z "$version" ]] && version=$(cat /VERSION 2>/dev/null | tr -d '\n')
    [[ -z "$version" ]] && version=$(rpm -q --queryformat '%{VERSION}' nftban-core 2>/dev/null)
    [[ -z "$version" ]] && version=$(dpkg-query -W -f '${Version}' nftban-core 2>/dev/null | cut -d- -f1)
    [[ -z "$version" ]] && version="unknown"
    distro=$(. /etc/os-release 2>/dev/null && echo "${ID:-unknown}-${VERSION_ID:-}" || echo "unknown")
    arch=$(uname -m 2>/dev/null || echo "unknown")

    package_type="unknown"
    if command -v dpkg >/dev/null 2>&1 && dpkg -l nftban-core >/dev/null 2>&1; then
        package_type="deb"
    elif command -v rpm >/dev/null 2>&1 && rpm -q nftban-core >/dev/null 2>&1; then
        package_type="rpm"
    fi

    health_state=$(/usr/lib/nftban/bin/nftban-validate --json 2>/dev/null | jq -r '.status // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")
    # Normalize to UPPERCASE (canonical — prevents PROTECTED vs protected mismatch)
    health_state=$(echo "$health_state" | tr '[:lower:]' '[:upper:]')

    # Build minimal payload — STRICTLY limited fields
    local payload
    payload=$(cat <<JSONEOF
{
  "event": "install_result",
  "node_id": "$node_id",
  "version": "$version",
  "distro": "$distro",
  "arch": "$arch",
  "package_type": "$package_type",
  "health_state": "$health_state",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSONEOF
)

    # Fire-and-forget — DO NOT block installer, DO NOT retry
    # Reuses same curl pattern as nftban_community_submit
    curl -s -o /dev/null \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --connect-timeout 5 \
        --max-time 10 \
        "$NFTBAN_INSTALL_RESULT_URL" 2>/dev/null || true

    # Mark as sent (even if curl failed — don't spam on repeated installs)
    touch "$NFTBAN_INSTALL_RESULT_MARKER" 2>/dev/null || true
}

export -f nftban_send_install_result

export -f nftban_pro_cmd_community
export -f nftban_community_enable
export -f nftban_community_disable
export -f nftban_community_show
export -f nftban_community_status
export -f nftban_community_build_payload
export -f nftban_community_submit

export -f nftban_pro_ensure_server_id
export -f nftban_pro_get_server_id
export -f nftban_pro_collect_inventory
export -f nftban_pro_save_inventory
export -f nftban_pro_inventory_changed
export -f nftban_pro_submit_inventory
export -f nftban_pro_check_license
export -f nftban_pro_is_enabled
export -f nftban_pro_disable_remote
export -f nftban_pro_enable_remote
export -f nftban_pro_license_check_timer

# Export paths
export NFTBAN_PRO_TOKEN_FILE
export NFTBAN_PRO_SERVER_ID_FILE
export NFTBAN_PRO_DATA_DIR
export NFTBAN_PRO_INVENTORY_FILE
export NFTBAN_PRO_REMOTE_WRITE_URL
export NFTBAN_PRO_INVENTORY_URL
