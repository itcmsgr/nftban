# Reproducible Builds Verification

This document describes how to reproduce and verify NFTBan release binaries from source code.

## 1. Build Requirements

### Go Version

The project requires **Go 1.23.0** or later (as specified in `go.mod`).

```bash
# Verify your Go version
go version
# Expected output: go version go1.23.x linux/amd64
```

### Required System Packages

**For CGO-disabled builds (nftban-core, nftban-ui):**
- Go 1.23+
- No additional system dependencies

**For CGO-enabled builds (nftban-ui-auth, nftband):**
- Go 1.23+
- GCC compiler (build-essential on Debian/Ubuntu)
- PAM development headers (for nftban-ui-auth only)

```bash
# Debian/Ubuntu
sudo apt-get install -y build-essential libpam0g-dev

# RHEL/Fedora/Rocky
sudo dnf install -y gcc pam-devel
```

### Environment Variables

| Variable | Value | Description |
|----------|-------|-------------|
| `CGO_ENABLED` | `0` | For SLSA builds (nftban-core, nftban-ui) |
| `CGO_ENABLED` | `1` | For PAM builds (nftban-ui-auth) |
| `GOOS` | `linux` | Target operating system |
| `GOARCH` | `amd64` | Target architecture |

## 2. Deterministic Build Commands

### SLSA-Verified Binaries (Recommended)

The official release binaries for `nftban-core` and `nftban-ui` are built using the [SLSA Go Builder](https://github.com/slsa-framework/slsa-github-generator) which provides SLSA Level 3 compliance. These builds are:

- Hermetic (isolated build environment)
- Reproducible (deterministic output)
- Cryptographically signed with provenance

**To reproduce the exact SLSA build:**

```bash
# nftban-core
CGO_ENABLED=0 go build -trimpath \
  -ldflags="-s -w -X github.com/itcmsgr/nftban/pkg/version.FullVersion=vX.Y.Z" \
  -o nftban-core-linux-amd64 \
  ./cmd/nftban-core

# nftban-ui
CGO_ENABLED=0 go build -trimpath \
  -ldflags="-s -w -X main.Version=vX.Y.Z" \
  -o nftban-ui-linux-amd64 \
  ./cmd/nftban-ui
```

Replace `vX.Y.Z` with the actual version tag (e.g., `v1.16.0`).

### Local Development Build

For local development with all binaries (including CGO-dependent ones):

```bash
# Clone the repository
git clone https://github.com/itcmsgr/nftban.git
cd nftban

# Checkout the release tag
git checkout vX.Y.Z

# Run the build script
./build.sh all

# Binaries are output to bin/
ls -la bin/
```

### Individual Component Builds

```bash
# nftban-core only
./build.sh core

# nftban-ui only (requires templ code generation)
./build.sh gui

# nftban-ui-auth only (requires CGO + PAM)
./build.sh ui-auth

# nftband (IPC daemon)
./build.sh daemon
```

## 3. Verification Procedure

### Step 1: Download Release Artifacts

```bash
VERSION="v1.16.0"  # Replace with target version

# Download binary and provenance
wget "https://github.com/itcmsgr/nftban/releases/download/${VERSION}/nftban-core-linux-amd64"
wget "https://github.com/itcmsgr/nftban/releases/download/${VERSION}/nftban-core-linux-amd64.intoto.jsonl"
wget "https://github.com/itcmsgr/nftban/releases/download/${VERSION}/SHA256SUMS"
```

### Step 2: Verify SHA256 Checksums

```bash
# Download checksums file
wget "https://github.com/itcmsgr/nftban/releases/download/${VERSION}/SHA256SUMS"

# Verify the binary
sha256sum -c SHA256SUMS --ignore-missing
```

### Step 3: Reproduce the Build

```bash
# Clone at the exact release tag
git clone --depth 1 --branch "${VERSION}" https://github.com/itcmsgr/nftban.git
cd nftban

# Build with identical flags
CGO_ENABLED=0 go build -trimpath \
  -ldflags="-s -w -X github.com/itcmsgr/nftban/pkg/version.FullVersion=${VERSION}" \
  -o my-nftban-core \
  ./cmd/nftban-core

# Compare checksums
sha256sum nftban-core-linux-amd64 my-nftban-core
```

**Note:** Local builds may not match byte-for-byte due to:
- Different Go toolchain patch versions
- Different build timestamps embedded in debug info (mitigated by `-s -w`)
- Different module cache state

For cryptographic verification, use SLSA provenance instead.

## 4. SLSA Provenance Verification

NFTBan releases include [SLSA Level 3](https://slsa.dev/spec/v1.0/levels) provenance for `nftban-core` and `nftban-ui`. This cryptographically proves the binary was built from the claimed source code.

### Install slsa-verifier

```bash
# Using Go
go install github.com/slsa-framework/slsa-verifier/v2/cli/slsa-verifier@latest

# Or download pre-built binary
wget https://github.com/slsa-framework/slsa-verifier/releases/latest/download/slsa-verifier-linux-amd64
chmod +x slsa-verifier-linux-amd64
sudo mv slsa-verifier-linux-amd64 /usr/local/bin/slsa-verifier
```

### Verify nftban-core

```bash
slsa-verifier verify-artifact nftban-core-linux-amd64 \
  --provenance-path nftban-core-linux-amd64.intoto.jsonl \
  --source-uri github.com/itcmsgr/nftban
```

### Verify nftban-ui

```bash
slsa-verifier verify-artifact nftban-ui-linux-amd64 \
  --provenance-path nftban-ui-linux-amd64.intoto.jsonl \
  --source-uri github.com/itcmsgr/nftban
```

### Verify Specific Version

```bash
slsa-verifier verify-artifact nftban-core-linux-amd64 \
  --provenance-path nftban-core-linux-amd64.intoto.jsonl \
  --source-uri github.com/itcmsgr/nftban \
  --source-tag v1.16.0
```

### Expected Output

```
Verified signature against tance: &#10003;
Verified build identity: slsa-framework/slsa-github-generator
PASSED: Verified SLSA provenance
```

## 5. SHA256 Checksums

### Where to Find Checksums

Checksums are published in `SHA256SUMS` with each GitHub release:

```
https://github.com/itcmsgr/nftban/releases/download/vX.Y.Z/SHA256SUMS
```

### What's Included

The `SHA256SUMS` file contains checksums for:

- **RPM packages:** `nftban-el9-x86_64.rpm`, `nftban-el10-x86_64.rpm`
- **DEB packages:** `nftban-ubuntu22.04-amd64.deb`, `nftban-ubuntu24.04-amd64.deb`, `nftban-debian12-amd64.deb`, `nftban-debian13-amd64.deb`
- **Binaries:** `nftban-core-linux-amd64`, `nftban-ui-linux-amd64`, `nftband-linux-amd64`, `nftban-ui-auth-linux-amd64`

### Verification Commands

```bash
# Verify all downloaded files
sha256sum -c SHA256SUMS

# Verify only what you have (ignore missing)
sha256sum -c SHA256SUMS --ignore-missing

# Manual verification of single file
sha256sum nftban-core-linux-amd64
# Compare output with SHA256SUMS content
```

### Additional Artifacts

| File | Purpose |
|------|---------|
| `MANIFEST.txt` | Human-readable package inventory |
| `VERIFY.txt` | Installation and verification guide |
| `sbom.spdx.json` | Software Bill of Materials (SPDX format) |
| `*.intoto.jsonl` | SLSA provenance attestations |

## 6. Known Limitations

### CGO and PAM Dependencies

**`nftban-ui-auth` cannot be built with SLSA provenance** because it requires:
- CGO enabled (`CGO_ENABLED=1`)
- PAM development headers (`libpam0g-dev` / `pam-devel`)

The SLSA hermetic build environment does not support external C dependencies. This binary is built via the standard release workflow instead and verified via SHA256 checksums only.

### Templ Code Generation

**`nftban-ui` requires templ code generation** before building:

```bash
# Install templ
go install github.com/a-h/templ/cmd/templ@latest

# Generate Go code from .templ files
templ generate

# Then build
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" ./cmd/nftban-ui
```

The SLSA workflow handles this automatically, but local builds must run `templ generate` first.

### Factors Affecting Reproducibility

| Factor | Impact | Mitigation |
|--------|--------|------------|
| Go version | Different binaries | Pin to Go 1.23 |
| `-trimpath` flag | Removes local paths | Always use `-trimpath` |
| `-s -w` ldflags | Strips debug info | Always use both flags |
| Build timestamp | May be embedded | Stripped by `-s -w` |
| Module cache | Different downloads | Use `go mod download` first |
| Templ version | Different generated code | Pin templ version |

### What SLSA Provenance Proves

SLSA Level 3 provenance guarantees:

1. **Source integrity:** Binary was built from the claimed git commit
2. **Build isolation:** Build ran in an isolated, ephemeral environment
3. **Non-falsifiable:** Provenance is cryptographically signed by Sigstore
4. **Tamper-evident:** Any modification invalidates the signature

It does **not** guarantee:
- The source code is free of vulnerabilities
- The build environment was free of malware (though highly unlikely with GitHub Actions)
- Byte-for-byte reproducibility across different build environments

## References

- [SLSA Framework](https://slsa.dev/)
- [SLSA Go Builder](https://github.com/slsa-framework/slsa-github-generator)
- [slsa-verifier](https://github.com/slsa-framework/slsa-verifier)
- [Sigstore](https://www.sigstore.dev/)
- [Go Build Reproducibility](https://go.dev/doc/go1.21#build)
