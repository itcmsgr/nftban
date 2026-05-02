#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.100.4 — H3.3 Shell-Delete Guard
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="ci-shell-delete-guard"
# meta:type="ci-script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-02"
# meta:description="H3.3 CI guard refusing protected shell deletions without authorization marker"
# meta:inventory.files="scripts/ci/shell-delete-guard.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars="GITHUB_PR_TITLE, GITHUB_PR_BODY, BASE_REF"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
#
# Composes with H3.2 (Migration Coverage Gate). Both gates use inline
# classification rules — the spec doc lives in an internal audit/wiki
# workspace and is intentionally NOT shipped in this repo. H3.2 enforces
# add/state invariants; H3.3 enforces deletion-side discipline.
#
# 5 required checks per OPERATOR DECISION 2026-05-02:
#   1. NO-DROP-OPERATOR-FACING-SHELL
#   2. NO-DROP-SHARED-SHELL-LIBS
#   3. NO-DROP-RUNTIME-DIRS-CODE
#   4. NO-DROP-DEPRECATED-MARKERS
#   5. REQUIRE-MIGRATION-COVERAGE-UPDATE
#
# Allowed authorization markers (case-insensitive, whitespace-tolerant,
# searchable in PR title OR body):
#   [MIGRATION-LANE-AUTHORIZED]
#   [DEPRECATED-REMOVAL]
#
# Multi-PR migration handling: a deletion PR with [MIGRATION-LANE-AUTHORIZED]
# may PASS even without same-PR Go replacement IF the surface basename is in
# the inline ALREADY_MIGRATED_BASENAMES allow-list (operator updates the
# script when a migration lands).
#
# Local invocation:
#     bash scripts/ci/shell-delete-guard.sh [<base-ref>]
# Default <base-ref> = origin/main.
#
# CI invocation:
#     .github/workflows/ci-shell-delete-guard.yml
# Reads PR title from GITHUB_PR_TITLE and body from GITHUB_PR_BODY env vars.
# In a real PR run, the workflow extracts these from the github.event payload.
#
# Known accepted limitations for v1.100.4:
#   - Marker-spoofing requires human review (no behavioral verification)
#   - No CODEOWNERS enforcement here
#   - Rename/symlink/tombstone hardening deferred to v1.101 follow-up
#     H3_3_RENAME_ESCAPE_001
# =============================================================================
set -Eeuo pipefail

# Use the CALLER's git toplevel (not the script's own location) so that
# tooling and tests can run the guard against any worktree. Falls back to
# the script's parent-of-parent dir if not in a git context.
if REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$REPO_ROOT" ]; then
    cd "$REPO_ROOT"
else
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    cd "$REPO_ROOT"
fi

BASE_REF="${1:-${BASE_REF:-origin/main}}"

# Inline classification rules. The migration-coverage spec lives in an
# internal audit/wiki workspace and is intentionally NOT shipped in this
# repo. The lists below MUST stay in sync with that internal spec.

# Files currently classified as deprecated (eligible for [DEPRECATED-REMOVAL]).
# Empty by design at v1.100.4 — the only deprecated unit (nftban-ui.service)
# is already absent from the source tree; future deprecations land here.
DEPRECATED_BASENAMES=()

# Surfaces classified as already-migrated/deprecated on main BEFORE any PR.
# Used by the multi-PR migration support: a follow-up deletion PR with
# [MIGRATION-LANE-AUTHORIZED] passes if the surface is in this list.
# Empty at v1.100.4 — no formal/intentional shell-owned surface has yet
# been migrated to Go-only. Update inline when migrations land.
ALREADY_MIGRATED_BASENAMES=()

declare -i FAILS=0
declare -i CHECKS=0

check_pass() {
    local name="$1" detail="$2"
    printf "%s: PASS  %s\n" "$name" "$detail"
    CHECKS=$((CHECKS + 1))
}

check_fail() {
    local name="$1" detail="$2"
    printf "%s: FAIL  %s\n" "$name" "$detail" >&2
    CHECKS=$((CHECKS + 1))
    FAILS=$((FAILS + 1))
}

echo "============================================================"
echo "H3.3 shell-delete guard — branch HEAD $(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
echo "rules: inline (internal H3.1 spec is not in this repo)"
echo "diff base: $BASE_REF"
echo "============================================================"

# -----------------------------------------------------------------------------
# Compute deletion set (status=D), with rename detection (-M) so renames are
# not double-counted as deletions. Renames-out-of-tree are deferred per
# OPERATOR DECISION (rename-detection scope decision item 5; tracked as
# v1.101 follow-up H3_3_RENAME_ESCAPE_001).
# -----------------------------------------------------------------------------
DELETED_FILES=()
ADDED_OR_MODIFIED=()

if git rev-parse --verify "$BASE_REF" >/dev/null 2>&1; then
    while IFS=$'\t' read -r status path _rest; do
        case "$status" in
            D)   DELETED_FILES+=("$path") ;;
            A|M) ADDED_OR_MODIFIED+=("$path") ;;
        esac
    done < <(git diff -M --name-status --diff-filter=DAM "${BASE_REF}...HEAD" 2>/dev/null || true)
else
    echo "WARN: base ref '$BASE_REF' not found; running in zero-deletion mode (all checks PASS by default)" >&2
fi

echo "Diff vs $BASE_REF: ${#DELETED_FILES[@]} deletions; ${#ADDED_OR_MODIFIED[@]} adds/modifies."

# -----------------------------------------------------------------------------
# Watched-path classifications (per H3.1 §6 / §7 + OPERATOR DECISION 2026-05-02)
#
# §2.1 Operator-facing shell CLI (intentionally shell-owned)
# §2.2 Shared shell libraries (mixed bridge)
# §2.3 Runtime-dir creators (shell-runtime artifacts)
# §2.4 Deprecated marker zone (nftban-ui*)
#
# Classification is by-prefix and by-glob. is_*_path functions return 0 if
# the given path falls into that category, 1 otherwise.
# -----------------------------------------------------------------------------

is_operator_facing_path() {
    local p="$1" base
    base=$(basename "$p")
    [[ "$p" == cli/lib/nftban/cli/* ]] || return 1
    case "$base" in
        cmd_ban.sh|cmd_unban.sh|cmd_whitelist.sh|cmd_blacklist.sh|\
        cmd_status.sh|cmd_feeds.sh|cmd_stats.sh|\
        cmd_panel.sh|cmd_report.sh|cmd_test.sh|\
        cmd_ddos.sh|cmd_botguard.sh|cmd_suricata.sh|cmd_botscan.sh|\
        cmd_login.sh|cmd_firewall.sh|cmd_config.sh|\
        cmd_health*.sh|\
        cmd_trust.sh)
            # cmd_trust.sh covers Cloudflare/CDN trust-feed surface
            # (DirectAdmin mandates Cloudflare whitelist; AWS / GOOGLE /
            # AZURE / DIGITALOCEAN / FASTLY / QUICCLOUD / CLOUDFLARE_CHINA
            # are co-providers). NO standalone cmd_cloudflare.sh exists.
            return 0 ;;
    esac
    return 1
}

is_shared_shell_lib_path() {
    local p="$1"
    case "$p" in
        cli/lib/nftban/core/nftban_table_classify.sh) return 0 ;;
        cli/lib/nftban/core/nftban_config_doctor.sh)  return 0 ;;
        cli/lib/nftban/core/nftban_trust.sh)          return 0 ;;
        cli/lib/nftban/helpers/autoheal.sh)           return 0 ;;
        cli/lib/nftban/lib/nftban_pipeline_validation.sh) return 0 ;;
        cli/lib/nftban/lib/nftban_panel_common.sh)    return 0 ;;
        cli/lib/nftban/lib/nftban_panel_*.sh)         return 0 ;;
        cli/lib/nftban/lib/cmd_common.sh)             return 0 ;;
        cli/lib/nftban/lib/env.sh)                    return 0 ;;
    esac
    return 1
}

# Runtime-dir creators — code that writes to /etc/nftban/rules.d/, state/,
# recorder/, backup/. Bounded list captured by:
#   grep -rln 'rules.d|/var/lib/nftban/state|/var/lib/nftban/recorder|/var/lib/nftban/backup' cli/lib/nftban/
# (10 hits at 2026-05-02). H3.3 hard-locks deletion of these until
# UPSTREAM-UNINSTALL-SHELL-RESIDUE-002 lands.
is_runtime_creator_path() {
    local p="$1"
    case "$p" in
        cli/lib/nftban/cli/cmd_firewall.sh|\
        cli/lib/nftban/cli/cmd_polkit.sh|\
        cli/lib/nftban/cli/cmd_port.sh|\
        cli/lib/nftban/cli/cmd_protect.sh|\
        cli/lib/nftban/cli/cmd_suricata.sh|\
        cli/lib/nftban/cli/cmd_suricata_setup.sh|\
        cli/lib/nftban/core/nftban_ddos_suricata.sh|\
        cli/lib/nftban/core/nftban_firewall_conflicts.sh|\
        cli/lib/nftban/core/nftban_report_port.sh|\
        cli/lib/nftban/core/nftban_system_ip.sh)
            return 0 ;;
    esac
    return 1
}

# -----------------------------------------------------------------------------
# Marker detection — case-insensitive, whitespace-tolerant.
# Reads from GITHUB_PR_TITLE + GITHUB_PR_BODY (env vars set by CI workflow).
# Locally, both default to empty.
# -----------------------------------------------------------------------------
PR_TITLE="${GITHUB_PR_TITLE:-}"
PR_BODY="${GITHUB_PR_BODY:-}"
COMBINED_TEXT="$PR_TITLE
$PR_BODY"

# A marker matches if the bracketed token appears (case-insensitive)
# anywhere in title OR body.
has_migration_marker() {
    grep -qiE '\[\s*MIGRATION-LANE-AUTHORIZED\s*\]' <<<"$COMBINED_TEXT"
}

has_deprecated_marker() {
    grep -qiE '\[\s*DEPRECATED-REMOVAL\s*\]' <<<"$COMBINED_TEXT"
}

# Inline-list classification helpers (replaces in-repo doc lookups).
# Returns 0 if the file's basename is classified per the inline rule.

# shellcheck disable=SC2329  # used by future check expansions
classified_migrated_or_deprecated() {
    local file="$1" base
    base=$(basename "$file")
    local x
    for x in "${ALREADY_MIGRATED_BASENAMES[@]:-}" "${DEPRECATED_BASENAMES[@]:-}"; do
        [ "$x" = "$base" ] && return 0
    done
    return 1
}

classified_deprecated() {
    local file="$1" base
    base=$(basename "$file")
    local x
    for x in "${DEPRECATED_BASENAMES[@]:-}"; do
        [ "$x" = "$base" ] && return 0
    done
    return 1
}

# CHECK 5 doc-coverage-update no longer applies — the spec doc is not in
# the repo. The migration-marker authorization path now relies on the
# inline ALREADY_MIGRATED_BASENAMES allow-list (operator updates the
# script when migrations land). Stub remains for code-flow continuity.
# shellcheck disable=SC2329  # retained for symmetry; always returns false
doc_in_diff() {
    return 1
}

# Verify a Go-side replacement was added in this PR (any new .go file
# under internal/installer/ or cmd/nftban-installer/ counts as a
# presence-only signal; behavioral equivalence is human-review territory).
go_replacement_in_diff() {
    local f
    for f in "${ADDED_OR_MODIFIED[@]:-}"; do
        [ -z "$f" ] && continue
        case "$f" in
            internal/installer/*.go|cmd/nftban-installer/*.go) return 0 ;;
        esac
    done
    return 1
}

# Multi-PR migration support: if surface already in ALREADY_MIGRATED_BASENAMES,
# a same-PR Go-replacement is NOT required.
already_migrated_on_base() {
    local file="$1" base
    base=$(basename "$file")
    local x
    for x in "${ALREADY_MIGRATED_BASENAMES[@]:-}"; do
        [ "$x" = "$base" ] && return 0
    done
    return 1
}

# -----------------------------------------------------------------------------
# CHECK 1 — NO-DROP-OPERATOR-FACING-SHELL
# -----------------------------------------------------------------------------
{
    name="NO-DROP-OPERATOR-FACING-SHELL"
    fail_detail=""
    matched=0

    for f in "${DELETED_FILES[@]:-}"; do
        [ -z "$f" ] && continue
        if is_operator_facing_path "$f"; then
            matched=$((matched + 1))
            if has_deprecated_marker; then
                if classified_deprecated "$f"; then
                    continue
                fi
                fail_detail+="$f deleted under [DEPRECATED-REMOVAL] but docs/MIGRATION_COVERAGE.md does not mark it 'deprecated'; "
                continue
            fi
            if has_migration_marker; then
                # PASS conditions: (a) same-PR Go replacement + doc updated, OR
                # (b) doc already migrated/deprecated on base ref before this PR.
                if doc_in_diff && go_replacement_in_diff; then
                    continue
                fi
                if already_migrated_on_base "$f"; then
                    continue
                fi
                fail_detail+="$f deleted under [MIGRATION-LANE-AUTHORIZED] but lacks (doc update + Go replacement) in same PR AND doc on $BASE_REF does not already mark it migrated/deprecated; "
                continue
            fi
            fail_detail+="$f is operator-facing shell (H3.1 §6) — deletion requires [MIGRATION-LANE-AUTHORIZED] or [DEPRECATED-REMOVAL] marker in PR title or body; "
        fi
    done

    if [ -n "$fail_detail" ]; then
        check_fail "$name" "$fail_detail"
    else
        check_pass "$name" "no protected operator-facing shell deletions ($matched candidate(s) reviewed)"
    fi
}

# -----------------------------------------------------------------------------
# CHECK 2 — NO-DROP-SHARED-SHELL-LIBS
# -----------------------------------------------------------------------------
{
    name="NO-DROP-SHARED-SHELL-LIBS"
    fail_detail=""
    matched=0

    for f in "${DELETED_FILES[@]:-}"; do
        [ -z "$f" ] && continue
        if is_shared_shell_lib_path "$f"; then
            matched=$((matched + 1))
            if has_deprecated_marker && classified_deprecated "$f"; then
                continue
            fi
            if has_migration_marker; then
                if doc_in_diff && go_replacement_in_diff; then continue; fi
                if already_migrated_on_base "$f"; then continue; fi
                fail_detail+="$f shared-lib deletion under [MIGRATION-LANE-AUTHORIZED] but doc/Go-replacement requirements not met; "
                continue
            fi
            fail_detail+="$f is shared shell library (H3.1 §7) — deletion requires marker; "
        fi
    done

    if [ -n "$fail_detail" ]; then
        check_fail "$name" "$fail_detail"
    else
        check_pass "$name" "no protected shared-shell-lib deletions ($matched candidate(s) reviewed)"
    fi
}

# -----------------------------------------------------------------------------
# CHECK 3 — NO-DROP-RUNTIME-DIRS-CODE
# H3.3 hard-locks runtime-creator deletions until
# UPSTREAM-UNINSTALL-SHELL-RESIDUE-002 lands. Marker alone is insufficient.
# -----------------------------------------------------------------------------
{
    name="NO-DROP-RUNTIME-DIRS-CODE"
    fail_detail=""
    matched=0

    for f in "${DELETED_FILES[@]:-}"; do
        [ -z "$f" ] && continue
        if is_runtime_creator_path "$f"; then
            matched=$((matched + 1))
            # Hard-lock: even with marker, runtime-creator deletion requires
            # UPSTREAM-UNINSTALL-SHELL-RESIDUE-002 to land first.
            fail_detail+="$f creates shell-runtime artifacts (H3.1 row 29) — deletion is hard-locked until UPSTREAM-UNINSTALL-SHELL-RESIDUE-002 (v1.101 follow-up) lands; "
        fi
    done

    if [ -n "$fail_detail" ]; then
        check_fail "$name" "$fail_detail"
    else
        check_pass "$name" "no runtime-creator deletions ($matched candidate(s) reviewed)"
    fi
}

# -----------------------------------------------------------------------------
# CHECK 4 — NO-DROP-DEPRECATED-MARKERS
#   FAIL if [DEPRECATED-REMOVAL] PR deletes a file whose H3.1 row is NOT
#         classified deprecated, OR
#   FAIL if [DEPRECATED-REMOVAL] PR strips the deprecated row from the doc
#         (the row must remain as historical evidence).
# -----------------------------------------------------------------------------
{
    name="NO-DROP-DEPRECATED-MARKERS"
    fail_detail=""

    if has_deprecated_marker; then
        for f in "${DELETED_FILES[@]:-}"; do
            [ -z "$f" ] && continue
            # Only meaningful for paths that fall into a watched category.
            if is_operator_facing_path "$f" || is_shared_shell_lib_path "$f" || is_runtime_creator_path "$f"; then
                if ! classified_deprecated "$f"; then
                    fail_detail+="$f under [DEPRECATED-REMOVAL] but doc does not classify it 'deprecated'; "
                fi
            fi
        done

        # Doc-row-stays rule: if the doc was modified, the resulting doc
        # MUST still mention 'deprecated' classification at least once
        # (we cannot easily check per-row preservation in shell, but
        # presence of the keyword on the post-PR doc is a strong signal).
        if doc_in_diff; then
            if ! grep -qiE '\bdeprecated\b' "$MIGRATION_COVERAGE_DOC"; then
                fail_detail+="[DEPRECATED-REMOVAL] PR appears to strip 'deprecated' classification from doc; historical row must remain; "
            fi
        fi

        if [ -z "$fail_detail" ]; then
            check_pass "$name" "[DEPRECATED-REMOVAL] requirements satisfied"
        else
            check_fail "$name" "$fail_detail"
        fi
    else
        check_pass "$name" "no [DEPRECATED-REMOVAL] PR; nothing to enforce"
    fi
}

# -----------------------------------------------------------------------------
# CHECK 5 — REQUIRE-MIGRATION-COVERAGE-UPDATE
#   Bounded to ownership-boundary crossings (per OPERATOR DECISION q4).
#   The principal trigger is deletion of a watched shell file. CHECK 5
#   complements CHECK 1/2 by requiring the doc be in the diff for any
#   migration-marker-tagged deletion.
# -----------------------------------------------------------------------------
{
    name="REQUIRE-MIGRATION-COVERAGE-UPDATE"
    fail_detail=""
    cross=0

    for f in "${DELETED_FILES[@]:-}"; do
        [ -z "$f" ] && continue
        if is_operator_facing_path "$f" || is_shared_shell_lib_path "$f"; then
            cross=$((cross + 1))
        fi
    done

    if [ "$cross" -gt 0 ]; then
        if has_migration_marker; then
            if ! doc_in_diff && ! already_migrated_on_base "${DELETED_FILES[0]:-}"; then
                fail_detail+="ownership-boundary crossing detected ($cross deletion(s)) — docs/MIGRATION_COVERAGE.md must be in the diff OR the surface must already be migrated/deprecated on $BASE_REF; "
            fi
        elif has_deprecated_marker; then
            : # CHECK 4 covers the doc-stays rule
        else
            : # CHECK 1/2 will fail; CHECK 5 stays silent on already-blocked PRs
        fi
    fi

    if [ -n "$fail_detail" ]; then
        check_fail "$name" "$fail_detail"
    else
        check_pass "$name" "no ownership-boundary crossing without doc update"
    fi
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo "============================================================"
echo "Summary: $CHECKS checks executed; $FAILS required failures."
if [ "$FAILS" -eq 0 ]; then
    echo "H3.3 shell-delete guard: PASS"
    exit 0
else
    echo "H3.3 shell-delete guard: FAIL"
    exit 1
fi
