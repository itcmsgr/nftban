// =============================================================================
// NFTBan - Event Rule Engine: Service (integration layer)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="ruleengine-service"
// meta:type="package"
// meta:version="1.93.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-16"
// meta:description="Integrates rule engine with daemon — loads rules, processes events, produces actions"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/rules.d/"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package ruleengine

import (
	"log"
	"sync/atomic"
	"time"
)

// Service is the main integration point for the rule engine.
// It loads rules from disk, processes incoming events, and returns
// ban/observe decisions. The daemon wires this into the event pipeline.
//
// All enforcement flows through daemon IPC → nftables (INV-S-004).
// The service MUST NOT trigger inline behavior (INV-S-012).
type Service struct {
	engine   *Engine
	rulesDir string
	enabled  atomic.Bool

	// Metrics
	eventsProcessed atomic.Int64
	rulesMatched    atomic.Int64
	bansProduced    atomic.Int64
}

// NewService creates a rule engine service.
// rulesDir is typically /etc/nftban/rules.d/
func NewService(rulesDir string) *Service {
	s := &Service{
		engine:   New(),
		rulesDir: rulesDir,
	}
	return s
}

// Start loads rules and enables the service.
func (s *Service) Start() error {
	rules, err := LoadRulesFromDir(s.rulesDir)
	if err != nil {
		return err
	}

	s.engine.LoadRules(rules)
	s.enabled.Store(true)

	log.Printf("[ruleengine] service started with %d rules from %s", s.engine.RuleCount(), s.rulesDir)

	// Start cleanup goroutine (evict expired score/threshold entries every 5 min)
	go s.cleanupLoop()

	return nil
}

// Stop disables the service.
func (s *Service) Stop() {
	s.enabled.Store(false)
	log.Printf("[ruleengine] service stopped (processed=%d matched=%d bans=%d)",
		s.eventsProcessed.Load(), s.rulesMatched.Load(), s.bansProduced.Load())
}

// Reload reloads rules from disk without stopping.
func (s *Service) Reload() error {
	rules, err := LoadRulesFromDir(s.rulesDir)
	if err != nil {
		return err
	}
	s.engine.LoadRules(rules)
	log.Printf("[ruleengine] reloaded %d rules", s.engine.RuleCount())
	return nil
}

// ProcessEvent evaluates an event against loaded rules.
// Returns a Result with the action to take.
// If the service is disabled or no rules match, returns ActionObserve.
func (s *Service) ProcessEvent(ev *Event) *Result {
	if !s.enabled.Load() {
		return &Result{Action: ActionObserve}
	}

	s.eventsProcessed.Add(1)

	result := s.engine.Evaluate(ev)

	if result.Matched {
		s.rulesMatched.Add(1)
		if result.Action != ActionObserve && result.Action != ActionScore {
			s.bansProduced.Add(1)
		}
	}

	return result
}

// Stats returns current service statistics.
func (s *Service) Stats() ServiceStats {
	return ServiceStats{
		Enabled:         s.enabled.Load(),
		RuleCount:       s.engine.RuleCount(),
		EventsProcessed: s.eventsProcessed.Load(),
		RulesMatched:    s.rulesMatched.Load(),
		BansProduced:    s.bansProduced.Load(),
	}
}

// ServiceStats holds runtime statistics for the rule engine.
type ServiceStats struct {
	Enabled         bool  `json:"enabled"`
	RuleCount       int   `json:"rule_count"`
	EventsProcessed int64 `json:"events_processed"`
	RulesMatched    int64 `json:"rules_matched"`
	BansProduced    int64 `json:"bans_produced"`
}

func (s *Service) cleanupLoop() {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()

	for range ticker.C {
		if !s.enabled.Load() {
			return
		}
		s.engine.Cleanup(1 * time.Hour)
	}
}
