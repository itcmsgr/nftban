// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-core-logretention-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="Tests the logretention status view builder: NOT_GENERATED when no state exists (still reports live filesystem facts); VALIDATED + populated per-family policy from an authoritative state; STATE_UNPARSEABLE on corrupt state; staleness detected when the live operator config diverges from the state's overrides (and NOT flagged for the auto/empty equivalence); no fabricated cleanup/timer fields."
// meta:inventory.files="cmd/nftban-core/cmd_logretention.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_LR_STATE,NFTBAN_LR_LOGDIR,NFTBAN_LR_NFTBANLOG,NFTBAN_LR_CONF"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	lr "github.com/itcmsgr/nftban/internal/logretention"
)

func setEnvPaths(t *testing.T, state, conf, dir string) {
	t.Setenv("NFTBAN_LR_STATE", state)
	t.Setenv("NFTBAN_LR_LOGDIR", os.TempDir()) // a real fs for statfs
	t.Setenv("NFTBAN_LR_NFTBANLOG", dir)
	t.Setenv("NFTBAN_LR_CONF", conf)
}

func TestStatusNotGenerated(t *testing.T) {
	dir := t.TempDir()
	setEnvPaths(t, filepath.Join(dir, "absent.json"), filepath.Join(dir, "absent.conf"), dir)
	s := buildStatus()
	if s.StateAvailable || s.ValidationStatus != "NOT_GENERATED" {
		t.Errorf("want NOT_GENERATED/unavailable, got %s/%v", s.ValidationStatus, s.StateAvailable)
	}
	if s.FilesystemTotalBytes == 0 {
		t.Error("live filesystem facts should be populated even without state")
	}
}

func writeState(t *testing.T, dir string, gs lr.GeneratedState) string {
	t.Helper()
	b, _ := json.Marshal(gs)
	p := filepath.Join(dir, "state.json")
	if err := os.WriteFile(p, b, 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestStatusPopulatedNotStale(t *testing.T) {
	dir := t.TempDir()
	gs := lr.GeneratedState{
		PolicyVersion: "1", GeneratorVersion: "1", Profile: lr.Profile{Name: "standard"},
		BudgetBytes: 7 * lr.GiB, TheoreticalMaxBytes: 6 * lr.GiB, FitVerdict: "FITS",
		ValidationOK: true, Overrides: lr.Overrides{Mode: "auto"},
		ActivePolicyHashes: map[string]string{"nftban": "abc123"},
		Families:           []lr.FamilyPolicy{{Key: "bans", RotateCount: 5, SizeCapBytes: 10 * lr.MiB, RetentionDays: 30, ForensicFloorDays: 30, WorstCaseBytes: 50 * lr.MiB}},
	}
	state := writeState(t, dir, gs)
	conf := filepath.Join(dir, "logs.conf")
	_ = os.WriteFile(conf, []byte(`LOG_RETENTION_MODE="auto"`+"\n"), 0o644)
	setEnvPaths(t, state, conf, dir)

	s := buildStatus()
	if !s.StateAvailable || s.ValidationStatus != "VALIDATED" {
		t.Fatalf("want VALIDATED, got %s", s.ValidationStatus)
	}
	if s.StateStale {
		t.Error("auto (state) vs auto (conf) must NOT be stale")
	}
	if len(s.PerFamilyPolicy) != 1 || s.PerFamilyPolicy[0].ForensicFloorDays != 30 {
		t.Errorf("per-family policy/forensic floor not surfaced: %+v", s.PerFamilyPolicy)
	}
	if s.EffectiveBudgetBytes != 7*lr.GiB {
		t.Errorf("budget not surfaced: %d", s.EffectiveBudgetBytes)
	}
}

func TestStatusStaleOnConfigChange(t *testing.T) {
	dir := t.TempDir()
	gs := lr.GeneratedState{PolicyVersion: "1", ValidationOK: true, Overrides: lr.Overrides{Mode: "auto"}, Profile: lr.Profile{Name: "standard"}}
	state := writeState(t, dir, gs)
	conf := filepath.Join(dir, "logs.conf")
	_ = os.WriteFile(conf, []byte("LOG_RETENTION_MODE=\"fixed\"\nLOG_RETENTION_MAX_PERCENT=\"20\"\n"), 0o644)
	setEnvPaths(t, state, conf, dir)

	s := buildStatus()
	if !s.StateStale {
		t.Error("live config (fixed/20%) diverges from state (auto) → should be stale")
	}
}

func TestStatusUnparseable(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "state.json")
	_ = os.WriteFile(p, []byte("{ not json"), 0o644)
	setEnvPaths(t, p, filepath.Join(dir, "absent.conf"), dir)
	s := buildStatus()
	if s.StateAvailable || s.ValidationStatus != "STATE_UNPARSEABLE" {
		t.Errorf("want STATE_UNPARSEABLE/unavailable, got %s/%v", s.ValidationStatus, s.StateAvailable)
	}
}

func TestStatusJSONHasNoFabricatedFields(t *testing.T) {
	dir := t.TempDir()
	setEnvPaths(t, filepath.Join(dir, "absent.json"), filepath.Join(dir, "absent.conf"), dir)
	b, _ := json.Marshal(buildStatus())
	for _, forbidden := range []string{"bytes_reclaimed", "last_cleanup", "next_trigger", "timer_"} {
		if containsJSONKey(string(b), forbidden) {
			t.Errorf("status JSON must not contain fabricated field %q", forbidden)
		}
	}
}

func containsJSONKey(s, key string) bool {
	return len(s) > 0 && (indexOf(s, "\""+key) >= 0)
}

func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}

func TestStatusActiveDriftAndLiveFacts(t *testing.T) {
	dir := t.TempDir()
	main := filepath.Join(dir, "nftban")
	suri := filepath.Join(dir, "nftban-suricata")
	state := filepath.Join(dir, "state.json")
	if _, err := lr.Generate(lr.GenerateOptions{
		MainPath: main, SuricataPath: suri, StatePath: state,
		Disk:      lr.DiskFacts{TotalBytes: 50 * lr.GiB, AvailBytes: 30 * lr.GiB},
		Validator: func([]string) (string, error) { return "stub", nil },
		Now:       time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	conf := filepath.Join(dir, "logs.conf")
	_ = os.WriteFile(conf, []byte(`LOG_RETENTION_MODE="auto"`+"\n"), 0o644)
	t.Setenv("NFTBAN_LR_STATE", state)
	t.Setenv("NFTBAN_LR_MAIN", main)
	t.Setenv("NFTBAN_LR_SURICATA", suri)
	t.Setenv("NFTBAN_LR_LOGDIR", os.TempDir())
	t.Setenv("NFTBAN_LR_NFTBANLOG", dir)
	t.Setenv("NFTBAN_LR_CONF", conf)

	// clean generation -> ACTIVE_MATCH, live fit computed, detected profile set, semantic classes present
	s := buildStatus()
	if s.OverallState != "ACTIVE_MATCH" {
		t.Errorf("clean state should be ACTIVE_MATCH, got %s", s.OverallState)
	}
	if s.LiveFitVerdict == "" || s.DetectedProfile == "" {
		t.Error("live fit / detected profile not populated")
	}
	var sawEnforcement bool
	for _, f := range s.PerFamilyPolicy {
		if f.SemanticClass == "ENFORCEMENT_AUDIT" {
			sawEnforcement = true
		}
	}
	if !sawEnforcement {
		t.Error("per-family semantic class not surfaced (no ENFORCEMENT_AUDIT)")
	}

	// hand-edit the activated main policy -> content drift must be DETECTED (live re-hash)
	_ = os.WriteFile(main, []byte("# operator hand-edit\n"), 0o644)
	s2 := buildStatus()
	if s2.OverallState != "ACTIVE_DRIFT" {
		t.Errorf("hand-edit should surface ACTIVE_DRIFT, got %s", s2.OverallState)
	}
	if s2.ActivePolicyDrift["nftban"] != "drift" {
		t.Errorf("main policy drift not detected: %v", s2.ActivePolicyDrift)
	}
}
