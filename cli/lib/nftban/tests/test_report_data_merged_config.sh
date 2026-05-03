#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="test_report_data_merged_config"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-03"
# meta:description="PR-C2: verify nftban_report_data.sh reads merged base+.conf.local for module enabled flags and GeoBan countries"
# meta:input="None"
# meta:output="Test pass/fail to stdout"
# meta:depends="cli/lib/nftban/lib/nftban_report_data.sh"
# meta:inventory.files=""
# meta:inventory.binaries="grep,cut,tr,bash"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

# Test sandbox
SANDBOX="$(mktemp -d -t nftban-c2-test.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

# Load report data lib against sandbox
export NFTBAN_CONFIG_DIR="$SANDBOX"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/nftban/lib/nftban_report_data.sh"

# Test counters
PASS=0
FAIL=0

_assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        printf "  PASS %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL %s\n    expected: %q\n    actual:   %q\n" "$name" "$expected" "$actual"
        FAIL=$((FAIL + 1))
    fi
}

_reset() {
    rm -rf "$SANDBOX/conf.d"
    mkdir -p "$SANDBOX/conf.d/ddos" "$SANDBOX/conf.d/portscan" "$SANDBOX/conf.d/geoban"
}

_collect_status() {
    declare -gA status_data=()
    _collect_module_status status_data
}

# =============================================================================
# DDoS module — base / .local / override semantics
# =============================================================================

echo "[1/4] DDoS enabled-check (DDOS_ENABLED merged read)"

_reset
echo 'DDOS_ENABLED="true"'  > "$SANDBOX/conf.d/ddos/main.conf"
_collect_status
_assert_eq "DDoS base=true => Active" "Active" "${status_data[MODULE_DDOS_STATUS]}"

_reset
echo 'DDOS_ENABLED="false"' > "$SANDBOX/conf.d/ddos/main.conf"
_collect_status
_assert_eq "DDoS base=false => Disabled" "Disabled" "${status_data[MODULE_DDOS_STATUS]}"

_reset
echo 'DDOS_ENABLED="false"' > "$SANDBOX/conf.d/ddos/main.conf"
echo 'DDOS_ENABLED="true"'  > "$SANDBOX/conf.d/ddos/main.conf.local"
_collect_status
_assert_eq "DDoS base=false + .local=true => Active (override wins)" "Active" "${status_data[MODULE_DDOS_STATUS]}"

_reset
echo 'DDOS_ENABLED="true"'  > "$SANDBOX/conf.d/ddos/main.conf"
echo 'DDOS_ENABLED="false"' > "$SANDBOX/conf.d/ddos/main.conf.local"
_collect_status
_assert_eq "DDoS base=true + .local=false => Disabled (override wins)" "Disabled" "${status_data[MODULE_DDOS_STATUS]}"

# =============================================================================
# Portscan module — base / .local / override semantics
# =============================================================================

echo "[2/4] Portscan enabled-check (PORTSCAN_ENABLED merged read)"

_reset
echo 'PORTSCAN_ENABLED="true"'  > "$SANDBOX/conf.d/portscan/main.conf"
_collect_status
_assert_eq "Portscan base=true => Active" "Active" "${status_data[MODULE_PORTSCAN_STATUS]}"

_reset
echo 'PORTSCAN_ENABLED="false"' > "$SANDBOX/conf.d/portscan/main.conf"
_collect_status
_assert_eq "Portscan base=false => Disabled" "Disabled" "${status_data[MODULE_PORTSCAN_STATUS]}"

_reset
echo 'PORTSCAN_ENABLED="false"' > "$SANDBOX/conf.d/portscan/main.conf"
echo 'PORTSCAN_ENABLED="true"'  > "$SANDBOX/conf.d/portscan/main.conf.local"
_collect_status
_assert_eq "Portscan base=false + .local=true => Active (override wins)" "Active" "${status_data[MODULE_PORTSCAN_STATUS]}"

_reset
echo 'PORTSCAN_ENABLED="true"'  > "$SANDBOX/conf.d/portscan/main.conf"
echo 'PORTSCAN_ENABLED="false"' > "$SANDBOX/conf.d/portscan/main.conf.local"
_collect_status
_assert_eq "Portscan base=true + .local=false => Disabled (override wins)" "Disabled" "${status_data[MODULE_PORTSCAN_STATUS]}"

# =============================================================================
# GeoBan module — enabled-check
# =============================================================================

echo "[3/4] GeoBan enabled-check (GEOBAN_ENABLED merged read)"

_reset
echo 'GEOBAN_ENABLED="true"'  > "$SANDBOX/conf.d/geoban/main.conf"
_collect_status
_assert_eq "GeoBan base=true => Active" "Active" "${status_data[MODULE_GEOBAN_STATUS]}"

_reset
echo 'GEOBAN_ENABLED="false"' > "$SANDBOX/conf.d/geoban/main.conf"
_collect_status
_assert_eq "GeoBan base=false => Disabled" "Disabled" "${status_data[MODULE_GEOBAN_STATUS]}"

_reset
echo 'GEOBAN_ENABLED="false"' > "$SANDBOX/conf.d/geoban/main.conf"
echo 'GEOBAN_ENABLED="true"'  > "$SANDBOX/conf.d/geoban/main.conf.local"
_collect_status
_assert_eq "GeoBan base=false + .local=true => Active (override wins)" "Active" "${status_data[MODULE_GEOBAN_STATUS]}"

_reset
echo 'GEOBAN_ENABLED="true"'  > "$SANDBOX/conf.d/geoban/main.conf"
echo 'GEOBAN_ENABLED="false"' > "$SANDBOX/conf.d/geoban/main.conf.local"
_collect_status
_assert_eq "GeoBan base=true + .local=false => Disabled (override wins)" "Disabled" "${status_data[MODULE_GEOBAN_STATUS]}"

# =============================================================================
# GeoBan countries — _get_geoban_countries merged read + sentinels
# =============================================================================

echo "[4/4] GeoBan countries (GEOBAN_COUNTRIES merged read + sentinel)"

_reset
echo 'GEOBAN_COUNTRIES="US,CA"' > "$SANDBOX/conf.d/geoban/main.conf"
_assert_eq "Countries base=US,CA => 2 countries" "2 countries" "$(_get_geoban_countries)"

_reset
echo 'GEOBAN_COUNTRIES="US,CA"'        > "$SANDBOX/conf.d/geoban/main.conf"
echo 'GEOBAN_COUNTRIES="DE,FR,IT"'     > "$SANDBOX/conf.d/geoban/main.conf.local"
_assert_eq "Countries base=US,CA + .local=DE,FR,IT => 3 countries (override wins)" \
           "3 countries" "$(_get_geoban_countries)"

# Empty .local override MUST win (operator semantics — explicit empty wipes base)
_reset
echo 'GEOBAN_COUNTRIES="US,CA"' > "$SANDBOX/conf.d/geoban/main.conf"
echo 'GEOBAN_COUNTRIES=""'      > "$SANDBOX/conf.d/geoban/main.conf.local"
_assert_eq "Countries base=US,CA + .local=\"\" => 0 countries (explicit empty override)" \
           "0 countries" "$(_get_geoban_countries)"

# Missing base + missing .local must preserve "-" sentinel
_reset
_assert_eq "Countries no base + no .local => \"-\" sentinel" "-" "$(_get_geoban_countries)"

# .local-only define (no base) — should still report the count
_reset
echo 'GEOBAN_COUNTRIES="DE,FR"' > "$SANDBOX/conf.d/geoban/main.conf.local"
_assert_eq "Countries no base + .local=DE,FR => 2 countries" "2 countries" "$(_get_geoban_countries)"

# =============================================================================
# Summary
# =============================================================================

echo
echo "================================================================"
echo "  PR-C2 merged-config read: PASS=$PASS  FAIL=$FAIL"
echo "================================================================"
[[ "$FAIL" -eq 0 ]]
