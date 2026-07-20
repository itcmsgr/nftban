// =============================================================================
// NFTBan - Differential Sync Command
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_sync"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Synchronize whitelist and blacklist with nftables via daemon"
// meta:input="None"
// meta:output="Console output with sync results"
// meta:depends="github.com/itcmsgr/nftban/pkg/ipc,github.com/itcmsgr/nftban/internal/nftbanconf"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftband.service"
// meta:inventory.network="unix:/var/run/nftban/nftband.sock"
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/ipc"
	"github.com/itcmsgr/nftban/pkg/version"
)

func cmdSync(cfg *nftbanconf.Config) error {
	// Check for privilege (root OR CAP_NET_ADMIN capability)
	if err := checkPrivilege(); err != nil {
		return err
	}

	// Check for --quick flag (skips feeds/geoban for fast postinst sync)
	quickMode := false
	for _, arg := range os.Args[2:] {
		if arg == "--quick" || arg == "-q" {
			quickMode = true
			break
		}
	}

	if quickMode {
		fmt.Println(version.BannerWithEmoji("🔄", "Quick Sync (whitelist/blacklist only)"))
	} else {
		fmt.Println(version.BannerWithEmoji("🔄", "Differential Sync"))
	}
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Connect to daemon via IPC
	fmt.Println("Connecting to nftband daemon...")
	client := ipc.NewClient()

	// Check if daemon is running
	if err := client.Ping(); err != nil {
		return fmt.Errorf("daemon not running: %w\nStart with: sudo systemctl start nftband", err)
	}
	fmt.Println("  ✅ Connected to nftband daemon")
	fmt.Println()

	// Set timeout based on mode
	var syncTimeout time.Duration
	if quickMode {
		// Quick mode: only whitelist/blacklist, should complete in <30 seconds
		syncTimeout = 30 * time.Second
		fmt.Printf("  ⏱️  Quick mode: timeout %v (no feeds/geoban)\n", syncTimeout)
	} else {
		// Full mode: includes feeds + geoban loading (can take 3-5 minutes)
		syncTimeout = 5 * time.Minute
		fmt.Printf("  ⏱️  Timeout set to %v for full sync\n", syncTimeout)
	}
	client.SetTimeout(syncTimeout)
	fmt.Println()

	// Perform sync via IPC
	fmt.Println("Performing differential sync via daemon...")
	resp, err := client.Sync(quickMode)
	if err != nil {
		return fmt.Errorf("sync failed: %w", err)
	}

	if !resp.Success {
		return fmt.Errorf("sync failed: %s", resp.Error)
	}

	// Extract results from response
	data, ok := resp.Data.(map[string]any)
	if !ok {
		return fmt.Errorf("unexpected response format")
	}

	fmt.Println()
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println("✅ Sync completed successfully!")
	fmt.Println()

	// Print sync results
	fmt.Println("Sync Results:")
	fmt.Println(strings.Repeat("-", 70))

	if v, ok := data["whitelist_ipv4_added"].(float64); ok && v > 0 {
		fmt.Printf("  Whitelist IPv4: +%.0f added\n", v)
	}
	if v, ok := data["whitelist_ipv4_removed"].(float64); ok && v > 0 {
		fmt.Printf("  Whitelist IPv4: -%.0f removed\n", v)
	}
	if v, ok := data["whitelist_ipv6_added"].(float64); ok && v > 0 {
		fmt.Printf("  Whitelist IPv6: +%.0f added\n", v)
	}
	if v, ok := data["whitelist_ipv6_removed"].(float64); ok && v > 0 {
		fmt.Printf("  Whitelist IPv6: -%.0f removed\n", v)
	}
	if v, ok := data["blacklist_ipv4_added"].(float64); ok && v > 0 {
		fmt.Printf("  Blacklist IPv4: +%.0f added\n", v)
	}
	if v, ok := data["blacklist_ipv4_removed"].(float64); ok && v > 0 {
		fmt.Printf("  Blacklist IPv4: -%.0f removed\n", v)
	}
	if v, ok := data["blacklist_ipv6_added"].(float64); ok && v > 0 {
		fmt.Printf("  Blacklist IPv6: +%.0f added\n", v)
	}
	if v, ok := data["blacklist_ipv6_removed"].(float64); ok && v > 0 {
		fmt.Printf("  Blacklist IPv6: -%.0f removed\n", v)
	}

	// Feeds loaded (if any)
	if v, ok := data["feeds_ipv4_loaded"].(float64); ok && v > 0 {
		fmt.Printf("  Feeds IPv4: %.0f ranges loaded\n", v)
	}
	if v, ok := data["feeds_ipv6_loaded"].(float64); ok && v > 0 {
		fmt.Printf("  Feeds IPv6: %.0f ranges loaded\n", v)
	}

	// Geoban loaded (if any)
	if v, ok := data["geoban_ipv4_loaded"].(float64); ok && v > 0 {
		fmt.Printf("  Geoban IPv4: %.0f ranges loaded\n", v)
	}
	if v, ok := data["geoban_ipv6_loaded"].(float64); ok && v > 0 {
		fmt.Printf("  Geoban IPv6: %.0f ranges loaded\n", v)
	}

	if tcp, ok := data["tcp_ports_in"].(float64); ok && tcp > 0 {
		fmt.Printf("  TCP Ports (In): %.0f loaded\n", tcp)
	}
	if udp, ok := data["udp_ports_in"].(float64); ok && udp > 0 {
		fmt.Printf("  UDP Ports (In): %.0f loaded\n", udp)
	}

	// Show directional port counts if present
	tcpIn, _ := data["tcp_ports_in"].(float64)
	tcpOut, _ := data["tcp_ports_out"].(float64)
	udpIn, _ := data["udp_ports_in"].(float64)
	udpOut, _ := data["udp_ports_out"].(float64)
	if tcpIn > 0 || tcpOut > 0 || udpIn > 0 || udpOut > 0 {
		fmt.Println("  Directional ports:")
		if tcpIn > 0 {
			fmt.Printf("    TCP Input:  %.0f\n", tcpIn)
		}
		if tcpOut > 0 {
			fmt.Printf("    TCP Output: %.0f\n", tcpOut)
		}
		if udpIn > 0 {
			fmt.Printf("    UDP Input:  %.0f\n", udpIn)
		}
		if udpOut > 0 {
			fmt.Printf("    UDP Output: %.0f\n", udpOut)
		}
	}

	fmt.Println()
	fmt.Println("Firewall is now in sync with configuration files.")
	fmt.Println()

	return nil
}
