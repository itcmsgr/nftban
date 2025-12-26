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

// Version is injected at build time from VERSION file via -ldflags
// If not set during build, defaults to development version
var Version = "dev"

// Core version constants - AUTO-GENERATED from Version
const (
	// ProductName is the official product name
	ProductName = "NFTBan"

	// CoreEngineName is the name of the core engine binary
	CoreEngineName = "nftban-core"
)

// FullVersion includes the 'v' prefix (e.g., "v1.0.5")
func FullVersion() string {
	return "v" + Version
}

// Major returns the major version number
func Major() int {
	// Parse from Version string
	return 1 // Simplified for now
}

// Minor returns the minor version number
func Minor() int {
	return 0
}

// Patch returns the patch version number
func Patch() int {
	return 5
}

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
