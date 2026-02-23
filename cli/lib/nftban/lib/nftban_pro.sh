#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_pro" meta:type="lib" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Manages NFTBan Pro subscription, inventory, and license"
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
    source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"
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
        mkdir -p "$(dirname "$NFTBAN_PRO_SERVER_ID_FILE")"

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

    mkdir -p "$NFTBAN_PRO_DATA_DIR"
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
    _pro_tmp_response=$(mktemp /tmp/nftban_pro_XXXXXX)
    trap 'rm -f "$_pro_tmp_response"' RETURN

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
    _pro_tmp_license=$(mktemp /tmp/nftban_pro_XXXXXX)
    trap 'rm -f "$_pro_tmp_license"' RETURN

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

    # Mark Pro as disabled
    mkdir -p "$NFTBAN_PRO_DATA_DIR"
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

    # Mark Pro as enabled
    mkdir -p "$NFTBAN_PRO_DATA_DIR"
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

        # Submit inventory if changed
        nftban_pro_submit_inventory false
    else
        echo "License invalid - disabling Pro features"
        nftban_pro_disable_remote
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

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
