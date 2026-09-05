// =============================================================================
// NFTBan v1.121 - Installer nftables.conf Render Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-render-nftables-test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-19"
// meta:description="V121 unit tests for the ensureSSHPortsInSet injection helper (v1.145 PR-A generalized it from the V121 ensureSSHPortInTcpPortsIn). Covers Mechanism A (template hardcodes port via __SSH_PORT__ placeholder substitution), Mechanism B (template hardcodes port directly), Mechanism C (template lacks port — injection fires), idempotency, multi-set injection (ip + ip6 tcp_ports_in), and v1.145 set-driven ssh_ports injection (tcp dport @ssh_ports brute-force rate-limit) for single-port and multi-port hosts."
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

// ⛔ v1.229.13 Lane 3D.2 — SUPERSESSION NOTICE (assurance MIGRATED, not retired).
// Placeholder substitution now has exactly ONE authority: the shell function
// _firewall_substitute_placeholders. The Go tests that exercised substitution
// here were removed because the BEHAVIOUR left this package, not because the
// guarantees were dropped. They are re-asserted arm for arm, with two
// non-vacuity negative controls, against the real authority in:
//     cli/lib/nftban/tests/render_authority_ssh_union_v1229_13_test.sh

import (
	"regexp"
	"strconv"
	"strings"
	"testing"

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
	out := ensureSSHPortsInSet(input, "tcp_ports_in", 55000, log)
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
	out := ensureSSHPortsInSet(input, "tcp_ports_in", 55000, log)
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
	out := ensureSSHPortsInSet(input, "tcp_ports_in", 55000, log)
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
	out := ensureSSHPortsInSet(input, "tcp_ports_in", 55000, log)
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
	once := ensureSSHPortsInSet(input, "tcp_ports_in", 55000, log)
	twice := ensureSSHPortsInSet(once, "tcp_ports_in", 55000, log)
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
	out := ensureSSHPortsInSet(input, "tcp_ports_in", 55000, log)
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
	out := ensureSSHPortsInSet(input, "tcp_ports_in", 55000, log)
	if out != input {
		t.Errorf("expected unchanged output when no tcp_ports_in set present; got diff")
	}
}

// TestEnsureSSHPortInTcpPortsIn_MultilineElements covers the realistic
// case where elements span multiple lines (large port lists wrapped):
//
//	elements = { 20, 21, 25, 53, 80,
//	             110, 143, 443, 465 }
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
	out := ensureSSHPortsInSet(input, "tcp_ports_in", 22222, log)
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
// single-element slice — both paths share the same injection helper
// (ensureSSHPortsInSet, V121's ensureSSHPortInTcpPortsIn generalized in
// v1.145 PR-A), exercised here directly to assert multi-port behavior
// without spinning up the full executor/file I/O machinery.
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
	out := ensureSSHPortsInSet(input, "tcp_ports_in", 22, log)
	out = ensureSSHPortsInSet(out, "tcp_ports_in", 55000, log)

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
	out := ensureSSHPortsInSet(input, "tcp_ports_in", 22, log)
	out = ensureSSHPortsInSet(out, "tcp_ports_in", 55000, log)

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
	once := ensureSSHPortsInSet(input, "tcp_ports_in", 55000, log)
	twice := ensureSSHPortsInSet(once, "tcp_ports_in", 55000, log)
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
	err := RenderNftablesConfMultiPort(nil, nil, log)
	if err == nil {
		t.Fatalf("expected error on empty sshPorts; got nil")
	}
	if !strings.Contains(err.Error(), "sshPorts is empty") {
		t.Errorf("expected 'sshPorts is empty' in error; got: %v", err)
	}
	// Empty slice (vs nil) — same code path.
	err = RenderNftablesConfMultiPort(nil, []int{}, log)
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
	out := ensureSSHPortsInSet(input, "tcp_ports_in", 22, log)
	// Port 22 MUST be injected as an exact whole token (not masked by "2222").
	if !regexp.MustCompile(`(^|[^0-9])22([^0-9]|$)`).MatchString(out) {
		t.Fatalf("expected exact port 22 to be injected as a whole token; got:\n%s", out)
	}
	// Original 2222 entry must still be present.
	if !strings.Contains(out, "2222") {
		t.Errorf("original port 2222 lost from output:\n%s", out)
	}
	// Idempotency on the new strict-presence check.
	out2 := ensureSSHPortsInSet(out, "tcp_ports_in", 22, log)
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
			out := ensureSSHPortsInSet(tt.template, "tcp_ports_in", tt.target, log)
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

func wholeToken(port int) *regexp.Regexp {
	return regexp.MustCompile(`(^|[^0-9])` + strconv.Itoa(port) + `([^0-9]|$)`)
}

// ssh_ports block extractor — the inner `elements = { … }` of `set ssh_ports`.
var sshPortsBlockRe = regexp.MustCompile(`(?s)set ssh_ports \{[^{}]*elements = \{([^}]*)\}`)

func sshPortsElements(t *testing.T, content string) string {
	t.Helper()
	m := sshPortsBlockRe.FindStringSubmatch(content)
	if m == nil {
		t.Fatalf("no `set ssh_ports { … }` block found in:\n%s", content)
	}
	return m[1]
}

// TestEnsureSSHPortsInSet_V145_TargetsSSHPortsSet asserts the generalized
// helper injects into the named ssh_ports set (not tcp_ports_in) when asked.
func TestEnsureSSHPortsInSet_V145_TargetsSSHPortsSet(t *testing.T) {
	log := newRenderTestLogger(t)
	defer log.Close()
	input := `table ip nftban {
	set ssh_ports {
		type inet_service
		elements = { 22 }
	}
}`
	out := ensureSSHPortsInSet(input, "ssh_ports", 55000, log)
	if !wholeToken(55000).MatchString(sshPortsElements(t, out)) {
		t.Errorf("port 55000 not injected into ssh_ports elements; got:\n%s", out)
	}
	if !wholeToken(22).MatchString(sshPortsElements(t, out)) {
		t.Errorf("existing port 22 lost from ssh_ports elements; got:\n%s", out)
	}
}

// TestEnsureSSHPortsInSet_V145_DoesNotCrossContaminate asserts that injecting
// into ssh_ports leaves tcp_ports_in untouched and vice-versa (set targeting
// is precise — the regex is anchored on the set name).
func TestEnsureSSHPortsInSet_V145_DoesNotCrossContaminate(t *testing.T) {
	log := newRenderTestLogger(t)
	defer log.Close()
	input := `table ip nftban {
	set tcp_ports_in {
		type inet_service
		elements = { 22, 80, 443 }
	}
	set ssh_ports {
		type inet_service
		elements = { 22 }
	}
}`
	// Inject 55000 ONLY into ssh_ports.
	out := ensureSSHPortsInSet(input, "ssh_ports", 55000, log)
	if !wholeToken(55000).MatchString(sshPortsElements(t, out)) {
		t.Errorf("55000 not injected into ssh_ports; got:\n%s", out)
	}
	// tcp_ports_in must NOT have gained 55000.
	tcpRe := regexp.MustCompile(`(?s)set tcp_ports_in \{[^{}]*elements = \{([^}]*)\}`)
	tcpInner := tcpRe.FindStringSubmatch(out)
	if tcpInner == nil {
		t.Fatalf("tcp_ports_in block missing after ssh_ports injection:\n%s", out)
	}
	if wholeToken(55000).MatchString(tcpInner[1]) {
		t.Errorf("ssh_ports injection leaked into tcp_ports_in; got tcp_ports_in elements: %q", tcpInner[1])
	}
}

// TestEnsureSSHPortsInSet_V145_SSHPorts_SubstringGuard asserts the v1.125 R-1
// strict-token presence check carries over to the ssh_ports set (22 must not
// be considered "present" because 2222 appears).
func TestEnsureSSHPortsInSet_V145_SSHPorts_SubstringGuard(t *testing.T) {
	log := newRenderTestLogger(t)
	defer log.Close()
	input := `set ssh_ports {
	elements = { 2222 }
}`
	out := ensureSSHPortsInSet(input, "ssh_ports", 22, log)
	if !wholeToken(22).MatchString(out) {
		t.Fatalf("port 22 not injected as a whole token into ssh_ports (masked by 2222?); got:\n%s", out)
	}
	if !strings.Contains(out, "2222") {
		t.Errorf("existing 2222 lost from ssh_ports; got:\n%s", out)
	}
	// Idempotent on the strict-presence path.
	if out2 := ensureSSHPortsInSet(out, "ssh_ports", 22, log); out2 != out {
		t.Errorf("ssh_ports injection not idempotent; second call mutated content")
	}
}

// renderSetDrivenMock returns a mock executor seeded with a representative
// v1.145 template: both port sets seeded via __SSH_PORT__, plus the set-driven
// ct-count rule reading @ssh_ports.
func renderSetDrivenTemplate() string {
	return `# v1.145 set-driven template (test fixture)
table ip nftban {
	set tcp_ports_in {
		type inet_service
		elements = { __SSH_PORT__, 80, 443 }
	}
	set udp_ports_in {
		type inet_service
		elements = { 53 }
	}
	set udp_ports_out {
		type inet_service
		elements = { 53, 123 }
	}
	set ssh_ports {
		type inet_service
		elements = { __SSH_PORT__ }
	}
	chain input {
		ct state new tcp dport @ssh_ports ct count over __CT_LIMIT_SSH__ counter drop comment "SSH set-driven"
		ct state new tcp dport { 80, 443 } ct count over __CT_LIMIT_HTTP__ counter drop comment "HTTP(S)"
		ct state new tcp dport { 25, 465, 587 } ct count over __CT_LIMIT_MAIL__ counter drop comment "MAIL"
	}
}
`
}

// setElements extracts the inner `elements = { … }` text of the named set.
func setElements(t *testing.T, content, setName string) string {
	t.Helper()
	re := regexp.MustCompile(`(?s)set ` + regexp.QuoteMeta(setName) + ` \{[^{}]*elements = \{([^}]*)\}`)
	m := re.FindStringSubmatch(content)
	if m == nil {
		t.Fatalf("no `set %s { … }` block found in:\n%s", setName, content)
	}
	return m[1]
}

// tokenCount returns how many times port appears as a whole numeric token in s.
func tokenCount(s string, port int) int {
	return len(regexp.MustCompile(`(^|[^0-9])`+strconv.Itoa(port)+`([^0-9]|$)`).FindAllString(s, -1))
}

// renderForPorts renders renderSetDrivenTemplate with the given sshPorts and
// returns the written output.
func renderForPorts(t *testing.T, sshPorts []int) string {
	t.Helper()
	log := newRenderTestLogger(t)
	defer log.Close()
	mock := executor.NewMockExecutor()
	// v1.229.13 Lane 3D.2: substitution belongs to the SHELL authority, so by the
	// time this package sees the file the placeholders are already gone. The
	// harness therefore performs the shell's role explicitly and hands the Go path
	// a POST-SUBSTITUTION artifact — which is exactly what happens in production.
	//
	// The primary port is seeded the way the shell seeds it. That MATTERS for the
	// reserved-port edge: with sshPorts=[80] the shell emits `{ 80, 80, 443 }`, so
	// dedupePortSetElements is still handed a real duplicate and the dedup
	// assertions stay non-vacuous. Seeding a constant here would have silently
	// turned those tests into no-ops.
	seeded := strings.ReplaceAll(renderSetDrivenTemplate(), "__SSH_PORT__", strconv.Itoa(sshPorts[0]))
	seeded = strings.ReplaceAll(seeded, "__CT_LIMIT_SSH__", "15")
	seeded = strings.ReplaceAll(seeded, "__CT_LIMIT_HTTP__", "200")
	seeded = strings.ReplaceAll(seeded, "__CT_LIMIT_MAIL__", "30")
	mock.Files["/etc/nftban/nftables.conf"] = []byte(seeded)
	if err := RenderNftablesConfMultiPort(mock, sshPorts, log); err != nil {
		t.Fatalf("RenderNftablesConfMultiPort(%v): %v", sshPorts, err)
	}
	written, ok := mock.WrittenFiles["/etc/nftban/nftables.conf"]
	if !ok {
		t.Fatalf("render did not write nftables.conf for sshPorts=%v", sshPorts)
	}
	return string(written)
}

// ADD_V145_PR_A_SET_DEDUP_AND_OVERLAP_TESTS — assertion #2: duplicate INPUT
// ports collapse to a single token in BOTH sets.
func TestRenderV145_DuplicateInputPorts_NoDuplicateTokens(t *testing.T) {
	out := renderForPorts(t, []int{22, 22, 55000, 55000})
	tcp := setElements(t, out, "tcp_ports_in")
	ssh := setElements(t, out, "ssh_ports")
	for _, p := range []int{22, 55000} {
		if c := tokenCount(tcp, p); c != 1 {
			t.Errorf("tcp_ports_in: port %d appears %d times, want exactly 1; elements=%q", p, c, tcp)
		}
		if c := tokenCount(ssh, p); c != 1 {
			t.Errorf("ssh_ports: port %d appears %d times, want exactly 1; elements=%q", p, c, ssh)
		}
	}
}

// assertion #3: intentional overlap — both ports in BOTH sets.
func TestRenderV145_IntentionalOverlap_BothSetsContainBothPorts(t *testing.T) {
	out := renderForPorts(t, []int{22, 55000})
	tcp := setElements(t, out, "tcp_ports_in")
	ssh := setElements(t, out, "ssh_ports")
	for _, p := range []int{22, 55000} {
		if tokenCount(tcp, p) != 1 {
			t.Errorf("tcp_ports_in missing port %d (want exactly 1); elements=%q", p, tcp)
		}
		if tokenCount(ssh, p) != 1 {
			t.Errorf("ssh_ports missing port %d (want exactly 1); elements=%q", p, ssh)
		}
	}
}

// assertion #4: no UDP contamination — SSH ports must NOT reach udp sets.
func TestRenderV145_NoUDPContamination(t *testing.T) {
	out := renderForPorts(t, []int{22, 55000})
	for _, set := range []string{"udp_ports_in", "udp_ports_out"} {
		elems := setElements(t, out, set)
		for _, p := range []int{22, 55000} {
			if tokenCount(elems, p) != 0 {
				t.Errorf("SSH port %d leaked into %s; elements=%q", p, set, elems)
			}
		}
	}
}

// assertion #7: HTTP service ports must NOT reach ssh_ports.
func TestRenderV145_HTTPPortsNotInSSHSet(t *testing.T) {
	out := renderForPorts(t, []int{22, 55000})
	ssh := setElements(t, out, "ssh_ports")
	for _, p := range []int{80, 443} {
		if tokenCount(ssh, p) != 0 {
			t.Errorf("HTTP port %d leaked into ssh_ports; elements=%q", p, ssh)
		}
	}
	// And they remain in tcp_ports_in.
	tcp := setElements(t, out, "tcp_ports_in")
	for _, p := range []int{80, 443} {
		if tokenCount(tcp, p) != 1 {
			t.Errorf("service port %d missing from tcp_ports_in; elements=%q", p, tcp)
		}
	}
}

// assertion #6: SSH ct-count rule is set-driven (@ssh_ports), never literal or
// @tcp_ports_in.
func TestRenderV145_CtCountRuleIsSetDriven(t *testing.T) {
	out := renderForPorts(t, []int{22, 55000})
	if !strings.Contains(out, "tcp dport @ssh_ports ct count") {
		t.Errorf("expected `tcp dport @ssh_ports ct count`; got:\n%s", out)
	}
	for _, bad := range []string{
		"tcp dport 22 ct count",
		"tcp dport 55000 ct count",
		"tcp dport @tcp_ports_in ct count",
	} {
		if strings.Contains(out, bad) {
			t.Errorf("SSH ct-count rule must not use %q", bad)
		}
	}
}

// assertion #8: reserved-port duplicate edge — sshPorts=[80] / [443] must NOT
// produce a duplicate token in tcp_ports_in even though the template hardcodes
// 80/443. (It is acceptable that ssh_ports holds the detected SSH port; the
// renderer does not validate the daemon's bind policy.)
func TestRenderV145_ReservedPortDuplicateEdge(t *testing.T) {
	for _, p := range []int{80, 443} {
		t.Run(strconv.Itoa(p), func(t *testing.T) {
			out := renderForPorts(t, []int{p})
			tcp := setElements(t, out, "tcp_ports_in")
			if c := tokenCount(tcp, p); c != 1 {
				t.Errorf("tcp_ports_in: reserved port %d appears %d times, want exactly 1 (dedup failed); elements=%q", p, c, tcp)
			}
			// The other reserved port must still be present exactly once.
			other := 443
			if p == 443 {
				other = 80
			}
			if c := tokenCount(tcp, other); c != 1 {
				t.Errorf("tcp_ports_in: service port %d appears %d times, want exactly 1; elements=%q", other, c, tcp)
			}
		})
	}
}

// TestRenderRefusesUnsubstitutedTemplate pins the NEW Lane 3D.2 contract: this
// package is no longer a substitution authority, so when handed a file that
// still carries placeholders it must FAIL CLOSED rather than publish a partially
// rendered ruleset. A half-rendered nftables.conf is not a degraded firewall, it
// is an unloadable one.
func TestRenderRefusesUnsubstitutedTemplate(t *testing.T) {
	for _, ph := range placeholders {
		mock := executor.NewMockExecutor()
		mock.Files["/etc/nftban/nftables.conf"] = []byte(
			"table ip nftban {\n  set ssh_ports {\n    elements = { " + ph + " }\n  }\n}\n")
		log := newRenderTestLogger(t)

		err := RenderNftablesConfMultiPort(mock, []int{22}, log)
		log.Close()
		if err == nil {
			t.Fatalf("placeholder %s: render returned nil — a partially rendered ruleset was accepted", ph)
		}
		if !strings.Contains(err.Error(), ph) {
			t.Errorf("placeholder %s: error does not name the offending placeholder: %v", ph, err)
		}
		if !strings.Contains(err.Error(), "_firewall_substitute_placeholders") {
			t.Errorf("placeholder %s: error must name the owning authority; got: %v", ph, err)
		}
	}
}
