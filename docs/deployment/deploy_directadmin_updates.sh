#!/bin/bash
# NFTBan v0.10.0 - DirectAdmin Module Update Deployment
# Date: 2025-10-29
#
# This script deploys the updated DirectAdmin module to all servers
# Run this when server connectivity is restored

set -e

echo "═══════════════════════════════════════════════════════════════════"
echo "NFTBan DirectAdmin Module Update - Deployment"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

# Source files
SRC_DIR="/home/gituser/nftban-v0.10.0-dev/src"
PORT_CMD="$SRC_DIR/usr/lib/nftban/cli/cmd_port.sh"
DA_CONF="$SRC_DIR/etc/nftban/conf.d/directadmin.conf"

# Target servers
SERVERS="server1.example.com server2.example.com server3.example.com"

# Check source files exist
if [[ ! -f "$PORT_CMD" ]]; then
    echo "ERROR: Source file not found: $PORT_CMD"
    exit 1
fi

if [[ ! -f "$DA_CONF" ]]; then
    echo "ERROR: Source file not found: $DA_CONF"
    exit 1
fi

echo "Source files:"
echo "  ✓ $PORT_CMD"
echo "  ✓ $DA_CONF"
echo ""

# Deploy to each server
for server in $SERVERS; do
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Deploying to: $server"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Test connectivity
    if ! timeout 10 ssh root@$server "echo 'Connection OK'" 2>/dev/null; then
        echo "⚠️  Cannot connect to $server (timeout)"
        echo "   Skipping..."
        echo ""
        continue
    fi

    # Deploy cmd_port.sh
    echo "→ Deploying cmd_port.sh..."
    if scp "$PORT_CMD" root@$server:/usr/lib/nftban/cli/ 2>&1 | grep -v "Permanently added"; then
        echo "  ✓ cmd_port.sh deployed"
    else
        echo "  ✗ Failed to deploy cmd_port.sh"
        continue
    fi

    # Deploy directadmin.conf
    echo "→ Deploying directadmin.conf..."
    if scp "$DA_CONF" root@$server:/etc/nftban/conf.d/ 2>&1 | grep -v "Permanently added"; then
        echo "  ✓ directadmin.conf deployed"
    else
        echo "  ✗ Failed to deploy directadmin.conf"
        continue
    fi

    # Set permissions
    echo "→ Setting permissions..."
    if ssh root@$server "chmod +x /usr/lib/nftban/cli/cmd_port.sh"; then
        echo "  ✓ Permissions set"
    else
        echo "  ✗ Failed to set permissions"
        continue
    fi

    # Verify deployment
    echo "→ Verifying deployment..."
    ssh root@$server "ls -lh /usr/lib/nftban/cli/cmd_port.sh /etc/nftban/conf.d/directadmin.conf" | while read line; do
        echo "  $line"
    done

    echo ""
    echo "✅ $server deployment complete"
    echo ""
done

echo "═══════════════════════════════════════════════════════════════════"
echo "Deployment Summary"
echo "═══════════════════════════════════════════════════════════════════"
echo ""
echo "Files deployed:"
echo "  • /usr/lib/nftban/cli/cmd_port.sh (updated)"
echo "  • /etc/nftban/conf.d/directadmin.conf (updated)"
echo ""
echo "Changes:"
echo "  ✓ Updated port configuration (DirectAdmin official CSF policy)"
echo "  ✓ Added passive FTP range (35000:35999)"
echo "  ✓ Added DNS over TLS (853)"
echo "  ✓ Added HTTP/3 QUIC support (80, 443 UDP)"
echo "  ✓ Added CloudFlare integration"
echo "  ✓ Added user warnings and prompts"
echo ""
echo "Next steps:"
echo "  1. Test on one server:"
echo "     ssh root@SERVER"
echo "     nftban port allow-panel directadmin"
echo ""
echo "  2. Verify CloudFlare prompt appears"
echo "  3. Check ports are configured correctly"
echo "  4. Test DirectAdmin licensing"
echo ""
echo "Documentation:"
echo "  /tmp/DIRECTADMIN_UPDATE_SUMMARY.md"
echo ""
echo "═══════════════════════════════════════════════════════════════════"
