// =============================================================================
// NFTBan - Network Utilities
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="ip"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="IP address utilities, whitelist checking, and CIDR operations"
// meta:input="IP address strings"
// meta:output="Validated and normalized IP data"
// meta:depends="net"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package netutil provides network utility functions for NFTBan
// Centralizes IP address handling, whitelist checking, and CIDR operations
package netutil

import (
	"bufio"
	"fmt"
	"net"
	"net/http"
	"os"
	"strings"
)

// =============================================================================
// Client IP Extraction
// =============================================================================

// GetClientIP extracts the real client IP address from an HTTP request.
// SECURITY: Only trusts X-Forwarded-For and X-Real-IP headers when the
// direct connection comes from a trusted proxy (loopback or private network).
// This prevents IP spoofing via forged headers from external clients.
func GetClientIP(r *http.Request) string {
	// Extract direct connection IP first
	remoteIP, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		remoteIP = r.RemoteAddr
	}

	// Only trust proxy headers from trusted sources (loopback/private networks)
	if isTrustedProxy(remoteIP) {
		// Check X-Forwarded-For header (may contain multiple IPs)
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			ips := strings.Split(xff, ",")
			if len(ips) > 0 {
				return strings.TrimSpace(ips[0])
			}
		}

		// Check X-Real-IP header
		if xri := r.Header.Get("X-Real-IP"); xri != "" {
			return xri
		}
	}

	return remoteIP
}

// isTrustedProxy checks if an IP is from a trusted proxy (loopback or RFC1918 private).
func isTrustedProxy(ip string) bool {
	parsed := net.ParseIP(ip)
	if parsed == nil {
		return false
	}
	return parsed.IsLoopback() || parsed.IsPrivate()
}

// =============================================================================
// IP Whitelist Checking
// =============================================================================

// IsIPWhitelisted checks if an IP is in a whitelist file
// Returns (true, nil) if IP is whitelisted
// Returns (false, nil) if IP is not whitelisted or file doesn't exist
// Returns (false, error) on file read errors
func IsIPWhitelisted(clientIP string, whitelistFile string) (bool, error) {
	// Parse client IP
	ip := net.ParseIP(clientIP)
	if ip == nil {
		return false, nil
	}

	// Open whitelist file
	file, err := os.Open(whitelistFile)
	if err != nil {
		// If file doesn't exist, deny access (security default)
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, err
	}
	defer file.Close()

	// Read whitelist entries
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())

		// Skip comments and empty lines
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Check if line is CIDR or single IP
		if strings.Contains(line, "/") {
			// Parse CIDR
			_, ipnet, err := net.ParseCIDR(line)
			if err != nil {
				continue
			}
			if ipnet.Contains(ip) {
				return true, nil
			}
		} else {
			// Parse single IP
			whiteIP := net.ParseIP(line)
			if whiteIP != nil && whiteIP.Equal(ip) {
				return true, nil
			}
		}
	}

	if err := scanner.Err(); err != nil {
		return false, err
	}

	return false, nil
}

// =============================================================================
// IP Parsing and Validation
// =============================================================================

// ParseIP parses an IP address string and returns the net.IP
// Returns nil if the string is not a valid IP
func ParseIP(ipStr string) net.IP {
	return net.ParseIP(ipStr)
}

// ParseCIDR parses a CIDR string and returns the IP and network
func ParseCIDR(cidr string) (net.IP, *net.IPNet, error) {
	return net.ParseCIDR(cidr)
}

// IsIPv4 checks if an IP string represents an IPv4 address
func IsIPv4(ipStr string) bool {
	ip := net.ParseIP(ipStr)
	return ip != nil && ip.To4() != nil
}

// IsIPv6 checks if an IP string represents an IPv6 address
func IsIPv6(ipStr string) bool {
	ip := net.ParseIP(ipStr)
	return ip != nil && ip.To4() == nil
}

// IsCIDR checks if a string is a valid CIDR notation
func IsCIDR(s string) bool {
	_, _, err := net.ParseCIDR(s)
	return err == nil
}

// IsValidIP checks if a string is a valid IP address (v4 or v6)
func IsValidIP(ipStr string) bool {
	return net.ParseIP(ipStr) != nil
}

// =============================================================================
// IP Network Operations
// =============================================================================

// IPContainedInCIDR checks if an IP is contained within a CIDR range
func IPContainedInCIDR(ipStr, cidr string) bool {
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return false
	}

	_, ipnet, err := net.ParseCIDR(cidr)
	if err != nil {
		return false
	}

	return ipnet.Contains(ip)
}

// GetIPFamily returns "ipv4" or "ipv6" based on the IP address
func GetIPFamily(ipStr string) string {
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return ""
	}
	if ip.To4() != nil {
		return "ipv4"
	}
	return "ipv6"
}

// NormalizeIP returns a normalized string representation of an IP
// Useful for consistent map keys and comparisons
func NormalizeIP(ipStr string) string {
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return ipStr // Return original if not valid
	}
	return ip.String()
}

// =============================================================================
// Private IP Detection
// =============================================================================

// Private IP ranges
var (
	privateIPv4Ranges = []string{
		"10.0.0.0/8",
		"172.16.0.0/12",
		"192.168.0.0/16",
		"127.0.0.0/8",
	}
	privateIPv6Ranges = []string{
		"::1/128",
		"fc00::/7",
		"fe80::/10",
	}
)

// IsPrivateIP checks if an IP is a private/local address
func IsPrivateIP(ipStr string) bool {
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return false
	}

	// Check IPv4 private ranges
	if ip.To4() != nil {
		for _, cidr := range privateIPv4Ranges {
			_, ipnet, _ := net.ParseCIDR(cidr)
			if ipnet.Contains(ip) {
				return true
			}
		}
	} else {
		// Check IPv6 private ranges
		for _, cidr := range privateIPv6Ranges {
			_, ipnet, _ := net.ParseCIDR(cidr)
			if ipnet.Contains(ip) {
				return true
			}
		}
	}

	return false
}

// IsPublicIP checks if an IP is a public/routable address
func IsPublicIP(ipStr string) bool {
	return IsValidIP(ipStr) && !IsPrivateIP(ipStr)
}

// =============================================================================
// IP Validation for Lists (blacklist/whitelist)
// =============================================================================

// ValidateAndNormalizeIP validates and normalizes an IP or CIDR
// Returns: (normalized string, isIPv4, error)
// Used by blacklist/whitelist loaders for consistent IP handling
func ValidateAndNormalizeIP(ipStr string) (string, bool, error) {
	ipStr = strings.TrimSpace(ipStr)
	if ipStr == "" {
		return "", false, fmt.Errorf("empty IP string")
	}

	// Handle CIDR
	if strings.Contains(ipStr, "/") {
		_, ipNet, err := net.ParseCIDR(ipStr)
		if err != nil {
			return "", false, fmt.Errorf("invalid CIDR: %s", ipStr)
		}
		return ipNet.String(), ipNet.IP.To4() != nil, nil
	}

	// Handle single IP
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return "", false, fmt.Errorf("invalid IP: %s", ipStr)
	}

	return ip.String(), ip.To4() != nil, nil
}
