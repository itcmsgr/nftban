# PR-18 — Update Apply Orchestration Contract

**Status:** Draft — READY FOR IMPLEMENTATION (under strict contract enforcement)
**Scope:** G3-U5 .. G3-U10
**Pinned invariants:** INV-U-001 / INV-U-002 / INV-U-003

---

## Single-sentence contract

> PR-18 is orchestration-only: update apply may invoke the existing
> rebuild/lifecycle authority, but may not implement any independent apply,
> mutation, recovery, validation, or authority-taking behavior.

---

## Call graph (critical proof surface)

```
runUpdateApply  (new — orchestration only)
     │
     ├── update.Preflight              (existing — read-only, PR-16/PR-17)
     ├── exec.Run("nftban", "firewall", "rebuild")
     │        │
     │        └── firewall_rebuild     (existing — shell, cli/lib/nftban/cli/cmd_firewall.sh:1070)
     │             │
     │             ├── _firewall_rebuild_core
     │             ├── nftban_rebuild_recovery.sh  (existing — recovery)
     │             └── rebuild/marker.go            (existing — classification)
     │
     ├── exec.Run("/usr/lib/nftban/bin/nftban-validate", "--json")   (validator gate)
     │    ↑ absolute path via fhs.NftbanValidateBin — /usr/lib/nftban/bin
     │      is NOT in default $PATH. Parity gate FC-1 (2026-04-19).
     │
     └── sf.Transition(...)            (existing — lifecycle state machine)
```

**No new mutation path.**
**No new validator path.**
**No new recovery path.**
**No new authority path.**

---

## Canonical entry points PR-18 orchestrates (never reimplements)

| Phase | Canonical entry | Owner |
|---|---|---|
| Preflight | `update.Preflight(exec, log, origin)` | PR-16 + PR-17 |
| Target detection | `update.DetectVersions(exec, sourceDir, origin, log)` | PR-16 + PR-17 |
| Recovery planning | `update.BuildRecoveryPlan(exec)` | PR-17 |
| **Rebuild execution** | `nftban firewall rebuild` → `firewall_rebuild` | v1.96 (shell) |
| **Recovery** | `_rebuild_*` family in `nftban_rebuild_recovery.sh` | v1.96 (shell) |
| **Validator gate** | `nftban-validate --json` | v1.78+ (Go) |
| **State transition** | `sf.Transition(State, Phase, reason)` | v1.73+ (installer) |

PR-21 will migrate `firewall_rebuild` to Go and delete the shell layer.
PR-18 must not pre-empt that migration — orchestrate the shell path today.

### Per-run arguments (v1.230.0 Gate 6R)

`nftban firewall rebuild` is invoked with three arguments whose VALUES are allocated
per operation and cannot be enumerated as a fixed whitelist string:

| Argument | Why the value varies |
|---|---|
| `--result-file` | the per-operation result contract path; a fixed name reintroduces the stale-record and cross-run hazards the contract removed |
| `--operation-id` | binds the record to THIS operation, so a foreign or stale record is refused |
| `--execution-witness` | records that the rebuild crossed the execution boundary, so "no contract" can be told apart from "never started" |

`ApplyWhitelistPerRunArgs` in `apply_contract.go` declares the allowed flags, and
`matchesPerRunArgvShape` validates the SHAPE of the tail: only declared flags, each at
most once, each with a non-empty single-token value. It is deliberately **not** a bare
prefix match — a prefix would accept any tail at all.

Apply still passes **no** `--install-context`: this plane keeps the interactive
fail-fast lock policy, and no refusal retry happens here.

`nft -c` is **not** whitelisted, so the projection-validity leg of the post-update
convergence contract is **not** applied on this plane. Adding it is a contract decision,
not an implementation detail.

---

## Forbidden patterns (automatic NO-GO on PR-18)

1. New `exec.Run("nft", ...)` call in `runUpdateApply` (nft only via rebuild)
2. New `exec.WriteFile(...)` call that targets anything under `/etc/nftban/` or `/usr/lib/nftban/`
3. New authority-classification call outside `authority.Classify` (which lives upstream of rebuild)
4. New `systemctl` call that stops/starts external firewalls (UFW/firewalld/iptables)
5. New rollback mechanism — any failure must delegate to `firewall_rebuild`'s own recovery
6. Any path where `nftban-validate` is NOT called after apply
7. Any path where `.conf.local` files are opened in write mode
8. Any retry/loop/fallback logic that could mask a rebuild failure

CI enforces 1-5 via a call-path audit step; 6-8 via behavioural tests.

---

## Stop condition

If implementation pressure appears that requires any of:

- new apply logic
- bypass of rebuild
- direct config mutation
- custom recovery
- custom authority handling

→ **STOP PR-18 immediately.** Split that work into a separate design/audit PR. Do NOT solve it inside PR-18.
