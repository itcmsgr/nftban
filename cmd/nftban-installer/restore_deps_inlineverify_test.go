// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 PR-25 — Inline Verify Dep tests (commit 4B-4)
// =============================================================================
// meta:name="nftban-installer-restore-deps-inlineverify-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-28"
// meta:description="Behavior + file-scan tests for the productionInlineVerifyDep real implementation. Covers the three §21.1 assertions (target firewall active, current authority class, safety-net removal safe) plus the 4B-4 wiring pin (production factory now sets safetyNetRemovalSafeFn). Also pins a CSF integration test that proves A.7 deletes nftban tables only when the wired predicate returns true."
// meta:depends="github.com/itcmsgr/nftban/internal/installer/detect,github.com/itcmsgr/nftban/internal/installer/executor,github.com/itcmsgr/nftban/internal/installer/restore,github.com/itcmsgr/nftban/internal/installer/uninstall"
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
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/restore"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// =============================================================================
// Test helpers — local to this file. The mock builders here only
// configure state the inline-verify dep observes; they do NOT exercise
// mutation code.
// =============================================================================

// newInlineVerifyMock returns a MockExecutor pre-configured with the
// minimum state required by detect.SSHPort to succeed via the
// "ss listener" source — its highest-priority chain entry. Tests can
// further customize by setting Services / Files / RunResults.
func newInlineVerifyMock(t *testing.T, sshdPort int) *executor.MockExecutor {
	t.Helper()
	mock := executor.NewMockExecutor()
	// detect.SSHPort calls Run("ss", "-tlnp"). We seed a stdout that
	// includes a sshd listener on the requested port so the listener
	// source resolves without falling through to sshd_config.
	if sshdPort > 0 {
		mock.RunResults["ss:-tlnp"] = executor.Result{
			ExitCode: 0,
			Stdout: fmt.Sprintf(
				"State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n"+
					"LISTEN 0 128 0.0.0.0:%d 0.0.0.0:* users:((\"sshd\",pid=1,fd=3))\n",
				sshdPort,
			),
		}
	} else {
		// No sshd in listener output. detect.SSHPort then tries
		// sshd_config; we leave Files empty so it also fails. State
		// file and conf.local likewise absent. SSHPort returns error.
		mock.RunResults["ss:-tlnp"] = executor.Result{
			ExitCode: 0,
			Stdout:   "State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n",
		}
	}
	return mock
}

// newInlineVerifyDep returns a productionInlineVerifyDep wired to the
// given executor and a per-test logger.
func newInlineVerifyDep(t *testing.T, mock *executor.MockExecutor) *productionInlineVerifyDep {
	t.Helper()
	return &productionInlineVerifyDep{
		exec: mock,
		log:  pf4B2TestLogger(t),
	}
}

// =============================================================================
// Test #1: IsTargetFirewallActive("csf") queries only csf.service.
// =============================================================================

func TestInlineVerify_4B4_IsTargetFirewallActive_CSF_QueriesOnlyCSFService(t *testing.T) {
	mock := newInlineVerifyMock(t, 22)
	mock.Services["csf.service"] = true
	dep := newInlineVerifyDep(t, mock)

	active, err := dep.IsTargetFirewallActive(context.Background(), "csf")
	if err != nil {
		t.Fatalf("err = %v; want nil", err)
	}
	if !active {
		t.Errorf("active = false; want true")
	}

	// No service ops recorded — ServiceActive in the mock does not
	// record (only state-mutating systemctl ops do).
	for _, cmd := range mock.Commands {
		if cmd.Name == "systemctl" && len(cmd.Args) >= 2 {
			verb := cmd.Args[0]
			if verb == "start" || verb == "stop" || verb == "enable" ||
				verb == "disable" || verb == "mask" || verb == "unmask" {
				t.Errorf("IsTargetFirewallActive recorded mutation command: %+v", cmd)
			}
		}
	}
}

// =============================================================================
// Test #2: IsTargetFirewallActive(non-csf known) returns typed unsupported.
// =============================================================================

func TestInlineVerify_4B4_IsTargetFirewallActive_NonCSFKnown_ReturnsTypedUnsupported(t *testing.T) {
	for _, fwt := range []string{"ufw", "firewalld", "iptables"} {
		t.Run(fwt, func(t *testing.T) {
			mock := newInlineVerifyMock(t, 22)
			dep := newInlineVerifyDep(t, mock)
			active, err := dep.IsTargetFirewallActive(context.Background(), fwt)
			if active {
				t.Errorf("active = true; want false")
			}
			if !errors.Is(err, ErrInlineVerifyOnlyCSFAuthorized) {
				t.Errorf("err = %v; want ErrInlineVerifyOnlyCSFAuthorized", err)
			}
		})
	}
}

// =============================================================================
// Test #3: IsTargetFirewallActive(unknown) returns typed unknown.
// =============================================================================

func TestInlineVerify_4B4_IsTargetFirewallActive_Unknown_ReturnsTypedUnknown(t *testing.T) {
	for _, fwt := range []string{"", "shorewall", "pf", "CSF", "csf "} {
		t.Run(fmt.Sprintf("fwt=%q", fwt), func(t *testing.T) {
			mock := newInlineVerifyMock(t, 22)
			dep := newInlineVerifyDep(t, mock)
			_, err := dep.IsTargetFirewallActive(context.Background(), fwt)
			if !errors.Is(err, ErrInlineVerifyUnknownFirewall) {
				t.Errorf("err = %v; want ErrInlineVerifyUnknownFirewall", err)
			}
		})
	}
}

// =============================================================================
// Test #4: CurrentAuthorityClass calls uninstall.Classify as
// verification — observable result includes the State field that
// Classify produced. Not fed back into planner.
// =============================================================================

func TestInlineVerify_4B4_CurrentAuthorityClass_ReturnsClassifierState(t *testing.T) {
	// Seed a state where Classify() returns AuthorityNFTBan: ip nftban
	// table present + nftband.service active. (Per uninstall/authority.go
	// detection inputs.)
	mock := newInlineVerifyMock(t, 22)
	mock.NftTables["ip:nftban"] = true
	mock.Services["nftband.service"] = true

	dep := newInlineVerifyDep(t, mock)
	got, err := dep.CurrentAuthorityClass(context.Background())
	if err != nil {
		t.Fatalf("err = %v; want nil", err)
	}
	if got != uninstall.AuthorityNFTBan {
		t.Errorf("class = %q; want AuthorityNFTBan", got)
	}
}

func TestInlineVerify_4B4_CurrentAuthorityClass_ExternalState(t *testing.T) {
	// External authority: csf.service active without nftban kernel.
	mock := newInlineVerifyMock(t, 22)
	mock.Services["csf.service"] = true
	mock.ExistingCommands["csf"] = true
	mock.Files["/usr/sbin/csf"] = []byte{}

	dep := newInlineVerifyDep(t, mock)
	got, _ := dep.CurrentAuthorityClass(context.Background())
	// We don't pin the exact value (extfw.Detect's mapping is its
	// own contract); we pin that it's NOT AuthorityNFTBan and
	// the dep returned without error.
	if got == uninstall.AuthorityNFTBan {
		t.Errorf("class = %q; want NOT AuthorityNFTBan when nftban kernel absent", got)
	}
}

// =============================================================================
// Test #5: CurrentAuthorityClass does NOT call DetectPanel / Probe /
// restore.Decide. File-scan on the production source.
// =============================================================================

func TestInlineVerify_4B4_NoDecisionPathCalls_FileScan(t *testing.T) {
	body, err := os.ReadFile("restore_deps.go")
	if err != nil {
		t.Fatalf("read restore_deps.go: %v", err)
	}
	src := string(body)
	forbidden := []string{
		"detect.DetectPanel(",
		"uninstall.Probe(",
		"restore.Decide(",
		"restore.PlanFromDecision(",
	}
	for _, pat := range forbidden {
		if strings.Contains(src, pat) {
			t.Errorf("restore_deps.go references decision-path call %q (forbidden in inline-verify scope)", pat)
		}
	}
}

// =============================================================================
// Test #6: IsSafetyNetRemovalSafe returns true only when an external
// firewall service is active AND the SSH port is observable.
// =============================================================================

func TestInlineVerify_4B4_IsSafetyNetRemovalSafe_TrueOnlyWhenExternalFWActive(t *testing.T) {
	mock := newInlineVerifyMock(t, 22)
	mock.Services["csf.service"] = true // external firewall active

	dep := newInlineVerifyDep(t, mock)
	safe, err := dep.IsSafetyNetRemovalSafe(context.Background())
	if err != nil {
		t.Fatalf("err = %v; want nil", err)
	}
	if !safe {
		t.Errorf("safe = false; want true (csf active + sshd port observable)")
	}
}

// =============================================================================
// Test #7: IsSafetyNetRemovalSafe returns false when the only
// protection is the emergency table (no external firewall service
// active).
// =============================================================================

func TestInlineVerify_4B4_IsSafetyNetRemovalSafe_FalseWhenOnlyEmergencyProtects(t *testing.T) {
	mock := newInlineVerifyMock(t, 22)
	// Emergency table is present, but no external firewall service.
	mock.NftTables["inet:nftban_install_emergency"] = true
	// nftband stopped (as it would be after A.6).
	mock.Services["nftband.service"] = false

	dep := newInlineVerifyDep(t, mock)
	safe, err := dep.IsSafetyNetRemovalSafe(context.Background())
	if err != nil {
		t.Errorf("err = %v; want nil (the predicate refuses cleanly, not via error)", err)
	}
	if safe {
		t.Errorf("safe = true; want false (only emergency table protects)")
	}
}

// =============================================================================
// Test #8: IsSafetyNetRemovalSafe returns error when SSH port unknown.
// =============================================================================

func TestInlineVerify_4B4_IsSafetyNetRemovalSafe_FalseWhenSSHPortUnknown(t *testing.T) {
	// sshdPort=0 → the mock seeds an empty ss listener output and
	// no /etc/ssh/sshd_config; detect.SSHPort returns error.
	mock := newInlineVerifyMock(t, 0)
	mock.Services["csf.service"] = true // even with csf active, SSH port unknown → refuse

	dep := newInlineVerifyDep(t, mock)
	safe, err := dep.IsSafetyNetRemovalSafe(context.Background())
	if !errors.Is(err, ErrInlineVerifySSHPortUnknown) {
		t.Errorf("err = %v; want ErrInlineVerifySSHPortUnknown", err)
	}
	if safe {
		t.Errorf("safe = true; want false")
	}
}

// =============================================================================
// Test #9: IsSafetyNetRemovalSafe performs no mutation — no
// systemctl/nft/exec/file-write recorded.
// =============================================================================

func TestInlineVerify_4B4_IsSafetyNetRemovalSafe_NoMutation(t *testing.T) {
	mock := newInlineVerifyMock(t, 22)
	mock.Services["csf.service"] = true

	dep := newInlineVerifyDep(t, mock)
	_, _ = dep.IsSafetyNetRemovalSafe(context.Background())

	// Allowed Run commands (read-only): ss -tlnp; nothing else.
	allowedRun := func(cmd executor.RecordedCommand) bool {
		if cmd.Name == "ss" {
			if len(cmd.Args) == 1 && cmd.Args[0] == "-tlnp" {
				return true
			}
		}
		return false
	}
	for _, cmd := range mock.Commands {
		if cmd.Name == "systemctl" {
			t.Errorf("IsSafetyNetRemovalSafe ran systemctl: %+v", cmd)
		}
		if cmd.Name == "nft" {
			t.Errorf("IsSafetyNetRemovalSafe ran nft: %+v", cmd)
		}
		if cmd.Name == "mv" || cmd.Name == "rm" || cmd.Name == "cp" {
			t.Errorf("IsSafetyNetRemovalSafe ran fs-mutating cmd: %+v", cmd)
		}
		if cmd.Name == "ss" && !allowedRun(cmd) {
			t.Errorf("IsSafetyNetRemovalSafe ran unexpected ss flavor: %+v", cmd)
		}
	}
	if len(mock.WrittenFiles) != 0 {
		t.Errorf("IsSafetyNetRemovalSafe wrote files: %v", mock.WrittenFiles)
	}
	if len(mock.NftSets) != 0 {
		t.Errorf("IsSafetyNetRemovalSafe touched nft sets: %v", mock.NftSets)
	}
}

// =============================================================================
// Test #10: production factory wires safetyNetRemovalSafeFn non-nil.
// (Companion to the flipped 4B-3-csf PR25NonShipping pin.)
// =============================================================================

func TestInlineVerify_4B4_FactoryWiresSafetyNetPredicate(t *testing.T) {
	deps := newProductionRestoreDepsWithEvidence(nil, nil, nil, detect.PanelNone)
	mut, ok := deps.Mutation.(*productionMutationDep)
	if !ok {
		t.Fatalf("Mutation is not *productionMutationDep")
	}
	if mut.safetyNetRemovalSafeFn == nil {
		t.Fatalf("safetyNetRemovalSafeFn is nil; 4B-4 must wire it to inlineVerify.IsSafetyNetRemovalSafe")
	}
	// The wired closure must reach inlineVerify, not bypass it.
	// Confirm by giving the dep a non-csf-active mock and observing
	// the predicate refuses (no external FW + no SSH port).
	mock := newInlineVerifyMock(t, 0)
	// Re-construct deps with this exec so the closure consults it.
	deps = newProductionRestoreDepsWithEvidence(mock, pf4B2TestLogger(t), nil, detect.PanelNone)
	mut = deps.Mutation.(*productionMutationDep)
	safe, _ := mut.safetyNetRemovalSafeFn(context.Background())
	if safe {
		t.Errorf("wired predicate returned true with no SSH and no external FW; want false")
	}
}

// =============================================================================
// Test #11: integration — A.7 deletes nftban tables when wired
// predicate returns true.
// =============================================================================

func TestInlineVerify_4B4_Integration_A7_DeletesWhenPredicateTrue(t *testing.T) {
	// Build the same fixture buildCSFFixture would, but wire the
	// mutation dep to the REAL production predicate via the factory.
	mock := newInlineVerifyMock(t, 22)
	mock.Files["/usr/sbin/csf.disabled"] = []byte{}
	mock.NftTables["ip:nftban"] = true
	mock.NftTables["ip6:nftban"] = true

	priorActive := true
	priorRec := &uninstall.PriorRecord{
		SchemaVersion:   uninstall.PriorRecordSchemaVersion,
		FirewallType:    "csf",
		ActiveAtInstall: &priorActive,
	}

	deps := newProductionRestoreDepsWithEvidence(mock, pf4B2TestLogger(t), priorRec, detect.PanelNone)
	mut := deps.Mutation.(*productionMutationDep)

	// At the point in the §32 ordering where the predicate is consulted,
	// csf.service is active (set by A.5 ServiceStart in the mock) and
	// nftband.service is stopped. Our mock's ServiceStart auto-sets
	// Services["csf.service"]=true; we manually set the post-A.6 state.
	if err := mutateToCSFTarget(context.Background(), mut); err != nil {
		t.Fatalf("happy-path mutate err = %v; want nil", err)
	}

	if mock.NftTables["ip:nftban"] || mock.NftTables["ip6:nftban"] {
		t.Errorf("A.7 did not delete nftban tables despite wired predicate returning true")
	}
}

// =============================================================================
// Test #12: integration — A.7 still refuses when predicate returns false.
// =============================================================================

func TestInlineVerify_4B4_Integration_A7_RefusesWhenPredicateFalse(t *testing.T) {
	// Setup forces predicate to return false: no SSH listener.
	mock := newInlineVerifyMock(t, 0)
	mock.Files["/usr/sbin/csf.disabled"] = []byte{}
	mock.NftTables["ip:nftban"] = true
	mock.NftTables["ip6:nftban"] = true

	priorActive := true
	priorRec := &uninstall.PriorRecord{
		SchemaVersion:   uninstall.PriorRecordSchemaVersion,
		FirewallType:    "csf",
		ActiveAtInstall: &priorActive,
	}
	deps := newProductionRestoreDepsWithEvidence(mock, pf4B2TestLogger(t), priorRec, detect.PanelNone)
	mut := deps.Mutation.(*productionMutationDep)

	err := mutateToCSFTarget(context.Background(), mut)
	if !errors.Is(err, ErrCSFRestoreNftReleaseUnsafe) {
		t.Errorf("err = %v; want ErrCSFRestoreNftReleaseUnsafe", err)
	}
	if !mock.NftTables["ip:nftban"] || !mock.NftTables["ip6:nftban"] {
		t.Errorf("A.7 deleted nftban tables despite wired predicate refusing")
	}
}

// =============================================================================
// Test #13: InlineVerify (full 3-assertion call) checks exactly the
// three §21.1 questions and nothing more.
// =============================================================================

func TestInlineVerify_4B4_FullRun_ChecksThreeAssertionsOnly(t *testing.T) {
	mock := newInlineVerifyMock(t, 22)
	mock.Services["csf.service"] = true
	// External authority observed: csf binary present + active.
	mock.ExistingCommands["csf"] = true
	mock.Files["/usr/sbin/csf"] = []byte{}

	dep := newInlineVerifyDep(t, mock)
	vr := restore.InlineVerify(context.Background(), dep, "csf", uninstall.AuthorityExternal)
	if vr.Err != nil {
		t.Fatalf("Err = %v; want nil", vr.Err)
	}
	if !vr.TargetFirewallActive {
		t.Errorf("TargetFirewallActive = false; want true")
	}
	if !vr.SafetyNetRemovalSafe {
		t.Errorf("SafetyNetRemovalSafe = false; want true")
	}
	// AuthorityClassCorrect depends on extfw.Detect mapping behavior;
	// what matters is that ObservedAuthority was populated.
	if vr.ObservedAuthority == "" {
		t.Errorf("ObservedAuthority empty; CurrentAuthorityClass did not run")
	}
}

// =============================================================================
// Test #14: no full-validator / module-health / CLI-truth surface in
// the inline-verify code.
// =============================================================================

func TestInlineVerify_4B4_NoFullValidatorSurface_FileScan(t *testing.T) {
	body, err := os.ReadFile("restore_deps.go")
	if err != nil {
		t.Fatalf("read restore_deps.go: %v", err)
	}
	src := string(body)
	forbidden := []string{
		// Full validator surface (PR-26 territory)
		"validator.Run",
		"validator.RunAll",
		"validator.Health",
		// Module-health probe surface
		"health.Check",
		"health.Probe",
		"healthmodel.",
		// CLI parse-as-truth (the inline-verify must rely on kernel +
		// service signals, not "nft list" stdout parsing).
		"nft list ruleset",
		`"nft", "list"`,
		"NftListSet(",
	}
	for _, pat := range forbidden {
		if strings.Contains(src, pat) {
			t.Errorf("restore_deps.go references forbidden full-validator/CLI-truth pattern %q", pat)
		}
	}
}

// =============================================================================
// Test #15: no update-history / StateCommitted references in the
// inline-verify code path.
// =============================================================================

func TestInlineVerify_4B4_NoHistoryReferences_FileScan(t *testing.T) {
	body, err := os.ReadFile("restore_deps.go")
	if err != nil {
		t.Fatalf("read restore_deps.go: %v", err)
	}
	src := string(body)
	forbidden := []string{
		"writeHistory(",
		"update-history",
		"StateCommitted",
		"IsApplyTerminal(",
	}
	for _, pat := range forbidden {
		if strings.Contains(src, pat) {
			t.Errorf("restore_deps.go references history/commit pattern %q (forbidden in PR-25 §19.2 layer 4)", pat)
		}
	}
}

// =============================================================================
// Test #16: no direct os/exec / nft / systemctl bypass in inline-verify.
// =============================================================================

func TestInlineVerify_4B4_NoDirectOSBypass_FileScan(t *testing.T) {
	body, err := os.ReadFile("restore_deps.go")
	if err != nil {
		t.Fatalf("read restore_deps.go: %v", err)
	}
	src := string(body)
	forbidden := []string{
		"os/exec",
		"exec.Command(",
		"os.WriteFile",
		"os.Create",
		"os.Remove(",
		"os.Rename",
		"syscall.",
	}
	for _, pat := range forbidden {
		if strings.Contains(src, pat) {
			t.Errorf("restore_deps.go references direct-OS bypass %q", pat)
		}
	}
}

// (Test #17 — `go test -race` — is exercised at the suite level on
// lab2, not as a Go test function. The suite-level invocation is the
// authoritative pin.)
