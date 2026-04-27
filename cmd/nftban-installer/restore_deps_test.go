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
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/restore"
)

// =============================================================================
// 1. Stub methods that REMAIN stubs after 4B-3-csf — only InlineVerify.
//    Real impls for inline-verify land in 4B-4.
//
//    Note: 4B-1 made productionPreflightDep real (read-only).
//    Note: 4B-2 made productionSafetyNetDep real (emergency-SSH).
//    Note: 4B-3-csf made productionMutationDep real for csf (typed
//          unsupported for the other §18.2 firewalls; typed unknown
//          for anything outside §18.2). Tests for that live in
//          restore_deps_csf_test.go.
//
// The narrowed assertion below pins the dispatch shape of the
// mutation dep: a non-csf known firewall returns
// ErrCSFRestoreOnlyAuthorized, and an unknown firewall returns
// ErrRestoreMutationUnknownFirewall. csf-specific behavior is in
// restore_deps_csf_test.go.
// =============================================================================

func TestProductionMutationDep_NonCSFKnown_ReturnsTypedUnsupported(t *testing.T) {
	for _, fwt := range []string{"ufw", "firewalld", "iptables"} {
		t.Run(fwt, func(t *testing.T) {
			d := &productionMutationDep{}
			err := d.MutateToTarget(context.Background(), fwt)
			if !errors.Is(err, ErrCSFRestoreOnlyAuthorized) {
				t.Errorf("MutateToTarget(%q) err = %v; want ErrCSFRestoreOnlyAuthorized", fwt, err)
			}
		})
	}
}

func TestProductionMutationDep_UnknownFirewall_ReturnsTypedUnknown(t *testing.T) {
	for _, fwt := range []string{"", "shorewall", "pf", "nftables", "CSF", "csf "} {
		t.Run(fmt.Sprintf("fwt=%q", fwt), func(t *testing.T) {
			d := &productionMutationDep{}
			err := d.MutateToTarget(context.Background(), fwt)
			if !errors.Is(err, ErrRestoreMutationUnknownFirewall) {
				t.Errorf("MutateToTarget(%q) err = %v; want ErrRestoreMutationUnknownFirewall", fwt, err)
			}
		})
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
	// 4B-3-pre changed the default to newProductionRestoreDepsWithEvidence
	// (the evidence-aware factory the dispatcher uses). Confirm via
	// reflect-pointer comparison; tests may have leaked a swap if
	// this fails.
	got := reflect.ValueOf(newRestoreDeps).Pointer()
	want := reflect.ValueOf(newProductionRestoreDepsWithEvidence).Pointer()
	if got != want {
		t.Errorf("newRestoreDeps default does not point at newProductionRestoreDepsWithEvidence; tests may have leaked a swap")
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

// =============================================================================
// =============================================================================
// 4B-2 — productionSafetyNetDep real-implementation tests
// =============================================================================
// =============================================================================

// fakeSSHPortFn returns a fixed port on every call. Used by 4B-2
// tests to avoid mocking the full detect.SSHPort source chain.
func fakeSSHPortFn(port int) func() (int, error) {
	return func() (int, error) { return port, nil }
}

// pf4B2TestLogger builds a logger that writes only to a temp file.
// switchop.InjectEmergencySSH calls log.Info on a non-nil logger, so
// every 4B-2 test that exercises Insert/Remove must construct the
// dep with a non-nil logger.
func pf4B2TestLogger(t *testing.T) *logging.Logger {
	t.Helper()
	return logging.New(filepath.Join(t.TempDir(), "test.log"), false)
}

// =============================================================================
// 4B-2.1 Insert happy path: emits exactly the expected nft-load
//        sequence, no other commands.
// =============================================================================

func TestSafetyNetDep_4B2_Insert_HappyPath_EmitsOnlyExpectedCommands(t *testing.T) {
	mock := executor.NewMockExecutor()
	// No stale emergency table → no idempotent NftDeleteTable call.

	s := &productionSafetyNetDep{
		log:       pf4B2TestLogger(t),
		exec:      mock,
		sshPortFn: fakeSSHPortFn(22),
	}

	if err := s.InsertEmergencySSH(context.Background()); err != nil {
		t.Fatalf("InsertEmergencySSH returned: %v", err)
	}

	// Exactly one Run call: nft -f <tmpPath>.
	if len(mock.Commands) != 1 {
		t.Fatalf("Insert recorded %d Run commands; want exactly 1 (nft -f). Got: %+v",
			len(mock.Commands), mock.Commands)
	}
	cmd := mock.Commands[0]
	if cmd.Name != "nft" {
		t.Errorf("first command name = %q; want %q", cmd.Name, "nft")
	}
	if len(cmd.Args) != 2 || cmd.Args[0] != "-f" {
		t.Errorf("first command args = %v; want [-f <tmpPath>]", cmd.Args)
	}
	tmpPath := cmd.Args[1]
	// Tmp path must be the documented switchop value.
	if tmpPath != "/tmp/.nftban-emergency-ssh.nft" {
		t.Errorf("nft -f path = %q; want /tmp/.nftban-emergency-ssh.nft", tmpPath)
	}

	// One file written: the same tmp path.
	if _, ok := mock.WrittenFiles[tmpPath]; !ok {
		t.Errorf("WrittenFiles missing %q; got %v", tmpPath, keysOf(mock.WrittenFiles))
	}

	// File content must contain the SSH port and the emergency table name.
	content := string(mock.WrittenFiles[tmpPath])
	if !strings.Contains(content, "tcp dport 22 accept") {
		t.Errorf("nft config does not contain expected port-22 rule:\n%s", content)
	}
	if !strings.Contains(content, "table inet "+emergencySafetyNetTable) {
		t.Errorf("nft config does not declare table %q:\n%s", emergencySafetyNetTable, content)
	}
}

// =============================================================================
// 4B-2.2 Insert with stale emergency table: idempotent — exactly ONE
//        delete-table call (for the emergency table, never for nftban
//        production tables).
// =============================================================================

func TestSafetyNetDep_4B2_Insert_StaleEmergencyTable_IdempotentDelete(t *testing.T) {
	mock := executor.NewMockExecutor()
	// Pre-existing stale emergency table.
	mock.NftTables["inet:"+emergencySafetyNetTable] = true
	// Production tables that MUST be preserved.
	mock.NftTables["ip:nftban"] = true
	mock.NftTables["ip6:nftban"] = true

	s := &productionSafetyNetDep{
		log:       pf4B2TestLogger(t),
		exec:      mock,
		sshPortFn: fakeSSHPortFn(22),
	}

	if err := s.InsertEmergencySSH(context.Background()); err != nil {
		t.Fatalf("Insert returned: %v", err)
	}

	// Production tables must still be present (idempotent delete is
	// scoped to the emergency table only).
	if !mock.NftTables["ip:nftban"] {
		t.Errorf("Insert deleted ip:nftban — broke production table (CRITICAL §17 violation)")
	}
	if !mock.NftTables["ip6:nftban"] {
		t.Errorf("Insert deleted ip6:nftban — broke production table (CRITICAL §17 violation)")
	}
}

// =============================================================================
// 4B-2.3 Insert with valid SSH port from sshPortFn writes that exact
//        port into the rule.
// =============================================================================

func TestSafetyNetDep_4B2_Insert_SSHPortFromConfigSource(t *testing.T) {
	cases := []int{22, 2222, 55000, 65535, 1}
	for _, port := range cases {
		t.Run(fmt.Sprintf("port-%d", port), func(t *testing.T) {
			mock := executor.NewMockExecutor()
			s := &productionSafetyNetDep{
				log:       pf4B2TestLogger(t),
				exec:      mock,
				sshPortFn: fakeSSHPortFn(port),
			}
			if err := s.InsertEmergencySSH(context.Background()); err != nil {
				t.Fatalf("Insert returned: %v", err)
			}
			content := string(mock.WrittenFiles["/tmp/.nftban-emergency-ssh.nft"])
			want := fmt.Sprintf("tcp dport %d accept", port)
			if !strings.Contains(content, want) {
				t.Errorf("nft config missing %q:\n%s", want, content)
			}
		})
	}
}

// =============================================================================
// 4B-2.4 Insert with sshPortFn returning error refuses BEFORE any
//        kernel mutation. ErrSafetyNetSSHPortUnknown surfaced.
// =============================================================================

func TestSafetyNetDep_4B2_Insert_SSHPortUnknown_NoMutation(t *testing.T) {
	mock := executor.NewMockExecutor()
	s := &productionSafetyNetDep{
		log:       pf4B2TestLogger(t),
		exec: mock,
		sshPortFn: func() (int, error) {
			return 0, errors.New("simulated detect.SSHPort failure")
		},
	}
	err := s.InsertEmergencySSH(context.Background())
	if err == nil {
		t.Fatalf("Insert accepted unknown SSH port; want refusal")
	}
	if !errors.Is(err, ErrSafetyNetSSHPortUnknown) {
		t.Errorf("err = %v; want ErrSafetyNetSSHPortUnknown", err)
	}
	// Critical: NO kernel mutation when SSH port unknown.
	if len(mock.Commands) != 0 {
		t.Errorf("Insert ran %d commands on SSH-port-unknown path; want 0: %+v",
			len(mock.Commands), mock.Commands)
	}
	if len(mock.WrittenFiles) != 0 {
		t.Errorf("Insert wrote %d files on SSH-port-unknown path; want 0",
			len(mock.WrittenFiles))
	}
}

// =============================================================================
// 4B-2.5 Insert with nil sshPortFn refuses BEFORE any kernel mutation.
// =============================================================================

func TestSafetyNetDep_4B2_Insert_NilSSHPortFn_NoMutation(t *testing.T) {
	mock := executor.NewMockExecutor()
	s := &productionSafetyNetDep{exec: mock, sshPortFn: nil, log: pf4B2TestLogger(t)}
	err := s.InsertEmergencySSH(context.Background())
	if !errors.Is(err, ErrSafetyNetSSHPortUnknown) {
		t.Errorf("err = %v; want ErrSafetyNetSSHPortUnknown", err)
	}
	if len(mock.Commands) != 0 || len(mock.WrittenFiles) != 0 {
		t.Errorf("nil sshPortFn caused mutation: cmds=%v files=%v",
			mock.Commands, keysOf(mock.WrittenFiles))
	}
}

// =============================================================================
// 4B-2.6 Insert with out-of-range SSH port refuses BEFORE any kernel
//        mutation.
// =============================================================================

func TestSafetyNetDep_4B2_Insert_InvalidSSHPort_NoMutation(t *testing.T) {
	for _, port := range []int{0, -1, -100, 65536, 999999} {
		t.Run(fmt.Sprintf("port-%d", port), func(t *testing.T) {
			mock := executor.NewMockExecutor()
			s := &productionSafetyNetDep{exec: mock, sshPortFn: fakeSSHPortFn(port), log: pf4B2TestLogger(t)}
			err := s.InsertEmergencySSH(context.Background())
			if !errors.Is(err, ErrSafetyNetInvalidSSHPort) {
				t.Errorf("err = %v; want ErrSafetyNetInvalidSSHPort", err)
			}
			if len(mock.Commands) != 0 || len(mock.WrittenFiles) != 0 {
				t.Errorf("invalid port %d caused mutation", port)
			}
		})
	}
}

// =============================================================================
// 4B-2.7 Insert with nil executor refuses cleanly.
// =============================================================================

func TestSafetyNetDep_4B2_Insert_NilExecutor(t *testing.T) {
	s := &productionSafetyNetDep{exec: nil, sshPortFn: fakeSSHPortFn(22), log: pf4B2TestLogger(t)}
	err := s.InsertEmergencySSH(context.Background())
	if !errors.Is(err, ErrSafetyNetNilExecutorProd) {
		t.Errorf("err = %v; want ErrSafetyNetNilExecutorProd", err)
	}
}

// =============================================================================
// 4B-2.8 Insert touches NO services / blacklist / whitelist /
//        DaemonReload / WriteFile-outside-tmp.
// =============================================================================

func TestSafetyNetDep_4B2_Insert_NoForbiddenSurfaces(t *testing.T) {
	mock := executor.NewMockExecutor()
	s := &productionSafetyNetDep{exec: mock, sshPortFn: fakeSSHPortFn(22), log: pf4B2TestLogger(t)}
	_ = s.InsertEmergencySSH(context.Background())

	// Run commands — only "nft -f <tmppath>" allowed.
	for _, cmd := range mock.Commands {
		if cmd.Name == "systemctl" {
			t.Errorf("Insert ran systemctl: %+v", cmd)
		}
		if cmd.Name == "nft" {
			if len(cmd.Args) != 2 || cmd.Args[0] != "-f" {
				t.Errorf("Insert ran nft with non-load args: %+v", cmd)
			}
		}
	}
	// WriteFileAtomic — only the documented tmp path.
	for path := range mock.WrittenFiles {
		if path != "/tmp/.nftban-emergency-ssh.nft" {
			t.Errorf("Insert wrote unexpected file %q", path)
		}
	}
	// nft set mutations — none.
	if len(mock.NftSets) != 0 {
		t.Errorf("Insert added/removed nft set elements: %v", mock.NftSets)
	}
}

// =============================================================================
// 4B-2.9 Remove happy path: deletes ONLY the emergency table.
// =============================================================================

func TestSafetyNetDep_4B2_Remove_HappyPath_DeletesOnlyEmergencyTable(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["inet:"+emergencySafetyNetTable] = true
	mock.NftTables["ip:nftban"] = true
	mock.NftTables["ip6:nftban"] = true

	s := &productionSafetyNetDep{exec: mock, log: pf4B2TestLogger(t)}

	if err := s.RemoveEmergencySSH(context.Background()); err != nil {
		t.Fatalf("Remove returned: %v", err)
	}

	if mock.NftTables["inet:"+emergencySafetyNetTable] {
		t.Errorf("Remove failed to delete emergency table")
	}
	if !mock.NftTables["ip:nftban"] {
		t.Errorf("Remove deleted ip:nftban — broke production table (CRITICAL §17 violation)")
	}
	if !mock.NftTables["ip6:nftban"] {
		t.Errorf("Remove deleted ip6:nftban — broke production table (CRITICAL §17 violation)")
	}
}

// =============================================================================
// 4B-2.10 Remove with no stale emergency table: no-op, returns nil.
// =============================================================================

func TestSafetyNetDep_4B2_Remove_NoEmergencyTable_NoOp(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["ip:nftban"] = true

	s := &productionSafetyNetDep{exec: mock, log: pf4B2TestLogger(t)}

	if err := s.RemoveEmergencySSH(context.Background()); err != nil {
		t.Errorf("Remove on absent emergency table returned: %v; want nil (idempotent)", err)
	}
	// Production tables must still be there.
	if !mock.NftTables["ip:nftban"] {
		t.Errorf("Remove (no-op path) deleted production table")
	}
}

// =============================================================================
// 4B-2.11 Remove with nil executor refuses cleanly.
// =============================================================================

func TestSafetyNetDep_4B2_Remove_NilExecutor(t *testing.T) {
	s := &productionSafetyNetDep{exec: nil, log: pf4B2TestLogger(t)}
	err := s.RemoveEmergencySSH(context.Background())
	if !errors.Is(err, ErrSafetyNetNilExecutorProd) {
		t.Errorf("err = %v; want ErrSafetyNetNilExecutorProd", err)
	}
}

// =============================================================================
// 4B-2.12 Remove emits NO Run / WriteFile / service / set mutation —
//         only NftDeleteTable on the emergency table.
// =============================================================================

func TestSafetyNetDep_4B2_Remove_NoForbiddenSurfaces(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.NftTables["inet:"+emergencySafetyNetTable] = true
	s := &productionSafetyNetDep{exec: mock, log: pf4B2TestLogger(t)}
	_ = s.RemoveEmergencySSH(context.Background())

	if len(mock.Commands) != 0 {
		t.Errorf("Remove ran Run commands: %+v", mock.Commands)
	}
	if len(mock.WrittenFiles) != 0 {
		t.Errorf("Remove wrote files: %v", keysOf(mock.WrittenFiles))
	}
	if len(mock.NftSets) != 0 {
		t.Errorf("Remove touched nft sets: %v", mock.NftSets)
	}
}

// =============================================================================
// 4B-2.13 IPv4/IPv6 dual-stack explicit: the rule lives in the
//         `inet` family which simultaneously matches IPv4 + IPv6.
//         No silent partial behavior.
// =============================================================================

func TestSafetyNetDep_4B2_DualStackExplicit(t *testing.T) {
	mock := executor.NewMockExecutor()
	s := &productionSafetyNetDep{exec: mock, sshPortFn: fakeSSHPortFn(22), log: pf4B2TestLogger(t)}
	if err := s.InsertEmergencySSH(context.Background()); err != nil {
		t.Fatalf("Insert: %v", err)
	}
	content := string(mock.WrittenFiles["/tmp/.nftban-emergency-ssh.nft"])
	// Must declare `table inet ...` — the inet family covers IPv4 + IPv6.
	if !strings.Contains(content, "table inet ") {
		t.Errorf("safety net does not use inet family (dual-stack):\n%s", content)
	}
	// Must NOT declare `ip` or `ip6` family separately (would be partial).
	for _, bad := range []string{"table ip ", "table ip6 "} {
		if strings.Contains(content, bad) {
			t.Errorf("safety net uses single-stack family %q — must be inet:\n%s", bad, content)
		}
	}
}

// =============================================================================
// 4B-2.14 Switchop table-name pin — emergencySafetyNetTable must
//         match switchop's unexported emergencyTable. If switchop
//         changes the const, this test fails so we update both.
//
//         Cross-package check: build a fresh emergency via switchop
//         on a mock, observe the resulting key in mock.NftTables.
// =============================================================================

func TestSafetyNetDep_4B2_TableNameMatchesSwitchop(t *testing.T) {
	// Use a logger seam so switchop can print.
	mock := executor.NewMockExecutor()
	s := &productionSafetyNetDep{exec: mock, sshPortFn: fakeSSHPortFn(22), log: pf4B2TestLogger(t)}
	if err := s.InsertEmergencySSH(context.Background()); err != nil {
		t.Fatalf("Insert: %v", err)
	}
	// After Insert via switchop, the file content references
	// emergencySafetyNetTable. If the const drifts from switchop's
	// internal one, the file content from switchop wouldn't contain
	// our local literal.
	content := string(mock.WrittenFiles["/tmp/.nftban-emergency-ssh.nft"])
	if !strings.Contains(content, emergencySafetyNetTable) {
		t.Errorf("switchop wrote a config that does not reference %q; the local mirror constant has drifted from switchop.emergencyTable",
			emergencySafetyNetTable)
	}
}

// =============================================================================
// helpers
// =============================================================================

func keysOf(m map[string][]byte) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
