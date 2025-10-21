#!/usr/bin/env bash
# =============================================================================
# nftban Bootstrap - Checks dependencies and downloads installer
# =============================================================================

set -e

# Check if root
[[ $EUID -ne 0 ]] && { echo "ERROR: Run as root"; exit 1; }

# Detect OS
. /etc/os-release 2>/dev/null || { echo "ERROR: Cannot detect OS"; exit 1; }

# Check and install dependencies
MISSING=()
for cmd in curl tar gzip unzip; do
    command -v $cmd &>/dev/null || MISSING+=($cmd)
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "Missing: ${MISSING[*]}"
    read -p "Install automatically? [Y/n] " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$|^$ ]] && { echo "Cancelled"; exit 1; }

    case "$ID" in
        ubuntu|debian) apt-get update -qq; apt-get install -y "${MISSING[@]}" ;;
        centos|rhel|rocky|almalinux|fedora)
            command -v dnf &>/dev/null && dnf install -y "${MISSING[@]}" || yum install -y "${MISSING[@]}" ;;
        *) echo "ERROR: Unsupported OS"; exit 1 ;;
    esac
fi

# Download and extract
TEMP_DIR=$(mktemp -d)
echo "Downloading to: $TEMP_DIR"
cd "$TEMP_DIR"
curl -fsSL https://github.com/itcmsgr/nftban/archive/refs/heads/main.tar.gz | tar xz
cd nftban-main
echo "Current directory: $(pwd)"
echo "Files in lib/installer/:"
ls -la lib/installer/ 2>/dev/null || echo "ERROR: lib/installer/ not found!"

# Unattended install flag
[[ "$1" == "--unattended" ]] && UNATTENDED=1 || UNATTENDED=0

echo "Installing to: /etc/nftban"

# Copy files to /etc/nftban
if [[ ! -d /etc/nftban ]]; then
    mkdir -p /etc/nftban
fi

# Copy all files
cp -r bin lib config data scripts templates completions .version /etc/nftban/
cp CHANGELOG.md README.md LICENSE.md /etc/nftban/ 2>/dev/null || true

echo "Running installation script..."

# Run installer from /etc/nftban
if [[ -f /etc/nftban/lib/nftban_init_script.sh ]]; then
    bash /etc/nftban/lib/nftban_init_script.sh
else
    echo "ERROR: Installation script not found"
    exit 1
fi

# Cleanup
cd /
rm -rf "$TEMP_DIR"
