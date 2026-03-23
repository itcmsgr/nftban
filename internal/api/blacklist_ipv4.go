// =============================================================================
// NFTBan - Blacklist IPv4 API Handlers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="blacklist_ipv4"
// meta:type="package"
// meta:version="1.1.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="HTTP API handlers for IPv4 blacklist batch operations"
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

// HandleBlacklistIPv4Batch handles batch add/remove for blacklist IPv4
// POST /api/blacklist/ipv4/batch
// Body: { "add": ["1.2.3.4", "5.6.7.8"], "remove": ["9.9.9.9"] }
func (api *API) HandleBlacklistIPv4Batch(w http.ResponseWriter, r *http.Request) {
	api.handleIPListBatch(w, r, api.BlacklistIPv4Set, "Blacklist IPv4")
}

// HandleBlacklistIPv4Add handles single IP add
// POST /api/blacklist/ipv4/add
// Body: { "ip": "1.2.3.4" }
func (api *API) HandleBlacklistIPv4Add(w http.ResponseWriter, r *http.Request) {
	api.handleIPListAdd(w, r, api.BlacklistIPv4Set, "blacklist")
}

// HandleBlacklistIPv4Remove handles single IP remove
// POST /api/blacklist/ipv4/remove
// Body: { "ip": "1.2.3.4" }
func (api *API) HandleBlacklistIPv4Remove(w http.ResponseWriter, r *http.Request) {
	api.handleIPListRemove(w, r, api.BlacklistIPv4Set, "blacklist")
}

// HandleBlacklistIPv4Preview shows what would change (dry-run)
// POST /api/blacklist/ipv4/preview
// Body: { "desired": ["1.2.3.4", "5.6.7.8"] }
func (api *API) HandleBlacklistIPv4Preview(w http.ResponseWriter, r *http.Request) {
	api.handleIPListPreview(w, r, api.BlacklistIPv4Set)
}
