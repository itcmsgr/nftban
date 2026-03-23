// =============================================================================
// NFTBan - Set Diff Computation
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="diff"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Computes diffs between desired and current nftables sets"
// meta:input="Source sets, current nftables elements"
// meta:output="DiffResult with adds and removes"
// meta:depends="github.com/google/nftables,github.com/itcmsgr/nftban/internal/util"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package setsync

import (
	"fmt"
	"time"

	"github.com/google/nftables"
	"github.com/itcmsgr/nftban/internal/util"
)

// DiffResult is a type alias for the generic util.DiffResult[string]
// This maintains backwards compatibility while using the optimized generic implementation
type DiffResult = util.DiffResult[string]

// ComputeDiff compares desired state with current nftables state
// Returns IPs that need to be added or removed
//
// This now uses the optimized generic diff engine from internal/util
// Benefits:
// - Preallocated maps (no resizing)
// - Zero allocations for struct{} map values
// - Same algorithm, better performance
func ComputeDiff(desiredIPs []string, currentIPs []string) *DiffResult {
	diff := util.ComputeDiff[string](desiredIPs, currentIPs)
	return &diff
}

// SyncStats holds statistics about a sync operation
type SyncStats struct {
	SetName       string
	IPsAdded      int
	IPsRemoved    int
	IPsUnchanged  int
	TotalDesired  int
	TotalCurrent  int
	Duration      time.Duration
	Error         error
}

// SyncSetToNFT performs differential sync of a set
// Only adds/removes IPs that have changed
func SyncSetToNFT(nft *NFTManager, set *nftables.Set, desiredIPs []string) (*SyncStats, error) {
	startTime := time.Now()

	stats := &SyncStats{
		SetName:      set.Name,
		TotalDesired: len(desiredIPs),
	}

	// Get current IPs in nftables set
	currentIPs, err := nft.GetSetElements(set)
	if err != nil {
		stats.Error = fmt.Errorf("failed to get current elements: %w", err)
		stats.Duration = time.Since(startTime)
		return stats, stats.Error
	}

	stats.TotalCurrent = len(currentIPs)

	// Compute diff
	diff := ComputeDiff(desiredIPs, currentIPs)
	stats.IPsAdded = len(diff.ToAdd)
	stats.IPsRemoved = len(diff.ToRemove)
	stats.IPsUnchanged = diff.Unchanged

	// Apply diff using centralized ApplyDiff layer
	// This ensures all nftables updates go through a single code path
	if err := ApplyStringDiffToSet(nft, set, *diff); err != nil {
		stats.Error = fmt.Errorf("failed to apply diff: %w", err)
		stats.Duration = time.Since(startTime)
		return stats, stats.Error
	}

	stats.Duration = time.Since(startTime)
	return stats, nil
}

// SyncResult holds results of syncing multiple sets
type SyncResult struct {
	WhitelistIPv4 *SyncStats
	WhitelistIPv6 *SyncStats
	BlacklistIPv4 *SyncStats
	BlacklistIPv6 *SyncStats
	TotalDuration time.Duration
	Success       bool
}

// FullSync performs a complete sync of all whitelist/blacklist sets
func FullSync(
	nft *NFTManager,
	whitelistIPv4Set, whitelistIPv6Set *nftables.Set,
	blacklistIPv4Set, blacklistIPv6Set *nftables.Set,
	whitelistIPv4, whitelistIPv6 []string,
	blacklistIPv4, blacklistIPv6 []string,
) (*SyncResult, error) {
	startTime := time.Now()
	result := &SyncResult{Success: true}

	// Sync whitelist IPv4
	if whitelistIPv4Set != nil {
		stats, err := SyncSetToNFT(nft, whitelistIPv4Set, whitelistIPv4)
		result.WhitelistIPv4 = stats
		if err != nil {
			result.Success = false
			return result, fmt.Errorf("whitelist IPv4 sync failed: %w", err)
		}
	}

	// Sync whitelist IPv6
	if whitelistIPv6Set != nil {
		stats, err := SyncSetToNFT(nft, whitelistIPv6Set, whitelistIPv6)
		result.WhitelistIPv6 = stats
		if err != nil {
			result.Success = false
			return result, fmt.Errorf("whitelist IPv6 sync failed: %w", err)
		}
	}

	// Sync blacklist IPv4
	if blacklistIPv4Set != nil {
		stats, err := SyncSetToNFT(nft, blacklistIPv4Set, blacklistIPv4)
		result.BlacklistIPv4 = stats
		if err != nil {
			result.Success = false
			return result, fmt.Errorf("blacklist IPv4 sync failed: %w", err)
		}
	}

	// Sync blacklist IPv6
	if blacklistIPv6Set != nil {
		stats, err := SyncSetToNFT(nft, blacklistIPv6Set, blacklistIPv6)
		result.BlacklistIPv6 = stats
		if err != nil {
			result.Success = false
			return result, fmt.Errorf("blacklist IPv6 sync failed: %w", err)
		}
	}

	result.TotalDuration = time.Since(startTime)
	return result, nil
}

// PrintSyncStats prints sync statistics in a readable format
func PrintSyncStats(stats *SyncStats) {
	if stats == nil {
		return
	}

	fmt.Printf("  Set: %s\n", stats.SetName)
	fmt.Printf("    Added:     %d IPs\n", stats.IPsAdded)
	fmt.Printf("    Removed:   %d IPs\n", stats.IPsRemoved)
	fmt.Printf("    Unchanged: %d IPs\n", stats.IPsUnchanged)
	fmt.Printf("    Current:   %d → %d IPs\n", stats.TotalCurrent, stats.TotalDesired)
	fmt.Printf("    Duration:  %v\n", stats.Duration)
	if stats.Error != nil {
		fmt.Printf("    Error:     %v\n", stats.Error)
	}
}

// PrintSyncResult prints a complete sync result
func PrintSyncResult(result *SyncResult) {
	fmt.Println("\n📊 Sync Results:")
	fmt.Println("================")

	if result.WhitelistIPv4 != nil {
		fmt.Println("\nWhitelist IPv4:")
		PrintSyncStats(result.WhitelistIPv4)
	}

	if result.WhitelistIPv6 != nil {
		fmt.Println("\nWhitelist IPv6:")
		PrintSyncStats(result.WhitelistIPv6)
	}

	if result.BlacklistIPv4 != nil {
		fmt.Println("\nBlacklist IPv4:")
		PrintSyncStats(result.BlacklistIPv4)
	}

	if result.BlacklistIPv6 != nil {
		fmt.Println("\nBlacklist IPv6:")
		PrintSyncStats(result.BlacklistIPv6)
	}

	fmt.Printf("\nTotal Duration: %v\n", result.TotalDuration)
	if result.Success {
		fmt.Println("✅ Sync completed successfully!")
	} else {
		fmt.Println("❌ Sync failed!")
	}
}

// IsFastSync checks if a sync operation is "fast" (few changes)
// This can be used for metrics/alerting
func IsFastSync(stats *SyncStats, threshold int) bool {
	return (stats.IPsAdded + stats.IPsRemoved) <= threshold
}

// GetSyncEfficiency returns the percentage of IPs that were already in sync
func GetSyncEfficiency(stats *SyncStats) float64 {
	total := stats.IPsAdded + stats.IPsRemoved + stats.IPsUnchanged
	if total == 0 {
		return 100.0
	}
	return float64(stats.IPsUnchanged) / float64(total) * 100.0
}
