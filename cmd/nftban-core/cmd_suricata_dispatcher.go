// =============================================================================
// NFTBan - Suricata Integration Command
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cmd_suricata"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Suricata IDS integration with profile, rules, and filter management"
// meta:input="Subcommand (status, filters, daemon, enable, disable, set-threshold, set-action, profile-*, scan, rules-*, sid-*, custom-*, recommend)"
// meta:output="Console output with Suricata configuration and status"
// meta:depends="github.com/itcmsgr/nftban/internal/suricata,github.com/itcmsgr/nftban/internal/analytics,github.com/itcmsgr/nftban/internal/nftbanconf"
// meta:inventory.files="/var/log/nftban/suricata/eve-alerts.json"
// meta:inventory.binaries="suricata"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/suricata/*.conf"
// meta:inventory.systemd_units="suricata.service"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"fmt"
	"os"

	"github.com/itcmsgr/nftban/internal/nftbanconf"
)

// getSuricataPaths returns suricata-related paths from passed config
// Note: Suricata itself uses /etc/suricata (external dependency, not nftban config)
func getSuricataPaths(cfg *nftbanconf.Config) (suricataConfigDir, evePath, logDir, dataDir string) {
	// Suricata itself uses /etc/suricata (external dependency, not nftban config)
	suricataConfigDir = "/etc/suricata"
	// NFTBan alert-only EVE output (daemon reads this file)
	evePath = "/var/log/nftban/suricata/eve-alerts.json"
	logDir = cfg.LogDir
	dataDir = cfg.DataDir
	return
}

func cmdSuricata(action string, cfg *nftbanconf.Config) error {
	switch action {
	case "status":
		return cmdSuricataStatus(cfg)
	case "filters":
		return cmdSuricataFilters(cfg)
	case "daemon":
		return cmdSuricataDaemon()
	case "enable":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core suricata enable <FILTER_NAME>")
		}
		filterName := os.Args[3]
		return cmdSuricataEnable(cfg, filterName, true)
	case "disable":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core suricata disable <FILTER_NAME>")
		}
		filterName := os.Args[3]
		return cmdSuricataEnable(cfg, filterName, false)
	case "set-threshold":
		if len(os.Args) < 5 {
			return fmt.Errorf("usage: nftban-core suricata set-threshold <FILTER_NAME> <THRESHOLD>")
		}
		filterName := os.Args[3]
		var threshold int
		if _, err := fmt.Sscanf(os.Args[4], "%d", &threshold); err != nil {
			return fmt.Errorf("invalid threshold: %w", err)
		}
		return cmdSuricataSetThreshold(cfg, filterName, threshold)
	case "set-action":
		if len(os.Args) < 5 {
			return fmt.Errorf("usage: nftban-core suricata set-action <FILTER_NAME> <ACTION>")
		}
		filterName := os.Args[3]
		actionArg := os.Args[4]
		return cmdSuricataSetAction(cfg, filterName, actionArg)

	// v1.92: Removed scope-creep commands: profile-*, scan*, rules-*, sid-*,
	// custom-*, recommend*. See V192_EXECUTION_PLAN.md Phase 2.
	case "stats-daemon":
		return cmdSuricataStatsDaemon()

	default:
		return fmt.Errorf("unknown suricata action: %s\nUsage: nftban-core suricata [status|filters|daemon|enable|disable|set-threshold|set-action|stats-daemon]", action)
	}
}
