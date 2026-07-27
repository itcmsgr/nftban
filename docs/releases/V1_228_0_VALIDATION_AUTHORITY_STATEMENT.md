# v1.228.0 — Validation Authority Statement

Permanent release interpretation. Authority for the principle:
[`../RUNTIME_MODE_AUTHORITY_CONTRACT.md`](../RUNTIME_MODE_AUTHORITY_CONTRACT.md) and
[`../adr/ADR-0001-runtime-mode-authority.md`](../adr/ADR-0001-runtime-mode-authority.md).

## Statement

> v1.228.0 introduced stronger package, runtime, enforcement and lifecycle gates. Those gates
> uncovered several small but material gaps in behaviour that had previously been assumed complete
> because the corresponding code or configuration existed. The release corrected the confirmed
> **package-boundary** defects, converted major validation paths into durable tests, and materially
> increased confidence in the parts of NFTBan that are now proven end to end. Confirmed
> **runtime-mode** defects are recorded explicitly and are **not** corrected in this release.
> Remaining unverified paths are recorded explicitly and are not represented as complete.

## What this release did and did not reveal

It did **not** reveal that NFTBan had no implementation. It revealed something more specific:

> Several features, modes, lifecycle paths and status claims existed in code, but some were
> incomplete, unreachable, insufficiently verified, or not proven end to end.

## The gates that exposed them

package lifecycle gates · runtime mode authority checks · real DEB/RPM package validation ·
cross-VM attack tests · hooked-chain enforcement checks · negative controls · mutation fixtures ·
read-only verification proofs · configured-vs-effective mode tracing

## Findings, split by disposition

**CORRECTED in v1.228.0 — package boundary**

- missing package outcome truth (a package manager reporting success over a failed install)
- stale historical state confused with the current transaction
- silent no-installer path emitting no machine-readable result
- RPM build failure hidden behind a successful wrapper result (**no package produced at all**)
- timestamp precision defect producing a false `STALE_STATE` on a healthy install
- a dead, contradictory verdict-to-exit authority

**CONFIRMED AND RECORDED — not corrected in this release** (runtime lane, `PLAN_AFTER_PROOF`)

- mode names without proven runtime reachability (`DDOS_MODE=suricata` — processor has no caller)
- Suricata readiness based on presence rather than producing input (LoginMon `auto`)
- health reporting `RUNNING` while the active watcher had exited
- `STATE_READ_ERROR` has no producer; read errors report as `MISSING_STATE`
- silent no-op mode dispatch (`type -t fn && fn` returning success when the entrypoint is absent)

**METHOD DEFECTS — corrected in the harnesses themselves**

- harnesses that could report `PASS` without proving the intended injection
- missing lifecycle and attack-path coverage

## Scope of confidence

```
PROVEN AREAS              stronger confidence
UNPROVEN / INCOMPLETE     remain explicitly open
NO GREEN LABEL            may hide a skipped, unreachable or unverified path
```

Confidence is scoped to what was proven, and proof means the full production path — not that the
code exists. Areas absent from a ledger or matrix are **unassessed**, not healthy.

## Standing lesson

> A feature is not merely code that exists. A feature is a complete production path that is
> **reachable, observable, enforceable, testable and recoverable.**

```
DEFINED         ≠  REACHABLE
CONFIGURED      ≠  EFFECTIVE
ENABLED         ≠  DETECTING
RUNNING         ≠  RECEIVING INPUT
DETECTED        ≠  ENFORCED
SET MEMBERSHIP  ≠  FIREWALL BLOCK
PASS            ≠  INJECTION PROVEN
```
