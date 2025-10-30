#!/usr/bin/env bash
# NFTBan v0.10.0 - Fail2ban Integration Deployment
# Deploys complete Fail2ban integration to all lab servers

set -Eeuo pipefail

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "NFTBan v0.10.0 - Fail2ban Integration Deployment"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_SERVERS=(
    "lab.example.test"
    "lab1.example.test"
    "lab2.example.test"
)

for server in "${LAB_SERVERS[@]}"; do
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "Deploying to: $server"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo ""

    echo "[1/7] Syncing runtime table..."
    rsync -avz --progress \
        "$SCRIPT_DIR/src/usr/lib/nftban/nft-runtime.nft" \
        root@$server:/usr/lib/nftban/
    echo ""

    echo "[2/7] Syncing complete CLI..."
    rsync -avz --progress \
        "$SCRIPT_DIR/src/usr/sbin/nftban-complete" \
        root@$server:/usr/sbin/
    ssh root@$server "chmod +x /usr/sbin/nftban-complete"
    echo ""

    echo "[3/7] Syncing Fail2ban templates..."
    ssh root@$server "mkdir -p /usr/share/nftban/templates/fail2ban"
    rsync -avz --progress \
        "$SCRIPT_DIR/src/usr/share/nftban/templates/fail2ban/" \
        root@$server:/usr/share/nftban/templates/fail2ban/
    echo ""

    echo "[4/7] Syncing logrotate config..."
    rsync -avz --progress \
        "$SCRIPT_DIR/deploy/logrotate.d/nftban" \
        root@$server:/etc/logrotate.d/
    echo ""

    echo "[5/7] Initializing runtime table..."
    ssh root@$server "
        set -e
        # Install runtime table
        nft -f /usr/lib/nftban/nft-runtime.nft

        # Verify
        echo '✓ Runtime table created:'
        nft list table inet nftban_runtime | head -10
    "
    echo ""

    echo "[6/7] Setting up Fail2ban integration..."
    ssh root@$server "
        set -e
        # Create directories
        mkdir -p /var/log/nftban /var/lib/nftban

        # Run Fail2ban setup
        /usr/sbin/nftban-complete fail2ban setup

        # Verify
        echo '✓ Fail2ban files created:'
        ls -l /etc/fail2ban/action.d/nftban.conf
        ls -l /etc/fail2ban/jail.d/nftban-sshd.conf
    "
    echo ""

    echo "[7/7] Testing manual ban..."
    ssh root@$server "
        set -e
        # Test ban with 30-second timeout
        /usr/sbin/nftban-complete ban 192.0.2.1 --temp --timeout 30 --source test --jail manual

        echo '✓ Test ban created (will auto-expire in 30s):'
        nft list set inet nftban_runtime temp_ban_v4 | grep -A5 'elements'

        echo ''
        echo '✓ Log entry:'
        tail -1 /var/log/nftban/fail2ban-bans.log
    "
    echo ""

    echo "✓✓✓ Deployed to $server successfully!"
    echo ""
done

echo "═══════════════════════════════════════════════════════════════════════════════"
echo "✅ DEPLOYMENT COMPLETE TO ALL SERVERS"
echo "═══════════════════════════════════════════════════════════════════════════════"
echo ""
echo "Next steps:"
echo "  1. Fail2ban SSHD jail is ACTIVE on all servers"
echo "  2. Test tomorrow: ssh wronguser@lab.example.test (fail 5 times)"
echo "  3. Check logs: ssh root@lab.example.test 'tail /var/log/nftban/fail2ban-bans.log'"
echo "  4. View stats: ssh root@lab.example.test '/usr/sbin/nftban-complete stats'"
echo ""
echo "Monitoring commands:"
echo "  - nftban-complete logs tail fail2ban-bans.log"
echo "  - nftban-complete stats top-ips"
echo "  - nftban-complete fail2ban status"
echo ""
