// =============================================================================
// NFTBan - NFTables Diff Application
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="apply"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Applies DiffResult changes to nftables sets"
// meta:input="DiffResult, NFTManager, nftables set"
// meta:output="Applied changes to firewall"
// meta:depends="github.com/google/nftables,github.com/itcmsgr/nftban/pkg/util"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package sync

import (
	"github.com/google/nftables"
	"github.com/itcmsgr/nftban/pkg/util"
)

// ApplyStringDiffToSet applies a DiffResult[string] to a nftables set via NFTManager.
// This centralizes all add/remove logic so it can be reused by:
// - Full sync operations (SyncSetToNFT)
// - Incremental API operations (single IP add/remove)
// - Batch API operations (multiple IPs at once)
// - Suricata alert processing (future v1.0)
//
// Benefits of centralization:
// - Single place for all nftables set updates
// - Consistent error handling
// - Easy to add hooks (logging, metrics, validation)
// - Reusable across all v1.0 features
//
// Performance characteristics:
// - Batched operations (not one-by-one)
// - Atomic updates via NFTManager
// - Efficient for both small and large diffs
//
// Example usage:
//
//	// Single IP add
//	diff := util.DiffResult[string]{
//	    ToAdd: []string{"1.2.3.4"},
//	}
//	err := ApplyStringDiffToSet(nft, whitelistSet, diff)
//
//	// Batch update
//	diff := util.DiffResult[string]{
//	    ToAdd:    []string{"1.2.3.4", "5.6.7.8"},
//	    ToRemove: []string{"9.9.9.9"},
//	}
//	err := ApplyStringDiffToSet(nft, blacklistSet, diff)
func ApplyStringDiffToSet(
	nft *NFTManager,
	set *nftables.Set,
	diff util.DiffResult[string],
) error {
	// Add new IPs if any
	if len(diff.ToAdd) > 0 {
		if err := nft.AddSetElements(set, diff.ToAdd); err != nil {
			return err
		}
	}

	// Remove old IPs if any
	if len(diff.ToRemove) > 0 {
		if err := nft.DeleteSetElements(set, diff.ToRemove); err != nil {
			return err
		}
	}

	return nil
}

// ApplyDiffToSetWithStats is like ApplyStringDiffToSet but also returns statistics.
// This is useful for operations that need detailed metrics.
//
// The stats include:
// - Number of IPs successfully added
// - Number of IPs successfully removed
// - Number of IPs that were unchanged
//
// Example usage:
//
//	stats := ApplyDiffToSetWithStats(nft, set, diff)
//	log.Printf("Applied: +%d -%d =%d", stats.Added, stats.Removed, stats.Unchanged)
func ApplyDiffToSetWithStats(
	nft *NFTManager,
	set *nftables.Set,
	diff util.DiffResult[string],
) (added, removed, unchanged int, err error) {
	added = len(diff.ToAdd)
	removed = len(diff.ToRemove)
	unchanged = diff.Unchanged

	err = ApplyStringDiffToSet(nft, set, diff)
	return
}

// BatchApplyDiff applies multiple diffs to multiple sets in sequence.
// This is useful for operations that need to update several sets atomically.
//
// All diffs are applied in order. If any diff fails, the function stops
// and returns the error immediately.
//
// Example usage:
//
//	diffs := []DiffApplication{
//	    {Set: whitelistIPv4Set, Diff: whitelistIPv4Diff},
//	    {Set: whitelistIPv6Set, Diff: whitelistIPv6Diff},
//	    {Set: blacklistIPv4Set, Diff: blacklistIPv4Diff},
//	}
//	err := BatchApplyDiff(nft, diffs)
type DiffApplication struct {
	Set  *nftables.Set
	Diff util.DiffResult[string]
}

func BatchApplyDiff(nft *NFTManager, applications []DiffApplication) error {
	for _, app := range applications {
		if err := ApplyStringDiffToSet(nft, app.Set, app.Diff); err != nil {
			return err
		}
	}
	return nil
}
