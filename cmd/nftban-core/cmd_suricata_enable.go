// =============================================================================
// NFTBan - Suricata Integration - Enable, disable, threshold, and action commands
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_suricata"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Enable, disable, threshold, and action commands"
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

	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/internal/suricata"
)

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
