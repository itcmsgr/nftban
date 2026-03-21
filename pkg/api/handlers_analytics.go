// =============================================================================
// NFTBan - Analytics API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="handlers_analytics"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-30"
// meta:description="Ban analytics and statistics API handlers"
// meta:input="HTTP requests for analytics operations"
// meta:output="JSON responses with analytics data"
// meta:depends="github.com/itcmsgr/nftban/pkg/nftbanconf"
// meta:inventory.files=""
// meta:inventory.binaries="nftban-core"
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
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/itcmsgr/nftban/pkg/logutil"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
)

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
		log.Printf("[ANALYTICS] Failed to lookup IP %s: %v", logutil.Sanitize(ip), err)
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
	// Use GetPaths() instead of MustLoadPaths() - config already loaded at startup
	paths := nftbanconf.GetPaths()
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
