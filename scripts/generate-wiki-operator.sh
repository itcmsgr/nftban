#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Wiki Generator (Operator View)
# =============================================================================
# meta:name="generate-wiki-operator"
# meta:type="script"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Generate complete CLI Commands Reference for operators"
# meta:inventory.files=""
# meta:inventory.binaries="bash,yq"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Usage: ./scripts/generate-wiki-operator.sh > wiki/CLI-Commands-Reference.md
# Output: Markdown wiki page with all commands (operator view)
#
# CRITICAL: This script uses 'set -Eeuo pipefail' and will EXIT IMMEDIATELY on
# any error. Never redirect both stdout AND stderr to a file (don't use &>).
# Use > for stdout only, so error messages appear on terminal, not in docs.
# =============================================================================

set -Eeuo pipefail

# SAFETY: Verify we're not being redirected incorrectly
# If both stdout AND stderr are redirected to the same file, errors would be
# captured in documentation. We detect this and exit with clear message.
if [[ ! -t 1 ]] && [[ ! -t 2 ]]; then
    # Both stdout and stderr are redirected (not a terminal)
    # Check if they're the same file (dangerous!)
    if [[ "$(readlink -f /proc/$$/fd/1)" == "$(readlink -f /proc/$$/fd/2)" ]]; then
        # This would capture errors in the output file - ABORT
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
    echo "Install: pip install yq  OR  brew install yq" >&2
    exit 1
fi

# =============================================================================
# WIKI HEADER
# =============================================================================

cat <<'EOF'
# NFTBan CLI Commands Reference

**Complete reference for all NFTBan command-line operations**

> **Auto-generated from `commands.registry.yml`** - Do not edit manually

---

## Quick Navigation

- [Quick Start](#quick-start)
- [Global Options](#global-options)
- [Task Groups](#task-groups)
  - [Setup & Discovery](#setup--discovery)
  - [Immediate Action](#immediate-action)
  - [Active Protection](#active-protection)
  - [Infrastructure](#infrastructure)
  - [Intelligence & Reporting](#intelligence--reporting)
  - [Developer / SysAdmin](#developer--sysadmin)
- [Risk Levels](#risk-levels)

---

## Quick Start

### Most Common Tasks

```bash
# I'm under attack
nftban ban 1.2.3.4
nftban ddos enable
nftban status

# Block an entire country
nftban geoban ban CN

# Check if an IP or port is blocked
nftban check 1.2.3.4
nftban check port 22

# Verify system health and auto-fix
nftban health check
nftban health fix

# Update feeds and synchronize rules
nftban feeds update
nftban sync --dry-run
```

---

## Global Options

These options work across all commands (where applicable):

| Option | Description |
|--------|-------------|
| `--json` | Output machine-readable JSON |
| `--dry-run` | Preview changes without applying (for mutating commands) |
| `--quiet` | Suppress non-essential output |
| `--verbose` | Show detailed diagnostic output |
| `--help`, `-h` | Command-specific help |

**JSON Output Contract:**
```json
{
  "success": true|false,
  "timestamp": "2025-12-31T12:34:56Z",
  "data": { ... }
}
```

---

EOF

# =============================================================================
# TASK GROUP GENERATOR
# =============================================================================

generate_task_group() {
    local category="$1"
    local title="$2"
    local icon="$3"
    local description="$4"

    # Get commands for this category
    local commands
    commands=$(yq -r "
        to_entries |
        map(select(.key != \"_metadata\" and .value.category == \"$category\")) |
        map(.key) |
        .[]
    " "$REGISTRY" 2>/dev/null | sort)

    # Skip if no commands
    [[ -z "$commands" ]] && return

    cat <<EOF

## $icon  $title

**$description**

| Command | Description | Risk | JSON | Dry-Run |
|---------|-------------|------|------|---------|
EOF

    for cmd in $commands; do
        local desc risk has_json dry_run
        desc=$(yq -r ".\"$cmd\".description" "$REGISTRY")
        risk=$(yq -r ".\"$cmd\".risk" "$REGISTRY")
        has_json=$(yq -r ".\"$cmd\".has_json" "$REGISTRY")
        dry_run=$(yq -r ".\"$cmd\".supports_dry_run" "$REGISTRY")

        # Format icons
        local risk_icon
        case "$risk" in
            core) risk_icon="⚡ Core" ;;
            setup) risk_icon="🛠️ Setup" ;;
            advanced) risk_icon="⚠️ Advanced" ;;
            *) risk_icon="$risk" ;;
        esac

        local json_icon
        [[ "$has_json" == "true" ]] && json_icon="✅" || json_icon="❌"

        local dry_icon
        [[ "$dry_run" == "true" ]] && dry_icon="✅" || dry_icon="—"

        echo "| \`$cmd\` | $desc | $risk_icon | $json_icon | $dry_icon |"
    done

    echo ""
    echo "### Command Details"
    echo ""

    # Generate detailed documentation for each command
    for cmd in $commands; do
        local desc risk has_json examples mutates
        desc=$(yq -r ".\"$cmd\".description" "$REGISTRY")
        risk=$(yq -r ".\"$cmd\".risk" "$REGISTRY")
        has_json=$(yq -r ".\"$cmd\".has_json" "$REGISTRY")
        mutates=$(yq -r ".\"$cmd\".mutates" "$REGISTRY")

        # Get examples array
        examples=$(yq -r ".\"$cmd\".examples[]?" "$REGISTRY" 2>/dev/null || echo "")

        cat <<EOF

#### \`nftban $cmd\`

**Description:** $desc

**Properties:**
- **Risk Level:** $risk
- **Mutates State:** $mutates
- **JSON Support:** $has_json

EOF

        if [[ -n "$examples" ]]; then
            echo "**Examples:**"
            echo '```bash'
            echo "$examples"
            echo '```'
            echo ""
        fi

        # Add subcommands if present
        local subcommands
        subcommands=$(yq -r ".\"$cmd\".subcommands // empty | if type == \"array\" then .[] else keys[] end" "$REGISTRY" 2>/dev/null || true)

        if [[ -n "$subcommands" ]]; then
            echo "**Subcommands:**"
            for subcmd in $subcommands; do
                echo "- \`$subcmd\`"
            done
            echo ""
        fi
    done
}

# =============================================================================
# GENERATE ALL GROUPS
# =============================================================================

generate_task_group "setup_discovery" "Setup & Discovery" "🛠️" "First-run configuration and system diagnostics"
generate_task_group "immediate_action" "Immediate Action" "⚡" "Reactive security - Firefighter mode"
generate_task_group "active_protection" "Active Protection" "🧱" "Proactive hardening - Builder mode"
generate_task_group "infrastructure" "Infrastructure" "⚙️" "Low-level firewall and policy management"
generate_task_group "intelligence_reporting" "Intelligence & Reporting" "📊" "Visibility and observability"
generate_task_group "developer_sysadmin" "Developer / SysAdmin" "🧪" "Advanced debugging and testing"

# =============================================================================
# FOOTER
# =============================================================================

cat <<'EOF'

---

## Risk Levels

| Icon | Level | Description |
|------|-------|-------------|
| ⚡ | **Core** | Essential, safe operations - recommended for all users |
| 🛠️ | **Setup** | One-time configuration - typically run during installation |
| ⚠️ | **Advanced** | Use with caution - may significantly affect system state |

---

## Common Workflows

### Initial Setup → Production

```bash
# 1. Install and verify
nftban health check
nftban validate all

# 2. Enable protection modules
nftban login enable ssh
nftban feeds enable
nftban portscan enable

# 3. Apply security profile
nftban profile apply standard

# 4. Sync and verify
nftban sync --dry-run
nftban sync
nftban status
```

### Incident Response

```bash
# 1. Check current state
nftban health check

# 2. Search for suspicious IP
nftban search 1.2.3.4

# 3. Ban if confirmed malicious
nftban ban 1.2.3.4 --reason "incident-response"

# 4. Generate incident report
nftban report generate
```

### Panel Integration

```bash
# 1. Detect hosting panel
nftban panel detect

# 2. Auto-whitelist panel infrastructure
nftban whitelist-system --dry-run
nftban whitelist-system

# 3. Open required ports
nftban port add 2087  # cPanel/WHM
nftban port add 2222  # DirectAdmin
```

---

## Troubleshooting

### Top 10 Common Errors

1. **nftables service not running**
   ```bash
   Fix: nftban health fix
   ```

2. **Permissions denied**
   ```bash
   Fix: nftban permissions fix
   ```

3. **GeoIP database missing**
   ```bash
   Fix: nftban geoip update
   ```

4. **Firewall validation failed**
   ```bash
   Fix: nftban validate firewall
   Fix: nftban firewall reload
   ```

5. **Service not enabled**
   ```bash
   Fix: nftban services status
   Fix: sudo systemctl enable --now nftban-*.service
   ```

---

## Documentation Links

- **[Installation Guide](https://github.com/itcmsgr/nftban#quick-install)**
- **[Security Architecture](https://github.com/itcmsgr/nftban/wiki/Security-Architecture)**
- **[Suricata IDS Integration](https://github.com/itcmsgr/nftban/wiki/Suricata-Integration)**
- **[Security Operations Guide](https://github.com/itcmsgr/nftban/wiki/Security-Operations-Guide)**

---

**Auto-generated:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')
**Source:** `commands.registry.yml`
**Profile:** Operator (full access)

EOF
