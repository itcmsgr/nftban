// =============================================================================
// NFTBan v1.0 - Pressure Score Calculator
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="pressure"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Calculates pressure scores per dimension from collected metrics"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package watchdog

import (
	"math"
	"sync"
	"time"
)

// PressureCalculator computes pressure scores from snapshots
type PressureCalculator struct {
	config *Config

	mu sync.Mutex

	// For RSS slope calculation
	rssHistory    []rssPoint
	maxRSSHistory int

	// Cached softnet drops rate
	lastSoftnetDrops uint64
	lastSoftnetTime  time.Time
	softnetDropsRate float64
}

type rssPoint struct {
	timestamp time.Time
	rss       uint64
}

// NewPressureCalculator creates a new pressure calculator
func NewPressureCalculator(cfg *Config) *PressureCalculator {
	return &PressureCalculator{
		config:        cfg,
		maxRSSHistory: 12, // 1 minute at 5s intervals
		rssHistory:    make([]rssPoint, 0, 12),
	}
}

// Calculate computes pressure scores from a snapshot
func (p *PressureCalculator) Calculate(snapshot *Snapshot) map[Dimension]float64 {
	p.mu.Lock()
	defer p.mu.Unlock()

	scores := make(map[Dimension]float64)

	scores[DimCPU] = p.calculateCPUScore(snapshot)
	scores[DimMEM] = p.calculateMEMScore(snapshot)
	scores[DimIO] = p.calculateIOScore(snapshot)
	scores[DimNET] = p.calculateNETScore(snapshot)

	return scores
}

// calculateCPUScore computes CPU dimension score
// Inputs: process CPU%, system load, softnet drops
func (p *PressureCalculator) calculateCPUScore(snapshot *Snapshot) float64 {
	var score float64

	// Process CPU contribution (0-50 points)
	cpuContrib := (snapshot.Process.CPUPct / p.config.CPUCritPercent) * 50
	cpuContrib = clamp(cpuContrib, 0, 50)
	score += cpuContrib

	// Load average contribution (0-30 points)
	// Normalize by CPU count
	if snapshot.System.NumCPU > 0 {
		normalizedLoad := snapshot.System.LoadAvg5 / float64(snapshot.System.NumCPU)
		loadContrib := (normalizedLoad / p.config.LoadNormalizedCrit) * 30
		loadContrib = clamp(loadContrib, 0, 30)
		score += loadContrib
	}

	// Softnet drops penalty (0-20 points)
	// Rising drops indicate kernel stress even if process CPU is low
	p.updateSoftnetDropsRate(snapshot)
	if p.softnetDropsRate > 0 && p.config.SoftnetDropsRateCrit > 0 {
		softnetContrib := (p.softnetDropsRate / p.config.SoftnetDropsRateCrit) * 20
		softnetContrib = clamp(softnetContrib, 0, 20)
		score += softnetContrib
	}

	return clamp(score, 0, 100)
}

// calculateMEMScore computes memory dimension score
// Inputs: RSS vs budget, heap vs GOMEMLIMIT, GC fraction, RSS slope
func (p *PressureCalculator) calculateMEMScore(snapshot *Snapshot) float64 {
	var score float64

	// RSS vs budget contribution (0-40 points)
	if p.config.MemBudgetBytes > 0 {
		rssPct := (float64(snapshot.Process.RSS) / float64(p.config.MemBudgetBytes)) * 100
		rssContrib := (rssPct / p.config.RSSCritPercentOfBudget) * 40
		rssContrib = clamp(rssContrib, 0, 40)
		score += rssContrib
	}

	// Heap vs GOMEMLIMIT contribution (0-30 points)
	if snapshot.Runtime.GOMEMLIMIT > 0 {
		heapPct := (float64(snapshot.Runtime.HeapInuse) / float64(snapshot.Runtime.GOMEMLIMIT)) * 100
		heapContrib := (heapPct / p.config.HeapCritPercentOfLimit) * 30
		heapContrib = clamp(heapContrib, 0, 30)
		score += heapContrib
	}

	// GC CPU fraction contribution (0-15 points)
	// If GC is consuming >10% CPU, that's concerning
	gcContrib := (snapshot.Runtime.GCCPUFraction / 0.10) * 15
	gcContrib = clamp(gcContrib, 0, 15)
	score += gcContrib

	// RSS slope contribution (0-15 points) - leak suspicion
	p.updateRSSHistory(snapshot)
	slope := p.calculateRSSSlope()
	if slope > 0 {
		// 50MB/min growth = max score
		slopePerMin := slope * 60 // bytes per minute
		slopeContrib := (slopePerMin / (50 * 1024 * 1024)) * 15
		slopeContrib = clamp(slopeContrib, 0, 15)
		score += slopeContrib
	}

	return clamp(score, 0, 100)
}

// calculateIOScore computes I/O dimension score
// Inputs: iowait%, disk usage
func (p *PressureCalculator) calculateIOScore(snapshot *Snapshot) float64 {
	var score float64

	// I/O wait contribution (0-60 points)
	iowaitContrib := (snapshot.System.IOWaitPct / p.config.IOWaitCritPercent) * 60
	iowaitContrib = clamp(iowaitContrib, 0, 60)
	score += iowaitContrib

	// Disk usage contribution (0-40 points)
	diskContrib := (snapshot.System.DiskUsePct / p.config.DiskUseCritPercent) * 40
	diskContrib = clamp(diskContrib, 0, 40)
	score += diskContrib

	return clamp(score, 0, 100)
}

// calculateNETScore computes network dimension score
// Inputs: conntrack utilization, softnet drops rate, nft apply latency
func (p *PressureCalculator) calculateNETScore(snapshot *Snapshot) float64 {
	var score float64

	// Conntrack utilization contribution (0-50 points)
	if p.config.ConntrackUtilCrit > 0 {
		ctContrib := (snapshot.Kernel.ConntrackUtilization / p.config.ConntrackUtilCrit) * 50
		ctContrib = clamp(ctContrib, 0, 50)
		score += ctContrib
	}

	// Softnet drops rate contribution (0-30 points)
	if p.softnetDropsRate > 0 && p.config.SoftnetDropsRateCrit > 0 {
		softnetContrib := (p.softnetDropsRate / p.config.SoftnetDropsRateCrit) * 30
		softnetContrib = clamp(softnetContrib, 0, 30)
		score += softnetContrib
	}

	// nft apply latency contribution (0-20 points)
	// Consider >1s latency as critical
	if snapshot.NFTables.LastApplyLatency > 0 {
		latencyContrib := (snapshot.NFTables.LastApplyLatency / 1.0) * 20
		latencyContrib = clamp(latencyContrib, 0, 20)
		score += latencyContrib
	}

	return clamp(score, 0, 100)
}

// updateRSSHistory adds current RSS to history
func (p *PressureCalculator) updateRSSHistory(snapshot *Snapshot) {
	point := rssPoint{
		timestamp: snapshot.Timestamp,
		rss:       snapshot.Process.RSS,
	}

	p.rssHistory = append(p.rssHistory, point)

	// Trim to max size
	if len(p.rssHistory) > p.maxRSSHistory {
		p.rssHistory = p.rssHistory[1:]
	}
}

// calculateRSSSlope returns RSS growth rate in bytes per second
// Uses linear regression over the history window
func (p *PressureCalculator) calculateRSSSlope() float64 {
	if len(p.rssHistory) < 2 {
		return 0
	}

	// Simple linear regression
	n := float64(len(p.rssHistory))
	var sumX, sumY, sumXY, sumX2 float64

	startTime := p.rssHistory[0].timestamp
	for _, point := range p.rssHistory {
		x := point.timestamp.Sub(startTime).Seconds()
		y := float64(point.rss)
		sumX += x
		sumY += y
		sumXY += x * y
		sumX2 += x * x
	}

	denominator := n*sumX2 - sumX*sumX
	if denominator == 0 {
		return 0
	}

	slope := (n*sumXY - sumX*sumY) / denominator
	return slope // bytes per second
}

// updateSoftnetDropsRate calculates drops rate from snapshot
func (p *PressureCalculator) updateSoftnetDropsRate(snapshot *Snapshot) {
	if p.lastSoftnetTime.IsZero() {
		p.lastSoftnetDrops = snapshot.Kernel.SoftnetDrops
		p.lastSoftnetTime = snapshot.Timestamp
		return
	}

	elapsed := snapshot.Timestamp.Sub(p.lastSoftnetTime).Seconds()
	if elapsed > 0 {
		delta := snapshot.Kernel.SoftnetDrops - p.lastSoftnetDrops
		p.softnetDropsRate = float64(delta) / elapsed
	}

	p.lastSoftnetDrops = snapshot.Kernel.SoftnetDrops
	p.lastSoftnetTime = snapshot.Timestamp
}

// clamp limits a value to [min, max]
func clamp(value, min, max float64) float64 {
	return math.Max(min, math.Min(max, value))
}
