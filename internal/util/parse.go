// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="util_parse"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Common parsing utilities (bool, float, int)"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
package util

import (
	"strconv"
	"strings"
)

// ParseBool parses boolean string with multiple formats.
// Recognizes: true/false, yes/no, 1/0, on/off
func ParseBool(s string, defaultVal bool) bool {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "true", "yes", "1", "on", "enabled":
		return true
	case "false", "no", "0", "off", "disabled":
		return false
	default:
		return defaultVal
	}
}

// ParseFloat parses float string with default fallback
func ParseFloat(s string, defaultVal float64) float64 {
	s = strings.TrimSpace(s)
	if s == "" {
		return defaultVal
	}
	if f, err := strconv.ParseFloat(s, 64); err == nil {
		return f
	}
	return defaultVal
}

// ParseInt parses int string with default fallback
func ParseInt(s string, defaultVal int) int {
	s = strings.TrimSpace(s)
	if s == "" {
		return defaultVal
	}
	if i, err := strconv.Atoi(s); err == nil {
		return i
	}
	return defaultVal
}

// ParseInt64 parses int64 string with default fallback
func ParseInt64(s string, defaultVal int64) int64 {
	s = strings.TrimSpace(s)
	if s == "" {
		return defaultVal
	}
	if i, err := strconv.ParseInt(s, 10, 64); err == nil {
		return i
	}
	return defaultVal
}

// ParseUint parses unsigned int string with default fallback
func ParseUint(s string, defaultVal uint64) uint64 {
	s = strings.TrimSpace(s)
	if s == "" {
		return defaultVal
	}
	if i, err := strconv.ParseUint(s, 10, 64); err == nil {
		return i
	}
	return defaultVal
}
