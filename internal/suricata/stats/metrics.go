// =============================================================================
// NFTBan - Suricata Prometheus Metrics
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="metrics"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Prometheus metrics for Suricata SID triggers and performance"
// meta:input="SID trigger events"
// meta:output="Prometheus metrics"
// meta:depends="github.com/prometheus/client_golang/prometheus"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package stats

import (
	"sync"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// Metrics holds all Suricata-related Prometheus metrics
type Metrics struct {
	// SID trigger counters
	SIDTriggers *prometheus.CounterVec

	// SID last trigger timestamp
	SIDLastTrigger *prometheus.GaugeVec

	// Unique source IPs per SID
	SIDUniqueSources *prometheus.GaugeVec

	// User actions (enabled/disabled)
	SIDUserEnabled  *prometheus.GaugeVec
	SIDUserDisabled *prometheus.GaugeVec

	// Category aggregates
	CategoryTriggers *prometheus.CounterVec

	// Alert severity
	AlertSeverity *prometheus.CounterVec

	// Performance metrics
	ProcessingLatency prometheus.Histogram
	EventsProcessed   prometheus.Counter
	ParseErrors       prometheus.Counter

	// Service-level metrics (for web UI alignment)
	ServiceRunning   prometheus.Gauge
	RulesTotal       prometheus.Gauge
	RulesEnabled     prometheus.Gauge
	AlertsLast24h    prometheus.Gauge
	DropRate         prometheus.Gauge
	MemoryUsageBytes prometheus.Gauge
	UptimeSeconds    prometheus.Gauge
}

var (
	metrics *Metrics
	once    sync.Once
)

// InitMetrics initializes Prometheus metrics (singleton)
func InitMetrics() *Metrics {
	once.Do(func() {
		metrics = &Metrics{
			SIDTriggers: promauto.NewCounterVec(
				prometheus.CounterOpts{
					Name: "nftban_suricata_sid_triggers_total",
					Help: "Total number of triggers per SID",
				},
				[]string{"sid", "category", "signature"},
			),

			SIDLastTrigger: promauto.NewGaugeVec(
				prometheus.GaugeOpts{
					Name: "nftban_suricata_sid_last_trigger_timestamp",
					Help: "Timestamp of last trigger for SID",
				},
				[]string{"sid", "category"},
			),

			SIDUniqueSources: promauto.NewGaugeVec(
				prometheus.GaugeOpts{
					Name: "nftban_suricata_sid_unique_sources_total",
					Help: "Number of unique source IPs triggering this SID",
				},
				[]string{"sid", "category"},
			),

			SIDUserEnabled: promauto.NewGaugeVec(
				prometheus.GaugeOpts{
					Name: "nftban_suricata_sid_user_enabled",
					Help: "SIDs manually enabled by user (1=enabled, 0=not)",
				},
				[]string{"sid", "mode"}, // mode: alert or drop
			),

			SIDUserDisabled: promauto.NewGaugeVec(
				prometheus.GaugeOpts{
					Name: "nftban_suricata_sid_user_disabled",
					Help: "SIDs manually disabled by user (1=disabled, 0=not)",
				},
				[]string{"sid"},
			),

			CategoryTriggers: promauto.NewCounterVec(
				prometheus.CounterOpts{
					Name: "nftban_suricata_category_triggers_total",
					Help: "Total triggers per rule category",
				},
				[]string{"category"},
			),

			AlertSeverity: promauto.NewCounterVec(
				prometheus.CounterOpts{
					Name: "nftban_suricata_alert_severity_total",
					Help: "Alerts by severity level",
				},
				[]string{"severity"},
			),

			ProcessingLatency: promauto.NewHistogram(
				prometheus.HistogramOpts{
					Name:    "nftban_suricata_processing_latency_seconds",
					Help:    "Latency of eve-alerts.json event processing",
					Buckets: prometheus.DefBuckets,
				},
			),

			EventsProcessed: promauto.NewCounter(
				prometheus.CounterOpts{
					Name: "nftban_suricata_events_processed_total",
					Help: "Total number of eve-alerts.json events processed",
				},
			),

			ParseErrors: promauto.NewCounter(
				prometheus.CounterOpts{
					Name: "nftban_suricata_parse_errors_total",
					Help: "Total number of JSON parse errors",
				},
			),

			// Service-level metrics
			ServiceRunning: promauto.NewGauge(
				prometheus.GaugeOpts{
					Name: "nftban_suricata_service_running",
					Help: "Suricata service running status (1=running, 0=stopped)",
				},
			),

			RulesTotal: promauto.NewGauge(
				prometheus.GaugeOpts{
					Name: "nftban_suricata_rules_total",
					Help: "Total number of Suricata rules loaded",
				},
			),

			RulesEnabled: promauto.NewGauge(
				prometheus.GaugeOpts{
					Name: "nftban_suricata_rules_enabled",
					Help: "Number of enabled Suricata rules",
				},
			),

			AlertsLast24h: promauto.NewGauge(
				prometheus.GaugeOpts{
					Name: "nftban_suricata_alerts_last_24h",
					Help: "Number of alerts in the last 24 hours",
				},
			),

			DropRate: promauto.NewGauge(
				prometheus.GaugeOpts{
					Name: "nftban_suricata_drop_rate",
					Help: "Packet drop rate percentage",
				},
			),

			MemoryUsageBytes: promauto.NewGauge(
				prometheus.GaugeOpts{
					Name: "nftban_suricata_memory_usage_bytes",
					Help: "Memory usage of Suricata process in bytes",
				},
			),

			UptimeSeconds: promauto.NewGauge(
				prometheus.GaugeOpts{
					Name: "nftban_suricata_uptime_seconds",
					Help: "Suricata service uptime in seconds",
				},
			),
		}
	})

	return metrics
}

// GetMetrics returns the singleton metrics instance
func GetMetrics() *Metrics {
	if metrics == nil {
		return InitMetrics()
	}
	return metrics
}

// RecordTrigger records a SID trigger event
func (m *Metrics) RecordTrigger(sid, category, signature string, timestamp float64, sourceIP string) {
	// Increment trigger counter
	m.SIDTriggers.WithLabelValues(sid, category, signature).Inc()

	// Update last trigger timestamp
	m.SIDLastTrigger.WithLabelValues(sid, category).Set(timestamp)

	// Increment category counter
	m.CategoryTriggers.WithLabelValues(category).Inc()

	// Events processed counter
	m.EventsProcessed.Inc()
}

// RecordSeverity records alert severity
func (m *Metrics) RecordSeverity(severity string) {
	m.AlertSeverity.WithLabelValues(severity).Inc()
}

// SetUserEnabled sets user-enabled flag for a SID
func (m *Metrics) SetUserEnabled(sid, mode string) {
	m.SIDUserEnabled.WithLabelValues(sid, mode).Set(1)
}

// SetUserDisabled sets user-disabled flag for a SID
func (m *Metrics) SetUserDisabled(sid string) {
	m.SIDUserDisabled.WithLabelValues(sid).Set(1)
}

// ClearUserEnabled clears user-enabled flag for a SID
func (m *Metrics) ClearUserEnabled(sid, mode string) {
	m.SIDUserEnabled.WithLabelValues(sid, mode).Set(0)
}

// ClearUserDisabled clears user-disabled flag for a SID
func (m *Metrics) ClearUserDisabled(sid string) {
	m.SIDUserDisabled.WithLabelValues(sid).Set(0)
}

// RecordParseError increments parse error counter
func (m *Metrics) RecordParseError() {
	m.ParseErrors.Inc()
}

// SetServiceRunning sets Suricata service running status
func (m *Metrics) SetServiceRunning(running bool) {
	if running {
		m.ServiceRunning.Set(1)
	} else {
		m.ServiceRunning.Set(0)
	}
}

// SetRulesCount sets total and enabled rules count
func (m *Metrics) SetRulesCount(total, enabled int) {
	m.RulesTotal.Set(float64(total))
	m.RulesEnabled.Set(float64(enabled))
}

// SetAlertsLast24h sets alerts count for last 24 hours
func (m *Metrics) SetAlertsLast24h(count int) {
	m.AlertsLast24h.Set(float64(count))
}

// SetDropRate sets packet drop rate
func (m *Metrics) SetDropRate(rate float64) {
	m.DropRate.Set(rate)
}

// SetMemoryUsage sets memory usage in bytes
func (m *Metrics) SetMemoryUsage(bytes int64) {
	m.MemoryUsageBytes.Set(float64(bytes))
}

// SetUptime sets service uptime in seconds
func (m *Metrics) SetUptime(seconds float64) {
	m.UptimeSeconds.Set(seconds)
}
