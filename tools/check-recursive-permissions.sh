#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - CI Guard: Block Recursive Permissions
# =============================================================================
# meta:name="check-recursive-permissions"
# meta:type="tool"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Prevent introduction of recursive permission commands"
# meta:inventory.files=""
# meta:inventory.binaries="git,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# This script blocks:
#   - chmod -R (recursive mode changes)
#   - chown -R (recursive ownership changes)
#
# These are dangerous because:
#   1. They can change permissions on user-edited config files
#   2. They create race conditions with other processes
#   3. They bypass the canonical FHS spec
#
# Instead, use:
#   - systemd-tmpfiles for runtime directories
#   - Package %files or dh_installdirs for package directories
#   - Explicit per-file permissions for specific files
# =============================================================================

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

REPO_ROOT="$(git rev-parse --show-toplevel)"

# Files to check (staged files only)
#
# v1.228.10: the subject is UNBOUNDED OWNERSHIP/MODE MUTATION, not the literal shell
# string "chown -R". Two coverage gaps were measured and are closed here:
#
#   1. GO WAS INVISIBLE. internal/installer/fhs/permissions.go issues the same policy as
#      exec.Run("chown","-R",...) argv elements, which no shell-only grep can see. That
#      path is the installer's permission fallback — a security actor the guard was blind to.
#   2. packaging/build_nftban.sh WAS BLIND-EXCLUDED as "legacy". It emits the RPM %post
#      scriptlet, so the exclusion hid a privileged packaging actor. The exclusion is removed.
#
# Still excluded, and only these: this script and health_check.sh, both of which contain the
# detection patterns themselves as data rather than as executable policy.
FILES=$(git diff --cached --name-only --diff-filter=ACMR | grep -E '\.(sh|go|spec|postinst|preinst|postrm|prerm)$' | grep -v 'check-recursive-permissions.sh' | grep -v 'health_check.sh' || true)

if [[ -z "$FILES" ]]; then
    echo -e "${GREEN}[OK]${NC} No shell/packaging files to check"
    exit 0
fi

ERRORS=0
PENDING_FILE="${REPO_ROOT}/scripts/ci/data/recursive-permission-pending.tsv"

# A site listed in the pending file is STILL WRONG and deliberately deferred (owner TODO-3,
# GO fallback parity). It is reported every run so the debt stays visible; it does not fail
# the build. Anything NOT listed fails immediately.
is_pending() {  # $1=file  $2=line
    [[ -f "$PENDING_FILE" ]] || return 1
    grep -qF "$1:$2	" "$PENDING_FILE" 2>/dev/null
}

echo "Checking for recursive permission commands..."

for file in $FILES; do
    filepath="${REPO_ROOT}/${file}"

    if [[ ! -f "$filepath" ]]; then
        continue
    fi

    # Shell surface. The subject is the EXECUTABLE COMMAND SURFACE, so a comment
    # describing the policy is not a violation of it — the same rule the Go branch
    # below already applies to '//' lines. A comment-only line (optionally indented)
    # is skipped; everything else is judged. Both comment prefixes count: '#' for shell
    # and '//' for Go, because this surface check also reads .go files.
    #
    # BOUNDARY, stated rather than faked: this does NOT discriminate a recursive verb
    # appearing inside a quoted string on an otherwise executable line. Doing that
    # correctly needs shell parsing, and a regex approximation would be fragile in
    # exactly the direction that matters (false negatives on real commands).
    while IFS=: read -r ln body; do
        [[ -n "$ln" ]] || continue
        case "$(printf '%s' "$body" | sed 's/^[[:space:]]*//')" in '#'*|'//'*) continue ;; esac
        echo -e "${RED}[ERROR]${NC} $file:$ln contains a recursive chown/chmod"
        echo "  Use explicit ownership/permissions or systemd-tmpfiles instead"
        ERRORS=$((ERRORS + 1))
    done < <(grep -n -E '(chown|chmod)\s+(-R|--recursive)' "$filepath" 2>/dev/null || true)

    # Go surface: the recursive flag as its own quoted argv element immediately after the
    # quoted verb. Written this way so a Go COMMENT or a log string naming the flag does
    # NOT match — only an actual command invocation does.
    if [[ "$file" == *.go ]]; then
        while IFS=: read -r ln _; do
            [[ -n "$ln" ]] || continue
            if is_pending "$file" "$ln"; then
                echo "  [PENDING] $file:$ln — deferred debt (GO fallback parity, owner TODO-3)"
            else
                echo -e "${RED}[ERROR]${NC} $file:$ln executes a recursive chown/chmod"
                echo "  Derive from the canonical FHS matrix (build/fhs-spec.yaml) instead"
                ERRORS=$((ERRORS + 1))
            fi
        done < <(grep -n -E '"(chown|chmod)"[[:space:]]*,[[:space:]]*"(-R|--recursive)"' "$filepath" 2>/dev/null || true)
    fi
done

if [[ $ERRORS -gt 0 ]]; then
    echo ""
    echo -e "${RED}[FAILED]${NC} Found $ERRORS recursive permission command(s)"
    echo ""
    echo "Recursive chmod/chown is prohibited because:"
    echo "  1. It changes permissions on user-edited config files"
    echo "  1b. It claims ownership of descendants the package never created"
    echo "  2. It creates race conditions with running services"
    echo "  3. It bypasses the canonical FHS spec"
    echo ""
    echo "Solutions:"
    echo "  - Use systemd-tmpfiles for runtime dirs (/var/lib, /var/log, etc.)"
    echo "  - Use find with -maxdepth for first-level subdirs only"
    echo "  - Use explicit per-file permissions for specific files"
    echo ""
    echo "See: build/fhs-spec.yaml for canonical directory specifications"
    exit 1
fi

echo -e "${GREEN}[OK]${NC} No recursive permission commands found"
exit 0
