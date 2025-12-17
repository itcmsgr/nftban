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
LDFLAGS="-s -w"

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


show_usage() {
    cat << EOF
NFTBan Build Script

Usage:
  $0 [component]

Components:
  all       Build all Go binaries (default)
  core      Build nftban-core only
  gui       Build nftban-ui only

Environment Variables:
  CGO_ENABLED   Enable/disable CGO (default: 1)
  GOOS          Target OS (default: linux)
  GOARCH        Target architecture (default: amd64)

Examples:
  $0              # Build everything
  $0 all          # Build everything
  $0 core         # Build core binary only
  $0 gui          # Build GUI only

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
