// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2025 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="cmd_ban"
// meta:type="go"
// meta:package="main"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-01-01"
// meta:description="Ban IP subcommand with timeout and reason support"
// meta:input="IP address, timeout, reason, source"
// meta:output="nftables ban operation, logging"
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
	"time"

	"github.com/itcmsgr/nftban/pkg/analytics"
	"github.com/itcmsgr/nftban/pkg/banlog"
	"github.com/itcmsgr/nftban/pkg/blacklist"
	"github.com/itcmsgr/nftban/pkg/geoip"
	"github.com/itcmsgr/nftban/pkg/ipc"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/persistent"
	"github.com/itcmsgr/nftban/pkg/version"
	"github.com/itcmsgr/nftban/pkg/whitelist"
)

// getBanConfigDir returns the config directory from passed config
func getBanConfigDir(cfg *nftbanconf.Config) string {
	return cfg.ConfigDir
}

// formatDuration converts seconds to human-readable format
func formatDuration(seconds int) string {
	if seconds < 60 {
		return fmt.Sprintf("%ds", seconds)
	} else if seconds < 3600 {
		return fmt.Sprintf("%dm", seconds/60)
	} else if seconds < 86400 {
		hours := seconds / 3600
		mins := (seconds % 3600) / 60
		if mins > 0 {
			return fmt.Sprintf("%dh%dm", hours, mins)
		}
		return fmt.Sprintf("%dh", hours)
	}
	days := seconds / 86400
	hours := (seconds % 86400) / 3600
	if hours > 0 {
		return fmt.Sprintf("%dd%dh", days, hours)
	}
	return fmt.Sprintf("%dd", days)
}

func cmdBan(ipStr string, reason string, source string, timeoutSeconds int, cfg *nftbanconf.Config) error {
	// Check for privilege (root OR CAP_NET_ADMIN capability)
	if err := checkPrivilege(); err != nil {
		return err
	}

	fmt.Printf("%s: %s\n", version.BannerWithEmoji("🛡️", "Ban IP"), ipStr)
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

	// Check if IP is whitelisted
	fmt.Println("Step 2: Checking whitelist...")
	configDir := getBanConfigDir(cfg)
	whitelistIPv4, whitelistIPv6, err := whitelist.LoadAllWhitelists(configDir)
	if err != nil {
		return fmt.Errorf("failed to load whitelists: %w", err)
	}

	if isIPv4 {
		if whitelistIPv4[normalizedIP] {
			return fmt.Errorf("IP %s is whitelisted, cannot ban", normalizedIP)
		}
	} else {
		if whitelistIPv6[normalizedIP] {
			return fmt.Errorf("IP %s is whitelisted, cannot ban", normalizedIP)
		}
	}
	fmt.Printf("  ✅ IP is not whitelisted\n")
	fmt.Println()

	// Check if already banned
	fmt.Println("Step 3: Checking if already banned...")
	blacklistIPv4, blacklistIPv6, err := blacklist.LoadAllBlacklists(configDir)
	if err != nil {
		return fmt.Errorf("failed to load blacklists: %w", err)
	}

	alreadyBanned := false
	if isIPv4 {
		alreadyBanned = blacklistIPv4[normalizedIP]
	} else {
		alreadyBanned = blacklistIPv6[normalizedIP]
	}

	// Step 4: Check for persistent offender (fail2ban only)
	shouldEscalate := false
	jailName := ""

	if timeoutSeconds > 0 && source == "fail2ban" {
		// Extract jail name from reason (format: "fail2ban: jail-name")
		if strings.HasPrefix(reason, "fail2ban: ") {
			jailName = strings.TrimPrefix(reason, "fail2ban: ")
		}

		// Check if this IP should escalate to permanent
		escalate, err := checkPersistentOffender(configDir, normalizedIP, jailName)
		if err != nil {
			fmt.Printf("  ⚠️  Warning: Failed to check persistent offender status: %v\n", err)
		} else if escalate {
			shouldEscalate = true
			fmt.Println()
			fmt.Println("🚨 PERSISTENT OFFENDER DETECTED")
			fmt.Printf("  ⚠️  This IP has exceeded the ban threshold\n")
			fmt.Printf("  🔒 Escalating to PERMANENT ban\n")
			fmt.Println()
			// Override: make it permanent
			timeoutSeconds = 0
		}
	}

	// Step 5: Add to appropriate location
	fmt.Println("Step 5: Adding ban...")

	if timeoutSeconds > 0 {
		// Temporary ban - add directly to NFT with timeout (no config file)
		fmt.Printf("  ⏱️  Temporary ban: %d seconds (%s)\n", timeoutSeconds, formatDuration(timeoutSeconds))
		if reason != "" {
			fmt.Printf("  ✅ Reason: %s\n", reason)
		}
		fmt.Println()
	} else {
		// Permanent ban - add to config file via IPC (daemon owns all writes)
		if alreadyBanned {
			fmt.Printf("  ⚠️  IP %s is already banned\n", normalizedIP)
			fmt.Println()
			fmt.Println("Re-syncing to ensure nftables is up to date...")
		} else {
			// Determine source for file mapping
			banSource := source
			if banSource == "" {
				banSource = "manual"
			}
			banReason := reason

			if shouldEscalate {
				// Use persistent offenders file (overrides source-based file)
				banReason = fmt.Sprintf("persistent offender (%s)", jailName)
				banSource = "persistent"
			}

			// Add to persistent blacklist via IPC
			ipcClient := ipc.NewClient()
			resp, err := ipcClient.PersistBan(normalizedIP, banReason, banSource)
			if err != nil {
				return fmt.Errorf("failed to persist ban via IPC: %w", err)
			}
			if !resp.Success {
				return fmt.Errorf("failed to persist ban: %s", resp.Error)
			}

			// Extract filename from response
			if data, ok := resp.Data.(map[string]any); ok {
				if filename, ok := data["filename"].(string); ok {
					fmt.Printf("  ✅ Added to %s/blacklist.d/%s\n", configDir, filename)
				}
			}
			if banReason != "" {
				fmt.Printf("  ✅ Reason: %s\n", banReason)
			}
			fmt.Println()
		}
	}

	// Step 6: Add to nftables via IPC (daemon is the single nft writer)
	fmt.Println("Step 6: Adding to nftables via IPC...")

	ipcClient := ipc.NewClient()
	startTime := time.Now()

	resp, err := ipcClient.Ban(normalizedIP, timeoutSeconds, reason, source)
	if err != nil {
		return fmt.Errorf("failed to ban via IPC: %w", err)
	}
	if !resp.Success {
		return fmt.Errorf("failed to ban: %s", resp.Error)
	}
	duration := time.Since(startTime)

	if timeoutSeconds > 0 {
		fmt.Printf("  ✅ Added to nftables with %s timeout in %v\n", formatDuration(timeoutSeconds), duration)
	} else {
		fmt.Printf("  ✅ Added to nftables (permanent) in %v\n", duration)
	}
	fmt.Println()

	// ════════════════════════════════════════════════════════════
	// Step 7: Record analytics and central ban log
	// ════════════════════════════════════════════════════════════
	fmt.Println("Step 7: Recording analytics...")
	country, city := lookupCountryAndCity(normalizedIP)

	// Record to analytics (JSON files for dashboard)
	if st := analytics.StateOrNil(); st != nil {
		st.RecordBan(normalizedIP, country, city, source, reason, time.Now())
		fmt.Printf("  ✅ Analytics recorded: %s (%s)\n", country, city)
	} else {
		fmt.Printf("  ⚠️  Analytics not available\n")
	}

	// Record to central ban.log (for stats dashboard)
	banSource := source
	if banSource == "" {
		banSource = banlog.SourceManual
	}
	if err := banlog.LogBan(normalizedIP, banSource, country); err != nil {
		fmt.Printf("  ⚠️  Failed to write to bans.log: %v\n", err)
	} else {
		fmt.Printf("  ✅ Ban logged to %s/bans.log\n", cfg.LogDir)
	}
	fmt.Println()

	// Success!
	fmt.Println(strings.Repeat("=", 70))
	fmt.Printf("✅ IP %s has been BANNED!\n", normalizedIP)
	fmt.Println()
	fmt.Println("The IP is now blocked by the firewall.")
	if !alreadyBanned && timeoutSeconds == 0 {
		// Show correct file based on source
		savedFile := "99-manual.conf"
		switch source {
		case "login":
			savedFile = "login-auto.conf"
		case "portscan":
			savedFile = "portscan-auto.conf"
		case "ddos":
			savedFile = "ddos-auto.conf"
		}
		if shouldEscalate {
			savedFile = "30-persistent-offenders.conf"
		}
		fmt.Printf("Entry saved to: /etc/nftban/blacklist.d/%s\n", savedFile)
	}
	fmt.Println()

	return nil
}

// lookupCountryAndCity performs GeoIP lookup for an IP address.
// Returns country code and city name, or "UNK"/"Unknown" if lookup fails.
func lookupCountryAndCity(ip string) (string, string) {
	country, city := geoip.LookupIP(ip)

	// Use defaults if lookup failed
	if country == "" {
		country = "UNK"
	}
	if city == "" {
		city = "Unknown"
	}

	return country, city
}

// checkPersistentOffender checks if an IP should be escalated to permanent ban
// Returns true if threshold exceeded
func checkPersistentOffender(configDir, ip, jailName string) (bool, error) {
	// Load configuration
	cfg, err := persistent.LoadConfig(configDir)
	if err != nil {
		return false, fmt.Errorf("failed to load persistent offender config: %w", err)
	}

	if !cfg.Enabled {
		return false, nil // Feature disabled
	}

	// Get filter-specific configuration (was jail in v0.7)
	jailCfg := cfg.GetFilterConfig(jailName)

	// Log this temp ban for escalation tracking
	if err := persistent.LogTempBan(cfg.BanLog, ip, jailName, fmt.Sprintf("temp ban from %s", jailName)); err != nil {
		return false, fmt.Errorf("failed to log ban: %w", err)
	}

	// Count recent bans for this IP
	banCount, err := persistent.CountRecentBans(cfg.BanLog, ip, jailCfg.Period)
	if err != nil {
		return false, fmt.Errorf("failed to count bans: %w", err)
	}

	// Check if threshold exceeded
	if banCount >= jailCfg.Threshold {
		// Log persistent offender
		if err := persistent.LogPersistentOffender(cfg.OffendersLog, ip, jailName, banCount); err != nil {
			// Log error but don't fail the ban
			fmt.Printf("  ⚠️  Warning: Failed to log persistent offender: %v\n", err)
		}

		// Add to persistent offenders file
		reason := fmt.Sprintf(">=%d bans in %s", jailCfg.Threshold, jailCfg.Period)
		if err := persistent.AddToPersistentOffenders(cfg.OffendersConf, ip, reason); err != nil {
			return false, fmt.Errorf("failed to add to persistent offenders: %w", err)
		}

		return true, nil
	}

	return false, nil
}
