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
// meta:depends="github.com/itcmsgr/nftban/pkg/suricata,github.com/itcmsgr/nftban/pkg/analytics,github.com/itcmsgr/nftban/pkg/nftbanconf"
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

	"github.com/itcmsgr/nftban/pkg/nftbanconf"
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

	// NEW: Profile Management
	case "profile-detect":
		return cmdSuricataProfileDetect()
	case "profile-apply":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core suricata profile-apply <PROFILE>")
		}
		profileName := os.Args[3]
		return cmdSuricataProfileApply(profileName)
	case "profile-show":
		return cmdSuricataProfileShow()
	case "profile-validate":
		return cmdSuricataProfileValidate()

	// NEW: Service Scanner
	case "scan":
		return cmdSuricataScan()
	case "scan-deep":
		return cmdSuricataScanDeep()

	// NEW: Rules Management
	case "rules-generate":
		return cmdSuricataRulesGenerate()
	case "rules-stats":
		return cmdSuricataRulesStats()
	case "rules-init":
		return cmdSuricataRulesInit()

	// NEW: SID Statistics
	case "sid-stats":
		return cmdSuricataSIDStats()
	case "sid-info":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core suricata sid-info <SID>")
		}
		return cmdSuricataSIDInfo(os.Args[3])
	case "sid-top":
		return cmdSuricataSIDTop()
	case "sid-recent":
		return cmdSuricataSIDRecent()
	case "stats-daemon":
		return cmdSuricataStatsDaemon()

	// NEW: Custom Rules Management
	case "custom-add":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core suricata custom-add <RULE>")
		}
		return cmdSuricataCustomAdd(os.Args[3])
	case "custom-remove":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core suricata custom-remove <SID>")
		}
		var sid int
		if _, err := fmt.Sscanf(os.Args[3], "%d", &sid); err != nil {
			return fmt.Errorf("invalid SID: %w", err)
		}
		return cmdSuricataCustomRemove(sid)
	case "custom-edit":
		if len(os.Args) < 5 {
			return fmt.Errorf("usage: nftban-core suricata custom-edit <SID> <NEW_RULE>")
		}
		var sid int
		if _, err := fmt.Sscanf(os.Args[3], "%d", &sid); err != nil {
			return fmt.Errorf("invalid SID: %w", err)
		}
		return cmdSuricataCustomEdit(sid, os.Args[4])
	case "custom-list":
		return cmdSuricataCustomList()
	case "custom-validate":
		return cmdSuricataCustomValidate()
	case "custom-enable":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core suricata custom-enable <SID>")
		}
		var sid int
		if _, err := fmt.Sscanf(os.Args[3], "%d", &sid); err != nil {
			return fmt.Errorf("invalid SID: %w", err)
		}
		return cmdSuricataCustomEnable(sid)
	case "custom-disable":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core suricata custom-disable <SID>")
		}
		var sid int
		if _, err := fmt.Sscanf(os.Args[3], "%d", &sid); err != nil {
			return fmt.Errorf("invalid SID: %w", err)
		}
		return cmdSuricataCustomDisable(sid)
	case "custom-backup":
		return cmdSuricataCustomBackup()
	case "custom-rollback":
		if len(os.Args) < 4 {
			return fmt.Errorf("usage: nftban-core suricata custom-rollback <BACKUP_NAME>")
		}
		return cmdSuricataCustomRollback(os.Args[3])

	// NEW: Recommendations Engine
	case "recommend":
		return cmdSuricataRecommend()
	case "recommend-summary":
		return cmdSuricataRecommendSummary()

	default:
		return fmt.Errorf("unknown suricata action: %s\nUsage: nftban-core suricata [status|filters|daemon|enable|disable|set-threshold|set-action|profile-detect|profile-apply|profile-show|profile-validate|scan|scan-deep|rules-generate|rules-stats|rules-init|sid-stats|sid-info|sid-top|sid-recent|stats-daemon|custom-add|custom-remove|custom-edit|custom-list|custom-validate|custom-enable|custom-disable|custom-backup|custom-rollback|recommend|recommend-summary]", action)
	}
}
