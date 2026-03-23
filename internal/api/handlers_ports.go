// =============================================================================
// NFTBan - Ports API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="handlers_ports"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-30"
// meta:description="Port management API handlers for NFTBan web interface"
// meta:input="HTTP requests for port operations"
// meta:output="JSON responses with port data"
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
	"os/exec"
	"strings"
)

// PortsHandler returns open ports status via CLI command
func PortsHandler(w http.ResponseWriter, r *http.Request) {
	log.Printf("[INFO] Getting ports status via CLI")

	// Call CLI via pkexec for root privileges (polkit rule allows nftban user)
	// Port scanning requires root for ss -tunlp to show process info
	// Path comes from central config - polkit rule must match NFTBAN_BIN
	cmd := exec.Command("/usr/bin/pkexec", getNFTBanCLI(), "port", "status", "--json")
	output, err := cmd.CombinedOutput()
	outputStr := string(output)

	// Check if we got valid output
	if outputStr == "" || (!strings.Contains(outputStr, "{") && err != nil) {
		log.Printf("[ERROR] Port status failed: %v (output: %s)", err, outputStr)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Port status check failed"})
		return
	}

	// Parse JSON response from CLI
	var portsData map[string]interface{}
	if err := json.Unmarshal([]byte(outputStr), &portsData); err != nil {
		log.Printf("[ERROR] Failed to parse ports JSON: %v (output: %s)", err, outputStr)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse ports data"})
		return
	}

	respondJSON(w, http.StatusOK, portsData)
}

// PortBanHandler bans a port via CLI
// POST /api/v1/ports/ban
func PortBanHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Port     int    `json:"port"`
		Protocol string `json:"protocol"` // tcp, udp, both
	}

	if !DecodeJSONBody(w, r, &req) {
		return
	}

	if req.Port < 1 || req.Port > 65535 {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid port number"})
		return
	}

	proto := req.Protocol
	if proto == "" {
		proto = "both"
	}

	// Call CLI: nftban port block <port>
	output, err := execNFTBanCommand("port", "block", fmt.Sprintf("%d", req.Port))
	if err != nil {
		log.Printf("[ERROR] Port ban failed: %v - %s", err, output)
		// Check if port is already blocked (not in whitelist)
		if strings.Contains(output, "not found in whitelist") {
			respondJSON(w, http.StatusOK, map[string]interface{}{
				"success": true,
				"message": fmt.Sprintf("Port %d is already blocked (not in whitelist)", req.Port),
			})
			return
		}
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to ban port: " + sanitizeError(err)})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": fmt.Sprintf("Port %d blocked successfully", req.Port),
	})
}

// PortUnbanHandler unbans a port via CLI
// POST /api/v1/ports/unban
func PortUnbanHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Port     int    `json:"port"`
		Protocol string `json:"protocol"` // tcp, udp, both
	}

	if !DecodeJSONBody(w, r, &req) {
		return
	}

	if req.Port < 1 || req.Port > 65535 {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid port number"})
		return
	}

	proto := req.Protocol
	if proto == "" {
		proto = "both"
	}

	// Call CLI: nftban port unblock <port>
	output, err := execNFTBanCommand("port", "unblock", fmt.Sprintf("%d", req.Port))
	if err != nil {
		log.Printf("[ERROR] Port unban failed: %v - %s", err, output)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to unban port: " + sanitizeError(err)})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": fmt.Sprintf("Port %d unblocked successfully", req.Port),
	})
}

// PortStatusHandler checks status of a specific port
// GET /api/v1/ports/status?port=22&protocol=tcp
func PortStatusHandler(w http.ResponseWriter, r *http.Request) {
	port := r.URL.Query().Get("port")
	if port == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Port parameter required"})
		return
	}

	// Call CLI: nftban port status <port> --json
	output, err := execNFTBanCommand("port", "status", port, "--json")
	if err != nil {
		log.Printf("[ERROR] Port status failed: %v", err)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to get port status"})
		return
	}

	var result map[string]interface{}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data":    map[string]string{"status": "unknown", "output": output},
		})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data":    result,
	})
}
