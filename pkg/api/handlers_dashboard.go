// =============================================================================
// NFTBan - Dashboard API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="handlers_dashboard"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-30"
// meta:description="Dashboard and status API handlers for NFTBan web interface"
// meta:input="HTTP requests for dashboard and health operations"
// meta:output="JSON responses with status and health data"
// meta:depends="github.com/itcmsgr/nftban/pkg/auth,github.com/itcmsgr/nftban/pkg/state"
// meta:inventory.files=""
// meta:inventory.binaries="nftban"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package api

import (
	"encoding/json"
	"log"
	"net/http"
	"os/exec"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/pkg/auth"
	"github.com/itcmsgr/nftban/pkg/middleware"
	"github.com/itcmsgr/nftban/pkg/state"
	"github.com/itcmsgr/nftban/pkg/util"
)

// DashboardHandler returns dashboard statistics
// Uses shared state for BASIC metrics (NO CLI), falls back to CLI for full status
func DashboardHandler(w http.ResponseWriter, r *http.Request) {
	// Get authenticated user from context
	claims, ok := r.Context().Value(middleware.UserContextKey).(*auth.Claims)
	if !ok {
		respondJSON(w, http.StatusUnauthorized, ErrorResponse{Error: "Unauthorized"})
		return
	}

	// Try shared state first for BASIC metrics (NO CLI overhead)
	var statusData map[string]interface{}
	if state.IsInitialized() && !state.IsStale(30*time.Second) {
		snap := state.Get()
		// Build status from shared state - instant, no CLI
		statusData = map[string]interface{}{
			"firewall": map[string]interface{}{
				"banned_ips":    snap.BannedIPv4 + snap.BannedIPv6,
				"banned_ipv4":   snap.BannedIPv4,
				"banned_ipv6":   snap.BannedIPv6,
				"whitelist_ips": snap.WhitelistIPv4 + snap.WhitelistIPv6,
				"rule_count":    snap.RulesTotal,
			},
			"feeds": map[string]interface{}{
				"active":    snap.FeedsActive,
				"total_ips": snap.FeedsIPs,
			},
			"source": "shared_state",
		}
	} else {
		// Fallback to CLI for full status
		output, err := execNFTBanCommand("status", "--json")
		if err != nil {
			log.Printf("[ERROR] Failed to get dashboard data: %v", err)
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to retrieve dashboard data"})
			return
		}

		// Parse JSON output from CLI
		if err := json.Unmarshal([]byte(output), &statusData); err != nil {
			log.Printf("[ERROR] Failed to parse dashboard JSON: %v (output: %s)", err, output)
			respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse dashboard data"})
			return
		}
		statusData["source"] = "cli"
	}

	// Build dashboard response with user info and status data
	dashboard := map[string]interface{}{
		"user":   claims.Username,
		"status": statusData,
	}

	respondJSON(w, http.StatusOK, dashboard)
}

// StatusHandler returns firewall status
func StatusHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execNFTBanCommand("status", "--json")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to get status"})
		return
	}

	// Extract JSON from CLI output (may contain non-JSON prefix/suffix)
	jsonOutput := util.ExtractJSONRobust(output)
	if jsonOutput == "" {
		log.Printf("[ERROR] No valid JSON found in status output: %s", output)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Invalid status response format"})
		return
	}

	// Parse JSON response from CLI
	var statusData map[string]interface{}
	if err := json.Unmarshal([]byte(jsonOutput), &statusData); err != nil {
		log.Printf("[ERROR] Failed to parse status JSON: %v - Output: %s", err, jsonOutput)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse status data"})
		return
	}

	respondJSON(w, http.StatusOK, statusData)
}

// HealthHandler returns system health check
func HealthHandler(w http.ResponseWriter, r *http.Request) {
	// Note: health command may return non-zero exit code for warnings, but still produces valid JSON
	cmd := exec.Command(getNFTBanCLI(), "health", "--json")
	output, err := cmd.CombinedOutput()
	outputStr := string(output)

	// Check if we got valid output (even if exit code is non-zero due to warnings)
	if outputStr == "" || (!strings.Contains(outputStr, "{") && err != nil) {
		log.Printf("[ERROR] Health check failed: %v (output: %s)", err, outputStr)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Health check failed"})
		return
	}

	// Parse JSON response from CLI
	var healthData map[string]interface{}
	if err := json.Unmarshal([]byte(outputStr), &healthData); err != nil {
		log.Printf("[ERROR] Failed to parse health JSON: %v (output: %s)", err, outputStr)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse health data"})
		return
	}

	respondJSON(w, http.StatusOK, healthData)
}

// HealthFixHandler runs automated fixes via CLI command
func HealthFixHandler(w http.ResponseWriter, r *http.Request) {
	log.Printf("[INFO] Running health fix via CLI")

	// Call existing CLI command: nftban health fix all - use central config
	cmd := exec.Command(getNFTBanCLI(), "health", "fix", "all")
	output, err := cmd.CombinedOutput()
	outputStr := string(output)

	// Health fix may return non-zero for warnings, check output
	if err != nil && !strings.Contains(outputStr, "Fix complete") {
		log.Printf("[ERROR] Health fix failed: %v (output: %s)", err, outputStr)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{
			Error: "Health fix failed: " + sanitizeError(err),
		})
		return
	}

	log.Printf("[INFO] Health fix completed")

	// Return success with output
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": "Health fix completed successfully",
		"output":  outputStr,
	})
}
