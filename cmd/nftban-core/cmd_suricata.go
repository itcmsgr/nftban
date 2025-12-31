package main

import (
	"fmt"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"text/tabwriter"

	"github.com/itcmsgr/nftban/pkg/analytics"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/suricata"
	"github.com/itcmsgr/nftban/pkg/version"
)

// getSuricataPaths returns suricata-related paths from central config
// NO FALLBACK for nftban paths - must come from /etc/nftban/nftban.conf
// Note: Suricata itself uses /etc/suricata (external dependency, not nftban config)
func getSuricataPaths() (suricataConfigDir, evePath, logDir, dataDir string) {
	cfg := nftbanconf.MustLoad()
	// Suricata itself uses /etc/suricata (external dependency, not nftban config)
	suricataConfigDir = "/etc/suricata"
	evePath = "/var/log/suricata/eve.json"
	logDir = cfg.LogDir
	dataDir = cfg.DataDir
	return
}

func cmdSuricata(action string) error {
	switch action {
	case "status":
		return cmdSuricataStatus()
	case "filters":
		return cmdSuricataFilters()
	case "daemon":
		return cmdSuricataDaemon()
	case "enable":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core suricata enable <FILTER_NAME>")
		}
		filterName := os.Args[3]
		return cmdSuricataEnable(filterName, true)
	case "disable":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core suricata disable <FILTER_NAME>")
		}
		filterName := os.Args[3]
		return cmdSuricataEnable(filterName, false)
	case "set-threshold":
		if len(os.Args) < 5 {
			return fmt.Errorf("usage: nftban-core suricata set-threshold <FILTER_NAME> <THRESHOLD>")
		}
		filterName := os.Args[3]
		var threshold int
		if _, err := fmt.Sscanf(os.Args[4], "%d", &threshold); err != nil {
			return fmt.Errorf("invalid threshold: %v", err)
		}
		return cmdSuricataSetThreshold(filterName, threshold)
	case "set-action":
		if len(os.Args) < 5 {
			return fmt.Errorf("usage: nftban-core suricata set-action <FILTER_NAME> <ACTION>")
		}
		filterName := os.Args[3]
		action := os.Args[4]
		return cmdSuricataSetAction(filterName, action)
	default:
		return fmt.Errorf("unknown suricata action: %s\nUsage: nftban-core suricata [status|filters|daemon|enable|disable|set-threshold|set-action]", action)
	}
}

// cmdSuricataStatus shows Suricata integration status
func cmdSuricataStatus() error {
	fmt.Println(version.BannerWithEmoji("🛡️", "Suricata Integration Status"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Load config
	configDir, _, _, _ := getSuricataPaths()
	config, err := suricata.LoadConfig(configDir)
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	// Global status
	fmt.Println("Global Configuration:")
	fmt.Printf("  Enabled:          %v\n", config.GlobalEnabled)
	fmt.Printf("  Default Threshold: %d points\n", config.DefaultThreshold)
	fmt.Printf("  Default Ban Time:  %s\n", config.DefaultBanTime)
	fmt.Printf("  Default Action:    %s\n", config.DefaultAction)
	fmt.Printf("  Score Decay:       %s\n", config.ScoreDecay)
	fmt.Println()

	// Filter counts
	enabledFilters := config.GetEnabledFilters()
	totalFilters := len(config.Filters)
	enabledCount := len(enabledFilters)
	disabledCount := totalFilters - enabledCount

	fmt.Println("Filter Summary:")
	fmt.Printf("  Total Filters:    %d\n", totalFilters)
	fmt.Printf("  Enabled:          %d\n", enabledCount)
	fmt.Printf("  Disabled:         %d\n", disabledCount)
	fmt.Println()

	// Eve.json path
	_, evePath, _, _ := getSuricataPaths()
	if _, err := os.Stat(evePath); err == nil {
		fmt.Printf("✅ Eve log found: %s\n", evePath)
	} else {
		fmt.Printf("❌ Eve log not found: %s\n", evePath)
	}
	fmt.Println()

	return nil
}

// cmdSuricataFilters lists all configured filters
func cmdSuricataFilters() error {
	fmt.Println(version.BannerWithEmoji("🛡️", "Suricata Filters"))
	fmt.Println(strings.Repeat("=", 100))
	fmt.Println()

	// Load config
	configDir, _, _, _ := getSuricataPaths()
	config, err := suricata.LoadConfig(configDir)
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	// Create table writer
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "FILTER\tENABLED\tTHRESHOLD\tBAN TIME\tACTION\tBAN TYPE\tDESCRIPTION")
	fmt.Fprintln(w, "------\t-------\t---------\t--------\t------\t--------\t-----------")

	// Print each filter
	for name, filter := range config.Filters {
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

	w.Flush()
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
func cmdSuricataEnable(filterName string, enable bool) error {
	configDir, _, _, _ := getSuricataPaths()
	localPath := configDir + "/filters.conf.local"

	// Load existing config
	config, err := suricata.LoadConfig(configDir)
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	// Check if filter exists
	filter, ok := config.GetFilter(filterName)
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
func cmdSuricataSetThreshold(filterName string, threshold int) error {
	configDir, _, _, _ := getSuricataPaths()
	localPath := configDir + "/filters.conf.local"

	// Load existing config
	config, err := suricata.LoadConfig(configDir)
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	// Check if filter exists
	filter, ok := config.GetFilter(filterName)
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
func cmdSuricataSetAction(filterName string, action string) error {
	// Validate action
	if action != "log" && action != "observe" && action != "ban" {
		return fmt.Errorf("invalid action '%s' (must be log/observe/ban)", action)
	}

	configDir, _, _, _ := getSuricataPaths()
	localPath := configDir + "/filters.conf.local"

	// Load existing config
	config, err := suricata.LoadConfig(configDir)
	if err != nil {
		return fmt.Errorf("failed to load config: %w", err)
	}

	// Check if filter exists
	filter, ok := config.GetFilter(filterName)
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

	// Create ban handler using existing netlink infrastructure
	banHandler, err := suricata.NewNetlinkBanHandler()
	if err != nil {
		return fmt.Errorf("failed to create ban handler: %w", err)
	}
	defer banHandler.Close()

	// Create processor
	suricataConfigDir, evePath, logDir, _ := getSuricataPaths()
	cfg := &suricata.ProcessorConfig{
		ConfigDir:  suricataConfigDir,
		EvePath:    evePath,
		LogPath:    logDir + "/suricata-events.log",
		BanHandler: banHandler,
	}

	processor, err := suricata.NewProcessor(cfg)
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
	_, _, _, dataDir := getSuricataPaths()
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
