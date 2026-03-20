// =============================================================================
// NFTBan v1.0 - Network IP Family Detection Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="detect_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Unit tests for IPFamilySupport methods"
// meta:input="Test cases"
// meta:output="Test results"
// meta:depends="testing"
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
	"testing"
)

// =============================================================================
// IPFamilySupport.String() Tests
// =============================================================================

func TestIPFamilySupport_String(t *testing.T) {
	tests := []struct {
		name    string
		support IPFamilySupport
		want    string
	}{
		{
			name:    "dual_stack",
			support: IPFamilySupport{HasIPv4: true, HasIPv6: true},
			want:    "IPv4 + IPv6 (dual-stack)",
		},
		{
			name:    "ipv4_only",
			support: IPFamilySupport{HasIPv4: true, HasIPv6: false},
			want:    "IPv4 only",
		},
		{
			name:    "ipv6_only",
			support: IPFamilySupport{HasIPv4: false, HasIPv6: true},
			want:    "IPv6 only",
		},
		{
			name:    "no_connectivity",
			support: IPFamilySupport{HasIPv4: false, HasIPv6: false},
			want:    "No IP connectivity detected",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.support.String()
			if got != tt.want {
				t.Errorf("String() = %q, want %q", got, tt.want)
			}
		})
	}
}

// =============================================================================
// ShouldCreateIPv4Rules Tests
// =============================================================================

func TestShouldCreateIPv4Rules(t *testing.T) {
	tests := []struct {
		name    string
		support IPFamilySupport
		want    bool
	}{
		{"dual_stack", IPFamilySupport{HasIPv4: true, HasIPv6: true}, true},
		{"ipv4_only", IPFamilySupport{HasIPv4: true, HasIPv6: false}, true},
		{"ipv6_only", IPFamilySupport{HasIPv4: false, HasIPv6: true}, false},
		{"none", IPFamilySupport{HasIPv4: false, HasIPv6: false}, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.support.ShouldCreateIPv4Rules()
			if got != tt.want {
				t.Errorf("ShouldCreateIPv4Rules() = %v, want %v", got, tt.want)
			}
		})
	}
}

// =============================================================================
// ShouldCreateIPv6Rules Tests
// =============================================================================

func TestShouldCreateIPv6Rules(t *testing.T) {
	tests := []struct {
		name    string
		support IPFamilySupport
		want    bool
	}{
		{"dual_stack", IPFamilySupport{HasIPv4: true, HasIPv6: true}, true},
		{"ipv4_only", IPFamilySupport{HasIPv4: true, HasIPv6: false}, false},
		{"ipv6_only", IPFamilySupport{HasIPv4: false, HasIPv6: true}, true},
		{"none", IPFamilySupport{HasIPv4: false, HasIPv6: false}, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.support.ShouldCreateIPv6Rules()
			if got != tt.want {
				t.Errorf("ShouldCreateIPv6Rules() = %v, want %v", got, tt.want)
			}
		})
	}
}

// =============================================================================
// GetActiveFamilies Tests
// =============================================================================

func TestGetActiveFamilies(t *testing.T) {
	tests := []struct {
		name    string
		support IPFamilySupport
		want    []string
	}{
		{
			name:    "dual_stack",
			support: IPFamilySupport{HasIPv4: true, HasIPv6: true},
			want:    []string{"IPv4", "IPv6"},
		},
		{
			name:    "ipv4_only",
			support: IPFamilySupport{HasIPv4: true, HasIPv6: false},
			want:    []string{"IPv4"},
		},
		{
			name:    "ipv6_only",
			support: IPFamilySupport{HasIPv4: false, HasIPv6: true},
			want:    []string{"IPv6"},
		},
		{
			name:    "none",
			support: IPFamilySupport{HasIPv4: false, HasIPv6: false},
			want:    nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.support.GetActiveFamilies()

			if len(got) != len(tt.want) {
				t.Errorf("GetActiveFamilies() returned %d families, want %d", len(got), len(tt.want))
				return
			}

			for i, family := range got {
				if family != tt.want[i] {
					t.Errorf("GetActiveFamilies()[%d] = %q, want %q", i, family, tt.want[i])
				}
			}
		})
	}
}
