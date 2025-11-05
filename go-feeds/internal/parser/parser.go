package parser

import (
	"bufio"
	"bytes"
	"net/netip"
	"strings"
)

// ParseIPs extracts and validates IPs/CIDRs from feed content
// Skips comments, empty lines, and invalid entries
// Returns slice of netip.Prefix (both single IPs and CIDRs)
func ParseIPs(content []byte) ([]netip.Prefix, error) {
	var prefixes []netip.Prefix
	scanner := bufio.NewScanner(bytes.NewReader(content))

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())

		// Skip comments and empty lines
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Some feeds have trailing comments: "192.0.2.1 # comment"
		if idx := strings.Index(line, "#"); idx != -1 {
			line = strings.TrimSpace(line[:idx])
		}

		// Try parsing as CIDR first (e.g., 192.0.2.0/24)
		prefix, err := netip.ParsePrefix(line)
		if err == nil {
			prefixes = append(prefixes, prefix)
			continue
		}

		// Try parsing as single IP (convert to /32 or /128)
		addr, err := netip.ParseAddr(line)
		if err == nil {
			bits := 32
			if addr.Is6() {
				bits = 128
			}
			prefix = netip.PrefixFrom(addr, bits)
			prefixes = append(prefixes, prefix)
		}

		// If both fail, skip silently (invalid entry)
	}

	return prefixes, scanner.Err()
}

// Deduplicate removes duplicate prefixes
// Uses map for O(n) performance
func Deduplicate(prefixes []netip.Prefix) []netip.Prefix {
	seen := make(map[netip.Prefix]struct{}, len(prefixes))
	var unique []netip.Prefix

	for _, p := range prefixes {
		if _, exists := seen[p]; !exists {
			seen[p] = struct{}{}
			unique = append(unique, p)
		}
	}
	return unique
}

// SplitIPv4v6 separates IPv4 and IPv6 prefixes
// Returns two slices: (ipv4, ipv6)
func SplitIPv4v6(prefixes []netip.Prefix) (v4, v6 []netip.Prefix) {
	for _, p := range prefixes {
		if p.Addr().Is4() {
			v4 = append(v4, p)
		} else if p.Addr().Is6() {
			v6 = append(v6, p)
		}
	}
	return
}
