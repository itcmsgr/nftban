#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.19.1 - Review 07: RBL Module Static Analysis Tests
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Automated static checks for RBL module code review
#
# meta:name="07_rbl_test"
# meta:type="test"
# meta:header="RBL Module Review Tests"
# meta:version="1.19.1"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="Static analysis tests for RBL module (review 07)"
# meta:created_date="2026-02-27"
# meta:updated_date="2026-02-27"
#
# meta:inventory.files="cli/lib/nftban/core/nftban_rbl.sh, cli/lib/nftban/cli/cmd_rbl.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# REPO ROOT DETECTION
# =============================================================================

# Determine repo root: allow override via REPO_ROOT, then try git, then fallback
if [[ -n "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="${REPO_ROOT}"
elif command -v git &>/dev/null && git rev-parse --show-toplevel &>/dev/null 2>&1; then
    REPO_ROOT="$(git rev-parse --show-toplevel)"
else
    # Fallback: script is at tests/review/07_rbl_test.sh
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi

# Verify key source files exist
RBL_CORE="${REPO_ROOT}/cli/lib/nftban/core/nftban_rbl.sh"
RBL_CLI="${REPO_ROOT}/cli/lib/nftban/cli/cmd_rbl.sh"
RBL_PREREQ="${REPO_ROOT}/cli/lib/nftban/lib/nftban_prereq.sh"
RBL_MAIN_CONF="${REPO_ROOT}/etc/nftban/conf.d/rbl/main.conf"
RBL_TIMER="${REPO_ROOT}/install/systemd/nftban-rbl-check.timer"
RBL_SERVICE="${REPO_ROOT}/install/systemd/nftban-rbl-check.service"

for f in "$RBL_CORE" "$RBL_CLI" "$RBL_PREREQ"; do
    if [[ ! -f "$f" ]]; then
        echo "FATAL: Required source file not found: $f" >&2
        exit 2
    fi
done

# =============================================================================
# TEST FRAMEWORK
# =============================================================================

PASS=0
FAIL=0
TESTS_RUN=0

check() {
    # Usage: check "description" <command that returns 0 on success>
    local description="$1"
    shift

    TESTS_RUN=$((TESTS_RUN + 1))

    if "$@" >/dev/null 2>&1; then
        PASS=$((PASS + 1))
        printf "  PASS  %s\n" "$description"
    else
        FAIL=$((FAIL + 1))
        printf "  FAIL  %s\n" "$description"
    fi
}

# =============================================================================
# TEST: RBL is disabled by default
# =============================================================================
# The core module must default NFTBAN_RBL_ENABLED to NO so that a fresh
# install does not perform unsolicited DNS queries.  The shell default
# assignment (: "${NFTBAN_RBL_ENABLED:=NO}") is the authoritative gate.
# =============================================================================

echo ""
echo "=== 1. RBL disabled by default ==="

check "Core module defaults NFTBAN_RBL_ENABLED to NO" \
    grep -qP '^\s*:\s+"\$\{NFTBAN_RBL_ENABLED:=NO\}"' "$RBL_CORE"

check "Default assignment uses :=NO (not YES)" \
    bash -c '! grep -qP "^\s*:\s+\"\\\$\{NFTBAN_RBL_ENABLED:=YES\}\"" "'"$RBL_CORE"'"'

# =============================================================================
# TEST: DNS lookup tool prerequisite check exists
# =============================================================================
# Before enabling RBL, a prerequisite check must verify that at least one
# DNS lookup tool (host, dig, or nslookup) is available on the system.
# =============================================================================

echo ""
echo "=== 2. DNS lookup tool prerequisite check ==="

check "nftban_prereq_check_rbl function exists in prereq library" \
    grep -q 'nftban_prereq_check_rbl()' "$RBL_PREREQ"

check "Prereq checks for host/dig/nslookup" \
    grep -qP 'host\s+dig|dig.*host|nslookup' "$RBL_PREREQ"

check "CLI enable calls prereq check before enabling" \
    grep -q 'nftban_prereq_check_rbl' "$RBL_CLI"

check "CLI enable gates on prereq_satisfied result" \
    grep -q 'nftban_prereq_satisfied' "$RBL_CLI"

check "Core declares dependency on dig and host in meta:depends" \
    grep -qP 'meta:depends=.*dig.*host|meta:depends=.*host.*dig' "$RBL_CORE"

check "Core inventory lists dig and host as required binaries" \
    grep -qP 'meta:inventory\.binaries=.*dig.*host|meta:inventory\.binaries=.*host.*dig' "$RBL_CORE"

# =============================================================================
# TEST: Rate limiting for RBL queries
# =============================================================================
# RBL queries must be rate-limited to prevent abuse (e.g., Spamhaus will
# block IPs that send too many queries).  The code must enforce a maximum
# number of queries per run.
# =============================================================================

echo ""
echo "=== 3. Rate limiting for RBL queries ==="

check "Rate limit counter _NFTBAN_RBL_QUERY_COUNT is incremented" \
    grep -q '_NFTBAN_RBL_QUERY_COUNT' "$RBL_CORE"

check "MAX_QUERIES_PER_RUN configurable threshold exists" \
    grep -q 'NFTBAN_RBL_MAX_QUERIES_PER_RUN' "$RBL_CORE"

check "Rate limit returns RATE_LIMITED when threshold exceeded" \
    grep -q 'RATE_LIMITED' "$RBL_CORE"

check "Rate limit check is in nftban_rbl_dns_lookup function" \
    bash -c 'sed -n "/^nftban_rbl_dns_lookup()/,/^[^ ]/p" "'"$RBL_CORE"'" | grep -q "RATE_LIMITED"'

check "Default max queries is 500" \
    grep -qP 'NFTBAN_RBL_MAX_QUERIES_PER_RUN:-500' "$RBL_CORE"

# =============================================================================
# TEST: Alert pipeline is async (does not block ban engine)
# =============================================================================
# Alerts (email) must never block the main ban path.  The code must:
# - Use background delivery or a fire-and-forget pattern
# - Handle mail failures gracefully (|| true or stderr warning)
# - Use alert throttling to prevent duplicate floods
# =============================================================================

echo ""
echo "=== 4. Alert pipeline is async ==="

check "Alert send uses nftban_mail_send (unified mechanism)" \
    grep -q 'nftban_mail_send' "$RBL_CORE"

check "Mail failure is caught and does not abort (|| with warning)" \
    grep -qP 'nftban_mail_send.*\|\|.*\\' "$RBL_CORE"

check "Alert throttle library is loaded" \
    grep -q 'nftban_alert_throttle.sh' "$RBL_CORE"

check "nftban_should_alert is called before sending alert" \
    grep -q 'nftban_should_alert' "$RBL_CORE"

check "Alert throttle has a 12-hour window (43200 seconds)" \
    grep -q '43200' "$RBL_CORE"

check "New-listing check gates alerts (state transition detection)" \
    grep -q 'nftban_rbl_check_new_listing' "$RBL_CORE"

check "RBL check service runs as Type=oneshot (non-blocking)" \
    grep -q 'Type=oneshot' "$RBL_SERVICE"

# =============================================================================
# TEST: Exception/whitelist handling
# =============================================================================
# The module must support exceptions at two levels:
# - RBL provider level: custom.conf with disablerbl:/enablerbl: directives
# - IP level: watchlist.conf with per-IP management (add/remove/list)
# Both must support persistence across restarts and package upgrades.
# =============================================================================

echo ""
echo "=== 5. Exception/whitelist handling ==="

check "custom.conf supports disablerbl: directive" \
    grep -q 'disablerbl:' "$RBL_CORE"

check "custom.conf supports enablerbl: directive" \
    grep -q 'enablerbl:' "$RBL_CORE"

check "Disabled RBLs are filtered out from provider list" \
    bash -c 'sed -n "/^nftban_rbl_load_providers()/,/^[^ ]/p" "'"$RBL_CORE"'" | grep -q "is_disabled"'

check "Watchlist add function exists" \
    grep -q 'nftban_rbl_watchlist_add()' "$RBL_CORE"

check "Watchlist remove function exists" \
    grep -q 'nftban_rbl_watchlist_remove()' "$RBL_CORE"

check "Watchlist is persisted to file (NFTBAN_RBL_WATCHLIST_FILE)" \
    grep -q 'NFTBAN_RBL_WATCHLIST_FILE' "$RBL_CORE"

check "Watchlist prevents duplicate entries" \
    bash -c 'sed -n "/^nftban_rbl_watchlist_add()/,/^[^ ]/p" "'"$RBL_CORE"'" | grep -q "already in watchlist"'

check "Critical IPs use .conf.local override architecture" \
    grep -q 'main.conf.local' "$RBL_CLI"

check "Critical IP changes never modify package defaults (writes to .conf.local)" \
    bash -c 'sed -n "/^nftban_cmd_rbl_critical()/,/^[^ ]/p" "'"$RBL_CLI"'" | grep -q "local_conf"'

# =============================================================================
# TEST: Enable/disable persists to config
# =============================================================================
# The enable/disable commands must write NFTBAN_RBL_ENABLED to
# main.conf.local (user overrides) so the setting survives package
# upgrades.  Must never modify the package-shipped main.conf.
# =============================================================================

echo ""
echo "=== 6. Enable/disable persists to config ==="

check "Enable writes NFTBAN_RBL_ENABLED=YES to main.conf.local" \
    bash -c 'sed -n "/^nftban_cmd_rbl_enable()/,/^nftban_cmd_rbl_[a-z]/p" "'"$RBL_CLI"'" | grep -q "NFTBAN_RBL_ENABLED=.*YES"'

check "Disable writes NFTBAN_RBL_ENABLED=NO to main.conf.local" \
    bash -c 'sed -n "/^nftban_cmd_rbl_disable()/,/^nftban_cmd_rbl_[a-z]/p" "'"$RBL_CLI"'" | grep -q "NFTBAN_RBL_ENABLED=.*NO"'

check "Enable targets conf.d/rbl/main.conf.local (not main.conf)" \
    bash -c 'sed -n "/^nftban_cmd_rbl_enable()/,/^nftban_cmd_rbl_[a-z]/p" "'"$RBL_CLI"'" | grep -q "main.conf.local"'

check "Disable targets conf.d/rbl/main.conf.local (not main.conf)" \
    bash -c 'sed -n "/^nftban_cmd_rbl_disable()/,/^nftban_cmd_rbl_[a-z]/p" "'"$RBL_CLI"'" | grep -q "main.conf.local"'

check "Enable uses sed -i for in-place update if key exists" \
    bash -c 'sed -n "/^nftban_cmd_rbl_enable()/,/^nftban_cmd_rbl_[a-z]/p" "'"$RBL_CLI"'" | grep -q "sed -i"'

check "Core loads main.conf.local after main.conf (override order)" \
    bash -c '
        main_line=$(grep -n "conf.d/rbl/main.conf\"" "'"$RBL_CORE"'" | grep -v "\.local" | head -1 | cut -d: -f1)
        local_line=$(grep -n "main.conf.local" "'"$RBL_CORE"'" | head -1 | cut -d: -f1)
        [[ -n "$main_line" ]] && [[ -n "$local_line" ]] && [[ "$local_line" -gt "$main_line" ]]
    '

# =============================================================================
# TEST: Timer unit exists for scheduled checks
# =============================================================================
# A systemd timer must exist to run RBL checks on a schedule.  The timer
# must reference the correct service unit and include persistence for
# missed runs.
# =============================================================================

echo ""
echo "=== 7. Timer unit exists for scheduled checks ==="

check "Timer unit file exists" \
    test -f "$RBL_TIMER"

check "Service unit file exists" \
    test -f "$RBL_SERVICE"

check "Timer has OnCalendar directive" \
    grep -q 'OnCalendar=' "$RBL_TIMER"

check "Timer has Persistent=true (catches up after downtime)" \
    grep -q 'Persistent=true' "$RBL_TIMER"

check "Timer has RandomizedDelaySec (jitter)" \
    grep -q 'RandomizedDelaySec=' "$RBL_TIMER"

check "Service runs nftban rbl check command" \
    grep -qP 'ExecStart=.*/nftban\s+rbl\s+check' "$RBL_SERVICE"

check "Service has security hardening (NoNewPrivileges)" \
    grep -q 'NoNewPrivileges=true' "$RBL_SERVICE"

check "Service has TimeoutStartSec for long-running checks" \
    grep -q 'TimeoutStartSec=' "$RBL_SERVICE"

check "Core module references timer unit in meta:inventory" \
    grep -qP 'meta:inventory\.systemd_units=.*nftban-rbl-check\.timer' "$RBL_CORE"

check "CLI enable verifies timer unit exists before enabling" \
    bash -c 'sed -n "/^nftban_cmd_rbl_enable()/,/^nftban_cmd_rbl_[a-z]/p" "'"$RBL_CLI"'" | grep -q "nftban-rbl-check.timer"'

# =============================================================================
# TEST: Provider list is configurable (rbls.conf)
# =============================================================================
# The RBL provider list must be loaded from a configurable file
# (rbls.conf) so operators can add or remove providers without editing
# code.  A custom.conf mechanism must allow per-provider overrides.
# =============================================================================

echo ""
echo "=== 8. Provider list is configurable ==="

check "NFTBAN_RBL_PROVIDERS_FILE variable references rbls.conf" \
    grep -qP 'NFTBAN_RBL_PROVIDERS_FILE.*rbls\.conf' "$RBL_CORE"

check "nftban_rbl_load_providers reads from NFTBAN_RBL_PROVIDERS_FILE" \
    bash -c 'sed -n "/^nftban_rbl_load_providers()/,/^[^ ]/p" "'"$RBL_CORE"'" | grep -q "NFTBAN_RBL_PROVIDERS_FILE"'

check "Provider file is configurable (not hardcoded path)" \
    grep -qP '^\s*:\s+"\$\{NFTBAN_RBL_PROVIDERS_FILE:=' "$RBL_CORE"

check "Custom file supports disabling individual RBLs" \
    bash -c 'sed -n "/^nftban_rbl_load_providers()/,/^[^ ]/p" "'"$RBL_CORE"'" | grep -q "disabled_rbls"'

check "Custom file supports enabling additional RBLs" \
    bash -c 'sed -n "/^nftban_rbl_load_providers()/,/^[^ ]/p" "'"$RBL_CORE"'" | grep -q "enabled_rbls"'

check "Provider list is deduplicated (sort -u)" \
    bash -c 'sed -n "/^nftban_rbl_load_providers()/,/^[^ ]/p" "'"$RBL_CORE"'" | grep -q "sort -u"'

check "CLI list subcommand exists to show providers" \
    grep -q 'nftban_cmd_rbl_list()' "$RBL_CLI"

check "rbls.conf is referenced in packaging/config" \
    grep -rq 'rbls\.conf' "${REPO_ROOT}/packaging/" 2>/dev/null || \
    grep -rq 'rbls\.conf' "${REPO_ROOT}/etc/" 2>/dev/null

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "==========================================="
echo "  RBL Module Review (07) - Test Summary"
echo "==========================================="
echo "  Tests run : ${TESTS_RUN}"
echo "  Passed    : ${PASS}"
echo "  Failed    : ${FAIL}"
echo "==========================================="

if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "  RESULT: FAIL ($FAIL test(s) failed)"
    echo ""
    exit 1
fi

echo ""
echo "  RESULT: PASS (all tests passed)"
echo ""
exit 0
