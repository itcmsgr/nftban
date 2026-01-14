// =============================================================================
// NFTBan - GOTH GUI Types
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="types"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-15"
// meta:description="Data types for GOTH GUI templates"
// meta:input="None"
// meta:output="None"
// meta:depends=""
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package ui

// SummaryData holds dashboard summary statistics
type SummaryData struct {
	ActiveBans     int
	EventsLastHour int
	ModulesUp      int
	WhitelistCount int
}

// NavItem represents a navigation menu item
type NavItem struct {
	Name   string
	Path   string
	Icon   string
	Active bool
}

// UserInfo holds current user session info
type UserInfo struct {
	Username string
	Role     string
}
