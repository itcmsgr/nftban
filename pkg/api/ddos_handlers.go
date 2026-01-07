// =============================================================================
// NFTBan - DDoS Protection API Handlers
// =============================================================================
// SPDX-License-Identifier: GPL-3.0-or-later
// meta:name="ddos_handlers"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="HTTP API handlers for DDoS protection status and control"
// meta:input="HTTP requests for DDoS operations"
// meta:output="JSON responses with DDoS statistics"
// meta:depends="net/http"
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
	"log"
	"net/http"
	"strings"
)

// DdosStats represents DDoS protection statistics
type DdosStats struct {
	PacketsDropped    int    `json:"packets_dropped"`
	BytesDropped      int    `json:"bytes_dropped"`
	Blocked24h        int    `json:"blocked_24h"`
	BlockedTotal      int    `json:"blocked_total"`
	Enabled           bool   `json:"enabled"`
	RateLimit         int    `json:"rate_limit"`
	Mode              string `json:"mode"`               // classic, suricata, hybrid
	SuricataAvailable bool   `json:"suricata_available"` // is Suricata service running
}

// DdosStatsHandler returns DDoS protection statistics
// GET /api/v1/ddos/stats
func DdosStatsHandler(w http.ResponseWriter, r *http.Request) {
	// Execute: nftban ddos stats --json (dedicated DDoS stats command)
	output, err := execNFTBanCommand("ddos", "stats", "--json")
	if err != nil {
		log.Printf("[ERROR] Failed to get ddos stats: %v", err)
		// Return default stats on error
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"ddos": DdosStats{
					Enabled: false,
				},
			},
		})
		return
	}

	// Strip any non-JSON output (comments, warnings, etc.) before parsing
	// Look for the first '{' and last '}' to extract only the JSON portion
	output = strings.TrimSpace(output)
	startIdx := strings.Index(output, "{")
	endIdx := strings.LastIndex(output, "}")

	if startIdx == -1 || endIdx == -1 || startIdx > endIdx {
		log.Printf("[ERROR] No valid JSON found in ddos stats output: %s", output)
		// Return default stats on invalid JSON
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"ddos": DdosStats{
					Enabled: false,
				},
			},
		})
		return
	}

	jsonOutput := output[startIdx : endIdx+1]

	// Parse the JSON output
	var result struct {
		Success bool `json:"success"`
		Data    struct {
			Ddos DdosStats `json:"ddos"`
		} `json:"data"`
	}

	if err := json.Unmarshal([]byte(jsonOutput), &result); err != nil {
		log.Printf("[ERROR] Failed to parse ddos stats output: %v - Output: %s", err, jsonOutput)
		// Return default stats on parse error
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"ddos": DdosStats{
					Enabled: false,
				},
			},
		})
		return
	}

	respondJSON(w, http.StatusOK, result)
}

// DdosControlHandler handles DDoS enable/disable
// POST /api/v1/ddos/enable or /api/v1/ddos/disable
func DdosControlHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Action string `json:"action"` // "enable" or "disable"
	}

	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid request"})
		return
	}

	var output string
	var err error

	switch req.Action {
	case "enable":
		output, err = execNFTBanCommand("ddos", "enable")
	case "disable":
		output, err = execNFTBanCommand("ddos", "disable")
	default:
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid action. Use 'enable' or 'disable'"})
		return
	}

	if err != nil {
		log.Printf("[ERROR] DDoS %s failed: %v - %s", req.Action, err, output)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to " + req.Action + " DDoS protection"})
		return
	}

	respondJSON(w, http.StatusOK, SuccessResponse{
		Success: true,
		Message: "DDoS protection " + req.Action + "d successfully",
	})
}

// DdosEnableHandler enables DDoS protection
// POST /api/v1/ddos/enable
func DdosEnableHandler(w http.ResponseWriter, r *http.Request) {
	// Use bash CLI for ddos enable - it handles the actual implementation
	output, err := execNFTBanCommand("ddos", "enable")
	if err != nil {
		log.Printf("[ERROR] DDoS enable failed: %v - %s", err, output)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to enable DDoS protection"})
		return
	}

	respondJSON(w, http.StatusOK, SuccessResponse{
		Success: true,
		Message: "DDoS protection enabled successfully",
	})
}

// DdosDisableHandler disables DDoS protection
// POST /api/v1/ddos/disable
func DdosDisableHandler(w http.ResponseWriter, r *http.Request) {
	// Use bash CLI for ddos disable - it handles the actual implementation
	output, err := execNFTBanCommand("ddos", "disable")
	if err != nil {
		log.Printf("[ERROR] DDoS disable failed: %v - %s", err, output)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to disable DDoS protection"})
		return
	}

	respondJSON(w, http.StatusOK, SuccessResponse{
		Success: true,
		Message: "DDoS protection disabled successfully",
	})
}
