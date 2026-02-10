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
	// Extended data from shared check functions
	Extended HealthExtended
}

// HealthExtended holds extended health data from shared check functions
type HealthExtended struct {
	Resources        HealthResources
	Suricata         HealthSuricata
	DNS              HealthDNS
	FirewallConflicts HealthFirewallConflicts
}

// HealthResources holds system resource metrics
type HealthResources struct {
	Load   HealthLoad
	Memory HealthMemory
	Disk   HealthDisk
	Status string // "ok", "warning", "critical"
}

// HealthLoad holds load average data
type HealthLoad struct {
	Load1m  float64 `json:"1m"`
	Load5m  float64 `json:"5m"`
	Load15m float64 `json:"15m"`
	CPUs    int     `json:"cpus"`
}

// HealthMemory holds memory usage data
type HealthMemory struct {
	UsedPercent int `json:"used_percent"`
	TotalMB     int `json:"total_mb"`
}

// HealthDisk holds disk usage data
type HealthDisk struct {
	Path        string `json:"path"`
	UsedPercent int    `json:"used_percent"`
}

// HealthSuricata holds Suricata IDS status
type HealthSuricata struct {
	Installed     bool   `json:"installed"`
	ServiceActive bool   `json:"service_active"`
	EVEExists     bool   `json:"eve_exists"`
	EVEFresh      bool   `json:"eve_fresh"`
	RulesLoaded   int    `json:"rules_loaded"`
	BanningActive bool   `json:"banning_active"`
	Status        string `json:"status"`
}

// HealthDNS holds DNS resolver status
type HealthDNS struct {
	Hostname  string `json:"hostname"`
	Working   bool   `json:"working"`
	Resolver  string `json:"resolver"`
	LatencyMS int    `json:"latency_ms"`
	Status    string `json:"status"`
}

// HealthFirewallConflicts holds conflicting firewall status
type HealthFirewallConflicts struct {
	CSF       HealthFirewall `json:"csf"`
	Firewalld HealthFirewall `json:"firewalld"`
	UFW       HealthFirewall `json:"ufw"`
	IPTables  HealthFirewall `json:"iptables"`
}

// HealthFirewall holds individual firewall conflict status
type HealthFirewall struct {
	Installed     bool   `json:"installed"`
	Enabled       bool   `json:"enabled"`
	Active        bool   `json:"active"`
	ConflictLevel string `json:"conflict_level"` // none, warning, high, critical
	Status        string `json:"status"`
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
// TOOLS PAGE DATA - Diagnostic Tools
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

// =============================================================================
// METRICS PAGE DATA - Unified metrics overview
// =============================================================================

// MetricsData holds all metrics overview information
type MetricsData struct {
	// Collection info
	Timestamp      string
	CollectorState string // "running", "stopped", "stale"
	CachePath      string
	CacheAge       string

	// Summary cards
	Summary MetricsSummary

	// Detailed sections
	Firewall  FirewallMetrics
	Security  SecurityMetrics
	Network   NetworkMetrics
	System    SystemMetrics
	Modules   []ModuleMetrics
	Feeds     []FeedMetrics
	GeoIP     GeoIPMetrics
	Portscan  PortscanMetrics
	DDoS      DDoSMetrics
	Suricata  SuricataMetrics
}

// MetricsSummary holds top-level summary metrics
type MetricsSummary struct {
	TotalBans       int
	BansIPv4        int
	BansIPv6        int
	TotalWhitelist  int
	ActiveFeeds     int
	BlockedCountries int
	EventsLastHour  int
	HealthStatus    string // "ok", "warning", "error"
}

// FirewallMetrics holds nftables/firewall specific metrics
type FirewallMetrics struct {
	TableExists    bool
	RulesTotal     int
	SetsTotal      int
	CountersTotal  int
	ChainCount     int
	NftablesActive bool
}

// SecurityMetrics holds security-related metrics
type SecurityMetrics struct {
	BansTotal       int
	BansTemporary   int
	BansPermanent   int
	BansFeed        int
	BansGeoIP       int
	UnbansToday     int
	WhitelistTotal  int
	ThreatLevel     string // "low", "medium", "high", "critical"
}

// NetworkMetrics holds network traffic metrics
type NetworkMetrics struct {
	RxMbps           float64
	TxMbps           float64
	TotalRxGB        float64
	TotalTxGB        float64
	PacketsDropped   int64
	ConnectionsTotal int
	ConnectionsNew   int
	TopInterface     string
	Interfaces       []InterfaceMetrics
}

// InterfaceMetrics holds per-interface network stats
type InterfaceMetrics struct {
	Name     string
	RxMbps   float64
	TxMbps   float64
	RxBytes  int64
	TxBytes  int64
	Status   string // "up", "down"
}

// SystemMetrics holds system resource metrics
type SystemMetrics struct {
	Hostname      string
	Kernel        string
	Uptime        string
	UptimeSeconds int64
	CPUPercent    float64
	MemPercent    float64
	DiskPercent   float64
	LoadAvg1      float64
	LoadAvg5      float64
	LoadAvg15     float64
	NFTBanVersion string
	NFTBanPID     int
	NFTBanCPU     float64
	NFTBanMemMB   float64
}

// ModuleMetrics holds per-module metrics
type ModuleMetrics struct {
	Name        string
	Status      string // "active", "inactive", "error"
	Enabled     bool
	BansCount   int
	EventsCount int
	LastSync    string
	CPUPercent  float64
	MemoryMB    float64
}

// FeedMetrics holds threat feed metrics
type FeedMetrics struct {
	Name        string
	Status      string // "active", "syncing", "stale", "error"
	IPCount     int
	LastSync    string
	NextSync    string
	SyncErrors  int
}

// GeoIPMetrics holds GeoIP/GeoBan metrics
type GeoIPMetrics struct {
	Enabled          bool
	DatabaseVersion  string
	DatabaseAge      string
	BlockedCountries int
	BlockedRanges    int
	CountryStats     []CountryMetrics
}

// CountryMetrics holds per-country ban statistics
type CountryMetrics struct {
	Code      string
	Name      string
	BanCount  int
	RangeCount int
	Percent   float64
}

// PortscanMetrics holds portscan detection metrics
type PortscanMetrics struct {
	Enabled      bool
	TotalBlocks  int
	BlocksToday  int
	TopPorts     []PortMetrics
}

// PortMetrics holds per-port scan statistics
type PortMetrics struct {
	Port       int
	Protocol   string
	ScanCount  int
}

// DDoSMetrics holds DDoS protection metrics
type DDoSMetrics struct {
	Enabled       bool
	TotalBlocks   int
	BlocksToday   int
	ActiveMitigations int
}

// SuricataMetrics holds Suricata IDS metrics
type SuricataMetrics struct {
	Enabled       bool
	Status        string
	AlertsTotal   int
	AlertsToday   int
	RulesLoaded   int
	TopAlerts     []AlertMetrics
}

// AlertMetrics holds alert statistics
type AlertMetrics struct {
	SID       string
	Signature string
	Count     int
	Severity  string
}

// =============================================================================
// FEEDS PAGE DATA - Threat feeds management
// =============================================================================

// FeedsPageData holds feeds page information
type FeedsPageData struct {
	// Summary stats
	TotalFeeds   int
	ActiveFeeds  int
	StaleFeeds   int
	ErrorFeeds   int
	TotalIPs     int
	LastCheck    string

	// Feed list
	Feeds        []FeedEntry

	// Top feeds by IP count (for chart)
	TopFeeds     []FeedChartEntry

	// Recent sync activity
	RecentActivity []FeedSyncActivity
}

// FeedEntry represents a single threat feed
type FeedEntry struct {
	Name        string
	Description string
	URL         string
	Status      string // "active", "syncing", "stale", "error", "disabled"
	Enabled     bool
	IPCount     int
	LastSync    string
	NextSync    string
	SyncErrors  int
	LastError   string
}

// FeedChartEntry represents a feed for chart display
type FeedChartEntry struct {
	Name    string
	IPCount int
	Percent float64
}

// FeedSyncActivity represents a recent sync event
type FeedSyncActivity struct {
	FeedName   string
	Status     string // "success", "error", "syncing"
	IPsAdded   int
	IPsRemoved int
	Timestamp  string
	Error      string
}

// =============================================================================
// GEOIP PAGE DATA - Detailed GeoIP/GeoBan view
// =============================================================================

// GeoIPPageData holds GeoIP page information
type GeoIPPageData struct {
	// Database info
	DatabasePath     string
	DatabaseVersion  string
	DatabaseDate     string
	DatabaseSize     string
	LastUpdate       string
	NextUpdate       string
	UpdateEnabled    bool

	// Blocking config
	BlockingEnabled  bool
	BlockingMode     string // "whitelist" or "blacklist"

	// Statistics
	TotalCountries   int
	BlockedCountries int
	AllowedCountries int
	TotalRanges      int
	TotalIPs         int64

	// Country list
	Countries        []GeoCountryEntry

	// Recent blocks
	RecentBlocks     []GeoBlockEntry
}

// GeoCountryEntry represents a country in the GeoIP list
type GeoCountryEntry struct {
	Code         string
	Name         string
	Blocked      bool
	RangeCount   int
	IPCount      int64
	BansFromHere int
	LastBan      string
}

// GeoBlockEntry represents a recent geo-block event
type GeoBlockEntry struct {
	IP          string
	Country     string
	CountryCode string
	Timestamp   string
	Reason      string
}

// =============================================================================
// SYSTEM PAGE DATA - System overview
// =============================================================================

// SystemPageData holds system page information
type SystemPageData struct {
	// Identity
	Hostname     string
	OS           string
	Kernel       string
	Arch         string
	Uptime       string
	UptimeSeconds int64
	BootTime     string

	// NFTBan info
	NFTBanVersion string
	NFTBanBuild   string
	NFTBanCommit  string
	NFTBanUptime  string
	NFTBanPID     int
	NFTBanCPU     float64
	NFTBanMemMB   float64

	// Resources
	CPU          CPUInfo
	Memory       MemoryInfo
	Disk         DiskInfo

	// Services
	Services     []SystemService

	// Processes
	TopProcesses []ProcessInfo
}

// CPUInfo holds CPU information
type CPUInfo struct {
	Model      string
	Cores      int
	Threads    int
	Frequency  string
	UsagePercent float64
	LoadAvg1   float64
	LoadAvg5   float64
	LoadAvg15  float64
}

// MemoryInfo holds memory information
type MemoryInfo struct {
	TotalGB     float64
	UsedGB      float64
	FreeGB      float64
	AvailableGB float64
	Percent     float64
	SwapTotalGB float64
	SwapUsedGB  float64
	SwapPercent float64
}

// DiskInfo holds disk information
type DiskInfo struct {
	Path        string
	TotalGB     float64
	UsedGB      float64
	FreeGB      float64
	Percent     float64
	FSType      string
	InodesUsed  int64
	InodesTotal int64
}

// SystemService represents a system service status
type SystemService struct {
	Name        string
	Description string
	Status      string // "active", "inactive", "failed"
	PID         int
	MemoryMB    float64
	Uptime      string
	Restarts    int
}

// ProcessInfo holds process information
type ProcessInfo struct {
	PID        int
	Name       string
	User       string
	CPUPercent float64
	MemPercent float64
	MemMB      float64
	Status     string
}

// =============================================================================
// NETWORK PAGE DATA - Network monitoring
// =============================================================================

// NetworkPageData holds network page information
type NetworkPageData struct {
	// Summary
	TotalRxMbps    float64
	TotalTxMbps    float64
	TotalRxToday   string
	TotalTxToday   string
	ActiveConns    int
	DroppedPackets int64

	// Interfaces
	Interfaces     []NetworkInterface

	// Connections
	TopConnections []ConnectionInfo

	// Traffic history (for graphs)
	TrafficHistory []TrafficSample

	// Dropped traffic
	DroppedByCountry []CountryTraffic
	DroppedByPort    []PortTraffic
}

// NetworkInterface holds interface information
type NetworkInterface struct {
	Name        string
	Status      string // "up", "down"
	IPAddress   string
	MACAddress  string
	MTU         int
	RxMbps      float64
	TxMbps      float64
	RxBytes     int64
	TxBytes     int64
	RxPackets   int64
	TxPackets   int64
	RxErrors    int64
	TxErrors    int64
	Dropped     int64
}

// ConnectionInfo holds connection information
type ConnectionInfo struct {
	Protocol   string // "tcp", "udp"
	LocalAddr  string
	RemoteAddr string
	State      string
	PID        int
	Process    string
}

// TrafficSample holds a traffic history point
type TrafficSample struct {
	Timestamp string
	RxMbps    float64
	TxMbps    float64
}

// CountryTraffic holds traffic by country
type CountryTraffic struct {
	Code       string
	Name       string
	Packets    int64
	Bytes      int64
	Blocked    int64
}

// PortTraffic holds traffic by port
type PortTraffic struct {
	Port      int
	Protocol  string
	Packets   int64
	Bytes     int64
	Blocked   int64
}

// =============================================================================
// SETTINGS PAGE DATA - Configuration settings
// =============================================================================

// SettingsData holds settings page information
type SettingsData struct {
	System        SystemSettings
	Security      SecuritySettings
	Notifications NotificationSettings
	Modules       ModuleSettings
}

// SystemSettings holds system configuration
type SystemSettings struct {
	Timezone         string
	LogLevel         string
	LogRetentionDays int
}

// SecuritySettings holds security configuration
type SecuritySettings struct {
	DefaultBanDurationHours int
	PermBanThreshold        int
	WhitelistEnabled        bool
	AutoWhitelistPrivate    bool
}

// NotificationSettings holds notification configuration
type NotificationSettings struct {
	EmailEnabled   bool
	EmailAddress   string
	WebhookEnabled bool
	WebhookURL     string
	NotifyOnBan    bool
	NotifyOnHealth bool
}

// ModuleSettings holds module toggle configuration
type ModuleSettings struct {
	PortscanEnabled bool
	DDoSEnabled     bool
	LoginEnabled    bool
	FeedsEnabled    bool
	GeobanEnabled   bool
}

// =============================================================================
// EXTENDED SETTINGS DATA - For comprehensive settings management
// =============================================================================

// ExtendedSettingsData holds comprehensive settings page information
type ExtendedSettingsData struct {
	// General settings
	General GeneralSettingsData

	// Feature toggles
	Features FeatureSettingsData

	// Metrics settings
	Metrics MetricsSettingsData

	// GeoIP settings
	GeoIP GeoIPSettingsData

	// Suricata settings
	Suricata SuricataSettingsData

	// Logging settings
	Logging LoggingSettingsData

	// GUI/API settings
	Network NetworkSettingsData

	// Paths (read-only display)
	Paths PathSettingsData

	// Config metadata
	ConfigPath    string
	ConfigVersion string
	LastModified  string
	CanWrite      bool

	// Status messages
	SaveSuccess bool
	SaveError   string
}

// GeneralSettingsData holds general NFTBan settings
type GeneralSettingsData struct {
	Version       string
	ConfigVersion string
}

// FeatureSettingsData holds feature toggle settings
type FeatureSettingsData struct {
	MetricsEnabled      bool
	GeoIPEnabled        bool
	FeedsEnabled        bool
	FeedsAutoUpdate     bool
	SuricataEnabled     bool
	GUIEnabled          bool
	PortscanEnabled     bool
	DDoSEnabled         bool
	LoginMonitorEnabled bool
	GrafanaEnabled      bool
}

// MetricsSettingsData holds metrics-related settings
type MetricsSettingsData struct {
	Enabled          bool
	Backend          string // "prometheus", "victoriametrics", etc.
	SamplingInterval int    // seconds
	MaxSamples       int
	PrometheusDir    string
	PrometheusAddr   string
	NodeExporterAddr string
	VictoriaAddr     string
}

// GeoIPSettingsData holds GeoIP/GeoBan settings
type GeoIPSettingsData struct {
	Enabled    bool
	LicenseKey string // Masked for display
	HasKey     bool   // Whether a license key is configured
}

// SuricataSettingsData holds Suricata IDS settings
type SuricataSettingsData struct {
	Enabled             bool
	EveLog              string
	LogDir              string
	BanThreshold        int
	ScoreDecay          int
	CloudflareWhitelist bool
}

// LoggingSettingsData holds logging configuration
type LoggingSettingsData struct {
	LogLevel      string
	ColorOutput   bool
	DebugTrace    bool
	DebugTraceLog string
}

// NetworkSettingsData holds GUI/API network settings
type NetworkSettingsData struct {
	GUIAddr string
	APIAddr string
}

// PathSettingsData holds path configuration (read-only)
type PathSettingsData struct {
	Bin       string
	CoreBin   string
	UIBin     string
	LibDir    string
	ConfigDir string
	DataDir   string
	LogDir    string
	CacheDir  string
	RunDir    string
}

// =============================================================================
// EVENTS PAGE DATA - Security events and activity log
// =============================================================================

// EventsData holds events page information
type EventsData struct {
	// Summary stats
	TotalEvents    int
	EventsLastHour int
	EventsToday    int
	BanEvents      int
	UnbanEvents    int
	WarningEvents  int
	ErrorEvents    int

	// Event list
	Events []EventEntry

	// Pagination
	Page       int
	PageSize   int
	TotalPages int

	// Filters
	Filter      string // "all", "bans", "unbans", "warnings", "errors"
	SearchQuery string
	DateFrom    string
	DateTo      string
}

// EventEntry represents a single security event
type EventEntry struct {
	ID          string
	Timestamp   string
	Level       string // "INFO", "WARN", "ERROR", "BAN", "UNBAN"
	Module      string // login, portscan, ddos, geoban, feed, etc.
	Action      string // "ban", "unban", "detect", "block", "warning", "error"
	IP          string
	Country     string
	CountryCode string
	Message     string
	Details     string
}
