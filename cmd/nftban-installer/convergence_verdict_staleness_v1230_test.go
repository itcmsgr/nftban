// =============================================================================
// NFTBan v1.230.0 Gate 6R F1 — a verdict from an earlier run must not survive
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-convergence-verdict-staleness-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-13"
// meta:description="Proves that CONVERGENCE_VERIFIED from an EARLIER successful run is cleared before any rebuild disposition is persisted, so REBUILD_REFUSED_BUSY / REBUILD_NOT_EXECUTED / FAILED_REBUILD records never inherit VERIFIED. Every fixture starts from a POPULATED prior record and every assertion RELOADS FROM DISK, because an empty-state in-memory check cannot fail this defect."
// meta:inventory.files="cmd/nftban-installer/convergence_verdict_staleness_v1230_test.go"
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
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/switchop"
	"github.com/itcmsgr/nftban/pkg/version"
)

// ⛔ LIVE-OBSERVED ON lab3: a REBUILD_REFUSED_BUSY record carried
// CONVERGENCE_VERIFIED=VERIFIED from an earlier successful run.
//
//	HISTORICAL STATE MAY INFORM DIAGNOSIS, BUT MUST NEVER SATISFY A
//	CURRENT-RUN PROOF OBLIGATION.
//
// ⛔ THE FIXTURE MUST START FROM A POPULATED PRIOR RECORD. An empty state file cannot
// fail this defect by construction — which is exactly why a full unit suite missed it.
// ⛔ AND EVERY ASSERTION RELOADS FROM DISK. The inheritance happens on the WRITE path
// (WriteAtomic serialises the struct verbatim), so an in-memory check on the same struct
// the code just cleared would pass while the shipped artifact still carried the lie.

// writePriorVerifiedRecord lays down a COMMITTED record from a previous, genuinely
// successful run — including CONVERGENCE_VERIFIED=VERIFIED — and returns the state dir.
func writePriorVerifiedRecord(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	prior := state.NewStateFile(dir)
	prior.State = state.StateCommitted
	prior.Version = version.Version
	prior.Mode = "upgrade"
	prior.SSHPort = 22
	prior.ConvergenceVerified = string(switchop.ConvergenceVerified)
	prior.RebuildExitCode = 0
	prior.RebuildDurationMs = 4523
	if err := prior.WriteAtomic(); err != nil {
		t.Fatalf("seed prior record: %v", err)
	}
	// ⛔ NON-VACUITY: the fixture must actually contain the stale value, or the arms
	// below would pass against a record that never carried it.
	raw, err := os.ReadFile(filepath.Join(dir, "install_state"))
	if err != nil {
		t.Fatalf("read seeded record: %v", err)
	}
	if !strings.Contains(string(raw), "CONVERGENCE_VERIFIED=VERIFIED") {
		t.Fatalf("fixture did not seed a stale verdict:\n%s", raw)
	}
	return dir
}

// reloadRecord reads the PERSISTED record back, which is the only artifact a later run,
// `nftban support` or an operator will ever see.
func reloadRecord(t *testing.T, dir string) *state.StateFile {
	t.Helper()
	sf := state.NewStateFile(dir)
	if err := sf.Read(); err != nil {
		t.Fatalf("reload install_state: %v", err)
	}
	return sf
}

// driveSwitchOnPriorRecord runs the real installer over a state dir that already holds a
// VERIFIED record, with the rebuild behaving as `sim` dictates.
func driveSwitchOnPriorRecord(t *testing.T, dir string, hook func(m *executor.MockExecutor, args []string) executor.Result) (int, string) {
	t.Helper()
	inj, m, cleanup := newAllAssertionsPassFixture(t)
	defer cleanup()
	t.Setenv("NFTBAN_MIN_DISK_FREE_MB", "1")
	m.Files["/etc/ssh/sshd_config"] = []byte("Port 22\n")
	t.Cleanup(switchop.SetRebuildResultBaseDirForTest(t.TempDir()))
	for _, c := range []string{
		"jq", "curl", "socat", "bc", "gawk", "getfacl", "tar", "nft", "systemctl",
		"install", "chown", "chmod", "setcap", "sed", "grep", "awk",
	} {
		m.ExistingCommands[c] = true
	}
	m.Files["/etc/os-release"] = []byte("ID=ubuntu\nVERSION_ID=\"24.04\"\n")
	m.Files[switchop.BootProjectionPath] = []byte("table ip nftban {\n}\n")
	m.Files[switchop.ConvergenceGenerationPath] = []byte("7\n")
	m.NftTables["ip:nftban"] = true
	m.NftTables["ip6:nftban"] = true
	m.RunHook = func(name string, args []string) (executor.Result, bool) {
		if name == fhs.NftbanCLI && len(args) >= 2 && args[0] == "firewall" && args[1] == "rebuild" {
			return hook(m, args), true
		}
		return executor.Result{}, false
	}

	sf := state.NewStateFile(dir)
	if err := sf.Read(); err != nil {
		t.Fatalf("read seeded record: %v", err)
	}
	sf.Version = version.Version
	sf.SSHPort = 22
	cfg := &config{mode: "upgrade", stateDir: dir, inject: inj}
	globalPhaseData = phaseData{}
	logPath := dir + "/installer.log"
	log := logging.New(logPath, false)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	rc := runInstall(ctx, m, sf, cfg, log)
	b, _ := os.ReadFile(logPath)
	return rc, string(b)
}

// refusalHook plays a shell whose convergence lock is permanently held.
func refusalHook(_ *executor.MockExecutor, args []string) executor.Result {
	var rp, op string
	for i := 0; i < len(args)-1; i++ {
		switch args[i] {
		case "--result-file":
			rp = args[i+1]
		case "--operation-id":
			op = args[i+1]
		}
	}
	if rp != "" {
		body := `{"schema_version":"1","operation_id":"` + op + `","context":"install-deferred",` +
			`"disposition":"REFUSED","reason_codes":["CONVERGENCE_LOCK_HELD"],"rollback_performed":false,` +
			`"modified":false,"enforcement_unchanged":true,` +
			`"transaction":{"committed":false,"reason":"NOT_STARTED"},"retry":{"reason":"REFUSED_CONVERGENCE_LOCK"},` +
			`"pre_status":"not-observed","post_status":"not-observed","emitted_at":"2026-09-13T00:00:00Z"}`
		_ = os.MkdirAll(filepath.Dir(rp), 0o750)
		_ = os.WriteFile(rp, []byte(body), 0o640)
	}
	return executor.Result{ExitCode: 1}
}

func TestF1_RefusedRecordDoesNotInheritTheEarlierVerdict(t *testing.T) {
	dir := writePriorVerifiedRecord(t)
	defer switchop.SetRefusalBackoffForTest(time.Millisecond, 2*time.Millisecond)()

	_, logText := driveSwitchOnPriorRecord(t, dir, refusalHook)

	got := reloadRecord(t, dir)
	if got.State != state.StateRebuildRefusedBusy {
		t.Fatalf("state = %s, want REBUILD_REFUSED_BUSY\n%s", got.State, logText)
	}
	// THE DEFECT.
	if got.ConvergenceVerified == string(switchop.ConvergenceVerified) {
		t.Errorf("PERSISTED CONVERGENCE_VERIFIED=VERIFIED on a refused run — inherited from the earlier record")
	}
	if got.ConvergenceVerified != "" {
		t.Errorf("CONVERGENCE_VERIFIED = %q, want the not-evaluated representation \"\"", got.ConvergenceVerified)
	}
	// ⛔ AND NOT "FAILED": refusal means NOT EVALUATED, not evaluated-and-failed.
	if strings.EqualFold(got.ConvergenceVerified, "FAILED") ||
		got.ConvergenceVerified == string(switchop.ConvergenceNotConverged) {
		t.Errorf("a refusal must not record a failed evaluation; got %q", got.ConvergenceVerified)
	}
	// Read the raw bytes too — the operator and `nftban support` see the FILE.
	raw, _ := os.ReadFile(filepath.Join(dir, "install_state"))
	if strings.Contains(string(raw), "CONVERGENCE_VERIFIED=VERIFIED") {
		t.Errorf("the persisted file still claims VERIFIED:\n%s", raw)
	}

	// ⛔ REFUSAL TRUTH MUST BE UNDISTURBED by this metadata fix.
	if !strings.Contains(logText, "modified=false enforcement_unchanged=true") {
		t.Errorf("the refusal contract's mutation facts are no longer reported\n%s", logText)
	}
	if got.State == state.StateCommitted {
		t.Error("a refused run must never be COMMITTED")
	}
}

// ⛔ VERIFY RATHER THAN ASSUME: the coordinator inferred that FAILED_REBUILD and
// REBUILD_NOT_EXECUTED inherit through the same return path. They do — this pins it.
func TestF1_EveryPreConvergenceDispositionClearsTheVerdict(t *testing.T) {
	cases := []struct {
		name string
		want state.InstallState
		hook func(m *executor.MockExecutor, args []string) executor.Result
	}{
		{"refused", state.StateRebuildRefusedBusy, refusalHook},
		{
			// No contract and no witness -> execution not established.
			"not executed", state.StateRebuildNotExecuted,
			func(_ *executor.MockExecutor, _ []string) executor.Result {
				return executor.Result{ExitCode: 1, Stderr: "unknown option"}
			},
		},
		{
			// Executed (witness written) and failed -> a real rebuild failure.
			"failed rebuild", state.StateFailedRebuild,
			func(_ *executor.MockExecutor, args []string) executor.Result {
				var wp, op string
				for i := 0; i < len(args)-1; i++ {
					switch args[i] {
					case "--execution-witness":
						wp = args[i+1]
					case "--operation-id":
						op = args[i+1]
					}
				}
				if wp != "" {
					_ = os.MkdirAll(filepath.Dir(wp), 0o750)
					_ = os.WriteFile(wp, []byte("operation_id="+op+"\n"), 0o640)
				}
				return executor.Result{ExitCode: 2, Stderr: "rollback performed"}
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := writePriorVerifiedRecord(t)
			defer switchop.SetRefusalBackoffForTest(time.Millisecond, 2*time.Millisecond)()
			_, logText := driveSwitchOnPriorRecord(t, dir, tc.hook)

			got := reloadRecord(t, dir)
			if got.State != tc.want {
				t.Fatalf("state = %s, want %s\n%s", got.State, tc.want, logText)
			}
			if got.ConvergenceVerified != "" {
				t.Errorf("%s inherited CONVERGENCE_VERIFIED=%q from the earlier run", tc.want, got.ConvergenceVerified)
			}
		})
	}
}

// Positive control: a run that DOES evaluate convergence still records its verdict.
// Without this the fix could be "always clear", which would be equally wrong.
func TestF1_SuccessfulRunStillRecordsVerified(t *testing.T) {
	dir := writePriorVerifiedRecord(t)
	_, logText := driveSwitchOnPriorRecord(t, dir, func(m *executor.MockExecutor, args []string) executor.Result {
		var rp, op, wp string
		for i := 0; i < len(args)-1; i++ {
			switch args[i] {
			case "--result-file":
				rp = args[i+1]
			case "--operation-id":
				op = args[i+1]
			case "--execution-witness":
				wp = args[i+1]
			}
		}
		if wp != "" {
			_ = os.MkdirAll(filepath.Dir(wp), 0o750)
			_ = os.WriteFile(wp, []byte("operation_id="+op+"\n"), 0o640)
		}
		m.Files[switchop.ConvergenceGenerationPath] = []byte("8\n")
		body := `{"schema_version":"1","operation_id":"` + op + `","context":"install-deferred",` +
			`"disposition":"COMPLETE","reason_codes":[],"rollback_performed":false,` +
			`"modified":true,"enforcement_unchanged":false,` +
			`"transaction":{"committed":true,"reason":"COMMITTED"},"retry":{"reason":"NONE"},` +
			`"pre_status":"protected","post_status":"protected","emitted_at":"2026-09-13T00:00:00Z"}`
		_ = os.MkdirAll(filepath.Dir(rp), 0o750)
		_ = os.WriteFile(rp, []byte(body), 0o640)
		return executor.Result{ExitCode: 0}
	})

	got := reloadRecord(t, dir)
	if got.ConvergenceVerified != string(switchop.ConvergenceVerified) {
		t.Errorf("CONVERGENCE_VERIFIED = %q, want VERIFIED — the clear must not erase a verdict this run earned\n%s",
			got.ConvergenceVerified, logText)
	}
}
