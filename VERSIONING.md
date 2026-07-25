# NFTBan Versioning System

**Single Source of Truth:** All version numbers come from the `VERSION` file.

## How It Works

```
VERSION file (1.0.5)
    ├─→ Go binaries    (injected via ldflags during build)
    ├─→ Bash scripts   (read from cli/lib/nftban/lib/version.sh)
    ├─→ RPM packages   (read by packaging/build_nftban.sh)
    ├─→ DEB packages   (read by packaging/build_nftban.sh)
    └─→ GitHub Actions (read during release workflow)
```

## The VERSION File

**Location:** `/VERSION`

**Content:** Single line with version number (no 'v' prefix)

```
1.0.5
```

That's it! One file, one line, one truth.

## Making a Release

### Option 1: Bump Version Automatically (Recommended)

```bash
# Bump patch version (1.0.5 → 1.0.6)
./scripts/bump-version.sh patch

# Bump minor version (1.0.5 → 1.1.0)
./scripts/bump-version.sh minor

# Bump major version (1.0.5 → 2.0.0)
./scripts/bump-version.sh major

# Set specific version
./scripts/bump-version.sh 1.2.3
```

### Option 2: Manual Update

```bash
# Edit VERSION file
echo "1.0.6" > VERSION

# Commit
git add VERSION
git commit -m "chore: Bump version to 1.0.6"
```

### Option 3: Tag and Release

```bash
# After bumping version, create a tag
git tag v1.0.6 -m "Release v1.0.6"

# Push tag (triggers GitHub release workflow)
git push origin v1.0.6
```

**The release workflow automatically:**
1. Reads version from `VERSION` file
2. Builds all packages
3. Creates GitHub Release
4. Uploads packages to release
5. Makes them available at download URLs

## No More Manual Updates!

**Before (BAD):** Update version in 50+ files manually
```
pkg/version/version.go
cli/lib/nftban/lib/version.sh
packaging/build_nftban.sh
... 47 more files
```

**After (GOOD):** Update ONE file
```
VERSION
```

## Where Versions Are Used

### 1. Go Binaries

**Injected during build:**
```bash
./build.sh
# Reads VERSION file
# Builds with: -ldflags "-X github.com/itcmsgr/nftban/pkg/version.Version=1.0.5"
```

**Usage in code:**
```go
import "github.com/itcmsgr/nftban/pkg/version"

fmt.Println(version.Version)     // "1.0.5"
fmt.Println(version.FullVersion()) // "v1.0.5"
```

### 2. Bash Scripts

**Auto-loaded from VERSION file:**
```bash
source "${NFTBAN_LIB_DIR}/lib/version.sh"
echo "$NFTBAN_VERSION"  # Reads from VERSION file automatically
```

### 3. RPM/DEB Packages

**Auto-read during packaging:**
```bash
cd packaging
./build_nftban.sh rpm  # Reads VERSION file
./build_nftban.sh deb  # Reads VERSION file
```

### 4. GitHub Actions

**Read from VERSION file during workflows:**
```yaml
- name: Get version
  run: |
    VERSION=$(cat VERSION)
    echo "Building version: $VERSION"
```

## Testing Version System

```bash
# Test bash version reading
source cli/lib/nftban/lib/version.sh
echo "$NFTBAN_VERSION"

# Test Go version injection
./build.sh
./bin/nftban-core --version

# Test packaging version
cd packaging
./build_nftban.sh rpm
# Check RPM version: rpm -qpi build/packages/RPMS/*/*.rpm | grep Version
```

## Migration Notes

**Old System:**
- Version hardcoded in multiple places
- Manual updates error-prone
- Easy to miss files
- Inconsistent versions possible

**New System:**
- Single VERSION file
- Automatic propagation
- Impossible to have inconsistent versions
- One command to bump version

## Semantic Versioning

We follow [SemVer](https://semver.org/):

- **MAJOR** (1.x.x): Breaking changes
- **MINOR** (x.1.x): New features (backward compatible)
- **PATCH** (x.x.1): Backward-compatible corrections. This covers more than product bug fixes:
  - product bug fixes;
  - release, build and test-infrastructure corrections;
  - development-authority and repository-lifecycle tooling;
  - documentation and metadata corrections.

  A PATCH must introduce **no** intentional runtime feature and **no** incompatible schema or CLI
  contract change. Do **not** take a MINOR bump merely because the work is development
  infrastructure — the axis is compatibility, not subject matter.

### Release category

Orthogonal to the SemVer level, every release declares what kind of change it carries. The level
answers *"can this break a consumer?"*; the category answers *"what was changed?"*.

| `RELEASE_CATEGORY` | Meaning |
|---|---|
| `PRODUCT_FIX` | Defect in shipped runtime behaviour |
| `SECURITY_FIX` | Security-relevant correction |
| `MAINTENANCE_TOOLING` | Build, CI, test or development-lifecycle tooling |
| `PACKAGING` | DEB/RPM packaging, install layout, unit files |
| `DOCUMENTATION` | Documentation or metadata only |
| `HOTFIX` | Expedited correction of a released defect |

The two axes are independent, and the category must not drag the level upward: development-infrastructure
work is still `PATCH` when it is backward compatible.

**A worked example of the level changing with the evidence.** A maintenance train was originally scoped
as `PATCH` + `MAINTENANCE_TOOLING` — repository-authority and workspace-lifecycle guards, no runtime,
daemon, nft schema or config schema change. Clean-environment validation then exposed release-relevant
runtime and packaging defects, which meant the eventual release would carry runtime correction as well as
tooling. The planned patch was **not published**; the work was reclassified into the next minor train as
`SECURITY_AND_INSTALL_CORRECTNESS`.

The rule that produced that outcome: **classify from the change set that will actually ship, not from the
one that was planned.** If validation changes the change set, reclassify before publishing — never
publish under a level the contents no longer justify.

## Quick Reference

| Task | Command |
|------|---------|
| Check current version | `cat VERSION` |
| Bump patch | `./scripts/bump-version.sh patch` |
| Bump minor | `./scripts/bump-version.sh minor` |
| Bump major | `./scripts/bump-version.sh major` |
| Set specific version | `./scripts/bump-version.sh 1.2.3` |
| Create release | `git tag v$(cat VERSION) && git push origin v$(cat VERSION)` |

## Summary

**Before each release:**
1. `./scripts/bump-version.sh patch` (or minor/major)
2. `git add VERSION && git commit -m "chore: Bump version to X.Y.Z"`
3. `git tag vX.Y.Z && git push origin vX.Y.Z`

**That's it!** All packages will be built with the correct version automatically.
