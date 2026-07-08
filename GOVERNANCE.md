<!-- SPDX-License-Identifier: MPL-2.0 -->
# Governance

## Model

NFTBan is **founder-led**. The primary maintainer and security-response owner is
**@itcmsgr** (Antonios Voulvoulis); see [`MAINTAINERS`](MAINTAINERS) and
[`.github/CODEOWNERS`](.github/CODEOWNERS).

Decisions on architecture, security policy, coordinated disclosure, and releases rest with the
maintainer until a broader governance model is published.

## Bus factor

The project is currently **single-maintainer (bus-factor 1)**. A named **backup maintainer /
security-response backup is a known gap (TODO)**. We state this openly rather than imply a team
that does not exist.

## Security-response ownership

- Vulnerability intake, triage, and coordinated disclosure are owned by the maintainer
  (see [`SECURITY.md`](SECURITY.md) and [`docs/security/`](docs/security/)).
- Confidential reports: GitHub private Security Advisory (preferred) or **security@itcms.gr**.

## Decision-making

- Routine changes: maintainer review + CI gates.
- Security policy / disclosure / release decisions: maintainer, following the documented
  [coordinated-disclosure process](docs/security/COORDINATED_DISCLOSURE.md).

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Contributions are welcome; the maintainer makes final
merge and release decisions.

## Changes to governance

This document will be updated if/when backup maintainers are added or the governance model
changes. It does not claim any external affiliation, membership, or certification.
