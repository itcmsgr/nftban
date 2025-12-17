package suricata

import (
	"sync"
	"time"
)

// IPScore tracks scoring for a single IP address
type IPScore struct {
	IP            string
	CurrentScore  int
	Events        []time.Time // Timestamps of recent events
	LastUpdate    time.Time
	TotalEvents   int
}

// Scorer calculates threat scores for IPs based on Suricata events
type Scorer struct {
	mu          sync.RWMutex
	scores      map[string]*IPScore
	config      *Config
	decayTicker *time.Ticker
	stopChan    chan struct{}
}

// NewScorer creates a new scorer
func NewScorer(config *Config) *Scorer {
	s := &Scorer{
		scores:      make(map[string]*IPScore),
		config:      config,
		decayTicker: time.NewTicker(1 * time.Minute),
		stopChan:    make(chan struct{}),
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
		newEvents := []time.Time{}
		for _, t := range score.Events {
			if t.After(cutoff) {
				newEvents = append(newEvents, t)
			}
		}
		score.Events = newEvents

		// If no recent events, remove IP from tracking
		if len(score.Events) == 0 {
			delete(s.scores, ip)
		}
	}
}

// AddEvent processes a new event and updates IP score
func (s *Scorer) AddEvent(event *Event) int {
	s.mu.Lock()
	defer s.mu.Unlock()

	// Get or create IP score tracker
	score, exists := s.scores[event.SrcIP]
	if !exists {
		score = &IPScore{
			IP:     event.SrcIP,
			Events: []time.Time{},
		}
		s.scores[event.SrcIP] = score
	}

	// Add event timestamp
	score.Events = append(score.Events, event.Timestamp)
	score.LastUpdate = time.Now()
	score.TotalEvents++

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

	delete(s.scores, ip)
}
