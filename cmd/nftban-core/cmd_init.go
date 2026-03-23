// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="cmd_init"
// meta:type="go"
// meta:package="main"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-01-01"
// meta:description="Safety-first initialization with IP detection"
// meta:input="Config, user confirmation"
// meta:output="Whitelist configuration"
// meta:depends="go"
//
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftban.conf,/etc/nftban/conf.d/whitelist.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"

package main

import (
	"bufio"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/configloader"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/internal/safety"
	"github.com/itcmsgr/nftban/pkg/version"
)

func cmdInit(cfg *nftbanconf.Config) error {
	fmt.Println(version.BannerWithEmoji("🛡️", "Safety-First Initialization"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Check for privilege (root OR CAP_NET_ADMIN capability)
	if err := checkPrivilege(); err != nil {
		return err
	}

	// Step 1: Detect all system IPs
	fmt.Println("Step 1: Detecting system IPs...")
	sysIPs, err := safety.DetectSystemIPs()
	if err != nil {
		return fmt.Errorf("failed to detect system IPs: %w", err)
	}

	// Step 2: Display detected IPs
	sysIPs.PrintSystemIPs()

	// Step 3: Confirm with user if SSH IP not detected
	if sysIPs.CurrentUserIP == nil {
		fmt.Println("⚠️  WARNING: Could not detect your current SSH IP!")
		fmt.Println("⚠️  Please manually add your IP to whitelist before proceeding:")
		fmt.Printf("   echo \"YOUR_IP_HERE\" >> /etc/nftban/whitelist.conf\n")
		fmt.Println()
		fmt.Print("Continue anyway? [y/N]: ")

		reader := bufio.NewReader(os.Stdin)
		response, _ := reader.ReadString('\n')
		response = strings.TrimSpace(strings.ToLower(response))

		if response != "y" && response != "yes" {
			return fmt.Errorf("initialization cancelled by user")
		}
	}

	// Step 4: Load configurations
	fmt.Println("Step 2: Loading configurations...")

	// Load FHS spec
	fhsSpec, err := configloader.LoadFHSSpec()
	if err != nil {
		fmt.Fprintf(os.Stderr, "  ⚠️  Warning: Could not load FHS spec: %v\n", err)
		fmt.Println("  ℹ️  Continuing with defaults...")
	} else {
		fmt.Printf("  ✅ Loaded FHS specification (%d directories)\n", len(fhsSpec))
	}

	// Load distro config
	distro, err := configloader.LoadDistroConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "  ⚠️  Warning: Could not load distro config: %v\n", err)
		fmt.Println("  ℹ️  Continuing with defaults...")
	} else {
		fmt.Printf("  ✅ Detected distribution: %s\n", distro.Name)
	}

	// Load services config
	services, err := configloader.LoadServicesConfig()
	if err != nil {
		fmt.Fprintf(os.Stderr, "  ⚠️  Warning: Could not load services config: %v\n", err)
	} else {
		fmt.Printf("  ✅ Loaded services configuration\n")
		if !services["nftban"] {
			return fmt.Errorf("NFTBan is disabled in services.conf")
		}
	}
	fmt.Println()

	// Step 5: Create emergency whitelist file
	fmt.Println("Step 3: Creating emergency whitelist...")
	emergencyFile := configloader.GetFHSPath("config") + "/emergency_whitelist.conf"

	f, err := os.OpenFile(emergencyFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644) //nolint:gosec // non-sensitive config file
	if err != nil {
		return fmt.Errorf("failed to create emergency whitelist: %w", err)
	}

	fmt.Fprintf(f, "# NFTBan Emergency Whitelist\n")
	fmt.Fprintf(f, "# Auto-generated: %s\n", time.Now().Format(time.RFC3339))
	fmt.Fprintf(f, "# These IPs are CRITICAL and must NEVER be blocked!\n\n")

	if sysIPs.CurrentUserIP != nil {
		fmt.Fprintf(f, "# Your current SSH connection:\n")
		fmt.Fprintf(f, "%s\n\n", sysIPs.CurrentUserIP)
	}

	fmt.Fprintf(f, "# Server interface IPs:\n")
	for _, ip := range sysIPs.ServerIPs {
		fmt.Fprintf(f, "%s\n", ip)
	}

	if len(sysIPs.GatewayIPs) > 0 {
		fmt.Fprintf(f, "\n# Gateway IPs:\n")
		for _, ip := range sysIPs.GatewayIPs {
			fmt.Fprintf(f, "%s\n", ip)
		}
	}

	if len(sysIPs.DNSServers) > 0 {
		fmt.Fprintf(f, "\n# DNS Servers:\n")
		for _, ip := range sysIPs.DNSServers {
			fmt.Fprintf(f, "%s\n", ip)
		}
	}

	if err := f.Close(); err != nil {
		return fmt.Errorf("failed to close emergency whitelist: %w", err)
	}
	fmt.Printf("  ✅ Created: %s\n", emergencyFile)
	fmt.Println()

	// Step 6: Update whitelist using organized whitelist.d/ structure
	fmt.Println("Step 4: Updating whitelist (whitelist.d/ structure)...")
	whitelistDir := configloader.GetFHSPath("config") + "/whitelist.d"
	whitelistFile := whitelistDir + "/01-nftban-init.conf"

	// Ensure whitelist.d directory exists
	if err := os.MkdirAll(whitelistDir, 0750); err != nil {
		return fmt.Errorf("failed to create whitelist.d: %w", err)
	}

	// Read existing whitelist from ALL sources (whitelist.conf + whitelist.d/*)
	existingIPs := make(map[string]bool)

	// Read main whitelist.conf
	mainWhitelist := configloader.GetFHSPath("config") + "/whitelist.conf"
	if data, err := os.ReadFile(mainWhitelist); err == nil {
		lines := strings.Split(string(data), "\n")
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if line != "" && !strings.HasPrefix(line, "#") {
				existingIPs[line] = true
			}
		}
	}

	// Read all files in whitelist.d/
	if entries, err := os.ReadDir(whitelistDir); err == nil {
		for _, entry := range entries {
			if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".conf") {
				continue
			}
			filePath := whitelistDir + "/" + entry.Name()
			if data, err := os.ReadFile(filePath); err == nil {
				lines := strings.Split(string(data), "\n")
				for _, line := range lines {
					line = strings.TrimSpace(line)
					if line != "" && !strings.HasPrefix(line, "#") {
						existingIPs[line] = true
					}
				}
			}
		}
	}

	// Check what IPs need to be added
	allIPs := sysIPs.GetAllIPs()
	var newIPs []string
	for _, ip := range allIPs {
		ipStr := ip.String()
		if !existingIPs[ipStr] {
			newIPs = append(newIPs, ipStr)
		}
	}

	if len(newIPs) > 0 {
		// Create/append to 01-nftban-init.conf
		f, err = os.OpenFile(whitelistFile, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0640)
		if err != nil {
			return fmt.Errorf("failed to open whitelist: %w", err)
		}
		defer f.Close()

		fmt.Fprintf(f, "# NFTBan Init Auto-Whitelist\n")
		fmt.Fprintf(f, "# Auto-generated: %s\n", time.Now().Format(time.RFC3339))
		fmt.Fprintf(f, "# Critical system IPs detected during initialization\n")
		fmt.Fprintf(f, "# DO NOT DELETE - LOCKOUT RISK!\n\n")

		if sysIPs.CurrentUserIP != nil {
			found := false
			for _, ip := range newIPs {
				if ip == sysIPs.CurrentUserIP.String() {
					found = true
					break
				}
			}
			if found {
				fmt.Fprintf(f, "# Current SSH connection:\n")
				fmt.Fprintf(f, "%s\n\n", sysIPs.CurrentUserIP)
			}
		}

		// Server IPs
		serverIPsAdded := false
		for _, ip := range sysIPs.ServerIPs {
			ipStr := ip.String()
			for _, newIP := range newIPs {
				if newIP == ipStr {
					if !serverIPsAdded {
						fmt.Fprintf(f, "# Server interface IPs:\n")
						serverIPsAdded = true
					}
					fmt.Fprintf(f, "%s\n", ipStr)
					break
				}
			}
		}
		if serverIPsAdded {
			fmt.Fprintf(f, "\n")
		}

		// Gateway IPs
		if len(sysIPs.GatewayIPs) > 0 {
			gatewayIPsAdded := false
			for _, ip := range sysIPs.GatewayIPs {
				ipStr := ip.String()
				for _, newIP := range newIPs {
					if newIP == ipStr {
						if !gatewayIPsAdded {
							fmt.Fprintf(f, "# Gateway IPs:\n")
							gatewayIPsAdded = true
						}
						fmt.Fprintf(f, "%s\n", ipStr)
						break
					}
				}
			}
			if gatewayIPsAdded {
				fmt.Fprintf(f, "\n")
			}
		}

		// DNS Servers
		if len(sysIPs.DNSServers) > 0 {
			dnsIPsAdded := false
			for _, ip := range sysIPs.DNSServers {
				ipStr := ip.String()
				for _, newIP := range newIPs {
					if newIP == ipStr {
						if !dnsIPsAdded {
							fmt.Fprintf(f, "# DNS Servers:\n")
							dnsIPsAdded = true
						}
						fmt.Fprintf(f, "%s\n", ipStr)
						break
					}
				}
			}
		}

		fmt.Printf("  ✅ Added %d new IPs to whitelist\n", len(newIPs))
		fmt.Printf("  ✅ Updated: %s\n", whitelistFile)
	} else {
		fmt.Println("  ℹ️  All critical IPs already whitelisted")
	}
	fmt.Println()

	// Step 7: Success!
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println("✅ NFTBan initialized successfully!")
	fmt.Println()
	fmt.Println("CRITICAL IPs whitelisted:")
	for _, ip := range allIPs {
		fmt.Printf("  ✅ %s\n", ip)
	}
	fmt.Println()
	fmt.Println("Whitelist files structure:")
	fmt.Printf("  📁 /etc/nftban/whitelist.conf (main file)\n")
	fmt.Printf("  📁 /etc/nftban/whitelist.d/*.conf (modular includes)\n")
	fmt.Printf("  📁 %s (emergency backup)\n", emergencyFile)
	fmt.Println()
	fmt.Println("You can now safely run:")
	fmt.Println("  nftban feeds update")
	fmt.Println("  nftban geoban CN --ban")
	fmt.Println("  nftban ban 1.2.3.4")
	fmt.Println()
	fmt.Println("⚠️  IMPORTANT: Keep emergency_whitelist.conf safe!")
	fmt.Printf("   Location: %s\n", emergencyFile)
	fmt.Println()

	return nil
}
