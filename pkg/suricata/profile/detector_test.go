// =============================================================================
// NFTBan v1.0 - Suricata Profile Detector Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="detector_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Unit tests for profile types, parsing, and specifications"
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

package profile

import (
	"testing"
)

// =============================================================================
// ProfileType.String() Tests
// =============================================================================

func TestProfileType_String(t *testing.T) {
	tests := []struct {
		name    string
		profile ProfileType
		want    string
	}{
		{"minimal", ProfileMinimal, "minimal"},
		{"standard", ProfileStandard, "standard"},
		{"maximum", ProfileMaximum, "maximum"},
		{"unknown", ProfileType(99), "unknown"},
		{"negative", ProfileType(-1), "unknown"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := tt.profile.String()
			if got != tt.want {
				t.Errorf("ProfileType(%d).String() = %q, want %q", tt.profile, got, tt.want)
			}
		})
	}
}

// =============================================================================
// ProfileFromString Tests
// =============================================================================

func TestProfileFromString(t *testing.T) {
	tests := []struct {
		name      string
		input     string
		want      ProfileType
		wantErr   bool
	}{
		// Minimal aliases
		{"minimal", "minimal", ProfileMinimal, false},
		{"min", "min", ProfileMinimal, false},
		{"low", "low", ProfileMinimal, false},
		{"a", "a", ProfileMinimal, false},

		// Standard aliases
		{"standard", "standard", ProfileStandard, false},
		{"std", "std", ProfileStandard, false},
		{"medium", "medium", ProfileStandard, false},
		{"b", "b", ProfileStandard, false},
		{"default", "default", ProfileStandard, false},

		// Maximum aliases
		{"maximum", "maximum", ProfileMaximum, false},
		{"max", "max", ProfileMaximum, false},
		{"high", "high", ProfileMaximum, false},
		{"c", "c", ProfileMaximum, false},

		// Case insensitive
		{"case_minimal", "MINIMAL", ProfileMinimal, false},
		{"case_standard", "Standard", ProfileStandard, false},
		{"case_maximum", "MAXIMUM", ProfileMaximum, false},

		// Unknown (returns standard with error)
		{"unknown", "invalid", ProfileStandard, true},
		{"empty", "", ProfileStandard, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ProfileFromString(tt.input)
			if (err != nil) != tt.wantErr {
				t.Errorf("ProfileFromString(%q) error = %v, wantErr %v", tt.input, err, tt.wantErr)
				return
			}
			if got != tt.want {
				t.Errorf("ProfileFromString(%q) = %v, want %v", tt.input, got, tt.want)
			}
		})
	}
}

// =============================================================================
// GetProfileSpec Tests
// =============================================================================

func TestGetProfileSpec(t *testing.T) {
	tests := []struct {
		name       string
		profile    ProfileType
		wantName   string
		wantMinCPU int
	}{
		{"minimal", ProfileMinimal, "minimal", 2},
		{"standard", ProfileStandard, "standard", 4},
		{"maximum", ProfileMaximum, "maximum", 8},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			spec := GetProfileSpec(tt.profile)

			if spec.Name != tt.wantName {
				t.Errorf("GetProfileSpec(%v).Name = %q, want %q", tt.profile, spec.Name, tt.wantName)
			}
			if spec.MinCPU != tt.wantMinCPU {
				t.Errorf("GetProfileSpec(%v).MinCPU = %d, want %d", tt.profile, spec.MinCPU, tt.wantMinCPU)
			}
			if spec.Profile != tt.profile {
				t.Errorf("GetProfileSpec(%v).Profile = %v, want %v", tt.profile, spec.Profile, tt.profile)
			}
		})
	}
}

func TestGetProfileSpec_UnknownDefault(t *testing.T) {
	// Unknown profile type should default to standard
	spec := GetProfileSpec(ProfileType(99))
	if spec.Name != "standard" {
		t.Errorf("expected standard for unknown profile, got %q", spec.Name)
	}
}

func TestGetProfileSpec_MinimalValues(t *testing.T) {
	spec := GetProfileSpec(ProfileMinimal)

	if spec.MinRAMGB != 2 {
		t.Errorf("minimal MinRAMGB = %.1f, want 2", spec.MinRAMGB)
	}
	if spec.RingSize != 50000 {
		t.Errorf("minimal RingSize = %d, want 50000", spec.RingSize)
	}
	if spec.FlowTimeout != 60 {
		t.Errorf("minimal FlowTimeout = %d, want 60", spec.FlowTimeout)
	}
	if spec.DetectProfile != "low" {
		t.Errorf("minimal DetectProfile = %q, want %q", spec.DetectProfile, "low")
	}
}

func TestGetProfileSpec_StandardValues(t *testing.T) {
	spec := GetProfileSpec(ProfileStandard)

	if spec.MinRAMGB != 4 {
		t.Errorf("standard MinRAMGB = %.1f, want 4", spec.MinRAMGB)
	}
	if spec.RingSize != 100000 {
		t.Errorf("standard RingSize = %d, want 100000", spec.RingSize)
	}
	if spec.FlowTimeout != 120 {
		t.Errorf("standard FlowTimeout = %d, want 120", spec.FlowTimeout)
	}
	if spec.DetectProfile != "medium" {
		t.Errorf("standard DetectProfile = %q, want %q", spec.DetectProfile, "medium")
	}
}

func TestGetProfileSpec_MaximumValues(t *testing.T) {
	spec := GetProfileSpec(ProfileMaximum)

	if spec.MinRAMGB != 8 {
		t.Errorf("maximum MinRAMGB = %.1f, want 8", spec.MinRAMGB)
	}
	if spec.RingSize != 300000 {
		t.Errorf("maximum RingSize = %d, want 300000", spec.RingSize)
	}
	if spec.FlowTimeout != 300 {
		t.Errorf("maximum FlowTimeout = %d, want 300", spec.FlowTimeout)
	}
	if spec.DetectProfile != "high" {
		t.Errorf("maximum DetectProfile = %q, want %q", spec.DetectProfile, "high")
	}
}

// =============================================================================
// GetAllProfiles Tests
// =============================================================================

func TestGetAllProfiles(t *testing.T) {
	profiles := GetAllProfiles()

	if len(profiles) != 3 {
		t.Fatalf("expected 3 profiles, got %d", len(profiles))
	}

	// Should be in order: minimal, standard, maximum
	expected := []string{"minimal", "standard", "maximum"}
	for i, p := range profiles {
		if p.Name != expected[i] {
			t.Errorf("profiles[%d].Name = %q, want %q", i, p.Name, expected[i])
		}
	}
}

func TestGetAllProfiles_IncreasingResources(t *testing.T) {
	profiles := GetAllProfiles()

	// Each profile should require more resources than the previous
	for i := 1; i < len(profiles); i++ {
		if profiles[i].MinCPU <= profiles[i-1].MinCPU {
			t.Errorf("expected increasing MinCPU: profile[%d].MinCPU=%d <= profile[%d].MinCPU=%d",
				i, profiles[i].MinCPU, i-1, profiles[i-1].MinCPU)
		}
		if profiles[i].MinRAMGB <= profiles[i-1].MinRAMGB {
			t.Errorf("expected increasing MinRAMGB: profile[%d].MinRAMGB=%.1f <= profile[%d].MinRAMGB=%.1f",
				i, profiles[i].MinRAMGB, i-1, profiles[i-1].MinRAMGB)
		}
		if profiles[i].RingSize <= profiles[i-1].RingSize {
			t.Errorf("expected increasing RingSize: profile[%d].RingSize=%d <= profile[%d].RingSize=%d",
				i, profiles[i].RingSize, i-1, profiles[i-1].RingSize)
		}
	}
}

// =============================================================================
// ProfileType Constants Tests
// =============================================================================

func TestProfileTypeConstants(t *testing.T) {
	// Verify the iota ordering
	if ProfileMinimal != 0 {
		t.Errorf("ProfileMinimal = %d, want 0", ProfileMinimal)
	}
	if ProfileStandard != 1 {
		t.Errorf("ProfileStandard = %d, want 1", ProfileStandard)
	}
	if ProfileMaximum != 2 {
		t.Errorf("ProfileMaximum = %d, want 2", ProfileMaximum)
	}
}
