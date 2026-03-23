// =============================================================================
// NFTBan - API Endpoints Registry
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="endpoints"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Centralized API endpoint definitions for frontend/backend consistency"
// meta:input="None"
// meta:output="Endpoint paths and metadata"
// meta:depends="None"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package nftbanconf

// =============================================================================
// API Endpoints Registry
// =============================================================================
// Purpose: Centralized API endpoint definitions for:
// - Consistent path references across frontend/backend
// - Documentation generation
// - Route registration helpers
// - OpenAPI schema generation (future)
//
// This file defines all API endpoints as constants, ensuring frontend
// and backend use the same paths and reducing maintenance burden.
// =============================================================================

// API Version prefix
const (
	APIVersion    = "v1"
	APIPathPrefix = "/api/" + APIVersion
)

// =============================================================================
// Public Endpoints (No Authentication)
// =============================================================================

const (
	// EndpointLogin handles user authentication
	EndpointLogin = "/login"
)

// =============================================================================
// Core Endpoints (Protected)
// =============================================================================

const (
	// EndpointMe returns current user information
	EndpointMe = "/me"

	// EndpointDashboard returns dashboard statistics
	EndpointDashboard = "/dashboard"

	// EndpointStatus returns current firewall status
	EndpointStatus = "/status"

	// EndpointHealth returns system health check
	EndpointHealth = "/health"

	// EndpointHealthFix attempts to fix health issues
	EndpointHealthFix = "/health/fix"
)

// =============================================================================
// IP Management Endpoints
// =============================================================================

const (
	// EndpointBan bans an IP address
	EndpointBan = "/ban"

	// EndpointUnban removes an IP from ban list
	EndpointUnban = "/unban"

	// EndpointSearch searches for an IP across all lists
	EndpointSearch = "/search"
)

// =============================================================================
// Whitelist Endpoints
// =============================================================================

const (
	// EndpointWhitelist - GET for list, POST for add
	EndpointWhitelist = "/whitelist"

	// EndpointWhitelistAdd explicitly adds to whitelist
	EndpointWhitelistAdd = "/whitelist/add"

	// EndpointWhitelistRemove removes from whitelist
	EndpointWhitelistRemove = "/whitelist/remove"

	// EndpointWhitelistCount returns whitelist entry count
	EndpointWhitelistCount = "/whitelist/count"
)

// =============================================================================
// UI-Specific Endpoints
// =============================================================================

const (
	// EndpointUIWhitelist - UI-formatted whitelist
	EndpointUIWhitelist = "/ui/whitelist"

	// EndpointUIListIPs - UI-formatted banned IPs list
	EndpointUIListIPs = "/ui/list-ips"
)

// =============================================================================
// Threat Feeds Endpoints
// =============================================================================

const (
	// EndpointFeeds returns threat feed list and status
	EndpointFeeds = "/feeds"

	// EndpointFeedsControl enables/disables feeds
	EndpointFeedsControl = "/feeds/control"

	// EndpointFeedsStats returns feed statistics
	EndpointFeedsStats = "/feeds/stats"

	// EndpointSyncFeeds triggers feed synchronization
	EndpointSyncFeeds = "/sync-feeds"
)

// =============================================================================
// Log Endpoints
// =============================================================================

const (
	// EndpointLogs returns log file list
	EndpointLogs = "/logs"

	// EndpointLogsViewer returns log file contents
	EndpointLogsViewer = "/logs/viewer"
)

// =============================================================================
// Firewall Endpoints
// =============================================================================

const (
	// EndpointRules returns nftables rules
	EndpointRules = "/rules"

	// EndpointReload reloads firewall rules
	EndpointReload = "/reload"

	// EndpointFlush flushes all dynamic rules
	EndpointFlush = "/flush"

	// EndpointFirewallValidate validates nftables config
	EndpointFirewallValidate = "/firewall/validate"

	// EndpointFirewallCheck checks an IP against rules
	EndpointFirewallCheck = "/firewall/check"
)

// =============================================================================
// GeoIP Endpoints
// =============================================================================

const (
	// EndpointGeo returns geo-blocking status
	EndpointGeo = "/geo"
)

// =============================================================================
// Metrics Endpoints
// =============================================================================

const (
	// EndpointMetricsEnable enables/disables metrics collection
	EndpointMetricsEnable = "/metrics/enable"

	// EndpointMetricsStatus returns metrics collection status
	EndpointMetricsStatus = "/metrics/status"

	// EndpointMetricsSnapshot returns current metrics snapshot
	EndpointMetricsSnapshot = "/metrics/snapshot"
)

// =============================================================================
// Statistics Endpoints
// =============================================================================

const (
	// EndpointStatsTraffic returns traffic statistics
	EndpointStatsTraffic = "/stats/traffic"

	// EndpointStatsBans returns ban statistics
	EndpointStatsBans = "/stats/bans"

	// EndpointStatsCountries returns country-based statistics
	EndpointStatsCountries = "/stats/countries"
)

// =============================================================================
// Network Endpoints
// =============================================================================

const (
	// EndpointNetworkBandwidth returns bandwidth usage
	EndpointNetworkBandwidth = "/network/bandwidth"

	// EndpointNetworkConnections returns active connections
	EndpointNetworkConnections = "/network/connections"

	// EndpointNetworkMetricsSamples returns metrics samples
	EndpointNetworkMetricsSamples = "/network/metrics/samples"
)

// =============================================================================
// Bandwidth Endpoints
// =============================================================================

const (
	// EndpointBandwidthCurrent returns current bandwidth
	EndpointBandwidthCurrent = "/bandwidth/current"

	// EndpointBandwidthHistory returns bandwidth history
	EndpointBandwidthHistory = "/bandwidth/history"

	// EndpointBandwidthInterfaces returns interface stats
	EndpointBandwidthInterfaces = "/bandwidth/interfaces"

	// EndpointBandwidthConnections returns connection stats
	EndpointBandwidthConnections = "/bandwidth/connections"
)

// =============================================================================
// System Endpoints
// =============================================================================

const (
	// EndpointSystemHostname returns system hostname
	EndpointSystemHostname = "/system/hostname"
)

// =============================================================================
// Endpoint Metadata (for documentation/OpenAPI)
// =============================================================================

// EndpointInfo describes an API endpoint
type EndpointInfo struct {
	Path        string   // URL path (relative to API prefix)
	Methods     []string // HTTP methods supported
	Description string   // Human-readable description
	Auth        bool     // Requires authentication
	Admin       bool     // Requires admin privileges
	Deprecated  bool     // Marked for deprecation
}

// AllEndpoints returns metadata for all API endpoints
// Useful for documentation generation and OpenAPI specs
func AllEndpoints() []EndpointInfo {
	return []EndpointInfo{
		// Public
		{Path: EndpointLogin, Methods: []string{"POST"}, Description: "Authenticate user", Auth: false},

		// Core
		{Path: EndpointMe, Methods: []string{"GET"}, Description: "Current user info", Auth: true},
		{Path: EndpointDashboard, Methods: []string{"GET"}, Description: "Dashboard statistics", Auth: true},
		{Path: EndpointStatus, Methods: []string{"GET"}, Description: "Firewall status", Auth: true},
		{Path: EndpointHealth, Methods: []string{"GET"}, Description: "System health check", Auth: true},
		{Path: EndpointHealthFix, Methods: []string{"POST"}, Description: "Fix health issues", Auth: true, Admin: true},

		// IP Management
		{Path: EndpointBan, Methods: []string{"POST"}, Description: "Ban an IP", Auth: true, Admin: true},
		{Path: EndpointUnban, Methods: []string{"POST"}, Description: "Unban an IP", Auth: true, Admin: true},
		{Path: EndpointSearch, Methods: []string{"GET"}, Description: "Search IP", Auth: true},

		// Whitelist
		{Path: EndpointWhitelist, Methods: []string{"GET", "POST"}, Description: "Whitelist management", Auth: true},
		{Path: EndpointWhitelistAdd, Methods: []string{"POST"}, Description: "Add to whitelist", Auth: true, Admin: true},
		{Path: EndpointWhitelistRemove, Methods: []string{"POST"}, Description: "Remove from whitelist", Auth: true, Admin: true},
		{Path: EndpointWhitelistCount, Methods: []string{"GET"}, Description: "Whitelist count", Auth: true},

		// UI
		{Path: EndpointUIWhitelist, Methods: []string{"GET", "POST"}, Description: "UI whitelist view", Auth: true},
		{Path: EndpointUIListIPs, Methods: []string{"GET"}, Description: "UI banned IPs list", Auth: true},

		// Feeds
		{Path: EndpointFeeds, Methods: []string{"GET"}, Description: "Threat feeds list", Auth: true},
		{Path: EndpointFeedsControl, Methods: []string{"POST"}, Description: "Enable/disable feeds", Auth: true, Admin: true},
		{Path: EndpointFeedsStats, Methods: []string{"GET"}, Description: "Feed statistics", Auth: true},
		{Path: EndpointSyncFeeds, Methods: []string{"POST"}, Description: "Sync threat feeds", Auth: true, Admin: true},

		// Logs
		{Path: EndpointLogs, Methods: []string{"GET"}, Description: "Log file list", Auth: true},
		{Path: EndpointLogsViewer, Methods: []string{"GET"}, Description: "View log contents", Auth: true},

		// Firewall
		{Path: EndpointRules, Methods: []string{"GET"}, Description: "NFTables rules", Auth: true},
		{Path: EndpointReload, Methods: []string{"POST"}, Description: "Reload firewall", Auth: true, Admin: true},
		{Path: EndpointFlush, Methods: []string{"POST"}, Description: "Flush dynamic rules", Auth: true, Admin: true},
		{Path: EndpointFirewallValidate, Methods: []string{"GET"}, Description: "Validate config", Auth: true},
		{Path: EndpointFirewallCheck, Methods: []string{"POST"}, Description: "Check IP against rules", Auth: true},

		// Geo
		{Path: EndpointGeo, Methods: []string{"GET"}, Description: "Geo-blocking status", Auth: true},

		// Metrics
		{Path: EndpointMetricsEnable, Methods: []string{"POST"}, Description: "Enable metrics", Auth: true, Admin: true},
		{Path: EndpointMetricsStatus, Methods: []string{"GET"}, Description: "Metrics status", Auth: true},
		{Path: EndpointMetricsSnapshot, Methods: []string{"GET"}, Description: "Metrics snapshot", Auth: true},

		// Stats
		{Path: EndpointStatsTraffic, Methods: []string{"GET"}, Description: "Traffic stats", Auth: true},
		{Path: EndpointStatsBans, Methods: []string{"GET"}, Description: "Ban stats", Auth: true},
		{Path: EndpointStatsCountries, Methods: []string{"GET"}, Description: "Country stats", Auth: true},

		// Network
		{Path: EndpointNetworkBandwidth, Methods: []string{"GET"}, Description: "Bandwidth usage", Auth: true},
		{Path: EndpointNetworkConnections, Methods: []string{"GET"}, Description: "Active connections", Auth: true},
		{Path: EndpointNetworkMetricsSamples, Methods: []string{"GET"}, Description: "Network metrics samples", Auth: true},

		// Bandwidth
		{Path: EndpointBandwidthCurrent, Methods: []string{"GET"}, Description: "Current bandwidth", Auth: true},
		{Path: EndpointBandwidthHistory, Methods: []string{"GET"}, Description: "Bandwidth history", Auth: true},
		{Path: EndpointBandwidthInterfaces, Methods: []string{"GET"}, Description: "Interface stats", Auth: true},
		{Path: EndpointBandwidthConnections, Methods: []string{"GET"}, Description: "Connection stats", Auth: true},

		// System
		{Path: EndpointSystemHostname, Methods: []string{"GET"}, Description: "System hostname", Auth: true},
	}
}

// GetAdminEndpoints returns endpoints that require admin privileges
func GetAdminEndpoints() []string {
	var adminPaths []string
	for _, ep := range AllEndpoints() {
		if ep.Admin {
			adminPaths = append(adminPaths, ep.Path)
		}
	}
	return adminPaths
}

// GetPublicEndpoints returns endpoints that don't require authentication
func GetPublicEndpoints() []string {
	var publicPaths []string
	for _, ep := range AllEndpoints() {
		if !ep.Auth {
			publicPaths = append(publicPaths, ep.Path)
		}
	}
	return publicPaths
}

// IsAdminEndpoint checks if a path requires admin privileges
func IsAdminEndpoint(path string) bool {
	for _, ep := range AllEndpoints() {
		if ep.Path == path {
			return ep.Admin
		}
	}
	return false
}

// FullPath returns the full API path including version prefix
func FullPath(endpoint string) string {
	return APIPathPrefix + endpoint
}
