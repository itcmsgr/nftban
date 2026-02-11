// =============================================================================
// NFTBan - PAM Authentication Handler
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="pam"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="PAM-based authentication with JWT token generation and RBAC"
// meta:input="Unix socket auth requests"
// meta:output="JWT tokens and user claims"
// meta:depends="github.com/golang-jwt/jwt/v5"
// meta:inventory.files="/run/nftban-ui/auth.sock"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package auth

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"os/user"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/itcmsgr/nftban/internal/authproto"
	"github.com/itcmsgr/nftban/internal/config"
)

// PAMAuth handles PAM-based authentication
type PAMAuth struct {
	config *config.Config
}

// User represents an authenticated user
type User struct {
	Username string
	UID      string
	GID      string
	Groups   []string
}

// Claims represents JWT claims
type Claims struct {
	Username string   `json:"username"`
	Groups   []string `json:"groups"`
	jwt.RegisteredClaims
}

// =============================================================================
// RBAC Helper Methods for Claims
// =============================================================================
//
// NFTBan 3-Group Security Model:
//   - nftban:         Admin/Operator (full access, config, service management)
//   - nftban-auditor: Read-only (reports, logs, status - NO actions)
//   - nftban-panel:   Panel Operator (ban/unban/status - NO config/restart)
//
// Authorization hierarchy:
//   CanConfig() → nftban only (configuration changes)
//   CanAct()    → nftban OR nftban-panel (runtime actions: ban/unban)
//   CanRead()   → nftban OR nftban-auditor OR nftban-panel (view logs/status)
//
// =============================================================================

// HasGroup checks if the user belongs to a specific group
func (c *Claims) HasGroup(group string) bool {
	for _, g := range c.Groups {
		if g == group {
			return true
		}
	}
	return false
}

// HasAnyGroup checks if the user belongs to any of the specified groups
func (c *Claims) HasAnyGroup(groups ...string) bool {
	for _, required := range groups {
		if c.HasGroup(required) {
			return true
		}
	}
	return false
}

// HasAllGroups checks if the user belongs to all of the specified groups
func (c *Claims) HasAllGroups(groups ...string) bool {
	for _, required := range groups {
		if !c.HasGroup(required) {
			return false
		}
	}
	return true
}

// =============================================================================
// Role Checks (explicit group membership)
// =============================================================================

// IsAdmin checks if the user has admin privileges (nftban group)
// Admins have full access: config changes, service management, all actions
func (c *Claims) IsAdmin() bool {
	return c.HasGroup("nftban")
}

// IsPanelOperator checks if the user is a panel integration account
// Panel operators can perform runtime actions but NOT config changes
func (c *Claims) IsPanelOperator() bool {
	return c.HasGroup("nftban-panel")
}

// IsAuditor checks if the user is a read-only auditor
// Auditors can view logs/reports/status but CANNOT perform any actions
func (c *Claims) IsAuditor() bool {
	return c.HasGroup("nftban-auditor")
}

// =============================================================================
// Permission Checks (capability-based)
// =============================================================================

// IsOperator checks if the user can perform runtime actions (ban/unban/status)
// Includes: nftban (admin) and nftban-panel (panel operators)
// Excludes: nftban-auditor (auditors are read-only, NOT operators)
func (c *Claims) IsOperator() bool {
	return c.HasAnyGroup("nftban", "nftban-panel")
}

// CanRead checks if the user can view logs, reports, and status
// All authenticated users with valid groups can read
func (c *Claims) CanRead() bool {
	return c.HasAnyGroup("nftban", "nftban-auditor", "nftban-panel")
}

// CanAct checks if the user can perform runtime actions (ban/unban/whitelist)
// Only admins and panel operators - NOT auditors
func (c *Claims) CanAct() bool {
	return c.HasAnyGroup("nftban", "nftban-panel")
}

// CanConfig checks if the user can modify configuration
// Only admins (nftban group) - NOT panel operators or auditors
func (c *Claims) CanConfig() bool {
	return c.HasGroup("nftban")
}

// =============================================================================
// Legacy/Compatibility Methods
// =============================================================================

// CanModify is an alias for CanAct (runtime action permission)
// Deprecated: Use CanAct() for actions or CanConfig() for configuration
func (c *Claims) CanModify() bool {
	return c.CanAct()
}

// CanViewLogs checks if the user can view log files
func (c *Claims) CanViewLogs() bool {
	return c.CanRead()
}

// MinJWTSecretLength is the minimum required length for JWT secrets (32 bytes = 256 bits)
const MinJWTSecretLength = 32

// NewPAMAuth creates a new PAM authentication handler
// Returns error if JWT secret is too short (security requirement)
func NewPAMAuth(cfg *config.Config) (*PAMAuth, error) {
	// SECURITY: Enforce minimum JWT secret length
	if len(cfg.JWTSecret) < MinJWTSecretLength {
		return nil, fmt.Errorf("JWT secret too short: got %d bytes, minimum %d bytes required", len(cfg.JWTSecret), MinJWTSecretLength)
	}
	return &PAMAuth{
		config: cfg,
	}, nil
}

// AuthRequest is an alias to shared authproto.AuthRequest
type AuthRequest = authproto.AuthRequest

// AuthResponse is an alias to shared authproto.AuthResponse
type AuthResponse = authproto.AuthResponse

// Authenticate validates user credentials via Unix socket to auth service
func (p *PAMAuth) Authenticate(username, password string) (*User, error) {
	// SECURITY: Block root login if configured
	if p.config.BlockRootLogin && username == "root" {
		log.Printf("[SECURITY] Root login attempt blocked for username: %s", username)
		return nil, fmt.Errorf("root login is disabled")
	}

	// Connect to authentication socket
	const socketPath = "/run/nftban-ui/auth.sock"

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	var d net.Dialer
	conn, err := d.DialContext(ctx, "unix", socketPath)
	if err != nil {
		log.Printf("[ERROR] Failed to connect to auth socket: %v", err)
		return nil, fmt.Errorf("authentication service unavailable")
	}
	defer conn.Close()

	// Send authentication request
	req := AuthRequest{
		Username: username,
		Password: password,
	}

	reqData, err := json.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("failed to prepare auth request: %w", err)
	}

	// Write request with newline
	if _, err := conn.Write(append(reqData, '\n')); err != nil {
		return nil, fmt.Errorf("failed to send auth request: %w", err)
	}

	// Read response
	scanner := bufio.NewScanner(conn)
	if !scanner.Scan() {
		return nil, fmt.Errorf("failed to read auth response")
	}

	var resp AuthResponse
	if err := json.Unmarshal(scanner.Bytes(), &resp); err != nil {
		return nil, fmt.Errorf("failed to parse auth response: %w", err)
	}

	// Check authentication result
	if !resp.Success {
		log.Printf("[AUTH] Failed login attempt for user: %s", username)
		return nil, fmt.Errorf("authentication failed: %s", resp.Error)
	}

	// Get user information
	u, err := user.Lookup(username)
	if err != nil {
		return nil, fmt.Errorf("failed to lookup user: %w", err)
	}

	// Get user groups
	groups, err := p.getUserGroups(u)
	if err != nil {
		return nil, fmt.Errorf("failed to get user groups: %w", err)
	}

	// Success
	log.Printf("[AUTH] Successful login: %s (UID: %s)", username, u.Uid)

	return &User{
		Username: username,
		UID:      u.Uid,
		GID:      u.Gid,
		Groups:   groups,
	}, nil
}

// GenerateToken creates a JWT token for authenticated user
func (p *PAMAuth) GenerateToken(user *User) (string, error) {
	// Create claims
	claims := &Claims{
		Username: user.Username,
		Groups:   user.Groups,
		RegisteredClaims: jwt.RegisteredClaims{
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Duration(p.config.SessionTimeout) * time.Minute)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
			NotBefore: jwt.NewNumericDate(time.Now()),
			Issuer:    "nftban-ui",
			Subject:   user.Username,
		},
	}

	// Create token
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)

	// Sign token
	tokenString, err := token.SignedString([]byte(p.config.JWTSecret))
	if err != nil {
		return "", fmt.Errorf("failed to sign token: %w", err)
	}

	return tokenString, nil
}

// ValidateToken verifies and parses a JWT token
func (p *PAMAuth) ValidateToken(tokenString string) (*Claims, error) {
	// Parse token
	token, err := jwt.ParseWithClaims(tokenString, &Claims{}, func(token *jwt.Token) (interface{}, error) {
		// Verify signing method
		if _, ok := token.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", token.Header["alg"])
		}
		return []byte(p.config.JWTSecret), nil
	})

	if err != nil {
		return nil, fmt.Errorf("token validation failed: %w", err)
	}

	// Extract claims
	if claims, ok := token.Claims.(*Claims); ok && token.Valid {
		return claims, nil
	}

	return nil, fmt.Errorf("invalid token")
}

// getUserGroups retrieves all groups for a user
func (p *PAMAuth) getUserGroups(u *user.User) ([]string, error) {
	gids, err := u.GroupIds()
	if err != nil {
		return nil, err
	}

	groups := make([]string, 0, len(gids))
	for _, gid := range gids {
		g, err := user.LookupGroupId(gid)
		if err != nil {
			continue
		}
		groups = append(groups, g.Name)
	}

	return groups, nil
}

// AuditLog writes an audit log entry
func (p *PAMAuth) AuditLog(username, action, result, clientIP string) {
	// TODO: Write to audit log file
	log.Printf("[AUDIT] User: %s | Action: %s | Result: %s | IP: %s", username, action, result, clientIP)
}
