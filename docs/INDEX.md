# NFTBan Documentation Index

**Version:** v0.32.24
**Last Updated:** 2025-11-08
**Repository:** https://github.com/itcmsgr/nftban

---

## 📚 Documentation Structure

All NFTBan documentation is located in `/docs/` directory within the repository. **No external documentation should be used.**

---

## 📖 Core Documentation

### [README.md](README.md)
**Purpose:** Project overview and quick start guide
**Audience:** New users, evaluators
**Contains:** Introduction, installation, basic usage

### [ARCHITECTURE.md](ARCHITECTURE.md)
**Purpose:** System architecture and design decisions
**Audience:** Developers, advanced users
**Contains:** Two-table design, atomic operations, module system

---

## 🔧 Development Documentation

### [CODING_STANDARDS.md](CODING_STANDARDS.md) ⚠️ MANDATORY
**Purpose:** Mandatory coding standards for all NFTBan bash scripts
**Audience:** ALL developers, contributors, AI assistants
**Contains:**
- Error handling (`set -Eeuo pipefail`)
- Arithmetic expressions (avoid `((counter++))` trap)
- Logging standards (no `&>/dev/null`)
- User communication (messages must match reality)
- Cross-distribution compatibility
- Package manager integration
- Real bug lessons learned (v0.32.16-v0.32.19)

**Critical Rules:**
1. ✅ `set -Eeuo pipefail` in ALL scripts
2. ✅ Use `counter=$((counter + 1))` not `((counter++))`
3. ✅ Log to files, NEVER suppress with `&>/dev/null`
4. ✅ Test on ALL distros before merging

### [GO_COMPILATION_GUIDE.md](GO_COMPILATION_GUIDE.md)
**Purpose:** Complete guide for compiling Go binaries
**Audience:** Developers, package maintainers
**Contains:**
- Prerequisites and system requirements
- Build procedures (official script + manual)
- Configuration values reference
- Testing procedures
- Troubleshooting guide

**Key Configuration Values:**
```bash
# CPU/Memory Protection
GO_MAX_CPU_PERCENT=80
GO_MAX_MEMORY_MB=4096
GO_NFT_CHUNK_SIZE=4096

# Network
GO_DOWNLOAD_TIMEOUT=30
GO_MAX_DOWNLOAD_SIZE_MB=50

# Paths
GO_CACHE_DIR=/var/cache/nftban/go-cache
GO_LOG_FILE=/var/log/nftban/go-operations.log
```

### [GO_SYSTEM_PROTECTION.md](GO_SYSTEM_PROTECTION.md)
**Purpose:** System resource protection for Go operations
**Audience:** System administrators, DevOps
**Contains:**
- Systemd service limits (CPU, RAM, I/O)
- Timer configuration (scheduling, overlap prevention)
- Go code protections (chunking, timeouts, memory limits)
- Kernel protection (nftables set limits)
- Monitoring and alerting setup
- Emergency kill switch procedures

**Critical Protection Layers:**
1. **Systemd limits:** CPUQuota=50%, MemoryMax=500M
2. **Go chunking:** 4096 elements per transaction
3. **Timeouts:** 30s per operation, 120s hard limit
4. **ENOBUFS retry:** Automatic retry on buffer full

### [DNS_AND_NETWORK_REQUIREMENTS.md](DNS_AND_NETWORK_REQUIREMENTS.md) ⚠️ IMPORTANT
**Purpose:** DNS requirements and troubleshooting
**Audience:** ALL administrators
**Contains:**
- Why DNS is required for Cloudflare, Feeds, GeoBan
- DNS health check feature
- How to fix broken DNS
- Testing network-dependent features
- Educational content for system administrators

**Critical for:**
- ✅ Cloudflare IP updates
- ✅ Threat feed downloads
- ✅ GeoBan country downloads
- ✅ GeoIP database updates

---

## 🌍 Feature Documentation

### [GEOBAN_FEATURE.md](GEOBAN_FEATURE.md)
**Purpose:** GeoBan country-based blocking feature
**Audience:** Users, administrators
**Contains:**
- Feature overview and use cases
- Command reference (ban, unban, whitelist, list)
- Country code reference (ISO alpha-2)
- IPdeny.com integration details
- Configuration options
- Examples and best practices

**Quick Commands:**
```bash
# Ban countries
nftban geoip ban CN RU KP

# Whitelist countries
nftban geoip whitelist US GB DE

# Remove ban
nftban geoip unban CN

# List active countries
nftban geoip list
```

---

## 📂 Directory Structure

```
nftban/
├── docs/                           # All documentation (THIS DIRECTORY)
│   ├── INDEX.md                    # This file - documentation index
│   ├── README.md                   # Project overview
│   ├── ARCHITECTURE.md             # System architecture
│   ├── GO_COMPILATION_GUIDE.md     # Go build guide
│   ├── GO_SYSTEM_PROTECTION.md     # Resource protection
│   └── GEOBAN_FEATURE.md           # GeoBan feature docs
│
├── go-geoip/                       # GeoIP + GeoBan Go package
│   ├── cmd/nftban-geoip/           # Main binary
│   ├── internal/geoban/            # GeoBan implementation
│   └── go.mod                      # Go dependencies
│
├── go-feeds/                       # Threat feeds Go package
│   ├── cmd/nftban-feeds/           # Feeds binary
│   ├── internal/                   # Internal packages
│   └── go.mod                      # Go dependencies
│
├── src/                            # Source files for installation
│   ├── etc/nftban/                 # Configuration
│   │   ├── conf.d/
│   │   │   ├── nftban-go.conf      # Unified Go config
│   │   │   ├── feeds.conf          # Feed definitions
│   │   │   └── geoip.conf          # GeoIP config
│   │   ├── geoban.d/               # Country IP files
│   │   └── nftban.conf             # Main config
│   │
│   └── usr/lib/nftban/             # Core modules
│       ├── bin/                    # Go binaries wrapper
│       ├── core/                   # Bash core modules
│       └── cli/                    # CLI handlers
│
├── scripts/                        # Build and utility scripts
│   └── build-go-binaries.sh        # Official Go build script
│
├── dist/                           # Build outputs
│   ├── x86_64/                     # Intel/AMD binaries
│   ├── aarch64/                    # ARM64 binaries
│   └── packages/                   # RPM/DEB packages
│
└── packaging/                      # Package specifications
    ├── rpm/                        # RPM spec files
    └── deb/                        # Debian control files
```

---

## 🔍 Finding Information

### "I want to..."

**...install NFTBan**
→ Start with [README.md](README.md)

**...understand the architecture**
→ Read [ARCHITECTURE.md](ARCHITECTURE.md)

**...compile the Go binaries**
→ Follow [GO_COMPILATION_GUIDE.md](GO_COMPILATION_GUIDE.md)

**...protect my system resources**
→ Implement [GO_SYSTEM_PROTECTION.md](GO_SYSTEM_PROTECTION.md)

**...use country blocking**
→ Read [GEOBAN_FEATURE.md](GEOBAN_FEATURE.md)

**...configure safety limits**
→ Edit `/etc/nftban/conf.d/nftban-go.conf` (see GO_COMPILATION_GUIDE.md)

**...troubleshoot build issues**
→ See "Troubleshooting" section in [GO_COMPILATION_GUIDE.md](GO_COMPILATION_GUIDE.md)

**...contribute to the project**
→ Read [ARCHITECTURE.md](ARCHITECTURE.md) + [GO_COMPILATION_GUIDE.md](GO_COMPILATION_GUIDE.md)

---

## 🎯 Quick Reference

### Configuration Files (Priority Order)

1. `/etc/nftban/nftban.conf` - Main configuration
2. `/etc/nftban/conf.d/*.conf` - Module configurations
3. `/etc/nftban/conf.d/*.conf.local` - User overrides (preserved on upgrade)

### Go Binary Configuration

**Single unified config:** `/etc/nftban/conf.d/nftban-go.conf`

**Applies to:**
- `nftban-geoip` (GeoIP lookups + GeoBan)
- `nftban-feeds` (Threat intelligence feeds)

**Key sections:**
- System Safety (CPU, RAM, I/O limits)
- HTTP Caching (ETag support)
- Threat Feeds settings
- GeoBan settings
- GeoIP settings
- NFTables integration

### Go Binaries

| Binary | Purpose | Commands |
|--------|---------|----------|
| `nftban-geoip` | GeoIP + GeoBan | lookup, bulk, status, test, geoban fetch, geoban remove |
| `nftban-feeds` | Threat feeds | sync, parse, validate, stats |

**Location:** `/usr/lib/nftban/bin/.real/nftban-{geoip,feeds}-{x86_64,aarch64}`

### Build Commands

```bash
# Official build (both architectures)
./scripts/build-go-binaries.sh

# Manual x86_64 build
cd go-geoip
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -buildvcs=false -ldflags "-s -w -X main.VERSION=0.32.0" \
  -o ../dist/x86_64/nftban-geoip ./cmd/nftban-geoip

# Manual aarch64 build
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
  go build -buildvcs=false -ldflags "-s -w -X main.VERSION=0.32.0" \
  -o ../dist/aarch64/nftban-geoip ./cmd/nftban-geoip
```

### System Protection Values

| Setting | Default | Purpose |
|---------|---------|---------|
| `GO_MAX_CPU_PERCENT` | 80 | Max CPU before throttling |
| `GO_MAX_MEMORY_MB` | 4096 | Hard memory limit |
| `GO_NFT_CHUNK_SIZE` | 4096 | Elements per nftables transaction |
| `GO_DOWNLOAD_TIMEOUT` | 30 | HTTP timeout (seconds) |
| `GO_MAX_DOWNLOAD_SIZE_MB` | 50 | Max file download size |
| `GO_NFT_ENOBUFS_RETRY` | true | Retry on buffer full |
| `GO_DELTA_LIMIT_ENABLED` | true | Prevent 10x+ changes |

---

## 📊 Testing Checklist

Before production deployment:

### Build Testing
- [ ] Builds successfully for x86_64
- [ ] Builds successfully for aarch64
- [ ] Binary size < 15MB (stripped)
- [ ] Version command works
- [ ] Help command shows all features

### Functional Testing
- [ ] GeoIP lookup works (test with 8.8.8.8)
- [ ] GeoBan fetch works (test with VA - Vatican City)
- [ ] GeoBan remove works
- [ ] Config file generated correctly
- [ ] Tracking JSON created

### Integration Testing
- [ ] NFTables integration works (requires root)
- [ ] Atomic operations work (no gaps)
- [ ] Chunking works (large countries like CN, US)
- [ ] HTTP caching works (ETag)
- [ ] Error handling works (invalid country, network failure)

### Safety Testing
- [ ] CPU usage stays under limit (watch during load)
- [ ] Memory usage stays under limit (test with large country)
- [ ] Timeouts trigger correctly (simulate slow network)
- [ ] ENOBUFS retry works (large atomic transaction)

### System Testing
- [ ] Works on Rocky Linux 9
- [ ] Works on Ubuntu 24.04
- [ ] Works on CentOS Stream 10
- [ ] Systemd service starts correctly
- [ ] Logs appear in correct location

---

## 🆘 Support Resources

**Documentation Issues:**
- Check this INDEX.md first
- Search within specific document using `/` (less command)
- All answers should be in `/docs/` - no external sources

**Build Issues:**
- See [GO_COMPILATION_GUIDE.md](GO_COMPILATION_GUIDE.md) Troubleshooting section

**Runtime Issues:**
- Check `/var/log/nftban/go-operations.log`
- See [GO_SYSTEM_PROTECTION.md](GO_SYSTEM_PROTECTION.md) for monitoring

**Feature Questions:**
- GeoBan: See [GEOBAN_FEATURE.md](GEOBAN_FEATURE.md)
- Architecture: See [ARCHITECTURE.md](ARCHITECTURE.md)

**Community:**
- GitHub Issues: https://github.com/nftban/nftban/issues
- Discussions: https://github.com/nftban/nftban/discussions

---

## 📝 Documentation Guidelines

### For Contributors

When adding new features:

1. **Update relevant docs** in `/docs/` directory
2. **Add to this INDEX.md** if creating new major documentation
3. **Keep documentation in repository** - no external docs
4. **Use relative links** for cross-references
5. **Include configuration examples** with actual values
6. **Document safety limits** if adding resource-intensive features

### Documentation Standards

- **Format:** Markdown (.md)
- **Location:** `/docs/` directory only
- **Linking:** Use relative paths `[text](FILE.md)`
- **Code blocks:** Use triple backticks with language identifier
- **Headers:** Use ATX style (`#` syntax)
- **Line length:** Soft wrap at 100 chars (not enforced)

---

## 🔄 Update History

| Date | Changes | Updated By |
|------|---------|------------|
| 2025-11-08 | Added CODING_STANDARDS.md (comprehensive) | NFTBan Team + Claude Code |
| 2025-11-05 | Initial documentation consolidation | NFTBan Team |
| 2025-11-05 | Added GeoBan feature documentation | NFTBan Team |
| 2025-11-05 | Created unified nftban-go.conf | NFTBan Team |
| 2025-11-05 | Added system protection guide | NFTBan Team |

---

**Last Updated:** 2025-11-08
**Maintained By:** NFTBan Development Team
**License:** MPL-2.0
