// =============================================================================
// NFTBan v1.99 PR-18 — Update Apply Call-Path Purity Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-update-apply-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Verify runUpdateApply is a thin sequencer and nothing more"
// meta:inventory.files="cmd/nftban-installer/update_apply_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// These tests run every MockExecutor.Commands trace from a runUpdateApply
// execution through the contract-audit harness in
// internal/installer/update/apply_contract_test.go. If apply ever invokes
// a command outside the whitelist, or writes to a forbidden path, the
// tests fail — before CI sees it.
//
// Coverage:
//   T1 happy path — preflight + rebuild + validator all pass → exit 0
//   T2 preflight fails → rebuild NEVER invoked → exit 1
//   T3 rebuild fails → validator NEVER invoked → exit = rebuild's RC
//   T4 rebuild OK but validator fails → exit = validator's RC (G3-U8
//      truth gate — validator wins)
//   T5 call-path purity — no command outside applyWhitelist ever invoked
//   T6 .conf.local byte-preservation — no write to *.conf.local (G3-U5)
//
// =============================================================================

package main

import (
	"context"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/update"
)

func newApplyTestLogger() *logging.Logger {
	return logging.New("/dev/null", false)
}

// seedHappyApplyHost populates a mock where:
//   - preflight passes (P-1..P-7 all OK)
//   - nftban firewall rebuild returns exit 0
//   - nftban-validate --json returns exit 0 with a valid "protected" body
//   - post-state inspection finds expected kernel + service state
func seedHappyApplyHost(mock *executor.MockExecutor) {
	// Preflight surface (mirrors PR-16/PR-17 tests).
	mock.NftTables["ip:nftban"] = true
	mock.Services["nftband.service"] = true
	mock.Files["/usr/lib/nftban/VERSION"] = []byte("1.99.0\n")
	mock.RunResults["sh:-c:command -v nft >/dev/null 2>&1"] = executor.Result{ExitCode: 0}
	mock.Files["/var/lib/nftban/state/install_state"] = []byte("COMMITTED\n")
	// DetectInstallOrigin probes — return "" from all to keep origin "".
	mock.RunResults["rpm:-q:nftban-core"] = executor.Result{ExitCode: 127}
	mock.RunResults["rpm:-q:nftban"] = executor.Result{ExitCode: 127}
	mock.RunResults["dpkg:-s:nftban-core"] = executor.Result{ExitCode: 127}
	mock.RunResults["dpkg:-s:nftban"] = executor.Result{ExitCode: 127}

	// Canonical rebuild entry — success.
	mock.RunResults["nftban:firewall:rebuild"] = executor.Result{ExitCode: 0, Stdout: "rebuild ok"}

	// Validator gate — success with a plausible JSON body.
	mock.RunResults["nftban-validate:--json"] = executor.Result{
		ExitCode: 0,
		Stdout:   `{"schema_version":"1.83.0","status":"protected"}`,
	}
}

// cmdTrace flattens mock.Commands into strings suitable for feeding into
// the auditRecordedCommands harness.
func cmdTrace(mock *executor.MockExecutor) []string {
	out := make([]string, 0, len(mock.Commands))
	for _, c := range mock.Commands {
		out = append(out, c.Name+" "+strings.Join(c.Args, " "))
	}
	return out
}

func writtenPaths(mock *executor.MockExecutor) []string {
	out := make([]string, 0, len(mock.WrittenFiles))
	for k := range mock.WrittenFiles {
		out = append(out, k)
	}
	return out
}

// T1 — Happy path.
func TestUpdateApply_HappyPath_Exits0(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyApplyHost(mock)
	cfg := &config{mode: "upgrade", stateDir: "/var/lib/nftban/state"}
	sf := state.NewStateFile(cfg.stateDir)

	rc := runUpdateApply(context.Background(), mock, sf, cfg, newApplyTestLogger())
	if rc != state.ExitCommitted {
		t.Errorf("happy path rc = %d; want ExitCommitted (0)", rc)
	}

	// Contract audit: every recorded command must be in the whitelist.
	trace := cmdTrace(mock)
	if v := update.AuditRecordedCommands(trace); len(v) != 0 {
		t.Errorf("call-path contract violated on happy path:\n%s", strings.Join(v, "\n"))
	}
	if v := update.AuditWrittenFiles(writtenPaths(mock)); len(v) != 0 {
		t.Errorf("write-path contract violated on happy path:\n%s", strings.Join(v, "\n"))
	}
}

// T2 — Preflight failure blocks rebuild invocation.
func TestUpdateApply_PreflightFail_DoesNotInvokeRebuild(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyApplyHost(mock)
	// Break P-1 (authority_nftban): remove ip nftban table.
	delete(mock.NftTables, "ip:nftban")

	cfg := &config{mode: "upgrade", stateDir: "/var/lib/nftban/state"}
	sf := state.NewStateFile(cfg.stateDir)

	rc := runUpdateApply(context.Background(), mock, sf, cfg, newApplyTestLogger())
	if rc == state.ExitCommitted {
		t.Error("preflight-fail path must not return ExitCommitted")
	}

	// Rebuild must never have been invoked.
	for _, c := range mock.Commands {
		if c.Name == "nftban" && len(c.Args) >= 2 && c.Args[0] == "firewall" && c.Args[1] == "rebuild" {
			t.Error("rebuild invoked despite preflight failure — contract violated")
		}
	}
}

// T3 — Rebuild failure short-circuits before validator invocation.
func TestUpdateApply_RebuildFail_DoesNotInvokeValidator(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyApplyHost(mock)
	mock.RunResults["nftban:firewall:rebuild"] = executor.Result{
		ExitCode: 2,
		Stderr:   "rebuild failed",
	}

	cfg := &config{mode: "upgrade", stateDir: "/var/lib/nftban/state"}
	sf := state.NewStateFile(cfg.stateDir)

	rc := runUpdateApply(context.Background(), mock, sf, cfg, newApplyTestLogger())
	if rc != 2 {
		t.Errorf("rebuild-fail rc = %d; must propagate rebuild's exit (2) without reinterpretation", rc)
	}

	// Validator must never have been invoked — apply must not try to
	// "confirm" a failed rebuild.
	for _, c := range mock.Commands {
		if c.Name == "nftban-validate" {
			t.Error("validator invoked after rebuild failure — contract violated")
		}
	}
}

// T4 — G3-U8 TRUTH GATE: rebuild OK + validator fail → apply FAILS.
// This is the semantic the user called out explicitly: validator wins
// over rebuild. No success coercion, no error downgrading.
func TestUpdateApply_ValidatorFail_OverridesRebuildSuccess(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyApplyHost(mock)
	// Rebuild succeeds, but validator rejects post-state.
	mock.RunResults["nftban:firewall:rebuild"] = executor.Result{ExitCode: 0}
	mock.RunResults["nftban-validate:--json"] = executor.Result{
		ExitCode: 2, // validator exits 2 when state is "down"
		Stderr:   "post-state rejected",
	}

	cfg := &config{mode: "upgrade", stateDir: "/var/lib/nftban/state"}
	sf := state.NewStateFile(cfg.stateDir)

	rc := runUpdateApply(context.Background(), mock, sf, cfg, newApplyTestLogger())
	if rc == state.ExitCommitted {
		t.Error("validator-fail path must NOT return ExitCommitted even though rebuild passed")
	}
	if rc != 2 {
		t.Errorf("validator-fail rc = %d; must propagate validator's exit (2) — truth gate discipline", rc)
	}
}

// T5 — Call-path purity under all failure branches.
func TestUpdateApply_CallPathPurity_AllBranches(t *testing.T) {
	branches := []struct {
		name  string
		setup func(*executor.MockExecutor)
	}{
		{"happy", func(m *executor.MockExecutor) {}},
		{"rebuild-fail", func(m *executor.MockExecutor) {
			m.RunResults["nftban:firewall:rebuild"] = executor.Result{ExitCode: 2}
		}},
		{"validator-fail", func(m *executor.MockExecutor) {
			m.RunResults["nftban-validate:--json"] = executor.Result{ExitCode: 2}
		}},
	}
	for _, b := range branches {
		b := b
		t.Run(b.name, func(t *testing.T) {
			mock := executor.NewMockExecutor()
			seedHappyApplyHost(mock)
			b.setup(mock)
			cfg := &config{mode: "upgrade", stateDir: "/var/lib/nftban/state"}
			sf := state.NewStateFile(cfg.stateDir)

			_ = runUpdateApply(context.Background(), mock, sf, cfg, newApplyTestLogger())

			trace := cmdTrace(mock)
			if v := update.AuditRecordedCommands(trace); len(v) != 0 {
				t.Errorf("call-path contract violated on %s branch:\n%s", b.name, strings.Join(v, "\n"))
			}
			if v := update.AuditWrittenFiles(writtenPaths(mock)); len(v) != 0 {
				t.Errorf("write-path contract violated on %s branch:\n%s", b.name, strings.Join(v, "\n"))
			}
		})
	}
}

// T6 — G3-U5 .conf.local byte-preservation.
// Apply must never write to any *.conf.local path, regardless of outcome.
func TestUpdateApply_NeverTouchesConfLocal(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyApplyHost(mock)
	// Pre-seed a .conf.local so the post-run audit can observe it.
	preContent := []byte("OPERATOR_EDITED=1\n")
	mock.Files["/etc/nftban/nftban.conf.local"] = append([]byte{}, preContent...)

	cfg := &config{mode: "upgrade", stateDir: "/var/lib/nftban/state"}
	sf := state.NewStateFile(cfg.stateDir)

	_ = runUpdateApply(context.Background(), mock, sf, cfg, newApplyTestLogger())

	// Byte hash must match — mock.WrittenFiles only captures writes via
	// the mock's WriteFileAtomic path; apply never writes through it.
	if got, ok := mock.WrittenFiles["/etc/nftban/nftban.conf.local"]; ok {
		t.Errorf("G3-U5 VIOLATION — apply wrote to .conf.local: %q", got)
	}
	// Post-content in Files must still equal pre-content.
	if got, ok := mock.Files["/etc/nftban/nftban.conf.local"]; !ok || string(got) != string(preContent) {
		t.Errorf("G3-U5 VIOLATION — .conf.local bytes changed: pre=%q post=%q", preContent, got)
	}
}
