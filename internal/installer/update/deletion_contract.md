# PR-21 — Shell Update-Path Deletion Contract (G3-U14)

**Status:** Draft
**Type:** Point-of-no-return deletion PR
**Scope:** Remove the shell `cmd_update*.sh` family; route `nftban update` through the Go orchestrator
**Authorization basis:** G3-U-REBUILD-PARITY PASSED on both required hosts

---

## Pinned sentence

> PR-21 is shell-update-path deletion only: it removes the legacy
> cmd_update*.sh family and redirects the `nftban update` CLI entry to
> the Go orchestrator. It must not change mutation, validator, recovery,
> or authority semantics; it must not add a compatibility shim that
> keeps deleted logic alive; and zero runtime references to the deleted
> files may remain after merge.

---

## Parity authorization (verbatim from §8 of G3_U_REBUILD_PARITY_EVIDENCE.md)

> G3-U-REBUILD-PARITY PASSED on hosts lab2 (Ubuntu 24.04 DEB) and lab4
> (AlmaLinux 9 RPM) per evidence bundles at `parity-lab2-postfix.tar.gz`
> (68 KB) + `parity-lab4-postfix.tar.gz` (68 KB) on 2026-04-19, reviewed
> by automated run via itcmsgr. PR-21 may delete shell update paths
> under the parity proof recorded there.

---

## Deletion inventory

| File | LOC | Disposition |
|---|---:|---|
| `cli/lib/nftban/cli/cmd_update.sh` | 2232 | **REPLACE** with thin Go-dispatcher (~30 LOC) |
| `cli/lib/nftban/cli/cmd_update_backup.sh` | 159 | DELETE |
| `cli/lib/nftban/cli/cmd_update_detection.sh` | 432 | DELETE |
| `cli/lib/nftban/cli/cmd_update_helpers.sh` | 257 | DELETE |
| `cli/lib/nftban/cli/cmd_update_methods.sh` | 444 | DELETE |
| **Total LOC removed** | **~3,494** | (2232 replaced + 1292 deleted) |

---

## Scope

### In scope

- Delete the 4 shell helper files (1292 LOC)
- Replace `cmd_update.sh` with a ~30-line thin dispatcher that `exec`s the
  Go installer: `/usr/lib/nftban/bin/nftban-installer --mode=upgrade`
- Update the comment reference at `internal/installer/history/history.go:56`
  that points at the deleted `_update_write_history()` shell function
- Grep audit: `zero` runtime references to any deleted file or
  deleted shell function (`_cmd_update_*`, `_update_*`, `_detect_install_type`)
- CI gate addition: structural grep that fails if any future PR
  reintroduces shell update logic

### Explicitly out of scope

- ❌ No mutation, validator, recovery, or authority behaviour change
- ❌ No compatibility shim that keeps deleted logic alive
- ❌ No config-preservation regression (`.conf.local` stays untouched)
- ❌ No `ApplyWhitelist` change (Go contract layer unchanged)
- ❌ No shell-side `_detect_install_type` replacement — operators who ran
  `nftban update` previously got package-origin auto-detect in shell; PR-17
  added the same to Go. The thin dispatcher lets the Go path resolve origin.
- ❌ No user-facing CLI taxonomy change beyond the transparent rewrite

---

## Non-negotiable invariants

1. **No hidden fallback.** The new `cmd_update.sh` dispatcher must not
   call any deleted function, must not check for a deleted file, and
   must not preserve any behaviour from the old 2232-LOC implementation.
2. **Zero residual references.** `grep -rn "cmd_update_helpers\|cmd_update_methods\|cmd_update_detection\|cmd_update_backup" --include="*.sh" --include="*.go" --include="*.yml"` must return 0 matches after merge (excluding the deletion commit's own log).
3. **Zero shell-function residuals.** `grep -rn "_cmd_update_\|_update_write_history\|_detect_install_type" ...` must return 0 matches after merge.
4. **`nftban update` UX preserved.** Running `nftban update` still dispatches to a working path (the Go orchestrator).
5. **All existing Go-path invariants preserved** (INV-U-001/002/003 + G3-U-* + state↔exit discipline from PR-19).

---

## Mandatory merge evidence

- [ ] G3-U-REBUILD-PARITY authorization line pasted verbatim in PR body
- [ ] Evidence bundle paths referenced in PR body
- [ ] Grep audit output showing 0 residual references (run in CI)
- [ ] New `cmd_update.sh` dispatcher is ≤ 40 LOC
- [ ] Dispatcher does NOT source any other file from the shell update family
- [ ] Dispatcher does NOT parse args beyond the minimum needed to forward
- [ ] Existing CI gates (Runtime Truth + Update Canonization) stay green

---

## Stop condition

If review or CI surfaces:

- any residual reference not caught by the grep audit
- any behavioural change beyond removing legacy paths
- any hidden dependency on deleted functions
- any regression in `.conf.local` preservation
- any new parity-relevant divergence

→ STOP merge. Treat as a blocker. Fix or abandon the PR.

---

## Implementation plan (commit-by-commit)

1. **Contract seed** — this file (lands first; zero code change)
2. **Replace `cmd_update.sh`** with thin dispatcher + delete 4 helpers atomically in one commit (keeps `nftban update` UX working at every revision)
3. **Clean stale references** — `history.go:56` comment
4. **CI grep audit** — structural check that fails on any future re-introduction of deleted names
