#!/usr/bin/env bash
# =============================================================================
# NFTBan - GeoIP Module Static Review Tests
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Automated static-analysis checks for the GeoIP module (review 04)
#
# meta:name="04_geoip_test"
# meta:type="test"
# meta:header="GeoIP Review Tests"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="Static review tests for GeoIP module security and correctness"
# meta:inventory.files=""
# meta:inventory.binaries="grep,bash"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# Resolve repo root (script lives in tests/review/)
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# GeoIP source files under test
GEOIP_DOWNLOAD="${REPO_ROOT}/cli/lib/nftban/core/nftban_geoip_download.sh"
GEOIP_GO="${REPO_ROOT}/cli/lib/nftban/core/nftban_geoip_go.sh"
CMD_GEOIP="${REPO_ROOT}/cli/lib/nftban/cli/cmd_geoip.sh"
GEOIP_CONF="${REPO_ROOT}/etc/nftban/conf.d/geoip/main.conf"
GO_LOOKUP="${REPO_ROOT}/pkg/geoip/lookup.go"
TIMER_UNIT="${REPO_ROOT}/install/systemd/nftban-core-geoip.timer"
SERVICE_UNIT="${REPO_ROOT}/install/systemd/nftban-core-geoip.service"

# All shell GeoIP files for broad scans
GEOIP_SHELL_FILES=(
    "${GEOIP_DOWNLOAD}"
    "${GEOIP_GO}"
    "${CMD_GEOIP}"
)

# All config/template files
GEOIP_CONFIG_FILES=(
    "${GEOIP_CONF}"
)

# =============================================================================
# TEST FRAMEWORK
# =============================================================================

PASS=0
FAIL=0
SKIP=0
TOTAL=0

check() {
    # Usage: check "description" <command ...>
    # Runs command; PASS if exit 0, FAIL otherwise.
    local desc="$1"
    shift
    TOTAL=$(( TOTAL + 1 ))
    if "$@" >/dev/null 2>&1; then
        PASS=$(( PASS + 1 ))
        printf "  [PASS]  %s\n" "$desc"
    else
        FAIL=$(( FAIL + 1 ))
        printf "  [FAIL]  %s\n" "$desc"
    fi
}

check_inverse() {
    # Usage: check_inverse "description" <command ...>
    # PASS if command FAILS (exit != 0), FAIL if command succeeds.
    # Useful for "must NOT contain" patterns.
    local desc="$1"
    shift
    TOTAL=$(( TOTAL + 1 ))
    if "$@" >/dev/null 2>&1; then
        FAIL=$(( FAIL + 1 ))
        printf "  [FAIL]  %s\n" "$desc"
    else
        PASS=$(( PASS + 1 ))
        printf "  [PASS]  %s\n" "$desc"
    fi
}

skip_check() {
    local desc="$1"
    local reason="$2"
    TOTAL=$(( TOTAL + 1 ))
    SKIP=$(( SKIP + 1 ))
    printf "  [SKIP]  %s (%s)\n" "$desc" "$reason"
}

# =============================================================================
# PRE-FLIGHT: verify source files exist
# =============================================================================

preflight_ok=true
for f in "${GEOIP_SHELL_FILES[@]}" "${GEOIP_CONFIG_FILES[@]}"; do
    if [[ ! -f "$f" ]]; then
        printf "[ERROR] Required file missing: %s\n" "$f"
        preflight_ok=false
    fi
done

if [[ "$preflight_ok" != "true" ]]; then
    printf "\nPre-flight failed. Run this script from the repo root.\n"
    exit 1
fi

printf "===================================================================\n"
printf "  NFTBan GeoIP Module - Static Review Tests (04)\n"
printf "===================================================================\n"
printf "  Repo root: %s\n" "$REPO_ROOT"
printf "===================================================================\n\n"

# =============================================================================
# 1. MaxMind license key is never hardcoded or logged
# =============================================================================

printf '%s\n' "-- 1. MaxMind license key security ---------------------------------"

# 1a. No hardcoded license key values in shell sources
#     A hardcoded key looks like: LICENSE_KEY="someActualValue" where the
#     value is not empty, not a placeholder, and not a variable reference.
check_inverse \
    "No hardcoded MaxMind license key in download module" \
    grep -Pn 'LICENSE_KEY\s*=\s*"[A-Za-z0-9]{6,}"' "$GEOIP_DOWNLOAD"

check_inverse \
    "No hardcoded MaxMind license key in CLI module" \
    grep -Pn 'LICENSE_KEY\s*=\s*"[A-Za-z0-9]{6,}"' "$CMD_GEOIP"

# 1b. License key is never passed via echo/printf to log output
#     The download module should mask the key in any debug/log lines.
check_inverse \
    "License key variable not echoed directly (download module)" \
    grep -Pn 'echo.*\$\{?MAXMIND_LICENSE_KEY' "$GEOIP_DOWNLOAD"

check_inverse \
    "License key variable not echoed directly (CLI module)" \
    grep -Pn 'echo.*\$\{?MAXMIND_LICENSE_KEY' "$CMD_GEOIP"

check_inverse \
    "License key variable not in printf (download module)" \
    grep -Pn 'printf.*\$\{?MAXMIND_LICENSE_KEY' "$GEOIP_DOWNLOAD"

# 1c. License key not exposed in curl command-line arguments
#     The key should be passed via -K config file, not as a URL argument
#     visible in /proc/*/cmdline.
check \
    "Download uses curl -K (config file) to hide key from process list" \
    grep -qn '\-K\s' "$GEOIP_DOWNLOAD"

# 1d. Curl config file created with restrictive permissions (0600)
check \
    "Curl config file gets chmod 600" \
    grep -qn 'chmod 600.*curl' "$GEOIP_DOWNLOAD"

# 1e. Curl config file is cleaned up after use
check \
    "Curl config file removed after download (success path)" \
    grep -qn 'rm -f.*curl_config' "$GEOIP_DOWNLOAD"

# 1f. No hardcoded key in the Go source
if [[ -f "$GO_LOOKUP" ]]; then
    check_inverse \
        "No hardcoded license key in Go lookup module" \
        grep -Pn 'licenseKey\s*=\s*"[A-Za-z0-9]{6,}"' "$GO_LOOKUP"
else
    skip_check "No hardcoded license key in Go lookup module" "file not found"
fi

printf "\n"

# =============================================================================
# 2. All curl calls use HTTPS (no plain HTTP for DB downloads)
# =============================================================================

printf '%s\n' "-- 2. HTTPS enforcement --------------------------------------------"

# 2a. Download URL defaults to HTTPS
check \
    "Default download URL uses HTTPS" \
    grep -qn 'https://download.maxmind.com' "$GEOIP_DOWNLOAD"

# 2b. No plain http:// URLs in download module (excluding comments)
check_inverse \
    "No plain http:// URLs in download module (non-comment lines)" \
    grep -Pn '^\s*[^#]*http://' "$GEOIP_DOWNLOAD"

# 2c. curl uses --proto '=https' to enforce HTTPS-only
check \
    "curl uses --proto '=https' flag" \
    grep -qn "proto.*=https" "$GEOIP_DOWNLOAD"

# 2d. curl enforces minimum TLS version (--tlsv1.2 or higher)
check \
    "curl enforces TLS 1.2 minimum (--tlsv1.2)" \
    grep -qn 'tlsv1\.[23]' "$GEOIP_DOWNLOAD"

# 2e. No plain http:// in the CLI module (non-comment lines)
check_inverse \
    "No plain http:// URLs in CLI module (non-comment lines)" \
    grep -Pn '^\s*[^#]*http://' "$CMD_GEOIP"

# 2f. Config template uses HTTPS for any URLs
check_inverse \
    "No plain http:// URLs in config template" \
    grep -Pn '^\s*[^#]*http://' "$GEOIP_CONF"

printf "\n"

# =============================================================================
# 3. Timeout configuration exists for download operations
# =============================================================================

printf '%s\n' "-- 3. Download timeout configuration -------------------------------"

# 3a. GEOIP_TIMEOUT variable is defined or defaulted
check \
    "GEOIP_TIMEOUT variable exists with default in download module" \
    grep -qn 'GEOIP_TIMEOUT' "$GEOIP_DOWNLOAD"

# 3b. curl --connect-timeout is set
check \
    "curl uses --connect-timeout" \
    grep -qn '\-\-connect-timeout' "$GEOIP_DOWNLOAD"

# 3c. curl --max-time is set
check \
    "curl uses --max-time for total transfer timeout" \
    grep -qn '\-\-max-time' "$GEOIP_DOWNLOAD"

# 3d. Systemd service has TimeoutStartSec
if [[ -f "$SERVICE_UNIT" ]]; then
    check \
        "Systemd service has TimeoutStartSec" \
        grep -qn 'TimeoutStartSec' "$SERVICE_UNIT"
else
    skip_check "Systemd service has TimeoutStartSec" "file not found"
fi

printf "\n"

# =============================================================================
# 4. Checksum/integrity validation exists after download
# =============================================================================

printf '%s\n' "-- 4. Download integrity validation --------------------------------"

# 4a. Size validation: extracted mmdb is checked for minimum size
check \
    "Extracted database size validation exists (>100KB guard)" \
    grep -qn 'mmdb_size.*102400\|mmdb_size.*-lt' "$GEOIP_DOWNLOAD"

# 4b. Corrupt download detection: extraction failure handled
check \
    "tar extraction failure is detected and handled" \
    grep -qn 'tar.*-xzf.*||.*return\|Extraction failed' "$GEOIP_DOWNLOAD"

# 4c. Missing mmdb file after extraction is caught
check \
    "Missing .mmdb file after extraction is caught" \
    grep -qn 'Database file not found in archive' "$GEOIP_DOWNLOAD"

# 4d. Backup of existing database before overwrite
check \
    "Existing database is backed up before overwrite" \
    grep -qn 'cp.*backup\|\.backup' "$GEOIP_DOWNLOAD"

# 4e. Restrictive permissions on new database file
check \
    "New database file gets restrictive permissions (chmod 640)" \
    grep -qn 'chmod 640' "$GEOIP_DOWNLOAD"

# 4f. GEOIP_VERIFY_DOWNLOAD config option exists
check \
    "Config has GEOIP_VERIFY_DOWNLOAD option" \
    grep -qn 'GEOIP_VERIFY_DOWNLOAD' "$GEOIP_CONF"

printf "\n"

# =============================================================================
# 5. Graceful degradation when GeoIP DB is missing
# =============================================================================

printf '%s\n' "-- 5. Graceful degradation (DB missing) ----------------------------"

# 5a. Download module: _check_database handles missing DB with WARNING
check \
    "Download module warns when database not found" \
    grep -qn 'WARNING.*GeoIP database not found\|database not found' "$GEOIP_DOWNLOAD"

# 5b. Go module: returns empty strings on database error (not panic)
if [[ -f "$GO_LOOKUP" ]]; then
    check \
        "Go lookup returns empty on database error (no panic)" \
        grep -qn 'return ""' "$GO_LOOKUP"
else
    skip_check "Go lookup returns empty on database error" "file not found"
fi

# 5c. Go module: returns empty on invalid IP (not panic)
if [[ -f "$GO_LOOKUP" ]]; then
    check \
        "Go lookup returns empty on invalid IP (nil check)" \
        grep -qn 'parsedIP == nil' "$GO_LOOKUP"
else
    skip_check "Go lookup returns empty on invalid IP" "file not found"
fi

# 5d. Shell wrapper: checks binary availability before calling
check \
    "Go wrapper checks binary existence before calling" \
    grep -qn 'if.*!.*-x.*NFTBAN_CORE_BIN\|not found' "$GEOIP_GO"

# 5e. CLI module: error handling when nftban-core is missing
check \
    "CLI module handles missing nftban-core binary gracefully" \
    grep -qn 'nftban-core binary not found\|nftban-core.*not.*found' "$CMD_GEOIP"

# 5f. Shell wrapper: lookup returns fallback on failure
check \
    "Shell wrapper returns fallback value on lookup failure" \
    grep -qn 'Unknown\|??' "$GEOIP_GO"

# 5g. Download module: license key check returns clear error
check \
    "License key check gives clear instructions when missing" \
    grep -qn 'MaxMind license key not configured' "$GEOIP_DOWNLOAD"

printf "\n"

# =============================================================================
# 6. Timer unit exists for scheduled updates
# =============================================================================

printf '%s\n' "-- 6. Systemd timer for scheduled updates --------------------------"

# 6a. Timer unit file exists
if [[ -f "$TIMER_UNIT" ]]; then
    check \
        "GeoIP timer unit file exists" \
        test -f "$TIMER_UNIT"

    # 6b. Timer has OnCalendar schedule (weekly)
    check \
        "Timer has OnCalendar schedule" \
        grep -qn 'OnCalendar=' "$TIMER_UNIT"

    # 6c. Timer has Persistent=true (catches up after downtime)
    check \
        "Timer has Persistent=true (runs after missed schedule)" \
        grep -qn 'Persistent=true' "$TIMER_UNIT"

    # 6d. Timer has RandomizedDelaySec (avoid thundering herd)
    check \
        "Timer has RandomizedDelaySec (jitter)" \
        grep -qn 'RandomizedDelaySec' "$TIMER_UNIT"

    # 6e. Timer is in WantedBy=timers.target
    check \
        "Timer installs into timers.target" \
        grep -qn 'WantedBy=timers.target' "$TIMER_UNIT"
else
    skip_check "GeoIP timer unit file exists" "file not found"
    skip_check "Timer has OnCalendar schedule" "timer file not found"
    skip_check "Timer has Persistent=true" "timer file not found"
    skip_check "Timer has RandomizedDelaySec" "timer file not found"
    skip_check "Timer installs into timers.target" "timer file not found"
fi

# 6f. Service unit file exists
if [[ -f "$SERVICE_UNIT" ]]; then
    check \
        "GeoIP service unit file exists" \
        test -f "$SERVICE_UNIT"

    # 6g. Service is Type=oneshot
    check \
        "Service is Type=oneshot" \
        grep -qn 'Type=oneshot' "$SERVICE_UNIT"

    # 6h. Service has security hardening
    check \
        "Service has NoNewPrivileges=true" \
        grep -qn 'NoNewPrivileges=true' "$SERVICE_UNIT"

    check \
        "Service has ProtectSystem=strict" \
        grep -qn 'ProtectSystem=strict' "$SERVICE_UNIT"

    # 6i. Service has resource limits
    check \
        "Service has MemoryMax limit" \
        grep -qn 'MemoryMax=' "$SERVICE_UNIT"
else
    skip_check "GeoIP service unit file exists" "file not found"
    skip_check "Service is Type=oneshot" "service file not found"
    skip_check "Service has NoNewPrivileges=true" "service file not found"
    skip_check "Service has ProtectSystem=strict" "service file not found"
    skip_check "Service has MemoryMax limit" "service file not found"
fi

printf "\n"

# =============================================================================
# 7. No secrets in config template files
# =============================================================================

printf '%s\n' "-- 7. No secrets in config templates -------------------------------"

# 7a. Config template does not contain actual license key values
check_inverse \
    "Config template has no hardcoded license key value" \
    grep -Pn '^\s*GEOIP_MAXMIND_KEY\s*=\s*"[A-Za-z0-9]{6,}"' "$GEOIP_CONF"

# 7b. Config template key field is commented out or empty
check \
    "Config template MaxMind key is commented out" \
    grep -qn '^#.*GEOIP_MAXMIND_KEY' "$GEOIP_CONF"

# 7c. No API tokens or passwords in config template
check_inverse \
    "No API tokens in config template" \
    grep -Pni '^\s*[^#].*(api_token|api_key|password|secret)\s*=\s*"[A-Za-z0-9]{6,}"' "$GEOIP_CONF"

# 7d. Config template directs users to main.conf.local for customizations
check \
    "Config template references main.conf.local for overrides" \
    grep -qn 'main.conf.local' "$GEOIP_CONF"

# 7e. CLI set-key command sets 600 permissions on local config
check \
    "CLI set-key sets chmod 600 on local config file" \
    grep -qn 'chmod 600.*config_local' "$CMD_GEOIP"

# 7f. No actual MaxMind key values anywhere in all GeoIP shell files
for f in "${GEOIP_SHELL_FILES[@]}"; do
    fname="$(basename "$f")"
    check_inverse \
        "No hardcoded API key in ${fname}" \
        grep -Pn '[A-Za-z0-9]{16,}' <(grep -n 'LICENSE_KEY\s*=' "$f" | grep -v ':-\|:-}\|""' | grep -v '^#' | grep -v 'config_local\|conf\.local' || true)
done

# 7g. Download module masks key in debug output
check \
    "Download module masks key in debug output (key masked)" \
    grep -qn 'key masked' "$GEOIP_DOWNLOAD"

printf "\n"

# =============================================================================
# SUMMARY
# =============================================================================

printf "===================================================================\n"
printf "  GeoIP Review Test Summary\n"
printf "===================================================================\n"
printf "  Total:   %d\n" "$TOTAL"
printf "  Passed:  %d\n" "$PASS"
printf "  Failed:  %d\n" "$FAIL"
printf "  Skipped: %d\n" "$SKIP"
printf "===================================================================\n"

if [[ "$FAIL" -gt 0 ]]; then
    printf "\n  RESULT: FAIL (%d test(s) failed)\n\n" "$FAIL"
    exit 1
else
    printf "\n  RESULT: PASS (all tests passed)\n\n"
    exit 0
fi
