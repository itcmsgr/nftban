// =============================================================================
// NFTBan v1.0 - Analytics Prometheus Metrics
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="prometheus"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Prometheus metrics integration for analytics package"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package analytics

import (
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

var (
	bansTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Namespace: "nftban",
			Subsystem: "analytics",
			Name:      "bans_total",
			Help:      "Total number of IP bans, labeled by country and source.",
		},
		[]string{"country", "source"},
	)

	persistentOffendersTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Namespace: "nftban",
			Subsystem: "analytics",
			Name:      "persistent_offenders_total",
			Help:      "Total number of IPs escalated to persistent/permanent bans, labeled by country and source.",
		},
		[]string{"country", "source"},
	)

	uniqueIPsByCountry = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Namespace: "nftban",
			Subsystem: "analytics",
			Name:      "unique_ips_by_country",
			Help:      "Number of unique banned IPs per country.",
		},
		[]string{"country"},
	)
)

// RegisterPrometheus registers nftban analytics metrics with Prometheus.
// Call once from main after prometheus client init.
func RegisterPrometheus(registry *prometheus.Registry) {
	if registry == nil {
		prometheus.MustRegister(bansTotal, persistentOffendersTotal, uniqueIPsByCountry)
		return
	}
	registry.MustRegister(bansTotal, persistentOffendersTotal, uniqueIPsByCountry)
}

// RecordBanWithMetrics combines analytics + Prometheus for a ban.
func (s *State) RecordBanWithMetrics(ip, country, city, source, reason string, t time.Time) {
	s.RecordBan(ip, country, city, source, reason, t)

	if country == "" {
		country = "UNK"
	}
	if source == "" {
		source = "unknown"
	}

	bansTotal.WithLabelValues(country, source).Inc()

	// Update gauge for unique IPs per country
	if cs := s.countries[country]; cs != nil {
		uniqueIPsByCountry.WithLabelValues(country).Set(float64(cs.IPCount))
	}
}

// RecordPersistentOffender increments the persistent offenders counter.
func (s *State) RecordPersistentOffender(ip, country, source string, t time.Time) {
	if country == "" {
		country = "UNK"
	}
	if source == "" {
		source = "unknown"
	}
	persistentOffendersTotal.WithLabelValues(country, source).Inc()
}

// UpdatePrometheusGauges updates all gauge metrics from current state.
// Call periodically (e.g., every 30s) to keep gauges in sync.
func (s *State) UpdatePrometheusGauges() {
	if s == nil {
		return
	}

	s.mu.RLock()
	defer s.mu.RUnlock()

	for country, cs := range s.countries {
		uniqueIPsByCountry.WithLabelValues(country).Set(float64(cs.IPCount))
	}
}
