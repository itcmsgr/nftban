#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.107 — V108 Item 1: systemd Exec* payload-resolution CI gate
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="test-systemd-execstart-payload-resolution"
# meta:type="ci-script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-10"
# meta:description="V108 Item 1 CI gate: every active installed systemd unit's Exec* paths must resolve to artifacts shipped in both RPM and DEB package payloads"
# meta:inventory.files="scripts/ci/test-systemd-execstart-payload-resolution.sh, scripts/ci/data/system-binaries-allowlist.txt, build/deprecated-units.yaml"
# meta:inventory.binaries="bash, awk, grep, sed, find, file, sort, comm, rpm2cpio, cpio, dpkg-deb"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
#
# Implements V108 Item 1 per the project audit scope artifact:
#   V108_ITEM1_EXECSTART_PAYLOAD_RESOLUTION_SCOPE.md
#
# Compile-time complement to runtime assertion `systemd_execstart_paths_ok`
# (internal/installer/validate/assertions.go::assertSystemdExecStartPaths).
# Runtime version inspects /usr/lib/systemd/system/ on a deployed host;
# THIS script inspects the BUILT RPM/DEB package payloads before release.
#
# Modes:
#   validate --rpm-payload=<dir> --deb-payload=<dir>
#       Validate two already-extracted package payloads against each other.
#       Each payload dir is the rootfs of a package extraction (i.e.,
#       contains usr/lib/systemd/system/, usr/lib/nftban/, usr/sbin/, etc.).
#       This is the form CI uses after build-packages.yml extracts artifacts.
#
#   validate --rpm=<file.rpm> --deb=<file.deb>
#       Extract both packages into temp dirs, then run validation.
#       Convenience wrapper for local testing.
#
# Optional flags:
#   --deprecated-yaml=<path>           Override default build/deprecated-units.yaml
#   --system-binary-allowlist=<path>   Override default scripts/ci/data/system-binaries-allowlist.txt
#   --verbose                          Emit per-directive classification rows
#   --strict-system-binary             Treat unlisted system binaries as FAIL
#                                      (default: warn)
#
# Exit codes:
#   0  PASS — all Exec* paths resolve cleanly
#   1  FAIL — at least one failure mode triggered (see report)
#   2  Invalid usage / missing dependency
#
# Failure mode taxonomy:
#   INVALID_MISSING_PATH                    Exec* path not present in
#                                            either packager's payload
#   DEPRECATED_UNIT_RESIDUE_IN_ACTIVE_UNIT  Active unit name matches
#                                            deprecated-units.yaml entry
#   PARITY_UNIT_PRESENT_IN_ONE_PACKAGER     Unit shipped by RPM but not DEB
#                                            (or vice versa)
#   PARITY_EXEC_PATH_RESOLUTION_DIVERGENT   Exec* path present in one
#                                            packager but not the other
#   STALE_RESIDUE_INCOHERENT_STATE          A unit is BOTH in active
#                                            install/systemd AND in
#                                            deprecated-units.yaml
#   SYSTEM_BINARY_NOT_IN_ALLOWLIST          Active unit Exec* references
#                                            a system binary not in
#                                            allowlist (strict mode only)
#
# Output format (deterministic, sorted):
#   <unit>|<directive>|<exec-path>|<classification>|<packager>
# =============================================================================

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Constants & defaults
# -----------------------------------------------------------------------------
SCRIPT_NAME="test-systemd-execstart-payload-resolution"
SCRIPT_VERSION="1.0.0"

# Resolve repo root from this script's location (scripts/ci/SCRIPT.sh)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DEFAULT_DEPRECATED_YAML="$REPO_ROOT/build/deprecated-units.yaml"
DEFAULT_SYSTEM_ALLOWLIST="$REPO_ROOT/scripts/ci/data/system-binaries-allowlist.txt"

# -----------------------------------------------------------------------------
# Logging
# -----------------------------------------------------------------------------
log_info()  { printf '[%s] [INFO] %s\n'  "$SCRIPT_NAME" "$*" >&2; }
log_warn()  { printf '[%s] [WARN] %s\n'  "$SCRIPT_NAME" "$*" >&2; }
log_error() { printf '[%s] [ERROR] %s\n' "$SCRIPT_NAME" "$*" >&2; }
log_pass()  { printf '[%s] [PASS] %s\n'  "$SCRIPT_NAME" "$*" >&2; }
log_fail()  { printf '[%s] [FAIL] %s\n'  "$SCRIPT_NAME" "$*" >&2; }

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------
usage() {
    cat >&2 <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION — V108 Item 1 CI gate

Usage:
  $0 validate --rpm-payload=<dir> --deb-payload=<dir> [options]
  $0 validate --rpm=<file.rpm> --deb=<file.deb> [options]

Options:
  --deprecated-yaml=<path>           (default: build/deprecated-units.yaml)
  --system-binary-allowlist=<path>   (default: scripts/ci/data/system-binaries-allowlist.txt)
  --verbose                          Emit per-directive classification
  --strict-system-binary             FAIL on system binaries not in allowlist
                                     (default: WARN)

Exit codes:
  0  PASS    1  FAIL    2  invalid usage / missing dep
EOF
}

# -----------------------------------------------------------------------------
# Dependency check
# -----------------------------------------------------------------------------
check_deps() {
    local missing=()
    local cmd
    for cmd in awk grep sed find file sort comm; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        exit 2
    fi
}

# Optional deps (only needed for direct-file mode)
need_extraction_tools() {
    local missing=()
    command -v rpm2cpio >/dev/null 2>&1 || missing+=("rpm2cpio")
    command -v cpio     >/dev/null 2>&1 || missing+=("cpio")
    command -v dpkg-deb >/dev/null 2>&1 || missing+=("dpkg-deb")
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "--rpm=/--deb= modes require: ${missing[*]}"
        exit 2
    fi
}

# -----------------------------------------------------------------------------
# Load system-binary allowlist (one path per line, comments + blanks ignored)
# -----------------------------------------------------------------------------
SYSTEM_BINARIES=()
load_system_allowlist() {
    local f="$1"
    if [[ ! -f "$f" ]]; then
        log_error "System-binary allowlist not found: $f"
        exit 2
    fi
    while IFS= read -r line; do
        # Strip comments + whitespace
        line="${line%%#*}"
        line="$(echo "$line" | awk '{$1=$1; print}')"
        [[ -z "$line" ]] && continue
        SYSTEM_BINARIES+=("$line")
    done < "$f"
}

is_system_binary() {
    local path="$1"
    local b
    for b in "${SYSTEM_BINARIES[@]}"; do
        [[ "$path" == "$b" ]] && return 0
    done
    return 1
}

# -----------------------------------------------------------------------------
# Load deprecated-units.yaml — extract unit names (under any `units:` list)
# -----------------------------------------------------------------------------
DEPRECATED_UNITS=()
load_deprecated_yaml() {
    local f="$1"
    if [[ ! -f "$f" ]]; then
        log_error "Deprecated-units yaml not found: $f"
        exit 2
    fi
    # Extract `- name:` entries (most common yaml-list pattern)
    # Falls back to `name:` lines if structure differs
    local names
    names="$(awk '
        /^[[:space:]]*-?[[:space:]]*name:[[:space:]]*/ {
            sub(/^[[:space:]]*-?[[:space:]]*name:[[:space:]]*/, "")
            gsub(/["'\'']/, "")
            sub(/[[:space:]]*#.*$/, "")
            print
        }
    ' "$f")"
    if [[ -z "$names" ]]; then
        # Fallback: also accept `unit:` keys (defensive)
        names="$(awk '
            /^[[:space:]]*-?[[:space:]]*unit:[[:space:]]*/ {
                sub(/^[[:space:]]*-?[[:space:]]*unit:[[:space:]]*/, "")
                gsub(/["'\'']/, "")
                sub(/[[:space:]]*#.*$/, "")
                print
            }
        ' "$f")"
    fi
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        DEPRECATED_UNITS+=("$line")
    done <<< "$names"
}

is_deprecated_unit() {
    local unit="$1"
    local d
    for d in "${DEPRECATED_UNITS[@]}"; do
        [[ "$unit" == "$d" ]] && return 0
    done
    return 1
}

# -----------------------------------------------------------------------------
# Locate systemd unit directory inside an extracted package payload
# Returns the first existing directory among the standard candidates.
# -----------------------------------------------------------------------------
locate_systemd_dir() {
    local root="$1"
    local candidates=(
        "$root/usr/lib/systemd/system"
        "$root/lib/systemd/system"
    )
    local c
    for c in "${candidates[@]}"; do
        [[ -d "$c" ]] && { echo "$c"; return 0; }
    done
    return 1
}

# -----------------------------------------------------------------------------
# Extract Exec* directives from a single unit file.
# Emits lines: <directive>|<exec-path>
# Handles:
#   - flag prefixes -+:!@  (per systemd.exec(5))
#   - shell wrappers /bin/sh -c '...' / /bin/bash -c '...' — emits the
#     shell binary as the resolvable path
#   - line continuations (\) — concatenated by sed pre-pass
# -----------------------------------------------------------------------------
parse_exec_directives() {
    local unit_file="$1"
    # 1. Join line continuations (backslash at EOL)
    # 2. Match Exec* directives only at start-of-line
    # 3. Strip the directive name and leading whitespace
    # 4. Strip flag prefix [-+:!@]+
    # 5. Take the first whitespace-delimited token (the executable path)
    awk '
        BEGIN { buf = "" }
        {
            if (match($0, /\\$/)) {
                buf = buf substr($0, 1, RSTART-1)
                next
            }
            line = buf $0
            buf = ""
            if (line ~ /^Exec(Start|StartPre|StartPost|Stop|StopPost|Reload|Condition)=/) {
                # Extract directive name (before =)
                directive = line
                sub(/=.*$/, "", directive)
                # Extract value (after =)
                value = line
                sub(/^Exec[A-Za-z]+=/, "", value)
                # Strip flag prefix
                sub(/^[-+:!@]+/, "", value)
                # First whitespace-separated token
                split(value, tok, /[[:space:]]+/)
                path = tok[1]
                if (path != "") {
                    print directive "|" path
                }
            }
        }
    ' "$unit_file"
}

# -----------------------------------------------------------------------------
# Check whether a path is present in the package payload root
# -----------------------------------------------------------------------------
path_present_in_payload() {
    local payload_root="$1"
    local path="$2"
    # Convert absolute path to relative under payload root
    local rel="${path#/}"
    local candidate="$payload_root/$rel"
    if [[ -e "$candidate" ]]; then
        return 0
    fi
    return 1
}

# -----------------------------------------------------------------------------
# Enumerate unit files in a systemd dir, returning bare unit names
# -----------------------------------------------------------------------------
list_unit_names() {
    local sysd_dir="$1"
    if [[ ! -d "$sysd_dir" ]]; then
        return
    fi
    find "$sysd_dir" -maxdepth 1 -type f \
        \( -name '*.service' -o -name '*.socket' -o -name '*.timer' -o -name '*.target' \) \
        -printf '%f\n' 2>/dev/null | sort
}

# -----------------------------------------------------------------------------
# Main validation
# -----------------------------------------------------------------------------
validate_payloads() {
    local rpm_root="$1"
    local deb_root="$2"
    local verbose="$3"
    local strict_system="$4"

    local rpm_sysd deb_sysd
    if ! rpm_sysd=$(locate_systemd_dir "$rpm_root"); then
        log_error "No systemd unit dir found under RPM payload: $rpm_root"
        log_error "Expected: $rpm_root/usr/lib/systemd/system or $rpm_root/lib/systemd/system"
        return 1
    fi
    if ! deb_sysd=$(locate_systemd_dir "$deb_root"); then
        log_error "No systemd unit dir found under DEB payload: $deb_root"
        log_error "Expected: $deb_root/usr/lib/systemd/system or $deb_root/lib/systemd/system"
        return 1
    fi
    log_info "RPM systemd dir: $rpm_sysd"
    log_info "DEB systemd dir: $deb_sysd"

    # Enumerate units in each
    local rpm_units_file deb_units_file
    rpm_units_file=$(mktemp)
    deb_units_file=$(mktemp)
    trap 'rm -f "$rpm_units_file" "$deb_units_file"' RETURN

    list_unit_names "$rpm_sysd" > "$rpm_units_file"
    list_unit_names "$deb_sysd" > "$deb_units_file"

    local rpm_count deb_count
    rpm_count=$(wc -l < "$rpm_units_file")
    deb_count=$(wc -l < "$deb_units_file")
    log_info "RPM units: $rpm_count   DEB units: $deb_count"

    # -------------------------------------------------------------------------
    # Check 1: STALE_RESIDUE_INCOHERENT_STATE
    # Any unit listed in deprecated-units.yaml MUST NOT appear in active
    # install payloads.
    # -------------------------------------------------------------------------
    local total_failures=0
    local report_file
    report_file=$(mktemp)
    trap 'rm -f "$rpm_units_file" "$deb_units_file" "$report_file"' RETURN

    local d
    for d in "${DEPRECATED_UNITS[@]}"; do
        if grep -qFx "$d" "$rpm_units_file"; then
            log_fail "STALE_RESIDUE_INCOHERENT_STATE: $d is in deprecated-units.yaml AND in RPM active payload"
            echo "$d|—|—|STALE_RESIDUE_INCOHERENT_STATE|rpm" >> "$report_file"
            total_failures=$((total_failures + 1))
        fi
        if grep -qFx "$d" "$deb_units_file"; then
            log_fail "STALE_RESIDUE_INCOHERENT_STATE: $d is in deprecated-units.yaml AND in DEB active payload"
            echo "$d|—|—|STALE_RESIDUE_INCOHERENT_STATE|deb" >> "$report_file"
            total_failures=$((total_failures + 1))
        fi
    done

    # -------------------------------------------------------------------------
    # Check 2: PARITY_UNIT_PRESENT_IN_ONE_PACKAGER
    # Every active unit must ship in BOTH RPM and DEB.
    # -------------------------------------------------------------------------
    local only_rpm only_deb
    only_rpm=$(comm -23 "$rpm_units_file" "$deb_units_file")
    only_deb=$(comm -13 "$rpm_units_file" "$deb_units_file")

    if [[ -n "$only_rpm" ]]; then
        while IFS= read -r u; do
            [[ -z "$u" ]] && continue
            log_fail "PARITY_UNIT_PRESENT_IN_ONE_PACKAGER: $u in RPM but not DEB"
            echo "$u|—|—|PARITY_UNIT_PRESENT_IN_ONE_PACKAGER|rpm-only" >> "$report_file"
            total_failures=$((total_failures + 1))
        done <<< "$only_rpm"
    fi
    if [[ -n "$only_deb" ]]; then
        while IFS= read -r u; do
            [[ -z "$u" ]] && continue
            log_fail "PARITY_UNIT_PRESENT_IN_ONE_PACKAGER: $u in DEB but not RPM"
            echo "$u|—|—|PARITY_UNIT_PRESENT_IN_ONE_PACKAGER|deb-only" >> "$report_file"
            total_failures=$((total_failures + 1))
        done <<< "$only_deb"
    fi

    # -------------------------------------------------------------------------
    # Check 3: For each unit present in BOTH (the intersection), parse
    # Exec* directives and resolve each path.
    # -------------------------------------------------------------------------
    local common_units
    common_units=$(comm -12 "$rpm_units_file" "$deb_units_file")

    local exec_directive_count=0
    local exec_path_pass_count=0

    while IFS= read -r unit; do
        [[ -z "$unit" ]] && continue

        # Defensive: a unit in active install AND deprecated yaml was caught
        # in Check 1; skip parsing of confirmed-bad units to avoid noise.
        if is_deprecated_unit "$unit"; then
            continue
        fi

        local rpm_unit_file="$rpm_sysd/$unit"
        # deb_unit_file kept for symmetry / future DEB-side checks but not
        # currently consumed; RPM-side is authoritative per the assertion
        # below. v1.124.1: explicitly suppress SC2034 to silence the
        # baseline Project Health workflow warning.
        # shellcheck disable=SC2034
        local deb_unit_file="$deb_sysd/$unit"

        # Parse Exec* from RPM-side unit file (authoritative; should match DEB)
        local directives
        if ! directives=$(parse_exec_directives "$rpm_unit_file"); then
            continue
        fi
        [[ -z "$directives" ]] && continue

        while IFS='|' read -r directive exec_path; do
            [[ -z "$directive" || -z "$exec_path" ]] && continue
            exec_directive_count=$((exec_directive_count + 1))

            local classification=""
            local packager_tag=""

            # 3a: System binary?
            if is_system_binary "$exec_path"; then
                classification="SYSTEM_BINARY_ALLOWLISTED"
                packager_tag="-"
                exec_path_pass_count=$((exec_path_pass_count + 1))
            else
                # 3b: Resolve against RPM and DEB payloads
                local in_rpm=0 in_deb=0
                path_present_in_payload "$rpm_root" "$exec_path" && in_rpm=1
                path_present_in_payload "$deb_root" "$exec_path" && in_deb=1

                if [[ $in_rpm -eq 1 && $in_deb -eq 1 ]]; then
                    classification="PACKAGE_PAYLOAD"
                    packager_tag="both"
                    exec_path_pass_count=$((exec_path_pass_count + 1))
                elif [[ $in_rpm -eq 1 && $in_deb -eq 0 ]]; then
                    classification="PARITY_EXEC_PATH_RESOLUTION_DIVERGENT"
                    packager_tag="rpm-only"
                    total_failures=$((total_failures + 1))
                    log_fail "PARITY_EXEC_PATH_RESOLUTION_DIVERGENT: $unit:$directive=$exec_path resolves in RPM but not DEB"
                elif [[ $in_rpm -eq 0 && $in_deb -eq 1 ]]; then
                    classification="PARITY_EXEC_PATH_RESOLUTION_DIVERGENT"
                    packager_tag="deb-only"
                    total_failures=$((total_failures + 1))
                    log_fail "PARITY_EXEC_PATH_RESOLUTION_DIVERGENT: $unit:$directive=$exec_path resolves in DEB but not RPM"
                else
                    # 3c: Neither — likely INVALID_MISSING_PATH unless it's an
                    # unlisted system binary
                    if [[ "$exec_path" == /bin/* || "$exec_path" == /usr/bin/* || "$exec_path" == /sbin/* || "$exec_path" == /usr/sbin/* ]]; then
                        # Could be a system binary not in our allowlist
                        if [[ "$strict_system" == "yes" ]]; then
                            classification="SYSTEM_BINARY_NOT_IN_ALLOWLIST"
                            packager_tag="-"
                            total_failures=$((total_failures + 1))
                            log_fail "SYSTEM_BINARY_NOT_IN_ALLOWLIST: $unit:$directive=$exec_path (not in allowlist, strict mode)"
                        else
                            classification="SYSTEM_BINARY_UNLISTED_WARN"
                            packager_tag="-"
                            log_warn "SYSTEM_BINARY_UNLISTED_WARN: $unit:$directive=$exec_path (not in allowlist)"
                            exec_path_pass_count=$((exec_path_pass_count + 1))
                        fi
                    else
                        classification="INVALID_MISSING_PATH"
                        packager_tag="neither"
                        total_failures=$((total_failures + 1))
                        log_fail "INVALID_MISSING_PATH: $unit:$directive=$exec_path missing from both RPM and DEB"
                    fi
                fi
            fi

            echo "$unit|$directive|$exec_path|$classification|$packager_tag" >> "$report_file"
        done <<< "$directives"
    done <<< "$common_units"

    # -------------------------------------------------------------------------
    # Emit deterministic report
    # -------------------------------------------------------------------------
    log_info "─────────────────────────────────────────────────────────"
    log_info "Report (sorted):"
    log_info "─────────────────────────────────────────────────────────"
    if [[ "$verbose" == "yes" ]]; then
        sort "$report_file" | sed 's/^/  /' >&2
    else
        # Quiet mode: only show failures
        sort "$report_file" | grep -E '\|(INVALID_MISSING_PATH|DEPRECATED_UNIT_RESIDUE_IN_ACTIVE_UNIT|PARITY_UNIT_PRESENT_IN_ONE_PACKAGER|PARITY_EXEC_PATH_RESOLUTION_DIVERGENT|STALE_RESIDUE_INCOHERENT_STATE|SYSTEM_BINARY_NOT_IN_ALLOWLIST)\|' | sed 's/^/  /' >&2 || true
    fi
    log_info "─────────────────────────────────────────────────────────"
    log_info "Summary:"
    log_info "  Units in RPM:                 $rpm_count"
    log_info "  Units in DEB:                 $deb_count"
    log_info "  Common units validated:       $(echo "$common_units" | grep -cv '^$' || echo 0)"
    log_info "  Exec* directives parsed:      $exec_directive_count"
    log_info "  Exec* paths PASSED:           $exec_path_pass_count"
    log_info "  Failures:                     $total_failures"
    log_info "─────────────────────────────────────────────────────────"

    if [[ $total_failures -eq 0 ]]; then
        log_pass "All Exec* paths resolve cleanly. V108 Item 1 gate PASSED."
        return 0
    else
        log_fail "$total_failures failure(s) detected. V108 Item 1 gate FAILED."
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Extract RPM into a temp directory (caller is responsible for cleanup)
# -----------------------------------------------------------------------------
extract_rpm() {
    local rpm_file="$1"
    local out_dir="$2"
    mkdir -p "$out_dir"
    (
        cd "$out_dir"
        rpm2cpio "$rpm_file" | cpio -idm --quiet 2>/dev/null
    )
}

extract_deb() {
    local deb_file="$1"
    local out_dir="$2"
    mkdir -p "$out_dir"
    dpkg-deb -x "$deb_file" "$out_dir"
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
main() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 2
    fi

    local mode="$1"
    shift

    case "$mode" in
        validate)
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown mode: $mode"
            usage
            exit 2
            ;;
    esac

    local rpm_payload="" deb_payload="" rpm_file="" deb_file=""
    local deprecated_yaml="$DEFAULT_DEPRECATED_YAML"
    local system_allowlist="$DEFAULT_SYSTEM_ALLOWLIST"
    local verbose="no"
    local strict_system="no"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --rpm-payload=*)            rpm_payload="${1#*=}"            ;;
            --deb-payload=*)            deb_payload="${1#*=}"            ;;
            --rpm=*)                    rpm_file="${1#*=}"               ;;
            --deb=*)                    deb_file="${1#*=}"               ;;
            --deprecated-yaml=*)        deprecated_yaml="${1#*=}"        ;;
            --system-binary-allowlist=*) system_allowlist="${1#*=}"      ;;
            --verbose)                  verbose="yes"                    ;;
            --strict-system-binary)     strict_system="yes"              ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 2
                ;;
        esac
        shift
    done

    check_deps
    load_deprecated_yaml "$deprecated_yaml"
    load_system_allowlist "$system_allowlist"

    log_info "$SCRIPT_NAME v$SCRIPT_VERSION"
    log_info "Deprecated yaml:   $deprecated_yaml (${#DEPRECATED_UNITS[@]} entries)"
    log_info "System allowlist:  $system_allowlist (${#SYSTEM_BINARIES[@]} entries)"

    local cleanup_dir=""
    if [[ -n "$rpm_file" && -n "$deb_file" ]]; then
        need_extraction_tools
        cleanup_dir=$(mktemp -d)
        rpm_payload="$cleanup_dir/rpm-payload"
        deb_payload="$cleanup_dir/deb-payload"
        log_info "Extracting RPM to $rpm_payload"
        extract_rpm "$rpm_file" "$rpm_payload"
        log_info "Extracting DEB to $deb_payload"
        extract_deb "$deb_file" "$deb_payload"
        trap 'rm -rf "$cleanup_dir"' EXIT
    fi

    if [[ -z "$rpm_payload" || -z "$deb_payload" ]]; then
        log_error "validate requires either --rpm-payload + --deb-payload or --rpm + --deb"
        usage
        exit 2
    fi

    if [[ ! -d "$rpm_payload" ]]; then
        log_error "RPM payload dir not found: $rpm_payload"
        exit 2
    fi
    if [[ ! -d "$deb_payload" ]]; then
        log_error "DEB payload dir not found: $deb_payload"
        exit 2
    fi

    if validate_payloads "$rpm_payload" "$deb_payload" "$verbose" "$strict_system"; then
        exit 0
    else
        exit 1
    fi
}

main "$@"
