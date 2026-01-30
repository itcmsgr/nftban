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
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/mux"
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

// DashboardHandler returns dashboard statistics
// Uses shared state for BASIC metrics (NO CLI), falls back to CLI for full status
func DashboardHandler(w http.ResponseWriter, r *http.Request) {
	// Get authenticated user from context
	claims, ok := r.Context().Value(middleware.UserContextKey).(*auth.Claims)
	if !ok {
		respondJSON(w, http.StatusUnauthorized, ErrorResponse{Error: "Unauthorized"})
		return
	}

	// Try shared state first for BASIC metrics (NO CLI overhead)
	var statusData map[string]interface{}
	if state.IsInitialized() && !state.IsStale(30*time.Second) {
		snap := state.Get()
		// Build status from shared state - instant, no CLI
		statusData = map[string]interface{}{
			"firewall": map[string]interface{}{
				"banned_ips":    snap.BannedIPv4 + snap.BannedIPv6,
				"banned_ipv4":   snap.BannedIPv4,
				"banned_ipv6":   snap.BannedIPv6,
				"whitelist_ips": snap.WhitelistIPv4 + snap.WhitelistIPv6,
				"rule_count":    snap.RulesTotal,
			},
			"feeds": map[string]interface{}{
				"active":    snap.FeedsActive,
				"total_ips": snap.FeedsIPs,
			},
			"source": "shared_state",
		}
	} else {
		// Fallback to CLI for full status
		output, err := execNFTBanCommand("status", "--json")
		if err != nil {
			log.Printf("[ERROR] Failed to get dashboard data: %v", err)
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to retrieve dashboard data"})
			return
		}

		// Parse JSON output from CLI
		if err := json.Unmarshal([]byte(output), &statusData); err != nil {
			log.Printf("[ERROR] Failed to parse dashboard JSON: %v (output: %s)", err, output)
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse dashboard data"})
			return
		}
		statusData["source"] = "cli"
	}

	// Build dashboard response with user info and status data
	dashboard := map[string]interface{}{
		"user":   claims.Username,
		"status": statusData,
	}

	respondJSON(w, http.StatusOK, dashboard)
}

// StatusHandler returns firewall status
func StatusHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execNFTBanCommand("status", "--json")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to get status"})
		return
	}

	// Strip any non-JSON output (comments, warnings, etc.) before parsing
	// Look for the first '{' and last '}' to extract only the JSON portion
	output = strings.TrimSpace(output)
	startIdx := strings.Index(output, "{")
	endIdx := strings.LastIndex(output, "}")

	if startIdx == -1 || endIdx == -1 || startIdx > endIdx {
		log.Printf("[ERROR] No valid JSON found in status output: %s", output)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Invalid status response format"})
		return
	}

	jsonOutput := output[startIdx : endIdx+1]

	// Parse JSON response from CLI
	var statusData map[string]interface{}
	if err := json.Unmarshal([]byte(jsonOutput), &statusData); err != nil {
		log.Printf("[ERROR] Failed to parse status JSON: %v - Output: %s", err, jsonOutput)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse status data"})
		return
	}

	respondJSON(w, http.StatusOK, statusData)
}

// HealthHandler returns system health check
func HealthHandler(w http.ResponseWriter, r *http.Request) {
	// Note: health command may return non-zero exit code for warnings, but still produces valid JSON
	cmd := exec.Command(getNFTBanCLI(), "health", "--json")
	output, err := cmd.CombinedOutput()
	outputStr := string(output)

	// Check if we got valid output (even if exit code is non-zero due to warnings)
	if outputStr == "" || (!strings.Contains(outputStr, "{") && err != nil) {
		log.Printf("[ERROR] Health check failed: %v (output: %s)", err, outputStr)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Health check failed"})
		return
	}

	// Parse JSON response from CLI
	var healthData map[string]interface{}
	if err := json.Unmarshal([]byte(outputStr), &healthData); err != nil {
		log.Printf("[ERROR] Failed to parse health JSON: %v (output: %s)", err, outputStr)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse health data"})
		return
	}

	respondJSON(w, http.StatusOK, healthData)
}

// HealthFixHandler runs automated fixes via CLI command
func HealthFixHandler(w http.ResponseWriter, r *http.Request) {
	log.Printf("[INFO] Running health fix via CLI")

	// Call existing CLI command: nftban health fix all - use central config
	cmd := exec.Command(getNFTBanCLI(), "health", "fix", "all")
	output, err := cmd.CombinedOutput()
	outputStr := string(output)

	// Health fix may return non-zero for warnings, check output
	if err != nil && !strings.Contains(outputStr, "Fix complete") {
		log.Printf("[ERROR] Health fix failed: %v (output: %s)", err, outputStr)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{
			Error: fmt.Sprintf("Health fix failed: %v", err),
		})
		return
	}

	log.Printf("[INFO] Health fix completed")

	// Return success with output
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": "Health fix completed successfully",
		"output":  outputStr,
	})
}

// PortsHandler returns open ports status via CLI command
func PortsHandler(w http.ResponseWriter, r *http.Request) {
	log.Printf("[INFO] Getting ports status via CLI")

	// Call CLI via pkexec for root privileges (polkit rule allows nftban user)
	// Port scanning requires root for ss -tunlp to show process info
	// Path comes from central config - polkit rule must match NFTBAN_BIN
	cmd := exec.Command("/usr/bin/pkexec", getNFTBanCLI(), "port", "status", "--json")
	output, err := cmd.CombinedOutput()
	outputStr := string(output)

	// Check if we got valid output
	if outputStr == "" || (!strings.Contains(outputStr, "{") && err != nil) {
		log.Printf("[ERROR] Port status failed: %v (output: %s)", err, outputStr)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Port status check failed"})
		return
	}

	// Parse JSON response from CLI
	var portsData map[string]interface{}
	if err := json.Unmarshal([]byte(outputStr), &portsData); err != nil {
		log.Printf("[ERROR] Failed to parse ports JSON: %v (output: %s)", err, outputStr)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse ports data"})
		return
	}

	respondJSON(w, http.StatusOK, portsData)
}

// PortBanHandler bans a port via CLI
// POST /api/v1/ports/ban
func PortBanHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Port     int    `json:"port"`
		Protocol string `json:"protocol"` // tcp, udp, both
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid request"})
		return
	}

	if req.Port < 1 || req.Port > 65535 {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid port number"})
		return
	}

	proto := req.Protocol
	if proto == "" {
		proto = "both"
	}

	// Call CLI: nftban port block <port>
	output, err := execNFTBanCommand("port", "block", fmt.Sprintf("%d", req.Port))
	if err != nil {
		log.Printf("[ERROR] Port ban failed: %v - %s", err, output)
		// Check if port is already blocked (not in whitelist)
		if strings.Contains(output, "not found in whitelist") {
			respondJSON(w, http.StatusOK, map[string]interface{}{
				"success": true,
				"message": fmt.Sprintf("Port %d is already blocked (not in whitelist)", req.Port),
			})
			return
		}
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to ban port: " + err.Error()})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": fmt.Sprintf("Port %d blocked successfully", req.Port),
	})
}

// PortUnbanHandler unbans a port via CLI
// POST /api/v1/ports/unban
func PortUnbanHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Port     int    `json:"port"`
		Protocol string `json:"protocol"` // tcp, udp, both
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid request"})
		return
	}

	if req.Port < 1 || req.Port > 65535 {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid port number"})
		return
	}

	proto := req.Protocol
	if proto == "" {
		proto = "both"
	}

	// Call CLI: nftban port unblock <port>
	output, err := execNFTBanCommand("port", "unblock", fmt.Sprintf("%d", req.Port))
	if err != nil {
		log.Printf("[ERROR] Port unban failed: %v - %s", err, output)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to unban port: " + err.Error()})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": fmt.Sprintf("Port %d unblocked successfully", req.Port),
	})
}

// PortStatusHandler checks status of a specific port
// GET /api/v1/ports/status?port=22&protocol=tcp
func PortStatusHandler(w http.ResponseWriter, r *http.Request) {
	port := r.URL.Query().Get("port")
	if port == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Port parameter required"})
		return
	}

	// Call CLI: nftban port status <port> --json
	output, err := execNFTBanCommand("port", "status", port, "--json")
	if err != nil {
		log.Printf("[ERROR] Port status failed: %v", err)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to get port status"})
		return
	}

	var result map[string]interface{}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data":    map[string]string{"status": "unknown", "output": output},
		})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data":    result,
	})
}


// FeedsHandler returns ALL threat feeds (enabled and disabled) from CLI
func FeedsHandler(w http.ResponseWriter, r *http.Request) {
	// Call CLI to get ALL feeds (enabled and disabled)
	output, err := execNFTBanCommand("feeds", "list")
	if err != nil {
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"feeds":     []interface{}{},
				"total":     0,
				"total_ips": 0,
			},
		})
		return
	}

	// Parse CLI output to extract all feeds
	var feeds []map[string]interface{}
	totalIPs := 0
	feedsDir := getFeedsDir() // Use central config

	lines := strings.Split(output, "\n")
	for _, line := range lines {
		// Look for feed lines: [✓] or [✗] FEED_NAME ...
		line = strings.TrimSpace(line)
		if !strings.Contains(line, "[✓]") && !strings.Contains(line, "[✗]") {
			continue
		}
		// Skip lines without actual feed content (enabled feeds show "enabled", disabled show "IPs (off)")
		if !strings.Contains(line, "enabled") && !strings.Contains(line, "IPs") {
			continue
		}

		enabled := strings.Contains(line, "[✓]")
		// Remove box drawing chars and checkbox
		line = strings.ReplaceAll(line, "│", "")
		line = strings.ReplaceAll(line, "[✓]", "")
		line = strings.ReplaceAll(line, "[✗]", "")
		line = strings.TrimSpace(line)

		// Parse: FEED_NAME enabled/disabled INTERVAL
		parts := strings.Fields(line)
		if len(parts) < 2 {
			continue
		}

		feedName := parts[0]
		feedID := strings.ToLower(feedName)
		interval := "DAILY"
		if len(parts) >= 3 {
			interval = parts[2]
		}

		// Count IPs if enabled (file exists)
		ipCount := 0
		lastUpdate := "-"
		if enabled {
			feedLower := strings.ToLower(feedID)  // Convert to lowercase
			filePath := filepath.Join(feedsDir, feedLower+".txt")
			ipCount = countLinesInFile(filePath)
			totalIPs += ipCount
			if info, err := os.Stat(filePath); err == nil {
				lastUpdate = info.ModTime().Format("2006-01-02 15:04")
			}
		}

		feeds = append(feeds, map[string]interface{}{
			"id":              feedID,
			"name":            feedName,
			"enabled":         enabled,
			"ip_count":        ipCount,
			"last_update":     lastUpdate,
			"update_interval": interval,
		})
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"feeds":     feeds,
			"total":     len(feeds),
			"total_ips": totalIPs,
		},
	})
}

// Helper function to count lines in a file
func countLinesInFile(filePath string) int {
	file, err := os.Open(filePath)
	if err != nil {
		return 0
	}
	defer file.Close()

	count := 0
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		// Skip empty lines and comments
		if line != "" && !strings.HasPrefix(line, "#") {
			count++
		}
	}
	return count
}

// FeedsControlHandler handles enable/disable feed operations
func FeedsControlHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Action string `json:"action"` // enable, disable
		Feed   string `json:"feed"`   // feed ID
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid request"})
		return
	}

	if req.Action != "enable" && req.Action != "disable" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid action"})
		return
	}

	if req.Feed == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Feed ID required"})
		return
	}

	// Call CLI: nftban feeds enable/disable <feed> (CLI expects uppercase)
	feedName := strings.ToUpper(req.Feed)
	output, err := execNFTBanCommand("feeds", req.Action, feedName)
	if err != nil {
		log.Printf("[ERROR] Feeds %s failed: %v - %s", req.Action, err, output)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to " + req.Action + " feed: " + err.Error()})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": "Feed " + req.Feed + " " + req.Action + "d successfully",
	})
}

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

// LogsHandler returns system logs
func LogsHandler(w http.ResponseWriter, r *http.Request) {
	// UPDATED v0.6.5: Now supports log viewer functionality
	// Accepts both 'type' (GUI) and 'log_type' (API standard) parameters

	logType := r.URL.Query().Get("type")
	if logType == "" {
		logType = r.URL.Query().Get("log_type")
	}

	// If type is specified, use LogsViewerHandler logic
	if logType != "" {
		// Delegate to LogsViewerHandler logic inline
		linesStr := r.URL.Query().Get("lines")
		searchFilter := r.URL.Query().Get("search")

		lines := 100
		if linesStr != "" {
			if n, err := strconv.Atoi(linesStr); err == nil && n > 0 && n <= 10000 {
				lines = n
			}
		}

		// Map log types to files - use central config
		logFiles := getLogFiles()

		logFile, ok := logFiles[logType]
		if !ok {
			respondJSON(w, http.StatusBadRequest, ErrorResponse{
				Error: "Invalid log type. Available: nftban, nftban-actions, portscan, ddos, login-alert, feeds, geoban, suricata-eve, suricata-fast, suricata-stats, suricata-log, cron, maintenance, cli-errors",
			})
			return
		}

		// Check if file exists
		if _, err := os.Stat(logFile); os.IsNotExist(err) {
			respondJSON(w, http.StatusOK, map[string]interface{}{
				"success":       true,
				"log_type":      logType,
				"lines":         []string{},
				"total_lines":   0,
				"visible_lines": 0,
				"message":       "Log file does not exist yet",
			})
			return
		}

		// Read with tail/grep
		var output string
		var err error

		if searchFilter != "" {
			output, err = execCommand("sh", "-c", fmt.Sprintf("tail -n %d %s | grep -i '%s'", lines, logFile, searchFilter))
		} else {
			output, err = execCommand("tail", "-n", strconv.Itoa(lines), logFile)
		}

		if err != nil && searchFilter != "" && output == "" {
			// No matches
			respondJSON(w, http.StatusOK, map[string]interface{}{
				"success":       true,
				"log_type":      logType,
				"lines":         []string{},
				"total_lines":   0,
				"visible_lines": 0,
			})
			return
		}

		if err != nil {
			log.Printf("[ERROR] Failed to read log file %s: %v", logFile, err)
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{
				Error: fmt.Sprintf("Failed to read log file: %v", err),
			})
			return
		}

		// Split into lines
		logLines := strings.Split(strings.TrimSpace(output), "\n")
		if len(logLines) == 1 && logLines[0] == "" {
			logLines = []string{}
		}

		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success":       true,
			"log_type":      logType,
			"lines":         logLines,
			"total_lines":   len(logLines),
			"visible_lines": len(logLines),
		})
		return
	}

	// Legacy: No type specified, return journalctl logs
	tailStr := r.URL.Query().Get("tail")
	tail := "200"
	if tailStr != "" {
		tail = tailStr
	}

	output, err := execCommand("journalctl", "-u", "nftban", "-n", tail, "--no-pager")
	if err != nil {
		log.Printf("[ERROR] Failed to get logs: %v", err)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to retrieve logs"})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"logs": output,
	})
}

// LogsViewerHandler returns logs from specific NFTBan log files
// Supports multiple log types with search filtering and tail mode
func LogsViewerHandler(w http.ResponseWriter, r *http.Request) {
	// Get parameters
	logType := r.URL.Query().Get("log_type")
	linesStr := r.URL.Query().Get("lines")
	searchFilter := r.URL.Query().Get("search")
	tailMode := r.URL.Query().Get("tail") == "true"

	// Default values
	lines := 100
	if linesStr != "" {
		if n, err := strconv.Atoi(linesStr); err == nil && n > 0 && n <= 10000 {
			lines = n
		}
	}

	// Map log types to actual log files - use central config
	logFiles := getLogFiles()

	// Validate log type
	logFile, ok := logFiles[logType]
	if !ok || logType == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{
			Error: "Invalid log type. Available: nftban, nftban-actions, portscan, ddos, login-alert, feeds, geoban, suricata-eve, suricata-fast, suricata-stats, suricata-log, cron, maintenance, cli-errors",
		})
		return
	}

	// Check if log file exists
	if _, err := os.Stat(logFile); os.IsNotExist(err) {
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success":       true,
			"log_type":      logType,
			"lines":         []string{},
			"total_lines":   0,
			"visible_lines": 0,
			"message":       "Log file does not exist yet",
		})
		return
	}

	// Read log file with tail
	var output string
	var err error

	if searchFilter != "" {
		// Use grep for filtering
		output, err = execCommand("sh", "-c", fmt.Sprintf("tail -n %d %s | grep -i '%s'", lines, logFile, searchFilter))
	} else {
		// Just tail
		output, err = execCommand("tail", "-n", strconv.Itoa(lines), logFile)
	}

	if err != nil {
		// If grep returns no matches, it's not an error
		if searchFilter != "" && output == "" {
			respondJSON(w, http.StatusOK, map[string]interface{}{
				"success":       true,
				"log_type":      logType,
				"lines":         []string{},
				"total_lines":   0,
				"visible_lines": 0,
				"message":       "No matching lines found",
			})
			return
		}

		log.Printf("[ERROR] Failed to read log file %s: %v", logFile, err)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{
			Error: fmt.Sprintf("Failed to read log file: %v", err),
		})
		return
	}

	// Split into lines
	logLines := strings.Split(strings.TrimSpace(output), "\n")
	if len(logLines) == 1 && logLines[0] == "" {
		logLines = []string{}
	}

	// Response
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success":       true,
		"log_type":      logType,
		"lines":         logLines,
		"total_lines":   len(logLines),
		"visible_lines": len(logLines),
		"tail_mode":     tailMode,
		"search_filter": searchFilter,
	})
}

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

// MetricsEnableHandler enables continuous metrics sampling (overrides session-based logic)
func MetricsEnableHandler(w http.ResponseWriter, r *http.Request) {
	type EnableRequest struct {
		Enable bool `json:"enable"`
	}

	var req EnableRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid request"})
		return
	}

	sampler := metrics.GetSampler()
	if req.Enable {
		sampler.EnableMetrics()
		log.Println("[METRICS] Continuous metrics mode enabled via API")
	} else {
		sampler.DisableMetrics()
		log.Println("[METRICS] Continuous metrics mode disabled via API")
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success":         true,
		"metrics_enabled": sampler.IsMetricsEnabled(),
		"status":          sampler.GetStatus(),
	})
}

// MetricsStatusHandler returns current metrics sampler status
func MetricsStatusHandler(w http.ResponseWriter, r *http.Request) {
	sampler := metrics.GetSampler()
	status := sampler.GetStatus()
	status["metrics_enabled"] = sampler.IsMetricsEnabled()

	respondJSON(w, http.StatusOK, status)
}

// MetricsSnapshotHandler returns recent samples
func MetricsSnapshotHandler(w http.ResponseWriter, r *http.Request) {
	// Get count parameter (default 10, max 100)
	countStr := r.URL.Query().Get("count")
	count := 10
	if countStr != "" {
		if n, err := fmt.Sscanf(countStr, "%d", &count); err == nil && n == 1 {
			if count > 100 {
				count = 100
			}
		}
	}

	sampler := metrics.GetSampler()
	samples := sampler.GetRecentSamples(count)

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"count":   len(samples),
		"samples": samples,
	})
}

// FirewallValidateHandler validates nftables structure against NFTBan spec
func FirewallValidateHandler(w http.ResponseWriter, r *http.Request) {
	// Execute nftban firewall validate --json
	output, err := execNFTBanCommand("firewall", "validate", "--json")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: err.Error()})
		return
	}

	// Parse JSON output
	var result map[string]interface{}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse validation result"})
		return
	}

	respondJSON(w, http.StatusOK, result)
}

// FirewallCheckRequest represents the request body for firewall check
type FirewallCheckRequest struct {
	Value string `json:"value"` // IP or port to check
}

// FirewallCheckHandler checks if IP or port is blocked/allowed
func FirewallCheckHandler(w http.ResponseWriter, r *http.Request) {
	var req FirewallCheckRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid request"})
		return
	}

	if req.Value == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Value is required"})
		return
	}

	// Execute nftban firewall check <value> --json
	output, err := execNFTBanCommand("firewall", "check", req.Value, "--json")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: err.Error()})
		return
	}

	// Parse JSON output
	var result map[string]interface{}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse check result"})
		return
	}

	respondJSON(w, http.StatusOK, result)
}

// FirewallStatsHandler returns firewall statistics
func FirewallStatsHandler(w http.ResponseWriter, r *http.Request) {
	// Execute nftban firewall stats --json
	output, err := execNFTBanCommand("firewall", "stats", "--json")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: err.Error()})
		return
	}

	// Parse JSON output
	var result map[string]interface{}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse stats result"})
		return
	}

	respondJSON(w, http.StatusOK, result)
}

// LogFileHandler serves individual log files from /var/log/nftban/
func LogFileHandler(w http.ResponseWriter, r *http.Request) {
	// Get log file path from query parameter: /api/v1/logs?path=/var/log/nftban/portscan.log
	logPath := r.URL.Query().Get("path")
	if logPath == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Missing 'path' parameter"})
		return
	}

	// Security: Validate log path (must be under configured log dir)
	baseDir := getLogDir() + "/"
	if !strings.HasPrefix(logPath, baseDir) {
		respondJSON(w, http.StatusForbidden, ErrorResponse{Error: fmt.Sprintf("Log file must be under %s", baseDir)})
		return
	}

	// Security: Prevent directory traversal
	if strings.Contains(logPath, "..") {
		respondJSON(w, http.StatusForbidden, ErrorResponse{Error: "Invalid log path"})
		return
	}

	// Security: Only allow .log files (not .conf, .sh, etc.)
	if !strings.HasSuffix(logPath, ".log") {
		respondJSON(w, http.StatusForbidden, ErrorResponse{Error: "Only .log files are allowed"})
		return
	}

	// Check if file exists
	fileInfo, err := os.Stat(logPath)
	if err != nil {
		if os.IsNotExist(err) {
			respondJSON(w, http.StatusNotFound, ErrorResponse{Error: "Log file not found"})
		} else {
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to access log file"})
		}
		return
	}

	// If today's log is empty, try yesterday's compressed log
	if fileInfo.Size() == 0 {
		gzLogPath := logPath + ".1.gz"
		if gzInfo, err := os.Stat(gzLogPath); err == nil {
			// Yesterday's log exists, decompress and read it
			output, err := execCommand("zcat", gzLogPath)
			if err == nil {
				// Get last N lines from decompressed content
				linesParam := r.URL.Query().Get("lines")

				// Split into lines and get last N
				allLines := strings.Split(strings.TrimSpace(output), "\n")
				if linesParam == "all" || len(allLines) <= 100 {
					content := strings.Join(allLines, "\n")
					respondJSON(w, http.StatusOK, map[string]interface{}{
						"success": true,
						"data": map[string]interface{}{
							"content":  content,
							"size":     gzInfo.Size(),
							"modified": gzInfo.ModTime().Unix(),
							"lines":    len(allLines),
							"note":     "Today's log is empty, showing yesterday's log",
						},
					})
					return
				} else {
					// Get last N lines
					lineCount := 100
					if linesParam != "" {
						if n, err := strconv.Atoi(linesParam); err == nil {
							lineCount = n
						}
					}
					start := len(allLines) - lineCount
					if start < 0 {
						start = 0
					}
					content := strings.Join(allLines[start:], "\n")
					respondJSON(w, http.StatusOK, map[string]interface{}{
						"success": true,
						"data": map[string]interface{}{
							"content":  content,
							"size":     gzInfo.Size(),
							"modified": gzInfo.ModTime().Unix(),
							"lines":    lineCount,
							"note":     "Today's log is empty, showing yesterday's log",
						},
					})
					return
				}
			}
		}
	}

	// Get number of lines to return (default: 100, max: all)
	linesParam := r.URL.Query().Get("lines")
	lines := "100"
	if linesParam != "" {
		lines = linesParam
	}

	// Read log file
	var content string
	if lines == "all" {
		// Read entire file
		data, err := os.ReadFile(logPath)
		if err != nil {
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to read log file"})
			return
		}
		content = string(data)
	} else {
		// Use tail to get last N lines
		output, err := execCommand("tail", "-n", lines, logPath)
		if err != nil {
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to read log file"})
			return
		}
		content = output
	}

	// Return log content in standard response format
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"content":  content,
			"size":     fileInfo.Size(),
			"modified": fileInfo.ModTime().Unix(),
			"lines":    strings.Count(content, "\n"),
		},
	})
}

// ConfigFileHandler serves configuration files from /etc/nftban/
func ConfigFileHandler(w http.ResponseWriter, r *http.Request) {
	// Extract config path from URL: /api/v1/config/{path}
	parts := strings.Split(r.URL.Path, "/")
	if len(parts) < 4 {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid config path"})
		return
	}

	// Join remaining parts to support paths like "conf.d/portscan.conf"
	configPath := strings.Join(parts[4:], "/")

	// Base directory for config files - use central config
	baseDir := getConfigDir()

	// Security: Validate config path (prevent directory traversal)
	if strings.Contains(configPath, "..") || strings.HasPrefix(configPath, "/") {
		respondJSON(w, http.StatusForbidden, ErrorResponse{Error: "Invalid config path"})
		return
	}

	// Allowed config files (whitelist)
	allowedFiles := map[string]bool{
		"nftban.conf":             true,
		"nftban.conf.local":       true,
		"conf.d/portscan.conf":    true,
		"conf.d/ddos.conf":        true,
		// Removed: conf.d/fail2ban.conf (v1.0 migration to Suricata)
		"conf.d/feeds.conf":       true,
		"conf.d/geoip.conf":       true,
		"conf.d/mail.conf":        true,
		"conf.d/log.conf":         true,
		"conf.d/services.conf":    true,
		"conf.d/banner.conf":      true,
		"conf.d/cloudflare.conf":  true,
		"conf.d/panels/directadmin/main.conf": true,
		"conf.d/health.conf":      true,
		"conf.d/login_alert.conf": true,
		"conf.d/geoip/main.conf":  true,
		"conf.d/geoban/main.conf": true,
		"conf.d/nftban-go.conf":   true, // Legacy (deprecated)
		"conf.d/recovery.conf":    true,
		"conf.d/stats.conf":       true,
	}

	if !allowedFiles[configPath] {
		respondJSON(w, http.StatusForbidden, ErrorResponse{Error: "Config file not allowed"})
		return
	}

	fullPath := baseDir + "/" + configPath

	// Handle GET request (read file)
	if r.Method == "GET" {
		// Check if file exists
		fileInfo, err := os.Stat(fullPath)
		if err != nil {
			if os.IsNotExist(err) {
				respondJSON(w, http.StatusNotFound, ErrorResponse{Error: "Config file not found"})
			} else {
				respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to access config file"})
			}
			return
		}

		// Read file content
		data, err := os.ReadFile(fullPath)
		if err != nil {
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to read config file"})
			return
		}

		// Return config content
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"content":  string(data),
			"size":     fileInfo.Size(),
			"modified": fileInfo.ModTime().Unix(),
			"path":     configPath,
		})
		return
	}

	// Handle POST request (save file)
	if r.Method == "POST" {
		// Only allow editing .local files
		if !strings.Contains(configPath, ".local") {
			respondJSON(w, http.StatusForbidden, ErrorResponse{Error: "Only .local files can be edited"})
			return
		}

		// Parse request body
		var req struct {
			Content string `json:"content"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid request body"})
			return
		}

		// Write file (create backup first if file exists)
		if _, err := os.Stat(fullPath); err == nil {
			// Create backup
			backupPath := fullPath + ".backup"
			if _, err := execCommand("cp", fullPath, backupPath); err != nil {
				log.Printf("[WARN] Failed to create backup: %v", err)
			}
		}

		// Write new content
		if err := os.WriteFile(fullPath, []byte(req.Content), 0640); err != nil {
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to write config file"})
			return
		}

		// Set proper ownership (nftban:nftban or root:nftban)
		if err := os.Chown(fullPath, 0, 988); err != nil {  // 988 = nftban group GID
			log.Printf("[WARN] Failed to set ownership: %v", err)
		}

		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"message": "Config file saved successfully",
			"path":    configPath,
		})
		return
	}

	respondJSON(w, http.StatusMethodNotAllowed, ErrorResponse{Error: "Method not allowed"})
}

// SystemServicesHandler returns system services status
func SystemServicesHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execNFTBanCommand("services")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to get services"})
		return
	}

	// Return raw output for now (can be enhanced with JSON parsing)
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"output": output,
	})
}

// SystemModulesHandler returns NFTBan modules inventory
func SystemModulesHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execNFTBanCommand("module")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to get modules"})
		return
	}

	// Return raw output for now (can be enhanced with JSON parsing)
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"output": output,
	})
}

// SystemTimersHandler returns systemd timers status
func SystemTimersHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execCommand("systemctl", "list-timers", "nftban*", "--no-pager")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to get timers"})
		return
	}

	// Return raw output for now (can be enhanced with JSON parsing)
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"output": output,
	})
}

// SystemServiceControlHandler handles service start/stop/restart
func SystemServiceControlHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Service string `json:"service"`
		Action  string `json:"action"`
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid request"})
		return
	}

	// Validate service name (only allow specific services)
	allowedServices := map[string]bool{
		// Removed: "fail2ban" (v1.0 migration to Suricata)
		"nftables": true,
	}

	if !allowedServices[req.Service] {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Service not allowed"})
		return
	}

	// Validate action
	allowedActions := map[string]bool{
		"start":   true,
		"stop":    true,
		"restart": true,
		"status":  true,
	}

	if !allowedActions[req.Action] {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid action"})
		return
	}

	// Execute systemctl command
	output, err := execCommand("systemctl", req.Action, req.Service)
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: fmt.Sprintf("Failed to %s %s: %v", req.Action, req.Service, err)})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": fmt.Sprintf("Service %s %sed successfully", req.Service, req.Action),
		"output":  output,
	})
}

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

// =============================================================================
// DASHBOARD STATISTICS ENDPOINTS
// =============================================================================

// StatsTrafficHandler returns real traffic statistics from Node Exporter
func StatsTrafficHandler(w http.ResponseWriter, r *http.Request) {
	// Get authenticated user
	claims, ok := r.Context().Value(middleware.UserContextKey).(*auth.Claims)
	if !ok {
		respondJSON(w, http.StatusUnauthorized, ErrorResponse{Error: "Unauthorized"})
		return
	}
	markUserActive(claims.Username)

	// Fetch real network statistics from Node Exporter
	bandwidthIn := uint64(0)
	bandwidthOut := uint64(0)
	packetsIn := uint64(0)
	packetsOut := uint64(0)

	// Try to get network stats from Node Exporter metrics
	cfg := nftbanconf.MustLoad()
	nodeExporterAddr := cfg.MetricsNodeExporterAddr
	if nodeExporterAddr == "" {
		nodeExporterAddr = "localhost:9100"
	}
	metricsOutput, err := execCommand("curl", "-s", "http://"+nodeExporterAddr+"/metrics")
	if err == nil {
		// Parse node_network metrics for eth0
		lines := strings.Split(metricsOutput, "\n")
		for _, line := range lines {
			if strings.HasPrefix(line, "node_network_receive_bytes_total{device=\"eth0\"}") {
				parts := strings.Fields(line)
				if len(parts) >= 2 {
					if val, err := strconv.ParseFloat(parts[1], 64); err == nil {
						bandwidthIn = uint64(val)
					}
				}
			} else if strings.HasPrefix(line, "node_network_transmit_bytes_total{device=\"eth0\"}") {
				parts := strings.Fields(line)
				if len(parts) >= 2 {
					if val, err := strconv.ParseFloat(parts[1], 64); err == nil {
						bandwidthOut = uint64(val)
					}
				}
			} else if strings.HasPrefix(line, "node_network_receive_packets_total{device=\"eth0\"}") {
				parts := strings.Fields(line)
				if len(parts) >= 2 {
					if val, err := strconv.ParseFloat(parts[1], 64); err == nil {
						packetsIn = uint64(val)
					}
				}
			} else if strings.HasPrefix(line, "node_network_transmit_packets_total{device=\"eth0\"}") {
				parts := strings.Fields(line)
				if len(parts) >= 2 {
					if val, err := strconv.ParseFloat(parts[1], 64); err == nil {
						packetsOut = uint64(val)
					}
				}
			}
		}
	} else {
		log.Printf("[WARN] Failed to fetch Node Exporter metrics: %v", err)
	}

	// Build response with real data
	response := map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"bandwidth_in":  bandwidthIn,
			"bandwidth_out": bandwidthOut,
			"packets_in":    packetsIn,
			"packets_out":   packetsOut,
			"connections":   0, // Connection tracking not yet implemented
		},
	}

	respondJSON(w, http.StatusOK, response)
}

// Removed: getFailTwoBanCount24h function (v1.0 migration to Suricata)

// StatsBansHandler returns ban statistics by module
func StatsBansHandler(w http.ResponseWriter, r *http.Request) {
	// Get authenticated user
	claims, ok := r.Context().Value(middleware.UserContextKey).(*auth.Claims)
	if !ok {
		respondJSON(w, http.StatusUnauthorized, ErrorResponse{Error: "Unauthorized"})
		return
	}
	markUserActive(claims.Username)

	// SINGLE SOURCE OF TRUTH: Use nftban stats --json with enhanced breakdown
	statsOutput, err := execNFTBanCommand("stats", "--json")
	if err != nil {
		log.Printf("[ERROR] Failed to get stats: %v", err)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to retrieve ban statistics"})
		return
	}

	// Strip comment lines (# NFTBAN_CMD_EXIT: ...) that bash wrapper adds
	// These lines break JSON parsing, so we remove all lines starting with #
	lines := strings.Split(statsOutput, "\n")
	var jsonLines []string
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if !strings.HasPrefix(trimmed, "#") && trimmed != "" {
			jsonLines = append(jsonLines, line)
		}
	}
	cleanJSON := strings.Join(jsonLines, "\n")

	// Parse JSON response
	var statsData map[string]interface{}
	if err := json.Unmarshal([]byte(cleanJSON), &statsData); err != nil {
		log.Printf("[ERROR] Failed to parse stats JSON: %v", err)
		log.Printf("[DEBUG] Raw output: %s", statsOutput)
		log.Printf("[DEBUG] Cleaned JSON: %s", cleanJSON)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse statistics"})
		return
	}

	// Extract data from enhanced breakdown (v0.6.2: added geoban support)
	tempBans := 0
	blacklistBans := 0
	feedBans := 0
	geobanBans := 0
	whitelistCount := 0

	if data, ok := statsData["data"].(map[string]interface{}); ok {
		// Get breakdown (IPv4 + IPv6 counts)
		if breakdown, ok := data["breakdown"].(map[string]interface{}); ok {
			if temporary, ok := breakdown["temporary"].(map[string]interface{}); ok {
				if total, ok := temporary["total"].(float64); ok {
					tempBans = int(total)
				}
			}
			if blacklist, ok := breakdown["blacklist"].(map[string]interface{}); ok {
				if total, ok := blacklist["total"].(float64); ok {
					blacklistBans = int(total)
				}
			}
			if feeds, ok := breakdown["feeds"].(map[string]interface{}); ok {
				if total, ok := feeds["total"].(float64); ok {
					feedBans = int(total)
				}
			}
			if geoban, ok := breakdown["geoban"].(map[string]interface{}); ok {
				if total, ok := geoban["total"].(float64); ok {
					geobanBans = int(total)
				}
			}
			if whitelist, ok := breakdown["whitelist"].(map[string]interface{}); ok {
				if total, ok := whitelist["total"].(float64); ok {
					whitelistCount = int(total)
				}
			}
		}
	}

	// Build response with real data from nftban stats
	// IMPORTANT: "total" = ALL categories (blacklist + feeds + geoban + temp bans)
	totalBlocked := tempBans + blacklistBans + feedBans + geobanBans

	// Removed: fail2ban bans count (v1.0 migration to Suricata)

	response := map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"total":     totalBlocked,   // Total blocked IPs (temp + blacklist + feeds + geoban)
			"last_24h":  tempBans,       // Temporary bans from last 24h
			"whitelist": whitelistCount, // Whitelisted IPs
			"by_module": map[string]interface{}{
				"tempban":   tempBans,      // Temporary bans
				"blacklist": blacklistBans, // Permanent blacklist
				"feeds":     feedBans,      // Threat feed IPs
				"geoban":    geobanBans,    // Country blocking (v0.6.2)
			},
		},
	}

	respondJSON(w, http.StatusOK, response)
}

// StatsCountriesHandler returns top blocked countries
func StatsCountriesHandler(w http.ResponseWriter, r *http.Request) {
	// Get authenticated user
	claims, ok := r.Context().Value(middleware.UserContextKey).(*auth.Claims)
	if !ok {
		respondJSON(w, http.StatusUnauthorized, ErrorResponse{Error: "Unauthorized"})
		return
	}
	markUserActive(claims.Username)

	// Execute stats command for country information
	output, err := execNFTBanCommand("stats", "top", "countries", "5", "--json")
	if err != nil {
		log.Printf("[ERROR] Failed to get country stats: %v", err)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to retrieve country statistics"})
		return
	}

	// Parse JSON response
	var statsData map[string]interface{}
	if err := json.Unmarshal([]byte(output), &statsData); err != nil {
		log.Printf("[ERROR] Failed to parse country stats JSON: %v", err)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse country statistics"})
		return
	}

	// Build response with top countries
	response := map[string]interface{}{
		"success": true,
		"data":    []interface{}{},
	}

	// Extract countries from stats
	if data, ok := statsData["data"].(map[string]interface{}); ok {
		if items, ok := data["items"].([]interface{}); ok {
			response["data"] = items
		}
	}

	respondJSON(w, http.StatusOK, response)
}

// StatsTrendHandler returns 7-day trend analysis
// GET /api/v1/stats/trend
func StatsTrendHandler(w http.ResponseWriter, r *http.Request) {
	// Get authenticated user
	claims, ok := r.Context().Value(middleware.UserContextKey).(*auth.Claims)
	if !ok {
		respondJSON(w, http.StatusUnauthorized, ErrorResponse{Error: "Unauthorized"})
		return
	}
	markUserActive(claims.Username)

	// Execute nftban stats trend --json
	output, err := execNFTBanCommand("stats", "trend", "--json")
	if err != nil {
		log.Printf("[ERROR] Failed to get trend stats: %v", err)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to retrieve trend statistics"})
		return
	}

	// Strip comment lines (# NFTBAN_CMD_EXIT: ...) that bash wrapper adds
	lines := strings.Split(output, "\n")
	var jsonLines []string
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if !strings.HasPrefix(trimmed, "#") && trimmed != "" {
			jsonLines = append(jsonLines, line)
		}
	}
	cleanJSON := strings.Join(jsonLines, "\n")

	// Parse JSON response
	var trendData map[string]interface{}
	if err := json.Unmarshal([]byte(cleanJSON), &trendData); err != nil {
		log.Printf("[ERROR] Failed to parse trend JSON: %v - Raw: %s", err, cleanJSON)
		// Return empty trend data instead of error (trend data may not exist yet)
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"averages": map[string]interface{}{
					"avg_hourly": 0,
					"avg_daily":  0,
					"min":        0,
					"max":        0,
					"stddev":     0,
					"samples":    0,
				},
				"comparison": map[string]interface{}{
					"vs_yesterday": 0,
					"vs_last_week": nil,
				},
				"sources":    []interface{}{},
				"thresholds": map[string]interface{}{},
			},
		})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data":    trendData,
	})
}

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

// ConfigGetHandler handles GET /api/v1/config/:module
func ConfigGetHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	module := vars["module"]

	// Validate module name (all NFTBan configuration files)
	allowedModules := map[string]bool{
		"main":     true,
		"firewall": true,
		"feeds":    true,
		// Removed: "fail2ban" (v1.0 migration to Suricata)
		"portscan": true,
		"ddos":     true,
		"geoip":    true,
	}

	if !allowedModules[module] {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid module name"})
		return
	}

	// Execute nftban config get command
	output, err := execNFTBanCommand("config", "get", module, "--json")
	if err != nil {
		log.Printf("[ERROR] Failed to get config for %s: %v", module, err)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to get configuration"})
		return
	}

	// Strip any non-JSON output (comments, warnings, etc.) before parsing
	// Look for the first '{' and last '}' to extract only the JSON portion
	output = strings.TrimSpace(output)
	startIdx := strings.Index(output, "{")
	endIdx := strings.LastIndex(output, "}")

	if startIdx == -1 || endIdx == -1 || startIdx > endIdx {
		log.Printf("[ERROR] No valid JSON found in config output for %s: %s", module, output)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Invalid configuration response format"})
		return
	}

	jsonOutput := output[startIdx : endIdx+1]

	// Parse JSON response
	var configData map[string]interface{}
	if err := json.Unmarshal([]byte(jsonOutput), &configData); err != nil {
		log.Printf("[ERROR] Failed to parse config JSON for %s: %v - Output: %s", module, err, jsonOutput)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse configuration"})
		return
	}

	respondJSON(w, http.StatusOK, configData)
}

// ConfigSetHandler handles POST /api/v1/config/:module
func ConfigSetHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	module := vars["module"]

	// Validate module name (all NFTBan configuration files)
	allowedModules := map[string]bool{
		"main":     true,
		"firewall": true,
		"feeds":    true,
		// Removed: "fail2ban" (v1.0 migration to Suricata)
		"portscan": true,
		"ddos":     true,
		"geoip":    true,
	}

	if !allowedModules[module] {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid module name"})
		return
	}

	// Parse request body - expect {"key": "value", "key2": "value2", ...}
	var updates map[string]string
	if err := json.NewDecoder(r.Body).Decode(&updates); err != nil {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid request body"})
		return
	}

	// Apply each update
	var errors []string
	for key, value := range updates {
		keyValue := fmt.Sprintf("%s=%s", key, value)
		_, err := execNFTBanCommand("config", "set", module, keyValue)
		if err != nil {
			errors = append(errors, fmt.Sprintf("%s: %v", key, err))
		}
	}

	if len(errors) > 0 {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{
			Error: fmt.Sprintf("Failed to set some values: %s", strings.Join(errors, "; ")),
		})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": fmt.Sprintf("Configuration updated for %s", module),
		"updated": len(updates),
	})
}

// ConfigResetHandler handles POST /api/v1/config/:module/reset
func ConfigResetHandler(w http.ResponseWriter, r *http.Request) {
	vars := mux.Vars(r)
	module := vars["module"]

	// Validate module name (all NFTBan configuration files)
	allowedModules := map[string]bool{
		"main":     true,
		"firewall": true,
		"feeds":    true,
		// Removed: "fail2ban" (v1.0 migration to Suricata)
		"portscan": true,
		"ddos":     true,
		"geoip":    true,
	}

	if !allowedModules[module] {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid module name"})
		return
	}

	// Parse request body - accept multiple formats:
	// 1. {"keys": ["KEY1", "KEY2"]} - array of keys
	// 2. {"key": "KEY"} - single key (from frontend)
	// 3. {"reset_all": true} or {"all": true} - reset all
	// 4. empty body - reset all
	var req struct {
		Key      string   `json:"key"`       // single key (frontend format)
		Keys     []string `json:"keys"`      // array of keys
		ResetAll bool     `json:"reset_all"` // reset all flag
		All      bool     `json:"all"`       // alternate reset all flag
	}

	// Decode body - if empty or invalid, treat as reset all
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		// Empty body means reset all
		req.ResetAll = true
	}

	// Handle single key format (convert to array)
	if req.Key != "" && len(req.Keys) == 0 {
		req.Keys = []string{req.Key}
	}

	// Check for reset all (both formats)
	resetAll := req.ResetAll || req.All || (len(req.Keys) == 0 && req.Key == "")

	// Reset all configuration
	if resetAll {
		_, err := execNFTBanCommand("config", "reset-all", module)
		if err != nil {
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{
				Error: fmt.Sprintf("Failed to reset configuration: %v", err),
			})
			return
		}

		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"message": fmt.Sprintf("All %s configuration reset to defaults", module),
		})
		return
	}

	// Reset specific keys
	var errors []string
	for _, key := range req.Keys {
		_, err := execNFTBanCommand("config", "reset", module, key)
		if err != nil {
			errors = append(errors, fmt.Sprintf("%s: %v", key, err))
		}
	}

	if len(errors) > 0 {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{
			Error: fmt.Sprintf("Failed to reset some values: %s", strings.Join(errors, "; ")),
		})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": fmt.Sprintf("Reset %d configuration values", len(req.Keys)),
		"reset":   len(req.Keys),
	})
}

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

// PrometheusMetricsHandler fetches metrics from Prometheus exporter textfile
func PrometheusMetricsHandler(w http.ResponseWriter, r *http.Request) {
	// Use central config for metrics file path
	metricsFile := getPrometheusFile()

	// Check if metrics file exists
	if _, err := os.Stat(metricsFile); os.IsNotExist(err) {
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"available": false,
			"message":   "Metrics not available - exporter not running",
		})
		return
	}

	// Read metrics file
	content, err := os.ReadFile(metricsFile)
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to read metrics file"})
		return
	}

	// Parse Prometheus metrics format
	metrics := parsePrometheusMetrics(string(content))

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"available": true,
		"metrics":   metrics,
		"timestamp": time.Now().Unix(),
	})
}

// parsePrometheusMetrics parses Prometheus text exposition format
func parsePrometheusMetrics(content string) map[string]interface{} {
	metrics := make(map[string]interface{})
	lines := strings.Split(content, "\n")

	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Parse metric line: metric_name{labels} value
		parts := strings.Fields(line)
		if len(parts) >= 2 {
			metricName := parts[0]
			metricValue := parts[1]

			// Skip lines that are just numbers (malformed exporter output)
			// Valid lines must start with metric name (letters/underscores)
			if len(metricName) > 0 && (metricName[0] >= 'a' && metricName[0] <= 'z' || metricName[0] == '_') {
				// Handle labeled metrics (e.g., nftban_health_status{component="nftables"} 0)
				if strings.Contains(metricName, "{") {
					// Store the full metric name with labels as the key
					// This way GUI can access: metrics["nftban_health_status{component=\"nftables\"}"]
					metrics[metricName] = metricValue
				} else {
					// Simple metric without labels
					metrics[metricName] = metricValue
				}
			}
		}
	}

	return metrics
}

// Removed: Fail2BanLogsHandler function (v1.0 migration to Suricata)

// PortScanLogsHandler fetches PortScan detection logs with pagination
func PortScanLogsHandler(w http.ResponseWriter, r *http.Request) {
	lines := r.URL.Query().Get("lines")
	if lines == "" {
		lines = "100"
	}

	// Fetch portscan logs from nftban
	output, err := execNFTBanCommand("logs", "--lines", lines, "--json")
	if err != nil {
		// Try systemd journal if direct logs fail
		cmd := exec.Command("journalctl", "-u", "nftban-portscan", "-n", lines, "--no-pager", "-o", "json")
		journalOutput, jErr := cmd.Output()
		if jErr != nil {
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to fetch portscan logs"})
			return
		}

		var logs []map[string]interface{}
		for _, line := range strings.Split(string(journalOutput), "\n") {
			if strings.TrimSpace(line) == "" {
				continue
			}
			var entry map[string]interface{}
			if err := json.Unmarshal([]byte(line), &entry); err == nil {
				logs = append(logs, entry)
			}
		}

		respondJSON(w, http.StatusOK, map[string]interface{}{
			"logs":  logs,
			"count": len(logs),
		})
		return
	}

	// Parse JSON output
	var result map[string]interface{}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse portscan logs"})
		return
	}

	respondJSON(w, http.StatusOK, result)
}

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

// SystemLogsHandler provides unified system logs viewer
func SystemLogsHandler(w http.ResponseWriter, r *http.Request) {
	// Get query parameters
	service := r.URL.Query().Get("service") // nftban, fail2ban, sshd, etc
	lines := r.URL.Query().Get("lines")
	priority := r.URL.Query().Get("priority") // emerg, alert, crit, err, warning, notice, info, debug

	if lines == "" {
		lines = "100"
	}

	// Build journalctl command
	args := []string{
		"-n", lines,
		"--no-pager",
		"-o", "json",
	}

	if service != "" {
		args = append(args, "-u", service)
	}

	if priority != "" {
		args = append(args, "-p", priority)
	}

	cmd := exec.Command("journalctl", args...)
	output, err := cmd.Output()
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to fetch system logs"})
		return
	}

	// Parse JSON output
	var logs []map[string]interface{}
	for _, line := range strings.Split(string(output), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var entry map[string]interface{}
		if err := json.Unmarshal([]byte(line), &entry); err == nil {
			logs = append(logs, entry)
		}
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"logs":  logs,
		"count": len(logs),
		"filters": map[string]string{
			"service":  service,
			"lines":    lines,
			"priority": priority,
		},
	})
}

// DashboardMetricsHandler provides all metrics for impressive dashboard in one call
// OPTIMIZED: Removed slow nftban health call (9+ seconds), use Prometheus metrics instead
func DashboardMetricsHandler(w http.ResponseWriter, r *http.Request) {
	// Get authenticated user
	claims, ok := r.Context().Value(middleware.UserContextKey).(*auth.Claims)
	if !ok {
		respondJSON(w, http.StatusUnauthorized, ErrorResponse{Error: "Unauthorized"})
		return
	}
	markUserActive(claims.Username)

	// Aggregate all metrics in one response for impressive dashboard
	response := make(map[string]interface{})

	// 1. Prometheus metrics (if available) - includes CPU, RAM, Disk, Uptime
	// Use central config for metrics file path
	if content, err := os.ReadFile(getPrometheusFile()); err == nil {
		promMetrics := parsePrometheusMetrics(string(content))
		response["prometheus"] = promMetrics

		// Extract system stats for dashboard (cpu, ram, disk, uptime)
		// parsePrometheusMetrics returns map[string]interface{}, so use it directly
		// CPU usage from node_cpu_seconds_total
		if cpu, ok := promMetrics["node_cpu_seconds_total"].(float64); ok {
			response["cpu"] = fmt.Sprintf("%.1f%%", cpu)
		}

		// RAM usage from node_memory_MemAvailable_bytes
		if memAvail, ok := promMetrics["node_memory_MemAvailable_bytes"].(float64); ok {
			if memTotal, ok2 := promMetrics["node_memory_MemTotal_bytes"].(float64); ok2 && memTotal > 0 {
				usedPercent := ((memTotal - memAvail) / memTotal) * 100
				response["ram"] = fmt.Sprintf("%.1f%%", usedPercent)
			}
		}

		// Disk usage from node_filesystem_avail_bytes (root partition)
		if diskAvail, ok := promMetrics["node_filesystem_avail_bytes"].(float64); ok {
			if diskTotal, ok2 := promMetrics["node_filesystem_size_bytes"].(float64); ok2 && diskTotal > 0 {
				usedPercent := ((diskTotal - diskAvail) / diskTotal) * 100
				response["disk"] = fmt.Sprintf("%.1f%%", usedPercent)
			}
		}

		// Uptime from node_boot_time_seconds
		if bootTime, ok := promMetrics["node_boot_time_seconds"].(float64); ok {
			uptimeSeconds := time.Now().Unix() - int64(bootTime)
			days := uptimeSeconds / 86400
			hours := (uptimeSeconds % 86400) / 3600
			response["uptime"] = fmt.Sprintf("%dd %dh", days, hours)
		}
	} else {
		// Fallback: If Prometheus metrics not available, use basic system info
		response["cpu"] = "N/A"
		response["ram"] = "N/A"
		response["disk"] = "N/A"
		response["uptime"] = "N/A"
	}

	// 2. Current stats (from cache)
	statsCacheMux.RLock()
	response["stats"] = statsCache
	statsCacheMux.RUnlock()

	// 3. REMOVED: Slow nftban health call (9+ seconds)
	// Health data available via separate /api/v1/health endpoint if needed

	// 4. Grafana availability (fast check) - use service name from central config
	grafanaServiceName := "grafana-server"
	if svc := nftbanconf.GetServices(); svc != nil {
		grafanaServiceName = svc.Grafana
	}
	cmd := exec.Command("systemctl", "is-active", grafanaServiceName)
	grafanaOutput, _ := cmd.Output()
	response["grafana_available"] = strings.TrimSpace(string(grafanaOutput)) == "active"

	// 5. REMOVED: Recent bans call (can be slow)
	// Use stats cache instead, which is updated periodically

	// 6. REMOVED: Top countries call (can be slow)
	// Available via separate /api/v1/stats/countries endpoint

	response["timestamp"] = time.Now().Unix()

	respondJSON(w, http.StatusOK, response)
}

// SystemHostnameHandler returns the system hostname
func SystemHostnameHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execCommand("hostname")
	hostname := "unknown"
	if err == nil {
		hostname = strings.TrimSpace(output)
	}
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success":  true,
		"hostname": hostname,
	})
}

// FeedsStatsHandler returns feed statistics for dashboard
func FeedsStatsHandler(w http.ResponseWriter, r *http.Request) {
	// Use nftban-core feeds list --json (v0.7.3+)
	output, err := execNFTBanCoreCommand("feeds", "list", "--json")
	if err != nil {
		log.Printf("[FEEDS] Failed to get feeds list: %v", err)
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"active":    0,
				"total_ips": 0,
			},
		})
		return
	}

	// Parse JSON output from nftban-core
	var result struct {
		Success bool `json:"success"`
		Data    struct {
			Feeds []struct {
				Name    string `json:"name"`
				Enabled bool   `json:"enabled"`
				Count   int    `json:"count"`
			} `json:"feeds"`
			Total int `json:"total"`
		} `json:"data"`
	}

	if err := json.Unmarshal([]byte(output), &result); err != nil {
		log.Printf("[FEEDS] Failed to parse feeds JSON: %v", err)
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"active":    0,
				"total_ips": 0,
			},
		})
		return
	}

	// Count enabled feeds and total IPs
	active := 0
	totalIPs := 0

	for _, feed := range result.Data.Feeds {
		if feed.Enabled {
			active++
			totalIPs += feed.Count
		}
	}

	// Update shared state for BASIC tier consumers (sampler, stats CLI, status CLI)
	// This keeps feeds data fresh without needing CLI calls in other components
	state.UpdateFeeds(active, int64(totalIPs))

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"active":    active,
			"total_ips": totalIPs,
		},
	})
}


// ========================================================================
// ANALYTICS API HANDLERS (v0.7.3 - Ban Analytics & Statistics)
// ========================================================================

// AnalyticsSummaryHandler returns overall analytics summary
// Executes: nftban-core analytics summary --json
func AnalyticsSummaryHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execNFTBanCoreCommand("analytics", "summary", "--json")
	if err != nil {
		log.Printf("[ANALYTICS] Failed to get summary: %v", err)
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"total_ips":       0,
				"total_countries": 0,
				"ipv4_count":      0,
				"ipv6_count":      0,
			},
		})
		return
	}

	// Parse JSON output from nftban-core
	var result map[string]interface{}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		log.Printf("[ANALYTICS] Failed to parse summary JSON: %v", err)
		respondJSON(w, http.StatusInternalServerError, map[string]interface{}{
			"success": false,
			"error":   "Failed to parse analytics data",
		})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data":    result,
	})
}

// AnalyticsCountriesHandler returns country-based ban statistics
// Executes: nftban-core analytics countries --json
func AnalyticsCountriesHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execNFTBanCoreCommand("analytics", "countries", "--json")
	if err != nil {
		log.Printf("[ANALYTICS] Failed to get countries: %v", err)
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data":    []interface{}{},
		})
		return
	}

	// Parse JSON output from nftban-core (returns map[string]CountryStats)
	var countriesMap map[string]interface{}
	if err := json.Unmarshal([]byte(output), &countriesMap); err != nil {
		log.Printf("[ANALYTICS] Failed to parse countries JSON: %v", err)
		respondJSON(w, http.StatusInternalServerError, map[string]interface{}{
			"success": false,
			"error":   "Failed to parse countries data",
		})
		return
	}

	// Convert map to array for frontend consumption
	var countriesArray []interface{}
	for _, v := range countriesMap {
		countriesArray = append(countriesArray, v)
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data":    countriesArray,
	})
}

// AnalyticsTopCountriesHandler returns top N countries by ban count
// Executes: nftban-core analytics top [N] --json
func AnalyticsTopCountriesHandler(w http.ResponseWriter, r *http.Request) {
	// Get N from query parameter (default 10)
	n := r.URL.Query().Get("n")
	if n == "" {
		n = "10"
	}

	output, err := execNFTBanCoreCommand("analytics", "top", n, "--json")
	if err != nil {
		log.Printf("[ANALYTICS] Failed to get top countries: %v", err)
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success":       true,
			"count":         0,
			"top_countries": []interface{}{},
		})
		return
	}

	// Parse JSON output
	var result map[string]interface{}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		log.Printf("[ANALYTICS] Failed to parse top countries JSON: %v", err)
		respondJSON(w, http.StatusInternalServerError, map[string]interface{}{
			"success": false,
			"error":   "Failed to parse top countries data",
		})
		return
	}

	respondJSON(w, http.StatusOK, result)
}

// AnalyticsIPHandler looks up analytics data for a specific IP
// Executes: nftban-core analytics ip <IP> --json
func AnalyticsIPHandler(w http.ResponseWriter, r *http.Request) {
	// Get IP from query parameter
	ip := r.URL.Query().Get("ip")
	if ip == "" {
		respondJSON(w, http.StatusBadRequest, map[string]interface{}{
			"success": false,
			"error":   "IP parameter required",
		})
		return
	}

	output, err := execNFTBanCoreCommand("analytics", "ip", ip, "--json")
	if err != nil {
		log.Printf("[ANALYTICS] Failed to lookup IP %s: %v", ip, err)
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"ip":      ip,
			"found":   false,
			"message": "IP not found in analytics database",
		})
		return
	}

	// Parse JSON output
	var result map[string]interface{}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		log.Printf("[ANALYTICS] Failed to parse IP lookup JSON: %v", err)
		respondJSON(w, http.StatusInternalServerError, map[string]interface{}{
			"success": false,
			"error":   "Failed to parse IP lookup data",
		})
		return
	}

	respondJSON(w, http.StatusOK, result)
}

// RecentActivity represents a single recent activity event
type RecentActivity struct {
	Timestamp string `json:"timestamp"`
	Type      string `json:"type"`
	Action    string `json:"action"`
	IP        string `json:"ip"`
	Source    string `json:"source"`
	Details   string `json:"details"`
	TimeAgo   string `json:"time_ago"`
}

// RecentActivityHandler returns recent ban/unban/feed activity
// GET /api/v1/activity/recent?limit=10
func RecentActivityHandler(w http.ResponseWriter, r *http.Request) {
	limitStr := r.URL.Query().Get("limit")
	limit := 10
	if limitStr != "" {
		if l, err := strconv.Atoi(limitStr); err == nil && l > 0 && l <= 100 {
			limit = l
		}
	}

	var activities []RecentActivity

	// Read from nftban-actions.log (JSONL format) - use central config
	// NO FALLBACK - path must come from /etc/nftban/nftban.conf
	paths := nftbanconf.MustLoadPaths()
	logPath := paths.AuditLog
	if logPath == "" {
		logPath = getLogDir() + "/nftban-actions.log"
	}
	file, err := os.Open(logPath)
	if err != nil {
		log.Printf("[ACTIVITY] Failed to open actions log: %v", err)
		// Return empty array on error (not an API error)
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"activities": []RecentActivity{},
			},
		})
		return
	}
	defer file.Close()

	// Read all lines and take the last N
	var lines []string
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		lines = append(lines, scanner.Text())
	}

	// Take last N lines (most recent)
	start := 0
	if len(lines) > limit {
		start = len(lines) - limit
	}

	now := time.Now()
	for i := len(lines) - 1; i >= start; i-- {
		var entry map[string]interface{}
		if err := json.Unmarshal([]byte(lines[i]), &entry); err != nil {
			continue
		}

		activity := RecentActivity{}

		// Parse timestamp
		if ts, ok := entry["ts"].(string); ok {
			activity.Timestamp = ts
			// Calculate time ago
			if t, err := time.Parse(time.RFC3339, ts); err == nil {
				diff := now.Sub(t)
				if diff.Minutes() < 1 {
					activity.TimeAgo = "just now"
				} else if diff.Minutes() < 60 {
					activity.TimeAgo = fmt.Sprintf("%.0fm", diff.Minutes())
				} else if diff.Hours() < 24 {
					activity.TimeAgo = fmt.Sprintf("%.0fh", diff.Hours())
				} else {
					activity.TimeAgo = fmt.Sprintf("%.0fd", diff.Hours()/24)
				}
			}
		}

		// Parse event type
		if event, ok := entry["event"].(string); ok {
			activity.Action = event
		}

		// Parse source (portscan, ddos, fail2ban, feeds, manual, etc.)
		if source, ok := entry["source"].(string); ok {
			activity.Source = source
			// Map source to display type
			switch source {
			case "portscan":
				activity.Type = "Port scan"
			case "ddos":
				activity.Type = "DDoS blocked"
			case "fail2ban":
				activity.Type = "Fail2Ban"
			case "feeds", "feed":
				activity.Type = "Feed update"
			case "manual":
				activity.Type = "Manual"
			case "whitelist":
				activity.Type = "Whitelisted"
			case "login_monitor":
				activity.Type = "Login alert"
			default:
				activity.Type = source
			}
		}

		// Parse IP
		if ip, ok := entry["ip"].(string); ok {
			activity.IP = ip
			activity.Details = ip
		}

		// Parse additional details
		if reason, ok := entry["reason"].(string); ok {
			activity.Details = reason
		}

		activities = append(activities, activity)
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"activities": activities,
		},
	})
}

// =============================================================================
// BASIC STATS ENDPOINT - Shared State for CLI/UI
// =============================================================================
// This is the SINGLE SOURCE OF TRUTH for BASIC tier metrics.
// Populated by watchdog (netlink - NO CLI) and feeds loader (in-memory).
// Consumers: nftban stats, nftban status, UI dashboard, sampler
// =============================================================================

// BasicStatsHandler returns the shared state snapshot for BASIC tier consumers
// GET /api/v1/basic-stats
// This endpoint provides banned IPs, whitelist counts, feeds data WITHOUT CLI calls.
// Data comes from watchdog's netlink collection and feeds loader's in-memory state.
func BasicStatsHandler(w http.ResponseWriter, r *http.Request) {
	snap := state.Get()

	// Check if data is initialized
	if !state.IsInitialized() {
		respondJSON(w, http.StatusServiceUnavailable, map[string]interface{}{
			"success": false,
			"error":   "Watchdog not yet initialized - shared state empty",
		})
		return
	}

	// Check staleness (warn if data is older than 30s)
	stale := state.IsStale(30 * time.Second)

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"banned_ipv4":    snap.BannedIPv4,
			"banned_ipv6":    snap.BannedIPv6,
			"banned_total":   snap.BannedIPv4 + snap.BannedIPv6,
			"whitelist_ipv4": snap.WhitelistIPv4,
			"whitelist_ipv6": snap.WhitelistIPv6,
			"whitelist_total": snap.WhitelistIPv4 + snap.WhitelistIPv6,
			"rules_total":    snap.RulesTotal,
			"feeds_active":   snap.FeedsActive,
			"feeds_ips":      snap.FeedsIPs,
			"updated_at":     snap.UpdatedAt.Format(time.RFC3339),
			"age_ms":         state.GetAge().Milliseconds(),
			"stale":          stale,
		},
	})
}
