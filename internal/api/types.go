// =============================================================================
// NFTBan - API Type Definitions
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="types"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Common type definitions for API request and response structures"
// meta:input="None"
// meta:output="None"
// meta:depends="github.com/itcmsgr/nftban/internal/setsync"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package api

import (
	"github.com/itcmsgr/nftban/internal/setsync"
)

// API holds dependencies for all API handlers
type API struct {
	NFT              *setsync.NFTManager
	WhitelistIPv4Set *setsync.Set
	WhitelistIPv6Set *setsync.Set
	BlacklistIPv4Set *setsync.Set
	BlacklistIPv6Set *setsync.Set
}

// BatchRequest represents a batch add/remove operation
type BatchRequest struct {
	Add    []string `json:"add"`
	Remove []string `json:"remove"`
}

// BatchResponse represents the result of a batch operation
type BatchResponse struct {
	Added     int    `json:"added"`
	Removed   int    `json:"removed"`
	Unchanged int    `json:"unchanged,omitempty"`
	Success   bool   `json:"success"`
	Message   string `json:"message,omitempty"`
}

// PreviewRequest requests a dry-run diff preview
type PreviewRequest struct {
	Desired []string `json:"desired"`
}

// PreviewResponse shows what would change
type PreviewResponse struct {
	ToAdd     []string `json:"to_add"`
	ToRemove  []string `json:"to_remove"`
	Unchanged int      `json:"unchanged"`
}

// SingleIPRequest for adding/removing single IP
type SingleIPRequest struct {
	IP string `json:"ip"`
}

// SingleIPResponse for single IP operations
type SingleIPResponse struct {
	Success bool   `json:"success"`
	Message string `json:"message"`
}
