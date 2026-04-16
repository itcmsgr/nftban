// =============================================================================
// NFTBan - Event Rule Engine: Core Engine
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="ruleengine-engine"
// meta:type="package"
// meta:version="1.93.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-16"
// meta:description="Semantic event rule engine — matches normalized events against rules"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/rules.d/*.rules"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package ruleengine

import (
	"log"
	"sync"
	"time"
)

// Engine is the event rule engine. It matches normalized events against
// loaded rules and produces actions (observe, score, ban_*).
//
// The engine operates at the semantic/behavioral layer ONLY.
// It MUST NOT trigger inline Suricata behavior (INV-S-012).
// It MUST NOT inspect raw packets or payloads.
// All enforcement goes through daemon IPC → nftables (INV-S-004).
type Engine struct {
	mu       sync.RWMutex
	rules    []Rule
	scores   map[string]*ipScore // per-IP score tracker
	counters map[string]*thresholdCounter // per-IP per-rule threshold counters
}

type ipScore struct {
	score     int
	lastEvent time.Time
}

type thresholdCounter struct {
	events []time.Time
}

// Result is the engine's decision for an event.
type Result struct {
	Matched  bool   `json:"matched"`
	RuleID   string `json:"rule_id,omitempty"`
	RuleName string `json:"rule_name,omitempty"`
	Action   string `json:"action"`           // observe, score, ban_short, ban_long, ban_permanent
	Score    int    `json:"score,omitempty"`   // points added
	TotalScore int  `json:"total_score"`      // accumulated per-IP score
}

// New creates a new rule engine.
func New() *Engine {
	return &Engine{
		rules:    nil,
		scores:   make(map[string]*ipScore),
		counters: make(map[string]*thresholdCounter),
	}
}

// LoadRules replaces the current rule set.
func (e *Engine) LoadRules(rules []Rule) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.rules = rules
	log.Printf("[ruleengine] loaded %d rules", len(rules))
}

// RuleCount returns the number of loaded rules.
func (e *Engine) RuleCount() int {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return len(e.rules)
}

// Evaluate processes an event against all loaded rules.
// Returns the highest-priority matching result.
func (e *Engine) Evaluate(ev *Event) *Result {
	e.mu.RLock()
	defer e.mu.RUnlock()

	if len(e.rules) == 0 {
		return &Result{Action: ActionObserve}
	}

	var bestResult *Result

	for i := range e.rules {
		r := &e.rules[i]
		if !r.Matches(ev) {
			continue
		}

		// Check threshold if defined
		if r.Threshold != nil {
			key := ev.SourceIP + ":" + r.ID
			if !e.checkThreshold(key, r.Threshold) {
				continue // threshold not met
			}
		}

		// Apply score
		e.addScore(ev.SourceIP, r.Score)
		total := e.getScore(ev.SourceIP)

		result := &Result{
			Matched:    true,
			RuleID:     r.ID,
			RuleName:   r.Name,
			Action:     r.Action,
			Score:      r.Score,
			TotalScore: total,
		}

		// Score-based escalation (if action is "score")
		if r.Action == ActionScore {
			result.Action = e.scoreToAction(total)
		}

		// Keep highest-priority result
		if bestResult == nil || actionPriority(result.Action) > actionPriority(bestResult.Action) {
			bestResult = result
		}
	}

	if bestResult == nil {
		return &Result{Action: ActionObserve}
	}

	return bestResult
}

// checkThreshold verifies the event count exceeds the threshold within the window.
func (e *Engine) checkThreshold(key string, t *RuleThreshold) bool {
	now := time.Now()
	cutoff := now.Add(-t.Window)

	tc, ok := e.counters[key]
	if !ok {
		tc = &thresholdCounter{}
		e.counters[key] = tc
	}

	// Add current event
	tc.events = append(tc.events, now)

	// Evict old events
	valid := tc.events[:0]
	for _, ts := range tc.events {
		if ts.After(cutoff) {
			valid = append(valid, ts)
		}
	}
	tc.events = valid

	return len(tc.events) >= t.Count
}

// addScore adds points to an IP's score tracker.
func (e *Engine) addScore(ip string, points int) {
	s, ok := e.scores[ip]
	if !ok {
		s = &ipScore{}
		e.scores[ip] = s
	}

	// Decay: 1 point per minute since last event
	if !s.lastEvent.IsZero() {
		elapsed := time.Since(s.lastEvent)
		decay := int(elapsed.Minutes())
		s.score -= decay
		if s.score < 0 {
			s.score = 0
		}
	}

	s.score += points
	s.lastEvent = time.Now()
}

func (e *Engine) getScore(ip string) int {
	s, ok := e.scores[ip]
	if !ok {
		return 0
	}
	return s.score
}

// scoreToAction maps accumulated score to an action.
func (e *Engine) scoreToAction(score int) string {
	switch {
	case score >= 100:
		return ActionBanPermanent
	case score >= 50:
		return ActionBanLong
	case score >= 25:
		return ActionBanShort
	default:
		return ActionObserve
	}
}

// actionPriority returns a numeric priority for action comparison.
func actionPriority(action string) int {
	switch action {
	case ActionBanPermanent:
		return 4
	case ActionBanLong:
		return 3
	case ActionBanShort:
		return 2
	case ActionScore:
		return 1
	default:
		return 0
	}
}

// Cleanup removes expired entries from scores and counters.
// Call periodically (e.g. every 5 minutes).
func (e *Engine) Cleanup(maxAge time.Duration) {
	e.mu.Lock()
	defer e.mu.Unlock()

	cutoff := time.Now().Add(-maxAge)

	for ip, s := range e.scores {
		if s.lastEvent.Before(cutoff) {
			delete(e.scores, ip)
		}
	}

	for key, tc := range e.counters {
		if len(tc.events) == 0 || tc.events[len(tc.events)-1].Before(cutoff) {
			delete(e.counters, key)
		}
	}
}
