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
mode_rpm_meta() {
    local rpm_file="${1:?usage: rpm-meta <rpm-file>}"
    [[ -r "$rpm_file" ]] || { log_err "RPM not readable: $rpm_file"; exit 3; }
    command -v rpm >/dev/null || { log_err "rpm not installed"; exit 2; }

    # `rpm -qplv` output: drwxr-x---    2 root    nftban              0 Jan  1 00:00 /etc/nftban
    rpm -qplv "$rpm_file" | while read -r mode_str _links owner group _size _date _time _tz path; do
        # Some `rpm -qplv` formats omit timezone column; handle both
        if [[ -z "$path" ]]; then
            path="$_tz"
        fi
        is_critical_path "$path" || continue
        local octal type
        octal=$(ls_mode_to_octal "$mode_str")
        type=$(ls_type_from_mode "$mode_str")
        echo "$path|$type|$octal|$owner|$group"
    done | sort -u
}

# -----------------------------------------------------------------------------
# Mode: deb-meta — extract dir metadata from DEB artifact via `dpkg-deb --contents`
# -----------------------------------------------------------------------------
mode_deb_meta() {
    local deb_file="${1:?usage: deb-meta <deb-file>}"
    [[ -r "$deb_file" ]] || { log_err "DEB not readable: $deb_file"; exit 3; }
    command -v dpkg-deb >/dev/null || { log_err "dpkg-deb not installed"; exit 2; }

    # `dpkg-deb --contents` output: drwxr-xr-x root/root         0 2024-12-22 18:08 ./etc/nftban/
    dpkg-deb --contents "$deb_file" | while read -r mode_str owner_group _size _date _time path _link; do
        # Strip leading './' and trailing '/'
        path="${path#./}"
        path="${path%/}"
        path="/$path"
        is_critical_path "$path" || continue
        local octal type owner group
        octal=$(ls_mode_to_octal "$mode_str")
        type=$(ls_type_from_mode "$mode_str")
        owner="${owner_group%%/*}"
        group="${owner_group#*/}"
        echo "$path|$type|$octal|$owner|$group"
    done | sort -u
}

# -----------------------------------------------------------------------------
# Mode: fresh-stat / reinstall-stat / upgrade-stat — stat live filesystem
# -----------------------------------------------------------------------------
mode_fresh_stat() {
    local row path type expected_type
    for row in "${EXPECTED_TABLE[@]}"; do
        path="${row%%|*}"
        expected_type=$(echo "$row" | cut -d'|' -f2)
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
# Mode: diff — compare two parity tables; require exact match for shared paths
# -----------------------------------------------------------------------------
# Portable shell-only comparison — does NOT depend on the external `diff`
# binary, which is not preinstalled in minimal EL9 containers
# (rockylinux:9, almalinux:9, centos:stream9). Uses sort + bash string
# equality, with awk-based set-difference reporting on divergence.
mode_diff() {
    local a="${1:?usage: diff <file-a> <file-b>}"
    local b="${2:?usage: diff <file-a> <file-b>}"
    [[ -r "$a" ]] || { log_err "Not readable: $a"; exit 3; }
    [[ -r "$b" ]] || { log_err "Not readable: $b"; exit 3; }

    local sorted_a sorted_b
    sorted_a=$(sort "$a")
    sorted_b=$(sort "$b")

    if [[ "$sorted_a" == "$sorted_b" ]]; then
        log_pass "Parity tables match: $a == $b"
        return 0
    fi

    log_fail "Parity tables diverge: $a vs $b"
    {
        echo "--- $a (sorted) ---"
        printf '%s\n' "$sorted_a"
        echo "--- $b (sorted) ---"
        printf '%s\n' "$sorted_b"
        echo "--- lines only in $a ---"
        awk 'NR==FNR{seen[$0]++; next} !($0 in seen)' \
            <(printf '%s\n' "$sorted_b") <(printf '%s\n' "$sorted_a")
        echo "--- lines only in $b ---"
        awk 'NR==FNR{seen[$0]++; next} !($0 in seen)' \
            <(printf '%s\n' "$sorted_a") <(printf '%s\n' "$sorted_b")
    } >&2
    return 1
}

# -----------------------------------------------------------------------------
# Mode: assert-expected — compare an extracted/observed table against expected
# -----------------------------------------------------------------------------
# Asserts every package_shipped=yes path is present and matches expected metadata.
# For package_shipped=no paths, only checks against expected when path is found.
mode_assert_expected() {
    local observed="${1:?usage: assert-expected <observed-file>}"
    local mode_filter="${2:-}"  # 'package' or 'all'
    [[ -r "$observed" ]] || { log_err "Not readable: $observed"; exit 3; }

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
        local expected_row="${exp_path}|${exp_type}|${exp_mode}|${exp_owner}|${exp_group}"
        if [[ "$actual" != "$expected_row" ]]; then
            log_fail "metadata mismatch for $exp_path"
            log_fail "  expected: $expected_row"
            log_fail "  observed: $actual"
            fail=1
        else
            log_pass "$exp_path matches expected"
        fi
    done

    if [[ "$fail" -eq 1 ]]; then
        return 1
    fi
    log_pass "assert-expected (filter=${mode_filter:-all}) clean"
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
  diff <file-a> <file-b>           Diff two parity tables; exit 1 on divergence
  assert-expected <observed-file>  [package|all]
                                    Assert observed matches expected; package-only
                                    filter restricts to L3-applicable paths
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
