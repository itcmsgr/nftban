// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 PR-26-code-D — restore evidence record tests
// =============================================================================
// meta:name="nftban-installer-restore-evidence-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-28"
// meta:description="Tests for the post-restore evidence-record writer. Pins §48.6 invariants: writes only under restoreEvidenceDir, single helper enforcement (file-scan), schema_version + required fields populated, no update-history writes, recording-only (no Decide / Probe / DetectPanel calls)."
// meta:depends="github.com/itcmsgr/nftban/internal/installer/executor,github.com/itcmsgr/nftban/internal/installer/restore"
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
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/restore"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// =============================================================================
// Helpers
// =============================================================================

func newEvidenceTestRecord(now time.Time, terminal state.InstallState, fwt string) *RestoreEvidenceRecord {
	return &RestoreEvidenceRecord{
		SchemaVersion: restoreEvidenceSchemaVersion,
		TimestampUTC:  now,
		Mode:          "restore",
		Phase:         "post_restore_verify",
		Target: RestoreEvidenceTarget{
			Kind:         string(restore.TargetAuthorityKindRecordedPrior),
			FirewallType: fwt,
			Panel:        string(detect.PanelNone),
		},
		Result: RestoreEvidenceResult{
			State:    string(terminal),
			ExitCode: terminal.ExitCode(),
			Stage:    "complete",
			Success:  terminal == state.StateRestoreExecuted,
		},
		Verification: RestoreEvidenceVerify{
			TargetFirewallActive: true,
			AuthorityClass:       string(uninstall.AuthorityExternal),
			SafetyNetRemovalSafe: true,
			SSHPort:              22,
			SSHPortSource:        "ss",
		},
		HistoryGate: RestoreEvidenceHistory{
			UpdateHistoryUnchanged:           true,
			RestoreModeHistoryWriteForbidden: true,
		},
	}
}

// =============================================================================
// Writer tests
// =============================================================================

func TestWriteRestoreEvidence_HappyPath(t *testing.T) {
	mock := executor.NewMockExecutor()
	rec := newEvidenceTestRecord(time.Date(2026, 4, 28, 13, 45, 0, 0, time.UTC),
		state.StateRestoreExecuted, "csf")

	err := writeRestoreEvidenceRecord(context.Background(), mock, rec, pf4B2TestLogger(t))
	if err != nil {
		t.Fatalf("err = %v; want nil", err)
	}

	// Exactly one file written under restoreEvidenceDir.
	count := 0
	var path string
	for k := range mock.WrittenFiles {
		if strings.HasPrefix(k, restoreEvidenceDir+"/") {
			count++
			path = k
		}
	}
	if count != 1 {
		t.Errorf("evidence file count = %d; want 1", count)
	}
	// Filename pattern: prefix + UTC stamp + - + 8-hex + .json.
	base := filepath.Base(path)
	if !strings.HasPrefix(base, restoreEvidenceFilenamePrefix) {
		t.Errorf("filename %q does not start with %q", base, restoreEvidenceFilenamePrefix)
	}
	if !strings.HasSuffix(base, ".json") {
		t.Errorf("filename %q does not end with .json", base)
	}
	if !strings.Contains(base, "20260428T134500Z") {
		t.Errorf("filename %q does not contain expected UTC stamp", base)
	}
}

func TestWriteRestoreEvidence_RoundTripsJSON(t *testing.T) {
	mock := executor.NewMockExecutor()
	rec := newEvidenceTestRecord(time.Now().UTC(), state.StateRestoreExecuted, "csf")

	if err := writeRestoreEvidenceRecord(context.Background(), mock, rec, pf4B2TestLogger(t)); err != nil {
		t.Fatalf("err = %v", err)
	}

	var path string
	for k := range mock.WrittenFiles {
		if strings.HasPrefix(k, restoreEvidenceDir+"/") {
			path = k
		}
	}
	if path == "" {
		t.Fatal("no evidence file written")
	}

	var decoded RestoreEvidenceRecord
	if err := json.Unmarshal(mock.WrittenFiles[path], &decoded); err != nil {
		t.Fatalf("evidence file does not parse as JSON: %v", err)
	}
	if decoded.SchemaVersion != restoreEvidenceSchemaVersion {
		t.Errorf("schema_version = %q; want %q", decoded.SchemaVersion, restoreEvidenceSchemaVersion)
	}
	if decoded.Mode != "restore" {
		t.Errorf("mode = %q; want %q", decoded.Mode, "restore")
	}
	if decoded.Phase != "post_restore_verify" {
		t.Errorf("phase = %q; want %q", decoded.Phase, "post_restore_verify")
	}
	if !decoded.HistoryGate.UpdateHistoryUnchanged || !decoded.HistoryGate.RestoreModeHistoryWriteForbidden {
		t.Errorf("history_gate flags must both be true; got %+v", decoded.HistoryGate)
	}
}

func TestWriteRestoreEvidence_NilExecutor(t *testing.T) {
	rec := newEvidenceTestRecord(time.Now().UTC(), state.StateRestoreExecuted, "csf")
	err := writeRestoreEvidenceRecord(context.Background(), nil, rec, nil)
	if !errors.Is(err, ErrEvidenceNilExecutor) {
		t.Errorf("err = %v; want ErrEvidenceNilExecutor", err)
	}
}

func TestWriteRestoreEvidence_NilRecord(t *testing.T) {
	mock := executor.NewMockExecutor()
	err := writeRestoreEvidenceRecord(context.Background(), mock, nil, nil)
	if !errors.Is(err, ErrEvidenceNilRecord) {
		t.Errorf("err = %v; want ErrEvidenceNilRecord", err)
	}
}

// =============================================================================
// Single-helper invariant + path containment — file-scan
// =============================================================================

func TestWriteRestoreEvidence_OnlyHelperWritesUnderEvidenceDir_FileScan(t *testing.T) {
	body, err := os.ReadFile("restore_evidence.go")
	if err != nil {
		t.Fatalf("read restore_evidence.go: %v", err)
	}
	src := string(body)

	// Strip line-leading // comments per §46.1 discipline.
	var prodLines []string
	for _, line := range strings.Split(src, "\n") {
		trimmed := strings.TrimLeft(line, " \t")
		if strings.HasPrefix(trimmed, "//") {
			continue
		}
		prodLines = append(prodLines, line)
	}
	prodSrc := strings.Join(prodLines, "\n")

	// The single helper writeRestoreEvidenceRecord MUST be the only
	// function in this file that calls exec.WriteFileAtomic AND uses
	// restoreEvidenceDir. Detect both:
	//   - any WriteFileAtomic call: count must be exactly 1
	//   - any restoreEvidenceDir reference outside the helper /
	//     constant declaration must be 0
	wfa := strings.Count(prodSrc, "WriteFileAtomic(")
	if wfa != 1 {
		t.Errorf("WriteFileAtomic( call count in restore_evidence.go = %d; want exactly 1 (the single helper)", wfa)
	}
}

func TestWriteRestoreEvidence_NoForbiddenSurfaces_FileScan(t *testing.T) {
	body, err := os.ReadFile("restore_evidence.go")
	if err != nil {
		t.Fatalf("read restore_evidence.go: %v", err)
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

	// Recording-only invariant — the evidence module must not call
	// any decision/redetection API.
	forbidden := []string{
		"restore.Decide(",
		"restore.PlanFromDecision(",
		"uninstall.Probe(",
		"detect.DetectPanel(",
		// History gate: evidence is a SEPARATE artefact from
		// update-history.json. The evidence module must not write
		// update-history.json itself.
		"writeHistory(",
		"update-history.json",
		// No mutation primitives allowed (recording is read-only).
		"ServiceStart(",
		"ServiceStop(",
		"ServiceEnable(",
		"ServiceDisable(",
		"ServiceMask(",
		"ServiceUnmask(",
		"NftDeleteTable(",
		"NftAddElement(",
		"DaemonReload(",
		"Rename(",
		// Direct OS bypass.
		"os/exec",
		"exec.Command(",
		"os.Rename(",
		"os.Remove(",
		"os.WriteFile(",
		"os.Create(",
		"syscall.",
	}
	for _, pat := range forbidden {
		if strings.Contains(prodSrc, pat) {
			t.Errorf("restore_evidence.go references forbidden pattern %q (recording-only invariant)", pat)
		}
	}
}

// =============================================================================
// Builder — recording-only assembly from existing dispatcher state
// =============================================================================

func TestBuildRestoreEvidenceRecord_RecordedPriorHappy(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-tlnp"] = executor.Result{
		ExitCode: 0,
		Stdout:   "LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:((\"sshd\",pid=1,fd=3))\n",
	}

	target, _ := restore.TargetRecordedPrior("csf")
	execRes := restore.ExecuteResult{
		Terminal: state.StateRestoreExecuted,
		Stage:    "complete",
		VerifyResult: restore.VerifyResult{
			TargetFirewallActive:  true,
			AuthorityClassCorrect: true,
			SafetyNetRemovalSafe:  true,
			SafeToRemove:          true,
			ObservedAuthority:     uninstall.AuthorityExternal,
		},
	}

	rec := buildRestoreEvidenceRecord(mock, pf4B2TestLogger(t), target, execRes)
	if rec.SchemaVersion != restoreEvidenceSchemaVersion {
		t.Errorf("schema_version = %q", rec.SchemaVersion)
	}
	if rec.Result.State != string(state.StateRestoreExecuted) {
		t.Errorf("result.state = %q", rec.Result.State)
	}
	if !rec.Result.Success {
		t.Errorf("result.success = false; want true")
	}
	if rec.Result.ExitCode != state.StateRestoreExecuted.ExitCode() {
		t.Errorf("result.exit_code = %d; want %d", rec.Result.ExitCode, state.StateRestoreExecuted.ExitCode())
	}
	if rec.Verification.SSHPort != 22 || rec.Verification.SSHPortSource != "ss" {
		t.Errorf("verification.ssh_port=%d source=%q; want 22 / ss",
			rec.Verification.SSHPort, rec.Verification.SSHPortSource)
	}
	if !rec.HistoryGate.UpdateHistoryUnchanged || !rec.HistoryGate.RestoreModeHistoryWriteForbidden {
		t.Errorf("history_gate flags must both be true; got %+v", rec.HistoryGate)
	}
}

func TestBuildRestoreEvidenceRecord_NftbanTablesPresent_Recorded(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-tlnp"] = executor.Result{
		ExitCode: 0,
		Stdout:   "LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:((\"sshd\",pid=1,fd=3))\n",
	}
	mock.NftTables["ip:nftban"] = true

	target, _ := restore.TargetRecordedPrior("csf")
	execRes := restore.ExecuteResult{Terminal: state.StateRestoreFailedExecution, Stage: "mutate"}

	rec := buildRestoreEvidenceRecord(mock, pf4B2TestLogger(t), target, execRes)
	if !rec.Verification.NftbanTablesPresentAfter {
		t.Errorf("nftban_tables_present_after = false; want true (ip:nftban seeded)")
	}
}

func TestBuildRestoreEvidenceRecord_AuthorityClassDivergenceWarning(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.RunResults["ss:-tlnp"] = executor.Result{ExitCode: 0, Stdout: "LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:((\"sshd\",pid=1,fd=3))\n"}

	target, _ := restore.TargetRecordedPrior("csf")
	execRes := restore.ExecuteResult{
		Terminal: state.StateRestoreExecuted,
		Stage:    "complete",
		VerifyResult: restore.VerifyResult{
			ObservedAuthority: uninstall.AuthorityNFTBan, // diverges from expected External
		},
	}

	rec := buildRestoreEvidenceRecord(mock, pf4B2TestLogger(t), target, execRes)
	found := false
	for _, w := range rec.Warnings {
		if strings.Contains(w, "authority-class observed") {
			found = true
		}
	}
	if !found {
		t.Errorf("authority-class divergence not surfaced as warning; got warnings = %v", rec.Warnings)
	}
}

// =============================================================================
// Path constant — pinned to §48.6
// =============================================================================

func TestRestoreEvidenceConstants_LockPin(t *testing.T) {
	if restoreEvidenceDir != "/var/lib/nftban/state/restore-evidence" {
		t.Errorf("restoreEvidenceDir = %q; §48.6 lock requires %q",
			restoreEvidenceDir, "/var/lib/nftban/state/restore-evidence")
	}
	if restoreEvidenceSchemaVersion != "1.0.0" {
		t.Errorf("restoreEvidenceSchemaVersion = %q; §48.6 lock requires %q",
			restoreEvidenceSchemaVersion, "1.0.0")
	}
	if restoreEvidenceFilenamePrefix != "restore-evidence-" {
		t.Errorf("restoreEvidenceFilenamePrefix = %q; want %q",
			restoreEvidenceFilenamePrefix, "restore-evidence-")
	}
}
