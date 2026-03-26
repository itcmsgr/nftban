// =============================================================================
// NFTBan - Prometheus Metrics
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Prometheus metrics for ban/unban, feeds, sync, and auth operations"
// meta:input="Metric recording calls"
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

// Package metrics provides Prometheus metrics for NFTBan operations
// This file contains application-level metrics for ban/unban operations,
// feed loading, sync operations, and authentication
package metrics

import (
	"sync"
	"time"

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

	// v1.19.28: Queue drop metrics for observability
	// These track event loss in internal queues - critical for reliability monitoring
	opqueueDropsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "opqueue_drops_total",
		Help:      "Total operations dropped due to queue backpressure",
	}, []string{"lane"}) // lane: fast, bulk

	eventbusDropsTotal = promauto.NewCounter(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "eventbus_drops_total",
		Help:      "Total events dropped from EventBus due to backpressure",
	})

	// Queue utilization gauges - for alerting before saturation
	opqueueUtilization = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "opqueue_utilization_percent",
		Help:      "Queue utilization percentage (100 = full, drops occurring)",
	}, []string{"lane"}) // lane: fast, bulk

	// v1.40.0: Feed staleness tracking — per-feed last-success timestamp and stale flag
	feedLastSuccessTimestamp = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "feed_last_success_timestamp",
		Help:      "Unix timestamp of last successful feed file load (from file mtime)",
	}, []string{"feed"})

	feedStale = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "feed_stale",
		Help:      "Whether feed data is stale (1=stale, 0=fresh). Stale = file mtime older than threshold",
	}, []string{"feed"})

	// v1.40.0: Ban enforcement latency — time from enqueue to nftables insertion
	banEnforcementLatency = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Namespace: "nftban",
		Name:      "ban_enforcement_latency_seconds",
		Help:      "Time from ban enqueue to nftables element insertion",
		Buckets:   prometheus.ExponentialBuckets(0.0001, 2, 16), // 0.1ms to ~3.2s
	}, []string{"op"}) // op: add, delete, flush

	// v1.40.0: Pipeline event accounting — generated vs applied for gap detection
	eventsGeneratedTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "events_generated_total",
		Help:      "Total events published to eventbus",
	}, []string{"type"}) // type: ban, unban, feed_sync, etc.

	eventsAppliedTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "events_applied_total",
		Help:      "Total operations applied to nftables via opqueue",
	}, []string{"lane"}) // lane: fast, bulk

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

	// =============================================================================
	// Loginmon Module Metrics
	// =============================================================================

	loginmonDetectionsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Subsystem: "loginmon",
		Name:      "detections_total",
		Help:      "Total login failure detections",
	}, []string{"reason", "service"}) // reason: ssh_invalid_user, ssh_root_attempt, etc.

	loginmonBansTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Subsystem: "loginmon",
		Name:      "bans_total",
		Help:      "Total bans triggered by loginmon",
	}, []string{"family", "reason"}) // family: ipv4, ipv6

	loginmonTrackedIPs = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Subsystem: "loginmon",
		Name:      "tracked_ips",
		Help:      "Number of IPs currently being tracked/scored",
	})

	loginmonScoreHistogram = promauto.NewHistogram(prometheus.HistogramOpts{
		Namespace: "nftban",
		Subsystem: "loginmon",
		Name:      "score_at_ban",
		Help:      "Score distribution when bans are triggered",
		Buckets:   []float64{45, 50, 65, 75, 100, 150, 200}, // threshold buckets
	})

	loginmonDetectionLatency = promauto.NewHistogram(prometheus.HistogramOpts{
		Namespace: "nftban",
		Subsystem: "loginmon",
		Name:      "detection_latency_seconds",
		Help:      "Time from log event to detection processing",
		Buckets:   prometheus.ExponentialBuckets(0.0001, 2, 12), // 0.1ms to ~400ms
	})

	// =============================================================================
	// Portscan Module Metrics
	// =============================================================================

	portscanDetectionsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Subsystem: "portscan",
		Name:      "detections_total",
		Help:      "Total port scan detections",
	}, []string{"protocol"}) // protocol: tcp, udp

	portscanTrackedIPs = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Subsystem: "portscan",
		Name:      "tracked_ips",
		Help:      "Number of IPs currently being tracked for port scanning",
	})

	portscanBansTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Subsystem: "portscan",
		Name:      "bans_total",
		Help:      "Total bans triggered by portscan detection",
	}, []string{"family"})

	// =============================================================================
	// DDoS Module Metrics
	// =============================================================================

	ddosDetectionsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Subsystem: "ddos",
		Name:      "detections_total",
		Help:      "Total DDoS attack detections",
	}, []string{"attack_type"}) // attack_type: syn_flood, icmp_flood, udp_flood, etc.

	ddosMitigationsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Subsystem: "ddos",
		Name:      "mitigations_total",
		Help:      "Total DDoS mitigation actions taken",
	}, []string{"action"}) // action: rate_limit, block, drop

	ddosActiveMitigations = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Subsystem: "ddos",
		Name:      "active_mitigations",
		Help:      "Number of currently active DDoS mitigations",
	})

	// =============================================================================
	// Suricata Module Metrics
	// =============================================================================

	suricataEventsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Subsystem: "suricata",
		Name:      "events_total",
		Help:      "Total Suricata events processed from eve.json",
	}, []string{"event_type"}) // event_type: alert, anomaly, dns, flow, http, etc.

	suricataBansTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Subsystem: "suricata",
		Name:      "bans_total",
		Help:      "Total bans triggered by Suricata alerts",
	}, []string{"category", "family"}) // category: ET SCAN, ET EXPLOIT, etc. family: ipv4, ipv6

	suricataEveLagSeconds = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Subsystem: "suricata",
		Name:      "eve_lag_seconds",
		Help:      "Seconds since last EVE log event (freshness indicator)",
	})

	suricataProcessingLatency = promauto.NewHistogram(prometheus.HistogramOpts{
		Namespace: "nftban",
		Subsystem: "suricata",
		Name:      "processing_latency_seconds",
		Help:      "Time from EVE event to ban action",
		Buckets:   prometheus.ExponentialBuckets(0.001, 2, 12), // 1ms to ~4s
	})

	suricataAlertsActive = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Subsystem: "suricata",
		Name:      "alerts_active",
		Help:      "Number of IPs currently tracked from Suricata alerts",
	})

	// =============================================================================
	// IPC Metrics
	// =============================================================================

	ipcRequestsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Subsystem: "ipc",
		Name:      "requests_total",
		Help:      "Total IPC requests to nftband daemon",
	}, []string{"method", "status"}) // method: ban, unban, sync, etc. status: success, error

	ipcLatency = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Namespace: "nftban",
		Subsystem: "ipc",
		Name:      "latency_seconds",
		Help:      "IPC request latency in seconds",
		Buckets:   prometheus.ExponentialBuckets(0.0001, 2, 14), // 0.1ms to ~1.6s
	}, []string{"method"})

	// IPC Connection Metrics (for bottleneck identification)
	ipcConnectionsActive = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Subsystem: "ipc",
		Name:      "connections_active",
		Help:      "Number of currently active IPC connections (0 to max concurrent)",
	})

	ipcConnectionsRejectedTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Subsystem: "ipc",
		Name:      "connections_rejected_total",
		Help:      "Total IPC connections rejected by reason",
	}, []string{"reason"}) // reason: at_capacity, auth_failed, read_error

	ipcConnectionWaitSeconds = promauto.NewHistogram(prometheus.HistogramOpts{
		Namespace: "nftban",
		Subsystem: "ipc",
		Name:      "connection_wait_seconds",
		Help:      "Time spent waiting for semaphore slot before processing",
		Buckets:   prometheus.ExponentialBuckets(0.0001, 2, 12), // 0.1ms to ~400ms
	})

	ipcSemaphoreAvailable = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Subsystem: "ipc",
		Name:      "semaphore_available",
		Help:      "Number of available IPC semaphore slots (max - active)",
	})

	ipcConnectionsPeak = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Subsystem: "ipc",
		Name:      "connections_peak",
		Help:      "Peak concurrent connections since last reset (high water mark)",
	})

	// =============================================================================
	// Active Bans Gauge
	// =============================================================================

	activeBans = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "active_bans",
		Help:      "Number of currently active bans (real-time count)",
	}, []string{"family", "type"}) // family: ipv4, ipv6. type: temp, permanent, feed

	// =============================================================================
	// GeoIP Metrics
	// =============================================================================

	bansByCountry = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "bans_by_country_total",
		Help:      "Total bans by country code",
	}, []string{"country"}) // ISO 3166-1 alpha-2 country code

	detectionsCountry = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "detections_by_country_total",
		Help:      "Total detections by country code",
	}, []string{"country", "module"}) // module: loginmon, portscan, ddos

	// =============================================================================
	// Error Metrics
	// =============================================================================

	errorsTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "errors_total",
		Help:      "Total errors by module and type",
	}, []string{"module", "error_type"}) // module: loginmon, portscan, ddos, ipc, etc.

	// =============================================================================
	// Memory Protection Metrics
	// =============================================================================

	protectionActive = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "protection_active",
		Help:      "1 if memory protection triggered, 0 otherwise",
	})

	protectionFeedsSkipped = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "protection_feeds_skipped",
		Help:      "1 if feeds were skipped due to memory, 0 otherwise",
	})

	protectionGeobanSkipped = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "protection_geoban_skipped",
		Help:      "1 if geoban was skipped due to memory, 0 otherwise",
	})

	// =============================================================================
	// Memory Pressure Metrics
	// =============================================================================

	memoryPressureLevel = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "memory_pressure_level",
		Help:      "Memory pressure level: 0=normal, 1=warning, 2=high, 3=critical",
	})

	memoryBudgetBytes = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "memory_budget_bytes",
		Help:      "Configured memory budget for daemon in bytes",
	})

	memoryUsedPercent = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "memory_used_percent",
		Help:      "Current memory usage as percentage of budget",
	})

	// =============================================================================
	// Permanent Ban Tracking Metrics
	// =============================================================================

	permanentBansTotal = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "permanent_bans_total",
		Help:      "Total permanent bans tracked",
	})

	permanentBansProtected = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "permanent_bans_protected",
		Help:      "Bans marked as never evict",
	})

	permanentBansEvictable = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "permanent_bans_evictable",
		Help:      "Bans eligible for cleanup (>30 days, unprotected)",
	})

	// =============================================================================
	// CIDR Limit Metrics
	// =============================================================================

	cidrLimitHard = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "cidr_limit_hard",
		Help:      "Maximum CIDRs allowed for this server tier",
	})

	cidrCurrentTotal = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "cidr_current_total",
		Help:      "Current total CIDRs loaded",
	})

	// =============================================================================
	// Reconciliation Metrics (v1.34.0)
	// =============================================================================

	reconciliationDuration = promauto.NewHistogram(prometheus.HistogramOpts{
		Namespace: "nftban",
		Name:      "reconciliation_duration_seconds",
		Help:      "Duration of periodic reconciliation cycle",
		Buckets:   prometheus.ExponentialBuckets(0.1, 2, 10),
	})

	reconciliationDriftTotal = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "reconciliation_drift_total",
		Help:      "Count difference between kernel and in-memory state per set",
	}, []string{"set"})

	reconciliationLastTimestamp = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "reconciliation_last_timestamp",
		Help:      "Unix timestamp of last reconciliation run",
	})

	reconciliationRunsTotal = promauto.NewCounter(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "reconciliation_runs_total",
		Help:      "Total number of reconciliation cycles completed",
	})

	// =============================================================================
	// Schema Validation Metrics (v1.34.0)
	// =============================================================================

	schemaValidationStatus = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "schema_validation_status",
		Help:      "Schema validation status (0=valid, 1=drifted)",
	})

	schemaErrorsTotal = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "schema_errors_total",
		Help:      "Number of schema validation errors detected",
	})

	// =============================================================================
	// Whitelist Overlap Metrics (v1.34.0)
	// =============================================================================

	whitelistOverlapCount = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "whitelist_overlap_count",
		Help:      "Number of IPs present in both whitelist and blacklist sets",
	})
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
// Loginmon Metrics Recording Functions
// =============================================================================

// RecordLoginmonDetection records a login failure detection
func RecordLoginmonDetection(reason, service string) {
	loginmonDetectionsTotal.WithLabelValues(reason, service).Inc()
}

// RecordLoginmonBan records a ban triggered by loginmon
func RecordLoginmonBan(family, reason string) {
	loginmonBansTotal.WithLabelValues(family, reason).Inc()
}

// SetLoginmonTrackedIPs sets the current number of tracked IPs
func SetLoginmonTrackedIPs(count int) {
	loginmonTrackedIPs.Set(float64(count))
}

// RecordLoginmonScoreAtBan records the score when a ban is triggered
func RecordLoginmonScoreAtBan(score float64) {
	loginmonScoreHistogram.Observe(score)
}

// RecordLoginmonDetectionLatency records detection processing latency
func RecordLoginmonDetectionLatency(latencySec float64) {
	loginmonDetectionLatency.Observe(latencySec)
}

// =============================================================================
// Portscan Metrics Recording Functions
// =============================================================================

// RecordPortscanDetection records a port scan detection
func RecordPortscanDetection(protocol string) {
	portscanDetectionsTotal.WithLabelValues(protocol).Inc()
}

// SetPortscanTrackedIPs sets the current number of IPs being tracked for port scanning
func SetPortscanTrackedIPs(count int) {
	portscanTrackedIPs.Set(float64(count))
}

// RecordPortscanBan records a ban triggered by portscan detection
func RecordPortscanBan(family string) {
	portscanBansTotal.WithLabelValues(family).Inc()
}

// =============================================================================
// DDoS Metrics Recording Functions
// =============================================================================

// RecordDDoSDetection records a DDoS attack detection
func RecordDDoSDetection(attackType string) {
	ddosDetectionsTotal.WithLabelValues(attackType).Inc()
}

// RecordDDoSMitigation records a DDoS mitigation action
func RecordDDoSMitigation(action string) {
	ddosMitigationsTotal.WithLabelValues(action).Inc()
}

// SetDDoSActiveMitigations sets the number of currently active mitigations
func SetDDoSActiveMitigations(count int) {
	ddosActiveMitigations.Set(float64(count))
}

// =============================================================================
// Suricata Metrics Recording Functions
// =============================================================================

// RecordSuricataEvent records a Suricata event from eve.json
func RecordSuricataEvent(eventType string) {
	suricataEventsTotal.WithLabelValues(eventType).Inc()
}

// RecordSuricataBan records a ban triggered by Suricata alert
func RecordSuricataBan(category, family string) {
	suricataBansTotal.WithLabelValues(category, family).Inc()
}

// SetSuricataEveLag sets the EVE log freshness (seconds since last event)
func SetSuricataEveLag(lagSeconds float64) {
	suricataEveLagSeconds.Set(lagSeconds)
}

// RecordSuricataProcessingLatency records time from EVE event to ban action
func RecordSuricataProcessingLatency(latencySec float64) {
	suricataProcessingLatency.Observe(latencySec)
}

// SetSuricataAlertsActive sets the number of IPs being tracked from alerts
func SetSuricataAlertsActive(count int) {
	suricataAlertsActive.Set(float64(count))
}

// =============================================================================
// IPC Metrics Recording Functions
// =============================================================================

// RecordIPCRequest records an IPC request with its status
func RecordIPCRequest(method string, success bool, latencySec float64) {
	status := "success"
	if !success {
		status = "error"
	}
	ipcRequestsTotal.WithLabelValues(method, status).Inc()
	ipcLatency.WithLabelValues(method).Observe(latencySec)
}

// SetIPCConnectionsActive sets the current number of active IPC connections
func SetIPCConnectionsActive(count int) {
	ipcConnectionsActive.Set(float64(count))
}

// RecordIPCRejection records an IPC connection rejection with reason
// Reasons: "at_capacity", "auth_failed", "read_error", "timeout"
func RecordIPCRejection(reason string) {
	ipcConnectionsRejectedTotal.WithLabelValues(reason).Inc()
}

// RecordIPCConnectionWait records time spent waiting for semaphore slot
func RecordIPCConnectionWait(waitSec float64) {
	ipcConnectionWaitSeconds.Observe(waitSec)
}

// SetIPCSemaphoreAvailable sets the number of available semaphore slots
func SetIPCSemaphoreAvailable(available int) {
	ipcSemaphoreAvailable.Set(float64(available))
}

// SetIPCConnectionsPeak sets the peak concurrent connections (high water mark)
func SetIPCConnectionsPeak(peak int) {
	ipcConnectionsPeak.Set(float64(peak))
}

// =============================================================================
// Active Bans Recording Functions
// =============================================================================

// SetActiveBans sets the current number of active bans
func SetActiveBans(family, banType string, count int) {
	activeBans.WithLabelValues(family, banType).Set(float64(count))
}

// =============================================================================
// GeoIP Metrics Recording Functions
// =============================================================================

// RecordBanByCountry records a ban for a specific country
func RecordBanByCountry(country string) {
	bansByCountry.WithLabelValues(country).Inc()
}

// RecordDetectionByCountry records a detection for a specific country and module
func RecordDetectionByCountry(country, module string) {
	detectionsCountry.WithLabelValues(country, module).Inc()
}

// =============================================================================
// Error Recording Functions
// =============================================================================

// RecordError records an error for a module
func RecordError(module, errorType string) {
	errorsTotal.WithLabelValues(module, errorType).Inc()
}

// =============================================================================
// Queue Observability Recording Functions (v1.19.28)
// =============================================================================
// These functions track event loss and queue pressure - critical for reliability

// RecordOpQueueDrop records a dropped operation due to queue backpressure
// lane should be "fast" (ban/unban) or "bulk" (feeds/geoban)
func RecordOpQueueDrop(lane string) {
	opqueueDropsTotal.WithLabelValues(lane).Inc()
}

// RecordEventBusDrop records a dropped event from the EventBus
func RecordEventBusDrop() {
	eventbusDropsTotal.Inc()
}

// SetOpQueueUtilization sets the current queue utilization percentage
// pending = current pending operations, capacity = max queue size
func SetOpQueueUtilization(lane string, pending, capacity int64) {
	if capacity > 0 {
		utilization := float64(pending) / float64(capacity) * 100
		opqueueUtilization.WithLabelValues(lane).Set(utilization)
	}
}

// =============================================================================
// Pipeline Accounting Functions (v1.40.0)
// =============================================================================
// Track events_generated vs events_applied to detect pipeline gaps

// RecordEventGenerated records an event published to the eventbus
func RecordEventGenerated(eventType string) {
	eventsGeneratedTotal.WithLabelValues(eventType).Inc()
}

// RecordEventsApplied records operations applied to nftables via opqueue
func RecordEventsApplied(lane string, count int) {
	eventsAppliedTotal.WithLabelValues(lane).Add(float64(count))
}

// =============================================================================
// Ban Enforcement Latency Recording Functions (v1.40.0)
// =============================================================================
// Track time from enqueue to nftables element insertion

// RecordBanEnforcementLatency records the latency of a ban enforcement operation
func RecordBanEnforcementLatency(op string, latencySec float64) {
	banEnforcementLatency.WithLabelValues(op).Observe(latencySec)
}

// =============================================================================
// Feed Staleness Recording Functions (v1.40.0)
// =============================================================================
// Track per-feed file freshness for alerting on stale threat intelligence

// DefaultFeedStaleThreshold is the default duration after which a feed is considered stale
const DefaultFeedStaleThreshold = 48 * time.Hour

// RecordFeedLastSuccess records the mtime of a successfully loaded feed file
func RecordFeedLastSuccess(feedName string, mtime time.Time) {
	feedLastSuccessTimestamp.WithLabelValues(feedName).Set(float64(mtime.Unix()))
}

// UpdateFeedStaleness checks all tracked feeds and sets the stale gauge
// based on whether the feed file mtime is older than the threshold
func UpdateFeedStaleness(feedName string, mtime time.Time, threshold time.Duration) {
	if threshold <= 0 {
		threshold = DefaultFeedStaleThreshold
	}
	if time.Since(mtime) > threshold {
		feedStale.WithLabelValues(feedName).Set(1)
	} else {
		feedStale.WithLabelValues(feedName).Set(0)
	}
}

// =============================================================================
// Memory Protection Recording Functions
// =============================================================================

// SetProtectionActive sets whether memory protection is currently triggered
func SetProtectionActive(active bool) {
	value := float64(0)
	if active {
		value = 1
	}
	protectionActive.Set(value)
}

// SetProtectionFeedsSkipped sets whether feeds were skipped due to memory pressure
func SetProtectionFeedsSkipped(skipped bool) {
	value := float64(0)
	if skipped {
		value = 1
	}
	protectionFeedsSkipped.Set(value)
}

// SetProtectionGeobanSkipped sets whether geoban was skipped due to memory pressure
func SetProtectionGeobanSkipped(skipped bool) {
	value := float64(0)
	if skipped {
		value = 1
	}
	protectionGeobanSkipped.Set(value)
}

// =============================================================================
// Memory Pressure Recording Functions
// =============================================================================

// SetMemoryPressureLevel sets the current memory pressure level
// Levels: 0=normal, 1=warning, 2=high, 3=critical
func SetMemoryPressureLevel(level int) {
	memoryPressureLevel.Set(float64(level))
}

// SetMemoryBudgetBytes sets the configured memory budget in bytes
func SetMemoryBudgetBytes(bytes int64) {
	memoryBudgetBytes.Set(float64(bytes))
}

// SetMemoryUsedPercent sets the current memory usage as a percentage of budget
func SetMemoryUsedPercent(percent float64) {
	memoryUsedPercent.Set(percent)
}

// =============================================================================
// Permanent Ban Tracking Recording Functions
// =============================================================================

// SetPermanentBansTotal sets the total number of permanent bans tracked
func SetPermanentBansTotal(count int) {
	permanentBansTotal.Set(float64(count))
}

// SetPermanentBansProtected sets the number of bans marked as "never evict"
func SetPermanentBansProtected(count int) {
	permanentBansProtected.Set(float64(count))
}

// SetPermanentBansEvictable sets the number of bans eligible for cleanup
func SetPermanentBansEvictable(count int) {
	permanentBansEvictable.Set(float64(count))
}

// =============================================================================
// CIDR Limit Recording Functions
// =============================================================================

// SetCIDRLimitHard sets the maximum CIDRs allowed for this server tier
func SetCIDRLimitHard(limit int) {
	cidrLimitHard.Set(float64(limit))
}

// SetCIDRCurrentTotal sets the current total CIDRs loaded
func SetCIDRCurrentTotal(count int) {
	cidrCurrentTotal.Set(float64(count))
}

// =============================================================================
// Reconciliation Recording Functions (v1.34.0)
// =============================================================================

// RecordReconciliationDuration records the duration of a reconciliation cycle
func RecordReconciliationDuration(seconds float64) {
	reconciliationDuration.Observe(seconds)
}

// SetReconciliationDrift sets the drift count for a specific set
func SetReconciliationDrift(setName string, drift float64) {
	reconciliationDriftTotal.WithLabelValues(setName).Set(drift)
}

// SetReconciliationLastTimestamp sets the timestamp of the last reconciliation
func SetReconciliationLastTimestamp(ts float64) {
	reconciliationLastTimestamp.Set(ts)
}

// RecordReconciliationRun increments the total reconciliation runs counter
func RecordReconciliationRun() {
	reconciliationRunsTotal.Inc()
}

// =============================================================================
// Schema Validation Recording Functions (v1.34.0)
// =============================================================================

// SetSchemaValidationStatus sets whether schema validation passed or failed
func SetSchemaValidationStatus(drifted bool) {
	val := float64(0)
	if drifted {
		val = 1
	}
	schemaValidationStatus.Set(val)
}

// SetSchemaErrorsTotal sets the number of schema errors detected
func SetSchemaErrorsTotal(count int) {
	schemaErrorsTotal.Set(float64(count))
}

// =============================================================================
// Whitelist Overlap Recording Functions (v1.34.0)
// =============================================================================

// SetWhitelistOverlapCount sets the number of overlapping IPs
func SetWhitelistOverlapCount(count int) {
	whitelistOverlapCount.Set(float64(count))
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
