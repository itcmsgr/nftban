// =============================================================================
// NFTBan - Firewall Emulation API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="emulate_handlers"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="HTTP API handlers for firewall rule emulation and testing"
// meta:input="HTTP requests with IP, protocol, port, direction"
// meta:output="JSON responses with allow/block decisions"
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
	"net"
	"net/http"
	"os/exec"
	"strconv"
	"strings"
)

// EmulateQuery represents the query parameters for emulation
type EmulateQuery struct {
	IP        string `json:"ip"`
	Protocol  string `json:"protocol,omitempty"`
	Port      int    `json:"port,omitempty"`
	Direction string `json:"direction,omitempty"`
	Family    string `json:"family"`
}

// EmulateReason explains why the decision was made
type EmulateReason struct {
	Module       string `json:"module"`
	Source       string `json:"source"`
	ListType     string `json:"list_type"`
	MatchingCIDR string `json:"matching_cidr"`
}

// EmulateNFT contains nftables-specific information
type EmulateNFT struct {
	Family     string `json:"family"`
	Table      string `json:"table"`
	Chain      string `json:"chain"`
	RuleHandle int    `json:"rule_handle,omitempty"`
	SetName    string `json:"set_name,omitempty"`
}

// EmulateResult is the full result of an emulation
type EmulateResult struct {
	Decision    string        `json:"decision"`
	Reason      EmulateReason `json:"reason"`
	NFTables    EmulateNFT    `json:"nftables"`
	Explanation string        `json:"explanation"`
}

// EmulateEvalEntry tracks each set evaluation
type EmulateEvalEntry struct {
	Set     string `json:"set"`
	Matched bool   `json:"matched"`
	Entry   string `json:"entry,omitempty"`
}

// EmulateResponse is the complete API response
type EmulateResponse struct {
	Query           EmulateQuery       `json:"query"`
	Result          EmulateResult      `json:"result"`
	EvaluationOrder []EmulateEvalEntry `json:"evaluation_order"`
}

// EmulateHandler handles GET /api/v1/emulate
// Query parameters: ip (required), proto, port, direction
func EmulateHandler(w http.ResponseWriter, r *http.Request) {
	// Get query parameters
	ip := r.URL.Query().Get("ip")
	if ip == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "IP address required"})
		return
	}

	// Validate IP
	if net.ParseIP(ip) == nil {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid IP address"})
		return
	}

	proto := r.URL.Query().Get("proto")
	portStr := r.URL.Query().Get("port")
	direction := r.URL.Query().Get("direction")

	// Validate protocol
	if proto != "" {
		proto = strings.ToLower(proto)
		if proto != "tcp" && proto != "udp" && proto != "icmp" && proto != "icmpv6" {
			respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid protocol (use tcp, udp, icmp)"})
			return
		}
	}

	// Validate port
	var port int
	if portStr != "" {
		var err error
		port, err = strconv.Atoi(portStr)
		if err != nil || port < 1 || port > 65535 {
			respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid port (must be 1-65535)"})
			return
		}
	}

	// Validate direction
	if direction == "" {
		direction = "in"
	} else {
		direction = strings.ToLower(direction)
		if direction != "in" && direction != "out" && direction != "fwd" {
			respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid direction (use in, out, fwd)"})
			return
		}
	}

	// Build CLI command
	args := []string{"emulate", ip, "--json"}
	if proto != "" {
		args = append(args, "--proto", proto)
	}
	if port > 0 {
		args = append(args, "--port", strconv.Itoa(port))
	}
	if direction != "" {
		args = append(args, "--direction", direction)
	}

	// Execute nftban emulate - use central config for CLI path
	cmd := exec.Command(getNFTBanCLI(), args...)
	output, err := cmd.Output()
	if err != nil {
		// Exit code 2 means blocked (still valid)
		if exitErr, ok := err.(*exec.ExitError); ok && exitErr.ExitCode() == 2 {
			// Blocked - output is still valid JSON
		} else {
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{
				Error: "Failed to execute emulation: " + err.Error(),
			})
			return
		}
	}

	// Parse the JSON output from CLI
	var response EmulateResponse
	if err := json.Unmarshal(output, &response); err != nil {
		// Try to return raw output for debugging
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{
			Error: "Failed to parse emulation result: " + err.Error(),
		})
		return
	}

	respondJSON(w, http.StatusOK, response)
}

// EmulateQuickHandler handles GET /api/v1/emulate/quick
// Returns just allow/block for simple checks
func EmulateQuickHandler(w http.ResponseWriter, r *http.Request) {
	ip := r.URL.Query().Get("ip")
	if ip == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "IP address required"})
		return
	}

	// Validate IP
	if net.ParseIP(ip) == nil {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid IP address"})
		return
	}

	// Execute quick check - use central config for CLI path
	cmd := exec.Command(getNFTBanCLI(), "emulate", ip, "--json")
	output, _ := cmd.Output() // Ignore exit code, we just need the output

	// Parse just the decision
	var response struct {
		Result struct {
			Decision string `json:"decision"`
		} `json:"result"`
	}
	if err := json.Unmarshal(output, &response); err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{
			Error: "Failed to parse result",
		})
		return
	}

	respondJSON(w, http.StatusOK, map[string]string{
		"ip":       ip,
		"decision": response.Result.Decision,
	})
}

// EmulateBatchHandler handles POST /api/v1/emulate/batch
// Accepts array of IPs to check
func EmulateBatchHandler(w http.ResponseWriter, r *http.Request) {
	var request struct {
		IPs []string `json:"ips"`
	}

	if !DecodeJSONBody(w, r, &request) {
		return
	}

	if len(request.IPs) == 0 {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "No IPs provided"})
		return
	}

	if len(request.IPs) > 100 {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Maximum 100 IPs per batch"})
		return
	}

	results := make([]map[string]string, 0, len(request.IPs))

	for _, ip := range request.IPs {
		// Validate IP
		if net.ParseIP(ip) == nil {
			results = append(results, map[string]string{
				"ip":       ip,
				"decision": "error",
				"error":    "invalid IP",
			})
			continue
		}

		// Execute quick check - use central config for CLI path
		cmd := exec.Command(getNFTBanCLI(), "emulate", ip, "--json")
		output, _ := cmd.Output()

		var response struct {
			Result struct {
				Decision string `json:"decision"`
			} `json:"result"`
		}
		if err := json.Unmarshal(output, &response); err != nil {
			results = append(results, map[string]string{
				"ip":       ip,
				"decision": "error",
				"error":    "parse failed",
			})
			continue
		}

		results = append(results, map[string]string{
			"ip":       ip,
			"decision": response.Result.Decision,
		})
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"results": results,
		"total":   len(results),
	})
}
