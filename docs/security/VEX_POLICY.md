<!-- SPDX-License-Identifier: MPL-2.0 -->
# VEX Policy

**Policy only — this document does not implement VEX generation.**

VEX (Vulnerability Exploitability eXchange) lets NFTBan state whether a vulnerability reported
against one of its dependencies is actually exploitable **in NFTBan's usage**. This reduces
false-positive noise for downstream operators scanning the SBOM.

## When NFTBan will publish VEX

- When a dependency CVE is surfaced by OSV / Dependency Review against a shipped release, and
  the exploitability in NFTBan's context is materially different from the raw CVE.

## Relationship to SBOM / OSV / Dependency Review

- **SBOM** (`sbom.spdx.json`, per release) — what is shipped.
- **OSV / Dependency Review** — which dependency CVEs are flagged.
- **VEX** — whether a flagged CVE is actually exploitable in NFTBan → `affected`,
  `not_affected`, `fixed`, or `under_investigation`.

## Status semantics

| Status | Meaning |
|---|---|
| `affected` | Exploitable in NFTBan; a fix/mitigation is needed or in progress |
| `not_affected` | Present in the dependency but not reachable/exploitable in NFTBan (with justification) |
| `fixed` | Addressed in a released version |
| `under_investigation` | Assessment in progress |

## Owner review gate

A **`not_affected`** statement is an exploitability claim. It **must** be reviewed and approved
by the maintainer before publication — it is not auto-generated and not delegated. Every
`not_affected` entry must include a justification (e.g. "code path not compiled", "function not
called", "requires a configuration NFTBan never uses").

## Non-goals (for now)

- No automated VEX generation pipeline in this lane.
- No VEX published without maintainer review.
