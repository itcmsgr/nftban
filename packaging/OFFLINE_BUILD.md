# NFTBan — Build Provenance & Offline Builds

The packaging build is guarded against silently shipping a **stale prebuilt
binary**. A build always produces a daemon that provably corresponds to the
current source, or it fails closed. There are three supported modes.

## Capability (honest status)

| Capability | Status |
|---|---|
| Connected source build | **supported** |
| Offline source build | **supported *when* Go + all modules/tools are locally provisioned** (conditional) |
| Offline prebuilt packaging | **supported** with a complete verified manifest bundle |
| Offline dependency kit generation | deferred (`OPEN_OFFLINE_BUILD_DEPENDENCY_AND_KIT`) |
| Manifest signing | deferred |

> A lack of internet must never cause NFTBan to package whatever old executable
> happens to be in `bin/`. Offline capability is prepared deliberately.

## Mode 1 — connected/normal source build (default)

```
./packaging/build_nftban.sh deb        # or rpm / both
```

Go present → the six generated binaries under `bin/` are **cleaned (allowlisted)**
and **rebuilt from source**; each anchor binary's embedded `GitCommit` is verified
to equal the resolved source identity; the exact rebuilt binaries are packaged.
Existing `bin/*` **never** suppresses the rebuild.

## Mode 2 — offline source build (conditional)

```
./packaging/build_nftban.sh deb --offline
./packaging/build_nftban.sh deb --offline --module-cache /abs/path/to/gomodcache
```

- Go must be installed; source identity must be resolvable.
- Sets `GOPROXY=off` (no module/tool downloads) and skips `go mod tidy`.
- Dependency source: `vendor/` if present, else an explicit `--module-cache`.
- **Fails closed** before staging if no local dependency source is available —
  no network fallback, never a `bin/*` fallback.

`vendor/` is **not** currently committed, so true no-network source builds require
a supplied module cache until the deferred vendoring lane lands.

## Mode 3 — verified prebuilt packaging (no Go)

For an isolated packager without a Go toolchain. Explicit only — never inferred
from Go being absent.

```
./packaging/build_nftban.sh deb \
    --use-prebuilt \
    --prebuilt-manifest /abs/path/build-manifest.json
```

All **six** binaries (`nftban-core`, `nftband`, `nftban-botscan-matcher`,
`nftban-validate`, `nftban-detect-ssh-ports`, `nftban-installer`) are verified
against the manifest: regular file (no symlink), ELF, `linux`/`amd64`, sha256 ==
manifest, and — for the commit anchors (`nftban-core`, `nftband`) — embedded
commit == manifest `source_commit` == resolved source identity. Missing, extra,
or duplicate entries fail. `jq` is required.

## Source identity precedence

1. explicit manifest `source_commit` (prebuilt mode)
2. `SOURCE_COMMIT` file (exported/offline source bundle; full 40-hex)
3. git `HEAD` (checkout)
4. **hard failure** — never silently embeds `dev`

When both `.git` and `SOURCE_COMMIT` exist they must agree (a stale exported
identity must not contaminate a live checkout). A shortened SHA is rejected.

> `SOURCE_TREE_SHA256` / `module_lock_sha256` are recorded in the manifest for
> integrity but are **not** authoritative gates in this lane; a canonical
> source-tree digest is deferred to `OPEN_OFFLINE_BUILD_DEPENDENCY_AND_KIT`.

## Provenance manifest (schema v1)

`build.sh` writes `bin/build-manifest.json` after a full build:

```json
{
  "manifest_version": 1,
  "source_commit": "<40-hex>",
  "source_version": "<VERSION>",
  "target_os": "linux",
  "target_arch": "amd64",
  "go_version": "<go version>",
  "module_lock_sha256": "<sha256(go.mod+go.sum)>",
  "binaries": [ { "name": "nftband", "sha256": "<hex>", "embedded_commit": "<40-hex>" } ]
}
```

Cryptographic signing is deferred; an unsigned manifest provides integrity +
provenance consistency only when transferred through a trusted channel.

## Local packaging tool requirements

| | DEB | RPM |
|---|---|---|
| required for package | go, dpkg-deb, tar, gzip/xz, python3, coreutils | go, rpmbuild, tar, gzip/xz, python3, coreutils |
| verified-prebuilt (Mode 3) | + jq, file (Go not required) | + jq, file (Go not required) |

SBOM / SLSA / checksums / signing / privacy-gate tools are **required for
release**, optional for local validation. A local build never auto-installs
missing tools from the network.

## Package SHA chain

Every package build asserts `BUILT == STAGED == PACKAGE_EXTRACTED` for the
daemon (`verify_package_sha_chain`). In Mode 3 the `MANIFEST` sha substitutes for
`BUILT`. Installed-SHA equality is proven in package-native lab validation.

## CI

`build-packages.yml`: the `build-binaries` job builds fresh + emits the manifest
in the `go-binaries` artifact. The RPM/DEB package jobs **explicitly** consume it
with `--use-prebuilt --prebuilt-manifest` (they intentionally trust that artifact
and have no Go). A `provenance-negative` job plants a stale binary and proves a
source build overwrites it, and that a tampered manifest is rejected.
`ci-architecture.yml` runs `scripts/ci/check-build-provenance.sh` (static lint +
hermetic tests).
