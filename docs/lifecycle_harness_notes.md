# lifecycle_deb_matrix.sh — derivation notes and evidence

Deliverable pair:

- `lifecycle_deb_matrix.sh` — the harness (1276 lines, ~152 assertion call sites,
  `shellcheck -S error` clean, `bash -n` clean).
- this file — evidence table + the honest list of what could not be implemented faithfully.

## 0. Evidence discipline used here

I did **not** execute anything against a VM, a package, or a Go toolchain (none of those
are available on this box, and the task forbids ssh / repo mutation). So the labels mean:

| Label | Meaning in this document |
|---|---|
| **MEASURED** | I opened the file and read the cited lines. The *source text* is a measurement. Also: `shellcheck -S error` and `bash -n` were actually run on the harness, and the harness's pure helpers were exercised in a self-test that showed them failing as well as passing. |
| **INFERRED** | Derived from a code path I read, plus documented Linux/systemd/dpkg semantics. Not observed at runtime. |
| **NOT_YET_VERIFIED** | I could not establish it from the repo, and it must be established on the VM. |

The harness is written so that every INFERRED induction is *self-checked*: if the
injection does not take effect, the case reports **FAIL** ("injection did not take
effect"), never PASS. A case that cannot be induced at all reports **SKIP**, and the
harness then refuses to print a success verdict (`NFTBAN_MATRIX_VERDICT=INCOMPLETE`,
exit 2).

## 0b. Repo state caveat — the working tree moved under me

`git log -1` = `fda1603e test(packaging): package-level T8 + DEB/RPM parity for the
post-install gate`, but the working tree is **dirty** while I was reading it:

```
 M packaging/build_nftban.sh
 M packaging/deb/postinst
 M scripts/ci/tests/package_postinstall_verify_test.sh
```

`packaging/deb/postinst` grew from 538 to 551 lines *during* this session (a new
"no-installer path" block was added at lines 489–502). All line numbers below are
against the **working tree as of the end of this session**; re-verify with
`git diff` before quoting them elsewhere. The Item 2 block itself (postinst:356–398)
did not move.

---

## 1. Evidence table

### 1.1 Package identity and what dpkg owns

| Claim | Evidence | Status |
|---|---|---|
| Binary package name is `nftban-core` (source stanza also `nftban-core`) | `packaging/deb/control:1,13`; generated control at `packaging/build_nftban.sh:1896` | MEASURED |
| Artifact filename is `nftban-core_${PKG_VERSION}_amd64.deb` | `packaging/build_nftban.sh:2358` | MEASURED |
| `PKG_VERSION` comes from the repo `VERSION` file | `packaging/build_nftban.sh:46` | MEASURED |
| The DEB is built with raw `dpkg-deb --build` — **no debhelper** | `packaging/build_nftban.sh:2372` | MEASURED |
| Consequence: `#DEBHELPER#` in postinst/prerm/postrm is inert text, so there is no `dh_installsystemd` enable/start/disable. Unit enablement is owned by the Go installer. | `packaging/deb/postinst:549`, `prerm:136`, `postrm:249` + `install/packaging/systemd/nftban-systemd-install.list:11-13` (comment states runtime-controlled enablement) | INFERRED (from the two MEASURED facts) |
| `/usr/lib/nftban/VERSION` is shipped in the payload and is the expected-version source for the gate | `packaging/build_nftban.sh:2133-2137`, read at `packaging/deb/postinst:381` | MEASURED |
| conffiles are **generated** from the staged tree: every `/etc/nftban/**/*.conf`, botguard `conf.d/**/*.yaml|yml`, `/etc/sysctl.d/90-nftban.conf`; `*.default`, `*.example`, `*.local` excluded | `packaging/build_nftban.sh:2024-2048` | MEASURED |
| Consequence: `*.local` operator overrides are **never** dpkg-managed, so they are the strongest "operator override preserved" fixture | same | INFERRED |
| Package-owned file inventory is enumerable at runtime via `dpkg -L nftban-core` | standard dpkg behaviour | INFERRED |

### 1.2 systemd units and timers

| Claim | Evidence | Status |
|---|---|---|
| Daemon units the installer enables+starts: `nftband.socket`, then `nftband.service` | `internal/installer/services/daemon.go:65-91` | MEASURED |
| The `daemon_active` assertion checks exactly `nftband.service` | `internal/installer/validate/assertions.go:289-292` | MEASURED |
| Core timers reconciled (enable+start) — 9 units: maintenance, health, unified-exporter, core-geoip, core-feeds, watchdog, queue, update-check, geoban-refresh | `internal/installer/services/timers.go:29-38` | MEASURED |
| Optional timers (only if unit file exists): `nftban-botscan.timer`, `nftban-botscan-collector.timer` | `internal/installer/services/timers.go:41-44` | MEASURED |
| **Critical** timer set — the only one whose absence DEGRADEs the install — is `nftban-maintenance.timer` alone | `internal/installer/services/timers.go:98-100` + `CriticalCoreTimers()` 102-108 | MEASURED |
| Critical-timer rule: enabled **AND** active-or-scheduled; `NFTBAN_RECONCILE_CORE_TIMERS=false` turns it into an intentional Skipped-OK | `internal/installer/validate/timers.go:68-80`, gather at `timers_gather.go:34-52`, default-true at `services/timers.go:137-157` | MEASURED |
| Full shipped unit inventory (54 units incl. `nftban-alert@.service`) | `install/packaging/systemd/nftban-systemd-install.list` | MEASURED |
| `failed_units_postinstall_ok` only counts units matching `nftban*`/`nftband*`, and `nftban-unified-exporter` is auxiliary (non-fatal) | `internal/installer/validate/systemd_payload.go:75-92,102-104`, `validate/failed_units.go:18-24` | MEASURED |

Harness choice: it hard-asserts all **9 core timers** enabled+active plus the critical
one, and asserts the failed-nftban-unit count is zero. Rationale: `ReconcileTimers`
enables+starts all nine, so a non-active core timer is a genuine finding even though
only the critical one drives DEGRADED.

### 1.3 State file: path, fields, vocabulary

| Claim | Evidence | Status |
|---|---|---|
| State file is `/var/lib/nftban/state/install_state` | `internal/installer/state/file.go:31,34,151-153` | MEASURED |
| Lock file is `/var/lib/nftban/state/installer.lock` | `internal/installer/state/file.go:39,45-50` | MEASURED |
| Persisted schema keys used by the harness: `INSTALL_STATE`, `INSTALL_MODE`, `INSTALL_VERSION`, `INSTALL_TIMESTAMP`, `PHASE_REACHED`, `FAILURE_REASON`, `SERVICES_FAILED` | `internal/installer/state/file.go:54-71` (contract) and 248-266 (writer) | MEASURED |
| Writes are atomic (tmp + rename) | `internal/installer/state/file.go:236-295` | MEASURED |
| `INSTALL_VERSION` = ldflags-injected `pkg/version.Version` = repo `VERSION` | `cmd/nftban-installer/main.go:154` (`sf.Version = version.Version`), `pkg/version/version.go:33`, `build.sh:126` | MEASURED |
| Terminal state vocabulary: `COMMITTED`, `DEGRADED`, `FAILED_SSH_UNKNOWN`, `FAILED_AUTHORITY_ABORT`, `FAILED_RENDER`, `FAILED_REBUILD`, `FAILED_NO_FIREWALL`, `FAILED_TAKEOVER`, `FAILED_PREFLIGHT_DISK_SPACE` (+ uninstall/restore terminals) | `internal/installer/state/machine.go:24-36,55,85,95,110-177` | MEASURED |
| Installer exit contract: 0 COMMITTED, 1 DEGRADED, 2 FAILED, 3 ABORTED, 4 FATAL, 5 REFUSED, 6 INTENT_REQUIRED, 7–10 restore | `internal/installer/state/machine.go:192-229` | MEASURED |
| Verdict vocabulary (10): `CURRENT_COMMITTED`, `STALE_STATE`, `VERSION_MISMATCH`, `INSTALL_FAILED`, `INSTALL_DEGRADED`, `MISSING_STATE`, `INVALID_STATE`, `DRY_RUN_NOT_APPLIED`, `STATE_READ_ERROR`, `INVALID_INVOCATION` | `internal/installer/postinstall/verify.go:69-95` | MEASURED |
| Only `CURRENT_COMMITTED` counts as verified | `internal/installer/postinstall/verify.go:99` | MEASURED |
| Verifier exit mapping: 0 verified, 2 any determinate non-verified verdict, 4 invalid invocation | `cmd/nftban-installer/verify_mode.go:96-100,114-120,126-131` | MEASURED |
| Verifier emits `installerExit = -1` sentinel (it is invoked without one) | `cmd/nftban-installer/verify_mode.go:142` + `postinstall/verify.go:273` | MEASURED |
| The 8 canonical tokens are emitted by the installer only; the scriptlet adds 3 package-context tokens | `postinstall/verify.go:265-274` vs `packaging/deb/postinst:391-397` | MEASURED |

### 1.4 The Item 2 plumbing in the DEB scriptlet

| Claim | Evidence | Status |
|---|---|---|
| Mode selection: `$2` non-empty ⇒ `upgrade`, else `install`; announced on stdout | `packaging/deb/postinst:303-307,349` | MEASURED |
| `NOT_BEFORE` is captured with nanosecond precision immediately before the mutating call | `packaging/deb/postinst:365` | MEASURED |
| Mutating call is errexit-safe (`\|\| INSTALLER_EXIT=$?`) | `packaging/deb/postinst:368` | MEASURED |
| Verifier runs **unconditionally** after every installer outcome, family-flag-free | `packaging/deb/postinst:383-387` | MEASURED |
| Package-context tokens on the normal path: `NFTBAN_PACKAGE_INSTALLER_EXIT`, `NFTBAN_PACKAGE_VERIFY_EXIT`, `NFTBAN_PACKAGE_POSTINSTALL_VERIFIED` | `packaging/deb/postinst:391-397` | MEASURED |
| Tokens reach the operator through plain `echo` on postinst stdout, i.e. through apt/dpkg output | same | INFERRED (harness runs apt with `-o Dpkg::Use-Pty=0` so the lines are not pty-mangled) |
| **New during this session:** a missing/non-executable installer now emits `NFTBAN_PACKAGE_INSTALLER_EXIT=127`, `NFTBAN_PACKAGE_VERIFY_EXIT=127`, `..._POSTINSTALL_VERIFIED=NO` | `packaging/deb/postinst:486-502` | MEASURED |
| The postinst exits 0 on every one of these paths (`exit 0` at end of `configure`) | `packaging/deb/postinst:551` (`exit 0`) | MEASURED |

### 1.5 Terminal-state induction (the part that had to be derived, not invented)

| Terminal state | Code path | Controlled, reversible induction | Status |
|---|---|---|---|
| `FAILED_NO_FIREWALL` | `switchop.EnableNftables` returns an error when `systemctl start nftables` fails or the unit is not active afterwards (`internal/installer/switchop/enable.go:41-46`) → `cmd/nftban-installer/phases.go:476 Transition(StateFailedNoFirewall)` | `systemctl mask nftables.service` before the transaction; `systemctl unmask` after | Path MEASURED; that masking makes `ServiceStart` fail is **INFERRED** |
| `FAILED_AUTHORITY_ABORT` | `extfw.Detect` records a UFW conflict iff `ufw.service` is active (`internal/installer/extfw/detect.go:178-184`) → `authority.Classify` returns `Abort` with no takeover approval (`internal/installer/authority/classify.go:157-164`) → `phases.go:245 Transition(StateFailedAbort)`, installer exit 3 (`machine.go:390`) | `systemctl start ufw.service` **without** `ufw enable` (unit becomes active, no rules applied); stop it afterwards | Path MEASURED; that `systemctl start ufw` yields `is-active=active` with the firewall disabled is **INFERRED** — the harness measures `is-active` and SKIPs the sub-case if it is not `active` |
| `DEGRADED` | critical-timer assertion fails in VALIDATE_1, permissions-enforce retry does not fix a mask, VALIDATE_2 still fails → `phases.go:736 Transition(StateDegraded)`, installer exit 1 | `systemctl mask nftban-maintenance.timer` on an already-installed host, then reinstall; unmask after | Path MEASURED; that a masked unit reports `is-enabled != enabled` / `is-active != active` is **INFERRED** |

Note on the ABORT induction: stock Ubuntu ships `ufw` and `ufw.service` may be active on
a fresh image. If it is, **every** install on that host would classify as ABORT. The
harness therefore stops+disables `ufw.service` in its baseline (and prints the pre-existing
value), so the happy-path cases are not silently pre-aborted, and re-enables it only for
the 6b sub-case. This is recorded in the run output, not hidden.

### 1.6 Existing test/injection hooks — searched for, and what was found

| Question | Evidence | Status |
|---|---|---|
| Is there a runtime injection hook to force a terminal state? | `cmd/nftban-installer/inject.go:32-45` — `assertionTestInjection` is an **unexported Go-test-only DATA carrier** (systemd payload / health profile / logrotate validator). It is set from tests, never from flags or env: "never populated in production (nil)" | MEASURED |
| Any abort/inject environment variable? | Full sweep of `Getenv` in `cmd/nftban-installer/` + `internal/installer/`: only `NFTBAN_TAKEOVER`, `NFTBAN_INSTALLER_LOG`, `NFTBAN_PANEL_AUTO_TAKEOVER`, `NFTBAN_LIFECYCLE`, `NFTBAN_SOURCE_DIR`, `NFTBAN_DEBUG`, `NFTBAN_RUN_ID`, `NFTBAN_OPERATOR_SESSION_IP`, `SSH_CLIENT`, `NFTBAN_MIN_DISK_FREE_MB`, `NFTBAN_RECONCILE_CORE_TIMERS`, `NFTBAN_ALLOW_REMOVE_INET_FILTER` | MEASURED |
| Would a bad `NFTBAN_INSTALLER_LOG` abort pre-StateFile? | No — `logging.New` never fails: `internal/installer/logging/logger.go:62-90` swallows MkdirAll/OpenFile errors | MEASURED |
| Does `NFTBAN_MIN_DISK_FREE_MB` give a pre-Transition exit? | No — it produces `FAILED_PREFLIGHT_DISK_SPACE`, which **writes** state (`phases.go:262-265`), so it is not the T9 class | MEASURED |
| Lock contention (the T8 mechanism) | `cmd/nftban-installer/main.go:107-115` — `lock.Acquire` failure ⇒ `os.Exit(75)` **before** the StateFile is constructed (main.go:134) | MEASURED |
| Existing fixture-level T8 already in the repo | `scripts/ci/tests/package_postinstall_verify_test.sh` — 3 tiers, extracts the real block from `packaging/deb/postinst`, stubs the installer, tier 3 needs `NFTBAN_INSTALLER_BIN` | MEASURED |

### 1.7 remove vs purge — the declared DEB policy

| Behaviour | Evidence | Status |
|---|---|---|
| `prerm remove\|deconfigure` stops the full shipped active-unit list (53 unit names) via `deb-systemd-invoke stop`; **does not disable them**. Only the deprecated units (`nftban-login-monitor`, `nftban-api`, `nftban-ui*`) are additionally `systemctl disable`d, and the `nftban-ui*` trio is masked/removed | `packaging/deb/prerm:51-125` | MEASURED |
| `postrm remove` deletes the generated health-resource drop-in, **deletes** (not flushes) `ip nftban` and `ip6 nftban`, strips the fenced include from `/etc/nftables.conf` and `/etc/sysconfig/nftables.conf`, unloads the AppArmor profile | `packaging/deb/postrm:188-242` | MEASURED |
| `postrm remove` prints the documented uninstall-consequence text ("no longer protecting this system", "Config preserved in /etc/nftban/") | `packaging/deb/postrm:218-223` | MEASURED |
| On `remove`, `/etc/nftban` **and `/var/lib/nftban`** (hence `install_state`) are **retained** | `packaging/deb/postrm:188-242` contains no removal of either | MEASURED |
| Consequence for L8: a same-version prior `COMMITTED` **survives** an uninstall and is present at reinstall time — exactly the stale-evidence trap Item 2 exists for | derived from the above | INFERRED |
| `postrm purge` backs config up to `/var/tmp/nftban-config-backup-<ts>`, removes `/run/nftban`, purges all units via `deb-systemd-helper purge`, deletes the nft tables, removes tmpfiles/logrotate/sysctl/polkit/AppArmor artifacts and the yq symlink, removes statoverrides, then `rm -rf /etc/nftban /var/lib/nftban /var/log/nftban /var/cache/nftban /usr/share/nftban` | `packaging/deb/postrm:41-186` | MEASURED |
| Neither `prerm` nor `postrm` invokes `--verify-install-state` or `--not-before` | grep of both files: zero hits | MEASURED |

### 1.8 `nftban validate`

| Claim | Evidence | Status |
|---|---|---|
| Registry: read-only, `mutates: false`, text+json | `commands.registry.yml:312-326` | MEASURED |
| Exit status contract: **0** PROTECTED/IDLE, **1** DEGRADED, **2** DOWN, **3** validator crashed/unreachable | `cli/lib/nftban/cli/cmd_validate.sh:147-151` | MEASURED |
| It returns the nft-structure rc; the central-comms section it prints does **not** change that rc | `cli/lib/nftban/cli/cmd_validate.sh:104-120` | MEASURED |
| It checks required tables `ip nftban`/`ip6 nftban`, forbidden `inet filter`/`ip filter`, required sets, chain policies | `cli/lib/nftban/cli/cmd_validate.sh:136-141` (help text; the implementation lives in `validate_structure`) | MEASURED (as help text) / behaviour NOT_YET_VERIFIED |

---

## 2. Case-by-case implementability

| Case | Implemented? | Induction | Notes |
|---|---|---|---|
| **L1** fresh install | YES | `reset_to_absent` → `apt-get install ./candidate.deb` | Asserts dpkg `ii`, mode=install, `COMMITTED`, the 9 verifier/package tokens, state version == package version, timestamp in window, daemon+socket active, 9 core timers + critical timer active, `ip`/`ip6 nftban` loaded, emergency table gone, zero failed nftban units, `nftban validate` rc 0. |
| **L2** same-version reinstall | YES | `apt-get install --reinstall` | Adds: timestamp advanced, operator conffile edit + `*.local` preserved, owned-file count unchanged, no duplicate dpkg entries, no duplicate `install_state` keys, no duplicate unit files, no `.dpkg-dist/.dpkg-new` residue. |
| **L3** upgrade | YES, **but self-gated** | install the REAL prior `.deb`, then install the candidate | Never simulated by editing `VERSION`. The harness **refuses** (SKIP + a top-level FAIL at PRE) if `dpkg-deb -f Version` is equal for both files. See §3.1 — with the tree as-is this WILL trip, because `VERSION` still reads `1.227.0`. |
| **L4** package-level T8 | YES | hold an exclusive `flock` on `/var/lib/nftban/state/installer.lock` for the duration of a `--reinstall` | Real transaction, real installer, real exit 75. Asserts exactly the five required tokens, plus "apt rc=0 + dpkg `ii`" (mechanical completion) against `VERIFIED=NO` (no verified-success claim), plus install_state byte-window unchanged, plus no dpkg scriptlet error. |
| **L5** controlled pre-Transition termination | **PARTIAL — see §3.2** | immutable flag on `install_state` so `WriteAtomic`'s `os.Rename` cannot land | This is **not** the panic path. It is the only controlled, reversible, non-kill mechanism I could derive that provably keeps the persisted state historical. It self-checks: if `install_state` changed at all, L5 reports FAIL "INJECTION DID NOT TAKE EFFECT … treat as NOT_YET_VERIFIED", and it asserts installer exit != 75 so it cannot silently degenerate into a second L4. |
| **L6** terminal states | YES (3 sub-cases) | 6a mask `nftables.service`; 6b start `ufw.service`; 6c mask `nftban-maintenance.timer` | Each asserts: apt rc=0, the right `INSTALL_STATE`, the right verdict (`INSTALL_FAILED` / `INSTALL_DEGRADED`), `VERIFIED=NO` on both tokens, `VERIFY_EXIT=2`, and that the persisted state is **CURRENT** (inside the transaction window) rather than stale. 6b also asserts installer exit 3, 6c asserts installer exit 1. |
| **L7** uninstall | YES | `apt-get remove` | Asserts rc=0, dpkg `rc`, daemon+timers not active, no nftban unit files left in `/usr/lib/systemd/system`, both nftban tables **deleted** (the v1.221.3 drop-policy-blackhole invariant), the documented consequence text, `/etc/nftban` + operator config + `install_state` retained per policy, **no Item 2 tokens on the removal path**, `prerm`/`postrm` (extracted from the real `.deb` with `dpkg-deb -e`) contain no `--verify-install-state`, and a read-only re-run of the shipped verifier against the removal timestamp does not claim success. |
| **L8** reinstall after uninstall | YES | install over the `rc` state left by L7 | Asserts the surviving stale state is present beforehand, then that the new timestamp is **strictly greater**, verdict `CURRENT_COMMITTED`, `VERIFIED=YES`, version not reused from history. |
| **L9** purge | YES | `apt-get purge`, then a fresh install | Asserts all five purge dirs gone, `install_state` gone, zero nftban unit files known to systemd, zero orphan nftban-scoped package-owned paths (inventory captured with `dpkg -L` **before** the purge), and that the following fresh install reaches `CURRENT_COMMITTED` with `INSTALL_MODE=install`. Records the documented `/var/tmp/nftban-config-backup-*` side effect. |
| **L10** interrupted/failed uninstall | YES | `chattr +i` on a package-owned file (`/usr/lib/nftban/VERSION_DATE`) so dpkg's unlink fails during removal | Chosen because `preinst` only strips `+i` from `nft_schema.sh` and `nftban.conf` (`packaging/deb/preinst:78-89`), so the flag survives the transaction. Asserts the removal genuinely failed (otherwise the case FAILs as "not induced"), that **no** install-verification tokens were emitted, that a prior `COMMITTED` does not read as removal success (read-only verifier probe with the uninstall time as `--not-before`), and that `install_state` was untouched. Then recovers the host. |

---

## 3. What I could NOT implement faithfully

### 3.1 L3 cannot run against the repo as it stands (blocking, not a harness defect)

`VERSION` currently reads **`1.227.0`** on branch `feat/v1.228.0-item2-postinstall-outcome-truth`
(`VERSION`, single line, no trailing newline), and `PKG_VERSION` is read straight from it
(`packaging/build_nftban.sh:46`). A candidate built from this tree is therefore
`nftban-core_1.227.0_amd64.deb` — **the same version as the "prior published v1.227.0"**.
L3 would then not be an upgrade at all, and L4's "SAME-VERSION prior COMMITTED" would be
ambiguous with the prior package.

The harness does not paper over this: it compares `dpkg-deb -f Version` of both inputs,
fails the pre-flight assertion, and SKIPs L3 with an explicit note telling the operator to
rebuild the candidate with a bumped `VERSION`. **Status: NOT_YET_VERIFIED until a
1.228.0-versioned candidate exists.**

### 3.2 L5 — the T9 panic class has no package-level injection hook

I searched for one and it does not exist:

- `cmd/nftban-installer/inject.go:32-45` is unexported, Go-test-only, and carries only
  systemd-payload / health-profile / logrotate-validator data. It cannot force a
  termination and is unreachable from a flag or an env var.
- No abort/inject env var exists (full `Getenv` sweep, §1.6).
- `logging.New` cannot be made to fail (`logger.go:62-90`).
- `NFTBAN_MIN_DISK_FREE_MB` produces a state **write**, so it is the wrong class.
- The one shipped pre-StateFile termination reachable from a real transaction is lock
  contention — which is already L4.

The task forbids an uncontrolled panic / `kill -9` of a real transaction, and I agree with
that constraint, so I did not use one. What L5 actually exercises is the *observable* of
T9 — historical state unchanged, `STALE_STATE`, scriptlet rc 0 — via an immutable
`install_state`, which makes `WriteAtomic`'s final `os.Rename`
(`internal/installer/state/file.go:294`) fail so nothing can be persisted.

**Honest label: the mechanism is INFERRED and the case is NOT_YET_VERIFIED as a faithful
reproduction of "pre-Transition termination".** It reproduces the class, not the cause.
If you need the cause reproduced, the product would have to grow a controlled abort hook
(e.g. an env-gated `NFTBAN_INSTALLER_ABORT_AT=<phase>` honoured only when a debug build
tag is set) — that is a product change, not something a harness can fake.

### 3.3 Things the harness asserts but that I could not pre-verify from the repo

All **NOT_YET_VERIFIED** until the first VM run:

1. That `systemctl mask nftables.service` actually drives `EnableNftables` to error rather
   than some earlier phase failing first (would show up as a wrong `INSTALL_STATE`, which
   the harness reports as a FAIL with the actual value printed).
2. That `systemctl start ufw.service` with the ufw firewall *disabled* leaves the unit
   `active` (harness measures and SKIPs 6b if not).
3. That `chattr +i` is honoured on the VM's root filesystem (harness SKIPs L5/L10 with a
   NOT_YET_VERIFIED note if `chattr` is missing or the flag is not observable via `lsattr`).
4. That `apt-get remove` fails when a package-owned file is immutable (harness FAILs the
   case loudly with "the failure was not induced" rather than passing).
5. Whether `phasePrepare`'s dependency-install step behaves under a held dpkg lock (it
   runs *inside* a dpkg transaction). On a lab VM with all `Depends` satisfied this should
   be a no-op, but I have no evidence either way.
6. The exact text `validate_structure` emits — I read `cmd_validate.sh` (which documents
   the 0/1/2/3 contract) but not the implementation of `validate_structure` itself.

---

## 4. Findings surfaced while deriving (worth a look independent of the harness)

1. **RFC3339 second-truncation vs nanosecond `NOT_BEFORE` — latent false STALE_STATE.**
   `packaging/deb/postinst:365` captures `NOT_BEFORE` with `%N` (nanoseconds), but
   `internal/installer/state/file.go:252` persists `INSTALL_TIMESTAMP` with `time.RFC3339`,
   which has **no fractional seconds**. The persisted value is therefore truncated
   *downward*, while the comparison at `internal/installer/postinstall/verify.go:195` is a
   strict `Before(NotBefore)` with no tolerance (deliberately — the doc comment at 137-140
   explains why a tolerance was rejected). If an installer run ever completed within the
   same wall-clock second in which `NOT_BEFORE` was taken, a genuinely fresh COMMITTED
   would be reported `STALE_STATE`. Real installs take seconds, so this is latent, not
   active — but it is an asymmetry between the two operands the design doc claims are
   directly comparable ("Both operands are UTC … so no timezone conversion can affect the
   comparison" — verify.go:49-50 addresses zones, not precision).
   The harness accounts for it: `assert_state_version_and_window` allows exactly one
   second of slack at the lower bound and none elsewhere.
   Status: **MEASURED** (both code sites), consequence **INFERRED**.

2. **The Item 2 gate lives inside `if [ -x "$NFTBAN_INSTALLER" ]`.** During this session a
   `no-installer` branch was added (`packaging/deb/postinst:486-502`) emitting
   `NFTBAN_PACKAGE_INSTALLER_EXIT=127` / `VERIFY_EXIT=127` / `POSTINSTALL_VERIFIED=NO`, which
   closes the "silent success with no verdict" hole on that path. Note the branch emits
   *only* package-context tokens — no `NFTBAN_INSTALL_ATTEMPT_VERDICT` — so a consumer that
   keys solely on the verdict token still sees nothing on that path. The harness's
   `assert_verified_tokens` requires `INSTALLER_EXIT=0`, so a 127 outcome fails loudly, but
   there is **no dedicated case** for it in the L1–L10 matrix as specified. Worth adding as
   L11 if you want the no-installer path covered.
   Status: **MEASURED**.

3. **`install_state` survives `apt-get remove`.** `postrm`'s `remove` branch
   (`packaging/deb/postrm:188-242`) never touches `/var/lib/nftban`. A same-version prior
   `COMMITTED` is therefore sitting on disk at the moment of every reinstall-after-uninstall
   — which is precisely why L8 and L10 are the sharp cases, not L1.
   Status: **MEASURED**.

4. **`prerm` stops but does not disable the active units.** Only the deprecated units are
   disabled (`packaging/deb/prerm:109-125`); with no debhelper in the build
   (`packaging/build_nftban.sh:2372`) there is no `dh_installsystemd` disable either. On
   `remove` the unit *files* go away with the payload, so "enabled" state is moot — but
   the task's phrase "services stopped/disabled as designed" resolves to **stopped +
   unit-files-removed**, and the harness asserts that, not a `disabled` string.
   Status: **MEASURED** (policy), **INFERRED** (that file removal is what makes it moot).

5. **UFW on a stock Ubuntu image can pre-abort every install.** `extfw.Detect` treats
   `ufw.service` being active as a conflict signal regardless of whether the ufw firewall
   is enabled (`internal/installer/extfw/detect.go:178-184`). Any lab image where
   `ufw.service` is active would classify every fresh install as `FAILED_AUTHORITY_ABORT`.
   The harness prints the baseline value and neutralises it explicitly rather than
   inheriting it silently.
   Status: **MEASURED** (detector), image behaviour **NOT_YET_VERIFIED**.

---

## 5. How to run

```bash
# on a DISPOSABLE Ubuntu 24.04 VM, as root
scp lifecycle_deb_matrix.sh vm:/root/
ssh vm 'chmod +x /root/lifecycle_deb_matrix.sh'
ssh vm '/root/lifecycle_deb_matrix.sh \
          /root/nftban-core_1.228.0_amd64.deb \
          /root/nftban-core_1.227.0_amd64.deb 2>&1 | tee /root/lifecycle_matrix.log'
```

Subset runs: `NFTBAN_LIFECYCLE_CASES="L1 L4 L7" ./lifecycle_deb_matrix.sh cand.deb prior.deb`.

Exit codes: `0` = every case ran and passed, `1` = at least one assertion or case failed,
`2` = at least one case was skipped (verdict `INCOMPLETE` — **not** a pass) or the
invocation was invalid.

Machine-readable tail:

```
NFTBAN_MATRIX_CANDIDATE_VERSION=…
NFTBAN_MATRIX_PRIOR_VERSION=…
NFTBAN_MATRIX_RESULT_L1..L10=PASS|FAIL|SKIP
NFTBAN_MATRIX_NOTE_<case>=…            (skip reason, when applicable)
NFTBAN_MATRIX_ASSERTIONS_PASS=…
NFTBAN_MATRIX_ASSERTIONS_FAIL=…
NFTBAN_MATRIX_CASES_FAILED=…
NFTBAN_MATRIX_CASES_SKIPPED=…
NFTBAN_MATRIX_ARTIFACTS=/var/tmp/nftban-lifecycle-XXXXXX
NFTBAN_MATRIX_VERDICT=PASS|FAIL|INCOMPLETE
```

Every apt/dpkg transcript, every `nftban validate` run and every verifier probe is kept
under `NFTBAN_MATRIX_ARTIFACTS` for post-mortem.

## 6. Safety notes

- The harness is **destructive by design**: it purges, masks `nftables.service`, starts
  `ufw.service`, and sets immutable flags. Disposable VM only.
- Every mutation is recorded in a cleanup ledger and reverted by an `EXIT` trap
  (`unmask`, `chattr -i`, release the flock holder, drop the emergency SSH table).
- It never uses `kill -9`/`pkill -f` against a live transaction, and it never edits the
  `VERSION` file or any packaging file to manufacture a scenario.
- `nft delete table inet nftban_install_emergency` is issued during teardown because
  `phaseSwitch` deliberately leaves the emergency SSH table in place on the
  `FAILED_NO_FIREWALL` path (`cmd/nftban-installer/phases.go:474-477` — "Emergency table
  LEFT IN PLACE — SSH still safe").
