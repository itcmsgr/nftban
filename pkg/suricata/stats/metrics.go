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
	SIDUserEnabled *prometheus.GaugeVec
	SIDUserDisabled *prometheus.GaugeVec

	// Category aggregates
	CategoryTriggers *prometheus.CounterVec

	// Alert severity
	AlertSeverity *prometheus.CounterVec

	// Performance metrics
	ProcessingLatency prometheus.Histogram
	EventsProcessed prometheus.Counter
	ParseErrors prometheus.Counter
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
