// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>

package rbac

import (
	"net/http"
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
type Middleware struct {
	permissions map[Role][]Permission
}

// NewMiddleware creates a new RBAC middleware
func NewMiddleware() *Middleware {
	return &Middleware{
		permissions: map[Role][]Permission{
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
		},
	}
}

// HasPermission checks if a role has a specific permission
func (m *Middleware) HasPermission(role Role, perm Permission) bool {
	perms, exists := m.permissions[role]
	if !exists {
		return false
	}

	for _, p := range perms {
		if p == perm {
			return true
		}
	}

	return false
}

// Require returns a middleware that enforces permission
func (m *Middleware) Require(perm Permission) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// Get role from context (set by auth middleware)
			role, ok := r.Context().Value("role").(string)
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
