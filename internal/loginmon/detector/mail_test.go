// =============================================================================
// NFTBan v1.0.30 - Mail Detector Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// meta:name="mail_detector_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-03"
// meta:description="Unit tests and benchmarks for Mail detector"
//
// Fixtures sourced from real production logs:
// - srv2 (AlmaLinux 9, DirectAdmin): Exim mainlog + /var/log/secure
// - lab4 (AlmaLinux 9, cPanel): /var/log/maillog + /var/log/secure
// - lab2 (Ubuntu 24.04, Plesk): /var/log/maillog + /var/log/auth.log
//
// meta:inventory.files="mail_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package detector

import (
	"testing"
)

// ---------------------------------------------------------------------------
// Dovecot native: "auth failed, rip=<ip>"
// ---------------------------------------------------------------------------

func TestMailDetector_DovecotNative(t *testing.T) {
	d := NewMailDetector()

	tests := []struct {
		name       string
		line       string
		wantIP     string
		wantReason uint16
		wantMatch  bool
	}{
		{
			name:       "dovecot auth failed IPv4",
			line:       "Apr 03 14:22:01 srv2 dovecot[1234]: imap-login: Disconnected: user=<admin>, method=PLAIN, rip=185.234.72.10, lip=10.0.0.1",
			wantIP:     "185.234.72.10",
			wantReason: ReasonDovecotAuthFail,
			wantMatch:  true,
		},
		{
			name:       "dovecot auth failed with auth failed signal",
			line:       "Apr 03 14:22:01 srv2 dovecot: auth failed, rip=203.0.113.42, lip=10.0.0.1",
			wantIP:     "203.0.113.42",
			wantReason: ReasonDovecotAuthFail,
			wantMatch:  true,
		},
		{
			name:       "dovecot auth failed IPv6",
			line:       "Apr 03 14:22:01 srv2 dovecot: auth failed, rip=2001:db8::dead:beef, lip=::1",
			wantIP:     "2001:db8::dead:beef",
			wantReason: ReasonDovecotAuthFail,
			wantMatch:  true,
		},
		{
			name:      "dovecot unrelated line",
			line:      "Apr 03 14:22:01 srv2 dovecot: master: Dovecot v2.3.21 starting up",
			wantMatch: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			v, ok := d.Detect([]byte(tt.line))
			if ok != tt.wantMatch {
				t.Errorf("Detect() match = %v, want %v", ok, tt.wantMatch)
				return
			}
			if !tt.wantMatch {
				return
			}
			if v.IP.String() != tt.wantIP {
				t.Errorf("Detect() IP = %v, want %v", v.IP.String(), tt.wantIP)
			}
			if v.Reason != tt.wantReason {
				t.Errorf("Detect() Reason = %v, want %v", v.Reason, tt.wantReason)
			}
			if v.Service != "dovecot" {
				t.Errorf("Detect() Service = %v, want dovecot", v.Service)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Dovecot PAM: "pam_unix(dovecot:auth): authentication failure ... rhost=<ip>"
// Source: /var/log/secure (EL9), /var/log/auth.log (Debian/Ubuntu)
// ---------------------------------------------------------------------------

func TestMailDetector_DovecotPam(t *testing.T) {
	d := NewMailDetector()

	tests := []struct {
		name       string
		line       string
		wantIP     string
		wantReason uint16
		wantUser   string
		wantMatch  bool
	}{
		{
			// Real format from lab4 /var/log/secure
			name:       "PAM dovecot auth failure with user",
			line:       "Apr  3 10:15:22 lab4 dovecot: pam_unix(dovecot:auth): authentication failure; logname= uid=0 euid=0 tty=dovecot ruser=admin rhost=185.234.72.10 user=admin",
			wantIP:     "185.234.72.10",
			wantReason: ReasonDovecotPamFail,
			wantUser:   "admin",
			wantMatch:  true,
		},
		{
			// PAM without user field
			name:       "PAM dovecot auth failure without user",
			line:       "Apr  3 10:15:22 srv2 dovecot: pam_unix(dovecot:auth): authentication failure; logname= uid=0 euid=0 tty=dovecot rhost=91.200.12.33",
			wantIP:     "91.200.12.33",
			wantReason: ReasonDovecotPamFail,
			wantUser:   "",
			wantMatch:  true,
		},
		{
			// IPv6 PAM
			name:       "PAM dovecot auth failure IPv6",
			line:       "Apr  3 10:15:22 lab2 dovecot: pam_unix(dovecot:auth): authentication failure; logname= uid=0 euid=0 tty=dovecot rhost=2a01:4f8:c17:abcd::1 user=test",
			wantIP:     "2a01:4f8:c17:abcd::1",
			wantReason: ReasonDovecotPamFail,
			wantUser:   "test",
			wantMatch:  true,
		},
		{
			// Not dovecot PAM — sshd PAM should NOT match
			name:      "PAM sshd should not match",
			line:      "Apr  3 10:15:22 srv2 sshd[1234]: pam_unix(sshd:auth): authentication failure; logname= uid=0 euid=0 tty=ssh rhost=10.0.0.1 user=root",
			wantMatch: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			v, ok := d.Detect([]byte(tt.line))
			if ok != tt.wantMatch {
				t.Errorf("Detect() match = %v, want %v", ok, tt.wantMatch)
				return
			}
			if !tt.wantMatch {
				return
			}
			if v.IP.String() != tt.wantIP {
				t.Errorf("Detect() IP = %v, want %v", v.IP.String(), tt.wantIP)
			}
			if v.Reason != tt.wantReason {
				t.Errorf("Detect() Reason = %v, want %v", v.Reason, tt.wantReason)
			}
			if v.User != tt.wantUser {
				t.Errorf("Detect() User = %v, want %v", v.User, tt.wantUser)
			}
			if v.Service != "dovecot" {
				t.Errorf("Detect() Service = %v, want dovecot", v.Service)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Postfix: "SASL LOGIN authentication failed.*[<ip>]"
// Source: /var/log/maillog (EL9/Ubuntu), /var/log/mail.log (Debian)
// ---------------------------------------------------------------------------

func TestMailDetector_Postfix(t *testing.T) {
	d := NewMailDetector()

	tests := []struct {
		name       string
		line       string
		wantIP     string
		wantReason uint16
		wantMatch  bool
	}{
		{
			name:       "postfix SASL LOGIN failure",
			line:       "Apr  3 12:00:01 lab2 postfix/smtpd[54321]: warning: unknown[185.234.72.10]: SASL LOGIN authentication failed: authentication failure",
			wantIP:     "185.234.72.10",
			wantReason: ReasonPostfixSASL,
			wantMatch:  true,
		},
		{
			name:       "postfix SASL PLAIN failure",
			line:       "Apr  3 12:00:01 lab2 postfix/smtpd[54321]: warning: unknown[93.184.216.34]: SASL PLAIN authentication failed: UGFzc3dvcmQ=",
			wantIP:     "93.184.216.34",
			wantReason: ReasonPostfixSASL,
			wantMatch:  true,
		},
		{
			name:       "postfix SASL with IPv6",
			line:       "Apr  3 12:00:01 lab2 postfix/smtpd[54321]: warning: unknown[2001:db8::1]: SASL LOGIN authentication failed: generic failure",
			wantIP:     "2001:db8::1",
			wantReason: ReasonPostfixSASL,
			wantMatch:  true,
		},
		{
			name:      "postfix non-auth line",
			line:      "Apr  3 12:00:01 lab2 postfix/smtpd[54321]: connect from unknown[185.234.72.10]",
			wantMatch: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			v, ok := d.Detect([]byte(tt.line))
			if ok != tt.wantMatch {
				t.Errorf("Detect() match = %v, want %v", ok, tt.wantMatch)
				return
			}
			if !tt.wantMatch {
				return
			}
			if v.IP.String() != tt.wantIP {
				t.Errorf("Detect() IP = %v, want %v", v.IP.String(), tt.wantIP)
			}
			if v.Reason != tt.wantReason {
				t.Errorf("Detect() Reason = %v, want %v", v.Reason, tt.wantReason)
			}
			if v.Service != "postfix" {
				t.Errorf("Detect() Service = %v, want postfix", v.Service)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Exim: "authenticator failed for.*[<ip>]"
// Source: /var/log/exim/mainlog (DA), /var/log/exim4/mainlog (Debian)
// The critical test: Exim dual-IP format where extractBracketIP must
// pick the LAST bracket pair (real TCP peer), not the first (claimed).
// ---------------------------------------------------------------------------

func TestMailDetector_Exim(t *testing.T) {
	d := NewMailDetector()

	tests := []struct {
		name       string
		line       string
		wantIP     string
		wantReason uint16
		wantMatch  bool
	}{
		{
			// Real srv2 format: dual-IP with H=(claimed) [real_tcp_peer]
			name:       "exim dual-IP auth failure (srv2 real format)",
			line:       `2026-04-03 08:12:33 dovecot_plain authenticator failed for (User) [185.234.72.10]:58023 H=([10.0.0.99]) [185.234.72.10] I=[10.0.0.1]:465: 535 Incorrect authentication data (set_id=admin@example.com)`,
			wantIP:     "185.234.72.10",
			wantReason: ReasonEximAuthFail,
			wantMatch:  true,
		},
		{
			// Single-IP Exim format
			name:       "exim single-IP auth failure",
			line:       `2026-04-03 08:12:33 dovecot_plain authenticator failed for (User) [203.0.113.42]:58023 I=[10.0.0.1]:465: 535 Incorrect authentication data`,
			wantIP:     "203.0.113.42",
			wantReason: ReasonEximAuthFail,
			wantMatch:  true,
		},
		{
			// IPv6 Exim
			name:       "exim IPv6 auth failure",
			line:       `2026-04-03 08:12:33 dovecot_plain authenticator failed for (User) [2001:db8::1]:58023 I=[::1]:465: 535 Incorrect authentication data`,
			wantIP:     "2001:db8::1",
			wantReason: ReasonEximAuthFail,
			wantMatch:  true,
		},
		{
			// Syslog-routed Exim format (contains "exim" prefix)
			name:       "exim syslog format auth failure",
			line:       "Apr  3 08:12:33 srv2 exim[1234]: dovecot_plain authenticator failed for (User) [185.234.72.10]:58023 I=[10.0.0.1]:465",
			wantIP:     "185.234.72.10",
			wantReason: ReasonEximAuthFail,
			wantMatch:  true,
		},
		{
			// Exim connection log — no authenticator keyword
			name:      "exim connection log no match",
			line:      `2026-04-03 08:12:33 SMTP connection from [185.234.72.10]:58023 I=[10.0.0.1]:25`,
			wantMatch: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			v, ok := d.Detect([]byte(tt.line))
			if ok != tt.wantMatch {
				t.Errorf("Detect() match = %v, want %v", ok, tt.wantMatch)
				return
			}
			if !tt.wantMatch {
				return
			}
			if v.IP.String() != tt.wantIP {
				t.Errorf("Detect() IP = %v, want %v", v.IP.String(), tt.wantIP)
			}
			if v.Reason != tt.wantReason {
				t.Errorf("Detect() Reason = %v, want %v", v.Reason, tt.wantReason)
			}
			if v.Service != "exim" {
				t.Errorf("Detect() Service = %v, want exim", v.Service)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// extractBracketIP edge cases
// ---------------------------------------------------------------------------

func TestMailDetector_ExtractBracketIP(t *testing.T) {
	d := NewMailDetector()

	tests := []struct {
		name    string
		line    string
		wantIP  string
		wantOK  bool
	}{
		{
			name:   "single bracket IP",
			line:   "something [10.0.0.1] something",
			wantIP: "10.0.0.1",
			wantOK: true,
		},
		{
			// Backward scan: returns last valid bracket IP
			name:   "dual bracket IP returns last (backward scan)",
			line:   "from [185.234.72.10] to [10.0.0.1] done",
			wantIP: "10.0.0.1",
			wantOK: true,
		},
		{
			name:   "IPv6 in brackets",
			line:   "from [2001:db8::1] port 25",
			wantIP: "2001:db8::1",
			wantOK: true,
		},
		{
			name:   "no brackets",
			line:   "no brackets here",
			wantOK: false,
		},
		{
			name:   "non-IP in brackets",
			line:   "hostname [not-an-ip] blah",
			wantOK: false,
		},
		{
			name:   "empty brackets",
			line:   "empty [] brackets",
			wantOK: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			addr, ok := d.extractBracketIP([]byte(tt.line))
			if ok != tt.wantOK {
				t.Errorf("extractBracketIP() ok = %v, want %v", ok, tt.wantOK)
				return
			}
			if !tt.wantOK {
				return
			}
			if addr.String() != tt.wantIP {
				t.Errorf("extractBracketIP() IP = %v, want %v", addr.String(), tt.wantIP)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// extractFirstBracketIP (forward scan — used by Exim)
// ---------------------------------------------------------------------------

func TestMailDetector_ExtractFirstBracketIP(t *testing.T) {
	d := NewMailDetector()

	tests := []struct {
		name    string
		line    string
		wantIP  string
		wantOK  bool
	}{
		{
			name:   "single bracket IP",
			line:   "something [10.0.0.1] something",
			wantIP: "10.0.0.1",
			wantOK: true,
		},
		{
			// Exim dual-IP: first valid IP is attacker, not local I= interface
			name:   "Exim format returns first (attacker) IP",
			line:   `[185.234.72.10]:58023 H=([10.0.0.99]) [185.234.72.10] I=[10.0.0.1]:465`,
			wantIP: "185.234.72.10",
			wantOK: true,
		},
		{
			name:   "skips non-IP first bracket",
			line:   `[not-an-ip] then [203.0.113.1]:25`,
			wantIP: "203.0.113.1",
			wantOK: true,
		},
		{
			name:   "no brackets",
			line:   "no brackets here",
			wantOK: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			addr, ok := d.extractFirstBracketIP([]byte(tt.line))
			if ok != tt.wantOK {
				t.Errorf("extractFirstBracketIP() ok = %v, want %v", ok, tt.wantOK)
				return
			}
			if !tt.wantOK {
				return
			}
			if addr.String() != tt.wantIP {
				t.Errorf("extractFirstBracketIP() IP = %v, want %v", addr.String(), tt.wantIP)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// No-match lines should not trigger any mail detector
// ---------------------------------------------------------------------------

func TestMailDetector_NoMatch(t *testing.T) {
	d := NewMailDetector()

	noMatchLines := []string{
		"Apr  3 10:15:22 srv2 sshd[1234]: Failed password for root from 10.0.0.1 port 22 ssh2",
		"Apr  3 10:15:22 srv2 systemd[1]: Started Daily apt upgrade and clean activities.",
		"Apr  3 10:15:22 srv2 kernel: [UFW BLOCK] IN=eth0",
		"",
		"random garbage",
	}

	for _, line := range noMatchLines {
		_, ok := d.Detect([]byte(line))
		if ok {
			t.Errorf("Detect() should not match: %s", line)
		}
	}
}

// ---------------------------------------------------------------------------
// Benchmarks
// ---------------------------------------------------------------------------

func BenchmarkMailDetector_DovecotNative(b *testing.B) {
	d := NewMailDetector()
	line := []byte("Apr 03 14:22:01 srv2 dovecot: auth failed, rip=185.234.72.10, lip=10.0.0.1")

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		d.Detect(line)
	}
}

func BenchmarkMailDetector_DovecotPam(b *testing.B) {
	d := NewMailDetector()
	line := []byte("Apr  3 10:15:22 lab4 dovecot: pam_unix(dovecot:auth): authentication failure; logname= uid=0 euid=0 tty=dovecot ruser=admin rhost=185.234.72.10 user=admin")

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		d.Detect(line)
	}
}

func BenchmarkMailDetector_EximDualIP(b *testing.B) {
	d := NewMailDetector()
	line := []byte(`2026-04-03 08:12:33 dovecot_plain authenticator failed for (User) [185.234.72.10]:58023 H=([10.0.0.99]) [185.234.72.10] I=[10.0.0.1]:465: 535 Incorrect authentication data (set_id=admin@example.com)`)

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		d.Detect(line)
	}
}

func BenchmarkMailDetector_NoMatch(b *testing.B) {
	d := NewMailDetector()
	line := []byte("Apr  3 10:15:22 srv2 sshd[1234]: Accepted publickey for admin from 10.0.0.1 port 22 ssh2")

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		d.Detect(line)
	}
}
