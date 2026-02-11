// =============================================================================
// NFTBan - Blacklist IPv4 API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="blacklist_ipv4"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="HTTP API handlers for IPv4 blacklist batch operations"
// meta:input="HTTP requests with IP addresses"
// meta:output="JSON responses with operation results"
// meta:depends="github.com/itcmsgr/nftban/pkg/sync,github.com/itcmsgr/nftban/pkg/util"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package api

import (
	"net/http"

	"github.com/itcmsgr/nftban/pkg/sync"
	"github.com/itcmsgr/nftban/pkg/util"
)

// HandleBlacklistIPv4Batch handles batch add/remove for blacklist IPv4
// POST /api/blacklist/ipv4/batch
// Body: { "add": ["1.2.3.4", "5.6.7.8"], "remove": ["9.9.9.9"] }
func (api *API) HandleBlacklistIPv4Batch(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	var req BatchRequest
	if !DecodeJSONBody(w, r, &req) {
		return
	}

	// Validate IPs
	if err := validateIPs(req.Add); err != nil {
		respondError(w, http.StatusBadRequest, "invalid IP in add list: "+err.Error())
		return
	}
	if err := validateIPs(req.Remove); err != nil {
		respondError(w, http.StatusBadRequest, "invalid IP in remove list: "+err.Error())
		return
	}

	// Create diff
	diff := util.DiffResult[string]{
		ToAdd:    req.Add,
		ToRemove: req.Remove,
	}

	// Apply changes
	if err := sync.ApplyStringDiffToSet(api.NFT, api.BlacklistIPv4Set, diff); err != nil {
		respondError(w, http.StatusInternalServerError, "failed to update blacklist: "+err.Error())
		return
	}

	// Success response
	resp := BatchResponse{
		Added:   len(req.Add),
		Removed: len(req.Remove),
		Success: true,
		Message: "Blacklist IPv4 updated successfully",
	}

	respondJSON(w, http.StatusOK, resp)
}

// HandleBlacklistIPv4Add handles single IP add
// POST /api/blacklist/ipv4/add
// Body: { "ip": "1.2.3.4" }
func (api *API) HandleBlacklistIPv4Add(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	var req SingleIPRequest
	if !DecodeJSONBody(w, r, &req) {
		return
	}

	// Validate IP
	if err := validateIP(req.IP); err != nil {
		respondError(w, http.StatusBadRequest, "invalid IP: "+err.Error())
		return
	}

	// Create diff with single add
	diff := util.DiffResult[string]{
		ToAdd: []string{req.IP},
	}

	// Apply change
	if err := sync.ApplyStringDiffToSet(api.NFT, api.BlacklistIPv4Set, diff); err != nil {
		respondError(w, http.StatusInternalServerError, "failed to add IP: "+err.Error())
		return
	}

	resp := SingleIPResponse{
		Success: true,
		Message: "IP " + req.IP + " added to blacklist",
	}

	respondJSON(w, http.StatusOK, resp)
}

// HandleBlacklistIPv4Remove handles single IP remove
// POST /api/blacklist/ipv4/remove
// Body: { "ip": "1.2.3.4" }
func (api *API) HandleBlacklistIPv4Remove(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	var req SingleIPRequest
	if !DecodeJSONBody(w, r, &req) {
		return
	}

	// Validate IP
	if err := validateIP(req.IP); err != nil {
		respondError(w, http.StatusBadRequest, "invalid IP: "+err.Error())
		return
	}

	// Create diff with single remove
	diff := util.DiffResult[string]{
		ToRemove: []string{req.IP},
	}

	// Apply change
	if err := sync.ApplyStringDiffToSet(api.NFT, api.BlacklistIPv4Set, diff); err != nil {
		respondError(w, http.StatusInternalServerError, "failed to remove IP: "+err.Error())
		return
	}

	resp := SingleIPResponse{
		Success: true,
		Message: "IP " + req.IP + " removed from blacklist",
	}

	respondJSON(w, http.StatusOK, resp)
}

// HandleBlacklistIPv4Preview shows what would change (dry-run)
// POST /api/blacklist/ipv4/preview
// Body: { "desired": ["1.2.3.4", "5.6.7.8"] }
func (api *API) HandleBlacklistIPv4Preview(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	var req PreviewRequest
	if !DecodeJSONBody(w, r, &req) {
		return
	}

	// Get current state
	current, err := api.NFT.GetSetElements(api.BlacklistIPv4Set)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "failed to get current state: "+err.Error())
		return
	}

	// Compute diff
	diff := util.ComputeDiff(req.Desired, current)

	// Return preview
	resp := PreviewResponse{
		ToAdd:     diff.ToAdd,
		ToRemove:  diff.ToRemove,
		Unchanged: diff.Unchanged,
	}

	respondJSON(w, http.StatusOK, resp)
}
