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
