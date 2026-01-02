// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>

package handlers

import (
	"context"
	"encoding/json"
	"log"
	"net/http"

	"github.com/itcmsgr/nftban/pkg/webapi/auth"
	"github.com/itcmsgr/nftban/pkg/webapi/rbac"
	"github.com/itcmsgr/nftban/pkg/webapi/session"
)

// Server handles HTTP requests
type Server struct {
	sessions session.Store
	auth     auth.Authenticator
	rbac     *rbac.Middleware
	mux      *http.ServeMux
}

// NewServer creates a new HTTP server
func NewServer(sessions session.Store, auth auth.Authenticator, rbacMW *rbac.Middleware) http.Handler {
	s := &Server{
		sessions: sessions,
		auth:     auth,
		rbac:     rbacMW,
		mux:      http.NewServeMux(),
	}

	s.routes()
	return s.addSecurityHeaders(s.mux)
}

// routes defines all HTTP routes
func (s *Server) routes() {
	// Static files
	fs := http.FileServer(http.Dir("web"))
	s.mux.Handle("/", fs)
	s.mux.Handle("/assets/", fs)

	// Auth endpoints (no auth required)
	s.mux.HandleFunc("/api/v1/login", s.handleLogin)
	s.mux.HandleFunc("/api/v1/logout", s.handleLogout)

	// Protected endpoints
	s.mux.Handle("/api/v1/me", s.requireAuth(http.HandlerFunc(s.handleMe)))
	s.mux.Handle("/api/v1/ban", s.requireAuth(s.rbac.Require(rbac.PermBan)(http.HandlerFunc(s.handleBan))))
	s.mux.Handle("/api/v1/unban", s.requireAuth(s.rbac.Require(rbac.PermUnban)(http.HandlerFunc(s.handleUnban))))
	s.mux.Handle("/api/v1/list", s.requireAuth(s.rbac.Require(rbac.PermList)(http.HandlerFunc(s.handleList))))
	s.mux.Handle("/api/v1/metrics/overview", s.requireAuth(s.rbac.Require(rbac.PermMetricsRead)(http.HandlerFunc(s.handleMetricsOverview))))
}

// handleLogin handles POST /api/v1/login
func (s *Server) handleLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}

	// Authenticate via PAM
	role, err := s.auth.Authenticate(req.Username, req.Password)
	if err != nil {
		log.Printf("[auth] Login failed for %s: %v", req.Username, err)
		http.Error(w, "Authentication failed", http.StatusUnauthorized)
		return
	}

	// Create session
	token, err := s.sessions.Create(req.Username, role)
	if err != nil {
		log.Printf("[auth] Failed to create session for %s: %v", req.Username, err)
		http.Error(w, "Internal server error", http.StatusInternalServerError)
		return
	}

	log.Printf("[auth] Login successful: %s (role=%s)", req.Username, role)

	// Return token
	json.NewEncoder(w).Encode(map[string]interface{}{
		"token": token,
		"user":  req.Username,
		"role":  role,
	})
}

// handleLogout handles POST /api/v1/logout
func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	token := r.Header.Get("X-Session-Token")
	if token != "" {
		s.sessions.Delete(token)
	}

	w.WriteHeader(http.StatusNoContent)
}

// handleMe handles GET /api/v1/me
func (s *Server) handleMe(w http.ResponseWriter, r *http.Request) {
	username, _ := r.Context().Value("username").(string)
	role, _ := r.Context().Value("role").(string)

	json.NewEncoder(w).Encode(map[string]interface{}{
		"username": username,
		"role":     role,
	})
}

// handleBan handles POST /api/v1/ban
func (s *Server) handleBan(w http.ResponseWriter, r *http.Request) {
	var req struct {
		IP     string `json:"ip"`
		Reason string `json:"reason"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}

	// TODO: Call nftband via IPC
	log.Printf("[ban] Ban IP: %s (reason: %s)", req.IP, req.Reason)

	json.NewEncoder(w).Encode(map[string]interface{}{
		"success": true,
		"ip":      req.IP,
	})
}

// handleUnban handles POST /api/v1/unban
func (s *Server) handleUnban(w http.ResponseWriter, r *http.Request) {
	var req struct {
		IP string `json:"ip"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "Invalid request", http.StatusBadRequest)
		return
	}

	// TODO: Call nftband via IPC
	log.Printf("[unban] Unban IP: %s", req.IP)

	json.NewEncoder(w).Encode(map[string]interface{}{
		"success": true,
		"ip":      req.IP,
	})
}

// handleList handles GET /api/v1/list
func (s *Server) handleList(w http.ResponseWriter, r *http.Request) {
	// TODO: Call nftband via IPC
	log.Printf("[list] List banned IPs")

	json.NewEncoder(w).Encode(map[string]interface{}{
		"ips": []string{"1.2.3.4", "5.6.7.8"},
	})
}

// handleMetricsOverview handles GET /api/v1/metrics/overview
func (s *Server) handleMetricsOverview(w http.ResponseWriter, r *http.Request) {
	// TODO: Query Prometheus
	log.Printf("[metrics] Overview requested")

	json.NewEncoder(w).Encode(map[string]interface{}{
		"blocked_ips":    1234,
		"firewall_rules": 567,
		"health_ok":      true,
		"uptime_seconds": 86400,
	})
}

// requireAuth middleware validates session token
func (s *Server) requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := r.Header.Get("X-Session-Token")
		if token == "" {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}

		sess, err := s.sessions.Get(token)
		if err != nil {
			http.Error(w, "Invalid or expired session", http.StatusUnauthorized)
			return
		}

		// Add user info to context
		ctx := context.WithValue(r.Context(), "username", sess.Username)
		ctx = context.WithValue(ctx, "role", sess.Role)

		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// addSecurityHeaders adds security headers to all responses
func (s *Server) addSecurityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Permissions-Policy", "geolocation=(), microphone=(), camera=()")

		next.ServeHTTP(w, r)
	})
}
