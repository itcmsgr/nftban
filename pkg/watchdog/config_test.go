// =============================================================================
// NFTBan - Tests for watchdog configuration loading and validation
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="watchdog_config_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for watchdog configuration loading and validation"
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

package watchdog

import (
	"os"
	"testing"
	"time"
)

// =============================================================================
// Validate
// =============================================================================

func TestValidate_MinimumIntervals(t *testing.T) {
	cfg := &Config{
		BaseInterval:       100 * time.Millisecond,
		ProcessInterval:    100 * time.Millisecond,
		SystemInterval:     100 * time.Millisecond,
		KernelInterval:     100 * time.Millisecond,
		NFTSetInterval:     100 * time.Millisecond,
		NFTRulesetInterval: time.Second, // below 5s minimum
		RecorderMaxEvents:  500,
		RecorderRetentionDays: 3,
		ProfileMaxCount:    5,
	}

	cfg.Validate()

	if cfg.BaseInterval < time.Second {
		t.Errorf("BaseInterval = %v, want >= 1s", cfg.BaseInterval)
	}
	if cfg.ProcessInterval < time.Second {
		t.Errorf("ProcessInterval = %v, want >= 1s", cfg.ProcessInterval)
	}
	if cfg.SystemInterval < time.Second {
		t.Errorf("SystemInterval = %v, want >= 1s", cfg.SystemInterval)
	}
	if cfg.KernelInterval < time.Second {
		t.Errorf("KernelInterval = %v, want >= 1s", cfg.KernelInterval)
	}
	if cfg.NFTSetInterval < time.Second {
		t.Errorf("NFTSetInterval = %v, want >= 1s", cfg.NFTSetInterval)
	}
	if cfg.NFTRulesetInterval < 5*time.Second {
		t.Errorf("NFTRulesetInterval = %v, want >= 5s", cfg.NFTRulesetInterval)
	}
}

func TestValidate_HysteresisCorrection(t *testing.T) {
	cfg := &Config{
		HysteresisWarnEnter:  60,
		HysteresisWarnExit:   70, // Invalid: exit >= enter
		HysteresisCritEnter:  80,
		HysteresisCritExit:   90, // Invalid: exit >= enter
		BaseInterval:         5 * time.Second,
		ProcessInterval:      5 * time.Second,
		SystemInterval:       5 * time.Second,
		KernelInterval:       5 * time.Second,
		NFTSetInterval:       10 * time.Second,
		NFTRulesetInterval:   30 * time.Second,
		RecorderMaxEvents:    500,
		RecorderRetentionDays: 3,
		ProfileMaxCount:      5,
	}

	cfg.Validate()

	if cfg.HysteresisWarnExit >= cfg.HysteresisWarnEnter {
		t.Errorf("WarnExit (%f) should be < WarnEnter (%f)", cfg.HysteresisWarnExit, cfg.HysteresisWarnEnter)
	}
	if cfg.HysteresisCritExit >= cfg.HysteresisCritEnter {
		t.Errorf("CritExit (%f) should be < CritEnter (%f)", cfg.HysteresisCritExit, cfg.HysteresisCritEnter)
	}
}

func TestValidate_MinimumCooldowns(t *testing.T) {
	cfg := &Config{
		ProfileCPUCooldown:   10 * time.Second, // below 1 minute minimum
		ProfileHeapCooldown:  10 * time.Second, // below 1 minute minimum
		FreeOSMemoryCooldown: time.Minute,      // below 5 minute minimum
		BaseInterval:         5 * time.Second,
		ProcessInterval:      5 * time.Second,
		SystemInterval:       5 * time.Second,
		KernelInterval:       5 * time.Second,
		NFTSetInterval:       10 * time.Second,
		NFTRulesetInterval:   30 * time.Second,
		RecorderMaxEvents:    500,
		RecorderRetentionDays: 3,
		ProfileMaxCount:      5,
	}

	cfg.Validate()

	if cfg.ProfileCPUCooldown < time.Minute {
		t.Errorf("ProfileCPUCooldown = %v, want >= 1m", cfg.ProfileCPUCooldown)
	}
	if cfg.ProfileHeapCooldown < time.Minute {
		t.Errorf("ProfileHeapCooldown = %v, want >= 1m", cfg.ProfileHeapCooldown)
	}
	if cfg.FreeOSMemoryCooldown < 5*time.Minute {
		t.Errorf("FreeOSMemoryCooldown = %v, want >= 5m", cfg.FreeOSMemoryCooldown)
	}
}

func TestValidate_DegradedIntervalMultiplier(t *testing.T) {
	tests := []struct {
		name      string
		input     float64
		wantMin   float64
		wantMax   float64
	}{
		{"below minimum", 0.5, 1.0, 1.0},
		{"above maximum", 15.0, 10.0, 10.0},
		{"in range", 3.0, 3.0, 3.0},
		{"at minimum", 1.0, 1.0, 1.0},
		{"at maximum", 10.0, 10.0, 10.0},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cfg := &Config{
				DegradedIntervalMultiplier: tc.input,
				BaseInterval:               5 * time.Second,
				ProcessInterval:            5 * time.Second,
				SystemInterval:             5 * time.Second,
				KernelInterval:             5 * time.Second,
				NFTSetInterval:             10 * time.Second,
				NFTRulesetInterval:         30 * time.Second,
				RecorderMaxEvents:          500,
				RecorderRetentionDays:      3,
				ProfileMaxCount:            5,
			}
			cfg.Validate()

			if cfg.DegradedIntervalMultiplier < tc.wantMin || cfg.DegradedIntervalMultiplier > tc.wantMax {
				t.Errorf("DegradedIntervalMultiplier = %f, want [%f, %f]",
					cfg.DegradedIntervalMultiplier, tc.wantMin, tc.wantMax)
			}
		})
	}
}

func TestValidate_ProfileMaxCount(t *testing.T) {
	tests := []struct {
		name  string
		input int
		want  int
	}{
		{"below minimum", 0, 1},
		{"above maximum", 200, 100},
		{"in range", 50, 50},
		{"at minimum", 1, 1},
		{"at maximum", 100, 100},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cfg := &Config{
				ProfileMaxCount:       tc.input,
				BaseInterval:          5 * time.Second,
				ProcessInterval:       5 * time.Second,
				SystemInterval:        5 * time.Second,
				KernelInterval:        5 * time.Second,
				NFTSetInterval:        10 * time.Second,
				NFTRulesetInterval:    30 * time.Second,
				RecorderMaxEvents:     500,
				RecorderRetentionDays: 3,
			}
			cfg.Validate()

			if cfg.ProfileMaxCount != tc.want {
				t.Errorf("ProfileMaxCount = %d, want %d", cfg.ProfileMaxCount, tc.want)
			}
		})
	}
}

func TestValidate_RecorderMaxEvents(t *testing.T) {
	tests := []struct {
		name  string
		input int
		want  int
	}{
		{"below minimum", 50, 100},
		{"above maximum", 20000, 10000},
		{"in range", 500, 500},
		{"at minimum", 100, 100},
		{"at maximum", 10000, 10000},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cfg := &Config{
				RecorderMaxEvents:     tc.input,
				RecorderRetentionDays: 3,
				ProfileMaxCount:       5,
				BaseInterval:          5 * time.Second,
				ProcessInterval:       5 * time.Second,
				SystemInterval:        5 * time.Second,
				KernelInterval:        5 * time.Second,
				NFTSetInterval:        10 * time.Second,
				NFTRulesetInterval:    30 * time.Second,
			}
			cfg.Validate()

			if cfg.RecorderMaxEvents != tc.want {
				t.Errorf("RecorderMaxEvents = %d, want %d", cfg.RecorderMaxEvents, tc.want)
			}
		})
	}
}

func TestValidate_RecorderRetentionDays(t *testing.T) {
	cfg := &Config{
		RecorderRetentionDays: 0,
		RecorderMaxEvents:     500,
		ProfileMaxCount:       5,
		BaseInterval:          5 * time.Second,
		ProcessInterval:       5 * time.Second,
		SystemInterval:        5 * time.Second,
		KernelInterval:        5 * time.Second,
		NFTSetInterval:        10 * time.Second,
		NFTRulesetInterval:    30 * time.Second,
	}
	cfg.Validate()

	if cfg.RecorderRetentionDays < 1 {
		t.Errorf("RecorderRetentionDays = %d, want >= 1", cfg.RecorderRetentionDays)
	}
}

// =============================================================================
// GetIntervalForMode
// =============================================================================

func TestGetIntervalForMode(t *testing.T) {
	cfg := &Config{
		DegradedIntervalMultiplier: 2.0,
		BaseInterval:               5 * time.Second,
		ProcessInterval:            5 * time.Second,
		SystemInterval:             5 * time.Second,
		KernelInterval:             5 * time.Second,
		NFTSetInterval:             10 * time.Second,
		NFTRulesetInterval:         30 * time.Second,
		RecorderMaxEvents:          500,
		RecorderRetentionDays:      3,
		ProfileMaxCount:            5,
	}

	base := 5 * time.Second

	tests := []struct {
		name string
		mode Mode
		want time.Duration
	}{
		{"normal mode", ModeNormal, 5 * time.Second},
		{"degraded mode", ModeDegraded, 10 * time.Second},
		{"survival mode", ModeSurvival, 5 * time.Second},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := cfg.GetIntervalForMode(base, tc.mode)
			if got != tc.want {
				t.Errorf("GetIntervalForMode(%v, %q) = %v, want %v", base, tc.mode, got, tc.want)
			}
		})
	}
}

func TestGetIntervalForMode_DifferentMultipliers(t *testing.T) {
	base := 10 * time.Second

	tests := []struct {
		name       string
		multiplier float64
		want       time.Duration
	}{
		{"1x", 1.0, 10 * time.Second},
		{"2x", 2.0, 20 * time.Second},
		{"3x", 3.0, 30 * time.Second},
		{"5x", 5.0, 50 * time.Second},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cfg := &Config{
				DegradedIntervalMultiplier: tc.multiplier,
			}
			got := cfg.GetIntervalForMode(base, ModeDegraded)
			if got != tc.want {
				t.Errorf("GetIntervalForMode with multiplier %f = %v, want %v",
					tc.multiplier, got, tc.want)
			}
		})
	}
}

// =============================================================================
// DefaultConfig
// =============================================================================

func TestDefaultConfig_HasReasonableValues(t *testing.T) {
	cfg := DefaultConfig()

	if !cfg.Enabled {
		t.Error("Enabled should be true by default")
	}
	if cfg.BaseInterval != 5*time.Second {
		t.Errorf("BaseInterval = %v, want 5s", cfg.BaseInterval)
	}
	if cfg.HysteresisWarnEnter != 60 {
		t.Errorf("HysteresisWarnEnter = %f, want 60", cfg.HysteresisWarnEnter)
	}
	if cfg.HysteresisWarnExit != 50 {
		t.Errorf("HysteresisWarnExit = %f, want 50", cfg.HysteresisWarnExit)
	}
	if cfg.HysteresisCritEnter != 80 {
		t.Errorf("HysteresisCritEnter = %f, want 80", cfg.HysteresisCritEnter)
	}
	if cfg.HysteresisCritExit != 70 {
		t.Errorf("HysteresisCritExit = %f, want 70", cfg.HysteresisCritExit)
	}

	// Hysteresis invariants
	if cfg.HysteresisWarnExit >= cfg.HysteresisWarnEnter {
		t.Error("WarnExit should be < WarnEnter")
	}
	if cfg.HysteresisCritExit >= cfg.HysteresisCritEnter {
		t.Error("CritExit should be < CritEnter")
	}
	if cfg.HysteresisWarnEnter >= cfg.HysteresisCritEnter {
		t.Error("WarnEnter should be < CritEnter")
	}

	// Memory budget should be positive
	if cfg.MemBudgetBytes <= 0 {
		t.Errorf("MemBudgetBytes = %d, want > 0", cfg.MemBudgetBytes)
	}

	// Intervals should be positive
	if cfg.ProcessInterval <= 0 {
		t.Error("ProcessInterval should be positive")
	}
	if cfg.SystemInterval <= 0 {
		t.Error("SystemInterval should be positive")
	}
	if cfg.KernelInterval <= 0 {
		t.Error("KernelInterval should be positive")
	}

	// Thresholds should be positive
	if cfg.CPUCritPercent <= 0 {
		t.Error("CPUCritPercent should be positive")
	}
	if cfg.RSSCritPercentOfBudget <= 0 {
		t.Error("RSSCritPercentOfBudget should be positive")
	}
	if cfg.IOWaitCritPercent <= 0 {
		t.Error("IOWaitCritPercent should be positive")
	}
	if cfg.DiskUseCritPercent <= 0 {
		t.Error("DiskUseCritPercent should be positive")
	}
	if cfg.ConntrackUtilCrit <= 0 {
		t.Error("ConntrackUtilCrit should be positive")
	}
}

func TestDefaultConfig_PassesValidation(t *testing.T) {
	cfg := DefaultConfig()

	// Store original values
	origBase := cfg.BaseInterval
	origProcess := cfg.ProcessInterval
	origMultiplier := cfg.DegradedIntervalMultiplier
	origMaxEvents := cfg.RecorderMaxEvents
	origProfileMax := cfg.ProfileMaxCount

	cfg.Validate()

	// Values should not change after validation (already valid)
	if cfg.BaseInterval != origBase {
		t.Errorf("BaseInterval changed from %v to %v", origBase, cfg.BaseInterval)
	}
	if cfg.ProcessInterval != origProcess {
		t.Errorf("ProcessInterval changed from %v to %v", origProcess, cfg.ProcessInterval)
	}
	if cfg.DegradedIntervalMultiplier != origMultiplier {
		t.Errorf("DegradedIntervalMultiplier changed from %f to %f", origMultiplier, cfg.DegradedIntervalMultiplier)
	}
	if cfg.RecorderMaxEvents != origMaxEvents {
		t.Errorf("RecorderMaxEvents changed from %d to %d", origMaxEvents, cfg.RecorderMaxEvents)
	}
	if cfg.ProfileMaxCount != origProfileMax {
		t.Errorf("ProfileMaxCount changed from %d to %d", origProfileMax, cfg.ProfileMaxCount)
	}
}

// =============================================================================
// Config Loader (applyConfigValues)
// =============================================================================

func TestApplyConfigValues_BooleanFields(t *testing.T) {
	cfg := DefaultConfig()
	values := map[string]string{
		"NFTBAN_DYNAMIC_WATCHDOG_ENABLED": "false",
		"NFTBAN_PROFILE_AUTO_ENABLED":     "false",
		"NFTBAN_FREE_OS_MEMORY_ENABLED":   "false",
		"NFTBAN_RECORDER_ENABLED":         "false",
	}

	applyConfigValues(cfg, values)

	if cfg.Enabled {
		t.Error("Enabled should be false")
	}
	if cfg.ProfileAutoEnabled {
		t.Error("ProfileAutoEnabled should be false")
	}
	if cfg.FreeOSMemoryEnabled {
		t.Error("FreeOSMemoryEnabled should be false")
	}
	if cfg.RecorderEnabled {
		t.Error("RecorderEnabled should be false")
	}
}

func TestApplyConfigValues_Intervals(t *testing.T) {
	cfg := DefaultConfig()
	values := map[string]string{
		"NFTBAN_DYNAMIC_WATCHDOG_INTERVAL": "10",
	}

	applyConfigValues(cfg, values)

	if cfg.BaseInterval != 10*time.Second {
		t.Errorf("BaseInterval = %v, want 10s", cfg.BaseInterval)
	}
}

func TestApplyConfigValues_Thresholds(t *testing.T) {
	cfg := DefaultConfig()
	values := map[string]string{
		"NFTBAN_PRESSURE_WARN_ENTER":  "70",
		"NFTBAN_PRESSURE_WARN_EXIT":   "55",
		"NFTBAN_PRESSURE_CRIT_ENTER":  "90",
		"NFTBAN_PRESSURE_CRIT_EXIT":   "75",
		"NFTBAN_CPU_CRIT_PERCENT":     "90",
		"NFTBAN_IOWAIT_CRIT_PERCENT":  "50",
		"NFTBAN_DISK_CRIT_PERCENT":    "98",
		"NFTBAN_CONNTRACK_UTIL_CRIT":  "0.95",
		"NFTBAN_GOROUTINES_CRIT":      "5000",
		"NFTBAN_MEM_BUDGET_BYTES":     "1073741824",
	}

	applyConfigValues(cfg, values)

	if cfg.HysteresisWarnEnter != 70 {
		t.Errorf("HysteresisWarnEnter = %f, want 70", cfg.HysteresisWarnEnter)
	}
	if cfg.HysteresisWarnExit != 55 {
		t.Errorf("HysteresisWarnExit = %f, want 55", cfg.HysteresisWarnExit)
	}
	if cfg.HysteresisCritEnter != 90 {
		t.Errorf("HysteresisCritEnter = %f, want 90", cfg.HysteresisCritEnter)
	}
	if cfg.HysteresisCritExit != 75 {
		t.Errorf("HysteresisCritExit = %f, want 75", cfg.HysteresisCritExit)
	}
	if cfg.CPUCritPercent != 90 {
		t.Errorf("CPUCritPercent = %f, want 90", cfg.CPUCritPercent)
	}
	if cfg.IOWaitCritPercent != 50 {
		t.Errorf("IOWaitCritPercent = %f, want 50", cfg.IOWaitCritPercent)
	}
	if cfg.DiskUseCritPercent != 98 {
		t.Errorf("DiskUseCritPercent = %f, want 98", cfg.DiskUseCritPercent)
	}
	if cfg.ConntrackUtilCrit != 0.95 {
		t.Errorf("ConntrackUtilCrit = %f, want 0.95", cfg.ConntrackUtilCrit)
	}
	if cfg.GoroutinesCrit != 5000 {
		t.Errorf("GoroutinesCrit = %d, want 5000", cfg.GoroutinesCrit)
	}
	if cfg.MemBudgetBytes != 1073741824 {
		t.Errorf("MemBudgetBytes = %d, want 1073741824", cfg.MemBudgetBytes)
	}
}

func TestApplyConfigValues_Profiling(t *testing.T) {
	cfg := DefaultConfig()
	values := map[string]string{
		"NFTBAN_WATCHDOG_PROFILE_DIR":        "/tmp/profiles",
		"NFTBAN_PROFILE_CPU_COOLDOWN":        "300",
		"NFTBAN_PROFILE_HEAP_COOLDOWN":       "600",
		"NFTBAN_PROFILE_GOROUTINE_COOLDOWN":  "120",
		"NFTBAN_PROFILE_CPU_DURATION":        "60",
		"NFTBAN_WATCHDOG_PROFILE_MAX_COUNT":  "20",
	}

	applyConfigValues(cfg, values)

	if cfg.ProfileDir != "/tmp/profiles" {
		t.Errorf("ProfileDir = %q, want /tmp/profiles", cfg.ProfileDir)
	}
	if cfg.ProfileCPUCooldown != 300*time.Second {
		t.Errorf("ProfileCPUCooldown = %v, want 300s", cfg.ProfileCPUCooldown)
	}
	if cfg.ProfileHeapCooldown != 600*time.Second {
		t.Errorf("ProfileHeapCooldown = %v, want 600s", cfg.ProfileHeapCooldown)
	}
	if cfg.ProfileGoroutineCooldown != 120*time.Second {
		t.Errorf("ProfileGoroutineCooldown = %v, want 120s", cfg.ProfileGoroutineCooldown)
	}
	if cfg.ProfileCPUDuration != 60*time.Second {
		t.Errorf("ProfileCPUDuration = %v, want 60s", cfg.ProfileCPUDuration)
	}
	if cfg.ProfileMaxCount != 20 {
		t.Errorf("ProfileMaxCount = %d, want 20", cfg.ProfileMaxCount)
	}
}

func TestApplyConfigValues_Degradation(t *testing.T) {
	cfg := DefaultConfig()
	values := map[string]string{
		"NFTBAN_DEGRADE_REDUCE_WORKERS_TO":    "3",
		"NFTBAN_SURVIVAL_REDUCE_WORKERS_TO":   "1",
		"NFTBAN_DEGRADED_INTERVAL_MULTIPLIER": "3.0",
	}

	applyConfigValues(cfg, values)

	if cfg.DegradeReduceWorkersTo != 3 {
		t.Errorf("DegradeReduceWorkersTo = %d, want 3", cfg.DegradeReduceWorkersTo)
	}
	if cfg.SurvivalReduceWorkersTo != 1 {
		t.Errorf("SurvivalReduceWorkersTo = %d, want 1", cfg.SurvivalReduceWorkersTo)
	}
	if cfg.DegradedIntervalMultiplier != 3.0 {
		t.Errorf("DegradedIntervalMultiplier = %f, want 3.0", cfg.DegradedIntervalMultiplier)
	}
}

func TestApplyConfigValues_Recorder(t *testing.T) {
	cfg := DefaultConfig()
	values := map[string]string{
		"NFTBAN_RECORDER_DIR":               "/tmp/recorder",
		"NFTBAN_RECORDER_MAX_EVENTS":        "2000",
		"NFTBAN_RECORDER_SNAPSHOT_INTERVAL": "120",
		"NFTBAN_RECORDER_RETENTION_DAYS":    "14",
	}

	applyConfigValues(cfg, values)

	if cfg.RecorderDir != "/tmp/recorder" {
		t.Errorf("RecorderDir = %q, want /tmp/recorder", cfg.RecorderDir)
	}
	if cfg.RecorderMaxEvents != 2000 {
		t.Errorf("RecorderMaxEvents = %d, want 2000", cfg.RecorderMaxEvents)
	}
	if cfg.RecorderSnapshotInterval != 120*time.Second {
		t.Errorf("RecorderSnapshotInterval = %v, want 120s", cfg.RecorderSnapshotInterval)
	}
	if cfg.RecorderRetentionDays != 14 {
		t.Errorf("RecorderRetentionDays = %d, want 14", cfg.RecorderRetentionDays)
	}
}

func TestApplyConfigValues_EmptyMap(t *testing.T) {
	cfg := DefaultConfig()
	origEnabled := cfg.Enabled
	origInterval := cfg.BaseInterval

	applyConfigValues(cfg, map[string]string{})

	if cfg.Enabled != origEnabled {
		t.Error("empty values should not change Enabled")
	}
	if cfg.BaseInterval != origInterval {
		t.Error("empty values should not change BaseInterval")
	}
}

func TestApplyConfigValues_InvalidValues(t *testing.T) {
	cfg := DefaultConfig()
	origInterval := cfg.BaseInterval

	values := map[string]string{
		"NFTBAN_DYNAMIC_WATCHDOG_INTERVAL": "not_a_number",
		"NFTBAN_GOROUTINES_CRIT":          "invalid",
	}

	applyConfigValues(cfg, values)

	// Invalid values should be ignored
	if cfg.BaseInterval != origInterval {
		t.Errorf("invalid interval should be ignored, got %v", cfg.BaseInterval)
	}
}

// =============================================================================
// loadConfigFile
// =============================================================================

func TestLoadConfigFile_ValidFile(t *testing.T) {
	tmpDir := t.TempDir()
	cfgFile := tmpDir + "/test.conf"

	content := `# Comment
NFTBAN_DYNAMIC_WATCHDOG_ENABLED="true"
NFTBAN_DYNAMIC_WATCHDOG_INTERVAL=10
NFTBAN_PRESSURE_WARN_ENTER = 65
EMPTY_VALUE=

# Another comment
QUOTED_VALUE="hello world"
SINGLE_QUOTED='test'
`
	if err := os.WriteFile(cfgFile, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	values, err := loadConfigFile(cfgFile)
	if err != nil {
		t.Fatalf("loadConfigFile() error = %v", err)
	}

	if values["NFTBAN_DYNAMIC_WATCHDOG_ENABLED"] != "true" {
		t.Errorf("ENABLED = %q, want %q", values["NFTBAN_DYNAMIC_WATCHDOG_ENABLED"], "true")
	}
	if values["NFTBAN_DYNAMIC_WATCHDOG_INTERVAL"] != "10" {
		t.Errorf("INTERVAL = %q, want %q", values["NFTBAN_DYNAMIC_WATCHDOG_INTERVAL"], "10")
	}
	if values["NFTBAN_PRESSURE_WARN_ENTER"] != "65" {
		t.Errorf("WARN_ENTER = %q, want %q", values["NFTBAN_PRESSURE_WARN_ENTER"], "65")
	}
	if values["QUOTED_VALUE"] != "hello world" {
		t.Errorf("QUOTED_VALUE = %q, want %q", values["QUOTED_VALUE"], "hello world")
	}
	if values["SINGLE_QUOTED"] != "test" {
		t.Errorf("SINGLE_QUOTED = %q, want %q", values["SINGLE_QUOTED"], "test")
	}
}

func TestLoadConfigFile_NonexistentFile(t *testing.T) {
	_, err := loadConfigFile("/nonexistent/path/config.conf")
	if err == nil {
		t.Error("expected error for nonexistent file")
	}
}

func TestLoadConfigFile_SkipsInvalidLines(t *testing.T) {
	tmpDir := t.TempDir()
	cfgFile := tmpDir + "/test.conf"

	content := `VALID_KEY=valid_value
no_equals_sign_here
=no_key
KEY_ONLY
ANOTHER_VALID=42
`
	if err := os.WriteFile(cfgFile, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	values, err := loadConfigFile(cfgFile)
	if err != nil {
		t.Fatalf("loadConfigFile() error = %v", err)
	}

	if values["VALID_KEY"] != "valid_value" {
		t.Errorf("VALID_KEY = %q, want %q", values["VALID_KEY"], "valid_value")
	}
	if values["ANOTHER_VALID"] != "42" {
		t.Errorf("ANOTHER_VALID = %q, want %q", values["ANOTHER_VALID"], "42")
	}
	// Lines without = should be skipped, not cause errors
	if _, ok := values["KEY_ONLY"]; ok {
		t.Error("KEY_ONLY should not be in values (no = sign)")
	}
}

func TestLoadConfigFile_EmptyFile(t *testing.T) {
	tmpDir := t.TempDir()
	cfgFile := tmpDir + "/empty.conf"

	if err := os.WriteFile(cfgFile, []byte(""), 0644); err != nil {
		t.Fatal(err)
	}

	values, err := loadConfigFile(cfgFile)
	if err != nil {
		t.Fatalf("loadConfigFile() error = %v", err)
	}
	if len(values) != 0 {
		t.Errorf("empty file should produce empty map, got %d entries", len(values))
	}
}

func TestLoadConfigFile_CommentsOnly(t *testing.T) {
	tmpDir := t.TempDir()
	cfgFile := tmpDir + "/comments.conf"

	content := `# This is a comment
# Another comment
# KEY=value
`
	if err := os.WriteFile(cfgFile, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	values, err := loadConfigFile(cfgFile)
	if err != nil {
		t.Fatalf("loadConfigFile() error = %v", err)
	}
	if len(values) != 0 {
		t.Errorf("comments-only file should produce empty map, got %d entries", len(values))
	}
}

// =============================================================================
// LoadConfig (integration-style with temp files)
// =============================================================================

func TestLoadConfig_DefaultsWhenNoFile(t *testing.T) {
	cfg := LoadConfig("/nonexistent/path/watchdog.conf")

	// Should still return a valid config with defaults
	if cfg == nil {
		t.Fatal("LoadConfig() returned nil")
	}
	if !cfg.Enabled {
		t.Error("default Enabled should be true")
	}
}

func TestLoadConfig_OverrideChain(t *testing.T) {
	tmpDir := t.TempDir()

	// Create directory structure: tmpDir/conf.d/watchdog.conf
	confDir := tmpDir + "/conf.d"
	os.MkdirAll(confDir, 0755)

	// Base config
	baseContent := `NFTBAN_DYNAMIC_WATCHDOG_INTERVAL=5
NFTBAN_PRESSURE_WARN_ENTER=60
`
	os.WriteFile(confDir+"/watchdog.conf", []byte(baseContent), 0644)

	// Local override
	localContent := `NFTBAN_PRESSURE_WARN_ENTER=70
`
	os.WriteFile(confDir+"/watchdog.conf.local", []byte(localContent), 0644)

	cfg := LoadConfig(confDir + "/watchdog.conf")

	// Interval from base
	if cfg.BaseInterval != 5*time.Second {
		t.Errorf("BaseInterval = %v, want 5s (from base)", cfg.BaseInterval)
	}

	// WarnEnter from local override
	if cfg.HysteresisWarnEnter != 70 {
		t.Errorf("HysteresisWarnEnter = %f, want 70 (from local override)", cfg.HysteresisWarnEnter)
	}
}

func TestLoadConfig_EmptyPathUsesDefault(t *testing.T) {
	// With empty path, it tries /etc/nftban/conf.d/watchdog.conf
	// which won't exist in test env, so should return defaults
	cfg := LoadConfig("")

	if cfg == nil {
		t.Fatal("LoadConfig('') returned nil")
	}
}
