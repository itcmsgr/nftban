// =============================================================================
// NFTBan v1.0 - NFT Backend Package
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="doc"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-21"
// meta:description="Package documentation for NFTBan nftables backend"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package nftbackend provides the core interface to nftables operations.
//
// # Architecture
//
// This package is the single point of truth for nftables write operations
// in NFTBan. It enforces the single-writer architecture where only the
// nftband daemon should perform nftables modifications.
//
// # Operations
//
// The backend supports:
//
//   - Ban: Add IP to blacklist set
//   - Unban: Remove IP from blacklist set
//   - Whitelist: Add/remove from whitelist set
//   - Sync: Bulk update of sets (feeds, geoban)
//   - Flush: Clear all entries from a set
//
// # Safety Features
//
//   - Validates IPs before operations
//   - Prevents blocking of system IPs
//   - Uses atomic nft transactions
//   - Logs all operations for audit
//
// # Thread Safety
//
// The Backend type uses mutex locking to ensure thread-safe operations.
// Multiple goroutines can safely call Ban/Unban concurrently.
//
// # Usage
//
// The backend is instantiated by nftband daemon:
//
//	backend := nftbackend.New()
//	err := backend.Ban("192.168.1.100", "manual", 0)
//	err := backend.Unban("192.168.1.100")
//
// CLI tools should use the IPC client instead of this package directly.
package nftbackend
