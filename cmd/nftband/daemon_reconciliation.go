// =============================================================================
// NFTBan v1.34.0 - Periodic Reconciliation, Schema Validation, Overlap Detection
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Periodic reconciliation loop with kernel drift detection and overlap checking"
//
// meta:inventory.files="/usr/lib/nftban/bin/nftband"
// meta:inventory.binaries="nftband"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package main

import (
	"log"
	"time"

	"github.com/itcmsgr/nftban/pkg/constants"
	"github.com/itcmsgr/nftban/pkg/metrics"
	"github.com/itcmsgr/nftban/pkg/nftlock"
	"github.com/itcmsgr/nftban/pkg/opqueue"
)

// startPeriodicReconciliation runs reconciliation on a schedule (v1.34.0)
func (d *Daemon) startPeriodicReconciliation(wrapper *opqueue.NFTBackendWrapper) {
	interval := d.setCounters.ReconcileInterval()
	log.Printf("[RECONCILE] Periodic reconciliation enabled, interval=%s", interval)
	timer := time.NewTimer(interval)
	defer timer.Stop()

	for {
		select {
		case <-d.ctx.Done():
			return
		case <-timer.C:
			d.runReconciliation(wrapper)
			interval = d.setCounters.ReconcileInterval()
			timer.Reset(interval)
		}
	}
}

// runReconciliation performs a single reconciliation cycle with metrics (v1.34.0)
func (d *Daemon) runReconciliation(wrapper *opqueue.NFTBackendWrapper) {
	start := time.Now()

	// Snapshot current in-memory counts before reconciliation
	oldCounts := make(map[string]int64)
	for _, name := range d.setCounters.AllSets() {
		oldCounts[name] = d.setCounters.Get(name)
	}

	// Acquire exclusive nft lock
	lock, err := nftlock.AcquireExclusive(constants.ReconciliationLockTimeout)
	if err != nil {
		log.Printf("[RECONCILE] Failed to acquire lock: %v", err)
		return
	}
	defer lock.Release()

	// Run reconciliation
	d.reconcileSetCountersFromKernel(wrapper)
	d.sourceIndex.ReconcileWithBackend(wrapper)

	// Check whitelist-blacklist overlap (hash sets only — interval sets too expensive)
	d.checkWhitelistOverlap(wrapper)

	duration := time.Since(start)

	// Calculate drift
	driftCount := 0
	for _, name := range d.setCounters.AllSets() {
		newCount := d.setCounters.Get(name)
		oldCount := oldCounts[name]
		drift := newCount - oldCount
		if drift != 0 {
			driftCount++
			log.Printf("[RECONCILE] Drift: %s: %d -> %d (delta %+d)", name, oldCount, newCount, drift)
		}
		metrics.SetReconciliationDrift(name, float64(abs64(drift)))
	}

	// Record metrics
	metrics.RecordReconciliationDuration(duration.Seconds())
	metrics.SetReconciliationLastTimestamp(float64(time.Now().Unix()))
	metrics.RecordReconciliationRun()

	log.Printf("[RECONCILE] Periodic reconciliation complete: %d drift(s), took %s",
		driftCount, duration.Round(time.Millisecond))
}

// handleReconcileRequest triggers manual reconciliation via IPC (v1.35.0).
func (d *Daemon) handleReconcileRequest() SocketResponse {
	nft := d.backend.GetNFTManager()
	if nft == nil {
		return SocketResponse{Success: false, Error: "nftables backend not initialized"}
	}

	wrapper, err := opqueue.NewNFTBackendWrapper(nft)
	if err != nil {
		return SocketResponse{Success: false, Error: "failed to create wrapper: " + err.Error()}
	}

	start := time.Now()
	d.runReconciliation(wrapper)
	duration := time.Since(start)

	return SocketResponse{
		Success: true,
		Data:    "reconciliation completed in " + duration.Round(time.Millisecond).String(),
	}
}

// checkWhitelistOverlap detects IPs present in both whitelist and blacklist_manual sets (v1.34.0).
// Only checks hash sets (blacklist_manual_*) — interval sets (blacklist_*) contain 500K+ CIDRs
// and loading them would spike memory. Overlap with feed CIDRs is handled at sync time.
func (d *Daemon) checkWhitelistOverlap(wrapper *opqueue.NFTBackendWrapper) {
	overlapCount := 0

	// Whitelist/blacklist_manual pairs per address family
	type setPair struct {
		whitelist    string
		manualBans   string
	}
	pairs := []setPair{
		{"whitelist_ipv4", "blacklist_manual_ipv4"},
		{"whitelist_ipv6", "blacklist_manual_ipv6"},
	}

	for _, pair := range pairs {
		wlIPs, err := wrapper.GetSetElements("nftban", pair.whitelist)
		if err != nil {
			continue // Set may not exist
		}
		if len(wlIPs) == 0 {
			continue
		}

		// Build whitelist lookup
		wlSet := make(map[string]bool, len(wlIPs))
		for _, ip := range wlIPs {
			wlSet[ip] = true
		}

		// Check manual blacklist
		blIPs, err := wrapper.GetSetElements("nftban", pair.manualBans)
		if err != nil {
			continue
		}
		for _, ip := range blIPs {
			if wlSet[ip] {
				overlapCount++
				log.Printf("[RECONCILE] WARNING: IP %s in both %s and %s", ip, pair.whitelist, pair.manualBans)
			}
		}
	}

	metrics.SetWhitelistOverlapCount(overlapCount)
	if overlapCount > 0 {
		log.Printf("[RECONCILE] Whitelist-blacklist overlap: %d IPs in both sets", overlapCount)
	}
}

func abs64(n int64) int64 {
	if n < 0 {
		return -n
	}
	return n
}
