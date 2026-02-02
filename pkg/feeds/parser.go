// =============================================================================
// NFTBan - Feed Parser
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="parser"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Unified parser for threat feed and blacklist file lines"
// meta:input="Feed file lines"
// meta:output="Parsed IP/CIDR entries"
// meta:depends="github.com/itcmsgr/nftban/pkg/netutil"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package feeds

import (
	"encoding/binary"
	"fmt"
	"net"
	"strings"

	"github.com/itcmsgr/nftban/pkg/netutil"
)

// ParsedEntry represents a parsed feed line
type ParsedEntry struct {
	IPv4   bool   // true if IPv4, false if IPv6
	IsCIDR bool   // true if CIDR range, false if single IP
	Value  string // normalized IP or CIDR
}

// ParseFeedLine parses a single line from a feed/blacklist/whitelist file
// Handles multiple formats:
//   - Plain IP: "1.2.3.4"
//   - CIDR: "1.2.3.0/24"
//   - IP range: "1.2.3.4-1.2.3.10" (returns multiple entries)
//   - With inline comment: "1.2.3.4 # some comment"
//   - With whitespace-separated fields: "1.2.3.4   reason   timestamp"
//
// Returns nil, nil for empty lines and comments (skip)
// Returns nil, error for invalid IPs/CIDRs
// Note: For IP ranges, use ParseFeedLineMulti to get all IPs in the range
func ParseFeedLine(line string) (*ParsedEntry, error) {
	line = strings.TrimSpace(line)

	// Skip empty lines and full-line comments
	if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
		return nil, nil
	}

	// Handle inline comments (both # and ;)
	if idx := strings.Index(line, "#"); idx >= 0 {
		line = strings.TrimSpace(line[:idx])
		if line == "" {
			return nil, nil
		}
	}
	if idx := strings.Index(line, ";"); idx >= 0 {
		line = strings.TrimSpace(line[:idx])
		if line == "" {
			return nil, nil
		}
	}

	// Handle whitespace-separated format (IP<whitespace>comment/reason)
	// Only take the first field (the IP/CIDR)
	fields := strings.Fields(line)
	if len(fields) == 0 {
		return nil, nil
	}
	ipStr := fields[0]

	// Parse CIDR
	if strings.Contains(ipStr, "/") {
		_, ipNet, err := net.ParseCIDR(ipStr)
		if err != nil {
			return nil, fmt.Errorf("invalid CIDR: %s", ipStr)
		}
		return &ParsedEntry{
			IPv4:   ipNet.IP.To4() != nil,
			IsCIDR: true,
			Value:  ipNet.String(),
		}, nil
	}

	// Parse IP range (e.g., "1.2.3.4-1.2.3.10")
	// For single entry return, just return the start IP
	// Use ParseFeedLineMulti for full range expansion
	if strings.Contains(ipStr, "-") {
		parts := strings.SplitN(ipStr, "-", 2)
		if len(parts) == 2 {
			startIP := net.ParseIP(strings.TrimSpace(parts[0]))
			endIP := net.ParseIP(strings.TrimSpace(parts[1]))
			if startIP != nil && endIP != nil {
				// Return the start IP; use ParseFeedLineMulti for full range
				return &ParsedEntry{
					IPv4:   startIP.To4() != nil,
					IsCIDR: false,
					Value:  startIP.String(),
				}, nil
			}
			return nil, fmt.Errorf("invalid IP range: %s", ipStr)
		}
	}

	// Parse single IP
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return nil, fmt.Errorf("invalid IP: %s", ipStr)
	}

	// Normalize IP representation
	normalized := ip.String()

	return &ParsedEntry{
		IPv4:   ip.To4() != nil,
		IsCIDR: false,
		Value:  normalized,
	}, nil
}

// ParseFeedLineStrict is like ParseFeedLine but returns error for invalid entries
// Use this when you want to know about parsing failures
func ParseFeedLineStrict(line string) (*ParsedEntry, error) {
	return ParseFeedLine(line)
}

// ParseFeedLineSilent parses a line and returns nil for both skip and error cases
// Use this when you want to silently ignore invalid entries (like the original loader)
func ParseFeedLineSilent(line string) *ParsedEntry {
	entry, _ := ParseFeedLine(line)
	return entry
}

// ParseFeedLineMulti parses a line and expands IP ranges into multiple entries.
// For IP ranges like "1.2.3.4-1.2.3.10", returns all IPs in the range.
// For single IPs and CIDRs, returns a slice with one entry.
// Returns nil, nil for empty lines and comments (skip).
// Returns nil, error for invalid IPs/CIDRs/ranges.
func ParseFeedLineMulti(line string) ([]*ParsedEntry, error) {
	line = strings.TrimSpace(line)

	// Skip empty lines and full-line comments
	if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
		return nil, nil
	}

	// Handle inline comments (both # and ;)
	if idx := strings.Index(line, "#"); idx >= 0 {
		line = strings.TrimSpace(line[:idx])
		if line == "" {
			return nil, nil
		}
	}
	if idx := strings.Index(line, ";"); idx >= 0 {
		line = strings.TrimSpace(line[:idx])
		if line == "" {
			return nil, nil
		}
	}

	// Handle whitespace-separated format (IP<whitespace>comment/reason)
	fields := strings.Fields(line)
	if len(fields) == 0 {
		return nil, nil
	}
	ipStr := fields[0]

	// Parse CIDR - return single entry
	if strings.Contains(ipStr, "/") {
		_, ipNet, err := net.ParseCIDR(ipStr)
		if err != nil {
			return nil, fmt.Errorf("invalid CIDR: %s", ipStr)
		}
		return []*ParsedEntry{{
			IPv4:   ipNet.IP.To4() != nil,
			IsCIDR: true,
			Value:  ipNet.String(),
		}}, nil
	}

	// Parse IP range (e.g., "1.2.3.4-1.2.3.10")
	if strings.Contains(ipStr, "-") {
		parts := strings.SplitN(ipStr, "-", 2)
		if len(parts) == 2 {
			startIP := net.ParseIP(strings.TrimSpace(parts[0]))
			endIP := net.ParseIP(strings.TrimSpace(parts[1]))
			if startIP == nil || endIP == nil {
				return nil, fmt.Errorf("invalid IP range: %s", ipStr)
			}

			// Expand IP range
			entries, err := expandIPRange(startIP, endIP)
			if err != nil {
				return nil, fmt.Errorf("invalid IP range %s: %w", ipStr, err)
			}
			return entries, nil
		}
	}

	// Parse single IP
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return nil, fmt.Errorf("invalid IP: %s", ipStr)
	}

	return []*ParsedEntry{{
		IPv4:   ip.To4() != nil,
		IsCIDR: false,
		Value:  ip.String(),
	}}, nil
}

// expandIPRange expands a start-end IP range into individual IP entries.
// Supports both IPv4 and IPv6 ranges.
// Returns error if range is invalid (end < start) or too large (>65536 IPs).
func expandIPRange(startIP, endIP net.IP) ([]*ParsedEntry, error) {
	// Normalize to same format
	start4 := startIP.To4()
	end4 := endIP.To4()

	if (start4 != nil) != (end4 != nil) {
		return nil, fmt.Errorf("mixed IPv4/IPv6 range not supported")
	}

	isIPv4 := start4 != nil

	var entries []*ParsedEntry

	if isIPv4 {
		// IPv4 range expansion
		startInt := binary.BigEndian.Uint32(start4)
		endInt := binary.BigEndian.Uint32(end4)

		if endInt < startInt {
			return nil, fmt.Errorf("end IP is before start IP")
		}

		rangeSize := endInt - startInt + 1
		if rangeSize > 65536 {
			return nil, fmt.Errorf("IP range too large (%d IPs, max 65536)", rangeSize)
		}

		entries = make([]*ParsedEntry, 0, rangeSize)
		ipBytes := make([]byte, 4)
		for i := startInt; i <= endInt; i++ {
			binary.BigEndian.PutUint32(ipBytes, i)
			ip := net.IP(ipBytes).String()
			entries = append(entries, &ParsedEntry{
				IPv4:   true,
				IsCIDR: false,
				Value:  ip,
			})
			// Re-allocate for next iteration
			ipBytes = make([]byte, 4)
		}
	} else {
		// IPv6 range expansion - only support small ranges
		start16 := startIP.To16()
		end16 := endIP.To16()

		// Compare IPs byte by byte
		cmp := 0
		for i := 0; i < 16; i++ {
			if start16[i] < end16[i] {
				cmp = -1
				break
			} else if start16[i] > end16[i] {
				cmp = 1
				break
			}
		}
		if cmp > 0 {
			return nil, fmt.Errorf("end IP is before start IP")
		}

		// For IPv6, only support ranges where only last 2 bytes differ
		for i := 0; i < 14; i++ {
			if start16[i] != end16[i] {
				return nil, fmt.Errorf("IPv6 range too large (only last 16 bits can differ)")
			}
		}

		startLast := uint16(start16[14])<<8 | uint16(start16[15])
		endLast := uint16(end16[14])<<8 | uint16(end16[15])

		rangeSize := int(endLast) - int(startLast) + 1
		if rangeSize > 65536 {
			return nil, fmt.Errorf("IP range too large (%d IPs, max 65536)", rangeSize)
		}

		entries = make([]*ParsedEntry, 0, rangeSize)
		for i := startLast; i <= endLast; i++ {
			ipBytes := make([]byte, 16)
			copy(ipBytes, start16[:14])
			ipBytes[14] = byte(i >> 8)
			ipBytes[15] = byte(i & 0xff)
			ip := net.IP(ipBytes).String()
			entries = append(entries, &ParsedEntry{
				IPv4:   false,
				IsCIDR: false,
				Value:  ip,
			})
		}
	}

	return entries, nil
}

// IsIPv4 checks if an IP string is IPv4
// Delegates to netutil.IsIPv4 for consistency
func IsIPv4(ipStr string) bool {
	return netutil.IsIPv4(ipStr)
}

// IsIPv6 checks if an IP string is IPv6
// Delegates to netutil.IsIPv6 for consistency
func IsIPv6(ipStr string) bool {
	return netutil.IsIPv6(ipStr)
}

// IsCIDR checks if a string is a valid CIDR
// Delegates to netutil.IsCIDR for consistency
func IsCIDR(s string) bool {
	return netutil.IsCIDR(s)
}
