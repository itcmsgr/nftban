// =============================================================================
// NFTBan - Metrics API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="handlers_metrics"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-30"
// meta:description="Metrics and Prometheus API handlers for NFTBan dashboard"
// meta:input="HTTP requests for metrics operations"
// meta:output="JSON responses with metrics data"
// meta:depends="github.com/itcmsgr/nftban/pkg/metrics,github.com/itcmsgr/nftban/pkg/auth"
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
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/pkg/auth"
	"github.com/itcmsgr/nftban/pkg/metrics"
	"github.com/itcmsgr/nftban/pkg/middleware"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
)

// MetricsEnableHandler enables continuous metrics sampling (overrides session-based logic)
func MetricsEnableHandler(w http.ResponseWriter, r *http.Request) {
	type EnableRequest struct {
		Enable bool `json:"enable"`
	}

	var req EnableRequest
	if !DecodeJSONBody(w, r, &req) {
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
