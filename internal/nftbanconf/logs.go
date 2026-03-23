// =============================================================================
// NFTBan - Log Files Registry
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="logs"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Centralized log file paths and management helpers"
// meta:input="None"
// meta:output="Log file paths and metadata"
// meta:depends="path/filepath"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package nftbanconf

// =============================================================================
// Log Files Registry
// =============================================================================
// Centralizes all log file paths and provides helpers for log management.
// All paths are derived from the central configuration.
// =============================================================================

import (
	"path/filepath"
)

// LogCategory represents different log categories
type LogCategory string

const (
	LogCategoryMain        LogCategory = "main"
	LogCategoryAudit       LogCategory = "audit"
	LogCategoryBans        LogCategory = "bans"
	LogCategoryPortscan    LogCategory = "portscan"
	LogCategoryDDoS        LogCategory = "ddos"
	LogCategoryLoginAlert  LogCategory = "login_alert"
	LogCategoryFeeds       LogCategory = "feeds"
	LogCategoryGeoban      LogCategory = "geoban"
	LogCategoryCron        LogCategory = "cron"
	LogCategoryMaintenance LogCategory = "maintenance"
	LogCategoryCLIErrors   LogCategory = "cli_errors"
	LogCategorySuricata    LogCategory = "suricata"
	LogCategoryBotguard    LogCategory = "botguard"
	LogCategoryDebug       LogCategory = "debug"
)

// LogFileInfo holds metadata about a log file
type LogFileInfo struct {
	Category    LogCategory
	Path        string
	Description string
	Rotation    string // logrotate frequency: daily, weekly, monthly
	Retain      int    // number of rotated files to keep
}

// GetLogFile returns the path for a specific log category
func GetLogFile(category LogCategory) string {
	paths := GetPaths()
	if paths == nil {
		return ""
	}

	switch category {
	case LogCategoryMain:
		return paths.MainLog
	case LogCategoryAudit:
		return paths.AuditLog
	case LogCategoryBans:
		return paths.BansLog
	case LogCategoryPortscan:
		return paths.PortscanLog
	case LogCategoryDDoS:
		return paths.DDoSLog
	case LogCategoryLoginAlert:
		return paths.LoginAlertLog
	case LogCategoryFeeds:
		return paths.FeedsLog
	case LogCategoryGeoban:
		return paths.GeobanLog
	case LogCategoryCron:
		return paths.CronLog
	case LogCategoryMaintenance:
		return paths.MaintenanceLog
	case LogCategoryCLIErrors:
		return paths.CLIErrorsLog
	case LogCategorySuricata:
		return paths.SuricataMainLog
	case LogCategoryBotguard:
		return paths.BotguardLog
	case LogCategoryDebug:
		cfg := Get()
		if cfg != nil {
			return cfg.DebugTraceLog
		}
		return ""
	default:
		return ""
	}
}

// AllLogFiles returns information about all nftban log files
func AllLogFiles() []LogFileInfo {
	paths := GetPaths()
	cfg := Get()
	if paths == nil || cfg == nil {
		return nil
	}

	return []LogFileInfo{
		{
			Category:    LogCategoryMain,
			Path:        paths.MainLog,
			Description: "Main nftban log - all operations",
			Rotation:    "daily",
			Retain:      14,
		},
		{
			Category:    LogCategoryAudit,
			Path:        paths.AuditLog,
			Description: "Audit log - security-relevant actions",
			Rotation:    "daily",
			Retain:      90,
		},
		{
			Category:    LogCategoryBans,
			Path:        paths.BansLog,
			Description: "Ban/unban operations log",
			Rotation:    "daily",
			Retain:      30,
		},
		{
			Category:    LogCategoryPortscan,
			Path:        paths.PortscanLog,
			Description: "Port scan detection log",
			Rotation:    "daily",
			Retain:      14,
		},
		{
			Category:    LogCategoryDDoS,
			Path:        paths.DDoSLog,
			Description: "DDoS detection and mitigation log",
			Rotation:    "daily",
			Retain:      14,
		},
		{
			Category:    LogCategoryLoginAlert,
			Path:        paths.LoginAlertLog,
			Description: "SSH/login attempt alerts",
			Rotation:    "daily",
			Retain:      30,
		},
		{
			Category:    LogCategoryFeeds,
			Path:        paths.FeedsLog,
			Description: "Threat intelligence feed updates",
			Rotation:    "weekly",
			Retain:      4,
		},
		{
			Category:    LogCategoryGeoban,
			Path:        paths.GeobanLog,
			Description: "Geographic blocking operations",
			Rotation:    "weekly",
			Retain:      4,
		},
		{
			Category:    LogCategoryCron,
			Path:        paths.CronLog,
			Description: "Scheduled task execution log",
			Rotation:    "weekly",
			Retain:      4,
		},
		{
			Category:    LogCategoryMaintenance,
			Path:        paths.MaintenanceLog,
			Description: "System maintenance operations",
			Rotation:    "weekly",
			Retain:      4,
		},
		{
			Category:    LogCategoryCLIErrors,
			Path:        paths.CLIErrorsLog,
			Description: "CLI command errors and exceptions",
			Rotation:    "daily",
			Retain:      7,
		},
		{
			Category:    LogCategoryBotguard,
			Path:        paths.BotguardLog,
			Description: "HTTP Bot Guard classification log",
			Rotation:    "daily",
			Retain:      14,
		},
		{
			Category:    LogCategoryBotguard,
			Path:        paths.BotguardDecisionsLog,
			Description: "HTTP Bot Guard decision audit log",
			Rotation:    "daily",
			Retain:      30,
		},
		{
			Category:    LogCategoryDebug,
			Path:        cfg.DebugTraceLog,
			Description: "Debug trace log (when enabled)",
			Rotation:    "daily",
			Retain:      3,
		},
	}
}

// SuricataLogFiles returns all Suricata-related log files
func SuricataLogFiles() []LogFileInfo {
	paths := GetPaths()
	if paths == nil {
		return nil
	}

	return []LogFileInfo{
		{
			Category:    LogCategorySuricata,
			Path:        paths.SuricataEveLog,
			Description: "Suricata EVE JSON log (alerts)",
			Rotation:    "daily",
			Retain:      7,
		},
		{
			Category:    LogCategorySuricata,
			Path:        paths.SuricataFastLog,
			Description: "Suricata fast.log (quick alerts)",
			Rotation:    "daily",
			Retain:      7,
		},
		{
			Category:    LogCategorySuricata,
			Path:        paths.SuricataStatsLog,
			Description: "Suricata statistics log",
			Rotation:    "daily",
			Retain:      7,
		},
		{
			Category:    LogCategorySuricata,
			Path:        paths.SuricataMainLog,
			Description: "Suricata main log",
			Rotation:    "daily",
			Retain:      7,
		},
	}
}

// LogDir returns the base log directory
// NO FALLBACK - path must come from /etc/nftban/nftban.conf
func LogDir() string {
	cfg := MustLoad()
	return cfg.LogDir
}

// SuricataLogDir returns the Suricata log directory
// NO FALLBACK - path must come from /etc/nftban/nftban.conf
func SuricataLogDir() string {
	cfg := MustLoad()
	if cfg.SuricataLogDir != "" {
		return cfg.SuricataLogDir
	}
	return filepath.Join(cfg.LogDir, "suricata")
}

// LogPathForDate returns a log file path with date suffix
// Useful for accessing rotated logs like nftban.log.2024-01-15
func LogPathForDate(category LogCategory, dateSuffix string) string {
	basePath := GetLogFile(category)
	if basePath == "" || dateSuffix == "" {
		return basePath
	}
	return basePath + "." + dateSuffix
}
