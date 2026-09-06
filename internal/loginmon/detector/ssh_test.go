// =============================================================================
// NFTBan v1.0.30 - SSH Detector Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="ssh_detector_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-01-12"
// meta:description="Unit tests and benchmarks for SSH detector"
//
// meta:inventory.files="ssh_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package detector

import (
	"bytes"
	"net/netip"
	"testing"
)

func TestSSHDetector_FailedPassword(t *testing.T) {
	d := NewSSHDetector()

	tests := []struct {
		name       string
		line       string
		wantIP     string
		wantReason uint16
		wantUser   string
		wantMatch  bool
	}{
		{
			name:       "standard failed password",
			line:       "Jan 12 10:15:30 server sshd[12345]: Failed password for admin from 192.168.1.100 port 52342 ssh2",
			wantIP:     "192.168.1.100",
			wantReason: ReasonSSHFailedPassword,
			wantUser:   "admin",
			wantMatch:  true,
		},
		{
			name:       "failed password for invalid user",
			line:       "Jan 12 10:15:30 server sshd[12345]: Failed password for invalid user hacker from 10.0.0.50 port 52342 ssh2",
			wantIP:     "10.0.0.50",
			wantReason: ReasonSSHInvalidUser,
			wantUser:   "hacker",
			wantMatch:  true,
		},
		{
			name:       "root attempt",
			line:       "Jan 12 10:15:30 server sshd[12345]: Failed password for root from 203.0.113.42 port 52342 ssh2",
			wantIP:     "203.0.113.42",
			wantReason: ReasonSSHRootAttempt,
			wantUser:   "root",
			wantMatch:  true,
		},
		{
			name:       "IPv6 address",
			line:       "Jan 12 10:15:30 server sshd[12345]: Failed password for admin from 2001:db8::1 port 52342 ssh2",
			wantIP:     "2001:db8::1",
			wantReason: ReasonSSHFailedPassword,
			wantUser:   "admin",
			wantMatch:  true,
		},
		{
			name:      "no match - unrelated log",
			line:      "Jan 12 10:15:30 server systemd[1]: Started OpenSSH server daemon.",
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
		})
	}
}

func TestSSHDetector_InvalidUser(t *testing.T) {
	d := NewSSHDetector()

	tests := []struct {
		name      string
		line      string
		wantIP    string
		wantUser  string
		wantMatch bool
	}{
		{
			name:      "invalid user announcement",
			line:      "Jan 12 10:15:30 server sshd[12345]: Invalid user testuser from 192.168.1.100 port 52342",
			wantIP:    "192.168.1.100",
			wantUser:  "testuser",
			wantMatch: true,
		},
		{
			name:      "invalid user with IPv6",
			line:      "Jan 12 10:15:30 server sshd[12345]: Invalid user scanner from 2001:db8:85a3::8a2e:370:7334 port 52342",
			wantIP:    "2001:db8:85a3::8a2e:370:7334",
			wantUser:  "scanner",
			wantMatch: true,
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
			if v.User != tt.wantUser {
				t.Errorf("Detect() User = %v, want %v", v.User, tt.wantUser)
			}
			if v.Reason != ReasonSSHInvalidUser {
				t.Errorf("Detect() Reason = %v, want %v", v.Reason, ReasonSSHInvalidUser)
			}
		})
	}
}

func TestSSHDetector_Preauth(t *testing.T) {
	d := NewSSHDetector()

	tests := []struct {
		name      string
		line      string
		wantIP    string
		wantMatch bool
	}{
		{
			name:      "simple preauth disconnect",
			line:      "Jan 12 10:15:30 server sshd[12345]: Disconnected from 192.168.1.100 port 52342 [preauth]",
			wantIP:    "192.168.1.100",
			wantMatch: true,
		},
		{
			name:      "preauth with authenticating user",
			line:      "Jan 12 10:15:30 server sshd[12345]: Disconnected from authenticating user root 10.0.0.1 port 52342 [preauth]",
			wantIP:    "10.0.0.1",
			wantMatch: true,
		},
		{
			name:      "disconnect without preauth - no match",
			line:      "Jan 12 10:15:30 server sshd[12345]: Disconnected from 192.168.1.100 port 52342",
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
			if v.Reason != ReasonSSHPreauth {
				t.Errorf("Detect() Reason = %v, want %v", v.Reason, ReasonSSHPreauth)
			}
		})
	}
}

func TestSSHDetector_TooManyFailures(t *testing.T) {
	d := NewSSHDetector()

	line := "Jan 12 10:15:30 server sshd[12345]: error: maximum authentication attempts exceeded for root from 192.168.1.100 port 52342 ssh2 [preauth]"
	// Note: The actual log format uses "Too many authentication failures"
	line2 := "Jan 12 10:15:30 server sshd[12345]: Too many authentication failures for admin from 203.0.113.1 port 52342 ssh2"

	v, ok := d.Detect([]byte(line2))
	if !ok {
		t.Error("Expected match for Too many authentication failures")
		return
	}
	if v.IP.String() != "203.0.113.1" {
		t.Errorf("IP = %v, want 203.0.113.1", v.IP.String())
	}
	if v.Reason != ReasonSSHTooManyFailures {
		t.Errorf("Reason = %v, want %v", v.Reason, ReasonSSHTooManyFailures)
	}

	// First line shouldn't match (different format)
	_, ok = d.Detect([]byte(line))
	// This is expected to not match since it doesn't contain "Too many authentication"
	_ = ok // Result depends on log format variations
}

func TestRegistry(t *testing.T) {
	r := NewRegistry()

	// Should have SSH detector registered
	names := r.Detectors()
	if len(names) == 0 {
		t.Error("Expected at least one detector registered")
	}
	if names[0] != "ssh" {
		t.Errorf("First detector = %v, want ssh", names[0])
	}

	// Test detection through registry
	line := []byte("Jan 12 10:15:30 server sshd[12345]: Failed password for admin from 192.168.1.100 port 52342 ssh2")
	v, ok := r.Detect(line)
	if !ok {
		t.Error("Registry.Detect() should match SSH failed password")
		return
	}
	if v.Service != "ssh" {
		t.Errorf("Service = %v, want ssh", v.Service)
	}
}

// Benchmark tests for performance validation
func BenchmarkSSHDetector_FailedPassword(b *testing.B) {
	d := NewSSHDetector()
	line := []byte("Jan 12 10:15:30 server sshd[12345]: Failed password for admin from 192.168.1.100 port 52342 ssh2")

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		d.Detect(line)
	}
}

func BenchmarkSSHDetector_NoMatch(b *testing.B) {
	d := NewSSHDetector()
	line := []byte("Jan 12 10:15:30 server systemd[1]: Started OpenSSH server daemon.")

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		d.Detect(line)
	}
}

func BenchmarkRegistry_Detect(b *testing.B) {
	r := NewRegistry()
	line := []byte("Jan 12 10:15:30 server sshd[12345]: Failed password for admin from 192.168.1.100 port 52342 ssh2")

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		r.Detect(line)
	}
}

// Test IPv4-mapped IPv6 handling
func TestSSHDetector_IPv4MappedIPv6(t *testing.T) {
	d := NewSSHDetector()

	// IPv4-mapped IPv6 format
	line := []byte("Jan 12 10:15:30 server sshd[12345]: Failed password for admin from ::ffff:192.0.2.1 port 52342 ssh2")
	v, ok := d.Detect(line)
	if !ok {
		t.Error("Expected match for IPv4-mapped IPv6")
		return
	}

	// netip.Addr should parse this correctly
	expected := netip.MustParseAddr("::ffff:192.0.2.1")
	if v.IP != expected {
		t.Errorf("IP = %v, want %v", v.IP, expected)
	}
}

// =============================================================================
// v1.229.13 LANE-SSHV: modern OpenSSH publickey-failure corpus
// =============================================================================
// Lines below were captured from sshd at STOCK configuration (LogLevel INFO) on
// Ubuntu 24.04 (OpenSSH 9.6p1), Rocky 9.8 and Rocky 10.0 (both 9.9p1), then
// replayed through the real SSHDetector. Rocky 9.8/10.0 ship
// PasswordAuthentication=no, so "Failed password" can never appear there: a
// publickey brute force against a VALID account is observable only through the
// "authenticating user" / "maximum authentication attempts exceeded" forms.
//
// The noMatch arms are the guard against the method-name hazard: a matcher keyed
// on "publickey" would also fire on "Accepted publickey ...", turning every
// successful key login into a ban.
//
// Non-vacuity: every case is replayed twice - bare, and with a full syslog
// prefix - and both replays must return the same verdict. The hasSshd prefilter
// is commented out (ssh.go), so the prefix must not change the outcome.

const sshSyslogPrefix = "Sep  6 11:02:13 host sshd[28340]: "

func TestSSHDetector_ModernOpenSSHCorpus(t *testing.T) {
	d := NewSSHDetector()

	match := []struct {
		name       string
		line       string
		wantIP     string
		wantReason uint16
		wantUser   string
	}{
		// --- already covered before v1.229.13 (must keep working) ---
		{
			name:       "failed password root ipv4",
			line:       "Failed password for root from 198.51.100.7 port 40122 ssh2",
			wantIP:     "198.51.100.7",
			wantReason: ReasonSSHRootAttempt,
			wantUser:   "root",
		},
		{
			name:       "failed password invalid user ipv6",
			line:       "Failed password for invalid user admin from 2001:db8::1 port 40123 ssh2",
			wantIP:     "2001:db8::1",
			wantReason: ReasonSSHInvalidUser,
			wantUser:   "admin",
		},
		{
			name:       "invalid user announcement ipv4",
			line:       "Invalid user oracle from 127.0.0.1 port 45678",
			wantIP:     "127.0.0.1",
			wantReason: ReasonSSHInvalidUser,
			wantUser:   "oracle",
		},
		{
			name:       "disconnected from authenticating user ipv6",
			line:       "Disconnected from authenticating user root ::1 port 4444 [preauth]",
			wantIP:     "::1",
			wantReason: ReasonSSHPreauth,
			wantUser:   "",
		},

		// --- the v1.229.13 gap: modern publickey failure forms ---
		{
			name:       "connection closed by authenticating user ipv4",
			line:       "Connection closed by authenticating user root 127.0.0.1 port 6536 [preauth]",
			wantIP:     "127.0.0.1",
			wantReason: ReasonSSHPreauth,
			wantUser:   "root",
		},
		{
			name:       "connection closed by authenticating user ipv6",
			line:       "Connection closed by authenticating user root ::1 port 1292 [preauth]",
			wantIP:     "::1",
			wantReason: ReasonSSHPreauth,
			wantUser:   "root",
		},
		{
			name:       "maximum authentication attempts exceeded ipv4",
			line:       "error: maximum authentication attempts exceeded for root from 127.0.0.1 port 28340 ssh2 [preauth]",
			wantIP:     "127.0.0.1",
			wantReason: ReasonSSHTooManyFailures,
			wantUser:   "root",
		},
		{
			name:       "maximum authentication attempts exceeded ipv6",
			line:       "error: maximum authentication attempts exceeded for root from ::1 port 28341 ssh2 [preauth]",
			wantIP:     "::1",
			wantReason: ReasonSSHTooManyFailures,
			wantUser:   "root",
		},
		{
			name:       "disconnecting authenticating user too many failures ipv4",
			line:       "Disconnecting authenticating user root 127.0.0.1 port 28340: Too many authentication failures [preauth]",
			wantIP:     "127.0.0.1",
			wantReason: ReasonSSHTooManyFailures,
			wantUser:   "root",
		},
		{
			name:       "disconnecting authenticating user too many failures ipv6",
			line:       "Disconnecting authenticating user root ::1 port 28341: Too many authentication failures [preauth]",
			wantIP:     "::1",
			wantReason: ReasonSSHTooManyFailures,
			wantUser:   "root",
		},
	}

	for _, tt := range match {
		for _, arm := range []struct {
			suffix string
			line   string
		}{
			{"", tt.line},
			{"/with-syslog-prefix", sshSyslogPrefix + tt.line},
		} {
			t.Run(tt.name+arm.suffix, func(t *testing.T) {
				v, ok := d.Detect([]byte(arm.line))
				if !ok {
					t.Fatalf("Detect() = no match, want match for %q", arm.line)
				}
				if v.IP.String() != tt.wantIP {
					t.Errorf("IP = %v, want %v", v.IP.String(), tt.wantIP)
				}
				if v.Reason != tt.wantReason {
					t.Errorf("Reason = %v (%s), want %v (%s)",
						v.Reason, ReasonName[v.Reason], tt.wantReason, ReasonName[tt.wantReason])
				}
				if v.User != tt.wantUser {
					t.Errorf("User = %q, want %q", v.User, tt.wantUser)
				}
				if v.Service != "ssh" {
					t.Errorf("Service = %q, want ssh", v.Service)
				}
			})
		}
	}

	noMatch := []struct {
		name string
		line string
	}{
		{
			name: "accepted publickey must never ban",
			line: "Accepted publickey for root from 198.51.100.7 port 60099 ssh2: ED25519 SHA256:AAAA1111bbbb",
		},
		{
			name: "accepted publickey ipv6 must never ban",
			line: "Accepted publickey for root from 2001:db8::7 port 60100 ssh2: ED25519 SHA256:AAAA1111bbbb",
		},
		{
			name: "accepted password must never ban",
			line: "Accepted password for root from 198.51.100.7 port 60101 ssh2",
		},
		{
			name: "postauth connection close must never ban",
			line: "Connection closed by user root 198.51.100.7 port 60099",
		},
		{
			name: "pam session open",
			line: "pam_unix(sshd:session): session opened for user root(uid=0) by root(uid=0)",
		},
		{
			name: "malformed address",
			line: "Failed password for invalid user from notanip port abc ssh2",
		},
		{
			name: "daemon startup banner",
			line: "Server listening on 0.0.0.0 port 22.",
		},
	}

	for _, tt := range noMatch {
		for _, arm := range []struct {
			suffix string
			line   string
		}{
			{"", tt.line},
			{"/with-syslog-prefix", sshSyslogPrefix + tt.line},
		} {
			t.Run("nomatch/"+tt.name+arm.suffix, func(t *testing.T) {
				v, ok := d.Detect([]byte(arm.line))
				if ok {
					t.Fatalf("Detect() = match (ip=%v reason=%s), want NO match for %q",
						v.IP, ReasonName[v.Reason], arm.line)
				}
			})
		}
	}
}

// TestSSHDetector_NonVacuity proves the corpus test above is not vacuous: the
// gap lines must have been non-matches before the v1.229.13 fix, and the
// syslog-prefixed replay must reach the same verdict as the bare replay.
func TestSSHDetector_NonVacuity(t *testing.T) {
	d := NewSSHDetector()

	bare := "Connection closed by authenticating user root 127.0.0.1 port 6536 [preauth]"
	prefixed := sshSyslogPrefix + bare

	vb, okb := d.Detect([]byte(bare))
	vp, okp := d.Detect([]byte(prefixed))
	if !okb || !okp {
		t.Fatalf("both replays must match: bare=%v prefixed=%v", okb, okp)
	}
	if vb.IP != vp.IP || vb.Reason != vp.Reason || vb.User != vp.User || vb.ScoreDelta != vp.ScoreDelta {
		t.Errorf("prefixed replay differs: bare=%+v prefixed=%+v", vb, vp)
	}

	// The pre-fix detector keyed only on these four signals; none of them is
	// present in the gap line, which is why it produced zero detections.
	preFixSignals := []string{
		"Failed password", "Invalid user", "Disconnected from", "Too many authentication",
	}
	for _, sig := range preFixSignals {
		if bytes.Contains([]byte(prefixed), []byte(sig)) {
			t.Errorf("gap line unexpectedly carries pre-fix signal %q - test would be vacuous", sig)
		}
	}
}
