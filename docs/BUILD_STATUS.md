# NFTBan — Integrity & Build Status

> **Policy:** Main branch is always green. Failed CI blocks merge.
> No exceptions, no manual overrides for truth-critical checks.

**Current version:** see [`/VERSION`](../VERSION) — sourced per commit, not hardcoded here.
**Last audit:** see the [CHANGELOG](../CHANGELOG.md) and GitHub release notes for the current release.

---

## Build & Test

| Workflow | What it verifies | Frequency | Status |
|----------|-----------------|-----------|--------|
| [Go Build & Test](https://github.com/itcmsgr/nftban/actions/workflows/ci-go.yml) | Go compilation, unit tests (race detector), module completeness (G8-1/G8-2/G8-3), schema version lock | Every PR + push | [![Go](https://github.com/itcmsgr/nftban/actions/workflows/ci-go.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-go.yml) |
| [Bash Validation](https://github.com/itcmsgr/nftban/actions/workflows/ci-bash.yml) | Shell syntax, strict mode compliance, header spec | Every PR + push | [![Bash](https://github.com/itcmsgr/nftban/actions/workflows/ci-bash.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-bash.yml) |
| [ShellCheck](https://github.com/itcmsgr/nftban/actions/workflows/shellcheck.yml) | Static analysis of all shell scripts | Every PR + push | [![ShellCheck](https://github.com/itcmsgr/nftban/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/shellcheck.yml) |
| [Build Packages](https://github.com/itcmsgr/nftban/actions/workflows/build-packages.yml) | RPM (el9/el10) + DEB (debian12/13, ubuntu22/24) build + install test | Every PR + push | [![Build](https://github.com/itcmsgr/nftban/actions/workflows/build-packages.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/build-packages.yml) |
| [Docker](https://github.com/itcmsgr/nftban/actions/workflows/docker.yml) | Container image build | Every PR + push | [![Docker](https://github.com/itcmsgr/nftban/actions/workflows/docker.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/docker.yml) |
| [Smoke Test](https://github.com/itcmsgr/nftban/actions/workflows/ci-smoke.yml) | CLI command execution, runtime anomaly checks | Every PR + push | [![Smoke](https://github.com/itcmsgr/nftban/actions/workflows/ci-smoke.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-smoke.yml) |

## Architecture & Contract Enforcement

| Workflow | What it verifies | Frequency | Status |
|----------|-----------------|-----------|--------|
| [Architecture Policy](https://github.com/itcmsgr/nftban/actions/workflows/ci-architecture.yml) | FHS spec drift, schema codegen sync, vocabulary (G1-1), schema version (G2-3), module smoke (G8-4), legacy regression blockers (B86-1/M84-2 guards) | Every PR + push | [![Architecture](https://github.com/itcmsgr/nftban/actions/workflows/ci-architecture.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-architecture.yml) |
| [Documentation Validation](https://github.com/itcmsgr/nftban/actions/workflows/ci-docs.yml) | Markdown lint, link validation, doc completeness | Every PR + push | [![Docs](https://github.com/itcmsgr/nftban/actions/workflows/ci-docs.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-docs.yml) |
| [Project Health](https://github.com/itcmsgr/nftban/actions/workflows/project-health.yml) | Repository health metrics, stale issues, PR hygiene | Scheduled | [![Health](https://github.com/itcmsgr/nftban/actions/workflows/project-health.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/project-health.yml) |

## Security (SAST + SCA + Secrets)

| Workflow | What it verifies | Frequency | Status |
|----------|-----------------|-----------|--------|
| [CodeQL](https://github.com/itcmsgr/nftban/actions/workflows/codeql.yml) | Go semantic code analysis (GitHub Advanced Security) | Every PR + push | [![CodeQL](https://github.com/itcmsgr/nftban/actions/workflows/codeql.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/codeql.yml) |
| [Semgrep](https://github.com/itcmsgr/nftban/actions/workflows/semgrep.yml) | Pattern-based security rules (Go + Shell) | Every PR + push | [![Semgrep](https://github.com/itcmsgr/nftban/actions/workflows/semgrep.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/semgrep.yml) |
| [Secure Go](https://github.com/itcmsgr/nftban/actions/workflows/secure-go.yml) | gosec + staticcheck + govulncheck + Trivy | Every PR + push | [![SecureGo](https://github.com/itcmsgr/nftban/actions/workflows/secure-go.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/secure-go.yml) |
| [OSV-Scanner](https://github.com/itcmsgr/nftban/actions/workflows/osv-scanner.yml) | Google OSV vulnerability database scan | Every PR + weekly | [![OSV](https://github.com/itcmsgr/nftban/actions/workflows/osv-scanner.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/osv-scanner.yml) |
| [Gitleaks](https://github.com/itcmsgr/nftban/actions/workflows/gitleaks.yml) | Secret/credential detection in commits | Every PR + push | [![Gitleaks](https://github.com/itcmsgr/nftban/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/gitleaks.yml) |
| [Fuzz Tests](https://github.com/itcmsgr/nftban/actions/workflows/fuzz.yml) | Automated fuzz testing for parser robustness | Nightly | [![Fuzz](https://github.com/itcmsgr/nftban/actions/workflows/fuzz.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/fuzz.yml) |
| [Dependency Review](https://github.com/itcmsgr/nftban/actions/workflows/dependency-review.yml) | PR-level dependency diff analysis | Every PR | [![DepReview](https://github.com/itcmsgr/nftban/actions/workflows/dependency-review.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/dependency-review.yml) |
| [Socket Supply Chain](https://github.com/itcmsgr/nftban/actions/workflows/socket-supplychain.yml) | Typosquatting and malicious package detection | Every PR | [![Socket](https://github.com/itcmsgr/nftban/actions/workflows/socket-supplychain.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/socket-supplychain.yml) |

## Compliance & Supply Chain

| Workflow | What it verifies | Frequency | Status |
|----------|-----------------|-----------|--------|
| [OSSRA Remediation](https://github.com/itcmsgr/nftban/actions/workflows/ossra-remediation.yml) | License compliance (go-licenses), SPDX headers, dependency freshness (libyear), URL validation (Lychee) | Every PR + push | [![OSSRA](https://github.com/itcmsgr/nftban/actions/workflows/ossra-remediation.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ossra-remediation.yml) |
| [OpenSSF Scorecard](https://github.com/itcmsgr/nftban/actions/workflows/scorecard.yml) | OpenSSF security health score | Scheduled | [![Scorecard](https://github.com/itcmsgr/nftban/actions/workflows/scorecard.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/scorecard.yml) |
| [SLSA Go Releaser](https://github.com/itcmsgr/nftban/actions/workflows/slsa-go-releaser.yml) | SLSA Level 3 provenance attestation | On release | — |

---

## Contract Gates (v1.84+)

These are **blocking** — a PR cannot merge if any gate fails.

| Gate | What it enforces | Since | Workflow |
|------|-----------------|-------|----------|
| G1-1 | No banned terms in CLI output (vocabulary discipline) | v1.84 | ci-architecture.yml |
| G2-3 | Schema version: Go source = CLI expectation | v1.84 | ci-architecture.yml |
| G8-1 | Every CORE module in ModuleHealthMap + JSON | v1.85 | ci-go.yml (Go tests) |
| G8-2 | Every config directory has a classification | v1.85 | ci-go.yml (Go tests) |
| G8-3 | IPv6 parity: no IPv4-only evaluator checks | v1.85 | ci-go.yml (Go tests) |
| G8-4 | Cross-surface module consistency (validator = health) | v1.85 | ci-architecture.yml |
| B86-1 | No ModuleTruth reintroduction | v1.86 | ci-architecture.yml |
| M84-2 | No legacy fallback reintroduction | v1.86 | ci-architecture.yml |
| M87-1 | Evidence schema version lock (1.88.0) | v1.87 | ci-go.yml (Go tests) |
| M87-2 | Correlation enum restricted to allowed values | v1.87 | ci-go.yml (Go tests) |
| M87-3 | EvidenceSnapshot golden JSON must not drift | v1.87 | ci-go.yml (Go tests) |
| M88-1 | Journal evidence must not affect truth authority | v1.88 | ci-go.yml (Go tests) |

## Host Runtime Gate (pre-release)

| Test | What it verifies | File |
|------|-----------------|------|
| CLI runtime smoke | 27 CLI commands execute without bash errors | test_cli_runtime.sh |

This gate runs on deployed hosts before release tagging.
It catches runtime failures (bad array subscript, unbound variable, syntax error)
that cannot be detected in CI containers without nftables/systemd.

## Runtime Tests (host-deployed)

These require a deployed system and are not part of PR CI:

| Test | What it verifies | File |
|------|-----------------|------|
| G2-1 | Truth consistency: validator status = health status | test_truth_consistency.sh |
| G7-3 | Exit code contract: 0=PROTECTED, 1=DEGRADED, 2=DOWN | test_exit_code_consistency.sh |
| G8-4 | Module list: validator JSON = health JSON | test_module_selftest.sh |

---

## Known Issues

| Issue | Severity | Status |
|-------|----------|--------|
| gosec SARIF alerts on installer G104 | LOW | Dismissed as false positive (pre-existing, not PR-related) |

---

## Health Policy

- **Main is always green.** Failed CI blocks merge.
- **No manual overrides** for truth-critical checks (G1-1, G2-3, G8-*).
- **Failing badge = working system.** It proves CI is active and catching issues.
- **Every release is CI-gated.** No tag without green pipeline.
- **Evidence over claims.** Click any badge to see full run logs.

---

## How to Verify

```bash
# On any deployed host:
nftban-validate --json | jq '.status'          # Kernel truth
nftban health --json | jq '.status'            # CLI agrees
nftban metrics evidence                         # Evidence snapshot
nftban metrics evidence-json | jq '.correlation' # Correlation diagnostic
```

All outputs are verifiable against the [contract rules](docs/CONTRACT_RULES.md).
