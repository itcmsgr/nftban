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
	"strings"
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

// r11FloorContract is the owner ruling (2026-09-29) as an executable predicate,
// applied to ANY resolver so the negative controls below can prove it bites.
//
//	unset              -> {80, 443}
//	explicit non-empty -> exactly the configured ports (80/443 NOT appended)
//	explicit empty     -> nothing (defaults NOT restored)
func r11FloorContract(resolve func(string, bool) ([]int, error)) []string {
	var bad []string
	check := func(label, v string, set bool, want []int) {
		got, err := resolve(v, set)
		if err != nil {
			bad = append(bad, label+": error "+err.Error())
			return
		}
		if len(got) != len(want) {
			bad = append(bad, label)
			return
		}
		for i := range want {
			if got[i] != want[i] {
				bad = append(bad, label)
				return
			}
		}
	}
	check("unset", "", false, []int{80, 443})
	check("explicit 8443", "8443", true, []int{8443})
	check("explicit empty", "", true, []int{})
	return bad
}

func TestR11InboundFloor_OwnerRulingContract(t *testing.T) {
	if bad := r11FloorContract(ResolveInboundFloor); len(bad) > 0 {
		t.Fatalf("ResolveInboundFloor violates the owner ruling: %v", bad)
	}
}

// NEGATIVE CONTROLS: the contract must reject the two wrong designs it exists to
// exclude, or TestR11InboundFloor_OwnerRulingContract proves nothing.
func TestR11InboundFloor_NegativeControls(t *testing.T) {
	restoresOnEmpty := func(v string, set bool) ([]int, error) {
		if !set || strings.TrimSpace(v) == "" { // the ${VAR:-default} shape
			return DefaultInboundFloor(), nil
		}
		return ResolveInboundFloor(v, set)
	}
	appendsDefaults := func(v string, set bool) ([]int, error) {
		got, err := ResolveInboundFloor(v, set)
		if err != nil || !set || len(got) == 0 {
			return got, err
		}
		return normalizePortList(append(got, DefaultInboundFloor()...)), nil
	}
	if bad := r11FloorContract(restoresOnEmpty); len(bad) == 0 {
		t.Fatal("negative control: a resolver that restores 80/443 on an explicit empty value PASSED the contract")
	} else if bad[0] != "explicit empty" {
		t.Fatalf("negative control failed for the wrong reason: %v", bad)
	}
	if bad := r11FloorContract(appendsDefaults); len(bad) == 0 {
		t.Fatal("negative control: a resolver that appends 80/443 to an explicit value PASSED the contract")
	} else if bad[0] != "explicit 8443" {
		t.Fatalf("negative control failed for the wrong reason: %v", bad)
	}
}

// SYNC PATH (`nftban sync` and the nftband startup auto-sync): the daemon adds
// exactly ports.LoadAllPorts (ports.d + enabled panels) and never the floor, so
// NO configuration of the key can make sync add 80/443 or 22. With SSH on 55000
// and 22/80/443 absent from ports.d, sync contributes {18765, 55000} only.
func TestR11SyncPath_LoadAllPortsNeverAddsFloorOrPort22(t *testing.T) {
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
	all, err := LoadAllPorts(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, bad := range []int{22, 80, 443} {
		if contains(all.TCPPortsIn, bad) {
			t.Errorf("sync source carries %d although nothing configures it: %v", bad, all.TCPPortsIn)
		}
	}
	for _, want := range []int{55000, 18765} {
		if !contains(all.TCPPortsIn, want) {
			t.Errorf("sync source lost %d: %v", want, all.TCPPortsIn)
		}
	}
}

// STRUCTURAL: the daemon full sync takes its ports from LoadAllPorts and from
// nothing that carries a floor or a template literal.
func TestR11SyncPath_DaemonPortSourceIsLoadAllPortsOnly(t *testing.T) {
	src, err := os.ReadFile("../../cmd/nftband/daemon_handlers_sync.go")
	if err != nil {
		t.Fatalf("subject not found: %v", err)
	}
	s := string(src)
	if !strings.Contains(s, "ports.LoadAllPorts(configDir)") {
		t.Fatal("daemon sync no longer loads ports via ports.LoadAllPorts — re-derive this proof")
	}
	for _, forbidden := range []string{"EffectiveServicePorts", "ComputeEffective", "DefaultInboundFloor", "ResolveInboundFloor", "baselineTCPIn", "[]int{80", "80, 443"} {
		if strings.Contains(s, forbidden) {
			t.Fatalf("daemon sync references %q — the sync path would carry a floor", forbidden)
		}
	}
}
