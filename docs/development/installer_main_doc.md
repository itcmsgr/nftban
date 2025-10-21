# NFTBan Installer - Main Entry Point

**File:** `lib/installer/installer_main.sh`
**Version:** 7.0.0
**Purpose:** Modular installer main entry point with bootstrap and command routing

---

## Overview

The Installer Main module serves as the primary entry point for NFTBan's installation system. It provides bootstrap dependency checking, module loading orchestration, and command routing to appropriate installer functions. This module implements a modular architecture where each installation task (package management, download, verification, etc.) is handled by specialized modules.

Key features include automatic dependency installation, strict module loading order verification, and comprehensive command routing for all installer operations (install, update, uninstall, verify, repair, backup, restore).

---

## Key Functions

### Bootstrap Functions

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `check_and_install_dependencies()` | Check and install bootstrap tools | `$1` - --unattended flag (optional) | 0 on success, 1 on error |
| `verify_installer_modules()` | Verify all modules loaded | None | 0 if all loaded, exits on failure |
| `main()` | Command routing and execution | `$@` - command and arguments | Exit code from command |

---

## Module Loading Order

**Critical:** Modules must be loaded in this exact order due to dependencies:

1. `installer_core.sh` - Core functions, logging, utilities
2. `installer_package.sh` - Package manager & dependencies
3. `installer_download.sh` - GitHub/ZIP download
4. `installer_structure.sh` - Directory creation, permissions
5. `installer_config_full.sh` - Control panel detection
6. `installer_verification.sh` - Verify/repair
7. `installer_backup.sh` - Backup/restore operations

---

## Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `INSTALLER_DIR` | Auto-detected | Installer module directory |
| `INSTALL_DIR` | `/etc/nftban` | Installation target directory |

---

## Dependencies

**Bootstrap Dependencies (Auto-installed):**
- `tar` - Extract archives
- `gzip` - Decompress archives
- `unzip` - Unzip files
- `curl` - Download files
- `git` - Version control (optional)
- `ipcalc` - IP validation (required for nftban)

**Installer Modules (Required):**
All 7 installer modules must be present in `lib/installer/`

---

## Commands

| Command | Description | Module |
|---------|-------------|--------|
| `install` | Install nftban system | verification |
| `update`/`upgrade` | Update existing installation | verification |
| `uninstall`/`remove` | Remove nftban system | verification |
| `verify` | Verify installation integrity | verification |
| `status` | Show installation status | verification |
| `repair` | Repair broken installation | verification |
| `backup` | Create backup | backup |
| `restore` | Restore from backup | backup |
| `self-update` | Update installer itself | backup |
| `help` | Show help message | core |

---

## Usage Examples

### Example 1: Fresh Installation
```bash
# Install from GitHub (default)
sudo bash lib/installer/installer_main.sh install --github

# Install with auto-confirmation
sudo bash lib/installer/installer_main.sh install --github -y

# Install from ZIP archive
sudo bash lib/installer/installer_main.sh install --zip
```

### Example 2: Update Existing Installation
```bash
# Update from source
sudo bash lib/installer/installer_main.sh update

# Force update (no confirmation)
sudo bash lib/installer/installer_main.sh update -y
```

### Example 3: Verify Installation
```bash
# Check installation integrity
sudo bash lib/installer/installer_main.sh verify
```

### Example 4: Repair Installation
```bash
# Automatically fix issues
sudo bash lib/installer/installer_main.sh repair
```

### Example 5: Complete Uninstallation
```bash
# Uninstall with data purge
sudo bash lib/installer/installer_main.sh uninstall --purge -y
```

---

## Bootstrap Dependency Check

The installer automatically checks for and installs required bootstrap tools:

**Supported OS:**
- Debian/Ubuntu (apt)
- RHEL/CentOS/Rocky/AlmaLinux/Fedora (dnf/yum)

**Unattended Mode:**
```bash
# Auto-install dependencies without prompting
sudo bash lib/installer/installer_main.sh install --yes
```

**Manual Mode:**
```bash
# Prompt before installing dependencies
sudo bash lib/installer/installer_main.sh install
# Output:
# WARNING: Missing required dependencies: git ipcalc
# Do you want to install missing dependencies automatically? [Y/n]
```

---

## Module Verification

The installer verifies all modules loaded successfully:

```bash
# Check if each module set its LOADED flag
INSTALLER_CORE_LOADED
INSTALLER_PACKAGE_LOADED
INSTALLER_DOWNLOAD_LOADED
INSTALLER_STRUCTURE_LOADED
INSTALLER_CONFIG_LOADED
INSTALLER_VERIFICATION_LOADED
INSTALLER_BACKUP_LOADED
```

**If any module fails to load:**
```
ERROR: Module not loaded: INSTALLER_CORE_LOADED
FATAL: 1 installer module(s) failed to load
```

---

## Error Handling

**Bootstrap Errors:**
- Missing OS release file: Cannot detect OS
- Unsupported OS: Manual dependency installation required
- Package installation failure: Check network and repositories

**Module Loading Errors:**
- Missing module file: FATAL exit with error message
- Failed to source module: FATAL exit with error message
- Module verification failure: Lists missing modules and exits

---

## Security Considerations

### Root Requirement
- Installer must run as root (checked by modules)
- Package installation requires root
- Directory creation requires root

### Dependency Installation
- Only installs from official repositories
- Uses package manager's GPG verification
- No arbitrary code execution from downloads

---

## See Also

**Related Modules:**
- All other installer modules (loaded by this)

**Documentation:**
- Individual installer module documentation

**Usage:**
- Run `sudo bash lib/installer/installer_main.sh help`
