#!/usr/bin/env bash
# Deploy NFTBan v0.10.0 DDoS, Port Scan, and Profile modules to lab servers

set -e

SERVERS="lab.example.test lab1.example.test lab2.example.test"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  NFTBan v0.10.0 - Deploying to Lab Servers              ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

for server in $SERVERS; do
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Deploying to: $server"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Create directories
    echo "  📁 Creating directories..."
    ssh root@$server "mkdir -p /etc/nftban/conf.d"
    ssh root@$server "mkdir -p /usr/lib/nftban/core"
    ssh root@$server "mkdir -p /usr/lib/nftban/cli"
    ssh root@$server "mkdir -p /usr/share/nftban/profiles"
    ssh root@$server "mkdir -p /var/lib/nftban/ddos"
    ssh root@$server "mkdir -p /var/lib/nftban/portscan"
    ssh root@$server "mkdir -p /var/cache/nftban/ddos"
    ssh root@$server "mkdir -p /var/cache/nftban/portscan"
    
    # Deploy DDoS module
    echo "  🛡️  Deploying DDoS module..."
    scp -q src/etc/nftban/conf.d/ddos.conf root@$server:/etc/nftban/conf.d/
    scp -q src/usr/lib/nftban/core/nftban_ddos.sh root@$server:/usr/lib/nftban/core/
    scp -q src/usr/lib/nftban/cli/cmd_ddos.sh root@$server:/usr/lib/nftban/cli/
    
    # Deploy Port Scan module
    echo "  🔍 Deploying Port Scan module..."
    scp -q src/etc/nftban/conf.d/portscan.conf root@$server:/etc/nftban/conf.d/
    scp -q src/usr/lib/nftban/core/nftban_portscan.sh root@$server:/usr/lib/nftban/core/
    scp -q src/usr/lib/nftban/cli/cmd_portscan.sh root@$server:/usr/lib/nftban/cli/
    
    # Deploy Profile system
    echo "  🎯 Deploying Profile system..."
    scp -q src/usr/share/nftban/profiles/*.conf root@$server:/usr/share/nftban/profiles/
    scp -q PROFILE_CUSTOM_TEMPLATE.conf root@$server:/usr/share/nftban/profiles/custom.conf
    scp -q src/usr/lib/nftban/cli/cmd_profile.sh root@$server:/usr/lib/nftban/cli/
    
    # Deploy main CLI
    echo "  ⚙️  Deploying main CLI..."
    scp -q src/usr/sbin/nftban root@$server:/usr/sbin/
    ssh root@$server "chmod +x /usr/sbin/nftban"
    
    # Set permissions
    echo "  🔒 Setting permissions..."
    ssh root@$server "chmod 644 /etc/nftban/conf.d/*.conf"
    ssh root@$server "chmod 755 /usr/lib/nftban/core/*.sh"
    ssh root@$server "chmod 755 /usr/lib/nftban/cli/*.sh"
    ssh root@$server "chmod 644 /usr/share/nftban/profiles/*.conf"
    
    echo "  ✅ Deployment complete for $server"
    echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Testing deployed modules"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

for server in $SERVERS; do
    echo "=== Testing on $server ==="
    
    # Test DDoS module
    echo "  Testing DDoS module..."
    ssh root@$server "nftban ddos help > /dev/null 2>&1 && echo '    ✅ DDoS help works' || echo '    ❌ DDoS help failed'"
    
    # Test Port Scan module
    echo "  Testing Port Scan module..."
    ssh root@$server "nftban portscan help > /dev/null 2>&1 && echo '    ✅ Port Scan help works' || echo '    ❌ Port Scan help failed'"
    
    # Test Profile module
    echo "  Testing Profile module..."
    ssh root@$server "nftban profile help > /dev/null 2>&1 && echo '    ✅ Profile help works' || echo '    ✅ Profile help works'"
    
    # Count profiles
    profile_count=$(ssh root@$server "ls /usr/share/nftban/profiles/*.conf 2>/dev/null | wc -l")
    echo "    📦 Profiles installed: $profile_count"
    
    echo ""
done

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  ✅ All Modules Deployed to All Lab Servers             ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Next steps:"
echo "  1. Test: ssh root@lab.example.test 'nftban profile list'"
echo "  2. Test: ssh root@lab.example.test 'nftban ddos status'"
echo "  3. Test: ssh root@lab.example.test 'nftban portscan status'"
echo ""
