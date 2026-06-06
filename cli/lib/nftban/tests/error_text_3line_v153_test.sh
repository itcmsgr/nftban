#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.153 PR-C: error-text normalization (UX-C2 + UX-C6)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="error_text_3line_v153_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-06"
# meta:description="Locks v1.153 PR-C error-text normalization. UX-C2: cmd_error with a usage_func no longer reprints the ~30-line usage block on parse errors — it emits exactly the 'ERROR: <fault>' line plus a single 'Run 'nftban <cmd> --help' for more' pointer, deriving <cmd> from the conventional nftban_cmd_<name>_usage name (underscores -> spaces for subcommands). The full usage text remains available via the explicit --help path (usage_func called directly). UX-C6: _require_root_or_sudo_hint prints the inline sudo/root-shell guidance and returns non-zero when EUID!=0, returns 0 when root. JSON mode stays structured (no pointer/hint chrome). Hermetic: sources lib/cmd_common.sh; no host/nft/IPC."
# meta:input="cli/lib/nftban/lib/cmd_common.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files="cli/lib/nftban/lib/cmd_common.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
export NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

# Source cmd_common in a controlled subshell (env.sh deps tolerated).
load() {
    # shellcheck source=/dev/null
    source "$NFTBAN_LIB_DIR/lib/cmd_common.sh" 2>/dev/null || true
}

# A fake 30-line usage function to prove it is NOT reprinted on parse error.
make_fake_usage() {
    cat <<'STUB'
nftban_cmd_ban_usage() {
    cat <<'EOF'
nftban ban — line1
line2
line3
line4
line5
line6
line7
line8
line9
line10
EOF
}
STUB
}

echo "=== UX-C2: cmd_error with usage_func emits 3-line form, not the block ==="
out=$(
    set +e
    load
    eval "$(make_fake_usage)"
    cmd_error "Unknown option: --bogus" false nftban_cmd_ban_usage 2>&1
) || true
line_count=$(printf '%s\n' "$out" | grep -c . || true)
printf '%s\n' "$out" | grep -q "^ERROR: Unknown option: --bogus$" \
    && ok "first line is 'ERROR: <fault>'" || no "ERROR line missing" "$out"
printf '%s\n' "$out" | grep -q "Run 'nftban ban --help' for more" \
    && ok "pointer line names the derived command (ban)" || no "pointer line missing/wrong" "$out"
printf '%s\n' "$out" | grep -q "^line5$" \
    && no "full usage block WAS reprinted (UX-C2 violated)" "$out" \
    || ok "full usage block NOT reprinted"
[[ "$line_count" -le 3 ]] \
    && ok "error output is <= 3 lines (was ~30)" || no "too many lines: $line_count" "$out"

echo "=== UX-C2: subcommand usage name -> spaced command in the hint ==="
out=$(
    set +e
    load
    eval 'nftban_cmd_config_validate_usage() { echo "usage..."; }'
    cmd_error "bad arg" false nftban_cmd_config_validate_usage 2>&1
) || true
printf '%s\n' "$out" | grep -q "Run 'nftban config validate --help' for more" \
    && ok "underscores in usage name -> spaced subcommand in hint" || no "subcommand hint wrong" "$out"

echo "=== UX-C2: JSON mode stays structured (no pointer chrome) ==="
out=$(
    set +e
    load
    json_error() { echo "{\"success\":false,\"error\":\"$1\"}"; }
    eval 'nftban_cmd_ban_usage() { echo "usage"; }'
    cmd_error "bad" true nftban_cmd_ban_usage 2>&1
) || true
printf '%s\n' "$out" | grep -q "Run 'nftban" \
    && no "JSON mode leaked a pointer hint" "$out" \
    || ok "JSON mode emits no pointer hint"

echo "=== UX-C6: _require_root_or_sudo_hint prints guidance when not root ==="
load
declare -f _require_root_or_sudo_hint >/dev/null 2>&1 \
    && ok "_require_root_or_sudo_hint is defined" || no "_require_root_or_sudo_hint missing"
# The test runner is non-root, so the real EUID exercises the not-root branch
# directly. (EUID is readonly in bash and cannot be shadowed to simulate root.)
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    out=$(
        set +e
        load
        _require_root_or_sudo_hint "ban an IP" false 2>&1
        echo "RC=$?"
    ) || true
    printf '%s\n' "$out" | grep -q "requires root privileges" \
        && ok "emits a root-required line when EUID!=0" || no "root-required line missing" "$out"
    printf '%s\n' "$out" | grep -q "Re-run with one of:" \
        && ok "emits the inline sudo / root-shell re-run guidance" || no "sudo hint missing" "$out"
    printf '%s\n' "$out" | grep -q "RC=1" \
        && ok "returns non-zero when not root" || no "did not return non-zero" "$out"
else
    ok "skipped not-root runtime check (test running as root)"
    ok "skipped not-root runtime check (test running as root)"
    ok "skipped not-root runtime check (test running as root)"
fi
# Root path: assert the source contract (EUID==0 -> silent return 0). EUID is
# readonly so we verify the implemented logic rather than simulate uid 0.
CC="$NFTBAN_LIB_DIR/lib/cmd_common.sh"
awk '/^_require_root_or_sudo_hint\(\) \{/,/^\}/' "$CC" | grep -qE '\-ne 0 \]\]' \
    && ok "root path is guarded by an EUID -ne 0 check (returns 0 when root)" \
    || no "EUID guard missing in _require_root_or_sudo_hint"
awk '/^_require_root_or_sudo_hint\(\) \{/,/^\}/' "$CC" | grep -qE '^    return 0$' \
    && ok "function returns 0 on the root (success) path" || no "return 0 missing"

echo ""
echo "================================================================"
echo "error_text_3line_v153: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
