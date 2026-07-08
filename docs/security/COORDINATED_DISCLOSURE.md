<!-- SPDX-License-Identifier: MPL-2.0 -->
# Coordinated Vulnerability Disclosure

NFTBan follows a coordinated vulnerability disclosure (CVD) model. This document describes
how a report moves from intake to public advisory. The canonical policy is
[`SECURITY.md`](../../SECURITY.md); this file expands the process.

> **No external affiliation.** NFTBan is not affiliated with, certified by, endorsed by, or
> protected by Akrites or any other external security body. NFTBan maintains its own coordinated
> vulnerability disclosure process and is designed to be compatible with modern security-response
> practices such as confidential intake, coordinated disclosure, CVE, CVSS, CWE, TLP, and VEX.

## 1. Intake

- **Preferred:** GitHub private Security Advisory — *Security → Advisories → Report a vulnerability*.
- **Fallback:** email **security@itcms.gr** with a `[SECURITY]` subject prefix.
- **Do not** use public issues, discussions, or pull requests.
- **Encrypted contact:** a PGP key for encrypted email is **pending publication**; until then,
  prefer the private Security Advisory (encrypted in transit).
- **Confidentiality:** reports are handled **TLP:RED** by default (named recipients only) until a
  classification is agreed with the reporter.

## 2. Acknowledgement

- Acknowledgement within **48 hours**.
- Initial assessment within **7 days**.
- Status updates every **7–14 days** until resolution.

## 3. Triage & validation

- Reproduce and confirm the issue against a supported release.
- Classify by [vulnerability class](VULNERABILITY_CLASSES.md).
- Determine attacker-reachability and impact (is it a real vulnerability, or a hardening item?).

## 4. Severity scoring

- Score with CVSS v3.1 and map to a CWE per the [scoring rubric](CVE_CVSS_CWE_GUIDE.md).
- Decide whether a CVE is appropriate (see the rubric's "when a CVE is appropriate" section).

## 5. Fix development

- Develop and test the fix under embargo (see [Security Advisory Process](SECURITY_ADVISORY_PROCESS.md)).
- Backport to the "security-fixes-only" prior minor per the supported-versions policy in `SECURITY.md`.

## 6. Embargo

- Default **90-day** coordinated-disclosure window (see `SECURITY.md` timeline).
- Exceptions: actively-exploited issues may be disclosed sooner; complex issues may extend the
  window with reporter agreement.

## 7. Advisory publication & release

- Publish a GitHub Security Advisory and the fixed release **together** at the agreed time.
- Include affected/fixed versions, CVSS vector, CWE, and — for dependency issues — a
  [VEX](VEX_POLICY.md) statement.

## 8. Credit

- Reporters who follow this process are credited in the advisory and release notes (opt-out on request).

## 9. Researcher expectations

- Please do **not** publish exploit code, proof-of-concept, or reproduction details before a fix is
  released and the disclosure window has elapsed.
- Report in good faith; do not access, modify, or exfiltrate data beyond what is needed to
  demonstrate the issue.
