#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# =============================================================================
# NFTBan v1.0.0 - Header & Metadata Validator
# =============================================================================
# meta:name="validate-headers"
# meta:type="tool"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Pre-commit hook to validate SPDX + meta tags + inventory keys + Bash set flags"
# meta:inventory.files=""
# meta:inventory.binaries="git,grep,head"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail

# Validate SPDX + meta quoting + required inventory keys + bash set flags.
# Fails commit if any tracked file violates the file-header spec
# defined in CONTRIBUTING.md section 'File Headers'.

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# Files staged for commit (Added/Copied/Modified/Renamed)
# ⛔ v1.229.11 LANE 8: THIS GATE USED TO PASS BY VALIDATING NOTHING.
#
#   $ bash tools/validate-headers.sh
#   Validating headers for 0 files...
#   All header validations passed.   rc=0
#
# The subject set came from `git diff --cached`, and the `|| find … | head -500`
# fallback was UNREACHABLE DEAD CODE: `git diff --cached` EXITS 0 when nothing is
# staged, so `||` never fired. With nothing staged the gate scanned ZERO files
# and reported success. Not a truncated scan reading as full coverage — a ZERO
# scan reading as full coverage. The `| head -500` truncation was real too, but
# it was never even reached.
#   A GATE ENFORCES WHAT IT MEASURES, NOT WHAT ITS NAME SUGGESTS.
#
# The full-repo path is now EXPLICIT and uncapped, selected on EMPTINESS rather
# than on an exit status that never signals it.
mapfile -t files < <(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
if (( ${#files[@]} == 0 )); then
    # Nothing staged: validate the WHOLE tracked tree. No head/limit — a silent
    # cap here would recreate the same class of lie at a different size.
    mapfile -t files < <(git ls-files)
    echo "No staged changes — validating the full tracked tree (${#files[@]} files)."
fi

fail=0

is_bash() {
  local f="$1"
  [[ "$f" == *.sh ]] && return 0
  # Shebang detection for non-.sh
  [[ -f "$f" ]] && head -n 1 "$f" 2>/dev/null | grep -qE '^#!.*/(env )?bash' && return 0
  return 1
}

is_go() { [[ "$1" == *.go ]]; }

is_conf() {
  case "$1" in
    *.conf|*.cfg|*.env|*.rules|templates/*) return 0 ;;
    *) return 1 ;;
  esac
}

is_systemd() {
  case "$1" in
    *.service|*.timer|*.socket|*.path) return 0 ;;
    *) return 1 ;;
  esac
}

require_header_checks() {
  local f="$1"
  is_bash "$f" || is_go "$f" || is_conf "$f" || is_systemd "$f"
}

check_spdx_once() {
  local f="$1"
  local count
  # Only count actual SPDX header lines (comment marker followed by SPDX)
  # Exclude lines where SPDX appears inside code (grep patterns, strings, etc.)
# REUSE-IgnoreStart
  count="$(grep -cE '^[[:space:]]*(#|//)[[:space:]]*SPDX-License-Identifier:' "$f" 2>/dev/null || echo "0")"
# REUSE-IgnoreEnd
  if [[ "$count" -ne 1 ]]; then
# REUSE-IgnoreStart
    echo "ERROR: $f must contain exactly one SPDX-License-Identifier line (found $count)"
# REUSE-IgnoreEnd
    return 1
  fi
}

check_meta_quoted() {
  local f="$1"
  # Any meta: line must match meta:key="value"
  # Allow leading comment markers and optional spaces.
  local bad
  bad="$(grep -nE '^[[:space:]]*(#|//)[[:space:]]*meta:[a-z0-9.]+=' "$f" 2>/dev/null \
        | grep -vE 'meta:[a-z0-9.]+=".*"' || true)"
  if [[ -n "$bad" ]]; then
    echo "ERROR: $f has non-quoted meta lines. Must be meta:key=\"value\"."
    echo "$bad"
    return 1
  fi
}

check_inventory_keys_present() {
  local f="$1"
  local marker
  # Go and .rules files use // comments; everything else uses #
  if is_go "$f" || [[ "$f" == *.rules ]]; then marker='//'; else marker='#'; fi

  local keys=(
    'meta:inventory.files='
    'meta:inventory.binaries='
    'meta:inventory.env_vars='
    'meta:inventory.config_files='
    'meta:inventory.systemd_units='
    'meta:inventory.network='
    'meta:inventory.privileges='
  )

  local k missing=0
  for k in "${keys[@]}"; do
    if ! grep -qE "^[[:space:]]*(${marker})[[:space:]]*${k}\"" "$f" 2>/dev/null; then
      echo "ERROR: $f missing required inventory line: ${k}\"...\""
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] || return 1
}

check_no_free_text_from_calledby() {
  local f="$1"
  # Disallow bare header labels that tend to creep in.
  # (Still allows them if they are clearly meta: keys.)
  if grep -nE '^[[:space:]]*(#|//)[[:space:]]*(From|Called by|Used by)[[:space:]]*:' "$f" >/dev/null 2>&1; then
    echo "ERROR: $f contains free-text header lines (e.g., 'From:', 'Called by:'). Convert to meta: keys."
    grep -nE '^[[:space:]]*(#|//)[[:space:]]*(From|Called by|Used by)[[:space:]]*:' "$f" || true
    return 1
  fi
}

check_bash_set_flags() {
  local f="$1"
  is_bash "$f" || return 0

  # Must include set -Eeuo pipefail (allow whitespace variants)
  if ! grep -qE '^[[:space:]]*set[[:space:]]+-Eeuo[[:space:]]+pipefail' "$f" 2>/dev/null; then
    echo "ERROR: $f missing required 'set -Eeuo pipefail' (NFTBan coding standards)."
    return 1
  fi
}

# ⛔ v1.229.11 LANE 8: assert COPYRIGHT, not only LICENCE. The gate's name says
# "headers", and everyone believed it covered REUSE compliance, but it contained
# zero occurrences of SPDX-FileCopyrightText — so a file could carry a perfect
# licence line and no attribution at all and still pass.
#   A LICENCE WITHOUT AN ATTRIBUTION IS NOT A COMPLETE HEADER.
# The expected string is the owner-frozen canon (legal-identity-surfaces.tsv:3-6),
# checked as a SUBSTRING so the optional contact suffix is permitted.
check_spdx_copyright() {
    local f="$1" n
    # ⛔ SAME SUBJECT POPULATION AS THE ANNOTATOR — the intersection of this
    # gate's source classes and the ownership registry's exemptions
    # (check-core-ownership-identity.sh:146). Systemd units, .cfg/.env,
    # templates/* and .githooks/* get their copyright from REUSE.toml, because an
    # in-file attribution would make each an UNREGISTERED legal-identity surface
    # and fail that gate. Demanding it here would demand the thing the other gate
    # forbids.
    #   TWO GATES MUST NOT REQUIRE OPPOSITE THINGS OF THE SAME FILE.
    case "$f" in
        *.sh|*.go|*.conf|*.rules|cli/sbin/*) ;;
        *) return 0 ;;
    esac
    case "$f" in .githooks/*) return 0 ;; esac
    n="$(grep -cE '^[[:space:]]*(#|//)[[:space:]]*SPDX-FileCopyrightText:' "$f" 2>/dev/null || true)"
    if [[ "$n" -eq 0 ]]; then
        echo "  ERROR: $f has no SPDX-FileCopyrightText line" >&2
        return 1
    fi
    if ! grep -qF 'Copyright (c) 2024-2026 Antonios Voulvoulis' "$f" 2>/dev/null; then
        echo "  ERROR: $f copyright is not the canonical holder/years" >&2
        return 1
    fi
    return 0
}

check_spdx_is_mpl() {
  local f="$1"
  # All NFTBan files must use MPL-2.0 (only check actual header lines)
# REUSE-IgnoreStart
  if ! grep -qE '^[[:space:]]*(#|//)[[:space:]]*SPDX-License-Identifier:[[:space:]]*MPL-2\.0' "$f" 2>/dev/null; then
    echo "ERROR: $f must use 'SPDX-License-Identifier: MPL-2.0' (NFTBan standard)."
# REUSE-IgnoreEnd
    return 1
  fi
}

echo "Validating headers for ${#files[@]} files..."

for f in "${files[@]}"; do
  # Skip deleted or non-existent
  [[ -f "$f" ]] || continue

  # Skip vendor, node_modules, .git, generated files
  [[ "$f" == vendor/* ]] && continue
  [[ "$f" == node_modules/* ]] && continue
  [[ "$f" == .git/* ]] && continue
  [[ "$f" == *_templ.go ]] && continue

  if ! require_header_checks "$f"; then
    continue
  fi

  # Run checks
  check_spdx_once "$f" || fail=1
  check_spdx_is_mpl "$f" || fail=1
  check_spdx_copyright "$f" || fail=1
  check_meta_quoted "$f" || fail=1
  check_inventory_keys_present "$f" || fail=1
  check_no_free_text_from_calledby "$f" || fail=1
  check_bash_set_flags "$f" || fail=1
done

if [[ "$fail" -ne 0 ]]; then
  echo
  echo "=========================================="
  echo "Commit blocked: header / coding standards validation failed."
  echo "Fix headers/metadata or inventory lines, then re-stage and commit."
  echo
  echo "References:"
  echo "  - CONTRIBUTING.md, section 'File Headers' (authoritative spec)"
  echo "  - https://nftban.com/coding-standards.html"
  echo "=========================================="
  exit 1
fi

echo "All header validations passed."
exit 0
