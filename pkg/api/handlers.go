// =============================================================================
// NFTBan - Main API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="handlers"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Main HTTP API handlers for NFTBan web interface"
// meta:input="HTTP requests"
// meta:output="JSON responses"
// meta:depends="github.com/gorilla/mux,github.com/itcmsgr/nftban/pkg/auth"
// meta:inventory.files=""
// meta:inventory.binaries="nftban"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package api

import (
	"strings"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/pkg/nftbanconf"
)

// =============================================================================
// Central Config Accessors - NO FALLBACKS
// =============================================================================
// All paths come from /etc/nftban/nftban.conf via nftbanconf package.
// If config is not loaded, we fail fast rather than silently using wrong paths.
// This prevents GUI breakage from path mismatches.
// =============================================================================

// getNFTBanCLI returns the path to nftban CLI from central config
func getNFTBanCLI() string {
	cfg := nftbanconf.MustLoad()
	return cfg.Bin
}

// getLogDir returns the log directory from central config
func getLogDir() string {
	cfg := nftbanconf.MustLoad()
	return cfg.LogDir
}

// getConfigDir returns the config directory from central config
func getConfigDir() string {
	cfg := nftbanconf.MustLoad()
	return cfg.ConfigDir
}

// getCoreBin returns the nftban-core binary path from central config
func getCoreBin() string {
	cfg := nftbanconf.MustLoad()
	return cfg.CoreBin
}

// getLogFiles returns log file paths map using central config
// NO FALLBACK - paths must come from /etc/nftban/nftban.conf
func getLogFiles() map[string]string {
	logDir := getLogDir()
	paths := nftbanconf.MustLoadPaths()

	// Build paths dynamically from central config
	logFiles := map[string]string{
		// NFTBan Core
		"nftban":               logDir + "/nftban.log",
		"nftban-actions":       logDir + "/nftban-actions.log",
		"firewall":             logDir + "/nftban.log", // Alias for GUI
		// Protection Modules
		"portscan":             logDir + "/portscan.log",
		"ddos":                 logDir + "/ddos.log",
		"login-alert":          logDir + "/login_alert.log",
		"login_alert":          logDir + "/login_alert.log", // Legacy compatibility
		"feeds":                logDir + "/feeds.log",
		"geoban":               logDir + "/geoban.log",
		// Suricata IDS (v1.0) - paths from central config
		"suricata-eve":         getSuricataLogPath("eve-alerts.json"),
		"suricata-fast":        getSuricataLogPath("fast.log"),
		"suricata-stats":       getSuricataLogPath("stats.log"),
		"suricata-log":         getSuricataLogPath("suricata.log"),
		// System
		"cron":                 logDir + "/cron.log",
		"maintenance":          logDir + "/maintenance.log",
		"cli-errors":           logDir + "/cli-errors.log",
		"persistent-offenders": logDir + "/persistent-offenders.log",
	}

	// Override with specific paths from config if set
	if paths.MainLog != "" {
		logFiles["nftban"] = paths.MainLog
		logFiles["firewall"] = paths.MainLog
	}
	if paths.AuditLog != "" {
		logFiles["nftban-actions"] = paths.AuditLog
	}

	return logFiles
}

// getFeedsDir returns the feeds directory from central config
// NO FALLBACK - path must come from /etc/nftban/nftban.conf
func getFeedsDir() string {
	paths := nftbanconf.MustLoadPaths()
	return paths.FeedsDir
}

// getSuricataLogPath returns a Suricata log file path from central config
// NO FALLBACK - path must come from /etc/nftban/nftban.conf
func getSuricataLogPath(filename string) string {
	cfg := nftbanconf.MustLoad()
	return cfg.SuricataLogDir + "/" + filename
}

// Removed: getGrafanaURL - unused (U1000)

// getPrometheusFile returns the Prometheus metrics file path from central config
// NO FALLBACK - path must come from /etc/nftban/nftban.conf
func getPrometheusFile() string {
	paths := nftbanconf.MustLoadPaths()
	return paths.PrometheusFile
}

// Stats cache for background updates
var (
	statsCache     map[string]interface{}
	statsCacheMux  sync.RWMutex
	activeUsers    = make(map[string]time.Time) // Track active sessions
	activeUsersMux sync.RWMutex
)

// Response structures
type ErrorResponse struct {
	Error string `json:"error"`
}

type SuccessResponse struct {
	Success bool   `json:"success"`
	Message string `json:"message"`
}

// Removed: DashboardHandler, StatusHandler, HealthHandler, HealthFixHandler - moved to handlers_dashboard.go

// Removed: PortsHandler, PortBanHandler, PortUnbanHandler, PortStatusHandler - moved to handlers_ports.go

// Removed: UIListBannedIPsHandler, UIWhitelistGetHandler, UIWhitelistAddHandler - moved to handlers_ui.go

// Removed: LogsHandler, LogsViewerHandler - moved to handlers_logs.go

// Removed: RulesHandler - moved to handlers_actions.go

// Removed: GeoHandler - moved to handlers_geo.go

// Removed: ReloadHandler - moved to handlers_actions.go

// Removed: SyncFeedsHandler - moved to handlers_actions.go

// Removed: FlushHandler - moved to handlers_actions.go

// Removed: SearchHandler - moved to handlers_actions.go

// Removed: MetricsEnableHandler, MetricsStatusHandler, MetricsSnapshotHandler - moved to handlers_metrics.go

// Removed: FirewallValidateHandler, FirewallCheckRequest, FirewallCheckHandler, FirewallStatsHandler - moved to handlers_firewall.go

// Removed: LogFileHandler - moved to handlers_logs.go
// Removed: ConfigFileHandler - moved to handlers_config.go

// Removed: SystemServicesHandler, SystemModulesHandler, SystemTimersHandler, SystemServiceControlHandler
// Moved to handlers_system.go

// Helper functions

func parseWhitelistOutput(output string) []string {
	lines := strings.Split(output, "\n")
	var ips []string
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line != "" && !strings.HasPrefix(line, "#") {
			ips = append(ips, line)
		}
	}
	return ips
}

// Removed: parseUIWhitelistOutput - moved to handlers_ui.go

// Removed: parseGeoOutput - moved to handlers_geo.go

// Removed: updateStatsCache - unused (U1000), but statsCache/statsCacheMux kept for handlers_metrics.go

// Removed: StatsTrafficHandler, StatsBansHandler, StatsCountriesHandler, StatsTrendHandler
// Moved to handlers_stats.go

// Removed: Fail2BanStatusHandler (v1.0 migration to Suricata)
// Removed: Fail2BanControlHandler (v1.0 migration to Suricata)

// Removed: Fail2BanJailsHandler (v1.0 migration to Suricata)

// Removed: PortscanControlHandler - moved to handlers_actions.go

// Removed: ConfigGetHandler, ConfigSetHandler, ConfigResetHandler - moved to handlers_config.go

func markUserActive(username string) {
	activeUsersMux.Lock()
	activeUsers[username] = time.Now()
	activeUsersMux.Unlock()
}

// Removed: cleanInactiveUsers - unused (U1000), activeUsers tracking kept for markUserActive

// =============================================================================
// NEW API ENDPOINTS FOR IMPRESSIVE DASHBOARD v0.6
// =============================================================================

// Removed: PrometheusMetricsHandler, parsePrometheusMetrics - moved to handlers_metrics.go

// Removed: Fail2BanLogsHandler function (v1.0 migration to Suricata)
// Removed: PortScanLogsHandler - moved to handlers_logs.go

// Removed: GeoBanStatsHandler, getGeoBanStatsFallback, GrafanaStatusHandler - moved to handlers_geo.go

// Removed: SystemLogsHandler - moved to handlers_logs.go

// Removed: DashboardMetricsHandler - moved to handlers_metrics.go

// Removed: SystemHostnameHandler - moved to handlers_system.go



// Removed: AnalyticsSummaryHandler, AnalyticsCountriesHandler, AnalyticsTopCountriesHandler,
// AnalyticsIPHandler, RecentActivityHandler, RecentActivity struct - moved to handlers_analytics.go

// Removed: BasicStatsHandler - moved to handlers_stats.go
