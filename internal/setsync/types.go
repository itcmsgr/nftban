// =============================================================================
// NFTBan - Sync Package Type Exports
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="types"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-02-14"
// meta:description="Type exports for nftables abstraction - isolates netlink types from API layer"
// meta:input="None"
// meta:output="None"
// meta:depends="github.com/google/nftables"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package setsync

import "github.com/google/nftables"

// Set is a type alias for nftables.Set.
// This allows the API layer to use nftables set references without directly
// importing the github.com/google/nftables package, keeping all netlink-related
// imports isolated to the sync package.
//
// Packages that need to work with nftables sets should:
//   - Import internal/setsync (not github.com/google/nftables)
//   - Use *setsync.Set in their type definitions
//   - Pass set references to setsync package functions for operations
//
// This abstraction supports the architecture principle of IPC-based firewall
// operations, where only the nftband daemon (via the sync package) performs
// actual netlink operations.
type Set = nftables.Set

// TableFamily is a type alias for nftables.TableFamily.
// Used when creating or referencing nftables tables.
type TableFamily = nftables.TableFamily

// Table family constants for convenience
const (
	TableFamilyIPv4 = nftables.TableFamilyIPv4
	TableFamilyIPv6 = nftables.TableFamilyIPv6
)
