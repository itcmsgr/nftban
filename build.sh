#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.9.3 - Consolidated Build Script
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="build"
# meta:type="script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-10-26"
# meta:description="Build all NFTBan Go binaries in one place"
# meta:input="component (all, core, daemon, installer, validator)"
# meta:output="Compiled Go binaries in bin/"
# meta:depends="go"
# meta:inventory.files=""
# meta:inventory.binaries="nftban-core, nftband, nftban-installer, nftban-validate"
# meta:inventory.env_vars="CGO_ENABLED, GOOS, GOARCH"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Usage: ./build.sh [component]
#        component: all (default) or specific binary name (core, daemon, installer, validator)
# =============================================================================

set -Eeuo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log()   { echo -e "${BLUE}[BUILD]${NC} $*"; }
ok()    { echo -e "${GREEN}[  OK ]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN ]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Build directories
BIN_DIR="$SCRIPT_DIR/bin"
mkdir -p "$BIN_DIR"

# =============================================================================
# BUILD PREREQUISITES CHECK
# =============================================================================

check_prerequisites() {
    local missing=0

    # Check Go version (need 1.21+)
    if ! command -v go &>/dev/null; then
        error "Go is not installed"
        echo "  Install: https://go.dev/dl/ (need Go 1.21+)"
        missing=1
    else
        local go_version
        go_version=$(go version | grep -oP 'go\K[0-9]+\.[0-9]+' | head -1)
        local major minor
        major=$(echo "$go_version" | cut -d. -f1)
        minor=$(echo "$go_version" | cut -d. -f2)
        if [[ "$major" -lt 1 ]] || [[ "$major" -eq 1 && "$minor" -lt 21 ]]; then
            error "Go version $go_version is too old (need 1.21+)"
            echo "  Update: https://go.dev/dl/"
            missing=1
        else
            ok "Go $go_version"
        fi
    fi

    # Check C compiler (needed for CGO)
    if ! command -v gcc &>/dev/null; then
        error "GCC is not installed (needed for CGO)"
        echo "  Install (Debian/Ubuntu): apt install build-essential"
        echo "  Install (RHEL/Fedora):   dnf install gcc"
        missing=1
    else
        ok "GCC $(gcc --version | head -1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    fi

    # PAM headers check removed in v1.100.1b.A — nftban-ui-auth is no
    # longer built or shipped (GOTH PR-D4 stage 1).

    if [[ $missing -eq 1 ]]; then
        echo ""
        error "Missing build prerequisites. Install them and try again."
        exit 1
    fi
}

log "Checking build prerequisites..."
check_prerequisites
echo ""

# Build configuration
CGO_ENABLED=1
GOOS=linux
GOARCH=amd64

# Read version from VERSION file (single source of truth)
VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "dev")

# v1.100.4 H1.1 — inject GitCommit + BuildDate so binaries report
# chain-of-custody (--version output ties back to a specific source
# commit + build wall-clock). Both fall back to the pkg/version
# defaults ("dev" / "unknown") when run outside a git checkout, so
# release tooling can detect uninjected builds.
# Source identity via the provenance precedence (SOURCE_COMMIT file | git HEAD),
# full 40-char sha, FAIL-CLOSED — never silently embed "dev". An exported source
# bundle without .git must carry a SOURCE_COMMIT file written at archive time.
# shellcheck source=packaging/lib/provenance.sh
source "$SCRIPT_DIR/packaging/lib/provenance.sh"
if ! prov_resolve_source_identity "$SCRIPT_DIR"; then
    error "Cannot resolve source identity: not a git checkout and no SOURCE_COMMIT file."
    error "For an offline/exported source bundle, write bin/../SOURCE_COMMIT (full 40-hex) at archive time."
    exit 1
fi
GIT_COMMIT="$PROV_SOURCE_COMMIT"
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

LDFLAGS="-s -w \
  -X github.com/itcmsgr/nftban/pkg/version.Version=$VERSION \
  -X github.com/itcmsgr/nftban/pkg/version.GitCommit=$GIT_COMMIT \
  -X github.com/itcmsgr/nftban/pkg/version.BuildDate=$BUILD_DATE"

# Component to build (default: all)
COMPONENT="${1:-all}"

# =============================================================================
# PRE-BUILD FIXES
# =============================================================================

# Fix go.work if it exists (causes module resolution issues)
if [[ -f "$SCRIPT_DIR/go.work" ]]; then
    warn "Removing go.work (causes module resolution issues)"
    rm -f "$SCRIPT_DIR/go.work"
fi

# Ensure go.mod dependencies are up to date
fix_dependencies() {
    local module_dir="$1"
    # Offline builds must not attempt a network module resolve. build_nftban.sh
    # sets NFTBAN_SKIP_MOD_TIDY=1 (with GOPROXY=off) for --offline; also skip when
    # the caller has pinned GOPROXY=off directly.
    if [[ "${NFTBAN_SKIP_MOD_TIDY:-0}" == "1" || "${GOPROXY:-}" == "off" ]]; then
        warn "Skipping 'go mod tidy' (offline / GOPROXY=off)"
        return 0
    fi
    if [[ -f "$module_dir/go.mod" ]]; then
        log "Updating dependencies in $module_dir..."
        (cd "$module_dir" && go mod tidy -v 2>/dev/null) || true
    fi
}

# Fix dependencies for all Go modules
log "Checking Go module dependencies..."
fix_dependencies "$SCRIPT_DIR/cmd/nftban-core"
# nftban-ui + nftban-ui-auth dep checks removed in v1.100.1b.A
# (GOTH PR-D4 stage 1 — no longer built or shipped).
ok "Dependencies checked"
echo ""

# =============================================================================
# BUILD FUNCTIONS
# =============================================================================

build_core() {
    log "Building nftban-core (Core binary with GeoIP, feeds, etc.)..."

    cd "$SCRIPT_DIR/cmd/nftban-core"

    CGO_ENABLED=$CGO_ENABLED GOOS=$GOOS GOARCH=$GOARCH \
        go build -trimpath -o "$BIN_DIR/nftban-core" \
        -ldflags="$LDFLAGS" \
        . || {
        error "Failed to build nftban-core"
        return 1
    }

    chmod +x "$BIN_DIR/nftban-core"
    ok "Built: $BIN_DIR/nftban-core"

    cd "$SCRIPT_DIR"
    return 0
}


# build_gui / build_ui_auth / generate_templ removed in v1.100.1b.A
# (GOTH PR-D4 stage 1 — nftban-ui + nftban-ui-auth no longer built or
# shipped). Source trees under cmd/nftban-ui/, cmd/nftban-ui-auth/,
# internal/ui/ remain in repo and will be removed in a later
# stabilization release (1.100.1b.B).

build_daemon() {
    log "Building nftband (IPC daemon for nft operations)..."

    cd "$SCRIPT_DIR/cmd/nftband"

    CGO_ENABLED=$CGO_ENABLED GOOS=$GOOS GOARCH=$GOARCH \
        go build -trimpath -o "$BIN_DIR/nftband" \
        -ldflags="$LDFLAGS" \
        . || {
        error "Failed to build nftband"
        return 1
    }

    chmod +x "$BIN_DIR/nftband"
    ok "Built: $BIN_DIR/nftband"

    cd "$SCRIPT_DIR"
    return 0
}

build_installer() {
    log "Building nftban-installer (RPM install finalizer)..."

    cd "$SCRIPT_DIR"

    # Installer is pure Go — no CGO needed
    CGO_ENABLED=0 GOOS=$GOOS GOARCH=$GOARCH \
        go build -trimpath -o "$BIN_DIR/nftban-installer" \
        -ldflags="$LDFLAGS" \
        ./cmd/nftban-installer || {
        error "Failed to build nftban-installer"
        return 1
    }

    chmod +x "$BIN_DIR/nftban-installer"
    ok "Built: $BIN_DIR/nftban-installer"

    cd "$SCRIPT_DIR"
    return 0
}

build_validator() {
    log "Building nftban-validate (Kernel validator for CLI)..."

    cd "$SCRIPT_DIR"

    # Validator is pure Go — no CGO needed
    CGO_ENABLED=0 GOOS=$GOOS GOARCH=$GOARCH \
        go build -trimpath -o "$BIN_DIR/nftban-validate" \
        -ldflags="$LDFLAGS" \
        ./cmd/nftban-validate || {
        error "Failed to build nftban-validate"
        return 1
    }

    chmod +x "$BIN_DIR/nftban-validate"
    ok "Built: $BIN_DIR/nftban-validate"

    # v1.145 PR-B: SSH-port union detector — pure Go, zero-side-effect, shared
    # by installer + runtime shell paths via ssh_port_detect.sh.
    CGO_ENABLED=0 GOOS=$GOOS GOARCH=$GOARCH \
        go build -trimpath -o "$BIN_DIR/nftban-detect-ssh-ports" \
        -ldflags="$LDFLAGS" \
        ./cmd/nftban-detect-ssh-ports || {
        error "Failed to build nftban-detect-ssh-ports"
        return 1
    }
    chmod +x "$BIN_DIR/nftban-detect-ssh-ports"
    ok "Built: $BIN_DIR/nftban-detect-ssh-ports"

    # v1.209.1: BotScan candidate prefilter helper — pure Go, bounded Aho-Corasick + RE2,
    # replaces the fragile `grep -E -f` prefilter that GNU grep rejects wholesale on the
    # |-delimiter-mis-split patterns. Shell-invoked (one process per scan file).
    CGO_ENABLED=0 GOOS=$GOOS GOARCH=$GOARCH \
        go build -trimpath -o "$BIN_DIR/nftban-botscan-matcher" \
        -ldflags="$LDFLAGS" \
        ./cmd/nftban-botscan-matcher || {
        error "Failed to build nftban-botscan-matcher"
        return 1
    }
    chmod +x "$BIN_DIR/nftban-botscan-matcher"
    ok "Built: $BIN_DIR/nftban-botscan-matcher"

    cd "$SCRIPT_DIR"
    return 0
}

show_usage() {
    cat << EOF
NFTBan Build Script

Usage:
  $0 [component]

Components:
  all       Build all Go binaries (default)
  core      Build nftban-core only
  daemon    Build nftband only
  installer Build nftban-installer only
  validator Build nftban-validate only

  (gui + ui-auth removed in v1.100.1b.A — GOTH PR-D4 stage 1)

Environment Variables:
  CGO_ENABLED   Enable/disable CGO (default: 1)
  GOOS          Target OS (default: linux)
  GOARCH        Target architecture (default: amd64)

Examples:
  $0              # Build everything
  $0 all          # Build everything
  $0 core         # Build core binary only
  $0 daemon       # Build IPC daemon only

Output:
  All binaries are placed in: $BIN_DIR/
EOF
}

# =============================================================================
# MAIN BUILD LOGIC
# =============================================================================

log "NFTBan Build System"
log "==================="
log "Target: $GOOS/$GOARCH (CGO: $CGO_ENABLED)"
log "Output: $BIN_DIR/"
echo ""

case "$COMPONENT" in
    all)
        log "Building all components..."
        echo ""

        build_core || exit 1
        echo ""

        # build_gui + build_ui_auth removed in v1.100.1b.A.

        build_daemon || exit 1
        echo ""

        build_installer || exit 1
        echo ""

        build_validator || exit 1
        echo ""

        # Provenance: prove all 6 embed the resolved source commit, then emit the
        # build manifest (consumed by verified-prebuilt packaging + CI provenance).
        prov_verify_source_build "$SCRIPT_DIR" "$BIN_DIR" || {
            error "Source-build provenance verification failed"
            exit 1
        }
        prov_write_manifest "$SCRIPT_DIR" "$BIN_DIR" "$BIN_DIR/build-manifest.json" || {
            error "Failed to write build manifest"
            exit 1
        }

        log "Build Summary:"
        ls -lh "$BIN_DIR"/ 2>/dev/null || true
        echo ""
        ok "All components built successfully! (manifest: bin/build-manifest.json @ ${GIT_COMMIT})"
        ;;

    core)
        build_core || exit 1
        ;;

    gui|ui-auth)
        error "nftban-ui and nftban-ui-auth are no longer built or shipped (v1.100.1b.A — GOTH PR-D4 stage 1)."
        exit 1
        ;;

    daemon)
        build_daemon || exit 1
        ;;

    installer)
        build_installer || exit 1
        ;;

    validator)
        build_validator || exit 1
        ;;

    help|-h|--help)
        show_usage
        exit 0
        ;;

    *)
        error "Unknown component: $COMPONENT"
        echo ""
        show_usage
        exit 1
        ;;
esac

echo ""
ok "Build complete!"
echo ""
echo "Next steps:"
echo "  - Install locally: sudo ./install.sh all"
echo "  - Deploy to remote: ./deploy.sh [target]"
echo "  - Test core binary: ./bin/nftban-core --version"
echo "  - View install options: ./install.sh --help"
