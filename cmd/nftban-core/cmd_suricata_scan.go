// =============================================================================
// NFTBan - Suricata Integration - Log scanning and deep scan
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_suricata"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Log scanning and deep scan"
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

	"github.com/itcmsgr/nftban/pkg/suricata/config"
	"github.com/itcmsgr/nftban/pkg/suricata/scanner"
	"github.com/itcmsgr/nftban/pkg/version"
)

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
