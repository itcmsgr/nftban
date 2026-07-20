// =============================================================================
// NFTBan - Trust Feeds Management Command
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_trust"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Manage trust feeds (whitelists) for cloud providers and CDNs"
// meta:input="Subcommand (list, enable, disable, update, load)"
// meta:output="Console output with trust feed status"
// meta:depends="github.com/itcmsgr/nftban/pkg/ipc,github.com/itcmsgr/nftban/internal/nftbanconf"
// meta:inventory.files="/var/lib/nftban/trust/*.txt"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/conf.d/trust.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network="http"
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"bufio"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/ipc"
	"github.com/itcmsgr/nftban/pkg/version"
)

// getTrustPaths returns trust directory and config paths from passed config
func getTrustPaths(cfg *nftbanconf.Config) (trustDir, trustConfig string) {
	return cfg.DataDir + "/trust", cfg.ConfigDir + "/conf.d/trust.conf"
}

// TrustConfig represents a whitelist/trust feed configuration
type TrustConfig struct {
	Name        string
	URL         string
	URLv6       string // Optional separate IPv6 URL (e.g., Cloudflare)
	Enabled     bool
	Category    string
	Description string
}

// Built-in trust feeds (cloud providers, CDNs, etc.)
var builtInTrustFeeds = []TrustConfig{
	{
		Name:        "CLOUDFLARE",
		URL:         "https://www.cloudflare.com/ips-v4",
		URLv6:       "https://www.cloudflare.com/ips-v6",
		Category:    "cdn",
		Description: "Cloudflare CDN IP ranges",
	},
	{
		Name:        "CLOUDFLARE_CHINA",
		URL:         "https://www.cloudflare.com/ips-v4/cn",
		Category:    "cdn",
		Description: "Cloudflare China Network IP ranges",
	},
	{
		Name:        "GOOGLE_CLOUD",
		URL:         "https://www.gstatic.com/ipranges/cloud.json",
		Category:    "cloud",
		Description: "Google Cloud Platform IP ranges",
	},
	{
		Name:        "GOOGLE_SERVICES",
		URL:         "https://www.gstatic.com/ipranges/goog.json",
		Category:    "cloud",
		Description: "Google Services IP ranges",
	},
	{
		Name:        "AWS",
		URL:         "https://ip-ranges.amazonaws.com/ip-ranges.json",
		Category:    "cloud",
		Description: "Amazon Web Services IP ranges",
	},
	{
		Name:        "AZURE",
		URL:         "https://download.microsoft.com/download/7/1/D/71D86715-5596-4529-9B13-DA13A5DE5B63/ServiceTags_Public_Weekly.json",
		Category:    "cloud",
		Description: "Microsoft Azure IP ranges",
	},
	{
		Name:        "DIGITALOCEAN",
		URL:         "https://digitalocean.com/geo/google.csv",
		Category:    "cloud",
		Description: "DigitalOcean IP ranges",
	},
	{
		Name:        "FASTLY",
		URL:         "https://api.fastly.com/public-ip-list",
		Category:    "cdn",
		Description: "Fastly CDN IP ranges",
	},
	{
		Name:        "QUICCLOUD",
		URL:         "https://quic.cloud/ips",
		Category:    "cdn",
		Description: "QUIC.cloud / LiteSpeed CDN IP ranges",
	},
}

func cmdTrust(action string, cfg *nftbanconf.Config) error {
	trustDir, trustConfig := getTrustPaths(cfg)

	switch action {
	case "list", "status":
		return cmdTrustList(trustConfig)
	case "enable":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core trust enable <TRUST_NAME>")
		}
		trustName := os.Args[3]
		return cmdTrustEnable(trustConfig, trustName, true)
	case "disable":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core trust disable <TRUST_NAME>")
		}
		trustName := os.Args[3]
		return cmdTrustEnable(trustConfig, trustName, false)
	case "update":
		return cmdTrustUpdate(trustDir, trustConfig)
	case "load":
		return cmdTrustLoad(trustDir)
	default:
		return fmt.Errorf("unknown trust action: %s\nUsage: nftban-core trust [list|status|enable|disable|update|load] [NAME]", action)
	}
}

func cmdTrustList(configPath string) error {
	// Check for --json flag
	jsonOutput := hasFlag("--json")

	// Get enabled status from config
	enabledMap := getTrustEnabledStatus(configPath)

	if jsonOutput {
		trustData := []map[string]interface{}{}
		for _, tf := range builtInTrustFeeds {
			enabled := enabledMap[tf.Name]
			trustData = append(trustData, map[string]interface{}{
				"name":        tf.Name,
				"enabled":     enabled,
				"category":    tf.Category,
				"description": tf.Description,
				"url":         tf.URL,
			})
		}

		output := map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"trusts": trustData,
				"total":  len(builtInTrustFeeds),
			},
		}
		data, _ := json.MarshalIndent(output, "", "  ")
		fmt.Println(string(data))
		return nil
	}

	// Human-readable output
	fmt.Println(version.BannerWithEmoji("🛡️", "Trust Feeds (Whitelists)"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	fmt.Printf("Available trust feeds: %d\n\n", len(builtInTrustFeeds))

	// Group by category
	categories := make(map[string][]TrustConfig)
	for _, tf := range builtInTrustFeeds {
		categories[tf.Category] = append(categories[tf.Category], tf)
	}

	for category, feeds := range categories {
		fmt.Printf("─── %s ───\n", strings.ToUpper(category))
		for _, tf := range feeds {
			enabled := enabledMap[tf.Name]
			status := "[✗]"
			if enabled {
				status = "[✓]"
			}
			fmt.Printf("  %s %s - %s\n", status, tf.Name, tf.Description)
		}
		fmt.Println()
	}

	fmt.Println("Commands:")
	fmt.Println("  nftban trust enable CLOUDFLARE   Enable a trust feed")
	fmt.Println("  nftban trust disable AWS         Disable a trust feed")
	fmt.Println("  nftban trust update              Download and apply all enabled")
	fmt.Println()

	return nil
}

func cmdTrustEnable(configPath, trustName string, enable bool) error {
	// Check for privilege (root OR CAP_NET_ADMIN capability)
	if err := checkPrivilege(); err != nil {
		return err
	}

	trustName = strings.ToUpper(trustName)

	// Verify trust exists
	found := false
	for _, tf := range builtInTrustFeeds {
		if tf.Name == trustName {
			found = true
			break
		}
	}
	if !found {
		return fmt.Errorf("unknown trust feed: %s\nUse 'nftban trust list' to see available feeds", trustName)
	}

	// Write to nftban.conf.local (central override — survives package upgrades)
	configDir := filepath.Dir(filepath.Dir(configPath)) // conf.d/trust.conf → /etc/nftban
	localConf := filepath.Join(configDir, "nftban.conf.local")

	// Ensure config directory exists
	if err := os.MkdirAll(configDir, 0750); err != nil {
		return fmt.Errorf("failed to create config directory: %w", err)
	}

	// Read existing content or start fresh
	localContent := ""
	if data, err := os.ReadFile(localConf); err == nil {
		localContent = string(data)
	}

	varName := fmt.Sprintf("TRUST_%s_ENABLED", trustName)
	newValue := "false"
	if enable {
		newValue = "true"
	}
	newLine := fmt.Sprintf(`%s="%s"`, varName, newValue)

	// Check if variable exists and replace
	varFound := false
	lines := strings.Split(localContent, "\n")
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, varName+"=") || strings.HasPrefix(trimmed, varName+" =") {
			lines[i] = newLine
			varFound = true
			break
		}
	}

	if varFound {
		localContent = strings.Join(lines, "\n")
	} else {
		// Append — ensure section marker exists
		if !strings.Contains(localContent, "# --- TRUST Configuration ---") {
			if localContent != "" && !strings.HasSuffix(localContent, "\n") {
				localContent += "\n"
			}
			localContent += "\n# --- TRUST Configuration ---\n"
		}
		localContent += newLine + "\n"
	}

	// Write config
	if err := os.WriteFile(localConf, []byte(localContent), 0640); err != nil {
		return fmt.Errorf("failed to write config: %w", err)
	}

	action := "disabled"
	if enable {
		action = "enabled"
	}
	fmt.Printf("✅ Trust feed '%s' %s\n", trustName, action)

	if enable {
		fmt.Println()
		fmt.Println("Next: Run 'sudo nftban trust update' to download and apply")
	}

	return nil
}

func cmdTrustUpdate(trustDir, configPath string) error {
	// Check for privilege (root OR CAP_NET_ADMIN capability)
	if err := checkPrivilege(); err != nil {
		return err
	}

	fmt.Println(version.BannerWithEmoji("🔄", "Update Trust Feeds"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Get enabled status
	enabledMap := getTrustEnabledStatus(configPath)

	enabledFeeds := []TrustConfig{}
	for _, tf := range builtInTrustFeeds {
		if enabledMap[tf.Name] {
			enabledFeeds = append(enabledFeeds, tf)
		}
	}

	fmt.Printf("Step 1: Found %d trust feeds (%d enabled)\n", len(builtInTrustFeeds), len(enabledFeeds))
	fmt.Println()

	if len(enabledFeeds) == 0 {
		fmt.Println("⚠️  No trust feeds enabled.")
		fmt.Println("   Use 'nftban trust enable <name>' to enable trust feeds.")
		fmt.Println("   Example: nftban trust enable CLOUDFLARE")
		return nil
	}

	// Ensure trust directory exists
	if err := os.MkdirAll(trustDir, 0755); err != nil {
		return fmt.Errorf("failed to create trust directory: %w", err)
	}

	fmt.Println("Step 2: Downloading enabled trust feeds...")
	fmt.Println(strings.Repeat("-", 70))

	successCount := 0
	failCount := 0
	totalIPs := 0

	for i, tf := range enabledFeeds {
		fmt.Printf("\n[%d/%d] %s\n", i+1, len(enabledFeeds), tf.Name)
		fmt.Printf("  Category: %s\n", tf.Category)
		fmt.Printf("  URL: %s\n", tf.URL)

		// Download and parse
		trustFile := filepath.Join(trustDir, strings.ToLower(tf.Name)+".txt")
		ipCount, err := downloadTrustFeed(tf, trustFile)
		if err != nil {
			fmt.Printf("  ❌ Error: %v\n", err)
			failCount++
			continue
		}

		fmt.Printf("  ✅ Downloaded: %d IPs/CIDRs\n", ipCount)
		successCount++
		totalIPs += ipCount
	}

	fmt.Println()
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println("Download Summary:")
	fmt.Printf("  ✅ Success: %d feeds\n", successCount)
	if failCount > 0 {
		fmt.Printf("  ❌ Failed: %d feeds\n", failCount)
	}
	fmt.Printf("  📊 Total IPs/CIDRs: %d\n", totalIPs)
	fmt.Println()

	// Auto-load into nftables
	if successCount > 0 {
		fmt.Println("Step 3: Loading trust feeds into nftables whitelist...")
		if err := cmdTrustLoad(trustDir); err != nil {
			fmt.Printf("⚠️  Warning: failed to load trust feeds: %v\n", err)
		}
	}

	return nil
}

func cmdTrustLoad(trustDir string) error {
	// Check for privilege (root OR CAP_NET_ADMIN capability)
	if err := checkPrivilege(); err != nil {
		return err
	}

	fmt.Println(version.BannerWithEmoji("🛡️", "Load Trust Feeds"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Read all .txt files from trust directory
	files, err := filepath.Glob(filepath.Join(trustDir, "*.txt"))
	if err != nil {
		return fmt.Errorf("failed to read trust directory: %w", err)
	}

	if len(files) == 0 {
		fmt.Println("⚠️  No trust feed files found.")
		fmt.Println("   Run 'nftban trust update' first to download feeds.")
		return nil
	}

	// Collect all IPs
	var ipv4List, ipv6List []string

	for _, file := range files {
		content, err := os.ReadFile(file)
		if err != nil {
			fmt.Printf("⚠️  Warning: failed to read %s: %v\n", file, err)
			continue
		}

		lines := strings.Split(string(content), "\n")
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if line == "" || strings.HasPrefix(line, "#") {
				continue
			}

			if strings.Contains(line, ":") {
				// IPv6
				if !strings.Contains(line, "/") {
					line += "/128"
				}
				ipv6List = append(ipv6List, line)
			} else {
				// IPv4
				if !strings.Contains(line, "/") {
					line += "/32"
				}
				ipv4List = append(ipv4List, line)
			}
		}
	}

	fmt.Printf("Loaded: %d IPv4 CIDRs, %d IPv6 CIDRs\n", len(ipv4List), len(ipv6List))
	fmt.Println()

	if len(ipv4List) == 0 && len(ipv6List) == 0 {
		fmt.Println("⚠️  No valid IPs found in trust feed files.")
		return nil
	}

	// Connect to daemon
	fmt.Println("Connecting to nftband daemon...")
	client := ipc.NewClient()
	if err := client.Ping(); err != nil {
		return fmt.Errorf("daemon not running: %w\nStart with: sudo systemctl start nftband", err)
	}
	fmt.Println("  ✅ Connected to nftband daemon")
	fmt.Println()

	// Load into nftables whitelist via IPC
	fmt.Println("Loading into nftables whitelist sets via daemon...")

	// Combine all CIDRs
	allCIDRs := append(ipv4List, ipv6List...)

	resp, err := client.LoadCIDRs("whitelist", allCIDRs)
	if err != nil {
		return fmt.Errorf("failed to load trust feeds: %w", err)
	}

	if !resp.Success {
		return fmt.Errorf("failed to load trust feeds: %s", resp.Error)
	}

	// Extract results
	data, ok := resp.Data.(map[string]any)
	if !ok {
		return fmt.Errorf("unexpected response format")
	}

	// Show results
	if ipv4Input, ok := data["ipv4_input"].(float64); ok && ipv4Input > 0 {
		if ipv4Ranges, ok := data["ipv4_output_ranges"].(float64); ok {
			if reduction, ok := data["ipv4_reduction_pct"].(float64); ok {
				fmt.Printf("  ✅ IPv4: %.0f CIDRs → %.0f ranges (%.1f%% reduction)\n",
					ipv4Input, ipv4Ranges, reduction)
			}
		}
	}
	if ipv6Input, ok := data["ipv6_input"].(float64); ok && ipv6Input > 0 {
		if ipv6Ranges, ok := data["ipv6_output_ranges"].(float64); ok {
			if reduction, ok := data["ipv6_reduction_pct"].(float64); ok {
				fmt.Printf("  ✅ IPv6: %.0f CIDRs → %.0f ranges (%.1f%% reduction)\n",
					ipv6Input, ipv6Ranges, reduction)
			}
		}
	}

	fmt.Println()
	fmt.Println("✅ Trust feeds loaded into whitelist successfully!")
	fmt.Println("   These IPs will NEVER be blocked by nftban.")
	fmt.Println()

	return nil
}

// getTrustEnabledStatus reads trust config and returns enabled status map.
// Override chain: conf.d/trust.conf → conf.d/trust.conf.local → nftban.conf.local
// Each layer is partial — only values present in the file override previous layers.
func getTrustEnabledStatus(configPath string) map[string]bool {
	enabledMap := make(map[string]bool)

	// Override chain: .conf → .conf.local → nftban.conf.local
	configDir := filepath.Dir(filepath.Dir(configPath)) // conf.d/trust.conf → /etc/nftban
	configFiles := []string{
		configPath,
		configPath + ".local",
		filepath.Join(configDir, "nftban.conf.local"),
	}

	for _, file := range configFiles {
		content, err := os.ReadFile(file)
		if err != nil {
			continue
		}

		lines := strings.Split(string(content), "\n")
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if strings.HasPrefix(line, "TRUST_") && strings.Contains(line, "_ENABLED=") {
				parts := strings.SplitN(line, "=", 2)
				if len(parts) != 2 {
					continue
				}

				varName := parts[0]
				value := strings.Trim(parts[1], `"' `)

				// Extract name: TRUST_<NAME>_ENABLED
				name := strings.TrimPrefix(varName, "TRUST_")
				name = strings.TrimSuffix(name, "_ENABLED")

				enabledMap[name] = (value == "true")
			}
		}
	}

	return enabledMap
}

// downloadTrustFeed downloads a trust feed and returns IP count
func downloadTrustFeed(tf TrustConfig, outputFile string) (int, error) {
	client := &http.Client{
		Timeout: 60 * time.Second,
	}

	var allIPs []string

	// Download main URL
	ips, err := downloadAndParseURL(client, tf.URL, tf.Name)
	if err != nil {
		return 0, err
	}
	allIPs = append(allIPs, ips...)

	// Download IPv6 URL if specified
	if tf.URLv6 != "" {
		fmt.Printf("  URL (v6): %s\n", tf.URLv6)
		ipsv6, err := downloadAndParseURL(client, tf.URLv6, tf.Name)
		if err != nil {
			fmt.Printf("  ⚠️  IPv6 download failed: %v\n", err)
		} else {
			allIPs = append(allIPs, ipsv6...)
		}
	}

	if len(allIPs) == 0 {
		return 0, fmt.Errorf("no valid IPs found")
	}

	// Write to file
	out, err := os.Create(outputFile)
	if err != nil {
		return 0, fmt.Errorf("failed to create output file: %w", err)
	}
	defer out.Close()

	writer := bufio.NewWriter(out)
	for _, ip := range allIPs {
		fmt.Fprintln(writer, ip)
	}
	if err := writer.Flush(); err != nil {
		return 0, fmt.Errorf("flush failed: %w", err)
	}

	return len(allIPs), nil
}

// downloadAndParseURL downloads a URL and extracts IPs based on content type
func downloadAndParseURL(client *http.Client, url, feedName string) ([]string, error) {
	resp, err := client.Get(url)
	if err != nil {
		return nil, fmt.Errorf("HTTP request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("bad HTTP status: %s", resp.Status)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	content := string(body)

	// Detect format and parse accordingly
	trimmed := strings.TrimSpace(content)
	if strings.HasPrefix(trimmed, "{") {
		// JSON format (AWS, Google, Azure, Fastly)
		return parseJSONIPRanges(content, feedName)
	}

	// CSV format (DigitalOcean)
	if strings.Contains(feedName, "DIGITALOCEAN") {
		return parseCSVIPs(content), nil
	}

	// Plain text format (Cloudflare, simple lists)
	return parsePlainTextIPs(content), nil
}

// parseJSONIPRanges parses JSON IP range responses from cloud providers
func parseJSONIPRanges(content, feedName string) ([]string, error) {
	var ips []string

	switch {
	case strings.Contains(feedName, "AWS"):
		// AWS format: {"prefixes": [{"ip_prefix": "..."}], "ipv6_prefixes": [...]}
		var awsData struct {
			Prefixes []struct {
				IPPrefix string `json:"ip_prefix"`
			} `json:"prefixes"`
			IPv6Prefixes []struct {
				IPv6Prefix string `json:"ipv6_prefix"`
			} `json:"ipv6_prefixes"`
		}
		if err := json.Unmarshal([]byte(content), &awsData); err != nil {
			return nil, fmt.Errorf("failed to parse AWS JSON: %w", err)
		}
		for _, p := range awsData.Prefixes {
			ips = append(ips, p.IPPrefix)
		}
		for _, p := range awsData.IPv6Prefixes {
			ips = append(ips, p.IPv6Prefix)
		}

	case strings.Contains(feedName, "GOOGLE"):
		// Google format: {"prefixes": [{"ipv4Prefix": "..."}, {"ipv6Prefix": "..."}]}
		var googleData struct {
			Prefixes []struct {
				IPv4Prefix string `json:"ipv4Prefix"`
				IPv6Prefix string `json:"ipv6Prefix"`
			} `json:"prefixes"`
		}
		if err := json.Unmarshal([]byte(content), &googleData); err != nil {
			return nil, fmt.Errorf("failed to parse Google JSON: %w", err)
		}
		for _, p := range googleData.Prefixes {
			if p.IPv4Prefix != "" {
				ips = append(ips, p.IPv4Prefix)
			}
			if p.IPv6Prefix != "" {
				ips = append(ips, p.IPv6Prefix)
			}
		}

	case strings.Contains(feedName, "FASTLY"):
		// Fastly format: {"addresses": ["..."], "ipv6_addresses": ["..."]}
		var fastlyData struct {
			Addresses     []string `json:"addresses"`
			IPv6Addresses []string `json:"ipv6_addresses"`
		}
		if err := json.Unmarshal([]byte(content), &fastlyData); err != nil {
			return nil, fmt.Errorf("failed to parse Fastly JSON: %w", err)
		}
		ips = append(ips, fastlyData.Addresses...)
		ips = append(ips, fastlyData.IPv6Addresses...)

	case strings.Contains(feedName, "AZURE"):
		// Azure format: {"values": [{"properties": {"addressPrefixes": ["..."]}}]}
		var azureData struct {
			Values []struct {
				Properties struct {
					AddressPrefixes []string `json:"addressPrefixes"`
				} `json:"properties"`
			} `json:"values"`
		}
		if err := json.Unmarshal([]byte(content), &azureData); err != nil {
			return nil, fmt.Errorf("failed to parse Azure JSON: %w", err)
		}
		for _, v := range azureData.Values {
			ips = append(ips, v.Properties.AddressPrefixes...)
		}

	case strings.Contains(feedName, "QUICCLOUD"):
		// QUIC.cloud format: IPs separated by <br /> in HTML
		// Bare IPs (no CIDR) — whitelist parser handles both formats
		cleaned := strings.ReplaceAll(content, "<br />", "\n")
		cleaned = strings.ReplaceAll(cleaned, "<br>", "\n")
		ipv4Pattern := regexp.MustCompile(`^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$`)
		for _, line := range strings.Split(cleaned, "\n") {
			line = strings.TrimSpace(line)
			if ipv4Pattern.MatchString(line) {
				ips = append(ips, line)
			}
		}

	default:
		// Try generic extraction using regex
		ipv4Pattern := regexp.MustCompile(`\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(/\d{1,2})?`)

		matches := ipv4Pattern.FindAllString(content, -1)
		ips = append(ips, matches...)

		// IPv6: use net.ParseIP for validation instead of loose regex
		ipv6Candidate := regexp.MustCompile(`[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{0,4}){2,7}(/\d{1,3})?`)
		matches = ipv6Candidate.FindAllString(content, -1)
		for _, m := range matches {
			// Strip CIDR suffix for validation
			addr := m
			if idx := strings.Index(m, "/"); idx != -1 {
				addr = m[:idx]
			}
			if net.ParseIP(addr) != nil {
				ips = append(ips, m)
			}
		}
	}

	return ips, nil
}

// parseCSVIPs parses CSV IP lists (DigitalOcean format: CIDR in first column)
func parseCSVIPs(content string) []string {
	var ips []string

	ipv4Pattern := regexp.MustCompile(`^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(/\d{1,2})?$`)

	reader := csv.NewReader(strings.NewReader(content))
	reader.FieldsPerRecord = -1 // Variable field count
	reader.LazyQuotes = true
	for {
		record, err := reader.Read()
		if err != nil {
			break
		}
		if len(record) == 0 {
			continue
		}
		cidr := strings.TrimSpace(record[0])
		if ipv4Pattern.MatchString(cidr) {
			ips = append(ips, cidr)
		} else if isValidIPv6CIDR(cidr) {
			ips = append(ips, cidr)
		}
	}

	return ips
}

// parsePlainTextIPs parses plain text IP lists (one per line)
func parsePlainTextIPs(content string) []string {
	var ips []string

	ipv4Pattern := regexp.MustCompile(`^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(/\d{1,2})?$`)

	scanner := bufio.NewScanner(strings.NewReader(content))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		if ipv4Pattern.MatchString(line) || isValidIPv6CIDR(line) {
			ips = append(ips, line)
		}
	}

	return ips
}

// isValidIPv6CIDR validates an IPv6 address or CIDR using net.ParseIP
func isValidIPv6CIDR(s string) bool {
	if !strings.Contains(s, ":") {
		return false
	}
	addr := s
	if idx := strings.Index(s, "/"); idx != -1 {
		_, _, err := net.ParseCIDR(s)
		return err == nil
	}
	return net.ParseIP(addr) != nil
}
