#!/usr/bin/env bash
# =============================================================================
# NFTBan Soak Check Script
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban-soak-check"
# meta:type="script"
# meta:version="1.98.1"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-17"
# meta:description="Automated soak validation — read-only checks + one bounded rebuild"
# meta:inventory.files="scripts/nftban-soak-check.sh"
# meta:inventory.binaries="/usr/sbin/nftban"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# Usage: cron every 2 hours
#   0 */2 * * * /usr/local/sbin/nftban-soak-check.sh >> /var/log/nftban/soak/cron.log 2>&1
#
# Safety: read-heavy, one bounded rebuild, no config mutation, no authority changes
# =============================================================================

set -Eeuo pipefail

HOST="$(hostname -f 2>/dev/null || hostname)"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OUT_DIR="/var/log/nftban/soak"
OUT_FILE="${OUT_DIR}/soak-${TS}.json"

mkdir -p "$OUT_DIR"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
RETRY_COUNT=0
RESULTS=()
RETRY_EXIT=0

# --- helpers ---
record() {
    local status="$1" check="$2" detail="${3:-}"
    RESULTS+=("{\"status\":\"$status\",\"check\":\"$check\",\"detail\":\"$detail\"}")
    case "$status" in
        PASS) ((PASS_COUNT++)) || true ;;
        FAIL) ((FAIL_COUNT++)) || true ;;
        WARN) ((WARN_COUNT++)) || true ;;
    esac
    echo "[$TS] [$HOST] $status: $check${detail:+ — $detail}"
}

# retry_on_127: run a command, retry up to 3 attempts on exit 127 (transient
# "command not found" under cron-storm / OOM pressure on cPanel hosts).
# - retries ONLY on exit 127; any other exit is returned immediately
# - 10s sleep between attempts
# - emits WARN log line per retry; does not mask final failure
# - captured stdout printed to stdout; exit code stored in $RETRY_EXIT
retry_on_127() {
    local check_name="$1"; shift
    local attempt=1 max=3 out rc
    while :; do
        out="$("$@" 2>/dev/null)"
        rc=$?
        if [[ $rc -ne 127 ]]; then
            break
        fi
        if [[ $attempt -ge $max ]]; then
            echo "[$TS] [$HOST] WARN: ${check_name} exit=127 after ${max} attempts — treating as real failure" >&2
            break
        fi
        echo "[$TS] [$HOST] WARN: ${check_name} exit=127 attempt ${attempt}/${max}, retrying in 10s" >&2
        RETRY_COUNT=$((RETRY_COUNT + 1))
        sleep 10
        attempt=$((attempt + 1))
    done
    RETRY_EXIT=$rc
    printf '%s' "$out"
}

# --- start ---
echo "[$TS] [$HOST] === NFTBan Soak Check Start ==="

# ==============================
# 1. Validator Status
# ==============================
VALIDATE_OUT="$(retry_on_127 validator_status nftban status --json)"
[[ -z "$VALIDATE_OUT" ]] && VALIDATE_OUT='{}'
VALIDATOR_STATUS="$(echo "$VALIDATE_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('health',{}).get('status','unknown'))" 2>/dev/null || echo "unknown")"

if [[ "$VALIDATOR_STATUS" == "protected" || "$VALIDATOR_STATUS" == "idle" ]]; then
    record "PASS" "validator_status" "$VALIDATOR_STATUS"
else
    record "FAIL" "validator_status" "$VALIDATOR_STATUS"
fi

# ==============================
# 2. Service Health
# ==============================
if systemctl is-active --quiet nftband 2>/dev/null; then
    record "PASS" "nftband_active"
else
    record "FAIL" "nftband_active"
fi

if systemctl is-active --quiet nftables 2>/dev/null; then
    record "PASS" "nftables_active"
else
    record "FAIL" "nftables_active"
fi

# ==============================
# 3. SSH Safety
# ==============================
SSH_PORT=$(grep -E '^Port ' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
[[ -z "$SSH_PORT" ]] && SSH_PORT="22"

# Check SSH port in nftban sets (tcp_ports_in) or direct rules
if nft list set ip nftban tcp_ports_in 2>/dev/null | grep -q "${SSH_PORT}"; then
    record "PASS" "ssh_port_in_ruleset" "port=$SSH_PORT in tcp_ports_in"
elif nft list ruleset 2>/dev/null | grep -q "dport.*${SSH_PORT}"; then
    record "PASS" "ssh_port_in_ruleset" "port=$SSH_PORT in rules"
else
    record "FAIL" "ssh_port_in_ruleset" "port=$SSH_PORT missing from sets and rules"
fi

# ==============================
# 4. Forbidden Patterns (CRITICAL)
# ==============================
FORBIDDEN_FOUND=0
SINCE_FLAG="--since=-130min"  # slightly more than 2h cron interval

for pattern in "health fix all" "systemctl disable" "apt-get remove" "dnf remove" "yum remove"; do
    if journalctl -u 'nftban*' $SINCE_FLAG 2>/dev/null | grep -qi "$pattern"; then
        record "FAIL" "forbidden_pattern" "$pattern"
        FORBIDDEN_FOUND=1
    fi
done

if [[ $FORBIDDEN_FOUND -eq 0 ]]; then
    record "PASS" "no_forbidden_patterns"
fi

# ==============================
# 5. Health Fix Service (must NOT auto-trigger)
# ==============================
HEALTH_FIX_RUNS="$(journalctl -u nftban-health-fix.service $SINCE_FLAG 2>/dev/null | grep -c "Started" || true)"
HEALTH_FIX_RUNS="${HEALTH_FIX_RUNS//[^0-9]/}"
[[ -z "$HEALTH_FIX_RUNS" ]] && HEALTH_FIX_RUNS=0
if [[ "$HEALTH_FIX_RUNS" -gt 0 ]]; then
    record "FAIL" "health_fix_auto_triggered" "runs=$HEALTH_FIX_RUNS"
else
    record "PASS" "health_fix_not_triggered"
fi

# ==============================
# 6. Rebuild Idempotency
# ==============================
retry_on_127 rebuild nftban firewall rebuild --quiet >/dev/null
REBUILD_EXIT=$RETRY_EXIT

if [[ $REBUILD_EXIT -eq 0 ]]; then
    record "PASS" "rebuild_idempotent" "exit=$REBUILD_EXIT"
elif [[ $REBUILD_EXIT -eq 1 ]]; then
    record "WARN" "rebuild_degraded" "exit=$REBUILD_EXIT"
else
    record "FAIL" "rebuild_failed" "exit=$REBUILD_EXIT"
fi

# Post-rebuild validator
POST_OUT="$(retry_on_127 post_rebuild_validator nftban status --json)"
[[ -z "$POST_OUT" ]] && POST_OUT='{}'
POST_STATUS="$(echo "$POST_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('health',{}).get('status','unknown'))" 2>/dev/null || echo "unknown")"
if [[ "$POST_STATUS" == "protected" || "$POST_STATUS" == "idle" ]]; then
    record "PASS" "post_rebuild_validator" "$POST_STATUS"
else
    record "FAIL" "post_rebuild_validator" "$POST_STATUS"
fi

# ==============================
# 7. Permission Drift (NB-5)
# ==============================
if [[ -f /usr/sbin/nftban ]]; then
    PERM="$(stat -c '%a' /usr/sbin/nftban 2>/dev/null || echo "000")"
    GROUP="$(stat -c '%G' /usr/sbin/nftban 2>/dev/null || echo "unknown")"
    if [[ "$PERM" == "750" && "$GROUP" == "nftban" ]]; then
        record "PASS" "nftban_binary_perms" "$GROUP:$PERM"
    else
        record "WARN" "nftban_binary_perms_drift" "$GROUP:$PERM (expected nftban:750)"
    fi
fi

# ==============================
# 8. Recovery Marker (should be absent during stable soak)
# ==============================
if [[ -f /var/lib/nftban/state/rebuild_recovery.json ]]; then
    record "WARN" "recovery_marker_present" "unexpected during stable soak"
else
    record "PASS" "no_recovery_marker"
fi

# ==============================
# 9. Write JSON result
# ==============================
VERDICT="PASS"
[[ $FAIL_COUNT -gt 0 ]] && VERDICT="FAIL"
[[ $WARN_COUNT -gt 0 && $FAIL_COUNT -eq 0 ]] && VERDICT="WARN"

# Build JSON array
RESULTS_JSON="["
for i in "${!RESULTS[@]}"; do
    [[ $i -gt 0 ]] && RESULTS_JSON+=","
    RESULTS_JSON+="${RESULTS[$i]}"
done
RESULTS_JSON+="]"

cat > "$OUT_FILE" <<EOF
{
  "timestamp": "$TS",
  "host": "$HOST",
  "verdict": "$VERDICT",
  "pass": $PASS_COUNT,
  "fail": $FAIL_COUNT,
  "warn": $WARN_COUNT,
  "retries": $RETRY_COUNT,
  "checks": $RESULTS_JSON
}
EOF

echo "[$TS] [$HOST] === Soak Check End: $VERDICT (pass=$PASS_COUNT fail=$FAIL_COUNT warn=$WARN_COUNT) ==="
echo "[$TS] [$HOST] Result: $OUT_FILE"
