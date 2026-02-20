// =============================================================================
// NFTBan - Port Management Command
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_ports"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Manage allowed ports in nftables firewall"
// meta:input="Subcommand (list, load, status)"
// meta:output="Console output with port configuration"
// meta:depends="github.com/itcmsgr/nftban/pkg/ipc,github.com/itcmsgr/nftban/pkg/network,github.com/itcmsgr/nftban/pkg/ports"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/ports.d/*.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"fmt"
	"strings"

	"github.com/itcmsgr/nftban/pkg/ipc"
	"github.com/itcmsgr/nftban/pkg/network"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/ports"
	"github.com/itcmsgr/nftban/pkg/version"
)

// getPortsDir returns the ports directory from passed config
func getPortsDir(cfg *nftbanconf.Config) string {
	return cfg.ConfigDir + "/ports.d"
}

func cmdPorts(action string, cfg *nftbanconf.Config) error {
	portsDir := getPortsDir(cfg)

	switch action {
	case "list":
		return cmdPortsList(portsDir)
	case "load":
		return cmdPortsLoad(portsDir)
	case "status":
		return cmdPortsStatus(portsDir)
	default:
		return fmt.Errorf("unknown ports action: %s\nUsage: nftban-core ports [list|load|status]", action)
	}
}

func cmdPortsList(portsDir string) error {
	fmt.Println(version.BannerWithEmoji("🔌", "Port Configuration"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Load port configuration
	config, err := ports.LoadPortsFromDirectory(portsDir)
	if err != nil {
		return fmt.Errorf("failed to load port configuration: %w", err)
	}

	if len(config.AllRules) == 0 {
		fmt.Println("No port rules configured.")
		fmt.Printf("Port directory: %s\n", portsDir)
		fmt.Println()
		fmt.Println("To add ports, create .conf files with format: PORT/PROTOCOL")
		fmt.Println("Where PROTOCOL is: T (TCP), U (UDP), or B (Both)")
		fmt.Println()
		fmt.Println("Example:")
		fmt.Println("  22/T    # SSH (TCP only)")
		fmt.Println("  53/B    # DNS (Both TCP and UDP)")
		fmt.Println("  80/T    # HTTP (TCP only)")
		return nil
	}

	fmt.Printf("Found %d port rules:\n\n", len(config.AllRules))

	// Group by protocol (legacy view)
	fmt.Println("TCP Ports (all directions):")
	tcpCount := 0
	for _, port := range config.TCPPorts {
		fmt.Printf("  %d", port)
		tcpCount++
		if tcpCount%10 == 0 {
			fmt.Println()
		} else {
			fmt.Print(" ")
		}
	}
	if tcpCount%10 != 0 {
		fmt.Println()
	}
	fmt.Printf("  Total: %d TCP ports\n\n", len(config.TCPPorts))

	fmt.Println("UDP Ports (all directions):")
	udpCount := 0
	for _, port := range config.UDPPorts {
		fmt.Printf("  %d", port)
		udpCount++
		if udpCount%10 == 0 {
			fmt.Println()
		} else {
			fmt.Print(" ")
		}
	}
	if udpCount%10 != 0 {
		fmt.Println()
	}
	fmt.Printf("  Total: %d UDP ports\n\n", len(config.UDPPorts))

	// Show directional breakdown if any directional rules exist
	hasDirectional := len(config.TCPPortsIn) > 0 || len(config.TCPPortsOut) > 0 ||
		len(config.UDPPortsIn) > 0 || len(config.UDPPortsOut) > 0
	if hasDirectional {
		fmt.Println("Directional Breakdown:")
		fmt.Printf("  TCP Input:  %d ports\n", len(config.TCPPortsIn))
		fmt.Printf("  TCP Output: %d ports\n", len(config.TCPPortsOut))
		fmt.Printf("  UDP Input:  %d ports\n", len(config.UDPPortsIn))
		fmt.Printf("  UDP Output: %d ports\n", len(config.UDPPortsOut))
		fmt.Println()
	}

	return nil
}

func cmdPortsStatus(portsDir string) error {
	fmt.Println(version.BannerWithEmoji("🔌", "Port Status"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Detect IP family support
	fmt.Println("Step 1: Detecting IP family support...")
	ipSupport, err := network.DetectIPFamilySupport()
	if err != nil {
		return fmt.Errorf("failed to detect IP families: %w", err)
	}
	fmt.Printf("  ✅ System: %s\n", ipSupport.String())
	if ipSupport.HasIPv4 {
		fmt.Println("  ✅ IPv4 is available")
	}
	if ipSupport.HasIPv6 {
		fmt.Println("  ✅ IPv6 is available")
	}
	if !ipSupport.HasIPv4 && !ipSupport.HasIPv6 {
		fmt.Println("  ⚠️  WARNING: No IP connectivity detected!")
	}
	fmt.Println()

	// Load port configuration
	fmt.Println("Step 2: Loading port configuration...")
	config, err := ports.LoadPortsFromDirectory(portsDir)
	if err != nil {
		return fmt.Errorf("failed to load ports: %w", err)
	}
	fmt.Printf("  ✅ Loaded %d TCP ports\n", len(config.TCPPorts))
	fmt.Printf("  ✅ Loaded %d UDP ports\n", len(config.UDPPorts))
	fmt.Println()

	// Check daemon status via IPC
	fmt.Println("Step 3: Checking nftband daemon status...")
	client := ipc.NewClient()
	if err := client.Ping(); err != nil {
		fmt.Println("  ⚠️  Daemon not running")
		fmt.Println("     Start with: sudo systemctl start nftband")
	} else {
		fmt.Println("  ✅ Daemon is running")

		// Get daemon status
		resp, err := client.Status()
		if err == nil && resp.Success {
			if data, ok := resp.Data.(map[string]any); ok {
				if v, ok := data["version"].(string); ok {
					fmt.Printf("  ✅ Daemon version: %s\n", v)
				}
			}
		}
	}
	fmt.Println()

	return nil
}

func cmdPortsLoad(portsDir string) error {
	// Check for privilege (root OR CAP_NET_ADMIN capability)
	if err := checkPrivilege(); err != nil {
		return err
	}

	fmt.Println(version.BannerWithEmoji("🔌", "Load Port Rules"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Step 1: Detect IP family support
	fmt.Println("Step 1: Detecting IP family support...")
	ipSupport, err := network.DetectIPFamilySupport()
	if err != nil {
		return fmt.Errorf("failed to detect IP families: %w", err)
	}
	fmt.Printf("  ✅ System: %s\n", ipSupport.String())

	if !ipSupport.HasIPv4 && !ipSupport.HasIPv6 {
		return fmt.Errorf("no IP connectivity detected: system has no IPv4 or IPv6 addresses")
	}
	fmt.Println()

	// Step 2: Load port configuration
	fmt.Println("Step 2: Loading port configuration...")
	config, err := ports.LoadPortsFromDirectory(portsDir)
	if err != nil {
		return fmt.Errorf("failed to load ports: %w", err)
	}

	if len(config.AllRules) == 0 {
		fmt.Println("  ⚠️  No port rules found")
		fmt.Println()
		fmt.Println("Create port configuration in: " + portsDir)
		fmt.Println("Format: PORT/PROTOCOL (T=TCP, U=UDP, B=Both)")
		return nil
	}

	fmt.Printf("  ✅ Loaded %d port rules\n", len(config.AllRules))
	fmt.Printf("  ✅ TCP ports: %d\n", len(config.TCPPorts))
	fmt.Printf("  ✅ UDP ports: %d\n", len(config.UDPPorts))
	fmt.Println()

	// Step 3: Connect to daemon
	fmt.Println("Step 3: Connecting to nftband daemon...")
	client := ipc.NewClient()
	if err := client.Ping(); err != nil {
		return fmt.Errorf("daemon not running: %w\nStart with: sudo systemctl start nftband", err)
	}
	fmt.Println("  ✅ Connected to nftband daemon")
	fmt.Println()

	// Step 4: Load ports via IPC
	fmt.Println("Step 4: Loading ports into nftables via daemon...")
	resp, err := client.LoadPorts()
	if err != nil {
		return fmt.Errorf("failed to load ports: %w", err)
	}

	if !resp.Success {
		return fmt.Errorf("failed to load ports: %s", resp.Error)
	}

	// Extract results
	data, ok := resp.Data.(map[string]any)
	if !ok {
		return fmt.Errorf("unexpected response format")
	}

	fmt.Println()
	fmt.Println(strings.Repeat("=", 70))
	fmt.Printf("✅ Port rules loaded successfully!\n")
	fmt.Println()

	if tcpIn, ok := data["tcp_ports_in"].(float64); ok {
		fmt.Printf("TCP ports (input) loaded: %.0f\n", tcpIn)
	}
	if tcpOut, ok := data["tcp_ports_out"].(float64); ok {
		fmt.Printf("TCP ports (output) loaded: %.0f\n", tcpOut)
	}
	if udpIn, ok := data["udp_ports_in"].(float64); ok {
		fmt.Printf("UDP ports (input) loaded: %.0f\n", udpIn)
	}
	if udpOut, ok := data["udp_ports_out"].(float64); ok {
		fmt.Printf("UDP ports (output) loaded: %.0f\n", udpOut)
	}
	fmt.Println()
	fmt.Println("Port sets are now configured in nftables.")
	fmt.Println("Use firewall rules to reference @tcp_ports_in, @tcp_ports_out, @udp_ports_in, @udp_ports_out sets.")
	fmt.Println()

	return nil
}
