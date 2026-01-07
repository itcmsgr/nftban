#!/usr/bin/env bash
# =============================================================================
# NFTBan Build Script - Consolidated Build System
# =============================================================================
# Purpose: Build all NFTBan Go binaries in one place
# Usage: ./build.sh [component]
#        component: all (default), gui, auth, or specific binary name
# =============================================================================

set -euo pipefail

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

# Build configuration
CGO_ENABLED=1
GOOS=linux
GOARCH=amd64

# Read version from VERSION file (single source of truth)
VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "dev")
LDFLAGS="-s -w -X github.com/itcmsgr/nftban/pkg/version.Version=$VERSION"

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
    if [[ -f "$module_dir/go.mod" ]]; then
        log "Updating dependencies in $module_dir..."
        (cd "$module_dir" && go mod tidy -v 2>/dev/null) || true
    fi
}

# Fix dependencies for all Go modules
log "Checking Go module dependencies..."
fix_dependencies "$SCRIPT_DIR/cmd/nftban-core"
fix_dependencies "$SCRIPT_DIR/cmd/nftban-ui"
fix_dependencies "$SCRIPT_DIR/cmd/nftban-ui-auth"
ok "Dependencies checked"
echo ""

# =============================================================================
# BUILD FUNCTIONS
# =============================================================================

build_core() {
    log "Building nftban-core (Core binary with GeoIP, feeds, etc.)..."

    cd "$SCRIPT_DIR/cmd/nftban-core"

    CGO_ENABLED=$CGO_ENABLED GOOS=$GOOS GOARCH=$GOARCH \
        go build -o "$BIN_DIR/nftban-core" \
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


build_gui() {
    log "Building nftban-ui (Web GUI)..."

    cd "$SCRIPT_DIR/cmd/nftban-ui"

    CGO_ENABLED=$CGO_ENABLED GOOS=$GOOS GOARCH=$GOARCH \
        go build -o "$BIN_DIR/nftban-ui" \
        -ldflags="$LDFLAGS" \
        . || {
        error "Failed to build nftban-ui"
        return 1
    }

    chmod +x "$BIN_DIR/nftban-ui"
    ok "Built: $BIN_DIR/nftban-ui"

    cd "$SCRIPT_DIR"
    return 0
}


build_ui_auth() {
    log "Building nftban-ui-auth (PAM authentication daemon)..."

    cd "$SCRIPT_DIR/cmd/nftban-ui-auth"

    CGO_ENABLED=1 GOOS=$GOOS GOARCH=$GOARCH \
        go build -o "$BIN_DIR/nftban-ui-auth" \
        -ldflags="$LDFLAGS" \
        . || {
        error "Failed to build nftban-ui-auth"
        return 1
    }

    chmod +x "$BIN_DIR/nftban-ui-auth"
    ok "Built: $BIN_DIR/nftban-ui-auth"

    cd "$SCRIPT_DIR"
    return 0
}

build_daemon() {
    log "Building nftband (IPC daemon for nft operations)..."

    cd "$SCRIPT_DIR/cmd/nftband"

    CGO_ENABLED=$CGO_ENABLED GOOS=$GOOS GOARCH=$GOARCH \
        go build -o "$BIN_DIR/nftband" \
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

build_api() {
    log "Building nftban-api (API server)..."

    cd "$SCRIPT_DIR/cmd/nftban-api"

    CGO_ENABLED=$CGO_ENABLED GOOS=$GOOS GOARCH=$GOARCH \
        go build -o "$BIN_DIR/nftban-api" \
        -ldflags="$LDFLAGS" \
        . || {
        error "Failed to build nftban-api"
        return 1
    }

    chmod +x "$BIN_DIR/nftban-api"
    ok "Built: $BIN_DIR/nftban-api"

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
  gui       Build nftban-ui only
  ui-auth   Build nftban-ui-auth only
  daemon    Build nftband only
  api       Build nftban-api only

Environment Variables:
  CGO_ENABLED   Enable/disable CGO (default: 1)
  GOOS          Target OS (default: linux)
  GOARCH        Target architecture (default: amd64)

Examples:
  $0              # Build everything
  $0 all          # Build everything
  $0 core         # Build core binary only
  $0 gui          # Build GUI only
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

        build_gui || exit 1
        echo ""

        build_ui_auth || exit 1
        echo ""

        build_daemon || exit 1
        echo ""

        build_api || exit 1
        echo ""

        log "Build Summary:"
        ls -lh "$BIN_DIR"/ 2>/dev/null || true
        echo ""
        ok "All components built successfully!"
        ;;

    core)
        build_core || exit 1
        ;;

    gui)
        build_gui || exit 1
        ;;

    ui-auth)
        build_ui_auth || exit 1
        ;;

    daemon)
        build_daemon || exit 1
        ;;

    api)
        build_api || exit 1
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
