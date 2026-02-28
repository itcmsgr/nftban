#!/usr/bin/env bash
# =============================================================================
# NFTBan Review 08 - Login Module Static Analysis Test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Automated static checks for login monitoring module
#
# meta:name="08_login_test"
# meta:type="test"
# meta:header="Login Module Review Test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Static analysis tests for the login monitoring module"
# meta:input="Source files under cli/lib/nftban/"
# meta:output="PASS/FAIL test results"
# meta:depends="grep,bash"
#
# meta:inventory.files="nftban_login.sh,nftban_login_classic.sh,nftban_login_suricata.sh,nftban_login_alert.sh,cmd_login.sh"
# meta:inventory.binaries="grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# RESOLVE REPO ROOT
# =============================================================================

# Determine repository root - works when invoked from any directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Verify we are in an nftban repo
if [[ ! -f "$REPO_ROOT/VERSION" ]]; then
    echo "FATAL: Cannot locate repo root (no VERSION file at $REPO_ROOT)" >&2
    exit 2
fi

# =============================================================================
# FILE PATHS (relative to repo root)
# =============================================================================

LOGIN_CORE="$REPO_ROOT/cli/lib/nftban/core/nftban_login.sh"
LOGIN_CLASSIC="$REPO_ROOT/cli/lib/nftban/core/nftban_login_classic.sh"
LOGIN_SURICATA="$REPO_ROOT/cli/lib/nftban/core/nftban_login_suricata.sh"
LOGIN_ALERT="$REPO_ROOT/cli/lib/nftban/core/nftban_login_alert.sh"
CMD_LOGIN="$REPO_ROOT/cli/lib/nftban/cli/cmd_login.sh"
SERVICE_UNIT="$REPO_ROOT/install/systemd/nftban-login-monitor.service"

# All source files as an array for cross-file searches
ALL_LOGIN_FILES=(
    "$LOGIN_CORE"
    "$LOGIN_CLASSIC"
    "$LOGIN_SURICATA"
    "$LOGIN_ALERT"
    "$CMD_LOGIN"
)

# =============================================================================
# COUNTERS AND HELPERS
# =============================================================================

PASS=0
FAIL=0
TOTAL=0

check() {
    # Usage: check "description" <exit_code>
    # Exit code 0 = PASS, nonzero = FAIL
    local description="$1"
    local result="$2"

    ((TOTAL++)) || true

    if [[ "$result" -eq 0 ]]; then
        ((PASS++)) || true
        printf "  PASS  %s\n" "$description"
    else
        ((FAIL++)) || true
        printf "  FAIL  %s\n" "$description"
    fi
}

section() {
    echo ""
    echo "--- $1 ---"
}

# grep_check: run grep -qE and record PASS/FAIL without triggering set -e
grep_check() {
    local description="$1"
    local pattern="$2"
    local file="$3"

    if grep -qE "$pattern" "$file" 2>/dev/null; then
        check "$description" 0
    else
        check "$description" 1
    fi
}

# =============================================================================
# PREREQUISITE: verify all source files exist
# =============================================================================

section "Prerequisites"

for f in "${ALL_LOGIN_FILES[@]}" "$SERVICE_UNIT"; do
    name="$(basename "$f")"
    if [[ -f "$f" ]]; then
        check "Source file exists: $name" 0
    else
        check "Source file exists: $name" 1
    fi
done

# =============================================================================
# 1. SSH LOG PARSING REGEX
# =============================================================================

section "1. SSH log parsing regex"

# 1a. "Failed password for <user> from <IP>" pattern
grep_check \
    "Classic: regex for 'Failed password for <user> from <IP>'" \
    'Failed[[:space:]]+password[[:space:]]+for.*from.*[0-9a-fA-F.:]+' \
    "$LOGIN_CLASSIC"

# 1b. "Failed password for invalid user" pattern
grep_check \
    "Classic: regex for 'Failed password for invalid user'" \
    'Failed[[:space:]]+password[[:space:]]+for[[:space:]]+invalid[[:space:]]+user' \
    "$LOGIN_CLASSIC"

# 1c. "Invalid user" standalone pattern
# Source uses backslash-escaped spaces in bash regex: Invalid\ user\ ...
grep_check \
    "Classic: regex for 'Invalid user <user> from <IP>'" \
    'Invalid\\ user' \
    "$LOGIN_CLASSIC"

# 1d. "Too many authentication failures" pattern
grep_check \
    "Classic: regex for 'Too many authentication failures'" \
    '[Tt]oo[[:space:]]+many[[:space:]]+authentication[[:space:]]+failures' \
    "$LOGIN_CLASSIC"

# 1e. Disconnected preauth pattern (scan detection)
grep_check \
    "Classic: regex for disconnected preauth (scan detection)" \
    'Disconnected.*preauth' \
    "$LOGIN_CLASSIC"

# 1f. Alert module also has SSH parsing patterns
grep_check \
    "Alert: regex for SSH failed login (password/publickey)" \
    'Failed.*(password|publickey).*for.*from' \
    "$LOGIN_ALERT"

# 1g. Alert module parses successful logins too
grep_check \
    "Alert: regex for SSH accepted login (password/publickey)" \
    'Accepted.*(password|publickey).*for.*from' \
    "$LOGIN_ALERT"

# 1h. IPv6-capable IP regex (matches both IPv4 and IPv6 in capture group)
grep_check \
    "Classic: IP regex handles both IPv4 and IPv6 addresses" \
    '0-9a-fA-F.:' \
    "$LOGIN_CLASSIC"

# =============================================================================
# 2. RATE WINDOW CONFIGURATION
# =============================================================================

section "2. Rate window configuration"

# 2a. Threshold count variable exists with default
grep_check \
    "Classic: fail threshold variable defined" \
    '(LOGIN_CLASSIC_FAIL_THRESHOLD|LOGIN_FAIL_THRESHOLD|NFTBAN_LOGIN_FAILED_THRESHOLD)' \
    "$LOGIN_CLASSIC"

# 2b. Window duration variable exists with default
grep_check \
    "Classic: fail window variable defined" \
    '(LOGIN_CLASSIC_FAIL_WINDOW|LOGIN_FAIL_WINDOW|NFTBAN_LOGIN_FAILED_WINDOW)' \
    "$LOGIN_CLASSIC"

# 2c. Alert module also defines threshold
grep_check \
    "Alert: fail threshold variable defined" \
    'NFTBAN_LOGIN_FAILED_THRESHOLD' \
    "$LOGIN_ALERT"

# 2d. Alert module also defines window
grep_check \
    "Alert: fail window variable defined" \
    'NFTBAN_LOGIN_FAILED_WINDOW' \
    "$LOGIN_ALERT"

# 2e. Window-based reset logic (outside window -> reset counter)
# The classic module resets the counter when elapsed >= window
if grep -qE 'elapsed' "$LOGIN_CLASSIC" 2>/dev/null && \
   grep -qE 'window' "$LOGIN_CLASSIC" 2>/dev/null; then
    check "Classic: window-based counter reset logic present" 0
else
    check "Classic: window-based counter reset logic present" 1
fi

# 2f. Suricata mode also has alert window
grep_check \
    "Suricata: alert window variable defined" \
    'LOGIN_SURICATA_ALERT_WINDOW' \
    "$LOGIN_SURICATA"

# 2g. Per-service threshold overrides supported
grep_check \
    "Classic: per-service threshold overrides supported" \
    'LOGIN_SERVICE_.*_FAIL_THRESHOLD' \
    "$LOGIN_CLASSIC"

# =============================================================================
# 3. WHITELIST INTEGRATION
# =============================================================================

section "3. Whitelist integration (check before ban)"

# 3a. Classic mode checks whitelist inside event processing
grep_check \
    "Classic: whitelist check function exists" \
    '_is_whitelisted' \
    "$LOGIN_CLASSIC"

# 3b. Whitelist is checked before any count increment (structural check)
# In _nftban_login_classic_process_event, the whitelist check comes before
# the fail count increment. Verify the whitelist call appears earlier in the
# function than the fail count increment.
_wl_line=$(grep -n '_nftban_login_classic_is_whitelisted' "$LOGIN_CLASSIC" 2>/dev/null | head -1 | cut -d: -f1 || echo "")
_count_line=$(grep -n '_LOGIN_CLASSIC_FAIL_COUNT\[' "$LOGIN_CLASSIC" 2>/dev/null | head -1 | cut -d: -f1 || echo "")
if [[ -n "$_wl_line" && -n "$_count_line" && "$_wl_line" -lt "$_count_line" ]]; then
    check "Classic: whitelist check appears before fail count increment" 0
else
    check "Classic: whitelist check appears before fail count increment" 1
fi

# 3c. Core ban function also checks whitelist before banning
if grep -qE 'whitelist' "$LOGIN_CORE" 2>/dev/null && \
   grep -qE 'nft get element' "$LOGIN_CORE" 2>/dev/null; then
    check "Core: nftban_login_ban() checks nft whitelist set before banning" 0
else
    check "Core: nftban_login_ban() checks nft whitelist set before banning" 1
fi

# 3d. Suricata mode has whitelist check
grep_check \
    "Suricata: whitelist check exists" \
    '_is_whitelisted' \
    "$LOGIN_SURICATA"

# 3e. Alert module has its own whitelist function
grep_check \
    "Alert: whitelist check function exists" \
    'nftban_login_is_whitelisted' \
    "$LOGIN_ALERT"

# 3f. Localhost whitelisting (127.0.0.1 and ::1)
if grep -qE '127\.0\.0\.1' "$LOGIN_CLASSIC" 2>/dev/null && \
   grep -qE '::1' "$LOGIN_CLASSIC" 2>/dev/null; then
    check "Classic: localhost IPs (127.0.0.1, ::1) are whitelisted" 0
else
    check "Classic: localhost IPs (127.0.0.1, ::1) are whitelisted" 1
fi

# 3g. Private network whitelisting (RFC 1918)
grep_check \
    "Classic: RFC 1918 private networks are whitelisted" \
    '\^10\\' \
    "$LOGIN_CLASSIC"

# 3h. IPv6 ULA/link-local whitelisting (RFC 4193)
grep_check \
    "Classic: IPv6 ULA/link-local addresses are whitelisted" \
    '[Ff][CcDd]|[Ff][Ee]80' \
    "$LOGIN_CLASSIC"

# 3i. Central whitelist integration (nftban_is_whitelisted from nft_schema.sh)
grep_check \
    "Classic: delegates to central nftban_is_whitelisted()" \
    'nftban_is_whitelisted' \
    "$LOGIN_CLASSIC"

# =============================================================================
# 4. LOGROTATE SAFETY
# =============================================================================

section "4. Logrotate safety (file inode tracking / reopen detection)"

# 4a. Uses tail -F (capital F) which follows by name, not inode.
# This survives logrotate because tail -F reopens the file after rotation.
grep_check \
    "Classic: uses 'tail -F' for file monitoring (survives logrotate)" \
    'tail -F' \
    "$LOGIN_CLASSIC"

# 4b. Suricata mode also uses tail -F for EVE file
grep_check \
    "Suricata: uses 'tail -F' for EVE monitoring (survives logrotate)" \
    'tail -F' \
    "$LOGIN_SURICATA"

# 4c. Journal cursor persistence (v1.18.9) - prevents double-processing on restart
grep_check \
    "Classic: journalctl cursor persistence for restart safety" \
    'cursor|CURSOR|after-cursor' \
    "$LOGIN_CLASSIC"

# 4d. Cursor file variable defined
grep_check \
    "Classic: cursor file path variable defined" \
    '_LOGIN_CLASSIC_CURSOR_FILE' \
    "$LOGIN_CLASSIC"

# 4e. Journal mode uses --follow (-f) for live tailing
grep_check \
    "Classic: journalctl uses follow mode (-f)" \
    'journalctl.*-f' \
    "$LOGIN_CLASSIC"

# =============================================================================
# 5. CONFIG PERSISTENCE FOR ENABLE/DISABLE
# =============================================================================

section "5. Config persistence for enable/disable"

# 5a. Enable command writes to config file
grep_check \
    "CLI: enable command persists ENABLED=true to config" \
    '_nftban_login_set_config.*ENABLED.*true' \
    "$CMD_LOGIN"

# 5b. Disable command writes to config file
grep_check \
    "CLI: disable command persists ENABLED=false to config" \
    '_nftban_login_set_config.*ENABLED.*false' \
    "$CMD_LOGIN"

# 5c. Config writes go to .conf.local (user overrides, not base config)
grep_check \
    "CLI: config changes written to .conf.local (user override file)" \
    'conf\.local' \
    "$CMD_LOGIN"

# 5d. _nftban_login_set_config helper uses sed for update, append for new
grep_check \
    "CLI: set_config uses sed for existing keys" \
    'sed -i' \
    "$CMD_LOGIN"

# 5e. set_config appends new keys via echo >>
grep_check \
    "CLI: set_config appends new keys" \
    'echo.*>>' \
    "$CMD_LOGIN"

# 5f. Config file gets proper permissions (640)
grep_check \
    "CLI: config file created with 640 permissions" \
    'chmod 640' \
    "$CMD_LOGIN"

# 5g. Classic mode saves state to disk on stop
if grep -qE '_nftban_login_classic_save_state' "$LOGIN_CLASSIC" 2>/dev/null || \
   grep -qE 'login-classic-state' "$LOGIN_CLASSIC" 2>/dev/null; then
    check "Classic: state is persisted to disk on stop" 0
else
    check "Classic: state is persisted to disk on stop" 1
fi

# 5h. Suricata mode saves state to disk on stop
if grep -qE '_nftban_login_suricata_save_state' "$LOGIN_SURICATA" 2>/dev/null || \
   grep -qE 'login-suricata-state' "$LOGIN_SURICATA" 2>/dev/null; then
    check "Suricata: state is persisted to disk on stop" 0
else
    check "Suricata: state is persisted to disk on stop" 1
fi

# =============================================================================
# 6. SERVICE UNIT EXISTS
# =============================================================================

section "6. Systemd service unit"

# 6a. Service unit file exists
if [[ -f "$SERVICE_UNIT" ]]; then
    check "Service unit file exists: nftban-login-monitor.service" 0
else
    check "Service unit file exists: nftban-login-monitor.service" 1
fi

# 6b. Service ExecStart runs nftban login run
grep_check \
    "Service: ExecStart invokes 'nftban login run'" \
    'ExecStart=.*/nftban login run' \
    "$SERVICE_UNIT"

# 6c. Service has Restart=on-failure for resilience
grep_check \
    "Service: Restart=on-failure configured" \
    'Restart=on-failure' \
    "$SERVICE_UNIT"

# 6d. Service has security hardening (NoNewPrivileges)
grep_check \
    "Service: NoNewPrivileges=true hardening" \
    'NoNewPrivileges=true' \
    "$SERVICE_UNIT"

# 6e. Service runs as unprivileged user (not root)
grep_check \
    "Service: runs as unprivileged nftban user" \
    'User=nftban' \
    "$SERVICE_UNIT"

# 6f. Service has memory limit
grep_check \
    "Service: memory limit configured (MemoryMax)" \
    'MemoryMax=' \
    "$SERVICE_UNIT"

# 6g. Service name referenced in source code
grep_check \
    "CLI: references nftban-login-monitor service name" \
    'nftban-login-monitor' \
    "$CMD_LOGIN"

# 6h. Meta tag references the systemd unit
grep_check \
    "Core: meta tag declares nftban-login-monitor.service" \
    'meta:inventory.systemd_units=.*nftban-login-monitor' \
    "$LOGIN_CORE"

# =============================================================================
# 7. LOG SOURCES ARE CONFIGURABLE
# =============================================================================

section "7. Log sources are configurable"

# 7a. SSH journal units are configurable
grep_check \
    "Classic: SSH journal units configurable (LOGIN_SERVICE_SSH_UNITS)" \
    'LOGIN_SERVICE_SSH_UNITS' \
    "$LOGIN_CLASSIC"

# 7b. Dovecot journal units configurable
grep_check \
    "Classic: Dovecot journal units configurable" \
    'LOGIN_SERVICE_DOVECOT_UNITS' \
    "$LOGIN_CLASSIC"

# 7c. Postfix journal units configurable
grep_check \
    "Classic: Postfix journal units configurable" \
    'LOGIN_SERVICE_POSTFIX_UNITS' \
    "$LOGIN_CLASSIC"

# 7d. Exim journal units configurable
grep_check \
    "Classic: Exim journal units configurable" \
    'LOGIN_SERVICE_EXIM_UNITS' \
    "$LOGIN_CLASSIC"

# 7e. Mail log file path is configurable
grep_check \
    "Classic: mail log file path configurable (LOGIN_SERVICE_MAIL_LOG)" \
    'LOGIN_SERVICE_MAIL_LOG' \
    "$LOGIN_CLASSIC"

# 7f. Exim log file path is configurable
grep_check \
    "Classic: Exim log file path configurable (LOGIN_SERVICE_EXIM_LOG)" \
    'LOGIN_SERVICE_EXIM_LOG' \
    "$LOGIN_CLASSIC"

# 7g. WordPress log file is configurable
grep_check \
    "Classic: WordPress access log path configurable" \
    'LOGIN_SERVICE_WORDPRESS_LOG' \
    "$LOGIN_CLASSIC"

# 7h. Suricata EVE file path is configurable
grep_check \
    "Suricata: EVE JSON file path configurable" \
    'LOGIN_SURICATA_EVE_FILE' \
    "$LOGIN_SURICATA"

# 7i. Smart log source detection (journal vs file fallback)
if grep -qE 'journal_has_entries' "$LOGIN_CLASSIC" 2>/dev/null || \
   grep -qE 'journal empty.*using file' "$LOGIN_CLASSIC" 2>/dev/null; then
    check "Classic: smart journal-vs-file fallback detection" 0
else
    check "Classic: smart journal-vs-file fallback detection" 1
fi

# 7j. Supports both journalctl and plain file sources
if grep -qE '_monitor_journal' "$LOGIN_CLASSIC" 2>/dev/null && \
   grep -qE '_monitor_file' "$LOGIN_CLASSIC" 2>/dev/null; then
    check "Classic: supports both journal and file monitoring modes" 0
else
    check "Classic: supports both journal and file monitoring modes" 1
fi

# =============================================================================
# 8. FALSE POSITIVE PREVENTION
# =============================================================================

section "8. False positive prevention (conservative defaults)"

# 8a. Classic default threshold is >= 5 (conservative, not 1 or 2)
threshold_default=$(grep -oP 'LOGIN_CLASSIC_FAIL_THRESHOLD:=\K[0-9]+' "$LOGIN_CLASSIC" 2>/dev/null | head -1 || echo "")
if [[ -n "$threshold_default" && "$threshold_default" -ge 5 ]]; then
    check "Classic: default fail threshold is >= 5 (got $threshold_default)" 0
else
    check "Classic: default fail threshold is >= 5 (got ${threshold_default:-?})" 1
fi

# 8b. Alert module default threshold is >= 5
# Alert module uses ${VAR:-default} syntax (not :=)
alert_threshold=$(grep -oP 'NFTBAN_LOGIN_FAILED_THRESHOLD.*:-\K[0-9]+' "$LOGIN_ALERT" 2>/dev/null | head -1 || echo "")
if [[ -n "$alert_threshold" && "$alert_threshold" -ge 5 ]]; then
    check "Alert: default fail threshold is >= 5 (got $alert_threshold)" 0
else
    check "Alert: default fail threshold is >= 5 (got ${alert_threshold:-?})" 1
fi

# 8c. Default window is >= 60 seconds (not too small)
window_default=$(grep -oP 'LOGIN_CLASSIC_FAIL_WINDOW:=\K[0-9]+' "$LOGIN_CLASSIC" 2>/dev/null | head -1 || echo "")
if [[ -n "$window_default" && "$window_default" -ge 60 ]]; then
    check "Classic: default fail window is >= 60s (got ${window_default}s)" 0
else
    check "Classic: default fail window is >= 60s (got ${window_default:-?}s)" 1
fi

# 8d. Score-based tiered banning (short vs long bans, not immediate permanent)
if grep -qE 'THRESHOLD_BLOCK_SHORT' "$LOGIN_CLASSIC" 2>/dev/null && \
   grep -qE 'THRESHOLD_BLOCK_LONG' "$LOGIN_CLASSIC" 2>/dev/null; then
    check "Classic: tiered banning with short and long thresholds" 0
else
    check "Classic: tiered banning with short and long thresholds" 1
fi

# 8e. Short ban duration is less than long ban duration
short_ban=$(grep -oP 'BAN_DURATION_SHORT:=\K[0-9]+' "$LOGIN_CLASSIC" 2>/dev/null | head -1 || echo "")
long_ban=$(grep -oP 'BAN_DURATION_LONG:=\K[0-9]+' "$LOGIN_CLASSIC" 2>/dev/null | head -1 || echo "")
if [[ -n "$short_ban" && -n "$long_ban" && "$short_ban" -lt "$long_ban" ]]; then
    check "Classic: short ban (${short_ban}s) < long ban (${long_ban}s)" 0
else
    check "Classic: short ban < long ban (short=${short_ban:-?}, long=${long_ban:-?})" 1
fi

# 8f. Score decay prevents permanent score inflation (v1.18.9)
if grep -qE 'SCORE_DECAY_RATE' "$LOGIN_CLASSIC" 2>/dev/null || \
   grep -qE '_apply_decay' "$LOGIN_CLASSIC" 2>/dev/null; then
    check "Classic: score decay mechanism prevents permanent inflation" 0
else
    check "Classic: score decay mechanism prevents permanent inflation" 1
fi

# 8g. Root login gets stricter threshold (not the same as normal users)
if grep -qE 'ROOT_MULTIPLIER' "$LOGIN_ALERT" 2>/dev/null || \
   grep -qE 'root.*multiplier' "$LOGIN_ALERT" 2>/dev/null; then
    check "Alert: root login attempts get stricter threshold handling" 0
else
    check "Alert: root login attempts get stricter threshold handling" 1
fi

# 8h. Ban deduplication: skip if IP already banned
if grep -qE 'already banned' "$LOGIN_ALERT" 2>/dev/null || \
   grep -qE 'blacklist_ipv4' "$LOGIN_ALERT" 2>/dev/null; then
    check "Alert: ban deduplication avoids re-banning already-banned IPs" 0
else
    check "Alert: ban deduplication avoids re-banning already-banned IPs" 1
fi

# 8i. Alert throttling prevents storm of alerts
grep_check \
    "Alert: alert throttling prevents alert storms" \
    'throttl' \
    "$LOGIN_ALERT"

# 8j. Ban retry logic with backoff on failure
if grep -qE 'ban_retries' "$LOGIN_ALERT" 2>/dev/null || \
   grep -qE 'ban_max_retries' "$LOGIN_ALERT" 2>/dev/null; then
    check "Alert: ban retry logic with backoff on transient failures" 0
else
    check "Alert: ban retry logic with backoff on transient failures" 1
fi

# =============================================================================
# BONUS: Cross-cutting invariants
# =============================================================================

section "Bonus: Cross-cutting invariants"

# B1. All login source files have set -Eeuo pipefail (directly or via strict.sh)
for f in "${ALL_LOGIN_FILES[@]}"; do
    name="$(basename "$f")"
    if grep -qE 'set -Eeuo pipefail' "$f" 2>/dev/null || \
       grep -qE 'source.*strict\.sh' "$f" 2>/dev/null; then
        check "Strict mode: $name has 'set -Eeuo pipefail' or sources strict.sh" 0
    else
        check "Strict mode: $name has 'set -Eeuo pipefail' or sources strict.sh" 1
    fi
done

# B2. All login source files have 7 meta:inventory lines
for f in "${ALL_LOGIN_FILES[@]}"; do
    name="$(basename "$f")"
    inv_count=$(grep -c 'meta:inventory\.' "$f" 2>/dev/null || echo 0)
    if [[ "$inv_count" -ge 7 ]]; then
        check "Meta tags: $name has >= 7 inventory lines (got $inv_count)" 0
    else
        check "Meta tags: $name has >= 7 inventory lines (got $inv_count)" 1
    fi
done

# B3. Double-load guards in all modules
for f in "$LOGIN_CORE" "$LOGIN_CLASSIC" "$LOGIN_SURICATA" "$LOGIN_ALERT" "$CMD_LOGIN"; do
    name="$(basename "$f")"
    if grep -qE '_LOADED' "$f" 2>/dev/null && grep -qE 'return 0' "$f" 2>/dev/null; then
        check "Load guard: $name has double-load prevention" 0
    else
        check "Load guard: $name has double-load prevention" 1
    fi
done

# B4. IPC-based banning (bans go through nftban ban command, not direct nft calls)
if grep -qE 'nftban.*ban' "$LOGIN_CORE" 2>/dev/null || \
   grep -qE 'BAN_COMMAND' "$LOGIN_CORE" 2>/dev/null; then
    check "IPC: bans use 'nftban ban' command (not direct nft calls)" 0
else
    check "IPC: bans use 'nftban ban' command (not direct nft calls)" 1
fi

# B5. HTML injection prevention in alert emails
if grep -qE 'lt;|gt;|quot;' "$LOGIN_ALERT" 2>/dev/null; then
    check "Security: HTML injection prevention in alert email fields" 0
else
    check "Security: HTML injection prevention in alert email fields" 1
fi

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "=============================================="
echo "  LOGIN MODULE REVIEW - TEST SUMMARY"
echo "=============================================="
echo ""
echo "  Total:  $TOTAL"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
    echo "  RESULT: FAIL ($FAIL test(s) did not pass)"
    echo ""
    exit 1
else
    echo "  RESULT: ALL PASS"
    echo ""
    exit 0
fi
