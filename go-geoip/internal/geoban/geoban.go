package geoban

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/google/nftables"
)

// Action defines the type of GeoBan operation
type Action string

const (
	ActionBan       Action = "ban"
	ActionWhitelist Action = "whitelist"
)

// Options contains configuration for GeoBan operations
type Options struct {
	Action      Action
	Atomic      bool
	FilesDir    string
	TrackingDir string
	CacheDir    string
}

// FetchAndLoad fetches country IP ranges from IPdeny.com and loads into nftables
func FetchAndLoad(cc string, opt Options) error {
	cc = strings.ToUpper(cc)

	if len(cc) != 2 {
		return fmt.Errorf("invalid country code: %s (must be ISO alpha-2)", cc)
	}

	fmt.Printf("Fetching IP ranges for country: %s\n", cc)

	// 1. Fetch from IPdeny.com
	v4, v6, err := fetchIPDeny(cc, opt.CacheDir)
	if err != nil {
		return fmt.Errorf("fetch failed: %w", err)
	}

	// 2. Parse and merge CIDRs
	v4 = mergeCIDRs(v4)
	v6 = mergeCIDRs(v6)

	fmt.Printf("  IPv4: %d ranges\n", len(v4))
	fmt.Printf("  IPv6: %d ranges\n", len(v6))

	// 3. Save to configuration file
	filePath := filePathFor(opt.FilesDir, opt.Action, cc)
	if err := saveCountryFile(filePath, cc, string(opt.Action), v4, v6); err != nil {
		return fmt.Errorf("save file: %w", err)
	}
	fmt.Printf("  Saved to: %s\n", filePath)

	// 4. Atomic nftables loading
	if opt.Atomic {
		fmt.Printf("  Loading into nftables atomically...\n")
		if err := nftAdd(opt.Action, v4, v6); err != nil {
			return fmt.Errorf("nftables load: %w", err)
		}
		fmt.Printf("  ✓ Loaded into nftables\n")
	}

	// 5. Save tracking information
	if err := saveTracking(opt.TrackingDir, opt.Action, cc, v4, v6); err != nil {
		return fmt.Errorf("save tracking: %w", err)
	}

	return nil
}

// Remove removes country IPs from nftables and deletes configuration files
func Remove(cc string, opt Options) error {
	cc = strings.ToUpper(cc)

	fmt.Printf("Removing country: %s\n", cc)

	// 1. Read existing file to get IPs
	filePath := filePathFor(opt.FilesDir, opt.Action, cc)
	v4, v6, _ := readCountryFile(filePath)

	// 2. Remove from nftables atomically
	if opt.Atomic && (len(v4) > 0 || len(v6) > 0) {
		fmt.Printf("  Removing from nftables...\n")
		if err := nftDelete(opt.Action, v4, v6); err != nil {
			fmt.Fprintf(os.Stderr, "  Warning: nftables removal partial: %v\n", err)
		} else {
			fmt.Printf("  ✓ Removed from nftables\n")
		}
	}

	// 3. Delete configuration file
	if err := os.Remove(filePath); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("delete file: %w", err)
	}
	fmt.Printf("  ✓ Deleted file: %s\n", filePath)

	// 4. Delete tracking file
	trackingFile := filepath.Join(opt.TrackingDir, fmt.Sprintf("%s-%s.json", opt.Action, cc))
	os.Remove(trackingFile) // Ignore errors

	return nil
}

// fetchIPDeny downloads country IP ranges from IPdeny.com
func fetchIPDeny(cc string, cacheDir string) ([]string, []string, error) {
	ccLower := strings.ToLower(cc)

	v4URL := fmt.Sprintf("https://www.ipdeny.com/ipblocks/data/aggregated/%s-aggregated.zone", ccLower)
	v6URL := fmt.Sprintf("https://www.ipdeny.com/ipv6/ipaddresses/aggregated/%s-aggregated.zone", ccLower)

	// Fetch IPv4 (required)
	v4, err := downloadCIDRs(v4URL, cc, "v4", cacheDir)
	if err != nil {
		return nil, nil, fmt.Errorf("IPv4 download failed: %w", err)
	}

	// Fetch IPv6 (optional - may not exist for all countries)
	v6, _ := downloadCIDRs(v6URL, cc, "v6", cacheDir)

	return v4, v6, nil
}

// downloadCIDRs downloads and parses CIDR list from URL with caching
func downloadCIDRs(url, cc, version, cacheDir string) ([]string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// Setup cache
	cacheFile := ""
	etagFile := ""
	if cacheDir != "" {
		os.MkdirAll(cacheDir, 0755)
		cacheFile = filepath.Join(cacheDir, fmt.Sprintf("%s-%s.zone", cc, version))
		etagFile = filepath.Join(cacheDir, fmt.Sprintf("%s-%s.etag", cc, version))
	}

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("User-Agent", "NFTBan/0.31.0 (+https://nftban.com)")

	// Add ETag if cached
	if etagFile != "" {
		if etag, err := os.ReadFile(etagFile); err == nil {
			req.Header.Set("If-None-Match", strings.TrimSpace(string(etag)))
		}
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	// 304 Not Modified - use cache
	if resp.StatusCode == http.StatusNotModified && cacheFile != "" {
		content, err := os.ReadFile(cacheFile)
		if err != nil {
			return nil, fmt.Errorf("cache read error: %w", err)
		}
		return parseCIDRs(content), nil
	}

	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("HTTP %d: %s", resp.StatusCode, url)
	}

	// Read response (limit 50MB)
	scanner := bufio.NewScanner(resp.Body)
	var lines []string
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}

	content := []byte(strings.Join(lines, "\n"))

	// Save to cache
	if cacheFile != "" {
		os.WriteFile(cacheFile, content, 0644)
		if etag := resp.Header.Get("ETag"); etag != "" {
			os.WriteFile(etagFile, []byte(etag), 0644)
		}
	}

	return parseCIDRs(content), scanner.Err()
}

// parseCIDRs parses CIDR ranges from content
func parseCIDRs(content []byte) []string {
	lines := strings.Split(string(content), "\n")
	var cidrs []string

	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Validate CIDR
		if _, err := netip.ParsePrefix(line); err == nil {
			cidrs = append(cidrs, line)
		}
	}

	return cidrs
}

// mergeCIDRs deduplicates CIDR ranges
func mergeCIDRs(cidrs []string) []string {
	seen := make(map[string]struct{})
	result := make([]string, 0, len(cidrs))

	for _, cidr := range cidrs {
		if _, exists := seen[cidr]; !exists {
			seen[cidr] = struct{}{}
			result = append(result, cidr)
		}
	}

	return result
}

// nftAdd adds CIDRs to nftables sets atomically
func nftAdd(action Action, v4, v6 []string) error {
	conn, err := nftables.New()
	if err != nil {
		return fmt.Errorf("nftables connection: %w", err)
	}

	setV4, setV6 := targetSets(action)

	// Add IPv4
	if len(v4) > 0 {
		if err := nftElements(conn, "add", setV4, v4); err != nil {
			return err
		}
	}

	// Add IPv6
	if len(v6) > 0 {
		if err := nftElements(conn, "add", setV6, v6); err != nil {
			return err
		}
	}

	return nil
}

// nftDelete removes CIDRs from nftables sets atomically
func nftDelete(action Action, v4, v6 []string) error {
	conn, err := nftables.New()
	if err != nil {
		return fmt.Errorf("nftables connection: %w", err)
	}

	setV4, setV6 := targetSets(action)

	// Delete IPv4
	if len(v4) > 0 {
		_ = nftElements(conn, "delete", setV4, v4) // Best effort
	}

	// Delete IPv6
	if len(v6) > 0 {
		_ = nftElements(conn, "delete", setV6, v6) // Best effort
	}

	return nil
}

// targetSets returns the nftables set names for the given action
func targetSets(action Action) (string, string) {
	if action == ActionBan {
		return "inet nftban_main blacklist_v4", "inet nftban_main blacklist_v6"
	}
	return "inet nftban_main whitelist_v4", "inet nftban_main whitelist_v6"
}

// nftElements adds or deletes elements in chunks to handle large sets
func nftElements(conn *nftables.Conn, op, setName string, cidrs []string) error {
	// Parse set name: "inet nftban_main blacklist_v4"
	parts := strings.Fields(setName)
	if len(parts) != 3 {
		return fmt.Errorf("invalid set name format: %s", setName)
	}

	tableName := parts[1]
	setShortName := parts[2]

	// Find table
	table, err := findTable(conn, tableName)
	if err != nil {
		return err
	}

	// Find set
	set, err := findSet(conn, table, setShortName)
	if err != nil {
		return err
	}

	// Process in chunks of 4096 elements
	const chunkSize = 4096
	for i := 0; i < len(cidrs); i += chunkSize {
		end := i + chunkSize
		if end > len(cidrs) {
			end = len(cidrs)
		}
		chunk := cidrs[i:end]

		// Build elements
		elems := make([]nftables.SetElement, 0, len(chunk))
		for _, cidr := range chunk {
			prefix, err := netip.ParsePrefix(cidr)
			if err != nil {
				continue
			}

			elem := nftables.SetElement{
				Key: prefix.Addr().AsSlice(),
			}
			elems = append(elems, elem)
		}

		// Add or delete elements
		if op == "add" {
			if err := conn.SetAddElements(set, elems); err != nil {
				return fmt.Errorf("add elements to %s: %w", setShortName, err)
			}
		} else if op == "delete" {
			if err := conn.SetDeleteElements(set, elems); err != nil {
				return fmt.Errorf("delete elements from %s: %w", setShortName, err)
			}
		}
	}

	// Commit transaction
	if err := conn.Flush(); err != nil {
		return fmt.Errorf("commit transaction: %w", err)
	}

	return nil
}

// Helper: Find table by name
func findTable(conn *nftables.Conn, name string) (*nftables.Table, error) {
	tables, err := conn.ListTables()
	if err != nil {
		return nil, fmt.Errorf("list tables: %w", err)
	}

	for _, t := range tables {
		if t.Name == name && t.Family == nftables.TableFamilyINet {
			return t, nil
		}
	}
	return nil, fmt.Errorf("table '%s' not found", name)
}

// Helper: Find set by name within table
func findSet(conn *nftables.Conn, table *nftables.Table, name string) (*nftables.Set, error) {
	sets, err := conn.GetSets(table)
	if err != nil {
		return nil, fmt.Errorf("get sets: %w", err)
	}

	for _, s := range sets {
		if s.Name == name {
			return s, nil
		}
	}
	return nil, fmt.Errorf("set '%s' not found in table '%s'", name, table.Name)
}

// filePathFor generates the file path for a country configuration
func filePathFor(dir string, action Action, cc string) string {
	if action == ActionBan {
		return filepath.Join(dir, fmt.Sprintf("50-ban-%s.conf", cc))
	}
	return filepath.Join(dir, fmt.Sprintf("40-whitelist-%s.conf", cc))
}

// saveCountryFile saves country IP ranges to a configuration file
func saveCountryFile(path, cc, action string, v4, v6 []string) error {
	tmp := path + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	defer f.Close()

	w := bufio.NewWriter(f)

	fmt.Fprintf(w, "# Auto-generated by NFTBan GeoBan: %s\n", time.Now().Format(time.RFC3339))
	fmt.Fprintf(w, "# Country: %s (%s)\n", cc, strings.ToUpper(action))
	fmt.Fprintf(w, "# Source: IPdeny.com\n")
	fmt.Fprintf(w, "#\n")
	fmt.Fprintf(w, "# DO NOT EDIT - This file is managed by nftban geoip %s\n", action)
	fmt.Fprintf(w, "#\n\n")

	if len(v4) > 0 {
		fmt.Fprintln(w, "# IPv4 Ranges")
		for _, cidr := range v4 {
			fmt.Fprintln(w, cidr)
		}
		fmt.Fprintln(w)
	}

	if len(v6) > 0 {
		fmt.Fprintln(w, "# IPv6 Ranges")
		for _, cidr := range v6 {
			fmt.Fprintln(w, cidr)
		}
	}

	if err := w.Flush(); err != nil {
		return err
	}

	if err := f.Close(); err != nil {
		return err
	}

	// Atomic rename
	if err := os.Rename(tmp, path); err != nil {
		return err
	}

	// Set permissions
	return os.Chmod(path, 0640)
}

// readCountryFile reads IP ranges from a country configuration file
func readCountryFile(path string) (v4, v6 []string, err error) {
	content, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, err
	}

	lines := strings.Split(string(content), "\n")
	inV6 := false

	for _, line := range lines {
		line = strings.TrimSpace(line)

		if line == "" || strings.HasPrefix(line, "#") {
			if strings.Contains(line, "IPv6") {
				inV6 = true
			}
			continue
		}

		// Validate CIDR
		if _, err := netip.ParsePrefix(line); err == nil {
			if inV6 {
				v6 = append(v6, line)
			} else {
				v4 = append(v4, line)
			}
		}
	}

	return v4, v6, nil
}

// saveTracking saves tracking information as JSON
func saveTracking(trackDir string, action Action, cc string, v4, v6 []string) error {
	if trackDir == "" {
		return nil
	}

	if err := os.MkdirAll(trackDir, 0750); err != nil {
		return err
	}

	filename := filepath.Join(trackDir, fmt.Sprintf("%s-%s.json", action, cc))

	data := map[string]interface{}{
		"country":   cc,
		"action":    action,
		"timestamp": time.Now().Unix(),
		"ipv4":      v4,
		"ipv6":      v6,
		"ipv4_count": len(v4),
		"ipv6_count": len(v6),
	}

	jsonData, err := json.MarshalIndent(data, "", "  ")
	if err != nil {
		return err
	}

	return os.WriteFile(filename, jsonData, 0640)
}
