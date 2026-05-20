# CSF / lfd Removal and Takeover (DirectAdmin Hosts)

## Purpose

This document is the canonical operator procedure for disarming or removing
CSF/lfd on DirectAdmin hosts before installing or upgrading NFTBan. It
exists because manual sequences (`systemctl stop csf` + `csf -x` +
`da build remove_csf`) duplicate logic that NFTBan already encodes — and
those manual sequences omit refinements that the codified path applies
(structured cron-backup manifest, DirectAdmin `services.status` watchdog
flip, stale `systemctl --failed` marker reset).

**Rule:** Use the codified takeover command. Do not run manual disarm
sequences unless you have an explicit reason that doesn't fit the
codified path.

## The codified command

Two steps. The first is a dry-run preview. The second is the actual
disarm. Both require root.

```
nftban firewall takeover --dry-run                       # preview only
nftban firewall takeover --panel-auto-takeover           # supported takeover
```

The second form is the **supported takeover path** on panel hosts —
the wrapper invokes the installer with the real takeover authorization
internally. Use this for `install_state AUTHORITY=AMBIGUOUS` or
`CONFLICTS != (empty)`. Do **not** use `nftban update --panel-auto-takeover`
as the primary recovery action — that path forwards the flag via env
mirror for use during an actual update, but the standalone-recovery
wrapper is `nftban firewall takeover --panel-auto-takeover`.

The `--panel-auto-takeover` flag is the PR-22B opt-in for control-panel
hosts (cPanel / Plesk / DirectAdmin). It is a **permission** flag —
it permits panel-aware conflict handling but does NOT by itself
authorize takeover. The wrapper supplies the actual `--takeover`
authorizer to the installer on real (non-dry-run) calls. Without
`--panel-auto-takeover` the codified path refuses to act on panel
hosts, which is by design (PR-22B explicit opt-in gate).

`--dry-run` previews the wrapper path where supported. It runs the
installer's upgrade-mode preview (because the installer does not
implement an honest install-mode dry-run orchestrator — v1.100 PR-22B
scope). It does **not** perform conflict disarm, does **not** trigger
the authority transition, and is **not** an exact simulation of the
real install-mode takeover phases.

## What the codified path does

`nftban firewall takeover` is a discoverability surface — the actual
work happens inside the installer. As of v1.124, the wrapper invokes
the installer as:

```
nftban-installer --mode=install --takeover --force [--panel-auto-takeover]
```

(For `--dry-run` preview the wrapper falls back to
`--mode=upgrade --dry-run`, since install-mode dry-run is not
implemented in this release — v1.100 PR-22B scope boundary.)

The disarm logic is `DisableConflicts()` at
`internal/installer/switchop/takeover.go:32`.

**Important flag distinction:** `--panel-auto-takeover` is a
**permission** flag, not the takeover authorizer. The authorizer is
`--takeover`, which sets `NFTBAN_TAKEOVER=1`
(`cmd/nftban-installer/main.go:104-106`) and reaches the authority
classifier's takeover branch (`cmd/nftban-installer/phases.go:259`
→ `switchop.DisableConflicts`). Without `--takeover`, the installer
runs the upgrade lifecycle (rebuild only) and does NOT disarm
conflicts — the wrapper now passes both flags for the non-dry-run
path. **Pre-v1.124 history:** earlier versions of this doc described
the wrapper as invoking `--mode=upgrade --panel-auto-takeover`. That
was the actual code at the time and did NOT trigger the takeover
branch on hosts arriving with `install_state INSTALL_STATE=COMMITTED`;
the dns2 source-install → RPM migration (2026-05-20) surfaced the
gap.

For each conflicting service (CSF emits two entries — `csf.service`
and `lfd.service` — so each is handled independently):

- `systemctl stop` the service
- `systemctl disable` the service
- `systemctl mask` the service
- `systemctl reset-failed` the service (PR-P1, closes #524) — clears
  the stale `failed (Result: signal)` marker so `systemctl --failed`
  does not show units NFTBan just intentionally tore down

Then a legacy-firewall flush:

- For both `iptables` and `ip6tables` (if present):
  - Reset INPUT/FORWARD/OUTPUT to ACCEPT (prevents DROP-policy lockout
    during the flush)
  - Flush + delete chains in `filter`, `nat`, `mangle`

Then CSF-artifact disarm (`disarmCSFArtifacts()`):

- **Write a structured cron-backup manifest** (PR-26-code-C) under
  `/var/lib/nftban/state/csf-cron-backup/` BEFORE removing the cron
  files. The manifest records per-file `sha256 + mode + uid + gid +
  size` so the restore path (`internal/installer/restore/`) can later
  reverse the removal with fidelity. Hosts that took the manual route
  ship without a manifest; A.4 restore stays soft-skip on those hosts.
- `rm -f /etc/cron.d/lfd-cron /etc/cron.d/csf-cron`
- `mv /usr/sbin/csf /usr/sbin/csf.disabled` (sha256 byte-identical;
  no content change)

DirectAdmin-specific disarm (`disarmPanelCSF()`):

- **Flip `lfd=ON` → `lfd=OFF`** in `/usr/local/directadmin/data/admin/services.status`
  (PR26.6.1, PANEL-WATCHDOG-COHERENCE-001). Without this, `dataskq`
  emits `error=service "lfd": Unit lfd.service is masked.` every 60
  seconds. The dns2 host evidence (2026-04-30 → 2026-05-01) showed 14+
  hours of that noise on a host where the codified path was not used.
- Run `custombuild/build set csf no` to flip `csf=yes` → `csf=no` in
  `/usr/local/directadmin/custombuild/options.conf` so that
  `./build update` does not re-enable CSF.
- Audit `/usr/local/directadmin/scripts/custom/` for `csf|lfd|iptables`
  references and emit one informational `WARN` per match. This is
  informational only — operator review is recommended but not
  required.

### DA CustomBuild commands: which one nftban uses

DirectAdmin offers two CustomBuild commands for CSF; nftban uses one
and explicitly avoids the other:

| DA command | What it does | nftban uses it? |
|---|---|---|
| **`da build set csf no`** | Writes `csf=no` to `/usr/local/directadmin/custombuild/options.conf`. Tells CustomBuild "don't manage CSF on next `./build update`". Pure configuration toggle. **Files preserved.** Reversible by `da build set csf yes`. | ✅ YES — `internal/installer/switchop/takeover.go:172` |
| **`da build remove_csf`** | Destructive cleanup: physically removes `/etc/csf/`, `/etc/cron.d/csf-cron`, `/etc/cron.d/lfd-cron`, `/usr/sbin/csf`, `/usr/sbin/lfd`, `/usr/local/directadmin/plugins/csf`. **Irreversible** without backup. | ❌ NO — would destroy `/etc/csf/` and the cron-backup manifest that `nftban firewall restore csf` depends on. |

**Design rationale:** nftban's takeover is reversible-by-design. The
restore-contract Amendments 1/2/3 (`internal/installer/restore/contract.md`)
require `/etc/csf/`, `/usr/sbin/csf.disabled`, and the cron-backup
manifest to be on disk for `--mode=restore` to work. `da build remove_csf`
would destroy those prerequisites. Operators who want CSF permanently
gone can run `da build remove_csf` themselves AFTER nftban takeover
lands — that's operator territory, not nftban's responsibility.

Ghost-table cleanup (`CleanGhostTables()`, runs in `phaseSwitch` after
`DisableConflicts`):

- Removes 10 documented ghost-table candidates:
  `{ip,ip6} × {filter, nat, mangle, security}` + `inet firewalld` +
  `inet filter`. Only present-and-empty tables are deleted.
- **Does NOT clean `inet nftban_install_emergency`** — that table's
  lifecycle is managed by `InjectEmergencySSH` / `RemoveEmergencySSH`
  in `internal/installer/switchop/sshguard.go`. The codified comment
  at `ghost.go:55–58` documents this exclusion.

## What the codified path does NOT do

It does not run `da build remove_csf`. The DirectAdmin "remove" command
deletes `/etc/csf/` entirely, removes `/usr/sbin/lfd`, removes
`/usr/local/csf/`, and removes the CSF plugin from
`/usr/local/directadmin/plugins/csf`. This is more aggressive than
`DisableConflicts()` and sacrifices reversibility. The codified path
keeps `/etc/csf/` intact and only renames binaries — full reversal is
possible with `nftban firewall restore csf` or
`nftban-installer --mode=restore`.

If the operator's intent is to permanently remove CSF (not just disarm
it), `da build remove_csf` is the DirectAdmin canonical command for
that — but it is a separate decision and should be made deliberately,
not as a default disarm step.

## Reversibility

The codified disarm is reversible:

```
nftban firewall restore csf
```

Or equivalently:

```
/usr/lib/nftban/bin/nftban-installer --mode=restore
```

This relies on the cron-backup manifest (`/var/lib/nftban/state/csf-cron-backup/`).
Hosts disarmed via the manual route — where the manifest may be
absent or non-conformant — will see the restore path soft-skip
gracefully.

## Anti-patterns

These sequences are duplicate-logic and miss codified refinements:

- `systemctl stop csf lfd` + `systemctl disable csf lfd` + `csf -x`
  alone — misses PR-P1 reset-failed, misses PR26.6.1 DA watchdog
  flip, misses structured cron-backup manifest
- `csf -x` alone — flushes CSF rules but does not stop the
  `csf.service` / `lfd.service` units, does not touch DirectAdmin
  `services.status`, does not preserve cron files
- `da build remove_csf` alone — over-removes (deletes `/etc/csf/`
  including operator-curated `csf.allow` + `csf.deny`); sacrifices
  reversibility. See the companion document
  `docs/operator/UPGRADING_FROM_V1_120_AND_EARLIER.md` for the
  byte-equivalent backup recommendation if you must use this path

## When to use the codified path

Any time you need to disarm CSF/lfd to install or upgrade NFTBan on a
DirectAdmin host. This includes:

- Initial installation of NFTBan on a host that previously ran CSF
- Upgrading from a version of NFTBan that coexisted with active CSF
- Operator-decided shift from CSF to NFTBan as primary firewall
  authority

## Environment-variable equivalent

For cloud-init, Ansible, or package `%post` hooks where you need
non-interactive automation:

```
NFTBAN_PANEL_AUTO_TAKEOVER=1 nftban-installer --mode=upgrade
```

This sets the equivalent of `--panel-auto-takeover` at the
environment-variable level. The PR-22B gate semantics are unchanged.

## Code references

| Component | File | Line |
|-----------|------|------|
| CLI wrapper | `cli/lib/nftban/cli/cmd_firewall.sh` | 752 (`firewall_takeover()`) |
| Installer dispatch | `cmd/nftban-installer/main.go` | `--mode=upgrade --panel-auto-takeover` |
| Core disarm | `internal/installer/switchop/takeover.go` | 32 (`DisableConflicts()`) |
| Per-service stop+mask+reset-failed | `internal/installer/switchop/takeover.go` | 38–66 |
| iptables flush | `internal/installer/switchop/takeover.go` | 69–82 |
| `WriteCronBackupManifest()` | `internal/installer/switchop/cron_manifest.go` | 158 |
| CSF binary rename | `internal/installer/switchop/takeover.go` | 133 |
| DA watchdog flip | `internal/installer/switchop/takeover.go` | 251 (`disarmDAWatchdog()`) |
| `flipLfdWatchdogOff()` (pure function, unit-testable) | `internal/installer/switchop/takeover.go` | 285 |
| CustomBuild `set csf no` | `internal/installer/switchop/takeover.go` | 172 |
| DA custom-scripts audit | `internal/installer/switchop/takeover.go` | 199–210 |
| Ghost-table cleanup | `internal/installer/switchop/ghost.go` | 44 (`CleanGhostTables()`) |
| Ghost-table list (10 candidates) | `internal/installer/switchop/ghost.go` | 25–37 |
| Emergency-table exclusion | `internal/installer/switchop/ghost.go` | 55–58 (comment) |
| Conflict detection | `internal/installer/detect/conflicts.go` | 65 (`DetectConflicts()`) |
