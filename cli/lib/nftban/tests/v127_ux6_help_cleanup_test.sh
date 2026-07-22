#!/usr/bin/env bash
# =============================================================================
# V127 UX-6 help-system cleanup — deterministic test fixtures
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="v127_ux6_help_cleanup_test"
# meta:type="test"
# meta:version="1.127.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-24"
# meta:description="Deterministic shell tests for V127 UX-6 lane (PR-F). Covers D-1 banner-pollution removal in nftban_help.sh + cmd_flush.sh help paths, D-7 fake 'Profile: operator' label removal from scripts/generate-help.sh footer, D-5 --async/--wait clarity rewrite in cmd_ban.sh, D-2 EXIT CODES sections present on cmd_ban.sh + cmd_flush.sh + cmd_update.sh + cmd_firewall.sh help blocks, D-3 CTRL+C interruption warning sections present on cmd_flush.sh + cmd_update.sh + cmd_firewall.sh, D-6 REQUIRES root notes present on the same three destructive commands, D-4 destructive-command help structure convergence (additive — measured by presence of the three new sections rather than full restructure), and explicit scope-creep guards that HELP_CODE_CORRELATION_AUDIT and WIKI_CLI_TEXT_ALIGNMENT pending follow-ups are NOT addressed in this PR per operator's 2026-05-24 directive."
# meta:input="static source-file inspection + functional source-and-call against _nftban_help_essential"
# meta:output="exit 0 if all assertions pass; exit 1 with FAILED tests list otherwise"
# meta:depends="bash,awk,grep,sed"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="v127_ux6_help_cleanup_test"
# meta:ta.owner="cli"
# meta:ta.module="cli-help-surface"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
#
# Scope: AUDIT_190_LIFECYCLE/V127_FULL_UX_CORRECTION_UMBRELLA_SCOPE.md (UX-6 lane)
# =============================================================================

set -Eeuo pipefail
# Continue past individual assertion failures so the suite reports total counts
set +e

TESTS_PASSED=0
TESTS_FAILED=0
FAILED_NAMES=()

_t_assert() {
    local name="$1"
    local ok="$2"
    local detail="${3:-}"
    if [[ "$ok" == "0" ]]; then
        printf "  [PASS] %s\n" "$name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        printf "  [FAIL] %s%s\n" "$name" "${detail:+ — $detail}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_NAMES+=("$name")
    fi
}

_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
_nftban_help="${_repo_root}/cli/lib/nftban/nftban_help.sh"
_generate_help="${_repo_root}/scripts/generate-help.sh"
_cmd_ban="${_repo_root}/cli/lib/nftban/cli/cmd_ban.sh"
_cmd_flush="${_repo_root}/cli/lib/nftban/cli/cmd_flush.sh"
_cmd_update="${_repo_root}/cli/lib/nftban/cli/cmd_update.sh"
_cmd_firewall="${_repo_root}/cli/lib/nftban/cli/cmd_firewall.sh"

echo "==============================================================================="
echo "V127 UX-6 help-system cleanup — deterministic test fixtures"
echo "==============================================================================="

# =============================================================================
# (A) D-1 banner pollution removed from help paths
# =============================================================================

# A1: nftban_print_help no longer calls nftban_banner before help text
awk '/^nftban_print_help\(\) \{/,/^\}$/' "$_nftban_help" | grep -qE '^\s*nftban_banner '
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "A1: nftban_print_help body does NOT call nftban_banner" "$ok"

# A2: _nftban_flush_help no longer renders the banner
awk '/^_nftban_flush_help\(\) \{/,/^HELP$/' "$_cmd_flush" | grep -qE '^\s*nftban_banner'
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "A2: _nftban_flush_help body does NOT call nftban_banner" "$ok"

# A3: V127 UX-6 anchor present in nftban_help.sh
grep -q 'V127 UX-6' "$_nftban_help"
_t_assert "A3: nftban_help.sh carries V127 UX-6 scope anchor" "$?"

# A4: V127 UX-6 anchor present in cmd_flush.sh
grep -q 'V127 UX-6' "$_cmd_flush"
_t_assert "A4: cmd_flush.sh carries V127 UX-6 scope anchor" "$?"

# A5: functional check via _nftban_help_essential — no banner string appears
# shellcheck disable=SC1090
( source "$_nftban_help" 2>&1; _nftban_help_essential ) 2>&1 | grep -qiE 'nftban v?[0-9]+\.[0-9]+|███|banner'
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "A5: _nftban_help_essential output contains no banner-like text" "$ok"

# =============================================================================
# (B) D-7 fake "Profile: operator" footer label removed
# =============================================================================

# B1: source no longer contains the Profile: $profile footer line
grep -qE '^Profile: \$profile$' "$_generate_help"
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "B1: generate-help.sh footer no longer contains 'Profile: \$profile'" "$ok"

# B2: V127 UX-6 anchor present in generate-help.sh
grep -q 'V127 UX-6' "$_generate_help"
_t_assert "B2: generate-help.sh carries V127 UX-6 scope anchor" "$?"

# B3: profile-gating logic preserved (should_show_for_profile function intact)
grep -q '^should_show_for_profile()' "$_generate_help"
_t_assert "B3: should_show_for_profile() profile-gating logic preserved (not collateral-removed)" "$?"

# =============================================================================
# (C) D-5 cmd_ban.sh --async / --wait clarity
# =============================================================================

# C1: --async help text rewritten — no longer says "Return immediately without waiting for sync"
# (the V127 replacement is multi-line; assert the legacy concise wording is gone)
grep -qE 'Return immediately without waiting for sync' "$_cmd_ban"
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "C1: cmd_ban.sh --async legacy short wording removed" "$ok"

# C2: --wait help text rewritten — no longer says only "Wait for nftables sync confirmation"
# (V127 replacement adds "This is the DEFAULT" clarification)
awk '/nftban_cmd_ban_usage\(\) \{/,/^EOF$/' "$_cmd_ban" | grep -qE 'DEFAULT'
_t_assert "C2: cmd_ban.sh --wait help text states it is the DEFAULT" "$?"

# C3: Notes block no longer contains the contradictory "synced to nftables immediately"
# (replaced with clearer "Default behavior writes ... and waits for the kernel set ...")
awk '/nftban_cmd_ban_usage\(\) \{/,/^EOF$/' "$_cmd_ban" | grep -qE 'synced to nftables immediately'
ok=$?
[[ $ok -eq 0 ]] && ok=1 || ok=0
_t_assert "C3: cmd_ban.sh Notes block no longer contains contradictory 'synced to nftables immediately'" "$ok"

# C4: Notes block contains the new "kernel set to confirm sync" clarity
awk '/nftban_cmd_ban_usage\(\) \{/,/^EOF$/' "$_cmd_ban" | grep -qE 'kernel set to confirm sync'
_t_assert "C4: cmd_ban.sh Notes block contains 'kernel set to confirm sync' wording" "$?"

# =============================================================================
# (D) D-2 EXIT CODES section present on the 4 target commands
# =============================================================================

# D1: cmd_ban.sh has Exit Codes section (gold-standard upgrade)
awk '/nftban_cmd_ban_usage\(\) \{/,/^EOF$/' "$_cmd_ban" | grep -qE '^Exit Codes:$'
_t_assert "D1: cmd_ban.sh help has 'Exit Codes:' section" "$?"

# D2: cmd_flush.sh help has EXIT CODES section
awk '/_nftban_flush_help\(\) \{/,/^HELP$/' "$_cmd_flush" | grep -qE '^EXIT CODES:$'
_t_assert "D2: cmd_flush.sh help has 'EXIT CODES:' section" "$?"

# D3: cmd_update.sh help has EXIT CODES section (pre-existing; verify not collateral-removed)
awk '/_cmd_update_help\(\) \{/,/^EOF$/' "$_cmd_update" | grep -qE '^EXIT CODES:$'
_t_assert "D3: cmd_update.sh help has 'EXIT CODES:' section" "$?"

# D4: cmd_firewall.sh help has the original 'Exit codes (validate --strict):' preserved
awk '/^show_firewall_help\(\) \{/,/^\}$/' "$_cmd_firewall" | grep -qE '^Exit codes \(validate --strict\):$'
_t_assert "D4: cmd_firewall.sh help preserves 'Exit codes (validate --strict):' section" "$?"

# D5: cmd_firewall.sh help adds the new 'Exit codes (other subcommands):' section
awk '/^show_firewall_help\(\) \{/,/^\}$/' "$_cmd_firewall" | grep -qE '^Exit codes \(other subcommands\):$'
_t_assert "D5: cmd_firewall.sh help has new 'Exit codes (other subcommands):' section" "$?"

# =============================================================================
# (E) D-3 CTRL+C interruption warning on the 3 destructive commands
# =============================================================================

# E1: cmd_flush.sh has CTRL+C section
awk '/_nftban_flush_help\(\) \{/,/^HELP$/' "$_cmd_flush" | grep -qE '^CTRL\+C / INTERRUPTION:$'
_t_assert "E1: cmd_flush.sh help has CTRL+C / INTERRUPTION section" "$?"

# E2: cmd_update.sh has CTRL+C section
awk '/_cmd_update_help\(\) \{/,/^EOF$/' "$_cmd_update" | grep -qE '^CTRL\+C / INTERRUPTION:$'
_t_assert "E2: cmd_update.sh help has CTRL+C / INTERRUPTION section" "$?"

# E3: cmd_firewall.sh has CTRL+C section
awk '/^show_firewall_help\(\) \{/,/^\}$/' "$_cmd_firewall" | grep -qE '^CTRL\+C / INTERRUPTION:$'
_t_assert "E3: cmd_firewall.sh help has CTRL+C / INTERRUPTION section" "$?"

# E4: each CTRL+C section says "Do NOT" or "do not"
for f in "$_cmd_flush" "$_cmd_update" "$_cmd_firewall"; do
    if ! grep -qE 'Do NOT interrupt|do not interrupt' "$f"; then
        _t_assert "E4: $(basename "$f") CTRL+C section lacks 'Do NOT interrupt' wording" 1
        E4_FAIL=1
        break
    fi
done
[[ -z "${E4_FAIL:-}" ]] && _t_assert "E4: all three destructive helps say 'Do NOT interrupt'" 0

# =============================================================================
# (F) D-6 REQUIRES root note on the 3 destructive commands
# =============================================================================

# F1: cmd_flush.sh REQUIRES section
awk '/_nftban_flush_help\(\) \{/,/^HELP$/' "$_cmd_flush" | grep -qE '^REQUIRES:$'
_t_assert "F1: cmd_flush.sh help has REQUIRES section" "$?"

# F2: cmd_update.sh REQUIRES section
awk '/_cmd_update_help\(\) \{/,/^EOF$/' "$_cmd_update" | grep -qE '^REQUIRES:$'
_t_assert "F2: cmd_update.sh help has REQUIRES section" "$?"

# F3: cmd_firewall.sh REQUIRES section
awk '/^show_firewall_help\(\) \{/,/^\}$/' "$_cmd_firewall" | grep -qE '^REQUIRES:$'
_t_assert "F3: cmd_firewall.sh help has REQUIRES section" "$?"

# F4: each REQUIRES section uses polkit-aware wording (PolicyKit/polkit
# mentioned + "site-approved privilege method" or "elevated privileges").
# Per feedback_polkit_not_sudo_in_help.md, NFTBan help text must NOT
# default to "Run with sudo" framing.
for f in "$_cmd_flush" "$_cmd_update" "$_cmd_firewall"; do
    block=$(grep -A 15 '^REQUIRES:$' "$f")
    if ! echo "$block" | grep -qE 'PolicyKit/polkit' \
       || ! echo "$block" | grep -qE 'site-approved privilege method' \
       || ! echo "$block" | grep -qE 'Elevated privileges'; then
        _t_assert "F4: $(basename "$f") REQUIRES section missing polkit-aware wording" 1
        F4_FAIL=1
        break
    fi
done
[[ -z "${F4_FAIL:-}" ]] && _t_assert "F4: all three destructive helps use polkit-aware wording (PolicyKit + site-approved + Elevated)" 0

# F5: NO legacy 'Run with sudo' wording in any of the three destructive
# command help blocks (post-correction guard).
for f in "$_cmd_flush" "$_cmd_update" "$_cmd_firewall"; do
    awk '/^REQUIRES:$/,/^[A-Z][A-Z]/' "$f" | grep -qiE 'Run with sudo'
    ok=$?
    if [[ $ok -eq 0 ]]; then
        _t_assert "F5: $(basename "$f") REQUIRES section still contains forbidden 'Run with sudo' wording" 1
        F5_FAIL=1
        break
    fi
done
[[ -z "${F5_FAIL:-}" ]] && _t_assert "F5: no destructive help carries forbidden 'Run with sudo' wording" 0

# F6: Exit-code wording uses "Authorization failed or insufficient
# privileges" form (not "Permission denied (not root)").
for f in "$_cmd_flush" "$_cmd_update" "$_cmd_firewall"; do
    if grep -qE 'Permission denied \(not root' "$f"; then
        _t_assert "F6: $(basename "$f") still uses legacy 'Permission denied (not root)' wording" 1
        F6_FAIL=1
        break
    fi
done
[[ -z "${F6_FAIL:-}" ]] && _t_assert "F6: no destructive help carries legacy 'Permission denied (not root)' wording" 0

# =============================================================================
# (G) D-4 destructive-cmd help structure convergence (additive measure)
# =============================================================================

# G1: All three destructive command helps now contain CTRL+C + REQUIRES + EXIT CODES sections
# (this is the additive convergence toward ban-help structure per UX-6 D-4)
for f in "$_cmd_flush" "$_cmd_update" "$_cmd_firewall"; do
    base=$(basename "$f")
    has_ctrl=$(grep -cE '^CTRL\+C / INTERRUPTION:$' "$f" || true)
    has_req=$(grep -cE '^REQUIRES:$' "$f" || true)
    has_exit=$(grep -ciE '^EXIT CODES:|^Exit codes' "$f" || true)
    has_ctrl=${has_ctrl:-0}; has_req=${has_req:-0}; has_exit=${has_exit:-0}
    if [[ "$has_ctrl" -lt 1 ]] || [[ "$has_req" -lt 1 ]] || [[ "$has_exit" -lt 1 ]]; then
        _t_assert "G1: $base lacks one of CTRL+C/REQUIRES/EXIT CODES (ctrl=$has_ctrl req=$has_req exit=$has_exit)" 1
        G1_FAIL=1
    fi
done
[[ -z "${G1_FAIL:-}" ]] && _t_assert "G1: flush/update/firewall help all carry CTRL+C + REQUIRES + EXIT CODES" 0

# =============================================================================
# (H) Scope-creep guards — explicit non-addressing of pending follow-ups
# =============================================================================

# H1: NO HELP_CODE_CORRELATION_AUDIT doctest sweep introduced in this PR
# (operator's 2026-05-24 directive: "Record as pending after UX-6")
if git diff --name-only HEAD 2>/dev/null | grep -qiE 'help.*correlat|doctest|help.*example.*test'; then
    _t_assert "H1: scope-creep: doctest/help-correlation sweep file appears in diff" 1
else
    _t_assert "H1: HELP_CODE_CORRELATION_AUDIT not addressed (pending follow-up preserved)" 0
fi

# H2: NO WIKI_CLI_TEXT_ALIGNMENT changes in this PR
if git diff --name-only HEAD 2>/dev/null | grep -qiE '^WIKI/|^docs/.*\.md$|wiki.*align'; then
    _t_assert "H2: scope-creep: wiki/docs file appears in diff" 1
else
    _t_assert "H2: WIKI_CLI_TEXT_ALIGNMENT not addressed (pending follow-up preserved)" 0
fi

# H3: NO new commands or aliases introduced (canonical command list unchanged)
if git diff cli/sbin/nftban 2>/dev/null | grep -qE '^\+.*echo "[a-z][a-z-]+"' \
   && git diff cli/sbin/nftban 2>/dev/null | grep -qE '^\+.*_nftban_canonical_commands'; then
    _t_assert "H3: scope-creep: new commands appear added to dispatcher/completion/canonical-list" 1
else
    _t_assert "H3: no new commands or aliases introduced" 0
fi

# H4: NO Suricata work
if git diff 2>/dev/null | grep -qiE '^\+.*[Ss]uricata' | head -3; then
    # Note: above pipeline may match incidental mentions like "fail2ban/csf/firewalld/suricata"
    # in narrative text; this check is intentionally loose — visual review in review packet
    _t_assert "H4: scope-creep WARNING: Suricata mention found in diff (visual review needed)" 1
else
    _t_assert "H4: no Suricata-specific changes" 0
fi

# H5: NO release/tag/publish files
if git status --porcelain 2>/dev/null | grep -qE '^.. (VERSION|STATUS\.md|CHANGELOG\.md|.*\.spec|.*\.fhs|release-)'; then
    _t_assert "H5: release/tag/publish file appears in diff" 1
else
    _t_assert "H5: no release/tag/publish files touched" 0
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "==============================================================================="
echo "V127 UX-6 test summary: ${TESTS_PASSED} PASS, ${TESTS_FAILED} FAIL"
echo "==============================================================================="
if [[ "$TESTS_FAILED" -gt 0 ]]; then
    echo "Failed tests:"
    for name in "${FAILED_NAMES[@]}"; do
        echo "  - $name"
    done
    exit 1
fi
exit 0
