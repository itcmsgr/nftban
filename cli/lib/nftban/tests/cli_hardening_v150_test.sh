#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.150 Lane A shell/CLI-health hardening
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cli_hardening_v150_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-05"
# meta:description="Tests for v1.150 Lane A (OPEN_V150_SHELL_CLI_HEALTH_IMPL). Asserts: re-sourcing nftban_firewall_conflicts.sh twice under set -u (with the load-guard pre-tripped, as an exported child shell would see) keeps CONFLICT_* bound (15.10/16.2); the meta:name parser is non-greedy on a single-line-meta lib (13.6); the dispatcher lowercasing idiom maps STATS->stats (16.7); botguard enable returns non-zero when the nft fragment fails (MOD-05); and nftban port help is reachable without root (CLI-01). Self-contained sandbox; no root, no host mutation."
# meta:input="None (self-contained sandbox)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,awk,sed,mktemp"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,awk,sed,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="cli_hardening_v150_test"
# meta:ta.owner="cli"
# meta:ta.module="cli-health"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
# Self-contained sandbox; no host contact; no root required. Functions under
# test are extracted from their source files by name and run in subshells with
# leaf helpers stubbed (nft/systemctl/config-set/banner), the EUID root guards
# patched out where needed.
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR

CONFLICTS_SRC="$NFTBAN_LIB_DIR/core/nftban_firewall_conflicts.sh"
MODULE_SRC="$NFTBAN_LIB_DIR/core/nftban_report_module.sh"
BOTGUARD_SRC="$NFTBAN_LIB_DIR/cli/cmd_botguard.sh"
PORT_SRC="$NFTBAN_LIB_DIR/cli/cmd_port.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
FAILED_TESTS=()

assert_contains() {
    local haystack="$1" needle="$2" name="$3"
    if printf '%s' "$haystack" | grep -F -q -- "$needle"; then
        printf "  [PASS] %s\n" "$name"; PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s\n         expected to contain: %s\n         got: %s\n" "$name" "$needle" "$haystack"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
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

echo "================================================="
echo "v1.150 Lane A CLI-health hardening test suite"
echo "================================================="

# ---------------------------------------------------------------------------
# T1: 15.10/16.2 — re-sourcing the conflicts lib twice under set -u keeps
#     CONFLICT_* bound and never aborts. We pre-set the load-guard variable so
#     the second source takes the early-return path — exactly the scenario an
#     inherited/exported guard creates in a fresh child shell.
# ---------------------------------------------------------------------------
echo; echo "[T1] firewall_conflicts re-source safe under set -u (15.10/16.2)"
T1_OUT=$(
    bash --norc -c '
        set -Eeuo pipefail
        # First load (normal).
        source "'"$CONFLICTS_SRC"'"
        # Simulate a child shell that inherited the guard but NOT the constants:
        unset CONFLICT_NONE CONFLICT_INFO CONFLICT_WARNING CONFLICT_CRITICAL
        # Guard is still set from the first source -> second source early-returns.
        source "'"$CONFLICTS_SRC"'"
        # Bare references must NOT abort under set -u.
        printf "NONE=%s WARN=%s INFO=%s CRIT=%s\n" \
            "$CONFLICT_NONE" "$CONFLICT_WARNING" "$CONFLICT_INFO" "$CONFLICT_CRITICAL"
        echo "RESOURCE_OK"
    ' 2>&1
) || true
assert_contains "$T1_OUT" "RESOURCE_OK"                 "T1.1 double-source under set -u did not abort"
assert_contains "$T1_OUT" "NONE=0 WARN=2 INFO=1 CRIT=3" "T1.2 CONFLICT_* bound after re-source"

# ---------------------------------------------------------------------------
# T2: 13.6 — meta:name parser is non-greedy / anchored. On a single-line-meta
#     lib the NAME must stop at the first closing quote, not swallow the rest.
# ---------------------------------------------------------------------------
echo; echo "[T2] meta:name parse is non-greedy on single-line-meta libs (13.6)"
META_LIB="$SANDBOX/oneliner.sh"
printf '#!/usr/bin/env bash\n# meta:name="clean_name" meta:type="core" meta:version="9.9.9"\n' > "$META_LIB"
META_MULTI="$SANDBOX/multi.sh"
printf '#!/usr/bin/env bash\n# meta:name="multi_name"\n# meta:type="lib"\n' > "$META_MULTI"

extract_meta_env() {
    awk '/^nftban_module_extract_meta\(\)/{c=1} c{print} /^}/{if(c){c=0}}' "$MODULE_SRC"
}
call_extract() { ( set +u; eval "$(extract_meta_env)"; nftban_module_extract_meta "$1" "$2" ); }

T2A=$(call_extract "$META_LIB" "name")
assert_eq "$T2A" "clean_name"   "T2.1 single-line-meta NAME stops at first closing quote"
# The pre-fix greedy capture would have yielded e.g.
# 'clean_name" meta:type="core" meta:version="9.9.9' — assert no leakage.
if printf '%s' "$T2A" | grep -F -q 'meta:type'; then
    printf "  [FAIL] %s (leaked: %s)\n" "T2.2 NAME does not swallow later meta tags" "$T2A"
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("T2.2")
else
    printf "  [PASS] %s\n" "T2.2 NAME does not swallow later meta tags"; PASS=$((PASS + 1))
fi
T2C=$(call_extract "$META_MULTI" "name")
assert_eq "$T2C" "multi_name"   "T2.3 multi-line-meta NAME still parsed (no regression)"
T2D=$(call_extract "$META_MULTI" "type")
assert_eq "$T2D" "lib"          "T2.4 own-line meta:type parsed cleanly"

# ---------------------------------------------------------------------------
# T3: 16.7 — case-insensitive dispatch idiom. The dispatcher lowercases the
#     top-level command token with ${cmd,,}; verify the idiom AND that the real
#     sbin source applies it (grep for the applied line).
# ---------------------------------------------------------------------------
echo; echo "[T3] \${cmd,,} lowercases the command token (16.7)"
cmd="STATS"; cmd="${cmd,,}"
assert_eq "$cmd" "stats"        "T3.1 STATS -> stats via \${cmd,,}"
cmd2="WhiteList"; cmd2="${cmd2,,}"
assert_eq "$cmd2" "whitelist"   "T3.2 mixed-case WhiteList -> whitelist"
T3SRC=$(grep -F 'cmd="${cmd,,}"' "$NFTBAN_LIB_DIR/../../sbin/nftban" 2>/dev/null || \
        grep -F 'cmd="${cmd,,}"' "$REPO_ROOT/cli/sbin/nftban" 2>/dev/null || true)
assert_contains "$T3SRC" 'cmd="${cmd,,}"' "T3.3 sbin/nftban applies the lowercasing"

# ---------------------------------------------------------------------------
# T4: MOD-05 — botguard enable returns non-zero when the nft fragment fails,
#     and must NOT claim "enabled".
# ---------------------------------------------------------------------------
echo; echo "[T4] botguard enable honest on fragment failure (MOD-05)"
botguard_env() {
    cat <<'STUBS'
NFTBAN_LIB_DIR_REAL="$NFTBAN_LIB_DIR"
_botguard_config_set() { return 0; }          # config write is a no-op success
systemctl() { return 1; }                     # daemon "not active"
# The function sources lib/nft_fragment.sh; pre-define the symbol so the source
# is a no-op and our stub wins. The stub FAILS (rc=1) to drive the error path.
nft_fragment_enable_module() { return 1; }
STUBS
    # Neutralise the `source .../lib/nft_fragment.sh` so it can't redefine our stub.
    awk '/^_nftban_botguard_enable\(\)/{c=1} c{print} /^}/{if(c){c=0}}' "$BOTGUARD_SRC" \
        | sed -E 's@source "\$\{NFTBAN_LIB_DIR\}/lib/nft_fragment.sh" \|\| true@true@'
}
call_botguard_enable() { ( set +eu; eval "$(botguard_env)"; _nftban_botguard_enable "false" ); }

T4_RC=0
T4_OUT=$(call_botguard_enable 2>&1) || T4_RC=$?
assert_eq "$T4_RC" "1"                                  "T4.1 fragment failure -> rc=1"
assert_contains "$T4_OUT" "NOT applied"                 "T4.2 says rules NOT applied"
assert_contains "$T4_OUT" "nftban rebuild"              "T4.3 points operator at rebuild"
if printf '%s' "$T4_OUT" | grep -F -q "Bot Guard enabled."; then
    printf "  [FAIL] %s\n" "T4.4 must NOT claim 'enabled' on failure"
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("T4.4")
else
    printf "  [PASS] %s\n" "T4.4 does NOT claim 'enabled' on failure"; PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
# T5: CLI-01 — `nftban port help` reachable without root (EUID gate hoisted
#     below the help short-circuit). We stub EUID non-root + the help fn.
# ---------------------------------------------------------------------------
echo; echo "[T5] port help reachable without root (CLI-01)"
port_env() {
    cat <<'STUBS'
nftban_cmd_port_help() { echo "PORT_HELP_SHOWN"; return 0; }
STUBS
    # Extract just the dispatcher; patch the EUID test to simulate non-root.
    awk '/^nftban_cmd_port\(\)/{c=1} c{print} /^}/{if(c){c=0}}' "$PORT_SRC" \
        | sed -E 's@\[\[ \$EUID -ne 0 \]\]@[[ 1 -eq 1 ]]@g'
}
call_port() { ( set +eu; eval "$(port_env)"; nftban_cmd_port "$@" ); }

T5A=$(call_port help 2>&1); T5A_RC=$?
assert_contains "$T5A" "PORT_HELP_SHOWN"                "T5.1 'port help' shows help as non-root"
assert_eq "$T5A_RC" "0"                                 "T5.2 'port help' returns 0 as non-root"
T5B=$(call_port --help 2>&1)
assert_contains "$T5B" "PORT_HELP_SHOWN"                "T5.3 'port --help' shows help as non-root"
T5C=$(call_port -h 2>&1)
assert_contains "$T5C" "PORT_HELP_SHOWN"                "T5.4 'port -h' shows help as non-root"
# Sanity: a non-help, privileged subcommand still hits the (simulated) gate.
T5D=$(call_port scan 1.2.3.4 2>&1 || true)
assert_contains "$T5D" "authorization failed"           "T5.5 non-help subcommand still gated (gate intact)"

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
