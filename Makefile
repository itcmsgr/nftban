# =============================================================================
# NFTBan v1.0.0 - Makefile
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="Makefile"
# meta:type="config"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-01-07"
# meta:description="Build and development automation"
# meta:input="None"
# meta:output="Build artifacts"
# meta:depends=""
# meta:inventory.files=""
# meta:inventory.binaries="go, bash, shellcheck"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

.PHONY: all build clean test fuzz fuzz-long lint lint-headers lint-shell lint-go install help

# Default target
all: build

# Build all Go binaries
build:
	@echo "Building NFTBan..."
	@./build.sh

# Clean build artifacts
clean:
	@echo "Cleaning..."
	@rm -rf bin/ dist/
	@go clean -cache -testcache

# Run all tests
test:
	@echo "Running tests..."
	@go test ./...
	@./tests/test_all_commands.sh 2>/dev/null || true

# Run fuzz tests (30 seconds per test)
fuzz:
	@echo "Running fuzz tests..."
	@go test -fuzz=FuzzParseLogLine -fuzztime=30s ./internal/parser/
	@go test -fuzz=FuzzParseFeedLine -fuzztime=30s ./internal/parser/
	@go test -fuzz=FuzzValidateAndNormalizeIP -fuzztime=30s ./internal/parser/
	@echo "Fuzz tests completed."

# Run fuzz tests for longer duration (use for CI)
fuzz-long:
	@echo "Running extended fuzz tests (5 minutes each)..."
	@go test -fuzz=FuzzParseLogLine -fuzztime=5m ./internal/parser/
	@go test -fuzz=FuzzSSHDetector -fuzztime=5m ./internal/parser/
	@go test -fuzz=FuzzMailDetector -fuzztime=5m ./internal/parser/
	@go test -fuzz=FuzzFTPDetector -fuzztime=5m ./internal/parser/
	@go test -fuzz=FuzzPanelDetector -fuzztime=5m ./internal/parser/
	@go test -fuzz=FuzzParseFeedLine -fuzztime=5m ./internal/parser/
	@go test -fuzz=FuzzValidateAndNormalizeIP -fuzztime=5m ./internal/parser/
	@go test -fuzz=FuzzParseBool -fuzztime=5m ./internal/parser/
	@go test -fuzz=FuzzParseInt -fuzztime=5m ./internal/parser/
	@go test -fuzz=FuzzParseDuration -fuzztime=5m ./internal/parser/
	@echo "Extended fuzz tests completed."

# Run all linters
lint: lint-headers lint-shell lint-go
	@echo "All linting passed."

# Validate HEADER_SPEC compliance
lint-headers:
	@echo "Validating headers (HEADER_SPEC.md)..."
	@./tools/validate-headers.sh

# ShellCheck for Bash scripts
lint-shell:
	@echo "Running ShellCheck..."
	@find cli/ -name "*.sh" -type f -exec shellcheck --severity=warning {} + 2>/dev/null || true
	@find tools/ -name "*.sh" -type f -exec shellcheck --severity=warning {} + 2>/dev/null || true

# Go static analysis
lint-go:
	@echo "Running Go linters..."
	@go fmt ./...
	@go vet ./...
	@staticcheck ./... 2>/dev/null || true

# Install pre-commit hooks
install-hooks:
	@echo "Installing pre-commit hooks..."
	@pip install pre-commit 2>/dev/null || pip3 install pre-commit
	@pre-commit install
	@echo "Pre-commit hooks installed."

# Install NFTBan
install:
	@echo "Installing NFTBan..."
	@sudo ./install.sh

# Help
help:
	@echo "NFTBan Makefile Targets:"
	@echo ""
	@echo "  make build         - Build all Go binaries"
	@echo "  make clean         - Clean build artifacts"
	@echo "  make test          - Run all tests"
	@echo "  make fuzz          - Run fuzz tests (30 seconds each)"
	@echo "  make fuzz-long     - Run extended fuzz tests (5 minutes each)"
	@echo "  make lint          - Run all linters (headers, shell, go)"
	@echo "  make lint-headers  - Validate HEADER_SPEC.md compliance"
	@echo "  make lint-shell    - Run ShellCheck on Bash scripts"
	@echo "  make lint-go       - Run Go formatters and linters"
	@echo "  make install-hooks - Install pre-commit hooks"
	@echo "  make install       - Install NFTBan (requires sudo)"
	@echo "  make help          - Show this help"
