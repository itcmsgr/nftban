// =============================================================================
// NFTBan v1.0 - Sync Package
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="doc"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-21"
// meta:description="Package documentation for NFTBan set synchronization"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package setsync provides efficient synchronization of IP sets with nftables.
//
// # Overview
//
// The setsync package handles the core operation of comparing desired state
// (from feeds, config files, etc.) with actual state in nftables, and
// applying minimal changes to reconcile them.
//
// # Key Features
//
//   - Diff Algorithm: Computes minimal add/delete operations
//   - CIDR Merging: Optimizes overlapping ranges into minimal set
//   - Atomic Apply: Uses nft atomic transactions for consistency
//   - Batch Operations: Groups changes for efficiency
//
// # CIDR Optimization
//
// The package can merge overlapping and adjacent CIDR ranges:
//
//	cidrs := []string{"10.0.0.0/24", "10.0.1.0/24", "10.0.0.128/25"}
//	merged := setsync.MergeCIDRs(cidrs)
//	// Result: ["10.0.0.0/23"] (two /24s merged)
//
// # Sync Flow
//
//	// 1. Get current state from nftables
//	current := setsync.GetSetElements("ip", "nftban", "blacklist_ipv4")
//
//	// 2. Compute diff
//	toAdd, toRemove := setsync.Diff(desired, current)
//
//	// 3. Apply changes atomically
//	setsync.Apply(toAdd, toRemove)
//
// # Thread Safety
//
// Sync operations should be serialized through the IPC mechanism to ensure
// consistency. Direct use of this package should only be from nftband daemon.
package setsync
