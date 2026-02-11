// =============================================================================
// NFTBan - Statistics API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="handlers_stats"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-30"
// meta:description="Statistics and metrics API handlers"
// meta:input="HTTP requests for stats operations"
// meta:output="JSON responses with statistics data"
// meta:depends="github.com/itcmsgr/nftban/pkg/state"
// meta:inventory.files=""
// meta:inventory.binaries="nftban,nftban-core"
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
	"strconv"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/pkg/auth"
	"github.com/itcmsgr/nftban/pkg/middleware"
	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/state"
	"github.com/itcmsgr/nftban/pkg/util"
)

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
	cleanJSON := strings.TrimSpace(util.StripCommentLines(statsOutput))

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
	cleanJSON := strings.TrimSpace(util.StripCommentLines(output))

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
			"banned_ipv4":     snap.BannedIPv4,
			"banned_ipv6":     snap.BannedIPv6,
			"banned_total":    snap.BannedIPv4 + snap.BannedIPv6,
			"whitelist_ipv4":  snap.WhitelistIPv4,
			"whitelist_ipv6":  snap.WhitelistIPv6,
			"whitelist_total": snap.WhitelistIPv4 + snap.WhitelistIPv6,
			"rules_total":     snap.RulesTotal,
			"feeds_active":    snap.FeedsActive,
			"feeds_ips":       snap.FeedsIPs,
			"updated_at":      snap.UpdatedAt.Format(time.RFC3339),
			"age_ms":          state.GetAge().Milliseconds(),
			"stale":           stale,
		},
	})
}
