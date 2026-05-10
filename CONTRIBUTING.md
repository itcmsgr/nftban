# Contributing to NFTBan

Thank you for your interest in contributing to NFTBan! This document provides guidelines for contributing.

## System Integrity Model

NFTBan enforces correctness through:

- [STATUS.md](STATUS.md) — CI/CD audit surface (build, security, contract gates)
- [docs/DESIGN_PRINCIPLES.md](docs/DESIGN_PRINCIPLES.md) — engineering contract

All contributions must preserve:

- Kernel-first authority
- Validator-derived truth
- Evidence-based protection
- CI-enforced invariants

Changes that violate these principles must not be merged.

---

## About the Project

**NFTBan** is an open-source Linux Intrusion Prevention System (IPS) and firewall manager built on nftables, designed to integrate cleanly with modern Linux security stacks. The name stands for **NFTables BAN actions**, emphasizing the system's foundation on native nftables technology for kernel-level packet filtering.

## Project Terminology

When writing documentation or code:

- **NFTBAN** (all caps) — Project name in formal contexts, marketing materials, and when emphasizing the acronym
- **NFTBan** (title case) — Stylized form for README headers and user-facing documentation
- **nftban** (lowercase) — Command name, binary name, file paths, and code references
- **nftables** — Always lowercase (the underlying Linux kernel technology)

**Example usage:**
- ✅ "NFTBAN is built on nftables technology"
- ✅ "Run the `nftban` command to manage firewall rules"
- ✅ "See the NFTBan documentation for details"

## Code of Conduct

Please read our [Code of Conduct](.github/CODE_OF_CONDUCT.md) before contributing.

## How to Contribute

### Reporting Bugs

1. Check existing [issues](https://github.com/itcmsgr/nftban/issues) first
2. Use the bug report template
3. Include:
   - NFTBan version (`nftban version`)
   - OS and version (`cat /etc/os-release`)
   - Steps to reproduce
   - Expected vs actual behavior
   - Relevant logs (`/var/log/nftban/`)

### Suggesting Features

1. Check existing issues and discussions
2. Use the feature request template
3. Explain the use case and benefit

### Pull Requests

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Make your changes
4. Run smoke tests: `nftban smoke` (non-destructive) or `nftban selftest` (lab/deep validation)
5. Commit with clear messages
6. Push and create a PR

## Development Setup

### Prerequisites

- Go 1.24+
- Bash 4.4+
- nftables
- Linux (Rocky/Alma/Ubuntu/Debian)

### Building

```bash
# Clone repository
git clone https://github.com/itcmsgr/nftban.git
cd nftban

# Build Go binaries
./build.sh

# Install for testing
sudo ./install.sh
```

### Project Structure

```
nftban/
├── cli/                    # Bash CLI
│   └── lib/nftban/
│       ├── core/          # Core functionality
│       ├── cli/           # Command handlers
│       ├── helpers/       # Utility functions
│       └── setup/         # Installation helpers
├── cmd/                    # Go binaries
│   ├── nftban-core/       # Main Go binary
│   └── nftban-api-server/ # REST API
├── internal/              # Go internal packages
├── pkg/                    # Go public packages (ipc, version)
├── install/               # Installation scripts
├── packaging/             # RPM/DEB specs
└── docs/                  # Documentation
```

## Engineering Rules & Platform Contract (2026)

All contributors, automation, and AI assistants must comply with this engineering contract.
**If a change violates this document, it must not be merged.**

### 1. Supported Platforms (Non-Negotiable)

NFTBan supports platforms by tier. Only Tier 0 platforms define correctness.

**Tier 0 — Focus (CI-required)**
- Ubuntu 24.04 LTS
- Debian 12
- Rocky Linux 9.x

A change is correct only if it builds, installs, and passes receipt-based audit on all Tier 0 platforms.

**Tier 1 — Future Planning (Limited CI)**
- Rocky Linux 10.x
- Debian 13
- Ubuntu 26.04 LTS

Rules: Architecture must accommodate. No hardcoded assumptions. Failures do not block Tier 0 releases.

**Tier 2 — Legacy (Best-Effort Only)**
- Rocky/RHEL 8.x
- Ubuntu 22.04 LTS
- Debian 11

Rules: Must not break catastrophically. No new features or design decisions for these platforms.

### 2. Build Strategy (Build Old, Run New)

**This rule is mandatory.**

| Package | Build Host | Result |
|---------|------------|--------|
| RPM | Rocky Linux 9 | Ensures binaries run on Rocky 10+ |
| DEB | Debian 12 or Ubuntu 22.04 | Ensures binaries run on Ubuntu 26.04+ |

Violating this rule risks GLIBC incompatibility and is not allowed.

### 3. Filesystem & Permissions (FHS Contract)

- `build/fhs-spec.yaml` is the single source of truth
- All directories, ownership, and modes are generated
- No hardcoded mkdir, chmod, or chown outside generated outputs

**Forbidden patterns:**
- `chmod -R`
- `chown -R`
- Hardcoded `/etc/nftban`, `/var/lib/nftban`, `/run/nftban` creation
- Runtime writes to `/etc` by non-root services

Violations are rejected by CI and pre-commit hooks.

### 4. Distro Differences (No Guessing)

All distro-specific paths live in:
```
/etc/nftban/distros/*.conf
```

**Rules:**
- Installers, services, and validators must not guess paths
- Resolved values are written to the installation receipt
- Validation checks the receipt, not the OS

**Required keys:**
```ini
[paths]
nft =
systemctl =
polkit_rules_dir =
journalctl =
```

### 5. nftables Networking Standard

- **nftables only** — iptables legacy is not supported
- Always use the `inet` family
- Example: `nft add rule inet filter input tcp dport 22 accept`

### 6. Systemd & Security

- Use systemd sandboxing (ProtectSystem, NoNewPrivileges, etc.)
- Use sysusers.d and tmpfiles.d (generated)
- Services must not escalate privileges silently
- **Cron is forbidden** — use systemd timers only

### 7. Receipt Is the Authority

- Every install produces a receipt
- Receipt defines: paths, permissions, distro resolution
- Audit compares system → receipt
- **If receipt says it's wrong, it is wrong**

### 8. AI / Automation Rule

Any AI (Claude, etc.) must obey:
- README "Official Supported Platforms & Build Contract"
- This CONTRIBUTING.md
- No exceptions

---

## Mandatory Standards

All contributions **must** comply with these authoritative standards:

### 1. File Headers

Every source file must have a compliant header with:
- **SPDX-License-Identifier: MPL-2.0** (exactly one per file)
- All `meta:` tags with quoted values: `meta:key="value"`
- All inventory keys present (even if empty):
  ```
  meta:inventory.files=""
  meta:inventory.binaries=""
  meta:inventory.env_vars=""
  meta:inventory.config_files=""
  meta:inventory.systemd_units=""
  meta:inventory.network=""
  meta:inventory.privileges=""
  ```

This section is the authoritative header spec. CI enforces it via `tools/validate-headers.sh`.

### 2. Coding Standards

Full standards available at: **https://nftban.com/coding-standards.html**

### Bash

- **Required:** `set -Eeuo pipefail` at the top of every script
- Quote all variables: `"$var"`
- Use `[[` for conditionals
- Add comments for complex logic
- Follow existing naming conventions
- **Avoid:** `((counter++))` patterns in conditionals under `set -e` (arithmetic integrity rule)

### Go

- Run `go fmt` before committing
- Run `go vet` and fix warnings
- Run `staticcheck` and address issues
- Use meaningful variable names
- Add tests for new functionality

### Pre-commit Validation

Headers and coding standards are enforced via pre-commit hook:

```bash
# Install pre-commit framework (recommended)
pip install pre-commit
pre-commit install

# Or use the Makefile
make lint-headers
make lint
```

The hook validates:
- SPDX license identifier (exactly one, must be MPL-2.0)
- All meta: lines are quoted
- All inventory keys are present
- Bash scripts have `set -Eeuo pipefail`
- No free-text header lines (From:, Called by:, etc.)

### Commits

- Use conventional commits:
  - `feat:` New feature
  - `fix:` Bug fix
  - `docs:` Documentation
  - `refactor:` Code refactoring
  - `test:` Adding tests
  - `chore:` Maintenance

### Examples

```bash
# Good commit messages
feat(cli): Add IP search across all sets
fix(geoban): Handle empty country list gracefully
docs: Update installation guide for Rocky 9

# Bad commit messages
fixed stuff
update
wip
```

## Testing

### Running Tests

```bash
# Non-destructive smoke (safe for CI, routine checks)
nftban smoke

# Extended system validation (includes controlled state changes — ban/unban lifecycle, whitelist tests)
nftban selftest

# Full test suite
./tests/test_all_commands.sh

# ShellCheck (bash linting)
shellcheck cli/lib/nftban/**/*.sh

# Go tests
go test ./...
```

### Test Before PR

1. Smoke tests pass: `nftban smoke` (non-destructive, CI-safe)
2. ShellCheck passes (warnings OK)
3. Go builds without errors
4. No regressions in existing functionality

## Questions?

- Open a [discussion](https://github.com/itcmsgr/nftban/discussions)
- Check [documentation](docs/)
- Review [support guide](.github/SUPPORT.md)

## License

By contributing, you agree that your contributions will be licensed under the MPL-2.0 License.
