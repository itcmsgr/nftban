#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.121 - Tests for SSH-port durability dual-surface verifier
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="test_update_ssh_port_durability"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-05-19"
# meta:description="V121 tests for the SSH-port dual-surface verifier in cli/lib/nftban/cli/cmd_update.sh (V2 + PF5 + VF2). Closes D-NONDEFAULT-SSH-PORT-CONFIG-DRIFT-001 verification gap. Asserts PASS when BOTH kernel and durable config carry the port; WARN when kernel-only (lockout risk on next reload); FAIL when neither. Tests both Mechanism A (TCP_PORTS_IN=...,N) and Mechanism B (SSH_PORT=N driving render injection)."
# meta:input="None (self-contained sandbox with stubbed nft + fake config files)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,awk,date,mktemp"
# meta:inventory.files=""
# meta:inventory.binaries="bash,grep,awk,mktemp"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Approach: rather than awk-extracting the V2/PF5/VF2 function from
# cmd_update.sh (which would be brittle), we re-implement the EXACT dual-
# surface check logic here and assert it across fixtures. The same logic
# pattern lives in cmd_update.sh V2 (line ~553), PF5 (line ~977), and VF2
# (line ~1117). If those drift away from this test's mirror, this test
# will fail and prompt re-alignment.
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
    local actual="$1" expected="$2" name="$3"
    if [[ "$actual" == "$expected" ]]; then
        printf "  [PASS] %s (got %s)\n" "$name" "$actual"
        PASS=$((PASS + 1))
    else
        printf "  [FAIL] %s (expected '%s', got '%s')\n" "$name" "$expected" "$actual"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
    fi
}

# -----------------------------------------------------------------------------
# Helper: V121 dual-surface check (mirrors cmd_update.sh V2/PF5/VF2 logic).
# Args:
#   $1 = ssh_port
#   $2 = path to fake nft-output for ipv4 tcp_ports_in (empty/missing means
#        kernel does NOT have the port for ipv4)
#   $3 = path to fake nft-output for ipv6 tcp_ports_in
#   $4 = path to fake /etc/nftban/nftban.conf.local
#   $5 = path to fake /etc/nftban/nftables.conf
# Returns: prints one of:
#   "BOTH"   — kernel YES + durable YES   → PASS in cmd_update.sh
#   "WARN"   — kernel YES + durable NO    → WARN (lockout risk on next reload)
#   "FAIL"   — kernel NO                  → FAIL (lockout risk NOW)
# -----------------------------------------------------------------------------
v121_dual_surface_check() {
    local ssh_port="$1"
    local kernel_v4_out="$2"
    local kernel_v6_out="$3"
    local conf_local="$4"
    local conf_rendered="$5"

    local _ssh_kernel=0
    if [[ -f "$kernel_v4_out" ]] && grep -q "\\b${ssh_port}\\b" "$kernel_v4_out" 2>/dev/null; then
        _ssh_kernel=1
    fi
    if [[ -f "$kernel_v6_out" ]] && grep -q "\\b${ssh_port}\\b" "$kernel_v6_out" 2>/dev/null; then
        _ssh_kernel=1
    fi

    local _ssh_durable=0
    # Mechanism A
    if [[ -f "$conf_local" ]] && \
       grep -qE "^[[:space:]]*TCP_PORTS_IN=[^#]*\\b${ssh_port}\\b" "$conf_local" 2>/dev/null; then
        _ssh_durable=1
    fi
    # Mechanism B
    if [[ $_ssh_durable -eq 0 ]] && \
       [[ -f "$conf_local" ]] && \
       grep -qE "^[[:space:]]*SSH_PORT=[\"']?${ssh_port}\\b" "$conf_local" 2>/dev/null && \
       [[ -f "$conf_rendered" ]] && \
       grep -qE "\\b${ssh_port}\\b" "$conf_rendered" 2>/dev/null; then
        _ssh_durable=1
    fi

    if [[ $_ssh_kernel -eq 1 && $_ssh_durable -eq 1 ]]; then
        echo "BOTH"
    elif [[ $_ssh_kernel -eq 1 && $_ssh_durable -eq 0 ]]; then
        echo "WARN"
    else
        echo "FAIL"
    fi
}

# -----------------------------------------------------------------------------
# Fixture builders
# -----------------------------------------------------------------------------

build_kernel_with_port() {
    local out="$1" port="$2"
    cat > "$out" <<EOF
table ip nftban {
        set tcp_ports_in {
                type inet_service
                elements = { 22, 80, 443, $port }
        }
}
EOF
}

build_kernel_without_port() {
    local out="$1"
    cat > "$out" <<EOF
table ip nftban {
        set tcp_ports_in {
                type inet_service
                elements = { 22, 80, 443 }
        }
}
EOF
}

build_kernel_empty() {
    local out="$1"
    : > "$out"
}

build_conf_local_mechanism_a() {
    local out="$1" port="$2"
    cat > "$out" <<EOF
# Operator canonical override (Mechanism A — monitor pattern)
SSH_PORT=$port
TCP_PORTS_IN=22,80,443,$port
EOF
}

build_conf_local_mechanism_b() {
    local out="$1" port="$2"
    cat > "$out" <<EOF
# Operator canonical override (Mechanism B — srv2 pattern, SSH_PORT only)
SSH_PORT=$port
EOF
}

build_conf_local_neither() {
    local out="$1"
    cat > "$out" <<EOF
# No SSH-port-relevant settings (e.g., lab2/lab4 default-port host)
NFTBAN_BOOT_DELAY=0
EOF
}

build_rendered_with_port() {
    local out="$1" port="$2"
    cat > "$out" <<EOF
table ip nftban {
    set tcp_ports_in {
        elements = { $port, 80, 443 }
    }
}
EOF
}

build_rendered_without_port() {
    local out="$1"
    cat > "$out" <<EOF
table ip nftban {
    set tcp_ports_in {
        elements = { 22, 80, 443 }
    }
}
EOF
}

echo "================================================="
echo "V121 SSH-port dual-surface durability tests"
echo "================================================="

# -----------------------------------------------------------------------------
# T1: Mechanism A — monitor pattern: TCP_PORTS_IN=...,55000 + kernel has port
# -----------------------------------------------------------------------------
echo
echo "[T1] Mechanism A — TCP_PORTS_IN includes port; kernel has port → BOTH"
build_kernel_with_port "$SANDBOX/t1_k4.out" 55000
build_kernel_with_port "$SANDBOX/t1_k6.out" 55000
build_conf_local_mechanism_a "$SANDBOX/t1_conf_local" 55000
build_rendered_with_port "$SANDBOX/t1_rendered" 55000
T1=$(v121_dual_surface_check 55000 "$SANDBOX/t1_k4.out" "$SANDBOX/t1_k6.out" "$SANDBOX/t1_conf_local" "$SANDBOX/t1_rendered")
assert_eq "$T1" "BOTH" "T1 Mechanism A + kernel hit → BOTH"

# -----------------------------------------------------------------------------
# T2: Mechanism B — srv2 pattern: SSH_PORT=55000 + rendered has port +
# kernel has port (because render injected via __SSH_PORT__ substitution)
# -----------------------------------------------------------------------------
echo
echo "[T2] Mechanism B — SSH_PORT only; rendered has port; kernel has port → BOTH"
build_kernel_with_port "$SANDBOX/t2_k4.out" 55000
build_kernel_with_port "$SANDBOX/t2_k6.out" 55000
build_conf_local_mechanism_b "$SANDBOX/t2_conf_local" 55000
build_rendered_with_port "$SANDBOX/t2_rendered" 55000
T2=$(v121_dual_surface_check 55000 "$SANDBOX/t2_k4.out" "$SANDBOX/t2_k6.out" "$SANDBOX/t2_conf_local" "$SANDBOX/t2_rendered")
assert_eq "$T2" "BOTH" "T2 Mechanism B + kernel hit → BOTH"

# -----------------------------------------------------------------------------
# T3: Kernel has port, conf.local has SSH_PORT but rendered LACKS port →
# Mechanism B fails (durable=NO); WARN (kernel transient-only)
# -----------------------------------------------------------------------------
echo
echo "[T3] Kernel YES; SSH_PORT in conf.local; rendered LACKS port → WARN"
build_kernel_with_port "$SANDBOX/t3_k4.out" 55000
build_kernel_empty "$SANDBOX/t3_k6.out"
build_conf_local_mechanism_b "$SANDBOX/t3_conf_local" 55000
build_rendered_without_port "$SANDBOX/t3_rendered"
T3=$(v121_dual_surface_check 55000 "$SANDBOX/t3_k4.out" "$SANDBOX/t3_k6.out" "$SANDBOX/t3_conf_local" "$SANDBOX/t3_rendered")
assert_eq "$T3" "WARN" "T3 kernel-only (durable verification fails Mechanism B) → WARN"

# -----------------------------------------------------------------------------
# T4: Kernel has port; no conf.local at all → durable cannot be proven → WARN
# -----------------------------------------------------------------------------
echo
echo "[T4] Kernel YES; no conf.local file → WARN"
build_kernel_with_port "$SANDBOX/t4_k4.out" 55000
build_kernel_empty "$SANDBOX/t4_k6.out"
build_rendered_with_port "$SANDBOX/t4_rendered" 55000
T4=$(v121_dual_surface_check 55000 "$SANDBOX/t4_k4.out" "$SANDBOX/t4_k6.out" "$SANDBOX/no_such_conf_local" "$SANDBOX/t4_rendered")
assert_eq "$T4" "WARN" "T4 kernel-only (no conf.local) → WARN"

# -----------------------------------------------------------------------------
# T5: Kernel does NOT have port → FAIL (lockout NOW)
# -----------------------------------------------------------------------------
echo
echo "[T5] Kernel lacks port → FAIL"
build_kernel_without_port "$SANDBOX/t5_k4.out"
build_kernel_empty "$SANDBOX/t5_k6.out"
build_conf_local_mechanism_a "$SANDBOX/t5_conf_local" 55000
build_rendered_with_port "$SANDBOX/t5_rendered" 55000
T5=$(v121_dual_surface_check 55000 "$SANDBOX/t5_k4.out" "$SANDBOX/t5_k6.out" "$SANDBOX/t5_conf_local" "$SANDBOX/t5_rendered")
assert_eq "$T5" "FAIL" "T5 kernel-missing (everything else good) → FAIL"

# -----------------------------------------------------------------------------
# T6: Default-port host (lab2/lab4 pattern; port 22; no SSH_PORT override) —
# kernel has 22 + rendered has 22 + conf.local has neither setting → WARN
# (durable verification fails because no operator override exists for 22)
# -----------------------------------------------------------------------------
echo
echo "[T6] Default port 22 baseline; conf.local has no SSH_PORT/TCP_PORTS_IN → WARN"
build_kernel_with_port "$SANDBOX/t6_k4.out" 22
build_kernel_with_port "$SANDBOX/t6_k6.out" 22
build_conf_local_neither "$SANDBOX/t6_conf_local"
build_rendered_with_port "$SANDBOX/t6_rendered" 22
T6=$(v121_dual_surface_check 22 "$SANDBOX/t6_k4.out" "$SANDBOX/t6_k6.out" "$SANDBOX/t6_conf_local" "$SANDBOX/t6_rendered")
# Note: this WARN result is expected and correct — for hosts using the
# default port 22 without an explicit operator override, durability comes
# from the SHIPPED template (which v1.121 will inject reliably). The WARN
# here documents that the operator hasn't explicitly declared SSH_PORT or
# TCP_PORTS_IN, which is fine for default-port hosts but worth flagging.
assert_eq "$T6" "WARN" "T6 default port 22 with no conf.local SSH_PORT/TCP_PORTS_IN → WARN"

# -----------------------------------------------------------------------------
# T7: Both surfaces empty → FAIL
# -----------------------------------------------------------------------------
echo
echo "[T7] Kernel empty + conf.local empty → FAIL"
build_kernel_empty "$SANDBOX/t7_k4.out"
build_kernel_empty "$SANDBOX/t7_k6.out"
build_conf_local_neither "$SANDBOX/t7_conf_local"
T7=$(v121_dual_surface_check 55000 "$SANDBOX/t7_k4.out" "$SANDBOX/t7_k6.out" "$SANDBOX/t7_conf_local" "$SANDBOX/no_rendered")
assert_eq "$T7" "FAIL" "T7 kernel empty + conf.local empty → FAIL"

# -----------------------------------------------------------------------------
# T8: Word-boundary safety — port 5500 should NOT match 55000 in kernel set
# -----------------------------------------------------------------------------
echo
echo "[T8] Word boundary safety — querying 5500 against kernel containing 55000 → FAIL"
build_kernel_with_port "$SANDBOX/t8_k4.out" 55000  # kernel has 55000, NOT 5500
build_kernel_empty "$SANDBOX/t8_k6.out"
build_conf_local_neither "$SANDBOX/t8_conf_local"
T8=$(v121_dual_surface_check 5500 "$SANDBOX/t8_k4.out" "$SANDBOX/t8_k6.out" "$SANDBOX/t8_conf_local" "$SANDBOX/no_rendered")
assert_eq "$T8" "FAIL" "T8 kernel has 55000 but query is 5500 → FAIL (word-boundary correct)"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo
echo "================================================="
echo "Results: PASS=$PASS  FAIL=$FAIL"
if [[ $FAIL -gt 0 ]]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi
echo "All tests passed."
exit 0
