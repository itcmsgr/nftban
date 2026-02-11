// =============================================================================
// NFTBan - Ban and Whitelist API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="handlers_bans"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-30"
// meta:description="Ban, unban, and whitelist management API handlers"
// meta:input="HTTP requests for ban/whitelist operations"
// meta:output="JSON responses with operation results"
// meta:depends="github.com/itcmsgr/nftban/pkg/auth"
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
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"

	"github.com/itcmsgr/nftban/pkg/auth"
	"github.com/itcmsgr/nftban/pkg/middleware"
)

// BanHandler bans an IP address
func BanHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		IP      string `json:"ip"`
		Reason  string `json:"reason"`
		Timeout string `json:"timeout"` // optional: "24h", "permanent", etc.
	}

	if !DecodeJSONBody(w, r, &req) {
		return
	}

	if req.IP == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "IP address is required"})
		return
	}

	args := []string{"ban", req.IP}
	if req.Reason != "" {
		args = append(args, "--reason", req.Reason)
	}

	output, err := execNFTBanCommandPrivileged(args...)
	hasSuccess := strings.Contains(output, "✅") || strings.Contains(output, "has been banned successfully")
	if err != nil && !hasSuccess {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: fmt.Sprintf("Failed to ban IP: %v", err)})
		return
	}

	claims, _ := r.Context().Value(middleware.UserContextKey).(*auth.Claims)
	log.Printf("[AUDIT] User %s banned IP: %s (reason: %s)", claims.Username, req.IP, req.Reason)

	respondJSON(w, http.StatusOK, SuccessResponse{
		Success: true,
		Message: fmt.Sprintf("IP %s banned successfully", req.IP),
	})
}

// UnbanHandler unbans an IP address
func UnbanHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		IP string `json:"ip"`
	}

	if !DecodeJSONBody(w, r, &req) {
		return
	}

	if req.IP == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "IP address is required"})
		return
	}

	output, err := execNFTBanCommandPrivileged("unban", req.IP)
	hasSuccess := strings.Contains(output, "✅") || strings.Contains(output, "has been unbanned") || strings.Contains(output, "removed successfully")
	if err != nil && !hasSuccess {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: fmt.Sprintf("Failed to unban IP: %v", err)})
		return
	}

	claims, _ := r.Context().Value(middleware.UserContextKey).(*auth.Claims)
	log.Printf("[AUDIT] User %s unbanned IP: %s", claims.Username, req.IP)

	respondJSON(w, http.StatusOK, SuccessResponse{
		Success: true,
		Message: fmt.Sprintf("IP %s unbanned successfully", req.IP),
	})
}

// WhitelistGetHandler returns whitelisted IPs
func WhitelistGetHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execNFTBanCommand("whitelist", "show", "--json")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to get whitelist"})
		return
	}

	var whitelistData map[string]interface{}
	if err := json.Unmarshal([]byte(output), &whitelistData); err != nil {
		log.Printf("[ERROR] Failed to parse whitelist JSON: %v", err)
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse whitelist data"})
		return
	}

	respondJSON(w, http.StatusOK, whitelistData)
}

// WhitelistAddHandler adds IP to whitelist
func WhitelistAddHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		IP      string `json:"ip"`
		Comment string `json:"comment"`
	}

	if !DecodeJSONBody(w, r, &req) {
		return
	}

	if req.IP == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "IP address is required"})
		return
	}

	args := []string{"whitelist", "add", req.IP}
	if req.Comment != "" {
		args = append(args, "--comment", req.Comment)
	}

	_, err := execNFTBanCommand(args...)
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: fmt.Sprintf("Failed to add to whitelist: %v", err)})
		return
	}

	claims, _ := r.Context().Value(middleware.UserContextKey).(*auth.Claims)
	log.Printf("[AUDIT] User %s added IP to whitelist: %s", claims.Username, req.IP)

	respondJSON(w, http.StatusOK, SuccessResponse{
		Success: true,
		Message: fmt.Sprintf("IP %s added to whitelist", req.IP),
	})
}

// WhitelistRemoveHandler removes IP from whitelist
func WhitelistRemoveHandler(w http.ResponseWriter, r *http.Request) {
	var req struct {
		IP string `json:"ip"`
	}

	if !DecodeJSONBody(w, r, &req) {
		return
	}

	if req.IP == "" {
		respondJSON(w, http.StatusBadRequest, ErrorResponse{Error: "IP address is required"})
		return
	}

	_, err := execNFTBanCommand("whitelist", "remove", req.IP)
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: fmt.Sprintf("Failed to remove from whitelist: %v", err)})
		return
	}

	claims, _ := r.Context().Value(middleware.UserContextKey).(*auth.Claims)
	log.Printf("[AUDIT] User %s removed IP from whitelist: %s", claims.Username, req.IP)

	respondJSON(w, http.StatusOK, SuccessResponse{
		Success: true,
		Message: fmt.Sprintf("IP %s removed from whitelist", req.IP),
	})
}

// WhitelistCountHandler returns the count of whitelisted IPs
func WhitelistCountHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execNFTBanCommand("whitelist", "list", "--json")
	if err != nil {
		respondJSON(w, http.StatusOK, map[string]interface{}{
			"success": true,
			"data": map[string]interface{}{
				"count": 0,
			},
		})
		return
	}

	var result struct {
		Success bool `json:"success"`
		Data    struct {
			IPv4 []string `json:"ipv4"`
			IPv6 []string `json:"ipv6"`
		} `json:"data"`
	}

	count := 0
	if err := json.Unmarshal([]byte(output), &result); err == nil {
		count = len(result.Data.IPv4) + len(result.Data.IPv6)
	}

	respondJSON(w, http.StatusOK, map[string]interface{}{
		"success": true,
		"data": map[string]interface{}{
			"count": count,
		},
	})
}
