// =============================================================================
// NFTBan - Suricata Integration - Rules generation, statistics, and initialization
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_suricata"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Rules generation, statistics, and initialization"
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
	"strings"

	"github.com/itcmsgr/nftban/internal/suricata/config"
	"github.com/itcmsgr/nftban/internal/suricata/rules"
	"github.com/itcmsgr/nftban/pkg/version"
)

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
