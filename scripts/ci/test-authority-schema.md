# Shell-Test Authority Schema (`meta:ta.*`)

**Status:** v1.226.0 PR-A substrate (transition phase). Non-activating: the strict
blocking gate is **not** switched on in PR-A. This document defines the metadata
contract that later phases build on.

## What this is

The single source of truth for how a shell test in `cli/lib/nftban/tests/*_test.sh`
is governed — who owns it, where it runs, and which CI/lab gate is responsible for
executing it — lives **in each test file** as a block of `# meta:ta.*` comment
headers.

- **CANONICAL authority:** the `meta:ta.*` headers in the test files.
- **DERIVED, non-authoritative:** `scripts/ci/test-authority-index.tsv` is a
  reproducible projection of those headers. It carries a
  `# GENERATED FILE — DO NOT EDIT` banner and is verified fresh in CI. Never hand-edit it.
  It lives under `scripts/ci/` (a CI/repo artifact) and is deliberately **not** inside
  `cli/lib/nftban/tests/`, because the packaging build sweeps that directory into the
  shipped payload (`/usr/lib/nftban/tests/`) — the index must never enter an end-user package.

The tool `scripts/ci/test-authority.py` parses the headers, validates them, and
regenerates the index. It reads only the leading comment region of each file as
inert text — it never sources or executes a test (no `eval`, no shell expansion).

## Why a separate `ta.` namespace

The pre-existing `meta:owner` header is a **person** (`Name <email>`) required by the
repo header hook, and `meta:type="test"` is a placeholder. To avoid colliding with
either, all governance fields use the `ta.` (test-authority) namespace. `meta:owner`
and `meta:type` are left untouched.

## Fields

All values are double-quoted: `# meta:ta.<field>="<value>"`.

| Field | Required (migrated) | Values |
|-------|--------------------|--------|
| `ta.id` | yes | `^[a-z0-9][a-z0-9._-]*$`; unique across all tests. Transitional (un-migrated) tests derive an id from the filename stem. |
| `ta.owner` | yes | one of the controlled owner vocabulary (subsystem, e.g. `update`, `mail`, `packaging`, `cli`, `rbl`, …). |
| `ta.module` | yes | subsystem/module label; non-blank (`cross-cutting` allowed). |
| `ta.execution_class` | yes | `CI_STATIC`, `CI_HERMETIC_SHELL`, `PACKAGE_BUILD`, `PACKAGE_NATIVE_DEB`, `PACKAGE_NATIVE_RPM`, `ROOT_LAB`, `NETWORK_LAB`, `LIVE_CANARY`, `FLEET_RECONCILIATION`, `MANUAL_FORENSIC`, `HISTORICAL_ONLY`. |
| `ta.gate` | yes | `policy-gates`, `ci-bash`, `package-build`, `package-native-deb`, `package-native-rpm`, `lab-manual`, `canary`, `fleet`, `manual-forensic`, `excluded`, `deferred`, `unassigned`. |
| `ta.hermetic` | yes | `true` / `false`. |
| `ta.requires_root` | yes | `true` / `false`. |
| `ta.requires_network` | yes | `true` / `false`. |
| `ta.requires_systemd` | yes | `true` / `false`. |
| `ta.requires_nftables` | yes | `true` / `false`. |
| `ta.requires_package` | yes | `true` / `false`. |
| `ta.timeout` | optional | free text (e.g. `60s`); projected to the index as-is. |
| `ta.exclusion_reason` | conditional | required and meaningful when `gate=excluded`, `gate=deferred`, or `execution_class=HISTORICAL_ONLY`; must be absent/empty when `gate=unassigned`. Placeholders (`TODO`, `TBD`, `none`, `n/a`, `-`) are rejected. |
| `ta.activation_condition` | conditional | required and meaningful when `gate=deferred` (what re-enables the test); must be absent/empty for any other gate. |

### The `deferred` gate (v1.226.0 PR-B)

`deferred` represents a test that is **correctly classified for future execution** but
is **withheld from a live gate right now** — the canonical case is a test whose true
nature is hermetic CI but which currently *fails* on a known, separately-tracked defect
(e.g. a stale fixture), so it must not block CI until the defect is repaired in a later
PR. It is distinct from `excluded` (intentionally never executed) and must never be
represented with `unassigned`. The validator enforces all three of: an accountable
`ta.owner` (always required for a migrated test), a meaningful `ta.exclusion_reason`
(why it is withheld), and a concrete `ta.activation_condition` (what re-enables it). A
`deferred` test still declares its real `execution_class` (which must not be
`HISTORICAL_ONLY`).

## Cross-field rules (consistency, not guesswork)

The validator refuses metadata that contradicts itself:

- `execution_class=CI_HERMETIC_SHELL` ⇒ every `requires_*` must be `false` and `hermetic=true`.
- `gate=policy-gates` ⇒ `hermetic=true`, and neither root nor network required.
- `execution_class=PACKAGE_NATIVE_DEB|PACKAGE_NATIVE_RPM` ⇒ `requires_package=true`.
- `execution_class=ROOT_LAB` ⇒ `requires_root=true`; `NETWORK_LAB` ⇒ `requires_network=true`.
- `execution_class=HISTORICAL_ONLY` ⇒ `gate=excluded`.

## Modes

- `validate --mode transition` *(default; what PR-A wires into CI)* — fails only on
  malformed metadata, duplicate id/path, or invalid values on **already-migrated**
  files. Un-migrated legacy tests are permitted. This lets the corpus migrate
  incrementally without a flag-day.
- `validate --mode strict` — additionally fails on any missing required `ta.*`
  field. Reserved for a later phase (PR-D) once the corpus is fully classified.

## Commands

```
scripts/ci/test-authority.py validate [--mode transition|strict]
scripts/ci/test-authority.py generate      # rewrite the derived index
scripts/ci/test-authority.py check         # fail if the tracked index is stale
scripts/ci/test-authority.py summary       # counts by class / owner / gate
```

Exit codes: `0` ok · `1` validation/staleness failure · `2` tool/config failure.

## CI

`ci-architecture.yml` runs, in the Policy Gates job:

1. `test-authority-selftest.py` — the tool's own self-tests (fixtures + exit codes).
2. `test-authority.py validate --mode transition` — schema check.
3. `test-authority.py check` — index freshness.

All three are **blocking**. Adding or changing a test's `ta.*` headers without
regenerating the index fails the freshness check.

## Self-tests

`scripts/ci/test-authority-selftest.py` builds throwaway git repos with fixture
tests (valid and deliberately-invalid) and drives the real CLI end-to-end,
asserting exit codes and messages. It depends on nothing in the live corpus.
