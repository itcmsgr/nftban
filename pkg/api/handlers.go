// =============================================================================
// NFTBan - Main API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="handlers"
// meta:type="go"
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
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/pkg/auth"
	"github.com/itcmsgr/nftban/pkg/metrics"
	"github.com/itcmsgr/nftban/pkg/middleware"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/state"
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

// getGrafanaURL returns the Grafana URL from central config
// NO FALLBACK - value must come from /etc/nftban/nftban.conf
func getGrafanaURL() string {
	cfg := nftbanconf.MustLoad()
	return cfg.GrafanaURL
}

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

// UIListBannedIPsHandler returns all banned IPs from nftables sets
func UIListBannedIPsHandler(w http.ResponseWriter, r *http.Request) {
	// Use nftban list command with JSON output (architectural compliance)
	output, err := execNFTBanCommand("list", "banned", "--json")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to get banned IPs"})
		return
	}

	// Parse JSON output from nftban list command
	var result map[string]interface{}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse banned IPs"})
		return
	}

	// Return the result as-is (already in correct format)
	respondJSON(w, http.StatusOK, result)
}

// UIWhitelistGetHandler returns IPs whitelisted for GUI access
func UIWhitelistGetHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execNFTBanCommand("ui", "list-ips")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to get UI whitelist"})
		return
	}

	whitelist := map[string]interface{}{
		"ips": parseUIWhitelistOutput(output),
	}

	respondJSON(w, http.StatusOK, whitelist)
}

// UIWhitelistAddHandler adds IP to GUI whitelist
func UIWhitelistAddHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		IP string `json:"ip"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid request"})
		return
	}

	if req.IP == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "IP address is required"})
		return
	}

	_, err := execNFTBanCommand("ui", "add-ip", req.IP)
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: fmt.Sprintf("Failed to add to UI whitelist: %v", err)})
		return
	}

	// Audit log
	claims, _ := r.Context().Value(middleware.UserContextKey).(*auth.Claims)
	log.Printf("[AUDIT] User %s added IP to UI whitelist: %s", claims.Username, req.IP)

	respondJSON(w, http.StatusOK, SuccessResponse{
		Success: true,
		Message: fmt.Sprintf("IP %s added to UI whitelist", req.IP),
	})
}

// Removed: LogsHandler, LogsViewerHandler - moved to handlers_logs.go

// RulesHandler returns nftables statistics
func RulesHandler(w http.ResponseWriter, r *http.Request) {
	// TODO: Parse nftables sets properly - for now return empty array
	// The stats command output is plain text, not structured data
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"sets": []map[string]interface{}{},
	})
}

// GeoHandler returns geographic statistics (top countries)
func GeoHandler(w http.ResponseWriter, r *http.Request) {
	// Get top countries from stats
	output, err := execNFTBanCommand("stats", "top", "countries", "50")
	if err != nil {
		log.Printf("[ERROR] Failed to get geo stats: %v", err)
		// Return empty array instead of error
		respondJSON(w, http.StatusOK, []map[string]interface{}{})
		return
	}

	// Parse geo output (format: CC CountryName Count)
	geoStats := parseGeoOutput(output)
	respondJSON(w, http.StatusOK, geoStats)
}

// ReloadHandler reloads nftban firewall configuration
func ReloadHandler(w http.ResponseWriter, r *http.Request) {
	claims, _ := r.Context().Value(middleware.UserContextKey).(*auth.Claims)

	_, err := execNFTBanCommand("firewall", "reload")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: fmt.Sprintf("Failed to reload: %v", err)})
		return
	}

	log.Printf("[AUDIT] User %s reloaded nftban firewall", claims.Username)
	respondJSON(w, http.StatusOK, SuccessResponse{Success: true, Message: "Firewall reloaded successfully"})
}

// SyncFeedsHandler updates threat feeds
func SyncFeedsHandler(w http.ResponseWriter, r *http.Request) {
	claims, _ := r.Context().Value(middleware.UserContextKey).(*auth.Claims)

	_, err := execNFTBanCommand("feeds", "update")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: fmt.Sprintf("Failed to update feeds: %v", err)})
		return
	}

	// Refresh feeds stats in shared state after sync
	// This keeps BASIC tier consumers up-to-date without additional CLI calls
	go func() {
		output, err := execNFTBanCoreCommand("feeds", "list", "--json")
		if err != nil {
			return
		}
		var result struct {
			Data struct {
				Feeds []struct {
					Enabled bool `json:"enabled"`
					Count   int  `json:"count"`
				} `json:"feeds"`
			} `json:"data"`
		}
		if json.Unmarshal([]byte(output), &result) == nil {
			active := 0
			totalIPs := 0
			for _, f := range result.Data.Feeds {
				if f.Enabled {
					active++
					totalIPs += f.Count
				}
			}
			state.UpdateFeeds(active, int64(totalIPs))
		}
	}()

	log.Printf("[AUDIT] User %s updated feeds", claims.Username)
	respondJSON(w, http.StatusOK, SuccessResponse{Success: true, Message: "Feeds updated successfully"})
}

// FlushHandler clears nftban runtime table (temporary bans from Fail2ban)
func FlushHandler(w http.ResponseWriter, r *http.Request) {
	claims, _ := r.Context().Value(middleware.UserContextKey).(*auth.Claims)

	// Use nftban firewall flush command (architectural compliance)
	_, err := execNFTBanCommand("firewall", "flush")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: fmt.Sprintf("Failed to flush runtime bans: %v", err)})
		return
	}

	log.Printf("[AUDIT] User %s flushed runtime bans (temp_ban_v4 + temp_ban_v6)", claims.Username)
	respondJSON(w, http.StatusOK, SuccessResponse{Success: true, Message: "Runtime bans flushed successfully"})
}

// SearchHandler searches for an IP across all NFTBan components
func SearchHandler(w http.ResponseWriter, r *http.Request) {
	ip := r.URL.Query().Get("ip")
	if ip == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "IP parameter is required"})
		return
	}

	// Use nftban check command (returns text output)
	output, err := execNFTBanCommand("check", ip)

	// Parse the text output to build JSON response
	searchData := map[string]interface{}{
		"ip":          ip,
		"found":       false,
		"whitelisted": false,
		"blacklisted": false,
		"in_feeds":    false,
		"locations":   []string{},
	}

	if err == nil && output != "" {
		outputLower := strings.ToLower(output)

		// Check if whitelisted (matches "MATCHED: whitelist_ipv4" or "whitelist" in output)
		if strings.Contains(outputLower, "whitelist") || strings.Contains(outputLower, "✅ allowed") {
			searchData["whitelisted"] = true
			searchData["found"] = true
			searchData["locations"] = append(searchData["locations"].([]string), "whitelist")
		}

		// Check if blacklisted (matches "MATCHED: blacklist_ipv4" or "blacklist" in output)
		if strings.Contains(outputLower, "blacklist") || strings.Contains(outputLower, "❌ blocked") {
			searchData["blacklisted"] = true
			searchData["found"] = true
			searchData["locations"] = append(searchData["locations"].([]string), "blacklist")
		}

		// Check if in feeds
		if strings.Contains(outputLower, "found in feeds") || strings.Contains(outputLower, "⚠️  potentially blocked") {
			searchData["in_feeds"] = true
			searchData["found"] = true
			searchData["locations"] = append(searchData["locations"].([]string), "threat_feeds")
		}
	}

	respondJSON(w, http.StatusOK, searchData)
}

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

//nolint:U1000 // Prepared for future API enhancement

func parseUIWhitelistOutput(output string) []string {
	return parseWhitelistOutput(output)
}

func parseGeoOutput(output string) []map[string]interface{} {
	var geoStats []map[string]interface{}
	lines := strings.Split(output, "\n")

	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Parse format: "US United States 1234"
		parts := strings.Fields(line)
		if len(parts) >= 3 {
			cc := parts[0]
			count := 0
			// Last field should be the count
			if c, err := fmt.Sscanf(parts[len(parts)-1], "%d", &count); err == nil && c == 1 {
				name := strings.Join(parts[1:len(parts)-1], " ")
				geoStats = append(geoStats, map[string]interface{}{
					"cc":      cc,
					"name":    name,
					"blocked": count,
				})
			}
		}
	}

	return geoStats
}

// Background stats collection
func updateStatsCache() {
	newStats := make(map[string]interface{})

	// Get status (fast)
	statusOutput, err := execNFTBanCommand("status", "--json")
	if err == nil {
		var statusData map[string]interface{}
		if err := json.Unmarshal([]byte(statusOutput), &statusData); err == nil {
			newStats["status"] = statusData
		}
	} else {
		log.Printf("[STATS] Failed to update cache: %v", err)
	}

	// Store in cache
	statsCacheMux.Lock()
	statsCache = newStats
	statsCacheMux.Unlock()
}

// Start background stats updater
func StartStatsUpdater() {
	log.Println("[STATS] Starting background stats updater (10s interval)")

	// Initial update
	updateStatsCache()

	// Background stats updater (every 10 seconds)
	go func() {
		ticker := time.NewTicker(10 * time.Second)
		defer ticker.Stop()

		for range ticker.C {
			// Only update if there are active users
			activeUsersMux.RLock()
			userCount := len(activeUsers)
			activeUsersMux.RUnlock()

			if userCount > 0 {
				updateStatsCache()
			}
		}
	}()

	// Cleanup inactive users (every 1 minute)
	go func() {
		ticker := time.NewTicker(1 * time.Minute)
		defer ticker.Stop()

		for range ticker.C {
			cleanInactiveUsers()
		}
	}()
}

// Removed: StatsTrafficHandler, StatsBansHandler, StatsCountriesHandler, StatsTrendHandler
// Moved to handlers_stats.go

// Removed: Fail2BanStatusHandler (v1.0 migration to Suricata)
// Removed: Fail2BanControlHandler (v1.0 migration to Suricata)

// Removed: Fail2BanJailsHandler (v1.0 migration to Suricata)

// PortscanControlHandler handles portscan enable/disable/status
func PortscanControlHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Action string `json:"action"` // enable, disable, status
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid request"})
		return
	}

	// Validate action
	allowedActions := map[string]bool{
		"enable":  true,
		"disable": true,
		"status":  true,
	}

	if !allowedActions[req.Action] {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid action"})
		return
	}

	// Execute nftban portscan command via bash CLI
	// The bash CLI handles portscan enable/disable/status
	var output string
	var err error
	output, err = execNFTBanCommand("portscan", req.Action)
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{
			Error: fmt.Sprintf("Failed to %s portscan: %v", req.Action, err),
		})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": fmt.Sprintf("Portscan %s successful", req.Action),
		"output":  output,
	})
}

// Removed: ConfigGetHandler, ConfigSetHandler, ConfigResetHandler - moved to handlers_config.go

func markUserActive(username string) {
	activeUsersMux.Lock()
	activeUsers[username] = time.Now()
	activeUsersMux.Unlock()
}

// Clean inactive users (not seen for 10 minutes)
func cleanInactiveUsers() {
	activeUsersMux.Lock()
	defer activeUsersMux.Unlock()

	sampler := metrics.GetSampler()
	threshold := time.Now().Add(-10 * time.Minute)
	for user, lastSeen := range activeUsers {
		if lastSeen.Before(threshold) {
			delete(activeUsers, user)
			sampler.RemoveSession()
			log.Printf("[SESSION] Removed inactive user: %s (last seen: %s)",
				user, lastSeen.Format(time.RFC3339))
		}
	}
}

// =============================================================================
// NEW API ENDPOINTS FOR IMPRESSIVE DASHBOARD v0.6
// =============================================================================

// Removed: PrometheusMetricsHandler, parsePrometheusMetrics - moved to handlers_metrics.go

// Removed: Fail2BanLogsHandler function (v1.0 migration to Suricata)
// Removed: PortScanLogsHandler - moved to handlers_logs.go

// GeoBanStatsHandler provides detailed GeoIP/GeoBan statistics
func GeoBanStatsHandler(w http.ResponseWriter, r *http.Request) {
	// Execute nftban geoban stats --json
	output, err := execNFTBanCommand("geoban", "stats", "--json")
	if err != nil {
		// Fallback: Get data from nftables and geoip lookups
		fallbackStats := getGeoBanStatsFallback()
		respondJSON(w, http.StatusOK, fallbackStats)
		return
	}

	// Parse JSON output
	var result map[string]interface{}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse geoban stats"})
		return
	}

	respondJSON(w, http.StatusOK, result)
}

// getGeoBanStatsFallback provides fallback GeoIP statistics
func getGeoBanStatsFallback() map[string]interface{} {
	// Use nftban geoban list command instead of direct nft (architectural compliance)
	output, err := execNFTBanCommand("geoban", "list")
	if err != nil {
		return map[string]interface{}{
			"error":         "Failed to fetch geoban data",
			"total_blocked": 0,
			"by_country":    map[string]int{},
		}
	}

	// Parse CLI output to extract country stats
	// Format: CC CountryName (blocked)
	countryMap := make(map[string]int)
	lines := strings.Split(output, "\n")
	totalBlocked := 0

	for _, line := range lines {
		line = strings.TrimSpace(line)
		if strings.Contains(line, "blocked") || strings.Contains(line, "BLOCKED") {
			totalBlocked++
			// Extract country code (first 2 chars if line starts with uppercase letters)
			if len(line) >= 2 {
				cc := line[0:2]
				if cc[0] >= 'A' && cc[0] <= 'Z' && cc[1] >= 'A' && cc[1] <= 'Z' {
					countryMap[cc]++
				}
			}
		}
	}

	return map[string]interface{}{
		"total_blocked": totalBlocked,
		"by_country":    countryMap,
		"last_updated":  time.Now().Unix(),
	}
}

// GrafanaStatusHandler checks if Grafana is available
func GrafanaStatusHandler(w http.ResponseWriter, r *http.Request) {
	// Get service name from central config
	services := nftbanconf.GetServices()
	grafanaService := "grafana-server"
	if services != nil {
		grafanaService = services.Grafana
	}

	// Check if Grafana is running
	cmd := exec.Command("systemctl", "is-active", grafanaService)
	output, err := cmd.Output()

	isRunning := err == nil && strings.TrimSpace(string(output)) == "active"

	// Check if Grafana is accessible using URL from central config
	grafanaBaseURL := getGrafanaURL()
	grafanaHealthURL := grafanaBaseURL + "/api/health"
	accessible := false

	if isRunning {
		client := &http.Client{Timeout: 2 * time.Second}
		resp, err := client.Get(grafanaHealthURL)
		if err == nil {
			accessible = resp.StatusCode == 200
			resp.Body.Close()
		}
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"available":  isRunning && accessible,
		"running":    isRunning,
		"accessible": accessible,
		"url":        grafanaBaseURL,
		"dashboards": map[string]string{
			"overview":    "/d/nftban-overview",
			"health":      "/d/nftban-health",
			"geographic":  "/d/nftban-geographic",
			"performance": "/d/nftban-performance",
		},
	})
}

// Removed: SystemLogsHandler - moved to handlers_logs.go

// Removed: DashboardMetricsHandler - moved to handlers_metrics.go

// Removed: SystemHostnameHandler - moved to handlers_system.go



// Removed: AnalyticsSummaryHandler, AnalyticsCountriesHandler, AnalyticsTopCountriesHandler,
// AnalyticsIPHandler, RecentActivityHandler, RecentActivity struct - moved to handlers_analytics.go

// Removed: BasicStatsHandler - moved to handlers_stats.go
