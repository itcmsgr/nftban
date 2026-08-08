// SPDX-License-Identifier: MPL-2.0
package watchdog

// v1.228.7 — tiered set-size sampling semantics.
//
// The defect: collectSetSizes ran ungated on every 5s tick under the comment
// "cheap operation", dumping every element of every set to take len(). Daemon
// CPU tracked total element count (dns4: 188,704 elements -> 113% CPU, IPC
// starved). NFTSetInterval existed as config but was never read — a dead knob.
//
// These tests pin the semantics that make the fix real:
//   - the knob is WIRED: constructor intervals land in the collector
//   - the dynamic tier can never sample FASTER than the enforcement tier
//   - cached counts are PUBLISHED on off-ticks (continuous metric, not absent)
//   - zero-value construction inherits the constants (no silent un-gating)
//
// The kernel-walk behaviour itself (dumps actually skipped on off-ticks) is
// proven on real nftables by the package-native lab gate, not here — this file
// deliberately needs no netlink.

import (
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/constants"
)

func TestTieredIntervalsWired(t *testing.T) {
	c := NewNFTablesCollectorWithIntervals(30*time.Second, 7*time.Second, 3*time.Minute)
	if c.setInterval != 7*time.Second {
		t.Fatalf("setInterval not wired: got %v", c.setInterval)
	}
	if c.dynamicSetInterval != 3*time.Minute {
		t.Fatalf("dynamicSetInterval not wired: got %v", c.dynamicSetInterval)
	}
}

func TestZeroValuesInheritConstants(t *testing.T) {
	// A zero interval must fall back to the constants — NOT to "sample every
	// tick", which would silently reintroduce the ungated walk.
	c := NewNFTablesCollectorWithIntervals(0, 0, 0)
	if c.setInterval != constants.WatchdogNFTSetInterval {
		t.Fatalf("zero setInterval must inherit constant, got %v", c.setInterval)
	}
	if c.dynamicSetInterval != constants.WatchdogNFTDynamicSetInterval {
		t.Fatalf("zero dynamicSetInterval must inherit constant, got %v", c.dynamicSetInterval)
	}
	if c.dynamicSetInterval <= c.setInterval {
		t.Fatalf("dynamic tier (%v) must be slower than enforcement tier (%v)",
			c.dynamicSetInterval, c.setInterval)
	}
}

func TestDynamicTierNeverFasterThanEnforcementTier(t *testing.T) {
	// A config asking for a FASTER dynamic tier than enforcement tier is a
	// misconfiguration that would re-create the expensive walk; it is clamped.
	c := NewNFTablesCollectorWithIntervals(0, 30*time.Second, 1*time.Second)
	if c.dynamicSetInterval < c.setInterval {
		t.Fatalf("dynamic tier %v ended up faster than enforcement tier %v",
			c.dynamicSetInterval, c.setInterval)
	}
}

func TestLegacyConstructorDelegates(t *testing.T) {
	// The pre-existing constructor must keep working and inherit the gated
	// defaults — existing callers must not silently lose the fix.
	c := NewNFTablesCollector(0)
	if c.setInterval != constants.WatchdogNFTSetInterval ||
		c.dynamicSetInterval != constants.WatchdogNFTDynamicSetInterval {
		t.Fatalf("legacy constructor lost the tier defaults: set=%v dynamic=%v",
			c.setInterval, c.dynamicSetInterval)
	}
	if c.cachedSetElements == nil || c.cachedDynamicSets == nil {
		t.Fatal("caches not initialised — off-tick publishing would panic")
	}
}

func TestOffTickPublishesCachedCounts(t *testing.T) {
	// On a tick where no population is due, the last known counts must be
	// PUBLISHED, not omitted: an absent metric reads as "no sets", which is a
	// different claim from "unchanged since the last sample".
	c := NewNFTablesCollectorWithIntervals(0, time.Hour, time.Hour)
	c.cachedSetElements["ip_whitelist_ipv4"] = 19
	c.cachedDynamicSets["ip_ddos_dns_udp"] = 58
	c.cachedSetsTotal = 2

	snap := &Snapshot{}
	snap.NFTables.SetElements = make(map[string]int)
	c.publishCachedSetElements(snap)

	if snap.NFTables.SetElements["ip_whitelist_ipv4"] != 19 {
		t.Fatalf("enforcement cache not published: %v", snap.NFTables.SetElements)
	}
	if snap.NFTables.SetElements["ip_ddos_dns_udp"] != 58 {
		t.Fatalf("dynamic cache not published: %v", snap.NFTables.SetElements)
	}
	if snap.NFTables.SetsTotal != 2 {
		t.Fatalf("SetsTotal not published from cache: %d", snap.NFTables.SetsTotal)
	}
}
