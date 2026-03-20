// =============================================================================
// NFTBan - Tests for nft set data model
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="model_setdata_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for nft set data model"
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

package model

import (
	"testing"
)

// =============================================================================
// NewSetData tests
// =============================================================================

func TestNewSetData(t *testing.T) {
	sd := NewSetData("test_source")

	if sd == nil {
		t.Fatal("NewSetData returned nil")
	}
	if sd.Source != "test_source" {
		t.Errorf("Source = %q, want test_source", sd.Source)
	}
	if sd.Count != 0 {
		t.Errorf("Count = %d, want 0", sd.Count)
	}
	if sd.IPv4 == nil {
		t.Error("IPv4 should not be nil")
	}
	if sd.IPv6 == nil {
		t.Error("IPv6 should not be nil")
	}
	if len(sd.IPv4) != 0 {
		t.Errorf("len(IPv4) = %d, want 0", len(sd.IPv4))
	}
	if len(sd.IPv6) != 0 {
		t.Errorf("len(IPv6) = %d, want 0", len(sd.IPv6))
	}
}

// =============================================================================
// AddIPv4 / AddIPv6 tests
// =============================================================================

func TestAddIPv4(t *testing.T) {
	sd := NewSetData("test")

	sd.AddIPv4("1.2.3.4")
	if len(sd.IPv4) != 1 {
		t.Errorf("len(IPv4) = %d, want 1", len(sd.IPv4))
	}
	if sd.Count != 1 {
		t.Errorf("Count = %d, want 1", sd.Count)
	}
	if sd.IPv4[0] != "1.2.3.4" {
		t.Errorf("IPv4[0] = %q, want 1.2.3.4", sd.IPv4[0])
	}

	sd.AddIPv4("5.6.7.8")
	if len(sd.IPv4) != 2 {
		t.Errorf("len(IPv4) = %d, want 2", len(sd.IPv4))
	}
	if sd.Count != 2 {
		t.Errorf("Count = %d, want 2", sd.Count)
	}
}

func TestAddIPv6(t *testing.T) {
	sd := NewSetData("test")

	sd.AddIPv6("2001:db8::1")
	if len(sd.IPv6) != 1 {
		t.Errorf("len(IPv6) = %d, want 1", len(sd.IPv6))
	}
	if sd.Count != 1 {
		t.Errorf("Count = %d, want 1", sd.Count)
	}
	if sd.IPv6[0] != "2001:db8::1" {
		t.Errorf("IPv6[0] = %q, want 2001:db8::1", sd.IPv6[0])
	}
}

func TestAddMixed(t *testing.T) {
	sd := NewSetData("test")

	sd.AddIPv4("1.2.3.4")
	sd.AddIPv6("::1")
	sd.AddIPv4("5.6.7.8")
	sd.AddIPv6("2001:db8::1")

	if len(sd.IPv4) != 2 {
		t.Errorf("len(IPv4) = %d, want 2", len(sd.IPv4))
	}
	if len(sd.IPv6) != 2 {
		t.Errorf("len(IPv6) = %d, want 2", len(sd.IPv6))
	}
	if sd.Count != 4 {
		t.Errorf("Count = %d, want 4", sd.Count)
	}
}

// =============================================================================
// IsEmpty tests
// =============================================================================

func TestIsEmpty(t *testing.T) {
	sd := NewSetData("test")
	if !sd.IsEmpty() {
		t.Error("new SetData should be empty")
	}

	sd.AddIPv4("1.2.3.4")
	if sd.IsEmpty() {
		t.Error("SetData with entries should not be empty")
	}
}

func TestIsEmpty_IPv6Only(t *testing.T) {
	sd := NewSetData("test")
	sd.AddIPv6("::1")
	if sd.IsEmpty() {
		t.Error("SetData with IPv6 entry should not be empty")
	}
}

// =============================================================================
// NewFirewallConfig tests
// =============================================================================

func TestNewFirewallConfig(t *testing.T) {
	fc := NewFirewallConfig()

	if fc == nil {
		t.Fatal("NewFirewallConfig returned nil")
	}
	if fc.Whitelist == nil {
		t.Error("Whitelist should not be nil")
	}
	if fc.Blacklist == nil {
		t.Error("Blacklist should not be nil")
	}
	if fc.Feeds == nil {
		t.Error("Feeds should not be nil")
	}
	if fc.Geoban == nil {
		t.Error("Geoban should not be nil")
	}

	if fc.Whitelist.Source != "whitelist" {
		t.Errorf("Whitelist.Source = %q, want whitelist", fc.Whitelist.Source)
	}
	if fc.Blacklist.Source != "blacklist" {
		t.Errorf("Blacklist.Source = %q, want blacklist", fc.Blacklist.Source)
	}
	if fc.Geoban.Source != "geoban" {
		t.Errorf("Geoban.Source = %q, want geoban", fc.Geoban.Source)
	}

	// Port slices should be initialized but empty
	if fc.TCPPortsIn == nil || len(fc.TCPPortsIn) != 0 {
		t.Error("TCPPortsIn should be empty non-nil slice")
	}
	if fc.TCPPortsOut == nil || len(fc.TCPPortsOut) != 0 {
		t.Error("TCPPortsOut should be empty non-nil slice")
	}
	if fc.UDPPortsIn == nil || len(fc.UDPPortsIn) != 0 {
		t.Error("UDPPortsIn should be empty non-nil slice")
	}
	if fc.UDPPortsOut == nil || len(fc.UDPPortsOut) != 0 {
		t.Error("UDPPortsOut should be empty non-nil slice")
	}

	// Optional fields should be nil
	if fc.RuntimeBans != nil {
		t.Error("RuntimeBans should be nil by default")
	}
	if fc.RuntimeWhitelist != nil {
		t.Error("RuntimeWhitelist should be nil by default")
	}
}

// =============================================================================
// SetData with CIDR entries
// =============================================================================

func TestSetData_CIDREntries(t *testing.T) {
	sd := NewSetData("feeds")

	// CIDRs are stored the same as single IPs (string values)
	sd.AddIPv4("192.168.0.0/16")
	sd.AddIPv4("10.0.0.0/8")
	sd.AddIPv6("2001:db8::/32")

	if len(sd.IPv4) != 2 {
		t.Errorf("len(IPv4) = %d, want 2", len(sd.IPv4))
	}
	if len(sd.IPv6) != 1 {
		t.Errorf("len(IPv6) = %d, want 1", len(sd.IPv6))
	}
	if sd.Count != 3 {
		t.Errorf("Count = %d, want 3", sd.Count)
	}
}

// =============================================================================
// SetData large volume test
// =============================================================================

func TestSetData_LargeVolume(t *testing.T) {
	sd := NewSetData("large")

	// Simulate typical feed sizes
	for i := 0; i < 10000; i++ {
		sd.AddIPv4("1.2.3.4") // Duplicate adds are fine (no dedup at this level)
	}

	if sd.Count != 10000 {
		t.Errorf("Count = %d, want 10000", sd.Count)
	}
	if len(sd.IPv4) != 10000 {
		t.Errorf("len(IPv4) = %d, want 10000", len(sd.IPv4))
	}
}
