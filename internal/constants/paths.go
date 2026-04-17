// =============================================================================
// NFTBan v1.96.0 - Centralized Binary Path Constants
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="constants/paths"
// meta:type="package"
// meta:version="1.96.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Centralized binary path constants for internal tools"
// meta:inventory.files="paths.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// Single canonical definition for internal binary paths.
// Never duplicate these paths as string literals.
package constants

// ValidatorBinPath is the canonical path to the nftban-validate binary.
const ValidatorBinPath = "/usr/lib/nftban/bin/nftban-validate"
