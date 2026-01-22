// =============================================================================
// NFTBan - GOTH GUI Types (Professional Dashboard Blueprint)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="types"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-15"
// meta:description="Data types for GOTH GUI - Professional Admin Dashboard"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package ui

// =============================================================================
// DASHBOARD DATA - Main structure for front page
// =============================================================================

// DashboardData contains all dashboard information for zero-refresh updates
type DashboardData struct {
	// System Identity (Top Left)
	Identity SystemIdentity

	// Security KPIs (Top Right)
	Security SecurityKPIs

	// Hardware Resources
	Resources ResourceStats

	// Module Status Grid
	Modules []ModuleStatus

	// Recent Activity
	RecentBans []RecentBan

	// Theme preference
	Theme string // "dark" or "light"
}

// =============================================================================
// SYSTEM IDENTITY - The Fingerprint (Top Left)
// =============================================================================

// SystemIdentity holds system identification info
type SystemIdentity struct {
	Hostname      string
	Kernel        string
	Uptime        string
	UptimeSeconds int64  // For JS counter
	NFTBanVersion string
	PanelMode     string // "active", "warning", "error"
	Heartbeat     bool   // Backend responding
}

// =============================================================================
// SECURITY KPIs - Real-Time Stats (Top Right)
// =============================================================================

// SecurityKPIs holds security statistics
type SecurityKPIs struct {
	// Active Bans
	BansTotal int
	BansIPv4  int
	BansIPv6  int

	// Whitelist
	WhitelistTotal int
	WhitelistIPv4  int
	WhitelistIPv6  int

	// Network Stats
	NetworkInMbps  float64
	NetworkOutMbps float64
	PacketDropRate int // Packets rejected per second

	// Event counts
	EventsLastHour int
	TotalBansEver  int
}

// =============================================================================
// RESOURCE STATS - Hardware Consumption
// =============================================================================

// ResourceStats holds system resource information
type ResourceStats struct {
	// CPU
	CPUPercent   float64
	CPULoadAvg1  float64
	CPULoadAvg5  float64
	CPULoadAvg15 float64

	// RAM
	RAMUsedGB  float64
	RAMTotalGB float64
	RAMPercent float64

	// Disk (focus on log partition)
	DiskUsedGB  float64
	DiskTotalGB float64
	DiskPercent float64
	DiskPath    string // Which partition we're monitoring

	// NFTBan Process specifically
	NFTBanCPU    float64
	NFTBanMemMB  float64
	NFTBanUptime string
}

// =============================================================================
// MODULE STATUS - The Engine Room
// =============================================================================

// ModuleStatus holds individual module information
type ModuleStatus struct {
	Name        string
	Description string
	Status      string // "active", "inactive", "failed", "warning"
	Enabled     bool
	Running     bool

	// Module-specific metrics
	BansProduced int     // How many IPs this module has added
	CPUPercent   float64 // Module-specific CPU (if separate process)
	MemoryMB     float64 // Module-specific memory
	LastSync     string  // Last time module reported in
	ServiceName  string  // Systemd service name for restart
}

// =============================================================================
// RECENT ACTIVITY
// =============================================================================

// RecentBan represents a recent ban entry
type RecentBan struct {
	IP        string
	Country   string
	CountryCode string
	Reason    string
	Module    string // Which module triggered the ban
	Timestamp string
}

// =============================================================================
// IP CHECK - Quick lookup result
// =============================================================================

// IPCheckResult holds the result of an IP lookup
type IPCheckResult struct {
	IP          string
	Status      string // "banned", "whitelisted", "clean"
	BannedSince string
	Reason      string
	Module      string
	Country     string
}

// =============================================================================
// COUNTRY STATS - For map visualization
// =============================================================================

// CountryStats for geo distribution
type CountryStats struct {
	CountryCode string
	Country     string
	Count       int
	Percent     float64
}

// =============================================================================
// HEALTH PAGE DATA
// =============================================================================

// HealthData holds comprehensive health check results
type HealthData struct {
	Timestamp     string
	OverallStatus string // "ok", "warning", "error"
	ExitCode      int
	ErrorCount    int
	WarningCount  int
	Checks        []HealthCheck
	Errors        []string
	Warnings      []string
}

// HealthCheck represents a single health check category
type HealthCheck struct {
	Name     string
	Status   string // "ok", "warning", "error"
	ExitCode int
	Message  string
}

// HealthItem represents a single health check (legacy)
type HealthItem struct {
	Name   string
	Status string // "ok", "warning", "error"
	Detail string // Additional info
}

// =============================================================================
// NAVIGATION
// =============================================================================

// NavItem represents a navigation menu item
type NavItem struct {
	Name   string
	Path   string
	Icon   string
	Active bool
}

// =============================================================================
// USER SESSION
// =============================================================================

// UserInfo holds current user session info
type UserInfo struct {
	Username string
	Role     string
}

// =============================================================================
// INVENTORY PAGE
// =============================================================================

// InventoryData holds all inventory information
type InventoryData struct {
	Services []ServiceInfo
	Timers   []TimerInfo
	Binaries []BinaryInfo
	Configs  []ConfigInfo
	FHS      []FHSItem
}

// ServiceInfo represents a systemd service
type ServiceInfo struct {
	Name        string
	Description string
	Status      string // "active", "inactive", "failed"
	PID         int
	MemoryMB    float64
	Uptime      string
}

// TimerInfo represents a systemd timer
type TimerInfo struct {
	Name        string
	Description string
	Status      string // "active", "inactive", "enabled"
	NextRun     string
	LastRun     string
}

// BinaryInfo represents an installed binary
type BinaryInfo struct {
	Name    string
	Path    string
	Version string
	Size    string
}

// ConfigInfo represents a configuration file
type ConfigInfo struct {
	Name     string
	Path     string
	Modified string
	Size     string
}

// FHSItem represents a filesystem hierarchy item
type FHSItem struct {
	Path     string
	Expected string
	Actual   string
	Status   string // "ok", "error", "warning"
	Notes    string
}

// =============================================================================
// BANS PAGE DATA
// =============================================================================

// BansData holds all ban list information
type BansData struct {
	// Summary stats
	TotalBans     int
	BansIPv4      int
	BansIPv6      int
	TempBans      int
	PermBans      int
	FeedBans      int
	GeoBans       int

	// Ban list
	Bans []BanEntry

	// Pagination
	Page       int
	PageSize   int
	TotalPages int

	// Filters
	Filter     string // "all", "temp", "perm", "feed", "geo"
	SearchQuery string
}

// BanEntry represents a single banned IP
type BanEntry struct {
	IP          string
	Type        string // "permanent", "temporary", "feed", "geoban"
	Reason      string
	Module      string // login, portscan, ddos, manual, feed
	Country     string
	CountryCode string
	BannedAt    string
	ExpiresAt   string // Empty for permanent
	Source      string // Config file or feed name
}

// =============================================================================
// WHITELIST PAGE DATA
// =============================================================================

// WhitelistData holds all whitelist information
type WhitelistData struct {
	// Summary stats
	TotalEntries int
	IPv4Count    int
	IPv6Count    int
	NetworkCount int // CIDR ranges

	// Whitelist entries
	Entries []WhitelistEntry

	// Sources breakdown
	Sources []WhitelistSource
}

// WhitelistEntry represents a single whitelisted IP/network
type WhitelistEntry struct {
	IP          string
	Type        string // "ip", "network", "range"
	Comment     string
	Source      string // Config file name
	AddedAt     string
	AddedBy     string // "manual", "system", "api"
}

// WhitelistSource represents a whitelist source file
type WhitelistSource struct {
	Name       string
	Path       string
	EntryCount int
	Editable   bool // System files not editable
}

// =============================================================================
// TOOLS PAGE DATA (pfSense-style Diagnostics)
// =============================================================================

// ToolsData holds diagnostic tools data
type ToolsData struct {
	// Last lookup results (if any)
	LastIPCheck   *IPCheckResult
	LastGeoLookup *GeoLookupResult
	LastSearch    *SearchResult

	// Log viewer
	RecentLogs []LogEntry

	// Quick stats for tools context
	TotalBans      int
	TotalWhitelist int
	TotalFeeds     int
}

// GeoLookupResult holds GeoIP lookup results
type GeoLookupResult struct {
	IP          string
	Country     string
	CountryCode string
	City        string
	Region      string
	ASN         string
	ASNOrg      string
	IsBlocked   bool   // Country is geo-blocked
	BlockReason string // Why blocked (if applicable)
}

// SearchResult holds cross-set search results
type SearchResult struct {
	IP           string
	Found        bool
	FoundIn      []SearchMatch
	TotalMatches int
}

// SearchMatch represents where an IP was found
type SearchMatch struct {
	SetName     string // "blacklist_ipv4", "whitelist_ipv4", "feed_spamhaus", etc.
	SetType     string // "blacklist", "whitelist", "feed", "geoban"
	EntryType   string // "exact", "cidr_match", "range"
	MatchedCIDR string // If CIDR match, show the network
	AddedAt     string
	Reason      string
}

// LogEntry represents a log line for the viewer
type LogEntry struct {
	Timestamp string
	Level     string // "INFO", "WARN", "ERROR", "BAN", "UNBAN"
	Module    string
	Message   string
	IP        string // Extracted IP if present
}

// =============================================================================
// MODULES PAGE DATA
// =============================================================================

// ModulesData holds modules page information
type ModulesData struct {
	Modules       []ModuleStatus
	TotalModules  int
	EnabledCount  int
	DisabledCount int
	RunningCount  int
}
