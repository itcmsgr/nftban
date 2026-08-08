// SPDX-License-Identifier: MPL-2.0
// Copyright (c) 2024-2026 Antonios Voulvoulis
//
// meta:name="usage"
// meta:type="go"
// meta:package="main"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-01-01"
// meta:description="Centralized usage strings for CLI subcommands"
// meta:input="None"
// meta:output="Usage text to stderr"
// meta:depends="go"
//
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"

package main

import (
	"fmt"
	"os"
)

// usageBan prints usage for the ban command
func usageBan() {
	fmt.Fprintln(os.Stderr, "Usage: nftban-core ban <IP> [OPTIONS]")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Ban an IP address from accessing the system.")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Options:")
	fmt.Fprintln(os.Stderr, "  --timeout <seconds>  Ban duration (default: permanent)")
	fmt.Fprintln(os.Stderr, "  --reason <text>      Reason for ban")
	fmt.Fprintln(os.Stderr, "  --source <source>    Source tag (login, portscan, manual, suricata, etc.)")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Examples:")
	fmt.Fprintln(os.Stderr, "  nftban-core ban 1.2.3.4")
	fmt.Fprintln(os.Stderr, "  nftban-core ban 1.2.3.4 --reason \"SSH brute force\"")
	fmt.Fprintln(os.Stderr, "  nftban-core ban 1.2.3.4 --timeout 3600 --source login")
}

// usageUnban prints usage for the unban command
func usageUnban() {
	fmt.Fprintln(os.Stderr, "Usage: nftban-core unban <IP>")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Remove an IP address from the ban list.")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Examples:")
	fmt.Fprintln(os.Stderr, "  nftban-core unban 1.2.3.4")
	fmt.Fprintln(os.Stderr, "  nftban-core unban 2001:db8::1")
}

// usageCheck prints usage for the check command
func usageCheck() {
	fmt.Fprintln(os.Stderr, "Usage: nftban-core check <IP>")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Check if an IP is whitelisted, blacklisted, or not in any list.")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Examples:")
	fmt.Fprintln(os.Stderr, "  nftban-core check 1.2.3.4")
	fmt.Fprintln(os.Stderr, "  nftban-core check 2001:db8::1")
}

// usageFeeds prints usage for the feeds command
func usageFeeds() {
	fmt.Fprintln(os.Stderr, "Usage: nftban-core feeds <action> [FEED_NAME]")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Manage threat intelligence feeds.")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Actions:")
	fmt.Fprintln(os.Stderr, "  list     List available feeds")
	fmt.Fprintln(os.Stderr, "  load     Load and apply enabled feeds")
	fmt.Fprintln(os.Stderr, "  stats    Show feed statistics")
	fmt.Fprintln(os.Stderr, "  update   Download latest feed data")
	fmt.Fprintln(os.Stderr, "  enable   Enable a feed by name")
	fmt.Fprintln(os.Stderr, "  disable  Disable a feed by name")
	fmt.Fprintln(os.Stderr, "  sync     Sync all enabled feeds")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Examples:")
	fmt.Fprintln(os.Stderr, "  nftban-core feeds list")
	fmt.Fprintln(os.Stderr, "  nftban-core feeds enable firehol_level1")
}

// usageTrust prints usage for the trust command
func usageTrust() {
	fmt.Fprintln(os.Stderr, "Usage: nftban-core trust <action>")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Manage trusted IP sources (Cloudflare, AWS, Google, etc.).")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Actions:")
	fmt.Fprintln(os.Stderr, "  list     List available trust sources")
	fmt.Fprintln(os.Stderr, "  enable   Enable a trust source")
	fmt.Fprintln(os.Stderr, "  disable  Disable a trust source")
	fmt.Fprintln(os.Stderr, "  update   Update trust source IP ranges")
	fmt.Fprintln(os.Stderr, "  load     Load and apply enabled trust sources")
}

// usageCountry prints usage for the country command
func usageCountry() {
	fmt.Fprintln(os.Stderr, "Usage: nftban-core country <action> [COUNTRY_CODE]")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Manage country-based blocking (geo-blocking).")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Actions:")
	fmt.Fprintln(os.Stderr, "  list     List all countries with status")
	fmt.Fprintln(os.Stderr, "  status   Show geo-blocking status")
	fmt.Fprintln(os.Stderr, "  enable   Enable blocking for a country (e.g., CN, RU)")
	fmt.Fprintln(os.Stderr, "  disable  Disable blocking for a country")
	fmt.Fprintln(os.Stderr, "  mode     Set mode (whitelist or blacklist)")
	fmt.Fprintln(os.Stderr, "  apply    Apply country rules to nftables")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Examples:")
	fmt.Fprintln(os.Stderr, "  nftban-core country enable CN")
	fmt.Fprintln(os.Stderr, "  nftban-core country mode blacklist")
}

// usagePorts prints usage for the ports command
func usagePorts() {
	fmt.Fprintln(os.Stderr, "Usage: nftban-core ports <action>")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Manage port access rules.")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Actions:")
	fmt.Fprintln(os.Stderr, "  list     List configured port rules")
	fmt.Fprintln(os.Stderr, "  load     Load and apply port rules")
	fmt.Fprintln(os.Stderr, "  status   Show port configuration status")
}

// usageGeoip prints usage for the geoip command
func usageGeoip() {
	fmt.Fprintln(os.Stderr, "Usage: nftban-core geoip <action> [IP]")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Manage GeoIP database and lookups.")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Actions:")
	fmt.Fprintln(os.Stderr, "  update   Download/update GeoIP database")
	fmt.Fprintln(os.Stderr, "  status   Show GeoIP database status")
	fmt.Fprintln(os.Stderr, "  lookup   Look up country for an IP address")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Examples:")
	fmt.Fprintln(os.Stderr, "  nftban-core geoip update")
	fmt.Fprintln(os.Stderr, "  nftban-core geoip lookup 8.8.8.8")
}

// usageSuricata prints usage for the suricata command
func usageSuricata() {
	fmt.Fprintln(os.Stderr, "Usage: nftban-core suricata <action>")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Manage Suricata IDS integration.")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Actions:")
	fmt.Fprintln(os.Stderr, "  status         Show Suricata integration status")
	fmt.Fprintln(os.Stderr, "  filters        List active alert filters")
	fmt.Fprintln(os.Stderr, "  enable         Enable Suricata integration")
	fmt.Fprintln(os.Stderr, "  disable        Disable Suricata integration")
	fmt.Fprintln(os.Stderr, "  set-threshold  Set ban threshold score")
	fmt.Fprintln(os.Stderr, "  set-action     Set action (ban, log, alert)")
}

// usageAnalytics prints usage for the analytics command
func usageAnalytics() {
	fmt.Fprintln(os.Stderr, "Usage: nftban-core analytics <action> [OPTIONS]")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "View ban analytics and statistics.")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Actions:")
	fmt.Fprintln(os.Stderr, "  summary    Show overall ban summary")
	fmt.Fprintln(os.Stderr, "  countries  Show bans by country")
	fmt.Fprintln(os.Stderr, "  top        Show top banned IPs")
	fmt.Fprintln(os.Stderr, "  ip <IP>    Show details for specific IP")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Options:")
	fmt.Fprintln(os.Stderr, "  --json     Output in JSON format (for GUI)")
	fmt.Fprintln(os.Stderr)
	fmt.Fprintln(os.Stderr, "Examples:")
	fmt.Fprintln(os.Stderr, "  nftban-core analytics summary --json")
	fmt.Fprintln(os.Stderr, "  nftban-core analytics top")
}

// errorWithUsage prints an error and the usage for a specific command
func errorWithUsage(cmd string, msg string) {
	fmt.Fprintf(os.Stderr, "Error: %s\n\n", msg)
	switch cmd {
	case "ban":
		usageBan()
	case "unban":
		usageUnban()
	case "check":
		usageCheck()
	case "feeds":
		usageFeeds()
	case "trust":
		usageTrust()
	case "country":
		usageCountry()
	case "ports":
		usagePorts()
	case "geoip":
		usageGeoip()
	case "suricata":
		usageSuricata()
	case "analytics":
		usageAnalytics()
	default:
		printUsage()
	}
}
