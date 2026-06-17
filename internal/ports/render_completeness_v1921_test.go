// =============================================================================
// NFTBan - V-NFT-SERVICE-PORTS-RENDERED-COMPLETE fixture guard (v1.192.1 inc5)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="render_completeness_v1921_test"
// meta:type="test"
// meta:version="1.192.1"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Fixture CI guard: a config with non-template service ports renders COMPLETE tcp_ports_in/out + udp_ports_in/out (ip+ip6) before daemon sync; skeletal render fails"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
// D-V192-RESIDUAL-REBUILD-DROP Increment 5 acceptance:
//   A generated config with configured non-template service ports cannot pass if
//   those ports are absent from tcp_ports_in/out or udp_ports_in/out. Exercises
//   the REAL authority (EffectiveServicePorts → LoadAllPorts reading a fixture
//   ports.d) + the render fragment. Hermetic: no root, no nft, no host state
//   (panel state file absent in CI → ports.d is the only source; "contains"
//   assertions tolerate any extra host ports if present).

package ports

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func mustContainAllPorts(t *testing.T, got []int, want []int, label string) {
	t.Helper()
	for _, w := range want {
		if !contains(got, w) {
			t.Errorf("%s incomplete: missing %d (got %v)", label, w, got)
		}
	}
}

// writeFixturePortsD writes a ports.d with non-template service ports. ports.d
// format is PORT/PROTOCOL: T = both TCP in+out, U = both UDP in+out, B = all.
func writeFixturePortsD(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	pd := filepath.Join(dir, "ports.d")
	if err := os.MkdirAll(pd, 0o755); err != nil {
		t.Fatal(err)
	}
	// PORT/PROTOCOL/DIRECTION (I=input, O=output, IO=both; default I).
	fixture := "# v1.192.1 fixture\n" +
		"993/T/I\n995/T/I\n10051/T/I\n" + // inbound TCP (mail/zabbix)
		"25/T/O\n587/T/O\n10050/T/O\n" + // outbound TCP (mail/zabbix)
		"53/U/I\n" // inbound UDP (DNS)
	if err := os.WriteFile(filepath.Join(pd, "50-fixture.conf"), []byte(fixture), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestServicePortRenderCompleteness_FixtureHasAllPorts(t *testing.T) {
	dir := writeFixturePortsD(t)
	sets, err := EffectiveServicePorts(dir, []int{55000})
	if err != nil {
		t.Fatalf("EffectiveServicePorts: %v", err)
	}

	// Per-set completeness (configured ports + baseline + SSH).
	mustContainAllPorts(t, sets.TCPIn, []int{993, 995, 10051, 80, 443, 55000}, "tcp_ports_in")
	mustContainAllPorts(t, sets.TCPOut, []int{25, 587, 10050, 53, 80, 443}, "tcp_ports_out")
	mustContainAllPorts(t, sets.UDPIn, []int{53}, "udp_ports_in")
	mustContainAllPorts(t, sets.UDPOut, []int{53, 123}, "udp_ports_out")

	// The rendered fragment carries them for BOTH families.
	frag := renderEffectiveFragment(sets)
	for _, fam := range []string{"ip", "ip6"} {
		for _, want := range []struct{ set, port string }{
			{"tcp_ports_in", "993"}, {"tcp_ports_in", "10051"},
			{"tcp_ports_out", "10050"}, {"udp_ports_in", "53"},
		} {
			// the add-element line for that set+family must include the port
			marker := "add element " + fam + " nftban " + want.set + " {"
			idx := strings.Index(frag, marker)
			if idx < 0 {
				t.Errorf("fragment missing %q", marker)
				continue
			}
			line := frag[idx:]
			if nl := strings.IndexByte(line, '\n'); nl >= 0 {
				line = line[:nl]
			}
			if !strings.Contains(line, want.port) {
				t.Errorf("%s %s line missing port %s: %q", fam, want.set, want.port, line)
			}
		}
	}
}

// The discriminator: a SKELETAL render (no configured ports) must NOT contain the
// fixture service ports — proving the completeness assertion above would FAIL on
// the v1.192.0 skeletal behavior (the guard can actually catch the regression).
func TestServicePortRenderCompleteness_SkeletalFailsGuard(t *testing.T) {
	empty := t.TempDir() // no ports.d, no panels → skeletal (baseline + SSH only)
	sets, err := EffectiveServicePorts(empty, []int{55000})
	if err != nil {
		t.Fatalf("EffectiveServicePorts(empty): %v", err)
	}
	for _, bad := range []int{993, 995, 10051} {
		if contains(sets.TCPIn, bad) {
			t.Fatalf("skeletal tcp_ports_in unexpectedly contains %d — guard cannot discriminate", bad)
		}
	}
	// tcp_ports_in skeletal = baseline {80,443} + SSH {55000} only.
	if len(sets.TCPIn) != 3 {
		t.Errorf("expected skeletal tcp_ports_in = {80,443,55000}, got %v", sets.TCPIn)
	}
	// Prove the completeness check would FAIL here (993 absent) — i.e. a skeletal
	// render cannot satisfy the fixture guard.
	if contains(sets.TCPIn, 993) {
		t.Fatal("skeletal render must not satisfy completeness (993 must be absent)")
	}
}
