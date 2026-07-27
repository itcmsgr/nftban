# ADR-0001 — Runtime Mode Authority

- **Status:** Accepted
- **Date:** 2026-07-26
- **Scope:** every module exposing a mode (DDoS, PortScan, LoginMon, and any future module)

## Context

NFTBan modules expose four user-facing mode values — `auto`, `classic`, `suricata`, `hybrid`.
Investigation of v1.228.0 established that a configured mode name does not imply a reachable,
observable or enforceable runtime path. Three findings, each by direct source trace:

1. `DDOS_MODE=suricata` names a mode whose EVE processor has **zero external callers**, and DDoS
   has no mode dispatcher at all. The mode resolves to nothing while status renders its name.
2. LoginMon `auto` selects Suricata from **presence** (binary + active service, EVE not required),
   then starts only the EVE watcher — silently darkening journal-based SSH, su, sudo, mail and FTP
   detection.
3. When the EVE source is absent, that watcher goroutine exits immediately while module status
   remains `RUNNING`.

These are not tuning problems and would not have been found by threshold work. They share one
shape: **a name in configuration that does not correspond to a proven production path.**

A further hazard is structural: the PortScan dispatcher guards each branch with
`type -t fn && fn`, so a missing mode function is indistinguishable from a successful run.

## Decision

**A feature is a complete production path that is REACHABLE, OBSERVABLE, ENFORCEABLE, TESTABLE and
RECOVERABLE — not merely code that exists.** This governs DDoS, PortScan, LoginMon, Suricata,
BotScan, ban/unban, package lifecycle, health, reporting, and every future module.

**NFTBan treats each module mode as an independently admitted runtime implementation.**

A configured mode is not supported until its production path, source readiness, health semantics,
enforcement, recovery and cross-VM behaviour are proven. Admission is tracked per module × mode in
a ledger, and promotion requires static reachability, committed positive and negative fixtures,
real cross-VM traffic, enforcement proof and clean recovery — entered through the shipped
production lifecycle, never a private helper.

The governing invariant:

```
NO CONFIGURED MODE MAY BE REPORTED ACTIVE
UNLESS ITS EFFECTIVE RUNTIME CHAIN IS PROVEN END TO END
```

## Consequences

- The four mode values are tested **independently**; they are never collapsed into
  "with Suricata / without Suricata".
- `auto` must record `CONFIGURED_MODE`, `EFFECTIVE_MODE` and `MODE_REASON` separately. Operator
  intent is never overwritten by the resolved value without preserving both.
- Suricata readiness requires the source to be **producing input**, not merely present.
- Hybrid requires a deduplication authority before it may be called supported.
- Silent fallback and silent no-op are prohibited: a selected mode with a missing entrypoint is
  `FAILED` or `DEGRADED` with a machine-readable reason, never rc0.
- **A broken mode must be rejected at configuration validation or explicitly marked unavailable.
  It must not be selectable as an operational mode. Hiding it from help alone is insufficient** —
  an existing configuration file would otherwise keep selecting it silently.
- **The mode declaration and admission ledger are specification and admission authorities, not
  runtime truth.** Runtime enforcement authority remains the nftables kernel; health interpretation
  remains the validator; configuration records operator intent. The ledger never replaces
  kernel/validator truth.
- Health must test the path the effective mode selected, and must be able to report failure —
  distinguishing `ACTIVE_ZERO_INPUT` from `ACTIVE_AND_RECEIVING`.
- Threshold retuning is blocked until reachability and ownership are proven, and may not reuse one
  numeric threshold across modes with different observation models.

## Alternatives considered

**Fix the specific bugs and move on.** Rejected: the same class had already recurred across
independent modules, and the finding would have disappeared with the release. The defect is
architectural — a missing admission boundary — not three unrelated bugs.

**Keep the contract only in agent/assistant memory.** Rejected by the owner. Institutional
knowledge must live in the repository where contributors, auditors and CI can enforce it.

## Revisit criteria

This ADR may be superseded only if NFTBan adopts a different runtime-mode architecture that
preserves equivalent or stronger guarantees for:

- configured versus effective mode separation
- source readiness
- production-path reachability
- enforcement authority
- health truth
- negative and cross-VM validation
- recovery and deduplication

A refactor that removes the admission model without providing equivalent guarantees does not
supersede this ADR; it violates it.

## Compliance

- Contract: [`../RUNTIME_MODE_AUTHORITY_CONTRACT.md`](../RUNTIME_MODE_AUTHORITY_CONTRACT.md)
- Ledger: [`../MODE_ADMISSION_LEDGER.md`](../MODE_ADMISSION_LEDGER.md)
- PR gate: the mode-authority section of `.github/PULL_REQUEST_TEMPLATE.md` — an unanswered field
  blocks merge.
