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

# Download and run installer
cd /tmp
curl -fsSL https://github.com/itcmsgr/nftban/archive/refs/heads/main.tar.gz | tar xz
cd nftban-main

# Unattended install flag
[[ "$1" == "--unattended" ]] && UNATTENDED=1 || UNATTENDED=0

if [[ $UNATTENDED -eq 1 ]]; then
    bash lib/installer/installer_main.sh install --unattended
else
    bash lib/installer/installer_main.sh install
fi
