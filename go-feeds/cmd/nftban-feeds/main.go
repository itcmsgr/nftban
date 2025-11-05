package main

import (
	"context"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/go-feeds/internal/fetcher"
	"github.com/itcmsgr/nftban/go-feeds/internal/nftloader"
	"github.com/itcmsgr/nftban/go-feeds/internal/parser"
	"github.com/itcmsgr/nftban/go-feeds/internal/safety"
)

func main() {
	// Initialize CPU/memory safety limits
	limits := safety.FromEnv()
	safety.InitCPU(limits)

	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	switch os.Args[1] {
	case "sync":
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "Usage: nftban-feeds sync <feed1,feed2,...>")
			os.Exit(1)
		}
		feedList := strings.Split(os.Args[2], ",")
		if err := syncFeeds(feedList, limits); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
	case "parse":
		fmt.Fprintln(os.Stderr, "Parse command not yet implemented")
		os.Exit(1)
	case "validate":
		fmt.Fprintln(os.Stderr, "Validate command not yet implemented")
		os.Exit(1)
	case "deduplicate":
		fmt.Fprintln(os.Stderr, "Deduplicate command not yet implemented")
		os.Exit(1)
	case "stats":
		fmt.Fprintln(os.Stderr, "Stats command not yet implemented")
		os.Exit(1)
	default:
		usage()
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprintf(os.Stderr, `NFTBan Feeds Manager v0.31.0

Usage:
  nftban-feeds sync <feed1,feed2,...>    Fetch and load feeds into nftables
  nftban-feeds parse                      Parse feed content (TODO)
  nftban-feeds validate                   Validate feed URLs (TODO)
  nftban-feeds deduplicate                Deduplicate IPs (TODO)
  nftban-feeds stats                      Show feed statistics (TODO)

Examples:
  nftban-feeds sync greensnow
  nftban-feeds sync greensnow,spamhaus-drop,cloudflare

`)
}

// syncFeeds fetches, parses, and loads feeds atomically
func syncFeeds(feedNames []string, limits safety.Limits) error {
	startTime := time.Now()

	// 1. Define feed URLs (TODO: load from /etc/nftban/feeds.conf in future)
	allFeeds := map[string]string{
		"greensnow":      "https://blocklist.greensnow.co/greensnow.txt",
		"cloudflare":     "https://www.cloudflare.com/ips-v4",
		"spamhaus-drop":  "https://www.spamhaus.org/drop/drop.txt",
		"spamhaus-edrop": "https://www.spamhaus.org/drop/edrop.txt",
		"abuse-ch-feodo": "https://feodotracker.abuse.ch/downloads/ipblocklist.txt",
		"blocklist-de":   "https://lists.blocklist.de/lists/all.txt",
		// Add more feeds as needed
	}

	// Filter to requested feeds only
	urls := make(map[string]string)
	for _, name := range feedNames {
		if url, ok := allFeeds[name]; ok {
			urls[name] = url
		} else {
			fmt.Fprintf(os.Stderr, "Warning: unknown feed '%s', skipping\n", name)
		}
	}

	if len(urls) == 0 {
		return fmt.Errorf("no valid feeds specified")
	}

	fmt.Printf("Fetching %d feeds (with ETag cache)...\n", len(urls))

	// 2. Fetch feeds concurrently with caching (30s global timeout)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Use worker limit from safety config
	maxWorkers := safety.WorkerLimit(8, limits)
	results, anyChanged := fetcher.FetchFeedsWithCache(ctx, urls, maxWorkers)
	fetchTime := time.Since(startTime)

	// 3. Parse and deduplicate
	parseStart := time.Now()
	var allPrefixes []netip.Prefix
	successCount := 0
	for _, result := range results {
		if result.Err != nil {
			fmt.Fprintf(os.Stderr, "Warning: %s failed: %v\n", result.Name, result.Err)
			continue
		}

		prefixes, err := parser.ParseIPs(result.Content)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Warning: %s parse error: %v\n", result.Name, err)
			continue
		}

		fmt.Printf("  %s: %d IPs parsed\n", result.Name, len(prefixes))
		allPrefixes = append(allPrefixes, prefixes...)
		successCount++
	}

	if successCount == 0 {
		return fmt.Errorf("all feeds failed to download or parse")
	}

	fmt.Printf("\nDeduplicating and merging CIDRs...\n")
	allPrefixes = parser.MergeCIDRs(allPrefixes)

	v4, v6 := parser.SplitIPv4v6(allPrefixes)
	fmt.Printf("Total unique: %d IPv4, %d IPv6\n", len(v4), len(v6))
	parseTime := time.Since(parseStart)

	// 4. Check if merged content hash changed (skip reload if same)
	currentHash := parser.HashPrefixes(allPrefixes)
	hashFile := filepath.Join(fetcher.CacheDir, "merged.sha256")

	if cachedHash, err := os.ReadFile(hashFile); err == nil {
		if parser.CompareHashes(currentHash, strings.TrimSpace(string(cachedHash))) {
			fmt.Printf("\n⏭️  No changes in merged feeds (hash match). Skipping nftables reload.\n")
			fmt.Printf("📊 Stats: fetch=%.2fs, parse=%.2fs, total=%.2fs\n",
				fetchTime.Seconds(), parseTime.Seconds(), time.Since(startTime).Seconds())
			return nil
		}
	}

	if !anyChanged {
		fmt.Printf("ℹ️  Feeds unchanged (ETag), but proceeding to verify nftables state.\n")
	}

	// 5. Run preflight safety checks (CPU/RAM protection)
	fmt.Printf("\n🛡️  Running preflight safety checks...\n")
	if err := safety.Preflight(len(v4), len(v6), currentHash, limits); err != nil {
		return fmt.Errorf("preflight check failed: %w", err)
	}

	// 6. Load atomically into nftables
	fmt.Printf("\nLoading into nftables atomically...\n")
	loadStart := time.Now()

	if len(v4) > 0 {
		fmt.Printf("  Loading %d IPv4 prefixes...", len(v4))
		if err := nftloader.LoadIPv4(v4); err != nil {
			return fmt.Errorf("load IPv4: %w", err)
		}
		fmt.Println(" ✅")
	}

	if len(v6) > 0 {
		fmt.Printf("  Loading %d IPv6 prefixes...", len(v6))
		if err := nftloader.LoadIPv6(v6); err != nil {
			return fmt.Errorf("load IPv6: %w", err)
		}
		fmt.Println(" ✅")
	}

	loadTime := time.Since(loadStart)

	// Save hash and snapshot for next run
	_ = os.MkdirAll(fetcher.CacheDir, 0755)
	_ = os.WriteFile(hashFile, []byte(currentHash), 0644)

	// Save snapshot for delta tracking
	snapshot := safety.Snapshot{
		TotalV4: len(v4),
		TotalV6: len(v6),
		Hash:    currentHash,
	}
	if err := safety.SaveSnapshot(limits.CacheDir, snapshot); err != nil {
		fmt.Fprintf(os.Stderr, "⚠️  Warning: failed to save snapshot: %v\n", err)
	}

	totalTime := time.Since(startTime)
	fmt.Printf("\n✅ Feeds loaded atomically\n")
	fmt.Printf("📊 Performance: fetch=%.2fs, parse=%.2fs, load=%.2fs, total=%.2fs\n",
		fetchTime.Seconds(), parseTime.Seconds(), loadTime.Seconds(), totalTime.Seconds())

	return nil
}
