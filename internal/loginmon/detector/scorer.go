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

	"github.com/itcmsgr/nftban/internal/constants"
)

// BanAction represents a ban decision.
//
// For per-IP bans (the original LoginMon path), IP is set and Prefix.IsValid()
// returns false. For subnet-aggregation bans (v1.113), Prefix is set to the
// /24 (IPv4) or /64 (IPv6) target and IsSubnet is true; IP still carries the
// triggering IP (the one whose event tripped the threshold) for audit-log
// attribution.
type BanAction struct {
	IP       netip.Addr
	Prefix   netip.Prefix // v1.113: set for subnet-aggregation bans; zero value otherwise
	Duration time.Duration
	Reason   string
	Score    int32
	Service  string
	IsNew    bool // true if this is a new ban, false if escalation
	IsSubnet bool // v1.113: true when this ban targets a CIDR via subnet aggregation
}

// ScorerConfig holds scoring thresholds
type ScorerConfig struct {
	// Thresholds (score * 100 for precision)
	ThresholdTempBan   int32 // Score to trigger temp ban (default: 45 = 0.45)
	ThresholdEscalate  int32 // Score to escalate ban (default: 65 = 0.65)
	ThresholdPermanent int32 // Score for permanent ban (default: 100 = 1.00)

	// Ban durations
	TempBanDuration   time.Duration   // Initial temp ban (default: 15m)
	EscalateDurations []time.Duration // Escalation ladder (2h, 4h, 12h, 24h)

	// Decay
	ScoreDecayInterval time.Duration // How often to decay scores (default: 5m)
	ScoreDecayAmount   int32         // Points to decay per interval (default: 5)

	// Cleanup
	IPRetentionDuration time.Duration // How long to keep IP data (default: 24h)

	// Deduplication (exponential backoff)
	RecentBanWindow    time.Duration // Initial suppress window (default: 10s)
	RecentBanMaxWindow time.Duration // Maximum suppress window (default: 5m)

	// =========================================================================
	// v1.113 SUBNET AGGREGATION (D-LOGINMON-EXIM-SUBNET-ROTATION-GAP)
	// =========================================================================
	// Driven by srv1 production incident 2026-05-13: rotating /24 SMTP brute
	// force where each IP made 1-2 attempts, scoring 15-30 pts per IP — below
	// the 45-pt temp-ban threshold. Detection worked; aggregation was missing.
	// Opt-in default-false; observe-then-enforce maturity progression.

	SubnetAggEnabled        bool          // Master toggle (default: false)
	SubnetAggMode           string        // "observe" or "enforce" (default: "observe")
	SubnetWindow            time.Duration // Rolling-window duration (default: 5m)
	SubnetUniqueIPsMin      int           // Minimum distinct IPs in window (default: 5)
	SubnetMinTotalEvents    int           // Minimum total events in window (default: 10)
	SubnetIPv4Prefix        int           // IPv4 aggregation prefix (default: 24)
	SubnetIPv6Prefix        int           // IPv6 aggregation prefix (default: 64)
	SubnetAction            string        // "ban_cidr" (initial release); reserved: "pressure_score", "dynamic_threshold"
	SubnetCIDRBanDuration   time.Duration // Duration for subnet ban (0 = permanent; default: 24h)
	SubnetMaxTracked        int           // Max simultaneously-tracked subnets (default: 10000; LRU eviction)
	SubnetTrustedAllowlist  []netip.Prefix // Operator-curated trusted-provider subnets (skip aggregation)
	SubnetTriggerReasonOnly bool          // Restrict aggregation to EXIM_AUTH_FAIL only (default: true)
}

// DefaultScorerConfig returns production defaults
func DefaultScorerConfig() ScorerConfig {
	return ScorerConfig{
		ThresholdTempBan:    45,  // 0.45
		ThresholdEscalate:   65,  // 0.65
		ThresholdPermanent:  100, // 1.00
		TempBanDuration:     constants.LoginmonTempBanDuration,
		EscalateDurations:   []time.Duration{2 * time.Hour, 4 * time.Hour, 12 * time.Hour, 24 * time.Hour},
		ScoreDecayInterval:  constants.LoginmonScoreDecayInterval,
		ScoreDecayAmount:    5,
		IPRetentionDuration: constants.LoginmonIPRetention,
		RecentBanWindow:     constants.LoginmonRecentBanWindow,
		RecentBanMaxWindow:  constants.LoginmonRecentBanMaxWindow,

		// v1.113 subnet aggregation — opt-in default-false
		SubnetAggEnabled:        false,
		SubnetAggMode:           "observe",
		SubnetWindow:            5 * time.Minute,
		SubnetUniqueIPsMin:      5,
		SubnetMinTotalEvents:    10,
		SubnetIPv4Prefix:        24,
		SubnetIPv6Prefix:        64,
		SubnetAction:            "ban_cidr",
		SubnetCIDRBanDuration:   24 * time.Hour,
		SubnetMaxTracked:        10000,
		SubnetTrustedAllowlist:  nil,
		SubnetTriggerReasonOnly: true,
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

// SubnetState tracks per-prefix aggregation state for the v1.113 subnet
// aggregation primitive. Each entry represents one /24 (IPv4) or /64 (IPv6)
// prefix being observed for rotating-brute-force patterns. Values are
// in-memory only; the rolling window is bounded by ScorerConfig.SubnetWindow
// and the map size is bounded by ScorerConfig.SubnetMaxTracked.
type SubnetState struct {
	// UniqueIPs maps source IPs seen in this prefix to their last-seen
	// timestamp. Used both for the unique-IP-count threshold and for
	// per-IP timestamp eviction when the rolling window expires.
	UniqueIPs map[netip.Addr]time.Time

	TotalEvents int       // Total events in this prefix within the rolling window.
	FirstSeen   time.Time // Anchor for the rolling window (advances on window-expiry reset).
	LastSeen    time.Time // Most recent event timestamp.
	Banned      bool      // Set true once the subnet has been banned (in enforce mode).
	BannedAt    time.Time // Timestamp of the subnet ban.
	PressureHits int64    // Cumulative observe-mode pressure events emitted (audit counter).
}

// Scorer tracks IP scores and triggers bans
type Scorer struct {
	config ScorerConfig
	ips    map[netip.Addr]*IPState
	mu     sync.RWMutex

	// Track recently banned IPs to prevent duplicate ban storms (exponential backoff)
	recentBans map[netip.Addr]*recentBanEntry

	// v1.113: subnet-aggregation map keyed by prefix (e.g., 81.30.98.0/24).
	// Guarded by the same mutex `mu` as the per-IP map for simplicity; the
	// subnet path runs under write-lock during RecordVerdict.
	subnets map[netip.Prefix]*SubnetState

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

	// v1.113 subnet-aggregation counters
	SubnetPressureCount atomic.Int64 // Cumulative observe-mode pressure events emitted across all prefixes.
	SubnetBansTotal     atomic.Int64 // Cumulative CIDR bans triggered in enforce mode.
	SubnetWatchActive   atomic.Int64 // Current number of prefixes being actively watched (gauge).
}

// NewScorer creates a new scoring engine
func NewScorer(config ScorerConfig) *Scorer {
	return &Scorer{
		config:     config,
		ips:        make(map[netip.Addr]*IPState),
		recentBans: make(map[netip.Addr]*recentBanEntry),
		subnets:    make(map[netip.Prefix]*SubnetState),
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

	// v1.113: subnet aggregation runs BEFORE per-IP threshold check so that
	// a /24 ban can fire on an IP whose own score is still below temp-ban.
	// The per-IP path still runs after to preserve original ban semantics.
	if s.config.SubnetAggEnabled {
		if action := s.checkSubnetAggregation(v, now); action != nil {
			return action
		}
	}

	// Check per-IP thresholds (the original LoginMon path)
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
		TotalDetections:     s.stats.TotalDetections.Load(),
		TotalBans:           s.stats.TotalBans.Load(),
		TotalEscalations:    s.stats.TotalEscalations.Load(),
		TotalPermanent:      s.stats.TotalPermanent.Load(),
		UniqueIPs:           s.stats.UniqueIPs.Load(),
		DetectionsIPv4:      s.stats.DetectionsIPv4.Load(),
		DetectionsIPv6:      s.stats.DetectionsIPv6.Load(),
		BansIPv4:            s.stats.BansIPv4.Load(),
		BansIPv6:            s.stats.BansIPv6.Load(),
		UniqueIPv4:          s.stats.UniqueIPv4.Load(),
		UniqueIPv6:          s.stats.UniqueIPv6.Load(),
		DetectionsByService: s.getServiceDetectionCounts(),
		BansByService:       s.getServiceBanCounts(),
		DetectionsByReason:  s.getReasonDetectionCounts(),
		BansByReason:        s.getReasonBanCounts(),
		SubnetPressureCount: s.stats.SubnetPressureCount.Load(),
		SubnetBansTotal:     s.stats.SubnetBansTotal.Load(),
		SubnetWatchActive:   s.stats.SubnetWatchActive.Load(),
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

	// v1.113 subnet aggregation
	SubnetPressureCount int64
	SubnetBansTotal     int64
	SubnetWatchActive   int64
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

// =============================================================================
// v1.113 SUBNET AGGREGATION
// =============================================================================
// Closes D-LOGINMON-EXIM-SUBNET-ROTATION-GAP from srv1 production incident
// 2026-05-13. Operator-locked design:
//   - 8 config knobs (ENABLED + MODE + WINDOW + UNIQUE_IPS + MIN_TOTAL_EVENTS
//     + IPV4_PREFIX + IPV6_PREFIX + ACTION)
//   - 6 false-positive guards (reason-filter + dual-threshold + window +
//     trusted-provider allowlist + private-range-blocked + audit log)
//   - 3 action types but only ban_cidr ships v1.113 (pressure_score and
//     dynamic_threshold reserved for v1.114+ schema-unfreeze considerations)
// Caller must hold s.mu (write-lock). Returns *BanAction in enforce mode when
// thresholds + guards pass; returns nil in observe mode (pressure event
// counted on stats) or when guards reject.

// checkSubnetAggregation is the main entry point. It applies all guards in
// order and either emits a pressure event (observe mode) or returns a CIDR
// BanAction (enforce mode).
func (s *Scorer) checkSubnetAggregation(v Verdict, now time.Time) *BanAction {
	// Guard 1: reason-filter — restrict aggregation to EXIM_AUTH_FAIL (configurable).
	if s.config.SubnetTriggerReasonOnly && v.Reason != ReasonEximAuthFail {
		return nil
	}

	// Compute the aggregation prefix for this IP.
	prefix, ok := s.subnetPrefixForIP(v.IP)
	if !ok {
		return nil // invalid IP family or zero-prefix config
	}

	// Guard 5: private/internal ranges blocked.
	if isPrivateOrInternalPrefix(prefix) {
		return nil
	}

	// Guard 4: trusted-provider allowlist.
	if isInTrustedAllowlist(prefix, s.config.SubnetTrustedAllowlist) {
		return nil
	}

	// Get or create subnet state under existing write-lock.
	state := s.getOrCreateSubnetState(prefix, now)
	if state == nil {
		return nil // cap reached and eviction declined this prefix
	}

	// Guard 3: rolling window — if window expired since FirstSeen, reset state.
	if now.Sub(state.FirstSeen) > s.config.SubnetWindow {
		state.UniqueIPs = make(map[netip.Addr]time.Time)
		state.TotalEvents = 0
		state.FirstSeen = now
		state.Banned = false // window reset re-arms enforcement
	}

	// Record this event.
	state.UniqueIPs[v.IP] = now
	state.TotalEvents++
	state.LastSeen = now

	// Suppress repeated triggers on already-banned subnets within window.
	if state.Banned {
		return nil
	}

	// Guard 2: dual-threshold (both unique IPs AND total events).
	if len(state.UniqueIPs) < s.config.SubnetUniqueIPsMin {
		return nil
	}
	if state.TotalEvents < s.config.SubnetMinTotalEvents {
		return nil
	}

	// Thresholds met. Branch on mode.
	switch s.config.SubnetAggMode {
	case "enforce":
		return s.emitSubnetBan(prefix, state, v, now)
	default: // "observe" or anything else falls through to observe-only
		s.stats.SubnetPressureCount.Add(1)
		state.PressureHits++
		// Audit-log emission is the caller's responsibility (module.go logs
		// pressure events at INFO level so the wire-format stays purely
		// in-memory at the scorer layer).
		return nil
	}
}

// subnetPrefixForIP returns the aggregation prefix for the given IP under the
// configured IPv4Prefix / IPv6Prefix bit lengths. Returns (zero, false) if the
// IP is invalid or the configured prefix length is unusable.
func (s *Scorer) subnetPrefixForIP(ip netip.Addr) (netip.Prefix, bool) {
	if !ip.IsValid() {
		return netip.Prefix{}, false
	}
	bits := s.config.SubnetIPv4Prefix
	if ip.Is6() && !ip.Is4In6() {
		bits = s.config.SubnetIPv6Prefix
	}
	if bits <= 0 {
		return netip.Prefix{}, false
	}
	p, err := ip.Prefix(bits)
	if err != nil {
		return netip.Prefix{}, false
	}
	return p.Masked(), true
}

// getOrCreateSubnetState returns the SubnetState for prefix, allocating a new
// one if needed. Enforces SubnetMaxTracked by refusing new entries when the
// map is full and the candidate prefix isn't already present.
func (s *Scorer) getOrCreateSubnetState(prefix netip.Prefix, now time.Time) *SubnetState {
	if state, ok := s.subnets[prefix]; ok {
		return state
	}
	if s.config.SubnetMaxTracked > 0 && len(s.subnets) >= s.config.SubnetMaxTracked {
		// Cap reached. Decline new prefix rather than evict — the cap is a
		// safety bound; LRU eviction is a future-debt enhancement.
		return nil
	}
	state := &SubnetState{
		UniqueIPs: make(map[netip.Addr]time.Time),
		FirstSeen: now,
	}
	s.subnets[prefix] = state
	s.stats.SubnetWatchActive.Store(int64(len(s.subnets)))
	return state
}

// emitSubnetBan builds a BanAction targeting the CIDR prefix and records the
// ban in stats. Caller must hold the write-lock.
func (s *Scorer) emitSubnetBan(prefix netip.Prefix, state *SubnetState, v Verdict, now time.Time) *BanAction {
	state.Banned = true
	state.BannedAt = now
	s.stats.SubnetBansTotal.Add(1)
	s.stats.TotalBans.Add(1)
	// Subnet bans are an additional ban category; record per-service/reason
	// counters using the triggering verdict's labels.
	s.incrementServiceBan(v.Service)
	s.incrementReasonBan(v.Reason)
	return &BanAction{
		IP:       v.IP, // triggering IP (audit-log attribution)
		Prefix:   prefix,
		Duration: s.config.SubnetCIDRBanDuration,
		Reason:   ReasonName[v.Reason] + "_subnet",
		Score:    int32(len(state.UniqueIPs)), // unique-IP count as "score"
		Service:  v.Service,
		IsNew:    true,
		IsSubnet: true,
	}
}

// SubnetStateFor returns a copy of the subnet state for the given prefix.
// Returns (zero, false) when the prefix is not currently tracked. Thread-safe.
// Useful for tests and audit-log emission from module.go.
func (s *Scorer) SubnetStateFor(prefix netip.Prefix) (SubnetState, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	state, ok := s.subnets[prefix]
	if !ok {
		return SubnetState{}, false
	}
	// Return a snapshot copy with a duplicated UniqueIPs map.
	cp := *state
	cp.UniqueIPs = make(map[netip.Addr]time.Time, len(state.UniqueIPs))
	for k, t := range state.UniqueIPs {
		cp.UniqueIPs[k] = t
	}
	return cp, true
}

// TrackedSubnets returns the number of currently tracked subnet prefixes.
// Thread-safe.
func (s *Scorer) TrackedSubnets() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.subnets)
}

// isPrivateOrInternalPrefix returns true when the prefix overlaps with
// reserved/private/internal ranges per RFC 1918 + RFC 4193 + RFC 6890.
// Subnets that match any of these are exempt from aggregation (guard 5).
func isPrivateOrInternalPrefix(p netip.Prefix) bool {
	if !p.IsValid() {
		return true // never aggregate invalid prefixes
	}
	addr := p.Addr()
	if addr.IsLoopback() {
		return true
	}
	if addr.IsPrivate() {
		return true // covers 10/8, 172.16/12, 192.168/16, fc00::/7
	}
	if addr.IsLinkLocalUnicast() || addr.IsLinkLocalMulticast() {
		return true // covers 169.254/16, fe80::/10
	}
	if addr.IsUnspecified() {
		return true
	}
	if addr.IsMulticast() {
		return true
	}
	return false
}

// isInTrustedAllowlist returns true when the candidate prefix is contained
// within any operator-curated trusted subnet. Trusted mail-relay subnets
// (Google, Microsoft, Apple, etc.) should be excluded from aggregation to
// avoid false positives during high-traffic mail-flow events.
func isInTrustedAllowlist(candidate netip.Prefix, allowlist []netip.Prefix) bool {
	if len(allowlist) == 0 {
		return false
	}
	for _, trusted := range allowlist {
		if !trusted.IsValid() {
			continue
		}
		// candidate is allowlisted if it is contained within OR equal to a
		// trusted prefix.
		if trusted.Contains(candidate.Addr()) {
			return true
		}
	}
	return false
}
