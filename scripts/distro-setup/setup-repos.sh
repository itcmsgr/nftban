#!/usr/bin/env bash
# =============================================================================
# NFTBan Repository Setup - Auto-Detector
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Automatically detect distro and setup required repositories
# Usage: curl -sSL https://raw.githubusercontent.com/itcmsgr/nftban/main/scripts/distro-setup/setup-repos.sh | sudo bash
#
# What this does:
#   1. Detects your Linux distribution
#   2. Runs the appropriate distro-specific setup script
#   3. Verifies all prerequisites are met
#   4. Reports what was configured
# =============================================================================

set -Eeuo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}NFTBan Repository Setup - Auto Configuration${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""

# Check if root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}ERROR: This script must be run as root${NC}"
   echo "Usage: sudo $0"
   exit 1
fi

# Detect OS
if [ ! -f /etc/os-release ]; then
    echo -e "${RED}ERROR: Cannot detect OS (/etc/os-release not found)${NC}"
    exit 1
fi

source /etc/os-release

OS_ID="${ID}"
OS_VERSION_ID="${VERSION_ID%%.*}"
OS_NAME="${PRETTY_NAME}"

echo -e "Detected: ${GREEN}${OS_NAME}${NC}"
echo ""

# Determine which setup script to run
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${OS_ID}" in
    fedora)
        echo "✓ Fedora detected - No repository setup needed!"
        echo "  All packages available in default repositories."
        exit 0
        ;;

    centos)
        echo "Running CentOS-specific setup..."
        if [[ -f "${SCRIPT_DIR}/centos-${OS_VERSION_ID}.sh" ]]; then
            bash "${SCRIPT_DIR}/centos-${OS_VERSION_ID}.sh"
        else
            bash "${SCRIPT_DIR}/centos.sh"
        fi
        ;;

    rocky)
        echo "Running Rocky Linux-specific setup..."
        bash "${SCRIPT_DIR}/rocky.sh"
        ;;

    almalinux)
        echo "Running AlmaLinux-specific setup..."
        bash "${SCRIPT_DIR}/almalinux.sh"
        ;;

    ubuntu|debian)
        echo "✓ ${OS_NAME} detected - No repository setup needed!"
        echo "  All packages available in default repositories."
        exit 0
        ;;

    *)
        echo -e "${RED}ERROR: Unsupported distribution: ${OS_ID}${NC}"
        echo ""
        echo "NFTBan supports:"
        echo "  - Fedora 38+"
        echo "  - CentOS Stream 9+"
        echo "  - Rocky Linux 8/9"
        echo "  - AlmaLinux 8/9"
        echo "  - Ubuntu 22.04/24.04"
        echo "  - Debian 12+"
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}✓ Repository setup completed successfully${NC}"
echo ""
