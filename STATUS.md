# NFTBan Development Project Health Status

**Status:** ⚠️ Warning
**Last Updated:** 2026-07-16 06:28:05 UTC
**Version:** v1.221.2 Development Branch

---

## Active Release Train

**v1.221.3 — P1 UNINSTALL FIREWALL-SAFETY HOTFIX (in prep)** — *packaging-only; no daemon/nft-schema change. Supersedes v1.221.2 for deployment.*

| Field | State |
|-------|-------|
| Defect | **CONFIRMED_V1_221_2_PACKAGE_NATIVE_UNINSTALL_CONNECTIVITY_DEFECT** — DEB `remove)` flushed `ip/ip6 nftban` but kept the `policy drop` input chain (0 accept rules) → dropped all inbound (SSH/ping) until reboot; iface/IP/route/sshd stayed healthy. Runtime + serial-console proven on published v1.221.2. Old (v1.38.0-era) path; not an RBL/release-workflow regression. |
| Fix | `packaging/deb/postrm` `remove)` now **deletes** `ip/ip6 nftban` tables (matches safe purge/RPM-erase); config retained; no reboot needed |
| Guard | NEW `scripts/ci/check-uninstall-firewall-safety.sh` (wired into ci-architecture.yml) — rejects flush-without-delete + negative self-test |
| Status | PR in prep (this hotfix) |
| v1.221.2 | PUBLISHED but **DEPLOYMENT_BLOCKED** by this defect (preserved, not rewritten) |
| Rollout | lab2 DEB + lab4 RPM full uninstall-lifecycle re-validation → canary → fleet, all PENDING |

**v1.221.2 — PUBLISHED · ARTIFACTS_VERIFIED · DEPLOYMENT_BLOCKED (uninstall defect) · superseded by v1.221.3 for deployment** — *release-automation repair only; same product code as v1.221.0/v1.221.1 (no daemon/nft-schema change).*

| Field | State |
|-------|-------|
| Product implementation | MERGED (#1106 privacy, #1107 opqueue, #1108 build-provenance, #1109 lifecycle) |
| Workflow Mode-3 + jq prerequisite | MERGED (#1111 f4fbb859, #1114 1f274b7b) |
| Publication-path fix (shared assembly verifier + CI guard) | MERGED (#1115 d47416b2) |
| Relative `--dist-dir` verifier fix | MERGED (#1116 → `main` 536db592) |
| **Tag v1.221.2** | **CREATED** — object `1188d650` → target `536db592919d7d5dc3c77d6526678fbcd948a0b9` |
| **Release** | **PUBLISHED** (non-draft, non-prerelease) · Release Packages 29618953508 ✅ · Docker 29618953526 ✅ · SLSA 29619105199 ✅ |
| **Assets** | **15/15, 0 duplicates** (5 DEB + 2 RPM + nftband + nftban-core + .intoto.jsonl + sbom + SHA256SUMS + SHA256SUMS.build + MANIFEST + VERIFY) |
| **Checksums** | SHA256SUMS ✅ == SHA256SUMS.build ✅ (8 entries: packages+nftband; nftban-core via SLSA intoto) · DEB↔RPM parity ✅ (nftban-core, nftband) · embedded commit `536db592` |
| **SLSA provenance** | VERIFIED — intoto subject sha256 matches `nftban-core-linux-amd64` (slsa.dev/provenance/v0.2) |
| **Docker tags** | `v1.221.2` · `1.221.2` · `1.221` · `sha-536db592` |
| Local KVM qualification | PENDING (Phase-4 matrix on official assets) |
| Remote lab / canary / fleet | PENDING |

**Superseded, incomplete publications (both preserved, never rewritten):**
- **v1.221.0** — tag `→ a9ab66b2` · Docker PUBLISHED · GitHub release ABSENT (release.yml called bare `build_nftban.sh`; no `jq`).
- **v1.221.1** — tag `→ 1f274b7b` · Docker PUBLISHED · GitHub release ABSENT (assembly-verify step's trailing bare conditional failed the push path). Both Docker image sets + failure evidence retained.

Register state: publication defects `OPEN_RELEASE_YML_MODE3_PREBUILT_GAP`, `OPEN_RELEASE_YML_MODE3_JQ_PREREQUISITE_GAP`, `OPEN_RELEASE_YML_PUSH_PATH_ASSEMBLY_VERIFY_FOOTGUN` are `SHIPPED_IN=v1.221.2` (the repaired release workflow is now published + asset-verified). NOT closed as a train: local KVM qualification, remote-lab, canary, and fleet rollout remain; validation-dependent findings (`SUSPECTED_NFTBAN_UNINSTALL_TRANSIENT_CONNECTIVITY_DROP`, `OPEN_SLSA_STANDALONE_BINARY_VERSION_LDFLAGS`) stay OPEN. The v1.221.2 release train is NOT closed.

**Current published / fleet baseline: v1.220.10** — managed fleet 11/11 (production 9/9, labs 2/2), daemon `bc9650be`, nft schema 1, validator/status schema 1.84.0. v1.221.2 is PUBLISHED but not yet the fleet baseline (rollout pending qualification).

---

## Summary

| Metric | Value |
|--------|-------|
| Total Checks | 29 |
| Passed | ✅ 29 |
| Failed | ❌ 0 |
| Warnings | ⚠️ 6 |

---

## Check Results

### ✅ Passed Checks
- **Shell Quality**: shellcheck, shfmt
- **Go Quality**: go vet, gofmt, go test
- **Documentation**: markdownlint
- **Configuration**: yamllint
- **Structure**: all critical files present
- **Security**: no obvious issues detected
- **Permissions**: appropriate file permissions
- **NFT Schema**: v1.221.1 alignment verified


### ⚠️ Warnings (Non-Critical)
- shfmt (528 files)
- markdownlint
- gofmt (171 files)
- No Go tests
- Security (1 potential issues)
- NFT Schema alignment (1 potential issues)

---

## Health Categories

### Shell Script Quality
- **shellcheck**: Static analysis for bash scripts
- **shfmt**: Shell script formatting
- **Status**: ✅ Passing

### Go Code Quality
- **go vet**: Go code static analysis
- **gofmt**: Go code formatting
- **go test**: Unit test execution
- **go.mod**: Dependency management
- **Status**: ✅ Passing

### Documentation
- **markdownlint**: Markdown style checking
- **Status**: ✅ Passing

### Project Structure
- **Critical Files**: README, LICENSE, go.mod, build.sh
- **Core Directories**: cli/, cmd/, internal/, pkg/, install/, packaging/
- **Status**: ✅ All present

### Security
- **Secret Scanning**: Basic grep-based detection
- **File Permissions**: World-writable checks
- **Status**: ⚠️ Review recommended

### NFT Schema v1.221.1 Alignment
- **Variable Usage**: Check for hardcoded table names in shell
- **Constants Usage**: Check for hardcoded table names in Go
- **Status**: ✅ Aligned

---

## CI/CD Status

This status report is automatically generated by `.ci/health_check.sh`.

- **Workflow**: Project Health
- **Trigger**: On push to v0.7 branch, weekly schedule
- **Full Logs**: [GitHub Actions](https://github.com/itcmsgr/nftban/actions/workflows/health.yml)

---

## Development Notes

This is the **development branch** for NFTBan v1.221.1. Health checks include:

1. **Code Quality**: Both shell and Go code are validated
2. **Architecture Alignment**: NFT Schema v1.221.1 dual-table architecture
3. **Package Building**: Automated RPM/DEB package generation
4. **Testing**: Unit tests and integration checks

**Note**: This is an automated health check. Manual review may be required for warnings.
