// =============================================================================
// NFTBan - Tests for time parsing utilities
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="timeutil_parse_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for time parsing utilities"
// meta:input="None"
// meta:output="None"
// meta:depends="testing"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package timeutil

import (
	"testing"
	"time"
)

// =============================================================================
// ParseDuration tests
// =============================================================================

func TestParseDuration(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    time.Duration
		wantErr bool
	}{
		// Days
		{"1 day", "1d", 24 * time.Hour, false},
		{"7 days", "7d", 7 * 24 * time.Hour, false},
		{"30 days", "30d", 30 * 24 * time.Hour, false},
		{"uppercase D", "7D", 7 * 24 * time.Hour, false},

		// Weeks
		{"1 week", "1w", 7 * 24 * time.Hour, false},
		{"2 weeks", "2w", 14 * 24 * time.Hour, false},
		{"uppercase W", "1W", 7 * 24 * time.Hour, false},

		// Standard Go durations
		{"hours", "24h", 24 * time.Hour, false},
		{"minutes", "30m", 30 * time.Minute, false},
		{"seconds", "60s", 60 * time.Second, false},
		{"milliseconds", "100ms", 100 * time.Millisecond, false},
		{"compound", "1h30m", 1*time.Hour + 30*time.Minute, false},

		// Edge cases
		{"empty", "", 0, false},
		{"spaces", "  7d  ", 7 * 24 * time.Hour, false},
		{"zero days", "0d", 0, false},
		{"zero weeks", "0w", 0, false},

		// Errors
		{"invalid day", "abcd", 0, true},
		{"invalid week", "abcw", 0, true},
		{"completely invalid", "not-a-duration", 0, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ParseDuration(tt.input)
			if (err != nil) != tt.wantErr {
				t.Errorf("ParseDuration(%q) error = %v, wantErr %v", tt.input, err, tt.wantErr)
				return
			}
			if err != nil {
				return
			}
			if got != tt.want {
				t.Errorf("ParseDuration(%q) = %v, want %v", tt.input, got, tt.want)
			}
		})
	}
}

// =============================================================================
// ParseDurationDefault tests
// =============================================================================

func TestParseDurationDefault(t *testing.T) {
	defaultVal := 5 * time.Minute

	tests := []struct {
		name  string
		input string
		want  time.Duration
	}{
		{"valid days", "7d", 7 * 24 * time.Hour},
		{"valid hours", "2h", 2 * time.Hour},
		{"invalid -> default", "invalid", defaultVal},
		{"empty -> zero", "", 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ParseDurationDefault(tt.input, defaultVal)
			if got != tt.want {
				t.Errorf("ParseDurationDefault(%q, %v) = %v, want %v",
					tt.input, defaultVal, got, tt.want)
			}
		})
	}
}

// =============================================================================
// ParseSeconds tests
// =============================================================================

func TestParseSeconds(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    int
		wantErr bool
	}{
		{"1 day in seconds", "1d", 86400, false},
		{"1 hour in seconds", "1h", 3600, false},
		{"30 minutes in seconds", "30m", 1800, false},
		{"1 week in seconds", "1w", 604800, false},
		{"60 seconds", "60s", 60, false},
		{"empty", "", 0, false},
		{"invalid", "invalid", 0, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ParseSeconds(tt.input)
			if (err != nil) != tt.wantErr {
				t.Errorf("ParseSeconds(%q) error = %v, wantErr %v", tt.input, err, tt.wantErr)
				return
			}
			if err != nil {
				return
			}
			if got != tt.want {
				t.Errorf("ParseSeconds(%q) = %d, want %d", tt.input, got, tt.want)
			}
		})
	}
}
