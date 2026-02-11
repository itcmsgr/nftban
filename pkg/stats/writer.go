// =============================================================================
// NFTBan v1.0 - Atomic File Writer
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="writer"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Atomic file writes using write-temp + fsync + rename pattern"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package stats

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// WriteJSONAtomic writes data to a file atomically.
// Pattern: write to temp file -> fsync -> rename
// This ensures the file is never partially written.
func WriteJSONAtomic(path string, data interface{}) error {
	// Ensure directory exists
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0750); err != nil {
		return fmt.Errorf("failed to create directory %s: %w", dir, err)
	}

	// Create temp file in same directory (for atomic rename)
	tempPath := path + ".tmp"
	f, err := os.OpenFile(tempPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0640)
	if err != nil {
		return fmt.Errorf("failed to create temp file %s: %w", tempPath, err)
	}

	// Encode JSON with indentation for readability
	encoder := json.NewEncoder(f)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(data); err != nil {
		f.Close()
		os.Remove(tempPath)
		return fmt.Errorf("failed to encode JSON: %w", err)
	}

	// Sync to disk before rename
	if err := f.Sync(); err != nil {
		f.Close()
		os.Remove(tempPath)
		return fmt.Errorf("failed to sync file: %w", err)
	}

	if err := f.Close(); err != nil {
		os.Remove(tempPath)
		return fmt.Errorf("failed to close file: %w", err)
	}

	// Atomic rename
	if err := os.Rename(tempPath, path); err != nil {
		os.Remove(tempPath)
		return fmt.Errorf("failed to rename temp file: %w", err)
	}

	return nil
}

// ReadJSON reads a JSON file, tolerating missing/partial files.
// Returns nil, nil if file doesn't exist (not an error).
// Returns data, nil on success.
// Returns nil, error on parse failure.
func ReadJSON(path string, data interface{}) error {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil // File doesn't exist - not an error
		}
		return fmt.Errorf("failed to open file %s: %w", path, err)
	}
	defer f.Close()

	if err := json.NewDecoder(f).Decode(data); err != nil {
		return fmt.Errorf("failed to decode JSON from %s: %w", path, err)
	}

	return nil
}

// FileExists checks if a file exists
func FileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// FileModTime returns the modification time of a file
// Returns zero time if file doesn't exist
func FileModTime(path string) (int64, error) {
	info, err := os.Stat(path)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	return info.ModTime().Unix(), nil
}
