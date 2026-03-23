// =============================================================================
// NFTBan - Metrics Package Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="metrics_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for metrics package: collector types, recording functions, status code helper"
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

package metrics

import (
	"testing"
)

// =============================================================================
// statusCodeString Tests
// =============================================================================

func TestStatusCodeString(t *testing.T) {
	tests := []struct {
		name string
		code int
		want string
	}{
		{"200 OK", 200, "2xx"},
		{"201 Created", 201, "2xx"},
		{"204 No Content", 204, "2xx"},
		{"299 upper bound", 299, "2xx"},
		{"301 Redirect", 301, "3xx"},
		{"304 Not Modified", 304, "3xx"},
		{"400 Bad Request", 400, "4xx"},
		{"401 Unauthorized", 401, "4xx"},
		{"403 Forbidden", 403, "4xx"},
		{"404 Not Found", 404, "4xx"},
		{"429 Rate Limited", 429, "4xx"},
		{"499 upper bound", 499, "4xx"},
		{"500 Internal Error", 500, "5xx"},
		{"502 Bad Gateway", 502, "5xx"},
		{"503 Unavailable", 503, "5xx"},
		{"0 unknown", 0, "unknown"},
		{"100 unknown", 100, "unknown"},
		{"199 unknown", 199, "unknown"},
		{"-1 unknown", -1, "unknown"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := statusCodeString(tt.code)
			if got != tt.want {
				t.Errorf("statusCodeString(%d) = %q, want %q", tt.code, got, tt.want)
			}
		})
	}
}

// =============================================================================
// InterfaceStats Type Tests
// =============================================================================

func TestInterfaceStats_Defaults(t *testing.T) {
	stats := InterfaceStats{}
	if stats.RxBytes != 0 || stats.TxBytes != 0 || stats.RxPackets != 0 || stats.TxPackets != 0 {
		t.Error("default InterfaceStats should have all zero values")
	}
}

// =============================================================================
// TCPStats Type Tests
// =============================================================================

func TestTCPStats_Defaults(t *testing.T) {
	stats := TCPStats{}
	if stats.InSegs != 0 || stats.OutSegs != 0 {
		t.Error("default TCPStats should have all zero values")
	}
}

// =============================================================================
// UDPStats Type Tests
// =============================================================================

func TestUDPStats_Defaults(t *testing.T) {
	stats := UDPStats{}
	if stats.InDatagrams != 0 || stats.OutDatagrams != 0 {
		t.Error("default UDPStats should have all zero values")
	}
}

// =============================================================================
// ConnectionStats Type Tests
// =============================================================================

func TestConnectionStats_Defaults(t *testing.T) {
	stats := ConnectionStats{}
	if stats.TCP != 0 {
		t.Error("default ConnectionStats should have zero TCP")
	}
}

// =============================================================================
// Sample Type Tests
// =============================================================================

func TestSample_Defaults(t *testing.T) {
	s := Sample{}
	if s.BlockedIPs != 0 || s.RuleCount != 0 || s.FeedsActive != 0 {
		t.Error("default Sample should have all zero values")
	}
	if s.HealthOK {
		t.Error("default Sample HealthOK should be false")
	}
	if s.Timestamp.IsZero() != true {
		t.Error("default Sample Timestamp should be zero")
	}
}

// =============================================================================
// basicStatsFromAPI Type Tests
// =============================================================================

func TestBasicStatsFromAPI_Defaults(t *testing.T) {
	stats := basicStatsFromAPI{}
	if stats.BannedIPv4 != 0 || stats.BannedIPv6 != 0 {
		t.Error("default basicStatsFromAPI should have zero banned counts")
	}
	if stats.WhitelistIPv4 != 0 || stats.WhitelistIPv6 != 0 {
		t.Error("default basicStatsFromAPI should have zero whitelist counts")
	}
	if stats.RulesTotal != 0 {
		t.Error("default basicStatsFromAPI should have zero rules")
	}
	if stats.FeedsActive != 0 {
		t.Error("default basicStatsFromAPI should have zero feeds")
	}
	if stats.FeedsIPs != 0 {
		t.Error("default basicStatsFromAPI should have zero feeds IPs")
	}
}

// =============================================================================
// NewCollector Tests
// =============================================================================

func TestNewCollector(t *testing.T) {
	c := NewCollector("/tmp/test.prom", "/tmp/state", "/tmp/log")
	if c == nil {
		t.Fatal("NewCollector() returned nil")
	}
	if c.outputFile != "/tmp/test.prom" {
		t.Errorf("outputFile = %q, want %q", c.outputFile, "/tmp/test.prom")
	}
	if c.stateDir != "/tmp/state" {
		t.Errorf("stateDir = %q, want %q", c.stateDir, "/tmp/state")
	}
	if c.logDir != "/tmp/log" {
		t.Errorf("logDir = %q, want %q", c.logDir, "/tmp/log")
	}
}

func TestNewCollector_EmptyPaths(t *testing.T) {
	c := NewCollector("", "", "")
	if c == nil {
		t.Fatal("NewCollector() with empty paths returned nil")
	}
}
