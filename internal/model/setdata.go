// =============================================================================
// NFTBan v1.0 - Set Data Model
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="setdata"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Data model for nftables set data representation"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package model

// SetData represents nftables set data for template rendering
// Used by pkg/feeds and pkg/geoban to return IP lists
type SetData struct {
	// IPv4 contains IPv4 addresses and CIDRs
	IPv4 []string `json:"ipv4"`

	// IPv6 contains IPv6 addresses and CIDRs
	IPv6 []string `json:"ipv6"`

	// Count is total number of IPs/CIDRs (IPv4 + IPv6)
	Count int `json:"count"`

	// Source identifies where data came from (e.g., "FIREHOL_ANONYMOUS", "CN")
	Source string `json:"source"`
}

// NewSetData creates empty SetData with given source
func NewSetData(source string) *SetData {
	return &SetData{
		IPv4:   make([]string, 0),
		IPv6:   make([]string, 0),
		Count:  0,
		Source: source,
	}
}

// AddIPv4 adds an IPv4 address or CIDR to the set
func (s *SetData) AddIPv4(ip string) {
	s.IPv4 = append(s.IPv4, ip)
	s.Count++
}

// AddIPv6 adds an IPv6 address or CIDR to the set
func (s *SetData) AddIPv6(ip string) {
	s.IPv6 = append(s.IPv6, ip)
	s.Count++
}

// IsEmpty returns true if set has no IPs
func (s *SetData) IsEmpty() bool {
	return s.Count == 0
}

// FirewallConfig represents complete firewall configuration
// Used by pkg/firewall.Sync() to generate nftables rules
type FirewallConfig struct {
	// Whitelist IPs (permanent, from /etc/nftban/whitelist.conf)
	Whitelist *SetData `json:"whitelist"`

	// Blacklist IPs (permanent, from /etc/nftban/blacklist.conf)
	Blacklist *SetData `json:"blacklist"`

	// Feeds contains all external feed data
	Feeds map[string]*SetData `json:"feeds"`

	// Geoban contains all country-based blocking data
	Geoban *SetData `json:"geoban"`

	// TCPPortsIn contains allowed TCP ports for input direction
	TCPPortsIn []int `json:"tcp_ports_in"`

	// TCPPortsOut contains allowed TCP ports for output direction
	TCPPortsOut []int `json:"tcp_ports_out"`

	// UDPPortsIn contains allowed UDP ports for input direction
	UDPPortsIn []int `json:"udp_ports_in"`

	// UDPPortsOut contains allowed UDP ports for output direction
	UDPPortsOut []int `json:"udp_ports_out"`

	// RuntimeBans contains blacklist_ipv4/ipv6 sets (v2.1: unified blacklist)
	RuntimeBans *SetData `json:"runtime_bans,omitempty"`

	// RuntimeWhitelist contains temporary whitelist entries to preserve
	RuntimeWhitelist *SetData `json:"runtime_whitelist,omitempty"`
}

// NewFirewallConfig creates empty firewall configuration
func NewFirewallConfig() *FirewallConfig {
	return &FirewallConfig{
		Whitelist:   NewSetData("whitelist"),
		Blacklist:   NewSetData("blacklist"),
		Feeds:       make(map[string]*SetData),
		Geoban:      NewSetData("geoban"),
		TCPPortsIn:  make([]int, 0),
		TCPPortsOut: make([]int, 0),
		UDPPortsIn:  make([]int, 0),
		UDPPortsOut: make([]int, 0),
	}
}
