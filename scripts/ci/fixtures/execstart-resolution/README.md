# V108 Item 1 — Test Fixtures

Test inputs for `scripts/ci/test-systemd-execstart-payload-resolution.sh`.

## Layout

Each fixture is a pair of directory trees mimicking extracted RPM and DEB package payloads. The script is invoked as:

```
bash scripts/ci/test-systemd-execstart-payload-resolution.sh validate \
  --rpm-payload=<fixture>/rpm \
  --deb-payload=<fixture>/deb \
  --deprecated-yaml=<fixture>/deprecated-units.yaml \
  --system-binary-allowlist=<fixture>/system-binaries.txt
```

Each fixture directory contains:

```
<fixture-name>/
├── rpm/                       # Extracted "RPM" payload root
│   └── usr/
│       ├── lib/
│       │   └── systemd/
│       │       └── system/    # Active unit files
│       │           └── <unit>.service
│       └── …                  # Other artifacts referenced by Exec*
├── deb/                       # Extracted "DEB" payload root
│   └── usr/
│       └── …                  # Mirror of RPM layout
├── deprecated-units.yaml      # Test-scoped deprecated unit list
├── system-binaries.txt        # Test-scoped allowlist
├── expected.exit              # Expected exit code (0 or 1)
└── expected.report            # Substring(s) that MUST appear in the output
```

## Fixtures

| Fixture | Failure mode probed | Expected exit |
|---|---|---|
| `pass-clean/` | None — minimal clean payload | 0 |
| `fail-invalid-missing-path/` | `INVALID_MISSING_PATH` (active unit references shipped path absent from BOTH RPM and DEB payloads) | 1 |
| `fail-deprecated-residue/` | `STALE_RESIDUE_INCOHERENT_STATE` (active install includes a unit named in deprecated-units.yaml) | 1 |
| `fail-parity-unit/` | `PARITY_UNIT_PRESENT_IN_ONE_PACKAGER` (unit in RPM but not DEB) | 1 |
| `fail-parity-exec/` | `PARITY_EXEC_PATH_RESOLUTION_DIVERGENT` (Exec path resolves in RPM but not DEB) | 1 |

## Running fixtures locally

```bash
# Single fixture
cd "$(git rev-parse --show-toplevel)"
bash scripts/ci/test-systemd-execstart-payload-resolution.sh validate \
  --rpm-payload=scripts/ci/fixtures/execstart-resolution/pass-clean/rpm \
  --deb-payload=scripts/ci/fixtures/execstart-resolution/pass-clean/deb \
  --deprecated-yaml=scripts/ci/fixtures/execstart-resolution/pass-clean/deprecated-units.yaml \
  --system-binary-allowlist=scripts/ci/fixtures/execstart-resolution/pass-clean/system-binaries.txt \
  --verbose
echo "Exit: $?"
```

A simple matrix runner script could iterate the fixtures directory and compare actual exit codes against `expected.exit` for each.

## Notes

- Fixtures use plain placeholder content for binaries (e.g., empty files at the
  expected paths) — the gate only cares about path existence, not content.
- Fixtures intentionally mirror nftban's real unit-file conventions
  (`ExecStart=/usr/lib/nftban/…`) so the matchers exercise the same parsing
  paths that production input does.
