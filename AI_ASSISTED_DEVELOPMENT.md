# AI-Assisted Development

NFTBan is developed with the assistance of AI tools (including, at various times,
ChatGPT and Claude).

## How AI tools are used

- AI tools may assist with **drafting, code review, tests, audit prompts, and
  documentation**.
- Every accepted change is **reviewed and approved by NFTBan Project / Antonios Voulvoulis**
  before it is merged. The human maintainer is responsible for all merged content.

## What AI tools are not

- AI tools are **not authors, contributors, maintainers, copyright holders, or
  owners** of NFTBan. They hold no rights in the project.
- All copyright in NFTBan is claimed by **Antonios Voulvoulis <contact@nftban.com>** to the
  fullest extent permitted by law.
- NFTBan Core is distributed under the **Mozilla Public License 2.0 (MPL-2.0)**;
  see `LICENSE`. Trademarks and brand assets are governed separately by
  `TRADEMARK.md`.

## Commit metadata policy

- Commit metadata **MUST NOT** credit AI tools as authors. Do not add
  `Co-Authored-By: Claude`, `Co-Authored-By: ChatGPT`, or any equivalent
  AI/`OpenAI`/`Anthropic` co-author trailer to commits going forward.
- Existing `Co-Authored-By` trailers in historical commits are treated as
  **legacy metadata only** and are not authorship or copyright assignments. Git
  history is **not** rewritten to remove them.

### Enforcement of the commit metadata policy

As of v1.231.0 the policy above is enforced in CI, and this section states the
transition plainly rather than claiming the repository is clean.

- **The repository is not free of AI co-author trailers, and no claim is made
  that it is.** Measured at commit `3c5d9286`: 2,734 of 4,219 commits carry an
  AI `Co-Authored-By` trailer, 26 of them in the last 100. Those commits are
  **not rewritten**. Published tags, including `v1.228.2`, stay as published.
- **Enforcement begins at the enforcement commit**
  `<ENFORCEMENT_COMMIT_SHA — placeholder; fill in with the SHA of the commit
  that introduced scripts/ci/check-ai-coauthor-trailers.sh once it is merged>`.
  Commits before that commit retain their historical AI trailers as legacy
  metadata, exactly as the clause above provides.
- **Scope is the incoming pull-request range only.**
  `scripts/ci/check-ai-coauthor-trailers.sh` inspects `BASE..HEAD`, where `BASE`
  is the merge base of the pull request with its target branch. It never
  inspects history outside that range, so the gate cannot become a demand to
  rewrite published commits. A test control asserts exactly that
  (`cli/lib/nftban/tests/ai_coauthor_trailer_guard_v1231_test.sh`, T3).
- **What is prohibited is declared, not inferred.** The identities are listed in
  `scripts/ci/data/ai-coauthor-trailer-registry.tsv` and are the ones this
  document names in text: Claude, ChatGPT, OpenAI, Anthropic. The clause "or any
  equivalent AI ... co-author trailer" is an open category that a script cannot
  enumerate on its own; an AI identity not listed in the registry is a gap in
  this policy to be closed by editing both files, not a detector bug.
- **Detection is on git trailer syntax**, case- and whitespace-tolerant as git
  itself is. A commit message that merely discusses an AI tool in prose is not a
  violation. `github-actions[bot]` and `dependabot[bot]` are automation
  identities, not authorship claims, and are allowlisted.
- The gate runs in the `Policy Gates` job of
  `.github/workflows/ci-architecture.yml` on the `pull_request` event, and is
  blocking.

---

Copyright © 2024-2026 Antonios Voulvoulis.
