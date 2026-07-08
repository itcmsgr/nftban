<!-- SPDX-License-Identifier: MPL-2.0 -->
# Security Advisory Process

How NFTBan produces and publishes a security advisory once a vulnerability is validated.
See [Coordinated Disclosure](COORDINATED_DISCLOSURE.md) for the end-to-end timeline and
[`SECURITY.md`](../../SECURITY.md) for the canonical policy.

## 1. Draft the advisory (private)

- Open/continue a **GitHub Security Advisory (GHSA)** draft in the repository.
- Keep it private (TLP:RED) until coordinated release.

## 2. CVE request (if applicable)

- NFTBan is **not** a CVE Numbering Authority (CNA). When a CVE is warranted (see the
  [scoring rubric](CVE_CVSS_CWE_GUIDE.md)), request an identifier via GitHub's advisory
  CVE-request flow or MITRE.
- Track "CVE: requested / assigned / not applicable" in the advisory.

## 3. CVSS + CWE assignment

- Assign a CVSS v3.1 vector and score.
- Map to one or more CWEs using the [scoring rubric](CVE_CVSS_CWE_GUIDE.md) and the
  [vulnerability classes](VULNERABILITY_CLASSES.md).

## 4. VEX decision (dependency-related issues)

- If the issue is (or involves) a dependency CVE, produce a [VEX](VEX_POLICY.md) statement
  (`affected` / `not_affected` / `fixed` / `under_investigation`).
- A `not_affected` claim requires maintainer review before publication.

## 5. Fix, validate, build

- Merge the fix; run full CI plus the relevant install/runtime-truth/canonization gates and a
  regression test for the vulnerability class.
- Build packages via the normal release pipeline (see the embargoed-release lane in
  `RELEASE-CHECKLIST.md`).

## 6. Release note & advisory publication

- Publish the fixed release and the GHSA **together** at the coordinated time.
- Release notes reference the advisory and the fixed versions.

## 7. Downstream / operator notice

- Disclosure is delivered via the **GitHub Security Advisory** and **release notes**.
- A dedicated security-announcement mailing list is **planned, not yet available** — do not
  promise it until it exists.

## 8. Public disclosure timing

- Follow the coordinated-disclosure window in `SECURITY.md` (default 90 days), unless an
  exception applies.

## 9. Closure / postmortem

- Record root cause, the vulnerability class, the fix, and any process/test improvements as a
  short internal postmortem; add a regression guard where practical.
