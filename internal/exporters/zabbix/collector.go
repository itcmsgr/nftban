// =============================================================================
// NFTBan v1.0 - Zabbix Metrics Collector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="collector"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-22"
// meta:description="Collects metrics from the nftban daemon for Zabbix export"
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
	"os"
	"runtime"
	"sync"
	"time"
)

// =============================================================================
// Collector Interface
// =============================================================================

// MetricsSource provides metrics from the daemon
type MetricsSource interface {
	// GetDaemonInfo returns daemon identification info
	GetDaemonInfo() DaemonInfo

	// GetRuntimeMetrics returns Go runtime metrics
	GetRuntimeMetrics() RuntimeInfo

	// GetBanStats returns ban statistics
	GetBanStats() BanStats

	// GetEventStats returns event processing statistics
	GetEventStats() EventStats

	// GetIPCStats returns IPC communication statistics
	GetIPCStats() IPCStats

	// GetModuleStatus returns status for all modules
	GetModuleStatus() map[string]ModuleInfo

	// GetWatchdogStatus returns watchdog status
	GetWatchdogStatus() WatchdogInfo

	// GetNFTablesStats returns nftables statistics
	GetNFTablesStats() NFTablesInfo

	// GetFeedStats returns threat feed statistics
	GetFeedStats() FeedStats

	// GetGeoIPStats returns GeoIP statistics
	GetGeoIPStats() GeoIPStats

	// GetSuricataStats returns Suricata integration statistics
	GetSuricataStats() SuricataInfo

	// GetAPIStats returns API statistics
	GetAPIStats() APIStats

	// GetDiscoveryData returns discovery data for LLD
	GetDiscoveryData() DiscoveryInfo
}

// Source info types (input from daemon)
type (
	DaemonInfo struct {
		Version          string
		BuildDate        string
		StartTime        time.Time
		PID              int
		ConfigReloadTime time.Time
		Mode             string
	}

	RuntimeInfo struct {
		HeapAlloc     uint64
		TotalAlloc    uint64
		Sys           uint64
		Goroutines    int
		NumGC         uint32
		GCPauseTotal  uint64
		GCPauseLast   uint64
		GCCPUFraction float64
		OpenFDs       int
		Threads       int
	}

	BanStats struct {
		Total           int64
		Last24h         int64
		Last1h          int64
		RatePerMinute   float64
		UnbansTotal     int64
		Unbans24h       int64
		ActiveCount     int64
		PermanentCount  int64
		PersistentCount int64
	}

	EventStats struct {
		Total      int64
		RatePerSec float64
		Dropped    int64
		QueueDepth int
	}

	IPCStats struct {
		Requests          int64
		Errors            int64
		LatencyAvgMs      float64
		ActiveConnections int
	}

	ModuleInfo struct {
		Name    string
		Mode    string
		Enabled bool
		Status  int // 1=ok, 0=error, -1=disabled
		Events  int64
		Bans    int64
		Errors  int64
		Latency float64
	}

	WatchdogInfo struct {
		Status       int // 1=ok, 0=disabled, -1=error
		Mode         string
		CPUScore     float64
		MemScore     float64
		IOScore      float64
		NetScore     float64
		ActionsTaken int64
		LastAction   string
		ModeChanges  int64
	}

	NFTablesInfo struct {
		RulesTotal    int
		SetsTotal     int
		ElementsTotal int64
		ApplyLatency  float64
		ApplyErrors   int64
	}

	FeedStats struct {
		Enabled    int
		Loaded     int
		Failed     int
		IPsTotal   int64
		LastUpdate time.Time
	}

	GeoIPStats struct {
		DatabaseAge      int
		LookupsTotal     int64
		LookupErrors     int64
		CountriesBlocked int
	}

	SuricataInfo struct {
		Enabled          bool
		AlertsProcessed  int64
		AlertsRate       float64
		BansGenerated    int64
		ConnectionStatus int
	}

	APIStats struct {
		RequestsTotal int64
		RequestsRate  float64
		ErrorsTotal   int64
		LatencyAvgMs  float64
		AuthFailures  int64
	}

	DiscoveryInfo struct {
		Modules    []ModuleDiscovery
		Interfaces []InterfaceDiscovery
		Countries  []CountryDiscovery
		Feeds      []FeedDiscovery
		Timers     []TimerDiscovery
	}

	ModuleDiscovery struct {
		Name    string
		Mode    string
		Enabled bool
	}

	InterfaceDiscovery struct {
		Name string
		Zone string
	}

	CountryDiscovery struct {
		Code    string
		Name    string
		Blocked bool
	}

	FeedDiscovery struct {
		Name    string
		URL     string
		Enabled bool
	}

	TimerDiscovery struct {
		Name     string
		Duration string
	}
)

// =============================================================================
// Collector
// =============================================================================

// Collector collects metrics from the daemon
type Collector struct {
	source MetricsSource
	mu     sync.RWMutex

	// Cached snapshot
	lastSnapshot *MetricsSnapshot
	lastCollect  time.Time

	// Server info (static)
	serverInfo ServerMetrics
}

// NewCollector creates a new metrics collector
func NewCollector(source MetricsSource) *Collector {
	c := &Collector{
		source: source,
	}
	c.initServerInfo()
	return c
}

// initServerInfo initializes static server information
func (c *Collector) initServerInfo() {
	hostname, _ := os.Hostname()

	c.serverInfo = ServerMetrics{
		Hostname: hostname,
		OS:       runtime.GOOS,
		Arch:     runtime.GOARCH,
		CPUCores: runtime.NumCPU(),
	}

	// Get kernel version on Linux
	if runtime.GOOS == "linux" {
		if data, err := os.ReadFile("/proc/sys/kernel/osrelease"); err == nil {
			c.serverInfo.Kernel = string(data)
		}
	}
}

// Collect gathers all metrics and returns a snapshot
func (c *Collector) Collect() *MetricsSnapshot {
	c.mu.Lock()
	defer c.mu.Unlock()

	snapshot := &MetricsSnapshot{
		Timestamp: time.Now(),
		Server:    c.serverInfo,
	}

	if c.source == nil {
		return snapshot
	}

	// Collect daemon info
	daemon := c.source.GetDaemonInfo()
	snapshot.Daemon = DaemonMetrics{
		Version:          daemon.Version,
		BuildDate:        daemon.BuildDate,
		Uptime:           int64(time.Since(daemon.StartTime).Seconds()),
		PID:              daemon.PID,
		Status:           1, // Running
		ConfigReloadTime: daemon.ConfigReloadTime.Unix(),
		Mode:             daemon.Mode,
	}

	// Collect runtime metrics
	rt := c.source.GetRuntimeMetrics()
	snapshot.Runtime = RuntimeMetrics{
		MemoryHeap:    rt.HeapAlloc,
		MemoryAlloc:   rt.TotalAlloc,
		MemorySys:     rt.Sys,
		Goroutines:    rt.Goroutines,
		GCCycles:      rt.NumGC,
		GCPauseTotal:  rt.GCPauseTotal,
		GCPauseLast:   rt.GCPauseLast,
		GCCPUFraction: rt.GCCPUFraction,
		OpenFDs:       rt.OpenFDs,
		Threads:       rt.Threads,
	}

	// Collect ban stats
	bans := c.source.GetBanStats()
	snapshot.Bans = BanMetrics{
		Total:           bans.Total,
		Last24h:         bans.Last24h,
		Last1h:          bans.Last1h,
		Rate:            bans.RatePerMinute,
		UnbansTotal:     bans.UnbansTotal,
		Unbans24h:       bans.Unbans24h,
		ActiveCount:     bans.ActiveCount,
		PermanentCount:  bans.PermanentCount,
		PersistentCount: bans.PersistentCount,
	}

	// Collect event stats
	events := c.source.GetEventStats()
	snapshot.Events = EventMetrics{
		Total:      events.Total,
		Rate:       events.RatePerSec,
		Dropped:    events.Dropped,
		QueueDepth: events.QueueDepth,
	}

	// Collect IPC stats
	ipc := c.source.GetIPCStats()
	snapshot.IPC = IPCMetrics{
		Requests:          ipc.Requests,
		Errors:            ipc.Errors,
		LatencyAvg:        ipc.LatencyAvgMs,
		ActiveConnections: ipc.ActiveConnections,
	}

	// Collect module status
	modules := c.source.GetModuleStatus()
	snapshot.Modules = ModuleMetrics{
		Status: make(map[string]ModuleStatus),
	}
	for name, m := range modules {
		snapshot.Modules.Status[name] = ModuleStatus{
			Status:  m.Status,
			Events:  m.Events,
			Bans:    m.Bans,
			Errors:  m.Errors,
			Latency: m.Latency,
		}
		if m.Enabled {
			snapshot.Modules.Enabled++
			if m.Status == 1 {
				snapshot.Modules.Active++
			} else if m.Status == 0 {
				snapshot.Modules.Failed++
			}
		}
	}

	// Collect watchdog status
	wd := c.source.GetWatchdogStatus()
	snapshot.Watchdog = WatchdogMetrics(wd)

	// Collect nftables stats
	nft := c.source.GetNFTablesStats()
	snapshot.NFTables = NFTablesMetrics(nft)

	// Collect feed stats
	feeds := c.source.GetFeedStats()
	snapshot.Feeds = FeedMetrics{
		Enabled:    feeds.Enabled,
		Loaded:     feeds.Loaded,
		Failed:     feeds.Failed,
		IPsTotal:   feeds.IPsTotal,
		LastUpdate: feeds.LastUpdate.Unix(),
	}

	// Collect GeoIP stats
	geoip := c.source.GetGeoIPStats()
	snapshot.GeoIP = GeoIPMetrics(geoip)

	// Collect Suricata stats
	suricata := c.source.GetSuricataStats()
	snapshot.Suricata = SuricataMetrics{
		Enabled:          boolToInt(suricata.Enabled),
		AlertsProcessed:  suricata.AlertsProcessed,
		AlertsRate:       suricata.AlertsRate,
		BansGenerated:    suricata.BansGenerated,
		ConnectionStatus: suricata.ConnectionStatus,
	}

	// Collect API stats
	api := c.source.GetAPIStats()
	snapshot.API = APIMetrics{
		RequestsTotal: api.RequestsTotal,
		RequestsRate:  api.RequestsRate,
		ErrorsTotal:   api.ErrorsTotal,
		LatencyAvg:    api.LatencyAvgMs,
		AuthFailures:  api.AuthFailures,
	}

	// Collect discovery data
	disc := c.source.GetDiscoveryData()
	snapshot.Discovery = c.convertDiscoveryData(disc)

	// Collect CIDR filter metrics from state file
	snapshot.Filter = c.collectFilterMetrics()

	// Update load averages
	c.updateLoadAverages(&snapshot.Server)

	// Cache snapshot
	c.lastSnapshot = snapshot
	c.lastCollect = time.Now()

	return snapshot
}

// collectFilterMetrics reads CIDR filter state from file
func (c *Collector) collectFilterMetrics() FilterMetrics {
	data, err := os.ReadFile("/var/lib/nftban/state/filter.json")
	if err != nil {
		return FilterMetrics{} // No filter state yet
	}

	var state struct {
		Total         int `json:"total"`
		Filtered      int `json:"filtered"`
		BogonCount    int `json:"bogon_count"`
		OversizeCount int `json:"oversize_count"`
		Kept          int `json:"kept"`
	}

	if err := json.Unmarshal(data, &state); err != nil {
		return FilterMetrics{}
	}

	return FilterMetrics{
		Total:    state.Total,
		Filtered: state.Filtered,
		Bogon:    state.BogonCount,
		Oversize: state.OversizeCount,
		Kept:     state.Kept,
	}
}

// convertDiscoveryData converts internal discovery format to Zabbix LLD format
func (c *Collector) convertDiscoveryData(disc DiscoveryInfo) DiscoveryData {
	data := DiscoveryData{}

	// Modules
	for _, m := range disc.Modules {
		data.Modules = append(data.Modules, DiscoveredModule{
			Module:  m.Name,
			Mode:    m.Mode,
			Enabled: boolToInt(m.Enabled),
		})
	}

	// Interfaces
	for _, i := range disc.Interfaces {
		data.Interfaces = append(data.Interfaces, DiscoveredInterface{
			Interface: i.Name,
			Zone:      i.Zone,
		})
	}

	// Countries
	for _, cc := range disc.Countries {
		data.Countries = append(data.Countries, DiscoveredCountry{
			Country:     cc.Code,
			CountryName: cc.Name,
			Blocked:     boolToInt(cc.Blocked),
		})
	}

	// Feeds
	for _, f := range disc.Feeds {
		data.Feeds = append(data.Feeds, DiscoveredFeed{
			Feed:    f.Name,
			URL:     f.URL,
			Enabled: boolToInt(f.Enabled),
		})
	}

	// Timers
	for _, t := range disc.Timers {
		data.Timers = append(data.Timers, DiscoveredTimer{
			Timer:    t.Name,
			Duration: t.Duration,
		})
	}

	return data
}

// updateLoadAverages reads load averages on Linux
func (c *Collector) updateLoadAverages(s *ServerMetrics) {
	if runtime.GOOS != "linux" {
		return
	}

	data, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return
	}

	var load1, load5, load15 float64
	_, _ = fmt.Sscanf(string(data), "%f %f %f", &load1, &load5, &load15)

	s.Load1m = load1
	s.Load5m = load5
	s.Load15m = load15
}

// GetLastSnapshot returns the last collected snapshot
func (c *Collector) GetLastSnapshot() *MetricsSnapshot {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.lastSnapshot
}

// GetLastCollectTime returns the time of the last collection
func (c *Collector) GetLastCollectTime() time.Time {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.lastCollect
}

// =============================================================================
// Snapshot to Metrics Conversion
// =============================================================================

// ToMetrics converts a snapshot to a list of Zabbix metrics
func (s *MetricsSnapshot) ToMetrics() []Metric {
	var metrics []Metric
	ts := s.Timestamp

	// Daemon metrics
	metrics = append(metrics,
		Metric{Name: "nftban.version", Value: s.Daemon.Version, Type: MetricTypeText, Timestamp: ts},
		Metric{Name: "nftban.build_date", Value: s.Daemon.BuildDate, Type: MetricTypeText, Timestamp: ts},
		Metric{Name: "nftban.uptime", Value: s.Daemon.Uptime, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.pid", Value: s.Daemon.PID, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.status", Value: s.Daemon.Status, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.config_reload_time", Value: s.Daemon.ConfigReloadTime, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.mode", Value: s.Daemon.Mode, Type: MetricTypeText, Timestamp: ts},
	)

	// Runtime metrics
	metrics = append(metrics,
		Metric{Name: "nftban.memory.heap", Value: s.Runtime.MemoryHeap, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.memory.alloc", Value: s.Runtime.MemoryAlloc, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.memory.sys", Value: s.Runtime.MemorySys, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.memory.rss", Value: s.Runtime.MemoryRSS, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.goroutines", Value: s.Runtime.Goroutines, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.gc.cycles", Value: s.Runtime.GCCycles, Type: MetricTypeCounter, Timestamp: ts},
		Metric{Name: "nftban.gc.pause_total", Value: s.Runtime.GCPauseTotal, Type: MetricTypeCounter, Timestamp: ts},
		Metric{Name: "nftban.gc.pause_last", Value: s.Runtime.GCPauseLast, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.gc.cpu_fraction", Value: s.Runtime.GCCPUFraction, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.fds.open", Value: s.Runtime.OpenFDs, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.threads", Value: s.Runtime.Threads, Type: MetricTypeGauge, Timestamp: ts},
	)

	// Ban metrics
	metrics = append(metrics,
		Metric{Name: "nftban.bans.total", Value: s.Bans.Total, Type: MetricTypeCounter, Timestamp: ts},
		Metric{Name: "nftban.bans.24h", Value: s.Bans.Last24h, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.bans.1h", Value: s.Bans.Last1h, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.bans.rate", Value: s.Bans.Rate, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.unbans.total", Value: s.Bans.UnbansTotal, Type: MetricTypeCounter, Timestamp: ts},
		Metric{Name: "nftban.unbans.24h", Value: s.Bans.Unbans24h, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.active.count", Value: s.Bans.ActiveCount, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.permanent.count", Value: s.Bans.PermanentCount, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.persistent.count", Value: s.Bans.PersistentCount, Type: MetricTypeGauge, Timestamp: ts},
	)

	// Event metrics
	metrics = append(metrics,
		Metric{Name: "nftban.events.total", Value: s.Events.Total, Type: MetricTypeCounter, Timestamp: ts},
		Metric{Name: "nftban.events.rate", Value: s.Events.Rate, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.events.dropped", Value: s.Events.Dropped, Type: MetricTypeCounter, Timestamp: ts},
		Metric{Name: "nftban.events.queue_depth", Value: s.Events.QueueDepth, Type: MetricTypeGauge, Timestamp: ts},
	)

	// IPC metrics
	metrics = append(metrics,
		Metric{Name: "nftban.ipc.requests", Value: s.IPC.Requests, Type: MetricTypeCounter, Timestamp: ts},
		Metric{Name: "nftban.ipc.errors", Value: s.IPC.Errors, Type: MetricTypeCounter, Timestamp: ts},
		Metric{Name: "nftban.ipc.latency_avg", Value: s.IPC.LatencyAvg, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.ipc.active_connections", Value: s.IPC.ActiveConnections, Type: MetricTypeGauge, Timestamp: ts},
	)

	// Module metrics
	metrics = append(metrics,
		Metric{Name: "nftban.modules.enabled", Value: s.Modules.Enabled, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.modules.active", Value: s.Modules.Active, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.modules.failed", Value: s.Modules.Failed, Type: MetricTypeGauge, Timestamp: ts},
	)

	// Watchdog metrics
	metrics = append(metrics,
		Metric{Name: "nftban.watchdog.status", Value: s.Watchdog.Status, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.watchdog.mode", Value: s.Watchdog.Mode, Type: MetricTypeText, Timestamp: ts},
		Metric{Name: "nftban.watchdog.cpu_score", Value: s.Watchdog.CPUScore, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.watchdog.mem_score", Value: s.Watchdog.MemScore, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.watchdog.io_score", Value: s.Watchdog.IOScore, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.watchdog.net_score", Value: s.Watchdog.NetScore, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.watchdog.actions_taken", Value: s.Watchdog.ActionsTaken, Type: MetricTypeCounter, Timestamp: ts},
		Metric{Name: "nftban.watchdog.last_action", Value: s.Watchdog.LastAction, Type: MetricTypeText, Timestamp: ts},
		Metric{Name: "nftban.watchdog.mode_changes", Value: s.Watchdog.ModeChanges, Type: MetricTypeCounter, Timestamp: ts},
	)

	// NFTables metrics
	metrics = append(metrics,
		Metric{Name: "nftban.nft.rules_total", Value: s.NFTables.RulesTotal, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.nft.sets_total", Value: s.NFTables.SetsTotal, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.nft.elements_total", Value: s.NFTables.ElementsTotal, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.nft.apply_latency", Value: s.NFTables.ApplyLatency, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.nft.apply_errors", Value: s.NFTables.ApplyErrors, Type: MetricTypeCounter, Timestamp: ts},
	)

	// Feed metrics
	metrics = append(metrics,
		Metric{Name: "nftban.feeds.enabled", Value: s.Feeds.Enabled, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.feeds.loaded", Value: s.Feeds.Loaded, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.feeds.failed", Value: s.Feeds.Failed, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.feeds.ips_total", Value: s.Feeds.IPsTotal, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.feeds.last_update", Value: s.Feeds.LastUpdate, Type: MetricTypeGauge, Timestamp: ts},
	)

	// GeoIP metrics
	metrics = append(metrics,
		Metric{Name: "nftban.geoip.database_age", Value: s.GeoIP.DatabaseAge, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.geoip.lookups_total", Value: s.GeoIP.LookupsTotal, Type: MetricTypeCounter, Timestamp: ts},
		Metric{Name: "nftban.geoip.lookup_errors", Value: s.GeoIP.LookupErrors, Type: MetricTypeCounter, Timestamp: ts},
		Metric{Name: "nftban.geoip.countries_blocked", Value: s.GeoIP.CountriesBlocked, Type: MetricTypeGauge, Timestamp: ts},
	)

	// Suricata metrics
	metrics = append(metrics,
		Metric{Name: "nftban.suricata.enabled", Value: s.Suricata.Enabled, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.suricata.alerts_processed", Value: s.Suricata.AlertsProcessed, Type: MetricTypeCounter, Timestamp: ts},
		Metric{Name: "nftban.suricata.alerts_rate", Value: s.Suricata.AlertsRate, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.suricata.bans_generated", Value: s.Suricata.BansGenerated, Type: MetricTypeCounter, Timestamp: ts},
		Metric{Name: "nftban.suricata.connection_status", Value: s.Suricata.ConnectionStatus, Type: MetricTypeGauge, Timestamp: ts},
	)

	// API metrics
	metrics = append(metrics,
		Metric{Name: "nftban.api.requests_total", Value: s.API.RequestsTotal, Type: MetricTypeCounter, Timestamp: ts},
		Metric{Name: "nftban.api.requests_rate", Value: s.API.RequestsRate, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.api.errors_total", Value: s.API.ErrorsTotal, Type: MetricTypeCounter, Timestamp: ts},
		Metric{Name: "nftban.api.latency_avg", Value: s.API.LatencyAvg, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.api.auth_failures", Value: s.API.AuthFailures, Type: MetricTypeCounter, Timestamp: ts},
	)

	// Server metrics
	metrics = append(metrics,
		Metric{Name: "nftban.server.hostname", Value: s.Server.Hostname, Type: MetricTypeText, Timestamp: ts},
		Metric{Name: "nftban.server.os", Value: s.Server.OS, Type: MetricTypeText, Timestamp: ts},
		Metric{Name: "nftban.server.kernel", Value: s.Server.Kernel, Type: MetricTypeText, Timestamp: ts},
		Metric{Name: "nftban.server.arch", Value: s.Server.Arch, Type: MetricTypeText, Timestamp: ts},
		Metric{Name: "nftban.server.cpu_cores", Value: s.Server.CPUCores, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.server.load_1m", Value: s.Server.Load1m, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.server.load_5m", Value: s.Server.Load5m, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.server.load_15m", Value: s.Server.Load15m, Type: MetricTypeGauge, Timestamp: ts},
	)

	// CIDR filter metrics
	metrics = append(metrics,
		Metric{Name: "nftban.filter.total", Value: s.Filter.Total, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.filter.filtered", Value: s.Filter.Filtered, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.filter.bogon", Value: s.Filter.Bogon, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.filter.oversize", Value: s.Filter.Oversize, Type: MetricTypeGauge, Timestamp: ts},
		Metric{Name: "nftban.filter.kept", Value: s.Filter.Kept, Type: MetricTypeGauge, Timestamp: ts},
	)

	return metrics
}

// =============================================================================
// Helper Functions
// =============================================================================

func boolToInt(b bool) int {
	if b {
		return 1
	}
	return 0
}
