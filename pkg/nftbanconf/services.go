// =============================================================================
// NFTBan - Service Names Registry
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="services"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Systemd service, timer, and socket name registry"
// meta:input="None"
// meta:output="Service and socket names"
// meta:depends="None"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftban*.service,nftban*.timer"
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package nftbanconf

// =============================================================================
// Service Names Registry
// =============================================================================
// Centralizes all systemd service names, timer names, and socket names
// to avoid hardcoding these strings throughout the codebase.
// =============================================================================

// ServiceNames holds all systemd service/timer/socket unit names
type ServiceNames struct {
	// Main services
	MainService      string // nftban.service
	CoreService      string // nftban-core.service (Go daemon)
	UIService        string // nftban-ui.service
	UIAuthService    string // nftban-ui-auth.service
	DaemonService    string // nftband.service (unified daemon)

	// Timers
	SyncTimer        string // nftban-sync.timer
	MaintenanceTimer string // nftban-maintenance.timer
	FeedsTimer       string // nftban-feeds.timer
	GeoIPTimer       string // nftban-geoip.timer
	MetricsTimer     string // nftban-metrics.timer
	HealthTimer      string // nftban-health.timer

	// Detection services
	PortscanService  string // nftban-portscan.service
	DDoSService      string // nftban-ddos.service
	LoginMonService  string // nftban-loginmon.service
	SuricataService  string // nftban-suricata.service

	// Integration services
	Fail2banService  string // fail2ban.service (external)
	NFTablesService  string // nftables.service (external)
	NodeExporter     string // node_exporter.service (external)
	Prometheus       string // prometheus.service (external)
	Grafana          string // grafana-server.service (external)
}

var defaultServices = &ServiceNames{
	// Main services
	MainService:      "nftban.service",
	CoreService:      "nftban-core.service",
	UIService:        "nftban-ui.service",
	UIAuthService:    "nftban-ui-auth.service",
	DaemonService:    "nftband.service",

	// Timers
	SyncTimer:        "nftban-sync.timer",
	MaintenanceTimer: "nftban-maintenance.timer",
	FeedsTimer:       "nftban-feeds.timer",
	GeoIPTimer:       "nftban-geoip.timer",
	MetricsTimer:     "nftban-metrics.timer",
	HealthTimer:      "nftban-health.timer",

	// Detection services
	PortscanService:  "nftban-portscan.service",
	DDoSService:      "nftban-ddos.service",
	LoginMonService:  "nftban-loginmon.service",
	SuricataService:  "nftban-suricata.service",

	// Integration services
	Fail2banService:  "fail2ban.service",
	NFTablesService:  "nftables.service",
	NodeExporter:     "node_exporter.service",
	Prometheus:       "prometheus.service",
	Grafana:          "grafana-server.service",
}

// GetServices returns the service names registry
func GetServices() *ServiceNames {
	return defaultServices
}

// AllNFTBanServices returns list of all nftban-owned service names
func AllNFTBanServices() []string {
	return []string{
		defaultServices.MainService,
		defaultServices.CoreService,
		defaultServices.UIService,
		defaultServices.UIAuthService,
		defaultServices.DaemonService,
		defaultServices.PortscanService,
		defaultServices.DDoSService,
		defaultServices.LoginMonService,
		defaultServices.SuricataService,
	}
}

// AllNFTBanTimers returns list of all nftban-owned timer names
func AllNFTBanTimers() []string {
	return []string{
		defaultServices.SyncTimer,
		defaultServices.MaintenanceTimer,
		defaultServices.FeedsTimer,
		defaultServices.GeoIPTimer,
		defaultServices.MetricsTimer,
		defaultServices.HealthTimer,
	}
}

// ExternalServices returns list of external services that nftban integrates with
func ExternalServices() []string {
	return []string{
		defaultServices.Fail2banService,
		defaultServices.NFTablesService,
		defaultServices.NodeExporter,
		defaultServices.Prometheus,
		defaultServices.Grafana,
	}
}

// SocketPaths holds Unix socket paths used by nftban
type SocketPaths struct {
	CLI       string // /run/nftban/nftban.sock - CLI communication
	Daemon    string // /run/nftban/nftband.sock - daemon socket
	UIAuth    string // /run/nftban-ui/auth.sock - PAM auth socket
	Metrics   string // /run/nftban/metrics.sock - metrics socket
}

// GetSockets returns socket paths from central config
func GetSockets() *SocketPaths {
	cfg := Get()
	runDir := cfg.RunDir
	if runDir == "" {
		runDir = "/run/nftban"
	}

	return &SocketPaths{
		CLI:     runDir + "/nftban.sock",
		Daemon:  runDir + "/nftband.sock",
		UIAuth:  "/run/nftban-ui/auth.sock",
		Metrics: runDir + "/metrics.sock",
	}
}

// PIDFiles holds PID file paths
type PIDFiles struct {
	Main    string // nftban main process
	Daemon  string // nftband daemon
	UI      string // nftban-ui web server
	UIAuth  string // nftban-ui-auth daemon
}

// GetPIDFiles returns PID file paths from central config
func GetPIDFiles() *PIDFiles {
	cfg := Get()
	runDir := cfg.RunDir
	if runDir == "" {
		runDir = "/run/nftban"
	}

	return &PIDFiles{
		Main:   runDir + "/nftban.pid",
		Daemon: runDir + "/nftband.pid",
		UI:     runDir + "/nftban-ui.pid",
		UIAuth: "/run/nftban-ui/auth.pid",
	}
}

// LockFiles holds lock file paths for exclusive operations
type LockFiles struct {
	Sync        string // sync operations
	Feeds       string // feed updates
	Maintenance string // maintenance tasks
	GeoIP       string // geoip updates
}

// GetLockFiles returns lock file paths from central config
func GetLockFiles() *LockFiles {
	cfg := Get()
	runDir := cfg.RunDir
	if runDir == "" {
		runDir = "/run/nftban"
	}

	return &LockFiles{
		Sync:        runDir + "/sync.lock",
		Feeds:       runDir + "/feeds.lock",
		Maintenance: runDir + "/maintenance.lock",
		GeoIP:       runDir + "/geoip.lock",
	}
}
