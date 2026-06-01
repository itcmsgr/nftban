#!/usr/bin/env bash
# =============================================================================
# NFTBan - exporter EXIT2 Phase 3 test (v1.143.1 EXPORTER-PHASE-3)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_exporter_exit2_phase_3_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-01"
# meta:description="v1.143.1 EXPORTER-PHASE-3 — asserts that the two new ERR-trap-pinpointed exporter SIGTERM sites surfaced during the v1.142.0 fleet rollout are now resilient. Site A: botguard legacy-kernel jq pipeline at cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh — validity gate (jq -e '.botguard') ONCE plus per-call '|| bg_X=0' belt-and-suspenders. Site B: systemctl-show ActiveEnterTimestamp — bounded 'timeout 2s' caps the dbus query so SIGTERM mid-systemctl-show falls through to the '|| echo ""' fallback (operator-selected SELECT_V1_143_EXPORTER_PHASE_3_SITE_B = bounded-timeout, TIMEOUT_SECONDS = 2). Stubbed-callable mirror pattern (same as v1.142 PR-FS + v1.143 PR-A/B tests). Hermetic — no host contact; no real systemctl, no real jq pipe to real daemon. T-DRIFT row asserts the two PR markers stay in the live file."
# meta:input="cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,jq,timeout"
# meta:inventory.files="cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh"
# meta:inventory.binaries="bash,grep,jq,timeout"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_RUN_DIR"
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
export NFTBAN_NONINTERACTIVE=1

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v timeout >/dev/null 2>&1 || { echo "SKIP: coreutils 'timeout' not installed"; exit 0; }

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

# Stubbed-callable mirror: extract the two Phase-3 patches as standalone
# scripts so each test row can drive them with controlled inputs. cmd_*.sh
# refuses to source standalone under strict.sh in this dev environment
# (same pattern as v1.142 PR-FS test). Drift between this mirror and the
# live exporter is caught by T-DRIFT at the bottom.
MIRROR=$(mktemp -d -t nftban-phase3.XXXXXX)
trap 'rm -rf "$MIRROR"' EXIT

# ──────────────────────────────────────────────────────────────────────────
# Site A mirror — botguard legacy-kernel branch validity gate + belt-suspenders
# ──────────────────────────────────────────────────────────────────────────
cat >"$MIRROR/site_a.sh" <<'EOF'
#!/usr/bin/env bash
set +e
# Inputs (env):
#   NF_COUNTS_JSON  — the $counts_json input string
#   NF_JQ_FAIL_PAT  — if non-empty, stub `jq` fails when arg matches this regex
counts_json="${NF_COUNTS_JSON-}"

# Stub jq when NF_JQ_FAIL_PAT set; otherwise use real jq.
if [[ -n "${NF_JQ_FAIL_PAT:-}" ]]; then
    jq() {
        # forward to real jq, but fail if last arg matches NF_JQ_FAIL_PAT
        for a in "$@"; do
            if [[ "$a" =~ $NF_JQ_FAIL_PAT ]]; then
                return 1
            fi
        done
        command jq "$@"
    }
fi

# Locals init exactly like the live exporter at line 234
bg_suspect=0 bg_pending=0 bg_allow=0 bg_grey=0 bg_ban=0 bg_emergency=0

# Mirror of v1.143.1 EXPORTER-PHASE-3 (Site A) legacy-kernel branch.
if [[ -n "${counts_json:-}" ]] && command -v jq &>/dev/null; then
    if echo "$counts_json" | jq -e '.sets' &>/dev/null; then
        # daemon-cache format — out of scope for this site
        :
    else
        if echo "$counts_json" | jq -e '.botguard' &>/dev/null; then
            bg_suspect=$(echo "$counts_json"   | jq -r '((.botguard.suspect.ipv4 // 0)   + (.botguard.suspect.ipv6 // 0))'   2>/dev/null) || bg_suspect=0
            bg_pending=$(echo "$counts_json"   | jq -r '((.botguard.pending.ipv4 // 0)   + (.botguard.pending.ipv6 // 0))'   2>/dev/null) || bg_pending=0
            bg_allow=$(echo "$counts_json"     | jq -r '((.botguard.allow.ipv4 // 0)     + (.botguard.allow.ipv6 // 0))'     2>/dev/null) || bg_allow=0
            bg_grey=$(echo "$counts_json"      | jq -r '((.botguard.grey.ipv4 // 0)      + (.botguard.grey.ipv6 // 0))'      2>/dev/null) || bg_grey=0
            bg_ban=$(echo "$counts_json"       | jq -r '((.botguard.ban.ipv4 // 0)       + (.botguard.ban.ipv6 // 0))'       2>/dev/null) || bg_ban=0
            bg_emergency=$(echo "$counts_json" | jq -r '((.botguard.emergency.ipv4 // 0) + (.botguard.emergency.ipv6 // 0))' 2>/dev/null) || bg_emergency=0
        fi
    fi
    # Pre-existing numeric-validity sweep (unchanged by Phase-3)
    [[ "$bg_suspect" =~ ^[0-9]+$ ]] || bg_suspect=0
    [[ "$bg_pending" =~ ^[0-9]+$ ]] || bg_pending=0
    [[ "$bg_allow" =~ ^[0-9]+$ ]] || bg_allow=0
    [[ "$bg_grey" =~ ^[0-9]+$ ]] || bg_grey=0
    [[ "$bg_ban" =~ ^[0-9]+$ ]] || bg_ban=0
    [[ "$bg_emergency" =~ ^[0-9]+$ ]] || bg_emergency=0
fi

# Emit one line per counter for assertion
echo "bg_suspect=$bg_suspect"
echo "bg_pending=$bg_pending"
echo "bg_allow=$bg_allow"
echo "bg_grey=$bg_grey"
echo "bg_ban=$bg_ban"
echo "bg_emergency=$bg_emergency"
exit 0
EOF
chmod +x "$MIRROR/site_a.sh"

# ──────────────────────────────────────────────────────────────────────────
# Site B mirror — systemctl-show with bounded timeout. Uses a PATH-shadow
# stub (not a bash function) because `timeout 2s systemctl …` spawns
# systemctl via execvp() inside the timeout child process, which does NOT
# inherit bash functions — only PATH-resolved binaries. The stub script
# must therefore live in a real file with PATH set to find it first.
# ──────────────────────────────────────────────────────────────────────────
mkdir -p "$MIRROR/path_b"
cat >"$MIRROR/path_b/systemctl" <<'EOF'
#!/usr/bin/env bash
# PATH-shadow systemctl stub for Site B test. Behaviour driven by env.
case "${NF_SYSTEMCTL_MODE:-ok}" in
    ok)
        echo "${NF_TIMESTAMP_OUTPUT-Mon 2026-05-29 12:00:00 UTC}"
        exit 0
        ;;
    sleep)
        sleep "${NF_SYSTEMCTL_SLEEP_SEC:-0}"
        echo "${NF_TIMESTAMP_OUTPUT-Mon 2026-05-29 12:00:00 UTC}"
        exit 0
        ;;
    fail)
        exit 1
        ;;
    *)
        echo "${NF_TIMESTAMP_OUTPUT-Mon 2026-05-29 12:00:00 UTC}"
        exit 0
        ;;
esac
EOF
chmod +x "$MIRROR/path_b/systemctl"

cat >"$MIRROR/site_b.sh" <<EOF
#!/usr/bin/env bash
set +e
# Put our PATH-shadow stub FIRST so 'timeout 2s systemctl …' finds it.
export PATH="$MIRROR/path_b:\$PATH"

# Mirror of v1.143.1 EXPORTER-PHASE-3 (Site B) — keep byte-for-byte
# alignment with the live exporter line for the drift test.
local_timestamp=\$(date +%s)
start_time=""
start_time=\$(timeout 2s systemctl show nftband.service -p ActiveEnterTimestamp --value 2>/dev/null || echo "")
echo "start_time_empty=\$([[ -z "\$start_time" ]] && echo true || echo false)"
echo "start_time=\$start_time"

uptime=0
if [[ -n "\$start_time" ]]; then
    start_epoch=\$(date -d "\$start_time" +%s 2>/dev/null || echo "\$local_timestamp")
    uptime=\$((local_timestamp - start_epoch))
fi
echo "uptime_nonzero=\$([[ \$uptime -gt 0 ]] && echo true || echo false)"
exit 0
EOF
chmod +x "$MIRROR/site_b.sh"

run() {
    local script="$1"; shift
    local rc=0 out
    local elapsed_start elapsed_end elapsed_ms
    elapsed_start=$(date +%s%N)
    out=$("$script" "$@" 2>&1) || rc=$?
    elapsed_end=$(date +%s%N)
    elapsed_ms=$(( (elapsed_end - elapsed_start) / 1000000 ))
    LAST_RC=$rc
    LAST_OUT=$out
    LAST_ELAPSED_MS=$elapsed_ms
}

assert_eq() {
    local label="$1" key="$2" want="$3"
    local got
    got=$(echo "$LAST_OUT" | grep "^${key}=" | head -1 | cut -d= -f2-)
    if [[ "$got" == "$want" ]]; then ok "$label ($key=$got)"
    else no "$label" "$key='$got' (expected '$want')"; fi
}
assert_rc() {
    local label="$1" expected="$2"
    if (( LAST_RC == expected )); then ok "$label (rc=$LAST_RC)"
    else no "$label" "rc=$LAST_RC (expected $expected); out=$LAST_OUT"; fi
}

echo "=========================================================="
echo "v1.143.1 EXPORTER-PHASE-3 — Site A + Site B rc=143 race fixes"
echo "=========================================================="

# ──────────────────────────────────────────────────────────────────────────
# T1 — Site A botguard legacy-kernel branch
# ──────────────────────────────────────────────────────────────────────────
echo "--- T1-A1: valid counts_json with .botguard legacy-kernel format ---"
NF_COUNTS_JSON='{"botguard":{"suspect":{"ipv4":3,"ipv6":2},"pending":{"ipv4":1,"ipv6":0},"allow":{"ipv4":7,"ipv6":4},"grey":{"ipv4":0,"ipv6":0},"ban":{"ipv4":12,"ipv6":3},"emergency":{"ipv4":0,"ipv6":0}}}' \
    run "$MIRROR/site_a.sh"
assert_rc "T1-A1 site_a all-valid rc=0" 0
assert_eq "T1-A1 bg_suspect (3+2=5)" bg_suspect 5
assert_eq "T1-A1 bg_pending (1+0=1)" bg_pending 1
assert_eq "T1-A1 bg_ban (12+3=15)"   bg_ban     15

echo "--- T1-A2: valid counts_json but .botguard key MISSING → all six stay at 0 ---"
NF_COUNTS_JSON='{"some_other_root_key":{"x":1}}' run "$MIRROR/site_a.sh"
assert_rc "T1-A2 site_a missing-key rc=0" 0
assert_eq "T1-A2 bg_suspect stays 0"   bg_suspect   0
assert_eq "T1-A2 bg_pending stays 0"   bg_pending   0
assert_eq "T1-A2 bg_allow stays 0"     bg_allow     0
assert_eq "T1-A2 bg_grey stays 0"      bg_grey      0
assert_eq "T1-A2 bg_ban stays 0"       bg_ban       0
assert_eq "T1-A2 bg_emergency stays 0" bg_emergency 0

echo "--- T1-A3: truncated counts_json → outer validity gate fails; no ERR trap fire ---"
NF_COUNTS_JSON='{"botguard":{"suspect":{"ipv4":3' run "$MIRROR/site_a.sh"
assert_rc "T1-A3 site_a truncated-json rc=0 (no abort)" 0
assert_eq "T1-A3 bg_suspect stays 0"   bg_suspect   0
assert_eq "T1-A3 bg_pending stays 0"   bg_pending   0

echo "--- T1-A4: per-call jq returns empty (stub forces failure on specific counter) ---"
NF_COUNTS_JSON='{"botguard":{"suspect":{"ipv4":3,"ipv6":2}}}' \
NF_JQ_FAIL_PAT='allow' run "$MIRROR/site_a.sh"
# This test exercises the belt-and-suspenders pattern: most counters succeed,
# but the "allow" counter's jq call is forced to fail. The `|| bg_allow=0`
# fallback catches it; rc still 0.
assert_rc "T1-A4 site_a per-jq-fail rc=0 (belt-suspenders catches)" 0
assert_eq "T1-A4 bg_suspect (3+2=5) still works" bg_suspect 5
assert_eq "T1-A4 bg_allow stays 0 (forced fail)" bg_allow   0

echo "--- T1-A5: counts_json with non-numeric (jq returns 'null' or string) → final sweep catches ---"
# jq's `// 0` defaulting makes this hard to hit naturally; verify the post-sweep
# numeric-validity gate is unchanged-by-Phase-3 and still catches edge cases.
# Force a malformed shape that jq returns 'null' for.
NF_COUNTS_JSON='{"botguard":{"suspect":"not-a-number"}}' run "$MIRROR/site_a.sh"
assert_rc "T1-A5 site_a malformed-shape rc=0" 0
# jq's `(.botguard.suspect.ipv4 // 0) + …` on a string field returns an error;
# `// 0` only fires on null/missing. So `|| bg_suspect=0` fallback OR the
# final numeric-validity sweep catches it. Either way: 0.
assert_eq "T1-A5 bg_suspect=0 on malformed shape" bg_suspect 0

# ──────────────────────────────────────────────────────────────────────────
# T2 — Site B systemctl-show with bounded timeout
# ──────────────────────────────────────────────────────────────────────────
echo "--- T2-B1: systemctl returns valid timestamp quickly ---"
NF_SYSTEMCTL_MODE=ok NF_TIMESTAMP_OUTPUT="Mon 2026-05-29 12:00:00 UTC" \
    run "$MIRROR/site_b.sh"
assert_rc "T2-B1 site_b happy-path rc=0" 0
assert_eq "T2-B1 start_time non-empty" start_time_empty false
assert_eq "T2-B1 uptime computed (nonzero)" uptime_nonzero true

echo "--- T2-B2: systemctl returns empty (e.g. unit not active) ---"
NF_SYSTEMCTL_MODE=ok NF_TIMESTAMP_OUTPUT="" run "$MIRROR/site_b.sh"
assert_rc "T2-B2 site_b empty-output rc=0" 0
assert_eq "T2-B2 start_time empty" start_time_empty true
assert_eq "T2-B2 uptime stays 0 (no compute)" uptime_nonzero false

echo "--- T2-B3: systemctl hangs >timeout → 'timeout 2s' kills it, start_time empty ---"
# Stub sleeps 4 s — exceeds the 2 s timeout, so `timeout` kills systemctl
# and the `|| echo ""` falls through. Total elapsed should be ~2 s, NOT 4 s.
NF_SYSTEMCTL_MODE=sleep NF_SYSTEMCTL_SLEEP_SEC=4 run "$MIRROR/site_b.sh"
assert_rc "T2-B3 site_b timeout-kills-systemctl rc=0 (no abort)" 0
assert_eq "T2-B3 start_time empty (timeout fired)" start_time_empty true
assert_eq "T2-B3 uptime stays 0" uptime_nonzero false
# Verify elapsed wall-clock proves the timeout actually fired (~2s, < 4s sleep)
if (( LAST_ELAPSED_MS < 3500 )); then
    ok "T2-B3 elapsed=${LAST_ELAPSED_MS}ms (< 3500ms proves 'timeout 2s' fired before 4s sleep)"
else
    no "T2-B3 timeout effectiveness" "elapsed=${LAST_ELAPSED_MS}ms (expected <3500ms; the 2s bound did not fire)"
fi

echo "--- T2-B4: systemctl exits 1 immediately → || echo \"\" catches ---"
NF_SYSTEMCTL_MODE=fail run "$MIRROR/site_b.sh"
assert_rc "T2-B4 site_b fail-fast rc=0" 0
assert_eq "T2-B4 start_time empty on non-zero exit" start_time_empty true

# ──────────────────────────────────────────────────────────────────────────
# T-DRIFT — assert the two PR-Phase-3 markers stay in the live exporter
# ──────────────────────────────────────────────────────────────────────────
echo "--- T-DRIFT: live exporter carries v1.143.1 EXPORTER-PHASE-3 markers ---"
LIVE="$REPO/cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh"
SITE_A_MARKER='v1.143.1 EXPORTER-PHASE-3 (Site A)'
SITE_B_MARKER='v1.143.1 EXPORTER-PHASE-3 (Site B)'
if grep -qF "$SITE_A_MARKER" "$LIVE"; then ok "T-DRIFT Site A marker present"
else no "T-DRIFT Site A marker" "missing from $LIVE"; fi
if grep -qF "$SITE_B_MARKER" "$LIVE"; then ok "T-DRIFT Site B marker present"
else no "T-DRIFT Site B marker" "missing from $LIVE"; fi

# Verify Site B has `timeout 2s` (the bounded-timeout sub-option chosen)
if grep -qE 'timeout 2s systemctl show nftband.service' "$LIVE"; then
    ok "T-DRIFT Site B 'timeout 2s' bound present"
else
    no "T-DRIFT Site B 'timeout 2s'" "bounded-timeout sub-option not landed"
fi

# Verify Site A has the `if echo "\$counts_json" | jq -e '.botguard'` validity gate
if grep -qE "if echo .\\\$counts_json. \\| jq -e '\.botguard'" "$LIVE"; then
    ok "T-DRIFT Site A '.botguard' validity gate present"
else
    no "T-DRIFT Site A '.botguard' validity gate" "single-validity-gate sub-option not landed"
fi

# Verify Site A has the `|| bg_X=0` belt-suspenders on at least one counter
if grep -qE '\|\| bg_suspect=0' "$LIVE"; then
    ok "T-DRIFT Site A belt-suspenders '|| bg_suspect=0' present"
else
    no "T-DRIFT Site A belt-suspenders" "per-call fallback not landed"
fi

# Verify the v1.136 Phase 2 :642 set_counts.json fix is UNCHANGED (regression guard)
if grep -qF 'v1.136.1 (Phase 2)' "$LIVE"; then
    ok "T-DRIFT v1.136 Phase 2 :642 marker still present (regression guard)"
else
    no "T-DRIFT v1.136 Phase 2 marker" "the prior fix was disturbed"
fi

echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then
    printf 'FAILED: %s\n' "${FAILED[@]}"
    exit 1
fi
echo "ALL PASS"
