// =============================================================================
// NFTBan v1.0 - Watchdog Config Loader
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// Loads watchdog configuration from /etc/nftban/conf.d/watchdog.conf
// Falls back to defaults for missing values.
//
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/conf.d/watchdog.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package watchdog

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// LoadConfig loads watchdog configuration from file.
// Override chain: watchdog.conf → watchdog.conf.local → nftban.conf.local
// Each layer is partial — only values present in the file override previous layers.
func LoadConfig(configPath string) *Config {
	cfg := DefaultConfig()

	if configPath == "" {
		configPath = "/etc/nftban/conf.d/watchdog.conf"
	}

	// 1. Load package defaults from watchdog.conf
	if values, err := loadConfigFile(configPath); err == nil {
		applyConfigValues(cfg, values)
	}

	// 2. Load user overrides from watchdog.conf.local (survives upgrades)
	localPath := configPath + ".local"
	if values, err := loadConfigFile(localPath); err == nil {
		applyConfigValues(cfg, values)
	}

	// 3. Load central override from nftban.conf.local (highest priority)
	configDir := filepath.Dir(filepath.Dir(configPath)) // conf.d/watchdog.conf → /etc/nftban
	centralLocal := filepath.Join(configDir, "nftban.conf.local")
	if values, err := loadConfigFile(centralLocal); err == nil {
		applyConfigValues(cfg, values)
	}

	cfg.Validate()

	return cfg
}

// loadConfigFile reads a KEY=value config file
func loadConfigFile(path string) (map[string]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	values := make(map[string]string)
	scanner := bufio.NewScanner(f)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())

		// Skip comments and empty lines
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Parse KEY="value" or KEY=value
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}

		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])

		// Remove quotes
		value = strings.Trim(value, "\"'")

		values[key] = value
	}

	return values, nil
}

// applyConfigValues applies loaded values to config
func applyConfigValues(cfg *Config, values map[string]string) {
	// Enable/disable
	if v, ok := values["NFTBAN_DYNAMIC_WATCHDOG_ENABLED"]; ok {
		cfg.Enabled = parseBool(v, true)
	}

	// Base interval
	if v, ok := values["NFTBAN_DYNAMIC_WATCHDOG_INTERVAL"]; ok {
		if secs, err := strconv.Atoi(v); err == nil {
			cfg.BaseInterval = time.Duration(secs) * time.Second
		}
	}

	// Hysteresis
	if v, ok := values["NFTBAN_PRESSURE_WARN_ENTER"]; ok {
		cfg.HysteresisWarnEnter = parseFloat(v, 60)
	}
	if v, ok := values["NFTBAN_PRESSURE_WARN_EXIT"]; ok {
		cfg.HysteresisWarnExit = parseFloat(v, 50)
	}
	if v, ok := values["NFTBAN_PRESSURE_CRIT_ENTER"]; ok {
		cfg.HysteresisCritEnter = parseFloat(v, 80)
	}
	if v, ok := values["NFTBAN_PRESSURE_CRIT_EXIT"]; ok {
		cfg.HysteresisCritExit = parseFloat(v, 70)
	}
	if v, ok := values["NFTBAN_PRESSURE_WARN_EXIT_DURATION"]; ok {
		if secs, err := strconv.Atoi(v); err == nil {
			cfg.WarnExitDuration = time.Duration(secs) * time.Second
		}
	}
	if v, ok := values["NFTBAN_PRESSURE_CRIT_EXIT_DURATION"]; ok {
		if secs, err := strconv.Atoi(v); err == nil {
			cfg.CritExitDuration = time.Duration(secs) * time.Second
		}
	}

	// Budgets/Thresholds
	if v, ok := values["NFTBAN_MEM_BUDGET_BYTES"]; ok {
		if bytes, err := strconv.ParseInt(v, 10, 64); err == nil {
			cfg.MemBudgetBytes = bytes
		}
	}
	if v, ok := values["NFTBAN_RSS_CRIT_PERCENT"]; ok {
		cfg.RSSCritPercentOfBudget = parseFloat(v, 95)
	}
	if v, ok := values["NFTBAN_HEAP_CRIT_PERCENT"]; ok {
		cfg.HeapCritPercentOfLimit = parseFloat(v, 90)
	}
	if v, ok := values["NFTBAN_CPU_CRIT_PERCENT"]; ok {
		cfg.CPUCritPercent = parseFloat(v, 80)
	}
	if v, ok := values["NFTBAN_LOAD_NORMALIZED_CRIT"]; ok {
		cfg.LoadNormalizedCrit = parseFloat(v, 4.0)
	}
	if v, ok := values["NFTBAN_IOWAIT_CRIT_PERCENT"]; ok {
		cfg.IOWaitCritPercent = parseFloat(v, 40)
	}
	if v, ok := values["NFTBAN_DISK_CRIT_PERCENT"]; ok {
		cfg.DiskUseCritPercent = parseFloat(v, 95)
	}
	if v, ok := values["NFTBAN_CONNTRACK_UTIL_CRIT"]; ok {
		cfg.ConntrackUtilCrit = parseFloat(v, 0.9)
	}
	if v, ok := values["NFTBAN_SOFTNET_DROPS_RATE_CRIT"]; ok {
		cfg.SoftnetDropsRateCrit = parseFloat(v, 100)
	}
	if v, ok := values["NFTBAN_GOROUTINES_CRIT"]; ok {
		if count, err := strconv.Atoi(v); err == nil {
			cfg.GoroutinesCrit = count
		}
	}

	// Profiling
	if v, ok := values["NFTBAN_PROFILE_AUTO_ENABLED"]; ok {
		cfg.ProfileAutoEnabled = parseBool(v, true)
	}
	if v, ok := values["NFTBAN_WATCHDOG_PROFILE_DIR"]; ok {
		cfg.ProfileDir = v
	}
	if v, ok := values["NFTBAN_PROFILE_CPU_COOLDOWN"]; ok {
		if secs, err := strconv.Atoi(v); err == nil {
			cfg.ProfileCPUCooldown = time.Duration(secs) * time.Second
		}
	}
	if v, ok := values["NFTBAN_PROFILE_HEAP_COOLDOWN"]; ok {
		if secs, err := strconv.Atoi(v); err == nil {
			cfg.ProfileHeapCooldown = time.Duration(secs) * time.Second
		}
	}
	if v, ok := values["NFTBAN_PROFILE_GOROUTINE_COOLDOWN"]; ok {
		if secs, err := strconv.Atoi(v); err == nil {
			cfg.ProfileGoroutineCooldown = time.Duration(secs) * time.Second
		}
	}
	if v, ok := values["NFTBAN_PROFILE_CPU_DURATION"]; ok {
		if secs, err := strconv.Atoi(v); err == nil {
			cfg.ProfileCPUDuration = time.Duration(secs) * time.Second
		}
	}
	if v, ok := values["NFTBAN_WATCHDOG_PROFILE_MAX_COUNT"]; ok {
		if count, err := strconv.Atoi(v); err == nil {
			cfg.ProfileMaxCount = count
		}
	}

	// Memory valve
	if v, ok := values["NFTBAN_FREE_OS_MEMORY_ENABLED"]; ok {
		cfg.FreeOSMemoryEnabled = parseBool(v, true)
	}
	if v, ok := values["NFTBAN_FREE_OS_MEMORY_COOLDOWN"]; ok {
		if secs, err := strconv.Atoi(v); err == nil {
			cfg.FreeOSMemoryCooldown = time.Duration(secs) * time.Second
		}
	}
	if v, ok := values["NFTBAN_FREE_OS_MEMORY_ONLY_IF_CPU_BELOW"]; ok {
		cfg.FreeOSMemoryOnlyIfCPUBelow = parseFloat(v, 40)
	}

	// Degradation
	if v, ok := values["NFTBAN_DEGRADE_DISABLE_NFT_RULESET_SCAN"]; ok {
		cfg.DegradeDisableNFTRulesetScan = parseBool(v, true)
	}
	if v, ok := values["NFTBAN_DEGRADE_REDUCE_WORKERS_TO"]; ok {
		if count, err := strconv.Atoi(v); err == nil {
			cfg.DegradeReduceWorkersTo = count
		}
	}
	if v, ok := values["NFTBAN_SURVIVAL_REDUCE_WORKERS_TO"]; ok {
		if count, err := strconv.Atoi(v); err == nil {
			cfg.SurvivalReduceWorkersTo = count
		}
	}
	if v, ok := values["NFTBAN_DEGRADED_INTERVAL_MULTIPLIER"]; ok {
		cfg.DegradedIntervalMultiplier = parseFloat(v, 2.0)
	}

	// Flight recorder
	if v, ok := values["NFTBAN_RECORDER_ENABLED"]; ok {
		cfg.RecorderEnabled = parseBool(v, true)
	}
	if v, ok := values["NFTBAN_RECORDER_DIR"]; ok {
		cfg.RecorderDir = v
	}
	if v, ok := values["NFTBAN_RECORDER_MAX_EVENTS"]; ok {
		if count, err := strconv.Atoi(v); err == nil {
			cfg.RecorderMaxEvents = count
		}
	}
	if v, ok := values["NFTBAN_RECORDER_SNAPSHOT_INTERVAL"]; ok {
		if secs, err := strconv.Atoi(v); err == nil {
			cfg.RecorderSnapshotInterval = time.Duration(secs) * time.Second
		}
	}
	if v, ok := values["NFTBAN_RECORDER_RETENTION_DAYS"]; ok {
		if days, err := strconv.Atoi(v); err == nil {
			cfg.RecorderRetentionDays = days
		}
	}
}

// parseBool parses a bool value with default
func parseBool(s string, def bool) bool {
	s = strings.ToLower(strings.TrimSpace(s))
	switch s {
	case "true", "yes", "1", "on":
		return true
	case "false", "no", "0", "off":
		return false
	default:
		return def
	}
}

// parseFloat parses a float value with default
func parseFloat(s string, def float64) float64 {
	if f, err := strconv.ParseFloat(s, 64); err == nil {
		return f
	}
	return def
}
