// =============================================================================
// NFTBan - Suricata Integration - SID statistics, info, top, and recent analysis
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_suricata"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="SID statistics, info, top, and recent analysis"
// meta:inventory.files="/var/log/nftban/suricata/eve-alerts.json"
// meta:inventory.binaries="suricata"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/suricata/*.conf"
// meta:inventory.systemd_units="suricata.service"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"text/tabwriter"
	"time"

	"github.com/itcmsgr/nftban/pkg/suricata/stats"
	"github.com/itcmsgr/nftban/pkg/version"
)

// =============================================================================
// SID STATISTICS COMMANDS (PHASE 3)
// =============================================================================

// cmdSuricataSIDStats displays overall SID statistics
func cmdSuricataSIDStats() error {
	fmt.Println(version.BannerWithEmoji("📊", "Suricata SID Statistics"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create cache
	cache, err := stats.NewCache()
	if err != nil {
		return fmt.Errorf("failed to create cache: %w", err)
	}

	fmt.Println("Overall Statistics:")
	fmt.Printf("  Total SIDs:         %d\n", cache.GetUniqueSIDs())
	fmt.Printf("  Total Triggers:     %d\n", cache.GetTotalTriggers())
	fmt.Printf("  Unique Sources:     %d\n", cache.GetUniqueSources())
	fmt.Println()

	fmt.Println("💡 To see detailed statistics:")
	fmt.Println("  Top SIDs:      nftban suricata sid top")
	fmt.Println("  Recent SIDs:   nftban suricata sid recent")
	fmt.Println("  Specific SID:  nftban suricata sid info <SID>")
	fmt.Println()

	return nil
}

// cmdSuricataSIDInfo shows detailed info for a specific SID
func cmdSuricataSIDInfo(sid string) error {
	fmt.Println(version.BannerWithEmoji("🔍", fmt.Sprintf("SID %s Details", sid)))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create cache
	cache, err := stats.NewCache()
	if err != nil {
		return fmt.Errorf("failed to create cache: %w", err)
	}

	// Get SID stats
	sidStats, exists := cache.GetSIDStats(sid)
	if !exists {
		fmt.Printf("⚠️  No statistics found for SID %s\n", sid)
		fmt.Println()
		fmt.Println("This SID has either:")
		fmt.Println("  - Never been triggered")
		fmt.Println("  - Not been processed yet (run collector)")
		fmt.Println()
		return nil
	}

	// Display details
	fmt.Printf("SID:           %s\n", sidStats.SID)
	fmt.Printf("Signature:     %s\n", sidStats.Signature)
	fmt.Printf("Category:      %s\n", sidStats.Category)
	fmt.Println()

	fmt.Printf("Trigger Count: %d\n", sidStats.TriggerCount)
	fmt.Printf("First Trigger: %s\n", sidStats.FirstTrigger.Format(time.RFC3339))
	fmt.Printf("Last Trigger:  %s\n", sidStats.LastTrigger.Format(time.RFC3339))
	fmt.Println()

	fmt.Printf("Unique Sources: %d\n", sidStats.SourceCount)
	if len(sidStats.SourceIPs) > 0 {
		fmt.Println("Top Source IPs:")
		for i, ip := range sidStats.SourceIPs {
			if i >= 10 {
				break
			}
			fmt.Printf("  %d. %s\n", i+1, ip)
		}
	}
	fmt.Println()

	return nil
}

// cmdSuricataSIDTop shows top SIDs by trigger count
func cmdSuricataSIDTop() error {
	fmt.Println(version.BannerWithEmoji("🏆", "Top 20 SIDs by Trigger Count"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create cache
	cache, err := stats.NewCache()
	if err != nil {
		return fmt.Errorf("failed to create cache: %w", err)
	}

	// Get top 20 SIDs
	topSIDs := cache.GetTopSIDs(20)

	if len(topSIDs) == 0 {
		fmt.Println("⚠️  No SID statistics available")
		fmt.Println()
		fmt.Println("Run the stats collector to gather data:")
		fmt.Println("  systemctl start nftban-suricata-stats")
		fmt.Println()
		return nil
	}

	// Display table
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "Rank\tSID\tTriggers\tSources\tCategory\tSignature")
	fmt.Fprintln(w, "----\t---\t--------\t-------\t--------\t---------")

	for i, sidStats := range topSIDs {
		signature := sidStats.Signature
		if len(signature) > 40 {
			signature = signature[:37] + "..."
		}
		fmt.Fprintf(w, "%d\t%s\t%d\t%d\t%s\t%s\n",
			i+1,
			sidStats.SID,
			sidStats.TriggerCount,
			sidStats.SourceCount,
			sidStats.Category,
			signature,
		)
	}
	_ = w.Flush()
	fmt.Println()

	return nil
}

// cmdSuricataSIDRecent shows recently triggered SIDs
func cmdSuricataSIDRecent() error {
	fmt.Println(version.BannerWithEmoji("⏰", "Recently Triggered SIDs (Last 24h)"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create cache
	cache, err := stats.NewCache()
	if err != nil {
		return fmt.Errorf("failed to create cache: %w", err)
	}

	// Get SIDs from last 24 hours
	recentSIDs := cache.GetRecentSIDs(24 * time.Hour)

	if len(recentSIDs) == 0 {
		fmt.Println("⚠️  No recent SID activity in the last 24 hours")
		fmt.Println()
		return nil
	}

	// Display table
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "SID\tLast Trigger\tTriggers\tSources\tSignature")
	fmt.Fprintln(w, "---\t------------\t--------\t-------\t---------")

	for _, sidStats := range recentSIDs {
		if len(recentSIDs) > 20 && sidStats != recentSIDs[len(recentSIDs)-1] {
			continue // Limit to 20 most recent
		}

		signature := sidStats.Signature
		if len(signature) > 40 {
			signature = signature[:37] + "..."
		}

		// Format time as relative (e.g., "5m ago")
		timeAgo := time.Since(sidStats.LastTrigger)
		var timeStr string
		if timeAgo < time.Minute {
			timeStr = fmt.Sprintf("%ds ago", int(timeAgo.Seconds()))
		} else if timeAgo < time.Hour {
			timeStr = fmt.Sprintf("%dm ago", int(timeAgo.Minutes()))
		} else {
			timeStr = fmt.Sprintf("%dh ago", int(timeAgo.Hours()))
		}

		fmt.Fprintf(w, "%s\t%s\t%d\t%d\t%s\n",
			sidStats.SID,
			timeStr,
			sidStats.TriggerCount,
			sidStats.SourceCount,
			signature,
		)
	}
	_ = w.Flush()
	fmt.Println()

	return nil
}

// cmdSuricataStatsDaemon runs the statistics collector daemon
func cmdSuricataStatsDaemon() error {
	fmt.Println(version.BannerWithEmoji("📊", "Suricata Statistics Collector"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Initialize Prometheus metrics
	fmt.Println("→ Initializing Prometheus metrics...")
	stats.InitMetrics()
	fmt.Println("✓ Metrics initialized")
	fmt.Println()

	// Create cache and load existing snapshot
	fmt.Println("→ Loading SID statistics cache...")
	cache, err := stats.NewCache()
	if err != nil {
		return fmt.Errorf("failed to create cache: %w", err)
	}
	fmt.Printf("✓ Cache loaded (%d SIDs)\n", cache.GetSize())
	fmt.Println()

	// Create collector
	fmt.Println("→ Creating eve.json collector...")
	collector, err := stats.NewCollector(cache)
	if err != nil {
		return fmt.Errorf("failed to create collector: %w", err)
	}
	fmt.Println("✓ Collector created")
	fmt.Println()

	// Start auto-save (every 5 minutes)
	fmt.Println("→ Starting auto-save timer (5 minute interval)...")
	cache.StartAutoSave(5 * time.Minute)
	fmt.Println("✓ Auto-save enabled")
	fmt.Println()

	// Start collector
	fmt.Println("→ Starting eve.json collector daemon...")
	if err := collector.Start(); err != nil {
		return fmt.Errorf("failed to start collector: %w", err)
	}
	fmt.Println("✓ Collector started")
	fmt.Println()

	fmt.Println("╔══════════════════════════════════════════════════════════════╗")
	fmt.Println("║  📊 Statistics Collector Running                             ║")
	fmt.Println("╚══════════════════════════════════════════════════════════════╝")
	fmt.Println()
	fmt.Println("Monitoring:  /var/log/nftban/suricata/eve-alerts.json")
	fmt.Println("Cache:       /etc/nftban/suricata/cache/sid-stats.json")
	fmt.Println("Auto-save:   Every 5 minutes")
	fmt.Println()
	fmt.Println("Press Ctrl+C to stop gracefully")
	fmt.Println()

	// Setup signal handling for graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	// Wait for signal
	sig := <-sigChan
	fmt.Printf("\n→ Received signal %v, shutting down gracefully...\n", sig)

	// Stop collector
	collector.Stop()
	fmt.Println("✓ Collector stopped")

	// Save final snapshot
	fmt.Println("→ Saving final cache snapshot...")
	if err := cache.Save(); err != nil {
		log.Printf("⚠️  Failed to save cache: %v\n", err)
	} else {
		fmt.Println("✓ Cache saved successfully")
	}

	fmt.Println()
	fmt.Println("✅ Shutdown complete")
	fmt.Println()

	return nil
}
