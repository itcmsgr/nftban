#!/usr/bin/env bash
# =============================================================================
# NFTBan - --json clean-output (valid JSON from byte 1) test (v1.141 PR-B J-*)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_json_clean_output_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-28"
# meta:description="v1.141 PR-B J-FEED + J-DDOS + J-PORT — asserts that `nftban feeds list --json`, `nftban ddos status --json`, `nftban portscan status --json` emit valid JSON starting at byte 1 (no banner/heading text prefix) and that the JSON parses cleanly via jq. Pre-v1.141 each of these commands prefixed the JSON with the unified banner + decorative ━━━ heading bars (cruel-judge §3 E_J6/E_J7). Hermetic — sources the cmd_* functions directly into a bash subshell with stub config / stub upstream helpers."
# meta:input="cli/lib/nftban/core/nftban_ddos.sh, cli/lib/nftban/core/nftban_portscan.sh, cli/lib/nftban/cli/cmd_feeds.sh"
# meta:output="Pass/fail assertions per --json surface; exit 0 on all-pass"
# meta:depends="bash,jq"
# meta:inventory.files="cli/lib/nftban/core/nftban_ddos.sh,cli/lib/nftban/core/nftban_portscan.sh,cli/lib/nftban/cli/cmd_feeds.sh,cli/sbin/nftban"
# meta:inventory.binaries="bash,jq"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_NO_BANNER"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cli_json_clean_output_test"
# meta:ta.owner="cli"
# meta:ta.module="json-output"
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
export NFTBAN_NONINTERACTIVE=1

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# Parse out and validate: rc, first byte is { or [, jq parses successfully.
assert_clean_json() {
    local label="$1" out="$2" rc="$3"
    if (( rc != 0 )); then
        no "$label" "rc=$rc (expected 0)"
        return
    fi
    # First non-whitespace char must be { or [.
    local trimmed="${out#"${out%%[![:space:]]*}"}"
    local first="${trimmed:0:1}"
    if [[ "$first" != "{" && "$first" != "[" ]]; then
        # show first 200 chars so we see what leaked
        no "$label" "first non-space char is '$first', not '{' or '['; head: ${trimmed:0:200}"
        return
    fi
    if ! echo "$trimmed" | jq -e '.' >/dev/null 2>&1; then
        no "$label" "jq parse failed on output: ${trimmed:0:200}"
        return
    fi
    ok "$label"
}

echo "=========================================================="
echo "v1.141 PR-B — --json clean-output (valid JSON from byte 1)"
echo "=========================================================="

# --- J-DDOS: source nftban_ddos.sh, call nftban_ddos_status "true" ---
echo "--- T1: nftban_ddos_status \"true\" (J-DDOS) ---"
out=$(bash -c "
    set +e
    export NFTBAN_LIB_DIR='$NFTBAN_LIB_DIR'
    export NFTBAN_NO_BANNER=1
    # Stub config loader + mode detector + banner so we don't touch the host.
    _nftban_ddos_load_config() { :; }
    _nftban_ddos_detect_mode() { echo 'classic'; }
    _nftban_ddos_banner() { :; }
    nftban_ddos_suricata_binary_exists() { return 1; }
    nftban_ddos_suricata_service_running() { return 1; }
    nftban_ddos_suricata_eve_active() { return 1; }
    nftban_ddos_suricata_is_available() { return 1; }
    DDOS_ENABLED=true
    DDOS_MODE=classic
    source '$NFTBAN_LIB_DIR/core/nftban_ddos.sh' 2>/dev/null || true
    nftban_ddos_status true
")
rc=$?
assert_clean_json "T1 nftban_ddos_status json_mode=true" "$out" "$rc"

# --- J-PORT: source nftban_portscan.sh, call nftban_portscan_status "true" ---
echo "--- T2: nftban_portscan_status \"true\" (J-PORT) ---"
out=$(bash -c "
    set +e
    export NFTBAN_LIB_DIR='$NFTBAN_LIB_DIR'
    export NFTBAN_CONFIG_DIR='/tmp/nftban-test-cfg'
    export NFTBAN_DATA_DIR='/tmp/nftban-test-data'
    export NFTBAN_LOG_DIR='/tmp/nftban-test-log'
    export NFTBAN_CACHE_DIR='/tmp/nftban-test-cache'
    export NFTBAN_NO_BANNER=1
    nftban_portscan_load_config() { :; }
    _nftban_portscan_detect_mode() { echo 'classic'; }
    _nftban_portscan_suricata_is_available() { return 1; }
    PORTSCAN_ENABLED=true
    PORTSCAN_MODE=classic
    PORTSCAN_AUTO_BAN=true
    source '$NFTBAN_LIB_DIR/core/nftban_portscan.sh' 2>/dev/null || true
    nftban_portscan_status true
")
rc=$?
assert_clean_json "T2 nftban_portscan_status json_mode=true" "$out" "$rc"

# --- J-FEED: nftban_feeds_list with --json (calls nftban_feeds_list "--json") ---
echo "--- T3: nftban_feeds_list --json (J-FEED, F-FEEDS-JSON) ---"
out=$(bash -c "
    set +e
    export NFTBAN_LIB_DIR='$NFTBAN_LIB_DIR'
    export NFTBAN_NO_BANNER=1
    # Stub the discovery helpers so we exercise the jq path.
    nftban_feeds_get_categories()         { echo 'ssh web'; }
    nftban_feeds_get_by_category()        { case \"\$1\" in ssh) echo 'BLOCKLISTDE_SSH';; web) echo 'BLOCKLISTDE_APACHE';; esac; }
    nftban_feeds_get_property()           { case \"\$2\" in
                                              ENABLED)     echo 'true';;
                                              DESCRIPTION) echo 'sample \"feed\" desc with quotes';;
                                              INTERVAL)    echo 'DAILY';;
                                            esac; }
    nftban_feeds_discover_all()           { echo 'BLOCKLISTDE_SSH BLOCKLISTDE_APACHE'; }
    nftban_feeds_get_stats()              { echo '0/2 feeds enabled | 0 total IPs'; }
    nftban_banner()                       { :; }
    json_output()                         { printf '%s' \"\$2\"; }
    source '$NFTBAN_LIB_DIR/cli/cmd_feeds.sh' 2>/dev/null || true
    nftban_feeds_list --json
")
rc=$?
assert_clean_json "T3 nftban_feeds_list --json" "$out" "$rc"

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "ALL PASS"
