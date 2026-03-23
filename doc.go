// =============================================================================
// NFTBan v1.0 - Root Package Documentation
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="doc"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-23"
// meta:description="Root package documentation for NFTBan module"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package nftban is a system-level nftables IPS firewall.
//
// NFTBan is a production firewall product consisting of a daemon (nftband),
// CLI engine (nftban-core), and shell framework. It is NOT a general-purpose
// Go library or embeddable SDK.
//
// # For Go Developers
//
// If you want to interact with a running NFTBan daemon from Go code,
// use the IPC client package:
//
//	import "github.com/itcmsgr/nftban/pkg/ipc"
//
//	client := ipc.NewClient()
//	resp, err := client.Ban("192.168.1.100", 0, "reason", "source")
//
// All other packages are internal implementation details and should not be
// imported directly. They may change without notice between releases.
//
// # Product Documentation
//
// For installation, configuration, and usage documentation, visit:
// https://github.com/itcmsgr/nftban/wiki
package nftban
