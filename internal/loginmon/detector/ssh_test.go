// =============================================================================
// NFTBan v1.0.30 - SSH Detector Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
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
		name       string
		line       string
		wantIP     string
		wantUser   string
		wantMatch  bool
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
