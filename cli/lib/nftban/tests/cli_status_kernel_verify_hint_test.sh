#!/usr/bin/env bash
# =============================================================================
# NFTBan - status kernel-verify-hint test (v1.141 PR-C D-verify-hint)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_status_kernel_verify_hint_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-28"
# meta:description="v1.141 PR-C D-verify-hint — asserts that `nftban status` (non-quiet, bans>0) prints the four copy-pasteable `nft list set` commands so an operator can independently verify enforcement. Honors CLAUDE.md project rule 'Kernel verification (nft list set) proves enforcement, not CLI output alone'. The set names are the canonical v2.1 schema names: blacklist_ipv4, blacklist_manual_ipv4, blacklist_ipv6, blacklist_manual_ipv6."
# meta:input="cli/lib/nftban/cli/cmd_status.sh output_terminal"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash"
# meta:inventory.files="cli/lib/nftban/cli/cmd_status.sh,cli/lib/nftban/lib/nft_schema.sh"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_NO_BANNER"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cli_status_kernel_verify_hint_test"
# meta:ta.owner="cli"
# meta:ta.module="status"
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
export NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"
export NFTBAN_NO_BANNER=1
export NFTBAN_NONINTERACTIVE=1

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# Drive _status_section_firewall with ban_count > 0 so the verify-hint block fires.
run_section() {
    local v4_auto="$1" v4_manual="$2" v6_auto="$3" v6_manual="$4"
    bash -c "
        set +e
        export NFTBAN_LIB_DIR='$NFTBAN_LIB_DIR'
        export NFTBAN_NO_BANNER=1
        export NFTBAN_CONFIG_DIR='/tmp/nftban-test-cfg'
        source '$NFTBAN_LIB_DIR/cli/cmd_status.sh' 2>/dev/null || true
        nftban_nft_count_set() {
            case \"\$1 \$3\" in
                'ip blacklist_ipv4')         echo $v4_auto ;;
                'ip blacklist_manual_ipv4')  echo $v4_manual ;;
                'ip6 blacklist_ipv6')        echo $v6_auto ;;
                'ip6 blacklist_manual_ipv6') echo $v6_manual ;;
                *) echo 0 ;;
            esac
        }
        nftban_stats_count_active_bans() { echo 0; }
        nftban_stats_count_whitelist()   { echo 0; }
        _nftban_count_rules()            { echo 0; }
        nftban_render_banner()           { :; }
        nftban_banner()                  { :; }
        _unit_is_active()                { return 0; }
        _status_section_firewall 0 2>&1
    "
}

echo "=========================================================="
echo "v1.141 PR-C — D-verify-hint kernel verification block"
echo "=========================================================="

echo "--- T1: bans > 0 (one v4 manual) → verify block prints ---"
OUT=$(run_section 0 1 0 0)
for cmd in \
    "nft list set ip nftban blacklist_ipv4" \
    "nft list set ip nftban blacklist_manual_ipv4" \
    "nft list set ip6 nftban blacklist_ipv6" \
    "nft list set ip6 nftban blacklist_manual_ipv6"; do
    if grep -qF "$cmd" <<<"$OUT"; then
        ok "T1 contains '$cmd'"
    else
        no "T1 missing '$cmd'" "block did not include this command"
    fi
done

if grep -qE "Verify kernel" <<<"$OUT"; then
    ok "T1 'Verify kernel' header present"
else
    no "T1 'Verify kernel' header" "header missing"
fi

echo "--- T2: bans == 0 → verify block must NOT print ---"
OUT=$(run_section 0 0 0 0)
if grep -qE "Verify kernel" <<<"$OUT"; then
    no "T2 verify block suppressed when bans=0" "block fired but ban_count==0"
else
    ok "T2 verify block correctly suppressed when bans=0"
fi
if grep -qF "nft list set ip nftban blacklist_ipv4" <<<"$OUT"; then
    no "T2 no 'nft list set' lines when bans=0" "found at least one nft list set line"
else
    ok "T2 no 'nft list set' lines emitted when bans=0"
fi

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "ALL PASS"
