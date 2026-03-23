// =============================================================================
// NFTBan v1.0 - Memory Limits Configuration
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="memory_limits"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Memory limits and caps for CWE-400 prevention"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package safety

// MemoryLimits holds caps and TTLs to prevent unbounded memory growth (CWE-400)
// All limits are configurable via environment variables with sane defaults.
type MemoryLimits struct {
	// Scorer limits (internal/suricata/scorer.go)
	ScorerMaxIPs         int // Max unique IPs tracked in scorer (default: 50000)
	ScorerMaxEventsPerIP int // Max event timestamps per IP (default: 100)

	// Analytics limits (internal/analytics/state.go)
	AnalyticsMaxIPOrigins     int // Max IPs in ipOrigins map (default: 100000)
	AnalyticsMaxIPsPerCountry int // Max IPs per country (default: 10000)

	// Stats cache limits (internal/suricata/stats/cache.go)
	StatsMaxSIDs             int // Max SIDs tracked (default: 10000)
	StatsMaxSourcesPerSID    int // Max unique sources per SID (default: 1000)

	// Queue limits (cli/lib/nftban/helpers/nftban_task_queue.sh)
	QueueMaxPending      int // Max pending tasks (default: 10000)
	QueueDLQAutoRetention int // Auto-purge DLQ entries older than N days (default: 7)
}

// DefaultMemoryLimits returns production-safe defaults
func DefaultMemoryLimits() MemoryLimits {
	return MemoryLimits{
		// Scorer: 50k IPs * ~200 bytes/IP ≈ 10MB
		ScorerMaxIPs:         getEnvInt("NFTBAN_SCORER_MAX_IPS", 50000),
		ScorerMaxEventsPerIP: getEnvInt("NFTBAN_SCORER_MAX_EVENTS_PER_IP", 100),

		// Analytics: 100k IPs * ~100 bytes ≈ 10MB
		AnalyticsMaxIPOrigins:     getEnvInt("NFTBAN_ANALYTICS_MAX_IP_ORIGINS", 100000),
		AnalyticsMaxIPsPerCountry: getEnvInt("NFTBAN_ANALYTICS_MAX_IPS_PER_COUNTRY", 10000),

		// Stats: 10k SIDs * 1k sources * 16 bytes ≈ 160MB max
		StatsMaxSIDs:          getEnvInt("NFTBAN_STATS_MAX_SIDS", 10000),
		StatsMaxSourcesPerSID: getEnvInt("NFTBAN_STATS_MAX_SOURCES_PER_SID", 1000),

		// Queue
		QueueMaxPending:       getEnvInt("NFTBAN_QUEUE_MAX_PENDING", 10000),
		QueueDLQAutoRetention: getEnvInt("NFTBAN_QUEUE_DLQ_AUTO_RETENTION_DAYS", 7),
	}
}

// Global instance for easy access
var memLimits = DefaultMemoryLimits()

// GetMemoryLimits returns the global memory limits
func GetMemoryLimits() MemoryLimits {
	return memLimits
}

// ReloadMemoryLimits reloads limits from environment (for testing/config changes)
func ReloadMemoryLimits() {
	memLimits = DefaultMemoryLimits()
}
