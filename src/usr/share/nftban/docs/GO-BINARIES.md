# NFTBan Go Binaries - Complete Architecture & Build Guide

**Version:** v0.10.0
**Purpose:** Documentation for Go binary architecture, building, and deployment
**Last Updated:** 2025-10-30

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Directory Structure](#directory-structure)
4. [Go Binaries](#go-binaries)
5. [Building Binaries](#building-binaries)
6. [How Building Works](#how-building-works)
7. [Automated Building (GitHub Actions)](#automated-building-github-actions)
8. [Testing Go Binaries](#testing-go-binaries)
9. [Troubleshooting](#troubleshooting)

---

## Overview

NFTBan includes two high-performance Go binaries that provide 10-60x faster processing compared to pure Bash implementations:

- **nftban-feeds**: Fast threat feed processing and IP extraction
- **nftban-geoip**: High-speed GeoIP database lookups and country blocking

These binaries are:
- **Statically compiled** (no external dependencies)
- **Cross-platform** (x86_64 and aarch64/ARM64)
- **Small footprint** (typically 5-10 MB each)
- **High performance** (optimized with `-ldflags "-s -w"`)

---

## Architecture

### Design Philosophy

```
┌─────────────────────────────────────────────────────────────┐
│                    NFTBan Architecture                      │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Bash Shell Scripts (Core)                                 │
│  ├─ Main CLI (/usr/sbin/nftban)                           │
│  ├─ Core modules (/usr/lib/nftban/core/*.sh)              │
│  └─ CLI commands (/usr/lib/nftban/cli/*.sh)               │
│                                                             │
│  Go Binaries (Performance-Critical Tasks)                  │
│  ├─ nftban-feeds  → Feed processing (10-60x faster)       │
│  └─ nftban-geoip  → GeoIP lookups (10-60x faster)         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Why Go + Bash?

| Component | Language | Reason |
|-----------|----------|--------|
| Core CLI & Logic | Bash | Native to Linux, no compilation, easy to audit |
| Feed Processing | Go | High-speed parsing of large threat feeds |
| GeoIP Lookups | Go | Fast binary search in GeoIP databases |

**Result:** Best of both worlds - maintainable Bash scripts with Go performance where it matters.

---

## Directory Structure

```
nftban/
│
├── go-feeds/                          # Go source: nftban-feeds
│   ├── cmd/
│   │   └── nftban-feeds/
│   │       └── main.go                # Entry point
│   ├── go.mod                         # Go module definition
│   ├── go.sum                         # Dependency checksums
│   └── README.md                      # Feed processor docs
│
├── go-geoip/                          # Go source: nftban-geoip
│   ├── cmd/
│   │   └── nftban-geoip/
│   │       └── main.go                # Entry point
│   ├── go.mod                         # Go module definition
│   ├── go.sum                         # Dependency checksums
│   └── README.md                      # GeoIP processor docs
│
├── scripts/
│   └── build-go-binaries.sh           # Build script (compiles both)
│
├── dist/                              # Build output (gitignored)
│   ├── x86_64/                        # AMD64 binaries
│   │   ├── nftban-feeds
│   │   └── nftban-geoip
│   └── aarch64/                       # ARM64 binaries
│       ├── nftban-feeds
│       └── nftban-geoip
│
└── src/usr/lib/nftban/bin/            # Binaries for packaging
    ├── nftban-feeds                   # Copied from dist/{arch}/
    └── nftban-geoip                   # Copied from dist/{arch}/
```

### What Gets Packaged?

RPM and DEB packages install the architecture-appropriate binaries to:
```
/usr/lib/nftban/bin/nftban-feeds
/usr/lib/nftban/bin/nftban-geoip
```

---

## Go Binaries

### nftban-feeds

**Purpose:** Fast processing of threat intelligence feeds

**Features:**
- Parse multiple feed formats (CSV, JSON, plain text)
- Extract IP addresses and CIDR ranges
- Deduplicate entries
- Format for nftables consumption
- Memory-efficient streaming

**Source:** `go-feeds/cmd/nftban-feeds/main.go`

**Performance:**
- Processes 100,000 IPs in ~0.5 seconds
- 10-60x faster than Bash/awk equivalents

**Usage from Bash:**
```bash
/usr/lib/nftban/bin/nftban-feeds \
  --input /tmp/threat-feed.txt \
  --output /tmp/processed-ips.nft \
  --format nftables
```

### nftban-geoip

**Purpose:** High-speed GeoIP database lookups

**Features:**
- MaxMind GeoLite2/GeoIP2 database support
- Binary search for fast lookups
- Batch processing support
- Country code extraction
- IPv4 and IPv6 support

**Source:** `go-geoip/cmd/nftban-geoip/main.go`

**Performance:**
- Lookups: ~50,000 per second
- 10-60x faster than Bash-based solutions

**Usage from Bash:**
```bash
/usr/lib/nftban/bin/nftban-geoip \
  --database /var/lib/nftban/geoip/GeoLite2-City.mmdb \
  --ip 8.8.8.8 \
  --format json
```

---

## Building Binaries

### Prerequisites

**Required:**
- Go 1.21 or later
- Git

**Install Go:**

```bash
# Rocky Linux / AlmaLinux / Fedora
sudo dnf install golang

# Ubuntu / Debian
sudo apt install golang-go

# Verify installation
go version
# Expected: go version go1.21.x linux/amd64
```

### Manual Build (Local Development)

```bash
# Clone repository
git clone https://github.com/itcmsgr/nftban.git
cd nftban

# Build both binaries (x86_64 and aarch64)
./scripts/build-go-binaries.sh

# Output:
# ═══════════════════════════════════════════════════════════
# Building nftban-feeds
# ═══════════════════════════════════════════════════════════
#   → Downloading dependencies...
#   → Building x86_64 binary...
#   ✓ x86_64:  5.2MiB
#   ✓ aarch64: 5.0MiB
#
# ═══════════════════════════════════════════════════════════
# Building nftban-geoip
# ═══════════════════════════════════════════════════════════
#   → Downloading dependencies...
#   → Building x86_64 binary...
#   ✓ x86_64:  6.1MiB
#   ✓ aarch64: 5.9MiB
#
# ═══════════════════════════════════════════════════════════
# Build Complete
# ═══════════════════════════════════════════════════════════
```

### Build on Lab Servers

```bash
# Build on lab2.example.test (recommended build server)
ssh root@lab2.example.test

cd /root/nftban
git pull origin main

# Install Go if not present
dnf install -y golang

# Build binaries
./scripts/build-go-binaries.sh

# Binaries available at:
# - dist/x86_64/nftban-feeds
# - dist/x86_64/nftban-geoip
# - dist/aarch64/nftban-feeds
# - dist/aarch64/nftban-geoip
```

### Build Individual Binaries

```bash
# Build only nftban-feeds
cd go-feeds
go build -o ../dist/nftban-feeds ./cmd/nftban-feeds

# Build only nftban-geoip
cd go-geoip
go build -o ../dist/nftban-geoip ./cmd/nftban-geoip
```

---

## How Building Works

### Build Script Flow

```
┌─────────────────────────────────────────────────────────────┐
│  scripts/build-go-binaries.sh Execution Flow               │
└─────────────────────────────────────────────────────────────┘

1. Check Go Installation
   ├─ Verify go command exists
   ├─ Check Go version (require 1.21+)
   └─ Display version info

2. Create Output Directories
   ├─ dist/x86_64/
   └─ dist/aarch64/

3. Build nftban-feeds
   ├─ cd go-feeds/
   ├─ go mod download (fetch dependencies)
   ├─ Build x86_64:
   │   CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
   │     go build -ldflags "-s -w -X main.version=0.10.0" \
   │     -o dist/x86_64/nftban-feeds ./cmd/nftban-feeds
   └─ Build aarch64:
       CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
         go build -ldflags "-s -w -X main.version=0.10.0" \
         -o dist/aarch64/nftban-feeds ./cmd/nftban-feeds

4. Build nftban-geoip
   ├─ cd go-geoip/
   ├─ go mod download
   ├─ Build x86_64 (same flags)
   └─ Build aarch64 (same flags)

5. Copy Binaries to src/
   ├─ Detect current architecture (uname -m)
   ├─ Copy appropriate binaries to src/usr/lib/nftban/bin/
   └─ Set executable permissions (chmod +x)

6. Display Summary
   ├─ Binary sizes
   ├─ Output paths
   └─ Success message
```

### Build Flags Explained

```bash
CGO_ENABLED=0                          # Disable CGO (static linking)
GOOS=linux                             # Target OS: Linux
GOARCH=amd64                           # Target architecture: x86_64
-ldflags "-s -w -X main.version=0.10.0"
         │   │  └─ Set version variable
         │   └─ Strip DWARF debug info (smaller binary)
         └─ Strip symbol table (smaller binary)
```

**Result:** Statically compiled, stripped binaries with no external dependencies

---

## Automated Building (GitHub Actions)

### Workflow Trigger

GitHub Actions automatically builds Go binaries when you push a version tag:

```bash
# Create and push version tag
git tag v0.10.1
git push --tags

# GitHub Actions workflow (.github/workflows/release.yml) runs:
# 1. Sets up Go 1.21
# 2. Runs scripts/build-go-binaries.sh
# 3. Builds RPM packages (includes Go binaries)
# 4. Builds DEB packages (includes Go binaries)
# 5. Creates GitHub Release with all artifacts
```

### Workflow File

**Location:** `.github/workflows/release.yml`

**Steps:**
```yaml
- name: Set up Go
  uses: actions/setup-go@v5
  with:
    go-version: '1.21'

- name: Build Go binaries (x86_64 and aarch64)
  run: |
    chmod +x scripts/build-go-binaries.sh
    ./scripts/build-go-binaries.sh

- name: Build RPM packages
  run: ./scripts/build-rpm.sh

- name: Build DEB packages
  run: ./scripts/build-deb.sh

- name: Upload to GitHub Release
  uses: softprops/action-gh-release@v2
  with:
    files: |
      dist/packages/*.rpm
      dist/packages/*.deb
      dist/packages/SHA256SUMS
```

### Release Artifacts

Each release includes:
- `nftban-0.10.0-1.el9.x86_64.rpm` (includes x86_64 Go binaries)
- `nftban-0.10.0-1.el9.aarch64.rpm` (includes aarch64 Go binaries)
- `nftban_0.10.0-1_amd64.deb` (includes x86_64 Go binaries)
- `nftban_0.10.0-1_arm64.deb` (includes aarch64 Go binaries)
- `SHA256SUMS` (checksums for verification)

---

## Testing Go Binaries

### Test nftban-feeds

```bash
# After building
./dist/x86_64/nftban-feeds --version
# Expected: nftban-feeds v0.10.0

# Test feed processing
echo "192.0.2.1" > /tmp/test-feed.txt
echo "198.51.100.0/24" >> /tmp/test-feed.txt

./dist/x86_64/nftban-feeds \
  --input /tmp/test-feed.txt \
  --output /tmp/processed.txt

cat /tmp/processed.txt
# Expected: Processed IPs in nftables format
```

### Test nftban-geoip

```bash
# After building
./dist/x86_64/nftban-geoip --version
# Expected: nftban-geoip v0.10.0

# Test GeoIP lookup (requires GeoLite2 database)
./dist/x86_64/nftban-geoip \
  --database /var/lib/nftban/geoip/GeoLite2-City.mmdb \
  --ip 8.8.8.8

# Expected: Country code (US)
```

### Test Installed Binaries

```bash
# After RPM/DEB installation
/usr/lib/nftban/bin/nftban-feeds --version
/usr/lib/nftban/bin/nftban-geoip --version

# Verify file permissions
ls -la /usr/lib/nftban/bin/
# Expected:
# -rwxr-xr-x. 1 root root 5.2M nftban-feeds
# -rwxr-xr-x. 1 root root 6.1M nftban-geoip
```

---

## Troubleshooting

### Issue 1: Go Not Installed

**Symptom:**
```
ERROR: Go is not installed
```

**Solution:**
```bash
# Rocky Linux / AlmaLinux
sudo dnf install golang

# Ubuntu / Debian
sudo apt install golang-go

# Verify
go version
```

### Issue 2: Build Fails - Missing Dependencies

**Symptom:**
```
ERROR: Failed to download go-feeds dependencies
```

**Solution:**
```bash
# Clear Go module cache
go clean -modcache

# Try again
./scripts/build-go-binaries.sh
```

### Issue 3: Permission Denied

**Symptom:**
```
bash: ./scripts/build-go-binaries.sh: Permission denied
```

**Solution:**
```bash
chmod +x scripts/build-go-binaries.sh
./scripts/build-go-binaries.sh
```

### Issue 4: Binary Not Found After Installation

**Symptom:**
```
/usr/lib/nftban/bin/nftban-feeds: No such file or directory
```

**Solution:**
```bash
# Check if binaries were packaged
rpm -ql nftban | grep bin/

# If missing, rebuild package:
./scripts/build-go-binaries.sh
./scripts/build-rpm.sh
```

### Issue 5: Architecture Mismatch

**Symptom:**
```
cannot execute binary file: Exec format error
```

**Solution:**
```bash
# Check binary architecture
file /usr/lib/nftban/bin/nftban-feeds

# Rebuild for correct architecture
./scripts/build-go-binaries.sh
```

---

## Performance Benchmarks

### Feed Processing (100,000 IPs)

| Implementation | Time | Speedup |
|----------------|------|---------|
| Pure Bash | 30.5 seconds | 1x (baseline) |
| Bash + awk | 5.2 seconds | 5.9x faster |
| Go (nftban-feeds) | 0.5 seconds | **61x faster** |

### GeoIP Lookups (10,000 IPs)

| Implementation | Time | Speedup |
|----------------|------|---------|
| Pure Bash | 125 seconds | 1x (baseline) |
| Python + geoip2 | 8.3 seconds | 15x faster |
| Go (nftban-geoip) | 0.2 seconds | **625x faster** |

---

## Development Guidelines

### Adding New Go Features

1. Create new directory under project root:
   ```bash
   mkdir go-newfeature
   cd go-newfeature
   go mod init github.com/itcmsgr/nftban/go-newfeature
   ```

2. Create entry point:
   ```bash
   mkdir -p cmd/nftban-newfeature
   # Create cmd/nftban-newfeature/main.go
   ```

3. Add to build script:
   ```bash
   # Edit scripts/build-go-binaries.sh
   # Add build section for new binary
   ```

4. Update packaging:
   ```bash
   # Edit packaging/rpm/nftban.spec
   # Add new binary to %files section
   ```

### Code Style

- Follow Go standard formatting (`gofmt`)
- Use meaningful variable names
- Add comments for exported functions
- Include error handling
- Write unit tests

---

## Summary

### Key Points

✅ **Two Go Binaries:** nftban-feeds and nftban-geoip
✅ **Statically Compiled:** No external dependencies
✅ **Cross-Platform:** x86_64 and aarch64 support
✅ **Performance:** 10-60x faster than Bash
✅ **Automated Building:** GitHub Actions builds on version tags
✅ **Packaged:** Included in RPM and DEB packages

### Quick Reference

```bash
# Build binaries
./scripts/build-go-binaries.sh

# Test binaries
./dist/x86_64/nftban-feeds --version
./dist/x86_64/nftban-geoip --version

# Create release (automated build)
git tag v0.10.1
git push --tags
```

---

**Last Updated:** 2025-10-30
**For Issues:** https://github.com/itcmsgr/nftban/issues
**Documentation:** https://github.com/itcmsgr/nftban/tree/main/docs
