# Repository Health & Security - TODO List

**Status:** Feature backlog for future implementation
**Priority:** Medium (security & maintainability improvements)
**Effort:** Medium (each item requires 1-3 hours)
**Reference:** `/home/gituser/github/repo_health.txt`

---

## ✅ Completed

- [x] SHA256SUMS.txt automated generation (v0.9.0)
- [x] TruffleHog secret scanning in health.yml (v0.9.0)
- [x] Workflow permissions hardening (v0.9.0)
- [x] Checkout security improvements (v0.9.0)

---

## 🔒 Security & Code Quality

### 1. OpenSSF Scorecard Integration

**Priority:** High
**Effort:** 2-3 hours
**Benefits:** Automated security posture assessment with industry-standard metrics

**Tasks:**
- [ ] Create `.github/workflows/scorecard.yml`
- [ ] Configure SARIF upload to GitHub Code Scanning
- [ ] Enable weekly scheduled runs
- [ ] Set up permissions correctly (id-token: write for publishing)
- [ ] Review first scorecard report and address low scores
- [ ] Add scorecard badge to README.md

**Configuration:**
```yaml
# .github/workflows/scorecard.yml
name: OpenSSF Scorecard
on:
  schedule:
    - cron: '37 2 * * 1'  # Weekly Monday
  push:
    branches: [ main ]
permissions:
  contents: read
  security-events: write
  id-token: write
jobs:
  scorecard:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false
      - uses: ossf/scorecard-action@v2.4.0
        with:
          results_file: results.sarif
          results_format: sarif
          publish_results: true
      - uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: results.sarif
```

**Expected Impact:**
- Security best practices verification
- Automated vulnerability detection
- Supply chain security assessment
- GitHub Security tab integration

---

### 2. CodeQL Code Scanning

**Priority:** High
**Effort:** 1-2 hours
**Benefits:** Automated security vulnerability detection in code

**Tasks:**
- [ ] Create `.github/workflows/codeql.yml`
- [ ] Determine which languages to scan (JavaScript? Python? Shell?)
- [ ] Configure autobuild or manual build steps
- [ ] Test workflow on feature branch first
- [ ] Review findings and fix any high-severity issues
- [ ] Enable required status check in branch protection

**Configuration:**
```yaml
# .github/workflows/codeql.yml
name: CodeQL Analysis
on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]
  schedule:
    - cron: '30 1 * * 2'  # Weekly Tuesday
permissions:
  contents: read
  security-events: write
jobs:
  analyze:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        # Choose languages present in your codebase
        language: [ 'javascript', 'python' ]
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false
      - uses: github/codeql-action/init@v3
        with:
          languages: ${{ matrix.language }}
      - uses: github/codeql-action/autobuild@v3
      - uses: github/codeql-action/analyze@v3
```

**Languages to Consider:**
- Shell scripts (if CodeQL supports)
- JavaScript (if any Node.js tooling)
- Python (if any Python scripts)

**Expected Impact:**
- SQL injection detection
- Command injection detection
- Path traversal vulnerabilities
- Hardcoded credentials detection

---

### 3. Dependabot Configuration

**Priority:** Medium
**Effort:** 1 hour
**Benefits:** Automated dependency updates and security patches

**Tasks:**
- [ ] Create `.github/dependabot.yml`
- [ ] Configure ecosystems (GitHub Actions, npm, pip, etc.)
- [ ] Set update schedule (weekly recommended)
- [ ] Configure PR limits to avoid spam
- [ ] Test with one ecosystem first
- [ ] Set up auto-merge rules for minor/patch updates (optional)

**Configuration:**
```yaml
# .github/dependabot.yml
version: 2
updates:
  # GitHub Actions dependencies
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
      day: "monday"
    open-pull-requests-limit: 5
    reviewers:
      - "itcmsgr"
    labels:
      - "dependencies"
      - "github-actions"

  # npm dependencies (if applicable)
  - package-ecosystem: "npm"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 5
    ignore:
      - dependency-name: "*"
        update-types: ["version-update:semver-major"]

  # Python dependencies (if applicable)
  - package-ecosystem: "pip"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 5
```

**Expected Impact:**
- Automatic security patch PRs
- Stay up-to-date with dependencies
- Reduced manual maintenance
- Security advisory alerts

---

### 4. Dependency Review Action (for PRs)

**Priority:** Medium
**Effort:** 30 minutes
**Benefits:** Review dependency changes in pull requests

**Tasks:**
- [ ] Add dependency-review job to existing workflow or create new one
- [ ] Configure severity threshold (fail on high/critical)
- [ ] Set allowed licenses list
- [ ] Test with sample PR
- [ ] Document for contributors

**Configuration:**
```yaml
# Add to .github/workflows/health.yml or create separate workflow
jobs:
  dependency-review:
    name: Dependency Review
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false
      - uses: actions/dependency-review-action@v4
        with:
          fail-on-severity: high
          allow-licenses: Apache-2.0, MIT, BSD-2-Clause, BSD-3-Clause, GPL-3.0
          deny-licenses: AGPL-3.0, LGPL-2.0
```

**Expected Impact:**
- Catch vulnerable dependencies before merge
- License compliance checks
- Supply chain attack prevention

---

### 5. Super-Linter Integration

**Priority:** Low-Medium
**Effort:** 2-3 hours
**Benefits:** Multi-language linting in one action

**Tasks:**
- [ ] Create `.github/workflows/super-linter.yml` or add to health.yml
- [ ] Configure which linters to enable/disable
- [ ] Set up `.github/linters/` config files for each linter
- [ ] Run on PR only (not on push to avoid noise)
- [ ] Fix initial linting issues
- [ ] Add to required checks

**Configuration:**
```yaml
# Can be added to health.yml or separate file
jobs:
  super-lint:
    name: Super-Linter
    runs-on: ubuntu-latest
    permissions:
      contents: read
      statuses: write
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false
          fetch-depth: 0

      - name: Super-Linter
        uses: super-linter/super-linter@v7
        env:
          VALIDATE_ALL_CODEBASE: false  # Only changed files in PR
          DEFAULT_BRANCH: main
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          # Enable/disable specific linters
          VALIDATE_BASH: true
          VALIDATE_MARKDOWN: true
          VALIDATE_YAML: true
          VALIDATE_JSON: true
          VALIDATE_SHELL_SHFMT: true
          # Disable noisy ones
          VALIDATE_JSCPD: false
```

**Pros:**
- All linters in one action
- Consistent formatting
- Catches common mistakes

**Cons:**
- Can be noisy/slow
- May conflict with existing linters
- Need to tune configuration

**Expected Impact:**
- Consistent code style
- Early bug detection
- Better code quality

---

## 🔐 GitHub Settings & Configuration

### 6. Branch Protection Rules

**Priority:** High
**Effort:** 30 minutes
**Benefits:** Prevent direct pushes to main, require reviews

**Tasks:**
- [ ] Navigate to Settings → Branches → Add rule for `main`
- [ ] Enable "Require pull request before merging"
- [ ] Set required approvals (1-2 reviewers)
- [ ] Enable "Require status checks to pass"
  - [ ] Select: Project Health
  - [ ] Select: SHA256 Generation
  - [ ] Select: CodeQL (once implemented)
  - [ ] Select: Scorecard (once implemented)
- [ ] Enable "Require conversation resolution before merging"
- [ ] Enable "Require linear history" (optional, prevents merge commits)
- [ ] Enable "Require signed commits" (recommended)
- [ ] Restrict who can push to matching branches
- [ ] Enable "Do not allow bypassing the above settings"

**Expected Impact:**
- No accidental direct pushes to main
- Code review requirement
- CI must pass before merge
- Better collaboration

---

### 7. Enable GitHub Security Features

**Priority:** High
**Effort:** 15 minutes
**Benefits:** Native GitHub security protections

**Tasks:**
- [ ] Navigate to Settings → Code security and analysis
- [ ] Enable "Dependency graph" (should already be on)
- [ ] Enable "Dependabot alerts"
- [ ] Enable "Dependabot security updates"
- [ ] Enable "Secret scanning"
- [ ] Enable "Push protection" for secrets
- [ ] Enable "Code scanning" (for CodeQL/Scorecard results)
- [ ] Set up security policy (already have SECURITY.md)
- [ ] Configure security advisories notification email

**Expected Impact:**
- Automatic vulnerability alerts
- Secret leak prevention
- Security dashboard visibility

---

### 8. CODEOWNERS File

**Priority:** Low
**Effort:** 20 minutes
**Benefits:** Auto-assign reviewers for specific paths

**Tasks:**
- [ ] Create `.github/CODEOWNERS`
- [ ] Define ownership patterns
- [ ] Create GitHub teams if needed (itcmsgr/core, itcmsgr/security)
- [ ] Test with a PR
- [ ] Document for contributors

**Configuration:**
```
# .github/CODEOWNERS

# Default owners for everything
* @itcmsgr

# GitHub workflows and CI/CD
.github/** @itcmsgr
.ci/** @itcmsgr

# Security-critical files
SECURITY.md @itcmsgr
SHA256SUMS.txt @itcmsgr
.github/workflows/generate-sha256.yml @itcmsgr

# Core modules
lib/nftban_core.sh @itcmsgr
lib/nftban_safety_module.sh @itcmsgr

# Installer
lib/installer/** @itcmsgr

# Documentation
docs/** @itcmsgr
README.md @itcmsgr
CHANGELOG.md @itcmsgr
```

**Expected Impact:**
- Automatic review requests
- Clear ownership
- Faster review process

---

## 📚 Documentation & Governance

### 9. CONTRIBUTING.md

**Priority:** Medium
**Effort:** 1 hour
**Benefits:** Clear contribution guidelines

**Tasks:**
- [ ] Create `CONTRIBUTING.md` in root
- [ ] Document code style requirements
- [ ] Explain how to run tests locally
- [ ] Describe PR process
- [ ] List required checks
- [ ] Add commit message conventions
- [ ] Link to SECURITY.md for security issues
- [ ] Add "good first issue" guidance

**Template Outline:**
```markdown
# Contributing to nftban

## Code of Conduct
Be professional and respectful.

## How to Contribute

### Reporting Bugs
Use GitHub Issues with the bug template.

### Suggesting Features
Use GitHub Discussions or feature request template.

### Pull Request Process
1. Fork the repository
2. Create a feature branch
3. Run local tests: `bash .ci/health_check.sh`
4. Ensure shellcheck passes: `shellcheck lib/*.sh`
5. Update CHANGELOG.md
6. Submit PR with clear description

### Code Style
- Use ShellCheck
- Follow existing patterns
- Add comments for complex logic
- Update documentation

### Commit Messages
- Use conventional commits: `feat:`, `fix:`, `docs:`, `chore:`
- Keep subject under 72 characters
- Add body for complex changes

### Required Checks
All PRs must pass:
- Project Health workflow
- Secret scanning
- SHA256 generation (for file changes)
```

**Expected Impact:**
- Easier for contributors
- Consistent quality
- Less back-and-forth on PRs

---

### 10. Pull Request Template

**Priority:** Low
**Effort:** 20 minutes
**Benefits:** Structured PR descriptions

**Tasks:**
- [ ] Create `.github/PULL_REQUEST_TEMPLATE.md`
- [ ] Include checklist items
- [ ] Add sections for description, testing, related issues
- [ ] Test with a sample PR

**Template:**
```markdown
## Description
<!-- Brief description of changes -->

## Type of Change
- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] Documentation update
- [ ] Security fix

## Related Issues
Closes #<!-- issue number -->

## How Has This Been Tested?
<!-- Describe the tests you ran -->

## Checklist
- [ ] Code follows the project style guidelines
- [ ] I have performed a self-review of my own code
- [ ] I have commented my code, particularly in hard-to-understand areas
- [ ] I have updated the documentation accordingly
- [ ] I have updated CHANGELOG.md
- [ ] My changes generate no new warnings
- [ ] I have run local tests and they pass
- [ ] Any dependent changes have been merged and published

## Screenshots (if applicable)
<!-- Add screenshots to help explain your changes -->
```

**Expected Impact:**
- Complete PR information
- Faster reviews
- Better documentation

---

## 🚀 Release & Distribution

### 11. Signed Releases & Provenance

**Priority:** Medium
**Effort:** 2-3 hours
**Benefits:** Verify release authenticity

**Tasks:**
- [ ] Set up GPG key for signing releases
- [ ] Create release workflow that signs tags
- [ ] Generate SLSA provenance (optional, advanced)
- [ ] Attach SHA256SUMS.txt to releases
- [ ] Document verification process
- [ ] Consider GitHub Attestations (beta feature)

**Configuration:**
```yaml
# .github/workflows/release.yml
name: Release
on:
  push:
    tags:
      - 'v*'
jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
      - name: Generate checksums
        run: |
          sha256sum lib/*.sh > SHA256SUMS.txt
      - name: Create Release
        uses: softprops/action-gh-release@v1
        with:
          files: |
            SHA256SUMS.txt
          generate_release_notes: true
          draft: false
```

**Expected Impact:**
- Release integrity verification
- Supply chain security
- User trust

---

### 12. Automated Release Notes

**Priority:** Low
**Effort:** 1 hour
**Benefits:** Auto-generated changelogs from PRs

**Tasks:**
- [ ] Configure release-drafter workflow
- [ ] Create `.github/release-drafter.yml` config
- [ ] Label PRs appropriately
- [ ] Test with next release
- [ ] Keep manual CHANGELOG.md or sync?

**Expected Impact:**
- Faster releases
- Consistent changelog format

---

## 📊 Monitoring & Metrics

### 13. GitHub Insights Dashboard

**Priority:** Low
**Effort:** 30 minutes
**Benefits:** Track repository health metrics

**Tasks:**
- [ ] Review Insights → Community Standards
- [ ] Complete missing items (already have most)
- [ ] Review Pulse regularly
- [ ] Monitor Traffic and Engagement
- [ ] Track Security advisories

**Expected Impact:**
- Better understanding of project health
- Identify areas for improvement

---

## 🔄 Continuous Improvement

### 14. Workflow Optimization

**Priority:** Low
**Effort:** Ongoing
**Benefits:** Faster CI/CD, cost savings

**Tasks:**
- [ ] Review workflow run times
- [ ] Cache dependencies where possible
- [ ] Use matrix strategies for parallel execution
- [ ] Optimize artifact retention
- [ ] Review concurrency settings

**Expected Impact:**
- Faster feedback
- Lower GitHub Actions minutes usage

---

## 📝 Implementation Priority

### Phase 1 (High Priority - Security)
1. OpenSSF Scorecard Integration
2. Branch Protection Rules
3. Enable GitHub Security Features
4. CodeQL Code Scanning

### Phase 2 (Medium Priority - Automation)
5. Dependabot Configuration
6. Dependency Review Action
7. CODEOWNERS File
8. CONTRIBUTING.md

### Phase 3 (Low Priority - Nice to Have)
9. Pull Request Template
10. Super-Linter Integration
11. Signed Releases & Provenance
12. Automated Release Notes

---

## 🎯 Quick Wins (< 30 minutes each)

- [ ] Enable GitHub Security Features (15 min)
- [ ] Create CODEOWNERS file (20 min)
- [ ] Add Dependency Review to existing workflow (30 min)
- [ ] Pull Request Template (20 min)

---

## 📖 References

- **Original Recommendations:** `/home/gituser/github/repo_health.txt`
- **GitHub Security Best Practices:** https://docs.github.com/en/code-security
- **OpenSSF Scorecard:** https://github.com/ossf/scorecard
- **Actions Security Hardening:** https://docs.github.com/en/actions/security-guides/security-hardening-for-github-actions

---

## 📅 Review Schedule

- **Monthly:** Review this TODO list and pick 1-2 items to implement
- **Quarterly:** Audit all security settings and workflows
- **Annually:** Full security review and update practices

---

<p align="center">
  <sub>This is a living document. Update as items are completed or priorities change.</sub>
</p>

<p align="center">
  <sub>Copyright © 2025 Antonios Voulvoulis – ITCMS. All rights reserved.</sub>
</p>
