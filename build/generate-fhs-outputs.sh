#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.39.0 - FHS Output Generator
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="generate-fhs-outputs"
# meta:type="build"
# meta:header="FHS Output Generator"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Generate all FHS-related packaging artifacts from canonical YAML spec"
# meta:inventory.files="build/fhs-spec.yaml"
# meta:inventory.binaries="yq,jq"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="user"
#
# meta:created_date="2026-01-10"
# meta:updated_date="2026-01-10"
#
# This script is deterministic - identical inputs produce identical outputs.
# Run in CI to validate generated files match committed versions.
#
# Outputs:
#   - install/systemd/tmpfiles.d/nftban.conf
#   - install/systemd/sysusers.d/nftban.conf
#   - install/packaging/deb/nftban.dirs
#   - install/packaging/rpm/nftban-files.inc
#   - cli/lib/nftban/data/fhs_directories.json
#   - cli/lib/nftban/core/nftban_fhs_spec.sh (generated helper)
#
# Usage:
#   ./build/generate-fhs-outputs.sh [--check]
#
# Options:
#   --check   Verify generated files match committed versions (for CI)
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# Script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source file
FHS_SPEC="${SCRIPT_DIR}/fhs-spec.yaml"

# Output paths
TMPFILES_OUT="${PROJECT_ROOT}/install/systemd/tmpfiles.d/nftban.conf"
SYSUSERS_OUT="${PROJECT_ROOT}/install/systemd/sysusers.d/nftban.conf"
DEB_DIRS_OUT="${PROJECT_ROOT}/install/packaging/deb/nftban.dirs"
DEB_ATTRS_OUT="${PROJECT_ROOT}/install/packaging/deb/nftban-dir-attrs.list"
RPM_FILES_OUT="${PROJECT_ROOT}/install/packaging/rpm/nftban-files.inc"
JSON_OUT="${PROJECT_ROOT}/cli/lib/nftban/data/fhs_directories.json"
SHELL_OUT="${PROJECT_ROOT}/cli/lib/nftban/core/nftban_fhs_spec.sh"
PERMS_OUT="${PROJECT_ROOT}/cli/lib/nftban/setup/fhs-permissions.sh"

# Read project version from /VERSION
NFTBAN_GEN_VERSION="$(cat "${PROJECT_ROOT}/VERSION" 2>/dev/null | tr -d '[:space:]')"
: "${NFTBAN_GEN_VERSION:=1.0.0}"

# Generated header
HEADER="Generated from build/fhs-spec.yaml - DO NOT EDIT"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() { echo -e "${GREEN}[OK]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
print_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }

# =============================================================================
# VALIDATION
# =============================================================================

check_dependencies() {
    local missing=()

    if ! command -v yq &>/dev/null; then
        missing+=("yq")
    fi

    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Missing dependencies: ${missing[*]}"
        echo "Install: pip3 install yq && apt install jq (or dnf install jq)"
        exit 1
    fi
}

validate_spec() {
    if [[ ! -f "$FHS_SPEC" ]]; then
        print_error "FHS spec not found: $FHS_SPEC"
        exit 1
    fi

    # Validate YAML syntax
    if ! yq -e '.' "$FHS_SPEC" >/dev/null 2>&1; then
        print_error "Invalid YAML syntax in $FHS_SPEC"
        exit 1
    fi
}

# =============================================================================
# GENERATORS
# =============================================================================

generate_tmpfiles() {
    print_info "Generating tmpfiles.d/nftban.conf..."

    mkdir -p "$(dirname "$TMPFILES_OUT")"

    # Write header (split SPDX to avoid validator detecting it as generator's own)
    {
        echo "# ============================================================================="
        echo "# NFTBan v1.0.0 - tmpfiles.d Configuration (GENERATED)"
        echo "# ============================================================================="
        echo "# SPDX-License-Identifier: MPL-2.0"
    } > "$TMPFILES_OUT"
    cat >> "$TMPFILES_OUT" << 'EOF'
#
# meta:name="nftban.tmpfiles"
# meta:type="systemd"
# meta:header="tmpfiles.d Configuration"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Runtime directory creation for NFTBan (GENERATED)"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2026-01-10"
# meta:updated_date="2026-01-10"
#
# Generated from build/fhs-spec.yaml - DO NOT EDIT
# Run manually: systemd-tmpfiles --create /usr/lib/tmpfiles.d/nftban.conf
# =============================================================================

EOF

    # Data directories (created_by: tmpfiles)
    echo "# Data directories (/var/lib/nftban)" >> "$TMPFILES_OUT"
    yq -r '.directories.data[] | select(.created_by == "tmpfiles") | "d \(.path) \(.mode) \(.owner) \(.group) -"' "$FHS_SPEC" >> "$TMPFILES_OUT"
    echo "" >> "$TMPFILES_OUT"

    # Log directories
    echo "# Log directories (/var/log/nftban)" >> "$TMPFILES_OUT"
    yq -r '.directories.logs[] | select(.created_by == "tmpfiles") | "d \(.path) \(.mode) \(.owner) \(.group) -"' "$FHS_SPEC" >> "$TMPFILES_OUT"
    echo "" >> "$TMPFILES_OUT"

    # Cache and runtime directories
    echo "# Cache and runtime directories" >> "$TMPFILES_OUT"
    yq -r '.directories.runtime[] | select(.created_by == "tmpfiles") | "d \(.path) \(.mode) \(.owner) \(.group) -"' "$FHS_SPEC" >> "$TMPFILES_OUT"

    print_status "Generated $TMPFILES_OUT"
}

generate_sysusers() {
    print_info "Generating sysusers.d/nftban.conf..."

    mkdir -p "$(dirname "$SYSUSERS_OUT")"

    # Write header (split SPDX to avoid validator detecting it as generator's own)
    {
        echo "# ============================================================================="
        echo "# NFTBan v1.0.0 - sysusers.d Configuration (GENERATED)"
        echo "# ============================================================================="
        echo "# SPDX-License-Identifier: MPL-2.0"
    } > "$SYSUSERS_OUT"
    cat >> "$SYSUSERS_OUT" << 'EOF'
#
# meta:name="nftban.sysusers"
# meta:type="systemd"
# meta:header="sysusers.d Configuration"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="System user/group creation for NFTBan (GENERATED)"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2026-01-10"
# meta:updated_date="2026-01-10"
#
# Generated from build/fhs-spec.yaml - DO NOT EDIT
# Run manually: systemd-sysusers /usr/lib/sysusers.d/nftban.conf
# =============================================================================

EOF

    # Groups
    echo "# Groups" >> "$SYSUSERS_OUT"
    yq -r '.sysusers.groups[] | "g \(.name) - \"\(.comment)\""' "$FHS_SPEC" >> "$SYSUSERS_OUT"
    echo "" >> "$SYSUSERS_OUT"

    # Users
    echo "# Users" >> "$SYSUSERS_OUT"
    yq -r '.sysusers.users[] | "u \(.name) - \"\(.comment)\" \(.home) \(.shell)"' "$FHS_SPEC" >> "$SYSUSERS_OUT"
    echo "" >> "$SYSUSERS_OUT"

    # Group memberships
    echo "# Group memberships" >> "$SYSUSERS_OUT"
    yq -r '.sysusers.users[] | select(.groups != null) | .groups[] as $grp | "m \(.name) \($grp)"' "$FHS_SPEC" >> "$SYSUSERS_OUT"

    print_status "Generated $SYSUSERS_OUT"
}

generate_deb_dirs() {
    print_info "Generating deb/nftban.dirs..."

    mkdir -p "$(dirname "$DEB_DIRS_OUT")"

    cat > "$DEB_DIRS_OUT" << 'EOF'
# =============================================================================
# NFTBan Debian package directories
# =============================================================================
# Generated from build/fhs-spec.yaml - DO NOT EDIT
#
# This file lists directories to create during package installation.
# Consumer: dh_installdirs
#
# Note: Directories marked created_by=package are listed here.
#       Directories marked created_by=tmpfiles are NOT listed here
#       (they are created by systemd-tmpfiles at runtime).
# =============================================================================

EOF

    # System directories
    yq -r '.directories.system[] | select(.created_by == "package") | .path' "$FHS_SPEC" >> "$DEB_DIRS_OUT"

    # Config directories
    yq -r '.directories.config[] | select(.created_by == "package") | .path' "$FHS_SPEC" >> "$DEB_DIRS_OUT"

    # Data directories (package-territory only; tmpfiles-managed are runtime-created).
    # PKG-EFFECTIVE-PARITY precondition fix: closes Layer-3 gap where data-tier
    # dirs declared `created_by:package` (e.g. /var/lib/nftban/community) were
    # in paths.go::RequiredDirs but missing from package payload.
    yq -r '.directories.data[] | select(.created_by == "package") | .path' "$FHS_SPEC" >> "$DEB_DIRS_OUT"

    # PKG-EFFECTIVE-PARITY Slot 5a: explicit parent emission. /var/lib/nftban
    # is `created_by:tmpfiles` in fhs-spec.yaml (runtime authority via
    # tmpfiles.d), but DEB build's `mkdir -p /var/lib/nftban/community`
    # incidentally creates the parent in the staged tree, and the L3 cross-
    # packager parity gate sees it diverge from RPM (which doesn't ship it).
    # Make /var/lib/nftban explicit in package payload to keep the L3 diff
    # symmetric. The runtime authority remains tmpfiles + postinst chown
    # (DEB ships root:root, postinst converges to root:nftban).
    echo "/var/lib/nftban" >> "$DEB_DIRS_OUT"

    # Shared directories
    yq -r '.directories.shared[] | select(.created_by == "package") | .path' "$FHS_SPEC" >> "$DEB_DIRS_OUT"

    print_status "Generated $DEB_DIRS_OUT"
}

# =============================================================================
# DEB DIR ATTRIBUTES (D-NEW-12 fix; AUTH-HARDENING)
# =============================================================================
# Emits ownership/mode metadata for package-territory directories so the DEB
# build (build_deb() in packaging/build_nftban.sh) can record correct owner/
# group/mode in the dpkg DB — bringing DEB to RPM %attr parity for /etc/nftban.
#
# Format (deterministic, easy to parse):
#   path|mode|owner|group
# RPM uses %attr() inside nftban-files.inc for the same purpose; DEB needs
# this externalised list because dpkg-deb has no equivalent in-tree directive.
#
# Scope: ONLY config-tier directories (/etc/nftban + subdirs). System dirs
# (/usr/lib/nftban, /usr/share/nftban) are correctly root:root 0755 by
# default and need no override. Tmpfiles-managed dirs are runtime-created
# and not in the package payload.
generate_deb_dir_attrs() {
    print_info "Generating deb/nftban-dir-attrs.list..."

    mkdir -p "$(dirname "$DEB_ATTRS_OUT")"

    cat > "$DEB_ATTRS_OUT" << 'EOF'
# =============================================================================
# NFTBan Debian package directory attributes (ownership + mode)
# =============================================================================
# Generated from build/fhs-spec.yaml - DO NOT EDIT
#
# Consumer: packaging/build_nftban.sh build_deb() — applies chown/chmod
# inside ${deb_root} before dpkg-deb --build so dpkg DB records correct
# ownership/mode. Brings DEB to RPM %attr parity (closes D-NEW-12).
#
# Format: path|mode|owner|group
# =============================================================================

EOF

    yq -r '.directories.config[] | select(.created_by == "package") | "\(.path)|\(.mode)|\(.owner)|\(.group)"' \
        "$FHS_SPEC" >> "$DEB_ATTRS_OUT"

    # Data directories (package-territory only). PKG-EFFECTIVE-PARITY precondition
    # fix: dirs like /var/lib/nftban/community declared `created_by:package` need
    # ownership/mode metadata recorded in dpkg DB so dpkg-verify is clean and
    # dpkg --reinstall does not reset to root:root.
    yq -r '.directories.data[] | select(.created_by == "package") | "\(.path)|\(.mode)|\(.owner)|\(.group)"' \
        "$FHS_SPEC" >> "$DEB_ATTRS_OUT"

    # PKG-EFFECTIVE-PARITY Slot 5a: explicit parent emission for /var/lib/nftban.
    # See generate_deb_dirs() for rationale. Emit using the metadata from
    # fhs-spec.yaml (which still says created_by:tmpfiles — that is the runtime
    # authority — but the package archive layer also needs to ship it so cross-
    # packager L3 parity is symmetric). The chmod loop in build_deb() reads
    # this attrs.list and applies mode 0750 to /var/lib/nftban at build time;
    # ownership is left as root:root in the archive (postinst converges to
    # root:nftban via the same attrs.list).
    yq -r '.directories.data[] | select(.path == "/var/lib/nftban") | "\(.path)|\(.mode)|\(.owner)|\(.group)"' \
        "$FHS_SPEC" >> "$DEB_ATTRS_OUT"

    print_status "Generated $DEB_ATTRS_OUT"
}

generate_rpm_files() {
    print_info "Generating rpm/nftban-files.inc..."

    mkdir -p "$(dirname "$RPM_FILES_OUT")"

    cat > "$RPM_FILES_OUT" << 'EOF'
# =============================================================================
# NFTBan RPM %files include
# =============================================================================
# Generated from build/fhs-spec.yaml - DO NOT EDIT
#
# Include in nftban.spec: %include nftban-files.inc
#
# Note: This file contains %dir entries with proper %attr() for directories
#       that are created by the package. Directories marked created_by=tmpfiles
#       are NOT listed here (they are created by systemd-tmpfiles at runtime).
# =============================================================================

# ---------------------------------------------------------------------------
# SYSTEM DIRECTORIES (root:root)
# ---------------------------------------------------------------------------
EOF

    yq -r '.directories.system[] | select(.created_by == "package") | "%dir %attr(\(.mode),\(.owner),\(.group)) \(.path)"' "$FHS_SPEC" >> "$RPM_FILES_OUT"

    echo "" >> "$RPM_FILES_OUT"
    echo "# ---------------------------------------------------------------------------" >> "$RPM_FILES_OUT"
    echo "# CONFIGURATION DIRECTORIES (root:nftban)" >> "$RPM_FILES_OUT"
    echo "# ---------------------------------------------------------------------------" >> "$RPM_FILES_OUT"

    yq -r '.directories.config[] | select(.created_by == "package") | "%dir %attr(\(.mode),\(.owner),\(.group)) \(.path)"' "$FHS_SPEC" >> "$RPM_FILES_OUT"

    echo "" >> "$RPM_FILES_OUT"
    echo "# ---------------------------------------------------------------------------" >> "$RPM_FILES_OUT"
    echo "# DATA DIRECTORIES (package-territory only; tmpfiles-managed runtime dirs excluded)" >> "$RPM_FILES_OUT"
    echo "# ---------------------------------------------------------------------------" >> "$RPM_FILES_OUT"

    # PKG-EFFECTIVE-PARITY precondition fix: closes Layer-3 gap where data-tier
    # dirs declared `created_by:package` (e.g. /var/lib/nftban/community) were
    # in paths.go::RequiredDirs but missing from RPM %files payload.
    yq -r '.directories.data[] | select(.created_by == "package") | "%dir %attr(\(.mode),\(.owner),\(.group)) \(.path)"' "$FHS_SPEC" >> "$RPM_FILES_OUT"

    # PKG-EFFECTIVE-PARITY Slot 5a: explicit parent emission for /var/lib/nftban.
    # See generate_deb_dirs() for rationale. RPM uses %attr() which is name-
    # based and re-applied at install time, so RPM ships /var/lib/nftban at
    # 0750 root:nftban (matching fhs-spec.yaml + tmpfiles.d). Cross-packager
    # L3 parity is preserved via test-package-deb-l3-exceptions.list which
    # filters /var/lib/nftban from both sides (DEB ships postinst-converged
    # root:root in archive; RPM ships root:nftban directly).
    yq -r '.directories.data[] | select(.path == "/var/lib/nftban") | "%dir %attr(\(.mode),\(.owner),\(.group)) \(.path)"' "$FHS_SPEC" >> "$RPM_FILES_OUT"

    echo "" >> "$RPM_FILES_OUT"
    echo "# ---------------------------------------------------------------------------" >> "$RPM_FILES_OUT"
    echo "# SHARED DATA DIRECTORIES (root:root)" >> "$RPM_FILES_OUT"
    echo "# ---------------------------------------------------------------------------" >> "$RPM_FILES_OUT"

    yq -r '.directories.shared[] | select(.created_by == "package") | "%dir %attr(\(.mode),\(.owner),\(.group)) \(.path)"' "$FHS_SPEC" >> "$RPM_FILES_OUT"

    print_status "Generated $RPM_FILES_OUT"
}

generate_json() {
    print_info "Generating fhs_directories.json..."

    mkdir -p "$(dirname "$JSON_OUT")"

    # Build JSON structure for receipt consumption
    cat > "$JSON_OUT" << 'EOF'
{
  "_comment": "Generated from build/fhs-spec.yaml - DO NOT EDIT",
  "_version": "1.0.0",
EOF

    # Add directories grouped by category
    echo '  "directories": {' >> "$JSON_OUT"

    # System directories
    echo '    "system": [' >> "$JSON_OUT"
    yq -r '.directories.system[] | "      {\"path\": \"\(.path)\", \"mode\": \"\(.mode)\", \"owner\": \"\(.owner)\", \"group\": \"\(.group)\", \"description\": \"\(.description)\", \"created_by\": \"\(.created_by)\"},"' "$FHS_SPEC" | sed '$ s/,$//' >> "$JSON_OUT"
    echo '    ],' >> "$JSON_OUT"

    # Config directories
    echo '    "config": [' >> "$JSON_OUT"
    yq -r '.directories.config[] | "      {\"path\": \"\(.path)\", \"mode\": \"\(.mode)\", \"owner\": \"\(.owner)\", \"group\": \"\(.group)\", \"description\": \"\(.description)\", \"created_by\": \"\(.created_by)\"},"' "$FHS_SPEC" | sed '$ s/,$//' >> "$JSON_OUT"
    echo '    ],' >> "$JSON_OUT"

    # Data directories
    echo '    "data": [' >> "$JSON_OUT"
    yq -r '.directories.data[] | "      {\"path\": \"\(.path)\", \"mode\": \"\(.mode)\", \"owner\": \"\(.owner)\", \"group\": \"\(.group)\", \"description\": \"\(.description)\", \"created_by\": \"\(.created_by)\"},"' "$FHS_SPEC" | sed '$ s/,$//' >> "$JSON_OUT"
    echo '    ],' >> "$JSON_OUT"

    # Log directories
    echo '    "logs": [' >> "$JSON_OUT"
    yq -r '.directories.logs[] | "      {\"path\": \"\(.path)\", \"mode\": \"\(.mode)\", \"owner\": \"\(.owner)\", \"group\": \"\(.group)\", \"description\": \"\(.description)\", \"created_by\": \"\(.created_by)\"},"' "$FHS_SPEC" | sed '$ s/,$//' >> "$JSON_OUT"
    echo '    ],' >> "$JSON_OUT"

    # Runtime directories
    echo '    "runtime": [' >> "$JSON_OUT"
    yq -r '.directories.runtime[] | "      {\"path\": \"\(.path)\", \"mode\": \"\(.mode)\", \"owner\": \"\(.owner)\", \"group\": \"\(.group)\", \"description\": \"\(.description)\", \"created_by\": \"\(.created_by)\"},"' "$FHS_SPEC" | sed '$ s/,$//' >> "$JSON_OUT"
    echo '    ],' >> "$JSON_OUT"

    # Shared directories
    echo '    "shared": [' >> "$JSON_OUT"
    yq -r '.directories.shared[] | "      {\"path\": \"\(.path)\", \"mode\": \"\(.mode)\", \"owner\": \"\(.owner)\", \"group\": \"\(.group)\", \"description\": \"\(.description)\", \"created_by\": \"\(.created_by)\"},"' "$FHS_SPEC" | sed '$ s/,$//' >> "$JSON_OUT"
    echo '    ]' >> "$JSON_OUT"

    echo '  },' >> "$JSON_OUT"

    # Add binaries section
    echo '  "binaries": {' >> "$JSON_OUT"
    echo '    "cli": "/usr/sbin/nftban",' >> "$JSON_OUT"
    echo '    "go_binaries_dir": "/usr/lib/nftban/bin"' >> "$JSON_OUT"
    echo '  },' >> "$JSON_OUT"

    # Add sysusers info
    echo '  "sysusers": {' >> "$JSON_OUT"
    echo '    "user": "nftban",' >> "$JSON_OUT"
    echo '    "group": "nftban",' >> "$JSON_OUT"
    echo '    "auditor_group": "nftban-auditor"' >> "$JSON_OUT"
    echo '  }' >> "$JSON_OUT"

    echo '}' >> "$JSON_OUT"

    # Validate JSON
    if ! jq -e '.' "$JSON_OUT" >/dev/null 2>&1; then
        print_error "Generated invalid JSON"
        exit 1
    fi

    # Pretty print JSON
    jq '.' "$JSON_OUT" > "${JSON_OUT}.tmp" && mv "${JSON_OUT}.tmp" "$JSON_OUT"

    print_status "Generated $JSON_OUT"
}

generate_shell_helper() {
    print_info "Generating nftban_fhs_spec.sh..."

    mkdir -p "$(dirname "$SHELL_OUT")"

    # Write header (split SPDX to avoid validator detecting it as generator's own)
    {
        echo "#!/usr/bin/env bash"
        echo "# ============================================================================="
        echo "# NFTBan v${NFTBAN_GEN_VERSION} - FHS Specification (GENERATED)"
        echo "# ============================================================================="
        echo "# SPDX-License-Identifier: MPL-2.0"
        echo "#"
        echo "# meta:name=\"nftban_fhs_spec\""
        echo "# meta:type=\"core\""
        echo "# meta:header=\"FHS Specification\""
        echo "# meta:version=\"${NFTBAN_GEN_VERSION}\""
    } > "$SHELL_OUT"
    cat >> "$SHELL_OUT" << 'SHELL_HEADER'
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Single source of truth for FHS directory specifications (GENERATED)"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="user"
#
# meta:created_date="2026-01-10"
# meta:updated_date="2026-01-10"
#
# WARNING: This file is GENERATED from build/fhs-spec.yaml - DO NOT EDIT
# Run: build/generate-fhs-outputs.sh
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_FHS_SPEC_LOADED:-}" ]] && return 0
readonly NFTBAN_FHS_SPEC_LOADED=1

# =============================================================================
# CANONICAL FHS SPECIFICATION
# =============================================================================

declare -g -A NFTBAN_FHS_DIRECTORIES=()

nftban_fhs_load_spec() {
    # Load canonical FHS directory specification
    # Format: NFTBAN_FHS_DIRECTORIES[path]="perms|owner|group|purpose"

SHELL_HEADER

    # Generate system directories
    echo "    # System Directories (root:root)" >> "$SHELL_OUT"
    yq -r '.directories.system[] | "    NFTBAN_FHS_DIRECTORIES[\"\(.path)\"]=\"\(.mode)|\(.owner)|\(.group)|\(.description)\""' "$FHS_SPEC" >> "$SHELL_OUT"
    echo "" >> "$SHELL_OUT"

    # Generate config directories
    echo "    # Configuration Directories (root:nftban)" >> "$SHELL_OUT"
    yq -r '.directories.config[] | "    NFTBAN_FHS_DIRECTORIES[\"\(.path)\"]=\"\(.mode)|\(.owner)|\(.group)|\(.description)\""' "$FHS_SPEC" >> "$SHELL_OUT"
    echo "" >> "$SHELL_OUT"

    # Generate data directories
    echo "    # Data Directories" >> "$SHELL_OUT"
    yq -r '.directories.data[] | "    NFTBAN_FHS_DIRECTORIES[\"\(.path)\"]=\"\(.mode)|\(.owner)|\(.group)|\(.description)\""' "$FHS_SPEC" >> "$SHELL_OUT"
    echo "" >> "$SHELL_OUT"

    # Generate log directories
    echo "    # Log Directories" >> "$SHELL_OUT"
    yq -r '.directories.logs[] | "    NFTBAN_FHS_DIRECTORIES[\"\(.path)\"]=\"\(.mode)|\(.owner)|\(.group)|\(.description)\""' "$FHS_SPEC" >> "$SHELL_OUT"
    echo "" >> "$SHELL_OUT"

    # Generate runtime directories
    echo "    # Runtime Directories" >> "$SHELL_OUT"
    yq -r '.directories.runtime[] | "    NFTBAN_FHS_DIRECTORIES[\"\(.path)\"]=\"\(.mode)|\(.owner)|\(.group)|\(.description)\""' "$FHS_SPEC" >> "$SHELL_OUT"
    echo "" >> "$SHELL_OUT"

    # Generate shared directories
    echo "    # Shared Directories" >> "$SHELL_OUT"
    yq -r '.directories.shared[] | "    NFTBAN_FHS_DIRECTORIES[\"\(.path)\"]=\"\(.mode)|\(.owner)|\(.group)|\(.description)\""' "$FHS_SPEC" >> "$SHELL_OUT"

    cat >> "$SHELL_OUT" << 'SHELL_FOOTER'
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

nftban_fhs_get_spec() {
    # Get FHS specification for a path
    # Args: $1 = path
    # Output: perms|owner|group|purpose (or empty if not found)

    local path="$1"

    # Load spec if not already loaded
    if [[ ${#NFTBAN_FHS_DIRECTORIES[@]} -eq 0 ]]; then
        nftban_fhs_load_spec
    fi

    echo "${NFTBAN_FHS_DIRECTORIES[$path]:-}"
}

nftban_fhs_get_all_paths() {
    # Get all defined FHS paths
    # Output: one path per line

    # Load spec if not already loaded
    if [[ ${#NFTBAN_FHS_DIRECTORIES[@]} -eq 0 ]]; then
        nftban_fhs_load_spec
    fi

    printf '%s\n' "${!NFTBAN_FHS_DIRECTORIES[@]}" | sort
}

nftban_fhs_parse_spec() {
    # Parse FHS spec into components
    # Args: $1 = spec string (perms|owner|group|purpose)
    # Output: Sets variables FHS_PERMS, FHS_OWNER, FHS_GROUP, FHS_PURPOSE

    local spec="$1"
    IFS='|' read -r FHS_PERMS FHS_OWNER FHS_GROUP FHS_PURPOSE <<< "$spec"
    export FHS_PERMS FHS_OWNER FHS_GROUP FHS_PURPOSE
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Auto-load spec on source
nftban_fhs_load_spec

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_fhs_load_spec
export -f nftban_fhs_get_spec
export -f nftban_fhs_get_all_paths
export -f nftban_fhs_parse_spec
SHELL_FOOTER

    chmod +x "$SHELL_OUT"
    print_status "Generated $SHELL_OUT"
}

# =============================================================================
# CHECK MODE (for CI)
# =============================================================================

check_mode() {
    print_info "Running in check mode - verifying generated files..."

    local failed=0
    local temp_dir
    temp_dir=$(mktemp -d)

    # Save current outputs
    local orig_tmpfiles="$TMPFILES_OUT"
    local orig_sysusers="$SYSUSERS_OUT"
    local orig_deb="$DEB_DIRS_OUT"
    local orig_deb_attrs="$DEB_ATTRS_OUT"
    local orig_rpm="$RPM_FILES_OUT"
    local orig_json="$JSON_OUT"
    local orig_shell="$SHELL_OUT"

    # Redirect to temp
    TMPFILES_OUT="${temp_dir}/tmpfiles.conf"
    SYSUSERS_OUT="${temp_dir}/sysusers.conf"
    DEB_DIRS_OUT="${temp_dir}/nftban.dirs"
    DEB_ATTRS_OUT="${temp_dir}/nftban-dir-attrs.list"
    RPM_FILES_OUT="${temp_dir}/nftban-files.inc"
    JSON_OUT="${temp_dir}/fhs_directories.json"
    SHELL_OUT="${temp_dir}/nftban_fhs_spec.sh"

    # Generate
    generate_tmpfiles
    generate_sysusers
    generate_deb_dirs
    generate_deb_dir_attrs
    generate_rpm_files
    generate_json
    generate_shell_helper

    # Compare
    for pair in \
        "${temp_dir}/tmpfiles.conf:${orig_tmpfiles}" \
        "${temp_dir}/sysusers.conf:${orig_sysusers}" \
        "${temp_dir}/nftban.dirs:${orig_deb}" \
        "${temp_dir}/nftban-dir-attrs.list:${orig_deb_attrs}" \
        "${temp_dir}/nftban-files.inc:${orig_rpm}" \
        "${temp_dir}/fhs_directories.json:${orig_json}" \
        "${temp_dir}/nftban_fhs_spec.sh:${orig_shell}"; do

        IFS=':' read -r generated committed <<< "$pair"

        if [[ ! -f "$committed" ]]; then
            print_error "Missing committed file: $committed"
            failed=1
            continue
        fi

        if ! diff -q "$generated" "$committed" >/dev/null 2>&1; then
            print_error "Mismatch: $committed"
            echo "Run: build/generate-fhs-outputs.sh"
            diff -u "$committed" "$generated" || true
            failed=1
        else
            print_status "OK: $(basename "$committed")"
        fi
    done

    rm -rf "$temp_dir"

    if [[ $failed -eq 1 ]]; then
        print_error "Generated files do not match committed versions"
        echo "Run: build/generate-fhs-outputs.sh"
        exit 1
    fi

    print_status "All generated files are up to date"
}

generate_file_permissions() {
    print_info "Generating fhs-permissions.sh..."

    mkdir -p "$(dirname "$PERMS_OUT")"

    # Write header (split SPDX to avoid validator detecting it as generator's own)
    {
        echo "#!/usr/bin/env bash"
        echo "# ============================================================================="
        echo "# NFTBan v1.0.0 - FHS File Permissions (GENERATED)"
        echo "# ============================================================================="
        echo "# SPDX-License-Identifier: MPL-2.0"
    } > "$PERMS_OUT"
    cat >> "$PERMS_OUT" << 'PERMS_HEADER'
#
# meta:name="fhs-permissions"
# meta:type="setup"
# meta:header="FHS File Permissions"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Sets file permissions during package installation (GENERATED)"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2026-02-08"
# meta:updated_date="2026-02-08"
#
# WARNING: This file is GENERATED from build/fhs-spec.yaml - DO NOT EDIT
# Run: build/generate-fhs-outputs.sh
# =============================================================================

set -Eeuo pipefail

nftban_install_set_file_permissions() {
    # File permissions from FHS spec (single source of truth)

PERMS_HEADER

    # Generate permission commands from file_permissions section
    yq -r '.file_permissions[] |
        "    # \(.path) - \(.pattern // "*")\n" +
        (if .recursive == true then
            "    find \"\(.path)\" -type f -name \"\(.pattern // "*")\"" +
            (if .exclude then " -not -path \"\(.exclude)/*\"" else "" end) +
            " -exec chown \(.owner):\(.group) {} \\; 2>/dev/null || true\n" +
            "    find \"\(.path)\" -type f -name \"\(.pattern // "*")\"" +
            (if .exclude then " -not -path \"\(.exclude)/*\"" else "" end) +
            " -exec chmod \(.mode) {} \\; 2>/dev/null || true"
        else
            "    chown \(.owner):\(.group) \"\(.path)\"/\(.pattern // "*") 2>/dev/null || true\n" +
            "    chmod \(.mode) \"\(.path)\"/\(.pattern // "*") 2>/dev/null || true"
        end) +
        (if .capabilities then
            "\n    # Set capabilities: \(.capabilities)\n" +
            "    if command -v setcap &>/dev/null; then\n" +
            ((.capabilities | split(":")[1] | split(",")[]) as $bin |
                "        setcap \"\(.capabilities | split(":")[0])\" \"\(.path)/\($bin)\" 2>/dev/null || true\n") +
            "    fi"
        else "" end)
    ' "$FHS_SPEC" >> "$PERMS_OUT"

    cat >> "$PERMS_OUT" << 'PERMS_FOOTER'

    return 0
}

# Export for sourcing
export -f nftban_install_set_file_permissions
PERMS_FOOTER

    chmod 755 "$PERMS_OUT"
    print_status "Generated $PERMS_OUT"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    echo "=========================================="
    echo "NFTBan FHS Output Generator"
    echo "=========================================="
    echo ""

    check_dependencies
    validate_spec

    if [[ "${1:-}" == "--check" ]]; then
        check_mode
        exit 0
    fi

    # Generate all outputs
    generate_tmpfiles
    generate_sysusers
    generate_deb_dirs
    generate_deb_dir_attrs
    generate_rpm_files
    generate_json
    generate_shell_helper
    generate_file_permissions

    echo ""
    echo "=========================================="
    print_status "All FHS outputs generated successfully"
    echo "=========================================="
    echo ""
    echo "Generated files:"
    echo "  - $TMPFILES_OUT"
    echo "  - $SYSUSERS_OUT"
    echo "  - $DEB_DIRS_OUT"
    echo "  - $DEB_ATTRS_OUT"
    echo "  - $RPM_FILES_OUT"
    echo "  - $JSON_OUT"
    echo "  - $SHELL_OUT"
    echo "  - $PERMS_OUT"
    echo ""
    echo "Next steps:"
    echo "  1. Review generated files"
    echo "  2. Update postinst/spec to use sysusers/tmpfiles"
    echo "  3. Commit all generated files"
    echo ""
}

main "$@"
