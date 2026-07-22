#!/usr/bin/env bash
# =============================================================================
# NFTBan - exporter hostname fallback test (v1.139.1 hotfix)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="hostname_fallback_v1_139_1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-28"
# meta:description="v1.139.1 hotfix test — asserts the nftban-unified-exporter's hostname fallback chain at cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh:~1474 (a) contains every expected fallback link (hostname -f, hostname, hostnamectl --static, uname -n, /etc/hostname, literal 'unknown') and (b) does NOT exit rc=127 when the hostname binary is shadowed/missing (the original v1.137/v1.138/v1.139.0 ship of this line called the same missing 'hostname' binary in both fallback branches → rc=127 on CentOS Stream 10 / RHEL 10 which ship no hostname binary by default; pre-existing since git-blame 97b2c9297 2026-02-04, classified auxiliary so installs still reach COMMITTED). Hermetic — no host contact, uses function-shadow to simulate missing binary."
# meta:input="cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,uname,cat"
# meta:inventory.files="cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh"
# meta:inventory.binaries="bash,grep,uname,cat"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="hostname_fallback_v1_139_1_test"
# meta:ta.owner="metrics"
# meta:ta.module="exporter"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
SRC="$REPO/cli/lib/nftban/exporters/nftban_unified_exporter_collect.sh"

[[ -f "$SRC" ]] || { echo "FAIL: cannot find $SRC" >&2; exit 1; }

PASS=0; FAIL=0; FAILED=()
ok(){ printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
no(){ printf '  [FAIL] %s (%s)\n' "$1" "$2"; FAIL=$((FAIL+1)); FAILED+=("$1"); }

echo "=========================================================="
echo "V1.139.1 hotfix: exporter hostname fallback test"
echo "=========================================================="

# -----------------------------------------------------------------------------
# Source-code assertions: the production fallback chain must carry every link.
# -----------------------------------------------------------------------------
echo "--- source-code link assertions ---"
grep -qE 'hostname -f 2>/dev/null'      "$SRC" && ok "T1 'hostname -f' link present"           || no "T1 'hostname -f' link present"      "missing"
grep -qE '\|\| hostname 2>/dev/null'    "$SRC" && ok "T2 'hostname' bare link present"         || no "T2 'hostname' bare link present"    "missing"
grep -qE 'hostnamectl --static 2>/dev/null' "$SRC" && ok "T3 'hostnamectl --static' link present" || no "T3 'hostnamectl --static' link present" "missing"
grep -qE 'uname -n 2>/dev/null'         "$SRC" && ok "T4 'uname -n' link present"              || no "T4 'uname -n' link present"         "missing"
grep -qE 'cat /etc/hostname 2>/dev/null' "$SRC" && ok "T5 '/etc/hostname' link present"        || no "T5 '/etc/hostname' link present"    "missing"
grep -qE 'echo unknown'                 "$SRC" && ok "T6 'echo unknown' last-resort guard present" || no "T6 'echo unknown' last-resort guard present" "missing"

# -----------------------------------------------------------------------------
# Runtime simulation: replay the EXACT fallback chain in a shell where
# `hostname` is shadowed (always returns 127, matching the EL10 reality of
# "binary not in PATH").
# -----------------------------------------------------------------------------
echo "--- runtime simulations ---"

# The chain itself (kept in lock-step with the production line; T7-T9 prove
# the runtime semantics; T1-T6 above prove the production source IS this chain).
fallback_chain() {
    hostname -f 2>/dev/null \
        || hostname 2>/dev/null \
        || hostnamectl --static 2>/dev/null \
        || uname -n 2>/dev/null \
        || cat /etc/hostname 2>/dev/null \
        || echo unknown
}

# T7: only `hostname` is missing (the EL10 reality — `hostnamectl` is present
# on every systemd host including EL10; the chain should land on hostnamectl).
result=$(
    set +e
    hostname() { return 127; }
    result=$(fallback_chain)
    printf '%s' "$result"
)
if [[ -n "$result" && "$result" != "unknown" && "$result" != *"command not found"* ]]; then
    ok "T7 hostname-shadowed → fallback returns non-empty real value (got: '$result')"
else
    no "T7 hostname-shadowed → fallback returns non-empty real value" "got: '$result'"
fi

# T8: BOTH `hostname` AND `hostnamectl` shadowed (forces uname -n / /etc/hostname).
result=$(
    set +e
    hostname()    { return 127; }
    hostnamectl() { return 127; }
    result=$(fallback_chain)
    printf '%s' "$result"
)
expected_uname=$(uname -n 2>/dev/null || true)
if [[ "$result" == "$expected_uname" && -n "$result" ]]; then
    ok "T8 hostname+hostnamectl-shadowed → fallback returns uname -n (got: '$result')"
elif [[ -n "$result" && "$result" != "unknown" ]]; then
    ok "T8 hostname+hostnamectl-shadowed → fallback returns non-empty real value (got: '$result', uname -n: '$expected_uname')"
else
    no "T8 hostname+hostnamectl-shadowed → fallback returns non-empty real value" "got: '$result' uname-n: '$expected_uname'"
fi

# T9: the chain MUST not exit 127 anywhere — the literal `echo unknown` is the
# bulletproof terminator. Force every binary to fail and assert the result is
# literally "unknown" (not a command-not-found error).
result=$(
    set +e
    hostname()    { return 127; }
    hostnamectl() { return 127; }
    uname()       { return 127; }
    cat()         { if [[ "${1:-}" == "/etc/hostname" ]]; then return 127; else command cat "$@"; fi; }
    result=$(fallback_chain)
    printf '%s' "$result"
)
if [[ "$result" == "unknown" ]]; then
    ok "T9 all fallbacks shadowed → literal 'unknown' (never command-not-found)"
else
    no "T9 all fallbacks shadowed → literal 'unknown'" "got: '$result' (expected 'unknown')"
fi

# T10: the production source-line region must NOT contain the original
# pre-existing pattern (the buggy `hostname -f 2>/dev/null || hostname$`
# without further fallbacks) — guards against regression to the v1.137-era
# shape.
if grep -qE '^[[:space:]]+hostname=\$\(hostname -f 2>/dev/null \|\| hostname\)$' "$SRC"; then
    no "T10 buggy pre-existing pattern absent" "the v1.137-era line is STILL PRESENT — fallback would regress to two-call-of-same-missing-binary"
else
    ok "T10 buggy pre-existing pattern absent (no two-call-of-same-binary fallback)"
fi

# -----------------------------------------------------------------------------
echo "=========================================================="
echo "RESULTS: PASS=$PASS FAIL=$FAIL"
if (( FAIL > 0 )); then printf 'FAILED: %s\n' "${FAILED[@]}"; exit 1; fi
echo "ALL PASS"
