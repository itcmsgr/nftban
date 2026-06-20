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

This requirement is enforced automatically by `tools/validate-headers.sh`
(wired into the pre-commit hook and CI). It rejects any tracked shell/Go/config
file that is missing the SPDX line, carries a non-`MPL-2.0` identifier, or has
more than one SPDX line, and it also requires the `meta:` and
`meta:inventory.*` header keys described in `CONTRIBUTING.md` (section
"File Headers").

## Package metadata

Package-level license declarations are asserted separately by
`scripts/ci/check-license-metadata.sh`, which verifies the RPM spec and the
high-level public legal surfaces declare `MPL-2.0` (never GPL/LGPL/AGPL).

---

Copyright © 2024-2026 NFTBan Project / Antonios Voulvoulis.
