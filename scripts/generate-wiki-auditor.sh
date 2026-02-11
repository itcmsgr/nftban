#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Wiki Generator (Auditor View)
# =============================================================================
# meta:name="generate-wiki-auditor"
# meta:type="script"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Generate CLI Commands Reference for auditors (read-only)"
# meta:inventory.files=""
# meta:inventory.binaries="bash,yq"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Usage: ./scripts/generate-wiki-auditor.sh > wiki/CLI-Commands-Reference-Auditor.md
# Output: Markdown wiki page with auditor-visible commands only
#
# CRITICAL: This script uses 'set -Eeuo pipefail' and will EXIT IMMEDIATELY on
# any error. Never redirect both stdout AND stderr to a file (don't use &>).
# Use > for stdout only, so error messages appear on terminal, not in docs.
# =============================================================================

set -Eeuo pipefail

# SAFETY: Verify we're not being redirected incorrectly
if [[ ! -t 1 ]] && [[ ! -t 2 ]]; then
    if [[ "$(readlink -f /proc/$$/fd/1)" == "$(readlink -f /proc/$$/fd/2)" ]]; then
        echo "FATAL: Both stdout and stderr are redirected to the same file!" >&2
        echo "This would capture error messages in documentation." >&2
        echo "Use: $0 > output.md   (NOT: $0 &> output.md)" >&2
        exit 1
    fi
fi

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

# Determine registry location (installed vs development)
if [[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/commands.registry.yml" ]]; then
    # Installed location (FHS compliant)
    REGISTRY="${NFTBAN_CONFIG_DIR:-/etc/nftban}/commands.registry.yml"
else
    # Development location (relative to script)
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    REGISTRY="${PROJECT_ROOT}/commands.registry.yml"
fi

# =============================================================================
# CHECK DEPENDENCIES
# =============================================================================

if ! command -v yq &>/dev/null; then
    echo "ERROR: yq is required for YAML parsing" >&2
    exit 1
fi

# =============================================================================
# WIKI HEADER
# =============================================================================

cat <<'EOF'
# NFTBan CLI Commands Reference (Auditor View)

**Read-only reference for compliance, audit, and security operations team**

> **Auto-generated from `commands.registry.yml`** - Do not edit manually

---

## Auditor Profile

This documentation shows **read-only commands** available to users in the `nftban-auditor` group.

**What Auditors Can Do:**
- ✅ View system status and health
- ✅ Read reports, statistics, and metrics
- ✅ Search logs and check IP status
- ✅ View configuration (read-only)
- ❌ Cannot modify firewall rules
- ❌ Cannot ban/unban IPs
- ❌ Cannot enable/disable services
- ❌ Cannot change system configuration

---

## Quick Examples

```bash
# Check system status
nftban status
nftban status --json

# View health and diagnostics
nftban health check
nftban health summary

# Search for IP activity
nftban search 1.2.3.4
nftban check 1.2.3.4

# View current bans and whitelist
nftban list banned
nftban list whitelist

# Generate compliance reports
nftban report generate
nftban stats top

# View service status
nftban services status --json
```

---

## Global Options (Auditor-Safe)

| Option | Description |
|--------|-------------|
| `--json` | Output machine-readable JSON |
| `--help`, `-h` | Command-specific help |

**Note:** `--dry-run` is not needed for auditors (all commands are read-only)

---

EOF

# =============================================================================
# FILTER FUNCTION
# =============================================================================

is_auditor_visible() {
    local cmd="$1"

    # Check if auditor is in audience array
    local audience
    audience=$(yq -r ".\"$cmd\".audience[]?" "$REGISTRY" 2>/dev/null || echo "")

    echo "$audience" | grep -q "auditor"
}

# =============================================================================
# TASK GROUP GENERATOR (FILTERED)
# =============================================================================

generate_auditor_group() {
    local category="$1"
    local title="$2"
    local icon="$3"
    local description="$4"

    # Get ALL commands for this category
    local all_commands
    all_commands=$(yq -r "
        to_entries |
        map(select(.key != \"_metadata\" and .value.category == \"$category\")) |
        map(.key) |
        .[]
    " "$REGISTRY" 2>/dev/null | sort)

    # Filter for auditor visibility
    local auditor_commands=()
    for cmd in $all_commands; do
        if is_auditor_visible "$cmd"; then
            auditor_commands+=("$cmd")
        fi
    done

    # Skip empty groups
    [[ ${#auditor_commands[@]} -eq 0 ]] && return

    cat <<EOF

## $icon  $title

**$description**

| Command | Description | JSON |
|---------|-------------|------|
EOF

    for cmd in "${auditor_commands[@]}"; do
        local desc has_json
        desc=$(yq -r ".\"$cmd\".description" "$REGISTRY")
        has_json=$(yq -r ".\"$cmd\".has_json" "$REGISTRY")

        local json_icon
        [[ "$has_json" == "true" ]] && json_icon="✅" || json_icon="❌"

        echo "| \`$cmd\` | $desc | $json_icon |"
    done

    echo ""
    echo "### Command Details"
    echo ""

    # Generate detailed documentation
    for cmd in "${auditor_commands[@]}"; do
        local desc has_json examples
        desc=$(yq -r ".\"$cmd\".description" "$REGISTRY")
        has_json=$(yq -r ".\"$cmd\".has_json" "$REGISTRY")

        # Get examples array
        examples=$(yq -r ".\"$cmd\".examples[]?" "$REGISTRY" 2>/dev/null || echo "")

        cat <<EOF

#### \`nftban $cmd\`

**Description:** $desc
**JSON Support:** $has_json
**Read-Only:** ✅ Safe for auditors

EOF

        if [[ -n "$examples" ]]; then
            echo "**Examples:**"
            echo '```bash'
            echo "$examples"
            echo '```'
            echo ""
        fi
    done
}

# =============================================================================
# GENERATE FILTERED GROUPS
# =============================================================================

generate_auditor_group "setup_discovery" "Setup & Discovery" "🛠️" "System diagnostics and health checks"
generate_auditor_group "immediate_action" "Immediate Action" "⚡" "Read-only status checks"
generate_auditor_group "active_protection" "Active Protection" "🧱" "View protection module status"
generate_auditor_group "infrastructure" "Infrastructure" "⚙️" "Configuration viewing"
generate_auditor_group "intelligence_reporting" "Intelligence & Reporting" "📊" "Reports, stats, and metrics"
generate_auditor_group "developer_sysadmin" "Developer / SysAdmin" "🧪" "Diagnostic tools"

# =============================================================================
# FOOTER
# =============================================================================

cat <<'EOF'

---

## Compliance Use Cases

### Security Audit

```bash
# 1. Verify firewall structure
nftban validate all --json

# 2. Check service status
nftban services status --json

# 3. Review current bans
nftban list banned --json

# 4. Generate compliance report
nftban report generate
```

### Incident Investigation

```bash
# 1. Check system health
nftban health check

# 2. Search for IP in question
nftban search 1.2.3.4 --json

# 3. Check if IP is currently blocked
nftban check 1.2.3.4 --json

# 4. View recent statistics
nftban stats recent --json
```

### Regular Monitoring

```bash
# Daily status check
nftban status --json > /tmp/nftban-status-$(date +%Y%m%d).json

# Weekly report generation
nftban report generate --json

# Monthly metrics export
nftban stats export --json > /var/audit/nftban-monthly.json
```

---

## JSON Output for Automation

All auditor commands support `--json` for easy parsing and integration with SIEM/logging platforms.

**Standard JSON Schema:**
```json
{
  "success": true,
  "timestamp": "2025-12-31T12:34:56Z",
  "data": {
    ...command-specific data...
  }
}
```

**Example - Automated Compliance Check:**
```bash
#!/bin/bash
# Daily NFTBan compliance check

REPORT_FILE="/var/audit/nftban-$(date +%Y%m%d).json"

# Collect status
nftban status --json > "$REPORT_FILE"

# Append services status
nftban services status --json >> "$REPORT_FILE"

# Append current bans
nftban list banned --json >> "$REPORT_FILE"

# Send to SIEM
curl -X POST https://siem.example.com/api/logs \
  -H "Content-Type: application/json" \
  -d @"$REPORT_FILE"
```

---

## Access Control

### Group Membership

Auditors must be added to the `nftban-auditor` Linux group:

```bash
# Add user to auditor group (requires root)
sudo usermod -a -G nftban-auditor username

# Verify membership
groups username
```

### Permissions

Auditor group has:
- ✅ Read access to `/var/log/nftban/`
- ✅ Read access to `/var/lib/nftban/reports/`
- ✅ Read access to configuration files (via polkit)
- ❌ No write access to firewall rules
- ❌ No service control permissions

---

## Related Documentation

- **[Security Operations Guide](https://github.com/itcmsgr/nftban/wiki/Security-Operations-Guide)**
- **[Groups and Permissions](https://github.com/itcmsgr/nftban/wiki/Groups-and-Permissions)**
- **[Full CLI Reference (Operator)](./CLI-Commands-Reference.md)**

---

**Auto-generated:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')
**Source:** `commands.registry.yml`
**Profile:** Auditor (read-only)
**Group:** `nftban-auditor`

EOF
