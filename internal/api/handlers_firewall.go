// =============================================================================
// NFTBan - Firewall API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="handlers_firewall"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-30"
// meta:description="Firewall validation, check, and stats API handlers"
// meta:input="HTTP requests for firewall operations"
// meta:output="JSON responses with firewall data"
// meta:depends="github.com/itcmsgr/nftban/internal/api"
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
	"net"
	"net/http"
	"strconv"
)

// FirewallCheckRequest represents the request body for firewall check
type FirewallCheckRequest struct {
	Value string `json:"value"` // IP or port to check
}

// FirewallValidateHandler validates nftables structure against NFTBan spec
func FirewallValidateHandler(w http.ResponseWriter, r *http.Request) {
	// Execute nftban firewall validate --json
	output, err := execNFTBanCommand("firewall", "validate", "--json")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: sanitizeError(err)})
		return
	}

	// Parse JSON output
	var result map[string]interface{}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse validation result"})
		return
	}

	respondJSON(w, http.StatusOK, result)
}

// FirewallCheckHandler checks if IP or port is blocked/allowed
func FirewallCheckHandler(w http.ResponseWriter, r *http.Request) {
	var req FirewallCheckRequest
	if !DecodeJSONBody(w, r, &req) {
		return
	}

	if req.Value == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Value is required"})
		return
	}

	// Input validation: value must be a valid IPv4/IPv6 address or a valid port number (1-65535)
	if net.ParseIP(req.Value) == nil {
		// Not a valid IP, check if it's a valid port number
		port, err := strconv.Atoi(req.Value)
		if err != nil || port < 1 || port > 65535 {
			respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid input: value must be a valid IPv4/IPv6 address or port number (1-65535)"})
			return
		}
	}

	// Execute nftban firewall check <value> --json
	output, err := execNFTBanCommand("firewall", "check", req.Value, "--json")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: sanitizeError(err)})
		return
	}

	// Parse JSON output
	var result map[string]interface{}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse check result"})
		return
	}

	respondJSON(w, http.StatusOK, result)
}

// FirewallStatsHandler returns firewall statistics
func FirewallStatsHandler(w http.ResponseWriter, r *http.Request) {
	// Execute nftban firewall stats --json
	output, err := execNFTBanCommand("firewall", "stats", "--json")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: sanitizeError(err)})
		return
	}

	// Parse JSON output
	var result map[string]interface{}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse stats result"})
		return
	}

	respondJSON(w, http.StatusOK, result)
}
