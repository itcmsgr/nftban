// =============================================================================
// NFTBan v1.0.30 - Scorer Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// meta:name="scorer_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-12"
// meta:description="Unit tests for IP scoring engine"
//
// meta:inventory.files="scorer_test.go"
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
	"testing"
	"time"
)

func TestScorer_BasicCounting(t *testing.T) {
	s := NewScorerDefault()

	ip := netip.MustParseAddr("192.168.1.100")

	// Record 3 detections
	s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHFailedPassword, ScoreDelta: 10, Service: "ssh"})
	s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHInvalidUser, ScoreDelta: 15, Service: "ssh"})
	s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHRootAttempt, ScoreDelta: 20, Service: "ssh"})

	stats := s.GetStats()

	if stats.TotalDetections != 3 {
		t.Errorf("TotalDetections = %d, want 3", stats.TotalDetections)
	}

	if stats.UniqueIPs != 1 {
		t.Errorf("UniqueIPs = %d, want 1", stats.UniqueIPs)
	}

	if stats.DetectionsByService["ssh"] != 3 {
		t.Errorf("DetectionsByService[ssh] = %d, want 3", stats.DetectionsByService["ssh"])
	}

	// All should be IPv4
	if stats.DetectionsIPv4 != 3 {
		t.Errorf("DetectionsIPv4 = %d, want 3", stats.DetectionsIPv4)
	}
	if stats.UniqueIPv4 != 1 {
		t.Errorf("UniqueIPv4 = %d, want 1", stats.UniqueIPv4)
	}

	// Check IP state
	state, ok := s.GetIPState(ip)
	if !ok {
		t.Fatal("IP state not found")
	}

	if state.Score != 45 { // 10 + 15 + 20
		t.Errorf("Score = %d, want 45", state.Score)
	}

	if state.Detections != 3 {
		t.Errorf("Detections = %d, want 3", state.Detections)
	}
}

func TestScorer_TempBanThreshold(t *testing.T) {
	s := NewScorerDefault()

	ip := netip.MustParseAddr("10.0.0.1")

	// Score = 10, no ban
	action := s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHFailedPassword, ScoreDelta: 10, Service: "ssh"})
	if action != nil {
		t.Error("Expected no ban at score 10")
	}

	// Score = 25, no ban
	action = s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHInvalidUser, ScoreDelta: 15, Service: "ssh"})
	if action != nil {
		t.Error("Expected no ban at score 25")
	}

	// Score = 45, should trigger temp ban
	action = s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHRootAttempt, ScoreDelta: 20, Service: "ssh"})
	if action == nil {
		t.Fatal("Expected temp ban at score 45")
	}

	if action.Duration != 15*time.Minute {
		t.Errorf("Duration = %v, want 15m", action.Duration)
	}

	if action.Score != 45 {
		t.Errorf("Score = %d, want 45", action.Score)
	}

	stats := s.GetStats()
	if stats.TotalBans != 1 {
		t.Errorf("TotalBans = %d, want 1", stats.TotalBans)
	}
}

func TestScorer_EscalationThreshold(t *testing.T) {
	s := NewScorerDefault()

	ip := netip.MustParseAddr("10.0.0.2")

	// Get to escalation threshold (65)
	s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHPreauth, ScoreDelta: 20, Service: "ssh"})
	s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHPreauth, ScoreDelta: 20, Service: "ssh"})
	action := s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHTooManyFailures, ScoreDelta: 30, Service: "ssh"})

	if action == nil {
		t.Fatal("Expected escalation ban at score 70")
	}

	// Should be escalation duration (2h for first escalation)
	if action.Duration != 2*time.Hour {
		t.Errorf("Duration = %v, want 2h", action.Duration)
	}

	stats := s.GetStats()
	if stats.TotalEscalations != 1 {
		t.Errorf("TotalEscalations = %d, want 1", stats.TotalEscalations)
	}
}

func TestScorer_PermanentBanThreshold(t *testing.T) {
	config := DefaultScorerConfig()
	config.RecentBanWindow = 0 // Disable deduplication for rapid test bans
	s := NewScorer(config)

	ip := netip.MustParseAddr("10.0.0.3")

	// Get to permanent threshold (100)
	// Note: intermediate bans may trigger but we disable deduplication to allow continued scoring
	s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHTooManyFailures, ScoreDelta: 30, Service: "ssh"})
	s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHTooManyFailures, ScoreDelta: 30, Service: "ssh"})
	s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHTooManyFailures, ScoreDelta: 30, Service: "ssh"})
	action := s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHPreauth, ScoreDelta: 20, Service: "ssh"})

	if action == nil {
		t.Fatal("Expected permanent ban at score 110")
	}

	// Duration = 0 means permanent
	if action.Duration != 0 {
		t.Errorf("Duration = %v, want 0 (permanent)", action.Duration)
	}

	stats := s.GetStats()
	if stats.TotalPermanent != 1 {
		t.Errorf("TotalPermanent = %d, want 1", stats.TotalPermanent)
	}
}

func TestScorer_MultipleIPs(t *testing.T) {
	s := NewScorerDefault()

	ip1 := netip.MustParseAddr("192.168.1.1")
	ip2 := netip.MustParseAddr("192.168.1.2")
	ip3 := netip.MustParseAddr("192.168.1.3")

	// Record detections for different IPs
	s.RecordVerdict(Verdict{IP: ip1, Reason: ReasonSSHFailedPassword, ScoreDelta: 10, Service: "ssh"})
	s.RecordVerdict(Verdict{IP: ip2, Reason: ReasonDovecotAuthFail, ScoreDelta: 15, Service: "dovecot"})
	s.RecordVerdict(Verdict{IP: ip3, Reason: ReasonFTPAuthFail, ScoreDelta: 15, Service: "ftp"})
	s.RecordVerdict(Verdict{IP: ip1, Reason: ReasonSSHInvalidUser, ScoreDelta: 15, Service: "ssh"})

	stats := s.GetStats()

	if stats.TotalDetections != 4 {
		t.Errorf("TotalDetections = %d, want 4", stats.TotalDetections)
	}

	if stats.UniqueIPs != 3 {
		t.Errorf("UniqueIPs = %d, want 3", stats.UniqueIPs)
	}

	if stats.DetectionsByService["ssh"] != 2 {
		t.Errorf("DetectionsByService[ssh] = %d, want 2", stats.DetectionsByService["ssh"])
	}

	if stats.DetectionsByService["dovecot"] != 1 {
		t.Errorf("DetectionsByService[dovecot] = %d, want 1", stats.DetectionsByService["dovecot"])
	}

	if stats.DetectionsByService["ftp"] != 1 {
		t.Errorf("DetectionsByService[ftp] = %d, want 1", stats.DetectionsByService["ftp"])
	}

	// Check individual IP scores
	state1, _ := s.GetIPState(ip1)
	if state1.Score != 25 {
		t.Errorf("IP1 Score = %d, want 25", state1.Score)
	}

	state2, _ := s.GetIPState(ip2)
	if state2.Score != 15 {
		t.Errorf("IP2 Score = %d, want 15", state2.Score)
	}
}

func TestScorer_DecayScores(t *testing.T) {
	s := NewScorerDefault()

	ip := netip.MustParseAddr("10.0.0.10")

	// Set score to 30
	s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHTooManyFailures, ScoreDelta: 30, Service: "ssh"})

	state, _ := s.GetIPState(ip)
	if state.Score != 30 {
		t.Errorf("Initial Score = %d, want 30", state.Score)
	}

	// Decay scores (default decay = 5)
	s.DecayScores()

	state, _ = s.GetIPState(ip)
	if state.Score != 25 {
		t.Errorf("After decay Score = %d, want 25", state.Score)
	}

	// Decay multiple times until 0
	for i := 0; i < 10; i++ {
		s.DecayScores()
	}

	state, _ = s.GetIPState(ip)
	if state.Score != 0 {
		t.Errorf("Score should be 0, got %d", state.Score)
	}
}

func TestScorer_ReasonCounting(t *testing.T) {
	s := NewScorerDefault()

	ip := netip.MustParseAddr("10.0.0.20")

	// Record different reasons
	s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHFailedPassword, ScoreDelta: 10, Service: "ssh"})
	s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHFailedPassword, ScoreDelta: 10, Service: "ssh"})
	s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHInvalidUser, ScoreDelta: 15, Service: "ssh"})

	stats := s.GetStats()

	if stats.DetectionsByReason["ssh_failed_password"] != 2 {
		t.Errorf("DetectionsByReason[ssh_failed_password] = %d, want 2", stats.DetectionsByReason["ssh_failed_password"])
	}

	if stats.DetectionsByReason["ssh_invalid_user"] != 1 {
		t.Errorf("DetectionsByReason[ssh_invalid_user] = %d, want 1", stats.DetectionsByReason["ssh_invalid_user"])
	}
}

func TestScorer_IPv4IPv6Counting(t *testing.T) {
	s := NewScorerDefault()

	ipv4_1 := netip.MustParseAddr("192.168.1.1")
	ipv4_2 := netip.MustParseAddr("10.0.0.1")
	ipv6_1 := netip.MustParseAddr("2001:db8::1")
	ipv6_2 := netip.MustParseAddr("2001:db8::2")

	// Record some IPv4 detections
	s.RecordVerdict(Verdict{IP: ipv4_1, Reason: ReasonSSHFailedPassword, ScoreDelta: 10, Service: "ssh"})
	s.RecordVerdict(Verdict{IP: ipv4_1, Reason: ReasonSSHFailedPassword, ScoreDelta: 10, Service: "ssh"})
	s.RecordVerdict(Verdict{IP: ipv4_2, Reason: ReasonSSHInvalidUser, ScoreDelta: 15, Service: "ssh"})

	// Record some IPv6 detections
	s.RecordVerdict(Verdict{IP: ipv6_1, Reason: ReasonSSHFailedPassword, ScoreDelta: 10, Service: "ssh"})
	s.RecordVerdict(Verdict{IP: ipv6_2, Reason: ReasonSSHRootAttempt, ScoreDelta: 20, Service: "ssh"})

	stats := s.GetStats()

	// Total checks
	if stats.TotalDetections != 5 {
		t.Errorf("TotalDetections = %d, want 5", stats.TotalDetections)
	}

	// IPv4 checks
	if stats.DetectionsIPv4 != 3 {
		t.Errorf("DetectionsIPv4 = %d, want 3", stats.DetectionsIPv4)
	}
	if stats.UniqueIPv4 != 2 {
		t.Errorf("UniqueIPv4 = %d, want 2", stats.UniqueIPv4)
	}

	// IPv6 checks
	if stats.DetectionsIPv6 != 2 {
		t.Errorf("DetectionsIPv6 = %d, want 2", stats.DetectionsIPv6)
	}
	if stats.UniqueIPv6 != 2 {
		t.Errorf("UniqueIPv6 = %d, want 2", stats.UniqueIPv6)
	}

	// Total unique
	if stats.UniqueIPs != 4 {
		t.Errorf("UniqueIPs = %d, want 4", stats.UniqueIPs)
	}
}

func TestScorer_BanCountingIPv4IPv6(t *testing.T) {
	config := DefaultScorerConfig()
	config.ThresholdTempBan = 20 // Lower threshold
	s := NewScorer(config)

	ipv4 := netip.MustParseAddr("192.168.1.100")
	ipv6 := netip.MustParseAddr("2001:db8::100")

	// IPv4 ban
	s.RecordVerdict(Verdict{IP: ipv4, Reason: ReasonSSHFailedPassword, ScoreDelta: 25, Service: "ssh"})

	// IPv6 ban
	s.RecordVerdict(Verdict{IP: ipv6, Reason: ReasonSSHInvalidUser, ScoreDelta: 25, Service: "ssh"})

	stats := s.GetStats()

	if stats.TotalBans != 2 {
		t.Errorf("TotalBans = %d, want 2", stats.TotalBans)
	}

	if stats.BansIPv4 != 1 {
		t.Errorf("BansIPv4 = %d, want 1", stats.BansIPv4)
	}

	if stats.BansIPv6 != 1 {
		t.Errorf("BansIPv6 = %d, want 1", stats.BansIPv6)
	}

	// Check ban by service
	if stats.BansByService["ssh"] != 2 {
		t.Errorf("BansByService[ssh] = %d, want 2", stats.BansByService["ssh"])
	}

	// Check ban by reason
	if stats.BansByReason["ssh_failed_password"] != 1 {
		t.Errorf("BansByReason[ssh_failed_password] = %d, want 1", stats.BansByReason["ssh_failed_password"])
	}
	if stats.BansByReason["ssh_invalid_user"] != 1 {
		t.Errorf("BansByReason[ssh_invalid_user] = %d, want 1", stats.BansByReason["ssh_invalid_user"])
	}
}

func TestScorer_BanEscalationLadder(t *testing.T) {
	config := DefaultScorerConfig()
	config.ThresholdTempBan = 10   // Lower threshold for testing
	config.ThresholdEscalate = 20
	config.ThresholdPermanent = 50
	config.RecentBanWindow = 0     // Disable deduplication for rapid test bans

	s := NewScorer(config)

	ip := netip.MustParseAddr("10.0.0.30")

	// First ban (temp) - score 15 > threshold 10, BanCount=1
	action := s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHFailedPassword, ScoreDelta: 15, Service: "ssh"})
	if action.Duration != 15*time.Minute {
		t.Errorf("First ban duration = %v, want 15m", action.Duration)
	}

	// Second ban (escalation) - score 25 > threshold 20, BanCount=2, durIdx=1 -> 4h
	action = s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHInvalidUser, ScoreDelta: 10, Service: "ssh"})
	if action.Duration != 4*time.Hour {
		t.Errorf("Second ban duration = %v, want 4h (escalation level 2)", action.Duration)
	}

	// Third ban (escalation) - score 30 > threshold 20, BanCount=3, durIdx=2 -> 12h
	action = s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHPreauth, ScoreDelta: 5, Service: "ssh"})
	if action.Duration != 12*time.Hour {
		t.Errorf("Third ban duration = %v, want 12h (escalation level 3)", action.Duration)
	}

	state, _ := s.GetIPState(ip)
	if state.BanCount != 3 {
		t.Errorf("BanCount = %d, want 3", state.BanCount)
	}
}

func BenchmarkScorer_RecordVerdict(b *testing.B) {
	s := NewScorerDefault()

	verdicts := []Verdict{
		{IP: netip.MustParseAddr("192.168.1.1"), Reason: ReasonSSHFailedPassword, ScoreDelta: 10, Service: "ssh"},
		{IP: netip.MustParseAddr("192.168.1.2"), Reason: ReasonSSHInvalidUser, ScoreDelta: 15, Service: "ssh"},
		{IP: netip.MustParseAddr("192.168.1.3"), Reason: ReasonDovecotAuthFail, ScoreDelta: 15, Service: "dovecot"},
		{IP: netip.MustParseAddr("192.168.1.4"), Reason: ReasonFTPAuthFail, ScoreDelta: 15, Service: "ftp"},
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		s.RecordVerdict(verdicts[i%len(verdicts)])
	}
}

func BenchmarkScorer_GetStats(b *testing.B) {
	s := NewScorerDefault()

	// Pre-populate with data
	for i := 0; i < 1000; i++ {
		ip := netip.AddrFrom4([4]byte{192, 168, byte(i / 256), byte(i % 256)})
		s.RecordVerdict(Verdict{IP: ip, Reason: ReasonSSHFailedPassword, ScoreDelta: 10, Service: "ssh"})
	}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		s.GetStats()
	}
}
