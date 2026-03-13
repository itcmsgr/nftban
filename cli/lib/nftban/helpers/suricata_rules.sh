#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="suricata_rules"
# meta:type="helper"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Shared functions for Suricata rules, categories, and SID management"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_SURICATA_RULES_LOADED:-}" ]] && return 0
_NFTBAN_SURICATA_RULES_LOADED=1

# Source core file operations module for atomic writes
_NFTBAN_LIB_DIR="${_NFTBAN_LIB_DIR:-/usr/share/nftban/lib/nftban}"
# shellcheck source=../core/nftban_file_ops.sh
source "${_NFTBAN_LIB_DIR}/core/nftban_file_ops.sh" 2>/dev/null || true

# Source distro config for distribution-specific paths
# shellcheck source=../lib/nftban_distro_config.sh
source "${_NFTBAN_LIB_DIR}/lib/nftban_distro_config.sh" 2>/dev/null || true

# =============================================================================
# CONFIGURATION
# =============================================================================

: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"
: "${NFTBAN_SURICATA_DIR:=${NFTBAN_CONFIG_DIR}/suricata}"
# Use distro config for rules directory (handles Debian vs RHEL path differences)
# NO HARDCODED FALLBACK - distro config is the single source of truth
: "${SURICATA_RULES_DIR:=${DISTRO_PATHS[suricata_rules_dir]}}"

# NFTBan-managed rule files (never edit vendor files)
readonly NFTBAN_DISABLE_CONF="${NFTBAN_SURICATA_DIR}/rules/disable.conf"
readonly NFTBAN_ENABLE_CONF="${NFTBAN_SURICATA_DIR}/rules/enable.conf"
readonly NFTBAN_CATEGORIES_CONF="${NFTBAN_SURICATA_DIR}/rules/categories.enabled"
readonly NFTBAN_LOCAL_RULES="${NFTBAN_SURICATA_DIR}/rules/local.rules"
readonly NFTBAN_STATE_DIR="${NFTBAN_SURICATA_DIR}/state"
readonly NFTBAN_LASTGOOD_DIR="${NFTBAN_STATE_DIR}/last-good"

# Colors
: "${RED:=\033[0;31m}"
: "${GREEN:=\033[0;32m}"
: "${YELLOW:=\033[0;33m}"
: "${BLUE:=\033[0;34m}"
: "${CYAN:=\033[0;36m}"
: "${NC:=\033[0m}"

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Check nftban group membership (polkit handles systemd operations)
_suricata_check_access() {
    local operation="${1:-this operation}"

    # Check if user is in nftban group (polkit grants systemd access)
    if id -nG 2>/dev/null | grep -qw "nftban"; then
        return 0
    fi

    # Root always has access
    if [[ $EUID -eq 0 ]]; then
        return 0
    fi

    echo -e "${RED}ERROR:${NC} nftban group membership required for $operation" >&2
    echo "Add user to nftban group: sudo usermod -a -G nftban \$USER" >&2
    echo "Then log out and back in for group membership to take effect." >&2
    return 1
}

# Legacy alias for compatibility (deprecated - use _suricata_check_access)
_suricata_check_root() {
    _suricata_check_access "$@"
}

# Ensure NFTBan suricata directories exist
_suricata_ensure_dirs() {
    mkdir -p "$NFTBAN_SURICATA_DIR/rules" || return 1
    mkdir -p "$NFTBAN_STATE_DIR" || return 1
    mkdir -p "$NFTBAN_LASTGOOD_DIR" || return 1
}

# Validate Suricata configuration
_suricata_validate_config() {
    local quiet="${1:-false}"

    if ! command -v suricata &>/dev/null; then
        [[ "$quiet" != "true" ]] && echo -e "${RED}ERROR:${NC} Suricata is not installed" >&2
        return 1
    fi

    # Run suricata -T to validate
    if ! suricata -T -c /etc/suricata/suricata.yaml &>/dev/null; then
        [[ "$quiet" != "true" ]] && echo -e "${YELLOW}WARNING:${NC} Suricata configuration test failed" >&2
        return 1
    fi

    return 0
}

# Create backup before modification
_suricata_backup_rules() {
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_dir="${NFTBAN_LASTGOOD_DIR}/${timestamp}"

    mkdir -p "$backup_dir" || return 1

    # Backup all rule config files
    [[ -f "$NFTBAN_DISABLE_CONF" ]] && cp "$NFTBAN_DISABLE_CONF" "$backup_dir/"
    [[ -f "$NFTBAN_ENABLE_CONF" ]] && cp "$NFTBAN_ENABLE_CONF" "$backup_dir/"
    [[ -f "$NFTBAN_CATEGORIES_CONF" ]] && cp "$NFTBAN_CATEGORIES_CONF" "$backup_dir/"
    [[ -f "$NFTBAN_LOCAL_RULES" ]] && cp "$NFTBAN_LOCAL_RULES" "$backup_dir/"

    # Write timestamp
    echo "$timestamp" > "$backup_dir/timestamp"

    # Prune old backups (keep last 10)
    local count
    count=$(find "$NFTBAN_LASTGOOD_DIR" -maxdepth 1 -type d -name "20*" | wc -l)
    if [[ $count -gt 10 ]]; then
        find "$NFTBAN_LASTGOOD_DIR" -maxdepth 1 -type d -name "20*" | sort | head -n $((count - 10)) | xargs rm -rf
    fi

    echo "$backup_dir"
}

# =============================================================================
# RULES STATUS
# =============================================================================

# Get ruleset status information
_suricata_rules_status() {
    local json_mode="${1:-false}"

    local total_rules=0
    local active_rules=0
    local disabled_rules=0
    local local_rules=0
    local last_update="unknown"
    local sources=""

    # Get rule count from files
    if [[ -d "$SURICATA_RULES_DIR" ]]; then
        total_rules=$(find "$SURICATA_RULES_DIR" -name "*.rules" -exec grep -c "^alert\|^drop\|^reject" {} + 2>/dev/null | awk -F: '{sum+=$NF} END {print sum}' || echo "0")
    fi

    # Count disabled SIDs
    if [[ -f "$NFTBAN_DISABLE_CONF" ]]; then
        disabled_rules=$(grep -cE "^[0-9]+" "$NFTBAN_DISABLE_CONF" 2>/dev/null || echo "0")
    fi

    # Count local rules
    if [[ -f "$NFTBAN_LOCAL_RULES" ]]; then
        local_rules=$(grep -cE "^alert|^drop|^reject" "$NFTBAN_LOCAL_RULES" 2>/dev/null || echo "0")
    fi

    # Get last update time from suricata.rules
    if [[ -f "$SURICATA_RULES_DIR/suricata.rules" ]]; then
        last_update=$(stat -c "%Y" "$SURICATA_RULES_DIR/suricata.rules" 2>/dev/null || echo "0")
        if [[ "$last_update" != "0" ]]; then
            last_update=$(date -d "@$last_update" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")
        fi
    fi

    # Check enabled sources
    if command -v suricata-update &>/dev/null; then
        sources=$(suricata-update list-enabled-sources 2>/dev/null | grep -E "^  - " | sed 's/^  - //' | tr '\n' ',' | sed 's/,$//' || echo "et/open")
        [[ -z "$sources" ]] && sources="et/open"
    fi

    active_rules=$((total_rules - disabled_rules))

    if [[ "$json_mode" == "true" ]]; then
        cat << EOF
{
  "success": true,
  "rules": {
    "total": $total_rules,
    "active": $active_rules,
    "disabled": $disabled_rules,
    "local": $local_rules,
    "last_update": "$last_update",
    "sources": "$sources",
    "rules_dir": "$SURICATA_RULES_DIR",
    "config_dir": "$NFTBAN_SURICATA_DIR/rules"
  }
}
EOF
    else
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  📊 Suricata Rules Status"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        printf "  %-20s %s\n" "Total Rules:" "$total_rules"
        printf "  %-20s %s\n" "Active Rules:" "$active_rules"
        printf "  %-20s %s\n" "Disabled Rules:" "$disabled_rules"
        printf "  %-20s %s\n" "Local Rules:" "$local_rules"
        echo ""
        printf "  %-20s %s\n" "Last Update:" "$last_update"
        printf "  %-20s %s\n" "Sources:" "$sources"
        echo ""
        printf "  %-20s %s\n" "Rules Dir:" "$SURICATA_RULES_DIR"
        printf "  %-20s %s\n" "Config Dir:" "$NFTBAN_SURICATA_DIR/rules"
        echo ""
    fi
}

# =============================================================================
# RULES ROLLBACK
# =============================================================================

# List available backups
_suricata_rules_list_backups() {
    local json_mode="${1:-false}"

    local backups=()
    local backup_data=""

    if [[ -d "$NFTBAN_LASTGOOD_DIR" ]]; then
        while IFS= read -r dir; do
            [[ -z "$dir" ]] && continue
            local name
            name=$(basename "$dir")
            local ts_file="$dir/timestamp"
            local timestamp=""
            [[ -f "$ts_file" ]] && timestamp=$(cat "$ts_file")
            backups+=("$name")
            backup_data+="\"$name\","
        done < <(find "$NFTBAN_LASTGOOD_DIR" -maxdepth 1 -type d -name "20*" 2>/dev/null | sort -r)
    fi

    if [[ "$json_mode" == "true" ]]; then
        backup_data="${backup_data%,}"  # Remove trailing comma
        echo "{\"success\": true, \"backups\": [$backup_data]}"
    else
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  💾 Available Rule Backups"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        if [[ ${#backups[@]} -eq 0 ]]; then
            echo "  No backups found"
        else
            echo "  Backup Directory: $NFTBAN_LASTGOOD_DIR"
            echo ""
            for backup in "${backups[@]}"; do
                echo "    $backup"
            done
        fi
        echo ""
    fi
}

# Rollback to a specific backup
_suricata_rules_rollback() {
    local backup_name="$1"
    local json_mode="${2:-false}"

    _suricata_check_root "rollback" || return 1

    local backup_dir="$NFTBAN_LASTGOOD_DIR/$backup_name"

    if [[ ! -d "$backup_dir" ]]; then
        if [[ "$json_mode" == "true" ]]; then
            echo "{\"success\": false, \"error\": \"Backup not found: $backup_name\"}"
        else
            echo -e "${RED}ERROR:${NC} Backup not found: $backup_name" >&2
            echo "List backups with: nftban suricata rules list-backups" >&2
        fi
        return 1
    fi

    # Create a backup before rollback
    local pre_rollback_backup
    pre_rollback_backup=$(_suricata_backup_rules)

    # v1.19.20 FIX: Added || true to prevent set -e failures
    # Restore files
    local restored=0
    [[ -f "$backup_dir/disable.conf" ]] && { cp "$backup_dir/disable.conf" "$NFTBAN_DISABLE_CONF"; ((restored++)) || true; }
    [[ -f "$backup_dir/enable.conf" ]] && { cp "$backup_dir/enable.conf" "$NFTBAN_ENABLE_CONF"; ((restored++)) || true; }
    [[ -f "$backup_dir/categories.enabled" ]] && { cp "$backup_dir/categories.enabled" "$NFTBAN_CATEGORIES_CONF"; ((restored++)) || true; }
    [[ -f "$backup_dir/local.rules" ]] && { cp "$backup_dir/local.rules" "$NFTBAN_LOCAL_RULES"; ((restored++)) || true; }

    if [[ "$json_mode" == "true" ]]; then
        echo "{\"success\": true, \"backup_restored\": \"$backup_name\", \"files_restored\": $restored, \"pre_rollback_backup\": \"$(basename "$pre_rollback_backup")\"}"
    else
        echo ""
        echo -e "${GREEN}✓${NC} Rolled back to: $backup_name"
        echo "  Files restored: $restored"
        echo "  Pre-rollback backup: $(basename "$pre_rollback_backup")"
        echo ""
        echo "To apply changes:"
        echo "  suricata-update && systemctl reload suricata"
        echo ""
    fi
}

# =============================================================================
# CATEGORY MANAGEMENT
# =============================================================================

# List all categories with status
_suricata_category_list() {
    local json_mode="${1:-false}"

    if [[ ! -f "$NFTBAN_CATEGORIES_CONF" ]]; then
        if [[ "$json_mode" == "true" ]]; then
            echo "{\"success\": false, \"error\": \"Categories config not found\"}"
        else
            echo -e "${RED}ERROR:${NC} Categories config not found: $NFTBAN_CATEGORIES_CONF" >&2
        fi
        return 1
    fi

    local categories=()
    local json_cats=""

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue

        local cat_name status
        cat_name=$(echo "$line" | cut -d'=' -f1 | xargs)
        status=$(echo "$line" | cut -d'=' -f2 | xargs)

        [[ -z "$cat_name" ]] && continue

        categories+=("$cat_name|$status")
        json_cats+="{\"name\": \"$cat_name\", \"status\": \"$status\"},"
    done < "$NFTBAN_CATEGORIES_CONF"

    if [[ "$json_mode" == "true" ]]; then
        json_cats="${json_cats%,}"
        echo "{\"success\": true, \"categories\": [$json_cats]}"
    else
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  📂 Suricata Rule Categories"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        printf "  %-30s %s\n" "CATEGORY" "STATUS"
        echo "  ──────────────────────────────────────────────────"

        for cat_entry in "${categories[@]}"; do
            local cat_name status color
            cat_name=$(echo "$cat_entry" | cut -d'|' -f1)
            status=$(echo "$cat_entry" | cut -d'|' -f2)

            if [[ "$status" == "enabled" ]]; then
                color="$GREEN"
            else
                color="$RED"
            fi

            printf "  %-30s ${color}%s${NC}\n" "$cat_name" "$status"
        done
        echo ""
        echo "Config file: $NFTBAN_CATEGORIES_CONF"
        echo ""
    fi
}

# Enable/disable a category
_suricata_category_set() {
    local category="$1"
    local status="$2"  # enabled or disabled
    local json_mode="${3:-false}"

    _suricata_check_root "category changes" || return 1

    if [[ ! -f "$NFTBAN_CATEGORIES_CONF" ]]; then
        if [[ "$json_mode" == "true" ]]; then
            echo "{\"success\": false, \"error\": \"Categories config not found\"}"
        else
            echo -e "${RED}ERROR:${NC} Categories config not found" >&2
        fi
        return 1
    fi

    # Validate status
    if [[ "$status" != "enabled" && "$status" != "disabled" ]]; then
        if [[ "$json_mode" == "true" ]]; then
            echo "{\"success\": false, \"error\": \"Invalid status. Use: enabled or disabled\"}"
        else
            echo -e "${RED}ERROR:${NC} Invalid status. Use: enabled or disabled" >&2
        fi
        return 1
    fi

    # Create backup
    _suricata_backup_rules >/dev/null

    # Check if category exists and update atomically
    if ! grep -qE "^${category}[[:space:]]*=" "$NFTBAN_CATEGORIES_CONF"; then
        # Add new category (atomic write)
        { cat "$NFTBAN_CATEGORIES_CONF"; echo ""; echo "$category = $status"; } | nftban_atomic_write "$NFTBAN_CATEGORIES_CONF"
    else
        # Update existing (atomic write)
        sed "s|^${category}[[:space:]]*=.*|${category} = ${status}|" "$NFTBAN_CATEGORIES_CONF" | nftban_atomic_write "$NFTBAN_CATEGORIES_CONF"
    fi

    if [[ "$json_mode" == "true" ]]; then
        echo "{\"success\": true, \"category\": \"$category\", \"status\": \"$status\"}"
    else
        local action_word="enabled"
        local color="$GREEN"
        if [[ "$status" == "disabled" ]]; then
            action_word="disabled"
            color="$RED"
        fi
        echo ""
        echo -e "${GREEN}✓${NC} Category ${color}$category${NC} is now $action_word"
        echo ""
        echo "To apply changes:"
        echo "  suricata-update && systemctl reload suricata"
        echo ""
    fi
}

# =============================================================================
# SID MANAGEMENT
# =============================================================================

# Enable a specific SID (add to enable.conf, remove from disable.conf)
_suricata_sid_enable() {
    local sid="$1"
    local json_mode="${2:-false}"

    _suricata_check_root "SID changes" || return 1

    # Validate SID format
    if ! [[ "$sid" =~ ^[0-9]+$ ]]; then
        if [[ "$json_mode" == "true" ]]; then
            echo "{\"success\": false, \"error\": \"Invalid SID format: $sid\"}"
        else
            echo -e "${RED}ERROR:${NC} Invalid SID format: $sid" >&2
        fi
        return 1
    fi

    _suricata_ensure_dirs
    _suricata_backup_rules >/dev/null

    # Create files if they don't exist
    [[ ! -f "$NFTBAN_ENABLE_CONF" ]] && cat > "$NFTBAN_ENABLE_CONF" << 'EOF'
# nftban Suricata Rule Enable Configuration
# Managed by: nftban suricata sid enable/disable
EOF

    # v1.19.21 FIX: Sorted rules (GH#46)
    # Remove from disable.conf if present (atomic write with sorting)
    if [[ -f "$NFTBAN_DISABLE_CONF" ]]; then
        grep -v "^${sid}$" "$NFTBAN_DISABLE_CONF" 2>/dev/null | sort -n | nftban_atomic_write "$NFTBAN_DISABLE_CONF"
    fi

    # v1.19.21 FIX: Sorted rules (GH#46)
    # Add to enable.conf if not already there (atomic write with sorting)
    if ! grep -qE "^${sid}$" "$NFTBAN_ENABLE_CONF" 2>/dev/null; then
        { cat "$NFTBAN_ENABLE_CONF" 2>/dev/null; echo "$sid"; } | sort -u -n | nftban_atomic_write "$NFTBAN_ENABLE_CONF"
    fi

    if [[ "$json_mode" == "true" ]]; then
        echo "{\"success\": true, \"sid\": $sid, \"action\": \"enabled\"}"
    else
        echo ""
        echo -e "${GREEN}✓${NC} SID $sid is now enabled"
        echo ""
        echo "To apply changes:"
        echo "  suricata-update && systemctl reload suricata"
        echo ""
    fi
}

# Disable a specific SID (add to disable.conf, remove from enable.conf)
_suricata_sid_disable() {
    local sid="$1"
    local json_mode="${2:-false}"

    _suricata_check_root "SID changes" || return 1

    # Validate SID format
    if ! [[ "$sid" =~ ^[0-9]+$ ]]; then
        if [[ "$json_mode" == "true" ]]; then
            echo "{\"success\": false, \"error\": \"Invalid SID format: $sid\"}"
        else
            echo -e "${RED}ERROR:${NC} Invalid SID format: $sid" >&2
        fi
        return 1
    fi

    _suricata_ensure_dirs
    _suricata_backup_rules >/dev/null

    # Create files if they don't exist
    [[ ! -f "$NFTBAN_DISABLE_CONF" ]] && cat > "$NFTBAN_DISABLE_CONF" << 'EOF'
# nftban Suricata Rule Disable Configuration
# Managed by: nftban suricata sid enable/disable
EOF

    # v1.19.21 FIX: Sorted rules (GH#46)
    # Remove from enable.conf if present (atomic write with sorting)
    if [[ -f "$NFTBAN_ENABLE_CONF" ]]; then
        grep -v "^${sid}$" "$NFTBAN_ENABLE_CONF" 2>/dev/null | sort -n | nftban_atomic_write "$NFTBAN_ENABLE_CONF"
    fi

    # v1.19.21 FIX: Sorted rules (GH#46)
    # Add to disable.conf if not already there (atomic write with sorting)
    if ! grep -qE "^${sid}$" "$NFTBAN_DISABLE_CONF" 2>/dev/null; then
        { cat "$NFTBAN_DISABLE_CONF" 2>/dev/null; echo "$sid"; } | sort -u -n | nftban_atomic_write "$NFTBAN_DISABLE_CONF"
    fi

    if [[ "$json_mode" == "true" ]]; then
        echo "{\"success\": true, \"sid\": $sid, \"action\": \"disabled\"}"
    else
        echo ""
        echo -e "${GREEN}✓${NC} SID $sid is now disabled"
        echo ""
        echo "To apply changes:"
        echo "  suricata-update && systemctl reload suricata"
        echo ""
    fi
}

# List enabled/disabled SIDs
_suricata_sid_list() {
    local type="${1:-all}"  # enabled, disabled, or all
    local json_mode="${2:-false}"

    local enabled_sids=()
    local disabled_sids=()

    if [[ -f "$NFTBAN_ENABLE_CONF" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^# ]] && continue
            [[ "$line" =~ ^[0-9]+$ ]] && enabled_sids+=("$line")
        done < "$NFTBAN_ENABLE_CONF"
    fi

    if [[ -f "$NFTBAN_DISABLE_CONF" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^# ]] && continue
            [[ "$line" =~ ^[0-9]+$ ]] && disabled_sids+=("$line")
        done < "$NFTBAN_DISABLE_CONF"
    fi

    if [[ "$json_mode" == "true" ]]; then
        local en_json="" dis_json=""
        for sid in "${enabled_sids[@]}"; do
            en_json+="$sid,"
        done
        for sid in "${disabled_sids[@]}"; do
            dis_json+="$sid,"
        done
        en_json="${en_json%,}"
        dis_json="${dis_json%,}"
        echo "{\"success\": true, \"enabled\": [$en_json], \"disabled\": [$dis_json]}"
    else
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  🔢 SID Overrides"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""

        if [[ "$type" == "all" || "$type" == "enabled" ]]; then
            echo -e "  ${GREEN}Enabled SIDs${NC} (${#enabled_sids[@]}):"
            if [[ ${#enabled_sids[@]} -eq 0 ]]; then
                echo "    (none)"
            else
                printf "    %s\n" "${enabled_sids[@]}"
            fi
            echo ""
        fi

        if [[ "$type" == "all" || "$type" == "disabled" ]]; then
            echo -e "  ${RED}Disabled SIDs${NC} (${#disabled_sids[@]}):"
            if [[ ${#disabled_sids[@]} -eq 0 ]]; then
                echo "    (none)"
            else
                printf "    %s\n" "${disabled_sids[@]}"
            fi
            echo ""
        fi

        echo "Config files:"
        echo "  Enable:  $NFTBAN_ENABLE_CONF"
        echo "  Disable: $NFTBAN_DISABLE_CONF"
        echo ""
    fi
}

# =============================================================================
# LOCAL RULES MANAGEMENT (User rules, SID 1000000-1999999)
# =============================================================================

# List local user rules
_suricata_local_list() {
    local json_mode="${1:-false}"

    if [[ ! -f "$NFTBAN_LOCAL_RULES" ]]; then
        if [[ "$json_mode" == "true" ]]; then
            echo "{\"success\": true, \"rules\": []}"
        else
            echo ""
            echo "No local rules file found"
            echo ""
        fi
        return 0
    fi

    local rules=()
    local json_rules=""
    local in_user_section=false
    local in_auto_section=false

    while IFS= read -r line; do
        # Track sections
        if [[ "$line" =~ "USER CUSTOM RULES" ]]; then
            in_user_section=true
            continue
        fi
        if [[ "$line" =~ \[nftban-auto-start\] ]]; then
            in_user_section=false
            in_auto_section=true
            continue
        fi

        # Only process user section
        if [[ "$in_user_section" == true && ! "$in_auto_section" == true ]]; then
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^# ]] && continue

            # Extract SID from rule
            local sid=""
            if [[ "$line" =~ sid:([0-9]+) ]]; then
                sid="${BASH_REMATCH[1]}"
            fi

            # Only include user SID range (1000000-1999999)
            if [[ -n "$sid" && "$sid" -ge 1000000 && "$sid" -le 1999999 ]]; then
                rules+=("$sid|$line")
                # Escape for JSON
                local escaped_line
                escaped_line=$(echo "$line" | sed 's/"/\\"/g')
                json_rules+="{\"sid\": $sid, \"rule\": \"$escaped_line\"},"
            fi
        fi
    done < "$NFTBAN_LOCAL_RULES"

    if [[ "$json_mode" == "true" ]]; then
        json_rules="${json_rules%,}"
        echo "{\"success\": true, \"rules\": [$json_rules]}"
    else
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  📝 Local User Rules (SID 1000000-1999999)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""

        if [[ ${#rules[@]} -eq 0 ]]; then
            echo "  No local user rules defined"
        else
            echo "  Count: ${#rules[@]}"
            echo ""
            for rule_entry in "${rules[@]}"; do
                local sid rule
                sid=$(echo "$rule_entry" | cut -d'|' -f1)
                rule=$(echo "$rule_entry" | cut -d'|' -f2-)
                # Truncate long rules
                [[ ${#rule} -gt 70 ]] && rule="${rule:0:67}..."
                printf "  [SID:%s] %s\n" "$sid" "$rule"
            done
        fi
        echo ""
        echo "File: $NFTBAN_LOCAL_RULES"
        echo ""
    fi
}

# Add a local user rule
_suricata_local_add() {
    local rule="$1"
    local json_mode="${2:-false}"

    _suricata_check_root "adding local rules" || return 1

    # Validate rule has SID in user range
    local sid=""
    if [[ "$rule" =~ sid:([0-9]+) ]]; then
        sid="${BASH_REMATCH[1]}"
    else
        if [[ "$json_mode" == "true" ]]; then
            echo "{\"success\": false, \"error\": \"Rule must contain sid: field\"}"
        else
            echo -e "${RED}ERROR:${NC} Rule must contain sid: field" >&2
        fi
        return 1
    fi

    # Validate SID range
    if [[ "$sid" -lt 1000000 || "$sid" -gt 1999999 ]]; then
        if [[ "$json_mode" == "true" ]]; then
            echo "{\"success\": false, \"error\": \"User rules must use SID range 1000000-1999999\"}"
        else
            echo -e "${RED}ERROR:${NC} User rules must use SID range 1000000-1999999" >&2
            echo "  Use SID 9000000-9999999 for nftban-managed rules (nftban suricata custom)" >&2
        fi
        return 1
    fi

    # Validate rule syntax (basic check)
    if ! [[ "$rule" =~ ^(alert|drop|reject|pass)[[:space:]] ]]; then
        if [[ "$json_mode" == "true" ]]; then
            echo "{\"success\": false, \"error\": \"Rule must start with: alert, drop, reject, or pass\"}"
        else
            echo -e "${RED}ERROR:${NC} Rule must start with: alert, drop, reject, or pass" >&2
        fi
        return 1
    fi

    _suricata_ensure_dirs
    _suricata_backup_rules >/dev/null

    # Initialize local.rules if needed
    if [[ ! -f "$NFTBAN_LOCAL_RULES" ]]; then
        cat > "$NFTBAN_LOCAL_RULES" << 'EOF'
# nftban Local Suricata Rules
# ===========================
# SID ranges:
#   1000000-1999999: Local rules (user-defined)
#   9000000-9999999: nftban auto-generated rules

# ===========================================================================
# USER CUSTOM RULES - Add your rules below this line
# ===========================================================================


# ===========================================================================
# NFTBAN AUTO-GENERATED RULES - DO NOT EDIT BELOW THIS LINE
# ===========================================================================
# [nftban-auto-start]
# [nftban-auto-end]
EOF
    fi

    # Check if SID already exists
    if grep -qE "sid:${sid}[^0-9]" "$NFTBAN_LOCAL_RULES" 2>/dev/null; then
        if [[ "$json_mode" == "true" ]]; then
            echo "{\"success\": false, \"error\": \"SID $sid already exists in local rules\"}"
        else
            echo -e "${RED}ERROR:${NC} SID $sid already exists in local rules" >&2
            echo "  Use 'nftban suricata local edit $sid' to modify" >&2
        fi
        return 1
    fi

    # Insert rule before auto-generated section
    local temp_file
    temp_file=$(mktemp)
    local inserted=false

    while IFS= read -r line; do
        if [[ "$line" =~ "NFTBAN AUTO-GENERATED" && "$inserted" == false ]]; then
            echo "$rule" >> "$temp_file"
            echo "" >> "$temp_file"
            inserted=true
        fi
        echo "$line" >> "$temp_file"
    done < "$NFTBAN_LOCAL_RULES"

    # If marker not found, just append
    if [[ "$inserted" == false ]]; then
        echo "$rule" >> "$NFTBAN_LOCAL_RULES"
    else
        mv "$temp_file" "$NFTBAN_LOCAL_RULES"
    fi

    chmod 644 "$NFTBAN_LOCAL_RULES"

    if [[ "$json_mode" == "true" ]]; then
        echo "{\"success\": true, \"sid\": $sid, \"action\": \"added\"}"
    else
        echo ""
        echo -e "${GREEN}✓${NC} Rule added with SID $sid"
        echo ""
        echo "To apply changes:"
        echo "  suricata-update && systemctl reload suricata"
        echo ""
    fi
}

# Remove a local user rule
_suricata_local_remove() {
    local sid="$1"
    local json_mode="${2:-false}"

    _suricata_check_root "removing local rules" || return 1

    # Validate SID format
    if ! [[ "$sid" =~ ^[0-9]+$ ]]; then
        if [[ "$json_mode" == "true" ]]; then
            echo "{\"success\": false, \"error\": \"Invalid SID format\"}"
        else
            echo -e "${RED}ERROR:${NC} Invalid SID format" >&2
        fi
        return 1
    fi

    if [[ ! -f "$NFTBAN_LOCAL_RULES" ]]; then
        if [[ "$json_mode" == "true" ]]; then
            echo "{\"success\": false, \"error\": \"Local rules file not found\"}"
        else
            echo -e "${RED}ERROR:${NC} Local rules file not found" >&2
        fi
        return 1
    fi

    # Check if SID exists
    if ! grep -qE "sid:${sid}[^0-9]" "$NFTBAN_LOCAL_RULES"; then
        if [[ "$json_mode" == "true" ]]; then
            echo "{\"success\": false, \"error\": \"SID $sid not found in local rules\"}"
        else
            echo -e "${RED}ERROR:${NC} SID $sid not found in local rules" >&2
        fi
        return 1
    fi

    _suricata_backup_rules >/dev/null

    # Remove the line containing the SID
    sed -i "/sid:${sid}[^0-9]/d" "$NFTBAN_LOCAL_RULES"

    if [[ "$json_mode" == "true" ]]; then
        echo "{\"success\": true, \"sid\": $sid, \"action\": \"removed\"}"
    else
        echo ""
        echo -e "${GREEN}✓${NC} Rule with SID $sid removed"
        echo ""
        echo "To apply changes:"
        echo "  suricata-update && systemctl reload suricata"
        echo ""
    fi
}

# =============================================================================
# APPLY CHANGES
# =============================================================================

# Apply all rule changes (run suricata-update and reload)
_suricata_rules_apply() {
    local json_mode="${1:-false}"

    _suricata_check_root "applying rules" || return 1

    if ! command -v suricata-update &>/dev/null; then
        if [[ "$json_mode" == "true" ]]; then
            echo "{\"success\": false, \"error\": \"suricata-update not installed\"}"
        else
            echo -e "${RED}ERROR:${NC} suricata-update not installed" >&2
        fi
        return 1
    fi

    if [[ "$json_mode" != "true" ]]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  ⚙️  Applying Rule Changes"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  → Running suricata-update..."
    fi

    # Run suricata-update with NFTBan config files
    local update_args=""
    [[ -f "$NFTBAN_DISABLE_CONF" ]] && update_args+=" --disable-conf=$NFTBAN_DISABLE_CONF"
    [[ -f "$NFTBAN_ENABLE_CONF" ]] && update_args+=" --enable-conf=$NFTBAN_ENABLE_CONF"
    [[ -f "$NFTBAN_LOCAL_RULES" ]] && update_args+=" --local=$NFTBAN_LOCAL_RULES"

    local update_output
    if ! update_output=$(suricata-update $update_args 2>&1); then
        if [[ "$json_mode" == "true" ]]; then
            echo "{\"success\": false, \"error\": \"suricata-update failed\", \"details\": \"$(echo "$update_output" | tr '\n' ' ')\"}"
        else
            echo -e "  ${RED}✗${NC} suricata-update failed"
            echo "$update_output"
        fi
        return 1
    fi

    if [[ "$json_mode" != "true" ]]; then
        echo -e "  ${GREEN}✓${NC} suricata-update completed"
        echo "  → Reloading Suricata..."
    fi

    # Reload Suricata
    if systemctl is-active suricata.service &>/dev/null; then
        if ! systemctl reload suricata.service 2>/dev/null; then
            # Try restart if reload fails
            if ! systemctl restart suricata.service; then
                if [[ "$json_mode" == "true" ]]; then
                    echo "{\"success\": false, \"error\": \"Failed to reload Suricata\"}"
                else
                    echo -e "  ${RED}✗${NC} Failed to reload Suricata"
                fi
                return 1
            fi
        fi

        if [[ "$json_mode" != "true" ]]; then
            echo -e "  ${GREEN}✓${NC} Suricata reloaded"
        fi
    else
        if [[ "$json_mode" != "true" ]]; then
            echo -e "  ${YELLOW}⊘${NC} Suricata not running - changes will apply on start"
        fi
    fi

    if [[ "$json_mode" == "true" ]]; then
        echo "{\"success\": true, \"applied\": true}"
    else
        echo ""
        echo -e "${GREEN}✓${NC} Rule changes applied successfully"
        echo ""
    fi
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f _suricata_check_root 2>/dev/null || true
export -f _suricata_ensure_dirs 2>/dev/null || true
export -f _suricata_validate_config 2>/dev/null || true
export -f _suricata_backup_rules 2>/dev/null || true
export -f _suricata_rules_status 2>/dev/null || true
export -f _suricata_rules_list_backups 2>/dev/null || true
export -f _suricata_rules_rollback 2>/dev/null || true
export -f _suricata_category_list 2>/dev/null || true
export -f _suricata_category_set 2>/dev/null || true
export -f _suricata_sid_enable 2>/dev/null || true
export -f _suricata_sid_disable 2>/dev/null || true
export -f _suricata_sid_list 2>/dev/null || true
export -f _suricata_local_list 2>/dev/null || true
export -f _suricata_local_add 2>/dev/null || true
export -f _suricata_local_remove 2>/dev/null || true
export -f _suricata_rules_apply 2>/dev/null || true
