// =============================================================================
// NFTBan - Suricata Ban Handler
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="ban_handler"
// meta:type="package"
// meta:version="1.1.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Implements ban operations via IPC to nftband daemon"
// meta:input="IP addresses to ban, ban duration"
// meta:output="IPC requests to nftband daemon"
// meta:depends="github.com/itcmsgr/nftban/pkg/ipc,github.com/itcmsgr/nftban/pkg/analytics,github.com/itcmsgr/nftban/pkg/banlog,github.com/itcmsgr/nftban/pkg/geoip"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network="unix:/run/nftban/nftband.sock"
// meta:inventory.privileges=""
// =============================================================================

package suricata

import (
	"fmt"
	"net"
	"time"

	"github.com/itcmsgr/nftban/pkg/analytics"
	"github.com/itcmsgr/nftban/pkg/banlog"
	"github.com/itcmsgr/nftban/pkg/geoip"
	"github.com/itcmsgr/nftban/pkg/ipc"
)

// IPCBanHandler implements BanHandler using IPC to the nftband daemon
// This is the correct architecture: suricata module sends ban requests via IPC,
// and the daemon handles the actual netlink operations.
type IPCBanHandler struct {
	client *ipc.Client
}

// NewIPCBanHandler creates a new ban handler that uses IPC to communicate with nftband
func NewIPCBanHandler() (*IPCBanHandler, error) {
	client := ipc.NewClient()

	// Verify daemon is reachable
	if err := client.Ping(); err != nil {
		return nil, fmt.Errorf("nftband daemon not reachable: %w", err)
	}

	return &IPCBanHandler{
		client: client,
	}, nil
}

// NewIPCBanHandlerWithSocket creates a ban handler with a custom socket path (for testing)
func NewIPCBanHandlerWithSocket(socketPath string) (*IPCBanHandler, error) {
	client := ipc.NewClientWithSocket(socketPath)

	// Verify daemon is reachable
	if err := client.Ping(); err != nil {
		return nil, fmt.Errorf("nftband daemon not reachable at %s: %w", socketPath, err)
	}

	return &IPCBanHandler{
		client: client,
	}, nil
}

// BanIP bans an IP by sending a request to the nftband daemon via IPC
func (h *IPCBanHandler) BanIP(ip string, duration time.Duration, reason string) error {
	// Validate IP
	parsedIP := net.ParseIP(ip)
	if parsedIP == nil {
		return fmt.Errorf("invalid IP address: %s", ip)
	}

	// Convert duration to seconds for IPC
	// 0 duration means permanent ban
	timeoutSecs := int(duration.Seconds())

	// Send ban request to daemon via IPC
	// The daemon handles all netlink operations
	resp, err := h.client.Ban(ip, timeoutSecs, reason, "suricata")
	if err != nil {
		return fmt.Errorf("IPC ban request failed: %w", err)
	}
	if !resp.Success {
		return fmt.Errorf("daemon rejected ban request: %s", resp.Error)
	}

	// GeoIP enrichment and logging happens AFTER ban is complete (async)
	// This keeps the hot path fast - IP is already blocked by daemon
	go func(ip, reason string) {
		// Record analytics (if initialized)
		// Analytics extracts service dynamically from reason parameter
		country, city := lookupGeoIP(ip)
		if st := analytics.StateOrNil(); st != nil {
			st.RecordBan(ip, country, city, "suricata", reason, time.Now())
		}

		// Log to central bans.log for stats dashboard
		if country == "" {
			country = "UNK"
		}
		_ = banlog.LogBan(ip, banlog.SourceSuricata, country)
	}(ip, reason)

	return nil
}

// lookupGeoIP performs GeoIP lookup for an IP address
// Returns country code and city name
func lookupGeoIP(ip string) (country string, city string) {
	return geoip.LookupIP(ip)
}

// Close closes the ban handler (IPC client has no cleanup needed)
func (h *IPCBanHandler) Close() {
	// IPC client doesn't require explicit cleanup
	// Each request opens a new connection that is closed after response
}

// =============================================================================
// Legacy NetlinkBanHandler - DEPRECATED
// =============================================================================
// The NetlinkBanHandler is kept for backward compatibility but should not be
// used in new code. It violates the architecture by accessing netlink directly
// instead of going through the nftband daemon via IPC.
//
// Use NewIPCBanHandler() instead of NewNetlinkBanHandler()
// =============================================================================

// NewNetlinkBanHandler is DEPRECATED - use NewIPCBanHandler instead
// This function now returns an IPCBanHandler for backward compatibility
func NewNetlinkBanHandler() (*IPCBanHandler, error) {
	return NewIPCBanHandler()
}
