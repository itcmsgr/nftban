// =============================================================================
// NFTBan - Feed Parser
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="parser"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Unified parser for threat feed and blacklist file lines"
// meta:input="Feed file lines"
// meta:output="Parsed IP/CIDR entries"
// meta:depends="github.com/itcmsgr/nftban/internal/netutil"
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
	"fmt"
	"net"
	"strings"

	"github.com/itcmsgr/nftban/internal/netutil"
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
	// BUG-L18 FIX: Return multiple entries via ParseFeedLineMulti instead.
	// For backward compatibility, ParseFeedLine returns the start IP as /32.
	if strings.Contains(ipStr, "-") {
		parts := strings.SplitN(ipStr, "-", 2)
		if len(parts) == 2 {
			startIP := net.ParseIP(strings.TrimSpace(parts[0]))
			endIP := net.ParseIP(strings.TrimSpace(parts[1]))
			if startIP != nil && endIP != nil {
				isV4 := startIP.To4() != nil
				suffix := "/32"
				if !isV4 {
					suffix = "/128"
				}
				return &ParsedEntry{
					IPv4:   isV4,
					IsCIDR: true,
					Value:  startIP.String() + suffix,
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

// ParseFeedLineMulti parses a line and returns multiple entries for IP ranges.
// For single IPs and CIDRs, returns a single-element slice.
// For IP ranges "x.x.x.x-y.y.y.y", expands to individual /32 or /128 entries.
// BUG-L18 FIX: This is the proper handler for IP range feed entries.
func ParseFeedLineMulti(line string) ([]*ParsedEntry, error) {
	line = strings.TrimSpace(line)
	if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
		return nil, nil
	}

	// Handle inline comments
	if idx := strings.Index(line, "#"); idx >= 0 {
		line = strings.TrimSpace(line[:idx])
	}
	if idx := strings.Index(line, ";"); idx >= 0 {
		line = strings.TrimSpace(line[:idx])
	}

	fields := strings.Fields(line)
	if len(fields) == 0 {
		return nil, nil
	}
	ipStr := fields[0]

	// Check for IP range
	if strings.Contains(ipStr, "-") && !strings.Contains(ipStr, "/") {
		parts := strings.SplitN(ipStr, "-", 2)
		if len(parts) == 2 {
			startIP := net.ParseIP(strings.TrimSpace(parts[0]))
			endIP := net.ParseIP(strings.TrimSpace(parts[1]))
			if startIP == nil || endIP == nil {
				return nil, fmt.Errorf("invalid IP range: %s", ipStr)
			}

			isV4 := startIP.To4() != nil
			var entries []*ParsedEntry

			// Expand range to individual IPs (cap at 65536 to prevent OOM)
			const maxExpand = 65536
			current := make(net.IP, len(startIP))
			copy(current, startIP)
			for i := 0; i < maxExpand; i++ {
				if bytesCompare(current, endIP) > 0 {
					break
				}
				suffix := "/32"
				if !isV4 {
					suffix = "/128"
				}
				entries = append(entries, &ParsedEntry{
					IPv4:   isV4,
					IsCIDR: true,
					Value:  current.String() + suffix,
				})
				current = incrementIP(current)
			}
			if len(entries) == 0 {
				return nil, fmt.Errorf("empty IP range: %s", ipStr)
			}
			if bytesCompare(current, endIP) <= 0 {
				return nil, fmt.Errorf("IP range too large (>%d): %s", maxExpand, ipStr)
			}
			return entries, nil
		}
	}

	// Non-range: delegate to ParseFeedLine
	entry, err := ParseFeedLine(line)
	if entry == nil {
		return nil, err
	}
	return []*ParsedEntry{entry}, err
}

// incrementIP returns the next IP address
func incrementIP(ip net.IP) net.IP {
	next := make(net.IP, len(ip))
	copy(next, ip)
	for i := len(next) - 1; i >= 0; i-- {
		next[i]++
		if next[i] != 0 {
			break
		}
	}
	return next
}

// bytesCompare compares two IPs as byte slices
func bytesCompare(a, b net.IP) int {
	// Normalize to same length
	a16 := a.To16()
	b16 := b.To16()
	for i := range a16 {
		if a16[i] < b16[i] {
			return -1
		}
		if a16[i] > b16[i] {
			return 1
		}
	}
	return 0
}

// ParseFeedLineSilent parses a line and returns nil for both skip and error cases
// Use this when you want to silently ignore invalid entries (like the original loader)
func ParseFeedLineSilent(line string) *ParsedEntry {
	entry, _ := ParseFeedLine(line)
	return entry
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
