// =============================================================================
// NFTBan v1.0.30 - IP Scoring Engine
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: detector
// Purpose: Track detection scores per IP and trigger bans at threshold
//
// meta:name="scorer"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="detector"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-12"
// meta:description="IP scoring engine with threshold-based ban triggers"
//
// Architecture:
// - Thread-safe IP score tracking
// - Configurable thresholds for temp/escalation/permanent bans
// - Automatic score decay over time
// - Statistics tracking for all detections and bans
//
// meta:inventory.files="scorer.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package detector

import (
	"net/netip"
	"sync"
	"sync/atomic"
	"time"

	"github.com/itcmsgr/nftban/pkg/constants"
)

// BanAction represents a ban decision
type BanAction struct {
	IP       netip.Addr
	Duration time.Duration
	Reason   string
	Score    int32
	Service  string
	IsNew    bool // true if this is a new ban, false if escalation
}

// ScorerConfig holds scoring thresholds
type ScorerConfig struct {
	// Thresholds (score * 100 for precision)
	ThresholdTempBan   int32         // Score to trigger temp ban (default: 45 = 0.45)
	ThresholdEscalate  int32         // Score to escalate ban (default: 65 = 0.65)
	ThresholdPermanent int32         // Score for permanent ban (default: 100 = 1.00)

	// Ban durations
	TempBanDuration       time.Duration // Initial temp ban (default: 15m)
	EscalateDurations     []time.Duration // Escalation ladder (2h, 4h, 12h, 24h)

	// Decay
	ScoreDecayInterval    time.Duration // How often to decay scores (default: 5m)
	ScoreDecayAmount      int32         // Points to decay per interval (default: 5)

	// Cleanup
	IPRetentionDuration   time.Duration // How long to keep IP data (default: 24h)

	// Deduplication (exponential backoff)
	RecentBanWindow       time.Duration // Initial suppress window (default: 10s)
	RecentBanMaxWindow    time.Duration // Maximum suppress window (default: 5m)
}

// DefaultScorerConfig returns production defaults
func DefaultScorerConfig() ScorerConfig {
	return ScorerConfig{
		ThresholdTempBan:      45,  // 0.45
		ThresholdEscalate:     65,  // 0.65
		ThresholdPermanent:    100, // 1.00
		TempBanDuration:       constants.LoginmonTempBanDuration,
		EscalateDurations:     []time.Duration{2 * time.Hour, 4 * time.Hour, 12 * time.Hour, 24 * time.Hour},
		ScoreDecayInterval:    constants.LoginmonScoreDecayInterval,
		ScoreDecayAmount:      5,
		IPRetentionDuration:   constants.LoginmonIPRetention,
		RecentBanWindow:       constants.LoginmonRecentBanWindow,
		RecentBanMaxWindow:    constants.LoginmonRecentBanMaxWindow,
	}
}

// IPState tracks state for a single IP
type IPState struct {
	Score        int32     // Current score (scaled by 100)
	Detections   int32     // Total detection count
	BanCount     int32     // Number of times banned
	LastSeen     time.Time // Last detection time
	LastBan      time.Time // Last ban time
	FirstSeen    time.Time // First detection time
	LastService  string    // Last service that detected this IP
	LastReason   uint16    // Last reason code
}

// recentBanEntry tracks deduplication state with exponential backoff
type recentBanEntry struct {
	BannedAt time.Time     // When the ban was recorded
	Window   time.Duration // Current suppress window (doubles each time)
}

// Scorer tracks IP scores and triggers bans
type Scorer struct {
	config ScorerConfig
	ips    map[netip.Addr]*IPState
	mu     sync.RWMutex

	// Track recently banned IPs to prevent duplicate ban storms (exponential backoff)
	recentBans map[netip.Addr]*recentBanEntry

	// Statistics (atomic for lock-free reads)
	stats Stats
}

// Stats holds global statistics
type Stats struct {
	TotalDetections   atomic.Int64
	TotalBans         atomic.Int64
	TotalEscalations  atomic.Int64
	TotalPermanent    atomic.Int64
	UniqueIPs         atomic.Int64

	// IPv4/IPv6 tracking
	DetectionsIPv4    atomic.Int64
	DetectionsIPv6    atomic.Int64
	BansIPv4          atomic.Int64
	BansIPv6          atomic.Int64
	UniqueIPv4        atomic.Int64
	UniqueIPv6        atomic.Int64

	// Per-service detection counts
	DetectionsByService sync.Map // map[string]*atomic.Int64

	// Per-service ban counts
	BansByService sync.Map // map[string]*atomic.Int64

	// Per-reason detection counts
	DetectionsByReason sync.Map // map[uint16]*atomic.Int64

	// Per-reason ban counts
	BansByReason sync.Map // map[uint16]*atomic.Int64
}

// NewScorer creates a new scoring engine
func NewScorer(config ScorerConfig) *Scorer {
	return &Scorer{
		config:     config,
		ips:        make(map[netip.Addr]*IPState),
		recentBans: make(map[netip.Addr]*recentBanEntry),
	}
}

// NewScorerDefault creates a scorer with default config
func NewScorerDefault() *Scorer {
	return NewScorer(DefaultScorerConfig())
}

// RecordVerdict records a detection verdict and returns ban action if threshold reached
func (s *Scorer) RecordVerdict(v Verdict) *BanAction {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()

	// Get or create IP state
	state, exists := s.ips[v.IP]
	if !exists {
		state = &IPState{
			FirstSeen: now,
		}
		s.ips[v.IP] = state
		s.stats.UniqueIPs.Add(1)

		// Track IPv4 vs IPv6 unique IPs
		if v.IP.Is4() {
			s.stats.UniqueIPv4.Add(1)
		} else {
			s.stats.UniqueIPv6.Add(1)
		}
	}

	// Update state
	state.Score += int32(v.ScoreDelta)
	state.Detections++
	state.LastSeen = now
	state.LastService = v.Service
	state.LastReason = v.Reason

	// Update statistics
	s.stats.TotalDetections.Add(1)
	s.incrementServiceDetection(v.Service)
	s.incrementReasonDetection(v.Reason)

	// Track IPv4 vs IPv6 detections
	if v.IP.Is4() {
		s.stats.DetectionsIPv4.Add(1)
	} else {
		s.stats.DetectionsIPv6.Add(1)
	}

	// Check thresholds
	return s.checkThresholds(v.IP, state, v)
}

// checkThresholds determines if a ban should be triggered
func (s *Scorer) checkThresholds(ip netip.Addr, state *IPState, v Verdict) *BanAction {
	score := state.Score

	// Skip if recently banned to prevent duplicate ban storms (exponential backoff)
	if s.config.RecentBanWindow > 0 {
		if entry, exists := s.recentBans[ip]; exists {
			if time.Since(entry.BannedAt) < entry.Window {
				// Still within suppress window - double it for next time (up to max)
				entry.Window *= 2
				if entry.Window > s.config.RecentBanMaxWindow {
					entry.Window = s.config.RecentBanMaxWindow
				}
				return nil
			}
			// Window expired, remove entry
			delete(s.recentBans, ip)
		}
	}

	// Permanent ban threshold
	if score >= s.config.ThresholdPermanent {
		now := time.Now()
		state.BanCount++
		state.LastBan = now
		s.recentBans[ip] = &recentBanEntry{BannedAt: now, Window: s.config.RecentBanWindow}
		s.stats.TotalBans.Add(1)
		s.stats.TotalPermanent.Add(1)
		s.recordBanStats(ip, v)
		return &BanAction{
			IP:       ip,
			Duration: 0, // 0 = permanent
			Reason:   ReasonName[v.Reason],
			Score:    score,
			Service:  v.Service,
			IsNew:    state.BanCount == 1,
		}
	}

	// Escalation threshold
	if score >= s.config.ThresholdEscalate {
		now := time.Now()
		state.BanCount++
		state.LastBan = now
		s.recentBans[ip] = &recentBanEntry{BannedAt: now, Window: s.config.RecentBanWindow}
		s.stats.TotalBans.Add(1)
		s.stats.TotalEscalations.Add(1)
		s.recordBanStats(ip, v)

		// Determine escalation duration based on ban count
		durIdx := int(state.BanCount) - 1
		if durIdx >= len(s.config.EscalateDurations) {
			durIdx = len(s.config.EscalateDurations) - 1
		}
		duration := s.config.EscalateDurations[durIdx]

		return &BanAction{
			IP:       ip,
			Duration: duration,
			Reason:   ReasonName[v.Reason],
			Score:    score,
			Service:  v.Service,
			IsNew:    state.BanCount == 1,
		}
	}

	// Temp ban threshold
	if score >= s.config.ThresholdTempBan {
		now := time.Now()
		state.BanCount++
		state.LastBan = now
		s.recentBans[ip] = &recentBanEntry{BannedAt: now, Window: s.config.RecentBanWindow}
		s.stats.TotalBans.Add(1)
		s.recordBanStats(ip, v)
		return &BanAction{
			IP:       ip,
			Duration: s.config.TempBanDuration,
			Reason:   ReasonName[v.Reason],
			Score:    score,
			Service:  v.Service,
			IsNew:    state.BanCount == 1,
		}
	}

	return nil
}

// recordBanStats updates ban-specific statistics
func (s *Scorer) recordBanStats(ip netip.Addr, v Verdict) {
	// IPv4 vs IPv6 bans
	if ip.Is4() {
		s.stats.BansIPv4.Add(1)
	} else {
		s.stats.BansIPv6.Add(1)
	}

	// Per-service bans
	s.incrementServiceBan(v.Service)

	// Per-reason bans
	s.incrementReasonBan(v.Reason)
}

// GetIPState returns the current state for an IP (thread-safe copy)
func (s *Scorer) GetIPState(ip netip.Addr) (IPState, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	state, exists := s.ips[ip]
	if !exists {
		return IPState{}, false
	}
	return *state, true
}

// GetStats returns current statistics snapshot
func (s *Scorer) GetStats() StatsSnapshot {
	return StatsSnapshot{
		TotalDetections:    s.stats.TotalDetections.Load(),
		TotalBans:          s.stats.TotalBans.Load(),
		TotalEscalations:   s.stats.TotalEscalations.Load(),
		TotalPermanent:     s.stats.TotalPermanent.Load(),
		UniqueIPs:          s.stats.UniqueIPs.Load(),
		DetectionsIPv4:     s.stats.DetectionsIPv4.Load(),
		DetectionsIPv6:     s.stats.DetectionsIPv6.Load(),
		BansIPv4:           s.stats.BansIPv4.Load(),
		BansIPv6:           s.stats.BansIPv6.Load(),
		UniqueIPv4:         s.stats.UniqueIPv4.Load(),
		UniqueIPv6:         s.stats.UniqueIPv6.Load(),
		DetectionsByService: s.getServiceDetectionCounts(),
		BansByService:       s.getServiceBanCounts(),
		DetectionsByReason:  s.getReasonDetectionCounts(),
		BansByReason:        s.getReasonBanCounts(),
	}
}

// StatsSnapshot is a point-in-time copy of statistics
type StatsSnapshot struct {
	TotalDetections  int64
	TotalBans        int64
	TotalEscalations int64
	TotalPermanent   int64
	UniqueIPs        int64

	// IPv4/IPv6 breakdown
	DetectionsIPv4 int64
	DetectionsIPv6 int64
	BansIPv4       int64
	BansIPv6       int64
	UniqueIPv4     int64
	UniqueIPv6     int64

	// By service
	DetectionsByService map[string]int64
	BansByService       map[string]int64

	// By reason
	DetectionsByReason map[string]int64
	BansByReason       map[string]int64
}

// DecayScores reduces all IP scores (call periodically)
func (s *Scorer) DecayScores() {
	s.mu.Lock()
	defer s.mu.Unlock()

	decay := s.config.ScoreDecayAmount
	for _, state := range s.ips {
		if state.Score > 0 {
			state.Score -= decay
			if state.Score < 0 {
				state.Score = 0
			}
		}
	}
}

// Cleanup removes old IP entries
func (s *Scorer) Cleanup() int {
	s.mu.Lock()
	defer s.mu.Unlock()

	cutoff := time.Now().Add(-s.config.IPRetentionDuration)
	removed := 0

	for ip, state := range s.ips {
		if state.LastSeen.Before(cutoff) && state.Score == 0 {
			delete(s.ips, ip)
			removed++
		}
	}

	return removed
}

// Reset clears all state (for testing)
func (s *Scorer) Reset() {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.ips = make(map[netip.Addr]*IPState)
	s.recentBans = make(map[netip.Addr]*recentBanEntry)
	s.stats = Stats{}
}

// helper functions

func (s *Scorer) incrementServiceDetection(service string) {
	val, _ := s.stats.DetectionsByService.LoadOrStore(service, &atomic.Int64{})
	if v, ok := val.(*atomic.Int64); ok {
		v.Add(1)
	}
}

func (s *Scorer) incrementServiceBan(service string) {
	val, _ := s.stats.BansByService.LoadOrStore(service, &atomic.Int64{})
	if v, ok := val.(*atomic.Int64); ok {
		v.Add(1)
	}
}

func (s *Scorer) incrementReasonDetection(reason uint16) {
	val, _ := s.stats.DetectionsByReason.LoadOrStore(reason, &atomic.Int64{})
	if v, ok := val.(*atomic.Int64); ok {
		v.Add(1)
	}
}

func (s *Scorer) incrementReasonBan(reason uint16) {
	val, _ := s.stats.BansByReason.LoadOrStore(reason, &atomic.Int64{})
	if v, ok := val.(*atomic.Int64); ok {
		v.Add(1)
	}
}

func (s *Scorer) getServiceDetectionCounts() map[string]int64 {
	result := make(map[string]int64)
	s.stats.DetectionsByService.Range(func(key, value interface{}) bool {
		if k, ok := key.(string); ok {
			if v, ok := value.(*atomic.Int64); ok {
				result[k] = v.Load()
			}
		}
		return true
	})
	return result
}

func (s *Scorer) getServiceBanCounts() map[string]int64 {
	result := make(map[string]int64)
	s.stats.BansByService.Range(func(key, value interface{}) bool {
		if k, ok := key.(string); ok {
			if v, ok := value.(*atomic.Int64); ok {
				result[k] = v.Load()
			}
		}
		return true
	})
	return result
}

func (s *Scorer) getReasonDetectionCounts() map[string]int64 {
	result := make(map[string]int64)
	s.stats.DetectionsByReason.Range(func(key, value interface{}) bool {
		if reasonCode, ok := key.(uint16); ok {
			reasonName := ReasonName[reasonCode]
			if reasonName == "" {
				reasonName = "unknown"
			}
			if v, ok := value.(*atomic.Int64); ok {
				result[reasonName] = v.Load()
			}
		}
		return true
	})
	return result
}

func (s *Scorer) getReasonBanCounts() map[string]int64 {
	result := make(map[string]int64)
	s.stats.BansByReason.Range(func(key, value interface{}) bool {
		if reasonCode, ok := key.(uint16); ok {
			reasonName := ReasonName[reasonCode]
			if reasonName == "" {
				reasonName = "unknown"
			}
			if v, ok := value.(*atomic.Int64); ok {
				result[reasonName] = v.Load()
			}
		}
		return true
	})
	return result
}

// TrackedIPs returns the number of currently tracked IPs
func (s *Scorer) TrackedIPs() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.ips)
}
