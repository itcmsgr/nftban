# NFTBan — Integrity & Build Status

> **Policy:** Main branch is always green. Failed CI blocks merge.
> No manual overrides for truth-critical checks. Evidence over claims.

**Version (this commit):** v1.107.1 — sourced from [`/VERSION`](VERSION); static per commit, not auto-updated. For the current released tag see [GitHub releases](https://github.com/itcmsgr/nftban/releases) or the README badge.
**Release lane:** v1.107.1 (2026-05-10) — packaging hotfix on top of v1.107.0. Closes a packaging-vs-source-install asymmetry surfaced by lab4 takeover (Issue #525 follow-on rollout): `nftban-firewall-init.service` references `/usr/lib/nftban/helpers/firewall-init-with-delay.sh` but RPM/DEB packagers did not ship the helper, leaving `INSTALL_STATE=DEGRADED` after every successful takeover. Fix is two `install` lines in `packaging/build_nftban.sh` (RPM `%install` + DEB `build_deb()`), staging the helper from `install/helpers/` (the same source location that `internal/installer/payload/payload.go:411` uses for the source-install path under PR26.5). Helper source unchanged. Unit file unchanged. Validator assertion unchanged. Schema frozen at `1.83.0`. No metrics, portal, install API, or panel-adapter changes. Behavior change limited to: `nftban-firewall-init.service` `ExecStart=` target now resolves on package install; `systemd_execstart_paths_ok` validator assertion now passes; takeover terminal state advances from `DEGRADED` to `OK`/`HEALTHY`. Carries forward all v1.107.0 non-goals (row 17 SELF-HEALING-AUTHORITY-REDESIGN, FHS Authority Graph / ATG, optional GHCR retention).
**Prior release lane:** v1.107.0 (2026-05-10) — post-MFST closure release on top of v1.106.0. Five code PRs and one accepted-retention closure land the v1.107 worklog targets. **PR #576 (squash `15bb9f44`)** — Slot 5a PKG-EFFECTIVE-PARITY: DEB postinst ownership convergence (Option α + Option A `dpkg-statoverride`) + new CI parity gate covering all six layers (yaml SoT → generator → archive metadata → installed-fs → reinstall preservation → verify tool). **PR #579 (squash `0daeb38e`)** — Slot 5b G8-AUDITOR-DIR-UBUNTU: Runtime Truth G8 verifier sudo-wrapped so the runner-user can traverse `0750 root:nftban` parents on Ubuntu 24.04; CI test-harness fix only (Bucket F), no product change. The SYSUSERS-GECOS-G-LINES dormant defect surfaced as a side-effect of this gate's reverted Stage-2 attempt and was closed separately by PR #582. **PR #580 (squash `1d2c4b63`)** — Slot 6 POLKIT-AUTHORITY: documentation-only amendment. Two `note:` fields added to `build/fhs-spec.yaml` (D-NEW-11 keep-decision + auditor-dir AUTHORITY EXCEPTION); header `// CONSUMERS` block added to `30-nftban-panel.rules` with 9-surface live-consumer manifest + decommission-rejected rationale. `polkit.addRule(...)` body BYTE-IDENTICAL to base. The three-tier polkit model (operator/auditor/panel) is confirmed load-bearing. **PR #581 (squash `1d83df9e`)** — Slot 7 LANE-G / Issue #525: `nftban-core-geoip.service` `TasksMax=10`→`64` (mirrored on `nftban-health.service`) closes a Go 1.25 runtime fatal-trace class triggered by `clone(2) EAGAIN` under cgroup pids exhaustion. New Runtime Truth G9 step asserts no Go runtime fatal trace appears at geoip startup on both ubuntu-24.04 (real-systemd path A) and almalinux-9 (prlimit path B) matrix legs. Issue #525 left OPEN by the merge gate (operational hygiene; operator may close separately). **PR #582 (squash `3af86877`)** — proposed worklog row 16 SYSUSERS-GECOS-G-LINES one-shot: generator emitter `g \(.name) - "\(.comment)"` → `g \(.name) -` (per `sysusers.d(5)`, g-lines do not take a GECOS field); regenerated `install/systemd/sysusers.d/nftban.conf`; new Runtime Truth G10 step asserts `systemd-sysusers --dry-run` exits 0 on systemd 252 + 255 matrix legs. Identities byte-equivalent. **Row 13 / F-6 REGISTRY-HYGIENE** closed via accepted-retention path (b): `ghcr.io/itcmsgr/nftban:sha-4de527d` re-classified as normal `docker/metadata-action@v5.9.0` `type=sha` output (one of 284 `sha-*` tags), not stale; zero registry mutation, zero code change, zero PR. **No runtime behavior change in `nftban-core` / `nftband` daemons; behavior changes confined to (a) raised cgroup `TasksMax` on `nftban-core-geoip.service` + `nftban-health.service` and (b) corrected `sysusers.d` g-line syntax (dormant in production; postinst uses `groupadd -r` directly, never `systemd-sysusers`).** Schema frozen at `1.83.0`. No metrics, portal, install API, or panel-adapter changes. **Explicit non-goals carried forward to v1.108+ as separately-gated future debt:** (i) row 17 SELF-HEALING-AUTHORITY-REDESIGN (lifecycle / authority-model debt; SCOPE-FIRST treatment; not displaced by v1.107.0); (ii) FHS Authority Graph / ATG (intentionally deferred — not a v1.107.0 blocker; will not open before release; after v1.108.0 the operator may introduce it as a separate debt lane with its own scope gate); (iii) optional org-level GHCR `sha-*` retention policy (forward-looking hygiene, post-v1.107).
**Schema status:** schema remains frozen at `1.83.0` in v1.107.1. No metric names, labels, or health JSON schema changed. The three v1.100.4 H4 disclosure items (ban attribution under `source=manual`, `EffectiveIdle` for Portscan/LoginMon, shared `input_syn_rate_exceeded` counter) are unchanged in v1.107.0. The schema / metrics lane (Lane S) remains held; deeper attribution / effective-state work is routed to a future release. No metrics, portal, lifecycle, install, packaging-payload, or panel-adapter changes in v1.107.0.
**Truth model:** Kernel → Validator → CLI
**Enforcement:** [Design Principles](docs/DESIGN_PRINCIPLES.md)

---

## 0. What This Page Represents

This is not a badge collection.

This page is a **live, machine-verifiable audit surface** showing how NFTBan
enforces system integrity through automated CI/CD pipelines.

**Authority model:**
Kernel (nftables) is the only source of truth. All validation, metrics, and
CLI output derive from kernel state via the Go validator. The daemon `/metrics`
endpoint is the canonical runtime observability surface.

**Evidence model:**
Protection state is derived from kernel-observable evidence (counters, sets,
meters). Structural presence alone does not imply enforcement.

Every check listed here is:

- **Automated** — runs without human intervention on every PR and push
- **Reproducible** — identical inputs produce identical results
- **Verifiable** — badge links go directly to workflow run logs

No check relies on manual verification.

If any check fails, the corresponding code **cannot be merged or released**.

This model allows operators and auditors to independently verify system
integrity without trusting documentation or claims.

This page covers four verification axes:

1. Build correctness and runtime safety
2. Architecture and contract enforcement
3. Security and supply chain integrity
4. Compliance and provenance attestation

---

## 1. Build & Runtime Verification

These workflows verify that NFTBan compiles, installs, and executes correctly
across all supported platforms.

| Workflow | What it verifies | Frequency | Status |
|---|---|---|---|
| [Go Build & Test](https://github.com/itcmsgr/nftban/actions/workflows/ci-go.yml) | Compilation, unit tests, race detection, module completeness (G8-1/2/3), schema codegen lock | Every PR + push | [![Go](https://github.com/itcmsgr/nftban/actions/workflows/ci-go.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-go.yml) |
| [Bash Validation](https://github.com/itcmsgr/nftban/actions/workflows/ci-bash.yml) | Shell correctness under `set -Eeuo pipefail`, execution safety | Every PR + push | [![Bash](https://github.com/itcmsgr/nftban/actions/workflows/ci-bash.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-bash.yml) |
| [ShellCheck](https://github.com/itcmsgr/nftban/actions/workflows/shellcheck.yml) | Static shell analysis (SC2 rules) | Every PR + push | [![ShellCheck](https://github.com/itcmsgr/nftban/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/shellcheck.yml) |
| [Build Packages](https://github.com/itcmsgr/nftban/actions/workflows/build-packages.yml) | RPM + DEB build and install test across 7 platform targets | Every PR + push | [![Build](https://github.com/itcmsgr/nftban/actions/workflows/build-packages.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/build-packages.yml) |
| [Docker](https://github.com/itcmsgr/nftban/actions/workflows/docker.yml) | Container build reproducibility | Every PR + push | [![Docker](https://github.com/itcmsgr/nftban/actions/workflows/docker.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/docker.yml) |
| [Smoke Test](https://github.com/itcmsgr/nftban/actions/workflows/ci-smoke.yml) | CLI runtime execution, JSON output validity, runtime anomaly detection | Every PR + push | [![Smoke](https://github.com/itcmsgr/nftban/actions/workflows/ci-smoke.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-smoke.yml) |
| [Release](https://github.com/itcmsgr/nftban/actions/workflows/release.yml) | Signed release pipeline with provenance attestation | Release only | [![Release](https://github.com/itcmsgr/nftban/actions/workflows/release.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/release.yml) |

---

## 2. Architecture & Contract Enforcement

These workflows enforce structural invariants that prevent regression of the
kernel-first truth model.

**Structural invariant:** No rule may shadow another. Detection logic must
remain reachable in the nftables chain. Shadowed logic (e.g., accept rules
before detection jumps) is treated as DEGRADED state.

| Workflow | What it verifies | Frequency | Status |
|---|---|---|---|
| [Architecture Policy](https://github.com/itcmsgr/nftban/actions/workflows/ci-architecture.yml) | Schema integrity, vocabulary discipline (G1-1), module consistency (G8-4), codegen drift detection, nft direct-write protection | Every PR + push | [![Architecture](https://github.com/itcmsgr/nftban/actions/workflows/ci-architecture.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-architecture.yml) |
| [Documentation](https://github.com/itcmsgr/nftban/actions/workflows/ci-docs.yml) | Markdown lint, link validity, doc completeness | Every PR + push | [![Docs](https://github.com/itcmsgr/nftban/actions/workflows/ci-docs.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ci-docs.yml) |
| [Project Health](https://github.com/itcmsgr/nftban/actions/workflows/project-health.yml) | Repository hygiene, stale issues, PR quality | Scheduled | [![Health](https://github.com/itcmsgr/nftban/actions/workflows/project-health.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/project-health.yml) |

The Architecture Policy workflow is the primary anti-regression guard. It
prevents changes that would break the kernel → validator → CLI truth pipeline
or introduce vocabulary drift in operator-facing output.

---

## 3. Security & Supply Chain (Zero-Trust)

These workflows implement defense-in-depth security scanning. No single tool
covers all attack surfaces — the combination provides layered coverage.

| Workflow | What it verifies | Frequency | Status |
|---|---|---|---|
| [CodeQL](https://github.com/itcmsgr/nftban/actions/workflows/codeql.yml) | Semantic SAST for Go (data flow, taint tracking) | Every PR + push | [![CodeQL](https://github.com/itcmsgr/nftban/actions/workflows/codeql.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/codeql.yml) |
| [Semgrep](https://github.com/itcmsgr/nftban/actions/workflows/semgrep.yml) | Pattern-based security rules (Go + Shell) | Every PR + push | [![Semgrep](https://github.com/itcmsgr/nftban/actions/workflows/semgrep.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/semgrep.yml) |
| [Secure Go](https://github.com/itcmsgr/nftban/actions/workflows/secure-go.yml) | gosec, govulncheck, staticcheck, Trivy container scan | Every PR + push | [![SecureGo](https://github.com/itcmsgr/nftban/actions/workflows/secure-go.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/secure-go.yml) |
| [OSV-Scanner](https://github.com/itcmsgr/nftban/actions/workflows/osv-scanner.yml) | Dependency CVE detection via Google OSV database | Every PR + weekly | [![OSV](https://github.com/itcmsgr/nftban/actions/workflows/osv-scanner.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/osv-scanner.yml) |
| [Gitleaks](https://github.com/itcmsgr/nftban/actions/workflows/gitleaks.yml) | Secret and credential leakage detection | Every PR + push | [![Gitleaks](https://github.com/itcmsgr/nftban/actions/workflows/gitleaks.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/gitleaks.yml) |
| [Fuzz Tests](https://github.com/itcmsgr/nftban/actions/workflows/fuzz.yml) | Parser robustness via automated fuzzing | Nightly | [![Fuzz](https://github.com/itcmsgr/nftban/actions/workflows/fuzz.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/fuzz.yml) |
| [Dependency Review](https://github.com/itcmsgr/nftban/actions/workflows/dependency-review.yml) | Dependency diff risk analysis on PRs | Every PR | [![DepReview](https://github.com/itcmsgr/nftban/actions/workflows/dependency-review.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/dependency-review.yml) |
| [Socket Supply Chain](https://github.com/itcmsgr/nftban/actions/workflows/socket-supplychain.yml) | Typosquatting, malicious package, and behavioral detection | Every PR + push | [![Socket](https://github.com/itcmsgr/nftban/actions/workflows/socket-supplychain.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/socket-supplychain.yml) |
| [Security Summary](https://github.com/itcmsgr/nftban/actions/workflows/security-summary.yml) | Consolidated security posture dashboard | Scheduled | [![SecSummary](https://github.com/itcmsgr/nftban/actions/workflows/security-summary.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/security-summary.yml) |

---

## 4. Compliance & Provenance

These workflows provide verifiable evidence of license compliance and build
provenance for enterprise and audit requirements.

| Workflow | What it verifies | Frequency | Status |
|---|---|---|---|
| [OSSRA Remediation](https://github.com/itcmsgr/nftban/actions/workflows/ossra-remediation.yml) | License compliance (go-licenses), SPDX header validation, dependency freshness (libyear), URL integrity (Lychee) | Every PR + push | [![OSSRA](https://github.com/itcmsgr/nftban/actions/workflows/ossra-remediation.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/ossra-remediation.yml) |
| [OpenSSF Scorecard](https://github.com/itcmsgr/nftban/actions/workflows/scorecard.yml) | OpenSSF security posture scoring | Scheduled | [![Scorecard](https://github.com/itcmsgr/nftban/actions/workflows/scorecard.yml/badge.svg)](https://github.com/itcmsgr/nftban/actions/workflows/scorecard.yml) |
| [SLSA Provenance](https://github.com/itcmsgr/nftban/actions/workflows/slsa-go-releaser.yml) | Cryptographic build attestation (SLSA Level 3) | Release only | [![SLSA 3](https://slsa.dev/images/gh-badge-level3.svg)](https://slsa.dev) |

Every release includes:

- SLSA Level 3 provenance (non-forgeable build attestation)
- SBOM in SPDX-JSON format
- GPG-signed tags and artifacts
- All GitHub Actions pinned to commit SHAs

---

## 5. Contract Gates

These are **blocking gates** enforced by CI workflows. A failure in any gate
prevents merge to main. They enforce [Design Principles](docs/DESIGN_PRINCIPLES.md)
directly in code — not by policy document, but by automated test.

| Gate | Design Principle | What it prevents |
|---|---|---|
| **G1-1** | Vocabulary discipline | Banned terms in CLI output ("healthy", "OK", "working", etc.) |
| **G2-3** | Schema consistency | CLI expected schema ≠ validator schema version |
| **G8-1** | Module completeness | CORE module missing from evaluator or JSON output |
| **G8-2** | Config classification | Module config directory without classification |
| **G8-3** | IPv6 parity | IPv4 structural check without matching IPv6 check |
| **G8-4** | Cross-surface truth | Validator module list ≠ CLI module list |
| **INV-M-001** | Single kernel read | Evidence layer calls nft directly (must go through validator) |
| **INV-M-003** | Metric ownership | Duplicate metric collection across components |
| **INV-M-005** | No shell duplication | Shell exporter duplicates daemon kernel collection |

These gates are tested as part of `ci-go.yml` (Go unit tests) and
`ci-architecture.yml` (structural policy checks).

---

## 6. Pipeline Statistics (Automation Proof)

These values represent enforced automation, not documentation claims.

| Metric | Value |
|---|---|
| CI/CD workflows | 24 |
| Security scanning tools | 10 |
| Contract gates (blocking) | 9 |
| Package build targets | 7 (el9, el10, ubuntu22/24, debian12/13, + validation) |
| Install test environments | 5 (rocky9, alma9, centos-stream9/10, debian12) |
| Canonical daemon metrics | ~110 (post v1.90 name freeze) |
| Provenance level | SLSA Level 3 |
| SBOM format | SPDX-JSON |

---

## 7. Runtime Truth Verification

Post-deploy verification commands that prove kernel enforcement on live hosts:

```bash
# 1. Kernel-derived health state (authoritative)
nftban-validate --json | jq '.status'
# Expected: "protected", "idle", or "degraded"

# 2. CLI truth (must match validator — INV-CONS-001)
nftban health --json | jq '.status'
# Must match validator output exactly

# 3. Evidence metrics (observable enforcement data)
nftban metrics evidence
nftban metrics evidence-json

# 4. Kernel structure verification
nft list tables
nft list chain ip nftban input | grep ANCHOR
# Must show 7 anchors: HYGIENE → TRUSTED → BAN → ESTABLISHED → DETECT → SERVICE → FINAL
```

**System invariant:** Kernel == Validator == CLI

If any of these commands disagree, the system state is invalid and must be
treated as DEGRADED regardless of what individual surfaces report.

---

## 8. Health Policy

- Main branch is always green
- Failed CI blocks merge — no exceptions
- No manual overrides for truth-critical checks
- Every release is CI-gated before tag
- Evidence over claims — if it cannot be measured, it cannot be stated
- Unknown state → DEGRADED (never PROTECTED)

---

## 9. Interpretation Guide

| Badge status | Meaning |
|---|---|
| **Green** | Workflow passed — invariant verified |
| **Red** | Workflow failed — code cannot merge or release until resolved |
| **Skipped** | Workflow not triggered for this event type (expected for some PR-only checks) |
| **Neutral** | Advisory result (e.g., gosec code annotations) — does not block |
| **No badge** | Workflow runs on a different trigger (release-only, scheduled) |

---

## 10. Integrity Statement

NFTBan does not claim protection. It **proves** protection through:

- **Kernel evidence** — nftables counters, sets, and chain structure
- **Automated validation** — Go validator reads kernel state (~1ms)
- **Reproducible CI** — 24 workflows, 10 security tools, 9 contract gates
- **Cryptographic provenance** — SLSA Level 3 attestation on every release

If any invariant breaks, the system reports **DEGRADED**, not PROTECTED.

This is not a design claim. It is enforced by CI and validator logic.

---

> [SECURITY.md](SECURITY.md) — Vulnerability reporting and supported versions
> [Design Principles](docs/DESIGN_PRINCIPLES.md) — Engineering contract for all components
> [Wiki](https://github.com/itcmsgr/nftban/wiki) — Full system specification
