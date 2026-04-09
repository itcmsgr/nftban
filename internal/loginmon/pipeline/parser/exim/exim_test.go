// =============================================================================
// NFTBan v1.80 - Exim parser tests (Phase C)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: exim
// Purpose: Unit tests + fixture replay for the Exim mainlog parser.
//
// meta:name="loginmon_pipeline_parser_exim_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="exim"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Phase C: Exim parser tests against real srv2/srv3 fixtures"
//
// meta:inventory.files="exim_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="../../testdata/exim/*.log"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package exim

import (
	"bufio"
	"net/netip"
	"os"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/event"
)

const fixtureDir = "../../testdata/exim"

func mkLine(raw string) event.RawLine {
	return event.RawLine{
		Source:     "exim",
		Path:       "/var/log/exim/mainlog",
		Line:       []byte(raw),
		ReceivedAt: time.Now(),
	}
}

// =============================================================================
// Unit tests
// =============================================================================

func TestParse_AuthFailure(t *testing.T) {
	p := New()
	line := mkLine(`2026-04-09 04:28:42 login authenticator failed for H=([92.118.39.211]) [92.118.39.211]: 535 Incorrect authentication data (set_id=admin@customer-b.example.test)`)
	r := p.Parse(line)

	if r.Outcome != event.ParseMatched {
		t.Fatalf("Outcome: got %v, want ParseMatched", r.Outcome)
	}
	if r.Event.SrcIP != netip.MustParseAddr("92.118.39.211") {
		t.Errorf("SrcIP: got %v", r.Event.SrcIP)
	}
	if r.Event.Username != "admin@customer-b.example.test" {
		t.Errorf("Username: got %q", r.Event.Username)
	}
	if r.Event.Reason != event.ReasonEximAuthFail {
		t.Errorf("Reason: got %v", r.Event.Reason)
	}
	if r.Event.Source != "exim" {
		t.Errorf("Source: got %q", r.Event.Source)
	}
	if r.Event.Protocol != "smtp" {
		t.Errorf("Protocol: got %q", r.Event.Protocol)
	}
}

func TestParse_Timestamp(t *testing.T) {
	p := New()
	line := mkLine(`2026-04-09 04:28:42 login authenticator failed for [1.2.3.4]:25`)
	r := p.Parse(line)
	if r.Outcome != event.ParseMatched {
		t.Fatalf("Outcome: %v", r.Outcome)
	}
	want := time.Date(2026, 4, 9, 4, 28, 42, 0, time.UTC)
	if !r.Event.Timestamp.Equal(want) {
		t.Errorf("Timestamp: got %v, want %v", r.Event.Timestamp, want)
	}
}

func TestParse_NoSetID(t *testing.T) {
	p := New()
	line := mkLine(`2026-04-09 04:28:42 login authenticator failed for [10.0.0.1]:25`)
	r := p.Parse(line)
	if r.Outcome != event.ParseMatched {
		t.Fatalf("Outcome: %v", r.Outcome)
	}
	if r.Event.Username != "" {
		t.Errorf("Username: got %q, want empty", r.Event.Username)
	}
}

func TestParse_NormalLine_Skipped(t *testing.T) {
	p := New()
	lines := []string{
		"2026-04-09 04:28:42 Message accepted",
		"2026-04-09 04:28:42 Completed",
		"",
		"random log line without exim signals",
	}
	for _, l := range lines {
		r := p.Parse(mkLine(l))
		if r.Outcome != event.ParseSkipped {
			t.Errorf("line %q: got %v, want ParseSkipped", l, r.Outcome)
		}
	}
}

func TestParse_AuthenticatorWithoutBracketIP_Malformed(t *testing.T) {
	p := New()
	line := mkLine(`2026-04-09 04:28:42 login authenticator failed for some_host without brackets`)
	r := p.Parse(line)
	if r.Outcome != event.ParseMalformed {
		t.Errorf("got %v, want ParseMalformed", r.Outcome)
	}
}

func TestParse_MultipleBracketIPs_FirstWins(t *testing.T) {
	// Exim puts [attacker]:port first, then H=([claimed]) [attacker] I=[local]:port
	p := New()
	line := mkLine(`2026-04-09 04:28:42 login authenticator failed for [5.6.7.8]:25 H=([5.6.7.8]) [5.6.7.8] I=[10.0.0.1]:25`)
	r := p.Parse(line)
	if r.Outcome != event.ParseMatched {
		t.Fatalf("Outcome: %v", r.Outcome)
	}
	// First bracket IP should be the attacker
	if r.Event.SrcIP != netip.MustParseAddr("5.6.7.8") {
		t.Errorf("SrcIP: got %v, want 5.6.7.8", r.Event.SrcIP)
	}
}

func TestParse_IPv6(t *testing.T) {
	p := New()
	line := mkLine(`2026-04-09 04:28:42 login authenticator failed for [2001:db8::1]:587`)
	r := p.Parse(line)
	if r.Outcome != event.ParseMatched {
		t.Fatalf("Outcome: %v", r.Outcome)
	}
	if r.Event.SrcIP.String() != "2001:db8::1" {
		t.Errorf("SrcIP: got %v", r.Event.SrcIP)
	}
}

func TestName(t *testing.T) {
	if New().Name() != "exim" {
		t.Errorf("Name: got %q", New().Name())
	}
}

// =============================================================================
// Fixture replay — real srv2 + srv3 exim mainlog
// =============================================================================

func testFixture(t *testing.T, path string, minMatched int) {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Skipf("fixture not available: %v", err)
	}
	defer f.Close()

	p := New()
	scanner := bufio.NewScanner(f)

	var total, matched, skipped, malformed int
	for scanner.Scan() {
		total++
		r := p.Parse(mkLine(scanner.Text()))
		switch r.Outcome {
		case event.ParseMatched:
			matched++
			if r.Event.Source != "exim" {
				t.Errorf("line %d: Source=%q", total, r.Event.Source)
			}
			if r.Event.Reason != event.ReasonEximAuthFail {
				t.Errorf("line %d: Reason=%v", total, r.Event.Reason)
			}
			if !r.Event.SrcIP.IsValid() {
				t.Errorf("line %d: SrcIP invalid", total)
			}
			if r.Event.Timestamp.IsZero() {
				t.Errorf("line %d: Timestamp zero", total)
			}
		case event.ParseSkipped:
			skipped++
		case event.ParseMalformed:
			malformed++
			t.Errorf("line %d: unexpected malformed: %s", total, r.Reason)
		}
	}

	t.Logf("%s: %d total, %d matched, %d skipped, %d malformed", path, total, matched, skipped, malformed)

	if matched < minMatched {
		t.Errorf("matched: got %d, want >= %d", matched, minMatched)
	}
	if malformed != 0 {
		t.Errorf("malformed: got %d, want 0", malformed)
	}
}

func TestFixture_Srv2(t *testing.T) {
	// srv2 fixture: 30 lines, all "authenticator failed" — all should match
	testFixture(t, fixtureDir+"/srv2_auth_failures.log", 30)
}

func TestFixture_Srv3(t *testing.T) {
	// srv3 fixture: 30 lines, all "authenticator failed"
	testFixture(t, fixtureDir+"/srv3_auth_failures.log", 30)
}

// TestFixture_Srv2_StealthworkerCluster asserts the well-known 92.118.39.x
// attacker cluster appears in the srv2 fixture (reality check).
func TestFixture_Srv2_StealthworkerCluster(t *testing.T) {
	f, err := os.Open(fixtureDir + "/srv2_auth_failures.log")
	if err != nil {
		t.Skipf("fixture not available: %v", err)
	}
	defer f.Close()

	p := New()
	scanner := bufio.NewScanner(f)
	stealthworkerCount := 0
	for scanner.Scan() {
		r := p.Parse(mkLine(scanner.Text()))
		if r.Outcome == event.ParseMatched {
			ip := r.Event.SrcIP.String()
			if len(ip) > 10 && ip[:10] == "92.118.39." {
				stealthworkerCount++
			}
		}
	}
	if stealthworkerCount == 0 {
		t.Error("expected at least one 92.118.39.x IP in srv2 fixture (Stealthworker cluster)")
	}
	t.Logf("92.118.39.x count: %d", stealthworkerCount)
}
