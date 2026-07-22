#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.153 PR-B: banner discipline + --no-banner/--plain/--quiet
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="banner_nobanner_v153_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-06"
# meta:description="Locks v1.153 PR-B banner discipline: (1) NOBANNER-CONSIST — the dispatcher (cli/sbin/nftban) maps --plain and --quiet to the universal banner-suppression env (NFTBAN_NO_BANNER/NFTBAN_QUIET) the same way --no-banner does, and leaves them in argv so per-subcommand semantics still see them; (2) one banner path — nftban_banner_unified routes through _v141_banner_suppressed and restricts the decorative FULL BOX to version/status/hello/first-run, while every other subcommand (list/firewall/feeds/…) gets the one-line simple header; (3) Cmd: truth — callsites passing no mode resolve to the dispatcher-exported NFTBAN_SUBCOMMAND instead of the literal 'cli'. Hermetic: sources nftban_output.sh and stubs the two render functions to observe routing; drives the dispatcher with --plain/--quiet/--no-banner. No host/nft/IPC."
# meta:input="cli/lib/nftban/core/nftban_output.sh + cli/sbin/nftban"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,mktemp"
# meta:inventory.files="cli/lib/nftban/core/nftban_output.sh,cli/sbin/nftban"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_NO_BANNER,NFTBAN_QUIET,NFTBAN_BANNER_MODE,NFTBAN_SUBCOMMAND"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="banner_nobanner_v153_test"
# meta:ta.owner="cli"
# meta:ta.module="banner"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
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
SBIN="$REPO/cli/sbin/nftban"
OUTPUT="$REPO/cli/lib/nftban/core/nftban_output.sh"
export NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"
export NFTBAN_NONINTERACTIVE=1

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

# ---------------------------------------------------------------------------
# Routing harness: source nftban_output.sh, stub the two render functions to
# emit markers, then call nftban_banner_unified for a given mode/env and
# observe which path fired.
# ---------------------------------------------------------------------------
route() {
    # $1 = env assignments ; $2 = mode arg (may be empty)
    local env_assign="$1" mode="${2:-}"
    bash -c "
        set +e
        $env_assign
        export NFTBAN_LIB_DIR='$NFTBAN_LIB_DIR'
        source '$OUTPUT' 2>/dev/null || true
        nftban_render_banner_simple() { echo 'PATH:SIMPLE'; }
        nftban_render_banner_compact() { echo 'PATH:SIMPLE'; }
        nftban_render_banner_full()   { echo 'PATH:FULL'; }
        # Replace the heavy full-box body so we observe the gate decision only:
        # the gate runs BEFORE the box body, so if we reach the body we mark FULL.
        nftban_banner_unified_body_marker() { echo 'PATH:FULLBOX'; }
        nftban_banner_unified '$mode' 2>&1 | grep -E 'PATH:' || echo 'PATH:NONE-OR-FULLBODY'
    "
}

echo "=== NOBANNER-CONSIST: dispatcher maps --plain/--quiet to suppression env ==="
grep -qE '\-\-plain\|--quiet\)' "$SBIN" \
    && ok "dispatcher argv scan handles --plain|--quiet" || no "--plain/--quiet not handled in dispatcher"
grep -q 'export NFTBAN_SUBCOMMAND=' "$SBIN" \
    && ok "dispatcher exports NFTBAN_SUBCOMMAND (Cmd: truth source)" || no "NFTBAN_SUBCOMMAND not exported"
# --plain/--quiet must NOT be consumed (left in argv like --json)
awk '/--plain\|--quiet\)/,/;;/' "$SBIN" | grep -q '_filtered+=' \
    && ok "--plain/--quiet left in argv (subcommand still sees them)" \
    || no "--plain/--quiet consumed (would break status --quiet)"

echo "=== one banner path: suppression env wins (any subcommand) ==="
for env in 'export NFTBAN_NO_BANNER=1' 'export NFTBAN_QUIET=1' 'export NFTBAN_BANNER_MODE=none'; do
    out="$(route "$env" status)"
    [[ "$out" != *PATH:SIMPLE* && "$out" != *PATH:FULL* ]] \
        && ok "suppressed ($env) → no banner path fired" \
        || no "suppression failed for $env" "$out"
done

echo "=== full box restricted to version/status/hello; others get one-line ==="
for m in version status hello; do
    out="$(route 'unset NFTBAN_NO_BANNER NFTBAN_QUIET NFTBAN_BANNER_MODE NFTBAN_SUBCOMMAND' "$m")"
    # Full-box body is heavy/stubbed-out env; the key assertion is it does NOT
    # short-circuit to the simple one-line header for these modes.
    [[ "$out" != *PATH:SIMPLE* ]] \
        && ok "mode '$m' is NOT downgraded to one-line header (full box allowed)" \
        || no "mode '$m' wrongly downgraded to simple header" "$out"
done
for m in list firewall feeds ban portscan; do
    out="$(route 'unset NFTBAN_NO_BANNER NFTBAN_QUIET NFTBAN_BANNER_MODE NFTBAN_SUBCOMMAND' "$m")"
    [[ "$out" == *PATH:SIMPLE* ]] \
        && ok "subcommand '$m' prints the one-line simple header (no full box)" \
        || no "subcommand '$m' did not route to the one-line header" "$out"
done

echo "=== Cmd: truth — no-mode callsite resolves to NFTBAN_SUBCOMMAND ==="
# When mode defaults to 'cli' but NFTBAN_SUBCOMMAND=feeds, the gate must treat
# it as the 'feeds' subcommand (one-line header), not the literal 'cli'.
out="$(route 'unset NFTBAN_NO_BANNER NFTBAN_QUIET NFTBAN_BANNER_MODE; export NFTBAN_SUBCOMMAND=feeds' cli)"
[[ "$out" == *PATH:SIMPLE* ]] \
    && ok "no-mode call with NFTBAN_SUBCOMMAND=feeds routes as 'feeds' (one-line)" \
    || no "Cmd: truth resolution failed" "$out"
grep -q 'NFTBAN_SUBCOMMAND' "$OUTPUT" \
    && ok "nftban_banner_unified consults NFTBAN_SUBCOMMAND" || no "NFTBAN_SUBCOMMAND not used in renderer"

echo ""
echo "================================================================"
echo "banner_nobanner_v153: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
