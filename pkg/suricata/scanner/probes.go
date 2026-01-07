// =============================================================================
// NFTBan - Service Protocol Probes
// =============================================================================
// SPDX-License-Identifier: GPL-3.0-or-later
// meta:name="probes"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Deep protocol detection for HTTP, SSH, TLS, MySQL, etc."
// meta:input="Host and port"
// meta:output="Service banner and protocol info"
// meta:depends="bufio,crypto/tls,net"
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
	"bufio"
	"crypto/tls"
	"fmt"
	"net"
	"strings"
	"time"
)

// ProbeService performs deep protocol detection on a service
func ProbeService(host string, port int) (*Service, error) {
	service := &Service{
		Port:     port,
		Protocol: "tcp",
		Name:     "unknown",
	}

	// Try different probes based on port
	switch port {
	case 80, 8080:
		if probeHTTP(host, port, service) {
			return service, nil
		}
	case 443, 8443:
		if probeHTTPS(host, port, service) {
			return service, nil
		}
	case 22:
		if probeSSH(host, port, service) {
			return service, nil
		}
	case 3306:
		if probeMySQL(host, port, service) {
			return service, nil
		}
	case 53:
		// DNS is typically UDP, handle separately
		service.Name = "dns"
		service.Protocol = "udp"
		return service, nil
	}

	// Fallback to basic detection
	service.Name = detectServiceByPort(port)
	return service, nil
}

// probeHTTP sends an HTTP request to verify HTTP service
func probeHTTP(host string, port int, service *Service) bool {
	address := net.JoinHostPort(host, fmt.Sprintf("%d", port))
	conn, err := net.DialTimeout("tcp", address, 2*time.Second)
	if err != nil {
		return false
	}
	defer conn.Close()

	// Send HTTP GET request
	request := "GET / HTTP/1.0\r\nHost: localhost\r\n\r\n"
	conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
	_, err = conn.Write([]byte(request))
	if err != nil {
		return false
	}

	// Read response
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	reader := bufio.NewReader(conn)
	response, err := reader.ReadString('\n')
	if err != nil {
		return false
	}

	// Check for HTTP response
	if strings.HasPrefix(response, "HTTP/") {
		service.Name = "http"
		// Extract server banner
		for {
			line, err := reader.ReadString('\n')
			if err != nil || line == "\r\n" {
				break
			}
			if strings.HasPrefix(line, "Server:") {
				service.Banner = strings.TrimSpace(strings.TrimPrefix(line, "Server:"))
				break
			}
		}
		return true
	}

	return false
}

// probeHTTPS attempts TLS handshake to verify HTTPS
func probeHTTPS(host string, port int, service *Service) bool {
	address := net.JoinHostPort(host, fmt.Sprintf("%d", port))
	config := &tls.Config{
		InsecureSkipVerify: true,
	}

	conn, err := tls.DialWithDialer(
		&net.Dialer{Timeout: 2 * time.Second},
		"tcp",
		address,
		config,
	)
	if err != nil {
		return false
	}
	defer conn.Close()

	// Successful TLS handshake
	service.Name = "https"

	// Get TLS version and cipher
	state := conn.ConnectionState()
	service.Banner = fmt.Sprintf("TLS %s", getTLSVersion(state.Version))

	return true
}

// probeSSH reads SSH banner
func probeSSH(host string, port int, service *Service) bool {
	address := net.JoinHostPort(host, fmt.Sprintf("%d", port))
	conn, err := net.DialTimeout("tcp", address, 2*time.Second)
	if err != nil {
		return false
	}
	defer conn.Close()

	// SSH server sends banner immediately
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	reader := bufio.NewReader(conn)
	banner, err := reader.ReadString('\n')
	if err != nil {
		return false
	}

	// Check for SSH banner
	if strings.HasPrefix(banner, "SSH-") {
		service.Name = "ssh"
		service.Banner = strings.TrimSpace(banner)
		return true
	}

	return false
}

// probeMySQL attempts MySQL handshake
func probeMySQL(host string, port int, service *Service) bool {
	address := net.JoinHostPort(host, fmt.Sprintf("%d", port))
	conn, err := net.DialTimeout("tcp", address, 2*time.Second)
	if err != nil {
		return false
	}
	defer conn.Close()

	// MySQL server sends handshake packet immediately
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	buffer := make([]byte, 128)
	n, err := conn.Read(buffer)
	if err != nil || n < 5 {
		return false
	}

	// Check for MySQL protocol version (first byte after packet length)
	// MySQL handshake starts with protocol version 10 (0x0a)
	if n > 4 && buffer[4] == 0x0a {
		service.Name = "mysql"
		// MySQL version string starts at byte 5
		if n > 5 {
			versionEnd := 5
			for versionEnd < n && buffer[versionEnd] != 0 {
				versionEnd++
			}
			if versionEnd < n {
				service.Banner = string(buffer[5:versionEnd])
			}
		}
		return true
	}

	return false
}

// getTLSVersion converts TLS version number to string
func getTLSVersion(version uint16) string {
	switch version {
	case tls.VersionTLS10:
		return "1.0"
	case tls.VersionTLS11:
		return "1.1"
	case tls.VersionTLS12:
		return "1.2"
	case tls.VersionTLS13:
		return "1.3"
	default:
		return "unknown"
	}
}

// DeepScan performs comprehensive service detection with protocol probes
func DeepScan(host string, ports []int) (*ScanResult, error) {
	result := &ScanResult{
		Services:       make([]Service, 0),
		RuleCategories: make([]string, 0),
	}

	fmt.Println("Performing deep service scan...")

	for _, port := range ports {
		service, err := ProbeService(host, port)
		if err == nil && service.Name != "unknown" {
			result.Services = append(result.Services, *service)
			fmt.Printf("  ✓ %s on port %d", service.Name, service.Port)
			if service.Banner != "" {
				fmt.Printf(" (%s)", service.Banner)
			}
			fmt.Println()
		}
	}

	// Map services to rule categories
	result.RuleCategories = mapServicesToCategories(result.Services)

	return result, nil
}
