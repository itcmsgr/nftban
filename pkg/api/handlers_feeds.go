// =============================================================================
// NFTBan - Feeds API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="handlers_feeds"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-30"
// meta:description="Threat feeds management API handlers"
// meta:input="HTTP requests for feed operations"
// meta:output="JSON responses with feed data"
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
	"bufio"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/itcmsgr/nftban/pkg/state"
)

// FeedsHandler returns ALL threat feeds (enabled and disabled) from CLI
func FeedsHandler(w http.ResponseWriter, r *http.Request) {
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

	var feeds []map[string]interface{}
	totalIPs := 0
	feedsDir := getFeedsDir()

	lines := strings.Split(output, "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if !strings.Contains(line, "[✓]") && !strings.Contains(line, "[✗]") {
			continue
		}
		if !strings.Contains(line, "enabled") && !strings.Contains(line, "IPs") {
			continue
		}

		enabled := strings.Contains(line, "[✓]")
		line = strings.ReplaceAll(line, "│", "")
		line = strings.ReplaceAll(line, "[✓]", "")
		line = strings.ReplaceAll(line, "[✗]", "")
		line = strings.TrimSpace(line)

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

		ipCount := 0
		lastUpdate := "-"
		if enabled {
			feedLower := strings.ToLower(feedID)
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

// countLinesInFile counts non-empty, non-comment lines in a file
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
		if line != "" && !strings.HasPrefix(line, "#") {
			count++
		}
	}
	return count
}

// FeedsControlHandler handles enable/disable feed operations
func FeedsControlHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Action string `json:"action"`
		Feed   string `json:"feed"`
	}

	if !DecodeJSONBody(w, r, &req) {
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

	feedName := strings.ToUpper(req.Feed)
	output, err := execNFTBanCommand("feeds", req.Action, feedName)
	if err != nil {
		log.Printf("[ERROR] Feeds %s failed: %v - %s", req.Action, err, output)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to " + req.Action + " feed: " + sanitizeError(err)})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": "Feed " + req.Feed + " " + req.Action + "d successfully",
	})
}

// FeedsStatsHandler returns feed statistics for dashboard
func FeedsStatsHandler(w http.ResponseWriter, r *http.Request) {
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

	active := 0
	totalIPs := 0

	for _, feed := range result.Data.Feeds {
		if feed.Enabled {
			active++
			totalIPs += feed.Count
		}
	}

	state.UpdateFeeds(active, int64(totalIPs))

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"active":    active,
			"total_ips": totalIPs,
		},
	})
}
