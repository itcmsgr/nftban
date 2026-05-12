#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.107 — V108 Item 3: heredoc command-substitution safety CI gate
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="test-heredoc-safety"
# meta:type="ci-script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-10"
# meta:description="V108 Item 3 CI gate: detect unsafe shell expansion (unescaped backticks, command substitution, arithmetic) in unquoted heredoc bodies in generator/build scripts"
# meta:inventory.files="scripts/ci/test-heredoc-safety.sh, scripts/ci/data/heredoc-safety-allowlist.txt"
# meta:inventory.binaries="bash, awk, grep, sed"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
#
# Implements V108 Item 3 per scope artifact:
#   /home/commonfolder/LLMAI4NFTBAN/V1.90_AUDIT_WIKI_CODE/AUDIT_190_LIFECYCLE/
#   V108_ITEM3_HEREDOC_SAFETY_SCAN_SCOPE.md
#
# Motivating defect (v1.107.1 / PR #585 fixup commit da14e182):
# Unescaped markdown backticks inside an unquoted heredoc at
# packaging/build_nftban.sh:266 were interpreted by bash as command
# substitution while emitting the RPM spec, producing corrupted
# scriptlet content. el10's rpmbuild was strict and failed; el9 was
# tolerant and reported success despite the same mangling.
#
# This gate scans all heredoc openers in target files, classifies
# each, and FAILs on:
#   - UNESCAPED_BACKTICK_IN_UNQUOTED_HEREDOC
#   - UNESCAPED_CMD_SUBST_IN_UNQUOTED_HEREDOC (outside function context)
#   - UNESCAPED_ARITH_IN_UNQUOTED_HEREDOC
#   - UNCLOSED_HEREDOC
#
# Function-context handling (per scope §6.3 Option α):
# A heredoc inside a function body (e.g. usage()) may use $VAR,
# ${VAR}, and $(...) at function-call time intentionally. The gate
# automatically detects function context via a simple brace counter
# and relaxes the $(...) check for in-function heredocs. Backticks
# and $((...)) still FAIL even inside functions.
#
# Modes:
#   scan [--paths=<path>] [--allowlist=<path>] [--verbose] [--strict-should-be-quoted]
#
# Exit codes:
#   0  PASS — no FAIL findings
#   1  FAIL — at least one FAIL
#   2  Invalid usage / missing dep
# =============================================================================

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------
SCRIPT_NAME="test-heredoc-safety"
SCRIPT_VERSION="1.0.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DEFAULT_ALLOWLIST="$REPO_ROOT/scripts/ci/data/heredoc-safety-allowlist.txt"

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
$SCRIPT_NAME v$SCRIPT_VERSION — V108 Item 3 CI gate

Usage:
  $0 scan [--paths=<glob>] [--allowlist=<path>] [--verbose] [--strict-should-be-quoted]

Default target globs (in order):
  packaging/build_nftban.sh
  build/generate-*.sh
  scripts/*.sh
  scripts/ci/*.sh

Options:
  --paths=<glob>            Override default scan globs (space-separated)
  --allowlist=<path>        Override default scripts/ci/data/heredoc-safety-allowlist.txt
  --verbose                 Emit per-heredoc classification (default: only failures + warns)
  --strict-should-be-quoted Treat SHOULD_BE_QUOTED warns as FAIL

Failure-mode taxonomy:
  UNESCAPED_BACKTICK_IN_UNQUOTED_HEREDOC      FAIL
  UNESCAPED_CMD_SUBST_IN_UNQUOTED_HEREDOC     FAIL (outside function context)
  UNESCAPED_ARITH_IN_UNQUOTED_HEREDOC         FAIL
  UNCLOSED_HEREDOC                            FAIL
  SHOULD_BE_QUOTED_NO_EXPANSION_NEEDED        WARN (or FAIL with --strict)
  PASS_QUOTED                                  PASS
  PASS_REQUIRED_EXPANSION                      PASS
  PASS_FUNCTION_CONTEXT                        PASS (in-function emit-time)
  PASS_ALLOWLISTED                             PASS (per allowlist entry)

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
    for cmd in awk grep sed; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing[*]}"
        exit 2
    fi
}

# -----------------------------------------------------------------------------
# Allowlist loader
# -----------------------------------------------------------------------------
# Format: file:line:reason  (one per line; # comments allowed)
ALLOWLIST=()
load_allowlist() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(echo "$line" | awk '{$1=$1; print}')"
        [[ -z "$line" ]] && continue
        ALLOWLIST+=("$line")
    done < "$f"
}

is_allowlisted() {
    local key="$1"   # file:line
    local entry
    for entry in "${ALLOWLIST[@]}"; do
        local entry_file="${entry%%:*}"
        local rest="${entry#*:}"
        local entry_line="${rest%%:*}"
        if [[ "$key" == "$entry_file:$entry_line" ]]; then
            return 0
        fi
    done
    return 1
}

# -----------------------------------------------------------------------------
# Awk program: per-file scanner
# Defined via quoted heredoc so awk can use any quote chars freely.
# Output: file:line|delim|kind|classification|details
# -----------------------------------------------------------------------------
read -r -d '' AWK_PROGRAM <<'AWK_END' || true
BEGIN {
    in_heredoc = 0
    in_function = 0
    function_brace_depth = 0
    body_count = 0
}

function emit(out_file, out_line, out_delim, out_kind, out_cls, out_details) {
    print out_file ":" out_line "|" out_delim "|" out_kind "|" out_cls "|" out_details
}

function reset_heredoc() {
    in_heredoc = 0
    h_delim = ""
    h_quoted = 0
    h_dash = 0
    h_open_line = 0
    h_in_function = 0
    body_count = 0
    delete body
}

function neutralize_escapes(s,    tmp) {
    tmp = s
    # Replace \` with placeholder
    gsub(/\\`/, "<ESC_BT>", tmp)
    # Replace \$ with placeholder (covers \$(, \${, \$VAR — all escaped tokens)
    gsub(/\\\$/, "<ESC_DOLLAR>", tmp)
    return tmp
}

function has_unescaped_backtick(s,    n) {
    n = neutralize_escapes(s)
    return (index(n, "`") > 0)
}

function has_unescaped_arith(s,    n) {
    n = neutralize_escapes(s)
    return (n ~ /\$\(\(/)
}

function has_unescaped_cmd_subst(s,    n) {
    n = neutralize_escapes(s)
    if (n ~ /\$\(\(/) return 0   # arith, not cmd subst
    return (n ~ /\$\(/)
}

function has_var_ref(s,    n) {
    n = neutralize_escapes(s)
    if (n ~ /\$\{[A-Za-z_]/) return 1
    if (n ~ /\$[A-Za-z_][A-Za-z0-9_]*/) return 1
    return 0
}

function classify_unquoted(    i, has_bt, has_arith, has_cs, has_var, line_bt, line_arith, line_cs) {
    has_bt = 0; has_arith = 0; has_cs = 0; has_var = 0
    line_bt = 0; line_arith = 0; line_cs = 0
    for (i = 1; i <= body_count; i++) {
        if (!has_bt    && has_unescaped_backtick(body[i]))   { has_bt    = 1; line_bt    = i }
        if (!has_arith && has_unescaped_arith(body[i]))      { has_arith = 1; line_arith = i }
        if (!has_cs    && has_unescaped_cmd_subst(body[i]))  { has_cs    = 1; line_cs    = i }
        if (!has_var   && has_var_ref(body[i]))              { has_var   = 1 }
    }
    if (has_bt) {
        emit(FILE, h_open_line, h_delim, "unquoted", "UNESCAPED_BACKTICK_IN_UNQUOTED_HEREDOC", "body-line-offset=" line_bt " (use <<\047DELIM\047 quoted form, or escape with \\\\`)")
        return
    }
    if (has_arith) {
        emit(FILE, h_open_line, h_delim, "unquoted", "UNESCAPED_ARITH_IN_UNQUOTED_HEREDOC", "body-line-offset=" line_arith " (use \\$((...)) or quote heredoc)")
        return
    }
    if (has_cs) {
        if (h_in_function) {
            emit(FILE, h_open_line, h_delim, "unquoted", "PASS_FUNCTION_CONTEXT", "in-function-cmd-subst-allowed (Option-alpha)")
            return
        }
        emit(FILE, h_open_line, h_delim, "unquoted", "UNESCAPED_CMD_SUBST_IN_UNQUOTED_HEREDOC", "body-line-offset=" line_cs " (escape as \\$(...) for runtime emission, or quote heredoc)")
        return
    }
    if (has_var) {
        emit(FILE, h_open_line, h_delim, "unquoted", "PASS_REQUIRED_EXPANSION", "var-refs-only")
        return
    }
    emit(FILE, h_open_line, h_delim, "unquoted", "SHOULD_BE_QUOTED_NO_EXPANSION_NEEDED", "body has no expansion needs")
}

# ============================================================================
# Per-line state machine
# ============================================================================
{
    line = $0

    # =========================================================
    # Phase 1: inside-heredoc handling
    # =========================================================
    if (in_heredoc) {
        # Closer: line that, after optional leading whitespace stripping for
        # <<- form, equals h_delim exactly (with optional trailing whitespace)
        if (h_dash) {
            stripped = line
            sub(/^[[:space:]]+/, "", stripped)
        } else {
            stripped = line
        }
        if (stripped == h_delim || stripped == h_delim "" ) {
            # also accept trailing whitespace
            close_match = 1
        } else {
            # also accept "DELIM<trailing-space>"
            if (h_dash) {
                close_match = (line ~ ("^[[:space:]]*" h_delim "[[:space:]]*$"))
            } else {
                close_match = (line ~ ("^" h_delim "[[:space:]]*$"))
            }
        }
        if (close_match) {
            if (h_quoted) {
                emit(FILE, h_open_line, h_delim, "quoted", "PASS_QUOTED", "safe-by-construction")
            } else {
                classify_unquoted()
            }
            reset_heredoc()
            close_match = 0
            next
        }
        body_count++
        body[body_count] = line
        next
    }

    # =========================================================
    # Phase 2: function-context tracking
    # =========================================================
    # Function opener detected by:  ^[[:space:]]*name() {  OR  ^function name() {
    if (line ~ /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{[[:space:]]*$/ ||
        line ~ /^[[:space:]]*function[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*\(\)[[:space:]]*\{[[:space:]]*$/) {
        in_function = 1
        function_brace_depth = 1
        next
    }
    # Update brace depth if inside function
    if (in_function) {
        # Count { and } in line (rough — does not handle braces inside strings)
        n_open  = gsub(/\{/, "{", line)
        n_close = gsub(/\}/, "}", line)
        function_brace_depth += n_open - n_close
        if (function_brace_depth <= 0) {
            in_function = 0
            function_brace_depth = 0
        }
        # Restore line (gsub mutated it)
        line = $0
    }

    # =========================================================
    # Phase 3: heredoc opener detection
    # =========================================================
    # Match: <<-? then optional space, then ('DELIM' or "DELIM" or DELIM)
    # Use a permissive regex; extract details from matched text
    if (match(line, /<<-?[[:space:]]*('[A-Z_][A-Z_0-9]*'|"[A-Z_][A-Z_0-9]*"|[A-Z_][A-Z_0-9]*)/)) {
        opener_text = substr(line, RSTART, RLENGTH)
        # Dash form?
        h_dash = (opener_text ~ /<<-/) ? 1 : 0
        # Quoted form?
        h_quoted = (opener_text ~ /'/ || opener_text ~ /"/) ? 1 : 0
        # Extract delim — strip <<, optional dash, optional whitespace, optional quotes
        tmp = opener_text
        sub(/<<-?[[:space:]]*/, "", tmp)
        gsub(/['"]/, "", tmp)
        h_delim = tmp
        h_open_line = NR
        h_in_function = in_function
        in_heredoc = 1
        body_count = 0
        delete body
        next
    }
}

END {
    if (in_heredoc) {
        emit(FILE, h_open_line, h_delim, "unquoted", "UNCLOSED_HEREDOC", "opener at line " h_open_line " has no matching closer")
    }
}
AWK_END

# -----------------------------------------------------------------------------
# Per-file scanner
# -----------------------------------------------------------------------------
scan_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        log_warn "Path not found, skipping: $file"
        return 0
    fi
    awk -v FILE="$file" "$AWK_PROGRAM" "$file"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 2
    fi

    local mode="$1"
    shift

    case "$mode" in
        scan) ;;
        -h|--help|help) usage; exit 0 ;;
        *) log_error "Unknown mode: $mode"; usage; exit 2 ;;
    esac

    local paths_arg=""
    local allowlist_arg="$DEFAULT_ALLOWLIST"
    local verbose="no"
    local strict_quoted="no"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --paths=*)                  paths_arg="${1#*=}"     ;;
            --allowlist=*)              allowlist_arg="${1#*=}" ;;
            --verbose)                  verbose="yes"           ;;
            --strict-should-be-quoted)  strict_quoted="yes"     ;;
            *) log_error "Unknown argument: $1"; usage; exit 2  ;;
        esac
        shift
    done

    check_deps
    load_allowlist "$allowlist_arg"

    # Build file list
    local -a files
    if [[ -n "$paths_arg" ]]; then
        eval "files=($paths_arg)"
    else
        files=()
        local g
        [[ -f "$REPO_ROOT/packaging/build_nftban.sh" ]] && files+=("$REPO_ROOT/packaging/build_nftban.sh")
        for g in "$REPO_ROOT"/build/generate-*.sh; do
            [[ -f "$g" ]] && files+=("$g")
        done
        for g in "$REPO_ROOT"/scripts/*.sh; do
            [[ -f "$g" ]] && files+=("$g")
        done
        for g in "$REPO_ROOT"/scripts/ci/*.sh; do
            [[ -f "$g" ]] && files+=("$g")
        done
    fi

    log_info "$SCRIPT_NAME v$SCRIPT_VERSION"
    log_info "Scanning ${#files[@]} files"
    log_info "Allowlist: $allowlist_arg (${#ALLOWLIST[@]} entries)"
    log_info ""

    local all_records processed
    all_records=$(mktemp)
    processed=$(mktemp)
    trap 'rm -f "$all_records" "$processed"' EXIT

    local f
    for f in "${files[@]}"; do
        scan_file "$f" >> "$all_records" || true
    done

    local total_fail=0 total_warn=0 total_pass=0
    while IFS= read -r record; do
        [[ -z "$record" ]] && continue
        local file_line cls
        file_line="${record%%|*}"
        cls=$(echo "$record" | awk -F'|' '{print $4}')

        # Allowlist override
        if is_allowlisted "$file_line"; then
            if [[ "$cls" == UNESCAPED* || "$cls" == UNCLOSED* ]]; then
                record="${record%|*}|PASS_ALLOWLISTED|allowlist override (was: $cls)"
                cls="PASS_ALLOWLISTED"
            fi
        fi

        # Strict-quoted upgrade
        if [[ "$strict_quoted" == "yes" && "$cls" == "SHOULD_BE_QUOTED_NO_EXPANSION_NEEDED" ]]; then
            record="${record%|*}|FAIL_SHOULD_BE_QUOTED|strict mode upgraded WARN to FAIL"
            cls="FAIL_SHOULD_BE_QUOTED"
        fi

        echo "$record" >> "$processed"

        case "$cls" in
            UNESCAPED*|UNCLOSED*|FAIL_*) total_fail=$((total_fail + 1)); log_fail "$record" ;;
            SHOULD_BE_QUOTED_NO_EXPANSION_NEEDED) total_warn=$((total_warn + 1)); log_warn "$record" ;;
            PASS_*) total_pass=$((total_pass + 1))
                    [[ "$verbose" == "yes" ]] && log_info "$record"
                    ;;
        esac
    done < "$all_records"

    log_info ""
    log_info "─────────────────────────────────────────────────────────"
    log_info "Summary"
    log_info "─────────────────────────────────────────────────────────"
    log_info "  Files scanned:   ${#files[@]}"
    log_info "  Heredocs:        $((total_pass + total_warn + total_fail))"
    log_info "  PASSes:          $total_pass"
    log_info "  WARNs:           $total_warn"
    log_info "  FAILs:           $total_fail"
    log_info "─────────────────────────────────────────────────────────"

    if [[ $total_fail -eq 0 ]]; then
        log_pass "All heredocs safe. V108 Item 3 gate PASSED."
        exit 0
    else
        log_fail "$total_fail unsafe heredoc(s) detected. V108 Item 3 gate FAILED."
        exit 1
    fi
}

main "$@"
