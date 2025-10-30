# NFTBan Runtime Directory

**Path:** `/run/nftban/`
**Created by:** systemd-tmpfiles.d at boot
**Ownership:** nftban:nftban (0755)

## Purpose:

This directory contains transient runtime files that are cleared on reboot.

## Contents:

- `*.lock` - Flock lock files (prevents concurrent operations)
- `*.pid` - Process ID files (daemon tracking)
- Transient state (session data, temporary IPC files)

## Lifecycle:

- **Created:** At boot by systemd-tmpfiles.d
- **Cleared:** On reboot (tmpfs filesystem)
- **Not backed up:** Transient data only

## Configuration:

Managed by `/usr/lib/tmpfiles.d/nftban.conf`:

```
d /run/nftban 0755 nftban nftban - -
```

## Manual Creation:

If systemd-tmpfiles is not available:

```bash
install -d -o nftban -g nftban -m 0755 /run/nftban
```

---

**Do not store persistent data here** - Use `/var/lib/nftban/` instead.
