// =============================================================================
// NFTBan - Suricata IP Threat Scorer
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="scorer"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Calculates threat scores for IPs based on Suricata events"
// meta:input="Suricata events"
// meta:output="IP threat scores"
// meta:depends="github.com/itcmsgr/nftban/internal/safety"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package suricata

import (
	"container/list"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/constants"
	"github.com/itcmsgr/nftban/internal/safety"
)

// IPScore tracks scoring for a single IP address
type IPScore struct {
	IP           string
	CurrentScore int
	Events       []time.Time // Timestamps of recent events (capped to MaxEventsPerIP)
	LastUpdate   time.Time
	TotalEvents  int
	// LRU bookkeeping
	lruElement *list.Element
}

// Scorer calculates threat scores for IPs based on Suricata events
// Implements bounded memory via LRU eviction and per-IP event caps.
// Protects against CWE-400 (Uncontrolled Resource Consumption).
type Scorer struct {
	mu          sync.RWMutex
	scores      map[string]*IPScore
	config      *Config
	decayTicker *time.Ticker
	stopChan    chan struct{}

	// LRU eviction support (oldest IPs evicted when at capacity)
	lruList   *list.List
	maxIPs    int
	maxEvents int
}

// NewScorer creates a new scorer with bounded memory
func NewScorer(config *Config) *Scorer {
	limits := safety.GetMemoryLimits()

	s := &Scorer{
		scores:      make(map[string]*IPScore),
		config:      config,
		decayTicker: time.NewTicker(constants.SuricataDecayInterval),
		stopChan:    make(chan struct{}),
		lruList:     list.New(),
		maxIPs:      limits.ScorerMaxIPs,
		maxEvents:   limits.ScorerMaxEventsPerIP,
	}

	// Start decay goroutine
	go s.runDecay()

	return s
}

// Stop stops the scorer
func (s *Scorer) Stop() {
	close(s.stopChan)
	s.decayTicker.Stop()
}

// runDecay periodically decays scores
func (s *Scorer) runDecay() {
	for {
		select {
		case <-s.decayTicker.C:
			s.applyDecay()
		case <-s.stopChan:
			return
		}
	}
}

// applyDecay removes old events and decays scores
func (s *Scorer) applyDecay() {
	s.mu.Lock()
	defer s.mu.Unlock()

	cutoff := time.Now().Add(-s.config.ScoreDecay)

	for ip, score := range s.scores {
		// Remove events older than decay period
		newEvents := make([]time.Time, 0, len(score.Events))
		for _, t := range score.Events {
			if t.After(cutoff) {
				newEvents = append(newEvents, t)
			}
		}
		score.Events = newEvents

		// If no recent events, remove IP from tracking
		if len(score.Events) == 0 {
			s.removeIPLocked(ip)
		}
	}
}

// removeIPLocked removes an IP from the scorer (must be called with lock held)
func (s *Scorer) removeIPLocked(ip string) {
	if score, exists := s.scores[ip]; exists {
		if score.lruElement != nil {
			s.lruList.Remove(score.lruElement)
		}
		delete(s.scores, ip)
	}
}

// evictOldestLocked evicts the oldest IP to make room (must be called with lock held)
func (s *Scorer) evictOldestLocked() {
	if s.lruList.Len() == 0 {
		return
	}
	oldest := s.lruList.Back()
	if oldest != nil {
		if ip, ok := oldest.Value.(string); ok {
			s.removeIPLocked(ip)
		}
	}
}

// touchLRULocked moves an IP to the front of the LRU list (must be called with lock held)
func (s *Scorer) touchLRULocked(score *IPScore) {
	if score.lruElement != nil {
		s.lruList.MoveToFront(score.lruElement)
	} else {
		score.lruElement = s.lruList.PushFront(score.IP)
	}
}

// AddEvent processes a new event and updates IP score
func (s *Scorer) AddEvent(event *Event) int {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Get or create IP score tracker
	score, exists := s.scores[event.SrcIP]
	if !exists {
		// Check capacity before adding new IP
		if len(s.scores) >= s.maxIPs {
			s.evictOldestLocked()
		}

		score = &IPScore{
			IP:     event.SrcIP,
			Events: make([]time.Time, 0, s.maxEvents),
		}
		s.scores[event.SrcIP] = score
	}

	// Add event timestamp with cap
	if len(score.Events) >= s.maxEvents {
		// Evict oldest events (keep most recent maxEvents-1)
		score.Events = score.Events[1:]
	}
	score.Events = append(score.Events, event.Timestamp)
	score.LastUpdate = time.Now()
	score.TotalEvents++

	// Touch LRU (mark as recently used)
	s.touchLRULocked(score)

	// Calculate new score
	newScore := s.calculateScore(event, score)
	score.CurrentScore = newScore

	return newScore
}

// calculateScore calculates the threat score for an IP based on an event
func (s *Scorer) calculateScore(event *Event, ipScore *IPScore) int {
	score := 0

	// 1. Base severity score
	// Severity: 1=High(40pts), 2=Medium(30pts), 3=Low(20pts), 4=Info(10pts)
	severityScores := map[int]int{
		1: 40, // High
		2: 30, // Medium
		3: 20, // Low
		4: 10, // Info
	}
	if severityScore, ok := severityScores[event.Severity]; ok {
		score += severityScore
	}

	// 2. Repetition score (events in last 2 minutes)
	cutoff := time.Now().Add(-2 * time.Minute)
	recentCount := 0
	for _, t := range ipScore.Events {
		if t.After(cutoff) {
			recentCount++
		}
	}

	if recentCount >= 5 && recentCount < 10 {
		score += 20
	} else if recentCount >= 10 && recentCount < 20 {
		score += 30
	} else if recentCount >= 20 {
		score += 50
	}

	// 3. TODO: Integrate with feeds module (when available)
	// if feeds.IsBlacklisted(event.SrcIP) {
	//     score += 30
	// }

	// 4. TODO: Integrate with geoban module (when available)
	// country := geoban.Lookup(event.SrcIP)
	// if country in high-risk countries {
	//     score += 10
	// }

	// 5. TODO: Integrate with DDoS counters (when available)
	// if ddos.GetPPS(event.SrcIP) > 1000 {
	//     score += 40
	// }

	return score
}

// GetScore returns the current score for an IP
func (s *Scorer) GetScore(ip string) int {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if score, exists := s.scores[ip]; exists {
		return score.CurrentScore
	}
	return 0
}

// GetIPScore returns full scoring details for an IP
func (s *Scorer) GetIPScore(ip string) *IPScore {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if score, exists := s.scores[ip]; exists {
		// Return a copy to avoid race conditions
		return &IPScore{
			IP:           score.IP,
			CurrentScore: score.CurrentScore,
			Events:       append([]time.Time{}, score.Events...),
			LastUpdate:   score.LastUpdate,
			TotalEvents:  score.TotalEvents,
		}
	}
	return nil
}

// GetAllScores returns all current IP scores
func (s *Scorer) GetAllScores() map[string]*IPScore {
	s.mu.RLock()
	defer s.mu.RUnlock()

	// Return a copy
	result := make(map[string]*IPScore)
	for ip, score := range s.scores {
		result[ip] = &IPScore{
			IP:           score.IP,
			CurrentScore: score.CurrentScore,
			Events:       append([]time.Time{}, score.Events...),
			LastUpdate:   score.LastUpdate,
			TotalEvents:  score.TotalEvents,
		}
	}
	return result
}

// ResetScore resets the score for an IP (e.g., after banning)
func (s *Scorer) ResetScore(ip string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.removeIPLocked(ip)
}

// GetStats returns memory usage statistics for monitoring
func (s *Scorer) GetStats() map[string]int {
	s.mu.RLock()
	defer s.mu.RUnlock()

	totalEvents := 0
	for _, score := range s.scores {
		totalEvents += len(score.Events)
	}

	return map[string]int{
		"tracked_ips":    len(s.scores),
		"max_ips":        s.maxIPs,
		"total_events":   totalEvents,
		"max_events_per": s.maxEvents,
		"lru_size":       s.lruList.Len(),
	}
}
