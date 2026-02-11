// =============================================================================
// NFTBan - Suricata Ban Handler
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="ban_handler"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Implements ban operations using netlink infrastructure"
// meta:input="IP addresses to ban, ban duration"
// meta:output="NFTables set modifications"
// meta:depends="github.com/google/nftables,github.com/itcmsgr/nftban/pkg/sync"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package suricata

import (
	"fmt"
	"net"
	"time"

	"github.com/google/nftables"
	"github.com/itcmsgr/nftban/pkg/analytics"
	"github.com/itcmsgr/nftban/pkg/banlog"
	"github.com/itcmsgr/nftban/pkg/geoip"
	"github.com/itcmsgr/nftban/pkg/sync"
)

// NetlinkBanHandler implements BanHandler using the existing netlink infrastructure
// This matches the existing fail2ban approach - uses sync.NFTManager for banning
type NetlinkBanHandler struct {
	nftManager *sync.NFTManager
}

// NewNetlinkBanHandler creates a new ban handler using the existing netlink infrastructure
func NewNetlinkBanHandler() (*NetlinkBanHandler, error) {
	nftManager, err := sync.NewNFTManager()
	if err != nil {
		return nil, fmt.Errorf("failed to create NFT manager: %w", err)
	}

	return &NetlinkBanHandler{
		nftManager: nftManager,
	}, nil
}

// BanIP bans an IP using the existing netlink/nftables infrastructure
// This is the same mechanism used by fail2ban integration
func (h *NetlinkBanHandler) BanIP(ip string, duration time.Duration, reason string) error {
	// Validate IP
	parsedIP := net.ParseIP(ip)
	if parsedIP == nil {
		return fmt.Errorf("invalid IP address: %s", ip)
	}

	// Determine if IPv4 or IPv6
	isIPv4 := parsedIP.To4() != nil

	// Get or create appropriate table
	var family nftables.TableFamily
	var setName string

	if isIPv4 {
		family = nftables.TableFamilyIPv4
		setName = "blacklist_ipv4"
	} else {
		family = nftables.TableFamilyIPv6
		setName = "blacklist_ipv6"
	}

	// Get table
	table, err := h.nftManager.GetOrCreateTable(family)
	if err != nil {
		return fmt.Errorf("failed to get nftables table: %w", err)
	}

	// Get set
	set, err := h.nftManager.GetOrCreateSet(table, setName, isIPv4)
	if err != nil {
		return fmt.Errorf("failed to get blacklist set: %w", err)
	}

	// Add IP with timeout using existing netlink infrastructure
	// This is the same AddIPWithTimeout used by cmdBan
	// Ban happens FIRST - this is the critical path
	if err := h.nftManager.AddIPWithTimeout(set, ip, duration); err != nil {
		return fmt.Errorf("failed to add IP to nftables: %w", err)
	}

	// GeoIP enrichment happens AFTER ban is complete (async)
	// This keeps the hot path fast - IP is already blocked
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

// Close closes the ban handler and cleans up resources
func (h *NetlinkBanHandler) Close() {
	if h.nftManager != nil {
		h.nftManager.Close()
	}
}
