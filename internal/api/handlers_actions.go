// =============================================================================
// NFTBan - Action API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="handlers_actions"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-30"
// meta:description="Action API handlers for firewall operations (reload, flush, sync)"
// meta:input="HTTP requests for firewall actions"
// meta:output="JSON responses with operation results"
// meta:depends="github.com/itcmsgr/nftban/internal/auth,github.com/itcmsgr/nftban/internal/middleware"
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
	"os"
	"strings"

	"github.com/itcmsgr/nftban/internal/auth"
	"github.com/itcmsgr/nftban/internal/middleware"
	"github.com/itcmsgr/nftban/internal/state"
)

// RulesHandler returns nftables set statistics from daemon cache.
// v1.33.0: Read real set data from /run/nftban/set_counts.json (P1-11)
func RulesHandler(w http.ResponseWriter, r *http.Request) {
	cacheFile := "/run/nftban/set_counts.json"
	data, err := os.ReadFile(cacheFile)
	if err != nil {
		// Fallback: daemon may not be running
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"sets": []map[string]interface{}{},
		})
		return
	}

	var snapshot map[string]interface{}
	if err := json.Unmarshal(data, &snapshot); err != nil {
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"sets": []map[string]interface{}{},
		})
		return
	}

	// Convert sets map to array format for API consumers
	setsMap, ok := snapshot["sets"].(map[string]interface{})
	if !ok {
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"sets": []map[string]interface{}{},
		})
		return
	}

	sets := make([]map[string]interface{}, 0, len(setsMap))
	for name, info := range setsMap {
		entry := map[string]interface{}{
			"name": name,
		}
		if m, ok := info.(map[string]interface{}); ok {
			for k, v := range m {
				entry[k] = v
			}
		}
		sets = append(sets, entry)
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"sets":       sets,
		"timestamp":  snapshot["timestamp"],
		"scale_mode": snapshot["scale_mode"],
	})
}

// ReloadHandler reloads nftban firewall configuration
func ReloadHandler(w http.ResponseWriter, r *http.Request) {
	claims, _ := r.Context().Value(middleware.UserContextKey).(*auth.Claims)

	_, err := execNFTBanCommand("firewall", "reload")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to reload: " + sanitizeError(err)})
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
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to update feeds: " + sanitizeError(err)})
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
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to flush runtime bans: " + sanitizeError(err)})
		return
	}

	log.Printf("[AUDIT] User %s flushed runtime bans (blacklist_ipv4 + blacklist_ipv6)", claims.Username)
	respondJSON(w, http.StatusOK, SuccessResponse{Success: true, Message: "Runtime bans flushed successfully"})
}

// SearchHandler searches for an IP across all NFTBan components
func SearchHandler(w http.ResponseWriter, r *http.Request) {
	ip := r.URL.Query().Get("ip")
	if ip == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "IP parameter is required"})
		return
	}
	if !validateIPOrCIDR(ip) {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid IP format"})
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
			if locs, ok := searchData["locations"].([]string); ok {
				searchData["locations"] = append(locs, "whitelist")
			}
		}

		// Check if blacklisted (matches "MATCHED: blacklist_ipv4" or "blacklist" in output)
		if strings.Contains(outputLower, "blacklist") || strings.Contains(outputLower, "❌ blocked") {
			searchData["blacklisted"] = true
			searchData["found"] = true
			if locs, ok := searchData["locations"].([]string); ok {
				searchData["locations"] = append(locs, "blacklist")
			}
		}

		// Check if in feeds
		if strings.Contains(outputLower, "found in feeds") || strings.Contains(outputLower, "⚠️  potentially blocked") {
			searchData["in_feeds"] = true
			searchData["found"] = true
			if locs, ok := searchData["locations"].([]string); ok {
				searchData["locations"] = append(locs, "threat_feeds")
			}
		}
	}

	respondJSON(w, http.StatusOK, searchData)
}

// PortscanControlHandler handles portscan enable/disable/status
func PortscanControlHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Action string `json:"action"` // enable, disable, status
	}

	if !DecodeJSONBody(w, r, &req) {
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
			Error: "Failed to " + req.Action + " portscan: " + sanitizeError(err),
		})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": fmt.Sprintf("Portscan %s successful", req.Action),
		"output":  output,
	})
}
