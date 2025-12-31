package main

import (
	"fmt"
	"strings"

	"github.com/google/nftables"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/runtime"
	"github.com/itcmsgr/nftban/pkg/sync"
	"github.com/itcmsgr/nftban/pkg/version"
)

// getSyncConfigDir returns the config directory from central config
// NO FALLBACK - path must come from /etc/nftban/nftban.conf
func getSyncConfigDir() string {
	cfg := nftbanconf.MustLoad()
	return cfg.ConfigDir
}

func cmdSync() error {
	// Check for privilege (root OR CAP_NET_ADMIN capability)
	if err := checkPrivilege(); err != nil {
		return err
	}

	fmt.Println(version.BannerWithEmoji("🔄", "Differential Sync"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Initialize RuntimeState
	fmt.Println("Step 1: Loading current state from config files...")
	state := runtime.NewRuntimeState(getSyncConfigDir())

	if err := state.LoadWhitelists(); err != nil {
		return fmt.Errorf("failed to load whitelists: %w", err)
	}
	fmt.Printf("  ✅ Loaded %d IPv4 + %d IPv6 whitelist entries\n",
		len(state.WhitelistIPv4), len(state.WhitelistIPv6))

	if err := state.LoadBlacklists(); err != nil {
		return fmt.Errorf("failed to load blacklists: %w", err)
	}
	fmt.Printf("  ✅ Loaded %d IPv4 + %d IPv6 blacklist entries\n",
		len(state.BlacklistIPv4), len(state.BlacklistIPv6))
	fmt.Println()

	// Initialize nftables connection
	fmt.Println("Step 2: Connecting to nftables via netlink...")
	nft, err := sync.NewNFTManager()
	if err != nil {
		return fmt.Errorf("failed to create nftables manager: %w", err)
	}
	defer nft.Close()
	fmt.Println("  ✅ Connected to nftables")
	fmt.Println()

	// Get or create nftban table (IPv4)
	fmt.Println("Step 3: Preparing nftables infrastructure...")
	tableIPv4, err := nft.GetOrCreateTable(nftables.TableFamilyIPv4)
	if err != nil {
		return fmt.Errorf("failed to get/create IPv4 table: %w", err)
	}
	fmt.Printf("  ✅ Table 'nftban' (IPv4) ready\n")

	// Get or create nftban table (IPv6)
	tableIPv6, err := nft.GetOrCreateTable(nftables.TableFamilyIPv6)
	if err != nil {
		return fmt.Errorf("failed to get/create IPv6 table: %w", err)
	}
	fmt.Printf("  ✅ Table 'nftban' (IPv6) ready\n")

	// Create sets (use IntervalSet for whitelists to support CIDR ranges)
	whitelistIPv4Set, err := nft.GetOrCreateIntervalSet(tableIPv4, "whitelist_ipv4", true)
	if err != nil {
		return fmt.Errorf("failed to get/create whitelist_ipv4 set: %w", err)
	}
	fmt.Printf("  ✅ Set 'whitelist_ipv4' ready\n")

	whitelistIPv6Set, err := nft.GetOrCreateIntervalSet(tableIPv6, "whitelist_ipv6", false)
	if err != nil {
		return fmt.Errorf("failed to get/create whitelist_ipv6 set: %w", err)
	}
	fmt.Printf("  ✅ Set 'whitelist_ipv6' ready\n")

	blacklistIPv4Set, err := nft.GetOrCreateSet(tableIPv4, "blacklist_ipv4", true)
	if err != nil {
		return fmt.Errorf("failed to get/create blacklist_ipv4 set: %w", err)
	}
	fmt.Printf("  ✅ Set 'blacklist_ipv4' ready\n")

	blacklistIPv6Set, err := nft.GetOrCreateSet(tableIPv6, "blacklist_ipv6", false)
	if err != nil {
		return fmt.Errorf("failed to get/create blacklist_ipv6 set: %w", err)
	}
	fmt.Printf("  ✅ Set 'blacklist_ipv6' ready\n")
	fmt.Println()

	// Get snapshots from runtime state
	fmt.Println("Step 4: Performing differential sync...")
	whitelistIPv4, whitelistIPv6 := state.GetWhitelistSnapshot()
	blacklistIPv4, blacklistIPv6 := state.GetBlacklistSnapshot()

	// Perform full sync
	result, err := sync.FullSync(
		nft,
		whitelistIPv4Set, whitelistIPv6Set,
		blacklistIPv4Set, blacklistIPv6Set,
		whitelistIPv4, whitelistIPv6,
		blacklistIPv4, blacklistIPv6,
	)

	if err != nil {
		return fmt.Errorf("sync failed: %w", err)
	}

	// Update counters
	state.IncrementSyncCounter(result.Success)

	// Print results
	sync.PrintSyncResult(result)

	fmt.Println()
	fmt.Println(strings.Repeat("=", 70))

	if result.Success {
		fmt.Println("✅ Sync completed successfully!")
		fmt.Println()
		fmt.Println("Firewall is now in sync with configuration files.")
		fmt.Println()

		// Print efficiency metrics
		if result.WhitelistIPv4 != nil {
			eff := sync.GetSyncEfficiency(result.WhitelistIPv4)
			fmt.Printf("Whitelist IPv4 efficiency: %.1f%% already in sync\n", eff)
		}
		if result.BlacklistIPv4 != nil {
			eff := sync.GetSyncEfficiency(result.BlacklistIPv4)
			fmt.Printf("Blacklist IPv4 efficiency: %.1f%% already in sync\n", eff)
		}
	} else {
		fmt.Println("❌ Sync encountered errors!")
		return fmt.Errorf("sync failed")
	}

	fmt.Println()
	return nil
}
