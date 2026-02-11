// =============================================================================
// NFTBan - File Utilities
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="file"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-30"
// meta:description="Centralized file utility functions for NFTBan"
// meta:input="File paths"
// meta:output="File existence checks, file operations"
// meta:depends="os"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package util

import (
	"os"
)

// FileExists checks if a file or directory exists at the given path.
// Returns true if the path exists, false otherwise.
func FileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// IsDir checks if the given path is a directory.
// Returns true if it's a directory, false if it doesn't exist or is a file.
func IsDir(path string) bool {
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	return info.IsDir()
}

// IsFile checks if the given path is a regular file.
// Returns true if it's a file, false if it doesn't exist or is a directory.
func IsFile(path string) bool {
	info, err := os.Stat(path)
	if err != nil {
		return false
	}
	return !info.IsDir()
}
