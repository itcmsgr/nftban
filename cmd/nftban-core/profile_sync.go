package main

import (
	"fmt"
	"log"
	"net/http"
	_ "net/http/pprof"
	"time"

	"github.com/itcmsgr/nftban-v1.0-dev/pkg/blacklist"
	"github.com/itcmsgr/nftban-v1.0-dev/pkg/nftbanconf"
	"github.com/itcmsgr/nftban-v1.0-dev/pkg/sync"
	"github.com/itcmsgr/nftban-v1.0-dev/pkg/whitelist"
)

// getProfileSyncConfigDir returns the config directory from central config
// NO FALLBACK - path must come from /etc/nftban/nftban.conf
func getProfileSyncConfigDir() string {
	cfg := nftbanconf.MustLoad()
	return cfg.ConfigDir
}

func runProfileSync() error {
	// Start pprof HTTP server
	go func() {
		log.Println("🔍 Profiling server starting on :6060")
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

	// Initialize NFT Manager
	log.Println("🔧 Initializing NFT Manager...")
	nft, err := sync.NewNFTManager()
	if err != nil {
		return fmt.Errorf("failed to create NFT manager: %w", err)
	}
	defer nft.Close()

	// Load whitelist
	configDir := getProfileSyncConfigDir()
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

		// NOTE: CIDR merging profiling disabled - implementation reserved for future
		// TODO: Re-enable when CIDR merge implementation is completed

		// Test diff computation
		wl4Diff := sync.ComputeDiff(wl4Slice, []string{})
		wl6Diff := sync.ComputeDiff(wl6Slice, []string{})
		bl4Diff := sync.ComputeDiff(bl4Slice, []string{})
		bl6Diff := sync.ComputeDiff(bl6Slice, []string{})

		duration := time.Since(start)
		totalDuration += duration
		log.Printf("  ✅ Iteration %d/%d completed in %s", i+1, iterations, duration)
		log.Printf("     WL4: +%d -%d | WL6: +%d -%d | BL4: +%d -%d | BL6: +%d -%d",
			len(wl4Diff.ToAdd), len(wl4Diff.ToRemove),
			len(wl6Diff.ToAdd), len(wl6Diff.ToRemove),
			len(bl4Diff.ToAdd), len(bl4Diff.ToRemove),
			len(bl6Diff.ToAdd), len(bl6Diff.ToRemove))

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
