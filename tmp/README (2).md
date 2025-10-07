# nftban – Hardened helper for nftables + Fail2Ban (v3.3.1)

This package provides a hardened `nftban` script and two systemd integration paths:

1. **Auto-apply on file change**
   - `nftban-apply.path` watches the nftban config files under `/etc/nftban/config/`.
   - When they change, `nftban-apply.service` runs `nftban reload` with `APPLY_ON_CHANGE=true` (safe checked).

2. **Scheduled reconcile**
   - `nftban.service` runs `nftban reconcile` (safe reload).
   - `nftban.timer` schedules the service to run **hourly** (change `OnCalendar=` to suit).

## Install

```bash
# Place the script
install -m 0755 nftban.sh /usr/local/sbin/nftban

# Place systemd units
install -m 0644 nftban-apply.service /etc/systemd/system/
install -m 0644 nftban-apply.path /etc/systemd/system/
install -m 0644 nftban.service /etc/systemd/system/
install -m 0644 nftban.timer /etc/systemd/system/

# Reload systemd
systemctl daemon-reload

# Enable & start auto-apply (on file change)
systemctl enable --now nftban-apply.path

# Enable & start periodic reconcile (hourly)
systemctl enable --now nftban.timer
```

## Defaults and overrides

The script ships with these **defaults**:

- `APPLY_ON_CHANGE=true` (auto apply nftables.conf after file edits, safe-checked)
- `F2B_FORCE_BAN=true` (on `--perm-ban`, also `banip` in all Fail2Ban jails if available)
- `REQUIRE_F2B=false` (Fail2Ban is optional for checks)
- `ENABLE_LOGGING=true` (logs under `/var/log/nftban/nftban.log`)

Override per call:

```bash
APPLY_ON_CHANGE=false nftban --perm-ban 203.0.113.9 "No auto-apply"
F2B_FORCE_BAN=false nftban --perm-ban 203.0.113.9 "Skip F2B"
```

## Quick usage

```bash
# Initialize nftables structure (requires your init script to create:
# table inet nftban_global + sets temp_ban_v4/temp_ban_v6)
nftban init

# Permanently ban (writes file + runtime temp-ban + F2B mass-ban if enabled)
nftban --perm-ban 203.0.113.9 "SSH brute-force"

# Remove IP from everywhere (nft temp sets, blacklists/whitelist, Fail2Ban)
nftban --remove-ban 203.0.113.9

# List temporary bans
nftban --list-temp

# Reconcile on demand
nftban reconcile
```

## Notes

- The script avoids banning your **current login IP**.
- All file edits are **atomic**; an optional `flock` lock prevents concurrent edits.
- Reload applies only if `/etc/nftables.conf` **passes** `nft -c`.
- Fail2Ban actions run **best-effort** across all jails (if installed).
- Adjust `OnCalendar=` in `nftban.timer` to your needs (e.g., `OnCalendar=*:0/15`).
