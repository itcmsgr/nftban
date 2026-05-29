#!/usr/bin/env bash
# =============================================================================
# NFTBan - FS3-DA rc-swallow regression test (v1.143 PR-B)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_fs3_da_v143_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-29"
# meta:description="v1.143 PR-B — asserts that the two FS3-class DA / permissions functions propagate child-operation rc truthfully. Pre-v1.143 nftban_port_allow_directadmin swallowed CloudFlare trust enable+update failure (licensing-critical path) under an unconditional `return 0`; nftban_permissions_cmd_enforce already returned truthful rc but printed ❌ to stdout with no actionable advice, leaving the lab4 v1.142 installer's swallowed 'permissions enforce failed (exit 1) — non-fatal' line without an audit trail. Same FS3 family as v1.142 PR-FS and v1.143 PR-A. Stubbed-callable mirror pattern matches PR-A test."
# meta:input="cli/lib/nftban/cli/cmd_port.sh, cli/lib/nftban/cli/cmd_permissions.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files="cli/lib/nftban/cli/cmd_port.sh,cli/lib/nftban/cli/cmd_permissions.sh"
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

MIRROR=$(mktemp -d -t nftban-fs3da.XXXXXX)
trap 'rm -rf "$MIRROR"' EXIT

# ──────────────────────────────────────────────────────────────────────────
# T-MIRROR-PERMISSIONS  —  nftban_permissions_cmd_enforce wrapper
# ──────────────────────────────────────────────────────────────────────────
cat >"$MIRROR/permissions_enforce.sh" <<'EOF'
#!/usr/bin/env bash
set +e
# Stub the per-step helper. Returns rc based on NF_HELPER_RC env var.
nftban_permissions_enforce_all() {
    return "${NF_HELPER_RC:-0}"
}
# Pretend we're root so the EUID gate doesn't fire (the gate isn't on the
# FS3 surface — the wrapper-around-helper rc is).
NFTBAN_LOG_DIR=/tmp

# Mirror of v1.143 PR-B code in cmd_permissions.sh nftban_permissions_cmd_enforce
# (just the post-EUID-gate enforcement section).
result=0
nftban_permissions_enforce_all || result=$?

if [[ $result -eq 0 ]]; then
    echo ""
    echo "✅ Permissions enforced successfully"
else
    {
        echo ""
        echo "❌ Permission enforcement failed with errors"
        echo "   See log: ${NFTBAN_LOG_DIR:-/var/log/nftban}/installer.log"
        echo "   Re-check: nftban permissions check"
        echo "   Re-run:   sudo nftban permissions enforce"
    } >&2
fi
exit $result
EOF
chmod +x "$MIRROR/permissions_enforce.sh"

# ──────────────────────────────────────────────────────────────────────────
# T-MIRROR-DA  —  nftban_port_allow_directadmin CloudFlare arm
# ──────────────────────────────────────────────────────────────────────────
cat >"$MIRROR/directadmin_cf.sh" <<'EOF'
#!/usr/bin/env bash
set +e
# Stub nftban: trust enable + update either succeed or fail based on env.
nftban() {
    case "$1 $2" in
        "trust enable")
            [[ "${NF_TRUST_ENABLE_FAIL:-0}" == "1" ]] && return 1
            return 0
            ;;
        "trust update"|"trust update ")
            [[ "${NF_TRUST_UPDATE_FAIL:-0}" == "1" ]] && return 1
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

# Mirror of v1.143 PR-B CloudFlare-arm code in cmd_port.sh.
_v143_da_rc=0
enable_cloudflare="${NF_ENABLE_CF:-yes}"
if [[ "$enable_cloudflare" == "yes" ]]; then
    echo "Enabling CloudFlare whitelist..."
    if nftban trust enable CLOUDFLARE 2>/dev/null && nftban trust update 2>/dev/null; then
        echo "✓ CloudFlare whitelist enabled"
    else
        {
            echo "⚠️  Failed to enable CloudFlare whitelist"
            echo "    DirectAdmin licensing REQUIRES this — operator action required."
            echo "    Re-run manually: nftban trust enable CLOUDFLARE && nftban trust update"
        } >&2
        _v143_da_rc=1
    fi
fi
exit $_v143_da_rc
EOF
chmod +x "$MIRROR/directadmin_cf.sh"

run() {
    local script="$1"; shift
    local rc=0
    local stdoutf; stdoutf=$(mktemp -t nftban-fs3da-out.XXX)
    local stderrf; stderrf=$(mktemp -t nftban-fs3da-err.XXX)
    "$script" "$@" >"$stdoutf" 2>"$stderrf" || rc=$?
    LAST_RC=$rc
    LAST_OUT=$(cat "$stdoutf")
    LAST_ERR=$(cat "$stderrf")
    rm -f "$stdoutf" "$stderrf"
}

assert_rc() {
    local label="$1" expected="$2"
    if (( LAST_RC == expected )); then ok "$label (rc=$LAST_RC)";
    else no "$label" "rc=$LAST_RC (expected $expected)"; fi
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
echo "v1.143 PR-B — FS3-DA rc-truth contract"
echo "=========================================================="

# ──────────────────────────────────────────────────────────────────────────
# T-PERMS — nftban_permissions_cmd_enforce wrapper rc-truth + stderr advice
# ──────────────────────────────────────────────────────────────────────────
echo "--- T-PERMS-1: permissions enforce helper fail → rc=1, ❌ to STDERR, no '✅' on STDOUT ---"
NF_HELPER_RC=1 run "$MIRROR/permissions_enforce.sh"
assert_rc "T-PERMS-1a permissions wrapper rc=1 on helper fail" 1
assert_contains_stderr "T-PERMS-1b ❌ failure line on STDERR" "❌ Permission enforcement failed"
assert_contains_stderr "T-PERMS-1c log location advice on STDERR" "/installer.log"
assert_contains_stderr "T-PERMS-1d re-run advice on STDERR" "Re-run:"
assert_not_contains_stdout "T-PERMS-1e no '✅' on STDOUT on failure" "✅ Permissions enforced"

echo "--- T-PERMS-2: permissions enforce helper succeeds → rc=0, ✅ to STDOUT, no ❌ ---"
NF_HELPER_RC=0 run "$MIRROR/permissions_enforce.sh"
assert_rc "T-PERMS-2a rc=0 on helper success" 0
assert_contains_stdout "T-PERMS-2b ✅ on STDOUT" "✅ Permissions enforced successfully"
assert_not_contains_stdout "T-PERMS-2c no ❌ on STDOUT" "❌"

# ──────────────────────────────────────────────────────────────────────────
# T-DA — nftban_port_allow_directadmin CloudFlare arm rc-truth
# ──────────────────────────────────────────────────────────────────────────
echo "--- T-DA-1: trust enable fails → rc=1, ⚠ to STDERR, no '✓ enabled' on STDOUT ---"
NF_ENABLE_CF=yes NF_TRUST_ENABLE_FAIL=1 NF_TRUST_UPDATE_FAIL=0 run "$MIRROR/directadmin_cf.sh"
assert_rc "T-DA-1a directadmin rc=1 on trust-enable fail" 1
assert_contains_stderr "T-DA-1b ⚠ to STDERR" "Failed to enable CloudFlare whitelist"
assert_contains_stderr "T-DA-1c 'licensing REQUIRES this' on STDERR" "REQUIRES this"
assert_contains_stderr "T-DA-1d manual-remediation hint on STDERR" "Re-run manually:"
assert_not_contains_stdout "T-DA-1e no '✓ CloudFlare whitelist enabled' on STDOUT" "✓ CloudFlare whitelist enabled"

echo "--- T-DA-2: trust update fails → rc=1 ---"
NF_ENABLE_CF=yes NF_TRUST_ENABLE_FAIL=0 NF_TRUST_UPDATE_FAIL=1 run "$MIRROR/directadmin_cf.sh"
assert_rc "T-DA-2a directadmin rc=1 on trust-update fail" 1
assert_contains_stderr "T-DA-2b ⚠ on STDERR" "Failed to enable CloudFlare whitelist"

echo "--- T-DA-3: trust enable+update both succeed → rc=0 + ✓ enabled ---"
NF_ENABLE_CF=yes NF_TRUST_ENABLE_FAIL=0 NF_TRUST_UPDATE_FAIL=0 run "$MIRROR/directadmin_cf.sh"
assert_rc "T-DA-3a directadmin rc=0 on full success" 0
assert_contains_stdout "T-DA-3b '✓ CloudFlare whitelist enabled' on STDOUT" "✓ CloudFlare whitelist enabled"
assert_not_contains_stdout "T-DA-3c no ⚠ on STDOUT" "Failed to enable CloudFlare"

echo "--- T-DA-4: CloudFlare arm disabled → rc=0 (no trust calls) ---"
NF_ENABLE_CF=no NF_TRUST_ENABLE_FAIL=1 NF_TRUST_UPDATE_FAIL=1 run "$MIRROR/directadmin_cf.sh"
assert_rc "T-DA-4 rc=0 when CF arm disabled (skip path)" 0

# ──────────────────────────────────────────────────────────────────────────
# T-DRIFT — assert live PR-B markers are present
# ──────────────────────────────────────────────────────────────────────────
echo "--- T-DRIFT: live cmd_*.sh carry v1.143 PR-B markers ---"
declare -A EXPECTED_MARKERS=(
    ["cli/lib/nftban/cli/cmd_port.sh"]=2          # CloudFlare arm + final return marker
    ["cli/lib/nftban/cli/cmd_permissions.sh"]=1   # wrapper rc-truth + actionable advice
)
for f in "${!EXPECTED_MARKERS[@]}"; do
    expected="${EXPECTED_MARKERS[$f]}"
    actual=$(grep -cE 'v1.143 PR-B \(FS3-DA\)' "$REPO/$f" || true)
    if [[ "$actual" -eq "$expected" ]]; then
        ok "T-DRIFT $f has $expected PR-B marker(s)"
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
