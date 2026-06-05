# NFTBan — admin SSH on an external redirect port (e.g. `:55000` → `:22`)

**Status:** operator note. **Added:** v1.150 lane (OBS-SSHPORT-55000-FAMILY). **Class:** SSH-lockout-adjacent **host-config** debt — **not** an NFTBan regression. Behaves identically on v1.142 and v1.150 (daemon byte-identical chain v1.147→v1.150).

This page explains, in plain English, **why a `nftban firewall rebuild` can briefly drop SSH on `:55000` while `:22` keeps working**, what NFTBan does about it, and what stays the host's job. It also records the **exact** CLI text so the wording can be checked against the code.

---

## 1. Root cause — in plain English

1. You connect to the server on **port 55000**.
2. **Something other than NFTBan** rewrites that to port 22 before `sshd` sees it. That "something" is an external redirect/NAT layer — **firewalld** forward-port, **iptables-nft** `REDIRECT`/`DNAT`, the hosting **panel** (DirectAdmin/CSF), or the **provider's** edge firewall. NFTBan does not create or manage that redirect.
3. `sshd` is actually **listening on port 22 only**. It never listens on 55000. You only *reach* it on 55000 because of step 2.
4. NFTBan figures out which SSH ports to protect by looking at **real `sshd` listeners + `sshd_config` Port lines + saved state + its own config** — it has **no way to see port 55000**, because 55000 is not a listener and not in any SSH config. So NFTBan correctly protects **`ssh_ports = { 22 }`**. That is the right answer for what `sshd` is doing.
5. `nftban firewall rebuild` (and `takeover`) re-apply NFTBan's own nftables **and disarm competing firewall layers** (that is the whole point of takeover — one firewall, not several fighting). If the **`:55000 → :22` redirect lives in one of those competing layers** (firewalld/iptables-nft), disarming it can **momentarily drop port 55000**. Port 22 stays up the whole time (NFTBan protects it), so an admin who only knows `:55000` can be surprised by a lockout while `:22` is perfectly fine.

**One sentence:** the `:55000 → :22` redirect is owned by the host's *other* firewall layer, not NFTBan; a rebuild that tidies up those other layers can disturb `:55000`, even though `sshd`/`:22` are never at risk.

Confirmed on **srv1** (CentOS Stream 10, +firewalld +iptables-nft layers) and **dns2** (CentOS Stream 9). Both: `ss` shows `sshd` on `:22` only; NFTBan renders `ssh_ports = { 22 }`; there is **no `:55000` rule anywhere in NFTBan's ruleset** (grep confirms none).

---

## 2. What NFTBan does about it (warn-only + lockout-net)

NFTBan does **not** try to own the redirect. Instead:

- **Warn-only (S1/S2).** Before a `rebuild`/`reload`/`takeover`, and on demand via `nftban firewall ssh-audit`, NFTBan reports the mismatch in plain language so the operator is never surprised.
- **Lockout-net (S2).** Before that rebuild/reload/takeover, NFTBan **session-whitelists your current admin source IP** through the existing, sanctioned IPC `whitelist-session` path (the same single-writer channel used everywhere else — **no direct nftables write**). That means **you stay reachable by IP regardless of which port the redirect was on**, even if the external `:55000` redirect flickers during the rebuild.

What NFTBan **deliberately does not do** (both rejected by design):

- It does **not** add `:55000` to `ssh_ports`. `ssh_ports` drives the brute-force rate-limit on the *actual* `sshd` **listener**; `sshd` is not on `:55000`, so adding it would not restore the redirect and would pollute the rate-limit set with a dead port.
- It does **not** recreate or "preserve" the `:55000 → :22` NAT. NFTBan is an ingress IPS, not a NAT/redirect manager. **Keep the redirect in the host firewall layer** (firewalld/iptables-nft/panel/provider).

---

## 3. Exact CLI text (recorded verbatim from the code)

On an affected host (`sshd` on `:22`, external `:55000` redirect declared via `NFTBAN_EXTERNAL_ADMIN_SSH_PORTS=55000`, admin connected):

### `nftban firewall ssh-audit`

```
SSH admin-port audit (OBS-SSHPORT-55000-FAMILY):
  sshd listeners (detected):     22
  nftban ssh_ports (protected):  22
  declared external admin ports: 55000   (set NFTBAN_EXTERNAL_ADMIN_SSH_PORTS to declare)
  active admin session:          ip=203.0.113.7  landed-port=22
  ⚠ external admin port :55000 is NOT an sshd listener → it reaches :22 via an EXTERNAL redirect/NAT
    (firewalld / iptables-nft / provider / panel). nftban does NOT own that path; a rebuild/takeover may
    disrupt :55000 while ssh_ports (22) stays valid. nftban will NOT import :55000 into ssh_ports
    (it is not a listener) and will NOT recreate the NAT — keep the redirect in the host firewall layer.
```

On a normal host (no external redirect) the last block is replaced by:

```
  ✓ no external-admin-port mismatch (ssh_ports reflects the real sshd listeners).
```

### Warning + lockout-net printed automatically before `nftban firewall rebuild`

```
  ⚠ NFTBan rebuild: external admin SSH port(s) declared (:55000).
    nftban ssh_ports stays the ACTUAL sshd listener set (22); nftban will NOT preserve the
    external NAT/redirect for :55000 (host-managed: firewalld/iptables-nft/provider).
  ✓ lockout-net: 203.0.113.7 session-whitelisted for the rebuild (TTL 1h).
```

The same lockout-net line (`✓ lockout-net: <ip> session-whitelisted …`) prints before **every** interactive `rebuild`/`reload`/`takeover` you run over SSH, even on a normal `:22` host — that is the general safety net. It is suppressed only off-session, on `--dry-run`, on opt-out, or on re-entry.

> These blocks are produced by `cli/lib/nftban/lib/ssh_admin_port_guard.sh` and are asserted character-for-character by `cli/lib/nftban/tests/ssh_admin_port_guard_v150_test.sh` (CI step *External admin SSH-port guard (OBS-SSHPORT-55000)* in `ci-architecture.yml`). If the code text and this page ever diverge, the test/CI is the source of truth.

---

## 4. Operator controls

| Setting | Effect | Default |
|---------|--------|---------|
| `NFTBAN_EXTERNAL_ADMIN_SSH_PORTS=55000` | Declares your external admin port so the warning is **precise** (otherwise NFTBan still applies the lockout-net, just without naming the port). Comma/space-separated list allowed. **Warning input only — never imported into `ssh_ports`.** | unset |
| `NFTBAN_NO_PREREBUILD_LOCKOUT=1` | Opt out of the pre-rebuild lockout-net entirely. | `0` (lockout-net on) |
| `NFTBAN_PREREBUILD_LOCKOUT_TTL=2h` | TTL of the session-whitelist entry added before a rebuild. | `1h` |

Recommended on srv1/dns2-class hosts: set `NFTBAN_EXTERNAL_ADMIN_SSH_PORTS` to the real external port in `/etc/nftban/nftban.conf.local` (or a `conf.d/*.local`), and **keep the `:55000 → :22` redirect in firewalld/iptables-nft/panel** — that is the layer that owns it.

---

## 5. Remediation if `:55000` is dropped after a rebuild

`:22` is never dropped (NFTBan protects it), so you can always recover:

1. Reconnect on **`:22`** directly (it stayed valid the entire time).
2. Re-apply the external redirect in **its own layer**, e.g. firewalld: `firewall-cmd --add-forward-port=port=55000:proto=tcp:toport=22 && firewall-cmd --runtime-to-permanent`, or restore the panel/provider rule. NFTBan does not own this rule and will not recreate it.
3. Run `nftban firewall ssh-audit` to confirm the picture (`ssh_ports = { 22 }`, declared `:55000`, mismatch flagged).

---

## 6. Related

- nftables single-writer policy: [`ARCHITECTURE-NFT-POLICY.md`](ARCHITECTURE-NFT-POLICY.md) — the lockout-net writes only through the sanctioned IPC `whitelist-session` path (no direct nft).
- SSH-port detection authority: `cli/lib/nftban/lib/ssh_port_detect.sh`, `cmd/nftban-detect-ssh-ports` (sources: `ss` listeners + `sshd_config` Port/ListenAddress + state + `conf.local`; **no conntrack source**).
- Register entry: `OBS-SSHPORT-55000-FAMILY` in `NFTBAN_PENDINGS_AND_BUGS_CURRENT.md` (cluster 3, SSH-port lifecycle).
