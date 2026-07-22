# Privacy identifier policy (developer guide)

_v1.226.0 privacy defense-in-depth. How real identifiers are kept out of the tree and out of
CI output, and how the two independent gates work._

## Approved example values — never use a real identifier

A real operator/customer/third-party identifier must NEVER appear anywhere in the tree —
including comments, documentation, test fixtures, regex examples, and the scanner's own
examples — and never as a reversible encoding (base64, hex, plain hash) of one. Use only:

| Purpose | Use |
|---------|-----|
| Documentation IPv4 | RFC 5737: `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24` |
| Documentation IPv6 | RFC 3849: `2001:db8::/32` |
| Domains | `example.test`, `example.com/.net/.org` |
| A value a product test must treat as **globally public** | an approved project synthetic-public fixture (e.g. the `1.2.3.0/24` convention) — NOT RFC5737, which the product classifies as documentation/non-public |

**Documentation-only vs synthetic-public:** RFC5737/RFC3849 are *documentation* ranges; the
product's RBL/whitelist logic classifies them as non-public. If a test must exercise
**public-address admission**, use the approved synthetic-public convention instead — do not
substitute a documentation range into such a test (that reintroduces the doc-range fixture bug).

## Two independent gates

1. **Generic scanner** — `scripts/ci/privacy-scan.py`. Public, committed detection. Classifies
   IPs/paths/domains; blocks the release surface and the whole tree on
   `REAL_OPERATOR_IDENTIFIER` / `SHIPPED_PUBLIC_SURFACE`. It **scans its own source** (no
   whole-file self-exemption); a real value accidentally placed in it is caught. Narrow,
   delimited `# privacy-allow-synthetic-begin/-end` (or a trailing `# privacy-allow-synthetic`)
   blocks may downgrade a **synthetic** finding on specific lines — they can NEVER downgrade a
   deny-authority (`REAL_OPERATOR_IDENTIFIER`) finding.
2. **Private identifier gate** — `scripts/ci/private-identifier-gate.py`. A SECOND, INDEPENDENT
   control with its own extraction/canonicalization (no shared normalization core — common-mode
   failure prevention). It compares the tree against a **secret-provided** denylist of
   known-real identifiers, recognizing literal / escaped-dot / double-escaped / quoted / anchored
   / URL-encoded IPv4 and compressed/expanded/upper/bracketed IPv6. Output is redacted: path,
   line, class, a redacted form, and a short **HMAC-keyed** fingerprint — never the raw token
   and never the full source line.

## Running the gates locally

```
python3 scripts/ci/privacy-scan-selftest.py
python3 scripts/ci/private-identifier-gate-selftest.py
python3 scripts/ci/privacy-scan.py --scope repository --strict          # whole-tree generic
python3 scripts/ci/privacy-scan.py --changed-lines origin/main --strict # changed-line generic
# Private gate (maintainers only; denylist + key are secrets, never committed):
NFTBAN_PRIVACY_DENYLIST_FILE=/path/to/private/denylist \
NFTBAN_PRIVACY_FP_KEY="$(cat /path/to/private/fp.key)" \
  python3 scripts/ci/private-identifier-gate.py --whole-tree --mode publication
```

The denylist file lives OUTSIDE the repository. It is never committed, never printed, and never
placed in workflow YAML, logs, artifacts, cache keys, or job summaries.

## CI wiring (blocking sequence)

In `ci-architecture.yml` Policy Gates, on every PR/push (no secret needed for the generic gates):
scanner self-tests → private-gate self-tests → generic whole-tree scan (includes scanner source)
→ generic changed-line scan (PRs) → private deny gate (advisory, auto-activates with the secret)
→ release-surface scan. The private gate is **advisory** here so untrusted fork PRs — which
receive no secrets — never block on it, while the generic gates always block. The workflow uses
`pull_request` (never `pull_request_target`): fork code runs read-only with no secret access.

`release.yml` runs the private gate in **publication / fail-closed** mode: a missing/empty/
malformed denylist, a missing fingerprint key, or any scan error BLOCKS the release. This is why
publication cannot proceed without private validation. Provisioning `NFTBAN_PRIVACY_DENYLIST`
and `NFTBAN_PRIVACY_FP_KEY` as repository secrets is a maintainer prerequisite before releasing.

## Trusted merge gate (protected main)

The PR/push private-gate step is **advisory** so untrusted fork PRs (which receive no
secrets) never block on it. That is safe for fork execution but insufficient by itself to
keep privacy-contaminated code out of protected `main`. Therefore, before an internal PR may
merge, **one trusted execution must run against the exact PR-head SHA**:

- `.github/workflows/privacy-trusted-merge-gate.yml` (`workflow_dispatch`, protected
  environment `privacy-gate`). A maintainer triggers it **from the default branch**,
  supplying the approved PR-head SHA.
- It checks out the **trusted gate implementation from the workflow's own ref** (not the PR)
  and the **PR-head content into a separate directory that is only scanned as data** (via
  `--selftest-root`, never executed). The secret is present only in the trusted-gate step.
- On completion it posts a commit status `privacy/trusted-private-gate` bound to the exact
  PR-head SHA. **Branch protection requires that status context**, so a merge cannot proceed
  without a trusted PASS on that exact head.

Security properties: fork/PR code is never executed with secrets; a PR-modified gate or
workflow is never the code that runs (the trusted ref supplies it); the checkout SHA is
explicit; the result binds to the exact head; `pull_request_target` and privileged
`workflow_run`-over-fork-code are not used.

**Enforcement activation (maintainer, after secret provisioning):** add
`privacy/trusted-private-gate` to `main`'s required status checks. Do this only after the
secrets are provisioned and this workflow exists on `main`; enabling it earlier would
deadlock all merges (the required check would never be produced).

## Historical residuals ≠ current-tree cleanliness

A clean current tree does not mean history is clean. The pre-existing test-fixture residue in
older commits/tags and the published v1.225.0 packages, and GitHub-managed `refs/pull/*`, are
tracked as SEPARATE, explicitly-open remediation/disclosure lanes — not closed by current-tree
gates.
