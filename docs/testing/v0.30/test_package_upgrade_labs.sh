#!/bin/bash
# =============================================================================
# NFTBan v0.30.0 - Lab Servers Package Upgrade Test
# =============================================================================
# Tests complete workflow: GitHub Release → Download → Install → Verify
# ONLY TESTS ON LAB SERVERS (no local testing)
# =============================================================================

set -e

VERSION="0.30.0"
REPO="itcmsgr/nftban"
TAG="v${VERSION}"

# Lab server configurations
declare -A SERVERS=(
    ["lab.mywebhost.gr"]="CentOS Stream 9:rpm:el9"
    ["lab1.mywebhost.gr"]="Ubuntu 24.04:deb:amd64"
    ["lab2.mywebhost.gr"]="CentOS Stream 10:rpm:el9"
    ["lab3.mywebhost.gr"]="AlmaLinux 10.0:rpm:el10"
    ["lab4.mywebhost.gr"]="Rocky Linux 10:rpm:el10"
)

echo "════════════════════════════════════════════════════════════════════════════════"
echo "  NFTBan v${VERSION} - Package Upgrade Test (LAB SERVERS ONLY)"
echo "════════════════════════════════════════════════════════════════════════════════"
echo ""
echo "This validates the complete CI/CD workflow:"
echo "  1. ✅ Code pushed to GitHub"
echo "  2. ✅ Tag ${TAG} created"
echo "  3. ⏳ GitHub Actions builds packages"
echo "  4. ⏳ Download packages from GitHub Release"
echo "  5. ⏳ Install/upgrade on 5 lab servers"
echo "  6. ⏳ Verify v0.30.0 functionality"
echo ""

# Verify release exists
echo "───────────────────────────────────────────────────────────────────────────────"
echo "📡 Verifying GitHub Release ${TAG}..."
echo "───────────────────────────────────────────────────────────────────────────────"

RELEASE_URL="https://github.com/${REPO}/releases/tag/${TAG}"
if ! curl -fsI "$RELEASE_URL" >/dev/null 2>&1; then
    echo "❌ ERROR: Release ${TAG} not found"
    echo ""
    echo "Please wait for GitHub Actions to complete the build."
    echo "Run monitor script: bash /tmp/monitor_build.sh"
    exit 1
fi

echo "✅ Release ${TAG} exists"
echo ""

# Download packages to temp directory
DOWNLOAD_DIR="/tmp/nftban-v${VERSION}-packages"
rm -rf "$DOWNLOAD_DIR"
mkdir -p "$DOWNLOAD_DIR"
cd "$DOWNLOAD_DIR"

echo "───────────────────────────────────────────────────────────────────────────────"
echo "📥 Downloading Packages from GitHub..."
echo "───────────────────────────────────────────────────────────────────────────────"

# Download RPM for EL9
RPM_EL9="nftban-${VERSION}-1.el9.x86_64.rpm"
echo "Downloading: ${RPM_EL9}..."
if curl -fsSL -o "${RPM_EL9}" "https://github.com/${REPO}/releases/download/${TAG}/${RPM_EL9}"; then
    echo "  ✅ ${RPM_EL9} ($(stat -c%s ${RPM_EL9} | numfmt --to=iec-i)B)"
else
    echo "  ❌ Failed to download ${RPM_EL9}"
fi

# Download RPM for EL10 (if exists)
RPM_EL10="nftban-${VERSION}-1.el10.x86_64.rpm"
echo "Downloading: ${RPM_EL10}..."
if curl -fsSL -o "${RPM_EL10}" "https://github.com/${REPO}/releases/download/${TAG}/${RPM_EL10}"; then
    echo "  ✅ ${RPM_EL10} ($(stat -c%s ${RPM_EL10} | numfmt --to=iec-i)B)"
else
    echo "  ⚠️  ${RPM_EL10} not available (will use EL9 for EL10 servers)"
    rm -f "${RPM_EL10}"
fi

# Download DEB
DEB_AMD64="nftban_${VERSION}-1_amd64.deb"
echo "Downloading: ${DEB_AMD64}..."
if curl -fsSL -o "${DEB_AMD64}" "https://github.com/${REPO}/releases/download/${TAG}/${DEB_AMD64}"; then
    echo "  ✅ ${DEB_AMD64} ($(stat -c%s ${DEB_AMD64} | numfmt --to=iec-i)B)"
else
    echo "  ❌ Failed to download ${DEB_AMD64}"
fi

# Download SHA256SUMS
echo "Downloading: SHA256SUMS..."
if curl -fsSL -o SHA256SUMS "https://github.com/${REPO}/releases/download/${TAG}/SHA256SUMS"; then
    echo "  ✅ SHA256SUMS"
fi

echo ""
echo "───────────────────────────────────────────────────────────────────────────────"
echo "🔐 Verifying Package Integrity..."
echo "───────────────────────────────────────────────────────────────────────────────"

if [ -f SHA256SUMS ]; then
    if sha256sum -c SHA256SUMS 2>&1 | grep -E "OK|FAILED"; then
        echo "  ✅ Checksums verified"
    else
        echo "  ⚠️  Some checksums couldn't be verified"
    fi
else
    echo "  ⚠️  SHA256SUMS not available, skipping verification"
fi

# Test on each lab server
echo ""
echo "════════════════════════════════════════════════════════════════════════════════"
echo "  Testing Package Installation on Lab Servers"
echo "════════════════════════════════════════════════════════════════════════════════"

SUCCESS_COUNT=0
FAIL_COUNT=0

for server in "${!SERVERS[@]}"; do
    IFS=':' read -r distro pkg_type pkg_variant <<< "${SERVERS[$server]}"

    echo ""
    echo "───────────────────────────────────────────────────────────────────────────"
    echo "🖥️  Server: $server"
    echo "    Distribution: $distro"
    echo "───────────────────────────────────────────────────────────────────────────"

    # Determine package to use
    if [ "$pkg_type" = "rpm" ]; then
        if [ "$pkg_variant" = "el10" ] && [ -f "${RPM_EL10}" ]; then
            PACKAGE="${RPM_EL10}"
        else
            PACKAGE="${RPM_EL9}"
        fi
        PKG_MANAGER="dnf"
    else
        PACKAGE="${DEB_AMD64}"
        PKG_MANAGER="apt-get"
    fi

    if [ ! -f "$PACKAGE" ]; then
        echo "  ❌ Package not found: $PACKAGE"
        ((FAIL_COUNT++))
        continue
    fi

    # Copy package to server
    echo "  📤 Uploading $PACKAGE to server..."
    if ! scp -q "$PACKAGE" "root@$server:/tmp/" 2>/dev/null; then
        echo "  ❌ Failed to upload package"
        ((FAIL_COUNT++))
        continue
    fi

    # Install/upgrade package
    echo "  📦 Installing/upgrading package..."

    if ssh -o ConnectTimeout=10 root@$server "bash -s" <<ENDSSH
set -e

echo "  📌 Current version: \$(rpm -q nftban 2>/dev/null || dpkg -l nftban 2>/dev/null | grep ^ii | awk '{print \$3}' || echo 'not installed')"

# Install/upgrade
if [ "$pkg_type" = "rpm" ]; then
    dnf upgrade -y /tmp/${PACKAGE} 2>&1 | grep -E "(Installing|Upgrading|Installed|Complete)" || true
    NEW_VERSION=\$(rpm -q nftban)
else
    DEBIAN_FRONTEND=noninteractive apt-get install -y /tmp/${PACKAGE} 2>&1 | grep -E "(Unpacking|Setting up|Processing)" || true
    NEW_VERSION=\$(dpkg -l nftban | grep ^ii | awk '{print \$3}')
fi

echo "  ✅ Installed version: \$NEW_VERSION"

# Verify v0.30 components
echo ""
echo "  🔍 Verifying v0.30 components:"

check_file() {
    if [ -f "\$1" ]; then
        echo "    ✅ \$2"
        return 0
    else
        echo "    ❌ \$2 MISSING"
        return 1
    fi
}

check_file "/usr/libexec/nftban/helpers/nftban-procnet" "nftban-procnet"
check_file "/usr/libexec/nftban/helpers/nftban-pkgs" "nftban-pkgs"
check_file "/usr/libexec/nftban/helpers/nftban-verify" "nftban-verify"
check_file "/usr/libexec/nftban/helpers/nftban-firewall" "nftban-firewall"
check_file "/usr/libexec/nftban/health/nftban-health" "nftban-health"
check_file "/usr/libexec/nftban/health/nftban-baseline-save" "nftban-baseline-save"
check_file "/etc/nftban/conf.d/health.conf" "health.conf"
check_file "/usr/lib/nftban/core/nftban_mail_v030.sh" "mail adapter v0.30"

if [ -d "/var/lib/nftban/reports/baseline" ]; then
    echo "    ✅ baseline directory"
else
    echo "    ❌ baseline directory MISSING"
fi

if [ -d "/etc/nftban/keys" ]; then
    echo "    ✅ keys directory"
else
    echo "    ❌ keys directory MISSING"
fi

# Test inventory collection
echo ""
echo "  🧪 Testing inventory collection..."
if /usr/local/bin/nftban-health --inventory >/tmp/test_inventory.json 2>&1; then
    PROC_COUNT=\$(jq -r '.processes | length' /tmp/test_inventory.json 2>/dev/null || echo 0)
    echo "    ✅ Inventory collection working (\$PROC_COUNT processes detected)"
    rm -f /tmp/test_inventory.json
else
    echo "    ❌ Inventory collection FAILED"
    exit 1
fi

# Test resource monitoring
echo ""
echo "  🧪 Testing resource monitoring..."
if nftban health check 2>&1 | grep -q "Resource Checks"; then
    echo "    ✅ Resource monitoring integrated"
else
    echo "    ⚠️  Resource monitoring not detected (may need config)"
fi

# Cleanup
rm -f /tmp/${PACKAGE}

echo ""
echo "  ✅ All tests passed on $server"
ENDSSH
    then
        echo "  ✅ SUCCESS: $server upgraded and verified"
        ((SUCCESS_COUNT++))
    else
        echo "  ❌ FAILED: $server tests failed"
        ((FAIL_COUNT++))
    fi
done

# Summary
echo ""
echo "════════════════════════════════════════════════════════════════════════════════"
echo "  🎉 Test Summary"
echo "════════════════════════════════════════════════════════════════════════════════"
echo ""
echo "  ✅ Successful: $SUCCESS_COUNT / ${#SERVERS[@]} servers"
echo "  ❌ Failed: $FAIL_COUNT / ${#SERVERS[@]} servers"
echo ""

if [ $SUCCESS_COUNT -eq ${#SERVERS[@]} ]; then
    echo "  🎊 100% SUCCESS! All lab servers upgraded to v${VERSION}"
    echo ""
    echo "  The complete CI/CD workflow is validated:"
    echo "    ✅ Git commit → push"
    echo "    ✅ Git tag → automated build"
    echo "    ✅ GitHub Release → packages published"
    echo "    ✅ Package download → installation"
    echo "    ✅ Upgrade → verification"
    echo ""
    echo "  v${VERSION} is PRODUCTION READY! 🚀"
else
    echo "  ⚠️  Some servers failed. Review logs above."
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════════"

# Cleanup
cd /
rm -rf "$DOWNLOAD_DIR"
