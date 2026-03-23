// =============================================================================
// NFTBan - Whitelist IPv4 API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="whitelist_ipv4"
// meta:type="package"
// meta:version="1.1.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="HTTP API handlers for IPv4 whitelist batch operations"
// meta:input="HTTP requests with IP addresses"
// meta:output="JSON responses with operation results"
// meta:depends="github.com/itcmsgr/nftban/internal/setsync,github.com/itcmsgr/nftban/internal/util"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
// v1.1.0: Refactored to use generic handlers (iplist_handlers.go)
// =============================================================================

package api

import (
	"net/http"
)

// HandleWhitelistIPv4Batch handles batch add/remove for whitelist IPv4
// POST /api/whitelist/ipv4/batch
// Body: { "add": ["1.2.3.4", "5.6.7.8"], "remove": ["9.9.9.9"] }
func (api *API) HandleWhitelistIPv4Batch(w http.ResponseWriter, r *http.Request) {
	api.handleIPListBatch(w, r, api.WhitelistIPv4Set, "Whitelist IPv4")
}

// HandleWhitelistIPv4Add handles single IP add
// POST /api/whitelist/ipv4/add
// Body: { "ip": "1.2.3.4" }
func (api *API) HandleWhitelistIPv4Add(w http.ResponseWriter, r *http.Request) {
	api.handleIPListAdd(w, r, api.WhitelistIPv4Set, "whitelist")
}

// HandleWhitelistIPv4Remove handles single IP remove
// POST /api/whitelist/ipv4/remove
// Body: { "ip": "1.2.3.4" }
func (api *API) HandleWhitelistIPv4Remove(w http.ResponseWriter, r *http.Request) {
	api.handleIPListRemove(w, r, api.WhitelistIPv4Set, "whitelist")
}

// HandleWhitelistIPv4Preview shows what would change (dry-run)
// POST /api/whitelist/ipv4/preview
// Body: { "desired": ["1.2.3.4", "5.6.7.8"] }
func (api *API) HandleWhitelistIPv4Preview(w http.ResponseWriter, r *http.Request) {
	api.handleIPListPreview(w, r, api.WhitelistIPv4Set)
}
