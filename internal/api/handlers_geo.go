// =============================================================================
// NFTBan - Geographic API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="handlers_geo"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-30"
// meta:description="Geographic and GeoIP/GeoBan API handlers"
// meta:input="HTTP requests for geographic operations"
// meta:output="JSON responses with geographic data"
// meta:depends="github.com/itcmsgr/nftban/internal/nftbanconf"
// meta:inventory.files=""
// meta:inventory.binaries="nftban"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
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
	"strings"
	"time"
)

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


// parseGeoOutput parses geographic statistics output from nftban CLI
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
