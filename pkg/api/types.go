package api

import (
	"github.com/google/nftables"
	"github.com/itcmsgr/nftban-v1.0-dev/pkg/sync"
)

// API holds dependencies for all API handlers
type API struct {
	NFT              *sync.NFTManager
	WhitelistIPv4Set *nftables.Set
	WhitelistIPv6Set *nftables.Set
	BlacklistIPv4Set *nftables.Set
	BlacklistIPv6Set *nftables.Set
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
