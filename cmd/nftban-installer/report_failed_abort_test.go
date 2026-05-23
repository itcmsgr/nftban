// =============================================================================
// V126.2 UX hotfix snapshot test — FAILED_AUTHORITY_ABORT report() output
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-report-failed-abort-test"
// meta:type="test"
// meta:version="1.126.2"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-23"
// meta:description="V126.2 regression guard for the FAILED_AUTHORITY_ABORT operator-friendly message: asserts report() emits the unified sudo-safe --repair recovery block (sudo + root-shell variants), Ctrl-C warning, dpkg-already-configured warning, kernel-verification commands, package-state observe-only commands, and conflict-list dynamic population. Asserts the broken legacy command forms are NOT emitted (NFTBAN_TAKEOVER=1 dpkg --configure nftban-core; generic FAILED block with --repair/firewall rebuild retry hints). Includes empty-Conflicts fallback case + ErrorLogOnly primitive unit test."
// meta:input="state.StateFile{State=StateFailedAbort, Conflicts=...} via in-memory construction; stdout+stderr+log file captured via os.Pipe redirection"
// meta:output="t.Errorf on missing INCLUDE strings, present EXCLUDE strings, or missing log-file audit trail"
// meta:depends="testing,bytes,io,os,strings,internal/installer/logging,internal/installer/state"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Scope: AUDIT_190_LIFECYCLE/V126_2_INSTALL_ABORT_UX_HOTFIX_SCOPE.md (REV 4)
// =============================================================================
package main

import (
	"bytes"
	"io"
	"os"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
)

// TestReportFailedAbortV126_2HotfixMessage verifies the FAILED_AUTHORITY_ABORT
// operator-facing message emitted by report() conforms to the V126.2 UX hotfix
// scope (AUDIT_190_LIFECYCLE/V126_2_INSTALL_ABORT_UX_HOTFIX_SCOPE.md REV 4).
//
// Acceptance criteria mapped from scope §4:
//   - Includes the new operator-friendly block (header, options, verification)
//   - Includes the sudo-safe command form (Gemini REV 4 finding)
//   - Includes the root-shell command form
//   - Includes Ctrl-C warning + dpkg-configure warning (operator dns1 evidence)
//   - Excludes the BROKEN command `NFTBAN_TAKEOVER=1 dpkg --configure nftban-core`
//   - Excludes the wrong-for-ABORT retry hints `--repair` (generic FAILED form)
//     and `nftban firewall rebuild` (generic FAILED form)
//   - Excludes the generic `Install/upgrade FAILED.` block
//   - Dynamically populates conflict list from sf.Conflicts
//
// Snapshot scope: report() output ONLY. The [NFTBan ERROR] phase Detect failed
// line + JSON detect/plan/result event dumps are emitted by separate code paths
// (main.go:396 + lifecycle bridge) and out of V126.2 scope per §6.
func TestReportFailedAbortV126_2HotfixMessage(t *testing.T) {
	// Redirect os.Stdout AND os.Stderr BEFORE constructing the logger so the
	// new logger's internal console writer (set at logger.New() time) captures
	// the pipe instead of the real stdout. Stderr capture is defensive — it
	// proves report() does NOT emit lifecycle JSON event dumps (those come
	// from the lifecycle bridge in main.go phase-runner, not from report()).
	origStdout := os.Stdout
	origStderr := os.Stderr
	rOut, wOut, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe (stdout): %v", err)
	}
	rErr, wErr, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe (stderr): %v", err)
	}
	os.Stdout = wOut
	os.Stderr = wErr
	defer func() {
		os.Stdout = origStdout
		os.Stderr = origStderr
	}()

	// Temp log file so writeFile() doesn't touch /var/log on the test host.
	tmpDir := t.TempDir()
	logPath := tmpDir + "/installer.log"
	log := logging.New(logPath, false)
	defer log.Close()

	// Construct a StateFile matching the dns1 FAILED_AUTHORITY_ABORT case
	// from 2026-05-23: Ubuntu 24.04 DEB install with 4 detected conflicts.
	sf := state.NewStateFile(tmpDir)
	sf.State = state.StateFailedAbort
	sf.Mode = "install"
	sf.Conflicts = "UFW,iptables-nft,iptables,CSF"
	sf.Panel = "directadmin"
	sf.FailureReason = "conflicts detected, takeover not approved: UFW,iptables-nft,iptables,CSF"

	// Run report() — this emits the V126.2 friendly block to stdout.
	// (Discard the returned exit code; the test asserts on output content.)
	_ = report(sf, log)

	// Capture both stdout and stderr.
	if err := wOut.Close(); err != nil {
		t.Fatalf("stdout pipe writer close: %v", err)
	}
	if err := wErr.Close(); err != nil {
		t.Fatalf("stderr pipe writer close: %v", err)
	}
	var bufOut, bufErr bytes.Buffer
	if _, err := io.Copy(&bufOut, rOut); err != nil {
		t.Fatalf("read captured stdout: %v", err)
	}
	if _, err := io.Copy(&bufErr, rErr); err != nil {
		t.Fatalf("read captured stderr: %v", err)
	}
	os.Stdout = origStdout
	os.Stderr = origStderr
	output := bufOut.String()
	stderrOutput := bufErr.String()

	// ====== Required INCLUDES (V126.2 §4 acceptance criteria 1-22) ======
	mustInclude := []string{
		// Header
		"NFTBan Installation Paused",
		"Existing Firewalls Detected",
		// OPTION 1 block
		"OPTION 1: Let NFTBan Take Control",
		// REV 4 sudo-safe inline form
		"sudo NFTBAN_TAKEOVER=1 /usr/lib/nftban/bin/nftban-installer --repair",
		// Root-shell alternative
		"NFTBAN_TAKEOVER=1 /usr/lib/nftban/bin/nftban-installer --repair",
		// OPTION 2 block (the "stop here" exit path)
		"OPTION 2: Stop Here",
		// REV 4 kernel-verification additions (Gemini #2)
		"nft list tables",
		"nft list ruleset | grep -i nftban",
		// REV 4 package-state CHECK commands (ChatGPT refinement)
		"dpkg -s nftban-core",
		"apt-get check",
		"rpm -q nftban-core",
		"dnf check",
		// REV 4 Ctrl-C warning (operator dns1 evidence)
		"do not press Ctrl+C",
		// REV 4 dpkg-already-configured warning
		"do not run dpkg --configure",
		// Conflict list dynamically populated from sf.Conflicts
		"• UFW",
		"• iptables-nft",
		"• iptables",
		"• CSF",
		// Health verification commands
		"nftban version",
		"systemctl is-active nftband",
		"INSTALL_STATE=COMMITTED",
	}
	for _, want := range mustInclude {
		if !strings.Contains(output, want) {
			t.Errorf("V126.2 report() FAILED_AUTHORITY_ABORT output is MISSING required string:\n  want: %q", want)
		}
	}

	// ====== Required EXCLUDES (V126.2 §4 acceptance criteria 10-22) ======
	// All excludes are scoped to report() output. The [NFTBan ERROR] phase
	// Detect failed line + JSON dumps come from separate code paths and are
	// not part of this test scope per V126.2 §6.
	mustExclude := []string{
		// BROKEN command from old DEB postinst (dns1 evidence: dpkg refuses)
		"NFTBAN_TAKEOVER=1 dpkg --configure nftban-core",
		// REV 3-era too-detailed RPM command (operator shouldn't need --rpm flag)
		"nftban-installer --rpm --mode=",
		// Generic FAILED block retry hints — wrong for the ABORT case
		// (those apply to FAILED_RENDER / FAILED_REBUILD recovery)
		"[NFTBan] To retry: /usr/lib/nftban/bin/nftban-installer --repair",
		"[NFTBan] Or: nftban firewall rebuild",
		// Generic FAILED block header — replaced by the friendly block
		"[NFTBan] Install/upgrade FAILED.",
	}
	for _, unwanted := range mustExclude {
		if strings.Contains(output, unwanted) {
			t.Errorf("V126.2 report() FAILED_AUTHORITY_ABORT output contains FORBIDDEN string:\n  unwanted: %q\n  scope: this string belongs to a pre-V126.2 message form or to a different state's output", unwanted)
		}
	}

	// Note: this test does NOT assert absence of "--repair" globally, because
	// the new (correct) recovery command intentionally contains
	// "/usr/lib/nftban/bin/nftban-installer --repair". Only specific OLD
	// command forms are forbidden — see mustExclude list.

	// ====== V126.2 REV 4 stderr cleanliness assertion ======
	// report() itself must NOT emit lifecycle JSON events to stderr. The
	// JSON dumps come from the lifecycle bridge (cmd/nftban-installer/
	// lifecycle_bridge.go), which is invoked from the phase-runner loop in
	// main.go run(). For FAILED_AUTHORITY_ABORT the phase-runner SKIPS the
	// lifecycle bridge observer calls (see main.go phase-failure handler),
	// so JSON dumps never reach stderr. This test asserts report() in
	// isolation does not produce stderr noise.
	stderrForbidden := []string{
		`{"timestamp":`,
		`"event":"detect"`,
		`"event":"plan"`,
		`"event":"result"`,
	}
	for _, unwanted := range stderrForbidden {
		if strings.Contains(stderrOutput, unwanted) {
			t.Errorf("V126.2 report() FAILED_AUTHORITY_ABORT stderr contains FORBIDDEN string: %q\nstderr:\n%s", unwanted, stderrOutput)
		}
	}
}

// TestErrorLogOnly_DoesNotEmitToStdout verifies the V126.2 logging primitive
// used by main.go phase-failure handler to suppress the cryptic
// "[NFTBan ERROR] phase Detect failed:" stdout line for FAILED_AUTHORITY_ABORT
// while preserving the same line in the log file.
//
// Acceptance criterion REV 4 §4 #10: ERROR line REMOVED from stdout for
// FAILED_AUTHORITY_ABORT case (kept in log file for audit).
func TestErrorLogOnly_DoesNotEmitToStdout(t *testing.T) {
	origStdout := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	os.Stdout = w
	defer func() { os.Stdout = origStdout }()

	tmpDir := t.TempDir()
	logPath := tmpDir + "/installer.log"
	log := logging.New(logPath, false)
	defer log.Close()

	// Call the new primitive
	log.ErrorLogOnly("phase Detect failed: FAILED_AUTHORITY_ABORT: conflicts detected")

	// Close stdout pipe and read
	_ = w.Close()
	var buf bytes.Buffer
	_, _ = io.Copy(&buf, r)
	os.Stdout = origStdout

	// Assertion: stdout MUST be empty (no ERROR line)
	stdout := buf.String()
	if strings.Contains(stdout, "[NFTBan ERROR]") {
		t.Errorf("ErrorLogOnly leaked to stdout — expected log-file-only:\n%s", stdout)
	}
	if strings.Contains(stdout, "phase Detect failed") {
		t.Errorf("ErrorLogOnly leaked to stdout — expected log-file-only:\n%s", stdout)
	}

	// Assertion: log file SHOULD contain the message (audit trail preserved)
	logBytes, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read log file: %v", err)
	}
	logContent := string(logBytes)
	if !strings.Contains(logContent, "phase Detect failed: FAILED_AUTHORITY_ABORT: conflicts detected") {
		t.Errorf("ErrorLogOnly did NOT write to log file (audit trail broken):\n%s", logContent)
	}
	if !strings.Contains(logContent, "[ERROR]") {
		t.Errorf("ErrorLogOnly did not include [ERROR] level marker in log file:\n%s", logContent)
	}
}

// TestReportFailedAbortV126_2_EmptyConflicts verifies graceful fallback when
// install_state.CONFLICTS is empty (per D_DETECTOR_OPTION_A_CSF_CONF_GAP_SCOPE.md —
// the detector can leave CONFLICTS empty even when conflicts are detected).
func TestReportFailedAbortV126_2_EmptyConflicts(t *testing.T) {
	origStdout := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	os.Stdout = w
	defer func() { os.Stdout = origStdout }()

	tmpDir := t.TempDir()
	log := logging.New(tmpDir+"/installer.log", false)
	defer log.Close()

	sf := state.NewStateFile(tmpDir)
	sf.State = state.StateFailedAbort
	sf.Conflicts = "" // empty — detector-gap case

	_ = report(sf, log)

	_ = w.Close()
	var buf bytes.Buffer
	_, _ = io.Copy(&buf, r)
	os.Stdout = origStdout
	output := buf.String()

	// Should fall back to a clear message, not crash or emit garbage bullets.
	if !strings.Contains(output, "detected conflicts could not be enumerated") {
		t.Errorf("V126.2 report() FAILED_AUTHORITY_ABORT with empty Conflicts: expected fallback message, got:\n%s", output)
	}
	// Should still emit the main friendly block.
	if !strings.Contains(output, "OPTION 1: Let NFTBan Take Control") {
		t.Errorf("V126.2 report() FAILED_AUTHORITY_ABORT with empty Conflicts: friendly block missing OPTION 1 header")
	}
}
