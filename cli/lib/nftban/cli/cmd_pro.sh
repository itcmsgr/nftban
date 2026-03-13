#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Pro Subscription CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Manage NFTBan Pro subscription, enrollment, and inventory
#
# meta:name="cmd_pro"
# meta:type="cli"
# meta:header="Pro Subscription CLI Handler"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI interface for NFTBan Pro subscription management"
# meta:inventory.files=""
# meta:inventory.binaries="curl"
# meta:inventory.env_vars="NFTBAN_PRO_TOKEN"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network="https://api.nftban.com"
# meta:inventory.privileges="nftban"
#
# meta:created_date="2026-01-08"
# meta:updated_date="2026-01-08"
# =============================================================================

set -Eeuo pipefail

# Bootstrap paths (nftban.conf will make them readonly)
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"

# Load main config (sets readonly paths)
if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_CONFIG_DIR}/nftban.conf" || true
fi

# Load Pro library
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_pro.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/lib/nftban_pro.sh" || return 1
fi

# Load pipeline validation
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_pipeline_validation.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/lib/nftban_pipeline_validation.sh" || return 1
fi

# =============================================================================
# CONSTANTS (configurable via nftban.conf)
# =============================================================================

: "${NFTBAN_PRO_TOKEN_FILE:=/etc/nftban/pro.token}"
: "${NFTBAN_PRO_SERVER_ID_FILE:=/etc/nftban/server_id}"
: "${NFTBAN_PRO_DATA_DIR:=/var/lib/nftban/pro}"
: "${NFTBAN_PRO_REMOTE_WRITE_URL:=https://pro.nftban.com/api/v1/write}"
: "${NFTBAN_PRO_INVENTORY_URL:=https://pro.nftban.com/api/v1/inventory}"
: "${NFTBAN_PRO_STATUS_URL:=https://pro.nftban.com/api/v1/enroll/status}"
: "${NFTBAN_PRO_TIMEOUT:=30}"

# =============================================================================
# TOKEN SECURITY FUNCTIONS
# =============================================================================

_pro_check_token_permissions() {
    # Check token file has secure permissions
    # Returns: 0 if secure, 1 if insecure

    local token_file="${1:-$NFTBAN_PRO_TOKEN_FILE}"

    if [[ ! -f "$token_file" ]]; then
        return 1
    fi

    # Check owner is root
    local owner
    owner=$(stat -c '%U' "$token_file" 2>/dev/null || echo "unknown")
    if [[ "$owner" != "root" ]]; then
        echo "ERROR: Token file must be owned by root (current: $owner)" >&2
        return 1
    fi

    # Check permissions are 0600 or 0640
    local perms
    perms=$(stat -c '%a' "$token_file" 2>/dev/null || echo "777")
    if [[ "$perms" != "600" ]] && [[ "$perms" != "640" ]]; then
        echo "ERROR: Token file must have mode 0600 or 0640 (current: $perms)" >&2
        echo "       World-readable tokens are a security risk." >&2
        echo "       Fix: chmod 600 $token_file" >&2
        return 1
    fi

    return 0
}

_pro_write_token_secure() {
    # Write token to file with secure permissions
    # Args: $1 = token value, $2 = optional file path

    local token="$1"
    local token_file="${2:-$NFTBAN_PRO_TOKEN_FILE}"

    # Validate token is not empty
    if [[ -z "$token" ]]; then
        echo "ERROR: Token cannot be empty" >&2
        return 1
    fi

    # Create directory if missing (atomic, avoids TOCTOU race)
    local token_dir
    token_dir=$(dirname "$token_file")
    mkdir -p "$token_dir" 2>/dev/null || true
    chmod 755 "$token_dir" 2>/dev/null || true

    # Write token atomically with secure permissions
    local tmp_file="${token_file}.tmp.$$"

    # Set umask to ensure secure permissions
    (
        umask 077
        echo -n "$token" > "$tmp_file"
    )

    # Set ownership and permissions
    chown root:nftban "$tmp_file" 2>/dev/null || chown root:root "$tmp_file"
    chmod 640 "$tmp_file"

    # Atomic move
    mv "$tmp_file" "$token_file"

    return 0
}

# =============================================================================
# ENROLL COMMAND
# =============================================================================

nftban_pro_cmd_enroll() {
    # Enroll server with NFTBan Pro
    #
    # Usage:
    #   nftban pro enroll                    # Interactive prompt
    #   nftban pro enroll --token-file PATH  # Copy from file
    #   nftban pro enroll --token VALUE      # Direct (not recommended)

    local token=""
    local token_file=""
    # shellcheck disable=SC2034  # Reserved for future env token support
    local _from_env=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --token)
                token="$2"
                shift 2
                ;;
            --token-file)
                token_file="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Pro Enrollment"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check for existing token
    if [[ -f "$NFTBAN_PRO_TOKEN_FILE" ]]; then
        echo "  Note: Existing token found at $NFTBAN_PRO_TOKEN_FILE"
        echo "        This will be replaced."
        echo ""
    fi

    # Get token from various sources
    if [[ -n "$token" ]]; then
        # Direct token (warn about shell history)
        echo "  WARNING: Using --token stores the token in shell history."
        echo "           Consider using --token-file or interactive mode instead."
        echo ""
    elif [[ -n "$token_file" ]]; then
        # Read from file
        if [[ ! -f "$token_file" ]]; then
            echo "  ERROR: Token file not found: $token_file"
            return 1
        fi
        token=$(cat "$token_file" | tr -d '\n\r')
        echo "  Reading token from: $token_file"
    elif [[ -n "${NFTBAN_PRO_TOKEN:-}" ]]; then
        # From environment variable
        token="$NFTBAN_PRO_TOKEN"
        echo "  Using token from NFTBAN_PRO_TOKEN environment variable"
    else
        # Interactive prompt (hidden input)
        echo "  Enter your Pro token (hidden input):"
        echo "  Get your token at: https://pro.nftban.com"
        echo ""
        read -rsp "  Token: " token
        echo ""

        if [[ -z "$token" ]]; then
            echo ""
            echo "  ERROR: No token provided"
            return 1
        fi
    fi

    # Validate token format (basic sanity check)
    if [[ ${#token} -lt 20 ]]; then
        echo ""
        echo "  ERROR: Token appears too short. Please check your token."
        return 1
    fi

    # Ensure server_id exists
    echo ""
    echo "  Ensuring server identity..."
    local server_id
    server_id=$(nftban_pro_ensure_server_id)
    echo "    Server ID: $server_id"

    # Write token securely
    echo ""
    echo "  Writing token..."
    if ! _pro_write_token_secure "$token"; then
        echo "  ERROR: Failed to write token"
        return 1
    fi
    echo "    Saved to: $NFTBAN_PRO_TOKEN_FILE (mode 0640)"

    # Validate token against Pro endpoint
    echo ""
    echo "  Validating token with pro.nftban.com..."

    # v1.19.0: Use mktemp instead of predictable PID-based temp files (R17)
    local http_code
    local response_file
    response_file=$(mktemp "${NFTBAN_RUN_DIR:-/run/nftban}/nftban_pro_XXXXXX")
    trap 'rm -f "$response_file"' RETURN

    http_code=$(curl -sf --connect-timeout "$NFTBAN_PRO_TIMEOUT" \
        -H "Authorization: Bearer $token" \
        -w "%{http_code}" \
        -o "$response_file" \
        "${NFTBAN_PRO_STATUS_URL}?server_id=${server_id}" 2>/dev/null || echo "000")

    local response=""
    [[ -f "$response_file" ]] && response=$(cat "$response_file")
    rm -f "$response_file"

    echo ""
    case "$http_code" in
        200)
            # Parse response
            local plan status expires_at
            plan=$(echo "$response" | jq -r '.plan // "unknown"' 2>/dev/null || echo "unknown")
            status=$(echo "$response" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
            expires_at=$(echo "$response" | jq -r '.expires_at // "unknown"' 2>/dev/null || echo "unknown")

            # Save license info
            mkdir -p "$NFTBAN_PRO_DATA_DIR" || return 1
            echo "$response" > "$NFTBAN_PRO_DATA_DIR/license.json"
            chmod 640 "$NFTBAN_PRO_DATA_DIR/license.json"

            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Enrollment Successful"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "    Status:     $status"
            echo "    Plan:       $plan"
            echo "    Expires:    $expires_at"
            echo "    Server ID:  $server_id"
            echo ""
            echo "  Next steps:"
            echo "    nftban metrics enable --pro    # Enable metrics streaming"
            echo "    nftban pro status              # Check subscription status"
            echo ""
            ;;
        401)
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Enrollment Failed: Invalid Token (401)"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "    The token was rejected. Please check:"
            echo "    - Token was copied correctly (no extra spaces)"
            echo "    - Token has not been revoked"
            echo "    - Token is for the correct account"
            echo ""
            echo "    Get a new token at: https://pro.nftban.com"
            echo ""
            # Remove invalid token
            rm -f "$NFTBAN_PRO_TOKEN_FILE"
            return 1
            ;;
        402|403)
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Enrollment: Subscription Inactive ($http_code)"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "    Token is valid but subscription is inactive."
            echo "    Reason: $(echo "$response" | jq -r '.reason // "payment required"' 2>/dev/null)"
            echo ""
            echo "    Renew at: https://pro.nftban.com/billing"
            echo ""
            echo "    Token saved for when subscription is renewed."
            echo ""
            return 1
            ;;
        000)
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Enrollment: Network Error"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "    Could not reach pro.nftban.com"
            echo ""
            echo "    Token saved locally. Validation will retry when Pro is enabled."
            echo "    You can proceed with: nftban metrics enable --pro"
            echo ""
            ;;
        *)
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "  Enrollment: Unexpected Error (HTTP $http_code)"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "    Please try again later or contact support."
            echo ""
            return 1
            ;;
    esac

    return 0
}

# =============================================================================
# STATUS COMMAND
# =============================================================================

nftban_pro_cmd_status() {
    # Show Pro subscription status

    local json_mode=false
    local refresh=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) json_mode=true; shift ;;
            --refresh) refresh=true; shift ;;
            *) shift ;;
        esac
    done

    # Check if Pro is configured
    local pro_enabled=false
    local token_exists=false
    local token_valid=false
    local license_status="unknown"
    local license_plan="unknown"
    local license_expires="unknown"
    local server_id=""
    local vmagent_running=false
    local inventory_last=""

    # Check token
    if [[ -f "$NFTBAN_PRO_TOKEN_FILE" ]]; then
        token_exists=true
        if _pro_check_token_permissions "$NFTBAN_PRO_TOKEN_FILE" 2>/dev/null; then
            token_valid=true
        fi
    fi

    # Check server ID
    if [[ -f "$NFTBAN_PRO_SERVER_ID_FILE" ]]; then
        server_id=$(cat "$NFTBAN_PRO_SERVER_ID_FILE" 2>/dev/null | tr -d '\n')
    fi

    # Check cached license
    if [[ -f "$NFTBAN_PRO_DATA_DIR/license.json" ]]; then
        license_status=$(jq -r '.status // "unknown"' "$NFTBAN_PRO_DATA_DIR/license.json" 2>/dev/null || echo "unknown")
        license_plan=$(jq -r '.plan // "unknown"' "$NFTBAN_PRO_DATA_DIR/license.json" 2>/dev/null || echo "unknown")
        license_expires=$(jq -r '.expires_at // "unknown"' "$NFTBAN_PRO_DATA_DIR/license.json" 2>/dev/null || echo "unknown")
    fi

    # Refresh from API if requested
    if [[ "$refresh" == "true" ]] && [[ "$token_exists" == "true" ]]; then
        nftban_pro_check_license >/dev/null 2>&1
        if [[ -f "$NFTBAN_PRO_DATA_DIR/license.json" ]]; then
            license_status=$(jq -r '.status // "unknown"' "$NFTBAN_PRO_DATA_DIR/license.json" 2>/dev/null || echo "unknown")
            license_plan=$(jq -r '.plan // "unknown"' "$NFTBAN_PRO_DATA_DIR/license.json" 2>/dev/null || echo "unknown")
            license_expires=$(jq -r '.expires_at // "unknown"' "$NFTBAN_PRO_DATA_DIR/license.json" 2>/dev/null || echo "unknown")
        fi
    fi

    # Check vmagent
    if systemctl is-active vmagent &>/dev/null; then
        vmagent_running=true
    fi

    # Check last inventory
    if [[ -f "$NFTBAN_PRO_DATA_DIR/last_submit.json" ]]; then
        inventory_last=$(jq -r '.submitted_at // "never"' "$NFTBAN_PRO_DATA_DIR/last_submit.json" 2>/dev/null || echo "never")
    fi

    # Determine overall Pro status
    if [[ "$token_exists" == "true" ]] && [[ "$license_status" == "active" ]]; then
        pro_enabled=true
    fi

    if [[ "$json_mode" == "true" ]]; then
        cat << EOF
{
  "pro_enabled": $pro_enabled,
  "token": {
    "exists": $token_exists,
    "valid_permissions": $token_valid,
    "path": "$NFTBAN_PRO_TOKEN_FILE"
  },
  "license": {
    "status": "$license_status",
    "plan": "$license_plan",
    "expires_at": "$license_expires"
  },
  "server_id": "$server_id",
  "vmagent_running": $vmagent_running,
  "inventory_last_submit": "$inventory_last"
}
EOF
        return 0
    fi

    # Text output
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Pro Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Overall status
    if [[ "$pro_enabled" == "true" ]]; then
        echo "  Status: ACTIVE"
    elif [[ "$token_exists" == "true" ]]; then
        echo "  Status: CONFIGURED (subscription ${license_status})"
    else
        echo "  Status: NOT ENROLLED"
    fi
    echo ""

    # Token
    echo "  Token:"
    if [[ "$token_exists" == "true" ]]; then
        echo "    File:        $NFTBAN_PRO_TOKEN_FILE"
        if [[ "$token_valid" == "true" ]]; then
            echo "    Permissions: OK (secure)"
        else
            echo "    Permissions: INSECURE (fix with: chmod 640 $NFTBAN_PRO_TOKEN_FILE)"
        fi
    else
        echo "    Not installed"
        echo "    Enroll with: nftban pro enroll"
    fi
    echo ""

    # License
    echo "  Subscription:"
    echo "    Status:  $license_status"
    echo "    Plan:    $license_plan"
    echo "    Expires: $license_expires"
    echo ""

    # Server
    echo "  Server:"
    echo "    ID:      ${server_id:-not generated}"
    echo ""

    # Services
    echo "  Services:"
    if [[ "$vmagent_running" == "true" ]]; then
        echo "    vmagent: Running"
    else
        echo "    vmagent: Stopped"
    fi

    if systemctl is-active nftban-pro-license.timer &>/dev/null; then
        echo "    License Timer: Running"
    else
        echo "    License Timer: Stopped"
    fi

    if systemctl is-active nftban-pro-inventory.timer &>/dev/null; then
        echo "    Inventory Timer: Running"
    else
        echo "    Inventory Timer: Stopped"
    fi
    echo ""

    # Inventory
    echo "  Inventory:"
    echo "    Last Submit: ${inventory_last:-never}"
    if [[ -f "$NFTBAN_PRO_DATA_DIR/inventory.sha256" ]]; then
        local hash
        hash=$(cat "$NFTBAN_PRO_DATA_DIR/inventory.sha256" 2>/dev/null | head -c 16)
        echo "    Checksum:    ${hash}..."
    fi
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# =============================================================================
# DISABLE COMMAND
# =============================================================================

nftban_pro_cmd_disable() {
    # Disable Pro features (keeps token, stops remote submission)

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Disabling NFTBan Pro"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Stop vmagent if configured for Pro
    if [[ -f /etc/victoriametrics/vmagent.yml ]]; then
        if grep -q "pro.nftban.com" /etc/victoriametrics/vmagent.yml 2>/dev/null; then
            echo "  Stopping vmagent (Pro remote_write)..."
            systemctl stop vmagent 2>/dev/null || true
            systemctl disable vmagent 2>/dev/null || true
            echo "    Done"
        fi
    fi

    # Stop timers
    echo "  Stopping Pro timers..."
    systemctl stop nftban-pro-license.timer 2>/dev/null || true
    systemctl disable nftban-pro-license.timer 2>/dev/null || true
    systemctl stop nftban-pro-inventory.timer 2>/dev/null || true
    systemctl disable nftban-pro-inventory.timer 2>/dev/null || true
    echo "    Done"

    # Update status
    mkdir -p "$NFTBAN_PRO_DATA_DIR" || return 1
    cat > "$NFTBAN_PRO_DATA_DIR/status.json" << EOF
{
  "enabled": false,
  "reason": "user_disabled",
  "disabled_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

    echo ""
    echo "  Pro features disabled."
    echo ""
    echo "  Note: Token kept at $NFTBAN_PRO_TOKEN_FILE"
    echo "        Re-enable with: nftban metrics enable --pro"
    echo "        Remove token with: nftban pro token revoke"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# =============================================================================
# TOKEN MANAGEMENT COMMANDS
# =============================================================================

nftban_pro_cmd_token() {
    # Token management subcommands
    local action="${1:-}"
    shift || true

    case "$action" in
        rotate)
            nftban_pro_cmd_token_rotate "$@"
            ;;
        revoke)
            nftban_pro_cmd_token_revoke "$@"
            ;;
        check)
            nftban_pro_cmd_token_check "$@"
            ;;
        *)
            echo "Usage: nftban pro token {rotate|revoke|check}"
            echo ""
            echo "Commands:"
            echo "  rotate    Replace token with new one"
            echo "  revoke    Remove token and disable Pro"
            echo "  check     Verify token permissions and validity"
            return 1
            ;;
    esac
}

nftban_pro_cmd_token_rotate() {
    # Rotate token (replace with new one)

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Token Rotation"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  To rotate your token:"
    echo ""
    echo "  1. Generate a new token in the Pro portal:"
    echo "     https://pro.nftban.com/settings/tokens"
    echo ""
    echo "  2. Install the new token:"
    echo "     nftban pro enroll --token-file /path/to/new/token"
    echo ""
    echo "  3. The old token will be replaced automatically."
    echo ""
    echo "  4. Optionally revoke the old token in the portal."
    echo ""

    # Offer to start enrollment
    echo "  Start enrollment now? (Enter new token):"
    nftban_pro_cmd_enroll
}

nftban_pro_cmd_token_revoke() {
    # Revoke token (remove locally and disable Pro)

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Token Revocation"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [[ ! -f "$NFTBAN_PRO_TOKEN_FILE" ]]; then
        echo "  No token file found."
        return 0
    fi

    echo "  This will:"
    echo "    - Remove the local token file"
    echo "    - Disable Pro remote submission"
    echo "    - Keep local metrics and watchdog running"
    echo ""
    echo "  NOTE: To fully revoke the token, also revoke it in the Pro portal."
    echo ""

    read -rp "  Proceed? [y/N]: " confirm
    if [[ "$confirm" != "y" ]] && [[ "$confirm" != "Y" ]]; then
        echo "  Cancelled."
        return 0
    fi

    # Disable Pro first
    nftban_pro_cmd_disable

    # Remove token
    echo "  Removing token file..."
    rm -f "$NFTBAN_PRO_TOKEN_FILE"
    echo "    Done"

    # Remove license cache
    rm -f "$NFTBAN_PRO_DATA_DIR/license.json"

    echo ""
    echo "  Token revoked locally."
    echo "  Remember to also revoke in portal: https://pro.nftban.com/settings/tokens"
    echo ""
}

nftban_pro_cmd_token_check() {
    # Check token permissions and validity

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Token Check"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [[ ! -f "$NFTBAN_PRO_TOKEN_FILE" ]]; then
        echo "  Token file: NOT FOUND"
        echo "  Enroll with: nftban pro enroll"
        return 1
    fi

    echo "  Token file: $NFTBAN_PRO_TOKEN_FILE"

    # Check permissions
    local owner perms
    owner=$(stat -c '%U:%G' "$NFTBAN_PRO_TOKEN_FILE" 2>/dev/null || echo "unknown")
    perms=$(stat -c '%a' "$NFTBAN_PRO_TOKEN_FILE" 2>/dev/null || echo "unknown")

    echo "  Owner:       $owner"
    echo "  Permissions: $perms"

    if _pro_check_token_permissions "$NFTBAN_PRO_TOKEN_FILE" 2>/dev/null; then
        echo "  Security:    OK"
    else
        echo "  Security:    INSECURE"
        echo ""
        echo "  Fix with:"
        echo "    chown root:nftban $NFTBAN_PRO_TOKEN_FILE"
        echo "    chmod 640 $NFTBAN_PRO_TOKEN_FILE"
        return 1
    fi

    # Check validity
    echo ""
    echo "  Validating with pro.nftban.com..."
    if nftban_pro_check_license; then
        echo "  Validity:    OK"
    else
        echo "  Validity:    FAILED or EXPIRED"
    fi

    echo ""
}

# =============================================================================
# INVENTORY COMMAND
# =============================================================================

nftban_pro_cmd_inventory() {
    # Inventory management subcommands
    local action="${1:-show}"
    shift || true

    case "$action" in
        show)
            nftban_pro_cmd_inventory_show "$@"
            ;;
        run)
            nftban_pro_cmd_inventory_run "$@"
            ;;
        submit)
            nftban_pro_cmd_inventory_submit "$@"
            ;;
        *)
            echo "Usage: nftban pro inventory {show|run|submit}"
            echo ""
            echo "Commands:"
            echo "  show      Display current inventory"
            echo "  run       Collect and submit inventory (if changed)"
            echo "  submit    Force submit inventory to Pro"
            return 1
            ;;
    esac
}

nftban_pro_cmd_inventory_show() {
    # Show current inventory

    if [[ -f "$NFTBAN_PRO_DATA_DIR/inventory.json" ]]; then
        echo ""
        echo "Current Inventory:"
        echo ""
        jq '.' "$NFTBAN_PRO_DATA_DIR/inventory.json" 2>/dev/null || cat "$NFTBAN_PRO_DATA_DIR/inventory.json"
        echo ""

        if [[ -f "$NFTBAN_PRO_DATA_DIR/inventory.sha256" ]]; then
            echo "Checksum: $(cat "$NFTBAN_PRO_DATA_DIR/inventory.sha256")"
        fi
    else
        echo ""
        echo "No inventory collected yet."
        echo "Run: nftban pro inventory run"
        echo ""
    fi
}

nftban_pro_cmd_inventory_run() {
    # Collect and submit inventory (non-interactive, idempotent)
    # Called by timer and at Pro enable time

    local verbose=false
    [[ "${1:-}" == "--verbose" ]] && verbose=true

    [[ "$verbose" == "true" ]] && echo "$(date '+%Y-%m-%d %H:%M:%S') Starting inventory collection..."

    # Step 1: Ensure server_id exists
    local server_id
    server_id=$(nftban_pro_ensure_server_id)
    [[ "$verbose" == "true" ]] && echo "  Server ID: $server_id"

    # Step 2: Collect inventory to temp file
    local tmp_file="${NFTBAN_PRO_DATA_DIR}/inventory.json.tmp"
    mkdir -p "$NFTBAN_PRO_DATA_DIR" || return 1

    nftban_pro_collect_inventory > "$tmp_file"

    # Step 3: Compute hash
    local new_hash
    new_hash=$(sha256sum "$tmp_file" | awk '{print $1}')
    [[ "$verbose" == "true" ]] && echo "  New hash: ${new_hash:0:16}..."

    # Step 4: Compare with existing hash
    local old_hash=""
    if [[ -f "$NFTBAN_PRO_DATA_DIR/inventory.sha256" ]]; then
        old_hash=$(cat "$NFTBAN_PRO_DATA_DIR/inventory.sha256" 2>/dev/null || echo "")
    fi

    if [[ "$new_hash" == "$old_hash" ]]; then
        [[ "$verbose" == "true" ]] && echo "  Inventory unchanged, skipping submission"
        rm -f "$tmp_file"
        return 0
    fi

    [[ "$verbose" == "true" ]] && echo "  Inventory changed, updating..."

    # Step 5: Update inventory files
    mv "$tmp_file" "$NFTBAN_PRO_DATA_DIR/inventory.json"
    echo "$new_hash" > "$NFTBAN_PRO_DATA_DIR/inventory.sha256"
    chmod 640 "$NFTBAN_PRO_DATA_DIR/inventory.json" "$NFTBAN_PRO_DATA_DIR/inventory.sha256"

    # Step 6: Check Pro entitlement
    if ! nftban_pro_is_enabled; then
        [[ "$verbose" == "true" ]] && echo "  Pro inactive, inventory saved locally only"
        return 0
    fi

    # Step 7: Submit to Pro
    [[ "$verbose" == "true" ]] && echo "  Submitting to Pro..."

    if nftban_pro_submit_inventory true >/dev/null 2>&1; then
        [[ "$verbose" == "true" ]] && echo "  Submission successful"
    else
        [[ "$verbose" == "true" ]] && echo "  Submission failed (will retry)"
    fi

    return 0
}

nftban_pro_cmd_inventory_submit() {
    # Force submit inventory to Pro

    echo ""
    echo "Force submitting inventory..."

    # First collect
    nftban_pro_cmd_inventory_run --verbose

    # Then force submit
    if nftban_pro_submit_inventory true; then
        echo ""
        echo "Inventory submitted successfully."
    else
        echo ""
        echo "Submission failed. Check Pro subscription status."
    fi
    echo ""
}

# =============================================================================
# LICENSE CHECK COMMAND (for timer)
# =============================================================================

nftban_pro_cmd_license_check() {
    # Check license and enforce Pro gating (called by timer)

    echo "$(date '+%Y-%m-%d %H:%M:%S') Checking Pro license..."

    if nftban_pro_is_enabled; then
        echo "  License valid - Pro features enabled"
        nftban_pro_enable_remote

        # Also run inventory collection
        nftban_pro_cmd_inventory_run --verbose
    else
        echo "  License invalid - disabling Pro features"
        nftban_pro_disable_remote
    fi
}

# =============================================================================
# MAIN COMMAND HANDLER
# =============================================================================

nftban_cmd_pro() {
    local subcommand="${1:-status}"
    shift || true

    # Show banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
        if [[ $(type -t nftban_banner) == "function" ]]; then
            nftban_banner
        fi
    fi

    case "$subcommand" in
        enroll)
            nftban_pro_cmd_enroll "$@"
            ;;
        status)
            nftban_pro_cmd_status "$@"
            ;;
        disable)
            nftban_pro_cmd_disable "$@"
            ;;
        token)
            nftban_pro_cmd_token "$@"
            ;;
        inventory)
            nftban_pro_cmd_inventory "$@"
            ;;
        license-check)
            # Internal command for timer
            nftban_pro_cmd_license_check "$@"
            ;;
        help|--help|-h)
            echo "Usage: nftban pro <command> [options]"
            echo ""
            echo "Commands:"
            echo "  enroll              Enroll with NFTBan Pro"
            echo "  status              Show Pro subscription status"
            echo "  disable             Disable Pro features"
            echo "  token rotate        Rotate Pro token"
            echo "  token revoke        Remove token and disable Pro"
            echo "  token check         Verify token permissions"
            echo "  inventory show      Display current inventory"
            echo "  inventory run       Collect and submit inventory"
            echo "  inventory submit    Force submit inventory"
            echo ""
            echo "Enrollment Options:"
            echo "  --token-file PATH   Read token from file (recommended)"
            echo "  --token VALUE       Direct token (saved in shell history)"
            echo "  (none)              Interactive prompt"
            echo ""
            echo "Environment Variables:"
            echo "  NFTBAN_PRO_TOKEN    One-shot token for automation"
            echo ""
            echo "Examples:"
            echo "  nftban pro enroll                    # Interactive"
            echo "  nftban pro enroll --token-file /tmp/token.txt"
            echo "  nftban pro status"
            echo "  nftban pro status --json"
            echo "  nftban pro status --refresh"
            echo "  nftban pro token check"
            echo "  nftban pro inventory show"
            echo ""
            ;;
        *)
            echo "Unknown command: $subcommand"
            echo "Usage: nftban pro {enroll|status|disable|token|inventory|help}"
            return 1
            ;;
    esac
}

# Export functions
export -f nftban_cmd_pro
