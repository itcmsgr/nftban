# NFTBan Install/Uninstall Enhancement - Implementation Plan

## 📋 Executive Summary

After reviewing OLD_FOR_REFERENCE, we found **excellent patterns** that should be integrated into the current version. This document provides a **step-by-step implementation plan** with code examples.

---

## 🎯 Phase 1: CRITICAL FIXES (Do Now)

### Task 1.1: Add Missing Directory Structure

**File to modify:** `/home/gituser/github/nftban/lib/installer/installer_structure.sh`

**Add these directories:**

```bash
# Around line 30-40, add to the directories array:

"$INSTALL_DIR/templates/conf"              # ← MISSING! For geo-*.conf, ddos.conf, portscan.conf
"$INSTALL_DIR/data"                        # Data directory
"$INSTALL_DIR/data/geoip"                  # GeoIP databases
"$INSTALL_DIR/data/geoip/cache"            # GeoIP cache
"$INSTALL_DIR/data/geoip/sets"             # GeoIP nftables sets
"$INSTALL_DIR/data/backups"                # System backups
"$INSTALL_DIR/cache"                       # Cache directory
"$INSTALL_DIR/cache/geoip"                 # GeoIP cache (duplicate for backward compat)
"$INSTALL_DIR/cache/autorebuild"           # Auto-rebuild tracking
"$INSTALL_DIR/templates/fail2ban/DEBIAN"   # Debian-specific fail2ban
"$INSTALL_DIR/templates/fail2ban/DEBIAN/jail.d"
"$INSTALL_DIR/templates/fail2ban/DEBIAN/filter.d"
"$INSTALL_DIR/templates/fail2ban/DEBIAN/action.d"
"$INSTALL_DIR/templates/fail2ban/REDHAT"   # RHEL-specific fail2ban
"$INSTALL_DIR/templates/fail2ban/REDHAT/jail.d"
"$INSTALL_DIR/templates/fail2ban/REDHAT/filter.d"
"$INSTALL_DIR/templates/fail2ban/REDHAT/action.d"
```

**Estimated Time:** 5 minutes
**Testing:** Run installer, verify all directories created

---

### Task 1.2: Create Comprehensive Uninstaller

**Create new file:** `/home/gituser/github/nftban/scripts/nftban_uninstall.sh`

**Copy pattern from:** `OLD_FOR_REFERENCE/nftban_chatgpt/nftban_refactor_final/scripts/nftban_uninstall.sh`

**Key sections to include:**

```bash
#!/bin/bash
# =============================================================================
# NFTBan Uninstaller
# =============================================================================

set -euo pipefail

# Source common functions
source /etc/nftban/lib/nftban_core.sh 2>/dev/null || {
    echo "ERROR: Cannot find nftban core module"
    exit 1
}

# =============================================================================
# CONFIGURATION
# =============================================================================
REMOVE_LOGS="${REMOVE_LOGS:-false}"
REMOVE_BACKUPS="${REMOVE_BACKUPS:-false}"
REMOVE_CONFIG="${REMOVE_CONFIG:-false}"
CREATE_FINAL_BACKUP="${CREATE_FINAL_BACKUP:-true}"

# =============================================================================
# CONFIRMATION
# =============================================================================
confirm_uninstall() {
    cat << EOF

╔═══════════════════════════════════════════════════════════════╗
║                                                               ║
║                    ⚠️  WARNING - UNINSTALL                    ║
║                                                               ║
╚═══════════════════════════════════════════════════════════════╝

This will remove:
  • NFTBan executables and libraries
  • Fail2ban integration
  • NFTables rules and sets
  • Command symlink (/usr/local/bin/nftban)

Optional removal (will ask):
  • Configuration files (preserved by default)
  • Log files (preserved by default)
  • Backup files (preserved by default)

What will be preserved:
  • Fail2ban service (if used by other tools)
  • NFTables service (if used by other tools)

EOF

    read -p "Proceed with uninstall? [y/N]: " response
    [[ ! "$response" =~ ^[Yy]$ ]] && { echo "Cancelled"; exit 0; }

    echo
    read -p "Remove configuration files? [y/N]: " response
    [[ "$response" =~ ^[Yy]$ ]] && REMOVE_CONFIG="true"

    read -p "Remove log files? [y/N]: " response
    [[ "$response" =~ ^[Yy]$ ]] && REMOVE_LOGS="true"

    read -p "Remove backup files? [y/N]: " response
    [[ "$response" =~ ^[Yy]$ ]] && REMOVE_BACKUPS="true"

    if [[ "$REMOVE_CONFIG" == "false" ]] || [[ "$REMOVE_LOGS" == "false" ]]; then
        read -p "Create final backup? [Y/n]: " response
        [[ "$response" =~ ^[Nn]$ ]] && CREATE_FINAL_BACKUP="false"
    fi

    echo
    echo "⏳ Starting uninstall in 3 seconds (Ctrl+C to cancel)..."
    sleep 3
}

# =============================================================================
# CLEANUP FUNCTIONS
# =============================================================================

stop_services() {
    nftban_log_info "Stopping services..."
    systemctl stop fail2ban 2>/dev/null || true
    systemctl stop nftban-login-monitor 2>/dev/null || true
    systemctl disable nftban-login-monitor 2>/dev/null || true
}

clean_nftables() {
    nftban_log_info "Cleaning nftables..."

    # Remove all nftban tables (handles inet, ip, ip6)
    nft list tables 2>/dev/null | \
    awk '/nftban|NFTBAN/ {print $2, $3}' | \
    while read family table; do
        nftban_log_debug "Removing table: $family $table"
        nft delete table "$family" "$table" 2>/dev/null || true
    done
}

clean_iptables() {
    nftban_log_info "Cleaning legacy iptables..."

    for tool in iptables ip6tables; do
        if command -v $tool &>/dev/null; then
            if $tool -S 2>/dev/null | grep -q nftban; then
                $tool -F nftban 2>/dev/null || true
                $tool -X nftban 2>/dev/null || true
            fi
        fi
    done
}

remove_fail2ban() {
    nftban_log_info "Removing Fail2ban integration..."

    rm -f /etc/fail2ban/jail.d/nftban*.conf
    rm -f /etc/fail2ban/filter.d/nftban*.conf
    rm -f /etc/fail2ban/action.d/nftban*.conf
    rm -f /etc/fail2ban/action.d/nftban*.local

    systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban 2>/dev/null || true
}

remove_cron() {
    nftban_log_info "Removing cron jobs..."

    # Remove from user crontab
    crontab -l 2>/dev/null | grep -v nftban | crontab - 2>/dev/null || true

    # Remove from system cron directories
    for dir in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly; do
        [[ -d "$dir" ]] && find "$dir" -type f -name "*nftban*" -delete 2>/dev/null || true
    done
}

remove_systemd() {
    nftban_log_info "Removing systemd units..."

    rm -f /etc/systemd/system/nftban-*.service
    rm -f /etc/systemd/system/nftban-*.timer
    systemctl daemon-reload
}

remove_logrotate() {
    nftban_log_info "Removing logrotate config..."
    rm -f /etc/logrotate.d/nftban
}

create_final_backup() {
    if [[ "$CREATE_FINAL_BACKUP" != "true" ]]; then
        return 0
    fi

    nftban_log_info "Creating final backup..."

    local backup_dir="/tmp/nftban-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"

    # Backup configuration
    [[ -d "/etc/nftban/config" ]] && cp -r /etc/nftban/config "$backup_dir/" 2>/dev/null || true

    # Backup logs
    [[ -d "/var/log/nftban" ]] && cp -r /var/log/nftban "$backup_dir/" 2>/dev/null || true

    # Backup existing backups
    [[ -d "/etc/nftban/data/backups" ]] && cp -r /etc/nftban/data/backups "$backup_dir/" 2>/dev/null || true

    # Create archive
    tar -czf "${backup_dir}.tar.gz" -C /tmp "$(basename "$backup_dir")" 2>/dev/null || true
    rm -rf "$backup_dir"

    nftban_log_success "Final backup created: ${backup_dir}.tar.gz"

    cat << EOF

═══════════════════════════════════════════════════════════════
To restore this backup:
  1. Extract: tar -xzf ${backup_dir}.tar.gz
  2. Copy config: cp -r $(basename "$backup_dir")/config/* /etc/nftban/config/
  3. Copy logs: cp -r $(basename "$backup_dir")/var/log/nftban/* /var/log/nftban/
═══════════════════════════════════════════════════════════════

EOF
}

remove_files() {
    nftban_log_info "Removing files..."

    # Remove CLI symlink
    rm -f /usr/local/bin/nftban

    # Remove installation directory (conditional)
    if [[ "$REMOVE_CONFIG" == "true" ]] && [[ "$REMOVE_LOGS" == "true" ]] && [[ "$REMOVE_BACKUPS" == "true" ]]; then
        rm -rf /etc/nftban
        rm -rf /var/log/nftban
    else
        # Selective removal
        rm -rf /etc/nftban/lib
        rm -rf /etc/nftban/bin
        rm -rf /etc/nftban/scripts
        rm -rf /etc/nftban/templates
        rm -rf /etc/nftban/cache

        [[ "$REMOVE_CONFIG" == "true" ]] && rm -rf /etc/nftban/config
        [[ "$REMOVE_LOGS" == "true" ]] && rm -rf /var/log/nftban
        [[ "$REMOVE_BACKUPS" == "true" ]] && rm -rf /etc/nftban/data/backups

        # Remove data directory if empty
        rmdir /etc/nftban/data 2>/dev/null || true
        rmdir /etc/nftban 2>/dev/null || true
    fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    nftban_check_root || exit 1

    confirm_uninstall
    create_final_backup

    stop_services
    clean_nftables
    clean_iptables
    remove_fail2ban
    remove_cron
    remove_systemd
    remove_logrotate
    remove_files

    echo
    nftban_log_success "Uninstall complete"

    if [[ "$REMOVE_CONFIG" == "false" ]] || [[ "$REMOVE_LOGS" == "false" ]]; then
        echo
        echo "Preserved files:"
        [[ "$REMOVE_CONFIG" == "false" ]] && echo "  • Configuration: /etc/nftban/config/"
        [[ "$REMOVE_LOGS" == "false" ]] && echo "  • Logs: /var/log/nftban/"
        [[ "$REMOVE_BACKUPS" == "false" ]] && echo "  • Backups: /etc/nftban/data/backups/"
    fi
}

main "$@"
```

**Estimated Time:** 30 minutes
**Testing:** Run on test system, verify clean removal

---

### Task 1.3: Enhance CLI Wrapper

**File to modify:** `/home/gituser/github/nftban/bin/nftban`

**Replace with smart fallback version:**

```bash
#!/usr/bin/env bash
# =============================================================================
# NFTBan CLI Entry Point
# Version: 1.0.0
# =============================================================================

set -euo pipefail

readonly LIB_DIR="/etc/nftban/lib"
readonly MAIN_CLI="${LIB_DIR}/nftban_main_cli.sh"

# =============================================================================
# ATTEMPT 1: Use main CLI (preferred)
# =============================================================================
if [[ -f "$MAIN_CLI" ]]; then
    exec bash "$MAIN_CLI" "$@"
fi

# =============================================================================
# ATTEMPT 2: Fallback to core module with error
# =============================================================================
if [[ -f "${LIB_DIR}/nftban_core.sh" ]]; then
    source "${LIB_DIR}/nftban_core.sh"

    cat << EOF >&2

╔═══════════════════════════════════════════════════════════════╗
║                        ⚠️  ERROR                              ║
╚═══════════════════════════════════════════════════════════════╝

Main CLI not found at: $MAIN_CLI

This usually means:
  • NFTBan installation is incomplete
  • Files were manually deleted
  • Update failed partway through

RECOVERY OPTIONS:

  Option 1 - Update/Repair:
    sudo nftban_installer.sh update

  Option 2 - Reinstall:
    sudo nftban_installer.sh install

  Option 3 - Check file integrity:
    ls -la ${LIB_DIR}/

═══════════════════════════════════════════════════════════════

EOF
    exit 1
fi

# =============================================================================
# ATTEMPT 3: Critical failure (no core module)
# =============================================================================
cat << EOF >&2

╔═══════════════════════════════════════════════════════════════╗
║                    ❌ CRITICAL ERROR                          ║
╚═══════════════════════════════════════════════════════════════╝

NFTBan is not properly installed.

Core module not found at: ${LIB_DIR}/nftban_core.sh

RECOVERY:

  1. Verify installation directory exists:
     ls -la /etc/nftban/

  2. If missing, reinstall:
     cd /path/to/nftban/source
     sudo bash lib/installer/installer_main.sh install

  3. If directory exists but files missing:
     sudo bash lib/installer/installer_main.sh repair

═══════════════════════════════════════════════════════════════

EOF
exit 1
```

**Estimated Time:** 10 minutes
**Testing:** Test all 3 scenarios (working, missing CLI, missing core)

---

## 🔧 Phase 2: MAINTENANCE MODULE ENHANCEMENT (High Priority)

### Task 2.1: Add Validation Function

**File to modify:** `/home/gituser/github/nftban/lib/nftban_maintenance_module.sh`

**Add this function:**

```bash
# =============================================================================
# CONFIGURATION VALIDATION
# =============================================================================

nftban_maintenance_validate_config() {
    nftban_log_info "Validating NFTBan configuration..."

    local errors=0

    # Check user config exists
    if [[ ! -f "${NFTBAN_CONFIG_DIR}/nftban.conf.local" ]]; then
        if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
            nftban_log_warning "User config missing, creating from default"
            cp "${NFTBAN_CONFIG_DIR}/nftban.conf" "${NFTBAN_CONFIG_DIR}/nftban.conf.local"
            chmod 600 "${NFTBAN_CONFIG_DIR}/nftban.conf.local"
        else
            nftban_log_error "No configuration files found"
            ((errors++))
        fi
    fi

    # Validate config syntax by sourcing it
    if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf.local" ]]; then
        if source "${NFTBAN_CONFIG_DIR}/nftban.conf.local" 2>/dev/null; then
            nftban_log_success "Configuration syntax valid"
        else
            nftban_log_error "Invalid syntax in configuration"
            ((errors++))
        fi
    fi

    # Check essential files
    local essential_files=(
        "${NFTBAN_CONFIG_DIR}/user-whitelist_ips.conf"
        "${NFTBAN_CONFIG_DIR}/user-blacklist_ips.conf"
        "${NFTBAN_INSTALL_DIR}/bin/nftban"
        "${NFTBAN_LIB_DIR}/nftban_core.sh"
        "${NFTBAN_LIB_DIR}/nftban_main_cli.sh"
    )

    for file in "${essential_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            nftban_log_error "Missing essential file: $file"
            ((errors++))
        fi
    done

    # Validate nftables configuration
    if [[ -f "${NFTBAN_CONFIG_DIR}/nft_rules.conf" ]]; then
        if nft -c -f "${NFTBAN_CONFIG_DIR}/nft_rules.conf" 2>/dev/null; then
            nftban_log_success "NFTables configuration valid"
        else
            nftban_log_error "Invalid NFTables configuration"
            ((errors++))
        fi
    fi

    # Validate Fail2ban configuration
    if command -v fail2ban-client &>/dev/null; then
        if fail2ban-client --test 2>/dev/null; then
            nftban_log_success "Fail2ban configuration valid"
        else
            nftban_log_warning "Fail2ban configuration may have issues"
        fi
    fi

    if [[ $errors -eq 0 ]]; then
        nftban_log_success "Configuration validation passed"
        return 0
    else
        nftban_log_error "Configuration validation failed: $errors error(s)"
        return 1
    fi
}

export -f nftban_maintenance_validate_config
```

**Estimated Time:** 15 minutes

---

### Task 2.2: Add Repair Function

```bash
# =============================================================================
# CONFIGURATION REPAIR
# =============================================================================

nftban_maintenance_repair_config() {
    nftban_log_info "Repairing NFTBan configuration..."

    # Recreate missing directories
    local required_dirs=(
        "${NFTBAN_CONFIG_DIR}"
        "${NFTBAN_LIB_DIR}"
        "${NFTBAN_INSTALL_DIR}/templates"
        "${NFTBAN_INSTALL_DIR}/data/backups"
        "${NFTBAN_LOG_DIR}"
    )

    for dir in "${required_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            nftban_log_success "Recreated directory: $dir"
        fi
    done

    # Recreate whitelist if missing
    if [[ ! -f "${NFTBAN_CONFIG_DIR}/user-whitelist_ips.conf" ]]; then
        cat > "${NFTBAN_CONFIG_DIR}/user-whitelist_ips.conf" << 'EOF'
# NFTBan User Whitelist
# IPs in this file are never banned
127.0.0.1  # Localhost IPv4
::1        # Localhost IPv6
EOF
        chmod 644 "${NFTBAN_CONFIG_DIR}/user-whitelist_ips.conf"
        nftban_log_success "Recreated whitelist file"
    fi

    # Recreate blacklist if missing
    if [[ ! -f "${NFTBAN_CONFIG_DIR}/user-blacklist_ips.conf" ]]; then
        touch "${NFTBAN_CONFIG_DIR}/user-blacklist_ips.conf"
        chmod 644 "${NFTBAN_CONFIG_DIR}/user-blacklist_ips.conf"
        nftban_log_success "Recreated blacklist file"
    fi

    # Fix permissions
    nftban_log_info "Fixing permissions..."

    # Directories: 755
    find "${NFTBAN_INSTALL_DIR}" -type d -exec chmod 755 {} \; 2>/dev/null || true

    # Config files: 644
    find "${NFTBAN_CONFIG_DIR}" -name "*.conf*" -exec chmod 644 {} \; 2>/dev/null || true

    # Library files: 644 (sourced, not executed)
    find "${NFTBAN_LIB_DIR}" -name "*.sh" -exec chmod 644 {} \; 2>/dev/null || true

    # Binary files: 755 (executed)
    find "${NFTBAN_INSTALL_DIR}/bin" -type f -exec chmod 755 {} \; 2>/dev/null || true

    # Script files: 755 (executed)
    find "${NFTBAN_INSTALL_DIR}/scripts" -name "*.sh" -exec chmod 755 {} \; 2>/dev/null || true

    nftban_log_success "Configuration repair completed"
}

export -f nftban_maintenance_repair_config
```

**Estimated Time:** 15 minutes

---

### Task 2.3: Add Health Check Function

```bash
# =============================================================================
# SYSTEM HEALTH CHECK
# =============================================================================

nftban_maintenance_health_check() {
    nftban_log_info "Performing system health check..."

    local issues=0

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  NFTBan Health Check"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    # Check services
    echo "Services:"
    for service in nftables fail2ban; do
        if systemctl is-active --quiet "$service" 2>/dev/null; then
            echo "  ✅ $service: Active"
        else
            echo "  ❌ $service: Inactive"
            ((issues++))
        fi
    done
    echo ""

    # Check nftables ruleset
    echo "NFTables:"
    if nft list ruleset >/dev/null 2>&1; then
        local table_count=$(nft list tables 2>/dev/null | grep -c -E "(nftban|NFTBAN)" || echo 0)
        echo "  ✅ Ruleset readable"
        echo "  ℹ️  NFTBan tables: $table_count"
    else
        echo "  ❌ Cannot read ruleset"
        ((issues++))
    fi
    echo ""

    # Check Fail2ban jails
    if command -v fail2ban-client &>/dev/null; then
        echo "Fail2ban:"
        local jail_count=$(fail2ban-client status 2>/dev/null | grep "Number of jail" | awk '{print $4}' || echo 0)
        local nftban_jails=$(fail2ban-client status 2>/dev/null | grep -o "nftban-[^,]*" | wc -l || echo 0)
        echo "  ℹ️  Total jails: $jail_count"
        echo "  ℹ️  NFTBan jails: $nftban_jails"
    fi
    echo ""

    # Check disk space
    echo "Disk Space:"
    local disk_usage=$(df "${NFTBAN_INSTALL_DIR}" | tail -1 | awk '{print $5}' | sed 's/%//')
    if [[ $disk_usage -gt 90 ]]; then
        echo "  ⚠️  High usage: ${disk_usage}%"
        ((issues++))
    else
        echo "  ✅ Usage: ${disk_usage}%"
    fi
    echo ""

    # Check log file sizes
    echo "Log Files:"
    if [[ -d "${NFTBAN_LOG_DIR}" ]]; then
        local total_size=$(du -sh "${NFTBAN_LOG_DIR}" 2>/dev/null | awk '{print $1}' || echo "0")
        echo "  ℹ️  Total size: $total_size"

        # Check for large logs
        find "${NFTBAN_LOG_DIR}" -type f -size +100M 2>/dev/null | while read -r large_log; do
            local size=$(du -h "$large_log" | awk '{print $1}')
            echo "  ⚠️  Large log: $(basename "$large_log") ($size)"
            ((issues++))
        done
    fi
    echo ""

    # Summary
    echo "═══════════════════════════════════════════════════════════════"
    if [[ $issues -eq 0 ]]; then
        echo "  ✅ Health check PASSED"
    else
        echo "  ⚠️  Health check found $issues issue(s)"
    fi
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    return $issues
}

export -f nftban_maintenance_health_check
```

**Estimated Time:** 20 minutes

---

## 📝 TESTING CHECKLIST

### Directory Structure:
- [ ] All directories created by installer
- [ ] `templates/conf/` exists
- [ ] `data/geoip/` exists
- [ ] OS-specific fail2ban directories exist
- [ ] Permissions are correct (755 for dirs, 644 for configs, 755 for bins)

### Uninstaller:
- [ ] Confirmation prompts work
- [ ] Selective removal works (config/logs/backups)
- [ ] Final backup created correctly
- [ ] All nftables tables removed
- [ ] All fail2ban configs removed
- [ ] All cron jobs removed
- [ ] All systemd units removed
- [ ] CLI symlink removed
- [ ] Can restore from backup

### CLI Wrapper:
- [ ] Works normally when all files present
- [ ] Shows helpful error when main CLI missing
- [ ] Shows critical error when core missing
- [ ] Error messages include recovery instructions

### Maintenance Module:
- [ ] validate_config() detects missing files
- [ ] validate_config() detects syntax errors
- [ ] repair_config() recreates missing directories
- [ ] repair_config() fixes permissions
- [ ] health_check() shows all system status
- [ ] health_check() detects issues

---

## 🎯 SUCCESS CRITERIA

### Phase 1 Complete When:
- ✅ All directories created during install
- ✅ Uninstaller has confirmation flow
- ✅ Uninstaller creates final backup
- ✅ Uninstaller preserves user data by default
- ✅ CLI wrapper has helpful error messages

### Phase 2 Complete When:
- ✅ Maintenance module can validate config
- ✅ Maintenance module can repair config
- ✅ Maintenance module can run health check
- ✅ All functions exported and callable from CLI

---

## 🚀 DEPLOYMENT STEPS

1. **Backup Current System:**
   ```bash
   cd /home/gituser/github/nftban
   git add .
   git commit -m "Backup before install/uninstall enhancements"
   ```

2. **Implement Phase 1:**
   - Add directories to installer_structure.sh
   - Create nftban_uninstall.sh
   - Update bin/nftban wrapper
   - Test on clean system

3. **Implement Phase 2:**
   - Add functions to nftban_maintenance_module.sh
   - Add CLI commands for maintenance
   - Test all maintenance functions

4. **Update Documentation:**
   - Add uninstall instructions to README
   - Add maintenance commands to help
   - Document directory structure

5. **Final Testing:**
   - Install on fresh system
   - Run all maintenance commands
   - Uninstall and verify cleanup
   - Restore from backup and verify

---

## 📞 QUESTIONS TO RESOLVE

1. Should we keep both `cache/geoip/` and `data/geoip/cache/` or consolidate?
2. Should uninstaller ask about removing packages (fail2ban, nftables)?
3. Should health check send email notifications?
4. Should we add OS detection for fail2ban template selection?
5. Should maintenance commands require confirmation or run silently?

