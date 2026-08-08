// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2024-2026 Antonios Voulvoulis
//
// meta:name="timeutil_parse"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Duration parsing with day/week support"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
package timeutil

import (
	"strconv"
	"strings"
	"time"
)

// ParseDuration parses duration string with day support (e.g., "7d", "24h", "30m")
// Extends standard time.ParseDuration with support for days.
func ParseDuration(s string) (time.Duration, error) {
	s = strings.ToLower(strings.TrimSpace(s))
	if s == "" {
		return 0, nil
	}

	// Handle days suffix
	if strings.HasSuffix(s, "d") {
		days, err := strconv.Atoi(strings.TrimSuffix(s, "d"))
		if err != nil {
			return 0, err
		}
		return time.Duration(days) * 24 * time.Hour, nil
	}

	// Handle weeks suffix
	if strings.HasSuffix(s, "w") {
		weeks, err := strconv.Atoi(strings.TrimSuffix(s, "w"))
		if err != nil {
			return 0, err
		}
		return time.Duration(weeks) * 7 * 24 * time.Hour, nil
	}

	// Fall back to standard parsing
	return time.ParseDuration(s)
}

// ParseDurationDefault parses duration with a default fallback
func ParseDurationDefault(s string, defaultVal time.Duration) time.Duration {
	d, err := ParseDuration(s)
	if err != nil {
		return defaultVal
	}
	return d
}

// ParseSeconds parses duration string and returns seconds
func ParseSeconds(s string) (int, error) {
	d, err := ParseDuration(s)
	if err != nil {
		return 0, err
	}
	return int(d.Seconds()), nil
}
