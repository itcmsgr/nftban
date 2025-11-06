# NFTBan Precompiled Go Binaries - Transparency & Verification

**Version:** v0.32.3
**Purpose:** Explain how we provide precompiled binaries and how users can verify them
**Audience:** Security-conscious users, system administrators

---

## 🎯 Our Commitment to Transparency

NFTBan provides **precompiled Go binaries** in our packages for ease of use, but we remain **100% transparent** about what we ship:

✅ **Source code is available** - All Go code is in this repository
✅ **Reproducible builds** - Anyone can rebuild from source
✅ **Checksums provided** - Verify binary integrity
✅ **Build instructions documented** - Follow our compilation guide

**You have TWO options:**
1. **Trust our precompiled binaries** (included in RPM/DEB packages)
2. **Build from source yourself** (follow the guide below)

---

## 📦 What's Included in Packages

### RPM/DEB Package Contents

```bash
# Precompiled Go binaries (both architectures)
/usr/lib/nftban/bin/.real/nftban-geoip-x86_64   # 6.0 MB
/usr/lib/nftban/bin/.real/nftban-geoip-aarch64  # 6.0 MB
/usr/lib/nftban/bin/.real/nftban-feeds-x86_64   # ~5 MB
/usr/lib/nftban/bin/.real/nftban-feeds-aarch64  # ~5 MB

# Wrapper scripts (architecture detection)
/usr/lib/nftban/bin/nftban-geoip                # Bash wrapper
/usr/lib/nftban/bin/nftban-feeds                # Bash wrapper

# Configuration files
/etc/nftban/conf.d/nftban-go.conf               # Go binary settings
/etc/nftban/conf.d/feeds.conf                   # Feed list
/etc/nftban/geoban.d/                           # GeoBan configs

# Documentation
/usr/share/doc/nftban/GO_COMPILATION_GUIDE.md   # Build instructions
/usr/share/doc/nftban/HLD_GO_MODULES.md         # Architecture
/usr/share/doc/nftban/GO_SYSTEM_PROTECTION.md   # Safety limits
```

---

## ✅ How to Verify Precompiled Binaries

### Step 1: Check Binary Integrity

```bash
# Check SHA256 checksums (included in package)
sha256sum /usr/lib/nftban/bin/.real/nftban-geoip-x86_64
# Compare with checksums file
cat /usr/share/doc/nftban/CHECKSUMS.txt
```

### Step 2: Inspect Binary Metadata

```bash
# Check build information
strings /usr/lib/nftban/bin/.real/nftban-geoip-x86_64 | grep -E "(VERSION|BuildTime|GoVersion)"

# Example output:
# VERSION=0.32.0
# BuildTime=2025-11-06T00:00:00Z
# GoVersion=go1.21.5
```

### Step 3: Run Version Command

```bash
# Verify binary works and shows version
/usr/lib/nftban/bin/.real/nftban-geoip-x86_64 version

# Output:
# nftban-geoip v0.32.0
# Build: 2025-11-06
# Go: go1.21.5
```

### Step 4: Compare with Source

```bash
# Clone repository
git clone https://github.com/nftban/nftban.git
cd nftban
git checkout v0.32.0

# Inspect source code
cat go-geoip/cmd/nftban-geoip/main.go
cat go-geoip/internal/geoban/geoban.go

# Verify it matches the binary behavior
```

---

## 🔨 Option 1: Use Precompiled Binaries (Easy)

**Who should use this:**
- Production servers (stable releases)
- Users who trust our build process
- Quick installations

**How to install:**

```bash
# Fedora/Rocky/RHEL/CentOS
sudo dnf install nftban

# Ubuntu/Debian
sudo apt install nftban

# Verify installation
nftban geoip version
nftban feeds version
```

**Binaries are precompiled by:**
- GitHub Actions (automated builds)
- Reproducible build environment
- Signed with GPG (coming in v0.32.0)

---

## 🏗️ Option 2: Build From Source (Advanced)

**Who should use this:**
- Security auditors
- Users who want to verify everything
- Custom architecture support
- Development/testing

**Prerequisites:**
```bash
# Install Go 1.21+
sudo dnf install golang  # Fedora/Rocky/RHEL
sudo apt install golang  # Ubuntu/Debian

# Verify Go version
go version
# Should show: go version go1.21.0 or newer
```

**Build Instructions:**

### Quick Build (Official Script)

```bash
cd /home/gituser/github/nftban

# Build all binaries (x86_64 + aarch64)
./scripts/build-go-binaries.sh

# Binaries will be in:
ls -lh dist/x86_64/nftban-geoip
ls -lh dist/x86_64/nftban-feeds
ls -lh dist/aarch64/nftban-geoip
ls -lh dist/aarch64/nftban-feeds
```

### Manual Build (Step-by-Step)

**GeoIP Binary:**
```bash
cd go-geoip

# Install dependencies
go mod download
go mod tidy

# Build for x86_64
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -buildvcs=false \
  -ldflags "-s -w -X main.VERSION=0.32.0" \
  -o ../dist/x86_64/nftban-geoip \
  ./cmd/nftban-geoip

# Build for ARM64
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
  go build -buildvcs=false \
  -ldflags "-s -w -X main.VERSION=0.32.0" \
  -o ../dist/aarch64/nftban-geoip \
  ./cmd/nftban-geoip

# Verify
ls -lh ../dist/*/nftban-geoip
```

**Feeds Binary:**
```bash
cd go-feeds

# Install dependencies
go mod download
go mod tidy

# Build for x86_64
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -buildvcs=false \
  -ldflags "-s -w -X main.VERSION=0.32.0" \
  -o ../dist/x86_64/nftban-feeds \
  ./cmd/nftban-feeds

# Build for ARM64
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
  go build -buildvcs=false \
  -ldflags "-s -w -X main.VERSION=0.32.0" \
  -o ../dist/aarch64/nftban-feeds \
  ./cmd/nftban-feeds

# Verify
ls -lh ../dist/*/nftban-feeds
```

### Install Manually Built Binaries

```bash
# Detect architecture
ARCH=$(uname -m)

# Copy binaries to system
sudo mkdir -p /usr/lib/nftban/bin/.real/
sudo cp dist/$ARCH/nftban-geoip /usr/lib/nftban/bin/.real/nftban-geoip-$ARCH
sudo cp dist/$ARCH/nftban-feeds /usr/lib/nftban/bin/.real/nftban-feeds-$ARCH
sudo chmod +x /usr/lib/nftban/bin/.real/nftban-*

# Test
nftban geoip version
nftban feeds version
```

---

## 📊 Build Configuration Values

All builds use these standard configuration values:

**Compilation Flags:**
```bash
CGO_ENABLED=0        # Static binary (no C dependencies)
GOOS=linux           # Target OS
GOARCH=amd64         # or arm64

-buildvcs=false      # Disable VCS stamping
-ldflags "-s -w"     # Strip symbols (smaller binary)
-ldflags "-X main.VERSION=0.32.0"  # Embed version
```

**Safety Configuration:**
```bash
# From /etc/nftban/conf.d/nftban-go.conf
GO_MAX_CPU_PERCENT="80"
GO_MAX_MEMORY_MB="4096"
GO_NFT_CHUNK_SIZE="4096"
GO_DOWNLOAD_TIMEOUT="30"
GO_MAX_DOWNLOAD_SIZE_MB="50"
```

**Full documentation:** See `/docs/GO_COMPILATION_GUIDE.md`

---

## 🔐 Security & Trust Model

### What We Do

✅ **Provide source code** - All Go code is in this repository
✅ **Document build process** - Exact commands to reproduce
✅ **Include checksums** - Verify binary integrity
✅ **Use GitHub Actions** - Automated, auditable builds
✅ **Keep binaries in git** - Precompiled binaries committed to `/dist/`

### What You Can Do

✅ **Audit source code** - Read every line before trusting
✅ **Build from source** - Compile yourself
✅ **Compare binaries** - Verify our precompiled matches your build
✅ **Check dependencies** - `go.mod` lists all dependencies
✅ **Review checksums** - Verify no tampering

### Trust Levels

**Level 1: Trust Nothing**
- Build from source yourself
- Audit every line of code
- Compare with precompiled binaries

**Level 2: Trust Build Process**
- Use precompiled binaries
- Verify checksums
- Spot-check source code

**Level 3: Trust Package Manager**
- Install via dnf/apt
- Rely on package signatures
- Use official repositories

**We support ALL levels!** Choose what works for you.

---

## 📂 Configuration File Locations

**ALL NFTBan configurations are in `/etc/nftban/`** - Nothing scattered elsewhere!

```bash
/etc/nftban/
├── nftban.conf                    # Main NFTBan config
├── conf.d/
│   ├── nftban-go.conf             # Go binary settings (CPU, RAM, etc)
│   ├── nftban-go.conf.local       # User overrides (preserved on upgrade)
│   ├── feeds.conf                 # Feed list (URLs, categories)
│   └── feeds.conf.local           # User feed customizations
├── geoban.d/
│   ├── 50-ban-CN.conf             # Banned countries
│   └── 40-whitelist-US.conf       # Whitelisted countries
└── feeds.d/
    └── *.list                     # Custom feed lists
```

**Key Configuration Files:**

1. **`/etc/nftban/conf.d/nftban-go.conf`**
   - Go binary performance settings
   - CPU/RAM/I/O limits
   - Safety thresholds
   - HTTP timeouts

2. **`/etc/nftban/conf.d/feeds.conf`**
   - Available threat feeds
   - Feed URLs and categories
   - Enable/disable feeds

3. **User Overrides: `*.conf.local`**
   - Preserved during package upgrades
   - Override default settings
   - Example: `/etc/nftban/conf.d/nftban-go.conf.local`

**Full documentation:** See `/docs/CONFIGURATION_LOCATIONS.md`

---

## 🎓 Educational Resources

### Documentation Files (All in `/docs/`)

1. **HLD_GO_MODULES.md** - Architecture overview
2. **GO_COMPILATION_GUIDE.md** - How to build binaries
3. **GO_SYSTEM_PROTECTION.md** - Safety limits explained
4. **CONFIGURATION_LOCATIONS.md** - All config files
5. **GEOBAN_FEATURE.md** - GeoBan usage guide
6. **DNS_AND_NETWORK_REQUIREMENTS.md** - Network dependencies

### Source Code (All in repository)

1. **go-geoip/** - GeoIP + GeoBan implementation
2. **go-feeds/** - Threat feeds implementation
3. **scripts/** - Build scripts

**Everything is documented and transparent!**

---

## ❓ Frequently Asked Questions

**Q: Why provide precompiled binaries?**

A: Convenience. Not everyone has Go installed or wants to compile. We provide both options.

**Q: Can I trust your precompiled binaries?**

A: You don't have to! Build from source and compare checksums. We document everything.

**Q: Are binaries signed?**

A: GPG signing coming in v0.32.0. Currently: checksums + reproducible builds.

**Q: Why are binaries in git?**

A: Transparency. You can see exactly what we ship in packages. GitHub tracks all changes.

**Q: What if I want to modify the code?**

A: Great! Fork the repo, make changes, rebuild. It's all open source (MPL-2.0 license).

**Q: Do updates overwrite my custom builds?**

A: No. Store custom builds outside `/usr/lib/nftban/bin/.real/` or use `.conf.local` to point to custom path.

---

## 🚀 Quick Start

**Trust precompiled (easiest):**
```bash
sudo dnf install nftban  # or apt
nftban geoip version
```

**Build from source (paranoid):**
```bash
git clone https://github.com/nftban/nftban.git
cd nftban
./scripts/build-go-binaries.sh
sudo ./install.sh
```

**Verify precompiled matches source:**
```bash
# Install package
sudo dnf install nftban

# Build from source
./scripts/build-go-binaries.sh

# Compare checksums
sha256sum /usr/lib/nftban/bin/.real/nftban-geoip-x86_64
sha256sum dist/x86_64/nftban-geoip
# Should match!
```

---

## 📞 Support

**Questions about binaries?**
- Read: `/docs/GO_COMPILATION_GUIDE.md`
- Issue: https://github.com/nftban/nftban/issues

**Want to audit code?**
- Start: `go-geoip/cmd/nftban-geoip/main.go`
- Architecture: `/docs/HLD_GO_MODULES.md`

**Found a security issue?**
- Contact: contact@nftban.com
- GPG: [Coming in v0.32.0]

---

**Last Updated:** 2025-11-06
**Version:** v0.32.3
**License:** MPL-2.0

**We believe in transparency. You shouldn't have to trust us blindly.**
