# NFTBan Architecture Policy: Single-Writer nftables

**Status**: MANDATORY
**Effective**: Immediately
**Enforcement**: CI gate (fails PR on violation)

---

## Policy Statement

> **All nftables WRITE operations MUST go through the nftband daemon.**
> No other component may directly execute `nft add|delete|flush|insert|create|destroy|replace`.

> **All /etc/nftban/blacklist.d/ writes MUST go through the nftband daemon.**
> CLI and modules use IPC `persist_ban`/`unpersist_ban` for persistent bans.

---

## Definitions

### WRITE Operations (MUST go through daemon)
```
nft add        # Add element, rule, chain, set, table
nft delete     # Delete element, rule, chain, set, table
nft flush      # Flush set, chain, table, ruleset
nft insert     # Insert rule at position
nft create     # Create table, chain, set (fails if exists)
nft destroy    # Destroy table, chain, set (fails if not exists)
nft replace    # Replace rule
```

### READ Operations (allowed directly, temporarily)
```
nft list       # List ruleset, tables, chains, sets
nft -j list    # JSON output for status/metrics
```

Read operations may remain direct during migration but should eventually proxy through daemon for caching and consistency.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         ALLOWED                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   CLI (bash)  ───IPC───▶  nftband  ───nft───▶  kernel          │
│   nftban-core ───IPC───▶  daemon   ───────────▶  nftables      │
│   cron jobs   ───IPC───▶           │                           │
│   modules     ───IPC───▶           │                           │
│                                    │                           │
│                          ┌─────────┴─────────┐                 │
│                          │ ONLY WRITER HERE  │                 │
│                          │ cmd/nftband/      │                 │
│                          │ pkg/nftbackend/   │                 │
│                          └───────────────────┘                 │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                        FORBIDDEN                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   CLI (bash)  ───nft add───▶  kernel     ❌ VIOLATION          │
│   cron job    ───nft flush──▶  nftables  ❌ VIOLATION          │
│   Go pkg      ───exec.Command("nft", "add")  ❌ VIOLATION      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Allowed Locations for nft WRITE Commands

| Path | Purpose |
|------|---------|
| `cmd/nftband/*.go` | Daemon implementation |
| `pkg/nftbackend/*.go` | Backend abstraction (used only by daemon) |

**All other locations are violations.**

---

## IPC Protocol

Socket: `/run/nftban/nftband.sock`

### Available Methods

| Method | Purpose | Scope |
|--------|---------|-------|
| `ban` | Add IP to nftables set | Kernel state |
| `unban` | Remove IP from nftables set | Kernel state |
| `persist_ban` | Add IP to /etc/nftban/blacklist.d/ | File persistence |
| `unpersist_ban` | Remove IP from blacklist.d files | File persistence |
| `add_element` | Add element to any set | Kernel state |
| `delete_element` | Remove element from set | Kernel state |
| `flush_set` | Flush all elements from set | Kernel state |
| `apply_ruleset` | Apply .nft file atomically | Kernel state |
| `check` | Check if IP is banned | Read-only |
| `ping` | Health check | Read-only |

### Request Format
```json
{
  "method": "ban|unban|persist_ban|unpersist_ban|...",
  "params": {
    "ip": "1.2.3.4",
    "timeout": 3600,
    "reason": "manual",
    "source": "login|portscan|ddos|manual"
  }
}
```

### Response Format
```json
{
  "success": true|false,
  "data": { ... },
  "error": "error message if failed"
}
```

### Error Codes
| Code | Meaning |
|------|---------|
| `OK` | Operation succeeded |
| `INVALID_IP` | IP address format invalid |
| `ALREADY_BANNED` | IP already in blocklist |
| `NOT_BANNED` | IP not in blocklist (for unban) |
| `NFT_ERROR` | nftables command failed |
| `DAEMON_BUSY` | Daemon is processing, retry |

---

## CI Enforcement

Two CI gates enforce single-writer architecture:

### 1. nft WRITE Command Check

```bash
# scripts/ci/check-nft-writes.sh
# Fails if nft WRITE commands found outside allowed paths
```

**Pass Criteria:**
- `nft (add|delete|flush|insert|create|destroy|replace)` found ONLY in:
  - `cmd/nftband/`
  - `pkg/nftbackend/`
  - `pkg/sync/` (used only by daemon)
  - `scripts/ci/` (the check itself)

**Fail Criteria:**
- Any match in `cli/lib/nftban/**/*.sh`, `cron/`, etc.

### 2. Netlink Import Guard

```bash
# Inline in .github/workflows/ci.yml
# Fails if github.com/google/nftables imported in CLI
```

**Pass Criteria:**
- `github.com/google/nftables` imported ONLY in:
  - `cmd/nftband/`
  - `pkg/nftbackend/`
  - `pkg/sync/`

**Fail Criteria:**
- Any import in `cmd/nftban-core/` (CLI must use `pkg/ipc`)

---

## Migration Path

### Phase 1: Daemon Authority
1. Implement `handleBan()`, `handleUnban()`, `handleSync()` in nftband
2. These handlers call nft directly (temporary)
3. CI gate enabled but in warn-only mode

### Phase 2: IPC Clients
1. Create `pkg/ipc/client.go` for Go callers
2. Create `cli/lib/nftban/lib/nft_ipc.sh` for bash callers
3. Both connect to `/run/nftban/nftband.sock`

### Phase 3: Migration
1. Refactor `pkg/firewall/sync.go` to use IPC client
2. Refactor shell scripts one by one
3. CI gate switched to fail mode

### Phase 4: Cleanup
1. Remove all direct nft calls outside daemon
2. Proxy read operations through daemon (optional)
3. Delete migration compatibility code

---

## Emergency Mode

If daemon is unavailable, CLI may fall back to direct nft calls ONLY if:

1. Explicitly enabled: `NFTBAN_EMERGENCY_MODE=1`
2. Logged with WARNING level
3. User is root

This is for disaster recovery, not normal operation.

---

## Rationale

| Problem with direct writes | Solution with daemon |
|---------------------------|---------------------|
| Race conditions between CLI and cron | Serialized through single writer |
| Inconsistent state under load | Atomic transactions |
| No audit trail | All operations logged |
| Permissions scattered | Single privileged process |
| Testing difficulty | Mock daemon for tests |

---

## Validation

Run this command to check compliance:

```bash
./scripts/ci/check-nft-writes.sh
```

Exit code 0 = compliant, non-zero = violations found.

---

*Document version: 1.0*
*Last updated: 2026-01-01*
