// =============================================================================
// NFTBan v1.0 - nftband Daemon Types and Validation Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="daemon_types_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Unit tests for daemon type validation, timeout helpers, and dispatch"
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

package main

import (
	"os"
	"testing"
	"time"
)

// =============================================================================
// validNFTBanTable Tests
// =============================================================================

func TestValidNFTBanTable(t *testing.T) {
	tests := []struct {
		name  string
		table string
		want  bool
	}{
		{"ip_nftban", "ip nftban", true},
		{"ip6_nftban", "ip6 nftban", true},
		{"inet_nftban", "inet nftban", false},
		{"empty", "", false},
		{"just_nftban", "nftban", false},
		{"ip_other", "ip other", false},
		{"ip6_other", "ip6 other", false},
		{"random", "random table", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := validNFTBanTable(tt.table)
			if got != tt.want {
				t.Errorf("validNFTBanTable(%q) = %v, want %v", tt.table, got, tt.want)
			}
		})
	}
}

// =============================================================================
// validNFTBanSet Tests
// =============================================================================

func TestValidNFTBanSet(t *testing.T) {
	validSets := []string{
		"blacklist_ipv4", "blacklist_ipv6",
		"whitelist_ipv4", "whitelist_ipv6",
		"persistent_offenders_ipv4", "persistent_offenders_ipv6",
		"bogon_ipv4", "bogon_ipv6",
		"geoban_ipv4", "geoban_ipv6",
		"tcp_ports_in", "tcp_ports_out",
		"udp_ports_in", "udp_ports_out",
		// HTTP Bot Guard sets
		"http_bot_suspect", "http_bot_suspect6",
		"http_bot_allow", "http_bot_allow6",
		"http_bot_ban", "http_bot_ban6",
		"http_bot_grey", "http_bot_grey6",
		"http_bot_emergency", "http_bot_emergency6",
		"http_bot_pending", "http_bot_pending6",
		// Per-IP port access sets (v1.43.0)
		"port_allow_tcp_ipv4", "port_allow_tcp_ipv6",
		"port_allow_udp_ipv4", "port_allow_udp_ipv6",
	}

	for _, set := range validSets {
		t.Run("valid_"+set, func(t *testing.T) {
			if !validNFTBanSet(set) {
				t.Errorf("validNFTBanSet(%q) = false, want true", set)
			}
		})
	}

	invalidSets := []string{
		"", "random", "blacklist", "whitelist",
		"ipv4", "ipv6", "iptables", "filter",
		"http_bot_unknown", "some_new_set",
	}

	for _, set := range invalidSets {
		t.Run("invalid_"+set, func(t *testing.T) {
			if validNFTBanSet(set) {
				t.Errorf("validNFTBanSet(%q) = true, want false", set)
			}
		})
	}
}

func TestKnownNFTBanSets_Count(t *testing.T) {
	// Verify we have the expected number of known sets
	// 4 blacklist/whitelist + 2 persistent + 2 bogon + 2 geoban + 4 ports + 12 botguard + 4 port_allow = 30
	if len(knownNFTBanSets) != 30 {
		t.Errorf("expected 30 known sets, got %d", len(knownNFTBanSets))
	}
}

// =============================================================================
// getIPCSocketTimeout Tests
// =============================================================================

func TestGetIPCSocketTimeout_Default(t *testing.T) {
	// Ensure env var is not set
	os.Unsetenv("NFTBAN_TIMEOUT_IPC_SOCKET")

	timeout := getIPCSocketTimeout()
	expected := 300 * time.Second
	if timeout != expected {
		t.Errorf("getIPCSocketTimeout() = %v, want %v", timeout, expected)
	}
}

func TestGetIPCSocketTimeout_CustomValue(t *testing.T) {
	os.Setenv("NFTBAN_TIMEOUT_IPC_SOCKET", "60")
	defer os.Unsetenv("NFTBAN_TIMEOUT_IPC_SOCKET")

	timeout := getIPCSocketTimeout()
	expected := 60 * time.Second
	if timeout != expected {
		t.Errorf("getIPCSocketTimeout() = %v, want %v", timeout, expected)
	}
}

func TestGetIPCSocketTimeout_InvalidValue(t *testing.T) {
	os.Setenv("NFTBAN_TIMEOUT_IPC_SOCKET", "not_a_number")
	defer os.Unsetenv("NFTBAN_TIMEOUT_IPC_SOCKET")

	timeout := getIPCSocketTimeout()
	expected := 300 * time.Second
	if timeout != expected {
		t.Errorf("getIPCSocketTimeout() with invalid value = %v, want default %v", timeout, expected)
	}
}

func TestGetIPCSocketTimeout_NegativeValue(t *testing.T) {
	os.Setenv("NFTBAN_TIMEOUT_IPC_SOCKET", "-10")
	defer os.Unsetenv("NFTBAN_TIMEOUT_IPC_SOCKET")

	timeout := getIPCSocketTimeout()
	expected := 300 * time.Second
	if timeout != expected {
		t.Errorf("getIPCSocketTimeout() with negative value = %v, want default %v", timeout, expected)
	}
}

func TestGetIPCSocketTimeout_ZeroValue(t *testing.T) {
	os.Setenv("NFTBAN_TIMEOUT_IPC_SOCKET", "0")
	defer os.Unsetenv("NFTBAN_TIMEOUT_IPC_SOCKET")

	timeout := getIPCSocketTimeout()
	expected := 300 * time.Second
	if timeout != expected {
		t.Errorf("getIPCSocketTimeout() with zero value = %v, want default %v", timeout, expected)
	}
}

// =============================================================================
// getAutoSyncDelay Tests
// =============================================================================

func TestGetAutoSyncDelay_Default(t *testing.T) {
	os.Unsetenv("NFTBAN_AUTO_SYNC_DELAY")

	delay := getAutoSyncDelay()
	expected := 60 * time.Second
	if delay != expected {
		t.Errorf("getAutoSyncDelay() = %v, want %v", delay, expected)
	}
}

func TestGetAutoSyncDelay_CustomValue(t *testing.T) {
	os.Setenv("NFTBAN_AUTO_SYNC_DELAY", "120")
	defer os.Unsetenv("NFTBAN_AUTO_SYNC_DELAY")

	delay := getAutoSyncDelay()
	expected := 120 * time.Second
	if delay != expected {
		t.Errorf("getAutoSyncDelay() = %v, want %v", delay, expected)
	}
}

func TestGetAutoSyncDelay_ZeroValid(t *testing.T) {
	os.Setenv("NFTBAN_AUTO_SYNC_DELAY", "0")
	defer os.Unsetenv("NFTBAN_AUTO_SYNC_DELAY")

	delay := getAutoSyncDelay()
	expected := 0 * time.Second
	if delay != expected {
		t.Errorf("getAutoSyncDelay() with 0 = %v, want %v", delay, expected)
	}
}

func TestGetAutoSyncDelay_InvalidValue(t *testing.T) {
	os.Setenv("NFTBAN_AUTO_SYNC_DELAY", "abc")
	defer os.Unsetenv("NFTBAN_AUTO_SYNC_DELAY")

	delay := getAutoSyncDelay()
	expected := 60 * time.Second
	if delay != expected {
		t.Errorf("getAutoSyncDelay() with invalid = %v, want default %v", delay, expected)
	}
}

func TestGetAutoSyncDelay_NegativeValue(t *testing.T) {
	os.Setenv("NFTBAN_AUTO_SYNC_DELAY", "-5")
	defer os.Unsetenv("NFTBAN_AUTO_SYNC_DELAY")

	delay := getAutoSyncDelay()
	expected := 60 * time.Second
	if delay != expected {
		t.Errorf("getAutoSyncDelay() with negative = %v, want default %v", delay, expected)
	}
}

// =============================================================================
// SocketRequest/SocketResponse Types Tests
// =============================================================================

func TestSocketRequest_Structure(t *testing.T) {
	req := SocketRequest{
		Method: "ban",
		Params: map[string]any{
			"ip":     "1.2.3.4",
			"reason": "portscan",
		},
	}

	if req.Method != "ban" {
		t.Errorf("expected Method=%q, got %q", "ban", req.Method)
	}
	if req.Params["ip"] != "1.2.3.4" {
		t.Errorf("expected Params[ip]=%q, got %v", "1.2.3.4", req.Params["ip"])
	}
}

func TestSocketResponse_Structure(t *testing.T) {
	resp := SocketResponse{
		Success: true,
		Data:    "pong",
	}

	if !resp.Success {
		t.Error("expected Success=true")
	}
	if resp.Data != "pong" {
		t.Errorf("expected Data=%q, got %v", "pong", resp.Data)
	}
	if resp.Error != "" {
		t.Errorf("expected empty Error, got %q", resp.Error)
	}
}

func TestSocketResponse_Error(t *testing.T) {
	resp := SocketResponse{
		Success: false,
		Error:   "unknown method: foo",
	}

	if resp.Success {
		t.Error("expected Success=false for error response")
	}
	if resp.Error != "unknown method: foo" {
		t.Errorf("expected Error=%q, got %q", "unknown method: foo", resp.Error)
	}
}

// =============================================================================
// Build Variables Tests
// =============================================================================

func TestBuildVariables_Defaults(t *testing.T) {
	// Default values when not set by ldflags
	if GitCommit != "dev" {
		t.Errorf("expected default GitCommit=%q, got %q", "dev", GitCommit)
	}
	if BuildDate != "unknown" {
		t.Errorf("expected default BuildDate=%q, got %q", "unknown", BuildDate)
	}
}

// =============================================================================
// Constants Tests
// =============================================================================

func TestConstants(t *testing.T) {
	if DefaultHTTPAddr != "127.0.0.1:8080" {
		t.Errorf("DefaultHTTPAddr = %q, want %q", DefaultHTTPAddr, "127.0.0.1:8080")
	}
	if PprofAddr != "127.0.0.1:6060" {
		t.Errorf("PprofAddr = %q, want %q", PprofAddr, "127.0.0.1:6060")
	}
	if MaxConcurrentIPCConns != 100 {
		t.Errorf("MaxConcurrentIPCConns = %d, want 100", MaxConcurrentIPCConns)
	}
}
