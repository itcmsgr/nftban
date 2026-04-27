// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 PR-25 — Restore Stub-Deps tests (commit 4)
// =============================================================================
// meta:name="nftban-installer-restore-deps-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-27"
// meta:description="Tests for the production stub-dep struct methods + the newProductionRestoreDeps factory + the package-level newRestoreDeps default. Confirms every stub method returns ErrRestoreExecutionUnavailable and that no real mutation surface exists in commit 4."
// meta:depends="github.com/itcmsgr/nftban/internal/installer/restore"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package main

import (
	"context"
	"errors"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/restore"
)

// =============================================================================
// 1. Stub methods (commit 4) — every method on the not-yet-implemented
//    deps still returns ErrRestoreExecutionUnavailable.
//
//    Note: 4B-1 replaced productionPreflightDep with a real
//    presence-check implementation. Its tests are below in the
//    "4B-1" section.
// =============================================================================

func TestProductionSafetyNetDep_BothMethodsReturnUnavailable(t *testing.T) {
	d := &productionSafetyNetDep{}
	if err := d.InsertEmergencySSH(context.Background()); !errors.Is(err, ErrRestoreExecutionUnavailable) {
		t.Errorf("InsertEmergencySSH err = %v; want ErrRestoreExecutionUnavailable", err)
	}
	if err := d.RemoveEmergencySSH(context.Background()); !errors.Is(err, ErrRestoreExecutionUnavailable) {
		t.Errorf("RemoveEmergencySSH err = %v; want ErrRestoreExecutionUnavailable", err)
	}
}

func TestProductionMutationDep_ReturnsUnavailable(t *testing.T) {
	d := &productionMutationDep{}
	if err := d.MutateToTarget(context.Background(), "csf"); !errors.Is(err, ErrRestoreExecutionUnavailable) {
		t.Errorf("MutateToTarget err = %v; want ErrRestoreExecutionUnavailable", err)
	}
}

func TestProductionInlineVerifyDep_AllThreeMethodsReturnUnavailable(t *testing.T) {
	d := &productionInlineVerifyDep{}

	active, err := d.IsTargetFirewallActive(context.Background(), "ufw")
	if active {
		t.Errorf("IsTargetFirewallActive returned active=true; stub must refuse")
	}
	if !errors.Is(err, ErrRestoreExecutionUnavailable) {
		t.Errorf("IsTargetFirewallActive err = %v; want ErrRestoreExecutionUnavailable", err)
	}

	auth, err := d.CurrentAuthorityClass(context.Background())
	if string(auth) != "" {
		t.Errorf("CurrentAuthorityClass returned %q; stub must return empty", auth)
	}
	if !errors.Is(err, ErrRestoreExecutionUnavailable) {
		t.Errorf("CurrentAuthorityClass err = %v; want ErrRestoreExecutionUnavailable", err)
	}

	safe, err := d.IsSafetyNetRemovalSafe(context.Background())
	if safe {
		t.Errorf("IsSafetyNetRemovalSafe returned safe=true; stub must refuse")
	}
	if !errors.Is(err, ErrRestoreExecutionUnavailable) {
		t.Errorf("IsSafetyNetRemovalSafe err = %v; want ErrRestoreExecutionUnavailable", err)
	}
}

// =============================================================================
// 2. Factory returns a complete ExecuteDeps with all four fields set.
// =============================================================================

func TestNewProductionRestoreDeps_AllFourFieldsSet(t *testing.T) {
	deps := newProductionRestoreDeps(nil, nil)
	if deps.Preflight == nil {
		t.Errorf("Preflight is nil")
	}
	if deps.SafetyNet == nil {
		t.Errorf("SafetyNet is nil")
	}
	if deps.Mutation == nil {
		t.Errorf("Mutation is nil")
	}
	if deps.InlineVerify == nil {
		t.Errorf("InlineVerify is nil")
	}
}

// =============================================================================
// 3. Default newRestoreDeps points at the production factory.
// =============================================================================

func TestNewRestoreDeps_DefaultIsProductionFactory(t *testing.T) {
	// We compare reflect-pointer addresses to confirm newRestoreDeps
	// is initialized to newProductionRestoreDeps. (Function values
	// are not directly comparable in Go beyond nil; use reflect.)
	got := reflect.ValueOf(newRestoreDeps).Pointer()
	want := reflect.ValueOf(newProductionRestoreDeps).Pointer()
	if got != want {
		t.Errorf("newRestoreDeps default does not point at newProductionRestoreDeps; tests may have leaked a swap")
	}
}

// =============================================================================
// 4. The factory's deps satisfy the restore-package interfaces at
//    compile time. (Smoke check: build the deps and assign each field
//    to its interface variable.)
// =============================================================================

func TestNewProductionRestoreDeps_InterfaceCompliance(t *testing.T) {
	deps := newProductionRestoreDeps(nil, nil)
	var _ restore.PreflightDep = deps.Preflight
	var _ restore.SafetyNetDep = deps.SafetyNet
	var _ restore.MutationDep = deps.Mutation
	var _ restore.InlineVerifyDep = deps.InlineVerify
}

// =============================================================================
// 5. ErrRestoreExecutionUnavailable carries an explicit "not implemented
//    in this commit" message so logs and operator output make the
//    placeholder nature obvious.
// =============================================================================

func TestErrRestoreExecutionUnavailable_MessageIsExplicit(t *testing.T) {
	msg := ErrRestoreExecutionUnavailable.Error()
	required := []string{
		"execution dependency",
		"not implemented",
	}
	for _, sub := range required {
		if !strings.Contains(msg, sub) {
			t.Errorf("ErrRestoreExecutionUnavailable message %q missing substring %q", msg, sub)
		}
	}
}

// =============================================================================
// 6. No mutation surface in restore_deps.go — file-scan.
//
// 4B-1 made productionPreflightDep real (read-only via CommandExists +
// FileExists). The forbidden list still excludes any mutation API;
// preflight is read-only by contract §23.1.
// =============================================================================

func TestRestoreDeps_NoMutationSurface_FileScan(t *testing.T) {
	body, err := os.ReadFile("restore_deps.go")
	if err != nil {
		t.Fatalf("read restore_deps.go: %v", err)
	}
	src := string(body)
	// Note: "exec.Command(" is the os/exec constructor call. The
	// substring includes the open paren so it does NOT false-match
	// the Executor method exec.CommandExists() which 4B-1 uses for
	// read-only preflight.
	forbidden := []string{
		"os/exec",
		"exec.Command(",
		"os.WriteFile",
		"os.Create",
		"os.Remove(",
		"os.Rename",
		"syscall.",
		`"nft "`,
		`"systemctl `,
		// Live re-detection — preflight + stubs must not classify or
		// probe anything outside their narrow remit.
		"uninstall.Probe(",
		"uninstall.Classify(",
		"detect.DetectPanel(",
		// History writes
		"writeHistory(",
		// Mutation primitives — preflight is read-only; safety-net /
		// mutation / inline-verify are still stubs in 4B-1
		"ServiceStart(",
		"ServiceStop(",
		"ServiceEnable(",
		"ServiceDisable(",
		"ServiceMask(",
		"NftAddElement(",
		"NftDeleteTable(",
		"DaemonReload(",
		"WriteFileAtomic(",
	}
	for _, pat := range forbidden {
		if strings.Contains(src, pat) {
			t.Errorf("restore_deps.go references forbidden pattern %q", pat)
		}
	}
}

// =============================================================================
// =============================================================================
// 4B-1 — productionPreflightDep real-implementation tests
// =============================================================================
// =============================================================================

// fwt covers the §18.2 known firewall set.
var pf4B1KnownFirewalls = []string{"ufw", "firewalld", "iptables", "csf"}

// pf4B1MockWith builds a MockExecutor with the given binary present
// in PATH and the given unit-file paths present on disk. Anything not
// listed is absent (zero-value behavior of the mock's maps).
func pf4B1MockWith(binary string, unitFiles []string) *executor.MockExecutor {
	mock := executor.NewMockExecutor()
	if binary != "" {
		mock.ExistingCommands[binary] = true
	}
	for _, p := range unitFiles {
		mock.Files[p] = []byte{} // any non-nil content makes FileExists true
	}
	return mock
}

// =============================================================================
// 4B-1.1 Each known firewall passes when its canonical binary +
//        at least one canonical unit file are present.
// =============================================================================

func TestPreflightTarget_4B1_HappyPath_AllKnownFirewalls(t *testing.T) {
	cases := []struct {
		fwt     string
		binary  string
		unit    string
	}{
		{"ufw", "ufw", "/usr/lib/systemd/system/ufw.service"},
		{"firewalld", "firewall-cmd", "/usr/lib/systemd/system/firewalld.service"},
		{"iptables", "iptables", "/usr/lib/systemd/system/iptables.service"},
		{"csf", "csf", "/etc/systemd/system/csf.service"},
	}
	for _, c := range cases {
		t.Run(c.fwt, func(t *testing.T) {
			mock := pf4B1MockWith(c.binary, []string{c.unit})
			d := &productionPreflightDep{exec: mock}
			ok, err := d.PreflightTarget(context.Background(), c.fwt)
			if !ok {
				t.Errorf("PreflightTarget(%q) = false; want true", c.fwt)
			}
			if err != nil {
				t.Errorf("PreflightTarget(%q) returned err: %v", c.fwt, err)
			}
		})
	}
}

// =============================================================================
// 4B-1.2 Distro-aware unit-path lookup: canonical SAME-firewall
//        names in different /lib paths all satisfy the check.
//        This is NOT fallback to a different firewall — it's the
//        canonical set for the requested firewall.
// =============================================================================

func TestPreflightTarget_4B1_DistroAware_UnitPaths(t *testing.T) {
	// Each entry: firewallType + the path to verify produces a positive answer.
	cases := []struct {
		fwt  string
		path string
	}{
		// ufw
		{"ufw", "/usr/lib/systemd/system/ufw.service"},
		{"ufw", "/lib/systemd/system/ufw.service"},
		{"ufw", "/etc/systemd/system/ufw.service"},
		// firewalld
		{"firewalld", "/usr/lib/systemd/system/firewalld.service"},
		{"firewalld", "/lib/systemd/system/firewalld.service"},
		{"firewalld", "/etc/systemd/system/firewalld.service"},
		// iptables (RHEL)
		{"iptables", "/usr/lib/systemd/system/iptables.service"},
		{"iptables", "/lib/systemd/system/iptables.service"},
		// iptables (Debian/Ubuntu — netfilter-persistent)
		{"iptables", "/lib/systemd/system/netfilter-persistent.service"},
		{"iptables", "/usr/lib/systemd/system/netfilter-persistent.service"},
		{"iptables", "/etc/systemd/system/iptables.service"},
		{"iptables", "/etc/systemd/system/netfilter-persistent.service"},
		// csf
		{"csf", "/etc/systemd/system/csf.service"},
		{"csf", "/lib/systemd/system/csf.service"},
		{"csf", "/usr/lib/systemd/system/csf.service"},
	}
	for _, c := range cases {
		t.Run(c.fwt+"/"+c.path, func(t *testing.T) {
			// Use the firewall's first canonical binary; every entry
			// in the map has at least one binary listed.
			binary := preflightKnownFirewalls[c.fwt].binaries[0]
			mock := pf4B1MockWith(binary, []string{c.path})
			d := &productionPreflightDep{exec: mock}
			ok, err := d.PreflightTarget(context.Background(), c.fwt)
			if !ok {
				t.Errorf("PreflightTarget(%q) at %q = false; want true (canonical unit path)", c.fwt, c.path)
			}
			if err != nil {
				t.Errorf("PreflightTarget(%q) at %q err: %v", c.fwt, c.path, err)
			}
		})
	}
}

// =============================================================================
// 4B-1.3 Missing binary: refuses with ErrPreflightBinaryMissing.
// =============================================================================

func TestPreflightTarget_4B1_MissingBinary(t *testing.T) {
	for _, fwt := range pf4B1KnownFirewalls {
		t.Run(fwt, func(t *testing.T) {
			// Only the unit file is present; no binary in PATH.
			unit := preflightKnownFirewalls[fwt].unitFiles[0]
			mock := pf4B1MockWith("", []string{unit})
			d := &productionPreflightDep{exec: mock}
			ok, err := d.PreflightTarget(context.Background(), fwt)
			if ok {
				t.Errorf("PreflightTarget(%q) accepted with missing binary; want refusal", fwt)
			}
			if !errors.Is(err, ErrPreflightBinaryMissing) {
				t.Errorf("PreflightTarget(%q) err = %v; want ErrPreflightBinaryMissing", fwt, err)
			}
		})
	}
}

// =============================================================================
// 4B-1.4 Missing unit file: refuses with ErrPreflightUnitMissing.
// =============================================================================

func TestPreflightTarget_4B1_MissingUnitFile(t *testing.T) {
	for _, fwt := range pf4B1KnownFirewalls {
		t.Run(fwt, func(t *testing.T) {
			// Binary present; no unit file at any canonical path.
			binary := preflightKnownFirewalls[fwt].binaries[0]
			mock := pf4B1MockWith(binary, nil)
			d := &productionPreflightDep{exec: mock}
			ok, err := d.PreflightTarget(context.Background(), fwt)
			if ok {
				t.Errorf("PreflightTarget(%q) accepted with missing unit; want refusal", fwt)
			}
			if !errors.Is(err, ErrPreflightUnitMissing) {
				t.Errorf("PreflightTarget(%q) err = %v; want ErrPreflightUnitMissing", fwt, err)
			}
		})
	}
}

// =============================================================================
// 4B-1.5 Unknown firewallType: refuses with ErrPreflightUnknownFirewall.
//        Defensive guard — planner already validates, but the dep
//        re-checks to surface upstream invariant violations.
// =============================================================================

func TestPreflightTarget_4B1_UnknownFirewallType(t *testing.T) {
	cases := []string{
		"",
		"nftables",
		"pf",
		"ufw ", // trailing space — must NOT match
		"UFW",  // uppercase — must NOT match
		"shorewall",
	}
	for _, fwt := range cases {
		t.Run(fwt, func(t *testing.T) {
			mock := pf4B1MockWith("", nil)
			d := &productionPreflightDep{exec: mock}
			ok, err := d.PreflightTarget(context.Background(), fwt)
			if ok {
				t.Errorf("PreflightTarget(%q) accepted unknown firewall; want refusal", fwt)
			}
			if !errors.Is(err, ErrPreflightUnknownFirewall) {
				t.Errorf("PreflightTarget(%q) err = %v; want ErrPreflightUnknownFirewall", fwt, err)
			}
		})
	}
}

// =============================================================================
// 4B-1.6 Nil executor: refuses with ErrPreflightNilExecutor.
// =============================================================================

func TestPreflightTarget_4B1_NilExecutor(t *testing.T) {
	d := &productionPreflightDep{exec: nil}
	ok, err := d.PreflightTarget(context.Background(), "ufw")
	if ok {
		t.Errorf("PreflightTarget accepted nil executor; want refusal")
	}
	if !errors.Is(err, ErrPreflightNilExecutor) {
		t.Errorf("err = %v; want ErrPreflightNilExecutor", err)
	}
}

// =============================================================================
// 4B-1.7 Preflight makes ZERO mutation calls — exec.Commands recorded
//        list must remain empty across happy + refusal paths.
// =============================================================================

func TestPreflightTarget_4B1_NoMutationCalls(t *testing.T) {
	cases := []struct {
		name   string
		fwt    string
		binary string
		unit   string
	}{
		{"happy", "ufw", "ufw", "/usr/lib/systemd/system/ufw.service"},
		{"missing-binary", "ufw", "", "/usr/lib/systemd/system/ufw.service"},
		{"missing-unit", "ufw", "ufw", ""},
		{"unknown-fwt", "nftables", "", ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var unitFiles []string
			if c.unit != "" {
				unitFiles = []string{c.unit}
			}
			mock := pf4B1MockWith(c.binary, unitFiles)
			d := &productionPreflightDep{exec: mock}
			_, _ = d.PreflightTarget(context.Background(), c.fwt)

			// Commands recorded must be empty: preflight only calls
			// CommandExists + FileExists, neither of which records a
			// command in MockExecutor.Commands.
			if len(mock.Commands) != 0 {
				t.Errorf("preflight recorded mutation commands: %+v", mock.Commands)
			}
		})
	}
}

// =============================================================================
// 4B-1.8 No fallback to a DIFFERENT firewall when the requested one
//        has nothing on the host. The resolver must NOT silently
//        approve "ufw" when only csf is installed.
// =============================================================================

func TestPreflightTarget_4B1_NoFallbackBetweenFirewalls(t *testing.T) {
	// Host has CSF installed; caller asks for ufw.
	mock := pf4B1MockWith("csf", []string{"/etc/systemd/system/csf.service"})
	d := &productionPreflightDep{exec: mock}
	ok, err := d.PreflightTarget(context.Background(), "ufw")
	if ok {
		t.Errorf("preflight cross-firewall fallback: accepted ufw when only csf installed")
	}
	if !errors.Is(err, ErrPreflightBinaryMissing) {
		t.Errorf("err = %v; want ErrPreflightBinaryMissing", err)
	}
}

// =============================================================================
// 4B-1.9 Map content pin — preflightKnownFirewalls covers exactly the
//        §18.2 known set and no more, no less.
// =============================================================================

func TestPreflightKnownFirewalls_MapContentPin(t *testing.T) {
	want := map[string]bool{
		"ufw": true, "firewalld": true, "iptables": true, "csf": true,
	}
	if len(preflightKnownFirewalls) != len(want) {
		t.Errorf("preflightKnownFirewalls has %d entries; §18.2 set has %d",
			len(preflightKnownFirewalls), len(want))
	}
	for k := range want {
		if _, ok := preflightKnownFirewalls[k]; !ok {
			t.Errorf("preflightKnownFirewalls missing %q", k)
		}
	}
	for k := range preflightKnownFirewalls {
		if !want[k] {
			t.Errorf("preflightKnownFirewalls contains unauthorized entry %q", k)
		}
	}
	// Every entry must have at least one binary and one unit-file path.
	for k, v := range preflightKnownFirewalls {
		if len(v.binaries) == 0 {
			t.Errorf("%q has no canonical binaries", k)
		}
		if len(v.unitFiles) == 0 {
			t.Errorf("%q has no canonical unit-file paths", k)
		}
	}
}
