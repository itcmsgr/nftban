// =============================================================================
// NFTBan - Attack Rate Tracker (v1.41.0)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="attack_rate"
// meta:type="package"
// meta:version="1.41.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Sliding window attack rate metric (events per minute)"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package metrics

import (
	"sync"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// v1.41.0: Attack rate per minute gauge
var attackRatePerMinute = promauto.NewGauge(prometheus.GaugeOpts{
	Namespace: "nftban",
	Name:      "attack_rate_per_minute",
	Help:      "Number of attack events in the last 60 seconds (sliding window)",
})

// AttackRateTracker maintains a sliding window of attack event timestamps.
// Thread-safe for concurrent RecordAttack calls from EventBus subscribers.
type AttackRateTracker struct {
	mu         sync.Mutex
	timestamps []time.Time // Ring buffer of event timestamps
	window     time.Duration
	maxEntries int
}

// NewAttackRateTracker creates a tracker with a 60-second sliding window.
// maxEntries caps memory usage under sustained attack (default: 10000).
func NewAttackRateTracker(maxEntries int) *AttackRateTracker {
	if maxEntries <= 0 {
		maxEntries = 10000
	}
	return &AttackRateTracker{
		timestamps: make([]time.Time, 0, 256),
		window:     60 * time.Second,
		maxEntries: maxEntries,
	}
}

// RecordAttack records an attack event and updates the Prometheus gauge.
func (t *AttackRateTracker) RecordAttack() {
	t.mu.Lock()
	defer t.mu.Unlock()

	now := time.Now()
	t.timestamps = append(t.timestamps, now)

	// Prune expired entries
	cutoff := now.Add(-t.window)
	pruneIdx := 0
	for pruneIdx < len(t.timestamps) && t.timestamps[pruneIdx].Before(cutoff) {
		pruneIdx++
	}
	if pruneIdx > 0 {
		t.timestamps = t.timestamps[pruneIdx:]
	}

	// Cap at maxEntries to prevent unbounded growth under sustained attack
	if len(t.timestamps) > t.maxEntries {
		t.timestamps = t.timestamps[len(t.timestamps)-t.maxEntries:]
	}

	// Update gauge
	attackRatePerMinute.Set(float64(len(t.timestamps)))
}

// Rate returns the current number of events in the sliding window.
func (t *AttackRateTracker) Rate() int {
	t.mu.Lock()
	defer t.mu.Unlock()

	// Prune expired
	now := time.Now()
	cutoff := now.Add(-t.window)
	pruneIdx := 0
	for pruneIdx < len(t.timestamps) && t.timestamps[pruneIdx].Before(cutoff) {
		pruneIdx++
	}
	if pruneIdx > 0 {
		t.timestamps = t.timestamps[pruneIdx:]
	}

	return len(t.timestamps)
}

// RefreshGauge updates the Prometheus gauge with the current rate.
// Called from the sampler to keep the gauge fresh even without new events.
func (t *AttackRateTracker) RefreshGauge() {
	attackRatePerMinute.Set(float64(t.Rate()))
}

// globalAttackTracker is the singleton tracker instance
var (
	globalAttackTracker     *AttackRateTracker
	globalAttackTrackerOnce sync.Once
)

// GetAttackRateTracker returns the global attack rate tracker singleton
func GetAttackRateTracker() *AttackRateTracker {
	globalAttackTrackerOnce.Do(func() {
		globalAttackTracker = NewAttackRateTracker(10000)
	})
	return globalAttackTracker
}
