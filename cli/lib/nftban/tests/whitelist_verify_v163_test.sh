#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.163: `nftban whitelist verify` (SEC-WL-VERIFY) read-only check
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="whitelist_verify_v163_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-08"
# meta:description="Locks v1.163 PR-A SEC-WL-VERIFY: the READ-ONLY 'nftban whitelist verify' command compares the live kernel whitelist sets (@whitelist_ipv4 in ip nftban, @whitelist_ipv6 in ip6 nftban) against the DURABLE whitelist.d baseline (entries with NO EXPIRES_AT). Asserts: (1) kernel == baseline -> rc=0, no anomaly; (2) an extra kernel IP not in baseline and not a current session -> rc=1, IN-KERNEL-NOT-IN-BASELINE; (3) a baseline IP missing from the kernel -> rc=1, IN-BASELINE-NOT-IN-KERNEL; (4) a kernel IP matching an unexpired 00-session.conf entry -> rc=0, informational (NOT anomaly); (5) an IPv6 baseline/kernel pair is exercised; (6) the command performs NO nft writes — a recording nft mock fails the suite if any add/delete/create/flush verb is seen. Hermetic: a TMPDIR stands in for /etc/nftban/whitelist.d and a PATH-shim nft returns controlled 'list set' output; no daemon, no kernel."
# meta:input="None (self-contained; TMPDIR sandbox + nft PATH shim)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,awk,sed,grep,date"
# meta:inventory.files="cli/lib/nftban/cli/cmd_whitelist.sh"
# meta:inventory.binaries="bash,awk,sed,grep,date"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files="/etc/nftban/whitelist.d/99-manual.conf,/etc/nftban/whitelist.d/00-session.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../../.." && pwd)
NFTBAN_LIB_DIR="${REPO_ROOT}/cli/lib/nftban"
export NFTBAN_LIB_DIR
WL_SRC="$NFTBAN_LIB_DIR/cli/cmd_whitelist.sh"

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

CONF_DIR="$SANDBOX/whitelist.d"
BIN_DIR="$SANDBOX/bin"
NFT_LOG="$SANDBOX/nft_calls.log"
NFT_FIX_V4="$SANDBOX/fix_v4.txt"
NFT_FIX_V6="$SANDBOX/fix_v6.txt"
mkdir -p "$CONF_DIR" "$BIN_DIR"

PASS=0
FAIL=0
FAILED_TESTS=()

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

# ---------------------------------------------------------------------------
# nft PATH-shim: records every invocation, serves fixtures for `list set`, and
# FAILS the suite (records a WRITE) if any mutating verb is ever seen. This is
# how case (6) proves the command is read-only.
# ---------------------------------------------------------------------------
cat > "$BIN_DIR/nft" <<NFT_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$NFT_LOG"
case "\$*" in
  *" add "*|*" delete "*|*" create "*|*" flush "*|*" insert "*|*" replace "*)
      printf 'WRITE: %s\n' "\$*" >> "$NFT_LOG" ;;
esac
# Serve read-only 'list set' fixtures.
if [[ "\$*" == *"list set ip nftban whitelist_ipv4"* ]]; then
    cat "$NFT_FIX_V4" 2>/dev/null || true
    exit 0
fi
if [[ "\$*" == *"list set ip6 nftban whitelist_ipv6"* ]]; then
    cat "$NFT_FIX_V6" 2>/dev/null || true
    exit 0
fi
exit 0
NFT_EOF
chmod +x "$BIN_DIR/nft"

# Build an nft `list set` fixture body from a comma list of elements.
# $1 = output file, $2 = set family decl line tag (unused), $3.. = elements
make_fixture() {
    local out="$1" set_label="$2"; shift 2
    local joined=""
    local e
    for e in "$@"; do
        [[ -z "$joined" ]] && joined="$e" || joined="$joined, $e"
    done
    {
        echo "table $set_label {"
        echo "  set $set_label {"
        echo "    type ipv4_addr"
        if [[ -n "$joined" ]]; then
            echo "    elements = { $joined }"
        fi
        echo "  }"
        echo "}"
    } > "$out"
}

# Future + past RFC3339 timestamps for session fixtures.
FUTURE_TS=$(date -u -d "+2 hours" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
PAST_TS="2000-01-01T00:00:00Z"

# Run verify with the sandbox conf dir + nft shim on PATH, in a subshell.
run_verify() {
    (
        set +e
        # shellcheck source=/dev/null
        source "$WL_SRC" >/dev/null 2>&1 || true
        _NFTBAN_WHITELIST_CONF_DIR="$CONF_DIR"
        PATH="$BIN_DIR:$PATH"
        nftban_whitelist_verify "$@"
    )
}

# Capture run_verify output + rc WITHOUT tripping the suite's errexit.
# Sets CAP_OUT and CAP_RC. (No-arg form — verify takes no positional args.)
cap_verify() {
    CAP_RC=0
    CAP_OUT="$(run_verify)" || CAP_RC=$?
}

reset_state() {
    : > "$NFT_LOG"
    rm -f "$CONF_DIR"/*.conf 2>/dev/null || true
    make_fixture "$NFT_FIX_V4" "whitelist_ipv4"
    make_fixture "$NFT_FIX_V6" "whitelist_ipv6"
}

no_write_seen() {
    ! grep -q '^WRITE:' "$NFT_LOG" 2>/dev/null
}

echo "================================================="
echo "v1.163 whitelist verify (SEC-WL-VERIFY) test suite"
echo "================================================="

# ---------------------------------------------------------------------------
# T1: kernel == durable baseline -> rc=0, no anomaly
# ---------------------------------------------------------------------------
echo; echo "[T1] kernel == durable baseline -> rc=0, OK"
reset_state
cat > "$CONF_DIR/99-manual.conf" <<EOF
# durable
203.0.113.10  # ADDED_BY=nftban-whitelist-static
203.0.113.11  # ADDED_BY=nftban-whitelist-static
EOF
make_fixture "$NFT_FIX_V4" "whitelist_ipv4" "203.0.113.10" "203.0.113.11"
cap_verify; T1_OUT="$CAP_OUT"; T1_RC="$CAP_RC"
assert_eq "$T1_RC" "0"                              "T1.1 rc=0 when kernel matches baseline"
assert_contains "$T1_OUT" "no anomalies"            "T1.2 reports no anomalies"
assert_not_contains "$T1_OUT" "[ANOMALY]"           "T1.3 no ANOMALY lines"

# ---------------------------------------------------------------------------
# T2: extra IP in kernel, not in baseline, not a session -> rc=1, IN-KERNEL-NOT-IN-BASELINE
# ---------------------------------------------------------------------------
echo; echo "[T2] extra kernel IP (not baseline/session) -> rc=1 injection anomaly"
reset_state
cat > "$CONF_DIR/99-manual.conf" <<EOF
203.0.113.10  # ADDED_BY=nftban-whitelist-static
EOF
make_fixture "$NFT_FIX_V4" "whitelist_ipv4" "203.0.113.10" "198.51.100.66"
cap_verify; T2_OUT="$CAP_OUT"; T2_RC="$CAP_RC"
assert_eq "$T2_RC" "1"                              "T2.1 rc=1 on injection anomaly"
assert_contains "$T2_OUT" "IN-KERNEL-NOT-IN-BASELINE" "T2.2 class IN-KERNEL-NOT-IN-BASELINE"
assert_contains "$T2_OUT" "198.51.100.66"           "T2.3 flags the injected IP"

# ---------------------------------------------------------------------------
# T3: baseline IP missing from kernel -> rc=1, IN-BASELINE-NOT-IN-KERNEL
# ---------------------------------------------------------------------------
echo; echo "[T3] baseline IP missing from kernel -> rc=1 drift anomaly"
reset_state
cat > "$CONF_DIR/99-manual.conf" <<EOF
203.0.113.10  # ADDED_BY=nftban-whitelist-static
203.0.113.99  # ADDED_BY=nftban-whitelist-static
EOF
make_fixture "$NFT_FIX_V4" "whitelist_ipv4" "203.0.113.10"
cap_verify; T3_OUT="$CAP_OUT"; T3_RC="$CAP_RC"
assert_eq "$T3_RC" "1"                              "T3.1 rc=1 on drift anomaly"
assert_contains "$T3_OUT" "IN-BASELINE-NOT-IN-KERNEL" "T3.2 class IN-BASELINE-NOT-IN-KERNEL"
assert_contains "$T3_OUT" "203.0.113.99"            "T3.3 flags the missing baseline IP"
assert_contains "$T3_OUT" "nftban sync"             "T3.4 remediation hint suggests sync"

# ---------------------------------------------------------------------------
# T4: kernel IP matching an UNEXPIRED 00-session.conf entry -> rc=0, informational
# ---------------------------------------------------------------------------
echo; echo "[T4] active session IP in kernel -> rc=0, informational (NOT anomaly)"
reset_state
cat > "$CONF_DIR/99-manual.conf" <<EOF
203.0.113.10  # ADDED_BY=nftban-whitelist-static
EOF
cat > "$CONF_DIR/00-session.conf" <<EOF
192.0.2.50  # EXPIRES_AT=${FUTURE_TS}  REASON=admin  ADDED_BY=test
EOF
make_fixture "$NFT_FIX_V4" "whitelist_ipv4" "203.0.113.10" "192.0.2.50"
cap_verify; T4_OUT="$CAP_OUT"; T4_RC="$CAP_RC"
assert_eq "$T4_RC" "0"                              "T4.1 rc=0 — active session is not an anomaly"
assert_contains "$T4_OUT" "192.0.2.50"              "T4.2 session IP mentioned"
assert_contains "$T4_OUT" "[info]"                  "T4.3 marked informational"
assert_not_contains "$T4_OUT" "192.0.2.50 — IN-KERNEL-NOT-IN-BASELINE" "T4.4 NOT flagged as injection"

# ---------------------------------------------------------------------------
# T4b: EXPIRED session IP in kernel -> still an anomaly (expired != baseline)
# ---------------------------------------------------------------------------
echo; echo "[T4b] EXPIRED session IP in kernel -> rc=1 anomaly (not a current session)"
reset_state
cat > "$CONF_DIR/99-manual.conf" <<EOF
203.0.113.10  # ADDED_BY=nftban-whitelist-static
EOF
cat > "$CONF_DIR/00-session.conf" <<EOF
192.0.2.77  # EXPIRES_AT=${PAST_TS}  REASON=stale  ADDED_BY=test
EOF
make_fixture "$NFT_FIX_V4" "whitelist_ipv4" "203.0.113.10" "192.0.2.77"
cap_verify; T4B_OUT="$CAP_OUT"; T4B_RC="$CAP_RC"
assert_eq "$T4B_RC" "1"                             "T4b.1 rc=1 — expired session in kernel is an anomaly"
assert_contains "$T4B_OUT" "IN-KERNEL-NOT-IN-BASELINE" "T4b.2 classed as injection"

# ---------------------------------------------------------------------------
# T5: IPv6 path exercised — baseline missing from kernel -> rc=1
# ---------------------------------------------------------------------------
echo; echo "[T5] IPv6 baseline/kernel comparison exercised"
reset_state
cat > "$CONF_DIR/99-manual.conf" <<EOF
2001:db8::10  # ADDED_BY=nftban-whitelist-static
2001:db8::beef  # ADDED_BY=nftban-whitelist-static
EOF
make_fixture "$NFT_FIX_V4" "whitelist_ipv4"
make_fixture "$NFT_FIX_V6" "whitelist_ipv6" "2001:db8::10"
cap_verify; T5_OUT="$CAP_OUT"; T5_RC="$CAP_RC"
assert_eq "$T5_RC" "1"                              "T5.1 rc=1 — IPv6 baseline drift"
assert_contains "$T5_OUT" "2001:db8::beef"          "T5.2 flags the missing IPv6 baseline entry"
assert_contains "$T5_OUT" "whitelist_ipv6"          "T5.3 IPv6 set named in report"

# ---------------------------------------------------------------------------
# T6: NO nft writes — across ALL the above runs no WRITE verb was recorded.
# (re-assert on a fresh run for explicitness)
# ---------------------------------------------------------------------------
echo; echo "[T6] read-only — no nft add/delete/create/flush ever invoked"
reset_state
cat > "$CONF_DIR/99-manual.conf" <<EOF
203.0.113.10  # ADDED_BY=nftban-whitelist-static
EOF
make_fixture "$NFT_FIX_V4" "whitelist_ipv4" "203.0.113.10" "198.51.100.66"
run_verify >/dev/null 2>&1 || true
if no_write_seen; then
    printf "  [PASS] %s\n" "T6.1 no nft write verb recorded"; PASS=$((PASS + 1))
else
    printf "  [FAIL] %s\n         write verbs: %s\n" "T6.1 no nft write verb recorded" "$(grep '^WRITE:' "$NFT_LOG" || true)"
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("T6.1")
fi
# Confirm the only nft sub-command used is 'list set' (read).
if grep -qv 'list set' "$NFT_LOG" 2>/dev/null; then
    # there is at least one non-'list set' line -> investigate
    NON_LIST=$(grep -v 'list set' "$NFT_LOG" || true)
    if [[ -n "$NON_LIST" ]]; then
        printf "  [FAIL] %s\n         non-list nft calls: %s\n" "T6.2 only 'list set' nft calls" "$NON_LIST"
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("T6.2")
    else
        printf "  [PASS] %s\n" "T6.2 only 'list set' nft calls"; PASS=$((PASS + 1))
    fi
else
    printf "  [PASS] %s\n" "T6.2 only 'list set' nft calls"; PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
# T7: --fix is rejected (read-only contract; no auto-fix surface)
# ---------------------------------------------------------------------------
echo; echo "[T7] --fix rejected (read-only contract)"
reset_state
T7_RC=0; T7_OUT="$(run_verify --fix 2>&1)" || T7_RC=$?
assert_eq "$T7_RC" "2"                              "T7.1 rc=2 on --fix"
assert_contains "$T7_OUT" "read-only"               "T7.2 message states read-only"

echo
echo "================================================="
echo "whitelist_verify_v163: PASS=$PASS FAIL=$FAIL"
echo "================================================="
if [[ "$FAIL" -ne 0 ]]; then
    printf 'FAILED: %s\n' "${FAILED_TESTS[*]}"
    exit 1
fi
exit 0
