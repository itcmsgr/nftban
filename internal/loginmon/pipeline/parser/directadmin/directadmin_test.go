// =============================================================================
// NFTBan v1.80 - DirectAdmin parser tests (Phase B)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: directadmin
// Purpose: Unit tests + fixture replay for the DirectAdmin login.log parser.
//
// meta:name="loginmon_pipeline_parser_directadmin_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="directadmin"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Phase B: DirectAdmin parser tests against real srv3 fixtures"
//
// meta:inventory.files="directadmin_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="../../testdata/directadmin/srv3_login.log"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package directadmin

import (
	"bufio"
	"net/netip"
	"os"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/event"
)

// fixtureDir is the path to real DA log fixtures captured from production.
const fixtureDir = "../../testdata/directadmin"

func mkLine(raw string) event.RawLine {
	return event.RawLine{
		Source:     "directadmin",
		Path:       "/var/log/directadmin/login.log",
		Line:       []byte(raw),
		ReceivedAt: time.Now(),
	}
}

// =============================================================================
// Unit tests — individual line parsing
// =============================================================================

func TestParse_FailedLogin(t *testing.T) {
	p := New()
	line := mkLine("2026:04:04-12:21:12: '192.0.2.122' 1 failed login attempts. Account 'admin'")
	r := p.Parse(line)

	if r.Outcome != event.ParseMatched {
		t.Fatalf("Outcome: got %v, want ParseMatched", r.Outcome)
	}
	if r.Event.SrcIP != netip.MustParseAddr("192.0.2.122") {
		t.Errorf("SrcIP: got %v", r.Event.SrcIP)
	}
	if r.Event.Username != "admin" {
		t.Errorf("Username: got %q", r.Event.Username)
	}
	if r.Event.Reason != event.ReasonDirectAdminFail {
		t.Errorf("Reason: got %v", r.Event.Reason)
	}
	if r.Event.Source != "directadmin" {
		t.Errorf("Source: got %q", r.Event.Source)
	}
	if r.Event.Protocol != "panel" {
		t.Errorf("Protocol: got %q", r.Event.Protocol)
	}
}

func TestParse_Timestamp(t *testing.T) {
	p := New()
	line := mkLine("2026:04:04-12:21:12: '1.2.3.4' 1 failed login attempts. Account 'x'")
	r := p.Parse(line)
	if r.Outcome != event.ParseMatched {
		t.Fatalf("Outcome: %v", r.Outcome)
	}
	want := time.Date(2026, 4, 4, 12, 21, 12, 0, time.UTC)
	if !r.Event.Timestamp.Equal(want) {
		t.Errorf("Timestamp: got %v, want %v", r.Event.Timestamp, want)
	}
}

func TestParse_SuccessfulLogin_Skipped(t *testing.T) {
	p := New()
	line := mkLine("2026:04:04-12:21:21: '192.0.2.122' successful login to 'reseller_admin'")
	r := p.Parse(line)
	if r.Outcome != event.ParseSkipped {
		t.Errorf("successful login: got %v, want ParseSkipped", r.Outcome)
	}
}

func TestParse_SuccessfulLoginVia_Skipped(t *testing.T) {
	p := New()
	line := mkLine("2026:04:05-08:34:51: '192.0.2.122' successful login to 'customer_account' via 'reseller_admin'")
	r := p.Parse(line)
	if r.Outcome != event.ParseSkipped {
		t.Errorf("successful login via: got %v, want ParseSkipped", r.Outcome)
	}
}

func TestParse_EmptyLine_Skipped(t *testing.T) {
	p := New()
	r := p.Parse(mkLine(""))
	if r.Outcome != event.ParseSkipped {
		t.Errorf("empty line: got %v, want ParseSkipped", r.Outcome)
	}
}

func TestParse_NoQuotes_Malformed(t *testing.T) {
	p := New()
	line := mkLine("2026:04:04-12:21:12: some garbage with failed login but no quotes")
	r := p.Parse(line)
	if r.Outcome != event.ParseMalformed {
		t.Errorf("no quotes: got %v, want ParseMalformed", r.Outcome)
	}
}

func TestParse_InvalidIP_Malformed(t *testing.T) {
	p := New()
	line := mkLine("2026:04:04-12:21:12: 'not-an-ip' 1 failed login attempts. Account 'x'")
	r := p.Parse(line)
	if r.Outcome != event.ParseMalformed {
		t.Errorf("invalid IP: got %v, want ParseMalformed", r.Outcome)
	}
}

func TestParse_NoAccount_StillMatches(t *testing.T) {
	// Some older DA formats may not include "Account 'xxx'"
	p := New()
	line := mkLine("2026:04:04-12:21:12: '1.2.3.4' 3 failed login attempts.")
	r := p.Parse(line)
	if r.Outcome != event.ParseMatched {
		t.Fatalf("no account: got %v, want ParseMatched", r.Outcome)
	}
	if r.Event.Username != "" {
		t.Errorf("Username: got %q, want empty", r.Event.Username)
	}
	if r.Event.SrcIP != netip.MustParseAddr("1.2.3.4") {
		t.Errorf("SrcIP: got %v", r.Event.SrcIP)
	}
}

func TestParse_MultipleAttempts(t *testing.T) {
	// "3 failed login attempts" should still be one event.
	p := New()
	line := mkLine("2026:04:06-15:38:39: '192.0.2.122' 3 failed login attempts. Account 'admin'")
	r := p.Parse(line)
	if r.Outcome != event.ParseMatched {
		t.Fatalf("multiple attempts: got %v", r.Outcome)
	}
	if r.Event.SrcIP.String() != "192.0.2.122" {
		t.Errorf("SrcIP: %v", r.Event.SrcIP)
	}
}

func TestParse_IPv6(t *testing.T) {
	p := New()
	line := mkLine("2026:04:04-12:21:12: '2001:db8::1' 1 failed login attempts. Account 'root'")
	r := p.Parse(line)
	if r.Outcome != event.ParseMatched {
		t.Fatalf("IPv6: got %v", r.Outcome)
	}
	if r.Event.SrcIP.String() != "2001:db8::1" {
		t.Errorf("SrcIP: got %v", r.Event.SrcIP)
	}
}

func TestName(t *testing.T) {
	p := New()
	if p.Name() != "directadmin" {
		t.Errorf("Name: got %q", p.Name())
	}
}

// =============================================================================
// Fixture replay — real srv3 login.log
// =============================================================================

func TestFixture_Srv3LoginLog(t *testing.T) {
	path := fixtureDir + "/srv3_login.log"
	f, err := os.Open(path)
	if err != nil {
		t.Skipf("fixture not available: %v", err)
	}
	defer f.Close()

	p := New()
	scanner := bufio.NewScanner(f)

	var totalLines, matched, skipped, malformed int
	for scanner.Scan() {
		totalLines++
		line := mkLine(scanner.Text())
		r := p.Parse(line)
		switch r.Outcome {
		case event.ParseMatched:
			matched++
			// All matched events in the fixture must have:
			if r.Event.Source != "directadmin" {
				t.Errorf("line %d: Source=%q", totalLines, r.Event.Source)
			}
			if r.Event.Reason != event.ReasonDirectAdminFail {
				t.Errorf("line %d: Reason=%v", totalLines, r.Event.Reason)
			}
			if !r.Event.SrcIP.IsValid() {
				t.Errorf("line %d: SrcIP invalid", totalLines)
			}
			if r.Event.Timestamp.IsZero() {
				t.Errorf("line %d: Timestamp zero", totalLines)
			}
		case event.ParseSkipped:
			skipped++
		case event.ParseMalformed:
			malformed++
			t.Errorf("line %d: unexpected malformed: %s", totalLines, r.Reason)
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatalf("scan: %v", err)
	}

	t.Logf("srv3_login.log: %d total, %d matched, %d skipped, %d malformed",
		totalLines, matched, skipped, malformed)

	// From the fixture: 30 lines total. 10 are "failed login", 20 are
	// "successful login". Zero should be malformed.
	if totalLines != 30 {
		t.Errorf("totalLines: got %d, want 30", totalLines)
	}
	if matched != 10 {
		t.Errorf("matched: got %d, want 10 (10 failed login lines in fixture)", matched)
	}
	if skipped != 20 {
		t.Errorf("skipped: got %d, want 20 (20 successful login lines)", skipped)
	}
	if malformed != 0 {
		t.Errorf("malformed: got %d, want 0", malformed)
	}
}

// TestFixture_Srv3_Parity asserts that the Go parser extracts the same
// (IP, User) pairs as the legacy parser would. This is the parity gate:
// if this test fails, the Go parser is not ready for dual-run.
func TestFixture_Srv3_Parity(t *testing.T) {
	path := fixtureDir + "/srv3_login.log"
	f, err := os.Open(path)
	if err != nil {
		t.Skipf("fixture not available: %v", err)
	}
	defer f.Close()

	p := New()
	scanner := bufio.NewScanner(f)

	// Expected: every failed-login line in the fixture has IP 192.0.2.122
	// and account "admin" (same attacker, same target on srv3).
	expectedIP := netip.MustParseAddr("192.0.2.122")
	expectedUser := "admin"

	lineNo := 0
	for scanner.Scan() {
		lineNo++
		r := p.Parse(mkLine(scanner.Text()))
		if r.Outcome != event.ParseMatched {
			continue
		}
		if r.Event.SrcIP != expectedIP {
			t.Errorf("line %d parity: SrcIP=%v, want %v", lineNo, r.Event.SrcIP, expectedIP)
		}
		if r.Event.Username != expectedUser {
			t.Errorf("line %d parity: Username=%q, want %q", lineNo, r.Event.Username, expectedUser)
		}
	}
}
