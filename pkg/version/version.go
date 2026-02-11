// =============================================================================
// NFTBan - Centralized Version Management
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="version"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Single source of truth for version strings injected via ldflags"
// meta:input="None"
// meta:output="Version constants and functions"
// meta:depends="None"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package version

import (
	"strconv"
	"strings"
)

// Version is injected at build time from VERSION file via -ldflags
// If not set during build, defaults to development version
var Version = "dev"

// parseVersion splits Version into [major, minor, patch] integers.
func parseVersion() []int {
	v := strings.TrimPrefix(Version, "v")
	parts := strings.SplitN(v, ".", 3)
	result := make([]int, 0, 3)
	for _, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil {
			break
		}
		result = append(result, n)
	}
	return result
}

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
	parts := parseVersion()
	if len(parts) >= 1 {
		return parts[0]
	}
	return 0
}

// Minor returns the minor version number
func Minor() int {
	parts := parseVersion()
	if len(parts) >= 2 {
		return parts[1]
	}
	return 0
}

// Patch returns the patch version number
func Patch() int {
	parts := parseVersion()
	if len(parts) >= 3 {
		return parts[2]
	}
	return 0
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
		return ProductName + " " + FullVersion()
	}
	return ProductName + " " + FullVersion() + " - " + component
}

// BannerWithEmoji returns a banner with emoji prefix
func BannerWithEmoji(emoji, component string) string {
	return emoji + " " + Banner(component)
}
