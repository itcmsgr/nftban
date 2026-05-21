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
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
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

// =============================================================================
// v1.125 R-1: SSH multi-port render
// =============================================================================
// Tests for the new RenderNftablesConfMultiPort entry point that closes the
// dns2-class lockout vector. The pre-v1.125 RenderNftablesConf path is kept
// as a back-compat shim around RenderNftablesConfMultiPort with a
// single-element slice — both paths share the same V121 injection helper
// (ensureSSHPortInTcpPortsIn), exercised here directly to assert multi-port
// behavior without spinning up the full executor/file I/O machinery.
//
// Scope per AUDIT_190_LIFECYCLE/V125_INSTALL_ROBUSTNESS_SCOPE.md §3.1 R-1.
// =============================================================================

func TestEnsureSSHPortInTcpPortsIn_MultiPort_BothInjected(t *testing.T) {
	// Template lacks both SSH ports — verify that calling the injection
	// helper once per port (matching RenderNftablesConfMultiPort's loop)
	// lands both ports in the rendered allow-set.
	log := newRenderTestLogger(t)
	defer log.Close()
	input := `set tcp_ports_in {
	elements = { 80, 443 }
}`
	// Simulate the v1.125 R-1 multi-port render loop: injection helper
	// called once per port, in order (primary first).
	out := ensureSSHPortInTcpPortsIn(input, 22, log)
	out = ensureSSHPortInTcpPortsIn(out, 55000, log)

	for _, p := range []string{"22", "55000", "80", "443"} {
		if !strings.Contains(out, p) {
			t.Errorf("expected port %s in multi-port allow-set; got:\n%s", p, out)
		}
	}
}

func TestEnsureSSHPortInTcpPortsIn_MultiPort_PrimaryAlreadyPresent_AdditionalInjected(t *testing.T) {
	// Template already carries the primary (via Mechanism A or Mechanism B
	// from V121); the additional multi-port (v1.125 R-1) still needs
	// injection.
	log := newRenderTestLogger(t)
	defer log.Close()
	input := `set tcp_ports_in {
	elements = { 22, 80, 443 }
}`
	// Primary 22 is already present → no-op. Additional 55000 → injection.
	out := ensureSSHPortInTcpPortsIn(input, 22, log)
	out = ensureSSHPortInTcpPortsIn(out, 55000, log)

	if !strings.Contains(out, "22") {
		t.Errorf("primary port 22 missing from output:\n%s", out)
	}
	if !strings.Contains(out, "55000") {
		t.Errorf("additional port 55000 missing from output:\n%s", out)
	}
	// Original non-SSH entries preserved.
	if !strings.Contains(out, "80") || !strings.Contains(out, "443") {
		t.Errorf("original ports lost:\n%s", out)
	}
}

func TestEnsureSSHPortInTcpPortsIn_MultiPort_Idempotent_AcrossCalls(t *testing.T) {
	// Calling the helper twice for the same port (e.g., the multi-port
	// loop re-encounters the same value) must be a no-op on the second
	// call. The fast-path strings.Contains check inside the helper
	// guarantees this.
	log := newRenderTestLogger(t)
	defer log.Close()
	input := `set tcp_ports_in {
	elements = { 80 }
}`
	once := ensureSSHPortInTcpPortsIn(input, 55000, log)
	twice := ensureSSHPortInTcpPortsIn(once, 55000, log)
	if once != twice {
		t.Errorf("multi-port injection NOT idempotent:\nonce:\n%s\ntwice:\n%s", once, twice)
	}
}

// TestRenderNftablesConfMultiPort_EmptySSHPorts asserts the function's
// pre-condition: caller MUST supply at least one port (the primary).
// The single-port back-compat shim RenderNftablesConf always supplies
// []int{sshPort}, so this error path is unreachable from existing
// callers; it guards against future multi-port-aware callers passing
// an empty slice by accident.
func TestRenderNftablesConfMultiPort_EmptySSHPorts(t *testing.T) {
	log := newRenderTestLogger(t)
	defer log.Close()
	// Cannot exercise the full render path without an executor; assert
	// the early-return error path via the public API. Using nil
	// executor is acceptable because the empty-sshPorts check fires
	// before any executor method is called.
	err := RenderNftablesConfMultiPort(nil, nil, detect.CTLimits{}, log)
	if err == nil {
		t.Fatalf("expected error on empty sshPorts; got nil")
	}
	if !strings.Contains(err.Error(), "sshPorts is empty") {
		t.Errorf("expected 'sshPorts is empty' in error; got: %v", err)
	}
	// Empty slice (vs nil) — same code path.
	err = RenderNftablesConfMultiPort(nil, []int{}, detect.CTLimits{}, log)
	if err == nil {
		t.Fatalf("expected error on empty sshPorts slice; got nil")
	}
}

// TestEnsureSSHPortInTcpPortsIn_PortSubstringDoesNotCount is the v1.125 R-1
// regression guard for the pre-v1.125 substring-presence false positive.
// Pre-fix the helper used strings.Contains(content, "22") which treated port
// 22 as "already present" when only 2222 (e.g., DirectAdmin control port)
// appeared in the elements list — port 22 was then silently NOT injected.
// On DA-class multi-port hosts (dns2 has DA on :2222 + sshd on :22 + :55000)
// the operator's :22 sshd listener would not reach the rendered allow-set.
//
// v1.125 R-1 fix: parse the tcp_ports_in elements list and compare each
// trimmed token against the port literal — eliminates substring false
// positives.
func TestEnsureSSHPortInTcpPortsIn_PortSubstringDoesNotCount(t *testing.T) {
	log := newRenderTestLogger(t)
	defer log.Close()
	input := `set tcp_ports_in {
	elements = { 2222, 80, 443 }
}`
	out := ensureSSHPortInTcpPortsIn(input, 22, log)
	// Port 22 MUST be injected as an exact whole token (not masked by "2222").
	if !regexp.MustCompile(`(^|[^0-9])22([^0-9]|$)`).MatchString(out) {
		t.Fatalf("expected exact port 22 to be injected as a whole token; got:\n%s", out)
	}
	// Original 2222 entry must still be present.
	if !strings.Contains(out, "2222") {
		t.Errorf("original port 2222 lost from output:\n%s", out)
	}
	// Idempotency on the new strict-presence check.
	out2 := ensureSSHPortInTcpPortsIn(out, 22, log)
	if out2 != out {
		t.Errorf("strict-presence check is NOT idempotent: second call mutated content:\n%s\n---vs---\n%s", out, out2)
	}
}

// TestEnsureSSHPortInTcpPortsIn_AdditionalSubstringDoesNotCount covers the
// 80-vs-8080 / 443-vs-44300 / 22-vs-2222 family of substring false positives
// in one parametrized test. Each row: template has only the *masking* port
// (no whole-token match for the *target* port); helper MUST inject the
// target port; output MUST contain target as a whole numeric token AND
// preserve the masking entry.
func TestEnsureSSHPortInTcpPortsIn_AdditionalSubstringDoesNotCount(t *testing.T) {
	tests := []struct {
		name        string
		template    string
		target      int
		maskingPort string // numeric token already in template that contains target as substring
	}{
		{"22 vs 2222 (DA control)", `set tcp_ports_in { elements = { 2222 } }`, 22, "2222"},
		{"80 vs 8080 (alt-http)", `set tcp_ports_in { elements = { 8080 } }`, 80, "8080"},
		{"443 vs 44300", `set tcp_ports_in { elements = { 44300 } }`, 443, "44300"},
		{"22 vs 522 (suffix mask)", `set tcp_ports_in { elements = { 522 } }`, 22, "522"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			log := newRenderTestLogger(t)
			defer log.Close()
			out := ensureSSHPortInTcpPortsIn(tt.template, tt.target, log)
			targetStr := strconv.Itoa(tt.target)
			// Exact whole-token match for target.
			tokRe := regexp.MustCompile(`(^|[^0-9])` + targetStr + `([^0-9]|$)`)
			if !tokRe.MatchString(out) {
				t.Errorf("target port %d not injected as whole token; got:\n%s", tt.target, out)
			}
			// Masking port preserved.
			if !strings.Contains(out, tt.maskingPort) {
				t.Errorf("masking port %s lost from output:\n%s", tt.maskingPort, out)
			}
		})
	}
}

// TestRenderNftablesConfMultiPort_PrimaryFirst_SSHPortSubstitution is the
// v1.125 R-1 end-to-end guard for the primary-first contract: when
// sshPorts = [55000, 22] (primary 55000 placed first by DetectSSHPorts via
// primaryFirstPorts), the rendered nftables.conf MUST have __SSH_PORT__
// substituted with 55000 (the primary), not with 22 (the additional port).
//
// Without this test, the dns2-class regression would be: SSH_CLIENT=55000
// → primary=55000 → ports=[22,55000] (UNORDERED) → __SSH_PORT__ replaced
// with 22 → per-IP SSH rate-limit rule applied to wrong port. The fix
// (primaryFirstPorts) makes ports=[55000,22] so sshPorts[0]=55000 and
// __SSH_PORT__ correctly substitutes 55000.
func TestRenderNftablesConfMultiPort_PrimaryFirst_SSHPortSubstitution(t *testing.T) {
	log := newRenderTestLogger(t)
	defer log.Close()
	mock := executor.NewMockExecutor()
	// Template with __SSH_PORT__ placeholder (per-IP rate-limit rule
	// canonical line) + a tcp_ports_in set that already has the primary
	// (so the post-substitution path exercises both code paths).
	mock.Files["/etc/nftban/nftables.conf"] = []byte(`# Simulated template
table ip nftban {
	set tcp_ports_in {
		type inet_service
		elements = { 55000, 80, 443 }
	}
	chain input {
		ct state new tcp dport __SSH_PORT__ ct count over 15 counter drop comment "SSH rate-limit"
	}
}
`)

	// Primary-first slice as DetectSSHPorts would emit on SSH_CLIENT=55000.
	err := RenderNftablesConfMultiPort(mock, []int{55000, 22}, detect.CTLimits{SSH: 15, HTTP: 200, Mail: 30}, log)
	if err != nil {
		t.Fatalf("RenderNftablesConfMultiPort: %v", err)
	}

	written, ok := mock.WrittenFiles["/etc/nftban/nftables.conf"]
	if !ok {
		t.Fatal("RenderNftablesConfMultiPort did not write /etc/nftban/nftables.conf")
	}
	out := string(written)

	// __SSH_PORT__ substitution MUST use the primary (55000), not the
	// additional port (22). Look for the canonical rate-limit line.
	if !strings.Contains(out, "tcp dport 55000 ct count over 15") {
		t.Errorf("__SSH_PORT__ substitution did not use primary=55000; rendered output:\n%s", out)
	}
	// And it must NOT have replaced with the additional port.
	if strings.Contains(out, "tcp dport 22 ct count over 15") {
		t.Errorf("__SSH_PORT__ substitution incorrectly used additional port 22 instead of primary 55000; rendered output:\n%s", out)
	}
	// Additional port (22) MUST be injected into tcp_ports_in allow-set
	// as a whole token (and not be masked by the existing 55000 entry).
	tokRe := regexp.MustCompile(`(^|[^0-9])22([^0-9]|$)`)
	if !tokRe.MatchString(out) {
		t.Errorf("additional port 22 not injected as whole token into tcp_ports_in; rendered output:\n%s", out)
	}
}
