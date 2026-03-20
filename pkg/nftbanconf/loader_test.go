// =============================================================================
// NFTBan - Tests for nftban configuration loading
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftbanconf_loader_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for nftban configuration loading"
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

package nftbanconf

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// resetGlobals resets the package-level singleton state for test isolation.
// This must be called at the start of each test that uses Load().
func resetGlobals() {
	loadOnce = sync.Once{}
	globalConfig = nil
	globalPaths = nil
	globalTimeouts = nil
	globalNFT = nil
}

// =============================================================================
// defaultConfig tests
// =============================================================================

func TestDefaultConfig(t *testing.T) {
	cfg := defaultConfig()

	if cfg == nil {
		t.Fatal("defaultConfig() returned nil")
	}

	// Check default paths
	if cfg.Bin != "/usr/sbin/nftban" {
		t.Errorf("Bin = %q, want /usr/sbin/nftban", cfg.Bin)
	}
	if cfg.CoreBin != "/usr/lib/nftban/bin/nftban-core" {
		t.Errorf("CoreBin = %q, want /usr/lib/nftban/bin/nftban-core", cfg.CoreBin)
	}
	if cfg.LibDir != "/usr/lib/nftban" {
		t.Errorf("LibDir = %q, want /usr/lib/nftban", cfg.LibDir)
	}
	if cfg.ConfigDir != "/etc/nftban" {
		t.Errorf("ConfigDir = %q, want /etc/nftban", cfg.ConfigDir)
	}
	if cfg.DataDir != "/var/lib/nftban" {
		t.Errorf("DataDir = %q, want /var/lib/nftban", cfg.DataDir)
	}
	if cfg.LogDir != "/var/log/nftban" {
		t.Errorf("LogDir = %q, want /var/log/nftban", cfg.LogDir)
	}
	if cfg.CacheDir != "/var/cache/nftban" {
		t.Errorf("CacheDir = %q, want /var/cache/nftban", cfg.CacheDir)
	}
	if cfg.RunDir != "/run/nftban" {
		t.Errorf("RunDir = %q, want /run/nftban", cfg.RunDir)
	}

	// Check defaults are safe (features off)
	if cfg.MetricsEnabled {
		t.Error("MetricsEnabled should default to false")
	}
	if cfg.GeoIPEnabled {
		t.Error("GeoIPEnabled should default to false")
	}
	if cfg.FeedsEnabled {
		t.Error("FeedsEnabled should default to false")
	}
	if cfg.SuricataEnabled {
		t.Error("SuricataEnabled should default to false")
	}
	if cfg.GUIEnabled {
		t.Error("GUIEnabled should default to false")
	}
	if cfg.PortscanEnabled {
		t.Error("PortscanEnabled should default to false")
	}
	if cfg.DDoSEnabled {
		t.Error("DDoSEnabled should default to false")
	}
	if cfg.LoginMonitorEnabled {
		t.Error("LoginMonitorEnabled should default to false")
	}

	// Check safe defaults for logging
	if cfg.LogLevel != "INFO" {
		t.Errorf("LogLevel = %q, want INFO", cfg.LogLevel)
	}
	if !cfg.ColorOutput {
		t.Error("ColorOutput should default to true")
	}
	if cfg.DebugTrace {
		t.Error("DebugTrace should default to false")
	}

	// Check version defaults
	if cfg.ConfigVersion != "2" {
		t.Errorf("ConfigVersion = %q, want 2", cfg.ConfigVersion)
	}
}

// =============================================================================
// loadFromFile tests
// =============================================================================

func TestLoadFromFile_NonexistentFile(t *testing.T) {
	cfg, err := loadFromFile("/tmp/nonexistent-nftban-conf-12345")
	if err != nil {
		t.Fatalf("expected defaults for nonexistent file, got error: %v", err)
	}
	if cfg == nil {
		t.Fatal("expected non-nil config with defaults")
	}
	// Should have default values
	if cfg.Bin != "/usr/sbin/nftban" {
		t.Errorf("expected default Bin, got %q", cfg.Bin)
	}
}

func TestLoadFromFile_ValidConfig(t *testing.T) {
	dir := t.TempDir()
	confFile := filepath.Join(dir, "nftban.conf")

	content := `# NFTBan Configuration
NFTBAN_VERSION="1.25.0"
NFTBAN_CONFIG_VERSION="2"
NFTBAN_BIN="/custom/bin/nftban"
NFTBAN_CORE_BIN="/custom/bin/nftban-core"
NFTBAN_LIB_DIR="/custom/lib"
NFTBAN_CONFIG_DIR="/custom/etc"
NFTBAN_DATA_DIR="/custom/data"
NFTBAN_LOG_DIR="/custom/log"
NFTBAN_CACHE_DIR="/custom/cache"
NFTBAN_RUN_DIR="/custom/run"
NFTBAN_METRICS_ENABLED="true"
NFTBAN_GEOIP_ENABLED="yes"
NFTBAN_FEEDS_ENABLED="1"
NFTBAN_LOG_LEVEL="DEBUG"
NFTBAN_SURICATA_BAN_THRESHOLD="200"
NFTBAN_METRICS_SAMPLING_INTERVAL="30"
NFTBAN_API_ADDR=":9090"
`
	if err := os.WriteFile(confFile, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	cfg, err := loadFromFile(confFile)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Verify parsed values
	if cfg.Version != "1.25.0" {
		t.Errorf("Version = %q, want 1.25.0", cfg.Version)
	}
	if cfg.Bin != "/custom/bin/nftban" {
		t.Errorf("Bin = %q, want /custom/bin/nftban", cfg.Bin)
	}
	if cfg.CoreBin != "/custom/bin/nftban-core" {
		t.Errorf("CoreBin = %q, want /custom/bin/nftban-core", cfg.CoreBin)
	}
	if cfg.LibDir != "/custom/lib" {
		t.Errorf("LibDir = %q, want /custom/lib", cfg.LibDir)
	}
	if cfg.ConfigDir != "/custom/etc" {
		t.Errorf("ConfigDir = %q, want /custom/etc", cfg.ConfigDir)
	}
	if cfg.DataDir != "/custom/data" {
		t.Errorf("DataDir = %q, want /custom/data", cfg.DataDir)
	}
	if cfg.LogDir != "/custom/log" {
		t.Errorf("LogDir = %q, want /custom/log", cfg.LogDir)
	}
	if cfg.CacheDir != "/custom/cache" {
		t.Errorf("CacheDir = %q, want /custom/cache", cfg.CacheDir)
	}
	if cfg.RunDir != "/custom/run" {
		t.Errorf("RunDir = %q, want /custom/run", cfg.RunDir)
	}
	if !cfg.MetricsEnabled {
		t.Error("MetricsEnabled should be true")
	}
	if !cfg.GeoIPEnabled {
		t.Error("GeoIPEnabled should be true (parsed 'yes')")
	}
	if !cfg.FeedsEnabled {
		t.Error("FeedsEnabled should be true (parsed '1')")
	}
	if cfg.LogLevel != "DEBUG" {
		t.Errorf("LogLevel = %q, want DEBUG", cfg.LogLevel)
	}
	if cfg.SuricataBanThreshold != 200 {
		t.Errorf("SuricataBanThreshold = %d, want 200", cfg.SuricataBanThreshold)
	}
	if cfg.MetricsSamplingInterval != 30 {
		t.Errorf("MetricsSamplingInterval = %d, want 30", cfg.MetricsSamplingInterval)
	}
	if cfg.APIAddr != ":9090" {
		t.Errorf("APIAddr = %q, want :9090", cfg.APIAddr)
	}
}

func TestLoadFromFile_CommentsAndSkips(t *testing.T) {
	dir := t.TempDir()
	confFile := filepath.Join(dir, "nftban.conf")

	content := `# Full line comment
# Another comment

NFTBAN_VERSION="1.0.0"

# Skip bash-specific
[[ something ]]
_NFTBAN_INTERNAL="skip"

# Line with no = sign
INVALID LINE WITHOUT EQUALS

NFTBAN_LOG_LEVEL="WARN"
`
	if err := os.WriteFile(confFile, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	cfg, err := loadFromFile(confFile)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if cfg.Version != "1.0.0" {
		t.Errorf("Version = %q, want 1.0.0", cfg.Version)
	}
	if cfg.LogLevel != "WARN" {
		t.Errorf("LogLevel = %q, want WARN", cfg.LogLevel)
	}
}

func TestLoadFromFile_QuoteStripping(t *testing.T) {
	dir := t.TempDir()
	confFile := filepath.Join(dir, "nftban.conf")

	content := `NFTBAN_VERSION="1.0.0"
NFTBAN_LOG_LEVEL='DEBUG'
NFTBAN_BIN=/no/quotes
`
	if err := os.WriteFile(confFile, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	cfg, err := loadFromFile(confFile)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Double quotes stripped
	if cfg.Version != "1.0.0" {
		t.Errorf("Version = %q, want 1.0.0 (double quotes stripped)", cfg.Version)
	}
	// Single quotes stripped
	if cfg.LogLevel != "DEBUG" {
		t.Errorf("LogLevel = %q, want DEBUG (single quotes stripped)", cfg.LogLevel)
	}
	// No quotes, value as-is
	if cfg.Bin != "/no/quotes" {
		t.Errorf("Bin = %q, want /no/quotes", cfg.Bin)
	}
}

// =============================================================================
// overlayFromFile tests
// =============================================================================

func TestOverlayFromFile(t *testing.T) {
	dir := t.TempDir()

	// Start with defaults
	cfg := defaultConfig()

	// Create overlay file that changes some values
	overlayFile := filepath.Join(dir, "nftban.conf.local")
	content := `NFTBAN_LOG_LEVEL="DEBUG"
NFTBAN_METRICS_ENABLED="true"
NFTBAN_API_ADDR=":9999"
`
	if err := os.WriteFile(overlayFile, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	overlayFromFile(cfg, overlayFile)

	// Overlaid values
	if cfg.LogLevel != "DEBUG" {
		t.Errorf("LogLevel = %q, want DEBUG (from overlay)", cfg.LogLevel)
	}
	if !cfg.MetricsEnabled {
		t.Error("MetricsEnabled should be true (from overlay)")
	}
	if cfg.APIAddr != ":9999" {
		t.Errorf("APIAddr = %q, want :9999 (from overlay)", cfg.APIAddr)
	}

	// Non-overlaid values remain default
	if cfg.Bin != "/usr/sbin/nftban" {
		t.Errorf("Bin = %q, want default (not changed by overlay)", cfg.Bin)
	}
}

func TestOverlayFromFile_NonexistentFile(t *testing.T) {
	cfg := defaultConfig()
	// Should not panic or change anything
	overlayFromFile(cfg, "/tmp/nonexistent-overlay-12345")

	if cfg.Bin != "/usr/sbin/nftban" {
		t.Errorf("config should be unchanged after overlay from nonexistent file")
	}
}

// =============================================================================
// derivePaths tests
// =============================================================================

func TestDerivePaths(t *testing.T) {
	cfg := &Config{
		DataDir:      "/data",
		ConfigDir:    "/etc/test",
		LogDir:       "/log",
		RunDir:       "/run/test",
		PrometheusDir: "/prom",
		SuricataLogDir: "/log/suricata",
	}

	paths := derivePaths(cfg)

	// Data subdirectories
	if paths.FeedsDir != "/data/feeds" {
		t.Errorf("FeedsDir = %q, want /data/feeds", paths.FeedsDir)
	}
	if paths.GeoIPDir != "/data/geoip" {
		t.Errorf("GeoIPDir = %q, want /data/geoip", paths.GeoIPDir)
	}
	if paths.MetricsDir != "/data/metrics" {
		t.Errorf("MetricsDir = %q, want /data/metrics", paths.MetricsDir)
	}
	if paths.SnapshotsDir != "/data/snapshots" {
		t.Errorf("SnapshotsDir = %q, want /data/snapshots", paths.SnapshotsDir)
	}

	// Config subdirectories
	if paths.ConfD != "/etc/test/conf.d" {
		t.Errorf("ConfD = %q, want /etc/test/conf.d", paths.ConfD)
	}
	if paths.WhitelistD != "/etc/test/whitelist.d" {
		t.Errorf("WhitelistD = %q, want /etc/test/whitelist.d", paths.WhitelistD)
	}
	if paths.BlacklistD != "/etc/test/blacklist.d" {
		t.Errorf("BlacklistD = %q, want /etc/test/blacklist.d", paths.BlacklistD)
	}

	// Log files
	if paths.MainLog != "/log/nftban.log" {
		t.Errorf("MainLog = %q, want /log/nftban.log", paths.MainLog)
	}
	if paths.BansLog != "/log/bans.log" {
		t.Errorf("BansLog = %q, want /log/bans.log", paths.BansLog)
	}

	// Runtime
	if paths.PIDFile != "/run/test/nftban.pid" {
		t.Errorf("PIDFile = %q, want /run/test/nftban.pid", paths.PIDFile)
	}
	if paths.SocketFile != "/run/test/nftban.sock" {
		t.Errorf("SocketFile = %q, want /run/test/nftban.sock", paths.SocketFile)
	}

	// Prometheus
	if paths.PrometheusFile != "/prom/nftban.prom" {
		t.Errorf("PrometheusFile = %q, want /prom/nftban.prom", paths.PrometheusFile)
	}

	// Suricata
	if paths.SuricataEveLog != "/log/suricata/eve-alerts.json" {
		t.Errorf("SuricataEveLog = %q, want /log/suricata/eve-alerts.json", paths.SuricataEveLog)
	}

	// Botguard
	if paths.BotguardLog != "/log/botguard/botguard.log" {
		t.Errorf("BotguardLog = %q, want /log/botguard/botguard.log", paths.BotguardLog)
	}
}

// =============================================================================
// defaultTimeouts tests
// =============================================================================

func TestDefaultTimeouts(t *testing.T) {
	to := defaultTimeouts()
	if to.Fast != 5*time.Second {
		t.Errorf("Fast = %v, want 5s", to.Fast)
	}
	if to.Medium != 30*time.Second {
		t.Errorf("Medium = %v, want 30s", to.Medium)
	}
	if to.Slow != 120*time.Second {
		t.Errorf("Slow = %v, want 120s", to.Slow)
	}
}

// =============================================================================
// defaultNFTables tests
// =============================================================================

func TestDefaultNFTables(t *testing.T) {
	nft := defaultNFTables()

	if nft.TableIPv4 != "ip nftban" {
		t.Errorf("TableIPv4 = %q, want 'ip nftban'", nft.TableIPv4)
	}
	if nft.TableIPv6 != "ip6 nftban" {
		t.Errorf("TableIPv6 = %q, want 'ip6 nftban'", nft.TableIPv6)
	}
	if nft.BlacklistIPv4 != "blacklist_ipv4" {
		t.Errorf("BlacklistIPv4 = %q, want blacklist_ipv4", nft.BlacklistIPv4)
	}
	if nft.BlacklistIPv6 != "blacklist_ipv6" {
		t.Errorf("BlacklistIPv6 = %q, want blacklist_ipv6", nft.BlacklistIPv6)
	}
	if nft.WhitelistIPv4 != "whitelist_ipv4" {
		t.Errorf("WhitelistIPv4 = %q, want whitelist_ipv4", nft.WhitelistIPv4)
	}
	if nft.WhitelistIPv6 != "whitelist_ipv6" {
		t.Errorf("WhitelistIPv6 = %q, want whitelist_ipv6", nft.WhitelistIPv6)
	}
}

// =============================================================================
// Load with custom config file tests
// =============================================================================

func TestLoad_FromTempFile(t *testing.T) {
	resetGlobals()

	dir := t.TempDir()
	confFile := filepath.Join(dir, "nftban.conf")
	content := `NFTBAN_VERSION="1.25.0"
NFTBAN_LOG_LEVEL="TRACE"
NFTBAN_DATA_DIR="/tmp/test-data"
`
	if err := os.WriteFile(confFile, []byte(content), 0644); err != nil {
		t.Fatal(err)
	}

	// Override DefaultConfigFile for this test
	oldDefault := DefaultConfigFile
	DefaultConfigFile = confFile
	defer func() {
		DefaultConfigFile = oldDefault
		resetGlobals()
	}()

	cfg, err := Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if cfg.Version != "1.25.0" {
		t.Errorf("Version = %q, want 1.25.0", cfg.Version)
	}
	if cfg.LogLevel != "TRACE" {
		t.Errorf("LogLevel = %q, want TRACE", cfg.LogLevel)
	}
	if cfg.DataDir != "/tmp/test-data" {
		t.Errorf("DataDir = %q, want /tmp/test-data", cfg.DataDir)
	}
}

func TestLoad_WithLocalOverlay(t *testing.T) {
	resetGlobals()

	dir := t.TempDir()
	confFile := filepath.Join(dir, "nftban.conf")
	localFile := filepath.Join(dir, "nftban.conf.local")

	// Main config
	mainContent := `NFTBAN_VERSION="1.25.0"
NFTBAN_LOG_LEVEL="INFO"
NFTBAN_METRICS_ENABLED="false"
`
	if err := os.WriteFile(confFile, []byte(mainContent), 0644); err != nil {
		t.Fatal(err)
	}

	// Local override
	localContent := `NFTBAN_LOG_LEVEL="DEBUG"
NFTBAN_METRICS_ENABLED="true"
`
	if err := os.WriteFile(localFile, []byte(localContent), 0644); err != nil {
		t.Fatal(err)
	}

	oldDefault := DefaultConfigFile
	DefaultConfigFile = confFile
	defer func() {
		DefaultConfigFile = oldDefault
		resetGlobals()
	}()

	cfg, err := Load()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Version from main file
	if cfg.Version != "1.25.0" {
		t.Errorf("Version = %q, want 1.25.0 (from main)", cfg.Version)
	}
	// LogLevel overridden by local
	if cfg.LogLevel != "DEBUG" {
		t.Errorf("LogLevel = %q, want DEBUG (from local overlay)", cfg.LogLevel)
	}
	// MetricsEnabled overridden by local
	if !cfg.MetricsEnabled {
		t.Error("MetricsEnabled should be true (from local overlay)")
	}
}

// =============================================================================
// Endpoints tests
// =============================================================================

func TestFullPath(t *testing.T) {
	got := FullPath(EndpointBan)
	want := "/api/v1/ban"
	if got != want {
		t.Errorf("FullPath(EndpointBan) = %q, want %q", got, want)
	}
}

func TestAllEndpoints_NotEmpty(t *testing.T) {
	eps := AllEndpoints()
	if len(eps) == 0 {
		t.Error("AllEndpoints() returned empty list")
	}

	// Every endpoint should have a path and at least one method
	for i, ep := range eps {
		if ep.Path == "" {
			t.Errorf("endpoint[%d] has empty path", i)
		}
		if len(ep.Methods) == 0 {
			t.Errorf("endpoint[%d] (%s) has no methods", i, ep.Path)
		}
	}
}

func TestGetAdminEndpoints(t *testing.T) {
	admins := GetAdminEndpoints()
	if len(admins) == 0 {
		t.Error("expected at least one admin endpoint")
	}

	// /ban should be admin
	found := false
	for _, path := range admins {
		if path == EndpointBan {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected /ban to be an admin endpoint")
	}
}

func TestGetPublicEndpoints(t *testing.T) {
	publics := GetPublicEndpoints()
	if len(publics) == 0 {
		t.Error("expected at least one public endpoint")
	}

	// /login should be public
	found := false
	for _, path := range publics {
		if path == EndpointLogin {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected /login to be a public endpoint")
	}
}

func TestIsAdminEndpoint(t *testing.T) {
	if !IsAdminEndpoint(EndpointBan) {
		t.Error("expected /ban to be admin")
	}
	if IsAdminEndpoint(EndpointLogin) {
		t.Error("expected /login to NOT be admin")
	}
	if IsAdminEndpoint("/nonexistent") {
		t.Error("expected unknown path to return false")
	}
}

// =============================================================================
// Services tests
// =============================================================================

func TestGetServices(t *testing.T) {
	svc := GetServices()
	if svc == nil {
		t.Fatal("GetServices() returned nil")
	}
	if svc.MainService != "nftband.service" {
		t.Errorf("MainService = %q, want nftband.service", svc.MainService)
	}
	if svc.DaemonService != "nftband.service" {
		t.Errorf("DaemonService = %q, want nftband.service", svc.DaemonService)
	}
}

func TestAllNFTBanServices(t *testing.T) {
	services := AllNFTBanServices()
	if len(services) == 0 {
		t.Error("AllNFTBanServices() returned empty list")
	}
	// All should end with .service
	for _, s := range services {
		if !strings.HasSuffix(s, ".service") {
			t.Errorf("service %q does not end with .service", s)
		}
	}
}

func TestAllNFTBanTimers(t *testing.T) {
	timers := AllNFTBanTimers()
	if len(timers) == 0 {
		t.Error("AllNFTBanTimers() returned empty list")
	}
	// All should end with .timer
	for _, timer := range timers {
		if !strings.HasSuffix(timer, ".timer") {
			t.Errorf("timer %q does not end with .timer", timer)
		}
	}
}

func TestExternalServices(t *testing.T) {
	ext := ExternalServices()
	if len(ext) == 0 {
		t.Error("ExternalServices() returned empty list")
	}
	// nftables should be an external service
	found := false
	for _, s := range ext {
		if s == "nftables.service" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected nftables.service in external services")
	}
}

// =============================================================================
// Log category tests
// =============================================================================

func TestLogPathForDate(t *testing.T) {
	// Reset and point at a temp config file to avoid reading /etc/nftban/nftban.conf
	resetGlobals()
	dir := t.TempDir()
	confFile := filepath.Join(dir, "nftban.conf")
	os.WriteFile(confFile, []byte(`NFTBAN_LOG_DIR="/var/log/nftban"`+"\n"), 0644)

	oldDefault := DefaultConfigFile
	DefaultConfigFile = confFile
	defer func() {
		DefaultConfigFile = oldDefault
		resetGlobals()
	}()

	path := LogPathForDate(LogCategoryMain, "2026-03-20")
	if path == "" {
		t.Error("LogPathForDate returned empty string")
	}
	if !strings.HasSuffix(path, ".2026-03-20") {
		t.Errorf("LogPathForDate = %q, expected suffix .2026-03-20", path)
	}
}

func TestLogPathForDate_EmptyCategory(t *testing.T) {
	// Unknown category returns empty base path
	path := LogPathForDate(LogCategory("nonexistent"), "2026-03-20")
	// Since base is empty, result should be empty
	if path != "" {
		t.Errorf("expected empty for unknown category, got %q", path)
	}
}
