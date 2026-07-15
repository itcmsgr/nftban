# Emergency recovery and rollback

**Last verified: v1.218.5.**

This page is the operator reference for recovering an NFTBan host after a failed update, a broken
firewall reload, an unresponsive daemon, or an accidental self-lockout. Every command and path below
is taken from the shipped code; where a `--help` string or a referenced path is stale, this page says
so and gives the real value.

## Prerequisites

- Root (or a shell that can run `nft`, `systemctl`, and the `nftban` CLI).
- NFTBan installed from an official package. The recovery paths below assume the FHS layout
  (`/usr/lib/nftban/`, `/etc/nftban/`, `/var/lib/nftban/`, `/var/log/nftban/`).
- Keep a second way into the box (console, or a second SSH session on a known-good port) before you
  start recovery work.

## 1. Roll back a failed update

`nftban update` takes a backup as its first phase, before it installs anything. If the backup step
fails, the update aborts unless you pass `--force`.

- **What is captured:** a single `tar -czf` archive of whichever of `usr/lib/nftban`,
  `usr/sbin/nftban`, and `etc/nftban` exist.
- **Where it is written:** `/var/lib/nftban/update-backups/`, as
  `nftban-<version>-<YYYYMMDD-HHMMSS>.tar.gz`.
  (Note: the `nftban rollback --help` text prints an older path, `/var/lib/nftban/update/backups/`.
  That string is stale — the real directory is `/var/lib/nftban/update-backups/`.)
- **Retention:** the newest `NFTBAN_UPDATE_BACKUP_COUNT` archives are kept (default 3); older ones are
  pruned.

Inspect backups without changing anything:

```bash
nftban update list        # list available backups
nftban update history     # update history
```

Roll back to the most recent backup:

```bash
nftban update rollback    # alias: nftban rollback
```

Rollback selects the newest `nftban-*.tar.gz`, repairs broken package state if needed, clears any
immutable flags, and extracts the archive over `/`. On a `.deb` system it re-runs
`dpkg --configure -a` afterwards. **This is destructive and has no undo** — it overwrites the current
install with the backup.

Related recovery verbs (printed by the update-failure message):

```bash
nftban update repair      # fix broken package state, clear immutable flags, optional backup restore
nftban update force       # re-run the update ignoring the abort guard
nftban update recommit    # re-validate the current install without a restart (nftban-installer --revalidate)
```

### What the update checks before it declares success

Any of these failing tells you to roll back:

- the `nftban` nftables table is present in the kernel,
- every detected SSH port is present both in the live kernel set and in durable config (lockout
  guard),
- `nftband` is active, the installed VERSION matches, and the Go validator passes.

## 2. Rebuild the firewall schema

The command is **`nftban firewall rebuild`**. (The bare `nftban rebuild` is an inert stub in this
build — it only prints that rebuild is handled by the distro package. Use the `firewall` form.)

Rebuild is safe to run for recovery because it validates before it applies:

1. renders the ruleset to a temporary file,
2. dry-run validates it with `nft -c -f`,
3. only on success does it atomically `mv` the file into place and load it in a single `nft -f`
   transaction.

If validation fails, the existing firewall is left untouched. The rendered ruleset does its
create/delete/define inside one transaction, so packets never see an empty ruleset. Before the
rebuild, NFTBan snapshots the full ruleset to `/var/lib/nftban/backup/rebuild_<timestamp>/` and backs
up the whitelist and blacklist sets (v4 and v6), so existing bans and whitelist entries are preserved
across the rebuild. If the load fails, the CLI advises `nftban firewall reset --force`.

Verify after a rebuild:

```bash
nft list tables            # must include: table ip nftban  and  table ip6 nftban
nftban health
```

## 3. Recover an unresponsive daemon

The runtime daemon is **`nftband.service`** (with `nftband.socket`). It owns IPC and ban/unban
execution.

```bash
systemctl start nftband        # or: systemctl restart nftband
nftban services                # report unit status (alias: nftban service)
nftban services fix            # auto-start stopped NFTBan services
```

Confirm recovery:

```bash
systemctl is-active nftband
nft list tables                # nftban tables present
nftban health
```

### Emergency mode (daemon down, you still need to ban/unban)

When the daemon cannot be started, NFTBan can talk to nftables directly. This is a break-glass path —
every use logs a warning:

- enable with `export NFTBAN_EMERGENCY_MODE=1`, **or** `touch /run/nftban/.emergency_unlock`,
- then `nftban ban <ip>` / `nftban unban <ip>` operate directly on the `blacklist_ipv4` /
  `blacklist_ipv6` sets.

The normal ban path always tries the daemon IPC first and only falls back to the direct path when
emergency mode is enabled.

## 4. Emergency flush

```bash
nftban flush all               # EMERGENCY: flush everything
nftban flush blacklist         # or: whitelist | feeds | geoban | ddos
```

`flush all` supports `--dry-run` and `--yes`. The system whitelist is automatically restored even
after `flush all`, so a flush does not strip your trusted-IP protection. Do not interrupt a flush
mid-run.

## 5. Recover from a self-lockout

The kernel ruleset evaluates the whitelist **before** the blacklist: `@whitelist_ipv4 … accept`
precedes the `@blacklist_manual_ipv4 … drop` and `@blacklist_ipv4 … drop` rules (and the same for
IPv6). A whitelisted address bypasses every ban check.

To recover trusted access durably:

```bash
nftban whitelist add --static <your-ip>    # writes whitelist.d/99-manual.conf; survives rebuild
```

A plain `nftban whitelist add <ip>` is runtime-only and is lost on the next rebuild — use `--static`
for recovery.

For an SSH-port lockout: NFTBan's update verification treats an SSH port that is missing from the live
kernel `tcp_ports_in` set as an error ("lockout risk"). The durable SSH port lives in
`/etc/nftban/nftban.conf.local` (`SSH_PORT=` / `TCP_PORTS_IN=`). See
[Changing the SSH port safely](../SSH-PORT-LIFECYCLE.md) for the full lifecycle.

## 6. Uninstall and reinstall

`./uninstall.sh` performs a complete removal: it stops and disables the units and (on `.deb`)
`dpkg --purge nftban-core`.

- **Without `--purge`:** `/etc/nftban` and `/var/lib/nftban` are preserved (configuration and data
  survive), so a reinstall picks up your existing config.
- **With `--purge`:** those directories are removed.

Reinstall from the official package for your distro, then confirm with `nftban health` and
`nft list tables`.

## Failure modes and caveats

- **Rollback is destructive.** It overwrites the current install with the newest backup and cannot be
  undone. Read `nftban update list` first.
- **CLI output is a report, not proof.** After any recovery, confirm kernel state with `nft list set`
  / `nft list tables`, not the CLI summary alone.
- **Emergency mode is break-glass.** It bypasses the daemon and logs a warning on every operation;
  return to the normal daemon path as soon as `nftband` is healthy.
- **`unbans.log` does not exist.** Unban events are recorded in `bans.log` with `STATUS=UNBANNED` (see
  [Ban forensics](BAN_FORENSICS.md)).

## References

- Update / rollback / repair: `cli/lib/nftban/cli/cmd_update.sh`, `cmd_update_backup.sh`
- Firewall rebuild / atomic apply: `cli/lib/nftban/cli/cmd_firewall.sh`
- Emergency IPC path: `cli/lib/nftban/lib/nft_ipc.sh`
- Flush: `cli/lib/nftban/cli/cmd_flush.sh`
- Whitelist (durable `--static`): `cli/lib/nftban/cli/cmd_whitelist.sh`
- Services: `cli/lib/nftban/cli/cmd_services.sh`
- Ruleset template (whitelist-before-blacklist ordering): `install/nftables/nftables.conf.tpl`
- Related: [Ban forensics](BAN_FORENSICS.md), [Production baseline](PRODUCTION_BASELINE.md)
