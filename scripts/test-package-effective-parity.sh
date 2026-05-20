#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.107 - Package Effective Parity Test (PKG-EFFECTIVE-PARITY)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# meta:name="test-package-effective-parity"
# meta:type="test"
# meta:header="Package Effective Parity Test"
# meta:version="1.107.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="L3-L6 invariant gate for RPM/DEB package metadata + installed-fs + reinstall + verify-tool parity"
# meta:inventory.files=""
# meta:inventory.binaries="rpm,dpkg-deb,stat,dnf,apt-get,dpkg"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root (for install/reinstall/verify modes); user (for *-meta modes)"
#
# meta:created_date="2026-05-07"
# meta:updated_date="2026-05-07"
#
# Closes worklog row 14 (PKG-EFFECTIVE-PARITY) when wired into CI:
#   - L3 package-metadata parity (rpm-meta vs deb-meta)
#   - L4 installed-filesystem parity (fresh-stat across packagers)
#   - L5 reinstall + upgrade preservation
#   - L6 verify-tool parity (rpm -V / dpkg --verify)
#
# Modes:
#   rpm-meta <rpm-file>            extract dir metadata from RPM artifact
#   deb-meta <deb-file>            extract dir metadata from DEB artifact
#   fresh-stat                     stat critical paths on installed system
#   reinstall-stat                 alias of fresh-stat (semantic marker)
#   upgrade-stat <phase>           alias of fresh-stat with phase tag (pre|post)
#   verify-tool <rpm|deb>          run rpm -V or dpkg --verify; filter by exceptions
#   diff <file-a> <file-b>         diff two parity tables; emit unified result
#
# Output format (stdout, deterministic, sorted):
#   <path>|<type>|<mode>|<owner>|<group>
#   - type: dir / file / link / other
#   - mode: 0NNN octal
#
# Exit codes:
#   0  success / clean
#   1  divergence detected
#   2  invalid usage / missing dependency
#   3  artifact missing / unreadable
#
# CRITICAL: 11 paths are HARDCODED below from V107_PKG_EFFECTIVE_PARITY_SCOPE.md
# §3 + worklog §6.3.5. They are NOT derived from fhs-spec.yaml at runtime —
# that would make the test circular (spec is the thing under test for L3).
# Path additions/removals require deliberate scope-amendment and edit here.
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# -----------------------------------------------------------------------------
# Critical-path expected metadata table (binding; per scope §3.1)
# Format: <path>|<type>|<mode>|<owner>|<group>|<package_shipped>
#   package_shipped=yes  → applicable to L3 (rpm-meta/deb-meta) + L4 + L5 + L6
#   package_shipped=no   → applicable to L4 (post-tmpfiles) + L5 only (no L3/L6)
# -----------------------------------------------------------------------------
EXPECTED_TABLE=(
    "/etc/nftban|dir|0750|root|nftban|yes"
    "/etc/nftban/conf.d|dir|0750|root|nftban|yes"
    "/etc/nftban/suricata|dir|0750|root|nftban|yes"
    "/etc/nftban/suricata/state|dir|0750|root|nftban|yes"
    "/etc/nftban/suricata/state/last-good|dir|0750|root|nftban|yes"
    "/run/nftban|dir|0755|nftban|nftban|no"
    "/var/cache/nftban|dir|0755|nftban|nftban|no"
    "/var/lib/nftban|dir|0750|root|nftban|no"
    "/var/lib/nftban/community|dir|0750|nftban|nftban|yes"
    "/var/lib/nftban/reports/auditors|dir|0770|root|nftban-auditor|no"
    "/var/log/nftban|dir|0750|nftban|nftban|no"
)

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

log_info() { echo "[INFO] $*" >&2; }
log_err()  { echo "[ERROR] $*" >&2; }
log_pass() { echo "[PASS] $*" >&2; }
log_fail() { echo "[FAIL] $*" >&2; }

# Convert ls-style mode 'drwxr-x---' or '-rw-r--r--' to octal '0750' / '0644'.
ls_mode_to_octal() {
    local m="$1"
    [[ ${#m} -lt 10 ]] && { echo "0000"; return; }
    local u=0 g=0 o=0
    [[ "${m:1:1}" == "r" ]] && u=$((u + 4))
    [[ "${m:2:1}" == "w" ]] && u=$((u + 2))
    case "${m:3:1}" in x|s) u=$((u + 1)) ;; esac
    [[ "${m:4:1}" == "r" ]] && g=$((g + 4))
    [[ "${m:5:1}" == "w" ]] && g=$((g + 2))
    case "${m:6:1}" in x|s) g=$((g + 1)) ;; esac
    [[ "${m:7:1}" == "r" ]] && o=$((o + 4))
    [[ "${m:8:1}" == "w" ]] && o=$((o + 2))
    case "${m:9:1}" in x|t) o=$((o + 1)) ;; esac
    printf "0%d%d%d\n" "$u" "$g" "$o"
}

# Convert ls-style first char to type tag.
ls_type_from_mode() {
    case "${1:0:1}" in
        d) echo "dir" ;;
        -) echo "file" ;;
        l) echo "link" ;;
        *) echo "other" ;;
    esac
}

# Critical-path set as a newline-delimited list (for grep -F filtering).
critical_paths_list() {
    printf '%s\n' "${EXPECTED_TABLE[@]}" | cut -d'|' -f1
}

# Critical-path set as a regex anchor pattern (for awk filtering).
# Returns lines where the path field is exactly one of the 11 critical paths.
critical_path_filter_awk() {
    awk -F'|' -v paths="$(critical_paths_list)" '
        BEGIN { split(paths, p, "\n"); for (i in p) keep[p[i]] = 1 }
        keep[$1] { print }
    '
}

# Look up expected row for a path; emits |-separated row or empty if not in set.
expected_for_path() {
    local target="$1"
    local row
    for row in "${EXPECTED_TABLE[@]}"; do
        [[ "${row%%|*}" == "$target" ]] && { echo "$row"; return; }
    done
}

# Check whether a path is in the critical set.
is_critical_path() {
    local target="$1"
    local row
    for row in "${EXPECTED_TABLE[@]}"; do
        [[ "${row%%|*}" == "$target" ]] && return 0
    done
    return 1
}

# -----------------------------------------------------------------------------
# Mode: rpm-meta — extract dir metadata from RPM artifact via `rpm -qplv`
# -----------------------------------------------------------------------------
# Defensive parser: rpm -qplv output column counts shift between rpm versions
# and locales. Recent files use date "Mon Day HH:MM" (3 columns), older/future
# files use "Mon Day Year" (also 3 columns), but some rpm builds emit extra
# columns (selinux context, capabilities) and the LANG-dependent month name
# may contain non-ASCII characters. The previous fixed-position read pattern
# silently produced 0 lines on Rocky 9 / EL 9-family containers in CI.
#
# Parse each line into an array. Mode/owner/group are at stable positions
# (1, 3, 4 — these have been canonical since RPM 4.0). Path is the LAST
# whitespace-separated field (none of our 11 critical paths contain spaces;
# paths in the FHS namespace never do in practice). Fail loudly if rpm itself
# fails or produces empty output, so the aggregator surfaces the real cause
# rather than silently passing on no data.
mode_rpm_meta() {
    local rpm_file="${1:?usage: rpm-meta <rpm-file>}"
    [[ -r "$rpm_file" ]] || { log_err "RPM not readable: $rpm_file"; exit 3; }
    command -v rpm >/dev/null || { log_err "rpm not installed"; exit 2; }

    # Force C locale so month names + decimal separators are predictable
    # across CI containers; capture all output to surface failures explicitly.
    local raw
    if ! raw=$(LC_ALL=C rpm -qplv "$rpm_file" 2>/dev/null); then
        log_err "rpm -qplv failed for $rpm_file"
        exit 1
    fi
    if [[ -z "$raw" ]]; then
        log_err "rpm -qplv produced empty output for $rpm_file"
        exit 1
    fi

    # Parse line-by-line; emit only critical paths in canonical format.
    local out
    out=$(printf '%s\n' "$raw" | awk '
        /^[-dlcbps]/ {
            # Field 1 = mode (e.g. drwxr-x---), Field 3 = owner, Field 4 = group.
            # Field NF = path (last whitespace-separated token; safe for FHS).
            mode = $1
            owner = $3
            group = $4
            path = $NF
            # Skip lines whose last field is not an absolute path.
            if (path !~ /^\//) next
            # Skip if line did not yield enough fields for a valid record.
            if (NF < 5) next
            print path "|" mode "|" owner "|" group
        }
    ')

    if [[ -z "$out" ]]; then
        log_err "rpm-meta parsed zero records from $rpm_file (rpm output was non-empty; parser may need adjustment)"
        log_err "First 5 raw lines for diagnosis:"
        printf '%s\n' "$raw" | head -5 >&2
        exit 1
    fi

    # Filter to critical paths and convert mode to octal in the shell loop
    # (awk's substr/permission math is more verbose than reusing the existing
    # ls_mode_to_octal helper). Sort -u for deterministic output.
    while IFS='|' read -r path mode owner group; do
        is_critical_path "$path" || continue
        local octal type
        octal=$(ls_mode_to_octal "$mode")
        type=$(ls_type_from_mode "$mode")
        echo "$path|$type|$octal|$owner|$group"
    done <<< "$out" | sort -u
}

# -----------------------------------------------------------------------------
# Mode: deb-meta — extract dir metadata from DEB artifact via `dpkg-deb --contents`
# -----------------------------------------------------------------------------
# Defensive parser: dpkg-deb --contents output column counts can shift between
# dpkg versions and locales. The previous fixed-column read silently produced
# 0 lines on debian12/13 + ubuntu22.04/24.04 containers in CI, hidden behind
# the parallel mode_rpm_meta failure (the L3 RPM assert step ran first and
# aborted the workflow before L3 DEB executed). After 75ebf1ad fixed RPM,
# the empty DEB extraction surfaced as the next blocker.
#
# Parse each line into an array. Mode is at stable position 1; owner/group
# is the combined "owner/group" token at position 2 (canonical since dpkg
# 1.0). Path is the LAST whitespace-separated field — none of our 11 critical
# paths contain spaces, and FHS paths in package archives never do in practice.
# Strip leading "./" and trailing "/" to normalize to absolute paths matching
# the EXPECTED_TABLE keys. Fail loudly if dpkg-deb itself fails or produces
# empty output.
mode_deb_meta() {
    local deb_file="${1:?usage: deb-meta <deb-file>}"
    [[ -r "$deb_file" ]] || { log_err "DEB not readable: $deb_file"; exit 3; }
    command -v dpkg-deb >/dev/null || { log_err "dpkg-deb not installed"; exit 2; }

    # Force C locale for predictable date/decimal formatting across CI
    # containers; capture all output to surface failures explicitly.
    local raw
    if ! raw=$(LC_ALL=C dpkg-deb --contents "$deb_file" 2>/dev/null); then
        log_err "dpkg-deb --contents failed for $deb_file"
        exit 1
    fi
    if [[ -z "$raw" ]]; then
        log_err "dpkg-deb --contents produced empty output for $deb_file"
        exit 1
    fi

    # Parse line-by-line; emit canonical "path|mode|owner|group" rows for any
    # line whose last field is an absolute path (after normalization). Mode is
    # field 1; owner_group is field 2 ("owner/group" combined per dpkg-deb
    # convention); path is field NF (last whitespace-separated token).
    local out
    out=$(printf '%s\n' "$raw" | awk '
        /^[-dlcbps]/ {
            mode = $1
            owner_group = $2
            path = $NF
            # Skip lines whose last field is not a path-like token
            if (path !~ /^\.?\//) next
            # Skip if line did not yield enough fields for a valid record
            if (NF < 4) next
            # Strip leading "./" and trailing "/" from path
            sub(/^\.\//, "", path)
            sub(/\/$/, "", path)
            # Normalize to absolute path
            if (path !~ /^\//) path = "/" path
            # Split owner_group "owner/group" into separate fields
            split(owner_group, og, "/")
            print path "|" mode "|" og[1] "|" og[2]
        }
    ')

    if [[ -z "$out" ]]; then
        log_err "deb-meta parsed zero records from $deb_file (dpkg-deb output was non-empty; parser may need adjustment)"
        log_err "First 5 raw lines for diagnosis:"
        printf '%s\n' "$raw" | head -5 >&2
        exit 1
    fi

    # Filter to critical paths and convert mode to octal in the shell loop
    # (matches mode_rpm_meta pattern; reuses ls_mode_to_octal helper). Sort
    # -u for deterministic output.
    while IFS='|' read -r path mode owner group; do
        is_critical_path "$path" || continue
        local octal type
        octal=$(ls_mode_to_octal "$mode")
        type=$(ls_type_from_mode "$mode")
        echo "$path|$type|$octal|$owner|$group"
    done <<< "$out" | sort -u
}

# -----------------------------------------------------------------------------
# Mode: fresh-stat / reinstall-stat / upgrade-stat — stat live filesystem
# -----------------------------------------------------------------------------
mode_fresh_stat() {
    # v1.124.1: removed unused `expected_type` local + assignment (SC2034
    # baseline Project Health warning). The aggregator path validates the
    # type/owner/group columns; expected_type was never read in this
    # function. If a future check needs it back, add via `cut -d'|' -f2`.
    local row path type
    for row in "${EXPECTED_TABLE[@]}"; do
        path="${row%%|*}"
        if [[ ! -e "$path" ]]; then
            # MISSING is reported as a sentinel row; aggregator treats as failure
            echo "$path|MISSING|-|-|-"
            continue
        fi
        # stat -c '%F %a %U %G' — %F is human-readable type ("directory", "regular file", ...)
        local s_type s_mode s_owner s_group
        s_type=$(stat -c '%F' "$path")
        s_mode=$(stat -c '%a' "$path")
        s_owner=$(stat -c '%U' "$path")
        s_group=$(stat -c '%G' "$path")
        # Normalize stat type to our type tag
        case "$s_type" in
            "directory") type="dir" ;;
            "regular file"|"regular empty file") type="file" ;;
            "symbolic link") type="link" ;;
            *) type="other" ;;
        esac
        # Pad mode to 4 digits ('750' → '0750')
        [[ ${#s_mode} -eq 3 ]] && s_mode="0$s_mode"
        echo "$path|$type|$s_mode|$s_owner|$s_group"
    done | sort -u
}

# -----------------------------------------------------------------------------
# Mode: verify-tool — run rpm -V or dpkg --verify; filter via exceptions
# -----------------------------------------------------------------------------
mode_verify_tool() {
    local kind="${1:?usage: verify-tool <rpm|deb>}"
    local exceptions_file="${EXCEPTIONS_FILE:-$(dirname "$0")/test-package-verify-exceptions.list}"
    local raw filtered_count=0 unexpected=0

    case "$kind" in
        rpm)
            command -v rpm >/dev/null || { log_err "rpm not installed"; exit 2; }
            # rpm -V exits 1 if any modifications detected; we want output regardless
            raw=$(rpm -V nftban-core 2>&1 || true)
            ;;
        deb)
            command -v dpkg >/dev/null || { log_err "dpkg not installed"; exit 2; }
            raw=$(dpkg --verify nftban-core 2>&1 || true)
            ;;
        *)
            log_err "verify-tool kind must be 'rpm' or 'deb'"
            exit 2
            ;;
    esac

    # Load exceptions (lines matching pattern: <path>|<flag-pattern>) — comments allowed
    local -a exceptions=()
    if [[ -r "$exceptions_file" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            exceptions+=("$line")
        done < "$exceptions_file"
    fi

    # Process verify output line-by-line
    if [[ -z "$raw" ]]; then
        echo "VERIFY-CLEAN"
        return 0
    fi

    while IFS= read -r v_line; do
        [[ -z "$v_line" ]] && continue
        local exempted=0 ex
        for ex in "${exceptions[@]}"; do
            local ex_path="${ex%%|*}"
            local ex_pat="${ex#*|}"
            if [[ "$v_line" == *"$ex_path"* ]] && [[ "$v_line" =~ $ex_pat ]]; then
                exempted=1
                break
            fi
        done
        if [[ "$exempted" -eq 1 ]]; then
            filtered_count=$((filtered_count + 1))
            echo "EXEMPTED: $v_line"
        else
            unexpected=$((unexpected + 1))
            echo "UNEXPECTED: $v_line"
        fi
    done <<< "$raw"

    if [[ "$unexpected" -gt 0 ]]; then
        log_fail "verify-tool $kind: $unexpected unexpected entry/entries (filtered $filtered_count exempted)"
        exit 1
    fi
    log_pass "verify-tool $kind: clean ($filtered_count exempted via $exceptions_file)"
}

# -----------------------------------------------------------------------------
# Helper: load path-only list from L3 exception file
# -----------------------------------------------------------------------------
# Reads scripts/test-package-deb-l3-exceptions.list (or any file with the same
# format `<path>|<rationale-tag>`) and emits one path per line. Used by
# mode_diff and mode_assert_expected to honor the postinst-converged authority
# model on the cross-packager (L3) layer only — L4/L5/L6 are unaffected.
load_l3_exception_paths() {
    local exceptions_file="$1"
    [[ -r "$exceptions_file" ]] || return 0
    awk -F'|' '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        NF >= 1 { gsub(/[[:space:]]+$/, "", $1); print $1 }
    ' "$exceptions_file"
}

# -----------------------------------------------------------------------------
# Mode: diff — compare two parity tables; require exact match for shared paths
# -----------------------------------------------------------------------------
# Portable shell-only comparison — does NOT depend on the external `diff`
# binary, which is not preinstalled in minimal EL9 containers
# (rockylinux:9, almalinux:9, centos:stream9). Uses sort + bash string
# equality, with awk-based set-difference reporting on divergence.
#
# Optional 3rd argument: --exceptions=<file>
#   When set, lines whose path field is listed in the exception file are
#   filtered out of BOTH inputs before comparison. This is intended for the
#   L3 cross-packager aggregator only — RPM (`%attr` name-based, applied at
#   install time, archive ships final ownership) vs DEB (postinst-converged,
#   archive ships root:root). The 6 critical postinst-converged paths are
#   listed in scripts/test-package-deb-l3-exceptions.list. L4/L5 (installed-fs
#   stat) and L6 (verify-tool) modes are NOT affected by this option.
mode_diff() {
    local a="${1:?usage: diff <file-a> <file-b> [--exceptions=<file>]}"
    local b="${2:?usage: diff <file-a> <file-b> [--exceptions=<file>]}"
    [[ -r "$a" ]] || { log_err "Not readable: $a"; exit 3; }
    [[ -r "$b" ]] || { log_err "Not readable: $b"; exit 3; }

    local exceptions_file=""
    case "${3:-}" in
        "")            ;;
        --exceptions=*) exceptions_file="${3#--exceptions=}" ;;
        *) log_err "Unknown arg: $3 (expected --exceptions=<file>)"; exit 2 ;;
    esac

    local sorted_a sorted_b filter_count=0
    if [[ -n "$exceptions_file" ]]; then
        if [[ ! -r "$exceptions_file" ]]; then
            log_err "Exceptions file not readable: $exceptions_file"
            exit 3
        fi
        local exception_paths
        exception_paths=$(load_l3_exception_paths "$exceptions_file")
        if [[ -z "$exception_paths" ]]; then
            log_info "Exceptions file present but empty: $exceptions_file"
            sorted_a=$(sort "$a")
            sorted_b=$(sort "$b")
        else
            # Filter both files: drop rows whose path field is in exception_paths.
            # Use awk with the exception paths supplied via stdin (NR==FNR trick).
            sorted_a=$(awk -F'|' -v paths="$exception_paths" '
                BEGIN {
                    n = split(paths, p, "\n")
                    for (i = 1; i <= n; i++) drop[p[i]] = 1
                }
                !($1 in drop) { print }
            ' "$a" | sort)
            sorted_b=$(awk -F'|' -v paths="$exception_paths" '
                BEGIN {
                    n = split(paths, p, "\n")
                    for (i = 1; i <= n; i++) drop[p[i]] = 1
                }
                !($1 in drop) { print }
            ' "$b" | sort)
            filter_count=$(echo "$exception_paths" | grep -cv '^$' || true)
            log_info "Applied L3 exceptions: $filter_count path(s) filtered from cross-packager diff (postinst-converged authority model)"
        fi
    else
        sorted_a=$(sort "$a")
        sorted_b=$(sort "$b")
    fi

    if [[ "$sorted_a" == "$sorted_b" ]]; then
        if [[ "$filter_count" -gt 0 ]]; then
            log_pass "Parity tables match (after $filter_count L3 exceptions): $a == $b"
        else
            log_pass "Parity tables match: $a == $b"
        fi
        return 0
    fi

    log_fail "Parity tables diverge: $a vs $b"
    {
        echo "--- $a (sorted, filtered) ---"
        printf '%s\n' "$sorted_a"
        echo "--- $b (sorted, filtered) ---"
        printf '%s\n' "$sorted_b"
        echo "--- lines only in $a ---"
        awk 'NR==FNR{seen[$0]++; next} !($0 in seen)' \
            <(printf '%s\n' "$sorted_b") <(printf '%s\n' "$sorted_a")
        echo "--- lines only in $b ---"
        awk 'NR==FNR{seen[$0]++; next} !($0 in seen)' \
            <(printf '%s\n' "$sorted_a") <(printf '%s\n' "$sorted_b")
        if [[ -n "$exceptions_file" ]]; then
            echo "--- L3 exceptions file: $exceptions_file ---"
            cat "$exceptions_file"
        fi
    } >&2
    return 1
}

# -----------------------------------------------------------------------------
# Mode: assert-expected — compare an extracted/observed table against expected
# -----------------------------------------------------------------------------
# Asserts every package_shipped=yes path is present and matches expected metadata.
# For package_shipped=no paths, only checks against expected when path is found.
#
# Optional 3rd argument: --deb-l3-exceptions=<file>
#   When set (used by DEB L3 assert step in the aggregator only), paths listed
#   in the exception file are expected to ship as root:root in the DEB archive
#   instead of root:nftban / nftban:nftban. This is the L3 reflection of the
#   postinst-converged authority model — DEB archive ships root:root, postinst
#   chown applies the final ownership (which L4/L5 still verify by name on the
#   installed filesystem, unchanged). Without this flag, expected ownership is
#   read from EXPECTED_TABLE verbatim (used for RPM L3 + L4/L5/L6 layers).
mode_assert_expected() {
    local observed="${1:?usage: assert-expected <observed-file> [package|all] [--deb-l3-exceptions=<file>]}"
    local mode_filter="${2:-}"  # 'package' or 'all'
    [[ -r "$observed" ]] || { log_err "Not readable: $observed"; exit 3; }

    local deb_l3_exceptions=""
    case "${3:-}" in
        "")                          ;;
        --deb-l3-exceptions=*)       deb_l3_exceptions="${3#--deb-l3-exceptions=}" ;;
        *) log_err "Unknown arg: $3 (expected --deb-l3-exceptions=<file>)"; exit 2 ;;
    esac

    # Build a map of postinst-converged exception paths (DEB L3 only).
    # An exception path means: in the DEB archive, this path is expected to
    # ship as root:root with its declared mode and type, NOT as root:nftban
    # etc. This catches a regression where someone re-introduces build-time
    # fakeroot chown — in that case the archive would show root:nftban for
    # an exception path and this assert would FAIL.
    local -A is_l3_exception=()
    if [[ -n "$deb_l3_exceptions" ]]; then
        if [[ ! -r "$deb_l3_exceptions" ]]; then
            log_err "DEB L3 exceptions file not readable: $deb_l3_exceptions"
            exit 3
        fi
        local p
        while IFS= read -r p; do
            [[ -n "$p" ]] && is_l3_exception["$p"]=1
        done < <(load_l3_exception_paths "$deb_l3_exceptions")
        log_info "DEB L3 exceptions loaded: ${#is_l3_exception[@]} postinst-converged path(s)"
    fi

    local fail=0 row exp_path exp_type exp_mode exp_owner exp_group exp_pkg
    for row in "${EXPECTED_TABLE[@]}"; do
        IFS='|' read -r exp_path exp_type exp_mode exp_owner exp_group exp_pkg <<< "$row"
        if [[ "$mode_filter" == "package" && "$exp_pkg" != "yes" ]]; then
            continue
        fi
        local actual
        actual=$(grep "^${exp_path}|" "$observed" || true)
        if [[ -z "$actual" ]]; then
            log_fail "expected path missing in observed: $exp_path"
            fail=1
            continue
        fi
        # If this path is a DEB L3 exception (postinst-converged), expect
        # root:root in the archive instead of the EXPECTED_TABLE owner/group.
        local effective_owner="$exp_owner" effective_group="$exp_group"
        if [[ -n "$deb_l3_exceptions" ]] && [[ -n "${is_l3_exception[$exp_path]:-}" ]]; then
            effective_owner="root"
            effective_group="root"
        fi
        local expected_row="${exp_path}|${exp_type}|${exp_mode}|${effective_owner}|${effective_group}"
        if [[ "$actual" != "$expected_row" ]]; then
            log_fail "metadata mismatch for $exp_path"
            log_fail "  expected: $expected_row"
            log_fail "  observed: $actual"
            fail=1
        else
            if [[ "$effective_owner" != "$exp_owner" || "$effective_group" != "$exp_group" ]]; then
                log_pass "$exp_path matches DEB L3 exception (archive=root:root; postinst converges to ${exp_owner}:${exp_group})"
            else
                log_pass "$exp_path matches expected"
            fi
        fi
    done

    if [[ "$fail" -eq 1 ]]; then
        return 1
    fi
    log_pass "assert-expected (filter=${mode_filter:-all}${deb_l3_exceptions:+, deb-l3-exceptions=$deb_l3_exceptions}) clean"
}

# -----------------------------------------------------------------------------
# Mode: list-critical-paths — emit the 11 critical paths (one per line)
# -----------------------------------------------------------------------------
mode_list_critical_paths() {
    critical_paths_list
}

# -----------------------------------------------------------------------------
# Mode: list-expected — emit the full expected table (path|type|mode|owner|group|pkg)
# -----------------------------------------------------------------------------
mode_list_expected() {
    printf '%s\n' "${EXPECTED_TABLE[@]}"
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") <mode> [args]

Modes:
  rpm-meta <rpm-file>              Extract dir metadata from built RPM artifact
  deb-meta <deb-file>              Extract dir metadata from built DEB artifact
  fresh-stat                       Stat critical paths on installed system
  reinstall-stat                   Alias of fresh-stat (semantic marker post-reinstall)
  upgrade-stat <pre|post>          Alias of fresh-stat with phase tag for upgrade canon
  verify-tool <rpm|deb>            Run rpm -V or dpkg --verify; filter by exceptions
  diff <file-a> <file-b> [--exceptions=<file>]
                                    Diff two parity tables; exit 1 on divergence.
                                    --exceptions=<file>: paths listed in <file>
                                    are filtered out before comparison (used by
                                    L3 cross-packager aggregator only; honors
                                    the postinst-converged DEB authority model)
  assert-expected <observed-file>  [package|all] [--deb-l3-exceptions=<file>]
                                    Assert observed matches expected; package-only
                                    filter restricts to L3-applicable paths.
                                    --deb-l3-exceptions=<file>: paths listed
                                    in <file> are expected to ship root:root
                                    in the DEB archive (postinst converges
                                    final ownership at install time)
  list-critical-paths              Emit the 11 critical paths (one per line)
  list-expected                    Emit the expected metadata table

Environment:
  EXCEPTIONS_FILE   Override path to verify-tool exceptions (default: alongside script)
EOF
}

main() {
    local mode="${1:-}"
    [[ -z "$mode" ]] && { usage; exit 2; }
    shift
    case "$mode" in
        rpm-meta)            mode_rpm_meta "$@" ;;
        deb-meta)            mode_deb_meta "$@" ;;
        fresh-stat)          mode_fresh_stat ;;
        reinstall-stat)      mode_fresh_stat ;;
        upgrade-stat)        mode_fresh_stat ;;
        verify-tool)         mode_verify_tool "$@" ;;
        diff)                mode_diff "$@" ;;
        assert-expected)     mode_assert_expected "$@" ;;
        list-critical-paths) mode_list_critical_paths ;;
        list-expected)       mode_list_expected ;;
        -h|--help|help)      usage ;;
        *)
            log_err "unknown mode: $mode"
            usage
            exit 2
            ;;
    esac
}

main "$@"
