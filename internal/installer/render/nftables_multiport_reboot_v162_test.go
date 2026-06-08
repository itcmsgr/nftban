// =============================================================================
// NFTBan v1.162 - Multi-port durable-render + reboot-sim regression (Go path)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-render-nftables-multiport-reboot-v162-test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-08"
// meta:description="Locks v1.162 DELTA §3.1 on the Go durable-render path (RenderNftablesConfMultiPort): the durable `set ssh_ports { elements = { … } }` must carry the FULL detected SSH-port union (every port), not just the primary, in BOTH the ip nftban and ip6 nftban tables, and the SSH brute-force ct-count rule must stay set-driven (`tcp dport @ssh_ports`), never a literal port. The reboot-sim asserts the durable rendered STRING alone — what survives a reboot with no kernel reconcile — carries the union, and that a re-render of the same input is idempotent (still all ports, no duplicates). A single-port [22] case asserts byte-compat (ssh_ports = {22} only). Hermetic: a mock executor stands in for file I/O; no host, no nft, no systemd."
// meta:input="None"
// meta:output="t.Fatalf/t.Errorf on assertion failure"
// meta:depends="testing,internal/installer/detect,internal/installer/executor,internal/installer/logging"
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
)

// dualTableSetDrivenTemplate is a minimal two-family fixture mirroring the
// shipped install/nftables/nftables.conf.tpl shape: each of `ip nftban` and
// `ip6 nftban` carries a `set ssh_ports { elements = { __SSH_PORT__ } }` and an
// input chain whose SSH brute-force ct-count rule reads `tcp dport @ssh_ports`.
// The primary port arrives via the __SSH_PORT__ substitution; every additional
// detected port is injected by ensureSSHPortsInSet. This fixture lets the test
// assert the durable union lands in BOTH families without depending on the full
// 800-line template.
func dualTableSetDrivenTemplate() string {
	return `# v1.162 dual-table set-driven fixture
table ip nftban {
	set tcp_ports_in {
		type inet_service
		elements = { __SSH_PORT__, 80, 443 }
	}
	set ssh_ports {
		type inet_service
		elements = { __SSH_PORT__ }
	}
	chain input {
		ct state new tcp dport @ssh_ports ct count over __CT_LIMIT_SSH__ counter drop comment "SSH set-driven v4"
	}
}
table ip6 nftban {
	set tcp_ports_in {
		type inet_service
		elements = { __SSH_PORT__, 80, 443 }
	}
	set ssh_ports {
		type inet_service
		elements = { __SSH_PORT__ }
	}
	chain input {
		ct state new tcp dport @ssh_ports ct count over __CT_LIMIT_SSH__ counter drop comment "SSH set-driven v6"
	}
}
`
}

// sshPortsBlocksV162 extracts the inner `elements = { … }` of EVERY
// `set ssh_ports { … }` block (one per family). Group 1 is the inner element
// list. Returns all matches so the test can assert per-table union coverage.
var sshPortsBlocksV162 = regexp.MustCompile(`(?s)set ssh_ports \{[^{}]*elements = \{([^}]*)\}`)

func allSSHPortsElementsV162(t *testing.T, content string) []string {
	t.Helper()
	ms := sshPortsBlocksV162.FindAllStringSubmatch(content, -1)
	if ms == nil {
		t.Fatalf("no `set ssh_ports { … }` block found in:\n%s", content)
	}
	out := make([]string, 0, len(ms))
	for _, m := range ms {
		out = append(out, m[1])
	}
	return out
}

// wholeTokenV162 matches an exact whole numeric port token (not masked by a
// longer number containing it as a substring, e.g. 22 inside 2222).
func wholeTokenV162(port int) *regexp.Regexp {
	return regexp.MustCompile(`(^|[^0-9])` + strconv.Itoa(port) + `([^0-9]|$)`)
}

func tokenCountV162(s string, port int) int {
	return len(wholeTokenV162(port).FindAllString(s, -1))
}

// renderDualV162 renders dualTableSetDrivenTemplate with sshPorts via the mock
// executor and returns the durable written content.
func renderDualV162(t *testing.T, sshPorts []int) string {
	t.Helper()
	log := newRenderTestLogger(t)
	defer log.Close()
	mock := executor.NewMockExecutor()
	mock.Files[nftbanConf] = []byte(dualTableSetDrivenTemplate())
	if err := RenderNftablesConfMultiPort(mock, sshPorts, detect.CTLimits{SSH: 15, HTTP: 200, Mail: 30}, log); err != nil {
		t.Fatalf("RenderNftablesConfMultiPort(%v): %v", sshPorts, err)
	}
	written, ok := mock.WrittenFiles[nftbanConf]
	if !ok {
		t.Fatalf("render did not write %s for sshPorts=%v", nftbanConf, sshPorts)
	}
	return string(written)
}

// TestRenderV162_MultiPort_DurableUnionInBothFamilies is the core DELTA §3.1
// lock: with a multi-port slice [22, 2222, 55000] the durable rendered
// ssh_ports set must carry ALL three ports as whole tokens in BOTH the ip and
// ip6 families — never primary-only.
func TestRenderV162_MultiPort_DurableUnionInBothFamilies(t *testing.T) {
	const wantBlocks = 2 // ip nftban + ip6 nftban
	ports := []int{22, 2222, 55000}
	out := renderDualV162(t, ports)

	blocks := allSSHPortsElementsV162(t, out)
	if len(blocks) != wantBlocks {
		t.Fatalf("expected %d ssh_ports blocks (ip + ip6), got %d:\n%s", wantBlocks, len(blocks), out)
	}
	for i, elems := range blocks {
		for _, p := range ports {
			if tokenCountV162(elems, p) != 1 {
				t.Errorf("ssh_ports block #%d: port %d appears %d times, want exactly 1 (primary-only regression?); elements=%q",
					i, p, tokenCountV162(elems, p), elems)
			}
		}
	}

	// SSH ct-count rule must be set-driven, never a literal port.
	if !strings.Contains(out, "tcp dport @ssh_ports ct count") {
		t.Errorf("expected set-driven `tcp dport @ssh_ports ct count`; got:\n%s", out)
	}
	for _, p := range ports {
		if strings.Contains(out, "tcp dport "+strconv.Itoa(p)+" ct count") {
			t.Errorf("found literal `tcp dport %d ct count` — SSH rule must read @ssh_ports", p)
		}
	}
}

// TestRenderV162_RebootSim_DurableStringAloneCarriesUnion treats the rendered
// output as the durable file that survives a reboot with NO kernel reconcile:
// the string alone must carry the full union, and re-rendering that same input
// (a second installer/reload pass) must be idempotent — still all ports, no
// duplicate tokens, ct-count rule still set-driven.
func TestRenderV162_RebootSim_DurableStringAloneCarriesUnion(t *testing.T) {
	ports := []int{22, 2222, 55000}
	first := renderDualV162(t, ports)

	// "Reboot": only the durable string survives. Re-parse it fresh and assert
	// every union port is present in both ssh_ports blocks.
	for i, elems := range allSSHPortsElementsV162(t, first) {
		for _, p := range ports {
			if !wholeTokenV162(p).MatchString(elems) {
				t.Errorf("post-reboot durable ssh_ports block #%d missing port %d; elements=%q", i, p, elems)
			}
		}
	}

	// Idempotent re-render: feed the SAME input again; the union must still be
	// fully present with no duplicate tokens in either ssh_ports block.
	second := renderDualV162(t, ports)
	for i, elems := range allSSHPortsElementsV162(t, second) {
		for _, p := range ports {
			if c := tokenCountV162(elems, p); c != 1 {
				t.Errorf("idempotency: ssh_ports block #%d port %d appears %d times, want exactly 1; elements=%q", i, p, c, elems)
			}
		}
	}
	if !strings.Contains(second, "tcp dport @ssh_ports ct count") {
		t.Errorf("idempotent re-render lost set-driven SSH rule:\n%s", second)
	}
}

// TestRenderV162_SinglePort_ByteCompat asserts the single-port [22] case still
// renders ssh_ports = {22} only (no spurious extra tokens) in both families —
// the multi-port lock must not regress the common single-port host.
func TestRenderV162_SinglePort_ByteCompat(t *testing.T) {
	out := renderDualV162(t, []int{22})
	for i, elems := range allSSHPortsElementsV162(t, out) {
		if tokenCountV162(elems, 22) != 1 {
			t.Errorf("ssh_ports block #%d: expected exactly one token 22; elements=%q", i, elems)
		}
		// No stray multi-port tokens from the fixtures used elsewhere.
		for _, p := range []int{2222, 55000} {
			if tokenCountV162(elems, p) != 0 {
				t.Errorf("ssh_ports block #%d: unexpected port %d in single-port render; elements=%q", i, p, elems)
			}
		}
	}
	if !strings.Contains(out, "tcp dport @ssh_ports ct count") {
		t.Errorf("single-port render lost set-driven SSH rule:\n%s", out)
	}
}
