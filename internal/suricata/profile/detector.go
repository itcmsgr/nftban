// =============================================================================
// NFTBan - Suricata Profile Detector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="detector"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Auto-detects optimal Suricata performance profile based on system resources"
// meta:input="CPU cores, memory"
// meta:output="Profile type recommendation"
// meta:depends="os,runtime"
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
	"fmt"
	"os"
	"regexp"
	"runtime"
	"strconv"
	"strings"
)

// ProfileType represents the Suricata performance profile
type ProfileType int

const (
	// ProfileMinimal is for 2 cores / 2 GB RAM
	ProfileMinimal ProfileType = iota
	// ProfileStandard is for 4 cores / 4-8 GB RAM (DEFAULT)
	ProfileStandard
	// ProfileMaximum is for 8+ cores / 8-16 GB RAM
	ProfileMaximum
)

// String returns the profile name
func (p ProfileType) String() string {
	switch p {
	case ProfileMinimal:
		return "minimal"
	case ProfileStandard:
		return "standard"
	case ProfileMaximum:
		return "maximum"
	default:
		return "unknown"
	}
}

// ProfileFromString parses a profile name
func ProfileFromString(s string) (ProfileType, error) {
	switch strings.ToLower(s) {
	case "minimal", "min", "low", "a":
		return ProfileMinimal, nil
	case "standard", "std", "medium", "b", "default":
		return ProfileStandard, nil
	case "maximum", "max", "high", "c":
		return ProfileMaximum, nil
	default:
		return ProfileStandard, fmt.Errorf("unknown profile: %s", s)
	}
}

// DetectionResult contains system resource detection results
type DetectionResult struct {
	Profile    ProfileType `json:"profile"`
	ProfileStr string      `json:"profile_name"`
	CPUCount   int         `json:"cpu_count"`
	RAMGB      float64     `json:"ram_gb"`
	Reason     string      `json:"reason"`
}

// DetectOptimalProfile auto-detects the best Suricata profile based on system resources
func DetectOptimalProfile() (*DetectionResult, error) {
	cpus := runtime.NumCPU()
	ramGB, err := getTotalMemoryGB()
	if err != nil {
		return nil, fmt.Errorf("failed to detect RAM: %w", err)
	}

	var profile ProfileType
	var reason string

	// Decision tree based on design document
	if cpus >= 8 && ramGB >= 8 {
		profile = ProfileMaximum
		reason = fmt.Sprintf("High-end server: %d cores, %.1f GB RAM - Deep inspection enabled", cpus, ramGB)
	} else if cpus >= 4 && ramGB >= 4 {
		profile = ProfileStandard
		reason = fmt.Sprintf("Standard server: %d cores, %.1f GB RAM - Balanced performance (default)", cpus, ramGB)
	} else {
		profile = ProfileMinimal
		reason = fmt.Sprintf("Resource-constrained: %d cores, %.1f GB RAM - Stability prioritized", cpus, ramGB)
	}

	return &DetectionResult{
		Profile:    profile,
		ProfileStr: profile.String(),
		CPUCount:   cpus,
		RAMGB:      ramGB,
		Reason:     reason,
	}, nil
}

// getTotalMemoryGB reads total system RAM from /proc/meminfo
func getTotalMemoryGB() (float64, error) {
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return 0, fmt.Errorf("failed to read /proc/meminfo: %w", err)
	}

	// Parse MemTotal line
	re := regexp.MustCompile(`MemTotal:\s+(\d+)\s+kB`)
	matches := re.FindSubmatch(data)
	if len(matches) < 2 {
		return 0, fmt.Errorf("failed to parse MemTotal from /proc/meminfo")
	}

	// Convert KB to GB
	kb, err := strconv.ParseInt(string(matches[1]), 10, 64)
	if err != nil {
		return 0, fmt.Errorf("failed to parse memory value: %w", err)
	}

	gb := float64(kb) / 1024 / 1024
	return gb, nil
}

// ProfileSpec contains profile characteristics
type ProfileSpec struct {
	Profile       ProfileType
	Name          string
	MinCPU        int
	MinRAMGB      float64
	RingSize      int
	FlowTimeout   int // seconds for established flows
	HTTPBodyLimit string
	DetectProfile string
	UseCase       string
}

// GetProfileSpec returns the specification for a given profile
func GetProfileSpec(p ProfileType) ProfileSpec {
	switch p {
	case ProfileMinimal:
		return ProfileSpec{
			Profile:       ProfileMinimal,
			Name:          "minimal",
			MinCPU:        2,
			MinRAMGB:      2,
			RingSize:      50000,
			FlowTimeout:   60,
			HTTPBodyLimit: "0 (disabled)",
			DetectProfile: "low",
			UseCase:       "Tiny VPS, stability first",
		}
	case ProfileStandard:
		return ProfileSpec{
			Profile:       ProfileStandard,
			Name:          "standard",
			MinCPU:        4,
			MinRAMGB:      4,
			RingSize:      100000,
			FlowTimeout:   120,
			HTTPBodyLimit: "10-30KB",
			DetectProfile: "medium",
			UseCase:       "Most servers, balanced (recommended)",
		}
	case ProfileMaximum:
		return ProfileSpec{
			Profile:       ProfileMaximum,
			Name:          "maximum",
			MinCPU:        8,
			MinRAMGB:      8,
			RingSize:      300000,
			FlowTimeout:   300,
			HTTPBodyLimit: "30KB",
			DetectProfile: "high",
			UseCase:       "High traffic, deep inspection",
		}
	default:
		return GetProfileSpec(ProfileStandard)
	}
}

// GetAllProfiles returns specifications for all profiles
func GetAllProfiles() []ProfileSpec {
	return []ProfileSpec{
		GetProfileSpec(ProfileMinimal),
		GetProfileSpec(ProfileStandard),
		GetProfileSpec(ProfileMaximum),
	}
}
