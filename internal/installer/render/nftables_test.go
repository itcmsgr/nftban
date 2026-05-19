// =============================================================================
// NFTBan v1.121 - Installer nftables.conf Render Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-render-nftables-test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-19"
// meta:description="V121 unit tests for ensureSSHPortInTcpPortsIn injection helper. Covers Mechanism A (template hardcodes port via __SSH_PORT__ placeholder substitution), Mechanism B (template hardcodes port directly), Mechanism C (template lacks port — V121 injection fires), idempotency, and multi-set injection (ip + ip6 tcp_ports_in)."
// meta:input="None"
// meta:output="t.Fatalf/t.Errorf on assertion failure"
// meta:depends="testing,internal/installer/logging"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package render

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/logging"
)

func newRenderTestLogger(t *testing.T) *logging.Logger {
	t.Helper()
	return logging.New("/dev/null", false)
}

// TestEnsureSSHPortInTcpPortsIn_Mechanism_A_PortAlreadyPresent asserts
// that templates already carrying the SSH port (e.g., monitor pattern
// where the template hardcodes `tcp_ports_in = { 22, 55000, 80, 443 }`)
// are returned unchanged. V121 injection must be idempotent.
func TestEnsureSSHPortInTcpPortsIn_Mechanism_A_PortAlreadyPresent(t *testing.T) {
	log := newRenderTestLogger(t)
	defer log.Close()
	input := `table ip nftban {
	set tcp_ports_in {
		type inet_service
		elements = { 22, 55000, 80, 443 }
	}
}`
	out := ensureSSHPortInTcpPortsIn(input, 55000, log)
	if out != input {
		t.Errorf("expected no-op for already-present port; got diff:\n--input--\n%s\n--output--\n%s", input, out)
	}
}

// TestEnsureSSHPortInTcpPortsIn_Mechanism_B_PortSubstitutedViaPlaceholder
// asserts that templates where __SSH_PORT__ has already been substituted
// (srv2/lab2/lab4/monitor default pattern) are detected via the fast-path
// substring check and returned unchanged.
func TestEnsureSSHPortInTcpPortsIn_Mechanism_B_PortSubstitutedViaPlaceholder(t *testing.T) {
	log := newRenderTestLogger(t)
	defer log.Close()
	// Simulating post-placeholder-substitution content (55000 was put in place
	// of __SSH_PORT__ in the line above).
	input := `table ip nftban {
	set tcp_ports_in {
		type inet_service
		elements = { 55000, 80, 443 }
	}
}`
	out := ensureSSHPortInTcpPortsIn(input, 55000, log)
	if out != input {
		t.Errorf("expected no-op when substituted port already present; got diff")
	}
}

// TestEnsureSSHPortInTcpPortsIn_Mechanism_C_InjectIntoSingleSet covers the
// V121 primary fix path: template lacks the SSH port entirely, and the
// helper must inject it into the tcp_ports_in elements list.
func TestEnsureSSHPortInTcpPortsIn_Mechanism_C_InjectIntoSingleSet(t *testing.T) {
	log := newRenderTestLogger(t)
	defer log.Close()
	input := `table ip nftban {
	set tcp_ports_in {
		type inet_service
		elements = { 80, 443 }
	}
}`
	out := ensureSSHPortInTcpPortsIn(input, 55000, log)
	if out == input {
		t.Fatalf("expected injection but output is unchanged")
	}
	if !strings.Contains(out, "55000") {
		t.Errorf("expected '55000' in output; got:\n%s", out)
	}
	if !strings.Contains(out, "80, 443") && !strings.Contains(out, "80,  443") {
		t.Errorf("expected existing entries 80, 443 to be preserved; got:\n%s", out)
	}
}

// TestEnsureSSHPortInTcpPortsIn_Mechanism_C_InjectIntoBothSets covers the
// dual-family case (ip nftban + ip6 nftban each have a tcp_ports_in set).
// The V121 injection must apply to both sets.
func TestEnsureSSHPortInTcpPortsIn_Mechanism_C_InjectIntoBothSets(t *testing.T) {
	log := newRenderTestLogger(t)
	defer log.Close()
	input := `table ip nftban {
	set tcp_ports_in {
		type inet_service
		elements = { 80, 443 }
	}
}
table ip6 nftban {
	set tcp_ports_in {
		type inet_service
		elements = { 80, 443 }
	}
}`
	out := ensureSSHPortInTcpPortsIn(input, 55000, log)
	// Both sets must now carry the port.
	count := strings.Count(out, "55000")
	if count < 2 {
		t.Errorf("expected port to appear in both v4 + v6 sets (count >= 2), got count=%d:\n%s", count, out)
	}
}

// TestEnsureSSHPortInTcpPortsIn_Idempotent asserts a second invocation on
// already-injected content does not duplicate the port.
func TestEnsureSSHPortInTcpPortsIn_Idempotent(t *testing.T) {
	log := newRenderTestLogger(t)
	defer log.Close()
	input := `table ip nftban {
	set tcp_ports_in {
		elements = { 80, 443 }
	}
}`
	once := ensureSSHPortInTcpPortsIn(input, 55000, log)
	twice := ensureSSHPortInTcpPortsIn(once, 55000, log)
	if once != twice {
		t.Errorf("expected idempotent (second call unchanged); got:\n--once--\n%s\n--twice--\n%s", once, twice)
	}
	if strings.Count(twice, "55000") != 1 {
		t.Errorf("expected exactly 1 occurrence of '55000' after double-call; got %d", strings.Count(twice, "55000"))
	}
}

// TestEnsureSSHPortInTcpPortsIn_EmptyElements covers the edge case where
// the tcp_ports_in set has an empty `elements = { }` block. Injection
// should produce `elements = { 55000 }`.
func TestEnsureSSHPortInTcpPortsIn_EmptyElements(t *testing.T) {
	log := newRenderTestLogger(t)
	defer log.Close()
	input := `set tcp_ports_in {
	elements = {}
}`
	out := ensureSSHPortInTcpPortsIn(input, 55000, log)
	if !strings.Contains(out, "55000") {
		t.Errorf("expected '55000' to be injected into empty elements list; got:\n%s", out)
	}
}

// TestEnsureSSHPortInTcpPortsIn_NoTcpPortsInSet covers the degenerate case
// where the content has no `tcp_ports_in` set at all. The helper must
// return content unchanged (the outer caller will log a warning).
func TestEnsureSSHPortInTcpPortsIn_NoTcpPortsInSet(t *testing.T) {
	log := newRenderTestLogger(t)
	defer log.Close()
	input := `table ip nftban {
	set whitelist_v4 {
		elements = { 127.0.0.1 }
	}
}`
	out := ensureSSHPortInTcpPortsIn(input, 55000, log)
	if out != input {
		t.Errorf("expected unchanged output when no tcp_ports_in set present; got diff")
	}
}

// TestEnsureSSHPortInTcpPortsIn_MultilineElements covers the realistic
// case where elements span multiple lines (large port lists wrapped):
//
//   elements = { 20, 21, 25, 53, 80,
//                110, 143, 443, 465 }
//
// The regex uses (?s) for dotall; injection should still place the port
// at the head and preserve formatting reasonably.
func TestEnsureSSHPortInTcpPortsIn_MultilineElements(t *testing.T) {
	log := newRenderTestLogger(t)
	defer log.Close()
	input := `set tcp_ports_in {
	elements = { 20, 21, 25, 53, 80,
		     110, 143, 443, 465 }
}`
	out := ensureSSHPortInTcpPortsIn(input, 22222, log)
	if !strings.Contains(out, "22222") {
		t.Errorf("expected '22222' in output; got:\n%s", out)
	}
	// Original entries must still be present.
	for _, p := range []string{"20", "21", "25", "53", "80", "110", "143", "443", "465"} {
		if !strings.Contains(out, p) {
			t.Errorf("expected original port %s preserved; got:\n%s", p, out)
		}
	}
}
