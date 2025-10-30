#!/usr/bin/env bash
# NFTBan Permission Fix Script
# Implements standard Linux daemon logging pattern
# Run as root

set -euo pipefail

echo "════════════════════════════════════════════════════════════"
echo "  NFTBan Permission Fix - Standard Linux Daemon Pattern"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "Pattern: nftban user writes, nftban group reads, secure"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root" 
   exit 1
fi

# Check if nftban user exists
if ! id -u nftban >/dev/null 2>&1; then
    echo "ERROR: nftban user does not exist"
    echo "Please create it first: useradd -r -s /usr/sbin/nologin nftban"
    exit 1
fi

# Check if nftban group exists
if ! getent group nftban >/dev/null 2>&1; then
    echo "ERROR: nftban group does not exist"
    echo "Please create it first: groupadd -r nftban"
    exit 1
fi

echo "✓ nftban user: $(id nftban)"
echo "✓ nftban group exists"
echo ""

# =============================================================================
# FIX LOG DIRECTORY PERMISSIONS
# =============================================================================

echo "Fixing /var/log/nftban/ permissions..."

if [[ -d /var/log/nftban ]]; then
    # Main log directory: nftban user writes, nftban group reads
    chown nftban:nftban /var/log/nftban
    chmod 750 /var/log/nftban
    echo "  ✓ /var/log/nftban/ → 750 nftban:nftban"
    
    # All subdirectories
    find /var/log/nftban/ -type d -exec chown nftban:nftban {} \;
    find /var/log/nftban/ -type d -exec chmod 750 {} \;
    echo "  ✓ Subdirectories → 750 nftban:nftban"
    
    # All log files: nftban writes, group reads
    find /var/log/nftban/ -type f -name "*.log" -exec chown nftban:nftban {} \;
    find /var/log/nftban/ -type f -name "*.log" -exec chmod 640 {} \;
    echo "  ✓ Log files (*.log) → 640 nftban:nftban"
    
    # All other files
    find /var/log/nftban/ -type f ! -name "*.log" -exec chown nftban:nftban {} \;
    find /var/log/nftban/ -type f ! -name "*.log" -exec chmod 640 {} \;
    echo "  ✓ Other files → 640 nftban:nftban"
else
    echo "  ⚠ /var/log/nftban/ does not exist (will be created by installer)"
fi

echo ""

# =============================================================================
# FIX CONFIG DIRECTORY PERMISSIONS
# =============================================================================

echo "Fixing /etc/nftban/ permissions..."

if [[ -d /etc/nftban ]]; then
    # Config directory: root writes, nftban group reads
    chown root:nftban /etc/nftban
    chmod 750 /etc/nftban
    echo "  ✓ /etc/nftban/ → 750 root:nftban"
    
    # Config subdirectories
    if [[ -d /etc/nftban/conf.d ]]; then
        chown root:nftban /etc/nftban/conf.d
        chmod 750 /etc/nftban/conf.d
        find /etc/nftban/conf.d/ -type f -exec chown root:nftban {} \;
        find /etc/nftban/conf.d/ -type f -exec chmod 640 {} \;
        echo "  ✓ /etc/nftban/conf.d/ → 750 root:nftban"
    fi
    
    # Secrets directory (more restrictive)
    if [[ -d /etc/nftban/secrets.d ]]; then
        chown root:nftban /etc/nftban/secrets.d
        chmod 750 /etc/nftban/secrets.d
        find /etc/nftban/secrets.d/ -type f -exec chown root:nftban {} \;
        find /etc/nftban/secrets.d/ -type f -exec chmod 600 {} \;
        echo "  ✓ /etc/nftban/secrets.d/ → 750 root:nftban (files: 600)"
    fi
    
    # Main config file
    if [[ -f /etc/nftban/nftban.conf ]]; then
        chown root:nftban /etc/nftban/nftban.conf
        chmod 640 /etc/nftban/nftban.conf
        echo "  ✓ nftban.conf → 640 root:nftban"
    fi
else
    echo "  ⚠ /etc/nftban/ does not exist (will be created by installer)"
fi

echo ""

# =============================================================================
# FIX VAR/LIB DIRECTORY PERMISSIONS
# =============================================================================

echo "Fixing /var/lib/nftban/ permissions..."

if [[ -d /var/lib/nftban ]]; then
    # Application data: nftban user owns
    chown nftban:nftban /var/lib/nftban
    chmod 755 /var/lib/nftban
    echo "  ✓ /var/lib/nftban/ → 755 nftban:nftban"
    
    # Reports directory
    if [[ -d /var/lib/nftban/reports ]]; then
        chown nftban:nftban /var/lib/nftban/reports
        chmod 750 /var/lib/nftban/reports
        find /var/lib/nftban/reports/ -type f -exec chown nftban:nftban {} \;
        find /var/lib/nftban/reports/ -type f -exec chmod 640 {} \;
        echo "  ✓ /var/lib/nftban/reports/ → 750 nftban:nftban"
    fi
    
    # GeoIP database: root owns, group reads
    if [[ -d /var/lib/nftban/geoip ]]; then
        chown root:nftban /var/lib/nftban/geoip
        chmod 750 /var/lib/nftban/geoip
        find /var/lib/nftban/geoip/ -type f -name "*.mmdb" -exec chown root:nftban {} \;
        find /var/lib/nftban/geoip/ -type f -name "*.mmdb" -exec chmod 640 {} \;
        echo "  ✓ /var/lib/nftban/geoip/ → 750 root:nftban"
    fi
else
    echo "  ⚠ /var/lib/nftban/ does not exist (will be created by installer)"
fi

echo ""

# =============================================================================
# FIX CACHE DIRECTORY PERMISSIONS
# =============================================================================

echo "Fixing /var/cache/nftban/ permissions..."

if [[ -d /var/cache/nftban ]]; then
    chown nftban:nftban /var/cache/nftban
    chmod 755 /var/cache/nftban
    find /var/cache/nftban/ -type f -exec chown nftban:nftban {} \;
    find /var/cache/nftban/ -type f -exec chmod 644 {} \;
    echo "  ✓ /var/cache/nftban/ → 755 nftban:nftban"
else
    echo "  ⚠ /var/cache/nftban/ does not exist"
fi

echo ""

# =============================================================================
# SUMMARY
# =============================================================================

echo "════════════════════════════════════════════════════════════"
echo "  Permission Fix Complete!"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "Summary of changes:"
echo "  • /var/log/nftban/    → 750 nftban:nftban (daemon writes, group reads)"
echo "  • /etc/nftban/        → 750 root:nftban (admin writes, group reads)"
echo "  • /var/lib/nftban/    → 755 nftban:nftban (daemon owns)"
echo "  • /var/cache/nftban/  → 755 nftban:nftban (daemon owns)"
echo ""
echo "Access:"
echo "  • nftban user: Full write access to logs and data"
echo "  • nftban group: Read access to logs and config"
echo "  • root: Always full access (as root)"
echo "  • others: No access (secure)"
echo ""
echo "Test with: su - nftbantest -c 'ls -la /var/log/nftban/'"
echo ""

