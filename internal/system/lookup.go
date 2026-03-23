// =============================================================================
// NFTBan - System Lookup Utilities
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="lookup"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Unified system lookup for groups and users with fallback parsing"
// meta:input="User/group names"
// meta:output="UIDs and GIDs"
// meta:depends="os/user,os"
// meta:inventory.files="/etc/group,/etc/passwd"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package system provides unified system lookup utilities
package system

import (
	"bufio"
	"fmt"
	"os"
	"os/user"
	"strings"
)

// LookupGroupID finds GID by group name
// Prefers os/user package, falls back to /etc/group parsing
func LookupGroupID(name string) (int, error) {
	// Try standard library first
	g, err := user.LookupGroup(name)
	if err == nil {
		var gid int
		fmt.Sscanf(g.Gid, "%d", &gid)
		return gid, nil
	}

	// Fallback: manual /etc/group parsing
	return lookupGroupFromFile(name)
}

// lookupGroupFromFile parses /etc/group directly
func lookupGroupFromFile(name string) (int, error) {
	file, err := os.Open("/etc/group")
	if err != nil {
		return 0, err
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.Split(line, ":")
		if len(parts) >= 3 && parts[0] == name {
			var gid int
			fmt.Sscanf(parts[2], "%d", &gid)
			return gid, nil
		}
	}
	if err := scanner.Err(); err != nil {
		return 0, err
	}
	return 0, fmt.Errorf("group %s not found", name)
}

// GetUserGroups returns all group names for a user
func GetUserGroups(u *user.User) ([]string, error) {
	gids, err := u.GroupIds()
	if err != nil {
		return nil, err
	}

	groups := make([]string, 0, len(gids))
	for _, gid := range gids {
		g, err := user.LookupGroupId(gid)
		if err != nil {
			continue // Skip groups we can't resolve
		}
		groups = append(groups, g.Name)
	}
	return groups, nil
}
