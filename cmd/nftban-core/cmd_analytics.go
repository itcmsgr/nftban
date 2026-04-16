// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="cmd_analytics"
// meta:type="cmd"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Analytics subcommand for ban statistics and country-based reporting"
//
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_DATA_DIR"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"

	"github.com/itcmsgr/nftban/internal/analytics"
)

func cmdAnalytics(action string) error {
	switch action {
	case "report":
		return cmdAnalyticsReport()
	case "summary":
		return cmdAnalyticsSummary()
	case "countries":
		return cmdAnalyticsCountries()
	case "top":
		return cmdAnalyticsTop()
	case "ip":
		return cmdAnalyticsIP()
	default:
		return fmt.Errorf("unknown analytics action: %s\nUsage: nftban-core analytics [report|summary|countries|top|ip]", action)
	}
}

// cmdAnalyticsReport generates report data for email reporting (optimized batch operations).
// Usage: nftban-core analytics report --ips="ip1,ip2,..." [--limit=5]
func cmdAnalyticsReport() error {
	// Parse flags
	var ipsStr string
	limit := 5

	for i, arg := range os.Args {
		if strings.HasPrefix(arg, "--ips=") {
			ipsStr = strings.TrimPrefix(arg, "--ips=")
		}
		if strings.HasPrefix(arg, "--limit=") {
			if val, err := strconv.Atoi(strings.TrimPrefix(arg, "--limit=")); err == nil {
				limit = val
			}
		}
		// Support space-separated format too
		if arg == "--ips" && i+1 < len(os.Args) {
			ipsStr = os.Args[i+1]
		}
		if arg == "--limit" && i+1 < len(os.Args) {
			if val, err := strconv.Atoi(os.Args[i+1]); err == nil {
				limit = val
			}
		}
	}

	if ipsStr == "" {
		return fmt.Errorf("usage: nftban-core analytics report --ips=\"ip1,ip2,...\" [--limit=5]")
	}

	// Parse IPs
	ips := strings.Split(ipsStr, ",")
	for i := range ips {
		ips[i] = strings.TrimSpace(ips[i])
	}

	// Get data directory
	dataDir := os.Getenv("NFTBAN_DATA_DIR")
	if dataDir == "" {
		dataDir = "/var/lib/nftban"
	}

	// Create reporter
	reporter, err := analytics.NewReporter(dataDir)
	if err != nil {
		return fmt.Errorf("failed to create reporter: %w", err)
	}
	defer reporter.Close()

	// Generate report
	report, err := reporter.GenerateReport(ips, limit)
	if err != nil {
		return fmt.Errorf("failed to generate report: %w", err)
	}

	// Output JSON
	jsonStr, err := report.ToJSON()
	if err != nil {
		return fmt.Errorf("failed to marshal JSON: %w", err)
	}

	fmt.Println(jsonStr)
	return nil
}

// cmdAnalyticsSummary shows overall analytics summary.
// Usage: nftban-core analytics summary [--json]
func cmdAnalyticsSummary() error {
	st := analytics.StateOrNil()
	if st == nil {
		return fmt.Errorf("analytics not initialized")
	}

	jsonOutput := hasFlag("--json")

	summary := st.GetSummary()

	if jsonOutput {
		data, err := json.MarshalIndent(summary, "", "  ")
		if err != nil {
			return err
		}
		fmt.Println(string(data))
		return nil
	}

	// Human-readable output
	fmt.Println("📊 NFTBan Analytics Summary")
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()
	fmt.Printf("Total Banned IPs:     %d\n", summary.TotalIPs)
	fmt.Printf("Total Countries:      %d\n", summary.TotalCountries)
	if !summary.LastUpdated.IsZero() {
		fmt.Printf("Last Updated:         %s\n", summary.LastUpdated.Format("2006-01-02 15:04:05"))
	}
	fmt.Println()

	return nil
}

// cmdAnalyticsCountries lists all countries with ban counts.
// Usage: nftban-core analytics countries [--json]
func cmdAnalyticsCountries() error {
	st := analytics.StateOrNil()
	if st == nil {
		return fmt.Errorf("analytics not initialized")
	}

	jsonOutput := hasFlag("--json")

	stats := st.GetCountryStats()

	if jsonOutput {
		data, err := json.MarshalIndent(stats, "", "  ")
		if err != nil {
			return err
		}
		fmt.Println(string(data))
		return nil
	}

	// Human-readable table output
	fmt.Println("🌍 Banned IPs by Country")
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "COUNTRY\tIP COUNT\tLAST UPDATED")
	fmt.Fprintln(w, strings.Repeat("-", 60))

	type row struct {
		country string
		count   int
		updated string
	}
	var rows []row
	for _, cs := range stats {
		rows = append(rows, row{
			country: cs.Country,
			count:   cs.IPCount,
			updated: cs.LastUpdated.Format("2006-01-02 15:04"),
		})
	}

	// Sort by count descending
	sort.Slice(rows, func(i, j int) bool {
		return rows[i].count > rows[j].count
	})

	for _, r := range rows {
		fmt.Fprintf(w, "%s\t%d\t%s\n", r.country, r.count, r.updated)
	}

	_ = w.Flush()
	fmt.Println()

	return nil
}

// cmdAnalyticsTop shows top N countries by IP count.
// Usage: nftban-core analytics top [N] [--json]
func cmdAnalyticsTop() error {
	st := analytics.StateOrNil()
	if st == nil {
		return fmt.Errorf("analytics not initialized")
	}

	// Parse N from args
	n := 10 // default
	for i, arg := range os.Args {
		if arg == "top" && i+1 < len(os.Args) {
			nextArg := os.Args[i+1]
			if !strings.HasPrefix(nextArg, "--") {
				if val, err := strconv.Atoi(nextArg); err == nil {
					n = val
				}
			}
			break
		}
	}

	jsonOutput := hasFlag("--json")

	topCountries := st.GetTopCountries(n)

	if jsonOutput {
		result := map[string]interface{}{
			"success":       true,
			"count":         len(topCountries),
			"top_countries": topCountries,
		}
		data, err := json.MarshalIndent(result, "", "  ")
		if err != nil {
			return err
		}
		fmt.Println(string(data))
		return nil
	}

	// Human-readable output
	fmt.Printf("🏆 Top %d Countries by Banned IPs\n", n)
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	fmt.Fprintln(w, "RANK\tCOUNTRY\tIP COUNT")
	fmt.Fprintln(w, strings.Repeat("-", 50))

	for i, cs := range topCountries {
		fmt.Fprintf(w, "%d\t%s\t%d\n", i+1, cs.Country, cs.IPCount)
	}

	_ = w.Flush()
	fmt.Println()

	return nil
}

// cmdAnalyticsIP looks up analytics data for a specific IP.
// Usage: nftban-core analytics ip <IP> [--json]
func cmdAnalyticsIP() error {
	st := analytics.StateOrNil()
	if st == nil {
		return fmt.Errorf("analytics not initialized")
	}

	// Find IP argument
	var ip string
	for i, arg := range os.Args {
		if arg == "ip" && i+1 < len(os.Args) {
			ip = os.Args[i+1]
			break
		}
	}

	if ip == "" {
		return fmt.Errorf("usage: nftban-core analytics ip <IP> [--json]")
	}

	jsonOutput := hasFlag("--json")

	origin, found := st.GetIPOrigin(ip)

	result := &analytics.IPLookupResult{
		Success: true,
		IP:      ip,
		Found:   found,
		Origin:  origin,
	}

	if !found {
		result.Message = "IP not found in analytics database"
	}

	if jsonOutput {
		data, err := json.MarshalIndent(result, "", "  ")
		if err != nil {
			return err
		}
		fmt.Println(string(data))
		return nil
	}

	// Human-readable output
	fmt.Printf("🔍 Analytics for IP: %s\n", ip)
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	if !found {
		fmt.Println("❌ IP not found in analytics database")
		fmt.Println()
		fmt.Println("This IP has not been banned, or analytics were not enabled when it was banned.")
		fmt.Println()
		return nil
	}

	fmt.Printf("IP Address:   %s\n", origin.IP)
	fmt.Printf("Country:      %s\n", origin.Country)
	if origin.City != "" {
		fmt.Printf("City:         %s\n", origin.City)
	}
	fmt.Printf("Banned At:    %s\n", origin.BannedAt.Format("2006-01-02 15:04:05"))
	if origin.Reason != "" {
		fmt.Printf("Reason:       %s\n", origin.Reason)
	}
	fmt.Println()

	return nil
}

// hasFlag checks if a flag exists in os.Args.
func hasFlag(flag string) bool {
	for _, arg := range os.Args {
		if arg == flag {
			return true
		}
	}
	return false
}
