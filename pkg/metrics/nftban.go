// Package metrics provides Prometheus metrics for NFTBan operations
// This file contains application-level metrics for ban/unban operations,
// feed loading, sync operations, and authentication
package metrics

import (
	"sync"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// =============================================================================
// NFTBan Operation Metrics
// =============================================================================
// These metrics track ban/unban operations, feed loading, sync duration,
// and authentication events for observability and alerting
// =============================================================================

var (
	// Ban/Unban counters
	bansTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "bans_total",
		Help:      "Total number of IP bans performed",
	}, []string{"source", "family"}) // source: manual, feeds, suricata, portscan, etc. family: ipv4, ipv6

	unbansTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "unbans_total",
		Help:      "Total number of IP unbans performed",
	}, []string{"source", "family"})

	// Ban/Unban errors
	banErrorsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "ban_errors_total",
		Help:      "Total number of ban operation errors",
	}, []string{"source", "error_type"})

	unbanErrorsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "unban_errors_total",
		Help:      "Total number of unban operation errors",
	}, []string{"source", "error_type"})

	// Feed loading metrics
	feedsLoadDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Namespace: "nftban",
		Name:      "feeds_load_duration_seconds",
		Help:      "Time to load threat feeds",
		Buckets:   prometheus.ExponentialBuckets(0.1, 2, 10), // 0.1s to ~102s
	}, []string{"feed_name"})

	feedsLoadTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "feeds_load_total",
		Help:      "Total number of feed load operations",
	}, []string{"feed_name", "status"}) // status: success, error

	feedsIPsLoaded = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "feeds_ips_loaded",
		Help:      "Number of IPs loaded from each feed",
	}, []string{"feed_name", "family"})

	// Sync operation metrics
	syncDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Namespace: "nftban",
		Name:      "sync_duration_seconds",
		Help:      "Time to sync firewall rules with nftables",
		Buckets:   prometheus.ExponentialBuckets(0.01, 2, 12), // 10ms to ~40s
	}, []string{"operation"}) // operation: full, incremental, feeds, manual

	syncOperationsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "sync_operations_total",
		Help:      "Total number of sync operations performed",
	}, []string{"operation", "status"})

	syncIPsAdded = promauto.NewCounter(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "sync_ips_added_total",
		Help:      "Total number of IPs added during sync operations",
	})

	syncIPsRemoved = promauto.NewCounter(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "sync_ips_removed_total",
		Help:      "Total number of IPs removed during sync operations",
	})

	// Authentication metrics
	authAttemptsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "auth_attempts_total",
		Help:      "Total authentication attempts",
	}, []string{"status"}) // status: success, failure

	authFailuresTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "auth_failures_total",
		Help:      "Total authentication failures by reason",
	}, []string{"reason"}) // reason: invalid_password, user_not_found, root_blocked, token_expired

	// API request metrics
	apiRequestDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Namespace: "nftban",
		Name:      "api_request_duration_seconds",
		Help:      "API request duration in seconds",
		Buckets:   prometheus.DefBuckets,
	}, []string{"endpoint", "method"})

	apiRequestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "api_requests_total",
		Help:      "Total API requests",
	}, []string{"endpoint", "method", "status_code"})

	// Module status gauges
	moduleStatus = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "module_enabled",
		Help:      "Module enabled status (1=enabled, 0=disabled)",
	}, []string{"module"}) // module: portscan, ddos, login_monitor, suricata, geoban

	// NFT CLI execution metrics
	nftCLIDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Namespace: "nftban",
		Name:      "nft_cli_duration_seconds",
		Help:      "Duration of nft CLI command execution",
		Buckets:   prometheus.ExponentialBuckets(0.001, 2, 15), // 1ms to ~32s
	}, []string{"operation"})

	nftCLIErrorsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "nft_cli_errors_total",
		Help:      "Total nft CLI command errors",
	}, []string{"operation", "error_type"})
)

// =============================================================================
// Metric Recording Functions
// =============================================================================

// RecordBan records a successful ban operation
func RecordBan(source, family string) {
	bansTotal.WithLabelValues(source, family).Inc()
}

// RecordUnban records a successful unban operation
func RecordUnban(source, family string) {
	unbansTotal.WithLabelValues(source, family).Inc()
}

// RecordBanError records a ban operation error
func RecordBanError(source, errorType string) {
	banErrorsTotal.WithLabelValues(source, errorType).Inc()
}

// RecordUnbanError records an unban operation error
func RecordUnbanError(source, errorType string) {
	unbanErrorsTotal.WithLabelValues(source, errorType).Inc()
}

// RecordFeedLoad records a feed load operation with duration
func RecordFeedLoad(feedName string, durationSec float64, success bool) {
	feedsLoadDuration.WithLabelValues(feedName).Observe(durationSec)
	status := "success"
	if !success {
		status = "error"
	}
	feedsLoadTotal.WithLabelValues(feedName, status).Inc()
}

// SetFeedIPsLoaded sets the number of IPs loaded from a feed
func SetFeedIPsLoaded(feedName, family string, count float64) {
	feedsIPsLoaded.WithLabelValues(feedName, family).Set(count)
}

// RecordSync records a sync operation with duration
func RecordSync(operation string, durationSec float64, success bool) {
	syncDuration.WithLabelValues(operation).Observe(durationSec)
	status := "success"
	if !success {
		status = "error"
	}
	syncOperationsTotal.WithLabelValues(operation, status).Inc()
}

// RecordSyncIPChanges records IPs added/removed during sync
func RecordSyncIPChanges(added, removed int) {
	syncIPsAdded.Add(float64(added))
	syncIPsRemoved.Add(float64(removed))
}

// RecordAuthAttempt records an authentication attempt
func RecordAuthAttempt(success bool) {
	status := "success"
	if !success {
		status = "failure"
	}
	authAttemptsTotal.WithLabelValues(status).Inc()
}

// RecordAuthFailure records an authentication failure with reason
func RecordAuthFailure(reason string) {
	authFailuresTotal.WithLabelValues(reason).Inc()
}

// RecordAPIRequest records an API request
func RecordAPIRequest(endpoint, method string, statusCode int, durationSec float64) {
	apiRequestDuration.WithLabelValues(endpoint, method).Observe(durationSec)
	apiRequestsTotal.WithLabelValues(endpoint, method, statusCodeString(statusCode)).Inc()
}

// SetModuleStatus sets the enabled status of a module
func SetModuleStatus(module string, enabled bool) {
	value := float64(0)
	if enabled {
		value = 1
	}
	moduleStatus.WithLabelValues(module).Set(value)
}

// RecordNFTCLI records an nft CLI command execution
func RecordNFTCLI(operation string, durationSec float64, err error) {
	nftCLIDuration.WithLabelValues(operation).Observe(durationSec)
	if err != nil {
		nftCLIErrorsTotal.WithLabelValues(operation, "execution_error").Inc()
	}
}

// =============================================================================
// Helper Functions
// =============================================================================

func statusCodeString(code int) string {
	switch {
	case code >= 200 && code < 300:
		return "2xx"
	case code >= 300 && code < 400:
		return "3xx"
	case code >= 400 && code < 500:
		return "4xx"
	case code >= 500:
		return "5xx"
	default:
		return "unknown"
	}
}

// =============================================================================
// Metrics Registration with Global Sampler
// =============================================================================

var registerOnce sync.Once

// RegisterWithSampler registers all nftban metrics with the global sampler's registry
// This should be called once during application startup
func RegisterWithSampler() {
	registerOnce.Do(func() {
		sampler := GetSampler()
		if sampler == nil {
			return
		}

		registry := sampler.Registry()
		if registry == nil {
			return
		}

		// Note: promauto already registers with default registry
		// If you need custom registry, use prometheus.NewCounterVec instead of promauto
		// and register manually here
	})
}
