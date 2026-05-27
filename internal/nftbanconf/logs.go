// =============================================================================
// NFTBan - Log Files Registry
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="logs"
// meta:type="package"
// meta:version="1.1.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Canonical nftban log inventory + path helpers. Inventory authority for log rotation policy (bridged to the packaged logrotate templates by a Go drift-test)."
// meta:input="None"
// meta:output="Log file paths, inventory, and coarse rotation policy"
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

// LogTemplate names a packaged logrotate template that executes rotation policy.
type LogTemplate string

const (
	// TemplateMain is install/config/nftban.logrotate (always installed).
	TemplateMain LogTemplate = "nftban.logrotate"
	// TemplateSuricata is install/config/nftban-suricata.logrotate, installed
	// only when Suricata is provisioned (it requires the suricata user).
	TemplateSuricata LogTemplate = "nftban-suricata.logrotate"
)

// LogPolicy is one entry in the canonical nftban log inventory: a log file that
// nftban owns and that requires rotation, plus its coarse policy.
type LogPolicy struct {
	Name     string      // path relative to LogDir(), e.g. "ddos-classic.log" or "suricata/fast.log"
	Category LogCategory // logical category
	Rotation string      // expected logrotate frequency: daily | weekly | monthly
	Retain   int         // expected logrotate "rotate N"
	Template LogTemplate // packaged template that must cover it
}

// LogFileInfo holds runtime metadata about a log file (absolute path + policy).
type LogFileInfo struct {
	Category    LogCategory
	Path        string
	Description string
	Rotation    string // logrotate frequency: daily, weekly, monthly
	Retain      int    // number of rotated files to keep
}

// LogInventory is the canonical, machine-readable inventory of nftban-owned log
// files that require rotation, and their coarse policy (frequency + retain).
//
// AUTHORITY MODEL (v1.137, B-12 — "inventory authority + drift-test"):
//   - This inventory is the AUTHORITY for *which* logs exist and their coarse
//     rotation policy (frequency + retain).
//   - The packaged logrotate templates (install/config/nftban.logrotate +
//     install/config/nftban-suricata.logrotate) are the EXECUTION policy and the
//     authority for the directives this inventory deliberately does not model:
//     copytruncate, size caps, su, olddir, create mode/owner, postrotate.
//     The templates are NOT generated from this inventory — they cannot be,
//     because those directives are not representable here.
//   - The Go drift-test (logs_logrotate_drift_test.go) is the mandatory bridge:
//     it asserts every entry below is covered by its template with matching
//     frequency/retain, and fails on stale legacy names or missing coverage.
//   - Runtime rotation is executed by the system logrotate. There is no daemon
//     rotator and no maintenance-script logrotate trigger.
//
// Reconciled to current real filenames (v1.137): the pre-v1.137 registry carried
// the pre-split / pre-rename legacy names ddos.log, portscan.log, cli_errors.log;
// the current files are the classic/suricata split (ddos-classic/ddos-suricata,
// portscan-classic/portscan-suricata) and the hyphenated cli-errors.log. This
// function is config-independent on purpose, so the bridge can validate it
// without loading host config.
func LogInventory() []LogPolicy {
	return []LogPolicy{
		{Name: "nftban.log", Category: LogCategoryMain, Rotation: "weekly", Retain: 4, Template: TemplateMain},
		{Name: "nftban-actions.log", Category: LogCategoryAudit, Rotation: "daily", Retain: 90, Template: TemplateMain},
		{Name: "audit.log", Category: LogCategoryAudit, Rotation: "daily", Retain: 90, Template: TemplateMain},
		{Name: "bans.log", Category: LogCategoryBans, Rotation: "weekly", Retain: 12, Template: TemplateMain},
		{Name: "portscan.log", Category: LogCategoryPortscan, Rotation: "daily", Retain: 30, Template: TemplateMain},
		{Name: "portscan-classic.log", Category: LogCategoryPortscan, Rotation: "daily", Retain: 30, Template: TemplateMain},
		{Name: "portscan-suricata.log", Category: LogCategoryPortscan, Rotation: "daily", Retain: 30, Template: TemplateMain},
		{Name: "ddos.log", Category: LogCategoryDDoS, Rotation: "daily", Retain: 30, Template: TemplateMain},
		{Name: "ddos-classic.log", Category: LogCategoryDDoS, Rotation: "daily", Retain: 30, Template: TemplateMain},
		{Name: "ddos-suricata.log", Category: LogCategoryDDoS, Rotation: "daily", Retain: 30, Template: TemplateMain},
		{Name: "login_alert.log", Category: LogCategoryLoginAlert, Rotation: "weekly", Retain: 12, Template: TemplateMain},
		{Name: "feeds.log", Category: LogCategoryFeeds, Rotation: "weekly", Retain: 12, Template: TemplateMain},
		{Name: "geoban.log", Category: LogCategoryGeoban, Rotation: "weekly", Retain: 12, Template: TemplateMain},
		{Name: "cron.log", Category: LogCategoryCron, Rotation: "weekly", Retain: 12, Template: TemplateMain},
		{Name: "maintenance.log", Category: LogCategoryMaintenance, Rotation: "weekly", Retain: 4, Template: TemplateMain},
		{Name: "cli-errors.log", Category: LogCategoryCLIErrors, Rotation: "weekly", Retain: 12, Template: TemplateMain},
		{Name: "debug_trace.log", Category: LogCategoryDebug, Rotation: "weekly", Retain: 12, Template: TemplateMain},
		{Name: "botguard/botguard.log", Category: LogCategoryBotguard, Rotation: "daily", Retain: 30, Template: TemplateMain},
		{Name: "botguard/decisions.log", Category: LogCategoryBotguard, Rotation: "daily", Retain: 30, Template: TemplateMain},
		{Name: "installer.log", Category: LogCategoryMaintenance, Rotation: "weekly", Retain: 8, Template: TemplateMain},
		{Name: "update.log", Category: LogCategoryMaintenance, Rotation: "weekly", Retain: 8, Template: TemplateMain},
		{Name: "suricata-events.log", Category: LogCategorySuricata, Rotation: "daily", Retain: 30, Template: TemplateMain},
		{Name: "suricata/eve-alerts.json", Category: LogCategorySuricata, Rotation: "daily", Retain: 7, Template: TemplateSuricata},
		{Name: "suricata/fast.log", Category: LogCategorySuricata, Rotation: "weekly", Retain: 4, Template: TemplateSuricata},
		{Name: "suricata/stats.log", Category: LogCategorySuricata, Rotation: "weekly", Retain: 4, Template: TemplateSuricata},
	}
}

// GetLogFile returns the absolute path for the primary log of a category.
// Paths are resolved against the runtime log directory.
func GetLogFile(category LogCategory) string {
	for _, p := range LogInventory() {
		if p.Category == category {
			return filepath.Join(LogDir(), p.Name)
		}
	}
	if category == LogCategoryDebug {
		if cfg := Get(); cfg != nil {
			return cfg.DebugTraceLog
		}
	}
	return ""
}

// AllLogFiles returns runtime info for every nftban log covered by the main
// (always-installed) logrotate template. Derived from LogInventory().
func AllLogFiles() []LogFileInfo {
	dir := LogDir()
	out := make([]LogFileInfo, 0, len(LogInventory()))
	for _, p := range LogInventory() {
		if p.Template == TemplateSuricata {
			continue
		}
		out = append(out, LogFileInfo{
			Category: p.Category,
			Path:     filepath.Join(dir, p.Name),
			Rotation: p.Rotation,
			Retain:   p.Retain,
		})
	}
	return out
}

// SuricataLogFiles returns runtime info for Suricata-native logs (covered by the
// Suricata logrotate template, installed only when Suricata is provisioned).
func SuricataLogFiles() []LogFileInfo {
	dir := LogDir()
	var out []LogFileInfo
	for _, p := range LogInventory() {
		if p.Template != TemplateSuricata {
			continue
		}
		out = append(out, LogFileInfo{
			Category: p.Category,
			Path:     filepath.Join(dir, p.Name),
			Rotation: p.Rotation,
			Retain:   p.Retain,
		})
	}
	return out
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
