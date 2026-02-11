// =============================================================================
// NFTBan - Format Utilities
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="format"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-30"
// meta:description="Centralized formatting functions for NFTBan"
// meta:input="Numeric values"
// meta:output="Formatted strings"
// meta:depends="fmt"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package util

import "fmt"

// FormatBytes formats a byte count into a human-readable string.
// Uses binary units (1024-based): B, KB, MB, GB, TB, PB, EB.
func FormatBytes(bytes int64) string {
	const unit = 1024
	if bytes < unit {
		return fmt.Sprintf("%d B", bytes)
	}
	div, exp := int64(unit), 0
	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", float64(bytes)/float64(div), "KMGTPE"[exp])
}

// FormatBytesUint formats an unsigned byte count into a human-readable string.
func FormatBytesUint(bytes uint64) string {
	return FormatBytes(int64(bytes))
}
