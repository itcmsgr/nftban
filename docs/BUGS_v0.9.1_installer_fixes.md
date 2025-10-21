# BUG35-40: Installer/Uninstaller Critical Fixes (v0.9.1)

**Fixed:** 2025-10-21
**Testing:** All 3 lab servers (CentOS 9, Ubuntu 24.04, CentOS 10)
**Status:** ✅ PRODUCTION READY

---

## BUG35: CLI Path Wrong + feeds.conf Required
- **File:** `lib/nftban_init_script.sh`
- **Issue:** Wrong CLI path in symlink + missing feeds.conf
- **Fix:** Corrected path to `/etc/nftban/bin/nftban_cli.sh` + added feeds.conf template

## BUG36: Bootstrap Installing to /tmp
- **File:** `nftban_init.sh`
- **Issue:** Files copied to /tmp instead of /etc/nftban
- **Fix:** Changed installation target to /etc/nftban before running installer

## BUG37: Symlink Resolution Broken
- **File:** `lib/installer/nftban_init_script.sh`
- **Issue:** Used `readlink` instead of `readlink -f`
- **Fix:** Added `-f` flag for full path resolution

## BUG38: Uninstall Trap EXIT Scope Error
- **File:** `lib/installer/nftban_uninstall_script.sh`
- **Issue:** `temp_cron` variable unbound in trap cleanup
- **Fix:** Initialized `temp_cron=""` at start of script

## BUG39: Uninstall Cron Patterns Incomplete
- **File:** `lib/installer/nftban_uninstall_script.sh`
- **Issue:** Only removed 3/9 cron jobs
- **Fix:** Added all 9 patterns for complete removal

## BUG40: Uninstall Cron Count Arithmetic Error
- **File:** `lib/installer/nftban_uninstall_script.sh`
- **Issue:** Bash strict mode error in count calculation
- **Fix:** Changed to `count=$((count + 1))` syntax

---

## Lifecycle Testing Results

| Server              | OS           | Install | Update | Uninstall | Config Preserved | Cron Removed |
|---------------------|--------------|---------|--------|-----------|------------------|--------------|
| lab.example.test    | CentOS 9     | ✅      | ✅     | ✅        | ✅               | ✅ (9 jobs)  |
| lab1.example.test   | Ubuntu 24.04 | ✅      | ✅     | ✅        | ✅               | ✅ (9 jobs)  |
| 198.51.100.15        | CentOS 10    | ✅      | ✅     | ✅        | ✅               | ✅ (9 jobs)  |

**Result:** 100% success rate across all platforms and all lifecycle stages.
