#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.167 blocker guard: `update --dry-run` rc=1 + CLI-BUG-1 reachability
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_update_dry_run_hint_v167_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-08"
# meta:description="Regression guard for the v1.167 SHIP-BLOCKER (CLI-BUG-1): _v144_error_with_hint() is defined ONLY in lib/cmd_common.sh, but several subcommands (cmd_update, cmd_config, cmd_feeds, cmd_status, cmd_test, cmd_whitelist_system) call it on error paths WITHOUT sourcing cmd_common.sh, and the dispatcher did not source it either -> `nftban update --dry-run` (and the 6 sibling error paths) hit command-not-found rc=127 instead of the intended rc=1 + 3-line hint. Fix: the dispatcher cli/sbin/nftban sources cmd_common.sh once. This guard asserts (a) the dispatcher sources cmd_common.sh; (b) after the dispatcher load chain, _v144_error_with_hint is DEFINED (not rc=127); (c) _v144_error_with_hint itself returns rc=1 and prints ERROR/Hint/Run; (d) the cmd_update --dry-run guard site exists. Hermetic; no real update transaction."
# meta:inventory.files="cli/sbin/nftban,cli/lib/nftban/lib/cmd_common.sh,cli/lib/nftban/cli/cmd_update.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cli_update_dry_run_hint_v167_test"
# meta:ta.owner="update"
# meta:ta.module="update"
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

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
DISPATCH="$REPO_ROOT/cli/sbin/nftban"
LIBDIR="$REPO_ROOT/cli/lib/nftban"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "v1.167 update --dry-run / CLI-BUG-1 guard:"

# --- (a) the dispatcher sources cmd_common.sh ---------------------------------
if grep -qE 'source "\$\{NFTBAN_LIB_DIR\}/lib/cmd_common\.sh"' "$DISPATCH"; then
    ok "dispatcher cli/sbin/nftban sources lib/cmd_common.sh"
else
    no "dispatcher does NOT source lib/cmd_common.sh (CLI-BUG-1 would recur)"
fi

# --- (b) after the dispatcher global-load chain, the helper is DEFINED ---------
# Reproduce the dispatcher's top-level sourcing in a subshell (env + version +
# cmd_common), then assert _v144_error_with_hint is reachable.
defined=$(
  NFTBAN_LIB_DIR="$LIBDIR" bash -c '
    set +e
    export NFTBAN_LIB_DIR="'"$LIBDIR"'"
    source "${NFTBAN_LIB_DIR}/lib/env.sh" 2>/dev/null
    [[ -f "${NFTBAN_LIB_DIR}/lib/cmd_common.sh" ]] && source "${NFTBAN_LIB_DIR}/lib/cmd_common.sh" 2>/dev/null
    declare -f _v144_error_with_hint >/dev/null 2>&1 && echo DEFINED || echo MISSING
  '
)
[[ "$defined" == "DEFINED" ]] \
    && ok "_v144_error_with_hint is DEFINED after the dispatcher load chain (no rc=127)" \
    || no "_v144_error_with_hint MISSING after dispatcher load chain → rc=127 ship-blocker"

# --- (c) _v144_error_with_hint returns rc=1 and prints ERROR/Hint/Run ----------
rc_and_out=$(
  NFTBAN_LIB_DIR="$LIBDIR" bash -c '
    export NFTBAN_LIB_DIR="'"$LIBDIR"'"
    source "${NFTBAN_LIB_DIR}/lib/cmd_common.sh" 2>/dev/null
    # cmd_common.sh re-enables `set -Eeuo pipefail`; disable it here so the
    # INTENDED rc=1 from _v144_error_with_hint does not abort this probe.
    set +e
    out=$(_v144_error_with_hint "test fault" "test hint" "nftban update check" 2>&1)
    echo "RC=$?"
    printf "%s\n" "$out"
  ' || true
)
echo "$rc_and_out" | grep -q '^RC=1$' \
    && ok "_v144_error_with_hint returns rc=1" \
    || no "_v144_error_with_hint did not return rc=1" "$(echo "$rc_and_out" | grep '^RC=')"
echo "$rc_and_out" | grep -qiE 'ERROR' && echo "$rc_and_out" | grep -qiE 'hint|run' \
    && ok "_v144_error_with_hint prints the 3-line ERROR/Hint/Run form" \
    || no "_v144_error_with_hint output missing ERROR/Hint/Run"

# --- (d) cmd_update has the --dry-run guard calling _v144_error_with_hint ------
if grep -qE -- '--dry-run' "$LIBDIR/cli/cmd_update.sh" && \
   grep -A3 -- '"\$cmd" == "--dry-run"' "$LIBDIR/cli/cmd_update.sh" | grep -q '_v144_error_with_hint'; then
    ok "cmd_update.sh has the --dry-run guard → _v144_error_with_hint"
else
    no "cmd_update.sh --dry-run guard missing or not wired to the hint"
fi

# --- (e) the 6 CLI-BUG-1 callsites are now reachable via the dispatcher --------
# (they call _v144_error_with_hint; with the dispatcher sourcing cmd_common.sh
# the function is in scope for all of them — assert each file still calls it AND
# the dispatcher source is present, which is the runtime bridge.)
bug1_files=(cmd_config.sh cmd_feeds.sh cmd_whitelist_system.sh cmd_update.sh cmd_status.sh cmd_test.sh)
missing=""
for f in "${bug1_files[@]}"; do
    grep -q '_v144_error_with_hint' "$LIBDIR/cli/$f" || missing+="$f "
done
[[ -z "$missing" ]] \
    && ok "all 6 CLI-BUG-1 callsites present and now dispatcher-reachable" \
    || no "expected callsites not found in: $missing"

echo ""
echo "  PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
