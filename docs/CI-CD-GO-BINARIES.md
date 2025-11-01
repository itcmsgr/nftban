# NFTBan Go Binaries CI/CD Architecture

**Version:** v0.10.0
**Date:** 2025-11-01
**Status:** Documented - Ready for Implementation

---

## 📋 Overview

NFTBan uses a **hybrid architecture** combining Bash scripts (for management/orchestration) with Go binaries (for performance-critical operations). This document describes the complete CI/CD pipeline for building, signing, and distributing Go binaries.

### The Challenge

**Problem:** How to distribute compiled Go binaries without bloating the Git repository?

**Solution:** Industry-standard CI/CD pattern used by Docker, Kubernetes, Prometheus, and Grafana:
- ✅ Source code only in Git
- ✅ CI builds binaries on release
- ✅ Artifacts published to GitHub Releases
- ✅ Packages download & verify binaries

---

## 🏗️ Architecture

### Source Repository (Git)
```
nftban/
├── go-feeds/                          # Go source code
│   └── cmd/nftban-feeds/main.go
├── go-geoip/                          # Go source code
│   └── cmd/nftban-geoip/main.go
├── src/usr/lib/nftban/bin/
│   ├── nftban-feeds                   # Smart wrapper (122 bytes)
│   └── nftban-geoip                   # Smart wrapper (122 bytes)
├── .github/workflows/
│   └── release-binaries.yml           # CI/CD workflow
└── scripts/
    ├── build-go-binaries.sh           # Local development builds
    ├── build-rpm-from-release.sh      # RPM from GitHub Release
    └── build-deb-from-release.sh      # DEB from GitHub Release
```

### Installed System (RPM/DEB packages)
```
/usr/lib/nftban/bin/
├── nftban-feeds         # Smart wrapper script
├── nftban-geoip         # Smart wrapper script
└── .real/
    ├── nftban-feeds     # Real Go binary (2.1 MB) - 10-60x faster
    └── nftban-geoip     # Real Go binary (2.1 MB) - 10-60x faster
```

### How Smart Wrappers Work
```bash
#!/usr/bin/env bash
REAL="/usr/lib/nftban/bin/.real/nftban-feeds"

# If real Go binary exists, exec it (fast path)
if [ -x "$REAL" ]; then
    exec "$REAL" "$@"
fi

# Otherwise, warn and use fallback (slow path)
echo "⚠️ nftban-feeds Go binary not present. Using slow fallback."
# ... fallback implementation ...
```

---

## 🔄 CI/CD Pipeline

### 1. Developer Pushes Release Tag
```bash
git tag v0.10.0
git push origin v0.10.0
```

### 2. GitHub Actions Workflow Triggers

**File:** `.github/workflows/release-binaries.yml`

**Steps:**
1. **Build Matrix** - Builds for `amd64` and `arm64` in parallel
   ```bash
   GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w" \
     -o dist/nftban-feeds-amd64 ./go-feeds/cmd/nftban-feeds
   ```

2. **Assemble Artifacts** - Collects all binaries
   ```
   dist/
   ├── nftban-feeds-amd64
   ├── nftban-feeds-arm64
   ├── nftban-geoip-amd64
   └── nftban-geoip-arm64
   ```

3. **Generate Checksums**
   ```bash
   sha256sum nftban-* > SHA256SUMS
   ```

4. **GPG Sign Checksums** (Security critical!)
   ```bash
   gpg --armor --detach-sign --output SHA256SUMS.asc SHA256SUMS
   ```

5. **Upload to GitHub Releases**
   ```
   Release v0.10.0 Assets:
   ├── nftban-feeds-amd64
   ├── nftban-feeds-arm64
   ├── nftban-geoip-amd64
   ├── nftban-geoip-arm64
   ├── SHA256SUMS
   └── SHA256SUMS.asc  (GPG signature)
   ```

### 3. Package Build Process

**For RPM:**
```bash
scripts/build-rpm-from-release.sh v0.10.0 x86_64
```

**What it does:**
1. Downloads binaries from GitHub Release
2. Downloads SHA256SUMS + SHA256SUMS.asc
3. **Verifies GPG signature**
4. **Verifies SHA256 checksums**
5. Builds RPM with verified binaries
6. Installs binaries to `/usr/lib/nftban/bin/.real/`

**For DEB:**
```bash
scripts/build-deb-from-release.sh v0.10.0 amd64
```
(Same verification process)

---

## 🛡️ Security Model

### Chain of Trust

1. **Developer** signs Git commit with GPG
2. **GitHub Actions** builds binaries in isolated environment
3. **CI Pipeline** signs SHA256SUMS with GPG private key (from secrets)
4. **Package Builder** verifies:
   - GPG signature on SHA256SUMS ✅
   - SHA256 checksums of binaries ✅
5. **User** installs verified package

### Required GitHub Secrets

Add these to repository settings → Secrets:

| Secret | Purpose | How to Generate |
|--------|---------|-----------------|
| `GPG_PRIVATE_KEY` | Sign release checksums | `gpg --armor --export-secret-key YOUR_KEY_ID` |
| `GPG_PASSPHRASE` | Unlock private key | Your GPG key passphrase |

### Generating GPG Keys

```bash
# Generate key
gpg --full-generate-key
# Choose: RSA, 4096 bits, no expiration
# Name: NFTBan Release Signing
# Email: release@nftban.com

# Export public key (for users to verify)
gpg --armor --export release@nftban.com > nftban-release-key.asc

# Export private key (for GitHub Secrets)
gpg --armor --export-secret-key release@nftban.com
# Copy output to GitHub Secret: GPG_PRIVATE_KEY
```

---

## 📦 Package Distribution

### Multi-Architecture Support

| Architecture | Go Arch | RPM Arch | Use Case |
|--------------|---------|----------|----------|
| Intel/AMD 64-bit | `amd64` | `x86_64` | Servers, desktops |
| ARM 64-bit | `arm64` | `aarch64` | Raspberry Pi, cloud ARM instances |

### Installed Files

**Wrappers** (from Git source):
- `/usr/lib/nftban/bin/nftban-feeds` (wrapper script)
- `/usr/lib/nftban/bin/nftban-geoip` (wrapper script)

**Real Binaries** (from GitHub Releases):
- `/usr/lib/nftban/bin/.real/nftban-feeds` (Go binary, 2.1 MB)
- `/usr/lib/nftban/bin/.real/nftban-geoip` (Go binary, 2.1 MB)

---

## 🚀 Usage

### For End Users

**Install from RPM:**
```bash
dnf install nftban-0.10.0-1.el9.x86_64.rpm
# Real Go binaries included automatically!
```

**Install from DEB:**
```bash
apt install ./nftban_0.10.0-1_amd64.deb
# Real Go binaries included automatically!
```

### For Developers

**Local Build (for testing):**
```bash
./scripts/build-go-binaries.sh --arch $(uname -m)
# Output: dist/nftban-feeds-amd64, dist/nftban-geoip-amd64
```

**Build All Architectures:**
```bash
./scripts/build-go-binaries.sh --all
# Output: dist/nftban-*-{amd64,arm64}
```

**Test Locally:**
```bash
sudo cp dist/nftban-feeds-amd64 /usr/lib/nftban/bin/.real/nftban-feeds
sudo cp dist/nftban-geoip-amd64 /usr/lib/nftban/bin/.real/nftban-geoip
nftban feeds update  # Uses fast Go binary now!
```

---

## 📊 Performance Comparison

| Operation | Bash Implementation | Go Binary | Speedup |
|-----------|-------------------|-----------|---------|
| Parse 100K IP feed | ~60 seconds | ~1 second | **60x faster** |
| GeoIP lookup (1000 IPs) | ~30 seconds | ~2 seconds | **15x faster** |
| Deduplicate 500K IPs | ~45 seconds | ~3 seconds | **15x faster** |

---

## 🔍 Verification

### Verify Package Integrity

**Verify GPG signature:**
```bash
# Import NFTBan public key
curl -fsSL https://github.com/itcmsgr/nftban/releases/download/v0.10.0/nftban-release-key.asc | gpg --import

# Verify checksum file signature
gpg --verify SHA256SUMS.asc SHA256SUMS
# Output: Good signature from "NFTBan Release Signing"
```

**Verify binary checksums:**
```bash
sha256sum -c SHA256SUMS
# Output: All files OK
```

### Check Installed Binaries

```bash
# Check if real binaries are installed
ls -lh /usr/lib/nftban/bin/.real/
# Output: -rwxr-xr-x 1 root root 2.1M nftban-feeds
#         -rwxr-xr-x 1 root root 2.1M nftban-geoip

# Test wrapper auto-detection
/usr/lib/nftban/bin/nftban-feeds version
# Output: nftban-feeds v1.0.0 (Go binary)
```

---

## 🛠️ Troubleshooting

### Issue: "Go binary not present. Using slow fallback"

**Cause:** RPM/DEB package didn't install real binaries.

**Solution:**
```bash
# Check if .real/ directory exists
ls -la /usr/lib/nftban/bin/.real/

# Reinstall package
dnf reinstall nftban
```

### Issue: "GPG verification failed"

**Cause:** GPG public key not imported.

**Solution:**
```bash
# Import NFTBan public key
curl -fsSL https://github.com/itcmsgr/nftban/releases/download/v0.10.0/nftban-release-key.asc | gpg --import

# Re-run build
./scripts/build-rpm-from-release.sh v0.10.0 x86_64
```

### Issue: GitHub Actions workflow fails

**Cause:** Missing GPG secrets.

**Solution:**
1. Go to repository Settings → Secrets → Actions
2. Add `GPG_PRIVATE_KEY` (ASCII-armored private key)
3. Add `GPG_PASSPHRASE` (your GPG passphrase)
4. Re-run workflow

---

## 📚 References

### Example Projects Using This Pattern

- **Prometheus** - https://github.com/prometheus/prometheus/releases
- **Grafana** - https://github.com/grafana/grafana/releases
- **Kubernetes** - https://github.com/kubernetes/kubernetes/releases
- **Docker** - https://github.com/docker/cli/releases

### Documentation

- GitHub Actions: https://docs.github.com/en/actions
- Go Cross-Compilation: https://go.dev/doc/install/source#environment
- RPM Packaging: https://rpm-packaging-guide.github.io/
- GPG Signing: https://www.gnupg.org/gph/en/manual.html

---

## 🔮 Future Enhancements

### Planned for v0.11.0

- [ ] Cosign/Sigstore signing (in addition to GPG)
- [ ] Publish to Fedora Copr repository
- [ ] Publish to GitHub Packages (APT/YUM)
- [ ] Binary reproducibility verification
- [ ] SBOM (Software Bill of Materials) generation

### Planned for v1.0.0

- [ ] Official Fedora package submission
- [ ] Official Debian package submission
- [ ] Multi-distro repository hosting
- [ ] Automated security scanning (Snyk, Trivy)

---

## 📞 Support

**Questions about Go binary distribution?**
- GitHub Issues: https://github.com/itcmsgr/nftban/issues
- Documentation: https://github.com/itcmsgr/nftban/blob/main/docs/

**Security concerns about binary verification?**
- Security Policy: https://github.com/itcmsgr/nftban/blob/main/SECURITY.md
- Email: security@nftban.com

---

**Last Updated:** 2025-11-01
**ChatGPT Review:** Complete
**Status:** ✅ Ready for Implementation
