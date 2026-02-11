// =============================================================================
// NFTBan - System Management API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="handlers_system"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-30"
// meta:description="System services, modules, and timers management API handlers"
// meta:input="HTTP requests for system operations"
// meta:output="JSON responses with system data"
// meta:depends="os/exec"
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
	"fmt"
	"net/http"
	"strings"
)

// SystemServicesHandler returns system services status
func SystemServicesHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execNFTBanCommand("services")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to get services"})
		return
	}

	// Return raw output for now (can be enhanced with JSON parsing)
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"output": output,
	})
}

// SystemModulesHandler returns NFTBan modules inventory
func SystemModulesHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execNFTBanCommand("module")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to get modules"})
		return
	}

	// Return raw output for now (can be enhanced with JSON parsing)
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"output": output,
	})
}

// SystemTimersHandler returns systemd timers status
func SystemTimersHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execCommand("systemctl", "list-timers", "nftban*", "--no-pager")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to get timers"})
		return
	}

	// Return raw output for now (can be enhanced with JSON parsing)
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"output": output,
	})
}

// SystemServiceControlHandler handles service start/stop/restart
func SystemServiceControlHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Service string `json:"service"`
		Action  string `json:"action"`
	}

	if !DecodeJSONBody(w, r, &req) {
		return
	}

	// Validate service name (only allow specific services)
	allowedServices := map[string]bool{
		// Removed: "fail2ban" (v1.0 migration to Suricata)
		"nftables": true,
	}

	if !allowedServices[req.Service] {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Service not allowed"})
		return
	}

	// Validate action
	allowedActions := map[string]bool{
		"start":   true,
		"stop":    true,
		"restart": true,
		"status":  true,
	}

	if !allowedActions[req.Action] {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "Invalid action"})
		return
	}

	// Execute systemctl command
	output, err := execCommand("systemctl", req.Action, req.Service)
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: fmt.Sprintf("Failed to %s %s: %v", req.Action, req.Service, err)})
		return
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"message": fmt.Sprintf("Service %s %sed successfully", req.Service, req.Action),
		"output":  output,
	})
}

// SystemHostnameHandler returns the system hostname
func SystemHostnameHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execCommand("hostname")
	hostname := "unknown"
	if err == nil {
		hostname = strings.TrimSpace(output)
	}
	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success":  true,
		"hostname": hostname,
	})
}
