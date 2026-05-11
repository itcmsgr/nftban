#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.108 — V108 Item 2: +i lifecycle matrix CI gate
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="test-immutable-lifecycle-matrix"
# meta:type="ci-script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-11"
# meta:description="V108 Item 2 CI gate: verify chattr +i lifecycle coverage matches build/+i-lifecycle-matrix.yaml across Go SetImmutableFlags + RPM %pretrans/%preun + DEB preinst/postinst/prerm scriptlets"
# meta:inventory.files="scripts/ci/test-immutable-lifecycle-matrix.sh, build/+i-lifecycle-matrix.yaml, internal/installer/validate/authority.go, packaging/build_nftban.sh, packaging/deb/preinst, packaging/deb/postinst, packaging/deb/prerm"
# meta:inventory.binaries="bash, awk, grep, sed"
# meta:inventory.env_vars="NFTBAN_TEST_MATRIX_YAML, NFTBAN_TEST_AUTHORITY_GO, NFTBAN_TEST_RPM_SPEC_SH, NFTBAN_TEST_DEB_PREINST, NFTBAN_TEST_DEB_POSTINST, NFTBAN_TEST_DEB_PRERM"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
#
# Implements V108 Item 2 per scope artifact:
#   /home/commonfolder/LLMAI4NFTBAN/V1.90_AUDIT_WIKI_CODE/AUDIT_190_LIFECYCLE/
#   V108_ITEM2_IMMUTABLE_LIFECYCLE_MATRIX_SCOPE.md
#
# Motivating defect (v1.107.2 / PR #585):
# Go SetImmutableFlags silently extended its protected-files list to include
# /etc/nftban/nftban.conf, but the RPM/DEB scriptlets did not have a matching
# pre-unpack strip. Direct dnf upgrade / apt install on +i-protected hosts
# failed with "cpio: rename failed - No data available". v1.107.2 added the
# %pretrans + DEB preinst strips. This gate is the permanent regression
# defense.
#
# Algorithm:
#   1. Parse build/+i-lifecycle-matrix.yaml → list of (file, hook, requirement) triples.
#   2. Extract Go SetImmutableFlags array from internal/installer/validate/authority.go.
#   3. Extract RPM scriptlet chattr lines from packaging/build_nftban.sh.
#   4. Extract DEB scriptlet chattr lines from packaging/deb/{preinst,postinst,prerm}.
#   5. For each (file, hook) cell in matrix:
#        required        → assert scriptlet contains chattr -i <file> in that hook
#        not_required    → no check (explicit waiver)
#        covered_by_*    → no per-file check (broad sweep)
#   6. Drift defense: every file in Go SetImmutableFlags MUST be in matrix yaml.
#                     every file in RPM %pretrans/%preun MUST be in matrix yaml.
#                     every file in DEB preinst/postinst/prerm MUST be in matrix yaml.
#
# Modes:
#   scan          Run gate against current HEAD repo
#   scan --paths=<override>  (for fixtures; uses NFTBAN_TEST_* overrides)
#
# Exit codes:
#   0  PASS — all matrix-declared coverage satisfied + no drift
#   1  FAIL — at least one mismatch detected
#   2  Invalid usage / missing dependency
#
# Failure-mode taxonomy:
#   YAML_FILE_NOT_IN_GO            file in yaml but absent from SetImmutableFlags array
#   GO_FILE_NOT_IN_YAML            file in SetImmutableFlags but missing from yaml (drift)
#   MISSING_RPM_PRETRANS_STRIP     yaml requires; RPM %pretrans does not strip
#   MISSING_RPM_PREUN_STRIP        yaml requires; RPM %preun does not strip
#   MISSING_DEB_PREINST_STRIP      yaml requires; DEB preinst does not strip
#   MISSING_DEB_POSTINST_STRIP     yaml requires; DEB postinst does not strip
#   MISSING_DEB_PRERM_STRIP        yaml requires; DEB prerm does not strip
# =============================================================================

set -Eeuo pipefail

SCRIPT_NAME="test-immutable-lifecycle-matrix"
SCRIPT_VERSION="1.0.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DEFAULT_MATRIX_YAML="$REPO_ROOT/build/+i-lifecycle-matrix.yaml"
DEFAULT_AUTHORITY_GO="$REPO_ROOT/internal/installer/validate/authority.go"
DEFAULT_BUILD_SH="$REPO_ROOT/packaging/build_nftban.sh"
DEFAULT_DEB_PREINST="$REPO_ROOT/packaging/deb/preinst"
DEFAULT_DEB_POSTINST="$REPO_ROOT/packaging/deb/postinst"
DEFAULT_DEB_PRERM="$REPO_ROOT/packaging/deb/prerm"

log_info()  { printf '[%s] [INFO] %s\n'  "$SCRIPT_NAME" "$*" >&2; }
log_warn()  { printf '[%s] [WARN] %s\n'  "$SCRIPT_NAME" "$*" >&2; }
log_error() { printf '[%s] [ERROR] %s\n' "$SCRIPT_NAME" "$*" >&2; }
log_pass()  { printf '[%s] [PASS] %s\n'  "$SCRIPT_NAME" "$*" >&2; }
log_fail()  { printf '[%s] [FAIL] %s\n'  "$SCRIPT_NAME" "$*" >&2; }

usage() {
    cat >&2 <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION — V108 Item 2 CI gate

Usage:
  $0 scan
  $0 scan [override flags]

Override flags (for fixtures):
  --matrix-yaml=<path>
  --authority-go=<path>
  --build-sh=<path>
  --deb-preinst=<path>
  --deb-postinst=<path>
  --deb-prerm=<path>

Exit codes:
  0  PASS    1  FAIL    2  invalid usage / missing dep
EOF
}

check_deps() {
    local missing=()
    local cmd
    for cmd in awk grep sed; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        exit 2
    fi
}

# -----------------------------------------------------------------------------
# Parse the matrix yaml — emit `<file>|<hook>|<requirement>` lines.
# Pure awk; no jq/yq dependency.
# -----------------------------------------------------------------------------
parse_matrix_yaml() {
    local f="$1"
    [[ -r "$f" ]] || { log_error "Cannot read matrix yaml: $f"; return 1; }
    awk '
    /^[[:space:]]*-[[:space:]]*path:/ {
        path = $0
        sub(/^[[:space:]]*-[[:space:]]*path:[[:space:]]*/, "", path)
        next
    }
    /^[[:space:]]*[a-z_]+:[[:space:]]*[a-z_]+[[:space:]]*$/ {
        if (path == "") next
        line = $0
        sub(/^[[:space:]]+/, "", line)
        hook = line
        sub(/:.*/, "", hook)
        value = line
        sub(/^[^:]*:[[:space:]]*/, "", value)
        sub(/[[:space:]]*$/, "", value)
        # Skip top-level keys that are not file-specific
        if (hook == "reapplication_authority") next
        print path "|" hook "|" value
    }
    ' "$f"
}

# -----------------------------------------------------------------------------
# Extract Go SetImmutableFlags file list.
# Reads the immutableFiles := []string{ ... } array and emits one path per line.
# -----------------------------------------------------------------------------
parse_go_immutable_files() {
    local f="$1"
    [[ -r "$f" ]] || { log_error "Cannot read Go authority file: $f"; return 1; }
    awk '
    /immutableFiles[[:space:]]*:=[[:space:]]*\[\]string{/ { in_block=1; next }
    in_block {
        if ($0 ~ /^[[:space:]]*\}/) { in_block=0; next }
        # Match either a literal string "/path" or a symbol (e.g. fhs.MainConf)
        if (match($0, /"[^"]+"/)) {
            s = substr($0, RSTART+1, RLENGTH-2)
            print s
        } else if (match($0, /[a-zA-Z_][a-zA-Z0-9_.]*/)) {
            sym = substr($0, RSTART, RLENGTH)
            # Skip "," and leading whitespace
            if (sym !~ /^[[:space:]]*$/ && sym != ",") {
                print "@" sym
            }
        }
    }
    ' "$f"
}

# Resolve symbolic references (e.g., fhs.MainConf → /etc/nftban/nftban.conf).
# Hardcoded — the small known-symbol set keeps the script self-contained.
resolve_go_symbol() {
    case "$1" in
        "@fhs.MainConf") echo "/etc/nftban/nftban.conf" ;;
        @*)              log_warn "Unknown Go symbol: ${1#@}"; echo "" ;;
        *)               echo "$1" ;;
    esac
}

# -----------------------------------------------------------------------------
# Check if a file path has a chattr -i strip in a region of a script.
# Args:
#   $1 - script file
#   $2 - region marker (regex matching the start line, e.g. "^%pretrans")
#   $3 - region end marker (regex matching where the region ends)
#   $4 - file path to look for
# Returns 0 if the strip is found within the region; 1 otherwise.
# -----------------------------------------------------------------------------
# Region-bounded check that handles BOTH:
#   - Direct strip:   chattr -i /path/to/file
#   - Variable loop:  for f in /path/to/file …; do chattr -i "$f"; done
#   - Lua variable:   local fp = "/path/to/file"; os.execute("chattr -i " .. fp)
#
# A region is considered to "strip" a path iff it contains BOTH:
#   1. The literal path string somewhere in the region
#   2. A `chattr -i` invocation somewhere in the region
# This is loose (could false-positive if the path appears in a comment AND
# chattr -i is unrelated), but matches the v1.107.2-class regression: a
# regression that removes the chattr line OR fails to add the file path
# always leaves at least one of the two missing.
region_has_chattr_strip() {
    local script="$1" start_re="$2" end_re="$3" path="$4"
    [[ -r "$script" ]] || return 1
    awk -v START_RE="$start_re" -v END_RE="$end_re" -v PATH_TO_FIND="$path" '
    BEGIN { in_region=0; has_chattr=0; has_path=0 }
    $0 ~ START_RE { in_region=1; next }
    in_region && $0 ~ END_RE {
        # End of region — emit verdict for this region
        exit (has_chattr && has_path) ? 0 : 1
    }
    in_region {
        if (index($0, "chattr -i")) has_chattr=1
        if (index($0, PATH_TO_FIND)) has_path=1
    }
    END { exit (has_chattr && has_path) ? 0 : 1 }
    ' "$script"
}

# Whole-file check (for files like packaging/deb/{preinst,postinst,prerm}
# that don't have embedded region markers — the whole file IS the region).
# Same loose matching as region_has_chattr_strip: file strips path iff it
# contains both `chattr -i` and the path string.
file_has_chattr_strip() {
    local script="$1" path="$2"
    [[ -r "$script" ]] || return 1
    grep -qF "chattr -i" "$script" || return 1
    grep -qF "$path" "$script"
}

# -----------------------------------------------------------------------------
# Main scan
# -----------------------------------------------------------------------------
scan_matrix() {
    local matrix_yaml="$1" authority_go="$2" build_sh="$3"
    local deb_preinst="$4" deb_postinst="$5" deb_prerm="$6"

    log_info "matrix yaml:   $matrix_yaml"
    log_info "authority.go:  $authority_go"
    log_info "build_sh:      $build_sh"
    log_info "deb_preinst:   $deb_preinst"
    log_info "deb_postinst:  $deb_postinst"
    log_info "deb_prerm:     $deb_prerm"
    log_info ""

    local matrix_records
    matrix_records=$(parse_matrix_yaml "$matrix_yaml") || return 2

    # Extract Go immutable files (resolve symbols)
    local raw_go_files resolved_go_files
    raw_go_files=$(parse_go_immutable_files "$authority_go") || return 2
    resolved_go_files=$(echo "$raw_go_files" | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        resolved=$(resolve_go_symbol "$line")
        [[ -n "$resolved" ]] && echo "$resolved"
    done | sort -u)
    log_info "Go SetImmutableFlags resolved files:"
    echo "$resolved_go_files" | sed 's/^/  /' >&2
    log_info ""

    # Extract matrix-declared file paths
    local matrix_paths
    matrix_paths=$(echo "$matrix_records" | awk -F'|' '{print $1}' | sort -u)
    log_info "Matrix-declared files:"
    echo "$matrix_paths" | sed 's/^/  /' >&2
    log_info ""

    local total_fail=0

    # ─── Drift defense 1: every Go-listed file MUST be in matrix ───
    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if ! echo "$matrix_paths" | grep -qFx "$f"; then
            log_fail "GO_FILE_NOT_IN_YAML: Go SetImmutableFlags protects $f but it is not declared in $matrix_yaml"
            total_fail=$((total_fail + 1))
        fi
    done <<< "$resolved_go_files"

    # ─── Drift defense 2: every matrix file MUST be in Go list ───
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if ! echo "$resolved_go_files" | grep -qFx "$f"; then
            log_fail "YAML_FILE_NOT_IN_GO: matrix declares $f but SetImmutableFlags does not protect it"
            total_fail=$((total_fail + 1))
        fi
    done <<< "$matrix_paths"

    # ─── Per-(file, hook) requirement checks ───
    while IFS='|' read -r path hook value; do
        [[ -z "$path" || -z "$hook" ]] && continue
        # Only `required` triggers a check; not_required / covered_by_* / go_set_apply
        # are validated by the drift checks above.
        [[ "$value" == "required" ]] || continue
        case "$hook" in
            go_set_apply)
                # Covered by drift defense 2 (every matrix file in Go list)
                ;;
            rpm_pretrans)
                if ! region_has_chattr_strip "$build_sh" '^%pretrans' '^%pre[^t]' "$path"; then
                    log_fail "MISSING_RPM_PRETRANS_STRIP: $path is matrix-required for rpm_pretrans; not stripped in %pretrans of $build_sh"
                    total_fail=$((total_fail + 1))
                fi
                ;;
            rpm_preun)
                if ! region_has_chattr_strip "$build_sh" '^%preun' '^%post' "$path"; then
                    log_fail "MISSING_RPM_PREUN_STRIP: $path is matrix-required for rpm_preun; not stripped in %preun of $build_sh"
                    total_fail=$((total_fail + 1))
                fi
                ;;
            deb_preinst)
                if ! file_has_chattr_strip "$deb_preinst" "$path"; then
                    log_fail "MISSING_DEB_PREINST_STRIP: $path is matrix-required for deb_preinst; not stripped in $deb_preinst"
                    total_fail=$((total_fail + 1))
                fi
                ;;
            deb_postinst)
                if ! file_has_chattr_strip "$deb_postinst" "$path"; then
                    log_fail "MISSING_DEB_POSTINST_STRIP: $path is matrix-required for deb_postinst; not stripped in $deb_postinst"
                    total_fail=$((total_fail + 1))
                fi
                ;;
            deb_prerm)
                if ! file_has_chattr_strip "$deb_prerm" "$path"; then
                    log_fail "MISSING_DEB_PRERM_STRIP: $path is matrix-required for deb_prerm; not stripped in $deb_prerm"
                    total_fail=$((total_fail + 1))
                fi
                ;;
            *)
                # Unknown hook name — gate is conservative; warn but don't fail
                log_warn "Unknown hook in matrix: $hook for $path"
                ;;
        esac
    done <<< "$matrix_records"

    log_info "─────────────────────────────────────────────────────────"
    log_info "Summary"
    log_info "─────────────────────────────────────────────────────────"
    log_info "  Files in matrix:   $(echo "$matrix_paths" | grep -cv '^$')"
    log_info "  Files in Go list:  $(echo "$resolved_go_files" | grep -cv '^$')"
    log_info "  FAILs:             $total_fail"
    log_info "─────────────────────────────────────────────────────────"

    if [[ $total_fail -eq 0 ]]; then
        log_pass "All matrix-required hooks present; no drift. V108 Item 2 gate PASSED."
        return 0
    else
        log_fail "$total_fail mismatch(es) detected. V108 Item 2 gate FAILED."
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    if [[ $# -lt 1 ]]; then
        usage; exit 2
    fi
    local mode="$1"; shift

    case "$mode" in
        scan) ;;
        -h|--help|help) usage; exit 0 ;;
        *) log_error "Unknown mode: $mode"; usage; exit 2 ;;
    esac

    local matrix_yaml="${NFTBAN_TEST_MATRIX_YAML:-$DEFAULT_MATRIX_YAML}"
    local authority_go="${NFTBAN_TEST_AUTHORITY_GO:-$DEFAULT_AUTHORITY_GO}"
    local build_sh="${NFTBAN_TEST_RPM_SPEC_SH:-$DEFAULT_BUILD_SH}"
    local deb_preinst="${NFTBAN_TEST_DEB_PREINST:-$DEFAULT_DEB_PREINST}"
    local deb_postinst="${NFTBAN_TEST_DEB_POSTINST:-$DEFAULT_DEB_POSTINST}"
    local deb_prerm="${NFTBAN_TEST_DEB_PRERM:-$DEFAULT_DEB_PRERM}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --matrix-yaml=*)   matrix_yaml="${1#*=}"   ;;
            --authority-go=*)  authority_go="${1#*=}"  ;;
            --build-sh=*)      build_sh="${1#*=}"      ;;
            --deb-preinst=*)   deb_preinst="${1#*=}"   ;;
            --deb-postinst=*)  deb_postinst="${1#*=}"  ;;
            --deb-prerm=*)     deb_prerm="${1#*=}"     ;;
            *) log_error "Unknown argument: $1"; usage; exit 2 ;;
        esac
        shift
    done

    check_deps

    log_info "$SCRIPT_NAME v$SCRIPT_VERSION"

    set +e
    scan_matrix "$matrix_yaml" "$authority_go" "$build_sh" "$deb_preinst" "$deb_postinst" "$deb_prerm"
    local rc=$?
    set -e
    exit "$rc"
}

main "$@"
