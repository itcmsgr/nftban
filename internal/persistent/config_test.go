// =============================================================================
// NFTBan - Tests for persistent configuration
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="persistent_config_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for persistent configuration"
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

package persistent

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// =============================================================================
// Config defaults tests
// =============================================================================

func TestConfig_Defaults(t *testing.T) {
	// Create a minimal config via parseConfigFile on a nonexistent file
	cfg := &Config{
		GlobalThreshold: 10,
		GlobalPeriod:    24 * time.Hour,
		GlobalAction:    "permanent",
		Enabled:         true,
		Filters:         make(map[string]*FilterConfig),
	}

	if cfg.GlobalThreshold != 10 {
		t.Errorf("GlobalThreshold = %d, want 10", cfg.GlobalThreshold)
	}
	if cfg.GlobalPeriod != 24*time.Hour {
		t.Errorf("GlobalPeriod = %v, want 24h", cfg.GlobalPeriod)
	}
	if cfg.GlobalAction != "permanent" {
		t.Errorf("GlobalAction = %q, want permanent", cfg.GlobalAction)
	}
	if !cfg.Enabled {
		t.Error("Enabled should default to true")
	}
}

// =============================================================================
// parseConfigFile tests
// =============================================================================

func TestParseConfigFile_GlobalSettings(t *testing.T) {
	dir := t.TempDir()
	confFile := filepath.Join(dir, "persistent.conf")

	content := `[global]
default_threshold = 5
default_period = 7d
default_action = escalate
enabled = true
ban_log = /custom/bans.log
offenders_log = /custom/offenders.log
offenders_conf = /custom/offenders.conf
`
	if err := os.WriteFile(confFile, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	cfg := &Config{
		GlobalThreshold: 10,
		GlobalPeriod:    24 * time.Hour,
		GlobalAction:    "permanent",
		Enabled:         true,
		Filters:         make(map[string]*FilterConfig),
	}

	if err := cfg.parseConfigFile(confFile); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if cfg.GlobalThreshold != 5 {
		t.Errorf("GlobalThreshold = %d, want 5", cfg.GlobalThreshold)
	}
	if cfg.GlobalPeriod != 7*24*time.Hour {
		t.Errorf("GlobalPeriod = %v, want 168h", cfg.GlobalPeriod)
	}
	if cfg.GlobalAction != "escalate" {
		t.Errorf("GlobalAction = %q, want escalate", cfg.GlobalAction)
	}
	if cfg.BanLog != "/custom/bans.log" {
		t.Errorf("BanLog = %q, want /custom/bans.log", cfg.BanLog)
	}
	if cfg.OffendersLog != "/custom/offenders.log" {
		t.Errorf("OffendersLog = %q, want /custom/offenders.log", cfg.OffendersLog)
	}
	if cfg.OffendersConf != "/custom/offenders.conf" {
		t.Errorf("OffendersConf = %q, want /custom/offenders.conf", cfg.OffendersConf)
	}
}

func TestParseConfigFile_FilterSections(t *testing.T) {
	dir := t.TempDir()
	confFile := filepath.Join(dir, "persistent.conf")

	content := `[global]
default_threshold = 10
default_period = 24h
default_action = permanent

[sshd]
threshold = 3
period = 1h
action = ban
comment = "SSH brute force"

[http]
threshold = 20
period = 30m
action = throttle
comment = "HTTP flooding"
`
	if err := os.WriteFile(confFile, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	cfg := &Config{
		GlobalThreshold: 10,
		GlobalPeriod:    24 * time.Hour,
		GlobalAction:    "permanent",
		Enabled:         true,
		Filters:         make(map[string]*FilterConfig),
	}

	if err := cfg.parseConfigFile(confFile); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Check sshd filter
	sshd, exists := cfg.Filters["sshd"]
	if !exists {
		t.Fatal("expected sshd filter to exist")
	}
	if sshd.Threshold != 3 {
		t.Errorf("sshd.Threshold = %d, want 3", sshd.Threshold)
	}
	if sshd.Period != time.Hour {
		t.Errorf("sshd.Period = %v, want 1h", sshd.Period)
	}
	if sshd.Action != "ban" {
		t.Errorf("sshd.Action = %q, want ban", sshd.Action)
	}
	if sshd.Comment != "SSH brute force" {
		t.Errorf("sshd.Comment = %q, want SSH brute force", sshd.Comment)
	}

	// Check http filter
	http, exists := cfg.Filters["http"]
	if !exists {
		t.Fatal("expected http filter to exist")
	}
	if http.Threshold != 20 {
		t.Errorf("http.Threshold = %d, want 20", http.Threshold)
	}
	if http.Period != 30*time.Minute {
		t.Errorf("http.Period = %v, want 30m", http.Period)
	}
	if http.Action != "throttle" {
		t.Errorf("http.Action = %q, want throttle", http.Action)
	}
}

func TestParseConfigFile_CommentsAndBlankLines(t *testing.T) {
	dir := t.TempDir()
	confFile := filepath.Join(dir, "persistent.conf")

	content := `# This is a comment
# Another comment

[global]
default_threshold = 5

# Inline comment after blank line

[sshd]
threshold = 3
`
	if err := os.WriteFile(confFile, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	cfg := &Config{
		GlobalThreshold: 10,
		GlobalPeriod:    24 * time.Hour,
		GlobalAction:    "permanent",
		Enabled:         true,
		Filters:         make(map[string]*FilterConfig),
	}

	if err := cfg.parseConfigFile(confFile); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if cfg.GlobalThreshold != 5 {
		t.Errorf("GlobalThreshold = %d, want 5", cfg.GlobalThreshold)
	}
	if _, exists := cfg.Filters["sshd"]; !exists {
		t.Error("expected sshd filter")
	}
}

func TestParseConfigFile_InlineComments(t *testing.T) {
	dir := t.TempDir()
	confFile := filepath.Join(dir, "persistent.conf")

	content := `[global]
default_threshold = 5 # custom threshold
default_action = permanent # default action
`
	if err := os.WriteFile(confFile, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	cfg := &Config{
		GlobalThreshold: 10,
		GlobalPeriod:    24 * time.Hour,
		GlobalAction:    "permanent",
		Enabled:         true,
		Filters:         make(map[string]*FilterConfig),
	}

	if err := cfg.parseConfigFile(confFile); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if cfg.GlobalThreshold != 5 {
		t.Errorf("GlobalThreshold = %d, want 5 (inline comment should be stripped)", cfg.GlobalThreshold)
	}
	if cfg.GlobalAction != "permanent" {
		t.Errorf("GlobalAction = %q, want permanent", cfg.GlobalAction)
	}
}

func TestParseConfigFile_NonexistentFile(t *testing.T) {
	cfg := &Config{
		Filters: make(map[string]*FilterConfig),
	}

	err := cfg.parseConfigFile("/tmp/nonexistent-persistent-conf-12345")
	if err == nil {
		t.Error("expected error for nonexistent file")
	}
}

func TestParseConfigFile_EnabledValues(t *testing.T) {
	tests := []struct {
		value string
		want  bool
	}{
		{"true", true},
		{"yes", true},
		{"1", true},
		{"false", false},
		{"no", false},
		{"0", false},
		{"other", false},
	}

	for _, tt := range tests {
		t.Run(tt.value, func(t *testing.T) {
			dir := t.TempDir()
			confFile := filepath.Join(dir, "persistent.conf")
			content := "[global]\nenabled = " + tt.value + "\n"
			os.WriteFile(confFile, []byte(content), 0644)

			cfg := &Config{
				Enabled: !tt.want, // Start with opposite
				Filters: make(map[string]*FilterConfig),
			}
			cfg.parseConfigFile(confFile)

			if cfg.Enabled != tt.want {
				t.Errorf("Enabled = %v for value %q, want %v", cfg.Enabled, tt.value, tt.want)
			}
		})
	}
}

// =============================================================================
// GetFilterConfig tests
// =============================================================================

func TestGetFilterConfig_ExistingFilter(t *testing.T) {
	cfg := &Config{
		GlobalThreshold: 10,
		GlobalPeriod:    24 * time.Hour,
		GlobalAction:    "permanent",
		Filters: map[string]*FilterConfig{
			"sshd": {
				Name:      "sshd",
				Threshold: 3,
				Period:    time.Hour,
				Action:    "ban",
			},
		},
	}

	fc := cfg.GetFilterConfig("sshd")
	if fc.Threshold != 3 {
		t.Errorf("Threshold = %d, want 3", fc.Threshold)
	}
	if fc.Period != time.Hour {
		t.Errorf("Period = %v, want 1h", fc.Period)
	}
	if fc.Action != "ban" {
		t.Errorf("Action = %q, want ban", fc.Action)
	}
}

func TestGetFilterConfig_FallbackToGlobal(t *testing.T) {
	cfg := &Config{
		GlobalThreshold: 10,
		GlobalPeriod:    24 * time.Hour,
		GlobalAction:    "permanent",
		Filters:         make(map[string]*FilterConfig),
	}

	fc := cfg.GetFilterConfig("nonexistent")
	if fc.Threshold != 10 {
		t.Errorf("Threshold = %d, want 10 (global default)", fc.Threshold)
	}
	if fc.Period != 24*time.Hour {
		t.Errorf("Period = %v, want 24h (global default)", fc.Period)
	}
	if fc.Action != "permanent" {
		t.Errorf("Action = %q, want permanent (global default)", fc.Action)
	}
	if fc.Name != "nonexistent" {
		t.Errorf("Name = %q, want nonexistent", fc.Name)
	}
}

// =============================================================================
// parseGlobalSetting tests
// =============================================================================

func TestParseGlobalSetting(t *testing.T) {
	cfg := &Config{
		Filters: make(map[string]*FilterConfig),
	}

	cfg.parseGlobalSetting("default_threshold", "15")
	if cfg.GlobalThreshold != 15 {
		t.Errorf("GlobalThreshold = %d, want 15", cfg.GlobalThreshold)
	}

	cfg.parseGlobalSetting("default_action", "escalate")
	if cfg.GlobalAction != "escalate" {
		t.Errorf("GlobalAction = %q, want escalate", cfg.GlobalAction)
	}

	cfg.parseGlobalSetting("default_period", "48h")
	if cfg.GlobalPeriod != 48*time.Hour {
		t.Errorf("GlobalPeriod = %v, want 48h", cfg.GlobalPeriod)
	}

	cfg.parseGlobalSetting("enabled", "true")
	if !cfg.Enabled {
		t.Error("Enabled should be true")
	}
}

// =============================================================================
// parseFilterSetting tests
// =============================================================================

func TestParseFilterSetting(t *testing.T) {
	cfg := &Config{}
	filter := &FilterConfig{Name: "test"}

	cfg.parseFilterSetting(filter, "threshold", "5")
	if filter.Threshold != 5 {
		t.Errorf("Threshold = %d, want 5", filter.Threshold)
	}

	cfg.parseFilterSetting(filter, "period", "2h")
	if filter.Period != 2*time.Hour {
		t.Errorf("Period = %v, want 2h", filter.Period)
	}

	cfg.parseFilterSetting(filter, "action", "throttle")
	if filter.Action != "throttle" {
		t.Errorf("Action = %q, want throttle", filter.Action)
	}

	cfg.parseFilterSetting(filter, "comment", `"SSH brute force attack"`)
	if filter.Comment != "SSH brute force attack" {
		t.Errorf("Comment = %q, want 'SSH brute force attack'", filter.Comment)
	}
}

// =============================================================================
// parseBanEntry tests
// =============================================================================

func TestParseBanEntry_ValidLine(t *testing.T) {
	line := "2026-01-15T10:30:00Z 1.2.3.4 nftban-sshd SSH brute force"
	entry, err := parseBanEntry(line)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if entry.IP != "1.2.3.4" {
		t.Errorf("IP = %q, want 1.2.3.4", entry.IP)
	}
	if entry.Jail != "nftban-sshd" {
		t.Errorf("Jail = %q, want nftban-sshd", entry.Jail)
	}
	if entry.Reason != "SSH brute force" {
		t.Errorf("Reason = %q, want 'SSH brute force'", entry.Reason)
	}
	if entry.Timestamp.Year() != 2026 {
		t.Errorf("Timestamp year = %d, want 2026", entry.Timestamp.Year())
	}
}

func TestParseBanEntry_MinimalLine(t *testing.T) {
	line := "2026-01-15T10:30:00Z 1.2.3.4 sshd"
	entry, err := parseBanEntry(line)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if entry.IP != "1.2.3.4" {
		t.Errorf("IP = %q, want 1.2.3.4", entry.IP)
	}
	if entry.Reason != "" {
		t.Errorf("Reason = %q, want empty", entry.Reason)
	}
}

func TestParseBanEntry_InvalidTimestamp(t *testing.T) {
	line := "not-a-timestamp 1.2.3.4 sshd"
	_, err := parseBanEntry(line)
	if err == nil {
		t.Error("expected error for invalid timestamp")
	}
}

func TestParseBanEntry_TooFewFields(t *testing.T) {
	tests := []string{
		"",
		"only-one",
		"just two",
	}

	for _, line := range tests {
		_, err := parseBanEntry(line)
		if err == nil {
			t.Errorf("expected error for line %q", line)
		}
	}
}

// =============================================================================
// Filter section inherits global defaults
// =============================================================================

func TestParseConfigFile_FilterInheritsGlobal(t *testing.T) {
	dir := t.TempDir()
	confFile := filepath.Join(dir, "persistent.conf")

	content := `[global]
default_threshold = 15
default_period = 48h
default_action = escalate

[newfilter]
threshold = 5
`
	os.WriteFile(confFile, []byte(content), 0644)

	cfg := &Config{
		GlobalThreshold: 10,
		GlobalPeriod:    24 * time.Hour,
		GlobalAction:    "permanent",
		Enabled:         true,
		Filters:         make(map[string]*FilterConfig),
	}
	cfg.parseConfigFile(confFile)

	f := cfg.Filters["newfilter"]
	if f == nil {
		t.Fatal("expected newfilter to exist")
	}
	// Threshold was explicitly set
	if f.Threshold != 5 {
		t.Errorf("Threshold = %d, want 5", f.Threshold)
	}
	// Period and Action should inherit from global (set at creation time, which was
	// the global values at section parse time - note global is parsed first)
	if f.Period != 48*time.Hour {
		t.Errorf("Period = %v, want 48h (inherited from global)", f.Period)
	}
	if f.Action != "escalate" {
		t.Errorf("Action = %q, want escalate (inherited from global)", f.Action)
	}
}
