// SPDX-License-Identifier: MPL-2.0
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
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/pkg/analytics"
	"github.com/itcmsgr/nftban/pkg/blacklist"
	"github.com/itcmsgr/nftban/pkg/geoip"
	"github.com/itcmsgr/nftban/pkg/ipc"
	"github.com/itcmsgr/nftban/pkg/netutil"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/opqueue"
	"github.com/itcmsgr/nftban/pkg/persistent"
	"github.com/itcmsgr/nftban/pkg/timeutil"
	"github.com/itcmsgr/nftban/pkg/version"
	"github.com/itcmsgr/nftban/pkg/whitelist"
)

// getBanConfigDir returns the config directory from passed config
func getBanConfigDir(cfg *nftbanconf.Config) string {
	return cfg.ConfigDir
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

	// Step 4: Check for persistent offender escalation (all temp ban sources)
	fmt.Println("Step 4: Checking persistent offender status...")
	shouldEscalate := false
	filterName := source
	if filterName == "" {
		filterName = "manual"
	}

	if timeoutSeconds > 0 {
		// Check if this IP should escalate to permanent ban
		// Uses per-filter thresholds from conf.d/persistent.conf
		escalate, err := checkPersistentOffender(configDir, normalizedIP, filterName)
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
		} else {
			fmt.Printf("  ✅ Not a repeat offender\n")
		}
	} else {
		fmt.Printf("  ✅ Permanent ban requested\n")
	}
	fmt.Println()

	// Step 5: Add to appropriate location
	fmt.Println("Step 5: Adding ban...")

	if timeoutSeconds > 0 {
		// Temporary ban - add directly to NFT with timeout (no config file)
		fmt.Printf("  ⏱️  Temporary ban: %d seconds (%s)\n", timeoutSeconds, timeutil.FormatDurationSeconds(timeoutSeconds))
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
				banReason = fmt.Sprintf("persistent offender (%s)", filterName)
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

	// v1.33.0: Determine target set for display (P0-10)
	banSource := source
	if banSource == "" {
		banSource = "manual"
	}
	targetSet := opqueue.GetTargetSet(banSource, normalizedIP)
	setType := "hash set"
	if strings.Contains(targetSet, "blacklist_ipv4") && !strings.Contains(targetSet, "manual") ||
		strings.Contains(targetSet, "blacklist_ipv6") && !strings.Contains(targetSet, "manual") {
		setType = "interval set"
	}

	ipcClient := ipc.NewClient()
	startTime := time.Now()

	// v1.33.0: Progress indicator for slow operations (P0-9)
	// Show spinner if ban takes >2s (typically interval set operations on large sets)
	var banResp *ipc.Response
	var banErr error
	var wg sync.WaitGroup
	done := make(chan struct{})

	wg.Add(1)
	go func() {
		defer wg.Done()
		banResp, banErr = ipcClient.Ban(normalizedIP, timeoutSeconds, reason, source)
		close(done)
	}()

	// Spinner loop — only activate after 2s
	spinnerShown := false
	ticker := time.NewTicker(500 * time.Millisecond)
	spinChars := []rune{'⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'}
	spinIdx := 0

	waitLoop:
	for {
		select {
		case <-done:
			break waitLoop
		case <-ticker.C:
			if time.Since(startTime) > 2*time.Second {
				if !spinnerShown {
					fmt.Printf("  %c Banning %s... (large %s, please wait)", spinChars[spinIdx], normalizedIP, setType)
					spinnerShown = true
				} else {
					fmt.Printf("\r  %c Banning %s... (large %s, please wait)", spinChars[spinIdx], normalizedIP, setType)
				}
				spinIdx = (spinIdx + 1) % len(spinChars)
			}
		}
	}
	ticker.Stop()
	wg.Wait()

	if spinnerShown {
		fmt.Print("\r" + strings.Repeat(" ", 80) + "\r") // Clear spinner line
	}

	if banErr != nil {
		return fmt.Errorf("failed to ban via IPC: %w", banErr)
	}
	if !banResp.Success {
		return fmt.Errorf("failed to ban: %s", banResp.Error)
	}
	duration := time.Since(startTime)

	// v1.33.0: Human-friendly timing with set type (P0-10)
	durationStr := formatBanDuration(duration)
	if timeoutSeconds > 0 {
		fmt.Printf("  ✅ Added to nftables with %s timeout in %s (%s)\n", timeutil.FormatDurationSeconds(timeoutSeconds), durationStr, setType)
	} else {
		fmt.Printf("  ✅ Added to nftables (permanent) in %s (%s)\n", durationStr, setType)
	}

	// v1.33.0: Post-ban verification — confirm element is in kernel set (P0-8)
	if verifyErr := verifyBanInKernel(normalizedIP, targetSet, isIPv4); verifyErr != nil {
		fmt.Printf("  ⚠️  Verification: %v\n", verifyErr)
	} else {
		fmt.Printf("  ✓  Verified: %s is in %s\n", normalizedIP, targetSet)
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

	// NOTE: bans.log is written by the daemon (nftband) via IPC handler
	// Do NOT log here to avoid duplicate entries
	fmt.Printf("  ✅ Ban logged to %s/bans.log (via daemon)\n", cfg.LogDir)
	fmt.Println()

	// Success!
	fmt.Println(strings.Repeat("=", 70))
	fmt.Printf("✅ IP %s has been BANNED!\n", normalizedIP)
	fmt.Println()
	// Show total ban count
	totalBans := len(blacklistIPv4) + len(blacklistIPv6)
	if !alreadyBanned {
		totalBans++ // Count the one we just added
	}
	fmt.Printf("The IP is now blocked by the firewall. (Total bans: %d)\n", totalBans)
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

// checkPersistentOffender checks if an IP should be escalated to permanent ban.
// Uses per-filter thresholds from conf.d/persistent.conf (falls back to global defaults).
// Returns true if ban count within the configured period exceeds the threshold.
func checkPersistentOffender(configDir, ip, filterName string) (bool, error) {
	// Load configuration
	cfg, err := persistent.LoadConfig(configDir)
	if err != nil {
		return false, fmt.Errorf("failed to load persistent offender config: %w", err)
	}

	if !cfg.Enabled {
		return false, nil // Feature disabled
	}

	// Get filter-specific configuration (or global defaults)
	filterCfg := cfg.GetFilterConfig(filterName)

	// Log this temp ban for escalation tracking
	if err := persistent.LogTempBan(cfg.BanLog, ip, filterName, fmt.Sprintf("temp ban from %s", filterName)); err != nil {
		return false, fmt.Errorf("failed to log ban: %w", err)
	}

	// Count recent bans for this IP within the configured period
	banCount, err := persistent.CountRecentBans(cfg.BanLog, ip, filterCfg.Period)
	if err != nil {
		return false, fmt.Errorf("failed to count bans: %w", err)
	}

	// Check if threshold exceeded
	if banCount >= filterCfg.Threshold {
		// Log persistent offender
		if err := persistent.LogPersistentOffender(cfg.OffendersLog, ip, filterName, banCount); err != nil {
			// Log error but don't fail the ban
			fmt.Printf("  ⚠️  Warning: Failed to log persistent offender: %v\n", err)
		}

		// Add to persistent offenders file
		reason := fmt.Sprintf(">=%d bans in %s from %s", filterCfg.Threshold, filterCfg.Period, filterName)
		if err := persistent.AddToPersistentOffenders(cfg.OffendersConf, ip, reason); err != nil {
			return false, fmt.Errorf("failed to add to persistent offenders: %w", err)
		}

		return true, nil
	}

	return false, nil
}

// verifyBanInKernel confirms that an IP is present in the specified nft set.
// Uses "nft get element" which returns exit 0 if found, non-zero if not.
func verifyBanInKernel(ip, setName string, isIPv4 bool) error {
	family := "ip"
	if !isIPv4 {
		family = "ip6"
	}
	// nft get element ip nftban blacklist_manual_ipv4 { 1.2.3.4 }
	//nolint:gosec // ip and setName are validated upstream
	cmd := exec.Command("nft", "get", "element", family, "nftban", setName, "{ "+ip+" }")
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s not found in %s (kernel verification failed)", ip, setName)
	}
	return nil
}

// formatBanDuration returns a human-friendly duration string.
func formatBanDuration(d time.Duration) string {
	switch {
	case d < time.Millisecond:
		return fmt.Sprintf("%dµs", d.Microseconds())
	case d < time.Second:
		return fmt.Sprintf("%dms", d.Milliseconds())
	case d < time.Minute:
		return fmt.Sprintf("%.1fs", d.Seconds())
	default:
		return fmt.Sprintf("%.0fs", d.Seconds())
	}
}
