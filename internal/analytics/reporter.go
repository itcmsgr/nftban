// =============================================================================
// NFTBan - Analytics Reporter for Batch GeoIP and Module Status
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="reporter"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Efficient batch operations for report generation with GeoIP lookup"
// meta:input="IP addresses, metrics files"
// meta:output="Analytics reports with geographic data"
// meta:depends="github.com/oschwald/geoip2-golang"
// meta:inventory.files="/var/lib/nftban/geoip/*.mmdb"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package analytics provides efficient batch operations for report generation
package analytics

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"time"

	"github.com/oschwald/geoip2-golang"
)

// Report contains aggregated analytics data for email reports
type Report struct {
	TopIPs       []IPInfo       `json:"top_ips"`
	ModuleStatus []ModuleStatus `json:"module_status"`
	Timestamp    time.Time      `json:"timestamp"`
}

// IPInfo contains IP address with geographic information
type IPInfo struct {
	IP      string `json:"ip"`
	Country string `json:"country"`
	City    string `json:"city"`
}

// ModuleStatus contains module name and status
type ModuleStatus struct {
	Module  string `json:"module"`
	Name    string `json:"name"`
	Enabled bool   `json:"enabled"`
	Active  bool   `json:"active"`
}

// Reporter handles batch analytics operations
type Reporter struct {
	geoipDB   *geoip2.Reader
	dataDir   string
	metricsDir string
}

// NewReporter creates a new analytics reporter
func NewReporter(dataDir string) (*Reporter, error) {
	// Try to open GeoIP database (check for multiple providers)
	geoipDir := filepath.Join(dataDir, "geoip")
	dbFiles := []string{
		filepath.Join(geoipDir, "dbip-country-lite.mmdb"),  // Default: DB-IP Country
		filepath.Join(geoipDir, "GeoLite2-City.mmdb"),      // Legacy: MaxMind City
		filepath.Join(geoipDir, "GeoLite2-Country.mmdb"),   // Legacy: MaxMind Country
	}

	var db *geoip2.Reader
	var err error

	for _, geoipPath := range dbFiles {
		if _, statErr := os.Stat(geoipPath); statErr == nil {
			db, err = geoip2.Open(geoipPath)
			if err == nil {
				break // Successfully opened
			}
			// Don't fail if GeoIP DB not available, just log
			fmt.Fprintf(os.Stderr, "Warning: GeoIP database not available: %v\n", err)
		}
	}

	return &Reporter{
		geoipDB:    db,
		dataDir:    dataDir,
		metricsDir: filepath.Join(dataDir, "metrics"),
	}, nil
}

// Close closes the GeoIP database
func (r *Reporter) Close() error {
	if r.geoipDB != nil {
		return r.geoipDB.Close()
	}
	return nil
}

// BatchGeoIPLookup performs GeoIP lookup for multiple IPs efficiently
func (r *Reporter) BatchGeoIPLookup(ips []string, limit int) ([]IPInfo, error) {
	if r.geoipDB == nil {
		// Return IPs without geo data if DB not available
		result := make([]IPInfo, 0, min(len(ips), limit))
		for i, ip := range ips {
			if i >= limit {
				break
			}
			if !isPublicIP(ip) {
				continue
			}
			result = append(result, IPInfo{
				IP:      ip,
				Country: "Unknown",
				City:    "",
			})
		}
		return result, nil
	}

	result := make([]IPInfo, 0, min(len(ips), limit))
	count := 0

	for _, ipStr := range ips {
		if count >= limit {
			break
		}

		// Skip private/reserved IPs
		if !isPublicIP(ipStr) {
			continue
		}

		ip := net.ParseIP(ipStr)
		if ip == nil {
			continue
		}

		// Lookup GeoIP data
		record, err := r.geoipDB.City(ip)
		if err != nil {
			// Skip IPs that fail lookup
			continue
		}

		country := "Unknown"
		city := ""

		if record.Country.Names != nil {
			if name, ok := record.Country.Names["en"]; ok {
				country = name
			}
		}

		if record.City.Names != nil {
			if name, ok := record.City.Names["en"]; ok {
				city = name
			}
		}

		result = append(result, IPInfo{
			IP:      ipStr,
			Country: country,
			City:    city,
		})

		count++
	}

	return result, nil
}

// GetModuleStatus reads module status from metrics files
func (r *Reporter) GetModuleStatus() ([]ModuleStatus, error) {
	modules := []struct {
		key  string
		name string
	}{
		{"ddos", "DDoS Protection"},
		{"portscan", "Port Scan Detection"},
		{"login", "Login Monitor"},
		{"feeds", "Threat Feeds"},
		{"geoip", "GeoIP Blocking"},
	}

	result := make([]ModuleStatus, 0, len(modules))

	for _, mod := range modules {
		status := ModuleStatus{
			Module:  mod.key,
			Name:    mod.name,
			Enabled: false,
			Active:  false,
		}

		// Try to read from metrics file
		metricsPath := filepath.Join(r.metricsDir, mod.key+".prom")
		if data, err := os.ReadFile(metricsPath); err == nil {
			// Simple parsing: look for enabled metric
			content := string(data)
			if containsMetric(content, "nftban_"+mod.key+"_enabled", "1") {
				status.Enabled = true
			}
			if containsMetric(content, "nftban_"+mod.key+"_active", "1") {
				status.Active = true
			}
		}

		result = append(result, status)
	}

	return result, nil
}

// GenerateReport creates a full analytics report
func (r *Reporter) GenerateReport(topIPs []string, limit int) (*Report, error) {
	// Batch GeoIP lookup
	ips, err := r.BatchGeoIPLookup(topIPs, limit)
	if err != nil {
		return nil, fmt.Errorf("failed to lookup IPs: %w", err)
	}

	// Get module status
	status, err := r.GetModuleStatus()
	if err != nil {
		return nil, fmt.Errorf("failed to get module status: %w", err)
	}

	return &Report{
		TopIPs:       ips,
		ModuleStatus: status,
		Timestamp:    time.Now(),
	}, nil
}

// ToJSON converts report to JSON
func (r *Report) ToJSON() (string, error) {
	data, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// isPublicIP checks if an IP is public (not private/reserved)
// Optimized: Uses Go's built-in IP classification methods (Go 1.17+)
// instead of manual range parsing on each call.
func isPublicIP(ipStr string) bool {
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return false
	}

	// Use Go's built-in methods for common cases (O(1) instead of O(n) range checks)
	if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() ||
		ip.IsLinkLocalMulticast() || ip.IsMulticast() || ip.IsUnspecified() {
		return false
	}

	// Additional reserved ranges not covered by standard library
	// Pre-parsed at package init for O(1) lookup
	for _, ipNet := range reservedIPNets {
		if ipNet.Contains(ip) {
			return false
		}
	}

	return true
}

// reservedIPNets contains pre-parsed reserved IP ranges not covered by Go's standard methods
// Initialized once at package load for O(1) Contains checks
var reservedIPNets []*net.IPNet

func init() {
	// Additional reserved ranges (RFC 5737 documentation, RFC 6598 CGN, etc.)
	reservedCIDRs := []string{
		"100.64.0.0/10",    // RFC 6598 - Shared Address Space (CGN)
		"192.0.0.0/24",     // RFC 6890 - IETF Protocol Assignments
		"192.0.2.0/24",     // RFC 5737 - Documentation (TEST-NET-1)
		"198.18.0.0/15",    // RFC 2544 - Benchmarking
		"198.51.100.0/24",  // RFC 5737 - Documentation (TEST-NET-2)
		"203.0.113.0/24",   // RFC 5737 - Documentation (TEST-NET-3)
		"240.0.0.0/4",      // RFC 1112 - Reserved for future use
	}

	reservedIPNets = make([]*net.IPNet, 0, len(reservedCIDRs))
	for _, cidr := range reservedCIDRs {
		_, ipNet, err := net.ParseCIDR(cidr)
		if err == nil {
			reservedIPNets = append(reservedIPNets, ipNet)
		}
	}
}

// containsMetric checks if metrics content contains a specific metric value
func containsMetric(content, metricName, expectedValue string) bool {
	// Simple line-by-line search
	// Format: metric_name value
	searchStr := metricName + " " + expectedValue
	return len(content) > 0 && contains(content, searchStr)
}

// contains is a simple substring check
func contains(s, substr string) bool {
	return len(s) >= len(substr) && indexOf(s, substr) >= 0
}

// indexOf finds the first occurrence of substr in s
func indexOf(s, substr string) int {
	n := len(substr)
	for i := 0; i <= len(s)-n; i++ {
		if s[i:i+n] == substr {
			return i
		}
	}
	return -1
}

// min returns the minimum of two integers
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
