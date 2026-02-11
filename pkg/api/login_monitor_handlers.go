// =============================================================================
// NFTBan - Login Monitor API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="login_monitor_handlers"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="HTTP API handlers for login monitoring status and events"
// meta:input="HTTP requests for login events and status"
// meta:output="JSON responses with login statistics and events"
// meta:depends="net/http"
// meta:inventory.files="/var/log/nftban/login_alert.log,/var/log/auth.log"
// meta:inventory.binaries="nftban"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package api

import (
	"bufio"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// getLoginAlertLogPath returns the login alert log path from central config
// NO FALLBACK - path must come from /etc/nftban/nftban.conf
func getLoginAlertLogPath() string {
	logFiles := getLogFiles()
	if path, ok := logFiles["login_alert"]; ok {
		return path
	}
	// This shouldn't happen if getLogFiles() is correct
	return getLogDir() + "/login_alert.log"
}

// LoginMonitorStatus represents login monitor status
type LoginMonitorStatus struct {
	ConfigExists   bool                   `json:"config_exists"`
	ModuleExists   bool                   `json:"module_exists"`
	ServiceStatus  string                 `json:"service_status"`
	Config         LoginMonitorConfig     `json:"config"`
	Monitoring     LoginMonitorTypes      `json:"monitoring"`
	FailedAttempts LoginMonitorFailed     `json:"failed_attempts"`
	LogLines       int                    `json:"log_lines"`
}

type LoginMonitorConfig struct {
	Enabled bool   `json:"enabled"`
	Format  string `json:"format"`
	GeoIP   bool   `json:"geoip"`
}

type LoginMonitorTypes struct {
	SSH     bool `json:"ssh"`
	SU      bool `json:"su"`
	SUDO    bool `json:"sudo"`
	Console bool `json:"console"`
}

type LoginMonitorFailed struct {
	AlertOnFailed bool `json:"alert_on_failed"`
	Threshold     int  `json:"threshold"`
	WindowSeconds int  `json:"window_seconds"`
}

// LoginMonitorStats represents login statistics
type LoginMonitorStats struct {
	Events  LoginEventStats   `json:"events"`
	Service LoginServiceStats `json:"service"`
}

type LoginEventStats struct {
	Total   int `json:"total"`
	Success int `json:"success"`
	Failed  int `json:"failed"`
	Today   int `json:"today"`
}

type LoginServiceStats struct {
	Running bool   `json:"running"`
	Uptime  string `json:"uptime"`
}

// LoginEvent represents a single login event
type LoginEvent struct {
	Timestamp string `json:"timestamp"`
	Type      string `json:"type"`
	User      string `json:"user"`
	IP        string `json:"ip"`
	Location  string `json:"location"`
	Status    string `json:"status"`
}

// LoginUser represents user login statistics
type LoginUser struct {
	Username  string `json:"username"`
	Total     int    `json:"total"`
	Success   int    `json:"success"`
	Failed    int    `json:"failed"`
	LastLogin string `json:"last_login"`
}

// LoginMonitorStatusHandler returns login monitor status
// GET /api/v1/login-monitor/status
func LoginMonitorStatusHandler(w http.ResponseWriter, r *http.Request) {
	// Execute: nftban login status --json
	output, err := execNFTBanCommand("login", "status", "--json")
	if err != nil {
		log.Printf("[ERROR] Failed to get login monitor status: %v", err)
		// Return default status on error
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": LoginMonitorStatus{
				ConfigExists:  false,
				ModuleExists:  false,
				ServiceStatus: "not_installed",
				Monitoring:    LoginMonitorTypes{},
			},
		})
		return
	}

	// Try to parse JSON output
	var result map[string]interface{}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		// If JSON parsing fails, parse the text output
		status := parseLoginStatusText(output)
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data":    status,
		})
		return
	}

	// Extract inner data if present (CLI returns {success, data: {...}})
	if innerData, ok := result["data"]; ok {
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data":    innerData,
		})
		return
	}

	// Return parsed JSON as-is
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data":    result,
	})
}

// parseLoginStatusText parses text output from nftban login status
func parseLoginStatusText(output string) LoginMonitorStatus {
	status := LoginMonitorStatus{
		ServiceStatus: "not_installed",
		Monitoring:    LoginMonitorTypes{},
	}

	lines := strings.Split(output, "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if strings.Contains(line, "Configuration:") && strings.Contains(line, "/etc/nftban") {
			status.ConfigExists = true
		}
		if strings.Contains(line, "Core Module: Installed") {
			status.ModuleExists = true
		}
		if strings.Contains(line, "Service: Running") {
			status.ServiceStatus = "running"
		} else if strings.Contains(line, "Service:") && strings.Contains(line, "not running") {
			status.ServiceStatus = "stopped"
		}
		if strings.Contains(line, "SSH:") && strings.Contains(line, "true") {
			status.Monitoring.SSH = true
		}
		if strings.Contains(line, "SU:") && strings.Contains(line, "true") {
			status.Monitoring.SU = true
		}
		if strings.Contains(line, "SUDO:") && strings.Contains(line, "true") {
			status.Monitoring.SUDO = true
		}
		if strings.Contains(line, "Console:") && strings.Contains(line, "true") {
			status.Monitoring.Console = true
		}
	}

	return status
}

// LoginMonitorStatsHandler returns login statistics
// GET /api/v1/login-monitor/stats
func LoginMonitorStatsHandler(w http.ResponseWriter, r *http.Request) {
	// Execute: nftban login stats --json
	output, err := execNFTBanCommand("login", "stats", "--json")
	if err != nil {
		log.Printf("[ERROR] Failed to get login stats: %v", err)
		// Return empty stats on error
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": LoginMonitorStats{
				Events:  LoginEventStats{},
				Service: LoginServiceStats{},
			},
		})
		return
	}

	// Try to parse JSON output
	var result map[string]interface{}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		// Parse text output and get stats from log file
		stats := parseLoginStatsFromLog()
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data":    stats,
		})
		return
	}

	// Extract inner data if present (CLI returns {success, data: {...}})
	if innerData, ok := result["data"]; ok {
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data":    innerData,
		})
		return
	}

	// Return parsed JSON as-is
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data":    result,
	})
}

// parseLoginStatsFromLog reads and parses the login log file
func parseLoginStatsFromLog() LoginMonitorStats {
	stats := LoginMonitorStats{
		Events:  LoginEventStats{},
		Service: LoginServiceStats{},
	}

	logPath := getLoginAlertLogPath() // Use central config
	file, err := os.Open(logPath)
	if err != nil {
		return stats
	}
	defer file.Close()

	today := time.Now().Format("2006-01-02")
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		stats.Events.Total++

		if strings.Contains(line, "SUCCESS") {
			stats.Events.Success++
		} else if strings.Contains(line, "FAILED") {
			stats.Events.Failed++
		}

		if strings.Contains(line, today) {
			stats.Events.Today++
		}
	}

	// Check service status
	output, err := execNFTBanCommand("login", "status")
	if err == nil && strings.Contains(output, "Service: Running") {
		stats.Service.Running = true
	}

	return stats
}

// LoginMonitorEventsHandler returns recent login events
// GET /api/v1/login-monitor/events?limit=100
func LoginMonitorEventsHandler(w http.ResponseWriter, r *http.Request) {
	limitStr := r.URL.Query().Get("limit")
	limit := 100
	if limitStr != "" {
		if l, err := strconv.Atoi(limitStr); err == nil && l > 0 {
			limit = l
		}
	}

	events := parseLoginEvents(limit)

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"events": events,
		},
	})
}

// parseLoginEvents reads login events from log and auth.log
func parseLoginEvents(limit int) []LoginEvent {
	var events []LoginEvent

	// Read from nftban login_alert.log - use central config
	logPath := getLoginAlertLogPath()
	file, err := os.Open(logPath)
	if err == nil {
		defer file.Close()
		scanner := bufio.NewScanner(file)
		var lines []string
		for scanner.Scan() {
			lines = append(lines, scanner.Text())
		}
		// Read last N lines
		start := 0
		if len(lines) > limit {
			start = len(lines) - limit
		}
		for i := len(lines) - 1; i >= start; i-- {
			if event := parseLoginLogLine(lines[i]); event != nil {
				events = append(events, *event)
			}
		}
	}

	// If no events from nftban log, try auth.log for SSH events
	if len(events) == 0 {
		events = parseAuthLog(limit)
	}

	return events
}

// parseLoginLogLine parses a single line from login_alert.log
func parseLoginLogLine(line string) *LoginEvent {
	// Expected format: [2025-11-21 10:30:00] [SSH] [SUCCESS] user@192.168.1.1 - Location info
	event := &LoginEvent{}

	// Extract timestamp
	tsRegex := regexp.MustCompile(`\[(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\]`)
	if matches := tsRegex.FindStringSubmatch(line); len(matches) > 1 {
		event.Timestamp = matches[1]
	}

	// Extract type (SSH, SU, SUDO, CONSOLE)
	typeRegex := regexp.MustCompile(`\[(SSH|SU|SUDO|CONSOLE)\]`)
	if matches := typeRegex.FindStringSubmatch(line); len(matches) > 1 {
		event.Type = matches[1]
	}

	// Extract status
	if strings.Contains(line, "[SUCCESS]") {
		event.Status = "SUCCESS"
	} else if strings.Contains(line, "[FAILED]") {
		event.Status = "FAILED"
	}

	// Extract user and IP
	userIPRegex := regexp.MustCompile(`(\w+)@([\d\.]+)`)
	if matches := userIPRegex.FindStringSubmatch(line); len(matches) > 2 {
		event.User = matches[1]
		event.IP = matches[2]
	}

	// Extract location (after the dash)
	if idx := strings.Index(line, " - "); idx > 0 {
		event.Location = strings.TrimSpace(line[idx+3:])
	}

	if event.Timestamp == "" && event.Type == "" {
		return nil
	}

	return event
}

// parseAuthLog parses /var/log/auth.log or /var/log/secure for SSH events
func parseAuthLog(limit int) []LoginEvent {
	var events []LoginEvent

	// Try both auth.log (Debian/Ubuntu) and secure (RHEL/CentOS)
	logPaths := []string{"/var/log/auth.log", "/var/log/secure"}

	for _, logPath := range logPaths {
		file, err := os.Open(logPath)
		if err != nil {
			continue
		}
		defer file.Close()

		scanner := bufio.NewScanner(file)
		var lines []string
		for scanner.Scan() {
			line := scanner.Text()
			// Match SSH events: Accepted, Failed, Invalid user, Connection closed
			if strings.Contains(line, "sshd") &&
				(strings.Contains(line, "Accepted") ||
					strings.Contains(line, "Failed") ||
					strings.Contains(line, "Invalid user") ||
					strings.Contains(line, "Connection closed") ||
					strings.Contains(line, "Disconnected from")) {
				lines = append(lines, line)
			}
		}

		// Get last N lines
		start := 0
		if len(lines) > limit {
			start = len(lines) - limit
		}

		for i := len(lines) - 1; i >= start && len(events) < limit; i-- {
			if event := parseAuthLogLine(lines[i]); event != nil {
				events = append(events, *event)
			}
		}

		if len(events) > 0 {
			break
		}
	}

	return events
}

// parseAuthLogLine parses a single line from auth.log/secure
func parseAuthLogLine(line string) *LoginEvent {
	event := &LoginEvent{
		Type: "SSH",
	}

	// Extract timestamp (e.g., "Nov 21 10:30:00" or "Dec  7 00:03:14")
	parts := strings.Fields(line)
	if len(parts) >= 3 {
		event.Timestamp = strings.Join(parts[0:3], " ")
	}

	// Determine status
	if strings.Contains(line, "Accepted") {
		event.Status = "SUCCESS"
	} else if strings.Contains(line, "Failed") ||
		strings.Contains(line, "Invalid user") ||
		strings.Contains(line, "Connection closed") ||
		strings.Contains(line, "Disconnected from") {
		event.Status = "FAILED"
	} else {
		return nil
	}

	// Extract user - handle multiple patterns:
	// "for root from", "for invalid user oracle from", "user root", "Invalid user oracle from"
	userPatterns := []string{
		`for (?:invalid user )?(\w+)`,
		`Invalid user (\w+) from`,
		`user (\w+) `,
		`Disconnected from (?:authenticating )?user (\w+)`,
	}
	for _, pattern := range userPatterns {
		userRegex := regexp.MustCompile(pattern)
		if matches := userRegex.FindStringSubmatch(line); len(matches) > 1 {
			event.User = matches[1]
			break
		}
	}

	// Extract IP - handle both "from IP" and "Connection from IP"
	ipPatterns := []string{
		`from ([\d\.]+)`,
		`Connection from ([\d\.]+)`,
	}
	for _, pattern := range ipPatterns {
		ipRegex := regexp.MustCompile(pattern)
		if matches := ipRegex.FindStringSubmatch(line); len(matches) > 1 {
			event.IP = matches[1]
			break
		}
	}

	return event
}

// LoginMonitorUsersHandler returns users with login activity
// GET /api/v1/login-monitor/users
func LoginMonitorUsersHandler(w http.ResponseWriter, r *http.Request) {
	users := aggregateUserStats()

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"users": users,
		},
	})
}

// aggregateUserStats aggregates login stats per user
func aggregateUserStats() []LoginUser {
	userMap := make(map[string]*LoginUser)

	// Get events
	events := parseLoginEvents(500)

	for _, event := range events {
		if event.User == "" {
			continue
		}

		user, exists := userMap[event.User]
		if !exists {
			user = &LoginUser{Username: event.User}
			userMap[event.User] = user
		}

		user.Total++
		if event.Status == "SUCCESS" {
			user.Success++
			if user.LastLogin == "" || event.Timestamp > user.LastLogin {
				user.LastLogin = event.Timestamp
			}
		} else {
			user.Failed++
		}
	}

	// Convert to slice
	var users []LoginUser
	for _, user := range userMap {
		users = append(users, *user)
	}

	return users
}

// LoginMonitorControlHandler enables/disables login monitoring
// POST /api/v1/login-monitor/control
func LoginMonitorControlHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Action string `json:"action"` // enable or disable
		Target string `json:"target"` // ssh, su, sudo, console, service, all
	}

	if !DecodeJSONBody(w, r, &req) {
		return
	}

	// Validate action
	if req.Action != "enable" && req.Action != "disable" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid action. Use 'enable' or 'disable'"})
		return
	}

	// Default target to service
	if req.Target == "" {
		req.Target = "service"
	}

	// Validate target
	validTargets := map[string]bool{"ssh": true, "su": true, "sudo": true, "console": true, "service": true, "all": true}
	if !validTargets[req.Target] {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid target"})
		return
	}

	// Execute: nftban login enable/disable <target>
	output, err := execNFTBanCommand("login", req.Action, req.Target)
	if err != nil {
		log.Printf("[ERROR] Failed to %s login monitor %s: %v - Output: %s", req.Action, req.Target, err, output)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{
			Error: "Failed to " + req.Action + " login monitor: " + err.Error(),
		})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": "Login monitor " + req.Target + " " + req.Action + "d successfully",
	})
}
