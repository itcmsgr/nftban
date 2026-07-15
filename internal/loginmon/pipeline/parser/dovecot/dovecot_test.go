// =============================================================================
// NFTBan v1.80 - Dovecot parser tests (Phase D)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: dovecot
// Purpose: Unit tests + fixture replay for the Dovecot auth-failure parser.
//
// meta:name="loginmon_pipeline_parser_dovecot_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="dovecot"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Phase D: Dovecot parser tests against sanitized sample fixtures"
//
// meta:inventory.files="dovecot_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="../../testdata/dovecot/*.log"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package dovecot

import (
	"bufio"
	"net/netip"
	"os"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/event"
)

const fixtureDir = "../../testdata/dovecot"

func mkLine(raw string) event.RawLine {
	return event.RawLine{
		Source:     "dovecot",
		Path:       "/var/log/maillog",
		Line:       []byte(raw),
		ReceivedAt: time.Now(),
	}
}

// =============================================================================
// Unit tests
// =============================================================================

func TestParse_ImapAuthFailed(t *testing.T) {
	p := New()
	line := mkLine(`Apr  9 03:01:45 mail01 dovecot[1234]: imap-login: Login aborted: Connection closed (auth failed, 1 attempts in 3 secs) (auth_failed): user=<contact@example.test>, method=PLAIN, rip=203.0.113.178, lip=192.0.2.97, TLS, session=<synthetic-session>`)
	r := p.Parse(line)

	if r.Outcome != event.ParseMatched {
		t.Fatalf("Outcome: got %v, want ParseMatched", r.Outcome)
	}
	if r.Event.SrcIP != netip.MustParseAddr("203.0.113.178") {
		t.Errorf("SrcIP: got %v", r.Event.SrcIP)
	}
	if r.Event.DstIP != netip.MustParseAddr("192.0.2.97") {
		t.Errorf("DstIP: got %v", r.Event.DstIP)
	}
	if r.Event.Username != "contact@example.test" {
		t.Errorf("Username: got %q", r.Event.Username)
	}
	if r.Event.Reason != event.ReasonDovecotAuthFail {
		t.Errorf("Reason: got %v", r.Event.Reason)
	}
	if r.Event.Protocol != "imap" {
		t.Errorf("Protocol: got %q", r.Event.Protocol)
	}
	if r.Event.Source != "dovecot" {
		t.Errorf("Source: got %q", r.Event.Source)
	}
}

func TestParse_Pop3Login(t *testing.T) {
	p := New()
	line := mkLine(`Apr  9 03:01:45 mail01 dovecot[123]: pop3-login: Login aborted: (auth failed): user=<x@y>, rip=1.2.3.4, lip=5.6.7.8`)
	r := p.Parse(line)
	if r.Outcome != event.ParseMatched {
		t.Fatalf("Outcome: %v", r.Outcome)
	}
	if r.Event.Protocol != "pop3" {
		t.Errorf("Protocol: got %q, want pop3", r.Event.Protocol)
	}
}

func TestParse_SubmissionLogin(t *testing.T) {
	p := New()
	line := mkLine(`Apr  9 03:01:45 mail01 dovecot[123]: submission-login: Login aborted: (auth failed): user=<x@y>, rip=1.2.3.4, lip=5.6.7.8`)
	r := p.Parse(line)
	if r.Outcome != event.ParseMatched {
		t.Fatalf("Outcome: %v", r.Outcome)
	}
	if r.Event.Protocol != "smtp" {
		t.Errorf("Protocol: got %q, want smtp", r.Event.Protocol)
	}
}

func TestParse_NoAuthFailed_Skipped(t *testing.T) {
	p := New()
	lines := []string{
		"Apr  9 03:01:45 mail01 dovecot[123]: imap-login: Login: user=<ok@ok>, rip=1.2.3.4",
		"Apr  9 03:01:45 mail01 postfix/smtpd[456]: connect from unknown",
		"",
		"random noise",
	}
	for _, l := range lines {
		r := p.Parse(mkLine(l))
		if r.Outcome != event.ParseSkipped {
			t.Errorf("line %q: got %v, want ParseSkipped", l, r.Outcome)
		}
	}
}

func TestParse_AuthFailedNoRip_Malformed(t *testing.T) {
	p := New()
	line := mkLine(`Apr  9 03:01:45 mail01 dovecot[123]: imap-login: (auth failed): user=<x@y>, no rip here`)
	r := p.Parse(line)
	if r.Outcome != event.ParseMalformed {
		t.Errorf("got %v, want ParseMalformed", r.Outcome)
	}
}

func TestParse_NoUser(t *testing.T) {
	p := New()
	line := mkLine(`Apr  9 03:01:45 mail01 dovecot[123]: imap-login: (auth failed): rip=1.2.3.4, lip=5.6.7.8`)
	r := p.Parse(line)
	if r.Outcome != event.ParseMatched {
		t.Fatalf("Outcome: %v", r.Outcome)
	}
	if r.Event.Username != "" {
		t.Errorf("Username: got %q, want empty", r.Event.Username)
	}
}

func TestParse_IPv6(t *testing.T) {
	p := New()
	line := mkLine(`Apr  9 03:01:45 mail01 dovecot[123]: imap-login: (auth failed): user=<x@y>, rip=2001:db8::1, lip=::1`)
	r := p.Parse(line)
	if r.Outcome != event.ParseMatched {
		t.Fatalf("Outcome: %v", r.Outcome)
	}
	if r.Event.SrcIP.String() != "2001:db8::1" {
		t.Errorf("SrcIP: got %v", r.Event.SrcIP)
	}
}

func TestName(t *testing.T) {
	if New().Name() != "dovecot" {
		t.Errorf("Name: got %q", New().Name())
	}
}

// =============================================================================
// Fixture replay
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
			if !r.Event.SrcIP.IsValid() {
				t.Errorf("line %d: SrcIP invalid", total)
			}
			if r.Event.Username == "" {
				t.Errorf("line %d: Username empty (dovecot fixtures should have user=<>)", total)
			}
		case event.ParseSkipped:
			skipped++
		case event.ParseMalformed:
			malformed++
			t.Errorf("line %d: malformed: %s", total, r.Reason)
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

func TestFixture_SampleA(t *testing.T) {
	testFixture(t, fixtureDir+"/auth_failures_a.log", 30)
}

func TestFixture_SampleB(t *testing.T) {
	testFixture(t, fixtureDir+"/auth_failures_b.log", 30)
}

func TestFixture_SampleA_ExtractsRealUsernames(t *testing.T) {
	f, err := os.Open(fixtureDir + "/auth_failures_a.log")
	if err != nil {
		t.Skipf("fixture: %v", err)
	}
	defer f.Close()

	p := New()
	scanner := bufio.NewScanner(f)
	users := map[string]int{}
	for scanner.Scan() {
		r := p.Parse(mkLine(scanner.Text()))
		if r.Outcome == event.ParseMatched && r.Event.Username != "" {
			users[r.Event.Username]++
		}
	}
	t.Logf("unique users in sample-A fixture: %d", len(users))
	if len(users) == 0 {
		t.Error("expected at least one user extracted from sample-A fixture")
	}
	// Fixture should contain real customer mailboxes from the BUG-1 audit
	for u, c := range users {
		t.Logf("  %s: %d events", u, c)
	}
}
