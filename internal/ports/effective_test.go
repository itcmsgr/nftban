// =============================================================================
// NFTBan - Effective service-port authority tests (v1.192.1 Increment 1)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="effective_test"
// meta:type="test"
// meta:version="1.192.1"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Hermetic tests for the shared effective service-port authority (ComputeEffective) + template baseline drift guard"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// Acceptance (operator): given the same config daemon sync uses, the authority
// returns the same effective set. ComputeEffective consumes the exact PortConfig
// LoadAllPorts produces (ports.d + enabled panels) — so equivalence is by
// construction; these tests assert the completion layer (baseline + SSH union),
// determinism, validation, and that the template baseline has not drifted.
// No root, no nft, no host state.

package ports

import (
	"os"
	"reflect"
	"regexp"
	"sort"
	"testing"
)

func contains(xs []int, v int) bool {
	for _, x := range xs {
		if x == v {
			return true
		}
	}
	return false
}

func TestComputeEffective_BaselineIncludesSSHAndWebPorts(t *testing.T) {
	got := ComputeEffective(&PortConfig{}, []int{22})
	for _, p := range []int{22, 80, 443} {
		if !contains(got.TCPIn, p) {
			t.Errorf("TCPIn missing baseline/SSH port %d: %v", p, got.TCPIn)
		}
	}
	for _, p := range []int{53, 80, 443} {
		if !contains(got.TCPOut, p) {
			t.Errorf("TCPOut missing baseline port %d: %v", p, got.TCPOut)
		}
	}
	for _, p := range []int{53, 123} {
		if !contains(got.UDPOut, p) {
			t.Errorf("UDPOut missing baseline port %d: %v", p, got.UDPOut)
		}
	}
	// Non-standard SSH port must flow through (single SSH authority via argument).
	got2 := ComputeEffective(&PortConfig{}, []int{55000})
	if !contains(got2.TCPIn, 55000) {
		t.Errorf("TCPIn missing injected SSH port 55000: %v", got2.TCPIn)
	}
}

func TestComputeEffective_PanelMailPortsAppear(t *testing.T) {
	// Simulates LoadAllPorts output for a cPanel/mail host (993/995 etc).
	all := &PortConfig{TCPPortsIn: []int{25, 465, 587, 993, 995, 2083, 2087}}
	got := ComputeEffective(all, []int{22})
	for _, p := range []int{993, 995, 25, 2083, 2087} {
		if !contains(got.TCPIn, p) {
			t.Errorf("TCPIn missing configured service port %d: %v", p, got.TCPIn)
		}
	}
}

func TestComputeEffective_ZabbixPortAppearsWhenConfigured(t *testing.T) {
	got := ComputeEffective(&PortConfig{TCPPortsIn: []int{10051}}, []int{22})
	if !contains(got.TCPIn, 10051) {
		t.Errorf("TCPIn missing configured 10051: %v", got.TCPIn)
	}
}

func TestComputeEffective_DeduplicatesAndSorts(t *testing.T) {
	// Duplicate 80/443 (baseline) + duplicate 993; SSH dup 22.
	all := &PortConfig{TCPPortsIn: []int{443, 993, 993, 80, 22}}
	got := ComputeEffective(all, []int{22, 22})
	// Deduplicated.
	seen := map[int]int{}
	for _, p := range got.TCPIn {
		seen[p]++
		if seen[p] > 1 {
			t.Fatalf("TCPIn has duplicate %d: %v", p, got.TCPIn)
		}
	}
	// Sorted ascending.
	if !sort.IntsAreSorted(got.TCPIn) {
		t.Fatalf("TCPIn not sorted: %v", got.TCPIn)
	}
}

func TestComputeEffective_RejectsInvalidPorts(t *testing.T) {
	all := &PortConfig{TCPPortsIn: []int{0, -1, 70000, 65536, 443}}
	got := ComputeEffective(all, []int{0})
	for _, bad := range []int{0, -1, 70000, 65536} {
		if contains(got.TCPIn, bad) {
			t.Errorf("TCPIn must reject invalid port %d: %v", bad, got.TCPIn)
		}
	}
	if !contains(got.TCPIn, 443) {
		t.Errorf("valid 443 dropped: %v", got.TCPIn)
	}
}

// Equivalence acceptance: the effective authority is a faithful SUPERSET of the
// LoadAllPorts authority that daemon sync applies — every directional port the
// daemon would add appears in the render's effective set (so render == sync, no
// gap). Construction-level proof using the exact PortConfig shape.
func TestComputeEffective_SupersetOfLoadAllPortsAuthority(t *testing.T) {
	all := &PortConfig{
		TCPPortsIn:  []int{25, 993, 10051, 2087},
		TCPPortsOut: []int{2703, 873},
		UDPPortsIn:  []int{4190},
		UDPPortsOut: []int{514},
	}
	got := ComputeEffective(all, []int{22})
	for _, p := range all.TCPPortsIn {
		if !contains(got.TCPIn, p) {
			t.Errorf("TCPIn not a superset of authority: missing %d", p)
		}
	}
	for _, p := range all.TCPPortsOut {
		if !contains(got.TCPOut, p) {
			t.Errorf("TCPOut not a superset of authority: missing %d", p)
		}
	}
	for _, p := range all.UDPPortsIn {
		if !contains(got.UDPIn, p) {
			t.Errorf("UDPIn not a superset of authority: missing %d", p)
		}
	}
	for _, p := range all.UDPPortsOut {
		if !contains(got.UDPOut, p) {
			t.Errorf("UDPOut not a superset of authority: missing %d", p)
		}
	}
}

func TestComputeEffective_Deterministic(t *testing.T) {
	all := &PortConfig{TCPPortsIn: []int{993, 25, 443}}
	a := ComputeEffective(all, []int{22})
	b := ComputeEffective(all, []int{22})
	if !reflect.DeepEqual(a, b) {
		t.Fatalf("non-deterministic output:\n a=%v\n b=%v", a, b)
	}
}

// Drift guard: the Go baseline constants MUST equal the rendered template's set
// elements (minus the __SSH_PORT__ placeholder). Catches the exact class where a
// template edit silently diverges from the Go authority.
func TestEffectiveBaselineMatchesTemplate(t *testing.T) {
	const tpl = "../../install/nftables/nftables.conf.tpl"
	data, err := os.ReadFile(tpl)
	if err != nil {
		t.Fatalf("cannot read template %s: %v", tpl, err)
	}
	src := string(data)

	// Confirm the set is declared (with or without an elements line).
	declRe := func(setName string) *regexp.Regexp {
		return regexp.MustCompile(`set ` + regexp.QuoteMeta(setName) + ` \{`)
	}
	check := func(setName string, want []int) {
		if !declRe(setName).MatchString(src) {
			t.Errorf("template missing set %s", setName)
			return
		}
		// `[^{}]*?` skips the brace-free type/comment lines up to the (nested)
		// `elements = { ... }`. A set with no elements line simply won't match
		// (got = empty), which is correct for udp_ports_in.
		elemRe := regexp.MustCompile(`set ` + regexp.QuoteMeta(setName) + ` \{[^{}]*?elements = \{([^}]*)\}`)
		em := elemRe.FindStringSubmatch(src)
		var got []int
		if em != nil {
			for _, tok := range regexp.MustCompile(`[0-9]+`).FindAllString(em[1], -1) {
				var n int
				for _, c := range tok {
					n = n*10 + int(c-'0')
				}
				got = append(got, n)
			}
		}
		got = normalizePortList(got)
		w := normalizePortList(append([]int{}, want...))
		if !reflect.DeepEqual(got, w) {
			t.Errorf("baseline drift for %s: template=%v go-baseline=%v (update baselineX in effective.go OR the template, not just one)", setName, got, w)
		}
	}

	// tcp_ports_in template = { __SSH_PORT__, 80, 443 } → numeric baseline {80,443}.
	check("tcp_ports_in", baselineTCPIn)
	check("tcp_ports_out", baselineTCPOut)
	check("udp_ports_in", baselineUDPIn)
	check("udp_ports_out", baselineUDPOut)
}
