// =============================================================================
// NFTBan v1.1 - OpQueue Package (Async IPC Architecture)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="opqueue"
// meta:type="package"
// meta:version="1.1.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Async operation queue with coalescing for nftables operations"
//
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
//
// ARCHITECTURE:
//
// This package implements the v1.1 Async IPC Architecture:
//
// 1. SINGLE WRITER: Go daemon is the ONLY writer to nftables via netlink
// 2. ASYNC IPC: All ban/unban/replace operations are queued, immediate response
// 3. COALESCING: Per-set buffers with TTL=max policy for adds
// 4. BARRIER SEMANTICS: flush/replace creates generation boundary
// 5. SOURCE TRACKING: SourceIndex persisted for shared sets
//
// Key Components:
// - OpQueue: Main queue manager with per-set buffers
// - SetBuffer: Per-set coalescing buffer with barrier support
// - SourceIndex: Tracks element ownership for flush_source
// - SecureFileReader: Safe file ingestion for replace_set
//
// IPC Methods Supported:
// - ban/unban: Single element add/delete with TTL=max coalescing
// - replace_set: Atomic bulk replacement (file-based)
// - flush_set: Clear entire set (barrier)
// - flush_source: Remove all elements from a source
//
// See: ARCHITECTURE-NFT-POLICY.md
// =============================================================================

package opqueue
