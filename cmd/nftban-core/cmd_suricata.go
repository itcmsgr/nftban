// =============================================================================
// NFTBan - Suricata Integration Command
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_suricata"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Suricata IDS integration with profile, rules, and filter management"
// meta:input="Subcommand (status, filters, daemon, enable, disable, profile-*, scan, rules-*, sid-*, custom-*, recommend)"
// meta:output="Console output with Suricata configuration and status"
// meta:depends="github.com/itcmsgr/nftban/pkg/suricata,github.com/itcmsgr/nftban/pkg/analytics,github.com/itcmsgr/nftban/pkg/nftbanconf"
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

	"github.com/itcmsgr/nftban/pkg/analytics"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/suricata"
	"github.com/itcmsgr/nftban/pkg/suricata/config"
	"github.com/itcmsgr/nftban/pkg/suricata/customrules"
	"github.com/itcmsgr/nftban/pkg/suricata/profile"
	"github.com/itcmsgr/nftban/pkg/suricata/recommendations"
	"github.com/itcmsgr/nftban/pkg/suricata/rules"
	"github.com/itcmsgr/nftban/pkg/suricata/scanner"
	"github.com/itcmsgr/nftban/pkg/suricata/stats"
	"github.com/itcmsgr/nftban/pkg/version"
)

// getSuricataPaths returns suricata-related paths from passed config
// Note: Suricata itself uses /etc/suricata (external dependency, not nftban config)
func getSuricataPaths(cfg *nftbanconf.Config) (suricataConfigDir, evePath, logDir, dataDir string) {
	// Suricata itself uses /etc/suricata (external dependency, not nftban config)
	suricataConfigDir = "/etc/suricata"
	// NFTBan alert-only EVE output (daemon reads this file)
	evePath = "/var/log/nftban/suricata/eve-alerts.json"
	logDir = cfg.LogDir
	dataDir = cfg.DataDir
	return
}

func cmdSuricata(action string, cfg *nftbanconf.Config) error {
	switch action {
	case "status":
		return cmdSuricataStatus(cfg)
	case "filters":
		return cmdSuricataFilters(cfg)
	case "daemon":
		return cmdSuricataDaemon()
	case "enable":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core suricata enable <FILTER_NAME>")
		}
		filterName := os.Args[3]
		return cmdSuricataEnable(cfg, filterName, true)
	case "disable":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core suricata disable <FILTER_NAME>")
		}
		filterName := os.Args[3]
		return cmdSuricataEnable(cfg, filterName, false)
	case "set-threshold":
		if len(os.Args) < 5 {
			return fmt.Errorf("usage: nftban-core suricata set-threshold <FILTER_NAME> <THRESHOLD>")
		}
		filterName := os.Args[3]
		var threshold int
		if _, err := fmt.Sscanf(os.Args[4], "%d", &threshold); err != nil {
			return fmt.Errorf("invalid threshold: %w", err)
		}
		return cmdSuricataSetThreshold(cfg, filterName, threshold)
	case "set-action":
		if len(os.Args) < 5 {
			return fmt.Errorf("usage: nftban-core suricata set-action <FILTER_NAME> <ACTION>")
		}
		filterName := os.Args[3]
		actionArg := os.Args[4]
		return cmdSuricataSetAction(cfg, filterName, actionArg)

	// NEW: Profile Management
	case "profile-detect":
		return cmdSuricataProfileDetect()
	case "profile-apply":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core suricata profile-apply <PROFILE>")
		}
		profileName := os.Args[3]
		return cmdSuricataProfileApply(profileName)
	case "profile-show":
		return cmdSuricataProfileShow()
	case "profile-validate":
		return cmdSuricataProfileValidate()

	// NEW: Service Scanner
	case "scan":
		return cmdSuricataScan()
	case "scan-deep":
		return cmdSuricataScanDeep()

	// NEW: Rules Management
	case "rules-generate":
		return cmdSuricataRulesGenerate()
	case "rules-stats":
		return cmdSuricataRulesStats()
	case "rules-init":
		return cmdSuricataRulesInit()

	// NEW: SID Statistics
	case "sid-stats":
		return cmdSuricataSIDStats()
	case "sid-info":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core suricata sid-info <SID>")
		}
		return cmdSuricataSIDInfo(os.Args[3])
	case "sid-top":
		return cmdSuricataSIDTop()
	case "sid-recent":
		return cmdSuricataSIDRecent()
	case "stats-daemon":
		return cmdSuricataStatsDaemon()

	// NEW: Custom Rules Management
	case "custom-add":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core suricata custom-add <RULE>")
		}
		return cmdSuricataCustomAdd(os.Args[3])
	case "custom-remove":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core suricata custom-remove <SID>")
		}
		var sid int
		if _, err := fmt.Sscanf(os.Args[3], "%d", &sid); err != nil {
			return fmt.Errorf("invalid SID: %w", err)
		}
		return cmdSuricataCustomRemove(sid)
	case "custom-edit":
		if len(os.Args) < 5 {
			return fmt.Errorf("usage: nftban-core suricata custom-edit <SID> <NEW_RULE>")
		}
		var sid int
		if _, err := fmt.Sscanf(os.Args[3], "%d", &sid); err != nil {
			return fmt.Errorf("invalid SID: %w", err)
		}
		return cmdSuricataCustomEdit(sid, os.Args[4])
	case "custom-list":
		return cmdSuricataCustomList()
	case "custom-validate":
		return cmdSuricataCustomValidate()
	case "custom-enable":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core suricata custom-enable <SID>")
		}
		var sid int
		if _, err := fmt.Sscanf(os.Args[3], "%d", &sid); err != nil {
			return fmt.Errorf("invalid SID: %w", err)
		}
		return cmdSuricataCustomEnable(sid)
	case "custom-disable":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core suricata custom-disable <SID>")
		}
		var sid int
		if _, err := fmt.Sscanf(os.Args[3], "%d", &sid); err != nil {
			return fmt.Errorf("invalid SID: %w", err)
		}
		return cmdSuricataCustomDisable(sid)
	case "custom-backup":
		return cmdSuricataCustomBackup()
	case "custom-rollback":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core suricata custom-rollback <BACKUP_NAME>")
		}
		return cmdSuricataCustomRollback(os.Args[3])

	// NEW: Recommendations Engine
	case "recommend":
		return cmdSuricataRecommend()
	case "recommend-summary":
		return cmdSuricataRecommendSummary()

	default:
		return fmt.Errorf("unknown suricata action: %s\nUsage: nftban-core suricata [status|filters|daemon|enable|disable|set-threshold|set-action|profile-detect|profile-apply|profile-show|profile-validate|scan|scan-deep|rules-generate|rules-stats|rules-init|sid-stats|sid-info|sid-top|sid-recent|stats-daemon|custom-add|custom-remove|custom-edit|custom-list|custom-validate|custom-enable|custom-disable|custom-backup|custom-rollback|recommend|recommend-summary]", action)
	}
}

// cmdSuricataStatus shows Suricata integration status
func cmdSuricataStatus(cfg *nftbanconf.Config) error {
	fmt.Println(version.BannerWithEmoji("🛡️", "Suricata Integration Status"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Load config
	configDir, _, _, _ := getSuricataPaths(cfg)
	suricataCfg, err := suricata.LoadConfig(configDir)
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	// Global status
	fmt.Println("Global Configuration:")
	fmt.Printf("  Enabled:          %v\n", suricataCfg.GlobalEnabled)
	fmt.Printf("  Default Threshold: %d points\n", suricataCfg.DefaultThreshold)
	fmt.Printf("  Default Ban Time:  %s\n", suricataCfg.DefaultBanTime)
	fmt.Printf("  Default Action:    %s\n", suricataCfg.DefaultAction)
	fmt.Printf("  Score Decay:       %s\n", suricataCfg.ScoreDecay)
	fmt.Println()

	// Filter counts
	enabledFilters := suricataCfg.GetEnabledFilters()
	totalFilters := len(suricataCfg.Filters)
	enabledCount := len(enabledFilters)
	disabledCount := totalFilters - enabledCount

	fmt.Println("Filter Summary:")
	fmt.Printf("  Total Filters:    %d\n", totalFilters)
	fmt.Printf("  Enabled:          %d\n", enabledCount)
	fmt.Printf("  Disabled:         %d\n", disabledCount)
	fmt.Println()

	// Eve.json path
	_, evePath, _, _ := getSuricataPaths(cfg)
	if _, err := os.Stat(evePath); err == nil {
		fmt.Printf("✅ Eve log found: %s\n", evePath)
	} else {
		fmt.Printf("❌ Eve log not found: %s\n", evePath)
	}
	fmt.Println()

	return nil
}

// cmdSuricataFilters lists all configured filters
func cmdSuricataFilters(cfg *nftbanconf.Config) error {
	fmt.Println(version.BannerWithEmoji("🛡️", "Suricata Filters"))
	fmt.Println(strings.Repeat("=", 100))
	fmt.Println()

	// Load config
	configDir, _, _, _ := getSuricataPaths(cfg)
	suricataCfg, err := suricata.LoadConfig(configDir)
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	// Create table writer
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "FILTER\tENABLED\tTHRESHOLD\tBAN TIME\tACTION\tBAN TYPE\tDESCRIPTION")
	fmt.Fprintln(w, "------\t-------\t---------\t--------\t------\t--------\t-----------")

	// Print each filter
	for name, filter := range suricataCfg.Filters {
		enabled := "✗"
		if filter.Enabled {
			enabled = "✓"
		}

		// Format ban type for display
		banTypeDisplay := filter.BanType
		if filter.BanType == "escalate" {
			banTypeDisplay = fmt.Sprintf("escalate:%d:%s", filter.MaxBans, filter.Period)
		}

		fmt.Fprintf(w, "%s\t%s\t%d\t%s\t%s\t%s\t%s\n",
			name,
			enabled,
			filter.Threshold,
			filter.BanTime,
			filter.Action,
			banTypeDisplay,
			filter.Description,
		)
	}

	_ = w.Flush()
	fmt.Println()
	fmt.Println("Legend:")
	fmt.Println("  Action modes:")
	fmt.Println("    log     - Log events only (testing, no bans)")
	fmt.Println("    observe - Log and track scores (tuning, no bans)")
	fmt.Println("    ban     - Ban IPs when threshold exceeded (production)")
	fmt.Println()
	fmt.Println("  Ban types:")
	fmt.Println("    temporary       - Always ban for ban_time duration")
	fmt.Println("    permanent       - Always ban permanently (forever)")
	fmt.Println("    escalate:N:T    - Ban temp initially, permanent after N bans in time T")
	fmt.Println()
	fmt.Println("Tip: Edit /etc/suricata/filters.conf.local to customize filters")
	fmt.Println()

	return nil
}

// cmdSuricataEnable enables/disables a filter
func cmdSuricataEnable(cfg *nftbanconf.Config, filterName string, enable bool) error {
	configDir, _, _, _ := getSuricataPaths(cfg)
	localPath := configDir + "/filters.conf.local"

	// Load existing config
	suricataCfg, err := suricata.LoadConfig(configDir)
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	// Check if filter exists
	filter, ok := suricataCfg.GetFilter(filterName)
	if !ok {
		return fmt.Errorf("filter '%s' not found", filterName)
	}

	// Update filter
	filter.Enabled = enable

	// Write to .local file
	if err := appendFilterToLocal(localPath, filter); err != nil {
		return fmt.Errorf("failed to update config: %w", err)
	}

	action := "disabled"
	if enable {
		action = "enabled"
	}

	fmt.Printf("✅ Filter '%s' %s\n", filterName, action)
	fmt.Printf("   Updated: %s\n", localPath)
	fmt.Println("   Reload required: nftban-core reload (not implemented yet)")
	fmt.Println()

	return nil
}

// cmdSuricataSetThreshold sets the threshold for a filter
func cmdSuricataSetThreshold(cfg *nftbanconf.Config, filterName string, threshold int) error {
	configDir, _, _, _ := getSuricataPaths(cfg)
	localPath := configDir + "/filters.conf.local"

	// Load existing config
	suricataCfg, err := suricata.LoadConfig(configDir)
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	// Check if filter exists
	filter, ok := suricataCfg.GetFilter(filterName)
	if !ok {
		return fmt.Errorf("filter '%s' not found", filterName)
	}

	oldThreshold := filter.Threshold
	filter.Threshold = threshold

	// Write to .local file
	if err := appendFilterToLocal(localPath, filter); err != nil {
		return fmt.Errorf("failed to update config: %w", err)
	}

	fmt.Printf("✅ Filter '%s' threshold updated: %d → %d\n", filterName, oldThreshold, threshold)
	fmt.Printf("   Updated: %s\n", localPath)
	fmt.Println("   Reload required: nftban-core reload (not implemented yet)")
	fmt.Println()

	return nil
}

// cmdSuricataSetAction sets the action for a filter
func cmdSuricataSetAction(cfg *nftbanconf.Config, filterName string, action string) error {
	// Validate action
	if action != "log" && action != "observe" && action != "ban" {
		return fmt.Errorf("invalid action '%s' (must be log/observe/ban)", action)
	}

	configDir, _, _, _ := getSuricataPaths(cfg)
	localPath := configDir + "/filters.conf.local"

	// Load existing config
	suricataCfg, err := suricata.LoadConfig(configDir)
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	// Check if filter exists
	filter, ok := suricataCfg.GetFilter(filterName)
	if !ok {
		return fmt.Errorf("filter '%s' not found", filterName)
	}

	oldAction := filter.Action
	filter.Action = action

	// Write to .local file
	if err := appendFilterToLocal(localPath, filter); err != nil {
		return fmt.Errorf("failed to update config: %w", err)
	}

	fmt.Printf("✅ Filter '%s' action updated: %s → %s\n", filterName, oldAction, action)
	fmt.Printf("   Updated: %s\n", localPath)

	// Explain what this means
	switch action {
	case "log":
		fmt.Println("   Mode: LOG ONLY - events logged, no banning (safe for testing)")
	case "observe":
		fmt.Println("   Mode: OBSERVE - scores tracked, no banning (tuning thresholds)")
	case "ban":
		fmt.Println("   Mode: BAN - IPs banned when threshold exceeded (production)")
	}

	fmt.Println("   Reload required: nftban-core reload (not implemented yet)")
	fmt.Println()

	return nil
}

// cmdSuricataDaemon runs the Suricata processor in daemon mode
func cmdSuricataDaemon() error {
	// Check for privilege (root OR CAP_NET_ADMIN capability)
	if err := checkPrivilege(); err != nil {
		return err
	}

	fmt.Println(version.BannerWithEmoji("🛡️", "Suricata Daemon"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Initialize analytics (for ban tracking)
	// Note: main.go only initializes for "ban" and "analytics" commands
	// We need it for "suricata daemon" too
	if err := initAnalyticsIfNeeded(); err != nil {
		fmt.Printf("⚠️  Analytics disabled: %v\n", err)
	} else {
		fmt.Println("✅ Analytics enabled")
		// Ensure we save on exit
		defer saveAnalyticsIfNeeded()
	}
	fmt.Println()

	// Create ban handler using IPC to nftband daemon
	banHandler, err := suricata.NewNetlinkBanHandler()
	if err != nil {
		return fmt.Errorf("failed to create ban handler: %w", err)
	}
	defer banHandler.Close()

	// Create processor
	nftbanCfg := nftbanconf.MustLoad()
	suricataConfigDir, evePath, logDir, _ := getSuricataPaths(nftbanCfg)
	processorCfg := &suricata.ProcessorConfig{
		ConfigDir:  suricataConfigDir,
		EvePath:    evePath,
		LogPath:    logDir + "/suricata-events.log",
		BanHandler: banHandler,
	}

	processor, err := suricata.NewProcessor(processorCfg)
	if err != nil {
		return fmt.Errorf("failed to create processor: %w", err)
	}

	// Start processor
	if err := processor.Start(); err != nil {
		return fmt.Errorf("failed to start processor: %w", err)
	}

	// Setup signal handling for graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	fmt.Println("✅ Daemon started - Press Ctrl+C to stop")
	fmt.Println()

	// Wait for signal
	sig := <-sigChan
	fmt.Printf("\n📡 Received signal: %v\n", sig)

	// Stop processor
	if err := processor.Stop(); err != nil {
		return fmt.Errorf("failed to stop processor: %w", err)
	}

	fmt.Println("✅ Daemon stopped gracefully")
	return nil
}

// appendFilterToLocal appends a filter configuration to the .local file
func appendFilterToLocal(localPath string, filter *suricata.FilterConfig) error {
	// Read existing .local file
	var existingLines []string
	if data, err := os.ReadFile(localPath); err == nil {
		existingLines = strings.Split(string(data), "\n")
	}

	// Remove existing entry for this filter
	newLines := []string{}
	inFiltersSection := false
	for _, line := range existingLines {
		trimmed := strings.TrimSpace(line)

		// Track if we're in [filters] section
		if trimmed == "[filters]" {
			inFiltersSection = true
			newLines = append(newLines, line)
			continue
		}
		if strings.HasPrefix(trimmed, "[") && trimmed != "[filters]" {
			inFiltersSection = false
		}

		// Skip line if it's this filter
		if inFiltersSection && strings.HasPrefix(trimmed, filter.Name+" =") {
			continue
		}

		newLines = append(newLines, line)
	}

	// Add [filters] section if not present
	hasFiltersSection := false
	for _, line := range newLines {
		if strings.TrimSpace(line) == "[filters]" {
			hasFiltersSection = true
			break
		}
	}

	if !hasFiltersSection {
		newLines = append(newLines, "", "[filters]")
	}

	// Format filter line
	keywords := strings.Join(filter.Keywords, ",")
	enabled := "false"
	if filter.Enabled {
		enabled = "true"
	}

	// Format ban type
	banTypeStr := filter.BanType
	if filter.BanType == "escalate" {
		banTypeStr = fmt.Sprintf("escalate:%d:%s", filter.MaxBans, filter.Period)
	}

	filterLine := fmt.Sprintf("%s = %s | %s | %d | %s | %s | %s | %s",
		filter.Name,
		enabled,
		keywords,
		filter.Threshold,
		filter.BanTime,
		filter.Action,
		banTypeStr,
		filter.Description,
	)

	// Append new filter line
	newLines = append(newLines, filterLine)

	// Write back to file
	content := strings.Join(newLines, "\n")
	if err := os.WriteFile(localPath, []byte(content), 0644); err != nil {
		return fmt.Errorf("failed to write file: %w", err)
	}

	return nil
}

// initAnalyticsIfNeeded initializes analytics if not already done
func initAnalyticsIfNeeded() error {
	if analytics.StateOrNil() != nil {
		return nil // Already initialized
	}
	cfg := nftbanconf.MustLoad()
	_, _, _, dataDir := getSuricataPaths(cfg)
	return analytics.Init(dataDir, dataDir+"/reports")
}

// saveAnalyticsIfNeeded saves analytics state if initialized
func saveAnalyticsIfNeeded() {
	if st := analytics.StateOrNil(); st != nil {
		if err := st.Save(); err != nil {
			log.Printf("Warning: Failed to save analytics: %v", err)
		}
	}
}

// =============================================================================
// PROFILE MANAGEMENT COMMANDS (NEW)
// =============================================================================

// cmdSuricataProfileDetect auto-detects the optimal profile based on system resources
func cmdSuricataProfileDetect() error {
	fmt.Println(version.BannerWithEmoji("🔍", "Suricata Profile Auto-Detection"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	result, err := profile.DetectOptimalProfile()
	if err != nil {
		return fmt.Errorf("failed to detect profile: %w", err)
	}

	fmt.Println("System Resources:")
	fmt.Printf("  CPU Cores:    %d\n", result.CPUCount)
	fmt.Printf("  Total RAM:    %.1f GB\n", result.RAMGB)
	fmt.Println()

	fmt.Println("Recommended Profile:", result.ProfileStr)
	fmt.Println()

	spec := profile.GetProfileSpec(result.Profile)
	fmt.Println("Profile Characteristics:")
	fmt.Printf("  Ring Size:        %d frames\n", spec.RingSize)
	fmt.Printf("  Flow Timeout:     %d seconds\n", spec.FlowTimeout)
	fmt.Printf("  HTTP Body Limit:  %s\n", spec.HTTPBodyLimit)
	fmt.Printf("  Detect Profile:   %s\n", spec.DetectProfile)
	fmt.Printf("  Use Case:         %s\n", spec.UseCase)
	fmt.Println()

	fmt.Println("Reason:", result.Reason)
	fmt.Println()

	fmt.Println("To apply this profile:")
	fmt.Printf("  nftban-core suricata profile-apply %s\n", result.ProfileStr)
	fmt.Println()

	return nil
}

// cmdSuricataProfileApply applies the specified profile (creates symlink)
func cmdSuricataProfileApply(profileName string) error {
	prof, err := profile.ProfileFromString(profileName)
	if err != nil {
		return fmt.Errorf("invalid profile name: %w", err)
	}

	fmt.Println(version.BannerWithEmoji("⚙️", "Applying Suricata Profile"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Check if profile templates exist
	if err := profile.EnsureProfilesExist(); err != nil {
		return fmt.Errorf("profile templates not found: %w\nRun: nftban suricata install", err)
	}

	// Apply profile (create symlink)
	if err := profile.ApplyProfile(prof); err != nil {
		return fmt.Errorf("failed to apply profile: %w", err)
	}

	spec := profile.GetProfileSpec(prof)

	fmt.Printf("✅ Profile Applied: %s\n", prof.String())
	fmt.Println()
	fmt.Println("Configuration:")

	yamlPath, _ := profile.GetProfileYAMLPath(prof)
	configPath, _ := profile.GetSuricataConfigPath()
	fmt.Printf("  YAML Template:    %s\n", yamlPath)
	fmt.Printf("  Active Config:    %s (symlink)\n", configPath)
	fmt.Println()

	fmt.Println("Profile Details:")
	fmt.Printf("  Minimum CPU:      %d cores\n", spec.MinCPU)
	fmt.Printf("  Minimum RAM:      %.1f GB\n", spec.MinRAMGB)
	fmt.Printf("  Ring Size:        %d frames\n", spec.RingSize)
	fmt.Printf("  Flow Timeout:     %d seconds\n", spec.FlowTimeout)
	fmt.Printf("  HTTP Body Limit:  %s\n", spec.HTTPBodyLimit)
	fmt.Printf("  Detect Profile:   %s\n", spec.DetectProfile)
	fmt.Println()

	fmt.Println("⚠️  Restart required:")
	fmt.Println("  systemctl restart suricata")
	fmt.Println()

	return nil
}

// cmdSuricataProfileShow displays the current active profile
func cmdSuricataProfileShow() error {
	fmt.Println(version.BannerWithEmoji("📋", "Current Suricata Profile"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	currentProfile, err := profile.GetCurrentProfile()
	if err != nil {
		fmt.Printf("⚠️  No active profile: %v\n", err)
		fmt.Println()
		fmt.Println("To set up a profile:")
		fmt.Println("  1. Auto-detect:  nftban-core suricata profile-detect")
		fmt.Println("  2. Apply:        nftban-core suricata profile-apply <PROFILE>")
		fmt.Println()
		return nil
	}

	spec := profile.GetProfileSpec(currentProfile)

	fmt.Printf("Active Profile: %s\n", currentProfile.String())
	fmt.Println()

	fmt.Println("Configuration:")
	yamlPath, _ := profile.GetProfileYAMLPath(currentProfile)
	configPath, _ := profile.GetSuricataConfigPath()
	fmt.Printf("  YAML Template:    %s\n", yamlPath)
	fmt.Printf("  Active Config:    %s (symlink)\n", configPath)
	fmt.Println()

	fmt.Println("Profile Specifications:")
	fmt.Printf("  Target Hardware:  %d+ cores, %.1f+ GB RAM\n", spec.MinCPU, spec.MinRAMGB)
	fmt.Printf("  Ring Size:        %d frames\n", spec.RingSize)
	fmt.Printf("  Flow Timeout:     %d seconds (established)\n", spec.FlowTimeout)
	fmt.Printf("  HTTP Body Limit:  %s\n", spec.HTTPBodyLimit)
	fmt.Printf("  Detect Profile:   %s\n", spec.DetectProfile)
	fmt.Printf("  Use Case:         %s\n", spec.UseCase)
	fmt.Println()

	// Show system resources
	result, err := profile.DetectOptimalProfile()
	if err == nil {
		fmt.Println("System Resources:")
		fmt.Printf("  CPU Cores:        %d\n", result.CPUCount)
		fmt.Printf("  Total RAM:        %.1f GB\n", result.RAMGB)
		fmt.Println()

		// Check if current profile matches recommendation
		if result.Profile != currentProfile {
			fmt.Printf("💡 Recommendation: Consider switching to '%s' profile\n", result.ProfileStr)
			fmt.Printf("   Reason: %s\n", result.Reason)
			fmt.Println()
			fmt.Printf("   To apply: nftban-core suricata profile-apply %s\n", result.ProfileStr)
			fmt.Println()
		} else {
			fmt.Println("✅ Current profile matches system resources")
			fmt.Println()
		}
	}

	return nil
}

// cmdSuricataProfileValidate validates the current profile configuration
func cmdSuricataProfileValidate() error {
	if err := profile.ValidateProfile(); err != nil {
		fmt.Printf("❌ Profile validation failed: %v\n", err)
		return err
	}

	fmt.Println("✅ Profile configuration is valid")
	return nil
}

// =============================================================================
// SERVICE SCANNER COMMANDS (PHASE 2)
// =============================================================================

// cmdSuricataScan performs basic localhost service scan
func cmdSuricataScan() error {
	fmt.Println(version.BannerWithEmoji("🔍", "Suricata Service Scanner"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Perform scan
	result, err := scanner.ScanLocalhost()
	if err != nil {
		return fmt.Errorf("scan failed: %w", err)
	}

	// Display results
	fmt.Println(result.GetServiceSummary())

	// Generate auto.conf
	fmt.Println()
	fmt.Println("Generating auto-configuration...")
	if err := config.GenerateAutoConf(result); err != nil {
		return fmt.Errorf("failed to generate auto.conf: %w", err)
	}

	// Merge configs
	if err := config.MergeConfigs(); err != nil {
		return fmt.Errorf("failed to merge configs: %w", err)
	}

	fmt.Println()
	fmt.Println("✅ Service scan complete!")
	fmt.Println()
	fmt.Println("Next step: nftban suricata rules generate")
	fmt.Println()

	return nil
}

// cmdSuricataScanDeep performs deep protocol probing
func cmdSuricataScanDeep() error {
	fmt.Println(version.BannerWithEmoji("🔬", "Suricata Deep Service Scan"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Perform deep scan
	result, err := scanner.DeepScan("127.0.0.1", scanner.CommonPorts)
	if err != nil {
		return fmt.Errorf("deep scan failed: %w", err)
	}

	// Display results
	fmt.Println(result.GetServiceSummary())

	// Generate auto.conf
	fmt.Println()
	fmt.Println("Generating auto-configuration...")
	if err := config.GenerateAutoConf(result); err != nil {
		return fmt.Errorf("failed to generate auto.conf: %w", err)
	}

	// Merge configs
	if err := config.MergeConfigs(); err != nil {
		return fmt.Errorf("failed to merge configs: %w", err)
	}

	fmt.Println()
	fmt.Println("✅ Deep scan complete!")
	fmt.Println()
	fmt.Println("Next step: nftban suricata rules generate")
	fmt.Println()

	return nil
}

// =============================================================================
// RULES MANAGEMENT COMMANDS (PHASE 2)
// =============================================================================

// cmdSuricataRulesGenerate generates enabled.list from effective config
func cmdSuricataRulesGenerate() error {
	fmt.Println(version.BannerWithEmoji("📝", "Generating Suricata Rules List"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Generate enabled.list
	if err := rules.GenerateEnabledList(); err != nil {
		return fmt.Errorf("failed to generate enabled.list: %w", err)
	}

	// Show stats
	stats, err := rules.GetRuleStats()
	if err != nil {
		return fmt.Errorf("failed to get stats: %w", err)
	}

	fmt.Println()
	fmt.Println("Statistics:")
	fmt.Printf("  Total Categories:   %d\n", stats["total_categories"])
	fmt.Printf("  Enabled Categories: %d\n", stats["enabled_categories"])
	fmt.Printf("  Enabled Rule Files: %d\n", stats["enabled_rule_files"])
	fmt.Printf("  Custom Rules:       %v\n", stats["custom_rules_exist"])
	fmt.Println()

	fmt.Println("✅ Rules list generated successfully!")
	fmt.Println()
	fmt.Println("⚠️  Restart Suricata to apply changes:")
	fmt.Println("  systemctl restart suricata")
	fmt.Println()

	return nil
}

// cmdSuricataRulesStats displays rule statistics
func cmdSuricataRulesStats() error {
	fmt.Println(version.BannerWithEmoji("📊", "Suricata Rules Statistics"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	stats, err := rules.GetRuleStats()
	if err != nil {
		return fmt.Errorf("failed to get stats: %w", err)
	}

	fmt.Println("Rules Configuration:")
	fmt.Printf("  Total Categories Available: %d\n", stats["total_categories"])
	fmt.Printf("  Enabled Categories:         %d\n", stats["enabled_categories"])
	fmt.Printf("  Enabled Rule Files:         %d\n", stats["enabled_rule_files"])
	fmt.Printf("  Custom Rules Exist:         %v\n", stats["custom_rules_exist"])
	fmt.Printf("  Enabled List Path:          %s\n", stats["enabled_list_path"])
	fmt.Println()

	reduction := 0
	if total, ok := stats["total_categories"].(int); ok && total > 0 {
		if enabled, ok := stats["enabled_categories"].(int); ok {
			reduction = int((float64(total-enabled) / float64(total)) * 100)
		}
	}

	if reduction > 0 {
		fmt.Printf("💡 Rule reduction: %d%% (loading only relevant rules)\n", reduction)
		fmt.Println()
	}

	return nil
}

// cmdSuricataRulesInit initializes config files
func cmdSuricataRulesInit() error {
	fmt.Println(version.BannerWithEmoji("🔧", "Initializing Suricata Configuration"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Initialize local.conf
	if err := config.InitializeLocalConf(); err != nil {
		return fmt.Errorf("failed to initialize local.conf: %w", err)
	}

	// Initialize custom.rules
	if err := rules.InitializeCustomRules(); err != nil {
		return fmt.Errorf("failed to initialize custom.rules: %w", err)
	}

	fmt.Println()
	fmt.Println("✅ Configuration files initialized!")
	fmt.Println()
	fmt.Println("Next steps:")
	fmt.Println("  1. Scan services:    nftban suricata scan")
	fmt.Println("  2. Generate rules:   nftban suricata rules generate")
	fmt.Println("  3. Restart Suricata: systemctl restart suricata")
	fmt.Println()

	return nil
}

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

// cmdSuricataCustomAdd adds a new custom rule
func cmdSuricataCustomAdd(rule string) error {
	fmt.Println(version.BannerWithEmoji("➕", "Add Custom Suricata Rule"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create manager
	manager, err := customrules.NewManager()
	if err != nil {
		return fmt.Errorf("failed to create manager: %w", err)
	}

	// Add rule
	result, err := manager.AddRule(rule)
	if err != nil {
		if result != nil && len(result.Errors) > 0 {
			fmt.Println("✗ Validation failed:")
			for _, e := range result.Errors {
				fmt.Printf("  - %s\n", e)
			}
		}
		return err
	}

	fmt.Printf("✓ Custom rule added successfully\n\n")
	fmt.Printf("SID:     %d\n", result.SID)
	fmt.Printf("Action:  %s\n", result.Action)
	fmt.Printf("Message: %s\n", result.Message)
	fmt.Println()
	fmt.Println("Next steps:")
	fmt.Println("  1. Reload Suricata: systemctl reload suricata")
	fmt.Println("  2. Monitor alerts: nftban suricata sid info", result.SID)
	fmt.Println()

	return nil
}

// cmdSuricataCustomRemove removes a custom rule
func cmdSuricataCustomRemove(sid int) error {
	fmt.Println(version.BannerWithEmoji("🗑️", "Remove Custom Suricata Rule"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create manager
	manager, err := customrules.NewManager()
	if err != nil {
		return fmt.Errorf("failed to create manager: %w", err)
	}

	// Get rule details before removal
	rule, err := manager.GetRule(sid)
	if err != nil {
		return err
	}

	fmt.Printf("Removing SID %d: %s\n", sid, rule.Message)
	fmt.Println()

	// Remove rule
	if err := manager.RemoveRule(sid); err != nil {
		return err
	}

	fmt.Println("✓ Custom rule removed successfully")
	fmt.Println()
	fmt.Println("Backup created before removal")
	fmt.Println("To undo: nftban suricata custom rollback")
	fmt.Println()

	return nil
}

// cmdSuricataCustomEdit edits an existing custom rule
func cmdSuricataCustomEdit(sid int, newRule string) error {
	fmt.Println(version.BannerWithEmoji("✏️", "Edit Custom Suricata Rule"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create manager
	manager, err := customrules.NewManager()
	if err != nil {
		return fmt.Errorf("failed to create manager: %w", err)
	}

	// Update rule
	result, err := manager.UpdateRule(sid, newRule)
	if err != nil {
		if result != nil && len(result.Errors) > 0 {
			fmt.Println("✗ Validation failed:")
			for _, e := range result.Errors {
				fmt.Printf("  - %s\n", e)
			}
		}
		return err
	}

	fmt.Printf("✓ Custom rule updated successfully\n\n")
	fmt.Printf("SID:     %d\n", result.SID)
	fmt.Printf("Action:  %s\n", result.Action)
	fmt.Printf("Message: %s\n", result.Message)
	fmt.Println()
	fmt.Println("Reload Suricata to apply: systemctl reload suricata")
	fmt.Println()

	return nil
}

// cmdSuricataCustomList lists all custom rules
func cmdSuricataCustomList() error {
	fmt.Println(version.BannerWithEmoji("📋", "Custom Suricata Rules"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create manager
	manager, err := customrules.NewManager()
	if err != nil {
		return fmt.Errorf("failed to create manager: %w", err)
	}

	// List rules
	rules, err := manager.ListRules()
	if err != nil {
		return err
	}

	if len(rules) == 0 {
		fmt.Println("No custom rules found")
		fmt.Println()
		fmt.Println("Add a rule:")
		fmt.Println("  nftban suricata custom add 'alert tcp any any -> any any (msg:\"Test\"; sid:9000000; rev:1;)'")
		fmt.Println()
		return nil
	}

	// Display table
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "SID\tStatus\tAction\tMessage")
	fmt.Fprintln(w, "---\t------\t------\t-------")

	for _, rule := range rules {
		status := "✓ Enabled"
		if !rule.Enabled {
			status = "✗ Disabled"
		}

		message := rule.Message
		if len(message) > 50 {
			message = message[:47] + "..."
		}

		fmt.Fprintf(w, "%d\t%s\t%s\t%s\n", rule.SID, status, rule.Action, message)
	}
	_ = w.Flush()

	fmt.Println()
	fmt.Printf("Total: %d custom rules\n", len(rules))
	fmt.Println()

	return nil
}

// cmdSuricataCustomValidate validates all custom rules
func cmdSuricataCustomValidate() error {
	fmt.Println(version.BannerWithEmoji("✅", "Validate Custom Suricata Rules"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create manager
	manager, err := customrules.NewManager()
	if err != nil {
		return fmt.Errorf("failed to create manager: %w", err)
	}

	// Validate all
	results, err := manager.ValidateAll()
	if err != nil {
		return err
	}

	if len(results) == 0 {
		fmt.Println("No custom rules to validate")
		fmt.Println()
		return nil
	}

	// Display results
	allValid := true
	for sid, result := range results {
		if result.Valid {
			fmt.Printf("✓ SID %d: Valid\n", sid)
		} else {
			fmt.Printf("✗ SID %d: Invalid\n", sid)
			for _, e := range result.Errors {
				fmt.Printf("  - %s\n", e)
			}
			allValid = false
		}
	}

	fmt.Println()
	if allValid {
		fmt.Println("✅ All custom rules are valid")
	} else {
		fmt.Println("⚠️  Some rules have validation errors")
		return fmt.Errorf("validation failed")
	}
	fmt.Println()

	return nil
}

// cmdSuricataCustomEnable enables a custom rule
func cmdSuricataCustomEnable(sid int) error {
	fmt.Println(version.BannerWithEmoji("✅", "Enable Custom Rule"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create manager
	manager, err := customrules.NewManager()
	if err != nil {
		return fmt.Errorf("failed to create manager: %w", err)
	}

	// Enable rule
	if err := manager.EnableRule(sid); err != nil {
		return err
	}

	fmt.Printf("✓ Custom rule SID %d enabled\n", sid)
	fmt.Println()
	fmt.Println("Reload Suricata to apply: systemctl reload suricata")
	fmt.Println()

	return nil
}

// cmdSuricataCustomDisable disables a custom rule
func cmdSuricataCustomDisable(sid int) error {
	fmt.Println(version.BannerWithEmoji("❌", "Disable Custom Rule"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create manager
	manager, err := customrules.NewManager()
	if err != nil {
		return fmt.Errorf("failed to create manager: %w", err)
	}

	// Disable rule
	if err := manager.DisableRule(sid); err != nil {
		return err
	}

	fmt.Printf("✓ Custom rule SID %d disabled\n", sid)
	fmt.Println()
	fmt.Println("Reload Suricata to apply: systemctl reload suricata")
	fmt.Println()

	return nil
}

// cmdSuricataCustomBackup creates a backup of custom rules
func cmdSuricataCustomBackup() error {
	fmt.Println(version.BannerWithEmoji("💾", "Backup Custom Rules"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create manager
	manager, err := customrules.NewManager()
	if err != nil {
		return fmt.Errorf("failed to create manager: %w", err)
	}

	// Create backup
	if err := manager.CreateBackup(); err != nil {
		return err
	}

	fmt.Println("✓ Backup created successfully")
	fmt.Println()

	// List backups
	backups, err := manager.ListBackups()
	if err != nil {
		return err
	}

	fmt.Printf("Available backups (%d):\n", len(backups))
	for _, backup := range backups {
		fmt.Printf("  - %s\n", backup)
	}
	fmt.Println()

	return nil
}

// cmdSuricataCustomRollback restores from a backup
func cmdSuricataCustomRollback(backupName string) error {
	fmt.Println(version.BannerWithEmoji("⏮️", "Rollback Custom Rules"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create manager
	manager, err := customrules.NewManager()
	if err != nil {
		return fmt.Errorf("failed to create manager: %w", err)
	}

	fmt.Printf("Rolling back to: %s\n", backupName)
	fmt.Println()

	// Rollback
	if err := manager.Rollback(backupName); err != nil {
		return err
	}

	fmt.Println("✓ Rollback completed successfully")
	fmt.Println()
	fmt.Println("Current state backed up before rollback")
	fmt.Println("Reload Suricata to apply: systemctl reload suricata")
	fmt.Println()

	return nil
}

// cmdSuricataRecommend generates intelligent recommendations
func cmdSuricataRecommend() error {
	fmt.Println(version.BannerWithEmoji("💡", "Suricata Rule Recommendations"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create cache and analyzer
	cache, err := stats.NewCache()
	if err != nil {
		return fmt.Errorf("failed to create cache: %w", err)
	}

	analyzer := recommendations.NewAnalyzer(cache)

	// Generate recommendations
	fmt.Println("→ Analyzing SID statistics...")
	recs, err := analyzer.AnalyzeAll()
	if err != nil {
		return fmt.Errorf("failed to analyze: %w", err)
	}

	if len(recs) == 0 {
		fmt.Println("✓ No recommendations at this time")
		fmt.Println()
		fmt.Println("All rules appear to be performing optimally based on current data.")
		fmt.Println()
		return nil
	}

	fmt.Printf("✓ Generated %d recommendations\n", len(recs))
	fmt.Println()

	// Group by severity
	highSeverity := make([]*recommendations.Recommendation, 0)
	mediumSeverity := make([]*recommendations.Recommendation, 0)
	lowSeverity := make([]*recommendations.Recommendation, 0)

	for _, rec := range recs {
		switch rec.Severity {
		case "high":
			highSeverity = append(highSeverity, rec)
		case "medium":
			mediumSeverity = append(mediumSeverity, rec)
		case "low":
			lowSeverity = append(lowSeverity, rec)
		}
	}

	// Display high severity first
	if len(highSeverity) > 0 {
		fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		fmt.Printf("  🔴 HIGH SEVERITY (%d recommendations)\n", len(highSeverity))
		fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		fmt.Println()

		for _, rec := range highSeverity {
			printRecommendation(rec)
		}
	}

	// Display medium severity
	if len(mediumSeverity) > 0 {
		fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		fmt.Printf("  🟡 MEDIUM SEVERITY (%d recommendations)\n", len(mediumSeverity))
		fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		fmt.Println()

		for _, rec := range mediumSeverity {
			printRecommendation(rec)
		}
	}

	// Display low severity
	if len(lowSeverity) > 0 {
		fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		fmt.Printf("  🟢 LOW SEVERITY (%d recommendations)\n", len(lowSeverity))
		fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
		fmt.Println()

		for _, rec := range lowSeverity {
			printRecommendation(rec)
		}
	}

	fmt.Println("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
	fmt.Println()
	fmt.Println("Next steps:")
	fmt.Println("  1. Review high severity recommendations first")
	fmt.Println("  2. Investigate SIDs: nftban suricata sid info <SID>")
	fmt.Println("  3. Apply fixes (disable/modify rules as needed)")
	fmt.Println("  4. Monitor results: nftban suricata sid top")
	fmt.Println()

	return nil
}

// cmdSuricataRecommendSummary shows summary statistics
func cmdSuricataRecommendSummary() error {
	fmt.Println(version.BannerWithEmoji("📊", "Recommendations Summary"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Create cache and analyzer
	cache, err := stats.NewCache()
	if err != nil {
		return fmt.Errorf("failed to create cache: %w", err)
	}

	analyzer := recommendations.NewAnalyzer(cache)

	// Generate summary
	summary := analyzer.GenerateSummary()

	// Display summary
	fmt.Printf("Total SIDs tracked:        %d\n", summary["total_sids"])
	fmt.Printf("Total recommendations:     %d\n", summary["total_recommendations"])
	fmt.Println()

	// Severity breakdown
	fmt.Println("By Severity:")
	fmt.Printf("  🔴 High:   %d\n", summary["high_severity_count"])
	fmt.Printf("  🟡 Medium: %d\n", summary["medium_severity_count"])
	fmt.Printf("  🟢 Low:    %d\n", summary["low_severity_count"])
	fmt.Println()

	// Type breakdown
	if byType, ok := summary["by_type"].(map[string]int); ok {
		fmt.Println("By Type:")
		if count, exists := byType["false_positive"]; exists && count > 0 {
			fmt.Printf("  False Positives:   %d\n", count)
		}
		if count, exists := byType["noise_reduction"]; exists && count > 0 {
			fmt.Printf("  Noise Reduction:   %d\n", count)
		}
		if count, exists := byType["drop_mode"]; exists && count > 0 {
			fmt.Printf("  Drop Mode:         %d\n", count)
		}
		if count, exists := byType["disable_rule"]; exists && count > 0 {
			fmt.Printf("  Disable Rule:      %d\n", count)
		}
		fmt.Println()
	}

	fmt.Println("For detailed recommendations:")
	fmt.Println("  nftban suricata recommend")
	fmt.Println()

	return nil
}

// printRecommendation formats and prints a recommendation
func printRecommendation(rec *recommendations.Recommendation) {
	// Type icon
	typeIcon := "ℹ️"
	switch rec.Type {
	case recommendations.FalsePositive:
		typeIcon = "⚠️"
	case recommendations.NoiseReduction:
		typeIcon = "🔇"
	case recommendations.DropMode:
		typeIcon = "🛡️"
	case recommendations.DisableRule:
		typeIcon = "❌"
	}

	fmt.Printf("%s SID %s: %s\n", typeIcon, rec.SID, rec.Reason)
	fmt.Printf("   Category: %s\n", rec.Category)

	signature := rec.Signature
	if len(signature) > 60 {
		signature = signature[:57] + "..."
	}
	fmt.Printf("   Signature: %s\n", signature)

	fmt.Println("   Evidence:")
	for _, evidence := range rec.Evidence {
		fmt.Printf("     • %s\n", evidence)
	}

	fmt.Printf("   ✅ Action: %s\n", rec.Action)
	fmt.Println()
}
