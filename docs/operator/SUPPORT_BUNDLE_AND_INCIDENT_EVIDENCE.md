# Support bundle and incident evidence

**Verified against main @ `4cf715a0`** (`cli/lib/nftban/cli/cmd_support.sh`).

> **Current development status.** This page describes behavior merged to main for the
> upcoming **v1.229.12**, which **has not been published**. The latest published release is
> **v1.229.11**. Differences from v1.229.11 are identified explicitly below.

`nftban support` collects a diagnostic bundle from the host. This page is the operator
contract for what it produces, how to read it, and how to interpret evidence the
collector could not obtain.

The bundle is **read-only**. It never mutates the host it is diagnosing — a host in a
failed state is evidence, and collection must not destroy it.

## Invocation

```bash
nftban support                        # create the bundle  (works on every release)
nftban support --email admin@example.com   # create it AND email it
nftban support --email                # create it AND email the default recipient
nftban support --quick                # terminal diagnostics only, no file
nftban support --network              # additionally include ip addr / routes / ports

# current main / upcoming v1.229.12 ONLY — NOT yet published.
# On v1.229.11 this exits 1 and produces NO bundle.
nftban support --output DIR           # write it to DIR instead of /tmp
```

`nftban support-bundle` is an accepted alias for the same command.

- **Default output:** `/tmp/nftban-support-YYYYMMDD-HHMMSS.tar.gz`.
- **`--output DIR` writes the bundle to `DIR` — on main only.** On **v1.229.11, the current
  published release, this flag exits 1 and produces no bundle at all**
  (`SUPPORT_OUTPUT_DIR: readonly variable`). On that release use plain `nftban support` and
  move the tarball from `/tmp` afterwards.
- **`--email` is transport, not authority.** The bundle is generated first and written to
  disk regardless of whether mail delivery succeeds. A mail failure does not mean you have
  no bundle — look in the output directory.
- **`--network` is opt-in** because network topology may reveal infrastructure.

## Reading the bundle: the four truth rules

The bundle is designed so that *absence of evidence* can never be mistaken for
*evidence of absence*.

**Serialized evidence tokens.** These literal values are written by the collector and can
be searched for in a bundle:

```
UNKNOWN      != 0            a query that failed, never a count
UNAVAILABLE  != ABSENT       an input that could not be read
DANGLING     != COMPLETE     a start with no matching end
```

Each is attached to a record — `chains=UNKNOWN`, `UNAVAILABLE: <path> not readable`,
`rebuild_end=DANGLING` — so finding one in a bundle tells you something about that record.
`EMPTY` is **not** in this list: it appears only as a MANIFEST census heading, written on
every run whether or not anything is empty, so searching for it discriminates nothing. See
[Manifest and collection census](#manifest-and-collection-census-manifesttxt).

**Semantic rule, not a token.** A phase that was never entered must not be treated as a
failed phase. The collector does **not** emit a literal `NOT_STARTED` value — read the
phase and deadline evidence it does emit (below) and reason about it. Do not search a
bundle for a token that does not exist.

- **`UNKNOWN` is not zero.** When a query fails, the bundle records `UNKNOWN` and the
  error, never a count. `nft list table ip nftban 2>/dev/null | grep -c chain` returns `0`
  for both an empty table and a failed `nft`, so rendering a tool failure as `chains=0`
  would read as proof the firewall had been destroyed. The collectors refuse to do this.
- **`UNAVAILABLE` is not absent.** A section that could not read its input says so. An
  absent file, by contrast, is ambiguous — which is why the manifest exists (below).
- **An unentered phase is not a failed phase.** The installer tests deadline expiry when
  *entering* a phase, so a phase named in a timeout error may be the one that never began.
  There is no token for this — establish it from the phase markers and rebuild start/end
  pairs. See [Installer phase attribution](#installer-phase-attribution).
- **`DANGLING` is not complete.** A rebuild start with no matching end is reported as
  `rebuild_end=DANGLING exit=UNKNOWN`. It is never paired with a later run's end line,
  because that would fabricate a duration.

## Collection time is not incident time

Every evidence file carries a correlation header:

```
# collected_at=2026-08-31T05:30:47Z   (observation time, NOT incident time)
# host=... nftban_version=... install_state=... install_state_timestamp=...
# latest_run_id=...
#
# ⛔ CORRELATION: log-derived lines below carry their OWN timestamps. Where a
# section reports LIVE state it is labelled as observed at collected_at above.
# Do not read a log line and a live observation as the same moment.
```

A bundle mixes two kinds of evidence:

| Kind | Example | Bound to |
|---|---|---|
| **Live state** | current chains, sets, service status | `collected_at` |
| **Historical events** | installer phases, rebuild durations, parser rejections | the log's own timestamps |

Reading a rotated log next to a freshly observed live state as one coherent story is the
single easiest way to reach a wrong conclusion from a technically correct bundle. The
header exists to make that mistake visible rather than silent.

## Incident evidence (`incident/`)

Added in v1.229.12 after a production upgrade failure could not be diagnosed from a
bundle. Seven files:

| File | Answers |
|---|---|
| `incident/phase_timeline.txt` | Was this a real failure, or a false verdict from a deadline? Installer global budget, phase markers, and computed rebuild start/end/exit pairs. |
| `incident/chain_inventory.txt` | *Which* chains are present, by **identity** — not just a count. |
| `incident/parser_rejections.txt` | How many feed/list elements the parser rejected, and roughly what shape they were. Counted from `installer.log` only, split by a two-way heuristic (`dash_range` vs `other`), with at most five unique sample values. An unreadable log yields `total_rejections=UNKNOWN`, never `0`. |
| `incident/timeline_ruleset_lifecycle.txt` | render → apply → validation → rollback → final live state. |
| `incident/timeline_installer_run.txt` | phase → duration → exit → deadline/cancellation → terminal verdict. |
| `incident/nft_ruleset.json` | The full live ruleset as `nft -j list ruleset` — structured, parseable without scraping human text. |
| `incident/nft_sets.json` | The live sets as `nft -j list sets`, same structured form. |

The two timelines are kept **separate on purpose**. They can disagree, and *the
disagreement is the diagnosis*: a ruleset lifecycle that completed cleanly alongside a
terminal installer verdict reads as a false verdict, not as a broken firewall. Conflating
them is what makes an incident unreadable.

> A healthy final live state alongside a terminal installer verdict does **not** mean the
> host is unprotected. Compare the two timelines before concluding anything.

### Chain inventory: identity, not count

`chain_inventory.txt` lists chains per family. The base firewall contributes
`input`, `forward`, and `output` **per family**. That structural statement is the claim to
rely on; the resulting total of six follows from it and is not pinned by a regression test.
Everything beyond the base chains is contributed by protection modules during module
re-apply, which runs **outside** the atomic ruleset transaction.

This matters for reading a topology change:

- A count alone (`16 → 6`) cannot say *which* protections went away.
- The identities can: six survivors that are exactly the base chains means every module
  chain is absent — base-only.

**Six chains is the base topology, not renderer corruption.** Do not read it as the base
renderer having lost the module chains; module chains are added by the module re-apply
mechanism, which is a separate step with its own failure modes.

### Installer phase attribution

`phase_timeline.txt` and `timeline_installer_run.txt` both carry this warning
unconditionally:

> The installer tests context expiry when **entering** a phase. An error naming phase X
> can therefore mean "the deadline had already expired before X started", **not** "X
> overran". Cross-check the phase that was actually **running** using the rebuild
> start/end pairs before attributing blame.

The installer's global wall-clock budget is **300 seconds**
(`cmd/nftban-installer/main.go:51`). That constant is present in v1.229.11 as well —
but **v1.229.11 does not log it**, so on a currently released host the budget is real yet
unobservable and a bundle reports it as `UNKNOWN`. Emitting it as structured evidence
(`installer global budget=300s deadline=...`) is unreleased v1.229.12 behavior.

A firewall rebuild is exempt from that budget by policy. If the budget is exhausted and a
policy-exempt operation has **already returned successfully**, the run continues under one
**fresh bounded** budget, granted at most once per run. It is never "no deadline".

## Manifest and collection census (`MANIFEST.txt`)

`MANIFEST.txt` records what the bundle contains *and what it could not collect*:

- every file collected, with size;
- **`EMPTY`** — collected but produced no content;
- **`UNAVAILABLE / FAILED`** — sections that explicitly declared they could not collect.

Without this census an absent file is ambiguous between "not collected", "collected
empty", and "collection failed". The census resolves it: these are the sections that
*said so*.

## Redaction and handling

- Redaction removes **known secret patterns** (API keys, tokens, passwords) via the
  canonical redaction authority. Derived diagnostic evidence — log excerpts, timelines,
  phase markers — is scrubbed through the same authority as the source logs, because
  derived evidence carries the same confidentiality requirements as its source.
- Redaction is **fail-closed**. If the redactor is unavailable, the affected stream is
  discarded and a marker is emitted; raw content is never passed through
  (`_support_scrub_stream`, `cmd_support.sh`).
- **Review the bundle before sharing it outside your organization.** Diagnostic data may
  still contain identifying or environment-specific information, and no pattern-based
  redactor can guarantee that arbitrary sensitive material is absent. Prefer a private
  channel.
- Never paste credentials into an issue or a bundle. Nothing in NFTBan asks for them.

## Known limitations

- **A hung rebuild is not bounded.** `switchop.Rebuild` runs the rebuild subprocess on
  `context.Background()`, so the installer's deadline cannot terminate it, and no scriptlet
  or systemd unit wraps the installer. A rebuild that *never returns* hangs the installer
  indefinitely. Progress-aware supervision that could distinguish a **long** rebuild from a
  **hung** one is **not implemented**; it is tracked as a GA backlog item and asserted in
  executable form by `TestRebuildHangSupervisionIsMissing`
  (`cmd/nftban-installer/deadline_attribution_test.go`). The bundle can show you a rebuild
  that started and never ended (`DANGLING`); it cannot tell you whether that rebuild is
  still making progress.
- The bundle reports what the host recorded. If `installer.log` was rotated or is
  unreadable, the phase timeline says `UNAVAILABLE` rather than reconstructing events.

## References

- Collector: `cli/lib/nftban/cli/cmd_support.sh`
- Installer budget and phase attribution: `cmd/nftban-installer/main.go`
- Rebuild context policy: `internal/installer/switchop/rebuild.go`
- Related: [Emergency recovery and rollback](EMERGENCY_RECOVERY_AND_ROLLBACK.md),
  [Ban forensics](BAN_FORENSICS.md), [Production baseline](PRODUCTION_BASELINE.md)
