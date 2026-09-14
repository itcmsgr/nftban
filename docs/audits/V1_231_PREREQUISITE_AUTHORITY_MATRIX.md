# v1.231 Lane 3 — Prerequisite Authority Reconciliation Matrix

Status: CLASSIFICATION ONLY. No package metadata changed, no code changed, no handles registered.

Subject SHA: `0c7ad204dd1d31b4ff88903900332572245ff019` (origin/main), VERSION `1.230.0`.
Runtime evidence planes: lab2 = Ubuntu 24.04.3 LTS, `nftban-core 1.229.14` (dpkg);
lab4 = Rocky Linux 9.8, `nftban-core-1.229.14-1.el9` (rpm). No production host touched.

Verifier applicability note: lab2 has `rpm` installed but is a dpkg host. A first sweep using
`rpm -qf` there returned "not owned by any package" for every binary — an OBSERVATION_FAILURE,
not evidence. All lab2 ownership below is re-derived with `dpkg -S`, and `/bin` vs `/usr/bin`
usr-merge path artifacts are resolved against the dpkg database spelling.

---

## 0. The authority topology (the single shared root cause)

Four surfaces name prerequisites. Only one reaches a package.

| # | Surface | Shipped? | Consumed by packaging? | Role |
|---|---------|----------|------------------------|------|
| A | `packaging/build_nftban.sh` RPM spec heredoc (`:441-473`) and DEB control heredoc (`:2189-2196`) | yes | **THIS IS THE ONLY PACKAGING AUTHORITY** | core-install contract |
| B | `/etc/nftban/distros/*.conf` `[packages]` (21 files) → `nftban_distro_get_package` → `cli/lib/nftban/lib/nftban_prereq.sh` | yes | **no** | feature-scoped advisory gate |
| C | `packaging/deb/control` | **no** | **no** — `build_nftban.sh:2189` writes `DEBIAN/control` from its own heredoc; nothing reads this file | DEAD |
| D | `install_prerequisites.sh` `CMD_TO_PKG_DEB`/`CMD_TO_PKG_RPM` (`:258`,`:269`) | **no** (repo root; 0 files matching in `rpm -ql nftban-core`; no reference in `build_nftban.sh`) | no | DEAD |

**New finding — C is a second dead duplicate authority, and it DISAGREES with what ships.**
`packaging/deb/control` declares `iproute2` and `libpam0g` in `Depends` and `acl` only in
`Recommends`. The DEB actually installed on lab2 declares neither `iproute2` nor `libpam0g`,
makes `acl` a hard `Depends`, and adds `conntrack` to `Recommends`:

```
# dpkg-query -W -f='Depends: ${Depends}\nRecommends: ${Recommends}\n' nftban-core   (lab2)
Depends: nftables (>= 0.9.0), systemd, bash (>= 4.0), bash-completion, jq, curl, tar,
         gzip, bc, gawk, socat, acl, logrotate, polkitd | policykit-1
Recommends: dnsutils, mailutils, netmask, whiptail, conntrack
```

That is byte-for-byte `build_nftban.sh:2195-2196`. Surface C is stale and misleading; reading it
to answer "does NFTBan depend on iproute2?" gives the wrong answer.

B is **not** dead — it is correctly scoped. `nftban_prereq.sh` is an *advisory, non-installing*
gate (`nftban_prereq_require_cmd` records a distro-correct `sudo <install_cmd> <pkg>` hint and
returns 1; it never installs). Its consumers are the feature verbs: `cmd_geoban.sh:173`,
`cmd_login.sh:340` (mail), `cmd_rbl.sh:998`, plus `nftban_prereq_check_suricata/_zabbix`. So the
architecture is deliberate: **A = core-install contract, B = feature-scoped capability gate.**
The defects below are the capabilities that fall in the gap between A and B.

---

## 1. Evidence matrix

Abbreviations: DEB/RPM columns quote the *shipped* declaration (surface A), verified against the
installed package on lab2/lab4. "—" = not declared. Guarded = call site tests for the binary
before use.

| CAPABILITY | CALLER(S) | EXECUTABLE EXPECTED | FEATURE OWNER | REQUIREMENT CLASS | DISTRO PACKAGE (per family) | PACKAGE PROVIDES EXPECTED EXECUTABLE? | DEB DECLARATION | RPM DECLARATION | RUNTIME INSTALL PATH | GUARDED? | LAB/FLEET PRESENCE | VERDICT |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **nft** | firewall/ban/set-sync core, pervasive | `nft` | firewall enforcement | core-required | EL `nftables` / DEB `nftables` | YES — lab4 `nftables-1.0.9-7.el9_8` owns `/usr/sbin/nft`; lab2 `nftables` owns it | `Depends: nftables (>= 0.9.0)` | `Requires: nftables >= 0.9.0` | none | n/a (declared) | lab2 PRESENT, lab4 PRESENT | **ALIGNED** |
| **systemctl** | service/timer verbs, health | `systemctl` | lifecycle | core-required | `systemd` both | YES — lab4 `systemd-252-67.el9_8.4`; lab2 `systemd` | `Depends: systemd` | `Requires: systemd` | none | n/a | PRESENT both | **ALIGNED** |
| **ip** | `cmd_system.sh:154`, `cmd_whitelist.sh:804,808`, `cmd_zabbix.sh:961`, `nftban_hostaddr.sh:106` | `ip` | host-address discovery | core-required | EL `iproute` / DEB `iproute2` (in all 21 confs) | YES — lab4 `iproute-6.17.0-2.el9` owns `/usr/sbin/ip`; lab2 `iproute2` owns `/bin/ip` | **—** (only the DEAD `packaging/deb/control` declares `iproute2`) | **—** | none | soft only (`2>/dev/null`, empty result) | PRESENT both (base system) | **GAP — UNDECLARED** (masked by base-system presence) |
| **jq** | `cmd_ban.sh:232`, `cmd_cleanup.sh:126`, pervasive | `jq` | JSON handling | core-required | `jq` both | YES — lab4 `jq-1.6-19.el9_8.2`; lab2 `jq` | `Depends: jq` | `Requires: jq` | none | many sites also `command -v` guard | PRESENT both | **ALIGNED** |
| **curl** | `cmd_feeds.sh:1008`, `cmd_geoip.sh:643`, `cmd_geoban.sh:556` | `curl` | feeds / GeoIP download | core-required | `curl` both | YES — lab4 `curl-7.76.1-40.el9`; lab2 `curl` | `Depends: curl` | `Requires: curl` | none | guarded at `cmd_feeds.sh:1008` | PRESENT both | **ALIGNED** |
| **tar** | `cmd_update_backup.sh:64` | `tar` | update backup | core-required | `tar` both | YES — lab4 `tar-1.34-11.el9`; lab2 `tar` | `Depends: tar` | `Requires: tar` | none | n/a | PRESENT both | **ALIGNED** |
| **gzip** | `cmd_update_backup.sh:64` (`-z`), `nftban_stats_collect.sh:593` (`zgrep`) | `gzip`, `zgrep` | backup + ban history | core-required | `gzip` both | YES — lab4 `gzip-1.12-1.el9`; lab2 `gzip` | `Depends: gzip` | `Requires: gzip` | none | `zgrep` absence warns and degrades (`:593`) | PRESENT both | **ALIGNED** |
| **bc** | `nftban_portscan_suricata.sh:552-601` | `bc` | Suricata score decay | feature-required (declared core) | `bc` both | YES — lab4 `bc-1.07.1-14.el9`; lab2 `bc` | `Depends: bc` | `Requires: bc` | none | every site has `|| echo <default>` fallback | PRESENT both | **ALIGNED** (over-declared but harmless) |
| **gawk** | pervasive `awk` | `gawk`/`awk` | parsing | core-required | `gawk` both | YES — lab4 `gawk-5.1.0-6.el9` owns both `/usr/bin/gawk` and `/usr/bin/awk`; lab2 `gawk` | `Depends: gawk` | `Requires: gawk` | none | n/a | PRESENT both | **ALIGNED** |
| **socat** | `cmd_cleanup.sh:117,168,248`, `cmd_protect.sh:94`, `cmd_support.sh:1288` | `socat` | daemon UNIX-socket IPC | core-required | `socat` both | YES — lab4 `socat-1.7.4.1-8.el9`; lab2 `socat` (`/usr/bin/socat1`) | `Depends: socat` | `Requires: socat` | none | `cmd_support.sh:1287` guards; IPC sites do not | PRESENT both | **ALIGNED** |
| **logrotate** | `/etc/logrotate.d/nftban*` (system rotator) | `logrotate` | log durability | core-required | not in distro confs | YES — lab4 `logrotate-3.18.0-12.el9`; lab2 `logrotate` | `Depends: logrotate` | `Requires: logrotate` (v1.137) | none | n/a — external rotator | PRESENT both | **ALIGNED** |
| **polkit** | `cmd_polkit.sh:209` (`pkcheck`), `nftban_health_checks_security.sh:511` + `nftban_health_fixes.sh:1350` (`pkaction`) | `pkcheck`, `pkaction` (**not** `pkexec` — `cmd_firewall.sh:1599` records the "no pkexec" design) | authorization | core-required | `polkit` both (`[services] polkit`) | YES for what is used — lab4 `polkit-0.117-14.el9` owns `pkaction`+`pkcheck`; lab2 `polkitd` owns `pkaction`+`pkcheck` | `Depends: polkitd \| policykit-1` | `Requires: polkit` | none | all three sites `command -v` guarded | PRESENT both. `pkexec` ABSENT on lab2 (separate `pkexec` pkg, uninstalled) — **not a gap, NFTBan never calls it** | **ALIGNED** |
| **acl** | `nftban_health_checks_core.sh:286` (`getfacl`), `nftban_health_fixes.sh:59` (`setfacl`) | `setfacl`, `getfacl` | nftban-auditor group ACLs | feature-required | not in distro confs | YES — lab4 `acl-2.4.0-1.el9_8`; lab2 `acl` | `Depends: acl` (hard) | `Recommends: acl` on el9; `Requires` only `%if fedora \|\| el10` | none | both sites `command -v` guarded and skip cleanly | PRESENT both | **FAMILY ASYMMETRY** (DEB hard / RPM soft). Callers guard → soft is defensible; harmonize downward, not upward |
| **perl** | `cmd_firewall.sh:422` (guard), `:434` (`perl -0pi`), `:3891` | `perl` | firewall service-port element rendering | core-required | not in distro confs | YES — lab4 `perl-interpreter-5.32.1-483.el9`; lab2 `perl-base` | **—** | `Requires: /usr/bin/perl` (v1.228.5, capability form → resolves to `perl-interpreter`) | none | `cmd_firewall.sh:422` fails closed with an explicit install hint | PRESENT both | **ALIGNED-IN-EFFECT** — DEB undeclared but `perl-base` is `Essential=yes Priority=required` on Ubuntu (measured), so it cannot be absent. Declare for symmetry only |
| **wget** | `nftban_health_checks_core.sh:168` **required_binaries** → `HEALTH_ERROR`; `nftban_system_ip.sh:94-99`; `install_vmagent.sh:98`; `nftban_metrics.sh:308` | `wget` | health gate + metrics/vmagent installers | **declared core by health, actually diagnostic** | `wget = wget` in all 21 confs | YES — lab4 `wget-1.21.1-8.el9_4`; lab2 `wget` | **—** | **—** | none | `nftban_system_ip.sh:94` guards (curl-first fallback); **health does NOT guard — it errors** | PRESENT both | **GAP — CONTRADICTION.** Health hard-ERRORs on a capability no package declares |
| **conntrack** | `nftban_sysctl_registry.sh:88,102,140` | `conntrack` | DB-session idle-age source for sysctl safety | fallback-only | **absent from all 21 distro confs** | YES — lab2 `conntrack` owns `/usr/sbin/conntrack`; EL name is **`conntrack-tools`** (`dnf provides */sbin/conntrack` → `conntrack-tools-1.4.7-4.el9_5`) | `Recommends: conntrack` (`build_nftban.sh:2196`, confirmed installed lab2) | **—** (absent from both `Requires` and `Recommends` on lab4) | none | yes — `:88` `command -v` guard; `:140` emits `UNKNOWN` + install hint | lab2 **PRESENT**, lab4 **ABSENT (measured)** | **FAMILY ASYMMETRY GAP** — degrades gracefully, so low severity |
| **nc / ncat** | `cmd_connector.sh:690,692` (**UNGUARDED**); `cmd_status.sh:1516` (guarded); `cmd_zabbix.sh:284` (guarded); `nftban_health_checks_integrations.sh:427,464` (guarded) | `nc` (connector), `nc`-or-`ncat` (zabbix/status/health) | syslog connector + Zabbix transport | feature-required | EL `nmap-ncat` / DEB `ncat` (`ncat` key, 21/21) | **TESTED — YES on BOTH.** EL: `dnf repoquery -l nmap-ncat` → `/usr/bin/nc` **and** `/usr/bin/ncat`; `--provides` → `nc`, `nc6`. DEB: `dpkg-deb --contents` ships **only** `/usr/bin/ncat`, **but** its postinst runs `update-alternatives --install /bin/nc nc /usr/bin/ncat 40` → provides `nc` | **—** | **—** | `cmd_zabbix.sh:292` `apt-get install -y ncat` / `:293` `dnf install -y nmap-ncat` — **Zabbix verb only; does not help the connector path** | **NO** at `cmd_connector.sh:690,692` | lab2 `nc` PRESENT via **`netcat-openbsd`** (`Priority: important` → stock image), `ncat` ABSENT. lab4 `nc` **ABSENT**, `ncat` **ABSENT**, `nmap-ncat` not installed | **CONFIRMED DEFECT — see §2** |
| **python3** | `cmd_search.sh:316,319` (IPv6 CIDR containment), `nftban_file_ops.sh:71`, `cmd_health_components.sh:430,448` | `python3` | optional IPv6/YAML helpers | optional | absent from all 21 confs | YES — lab4 `python3-3.9.25-7.el9_8.2`; lab2 `python3.12-minimal` | **—** | **—** | none | **every** site `command -v` guarded; degradation documented at `cmd_search.sh:764` | PRESENT both (base system) | **ALIGNED — no action** |
| **yq** | `nftban_health_checks_config.sh:219-233` | `yq` | commands-registry YAML validation | optional | absent from all 21 confs | **NFTBan VENDORS it** — `build_nftban.sh:87-135` `provision_yq`, SHA-pinned v4.44.1 (`PROV_YQ_SHA256=6dc2d0cd…`) → `/usr/lib/nftban/bin/yq` | **—** (self-provided) | **—** (self-provided) | build-time vendoring, not runtime install | guarded at `:219` | lab4 `/usr/bin/yq → /usr/lib/nftban/bin/yq` owned by **`nftban-core`**; lab2 identical | **ALIGNED** (vendored). Minor wording defect: `:233` hint says `pip install yq` — a *different* tool with incompatible syntax |
| **bash-completion** | `/usr/share/bash-completion/completions/nftban` (`build_nftban.sh:728`, `:1990`) | framework (no binary) | shell UX | optional (declared core) | not in distro confs | YES — lab4 `bash-completion-2.11-5.el9`; lab2 `bash-completion 1:2.11-8` | `Depends: bash-completion` | `Requires: bash-completion` | none | n/a | INSTALLED both | **ALIGNED** (over-declared; zero enforcement impact) |

---

## 2. The `nc` row — the predicted defect is REFUTED, a worse one is PROVEN

**The binary-name hypothesis is disproven on both families.** Tested, not inferred:

- **EL9** — `nmap-ncat-3:7.92-5.el9` file list contains `/usr/bin/nc` *and* `/usr/bin/ncat`, and the
  package virtual-provides `nc`. Mapping `ncat = nmap-ncat` is **correct**.
- **Ubuntu 24.04** — the `ncat` `.deb` payload contains only `/usr/bin/ncat`, which looks like the
  predicted defect. But its `postinst` registers
  `update-alternatives --install /bin/nc nc /usr/bin/ncat 40`. Mapping `ncat = ncat` is **correct**.

So `cmd_connector.sh` calling `nc` is **not** a caller/command-name defect, and the distro registry
is right. Two different defects are real:

### 2a. FALSE SUCCESS — `connector push` reports delivery that did not happen (primary)

`cli/lib/nftban/cli/cmd_connector.sh:691-695`:

```bash
if [[ "$proto" == "udp" ]]; then
    echo "$msg" | nc -u -w1 "$host" "$port"
else
    echo "$msg" | nc -w1 "$host" "$port"
fi
_connector_print_success "Event pushed to syslog"
```

`_connector_print_success` is **unconditional** — the `nc` pipeline's status is never examined.

Runtime proof, lab4, `nftban-core 1.229.14`, precondition asserted *before* the capability test:

```
precondition: nc=ABSENT(precondition_ok)
# nftban connector add labnctest --type syslog
# nftban connector push labnctest
/usr/lib/nftban/cli/cmd_connector.sh: line 676: nc: command not found     <- stderr
✅ Event pushed to syslog                                                  <- stdout
PUSH_RC=0
```

Exit 0 and an affirmative delivery claim while nothing was sent. This is the standing
"exit 0 != delivery" class. Test connector removed afterwards; `connector list` count = 0.

Observation, not a claim: `cmd_connector.sh:25` sets `-Eeuo pipefail`, yet the missing command did
not abort. The masking mechanism was not isolated in this lane — recorded, not explained. The
briefed expectation of a *hard abort* is therefore **not what the runtime does**; silent false
success is the observed behavior and is worse.

### 2b. UNDECLARED CAPABILITY — no `nc` provider is declared on either family

Why it has worked anyway, per family — different mechanisms, both accidental:

- **DEB**: `netcat-openbsd` is `Priority: important`, so it is on the stock Ubuntu image and owns
  `/bin/nc` via alternatives at priority 50. NFTBan never asked for it. The `ncat` package NFTBan's
  registry names is **not** installed on lab2 — the working `nc` comes from a package NFTBan does
  not reference anywhere.
- **RPM**: nothing supplies it, and lab4 measures `nc` **ABSENT** with NFTBan installed and the
  `connector` verb shipped and reachable (`rpm -ql nftban-core` → `/usr/lib/nftban/cli/cmd_connector.sh`;
  `nftban connector --help` → rc 0). The EL path is simply broken and was never exercised.

`cmd_zabbix.sh:292-293` self-installs at runtime, but only under the Zabbix verb; it does not help
`connector push`.

---

## 3. "Why have installs worked until now?" — proven mechanism per capability

| Mechanism (proven) | Capabilities |
|---|---|
| **Declared already** (surface A, both families) | nft, systemctl, jq, curl, tar, gzip, bc, gawk, socat, logrotate, polkit, bash-completion |
| **Declared on one family only; present anyway on the other** | `acl` (DEB hard / RPM Recommends — el9 pulled it regardless); `perl` (RPM capability-Requires; DEB carried by `perl-base`, `Essential=yes`, measured) |
| **Present on normal distro images; never declared** | `ip` (iproute/iproute2 in base), `python3` (`python3.12-minimal` / `python3-3.9`), `wget` (base on both labs) |
| **DEB `Recommends` masking; RPM has nothing** | `conntrack` — apt installs Recommends by default so lab2 has it; lab4 measures ABSENT |
| **Self-provided (vendored at build)** | `yq` — SHA-pinned v4.44.1 shipped inside `nftban-core` |
| **Runtime self-install in feature code** | `nc`/`ncat` — but only inside `cmd_zabbix.sh:292-293`, scoped to the Zabbix verb |
| **Feature path never exercised** | `nc` on EL — `connector push` over syslog has evidently never run on a minimal EL host; lab4 reproduces the failure on first attempt |
| **Distro registry knows the name; packaging never consumed it** | every `[packages]` key — surface B is not wired to surface A at all; `wget`, `ncat`, `iproute` are named correctly there and still ship undeclared |
| **Dead authority read as if live** | `iproute2`, `libpam0g` appear declared if one reads `packaging/deb/control` — that file is not consumed |

---

## 4. Recommended requirement-class ruling (for human ratification)

No change is made by this lane. Each row is a proposal.

| # | Capability | Proposed class | Proposed ruling | Priority |
|---|---|---|---|---|
| R1 | **nc / ncat** | feature-required | **Fix the caller, not the metadata.** Check the `nc` pipeline status at `cmd_connector.sh:691-695` and fail the push honestly; add a `command -v` guard consistent with `cmd_status.sh:1516`. Adding a hard `Requires` for a syslog-connector transport is the wrong lever. | **P1 — false success, exit 0, proven on lab4** |
| R2 | **nc / ncat** (declaration) | feature-required | After R1, route it through surface B (`nftban_prereq_require_any_cmd "nc ncat" "ncat ncat"`), which already produces the distro-correct hint. Do **not** promote to a package dependency. | P2 |
| R3 | **wget** | **diagnostic** | **Demote, don't declare.** Remove `wget` from `nftban_health_checks_core.sh:168` `required_binaries`. `curl` is already a hard dependency and every functional path treats wget as a *fallback* (`nftban_system_ip.sh:94`). A hard `HEALTH_ERROR` for an undeclared fallback is the contradiction; adding a dependency would ratify the wrong side. | **P1 — cheapest correct fix** |
| R4 | **ip** | core-required | **Declare it.** `iproute2` (DEB) / `iproute` (RPM). It is genuinely core (`nftban_hostaddr.sh` is the host-address discovery authority), the distro confs already carry the correct names 21/21, and the only reason it is absent is that the dead `packaging/deb/control` "already had it". | P2 |
| R5 | **conntrack** | fallback-only | **Parity at Recommends level.** Add `Recommends: conntrack-tools` to the RPM spec (note the EL name differs — `conntrack-tools`, proven via `dnf provides`). Also add a `conntrack` key to the 21 distro confs so surface B can render the right name per family. Caller already degrades to `UNKNOWN` with a hint, so never make this hard. | P3 |
| R6 | **`packaging/deb/control`** | n/a | **Delete it, or mark it non-authoritative.** It is unconsumed and actively contradicts the shipped DEB on `iproute2`, `libpam0g`, `acl` and `conntrack`. Leaving a stale declaration file is how R4 stayed invisible. | **P1 — authority hygiene** |
| R7 | **`install_prerequisites.sh` `CMD_TO_PKG_*`** | n/a | **Delete the map** (or make it call `nftban_distro_get_package`). Confirmed non-shipped, 9-entry weaker duplicate of surface B. | P2 |
| R8 | **acl** | feature-required | **Harmonize downward to `Recommends` on DEB**, matching el9. Both call sites are guarded and skip cleanly; a hard dependency overstates it. Alternatively upward on RPM — but pick one, currently the families disagree with no stated reason. | P3 |
| R9 | **perl** | core-required | **Declare `perl-base` on DEB** for symmetry with the RPM `Requires: /usr/bin/perl`. Effectively inert (`Essential=yes` on Ubuntu) but makes the contract self-describing. | P3 |
| R10 | **python3** | optional | **No action.** All four call sites guarded, degradation documented. | — |
| R11 | **yq** | optional | **No dependency.** Vendored and SHA-pinned. Separately, fix the misleading `pip install yq` hint at `nftban_health_checks_config.sh:233` — that names a different tool with incompatible syntax. | P3 (wording) |
| R12 | **bash-completion, bc** | optional | **No action.** Over-declared as hard dependencies; harmless, and relaxing them has no upside. | — |
| R13 | **Structural** | n/a | **Wire surface B to surface A, or declare them independent on purpose.** The distro confs already hold correct per-family names for `iproute`, `wget`, `ncat`, `dns_utils`, `mail`. Packaging re-types a disjoint list by hand. Every gap above (R2, R4, R5) is one instance of that single disconnection. | P2 — design decision |

**Scope discipline:** R1 and R3 are the only items with demonstrated impact on a current release
candidate. R4/R5 are correctness debts with graceful degradation. R6/R7 are authority hygiene.
Nothing here justifies converting each absent binary into a hard dependency — 12 of 20 capabilities
are already correctly declared, and 4 more (python3, yq, bc, bash-completion) need no declaration at all.
