// =============================================================================
// NFTBan - Tests for time formatting utilities
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="timeutil_format_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for time formatting utilities"
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
// FormatDurationShort tests
// =============================================================================

func TestFormatDurationShort(t *testing.T) {
	tests := []struct {
		name     string
		duration time.Duration
		want     string
	}{
		{"zero", 0, "0s"},
		{"1 second", 1 * time.Second, "1s"},
		{"30 seconds", 30 * time.Second, "30s"},
		{"59 seconds", 59 * time.Second, "59s"},
		{"1 minute", 1 * time.Minute, "1m"},
		{"5 minutes", 5 * time.Minute, "5m"},
		{"59 minutes", 59 * time.Minute, "59m"},
		{"1 hour", 1 * time.Hour, "1h"},
		{"3 hours", 3 * time.Hour, "3h"},
		{"23 hours", 23 * time.Hour, "23h"},
		{"1 day", 24 * time.Hour, "1d"},
		{"7 days", 7 * 24 * time.Hour, "7d"},
		{"30 days", 30 * 24 * time.Hour, "30d"},
		{"90 seconds truncated to minutes", 90 * time.Second, "1m"},
		{"90 minutes truncated to hours", 90 * time.Minute, "1h"},
		{"36 hours truncated to days", 36 * time.Hour, "1d"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := FormatDurationShort(tt.duration); got != tt.want {
				t.Errorf("FormatDurationShort(%v) = %q, want %q", tt.duration, got, tt.want)
			}
		})
	}
}

// =============================================================================
// FormatDurationLong tests
// =============================================================================

func TestFormatDurationLong(t *testing.T) {
	tests := []struct {
		name     string
		duration time.Duration
		want     string
	}{
		{"zero", 0, "0s"},
		{"1 second", 1 * time.Second, "1s"},
		{"45 seconds", 45 * time.Second, "45s"},
		{"1 minute", 1 * time.Minute, "1m"},
		{"5 minutes 30 seconds", 5*time.Minute + 30*time.Second, "5m"},
		{"1 hour", 1 * time.Hour, "1h"},
		{"1 hour 30 minutes", 1*time.Hour + 30*time.Minute, "1h30m"},
		{"2 hours", 2 * time.Hour, "2h"},
		{"1 day", 24 * time.Hour, "1d"},
		{"1 day 5 hours", 29 * time.Hour, "1d5h"},
		{"7 days", 7 * 24 * time.Hour, "7d"},
		{"3 days exact", 3 * 24 * time.Hour, "3d"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := FormatDurationLong(tt.duration); got != tt.want {
				t.Errorf("FormatDurationLong(%v) = %q, want %q", tt.duration, got, tt.want)
			}
		})
	}
}

// =============================================================================
// FormatDurationSeconds tests
// =============================================================================

func TestFormatDurationSeconds(t *testing.T) {
	tests := []struct {
		name    string
		seconds int
		want    string
	}{
		{"zero", 0, "0s"},
		{"30 seconds", 30, "30s"},
		{"60 seconds", 60, "1m"},
		{"3600 seconds", 3600, "1h"},
		{"3661 seconds", 3661, "1h1m"},
		{"86400 seconds", 86400, "1d"},
		{"90000 seconds", 90000, "1d1h"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := FormatDurationSeconds(tt.seconds); got != tt.want {
				t.Errorf("FormatDurationSeconds(%d) = %q, want %q", tt.seconds, got, tt.want)
			}
		})
	}
}

// =============================================================================
// FormatUptime tests
// =============================================================================

func TestFormatUptime(t *testing.T) {
	tests := []struct {
		name    string
		seconds int64
		want    string
	}{
		{"zero", 0, "0m"},
		{"5 minutes", 300, "5m"},
		{"1 hour", 3600, "1h 0m"},
		{"1 hour 30 minutes", 5400, "1h 30m"},
		{"1 day", 86400, "1d 0h 0m"},
		{"1 day 2 hours 30 min", 95400, "1d 2h 30m"},
		{"7 days", 604800, "7d 0h 0m"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := FormatUptime(tt.seconds); got != tt.want {
				t.Errorf("FormatUptime(%d) = %q, want %q", tt.seconds, got, tt.want)
			}
		})
	}
}
