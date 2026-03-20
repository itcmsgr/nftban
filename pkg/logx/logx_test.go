// =============================================================================
// NFTBan v1.0 - Structured Logging Wrappers Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="logx_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Unit tests for logx Sprintf and category logging helpers"
// meta:input="Test cases"
// meta:output="Test results"
// meta:depends="testing"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package logx

import (
	"testing"
)

// =============================================================================
// Sprintf Tests
// =============================================================================

func TestSprintf(t *testing.T) {
	tests := []struct {
		name     string
		category string
		format   string
		args     []any
		want     string
	}{
		{
			name:     "simple_message",
			category: "AUTH",
			format:   "User %s logged in",
			args:     []any{"admin"},
			want:     "[AUTH] User admin logged in",
		},
		{
			name:     "no_args",
			category: "FIREWALL",
			format:   "Rules loaded successfully",
			args:     nil,
			want:     "[FIREWALL] Rules loaded successfully",
		},
		{
			name:     "multiple_args",
			category: "SECURITY",
			format:   "IP %s blocked (count: %d, reason: %s)",
			args:     []any{"1.2.3.4", 5, "portscan"},
			want:     "[SECURITY] IP 1.2.3.4 blocked (count: 5, reason: portscan)",
		},
		{
			name:     "empty_category",
			category: "",
			format:   "test message",
			args:     nil,
			want:     "[] test message",
		},
		{
			name:     "numeric_format",
			category: "METRICS",
			format:   "Processed %d events in %.2fs",
			args:     []any{1000, 1.5},
			want:     "[METRICS] Processed 1000 events in 1.50s",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := Sprintf(tt.category, tt.format, tt.args...)
			if got != tt.want {
				t.Errorf("Sprintf(%q, %q, ...) = %q, want %q", tt.category, tt.format, got, tt.want)
			}
		})
	}
}
