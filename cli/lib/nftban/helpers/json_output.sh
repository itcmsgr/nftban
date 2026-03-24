#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="json_output"
# meta:type="helper"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Provides JSON output format for CLI commands when --json flag is used"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail


# =============================================================================
# MODULE GUARD
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_JSON_OUTPUT_LOADED:-}" ]] && return 0
readonly NFTBAN_JSON_OUTPUT_LOADED=1

# =============================================================================
# JSON MODE DETECTION
# =============================================================================

# Check if --json flag is present in arguments
# Usage: is_json_mode "$@"
# Returns: 0 if --json found, 1 otherwise
is_json_mode() {
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && return 0
    done
    return 1
}

# Remove --json from arguments array
# Usage: remove_json_flag "$@"
# Outputs: All args except --json
remove_json_flag() {
    for arg in "$@"; do
        [[ "$arg" != "--json" ]] && echo "$arg"
    done
}

# =============================================================================
# JSON OUTPUT FUNCTIONS
# =============================================================================

# Standard json_output function (used by most CLI commands)
# Usage: json_output <success:true/false> <data_json>
# Example: json_output "true" '{"ip":"1.2.3.4"}'
json_output() {
    local success="$1"
    local data="$2"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    if command -v jq &>/dev/null; then
        if [[ "$success" == "true" ]]; then
            jq -n \
                --arg ts "$timestamp" \
                --argjson data "$data" \
                '{
                    success: true,
                    timestamp: $ts,
                    data: $data
                }'
        else
            jq -n \
                --arg ts "$timestamp" \
                --arg err "$data" \
                '{
                    success: false,
                    timestamp: $ts,
                    error: $err
                }'
        fi
    else
        if [[ "$success" == "true" ]]; then
            cat <<EOF
{
  "success": true,
  "timestamp": "$timestamp",
  "data": $data
}
EOF
        else
            cat <<EOF
{
  "success": false,
  "timestamp": "$timestamp",
  "error": "$data"
}
EOF
        fi
    fi
}

# Output successful JSON response
# Usage: json_success <data_json>
# Example: json_success '{"ip":"1.2.3.4","action":"banned"}'
json_success() {
    local data="$1"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    if command -v jq &>/dev/null; then
        # Use jq for proper JSON formatting and validation
        jq -n \
            --arg ts "$timestamp" \
            --argjson data "$data" \
            '{
                success: true,
                timestamp: $ts,
                data: $data
            }'
    else
        # Fallback: manual JSON construction
        cat <<EOF
{
  "success": true,
  "timestamp": "$timestamp",
  "data": $data
}
EOF
    fi
}

# Output error JSON response
# Usage: json_error <error_message> [error_code]
# Example: json_error "Invalid IP address" 400
json_error() {
    local error_message="$1"
    local error_code="${2:-1}"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    if command -v jq &>/dev/null; then
        jq -n \
            --arg ts "$timestamp" \
            --arg err "$error_message" \
            --argjson code "$error_code" \
            '{
                success: false,
                timestamp: $ts,
                error: $err,
                error_code: $code
            }'
    else
        cat <<EOF
{
  "success": false,
  "timestamp": "$timestamp",
  "error": "$error_message",
  "error_code": $error_code
}
EOF
    fi
}

# =============================================================================
# JSON BUILDERS FOR COMMON OPERATIONS
# =============================================================================

# Build JSON for IP ban operation
# Usage: json_ban_response <ip> <reason> <timeout>
json_ban_response() {
    local ip="$1"
    local reason="${2:-manual}"
    local timeout="${3:-1h}"

    if command -v jq &>/dev/null; then
        jq -n \
            --arg ip "$ip" \
            --arg reason "$reason" \
            --arg timeout "$timeout" \
            '{
                ip: $ip,
                action: "banned",
                reason: $reason,
                timeout: $timeout
            }'
    else
        cat <<EOF
{
  "ip": "$ip",
  "action": "banned",
  "reason": "$reason",
  "timeout": "$timeout"
}
EOF
    fi
}

# Build JSON for IP unban operation
# Usage: json_unban_response <ip> <removed_from...>
json_unban_response() {
    local ip="$1"
    shift
    local locations=("$@")

    local locations_json="["
    for loc in "${locations[@]}"; do
        locations_json+="\"$loc\","
    done
    locations_json="${locations_json%,}]"

    if command -v jq &>/dev/null; then
        jq -n \
            --arg ip "$ip" \
            --argjson locs "$locations_json" \
            '{
                ip: $ip,
                action: "unbanned",
                removed_from: $locs
            }'
    else
        cat <<EOF
{
  "ip": "$ip",
  "action": "unbanned",
  "removed_from": $locations_json
}
EOF
    fi
}

# Build JSON for search results
# Usage: json_search_response <ip> <found> [locations...]
json_search_response() {
    local ip="$1"
    local found="$2"
    shift 2
    local locations=("$@")

    local locations_json="["
    for loc in "${locations[@]}"; do
        locations_json+="\"$loc\","
    done
    locations_json="${locations_json%,}]"

    if command -v jq &>/dev/null; then
        jq -n \
            --arg ip "$ip" \
            --argjson found "$found" \
            --argjson locs "$locations_json" \
            '{
                ip: $ip,
                found: $found,
                locations: $locs
            }'
    else
        cat <<EOF
{
  "ip": "$ip",
  "found": $found,
  "locations": $locations_json
}
EOF
    fi
}

# Build JSON for stats/dashboard
# Usage: json_stats_response <stats_object>
json_stats_response() {
    local stats="$1"

    if command -v jq &>/dev/null; then
        jq -n --argjson stats "$stats" '{stats: $stats}'
    else
        cat <<EOF
{
  "stats": $stats
}
EOF
    fi
}

# Build JSON for list results
# Usage: json_list_response <items_array> <total_count>
json_list_response() {
    local items="$1"
    local total="${2:-0}"

    if command -v jq &>/dev/null; then
        jq -n \
            --argjson items "$items" \
            --argjson total "$total" \
            '{
                items: $items,
                total: $total
            }'
    else
        cat <<EOF
{
  "items": $items,
  "total": $total
}
EOF
    fi
}

# Build JSON for geoban operation
# Usage: json_geoban_response <action> <country> <ip_count>
json_geoban_response() {
    local action="$1"
    local country="$2"
    local ip_count="${3:-0}"

    if command -v jq &>/dev/null; then
        jq -n \
            --arg action "$action" \
            --arg country "$country" \
            --argjson count "$ip_count" \
            '{
                action: $action,
                country: $country,
                ip_count: $count
            }'
    else
        cat <<EOF
{
  "action": "$action",
  "country": "$country",
  "ip_count": $ip_count
}
EOF
    fi
}

# =============================================================================
# ARRAY/OBJECT HELPERS
# =============================================================================

# Convert bash array to JSON array
# Usage: array_to_json "${my_array[@]}"
array_to_json() {
    local arr=("$@")

    if command -v jq &>/dev/null; then
        printf '%s\n' "${arr[@]}" | jq -R . | jq -s .
    else
        # Manual construction
        local json="["
        for item in "${arr[@]}"; do
            # Escape quotes in item
            item="${item//\"/\\\"}"
            json+="\"$item\","
        done
        json="${json%,}]"
        echo "$json"
    fi
}

# Convert key=value pairs to JSON object
# Usage: pairs_to_json "key1=value1" "key2=value2" ...
pairs_to_json() {
    local pairs=("$@")

    if command -v jq &>/dev/null; then
        local args=()
        for pair in "${pairs[@]}"; do
            local key="${pair%%=*}"
            local value="${pair#*=}"
            args+=(--arg "$key" "$value")
        done

        # Build jq object dynamically
        local obj_str="{"
        for pair in "${pairs[@]}"; do
            local key="${pair%%=*}"
            obj_str+="\"$key\": \$$key,"
        done
        obj_str="${obj_str%,}}"

        jq -n "${args[@]}" "$obj_str"
    else
        # Manual construction
        local json="{"
        for pair in "${pairs[@]}"; do
            local key="${pair%%=*}"
            local value="${pair#*=}"
            # Escape quotes
            value="${value//\"/\\\"}"
            json+="\"$key\": \"$value\","
        done
        json="${json%,}}"
        echo "$json"
    fi
}

# =============================================================================
# ESCAPE FUNCTIONS
# =============================================================================

# Escape string for JSON
# Usage: json_escape "string with \"quotes\" and \backslashes"
json_escape() {
    local str="$1"

    # Escape backslash first
    str="${str//\\/\\\\}"
    # Escape quotes
    str="${str//\"/\\\"}"
    # Escape newlines
    str="${str//$'\n'/\\n}"
    # Escape tabs
    str="${str//$'\t'/\\t}"
    # Escape carriage returns
    str="${str//$'\r'/\\r}"

    echo "$str"
}

# =============================================================================
# VALIDATION
# =============================================================================

# Check if string is valid JSON
# Usage: is_valid_json "$json_string"
is_valid_json() {
    local json="$1"

    if command -v jq &>/dev/null; then
        echo "$json" | jq empty 2>/dev/null
        return $?
    else
        # Basic check: starts with { or [, ends with } or ]
        [[ "$json" =~ ^[[:space:]]*(\{.*\}|\[.*\])[[:space:]]*$ ]]
    fi
}

# =============================================================================
# COMMAND EXIT MARKER
# =============================================================================

# Output command exit marker for validation
# This marker helps testing framework detect successful command completion
# Only outputs in debug mode (NFTBAN_DEBUG=true)
# Usage: nftban_cmd_exit <command_name>
# Example: nftban_cmd_exit "search"
nftban_cmd_exit() {
    # Only output in debug mode
    [[ "${NFTBAN_DEBUG:-false}" != "true" ]] && return 0
    local cmd_name="$1"
    echo "# NFTBAN_CMD_EXIT: $cmd_name"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f is_json_mode
export -f remove_json_flag
export -f json_output
export -f json_success
export -f json_error
export -f json_ban_response
export -f json_unban_response
export -f json_search_response
export -f json_stats_response
export -f json_list_response
export -f json_geoban_response
export -f array_to_json
export -f pairs_to_json
export -f json_escape
export -f is_valid_json
export -f nftban_cmd_exit

# =============================================================================
# MODULE LOADED
# =============================================================================

# Silent - no output on load
true
