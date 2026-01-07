# Contributing to NFTBan

Thank you for your interest in contributing to NFTBAN! This document provides guidelines for contributing.

## About the Project

**NFTBAN** is an enterprise-grade firewall management engine built on Linux nftables. The name stands for **NFTables BAN actions**, emphasizing the system's foundation on native nftables technology for high-performance, kernel-level packet filtering.

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
4. Run tests: `nftban smoke`
5. Commit with clear messages
6. Push and create a PR

## Development Setup

### Prerequisites

- Go 1.22+
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
│   ├── nftban-api-server/ # REST API
│   └── nftban-ui/         # Web interface
├── pkg/                    # Go packages
├── install/               # Installation scripts
├── packaging/             # RPM/DEB specs
└── docs/                  # Documentation
```

## Mandatory Standards

All contributions **must** comply with these authoritative standards:

### 1. HEADER_SPEC.md (File Headers)

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

See [HEADER_SPEC.md](HEADER_SPEC.md) for complete specification.

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
# Quick smoke test
nftban smoke

# Full test suite
./tests/test_all_commands.sh

# ShellCheck (bash linting)
shellcheck cli/lib/nftban/**/*.sh

# Go tests
go test ./...
```

### Test Before PR

1. All commands work: `nftban smoke`
2. ShellCheck passes (warnings OK)
3. Go builds without errors
4. No regressions in existing functionality

## Questions?

- Open a [discussion](https://github.com/itcmsgr/nftban/discussions)
- Check [documentation](docs/)
- Review [support guide](.github/SUPPORT.md)

## License

By contributing, you agree that your contributions will be licensed under the MPL-2.0 License.
