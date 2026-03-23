// =============================================================================
// NFTBan v1.0 - Port Configuration Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="ports_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Unit tests for port parsing, deduplication, and configuration loading"
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

package ports

import (
	"testing"
)

// =============================================================================
// parsePortList Tests
// =============================================================================

func TestParsePortList_SinglePort(t *testing.T) {
	ports, err := parsePortList("22")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ports) != 1 || ports[0] != 22 {
		t.Errorf("expected [22], got %v", ports)
	}
}

func TestParsePortList_MultiplePort(t *testing.T) {
	ports, err := parsePortList("22,80,443")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ports) != 3 {
		t.Fatalf("expected 3 ports, got %d", len(ports))
	}
	expected := []int{22, 80, 443}
	for i, want := range expected {
		if ports[i] != want {
			t.Errorf("ports[%d] = %d, want %d", i, ports[i], want)
		}
	}
}

func TestParsePortList_WithSpaces(t *testing.T) {
	ports, err := parsePortList("22 , 80 , 443")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ports) != 3 {
		t.Errorf("expected 3 ports, got %d", len(ports))
	}
}

func TestParsePortList_PortRange(t *testing.T) {
	ports, err := parsePortList("35000-35005")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ports) != 6 {
		t.Fatalf("expected 6 ports (35000-35005), got %d", len(ports))
	}
	if ports[0] != 35000 {
		t.Errorf("expected first port 35000, got %d", ports[0])
	}
	if ports[5] != 35005 {
		t.Errorf("expected last port 35005, got %d", ports[5])
	}
}

func TestParsePortList_MixedPortsAndRanges(t *testing.T) {
	ports, err := parsePortList("22,80,35000-35002,443")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// 22, 80, 35000, 35001, 35002, 443 = 6
	if len(ports) != 6 {
		t.Errorf("expected 6 ports, got %d: %v", len(ports), ports)
	}
}

func TestParsePortList_EmptyString(t *testing.T) {
	ports, err := parsePortList("")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ports) != 0 {
		t.Errorf("expected 0 ports for empty string, got %d", len(ports))
	}
}

func TestParsePortList_EmptyParts(t *testing.T) {
	ports, err := parsePortList("22,,80,,")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ports) != 2 {
		t.Errorf("expected 2 ports, got %d: %v", len(ports), ports)
	}
}

func TestParsePortList_InvalidPort(t *testing.T) {
	_, err := parsePortList("abc")
	if err == nil {
		t.Error("expected error for invalid port")
	}
}

func TestParsePortList_PortOutOfRange(t *testing.T) {
	_, err := parsePortList("0")
	if err == nil {
		t.Error("expected error for port 0")
	}

	_, err = parsePortList("70000")
	if err == nil {
		t.Error("expected error for port 70000")
	}
}

func TestParsePortList_InvalidRange(t *testing.T) {
	// Start > End
	_, err := parsePortList("100-50")
	if err == nil {
		t.Error("expected error for inverted range")
	}
}

func TestParsePortList_RangeTooLarge(t *testing.T) {
	_, err := parsePortList("1-20000")
	if err == nil {
		t.Error("expected error for range > 10000")
	}
}

func TestParsePortList_RangeOutOfBounds(t *testing.T) {
	_, err := parsePortList("0-100")
	if err == nil {
		t.Error("expected error for range starting at 0")
	}

	_, err = parsePortList("60000-70000")
	if err == nil {
		t.Error("expected error for range ending above 65535")
	}
}

// =============================================================================
// deduplicatePorts Tests
// =============================================================================

func TestDeduplicatePorts_TCPOnly(t *testing.T) {
	config := &PortConfig{
		AllRules: []PortRule{
			{Port: 22, Protocol: "T", Direction: "I"},
			{Port: 80, Protocol: "T", Direction: "I"},
			{Port: 22, Protocol: "T", Direction: "I"}, // Duplicate
		},
		PortMap: make(map[int][]string),
	}

	config.deduplicatePorts()

	// TCPPorts should contain 22 and 80 (no duplicates)
	if len(config.TCPPorts) != 2 {
		t.Errorf("expected 2 TCP ports, got %d: %v", len(config.TCPPorts), config.TCPPorts)
	}
	if len(config.UDPPorts) != 0 {
		t.Errorf("expected 0 UDP ports, got %d", len(config.UDPPorts))
	}
}

func TestDeduplicatePorts_UDPOnly(t *testing.T) {
	config := &PortConfig{
		AllRules: []PortRule{
			{Port: 53, Protocol: "U", Direction: "I"},
		},
		PortMap: make(map[int][]string),
	}

	config.deduplicatePorts()

	if len(config.UDPPorts) != 1 {
		t.Errorf("expected 1 UDP port, got %d", len(config.UDPPorts))
	}
	if len(config.TCPPorts) != 0 {
		t.Errorf("expected 0 TCP ports, got %d", len(config.TCPPorts))
	}
}

func TestDeduplicatePorts_BothProtocol(t *testing.T) {
	config := &PortConfig{
		AllRules: []PortRule{
			{Port: 53, Protocol: "B", Direction: "I"},
		},
		PortMap: make(map[int][]string),
	}

	config.deduplicatePorts()

	if len(config.TCPPorts) != 1 {
		t.Errorf("expected 1 TCP port for Both, got %d", len(config.TCPPorts))
	}
	if len(config.UDPPorts) != 1 {
		t.Errorf("expected 1 UDP port for Both, got %d", len(config.UDPPorts))
	}
}

func TestDeduplicatePorts_Directional(t *testing.T) {
	config := &PortConfig{
		AllRules: []PortRule{
			{Port: 22, Protocol: "T", Direction: "I"},   // TCP input
			{Port: 443, Protocol: "T", Direction: "O"},  // TCP output
			{Port: 80, Protocol: "T", Direction: "IO"},  // TCP both directions
			{Port: 53, Protocol: "U", Direction: "I"},   // UDP input
		},
		PortMap: make(map[int][]string),
	}

	config.deduplicatePorts()

	// TCPPortsIn should have 22 and 80
	tcpInSet := make(map[int]bool)
	for _, p := range config.TCPPortsIn {
		tcpInSet[p] = true
	}
	if !tcpInSet[22] || !tcpInSet[80] {
		t.Errorf("expected TCPPortsIn to contain 22 and 80, got %v", config.TCPPortsIn)
	}

	// TCPPortsOut should have 443 and 80
	tcpOutSet := make(map[int]bool)
	for _, p := range config.TCPPortsOut {
		tcpOutSet[p] = true
	}
	if !tcpOutSet[443] || !tcpOutSet[80] {
		t.Errorf("expected TCPPortsOut to contain 443 and 80, got %v", config.TCPPortsOut)
	}

	// UDPPortsIn should have 53
	udpInSet := make(map[int]bool)
	for _, p := range config.UDPPortsIn {
		udpInSet[p] = true
	}
	if !udpInSet[53] {
		t.Errorf("expected UDPPortsIn to contain 53, got %v", config.UDPPortsIn)
	}
}

// =============================================================================
// GetAllPorts Tests
// =============================================================================

func TestGetAllPorts(t *testing.T) {
	config := &PortConfig{
		TCPPorts: []int{22, 80, 443},
		UDPPorts: []int{53, 80}, // 80 overlaps with TCP
	}

	all := config.GetAllPorts()
	portSet := make(map[int]bool)
	for _, p := range all {
		portSet[p] = true
	}

	if len(portSet) != 4 {
		t.Errorf("expected 4 unique ports, got %d: %v", len(portSet), all)
	}

	expected := []int{22, 53, 80, 443}
	for _, port := range expected {
		if !portSet[port] {
			t.Errorf("expected port %d in GetAllPorts result", port)
		}
	}
}

// =============================================================================
// PortRule Tests
// =============================================================================

func TestPortRule_Struct(t *testing.T) {
	rule := PortRule{
		Port:      22,
		Protocol:  "T",
		Direction: "I",
		Source:    "test.conf",
	}

	if rule.Port != 22 {
		t.Errorf("expected Port=22, got %d", rule.Port)
	}
	if rule.Protocol != "T" {
		t.Errorf("expected Protocol=%q, got %q", "T", rule.Protocol)
	}
	if rule.Direction != "I" {
		t.Errorf("expected Direction=%q, got %q", "I", rule.Direction)
	}
	if rule.Source != "test.conf" {
		t.Errorf("expected Source=%q, got %q", "test.conf", rule.Source)
	}
}
