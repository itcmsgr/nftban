// =============================================================================
// NFTBan v1.180.0 - FTP Detector Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// meta:name="ftp_detector_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-13"
// meta:description="Unit tests for FTPDetector — auth_failure ownership: pure-ftpd / vsftpd / proftpd authentication-failure lines matched (ReasonFTPAuthFail, IPv4+IPv6); non-auth FTP lines (successful login, transfers) and unrelated web access-log lines not matched (wrong-module prevention). Uses the real FTPDetector + full registry."
//
// meta:inventory.files="ftp_test.go"
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

func TestFTPDetector(t *testing.T) {
	d := NewFTPDetector()
	tests := []struct {
		name      string
		line      string
		wantMatch bool
		wantIP    string
		wantSvc   string
	}{
		// --- pure-ftpd auth failures (owned) ---
		{
			"pure-ftpd auth fail IPv4",
			`Jun 13 10:00:00 host pure-ftpd: (?@203.0.113.7) [WARNING] Authentication failed for user [bob] [203.0.113.7]`,
			true, "203.0.113.7", "pure-ftpd",
		},
		{
			"pure-ftpd auth fail IPv6",
			`Jun 13 10:00:00 host pure-ftpd: (?@2001:db8::7) [WARNING] Authentication failed for user [bob] [2001:db8::7]`,
			true, "2001:db8::7", "pure-ftpd",
		},
		// --- vsftpd auth failures (owned) ---
		{
			"vsftpd FAIL LOGIN IPv4",
			`Mon Jun 13 10:00:00 2026 [pid 1234] [bob] FAIL LOGIN: Client "198.51.100.5"`,
			true, "198.51.100.5", "vsftpd",
		},
		{
			"vsftpd FAIL LOGIN IPv6",
			`Mon Jun 13 10:00:00 2026 [pid 1234] [bob] FAIL LOGIN: Client "2001:db8::5"`,
			true, "2001:db8::5", "vsftpd",
		},
		// --- proftpd auth failures (owned) ---
		{
			"proftpd no such user IPv4",
			`Jun 13 10:00:00 host proftpd[4321]: host (192.0.2.10[192.0.2.10]) - USER baduser: no such user found from 192.0.2.10 [192.0.2.10] to ::ffff:10.0.0.1:21`,
			true, "192.0.2.10", "proftpd",
		},
		{
			"proftpd login failed bracket-IP IPv6",
			`Jun 13 10:00:00 host proftpd[4321]: proftpd login failed for user bob [2001:db8::a]`,
			true, "2001:db8::a", "proftpd",
		},
		{
			"proftpd authentication failed IPv4",
			`Jun 13 10:00:00 host proftpd[4321]: SECURITY VIOLATION: authentication failed from 203.0.113.99`,
			true, "203.0.113.99", "proftpd",
		},

		// --- NOT owned: non-auth FTP + unrelated lines (wrong-module prevention) ---
		{
			"pure-ftpd successful login not a failure",
			`Jun 13 10:00:00 host pure-ftpd: (bob@203.0.113.7) [INFO] Logged in [203.0.113.7]`,
			false, "", "",
		},
		{
			"vsftpd OK LOGIN not a failure",
			`Mon Jun 13 10:00:00 2026 [pid 1234] [bob] OK LOGIN: Client "198.51.100.5"`,
			false, "", "",
		},
		{
			"proftpd transfer line not an auth failure",
			`Jun 13 10:00:00 host proftpd[4321]: host (192.0.2.10[192.0.2.10]) - FTP session opened.`,
			false, "", "",
		},
		{
			"web access-log 401 must NOT match FTP detector",
			`203.0.113.7 - - [13/Jun/2026:10:00:00 +0000] "GET /admin HTTP/1.1" 401 12 "-" "curl"`,
			false, "", "",
		},
		{
			"ssh auth-fail line must NOT match FTP detector",
			`Jun 13 10:00:00 host sshd[111]: Failed password for root from 203.0.113.7 port 2222 ssh2`,
			false, "", "",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			v, ok := d.Detect([]byte(tt.line))
			if ok != tt.wantMatch {
				t.Fatalf("match=%v want %v (line=%q)", ok, tt.wantMatch, tt.line)
			}
			if !tt.wantMatch {
				return
			}
			if v.Reason != ReasonFTPAuthFail {
				t.Errorf("reason=%d want ReasonFTPAuthFail(%d)", v.Reason, ReasonFTPAuthFail)
			}
			if v.Service != tt.wantSvc {
				t.Errorf("service=%q want %q", v.Service, tt.wantSvc)
			}
			want, _ := netip.ParseAddr(tt.wantIP)
			if v.IP != want {
				t.Errorf("ip=%v want %v", v.IP, want)
			}
			if v.ScoreDelta <= 0 {
				t.Errorf("scoreDelta=%d want >0", v.ScoreDelta)
			}
		})
	}
}

// TestFTPDetectorViaRegistry confirms the FTPDetector is wired into the default
// registry and that the registry classifies an FTP auth failure as ReasonFTPAuthFail
// while NOT misclassifying a normal web access-log line as an FTP event.
func TestFTPDetectorViaRegistry(t *testing.T) {
	r := NewRegistry()
	ftp := []byte(`Jun 13 10:00:00 host pure-ftpd: (?@203.0.113.7) [WARNING] Authentication failed for user [bob] [203.0.113.7]`)
	if v, ok := r.Detect(ftp); !ok || v.Reason != ReasonFTPAuthFail {
		t.Errorf("pure-ftpd auth fail → reason=%d ok=%v, want ReasonFTPAuthFail", v.Reason, ok)
	}
	web := []byte(`203.0.113.30 - - [13/Jun/2026:10:00:00 +0000] "GET /index.html HTTP/1.1" 200 1500 "-" "x"`)
	if v, ok := r.Detect(web); ok && v.Reason == ReasonFTPAuthFail {
		t.Errorf("normal web access-log line must NOT be classified as FTP auth fail")
	}
}
