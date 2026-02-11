// =============================================================================
// NFTBan v1.0 - Zabbix Low-Level Discovery
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="discovery"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-22"
// meta:description="Implements Zabbix Low-Level Discovery (LLD) for dynamic entities"
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
	"context"
	"encoding/json"
	"sync"
	"time"
)

// =============================================================================
// Discovery Keys (matching metrics-contract.yaml)
// =============================================================================

const (
	// Discovery rule keys
	DiscoveryKeyModules    = "nftban.discovery.modules"
	DiscoveryKeyInterfaces = "nftban.discovery.interfaces"
	DiscoveryKeyCountries  = "nftban.discovery.countries"
	DiscoveryKeyFeeds      = "nftban.discovery.feeds"
	DiscoveryKeyTimers     = "nftban.discovery.timers"
)

// =============================================================================
// Discovery Manager
// =============================================================================

// DiscoveryManager handles LLD data generation and caching
type DiscoveryManager struct {
	source MetricsSource
	config *Config

	// Cached discovery data
	cache   map[string]*DiscoveryCache
	cacheMu sync.RWMutex

	// Background refresh
	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup
}

// DiscoveryCache holds cached discovery data
type DiscoveryCache struct {
	Key       string
	Data      string    // JSON formatted for Zabbix
	Items     int       // Number of discovered items
	UpdatedAt time.Time
	Error     error
}

// NewDiscoveryManager creates a new discovery manager
func NewDiscoveryManager(source MetricsSource, config *Config) *DiscoveryManager {
	ctx, cancel := context.WithCancel(context.Background())

	dm := &DiscoveryManager{
		source: source,
		config: config,
		cache:  make(map[string]*DiscoveryCache),
		ctx:    ctx,
		cancel: cancel,
	}

	return dm
}

// Start begins background discovery refresh
func (dm *DiscoveryManager) Start() {
	if !dm.config.DiscoveryEnabled {
		return
	}

	dm.wg.Add(1)
	go dm.refreshLoop()
}

// Stop stops the discovery manager
func (dm *DiscoveryManager) Stop() {
	dm.cancel()
	dm.wg.Wait()
}

// refreshLoop periodically refreshes discovery data
func (dm *DiscoveryManager) refreshLoop() {
	defer dm.wg.Done()

	// Initial refresh
	dm.RefreshAll()

	interval := dm.config.DiscoveryInterval
	if interval == 0 {
		interval = time.Hour
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-dm.ctx.Done():
			return
		case <-ticker.C:
			dm.RefreshAll()
		}
	}
}

// =============================================================================
// Discovery Data Generation
// =============================================================================

// RefreshAll refreshes all discovery data
func (dm *DiscoveryManager) RefreshAll() {
	dm.RefreshModules()
	dm.RefreshInterfaces()
	dm.RefreshCountries()
	dm.RefreshFeeds()
	dm.RefreshTimers()
}

// RefreshModules refreshes module discovery data
func (dm *DiscoveryManager) RefreshModules() {
	if dm.source == nil {
		return
	}

	disc := dm.source.GetDiscoveryData()
	modules := make([]map[string]string, 0, len(disc.Modules))

	for _, m := range disc.Modules {
		enabled := "0"
		if m.Enabled {
			enabled = "1"
		}
		modules = append(modules, map[string]string{
			"{#MODULE}":  m.Name,
			"{#MODE}":    m.Mode,
			"{#ENABLED}": enabled,
		})
	}

	data, err := formatLLDData(modules)
	dm.updateCache(DiscoveryKeyModules, data, len(modules), err)
}

// RefreshInterfaces refreshes interface discovery data
func (dm *DiscoveryManager) RefreshInterfaces() {
	if dm.source == nil {
		return
	}

	disc := dm.source.GetDiscoveryData()
	interfaces := make([]map[string]string, 0, len(disc.Interfaces))

	for _, i := range disc.Interfaces {
		interfaces = append(interfaces, map[string]string{
			"{#IFACE}": i.Name,
			"{#ZONE}":  i.Zone,
		})
	}

	data, err := formatLLDData(interfaces)
	dm.updateCache(DiscoveryKeyInterfaces, data, len(interfaces), err)
}

// RefreshCountries refreshes country discovery data
func (dm *DiscoveryManager) RefreshCountries() {
	if dm.source == nil {
		return
	}

	disc := dm.source.GetDiscoveryData()
	countries := make([]map[string]string, 0, len(disc.Countries))

	for _, c := range disc.Countries {
		blocked := "0"
		if c.Blocked {
			blocked = "1"
		}
		countries = append(countries, map[string]string{
			"{#COUNTRY}":      c.Code,
			"{#COUNTRY_NAME}": c.Name,
			"{#BLOCKED}":      blocked,
		})
	}

	data, err := formatLLDData(countries)
	dm.updateCache(DiscoveryKeyCountries, data, len(countries), err)
}

// RefreshFeeds refreshes feed discovery data
func (dm *DiscoveryManager) RefreshFeeds() {
	if dm.source == nil {
		return
	}

	disc := dm.source.GetDiscoveryData()
	feeds := make([]map[string]string, 0, len(disc.Feeds))

	for _, f := range disc.Feeds {
		enabled := "0"
		if f.Enabled {
			enabled = "1"
		}
		feeds = append(feeds, map[string]string{
			"{#FEED}":    f.Name,
			"{#URL}":     f.URL,
			"{#ENABLED}": enabled,
		})
	}

	data, err := formatLLDData(feeds)
	dm.updateCache(DiscoveryKeyFeeds, data, len(feeds), err)
}

// RefreshTimers refreshes timer discovery data
func (dm *DiscoveryManager) RefreshTimers() {
	if dm.source == nil {
		return
	}

	disc := dm.source.GetDiscoveryData()
	timers := make([]map[string]string, 0, len(disc.Timers))

	for _, t := range disc.Timers {
		timers = append(timers, map[string]string{
			"{#TIMER}":    t.Name,
			"{#DURATION}": t.Duration,
		})
	}

	data, err := formatLLDData(timers)
	dm.updateCache(DiscoveryKeyTimers, data, len(timers), err)
}

// updateCache updates the cache for a discovery key
func (dm *DiscoveryManager) updateCache(key, data string, items int, err error) {
	dm.cacheMu.Lock()
	defer dm.cacheMu.Unlock()

	dm.cache[key] = &DiscoveryCache{
		Key:       key,
		Data:      data,
		Items:     items,
		UpdatedAt: time.Now(),
		Error:     err,
	}
}

// =============================================================================
// Discovery Data Retrieval
// =============================================================================

// Get returns discovery data for a key
func (dm *DiscoveryManager) Get(key string) (string, error) {
	dm.cacheMu.RLock()
	cache := dm.cache[key]
	dm.cacheMu.RUnlock()

	if cache == nil {
		// Refresh on demand if not cached
		switch key {
		case DiscoveryKeyModules:
			dm.RefreshModules()
		case DiscoveryKeyInterfaces:
			dm.RefreshInterfaces()
		case DiscoveryKeyCountries:
			dm.RefreshCountries()
		case DiscoveryKeyFeeds:
			dm.RefreshFeeds()
		case DiscoveryKeyTimers:
			dm.RefreshTimers()
		default:
			return "", &DiscoveryError{Key: key, Message: "unknown discovery key"}
		}

		dm.cacheMu.RLock()
		cache = dm.cache[key]
		dm.cacheMu.RUnlock()
	}

	if cache == nil {
		return "", &DiscoveryError{Key: key, Message: "discovery data not available"}
	}

	if cache.Error != nil {
		return "", cache.Error
	}

	return cache.Data, nil
}

// GetAll returns all discovery data
func (dm *DiscoveryManager) GetAll() map[string]string {
	dm.cacheMu.RLock()
	defer dm.cacheMu.RUnlock()

	result := make(map[string]string)
	for key, cache := range dm.cache {
		if cache.Error == nil {
			result[key] = cache.Data
		}
	}
	return result
}

// GetStatus returns status of all discovery caches
func (dm *DiscoveryManager) GetStatus() []DiscoveryStatus {
	dm.cacheMu.RLock()
	defer dm.cacheMu.RUnlock()

	var status []DiscoveryStatus
	for _, cache := range dm.cache {
		s := DiscoveryStatus{
			Key:       cache.Key,
			Items:     cache.Items,
			UpdatedAt: cache.UpdatedAt,
		}
		if cache.Error != nil {
			s.Error = cache.Error.Error()
		}
		status = append(status, s)
	}
	return status
}

// DiscoveryStatus represents status of a discovery cache
type DiscoveryStatus struct {
	Key       string    `json:"key"`
	Items     int       `json:"items"`
	UpdatedAt time.Time `json:"updated_at"`
	Error     string    `json:"error,omitempty"`
}

// =============================================================================
// Discovery Metrics Generation
// =============================================================================

// ToMetrics converts discovery data to Zabbix metrics
func (dm *DiscoveryManager) ToMetrics() []Metric {
	dm.cacheMu.RLock()
	defer dm.cacheMu.RUnlock()

	var metrics []Metric
	now := time.Now()

	for key, cache := range dm.cache {
		if cache.Error == nil && cache.Data != "" {
			metrics = append(metrics, Metric{
				Name:      key,
				Value:     cache.Data,
				Type:      MetricTypeDiscovery,
				Timestamp: now,
			})
		}
	}

	return metrics
}

// =============================================================================
// Item Prototype Metrics
// =============================================================================

// GenerateModuleMetrics generates metrics for discovered modules
func (dm *DiscoveryManager) GenerateModuleMetrics(modules map[string]ModuleStatus) []Metric {
	var metrics []Metric
	now := time.Now()

	for name, status := range modules {
		metrics = append(metrics,
			Metric{
				Name:      BuildKey("nftban.module.status", name),
				Value:     status.Status,
				Type:      MetricTypeGauge,
				Timestamp: now,
			},
			Metric{
				Name:      BuildKey("nftban.module.events", name),
				Value:     status.Events,
				Type:      MetricTypeCounter,
				Timestamp: now,
			},
			Metric{
				Name:      BuildKey("nftban.module.bans", name),
				Value:     status.Bans,
				Type:      MetricTypeCounter,
				Timestamp: now,
			},
			Metric{
				Name:      BuildKey("nftban.module.errors", name),
				Value:     status.Errors,
				Type:      MetricTypeCounter,
				Timestamp: now,
			},
			Metric{
				Name:      BuildKey("nftban.module.latency", name),
				Value:     status.Latency,
				Type:      MetricTypeGauge,
				Timestamp: now,
			},
		)
	}

	return metrics
}

// GenerateCountryMetrics generates metrics for discovered countries
func (dm *DiscoveryManager) GenerateCountryMetrics(countries map[string]CountryStats) []Metric {
	var metrics []Metric
	now := time.Now()

	for code, stats := range countries {
		metrics = append(metrics,
			Metric{
				Name:      BuildKey("nftban.country.bans", code),
				Value:     stats.ActiveBans,
				Type:      MetricTypeGauge,
				Timestamp: now,
			},
			Metric{
				Name:      BuildKey("nftban.country.bans_24h", code),
				Value:     stats.Bans24h,
				Type:      MetricTypeGauge,
				Timestamp: now,
			},
			Metric{
				Name:      BuildKey("nftban.country.unique_ips", code),
				Value:     stats.UniqueIPs,
				Type:      MetricTypeGauge,
				Timestamp: now,
			},
		)
	}

	return metrics
}

// CountryStats holds statistics for a country
type CountryStats struct {
	ActiveBans int64
	Bans24h    int64
	UniqueIPs  int64
}

// GenerateFeedMetrics generates metrics for discovered feeds
func (dm *DiscoveryManager) GenerateFeedMetrics(feeds map[string]FeedStatus) []Metric {
	var metrics []Metric
	now := time.Now()

	for name, status := range feeds {
		metrics = append(metrics,
			Metric{
				Name:      BuildKey("nftban.feed.status", name),
				Value:     status.Status,
				Type:      MetricTypeGauge,
				Timestamp: now,
			},
			Metric{
				Name:      BuildKey("nftban.feed.ips", name),
				Value:     status.IPCount,
				Type:      MetricTypeGauge,
				Timestamp: now,
			},
			Metric{
				Name:      BuildKey("nftban.feed.last_update", name),
				Value:     status.LastUpdate.Unix(),
				Type:      MetricTypeGauge,
				Timestamp: now,
			},
			Metric{
				Name:      BuildKey("nftban.feed.age", name),
				Value:     int64(time.Since(status.LastUpdate).Seconds()),
				Type:      MetricTypeGauge,
				Timestamp: now,
			},
		)
	}

	return metrics
}

// FeedStatus holds status for a feed
type FeedStatus struct {
	Status     int // 1=ok, 0=error
	IPCount    int64
	LastUpdate time.Time
}

// GenerateInterfaceMetrics generates metrics for discovered interfaces
func (dm *DiscoveryManager) GenerateInterfaceMetrics(interfaces map[string]InterfaceStats) []Metric {
	var metrics []Metric
	now := time.Now()

	for name, stats := range interfaces {
		metrics = append(metrics,
			Metric{
				Name:      BuildKey("nftban.iface.bytes_in", name),
				Value:     stats.BytesIn,
				Type:      MetricTypeCounter,
				Timestamp: now,
			},
			Metric{
				Name:      BuildKey("nftban.iface.bytes_out", name),
				Value:     stats.BytesOut,
				Type:      MetricTypeCounter,
				Timestamp: now,
			},
			Metric{
				Name:      BuildKey("nftban.iface.dropped", name),
				Value:     stats.Dropped,
				Type:      MetricTypeCounter,
				Timestamp: now,
			},
		)
	}

	return metrics
}

// InterfaceStats holds statistics for an interface
type InterfaceStats struct {
	BytesIn  uint64
	BytesOut uint64
	Dropped  uint64
}

// GenerateTimerMetrics generates metrics for discovered timers
func (dm *DiscoveryManager) GenerateTimerMetrics(timers map[string]TimerStats) []Metric {
	var metrics []Metric
	now := time.Now()

	for name, stats := range timers {
		metrics = append(metrics,
			Metric{
				Name:      BuildKey("nftban.timer.active", name),
				Value:     stats.ActiveCount,
				Type:      MetricTypeGauge,
				Timestamp: now,
			},
			Metric{
				Name:      BuildKey("nftban.timer.expires_1h", name),
				Value:     stats.ExpiresIn1h,
				Type:      MetricTypeGauge,
				Timestamp: now,
			},
		)
	}

	return metrics
}

// TimerStats holds statistics for a timer
type TimerStats struct {
	ActiveCount int64
	ExpiresIn1h int64
}

// =============================================================================
// Helper Functions
// =============================================================================

// formatLLDData formats data for Zabbix LLD
// Output format: {"data": [{"{#MACRO}": "value", ...}, ...]}
func formatLLDData(items []map[string]string) (string, error) {
	wrapper := struct {
		Data []map[string]string `json:"data"`
	}{
		Data: items,
	}

	b, err := json.Marshal(wrapper)
	if err != nil {
		return "", err
	}

	return string(b), nil
}

// =============================================================================
// Error Types
// =============================================================================

// DiscoveryError represents a discovery error
type DiscoveryError struct {
	Key     string
	Message string
	Cause   error
}

func (e *DiscoveryError) Error() string {
	if e.Cause != nil {
		return e.Key + ": " + e.Message + ": " + e.Cause.Error()
	}
	return e.Key + ": " + e.Message
}

func (e *DiscoveryError) Unwrap() error {
	return e.Cause
}
