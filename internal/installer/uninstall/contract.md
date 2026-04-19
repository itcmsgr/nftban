# PR-22 — Uninstall Lifecycle Scaffold Contract

**Status:** Draft
**Authorization basis:** `V1100_LIFECYCLE_COMPLETION_CONTRACT.md` §13 (frozen 2026-04-19)
**Scope:** Uninstall lifecycle mode **scaffold** — detect + dry-run plan only
**Point-of-no-return work deferred:** authority release (PR-23), CSF restoration enforcement (PR-24), purge vs remove artifact execution (PR-25), verify gate (PR-26)

---

## Pinned sentence

> PR-22 is detect + dry-run plan only. It must not flush any chain,
> remove any table, disable any service, delete any file, touch any
> `.conf.local`, or re-enable any external firewall. The dry-run output
> reads like a release contract preview, not a debug dump, and
> explicitly states that no phase beyond Plan is implemented yet.

---

## Claim surface (strictly what PR-22 may ship)

1. **State model additions** in `internal/installer/state/machine.go`:
   - `StateUninstallPlanning` — detect phase produced a release plan
   - (Other uninstall states land in PR-23/25; PR-22 only needs Planning so the dry-run can transition to it and stop)

2. **New package** `internal/installer/uninstall/`:
   - `authority.go` — read-only classifier over 4 states (below)
   - `prior.go` — read-only check for recorded prior-authority artifact; 3 states
   - `plan.go` — `Plan` struct + `BuildPlan` + `Render` + JSON round-trip
   - `uninstall_test.go` — unit tests (no real-host mutation)

3. **Installer dispatch** in `cmd/nftban-installer/`:
   - New flag/mode wiring: `--mode=uninstall` (and `--dry-run` already exists)
   - `runUninstallDryRun(ctx, exec, sf, cfg, log) int` — orchestrator mirroring `runUpdateDryRun` in shape:
     1. Detect phase — authority classification + prior-record probe + artifact inventory (read-only)
     2. Plan phase — `BuildPlan` + `Render`
     3. Explicit "not yet implemented beyond this phase" log marker
     4. Return 0 (successful plan) or non-zero (detect/plan failure)

4. **Flag surface** in `flags.go`:
   - `--mode=uninstall` — accepted
   - `--purge` — plan-only in PR-22; no mutation
   - `--force-delete-operator-config` — plan-only in PR-22; no mutation
   - `--restore-prior-authority` — plan-only in PR-22; no mutation

Flag combinations are reflected in the plan's rendered fields; they do
not trigger any mutation code in PR-22 because no mutation code exists
yet.

---

## Authority classification — 4 states (read-only)

Per the user's scope lock for PR-22:

| State | Condition (all read-only) |
|---|---|
| `AuthorityNFTBan` | `ip nftban` table present AND `nftband.service` active |
| `AuthorityExternal` | external firewall detected authoritative (UFW active / firewalld active / iptables rules present without nftban table) |
| `AuthorityNone` | no authoritative firewall detectable |
| `AuthorityAmbiguous` | both nftban and external present (degraded/mid-install state) OR detection inconclusive |

No takeover/release logic. No mutation. Classification only.

---

## Prior-authority record — 3 states

Per the user's scope lock:

| State | Meaning |
|---|---|
| `NoRecord` | No prior-authority artifact exists on disk |
| `RecordUsable` | Record exists, parseable, references a known firewall type and state |
| `RecordIncomplete` | Record exists but is missing required fields, unreadable, or references an unknown type |

PR-22 classifies and reports; it does not enforce. Enforcement
(refusing `--restore-prior-authority` when record is Incomplete) is
PR-24 scope. The PR-22 plan output must make this ambiguity visible to
the operator.

The artifact is stored at
`/var/lib/nftban/state/prior_authority.json` (proposed; final path in
PR-23). PR-22 only reads — it does not write any prior-authority
artifact (that's install-side expansion per v1.100 Q9, tracked for
PR-23 or a companion install-mode PR).

---

## Plan output — contract-language rendering

`Render(w io.Writer)` prints:

```
NFTBan Uninstall — Plan
═══════════════════════════════════════════════════════════════

  Requested mode              : <remove|purge|purge+force-delete-operator-config>
  Artifact policy             : <textual description of §4.4 contract row>
  Current authority           : <AuthorityNFTBan|External|None|Ambiguous>
  Target authority            : AuthorityNone (default) OR <prior recorded firewall>
  Restore requested           : <yes|no>
  Restore authorized          : <yes|no: requires recorded prior + flag>
  Prior-authority record      : <NoRecord|RecordUsable|RecordIncomplete>
  Detected external firewall  : <none|ufw|firewalld|iptables|csf>

  Phases that would mutate (NOT IMPLEMENTED in PR-22):
    • Switch   — flush + remove nftban tables (PR-23)
    • Configure — disable/mask services, stop timers (PR-23)
    • Configure — artifact removal per mode (PR-25)
    • Switch   — external firewall restoration (PR-24, conditional)
    • Validate — post-uninstall verification (PR-26)

  Warnings:
    <list of any operator-visible warnings, e.g. "restore flag set but
     no prior-authority record on disk">

  Scope boundary:
    PR-22 ships detect + plan only. No mutation code exists in this
    release. Running this command does NOT uninstall nftban. To plan
    an actual uninstall in a future release, the later PRs in the
    v1.100 track must land first.
```

The explicit scope-boundary block is mandatory (not optional) — it
prevents the PR-21-class confusion where operators or reviewers assume
broader authorization than the contract actually provides.

---

## Explicit non-goals (PR-22 strict)

- ❌ No kernel mutation (`nft add/delete/flush` forbidden)
- ❌ No service lifecycle (`systemctl disable/mask/stop/stop/start/restart/reload/enable/unmask` forbidden)
- ❌ No filesystem writes under `/etc/nftban/`, `/usr/lib/nftban/`, `/usr/sbin/nftban*`
- ❌ No `.conf.local` touch, read-or-write
- ❌ No external firewall touch (UFW/firewalld/iptables/CSF)
- ❌ No writing any prior-authority record (read-only detection only)
- ❌ No user/group deletion
- ❌ No package-manager transactions (rpm/dpkg forbidden)
- ❌ No dependency on the (future) uninstall-verify gate
- ❌ No coupling to maintenance subsystem (Q5=B — adjacent, not phase)

---

## Test coverage PR-22 must ship

- Authority classifier: 4 happy-path cases (one per state) + each "detection fails cleanly" path
- Prior-record detector: 3 states (NoRecord / RecordUsable / RecordIncomplete) + malformed JSON path
- `BuildPlan` / `Render`: per-mode rendering (remove, purge, purge+force, +restore); each flag combination produces the right field values; explicit scope-boundary block always present
- Call-path purity test: `runUninstallDryRun` trace contains **zero** mutation-flavored commands (reuse the PR-18 contract-audit harness pattern; add a new whitelist scoped to uninstall's read-only surface)
- Contract regression: `--mode=uninstall --dry-run` exits 0 on a host where the plan is computable, even if authority is ambiguous

---

## CI gate additions

- `G3-UN-PLAN-RENDERS` — structural check that `runUninstallDryRun` produces the §"Plan output" contract language (headers, field labels, scope-boundary block)
- `G3-UN-NO-MUTATION` — structural grep on `internal/installer/uninstall/*.go` + `cmd/nftban-installer/uninstall_*.go` rejecting any `exec.Run("nft", …)` with add/flush/delete, `systemctl` lifecycle verbs, `exec.WriteFileAtomic`/`os.WriteFile`/`os.Remove` calls, and external-firewall binary names

Both gates are fail-fast structural checks — they run before the unit
tests so a reviewer sees the scope violation immediately if one is
introduced.

---

## Audit C regression note — auto-elevation to dry-run MUST be revisited in PR-23

PR-22's `--mode=uninstall` without `--dry-run` auto-elevates to
`--dry-run` with a loud stderr banner. This is acceptable ONLY because
no mutation code exists in PR-22 — the auto-elevation is the safe
default in the absence of mutation.

**The moment PR-23 lands the Switch phase (authority release), this
auto-elevation MUST be removed or changed to REFUSE rather than silently
elevate.** Leaving it in place past PR-22 would teach operators that
`--mode=uninstall` is "safe by default," then PR-23 would change that
meaning without an audit prompt — a UX-drift attack on the contract
surface.

PR-23 acceptance criterion: either
- the auto-elevation block in `cmd/nftban-installer/flags.go` is deleted
  (so `--mode=uninstall` mutates unless `--dry-run` is explicit), OR
- the auto-elevation is replaced with an explicit REFUSAL that requires
  the operator to choose between `--dry-run` and `--confirm-mutation`
  (no silent default behaviour in either direction)

This audit note lives in the contract doc so the PR-23 reviewer has a
pre-written reminder that isn't buried in a branch commit log.

---

## Stop condition

If any PR-22 commit requires:
- writing to anywhere under `/etc/nftban/` or `/var/lib/nftban/`
- invoking any service lifecycle command
- invoking `nft` with anything other than `list`
- touching any external firewall binary
- reading `.conf.local` contents (even for planning — the plan only needs to know it EXISTS, not what it contains)

→ **STOP PR-22.** Push the work to PR-23 or later. PR-22's scope lock
is the point of the contract seed — bending it collapses the evidence
chain for the whole v1.100 track.

---

## Standing lifecycle-truth rule (from PR-22B merge)

**No new lifecycle code may bypass the shared authority predicate, the
history-write gate, or the dry-run contract.**

Concretely, every new or modified lifecycle code path must:

1. use `authority.IsNftbanAuthoritative(exec)` — not re-implement the
   predicate or proxy it via `NftTableExists` alone
2. respect the `!cfg.dryRun && state.IsApplyTerminal(sf.State)` history
   gate — no back-door direct writes to `update-history.json`
3. respect `StateFile.DryRun` — no direct writes to `install_state` or
   any path under `/var/lib/nftban/` or `/etc/nftban/` during dry-run
4. route `authority.Ambiguous` through emergency-SSH injection before
   any mutation — never silent-continue, never collapse to Fresh/None
5. surface `--panel-auto-takeover` explicitly if it needs panel consent
   — no implicit panel auto-approve path

CI gates (PR-22A + PR-22B): `G3-UN-NO-MUTATION`, `G3-UN-PLAN-RENDERS`,
`G3-UN-HISTORY-PURITY`, `G3-U3` hard-assertions, `G3-U5..U10` extended
grep, `G3-IN-REFUSE-DRY-RUN`, `G3-IN-FLAG-COMBOS`. Any lifecycle PR
that bypasses the rule above is expected to fail at least one of
these gates; if it doesn't, the gate needs extension, not the rule.

---

## Pre-PR-23 blockers (tracked follow-up PRs)

PR-23 (uninstall mutation: Switch phase + authority release) must NOT
start until all six items below have landed and been verified by a
narrow-scope audit. Each is its own PR with an explicit micro-contract
and one falsifiable proof test per PR-22B merge discipline.

| # | PR | Purpose | Blocking because |
|---|---|---|---|
| 1 | Prior-authority record hardening | Add `recorded_at`, `installer_version`, explicit `active_at_install=false` handling to `prior.go` | PR-24 restore enforcement cannot trust under-defined `RecordUsable` |
| 2 | External-firewall detection unification | One shared function + one precedence order used by install/update/uninstall | Detection drift between modules will cause disagreement under takeover/restore |
| 3 | Kernel/service snapshot CI gate | `nft list tables` + `systemctl is-active` diff before/after every dry-run path | Filesystem snapshot alone cannot prove process-level purity |
| 4 | Exec-trace CI gate | `strace -f -e trace=execve` (or equivalent) around dry-run paths; assert no forbidden mutators spawned | Strictest purity guarantee; catches dynamically-constructed commands |
| 5 | Auto-elevate shim removal gate | CI rule: PR-23-class changes blocked while the shim block in `flags.go` still exists | Prevents scaffold-era UX semantics leaking into mutation-era behavior |
| 6 | Payload integrity minimum checks | Minimum-size / header-presence for `nftban.conf`, `nftables.conf` | Presence-only validation lets a truncated file pass |

Phase 3 gating: once items 1–6 are merged and CI green, a focused
verification audit runs with ONLY these questions:

1. Is dry-run still pure across install / update / uninstall?
2. Is there any history / state drift?
3. Is the authority predicate still consistent across callers?

No exploratory scope in that audit. PR-23 starts only after it returns
clean.
