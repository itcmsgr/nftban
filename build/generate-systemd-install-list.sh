#!/usr/bin/env bash
# =============================================================================
# NFTBan - Systemd Install-List Generator (MFST-C1 / Layer 1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="generate-systemd-install-list"
# meta:type="build"
# meta:header="Systemd Install-List Generator"
# meta:version="1.106.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Generate canonical systemd unit install list consumed by RPM and DEB build paths"
# meta:inventory.files="install/systemd/*.{service,timer,socket}"
# meta:inventory.binaries="find,sort,diff,mktemp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="user"
#
# meta:created_date="2026-05-06"
# meta:updated_date="2026-05-06"
#
# Source of truth: install/systemd/*.{service,timer,socket}
# Output:          install/packaging/systemd/nftban-systemd-install.list
#
# Consumed at package-build time by both packagers
# (packaging/build_nftban.sh::build_rpm + ::build_deb) to ensure the RPM and
# DEB install layers ship the same systemd unit set as filesystem truth
# (D1 closure).
#
# Usage:
#   ./build/generate-systemd-install-list.sh           # regenerate
#   ./build/generate-systemd-install-list.sh --check   # CI parity check
#
# Options:
#   --check   Verify generated file matches committed version (for CI)
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

readonly SOURCE_DIR="${PROJECT_ROOT}/install/systemd"
readonly OUTPUT_FILE="${PROJECT_ROOT}/install/packaging/systemd/nftban-systemd-install.list"

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

print_info()    { echo -e "${YELLOW}[INFO]${NC} $*"; }
print_ok()      { echo -e "${GREEN}[OK]${NC} $*"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

generate() {
    local target="${1:-$OUTPUT_FILE}"

    if [[ ! -d "$SOURCE_DIR" ]]; then
        print_error "Source directory not found: $SOURCE_DIR"
        return 1
    fi

    mkdir -p "$(dirname "$target")"

    local units
    units=$(find "$SOURCE_DIR" -maxdepth 1 -type f \
        \( -name '*.service' -o -name '*.timer' -o -name '*.socket' \) \
        -printf '%f\n' | LC_ALL=C sort -u)

    if [[ -z "$units" ]]; then
        print_error "No systemd units found in $SOURCE_DIR"
        return 1
    fi

    local count
    count=$(printf '%s\n' "$units" | wc -l)

    {
        cat <<'EOF'
# =============================================================================
# NFTBan systemd unit install list
# =============================================================================
# Generated from install/systemd/*.{service,timer,socket} - DO NOT EDIT
# Generator: build/generate-systemd-install-list.sh
#
# Consumers:
#   - packaging/build_nftban.sh::build_rpm() spec heredoc %install loop
#   - packaging/build_nftban.sh::build_deb() install-loop
#
# Note: filesystem glob; all units in install/systemd are listed.
# Runtime-controlled enablement is owned by /usr/lib/nftban/bin/nftban-installer
# (PR-22B safety contract); file presence in /usr/lib/systemd/system/ does NOT
# imply enable. See V106_LANE_MFST_C1_SCOPE.md §7 for safety analysis.
# =============================================================================
EOF
        printf '%s\n' "$units"
    } > "$target"

    print_ok "Wrote $count units to $target"
}

check_mode() {
    print_info "Running in check mode - verifying generated file..."

    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf "${temp_dir:-}"' EXIT

    local temp_out="${temp_dir}/nftban-systemd-install.list"
    generate "$temp_out" >/dev/null

    if [[ ! -f "$OUTPUT_FILE" ]]; then
        print_error "Committed output missing: $OUTPUT_FILE"
        return 1
    fi

    if diff -q "$OUTPUT_FILE" "$temp_out" >/dev/null 2>&1; then
        print_ok "OK: nftban-systemd-install.list matches install/systemd source"
        return 0
    fi

    print_error "DRIFT: $OUTPUT_FILE is stale vs install/systemd"
    diff -u "$OUTPUT_FILE" "$temp_out" || true
    print_error "Run 'bash build/generate-systemd-install-list.sh' to regenerate"
    return 1
}

main() {
    case "${1:-}" in
        --check)
            check_mode
            return $?
            ;;
        ""|--write)
            generate
            return $?
            ;;
        -h|--help)
            sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
            return 0
            ;;
        *)
            print_error "Unknown option: $1"
            return 2
            ;;
    esac
}

main "$@"
