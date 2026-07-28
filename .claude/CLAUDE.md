# NFTBan — Agent Operating Contract

This file governs every agent session in this repository. It is an **execution contract**, not a
tutorial: each rule states what binds you, why it exists, where the full authority lives, and when to
stop.

NFTBan is a Linux firewall and intrusion-prevention system built on **nftables**. A defect here can
lock an operator out of a production host, or leave one unprotected while reporting success. Evidence
discipline is not ceremony — it is the product requirement.

---

## 0. Establish the baseline before claiming anything

**RULE.** Never hard-code the current version. Derive it:

```
VERSION           cat VERSION                 (no trailing newline — preserve that)
release date      cat VERSION_DATE            (strict ISO — and it must be CORRECT, not merely valid)
latest published  gh release list --limit 1
source authority  git rev-parse origin/main
open work         NFTBAN_ROADMAP/NFTBAN_PENDINGS_AND_BUGS_CURRENT.md  §0 baseline
```

**WHY.** A hard-coded version rots. This file previously declared `v1.195.0` while the project shipped
`v1.228.0`, and agents acted on it. A stale authority file is itself an authority defect.

**STOP** if those five disagree — report the conflict, do not pick one.

> **Dated snapshot, not permanent truth:** last reconciled baseline **v1.228.0 at `0c2a0d9a`,
> 2026-07-28** · production fleet 9/9 · labs 2/2 **not** updated (9/11). Re-derive; do not cite.

---

## 1. Authority hierarchy

**RULE.** When sources disagree, trust in this order:

```
1  runtime evidence on a real host    (nft list ruleset · systemctl · the actual exit code)
2  code at an exact commit            (git show <sha>:path — NOT the working tree)
3  the packaged artifact              (what the .deb/.rpm actually ships)
4  tests that can demonstrably fail
5  registers and ledgers              (intent and status — not behaviour)
6  comments, docs, summaries, prior agent reports
```

**WHY.** Comments lie. `NFTBAN_VALID_MODES` carried `# Used by other modules` with zero consumers. A
guard's header claimed two files "legitimately cannot route" through a durability helper whose
contract matched them exactly.

**AUTHORITY.** `docs/RUNTIME_MODE_AUTHORITY_CONTRACT.md` · `docs/adr/ADR-0001-runtime-mode-authority.md`

**STOP** before stating a behaviour you have only read *about*.

---

## 2. Label every claim

**RULE.** `MEASURED` / `INFERRED` / `NOT_YET_VERIFIED`. Never blur them. **A count is not evidence —
open the file.** Estimates are claims. Recon is a hypothesis.

**STOP** if you cannot label it.

---

## 3. A guard must measure the authority it claims to measure

**RULE.** Before trusting any check, ask *what does this actually assert?* A guard whose subject is not
the authority is **worse than no guard — it manufactures confidence.**

**WHY.** Nine instances found in one week:

```
VERSION_DATE format check passed while the value was stale   -> 5 wrong published releases
count guard pinned literal 66 against a registry of 71       -> bumping to 71 FAILED CI
a regression test seeded the reader's wrong vocabulary       -> locked the bug in permanently
a proposed tags: trigger would build and validate a SECOND independent artifact set
two tests asserted Depends against a file that does not build the package
three tests were absent from the authority index and NEVER RAN
a fsync guard exempted two files under a claim that was false
```

**STOP** and report if a "fix" would make a guard pass without changing what it measures.

---

## 4. A passing test is not sufficient

**RULE.** `PASS ≠ INJECTION PROVEN`. Every new guard must be shown to **fail**: break the fix
deliberately, capture the failure, restore, and say you did.

**WHY.** An eight-name denylist passed 39 of 41 assertions. Only a structural negative fixture could
distinguish it from a real fix.

**STOP** if a test cannot fail — fix the test first.

---

## 5. Derive sets; never pin names or counts

**RULE.** Guards compute both sides and compare. Never assert "the two names are X and Y" or "the count
is N".

**STOP** if your assertion would still pass after the thing it guards is removed.

---

## 6. One file set, one owner

**RULE.** Declare ownership before work starts. A deputy needing a change outside its set **reports**,
never edits:

```
CROSS_LANE_DEPENDENCY
FILE · REASON · REQUIRED_OWNER · BLOCKING_OR_NONBLOCKING · EXACT_CHANGE
```

`EXACT_CHANGE` must be applyable verbatim, without the owner re-deriving it.

**STOP** and report rather than reaching across a boundary — even for one line.

---

## 7. Parallel authoring, serial merging

**RULE.** Author concurrently in isolated worktrees. Merge one at a time in dependency order; rebase
later branches onto earlier merges. Never merge a stale branch.

**WHY.** Retiring a consumer must precede making its producer honest. Landing a router exit-truth fix
before retiring the units depending on the old false success converts a latent restart loop into an
active one.

**STOP** if the merge order is not explicit.

---

## 8. The two-register rule

```
NFTBAN_PENDINGS_AND_BUGS_CURRENT.md       OPEN work ONLY — unresolved/active/queued/deferred
NFTBAN_CLOSED_BUGS_IMPLEMENT_CURRENT.md   shipped/closed history, newest first
COMPLETED/ · forensic reports · scope docs   EVIDENCE LOCATIONS, never registers
```

**RULE.** No closed stubs, shipped-release bodies or duplicated forensic bodies in OPEN. **Planning
documents are evidence, never status authority** — if a plan body grows inside the register, move it to
a scope doc and leave a status row.

**WHY.** The OPEN register reached 56% planning content, inverting its own rule.

**STOP** before deleting: prefer MOVE over DELETE always, and preserve `IMMUTABLE` blocks **verbatim**
wherever they live.

---

## 9. Preserve chronology

**RULE.** Superseded records stay. Add a dated addendum that wins on conflict, plus a supersession
pointer. Distinguish:

```
IMMUTABLE_EVENT_RECORD      PRESERVE   — true when written
CURRENT_STATUS_PROJECTION   UPDATE     — true now
```

**WHY.** A superseded checkpoint is not a wrong one. Silently editing it destroys the audit trail and
hides how the conclusion was reached.

**STOP** if a correction requires altering a dated record rather than annotating it.

---

## 10. Handles are identities, not assignments

**RULE.** When releases are reordered, **do not rename handles** — `OPEN_V1_228_1_*` may legitimately
ship in v1.228.2. Record the mapping instead.

**WHY.** Renaming to chase a reshuffle rots every cross-reference.

---

## 11. Approval economy

```
IMPLEMENTATION_APPROVAL   one per bounded lane
PUBLICATION_APPROVAL      one per exact SHA + version
FLEET_APPROVAL            one separate production decision
UI environment clicks     EXECUTION of an existing approval, not a new decision
```

**RULE.** Inside an approved lane, do not stop for routine verified prerequisites. **Stop only for:**
scope expansion · a waived failed gate · destructive recovery · rollback execution · an unexpected
product defect · production-wide continuation after a canary · a semantic (not textual) conflict · a
new integration-only failure.

---

## 12. Evidence binds to an exact commit

**RULE.** Validation attaches to one SHA. If the commit changes, evidence does **not** carry forward.
Verify with `git show <sha>:path`, not the working tree. Trusted-gate approval binds to a SHA — never
to a branch or PR number.

**STOP** if the head moved after approval; re-run the gate.

---

## 13. CI truth

```
PAGINATION            REQUIRED   (unpaginated returns 30 of 93 — failures hide beyond page 1)
LATEST_RUN_PER_NAME   REQUIRED
STABLE_DOUBLE_FETCH   REQUIRED
NONTERMINAL_COUNT     0
LATE_CREATED_RUNS     0
```

**RULE.** `PR_CHECK_GREEN ≠ ALL_PATHS_EXECUTED`. `SKIPPED_PATH = UNTESTED_PATH`. A check green on a PR
may simply not have run the failing path — publication steps are gated on
`github.event_name != 'pull_request'`. Failed attempts are **never erased**.

**Local gates are non-deterministic:** the same commit has produced different `ci-bash` pass/fail sets
across runs. A single run does not establish a baseline — reproduce before attributing a failure.

**STOP** if the check set grew between polls (observed 35 → 71). Wait for terminal.

---

## 14. Release gates

**RULE.** Package-native validation on **lab2 (DEB)** and **lab4 (EL9/RPM)** is required before any
release. Production fleet rollout may be skipped **only by explicit owner decision** — and skipping it
never authorizes skipping labs.

The lab gate must exercise the **migration actually being shipped** — upgrade from the previous release
with the legacy state present — not a clean install of the new one.

**AUTHORITY.** `docs/releases/V1_228_0_VALIDATION_AUTHORITY_STATEMENT.md`

**STOP** on any DEB or RPM lifecycle failure.

---

## 15. Mode and detection authority

```
CONFIGURED ≠ EFFECTIVE      DEFINED ≠ REACHABLE       ENABLED ≠ DETECTING
RUNNING ≠ RECEIVING INPUT   DETECTED ≠ ENFORCED       SET MEMBERSHIP ≠ FIREWALL BLOCK
```

**RULE.** The four modes — `auto | classic | suricata | hybrid` — are **independent**; never collapse
them into "with/without Suricata". Detection input must be tested through the **actual runtime
consumer**, not a private helper. Enforcement requires a set referenced by a rule in a **HOOKED** chain.

**AUTHORITY.** `docs/MODE_ADMISSION_LEDGER.md` — absence from it means **unassessed**, not healthy.

**STOP** on mode ambiguity: resolve configured, effective and reason before any claim.

---

## 16. A component that cannot do its work must not report success

**RULE.** Never return 0 for work that did not happen.

**WHY.** Three live instances: the CLI router returning 0 when no entrypoint exists; a module loader
whose failure the router discarded; an installer printing `COMMITTED` after the state write failed.

**STOP** if a fix would convert a false success into a false *diagnosis* — that is not an improvement.

---

## 17. Exit codes are a shipped contract

**RULE.** Do not renumber. Load-bearing today: Nagios `0/1/2/3` · nine systemd units with
`SuccessExitStatus=` · `update` 10–13 · installer 0–10 · `--verify-install-state` `0` verified / `2`
determinate non-verified / `4` invalid invocation, live on production hosts and read by **both** package
scriptlets. `CLI_USAGE_ERROR = 1`.

**STOP** before changing any exit value — find the consumers first.

---

## 18. Completeness

**RULE.** **Never truncate a completeness search.** A negative conclusion from a partial list is an
assumption, not a finding. If a list is partial, say so.

**STOP** before writing "all", "none" or "only" without having enumerated.

---

## 19. Destructive operations

**RULE.** Before any irreversible delete, prove preservation is **sufficient**, not merely present.
**Copy, never move** — the original remains as reference. A mirror propagates deletions and is not an
archive.

**FORBIDDEN:** `rm -rf nftban*` · `find -delete` · `git clean -fdx` · `pkill -f`

**STOP** and ask before deleting content that exists in only one place.

---

## 20. Environment facts

```
NO LOCAL GO TOOLCHAIN   build/test Go on lab2; lab4 (EL9) has no Go
lab probes              from the hypervisor / ProxyJump — never the dev box
nftables tables         family-split ip/ip6 — NEVER inet
set sync                2x2: IPv4+IPv6 x whitelist+blacklist
git identity            contact@nftban.com (repo-local) — never a personal address
gh                      use --body-file for PR bodies
shellcheck              the repo gates at -S warning, not error
```

**STOP** if a task needs a local Go build — route it to the lab.

---

## 21. Ground truth

**NOT SUPPORTED — claiming these is a hallucination:**

```
Redis · cluster mode · port knocking · process tracking (PT_*) · fail2ban integration
iptables (nftables ONLY) · Webmin module
```

**Claim limits:** releases are **not GPG-signed** · SLSA L3 covers the **standalone Go binary only**,
not DEB/RPM payloads · PAM is **detection-only** · NFTBan is **not an antivirus** and **never compares
itself to other tools**.

**Key paths:** `/usr/lib/nftban/` install · `/etc/nftban/` config · `/var/lib/nftban/` data ·
`/var/log/nftban/` logs · `cli/lib/nftban/` source mirror.

**Command inventory — derive, do not trust a list:** top-level keys of `commands.registry.yml` minus
`global_options`, `standard_params`, `_metadata`. The registry's own `total_commands` field has been
wrong; treat it as a claim, not an authority.

---

## 22. `[VERIFIED]` protocol

When a request is prefixed `[VERIFIED]`: search and read **before** answering, cite `file:line` for
every claim, and close with a verification table.

```
✅ VERIFIED       read the code
⚠️ LIKELY         pattern-based, not confirmed
❓ UNVERIFIED     no evidence found
❌ NOT SUPPORTED  does not exist
```

Never invent file paths, function names, CLI commands, config options or performance numbers. If you
cannot find it, say **NOT FOUND**.

Related requests: *verify this* → re-check every claim against code and correct. *show me the evidence*
→ `file:line` plus the actual snippet. *which files did you read?* → the real list, and the searches run.

---

## 23. Documentation style

No marketing, no superlatives, no competitor comparisons. Calm senior-engineer tone. Mechanisms, not
adjectives. Every behaviour claim carries a version scope. **The CLI is a report** — kernel verification
proves enforcement; CLI output alone does not.

**AUTHORITY.** `.claude/docs/DOCS_WRITING_STANDARD.md` · `DOCS_DO_AND_DONT.md` ·
`CLAIMS_AND_WORDING_GUARDRAILS.md` · `WIKI_PAGE_CHECKLIST.md` · `DOCS_REWRITE_RULES_FOR_CLAUDE.md` ·
`.claude/WIKI_STYLE_GUIDE.md` · `.claude/BRAND_GUIDE.md`

---

## Canonical authorities

```
docs/RUNTIME_MODE_AUTHORITY_CONTRACT.md                    runtime mode doctrine
docs/adr/ADR-0001-runtime-mode-authority.md                the architectural decision
docs/MODE_ADMISSION_LEDGER.md                              per module x mode admission state
docs/SHELL_INPUT_PARSING_STANDARD.md                       shell input handling
docs/releases/V1_228_0_VALIDATION_AUTHORITY_STATEMENT.md   what "proven" means
NFTBAN_ROADMAP/NFTBAN_PENDINGS_AND_BUGS_CURRENT.md         OPEN work — single authority
NFTBAN_ROADMAP/NFTBAN_CLOSED_BUGS_IMPLEMENT_CURRENT.md     shipped history
NFTBAN_ROADMAP/V1_139_FHS_AUTHORITY_GRAPH.md               FHS ownership topology
```

---

## The standing invariant

> **A COMPONENT THAT FAILED TO PERFORM ITS REQUIRED WORK MUST NOT REPORT SUCCESS.**
>
> A feature is not code that exists. It is a complete production path that is **reachable, observable,
> enforceable, testable and recoverable.**
