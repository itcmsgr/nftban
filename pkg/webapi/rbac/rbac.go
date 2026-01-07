// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>

package rbac

import (
	"net/http"

	"github.com/itcmsgr/nftban/pkg/webapi"
)

// Role represents user roles
type Role string

const (
	RoleAdmin      Role = "admin"
	RoleOperator   Role = "operator"
	RolePanelAdmin Role = "panel-admin"
	RolePanelUser  Role = "panel-user"
)

// Permission represents an action permission
type Permission string

const (
	PermBan          Permission = "ban"
	PermUnban        Permission = "unban"
	PermList         Permission = "list"
	PermSearch       Permission = "search"
	PermMetricsRead  Permission = "metrics.read"
	PermAuditRead    Permission = "audit.read"
	PermConfigRead   Permission = "config.read"
	PermConfigWrite  Permission = "config.write"
	PermServiceControl Permission = "service.control"
)

// Middleware implements RBAC authorization
// Uses O(1) hash set lookups instead of O(n) linear search
type Middleware struct {
	permissions map[Role]map[Permission]struct{} // O(1) lookup
}

// NewMiddleware creates a new RBAC middleware with O(1) permission lookups
func NewMiddleware() *Middleware {
	m := &Middleware{
		permissions: make(map[Role]map[Permission]struct{}),
	}

	// Define permissions per role - converted to sets for O(1) lookup
	rolePerms := map[Role][]Permission{
		RoleAdmin: {
			PermBan, PermUnban, PermList, PermSearch,
			PermMetricsRead, PermAuditRead,
			PermConfigRead, PermConfigWrite,
			PermServiceControl,
		},
		RoleOperator: {
			PermList, PermSearch,
			PermMetricsRead, PermAuditRead,
			PermConfigRead,
		},
		RolePanelAdmin: {
			PermBan, PermUnban, PermList, PermSearch,
			PermMetricsRead, PermAuditRead,
		},
		RolePanelUser: {
			PermList, PermSearch,
			PermMetricsRead,
		},
	}

	// Convert slices to sets for O(1) lookup
	for role, perms := range rolePerms {
		m.permissions[role] = make(map[Permission]struct{}, len(perms))
		for _, p := range perms {
			m.permissions[role][p] = struct{}{}
		}
	}

	return m
}

// HasPermission checks if a role has a specific permission
// Optimized: O(1) hash lookup instead of O(n) linear search
func (m *Middleware) HasPermission(role Role, perm Permission) bool {
	perms, exists := m.permissions[role]
	if !exists {
		return false
	}

	_, hasPerm := perms[perm]
	return hasPerm
}

// Require returns a middleware that enforces permission
func (m *Middleware) Require(perm Permission) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Get role from context (set by auth middleware)
			role, ok := r.Context().Value(webapi.ContextKeyRole).(string)
			if !ok {
				http.Error(w, "Unauthorized", http.StatusUnauthorized)
				return
			}

			if !m.HasPermission(Role(role), perm) {
				http.Error(w, "Forbidden", http.StatusForbidden)
				return
			}

			next.ServeHTTP(w, r)
		})
	}
}
