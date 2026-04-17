// =============================================================================
// NFTBan v1.97 - Lifecycle Output Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="lifecycle-output-test"
// meta:type="test"
// meta:version="1.97.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-17"
// meta:description="Tests for lifecycle JSON and text output rendering"
// meta:inventory.files="internal/lifecycle/output_test.go"
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
	"time"
)

func makeTestResult() RunResult {
	r := RunResult{
		SchemaVersion: OutputSchemaVersion,
		Mode:          ModeInstall,
		DryRun:        true,
		Stage:         StageFinal,
		Outcome:       OutcomeSuccess,
		LastOperation: LastOperation{
			Result:            "SUCCESS",
			RecoveryPending:   false,
			LastRebuildFailed: false,
		},
		Plan: Plan{
			Actions:  []Action{ActionTakeAuthority},
			Warnings: []string{"first install"},
		},
		Detection: Detection{
			KernelValid:         true,
			ValidatorConsistent: true,
			SSHSafe:             true,
		},
		Timestamp: time.Date(2026, 4, 17, 12, 0, 0, 0, time.UTC),
	}
	r.Authority.Prior = AuthorityState{Owner: AuthorityNone, Health: HealthDown}
	r.Authority.Desired = AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}
	r.Authority.Resulting = AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}
	return r
}

func TestRenderJSON(t *testing.T) {
	var buf bytes.Buffer
	result := makeTestResult()

	if err := RenderJSON(&buf, result); err != nil {
		t.Fatalf("RenderJSON: %v", err)
	}

	output := buf.String()

	// Must contain schema version
	if !strings.Contains(output, `"schema_version": "1.0"`) {
		t.Error("JSON must contain schema_version 1.0")
	}

	// Must contain outcome
	if !strings.Contains(output, `"outcome": "SUCCESS"`) {
		t.Error("JSON must contain outcome")
	}

	// Must contain authority
	if !strings.Contains(output, `"owner": "NFTBAN"`) {
		t.Error("JSON must contain authority owner")
	}

	// Must parse back
	var parsed RunResult
	if err := json.Unmarshal(buf.Bytes(), &parsed); err != nil {
		t.Fatalf("roundtrip parse: %v", err)
	}
	if parsed.Outcome != OutcomeSuccess {
		t.Errorf("parsed outcome = %s; want SUCCESS", parsed.Outcome)
	}
}

func TestRenderJSONPreservesV196Truths(t *testing.T) {
	var buf bytes.Buffer
	result := makeTestResult()
	result.LastOperation = LastOperation{
		Result:            "FAILED_RECOVERED",
		FailureClass:      "POSTVALIDATION_REGRESSION",
		RecoveryPending:   false,
		LastRebuildFailed: true,
	}

	if err := RenderJSON(&buf, result); err != nil {
		t.Fatalf("RenderJSON: %v", err)
	}

	output := buf.String()

	// INV-LC-003: v1.96 results must be present
	if !strings.Contains(output, `"result": "FAILED_RECOVERED"`) {
		t.Error("must contain v1.96 operation result")
	}
	if !strings.Contains(output, `"failure_class": "POSTVALIDATION_REGRESSION"`) {
		t.Error("must contain v1.96 failure class")
	}
	if !strings.Contains(output, `"last_rebuild_failed": true`) {
		t.Error("must contain last_rebuild_failed flag")
	}
}

func TestRenderText(t *testing.T) {
	var buf bytes.Buffer
	result := makeTestResult()

	if err := RenderText(&buf, result); err != nil {
		t.Fatalf("RenderText: %v", err)
	}

	output := buf.String()

	if !strings.Contains(output, "DRY-RUN") {
		t.Error("text must indicate dry-run")
	}
	if !strings.Contains(output, "TAKE_AUTHORITY") {
		t.Error("text must contain action")
	}
	if !strings.Contains(output, "Outcome: SUCCESS") {
		t.Error("text must contain outcome")
	}
	if !strings.Contains(output, "NFTBAN") {
		t.Error("text must contain authority owner")
	}
}

func TestRenderTextWithV196Recovery(t *testing.T) {
	var buf bytes.Buffer
	result := makeTestResult()
	result.LastOperation = LastOperation{
		Result:            "FAILED_RECOVERED",
		FailureClass:      "MODULE_RESTORE_INCOMPLETE",
		RecoveryPending:   true,
		LastRebuildFailed: true,
	}

	if err := RenderText(&buf, result); err != nil {
		t.Fatalf("RenderText: %v", err)
	}

	output := buf.String()
	if !strings.Contains(output, "FAILED_RECOVERED") {
		t.Error("text must show v1.96 operation result")
	}
	if !strings.Contains(output, "MODULE_RESTORE_INCOMPLETE") {
		t.Error("text must show failure class")
	}
}

func TestParseRunResult(t *testing.T) {
	result := makeTestResult()
	data, _ := json.MarshalIndent(result, "", "  ")

	parsed, err := ParseRunResult(data)
	if err != nil {
		t.Fatalf("ParseRunResult: %v", err)
	}
	if parsed.Outcome != OutcomeSuccess {
		t.Errorf("parsed outcome = %s; want SUCCESS", parsed.Outcome)
	}
	if parsed.Authority.Resulting.Owner != AuthorityNFTBan {
		t.Errorf("parsed resulting owner = %s; want NFTBAN", parsed.Authority.Resulting.Owner)
	}
}

func TestParseRunResultInvalid(t *testing.T) {
	_, err := ParseRunResult([]byte("not json"))
	if err == nil {
		t.Error("expected error for invalid JSON")
	}
}

func TestSchemaVersionAlwaysSet(t *testing.T) {
	var buf bytes.Buffer
	result := RunResult{} // empty result, no schema version set
	if err := RenderJSON(&buf, result); err != nil {
		t.Fatalf("RenderJSON: %v", err)
	}

	var parsed RunResult
	json.Unmarshal(buf.Bytes(), &parsed)
	if parsed.SchemaVersion != OutputSchemaVersion {
		t.Errorf("schema_version = %s; want %s (must always be set by RenderJSON)", parsed.SchemaVersion, OutputSchemaVersion)
	}
}

func TestJSONFieldStability(t *testing.T) {
	// Snapshot test: verify specific field names exist in JSON output.
	// This prevents accidental field renames that would break consumers.
	var buf bytes.Buffer
	result := makeTestResult()
	RenderJSON(&buf, result)
	output := buf.String()

	requiredFields := []string{
		`"schema_version"`,
		`"mode"`,
		`"dry_run"`,
		`"stage"`,
		`"outcome"`,
		`"authority"`,
		`"prior"`,
		`"desired"`,
		`"resulting"`,
		`"owner"`,
		`"health"`,
		`"last_operation"`,
		`"result"`,
		`"failure_class"`,
		`"recovery_pending"`,
		`"last_rebuild_failed"`,
		`"plan"`,
		`"actions"`,
		`"warnings"`,
		`"detection"`,
		`"conflicting_firewall"`,
		`"kernel_valid"`,
		`"validator_consistent"`,
		`"ssh_safe"`,
		`"timestamp"`,
	}

	for _, field := range requiredFields {
		if !strings.Contains(output, field) {
			t.Errorf("JSON output missing required field: %s", field)
		}
	}
}
