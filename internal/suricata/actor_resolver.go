// =============================================================================
// NFTBan - Suricata L7 Actor IP Resolution
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="actor_resolver"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-28"
// meta:description="Resolves real client IP from trusted proxy chains (XFF handling)"
// meta:input="Source IP, HTTP headers, proxy trust configuration"
// meta:output="Resolved actor IP with trust level"
// meta:depends="net"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package suricata

import (
	"net"
	"strings"
)

// ProxyTrustConfig configures trusted proxy handling for actor IP resolution
type ProxyTrustConfig struct {
	Enabled         bool
	Networks        []*net.IPNet
	RejectPrivateIP bool // Reject private IPs from XFF
}

// ParseProxyNetworks parses CIDR strings into IPNet slice
func ParseProxyNetworks(cidrs []string) ([]*net.IPNet, error) {
	var networks []*net.IPNet
	for _, cidr := range cidrs {
		_, network, err := net.ParseCIDR(cidr)
		if err != nil {
			return nil, err
		}
		networks = append(networks, network)
	}
	return networks, nil
}

// ResolveActorIP determines the real client IP, handling trusted proxies
// Security: XFF is ONLY trusted when source IP is in trusted proxy networks
func ResolveActorIP(srcIP string, http *HTTPDetails, proxyCfg ProxyTrustConfig) (actorIP string, trust ActorTrust) {
	// Safe default: direct source IP
	if !proxyCfg.Enabled || http == nil || http.XFF == "" {
		return srcIP, ActorDirect
	}

	ip := net.ParseIP(srcIP)
	if ip == nil {
		return srcIP, ActorDirect
	}

	// Check if source is a trusted proxy
	trusted := false
	for _, n := range proxyCfg.Networks {
		if n.Contains(ip) {
			trusted = true
			break
		}
	}
	if !trusted {
		// Source is not a trusted proxy, ignore XFF (attacker-controlled)
		return srcIP, ActorProxyUntrusted
	}

	// Strictly take the FIRST IP in XFF list (leftmost = original client)
	// Note: Some setups use rightmost-first, configure accordingly
	first := strings.TrimSpace(strings.Split(http.XFF, ",")[0])
	xffIP := net.ParseIP(first)
	if xffIP == nil {
		// Invalid XFF IP format, fall back to src
		return srcIP, ActorProxyTrusted
	}

	// Optionally reject private IPs in XFF
	if proxyCfg.RejectPrivateIP && isPrivateIP(xffIP) {
		return srcIP, ActorProxyTrusted
	}

	return first, ActorProxyTrusted
}

// isPrivateIP checks if an IP is in private/reserved ranges
func isPrivateIP(ip net.IP) bool {
	privateRanges := []string{
		"10.0.0.0/8",
		"172.16.0.0/12",
		"192.168.0.0/16",
		"127.0.0.0/8",
		"169.254.0.0/16",
		"::1/128",
		"fc00::/7",
		"fe80::/10",
	}
	for _, cidr := range privateRanges {
		_, network, _ := net.ParseCIDR(cidr)
		if network.Contains(ip) {
			return true
		}
	}
	return false
}
