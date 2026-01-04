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
func isPublicIP(ipStr string) bool {
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return false
	}

	// Check for private ranges
	privateRanges := []struct {
		start string
		end   string
	}{
		{"10.0.0.0", "10.255.255.255"},
		{"172.16.0.0", "172.31.255.255"},
		{"192.168.0.0", "192.168.255.255"},
		{"127.0.0.0", "127.255.255.255"},
		{"169.254.0.0", "169.254.255.255"},
		{"224.0.0.0", "239.255.255.255"},
		{"100.64.0.0", "100.127.255.255"},
		{"192.0.0.0", "192.0.0.255"},
		{"192.0.2.0", "192.0.2.255"},
		{"198.18.0.0", "198.19.255.255"},
		{"198.51.100.0", "198.51.100.255"},
		{"203.0.113.0", "203.0.113.255"},
		{"240.0.0.0", "255.255.255.255"},
		{"0.0.0.0", "0.255.255.255"},
	}

	for _, r := range privateRanges {
		start := net.ParseIP(r.start)
		end := net.ParseIP(r.end)
		if start != nil && end != nil {
			if bytesInRange(ip, start, end) {
				return false
			}
		}
	}

	return true
}

// bytesInRange checks if IP is in range
func bytesInRange(ip, start, end net.IP) bool {
	ipv4 := ip.To4()
	startv4 := start.To4()
	endv4 := end.To4()

	if ipv4 == nil || startv4 == nil || endv4 == nil {
		return false
	}

	for i := 0; i < 4; i++ {
		if ipv4[i] < startv4[i] || ipv4[i] > endv4[i] {
			return false
		}
		if ipv4[i] > startv4[i] && ipv4[i] < endv4[i] {
			return true
		}
	}

	return true
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
