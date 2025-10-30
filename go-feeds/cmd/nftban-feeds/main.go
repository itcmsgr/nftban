package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"regexp"
	"strings"
	"time"
)

const (
	VERSION = "1.0.0"
)

// FeedParseResult represents the JSON output structure
type FeedParseResult struct {
	TotalLines    int      `json:"total_lines"`
	ValidIPs      int      `json:"valid_ips"`
	ValidCIDRs    int      `json:"valid_cidrs"`
	IPv4Count     int      `json:"ipv4_count"`
	IPv6Count     int      `json:"ipv6_count"`
	SkippedLines  int      `json:"skipped_lines"`
	DuplicatesSkipped int  `json:"duplicates_skipped"`
	ParseTimeMs   int64    `json:"parse_time_ms"`
	IPs           []string `json:"ips,omitempty"`
}

// ValidationResult for single IP/CIDR validation
type ValidationResult struct {
	Entry   string `json:"entry"`
	Valid   bool   `json:"valid"`
	Type    string `json:"type,omitempty"`
	Version string `json:"version,omitempty"`
	Error   string `json:"error,omitempty"`
}

var (
	// Regex patterns for quick validation
	commentRegex = regexp.MustCompile(`^\s*(#|;|//|$)`)
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(1)
	}

	cmd := os.Args[1]

	switch cmd {
	case "version", "--version", "-v":
		fmt.Printf("nftban-feeds v%s\n", VERSION)
		os.Exit(0)
	case "help", "--help", "-h":
		usage()
		os.Exit(0)
	case "parse":
		// Parse feed from stdin
		outputMode := "json"
		if len(os.Args) > 2 && os.Args[2] == "--list" {
			outputMode = "list"
		}
		parseFeed(outputMode)
	case "validate":
		// Validate single IP/CIDR
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, `{"error":"IP/CIDR required"}`)
			os.Exit(1)
		}
		validateEntry(os.Args[2])
	case "deduplicate":
		// Deduplicate IPs from stdin
		deduplicateIPs()
	case "stats":
		// Quick stats without full parse
		quickStats()
	default:
		fmt.Fprintf(os.Stderr, `{"error":"Unknown command: %s"}`+"\n", cmd)
		usage()
		os.Exit(1)
	}
}

// parseFeed reads feed from stdin, validates, and outputs results
func parseFeed(outputMode string) {
	start := time.Now()

	result := FeedParseResult{}
	scanner := bufio.NewScanner(os.Stdin)

	var ips []string
	seen := make(map[string]bool)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		result.TotalLines++

		// Skip comments and empty lines
		if line == "" || commentRegex.MatchString(line) {
			result.SkippedLines++
			continue
		}

		// Extract first field (IP/CIDR) - handles space/tab separated
		fields := strings.Fields(line)
		if len(fields) == 0 {
			result.SkippedLines++
			continue
		}

		entry := fields[0]

		// Validate entry
		if !isValidEntry(entry) {
			result.SkippedLines++
			continue
		}

		// Deduplicate
		if seen[entry] {
			result.DuplicatesSkipped++
			continue
		}
		seen[entry] = true

		// Categorize
		if strings.Contains(entry, "/") {
			result.ValidCIDRs++
		} else {
			result.ValidIPs++
		}

		if strings.Contains(entry, ":") {
			result.IPv6Count++
		} else {
			result.IPv4Count++
		}

		if outputMode == "list" {
			fmt.Println(entry)
		} else {
			ips = append(ips, entry)
		}
	}

	if err := scanner.Err(); err != nil {
		fmt.Fprintf(os.Stderr, `{"error":"Reading input: %v"}`+"\n", err)
		os.Exit(1)
	}

	result.ParseTimeMs = time.Since(start).Milliseconds()

	if outputMode == "json" {
		result.IPs = ips
		jsonOut, _ := json.MarshalIndent(result, "", "  ")
		fmt.Println(string(jsonOut))
	}
}

// isValidEntry validates IP or CIDR notation
func isValidEntry(entry string) bool {
	// CIDR notation
	if strings.Contains(entry, "/") {
		_, _, err := net.ParseCIDR(entry)
		return err == nil
	}

	// Single IP
	ip := net.ParseIP(entry)
	return ip != nil
}

// validateEntry validates and provides details about a single entry
func validateEntry(entry string) {
	result := ValidationResult{
		Entry: entry,
		Valid: isValidEntry(entry),
	}

	if result.Valid {
		if strings.Contains(entry, "/") {
			result.Type = "cidr"
			_, ipnet, _ := net.ParseCIDR(entry)
			if ipnet.IP.To4() != nil {
				result.Version = "ipv4"
			} else {
				result.Version = "ipv6"
			}
		} else {
			result.Type = "ip"
			ip := net.ParseIP(entry)
			if ip.To4() != nil {
				result.Version = "ipv4"
			} else {
				result.Version = "ipv6"
			}
		}
	} else {
		result.Error = "Invalid IP or CIDR notation"
	}

	jsonOut, _ := json.MarshalIndent(result, "", "  ")
	fmt.Println(string(jsonOut))
}

// deduplicateIPs removes duplicate entries from stdin
func deduplicateIPs() {
	seen := make(map[string]bool)
	scanner := bufio.NewScanner(os.Stdin)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		if !seen[line] {
			seen[line] = true
			fmt.Println(line)
		}
	}

	if err := scanner.Err(); err != nil {
		fmt.Fprintf(os.Stderr, `{"error":"Reading input: %v"}`+"\n", err)
		os.Exit(1)
	}
}

// quickStats provides quick statistics without full processing
func quickStats() {
	scanner := bufio.NewScanner(os.Stdin)

	totalLines := 0
	commentLines := 0
	emptyLines := 0
	potentialEntries := 0

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		totalLines++

		if line == "" {
			emptyLines++
			continue
		}

		if commentRegex.MatchString(line) {
			commentLines++
			continue
		}

		potentialEntries++
	}

	stats := map[string]interface{}{
		"total_lines":        totalLines,
		"comment_lines":      commentLines,
		"empty_lines":        emptyLines,
		"potential_entries":  potentialEntries,
	}

	jsonOut, _ := json.MarshalIndent(stats, "", "  ")
	fmt.Println(string(jsonOut))
}

func usage() {
	fmt.Println("nftban-feeds - Fast threat feed parser")
	fmt.Println("nftban — Simplifying Linux Firewall Management")
	fmt.Println()
	fmt.Println("Usage:")
	fmt.Println("  nftban-feeds parse [--list]        Parse feed from stdin")
	fmt.Println("  nftban-feeds validate <entry>      Validate IP/CIDR")
	fmt.Println("  nftban-feeds deduplicate           Deduplicate IPs from stdin")
	fmt.Println("  nftban-feeds stats                 Quick statistics")
	fmt.Println("  nftban-feeds version               Show version")
	fmt.Println("  nftban-feeds help                  Show this help")
	fmt.Println()
	fmt.Println("Examples:")
	fmt.Println("  # Parse feed and output JSON summary")
	fmt.Println("  curl https://example.com/feed.txt | nftban-feeds parse")
	fmt.Println()
	fmt.Println("  # Parse feed and output IP list")
	fmt.Println("  cat feed.txt | nftban-feeds parse --list > parsed.txt")
	fmt.Println()
	fmt.Println("  # Validate single IP/CIDR")
	fmt.Println("  nftban-feeds validate 192.168.1.1")
	fmt.Println("  nftban-feeds validate 10.0.0.0/8")
	fmt.Println()
	fmt.Println("  # Deduplicate IP list")
	fmt.Println("  cat ips.txt | nftban-feeds deduplicate")
	fmt.Println()
	fmt.Println("  # Quick stats")
	fmt.Println("  cat feed.txt | nftban-feeds stats")
	fmt.Println()
	fmt.Println("Output: JSON format (or IP list with --list)")
	fmt.Println("Performance: ~0.5-2 seconds for 50,000 IPs")
}
