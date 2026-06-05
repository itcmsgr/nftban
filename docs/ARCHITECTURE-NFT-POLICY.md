# NFTBan — nftables Write Policy (single-writer architecture)

**Status:** authoritative. **Added:** v1.150 (AUTH-5). **Audit:** `V150_BAN_UNBAN_SINGLE_AUTHORITY_AUDIT.md` (verdict PASS_WITH_FINDINGS — single-writer model holds).

This document is the in-tree reference that code comments and the CI gate (`scripts/ci/check-nft-writes.sh`) point to. It states **who may write nftables**, the **sanctioned exceptions**, and the **CI contract** that enforces it.

---

## 1. The rule

**The `nftband` daemon is the only process that writes nftables in normal operation.**

- The sole writer is `internal/nftbackend.Backend` — its header declares it "the ONLY authorized location for nftables WRITE operations" (`backend.go:19-21`). It writes via **netlink** (`google/nftables`) through one shared connection, `internal/setsync.NFTManager` (`nft_manager.go`). The only exec-based write is `Backend.ApplyRuleset` (`backend.go:691`, `nft -f`, unavoidable for loading `.nft` files).
- **Authorization:** the daemon's Unix socket `/run/nftban/nftband.sock` (`0660 root:nftban`) is gated by **SO_PEERCRED** (`daemon_socket.go`), allowing uid 0 or `nftban`-group members, enforced per request.

## 2. How everything reaches the authority

| Caller | Path to the daemon | Reference |
|--------|--------------------|-----------|
| `nftban ban` / `unban` (CLI) | `cmd_ban.sh`/`cmd_unban.sh` → `nftban-core ban/unban` → `pkg/ipc` (socket). `nftban-core` writes **no** nft (imports neither `internal/nftbackend` nor `internal/setsync`; its only nft exec is a `get element` read-verify). | `cmd/nftban-core/cmd_ban.go` |
| In-process detection modules (portscan / ddos / botguard / loginmon) | `bus.Publish(EventBan)` → one daemon subscriber → `backend.Ban` (with whitelist re-check) | `daemon_init.go` |
| suricata dispatcher | `pkg/ipc` Ban | `ban_handler.go` |
| botguard enforcement | daemon-only opqueue → `nftbackend_wrapper` (shared backend) | `enforcer.go` |
| shell helpers needing a set write | `nft_ipc_*` (`nft_ipc.sh` → socket) | `lib/nft_ipc.sh` |

**Reads** (`nft list` / `nft get`) are unrestricted and never mutate.

## 3. Sanctioned exceptions (direct nft, by design)

These are allowlisted in `scripts/ci/check-nft-writes.sh` (each with a one-line rationale). Categories:

- **AUTHORITY** — `cmd/nftband/`, `internal/nftbackend/`, `internal/setsync/`.
- **IPC** — `nft_ipc.sh` (client; also hosts the gated emergency fallback).
- **RENDER / REPAIR (root-only)** — the renderer (`nft_fragment.sh`), firewall rebuild/restore/flush (`cmd_firewall.sh`, `cmd_flush.sh`), repair/recovery (`nftban_health_fixes.sh`, `autoheal.sh`, `cmd_health_core.sh`, `health_checks_security.sh`), conflict resolution (`nftban_firewall_conflicts.sh`), boot init (`firewall-init-with-delay.sh`), maintenance rotation (`maintenance.sh`), log-chain rules (`cmd_firewall_logs.sh`), whitelist element management (`cmd_whitelist.sh`), monitoring (`cmd_zabbix.sh`).
- **EMERGENCY-GATED** — direct write only under `NFTBAN_EMERGENCY_MODE=1` (default **0**) or a confirmed daemon-down state:
  - `nftban_ddos_classic.sh` — **DDoS penalty escalation now routes through the daemon IPC** (`nft_ipc_add_element`, v1.150 AUTH-1); the remaining direct write is the gated emergency fallback only.
  - `service_control.sh` (`nftban disable --flush-rules` when the daemon may be down), `nftban_system_ip.sh` (postinst whitelist safety when the daemon is down).
- **LOW-LEVEL TOOLS** — `cli/sbin/nftban-apply` (ruleset `nft -f`), `cli/sbin/nftban-rollback` (`nft -f` + table delete on emergency rollback).
- **TEST-ONLY** — `scripts/test_server_cleanup.sh` (lab teardown), the CI gate itself, and `nft_writer_authority_v150_test.sh` (asserts on this policy).

A write **outside** these allowlisted paths is a violation and fails CI.

## 4. CI enforcement contract

`scripts/ci/check-nft-writes.sh` (wired in `ci-architecture.yml`, "Policy Gates"):

- **WRITE** (`nft add/delete/flush/insert/create/destroy/replace`, `nft -f`, and Go `exec.Command("nft", "add"…)`) outside the allowlist → **fails the PR**.
- **READ** (`nft list/get`) → warned, not enforced.
- **Scan scope (v1.150 AUTH-2):** `cli/`, `pkg/`, `install/`, `scripts/` (`*.sh`), the extensionless `cli/sbin/*` tools, and `internal/` Go. (Previously `scripts/`, `cli/sbin/*`, and `internal/` were blind spots.)
- **Allowlist (v1.150 AUTH-3/AUTH-4):** annotated per entry; the stale `nftban_geoban.sh` entry was removed (0 direct writes — it routes via `nft_ipc_apply_ruleset`).

**Positive assertions** (`cli/lib/nftban/tests/nft_writer_authority_v150_test.sh`): `nftban ban`/`unban` route through `nftban-core`/IPC (no direct nft); the DDoS penalty scan calls `nft_ipc_add_element` in normal mode; the emergency fallback stays **off by default**; the widened scan catches writes in `scripts/`, `cli/sbin/*`, and `internal/`.

## 5. Adding a new nft write

1. **Default:** don't. Send an IPC request — shell `nft_ipc_*` (`lib/nft_ipc.sh`) or Go `pkg/ipc.Client`.
2. For a bulk ruleset: `nft_ipc_apply_ruleset` with a `.nft` file.
3. If a direct write is genuinely unavoidable (render/repair/boot/emergency), add the file to the allowlist in `check-nft-writes.sh` **with a one-line rationale and a category**, and prefer gating it behind `NFTBAN_EMERGENCY_MODE` / a daemon-down check.

See also: the `Firewall-Anchor-Architecture` wiki page.
