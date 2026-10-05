// =============================================================================
// NFTBan - System IP Detection
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="detect"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Auto-detects critical IPs that must never be blocked"
// meta:input="Network interfaces, resolv.conf"
// meta:output="Server IPs, gateway, DNS servers"
// meta:depends="net,os"
// meta:inventory.files="/etc/resolv.conf"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package safety

import (
	"fmt"
	"net"
	"os"
	"strings"
)

// SystemIPs holds all critical IPs that must NEVER be blocked
type SystemIPs struct {
	ServerIPs     []net.IP    // All server interface IPs
	CurrentUserIP net.IP      // IP of current SSH connection
	GatewayIPs    []net.IP    // Default gateway
	DNSServers    []net.IP    // DNS servers from /etc/resolv.conf
	LoopbackCIDRs []net.IPNet // 127.0.0.0/8, ::1/128
}

// DetectSystemIPs auto-detects all critical IPs that must be whitelisted
func DetectSystemIPs() (*SystemIPs, error) {
	sys := &SystemIPs{}

	// 1. Detect all server IPs (all interfaces)
	serverIPs, err := detectServerIPs()
	if err != nil {
		return nil, fmt.Errorf("failed to detect server IPs: %w", err)
	}
	sys.ServerIPs = serverIPs

	// 2. Detect current user's SSH connection IP (CRITICAL!)
	userIP, err := detectCurrentUserIP()
	if err != nil {
		fmt.Fprintf(os.Stderr, "WARNING: Could not detect current user IP: %v\n", err)
		// Don't fail - just warn
	} else {
		sys.CurrentUserIP = userIP
	}

	// 3. Detect gateway IPs
	gatewayIPs, err := detectGatewayIPs()
	if err != nil {
		fmt.Fprintf(os.Stderr, "WARNING: Could not detect gateway IPs: %v\n", err)
	} else {
		sys.GatewayIPs = gatewayIPs
	}

	// 4. Detect DNS servers
	dnsIPs, err := detectDNSServers()
	if err != nil {
		fmt.Fprintf(os.Stderr, "WARNING: Could not detect DNS servers: %v\n", err)
	} else {
		sys.DNSServers = dnsIPs
	}

	// 5. Add loopback ranges (always whitelist!)
	sys.LoopbackCIDRs = []net.IPNet{
		{IP: net.IPv4(127, 0, 0, 0), Mask: net.CIDRMask(8, 32)}, // 127.0.0.0/8
		{IP: net.ParseIP("::1"), Mask: net.CIDRMask(128, 128)},  // ::1/128
	}

	return sys, nil
}

// detectServerIPs gets all IPs from all network interfaces
func detectServerIPs() ([]net.IP, error) {
	var ips []net.IP

	ifaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}

	for _, iface := range ifaces {
		// Skip loopback
		if iface.Flags&net.FlagLoopback != 0 {
			continue
		}

		// Skip down interfaces
		if iface.Flags&net.FlagUp == 0 {
			continue
		}

		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}

		for _, addr := range addrs {
			var ip net.IP
			switch v := addr.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}

			if ip != nil && !ip.IsLoopback() {
				ips = append(ips, ip)
			}
		}
	}

	return ips, nil
}

// detectCurrentUserIP detects the IP of the current SSH connection
func detectCurrentUserIP() (net.IP, error) {
	// Method 1: Check SSH_CONNECTION environment variable
	sshConn := os.Getenv("SSH_CONNECTION")
	if sshConn != "" {
		// Format: "client_ip client_port server_ip server_port"
		parts := strings.Fields(sshConn)
		if len(parts) >= 1 {
			ip := net.ParseIP(parts[0])
			if ip != nil {
				return ip, nil
			}
		}
	}

	// Method 2: Check SSH_CLIENT environment variable
	sshClient := os.Getenv("SSH_CLIENT")
	if sshClient != "" {
		// Format: "client_ip client_port server_port"
		parts := strings.Fields(sshClient)
		if len(parts) >= 1 {
			ip := net.ParseIP(parts[0])
			if ip != nil {
				return ip, nil
			}
		}
	}

	// Method 3 (v1.235): logged-in remote users from utmp, read in-process.
	// Pre-v1.235 this exec'd `who -u` then `w -h`, which SELinux enforcing
	// denies in the daemon domain (lab3 Rocky 10). Both tools read this same
	// file, so a denial is now an explicit read error rather than an exec AVC.
	// The first USER_PROCESS record wins, matching the old `who` order.
	ips, err := utmpRemoteIPs()
	if err != nil {
		return nil, fmt.Errorf("could not detect current user IP: %w", err)
	}
	if len(ips) > 0 {
		return ips[0], nil
	}

	return nil, fmt.Errorf("could not detect current user IP")
}

// detectGatewayIPs gets default gateway IPs
func detectGatewayIPs() ([]net.IP, error) {
	// v1.235: read the kernel routing tables from procfs instead of exec'ing
	// `ip route` (denied under SELinux enforcing in the daemon domain). Also
	// covers the IPv6 default route, which the old IPv4-only parse missed.
	return procDefaultGateways()
}

// detectDNSServers gets DNS server IPs from /etc/resolv.conf
func detectDNSServers() ([]net.IP, error) {
	var ips []net.IP

	data, err := os.ReadFile("/etc/resolv.conf")
	if err != nil {
		return nil, err
	}

	lines := strings.Split(string(data), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "nameserver") {
			parts := strings.Fields(line)
			if len(parts) >= 2 {
				ip := net.ParseIP(parts[1])
				if ip != nil && !ip.IsLoopback() {
					ips = append(ips, ip)
				}
			}
		}
	}

	return ips, nil
}

// PrintSystemIPs displays all detected IPs
func (s *SystemIPs) PrintSystemIPs() {
	fmt.Println("🛡️  CRITICAL IPs DETECTED (WILL BE AUTO-WHITELISTED):")
	fmt.Println()

	if len(s.ServerIPs) > 0 {
		fmt.Println("Server IPs:")
		for _, ip := range s.ServerIPs {
			fmt.Printf("  ✅ %s (server interface)\n", ip)
		}
		fmt.Println()
	}

	if s.CurrentUserIP != nil {
		fmt.Println("⚠️  YOUR CURRENT CONNECTION IP:")
		fmt.Printf("  ✅ %s (YOU - SSH connection)\n", s.CurrentUserIP)
		fmt.Println()
		fmt.Println("  ⚠️  THIS IP WILL BE WHITELISTED TO PREVENT LOCKOUT!")
		fmt.Println()
	}

	if len(s.GatewayIPs) > 0 {
		fmt.Println("Gateway IPs:")
		for _, ip := range s.GatewayIPs {
			fmt.Printf("  ✅ %s (gateway/router)\n", ip)
		}
		fmt.Println()
	}

	if len(s.DNSServers) > 0 {
		fmt.Println("DNS Servers:")
		for _, ip := range s.DNSServers {
			fmt.Printf("  ✅ %s (DNS)\n", ip)
		}
		fmt.Println()
	}

	fmt.Println("Loopback Ranges:")
	for _, cidr := range s.LoopbackCIDRs {
		fmt.Printf("  ✅ %s (localhost)\n", cidr.String())
	}
	fmt.Println()
}

// GetAllIPs returns all IPs as a flat list
func (s *SystemIPs) GetAllIPs() []net.IP {
	var all []net.IP
	all = append(all, s.ServerIPs...)
	if s.CurrentUserIP != nil {
		all = append(all, s.CurrentUserIP)
	}
	all = append(all, s.GatewayIPs...)
	all = append(all, s.DNSServers...)
	return all
}

// GetAllIPsWithCIDRs returns all IPs including loopback CIDRs
func (s *SystemIPs) GetAllIPsWithCIDRs() ([]net.IP, []net.IPNet) {
	ips := s.GetAllIPs()
	cidrs := s.LoopbackCIDRs
	return ips, cidrs
}
