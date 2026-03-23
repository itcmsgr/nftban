// =============================================================================
// NFTBan - Central Configuration Loader
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="loader"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Reads /etc/nftban/nftban.conf - the single source of truth"
// meta:input="Bash configuration file"
// meta:output="Config struct with all paths and settings"
// meta:depends="bufio,os"
// meta:inventory.files="/etc/nftban/nftban.conf"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package nftbanconf

// =============================================================================
// Central Configuration Loader
// =============================================================================
// Purpose: Read /etc/nftban/nftban.conf - the SINGLE SOURCE OF TRUTH
//          Both bash CLI and Go binaries use the SAME config file
//
// IMPORTANT: This package reads configuration from bash config files.
//            DO NOT hardcode paths here - they come from nftban.conf!
// =============================================================================

import (
	"bufio"
	"log"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/constants"
	"github.com/itcmsgr/nftban/internal/util"
)

// Config holds all NFTBan configuration from /etc/nftban/nftban.conf
// Variable names match the bash config exactly (e.g., NFTBAN_BIN -> Bin)
type Config struct {
	// Version
	Version       string
	ConfigVersion string

	// Binary paths (from nftban.conf PATHS section)
	Bin      string // NFTBAN_BIN - main CLI
	CoreBin  string // NFTBAN_CORE_BIN - Go core binary
	UIBin    string // NFTBAN_UI_BIN - Web UI binary
	AuthBin  string // NFTBAN_AUTH_BIN - Auth helper

	// Directory paths
	LibDir    string // NFTBAN_LIB_DIR
	ConfigDir string // NFTBAN_CONFIG_DIR
	DataDir   string // NFTBAN_DATA_DIR
	LogDir    string // NFTBAN_LOG_DIR
	CacheDir  string // NFTBAN_CACHE_DIR
	RunDir    string // NFTBAN_RUN_DIR

	// Feature flags
	MetricsEnabled      bool   // NFTBAN_METRICS_ENABLED
	MetricsBackend      string // NFTBAN_METRICS_BACKEND
	MetricsSamplingInterval int // NFTBAN_METRICS_SAMPLING_INTERVAL (seconds)
	MetricsMaxSamples   int    // NFTBAN_METRICS_MAX_SAMPLES
	PrometheusDir       string // NFTBAN_PROMETHEUS_DIR (node_exporter textfile dir)
	MetricsPrometheusAddr   string // NFTBAN_METRICS_PROMETHEUS_ADDR
	MetricsNodeExporterAddr string // NFTBAN_METRICS_NODE_EXPORTER_ADDR
	MetricsVictoriaAddr     string // NFTBAN_METRICS_VICTORIA_ADDR
	GeoIPEnabled        bool   // NFTBAN_GEOIP_ENABLED
	GeoIPLicenseKey     string // NFTBAN_GEOIP_LICENSE_KEY
	FeedsEnabled        bool   // NFTBAN_FEEDS_ENABLED
	FeedsAutoUpdate     bool   // NFTBAN_FEEDS_AUTO_UPDATE
	SuricataEnabled     bool   // NFTBAN_SURICATA_ENABLED
	GUIEnabled          bool   // NFTBAN_GUI_ENABLED
	GUIAddr             string // NFTBAN_GUI_ADDR
	APIAddr             string // NFTBAN_API_ADDR (daemon HTTP API address)
	PortscanEnabled     bool   // NFTBAN_PORTSCAN_ENABLED
	DDoSEnabled         bool   // NFTBAN_DDOS_ENABLED
	LoginMonitorEnabled bool   // NFTBAN_LOGIN_MONITOR_ENABLED

	// Suricata settings
	SuricataEveLog            string // NFTBAN_SURICATA_EVE_LOG
	SuricataLogDir            string // NFTBAN_SURICATA_LOG_DIR
	SuricataBanThreshold      int    // NFTBAN_SURICATA_BAN_THRESHOLD
	SuricataScoreDecay        int    // NFTBAN_SURICATA_SCORE_DECAY
	SuricataCloudflareWhitelist bool // NFTBAN_SURICATA_CLOUDFLARE_WHITELIST

	// Grafana settings
	GrafanaEnabled bool   // NFTBAN_GRAFANA_ENABLED
	GrafanaURL     string // NFTBAN_GRAFANA_URL
	GrafanaAPIKey  string // NFTBAN_GRAFANA_API_KEY

	// Logging
	LogLevel    string // NFTBAN_LOG_LEVEL
	ColorOutput bool   // NFTBAN_COLOR_OUTPUT
	DebugTrace  bool   // NFTBAN_DEBUG_TRACE
	DebugTraceLog string // NFTBAN_DEBUG_TRACE_LOG

	// Distro config
	DistroConfDir string // NFTBAN_DISTRO_CONF_DIR
}

// Derived paths (computed from base paths)
type Paths struct {
	// Data subdirectories
	FeedsDir     string
	GeoIPDir     string
	MetricsDir   string
	SnapshotsDir string
	ReportsDir   string
	ExportsDir   string

	// Config subdirectories
	ConfD        string
	WhitelistD   string
	BlacklistD   string
	PortsD       string
	GeobanD      string
	DistrosD     string

	// Log files
	MainLog      string
	AuditLog     string
	BansLog      string
	PortscanLog  string
	DDoSLog      string
	LoginAlertLog string
	FeedsLog     string
	GeobanLog    string
	CronLog      string
	MaintenanceLog string
	CLIErrorsLog string

	// Botguard log files
	BotguardLog          string
	BotguardDecisionsLog string

	// Suricata log files
	SuricataEveLog   string
	SuricataFastLog  string
	SuricataStatsLog string
	SuricataMainLog  string

	// Runtime files
	PIDFile      string
	SocketFile   string

	// Metrics files
	PrometheusFile          string // nftban.prom
	PrometheusBandwidthFile string // nftban_bandwidth.prom
	MetricsJSON             string
}

// Timeouts for CLI command execution (centralized)
type Timeouts struct {
	Fast   time.Duration // status, simple queries
	Medium time.Duration // ban, unban, search
	Slow   time.Duration // sync, health check, feed updates
}

// NFTables references (table/chain/set names)
type NFTables struct {
	TableIPv4       string
	TableIPv6       string
	BlacklistIPv4   string
	BlacklistIPv6   string
	WhitelistIPv4   string
	WhitelistIPv6   string
	// v2.1: All ban sources (feeds, geoban, auto, manual) go to blacklist
	// Source tracking done in daemon database, not separate nft sets
}

var (
	// Global singleton
	globalConfig *Config
	globalPaths  *Paths
	globalTimeouts *Timeouts
	globalNFT    *NFTables
	loadOnce     sync.Once
	loadErr      error

	// Default config file path
	DefaultConfigFile = "/etc/nftban/nftban.conf"
)

// Load reads configuration from /etc/nftban/nftban.conf + nftban.conf.local
// Central config architecture: nftban.conf (package defaults) is loaded first,
// then nftban.conf.local (user overrides) is overlaid on top.
// This is called once at startup - config is cached
func Load() (*Config, error) {
	loadOnce.Do(func() {
		globalConfig, loadErr = loadFromFile(DefaultConfigFile)
		if loadErr == nil {
			// Overlay central user overrides from nftban.conf.local
			// This is the SINGLE central override file — no symlinks, no scattered .local files
			localFile := DefaultConfigFile + ".local"
			if _, err := os.Stat(localFile); err == nil {
				overlayFromFile(globalConfig, localFile)
			}
			globalPaths = derivePaths(globalConfig)
			globalTimeouts = defaultTimeouts()
			globalNFT = defaultNFTables()
		}
	})
	return globalConfig, loadErr
}

// MustLoad loads config or exits - use in init() and startup code.
// Prefer Load() in code that can handle errors gracefully.
func MustLoad() *Config {
	cfg, err := Load()
	if err != nil {
		log.Fatalf("nftbanconf: failed to load config: %v", err)
	}
	return cfg
}

// Get returns the cached config (Load must be called first)
func Get() *Config {
	if globalConfig == nil {
		if _, err := Load(); err != nil {
			log.Printf("nftbanconf: auto-load failed: %v", err)
		}
	}
	return globalConfig
}

// GetPaths returns derived paths
func GetPaths() *Paths {
	if globalPaths == nil {
		if _, err := Load(); err != nil {
			log.Printf("nftbanconf: auto-load failed: %v", err)
		}
	}
	return globalPaths
}

// MustLoadPaths loads config and returns paths or exits.
// NO FALLBACK - paths must come from /etc/nftban/nftban.conf
// Prefer GetPaths() in code that can handle errors gracefully.
func MustLoadPaths() *Paths {
	_, err := Load()
	if err != nil {
		log.Fatalf("nftbanconf: failed to load paths: %v", err)
	}
	if globalPaths == nil {
		log.Fatalf("nftbanconf: paths not initialized after load (config may be invalid)")
	}
	return globalPaths
}

// GetTimeouts returns command timeouts
func GetTimeouts() *Timeouts {
	if globalTimeouts == nil {
		if _, err := Load(); err != nil {
			log.Printf("nftbanconf: auto-load failed: %v", err)
		}
	}
	return globalTimeouts
}

// GetNFT returns NFTables references
func GetNFT() *NFTables {
	if globalNFT == nil {
		if _, err := Load(); err != nil {
			log.Printf("nftbanconf: auto-load failed: %v", err)
		}
	}
	return globalNFT
}

// loadFromFile reads and parses the config file
func loadFromFile(path string) (*Config, error) {
	// Start with defaults
	cfg := defaultConfig()

	file, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			// Config file doesn't exist - use defaults
			return cfg, nil
		}
		return nil, err
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())

		// Skip empty lines and comments
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		// Skip bash-specific lines
		if strings.HasPrefix(line, "[[") || strings.HasPrefix(line, "_NFTBAN") {
			continue
		}

		// Parse KEY="value" or KEY=value
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}

		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])
		value = strings.Trim(value, `"'`)

		// Map to struct fields
		switch key {
		// Version
		case "NFTBAN_VERSION":
			cfg.Version = value
		case "NFTBAN_CONFIG_VERSION":
			cfg.ConfigVersion = value

		// Binary paths
		case "NFTBAN_BIN":
			cfg.Bin = value
		case "NFTBAN_CORE_BIN":
			cfg.CoreBin = value
		case "NFTBAN_UI_BIN":
			cfg.UIBin = value
		case "NFTBAN_AUTH_BIN":
			cfg.AuthBin = value

		// Directory paths
		case "NFTBAN_LIB_DIR":
			cfg.LibDir = value
		case "NFTBAN_CONFIG_DIR":
			cfg.ConfigDir = value
		case "NFTBAN_DATA_DIR":
			cfg.DataDir = value
		case "NFTBAN_LOG_DIR":
			cfg.LogDir = value
		case "NFTBAN_CACHE_DIR":
			cfg.CacheDir = value
		case "NFTBAN_RUN_DIR":
			cfg.RunDir = value

		// Features
		case "NFTBAN_METRICS_ENABLED":
			cfg.MetricsEnabled = util.ParseBool(value, false)
		case "NFTBAN_METRICS_BACKEND":
			cfg.MetricsBackend = value
		case "NFTBAN_METRICS_SAMPLING_INTERVAL":
			cfg.MetricsSamplingInterval = util.ParseInt(value, 10)
		case "NFTBAN_METRICS_MAX_SAMPLES":
			cfg.MetricsMaxSamples = util.ParseInt(value, 360)
		case "NFTBAN_PROMETHEUS_DIR":
			cfg.PrometheusDir = value
		case "NFTBAN_METRICS_PROMETHEUS_ADDR":
			cfg.MetricsPrometheusAddr = value
		case "NFTBAN_METRICS_NODE_EXPORTER_ADDR":
			cfg.MetricsNodeExporterAddr = value
		case "NFTBAN_METRICS_VICTORIA_ADDR":
			cfg.MetricsVictoriaAddr = value
		case "NFTBAN_GEOIP_ENABLED":
			cfg.GeoIPEnabled = util.ParseBool(value, false)
		case "NFTBAN_GEOIP_LICENSE_KEY":
			cfg.GeoIPLicenseKey = value
		case "NFTBAN_FEEDS_ENABLED":
			cfg.FeedsEnabled = util.ParseBool(value, false)
		case "NFTBAN_FEEDS_AUTO_UPDATE":
			cfg.FeedsAutoUpdate = util.ParseBool(value, false)
		case "NFTBAN_SURICATA_ENABLED":
			cfg.SuricataEnabled = util.ParseBool(value, false)
		case "NFTBAN_GUI_ENABLED":
			cfg.GUIEnabled = util.ParseBool(value, false)
		case "NFTBAN_GUI_ADDR":
			cfg.GUIAddr = value
		case "NFTBAN_API_ADDR":
			cfg.APIAddr = value
		case "NFTBAN_PORTSCAN_ENABLED":
			cfg.PortscanEnabled = util.ParseBool(value, false)
		case "NFTBAN_DDOS_ENABLED":
			cfg.DDoSEnabled = util.ParseBool(value, false)
		case "NFTBAN_LOGIN_MONITOR_ENABLED":
			cfg.LoginMonitorEnabled = util.ParseBool(value, false)

		// Suricata
		case "NFTBAN_SURICATA_EVE_LOG":
			cfg.SuricataEveLog = value
		case "NFTBAN_SURICATA_LOG_DIR":
			cfg.SuricataLogDir = value
		case "NFTBAN_SURICATA_BAN_THRESHOLD":
			cfg.SuricataBanThreshold = util.ParseInt(value, 100)
		case "NFTBAN_SURICATA_SCORE_DECAY":
			cfg.SuricataScoreDecay = util.ParseInt(value, 3600)
		case "NFTBAN_SURICATA_CLOUDFLARE_WHITELIST":
			cfg.SuricataCloudflareWhitelist = util.ParseBool(value, false)

		// Grafana
		case "NFTBAN_GRAFANA_ENABLED":
			cfg.GrafanaEnabled = util.ParseBool(value, false)
		case "NFTBAN_GRAFANA_URL":
			cfg.GrafanaURL = value
		case "NFTBAN_GRAFANA_API_KEY":
			cfg.GrafanaAPIKey = value

		// Logging
		case "NFTBAN_LOG_LEVEL":
			cfg.LogLevel = value
		case "NFTBAN_COLOR_OUTPUT":
			cfg.ColorOutput = util.ParseBool(value, false)
		case "NFTBAN_DEBUG_TRACE":
			cfg.DebugTrace = util.ParseBool(value, false)
		case "NFTBAN_DEBUG_TRACE_LOG":
			cfg.DebugTraceLog = value

		// Distro
		case "NFTBAN_DISTRO_CONF_DIR":
			cfg.DistroConfDir = value
		}
	}

	return cfg, scanner.Err()
}

// overlayFromFile reads nftban.conf.local and overlays values onto existing config.
// Central config architecture: nftban.conf.local is the SINGLE user override file.
// All Go and Bash components read from this same file — no symlinks needed.
func overlayFromFile(cfg *Config, path string) {
	file, err := os.Open(path)
	if err != nil {
		return
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}

		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}

		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])
		value = strings.Trim(value, `"'`)

		// Same switch as loadFromFile — only override if key is present
		switch key {
		case "NFTBAN_VERSION":
			cfg.Version = value
		case "NFTBAN_BIN":
			cfg.Bin = value
		case "NFTBAN_CORE_BIN":
			cfg.CoreBin = value
		case "NFTBAN_UI_BIN":
			cfg.UIBin = value
		case "NFTBAN_AUTH_BIN":
			cfg.AuthBin = value
		case "NFTBAN_LIB_DIR":
			cfg.LibDir = value
		case "NFTBAN_CONFIG_DIR":
			cfg.ConfigDir = value
		case "NFTBAN_DATA_DIR":
			cfg.DataDir = value
		case "NFTBAN_LOG_DIR":
			cfg.LogDir = value
		case "NFTBAN_CACHE_DIR":
			cfg.CacheDir = value
		case "NFTBAN_RUN_DIR":
			cfg.RunDir = value
		case "NFTBAN_METRICS_ENABLED":
			cfg.MetricsEnabled = util.ParseBool(value, false)
		case "NFTBAN_METRICS_BACKEND":
			cfg.MetricsBackend = value
		case "NFTBAN_METRICS_SAMPLING_INTERVAL":
			cfg.MetricsSamplingInterval = util.ParseInt(value, cfg.MetricsSamplingInterval)
		case "NFTBAN_METRICS_MAX_SAMPLES":
			cfg.MetricsMaxSamples = util.ParseInt(value, cfg.MetricsMaxSamples)
		case "NFTBAN_PROMETHEUS_DIR":
			cfg.PrometheusDir = value
		case "NFTBAN_METRICS_PROMETHEUS_ADDR":
			cfg.MetricsPrometheusAddr = value
		case "NFTBAN_METRICS_NODE_EXPORTER_ADDR":
			cfg.MetricsNodeExporterAddr = value
		case "NFTBAN_METRICS_VICTORIA_ADDR":
			cfg.MetricsVictoriaAddr = value
		case "NFTBAN_GEOIP_ENABLED":
			cfg.GeoIPEnabled = util.ParseBool(value, false)
		case "NFTBAN_GEOIP_LICENSE_KEY":
			cfg.GeoIPLicenseKey = value
		case "NFTBAN_FEEDS_ENABLED":
			cfg.FeedsEnabled = util.ParseBool(value, false)
		case "NFTBAN_FEEDS_AUTO_UPDATE":
			cfg.FeedsAutoUpdate = util.ParseBool(value, false)
		case "NFTBAN_SURICATA_ENABLED":
			cfg.SuricataEnabled = util.ParseBool(value, false)
		case "NFTBAN_GUI_ENABLED":
			cfg.GUIEnabled = util.ParseBool(value, false)
		case "NFTBAN_GUI_ADDR":
			cfg.GUIAddr = value
		case "NFTBAN_API_ADDR":
			cfg.APIAddr = value
		case "NFTBAN_PORTSCAN_ENABLED":
			cfg.PortscanEnabled = util.ParseBool(value, false)
		case "NFTBAN_DDOS_ENABLED":
			cfg.DDoSEnabled = util.ParseBool(value, false)
		case "NFTBAN_LOGIN_MONITOR_ENABLED":
			cfg.LoginMonitorEnabled = util.ParseBool(value, false)
		case "NFTBAN_SURICATA_EVE_LOG":
			cfg.SuricataEveLog = value
		case "NFTBAN_SURICATA_LOG_DIR":
			cfg.SuricataLogDir = value
		case "NFTBAN_SURICATA_BAN_THRESHOLD":
			cfg.SuricataBanThreshold = util.ParseInt(value, cfg.SuricataBanThreshold)
		case "NFTBAN_SURICATA_SCORE_DECAY":
			cfg.SuricataScoreDecay = util.ParseInt(value, cfg.SuricataScoreDecay)
		case "NFTBAN_SURICATA_CLOUDFLARE_WHITELIST":
			cfg.SuricataCloudflareWhitelist = util.ParseBool(value, false)
		case "NFTBAN_GRAFANA_ENABLED":
			cfg.GrafanaEnabled = util.ParseBool(value, false)
		case "NFTBAN_GRAFANA_URL":
			cfg.GrafanaURL = value
		case "NFTBAN_GRAFANA_API_KEY":
			cfg.GrafanaAPIKey = value
		case "NFTBAN_LOG_LEVEL":
			cfg.LogLevel = value
		case "NFTBAN_COLOR_OUTPUT":
			cfg.ColorOutput = util.ParseBool(value, false)
		case "NFTBAN_DEBUG_TRACE":
			cfg.DebugTrace = util.ParseBool(value, false)
		case "NFTBAN_DEBUG_TRACE_LOG":
			cfg.DebugTraceLog = value
		case "NFTBAN_DISTRO_CONF_DIR":
			cfg.DistroConfDir = value
		}
	}
}

// defaultConfig returns config with sane defaults
func defaultConfig() *Config {
	return &Config{
		Version:       "1.0.0",
		ConfigVersion: "2",

		// Binary paths
		Bin:     "/usr/sbin/nftban",
		CoreBin: "/usr/lib/nftban/bin/nftban-core",
		UIBin:   "/usr/sbin/nftban-ui",
		AuthBin: "/usr/libexec/nftban-ui-auth",

		// Directory paths
		LibDir:    "/usr/lib/nftban",
		ConfigDir: "/etc/nftban",
		DataDir:   "/var/lib/nftban",
		LogDir:    "/var/log/nftban",
		CacheDir:  "/var/cache/nftban",
		RunDir:    "/run/nftban",

		// Features (defaults to off for safety)
		MetricsEnabled:          false,
		MetricsBackend:          "prometheus",
		MetricsSamplingInterval: 10,  // 10 seconds
		MetricsMaxSamples:       360, // 1 hour at 10s intervals
		PrometheusDir:           "/var/lib/node_exporter/textfile_collector",
		MetricsPrometheusAddr:   "localhost:9090",
		MetricsNodeExporterAddr: "localhost:9100",
		MetricsVictoriaAddr:     "localhost:8428",
		GeoIPEnabled:            false,
		FeedsEnabled:        false,
		FeedsAutoUpdate:     true,
		SuricataEnabled:     false,
		GUIEnabled:          false,
		GUIAddr:             "127.0.0.1:3940",
		APIAddr:             ":8080",
		PortscanEnabled:     false,
		DDoSEnabled:         false,
		LoginMonitorEnabled: false,

		// Suricata
		SuricataEveLog:       "/var/log/nftban/suricata/eve-alerts.json",
		SuricataLogDir:       "/var/log/nftban/suricata",
		SuricataBanThreshold: 100,
		SuricataScoreDecay:   3600,

		// Grafana
		GrafanaEnabled: false,
		GrafanaURL:     "http://localhost:3000",
		GrafanaAPIKey:  "",

		// Logging
		LogLevel:      "INFO",
		ColorOutput:   true,
		DebugTrace:    false,
		DebugTraceLog: "/var/log/nftban/debug_trace.log",

		// Distro
		DistroConfDir: "/etc/nftban/distros",
	}
}

// derivePaths computes derived paths from base config
func derivePaths(cfg *Config) *Paths {
	return &Paths{
		// Data subdirectories
		FeedsDir:     cfg.DataDir + "/feeds",
		GeoIPDir:     cfg.DataDir + "/geoip",
		MetricsDir:   cfg.DataDir + "/metrics",
		SnapshotsDir: cfg.DataDir + "/snapshots",
		ReportsDir:   cfg.DataDir + "/reports",
		ExportsDir:   cfg.DataDir + "/exports",

		// Config subdirectories
		ConfD:      cfg.ConfigDir + "/conf.d",
		WhitelistD: cfg.ConfigDir + "/whitelist.d",
		BlacklistD: cfg.ConfigDir + "/blacklist.d",
		PortsD:     cfg.ConfigDir + "/ports.d",
		GeobanD:    cfg.ConfigDir + "/geoban.d",
		DistrosD:   cfg.ConfigDir + "/distros",

		// Log files
		MainLog:        cfg.LogDir + "/nftban.log",
		AuditLog:       cfg.LogDir + "/nftban-actions.log",
		BansLog:        cfg.LogDir + "/bans.log",
		PortscanLog:    cfg.LogDir + "/portscan.log",
		DDoSLog:        cfg.LogDir + "/ddos.log",
		LoginAlertLog:  cfg.LogDir + "/login_alert.log",
		FeedsLog:       cfg.LogDir + "/feeds.log",
		GeobanLog:      cfg.LogDir + "/geoban.log",
		CronLog:        cfg.LogDir + "/cron.log",
		MaintenanceLog: cfg.LogDir + "/maintenance.log",
		CLIErrorsLog:   cfg.LogDir + "/cli_errors.log",

		// Botguard log files
		BotguardLog:          cfg.LogDir + "/botguard/botguard.log",
		BotguardDecisionsLog: cfg.LogDir + "/botguard/decisions.log",

		// Suricata log files (use SuricataLogDir if set, else default)
		SuricataEveLog:   cfg.SuricataLogDir + "/eve-alerts.json",
		SuricataFastLog:  cfg.SuricataLogDir + "/fast.log",
		SuricataStatsLog: cfg.SuricataLogDir + "/stats.log",
		SuricataMainLog:  cfg.SuricataLogDir + "/suricata.log",

		// Runtime files
		PIDFile:    cfg.RunDir + "/nftban.pid",
		SocketFile: cfg.RunDir + "/nftban.sock",

		// Metrics files (use PrometheusDir from config)
		PrometheusFile:          cfg.PrometheusDir + "/nftban.prom",
		PrometheusBandwidthFile: cfg.PrometheusDir + "/nftban_bandwidth.prom",
		MetricsJSON:             cfg.DataDir + "/metrics/metrics.json",
	}
}

// defaultTimeouts returns sensible command timeouts
func defaultTimeouts() *Timeouts {
	return &Timeouts{
		Fast:   constants.IPCFastTimeout,   // status, simple queries
		Medium: constants.IPCMediumTimeout,  // ban, unban, search
		Slow:   constants.IPCSlowTimeout,    // sync, health, feed updates
	}
}

// defaultNFTables returns NFTables naming conventions
func defaultNFTables() *NFTables {
	return &NFTables{
		TableIPv4:     "ip nftban",
		TableIPv6:     "ip6 nftban",
		BlacklistIPv4: "blacklist_ipv4",
		BlacklistIPv6: "blacklist_ipv6",
		WhitelistIPv4: "whitelist_ipv4",
		WhitelistIPv6: "whitelist_ipv6",
		// v2.1: All bans go to blacklist (source tracked in DB)
	}
}


// Reload forces config reload (for testing or config changes)
func Reload() error {
	loadOnce = sync.Once{} // Reset once
	globalConfig = nil
	globalPaths = nil
	globalTimeouts = nil
	globalNFT = nil
	_, err := Load()
	return err
}
