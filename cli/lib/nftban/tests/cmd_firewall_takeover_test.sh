#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.117 firewall takeover discoverability
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_firewall_takeover_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-16"
# meta:description="Tests for v1.117 firewall takeover + update --panel-auto-takeover CLI surfaces"
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,python3"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_INSTALLER_BIN"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Purpose: Cover the v1.117 firewall-takeover discoverability surface:
#   - nftban firewall takeover dispatcher (cmd_firewall.sh)
#   - nftban update --panel-auto-takeover env-mirror forwarding (cmd_update.sh)
#   - help output, root/dry-run gating, argv forwarding to installer stub.
# Self-contained sandbox; no host contact; no real installer invocation.
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

# Installer stub: a real script on PATH that records its argv + env and
# exits 0. The cmd_firewall.sh `exec` of the installer would normally
# replace the test shell; we override via NFTBAN_INSTALLER_BIN to point
# at this stub. The stub's argv/env trace is written to a file the test
# reads after each invocation.
INSTALLER_STUB="$SANDBOX/bin/nftban-installer"
INSTALLER_LOG="$SANDBOX/installer.log"
mkdir -p "$SANDBOX/bin"
cat > "$INSTALLER_STUB" <<'STUB_EOF'
#!/usr/bin/env bash
{
    echo "argv: $*"
    echo "NFTBAN_PANEL_AUTO_TAKEOVER=${NFTBAN_PANEL_AUTO_TAKEOVER:-unset}"
    echo "NFTBAN_JSON=${NFTBAN_JSON:-unset}"
} >> "${INSTALLER_LOG:-/dev/null}"
exit 0
STUB_EOF
chmod +x "$INSTALLER_STUB"
export NFTBAN_INSTALLER_BIN="$INSTALLER_STUB"
export INSTALLER_LOG

# Bypass dependency-laden bootstrap of cmd_firewall.sh / cmd_update.sh.
export NFTBAN_RUN_DIR="$SANDBOX/run"
export NFTBAN_LOG_DIR="$SANDBOX/log"
export NFTBAN_CACHE_DIR="$SANDBOX/cache"
export NFTBAN_CONFIG_DIR="$SANDBOX/etc"
export NFTBAN_DATA_DIR="$SANDBOX/data"
mkdir -p "$NFTBAN_RUN_DIR" "$NFTBAN_LOG_DIR" "$NFTBAN_CACHE_DIR" "$NFTBAN_CONFIG_DIR" "$NFTBAN_DATA_DIR"
export NFTBAN_DISTRO_CONFIG_LOADED=1
export NFTBAN_FIREWALL_LOADED=1   # speculative guard; harmless if absent

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

reset_installer_log() {
    : > "$INSTALLER_LOG"
}

# ---------------------------------------------------------------------------
# Wrapper: invoke firewall_takeover in a subshell so its `exec` doesn't
# replace the test runner. The subshell exec's the stub installer, which
# writes to INSTALLER_LOG and exits, ending the subshell.
# ---------------------------------------------------------------------------
call_firewall_takeover() {
    # shellcheck disable=SC2317  # function is called below via subshell
    (
        set +e
        # Re-source minimum: cmd_firewall.sh requires its own bootstrap.
        # To keep this test self-contained without dragging the whole
        # NFTBAN_LIB_DIR runtime, we extract firewall_takeover from the
        # source file and re-source ONLY that function plus the dispatcher.
        # The function is self-contained — no external helper required.
        eval "$(awk '
            /^# SUBCOMMAND: TAKEOVER/,/^# =========.*$/ { print }
            /^firewall_takeover\(\)/,/^}$/ { print }
        ' "$NFTBAN_LIB_DIR/cli/cmd_firewall.sh")"
        firewall_takeover "$@"
    )
}

# ---------------------------------------------------------------------------
# Wrapper: invoke the update dispatcher's argv-stripping logic without
# running the full update pipeline. We extract just the nftban_cmd_update
# preamble (the new v1.117 filter) and verify env-mirror is set.
# ---------------------------------------------------------------------------
call_update_with_panel_flag() {
    (
        set +e
        # Source only the dispatcher header (preamble + flag-strip).
        # cmd_update.sh's full body has dependencies we don't need here;
        # this test focuses on the flag-strip side-effect.
        local _stub_dispatcher
        _stub_dispatcher=$(awk '
            /^nftban_cmd_update\(\)/ { capture=1 }
            capture { print }
            capture && /^    case "\$cmd" in/ { print "        *) return 0 ;;"; print "    esac"; print "}"; exit }
        ' "$NFTBAN_LIB_DIR/cli/cmd_update.sh")
        eval "$_stub_dispatcher"
        unset NFTBAN_PANEL_AUTO_TAKEOVER
        nftban_cmd_update "$@" >/dev/null 2>&1 || true
        # Emit the env-mirror value for the test runner to capture.
        printf 'NFTBAN_PANEL_AUTO_TAKEOVER=%s\n' "${NFTBAN_PANEL_AUTO_TAKEOVER:-unset}"
    )
}

echo "================================================="
echo "v1.117 firewall takeover discoverability test suite"
echo "================================================="

# ---------------------------------------------------------------------------
# T1: --help / -h exits 0 with usage text
# ---------------------------------------------------------------------------
echo
echo "[T1] firewall takeover --help"
reset_installer_log
T1_OUT=$(call_firewall_takeover --help 2>&1)
assert_contains "$T1_OUT" "Usage: nftban firewall takeover"          "T1.1 Usage line"
assert_contains "$T1_OUT" "--panel-auto-takeover"                    "T1.2 flag mentioned"
assert_contains "$T1_OUT" "--dry-run"                                "T1.3 dry-run mentioned"
assert_contains "$T1_OUT" "REVERSIBLE"                               "T1.4 reversibility callout"
assert_contains "$T1_OUT" "NFTBAN_PANEL_AUTO_TAKEOVER=1"             "T1.5 env mirror documented"

# ---------------------------------------------------------------------------
# T2: bare invocation (no flags) refuses with operator-actionable error
# ---------------------------------------------------------------------------
echo
echo "[T2] firewall takeover (no flags) refuses"
reset_installer_log
T2_OUT=$(call_firewall_takeover 2>&1 || true)
assert_contains "$T2_OUT" "requires --panel-auto-takeover or --dry-run"  "T2.1 refusal explains gate"
[[ ! -s "$INSTALLER_LOG" ]] && {
    printf "  [PASS] %s\n" "T2.2 installer not invoked (no flags)"
    PASS=$((PASS + 1))
} || {
    printf "  [FAIL] %s\n" "T2.2 installer not invoked (no flags)"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("T2.2")
}

# ---------------------------------------------------------------------------
# T3: --dry-run path invokes installer with correct argv (no root required)
# ---------------------------------------------------------------------------
echo
echo "[T3] firewall takeover --dry-run"
reset_installer_log
call_firewall_takeover --dry-run >/dev/null 2>&1 || true
T3_LOG=$(cat "$INSTALLER_LOG" 2>/dev/null || true)
assert_contains "$T3_LOG" "argv: --mode=upgrade --dry-run"           "T3.1 installer argv includes mode + dry-run"
assert_not_contains "$T3_LOG" "--panel-auto-takeover"                "T3.2 dry-run alone does NOT include --panel-auto-takeover"

# ---------------------------------------------------------------------------
# T4: --panel-auto-takeover path invokes installer with correct argv
# ---------------------------------------------------------------------------
echo
echo "[T4] firewall takeover --panel-auto-takeover (no root path uses dry-run skipped)"
# Bypass root check by also passing --dry-run so the test runner (non-root)
# doesn't trip the EUID gate. The argv must still contain --panel-auto-takeover.
reset_installer_log
call_firewall_takeover --panel-auto-takeover --dry-run >/dev/null 2>&1 || true
T4_LOG=$(cat "$INSTALLER_LOG" 2>/dev/null || true)
assert_contains "$T4_LOG" "--mode=upgrade"                           "T4.1 mode=upgrade present"
assert_contains "$T4_LOG" "--panel-auto-takeover"                    "T4.2 --panel-auto-takeover forwarded"
assert_contains "$T4_LOG" "--dry-run"                                "T4.3 --dry-run forwarded"

# ---------------------------------------------------------------------------
# T5: unknown flag refuses with exit 2
# ---------------------------------------------------------------------------
echo
echo "[T5] firewall takeover --bogus refuses"
reset_installer_log
T5_OUT=$(call_firewall_takeover --bogus 2>&1 || true)
assert_contains "$T5_OUT" "Unknown takeover argument"                "T5.1 unknown arg refusal"
[[ ! -s "$INSTALLER_LOG" ]] && {
    printf "  [PASS] %s\n" "T5.2 installer not invoked (bogus arg)"
    PASS=$((PASS + 1))
} || {
    printf "  [FAIL] %s\n" "T5.2 installer not invoked (bogus arg)"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("T5.2")
}

# ---------------------------------------------------------------------------
# T6: root gate — non-root + no --dry-run refuses with exit 1
# (We are non-root in CI; --panel-auto-takeover alone must hit the gate.)
# ---------------------------------------------------------------------------
echo
echo "[T6] root gate"
if [[ $EUID -ne 0 ]]; then
    reset_installer_log
    T6_OUT=$(call_firewall_takeover --panel-auto-takeover 2>&1 || true)
    assert_contains "$T6_OUT" "requires root"                        "T6.1 non-root refusal"
    [[ ! -s "$INSTALLER_LOG" ]] && {
        printf "  [PASS] %s\n" "T6.2 installer not invoked (non-root)"
        PASS=$((PASS + 1))
    } || {
        printf "  [FAIL] %s\n" "T6.2 installer not invoked (non-root)"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("T6.2")
    }
else
    echo "  [SKIP] T6 — running as root; cannot exercise non-root gate"
fi

# ---------------------------------------------------------------------------
# T7: update --panel-auto-takeover sets NFTBAN_PANEL_AUTO_TAKEOVER=1 and
#     strips the flag from the version/branch parser path.
# ---------------------------------------------------------------------------
echo
echo "[T7] update --panel-auto-takeover env-mirror forwarding"
T7_OUT=$(call_update_with_panel_flag check --panel-auto-takeover 2>&1 || true)
assert_contains "$T7_OUT" "NFTBAN_PANEL_AUTO_TAKEOVER=1"             "T7.1 env mirror set"

T7B_OUT=$(call_update_with_panel_flag check 2>&1 || true)
assert_contains "$T7B_OUT" "NFTBAN_PANEL_AUTO_TAKEOVER=unset"        "T7.2 env mirror NOT set when flag absent"

# ---------------------------------------------------------------------------
# T8: Registry YAML structural validity + new entries present
# ---------------------------------------------------------------------------
echo
echo "[T8] Registry YAML structural validation"
if command -v python3 >/dev/null 2>&1; then
    T8_OUT=$(python3 - <<PY 2>&1
import yaml, sys
try:
    d = yaml.safe_load(open("$REPO_ROOT/commands.registry.yml"))
    assert "takeover" in d["firewall"]["subcommands"], "missing firewall.subcommands.takeover"
    assert d["firewall"]["subcommands"]["takeover"]["requires_root"] is True, "takeover should require root"
    assert "--panel-auto-takeover" in d["firewall"]["subcommands"]["takeover"]["options"], "missing takeover.options.--panel-auto-takeover"
    assert "options" in d["update"] and "--panel-auto-takeover" in d["update"]["options"], "missing update.options.--panel-auto-takeover"
    print("YAML_OK")
except Exception as e:
    print(f"YAML_ERR: {e}")
PY
)
    assert_contains "$T8_OUT" "YAML_OK"                              "T8.1 Registry structurally valid"
    assert_not_contains "$T8_OUT" "YAML_ERR"                         "T8.2 No YAML errors"
else
    echo "  [SKIP] T8 — python3 not available"
fi

# ---------------------------------------------------------------------------
# T9: Installer flags.go untouched (regression guard against scope-creep)
# ---------------------------------------------------------------------------
echo
echo "[T9] Installer flags.go regression guard"
if command -v git >/dev/null 2>&1 && [[ -d "$REPO_ROOT/.git" ]]; then
    cd "$REPO_ROOT"
    if git diff --quiet main -- cmd/nftban-installer/flags.go 2>/dev/null; then
        printf "  [PASS] %s\n" "T9.1 cmd/nftban-installer/flags.go byte-unchanged vs main"
        PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s\n" "T9.1 cmd/nftban-installer/flags.go modified — SCOPE VIOLATION"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("T9.1")
    fi
    cd - >/dev/null
else
    echo "  [SKIP] T9 — not in git repo or git unavailable"
fi

echo
echo "================================================="
echo "Results: $PASS passed, $FAIL failed"
echo "================================================="

if [[ "$FAIL" -gt 0 ]]; then
    printf 'Failed tests:\n'
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
exit 0
