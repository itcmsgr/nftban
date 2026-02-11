// =============================================================================
// NFTBan v1.0 - Zabbix Exporter
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="exporter"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-22"
// meta:description="Main Zabbix exporter that orchestrates metrics collection"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network="10051/tcp"
// meta:inventory.privileges="none"
// =============================================================================

package zabbix

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"
)

// =============================================================================
// Exporter
// =============================================================================

// Exporter is the main Zabbix metrics exporter
type Exporter struct {
	config    *Config
	collector *Collector
	discovery *DiscoveryManager
	sender    *MultiSender

	// State
	running   atomic.Bool
	startTime time.Time

	// Background workers
	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup

	// Statistics
	stats ExporterStats

	// Callbacks
	onError func(error)
	onSend  func(*MultiSendResult)
}

// ExporterStats holds exporter statistics
type ExporterStats struct {
	CollectCount   atomic.Int64
	CollectErrors  atomic.Int64
	SendCount      atomic.Int64
	SendErrors     atomic.Int64
	MetricsSent    atomic.Int64
	LastCollect    atomic.Value // time.Time
	LastSend       atomic.Value // time.Time
	LastError      atomic.Value // string
}

// ExporterOption is a functional option for Exporter
type ExporterOption func(*Exporter)

// WithErrorCallback sets the error callback
func WithErrorCallback(fn func(error)) ExporterOption {
	return func(e *Exporter) {
		e.onError = fn
	}
}

// WithSendCallback sets the send callback
func WithSendCallback(fn func(*MultiSendResult)) ExporterOption {
	return func(e *Exporter) {
		e.onSend = fn
	}
}

// NewExporter creates a new Zabbix exporter
func NewExporter(config *Config, source MetricsSource, opts ...ExporterOption) (*Exporter, error) {
	if config == nil {
		return nil, fmt.Errorf("config is required")
	}

	// Apply defaults
	config.ApplyDefaults()

	// Validate config
	if err := config.Validate(); err != nil {
		return nil, fmt.Errorf("invalid config: %w", err)
	}

	ctx, cancel := context.WithCancel(context.Background())

	e := &Exporter{
		config:    config,
		collector: NewCollector(source),
		ctx:       ctx,
		cancel:    cancel,
	}

	// Apply options
	for _, opt := range opts {
		opt(e)
	}

	// Create discovery manager
	e.discovery = NewDiscoveryManager(source, config)

	// Create multi-sender if enabled
	if config.Enabled && len(config.GetEnabledTargets()) > 0 {
		sender, err := NewMultiSender(config)
		if err != nil {
			cancel()
			return nil, fmt.Errorf("failed to create sender: %w", err)
		}
		e.sender = sender
	}

	return e, nil
}

// =============================================================================
// Lifecycle
// =============================================================================

// Start starts the exporter
func (e *Exporter) Start() error {
	if !e.config.Enabled {
		return nil
	}

	if e.running.Swap(true) {
		return fmt.Errorf("exporter already running")
	}

	e.startTime = time.Now()

	// Start discovery manager
	e.discovery.Start()

	// Start collection loop
	e.wg.Add(1)
	go e.collectionLoop()

	return nil
}

// Stop stops the exporter
func (e *Exporter) Stop() error {
	if !e.running.Swap(false) {
		return nil // Not running
	}

	e.cancel()

	// Stop discovery
	e.discovery.Stop()

	// Wait for workers
	e.wg.Wait()

	// Close sender
	if e.sender != nil {
		return e.sender.Close()
	}

	return nil
}

// IsRunning returns true if the exporter is running
func (e *Exporter) IsRunning() bool {
	return e.running.Load()
}

// =============================================================================
// Collection Loop
// =============================================================================

// collectionLoop runs the main collection and send loop
func (e *Exporter) collectionLoop() {
	defer e.wg.Done()

	interval := e.config.Interval
	if interval == 0 {
		interval = DefaultInterval
	}

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	// Initial collection
	e.collectAndSend()

	for {
		select {
		case <-e.ctx.Done():
			return
		case <-ticker.C:
			e.collectAndSend()
		}
	}
}

// collectAndSend performs one collection and send cycle
func (e *Exporter) collectAndSend() {
	// Collect metrics
	snapshot := e.collector.Collect()
	e.stats.CollectCount.Add(1)
	e.stats.LastCollect.Store(time.Now())

	if snapshot == nil {
		e.stats.CollectErrors.Add(1)
		e.handleError(fmt.Errorf("failed to collect metrics"))
		return
	}

	// Convert to metrics
	metrics := snapshot.ToMetrics()

	// Add discovery metrics
	discoveryMetrics := e.discovery.ToMetrics()
	metrics = append(metrics, discoveryMetrics...)

	// Add module prototype metrics
	if len(snapshot.Modules.Status) > 0 {
		moduleMetrics := e.discovery.GenerateModuleMetrics(snapshot.Modules.Status)
		metrics = append(metrics, moduleMetrics...)
	}

	// Send metrics
	if e.sender != nil && len(metrics) > 0 {
		result, err := e.sender.Send(e.ctx, metrics)
		if err != nil {
			e.stats.SendErrors.Add(1)
			e.stats.LastError.Store(err.Error())
			e.handleError(err)
		} else {
			e.stats.SendCount.Add(1)
			e.stats.MetricsSent.Add(int64(len(metrics)))
			e.stats.LastSend.Store(time.Now())

			if e.onSend != nil {
				e.onSend(result)
			}
		}
	}
}

// handleError calls the error callback if set
func (e *Exporter) handleError(err error) {
	if e.onError != nil {
		e.onError(err)
	}
}

// =============================================================================
// Manual Operations
// =============================================================================

// CollectNow performs an immediate collection and returns the snapshot
func (e *Exporter) CollectNow() *MetricsSnapshot {
	return e.collector.Collect()
}

// SendNow performs an immediate send of the current metrics
func (e *Exporter) SendNow(ctx context.Context) (*MultiSendResult, error) {
	if e.sender == nil {
		return nil, fmt.Errorf("sender not configured")
	}

	snapshot := e.collector.Collect()
	if snapshot == nil {
		return nil, fmt.Errorf("failed to collect metrics")
	}

	metrics := snapshot.ToMetrics()
	discoveryMetrics := e.discovery.ToMetrics()
	metrics = append(metrics, discoveryMetrics...)

	return e.sender.Send(ctx, metrics)
}

// RefreshDiscovery forces a discovery refresh
func (e *Exporter) RefreshDiscovery() {
	e.discovery.RefreshAll()
}

// =============================================================================
// Status & Statistics
// =============================================================================

// Status returns the current exporter status
func (e *Exporter) Status() ExporterStatusFull {
	status := ExporterStatusFull{
		Enabled:   e.config.Enabled,
		Running:   e.running.Load(),
		StartTime: e.startTime,
		Stats: ExporterStatsSnapshot{
			CollectCount:  e.stats.CollectCount.Load(),
			CollectErrors: e.stats.CollectErrors.Load(),
			SendCount:     e.stats.SendCount.Load(),
			SendErrors:    e.stats.SendErrors.Load(),
			MetricsSent:   e.stats.MetricsSent.Load(),
		},
		Discovery: e.discovery.GetStatus(),
	}

	if v := e.stats.LastCollect.Load(); v != nil {
		status.Stats.LastCollect = v.(time.Time)
	}
	if v := e.stats.LastSend.Load(); v != nil {
		status.Stats.LastSend = v.(time.Time)
	}
	if v := e.stats.LastError.Load(); v != nil {
		status.Stats.LastError = v.(string)
	}

	if e.sender != nil {
		senderStatus := e.sender.Status()
		status.Targets = senderStatus.Targets
		status.Health = e.sender.GetHealth()
	}

	return status
}

// ExporterStatusFull contains full exporter status
type ExporterStatusFull struct {
	Enabled   bool                      `json:"enabled"`
	Running   bool                      `json:"running"`
	StartTime time.Time                 `json:"start_time"`
	Stats     ExporterStatsSnapshot     `json:"stats"`
	Targets   []SenderStatus            `json:"targets"`
	Health    map[string]TargetHealth   `json:"health"`
	Discovery []DiscoveryStatus         `json:"discovery"`
}

// ExporterStatsSnapshot is a point-in-time stats snapshot
type ExporterStatsSnapshot struct {
	CollectCount  int64     `json:"collect_count"`
	CollectErrors int64     `json:"collect_errors"`
	SendCount     int64     `json:"send_count"`
	SendErrors    int64     `json:"send_errors"`
	MetricsSent   int64     `json:"metrics_sent"`
	LastCollect   time.Time `json:"last_collect"`
	LastSend      time.Time `json:"last_send"`
	LastError     string    `json:"last_error,omitempty"`
}

// =============================================================================
// Configuration
// =============================================================================

// Config returns the current configuration
func (e *Exporter) Config() *Config {
	return e.config
}

// Reload reloads the configuration
func (e *Exporter) Reload(config *Config) error {
	if config == nil {
		return fmt.Errorf("config is required")
	}

	config.ApplyDefaults()
	if err := config.Validate(); err != nil {
		return fmt.Errorf("invalid config: %w", err)
	}

	wasRunning := e.running.Load()

	// Stop if running
	if wasRunning {
		if err := e.Stop(); err != nil {
			return fmt.Errorf("failed to stop: %w", err)
		}
	}

	// Update config
	e.config = config

	// Recreate sender
	if config.Enabled && len(config.GetEnabledTargets()) > 0 {
		sender, err := NewMultiSender(config)
		if err != nil {
			return fmt.Errorf("failed to create sender: %w", err)
		}
		e.sender = sender
	} else {
		e.sender = nil
	}

	// Recreate context
	e.ctx, e.cancel = context.WithCancel(context.Background())

	// Restart if was running
	if wasRunning && config.Enabled {
		return e.Start()
	}

	return nil
}

// =============================================================================
// Testing Helpers
// =============================================================================

// TestConnections tests connectivity to all targets
func (e *Exporter) TestConnections(ctx context.Context) map[string]error {
	if e.sender == nil {
		return map[string]error{"_": fmt.Errorf("sender not configured")}
	}
	return e.sender.TestAllConnections(ctx)
}

// PingTargets pings all targets and returns latencies
func (e *Exporter) PingTargets(ctx context.Context) map[string]time.Duration {
	if e.sender == nil {
		return nil
	}
	return e.sender.PingAll(ctx)
}

// SendTestMetric sends a test metric to verify the setup
func (e *Exporter) SendTestMetric(ctx context.Context) (*MultiSendResult, error) {
	if e.sender == nil {
		return nil, fmt.Errorf("sender not configured")
	}

	metric := Metric{
		Name:      "nftban.test",
		Value:     1,
		Type:      MetricTypeGauge,
		Timestamp: time.Now(),
	}

	return e.sender.Send(ctx, []Metric{metric})
}

// =============================================================================
// Getters
// =============================================================================

// Collector returns the metrics collector
func (e *Exporter) Collector() *Collector {
	return e.collector
}

// Discovery returns the discovery manager
func (e *Exporter) Discovery() *DiscoveryManager {
	return e.discovery
}

// Sender returns the multi-sender
func (e *Exporter) Sender() *MultiSender {
	return e.sender
}
