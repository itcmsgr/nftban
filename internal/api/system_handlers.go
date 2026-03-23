// =============================================================================
// NFTBan - System Status API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="system_handlers"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="HTTP API handlers for system status, health, and services"
// meta:input="HTTP requests for system information"
// meta:output="JSON responses with system status data"
// meta:depends="net/http"
// meta:inventory.files=""
// meta:inventory.binaries="nftban,systemctl"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package api

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"regexp"
	"strings"
)

// readVersionFromFile reads the NFTBan version from the VERSION file
func readVersionFromFile() string {
	versionPaths := []string{
		"/usr/lib/nftban/VERSION",
		"/opt/nftban/VERSION",
	}
	for _, path := range versionPaths {
		if data, err := os.ReadFile(path); err == nil {
			version := strings.TrimSpace(string(data))
			if version != "" {
				return "v" + version
			}
		}
	}
	return "v1.2.1" // Fallback to current version
}

// SystemOverviewStatusHandler returns comprehensive system status for overview
// GET /api/v1/system/status
func SystemOverviewStatusHandler(w http.ResponseWriter, r *http.Request) {
	data := make(map[string]interface{})

	// Get nftban status
	output, err := execNFTBanCommand("status", "--json")
	if err == nil {
		// Strip any non-JSON output (comments, warnings, etc.) before parsing
		output = strings.TrimSpace(output)
		startIdx := strings.Index(output, "{")
		endIdx := strings.LastIndex(output, "}")

		if startIdx != -1 && endIdx != -1 && startIdx <= endIdx {
			jsonOutput := output[startIdx : endIdx+1]
			var statusResult map[string]interface{}
			if json.Unmarshal([]byte(jsonOutput), &statusResult) == nil {
				if statusData, ok := statusResult["data"].(map[string]interface{}); ok {
					data["active"] = true
					data["version"] = statusData["version"]
					if fw, ok := statusData["firewall"].(map[string]interface{}); ok {
						data["rules"] = fw["rules"]
						data["banned"] = fw["banned"]
					}
				}
			}
		}
	}
	if data["active"] == nil {
		data["active"] = false
		data["version"] = readVersionFromFile()
		data["rules"] = 0
		data["banned"] = 0
	}

	// Check protection modules (parse text output, not JSON)
	ddosOut, _ := execNFTBanCommand("ddos", "status")
	data["ddos_enabled"] = strings.Contains(ddosOut, "Master Switch: ✅ ENABLED") ||
		strings.Contains(ddosOut, "ENABLED")

	portscanOut, _ := execNFTBanCommand("portscan", "status")
	data["portscan_enabled"] = strings.Contains(portscanOut, "Master Switch: ✅ ENABLED") ||
		strings.Contains(portscanOut, "ENABLED")

	loginOut, _ := execNFTBanCommand("login", "status", "--json")
	data["login_enabled"] = strings.Contains(loginOut, "enabled") || strings.Contains(loginOut, "true")

	// Feeds count
	feedsOut, _ := execNFTBanCommand("feeds", "status", "--json")
	data["feeds_active"] = countMatches(feedsOut, `"enabled":\s*true`)

	// Services status
	data["nftables_running"] = isServiceRunning("nftables")
	// Removed: fail2ban_running (v1.0 migration to Suricata)
	data["ui_running"] = isServiceRunning("nftban-ui")
	data["login_monitor_running"] = isServiceRunning("nftban-login-monitor")

	// Count running services
	services := []string{"nftables", "nftban-ui", "nftban-ui-auth", "nftban-login-monitor", "nftban-unified-exporter"}
	running := 0
	for _, svc := range services {
		if isServiceRunning(svc) {
			running++
		}
	}
	data["services_running"] = running
	data["services_total"] = len(services)

	// Timers
	timersOut, _ := execCommand("systemctl", "list-timers", "--no-pager")
	data["timers_active"] = strings.Count(timersOut, "nftban")

	// Modules
	modulesOut, _ := execNFTBanCommand("module", "--json")
	data["modules_total"] = countMatches(modulesOut, `"name"`)
	data["modules_enabled"] = countMatches(modulesOut, `"status":\s*"ENABLED"`)

	// Health summary
	healthOut, _ := execNFTBanCommand("health", "summary")
	if strings.Contains(healthOut, "OK") {
		data["health_status"] = "OK"
		data["health_errors"] = 0
		data["health_warnings"] = 0
	} else {
		data["health_status"] = "ERROR"
		data["health_errors"] = countMatches(healthOut, `error`)
		data["health_warnings"] = countMatches(healthOut, `warning`)
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data":    data,
	})
}

// SystemTimersDetailHandler returns detailed systemd timer information
// GET /api/v1/system/timers/detail
func SystemTimersDetailHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execCommand("systemctl", "list-timers", "--all", "--no-pager")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to get timers"})
		return
	}

	timers := []map[string]interface{}{}
	nftbanTimers := []string{
		"nftban-health.timer",
		"nftban-unified-exporter.timer",
		"nftban-queue.timer",
		"nftban-core-feeds.timer",
		"nftban-core-geoip.timer",
		"nftban-suricata-update.timer",
		// TODO: Future timers (disabled until snapshot command implemented)
		// "nftban-snapshot.timer",
		// "nftban-rollback.timer",
	}

	for _, timerName := range nftbanTimers {
		timer := map[string]interface{}{
			"name":     timerName,
			"active":   strings.Contains(output, timerName),
			"schedule": getTimerSchedule(timerName),
			"next_run": getTimerNextRun(output, timerName),
		}
		timers = append(timers, timer)
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data":    timers,
	})
}

// SystemHealthHandler returns health check results
// GET /api/v1/system/health
func SystemHealthHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execNFTBanCommand("health", "check", "--quiet")
	if err != nil {
		// Health check may return non-zero for errors/warnings, that's OK
		log.Printf("[INFO] Health check returned: %v", err)
	}

	data := map[string]interface{}{
		"status":        "OK",
		"errors":        0,
		"warnings":      0,
		"errors_list":   []string{},
		"warnings_list": []string{},
		"checks":        []map[string]string{},
	}

	// Parse output
	lines := strings.Split(output, "\n")
	var errorsList []string
	var warningsList []string

	for _, line := range lines {
		line = strings.TrimSpace(line)
		if strings.Contains(line, "ERROR") || strings.Contains(line, "error") {
			errorsList = append(errorsList, line)
		} else if strings.Contains(line, "WARNING") || strings.Contains(line, "warning") {
			warningsList = append(warningsList, line)
		}
	}

	data["errors"] = len(errorsList)
	data["warnings"] = len(warningsList)
	data["errors_list"] = errorsList
	data["warnings_list"] = warningsList

	if len(errorsList) > 0 {
		data["status"] = "ERROR"
	} else if len(warningsList) > 0 {
		data["status"] = "WARNING"
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data":    data,
	})
}

// SystemHealthFixHandler runs health fix
// POST /api/v1/system/health/fix
func SystemHealthFixHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execNFTBanCommand("health", "fix", "all")
	if err != nil {
		log.Printf("[ERROR] Health fix failed: %v - %s", err, output)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Health fix failed: " + sanitizeError(err)})
		return
	}

	respondJSON(w, http.StatusOK, SuccessResponse{
		Success: true,
		Message: "Health fix completed",
	})
}

// SystemServicesDetailHandler returns detailed services list with status
// GET /api/v1/system/services/detail
func SystemServicesDetailHandler(w http.ResponseWriter, r *http.Request) {
	services := []map[string]interface{}{
		{"name": "nftables", "description": "Netfilter firewall", "running": isServiceRunning("nftables")},
		// Removed: fail2ban service (v1.0 migration to Suricata)
		{"name": "nftban-ui", "description": "Web GUI", "running": isServiceRunning("nftban-ui")},
		{"name": "nftban-ui-auth", "description": "Auth service", "running": isServiceRunning("nftban-ui-auth")},
		{"name": "nftban-login-monitor", "description": "Login alerts", "running": isServiceRunning("nftban-login-monitor")},
		{"name": "nftban-unified-exporter", "description": "Unified metrics exporter", "running": isServiceRunning("nftban-unified-exporter")},
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data":    services,
	})
}

// SystemInfoHandler returns system information
// GET /api/v1/system/info
func SystemInfoHandler(w http.ResponseWriter, r *http.Request) {
	data := make(map[string]interface{})

	// Hostname
	if out, err := execCommand("hostname"); err == nil {
		data["hostname"] = strings.TrimSpace(out)
	}

	// OS
	if out, err := execCommand("cat", "/etc/os-release"); err == nil {
		for _, line := range strings.Split(out, "\n") {
			if strings.HasPrefix(line, "PRETTY_NAME=") {
				data["os"] = strings.Trim(strings.TrimPrefix(line, "PRETTY_NAME="), "\"")
				break
			}
		}
	}

	// Kernel
	if out, err := execCommand("uname", "-r"); err == nil {
		data["kernel"] = strings.TrimSpace(out)
	}

	// Uptime
	if out, err := execCommand("uptime", "-p"); err == nil {
		data["uptime"] = strings.TrimSpace(out)
	}

	// CPU load
	if out, err := execCommand("cat", "/proc/loadavg"); err == nil {
		parts := strings.Fields(out)
		if len(parts) >= 3 {
			data["cpu"] = parts[0] + ", " + parts[1] + ", " + parts[2]
		}
	}

	// Memory
	if out, err := execCommand("free", "-h"); err == nil {
		lines := strings.Split(out, "\n")
		if len(lines) >= 2 {
			parts := strings.Fields(lines[1])
			if len(parts) >= 4 {
				data["memory"] = parts[2] + " / " + parts[1] + " used"
			}
		}
	}

	// Disk
	if out, err := execCommand("df", "-h", "/"); err == nil {
		lines := strings.Split(out, "\n")
		if len(lines) >= 2 {
			parts := strings.Fields(lines[1])
			if len(parts) >= 5 {
				data["disk"] = parts[2] + " / " + parts[1] + " (" + parts[4] + " used)"
			}
		}
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data":    data,
	})
}

// SystemFHSHandler returns FHS compliance report
// GET /api/v1/system/fhs
func SystemFHSHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execNFTBanCommand("fhs", "--json")
	if err != nil {
		// Try without --json
		output, _ = execNFTBanCommand("fhs")
	}

	// Parse output into structured data
	directories := []map[string]interface{}{}
	lines := strings.Split(output, "\n")
	okCount, errCount, missingCount := 0, 0, 0

	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "=") || strings.HasPrefix(line, "DIRECTORY") || strings.HasPrefix(line, "---") || strings.HasPrefix(line, "Total") {
			continue
		}

		// Parse FHS output line
		parts := strings.Fields(line)
		if len(parts) >= 4 {
			dir := map[string]interface{}{
				"path":     parts[0],
				"expected": "",
				"actual":   "",
				"status":   "OK",
				"notes":    "",
			}

			// Find status
			for i, p := range parts {
				if p == "OK" || strings.Contains(p, "✔") {
					dir["status"] = "OK"
					okCount++
					if i > 0 {
						dir["expected"] = parts[1]
					}
					if i > 1 {
						dir["actual"] = parts[2]
					}
					break
				} else if p == "ERROR" || strings.Contains(p, "✖") {
					dir["status"] = "ERROR"
					errCount++
					if len(parts) > i+1 {
						dir["notes"] = strings.Join(parts[i+1:], " ")
					}
					break
				} else if strings.Contains(p, "MISSING") || strings.Contains(p, "⚠") {
					dir["status"] = "MISSING"
					missingCount++
					break
				}
			}

			directories = append(directories, dir)
		}
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"directories": directories,
			"total":       len(directories),
			"ok":          okCount,
			"errors":      errCount,
			"missing":     missingCount,
		},
	})
}

// SystemFHSFixHandler fixes FHS issues
// POST /api/v1/system/fhs/fix
func SystemFHSFixHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execNFTBanCommand("health", "fix", "all")
	if err != nil {
		log.Printf("[ERROR] FHS fix failed: %v - %s", err, output)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "FHS fix failed: " + sanitizeError(err)})
		return
	}

	respondJSON(w, http.StatusOK, SuccessResponse{
		Success: true,
		Message: "FHS issues fixed",
	})
}

// Helper functions

func isServiceRunning(name string) bool {
	out, err := execCommand("systemctl", "is-active", name)
	return err == nil && strings.TrimSpace(out) == "active"
}

func countMatches(text, pattern string) int {
	re := regexp.MustCompile(pattern)
	return len(re.FindAllString(text, -1))
}

func getTimerSchedule(timerName string) string {
	schedules := map[string]string{
		"nftban-health.timer":           "Daily at 03:00",
		"nftban-unified-exporter.timer": "Every 1 minute",
		"nftban-daily-report.timer":     "Daily",
		"nftban-core-feeds.timer":       "Every 4 hours",
		"nftban-core-geoip.timer":       "Daily",
		"nftban-maintenance.timer":      "Every 10 minutes",
		"nftban-snapshot.timer":         "Hourly",
		"nftban-rollback.timer":         "On boot",
	}
	if s, ok := schedules[timerName]; ok {
		return s
	}
	return "-"
}

func getTimerNextRun(output, timerName string) string {
	lines := strings.Split(output, "\n")
	for _, line := range lines {
		if strings.Contains(line, timerName) {
			parts := strings.Fields(line)
			if len(parts) >= 3 {
				return parts[0] + " " + parts[1]
			}
		}
	}
	return "-"
}

// Note: execCommand is defined in handlers.go, using that instead
