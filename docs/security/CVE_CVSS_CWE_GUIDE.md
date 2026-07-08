<!-- SPDX-License-Identifier: MPL-2.0 -->
# CVE / CVSS / CWE Scoring Guide

A consistent rubric for scoring NFTBan vulnerabilities. Used during triage
(see [Coordinated Disclosure](COORDINATED_DISCLOSURE.md)) and advisory drafting
(see [Security Advisory Process](SECURITY_ADVISORY_PROCESS.md)). Classes are defined in
[VULNERABILITY_CLASSES.md](VULNERABILITY_CLASSES.md).

## Method

1. Identify the vulnerability class and CWE(s).
2. Build a **CVSS v3.1** vector; record vector string + base score in the advisory.
3. Decide CVE-worthiness (below).

## Per-class scoring guidance (illustrative — score each report on its own facts)

| Class | Typical direction | Example CVSS vector (illustrative) | CWE |
|---|---|---|---|
| Firewall bypass | High | `AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:N` | CWE-693 / CWE-284 |
| False mass-ban / lockout | Med–High (availability) | `AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:H` | CWE-670 / CWE-754 |
| Update-chain compromise | Critical | `AV:N/AC:L/PR:N/UI:R/S:C/C:H/I:H/A:H` | CWE-494 / CWE-347 |
| Privilege-boundary failure | High–Critical | `AV:L/AC:L/PR:L/UI:N/S:C/C:H/I:H/A:H` | CWE-269 / CWE-862 |
| Log-parser injection | Depends on reachability/context | score per reachability + privilege | CWE-20 / CWE-74 |

> The vectors above are **templates**, not verdicts. Metrics (especially `PR`, `S`, `AV`) must
> reflect the actual attack path in the reported case.

## When a CVE is appropriate

- A defect exploitable by someone **other than a local root administrator** that:
  - defeats or bypasses protection (firewall bypass, false allow), or
  - escalates privilege / crosses a trust boundary, or
  - compromises the update/package trust chain, or
  - discloses secrets/PII,
  in a **released** version.

## When it is hardening, not a CVE

- Defense-in-depth improvements with no attacker-reachable impact.
- False-green/false-red health that misrepresents state but does not admit an attacker.
- Documentation, telemetry, or cosmetic issues.
- Local-root-only "self-inflicted" behaviors (root can already change the firewall).

Track hardening items in the normal backlog, not as CVEs.

## Recording

Each advisory records: class, CWE(s), CVSS vector + base score, CVE status
(requested / assigned / not applicable), affected + fixed versions, and — for dependency issues —
a [VEX](VEX_POLICY.md) status.
