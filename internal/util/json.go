// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2024-2026 Antonios Voulvoulis
//
// Package util provides common utility functions for NFTBan.
//
// meta:name="util"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Common utility functions (JSON, parsing, etc.)"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
package util

import "strings"

// ExtractJSON extracts JSON object from mixed output string.
// Useful for parsing CLI output that may contain non-JSON text.
func ExtractJSON(output string) string {
	output = strings.TrimSpace(output)
	startIdx := strings.Index(output, "{")
	endIdx := strings.LastIndex(output, "}")
	if startIdx == -1 || endIdx == -1 || startIdx > endIdx {
		return "{}"
	}
	return output[startIdx : endIdx+1]
}

// ExtractJSONArray extracts JSON array from mixed output string.
func ExtractJSONArray(output string) string {
	output = strings.TrimSpace(output)
	startIdx := strings.Index(output, "[")
	endIdx := strings.LastIndex(output, "]")
	if startIdx == -1 || endIdx == -1 || startIdx > endIdx {
		return "[]"
	}
	return output[startIdx : endIdx+1]
}

// IsJSON checks if a string looks like valid JSON (starts with { or [)
func IsJSON(s string) bool {
	s = strings.TrimSpace(s)
	return (strings.HasPrefix(s, "{") && strings.HasSuffix(s, "}")) ||
		(strings.HasPrefix(s, "[") && strings.HasSuffix(s, "]"))
}
