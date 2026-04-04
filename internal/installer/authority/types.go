// =============================================================================
// NFTBan v1.73 - Installer Authority Types
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-authority-types"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Authority decision enum and types"
// meta:inventory.files="internal/installer/authority/types.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_TAKEOVER"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package authority

// Decision represents the authority classification for the install.
type Decision string

const (
	// Update means NFTBan already owns the firewall (table + chain exist).
	Update Decision = "UPDATE"

	// Fresh means no conflicting firewalls — clean slate.
	Fresh Decision = "FRESH"

	// Takeover means conflicts exist but takeover is approved
	// (via env var, panel auto-approve, or user confirmation).
	Takeover Decision = "TAKEOVER"

	// Abort means conflicts exist and takeover is not approved.
	Abort Decision = "ABORT"
)
