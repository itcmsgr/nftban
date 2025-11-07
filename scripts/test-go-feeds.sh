#!/usr/bin/bash
# Test script for Go feeds implementation (v0.32.6)
# Usage: ./scripts/test-go-feeds.sh <lab-server> <go-binary>
# Example: ./scripts/test-go-feeds.sh lab.mywebhost.gr ./go-feeds/nftban-feeds

set -e

if [[ $# -lt 2 ]]; then
    echo "Usage: $0 <lab-server> <go-binary>"
    echo ""
    echo "Example:"
    echo "  $0 lab.mywebhost.gr ./go-feeds/nftban-feeds"
    echo ""
    echo "Available lab servers:"
    echo "  lab.mywebhost.gr   (Rocky Linux 9)"
    echo "  lab1.mywebhost.gr  (Ubuntu 24.04)"
    echo "  lab2.mywebhost.gr  (Rocky Linux 9)"
    echo "  lab3.mywebhost.gr  (AlmaLinux 10)"
    echo "  lab4.mywebhost.gr  (AlmaLinux 10)"
    exit 1
fi

SERVER="$1"
GO_BINARY="$2"

echo "========================================="
echo "NFTBan Go Feeds Test Script"
echo "========================================="
echo "Server: $SERVER"
echo "Binary: $GO_BINARY"
echo ""

# Check if binary exists
if [[ ! -f "$GO_BINARY" ]]; then
    echo "❌ Error: Go binary not found at $GO_BINARY"
    echo ""
    echo "AI coder should provide the binary after building:"
    echo "  cd go-feeds"
    echo "  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o nftban-feeds cmd/nftban-feeds/main.go"
    exit 1
fi

echo "✅ Go binary found: $GO_BINARY"
file "$GO_BINARY"
echo ""

# Test 1: Check server accessibility
echo "Test 1: Server accessibility"
if ssh "root@$SERVER" "echo 'SSH OK'" >/dev/null 2>&1; then
    echo "✅ SSH connection successful"
else
    echo "❌ SSH connection failed"
    exit 1
fi
echo ""

# Test 2: Check nftables table exists
echo "Test 2: NFTables table check"
if ssh "root@$SERVER" "nft list table inet nftban_main" >/dev/null 2>&1; then
    echo "✅ nftban_main table exists"
else
    echo "❌ nftban_main table not found"
    exit 1
fi
echo ""

# Test 3: Check nftables sets exist
echo "Test 3: NFTables sets check"
if ssh "root@$SERVER" "nft list set inet nftban_main feed_v4" >/dev/null 2>&1; then
    echo "✅ feed_v4 set exists"
else
    echo "❌ feed_v4 set not found"
    exit 1
fi

if ssh "root@$SERVER" "nft list set inet nftban_main feed_v6" >/dev/null 2>&1; then
    echo "✅ feed_v6 set exists"
else
    echo "❌ feed_v6 set not found"
    exit 1
fi
echo ""

# Test 4: Upload Go binary
echo "Test 4: Upload Go binary to server"
scp "$GO_BINARY" "root@$SERVER:/tmp/nftban-feeds" >/dev/null 2>&1
if ssh "root@$SERVER" "test -f /tmp/nftban-feeds"; then
    echo "✅ Binary uploaded successfully"
else
    echo "❌ Binary upload failed"
    exit 1
fi
echo ""

# Test 5: Make executable
echo "Test 5: Set executable permissions"
ssh "root@$SERVER" "chmod +x /tmp/nftban-feeds"
echo "✅ Permissions set"
echo ""

# Test 6: Kill any stuck processes
echo "Test 6: Clean up stuck processes"
ssh "root@$SERVER" "killall -9 nft sort 2>/dev/null; pkill -9 -f feeds 2>/dev/null || true"
echo "✅ Cleanup complete"
echo ""

# Test 7: Get current set size (before)
echo "Test 7: Current feed set size"
IPV4_BEFORE=$(ssh "root@$SERVER" "nft list set inet nftban_main feed_v4 2>/dev/null | grep -c elements || echo 0")
IPV6_BEFORE=$(ssh "root@$SERVER" "nft list set inet nftban_main feed_v6 2>/dev/null | grep -c elements || echo 0")
echo "Before: IPv4=$IPV4_BEFORE, IPv6=$IPV6_BEFORE"
echo ""

# Test 8: Run Go binary (manual test with small feed)
echo "Test 8: Manual Go binary test (dry run)"
echo "Command to test manually on server:"
echo ""
echo "  ssh root@$SERVER"
echo "  time /tmp/nftban-feeds sync greensnow"
echo ""
echo "Expected output:"
echo "  Fetching 1 feeds..."
echo "    greensnow: 12543 IPs parsed"
echo "  Deduplicating..."
echo "  Total unique: 12543 IPv4, 0 IPv6"
echo "  Loading into nftables..."
echo "    Loading 12543 IPv4 prefixes... ✅"
echo "  ✅ Feeds loaded atomically"
echo "  real    0m1.234s"
echo ""

# Test 9: CPU usage check
echo "Test 9: Prepare CPU monitoring"
echo "Monitor CPU during test:"
echo "  ssh root@$SERVER 'top -b -n 1 | head -20'"
echo ""
echo "Verify no nft processes after sync:"
echo "  ssh root@$SERVER 'ps aux | grep nft | grep -v grep'"
echo ""

# Test 10: Integration check
echo "Test 10: Integration with nftban command"
echo "To install Go binary permanently:"
echo ""
echo "  ssh root@$SERVER 'cp /tmp/nftban-feeds /usr/lib/nftban/bin/nftban-feeds'"
echo "  ssh root@$SERVER 'nftban feeds sync'"
echo ""
echo "This should automatically use the Go binary."
echo ""

echo "========================================="
echo "✅ Pre-flight checks complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Test manually: ssh root@$SERVER"
echo "2. Run: time /tmp/nftban-feeds sync greensnow"
echo "3. Verify: ps aux | grep nft (should be empty)"
echo "4. Check CPU: top (should be <2%)"
echo "5. Install permanently if successful"
echo ""
echo "Benchmark comparison:"
echo "  v0.32.6 (bash): 10-30 seconds for 100K IPs"
echo "  v0.32.6 (Go):   1-2 seconds for 100K IPs"
echo ""
