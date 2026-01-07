// =============================================================================
// NFTBan - Authentication Protocol Types
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="types"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Shared authentication protocol types for pkg/auth and cmd/nftban-ui-auth"
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

// Package authproto defines shared authentication protocol types
// Used by both pkg/auth and cmd/nftban-ui-auth to ensure consistency
package authproto

// AuthRequest represents a login request
type AuthRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// AuthResponse represents the authentication result
type AuthResponse struct {
	Success bool   `json:"success"`
	Message string `json:"message,omitempty"`
	Error   string `json:"error,omitempty"`
}

// NewSuccessResponse creates a successful auth response
func NewSuccessResponse(message string) AuthResponse {
	return AuthResponse{
		Success: true,
		Message: message,
	}
}

// NewErrorResponse creates an error auth response
func NewErrorResponse(err string) AuthResponse {
	return AuthResponse{
		Success: false,
		Error:   err,
	}
}
