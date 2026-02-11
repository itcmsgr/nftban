#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Man Page Update Script
# =============================================================================
# meta:name="update_man_page"
# meta:type="script"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Updates man page version, date, and adds new commands"
# meta:inventory.files="install/man/man8/nftban.8"
# meta:inventory.binaries="groff,man,gzip,mandb"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
# Usage:
#   ./update_man_page.sh version <version>     - Update version number
#   ./update_man_page.sh preview               - Preview man page
#   ./update_man_page.sh install               - Install man page
#   ./update_man_page.sh check                 - Check for syntax errors
#   ./update_man_page.sh add <command>         - Generate section for new command
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MAN_SOURCE="$PROJECT_DIR/install/man/man8/nftban.8"
MAN_DEST="/usr/share/man/man8/nftban.8"

ACTION="${1:-help}"

case "$ACTION" in
    version)
        VERSION="${2:-}"
        if [[ -z "$VERSION" ]]; then
            echo "Usage: $0 version <version>"
            echo "Example: $0 version 1.0.1"
            exit 1
        fi

        DATE=$(date "+%B %Y")

        # Update .TH line
        sed -i "s/^\.TH NFTBAN 8 \".*\" \"NFTBan .*\" \"System Administration\"/.TH NFTBAN 8 \"$DATE\" \"NFTBan $VERSION\" \"System Administration\"/" "$MAN_SOURCE"

        echo "Updated man page to version $VERSION"
        grep "^\.TH" "$MAN_SOURCE"
        ;;

    preview)
        if [[ ! -f "$MAN_SOURCE" ]]; then
            echo "ERROR: Man page not found: $MAN_SOURCE" >&2
            exit 1
        fi

        man -l "$MAN_SOURCE"
        ;;

    check)
        if [[ ! -f "$MAN_SOURCE" ]]; then
            echo "ERROR: Man page not found: $MAN_SOURCE" >&2
            exit 1
        fi

        echo "Checking man page syntax..."
        if groff -man -Tascii "$MAN_SOURCE" > /dev/null 2>&1; then
            echo "✓ Man page syntax is valid"
        else
            echo "✗ Man page has errors:"
            groff -man -Tascii "$MAN_SOURCE" 2>&1 | head -20
            exit 1
        fi
        ;;

    install)
        if [[ $EUID -ne 0 ]]; then
            echo "ERROR: Must run as root to install man page" >&2
            exit 1
        fi

        if [[ ! -f "$MAN_SOURCE" ]]; then
            echo "ERROR: Man page not found: $MAN_SOURCE" >&2
            exit 1
        fi

        # Check syntax first
        if ! groff -man -Tascii "$MAN_SOURCE" > /dev/null 2>&1; then
            echo "ERROR: Man page has syntax errors" >&2
            exit 1
        fi

        # Install
        cp "$MAN_SOURCE" "$MAN_DEST"
        gzip -f "$MAN_DEST"
        mandb -q

        echo "✓ Man page installed: $MAN_DEST.gz"
        echo "  Test with: man nftban"
        ;;

    add)
        CMD_NAME="${2:-}"
        if [[ -z "$CMD_NAME" ]]; then
            echo "Usage: $0 add <command-name>"
            echo "Example: $0 add update"
            exit 1
        fi

        CLI_FILE="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/cli/cmd_${CMD_NAME//-/_}.sh"

        # Fallback for dev
        if [[ ! -f "$CLI_FILE" ]]; then
            CLI_FILE="$PROJECT_DIR/cli/lib/nftban/cli/cmd_${CMD_NAME//-/_}.sh"
        fi

        if [[ ! -f "$CLI_FILE" ]]; then
            echo "WARNING: CLI file not found: $CLI_FILE"
            echo "Generating generic template..."
        fi

        # Generate man section
        echo ""
        echo "# Add this to install/man/man8/nftban.8 under appropriate section:"
        echo ""
        echo ".TP"
        echo ".B $CMD_NAME \\fR[\\fIsubcommand\\fR]"

        if [[ -f "$CLI_FILE" ]]; then
            desc=$(grep -oP 'meta:description=\K.*' "$CLI_FILE" 2>/dev/null | head -1 || echo "Description needed")
            echo "$desc"
        else
            echo "Description needed."
        fi

        echo "Subcommands: enable, disable, status."
        echo ""
        ;;

    help|*)
        cat <<'EOF'
NFTBan Man Page Update Script

Usage:
  ./update_man_page.sh <action> [args]

Actions:
  version <ver>   Update version number (e.g., 1.0.1)
  preview         Preview man page in terminal
  check           Check for syntax errors
  install         Install man page to /usr/share/man/man8/
  add <cmd>       Generate man section for new command
  help            Show this help

Examples:
  ./update_man_page.sh version 1.0.1
  ./update_man_page.sh preview
  ./update_man_page.sh check
  sudo ./update_man_page.sh install
  ./update_man_page.sh add update

Files:
  Source: install/man/man8/nftban.8
  Dest:   /usr/share/man/man8/nftban.8.gz
EOF
        ;;
esac
