package main

import (
	"fmt"
	"strings"

	"github.com/google/nftables"
	"github.com/itcmsgr/nftban/pkg/banlog"
	"github.com/itcmsgr/nftban/pkg/blacklist"
	"github.com/itcmsgr/nftban/pkg/geoip"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/sync"
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
	normalizedIP, isIPv4, err := blacklist.ValidateIP(ipStr)
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

	// Also check nftables directly (handles orphan entries not in files)
	nft, err := sync.NewNFTManager()
	if err != nil {
		return fmt.Errorf("failed to create nftables manager: %w", err)
	}
	defer nft.Close()

	var table *nftables.Table
	var setName string
	if isIPv4 {
		table, err = nft.GetOrCreateTable(nftables.TableFamilyIPv4)
		setName = "blacklist_ipv4"
	} else {
		table, err = nft.GetOrCreateTable(nftables.TableFamilyIPv6)
		setName = "blacklist_ipv6"
	}
	if err != nil {
		return fmt.Errorf("failed to get table: %w", err)
	}

	blacklistSet, err := nft.GetOrCreateSet(table, setName, isIPv4)
	if err != nil {
		return fmt.Errorf("failed to get blacklist set: %w", err)
	}

	// Check if IP is in nftables set
	isBannedInNFT := false
	currentIPs, err := nft.GetSetElements(blacklistSet)
	if err == nil {
		for _, ip := range currentIPs {
			if ip == normalizedIP {
				isBannedInNFT = true
				break
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

	// Remove from blacklist file (only if it's in files)
	fmt.Println("Step 3: Removing from blacklist...")
	if isBannedInFile {
		if err := blacklist.RemoveIP(configDir, normalizedIP); err != nil {
			return fmt.Errorf("failed to remove from blacklist: %w", err)
		}
		fmt.Printf("  ✅ Removed from blacklist.d/*.conf\n")
	} else {
		fmt.Printf("  ⚠️  IP not in blacklist files (orphan in nftables)\n")
	}
	fmt.Println()

	// Remove directly from nftables (more efficient than full sync for single IP)
	fmt.Println("Step 4: Removing from nftables...")

	// Use range-aware delete for IPv4 interval sets (handles auto-merge ranges)
	// For IPv6 or non-interval sets, fall back to simple delete
	if isIPv4 {
		// IPv4 uses interval sets with auto-merge - need range-aware delete
		if err := nft.DeleteFromIntervalSetCLI(blacklistSet, normalizedIP); err != nil {
			// Check if it's just "not found" vs a real error
			if strings.Contains(err.Error(), "not found in set") {
				fmt.Printf("  ⚠️  IP %s was not in nftables set\n", normalizedIP)
			} else {
				fmt.Printf("  ⚠️  Could not delete from nftables: %v\n", err)
			}
		} else {
			fmt.Printf("  ✅ Removed %s from nftables (range-aware)\n", normalizedIP)
		}
	} else {
		// IPv6 - use simple delete (or extend to range-aware if needed)
		if err := nft.DeleteSetElements(blacklistSet, []string{normalizedIP}); err != nil {
			fmt.Printf("  ⚠️  Could not delete from nftables: %v\n", err)
		} else {
			fmt.Printf("  ✅ Removed %s from nftables\n", normalizedIP)
		}
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
