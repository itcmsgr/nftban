# NFTBan Go Binary Compilation Guide

**Version:** v0.32.3
**Last Updated:** 2025-01-05
**Audience:** Developers, Package Maintainers, System Administrators

---

## 📋 Overview

NFTBan uses a **single unified Go binary** `nftban-geoip` that provides:
- **GeoIP Lookups** (MaxMind GeoLite2)
- **GeoBan Operations** (Country-based blocking using IPdeny.com)

All Go operations share common safety configurations in `/etc/nftban/conf.d/nftban-go.conf`.

---

## 🎯 Prerequisites

### Required Tools
```bash
# Go 1.21 or higher
go version  # Must show go1.21+

# Git
git --version

# Build tools
make --version
```

### System Requirements
- **OS:** Linux (kernel 5.10+)
- **Architecture:** x86_64 or aarch64 (ARM64)
- **RAM:** 2GB minimum, 4GB recommended for building
- **Disk:** 500MB free space

---

## 📂 Project Structure

```
nftban/
├── go-geoip/                       # GeoIP + GeoBan Go package
│   ├── go.mod                      # Dependencies
│   ├── go.sum                      # Dependency checksums
│   ├── cmd/
│   │   └── nftban-geoip/
│   │       └── main.go             # Main entry point
│   └── internal/
│       ├── geoban/
│       │   └── geoban.go           # Country blocking logic
│       └── ... (other internal packages)
│
├── scripts/
│   └── build-go-binaries.sh        # Official build script
│
├── src/etc/nftban/conf.d/
│   └── nftban-go.conf              # ⭐ UNIFIED CONFIGURATION
│
└── docs/
    └── GO_COMPILATION_GUIDE.md     # This file
```

---

## ⚙️ Configuration Values (MUST READ)

**All Go operations use `/etc/nftban/conf.d/nftban-go.conf`**

### Critical Safety Settings

| Setting | Default | Purpose |
|---------|---------|---------|
| `GO_MAX_CPU_PERCENT` | `80` | Max CPU usage before throttling (%) |
| `GO_MAX_MEMORY_MB` | `4096` | Max memory usage (MB) |
| `GO_NFT_CHUNK_SIZE` | `4096` | Elements per nftables transaction |
| `GO_NFT_ENOBUFS_RETRY` | `true` | Retry on buffer full errors |
| `GO_DELTA_LIMIT_ENABLED` | `true` | Prevent 10x+ size jumps |
| `GO_CACHE_ENABLED` | `true` | HTTP ETag caching |

### HTTP Download Settings

| Setting | Default | Purpose |
|---------|---------|---------|
| `GO_DOWNLOAD_TIMEOUT` | `30` | HTTP timeout (seconds) |
| `GO_MAX_DOWNLOAD_SIZE_MB` | `50` | Max file size (MB) |
| `GO_MAX_RETRIES` | `3` | Max retry attempts |
| `GO_USER_AGENT` | `NFTBan/0.32.0 (+https://nftban.com)` | HTTP User-Agent |

### Paths

| Setting | Default | Purpose |
|---------|---------|---------|
| `GO_CACHE_DIR` | `/var/cache/nftban/go-cache` | HTTP cache directory |
| `GO_LOG_FILE` | `/var/log/nftban/go-operations.log` | Unified Go log |
| `GEOBAN_FILES_DIR` | `/etc/nftban/geoban.d` | Country IP files |
| `GEOBAN_CACHE_DIR` | `/var/cache/nftban/geoban` | GeoBan HTTP cache |
| `GEOIP_DATABASE` | `/var/lib/nftban/geoip/GeoLite2-City.mmdb` | MaxMind DB |

**⚠️ IMPORTANT:** These values are read by the bash wrapper scripts. The Go binary itself has hardcoded defaults but can be overridden via CLI flags.

---

## 🔨 Compilation Instructions

### Method 1: Official Build Script (Recommended)

**This method builds for BOTH x86_64 and aarch64 architectures:**

```bash
# 1. Clone repository
cd /root
git clone https://github.com/nftban/nftban.git
cd nftban

# 2. Review configuration
cat src/etc/nftban/conf.d/nftban-go.conf

# 3. Build using official script
./scripts/build-go-binaries.sh

# 4. Verify outputs
ls -lh dist/x86_64/nftban-geoip
ls -lh dist/aarch64/nftban-geoip
ls -lh src/usr/lib/nftban/bin/.real/nftban-geoip-*
```

**Build Script Does:**
1. Detects system architecture
2. Builds static binaries (CGO_ENABLED=0)
3. Strips debug symbols (-ldflags "-s -w")
4. Embeds version string
5. Creates architecture-specific binaries:
   - `dist/x86_64/nftban-geoip`
   - `dist/aarch64/nftban-geoip`
6. Copies native binary to `src/usr/lib/nftban/bin/.real/nftban-geoip-<arch>`

---

### Method 2: Manual Build (Development)

**For x86_64:**
```bash
cd go-geoip
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -ldflags "-s -w -X main.VERSION=0.32.0" \
  -o ../dist/x86_64/nftban-geoip \
  ./cmd/nftban-geoip
```

**For aarch64 (ARM64):**
```bash
cd go-geoip
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
  go build -ldflags "-s -w -X main.VERSION=0.32.0" \
  -o ../dist/aarch64/nftban-geoip \
  ./cmd/nftban-geoip
```

**Build Flags Explained:**
- `CGO_ENABLED=0`: Static binary (no libc dependency)
- `GOOS=linux`: Target OS
- `GOARCH=amd64|arm64`: Target architecture
- `-ldflags "-s -w"`: Strip debug symbols (smaller binary)
- `-X main.VERSION=0.32.0`: Embed version string

---

### Method 3: Development Build (Faster, no stripping)

```bash
cd go-geoip
go build -o nftban-geoip ./cmd/nftban-geoip
./nftban-geoip version
```

---

## 🧪 Testing After Compilation

### 1. Basic Commands Test
```bash
cd dist/x86_64  # or dist/aarch64

# Version check
./nftban-geoip version
# Expected: nftban-geoip v0.32.0

# Help
./nftban-geoip help

# GeoIP test (requires MaxMind DB)
./nftban-geoip lookup 8.8.8.8

# GeoBan test (dry run without nftables)
./nftban-geoip geoban fetch VA --atomic=false
```

### 2. Unit Tests
```bash
cd go-geoip
go test ./internal/... -v
```

### 3. Integration Test (Requires Root + NFTables)
```bash
# On lab server with nftables configured
sudo ./nftban-geoip geoban fetch VA --action ban --atomic
sudo nft list set inet nftban_main blacklist_v4 | head -20

# Cleanup
sudo ./nftban-geoip geoban remove VA --action ban --atomic
```

---

## 📦 Installation After Build

### Automatic (via build script)
```bash
# Build script already copies to:
src/usr/lib/nftban/bin/.real/nftban-geoip-x86_64
src/usr/lib/nftban/bin/.real/nftban-geoip-aarch64

# Package installer detects architecture and uses correct binary
```

### Manual Installation
```bash
# Copy binary to system
sudo cp dist/x86_64/nftban-geoip /usr/lib/nftban/bin/.real/nftban-geoip-x86_64

# Verify architecture detection works
/usr/bin/nftban geoip version
```

---

## 🐛 Troubleshooting

### Issue 1: "Go not installed"
```bash
# Rocky Linux / AlmaLinux / RHEL
sudo dnf install golang -y

# Ubuntu / Debian
sudo apt install golang -y

# Verify
go version  # Must be 1.21+
```

### Issue 2: "go.mod: no such file"
```bash
# Must be in go-geoip directory
cd go-geoip
ls -l go.mod  # Should exist
```

### Issue 3: "package github.com/google/nftables: not found"
```bash
cd go-geoip
go mod download
go mod tidy
```

### Issue 4: "permission denied" when running binary
```bash
# Option 1: Run as root
sudo ./nftban-geoip geoban fetch CN --action ban

# Option 2: Grant CAP_NET_ADMIN capability
sudo setcap cap_net_admin+ep ./nftban-geoip
./nftban-geoip geoban fetch CN --action ban
```

### Issue 5: "table nftban_main not found"
```bash
# NFTables must be initialized first
sudo nftban init
sudo nft list tables
# Should show: table inet nftban_main
```

### Issue 6: Binary too large (>50MB)
```bash
# Use official build script with stripping
./scripts/build-go-binaries.sh

# Or manually strip
strip --strip-all ./nftban-geoip

# Expected size: 8-12MB (x86_64), 9-13MB (aarch64)
```

---

## 📊 Binary Size Expectations

| Architecture | With Debug | Stripped | Compressed (UPX) |
|--------------|-----------|----------|------------------|
| x86_64 | ~45MB | ~9MB | ~3MB |
| aarch64 | ~50MB | ~10MB | ~3.5MB |

**Current NFTBan policy:** Ship stripped binaries (9-10MB), no UPX compression.

---

## 🔐 Security Considerations

### 1. Static Linking (CGO_ENABLED=0)
- ✅ No libc dependency
- ✅ Works across all Linux distros
- ✅ No dynamic library vulnerabilities
- ⚠️ Slightly larger binary

### 2. Capabilities (Not Setuid)
```bash
# NEVER do this:
sudo chmod u+s /usr/lib/nftban/bin/.real/nftban-geoip  # ❌ INSECURE

# Instead, use capabilities:
sudo setcap cap_net_admin+ep /usr/lib/nftban/bin/.real/nftban-geoip  # ✅ SECURE
```

### 3. Input Validation
- Go binary validates all country codes (2-letter ISO alpha-2)
- CIDRs validated using `netip.ParsePrefix()`
- HTTP downloads limited to 50MB (configurable)

---

## 🚀 Performance Expectations

### Compilation Time
- First build (with dep download): 2-3 minutes
- Incremental build: 10-30 seconds
- Cross-compilation (both arches): 1-2 minutes

### Runtime Performance
| Operation | Time | Memory | CPU |
|-----------|------|--------|-----|
| Fetch country (CN) | 2-5s | 150MB | 5-15% |
| Load 50K IPs | 1-2s | 80MB | 8-12% |
| Load 200K IPs | 3-6s | 250MB | 15-25% |
| GeoIP lookup | <1ms | 200MB (DB cached) | <1% |

---

## 📝 Configuration Validation

After compilation, **always validate** that bash wrappers can read the config:

```bash
# 1. Verify config exists
ls -l /etc/nftban/conf.d/nftban-go.conf

# 2. Source it in bash
source /etc/nftban/conf.d/nftban-go.conf
echo "CPU Limit: $GO_MAX_CPU_PERCENT%"
echo "Memory Limit: $GO_MAX_MEMORY_MB MB"
echo "Chunk Size: $GO_NFT_CHUNK_SIZE"
echo "Cache Dir: $GO_CACHE_DIR"

# 3. Verify paths exist or can be created
sudo mkdir -p "$GO_CACHE_DIR"
sudo mkdir -p "$GEOBAN_FILES_DIR"
sudo mkdir -p "$GEOBAN_CACHE_DIR"
sudo mkdir -p "$(dirname "$GO_LOG_FILE")"
```

---

## 🎯 CI/CD Integration

### GitHub Actions Example
```yaml
name: Build Go Binaries
on: [push]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Setup Go
        uses: actions/setup-go@v4
        with:
          go-version: '1.21'

      - name: Build
        run: ./scripts/build-go-binaries.sh

      - name: Test
        run: |
          cd go-geoip
          go test ./internal/... -v

      - name: Upload Artifacts
        uses: actions/upload-artifact@v3
        with:
          name: binaries
          path: dist/
```

---

## 📚 Additional Resources

- **NFTBan Documentation:** https://docs.nftban.com
- **Go Modules:** https://go.dev/ref/mod
- **NFTables Go Library:** https://github.com/google/nftables
- **MaxMind GeoLite2:** https://dev.maxmind.com/geoip/geoip2/geolite2/
- **IPdeny.com:** https://www.ipdeny.com/ipblocks/

---

## ✅ Pre-Release Checklist

Before releasing a new version with Go binary changes:

- [ ] All unit tests pass (`go test ./...`)
- [ ] Builds successfully for x86_64
- [ ] Builds successfully for aarch64
- [ ] Binary size < 15MB (stripped)
- [ ] `nftban-go.conf` documented with all new settings
- [ ] Integration tests pass on Rocky Linux 9
- [ ] Integration tests pass on Ubuntu 24.04
- [ ] Memory usage < 500MB for 200K IPs
- [ ] CPU usage < 30% during load operations
- [ ] Version number updated in `main.go`
- [ ] CHANGELOG.md updated

---

## 🆘 Support

**Issues?** Check these in order:
1. This guide's Troubleshooting section
2. `/var/log/nftban/go-operations.log`
3. `sudo nftban status --verbose`
4. GitHub Issues: https://github.com/nftban/nftban/issues

---

**Last Updated:** 2025-01-05
**Maintained By:** NFTBan Development Team
**License:** MPL-2.0
