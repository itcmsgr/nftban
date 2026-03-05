// =============================================================================
// NFTBan - Generic IP List Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="iplist_handlers"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-05"
// meta:description="Generic HTTP API handlers for IPv4/IPv6 list operations (blacklist/whitelist)"
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

// handleIPListBatch is a generic handler for batch add/remove operations
// Used by both blacklist and whitelist handlers to eliminate code duplication
func (api *API) handleIPListBatch(w http.ResponseWriter, r *http.Request, set *sync.Set, listName string) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	var req BatchRequest
	if !DecodeJSONBody(w, r, &req) {
		return
	}

	if err := validateIPs(req.Add); err != nil {
		respondError(w, http.StatusBadRequest, "invalid IP in add list: "+err.Error())
		return
	}
	if err := validateIPs(req.Remove); err != nil {
		respondError(w, http.StatusBadRequest, "invalid IP in remove list: "+err.Error())
		return
	}

	diff := util.DiffResult[string]{
		ToAdd:    req.Add,
		ToRemove: req.Remove,
	}

	if err := sync.ApplyStringDiffToSet(api.NFT, set, diff); err != nil {
		respondError(w, http.StatusInternalServerError, "failed to update "+listName+": "+err.Error())
		return
	}

	resp := BatchResponse{
		Added:   len(req.Add),
		Removed: len(req.Remove),
		Success: true,
		Message: listName + " updated successfully",
	}

	respondJSON(w, http.StatusOK, resp)
}

// handleIPListAdd is a generic handler for single IP add
func (api *API) handleIPListAdd(w http.ResponseWriter, r *http.Request, set *sync.Set, listName string) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	var req SingleIPRequest
	if !DecodeJSONBody(w, r, &req) {
		return
	}

	if err := validateIP(req.IP); err != nil {
		respondError(w, http.StatusBadRequest, "invalid IP: "+err.Error())
		return
	}

	diff := util.DiffResult[string]{
		ToAdd: []string{req.IP},
	}

	if err := sync.ApplyStringDiffToSet(api.NFT, set, diff); err != nil {
		respondError(w, http.StatusInternalServerError, "failed to add IP: "+err.Error())
		return
	}

	resp := SingleIPResponse{
		Success: true,
		Message: "IP " + req.IP + " added to " + listName,
	}

	respondJSON(w, http.StatusOK, resp)
}

// handleIPListRemove is a generic handler for single IP remove
func (api *API) handleIPListRemove(w http.ResponseWriter, r *http.Request, set *sync.Set, listName string) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	var req SingleIPRequest
	if !DecodeJSONBody(w, r, &req) {
		return
	}

	if err := validateIP(req.IP); err != nil {
		respondError(w, http.StatusBadRequest, "invalid IP: "+err.Error())
		return
	}

	diff := util.DiffResult[string]{
		ToRemove: []string{req.IP},
	}

	if err := sync.ApplyStringDiffToSet(api.NFT, set, diff); err != nil {
		respondError(w, http.StatusInternalServerError, "failed to remove IP: "+err.Error())
		return
	}

	resp := SingleIPResponse{
		Success: true,
		Message: "IP " + req.IP + " removed from " + listName,
	}

	respondJSON(w, http.StatusOK, resp)
}

// handleIPListPreview is a generic handler for preview (dry-run)
func (api *API) handleIPListPreview(w http.ResponseWriter, r *http.Request, set *sync.Set) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}

	var req PreviewRequest
	if !DecodeJSONBody(w, r, &req) {
		return
	}

	current, err := api.NFT.GetSetElements(set)
	if err != nil {
		respondError(w, http.StatusInternalServerError, "failed to get current state: "+err.Error())
		return
	}

	diff := util.ComputeDiff(req.Desired, current)

	resp := PreviewResponse{
		ToAdd:     diff.ToAdd,
		ToRemove:  diff.ToRemove,
		Unchanged: diff.Unchanged,
	}

	respondJSON(w, http.StatusOK, resp)
}
