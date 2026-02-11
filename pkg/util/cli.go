// =============================================================================
// NFTBan - CLI Output Helpers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cli"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-02-06"
// meta:description="Helper functions for processing CLI output"
// meta:input="Raw CLI output strings"
// meta:output="Cleaned/extracted data"
// meta:depends=""
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package util

import "strings"

// ExtractJSONRobust extracts JSON object from CLI output that may have non-JSON prefix/suffix.
// Uses bracket depth tracking for robust extraction (handles nested objects correctly).
// Returns empty string if no valid JSON object is found.
func ExtractJSONRobust(output string) string {
	start := strings.Index(output, "{")
	if start == -1 {
		return ""
	}

	depth := 0
	for i := start; i < len(output); i++ {
		switch output[i] {
		case '{':
			depth++
		case '}':
			depth--
			if depth == 0 {
				return output[start : i+1]
			}
		}
	}
	return ""
}

// StripCommentLines removes lines starting with # from output.
// Useful for cleaning CLI output that includes bash-style comments
// (e.g., "# NFTBAN_CMD_EXIT: 0" lines added by bash wrappers).
func StripCommentLines(output string) string {
	lines := strings.Split(output, "\n")
	var result []string
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if !strings.HasPrefix(trimmed, "#") {
			result = append(result, line)
		}
	}
	return strings.Join(result, "\n")
}
