// =============================================================================
// NFTBan v1.0 - Network Service Detector Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="detector_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Unit tests for service detection by port, category mapping, and TLS version"
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

package scanner

import (
	"crypto/tls"
	"testing"
)

// =============================================================================
// detectServiceByPort Tests
// =============================================================================

func TestDetectServiceByPort(t *testing.T) {
	tests := []struct {
		port int
		want string
	}{
		{21, "ftp"},
		{22, "ssh"},
		{25, "smtp"},
		{53, "dns"},
		{80, "http"},
		{110, "pop3"},
		{143, "imap"},
		{443, "https"},
		{465, "smtps"},
		{587, "smtp-submission"},
		{993, "imaps"},
		{995, "pop3s"},
		{3306, "mysql"},
		{5432, "postgresql"},
		{6379, "redis"},
		{8080, "http-alt"},
		{8443, "https-alt"},
		{9000, "php-fpm"},
		{11211, "memcached"},
		{12345, "unknown"},
		{0, "unknown"},
		{65535, "unknown"},
	}

	for _, tt := range tests {
		got := detectServiceByPort(tt.port)
		if got != tt.want {
			t.Errorf("detectServiceByPort(%d) = %q, want %q", tt.port, got, tt.want)
		}
	}
}

// =============================================================================
// mapServicesToCategories Tests
// =============================================================================

func TestMapServicesToCategories_HTTP(t *testing.T) {
	services := []Service{{Port: 80, Name: "http", Protocol: "tcp"}}
	categories := mapServicesToCategories(services)

	catSet := make(map[string]bool)
	for _, c := range categories {
		catSet[c] = true
	}

	expected := []string{
		"emerging-web_server",
		"emerging-web_client",
		"emerging-exploit",
		"emerging-scan",
		// Always included
		"emerging-attack_response",
		"emerging-dos",
		"emerging-policy",
	}

	for _, exp := range expected {
		if !catSet[exp] {
			t.Errorf("expected category %q for HTTP service, not found in %v", exp, categories)
		}
	}
}

func TestMapServicesToCategories_SSH(t *testing.T) {
	services := []Service{{Port: 22, Name: "ssh", Protocol: "tcp"}}
	categories := mapServicesToCategories(services)

	catSet := make(map[string]bool)
	for _, c := range categories {
		catSet[c] = true
	}

	if !catSet["emerging-ssh"] {
		t.Error("expected emerging-ssh for SSH service")
	}
	if !catSet["emerging-exploit"] {
		t.Error("expected emerging-exploit for SSH service")
	}
}

func TestMapServicesToCategories_DNS(t *testing.T) {
	services := []Service{{Port: 53, Name: "dns", Protocol: "udp"}}
	categories := mapServicesToCategories(services)

	catSet := make(map[string]bool)
	for _, c := range categories {
		catSet[c] = true
	}

	if !catSet["emerging-dns"] {
		t.Error("expected emerging-dns for DNS service")
	}
	if !catSet["emerging-malware"] {
		t.Error("expected emerging-malware for DNS service")
	}
}

func TestMapServicesToCategories_MySQL(t *testing.T) {
	services := []Service{{Port: 3306, Name: "mysql", Protocol: "tcp"}}
	categories := mapServicesToCategories(services)

	catSet := make(map[string]bool)
	for _, c := range categories {
		catSet[c] = true
	}

	if !catSet["emerging-sql"] {
		t.Error("expected emerging-sql for MySQL service")
	}
}

func TestMapServicesToCategories_AlwaysIncluded(t *testing.T) {
	// Even with no services, critical categories should be included
	services := []Service{}
	categories := mapServicesToCategories(services)

	catSet := make(map[string]bool)
	for _, c := range categories {
		catSet[c] = true
	}

	alwaysIncluded := []string{
		"emerging-attack_response",
		"emerging-dos",
		"emerging-policy",
	}

	for _, exp := range alwaysIncluded {
		if !catSet[exp] {
			t.Errorf("expected always-included category %q, not found in %v", exp, categories)
		}
	}
}

func TestMapServicesToCategories_MultipleServices(t *testing.T) {
	services := []Service{
		{Port: 80, Name: "http", Protocol: "tcp"},
		{Port: 443, Name: "https", Protocol: "tcp"},
		{Port: 22, Name: "ssh", Protocol: "tcp"},
		{Port: 25, Name: "smtp", Protocol: "tcp"},
	}
	categories := mapServicesToCategories(services)

	catSet := make(map[string]bool)
	for _, c := range categories {
		catSet[c] = true
	}

	expectedCategories := []string{
		"emerging-web_server",
		"emerging-tls",
		"emerging-ssh",
		"emerging-smtp",
		"emerging-malware",
	}

	for _, exp := range expectedCategories {
		if !catSet[exp] {
			t.Errorf("expected category %q for multiple services, not found in %v", exp, categories)
		}
	}
}

func TestMapServicesToCategories_NoDuplicates(t *testing.T) {
	// HTTP and HTTP-Alt should both map to emerging-web_server but only once
	services := []Service{
		{Port: 80, Name: "http", Protocol: "tcp"},
		{Port: 8080, Name: "http-alt", Protocol: "tcp"},
	}
	categories := mapServicesToCategories(services)

	// Count occurrences
	counts := make(map[string]int)
	for _, c := range categories {
		counts[c]++
	}

	for cat, count := range counts {
		if count > 1 {
			t.Errorf("category %q appears %d times (expected at most 1)", cat, count)
		}
	}
}

// =============================================================================
// getTLSVersion Tests
// =============================================================================

func TestGetTLSVersion(t *testing.T) {
	tests := []struct {
		version uint16
		want    string
	}{
		{tls.VersionTLS10, "1.0"},
		{tls.VersionTLS11, "1.1"},
		{tls.VersionTLS12, "1.2"},
		{tls.VersionTLS13, "1.3"},
		{0, "unknown"},
		{9999, "unknown"},
	}

	for _, tt := range tests {
		got := getTLSVersion(tt.version)
		if got != tt.want {
			t.Errorf("getTLSVersion(%d) = %q, want %q", tt.version, got, tt.want)
		}
	}
}

// =============================================================================
// ScanResult.GetServiceSummary Tests
// =============================================================================

func TestGetServiceSummary_NoServices(t *testing.T) {
	sr := &ScanResult{
		Services:       []Service{},
		RuleCategories: []string{},
	}

	summary := sr.GetServiceSummary()
	if summary != "No services detected" {
		t.Errorf("expected %q, got %q", "No services detected", summary)
	}
}

func TestGetServiceSummary_WithServices(t *testing.T) {
	sr := &ScanResult{
		Services: []Service{
			{Port: 80, Name: "http", Protocol: "tcp"},
			{Port: 22, Name: "ssh", Protocol: "tcp", Banner: "OpenSSH_8.0"},
		},
		RuleCategories: []string{"emerging-web_server", "emerging-ssh"},
	}

	summary := sr.GetServiceSummary()
	if summary == "No services detected" {
		t.Error("expected service summary, got empty message")
	}
	if len(summary) < 20 {
		t.Errorf("expected meaningful summary, got %q", summary)
	}
}

// =============================================================================
// CommonPorts Tests
// =============================================================================

func TestCommonPorts_NotEmpty(t *testing.T) {
	if len(CommonPorts) == 0 {
		t.Error("expected non-empty CommonPorts list")
	}
}

func TestCommonPorts_ContainsEssentialPorts(t *testing.T) {
	essential := []int{22, 80, 443, 25, 53}
	portSet := make(map[int]bool)
	for _, p := range CommonPorts {
		portSet[p] = true
	}

	for _, port := range essential {
		if !portSet[port] {
			t.Errorf("CommonPorts missing essential port %d", port)
		}
	}
}

// =============================================================================
// DefaultProbeConfig Tests
// =============================================================================

func TestDefaultProbeConfig(t *testing.T) {
	if !DefaultProbeConfig.TLSSkipVerify {
		t.Error("expected TLSSkipVerify=true for default probe config")
	}
	if !DefaultProbeConfig.DevMode {
		t.Error("expected DevMode=true for default probe config")
	}
}
