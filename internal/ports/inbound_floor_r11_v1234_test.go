// =============================================================================
// NFTBan - R-11 inbound-floor authorization (v1.234)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="inbound_floor_r11_v1234_test"
// meta:type="test"
// meta:version="1.234.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="R-11 BUG-BOOT-PROJECTION-CARRIES-ONLY-TEMPLATE-PORTS owner acceptance: a configured removal of 80/443 must not be reversed by the template floor. Key absent keeps the package default; empty/none removes the floor; SSH ports (the lockout safeguard) are never removable through it; invalid values fail instead of falling back."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package ports

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestR11InboundFloor_AbsentKeyKeepsPackageDefault(t *testing.T) {
	got, err := ResolveInboundFloor("", false)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, []int{80, 443}) {
		t.Fatalf("absent key must keep the package default {80,443} (no silent closure on upgrade), got %v", got)
	}
}

func TestR11InboundFloor_EmptyOrNoneRemovesFloor(t *testing.T) {
	for _, v := range []string{"", "none", " NONE ", "  "} {
		got, err := ResolveInboundFloor(v, true)
		if err != nil {
			t.Fatalf("%q: %v", v, err)
		}
		if len(got) != 0 {
			t.Fatalf("%q: an explicit empty floor must authorize nothing, got %v", v, got)
		}
	}
}

func TestR11InboundFloor_ExplicitListIsExact(t *testing.T) {
	got, err := ResolveInboundFloor("8443, 443,443", true)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(got, []int{443, 8443}) {
		t.Fatalf("explicit floor must be exactly the configured ports, got %v", got)
	}
}

func TestR11InboundFloor_InvalidFailsNeverFallsBack(t *testing.T) {
	for _, v := range []string{"80,http", "0", "70000", "-1"} {
		if got, err := ResolveInboundFloor(v, true); err == nil {
			t.Fatalf("%q must be rejected, got floor %v (a fallback would re-add ports the admin removed)", v, got)
		}
	}
}

// The acceptance scenario: SSH on 55000, port 22 absent everywhere, 80/443 removed
// by the administrator. The effective set must contain the configured service ports
// and the SSH safeguard, and NONE of 22/80/443.
func TestR11InboundFloor_AdminRemovalHonoured_SSHSafeguardKept(t *testing.T) {
	dir := t.TempDir()
	pd := filepath.Join(dir, "ports.d")
	if err := os.MkdirAll(pd, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pd, "00-ssh.conf"), []byte("55000/T/I\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pd, "90-custom.conf"), []byte("18765/T/I\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	floor, err := ResolveInboundFloor("none", true)
	if err != nil {
		t.Fatal(err)
	}
	sets, err := EffectiveServicePortsWithInboundFloor(dir, []int{55000}, floor)
	if err != nil {
		t.Fatal(err)
	}
	for _, bad := range []int{22, 80, 443} {
		if contains(sets.TCPIn, bad) {
			t.Errorf("tcp_ports_in carries %d although nothing authorizes it: %v", bad, sets.TCPIn)
		}
	}
	for _, want := range []int{55000, 18765} {
		if !contains(sets.TCPIn, want) {
			t.Errorf("tcp_ports_in lost configured/SSH port %d: %v", want, sets.TCPIn)
		}
	}

	// The SSH safeguard cannot be removed through the floor: even an empty floor
	// with an empty ports.d keeps the detected SSH port.
	empty := t.TempDir()
	sets2, err := EffectiveServicePortsWithInboundFloor(empty, []int{55000}, []int{})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(sets2.TCPIn, []int{55000}) {
		t.Fatalf("empty floor + empty config must still carry ONLY the SSH safeguard, got %v", sets2.TCPIn)
	}

	// Discriminator: the pre-R-11 path (unconditional floor) re-adds 80/443 — this
	// is exactly what the acceptance forbids, so the arm above is not vacuous.
	old, err := EffectiveServicePorts(dir, []int{55000})
	if err != nil {
		t.Fatal(err)
	}
	if !contains(old.TCPIn, 80) || !contains(old.TCPIn, 443) {
		t.Fatalf("control: the default path should still carry the package floor, got %v", old.TCPIn)
	}
}

func TestR11InboundFloor_RenderHonoursFloor(t *testing.T) {
	dir := t.TempDir()
	out, err := RenderEffectiveElementsWithInboundFloor(dir, []int{55000}, []int{})
	if err != nil {
		t.Fatal(err)
	}
	v, ok := elemLine(out, "NFTBAN_SVC_TCP_IN")
	if !ok || v != "55000" {
		t.Fatalf("NFTBAN_SVC_TCP_IN must be exactly the SSH safeguard, got %q (ok=%v)\n%s", v, ok, out)
	}
}
