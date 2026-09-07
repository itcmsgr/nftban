# Reproducible Builds Verification

This document describes how to reproduce and verify NFTBan release binaries from source code.

## 1. Build Requirements

### Go Version

The project requires **Go 1.25.13** (as specified in `go.mod`). Release binaries are
built with exactly this toolchain, and a pre-publication gate rejects any shipped binary
whose embedded compiler is not the `go.mod` version.

```bash
# Verify your Go version
go version
# Expected output: go version go1.25.13 linux/amd64
```

### Required System Packages

**For CGO-disabled builds (nftban-core):**
- Go 1.25.13
- No additional system dependencies

**For CGO-enabled builds (nftband):**
- Go 1.25.13
- GCC compiler (build-essential on Debian/Ubuntu)

```bash
# Debian/Ubuntu
sudo apt-get install -y build-essential

# RHEL/Fedora/Rocky
sudo dnf install -y gcc
```

### Environment Variables

| Variable | Value | Description |
|----------|-------|-------------|
| `CGO_ENABLED` | `0` | For SLSA builds (nftban-core) |
| `CGO_ENABLED` | `1` | For CGO builds (nftband) |
| `GOOS` | `linux` | Target operating system |
| `GOARCH` | `amd64` | Target architecture |

## 2. Deterministic Build Commands

### SLSA-Verified Binaries (Recommended)

The official release binary for `nftban-core` is built using the [SLSA Go Builder](https://github.com/slsa-framework/slsa-github-generator) which provides SLSA Level 3 compliance. These builds are:

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
```

Replace `vX.Y.Z` with the actual version tag (e.g., `v1.18.0`).

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

# nftband (IPC daemon)
./build.sh daemon
```

## 3. Verification Procedure

### Step 1: Download Release Artifacts

```bash
VERSION="v1.18.0"  # Replace with target version

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

NFTBan releases include [SLSA Level 3](https://slsa.dev/spec/v1.0/levels) provenance for `nftban-core`. This cryptographically proves the binary was built from the claimed source code.

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

### Verify Specific Version

```bash
slsa-verifier verify-artifact nftban-core-linux-amd64 \
  --provenance-path nftban-core-linux-amd64.intoto.jsonl \
  --source-uri github.com/itcmsgr/nftban \
  --source-tag v1.18.0
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
- **DEB packages:** `nftban-ubuntu22.04-amd64.deb`, `nftban-ubuntu24.04-amd64.deb`, `nftban-ubuntu26.04-amd64.deb`, `nftban-debian12-amd64.deb`, `nftban-debian13-amd64.deb`
- **Binaries:** `nftban-core-linux-amd64`, `nftband-linux-amd64`

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

### Factors Affecting Reproducibility

| Factor | Impact | Mitigation |
|--------|--------|------------|
| Go version | Different binaries | Pin to Go 1.25.13 (enforced pre-publication) |
| `-trimpath` flag | Removes local paths | Always use `-trimpath` |
| `-s -w` ldflags | Strips debug info | Always use both flags |
| Build timestamp | May be embedded | Stripped by `-s -w` |
| Module cache | Different downloads | Use `go mod download` first |

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

---

## Build-Tree Cleanliness and `vcs.modified`

Go's VCS stamper records `vcs.modified=true` when the working tree is not clean at the moment
of compilation, and the module version gains a `+dirty` suffix. That marker is a provenance
qualification: it does not mean the binary is corrupt or built from the wrong revision, but it
does mean the tree contained something git did not track.

Two distinct producers were found and fixed in this project, and they are **not** the same
cause:

| build path | producer | fixed in | confirmed |
|---|---|---|---|
| `release.yml` (`nftband`) | CI runs Python authorities; Python writes `__pycache__/` | v1.229.4 | v1.229.4 artifact |
| SLSA builder (`nftban-core`) | `builder_go_slsa3.yml` runs `go mod vendor` in the project checkout before compiling | v1.229.6 | v1.229.6 artifact |

Both directories are ignored, so neither tool dirties the tree it is about to have stamped.

As of v1.229.6, every declared shipped Go binary is checked **before publication**: the
embedded compiler must be the `go.mod` toolchain and `vcs.modified` must be `false`. Metadata
that cannot be read is a failure, not a skip. The check reads embedded build information; it
does not execute the binary.

You can observe the same values on any published binary without running it:

```bash
grep -aoE 'go1\.[0-9.]+' nftban-core-linux-amd64 | sort -u
grep -aoE 'vcs\.(modified|revision)=[^[:space:]]*' nftban-core-linux-amd64 | sort -u
```
