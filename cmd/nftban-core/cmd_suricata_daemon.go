// =============================================================================
// NFTBan - Suricata Integration - Suricata daemon management
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_suricata"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Suricata daemon management"
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
	"os"
	"os/signal"
	"strings"
	"syscall"

	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/suricata"
	"github.com/itcmsgr/nftban/pkg/version"
)

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
