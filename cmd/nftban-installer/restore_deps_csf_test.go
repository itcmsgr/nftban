// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 PR-25 — CSF Restore Mutation tests (commit 4B-3-csf)
// =============================================================================
// meta:name="nftban-installer-restore-deps-csf-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-28"
// meta:description="Behavior + file-scan tests for the CSF restore mutation path. Covers A.1-A.7 happy/precondition-false/idempotency/no-out-of-target per Amendment 1 §35.1. Also pins ordering, evidence gates, and forbidden-surface absence."
// meta:depends="github.com/itcmsgr/nftban/internal/installer/detect,github.com/itcmsgr/nftban/internal/installer/executor,github.com/itcmsgr/nftban/internal/installer/uninstall"
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
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/switchop"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// =============================================================================
// Test helpers — kept private to this file. Build CSF-restore-ready
// productionMutationDep instances with controlled mock state.
// =============================================================================

// csfTestFixture controls evidence + mock-host state for a single
// mutateToCSFTarget invocation.
type csfTestFixture struct {
	// Evidence
	priorRecCSF      bool          // true → priorRec set with FirewallType="csf"
	priorRecActive   bool          // ActiveAtInstall (only meaningful when priorRecCSF)
	panelDirectAdmin bool          // true → panel = PanelDirectAdmin (E.7)
	priorRecOverride *uninstall.PriorRecord // when non-nil, replaces the constructed priorRec

	// Host state
	csfPresent         bool // /usr/sbin/csf
	csfDisabledPresent bool // /usr/sbin/csf.disabled
	csfMasked          bool // systemctl is-enabled csf.service prints "masked"
	nftbandActive      bool // ServiceActive("nftband.service")
	nftbanTablesExist  bool // ip:nftban + ip6:nftban present in mock.NftTables

	// Behaviour control
	mvBinaryFailsExit int // non-zero → mv csf.disabled csf returns this exit code
	unmaskFailsExit   int // non-zero → systemctl unmask returns this exit code

	// A.7 predicate
	safetyNetSafeFn func(context.Context) (bool, error)
}

// buildCSFFixture constructs a productionMutationDep + MockExecutor
// reflecting the fixture. Returns dep, mock for assertion.
func buildCSFFixture(t *testing.T, f csfTestFixture) (*productionMutationDep, *executor.MockExecutor) {
	t.Helper()
	mock := executor.NewMockExecutor()

	// Files (binaries).
	if f.csfPresent {
		mock.Files[csfBinary] = []byte{}
	}
	if f.csfDisabledPresent {
		mock.Files[csfBinaryDisabled] = []byte{}
	}

	// Pre-populate Services map so ServiceActive returns the seed.
	if f.nftbandActive {
		mock.Services[nftbandUnit] = true
	}

	// systemctl is-enabled csf.service result — controls
	// isCSFServiceMasked.
	if f.csfMasked {
		mock.RunResults["systemctl:is-enabled:"+csfServiceUnit] = executor.Result{
			ExitCode: 1, Stdout: "masked\n",
		}
	} else {
		mock.RunResults["systemctl:is-enabled:"+csfServiceUnit] = executor.Result{
			ExitCode: 0, Stdout: "enabled\n",
		}
	}

	// PR-26-code-B: systemctl unmask now goes through the typed
	// executor.ServiceUnmask method. Simulate failure via the
	// MockExecutor.ServiceUnmaskErr injection field.
	if f.unmaskFailsExit != 0 {
		mock.ServiceUnmaskErr = errors.New("simulated unmask failure")
	}

	// PR-26-code-B: mv now goes through the typed executor.Rename
	// method. Failure is injected via MockExecutor.RenameErr; success
	// updates mock.Files automatically (the typed-method semantics
	// match the prior OnCommand callback that simulated the rename).
	if f.mvBinaryFailsExit != 0 {
		mock.RenameErr = errors.New("simulated rename failure")
	}

	// nftban tables.
	if f.nftbanTablesExist {
		mock.NftTables["ip:nftban"] = true
		mock.NftTables["ip6:nftban"] = true
	}

	// Build evidence.
	var priorRec *uninstall.PriorRecord
	if f.priorRecOverride != nil {
		priorRec = f.priorRecOverride
	} else if f.priorRecCSF {
		active := f.priorRecActive
		priorRec = &uninstall.PriorRecord{
			SchemaVersion:   uninstall.PriorRecordSchemaVersion,
			FirewallType:    "csf",
			ActiveAtInstall: &active,
		}
	}
	panel := detect.PanelNone
	if f.panelDirectAdmin {
		panel = detect.PanelDirectAdmin
	}

	dep := &productionMutationDep{
		exec:                   mock,
		log:                    pf4B2TestLogger(t),
		priorRec:               priorRec,
		panel:                  panel,
		safetyNetRemovalSafeFn: f.safetyNetSafeFn,
	}
	return dep, mock
}

// flakyCSFActiveExec wraps a MockExecutor and overrides
// ServiceActive(csf.service) regardless of what mock.Services holds.
// Used by the §32 step-5 post-A.5-inactive failure test, which needs
// ServiceStart to succeed but ServiceActive to immediately report
// false. The plain mock can't express that state because its
// ServiceStart unconditionally sets Services[unit]=true.
type flakyCSFActiveExec struct {
	*executor.MockExecutor
	csfActive bool
}

func (f *flakyCSFActiveExec) ServiceActive(unit string) bool {
	if unit == csfServiceUnit {
		return f.csfActive
	}
	return f.MockExecutor.ServiceActive(unit)
}

// alwaysSafe / alwaysUnsafe are the two test-side predicates for A.7.
func alwaysSafe(_ context.Context) (bool, error)   { return true, nil }
func alwaysUnsafe(_ context.Context) (bool, error) { return false, nil }

// =============================================================================
// 4B-3-csf — Test #3: evidence gates consume priorRec / panel; refuse
// if neither E.1 nor E.7 holds. NO live re-detection.
// =============================================================================

func TestCSFMutate_4B3csf_Evidence_RefusesWhenNeitherE1NorE7(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		// Neither prior-csf nor PanelDirectAdmin — invariant violation.
		priorRecCSF:        false,
		panelDirectAdmin:   false,
		csfDisabledPresent: true,
	})
	err := mutateToCSFTarget(context.Background(), dep)
	if !errors.Is(err, ErrCSFRestoreEvidenceMissing) {
		t.Errorf("err = %v; want ErrCSFRestoreEvidenceMissing", err)
	}
	// Critical: NO mutation calls before evidence refusal.
	if len(mock.Commands) != 0 {
		t.Errorf("evidence refusal recorded mutation commands: %+v", mock.Commands)
	}
}

func TestCSFMutate_4B3csf_Evidence_E1Alone_Proceeds(t *testing.T) {
	dep, _ := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		panelDirectAdmin:   false,
		csfDisabledPresent: true,
	})
	err := mutateToCSFTarget(context.Background(), dep)
	// We expect A.7 to refuse (predicate unwired) — but the function
	// must reach A.7, proving E.1 alone is sufficient evidence.
	if !errors.Is(err, ErrCSFRestoreNftReleaseUnsafe) {
		t.Errorf("E.1-alone path err = %v; want ErrCSFRestoreNftReleaseUnsafe (A.7 refusal)", err)
	}
}

func TestCSFMutate_4B3csf_Evidence_E7Alone_Proceeds(t *testing.T) {
	dep, _ := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        false, // no prior record
		panelDirectAdmin:   true,  // E.7 alone
		csfDisabledPresent: true,
	})
	err := mutateToCSFTarget(context.Background(), dep)
	if !errors.Is(err, ErrCSFRestoreNftReleaseUnsafe) {
		t.Errorf("E.7-alone path err = %v; want ErrCSFRestoreNftReleaseUnsafe (A.7 refusal)", err)
	}
}

// =============================================================================
// 4B-3-csf — E.3 binary state: ambiguous, uninstalled, only-csf, only-disabled.
// =============================================================================

func TestCSFMutate_4B3csf_E3_Ambiguous_RefusesAtPreflight(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfPresent:         true,
		csfDisabledPresent: true,
	})
	err := mutateToCSFTarget(context.Background(), dep)
	if !errors.Is(err, ErrCSFRestoreAmbiguousBinary) {
		t.Errorf("err = %v; want ErrCSFRestoreAmbiguousBinary", err)
	}
	// Ambiguous-state refusal must run NO mutation commands (preflight).
	if len(mock.Commands) != 0 {
		t.Errorf("ambiguous-binary refusal ran mutation commands: %+v", mock.Commands)
	}
}

func TestCSFMutate_4B3csf_E3_Uninstalled_RefusesAtPreflight(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfPresent:         false,
		csfDisabledPresent: false,
	})
	err := mutateToCSFTarget(context.Background(), dep)
	if !errors.Is(err, ErrCSFRestoreCSFUninstalled) {
		t.Errorf("err = %v; want ErrCSFRestoreCSFUninstalled", err)
	}
	if len(mock.Commands) != 0 {
		t.Errorf("uninstalled refusal ran mutation commands: %+v", mock.Commands)
	}
}

// =============================================================================
// 4B-3-csf — Test #4: A.1 unmask only when masked.
// =============================================================================

func TestCSFMutate_4B3csf_A1_Unmask_OnlyWhenMasked(t *testing.T) {
	cases := []struct {
		name       string
		masked     bool
		wantUnmask bool
	}{
		{"masked", true, true},
		{"not-masked", false, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dep, mock := buildCSFFixture(t, csfTestFixture{
				priorRecCSF:        true,
				priorRecActive:     true,
				csfDisabledPresent: true,
				csfMasked:          c.masked,
			})
			_ = mutateToCSFTarget(context.Background(), dep)

			unmaskCalled := mock.CommandCalled("systemctl", "unmask", csfServiceUnit)
			if unmaskCalled != c.wantUnmask {
				t.Errorf("unmask called = %v; want %v (masked=%v)", unmaskCalled, c.wantUnmask, c.masked)
			}
		})
	}
}

func TestCSFMutate_4B3csf_A1_NoUnmaskOfOtherServices(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
		csfMasked:          true,
	})
	_ = mutateToCSFTarget(context.Background(), dep)
	for _, cmd := range mock.Commands {
		if cmd.Name == "systemctl" && len(cmd.Args) >= 2 && cmd.Args[0] == "unmask" && cmd.Args[1] != csfServiceUnit {
			t.Errorf("A.1 unmasked unauthorized service: %+v", cmd)
		}
	}
}

func TestCSFMutate_4B3csf_A1_UnmaskFailure_ReturnsTypedError(t *testing.T) {
	dep, _ := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
		csfMasked:          true,
		unmaskFailsExit:    1,
	})
	err := mutateToCSFTarget(context.Background(), dep)
	if !errors.Is(err, ErrCSFRestoreUnmaskFailed) {
		t.Errorf("err = %v; want ErrCSFRestoreUnmaskFailed", err)
	}
}

// =============================================================================
// 4B-3-csf — Test #5: A.2 enable only the csf.service.
// =============================================================================

func TestCSFMutate_4B3csf_A2_EnableOnlyCSFService(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
	})
	_ = mutateToCSFTarget(context.Background(), dep)

	enableCount := 0
	for _, cmd := range mock.Commands {
		if cmd.Name == "systemctl" && len(cmd.Args) >= 2 && cmd.Args[0] == "enable" {
			enableCount++
			if cmd.Args[1] != csfServiceUnit {
				t.Errorf("A.2 enabled unauthorized service: %+v", cmd)
			}
		}
	}
	if enableCount != 1 {
		t.Errorf("A.2 enable count = %d; want exactly 1 (csf.service)", enableCount)
	}
}

// =============================================================================
// 4B-3-csf — Test #6: A.3 binary restore branches.
// =============================================================================

func TestCSFMutate_4B3csf_A3_Renames_DisabledToCSF(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
		csfPresent:         false,
	})
	_ = mutateToCSFTarget(context.Background(), dep)

	// PR-26-code-B: A.3 now goes through typed executor.Rename, which
	// MockExecutor records as "rename" (not "mv").
	renameCalled := mock.CommandCalled("rename", csfBinaryDisabled, csfBinary)
	if !renameCalled {
		t.Errorf("A.3 did not call Rename(%s, %s)", csfBinaryDisabled, csfBinary)
	}
}

func TestCSFMutate_4B3csf_A3_SkipsWhenDisabledAbsent(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfPresent:         true,
		csfDisabledPresent: false,
	})
	_ = mutateToCSFTarget(context.Background(), dep)

	if mock.CommandCalled("rename", csfBinaryDisabled, csfBinary) {
		t.Errorf("A.3 called Rename when .disabled was absent")
	}
}

func TestCSFMutate_4B3csf_A3_AmbiguousAlreadyCovered(t *testing.T) {
	// A.3 ambiguous case is handled by E.3 preflight refusal; this
	// test pins that the refusal happens BEFORE A.3's mv command.
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfPresent:         true,
		csfDisabledPresent: true,
	})
	err := mutateToCSFTarget(context.Background(), dep)
	if !errors.Is(err, ErrCSFRestoreAmbiguousBinary) {
		t.Fatalf("err = %v; want ErrCSFRestoreAmbiguousBinary", err)
	}
	if mock.CommandCalled("rename", csfBinaryDisabled, csfBinary) {
		t.Errorf("ambiguous-binary refusal still ran A.3's Rename")
	}
}

func TestCSFMutate_4B3csf_A3_RenameFailure_ReturnsTypedError(t *testing.T) {
	dep, _ := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
		mvBinaryFailsExit:  1,
	})
	err := mutateToCSFTarget(context.Background(), dep)
	if !errors.Is(err, ErrCSFRestoreBinaryRestoreFailed) {
		t.Errorf("err = %v; want ErrCSFRestoreBinaryRestoreFailed", err)
	}
}

// =============================================================================
// 4B-3-csf — Test #7: A.4 cron soft-skip + warning + zero file writes.
// =============================================================================

func TestCSFMutate_4B3csf_A4_SoftSkip_ZeroFileWrites(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
	})
	_ = mutateToCSFTarget(context.Background(), dep)
	// A.4 must not WriteFileAtomic to /etc/cron.d/* or anywhere else.
	for path := range mock.WrittenFiles {
		if strings.HasPrefix(path, "/etc/cron.d/") {
			t.Errorf("A.4 wrote cron file %q; soft-skip required (E.5 manifest absent)", path)
		}
	}
	// Must not invoke rm on cron paths either.
	for _, cmd := range mock.Commands {
		if cmd.Name == "rm" {
			for _, arg := range cmd.Args {
				if strings.HasPrefix(arg, "/etc/cron.d/") {
					t.Errorf("A.4 ran rm on cron path: %+v", cmd)
				}
			}
		}
	}
}

// =============================================================================
// 4B-3-csf — Test #8: A.5 starts only csf.service.
// =============================================================================

func TestCSFMutate_4B3csf_A5_StartsOnlyCSFService(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
	})
	_ = mutateToCSFTarget(context.Background(), dep)

	startCount := 0
	for _, cmd := range mock.Commands {
		if cmd.Name == "systemctl" && len(cmd.Args) >= 2 && cmd.Args[0] == "start" {
			startCount++
			if cmd.Args[1] != csfServiceUnit {
				t.Errorf("A.5 started unauthorized service: %+v", cmd)
			}
		}
	}
	if startCount != 1 {
		t.Errorf("ServiceStart count = %d; want exactly 1 (csf.service)", startCount)
	}
}

func TestCSFMutate_4B3csf_A5_PostStartInactive_ReturnsTypedError(t *testing.T) {
	// ServiceStart returns nil but ServiceActive remains false. The
	// plain MockExecutor can't simulate this; flakyCSFActiveExec
	// wraps it and overrides ServiceActive(csf.service).
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
	})
	dep.exec = &flakyCSFActiveExec{MockExecutor: mock, csfActive: false}

	err := mutateToCSFTarget(context.Background(), dep)
	if !errors.Is(err, ErrCSFRestorePostStartInactive) {
		t.Errorf("err = %v; want ErrCSFRestorePostStartInactive", err)
	}
}

// =============================================================================
// 4B-3-csf — Test #9: A.6 stops only nftband.service, only after CSF active.
// =============================================================================

func TestCSFMutate_4B3csf_A6_StopsOnlyNftband_AfterCSFStarts(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
		nftbandActive:      true,
	})
	_ = mutateToCSFTarget(context.Background(), dep)

	// Find positions of csf-start and nftband-stop in the recorded
	// command sequence; assert csf-start precedes nftband-stop.
	csfStartIdx := -1
	nftbandStopIdx := -1
	for i, cmd := range mock.Commands {
		if cmd.Name == "systemctl" && len(cmd.Args) >= 2 {
			if cmd.Args[0] == "start" && cmd.Args[1] == csfServiceUnit {
				csfStartIdx = i
			}
			if cmd.Args[0] == "stop" && cmd.Args[1] == nftbandUnit {
				nftbandStopIdx = i
			}
		}
	}
	if csfStartIdx < 0 {
		t.Fatalf("csf.service start not recorded")
	}
	if nftbandStopIdx < 0 {
		t.Fatalf("nftband.service stop not recorded")
	}
	if !(csfStartIdx < nftbandStopIdx) {
		t.Errorf("csf-start (idx %d) must precede nftband-stop (idx %d)", csfStartIdx, nftbandStopIdx)
	}

	// And no other ServiceStop calls.
	stopCount := 0
	for _, cmd := range mock.Commands {
		if cmd.Name == "systemctl" && len(cmd.Args) >= 2 && cmd.Args[0] == "stop" {
			stopCount++
			if cmd.Args[1] != nftbandUnit {
				t.Errorf("A.6 stopped unauthorized service: %+v", cmd)
			}
		}
	}
	if stopCount != 1 {
		t.Errorf("ServiceStop count = %d; want exactly 1 (nftband.service)", stopCount)
	}
}

func TestCSFMutate_4B3csf_A6_IdempotentSkipWhenNftbandInactive(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
		nftbandActive:      false, // already stopped
	})
	_ = mutateToCSFTarget(context.Background(), dep)
	for _, cmd := range mock.Commands {
		if cmd.Name == "systemctl" && len(cmd.Args) >= 2 && cmd.Args[0] == "stop" {
			t.Errorf("A.6 ran stop when nftband already inactive: %+v", cmd)
		}
	}
}

// =============================================================================
// 4B-3-csf — Test #10: A.7 refuses when predicate unavailable.
// =============================================================================

func TestCSFMutate_4B3csf_A7_PredicateUnwired_RefusesNftRelease(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
		nftbanTablesExist:  true,
		safetyNetSafeFn:    nil, // unwired (4B-3 default)
	})
	err := mutateToCSFTarget(context.Background(), dep)
	if !errors.Is(err, ErrCSFRestoreNftReleaseUnsafe) {
		t.Errorf("err = %v; want ErrCSFRestoreNftReleaseUnsafe", err)
	}
	// nftban tables MUST still be present.
	if !mock.NftTables["ip:nftban"] {
		t.Errorf("A.7 deleted ip:nftban despite predicate unwired (CRITICAL violation)")
	}
	if !mock.NftTables["ip6:nftban"] {
		t.Errorf("A.7 deleted ip6:nftban despite predicate unwired (CRITICAL violation)")
	}
}

func TestCSFMutate_4B3csf_A7_PredicateFalse_RefusesNftRelease(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
		nftbanTablesExist:  true,
		safetyNetSafeFn:    alwaysUnsafe,
	})
	err := mutateToCSFTarget(context.Background(), dep)
	if !errors.Is(err, ErrCSFRestoreNftReleaseUnsafe) {
		t.Errorf("err = %v; want ErrCSFRestoreNftReleaseUnsafe", err)
	}
	if !mock.NftTables["ip:nftban"] || !mock.NftTables["ip6:nftban"] {
		t.Errorf("A.7 deleted nftban tables despite predicate=false")
	}
}

func TestCSFMutate_4B3csf_A7_PredicateError_RefusesNftRelease(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
		nftbanTablesExist:  true,
		safetyNetSafeFn: func(_ context.Context) (bool, error) {
			return false, errors.New("simulated predicate error")
		},
	})
	err := mutateToCSFTarget(context.Background(), dep)
	if !errors.Is(err, ErrCSFRestoreNftReleaseUnsafe) {
		t.Errorf("err = %v; want ErrCSFRestoreNftReleaseUnsafe", err)
	}
	if !mock.NftTables["ip:nftban"] || !mock.NftTables["ip6:nftban"] {
		t.Errorf("A.7 deleted nftban tables despite predicate error")
	}
}

// =============================================================================
// 4B-3-csf — Test #11: A.7 deletes ONLY ip:nftban + ip6:nftban when
//                    predicate is available and true.
// =============================================================================

func TestCSFMutate_4B3csf_A7_PredicateTrue_DeletesOnlyNftbanTables(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
		nftbanTablesExist:  true,
		safetyNetSafeFn:    alwaysSafe,
	})
	// Pre-seed an unrelated table that MUST be untouched.
	mock.NftTables["inet:nftban_install_emergency"] = true
	mock.NftTables["ip:filter"] = true

	err := mutateToCSFTarget(context.Background(), dep)
	if err != nil {
		t.Fatalf("happy path err = %v; want nil", err)
	}

	// nftban tables: gone.
	if mock.NftTables["ip:nftban"] {
		t.Errorf("A.7 did not delete ip:nftban")
	}
	if mock.NftTables["ip6:nftban"] {
		t.Errorf("A.7 did not delete ip6:nftban")
	}

	// Other tables: intact.
	if !mock.NftTables["inet:nftban_install_emergency"] {
		t.Errorf("A.7 incorrectly deleted emergency safety-net table")
	}
	if !mock.NftTables["ip:filter"] {
		t.Errorf("A.7 incorrectly deleted unrelated ip:filter table")
	}
}

// =============================================================================
// 4B-3-csf — Test #12: no nftban-table deletion before CSF is active.
//
// Forces a failure earlier in the §32 sequence (A.3 binary rename)
// and asserts the nftban tables are still present. This proves that
// no NftDeleteTable call exists upstream of step 5 (ServiceActive
// verification) — failing earlier than A.5 leaves the kernel
// authority untouched.
// =============================================================================

func TestCSFMutate_4B3csf_NoEarlyNftbanDeletion_OnPreA5Failure(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
		nftbanTablesExist:  true,
		mvBinaryFailsExit:  1,           // A.3 fails — function returns before A.5
		safetyNetSafeFn:    alwaysSafe, // would permit A.7 if reached
	})
	err := mutateToCSFTarget(context.Background(), dep)
	if !errors.Is(err, ErrCSFRestoreBinaryRestoreFailed) {
		t.Fatalf("err = %v; want ErrCSFRestoreBinaryRestoreFailed", err)
	}
	if !mock.NftTables["ip:nftban"] || !mock.NftTables["ip6:nftban"] {
		t.Errorf("nftban tables deleted on pre-A.5 failure (CRITICAL §32 ordering violation)")
	}
	// Also confirm A.7's command path was not exercised: no systemctl
	// start csf was recorded (start fires AFTER the failed A.3).
	if mock.CommandCalled("systemctl", "start", csfServiceUnit) {
		t.Errorf("ServiceStart was called despite A.3 failure")
	}
}

// =============================================================================
// 4B-3-csf — Test #13: no DirectAdmin custombuild commands.
// =============================================================================

func TestCSFMutate_4B3csf_NoDirectAdminCustombuild(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		panelDirectAdmin:   true,
		csfDisabledPresent: true,
		safetyNetSafeFn:    alwaysSafe,
		nftbanTablesExist:  true,
	})
	_ = mutateToCSFTarget(context.Background(), dep)
	for _, cmd := range mock.Commands {
		// /usr/local/directadmin/custombuild/build is the install-time
		// disarm path. Restore must NOT invoke it.
		if strings.Contains(cmd.Name, "custombuild") {
			t.Errorf("restore csf invoked custombuild: %+v", cmd)
		}
		if strings.Contains(cmd.Name, "directadmin") {
			t.Errorf("restore csf invoked a directadmin path: %+v", cmd)
		}
		// `build set csf …` argument pattern.
		if len(cmd.Args) >= 3 && cmd.Args[0] == "set" && cmd.Args[1] == "csf" {
			t.Errorf("restore csf ran a `build set csf …` style command: %+v", cmd)
		}
	}
}

// =============================================================================
// 4B-3-csf — Test #14: no Probe/Classify/DetectPanel/Decide calls.
// =============================================================================

func TestCSFMutate_4B3csf_NoLiveReDetection_FileScan(t *testing.T) {
	body, err := os.ReadFile("restore_deps_csf.go")
	if err != nil {
		t.Fatalf("read restore_deps_csf.go: %v", err)
	}
	src := string(body)
	forbidden := []string{
		"uninstall.Probe(",
		"uninstall.Classify(",
		"detect.DetectPanel(",
		"restore.Decide(",
		"restore.PlanFromDecision(",
		// History-write surface.
		"writeHistory(",
		"update-history",
	}
	for _, pat := range forbidden {
		if strings.Contains(src, pat) {
			t.Errorf("restore_deps_csf.go references forbidden re-detection pattern %q", pat)
		}
	}
}

// =============================================================================
// 4B-3-csf — Test #15: no direct os/exec, os.Rename, os.Remove.
// =============================================================================

func TestCSFMutate_4B3csf_NoDirectOSCalls_FileScan(t *testing.T) {
	body, err := os.ReadFile("restore_deps_csf.go")
	if err != nil {
		t.Fatalf("read restore_deps_csf.go: %v", err)
	}
	src := string(body)
	forbidden := []string{
		"os/exec",
		"exec.Command(",
		"os.WriteFile",
		"os.Create",
		"os.Remove(",
		"os.RemoveAll",
		"os.Rename",
		"syscall.",
	}
	for _, pat := range forbidden {
		if strings.Contains(src, pat) {
			t.Errorf("restore_deps_csf.go references forbidden direct-OS pattern %q", pat)
		}
	}
}

// =============================================================================
// 4B-3-csf — Test #16: command trace — zero out-of-target mutation on
//                    the happy path.
// =============================================================================

func TestCSFMutate_4B3csf_HappyPath_NoOutOfTargetMutation(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
		csfMasked:          true,
		nftbandActive:      true,
		nftbanTablesExist:  true,
		safetyNetSafeFn:    alwaysSafe,
	})
	if err := mutateToCSFTarget(context.Background(), dep); err != nil {
		t.Fatalf("happy path err = %v", err)
	}

	// Allowed command shapes (each entry: name + arg-prefix).
	type allow struct {
		name string
		args []string
	}
	allowed := []allow{
		{"systemctl", []string{"is-enabled", csfServiceUnit}},
		{"systemctl", []string{"unmask", csfServiceUnit}},
		{"systemctl", []string{"enable", csfServiceUnit}},
		{"systemctl", []string{"start", csfServiceUnit}},
		{"systemctl", []string{"stop", nftbandUnit}},
		// PR-26-code-B: typed Rename records as "rename" (not "mv").
		{"rename", []string{csfBinaryDisabled, csfBinary}},
	}
	matchAllowed := func(cmd executor.RecordedCommand) bool {
		for _, a := range allowed {
			if cmd.Name != a.name {
				continue
			}
			if len(cmd.Args) != len(a.args) {
				continue
			}
			ok := true
			for i, want := range a.args {
				if cmd.Args[i] != want {
					ok = false
					break
				}
			}
			if ok {
				return true
			}
		}
		return false
	}

	for _, cmd := range mock.Commands {
		if !matchAllowed(cmd) {
			t.Errorf("happy path emitted out-of-target command: %+v", cmd)
		}
	}

	// File writes: zero (cron soft-skip; binary rename via mv).
	if len(mock.WrittenFiles) != 0 {
		t.Errorf("happy path wrote files: %v (expected 0)", mock.WrittenFiles)
	}
}

// =============================================================================
// 4B-3-csf — Test #17: consumed mutation fields have no stale lint-suppression annotations.
// =============================================================================

func TestCSFMutate_4B3csf_NoNolintUnusedOnMutationFields(t *testing.T) {
	body, err := os.ReadFile("restore_deps.go")
	if err != nil {
		t.Fatalf("read restore_deps.go: %v", err)
	}
	src := string(body)

	// Find the productionMutationDep struct block.
	startIdx := strings.Index(src, "type productionMutationDep struct")
	if startIdx < 0 {
		t.Fatalf("productionMutationDep struct not found")
	}
	// End at the closing '}' of the struct.
	endIdx := strings.Index(src[startIdx:], "\n}\n")
	if endIdx < 0 {
		t.Fatalf("productionMutationDep struct close not found")
	}
	block := src[startIdx : startIdx+endIdx]
	if strings.Contains(block, "nolint:unused") {
		t.Errorf("productionMutationDep struct retains a nolint:unused annotation; 4B-3-csf consumes all fields:\n%s", block)
	}
}

// =============================================================================
// 4B-3-csf — Test #18 (flipped by 4B-4): predicate is now WIRED in the
//                    production factory. Before 4B-4 this test asserted
//                    safetyNetRemovalSafeFn==nil (PR-25 non-shipping
//                    pin); 4B-4 inverted the assertion to safetyNet
//                    RemovalSafeFn!=nil. Test name kept stable so
//                    auditor history can grep the flip.
// =============================================================================

func TestCSFMutate_4B3csf_PR25NonShipping_PredicateUnwiredByDefault(t *testing.T) {
	deps := newProductionRestoreDepsWithEvidence(nil, nil, nil, detect.PanelNone, "csf")
	mut, ok := deps.Mutation.(*productionMutationDep)
	if !ok {
		t.Fatalf("Mutation is not *productionMutationDep")
	}
	if mut.safetyNetRemovalSafeFn == nil {
		t.Errorf("4B-4 production factory did NOT wire safetyNetRemovalSafeFn — A.7 would refuse universally")
	}
}

// =============================================================================
// 4B-3-csf — extra: ordering pin across a representative happy run.
// §32 step order (visible in mock.Commands): is-enabled → unmask → enable
// → mv → start → is-enabled (post-start verify uses ServiceActive, not
// is-enabled) → stop. Pin the relative order of the externally-visible
// commands that ARE recorded.
// =============================================================================

func TestCSFMutate_4B3csf_OrderingPin(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
		csfMasked:          true,
		nftbandActive:      true,
		nftbanTablesExist:  true,
		safetyNetSafeFn:    alwaysSafe,
	})
	if err := mutateToCSFTarget(context.Background(), dep); err != nil {
		t.Fatalf("happy path err = %v", err)
	}

	// Build an ordered name+verb list of mutating-or-querying calls.
	type sig struct {
		name string
		verb string // first arg, or "" if none
	}
	var seen []sig
	for _, cmd := range mock.Commands {
		v := ""
		if len(cmd.Args) > 0 {
			v = cmd.Args[0]
		}
		seen = append(seen, sig{cmd.Name, v})
	}

	// Build the list of expected signatures (relative order).
	// PR-26-code-B: A.3 records "rename" (typed Rename), not "mv".
	want := []sig{
		{"systemctl", "is-enabled"},   // §32 step 1 / A.1 gate
		{"systemctl", "unmask"},       // A.1
		{"systemctl", "enable"},       // A.2
		{"rename", csfBinaryDisabled}, // A.3
		{"systemctl", "start"},        // A.5
		{"systemctl", "stop"},         // A.6
	}

	// Verify `seen` contains `want` as a subsequence.
	wi := 0
	for _, s := range seen {
		if wi < len(want) && s == want[wi] {
			wi++
		}
	}
	if wi != len(want) {
		t.Errorf("ordering subsequence mismatch — at %d of %d. seen=%+v want=%+v", wi, len(want), seen, want)
	}
}

// =============================================================================
// =============================================================================
// PR-26-code-B — typed executor migration tests
// =============================================================================
// =============================================================================

// =============================================================================
// PR-26-code-B test #1: A.1 calls typed exec.ServiceUnmask only on
// csf.service — never on any other unit.
// =============================================================================

func TestCSFMutate_PR26B_A1_ServiceUnmaskOnlyCSFService(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
		csfMasked:          true,
	})
	_ = mutateToCSFTarget(context.Background(), dep)

	unmaskCount := 0
	for _, cmd := range mock.Commands {
		if cmd.Name == "systemctl" && len(cmd.Args) >= 2 && cmd.Args[0] == "unmask" {
			unmaskCount++
			if cmd.Args[1] != csfServiceUnit {
				t.Errorf("ServiceUnmask called on unauthorized unit: %+v", cmd)
			}
		}
	}
	if unmaskCount != 1 {
		t.Errorf("ServiceUnmask call count = %d; want exactly 1 (csf.service)", unmaskCount)
	}
}

// =============================================================================
// PR-26-code-B test #2: A.3 calls typed exec.Rename only with the
// csf.disabled → csf path pair.
// =============================================================================

func TestCSFMutate_PR26B_A3_RenameOnlyCSFBinaryRestore(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
	})
	_ = mutateToCSFTarget(context.Background(), dep)

	renameCount := 0
	for _, cmd := range mock.Commands {
		if cmd.Name == "rename" {
			renameCount++
			if len(cmd.Args) != 2 || cmd.Args[0] != csfBinaryDisabled || cmd.Args[1] != csfBinary {
				t.Errorf("Rename called outside A.3 scope: %+v", cmd)
			}
		}
	}
	if renameCount != 1 {
		t.Errorf("Rename call count = %d; want exactly 1 (csf.disabled -> csf)", renameCount)
	}
}

// =============================================================================
// PR-26-code-B test #3: no raw Run("systemctl", "unmask", …) remains
// in the CSF restore path. File-scan against restore_deps_csf.go.
// =============================================================================

func TestCSFMutate_PR26B_NoRawSystemctlUnmaskRun_FileScan(t *testing.T) {
	body, err := os.ReadFile("restore_deps_csf.go")
	if err != nil {
		t.Fatalf("read restore_deps_csf.go: %v", err)
	}
	src := string(body)

	// Exclude doc-comment lines (production-code-only scan per §46.1).
	var prodLines []string
	for _, line := range strings.Split(src, "\n") {
		trimmed := strings.TrimLeft(line, " \t")
		if strings.HasPrefix(trimmed, "//") {
			continue
		}
		prodLines = append(prodLines, line)
	}
	prodSrc := strings.Join(prodLines, "\n")

	if strings.Contains(prodSrc, `Run("systemctl", "unmask"`) {
		t.Errorf("restore_deps_csf.go still contains a raw Run(\"systemctl\", \"unmask\", …) call — PR-26-code-B requires the typed exec.ServiceUnmask")
	}
}

// =============================================================================
// PR-26-code-B test #4: no raw Run("mv", …) remains in the CSF restore
// path. File-scan against restore_deps_csf.go.
// =============================================================================

func TestCSFMutate_PR26B_NoRawMvRun_FileScan(t *testing.T) {
	body, err := os.ReadFile("restore_deps_csf.go")
	if err != nil {
		t.Fatalf("read restore_deps_csf.go: %v", err)
	}
	src := string(body)

	var prodLines []string
	for _, line := range strings.Split(src, "\n") {
		trimmed := strings.TrimLeft(line, " \t")
		if strings.HasPrefix(trimmed, "//") {
			continue
		}
		prodLines = append(prodLines, line)
	}
	prodSrc := strings.Join(prodLines, "\n")

	if strings.Contains(prodSrc, `Run("mv"`) {
		t.Errorf("restore_deps_csf.go still contains a raw Run(\"mv\", …) call — PR-26-code-B requires the typed exec.Rename")
	}
}

// =============================================================================
// PR-26-code-B test #5: A.1 unmask failure still surfaces the same
// typed CSF restore error (ErrCSFRestoreUnmaskFailed). Migration must
// not change the error contract.
// =============================================================================

func TestCSFMutate_PR26B_A1_UnmaskFailure_TypedErrorPreserved(t *testing.T) {
	dep, _ := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
		csfMasked:          true,
		unmaskFailsExit:    1, // injects ServiceUnmaskErr via fixture
	})
	err := mutateToCSFTarget(context.Background(), dep)
	if !errors.Is(err, ErrCSFRestoreUnmaskFailed) {
		t.Errorf("err = %v; want ErrCSFRestoreUnmaskFailed (PR-26-code-B migration must preserve the error contract)", err)
	}
}

// =============================================================================
// PR-26-code-B test #6: A.3 rename failure still surfaces the same
// typed CSF restore error (ErrCSFRestoreBinaryRestoreFailed).
// =============================================================================

func TestCSFMutate_PR26B_A3_RenameFailure_TypedErrorPreserved(t *testing.T) {
	dep, _ := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
		mvBinaryFailsExit:  1, // injects RenameErr via fixture
	})
	err := mutateToCSFTarget(context.Background(), dep)
	if !errors.Is(err, ErrCSFRestoreBinaryRestoreFailed) {
		t.Errorf("err = %v; want ErrCSFRestoreBinaryRestoreFailed (PR-26-code-B migration must preserve the error contract)", err)
	}
}

// =============================================================================
// =============================================================================
// PR-26-code-C2 — A.4 manifest-restore tests
// =============================================================================
// =============================================================================

// seedCronManifest writes a sha256-valid manifest + matching backup
// files into the mock so the A.4 reader can succeed end-to-end.
func seedCronManifest(t *testing.T, mock *executor.MockExecutor, files map[string]string) {
	t.Helper()
	entries := make([]switchop.CronManifestEntry, 0, len(files))
	for path, content := range files {
		var name string
		switch path {
		case switchop.CronCSFSrcPath:
			name = "csf-cron"
		case switchop.CronLFDSrcPath:
			name = "lfd-cron"
		default:
			t.Fatalf("seedCronManifest: unauthorized path %q", path)
		}
		mock.Files[switchop.CronManifestDir+"/"+name] = []byte(content)
		entries = append(entries, switchop.CronManifestEntry{
			Path:       path,
			BackupName: name,
			SHA256:     switchop.ComputeCronBackupSHA256([]byte(content)),
			Mode:       0644,
			UID:        0,
			GID:        0,
			Size:       int64(len(content)),
		})
	}
	manifest := switchop.CronManifest{
		SchemaVersion: switchop.CronManifestSchemaVersion,
		Files:         entries,
	}
	body, _ := json.MarshalIndent(manifest, "", "  ")
	mock.Files[switchop.CronManifestFile] = body
}

// =============================================================================
// PR-26-code-C2 test #1: manifest absent → soft-skip; targets stay absent.
// (Mirrors the existing A4_SoftSkip_ZeroFileWrites under code-C2's
// new code path — manifest absent is the pre-PR-26 host case.)
// =============================================================================

func TestCSFMutate_PR26C2_A4_ManifestAbsent_SoftSkip(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
	})
	_ = mutateToCSFTarget(context.Background(), dep)

	for path := range mock.WrittenFiles {
		if strings.HasPrefix(path, "/etc/cron.d/") {
			t.Errorf("A.4 wrote cron file %q on manifest-absent host; expected soft-skip", path)
		}
	}
}

// =============================================================================
// PR-26-code-C2 test #2: manifest present + integrity ok + targets
// absent → A.4 restores both files via WriteFileAtomic + Chown.
// =============================================================================

func TestCSFMutate_PR26C2_A4_HappyPath_RestoresBothFiles(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
	})
	csfBody := "0 0 * * * root /usr/sbin/csf -r\n"
	lfdBody := "0 0 * * * root /usr/sbin/csf --lfd restart\n"
	seedCronManifest(t, mock, map[string]string{
		switchop.CronCSFSrcPath: csfBody,
		switchop.CronLFDSrcPath: lfdBody,
	})

	_ = mutateToCSFTarget(context.Background(), dep)

	if got := mock.WrittenFiles[switchop.CronCSFSrcPath]; string(got) != csfBody {
		t.Errorf("A.4 did not restore %s with the manifest content (got %q)",
			switchop.CronCSFSrcPath, string(got))
	}
	if got := mock.WrittenFiles[switchop.CronLFDSrcPath]; string(got) != lfdBody {
		t.Errorf("A.4 did not restore %s with the manifest content (got %q)",
			switchop.CronLFDSrcPath, string(got))
	}
}

// =============================================================================
// PR-26-code-C2 test #3: manifest present, target already exists
// (operator-content collision) → HARD REFUSE before A.5 with the
// typed ErrCSFRestoreCronTargetExists sentinel.
// =============================================================================

func TestCSFMutate_PR26C2_A4_TargetExists_HardRefuses_StopsBeforeA5(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
	})
	seedCronManifest(t, mock, map[string]string{
		switchop.CronCSFSrcPath: "manifest body\n",
	})
	// Operator already created a different version of the cron file.
	mock.Files[switchop.CronCSFSrcPath] = []byte("operator content\n")

	err := mutateToCSFTarget(context.Background(), dep)
	if !errors.Is(err, ErrCSFRestoreCronTargetExists) {
		t.Errorf("err = %v; want ErrCSFRestoreCronTargetExists (hard refusal on operator-content collision)", err)
	}
	// A.4 must NOT overwrite operator content — and the function
	// must NOT have proceeded to A.5.
	if got, ok := mock.WrittenFiles[switchop.CronCSFSrcPath]; ok {
		if string(got) == "manifest body\n" {
			t.Errorf("A.4 overwrote operator content with manifest content")
		}
	}
	if mock.CommandCalled("systemctl", "start", csfServiceUnit) {
		t.Errorf("A.4 target-exists collision did NOT stop A.5 — auditor requires hard refusal before A.5")
	}
}

// =============================================================================
// PR-26-code-C2 test #4: manifest sha256 mismatch → HARD REFUSE
// before A.5 with ErrCSFRestoreCronManifestCorrupt.
// =============================================================================

func TestCSFMutate_PR26C2_A4_SHA256Mismatch_HardRefuses_StopsBeforeA5(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
	})
	// Seed a valid-looking manifest but tamper with the backup file
	// content so the sha256 no longer matches.
	seedCronManifest(t, mock, map[string]string{
		switchop.CronCSFSrcPath: "original\n",
	})
	mock.Files[switchop.CronManifestDir+"/csf-cron"] = []byte("tampered\n")

	err := mutateToCSFTarget(context.Background(), dep)
	if !errors.Is(err, ErrCSFRestoreCronManifestCorrupt) {
		t.Errorf("err = %v; want ErrCSFRestoreCronManifestCorrupt (hard refusal on sha256 mismatch)", err)
	}
	// A.4 did NOT restore the tampered cron file.
	if _, ok := mock.WrittenFiles[switchop.CronCSFSrcPath]; ok {
		t.Errorf("A.4 wrote cron file despite sha256 mismatch")
	}
	// CRITICAL: A.5 must NOT have run. Restore evidence on disk is
	// untrusted; starting csf would weaken the evidence chain.
	if mock.CommandCalled("systemctl", "start", csfServiceUnit) {
		t.Errorf("A.4 sha256 mismatch did NOT stop A.5 — auditor requires hard refusal before A.5")
	}
}

// =============================================================================
// PR-26-code-C2 test #5: manifest schema mismatch → HARD REFUSE
// before A.5 with ErrCSFRestoreCronManifestCorrupt.
// =============================================================================

func TestCSFMutate_PR26C2_A4_SchemaMismatch_HardRefuses_StopsBeforeA5(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
	})
	body, _ := json.Marshal(switchop.CronManifest{
		SchemaVersion: "0.0.1-old",
		Files:         []switchop.CronManifestEntry{},
	})
	mock.Files[switchop.CronManifestFile] = body

	err := mutateToCSFTarget(context.Background(), dep)
	if !errors.Is(err, ErrCSFRestoreCronManifestCorrupt) {
		t.Errorf("err = %v; want ErrCSFRestoreCronManifestCorrupt (hard refusal on schema mismatch)", err)
	}
	for path := range mock.WrittenFiles {
		if strings.HasPrefix(path, "/etc/cron.d/") {
			t.Errorf("A.4 wrote cron file %q on schema-mismatch manifest", path)
		}
	}
	if mock.CommandCalled("systemctl", "start", csfServiceUnit) {
		t.Errorf("A.4 schema mismatch did NOT stop A.5 — auditor requires hard refusal before A.5")
	}
}

// =============================================================================
// PR-26-code-C2 test #6: A.4 only writes to the two §42.2-locked
// paths — no broad /etc/cron.d/* writes.
// =============================================================================

func TestCSFMutate_PR26C2_A4_OnlyAuthorizedTargetPaths(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
	})
	seedCronManifest(t, mock, map[string]string{
		switchop.CronCSFSrcPath: "csf\n",
		switchop.CronLFDSrcPath: "lfd\n",
	})

	_ = mutateToCSFTarget(context.Background(), dep)

	for path := range mock.WrittenFiles {
		if strings.HasPrefix(path, "/etc/cron.d/") {
			if path != switchop.CronCSFSrcPath && path != switchop.CronLFDSrcPath {
				t.Errorf("A.4 wrote unauthorized cron path %q", path)
			}
		}
	}
}

// =============================================================================
// PR-26-code-C2 test #7: ErrCSFRestoreCronManifestCorrupt is exported
// for assertion via errors.Is. (Compile-time + symbol pin.)
// =============================================================================

func TestCSFMutate_PR26C2_TypedSentinelExported(t *testing.T) {
	if ErrCSFRestoreCronManifestCorrupt == nil {
		t.Errorf("ErrCSFRestoreCronManifestCorrupt is nil — sentinel must be exported")
	}
	if !strings.Contains(ErrCSFRestoreCronManifestCorrupt.Error(), "manifest") {
		t.Errorf("ErrCSFRestoreCronManifestCorrupt message does not mention 'manifest': %q",
			ErrCSFRestoreCronManifestCorrupt.Error())
	}
}

// =============================================================================
// PR-26-code-C2 test #8: A.4 manifest entry with unknown path is
// HARD REFUSED before A.5 with ErrCSFRestoreCronManifestCorrupt.
// =============================================================================

func TestCSFMutate_PR26C2_A4_UnknownEntryPath_HardRefuses_StopsBeforeA5(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
	})
	body, _ := json.Marshal(switchop.CronManifest{
		SchemaVersion: switchop.CronManifestSchemaVersion,
		Files: []switchop.CronManifestEntry{
			{Path: "/etc/cron.d/some-other-cron", BackupName: "x", SHA256: "y", Size: 1},
		},
	})
	mock.Files[switchop.CronManifestFile] = body

	err := mutateToCSFTarget(context.Background(), dep)
	if !errors.Is(err, ErrCSFRestoreCronManifestCorrupt) {
		t.Errorf("err = %v; want ErrCSFRestoreCronManifestCorrupt (hard refusal on unknown-entry path)", err)
	}
	for path := range mock.WrittenFiles {
		if strings.HasPrefix(path, "/etc/cron.d/") {
			t.Errorf("A.4 wrote cron file %q despite unknown-entry manifest", path)
		}
	}
	if mock.CommandCalled("systemctl", "start", csfServiceUnit) {
		t.Errorf("A.4 unknown-entry did NOT stop A.5 — auditor requires hard refusal before A.5")
	}
}

// =============================================================================
// PR-26-code-C2 test #9: HappyPath_RestoresBothFiles must continue to
// A.5 after a clean restore. (Companion to the hard-refusal tests
// above — proves absent + clean keep the original "continue to A.5"
// semantics, only the corrupt branches stop.)
// =============================================================================

func TestCSFMutate_PR26C2_A4_HappyPath_ContinuesToA5(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
	})
	seedCronManifest(t, mock, map[string]string{
		switchop.CronCSFSrcPath: "csf body\n",
		switchop.CronLFDSrcPath: "lfd body\n",
	})

	_ = mutateToCSFTarget(context.Background(), dep)

	if !mock.CommandCalled("systemctl", "start", csfServiceUnit) {
		t.Errorf("A.4 clean restore did not continue to A.5 — happy path must not stop")
	}
}

// =============================================================================
// PR-26-code-C2 test #10: ManifestAbsent must continue to A.5 (the
// migration soft-skip path is the ONLY non-clean branch that
// continues — corrupt branches stop).
// =============================================================================

func TestCSFMutate_PR26C2_A4_ManifestAbsent_ContinuesToA5(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
	})
	// No manifest seeded — pre-PR-26 host case.

	_ = mutateToCSFTarget(context.Background(), dep)

	if !mock.CommandCalled("systemctl", "start", csfServiceUnit) {
		t.Errorf("A.4 absent-manifest soft-skip did NOT continue to A.5 — migration semantics broken")
	}
}

// =============================================================================
// PR-26-code-C2 test #11: parse-failure manifest (not valid JSON) →
// HARD REFUSE before A.5 with ErrCSFRestoreCronManifestCorrupt.
// =============================================================================

func TestCSFMutate_PR26C2_A4_ParseFailure_HardRefuses_StopsBeforeA5(t *testing.T) {
	dep, mock := buildCSFFixture(t, csfTestFixture{
		priorRecCSF:        true,
		priorRecActive:     true,
		csfDisabledPresent: true,
	})
	mock.Files[switchop.CronManifestFile] = []byte("{{{ not json")

	err := mutateToCSFTarget(context.Background(), dep)
	if !errors.Is(err, ErrCSFRestoreCronManifestCorrupt) {
		t.Errorf("err = %v; want ErrCSFRestoreCronManifestCorrupt (hard refusal on parse failure)", err)
	}
	if mock.CommandCalled("systemctl", "start", csfServiceUnit) {
		t.Errorf("A.4 parse-failure did NOT stop A.5 — auditor requires hard refusal before A.5")
	}
}

// =============================================================================
// PR-26-code-B test #7: removed helper symbols are gone. Compile-time
// check (the symbols would not parse if referenced). The file-scan
// pin documents §43.2 lock visibly.
// =============================================================================

func TestCSFMutate_PR26B_RemovedHelpersGone_FileScan(t *testing.T) {
	body, err := os.ReadFile("restore_deps_csf.go")
	if err != nil {
		t.Fatalf("read restore_deps_csf.go: %v", err)
	}
	src := string(body)

	var prodLines []string
	for _, line := range strings.Split(src, "\n") {
		trimmed := strings.TrimLeft(line, " \t")
		if strings.HasPrefix(trimmed, "//") {
			continue
		}
		prodLines = append(prodLines, line)
	}
	prodSrc := strings.Join(prodLines, "\n")

	// Function definitions, not just any identifier mention. Use the
	// "func name(" pattern to avoid false-matching the removal-marker
	// doc comment.
	for _, sym := range []string{"func unmaskCSFService(", "func renameAtomicViaExec("} {
		if strings.Contains(prodSrc, sym) {
			t.Errorf("restore_deps_csf.go still defines %q — §43.2 lock requires removal in favor of typed executor methods", sym)
		}
	}
}
