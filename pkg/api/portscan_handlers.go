package api

import (
	"encoding/json"
	"log"
	"net/http"
	"strings"
)

// PortscanStats represents portscan statistics
type PortscanStats struct {
	MonitoredPorts int  `json:"monitored_ports"`
	Blocked24h     int  `json:"blocked_24h"`
	BlockedTotal   int  `json:"blocked_total"`
	Enabled        bool `json:"enabled"`
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
