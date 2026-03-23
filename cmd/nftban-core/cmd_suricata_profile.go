// =============================================================================
// NFTBan - Suricata Integration - Profile detection, application, and validation
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_suricata"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Profile detection, application, and validation"
// meta:inventory.files="/var/log/nftban/suricata/eve-alerts.json"
// meta:inventory.binaries="suricata"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/suricata/*.conf"
// meta:inventory.systemd_units="suricata.service"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"fmt"
	"strings"

	"github.com/itcmsgr/nftban/internal/suricata/profile"
	"github.com/itcmsgr/nftban/pkg/version"
)

// =============================================================================
// PROFILE MANAGEMENT COMMANDS (NEW)
// =============================================================================

// cmdSuricataProfileDetect auto-detects the optimal profile based on system resources
func cmdSuricataProfileDetect() error {
	fmt.Println(version.BannerWithEmoji("🔍", "Suricata Profile Auto-Detection"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	result, err := profile.DetectOptimalProfile()
	if err != nil {
		return fmt.Errorf("failed to detect profile: %w", err)
	}

	fmt.Println("System Resources:")
	fmt.Printf("  CPU Cores:    %d\n", result.CPUCount)
	fmt.Printf("  Total RAM:    %.1f GB\n", result.RAMGB)
	fmt.Println()

	fmt.Println("Recommended Profile:", result.ProfileStr)
	fmt.Println()

	spec := profile.GetProfileSpec(result.Profile)
	fmt.Println("Profile Characteristics:")
	fmt.Printf("  Ring Size:        %d frames\n", spec.RingSize)
	fmt.Printf("  Flow Timeout:     %d seconds\n", spec.FlowTimeout)
	fmt.Printf("  HTTP Body Limit:  %s\n", spec.HTTPBodyLimit)
	fmt.Printf("  Detect Profile:   %s\n", spec.DetectProfile)
	fmt.Printf("  Use Case:         %s\n", spec.UseCase)
	fmt.Println()

	fmt.Println("Reason:", result.Reason)
	fmt.Println()

	fmt.Println("To apply this profile:")
	fmt.Printf("  nftban-core suricata profile-apply %s\n", result.ProfileStr)
	fmt.Println()

	return nil
}

// cmdSuricataProfileApply applies the specified profile (creates symlink)
func cmdSuricataProfileApply(profileName string) error {
	prof, err := profile.ProfileFromString(profileName)
	if err != nil {
		return fmt.Errorf("invalid profile name: %w", err)
	}

	fmt.Println(version.BannerWithEmoji("⚙️", "Applying Suricata Profile"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Check if profile templates exist
	if err := profile.EnsureProfilesExist(); err != nil {
		return fmt.Errorf("profile templates not found: %w\nRun: nftban suricata install", err)
	}

	// Apply profile (create symlink)
	if err := profile.ApplyProfile(prof); err != nil {
		return fmt.Errorf("failed to apply profile: %w", err)
	}

	spec := profile.GetProfileSpec(prof)

	fmt.Printf("✅ Profile Applied: %s\n", prof.String())
	fmt.Println()
	fmt.Println("Configuration:")

	yamlPath, _ := profile.GetProfileYAMLPath(prof)
	configPath, _ := profile.GetSuricataConfigPath()
	fmt.Printf("  YAML Template:    %s\n", yamlPath)
	fmt.Printf("  Active Config:    %s (symlink)\n", configPath)
	fmt.Println()

	fmt.Println("Profile Details:")
	fmt.Printf("  Minimum CPU:      %d cores\n", spec.MinCPU)
	fmt.Printf("  Minimum RAM:      %.1f GB\n", spec.MinRAMGB)
	fmt.Printf("  Ring Size:        %d frames\n", spec.RingSize)
	fmt.Printf("  Flow Timeout:     %d seconds\n", spec.FlowTimeout)
	fmt.Printf("  HTTP Body Limit:  %s\n", spec.HTTPBodyLimit)
	fmt.Printf("  Detect Profile:   %s\n", spec.DetectProfile)
	fmt.Println()

	fmt.Println("⚠️  Restart required:")
	fmt.Println("  systemctl restart suricata")
	fmt.Println()

	return nil
}

// cmdSuricataProfileShow displays the current active profile
func cmdSuricataProfileShow() error {
	fmt.Println(version.BannerWithEmoji("📋", "Current Suricata Profile"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	currentProfile, err := profile.GetCurrentProfile()
	if err != nil {
		fmt.Printf("⚠️  No active profile: %v\n", err)
		fmt.Println()
		fmt.Println("To set up a profile:")
		fmt.Println("  1. Auto-detect:  nftban-core suricata profile-detect")
		fmt.Println("  2. Apply:        nftban-core suricata profile-apply <PROFILE>")
		fmt.Println()
		return nil
	}

	spec := profile.GetProfileSpec(currentProfile)

	fmt.Printf("Active Profile: %s\n", currentProfile.String())
	fmt.Println()

	fmt.Println("Configuration:")
	yamlPath, _ := profile.GetProfileYAMLPath(currentProfile)
	configPath, _ := profile.GetSuricataConfigPath()
	fmt.Printf("  YAML Template:    %s\n", yamlPath)
	fmt.Printf("  Active Config:    %s (symlink)\n", configPath)
	fmt.Println()

	fmt.Println("Profile Specifications:")
	fmt.Printf("  Target Hardware:  %d+ cores, %.1f+ GB RAM\n", spec.MinCPU, spec.MinRAMGB)
	fmt.Printf("  Ring Size:        %d frames\n", spec.RingSize)
	fmt.Printf("  Flow Timeout:     %d seconds (established)\n", spec.FlowTimeout)
	fmt.Printf("  HTTP Body Limit:  %s\n", spec.HTTPBodyLimit)
	fmt.Printf("  Detect Profile:   %s\n", spec.DetectProfile)
	fmt.Printf("  Use Case:         %s\n", spec.UseCase)
	fmt.Println()

	// Show system resources
	result, err := profile.DetectOptimalProfile()
	if err == nil {
		fmt.Println("System Resources:")
		fmt.Printf("  CPU Cores:        %d\n", result.CPUCount)
		fmt.Printf("  Total RAM:        %.1f GB\n", result.RAMGB)
		fmt.Println()

		// Check if current profile matches recommendation
		if result.Profile != currentProfile {
			fmt.Printf("💡 Recommendation: Consider switching to '%s' profile\n", result.ProfileStr)
			fmt.Printf("   Reason: %s\n", result.Reason)
			fmt.Println()
			fmt.Printf("   To apply: nftban-core suricata profile-apply %s\n", result.ProfileStr)
			fmt.Println()
		} else {
			fmt.Println("✅ Current profile matches system resources")
			fmt.Println()
		}
	}

	return nil
}

// cmdSuricataProfileValidate validates the current profile configuration
func cmdSuricataProfileValidate() error {
	if err := profile.ValidateProfile(); err != nil {
		fmt.Printf("❌ Profile validation failed: %v\n", err)
		return err
	}

	fmt.Println("✅ Profile configuration is valid")
	return nil
}
