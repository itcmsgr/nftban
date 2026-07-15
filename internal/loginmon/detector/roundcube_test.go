// =============================================================================
// NFTBan v1.186.0 - Roundcube detector tests (parser match/non-match + public-IP guard)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="roundcube_detector_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-14"
// meta:description="Hard-stop tests: Failed-login match, Successful-login non-match, and the mandatory public-IP-only guard (localhost/private/link-local/ULA/unspecified/malformed = NO ban)."
// meta:inventory.files="roundcube_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package detector

import "testing"

// sample DA line shape (2026-06-14), public IP.
const rcFailedPublic = `[14-Jun-2026 10:54:37 +0000]: <0a1b2c3d> Failed login for user@example.gr from 192.0.2.122 in session 0a1b2c3d4e5f6789 (error: 0)`

func TestRoundcube_FailedPublic_Match(t *testing.T) {
	d := NewRoundcubeDetector()
	v, ok := d.Detect([]byte(rcFailedPublic))
	if !ok {
		t.Fatal("expected a verdict for a public failed-login line")
	}
	if v.Reason != ReasonRoundcubeAuthFail {
		t.Errorf("reason = %d, want %d (roundcube)", v.Reason, ReasonRoundcubeAuthFail)
	}
	if v.Service != "roundcube" {
		t.Errorf("service = %q, want roundcube", v.Service)
	}
	if v.IP.String() != "192.0.2.122" {
		t.Errorf("ip = %s, want 192.0.2.122", v.IP)
	}
	if v.User != "user@example.gr" {
		t.Errorf("user = %q, want user@example.gr", v.User)
	}
	if v.ScoreDelta != scoreRoundcubeAuthFail {
		t.Errorf("score = %d, want %d", v.ScoreDelta, scoreRoundcubeAuthFail)
	}
}

func TestRoundcube_IPv6Public_Match(t *testing.T) {
	d := NewRoundcubeDetector()
	line := `[14-Jun-2026 10:54:37 +0000]: <s> Failed login for u@d from 2001:db8:c012:57::99 in session abcd (error: 0)`
	v, ok := d.Detect([]byte(line))
	if !ok || v.IP.String() != "2001:db8:c012:57::99" {
		t.Fatalf("expected IPv6 public match, got ok=%v ip=%s", ok, v.IP)
	}
}

// HARD STOP: a "Successful login" line must NEVER produce a verdict.
func TestRoundcube_SuccessfulLogin_NoVerdict(t *testing.T) {
	d := NewRoundcubeDetector()
	line := `[14-Jun-2026 10:55:01 +0000]: <s> Successful login for user@example.gr (ID: 1) from 192.0.2.122 in session deadbeef`
	if _, ok := d.Detect([]byte(line)); ok {
		t.Fatal("HARD STOP VIOLATION: success line produced a verdict")
	}
}

// HARD STOP: the public-IP-only guard — no non-public IP may ever ban.
func TestRoundcube_PublicIPGuard(t *testing.T) {
	d := NewRoundcubeDetector()
	noBan := []string{
		"127.0.0.1",       // loopback v4
		"::1",             // loopback v6
		"10.0.0.5",        // RFC1918
		"172.16.4.9",      // RFC1918
		"192.168.1.50",    // RFC1918
		"169.254.10.10",   // link-local v4
		"fe80::1",         // link-local v6
		"fc00::1234",      // ULA v6
		"fd12:3456::1",    // ULA v6
		"0.0.0.0",         // unspecified
		"::",              // unspecified v6
		"224.0.0.1",       // multicast
		"not-an-ip",       // malformed
		"999.999.999.999", // malformed
	}
	for _, ip := range noBan {
		line := "[14-Jun-2026 10:54:37 +0000]: <s> Failed login for u@d from " + ip + " in session abcd (error: 0)"
		if v, ok := d.Detect([]byte(line)); ok {
			t.Errorf("HARD STOP VIOLATION: non-public/malformed IP %q produced a ban verdict (ip=%s)", ip, v.IP)
		}
	}
}

// A username containing " from " must not derail IP extraction (anchor on " in session").
func TestRoundcube_UserWithFromWord(t *testing.T) {
	d := NewRoundcubeDetector()
	line := `[14-Jun-2026 10:54:37 +0000]: <s> Failed login for weird from user@d from 192.0.2.122 in session abcd (error: 0)`
	v, ok := d.Detect([]byte(line))
	if !ok || v.IP.String() != "192.0.2.122" {
		t.Fatalf("expected IP 192.0.2.122 despite 'from' in username, got ok=%v ip=%s", ok, v.IP)
	}
}

// Non-Roundcube lines (access log, ssh) must not match.
func TestRoundcube_ForeignLines_NoMatch(t *testing.T) {
	d := NewRoundcubeDetector()
	foreign := []string{
		`192.0.2.122 - - [14/Jun/2026:04:37:53 +0000] "POST /wp-login.php HTTP/1.1" 200 1141 "-" "-"`,
		`Jun 14 10:00:00 host sshd[1]: Failed password for root from 192.0.2.122 port 2222 ssh2`,
		``,
	}
	for _, line := range foreign {
		if _, ok := d.Detect([]byte(line)); ok {
			t.Errorf("foreign line wrongly matched roundcube: %q", line)
		}
	}
}
