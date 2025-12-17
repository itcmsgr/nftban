package main

import (
	"fmt"
	"strings"

	"github.com/google/nftables"
	"github.com/itcmsgr/nftban-v1.0-dev/pkg/network"
	"github.com/itcmsgr/nftban-v1.0-dev/pkg/nftbanconf"
	"github.com/itcmsgr/nftban-v1.0-dev/pkg/ports"
	"github.com/itcmsgr/nftban-v1.0-dev/pkg/sync"
	"github.com/itcmsgr/nftban-v1.0-dev/pkg/version"
)

// getPortsDir returns the ports directory from central config
// NO FALLBACK - path must come from /etc/nftban/nftban.conf
func getPortsDir() string {
	cfg := nftbanconf.MustLoad()
	return cfg.ConfigDir + "/ports.d"
}

func cmdPorts(action string) error {
	portsDir := getPortsDir()

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

	// Group by protocol
	fmt.Println("TCP Ports:")
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

	fmt.Println("UDP Ports:")
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

	// Check nftables status
	fmt.Println("Step 3: Checking nftables status...")
	nft, err := sync.NewNFTManager()
	if err != nil {
		return fmt.Errorf("failed to connect to nftables: %w", err)
	}
	defer nft.Close()

	// Check for inet table (dual-stack)
	inetTable, _ := nft.GetOrCreateTable(nftables.TableFamilyINet)
	if inetTable != nil {
		fmt.Println("  ✅ Found inet (dual-stack) table")
	}

	// Check IPv4 table (only if system has IPv4)
	if ipSupport.HasIPv4 {
		ipv4Table, _ := nft.GetOrCreateTable(nftables.TableFamilyIPv4)
		if ipv4Table != nil {
			fmt.Println("  ✅ Found IPv4 table")
		}
	} else {
		fmt.Println("  ℹ️  IPv4 table skipped (system has no IPv4)")
	}

	// Check IPv6 table (only if system has IPv6)
	if ipSupport.HasIPv6 {
		ipv6Table, _ := nft.GetOrCreateTable(nftables.TableFamilyIPv6)
		if ipv6Table != nil {
			fmt.Println("  ✅ Found IPv6 table")
		}
	} else {
		fmt.Println("  ℹ️  IPv6 table skipped (system has no IPv6)")
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

	// Step 1: Detect IP family support (CRITICAL!)
	fmt.Println("Step 1: Detecting IP family support...")
	ipSupport, err := network.DetectIPFamilySupport()
	if err != nil {
		return fmt.Errorf("failed to detect IP families: %w", err)
	}
	fmt.Printf("  ✅ System: %s\n", ipSupport.String())

	if !ipSupport.HasIPv4 && !ipSupport.HasIPv6 {
		return fmt.Errorf("CRITICAL: No IP connectivity detected!\n" +
			"System has no IPv4 or IPv6 addresses. Cannot create firewall rules.")
	}

	// Show what will be created
	fmt.Println()
	fmt.Println("  Will create rules for:")
	if ipSupport.HasIPv4 {
		fmt.Println("  ✅ IPv4 (system has IPv4 addresses)")
	} else {
		fmt.Println("  ⏭️  IPv4 SKIPPED (system has NO IPv4 addresses)")
	}
	if ipSupport.HasIPv6 {
		fmt.Println("  ✅ IPv6 (system has IPv6 addresses)")
	} else {
		fmt.Println("  ⏭️  IPv6 SKIPPED (system has NO IPv6 addresses)")
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

	// Step 3: Initialize nftables manager
	fmt.Println("Step 3: Connecting to nftables...")
	nft, err := sync.NewNFTManager()
	if err != nil {
		return fmt.Errorf("failed to create nftables manager: %w", err)
	}
	defer nft.Close()
	fmt.Println("  ✅ Connected to nftables")
	fmt.Println()

	// Step 4: ALWAYS create port sets for BOTH IPv4 and IPv6 (for compatibility)
	// But only load data into families that actually exist on the system
	fmt.Println("Step 4: Creating port sets in nftables...")

	// Create IPv4 table and sets (ALWAYS - even if no IPv4)
	fmt.Println("  Creating IPv4 port sets...")
	ipv4Table, err := nft.GetOrCreateTable(nftables.TableFamilyIPv4)
	if err != nil {
		return fmt.Errorf("failed to get IPv4 table: %w", err)
	}

	tcpSetV4, err := nft.GetOrCreatePortSet(ipv4Table, "tcp_ports")
	if err != nil {
		return fmt.Errorf("failed to create IPv4 tcp_ports set: %w", err)
	}
	fmt.Println("  ✅ Created/verified tcp_ports set (IPv4)")

	udpSetV4, err := nft.GetOrCreatePortSet(ipv4Table, "udp_ports")
	if err != nil {
		return fmt.Errorf("failed to create IPv4 udp_ports set: %w", err)
	}
	fmt.Println("  ✅ Created/verified udp_ports set (IPv4)")

	// Create IPv6 table and sets (ALWAYS - even if no IPv6)
	fmt.Println("  Creating IPv6 port sets...")
	ipv6Table, err := nft.GetOrCreateTable(nftables.TableFamilyIPv6)
	if err != nil {
		return fmt.Errorf("failed to get IPv6 table: %w", err)
	}

	tcpSetV6, err := nft.GetOrCreatePortSet(ipv6Table, "tcp_ports")
	if err != nil {
		return fmt.Errorf("failed to create IPv6 tcp_ports set: %w", err)
	}
	fmt.Println("  ✅ Created/verified tcp_ports set (IPv6)")

	udpSetV6, err := nft.GetOrCreatePortSet(ipv6Table, "udp_ports")
	if err != nil {
		return fmt.Errorf("failed to create IPv6 udp_ports set: %w", err)
	}
	fmt.Println("  ✅ Created/verified udp_ports set (IPv6)")
	fmt.Println()

	// Step 5: Load ports ONLY into families that exist on the system
	fmt.Println("Step 5: Loading ports into nftables sets...")

	// Load IPv4 ports (only if system has IPv4)
	if ipSupport.HasIPv4 {
		if len(config.TCPPorts) > 0 {
			if err := nft.AddPortElements(tcpSetV4, config.TCPPorts); err != nil {
				return fmt.Errorf("failed to add IPv4 TCP ports: %w", err)
			}
			fmt.Printf("  ✅ Loaded %d TCP ports into IPv4 set\n", len(config.TCPPorts))
		}
		if len(config.UDPPorts) > 0 {
			if err := nft.AddPortElements(udpSetV4, config.UDPPorts); err != nil {
				return fmt.Errorf("failed to add IPv4 UDP ports: %w", err)
			}
			fmt.Printf("  ✅ Loaded %d UDP ports into IPv4 set\n", len(config.UDPPorts))
		}
	} else {
		fmt.Println("  ⏭️  IPv4 sets left EMPTY (system has no IPv4 addresses)")
	}

	// Load IPv6 ports (only if system has IPv6)
	if ipSupport.HasIPv6 {
		if len(config.TCPPorts) > 0 {
			if err := nft.AddPortElements(tcpSetV6, config.TCPPorts); err != nil {
				return fmt.Errorf("failed to add IPv6 TCP ports: %w", err)
			}
			fmt.Printf("  ✅ Loaded %d TCP ports into IPv6 set\n", len(config.TCPPorts))
		}
		if len(config.UDPPorts) > 0 {
			if err := nft.AddPortElements(udpSetV6, config.UDPPorts); err != nil {
				return fmt.Errorf("failed to add IPv6 UDP ports: %w", err)
			}
			fmt.Printf("  ✅ Loaded %d UDP ports into IPv6 set\n", len(config.UDPPorts))
		}
	} else {
		fmt.Println("  ⏭️  IPv6 sets left EMPTY (system has no IPv6 addresses)")
	}

	fmt.Println()
	fmt.Println(strings.Repeat("=", 70))
	fmt.Printf("✅ Port rules loaded successfully!\n")
	fmt.Println()
	fmt.Printf("System configuration: %s\n", ipSupport.String())
	fmt.Printf("TCP ports loaded: %d\n", len(config.TCPPorts))
	fmt.Printf("UDP ports loaded: %d\n", len(config.UDPPorts))
	fmt.Println()
	fmt.Println("Port sets are now configured in nftables.")
	fmt.Println("Use firewall rules to reference @tcp_ports and @udp_ports sets.")
	fmt.Println()

	return nil
}
