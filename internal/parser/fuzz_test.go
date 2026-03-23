// =============================================================================
// NFTBan - Security-Critical Fuzz Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="fuzz_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-02-16"
// meta:description="Fuzz tests for security-critical parsing functions"
//
// This file contains fuzz tests for log parsing and config parsing functions.
// These tests help identify edge cases, panics, and potential security issues
// in parsing untrusted input (log lines, config files, IP addresses).
//
// Run with: go test -fuzz=FuzzParseLogLine -fuzztime=30s ./internal/parser/
//
// meta:inventory.files="fuzz_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package parser

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/feeds"
	"github.com/itcmsgr/nftban/internal/loginmon/detector"
	"github.com/itcmsgr/nftban/internal/netutil"
	"github.com/itcmsgr/nftban/internal/timeutil"
	"github.com/itcmsgr/nftban/internal/util"
)

// =============================================================================
// Log Line Parsing Fuzz Tests
// =============================================================================

// FuzzParseLogLine tests the login detector registry with arbitrary log lines.
// This exercises all detectors: SSH, Mail (Dovecot/Postfix/Exim), FTP, Panel.
func FuzzParseLogLine(f *testing.F) {
	// Seed corpus with real-world log line examples
	seeds := []string{
		// SSH patterns
		"Failed password for root from 192.168.1.1 port 22 ssh2",
		"Accepted publickey for user from 10.0.0.1 port 22 ssh2",
		"Jan 12 10:15:30 server sshd[12345]: Failed password for admin from 192.168.1.100 port 52342 ssh2",
		"Jan 12 10:15:30 server sshd[12345]: Failed password for invalid user hacker from 10.0.0.50 port 52342 ssh2",
		"Invalid user testuser from 192.168.1.100 port 52342",
		"Disconnected from 192.168.1.100 port 52342 [preauth]",
		"Disconnected from authenticating user root 10.0.0.1 port 52342 [preauth]",
		"Too many authentication failures for admin from 203.0.113.1 port 52342 ssh2",
		"Failed password for root from 2001:db8::1 port 52342 ssh2",
		"Failed password for admin from ::ffff:192.0.2.1 port 52342 ssh2",

		// Dovecot patterns
		"dovecot: auth failed, rip=192.168.1.100",
		"Jan 12 10:15:30 mail dovecot[1234]: auth failed for user=test, rip=10.0.0.1, lip=127.0.0.1",

		// Postfix patterns
		"postfix/smtpd[1234]: warning: unknown[192.168.1.100]: SASL LOGIN authentication failed",
		"Jan 12 10:15:30 mail postfix/smtpd[1234]: SASL LOGIN authentication failed: authentication failed",

		// Exim patterns
		"exim[1234]: authenticator failed for host [192.168.1.100]",

		// Pure-FTPd patterns
		"pure-ftpd: Authentication failed for user [test] [192.168.1.100]",

		// vsftpd patterns
		"vsftpd: FAIL LOGIN: Client \"192.168.1.100\"",

		// ProFTPD patterns
		"proftpd[1234]: USER test no such user found from 192.168.1.100",
		"proftpd[1234]: login failed from 10.0.0.1",

		// DirectAdmin patterns
		"directadmin: FAILED LOGIN admin IP=192.168.1.100",

		// cPanel patterns
		"cpanel: failed login for user test ip=192.168.1.100",
		"cphulkd: blocked login from 10.0.0.1",

		// Plesk patterns
		"plesk: authentication failed from 192.168.1.100",

		// Edge cases
		"",
		"no ip here",
		"random log line without any pattern",
		"from 999.999.999.999 invalid ip",
		"from ::invalid::ipv6:: port 22",
		"Failed password for \x00nullbyte from 1.2.3.4 port 22",
		"Failed password for user with spaces from 1.2.3.4 port 22",
		"a]b[c]d[192.168.1.1]e", // nested brackets
	}

	for _, s := range seeds {
		f.Add(s)
	}

	registry := detector.NewRegistry()

	f.Fuzz(func(t *testing.T, input string) {
		// The detector should never panic on any input
		_, _ = registry.Detect([]byte(input))

		// Also test DetectAll
		_ = registry.DetectAll([]byte(input))
	})
}

// FuzzSSHDetector specifically tests the SSH detector with targeted inputs
func FuzzSSHDetector(f *testing.F) {
	seeds := []string{
		"Failed password for root from 192.168.1.1 port 22 ssh2",
		"Failed password for invalid user test from 10.0.0.1 port 22",
		"Invalid user scanner from 192.168.1.100 port 22",
		"Disconnected from 192.168.1.100 port 22 [preauth]",
		"Disconnected from authenticating user root 10.0.0.1 port 22 [preauth]",
		"Too many authentication failures for user from 10.0.0.1 port 22",
		"Failed password from from from 1.2.3.4 port 22", // multiple "from"
		"Failed password for from 1.2.3.4", // missing user
		"Failed password for user from", // missing IP
		"Failed password for user from  port 22", // missing IP with port
	}

	for _, s := range seeds {
		f.Add(s)
	}

	d := detector.NewSSHDetector()

	f.Fuzz(func(t *testing.T, input string) {
		_, _ = d.Detect([]byte(input))
	})
}

// FuzzMailDetector tests mail server log parsing
func FuzzMailDetector(f *testing.F) {
	seeds := []string{
		"dovecot: auth failed, rip=192.168.1.100",
		"dovecot: auth failed, rip=2001:db8::1, lip=::1",
		"postfix/smtpd: SASL LOGIN authentication failed [192.168.1.100]",
		"exim: authenticator failed for [192.168.1.100]",
		"dovecot: auth failed, rip=", // missing IP
		"dovecot: auth failed, rip=invalid",
		"postfix: SASL authentication failed []", // empty brackets
		"exim: authenticator failed for [not.an.ip]",
	}

	for _, s := range seeds {
		f.Add(s)
	}

	d := detector.NewMailDetector()

	f.Fuzz(func(t *testing.T, input string) {
		_, _ = d.Detect([]byte(input))
	})
}

// FuzzFTPDetector tests FTP server log parsing
func FuzzFTPDetector(f *testing.F) {
	seeds := []string{
		"pure-ftpd: Authentication failed for user [test] [192.168.1.100]",
		"vsftpd: FAIL LOGIN: Client \"192.168.1.100\"",
		"proftpd: no such user found from 192.168.1.100",
		"pure-ftpd: Authentication failed []",
		"vsftpd: FAIL LOGIN: Client \"\"",
		"proftpd: no such user found from ",
	}

	for _, s := range seeds {
		f.Add(s)
	}

	d := detector.NewFTPDetector()

	f.Fuzz(func(t *testing.T, input string) {
		_, _ = d.Detect([]byte(input))
	})
}

// FuzzPanelDetector tests control panel log parsing
func FuzzPanelDetector(f *testing.F) {
	seeds := []string{
		"directadmin: FAILED LOGIN admin IP=192.168.1.100",
		"cpanel: failed login ip=192.168.1.100",
		"cphulkd: blocked from 10.0.0.1",
		"plesk: authentication failed from 192.168.1.100",
		"directadmin: FAILED LOGIN admin IP=",
		"cpanel: failed login ip=not.valid",
		"plesk: authentication failed from [192.168.1.100]",
	}

	for _, s := range seeds {
		f.Add(s)
	}

	d := detector.NewPanelDetector()

	f.Fuzz(func(t *testing.T, input string) {
		_, _ = d.Detect([]byte(input))
	})
}

// =============================================================================
// Feed/Config Parsing Fuzz Tests
// =============================================================================

// FuzzParseFeedLine tests IP/CIDR feed line parsing
func FuzzParseFeedLine(f *testing.F) {
	seeds := []string{
		// Valid IPs
		"192.168.1.1",
		"10.0.0.1",
		"255.255.255.255",
		"0.0.0.0",
		"2001:db8::1",
		"::1",
		"::ffff:192.168.1.1",

		// Valid CIDRs
		"192.168.0.0/24",
		"10.0.0.0/8",
		"172.16.0.0/12",
		"2001:db8::/32",
		"::1/128",

		// IP ranges
		"192.168.1.1-192.168.1.10",

		// With comments
		"192.168.1.1 # blocked IP",
		"192.168.1.1 ; another comment",
		"# full line comment",
		"; semicolon comment",

		// With whitespace
		"  192.168.1.1  ",
		"\t10.0.0.1\t",
		"192.168.1.1   reason   timestamp",

		// Invalid inputs
		"",
		"not-an-ip",
		"192.168.1",
		"192.168.1.256",
		"192.168.1.1/33",
		"192.168.1.1/-1",
		"::gggg",
		"1.2.3.4.5",
		"1.2.3.4/",
		"/24",
		"192.168.1.1-",
		"-192.168.1.1",
		"192.168.1.10-192.168.1.1", // reversed range

		// Edge cases
		"0.0.0.0/0",
		"::/0",
		"127.0.0.1",
		"localhost",
	}

	for _, s := range seeds {
		f.Add(s)
	}

	f.Fuzz(func(t *testing.T, input string) {
		// Should never panic
		_, _ = feeds.ParseFeedLine(input)

		// Also test silent variant
		_ = feeds.ParseFeedLineSilent(input)
	})
}

// FuzzValidateAndNormalizeIP tests IP validation and normalization
func FuzzValidateAndNormalizeIP(f *testing.F) {
	seeds := []string{
		"192.168.1.1",
		"10.0.0.1",
		"2001:db8::1",
		"::1",
		"192.168.0.0/24",
		"2001:db8::/32",
		"",
		"   192.168.1.1   ",
		"invalid",
		"192.168.1.1/24extra",
		"192.168.1.256",
	}

	for _, s := range seeds {
		f.Add(s)
	}

	f.Fuzz(func(t *testing.T, input string) {
		_, _, _ = netutil.ValidateAndNormalizeIP(input)
	})
}

// FuzzIsIPContainedInCIDR tests CIDR containment checking
func FuzzIsIPContainedInCIDR(f *testing.F) {
	// Seed with IP, CIDR pairs
	f.Add("192.168.1.1", "192.168.0.0/24")
	f.Add("192.168.1.1", "192.168.1.0/24")
	f.Add("10.0.0.1", "10.0.0.0/8")
	f.Add("2001:db8::1", "2001:db8::/32")
	f.Add("invalid", "192.168.0.0/24")
	f.Add("192.168.1.1", "invalid")
	f.Add("", "")
	f.Add("192.168.1.1", "")
	f.Add("", "192.168.0.0/24")

	f.Fuzz(func(t *testing.T, ip, cidr string) {
		_ = netutil.IPContainedInCIDR(ip, cidr)
	})
}

// =============================================================================
// Utility Parsing Fuzz Tests
// =============================================================================

// FuzzParseBool tests boolean string parsing
func FuzzParseBool(f *testing.F) {
	seeds := []string{
		"true", "false", "yes", "no", "1", "0", "on", "off",
		"enabled", "disabled", "TRUE", "FALSE", "True", "False",
		"", "   ", "invalid", "maybe", "yep", "nope",
		"true ", " false", "  yes  ",
	}

	for _, s := range seeds {
		f.Add(s)
	}

	f.Fuzz(func(t *testing.T, input string) {
		_ = util.ParseBool(input, false)
		_ = util.ParseBool(input, true)
	})
}

// FuzzParseInt tests integer string parsing
func FuzzParseInt(f *testing.F) {
	seeds := []string{
		"0", "1", "-1", "100", "-100",
		"2147483647", "-2147483648", // int32 bounds
		"9223372036854775807", "-9223372036854775808", // int64 bounds
		"", "   ", "invalid", "12abc", "abc12",
		"1.5", "1e10", "0x10", "0b10", "0o10",
		"  42  ", "+42", "++1", "--1",
	}

	for _, s := range seeds {
		f.Add(s)
	}

	f.Fuzz(func(t *testing.T, input string) {
		_ = util.ParseInt(input, 0)
		_ = util.ParseInt64(input, 0)
		_ = util.ParseUint(input, 0)
	})
}

// FuzzParseFloat tests float string parsing
func FuzzParseFloat(f *testing.F) {
	seeds := []string{
		"0", "1", "-1", "1.5", "-1.5",
		"0.0", ".5", "5.", "1e10", "1e-10",
		"1.7976931348623157e+308", // max float64
		"-1.7976931348623157e+308",
		"", "   ", "invalid", "NaN", "Inf", "-Inf",
		"  3.14  ", "+3.14", "++1.0", "1.2.3",
	}

	for _, s := range seeds {
		f.Add(s)
	}

	f.Fuzz(func(t *testing.T, input string) {
		_ = util.ParseFloat(input, 0.0)
	})
}

// FuzzParseDuration tests duration string parsing with day/week support
func FuzzParseDuration(f *testing.F) {
	seeds := []string{
		"1h", "30m", "60s", "1h30m",
		"7d", "1w", "30d", "52w",
		"1ms", "1us", "1ns",
		"0", "0s", "0d", "0w",
		"", "   ", "invalid", "abc",
		"1x", "1dd", "1ww", "1hh",
		"-1h", "-7d", "-1w",
		"1d2h3m", // mixed (should fail for d)
		"9999999999999d", // overflow
		"  24h  ",
	}

	for _, s := range seeds {
		f.Add(s)
	}

	f.Fuzz(func(t *testing.T, input string) {
		_, _ = timeutil.ParseDuration(input)
		_ = timeutil.ParseDurationDefault(input, 0)
		_, _ = timeutil.ParseSeconds(input)
	})
}

// =============================================================================
// IP Utility Fuzz Tests
// =============================================================================

// FuzzIsIPv4 tests IPv4 detection
func FuzzIsIPv4(f *testing.F) {
	seeds := []string{
		"192.168.1.1", "10.0.0.1", "0.0.0.0", "255.255.255.255",
		"2001:db8::1", "::1", "::ffff:192.168.1.1",
		"", "invalid", "192.168.1", "192.168.1.256",
	}

	for _, s := range seeds {
		f.Add(s)
	}

	f.Fuzz(func(t *testing.T, input string) {
		_ = netutil.IsIPv4(input)
		_ = netutil.IsIPv6(input)
		_ = netutil.IsValidIP(input)
		_ = netutil.IsPrivateIP(input)
		_ = netutil.IsPublicIP(input)
		_ = netutil.IsCIDR(input)
		_ = netutil.NormalizeIP(input)
		_ = netutil.GetIPFamily(input)
	})
}

// FuzzParseIP tests IP parsing
func FuzzParseIP(f *testing.F) {
	seeds := []string{
		"192.168.1.1", "10.0.0.1", "2001:db8::1", "::1",
		"", "invalid", "192.168.1.256", "::gggg",
	}

	for _, s := range seeds {
		f.Add(s)
	}

	f.Fuzz(func(t *testing.T, input string) {
		_ = netutil.ParseIP(input)
	})
}

// FuzzParseCIDR tests CIDR parsing
func FuzzParseCIDR(f *testing.F) {
	seeds := []string{
		"192.168.0.0/24", "10.0.0.0/8", "2001:db8::/32",
		"", "invalid", "192.168.1.1", "192.168.0.0/33",
		"192.168.0.0/-1", "192.168.0.0/",
	}

	for _, s := range seeds {
		f.Add(s)
	}

	f.Fuzz(func(t *testing.T, input string) {
		_, _, _ = netutil.ParseCIDR(input)
	})
}
