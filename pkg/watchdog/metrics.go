// =============================================================================
// NFTBan v1.0 - Watchdog Prometheus Metrics
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="metrics"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-01-15"
// meta:description="Prometheus metrics for the watchdog system"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Prometheus metrics for the watchdog system.
// All metrics use the "nftban_" namespace.
//
// =============================================================================

package watchdog

import (
	"github.com/itcmsgr/nftban/pkg/safety"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	// ==========================================================================
	// Pressure State Metrics
	// ==========================================================================

	// Pressure state per dimension (use label level="ok|warn|critical")
	pressureState = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "pressure_state",
		Help:      "Current pressure state per dimension (1=active, 0=inactive)",
	}, []string{"dim", "level"})

	// Pressure score per dimension (0-100)
	pressureScore = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "pressure_score",
		Help:      "Current pressure score per dimension (0-100)",
	}, []string{"dim"})

	// Current operating mode
	operatingMode = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "operating_mode",
		Help:      "Current operating mode (1=active)",
	}, []string{"mode"})

	// ==========================================================================
	// Action Metrics
	// ==========================================================================

	// Action counter
	actionTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Namespace: "nftban",
		Name:      "watchdog_action_total",
		Help:      "Total watchdog actions taken",
	}, []string{"action"})

	// Last action timestamp
	actionLastTimestamp = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "watchdog_last_action_timestamp_seconds",
		Help:      "Unix timestamp of last action",
	}, []string{"action"})

	// ==========================================================================
	// Process Metrics
	// ==========================================================================

	procRSSBytes = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "proc_rss_bytes",
		Help:      "Process resident set size in bytes",
	})

	procCPUPercent = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "proc_cpu_percent",
		Help:      "Process CPU usage percentage (smoothed)",
	})

	procFDOpen = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "proc_fd_open",
		Help:      "Number of open file descriptors",
	})

	procThreads = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "proc_threads",
		Help:      "Number of process threads",
	})

	// ==========================================================================
	// Go Runtime Metrics
	// ==========================================================================

	goGoroutines = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "go_goroutines",
		Help:      "Number of goroutines",
	})

	goGCCPUFraction = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "go_gc_cpu_fraction",
		Help:      "Fraction of CPU time spent in GC",
	})

	goGCPauseSeconds = promauto.NewHistogram(prometheus.HistogramOpts{
		Namespace: "nftban",
		Name:      "go_gc_pause_seconds",
		Help:      "GC pause duration histogram",
		Buckets:   prometheus.ExponentialBuckets(0.0001, 2, 15), // 100us to ~3s
	})

	goHeapAllocBytes = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "go_heap_alloc_bytes",
		Help:      "Heap allocation in bytes",
	})

	goHeapInuseBytes = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "go_heap_inuse_bytes",
		Help:      "Heap in-use in bytes",
	})

	goHeapReleasedBytes = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "go_heap_released_bytes",
		Help:      "Heap memory released to OS in bytes",
	})

	// ==========================================================================
	// Kernel/Netfilter Metrics
	// ==========================================================================

	conntrackUsed = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "conntrack_used",
		Help:      "Number of conntrack entries used",
	})

	conntrackMax = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "conntrack_max",
		Help:      "Maximum conntrack entries",
	})

	conntrackUtilization = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "conntrack_utilization",
		Help:      "Conntrack utilization (used/max)",
	})

	softnetDropsTotal = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "softnet_drops_total",
		Help:      "Total softnet drops across all CPUs",
	})

	softnetTimeSqueezeTotal = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "softnet_time_squeeze_total",
		Help:      "Total softnet time squeeze events",
	})

	nicRXDroppedTotal = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "nic_rx_dropped_total",
		Help:      "Total NIC RX dropped packets",
	})

	// ==========================================================================
	// nftables Metrics
	// ==========================================================================

	nftSetElements = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "nft_set_elements",
		Help:      "Number of elements in nftables set",
	}, []string{"set", "family"})

	nftRulesTotal = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "nft_rules_total",
		Help:      "Total number of nftables rules",
	})

	nftRuleCountersEnabled = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "nft_rule_counters_enabled",
		Help:      "Whether nftables rules have counters (1=yes, 0=no)",
	})

	// ==========================================================================
	// Cost Metrics
	// ==========================================================================

	costBytesPerBlockRSS = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "cost_bytes_per_block_rss",
		Help:      "RSS bytes per blocked IP (rolling window)",
	})

	// ==========================================================================
	// CIDR Filter Metrics
	// ==========================================================================

	cidrFilterTotal = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "cidr_filter_total",
		Help:      "Total CIDRs processed in last sync",
	})

	cidrFilterFiltered = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "cidr_filter_filtered",
		Help:      "CIDRs removed by filtering in last sync",
	})

	cidrFilterBogon = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "cidr_filter_bogon",
		Help:      "Bogon/reserved CIDRs removed in last sync",
	})

	cidrFilterOversize = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "cidr_filter_oversize",
		Help:      "Oversized CIDRs (< /9) removed in last sync",
	})

	cidrFilterKept = promauto.NewGauge(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "cidr_filter_kept",
		Help:      "CIDRs that passed filtering in last sync",
	})
)

// MetricsExporter updates Prometheus metrics from watchdog data
type MetricsExporter struct {
	// For cost calculation
	lastRSS    uint64
	lastBlocks int
}

// NewMetricsExporter creates a new metrics exporter
func NewMetricsExporter() *MetricsExporter {
	return &MetricsExporter{}
}

// Update updates all metrics from a snapshot and state
func (m *MetricsExporter) Update(snapshot *Snapshot, state *PressureState) {
	// Pressure state
	for _, dim := range AllDimensions() {
		level := state.Levels[dim]
		score := state.Scores[dim]

		// Set score
		pressureScore.WithLabelValues(string(dim)).Set(score)

		// Set state (only one level is 1, others are 0)
		for _, l := range []Level{LevelOK, LevelWarn, LevelCritical} {
			val := float64(0)
			if level == l {
				val = 1
			}
			pressureState.WithLabelValues(string(dim), string(l)).Set(val)
		}
	}

	// Operating mode
	for _, mode := range []Mode{ModeNormal, ModeDegraded, ModeSurvival} {
		val := float64(0)
		if state.Mode == mode {
			val = 1
		}
		operatingMode.WithLabelValues(string(mode)).Set(val)
	}

	// Process metrics
	procRSSBytes.Set(float64(snapshot.Process.RSS))
	procCPUPercent.Set(snapshot.Process.CPUPct)
	procFDOpen.Set(float64(snapshot.Process.FDs))
	procThreads.Set(float64(snapshot.Process.Threads))

	// Go runtime metrics
	goGoroutines.Set(float64(snapshot.Runtime.Goroutines))
	goGCCPUFraction.Set(snapshot.Runtime.GCCPUFraction)
	goHeapAllocBytes.Set(float64(snapshot.Runtime.HeapAlloc))
	goHeapInuseBytes.Set(float64(snapshot.Runtime.HeapInuse))
	goHeapReleasedBytes.Set(float64(snapshot.Runtime.HeapReleased))

	// Record GC pause if there was one
	if snapshot.Runtime.GCPauseNs > 0 {
		goGCPauseSeconds.Observe(float64(snapshot.Runtime.GCPauseNs) / 1e9)
	}

	// Kernel metrics
	conntrackUsed.Set(float64(snapshot.Kernel.ConntrackCount))
	conntrackMax.Set(float64(snapshot.Kernel.ConntrackMax))
	conntrackUtilization.Set(snapshot.Kernel.ConntrackUtilization)
	softnetDropsTotal.Set(float64(snapshot.Kernel.SoftnetDrops))
	softnetTimeSqueezeTotal.Set(float64(snapshot.Kernel.SoftnetTimeSqueeze))
	nicRXDroppedTotal.Set(float64(snapshot.Kernel.NICDrops))

	// nftables metrics
	nftRulesTotal.Set(float64(snapshot.NFTables.RulesTotal))
	if snapshot.NFTables.CountersEnabled {
		nftRuleCountersEnabled.Set(1)
	} else {
		nftRuleCountersEnabled.Set(0)
	}

	// Set elements
	for setKey, count := range snapshot.NFTables.SetElements {
		// setKey is like "ip_blacklist_ipv4" or "ip6_whitelist_ipv6"
		family := "ip"
		setName := setKey
		if len(setKey) > 3 && setKey[:3] == "ip6" {
			family = "ip6"
			setName = setKey[4:]
		} else if len(setKey) > 2 && setKey[:2] == "ip" {
			family = "ip"
			setName = setKey[3:]
		}
		nftSetElements.WithLabelValues(setName, family).Set(float64(count))
	}

	// Cost per block calculation
	m.updateCostMetrics(snapshot)

	// CIDR filter metrics (read from state file)
	m.updateFilterMetrics()
}

// RecordAction records an action in metrics
func (m *MetricsExporter) RecordAction(action Action) {
	actionTotal.WithLabelValues(string(action.Type)).Inc()
	actionLastTimestamp.WithLabelValues(string(action.Type)).Set(float64(action.Timestamp.Unix()))
}

// updateCostMetrics calculates and updates cost per block metrics
func (m *MetricsExporter) updateCostMetrics(snapshot *Snapshot) {
	// Sum all set elements as "blocks"
	totalBlocks := 0
	for _, count := range snapshot.NFTables.SetElements {
		totalBlocks += count
	}

	// Only calculate if we have enough blocks
	minBlocks := 100
	if totalBlocks < minBlocks || m.lastBlocks < minBlocks {
		m.lastRSS = snapshot.Process.RSS
		m.lastBlocks = totalBlocks
		return
	}

	blockDelta := totalBlocks - m.lastBlocks
	if blockDelta > minBlocks {
		rssDelta := int64(snapshot.Process.RSS) - int64(m.lastRSS)
		if rssDelta > 0 && blockDelta > 0 {
			costPerBlock := float64(rssDelta) / float64(blockDelta)
			costBytesPerBlockRSS.Set(costPerBlock)
		}

		m.lastRSS = snapshot.Process.RSS
		m.lastBlocks = totalBlocks
	}
}

// updateFilterMetrics updates CIDR filter metrics from state file
func (m *MetricsExporter) updateFilterMetrics() {
	state, err := safety.GetFilterState()
	if err != nil || state == nil {
		return // No filter state available yet
	}

	cidrFilterTotal.Set(float64(state.Total))
	cidrFilterFiltered.Set(float64(state.Filtered))
	cidrFilterBogon.Set(float64(state.BogonCount))
	cidrFilterOversize.Set(float64(state.OversizeCount))
	cidrFilterKept.Set(float64(state.Kept))
}
