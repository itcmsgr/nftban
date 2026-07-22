#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.116 Cand1 cmd_login stats CLI formatter
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_login_stats_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-16"
# meta:description="Tests for v1.116 Cand1 cmd_login stats CLI formatter consuming LoginMonStatusExtra"
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,jq,python3,grep,timeout"
# meta:inventory.files=""
# meta:inventory.binaries="bash,jq,python3"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_RUN_DIR,NFTBAN_LOG_DIR,NFTBAN_CACHE_DIR,NFTBAN_CONFIG_DIR,NFTBAN_DATA_DIR,NFTBAN_LOGIN_ALERT_LOG,NFTBAN_DISTRO_CONFIG_LOADED,NFTBAN_LOGIN_ALERT_LOADED,NFTBAN_LOGIN_LOADED"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cmd_login_stats_test"
# meta:ta.owner="loginmon"
# meta:ta.module="loginmon"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
# Purpose: Cover the LoginMon source-state CLI surface introduced by the
#          v1.116 Cand1 PR — daemon-first formatter that consumes the
#          already-existing LoginMonStatusExtra via the IPC `modules` method.
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# Test harness — load the cmd_login.sh helpers from the repo without
# requiring an installed nftban.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR

# Sandbox for synthetic socket + log file so the suite doesn't touch
# /run/nftban or /var/log/nftban.
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

export NFTBAN_RUN_DIR="$SANDBOX/run"
export NFTBAN_LOG_DIR="$SANDBOX/log"
export NFTBAN_CACHE_DIR="$SANDBOX/cache"
export NFTBAN_CONFIG_DIR="$SANDBOX/etc"
export NFTBAN_DATA_DIR="$SANDBOX/data"
mkdir -p "$NFTBAN_RUN_DIR" "$NFTBAN_LOG_DIR" "$NFTBAN_CACHE_DIR" "$NFTBAN_CONFIG_DIR" "$NFTBAN_DATA_DIR"
export NFTBAN_LOGIN_ALERT_LOG="$NFTBAN_LOG_DIR/login_alert.log"

# Bypass the dependency-laden bootstrap of cmd_login.sh. The sandbox does
# not have /etc/nftban/distros/* or a populated lib tree; setting these two
# flags short-circuits the optional `source` calls at the top of cmd_login.sh.
export NFTBAN_DISTRO_CONFIG_LOADED=1
export NFTBAN_LOGIN_ALERT_LOADED=1
export NFTBAN_LOGIN_LOADED=1

# Make json_output a no-op passthrough so the JSON-mode tests can capture
# the raw payload by simply echoing it on stdout.
json_output() {
    # $1 = success bool (unused); $2 = data payload
    printf '%s\n' "$2"
}
export -f json_output

# systemctl stub — never claims daemon is running, to keep tests host-agnostic.
# The CLI uses systemctl only for the "Daemon Started:" suffix line; tests do
# not assert on that line.
systemctl() {
    return 1
}
export -f systemctl

# Source the cmd_login.sh under test.
NFTBAN_TEST_MODE=1 source "${REPO_ROOT}/cli/lib/nftban/cli/cmd_login.sh" >/dev/null 2>&1 || true

PASS=0
FAIL=0
FAILED_TESTS=()

assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    if printf '%s' "$haystack" | grep -F -q -- "$needle"; then
        printf "  [PASS] %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s\n" "$name"
        printf "         expected to contain: %s\n" "$needle"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" name="$3"
    if printf '%s' "$haystack" | grep -F -q -- "$needle"; then
        printf "  [FAIL] %s\n" "$name"
        printf "         did NOT expect: %s\n" "$needle"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    else
        printf "  [PASS] %s\n" "$name"
        PASS=$((PASS + 1))
    fi
}

# install_socat_stub <fixture-path>
# Places a real shell script named `socat` in $SANDBOX/bin and prepends
# that dir to PATH. The CLI's `timeout 5 socat -` invocation goes through
# execv, so a bash function will not be visible — only a script on PATH
# works. The wrapper ignores all arguments and emits the fixture JSON.
install_socat_stub() {
    local fixture="$1"
    mkdir -p "$SANDBOX/bin"
    cat > "$SANDBOX/bin/socat" <<EOF
#!/usr/bin/env bash
cat "$fixture"
EOF
    chmod +x "$SANDBOX/bin/socat"
    case ":$PATH:" in
        *":$SANDBOX/bin:"*) ;;
        *) export PATH="$SANDBOX/bin:$PATH" ;;
    esac
}

# remove_socket_marker — ensures _loginmon_ipc_call returns failure.
remove_socket_marker() {
    rm -f "$NFTBAN_RUN_DIR/nftband.sock"
    # Also remove the socat wrapper so the helper would short-circuit
    # on either path (socket absent OR socat absent).
    rm -f "$SANDBOX/bin/socat"
}

# create_socket_marker — creates the unix-socket placeholder so the
# `[[ -S "$socket_path" ]]` test in _loginmon_ipc_call passes.
create_socket_marker() {
    # bash test `-S` requires a real socket. Use python's socket module.
    python3 - <<PY
import socket, os
p = os.environ["NFTBAN_RUN_DIR"] + "/nftband.sock"
try: os.unlink(p)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(p)
s.close()
PY
}

# Fixture A: daemon-up with non-zero subnet aggregation fields.
FIXTURE_DAEMON_UP_SUBNET_NONZERO=$(cat <<'EOF'
{
  "success": true,
  "data": [
    {
      "name": "loginmon",
      "state": "running",
      "extra": {
        "mode": "observe",
        "suricata_available": true,
        "services": "ssh,exim,dovecot",
        "detectors": ["ssh", "exim"],
        "total_detections": 1284,
        "total_bans": 312,
        "total_escalations": 22,
        "total_permanent": 9,
        "unique_ips": 199,
        "detections_ipv4": 1201,
        "detections_ipv6": 83,
        "bans_ipv4": 298,
        "bans_ipv6": 14,
        "tracked_ips": 47,
        "detections_by_service": {"ssh": 742, "dovecot": 213, "exim": 189, "postfix": 93, "ftp": 47},
        "bans_by_service": {"ssh": 198, "exim": 89, "dovecot": 25},
        "detections_by_reason": {"brute_force": 800, "rate_limit": 484},
        "bans_by_reason": {"brute_force_auth_fail": 219, "rate_limit_exceeded": 71, "exim_smtp_auth_fail": 22},
        "subnet_pressure_count": 18,
        "subnet_bans_total": 3,
        "subnet_watch_active": 2
      }
    }
  ]
}
EOF
)

# Fixture B: daemon-up with subnet aggregation fields all zero.
FIXTURE_DAEMON_UP_SUBNET_ZERO=$(cat <<'EOF'
{
  "success": true,
  "data": [
    {
      "name": "loginmon",
      "state": "running",
      "extra": {
        "mode": "enforce",
        "suricata_available": false,
        "services": "ssh",
        "detectors": ["ssh"],
        "total_detections": 100,
        "total_bans": 10,
        "total_escalations": 0,
        "total_permanent": 0,
        "unique_ips": 9,
        "detections_ipv4": 100,
        "detections_ipv6": 0,
        "bans_ipv4": 10,
        "bans_ipv6": 0,
        "tracked_ips": 9,
        "detections_by_service": {"ssh": 100},
        "bans_by_service": {"ssh": 10},
        "detections_by_reason": {},
        "bans_by_reason": {"brute_force": 10},
        "subnet_pressure_count": 0,
        "subnet_bans_total": 0,
        "subnet_watch_active": 0
      }
    }
  ]
}
EOF
)

# Write fixtures to disk for the socat stub.
FIXTURE_A_PATH="$SANDBOX/fixture_subnet_nonzero.json"
FIXTURE_B_PATH="$SANDBOX/fixture_subnet_zero.json"
printf '%s\n' "$FIXTURE_DAEMON_UP_SUBNET_NONZERO" > "$FIXTURE_A_PATH"
printf '%s\n' "$FIXTURE_DAEMON_UP_SUBNET_ZERO" > "$FIXTURE_B_PATH"

# Seed a small login_alert.log so the file-log section has non-zero numbers.
{
    echo "[$(date '+%Y-%m-%d') 10:00:00] SUCCESS user=root ip=1.2.3.4"
    echo "[$(date '+%Y-%m-%d') 10:01:00] FAILED user=root ip=5.6.7.8"
    echo "[$(date '+%Y-%m-%d') 10:02:00] FAILED user=admin ip=9.8.7.6"
} > "$NFTBAN_LOGIN_ALERT_LOG"

echo "============================================"
echo "v1.116 Cand1 — cmd_login stats test suite"
echo "============================================"

# --- Test 1: daemon-up text mode contains Mode + Tracked IPs + Detections + Top Services row ---
echo
echo "[T1] daemon-up text mode core fields"
create_socket_marker
install_socat_stub "$FIXTURE_A_PATH"
T1_OUT=$(nftban_login_cmd_stats 2>&1)
assert_contains "$T1_OUT" "Mode:"                                "T1.1 Mode label present"
assert_contains "$T1_OUT" "observe"                              "T1.2 Mode value 'observe'"
assert_contains "$T1_OUT" "Tracked IPs:"                         "T1.3 Tracked IPs label"
assert_contains "$T1_OUT" "Detections:"                          "T1.4 Detections label"
assert_contains "$T1_OUT" "1284"                                 "T1.5 Detections total"
assert_contains "$T1_OUT" "Top Services (by detections):"        "T1.6 Top Services header"
assert_contains "$T1_OUT" "ssh"                                  "T1.7 Top Services row contains ssh"

# --- Test 2: daemon-up with non-zero subnet aggregation shows section ---
echo
echo "[T2] daemon-up text mode with subnet non-zero"
assert_contains "$T1_OUT" "Subnet Aggregation (v1.113):"         "T2.1 Subnet Aggregation header present"
assert_contains "$T1_OUT" "Pressure events:"                     "T2.2 Pressure events label"
assert_contains "$T1_OUT" "CIDR bans:"                           "T2.3 CIDR bans label"
assert_contains "$T1_OUT" "Watched prefixes:"                    "T2.4 Watched prefixes label"

# --- Test 3: daemon-up with all-zero subnet aggregation omits section ---
echo
echo "[T3] daemon-up text mode with subnet all-zero"
install_socat_stub "$FIXTURE_B_PATH"
T3_OUT=$(nftban_login_cmd_stats 2>&1)
assert_contains "$T3_OUT" "Mode:"                                "T3.1 Module status still present"
assert_contains "$T3_OUT" "enforce"                              "T3.2 Mode 'enforce' shown"
assert_not_contains "$T3_OUT" "Subnet Aggregation"               "T3.3 Subnet section omitted (all-zero)"

# --- Test 4: daemon-down text mode falls back to file-log-only ---
echo
echo "[T4] daemon-down text mode fallback"
remove_socket_marker
T4_OUT=$(nftban_login_cmd_stats 2>&1)
T4_RC=$?
assert_contains "$T4_OUT" "daemon unreachable"                   "T4.1 Fallback notice present"
assert_contains "$T4_OUT" "Today's logged events"                "T4.2 File-log section present"
if [[ "$T4_RC" -eq 0 ]]; then
    printf "  [PASS] T4.3 Exit code 0 on daemon-down fallback\n"
    PASS=$((PASS + 1))
else
    printf "  [FAIL] T4.3 Exit code 0 on daemon-down fallback (got rc=%s)\n" "$T4_RC"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("T4.3")
fi
assert_not_contains "$T4_OUT" "Module Status (from daemon):"     "T4.4 No module section in fallback"

# --- Test 5: JSON daemon-up includes .module.mode and .module.total_detections ---
echo
echo "[T5] daemon-up JSON includes .module"
create_socket_marker
install_socat_stub "$FIXTURE_A_PATH"
T5_OUT=$(_nftban_login_cmd_stats_json "true" 2>&1)
assert_contains "$T5_OUT" '"module"'                             "T5.1 .module key present"
assert_contains "$T5_OUT" '"mode": "observe"'                    "T5.2 .module.mode value"
assert_contains "$T5_OUT" '"total_detections": 1284'             "T5.3 .module.total_detections value"
assert_contains "$T5_OUT" '"events"'                             "T5.4 .events still present"
assert_contains "$T5_OUT" '"service"'                            "T5.5 .service still present"

# --- Test 6: JSON daemon-down omits .module but preserves .events + .service ---
echo
echo "[T6] daemon-down JSON omits .module"
remove_socket_marker
T6_OUT=$(_nftban_login_cmd_stats_json "true" 2>&1)
assert_not_contains "$T6_OUT" '"module"'                         "T6.1 .module key absent"
assert_contains "$T6_OUT" '"events"'                             "T6.2 .events preserved"
assert_contains "$T6_OUT" '"service"'                            "T6.3 .service preserved"
assert_contains "$T6_OUT" '"running": false'                     "T6.4 .service.running present (stub systemctl=fail)"

echo
echo "============================================"
echo "Results: $PASS passed, $FAIL failed"
echo "============================================"

if [[ "$FAIL" -gt 0 ]]; then
    printf 'Failed tests:\n'
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
exit 0
