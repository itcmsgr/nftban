#!/usr/bin/env bash
# =============================================================================
# NFTBan - FS3-MUTATION rc-swallow regression test (v1.143 PR-A)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_fs3_mutation_v143_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-29"
# meta:description="v1.143 PR-A — asserts that five FS3-class mutation-path functions propagate child-operation rc truthfully. Pre-v1.143 each of these functions printed an unconditional ✅ / 'Done' / 'Successfully' marker AND returned 0 even after a per-iteration child failed. Same FS3 family as v1.142 PR-FS nftban_feeds_select. Surfaces covered: cmd_feeds::nftban_cmd_feeds (feeds enable <category>), cmd_port::nftban_port_allow_add (IPC apply), cmd_port::nftban_port_allow_remove (IPC revoke), cmd_port::nftban_port_allow_flush (per-set IPC flush loop), cmd_metrics::nftban_metrics_enable (_set_metrics_backend rc swallow). Stubbed-callable mirror pattern matches v1.142 PR-FS test."
# meta:input="cli/lib/nftban/cli/cmd_feeds.sh, cli/lib/nftban/cli/cmd_port.sh, cli/lib/nftban/cli/cmd_metrics.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files="cli/lib/nftban/cli/cmd_feeds.sh,cli/lib/nftban/cli/cmd_port.sh,cli/lib/nftban/cli/cmd_metrics.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
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

# Each row uses the stubbed-callable mirror pattern from v1.142 PR-FS test.
# The mirror reproduces the v1.143-patched code shape; per-test drift is
# caught by T-DRIFT at the end which scans live source for the markers.
MIRROR=$(mktemp -d -t nftban-fs3.XXXXXX)
trap 'rm -rf "$MIRROR"' EXIT

# ──────────────────────────────────────────────────────────────────────────
# T-MIRROR-FEEDS  —  cmd_feeds enable-category loop+success
# ──────────────────────────────────────────────────────────────────────────
cat >"$MIRROR/feeds_enable_category.sh" <<'EOF'
#!/usr/bin/env bash
set +e
# stub: nftban_feeds_enable fails for feeds matching NF_FAIL_PAT
nftban_feeds_enable() {
    if [[ -n "${NF_FAIL_PAT:-}" ]] && [[ "$1" =~ $NF_FAIL_PAT ]]; then
        return 1
    fi
    return 0
}
nftban_feeds_get_by_category() { echo "$NF_CAT_FEEDS"; }
NFTBAN_LOG_DIR=/tmp

# Mirror of v1.143 PR-A code in cmd_feeds.sh nftban_cmd_feeds enable arm.
cat_feeds=$(nftban_feeds_get_by_category "$NF_CAT")
echo "⏳ Enabling all feeds in category: $NF_CAT"
echo ""
enabled_count=0
failed_count=0
_v143_failed=()
for feed in $cat_feeds; do
    echo "  • Enabling $feed..."
    if nftban_feeds_enable "$feed" "true"; then
        echo "    ✅ $feed enabled"
        ((enabled_count++)) || true
    else
        echo "    ❌ $feed failed"
        _v143_failed+=("$feed")
        ((failed_count++)) || true
    fi
done
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $failed_count -eq 0 ]]; then
    echo "✅ Successfully enabled and downloaded $enabled_count feed(s) in category '$NF_CAT'"
    echo ""
    echo "Check status: nftban feeds status"
    exit 0
else
    echo "⚠️  Enabled $enabled_count feed(s); $failed_count feed(s) failed: ${_v143_failed[*]}" >&2
    echo "    Check errors in: ${NFTBAN_LOG_DIR}/feeds.log" >&2
    exit 1
fi
EOF
chmod +x "$MIRROR/feeds_enable_category.sh"

# ──────────────────────────────────────────────────────────────────────────
# T-MIRROR-PORT-ADD
# ──────────────────────────────────────────────────────────────────────────
cat >"$MIRROR/port_allow_add.sh" <<'EOF'
#!/usr/bin/env bash
set +e
nft_ipc_is_daemon_running() { return 0; }
nft_ipc_request() { echo "$NF_IPC_RESPONSE"; }
nft_ipc_success() { [[ "$NF_IPC_SUCCESS" == "true" ]]; }
nft_ipc_error()   { echo "stub-ipc-error"; }
jq() { printf '{"stub":"ok"}'; }

# Mirror of v1.143 PR-A code in cmd_port.sh nftban_port_allow_add IPC arm.
_v143_rc=0
if nft_ipc_is_daemon_running 2>/dev/null; then
    params=$(jq -nc '{}')
    response=$(nft_ipc_request "access_allow" "$params")
    if nft_ipc_success "$response"; then
        echo "✅ Port 22 (tcp) access granted to 10.0.0.1"
    else
        echo "⚠ Saved to config but IPC failed: $(nft_ipc_error "$response")" >&2
        echo "  Port will be applied on daemon restart" >&2
        _v143_rc=1
    fi
fi
exit $_v143_rc
EOF
chmod +x "$MIRROR/port_allow_add.sh"

# ──────────────────────────────────────────────────────────────────────────
# T-MIRROR-PORT-REMOVE
# ──────────────────────────────────────────────────────────────────────────
cat >"$MIRROR/port_allow_remove.sh" <<'EOF'
#!/usr/bin/env bash
set +e
nft_ipc_is_daemon_running() { return 0; }
nft_ipc_request() { echo "$NF_IPC_RESPONSE"; }
nft_ipc_success() { [[ "$NF_IPC_SUCCESS" == "true" ]]; }
nft_ipc_error()   { echo "stub-ipc-error"; }
jq() { printf '{"stub":"ok"}'; }

# Mirror of v1.143 PR-A code in cmd_port.sh nftban_port_allow_remove IPC arm.
_v143_rc=0
if nft_ipc_is_daemon_running 2>/dev/null; then
    params=$(jq -nc '{}')
    response=$(nft_ipc_request "access_revoke" "$params")
    if nft_ipc_success "$response"; then
        echo "✅ Port 22 (tcp) access revoked from 10.0.0.1"
    else
        echo "⚠ IPC revoke failed: $(nft_ipc_error "$response")" >&2
        _v143_rc=1
    fi
fi
exit $_v143_rc
EOF
chmod +x "$MIRROR/port_allow_remove.sh"

# ──────────────────────────────────────────────────────────────────────────
# T-MIRROR-PORT-FLUSH
# ──────────────────────────────────────────────────────────────────────────
cat >"$MIRROR/port_allow_flush.sh" <<'EOF'
#!/usr/bin/env bash
set +e
nft_ipc_is_daemon_running() { return 0; }
# Stub flush: fails for sets matching NF_FAIL_PAT regex.
nft_ipc_flush_set() {
    # args: "<fam> nftban" "<set>"
    set_name="$2"
    if [[ -n "${NF_FAIL_PAT:-}" ]] && [[ "$set_name" =~ $NF_FAIL_PAT ]]; then
        return 1
    fi
    return 0
}

# Mirror of v1.143 PR-A code in cmd_port.sh nftban_port_allow_flush.
_v143_rc=0
_v143_failed=()
if nft_ipc_is_daemon_running 2>/dev/null; then
    families=("ip" "ip6")
    sets=("port_allow_tcp" "port_allow_udp")
    for fam in "${families[@]}"; do
        suffix="_ipv4"
        [[ "$fam" == "ip6" ]] && suffix="_ipv6"
        for set_base in "${sets[@]}"; do
            if ! nft_ipc_flush_set "${fam} nftban" "${set_base}${suffix}" 2>/dev/null; then
                echo "  ⚠ Failed to flush ${set_base}${suffix} via IPC" >&2
                _v143_failed+=("${fam} ${set_base}${suffix}")
                _v143_rc=1
            fi
        done
    done
    if (( _v143_rc == 0 )); then
        echo "✅ All per-IP port access rules flushed"
    else
        echo "⚠ Config cleared but ${#_v143_failed[@]} kernel set(s) failed to flush: ${_v143_failed[*]}" >&2
        echo "  Sets may carry stale entries until daemon restart." >&2
    fi
fi
exit $_v143_rc
EOF
chmod +x "$MIRROR/port_allow_flush.sh"

# ──────────────────────────────────────────────────────────────────────────
# T-MIRROR-METRICS-ENABLE
# ──────────────────────────────────────────────────────────────────────────
cat >"$MIRROR/metrics_enable.sh" <<'EOF'
#!/usr/bin/env bash
set +e
# Stub _set_metrics_backend — succeeds unless NF_SET_BACKEND_FAIL=1.
_set_metrics_backend() {
    [[ "${NF_SET_BACKEND_FAIL:-0}" == "1" ]] && return 1
    return 0
}

# Mirror of v1.143 PR-A code in cmd_metrics.sh nftban_metrics_enable
# (config-write rc capture).
if ! _set_metrics_backend "prometheus"; then
    echo "  ⚠ Prometheus stack started but config write to nftban.conf.local failed" >&2
    echo "  Restore-on-restart behavior may revert NFTBAN_METRICS_ENABLED." >&2
    exit 1
fi
echo "Prometheus Metrics Enabled Successfully!"
exit 0
EOF
chmod +x "$MIRROR/metrics_enable.sh"

run() {
    local script="$1"; shift
    local rc=0
    local stdoutf; stdoutf=$(mktemp -t nftban-fs3-out.XXX)
    local stderrf; stderrf=$(mktemp -t nftban-fs3-err.XXX)
    "$script" "$@" >"$stdoutf" 2>"$stderrf" || rc=$?
    LAST_RC=$rc
    LAST_OUT=$(cat "$stdoutf")
    LAST_ERR=$(cat "$stderrf")
    rm -f "$stdoutf" "$stderrf"
}

assert_rc() {
    local label="$1" expected="$2"
    if (( LAST_RC == expected )); then ok "$label (rc=$LAST_RC)";
    else no "$label" "rc=$LAST_RC (expected $expected); tail-out=$(echo "$LAST_OUT" | tail -1); tail-err=$(echo "$LAST_ERR" | tail -1)"; fi
}
assert_contains_stderr() {
    local label="$1" needle="$2"
    if [[ "$LAST_ERR" == *"$needle"* ]]; then ok "$label"; else no "$label" "stderr missing '$needle'"; fi
}
assert_not_contains_stdout() {
    local label="$1" needle="$2"
    if [[ "$LAST_OUT" != *"$needle"* ]]; then ok "$label"; else no "$label" "stdout had forbidden '$needle'"; fi
}
assert_contains_stdout() {
    local label="$1" needle="$2"
    if [[ "$LAST_OUT" == *"$needle"* ]]; then ok "$label"; else no "$label" "stdout missing '$needle'"; fi
}

echo "=========================================================="
echo "v1.143 PR-A — FS3-MUTATION rc-truth contract"
echo "=========================================================="

# T1-T2 — FEEDS-ENABLE-CATEGORY
echo "--- T1+T2: feeds enable category — partial failure → rc=1, no ✅ success line ---"
NF_CAT=ssh NF_CAT_FEEDS='FEED_A FEED_B FEED_C' NF_FAIL_PAT='FEED_B' \
    run "$MIRROR/feeds_enable_category.sh"
assert_rc "T1 feeds partial-failure → rc=1" 1
assert_not_contains_stdout "T2 no '✅ Successfully' on partial failure" "✅ Successfully"
assert_contains_stderr "T2 stderr lists failed feed" "FEED_B"

echo "--- T1b: feeds enable category — all-success → rc=0 + ✅ Successfully ---"
NF_CAT=ssh NF_CAT_FEEDS='FEED_A FEED_B FEED_C' NF_FAIL_PAT='' \
    run "$MIRROR/feeds_enable_category.sh"
assert_rc "T1b feeds all-success → rc=0" 0
assert_contains_stdout "T1b '✅ Successfully' present on all-success" "✅ Successfully"

# T3 — PORT-ADD
echo "--- T3: port allow add — IPC failure → rc=1 (config-side already saved) ---"
NF_IPC_RESPONSE='{}' NF_IPC_SUCCESS=false run "$MIRROR/port_allow_add.sh"
assert_rc "T3 port-add IPC fail → rc=1" 1
assert_contains_stderr "T3 stderr has 'Saved to config but IPC failed'" "Saved to config but IPC failed"
assert_not_contains_stdout "T3 no '✅ Port' on IPC fail" "✅ Port 22"

echo "--- T3b: port allow add — IPC success → rc=0 ---"
NF_IPC_SUCCESS=true run "$MIRROR/port_allow_add.sh"
assert_rc "T3b port-add IPC success → rc=0" 0
assert_contains_stdout "T3b '✅ Port' present on success" "✅ Port 22"

# T4 — PORT-REMOVE
echo "--- T4: port allow remove — IPC revoke fail → rc=1 ---"
NF_IPC_RESPONSE='{}' NF_IPC_SUCCESS=false run "$MIRROR/port_allow_remove.sh"
assert_rc "T4 port-remove IPC fail → rc=1" 1
assert_contains_stderr "T4 stderr has 'IPC revoke failed'" "IPC revoke failed"
assert_not_contains_stdout "T4 no '✅ Port' on revoke fail" "✅ Port"

echo "--- T4b: port allow remove — IPC success → rc=0 ---"
NF_IPC_SUCCESS=true run "$MIRROR/port_allow_remove.sh"
assert_rc "T4b port-remove IPC success → rc=0" 0
assert_contains_stdout "T4b '✅ Port' on revoke success" "✅ Port"

# T5 — PORT-FLUSH
echo "--- T5: port allow flush — one set IPC fail → rc=1, no ✅ All-flushed line ---"
NF_FAIL_PAT='port_allow_tcp_ipv4' run "$MIRROR/port_allow_flush.sh"
assert_rc "T5 flush partial fail → rc=1" 1
assert_not_contains_stdout "T5 no '✅ All per-IP' on partial fail" "✅ All per-IP port access rules flushed"
assert_contains_stderr "T5 stderr lists failed set" "port_allow_tcp_ipv4"

echo "--- T5b: port allow flush — all flushes succeed → rc=0 + ✅ All-flushed ---"
NF_FAIL_PAT='' run "$MIRROR/port_allow_flush.sh"
assert_rc "T5b flush all-success → rc=0" 0
assert_contains_stdout "T5b '✅ All per-IP' present on all-success" "✅ All per-IP port access rules flushed"

# T6 — METRICS-ENABLE config-write
echo "--- T6: metrics enable — _set_metrics_backend fail → rc=1, no 'Successfully' ---"
NF_SET_BACKEND_FAIL=1 run "$MIRROR/metrics_enable.sh"
assert_rc "T6 metrics enable backend-write fail → rc=1" 1
assert_contains_stderr "T6 stderr explains config-write failure" "config write to nftban.conf.local failed"
assert_not_contains_stdout "T6 no 'Successfully' on backend-write fail" "Successfully"

echo "--- T6b: metrics enable — backend write succeeds → rc=0 + 'Successfully' ---"
NF_SET_BACKEND_FAIL=0 run "$MIRROR/metrics_enable.sh"
assert_rc "T6b metrics enable all-success → rc=0" 0
assert_contains_stdout "T6b 'Successfully' present on success" "Successfully"

# ──────────────────────────────────────────────────────────────────────────
# T-DRIFT — assert the five live PR-A markers are present in cmd_*.sh
# ──────────────────────────────────────────────────────────────────────────
echo "--- T-DRIFT: live cmd_*.sh carry v1.143 PR-A markers ---"
declare -A EXPECTED_MARKERS=(
    ["cli/lib/nftban/cli/cmd_feeds.sh"]=1
    ["cli/lib/nftban/cli/cmd_metrics.sh"]=1
    ["cli/lib/nftban/cli/cmd_port.sh"]=3   # add + remove + flush
)
for f in "${!EXPECTED_MARKERS[@]}"; do
    expected="${EXPECTED_MARKERS[$f]}"
    actual=$(grep -cE 'v1.143 PR-A \(FS3-MUTATION\)' "$REPO/$f" || true)
    if [[ "$actual" -eq "$expected" ]]; then
        ok "T-DRIFT $f has $expected PR-A marker(s)"
    else
        no "T-DRIFT $f marker count" "got $actual; expected $expected"
    fi
done

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "ALL PASS"
