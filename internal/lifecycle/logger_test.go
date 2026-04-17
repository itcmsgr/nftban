// =============================================================================
// NFTBan v1.97 - Lifecycle Logger Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="lifecycle-logger-test"
// meta:type="test"
// meta:version="1.97.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-17"
// meta:description="Tests for lifecycle evidence logging"
// meta:inventory.files="internal/lifecycle/logger_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package lifecycle

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestLogDetect(t *testing.T) {
	var buf bytes.Buffer
	l := NewLogger(&buf, ModeInstall, true)

	l.LogDetect(
		AuthorityState{Owner: AuthorityNone, Health: HealthDown},
		Detection{KernelValid: false, SSHSafe: true},
	)

	output := buf.String()
	if !strings.Contains(output, `"event":"detect"`) {
		t.Error("log must contain event=detect")
	}
	if !strings.Contains(output, `"dry_run":true`) {
		t.Error("log must contain dry_run flag")
	}
	if !strings.Contains(output, `"mode":"install"`) {
		t.Error("log must contain mode")
	}

	// Must be valid JSON
	var event LogEvent
	if err := json.Unmarshal([]byte(strings.TrimSpace(output)), &event); err != nil {
		t.Fatalf("log output not valid JSON: %v", err)
	}
}

func TestLogPlan(t *testing.T) {
	var buf bytes.Buffer
	l := NewLogger(&buf, ModeUpdate, true)

	l.LogPlan(
		Plan{
			Actions:  []Action{ActionPreserveAuthority},
			Warnings: []string{"degraded state"},
		},
		LastOperation{
			Result:            "FAILED_RECOVERED",
			LastRebuildFailed: true,
		},
	)

	output := buf.String()
	if !strings.Contains(output, `"event":"plan"`) {
		t.Error("log must contain event=plan")
	}
	if !strings.Contains(output, "PRESERVE_AUTHORITY") {
		t.Error("log must contain action")
	}
	if !strings.Contains(output, "FAILED_RECOVERED") {
		t.Error("log must contain v1.96 operation result")
	}
}

func TestLogResult(t *testing.T) {
	var buf bytes.Buffer
	l := NewLogger(&buf, ModeInstall, true)

	result := RunResult{
		Outcome: OutcomeSuccess,
		Stage:   StageFinal,
	}
	result.Authority.Resulting = AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}

	l.LogResult(result)

	output := buf.String()
	if !strings.Contains(output, `"event":"result"`) {
		t.Error("log must contain event=result")
	}
	if !strings.Contains(output, "plan_completed") {
		t.Error("dry-run result must say plan_completed, not execution_completed")
	}
	if !strings.Contains(output, "SUCCESS") {
		t.Error("log must contain outcome")
	}
}

func TestLogResultExecution(t *testing.T) {
	var buf bytes.Buffer
	l := NewLogger(&buf, ModeInstall, false) // NOT dry-run

	result := RunResult{Outcome: OutcomeSuccess, Stage: StageFinal}
	result.Authority.Resulting = AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}

	l.LogResult(result)

	output := buf.String()
	if !strings.Contains(output, "execution_completed") {
		t.Error("non-dry-run result must say execution_completed")
	}
}

func TestLogOutputIsJSONL(t *testing.T) {
	var buf bytes.Buffer
	l := NewLogger(&buf, ModeInstall, true)

	l.LogDetect(AuthorityState{Owner: AuthorityNone, Health: HealthDown}, Detection{})
	l.LogPlan(Plan{Actions: []Action{ActionTakeAuthority}}, LastOperation{})
	l.LogResult(RunResult{Outcome: OutcomeSuccess, Stage: StageFinal})

	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) != 3 {
		t.Errorf("expected 3 JSONL lines, got %d", len(lines))
	}

	for i, line := range lines {
		var event LogEvent
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			t.Errorf("line %d not valid JSON: %v", i+1, err)
		}
	}
}
