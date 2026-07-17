#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# meta:name="verify-release-assembly"
# meta:type="script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Shared, mode-aware verifier for the assembled Release Packages directory (the PRE-SLSA asset set). Invoked by BOTH the dry-run and the tag-push paths of release.yml with an explicit --mode so the two paths run identical verification logic. Never publishes."
# meta:inventory.files=""
# meta:inventory.binaries="bash, ls, sha256sum, ar, tar, rpm2cpio, cpio, grep, awk"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
#
# WHY THIS SCRIPT EXISTS (v1.221.2):
#   v1.221.1 published-release FAILED because the inline "Verify assembled
#   release directory" step's LAST statement was `[ "$IS_DRYRUN" = 1 ] && echo …`.
#   On a tag push IS_DRYRUN=0 → the test returns 1 → the AND-list (being the
#   block's final command) makes the step exit 1. The dry-run (IS_DRYRUN=1)
#   never exercised that branch. This script removes the whole class of bug:
#     - one code path verifies the assembly for BOTH modes (no push-only branch);
#     - only SHA256SUMS handling differs by mode, via explicit `if`;
#     - it ALWAYS ends in `exit 0` after assertions (no trailing conditional);
#     - it is unit-tested in both modes in CI, without publishing anything.
#
# ASSET MODEL (proven from release.yml, v1.221.2):
#   base assembly (both modes): 5 DEB + 2 RPM + nftband-linux-amd64 + sbom.spdx.json
#     + SHA256SUMS.build + MANIFEST.txt + VERIFY.txt                       = 12
#   --mode dry-run: additionally generate SHA256SUMS locally to prove the set = 13
#   --mode push:    SHA256SUMS is added downstream by verify-release          = 12 here
#   published pre-SLSA (after verify-release adds SHA256SUMS)                  = 13
#   final (after SLSA appends nftban-core-linux-amd64 + .intoto.jsonl)         = 15
#
# This script covers ONLY the pre-SLSA assembly it is handed. It never uploads,
# tags, publishes, or contacts a registry.
# =============================================================================
set -Eeuo pipefail

MODE=""
DIST_DIR=""
EXPECT_COMMIT=""   # optional: assert the packaged nftband embeds this git commit

usage() { echo "usage: verify-release-assembly.sh --mode {dry-run|push} --dist-dir DIR [--expect-commit SHA]" >&2; }

parse_args() {
    MODE=""; DIST_DIR=""; EXPECT_COMMIT=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --mode)          MODE="${2:-}"; shift 2 ;;
            --dist-dir)      DIST_DIR="${2:-}"; shift 2 ;;
            --expect-commit) EXPECT_COMMIT="${2:-}"; shift 2 ;;
            -h|--help)       usage; exit 0 ;;
            *) echo "::error::unknown argument: $1" >&2; usage; exit 2 ;;
        esac
    done
    if [ "$MODE" != "dry-run" ] && [ "$MODE" != "push" ]; then
        echo "::error::--mode must be 'dry-run' or 'push' (got '${MODE}')" >&2; exit 2
    fi
    if [ -z "$DIST_DIR" ] || [ ! -d "$DIST_DIR" ]; then
        echo "::error::--dist-dir must be an existing directory (got '${DIST_DIR}')" >&2; exit 2
    fi
}

# verify_inventory DIR MODE  — file/count/mode assertions over the assembled dir.
# Prints EVIDENCE_* lines. Returns non-zero on any missing/miscount.
verify_inventory() {
    local dir="$1" mode="$2" f deb_count rpm_count
    ( # subshell so `cd` does not leak to the caller
      cd "$dir"
      deb_count=$(ls -1 ./*.deb 2>/dev/null | wc -l | tr -d ' ')
      rpm_count=$(ls -1 ./*.rpm 2>/dev/null | wc -l | tr -d ' ')
      echo "EVIDENCE_DEB_COUNT=$deb_count"
      echo "EVIDENCE_RPM_COUNT=$rpm_count"
      echo "EVIDENCE_PACKAGE_COUNT=$((deb_count + rpm_count))"
      if [ "$deb_count" != 5 ]; then echo "::error::expected DEB_COUNT=5, got $deb_count"; exit 1; fi
      if [ "$rpm_count" != 2 ]; then echo "::error::expected RPM_COUNT=2, got $rpm_count"; exit 1; fi

      # Standalone binary: create-release owns ONLY nftband; nftban-core is a
      # downstream SLSA asset, NOT produced here by design.
      if [ -f nftband-linux-amd64 ]; then echo "EVIDENCE_NFTBAND_PRESENT=YES"; else echo "::error::nftband-linux-amd64 missing"; exit 1; fi
      echo "EVIDENCE_NFTBAN_CORE_PRESENT=NOT_APPLICABLE_DOWNSTREAM_SLSA"
      echo "EVIDENCE_PRE_SLSA_BINARY_COUNT=1"

      for f in sbom.spdx.json SHA256SUMS.build MANIFEST.txt VERIFY.txt; do
          if [ -f "$f" ]; then echo "EVIDENCE_${f}_PRESENT=YES"; else echo "::error::$f MISSING"; exit 1; fi
      done

      # Mode-specific SHA256SUMS handling + count. Explicit branches; NEVER a
      # trailing bare conditional.
      local base_count=$((deb_count + rpm_count + 1 + 4))   # packages + nftband + (sbom,build,MANIFEST,VERIFY)
      if [ "$mode" = "dry-run" ]; then
          # Prove the pre-SLSA checksum inventory is generatable over the
          # checksummed release assets (packages + nftband) — mirrors what
          # verify-release publishes. This local SHA256SUMS is dry-run evidence only.
          sha256sum ./*.rpm ./*.deb nftband-linux-amd64 > SHA256SUMS
          echo "EVIDENCE_SHA256SUMS_GENERATED=YES (covers $(wc -l < SHA256SUMS | tr -d ' ') release assets: packages + nftband)"
          echo "EVIDENCE_ASSEMBLY_ASSET_COUNT=$((base_count + 1))"    # 13
          echo "EVIDENCE_EXPECTED_ASSEMBLY_COUNT=13"
      else
          # push: SHA256SUMS is produced downstream by verify-release (Gate 3),
          # so it is NOT expected in the assembled dir at this stage.
          if [ -f SHA256SUMS ]; then echo "::error::SHA256SUMS must NOT be pre-present on the push path (verify-release generates it)"; exit 1; fi
          echo "EVIDENCE_SHA256SUMS_DEFERRED_TO_VERIFY_RELEASE=YES"
          echo "EVIDENCE_ASSEMBLY_ASSET_COUNT=$base_count"           # 12
          echo "EVIDENCE_EXPECTED_ASSEMBLY_COUNT=12"
      fi
      echo "EVIDENCE_PUBLISHED_PRE_SLSA_ASSET_COUNT=13"
      echo "EVIDENCE_FINAL_POST_SLSA_ASSET_COUNT=15"
    )
}

# verify_parity DIR  — DEB and RPM must carry byte-identical daemon binaries
# (same build-binaries artifact). Extracts nftban-core AND nftband from a DEB and
# an RPM and compares. Uses ar+tar for the DEB (portable) and rpm2cpio for the RPM.
# Overridable in tests by redefining this function after sourcing.
verify_parity() {
    local dir="$1" work deb rpm b dsha rsha
    work="$(mktemp -d)"
    deb="$dir/nftban-ubuntu24.04-amd64.deb"
    rpm="$dir/nftban-el9-x86_64.rpm"
    if [ ! -f "$deb" ]; then echo "::error::parity: missing $deb"; rm -rf "$work"; return 1; fi
    if [ ! -f "$rpm" ]; then echo "::error::parity: missing $rpm"; rm -rf "$work"; return 1; fi
    mkdir -p "$work/deb" "$work/rpm"
    ( cd "$work/deb" && ar x "$deb" && mkdir -p x && tar -xf data.tar.* -C x )
    ( cd "$work/rpm" && rpm2cpio "$rpm" | cpio -idm --quiet )
    local ok=0
    for b in nftban-core nftband; do
        dsha=$(sha256sum "$work/deb/x/usr/lib/nftban/bin/$b" 2>/dev/null | awk '{print $1}')
        rsha=$(sha256sum "$work/rpm/usr/lib/nftban/bin/$b" 2>/dev/null | awk '{print $1}')
        echo "EVIDENCE_DEB_${b}_SHA=${dsha:-MISSING}"
        echo "EVIDENCE_RPM_${b}_SHA=${rsha:-MISSING}"
        if [ -z "$dsha" ] || [ -z "$rsha" ]; then echo "::error::parity: $b not found in a package"; ok=1
        elif [ "$dsha" != "$rsha" ]; then echo "::error::DEB_RPM_${b}_BYTE_IDENTICAL=NO"; ok=1
        else echo "EVIDENCE_DEB_RPM_${b}_BYTE_IDENTICAL=YES"; fi
    done
    if [ -n "$EXPECT_COMMIT" ]; then
        local emb
        emb=$("$work/deb/x/usr/lib/nftban/bin/nftband" --version 2>/dev/null | grep -oE 'git [0-9a-f]+' | awk '{print $2}' || true)
        echo "EVIDENCE_PUBLISHED_EMBEDDED_COMMIT=${emb:-unknown}"
        if [ -z "$emb" ] || [ "${EXPECT_COMMIT#"$emb"}" = "$EXPECT_COMMIT" ]; then
            echo "::error::embedded commit ${emb:-unknown} does not match expected $EXPECT_COMMIT"; ok=1
        else
            echo "EVIDENCE_EMBEDDED_COMMIT_MATCH=YES"
        fi
    fi
    rm -rf "$work"
    return "$ok"
}

main() {
    parse_args "$@"
    echo "verify-release-assembly: mode=$MODE dist-dir=$DIST_DIR"
    # Explicit return-code checks — do NOT rely on `set -e` to propagate a
    # function's failure (bash does not exit the caller when a function's body
    # is a subshell that returns non-zero; that implicit-exit fragility is the
    # very class of bug this script replaces).
    if ! verify_inventory "$DIST_DIR" "$MODE"; then
        echo "::error::release assembly inventory verification FAILED (mode=$MODE)"; exit 1
    fi
    if ! verify_parity "$DIST_DIR"; then
        echo "::error::release assembly DEB/RPM parity verification FAILED"; exit 1
    fi
    echo "verify-release-assembly: PASS (mode=$MODE) — assembly verified, nothing published"
    exit 0
}

# Source-guard: allow tests to `source` this file and exercise/redefine the
# individual functions without running main().
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
