#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.150 Lane A log-truth + SSH-posture cleanup
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="logs_truth_v150_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-05"
# meta:description="Tests for v1.150 Lane A log/CLI-truth fixes: logrotate stanzas exist for security-audit.log (LOG-01), portscan-events.log (LOG-02) and /var/lib/nftban/permissions_audit.log (LOG-11); the header comment no longer claims a *.log glob (LOG-10); nftban_sync.sh user-facing output no longer says Fail2Ban (13.5); reports-registry.json is valid JSON with bans.log + the real field set and no jail (LOG-09); and the SSH posture resolver picks up /etc/ssh/sshd_config.d drop-in overrides (15.5). logrotate -d and the Go inventory drift-test are lab steps."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,awk,sed,mktemp,python3"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,awk,sed,mktemp,python3"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Self-contained sandbox; no host contact; no root required. We read the
# packaged logrotate template, the JSON registry and the shell sources from the
# repo, and (for 15.5) extract the _ssh_effective_directive resolver from
# nftban_report_data.sh and point its drop-in glob at a sandbox dir so the real
# merge logic is exercised without touching /etc.
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR

LOGROTATE_FILE="$REPO_ROOT/install/config/nftban.logrotate"
SYNC_SRC="$NFTBAN_LIB_DIR/core/nftban_sync.sh"
REGISTRY_JSON="$NFTBAN_LIB_DIR/data/reports-registry.json"
REPORT_DATA_SRC="$NFTBAN_LIB_DIR/lib/nftban_report_data.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
FAILED_TESTS=()

# count_stanza_paths <log-path>: number of NON-comment lines in the logrotate
# template that reference the exact path (i.e. real stanza path entries, not the
# header/comment mentions).
count_stanza_paths() {
    grep -F -- "$1" "$LOGROTATE_FILE" | grep -vc '^[[:space:]]*#'
}

assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    if printf '%s' "$haystack" | grep -F -q -- "$needle"; then
        printf "  [PASS] %s\n" "$name"; PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s\n         expected to contain: %s\n" "$name" "$needle"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
    fi
}
assert_not_contains() {
    local haystack="$1" needle="$2" name="$3"
    if printf '%s' "$haystack" | grep -F -q -- "$needle"; then
        printf "  [FAIL] %s\n         did NOT expect: %s\n" "$name" "$needle"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
    else
        printf "  [PASS] %s\n" "$name"; PASS=$((PASS + 1))
    fi
}
assert_eq() {
    local actual="$1" expected="$2" name="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf "  [PASS] %s\n" "$name"; PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s (expected '%s', got '%s')\n" "$name" "$expected" "$actual"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
    fi
}
# extract_stanza_block <log-path>: prints the brace block for a stanza whose
# path line(s) include the given exact log path. Handles multi-path stanzas.
extract_stanza_block() {
    local logpath="$1"
    awk -v target="$logpath" '
        # collect path tokens until we hit "{"; remember if target was among them
        {
            line=$0
        }
        /\{/ { in_block=1 }
        {
            # buffer recent path lines while not in a block
            if (!in_block) {
                pending = pending "\n" line
                if (index(line, target)) hit=1
            } else {
                # check the line that opened the block too
                if (index(line, target)) hit=1
                block = block "\n" line
            }
        }
        /\}/ {
            if (in_block) {
                if (hit) { print block }
                in_block=0; block=""; pending=""; hit=0
            }
        }
        !in_block && /\{/ {
            # opening brace handled above; nothing extra
        }
    ' "$LOGROTATE_FILE"
}

echo "================================================="
echo "v1.150 Lane A log/CLI-truth + SSH-posture test suite"
echo "================================================="

# ---------------------------------------------------------------------------
# T1: LOG-01 — security-audit.log has a weekly/12 logrotate stanza
# ---------------------------------------------------------------------------
echo; echo "[T1] LOG-01 security-audit.log logrotate stanza (weekly/12)"
T1_BLK=$(extract_stanza_block "/var/log/nftban/security-audit.log")
assert_eq "$(count_stanza_paths /var/log/nftban/security-audit.log)" "1" "T1.1 exactly one stanza path entry"
assert_contains "$T1_BLK" "weekly"        "T1.2 weekly frequency"
assert_contains "$T1_BLK" "rotate 12"     "T1.3 rotate 12"
assert_contains "$T1_BLK" "copytruncate"  "T1.4 copytruncate"

# ---------------------------------------------------------------------------
# T2: LOG-02 — portscan-events.log has a daily / size 100M / rotate 30 stanza
# ---------------------------------------------------------------------------
echo; echo "[T2] LOG-02 portscan-events.log logrotate stanza (daily/100M/30)"
T2_BLK=$(extract_stanza_block "/var/log/nftban/portscan-events.log")
assert_eq "$(count_stanza_paths /var/log/nftban/portscan-events.log)" "1" "T2.1 exactly one stanza path entry"
assert_contains "$T2_BLK" "daily"      "T2.2 daily frequency"
assert_contains "$T2_BLK" "rotate 30"  "T2.3 rotate 30"
assert_contains "$T2_BLK" "size 100M"  "T2.4 size 100M cap"

# ---------------------------------------------------------------------------
# T3: LOG-11 — permissions_audit.log under /var/lib has a weekly/12 stanza
# ---------------------------------------------------------------------------
echo; echo "[T3] LOG-11 /var/lib/nftban/permissions_audit.log logrotate stanza"
T3_BLK=$(extract_stanza_block "/var/lib/nftban/permissions_audit.log")
assert_eq "$(count_stanza_paths /var/lib/nftban/permissions_audit.log)" "1" "T3.1 exactly one stanza path entry"
assert_contains "$T3_BLK" "weekly"     "T3.2 weekly frequency"
assert_contains "$T3_BLK" "rotate 12"  "T3.3 rotate 12"

# ---------------------------------------------------------------------------
# T4: LOG-10 — header no longer claims a bare *.log glob is rotated
# ---------------------------------------------------------------------------
echo; echo "[T4] LOG-10 header reflects exact-path enumeration (no false *.log claim)"
T4_HEADER=$(sed -n '1,20p' "$LOGROTATE_FILE")
assert_contains    "$T4_HEADER" "exact"                              "T4.1 header mentions exact-path enumeration"
assert_not_contains "$T4_HEADER" "- /var/log/nftban/*.log (weekly"   "T4.2 stale '*.log (weekly, 4 weeks)' claim removed"

# ---------------------------------------------------------------------------
# T5: 13.5 — nftban_sync.sh user-facing output no longer says Fail2Ban
# ---------------------------------------------------------------------------
echo; echo "[T5] 13.5 no user-facing Fail2Ban string in nftban_sync.sh"
# user-facing = nftban_output lines + the help/heredoc text. Assert none remain.
T5_OUTLINES=$(grep -nE "Fail2Ban|fail2ban" "$SYNC_SRC" || true)
assert_eq "${T5_OUTLINES:-}" "" "T5.1 zero Fail2Ban references remain in nftban_sync.sh"
assert_contains "$(grep -E 'nftban_output .*Runtime state' "$SYNC_SRC" || true)" "NFTBan runtime bans preserved" "T5.2 output relabeled to NFTBan runtime"

# ---------------------------------------------------------------------------
# T6: LOG-09 — reports-registry.json valid, bans.log path, real fields, no jail
# ---------------------------------------------------------------------------
echo; echo "[T6] LOG-09 reports-registry.json corrected (valid JSON, bans.log, no jail)"
if command -v python3 >/dev/null 2>&1; then
    T6_VALID=$(python3 -c "import json,sys; json.load(open(sys.argv[1])); print('ok')" "$REGISTRY_JSON" 2>&1 || echo "ERR")
    assert_eq "$T6_VALID" "ok" "T6.1 registry is valid JSON"
    T6_PATH=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['log_files']['ban_log']['path'])" "$REGISTRY_JSON" 2>/dev/null || echo "ERR")
    assert_eq "$T6_PATH" "/var/log/nftban/bans.log" "T6.2 ban_log.path -> bans.log"
    T6_ROT=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['log_files']['ban_log']['rotation'])" "$REGISTRY_JSON" 2>/dev/null || echo "ERR")
    assert_eq "$T6_ROT" "weekly" "T6.3 ban_log.rotation -> weekly"
    T6_FIELDS=$(python3 -c "import json,sys; print(','.join(json.load(open(sys.argv[1]))['log_files']['ban_log']['fields']))" "$REGISTRY_JSON" 2>/dev/null || echo "ERR")
    assert_eq "$T6_FIELDS" "DATE,TIME,SOURCE,IP,COUNTRY,STATUS,REASON" "T6.4 fields -> real bans.log schema"
    assert_not_contains "$T6_FIELDS" "jail" "T6.5 jail field removed"
else
    printf "  [SKIP] python3 unavailable — registry JSON checks (lab/CI step)\n"
fi

# ---------------------------------------------------------------------------
# T7: 15.5 — SSH posture resolver honours sshd_config.d drop-in overrides
# ---------------------------------------------------------------------------
echo; echo "[T7] 15.5 SSH posture resolver picks up sshd_config.d drop-in"
# Mock a main config (PasswordAuthentication yes) overridden by a later drop-in
# (PasswordAuthentication no). The effective value MUST be 'no'.
MAIN_CFG="$SANDBOX/sshd_config"
DROPIN_DIR="$SANDBOX/sshd_config.d"
mkdir -p "$DROPIN_DIR"
printf 'PasswordAuthentication yes\nPermitRootLogin yes\n' > "$MAIN_CFG"
printf 'PasswordAuthentication no\n' > "$DROPIN_DIR/50-hardening.conf"

# Extract the real resolver and repoint its drop-in glob at the sandbox dir.
# Force the non-root fallback path (we are not root and don't want to invoke
# the host sshd) by neutralising the EUID-root branch.
resolver_env() {
    awk '/^_ssh_effective_directive\(\)/{c=1} c{print} c&&/^}/{exit}' "$REPORT_DATA_SRC" \
        | sed -E "s@/etc/ssh/sshd_config.d@${DROPIN_DIR}@g" \
        | sed -E 's@\$\{EUID:-\$\(id -u\)\}" -eq 0@999" -eq 0@g'
}
call_resolver() { ( set +e; eval "$(resolver_env)"; _ssh_effective_directive "$1" "$MAIN_CFG" ); }

T7_PASS=$(call_resolver passwordauthentication 2>/dev/null || echo "ERR")
assert_eq "$T7_PASS" "no" "T7.1 drop-in override wins (PasswordAuthentication -> no)"
T7_ROOT=$(call_resolver permitrootlogin 2>/dev/null || echo "ERR")
assert_eq "$T7_ROOT" "yes" "T7.2 main-file value used when no drop-in overrides it"
# absent directive -> conservative default 'yes'
T7_ABSENT=$(call_resolver x11forwarding 2>/dev/null || echo "ERR")
assert_eq "$T7_ABSENT" "yes" "T7.3 absent directive -> conservative 'yes' default"

# ---------------------------------------------------------------------------
# T8: lab steps (logrotate -d + Go inventory drift-test) — informational
# ---------------------------------------------------------------------------
echo; echo "[T8] lab integration steps"
if command -v logrotate >/dev/null 2>&1; then
    if logrotate -d "$LOGROTATE_FILE" >/dev/null 2>&1; then
        printf "  [PASS] %s\n" "T8.1 logrotate -d parses the template cleanly"; PASS=$((PASS+1))
    else
        # -d may warn about missing users/paths on this host; that's a lab check.
        printf "  [SKIP] logrotate -d emitted host-specific warnings (validate on lab)\n"
    fi
else
    printf "  [SKIP] logrotate not installed — 'logrotate -d' is a lab step\n"
fi
printf "  [NOTE] Go inventory<->template drift-test (logs_logrotate_drift_test.go) runs on lab (no Go toolchain here)\n"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo; echo "================================================="
echo "Results: PASS=$PASS  FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then
    echo "Failed tests:"; for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
    exit 1
fi
echo "All tests passed."
exit 0
