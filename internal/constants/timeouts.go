// =============================================================================
// NFTBan v1.29.0 - Centralized Timeout & Interval Constants
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="constants/timeouts"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Centralized timeout, interval, and duration constants"
// meta:inventory.files="timeouts.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// Package constants provides centralized timeout, interval, and duration
// constants used across the NFTBan codebase. Extracting these from inline
// literals makes them discoverable, auditable, and consistently named.
//
// Naming convention:
//
//	{Module}{Purpose}{Unit}  e.g. BotguardLoopInterval, WatchdogBaseInterval
//
// All values are time.Duration. Use these instead of inline N * time.Second.
package constants

import "time"

// =============================================================================
// Watchdog intervals and cooldowns
// =============================================================================

const (
	// WatchdogBaseInterval is the fundamental tick for the watchdog loop.
	WatchdogBaseInterval = 5 * time.Second

	// WatchdogProcessInterval is how often process metrics are collected.
	WatchdogProcessInterval = 5 * time.Second

	// WatchdogSystemInterval is how often system metrics are collected.
	WatchdogSystemInterval = 5 * time.Second

	// WatchdogKernelInterval is how often kernel metrics are collected.
	WatchdogKernelInterval = 5 * time.Second

	// WatchdogNFTSetInterval is how often nft set sizes are sampled.
	WatchdogNFTSetInterval = 10 * time.Second

	// WatchdogNFTRulesetInterval is how often the full ruleset is scanned.
	WatchdogNFTRulesetInterval = 30 * time.Second

	// WatchdogTopProcessesInterval is how often top-N processes are sampled.
	WatchdogTopProcessesInterval = 30 * time.Second

	// WatchdogRecorderSnapshotInterval is how often flight recorder snapshots are taken.
	WatchdogRecorderSnapshotInterval = 60 * time.Second

	// WatchdogAlertThrottle prevents repeated alerts within this window.
	WatchdogAlertThrottle = 5 * time.Minute

	// WatchdogProfileCPUCooldown is the minimum gap between CPU profiles.
	WatchdogProfileCPUCooldown = 15 * time.Minute

	// WatchdogProfileHeapCooldown is the minimum gap between heap profiles.
	WatchdogProfileHeapCooldown = 30 * time.Minute

	// WatchdogProfileGoroutineCooldown is the minimum gap between goroutine profiles.
	WatchdogProfileGoroutineCooldown = 5 * time.Minute

	// WatchdogProfileCPUDuration is how long a CPU profile runs.
	WatchdogProfileCPUDuration = 30 * time.Second

	// WatchdogFreeOSMemoryCooldown is the minimum gap between FreeOSMemory calls.
	WatchdogFreeOSMemoryCooldown = 10 * time.Minute

	// WatchdogHysteresisWarnExit is the duration to wait before exiting WARN state.
	WatchdogHysteresisWarnExit = 30 * time.Second

	// WatchdogHysteresisCritExit is the duration to wait before exiting CRITICAL state.
	WatchdogHysteresisCritExit = 60 * time.Second

	// WatchdogMinNFTRulesetInterval is the floor for ruleset scan interval.
	WatchdogMinNFTRulesetInterval = 5 * time.Second

	// WatchdogMinCooldown is the floor for profiling cooldowns.
	WatchdogMinCooldown = time.Minute

	// WatchdogMinFreeOSCooldown is the floor for FreeOSMemory cooldown.
	WatchdogMinFreeOSCooldown = 5 * time.Minute
)

// =============================================================================
// Botguard intervals, TTLs, and timeouts
// =============================================================================

const (
	// BotguardLoopInterval is the Go classify loop tick (Clock 2).
	// v1.38.0 evaluation: 30s would halve detection latency but doubles CPU cost.
	// Keep 60s default; operators needing faster response can set
	// HTTP_BOT_FAST_LOOP_INTERVAL=30 in botguard/main.conf.local.
	BotguardLoopInterval = 60 * time.Second

	// BotguardLoopPressureInterval is the loop tick under pressure.
	BotguardLoopPressureInterval = 40 * time.Second

	// BotguardSuspectTimeout is how long an IP stays in the suspect set.
	BotguardSuspectTimeout = 5 * time.Minute

	// BotguardAllowTTL is how long a verified-good IP stays allowed.
	BotguardAllowTTL = 24 * time.Hour

	// BotguardBanTTL is how long a confirmed-bad IP stays banned.
	BotguardBanTTL = 96 * time.Hour

	// BotguardGreyTTL is how long an unclassified IP stays in grey.
	BotguardGreyTTL = 30 * time.Minute

	// BotguardEmergencyTTL is how long an emergency-blocked IP stays blocked.
	BotguardEmergencyTTL = 30 * time.Minute

	// BotguardPendingTTL is how long an IP stays in the pending set.
	BotguardPendingTTL = 60 * time.Second

	// BotguardBatchInterval is how often the botscan batch runs (Clock 3).
	BotguardBatchInterval = 10 * time.Minute

	// BotguardVerifyTimeout is the FCrDNS verification timeout per IP.
	BotguardVerifyTimeout = 3 * time.Second

	// BotguardVerifyCacheTTL is how long a positive verification is cached.
	BotguardVerifyCacheTTL = 24 * time.Hour

	// BotguardVerifyNegTTL is how long a negative verification is cached.
	BotguardVerifyNegTTL = 1 * time.Hour

	// BotguardCleanupInterval is how often stale entries are cleaned up.
	BotguardCleanupInterval = 5 * time.Minute

	// BotguardStaleThreshold is the age after which an entry is considered stale.
	BotguardStaleThreshold = 30 * time.Minute

	// BotguardCmdTimeout is the timeout for nft command execution.
	BotguardCmdTimeout = 5 * time.Second
)

// =============================================================================
// Portscan intervals
// =============================================================================

const (
	// PortscanCheckInterval is the default check interval.
	PortscanCheckInterval = 60 * time.Second

	// PortscanBanDuration is the default ban duration for scan sources.
	PortscanBanDuration = 30 * time.Minute

	// PortscanTrackWindow is the default window for tracking scan events.
	PortscanTrackWindow = 5 * time.Minute
)

// =============================================================================
// Login monitor intervals
// =============================================================================

const (
	// LoginmonCheckInterval is the default check interval for login monitor.
	LoginmonCheckInterval = 10 * time.Second

	// LoginmonBanDuration is the default ban duration for brute force.
	LoginmonBanDuration = 30 * time.Minute

	// LoginmonTrackWindow is the tracking window for login attempts.
	LoginmonTrackWindow = 10 * time.Minute

	// LoginmonCooldown is the cooldown between repeated bans of the same IP.
	LoginmonCooldown = 5 * time.Minute

	// LoginmonTempBanDuration is the default temporary ban duration.
	LoginmonTempBanDuration = 15 * time.Minute

	// LoginmonScoreDecayInterval is how often IP scores are decayed.
	LoginmonScoreDecayInterval = 5 * time.Minute

	// LoginmonIPRetention is how long IP entries are retained.
	LoginmonIPRetention = 24 * time.Hour

	// LoginmonEVEPollInterval is how often EVE JSON lines are polled.
	LoginmonEVEPollInterval = 100 * time.Millisecond

	// LoginmonCleanupInterval is how often stale IP entries are cleaned up.
	LoginmonCleanupInterval = 1 * time.Hour

	// LoginmonHighRiskDuration is the ban duration for high-risk IPs.
	LoginmonHighRiskDuration = 24 * time.Hour

	// LoginmonMediumRiskDuration is the ban duration for medium-risk IPs.
	LoginmonMediumRiskDuration = 1 * time.Hour

	// LoginmonLowRiskDuration is the ban duration for low-risk IPs.
	LoginmonLowRiskDuration = 10 * time.Minute

	// LoginmonFailureWindow is the window for counting failed login attempts.
	LoginmonFailureWindow = 10 * time.Minute

	// LoginmonProfileRetention is how long login profiles are retained.
	LoginmonProfileRetention = 30 * 24 * time.Hour

	// LoginmonRecentBanWindow is the minimum gap to suppress duplicate bans.
	LoginmonRecentBanWindow = 10 * time.Second

	// LoginmonRecentBanMaxWindow is the maximum suppress window for bans.
	LoginmonRecentBanMaxWindow = 5 * time.Minute
)

// =============================================================================
// Suricata intervals
// =============================================================================

const (
	// SuricataDecayInterval is how often scorer decay runs.
	SuricataDecayInterval = 1 * time.Minute

	// SuricataStatsInterval is how often stats are collected.
	SuricataStatsInterval = 30 * time.Second

	// SuricataDefaultBanTime is the default ban duration for suricata alerts.
	SuricataDefaultBanTime = 30 * time.Minute

	// SuricataScoreDecay is the default score decay period.
	SuricataScoreDecay = 1 * time.Hour

	// SuricataEVEPollInterval is how often EVE JSON is polled.
	SuricataEVEPollInterval = 100 * time.Millisecond
)

// =============================================================================
// OpQueue / batch processing
// =============================================================================

const (
	// OpQueueFlushInterval is the default flush interval for the operation queue.
	OpQueueFlushInterval = 100 * time.Millisecond

	// OpQueueInitialDelay is the initial backoff delay for retries.
	OpQueueInitialDelay = 10 * time.Millisecond

	// OpQueueMaxDelay is the maximum backoff delay for retries.
	OpQueueMaxDelay = 500 * time.Millisecond

	// OpQueueSourceIndexInterval is how often the source index refreshes.
	OpQueueSourceIndexInterval = 30 * time.Second
)

// =============================================================================
// IPC timeouts
// =============================================================================

const (
	// IPCFastTimeout is the timeout for quick status queries.
	IPCFastTimeout = 5 * time.Second

	// IPCMediumTimeout is the timeout for ban/unban/search operations.
	IPCMediumTimeout = 30 * time.Second

	// IPCSlowTimeout is the timeout for sync/health/feed operations.
	IPCSlowTimeout = 120 * time.Second
)

// =============================================================================
// Stats / exporters
// =============================================================================

const (
	// StatsCollectInterval is the default interval for stats collection.
	StatsCollectInterval = 60 * time.Second

	// StatsLiveInterval is the default live stats collection interval.
	StatsLiveInterval = 60 * time.Second

	// StatsIOInterval is the default I/O stats collection interval.
	StatsIOInterval = 300 * time.Second

	// StatsMinLiveInterval is the minimum live stats interval.
	StatsMinLiveInterval = 10 * time.Second

	// StatsMinIOInterval is the minimum I/O stats interval.
	StatsMinIOInterval = 60 * time.Second

	// StatsRetention is the default retention period for stats.
	StatsRetention = 24 * time.Hour

	// ZabbixSendTimeout is the timeout for Zabbix sender operations.
	ZabbixSendTimeout = 30 * time.Second

	// ZabbixCollectInterval is how often metrics are sent to Zabbix.
	ZabbixCollectInterval = 60 * time.Second

	// ZabbixBatchTimeout is the timeout for Zabbix batch sends.
	ZabbixBatchTimeout = 5 * time.Second

	// ZabbixConnectTimeout is the timeout for Zabbix connections.
	ZabbixConnectTimeout = 10 * time.Second

	// ZabbixRetryInterval is the interval between retries.
	ZabbixRetryInterval = 5 * time.Second

	// ZabbixDiscoveryInterval is how often Zabbix LLD discovery runs.
	ZabbixDiscoveryInterval = 3600 * time.Second

	// ElasticsearchFlushInterval is how often ES bulk writes are flushed.
	ElasticsearchFlushInterval = 5 * time.Second

	// ElasticsearchHTTPTimeout is the HTTP client timeout for ES.
	ElasticsearchHTTPTimeout = 30 * time.Second

	// ElasticsearchIdleConnTimeout is the idle connection timeout for ES.
	ElasticsearchIdleConnTimeout = 90 * time.Second

	// KafkaDialTimeout is the dial timeout for Kafka brokers.
	KafkaDialTimeout = 10 * time.Second

	// KafkaFlushInterval is how often Kafka batches are flushed.
	KafkaFlushInterval = 5 * time.Second

	// KafkaWriteTimeout is the write timeout for Kafka producers.
	KafkaWriteTimeout = 30 * time.Second

	// KafkaReadTimeout is the read timeout for Kafka consumers.
	KafkaReadTimeout = 30 * time.Second
)

// =============================================================================
// Persistent ban / filter defaults
// =============================================================================

const (
	// PersistentDefaultPeriod is the default global ban period.
	PersistentDefaultPeriod = 24 * time.Hour
)

// =============================================================================
// Daemon / HTTP / UI
// =============================================================================

const (
	// DaemonShutdownTimeout is how long the daemon waits for graceful shutdown.
	DaemonShutdownTimeout = 30 * time.Second

	// DaemonStartupWait is how long to wait for daemon to fully start.
	DaemonStartupWait = 5 * time.Second

	// ReconciliationLockTimeout is the timeout for acquiring the nft lock during reconciliation.
	ReconciliationLockTimeout = 30 * time.Second

	// HTTPReadTimeout is the read timeout for HTTP servers.
	HTTPReadTimeout = 30 * time.Second

	// HTTPWriteTimeout is the write timeout for HTTP servers.
	HTTPWriteTimeout = 60 * time.Second

	// HTTPIdleTimeout is the idle timeout for HTTP servers.
	HTTPIdleTimeout = 120 * time.Second

	// SSEKeepAliveInterval is how often SSE keepalive pings are sent.
	SSEKeepAliveInterval = 30 * time.Second
)

// =============================================================================
// Sync / nft backend
// =============================================================================

const (
	// NFTCommandTimeout is the timeout for nft command execution.
	NFTCommandTimeout = 30 * time.Second

	// SyncOperationTimeout is the timeout for sync operations.
	SyncOperationTimeout = 120 * time.Second
)

// =============================================================================
// Metrics sampling
// =============================================================================

const (
	// MetricsSampleInterval is the default metrics sampling interval.
	MetricsSampleInterval = 10 * time.Second
)
