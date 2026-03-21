// =============================================================================
// NFTBan - Global Metrics Sampler
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="sampler"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Global metrics sampler with Prometheus integration"
// meta:input="NFTBan status JSON, /proc/net/dev"
// meta:output="Prometheus metrics, sample ring buffer"
// meta:depends="github.com/prometheus/client_golang/prometheus"
// meta:inventory.files="/proc/net/dev"
// meta:inventory.binaries="nftban"
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package metrics

import (
	"bufio"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/pkg/nftbanconf"
	"github.com/itcmsgr/nftban/pkg/state"
	"github.com/prometheus/client_golang/prometheus"
)

// getMetricsPaths returns paths from central config for metrics collection
// NO FALLBACK - paths must come from /etc/nftban/nftban.conf
func getMetricsPaths() (configDir, dataDir string) {
	cfg := nftbanconf.MustLoad()
	return cfg.ConfigDir, cfg.DataDir
}

// Sample represents a single metrics snapshot
type Sample struct {
	Timestamp    time.Time              `json:"timestamp"`
	Version      string                 `json:"version"`
	BlockedIPs   int                    `json:"blocked_ips"`
	RuleCount    int                    `json:"rule_count"`
	HealthOK     bool                   `json:"health_ok"`
	FeedsActive  int                    `json:"feeds_active"`
	NetworkRxMbps float64               `json:"network_rx_mbps"`
	NetworkTxMbps float64               `json:"network_tx_mbps"`
	RawData      map[string]interface{} `json:"raw_data,omitempty"`
}

// Sampler manages global metrics collection
type Sampler struct {
	mu              sync.RWMutex
	running         bool
	metricsEnabled  bool
	activeSessions  int
	period          time.Duration
	maxSamples      int
	samples         []Sample
	lastSample      time.Time
	stopChan        chan struct{}
	ticker          *time.Ticker

	// Prometheus metrics
	registry          *prometheus.Registry
	blockedIPsGauge   prometheus.Gauge
	ruleCountGauge    prometheus.Gauge
	healthGauge       prometheus.Gauge
	feedsActiveGauge  prometheus.Gauge
	feedsTotalIPsGauge prometheus.Gauge
	sessionCountGauge prometheus.Gauge
	uptimeGauge       prometheus.Gauge
	networkRxGauge    prometheus.Gauge
	networkTxGauge    prometheus.Gauge

	// Additional comprehensive metrics
	// Removed: fail2ban gauges (v1.0 migration to Suricata)
	geobanCountriesGauge    prometheus.Gauge
	geobanRangesGauge       prometheus.Gauge
	blacklistIPsGauge       prometheus.Gauge
	whitelistIPsGauge       prometheus.Gauge
	portscanBlocksGauge     prometheus.Gauge
	ddosBlocksGauge         prometheus.Gauge
	nftablesActiveGauge     prometheus.Gauge
	// Removed: fail2banActiveGauge (v1.0 migration to Suricata)

	startTime        time.Time

	// Network traffic tracking
	lastRxBytes uint64
	lastTxBytes uint64
	lastNetCheck time.Time
}

var (
	globalSampler *Sampler
	samplerOnce   sync.Once
)

// GetSampler returns the global sampler instance (singleton)
func GetSampler() *Sampler {
	samplerOnce.Do(func() {
		// Get sampling config from central config
		// NO FALLBACK - values must come from /etc/nftban/nftban.conf
		cfg := nftbanconf.MustLoad()
		samplingInterval := cfg.MetricsSamplingInterval
		if samplingInterval <= 0 {
			samplingInterval = 10 // default 10 seconds if not set
		}
		maxSamples := cfg.MetricsMaxSamples
		if maxSamples <= 0 {
			maxSamples = 360 // default 1 hour at 10s if not set
		}

		globalSampler = &Sampler{
			period:     time.Duration(samplingInterval) * time.Second,
			maxSamples: maxSamples,
			samples:    make([]Sample, 0, maxSamples),
			stopChan:   make(chan struct{}),
			startTime:  time.Now(),
		}
		globalSampler.initPrometheus()
		log.Printf("[METRICS] Global sampler initialized (%ds period, max %d samples)", samplingInterval, maxSamples)
	})
	return globalSampler
}

// initPrometheus initializes Prometheus metrics
func (s *Sampler) initPrometheus() {
	s.registry = prometheus.NewRegistry()

	s.blockedIPsGauge = prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "blocked_ips_total",
		Help:      "Total number of blocked IPs in firewall",
	})

	s.ruleCountGauge = prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "firewall_rules_total",
		Help:      "Total number of firewall rules",
	})

	// BUG-001 FIX: Aligned semantics with collector.go (0=OK, higher=worse)
	// This matches standard Prometheus conventions where 0 = healthy
	s.healthGauge = prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "health_status",
		Help:      "Health status (0=OK, 1=WARN, 2=ERROR, 3=CRITICAL)",
	})

	s.feedsActiveGauge = prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "feeds_active_total",
		Help:      "Number of active threat feeds",
	})

	s.sessionCountGauge = prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "active_sessions_total",
		Help:      "Number of active user sessions",
	})

	s.uptimeGauge = prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "uptime_seconds",
		Help:      "Service uptime in seconds",
	})

	s.networkRxGauge = prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "network_rx_mbps",
		Help:      "Network receive rate in Mbps",
	})

	s.networkTxGauge = prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "network_tx_mbps",
		Help:      "Network transmit rate in Mbps",
	})

	s.feedsTotalIPsGauge = prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "feeds_total_ips",
		Help:      "Total IPs from all active threat feeds",
	})

	// Removed: fail2ban gauge initialization (v1.0 migration to Suricata)

	s.geobanCountriesGauge = prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "geoban_countries_total",
		Help:      "Number of countries blocked by GeoBan",
	})

	s.geobanRangesGauge = prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "geoban_ranges_total",
		Help:      "Number of IP ranges blocked by GeoBan",
	})

	s.blacklistIPsGauge = prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "blacklist_ips_total",
		Help:      "Number of IPs in permanent blacklist",
	})

	s.whitelistIPsGauge = prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "whitelist_ips_total",
		Help:      "Number of IPs in whitelist",
	})

	s.portscanBlocksGauge = prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "portscan_blocks_total",
		Help:      "Number of IPs blocked by portscan detection",
	})

	s.ddosBlocksGauge = prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "ddos_blocks_total",
		Help:      "Number of IPs blocked by DDoS protection",
	})

	s.nftablesActiveGauge = prometheus.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "nftables_active",
		Help:      "NFTables service status (1=active, 0=inactive)",
	})

	// Removed: fail2banActiveGauge initialization (v1.0 migration to Suricata)

	s.registry.MustRegister(
		s.blockedIPsGauge,
		s.ruleCountGauge,
		s.healthGauge,
		s.feedsActiveGauge,
		s.feedsTotalIPsGauge,
		s.sessionCountGauge,
		s.uptimeGauge,
		s.networkRxGauge,
		s.networkTxGauge,
		// Removed: fail2ban gauge registrations (v1.0 migration to Suricata)
		s.geobanCountriesGauge,
		s.geobanRangesGauge,
		s.blacklistIPsGauge,
		s.whitelistIPsGauge,
		s.portscanBlocksGauge,
		s.ddosBlocksGauge,
		s.nftablesActiveGauge,
		// Removed: fail2banActiveGauge (v1.0 migration to Suricata)
	)
}

// Registry returns the Prometheus registry
func (s *Sampler) Registry() *prometheus.Registry {
	return s.registry
}

// AddSession increments active session count and starts sampling if needed
func (s *Sampler) AddSession() {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.activeSessions++
	log.Printf("[METRICS] Session added (total: %d)", s.activeSessions)

	// Start sampler if not running and we have sessions OR metrics enabled
	if !s.running && (s.activeSessions > 0 || s.metricsEnabled) {
		s.startLocked()
	}

	s.updateSessionCount()
}

// RemoveSession decrements active session count and stops sampling if needed
func (s *Sampler) RemoveSession() {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.activeSessions > 0 {
		s.activeSessions--
		log.Printf("[METRICS] Session removed (total: %d)", s.activeSessions)
	}

	// Stop sampler if no sessions and metrics disabled
	if s.running && s.activeSessions == 0 && !s.metricsEnabled {
		s.stopLocked()
	}

	s.updateSessionCount()
}

// EnableMetrics enables continuous sampling (overrides session-based logic)
func (s *Sampler) EnableMetrics() {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.metricsEnabled {
		log.Println("[METRICS] Already enabled")
		return
	}

	s.metricsEnabled = true
	log.Println("[METRICS] Metrics mode enabled (continuous sampling)")

	// Start sampler if not running
	if !s.running {
		s.startLocked()
	}
}

// DisableMetrics disables continuous sampling (back to session-based logic)
func (s *Sampler) DisableMetrics() {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.metricsEnabled {
		log.Println("[METRICS] Already disabled")
		return
	}

	s.metricsEnabled = false
	log.Println("[METRICS] Metrics mode disabled (back to session-based)")

	// Stop sampler if no active sessions
	if s.running && s.activeSessions == 0 {
		s.stopLocked()
	}
}

// IsMetricsEnabled returns whether continuous metrics mode is enabled
func (s *Sampler) IsMetricsEnabled() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.metricsEnabled
}

// GetStatus returns current sampler status
func (s *Sampler) GetStatus() map[string]interface{} {
	s.mu.RLock()
	defer s.mu.RUnlock()

	return map[string]interface{}{
		"running":          s.running,
		"metrics_enabled":  s.metricsEnabled,
		"active_sessions":  s.activeSessions,
		"period_seconds":   s.period.Seconds(),
		"samples_stored":   len(s.samples),
		"max_samples":      s.maxSamples,
		"last_sample":      s.lastSample,
		"uptime_seconds":   time.Since(s.startTime).Seconds(),
	}
}

// GetRecentSamples returns the most recent N samples
func (s *Sampler) GetRecentSamples(count int) []Sample {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if count <= 0 || count > len(s.samples) {
		count = len(s.samples)
	}
	if count > s.maxSamples {
		count = s.maxSamples
	}

	start := len(s.samples) - count
	result := make([]Sample, count)
	copy(result, s.samples[start:])
	return result
}

// startLocked starts the sampler (must be called with lock held)
func (s *Sampler) startLocked() {
	if s.running {
		return
	}

	log.Printf("[METRICS] Starting sampler (period: %v, sessions: %d, metrics: %v)",
		s.period, s.activeSessions, s.metricsEnabled)

	s.running = true
	s.ticker = time.NewTicker(s.period)

	// Take initial sample
	go s.takeSample()

	// Start sampling loop
	go s.run()
}

// stopLocked stops the sampler (must be called with lock held)
func (s *Sampler) stopLocked() {
	if !s.running {
		return
	}

	log.Println("[METRICS] Stopping sampler")
	s.running = false

	if s.ticker != nil {
		s.ticker.Stop()
	}

	select {
	case s.stopChan <- struct{}{}:
	default:
	}
}

// run is the main sampling loop
func (s *Sampler) run() {
	for {
		select {
		case <-s.ticker.C:
			s.takeSample()

		case <-s.stopChan:
			log.Println("[METRICS] Sampler stopped")
			return
		}
	}
}

// getNetworkStats reads /proc/net/dev and calculates RX/TX rates in Mbps
func (s *Sampler) getNetworkStats() (rxMbps, txMbps float64) {
	file, err := os.Open("/proc/net/dev")
	if err != nil {
		log.Printf("[METRICS] Failed to open /proc/net/dev: %v", err)
		return 0, 0
	}
	defer file.Close()

	var totalRxBytes, totalTxBytes uint64
	scanner := bufio.NewScanner(file)

	// Skip first two header lines
	scanner.Scan()
	scanner.Scan()

	for scanner.Scan() {
		line := scanner.Text()
		fields := strings.Fields(line)
		if len(fields) < 10 {
			continue
		}

		// Skip loopback interface
		iface := strings.TrimSuffix(fields[0], ":")
		if iface == "lo" {
			continue
		}

		// Parse RX bytes (field 1) and TX bytes (field 9)
		rxBytes, err := strconv.ParseUint(fields[1], 10, 64)
		if err != nil {
			continue
		}
		txBytes, err := strconv.ParseUint(fields[9], 10, 64)
		if err != nil {
			continue
		}

		totalRxBytes += rxBytes
		totalTxBytes += txBytes
	}

	// Calculate rates if we have previous data
	now := time.Now()
	if !s.lastNetCheck.IsZero() {
		elapsed := now.Sub(s.lastNetCheck).Seconds()
		if elapsed > 0 {
			// Calculate bytes per second, then convert to Mbps
			rxBytesPerSec := float64(totalRxBytes-s.lastRxBytes) / elapsed
			txBytesPerSec := float64(totalTxBytes-s.lastTxBytes) / elapsed

			// Convert to Mbps: bytes/sec * 8 / 1000000
			rxMbps = (rxBytesPerSec * 8) / 1000000
			txMbps = (txBytesPerSec * 8) / 1000000
		}
	}

	// Store current values for next calculation
	s.lastRxBytes = totalRxBytes
	s.lastTxBytes = totalTxBytes
	s.lastNetCheck = now

	return rxMbps, txMbps
}

// takeSample collects a single metrics snapshot
// TWO-TIER COLLECTION:
//   BASIC tier (always): reads from shared state (NO CLI calls)
//   FULL tier (when metricsEnabled): adds geoban, portscan, ddos via file/CLI
func (s *Sampler) takeSample() {
	start := time.Now()

	// Get network statistics (reads /proc/net/dev - fast, no CLI)
	rxMbps, txMbps := s.getNetworkStats()

	// ==========================================================================
	// BASIC TIER: Read from shared state (populated by watchdog via netlink)
	// NO CLI CALLS - zero overhead
	// ==========================================================================
	snap := state.Get()

	// Build sample from shared state
	sample := Sample{
		Timestamp:     time.Now(),
		NetworkRxMbps: rxMbps,
		NetworkTxMbps: txMbps,
		BlockedIPs:    int(snap.BannedIPv4 + snap.BannedIPv6),
		RuleCount:     int(snap.RulesTotal),
		FeedsActive:   snap.FeedsActive,
		HealthOK:      state.IsInitialized() && !state.IsStale(30*time.Second),
	}

	// Update BASIC Prometheus metrics
	s.blockedIPsGauge.Set(float64(sample.BlockedIPs))
	s.ruleCountGauge.Set(float64(sample.RuleCount))
	// BUG-001 FIX: Use 0=OK, 2=ERROR to match collector.go semantics
	if sample.HealthOK {
		s.healthGauge.Set(0) // 0 = OK (was: 1)
	} else {
		s.healthGauge.Set(2) // 2 = ERROR (was: 0)
	}
	s.feedsActiveGauge.Set(float64(sample.FeedsActive))
	s.feedsTotalIPsGauge.Set(float64(snap.FeedsIPs))
	s.uptimeGauge.Set(time.Since(s.startTime).Seconds())
	s.networkRxGauge.Set(sample.NetworkRxMbps)
	s.networkTxGauge.Set(sample.NetworkTxMbps)

	// Blacklist/whitelist from shared state (watchdog provides from netlink)
	s.blacklistIPsGauge.Set(float64(snap.BannedIPv4 + snap.BannedIPv6))
	s.whitelistIPsGauge.Set(float64(snap.WhitelistIPv4 + snap.WhitelistIPv6))

	// nftables is always active if we have data
	if state.IsInitialized() {
		s.nftablesActiveGauge.Set(1)
	} else {
		s.nftablesActiveGauge.Set(0)
	}

	// ==========================================================================
	// FULL TIER: Only when metricsEnabled (adds file reads and CLI calls)
	// ==========================================================================
	s.mu.RLock()
	fullMetrics := s.metricsEnabled
	s.mu.RUnlock()

	if fullMetrics {
		// Geoban: file reads only (no CLI)
		geobanCountries, geobanRanges := s.collectGeobanMetrics()
		s.geobanCountriesGauge.Set(float64(geobanCountries))
		s.geobanRangesGauge.Set(float64(geobanRanges))

		// Portscan and DDoS: CLI calls (only in FULL tier)
		portscanBlocks := s.collectPortscanMetrics()
		ddosBlocks := s.collectDDoSMetrics()
		s.portscanBlocksGauge.Set(float64(portscanBlocks))
		s.ddosBlocksGauge.Set(float64(ddosBlocks))
	}

	// Store sample in ring buffer
	s.mu.Lock()
	s.samples = append(s.samples, sample)
	if len(s.samples) > s.maxSamples {
		s.samples = s.samples[1:]
	}
	s.lastSample = sample.Timestamp
	s.mu.Unlock()

	duration := time.Since(start)
	tier := "BASIC"
	if fullMetrics {
		tier = "FULL"
	}
	log.Printf("[METRICS] Sample collected (%s tier) in %v (blocked=%d, rules=%d, feeds=%d)",
		tier, duration, sample.BlockedIPs, sample.RuleCount, sample.FeedsActive)
}

// updateSessionCount updates Prometheus session count gauge
func (s *Sampler) updateSessionCount() {
	s.sessionCountGauge.Set(float64(s.activeSessions))
}

// Removed: collectFeedsMetrics - now uses shared state from watchdog (NO CLI)
// Removed: collectFail2banMetrics function (v1.0 migration to Suricata)

// collectGeobanMetrics counts banned countries and IP ranges
func (s *Sampler) collectGeobanMetrics() (countries, ranges int) {
	// Count tracking files - use central config
	_, dataDir := getMetricsPaths()
	trackingDir := dataDir + "/geoban/tracking"
	entries, err := os.ReadDir(trackingDir)
	if err != nil {
		return 0, 0
	}

	countries = len(entries)

	// Count total ranges from all tracking files
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		filePath := trackingDir + "/" + entry.Name()
		data, err := os.ReadFile(filePath)
		if err != nil {
			continue
		}
		// Count non-empty lines
		lines := strings.Split(string(data), "\n")
		for _, line := range lines {
			if strings.TrimSpace(line) != "" {
				ranges++
			}
		}
	}
	return countries, ranges
}

// Removed: collectBlacklistMetrics - now uses shared state from watchdog (NO CLI/file reads)
// Removed: collectWhitelistMetrics - now uses shared state from watchdog (NO CLI/file reads)

// collectPortscanMetrics gets portscan blocks from stats
func (s *Sampler) collectPortscanMetrics() int {
	cmd := exec.Command("nftban", "portscan", "stats")
	output, err := cmd.Output()
	if err != nil {
		return 0
	}

	// Parse output for total blocks
	outputStr := string(output)
	if idx := strings.Index(outputStr, "Total blocks:"); idx >= 0 {
		start := idx + len("Total blocks:")
		end := strings.Index(outputStr[start:], "\n")
		if end > 0 {
			numStr := strings.TrimSpace(outputStr[start : start+end])
			if val, err := strconv.Atoi(numStr); err == nil {
				return val
			}
		}
	}
	return 0
}

// collectDDoSMetrics gets DDoS protection blocks
func (s *Sampler) collectDDoSMetrics() int {
	cmd := exec.Command("nftban", "ddos", "stats")
	output, err := cmd.Output()
	if err != nil {
		return 0
	}

	// Parse output for total blocks
	outputStr := string(output)
	if idx := strings.Index(outputStr, "Total blocks:"); idx >= 0 {
		start := idx + len("Total blocks:")
		end := strings.Index(outputStr[start:], "\n")
		if end > 0 {
			numStr := strings.TrimSpace(outputStr[start : start+end])
			if val, err := strconv.Atoi(numStr); err == nil {
				return val
			}
		}
	}
	return 0
}
