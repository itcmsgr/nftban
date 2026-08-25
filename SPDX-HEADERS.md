# SPDX Headers

Every source file in NFTBan carries a license identifier so the project's
licensing is machine-readable and unambiguous.

## Required identifier

NFTBan Core is licensed under the **Mozilla Public License 2.0**. Source files
must contain exactly one SPDX identifier:

```
SPDX-License-Identifier: MPL-2.0
```

- Shell (`*.sh`), config (`*.conf`/`*.rules`), and systemd unit files use a
  `#`-comment form.
- Go (`*.go`) files use a `//`-comment form.

## Enforcement

This requirement is enforced by `tools/validate-headers.sh`, which runs in the
**pre-commit hook** (`.pre-commit-config.yaml`, `.githooks/pre-commit`). It is
**not** wired into a CI workflow; the licence gates that do run in CI are
`scripts/ci/check-license-identity.sh` and
`scripts/ci/check-core-ownership-identity.sh` (both blocking in
`ci-architecture.yml`), plus `.github/workflows/ci-reuse.yml` for REUSE
compliance.

Two corrections to what this document previously claimed, both found in
v1.229.11 Lane 8. It said the script was wired into CI — it never was. And it
said the script "rejects any tracked ... file", which was false in a more
serious way: its subject set came from `git diff --cached`, so with nothing
staged it validated **zero** files and exited 0. That is now fixed — it falls
back to the full tracked tree, uncapped — but the claim below describes the
corrected behaviour, not the behaviour of any released version before it.

It rejects any tracked shell/Go/config file that is missing the SPDX line,
carries a non-`MPL-2.0` identifier, has more than one SPDX line, or lacks the
canonical copyright attribution line, and it also requires the `meta:` and
`meta:inventory.*` header keys described in `CONTRIBUTING.md` (section
"File Headers").

## Package metadata

Package-level license declarations are asserted separately by
`scripts/ci/check-license-metadata.sh`, which verifies the RPM spec and the
high-level public legal surfaces declare `MPL-2.0` (never GPL/LGPL/AGPL).

---

Copyright (c) 2024-2026 Antonios Voulvoulis
