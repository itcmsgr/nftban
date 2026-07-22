#!/usr/bin/env bash
# =============================================================================
# NFTBan - version Release-Date authority (per-release VERSION_DATE artifact)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="version_release_date_authority_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-11"
# meta:description="Locks the version Release-Date authority. Release Date resolves from a per-release VERSION_DATE artifact (packaged /usr/lib/nftban/VERSION_DATE first, then source-tree VERSION_DATE, then an explicit 'unknown' fallback) — NEVER a frozen compile-time constant. VERSION_DATE must be a strict ISO YYYY-MM-DD; a malformed/missing artifact falls back to 'unknown'. Build Date renders ONLY when authoritative build metadata exists (a .build_date stamp or rpm BUILDTIME) and is OMITTED entirely otherwise (no 'unknown', no invented timestamp). Proves: repo ships a valid VERSION_DATE; source-tree resolution; malformed/missing fallback; strict-ISO validation; render omits Build Date when empty and shows it when a stamp exists. Shell-only; no daemon/Go; schema 1.84.0 unchanged."
# meta:input="Repo VERSION_DATE + sandboxed copies of lib/version.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,cp,mktemp"
# meta:inventory.files="cli/lib/nftban/lib/version.sh,VERSION_DATE,VERSION"
# meta:inventory.binaries="bash,cp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_ROOT,NFTBAN_VERSION_LOADED,NFTBAN_NO_BANNER"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="version_release_date_authority_test"
# meta:ta.owner="release"
# meta:ta.module="version"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================

set -Eeuo pipefail
set +eE

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# repo root: tests/ -> nftban -> lib -> cli -> repo? version.sh lives at
# cli/lib/nftban/lib/version.sh and tests at cli/lib/nftban/tests/. Repo root is
# five parents up from version.sh's dir.
VERSION_SH="$(cd "$SCRIPT_DIR/../lib" && pwd)/version.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

echo "=== version Release-Date authority (per-release VERSION_DATE) ==="

# --------------------------------------------------------------------------
# 0 — the repo ships a strict-ISO VERSION_DATE (no frozen constant left behind)
# --------------------------------------------------------------------------
[[ -f "$REPO_ROOT/VERSION_DATE" ]] && ok "repo ships VERSION_DATE" || no "repo VERSION_DATE missing"
rd="$(tr -d '[:space:]' < "$REPO_ROOT/VERSION_DATE" 2>/dev/null)"
[[ "$rd" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && ok "repo VERSION_DATE is strict ISO ($rd)" || no "repo VERSION_DATE not ISO ($rd)"
grep -qE '^[[:space:]]*(readonly[[:space:]]+)?NFTBAN_VERSION_DATE="[0-9]' "$VERSION_SH" && no "frozen NFTBAN_VERSION_DATE constant assignment still present" || ok "no frozen NFTBAN_VERSION_DATE constant assignment"

# --------------------------------------------------------------------------
# Resolver isolation: copy version.sh into a sandbox whose 5th-parent IS the
# sandbox, so the source-tree-relative VERSION_DATE path resolves to a file we
# control. Guard: if a real /usr/lib/nftban/VERSION_DATE exists it takes first
# priority and would mask the sandbox — skip those cases with a note.
# --------------------------------------------------------------------------
resolve_in_sandbox(){ # $1 = value to write to sandbox VERSION_DATE (or "" = none)
  local sb; sb="$(mktemp -d)"
  mkdir -p "$sb/cli/lib/nftban/lib"
  cp "$VERSION_SH" "$sb/cli/lib/nftban/lib/version.sh"
  printf '1.220.3\n' > "$sb/VERSION"
  [[ -n "$1" ]] && printf '%s\n' "$1" > "$sb/VERSION_DATE"
  ( cd "$sb"; unset NFTBAN_ROOT NFTBAN_VERSION_LOADED
    # shellcheck source=/dev/null
    source "$sb/cli/lib/nftban/lib/version.sh" >/dev/null 2>&1
    printf '%s' "${NFTBAN_VERSION_DATE:-<unset>}" )
  rm -rf "$sb"
}

if [[ -e /usr/lib/nftban/VERSION_DATE ]]; then
  echo "  [SKIP] /usr/lib/nftban/VERSION_DATE present on host — sandbox resolver cases skipped"
else
  got="$(resolve_in_sandbox 2026-05-04)"
  [[ "$got" == 2026-05-04 ]] && ok "source-tree VERSION_DATE resolved ($got)" || no "source-tree resolve ($got)"
  got="$(resolve_in_sandbox '2026/05/04')"
  [[ "$got" == unknown ]] && ok "malformed VERSION_DATE → 'unknown' fallback" || no "malformed fallback ($got)"
  got="$(resolve_in_sandbox 'not-a-date')"
  [[ "$got" == unknown ]] && ok "non-ISO VERSION_DATE → 'unknown' fallback" || no "non-ISO fallback ($got)"
  got="$(resolve_in_sandbox '')"   # no artifact anywhere in sandbox
  [[ "$got" == unknown ]] && ok "missing artifact → 'unknown' fallback" || no "missing fallback ($got)"
fi

# --------------------------------------------------------------------------
# Render: Build Date OMITTED when no authoritative build metadata; SHOWN when a
# .build_date stamp exists. Neutralize rpm with a stub so the result is
# host-independent (RPM hosts would otherwise resolve a real BUILDTIME).
# --------------------------------------------------------------------------
render_version(){ # $1 = lib dir (holds optional .build_date)
  local sb; sb="$(mktemp -d)"; local stub="$sb/bin"
  mkdir -p "$stub"; printf '#!/bin/sh\nexit 1\n' > "$stub/rpm"; chmod +x "$stub/rpm"
  ( export PATH="$stub:$PATH" NFTBAN_LIB_DIR="$1" NFTBAN_NO_BANNER=1
    unset NFTBAN_VERSION_LOADED
    # shellcheck source=/dev/null
    source "$VERSION_SH" >/dev/null 2>&1
    nftban_version_info 2>/dev/null )
  rm -rf "$sb"
}

empty_lib="$(mktemp -d)"   # no .build_date
out="$(render_version "$empty_lib")"
printf '%s\n' "$out" | grep -q '^Build Date:' && no "Build Date rendered with no metadata" || ok "Build Date OMITTED when no authoritative metadata"
printf '%s\n' "$out" | grep -qi 'Build Date.*unknown' && no "Build Date printed 'unknown'" || ok "no 'unknown' Build Date"
printf '%s\n' "$out" | grep -q "^Release Date:  *$rd" && ok "render shows repo Release Date ($rd)" || no "render Release Date ($(printf '%s' "$out" | grep -m1 '^Release Date:'))"
rm -rf "$empty_lib"

stamp_lib="$(mktemp -d)"; printf '2026-01-02 03:04:05 UTC\n' > "$stamp_lib/.build_date"
out2="$(render_version "$stamp_lib")"
printf '%s\n' "$out2" | grep -q '^Build Date:  *2026-01-02 03:04:05 UTC' && ok "Build Date SHOWN when .build_date stamp exists" || no "Build Date not shown with stamp ($(printf '%s' "$out2" | grep -m1 '^Build Date:'))"
rm -rf "$stamp_lib"

# --------------------------------------------------------------------------
echo "-------------------------------------------------------------"
echo "PASS=$PASS FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
echo "ALL PASS"; exit 0
