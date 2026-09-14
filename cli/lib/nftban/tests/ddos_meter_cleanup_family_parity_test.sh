#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
#
# meta:name="ddos_meter_cleanup_family_parity_test.sh"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-14"
# meta:description="Binds the DDoS stale-meter cleanup blocks to v4/v6 family parity. On re-enable, nftban_ddos_classic.sh deletes the previous run's meter sets before re-rendering the fragment, because nft treats 'add set' on an existing set as a no-op: a meter that is not deleted survives carrying its OLD size/timeout definition, so a changed DDOS_CLASSIC_* setting silently fails to take effect on that family while the other family picks it up, with no operator signal. The classic block deleted three IPv4 meters but only two IPv6 meters - ddos_udp_flood6 (created at nft_fragment.sh:1057, referenced at :1075) was never deleted. Section A proves emission at runtime with a PATH-shimmed nft recorder; Section B is a generic structural parity sweep over EVERY cleanup block in the file so a future omission in any block is caught; Section C runs Section B's checker against the pre-fix file taken from the immutable v1.230.0 tag and requires it to FAIL there, so the harness proves it discriminates. Hermetic: shimmed nft, stubbed fragment render/apply, no root, no network, no real nftables."
# meta:inventory.files=""
# meta:inventory.binaries="git,nft(shimmed)"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="unprivileged"
# meta:ta.id="ddos_meter_cleanup_family_parity_test"
# meta:ta.owner="ddos"
# meta:ta.module="ddos-meter-cleanup-parity"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SUBJECT="$ROOT/cli/lib/nftban/core/nftban_ddos_classic.sh"
SB="$(mktemp -d)"
cleanup() { rm -rf "$SB"; }
trap cleanup EXIT

PASS=0; FAIL=0
assert() {
    local label="$1" cond="$2" detail="${3:-}"
    if [[ "$cond" == "0" ]]; then PASS=$((PASS+1)); echo "[PASS] $label"
    else FAIL=$((FAIL+1)); echo "[FAIL] $label${detail:+ -- $detail}"; fi
}

echo "==============================================================================="
echo "DDoS stale-meter cleanup - IPv4/IPv6 family parity"
echo "==============================================================================="

# =============================================================================
# SECTION A - RUNTIME EMISSION (PATH-shimmed nft recorder)
# =============================================================================
# The subject is what the function ACTUALLY invokes, not what the source looks
# like, so the primary proof records real `nft` argv.

NFTLOG="$SB/nft.log"
mkdir -p "$SB/bin"
cat > "$SB/bin/nft" <<SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$NFTLOG"
exit 0
SHIM
chmod +x "$SB/bin/nft"

run_setup() {
    # $1 = function to invoke. Runs in a subshell so shim overrides never leak.
    local fn="$1"
    (
        set +e
        export PATH="$SB/bin:$PATH"
        export NFTBAN_LIB_DIR="$ROOT/cli/lib/nftban"
        # shellcheck source=/dev/null
        source "$SUBJECT" >/dev/null 2>&1
        # Neutralise everything downstream of the cleanup block. Overriding
        # AFTER the source is deliberate: the cleanup block must run for real.
        nft_fragment_render_ddos_classic() { echo "$SB/frag.nft"; }
        nft_fragment_render_ddos_prefix()  { echo "$SB/frag.nft"; }
        nft_fragment_render_ddos_classic_jump() { echo "$SB/frag.nft"; }
        nft_fragment_apply() { return 0; }
        _nftban_ddos_classic_jump_exists() { return 0; }
        _nftban_ddos_prefix_has_ipc() { return 0; }
        _nftban_ddos_classic_log() { return 0; }
        # The prefix block is config-gated (:439). Force it past the gate so the
        # positive baseline actually reaches its cleanup block rather than
        # returning early and "passing" on an empty log.
        DDOS_PREFIX_ENABLED="true"
        "$fn" >/dev/null 2>&1
    )
}

: > "$NFTLOG"
run_setup _nftban_ddos_classic_setup_via_ipc
CLASSIC_LOG="$(cat "$NFTLOG")"

# The classic fragment creates three meter families on EACH of ip and ip6
# (nft_fragment.sh:1013/1015/1017 for v4, :1053/1055/1057 for v6), so a correct
# cleanup deletes six sets.
for m in ddos_syn_flood ddos_icmp_flood ddos_udp_flood; do
    printf '%s\n' "$CLASSIC_LOG" | grep -qF "delete set ip nftban $m"
    assert "A1 classic cleanup deletes IPv4 meter '$m'" "$?" "nft log: $CLASSIC_LOG"
done
for m in ddos_syn_flood6 ddos_icmp_flood6 ddos_udp_flood6; do
    printf '%s\n' "$CLASSIC_LOG" | grep -qF "delete set ip6 nftban $m"
    assert "A2 classic cleanup deletes IPv6 meter '$m'" "$?" "nft log: $CLASSIC_LOG"
done

n4=$(printf '%s\n' "$CLASSIC_LOG" | grep -c '^delete set ip nftban ' || true)
n6=$(printf '%s\n' "$CLASSIC_LOG" | grep -c '^delete set ip6 nftban ' || true)
[[ "$n4" -eq "$n6" ]]
assert "A3 classic cleanup deletes the same COUNT per family (v4=$n4, v6=$n6)" "$?"

# Positive baseline: the prefix block in the same file was already symmetric.
# Asserting it too proves Section A is not vacuously passing on an empty log.
: > "$NFTLOG"
run_setup _nftban_ddos_prefix_setup_via_ipc
PREFIX_LOG="$(cat "$NFTLOG")"
p4=$(printf '%s\n' "$PREFIX_LOG" | grep -c '^delete set ip nftban ' || true)
p6=$(printf '%s\n' "$PREFIX_LOG" | grep -c '^delete set ip6 nftban ' || true)
[[ "$p4" -eq 2 && "$p6" -eq 2 ]]
assert "A4 prefix cleanup (already symmetric) emits 2 per family (v4=$p4, v6=$p6)" "$?" "nft log: $PREFIX_LOG"

# =============================================================================
# SECTION B - STRUCTURAL PARITY SWEEP (generic, all cleanup blocks)
# =============================================================================
# Section A only covers the two functions it invokes. This sweep binds EVERY
# `nft delete set` site in the file, so an omission in a block added later is
# caught without anyone remembering to extend Section A.
#
# Normalisation: a v4 delete names a meter var, the v6 sibling names the same
# var with a literal `6` suffix. Reduce both to the bare variable name and
# require the two multisets to be equal.
parity_check() {
    local file="$1" v4 v6
    v4=$(grep -oE 'nft delete set \$table_v4 "\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"' "$file" \
         | sed -E 's/.*"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"/\1/' | sort)
    v6=$(grep -oE 'nft delete set \$table_v6 "\$\{[A-Za-z_][A-Za-z0-9_]*\}6"' "$file" \
         | sed -E 's/.*"\$\{([A-Za-z_][A-Za-z0-9_]*)\}6"/\1/' | sort)
    if [[ "$v4" == "$v6" ]]; then
        return 0
    fi
    printf 'v4-only: %s\n' "$(comm -23 <(printf '%s\n' "$v4") <(printf '%s\n' "$v6") | tr '\n' ' ')" >&2
    printf 'v6-only: %s\n' "$(comm -13 <(printf '%s\n' "$v4") <(printf '%s\n' "$v6") | tr '\n' ' ')" >&2
    return 1
}

B_ERR="$SB/b.err"
parity_check "$SUBJECT" 2>"$B_ERR"
assert "B1 every 'nft delete set' v4 meter has a matching v6 sibling" "$?" "$(cat "$B_ERR")"

# =============================================================================
# SECTION C - NEGATIVE CONTROL (immutable pre-fix subject)
# =============================================================================
# v1.230.0 is a TAG, not a branch: it cannot invert the moment this fix merges,
# which origin/main would. If the ref is unreachable the control is SKIPPED
# LOUDLY and is NOT counted as a pass.
BASE_REF="v1.230.0"
OLD="$SB/prefix_nftban_ddos_classic.sh"
if git -C "$ROOT" show "${BASE_REF}:cli/lib/nftban/core/nftban_ddos_classic.sh" > "$OLD" 2>/dev/null; then
    if parity_check "$OLD" 2>/dev/null; then
        assert "C1 negative control: B1's checker FAILS on the pre-fix ${BASE_REF} subject" "1" \
               "checker passed on the known-defective file - it does not discriminate"
    else
        assert "C1 negative control: B1's checker FAILS on the pre-fix ${BASE_REF} subject" "0"
    fi
else
    echo "[SKIP] C1 negative control: ${BASE_REF} unreachable - NOT counted as pass"
fi

echo "==============================================================================="
echo "ddos_meter_cleanup_family_parity: PASS=$PASS FAIL=$FAIL"
echo "==============================================================================="
[[ "$FAIL" -eq 0 ]]
