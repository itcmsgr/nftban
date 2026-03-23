// =============================================================================
// NFTBan v1.0 - Feeds Package
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="doc"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-21"
// meta:description="Package documentation for NFTBan threat intelligence feeds"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package feeds handles threat intelligence feed processing for NFTBan.
//
// # Overview
//
// The feeds package downloads, parses, and manages IP blocklists from
// various threat intelligence sources. It supports multiple feed formats
// and provides deduplication and validation.
//
// # Supported Feed Types
//
//   - Plain text (one IP/CIDR per line)
//   - JSON arrays
//   - CSV with IP column
//   - Compressed feeds (gzip)
//
// # Feed Sources
//
// Common sources include:
//   - Spamhaus DROP/EDROP
//   - AbuseIPDB
//   - Firehol blocklists
//   - Custom enterprise feeds
//
// # Processing Pipeline
//
//  1. Download feed from URL
//  2. Decompress if needed
//  3. Parse based on format
//  4. Validate IPs/CIDRs
//  5. Deduplicate entries
//  6. Sync to nftables via IPC
//
// # Configuration
//
// Feeds are configured in /etc/nftban/feeds.d/*.conf with settings for
// URL, update interval, format, and enabled status.
//
// # Usage
//
// Feed processing is typically triggered by the nftban-core-feeds timer:
//
//	feeds.SyncAll()  // Update all enabled feeds
//	feeds.Sync("spamhaus")  // Update specific feed
package feeds
