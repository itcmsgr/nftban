// =============================================================================
// NFTBan v1.20.0 - HTTP Bot Guard: Set Enforcer
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: Write classification decisions to nftables sets via OpQueue
//
// meta:name="botguard_enforcer"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-14"
// meta:description="Writes bot classification results to nft enforcement sets"
//
// Set ownership model:
//   http_bot_suspect  — kernel-written (meter rule, NOT touched by enforcer)
//   http_bot_allow    — Go-written (this enforcer via OpQueue)
//   http_bot_ban      — Go-written (this enforcer via OpQueue)
//   http_bot_grey     — Go-written (this enforcer via OpQueue)
//   http_bot_emergency— Go-written (this enforcer via OpQueue)
//   http_bot_pending  — Go-written (this enforcer via OpQueue)
//
// meta:inventory.files="enforcer.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

import (
	"fmt"
	"log"
	"net/netip"

	"github.com/itcmsgr/nftban/pkg/opqueue"
)

const enforcerSource = "botguard"

// Enforcer writes classification decisions to nftables enforcement sets.
// All writes go through the OpQueue for safe async netlink batching.
type Enforcer struct {
	queue  *opqueue.OpQueue
	config *Config
}

// NewEnforcer creates an enforcer that writes to nft sets via OpQueue.
func NewEnforcer(queue *opqueue.OpQueue, config *Config) *Enforcer {
	return &Enforcer{
		queue:  queue,
		config: config,
	}
}

// Apply writes a classification decision to the appropriate nft set.
// It removes the IP from the old set (if any) and adds it to the new set.
func (e *Enforcer) Apply(ip netip.Addr, oldState, newState IPState, reason string) error {
	isV6 := ip.Is6()
	ipStr := ip.String()

	// Remove from old set (if transitioning between sets)
	if oldState != StateUnknown && oldState != newState {
		oldSet := e.setName(oldState, isV6)
		if oldSet != "" {
			if err := e.queue.EnqueueUnban(oldSet, ipStr, enforcerSource); err != nil {
				return fmt.Errorf("remove %s from %s: %w", ipStr, oldSet, err)
			}
		}
	}

	// Add to new set
	newSet := e.setName(newState, isV6)
	if newSet == "" {
		return nil // StateUnknown has no set
	}

	ttl := e.ttlSeconds(newState)

	if err := e.queue.EnqueueBan(newSet, ipStr, ttl, enforcerSource, reason); err != nil {
		return fmt.Errorf("add %s to %s: %w", ipStr, newSet, err)
	}

	if e.config.LogDecisions {
		log.Printf("[botguard] %s: %s → %s (reason: %s, ttl: %ds)",
			ipStr, oldState, newState, reason, ttl)
	}

	return nil
}

// ApplyEmergency adds an IP directly to the emergency set (fast path).
func (e *Enforcer) ApplyEmergency(ip netip.Addr, reason string) error {
	return e.Apply(ip, StateUnknown, StateEmergency, reason)
}

// Remove removes an IP from its current set (e.g., when state expires).
func (e *Enforcer) Remove(ip netip.Addr, state IPState) error {
	setName := e.setName(state, ip.Is6())
	if setName == "" {
		return nil
	}
	return e.queue.EnqueueUnban(setName, ip.String(), enforcerSource)
}

// setName returns the nft set name for a given state and address family.
func (e *Enforcer) setName(state IPState, isV6 bool) string {
	if isV6 {
		return state.SetName6()
	}
	return state.SetName()
}

// ttlSeconds returns the TTL in seconds for a classification state.
func (e *Enforcer) ttlSeconds(state IPState) uint32 {
	switch state {
	case StatePending:
		return uint32(e.config.PendingTTL.Seconds())
	case StateAllow:
		return uint32(e.config.AllowTTL.Seconds())
	case StateGrey:
		return uint32(e.config.GreyTTL.Seconds())
	case StateBan:
		return uint32(e.config.BanTTL.Seconds())
	case StateEmergency:
		return uint32(e.config.EmergencyTTL.Seconds())
	default:
		return 0
	}
}
