// =============================================================================
// NFTBan - Profile Sync for Performance Testing
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="profile_sync"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Run sync operations with pprof profiling for performance analysis"
// meta:input="None"
// meta:output="Profiling data on localhost:6060"
// meta:depends="github.com/itcmsgr/nftban/internal/blacklist,github.com/itcmsgr/nftban/internal/whitelist,github.com/itcmsgr/nftban/internal/nftbanconf"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network="http:6060"
// meta:inventory.privileges="none"
// =============================================================================

package main

import (
	"fmt"
	"log"
	"net/http"
	_ "net/http/pprof"
	"time"

	"github.com/itcmsgr/nftban/internal/blacklist"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/internal/whitelist"
)

// getProfileSyncConfigDir returns the config directory from passed config
func getProfileSyncConfigDir(cfg *nftbanconf.Config) string {
	return cfg.ConfigDir
}

func runProfileSync(cfg *nftbanconf.Config) error {
	// Start pprof HTTP server (localhost only for security)
	go func() {
		log.Println("WARNING: pprof profiling enabled - for debugging only")
		log.Println("Profiling server starting on localhost:6060")
		log.Println("")
		log.Println("Access profiling data:")
		log.Println("  CPU Profile:    go tool pprof http://localhost:6060/debug/pprof/profile?seconds=30")
		log.Println("  Heap Profile:   go tool pprof http://localhost:6060/debug/pprof/heap")
		log.Println("  Allocs Profile: go tool pprof http://localhost:6060/debug/pprof/allocs")
		log.Println("  Goroutines:     go tool pprof http://localhost:6060/debug/pprof/goroutine")
		log.Println("")
		log.Println("Interactive pprof commands:")
		log.Println("  top20          - Show top 20 CPU/memory consumers")
		log.Println("  list FuncName  - Show annotated source code")
		log.Println("  web            - Generate call graph (requires graphviz)")
		log.Println("  png            - Save call graph as PNG")
		log.Println("")
		if err := http.ListenAndServe("localhost:6060", nil); err != nil {
			log.Printf("pprof server error: %v", err)
		}
	}()

	// Small delay to ensure pprof server is ready
	time.Sleep(100 * time.Millisecond)

	// Load whitelist
	configDir := getProfileSyncConfigDir(cfg)
	log.Println("📥 Loading whitelist...")
	whitelistIPv4, whitelistIPv6, err := whitelist.LoadAllWhitelists(configDir)
	if err != nil {
		return fmt.Errorf("failed to load whitelist: %w", err)
	}
	log.Printf("  ✅ Loaded %d IPv4 + %d IPv6 whitelist entries", len(whitelistIPv4), len(whitelistIPv6))

	// Load blacklist
	log.Println("📥 Loading blacklist...")
	blacklistIPv4, blacklistIPv6, err := blacklist.LoadAllBlacklists(configDir)
	if err != nil {
		return fmt.Errorf("failed to load blacklist: %w", err)
	}
	log.Printf("  ✅ Loaded %d IPv4 + %d IPv6 blacklist entries", len(blacklistIPv4), len(blacklistIPv6))

	// Convert maps to slices for processing
	wl4Slice := mapKeysToSlice(whitelistIPv4)
	wl6Slice := mapKeysToSlice(whitelistIPv6)
	bl4Slice := mapKeysToSlice(blacklistIPv4)
	bl6Slice := mapKeysToSlice(blacklistIPv6)

	// Run sync operations multiple times to generate profile data
	log.Println("")
	log.Println("🔄 Running sync operations for profiling...")
	log.Println("   (5 iterations to generate meaningful profile data)")
	log.Println("")

	var totalDuration time.Duration
	iterations := 5

	for i := 0; i < iterations; i++ {
		start := time.Now()
		log.Printf("  📊 Iteration %d/%d starting...", i+1, iterations)

		// Simulate diff computation by comparing sets
		// This profiles the set comparison logic without netlink
		wl4Add := computeSimpleDiff(wl4Slice, []string{})
		wl6Add := computeSimpleDiff(wl6Slice, []string{})
		bl4Add := computeSimpleDiff(bl4Slice, []string{})
		bl6Add := computeSimpleDiff(bl6Slice, []string{})

		duration := time.Since(start)
		totalDuration += duration
		log.Printf("  ✅ Iteration %d/%d completed in %s", i+1, iterations, duration)
		log.Printf("     WL4: +%d | WL6: +%d | BL4: +%d | BL6: +%d",
			len(wl4Add), len(wl6Add), len(bl4Add), len(bl6Add))

		// Small delay between iterations
		time.Sleep(100 * time.Millisecond)
	}

	avgDuration := totalDuration / time.Duration(iterations)
	log.Println("")
	log.Println("📊 Performance Summary:")
	log.Printf("  Total time:   %s", totalDuration)
	log.Printf("  Average/sync: %s", avgDuration)
	log.Printf("  Iterations:   %d", iterations)
	log.Println("")
	log.Println("🔍 Profiling data ready!")
	log.Println("   Press Ctrl+C to exit (or leave running to capture more data)")
	log.Println("")

	// Keep server alive for profiling
	select {}
}

// mapKeysToSlice converts a map[string]bool to []string
func mapKeysToSlice(m map[string]bool) []string {
	result := make([]string, 0, len(m))
	for k := range m {
		result = append(result, k)
	}
	return result
}

// computeSimpleDiff computes elements to add (in desired but not in current)
func computeSimpleDiff(desired, current []string) []string {
	currentSet := make(map[string]bool, len(current))
	for _, item := range current {
		currentSet[item] = true
	}

	var toAdd []string
	for _, item := range desired {
		if !currentSet[item] {
			toAdd = append(toAdd, item)
		}
	}
	return toAdd
}
