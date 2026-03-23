// =============================================================================
// NFTBan v1.0 - Zabbix Exporter Types
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="types"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-22"
// meta:description="Type definitions for Zabbix trapper protocol and metrics"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package zabbix

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/itcmsgr/nftban/internal/constants"
)

// =============================================================================
// Protocol Constants
// =============================================================================

const (
	// ProtocolHeader is the Zabbix protocol header (ZBXD\x01)
	ProtocolHeader = "ZBXD\x01"

	// ProtocolVersion for Zabbix 5.x+ trapper
	ProtocolVersion = 1

	// DefaultPort is the default Zabbix server port
	DefaultPort = 10051

	// MaxPayloadSize is the maximum payload size (64MB)
	MaxPayloadSize = 64 * 1024 * 1024

	// DefaultTimeout for connections
	DefaultTimeout = constants.ZabbixSendTimeout

	// DefaultInterval between metric pushes
	DefaultInterval = constants.ZabbixCollectInterval

	// DefaultBatchSize for metric batching
	DefaultBatchSize = 100
)

// =============================================================================
// Trapper Protocol Types
// =============================================================================

// TrapperRequest represents a Zabbix trapper sender request
type TrapperRequest struct {
	Request string       `json:"request"`
	Data    []TrapperItem `json:"data"`
	Clock   int64        `json:"clock,omitempty"`
	Ns      int          `json:"ns,omitempty"`
}

// TrapperItem represents a single metric item in the trapper request
type TrapperItem struct {
	Host  string `json:"host"`
	Key   string `json:"key"`
	Value string `json:"value"`
	Clock int64  `json:"clock,omitempty"`
	Ns    int    `json:"ns,omitempty"`
}

// TrapperResponse represents the Zabbix server response
type TrapperResponse struct {
	Response string `json:"response"`
	Info     string `json:"info"`
}

// IsSuccess returns true if the response indicates success
func (r *TrapperResponse) IsSuccess() bool {
	return r.Response == "success"
}

// ParseInfo parses the info string for processed/failed counts
// Format: "processed: X; failed: Y; total: Z; seconds spent: W"
type TrapperInfo struct {
	Processed int
	Failed    int
	Total     int
	Seconds   float64
}

// ParseInfo extracts counts from the info string
func (r *TrapperResponse) ParseInfo() TrapperInfo {
	var info TrapperInfo
	// Simple parsing - production code should be more robust
	_ = json.Unmarshal([]byte(`{}`), &info) // placeholder
	return info
}

// =============================================================================
// Metric Types
// =============================================================================

// MetricType represents the type of metric
type MetricType string

const (
	MetricTypeGauge     MetricType = "gauge"
	MetricTypeCounter   MetricType = "counter"
	MetricTypeText      MetricType = "text"
	MetricTypeDiscovery MetricType = "discovery"
)

// Metric represents a single metric to be sent
type Metric struct {
	Name        string      `json:"name"`
	Value       interface{} `json:"value"`
	Type        MetricType  `json:"type"`
	Timestamp   time.Time   `json:"timestamp,omitempty"`
	Labels      Labels      `json:"labels,omitempty"`
	Description string      `json:"description,omitempty"`
	Unit        string      `json:"unit,omitempty"`
}

// Labels holds metric labels/dimensions
type Labels map[string]string

// StringValue returns the value as a string for Zabbix
func (m *Metric) StringValue() string {
	switch v := m.Value.(type) {
	case string:
		return v
	case int:
		return fmt.Sprintf("%d", v)
	case int32:
		return fmt.Sprintf("%d", v)
	case int64:
		return fmt.Sprintf("%d", v)
	case uint:
		return fmt.Sprintf("%d", v)
	case uint32:
		return fmt.Sprintf("%d", v)
	case uint64:
		return fmt.Sprintf("%d", v)
	case float32:
		return fmt.Sprintf("%g", v)
	case float64:
		return fmt.Sprintf("%g", v)
	case bool:
		if v {
			return "1"
		}
		return "0"
	default:
		b, _ := json.Marshal(v)
		return string(b)
	}
}

// =============================================================================
// Metrics Snapshot (matches HTTP endpoint response)
// =============================================================================

// MetricsSnapshot represents all metrics at a point in time
type MetricsSnapshot struct {
	Timestamp time.Time       `json:"timestamp"`
	Daemon    DaemonMetrics   `json:"daemon"`
	Runtime   RuntimeMetrics  `json:"runtime"`
	Bans      BanMetrics      `json:"bans"`
	Events    EventMetrics    `json:"events"`
	IPC       IPCMetrics      `json:"ipc"`
	Modules   ModuleMetrics   `json:"modules"`
	Watchdog  WatchdogMetrics `json:"watchdog"`
	NFTables  NFTablesMetrics `json:"nftables"`
	Feeds     FeedMetrics     `json:"feeds"`
	GeoIP     GeoIPMetrics    `json:"geoip"`
	Suricata  SuricataMetrics `json:"suricata"`
	API       APIMetrics      `json:"api"`
	Server    ServerMetrics   `json:"server"`
	Discovery DiscoveryData   `json:"discovery"`
	Filter    FilterMetrics   `json:"filter"`
}

// FilterMetrics contains CIDR filter statistics
type FilterMetrics struct {
	Total     int `json:"total"`      // Total CIDRs processed in last sync
	Filtered  int `json:"filtered"`   // CIDRs removed by filtering
	Bogon     int `json:"bogon"`      // Bogon/reserved CIDRs removed
	Oversize  int `json:"oversize"`   // Oversized CIDRs removed (< /9)
	Kept      int `json:"kept"`       // CIDRs that passed filtering
}

// DaemonMetrics contains daemon identification and status
type DaemonMetrics struct {
	Version          string `json:"version"`
	BuildDate        string `json:"build_date"`
	Uptime           int64  `json:"uptime"`
	PID              int    `json:"pid"`
	Status           int    `json:"status"`           // 1=running, 0=stopped
	ConfigReloadTime int64  `json:"config_reload_time"`
	Mode             string `json:"mode"`             // normal, degraded, survival
}

// RuntimeMetrics contains Go runtime information
type RuntimeMetrics struct {
	MemoryHeap      uint64  `json:"memory_heap"`
	MemoryAlloc     uint64  `json:"memory_alloc"`
	MemorySys       uint64  `json:"memory_sys"`
	MemoryRSS       uint64  `json:"memory_rss"`
	Goroutines      int     `json:"goroutines"`
	GCCycles        uint32  `json:"gc_cycles"`
	GCPauseTotal    uint64  `json:"gc_pause_total"`
	GCPauseLast     uint64  `json:"gc_pause_last"`
	GCCPUFraction   float64 `json:"gc_cpu_fraction"`
	OpenFDs         int     `json:"open_fds"`
	Threads         int     `json:"threads"`
}

// BanMetrics contains ban statistics
type BanMetrics struct {
	Total           int64   `json:"total"`
	Last24h         int64   `json:"last_24h"`
	Last1h          int64   `json:"last_1h"`
	Rate            float64 `json:"rate"`           // per minute
	UnbansTotal     int64   `json:"unbans_total"`
	Unbans24h       int64   `json:"unbans_24h"`
	ActiveCount     int64   `json:"active_count"`
	PermanentCount  int64   `json:"permanent_count"`
	PersistentCount int64   `json:"persistent_count"`
}

// EventMetrics contains event processing statistics
type EventMetrics struct {
	Total      int64   `json:"total"`
	Rate       float64 `json:"rate"`         // per second
	Dropped    int64   `json:"dropped"`
	QueueDepth int     `json:"queue_depth"`
}

// IPCMetrics contains IPC communication statistics
type IPCMetrics struct {
	Requests          int64   `json:"requests"`
	Errors            int64   `json:"errors"`
	LatencyAvg        float64 `json:"latency_avg"`        // ms
	ActiveConnections int     `json:"active_connections"`
}

// ModuleMetrics contains module status information
type ModuleMetrics struct {
	Enabled int                  `json:"enabled"`
	Active  int                  `json:"active"`
	Failed  int                  `json:"failed"`
	Status  map[string]ModuleStatus `json:"status"` // per-module status
}

// ModuleStatus represents individual module status
type ModuleStatus struct {
	Status  int     `json:"status"`  // 1=ok, 0=error, -1=disabled
	Events  int64   `json:"events"`
	Bans    int64   `json:"bans"`
	Errors  int64   `json:"errors"`
	Latency float64 `json:"latency"` // ms
}

// WatchdogMetrics contains watchdog status
type WatchdogMetrics struct {
	Status       int     `json:"status"`        // 1=ok, 0=disabled, -1=error
	Mode         string  `json:"mode"`          // normal, degraded, survival
	CPUScore     float64 `json:"cpu_score"`     // 0-100
	MemScore     float64 `json:"mem_score"`     // 0-100
	IOScore      float64 `json:"io_score"`      // 0-100
	NetScore     float64 `json:"net_score"`     // 0-100
	ActionsTaken int64   `json:"actions_taken"`
	LastAction   string  `json:"last_action"`
	ModeChanges  int64   `json:"mode_changes"`
}

// NFTablesMetrics contains nftables statistics
type NFTablesMetrics struct {
	RulesTotal    int     `json:"rules_total"`
	SetsTotal     int     `json:"sets_total"`
	ElementsTotal int64   `json:"elements_total"`
	ApplyLatency  float64 `json:"apply_latency"` // ms
	ApplyErrors   int64   `json:"apply_errors"`
}

// FeedMetrics contains threat feed statistics
type FeedMetrics struct {
	Enabled    int   `json:"enabled"`
	Loaded     int   `json:"loaded"`
	Failed     int   `json:"failed"`
	IPsTotal   int64 `json:"ips_total"`
	LastUpdate int64 `json:"last_update"` // unix timestamp
}

// GeoIPMetrics contains GeoIP database statistics
type GeoIPMetrics struct {
	DatabaseAge      int   `json:"database_age"`       // days
	LookupsTotal     int64 `json:"lookups_total"`
	LookupErrors     int64 `json:"lookup_errors"`
	CountriesBlocked int   `json:"countries_blocked"`
}

// SuricataMetrics contains Suricata integration statistics
type SuricataMetrics struct {
	Enabled          int     `json:"enabled"`
	AlertsProcessed  int64   `json:"alerts_processed"`
	AlertsRate       float64 `json:"alerts_rate"`        // per minute
	BansGenerated    int64   `json:"bans_generated"`
	ConnectionStatus int     `json:"connection_status"` // 1=connected, 0=disconnected
}

// APIMetrics contains API statistics
type APIMetrics struct {
	RequestsTotal int64   `json:"requests_total"`
	RequestsRate  float64 `json:"requests_rate"` // per minute
	ErrorsTotal   int64   `json:"errors_total"`
	LatencyAvg    float64 `json:"latency_avg"`   // ms
	AuthFailures  int64   `json:"auth_failures"`
}

// ServerMetrics contains server information
type ServerMetrics struct {
	Hostname string  `json:"hostname"`
	OS       string  `json:"os"`
	Kernel   string  `json:"kernel"`
	Arch     string  `json:"arch"`
	CPUCores int     `json:"cpu_cores"`
	Load1m   float64 `json:"load_1m"`
	Load5m   float64 `json:"load_5m"`
	Load15m  float64 `json:"load_15m"`
}

// =============================================================================
// Discovery Data (LLD)
// =============================================================================

// DiscoveryData contains all discovery information for LLD
type DiscoveryData struct {
	Modules    []DiscoveredModule    `json:"modules"`
	Interfaces []DiscoveredInterface `json:"interfaces"`
	Countries  []DiscoveredCountry   `json:"countries"`
	Feeds      []DiscoveredFeed      `json:"feeds"`
	Timers     []DiscoveredTimer     `json:"timers"`
}

// DiscoveredModule represents a discovered module for LLD
type DiscoveredModule struct {
	Module  string `json:"{#MODULE}"`
	Mode    string `json:"{#MODE}"`
	Enabled int    `json:"{#ENABLED}"`
}

// DiscoveredInterface represents a discovered interface for LLD
type DiscoveredInterface struct {
	Interface string `json:"{#IFACE}"`
	Zone      string `json:"{#ZONE}"`
}

// DiscoveredCountry represents a discovered country for LLD
type DiscoveredCountry struct {
	Country     string `json:"{#COUNTRY}"`
	CountryName string `json:"{#COUNTRY_NAME}"`
	Blocked     int    `json:"{#BLOCKED}"`
}

// DiscoveredFeed represents a discovered feed for LLD
type DiscoveredFeed struct {
	Feed    string `json:"{#FEED}"`
	URL     string `json:"{#URL}"`
	Enabled int    `json:"{#ENABLED}"`
}

// DiscoveredTimer represents a discovered timer for LLD
type DiscoveredTimer struct {
	Timer    string `json:"{#TIMER}"`
	Duration string `json:"{#DURATION}"`
}

// =============================================================================
// Target Configuration
// =============================================================================

// Target represents a Zabbix server target
type Target struct {
	Name     string        `json:"name"`
	Address  string        `json:"address"`
	Port     int           `json:"port"`
	Hostname string        `json:"hostname"` // host as registered in Zabbix
	TLS      *TLSConfig    `json:"tls,omitempty"`
	Timeout  time.Duration `json:"timeout"`
	Enabled  bool          `json:"enabled"`
}

// TLSConfig holds TLS configuration for a target
type TLSConfig struct {
	Enabled    bool   `json:"enabled"`
	CertFile   string `json:"cert_file,omitempty"`
	KeyFile    string `json:"key_file,omitempty"`
	CAFile     string `json:"ca_file,omitempty"`
	SkipVerify bool   `json:"skip_verify"` // Only honored when DevMode is true
	DevMode    bool   `json:"dev_mode"`    // Development mode - allows SkipVerify
}

// =============================================================================
// Status Types
// =============================================================================

// SenderStatus represents the status of a sender
type SenderStatus struct {
	Target       string    `json:"target"`
	Connected    bool      `json:"connected"`
	LastSend     time.Time `json:"last_send"`
	LastError    string    `json:"last_error,omitempty"`
	SendCount    int64     `json:"send_count"`
	ErrorCount   int64     `json:"error_count"`
	MetricsSent  int64     `json:"metrics_sent"`
	BytesSent    int64     `json:"bytes_sent"`
	AvgLatencyMs float64   `json:"avg_latency_ms"`
}

// ExporterStatus represents the overall exporter status
type ExporterStatus struct {
	Enabled      bool           `json:"enabled"`
	Running      bool           `json:"running"`
	StartTime    time.Time      `json:"start_time"`
	Targets      []SenderStatus `json:"targets"`
	TotalSent    int64          `json:"total_sent"`
	TotalErrors  int64          `json:"total_errors"`
}

// =============================================================================
// Error Types
// =============================================================================

// SendError represents an error during metric sending
type SendError struct {
	Target  string
	Message string
	Cause   error
}

func (e *SendError) Error() string {
	if e.Cause != nil {
		return e.Target + ": " + e.Message + ": " + e.Cause.Error()
	}
	return e.Target + ": " + e.Message
}

func (e *SendError) Unwrap() error {
	return e.Cause
}

// =============================================================================
// Batch Types
// =============================================================================

// Batch represents a batch of metrics to send
type Batch struct {
	Metrics   []Metric
	Host      string
	Timestamp time.Time
}

// Size returns the number of metrics in the batch
func (b *Batch) Size() int {
	return len(b.Metrics)
}

// ToTrapperRequest converts the batch to a trapper request
func (b *Batch) ToTrapperRequest() *TrapperRequest {
	items := make([]TrapperItem, len(b.Metrics))
	clock := b.Timestamp.Unix()
	ns := b.Timestamp.Nanosecond()

	for i, m := range b.Metrics {
		items[i] = TrapperItem{
			Host:  b.Host,
			Key:   m.Name,
			Value: m.StringValue(),
			Clock: clock,
			Ns:    ns,
		}
	}

	return &TrapperRequest{
		Request: "sender data",
		Data:    items,
		Clock:   clock,
		Ns:      ns,
	}
}
