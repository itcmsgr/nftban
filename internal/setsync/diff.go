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
	"github.com/itcmsgr/nftban/internal/netutil"
	"github.com/itcmsgr/nftban/internal/util"
)

// computeWhitelistRangeDiff produces a RANGE-AWARE add/remove plan for the
// whitelist interval set (WHITELIST_DURABLE_APPLY_RECONCILE Step 4). Unlike the
// string ComputeDiff: a desired CIDR COVERED by an existing kernel interval is
// "unchanged" (not re-added), and a kernel interval covered by the desired set is
// "unchanged" (not removed) — so a stable Cloudflare/trust config yields 0 churn.
// currentRanges MUST come from GetSetElementsRanges (range-preserving). Unparseable
// desired tokens fall back to exact membership so nothing is silently dropped.
func computeWhitelistRangeDiff(desiredIPs, currentRanges []string) *DiffResult {
	res := netutil.CoverageDiff(desiredIPs, currentRanges, nil)
	d := &DiffResult{ToAdd: make([]string, 0), ToRemove: make([]string, 0)}
	d.ToAdd = append(d.ToAdd, res.MissingFromKernel...)
	d.ToRemove = append(d.ToRemove, res.ExtraInKernel...)
	if len(res.BadBaseline) > 0 {
		cur := make(map[string]struct{}, len(currentRanges))
		for _, c := range currentRanges {
			cur[c] = struct{}{}
		}
		for _, b := range res.BadBaseline {
			if _, ok := cur[b]; !ok {
				d.ToAdd = append(d.ToAdd, b)
			}
		}
	}
	d.Unchanged = len(desiredIPs) - len(d.ToAdd)
	if d.Unchanged < 0 {
		d.Unchanged = 0
	}
	return d
}

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

// remainingTimeout computes the kernel timeout to apply to a whitelist element
// given its absolute expiry. It returns (0, false) for permanent entries — no
// expiry recorded (durable/trust) — and (expiry−now, true) for timed entries.
//
// The duration is anchored to the ABSOLUTE expiry instant and recomputed on
// every sync, so a re-sync/rebuild REFRESHES the remaining TTL instead of
// clobbering the element to permanent. This is the CLI-BUG-2 (v1.168) core
// invariant: a timed whitelist must keep a (shrinking) kernel timeout across
// FullSync, never silently become permanent. A non-positive result means the
// entry is already past — the caller skips it (the loader normally drops past
// entries first; this is defense-in-depth against the load→sync race window).
func remainingTimeout(expiry map[string]time.Time, ip string, now time.Time) (time.Duration, bool) {
	if expiry == nil {
		return 0, false
	}
	exp, ok := expiry[ip]
	if !ok || exp.IsZero() {
		return 0, false // permanent
	}
	return exp.Sub(now), true // timed (may be <= 0 if already past)
}

// SyncWhitelistSetToNFT performs a differential sync of a whitelist set,
// applying a per-element kernel timeout to entries that carry an absolute
// expiry (CLI-BUG-2, v1.168). Permanent entries (no expiry) are added in a
// single batch exactly as before; timed entries are added individually with
// AddIPWithTimeout(remaining). Removals are unchanged.
//
// Only newly-added elements (diff.ToAdd) receive a timeout. Elements already
// present in the kernel are left untouched so their existing countdown
// continues toward the absolute expiry; when the set is flushed/rebuilt they
// re-enter ToAdd and the remaining TTL is recomputed. Either way a timed
// entry never reverts to permanent.
func SyncWhitelistSetToNFT(nft *NFTManager, set *nftables.Set, desiredIPs []string, expiry map[string]time.Time) (*SyncStats, error) {
	startTime := time.Now()

	stats := &SyncStats{
		SetName:      set.Name,
		TotalDesired: len(desiredIPs),
	}

	// Range-preserving read: the whitelist set is an auto-merge INTERVAL set, so
	// GetSetElements would return only interval starts as bare IPs (losing the
	// range) → a string diff would churn CIDR<->interval forever. Use the
	// range-aware reader + diff instead (compare COVERAGE, not text).
	currentRanges, err := nft.GetSetElementsRanges(set)
	if err != nil {
		stats.Error = fmt.Errorf("failed to get current elements: %w", err)
		stats.Duration = time.Since(startTime)
		return stats, stats.Error
	}
	stats.TotalCurrent = len(currentRanges)

	diff := computeWhitelistRangeDiff(desiredIPs, currentRanges)
	stats.IPsAdded = len(diff.ToAdd)
	stats.IPsRemoved = len(diff.ToRemove)
	stats.IPsUnchanged = diff.Unchanged

	now := time.Now().UTC()
	permanent := make([]string, 0, len(diff.ToAdd))
	for _, ip := range diff.ToAdd {
		d, timed := remainingTimeout(expiry, ip, now)
		if !timed {
			permanent = append(permanent, ip)
			continue
		}
		if d <= 0 {
			// Expired in the load→sync window — skip; the loader will drop
			// it on the next reload.
			continue
		}
		if err := nft.AddIPWithTimeout(set, ip, d); err != nil {
			stats.Error = fmt.Errorf("failed to add timed element %s: %w", ip, err)
			stats.Duration = time.Since(startTime)
			return stats, stats.Error
		}
	}
	if len(permanent) > 0 {
		if err := nft.AddSetElements(set, permanent); err != nil {
			stats.Error = fmt.Errorf("failed to add permanent elements: %w", err)
			stats.Duration = time.Since(startTime)
			return stats, stats.Error
		}
	}
	if len(diff.ToRemove) > 0 {
		if err := nft.DeleteSetElements(set, diff.ToRemove); err != nil {
			stats.Error = fmt.Errorf("failed to remove elements: %w", err)
			stats.Duration = time.Since(startTime)
			return stats, stats.Error
		}
	}

	// Post-apply durable-coverage verification: every PERMANENT desired entry must
	// now be covered by the live set. If any is still absent the reconcile silently
	// failed (the srv3 symptom) — fail LOUD instead of reporting success.
	permanentDesired := make([]string, 0, len(desiredIPs))
	for _, ip := range desiredIPs {
		if _, timed := remainingTimeout(expiry, ip, now); !timed {
			permanentDesired = append(permanentDesired, ip)
		}
	}
	if len(permanentDesired) > 0 {
		if after, rerr := nft.GetSetElementsRanges(set); rerr == nil {
			if v := netutil.CoverageDiff(permanentDesired, after, nil); len(v.MissingFromKernel) > 0 {
				stats.Error = fmt.Errorf("durable whitelist entries NOT live after sync (reconcile failed): %v", v.MissingFromKernel)
				stats.Duration = time.Since(startTime)
				return stats, stats.Error
			}
		}
	}

	stats.Duration = time.Since(startTime)
	return stats, nil
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

// FullSync performs a complete sync of all whitelist/blacklist sets.
//
// whitelistExpiry maps ip → absolute expiry for timed whitelist entries
// (CLI-BUG-2, v1.168); pass nil/empty to treat every whitelist element as
// permanent (the pre-v1.168 behavior). Blacklist sync is unchanged.
func FullSync(
	nft *NFTManager,
	whitelistIPv4Set, whitelistIPv6Set *nftables.Set,
	blacklistIPv4Set, blacklistIPv6Set *nftables.Set,
	whitelistIPv4, whitelistIPv6 []string,
	blacklistIPv4, blacklistIPv6 []string,
	whitelistExpiry map[string]time.Time,
) (*SyncResult, error) {
	startTime := time.Now()
	result := &SyncResult{Success: true}

	// Sync whitelist IPv4 (timeout-aware: timed entries get a kernel timeout)
	if whitelistIPv4Set != nil {
		stats, err := SyncWhitelistSetToNFT(nft, whitelistIPv4Set, whitelistIPv4, whitelistExpiry)
		result.WhitelistIPv4 = stats
		if err != nil {
			result.Success = false
			return result, fmt.Errorf("whitelist IPv4 sync failed: %w", err)
		}
	}

	// Sync whitelist IPv6 (timeout-aware)
	if whitelistIPv6Set != nil {
		stats, err := SyncWhitelistSetToNFT(nft, whitelistIPv6Set, whitelistIPv6, whitelistExpiry)
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
