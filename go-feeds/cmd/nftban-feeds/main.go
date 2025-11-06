package main

import (
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"time"

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
		if err := parseFeeds(); err != nil {
			fmt.Fprintf(os.Stderr, "Error: %v\n", err)
			os.Exit(1)
		}
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
	fmt.Fprintf(os.Stderr, `NFTBan Feeds Manager v0.32.3

Architecture: Bash downloads feeds, Go parses and loads to nftables (fast, atomic)

Usage:
  nftban-feeds parse                      Parse feed from stdin, output valid IPs
  nftban-feeds sync <feed1,feed2,...>     Load pre-downloaded feeds to nftables

Commands:
  parse  - Read feed data from stdin, parse IPs, output to stdout (used by bash wrapper)
  sync   - Load pre-downloaded feeds from disk to nftables atomically

Notes:
  • Feeds must be downloaded first: nftban feeds update
  • Feed files location: /var/lib/nftban/feeds/*.txt
  • parse command reads from stdin and outputs valid IPs (one per line)
  • sync command loads from disk (single source of truth)

Examples:
  cat feed.txt | nftban-feeds parse
  nftban-feeds sync firehol_anonymous
  nftban-feeds sync firehol_anonymous,spamhaus_drop,greensnow

`)
}

// parseFeeds reads feed data from stdin, parses IPs, and outputs valid IPs to stdout
// Used by bash wrapper to parse downloaded feeds before storage
func parseFeeds() error {
	// Read all input from stdin
	content, err := os.ReadFile("/dev/stdin")
	if err != nil {
		return fmt.Errorf("failed to read stdin: %w", err)
	}

	// Parse IPs using the same parser as sync command
	prefixes, err := parser.ParseIPs(content)
	if err != nil {
		return fmt.Errorf("parse error: %w", err)
	}

	// Output each valid IP/prefix to stdout (one per line)
	for _, prefix := range prefixes {
		fmt.Println(prefix.String())
	}

	return nil
}

// syncFeeds loads pre-downloaded feeds from disk and loads to nftables atomically
// v0.32.0: Changed architecture - Bash downloads, Go loads (single source of truth)
func syncFeeds(feedNames []string, limits safety.Limits) error {
	startTime := time.Now()

	// Feed storage directory (Bash downloads feeds here)
	feedDir := "/var/lib/nftban/feeds"

	// Check which feeds exist on disk
	var existingFeeds []string
	for _, name := range feedNames {
		feedFile := filepath.Join(feedDir, name+".txt")
		if _, err := os.Stat(feedFile); err == nil {
			existingFeeds = append(existingFeeds, name)
		} else {
			fmt.Fprintf(os.Stderr, "Warning: feed file not found: %s (skipping)\n", feedFile)
		}
	}

	if len(existingFeeds) == 0 {
		return fmt.Errorf("no feed files found in %s\n"+
			"Feeds must be downloaded first using: nftban feeds update", feedDir)
	}

	fmt.Printf("Loading %d feeds from %s...\n", len(existingFeeds), feedDir)

	// Parse feeds from disk
	parseStart := time.Now()
	var allPrefixes []netip.Prefix
	successCount := 0

	for _, name := range existingFeeds {
		feedFile := filepath.Join(feedDir, name+".txt")

		// Read feed file
		content, err := os.ReadFile(feedFile)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Warning: failed to read %s: %v\n", feedFile, err)
			continue
		}

		// Parse IPs (content is already []byte from os.ReadFile)
		prefixes, err := parser.ParseIPs(content)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Warning: %s parse error: %v\n", name, err)
			continue
		}

		fmt.Printf("  %s: %d IPs parsed\n", name, len(prefixes))
		allPrefixes = append(allPrefixes, prefixes...)
		successCount++
	}

	if successCount == 0 {
		return fmt.Errorf("all feeds failed to parse")
	}

	fmt.Printf("\nDeduplicating and merging CIDRs...\n")
	allPrefixes = parser.MergeCIDRs(allPrefixes)

	v4, v6 := parser.SplitIPv4v6(allPrefixes)
	fmt.Printf("Total unique: %d IPv4, %d IPv6\n", len(v4), len(v6))
	parseTime := time.Since(parseStart)

	// 4. Check if merged content hash changed (skip reload if same)
	currentHash := parser.HashPrefixes(allPrefixes)
	cacheDir := "/var/cache/nftban/feeds"
	hashFile := filepath.Join(cacheDir, "merged.sha256")

	if cachedHash, err := os.ReadFile(hashFile); err == nil {
		if parser.CompareHashes(currentHash, strings.TrimSpace(string(cachedHash))) {
			fmt.Printf("\n⏭️  No changes in merged feeds (hash match). Skipping nftables reload.\n")
			fmt.Printf("📊 Stats: parse=%.2fs, total=%.2fs\n",
				parseTime.Seconds(), time.Since(startTime).Seconds())
			return nil
		}
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
	_ = os.MkdirAll(cacheDir, 0755)
	_ = os.WriteFile(hashFile, []byte(currentHash), 0644)

	// Save snapshot for delta tracking
	snapshot := safety.Snapshot{
		TotalV4: len(v4),
		TotalV6: len(v6),
		Hash:    currentHash,
	}
	if err := safety.SaveSnapshot(cacheDir, snapshot); err != nil {
		fmt.Fprintf(os.Stderr, "⚠️  Warning: failed to save snapshot: %v\n", err)
	}

	totalTime := time.Since(startTime)
	fmt.Printf("\n✅ Feeds loaded atomically\n")
	fmt.Printf("📊 Performance: parse=%.2fs, load=%.2fs, total=%.2fs\n",
		parseTime.Seconds(), loadTime.Seconds(), totalTime.Seconds())

	return nil
}
