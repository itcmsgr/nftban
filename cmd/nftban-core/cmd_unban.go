// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="cmd_unban"
// meta:type="go"
// meta:package="main"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-01-01"
// meta:description="Unban IP subcommand for removing bans"
// meta:input="IP address, config"
// meta:output="nftables unban operation, logging"
// meta:depends="go,nftables"
//
// meta:inventory.files=""
// meta:inventory.binaries="nft"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="cap_net_admin"

package main

import (
	"fmt"
	"strings"

	"github.com/itcmsgr/nftban/internal/banlog"
	"github.com/itcmsgr/nftban/internal/blacklist"
	"github.com/itcmsgr/nftban/internal/geoip"
	"github.com/itcmsgr/nftban/pkg/ipc"
	"github.com/itcmsgr/nftban/internal/netutil"
	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/version"
)

// getUnbanConfigDir returns the config directory from passed config
func getUnbanConfigDir(cfg *nftbanconf.Config) string {
	return cfg.ConfigDir
}

func cmdUnban(ipStr string, cfg *nftbanconf.Config) error {
	// Check for privilege (root OR CAP_NET_ADMIN capability)
	if err := checkPrivilege(); err != nil {
		return err
	}

	fmt.Printf("%s: %s\n", version.BannerWithEmoji("🛡️", "Unban IP"), ipStr)
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Validate IP
	fmt.Println("Step 1: Validating IP address...")
	normalizedIP, isIPv4, err := netutil.ValidateAndNormalizeIP(ipStr)
	if err != nil {
		return fmt.Errorf("invalid IP: %w", err)
	}
	ipType := "IPv6"
	if isIPv4 {
		ipType = "IPv4"
	}
	fmt.Printf("  ✅ Valid %s address: %s\n", ipType, normalizedIP)
	fmt.Println()

	// Check if currently banned (in files OR in nftables)
	fmt.Println("Step 2: Checking if IP is banned...")
	configDir := getUnbanConfigDir(cfg)
	blacklistIPv4, blacklistIPv6, err := blacklist.LoadAllBlacklists(configDir)
	if err != nil {
		return fmt.Errorf("failed to load blacklists: %w", err)
	}

	isBannedInFile := false
	if isIPv4 {
		isBannedInFile = blacklistIPv4[normalizedIP]
	} else {
		isBannedInFile = blacklistIPv6[normalizedIP]
	}

	// Also check nftables via IPC (handles orphan entries not in files)
	ipcClient := ipc.NewClient()
	isBannedInNFT := false

	resp, err := ipcClient.Check(normalizedIP)
	if err != nil {
		// Daemon not running - warn but continue with file-based unban
		fmt.Printf("  ⚠️  Could not check nftables (daemon not running?): %v\n", err)
	} else if resp.Success {
		if data, ok := resp.Data.(map[string]any); ok {
			if banned, ok := data["banned"].(bool); ok && banned {
				isBannedInNFT = true
			}
		}
	}

	if !isBannedInFile && !isBannedInNFT {
		fmt.Printf("  ⚠️  IP %s is not currently banned\n", normalizedIP)
		fmt.Println()
		fmt.Println("Nothing to do - IP is already not banned.")
		return nil
	}

	if isBannedInFile {
		fmt.Printf("  ✅ IP is in blacklist files\n")
	}
	if isBannedInNFT {
		fmt.Printf("  ✅ IP is in nftables set\n")
	}
	fmt.Println()

	// Remove from blacklist files via IPC (daemon owns all writes)
	fmt.Println("Step 3: Removing from blacklist via IPC...")
	if isBannedInFile {
		resp, err := ipcClient.UnpersistBan(normalizedIP)
		if err != nil {
			return fmt.Errorf("failed to unpersist ban via IPC: %w", err)
		}
		if !resp.Success {
			return fmt.Errorf("failed to unpersist ban: %s", resp.Error)
		}
		// Extract files modified count from response
		if data, ok := resp.Data.(map[string]any); ok {
			if filesModified, ok := data["files_modified"].(float64); ok && filesModified > 0 {
				fmt.Printf("  ✅ Removed from %d blacklist file(s)\n", int(filesModified))
			}
		}
	} else {
		fmt.Printf("  ⚠️  IP not in blacklist files (orphan in nftables)\n")
	}
	fmt.Println()

	// Remove from nftables via IPC (daemon is the single nft writer)
	fmt.Println("Step 4: Removing from nftables via IPC...")

	resp, err = ipcClient.Unban(normalizedIP)
	if err != nil {
		return fmt.Errorf("failed to unban via IPC: %w", err)
	}
	if !resp.Success {
		// Check if it's just "not found" vs a real error
		if strings.Contains(resp.Error, "not found") {
			fmt.Printf("  ⚠️  IP %s was not in nftables set\n", normalizedIP)
		} else {
			fmt.Printf("  ⚠️  Could not delete from nftables: %s\n", resp.Error)
		}
	} else {
		fmt.Printf("  ✅ Removed %s from nftables\n", normalizedIP)
	}
	fmt.Println()

	// Log the unban action
	fmt.Println("Step 5: Logging unban...")
	country, _ := geoip.LookupIP(normalizedIP)
	if country == "" {
		country = "UNK"
	}
	if err := banlog.LogUnban(normalizedIP, banlog.SourceManual, country); err != nil {
		fmt.Printf("  ⚠️  Failed to write to ban.log: %v\n", err)
	} else {
		fmt.Printf("  ✅ Unban logged to /var/log/nftban/ban.log\n")
	}
	fmt.Println()

	// Success!
	fmt.Println(strings.Repeat("=", 70))
	fmt.Printf("✅ IP %s has been UNBANNED!\n", normalizedIP)
	fmt.Println()
	fmt.Println("The IP is no longer blocked by the firewall.")
	fmt.Println()

	return nil
}
