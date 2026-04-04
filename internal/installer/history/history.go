// =============================================================================
// NFTBan v1.73 - Installer Update History Writer
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-history"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="JSON update history compatible with nftban update history --json"
// meta:inventory.files="internal/installer/history/history.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/var/lib/nftban/update-history.json"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package history

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// DefaultHistoryPath matches the shell CLI location for update-history.json.
// FHS ownership: nftban:nftban, mode 0640.
const DefaultHistoryPath = "/var/lib/nftban/update-history.json"

// MaxEntries is the cap on history entries (matching shell _update_write_history).
const MaxEntries = 9

// Status values matching the shell CLI contract.
const (
	StatusSuccess    = "success"
	StatusInstallFail = "install_fail"
	StatusVerifyFail  = "verify_fail"
)

// Entry represents one install/update history record.
// JSON field names MUST match the shell CLI format exactly for compatibility
// with `nftban update history --json`.
type Entry struct {
	Timestamp  string `json:"timestamp"`
	From       string `json:"from"`
	To         string `json:"to"`
	Status     string `json:"status"`
	Type       string `json:"type"`
	DurationS  int64  `json:"duration_s"`
	Host       string `json:"host"`
}

// WriteEntry prepends a new history entry to the JSON history file.
// Compatible with shell _update_write_history() in cmd_update_helpers.sh.
//
// Behavior:
//   - Creates parent directory if needed
//   - Reads existing entries (tolerates missing/corrupt file)
//   - Prepends new entry at index 0 (newest first)
//   - Keeps at most MaxEntries (9)
//   - Atomic write (temp + rename)
//   - Sets permissions 0640 (matching FHS spec: nftban:nftban 0640)
func WriteEntry(historyPath string, entry Entry) error {
	if historyPath == "" {
		historyPath = DefaultHistoryPath
	}

	// Ensure parent directory
	if err := os.MkdirAll(filepath.Dir(historyPath), 0750); err != nil {
		return fmt.Errorf("create history dir: %w", err)
	}

	// Read existing entries (ok if file missing or corrupt — start fresh)
	var existing []Entry
	if data, err := os.ReadFile(historyPath); err == nil {
		_ = json.Unmarshal(data, &existing) // ignore parse errors — start fresh
	}

	// Prepend new entry (newest first)
	entries := make([]Entry, 0, MaxEntries)
	entries = append(entries, entry)
	for i, e := range existing {
		if i >= MaxEntries-1 {
			break
		}
		entries = append(entries, e)
	}

	// Marshal with indentation for human readability (matches jq output)
	data, err := json.MarshalIndent(entries, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal history: %w", err)
	}
	data = append(data, '\n')

	// Atomic write: temp file + rename
	tmpPath := historyPath + ".tmp"
	if err := os.WriteFile(tmpPath, data, 0640); err != nil {
		return fmt.Errorf("write history temp: %w", err)
	}
	if err := os.Rename(tmpPath, historyPath); err != nil {
		os.Remove(tmpPath)
		return fmt.Errorf("rename history: %w", err)
	}

	// Ensure correct permissions (FHS: 0640)
	os.Chmod(historyPath, 0640)

	return nil
}

// NewEntry creates a history entry with the current UTC timestamp and hostname.
func NewEntry(fromVersion, toVersion, status, installType string, durationSecs int64, hostname string) Entry {
	return Entry{
		Timestamp: time.Now().UTC().Format("2006-01-02T15:04:05Z"),
		From:      fromVersion,
		To:        toVersion,
		Status:    status,
		Type:      installType,
		DurationS: durationSecs,
		Host:      hostname,
	}
}
