package safety

import (
	"fmt"
	"os"
)

// Preflight runs all safety checks before applying to nftables
// Returns error if any limit is exceeded
func Preflight(v4New, v6New int, hash string, lim Limits) error {
	// Load previous snapshot for delta calculation
	prev, _ := LoadSnapshot(lim.CacheDir)

	totalNew := v4New + v6New
	totalPrev := prev.TotalV4 + prev.TotalV6

	// Calculate adds/deletes
	adds := totalNew - totalPrev
	if adds < 0 {
		adds = 0
	}
	dels := totalPrev - totalNew
	if dels < 0 {
		dels = 0
	}

	// Check 1: Absolute total cap
	if totalNew > lim.MaxPrefixesTotal {
		msg := fmt.Sprintf("❌ REFUSE: total %d prefixes > cap %d", totalNew, lim.MaxPrefixesTotal)
		if lim.Enforce {
			return fmt.Errorf(msg)
		}
		fmt.Fprintln(os.Stderr, "⚠️ ", msg)
	}

	// Check 2: Delta additions cap (protect against sudden huge growth)
	if adds > lim.MaxAddsPerRun {
		msg := fmt.Sprintf("❌ REFUSE: additions %d exceed per-run cap %d (prev=%d new=%d)",
			adds, lim.MaxAddsPerRun, totalPrev, totalNew)
		if lim.Enforce {
			return fmt.Errorf(msg)
		}
		fmt.Fprintln(os.Stderr, "⚠️ ", msg)
	}

	// Check 3: Delta deletions cap (protect against sudden drops)
	if dels > lim.MaxDelsPerRun {
		msg := fmt.Sprintf("❌ REFUSE: deletions %d exceed per-run cap %d (prev=%d new=%d)",
			dels, lim.MaxDelsPerRun, totalPrev, totalNew)
		if lim.Enforce {
			return fmt.Errorf(msg)
		}
		fmt.Fprintln(os.Stderr, "⚠️ ", msg)
	}

	// Check 4: Projected memory bytes
	proj := ProjectBytes(v4New, v6New)
	if proj.Bytes > lim.MaxProjectedBytes {
		msg := fmt.Sprintf("❌ REFUSE: projected %d bytes > cap %d bytes",
			proj.Bytes, lim.MaxProjectedBytes)
		if lim.Enforce {
			return fmt.Errorf(msg)
		}
		fmt.Fprintln(os.Stderr, "⚠️ ", msg)
	}

	// Check 5: Percentage of available memory
	mem := AvailableMem()
	if mem.Avail > 0 {
		pct := int((proj.Bytes * 100) / mem.Avail)
		if pct > lim.MaxPctOfAvail {
			msg := fmt.Sprintf("❌ REFUSE: projected %d bytes would consume ~%d%% of available %d bytes (limit %d%%)",
				proj.Bytes, pct, mem.Avail, lim.MaxPctOfAvail)
			if lim.Enforce {
				return fmt.Errorf(msg)
			}
			fmt.Fprintln(os.Stderr, "⚠️ ", msg)
		}
	}

	// Log preflight summary
	fmt.Printf("🛡️  Preflight passed: %d prefixes (%d v4, %d v6), ~%d MB, delta: +%d/-%d\n",
		totalNew, v4New, v6New, proj.Bytes/(1024*1024), adds, dels)

	return nil
}
