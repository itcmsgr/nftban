// =============================================================================
// NFTBan - Service Protocol Probes
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="probes"
// meta:type="package"
// meta:version="1.0.0"
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

	"github.com/itcmsgr/nftban/internal/logx"
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
	case 21:
		if probeFTP(host, port, service) {
			return service, nil
		}
	case 25, 465, 587:
		if probeSMTP(host, port, service) {
			return service, nil
		}
	case 110, 995:
		if probePOP3(host, port, service) {
			return service, nil
		}
	case 143, 993:
		if probeIMAP(host, port, service) {
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

// ProbeConfig holds configuration for service probing
type ProbeConfig struct {
	// TLSSkipVerify allows skipping TLS verification during probes.
	// This is only for service detection, not for establishing secure connections.
	// Default: true (required for probing unknown services)
	TLSSkipVerify bool
	// DevMode enables less secure options. Must be true for TLSSkipVerify to work.
	DevMode bool
}

// DefaultProbeConfig returns the default probe configuration
// Note: Service probing inherently requires InsecureSkipVerify to detect
// services with self-signed or invalid certificates
var DefaultProbeConfig = ProbeConfig{
	TLSSkipVerify: true,
	DevMode:       true, // Service probing is a development/diagnostic tool
}

// probeHTTPS attempts TLS handshake to verify HTTPS
func probeHTTPS(host string, port int, service *Service) bool {
	return probeHTTPSWithConfig(host, port, service, DefaultProbeConfig)
}

// probeHTTPSWithConfig attempts TLS handshake with explicit configuration
func probeHTTPSWithConfig(host string, port int, service *Service, cfg ProbeConfig) bool {
	address := net.JoinHostPort(host, fmt.Sprintf("%d", port))
	config := &tls.Config{
		MinVersion: tls.VersionTLS12,
	}

	// Service probing requires InsecureSkipVerify to detect services with
	// self-signed certificates. This is acceptable because we're only detecting
	// if a TLS service exists, not establishing a trusted connection.
	if cfg.TLSSkipVerify {
		if cfg.DevMode {
			config.InsecureSkipVerify = true
			// Only log on first probe to avoid spam
			logx.Debug("HTTPS probe using InsecureSkipVerify for service detection on %s", address)
		} else {
			logx.Warn("HTTPS probe TLSSkipVerify requested but DevMode not enabled - probe may fail for self-signed certs")
		}
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

// probeSMTP checks for SMTP server greeting (220 response)
func probeSMTP(host string, port int, service *Service) bool {
	address := net.JoinHostPort(host, fmt.Sprintf("%d", port))
	conn, err := net.DialTimeout("tcp", address, 2*time.Second)
	if err != nil {
		return false
	}
	defer conn.Close()

	// SMTP server sends 220 greeting immediately
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	reader := bufio.NewReader(conn)
	banner, err := reader.ReadString('\n')
	if err != nil {
		return false
	}

	// Check for SMTP 220 greeting
	if strings.HasPrefix(banner, "220") {
		service.Name = "smtp"
		service.Banner = strings.TrimSpace(banner)
		return true
	}

	return false
}

// probeFTP checks for FTP server greeting (220 response)
func probeFTP(host string, port int, service *Service) bool {
	address := net.JoinHostPort(host, fmt.Sprintf("%d", port))
	conn, err := net.DialTimeout("tcp", address, 2*time.Second)
	if err != nil {
		return false
	}
	defer conn.Close()

	// FTP server sends 220 greeting immediately
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	reader := bufio.NewReader(conn)
	banner, err := reader.ReadString('\n')
	if err != nil {
		return false
	}

	// Check for FTP 220 greeting
	if strings.HasPrefix(banner, "220") {
		service.Name = "ftp"
		service.Banner = strings.TrimSpace(banner)
		return true
	}

	return false
}

// probePOP3 checks for POP3 server greeting (+OK response)
func probePOP3(host string, port int, service *Service) bool {
	address := net.JoinHostPort(host, fmt.Sprintf("%d", port))
	conn, err := net.DialTimeout("tcp", address, 2*time.Second)
	if err != nil {
		return false
	}
	defer conn.Close()

	// POP3 server sends +OK greeting immediately
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	reader := bufio.NewReader(conn)
	banner, err := reader.ReadString('\n')
	if err != nil {
		return false
	}

	// Check for POP3 +OK greeting
	if strings.HasPrefix(banner, "+OK") {
		service.Name = "pop3"
		service.Banner = strings.TrimSpace(banner)
		return true
	}

	return false
}

// probeIMAP checks for IMAP server greeting (* OK response)
func probeIMAP(host string, port int, service *Service) bool {
	address := net.JoinHostPort(host, fmt.Sprintf("%d", port))
	conn, err := net.DialTimeout("tcp", address, 2*time.Second)
	if err != nil {
		return false
	}
	defer conn.Close()

	// IMAP server sends * OK greeting immediately
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	reader := bufio.NewReader(conn)
	banner, err := reader.ReadString('\n')
	if err != nil {
		return false
	}

	// Check for IMAP * OK greeting
	if strings.HasPrefix(banner, "* OK") {
		service.Name = "imap"
		service.Banner = strings.TrimSpace(banner)
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
