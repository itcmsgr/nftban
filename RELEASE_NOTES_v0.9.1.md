# NFTBan v0.9.1 - Critical Bug Fixes

**Release Date:** October 21, 2025
**Type:** Maintenance Release
**Status:** Stable

## Overview

This is a maintenance release addressing critical bugs discovered in v0.9.0. All issues have been resolved and tested on CentOS 9, Ubuntu 24.04, and CentOS 10.

---

## 🐛 Bug Fixes

### BUG21: Fixed Uninstall Command Path
- **Issue:** Uninstall command was not found in CLI
- **Fix:** Corrected path resolution in main CLI
- **Impact:** Uninstall command now works correctly

### BUG22: Fixed Cron Removal During Uninstall
- **Issue:** Cron jobs not removed during uninstall
- **Fix:** Enhanced uninstall process to clean up all cron entries
- **Impact:** Clean uninstallation without leftover cron jobs

### BUG23: Fixed Backup Restore Functionality
- **Issue:** Backup restore was failing silently
- **Fix:** Corrected restore logic and file permissions
- **Impact:** Backup/restore now works reliably

### BUG24: Standardized Version Across All Modules
- **Issue:** Version inconsistencies across different modules
- **Fix:** Unified version to 0.9.1 across all components
- **Impact:** Consistent version reporting

---

## 📋 Testing

Tested on:
- ✅ CentOS 9 Stream
- ✅ Ubuntu 24.04 LTS
- ✅ CentOS 10 Stream

All bugs verified as fixed on all platforms.

---

## 📦 Installation

```bash
# Fresh installation
bash <(curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/install.sh)

# Upgrade from v0.9.0
sudo nftban update
```

---

## 🔗 Links

- [Full Changelog](https://github.com/itcmsgr/nftban/compare/v0.8.0...v0.9.1)
- [Documentation](https://github.com/itcmsgr/nftban)
- [Report Issues](https://github.com/itcmsgr/nftban/issues)

---

## ⬆️ Upgrade Notes

If upgrading from v0.8 or v0.9.0:
1. Run: `sudo nftban update`
2. Verify installation: `nftban --version`
3. Check status: `nftban status`

No configuration changes required.
