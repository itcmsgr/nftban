// =============================================================================
// NFTBan - Portscan Detection API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="portscan_handlers"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="HTTP API handlers for port scan detection statistics"
// meta:input="HTTP requests for portscan status"
// meta:output="JSON responses with portscan statistics"
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

// PortscanStats represents portscan statistics
type PortscanStats struct {
	MonitoredPorts    int    `json:"monitored_ports"`
	Blocked24h        int    `json:"blocked_24h"`
	BlockedTotal      int    `json:"blocked_total"`
	Enabled           bool   `json:"enabled"`
	Mode              string `json:"mode"`               // classic, suricata, hybrid
	SuricataAvailable bool   `json:"suricata_available"` // is Suricata service running
}

// PortscanStatsHandler returns portscan statistics
// GET /api/v1/portscan/stats
func PortscanStatsHandler(w http.ResponseWriter, r *http.Request) {
	// Execute: nftban portscan stats --json (dedicated portscan stats command)
	output, err := execNFTBanCommand("portscan", "stats", "--json")
	if err != nil {
		log.Printf("[ERROR] Failed to get portscan stats: %v", err)
		// Return default stats on error
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"portscan": PortscanStats{
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
		log.Printf("[ERROR] No valid JSON found in portscan stats output: %s", output)
		// Return default stats on invalid JSON
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"portscan": PortscanStats{
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
			Portscan PortscanStats `json:"portscan"`
		} `json:"data"`
	}

	if err := json.Unmarshal([]byte(jsonOutput), &result); err != nil {
		log.Printf("[ERROR] Failed to parse portscan stats output: %v - Output: %s", err, jsonOutput)
		// Return default stats on parse error
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"portscan": PortscanStats{
					Enabled: false,
				},
			},
		})
		return
	}

	respondJSON(w, http.StatusOK, result)
}
