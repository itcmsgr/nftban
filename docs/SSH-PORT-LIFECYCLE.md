# NFTBan — SSH-port lifecycle (socket activation, invariants, and the srv1 gate)

**Status:** operator note. **Added:** v1.155 lane (cluster 3, SSH-port lifecycle). **Class:** SSH-port-change correctness + lockout-adjacent **host-config** debt — **not** an NFTBan regression. Daemon byte-identical to v1.154.0.

This page is the companion to [`SSH-EXTERNAL-ADMIN-PORT.md`](SSH-EXTERNAL-ADMIN-PORT.md). That page covers the **external `:55000 → :22` redirect** class. This page covers two adjacent things:

1. the **socket-activation port-change pitfall** that v1.155 PR-1 warns about, and the **lifecycle invariants** that the v1.155 PR-2 validator checks;
2. the **read-only observation procedure** and the **decision matrix** for the two srv1 gates, recording that the on-host srv1 proof is a **separate read-only gate after this release**.

Throughout: NFTBan is an ingress IPS, **not a NAT manager**. The external redirect stays host-managed, `:22` is never at risk, and `ssh_ports` only ever holds the **real `sshd` listeners**.

---

## 1. The socket-activation port-change pitfall (plain English)

On modern distros `sshd` can be **socket-activated**: a systemd `ssh.socket` (or `sshd.socket`) unit owns the listening socket and starts `sshd` on demand. The catch:

- When `sshd` runs as a plain service (`sshd.service`), changing `Port` in `sshd_config` and reloading `sshd` moves the listener immediately.
- When `sshd` is **socket-activated**, the `ssh.socket` unit owns the `ListenStream` (the port). Changing `Port` in `sshd_config` does **not** move the listener until **the socket unit is restarted**. So:
  - `sshd -T` reports the **configured** (new) port, while
  - `ss -tlnp` shows the socket still bound to the **old** port.

NFTBan protects the **real listeners** (what `ss` shows), so during that window `ssh_ports` correctly follows the old, still-listening port — not the configured-but-not-yet-active one. The operator can be surprised: "I changed the Port and reloaded sshd, why is the firewall still on the old port?" The answer is that the socket unit was never restarted.

**What v1.155 PR-1 does about it.** On a socket-activated host, `nftban firewall ssh-audit` (and the pre-rebuild guard path) now compares the configured ports (`sshd -T`) against the actual listeners. On a real mismatch it prints **one** calm warning naming the class and the exact remediation:

```
systemctl daemon-reload && systemctl restart ssh.socket
```

It is **read-only**: it performs no `nft` write and no service restart — it only tells you what to run. It is silent when the ports match or when `sshd` is a plain service (which applies `Port` on reload, so there is nothing to warn about). The wording is asserted by `cli/lib/nftban/tests/ssh_socket_port_mismatch_v155_test.sh` (CI: *Socket-activated SSH port-mismatch warning (v1.155 PR-1)*) — the test is the source of truth if this page and the code ever diverge.

---

## 2. The lifecycle invariants (what the v1.155 PR-2 validator checks)

`tools/validation/ssh_port_change_lifecycle_validate.sh` is a **read-only** validator. Given the rendered nftables ruleset and the real `sshd` listeners, it asserts four invariants that together mean "a Port change has been carried through the whole lifecycle correctly":

| # | Invariant | Why it matters |
|---|-----------|----------------|
| (a) | every `sshd` listener ∈ `tcp_ports_in` | otherwise the SSH service port is filtered (no inbound accept) |
| (b) | every `sshd` listener ∈ `ssh_ports` | otherwise the brute-force rate-limit misses that port |
| (c) | the brute-force ct-count rule references `@ssh_ports` (the set) | the rate-limit must be set-driven (v1.145), not hardcoded |
| (d) | there is **no** literal `tcp dport <sshport> … ct count` rule for an sshd port | a hardcoded literal would drift from the set on the next Port change |

Exit `0` means all four hold. On drift it exits non-zero with a precise per-invariant message (e.g. *"(b) sshd listener(s) NOT in ssh_ports: 2222 (brute-force rate-limit would miss this port)"*).

The validator auto-collects inputs on a host (`nft list ruleset` + the listener detector), or accepts injected fixtures via `NFTBAN_VALIDATE_RULESET_FILE` and `NFTBAN_VALIDATE_LISTENERS` (this is how the hermetic CI test exercises it). It mutates **nothing**: no `nft` write, no reload, no restart, no `sshd_config` edit, no SSH-port change.

Run it read-only on a host:

```
sudo bash tools/validation/ssh_port_change_lifecycle_validate.sh
```

---

## 3. OBS-SSHPORT observation procedure (srv1 / dns2, read-only)

This is the procedure to **observe** the external `:55000 → :22` behaviour around a rebuild on the affected hosts. It is **strictly read-only — capture, do not mutate.** Do **not** run `nftban firewall rebuild`/`reload`/`takeover`, do not edit `sshd_config`, do not touch the host redirect. The point of this gate is to *watch*, not to change.

Capture, **before** any rebuild (and keep `:22` open in a second session throughout):

1. **Listeners:** `ss -tlnp | grep -i ssh` — confirm `sshd` is on `:22` only.
2. **Configured ports:** `sshd -T | awk '/^port /{print $2}'`.
3. **Socket activation:** `systemctl is-active ssh.socket sshd.socket`.
4. **Host-layer redirect rules** (whoever owns `:55000`):
   - firewalld: `firewall-cmd --list-forward-ports`
   - iptables-nft: `nft list ruleset | grep -iE 'redirect|dnat|55000'` and `iptables-save | grep 55000`
5. **NFTBan picture:** `nftban firewall ssh-audit` (records `ssh_ports = { 22 }`, declared `:55000`, the external-redirect flag, and — on a socket-activated host — the PR-1 socket section).
6. **Lifecycle invariants:** `sudo bash tools/validation/ssh_port_change_lifecycle_validate.sh`.
7. **Conntrack for the admin source:** `conntrack -L 2>/dev/null | grep <admin-ip>` (or `ss -tnp` for the established admin connection) — shows the admin path is held by established conntrack regardless of port.

If a rebuild is later performed **under the separate gate** (§4), repeat steps 1–7 **after** it and diff: confirm `sshd`/`:22` never moved, `ssh_ports` stayed `{ 22 }`, no `:55000` rule exists inside NFTBan's ruleset, and whether the **host-layer** `:55000` redirect survived (that is the host's responsibility, not NFTBan's).

> Why this is read-only here: the actual rebuild on srv1 is a **separate gate after this release** (next section). v1.155 ships the warning + validator + this procedure; the on-host proof is run later by the operator.

---

## 4. Decision matrix — the two srv1 gates

The operator tracks two named gates for the srv1 external-`:55000` question. They are mutually exclusive choices about *how much proof* the srv1 rebuild gate requires:

| Gate token | Meaning | What it requires | Selected? |
|------------|---------|------------------|-----------|
| `OPEN_SSHPORT_55000_EXTERNAL_REDIRECT_SURVIVES_REBUILD_SCOPE` | **Full lifecycle proof** | Run the §3 observation procedure **before and after** an actual rebuild on srv1; diff every capture; record whether the host-layer `:55000` redirect survived and how it was restored if not. The strongest evidence. | **Selected** (`SELECT_V155_SRV1_GATE_AFTER_RELEASE = full_lifecycle_proof`) |
| `MARK_V150_SRV1_REBUILD_RETEST_PASS_WITH_OBS_SSHPORT` | Lighter retest mark | Re-confirm the v1.150 OBS-SSHPORT observation on srv1 (audit + ruleset grep) without a fresh full before/after rebuild diff. | not selected |

**Recorded decision:** the operator selected the **full lifecycle proof** path, and the on-host srv1 proof is a **SEPARATE read-only gate that runs AFTER this v1.155 release** — it is not part of this lane. v1.155 delivers the code (PR-1 warning, PR-2 validator) and this documentation; the srv1 rebuild observation is performed and recorded under `OPEN_SSHPORT_55000_EXTERNAL_REDIRECT_SURVIVES_REBUILD_SCOPE` once v1.155 is shipped.

---

## 5. What stays true (the non-negotiables)

- **NFTBan is not a NAT manager.** It does not create, recreate, or preserve the external `:55000 → :22` redirect. That rule lives in the host layer (firewalld / iptables-nft / panel / provider) and stays there.
- **The external redirect stays host-managed.** If a rebuild disturbs `:55000`, restore it in its own layer (see `SSH-EXTERNAL-ADMIN-PORT.md` §5).
- **`:22` is never at risk.** `sshd` listens on `:22`; NFTBan protects the real listeners, so `:22` stays up across rebuild/reload/takeover. You can always reconnect on `:22`.
- **`ssh_ports` = real listeners only.** The external `:55000` is never imported into `ssh_ports` (it is not a listener); `ssh_ports` drives the brute-force rate-limit on the actual `sshd` port.

---

## 6. Related

- External admin redirect class: [`SSH-EXTERNAL-ADMIN-PORT.md`](SSH-EXTERNAL-ADMIN-PORT.md) — the `:55000 → :22` warn-only + lockout-net behaviour.
- nftables single-writer policy: [`ARCHITECTURE-NFT-POLICY.md`](ARCHITECTURE-NFT-POLICY.md).
- SSH-port detection authority: `cli/lib/nftban/lib/ssh_port_detect.sh` (sources: `ss` listeners + `sshd_config` Port/ListenAddress + state + `conf.local`; no conntrack source).
- Guard library + tests: `cli/lib/nftban/lib/ssh_admin_port_guard.sh`, `cli/lib/nftban/tests/ssh_socket_port_mismatch_v155_test.sh`, `cli/lib/nftban/tests/ssh_port_change_lifecycle_v155_test.sh`.
- Validator: `tools/validation/ssh_port_change_lifecycle_validate.sh`.
