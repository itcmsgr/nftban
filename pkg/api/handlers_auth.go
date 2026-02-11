// =============================================================================
// NFTBan - Authentication API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="handlers_auth"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-30"
// meta:description="Authentication and session management API handlers"
// meta:input="HTTP requests for login/logout/session operations"
// meta:output="JSON responses with auth tokens and session info"
// meta:depends="github.com/itcmsgr/nftban/pkg/auth,github.com/itcmsgr/nftban/pkg/session"
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
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/pkg/auth"
	"github.com/itcmsgr/nftban/pkg/metrics"
	"github.com/itcmsgr/nftban/pkg/middleware"
	"github.com/itcmsgr/nftban/pkg/session"
)

// LoginRequest represents login credentials
type LoginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

// LoginResponse represents login result
type LoginResponse struct {
	Success bool   `json:"success"`
	Token   string `json:"token,omitempty"`
	Message string `json:"message"`
}

// MeHandler returns current user information
func MeHandler(w http.ResponseWriter, r *http.Request) {
	// Get authenticated user from context
	claims, ok := r.Context().Value(middleware.UserContextKey).(*auth.Claims)
	if !ok {
		respondJSON(w, http.StatusUnauthorized, ErrorResponse{Error: "Unauthorized"})
		return
	}

	// Mark user as active
	markUserActive(claims.Username)

	// Get latest sample from global sampler (fast!)
	sampler := metrics.GetSampler()
	samples := sampler.GetRecentSamples(1)

	var statusData map[string]interface{}
	if len(samples) > 0 {
		// Use latest sample
		sample := samples[0]
		statusData = sample.RawData

		// Warn if sample is old
		age := time.Since(sample.Timestamp)
		if age > 30*time.Second {
			log.Printf("[WARN] Latest sample is old (age: %s)", age.Round(time.Second))
		}
	} else {
		// Fallback to direct CLI call if no samples yet
		log.Println("[WARN] No samples available, calling CLI directly")
		statusOutput, err := execNFTBanCommand("status", "--json")
		if err != nil {
			log.Printf("[ERROR] Failed to get status: %v", err)
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to get status"})
			return
		}

		if err := json.Unmarshal([]byte(statusOutput), &statusData); err != nil {
			log.Printf("[ERROR] Failed to parse status JSON: %v", err)
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse status"})
			return
		}
	}

	// Get health data from CLI (skip for now - also slow)
	var healthData map[string]interface{}

	// Get feeds data from CLI with timeout (5 seconds max)
	var feedsData map[string]interface{}
	feedsOutput, err := execNFTBanCommandWithTimeout(5*time.Second, "feeds", "status", "--json")
	if err == nil {
		json.Unmarshal([]byte(feedsOutput), &feedsData)
	} else {
		log.Printf("[WARN] Feeds status timed out or failed: %v", err)
	}

	// Build response matching frontend expectations
	userInfo := map[string]interface{}{
		"username": claims.Username,
		"groups":   claims.Groups,
		"version":  statusData["version"],
	}

	// Map firewall data to frontend format
	if firewall, ok := statusData["firewall"].(map[string]interface{}); ok {
		userInfo["counters"] = map[string]interface{}{
			"blocked_total": firewall["banned_ips"],
			"rule_count":    firewall["rule_count"],
		}
		userInfo["active_sets"] = []string{"ban_v4", "ban_v6"}
	}

	// Extract feed sync info (or use defaults)
	if feedsData != nil {
		if data, ok := feedsData["data"].(map[string]interface{}); ok {
			userInfo["last_feed_sync"] = data["last_sync"]
			if enabledFeeds, ok := data["enabled_feeds"].([]interface{}); ok {
				deltas := make([]int, len(enabledFeeds))
				for i := range deltas {
					deltas[i] = 0
				}
				userInfo["feed_deltas"] = deltas
			}
		}
	} else {
		userInfo["last_feed_sync"] = nil
		userInfo["feed_deltas"] = []int{0}
	}

	// Add health status (or default)
	if healthData != nil {
		if data, ok := healthData["data"].(map[string]interface{}); ok {
			userInfo["health_status"] = data["overall_status"]
		}
	} else {
		if health, ok := statusData["health"].(map[string]interface{}); ok {
			userInfo["health_status"] = health["status"]
		} else {
			userInfo["health_status"] = "unknown"
		}
	}

	userInfo["updated_at"] = time.Now().Format(time.RFC3339)
	respondJSON(w, http.StatusOK, userInfo)
}

// =============================================================================
// Session-Based Authentication Handlers (v1.1 - JWT Replacement)
// =============================================================================

// SessionLoginHandler authenticates user via PAM and creates server-side session
func SessionLoginHandler(authService *auth.PAMAuth, store *session.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req LoginRequest
		if !DecodeJSONBody(w, r, &req) {
			return
		}

		// Authenticate user via PAM socket
		user, err := authService.Authenticate(req.Username, req.Password)
		if err != nil {
			clientIP := middleware.GetClientIP(r)
			authService.AuditLog(req.Username, "login", "failed", clientIP)
			respondJSON(w, http.StatusUnauthorized, LoginResponse{
				Success: false,
				Message: "Authentication failed",
			})
			return
		}

		// Create server-side session
		clientIP := middleware.GetClientIP(r)
		sess, err := store.Create(user.Username, user.Groups, clientIP)
		if err != nil {
			log.Printf("[ERROR] Failed to create session: %v", err)
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to create session"})
			return
		}

		authService.AuditLog(req.Username, "login", "success", clientIP)

		// Start metrics sampling for this session
		sampler := metrics.GetSampler()
		sampler.AddSession()
		log.Printf("[SESSION] Created session for user %s (token: %s...)", req.Username, sess.Token[:8])

		respondJSON(w, http.StatusOK, LoginResponse{
			Success: true,
			Token:   sess.Token,
			Message: "Login successful",
		})
	}
}

// LogoutHandler invalidates the current session
func LogoutHandler(store *session.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := r.Header.Get("X-Session-Token")
		if token == "" {
			authHeader := r.Header.Get("Authorization")
			if authHeader != "" {
				parts := strings.SplitN(authHeader, " ", 2)
				if len(parts) == 2 && parts[0] == "Bearer" {
					token = parts[1]
				}
			}
		}

		if token == "" {
			respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "No session token provided"})
			return
		}

		sess, _ := store.Get(token)
		username := "unknown"
		if sess != nil {
			username = sess.Username
		}

		store.Delete(token)

		sampler := metrics.GetSampler()
		sampler.RemoveSession()

		log.Printf("[SESSION] Logged out user %s", username)
		respondJSON(w, http.StatusOK, SuccessResponse{
			Success: true,
			Message: "Logged out successfully",
		})
	}
}

// SessionInfoHandler returns current session information
func SessionInfoHandler(store *session.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := r.Header.Get("X-Session-Token")
		if token == "" {
			authHeader := r.Header.Get("Authorization")
			if authHeader != "" {
				parts := strings.SplitN(authHeader, " ", 2)
				if len(parts) == 2 && parts[0] == "Bearer" {
					token = parts[1]
				}
			}
		}

		if token == "" {
			respondJSON(w, http.StatusUnauthorized, ErrorResponse{Error: "No session token"})
			return
		}

		sess, err := store.Get(token)
		if err != nil {
			respondJSON(w, http.StatusUnauthorized, ErrorResponse{Error: "Invalid session"})
			return
		}

		respondJSON(w, http.StatusOK, map[string]interface{}{
			"username":   sess.Username,
			"groups":     sess.Groups,
			"client_ip":  sess.ClientIP,
			"created_at": sess.CreatedAt.Format(time.RFC3339),
			"expires_at": sess.ExpiresAt.Format(time.RFC3339),
			"is_admin":   sess.IsAdmin(),
		})
	}
}

// SessionsListHandler returns all active sessions (admin only)
func SessionsListHandler(store *session.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		claims, ok := r.Context().Value(middleware.UserContextKey).(*auth.Claims)
		if !ok || !claims.IsAdmin() {
			respondJSON(w, http.StatusForbidden, ErrorResponse{Error: "Admin access required"})
			return
		}

		sessions := store.List()

		sessionList := make([]map[string]interface{}, 0, len(sessions))
		for _, sess := range sessions {
			sessionList = append(sessionList, map[string]interface{}{
				"token_prefix": sess.Token[:8] + "...",
				"username":     sess.Username,
				"groups":       sess.Groups,
				"client_ip":    sess.ClientIP,
				"created_at":   sess.CreatedAt.Format(time.RFC3339),
				"expires_at":   sess.ExpiresAt.Format(time.RFC3339),
			})
		}

		respondJSON(w, http.StatusOK, map[string]interface{}{
			"count":    len(sessions),
			"sessions": sessionList,
		})
	}
}

// SessionRevokeHandler revokes a specific session (admin only)
func SessionRevokeHandler(store *session.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		claims, ok := r.Context().Value(middleware.UserContextKey).(*auth.Claims)
		if !ok || !claims.IsAdmin() {
			respondJSON(w, http.StatusForbidden, ErrorResponse{Error: "Admin access required"})
			return
		}

		var req struct {
			Username string `json:"username"`
		}
		if !DecodeJSONBody(w, r, &req) {
			return
		}

		if req.Username == "" {
			respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Username required"})
			return
		}

		count := store.DeleteByUser(req.Username)

		log.Printf("[ADMIN] User %s revoked %d sessions for user %s", claims.Username, count, req.Username)
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success":  true,
			"message":  fmt.Sprintf("Revoked %d sessions for user %s", count, req.Username),
			"revoked":  count,
			"username": req.Username,
		})
	}
}
