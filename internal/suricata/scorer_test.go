// =============================================================================
// NFTBan v1.0 - Suricata IP Threat Scorer Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="scorer_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Unit tests for scorer calculateScore, LRU eviction, and memory bounds"
// meta:input="Test cases"
// meta:output="Test results"
// meta:depends="testing"
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
	"testing"
	"time"
)

// newTestScorer creates a Scorer without calling safety.GetMemoryLimits()
// so tests can run without the production configuration files.
func newTestScorer(maxIPs, maxEvents int) *Scorer {
	return &Scorer{
		scores:      make(map[string]*IPScore),
		config:      &Config{ScoreDecay: 1 * time.Hour},
		decayTicker: time.NewTicker(1 * time.Hour),
		stopChan:    make(chan struct{}),
		lruList:     list.New(),
		maxIPs:      maxIPs,
		maxEvents:   maxEvents,
	}
}

// =============================================================================
// calculateScore Tests
// =============================================================================

func TestCalculateScore_SeverityScores(t *testing.T) {
	s := newTestScorer(1000, 100)
	defer s.Stop()

	tests := []struct {
		name     string
		severity int
		want     int
	}{
		{"high_severity", 1, 40},
		{"medium_severity", 2, 30},
		{"low_severity", 3, 20},
		{"info_severity", 4, 10},
		{"unknown_severity", 5, 0},
		{"zero_severity", 0, 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			event := &Event{Severity: tt.severity, Timestamp: time.Now()}
			ipScore := &IPScore{Events: []time.Time{}}
			got := s.calculateScore(event, ipScore)
			if got != tt.want {
				t.Errorf("calculateScore(severity=%d) = %d, want %d", tt.severity, got, tt.want)
			}
		})
	}
}

func TestCalculateScore_RepetitionBonus(t *testing.T) {
	s := newTestScorer(1000, 100)
	defer s.Stop()

	now := time.Now()

	tests := []struct {
		name          string
		recentEvents  int
		severity      int
		wantMinScore  int
	}{
		// Base score (severity 4 = 10) + no repetition bonus
		{"no_repetition", 1, 4, 10},
		// 5 events in 2 min = +20 bonus
		{"moderate_repetition", 5, 4, 30},
		// 10 events in 2 min = +30 bonus
		{"high_repetition", 10, 4, 40},
		// 20+ events in 2 min = +50 bonus
		{"extreme_repetition", 25, 4, 60},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			events := make([]time.Time, tt.recentEvents)
			for i := range events {
				events[i] = now.Add(-time.Duration(i) * time.Second)
			}

			event := &Event{Severity: tt.severity, Timestamp: now}
			ipScore := &IPScore{Events: events}
			got := s.calculateScore(event, ipScore)
			if got < tt.wantMinScore {
				t.Errorf("calculateScore(recentEvents=%d) = %d, want >= %d",
					tt.recentEvents, got, tt.wantMinScore)
			}
		})
	}
}

func TestCalculateScore_OldEventsNotCounted(t *testing.T) {
	s := newTestScorer(1000, 100)
	defer s.Stop()

	// Events older than 2 minutes should not contribute to repetition bonus
	oldEvents := []time.Time{
		time.Now().Add(-5 * time.Minute),
		time.Now().Add(-10 * time.Minute),
		time.Now().Add(-15 * time.Minute),
	}

	event := &Event{Severity: 4, Timestamp: time.Now()}
	ipScore := &IPScore{Events: oldEvents}
	got := s.calculateScore(event, ipScore)

	// Only base severity score (10), no repetition bonus
	if got != 10 {
		t.Errorf("calculateScore with old events = %d, want 10", got)
	}
}

// =============================================================================
// AddEvent Tests
// =============================================================================

func TestAddEvent_NewIP(t *testing.T) {
	s := newTestScorer(1000, 100)
	defer s.Stop()

	event := &Event{
		SrcIP:     "1.2.3.4",
		Severity:  1,
		Timestamp: time.Now(),
	}

	score := s.AddEvent(event)
	if score <= 0 {
		t.Errorf("expected positive score, got %d", score)
	}

	// Check the IP is tracked
	ipScore := s.GetIPScore("1.2.3.4")
	if ipScore == nil {
		t.Fatal("expected IP to be tracked")
	}
	if ipScore.TotalEvents != 1 {
		t.Errorf("expected TotalEvents=1, got %d", ipScore.TotalEvents)
	}
}

func TestAddEvent_ExistingIP(t *testing.T) {
	s := newTestScorer(1000, 100)
	defer s.Stop()

	event := &Event{
		SrcIP:     "1.2.3.4",
		Severity:  2,
		Timestamp: time.Now(),
	}

	s.AddEvent(event)
	s.AddEvent(event)
	s.AddEvent(event)

	ipScore := s.GetIPScore("1.2.3.4")
	if ipScore == nil {
		t.Fatal("expected IP to be tracked")
	}
	if ipScore.TotalEvents != 3 {
		t.Errorf("expected TotalEvents=3, got %d", ipScore.TotalEvents)
	}
	if len(ipScore.Events) != 3 {
		t.Errorf("expected 3 events, got %d", len(ipScore.Events))
	}
}

// =============================================================================
// LRU Eviction Tests
// =============================================================================

func TestAddEvent_LRUEviction(t *testing.T) {
	s := newTestScorer(3, 100) // Max 3 IPs
	defer s.Stop()

	// Add 3 IPs
	for _, ip := range []string{"1.1.1.1", "2.2.2.2", "3.3.3.3"} {
		s.AddEvent(&Event{SrcIP: ip, Severity: 1, Timestamp: time.Now()})
	}

	// All 3 should exist
	stats := s.GetStats()
	if stats["tracked_ips"] != 3 {
		t.Errorf("expected 3 tracked IPs, got %d", stats["tracked_ips"])
	}

	// Add a 4th IP - oldest should be evicted
	s.AddEvent(&Event{SrcIP: "4.4.4.4", Severity: 1, Timestamp: time.Now()})

	stats = s.GetStats()
	if stats["tracked_ips"] != 3 {
		t.Errorf("expected 3 tracked IPs after eviction, got %d", stats["tracked_ips"])
	}

	// The first IP (1.1.1.1) should have been evicted (it's oldest in LRU)
	if s.GetScore("1.1.1.1") != 0 {
		t.Error("expected evicted IP to have score 0")
	}
	if s.GetScore("4.4.4.4") == 0 {
		t.Error("expected new IP to have non-zero score")
	}
}

// =============================================================================
// Event Cap Tests
// =============================================================================

func TestAddEvent_EventCap(t *testing.T) {
	s := newTestScorer(1000, 5) // Max 5 events per IP
	defer s.Stop()

	// Add 10 events for the same IP
	for i := 0; i < 10; i++ {
		s.AddEvent(&Event{
			SrcIP:     "1.2.3.4",
			Severity:  1,
			Timestamp: time.Now(),
		})
	}

	ipScore := s.GetIPScore("1.2.3.4")
	if ipScore == nil {
		t.Fatal("expected IP to be tracked")
	}
	if len(ipScore.Events) > 5 {
		t.Errorf("expected max 5 events, got %d", len(ipScore.Events))
	}
	if ipScore.TotalEvents != 10 {
		t.Errorf("expected TotalEvents=10, got %d", ipScore.TotalEvents)
	}
}

// =============================================================================
// GetScore Tests
// =============================================================================

func TestGetScore_UnknownIP(t *testing.T) {
	s := newTestScorer(1000, 100)
	defer s.Stop()

	score := s.GetScore("9.9.9.9")
	if score != 0 {
		t.Errorf("expected 0 for unknown IP, got %d", score)
	}
}

func TestGetScore_KnownIP(t *testing.T) {
	s := newTestScorer(1000, 100)
	defer s.Stop()

	s.AddEvent(&Event{SrcIP: "1.2.3.4", Severity: 1, Timestamp: time.Now()})

	score := s.GetScore("1.2.3.4")
	if score == 0 {
		t.Error("expected non-zero score for tracked IP")
	}
}

// =============================================================================
// GetIPScore Tests
// =============================================================================

func TestGetIPScore_ReturnsACopy(t *testing.T) {
	s := newTestScorer(1000, 100)
	defer s.Stop()

	s.AddEvent(&Event{SrcIP: "1.2.3.4", Severity: 1, Timestamp: time.Now()})

	ipScore := s.GetIPScore("1.2.3.4")
	if ipScore == nil {
		t.Fatal("expected non-nil IPScore")
	}

	// Modifying the returned copy should not affect the scorer
	ipScore.CurrentScore = 9999
	original := s.GetIPScore("1.2.3.4")
	if original.CurrentScore == 9999 {
		t.Error("expected GetIPScore to return a copy, not a reference")
	}
}

func TestGetIPScore_UnknownIP(t *testing.T) {
	s := newTestScorer(1000, 100)
	defer s.Stop()

	ipScore := s.GetIPScore("9.9.9.9")
	if ipScore != nil {
		t.Error("expected nil for unknown IP")
	}
}

// =============================================================================
// GetAllScores Tests
// =============================================================================

func TestGetAllScores(t *testing.T) {
	s := newTestScorer(1000, 100)
	defer s.Stop()

	s.AddEvent(&Event{SrcIP: "1.1.1.1", Severity: 1, Timestamp: time.Now()})
	s.AddEvent(&Event{SrcIP: "2.2.2.2", Severity: 2, Timestamp: time.Now()})

	all := s.GetAllScores()
	if len(all) != 2 {
		t.Errorf("expected 2 scores, got %d", len(all))
	}
	if _, ok := all["1.1.1.1"]; !ok {
		t.Error("expected 1.1.1.1 in all scores")
	}
	if _, ok := all["2.2.2.2"]; !ok {
		t.Error("expected 2.2.2.2 in all scores")
	}
}

func TestGetAllScores_Empty(t *testing.T) {
	s := newTestScorer(1000, 100)
	defer s.Stop()

	all := s.GetAllScores()
	if len(all) != 0 {
		t.Errorf("expected 0 scores, got %d", len(all))
	}
}

// =============================================================================
// ResetScore Tests
// =============================================================================

func TestResetScore(t *testing.T) {
	s := newTestScorer(1000, 100)
	defer s.Stop()

	s.AddEvent(&Event{SrcIP: "1.2.3.4", Severity: 1, Timestamp: time.Now()})
	s.ResetScore("1.2.3.4")

	score := s.GetScore("1.2.3.4")
	if score != 0 {
		t.Errorf("expected 0 after ResetScore, got %d", score)
	}

	ipScore := s.GetIPScore("1.2.3.4")
	if ipScore != nil {
		t.Error("expected nil after ResetScore")
	}
}

func TestResetScore_UnknownIP(t *testing.T) {
	s := newTestScorer(1000, 100)
	defer s.Stop()

	// Should not panic
	s.ResetScore("9.9.9.9")
}

// =============================================================================
// GetStats Tests
// =============================================================================

func TestGetStats(t *testing.T) {
	s := newTestScorer(1000, 50)
	defer s.Stop()

	s.AddEvent(&Event{SrcIP: "1.1.1.1", Severity: 1, Timestamp: time.Now()})
	s.AddEvent(&Event{SrcIP: "1.1.1.1", Severity: 2, Timestamp: time.Now()})
	s.AddEvent(&Event{SrcIP: "2.2.2.2", Severity: 3, Timestamp: time.Now()})

	stats := s.GetStats()
	if stats["tracked_ips"] != 2 {
		t.Errorf("expected tracked_ips=2, got %d", stats["tracked_ips"])
	}
	if stats["max_ips"] != 1000 {
		t.Errorf("expected max_ips=1000, got %d", stats["max_ips"])
	}
	if stats["total_events"] != 3 {
		t.Errorf("expected total_events=3, got %d", stats["total_events"])
	}
	if stats["max_events_per"] != 50 {
		t.Errorf("expected max_events_per=50, got %d", stats["max_events_per"])
	}
	if stats["lru_size"] != 2 {
		t.Errorf("expected lru_size=2, got %d", stats["lru_size"])
	}
}

// =============================================================================
// applyDecay Tests
// =============================================================================

func TestApplyDecay_RemovesOldEvents(t *testing.T) {
	s := newTestScorer(1000, 100)
	s.config.ScoreDecay = 1 * time.Minute // Very short decay for testing
	defer s.Stop()

	// Manually add an IP with old events
	s.mu.Lock()
	s.scores["1.2.3.4"] = &IPScore{
		IP:         "1.2.3.4",
		Events:     []time.Time{time.Now().Add(-5 * time.Minute)},
		LastUpdate: time.Now().Add(-5 * time.Minute),
	}
	s.scores["1.2.3.4"].lruElement = s.lruList.PushFront("1.2.3.4")
	s.mu.Unlock()

	s.applyDecay()

	// Old IP should be removed
	if s.GetScore("1.2.3.4") != 0 {
		t.Error("expected old IP to be removed after decay")
	}
}

func TestApplyDecay_KeepsRecentEvents(t *testing.T) {
	s := newTestScorer(1000, 100)
	s.config.ScoreDecay = 1 * time.Hour
	defer s.Stop()

	s.AddEvent(&Event{SrcIP: "1.2.3.4", Severity: 1, Timestamp: time.Now()})

	s.applyDecay()

	// Recent IP should still be tracked
	if s.GetScore("1.2.3.4") == 0 {
		t.Error("expected recent IP to still be tracked after decay")
	}
}
