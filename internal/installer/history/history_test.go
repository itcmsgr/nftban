// =============================================================================
// NFTBan v1.73 - Installer Update History Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-history-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Tests for JSON history compatibility with nftban update history --json"
// meta:inventory.files="internal/installer/history/history_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package history

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestWriteEntry_NewFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "update-history.json")

	entry := NewEntry("1.72.0", "1.73.0", StatusSuccess, "rpm", 45, "lab4.mywebhost.gr")
	if err := WriteEntry(path, entry); err != nil {
		t.Fatalf("WriteEntry: %v", err)
	}

	// Read and verify JSON structure
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}

	var entries []Entry
	if err := json.Unmarshal(data, &entries); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected 1 entry, got %d", len(entries))
	}
	if entries[0].From != "1.72.0" {
		t.Errorf("From = %s, want 1.72.0", entries[0].From)
	}
	if entries[0].To != "1.73.0" {
		t.Errorf("To = %s, want 1.73.0", entries[0].To)
	}
	if entries[0].Status != "success" {
		t.Errorf("Status = %s, want success", entries[0].Status)
	}
	if entries[0].Type != "rpm" {
		t.Errorf("Type = %s, want rpm", entries[0].Type)
	}
	if entries[0].DurationS != 45 {
		t.Errorf("DurationS = %d, want 45", entries[0].DurationS)
	}
	if entries[0].Host != "lab4.mywebhost.gr" {
		t.Errorf("Host = %s, want lab4.mywebhost.gr", entries[0].Host)
	}
}

func TestWriteEntry_Prepend(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "update-history.json")

	// Write first entry
	e1 := NewEntry("1.71.0", "1.72.0", StatusSuccess, "rpm", 30, "lab.mywebhost.gr")
	if err := WriteEntry(path, e1); err != nil {
		t.Fatalf("WriteEntry 1: %v", err)
	}

	// Write second entry (should be prepended)
	e2 := NewEntry("1.72.0", "1.73.0", StatusVerifyFail, "rpm", 55, "lab4.mywebhost.gr")
	if err := WriteEntry(path, e2); err != nil {
		t.Fatalf("WriteEntry 2: %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}

	var entries []Entry
	if err := json.Unmarshal(data, &entries); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected 2 entries, got %d", len(entries))
	}
	// Newest first
	if entries[0].To != "1.73.0" {
		t.Errorf("entries[0].To = %s, want 1.73.0 (newest first)", entries[0].To)
	}
	if entries[1].To != "1.72.0" {
		t.Errorf("entries[1].To = %s, want 1.72.0", entries[1].To)
	}
}

func TestWriteEntry_Cap9(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "update-history.json")

	// Write 12 entries — should keep only 9
	for i := 0; i < 12; i++ {
		e := NewEntry("1.60.0", "1.61.0", StatusSuccess, "rpm", int64(i+1), "test")
		if err := WriteEntry(path, e); err != nil {
			t.Fatalf("WriteEntry %d: %v", i, err)
		}
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}

	var entries []Entry
	if err := json.Unmarshal(data, &entries); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if len(entries) != MaxEntries {
		t.Errorf("expected %d entries (capped), got %d", MaxEntries, len(entries))
	}
}

func TestWriteEntry_CorruptExisting(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "update-history.json")

	// Write corrupt JSON
	os.WriteFile(path, []byte("not json"), 0640)

	// Should succeed — start fresh
	e := NewEntry("1.72.0", "1.73.0", StatusSuccess, "rpm", 10, "test")
	if err := WriteEntry(path, e); err != nil {
		t.Fatalf("WriteEntry over corrupt: %v", err)
	}

	data, _ := os.ReadFile(path)
	var entries []Entry
	if err := json.Unmarshal(data, &entries); err != nil {
		t.Fatalf("Unmarshal: %v", err)
	}
	if len(entries) != 1 {
		t.Errorf("expected 1 entry, got %d", len(entries))
	}
}

func TestWriteEntry_ShellCompatibleJSON(t *testing.T) {
	// Verify the JSON output is readable by shell: jq '.[0].status' ...
	dir := t.TempDir()
	path := filepath.Join(dir, "update-history.json")

	e := NewEntry("1.72.0", "1.73.0", "success", "rpm", 45, "lab4.mywebhost.gr")
	if err := WriteEntry(path, e); err != nil {
		t.Fatalf("WriteEntry: %v", err)
	}

	data, _ := os.ReadFile(path)

	// Parse as generic JSON to verify field names match shell contract
	var raw []map[string]interface{}
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatalf("Unmarshal raw: %v", err)
	}

	// Verify all 7 fields are present with correct names
	required := []string{"timestamp", "from", "to", "status", "type", "duration_s", "host"}
	for _, field := range required {
		if _, ok := raw[0][field]; !ok {
			t.Errorf("missing required field %q in JSON output", field)
		}
	}

	// Verify duration_s is a number (not string)
	switch raw[0]["duration_s"].(type) {
	case float64:
		// OK — json.Unmarshal decodes numbers as float64
	default:
		t.Errorf("duration_s should be a number, got %T", raw[0]["duration_s"])
	}
}

func TestWriteEntry_Permissions(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "update-history.json")

	e := NewEntry("1.72.0", "1.73.0", StatusSuccess, "rpm", 10, "test")
	if err := WriteEntry(path, e); err != nil {
		t.Fatalf("WriteEntry: %v", err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("Stat: %v", err)
	}
	perm := info.Mode().Perm()
	if perm != 0640 {
		t.Errorf("permissions = %o, want 0640", perm)
	}
}
