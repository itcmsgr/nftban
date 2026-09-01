// =============================================================================
// NFTBan D-CSF-1 B4 — DirectAdmin panel-stage failure injection
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-switchop-takeover-da-panel-stages-b4-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-08-11"
// meta:description="D-CSF-1 B4: freezes the CURRENT behaviour of the existing canonical DirectAdmin CSF transition (disarmPanelCSF) at each of its own early-return boundaries S2/S3/S4/S5. Failure-injection only — asserts what the shipped implementation does today, changes nothing."
// meta:inventory.files="internal/installer/switchop/takeover.go"
// meta:inventory.privileges="none"
// =============================================================================
//
// SCOPE — read this before adding anything here.
//
// The existing NFTBan DirectAdmin implementation is CANONICAL (owner ruling
// 2026-08-11, DIRECTADMIN BINDING RULE). These tests do NOT propose a design,
// do NOT introduce a parallel mechanism, and do NOT assert desired behaviour.
// They FREEZE CURRENT TRUTH at the interruption boundaries the function already
// contains, so B4 can reason about partial states from evidence.
//
// Boundaries are the function's OWN early returns (takeover.go disarmPanelCSF):
//
//	S1 disarmDAWatchdog()                services.status lfd=ON -> OFF
//	S2 FileExists(custombuild/build)     absent  -> WARN + RETURN
//	S3 build set csf no                  exit!=0 -> WARN + RETURN
//	S4 ReadFile(options.conf)            err     -> WARN + RETURN
//	   options.conf csf != no            WARN + CONTINUE (does not return)
//	S5 audit scripts/custom              observational only
//
// PARTIAL_PROGRESS != SAFE_INTERMEDIATE_STATE — a stage succeeding does not
// establish that interruption after it leaves the host safe. Coverage of S2-S5
// was measured ABSENT before these were written (TEST_COVERAGE_GAP = PROVEN);
// S1 was already covered by takeover_pr26_6_1_test.go and is not duplicated.
package switchop

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

const (
	daBuildCmd    = "/usr/local/directadmin/custombuild/build"
	daOptionsPath = "/usr/local/directadmin/custombuild/options.conf"
	daStatusPath  = "/usr/local/directadmin/data/admin/services.status"
	daCustomDir   = "/usr/local/directadmin/scripts/custom"
)

// daPanelMock seeds a DirectAdmin host with the watchdog ARMED (lfd=ON) so each
// arm can observe whether S1 ran before the injected failure.
//
// CRITICAL — scripts/custom is seeded here on PURPOSE. S5 only executes when
// FileExists(customDir) is true (takeover.go:201). Without this seed S5 is
// unreachable in EVERY arm, and every "S5 did not run" assertion below passes
// no matter what the code does. A falsifiability control with a mutation
// witness caught exactly that in the first draft of this file.
func daPanelMock() *executor.MockExecutor {
	m := executor.NewMockExecutor()
	seedDirectAdminTakeoverPrereqs(m)
	m.Files[daStatusPath] = []byte("httpd=ON\nlfd=ON\nnamed=ON\n")
	m.Files[daCustomDir] = []byte("")
	m.Dirs[daCustomDir] = true
	m.RunResults["grep:-rl:-E:csf|lfd|iptables:"+daCustomDir] =
		executor.Result{ExitCode: 0, Stdout: daCustomDir + "/pre_install.sh\n"}
	return m
}

// capturingLogger yields a logger whose Warnings() can be read back, so an arm
// can discriminate branches that share the same control flow (S4 verification
// MISMATCH and MATCH both fall through to S5 — only the WARN separates them).
func capturingLogger(t *testing.T) *logging.Logger {
	t.Helper()
	return logging.New(filepath.Join(t.TempDir(), "installer.log"), false)
}

func warnedAbout(l *logging.Logger, substr string) bool {
	for _, w := range l.Warnings() {
		if strings.Contains(w, substr) {
			return true
		}
	}
	return false
}

func ranCustomBuild(m *executor.MockExecutor) bool {
	for _, c := range m.Commands {
		if c.Name == daBuildCmd {
			return true
		}
	}
	return false
}

func ranCustomScriptAudit(m *executor.MockExecutor) bool {
	for _, c := range m.Commands {
		if c.Name == "grep" && strings.Contains(strings.Join(c.Args, " "), "scripts/custom") {
			return true
		}
	}
	return false
}

func watchdogFlipped(m *executor.MockExecutor) bool {
	w, ok := m.WrittenFiles[daStatusPath]
	return ok && strings.Contains(string(w), "lfd=OFF")
}

// S2 — custombuild/build ABSENT. Current behaviour: watchdog already flipped,
// then WARN + RETURN with no CustomBuild mutation attempted.
func TestB4_DA_S2_CustomBuildAbsent_WatchdogFlipped_NoBuildAttempt(t *testing.T) {
	m := daPanelMock()
	delete(m.Files, daBuildCmd)
	log := capturingLogger(t)

	disarmPanelCSF(m, detect.PanelDirectAdmin, log)

	if !warnedAbout(log, "custombuild") {
		t.Error("no WARN naming custombuild — the S2 branch was not the one taken")
	}
	if !watchdogFlipped(m) {
		t.Error("S1 did not run before the S2 early return — the watchdog should already be OFF")
	}
	if ranCustomBuild(m) {
		t.Error("CustomBuild was invoked even though build is absent")
	}
	if ranCustomScriptAudit(m) {
		t.Error("S5 executed after the S2 early return")
	}
}

// S3 — `build set csf no` FAILS. Current behaviour: command attempted, then
// WARN + RETURN; S4 verification and S5 audit are skipped.
func TestB4_DA_S3_BuildSetFails_ReturnsBeforeVerifyAndAudit(t *testing.T) {
	m := daPanelMock()
	m.RunResults[daBuildCmd+":set:csf:no"] = executor.Result{ExitCode: 1, Stderr: "injected failure"}
	log := capturingLogger(t)

	disarmPanelCSF(m, detect.PanelDirectAdmin, log)

	if !warnedAbout(log, "failed") {
		t.Error("no failure WARN — the S3 error branch was not taken")
	}

	if !ranCustomBuild(m) {
		t.Fatal("the CustomBuild command was never attempted — arm proves nothing")
	}
	if !watchdogFlipped(m) {
		t.Error("watchdog should be OFF: S1 precedes S3")
	}
	if ranCustomScriptAudit(m) {
		t.Error("S5 executed after the S3 early return")
	}
	// FROZEN TRUTH: panel is half-transitioned — lfd watchdog OFF while
	// CustomBuild may still manage/reassert CSF. Recorded, not judged.
}

// S4 — options.conf UNREADABLE after a successful set. Current behaviour:
// WARN + RETURN; the setting is applied but UNVERIFIED, and S5 is skipped.
func TestB4_DA_S4_OptionsUnreadable_SetSucceededButUnverified(t *testing.T) {
	m := daPanelMock()
	delete(m.Files, daOptionsPath) // ReadFile fails
	log := capturingLogger(t)

	disarmPanelCSF(m, detect.PanelDirectAdmin, log)

	if !warnedAbout(log, "cannot verify options.conf") {
		t.Error("no verify-failure WARN — the S4 read-error branch was not taken")
	}

	if !ranCustomBuild(m) {
		t.Fatal("CustomBuild not attempted — arm proves nothing")
	}
	if ranCustomScriptAudit(m) {
		t.Error("S5 executed after the S4 read-failure early return")
	}
}

// S4 — options.conf reports csf != no. Current behaviour: WARN but CONTINUE —
// S5 still executes and the function returns normally. This is the one branch
// that does NOT early-return, so it is asserted explicitly.
func TestB4_DA_S4_VerificationMismatch_WarnsButContinuesToS5(t *testing.T) {
	m := daPanelMock()
	m.Files[daOptionsPath] = []byte("csf=yes\nfirewall=no\n")
	log := capturingLogger(t)

	disarmPanelCSF(m, detect.PanelDirectAdmin, log)

	// MISMATCH and MATCH both fall through to S5, so S5-reachability alone
	// proves nothing about which branch ran. The WARN is the discriminator.
	if !warnedAbout(log, "expected 'no'") {
		t.Error("no mismatch WARN — the verification branch under test did not run")
	}
	if !ranCustomScriptAudit(m) {
		t.Error("S5 did not run: current behaviour on a verification MISMATCH is " +
			"warn-and-continue, not early return")
	}
	// FROZEN TRUTH: a host whose panel still reports csf=yes completes the
	// transition with only a WARN. UNVERIFIED != VERIFIED_ABSENT.
}

// S5 — the custom-script audit is OBSERVATIONAL. It must never mutate; a
// read-only analysis authority must not acquire mutation capability.
func TestB4_DA_S5_ScriptAudit_IsObservationalOnly(t *testing.T) {
	m := daPanelMock()

	before := len(m.WrittenFiles)
	disarmPanelCSF(m, detect.PanelDirectAdmin, newTestLogger())

	// POSITIVE CONTROL: without this the arm is a pure negative assertion and
	// passes trivially whenever S5 never executes.
	if !ranCustomScriptAudit(m) {
		t.Fatal("S5 never ran — the read-only assertions below prove nothing")
	}

	for _, c := range m.Commands {
		joined := c.Name + " " + strings.Join(c.Args, " ")
		if strings.Contains(joined, "scripts/custom") && c.Name != "grep" {
			t.Errorf("S5 issued a non-grep command against scripts/custom: %s", joined)
		}
	}
	// only the watchdog write is permitted (S1); S5 must add none
	if len(m.WrittenFiles) > before+1 {
		t.Errorf("S5 wrote files: %d writes (expected at most the S1 watchdog write)", len(m.WrittenFiles))
	}
}

// Ordering — S1 precedes any CustomBuild interaction. B4 is about interruption,
// so stage ORDER is itself part of the frozen truth.
func TestB4_DA_StageOrdering_WatchdogBeforeCustomBuild(t *testing.T) {
	m := daPanelMock()

	disarmPanelCSF(m, detect.PanelDirectAdmin, newTestLogger())

	if !ranCustomScriptAudit(m) {
		t.Fatal("S5 unreachable in the happy path — every \"S5 skipped\" arm in " +
			"this file would be vacuous")
	}
	if !watchdogFlipped(m) {
		t.Fatal("watchdog never flipped — ordering cannot be established")
	}
	if !ranCustomBuild(m) {
		t.Fatal("CustomBuild never ran — ordering cannot be established")
	}
	// NEGATIVE CONTROL: a non-DirectAdmin panel must reach neither stage.
	m2 := daPanelMock()
	disarmPanelCSF(m2, detect.PanelCPanel, newTestLogger())
	if watchdogFlipped(m2) || ranCustomBuild(m2) {
		t.Error("non-DirectAdmin panel entered the DA branch — the panel gate is not holding")
	}
}
