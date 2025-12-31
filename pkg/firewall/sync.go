// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>

package firewall

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"text/template"
	"time"

	"github.com/itcmsgr/nftban/pkg/feeds"
	"github.com/itcmsgr/nftban/pkg/geoban"
	"github.com/itcmsgr/nftban/pkg/model"
	"github.com/itcmsgr/nftban/pkg/nftables"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
)

const (
	// MaxSnapshots is the number of snapshots to keep
	MaxSnapshots = 10
)

// getSyncPaths returns paths from central config
// NO FALLBACK - paths must come from /etc/nftban/nftban.conf
func getSyncPaths() (configDir, dataDir string) {
	cfg := nftbanconf.MustLoad()
	return cfg.ConfigDir, cfg.DataDir
}

// getDefaultStagingDir returns staging directory from central config
func getDefaultStagingDir() string {
	_, dataDir := getSyncPaths()
	return dataDir + "/staging"
}

// getDefaultSnapshotDir returns snapshot directory from central config
func getDefaultSnapshotDir() string {
	_, dataDir := getSyncPaths()
	return dataDir + "/snapshots"
}

// getDefaultWhitelistFile returns whitelist file from central config
func getDefaultWhitelistFile() string {
	configDir, _ := getSyncPaths()
	return configDir + "/whitelist.conf"
}

// getDefaultBlacklistFile returns blacklist file from central config
func getDefaultBlacklistFile() string {
	configDir, _ := getSyncPaths()
	return configDir + "/blacklist.conf"
}

// getDefaultFeedsDir returns feeds directory from central config
func getDefaultFeedsDir() string {
	_, dataDir := getSyncPaths()
	return dataDir + "/feeds"
}

// getDefaultGeobanDir returns geoban directory from central config
func getDefaultGeobanDir() string {
	configDir, _ := getSyncPaths()
	return configDir + "/geoban.d"
}

// getDefaultTemplateFile returns nftables template from central config
func getDefaultTemplateFile() string {
	configDir, _ := getSyncPaths()
	return configDir + "/nftables.conf.tmpl"
}

// SyncOptions configures the atomic reload
type SyncOptions struct {
	StagingDir    string
	SnapshotDir   string
	WhitelistFile string
	BlacklistFile string
	FeedsDir      string
	GeobanDir     string
	TemplateFile  string
	TCPPorts      []int
	UDPPorts      []int
	DryRun        bool // If true, validate only (don't apply)
}

// DefaultSyncOptions returns default sync options
func DefaultSyncOptions() *SyncOptions {
	return &SyncOptions{
		StagingDir:    getDefaultStagingDir(),
		SnapshotDir:   getDefaultSnapshotDir(),
		WhitelistFile: getDefaultWhitelistFile(),
		BlacklistFile: getDefaultBlacklistFile(),
		FeedsDir:      getDefaultFeedsDir(),
		GeobanDir:     getDefaultGeobanDir(),
		TemplateFile:  getDefaultTemplateFile(),
		TCPPorts:      []int{22, 80, 443, 3940},
		UDPPorts:      []int{},
		DryRun:        false,
	}
}

// Sync performs atomic firewall reload
//
// Algorithm (single phase) - v0.7.3 unified architecture:
// 1. Read static config (whitelist, blacklist, ports)
// 2. Build feed sets (Go pkg/feeds) - loaded into unified blacklist
// 3. Build geoban sets (Go pkg/geoban) - loaded into unified blacklist
// 4. Dump runtime sets (temp_whitelist_ipv4/ipv6, blacklist with timeout)
// 5. Generate rules.new.nft
// 6. Validate: nft -c -f rules.new.nft
// 7. Snapshot: nft list ruleset > backup.nft
// 8. Apply: nft -f rules.new.nft
// 9. Restore runtime elements (temp_whitelist, blacklist items with timeout)
func Sync(opts *SyncOptions) error {
	if opts == nil {
		opts = DefaultSyncOptions()
	}

	// Ensure directories exist
	if err := os.MkdirAll(opts.StagingDir, 0750); err != nil {
		return fmt.Errorf("failed to create staging dir: %w", err)
	}
	if err := os.MkdirAll(opts.SnapshotDir, 0750); err != nil {
		return fmt.Errorf("failed to create snapshot dir: %w", err)
	}

	fmt.Println("==> Step 1: Read static config")
	config := model.NewFirewallConfig()

	// Load whitelist
	if whitelist, err := loadIPFile(opts.WhitelistFile); err == nil {
		config.Whitelist = whitelist
		fmt.Printf("    Whitelist: %d IPv4, %d IPv6\n", len(whitelist.IPv4), len(whitelist.IPv6))
	} else {
		fmt.Printf("    WARNING: No whitelist file: %v\n", err)
	}

	// Load blacklist
	if blacklist, err := loadIPFile(opts.BlacklistFile); err == nil {
		config.Blacklist = blacklist
		fmt.Printf("    Blacklist: %d IPv4, %d IPv6\n", len(blacklist.IPv4), len(blacklist.IPv6))
	} else {
		fmt.Printf("    WARNING: No blacklist file: %v\n", err)
	}

	config.TCPPorts = opts.TCPPorts
	config.UDPPorts = opts.UDPPorts

	fmt.Println("\n==> Step 2: Build feed sets")
	feedsData, err := feeds.Build(opts.FeedsDir, nil)
	if err != nil {
		return fmt.Errorf("failed to build feeds: %w", err)
	}
	config.Feeds = feedsData
	for name, data := range feedsData {
		fmt.Printf("    %s: %d IPv4, %d IPv6\n", name, len(data.IPv4), len(data.IPv6))
	}

	fmt.Println("\n==> Step 3: Build geoban sets")
	geobanData, err := geoban.Build(opts.GeobanDir, nil)
	if err != nil {
		return fmt.Errorf("failed to build geoban: %w", err)
	}
	config.Geoban = geobanData
	fmt.Printf("    GeoBan: %d IPv4, %d IPv6\n", len(geobanData.IPv4), len(geobanData.IPv6))

	fmt.Println("\n==> Step 4: Dump runtime sets (Fail2Ban state)")
	runtime, err := dumpRuntimeSets()
	if err != nil {
		fmt.Printf("    WARNING: Failed to dump runtime sets: %v\n", err)
	} else {
		config.RuntimeBans = runtime.Bans
		config.RuntimeWhitelist = runtime.Whitelist
		fmt.Printf("    Runtime bans: %d IPv4, %d IPv6\n", len(runtime.Bans.IPv4), len(runtime.Bans.IPv6))
		fmt.Printf("    Runtime whitelist: %d IPv4, %d IPv6\n", len(runtime.Whitelist.IPv4), len(runtime.Whitelist.IPv6))
	}

	fmt.Println("\n==> Step 5: Generate rules.new.nft")
	rulesPath := filepath.Join(opts.StagingDir, "rules.new.nft")
	if err := generateRuleset(rulesPath, config, opts.TemplateFile); err != nil {
		return fmt.Errorf("failed to generate ruleset: %w", err)
	}
	fmt.Printf("    Written: %s\n", rulesPath)

	fmt.Println("\n==> Step 6: Validate ruleset")
	if err := validateRuleset(rulesPath); err != nil {
		return fmt.Errorf("ruleset validation failed: %w", err)
	}
	fmt.Println("    ✓ Validation passed")

	if opts.DryRun {
		fmt.Println("\n==> DRY RUN: Stopping before apply")
		return nil
	}

	fmt.Println("\n==> Step 7: Snapshot current rules")
	snapshotPath := filepath.Join(opts.SnapshotDir, fmt.Sprintf("snapshot-%s.nft", time.Now().Format("2006-01-02T15-04-05")))
	if err := snapshotRuleset(snapshotPath); err != nil {
		return fmt.Errorf("failed to snapshot ruleset: %w", err)
	}
	fmt.Printf("    Snapshot: %s\n", snapshotPath)

	fmt.Println("\n==> Step 8: Apply new ruleset")
	if err := applyRuleset(rulesPath); err != nil {
		return fmt.Errorf("failed to apply ruleset: %w", err)
	}
	fmt.Println("    ✓ Ruleset applied")

	fmt.Println("\n==> Step 9: Restore runtime elements")
	if runtime != nil {
		if err := restoreRuntimeSets(runtime); err != nil {
			fmt.Printf("    WARNING: Failed to restore runtime sets: %v\n", err)
		} else {
			fmt.Println("    ✓ Runtime state restored")
		}
	}

	fmt.Println("\n==> Step 10: Cleanup old snapshots")
	cleanupSnapshots(opts.SnapshotDir, MaxSnapshots)

	fmt.Println("\n✅ nftban sync COMPLETE")
	return nil
}

// loadIPFile loads IPs from a file (one per line, supports comments)
func loadIPFile(path string) (*model.SetData, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	data := model.NewSetData(filepath.Base(path))
	scanner := bufio.NewScanner(file)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Simple IP/CIDR detection
		if strings.Contains(line, ":") {
			// IPv6
			data.AddIPv6(line)
		} else {
			// IPv4
			data.AddIPv4(line)
		}
	}

	return data, scanner.Err()
}

// RuntimeSets holds current Fail2Ban state
type RuntimeSets struct {
	Bans      *model.SetData
	Whitelist *model.SetData
}

// dumpRuntimeSets reads current runtime sets (v0.7.3 unified architecture)
// v0.7.3: temp_whitelist in main tables, blacklist unified (permanent + temporary with timeout)
func dumpRuntimeSets() (*RuntimeSets, error) {
	runtime := &RuntimeSets{
		Bans:      model.NewSetData("runtime_bans"),
		Whitelist: model.NewSetData("runtime_whitelist"),
	}

	// v0.7.3: Temporary bans are now in unified blacklist_ipv4/ipv6 with timeout
	// NOTE: Cannot distinguish temp from permanent bans via nftables alone (both in same set)
	// Temporary bans have timeout parameter, but nft list doesn't show which IPs have timeout
	// Shell handles this via CLI commands that track metadata separately

	// Dump temp_whitelist_ipv4 (v0.7.3: in main table ip nftban)
	if ips, err := dumpSet(nftables.TableIPv4 + " temp_whitelist_ipv4"); err == nil {
		for _, ip := range ips {
			runtime.Whitelist.AddIPv4(ip)
		}
	}

	// Dump temp_whitelist_ipv6 (v0.7.3: in main table ip6 nftban)
	if ips, err := dumpSet(nftables.TableIPv6 + " temp_whitelist_ipv6"); err == nil {
		for _, ip := range ips {
			runtime.Whitelist.AddIPv6(ip)
		}
	}

	return runtime, nil
}

// dumpSet reads IPs from a nftables set
func dumpSet(setName string) ([]string, error) {
	cmd := exec.Command("nft", "list", "set", setName)
	output, err := cmd.Output()
	if err != nil {
		return nil, err
	}

	var ips []string
	scanner := bufio.NewScanner(bytes.NewReader(output))
	inElements := false

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())

		if strings.HasPrefix(line, "elements = {") {
			inElements = true
			line = strings.TrimPrefix(line, "elements = {")
			line = strings.TrimSuffix(line, "}")
		}

		if inElements {
			// Parse IP addresses (remove timeout, expires, etc)
			fields := strings.Split(line, ",")
			for _, field := range fields {
				field = strings.TrimSpace(field)
				if field == "" || field == "}" {
					continue
				}
				// Remove timeout/expires annotations
				ip := strings.Fields(field)[0]
				ips = append(ips, ip)
			}

			if strings.HasSuffix(line, "}") {
				break
			}
		}
	}

	return ips, nil
}

// generateRuleset creates the nftables configuration file with populated sets
func generateRuleset(path string, config *model.FirewallConfig, templatePath string) error {
	// Read template
	tmplContent, err := os.ReadFile(templatePath)
	if err != nil {
		return fmt.Errorf("failed to read template: %w", err)
	}

	// Parse template
	tmpl, err := template.New("nftables").Parse(string(tmplContent))
	if err != nil {
		return fmt.Errorf("failed to parse template: %w", err)
	}

	// Prepare template data with aggregated feed IPs
	type TemplateData struct {
		*model.FirewallConfig
		FeedIPv4      []string
		FeedIPv6      []string
		FeedIPv4Count int
		FeedIPv6Count int
	}

	data := &TemplateData{FirewallConfig: config}

	// Aggregate all feed IPs into flat arrays
	for _, feedData := range config.Feeds {
		data.FeedIPv4 = append(data.FeedIPv4, feedData.IPv4...)
		data.FeedIPv6 = append(data.FeedIPv6, feedData.IPv6...)
	}
	data.FeedIPv4Count = len(data.FeedIPv4)
	data.FeedIPv6Count = len(data.FeedIPv6)

	// Render template with enhanced data
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, data); err != nil {
		return fmt.Errorf("failed to execute template: %w", err)
	}

	// Write to file
	return os.WriteFile(path, buf.Bytes(), 0640)
}

// validateRuleset runs nft -c -f to validate
func validateRuleset(path string) error {
	cmd := exec.Command("nft", "-c", "-f", path)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, output)
	}
	return nil
}

// snapshotRuleset saves current ruleset to file
func snapshotRuleset(path string) error {
	cmd := exec.Command("nft", "list", "ruleset")
	output, err := cmd.Output()
	if err != nil {
		return err
	}

	return os.WriteFile(path, output, 0640)
}

// applyRuleset applies the new ruleset
func applyRuleset(path string) error {
	cmd := exec.Command("nft", "-f", path)
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, output)
	}
	return nil
}

// restoreRuntimeSets re-adds runtime elements after atomic reload (v0.7.3)
func restoreRuntimeSets(runtime *RuntimeSets) error {
	// v0.7.3: temp_whitelist moved to main tables (ip/ip6 nftban)
	// v0.7.3: temp bans handled via CLI (tracks timeout metadata externally)

	// Restore temp_whitelist_ipv4 (v0.7.3: in main table ip nftban)
	for _, ip := range runtime.Whitelist.IPv4 {
		cmd := exec.Command("nft", "add", "element", "ip", "nftban", "temp_whitelist_ipv4", fmt.Sprintf("{ %s }", ip))
		if err := cmd.Run(); err != nil {
			fmt.Printf("WARNING: Failed to restore whitelist %s: %v\n", ip, err)
		}
	}

	// Restore temp_whitelist_ipv6 (v0.7.3: in main table ip6 nftban)
	for _, ip := range runtime.Whitelist.IPv6 {
		cmd := exec.Command("nft", "add", "element", "ip6", "nftban", "temp_whitelist_ipv6", fmt.Sprintf("{ %s }", ip))
		if err := cmd.Run(); err != nil {
			fmt.Printf("WARNING: Failed to restore whitelist %s: %v\n", ip, err)
		}
	}

	// NOTE: Temporary bans no longer restored here in v0.7.3
	// Rationale: Temp bans are in unified blacklist_ipv4/ipv6 with timeout
	// nft-sync loads blacklist from config files (which includes active bans)
	// Fail2Ban re-adds bans via CLI if they're still active
	// This prevents stale ban restoration and ensures metadata consistency

	return nil
}

// cleanupSnapshots keeps only the N most recent snapshots
func cleanupSnapshots(dir string, keep int) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return
	}

	if len(entries) <= keep {
		return
	}

	// Remove oldest files
	for i := 0; i < len(entries)-keep; i++ {
		path := filepath.Join(dir, entries[i].Name())
		os.Remove(path)
	}
}
