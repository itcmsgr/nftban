// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package detector

// v1.238 (owner 2026-11-21, srv4 incident): a WordPress admin was banned 15m after three
// "lost password" requests, then 4h after one typo following a successful login.
//   - wp-login: only CREDENTIAL posts score; a credential POST answered 302 is a success.
//   - Success verdicts (WP 302, SSH Accepted, DirectAdmin successful login, Roundcube
//     Successful login, dovecot Login:) clear the IP's score, bounded, never lifting a ban.
//   - Success is recognised only at the message start, so a client-chosen username cannot
//     forge one.
// In-memory unit tests: reserved documentation IPs (192.0.2.0/24, 203.0.113.0/24,
// 2001:db8::/32), no traffic, no firewall change.

import (
	"bufio"
	"net/netip"
	"os"
	"strings"
	"testing"
)

func mustAddr(t *testing.T, s string) netip.Addr {
	t.Helper()
	a, err := netip.ParseAddr(s)
	if err != nil {
		t.Fatal(err)
	}
	return a
}

func wpLine(ip, target string, status int) string {
	return ip + ` - - [21/Nov/2026:09:43:44 +0200] "POST ` + target + ` HTTP/1.1" ` +
		map[int]string{200: "200", 302: "302"}[status] + ` 4512 "https://example.gr/wp-login.php" "Mozilla/5.0"`
}

func TestWPLoginOnlyCredentialPostsCount(t *testing.T) {
	d := NewWebAuthDetector()
	nonCredential := []string{
		"/wp-login.php?action=lostpassword", "/wp-login.php?action=retrievepassword",
		"/wp-login.php?action=rp&key=abc&login=x", "/wp-login.php?action=resetpass",
		"/wp-login.php?action=register", "/wp-login.php?action=postpass",
		"/wp-login.php?action=logout", "/wp-login.php?action=confirm_admin_email",
		"/wp-login.php?%61ction=lostpassword",    // PHP decodes the key
		"/blog/wp-login.php?action=lostpassword", // site in a subdirectory
	}
	for _, target := range nonCredential {
		for _, st := range []int{200, 302} {
			if v, ok := d.Detect([]byte(wpLine("203.0.113.7", target, st))); ok {
				t.Errorf("%s %d is not a credential attempt, got %+v", target, st, v)
			}
		}
	}
	credential := []string{
		"/wp-login.php", "/wp-login.php?action=login", "/wp-login.php?interim-login=1",
		"/wp-login.php?redirect_to=%2Fwp-admin%2F", "/blog/wp-login.php",
		// WordPress handles an unknown action in its login branch: still a credential attempt,
		// so ?action=x can't be used to brute-force without scoring.
		"/wp-login.php?action=x", "/wp-login.php?action=lostpassword&action=login",
		"/wp-login.php?action=LostPassword", // case-sensitive in WordPress: the login branch
	}
	for _, target := range credential {
		v, ok := d.Detect([]byte(wpLine("203.0.113.7", target, 200)))
		if !ok || v.Success || v.ScoreDelta != scoreWPLoginFail {
			t.Errorf("%s 200 must score as a failed login: ok=%v %+v", target, ok, v)
		}
		v, ok = d.Detect([]byte(wpLine("203.0.113.7", target, 302)))
		if !ok || !v.Success || v.ScoreDelta != 0 {
			t.Errorf("%s 302 must be a success: ok=%v %+v", target, ok, v)
		}
	}
}

func replayScorer() *Scorer {
	cfg := DefaultScorerConfig()
	cfg.RecentBanWindow = 0 // replay in one instant: no duplicate-ban suppression
	return NewScorer(cfg)
}

// feed runs lines through the real registry and scorer as module.processLine does.
func feed(t *testing.T, r *Registry, s *Scorer, lines ...string) (bans []*BanAction) {
	t.Helper()
	for _, l := range lines {
		v, ok := r.Detect([]byte(l))
		if !ok {
			continue
		}
		if v.Success {
			s.RecordSuccess(v)
			continue
		}
		if b := s.RecordVerdict(v); b != nil {
			bans = append(bans, b)
		}
	}
	return bans
}

// The srv4 incident, replayed: 3x lost password, a successful login, 17 minutes of decay,
// one typo. Before v1.238: 15m ban, then a 4h escalation. Now: no ban at all.
func TestIncidentReplayNoBan(t *testing.T) {
	const ip = "192.0.2.200"
	r, s := NewRegistry(), replayScorer()
	lost := wpLine(ip, "/wp-login.php?action=lostpassword", 200)
	if b := feed(t, r, s, lost, lost, lost); len(b) != 0 {
		t.Fatalf("lost-password requests banned: %+v", b[0])
	}
	if b := feed(t, r, s, wpLine(ip, "/wp-login.php", 302)); len(b) != 0 {
		t.Fatal("a successful login banned")
	}
	for i := 0; i < 3; i++ {
		s.DecayScores()
	}
	if b := feed(t, r, s, wpLine(ip, "/wp-login.php", 200)); len(b) != 0 {
		t.Fatalf("one typo after a good login banned: %+v", b[0])
	}
}

// Kept: three credential failures in a minute still ban; and after a temp ban a success
// clears the score, so the next single typo does not escalate (it did: 45 + 20 = 65).
func TestCredentialFailuresStillBanAndSuccessStopsEscalation(t *testing.T) {
	const ip = "192.0.2.201"
	r, s := NewRegistry(), replayScorer()
	fail := wpLine(ip, "/wp-login.php", 200)
	bans := feed(t, r, s, fail, fail, fail)
	if len(bans) != 1 || bans[0].Duration != s.config.TempBanDuration {
		t.Fatalf("3 credential failures must temp-ban: %+v", bans)
	}
	for i := 0; i < 3; i++ {
		s.DecayScores()
	}
	// control: without the success the next typo escalates
	ctl := replayScorer()
	feed(t, r, ctl, fail, fail, fail)
	for i := 0; i < 3; i++ {
		ctl.DecayScores()
	}
	if b := feed(t, r, ctl, fail); len(b) != 1 || b[0].Duration <= ctl.config.TempBanDuration {
		t.Fatalf("control: expected an escalation without a success, got %+v", b)
	}
	if b := feed(t, r, s, wpLine(ip, "/wp-login.php", 302), fail); len(b) != 0 {
		t.Fatalf("after a successful login one typo escalated: %+v", b[0])
	}
}

func TestRecordSuccessBounds(t *testing.T) {
	s := replayScorer()
	r := NewRegistry()
	ok := wpLine("192.0.2.202", "/wp-login.php", 302)
	fail := wpLine("192.0.2.202", "/wp-login.php", 200)
	feed(t, r, s, ok)
	if _, tracked := s.GetIPState(mustAddr(t, "192.0.2.202")); tracked {
		t.Fatal("a success must not create state for an unseen IP")
	}
	feed(t, r, s, fail, fail)
	feed(t, r, s, ok)
	st, _ := s.GetIPState(mustAddr(t, "192.0.2.202"))
	if st.Score != 0 {
		t.Fatalf("first success must clear the score: %d", st.Score)
	}
	// a second clear within TempBanDuration is refused: a valid account cannot keep
	// wiping the score while guessing another account
	feed(t, r, s, fail, fail, ok)
	st, _ = s.GetIPState(mustAddr(t, "192.0.2.202"))
	if st.Score != 2*scoreWPLoginFail {
		t.Fatalf("second success inside the window must not clear: score %d", st.Score)
	}
	// a success never changes the ban history (ladder position)
	bans := feed(t, r, s, fail)
	before, _ := s.GetIPState(mustAddr(t, "192.0.2.202"))
	if len(bans) != 1 || before.BanCount != 1 {
		t.Fatalf("expected a ban: %+v", bans)
	}
	s.mu.Lock()
	s.ips[mustAddr(t, "192.0.2.202")].SuccessReset = s.ips[mustAddr(t, "192.0.2.202")].SuccessReset.Add(-2 * s.config.TempBanDuration)
	s.mu.Unlock()
	feed(t, r, s, ok)
	after, _ := s.GetIPState(mustAddr(t, "192.0.2.202"))
	if after.BanCount != before.BanCount || after.Score != 0 {
		t.Fatalf("success must clear the score and keep BanCount: %+v", after)
	}
}

// Contract: every known SUCCESS line is a Success verdict and never scores.
func TestSuccessLinesNeverScore(t *testing.T) {
	r := NewRegistry()
	lines := []string{
		"Apr  3 10:15:22 host sshd[1234]: Accepted publickey for admin from 203.0.113.10 port 22 ssh2: ED25519 SHA256:x",
		"2026-11-21T10:01:00+0200 host sshd-session[77]: Accepted password for root from 2001:db8::5 port 51022 ssh2",
		"2026-11-21T10:01:00+0200 host sshd[77]: Accepted keyboard-interactive/pam for admin from 203.0.113.11 port 5 ssh2",
		"Apr 03 14:22:01 host dovecot: imap-login: Login: user=<admin@example.gr>, method=PLAIN, rip=203.0.113.12, lip=192.0.2.1, mpid=1, TLS",
		"2026-11-21T10:01:00+0200 host dovecot[9]: pop3-login: Login: user=<u>, method=PLAIN, rip=203.0.113.13, lip=192.0.2.1",
		"[21-Nov-2026 10:01:00 +0200]: <s> Successful login for user@example.gr (ID: 1) from 203.0.113.14 in session deadbeef",
		wpLine("203.0.113.15", "/wp-login.php", 302),
	}
	// DirectAdmin's own sample: every "successful login" line
	f, err := os.Open("../pipeline/testdata/directadmin/login_sample.log")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	da := 0
	for sc.Scan() {
		if strings.Contains(sc.Text(), "successful login") {
			lines = append(lines, sc.Text())
			da++
		}
	}
	if da < 20 {
		t.Fatalf("expected the DA sample's success lines, found %d", da)
	}
	for _, l := range lines {
		v, ok := r.Detect([]byte(l))
		if !ok || !v.Success || v.ScoreDelta != 0 {
			t.Errorf("success line must be a Success verdict: ok=%v %+v\n  %s", ok, v, l)
		}
	}
}

// Forgery: a client-chosen username containing a success phrase never yields a Success,
// and the failure is still scored where it was before.
func TestSuccessCannotBeForgedThroughAUsername(t *testing.T) {
	r := NewRegistry()
	for _, l := range []string{
		"Apr  3 10:15:22 host sshd[1]: Failed password for invalid user Accepted from 203.0.113.20 port 22 ssh2",
		"Apr  3 10:15:22 host sshd[1]: Connection closed by invalid user x]: Accepted password for b from 203.0.113.21 port 1 [preauth]",
		"Apr 03 14:22:01 host dovecot: imap-login: Disconnected (auth failed, 1 attempts): user=<a-login: Login: user=<b>, rip=203.0.113.22>, method=PLAIN, rip=203.0.113.23",
		"2026:04:04-13:00:00: '203.0.113.24' 1 failed login attempts. Account '' successful login to 'x'",
	} {
		if v, ok := r.Detect([]byte(l)); ok && v.Success {
			t.Errorf("forged success: %+v\n  %s", v, l)
		}
	}
}

// Plesk: a success line must not score through the word "authentication".
func TestPleskAuthenticationSucceededDoesNotScore(t *testing.T) {
	d := NewPanelDetector()
	l := "[panel] Authentication succeeded for user 'admin' from 203.0.113.30"
	if v, ok := d.Detect([]byte(l)); ok && !v.Success {
		t.Fatalf("a Plesk success line scored: %+v", v)
	}
}
