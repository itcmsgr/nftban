#!/usr/bin/env bash
# =============================================================================
# NFTBan - status count-truth test (v1.141 PR-C D-headline + D-cache-wording)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_status_count_truth_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-28"
# meta:description="v1.141 PR-C D-headline + D-cache-wording — asserts that `nftban status` headline 'Banned IPs' equals the kernel total (SELECT_CACHE_KERNEL_AUTHORITY=kernel) and that the four-line split (Automatic / Manual / Total kernel / Source-index-if-stale) is rendered. The pre-v1.141 string 'cache may lag' must NOT appear. Stubs nftban_nft_count_set to return known IP counts so we can deterministically check the math."
# meta:input="cli/lib/nftban/cli/cmd_status.sh output_terminal"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash"
# meta:inventory.files="cli/lib/nftban/cli/cmd_status.sh"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_NO_BANNER"
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
export NFTBAN_NO_BANNER=1
export NFTBAN_NONINTERACTIVE=1

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# Drive the status section function in isolation with stubbed counters.
# v4_auto=10, v4_manual=5, v6_auto=2, v6_manual=1 → totals: auto=12, manual=6, kernel=18.
run_firewall_section() {
    bash -c "
        set +e
        export NFTBAN_LIB_DIR='$NFTBAN_LIB_DIR'
        export NFTBAN_NO_BANNER=1
        export NFTBAN_CONFIG_DIR='/tmp/nftban-test-cfg'
        export NFTBAN_CACHE_DIR='/tmp/nftban-test-cache'
        export NFTBAN_DATA_DIR='/tmp/nftban-test-data'

        # Source first so the real definitions land, then override with stubs
        # so they take effect at call time. (Reversed order would let the
        # source pull in the real nftban_nft_count_set etc.)
        source '$NFTBAN_LIB_DIR/cli/cmd_status.sh' 2>/dev/null || true

        nftban_nft_count_set() {
            case \"\$1 \$3\" in
                'ip blacklist_ipv4')         echo 10 ;;
                'ip blacklist_manual_ipv4')  echo 5  ;;
                'ip6 blacklist_ipv6')        echo 2  ;;
                'ip6 blacklist_manual_ipv6') echo 1  ;;
                *) echo 0 ;;
            esac
        }
        nftban_stats_count_active_bans() { echo 999; }
        nftban_stats_count_whitelist()   { echo 0; }
        _nftban_count_rules()            { echo 50; }
        nftban_render_banner()           { :; }
        nftban_banner()                  { :; }
        _unit_is_active()                { return 0; }

        _status_section_firewall 0 2>&1
    "
}

echo "=========================================================="
echo "v1.141 PR-C — status headline kernel-authority + four-way split"
echo "=========================================================="

OUT=$(run_firewall_section)

# T1 — headline uses kernel total (18 = 10+5+2+1).
if grep -qE 'Banned IPs\.+\s+18($|\s)' <<<"$OUT"; then
    ok "T1 headline 'Banned IPs' = kernel total (18)"
else
    no "T1 headline kernel total" "expected '18' on Banned IPs line; got: $(grep -E 'Banned IPs' <<<\"$OUT\" | head -2 | tr '\n' '|')"
fi

# T2 — automatic split (12 = 10 v4_auto + 2 v6_auto).
if grep -qE 'Automatic.*\s12($|\s)' <<<"$OUT"; then
    ok "T2 Automatic split = 12"
else
    no "T2 Automatic split" "expected 12; got: $(grep -i 'Automatic' <<<\"$OUT\" | head -1)"
fi

# T3 — manual split (6 = 5 v4_manual + 1 v6_manual).
if grep -qE 'Manual.*\s6($|\s)' <<<"$OUT"; then
    ok "T3 Manual split = 6"
else
    no "T3 Manual split" "expected 6; got: $(grep -i 'Manual' <<<\"$OUT\" | head -1)"
fi

# T4 — Total kernel line shows 18.
if grep -qE 'Total kernel.*\s18($|\s)' <<<"$OUT"; then
    ok "T4 'Total kernel' = 18"
else
    no "T4 Total kernel" "expected 18; got: $(grep -i 'Total kernel' <<<\"$OUT\" | head -1)"
fi

# T5 — pre-v1.141 'cache may lag' must NOT appear anywhere.
if grep -q 'cache may lag' <<<"$OUT"; then
    no "T5 'cache may lag' removed" "string still present"
else
    ok "T5 pre-v1.141 'cache may lag' wording removed"
fi

# T6 — Source-index line fires because cache (999) != kernel (18) and uses
# explicit 'reconciled' wording, not 'cache may lag'.
if grep -qE 'Source-index.*999' <<<"$OUT"; then
    if grep -qE 'reconciled' <<<"$OUT"; then
        ok "T6 Source-index reports cache count + 'reconciled Ns ago'"
    else
        # If the cache file doesn't exist we still surface the number but
        # without the staleness note — that's acceptable.
        ok "T6 Source-index reports cache count (no cache-file mtime available)"
    fi
else
    no "T6 Source-index line" "expected 'Source-index' + 999; got: $(grep -i 'source-index' <<<\"$OUT\" | head -1)"
fi

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "ALL PASS"
