# MAC Profiles: SELinux and AppArmor

*As of v1.147.* Operator-facing reference for NFTBan's Mandatory Access Control
(MAC) integration: SELinux on EL/RHEL-family systems, AppArmor on Debian/Ubuntu.

NFTBan uses MAC profiles as defense-in-depth around the `nftband` daemon.

Normal Linux permissions decide whether a service may run. SELinux and AppArmor
decide what that service may access after it is running. This matters because
`nftband` manages nftables firewall state, SSH-protection sets, ban/unban state,
whitelists, and runtime firewall objects — if a bug, a bad helper path, or an
exploit reaches the daemon, the MAC profile limits what the damage can touch.

---

## 1. Why NFTBan uses MAC profiles

`nftband` runs privileged (it programs nftables via netlink). Standard
permissions answer *"can this service run?"*. MAC answers *"even as root, what
exactly is this process allowed to touch?"*.

- Without MAC: a daemon compromise has broad system reach.
- With MAC: `nftband` is confined to NFTBan paths plus the netlink/nftables
  operations it actually needs, and is blocked from everything else.

This is defense-in-depth. It does **not** replace normal file permissions,
systemd unit hardening (which v1.146 and the unit already apply), or polkit.

## 2. SELinux vs AppArmor

Both are Mandatory Access Control systems that confine a *running* process after
normal Linux permissions have already allowed execution. Linux distributions ship
different MAC systems, so NFTBan ships both:

| Family | MAC system | NFTBan profile |
|---|---|---|
| EL / RHEL family (AlmaLinux, Rocky, CentOS Stream, RHEL) | SELinux | policy module `nftban` |
| Debian / Ubuntu | AppArmor | profile `usr.lib.nftban.bin.nftband` |

## 3. What v1.147 changes

### SELinux (EL family)
- Ships the policy sources `nftban.te` / `nftban.if` / `nftban.fc` and a compiled
  `nftban.pp`, under `/usr/share/nftban/selinux/`.
- The `.pp` is compiled at **package build** via the refpolicy devel Makefile
  (`make -f /usr/share/selinux/devel/Makefile nftban.pp`); the RPM `%post`
  installs it with `semodule -i` (guarded by `selinuxenabled`), and falls back to
  compile-on-target if the prebuilt module is unavailable.
- Labels the daemon binary `/usr/lib/nftban/bin/nftband` (and `/usr/sbin/nftban`,
  `nftban-core`) as **`nftband_exec_t`**; `%post` runs `restorecon` over the
  NFTBan paths.
- Transitions the daemon from `init_t` into the **`nftband_t`** domain on exec
  (`type_transition` + entrypoint).
- Keeps **`NoNewPrivileges=true`** on the unit and still transitions, via the
  `process2:nnp_transition` permission — NNP is *not* relaxed on any host.
- Defines NFTBan file types: `nftban_conf_t` (`/etc/nftban`),
  `nftban_var_lib_t` (`/var/lib`, `/var/cache`), `nftban_log_t` (`/var/log/nftban`),
  `nftban_var_run_t` (`/run/nftban`).
- Allows the netlink/nftables operations the daemon needs, plus the system reads
  and helper executions it performs today.
- **Fixes the EL Enforcing failure** where the daemon could not program nftables:
  `cannot list tables: socket: permission denied`.

The `nftband_t` domain in v1.147 is deliberately **broad** — it reflects what the
daemon does today (it shells out to `bash`/`nft`/`iptables`/`journalctl`/
`systemctl`/`rpm`/`ssh` and reads several system resources). Tightening it is a
tracked follow-up (`D-V147-REDUCE-NFTBAND-SHELLOUTS-AND-TIGHTEN-MAC-DOMAIN`) and
must follow a reduction in daemon shell-outs, not precede it.

### AppArmor (Debian / Ubuntu)
- Ships the daemon profile to `/etc/apparmor.d/usr.lib.nftban.bin.nftband`.
- Confines the daemon path `/usr/lib/nftban/bin/nftband`.
- Default mode: **complain** (denials are logged, not enforced) for safe fleet soak.
- Profile flag **`attach_disconnected`** is required: the unit runs the daemon in a
  private mount namespace (`ProtectSystem=strict` + `ReadWritePaths` + `ProtectHome`),
  so without it AppArmor cannot resolve the systemd/dbus runtime sockets
  (`/run/systemd/notify`, etc.) and the daemon's `sd_notify` readiness fails. See §10.
- Allows NFTBan paths (read-only app tree/config; read-write only the unit's
  `ReadWritePaths`) and the netlink/nftables operations the daemon needs.
- The DEB `postinst` loads the profile with `apparmor_parser -r` (guarded by
  AppArmor being present); `postrm` removes it with `apparmor_parser -R`.

### Daemon
The daemon received **two small defensive nil-guards** (in `daemon_init.go` and
`daemon_socket.go`) so it degrades gracefully — rather than nil-panicking — when a
systemd-passed socket fd is mediated to nil under confinement. This is a robustness
fix, **not** a least-privilege redesign (that is v1.147-B). Because of these two
changes the daemon binary is **not** byte-identical to v1.146.0.

## 4. What v1.147 MAC does NOT do
- Does **not** use polkit to fix SELinux (see §5).
- Does **not** redesign the daemon's least-privilege model — that is **v1.147-B**.
- Does **not** add audit uid/gid/pid logging or whitelist/immutable-file verification
  — those are **v1.147-C**.
- Does **not** change the public JSON schema (stays `1.83.0`).
- Does **not** change NFTBan firewall ruleset semantics.
- Does **not** remove the v1.146 Shape-B boot include or change
  `nftban-firewall-init` / `nftables.service` behavior.

## 5. Why polkit is not the fix

> Polkit answers whether a *user* may request a privileged action. SELinux answers
> whether a *process domain* may access a kernel/socket/object type. If SELinux
> denies `nftband` netlink access, polkit cannot override it.

The EL Enforcing `socket: permission denied` is a kernel MAC denial against the
daemon's domain. The only correct fix is a SELinux policy module that grants the
daemon's domain the netlink/nftables access it needs — which is what v1.147 ships.

## 6. Operator commands and checks

### SELinux
```sh
sestatus                                  # Enforcing / Permissive / Disabled
semodule -l | grep nftban                 # nftban module loaded?
ps -eZ | grep nftband                     # daemon should run in ...:nftband_t:...
restorecon -Rv /usr/sbin/nftban /usr/lib/nftban/bin /etc/nftban \
  /var/lib/nftban /var/log/nftban /run/nftban /var/cache/nftban
ausearch -m avc -ts recent | grep -i nftban   # AVC denials (expect none)
```

### AppArmor
```sh
aa-status                                 # is the nftband profile loaded?
apparmor_parser -r /etc/apparmor.d/usr.lib.nftban.bin.nftband   # (re)load profile
# Mode helpers (if apparmor-utils installed):
aa-complain /etc/apparmor.d/usr.lib.nftban.bin.nftband
aa-enforce  /etc/apparmor.d/usr.lib.nftban.bin.nftband
# Denials (complain logs them without enforcing):
journalctl -k | grep -i 'apparmor=.*profile="nftband"'
dmesg | grep -i apparmor | grep nftband
```

## 7. Expected behavior

**SELinux Enforcing:** `nftband` runs in `nftband_t`; it lists and manages the
NFTBan nftables objects; no `socket: permission denied`; no NFTBan AVC denials.

**SELinux Permissive / Disabled:** install hooks are no-ops or non-disruptive
(`%post` is guarded by `selinuxenabled`); behavior is unchanged.

**AppArmor complain:** the profile is loaded; the daemon works normally; any
would-be denials are logged but not enforced. A future enforce flip is a separate
lane/release.

## 8. Troubleshooting

**SELinux module not loaded** — `semodule -l | grep nftban` empty: re-run
`semodule -i /usr/share/nftban/selinux/nftban.pp` (needs `selinuxenabled`). On EL
the policy requires the EL9+ refpolicy; EL8 is out of scope for v1.147 (see §9).

**`nftband` not labeled / wrong context** — `ps -eZ | grep nftband` shows `init_t`
instead of `nftband_t`: run the `restorecon` line in §6, then
`systemctl restart nftband`. Confirm the binary is `nftband_exec_t`
(`ls -Z /usr/lib/nftban/bin/nftband`).

**AVC denials still appear** — collect them with
`ausearch -m avc -ts recent | grep nftband` and attach to a bug report. Do not
set the domain permissive as a fix; report the denial.

**AppArmor profile not loaded** — `aa-status` does not list `nftband`: load with
`apparmor_parser -r /etc/apparmor.d/usr.lib.nftban.bin.nftband`. Confirm AppArmor
is enabled (`cat /sys/module/apparmor/parameters/enabled` = `Y`).

**Daemon stuck "activating" under AppArmor** — almost always the
`attach_disconnected` flag missing/edited out; the systemd notify socket then
fails as a "disconnected path". Confirm the profile line reads
`flags=(complain attach_disconnected)` and reload.

**Collecting evidence for a bug report** — include: distro + version,
`sestatus`/`aa-status`, `ps -eZ | grep nftband`, the relevant `ausearch`/
`journalctl -k` AppArmor lines since the daemon restart, and
`systemctl status nftband`.

## 9. Scope: distro coverage

| Family | Status (v1.147) |
|---|---|
| Ubuntu 22.04 / 24.04 / 26.04, Debian 12 / 13 (AppArmor, complain) | validated |
| AlmaLinux 9, Rocky 9, CentOS Stream 9 (SELinux Enforcing) | validated |
| EL10 family (AlmaLinux 10 / Rocky 10 / CentOS Stream 10) | validation in progress |
| EL8 (SELinux Enforcing) | out of scope / deferred — its older refpolicy lacks types the module requires |

## 10. Why `attach_disconnected` (background)

The `nftband.service` unit hardens the daemon with `ProtectSystem=strict`,
`ReadWritePaths`, and `ProtectHome`, which place it in a private mount namespace.
Inside that namespace AppArmor could not resolve `/run/systemd/notify`,
`/run/systemd/private`, or `/run/dbus/system_bus_socket` against the namespace
root — it returned a *"Failed name lookup - disconnected path"* error (EACCES)
even in complain mode. The daemon's `sd_notify(READY=1)` then never reached systemd
(the unit is `Type=notify`), so the service hung in "activating" and restart-looped.
The `attach_disconnected` profile flag attaches such paths to the namespace root so
the profile's file rules apply, which restores `sd_notify` readiness.

## 11. Related and future work
- **v1.147-B** — daemon least-privilege redesign (run as a dedicated user, reduce
  capabilities/syscalls).
- **v1.147-C** — audit-log uid/gid/pid and whitelist/immutable-file verification.
- `D-V147-REDUCE-NFTBAND-SHELLOUTS-AND-TIGHTEN-MAC-DOMAIN` — reduce daemon
  shell-outs, then tighten both the SELinux domain and the AppArmor profile and
  consider flipping AppArmor to enforce.

## See also
- `docs/THREAT_MODEL.md`
- `docs/systemd/` (unit hardening)
- Wiki: *MAC Profiles: SELinux and AppArmor*
