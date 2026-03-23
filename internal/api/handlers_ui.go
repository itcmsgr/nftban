// =============================================================================
// NFTBan - UI API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="handlers_ui"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-30"
// meta:description="UI whitelist and banned IPs management API handlers"
// meta:input="HTTP requests for UI whitelist operations"
// meta:output="JSON responses with whitelist data"
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

	"github.com/itcmsgr/nftban/internal/auth"
	"github.com/itcmsgr/nftban/internal/logutil"
	"github.com/itcmsgr/nftban/internal/middleware"
)

// UIListBannedIPsHandler returns all banned IPs from nftables sets
func UIListBannedIPsHandler(w http.ResponseWriter, r *http.Request) {
	// Use nftban list command with JSON output (architectural compliance)
	output, err := execNFTBanCommand("list", "banned", "--json")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to get banned IPs"})
		return
	}

	// Parse JSON output from nftban list command
	var result map[string]interface{}
	if err := json.Unmarshal([]byte(output), &result); err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to parse banned IPs"})
		return
	}

	// Return the result as-is (already in correct format)
	respondJSON(w, http.StatusOK, result)
}

// UIWhitelistGetHandler returns IPs whitelisted for GUI access
func UIWhitelistGetHandler(w http.ResponseWriter, r *http.Request) {
	output, err := execNFTBanCommand("ui", "list-ips")
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to get UI whitelist"})
		return
	}

	whitelist := map[string]interface{}{
		"ips": parseUIWhitelistOutput(output),
	}

	respondJSON(w, http.StatusOK, whitelist)
}

// UIWhitelistAddHandler adds IP to GUI whitelist
func UIWhitelistAddHandler(w http.ResponseWriter, r *http.Request) {
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

	_, err := execNFTBanCommand("ui", "add-ip", req.IP)
	if err != nil {
		respondJSON(w, http.StatusInternalServerError, ErrorResponse{Error: "Failed to add to UI whitelist: " + sanitizeError(err)})
		return
	}

	// Audit log
	claims, _ := r.Context().Value(middleware.UserContextKey).(*auth.Claims)
	log.Printf("[AUDIT] User %s added IP to UI whitelist: %s", logutil.Sanitize(claims.Username), logutil.Sanitize(req.IP))

	respondJSON(w, http.StatusOK, SuccessResponse{
		Success: true,
		Message: fmt.Sprintf("IP %s added to UI whitelist", req.IP),
	})
}

// parseUIWhitelistOutput parses the output from nftban ui list-ips command
func parseUIWhitelistOutput(output string) []string {
	return parseWhitelistOutput(output)
}
