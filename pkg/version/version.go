// Package version provides centralized version information for NFTBan.
// =============================================================================
// NFTBan v1.0 - Centralized Version Management
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// IMPORTANT: This is the SINGLE SOURCE OF TRUTH for version strings.
// All binaries and modules should import this package instead of hardcoding.
// =============================================================================
package version

// Core version constants - UPDATE THESE FOR RELEASES
const (
	// Major version for incompatible API changes
	Major = 1

	// Minor version for backwards-compatible functionality
	Minor = 0

	// Patch version for backwards-compatible bug fixes
	Patch = 0

	// Version is the full version string (e.g., "1.0.0")
	Version = "1.0.0"

	// FullVersion includes the 'v' prefix (e.g., "v1.0.0")
	FullVersion = "v" + Version

	// ProductName is the official product name
	ProductName = "NFTBan"

	// CoreEngineName is the name of the core engine binary
	CoreEngineName = "nftban-core"
)

// Architecture version constants
const (
	// SchemaVersion is the nftables schema version
	// This tracks changes to table/set/chain structure
	SchemaVersion = "0.7.3"

	// ConfigVersion is the configuration file format version
	ConfigVersion = "2"
)

// Banner returns a formatted banner string for CLI output
func Banner(component string) string {
	if component == "" {
		return ProductName + " " + FullVersion
	}
	return ProductName + " " + FullVersion + " - " + component
}

// BannerWithEmoji returns a banner with emoji prefix
func BannerWithEmoji(emoji, component string) string {
	return emoji + " " + Banner(component)
}
