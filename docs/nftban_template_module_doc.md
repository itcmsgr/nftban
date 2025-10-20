# NFTBan Template Processing Module

**File:** `lib/nftban_template_module.sh`
**Version:** 1.0.0
**Author:** ITCMS Team (Antonios Voulvoulis)
**Purpose:** Template variable substitution and Fail2Ban jail configuration management

---

## Overview

The Template Processing Module provides comprehensive Fail2Ban jail management through template-based configuration. It handles automatic variable substitution, OS-specific template selection, and lifecycle management (deploy/undeploy/redeploy) for Fail2Ban jails integrated with NFTBan.

This module acts as a bridge between NFTBan's configuration system and Fail2Ban's jail infrastructure. It processes template files with placeholder variables (e.g., `{{BANTIME}}`, `{{MAXRETRY}}`), replacing them with actual configuration values from NFTBan's settings. The module supports multiple operating systems (Debian/Ubuntu and RedHat/CentOS families) with OS-specific template directories.

Key features include jail-specific configuration management, bulk operations (deploy/undeploy all jails), interactive menu for jail management, and template validation to ensure consistency.

---

## Key Functions

### Public Functions (Exported)

#### Jail Configuration Management

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_jail_get_config()` | Get jail-specific config value | `$1` - jail name, `$2` - parameter (BAN_TIME/MAX_RETRY/FIND_TIME/ENABLED), `$3` - default value | Config value string |
| `nftban_jail_set_config()` | Set jail-specific config value | `$1` - jail name, `$2` - parameter, `$3` - value | 0 on success |
| `nftban_jail_is_enabled()` | Check if jail is enabled | `$1` - jail name | 0 if enabled, 1 if disabled |
| `nftban_jail_ensure_config()` | Ensure jail config exists with defaults | `$1` - jail name | 0 on success |
| `nftban_jail_remove_config()` | Remove jail configuration | `$1` - jail name | 0 on success |
| `nftban_jail_list_configured()` | List all configured jails | None | Jail names (one per line) |

#### Template Processing

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_template_process()` | Process template with variable substitution | `$1` - template file, `$2` - output file, `$3` - jail name | 0 on success, 1 on error |
| `nftban_template_process_jail()` | Process all templates for a jail | `$1` - jail name, `$2` - OS (DEBIAN/REDHAT) | 0 on success, 1 on error |
| `nftban_template_detect_os()` | Detect OS for template selection | None | OS string (DEBIAN/REDHAT) |
| `nftban_template_get_available_jails()` | Get available jails for current OS | `$1` - OS (optional) | Jail names (one per line) |
| `nftban_template_exists()` | Check if template exists for jail | `$1` - jail name, `$2` - OS (optional) | 0 if exists, 1 if not |

#### Jail Deployment

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_template_deploy_jail()` | Deploy jail (process templates + enable) | `$1` - jail name, `$2` - OS (optional) | 0 on success, 1 on error |
| `nftban_template_undeploy_jail()` | Undeploy jail (remove templates + disable) | `$1` - jail name | 0 on success |
| `nftban_template_redeploy_jail()` | Redeploy jail (refresh templates) | `$1` - jail name, `$2` - OS (optional) | 0 on success, 1 on error |
| `nftban_template_deploy_all()` | Deploy all available jails | `$1` - OS (optional) | 0 if any deployed |
| `nftban_template_undeploy_all()` | Undeploy all jails | None | 0 on success |
| `nftban_template_redeploy_all()` | Redeploy all enabled jails | `$1` - OS (optional) | 0 on success |

#### Status and Listing

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_template_show_jail_status()` | Show detailed jail status | `$1` - jail name | 0 on success |
| `nftban_template_list_jails()` | List all jails with status | `$1` - OS (optional) | 0 on success |

#### Validation

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_template_validate()` | Validate template syntax | `$1` - template file | 0 if valid, 1 if invalid |
| `nftban_template_validate_all()` | Validate all templates for OS | `$1` - OS (optional) | 0 if all valid, 1 if errors |

#### Interactive

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_template_interactive_menu()` | Interactive jail management menu | None | 0 on success |

---

## Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_TEMPLATE_BASE_DIR` | `${NFTBAN_TEMPLATE_DIR}/fail2ban` | Base template directory |
| `NFTBAN_JAIL_CONFIG_PREFIX` | `NFTBAN_F2B_JAIL` | Jail configuration prefix |

### Jail Configuration Parameters

Each jail stores configuration with the pattern: `NFTBAN_F2B_JAIL_{JAIL_NAME}_{PARAMETER}`

- **ENABLED** - true/false (whether jail is deployed)
- **BAN_TIME** - Ban duration in seconds (default: 3600)
- **MAX_RETRY** - Maximum login attempts (default: 5)
- **FIND_TIME** - Time window for attempts (default: 600)

### Template Placeholders

Templates support the following variable substitution:

- `{{BANTIME}}` or `{{BAN_TIME}}` - Replaced with configured ban time
- `{{MAXRETRY}}` or `{{MAX_RETRY}}` - Replaced with max retry count
- `{{FINDTIME}}` or `{{FIND_TIME}}` - Replaced with find time window
- `{{IGNOREIP}}` - Replaced with `file:/path/to/whitelist.conf`
- `{{JAIL_NAME}}` or `{{JAIL}}` - Replaced with jail name

---

## Dependencies

**Required Modules:**
- `nftban_core.sh` - Core logging and configuration utilities

**External Commands:**
- `sed` - Template variable substitution
- `grep`, `cut`, `sort` - Text processing
- `find` - Template discovery
- `systemctl` - Fail2Ban service management (for interactive menu)

**Required Files:**
- `/etc/fail2ban/` - Fail2Ban configuration directory
- Template directories:
  - `${NFTBAN_TEMPLATE_DIR}/fail2ban/DEBIAN/`
  - `${NFTBAN_TEMPLATE_DIR}/fail2ban/REDHAT/`

---

## Usage Examples

### Example 1: Deploy a Single Jail
```bash
# Deploy SSH jail with default settings
nftban_template_deploy_jail "SSHD"

# Expected output:
# [INFO] Deploying jail: SSHD
# [INFO] Creating default configuration for jail: SSHD
# [INFO] Processing templates for jail: SSHD (OS: DEBIAN)
# [SUCCESS] Processed 3 template files for jail: SSHD
# [SUCCESS] Jail deployed successfully: SSHD

# This creates:
# - /etc/fail2ban/jail.d/nftban-sshd.conf (with substituted variables)
# - /etc/fail2ban/filter.d/nftban-sshd.conf
# - /etc/fail2ban/action.d/nftban-sshd.conf
```

### Example 2: Configure Jail Before Deployment
```bash
# Set custom configuration for SSHD jail
nftban_jail_set_config "SSHD" "BAN_TIME" "7200"
nftban_jail_set_config "SSHD" "MAX_RETRY" "3"
nftban_jail_set_config "SSHD" "FIND_TIME" "300"

# Deploy with custom settings
nftban_template_deploy_jail "SSHD"

# The template will use: bantime=7200, maxretry=3, findtime=300
```

### Example 3: List Available Jails
```bash
# List all available jails with status
nftban_template_list_jails

# Expected output:
# ═══════════════════════════════════════════════════════
#   Available Jails (OS: DEBIAN)
# ═══════════════════════════════════════════════════════
#
# No.   Jail Name            Status     Ban Time     Max Retry
# ───────────────────────────────────────────────────────────
# 1     SSHD                 ENABLED    3600s        5
# 2     APACHE_AUTH          DISABLED   3600s        5
# 3     APACHE_BADBOTS       DISABLED   3600s        5
# 4     NGINX_AUTH           DISABLED   3600s        5
# 5     POSTFIX              DISABLED   3600s        5
#
# ═══════════════════════════════════════════════════════
```

### Example 4: Check Jail Status
```bash
# Show detailed status for SSHD jail
nftban_template_show_jail_status "SSHD"

# Expected output:
# ═══════════════════════════════════════════════════════
#   Jail Status: SSHD
# ═══════════════════════════════════════════════════════
#
# Configuration:
#   Enabled: true
#   Ban Time: 3600s
#   Max Retry: 5
#   Find Time: 600s
#
# Deployed Files:
#   ✓ jail.d/nftban-sshd.conf
#   ✓ filter.d/nftban-sshd.conf
#   ✓ action.d/nftban-sshd.conf
#
# ═══════════════════════════════════════════════════════
```

### Example 5: Undeploy a Jail
```bash
# Undeploy (disable and remove files)
nftban_template_undeploy_jail "SSHD"

# Expected output:
# [INFO] Undeploying jail: SSHD
# [SUCCESS] Jail undeployed: SSHD

# This removes:
# - /etc/fail2ban/jail.d/nftban-sshd.conf
# - /etc/fail2ban/filter.d/nftban-sshd.conf
# - /etc/fail2ban/action.d/nftban-sshd.conf
# And sets ENABLED=false in config
```

### Example 6: Deploy All Jails
```bash
# Deploy all available jails for current OS
nftban_template_deploy_all

# Expected output:
# [INFO] Deploying all available jails for OS: DEBIAN
# [INFO] Deploying jail: SSHD
# [SUCCESS] Jail deployed successfully: SSHD
# [INFO] Deploying jail: APACHE_AUTH
# [SUCCESS] Jail deployed successfully: APACHE_AUTH
# ...
# [INFO] Deployment summary: 8 succeeded, 0 failed
```

### Example 7: Redeploy After Configuration Change
```bash
# Modify configuration
nftban_jail_set_config "SSHD" "BAN_TIME" "10800"

# Redeploy to apply changes
nftban_template_redeploy_jail "SSHD"

# Expected output:
# [INFO] Redeploying jail: SSHD
# [INFO] Processing templates for jail: SSHD (OS: DEBIAN)
# [SUCCESS] Jail redeployed: SSHD

# Reload Fail2Ban to apply
systemctl reload fail2ban
```

### Example 8: Interactive Jail Manager
```bash
# Launch interactive menu
nftban_template_interactive_menu

# Expected output:
# ═══════════════════════════════════════════════════════
#   nftban Jail Manager
# ═══════════════════════════════════════════════════════
#
# No.   Jail Name            Status
# ───────────────────────────────────────────────────────
# 1     SSHD                 ENABLED
# 2     APACHE_AUTH          DISABLED
# 3     NGINX_AUTH           DISABLED
# 4     POSTFIX              DISABLED
#
# Options:
#   [1-4]  Toggle jail
#   a) Enable all
#   d) Disable all
#   r) Reload fail2ban
#   q) Quit
#
# Select option: _
```

### Example 9: Check if Jail Exists
```bash
# Check if SSHD template exists
if nftban_template_exists "SSHD"; then
    echo "SSHD template found"
else
    echo "SSHD template not found"
fi
```

### Example 10: Get Available Jails Programmatically
```bash
# Get list of available jails
while IFS= read -r jail_name; do
    echo "Found jail: $jail_name"
done < <(nftban_template_get_available_jails)

# Expected output:
# Found jail: SSHD
# Found jail: APACHE_AUTH
# Found jail: APACHE_BADBOTS
# Found jail: NGINX_AUTH
# Found jail: POSTFIX
```

### Example 11: Validate Templates
```bash
# Validate all templates for current OS
nftban_template_validate_all

# Expected output:
# [INFO] Validating all templates for OS: DEBIAN
# [INFO] Validation summary: 15 valid, 0 invalid (total: 15)
# [SUCCESS] Template validation passed
```

---

## Template Structure

### Directory Layout

```
${NFTBAN_TEMPLATE_DIR}/fail2ban/
├── DEBIAN/
│   ├── jail.d/
│   │   ├── nftban-sshd.conf
│   │   ├── nftban-apache-auth.conf
│   │   └── ...
│   ├── filter.d/
│   │   ├── nftban-sshd.conf
│   │   └── ...
│   └── action.d/
│       ├── nftban-sshd.conf
│       └── ...
└── REDHAT/
    ├── jail.d/
    ├── filter.d/
    └── action.d/
```

### Template File Example (jail.d)

```ini
# /templates/fail2ban/DEBIAN/jail.d/nftban-sshd.conf
[{{JAIL_NAME}}]
enabled  = true
port     = ssh
filter   = nftban-sshd
logpath  = /var/log/auth.log
maxretry = {{MAXRETRY}}
findtime = {{FINDTIME}}
bantime  = {{BANTIME}}
action   = nftban
ignoreip = {{IGNOREIP}}
```

After processing with values (bantime=3600, maxretry=5, findtime=600):

```ini
# /etc/fail2ban/jail.d/nftban-sshd.conf
[SSHD]
enabled  = true
port     = ssh
filter   = nftban-sshd
logpath  = /var/log/auth.log
maxretry = 5
findtime = 600
bantime  = 3600
action   = nftban
ignoreip = file:/etc/nftban/config/whitelist-system.conf
```

---

## File Operations

**Reads from:**
- `${NFTBAN_TEMPLATE_DIR}/fail2ban/{OS}/jail.d/*.conf` - Jail templates
- `${NFTBAN_TEMPLATE_DIR}/fail2ban/{OS}/filter.d/*.conf` - Filter templates
- `${NFTBAN_TEMPLATE_DIR}/fail2ban/{OS}/action.d/*.conf` - Action templates
- `/etc/nftban/config/nftban.conf.local` - Jail configurations
- `/etc/os-release` - OS detection

**Writes to:**
- `/etc/fail2ban/jail.d/nftban-*.conf` - Processed jail configurations
- `/etc/fail2ban/filter.d/nftban-*.conf` - Copied filter configurations
- `/etc/fail2ban/action.d/nftban-*.conf` - Copied action configurations
- `/etc/nftban/config/nftban.conf.local` - Jail configuration storage

**Permissions:**
- All generated Fail2Ban files: `644` (readable by all)

---

## Security Considerations

### Template Variable Injection

- **Protected Against:** Template variables are simple sed replacements with no evaluation
- **No Code Execution:** Variables are static values from configuration, not user input
- **Validation:** Configuration values validated before substitution

### Jail Name Sanitization

- **Lowercase Conversion:** Jail names converted to lowercase for file paths
- **Prevents:** Path traversal via jail names with special characters
- **Safe Pattern:** `nftban-{lowercase_jail_name}.conf`

### Privilege Requirements

- **Must run as root** to:
  - Write to `/etc/fail2ban/` directory
  - Manage Fail2Ban configurations
  - Reload Fail2Ban service

### Configuration File Security

- **Jail configs stored in:** `/etc/nftban/config/nftban.conf.local`
- **Readable by:** Root only (inherited from NFTBan config)
- **Contains:** Ban times, retry counts (non-sensitive)

---

## Error Handling

**Common Errors:**

- `ERROR: Template file not found: /path/to/template` - Template missing for OS/jail
- `ERROR: No template found for jail: JAILNAME (OS: DEBIAN)` - Jail not available for OS
- `ERROR: Template directory not found: /path/to/dir` - Template directory missing
- `WARNING: No templates found for jail: JAILNAME` - No templates processed
- `WARNING: Missing placeholder: {{VARIABLE}}` - Required variable not in template
- `ERROR: Jail is not enabled: JAILNAME` - Attempted to redeploy disabled jail

**Return Codes:**
- `0` - Success
- `1` - Error (see log for details)

---

## Integration Points

**Called by:**
- `nftban_main_cli.sh` - CLI commands for jail management
- `nftban_fail2ban_module.sh` - Fail2Ban integration setup
- Admin scripts - Bulk jail deployment

**Calls:**
- `nftban_log_*` functions from `nftban_core.sh`
- `nftban_get_config()` / `nftban_set_config()` from `nftban_core.sh`
- External: `systemctl` (for Fail2Ban reload)

---

## Common Jails

### Available Jail Types

**SSH Protection:**
- `SSHD` - SSH authentication failures
- `SSHD_DDOS` - SSH connection flooding

**Web Server Protection:**
- `APACHE_AUTH` - Apache authentication failures
- `APACHE_BADBOTS` - Apache bad bot detection
- `APACHE_NOSCRIPT` - Apache script probing
- `NGINX_AUTH` - Nginx authentication failures
- `NGINX_BADBOTS` - Nginx bad bot detection

**Mail Server Protection:**
- `POSTFIX` - Postfix SMTP authentication
- `DOVECOT` - Dovecot IMAP/POP3 authentication
- `POSTFIX_SASL` - Postfix SASL authentication

**FTP Protection:**
- `VSFTPD` - vsftpd authentication failures
- `PROFTPD` - ProFTPD authentication failures

**Database Protection:**
- `MYSQL_AUTH` - MySQL authentication failures

---

## Best Practices

### Jail Configuration

1. **Start Conservative:** Begin with standard defaults (ban_time=3600, max_retry=5)
2. **Monitor First:** Deploy and monitor before adjusting settings
3. **Test Changes:** Use `redeploy` to apply configuration changes
4. **Document Customizations:** Comment why specific values were chosen

### Deployment Workflow

```bash
# 1. List available jails
nftban_template_list_jails

# 2. Review jail before deployment
nftban_template_show_jail_status "SSHD"

# 3. Customize if needed
nftban_jail_set_config "SSHD" "BAN_TIME" "7200"

# 4. Deploy
nftban_template_deploy_jail "SSHD"

# 5. Reload Fail2Ban
systemctl reload fail2ban

# 6. Verify
fail2ban-client status nftban-sshd
```

### Progressive Deployment

```bash
# Phase 1: Deploy critical services only
nftban_template_deploy_jail "SSHD"
systemctl reload fail2ban
# Monitor for 24 hours

# Phase 2: Add web servers
nftban_template_deploy_jail "APACHE_AUTH"
nftban_template_deploy_jail "NGINX_AUTH"
systemctl reload fail2ban
# Monitor for 24 hours

# Phase 3: Add mail servers
nftban_template_deploy_jail "POSTFIX"
nftban_template_deploy_jail "DOVECOT"
systemctl reload fail2ban
```

### Configuration Management

```bash
# Export current configuration
grep "^NFTBAN_F2B_JAIL_" /etc/nftban/config/nftban.conf.local > jail-backup.conf

# Document custom settings
{
    echo "# Custom jail configurations"
    echo "# Modified: $(date)"
    nftban_jail_list_configured | while read jail; do
        echo "# $jail:"
        nftban_template_show_jail_status "$jail"
    done
} > jail-documentation.txt
```

---

## Troubleshooting

### Jail Not Appearing in Fail2Ban

```bash
# 1. Check if deployed
nftban_template_show_jail_status "SSHD"

# 2. Verify files exist
ls -la /etc/fail2ban/jail.d/nftban-sshd.conf
ls -la /etc/fail2ban/filter.d/nftban-sshd.conf

# 3. Check Fail2Ban status
fail2ban-client status

# 4. Reload Fail2Ban
systemctl reload fail2ban

# 5. Check logs
journalctl -u fail2ban -n 50
```

### Template Variables Not Substituted

```bash
# 1. Check configuration exists
nftban_jail_get_config "SSHD" "BAN_TIME"

# 2. Validate template
nftban_template_validate "/path/to/template"

# 3. Redeploy
nftban_template_redeploy_jail "SSHD"

# 4. Verify output file
cat /etc/fail2ban/jail.d/nftban-sshd.conf
```

### Jail Configuration Not Saving

```bash
# 1. Check config file permissions
ls -la /etc/nftban/config/nftban.conf.local

# 2. Verify config was written
grep "NFTBAN_F2B_JAIL_SSHD" /etc/nftban/config/nftban.conf.local

# 3. Set config again with sudo
sudo nftban_jail_set_config "SSHD" "BAN_TIME" "3600"
```

---

## Performance

- **Template Processing:** ~10-50ms per jail (depends on file size)
- **Variable Substitution:** O(n) where n = template lines
- **Bulk Deployment:** ~1-2s for 10 jails
- **OS Detection:** Cached after first call
- **Configuration Reads:** Direct file access, minimal overhead

**Tested with:**
- 20+ jails deployed simultaneously
- Template files up to 500 lines
- No performance degradation

---

## Change Log

### Version 1.0.0 (2025-10-20)
- Initial release
- OS-specific template support (Debian/RedHat)
- Template variable substitution system
- Jail lifecycle management (deploy/undeploy/redeploy)
- Bulk operations support
- Interactive jail management menu
- Template validation
- Jail configuration storage in nftban.conf.local

---

## See Also

**Related Modules:**
- `nftban_fail2ban_module.sh` - Fail2Ban integration
- `nftban_core.sh` - Configuration utilities
- `nftban_nftables_module.sh` - nftables management

**Related Documentation:**
- `FAIL2BAN_INTEGRATION.md` - Fail2Ban integration guide
- `JAIL_CONFIGURATION.md` - Jail configuration reference
- `TEMPLATE_DEVELOPMENT.md` - Creating custom templates

**Configuration Files:**
- `/etc/nftban/config/nftban.conf.local` - Jail configurations
- `/etc/fail2ban/jail.d/nftban-*.conf` - Generated jail configs

**External Resources:**
- Fail2Ban Documentation: https://fail2ban.readthedocs.io/
- Fail2Ban Filters: https://github.com/fail2ban/fail2ban
