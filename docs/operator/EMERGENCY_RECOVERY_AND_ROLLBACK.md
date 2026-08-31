# Emergency recovery and rollback

**Last verified: v1.218.5**, except sections 0 and 2 (evidence collection, rebuild
duration, safe fallback), which were verified against v1.229.12. The remaining sections
have not been re-verified since v1.218.5 and carry that stamp deliberately rather than a
bumped one.

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

## 0. Before you mutate anything: collect evidence

A host in a failed state **is evidence**. Repair, rollback, and rebuild all overwrite the
state that explains what happened. For a serious rebuild, update, or installer incident,
work in this order where it is operationally safe to do so:

1. **Establish whether protection is currently active.** This decides how much time you
   have, and it is a different question from "did the run succeed".
   ```bash
   nft list tables                    # expect: table ip nftban, table ip6 nftban
   systemctl is-active nftables nftband
   nftban health
   ```
2. **Collect the support bundle.**
   ```bash
   nftban support --output /root
   ```
   This is read-only and does not mutate the host.
3. **Preserve the bundle off-host** (`scp`, or `nftban support --email`). A later repair may
   destroy the evidence it was collected from.
4. **Read the installer/rebuild state** — `incident/timeline_installer_run.txt` and
   `incident/phase_timeline.txt` in the bundle, plus
   `/var/lib/nftban/state/install_state`.
5. **Read the validation and rollback result** —
   `incident/timeline_ruleset_lifecycle.txt`.
6. **Identify which stage actually failed**: render, apply, module re-apply, validation, or
   rollback. These have different remedies, and a terminal verdict alone does not name the
   stage.
7. **Only then** consider repair or any other mutation.

> **Do not run `nftban-installer --repair` as a first response.** Repair resumes from the
> phase recorded in the install state and re-runs it in full — which for a `FAILED_REBUILD`
> state means the entire Switch phase, including emergency SSH injection, ghost-table
> cleanup, and another complete firewall rebuild. If the original run's work actually
> succeeded, repair does substantial work to recover from nothing, and overwrites the
> evidence that would have shown that.

### A terminal verdict is not the same as a broken firewall

An installer run can report a terminal failure while the firewall is healthy and enforcing.
The two timelines in the support bundle are kept separate precisely so this is visible:
compare the **ruleset lifecycle** (render → apply → validation → rollback → live state)
against the **installer run** (phase → duration → exit → verdict). A clean ruleset lifecycle
next to a terminal installer verdict reads as a verdict problem, not a protection problem.

Note also that the installer checks its deadline when **entering** a phase. A timeout error
naming phase X can mean the deadline had already expired before X started — X may never have
run at all. Cross-check against the rebuild start/end pairs before attributing a failure to a
phase.

See [Support bundle and incident evidence](SUPPORT_BUNDLE_AND_INCIDENT_EVIDENCE.md) for how
to read each file and how to interpret `UNKNOWN` / `UNAVAILABLE` / `DANGLING`.

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

### How long a rebuild may take

A firewall rebuild on a host with large feed sets can run for **several minutes**. It is
exempt by policy from the installer's 300-second global wall-clock budget
(`cmd/nftban-installer/main.go:51`), so a long rebuild is not itself an error and is not
killed by the installer deadline.

- Since v1.229.12 the installer no longer converts a **successful** long rebuild into a
  `FAILED_REBUILD` verdict, and `nftban update` no longer imposes a separate 30-second
  timeout on the rebuild subprocess.
- The global budget is now written to `installer.log` as
  `installer global budget=300s deadline=...`, so a bundle can show what the budget was.

**A rebuild that never returns is not bounded.** The rebuild subprocess runs on
`context.Background()` (`internal/installer/switchop/rebuild.go`), so the installer's
deadline cannot terminate it, and nothing wraps the installer itself. NFTBan currently has
**no progress-aware supervision** and therefore **cannot distinguish a long rebuild from a
hung one**. If a rebuild appears stuck, diagnose it from outside the installer — check
whether `nft` is running and whether the process is consuming CPU — rather than assuming a
timeout will resolve it.

### Safe fallback ruleset

`install/nftables/nftables-safe.conf` is a minimal standalone ruleset used as a recovery
fallback. Before v1.229.12 it could not load on a host that had **no** `nftban` tables — a
bare `delete table` is a hard error and `nft` applies a file as one transaction, so it
returned `rc=1` and installed no firewall at all. That is exactly the fresh-install,
post-flush, post-uninstall, and recovery case the fallback exists for. It now declares the
empty tables before deleting them, so it loads cold as well as warm.

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
- **Collect before you repair.** `--repair` re-runs a whole phase and overwrites the state
  that explains the incident. See [section 0](#0-before-you-mutate-anything-collect-evidence).
- **A failed collection is not a zero.** In a support bundle, `UNKNOWN` and `UNAVAILABLE`
  mean the tool could not answer — never that the firewall is empty.
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
- Installer budget / phase attribution: `cmd/nftban-installer/main.go`
- Rebuild context policy (no hang supervision): `internal/installer/switchop/rebuild.go`
- Related: [Support bundle and incident evidence](SUPPORT_BUNDLE_AND_INCIDENT_EVIDENCE.md),
  [Ban forensics](BAN_FORENSICS.md), [Production baseline](PRODUCTION_BASELINE.md)
