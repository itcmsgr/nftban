// =============================================================================
// NFTBan - Network IP Family Detection
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="detect"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Detects IPv4 and IPv6 availability on system interfaces"
// meta:input="Network interfaces"
// meta:output="IP family support flags"
// meta:depends="net"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package network

import (
	"fmt"
	"net"
)

// IPFamilySupport represents which IP families are available on the system
type IPFamilySupport struct {
	HasIPv4 bool // System has at least one IPv4 address
	HasIPv6 bool // System has at least one IPv6 address
}

// DetectIPFamilySupport checks which IP families the system actually has
// This is critical for nftables: we should only create tables/chains for
// IP families that exist on the system
func DetectIPFamilySupport() (*IPFamilySupport, error) {
	support := &IPFamilySupport{
		HasIPv4: false,
		HasIPv6: false,
	}

	// Get all network interfaces
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil, fmt.Errorf("failed to get network interfaces: %w", err)
	}

	for _, iface := range ifaces {
		// Skip loopback - we want real network connectivity
		if iface.Flags&net.FlagLoopback != 0 {
			continue
		}

		// Skip down interfaces
		if iface.Flags&net.FlagUp == 0 {
			continue
		}

		// Get addresses for this interface
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}

		for _, addr := range addrs {
			var ip net.IP
			switch v := addr.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}

			if ip == nil || ip.IsLoopback() {
				continue
			}

			// Check if IPv4
			if ip.To4() != nil {
				support.HasIPv4 = true
			} else if ip.To16() != nil {
				// IPv6 (but not IPv4-mapped)
				support.HasIPv6 = true
			}

			// Early exit if we found both
			if support.HasIPv4 && support.HasIPv6 {
				return support, nil
			}
		}
	}

	return support, nil
}

// String returns a human-readable description
func (s *IPFamilySupport) String() string {
	if s.HasIPv4 && s.HasIPv6 {
		return "IPv4 + IPv6 (dual-stack)"
	} else if s.HasIPv4 {
		return "IPv4 only"
	} else if s.HasIPv6 {
		return "IPv6 only"
	}
	return "No IP connectivity detected"
}

// ShouldCreateIPv4Rules returns true if IPv4 nftables rules should be created
func (s *IPFamilySupport) ShouldCreateIPv4Rules() bool {
	return s.HasIPv4
}

// ShouldCreateIPv6Rules returns true if IPv6 nftables rules should be created
func (s *IPFamilySupport) ShouldCreateIPv6Rules() bool {
	return s.HasIPv6
}

// GetActiveFamilies returns a list of active IP families for logging
func (s *IPFamilySupport) GetActiveFamilies() []string {
	var families []string
	if s.HasIPv4 {
		families = append(families, "IPv4")
	}
	if s.HasIPv6 {
		families = append(families, "IPv6")
	}
	return families
}
