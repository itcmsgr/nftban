// =============================================================================
// NFTBan - Suricata Profile Applier
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="applier"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Applies Suricata performance profiles to suricata.yaml"
// meta:input="Profile type, distro config"
// meta:output="Modified suricata.yaml"
// meta:depends="github.com/itcmsgr/nftban/pkg/config,github.com/itcmsgr/nftban/pkg/nftbanconf"
// meta:inventory.files="/etc/suricata/suricata.yaml"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package profile

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/itcmsgr/nftban/pkg/config"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
)

// getPaths loads distro-specific paths from central config
func getPaths() (profilesDir, suricataYAML, profileConf string, err error) {
	// Load distro config for paths
	distro, err := config.LoadDistroConfig()
	if err != nil {
		return "", "", "", fmt.Errorf("failed to load distro config: %w", err)
	}

	// Get suricata_yaml path from distro config
	suricataYAML, ok := distro.Paths["suricata_yaml"]
	if !ok {
		// Fallback to standard path if not defined
		suricataYAML = "/etc/suricata/suricata.yaml"
	}

	// Profile paths are NFTBan-specific, use central config dir
	cfg := nftbanconf.MustLoad()
	profilesDir = filepath.Join(cfg.ConfigDir, "suricata/profiles")
	profileConf = filepath.Join(cfg.ConfigDir, "suricata/config/profile.conf")

	return profilesDir, suricataYAML, profileConf, nil
}

// ApplyProfile creates/updates the symlink to the selected profile YAML
func ApplyProfile(profile ProfileType) error {
	profilesDir, suricataYAML, profileConf, err := getPaths()
	if err != nil {
		return err
	}

	profileName := profile.String()
	profilePath := filepath.Join(profilesDir, profileName+".yaml")

	// Check if profile template exists
	if _, err := os.Stat(profilePath); err != nil {
		return fmt.Errorf("profile template not found: %s (run nftban install first)", profilePath)
	}

	// Create symlink atomically
	tmpLink := suricataYAML + ".tmp"

	// Remove old temp link if exists
	_ = os.Remove(tmpLink)

	// Create temp symlink
	if err := os.Symlink(profilePath, tmpLink); err != nil {
		return fmt.Errorf("failed to create symlink: %w", err)
	}

	// Atomic rename
	if err := os.Rename(tmpLink, suricataYAML); err != nil {
		_ = os.Remove(tmpLink)
		return fmt.Errorf("failed to replace symlink: %w", err)
	}

	// Save profile name to config file
	if err := saveProfileConfig(profileName, profileConf); err != nil {
		return fmt.Errorf("failed to save profile config: %w", err)
	}

	return nil
}

// GetCurrentProfile reads the current active profile
func GetCurrentProfile() (ProfileType, error) {
	_, suricataYAML, profileConf, err := getPaths()
	if err != nil {
		return ProfileStandard, err
	}

	// Try reading from config file first
	if data, err := os.ReadFile(profileConf); err == nil {
		profileName := string(data)
		if profile, err := ProfileFromString(profileName); err == nil {
			return profile, nil
		}
	}

	// Fallback: read symlink target
	target, err := os.Readlink(suricataYAML)
	if err != nil {
		return ProfileStandard, fmt.Errorf("no active profile (symlink not found)")
	}

	// Extract profile name from path
	base := filepath.Base(target)
	profileName := base[:len(base)-len(".yaml")]

	profile, err := ProfileFromString(profileName)
	if err != nil {
		return ProfileStandard, err
	}

	return profile, nil
}

// saveProfileConfig writes the profile name to config file
func saveProfileConfig(profileName string, profileConf string) error {
	// Ensure config directory exists
	configDir := filepath.Dir(profileConf)
	if err := os.MkdirAll(configDir, 0755); err != nil {
		return err
	}

	// Write profile name
	return os.WriteFile(profileConf, []byte(profileName), 0644)
}

// ValidateProfile checks if the current profile symlink is valid
func ValidateProfile() error {
	profilesDir, suricataYAML, _, err := getPaths()
	if err != nil {
		return err
	}

	// Check if symlink exists
	target, err := os.Readlink(suricataYAML)
	if err != nil {
		return fmt.Errorf("suricata.yaml symlink not found or broken")
	}

	// Check if target exists
	if _, err := os.Stat(target); err != nil {
		return fmt.Errorf("profile template not found: %s", target)
	}

	// Check if target is in correct directory (use strings.HasPrefix with cleaned paths)
	cleanTarget := filepath.Clean(target)
	cleanProfilesDir := filepath.Clean(profilesDir) + string(filepath.Separator)
	if !strings.HasPrefix(cleanTarget, cleanProfilesDir) && cleanTarget != filepath.Clean(profilesDir) {
		return fmt.Errorf("profile symlink points outside profiles directory: %s", target)
	}

	return nil
}

// GetProfileYAMLPath returns the path to the YAML file for a profile
func GetProfileYAMLPath(profile ProfileType) (string, error) {
	profilesDir, _, _, err := getPaths()
	if err != nil {
		return "", err
	}
	return filepath.Join(profilesDir, profile.String()+".yaml"), nil
}

// GetSuricataConfigPath returns the path to the active Suricata config (symlink)
func GetSuricataConfigPath() (string, error) {
	_, suricataYAML, _, err := getPaths()
	if err != nil {
		return "", err
	}
	return suricataYAML, nil
}

// EnsureProfilesExist checks if all profile templates are installed
func EnsureProfilesExist() error {
	for _, profile := range []ProfileType{ProfileMinimal, ProfileStandard, ProfileMaximum} {
		path, err := GetProfileYAMLPath(profile)
		if err != nil {
			return err
		}
		if _, err := os.Stat(path); err != nil {
			return fmt.Errorf("missing profile template: %s", path)
		}
	}
	return nil
}
