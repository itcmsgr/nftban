// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>

package session

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"sync"
	"time"
)

// Session represents a user session
type Session struct {
	Username  string
	Role      string
	CreatedAt time.Time
	ExpiresAt time.Time
}

// Store interface for session storage
type Store interface {
	Create(username, role string) (string, error)
	Get(token string) (*Session, error)
	Delete(token string)
	Cleanup()
}

// MemoryStore implements in-memory session storage
type MemoryStore struct {
	sessions map[string]*Session
	mu       sync.RWMutex
	ttl      time.Duration
}

// NewMemoryStore creates a new memory-only session store
func NewMemoryStore(ttl time.Duration) *MemoryStore {
	store := &MemoryStore{
		sessions: make(map[string]*Session),
		ttl:      ttl,
	}

	// Start cleanup goroutine
	go store.cleanupLoop()

	return store
}

// Create creates a new session and returns a token
func (s *MemoryStore) Create(username, role string) (string, error) {
	// Generate 32-byte random token
	tokenBytes := make([]byte, 32)
	if _, err := rand.Read(tokenBytes); err != nil {
		return "", fmt.Errorf("failed to generate token: %w", err)
	}
	token := hex.EncodeToString(tokenBytes)

	s.mu.Lock()
	defer s.mu.Unlock()

	s.sessions[token] = &Session{
		Username:  username,
		Role:      role,
		CreatedAt: time.Now(),
		ExpiresAt: time.Now().Add(s.ttl),
	}

	return token, nil
}

// Get retrieves a session by token
func (s *MemoryStore) Get(token string) (*Session, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	sess, exists := s.sessions[token]
	if !exists {
		return nil, fmt.Errorf("invalid session token")
	}

	if time.Now().After(sess.ExpiresAt) {
		return nil, fmt.Errorf("session expired")
	}

	return sess, nil
}

// Delete removes a session
func (s *MemoryStore) Delete(token string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.sessions, token)
}

// Cleanup removes expired sessions
func (s *MemoryStore) Cleanup() {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	for token, sess := range s.sessions {
		if now.After(sess.ExpiresAt) {
			delete(s.sessions, token)
		}
	}
}

// cleanupLoop runs periodic cleanup
func (s *MemoryStore) cleanupLoop() {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()

	for range ticker.C {
		s.Cleanup()
	}
}

// Count returns number of active sessions (for metrics)
func (s *MemoryStore) Count() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.sessions)
}
