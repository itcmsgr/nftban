// =============================================================================
// NFTBan - Network Service Detector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="detector"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Detects running network services for Suricata rule optimization"
// meta:input="Network ports"
// meta:output="Service detection results"
// meta:depends="net,time"
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
	"fmt"
	"net"
	"time"
)

// Service represents a detected network service
type Service struct {
	Port     int
	Protocol string // tcp/udp
	Name     string // http, https, ssh, mysql, dns, etc.
	Banner   string // Service banner/version if detected
}

// ScanResult contains all detected services
type ScanResult struct {
	Services      []Service
	RuleCategories []string // Suricata rule categories to enable
}

// CommonPorts defines the ports to scan
var CommonPorts = []int{
	21,    // FTP
	22,    // SSH
	25,    // SMTP
	53,    // DNS
	80,    // HTTP
	110,   // POP3
	143,   // IMAP
	443,   // HTTPS
	465,   // SMTPS
	587,   // SMTP Submission
	993,   // IMAPS
	995,   // POP3S
	3306,  // MySQL
	5432,  // PostgreSQL
	6379,  // Redis
	8080,  // HTTP-Alt
	8443,  // HTTPS-Alt
	9000,  // PHP-FPM
	11211, // Memcached
}

// ScanLocalhost scans localhost for running services
func ScanLocalhost() (*ScanResult, error) {
	result := &ScanResult{
		Services:       make([]Service, 0),
		RuleCategories: make([]string, 0),
	}

	fmt.Println("Scanning localhost for services...")

	for _, port := range CommonPorts {
		if service := scanPort("127.0.0.1", port); service != nil {
			result.Services = append(result.Services, *service)
			fmt.Printf("  ✓ Detected: %s on port %d\n", service.Name, service.Port)
		}
	}

	// Map services to Suricata rule categories
	result.RuleCategories = mapServicesToCategories(result.Services)

	return result, nil
}

// scanPort attempts to connect to a port and detect the service
func scanPort(host string, port int) *Service {
	address := net.JoinHostPort(host, fmt.Sprintf("%d", port))
	conn, err := net.DialTimeout("tcp", address, 1*time.Second)
	if err != nil {
		return nil // Port closed or filtered
	}
	defer conn.Close()

	// Basic service detection
	service := &Service{
		Port:     port,
		Protocol: "tcp",
		Name:     detectServiceByPort(port),
	}

	// Attempt banner grab for certain services
	if port == 22 || port == 21 || port == 25 {
		banner := grabBanner(conn)
		if banner != "" {
			service.Banner = banner
		}
	}

	return service
}

// detectServiceByPort maps port numbers to service names
func detectServiceByPort(port int) string {
	serviceMap := map[int]string{
		21:    "ftp",
		22:    "ssh",
		25:    "smtp",
		53:    "dns",
		80:    "http",
		110:   "pop3",
		143:   "imap",
		443:   "https",
		465:   "smtps",
		587:   "smtp-submission",
		993:   "imaps",
		995:   "pop3s",
		3306:  "mysql",
		5432:  "postgresql",
		6379:  "redis",
		8080:  "http-alt",
		8443:  "https-alt",
		9000:  "php-fpm",
		11211: "memcached",
	}

	if name, ok := serviceMap[port]; ok {
		return name
	}
	return "unknown"
}

// grabBanner attempts to read the service banner
func grabBanner(conn net.Conn) string {
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	buffer := make([]byte, 512)
	n, err := conn.Read(buffer)
	if err != nil {
		return ""
	}
	return string(buffer[:n])
}

// mapServicesToCategories maps detected services to Suricata rule categories
func mapServicesToCategories(services []Service) []string {
	categories := make(map[string]bool)

	for _, service := range services {
		switch service.Name {
		case "http", "http-alt":
			categories["emerging-web_server"] = true
			categories["emerging-web_client"] = true
			categories["emerging-exploit"] = true
			categories["emerging-scan"] = true

		case "https", "https-alt":
			categories["emerging-tls"] = true
			categories["emerging-web_server"] = true

		case "ssh":
			categories["emerging-ssh"] = true
			categories["emerging-exploit"] = true

		case "ftp":
			categories["emerging-ftp"] = true

		case "smtp", "smtps", "smtp-submission":
			categories["emerging-smtp"] = true
			categories["emerging-malware"] = true

		case "dns":
			categories["emerging-dns"] = true
			categories["emerging-malware"] = true

		case "mysql", "postgresql":
			categories["emerging-sql"] = true
			categories["emerging-exploit"] = true

		case "pop3", "pop3s":
			categories["emerging-pop3"] = true

		case "imap", "imaps":
			categories["emerging-imap"] = true

		case "redis", "memcached":
			categories["emerging-exploit"] = true
		}
	}

	// Always include these critical categories
	categories["emerging-attack_response"] = true
	categories["emerging-dos"] = true
	categories["emerging-policy"] = true

	// Convert map to slice
	result := make([]string, 0, len(categories))
	for cat := range categories {
		result = append(result, cat)
	}

	return result
}

// GetServiceSummary returns a human-readable summary
func (sr *ScanResult) GetServiceSummary() string {
	if len(sr.Services) == 0 {
		return "No services detected"
	}

	summary := fmt.Sprintf("Detected %d service(s):\n", len(sr.Services))
	for _, svc := range sr.Services {
		summary += fmt.Sprintf("  • %s (port %d/%s)\n", svc.Name, svc.Port, svc.Protocol)
		if svc.Banner != "" {
			summary += fmt.Sprintf("    Banner: %s\n", svc.Banner)
		}
	}

	summary += fmt.Sprintf("\nRecommended rule categories (%d):\n", len(sr.RuleCategories))
	for _, cat := range sr.RuleCategories {
		summary += fmt.Sprintf("  • %s\n", cat)
	}

	return summary
}
