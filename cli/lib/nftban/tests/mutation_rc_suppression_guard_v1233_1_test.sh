#!/usr/bin/env bash
# =============================================================================
# NFTBan - mutation-result suppression guard: falsifiability + tree gate (v1.233.1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="mutation_rc_suppression_guard_v1233_1_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-24"
# meta:description="Hermetic test of scripts/ci/check-mutation-rc-suppression.sh (claim-truth C-f). Proves each rule can FAIL and can PASS on fixture trees: `|| true` and `2>/dev/null || true` on a mutation primitive before a success claim, a bare call whose status is discarded, the motivating v1.233.0 portscan teardown shape (bare classic_disable inside a guard, then an unconditional success mark), a new finding against the baseline, a stale baseline row, and an exception annotation without a justification. Also proves what must NOT be flagged: a captured rc, a tested call, the last statement of a function, a read-only IPC predicate, a primitive named inside a message, and a suppression with no later success claim. Finally gates the REAL tree against its baseline, with a positive control that the known nftban_ddos_teardown finding is still reported (the guard is not silently empty)."
# meta:ta.id="mutation_rc_suppression_guard_v1233_1_test"
# meta:ta.owner="cli"
# meta:ta.module="claim-truth"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.blocking="true"
# meta:ta.timeout="120"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:inventory.files="scripts/ci/check-mutation-rc-suppression.sh,scripts/ci/data/mutation-rc-suppression-baseline.tsv"
# meta:inventory.binaries="bash,awk,grep,sort,comm"
# meta:inventory.env_vars="NFTBAN_ROOT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none (static analysis of fixture files)"
# =============================================================================

set -Eeuo pipefail

ROOT="${NFTBAN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)}"
GUARD="$ROOT/scripts/ci/check-mutation-rc-suppression.sh"
FAILURES=0
fail() { FAILURES=$((FAILURES + 1)); echo "  FAIL  $1"; }
ok()   { echo "  ok    $1"; }

echo "=== mutation-result suppression guard (v1.233.1) ==="
[[ -f "$GUARD" ]] || { echo "::error::SUBJECT_NOT_FOUND: $GUARD"; exit 1; }

TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

# fixture <name> <body-file> — a one-file tree under cli/lib/nftban/core/
fixture() {
    local d="$TMPD/$1"
    rm -rf "$d"; mkdir -p "$d/cli/lib/nftban/core" "$d/scripts/ci/data"
    cp "$2" "$d/cli/lib/nftban/core/fixture.sh"
    printf '# empty baseline\n' > "$d/scripts/ci/data/mutation-rc-suppression-baseline.tsv"
    echo "$d"
}
# list <tree> — findings as "function primitive form" lines
list() { bash "$GUARD" --root "$1" --list 2>&1 | awk -F'\t' 'NF==5 {print $3" "$4" "$5}'; }
gate_rc() { local rc=0; bash "$GUARD" --root "$1" >"$TMPD/gate.out" 2>&1 || rc=$?; echo "$rc"; }

expect_finding() {  # <label> <tree> <function> <primitive> <form>
    local got; got="$(list "$2")"
    if grep -qxF "$3 $4 $5" <<<"$got"; then ok "$1"; else fail "$1 — expected '$3 $4 $5', got: ${got:-<none>}"; fi
}
expect_none() {  # <label> <tree>
    local got; got="$(list "$2")"
    if [[ -z "$got" ]]; then ok "$1"; else fail "$1 — expected no finding, got: $got"; fi
}

# --- positive arms: the guard must FIRE ---------------------------------------
cat > "$TMPD/a.sh" <<'EOF'
mod_teardown() {
    nft_ipc_apply_ruleset "$frag" || true
    echo "  ✅ module disabled"
    return 0
}
EOF
expect_finding "A  '|| true' on an IPC write before a success mark" "$(fixture a "$TMPD/a.sh")" mod_teardown nft_ipc_apply_ruleset OR_TRUE

cat > "$TMPD/b.sh" <<'EOF'
nftban_x_teardown() {
    nftban_x_classic_disable 2>/dev/null || true
    echo "  DDoS Protection DISABLED"
}
EOF
expect_finding "B  '2>/dev/null || true' (stderr hidden AND rc dropped)" "$(fixture b "$TMPD/b.sh")" nftban_x_teardown nftban_x_classic_disable STDERR_HIDDEN_OR_TRUE

cat > "$TMPD/c.sh" <<'EOF'
nftban_x_classic_disable() {
    nftban_x_classic_save_state
    nftban_x_classic_remove_rules
    log_info "Classic detection disabled"
    return 0
}
EOF
expect_finding "C  bare call, status discarded, then a success claim" "$(fixture c "$TMPD/c.sh")" nftban_x_classic_disable nftban_x_classic_remove_rules DISCARDED_RC

# The MOTIVATING DEFECT, in its v1.233.0 shape (nftban_portscan_teardown).
cat > "$TMPD/m.sh" <<'EOF'
nftban_portscan_teardown() {
    local mode="${_PORTSCAN_ACTIVE_MODE:-classic}"
    case "$mode" in
        classic)
            if type -t nftban_portscan_classic_disable &>/dev/null; then
                nftban_portscan_classic_disable
            fi
            ;;
    esac
    _PORTSCAN_INITIALIZED=0
    echo "  ✅ Portscan detection disabled"
    return 0
}
EOF
expect_finding "M  v1.233.0 portscan teardown shape is flagged" "$(fixture m "$TMPD/m.sh")" nftban_portscan_teardown nftban_portscan_classic_disable DISCARDED_RC

cat > "$TMPD/s.sh" <<'EOF'
restart_it() {
    systemctl restart nftband 2>/dev/null || true
    echo "  ✅ Daemon restarted — now active"
}
EOF
expect_finding "S  systemctl restart with rc dropped before 'now active'" "$(fixture s "$TMPD/s.sh")" restart_it systemctl_restart STDERR_HIDDEN_OR_TRUE

# --- negative arms: the guard must NOT fire -----------------------------------
cat > "$TMPD/n1.sh" <<'EOF'
good_capture() {
    local rc=0
    nft_ipc_apply_ruleset "$f" || rc=$?
    if ! nftban_x_classic_remove_rules; then return 1; fi
    nftban_x_classic_add_rules
    rc=$?
    echo "  ✅ applied"
    return "$rc"
}
EOF
expect_none "N1 captured / tested / next-line-captured status is not flagged" "$(fixture n1 "$TMPD/n1.sh")"

cat > "$TMPD/n2.sh" <<'EOF'
last_statement() {
    echo "applying"
    nftban_x_classic_add_rules
}
nested_last() {
    if [[ -n "$x" ]]; then
        nftban_x_classic_add_rules
    fi
}
EOF
expect_none "N2 a bare call that IS the function's status is not flagged" "$(fixture n2 "$TMPD/n2.sh")"

cat > "$TMPD/n3.sh" <<'EOF'
predicates_and_messages() {
    nft_ipc_is_daemon_running || true
    echo "run nftban_x_classic_disable to disable" || true
    echo "  ✅ ready"
}
no_claim() {
    nft_ipc_apply_ruleset "$f" || true
    echo "ERROR: could not apply" >&2
    return 1
}
EOF
expect_none "N3 read predicates, messages, and suppressions with no later claim" "$(fixture n3 "$TMPD/n3.sh")"

cat > "$TMPD/n4.sh" <<'EOF'
annotated() {
    # nftban:rc-suppression-ok: per-object best effort; absence verified by the census below
    nft_fragment_delete_object ip chain x || true
    echo "  ✅ removed"
}
EOF
expect_none "N4 a justified exception annotation is honoured" "$(fixture n4 "$TMPD/n4.sh")"

# --- gate arms ----------------------------------------------------------------
t="$(fixture g1 "$TMPD/a.sh")"
rc="$(gate_rc "$t")"
if [[ "$rc" == "1" ]] && grep -q 'NEW mutation-result suppression' "$TMPD/gate.out"; then ok "G1 a finding absent from the baseline FAILS the gate"
else fail "G1 new finding did not fail the gate (rc=$rc): $(tail -n 3 "$TMPD/gate.out" | tr '\n' '|')"; fi

printf 'cli/lib/nftban/core/fixture.sh|mod_teardown|nft_ipc_apply_ruleset|OR_TRUE\n' >> "$t/scripts/ci/data/mutation-rc-suppression-baseline.tsv"
rc="$(gate_rc "$t")"
[[ "$rc" == "0" ]] && ok "G2 a baselined finding passes (ratchet, recorded debt)" || fail "G2 baselined finding failed the gate (rc=$rc)"

cp "$TMPD/n1.sh" "$t/cli/lib/nftban/core/fixture.sh"
rc="$(gate_rc "$t")"
if [[ "$rc" == "1" ]] && grep -q 'STALE baseline rows' "$TMPD/gate.out"; then ok "G3 a baseline row that no longer reproduces FAILS (stale)"
else fail "G3 stale row did not fail the gate (rc=$rc)"; fi

cat > "$TMPD/g4.sh" <<'EOF'
lazy() {
    # nftban:rc-suppression-ok: ok
    nft_ipc_apply_ruleset "$f" || true
    echo "  ✅ done"
}
EOF
t="$(fixture g4 "$TMPD/g4.sh")"
rc="$(gate_rc "$t")"
if [[ "$rc" == "1" ]] && grep -q 'without a justification' "$TMPD/gate.out"; then ok "G4 an exception without a real justification FAILS"
else fail "G4 unjustified exception accepted (rc=$rc)"; fi

# --- the real tree ------------------------------------------------------------
rc=0; bash "$GUARD" --root "$ROOT" >"$TMPD/tree.out" 2>&1 || rc=$?
if [[ "$rc" == "0" ]]; then ok "T1 the shipped tree matches its baseline"
else fail "T1 the shipped tree fails the guard (rc=$rc): $(grep -E 'FAIL|NEW|STALE' "$TMPD/tree.out" | tr '\n' '|')"; fi
# Positive control: an EMPTY finding set would also "match" an empty baseline.
if grep -q 'nftban_ddos_teardown()  nftban_ddos_classic_disable' "$TMPD/tree.out"; then
    ok "T2 positive control: the known nftban_ddos_teardown suppression is still reported"
else
    fail "T2 positive control lost: nftban_ddos_teardown is no longer reported — fixed (remove its baseline row) or the guard went blind"
fi
if grep -q 'nftban_portscan_teardown' "$TMPD/tree.out"; then
    fail "T3 nftban_portscan_teardown is reported again — the v1.233.1 fix regressed"
else ok "T3 nftban_portscan_teardown carries no suppression finding"; fi

echo ""
if (( FAILURES > 0 )); then
    echo "::error::mutation-result suppression guard test FAILED: $FAILURES"
    exit 1
fi
echo "mutation-result suppression guard test PASSED"
