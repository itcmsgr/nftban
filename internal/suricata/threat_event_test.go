// =============================================================================
// NFTBan - Suricata L7 Event Model Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="threat_event_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-28"
// meta:description="Unit tests for ThreatEvent, actor resolver, and mapper"
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

package suricata

import (
	"testing"
	"time"
)

// =============================================================================
// Actor Resolver Tests
// =============================================================================

func TestResolveActorIP_DirectConnection(t *testing.T) {
	proxyCfg := ProxyTrustConfig{Enabled: false}

	actorIP, trust := ResolveActorIP("1.2.3.4", nil, proxyCfg)

	if actorIP != "1.2.3.4" {
		t.Errorf("expected 1.2.3.4, got %s", actorIP)
	}
	if trust != ActorDirect {
		t.Errorf("expected direct trust, got %s", trust)
	}
}

func TestResolveActorIP_NoXFF(t *testing.T) {
	networks, _ := ParseProxyNetworks([]string{"10.0.0.0/8"})
	proxyCfg := ProxyTrustConfig{
		Enabled:  true,
		Networks: networks,
	}

	// No HTTP details at all
	actorIP, trust := ResolveActorIP("10.0.0.5", nil, proxyCfg)

	if actorIP != "10.0.0.5" {
		t.Errorf("expected 10.0.0.5, got %s", actorIP)
	}
	if trust != ActorDirect {
		t.Errorf("expected direct (no XFF), got %s", trust)
	}
}

func TestResolveActorIP_EmptyXFF(t *testing.T) {
	networks, _ := ParseProxyNetworks([]string{"10.0.0.0/8"})
	proxyCfg := ProxyTrustConfig{
		Enabled:  true,
		Networks: networks,
	}

	http := &HTTPDetails{XFF: ""}

	actorIP, trust := ResolveActorIP("10.0.0.5", http, proxyCfg)

	if actorIP != "10.0.0.5" {
		t.Errorf("expected 10.0.0.5, got %s", actorIP)
	}
	if trust != ActorDirect {
		t.Errorf("expected direct (empty XFF), got %s", trust)
	}
}

func TestResolveActorIP_UntrustedProxy(t *testing.T) {
	networks, _ := ParseProxyNetworks([]string{"10.0.0.0/8"})
	proxyCfg := ProxyTrustConfig{
		Enabled:  true,
		Networks: networks,
	}

	http := &HTTPDetails{XFF: "5.6.7.8"}

	// Source is NOT in trusted range - XFF should be IGNORED
	actorIP, trust := ResolveActorIP("1.2.3.4", http, proxyCfg)

	if actorIP != "1.2.3.4" {
		t.Errorf("expected 1.2.3.4 (ignored XFF), got %s", actorIP)
	}
	if trust != ActorProxyUntrusted {
		t.Errorf("expected untrusted, got %s", trust)
	}
}

func TestResolveActorIP_TrustedProxy_SingleXFF(t *testing.T) {
	networks, _ := ParseProxyNetworks([]string{"10.0.0.0/8"})
	proxyCfg := ProxyTrustConfig{
		Enabled:  true,
		Networks: networks,
	}

	http := &HTTPDetails{XFF: "5.6.7.8"}

	// Source IS in trusted range
	actorIP, trust := ResolveActorIP("10.0.0.5", http, proxyCfg)

	if actorIP != "5.6.7.8" {
		t.Errorf("expected 5.6.7.8 from XFF, got %s", actorIP)
	}
	if trust != ActorProxyTrusted {
		t.Errorf("expected trusted, got %s", trust)
	}
}

func TestResolveActorIP_TrustedProxy_MultipleXFF(t *testing.T) {
	networks, _ := ParseProxyNetworks([]string{"10.0.0.0/8"})
	proxyCfg := ProxyTrustConfig{
		Enabled:  true,
		Networks: networks,
	}

	// XFF chain: original client, intermediate proxy, ...
	http := &HTTPDetails{XFF: "5.6.7.8, 10.0.0.1, 10.0.0.2"}

	actorIP, trust := ResolveActorIP("10.0.0.5", http, proxyCfg)

	// Should take FIRST (leftmost) IP - the original client
	if actorIP != "5.6.7.8" {
		t.Errorf("expected 5.6.7.8 (first in chain), got %s", actorIP)
	}
	if trust != ActorProxyTrusted {
		t.Errorf("expected trusted, got %s", trust)
	}
}

func TestResolveActorIP_InvalidXFF(t *testing.T) {
	networks, _ := ParseProxyNetworks([]string{"10.0.0.0/8"})
	proxyCfg := ProxyTrustConfig{
		Enabled:  true,
		Networks: networks,
	}

	http := &HTTPDetails{XFF: "not-an-ip"}

	actorIP, trust := ResolveActorIP("10.0.0.5", http, proxyCfg)

	// Invalid XFF should fall back to source
	if actorIP != "10.0.0.5" {
		t.Errorf("expected 10.0.0.5 (invalid XFF), got %s", actorIP)
	}
	if trust != ActorProxyTrusted {
		t.Errorf("expected trusted (but fell back), got %s", trust)
	}
}

func TestResolveActorIP_RejectPrivateXFF(t *testing.T) {
	networks, _ := ParseProxyNetworks([]string{"10.0.0.0/8"})
	proxyCfg := ProxyTrustConfig{
		Enabled:         true,
		Networks:        networks,
		RejectPrivateIP: true,
	}

	http := &HTTPDetails{XFF: "192.168.1.100"}

	actorIP, trust := ResolveActorIP("10.0.0.5", http, proxyCfg)

	// Private XFF should be rejected
	if actorIP != "10.0.0.5" {
		t.Errorf("expected 10.0.0.5 (private XFF rejected), got %s", actorIP)
	}
	if trust != ActorProxyTrusted {
		t.Errorf("expected trusted, got %s", trust)
	}
}

func TestParseProxyNetworks(t *testing.T) {
	cidrs := []string{"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"}

	networks, err := ParseProxyNetworks(cidrs)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(networks) != 3 {
		t.Errorf("expected 3 networks, got %d", len(networks))
	}
}

func TestParseProxyNetworks_Invalid(t *testing.T) {
	cidrs := []string{"10.0.0.0/8", "invalid-cidr"}

	_, err := ParseProxyNetworks(cidrs)
	if err == nil {
		t.Error("expected error for invalid CIDR")
	}
}

// =============================================================================
// Mapper Tests
// =============================================================================

func TestMapEVEToThreatEvent_HTTP(t *testing.T) {
	eve := &EveEvent{
		Timestamp: "2026-01-28T12:00:00.000000+0000",
		EventType: "http",
		SrcIP:     "1.2.3.4",
		SrcPort:   54321,
		DestIP:    "10.0.0.1",
		DestPort:  80,
		Proto:     "TCP",
		AppProto:  "http",
		FlowID:    12345,
		HTTP: &EveHTTP{
			Hostname:  "example.com",
			URL:       "/wp-login.php",
			Method:    "POST",
			Status:    200,
			UserAgent: "Mozilla/5.0",
		},
	}

	proxyCfg := ProxyTrustConfig{Enabled: false}

	event, err := MapEVEToThreatEvent(eve, "sensor1", proxyCfg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if event.EventType != ThreatEventTypeHTTP {
		t.Errorf("expected http event type, got %s", event.EventType)
	}
	if event.ActorIP != "1.2.3.4" {
		t.Errorf("expected actor IP 1.2.3.4, got %s", event.ActorIP)
	}
	if event.ActorTrust != ActorDirect {
		t.Errorf("expected direct trust, got %s", event.ActorTrust)
	}
	if event.HTTP == nil {
		t.Fatal("expected HTTP details")
	}
	if event.HTTP.URI != "/wp-login.php" {
		t.Errorf("expected /wp-login.php, got %s", event.HTTP.URI)
	}
	if event.HTTP.Host != "example.com" {
		t.Errorf("expected example.com, got %s", event.HTTP.Host)
	}
	if event.ObservedDirection != "inbound" {
		t.Errorf("expected inbound, got %s", event.ObservedDirection)
	}
	if event.Sensor != "sensor1" {
		t.Errorf("expected sensor1, got %s", event.Sensor)
	}
}

func TestMapEVEToThreatEvent_HTTPWithProxy(t *testing.T) {
	networks, _ := ParseProxyNetworks([]string{"10.0.0.0/8"})
	proxyCfg := ProxyTrustConfig{
		Enabled:  true,
		Networks: networks,
	}

	eve := &EveEvent{
		Timestamp: "2026-01-28T12:00:00.000000+0000",
		EventType: "http",
		SrcIP:     "10.0.0.5", // Trusted proxy
		SrcPort:   54321,
		DestIP:    "10.0.0.1",
		DestPort:  80,
		Proto:     "TCP",
		HTTP: &EveHTTP{
			Hostname: "example.com",
			URL:      "/api/test",
			Method:   "GET",
			XFF:      "203.0.113.50", // Real client
		},
	}

	event, err := MapEVEToThreatEvent(eve, "sensor1", proxyCfg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Should resolve to XFF IP
	if event.ActorIP != "203.0.113.50" {
		t.Errorf("expected actor IP 203.0.113.50, got %s", event.ActorIP)
	}
	if event.ActorTrust != ActorProxyTrusted {
		t.Errorf("expected proxy_trusted, got %s", event.ActorTrust)
	}
	// SrcIP should still be the proxy
	if event.SrcIP != "10.0.0.5" {
		t.Errorf("expected src_ip 10.0.0.5, got %s", event.SrcIP)
	}
}

func TestMapEVEToThreatEvent_Alert(t *testing.T) {
	eve := &EveEvent{
		Timestamp: "2026-01-28T12:00:00.000000+0000",
		EventType: "alert",
		SrcIP:     "1.2.3.4",
		DestIP:    "10.0.0.1",
		DestPort:  443,
		Proto:     "TCP",
		Alert: &EveAlertFields{
			SID:       2100498,
			GID:       1,
			Rev:       5,
			Signature: "ET EXPLOIT Apache Struts RCE",
			Category:  "Attempted Administrator Privilege Gain",
			Severity:  1,
			Action:    "allowed",
		},
	}

	proxyCfg := ProxyTrustConfig{Enabled: false}

	event, err := MapEVEToThreatEvent(eve, "sensor1", proxyCfg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if event.EventType != ThreatEventTypeAlert {
		t.Errorf("expected alert event type, got %s", event.EventType)
	}
	if event.Alert == nil {
		t.Fatal("expected Alert details")
	}
	if event.Alert.SID != 2100498 {
		t.Errorf("expected SID 2100498, got %d", event.Alert.SID)
	}
	if event.Alert.Severity != 1 {
		t.Errorf("expected severity 1, got %d", event.Alert.Severity)
	}
	if event.Alert.Category != "Attempted Administrator Privilege Gain" {
		t.Errorf("expected category, got %s", event.Alert.Category)
	}
}

func TestMapEVEToThreatEvent_TLS(t *testing.T) {
	eve := &EveEvent{
		Timestamp: "2026-01-28T12:00:00.000000+0000",
		EventType: "tls",
		SrcIP:     "1.2.3.4",
		DestIP:    "10.0.0.1",
		DestPort:  443,
		Proto:     "TCP",
		TLS: &EveTLS{
			SNI:     "example.com",
			Version: "TLS 1.3",
			JA3: &struct {
				Hash string `json:"hash"`
			}{Hash: "abc123def456"},
		},
	}

	proxyCfg := ProxyTrustConfig{Enabled: false}

	event, err := MapEVEToThreatEvent(eve, "sensor1", proxyCfg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if event.EventType != ThreatEventTypeTLS {
		t.Errorf("expected tls event type, got %s", event.EventType)
	}
	if event.TLS == nil {
		t.Fatal("expected TLS details")
	}
	if event.TLS.SNI != "example.com" {
		t.Errorf("expected SNI example.com, got %s", event.TLS.SNI)
	}
	if event.TLS.JA3 != "abc123def456" {
		t.Errorf("expected JA3 hash, got %s", event.TLS.JA3)
	}
}

func TestMapEVEToThreatEvent_DNS(t *testing.T) {
	eve := &EveEvent{
		Timestamp: "2026-01-28T12:00:00.000000+0000",
		EventType: "dns",
		SrcIP:     "1.2.3.4",
		DestIP:    "8.8.8.8",
		DestPort:  53,
		Proto:     "UDP",
		DNS: &EveDNS{
			Type:   "query",
			RRType: "A",
			RRName: "malicious.example.com",
		},
	}

	proxyCfg := ProxyTrustConfig{Enabled: false}

	event, err := MapEVEToThreatEvent(eve, "sensor1", proxyCfg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if event.EventType != ThreatEventTypeDNS {
		t.Errorf("expected dns event type, got %s", event.EventType)
	}
	if event.DNS == nil {
		t.Fatal("expected DNS details")
	}
	if event.DNS.RRName != "malicious.example.com" {
		t.Errorf("expected RRName, got %s", event.DNS.RRName)
	}
}

func TestMapEVEToThreatEvent_SSH(t *testing.T) {
	eve := &EveEvent{
		Timestamp: "2026-01-28T12:00:00.000000+0000",
		EventType: "ssh",
		SrcIP:     "1.2.3.4",
		DestIP:    "10.0.0.1",
		DestPort:  22,
		Proto:     "TCP",
		SSH: &EveSSH{
			Client: &struct {
				ProtoVersion    string `json:"proto_version"`
				SoftwareVersion string `json:"software_version"`
			}{
				ProtoVersion:    "2.0",
				SoftwareVersion: "OpenSSH_8.0",
			},
		},
	}

	proxyCfg := ProxyTrustConfig{Enabled: false}

	event, err := MapEVEToThreatEvent(eve, "sensor1", proxyCfg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if event.EventType != ThreatEventTypeSSH {
		t.Errorf("expected ssh event type, got %s", event.EventType)
	}
	if event.SSH == nil {
		t.Fatal("expected SSH details")
	}
	if event.SSH.Client.Version != "2.0" {
		t.Errorf("expected client version 2.0, got %s", event.SSH.Client.Version)
	}
}

func TestMapEVEToThreatEvent_NilEvent(t *testing.T) {
	proxyCfg := ProxyTrustConfig{Enabled: false}

	_, err := MapEVEToThreatEvent(nil, "sensor1", proxyCfg)
	if err == nil {
		t.Error("expected error for nil event")
	}
}

func TestMapEVEToThreatEvent_InvalidTimestamp(t *testing.T) {
	eve := &EveEvent{
		Timestamp: "invalid-timestamp",
		EventType: "http",
		SrcIP:     "1.2.3.4",
		DestIP:    "10.0.0.1",
	}

	proxyCfg := ProxyTrustConfig{Enabled: false}

	event, err := MapEVEToThreatEvent(eve, "sensor1", proxyCfg)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Should use fallback timestamp (now)
	if event.Timestamp.IsZero() {
		t.Error("expected non-zero timestamp")
	}
}

func TestDetermineDirection(t *testing.T) {
	tests := []struct {
		srcPort  int
		dstPort  int
		expected string
	}{
		{54321, 80, "inbound"},
		{54321, 443, "inbound"},
		{54321, 22, "inbound"},
		{80, 54321, "outbound"},
		{443, 54321, "outbound"},
		{54321, 8080, "unknown"},
		{12345, 54321, "unknown"},
	}

	for _, tt := range tests {
		result := determineDirection(tt.srcPort, tt.dstPort)
		if result != tt.expected {
			t.Errorf("determineDirection(%d, %d) = %s, want %s",
				tt.srcPort, tt.dstPort, result, tt.expected)
		}
	}
}

func TestGenerateThreatEventID(t *testing.T) {
	// Event IDs should be deterministic
	id1 := generateThreatEventID(
		mustParseTime("2026-01-28T12:00:00Z"),
		12345,
		1,
		"http",
	)
	id2 := generateThreatEventID(
		mustParseTime("2026-01-28T12:00:00Z"),
		12345,
		1,
		"http",
	)

	if id1 != id2 {
		t.Errorf("expected same ID for same input, got %s and %s", id1, id2)
	}

	// Different inputs should produce different IDs
	id3 := generateThreatEventID(
		mustParseTime("2026-01-28T12:00:01Z"),
		12345,
		1,
		"http",
	)

	if id1 == id3 {
		t.Errorf("expected different ID for different timestamp")
	}
}

func mustParseTime(s string) time.Time {
	t, _ := time.Parse(time.RFC3339, s)
	return t
}
