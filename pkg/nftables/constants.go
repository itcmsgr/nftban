// =============================================================================
// NFTBan - NFTables Constants
// =============================================================================
// SPDX-License-Identifier: GPL-3.0-or-later
// meta:name="constants"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="NFTables table name constants for dual-table architecture"
// meta:input="None"
// meta:output="None"
// meta:depends="None"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package nftables

// NFTables table names for NFTBan v1.0.0 dual-table architecture
const (
	TableIPv4 = "ip nftban"
	TableIPv6 = "ip6 nftban"
)
