#!/usr/bin/env bash
# =============================================================================
# NFTBan - Tests for v1.155 PR-2 SSH-port-change lifecycle validator
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="ssh_port_change_lifecycle_v155_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-06"
# meta:description="Hermetic tests for tools/validation/ssh_port_change_lifecycle_validate.sh (v1.155 PR-2 / item 3.3). Feeds a good rendered-ruleset+listeners fixture (exit 0, all invariants hold) and four injected drifts (listener not in ssh_ports; listener not in tcp_ports_in; literal 'tcp dport 22 ct count' instead of @ssh_ports; missing @ssh_ports rule), each asserted to fail with the right invariant message and a non-zero exit. Hermetic: inputs injected via NFTBAN_VALIDATE_RULESET_FILE + NFTBAN_VALIDATE_LISTENERS; no host/nft/root."
# meta:input="None (self-contained sandbox fixtures)"
# meta:output="Pass/fail assertions on stdout; exit 0 on all-pass"
# meta:depends="bash,grep,awk,sort,paste,tr"
# meta:inventory.files="tools/validation/ssh_port_change_lifecycle_validate.sh"
# meta:inventory.binaries="bash,grep,awk,sort,paste,tr"
# meta:inventory.env_vars="NFTBAN_VALIDATE_RULESET_FILE,NFTBAN_VALIDATE_LISTENERS"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="ssh_port_change_lifecycle_v155_test"
# meta:ta.owner="firewall"
# meta:ta.module="ssh-port-lifecycle-validate"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
VALIDATOR="$REPO_ROOT/tools/validation/ssh_port_change_lifecycle_validate.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# run_validator <ruleset-file> <listeners> -> sets RC + OUT
run_validator() {
    local rf="$1" listeners="$2"
    OUT=""; RC=0
    OUT="$(NFTBAN_VALIDATE_RULESET_FILE="$rf" NFTBAN_VALIDATE_LISTENERS="$listeners" \
        bash "$VALIDATOR" 2>&1)" || RC=$?
}

# ---- fixture builders ----------------------------------------------------
# A well-formed rendered ruleset: tcp_ports_in + ssh_ports both contain the
# listener(s); brute-force rule is set-driven (@ssh_ports), no literal dport.
write_good_ruleset() {
    local f="$1" sshports="$2" tcpin="$3"
    cat > "$f" <<EOF
table ip nftban {
	set tcp_ports_in {
		type inet_service
		elements = { ${tcpin} }
	}
	set ssh_ports {
		type inet_service
		elements = { ${sshports} }
	}
	chain input {
		type filter hook input priority 0; policy drop;
		ct state established,related accept
		tcp dport @ssh_ports ct state new ct count over 10 counter drop comment "SSH brute-force"
		tcp dport @tcp_ports_in ct state new accept comment "TCP services"
	}
}
EOF
}

echo "=== GOOD config: all four invariants hold (exit 0) ==="
GOOD="$SANDBOX/good.nft"; write_good_ruleset "$GOOD" "22" "22, 80, 443"
run_validator "$GOOD" "22"
[[ $RC -eq 0 ]] && ok "good config exits 0" || no "good config should exit 0 (rc=$RC)" "$OUT"
echo "$OUT" | grep -q "PASS  (a)" && ok "(a) passes" || no "(a) should pass" "$OUT"
echo "$OUT" | grep -q "PASS  (b)" && ok "(b) passes" || no "(b) should pass" "$OUT"
echo "$OUT" | grep -q "PASS  (c)" && ok "(c) passes" || no "(c) should pass" "$OUT"
echo "$OUT" | grep -q "PASS  (d)" && ok "(d) passes" || no "(d) should pass" "$OUT"

echo "=== GOOD config: multi-port sshd (22 + 2222 in both sets) ==="
GOOD2="$SANDBOX/good2.nft"; write_good_ruleset "$GOOD2" "22, 2222" "22, 2222, 80"
run_validator "$GOOD2" "22 2222"
[[ $RC -eq 0 ]] && ok "multi-port good config exits 0" || no "multi-port should exit 0 (rc=$RC)" "$OUT"

echo "=== DRIFT (b): listener not in ssh_ports ==="
# sshd now listens on 2222 but ssh_ports still only has 22.
DRIFT_B="$SANDBOX/drift_b.nft"; write_good_ruleset "$DRIFT_B" "22" "22, 2222, 80"
run_validator "$DRIFT_B" "2222"
[[ $RC -ne 0 ]] && ok "drift-(b) exits non-zero" || no "drift-(b) should fail" "$OUT"
echo "$OUT" | grep -q "FAIL  (b)" && ok "drift-(b) reports invariant (b) failure" || no "drift-(b) message" "$OUT"
echo "$OUT" | grep -q "NOT in ssh_ports: 2222" && ok "drift-(b) names the missing port" || no "drift-(b) names port" "$OUT"

echo "=== DRIFT (a): listener not in tcp_ports_in ==="
# ssh_ports has 2222 but tcp_ports_in does not → service port would be filtered.
DRIFT_A="$SANDBOX/drift_a.nft"; write_good_ruleset "$DRIFT_A" "2222" "22, 80"
run_validator "$DRIFT_A" "2222"
[[ $RC -ne 0 ]] && ok "drift-(a) exits non-zero" || no "drift-(a) should fail" "$OUT"
echo "$OUT" | grep -q "FAIL  (a)" && ok "drift-(a) reports invariant (a) failure" || no "drift-(a) message" "$OUT"
echo "$OUT" | grep -q "NOT in tcp_ports_in: 2222" && ok "drift-(a) names the missing port" || no "drift-(a) names port" "$OUT"

echo "=== DRIFT (d)+(c): literal 'tcp dport 22 ct count' instead of @ssh_ports ==="
DRIFT_D="$SANDBOX/drift_d.nft"
cat > "$DRIFT_D" <<'EOF'
table ip nftban {
	set tcp_ports_in {
		type inet_service
		elements = { 22, 80, 443 }
	}
	set ssh_ports {
		type inet_service
		elements = { 22 }
	}
	chain input {
		type filter hook input priority 0; policy drop;
		tcp dport 22 ct state new ct count over 10 counter drop comment "SSH brute-force literal"
		tcp dport @tcp_ports_in ct state new accept
	}
}
EOF
run_validator "$DRIFT_D" "22"
[[ $RC -ne 0 ]] && ok "drift-(d) exits non-zero" || no "drift-(d) should fail" "$OUT"
echo "$OUT" | grep -q "FAIL  (d)" && ok "drift-(d) reports invariant (d) failure (literal dport)" || no "drift-(d) message" "$OUT"
echo "$OUT" | grep -q "FAIL  (c)" && ok "drift-(d) also fails (c) (no @ssh_ports ct-count rule)" || no "drift-(c) message" "$OUT"

echo "=== DRIFT (c): @ssh_ports set exists but no ct-count rule references it ==="
DRIFT_C="$SANDBOX/drift_c.nft"
cat > "$DRIFT_C" <<'EOF'
table ip nftban {
	set tcp_ports_in {
		type inet_service
		elements = { 22, 80 }
	}
	set ssh_ports {
		type inet_service
		elements = { 22 }
	}
	chain input {
		type filter hook input priority 0; policy drop;
		tcp dport @tcp_ports_in ct state new accept
	}
}
EOF
run_validator "$DRIFT_C" "22"
[[ $RC -ne 0 ]] && ok "drift-(c) exits non-zero" || no "drift-(c) should fail" "$OUT"
echo "$OUT" | grep -q "FAIL  (c)" && ok "drift-(c) reports invariant (c) failure" || no "drift-(c) message" "$OUT"

echo ""
echo "================================================================"
echo "ssh_port_change_lifecycle_v155: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
