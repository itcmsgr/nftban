// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>

package auth

import (
	"fmt"
	"os/user"

	"github.com/msteinert/pam"
)

// Authenticator interface for user authentication
type Authenticator interface {
	Authenticate(username, password string) (string, error)
}

// PAMAuthenticator implements PAM-based authentication
type PAMAuthenticator struct {
	serviceName string
}

// NewPAMAuthenticator creates a new PAM authenticator
func NewPAMAuthenticator() *PAMAuthenticator {
	return &PAMAuthenticator{
		serviceName: "nftban-api",
	}
}

// Authenticate validates username/password via PAM
func (a *PAMAuthenticator) Authenticate(username, password string) (string, error) {
	// CRITICAL: Block root login BEFORE PAM
	if username == "root" {
		return "", fmt.Errorf("root login forbidden")
	}

	// Validate username exists
	usr, err := user.Lookup(username)
	if err != nil {
		return "", fmt.Errorf("user not found: %w", err)
	}

	// PAM authentication
	t, err := pam.StartFunc(a.serviceName, username, func(s pam.Style, msg string) (string, error) {
		switch s {
		case pam.PromptEchoOff:
			return password, nil
		case pam.PromptEchoOn, pam.ErrorMsg, pam.TextInfo:
			return "", nil
		}
		return "", fmt.Errorf("unrecognized PAM message style")
	})

	if err != nil {
		return "", fmt.Errorf("PAM start failed: %w", err)
	}

	if err := t.Authenticate(0); err != nil {
		return "", fmt.Errorf("authentication failed: %w", err)
	}

	// Determine role based on group membership
	role := determineRole(usr)

	return role, nil
}

// determineRole determines user role based on group membership
func determineRole(usr *user.User) string {
	// Get user groups
	groupIDs, err := usr.GroupIds()
	if err != nil {
		return "operator" // Default role
	}

	// Check for admin groups
	for _, gid := range groupIDs {
		grp, err := user.LookupGroupId(gid)
		if err != nil {
			continue
		}

		switch grp.Name {
		case "wheel", "sudo", "nftban-admin":
			return "admin"
		case "nftban-panel-admin":
			return "panel-admin"
		case "nftban-panel":
			return "panel-user"
		}
	}

	// Check if in nftban group
	for _, gid := range groupIDs {
		grp, err := user.LookupGroupId(gid)
		if err != nil {
			continue
		}
		if grp.Name == "nftban" {
			return "operator"
		}
	}

	return "operator" // Default
}
