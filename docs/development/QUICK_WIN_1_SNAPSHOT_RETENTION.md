# Quick Win #1: Pre-Reload Snapshot with Retention Policy

**Date**: 2025-11-02
**Status**: ✅ COMPLETED
**Commit**: f86f763
**Implementation Time**: 30 minutes

## Overview

Implemented automatic snapshot retention policy for nftables ruleset backups. This feature prevents the `/var/backups/nftban/` directory from growing indefinitely while maintaining sufficient rollback history.

## Implementation

### What Was Changed

**File**: `src/usr/lib/nftban/core/nftban_nftables.sh`
**Function**: `backup_ruleset()`

Added automatic cleanup to keep only the last 10 timestamped snapshots:

```bash
# Retention policy: keep last 10 snapshots
# shellcheck disable=SC2012
ls -t "${BACKUP_DIR}"/ruleset-*.nft 2>/dev/null | tail -n +11 | xargs -r rm -f
```

### How It Works

1. **Automatic Backup**: Every time `nftban_atomic_reload()` is called, the `backup_ruleset()` function:
   - Creates a timestamped snapshot: `/var/backups/nftban/ruleset-YYYYMMDD-HHMMSS.nft`
   - Creates a symlink to latest: `/var/backups/nftban/backup-latest.nft`
   - Runs cleanup to keep only last 10 snapshots

2. **Retention Logic**:
   - Lists all `ruleset-*.nft` files sorted by modification time (newest first)
   - Keeps the first 10 (most recent)
   - Deletes all older snapshots
   - Uses `xargs -r` for safe deletion (handles empty lists)

3. **Rollback Capability**:
   - Existing `nftban-rollback` script can restore from backups
   - Manual rollback: `sudo nftban-rollback --force`
   - Automatic rollback via systemd timer (if configured)

## Testing

Deployed to all 4 lab servers:
- lab4.mywebhost.gr ✅
- lab.mywebhost.gr ✅
- lab1.mywebhost.gr ✅
- lab2.mywebhost.gr ✅

## Benefits

1. **Prevents disk space issues**: No infinite growth of backup directory
2. **Maintains rollback history**: 10 snapshots = sufficient history for most scenarios
3. **Zero-risk enhancement**: No change to existing functionality, only cleanup
4. **Automatic**: No manual intervention required

## Related Files

- `/var/backups/nftban/` - Backup storage location
- `src/usr/sbin/nftban-rollback` - Emergency rollback script
- `src/packaging/systemd/nftban-rollback.service` - Systemd rollback service
- `src/packaging/systemd/nftban-rollback.timer` - Systemd rollback timer

## Next Steps

According to `/tmp/NFTBAN_v0.10.0_QUICK_WINS.md`, the next recommended quick wins are:

### Phase 1 (This Week):
1. ✅ **Pre-Reload Snapshot** (DONE - this feature)
2. ⏭️ **Systemd Service Hardening** (1 hour) - Add security directives to systemd units

### Phase 2 (Next Week):
3. ⏭️ **Dry-Run Mode** (2 hours) - Add `--dry-run` flag to commands
4. ⏭️ **Config Doctor** (3 hours) - Self-diagnostic health check command

## References

- Quick Wins Document: `/tmp/NFTBAN_v0.10.0_QUICK_WINS.md`
- ChatGPT Architectural Review: `/tmp/claude30oct/NFTABLES_GO_architect_HLD2_chat_gpt_reply`
- Commit: https://github.com/itcmsgr/nftban/commit/f86f763
