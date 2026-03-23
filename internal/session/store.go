// =============================================================================
// NFTBan - Session Management
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="store"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="In-memory session store for nftban-ui authentication"
// meta:input="Session tokens"
// meta:output="Session objects"
// meta:depends="crypto/rand,sync,time"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package session provides simple in-memory session management for nftban-ui.
package session

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"sync"
	"time"
)

var (
	ErrSessionNotFound = errors.New("session not found")
	ErrSessionExpired  = errors.New("session expired")
	ErrInvalidToken    = errors.New("invalid token")
)

// Session represents an authenticated user session
type Session struct {
	Token     string    `json:"token"`
	CSRFToken string    `json:"csrf_token"`
	Username  string    `json:"username"`
	Groups    []string  `json:"groups"`
	ClientIP  string    `json:"client_ip,omitempty"`
	CreatedAt time.Time `json:"created_at"`
	ExpiresAt time.Time `json:"expires_at"`
}

// IsExpired checks if session has expired
func (s *Session) IsExpired() bool {
	return time.Now().After(s.ExpiresAt)
}

// HasGroup checks if user belongs to a group
func (s *Session) HasGroup(group string) bool {
	for _, g := range s.Groups {
		if g == group {
			return true
		}
	}
	return false
}

// IsAdmin checks for admin privileges (nftban group)
// Note: System groups (wheel, sudo, root) are NOT granted admin access
// Users must be in nftban group for CLI/GUI access and admin privileges
func (s *Session) IsAdmin() bool {
	return s.HasGroup("nftban")
}

// ValidateCSRF checks if the provided CSRF token matches the session's token
// SECURITY FIX: Use constant-time comparison to prevent timing attacks
func (s *Session) ValidateCSRF(token string) bool {
	if len(token) != 64 {
		return false
	}
	// Use subtle.ConstantTimeCompare to prevent timing-based token guessing attacks
	return subtle.ConstantTimeCompare([]byte(token), []byte(s.CSRFToken)) == 1
}

// Store is a simple in-memory session store
type Store struct {
	mu       sync.RWMutex
	sessions map[string]*Session
	timeout  time.Duration
}

// NewStore creates a new session store
func NewStore(timeout time.Duration) *Store {
	if timeout == 0 {
		timeout = 30 * time.Minute
	}
	return &Store{
		sessions: make(map[string]*Session),
		timeout:  timeout,
	}
}

// GenerateToken creates a random 32-byte token
func GenerateToken() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// Create stores a new session
func (s *Store) Create(username string, groups []string, clientIP string) (*Session, error) {
	token, err := GenerateToken()
	if err != nil {
		return nil, err
	}

	csrfToken, err := GenerateToken()
	if err != nil {
		return nil, err
	}

	session := &Session{
		Token:     token,
		CSRFToken: csrfToken,
		Username:  username,
		Groups:    groups,
		ClientIP:  clientIP,
		CreatedAt: time.Now(),
		ExpiresAt: time.Now().Add(s.timeout),
	}

	s.mu.Lock()
	s.sessions[token] = session
	s.mu.Unlock()

	return session, nil
}

// Get retrieves a session by token
func (s *Store) Get(token string) (*Session, error) {
	if len(token) != 64 {
		return nil, ErrInvalidToken
	}

	s.mu.RLock()
	session, exists := s.sessions[token]
	s.mu.RUnlock()

	if !exists {
		return nil, ErrSessionNotFound
	}

	if session.IsExpired() {
		s.Delete(token)
		return nil, ErrSessionExpired
	}

	return session, nil
}

// Delete removes a session
func (s *Store) Delete(token string) {
	s.mu.Lock()
	delete(s.sessions, token)
	s.mu.Unlock()
}

// DeleteByUser removes all sessions for a user
func (s *Store) DeleteByUser(username string) int {
	s.mu.Lock()
	defer s.mu.Unlock()

	count := 0
	for token, session := range s.sessions {
		if session.Username == username {
			delete(s.sessions, token)
			count++
		}
	}
	return count
}

// Cleanup removes expired sessions (call periodically)
func (s *Store) Cleanup() int {
	s.mu.Lock()
	defer s.mu.Unlock()

	count := 0
	now := time.Now()
	for token, session := range s.sessions {
		if now.After(session.ExpiresAt) {
			delete(s.sessions, token)
			count++
		}
	}
	return count
}

// Count returns number of active sessions
func (s *Store) Count() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.sessions)
}

// List returns all active sessions (for admin)
func (s *Store) List() []*Session {
	s.mu.RLock()
	defer s.mu.RUnlock()

	list := make([]*Session, 0, len(s.sessions))
	for _, session := range s.sessions {
		if !session.IsExpired() {
			list = append(list, session)
		}
	}
	return list
}
