// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2024-2026 Antonios Voulvoulis
//
// meta:name="cmd_country"
// meta:type="go"
// meta:package="main"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-01-01"
// meta:description="Country block/allow management subcommand"
// meta:input="Country codes, config"
// meta:output="Country configuration updates"
// meta:depends="go"
//
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/conf.d/country.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/itcmsgr/nftban/internal/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/version"
)

// getCountryConfigPath returns the country config path from passed config
func getCountryConfigPath(cfg *nftbanconf.Config) string {
	return cfg.ConfigDir + "/conf.d/country.conf"
}

// Common country codes with names
var countryNames = map[string]string{
	"CN": "China",
	"RU": "Russia",
	"KP": "North Korea",
	"IR": "Iran",
	"SY": "Syria",
	"CU": "Cuba",
	"VE": "Venezuela",
	"BY": "Belarus",
	"MM": "Myanmar",
	"AF": "Afghanistan",
	"IQ": "Iraq",
	"LY": "Libya",
	"SD": "Sudan",
	"YE": "Yemen",
	"PK": "Pakistan",
	"BD": "Bangladesh",
	"VN": "Vietnam",
	"UA": "Ukraine",
	"TR": "Turkey",
	"BR": "Brazil",
	"IN": "India",
	"ID": "Indonesia",
	"TH": "Thailand",
	"PH": "Philippines",
	"MY": "Malaysia",
	"SA": "Saudi Arabia",
	"AE": "UAE",
	"EG": "Egypt",
	"ZA": "South Africa",
	"NG": "Nigeria",
	"KE": "Kenya",
	"US": "United States",
	"CA": "Canada",
	"GB": "United Kingdom",
	"DE": "Germany",
	"FR": "France",
	"IT": "Italy",
	"ES": "Spain",
	"NL": "Netherlands",
	"BE": "Belgium",
	"CH": "Switzerland",
	"AT": "Austria",
	"SE": "Sweden",
	"NO": "Norway",
	"DK": "Denmark",
	"FI": "Finland",
	"PL": "Poland",
	"CZ": "Czech Republic",
	"PT": "Portugal",
	"GR": "Greece",
	"IE": "Ireland",
	"AU": "Australia",
	"NZ": "New Zealand",
	"JP": "Japan",
	"KR": "South Korea",
	"SG": "Singapore",
	"HK": "Hong Kong",
	"TW": "Taiwan",
	"IL": "Israel",
	"MX": "Mexico",
	"AR": "Argentina",
	"CL": "Chile",
	"CO": "Colombia",
}

func cmdCountry(action string, cfg *nftbanconf.Config) error {
	countryConfig := getCountryConfigPath(cfg)

	switch action {
	case "list":
		return cmdCountryList(countryConfig)
	case "status":
		return cmdCountryStatus(countryConfig)
	case "enable":
		// Enable means "allow" this country (remove from block list)
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core country enable <COUNTRY_CODE> [COUNTRY_CODE...]")
		}
		codes := os.Args[3:]
		return cmdCountrySetStatus(countryConfig, codes, false)
	case "disable":
		// Disable means "block" this country
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core country disable <COUNTRY_CODE> [COUNTRY_CODE...]")
		}
		codes := os.Args[3:]
		return cmdCountrySetStatus(countryConfig, codes, true)
	case "mode":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core country mode <blacklist|whitelist>")
		}
		mode := os.Args[3]
		return cmdCountrySetMode(countryConfig, mode)
	case "apply":
		return cmdCountryApply(countryConfig)
	default:
		return fmt.Errorf("unknown country action: %s\nUsage: nftban-core country [list|status|enable|disable|mode|apply]", action)
	}
}

func cmdCountryList(configPath string) error {
	jsonOutput := hasFlag("--json")

	if jsonOutput {
		countriesData := []map[string]interface{}{}
		for code, name := range countryNames {
			countriesData = append(countriesData, map[string]interface{}{
				"code": code,
				"name": name,
			})
		}

		output := map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"countries": countriesData,
				"total":     len(countryNames),
			},
		}
		data, _ := json.MarshalIndent(output, "", "  ")
		fmt.Println(string(data))
		return nil
	}

	fmt.Println(version.BannerWithEmoji("🌍", "Country Codes"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	// Sort by code
	codes := make([]string, 0, len(countryNames))
	for code := range countryNames {
		codes = append(codes, code)
	}
	sort.Strings(codes)

	// Group by region (simplified)
	fmt.Println("Common country codes:")
	fmt.Println()

	// High-risk countries often blocked
	fmt.Println("─── Often Blocked (high attack sources) ───")
	highRisk := []string{"CN", "RU", "KP", "IR", "SY", "BY"}
	for _, code := range highRisk {
		if name, ok := countryNames[code]; ok {
			fmt.Printf("  %s - %s\n", code, name)
		}
	}
	fmt.Println()

	fmt.Println("─── All Available Codes ───")
	col := 0
	for _, code := range codes {
		fmt.Printf("  %s", code)
		col++
		if col%10 == 0 {
			fmt.Println()
		}
	}
	if col%10 != 0 {
		fmt.Println()
	}
	fmt.Println()

	fmt.Printf("Total: %d country codes available\n", len(countryNames))
	fmt.Println()
	fmt.Println("Usage:")
	fmt.Println("  nftban country disable CN RU KP   Block these countries")
	fmt.Println("  nftban country enable CN          Unblock a country")
	fmt.Println("  nftban country status             Show current blocked countries")
	fmt.Println()

	return nil
}

func cmdCountryStatus(configPath string) error {
	jsonOutput := hasFlag("--json")

	config := readCountryConfig(configPath)

	if jsonOutput {
		output := map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"enabled":           config.Enabled,
				"mode":              config.Mode,
				"blocked_count":     len(config.Blocked),
				"blocked":           config.Blocked,
				"whitelisted_count": len(config.Whitelisted),
				"whitelisted":       config.Whitelisted,
			},
		}
		data, _ := json.MarshalIndent(output, "", "  ")
		fmt.Println(string(data))
		return nil
	}

	fmt.Println(version.BannerWithEmoji("🌍", "Country Block Status"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	if !config.Enabled {
		fmt.Println("Status: DISABLED")
		fmt.Println()
		fmt.Println("Country blocking is not enabled.")
		fmt.Println("Enable with: nftban country disable CN RU  (to block countries)")
		return nil
	}

	fmt.Printf("Status: ENABLED\n")
	fmt.Printf("Mode: %s\n", strings.ToUpper(config.Mode))
	fmt.Println()

	if config.Mode == "blacklist" {
		fmt.Printf("Blocked Countries (%d):\n", len(config.Blocked))
		if len(config.Blocked) == 0 {
			fmt.Println("  (none)")
		} else {
			for _, code := range config.Blocked {
				name := countryNames[code]
				if name == "" {
					name = "Unknown"
				}
				fmt.Printf("  [X] %s - %s\n", code, name)
			}
		}
	} else {
		fmt.Printf("Allowed Countries (%d):\n", len(config.Whitelisted))
		fmt.Println("  (all other countries are BLOCKED)")
		if len(config.Whitelisted) == 0 {
			fmt.Println("  (none - ALL traffic blocked!)")
		} else {
			for _, code := range config.Whitelisted {
				name := countryNames[code]
				if name == "" {
					name = "Unknown"
				}
				fmt.Printf("  [✓] %s - %s\n", code, name)
			}
		}
	}

	fmt.Println()
	fmt.Println("Commands:")
	fmt.Println("  nftban country disable CN RU   Add countries to block list")
	fmt.Println("  nftban country enable CN       Remove country from block list")
	fmt.Println("  nftban country apply           Apply changes to firewall")
	fmt.Println()

	return nil
}

func cmdCountrySetStatus(configPath string, codes []string, block bool) error {
	// Check for privilege (root OR CAP_NET_ADMIN capability)
	if err := checkPrivilege(); err != nil {
		return err
	}

	// Validate country codes
	validCodes := []string{}
	for _, code := range codes {
		code = strings.ToUpper(strings.TrimSpace(code))
		if len(code) != 2 {
			fmt.Printf("⚠️  Skipping invalid code: %s (must be 2 letters)\n", code)
			continue
		}
		validCodes = append(validCodes, code)
	}

	if len(validCodes) == 0 {
		return fmt.Errorf("no valid country codes provided")
	}

	// Read existing config
	config := readCountryConfig(configPath)
	config.Enabled = true

	if block {
		// Add to blocked list
		for _, code := range validCodes {
			if !contains(config.Blocked, code) {
				config.Blocked = append(config.Blocked, code)
			}
			// Remove from whitelist if present
			config.Whitelisted = removeString(config.Whitelisted, code)
		}
		fmt.Printf("✅ Countries blocked: %s\n", strings.Join(validCodes, ", "))
	} else {
		// Remove from blocked list
		for _, code := range validCodes {
			config.Blocked = removeString(config.Blocked, code)
		}
		fmt.Printf("✅ Countries unblocked: %s\n", strings.Join(validCodes, ", "))
	}

	// Write config
	if err := writeCountryConfig(configPath, config); err != nil {
		return fmt.Errorf("failed to save config: %w", err)
	}

	fmt.Println()
	fmt.Printf("Current blocked list: %s\n", strings.Join(config.Blocked, ", "))
	fmt.Println()
	fmt.Println("Run 'nftban country apply' to apply changes to firewall")

	return nil
}

func cmdCountrySetMode(configPath, mode string) error {
	// Check for privilege (root OR CAP_NET_ADMIN capability)
	if err := checkPrivilege(); err != nil {
		return err
	}

	mode = strings.ToLower(mode)
	if mode != "blacklist" && mode != "whitelist" {
		return fmt.Errorf("invalid mode: %s (must be 'blacklist' or 'whitelist')", mode)
	}

	config := readCountryConfig(configPath)
	config.Mode = mode
	config.Enabled = true

	if err := writeCountryConfig(configPath, config); err != nil {
		return fmt.Errorf("failed to save config: %w", err)
	}

	fmt.Printf("✅ Country blocking mode set to: %s\n", strings.ToUpper(mode))
	fmt.Println()

	if mode == "blacklist" {
		fmt.Println("Blacklist mode: Listed countries will be BLOCKED")
		fmt.Println("  nftban country disable CN RU   Block China and Russia")
	} else {
		fmt.Println("Whitelist mode: ONLY listed countries will be ALLOWED")
		fmt.Println("  ⚠️  WARNING: This will block ALL traffic except whitelisted countries!")
		fmt.Println("  nftban country enable US GB DE   Allow only these countries")
	}

	return nil
}

func cmdCountryApply(configPath string) error {
	// Check for privilege (root OR CAP_NET_ADMIN capability)
	if err := checkPrivilege(); err != nil {
		return err
	}

	fmt.Println(version.BannerWithEmoji("🌍", "Apply Country Blocking"))
	fmt.Println(strings.Repeat("=", 70))
	fmt.Println()

	config := readCountryConfig(configPath)

	if !config.Enabled {
		fmt.Println("Country blocking is DISABLED.")
		fmt.Println("Use 'nftban country disable CN RU' to block countries first.")
		return nil
	}

	if config.Mode == "blacklist" && len(config.Blocked) == 0 {
		fmt.Println("No countries in block list.")
		fmt.Println("Use 'nftban country disable CN RU' to add countries to block.")
		return nil
	}

	if config.Mode == "whitelist" && len(config.Whitelisted) == 0 {
		fmt.Println("⚠️  WARNING: Whitelist mode with no allowed countries!")
		fmt.Println("This would block ALL traffic. Please add allowed countries first:")
		fmt.Println("  nftban country enable US GB DE")
		return fmt.Errorf("cannot apply empty whitelist")
	}

	fmt.Printf("Mode: %s\n", strings.ToUpper(config.Mode))
	if config.Mode == "blacklist" {
		fmt.Printf("Blocking %d countries: %s\n", len(config.Blocked), strings.Join(config.Blocked, ", "))
	} else {
		fmt.Printf("Allowing ONLY %d countries: %s\n", len(config.Whitelisted), strings.Join(config.Whitelisted, ", "))
	}
	fmt.Println()

	// Note: Actual geoblock implementation requires IP-to-country mapping
	// This would use the GeoIP database and create nftables rules
	fmt.Println("⚠️  Note: Country blocking requires GeoIP data integration.")
	fmt.Println("   Current implementation saves configuration only.")
	fmt.Println("   Full geoblock integration requires nftables geoip module or")
	fmt.Println("   pre-processed country IP lists (like ipdeny.com).")
	fmt.Println()
	configDir := filepath.Dir(filepath.Dir(configPath))
	fmt.Println("Configuration file: " + filepath.Join(configDir, "nftban.conf.local"))
	fmt.Println()

	return nil
}

// CountryConfig holds country blocking configuration
type CountryConfig struct {
	Enabled     bool
	Mode        string   // "blacklist" or "whitelist"
	Blocked     []string // Countries to block (blacklist mode)
	Whitelisted []string // Countries to allow (whitelist mode)
}

// readCountryConfig reads country config from the override chain:
// conf.d/country.conf → conf.d/country.conf.local → nftban.conf.local
// Each layer is partial — only values present in the file override previous layers.
func readCountryConfig(configPath string) CountryConfig {
	config := CountryConfig{
		Enabled:     false,
		Mode:        "blacklist",
		Blocked:     []string{},
		Whitelisted: []string{},
	}

	// Override chain: .conf → .conf.local → nftban.conf.local
	configDir := filepath.Dir(filepath.Dir(configPath)) // conf.d/country.conf → /etc/nftban
	configFiles := []string{
		configPath,
		configPath + ".local",
		filepath.Join(configDir, "nftban.conf.local"),
	}

	for _, file := range configFiles {
		content, err := os.ReadFile(file)
		if err != nil {
			continue
		}
		parseCountryContent(&config, string(content))
	}

	return config
}

// parseCountryContent parses COUNTRY_* variables from config content
func parseCountryContent(config *CountryConfig, content string) {
	lines := strings.Split(content, "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}

		key := strings.TrimSpace(parts[0])
		value := strings.Trim(parts[1], `"' `)

		switch key {
		case "COUNTRY_ENABLED":
			config.Enabled = (value == "true")
		case "COUNTRY_MODE":
			config.Mode = value
		case "COUNTRY_BLOCKED":
			if value != "" {
				config.Blocked = strings.Split(value, ",")
				for i := range config.Blocked {
					config.Blocked[i] = strings.TrimSpace(config.Blocked[i])
				}
			}
		case "COUNTRY_WHITELISTED":
			if value != "" {
				config.Whitelisted = strings.Split(value, ",")
				for i := range config.Whitelisted {
					config.Whitelisted[i] = strings.TrimSpace(config.Whitelisted[i])
				}
			}
		}
	}
}

// writeCountryConfig writes country settings to nftban.conf.local (central override).
// Only user-changed values go here — package defaults stay in conf.d/country.conf.
func writeCountryConfig(configPath string, config CountryConfig) error {
	// Write to nftban.conf.local (central override — survives package upgrades)
	configDir := filepath.Dir(filepath.Dir(configPath)) // conf.d/country.conf → /etc/nftban
	localConf := filepath.Join(configDir, "nftban.conf.local")

	// Ensure config directory exists
	if err := os.MkdirAll(configDir, 0750); err != nil {
		return err
	}

	// Read existing content (or start fresh)
	localContent := ""
	if data, err := os.ReadFile(localConf); err == nil {
		localContent = string(data)
	}

	// Variables to write
	updates := [][2]string{
		{"COUNTRY_ENABLED", fmt.Sprintf("%v", config.Enabled)},
		{"COUNTRY_MODE", config.Mode},
		{"COUNTRY_BLOCKED", strings.Join(config.Blocked, ",")},
		{"COUNTRY_WHITELISTED", strings.Join(config.Whitelisted, ",")},
	}

	for _, pair := range updates {
		varName, varValue := pair[0], pair[1]
		newLine := fmt.Sprintf(`%s="%s"`, varName, varValue)

		// Check if variable exists and replace
		found := false
		lines := strings.Split(localContent, "\n")
		for i, line := range lines {
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, varName+"=") || strings.HasPrefix(trimmed, varName+" =") {
				lines[i] = newLine
				found = true
				break
			}
		}

		if found {
			localContent = strings.Join(lines, "\n")
		} else {
			// Append — ensure section marker exists
			if !strings.Contains(localContent, "# --- COUNTRY Configuration ---") {
				if localContent != "" && !strings.HasSuffix(localContent, "\n") {
					localContent += "\n"
				}
				localContent += "\n# --- COUNTRY Configuration ---\n"
			}
			localContent += newLine + "\n"
		}
	}

	return os.WriteFile(localConf, []byte(localContent), 0640)
}

func contains(slice []string, item string) bool {
	for _, s := range slice {
		if s == item {
			return true
		}
	}
	return false
}

func removeString(slice []string, item string) []string {
	result := []string{}
	for _, s := range slice {
		if s != item {
			result = append(result, s)
		}
	}
	return result
}
