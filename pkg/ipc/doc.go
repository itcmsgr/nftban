// =============================================================================
// NFTBan v1.0 - IPC Package
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="doc"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-21"
// meta:description="Package documentation for NFTBan IPC client"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package ipc provides inter-process communication for the NFTBan daemon architecture.
//
// This is a supported public package in the NFTBan module. It is the recommended
// integration point for Go programs that need to communicate with a running
// NFTBan daemon. All other NFTBan packages are internal implementation details.
//
// NFTBan uses a single-writer architecture where all nftables write operations
// must go through the nftband daemon. This package provides the client-side IPC
// mechanism for communicating with the daemon over a Unix socket.
//
// # Architecture
//
// The IPC client connects to nftband daemon at /run/nftban/nftband.sock and
// sends JSON-encoded requests for operations like:
//   - Ban/Unban IP addresses
//   - Sync feeds and geoban sets
//   - Manage whitelist entries
//
// # Usage
//
//	client := ipc.NewClient()
//	resp, err := client.Send(ipc.Request{
//	    Command: "ban",
//	    Args:    []string{"192.168.1.100"},
//	})
//
// # Thread Safety
//
// The Client type is safe for concurrent use. Each Send() call creates a new
// connection to the daemon socket.
//
// See also: cmd/nftband for the daemon implementation.
package ipc
