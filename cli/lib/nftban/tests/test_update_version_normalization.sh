#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.121 - Tests for update version-format normalization
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="test_update_version_normalization"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-19"
# meta:description="V121 Part B tests for the version-format normalization in cli/lib/nftban/cli/cmd_update_methods.sh _get_package_url. Asserts that the regex check after the V121 v/V strip accepts 1.120.0, v1.120.0, V1.120.0, 1.120.0-rc1; rejects 1.120, 1.120.0.0, latest, empty, and embedded-v forms. Closes the discoverability gap surfaced at lab2 V120 upgrade where the first attempt with v1.120.0 was rejected."
# meta:input="None"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files=""
# meta:inventory.binaries="bash"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

PASS=0
FAIL=0
FAILED_TESTS=()

# -----------------------------------------------------------------------------
# Helper: V121 version normalization (mirrors cmd_update_methods.sh
# _get_package_url validation logic). Returns:
#   "OK <normalized>"  — passes regex after v/V strip
#   "REJECT"           — fails regex
# -----------------------------------------------------------------------------
v121_version_check() {
    local input="$1"
    local version="${input#[vV]}"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9._-]+)?$ ]]; then
        echo "REJECT"
        return 1
    fi
    echo "OK ${version}"
    return 0
}

assert_eq() {
    local actual="$1" expected="$2" name="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf "  [PASS] %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s (expected '%s', got '%s')\n" "$name" "$expected" "$actual"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
}

echo "================================================="
echo "V121 update version-format normalization tests"
echo "================================================="

# Accepted forms
echo
echo "[ACCEPT] Canonical N.N.N forms"
assert_eq "$(v121_version_check 1.120.0)"        "OK 1.120.0"        "A1 1.120.0 accepted"
assert_eq "$(v121_version_check 1.119.0)"        "OK 1.119.0"        "A2 1.119.0 accepted"
assert_eq "$(v121_version_check 1.115.0)"        "OK 1.115.0"        "A3 1.115.0 accepted"
assert_eq "$(v121_version_check 10.20.30)"       "OK 10.20.30"       "A4 multi-digit accepted"

echo
echo "[ACCEPT] V121 leading v/V stripped"
assert_eq "$(v121_version_check v1.120.0)"       "OK 1.120.0"        "A5 v1.120.0 → 1.120.0"
assert_eq "$(v121_version_check V1.120.0)"       "OK 1.120.0"        "A6 V1.120.0 → 1.120.0"
assert_eq "$(v121_version_check v1.119.0-rc1)"   "OK 1.119.0-rc1"    "A7 v1.119.0-rc1 (v + pre-release suffix)"

echo
echo "[ACCEPT] Pre-release suffix forms"
assert_eq "$(v121_version_check 1.120.0-rc1)"    "OK 1.120.0-rc1"    "A8 1.120.0-rc1 accepted"
assert_eq "$(v121_version_check 1.120.0-beta.2)" "OK 1.120.0-beta.2" "A9 1.120.0-beta.2 accepted"
assert_eq "$(v121_version_check 1.120.0-alpha_3)" "OK 1.120.0-alpha_3" "A10 1.120.0-alpha_3 (underscore in suffix) accepted"

# Rejected forms
echo
echo "[REJECT] Malformed versions"
assert_eq "$(v121_version_check 1.120 || true)"           "REJECT"  "R1 1.120 rejected (only 2 parts)"
assert_eq "$(v121_version_check 1.120.0.0 || true)"       "REJECT"  "R2 1.120.0.0 rejected (4 parts)"
assert_eq "$(v121_version_check latest || true)"          "REJECT"  "R3 'latest' rejected"
assert_eq "$(v121_version_check '' || true)"              "REJECT"  "R4 empty rejected"
assert_eq "$(v121_version_check 'a.b.c' || true)"         "REJECT"  "R5 non-numeric rejected"
assert_eq "$(v121_version_check '1.120.0; rm -rf /' || true)" "REJECT" "R6 command injection rejected"

echo
echo "[REJECT] Embedded v in middle/end (only LEADING v/V stripped)"
assert_eq "$(v121_version_check '1.v120.0' || true)"      "REJECT"  "R7 embedded v in middle rejected"
assert_eq "$(v121_version_check 'vv1.120.0' || true)"     "REJECT"  "R8 double-leading v rejected"
assert_eq "$(v121_version_check '1.120.0v' || true)"      "REJECT"  "R9 trailing v rejected"

echo
echo "[REJECT] Whitespace contamination"
assert_eq "$(v121_version_check ' 1.120.0' || true)"      "REJECT"  "R10 leading space rejected"
assert_eq "$(v121_version_check '1.120.0 ' || true)"      "REJECT"  "R11 trailing space rejected"

echo
echo "================================================="
echo "Results: PASS=$PASS  FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi
echo "All tests passed."
exit 0
