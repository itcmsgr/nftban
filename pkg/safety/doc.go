// =============================================================================
// NFTBan v1.0 - Safety Package
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="doc"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-21"
// meta:description="Package documentation for NFTBan safety mechanisms"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package safety provides protection mechanisms to prevent self-lockout and
// ensure system stability during firewall operations.
//
// # Features
//
// The safety package implements several protection mechanisms:
//
//   - System IP Detection: Auto-detects IPs that must never be blocked
//     (server IP, gateway, DNS servers, active SSH connections)
//   - Memory Limits: Monitors and enforces memory usage limits
//   - File Safety: Validates file operations to prevent data loss
//   - Resource Limits: Prevents runaway processes
//
// # System IP Detection
//
// The Detect functions analyze the system to find critical IPs:
//
//	ips, err := safety.DetectSystemIPs()
//	// Returns: server IPs, gateway IP, DNS servers, active connections
//
// These IPs are automatically added to the whitelist to prevent lockout.
//
// # Memory Protection
//
// Memory limits prevent the watchdog and feeds from consuming excessive RAM:
//
//	if safety.IsMemoryPressureHigh() {
//	    // Trigger garbage collection or reduce operations
//	}
//
// # File Safety
//
// File operations are validated to ensure they target allowed paths:
//
//	if safety.IsPathSafe(filepath) {
//	    // Proceed with write
//	}
package safety
