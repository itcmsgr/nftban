// =============================================================================
// NFTBan - Differential Sync Command
// =============================================================================
// SPDX-License-Identifier: GPL-3.0-or-later
// meta:name="cmd_sync"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Synchronize whitelist and blacklist with nftables via daemon"
// meta:input="None"
// meta:output="Console output with sync results"
// meta:depends="github.com/itcmsgr/nftban/pkg/ipc,github.com/itcmsgr/nftban/pkg/nftbanconf"
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
	"strings"

	"github.com/itcmsgr/nftban/pkg/ipc"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/version"
)

func cmdSync(cfg *nftbanconf.Config) error {
	// Check for privilege (root OR CAP_NET_ADMIN capability)
	if err := checkPrivilege(); err != nil {
		return err
	}

	fmt.Println(version.BannerWithEmoji("🔄", "Differential Sync"))
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

	// Perform sync via IPC
	fmt.Println("Performing differential sync via daemon...")
	resp, err := client.Sync()
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

	if tcp, ok := data["tcp_ports"].(float64); ok && tcp > 0 {
		fmt.Printf("  TCP Ports: %.0f loaded\n", tcp)
	}
	if udp, ok := data["udp_ports"].(float64); ok && udp > 0 {
		fmt.Printf("  UDP Ports: %.0f loaded\n", udp)
	}

	fmt.Println()
	fmt.Println("Firewall is now in sync with configuration files.")
	fmt.Println()

	return nil
}
