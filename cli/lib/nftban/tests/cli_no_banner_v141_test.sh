#!/usr/bin/env bash
# =============================================================================
# NFTBan - --no-banner / NFTBAN_NO_BANNER discipline test (v1.141 PR-B E-NO-BANNER)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_no_banner_v141_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-28"
# meta:description="v1.141 PR-B E-NO-BANNER — asserts that --no-banner OR NFTBAN_NO_BANNER=1 OR --json suppresses ALL decorative chrome from the banner emitters: nftban_banner, nftban_render_banner, nftban_render_banner_simple, nftban_banner_unified. Decorative chrome = +--…-+ box, ╔══ frame, ━━━ run, 🐧🛡️ icon banner header. The contract is checked at the central gate inside cli/lib/nftban/core/nftban_output.sh (_v141_banner_suppressed). Hermetic — no host contact; sources nftban_output.sh directly into a bash subshell."
# meta:input="cli/lib/nftban/core/nftban_output.sh + cli/sbin/nftban dispatcher"
# meta:output="Pass/fail assertions per env/flag combination; exit 0 on all-pass"
# meta:depends="bash,grep,mktemp"
# meta:inventory.files="cli/lib/nftban/core/nftban_output.sh,cli/sbin/nftban"
# meta:inventory.binaries="bash,grep,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_NO_BANNER,NFTBAN_BANNER_MODE,NFTBAN_QUIET"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cli_no_banner_v141_test"
# meta:ta.owner="cli"
# meta:ta.module="output-banner"
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
NFTBAN_SBIN="$REPO/cli/sbin/nftban"
NFTBAN_OUTPUT="$REPO/cli/lib/nftban/core/nftban_output.sh"
export NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"
export NFTBAN_NONINTERACTIVE=1

[[ -x "$NFTBAN_SBIN" ]] || { echo "FAIL: missing $NFTBAN_SBIN" >&2; exit 1; }
[[ -f "$NFTBAN_OUTPUT" ]] || { echo "FAIL: missing $NFTBAN_OUTPUT" >&2; exit 1; }

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# Decorative chrome patterns that MUST NOT appear when banner is suppressed.
# We check substrings; any single hit is a fail.
CHROME_PATTERNS=( '+----' '╔══' '╚══' '━━━' '🐧🛡' '║  NFTBan' '| 🐧🛡' )

assert_no_chrome(){
    local label="$1" out="$2"
    local hit=""
    for p in "${CHROME_PATTERNS[@]}"; do
        if [[ "$out" == *"$p"* ]]; then
            hit="$p"; break
        fi
    done
    if [[ -n "$hit" ]]; then
        no "$label" "chrome substring present: '$hit'"
    else
        ok "$label"
    fi
}

assert_has_chrome(){
    # Inverse: at least one chrome marker must appear (sanity for the
    # banner-enabled control case).
    local label="$1" out="$2"
    local hit=""
    for p in "${CHROME_PATTERNS[@]}"; do
        if [[ "$out" == *"$p"* ]]; then
            hit="$p"; break
        fi
    done
    if [[ -n "$hit" ]]; then
        ok "$label (decorative chrome present as expected)"
    else
        no "$label" "expected chrome marker present, none found"
    fi
}

echo "=========================================================="
echo "v1.141 PR-B — E-NO-BANNER suppression discipline"
echo "=========================================================="

# Direct sourcing test: nftban_banner() under each suppression mode.
run_banner_direct() {
    # Run in a subshell so env overrides don't leak across tests.
    local env_assignments="$1"
    bash -c "
        set +e
        $env_assignments
        export NFTBAN_LIB_DIR='$NFTBAN_LIB_DIR'
        # nftban_banner_unified pulls in deep helpers (health cache, jq,
        # systemctl). We only care here whether _v141_banner_suppressed
        # short-circuits BEFORE those run. So we stub nftban_banner_unified
        # to a marker echo that we then negative-test for.
        source '$NFTBAN_OUTPUT' 2>/dev/null || true
        nftban_banner_unified() { echo 'CHROME_MARKER:╔══ frame ══╗'; }
        nftban_render_banner_simple() { echo 'CHROME_MARKER:+---- simple ----+'; }
        nftban_render_banner_full()   { echo 'CHROME_MARKER:🐧🛡 full'; }
        # Test entry: nftban_banner (universal call site)
        nftban_banner 2>&1
        echo '---'
        nftban_render_banner full 2>&1
    "
}

echo "--- T1: NFTBAN_NO_BANNER=1 → no chrome ---"
out=$(run_banner_direct 'export NFTBAN_NO_BANNER=1')
assert_no_chrome "T1 NFTBAN_NO_BANNER=1 → nftban_banner inert" "$out"

echo "--- T2: NFTBAN_QUIET=1 → no chrome ---"
out=$(run_banner_direct 'export NFTBAN_QUIET=1')
assert_no_chrome "T2 NFTBAN_QUIET=1 → nftban_banner inert" "$out"

echo "--- T3: NFTBAN_BANNER_MODE=none → no chrome ---"
out=$(run_banner_direct 'export NFTBAN_BANNER_MODE=none')
assert_no_chrome "T3 NFTBAN_BANNER_MODE=none → nftban_banner inert" "$out"

echo "--- T4: unset env → chrome present (sanity / control) ---"
out=$(run_banner_direct 'unset NFTBAN_NO_BANNER NFTBAN_QUIET NFTBAN_BANNER_MODE')
assert_has_chrome "T4 control: no suppression → chrome present" "$out"

# Dispatcher-level test: --no-banner argv flag exports NFTBAN_NO_BANNER=1.
echo "--- T5: dispatcher --no-banner argv flag is honored ---"
out=$(bash "$NFTBAN_SBIN" version --no-banner 2>&1 || true)
# version output legitimately contains the substring 'NFTBan' but should NOT
# carry decorative-frame markers when --no-banner is supplied.
hit=""
for p in '+----' '╔══' '╚══' '━━━' '🐧🛡' '║  NFTBan'; do
    if [[ "$out" == *"$p"* ]]; then hit="$p"; break; fi
done
if [[ -n "$hit" ]]; then
    no "T5 nftban version --no-banner → no chrome" "found: '$hit'"
else
    ok "T5 nftban version --no-banner → no chrome"
fi

# Dispatcher-level test: --json flag also implies banner suppression.
echo "--- T6: --json flag implies NFTBAN_NO_BANNER=1 ---"
out=$(bash "$NFTBAN_SBIN" version --json 2>&1 || true)
hit=""
for p in '+----' '╔══' '╚══' '━━━' '🐧🛡' '║  NFTBan'; do
    if [[ "$out" == *"$p"* ]]; then hit="$p"; break; fi
done
if [[ -n "$hit" ]]; then
    no "T6 nftban version --json → no chrome (implied)" "found: '$hit'"
else
    ok "T6 nftban version --json → no chrome (implied)"
fi

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "ALL PASS"
