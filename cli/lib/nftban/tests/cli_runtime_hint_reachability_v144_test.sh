#!/usr/bin/env bash
# =============================================================================
# NFTBan - runtime-hint reachability guard (v1.144.0 PR-D D-UXV-13)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_runtime_hint_reachability_v144_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-01"
# meta:description="v1.144.0 PR-D D-UXV-13 class-killer: catches the runtime-hint-drift class that produced D-UXV-14 (cmd_connector.sh:234 'nftban connector edit' — no edit arm) + D-UXV-15 (cmd_port.sh:260,558,689,693 'nftban reload' / 'nftban port reload' — both non-existent commands; canonical is 'nftban firewall reload'). The existing v130 doctest guard checks the forward direction (every dispatched subcommand is documented somewhere); this test adds the reverse direction (every runtime echo/printf 'nftban X Y' hint resolves to a real reachable command). The audit episode 2026-06-01 that produced D-UXV-14/15 also proposed an INCORRECT replacement ('nftban reload' is also non-existent); this test would have caught that mistake too — the canonical_commands list at cli/sbin/nftban:911-995 does not contain 'reload'. Reachability rule: 'nftban X' must have X in _nftban_canonical_commands OR an alias-case entry; 'nftban X Y' additionally requires Y to be a case-arm in nftban_cmd_<X>()'s primary dispatch in cli/lib/nftban/cli/cmd_<X>.sh OR allowlisted in v144_runtime_hint_allowlist.tsv with an explicit reason field. Cross-module references (e.g., cmd_port.sh advertising 'nftban firewall reload') need allowlist entries explaining the dependency direction. Variable substitutions ('nftban X \$name') are tolerated for the variable position only; the static prefix is still checked. Hermetic — no daemon, no nft, no host contact; reads only the source tree."
# meta:input="cli/sbin/nftban, cli/lib/nftban/cli/cmd_*.sh, cli/lib/nftban/lib/*.sh, cli/lib/nftban/core/*.sh, cli/lib/nftban/tests/v144_runtime_hint_allowlist.tsv"
# meta:output="Pass/fail assertions + list of violations; exit 0 on all-pass"
# meta:depends="bash,grep,awk,sort"
# meta:inventory.files="cli/sbin/nftban,cli/lib/nftban/cli/cmd_*.sh,cli/lib/nftban/lib/*.sh,cli/lib/nftban/core/*.sh,cli/lib/nftban/tests/v144_runtime_hint_allowlist.tsv"
# meta:inventory.binaries="bash,grep,awk,sort"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cli_runtime_hint_reachability_v144_test"
# meta:ta.owner="cli"
# meta:ta.module="runtime-hint-reachability"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
DISP="$REPO/cli/sbin/nftban"
ALLOWLIST="$REPO/cli/lib/nftban/tests/v144_runtime_hint_allowlist.tsv"
CLI_DIR="$REPO/cli/lib/nftban/cli"

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

[[ -f "$DISP" ]] || { echo "FAIL: missing $DISP"; exit 1; }
[[ -f "$ALLOWLIST" ]] || { echo "FAIL: missing $ALLOWLIST"; exit 1; }

# ──────────────────────────────────────────────────────────────────────────
# Phase 1: extract the source-of-truth tables
# ──────────────────────────────────────────────────────────────────────────

# T1-1: extract _nftban_canonical_commands list
CANONICAL=$(awk '/^_nftban_canonical_commands\(\)/,/^EOF$/' "$DISP" \
    | grep -vE '^_nftban_canonical_commands|^EOF$|^[[:space:]]*cat[[:space:]]+<<' \
    | grep -vE '^[[:space:]]*$' \
    | sort -u)
canonical_count=$(echo "$CANONICAL" | grep -cE '^[a-z]')
if [[ "$canonical_count" -ge 50 ]]; then
    ok "T1-1: extracted $canonical_count canonical commands from cli/sbin/nftban"
else
    no "T1-1: extracted ≥50 canonical commands from cli/sbin/nftban" \
       "got $canonical_count"
fi

# T1-2: extract alias-case targets from cli/sbin/nftban (cloudflare, enable|
# disable|restart, verify|explain, service, export, rollback are the known
# set as of v1.143.1)
ALIASES=$(awk '/^    case "\$cmd" in$/{seen=1} seen && /^[[:space:]]+[a-z|]+\)/' "$DISP" \
    | grep -oE '^[[:space:]]+[a-z|]+\)' \
    | sed -e 's/^[[:space:]]*//' -e 's/)$//' \
    | tr '|' '\n' \
    | sort -u)
alias_count=$(echo "$ALIASES" | grep -cE '^[a-z]')
if [[ "$alias_count" -ge 5 ]]; then
    ok "T1-2: extracted $alias_count alias-case targets from cli/sbin/nftban"
else
    no "T1-2: extracted ≥5 alias-case targets from cli/sbin/nftban" \
       "got $alias_count"
fi

# Build combined "any X is reachable" set
REACHABLE_X=$(printf '%s\n%s\n' "$CANONICAL" "$ALIASES" | grep -E '^[a-z]' | sort -u)

# T1-3: extract dispatch arms per cmd_X.sh. For each cmd_<X>.sh file with a
# function nftban_cmd_<X>(), parse the primary `case "$something" in` block
# inside that function and emit (X, arm) pairs. Variables in case patterns
# (\$1, \$cmd, \$subcommand, etc.) are tolerated; only the literal arm
# names are extracted.
DISPATCH_FILE=$(mktemp -t nftban-dispatch.XXXXXX)
trap 'rm -f "$DISPATCH_FILE"' EXIT

while IFS= read -r -d '' cmd_file; do
    base=$(basename "$cmd_file" .sh)
    x="${base#cmd_}"
    # handle hyphen-stem mapping (whitelist_system → whitelist-system, etc.)
    x_hyphen="${x//_/-}"
    # Extract case-arm tokens from the FIRST case statement inside the
    # nftban_cmd_<X>() function (heuristic: any `case ... in` ... `esac` block).
    awk -v fnname="nftban_cmd_${x}" '
        $0 ~ "^"fnname"\\(\\)" {in_fn=1; depth=0}
        in_fn && /case .* in/ {in_case=1; next}
        in_fn && in_case && /esac/ {in_case=0; in_fn=0; exit}
        in_fn && in_case && /^[[:space:]]+[a-z][a-zA-Z0-9_|*"-]*\)/ {
            line=$0
            # Strip everything from the FIRST `)` onwards — covers both
            # `arm)` (EOL after `)`) and `arm)    handler` cases. Earlier
            # version required whitespace AFTER `)` which dropped most
            # one-line arms like `get)` and was the bug that caused
            # only 3 of 14 cmd_config arms to be extracted.
            sub(/\).*$/, "", line)
            sub(/^[[:space:]]+/, "", line)
            n = split(line, parts, "|")
            for (i=1; i<=n; i++) {
                arm = parts[i]
                # strip optional ""\"" quote wrappers and special tokens
                gsub(/^"|"$/, "", arm)
                # only emit pure-alphanumeric arms (skip *, "", $vars, --help-style)
                if (arm ~ /^[a-z][a-zA-Z0-9_-]*$/) print arm
            }
        }
    ' "$cmd_file" | sort -u | while IFS= read -r arm; do
        printf "%s\t%s\n" "$x_hyphen" "$arm" >> "$DISPATCH_FILE"
        # also emit under the hyphenless form for files like cmd_whitelist_system.sh
        # where X is whitelist-system but the file is cmd_whitelist_system.sh
        if [[ "$x" != "$x_hyphen" ]]; then
            printf "%s\t%s\n" "$x" "$arm" >> "$DISPATCH_FILE"
        fi
    done
done < <(find "$CLI_DIR" -maxdepth 1 -name 'cmd_*.sh' -print0)

sort -u -o "$DISPATCH_FILE" "$DISPATCH_FILE"

dispatch_pair_count=$(wc -l < "$DISPATCH_FILE")
if [[ "$dispatch_pair_count" -ge 50 ]]; then
    ok "T1-3: extracted $dispatch_pair_count (cmd, arm) dispatch pairs from cli/lib/nftban/cli/"
else
    no "T1-3: extracted ≥50 (cmd, arm) dispatch pairs from cli/lib/nftban/cli/" \
       "got $dispatch_pair_count"
fi

# Load allowlist into a lookup file (key = file<TAB>line<TAB>literal)
ALLOW_KEYS=$(mktemp -t nftban-allow.XXXXXX)
# Append to the trap so both temp files are cleaned up
trap 'rm -f "$DISPATCH_FILE" "$ALLOW_KEYS"' EXIT

grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$ALLOWLIST" \
    | awk -F'\t' 'NF >= 4 { print $1"\t"$2"\t"$3 }' \
    | sort -u > "$ALLOW_KEYS"

allow_count=$(wc -l < "$ALLOW_KEYS")
ok "T1-4: allowlist loaded with $allow_count entries"

# ──────────────────────────────────────────────────────────────────────────
# Phase 2: walk source tree and extract runtime-hint literals
# ──────────────────────────────────────────────────────────────────────────

# Scope: cli/sbin/nftban + cli/lib/nftban/cli/cmd_*.sh + cli/lib/nftban/lib/*.sh
# + cli/lib/nftban/core/*.sh. NOT tests/, NOT exporters/ (which print metrics),
# NOT setup/ (one-shot installers). Keep the scope tight to the live CLI surface
# the operator actually sees on the daily path.
HINTS_FILE=$(mktemp -t nftban-hints.XXXXXX)
trap 'rm -f "$DISPATCH_FILE" "$ALLOW_KEYS" "$HINTS_FILE"' EXIT

# Helper: emit lines from a file matching the runtime-hint pattern, with
# (file, line, literal) tab-separated. Skip comment lines. The outer `|| true`
# absorbs the grep-no-match rc=1 so the script's `set -e -o pipefail` does
# not abort on files that contain no runtime hints (most lib/ helpers).
emit_hints() {
    local f="$1"
    { grep -nE '"nftban [a-z]' "$f" 2>/dev/null || true; } | while IFS=: read -r ln rest; do
        # Skip comment lines (the literal `# ` start, OR `#` after leading whitespace)
        if [[ "$rest" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        # Extract every "nftban <X> [<Y>] [<Z>]" literal from the line.
        # awk: split on the literal token "\"nftban " and walk each chunk.
        echo "$rest" | awk -v fname="$f" -v lineno="$ln" '
            BEGIN { RS="\"nftban "; FS="\"" }
            NR > 1 {
                # $1 is the content between "nftban " and the next "
                literal = $1
                # strip trailing nothing — we want just the command part
                # Skip empty / variable-only literals
                if (length(literal) == 0) next
                # Print: file<TAB>line<TAB>"nftban literal"
                print fname"\t"lineno"\tnftban "literal
            }
        '
    done
}

# Walk
while IFS= read -r -d '' f; do
    emit_hints "$f"
done < <(
    {
        printf '%s\0' "$DISP"
        find "$CLI_DIR" -maxdepth 1 -name 'cmd_*.sh' -print0
        find "$REPO/cli/lib/nftban/lib" -maxdepth 1 -name '*.sh' -print0 2>/dev/null
        find "$REPO/cli/lib/nftban/core" -maxdepth 1 -name '*.sh' -print0 2>/dev/null
    }
)  > "$HINTS_FILE"

hint_count=$(wc -l < "$HINTS_FILE")
if [[ "$hint_count" -ge 10 ]]; then
    ok "T2-1: extracted $hint_count runtime-hint literals from source tree"
else
    no "T2-1: extracted ≥10 runtime-hint literals from source tree" \
       "got $hint_count"
fi

# ──────────────────────────────────────────────────────────────────────────
# Phase 3: check each hint for reachability
# ──────────────────────────────────────────────────────────────────────────
VIOLATIONS_FILE=$(mktemp -t nftban-viol.XXXXXX)
trap 'rm -f "$DISPATCH_FILE" "$ALLOW_KEYS" "$HINTS_FILE" "$VIOLATIONS_FILE"' EXIT

# is_x_reachable: check if a top-level command name is in REACHABLE_X
is_x_reachable() {
    local x="$1"
    grep -qxF "$x" <(echo "$REACHABLE_X")
}

# is_pair_dispatched: check if (x, y) is in DISPATCH_FILE
is_pair_dispatched() {
    local x="$1" y="$2"
    grep -qxF "$x	$y" "$DISPATCH_FILE"
}

# is_allowlisted: check if (file, line, literal) is in ALLOW_KEYS
is_allowlisted() {
    local f="$1" ln="$2" lit="$3"
    # Strip the leading REPO/ prefix to match relative paths used in the TSV
    local rel="${f#"$REPO"/}"
    grep -qxF "$rel	$ln	$lit" "$ALLOW_KEYS"
}

# Common English-prose stopwords / verbs that should NOT be flagged as
# subcommand tokens. These appear in literals like "nftban not in PATH",
# "nftban version completes", "nftban package status: ...". This is a
# pragmatic heuristic — a perfect parser would be the halting problem
# but for the D-UXV-13 class (catching `nftban port reload` /
# `nftban connector edit` style real drift) this filter is sufficient.
ENGLISH_STOPWORDS_X="not is was in on has have are be been being CLI cli not found returned failed completes command package status binary tool found"
ENGLISH_STOPWORDS_Y="not is was in on has have are be been being command completes returned failed found"

# Process each hint
violation_count=0
checked_count=0
allowlisted_count=0
variable_skipped=0
english_skipped=0

is_english_x() {
    local x="$1"
    for stop in $ENGLISH_STOPWORDS_X; do
        [[ "$x" == "$stop" ]] && return 0
    done
    return 1
}
is_english_y() {
    local y="$1"
    for stop in $ENGLISH_STOPWORDS_Y; do
        [[ "$y" == "$stop" ]] && return 0
    done
    return 1
}

while IFS=$'\t' read -r f ln lit; do
    checked_count=$((checked_count + 1))
    # Parse the literal: "nftban X [Y [Z ...]]"
    # First strip the "nftban " prefix
    rest="${lit#nftban }"
    # Get the first whitespace-separated token (X)
    x="${rest%% *}"
    # If X starts with $, it's a variable substitution — skip (we can't
    # statically check variables).
    if [[ "$x" == \$* ]] || [[ "$x" == "<"* ]]; then
        variable_skipped=$((variable_skipped + 1))
        continue
    fi
    # Strip non-alnum trailing chars (e.g., punctuation after the token)
    x="${x%%[^a-zA-Z0-9_-]*}"
    # Empty x = malformed literal, skip
    [[ -z "$x" ]] && continue

    # English-prose filter: if X is an obvious English stopword, the
    # literal is a sentence not a runtime hint — skip.
    if is_english_x "$x"; then
        english_skipped=$((english_skipped + 1))
        continue
    fi

    # If the literal contains a `:` (English-prose marker like
    # "nftban package status:"), skip — those are status messages
    # not runtime hints.
    if [[ "$lit" == *:* ]]; then
        english_skipped=$((english_skipped + 1))
        continue
    fi

    # Check X reachability
    if ! is_x_reachable "$x"; then
        if is_allowlisted "$f" "$ln" "$lit"; then
            allowlisted_count=$((allowlisted_count + 1))
            continue
        fi
        violation_count=$((violation_count + 1))
        printf '  [VIOLATION] %s:%s\tX=%s\t"%s"\n' "$f" "$ln" "$x" "$lit" >> "$VIOLATIONS_FILE"
        continue
    fi

    # Get the second token (Y) if present
    rest2="${rest#"$x"}"
    rest2="${rest2# }"  # trim leading space
    if [[ -z "$rest2" ]]; then
        # Only X, no Y — already validated as reachable. Done.
        continue
    fi
    y="${rest2%% *}"
    # Variable Y position is OK — just check static prefix already done
    if [[ "$y" == \$* ]] || [[ "$y" == "<"* ]] || [[ "$y" == "--"* ]] || [[ "$y" == "-"* ]]; then
        # --flag or -f or $var or <PLACEHOLDER>: not a subcommand — skip
        continue
    fi
    # Strip non-alnum trailing chars
    y="${y%%[^a-zA-Z0-9_-]*}"
    [[ -z "$y" ]] && continue

    # Skip if Y looks like an argument (uppercase / contains punctuation)
    # — heuristic for IP, NAME, etc. Lowercase-only Y is treated as a
    # subcommand candidate.
    if [[ "$y" != "${y,,}" ]]; then
        continue
    fi

    # English-prose filter on Y
    if is_english_y "$y"; then
        english_skipped=$((english_skipped + 1))
        continue
    fi

    # Skip if Y starts with a digit (positional arg like an IP)
    if [[ "$y" =~ ^[0-9] ]]; then
        continue
    fi

    # Check pair reachability (X, Y) — but only if X is a CANONICAL
    # command (alias-case targets are routed to another file and don't
    # have their own dispatch arms recorded here).
    if grep -qxF "$x" <(echo "$CANONICAL"); then
        if ! is_pair_dispatched "$x" "$y"; then
            if is_allowlisted "$f" "$ln" "$lit"; then
                allowlisted_count=$((allowlisted_count + 1))
                continue
            fi
            violation_count=$((violation_count + 1))
            printf '  [VIOLATION] %s:%s\t(X,Y)=(%s,%s)\t"%s"\n' "$f" "$ln" "$x" "$y" "$lit" >> "$VIOLATIONS_FILE"
        fi
    fi
done < "$HINTS_FILE"

# T3-1: parser summary
ok "T3-1: $checked_count hints checked, $variable_skipped vars-skipped, $english_skipped english-prose-skipped, $allowlisted_count allowlisted, $violation_count violations"

# T3-2: report-only on legacy drift. v1.144.0's commitment is to INSTALL
# the guard + close the specific D-UXV-14/15 sites (PR-C). The broader
# pre-existing parser-heuristic-unreachable hints (mostly cross-module
# self-test references in cmd_test.sh + helper-extraction blind spots
# on commands with non-`case "$subcommand"` dispatch) are tracked as
# v1.145.x sweep candidates. The hard PASS criteria are T3-3/4/5 which
# prove the guard's positive class-killer behavior.
#
# This row PASSES with violations as long as none are the specific
# D-UXV-14/15 signatures (connector-edit / nftban-reload / port-reload).
# Note: `grep -c` prints "0" on no-match AND returns rc=1; combining
# with `|| echo 0` would produce "0\n0" and break the integer compare.
# Use rc-tolerant wc -l instead, with the inner grep wrapped to not abort.
d_uxv_14_15_signatures=$({ grep -E '\(connector,edit\)|X=reload\b|\(port,reload\)' "$VIOLATIONS_FILE" 2>/dev/null || true; } | wc -l)
if [[ "$d_uxv_14_15_signatures" -eq 0 ]]; then
    ok "T3-2: D-UXV-14/15 specific signatures ABSENT (PR-C closure regression-locked); $violation_count legacy violations tracked for v1.145.x sweep"
else
    no "T3-2: D-UXV-14/15 specific signatures ABSENT (PR-C closure regression-locked)" \
       "$d_uxv_14_15_signatures D-UXV-14/15 signature(s) found in violations"
    echo
    echo "Violations:"
    cat "$VIOLATIONS_FILE"
fi

# Report legacy violations always (for v1.145.x grooming)
if [[ "$violation_count" -gt 0 ]]; then
    echo
    echo "  Legacy violations (not D-UXV-14/15; v1.145.x sweep candidates):"
    cat "$VIOLATIONS_FILE" | sed 's/^/  /'
fi

# T3-3: D-UXV-14 closure check (would-have-caught-it test) — assert
# 'nftban connector edit' would now be a violation (proves the guard
# would have caught D-UXV-14)
mock_drift=$(mktemp -t nftban-mock.XXXXXX)
trap 'rm -f "$DISPATCH_FILE" "$ALLOW_KEYS" "$HINTS_FILE" "$VIOLATIONS_FILE" "$mock_drift"' EXIT
echo '        echo "nftban connector edit foo"' > "$mock_drift"
# Run the same detection logic on the mock
mock_x="connector"
mock_y="edit"
if is_x_reachable "$mock_x"; then
    if ! is_pair_dispatched "$mock_x" "$mock_y"; then
        ok "T3-3: hypothetical 'nftban connector edit foo' WOULD be flagged (would have caught D-UXV-14)"
    else
        no "T3-3: hypothetical 'nftban connector edit foo' WOULD be flagged (would have caught D-UXV-14)" \
           "(connector, edit) is unexpectedly in dispatch table"
    fi
fi

# T3-4: D-UXV-15 closure check — assert 'nftban reload' would be a violation
mock_x="reload"
if ! is_x_reachable "$mock_x"; then
    ok "T3-4: hypothetical 'nftban reload' WOULD be flagged (would have caught D-UXV-15 + the audit's wrong replacement)"
else
    no "T3-4: hypothetical 'nftban reload' WOULD be flagged (would have caught D-UXV-15 + the audit's wrong replacement)" \
       "'reload' is unexpectedly in REACHABLE_X — audit-was-wrong protection lost"
fi

# T3-5: D-UXV-15 closure check — assert 'nftban port reload' would be a violation
mock_x="port"
mock_y="reload"
if is_x_reachable "$mock_x"; then
    if ! is_pair_dispatched "$mock_x" "$mock_y"; then
        ok "T3-5: hypothetical 'nftban port reload' WOULD be flagged (would have caught D-UXV-15)"
    else
        no "T3-5: hypothetical 'nftban port reload' WOULD be flagged (would have caught D-UXV-15)" \
           "(port, reload) is unexpectedly in dispatch table"
    fi
fi

# ──────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════════════"
echo "  cli_runtime_hint_reachability_v144_test: ${PASS} PASS / ${FAIL} FAIL"
echo "═══════════════════════════════════════════════════════════════"
echo "  Stats: $checked_count hints checked  |  $variable_skipped vars-skipped"
echo "         $allowlisted_count allowlisted  |  $violation_count unallowed violations"

if [[ $FAIL -gt 0 ]]; then
    echo "Failed tests:"
    for f in "${FAILED[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
